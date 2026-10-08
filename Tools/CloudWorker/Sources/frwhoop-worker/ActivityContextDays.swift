import Foundation
import StrandAnalytics
import WhoopProtocol

/// ActivityContext v2 on the server: the activity lane's HART (or baseline) window probabilities and
/// the per-window `imu-feat-2` IMU features go through the SAME decoder the app runs
/// (`StrandAnalytics.ActivityContextTrackBuilder`), together with the day's stored heart rate, gravity,
/// step, sleep, workout and wear streams, and the resulting day document is stored in
/// `public.activity_context_days` through the fenced `publish_activity_context_day` RPC.
///
/// This is an add-on to the v1 epoch publish, not a replacement: the lane builds the document after
/// inference, writes it inside the same transaction right before the v1 publish, and a failure at any
/// step of it (stream read, decode, encode, rejected payload, migration not applied yet) is counted and
/// skipped so the v1 epochs, the scoring invalidation and the job completion behave exactly as before.
enum ActivityContextDays {

    /// A stored day's sensor streams, as the decoder wants them.
    struct Streams {
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        var steps: [StepSample] = []
        /// Wrist-off / wrist-on events only; `offWristIntervals` ignores every other kind.
        var events: [WhoopEvent] = []

        /// True when the day holds no measurement the decoder reads. Wear events alone describe no
        /// activity (they only shape spans over measurements), so they do not count.
        var isEmpty: Bool { hr.isEmpty && gravity.isEmpty && steps.isEmpty }
    }

