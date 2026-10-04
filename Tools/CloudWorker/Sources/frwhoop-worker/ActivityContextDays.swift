import Foundation
import StrandAnalytics
import WhoopProtocol

/// ActivityContext v2 on the server: the activity lane's HART (or baseline) window probabilities and
/// the per-window `imu-feat-1` IMU features go through the SAME decoder the app runs
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
    /// they are laid out the way this build's decoder reads them (`ActivityContextVersions.featureSchema`).
    /// A service that renames or rescales a feature must not feed shifted numbers into the decoder.
    static func windowsWithCompatibleFeatures(
        _ result: ActivityPythonService.InferResult) -> [ActivityPythonService.WindowPrediction] {
        if result.featureSchema == ActivityContextVersions.featureSchema { return result.windows }
        return result.windows.map { w in
            var stripped = w
            stripped.features = [:]
            return stripped
        }
    }

    /// One service window's IMU facts, or nil when the service did not send the required ones (an older
    /// serve.py without `feat`, or a window whose features were not computable).
    static func imuFeatures(_ w: ActivityPythonService.WindowPrediction) -> ImuWindowFeatures? {
        guard w.start.isFinite, w.end.isFinite, abs(w.start) < 1e12, abs(w.end) < 1e12 else { return nil }
        let f = w.features
        guard let accel = f["accel_rms_g"], let gyro = f["gyro_rms_dps"], let jerk = f["jerk_rms"],
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
            probs: w.probs, baseline: w.baseline)
    }

    /// The decoder input for one job day. Sleep outside logged sessions stays "unknown" on the server
    /// unless the caller says the day has been through sleep detection (`sleepKnownOutsideSessions`):
    /// the detector may not have run over a stretch yet, and stillness alone never means asleep.
    ///
    /// `horizon` is how far the day has actually happened (`now` for the UTC day in progress, the day's end
    /// for a finished one). A WRIST_OFF with no WRIST_ON yet stays open only up to it: the decoder emits an
    /// "off wrist" second for every second of an off-wrist span, so an unbounded tail would describe the
    /// rest of today as already over.
    static func trackInput(windows: [ActivityPythonService.WindowPrediction], streams: Streams,
                           sleep: [(start: Int, end: Int)], exercise: [(start: Int, end: Int)],
                           dayStart: Int, dayEnd: Int, horizon: Int? = nil,
                           encoderVersion: String,
                           sleepKnownOutsideSessions: Bool = false) -> ActivityContextTrackInput {
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
            sleepKnownOutsideSessions: sleepKnownOutsideSessions,
            workouts: exercise.map { DayStateWorkout(start: $0.start, end: $0.end, sport: "") },
            offWrist: offWrist,
            encoderWindows: windows.compactMap(encoderWindow),
            encoderId: encoderId, encoderVersion: encoderVersion,
            imuWindows: windows.compactMap(imuFeatures))
    }

    private struct Envelope: Encodable {
        var day: String
        var modelVersion: String
        var preprocessingVersion: String
        var document: ActivityContextDayDocument

        enum CodingKeys: String, CodingKey {
            case day, document
            case modelVersion = "model_version", preprocessingVersion = "preprocessing_version"
        }
    }

    /// Decode the day and encode the RPC payload. The decoder snapshot is left out: the server recomputes
    /// the whole day from stored inputs every time a job runs, so the snapshot would only add weight.
    static func build(input: ActivityContextTrackInput, day: String, modelVersion: String,
                      preprocessingVersion: String, generatedAt: Int,
                      config: ActivityDecoderConfig = ActivityDecoderConfig()) throws -> Built {
        let track = ActivityContextTrackBuilder.build(input, config: config)
        var document = ActivityContextDayDocument(track: track, input: input, generatedAt: generatedAt,
                                                  config: config, includeSnapshot: false)
        // A run is stamped one publish interval past its last state, so the run that is still open when
        // the data reaches midnight would spill into the next UTC day. A day document describes its own
        // day only; the neighbour's document starts where this one stops.
        document.runs = document.runs.compactMap { run in
            var clipped = run
            clipped.end = min(run.end, input.dayEnd)
            return clipped.end > clipped.start ? clipped : nil
        }
        document.summary = ActivityContextDaySummary(runs: document.runs)
        let envelope = Envelope(day: day, modelVersion: modelVersion,
                                preprocessingVersion: preprocessingVersion, document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("activity day document encoding failed")
        }
        return Built(payloadText: text, runs: document.runs.count, events: document.events.count,
                     observedSeconds: document.observedSeconds)
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
    static func buildStreamDay(day: String, dayBounds: (start: Int, end: Int), streams: Streams,
                               sleep: [(start: Int, end: Int)], exercise: [(start: Int, end: Int)],
                               now: Int) throws -> Built? {
        guard !streams.isEmpty else { return nil }
        let input = trackInput(
            windows: [], streams: streams, sleep: sleep, exercise: exercise,
            dayStart: dayBounds.start, dayEnd: dayBounds.end, horizon: now,
            encoderVersion: streamsPreprocessingVersion,
            sleepKnownOutsideSessions: now >= dayBounds.end + streamsSleepSettleSeconds)
        let built = try build(input: input, day: day, modelVersion: streamsModelVersion,
                              preprocessingVersion: streamsPreprocessingVersion, generatedAt: now)
        return (built.runs > 0 || built.events > 0) ? built : nil
    }

    // MARK: - Database

    /// The day's streams, read with the same predicates the scoring lane uses so a sample the scorer sees
    /// is a sample the decoder sees.
    static func loadStreams(db: PostgresClient, userId: String, deviceId: String,
                            dayStart: Int, dayEnd: Int) throws -> Streams {
        let range = [userId, deviceId, String(dayStart), String(dayEnd)]
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