    struct Built {
        /// The RPC payload: `{day, model_version, preprocessing_version, document}`, sorted keys.
        var payloadText: String
        var runs: Int
        var events: Int
        var observedSeconds: Int
        /// The decoder-config tag recorded in the document (`decoder_config.tag`), nil without provenance.
        var decoderConfigTag: String? = nil
    }

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        /// The lease or revision moved on; the v1 publish that follows is fenced the same way.
        case fenced
        /// The RPC raised (malformed document, migration missing, grant problem). Nothing was written and
        /// the surrounding transaction is still usable.
        case rejected(String)
    }

    /// Hours of wear events read before the day: a WRIST_OFF shortly before midnight still opens the span
    /// that runs into it. The phone reads the same reach-back.
    static let eventReachBackSeconds = 6 * 3600

    // MARK: - Pure assembly (unit-tested without a database)

    /// The windows of one inference response, with their IMU features dropped unless the service says
    /// they are laid out the way this build's decoder reads them (`ActivityContextVersions.featureSchema`),
    /// and their transition-expert output dropped unless it is stamped with the schema this build reads
    /// (`ActivityEncoderWindowSet.transitionSchema`). A service that renames or rescales either must not
    /// feed shifted numbers into the decoder.
    static func windowsWithCompatibleFeatures(
        _ result: ActivityPythonService.InferResult) -> [ActivityPythonService.WindowPrediction] {
        let featuresOK = result.featureSchema == ActivityContextVersions.featureSchema
        let transitionOK = result.transitionSchema == ActivityEncoderWindowSet.transitionSchema
        let fineOK = result.fineSchema == ActivityEncoderWindowSet.fineSchema
        if featuresOK && transitionOK && fineOK { return result.windows }
        return result.windows.map { w in
            var stripped = w
            if !featuresOK { stripped.features = [:] }
            if !transitionOK { stripped.transition = nil }
            if !fineOK { stripped.fine = nil }
            return stripped
        }
    }

    /// The response's ElderNet gait windows, or none unless stamped with the schema this build reads.
    static func compatibleGaitWindows(_ result: ActivityPythonService.InferResult) -> [ActivityGaitWindow] {
        result.gaitSchema == ActivityEncoderWindowSet.gaitSchema ? result.gaitWindows : []
    }

    /// The service window as the decoder's optional transition-expert window. Nil when the service
    /// sent no `transition` output (older serve.py or the expert unavailable — the fail-open default:
    /// the decoder then runs exactly as it did before the expert existed). An abstained window is also
    /// nil: the phone's stored window set writes no row for one, so both decoders must see the same
    /// seconds without it (an abstained window would otherwise clear the previous window's held evidence
    /// on the server only).
    static func transitionWindow(_ w: ActivityPythonService.WindowPrediction,
                                 modelVersion: String, preprocessingVersion: String) -> ActivityTransitionWindow? {
        guard let t = w.transition, !t.abstained else { return nil }
        guard w.start.isFinite, w.end.isFinite, abs(w.start) < 1e12, abs(w.end) < 1e12 else { return nil }
        let s = Int(w.start), e = Int(w.end)
        guard e > s else { return nil }
        // Canonical order, fixed: probabilities are stored in the persisted class order.
        let order = ActivityEncoderWindowSet.transitionClassOrder
        var probs: [Double] = []
        probs.reserveCapacity(order.count)
        for key in order {
            let v = t.probs[key] ?? 0
            guard v.isFinite else { return nil }
            probs.append(v)
        }
        return ActivityTransitionWindow(startTs: s, endTs: e, probabilities: probs,
                                        modelVersion: modelVersion,
                                        preprocessingVersion: preprocessingVersion,
                                        abstained: t.abstained)
    }

    /// One service window's IMU facts, or nil when the service did not send the required ones (an older
    /// serve.py without `feat`, or a window whose features were not computable).
    static func imuFeatures(_ w: ActivityPythonService.WindowPrediction) -> ImuWindowFeatures? {
        guard w.start.isFinite, w.end.isFinite, abs(w.start) < 1e12, abs(w.end) < 1e12 else { return nil }
        let f = w.features
        guard let accel = f["accel_rms_g"], let gyro = f["gyro_rms_dps"], let jerk = f["jerk_rms_gps"],
              let strength = f["cadence_strength"] else { return nil }
        let s = Int(w.start), e = Int(w.end)
        guard e > s else { return nil }
        return ImuWindowFeatures(startTs: s, endTs: e, accelRmsG: accel, gyroRmsDps: gyro, jerkRms: jerk,
                                 cadenceHz: f["cadence_hz"], cadenceStrength: strength,
                                 orientationChangeDeg: f["orientation_change_deg"])
    }

    /// The service window as the decoder's model-agnostic encoder window (unclipped: the track builder
    /// keys windows by their end second and ignores the ones outside the day).
    static func encoderWindow(_ w: ActivityPythonService.WindowPrediction) -> ActivityWindowPrediction? {
        guard w.start.isFinite, w.end.isFinite, abs(w.start) < 1e12, abs(w.end) < 1e12 else { return nil }
        let s = Int(w.start), e = Int(w.end)
        guard e > s else { return nil }
        return ActivityWindowPrediction(
            startTs: s, endTs: e, label: MotionLabel(rawValue: w.label) ?? .unknown,
            probs: w.probs, baseline: w.baseline, calibrated: w.calibrated, fineProbs: w.fine)
    }

    /// One published night: its in-bed window and the staged `[{start, end, stage}]` segments.
    struct Night: Equatable {
        let start: Int
        let end: Int
        let stagesJSON: String?
    }

    /// The nights' sleep epochs (each night's non-wake segments), the same spans the app derives from its
    /// stored nights, so lying awake in bed is "in bed" on the server too rather than asleep.
    static func asleepSpans(_ nights: [Night]) -> [(start: Int, end: Int)] {
        nights.flatMap { DayStateSpan.asleep(stagesJSON: $0.stagesJSON, start: $0.start, end: $0.end) }
            .map { (start: $0.start, end: $0.end) }
    }

    /// The decoder input for one job day. Sleep outside logged sessions stays "unknown" on the server
    /// unless the caller says the day has been through sleep detection (`sleepKnownOutsideSessions`):
    /// the detector may not have run over a stretch yet, and stillness alone never means asleep. There is
    /// no default: the raw-IMU lane took one and left every finished day's waking hours "unknown" forever
    /// (audit D1-02), so each caller decides (`sleepKnown(now:dayEnd:)` for a stored day).
    ///
    /// `horizon` is how far the day has actually happened (`now` for the UTC day in progress, the day's end
    /// for a finished one). A WRIST_OFF with no WRIST_ON yet stays open only up to it: the decoder emits an
    /// "off wrist" second for every second of an off-wrist span, so an unbounded tail would describe the
    /// rest of today as already over.
    static func trackInput(windows: [ActivityPythonService.WindowPrediction], streams: Streams,
                           sleep: [(start: Int, end: Int)], inBed: [(start: Int, end: Int)] = [],
                           exercise: [(start: Int, end: Int, sport: String)],
                           dayStart: Int, dayEnd: Int, horizon: Int? = nil,
                           sleepKnownOutsideSessions: Bool,
                           encoderVersion: String,
                           transitionVersion: String = "unknown",
                           transitionPreprocessingVersion: String = "unknown",
                           gaitWindows: [ActivityGaitWindow] = []) -> ActivityContextTrackInput {
        let spanEnd = min(horizon ?? dayEnd, dayEnd)
        let offWrist = AnalyticsEngine
            .offWristIntervals(events: streams.events, windowEnd: spanEnd, hr: streams.hr)
            .filter { $0.end > dayStart && $0.start < spanEnd }
            .map { DayStateSpan(start: $0.start, end: $0.end) }
        // "baseline" is the heuristic classifier (not calibrated probabilities); anything else the service
        // loaded from a manifest is the trained encoder.
        let encoderId = windows.contains { !$0.baseline } ? "hart" : "baseline"
        return ActivityContextTrackInput(
            dayStart: dayStart, dayEnd: dayEnd,
            hr: streams.hr, gravity: streams.gravity, steps: streams.steps,
            sleep: sleep.map { DayStateSpan(start: $0.start, end: $0.end) },
            inBed: inBed.map { DayStateSpan(start: $0.start, end: $0.end) },
            sleepKnownOutsideSessions: sleepKnownOutsideSessions,
            // Sport is the phone's own name from sessions.summary, passed through verbatim so the
            // shared decoder sees the same WorkoutKind the phone's decoder sees (a row with no sport
            // stays "" → .unspecified, exactly the phone's honest fallback). audit WS-11-F08.
            workouts: exercise.map { DayStateWorkout(start: $0.start, end: $0.end, sport: $0.sport) },
            offWrist: offWrist,
            encoderWindows: windows.compactMap(encoderWindow),
            encoderId: encoderId, encoderVersion: encoderVersion,
            imuWindows: windows.compactMap(imuFeatures),
            transitionWindows: windows.compactMap {
                transitionWindow($0, modelVersion: transitionVersion,
                                 preprocessingVersion: transitionPreprocessingVersion)
            },
            gaitWindows: gaitWindows)
    }

    private struct Envelope: Encodable {
        var day: String
        var modelVersion: String
        var preprocessingVersion: String
        var document: ProvenancedDocument

        enum CodingKeys: String, CodingKey {
            case day, document
            case modelVersion = "model_version", preprocessingVersion = "preprocessing_version"
        }
    }

    /// The shared day document with the server's additive `decoder_config` provenance beside its own keys
    /// (readers decoding `ActivityContextDayDocument` ignore the extra key; the publish RPC stores the whole
    /// object), so which heart-rate reference decoded a stored day is visible next to the phone's.
    private struct ProvenancedDocument: Encodable {
        var document: ActivityContextDayDocument
        var decoderConfig: DecoderConfigProvenance?

        private enum ExtraKeys: String, CodingKey { case decoderConfig = "decoder_config" }

        func encode(to encoder: Encoder) throws {
            try document.encode(to: encoder)
            if let decoderConfig {
                var extra = encoder.container(keyedBy: ExtraKeys.self)
                try extra.encode(decoderConfig, forKey: .decoderConfig)
            }
        }
    }

    /// Decode the day and encode the RPC payload. The decoder snapshot is left out: the server recomputes
    /// the whole day from stored inputs every time a job runs, so the snapshot would only add weight.
    ///
    /// `lookback` (the half hour before the day, see `lookbackInput`) warms the decoder up so the day does not
    /// start from the prior at midnight; `provenance` is recorded as the document's `decoder_config`.
    static func build(input: ActivityContextTrackInput, day: String, modelVersion: String,
                      preprocessingVersion: String, generatedAt: Int,
                      config: ActivityDecoderConfig = ActivityDecoderConfig(),
                      provenance: DecoderConfigProvenance? = nil,
                      lookback: ActivityContextTrackInput? = nil) throws -> Built {
        let document = dayDocumentAndTrack(input: input, generatedAt: generatedAt, config: config,
                                           lookback: lookback).document
        let envelope = Envelope(day: day, modelVersion: modelVersion,
                                preprocessingVersion: preprocessingVersion,
                                document: ProvenancedDocument(document: document, decoderConfig: provenance))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("activity day document encoding failed")
        }
        return Built(payloadText: text, runs: document.runs.count, events: document.events.count,
                     observedSeconds: document.observedSeconds, decoderConfigTag: provenance?.tag)
    }

    /// The day document for `input` (no snapshot), runs clipped to the day. Shared by the published v2
    /// document and the Inertia candidate comparison (`ActivityMotionHeadsDays`), which differ only in config.
    static func dayDocument(input: ActivityContextTrackInput, generatedAt: Int,
                            config: ActivityDecoderConfig = ActivityDecoderConfig(),
                            lookback: ActivityContextTrackInput? = nil) -> ActivityContextDayDocument {
        dayDocumentAndTrack(input: input, generatedAt: generatedAt, config: config, lookback: lookback).document
    }

    /// `dayDocument` plus the decode's motion-heads report (nil without a motion-heads config): how the Inertia
    /// windows were attached, dropped and used.
    static func dayDocumentAndReport(input: ActivityContextTrackInput, generatedAt: Int,
                                     config: ActivityDecoderConfig = ActivityDecoderConfig(),
                                     lookback: ActivityContextTrackInput? = nil)
        -> (document: ActivityContextDayDocument, report: MotionHeadsTrackReport?) {
        let built = dayDocumentAndTrack(input: input, generatedAt: generatedAt, config: config, lookback: lookback)
        return (built.document, built.track.motionHeads)
    }

    /// `dayDocument` plus the decode's gait-quality report (nil without a gait config): how the ElderNet windows were
    /// attached, dropped and used (the ElderNet candidate comparison, `ActivityGaitWindowsDays`).
    static func dayDocumentAndGaitReport(input: ActivityContextTrackInput, generatedAt: Int,
                                         config: ActivityDecoderConfig = ActivityDecoderConfig(),
                                         lookback: ActivityContextTrackInput? = nil)
        -> (document: ActivityContextDayDocument, report: GaitQualityTrackReport?) {
        let built = dayDocumentAndTrack(input: input, generatedAt: generatedAt, config: config, lookback: lookback)
        return (built.document, built.track.gaitQuality)
    }

    /// The decode behind every day document. With a `lookback` input that observed anything, the day resumes
    /// from the decoder state at the end of the lookback (`resuming:`), so the first minutes after midnight are
    /// decoded with the belief, dwell and evidence buffers the preceding half hour built instead of the prior
    /// (audit D2-11). The lookback's own states and events are never part of the document (events are clipped
    /// to the day like runs), and its observed seconds are not counted: only the day's own observations are.
    static func dayDocumentAndTrack(input: ActivityContextTrackInput, generatedAt: Int,
                                    config: ActivityDecoderConfig = ActivityDecoderConfig(),
                                    lookback: ActivityContextTrackInput? = nil)
        -> (document: ActivityContextDayDocument, track: ActivityContextTrack) {
        let warm = lookback.map { ActivityContextTrackBuilder.build($0, config: config) }
        let seed = (warm?.observedSeconds ?? 0) > 0 ? warm?.snapshot : nil
        let track = ActivityContextTrackBuilder.build(input, config: config, resuming: seed)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: generatedAt,
                                                  config: config, includeSnapshot: false)
        return (clippedToDay(document), track)
    }

    /// The document restricted to its own day `[dayStart, dayEnd)`, the last step of every day decode.
    ///
    /// Runs: a run is stamped one publish interval past its last state, so the run that is still open when
    /// the data reaches midnight would spill into the next UTC day. A day document describes its own day
    /// only; the neighbour's document starts where this one stops.
    ///
    /// Events: the resumed snapshot carries the lookback's recent transition events, and the first in-day
    /// state may re-emit one stamped up to the event hold before midnight. Those belong to the previous day's
    /// document (publish_activity_context_day rejects an event whose `ts` is outside the day), so only the
    /// day's are kept. The filter is on `ts`, the detection second (when the change became known, which is
    /// what a causal reader filters on), not on `onsetTs`: an event detected just after midnight whose onset
    /// was back-dated (at most `ActivityTransitionEvent.maxOnsetLeadS`) into the previous day stays in this
    /// day's document with its onset unchanged, and the server's validator checks only `ts`.
    static func clippedToDay(_ document: ActivityContextDayDocument) -> ActivityContextDayDocument {
        var document = document
        let dayEnd = document.dayEnd, dayStart = document.dayStart
        document.runs = document.runs.compactMap { run in
            var clipped = run
            clipped.end = min(run.end, dayEnd)
            return clipped.end > clipped.start ? clipped : nil
        }
        document.events = document.events.filter { $0.ts >= dayStart && $0.ts < dayEnd }
        document.summary = ActivityContextDaySummary(runs: document.runs)
        return document
    }

    // MARK: - Decoder config and versions (audit D1-01 / D5-12 / D5-03)

    /// How the server derives a day's decoder config from stored data. Part of the registered versions tag, so
    /// changing the recipe re-derives stored days. srv-cfg-1: `ActivityDecoderConfig.personalized` with the
    /// median resting heart rate of the (at most 14) nights before the day in `server_daily_scores`, and the
    /// Tanaka maximum for the wearer's age on the day (the phone's `effortHRmax` without its manual override,
    /// which the server does not store); each missing input keeps the decoder default (rest 60, max 190).
    /// The phone's adopted personal profile and its ElderNet gait pin are not on the server and are not used.
    static let decoderConfigRecipe = "srv-cfg-1"

    /// Nights of resting heart rate the reference reads (the phone reads its latest 14) and how far back.
    static let referenceNights = 14
    static let referenceLookbackDays = 60

    /// The wearer's heart-rate reference as of one day, from server data only, so the same stored day always
    /// decodes with the same config.
    struct DecoderReference: Equatable {
        /// Nightly resting heart rates before the day, oldest first (at most `referenceNights`).
        var restingNights: [Int] = []
        /// The wearer's age on the day, when the profile has a date of birth.
        var ageYears: Int? = nil

        var restingHeartRate: Double? { ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: restingNights) }
        var maxHeartRate: Double? { ageYears.flatMap { $0 > 0 ? StrainScorer.tanakaHRmax(age: Double($0)) : nil } }
        var config: ActivityDecoderConfig {
            .personalized(restingHeartRate: restingHeartRate, maxHeartRate: maxHeartRate)
        }

        /// The provenance the document records.
        func provenance(gaitWindows: Int = 0) -> DecoderConfigProvenance {
            let c = config
            // `personalized` ignores an implausible input, so the source says what the decoder actually used.
            let usedRest = restingHeartRate.map { ActivityDecoderConfig.restingHeartRateBounds.contains($0) } ?? false
            let usedMax = maxHeartRate.map { ActivityDecoderConfig.maxHeartRateBounds.contains($0) } ?? false
            return DecoderConfigProvenance(
                tag: "\(ActivityContextDays.decoderConfigRecipe):\(c.cacheTag)",
                recipe: ActivityContextDays.decoderConfigRecipe,
                restingHeartRate: c.restingHeartRate,
                restingHeartRateSource: usedRest ? "server_daily_scores" : "default",
                restingHeartRateNights: restingNights.count,
                maxHeartRate: c.maxHeartRate,
                maxHeartRateSource: usedMax ? "tanaka_age" : "default",
                gaitWindows: gaitWindows)
        }
    }

    /// The `decoder_config` object of a server day document: which heart-rate reference decoded it and where
    /// each value came from, so a phone/server divergence is visible in the stored row.
    struct DecoderConfigProvenance: Encodable, Equatable {
        var tag: String
        var recipe: String
        var restingHeartRate: Double
        var restingHeartRateSource: String
        var restingHeartRateNights: Int
        var maxHeartRate: Double
        var maxHeartRateSource: String
        /// In-process HART ElderNet gait windows the decode read (channel 4c). The standalone ElderNet stage
        /// (shadow / candidate) never reaches the published decode.
        var gaitWindows: Int

        enum CodingKeys: String, CodingKey {
            case tag, recipe
            case restingHeartRate = "resting_hr", restingHeartRateSource = "resting_hr_source"
            case restingHeartRateNights = "resting_hr_nights"
            case maxHeartRate = "max_hr", maxHeartRateSource = "max_hr_source"
            case gaitWindows = "gait_windows"
        }
    }

    /// The wearer's age in whole years on `day` ("yyyy-MM-dd") for a "yyyy-MM-dd" date of birth.
    static func ageYears(dateOfBirth: String, on day: String) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let dob = f.date(from: String(dateOfBirth.prefix(10))), let on = f.date(from: day), dob <= on else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let years = cal.dateComponents([.year], from: dob, to: on).year, years >= 0 else { return nil }
        return years
    }

    /// The reference for `day` (a UTC job day): the nights scored before it, and the profile's date of birth.
    /// Never throws: an unreadable table leaves the decoder defaults, recorded as such.
    static func loadDecoderReference(db: PostgresClient, userId: String, day: String) -> DecoderReference {
        var reference = DecoderReference()
        if let rows = try? db.isolatingFailures({ try db.query("""
            select round(resting_hr_bpm)::int::text as r from public.server_daily_scores
             where user_id = $1::uuid and algorithm_version = 'frwhoop-server-1'
               and day < $2::date and day >= $2::date - $3::integer and resting_hr_bpm is not null
             order by day desc limit $4::integer
            """, [userId, day, String(referenceLookbackDays), String(referenceNights)]) }) {
            reference.restingNights = rows.compactMap { Int($0["r"] ?? "") }.reversed()
        }
        if let rows = try? db.isolatingFailures({ try db.query(
            "select date_of_birth::text as dob from public.profiles where id = $1::uuid", [userId]) }),
           let dob = rows.first?["dob"], !dob.isEmpty {
            reference.ageYears = ageYears(dateOfBirth: dob, on: day)
        }
        return reference
    }

    /// What this worker build runs for a lane, as `reconcile_activity_context_versions` takes it: the decoder,
    /// ontology and feature schema the stored day documents are compared with, and a tag (folded into the day
    /// fingerprints) that also carries the schema, publish interval, decoder-config recipe, lookback and — for
    /// the raw-IMU lane — the HART model and preprocessing the service reported. `ordinal` is
    /// `versionsOrdinal`: the registry refuses a lower one, so an older build left running during a rolling
    /// deploy cannot take the registration back and re-queue the recent days on every reconcile.
    static func lanesVersions(model: String? = nil, preprocessing: String? = nil) -> [String: String] {
        var parts = ["d=\(ActivityContextVersions.decoder)", "o=\(ActivityContextVersions.ontology)",
                     "f=\(ActivityContextVersions.featureSchema)", "s=\(ActivityContextVersions.schema)",
                     "i=\(ActivityDecoderConfig().publishIntervalS)", "c=\(decoderConfigRecipe)",
                     "l=\(lookbackSeconds)"]
        var out = ["decoder": ActivityContextVersions.decoder, "ontology": ActivityContextVersions.ontology,
                   "feature_schema": ActivityContextVersions.featureSchema,
                   "ordinal": String(versionsOrdinal)]
        if let model, let preprocessing {
            parts += ["m=\(model)", "p=\(preprocessing)"]
            out["model"] = model
            out["preprocessing"] = preprocessing
        }
        out["tag"] = versionsTag(parts)
        return out
    }

    /// Increases whenever a build changes anything the versions tag names (decoder, ontology, feature schema,
    /// document schema, publish interval, decoder-config recipe, lookback). Not part of the tag: equal builds
    /// with different ordinals would otherwise fingerprint differently.
    static let versionsOrdinal = 1

    /// `parts` joined with ';', every character outside the registry's tag alphabet replaced, at most 256.
    static func versionsTag(_ parts: [String]) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:;=+-")
        let joined = parts.joined(separator: ";")
        return String(String(joined.map { allowed.contains($0) ? $0 : "_" }).prefix(256))
    }

    static func versionsJSON(_ versions: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: versions, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Lookback (audit D2-11)

    /// Seconds before a day's start decoded only to warm the decoder up; their states never reach the document.
    static let lookbackSeconds = 1_800

    /// The streams split at the day's start: the day's own samples, and the lookback before it. Wear events keep
    /// their own reach-back in both.
    static func split(_ streams: Streams, at dayStart: Int) -> (day: Streams, lookback: Streams) {
        var day = streams, before = streams
        day.hr = streams.hr.filter { $0.ts >= dayStart }
        day.gravity = streams.gravity.filter { $0.ts >= dayStart }
        day.steps = streams.steps.filter { $0.ts >= dayStart }
        before.hr = streams.hr.filter { $0.ts < dayStart }
        before.gravity = streams.gravity.filter { $0.ts < dayStart }
        before.steps = streams.steps.filter { $0.ts < dayStart }
        return (day, before)
    }

    /// The lookback decode input for `input`: the `lookbackSeconds` before its day, from the same windows and
    /// stored streams, with the same sleep / workout spans; nil when the lookback holds nothing to decode.
    static func lookbackInput(windows: [ActivityPythonService.WindowPrediction], streams: Streams,
                              sleep: [(start: Int, end: Int)], inBed: [(start: Int, end: Int)],
                              exercise: [(start: Int, end: Int, sport: String)],
                              dayStart: Int, sleepKnownOutsideSessions: Bool, encoderVersion: String,
                              transitionVersion: String = "unknown",
                              transitionPreprocessingVersion: String = "unknown",
                              gaitWindows: [ActivityGaitWindow] = []) -> ActivityContextTrackInput? {
        guard !streams.isEmpty else { return nil }
        return trackInput(windows: windows, streams: streams, sleep: sleep, inBed: inBed, exercise: exercise,
                          dayStart: dayStart - lookbackSeconds, dayEnd: dayStart, horizon: dayStart,
                          sleepKnownOutsideSessions: sleepKnownOutsideSessions, encoderVersion: encoderVersion,
                          transitionVersion: transitionVersion,
                          transitionPreprocessingVersion: transitionPreprocessingVersion, gaitWindows: gaitWindows)
    }

    // MARK: - Stream days

    /// The queue lineage of day documents built from stored measurements alone (no raw IMU): the
    /// `algorithm_version` of the `activity_context_jobs` / `activity_context_days` rows and the model and
    /// preprocessing stamps on them. The decoder runs with no encoder windows, exactly like the phone's.
    static let streamsAlgorithmVersion = "streams-activity-1"
    static let streamsModelVersion = "streams-activity-1"
    static let streamsPreprocessingVersion = "streams-v1"

    /// How long after a UTC day ends its time outside logged sleep still counts as "unknown" rather than
    /// "awake". The night that straddles midnight is only logged once the scorer has seen its morning.
    static let streamsSleepSettleSeconds = 12 * 3600

    /// Whether a stored UTC day's time outside logged sleep counts as awake: once the day has been over for
    /// `streamsSleepSettleSeconds`. Shared by the stream-day and the raw-IMU decodes so a day is the same day
    /// whichever lane decoded it.
    /// The database settles a day 10 minutes later (`internal.activity_day_settled`) and folds it into both day
    /// fingerprints, so a day decoded before it settled is queued again, and decoded as settled, once it has.
    static func sleepKnown(now: Int, dayEnd: Int) -> Bool { now >= dayEnd + streamsSleepSettleSeconds }

    enum StreamDayOutcome: Equatable {
        /// A document was stored (its result revision).
        case stored(revision: Int64)
        /// The job completed without a document: the day holds nothing the decoder could describe.
        case empty
        /// The lease or revision moved on; nothing was written and the queue owns the job again.
        case fenced
    }

    /// The day document for a stream-day job, or nil when the stored streams hold nothing to describe.
    /// `now` bounds an open WRIST_OFF span and decides whether the day has been through sleep detection.
    ///
    /// `encoder` is the day's stored HART windows (`activity_encoder_windows`), when the raw-IMU lane has
    /// produced any: the stream day then decodes with the same encoder evidence the phone does.
    ///
    /// `streams` may reach back `lookbackSeconds` before the day (`loadStreams(... lookback: true)`): those
    /// samples only warm the decoder up. `reference` is the wearer's heart-rate reference as of the day.
    static func buildStreamDay(day: String, dayBounds: (start: Int, end: Int), streams loaded: Streams,
                               sleep: [(start: Int, end: Int)], inBed: [(start: Int, end: Int)] = [],
                               exercise: [(start: Int, end: Int, sport: String)],
                               now: Int, encoder: ActivityEncoderWindowSet? = nil,
                               reference: DecoderReference = DecoderReference()) throws -> Built? {
        let (streams, before) = split(loaded, at: dayBounds.start)
        guard !streams.isEmpty else { return nil }
        let known = sleepKnown(now: now, dayEnd: dayBounds.end)
        let lookback = lookbackInput(windows: [], streams: before, sleep: sleep, inBed: inBed, exercise: exercise,
                                     dayStart: dayBounds.start, sleepKnownOutsideSessions: known,
                                     encoderVersion: streamsPreprocessingVersion)
        var input = trackInput(
            windows: [], streams: streams, sleep: sleep, inBed: inBed, exercise: exercise,
            dayStart: dayBounds.start, dayEnd: dayBounds.end, horizon: now,
            sleepKnownOutsideSessions: known,
            encoderVersion: streamsPreprocessingVersion)
        if let encoder, !encoder.isEmpty {
            input.encoderWindows = encoder.windows
            input.imuWindows = encoder.features
            input.encoderId = encoder.encoderId
            input.encoderVersion = encoder.encoderVersion
            // Stored transition-expert output rides the same stored-set path: each window
            // carries its own version stamps, so a stream day decodes with exactly the
            // evidence the raw-IMU lane published for it.
            input.transitionWindows = encoder.transitions
            input.gaitWindows = encoder.gaitWindows
        }
        let built = try build(input: input, day: day, modelVersion: streamsModelVersion,
                              preprocessingVersion: streamsPreprocessingVersion, generatedAt: now,
                              config: reference.config,
                              provenance: reference.provenance(gaitWindows: input.gaitWindows.count),
                              lookback: lookback)
        return (built.runs > 0 || built.events > 0) ? built : nil
    }

    // MARK: - Database

    /// The day's streams, read with the same predicates the scoring lane uses so a sample the scorer sees
    /// is a sample the decoder sees.
    ///
    /// `lookback` also reads the `lookbackSeconds` before the day (heart rate, gravity and steps), for the
    /// decoder warm-up; `split(_:at:)` separates them again.
    static func loadStreams(db: PostgresClient, userId: String, deviceId: String,
                            dayStart: Int, dayEnd: Int, lookback: Bool = false) throws -> Streams {
        let from = lookback ? dayStart - lookbackSeconds : dayStart
        let range = [userId, deviceId, String(from), String(dayEnd)]
        var streams = Streams()

        streams.hr = try db.query("""
            select ts::text, bpm::text from public.noop_hr_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, range).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let bpm = Int(r["bpm"] ?? "") else { return nil }
            return HRSample(ts: ts, bpm: bpm)
        }

        streams.gravity = try db.query("""
            select ts::text, x::text, y::text, z::text, "dynAccel"::text
            from public.noop_gravity_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, range).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""),
                  let x = Double(r["x"] ?? ""), let y = Double(r["y"] ?? ""), let z = Double(r["z"] ?? "")
            else { return nil }
            return GravitySample(ts: ts, x: x, y: y, z: z, dynAccel: Double(r["dynAccel"] ?? ""))
        }

        streams.steps = try db.query("""
            select ts::text, counter::text, coalesce("activityClass"::text,'') as ac
            from public.noop_step_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, range).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let counter = Int(r["counter"] ?? "") else { return nil }
            return StepSample(ts: ts, counter: counter, activityClass: Int(r["ac"] ?? ""))
        }

        streams.events = try db.query("""
            select ts::text, kind from public.noop_events
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
              and (starts_with(kind, 'WRIST_OFF') or starts_with(kind, 'WRIST_ON'))
            order by ts
            """, [userId, deviceId, String(dayStart - eventReachBackSeconds), String(dayEnd)]).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let kind = r["kind"], !kind.isEmpty else { return nil }
            return WhoopEvent(ts: ts, kind: kind, payload: [:])
        }
        return streams
    }

    /// Write the day document through the fenced RPC. Runs under a savepoint when a transaction is open,
    /// so a rejection (or a database that has not had the migration applied yet) leaves the transaction
    /// usable for the v1 publish that follows. Only a lost connection propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64,
                        payload: String) throws -> PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(
                    "SELECT public.publish_activity_context_day($1::uuid,$2::bigint,$3::jsonb)::text",
                    [token, String(revision), payload])
            }
            if let stored = Int64(out ?? ""), stored > 0 { return .stored(revision: stored) }
            return .fenced
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return .rejected(safeReason(error))
        }
    }

    /// Complete a stream-day job in one short transaction: the fenced RPC validates and stores the document
    /// (when there is one) and completes the job together. A rejected document raises, which completes
    /// nothing, so the caller settles it as a failure with backoff.
    static func completeStreamDay(db: PostgresClient, token: String, revision: Int64,
                                  payload: String?, durationMS: Int) throws -> StreamDayOutcome {
        let out = try db.callFunctionForJSON(
            "SELECT public.complete_activity_stream_day($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
            [token, String(revision), payload ?? "null", String(max(0, durationMS))])
        guard let stored = Int64(out ?? "") else { return .fenced }
        return stored > 0 ? .stored(revision: stored) : .empty
    }

    /// A one-line reason fit for counters and logs. Postgres appends DETAIL/CONTEXT lines to its
    /// message, and for a constraint failure those echo the offending row — the whole health document —
    /// so only the first line and the SQLSTATE are kept.
    static func safeReason(_ error: Error) -> String {
        if let pg = error as? PostgresClient.Error {
            let first = pg.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? "database error"
            return String("\(first) [sqlstate=\(pg.sqlstate ?? "-")]".prefix(240))
        }
        return String(String(describing: error).prefix(240))
    }
}
