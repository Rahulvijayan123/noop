import Foundation
import StrandAnalytics
import WhoopProtocol

/// The inputs of one physiology-context job (docs/physiology-context/contracts.md §7.2): what is read, from
/// where, and how it becomes a `PhysiologyContext.DayInput` / `HistoryInput`.
///
/// Two halves:
///  - `load` runs the reads (`ContextSQL`) inside ONE read-only REPEATABLE READ transaction, so every table is
///    read at the same snapshot. Optional products (activity documents, exposures, history) are read under a
///    savepoint: a missing table or a failing read leaves that input empty and is reported, never fatal.
///  - `assemble` is pure: the causal restriction, R-R transport selection, the series recomputation and the
///    mapping of every product to a `MeasurementInput` with its ACTUAL support interval. It reads no clock, so
///    equal loaded rows give equal inputs (and therefore byte-identical documents, `Engine.buildDay`).
///
/// Ordering is deterministic end to end: every query orders by the table's identity and every Swift-side
/// collection is sorted by a total key before it reaches the engine.
enum ContextInputs {
    typealias PC = PhysiologyContext

    /// Scoring lineage the lane reads (the only v2 algorithm in production).
    static let scoringAlgorithmVersion = "frwhoop-server-1"
    /// Detector stamp on sleep sessions read from scoring snapshots.
    static let sleepDetector = "frwhoop-server-1"

    // MARK: - Job

    struct Job: Equatable {
        var userId: String
        var deviceId: String
        var day: String
        var mode: PC.ProcessingMode
        var inputRevision: Int64
        var leaseToken: String
        var timezoneId: String
        /// Replay cutoff for a causal job (unix seconds); nil for a normal job.
        var cutoffOverride: Int?
        /// Database clock at the claim (unix seconds).
        var claimedAt: Int
        /// The queue's own `[local midnight, next local midnight)` for the day, when the claim returned it.
        var queueDayWindow: PC.Interval? = nil

        /// contracts §7.3: `causal_live` decides at the claim time, or at `cutoff_override` for a replay;
        /// `retrospective` uses the claim time (and every input stored by then).
        var cutoff: Int {
            mode == .causalLive ? (cutoffOverride ?? claimedAt) : claimedAt
        }
        /// When the document was produced (the claim time, never the replay cutoff).
        var generatedAt: Int { claimedAt }
    }

    /// A claim row → a job, or nil when it cannot be interpreted (the lane then settles it as a failure).
    static func parseJob(_ r: [String: String]) -> Job? {
        let uid = r["user_id"] ?? "", dev = r["device_id"] ?? "", day = r["day"] ?? ""
        let token = r["lease_token"] ?? ""
        guard !uid.isEmpty, !dev.isEmpty, isDayKey(day), !token.isEmpty,
              let mode = PC.ProcessingMode(rawValue: r["mode"] ?? ""),
              let revision = Int64(r["input_revision"] ?? ""), revision > 0,
              let claimedAt = Int(r["claimed_at"] ?? "") else { return nil }
        let tzRaw = (r["timezone_id"] ?? "").trimmingCharacters(in: .whitespaces)
        let tz = (!tzRaw.isEmpty && TimeZone(identifier: tzRaw) != nil) ? tzRaw : "UTC"
        let override = Int(r["cutoff_override"] ?? "")
        var queueWindow: PC.Interval?
        if let s = Int(r["day_start"] ?? ""), let e = Int(r["day_end"] ?? ""), e > s { queueWindow = PC.Interval(s, e) }
        return Job(userId: uid, deviceId: dev, day: day, mode: mode, inputRevision: revision,
                   leaseToken: token, timezoneId: tz, cutoffOverride: override, claimedAt: claimedAt,
                   queueDayWindow: queueWindow)
    }

    static func isDayKey(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Windows

    struct Windows: Equatable {
        var day: String
        var timezoneId: String
        /// `[local midnight, next local midnight)` (DST-correct).
        var dayWindow: PC.Interval
        /// Raw streams and activity: `[dayStart − 30 h, dayEnd + 6 h)` (`DayInput` contract).
        var read: PC.Interval
        /// Exposure occurrences: `[start of D−4, end of D+1)`.
        var exposure: PC.Interval
        var historyFrom: String   // D−160 (`historyDays`)
        var boutsFrom: String     // D−3
        var priorSleepFrom: String // D−14
        var previousDay: String   // D−1
        var nextDay: String       // D+1
        /// UTC calendar days the read window touches (activity day documents are per UTC day).
        var utcFrom: String
        var utcTo: String
    }

    static let lookbackS = 30 * 3_600
    static let lookaheadS = 6 * 3_600
    /// Days of daily-value history the change detector needs for a full burn-in (review R-F2), `historyDays(for:)`
    /// of the default policy: 160.
    static let historyDays = ContextInputs.historyDays(for: .default)
    static let boutHistoryDays = 3
    static let priorSleepNights = 14
    static let exposureLookbackDays = 4
    static let exposureLookaheadDays = 1

    /// Daily-value history for one document (review R-F2). `ChangeDetection.episodes` scores the trailing
    /// `windowDays` (90) and every scored day needs its own lookback: the rolling reference
    /// (`rollingWindowDays`, 28) and the lag-1 autocorrelation (`autocorrelationWindowDays`, 56, before an
    /// `autocorrelationGuardDays`, 14, guard). With only 90 days the first ~34 scored days had no φ̂ and ran the
    /// CUSUM unadjusted, which is not the evaluated detector. 90 + max(28, 14 + 56) = 160 days (D−160 … D−1) gives
    /// the oldest scored day (D−90) its full lookback. Derived from the policy so a tuning change moves the load
    /// with it.
    static func historyDays(for policy: PC.Policy) -> Int {
        let change = policy.change
        let lookback = change.cusumAutocorrelationAdjustment
            ? max(policy.reference.rollingWindowDays,
                  change.autocorrelationGuardDays + change.autocorrelationWindowDays)
            : policy.reference.rollingWindowDays
        return max(1, change.windowDays) + max(0, lookback)
    }

    static func windows(day: String, timezoneId: String,
                        historyDays: Int = ContextInputs.historyDays) -> Windows? {
        guard let tz = TimeZone(identifier: timezoneId), let start = DayScorer.dayStartUnix(day, tz: tz) else {
            return nil
        }
        let end = DayScorer.nextDayStartUnix(after: start, tz: tz)
        guard end > start, let dMinus4 = shiftDay(day, by: -exposureLookbackDays),
              let dPlus1 = shiftDay(day, by: exposureLookaheadDays),
              let exposureStart = DayScorer.dayStartUnix(dMinus4, tz: tz),
              let plus1Start = DayScorer.dayStartUnix(dPlus1, tz: tz),
              let historyFrom = shiftDay(day, by: -historyDays), let boutsFrom = shiftDay(day, by: -boutHistoryDays),
              let priorSleepFrom = shiftDay(day, by: -priorSleepNights),
              let previous = shiftDay(day, by: -1), let next = shiftDay(day, by: 1) else { return nil }
        let exposureEnd = DayScorer.nextDayStartUnix(after: plus1Start, tz: tz)
        let read = PC.Interval(start - lookbackS, end + lookaheadS)
        return Windows(day: day, timezoneId: timezoneId, dayWindow: PC.Interval(start, end), read: read,
                       exposure: PC.Interval(exposureStart, exposureEnd), historyFrom: historyFrom,
                       boutsFrom: boutsFrom, priorSleepFrom: priorSleepFrom, previousDay: previous, nextDay: next,
                       utcFrom: utcDay(read.start), utcTo: utcDay(read.end - 1))
    }

    /// Calendar-day arithmetic on a `yyyy-MM-dd` key (zone-independent).
    static func shiftDay(_ day: String, by days: Int) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              let s = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: s)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func utcDay(_ ts: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Loaded rows

    /// A skin-temperature row before the device-family conversion.
    struct SkinRow: Equatable { var ts: Int; var raw: Int; var availableAt: Int? }

    struct DeviceRow: Equatable {
        var family: String?
        var firmware: String?
        var sourceKind: String?
    }

    struct ProfileRow: Equatable {
        var heightCm: Double?
        var weightKg: Double?
        var dateOfBirth: String?
        var sexModel: String
    }

    /// One published scoring snapshot, reduced to what the context layer reads.
    struct Snapshot: Equatable {
        struct Session: Equatable {
            var id: String
            var start: Int
            var end: Int
            var isNap: Bool?
            var efficiency: Double?
            var stages: [StageSegment]
        }
        var day: String
        var resultRevision: Int64
        var inputRevision: Int64
        /// `ceil(computed_at)`: when this snapshot (and the sessions/values in it) became available.
        var availableAt: Int
        var status: String?
        /// The snapshot's `dataThrough` (unix seconds) and `timezone`.
        var dataThrough: Int? = nil
        var timezone: String? = nil
        var sessions: [Session]
        /// Nightly `daily.<field>` values (only numeric, finite ones).
        var values: [String: Double]
        var restingHRInt: Int?
    }

    /// Everything one job read. Plain rows: the pure `assemble` step turns them into engine inputs.
    struct Loaded {
        var heartRate: [PC.HeartRateObservation] = []
        var beatIntervals: [PC.BeatIntervalObservation] = []
        var motion: [PC.MotionObservation] = []
        var steps: [PC.StepObservation] = []
        var skin: [SkinRow] = []
        var wearEvents: [PC.WearEventObservation] = []
        var bandSleep: [PC.BandSleepStateObservation] = []
        var snapshot: Snapshot?
        /// The sleep of the newest snapshot of every other day in D−14 … D+1 (sessions only; values unused).
        var otherSnapshots: [Snapshot] = []
        var workouts: [PC.WorkoutInput] = []
        var epochs: [PC.ActivityEpochInput] = []
        var intervals: [PC.ActivityIntervalInput] = []
        var placements: [PC.PlacementInput] = []
        var device: DeviceRow?
        var profile: ProfileRow?
        var exposures: [PC.ExposureEventRevision] = []
        var historyValues: [PC.DailyValue] = []
        var historyBouts: [PC.ExertionBout] = []
        var frozen: [PC.FrozenReference] = []
        /// Optional inputs that could not be read (`activity_epochs_unavailable`, ...), sorted.
        var unavailable: [String] = []
        /// Stored rows that did not decode into the contract types (skipped, counted).
        var skippedRows = 0
        /// Causal jobs: history rows in the read ranges whose current publication is after the cutoff (not read;
        /// telemetry only, `ContextSQL.historyAfterCutoff`).
        var historyAfterCutoff = 0

        /// Every collection in one total order over its content. The SQL already orders by identity; this makes
        /// `assemble` independent of how the rows arrived (and is linear on already-sorted input).
        func normalized() -> Loaded {
            var l = self
            l.heartRate.sort { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
            l.beatIntervals.sort { ($0.ts, $0.seq, $0.rrMs, $0.channel ?? -1, $0.ord ?? -1) <
                                   ($1.ts, $1.seq, $1.rrMs, $1.channel ?? -1, $1.ord ?? -1) }
            l.motion.sort { $0.ts < $1.ts }
            l.steps.sort { ($0.ts, $0.counter) < ($1.ts, $1.counter) }
            l.skin.sort { ($0.ts, $0.raw) < ($1.ts, $1.raw) }
            l.wearEvents.sort { ($0.ts, $0.kind) < ($1.ts, $1.kind) }
            l.bandSleep.sort { ($0.ts, $0.state) < ($1.ts, $1.state) }
            l.workouts.sort { ($0.interval, $0.id) < ($1.interval, $1.id) }
            l.epochs.sort { ($0.epoch.startTs, $0.revision, $0.epoch.endTs) < ($1.epoch.startTs, $1.revision, $1.epoch.endTs) }
            l.intervals.sort { ($0.interval, $0.revision, $0.activityClass) < ($1.interval, $1.revision, $1.activityClass) }
            l.placements.sort { a, b in
                let ka = (a.start, a.end ?? Int.max, a.revision, a.recordedAt ?? -1, a.placement, a.source)
                let kb = (b.start, b.end ?? Int.max, b.revision, b.recordedAt ?? -1, b.placement, b.source)
                return ka != kb ? ka < kb : (a.scope ?? "") < (b.scope ?? "")
            }
            l.exposures.sort { ($0.eventId, $0.revision) < ($1.eventId, $1.revision) }
            l.otherSnapshots.sort { ($0.day, $0.resultRevision) < ($1.day, $1.resultRevision) }
            return l
        }

        var rowCount: Int {
            heartRate.count + beatIntervals.count + motion.count + steps.count + skin.count + wearEvents.count
                + bandSleep.count + workouts.count + epochs.count + intervals.count + placements.count
                + exposures.count + historyValues.count + historyBouts.count + frozen.count
                + otherSnapshots.count + (snapshot == nil ? 0 : 1)
        }
    }

    // MARK: - Load (one consistent read-only snapshot)

    static func load(db: PostgresClient, job: Job, windows w: Windows) throws -> Loaded {
        try db.beginTransaction(.repeatableRead)
        do {
            try db.exec("SET TRANSACTION READ ONLY")
            let out = try loadRows(db: db, job: job, windows: w)
            try db.commitTransaction()
            return out
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    private static func loadRows(db: PostgresClient, job: Job, windows w: Windows) throws -> Loaded {
        var out = Loaded()
        let scope = [job.userId, job.deviceId]
        let read = scope + [String(w.read.start), String(w.read.end)]

        // Raw streams (required: a failure ends the job and is retried).
        out.heartRate = try db.query(ContextSQL.heartRate, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let bpm = Int(r["bpm"] ?? "") else { return nil }
            return PC.HeartRateObservation(ts: ts, bpm: bpm, availableAt: Int(r["at"] ?? ""))
        }
        out.beatIntervals = try db.query(ContextSQL.beatIntervals, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let rr = Int(r["rr"] ?? "") else { return nil }
            return PC.BeatIntervalObservation(ts: ts, rrMs: rr, seq: Int(r["seq"] ?? "") ?? 0,
                                              ord: Int(r["ord"] ?? ""), channel: Int(r["ch"] ?? ""),
                                              availableAt: Int(r["at"] ?? ""))
        }
        out.motion = try db.query(ContextSQL.gravity, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? "") else { return nil }
            return PC.MotionObservation(ts: ts, dynAccelG: Double(r["dyn"] ?? ""), x: Double(r["x"] ?? ""),
                                        y: Double(r["y"] ?? ""), z: Double(r["z"] ?? ""),
                                        availableAt: Int(r["at"] ?? ""))
        }
        out.steps = try db.query(ContextSQL.steps, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let counter = Int(r["counter"] ?? "") else { return nil }
            return PC.StepObservation(ts: ts, counter: counter, activityClass: Int(r["ac"] ?? ""),
                                      availableAt: Int(r["at"] ?? ""))
        }
        out.skin = try db.query(ContextSQL.skinTemperature, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let raw = Int(r["raw"] ?? "") else { return nil }
            return SkinRow(ts: ts, raw: raw, availableAt: Int(r["at"] ?? ""))
        }
        out.wearEvents = try db.query(ContextSQL.wearEvents, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let kind = r["kind"], !kind.isEmpty else { return nil }
            let state: PC.WearEventState = kind.hasPrefix("WRIST_OFF") ? .offWrist : .onWrist
            return PC.WearEventObservation(ts: ts, state: state, kind: kind, availableAt: Int(r["at"] ?? ""))
        }
        out.bandSleep = try db.query(ContextSQL.bandSleepState, read).compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let state = Int(r["state"] ?? "") else { return nil }
            return PC.BandSleepStateObservation(ts: ts, state: state, availableAt: Int(r["at"] ?? ""))
        }

        // The day's snapshot (required table; an absent row is a valid "no snapshot yet").
        let snapRows = try db.query(ContextSQL.latestSnapshot,
                                    scope + [job.day, scoringAlgorithmVersion, String(job.cutoff)])
        if let r = snapRows.first {
            out.snapshot = parseSnapshot(day: job.day, payloadText: r["payload"] ?? "",
                                         resultRevision: Int64(r["result_revision"] ?? "") ?? 0,
                                         inputRevision: Int64(r["input_revision"] ?? "") ?? 0,
                                         availableAt: Int(r["at"] ?? "") ?? job.cutoff)
            if out.snapshot == nil { out.skippedRows += 1 }
        }
        let others = try db.query(ContextSQL.snapshotSleepRange,
                                  scope + [w.priorSleepFrom, w.nextDay, scoringAlgorithmVersion,
                                           String(job.cutoff), job.day])
        for r in others {
            let day = r["day"] ?? ""
            guard var s = parseSnapshot(day: day, payloadText: "{\"sleep\":\(r["sleep"] ?? "[]")}",
                                        resultRevision: Int64(r["result_revision"] ?? "") ?? 0,
                                        inputRevision: 0, availableAt: Int(r["at"] ?? "") ?? job.cutoff)
            else { out.skippedRows += 1; continue }
            s.dataThrough = nonEmpty(r["data_through"]).flatMap(parseInstant)
            s.timezone = nonEmpty(r["timezone"])
            out.otherSnapshots.append(s)
        }

        if let r = try db.query(ContextSQL.device, [job.deviceId, job.userId]).first {
            out.device = DeviceRow(family: nonEmpty(r["family"]), firmware: nonEmpty(r["firmware"]),
                                   sourceKind: nonEmpty(r["source_kind"]))
        }
        if let r = try db.query(ContextSQL.profile, [job.userId]).first {
            out.profile = ProfileRow(heightCm: Double(r["h"] ?? ""), weightKg: Double(r["w"] ?? ""),
                                     dateOfBirth: nonEmpty(r["dob"]), sexModel: nonEmpty(r["sex"]) ?? "nonbinary")
        }
        out.workouts = try db.query(ContextSQL.workouts, read).compactMap { r in
            guard let id = nonEmpty(r["id"]), let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s else {
                return nil
            }
            return PC.WorkoutInput(id: id, interval: PC.Interval(s, e), kind: nonEmpty(r["label"]),
                                   source: r["kind"] == "manual_workout" ? "manual" : "detected",
                                   availableAt: Int(r["at"] ?? ""))
        }

        // Optional products: each under a savepoint, so a missing table only empties that input. Any other failure
        // (a lock or statement timeout, a lost connection) ends the job, which the queue retries with backoff.
        func optional<T>(_ name: String, _ body: () throws -> T) throws -> T? {
            try optionalRead(name, unavailable: &out.unavailable) { try db.isolatingFailures(body) }
        }
        out.epochs = try optional("activity_epochs_unavailable") {
            try db.query(ContextSQL.activityEpochs, read).compactMap(parseEpoch)
        } ?? []
        out.intervals = try optional("activity_days_unavailable") {
            try db.query(ContextSQL.activityRuns, read + [w.utcFrom, w.utcTo]).compactMap(parseRun)
        } ?? []
        out.placements = try optional("placement_unavailable") {
            try db.query(ContextSQL.placements, read).compactMap(parsePlacement)
        } ?? []
        var skipped = 0
        out.exposures = try optional("exposures_unavailable") {
            try db.query(ContextSQL.exposureRevisions,
                         [job.userId, String(w.exposure.start), String(w.exposure.end)]).compactMap { r in
                let parsed = parseExposure(r)
                if parsed == nil { skipped += 1 }
                return parsed
            }
        } ?? []
        let mode = job.mode.rawValue
        let historyCutoff = historyCutoffParameter(job)
        out.historyValues = try optional("history_daily_values_unavailable") {
            try db.query(ContextSQL.historyDailyValues,
                         scope + [mode, w.historyFrom, w.previousDay, historyCutoff]).compactMap {
                let v: PC.DailyValue? = decodeStored($0["value"])
                if v == nil { skipped += 1 }
                return v
            }
        } ?? []
        out.historyBouts = try optional("history_bouts_unavailable") {
            try db.query(ContextSQL.historyBouts,
                         scope + [mode, w.boutsFrom, w.previousDay, historyCutoff]).compactMap {
                let v: PC.ExertionBout? = decodeStored($0["bout"])
                if v == nil { skipped += 1 }
                return v
            }
        } ?? []
        out.frozen = try optional("frozen_references_unavailable") {
            try db.query(ContextSQL.frozenReferences, scope + [historyCutoff]).compactMap {
                let v: PC.FrozenReference? = decodeStored($0["reference"])
                if v == nil { skipped += 1 }
                return v
            }
        } ?? []
        if !historyCutoff.isEmpty {
            // Telemetry only: a failure leaves the count at 0 and marks no input unavailable.
            let n = try? db.isolatingFailures {
                try db.query(ContextSQL.historyAfterCutoff,
                             scope + [mode, w.historyFrom, w.previousDay, historyCutoff, w.boutsFrom]).first?["n"]
            }
            out.historyAfterCutoff = n.flatMap { Int($0) } ?? 0
        }
        out.skippedRows += skipped
        out.unavailable.sort()
        return out
    }

    /// One optional input read (review R1, lead addendum). Only a schema object that does not exist — the worker
    /// deployed before (part of) the migration — makes the input "unavailable": the read returns nil and `name` is
    /// recorded (it reaches `inputRevisions`, and the document says the input was missing). Every other error is a
    /// failure of THIS job and is rethrown: a lock or statement timeout, a serialization failure or a lost
    /// connection must not publish a degraded document as if it were complete (references `insufficient`, episodes
    /// replaced by `insufficient_evidence`) and leave the job done. The lane settles it through
    /// `fail_physiology_context_v1`, which retries with backoff.
    static func optionalRead<T>(_ name: String, unavailable: inout [String], _ read: () throws -> T) throws -> T? {
        do {
            return try read()
        } catch {
            guard isMissingSchemaObject(error) else { throw error }
            unavailable.append(name)
            return nil
        }
    }

    /// SQLSTATE 42P01 undefined_table, 42883 undefined_function, 42703 undefined_column: the object the read names
    /// is not installed (an older schema). Deterministic for this deployment, so not worth a retry.
    static let missingSchemaObjectStates: Set<String> = ["42P01", "42883", "42703"]

    static func isMissingSchemaObject(_ error: Error) -> Bool {
        guard let e = error as? PostgresClient.Error, let state = e.sqlstate else { return false }
        return missingSchemaObjectStates.contains(state)
    }

    /// The publication cutoff of the history reads (`$6` of the daily-value and bout queries, `$3` of the frozen
    /// references): a causal decision reads only history published (references: registered) by its cutoff; a
    /// retrospective one reads it all — every frozen reference registered for the device included, so the engine
    /// scores against the registered reference and a back-filled day never registers a second one. "" = no cutoff.
    static func historyCutoffParameter(_ job: Job) -> String {
        job.mode == .causalLive ? String(job.cutoff) : ""
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func decodeStored<T: Decodable>(_ text: String?) -> T? {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? PC.decoder().decode(T.self, from: data)
    }

    // MARK: - Row parsers (pure)

    static func parseEpoch(_ r: [String: String]) -> PC.ActivityEpochInput? {
        guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s,
              let revision = Int(r["revision"] ?? "") else { return nil }
        let epoch = ActivityEpoch(
            startTs: s, endTs: e,
            motion: MotionLabel(rawValue: r["motion_label"] ?? "") ?? .unknown,
            posture: PostureLabel(rawValue: r["posture"] ?? "") ?? .unknown,
            exercise: ExerciseState(rawValue: r["exercise_session"] ?? "") ?? .unknown,
            sleepState: SleepStateLabel(rawValue: r["sleep_state"] ?? "") ?? .unknown,
            exertion: ExertionContext(rawValue: r["exertion_context"] ?? "") ?? .unknown,
            wear: WearState(rawValue: r["wear_state"] ?? "") ?? .unknown,
            confidence: Double(r["confidence"] ?? "") ?? 0,
            observedS: Int(r["observed_s"] ?? "") ?? 0,
            validS: Int(r["valid_s"] ?? "") ?? 0)
        return PC.ActivityEpochInput(epoch: epoch, revision: revision, availableAt: Int(r["at"] ?? ""))
    }

    static func parseRun(_ r: [String: String]) -> PC.ActivityIntervalInput? {
        guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s,
              let revision = Int(r["revision"] ?? "") else { return nil }
        let confidence = Double(r["confidence"] ?? "").map { min(1, max(0, $0)) } ?? 0
        return PC.ActivityIntervalInput(interval: PC.Interval(s, e), activityClass: nonEmpty(r["class"]) ?? "unknown",
                                        confidence: confidence, sleep: nonEmpty(r["sleep"]),
                                        wear: nonEmpty(r["wear"]), revision: revision,
                                        availableAt: Int(r["at"] ?? ""))
    }

    /// Scope of a placement record (review RC-17): `device` when the row names the device, `account` for the
    /// owner's device-less (user-level) declaration. The engine lets a device record win where the two overlap,
    /// as the app's `PlacementStore` does; revision order only decides within one scope.
    static let devicePlacementScope = "device"
    static let accountPlacementScope = "account"

    static func parsePlacement(_ r: [String: String]) -> PC.PlacementInput? {
        guard let s = Int(r["s"] ?? ""), let placement = nonEmpty(r["placement"]),
              let revision = Int(r["revision"] ?? "") else { return nil }
        let end = Int(r["e"] ?? "")
        if let end, end <= s { return nil }
        let scope = r["user_level"] == "true" ? accountPlacementScope : devicePlacementScope
        return PC.PlacementInput(start: s, end: end, placement: placement, source: nonEmpty(r["source"]) ?? "user",
                                 revision: revision, recordedAt: Int(r["at"] ?? ""), scope: scope)
    }

    static func parseExposure(_ r: [String: String]) -> PC.ExposureEventRevision? {
        guard let id = nonEmpty(r["event_id"]), let revision = Int(r["revision"] ?? ""),
              let kind = PC.ExposureKind(rawValue: r["kind"] ?? ""),
              let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s,
              let precision = PC.TimePrecision(rawValue: r["time_precision"] ?? ""),
              let recordedAt = Int(r["recorded_at"] ?? ""),
              let source = PC.ExposureSource(rawValue: r["source"] ?? ""),
              let confirmation = PC.ExposureConfirmation(rawValue: r["confirmation"] ?? "") else { return nil }
        return PC.ExposureEventRevision(
            eventId: id, revision: revision, kind: kind, label: r["label"] ?? "", occurred: PC.Interval(s, e),
            timePrecision: precision, recordedAt: recordedAt, receivedAt: Int(r["received_at"] ?? ""),
            source: source, confirmation: confirmation, doseAmount: Double(r["dose_amount"] ?? ""),
            doseUnit: nonEmpty(r["dose_unit"]), doseProvenance: nonEmpty(r["dose_provenance"]))
    }

    /// The snapshot payload fields the layer reads. Nil when the payload is not a JSON object.
    static func parseSnapshot(day: String, payloadText: String, resultRevision: Int64, inputRevision: Int64,
                              availableAt: Int) -> Snapshot? {
        guard let data = payloadText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var sessions: [Snapshot.Session] = []
        for case let s as [String: Any] in (obj["sleep"] as? [Any]) ?? [] {
            guard let start = (s["start_at"] as? String).flatMap(parseInstant),
                  let end = (s["end_at"] as? String).flatMap(parseInstant), end > start else { continue }
            let id = (s["id"] as? String).flatMap(nonEmpty) ?? "sleep-\(start)"
            var stages: [StageSegment] = []
            for case let g as [String: Any] in (s["stages"] as? [Any]) ?? [] {
                guard let a = number(g["start"]).map({ Int($0) }), let b = number(g["end"]).map({ Int($0) }),
                      b > a, let stage = g["stage"] as? String else { continue }
                stages.append(StageSegment(start: a, end: b, stage: stage))
            }
            stages.sort { ($0.start, $0.end, $0.stage) < ($1.start, $1.end, $1.stage) }
            // The scorer writes `is_nap: false` for every night (`legacyNights`), so only `true` is information.
            sessions.append(Snapshot.Session(id: id, start: start, end: end,
                                             isNap: (s["is_nap"] as? Bool) == true ? true : nil,
                                             efficiency: number(s["efficiency"]).flatMap(finite),
                                             stages: stages))
        }
        sessions.sort { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var values: [String: Double] = [:]
        var restingInt: Int?
        if let daily = obj["daily"] as? [String: Any] {
            for key in nightlyFields.map(\.field) + ["spo2_candidate_samples"] {
                if let v = number(daily[key]).flatMap(finite) { values[key] = v }
            }
            restingInt = values["resting_hr_bpm"].map { Int($0.rounded()) }
        }
        return Snapshot(day: day, resultRevision: resultRevision, inputRevision: inputRevision,
                        availableAt: availableAt, status: obj["status"] as? String,
                        dataThrough: (obj["dataThrough"] as? String).flatMap(parseInstant)
                            ?? number(obj["dataThrough"]).map { Int($0) },
                        timezone: (obj["timezone"] as? String).flatMap(nonEmpty),
                        sessions: sessions, values: values, restingHRInt: restingInt)
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    static func finite(_ d: Double) -> Double? { d.isFinite ? d : nil }

    /// `yyyy-MM-dd'T'HH:mm:ss(.SSS)Z` (and offsets) → unix seconds.
    static func parseInstant(_ text: String) -> Int? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return Int(d.timeIntervalSince1970) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: text) { return Int(d.timeIntervalSince1970.rounded(.down)) }
        return nil
    }

    // MARK: - Measurement methods (contracts §7.2: the ACTUAL support of each product)

    static let seriesTuning = IntradaySeries.Tuning()

    /// HRV bucket `b`: RMSSD of the bucket's own clean beats → support `[b, b+300)`.
    static let hrvSeriesMethod = PC.MethodRef(id: "series.hrv_rmssd.5min",
                                              algorithmVersion: IntradaySeries.algorithmVersion,
                                              aggregation: .window, windowS: IntradaySeries.bucketSeconds,
                                              units: "ms")
    /// Resting-HR bucket `b`: the lowest qualifying 5-minute mean over the trailing 12 buckets (the bucket
    /// included) → support `[b − 3300, b + 300)`, displayed in `[b, b+300)`.
    static let restingSeriesMethod = PC.MethodRef(
        id: "series.resting_hr.60min_min5", algorithmVersion: IntradaySeries.algorithmVersion,
        aggregation: .minimumOfBins, windowS: seriesTuning.restingTrailingBuckets * IntradaySeries.bucketSeconds,
        units: "bpm")
    /// Respiratory-rate minute `b`: breaths pooled over the trailing 2 one-minute buckets → support
    /// `[b − 60, b + 60)`, displayed in `[b, b+60)`.
    static let respSeriesMethod = PC.MethodRef(
        id: "series.resp_rate.2min", algorithmVersion: IntradaySeries.algorithmVersion, aggregation: .window,
        windowS: seriesTuning.respWindowBuckets * IntradaySeries.fineBucketSeconds, units: "breaths_per_min")

    /// The support and display bucket of a series point, clipped to the day exactly as the builder clips its
    /// inputs (streams are filtered to `[dayStart, dayEnd)`, so the first buckets' windows start at midnight and a
    /// short final bucket ends at the next midnight).
    static func seriesSupport(_ metric: IntradaySeries.Metric, bucket b: Int,
                              dayWindow: PC.Interval) -> (support: PC.Interval, display: PC.Interval?)? {
        let width = IntradaySeries.bucketSeconds(for: metric)
        let bucketEnd = min(b + width, dayWindow.end)
        guard b >= dayWindow.start, bucketEnd > b else { return nil }
        switch metric {
        case .hrv:
            return (PC.Interval(b, bucketEnd), nil)
        case .restingHR:
            let lo = max(dayWindow.start, b - (seriesTuning.restingTrailingBuckets - 1) * width)
            return (PC.Interval(lo, bucketEnd), PC.Interval(b, bucketEnd))
        case .respRate:
            let lo = max(dayWindow.start, b - (seriesTuning.respWindowBuckets - 1) * width)
            return (PC.Interval(lo, bucketEnd), PC.Interval(b, bucketEnd))
        case .steps, .calories:
            return nil
        }
    }

    static func seriesMethod(_ metric: IntradaySeries.Metric) -> (PC.MetricKind, PC.MethodRef)? {
        switch metric {
        case .hrv: return (.hrvRmssd, hrvSeriesMethod)
        case .restingHR: return (.restingHeartRate, restingSeriesMethod)
        case .respRate: return (.respiratoryRate, respSeriesMethod)
        case .steps, .calories: return nil
        }
    }

    /// Which of the day's sessions a nightly field's support covers (review RC-03).
    enum NightlySupport: Equatable {
        /// The scorer's primary session (longest, first on ties): the session `AnalyticsEngine` takes the daily
        /// resting HR from.
        case primarySession
        /// The main-sleep group: the day's main night as the scorer's own rule picks it
        /// (`SleepStageTotals.mainNightGroupIndices`), every fragment of a split night included.
        case mainSleep
    }

    /// Nightly snapshot fields, their metric, units and support (exact sessions: notes/worker.md §5).
    ///
    /// `resting_hr_bpm` comes from the primary session only. The others are canonical day aggregates over EVERY
    /// session the day owns (`AnalyticsEngine.analyzeDay`: HRV in-bed-weighted mean of per-session RMSSD, SDNN index
    /// over the in-session R-R, median of per-session respiration, worn-gated skin mean, SpO2 in-band mean), naps
    /// included. Their support is nevertheless the main-sleep group: the hull of all sessions spans the awake
    /// hours before a nap, is not "a measurement taken during sleep" for System C, and so dropped every nap day
    /// out of the nightly references. When the canonical aggregate also pools sessions outside that support, the
    /// measurement's source key says so (`aggregatePoolsOutsideSupport`), so the value is never presented as a
    /// main-night-only value without a trace.
    static let nightlyFields: [(field: String, metric: PC.MetricKind, name: String, units: String,
                                support: NightlySupport)] = [
        ("hrv_rmssd_ms", .hrvRmssd, "hrv_rmssd", "ms", .mainSleep),
        ("hrv_sdnn_ms", .hrvSdnn, "hrv_sdnn", "ms", .mainSleep),
        ("resting_hr_bpm", .restingHeartRate, "resting_hr", "bpm", .primarySession),
        ("resp_rate_bpm", .respiratoryRate, "resp_rate", "breaths_per_min", .mainSleep),
        ("skin_temp_c", .skinTemperature, "skin_temp", "degC", .mainSleep),
        ("spo2_candidate_pct", .spo2Candidate, "spo2_candidate", "percent", .mainSleep),
    ]

    /// Notes appended to a nightly measurement's source key (`daily.<field>#<note>;<note>`), sorted.
    /// The canonical aggregate's definition pools `n` of the day's sessions that lie outside the support (naps,
    /// fragments not bridged into the main night). Whether each contributed a value is not published (a session
    /// without beats, the HRV over-count gate, the skin wear gate, motion-backed sessions preferred over HR-only).
    static let aggregatePoolsOutsideSupport = "aggregate_pools_sessions_outside_support"
    /// A split main night: the support is the hull of its fragments and includes this many seconds between them
    /// that no fragment (and so no aggregate) measured.
    static let supportSpansSplitGap = "support_spans_split_sleep_gap_s"
    /// Every session of the day carried the scorer's `is_nap: true`, so the main-night rule ran over all of them.
    static let mainSleepFromNapFlagged = "main_sleep_from_nap_flagged_sessions"
    /// Resting HR's primary session (the longest) is not part of the main-night group (e.g. a long daytime sleep
    /// that lost to a shorter overnight one on the timing score).
    static let primaryOutsideMainSleep = "primary_session_outside_main_sleep"

    /// The scorer's primary session: the longest, the first on ties (`DayScorer.mainSleepSession`).
    static func primarySession(_ sessions: [Snapshot.Session]) -> Snapshot.Session? {
        var best: Snapshot.Session?
        for s in sessions where best == nil || (s.end - s.start) > (best!.end - best!.start) { best = s }
        return best
    }

    /// The day's sessions as the nightly fields' supports split them.
    struct NightlySessions: Equatable {
        /// Resting HR's session.
        var primary: Snapshot.Session
        var primaryInMain: Bool
        /// The main-night group, in time order.
        var main: [Snapshot.Session]
        /// How many of the day's sessions are outside the main group.
        var outsideCount: Int
        /// `[first main start, last main end)`.
        var mainSupport: PC.Interval
        /// Seconds of `mainSupport` that no main fragment covers (the gaps of a split night).
        var splitGapS: Int
        var mainFromNapFlagged: Bool
    }

    /// The main-night group exactly as the scorer derives it (`AnalyticsEngine.analyzeDay`): its
    /// `SleepStageTotals.mainNightGroupIndices` over the day's sessions (the snapshot's `sleep` array is that
    /// list), at the zone offset of the day's start and with no learned habitual midsleep (the server scorer passes
    /// none). A session the scorer flagged `is_nap: true` is never main sleep unless every session is flagged.
    static func nightlySessions(_ sessions: [Snapshot.Session], offsetSec: Int) -> NightlySessions? {
        guard let primary = primarySession(sessions) else { return nil }
        let unflagged = sessions.indices.filter { sessions[$0].isNap != true }
        let pool = unflagged.isEmpty ? Array(sessions.indices) : unflagged
        let blocks = pool.map { SleepStageTotals.NightBlock(start: sessions[$0].start, end: sessions[$0].end) }
        var mainIdx = Set((SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: offsetSec,
                                                                  habitualMidsleepSec: nil) ?? []).map { pool[$0] })
        if mainIdx.isEmpty, let p = sessions.firstIndex(of: primary) { mainIdx = [p] }
        let main = mainIdx.map { sessions[$0] }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        let support = PC.Interval(main.map(\.start).min()!, main.map(\.end).max()!)
        var covered = 0, reach = Int.min
        for f in main where f.end > max(reach, f.start) {
            covered += f.end - max(reach, f.start)
            reach = f.end
        }
        let primaryIndex = sessions.firstIndex(of: primary)
        return NightlySessions(primary: primary, primaryInMain: primaryIndex.map(mainIdx.contains) ?? false,
                               main: main, outsideCount: sessions.count - mainIdx.count, mainSupport: support,
                               splitGapS: max(0, support.duration - covered),
                               mainFromNapFlagged: unflagged.isEmpty && sessions.contains { $0.isNap == true })
    }

    /// The zone offset the scorer used for the main-night rule: the snapshot's zone (the scoring job's) at the
    /// start of the snapshot's day (`DayScorer`: `tz.secondsFromGMT(for: dayStart)`), else the context job's zone.
    static func scorerOffsetSeconds(_ s: Snapshot, fallbackTimezoneId: String) -> Int {
        let tz = s.timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: fallbackTimezoneId)
            ?? TimeZone(identifier: "UTC")!
        let start = DayScorer.dayStartUnix(s.day, tz: tz) ?? s.sessions.first?.start ?? 0
        return tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(start)))
    }

    /// `snapshot.<metric>.night` measurements from the day's snapshot. A session aggregate's nominal window is
    /// its support length (`MethodRef.windowS` contract; System A keys sessions by aggregation class, not length).
    static func snapshotMeasurements(_ s: Snapshot, offsetSec: Int) -> [PC.MeasurementInput] {
        guard let nights = nightlySessions(s.sessions, offsetSec: offsetSec) else { return [] }
        var out: [PC.MeasurementInput] = []
        for f in nightlyFields {
            guard let value = s.values[f.field] else { continue }
            let support: PC.Interval
            let sessionId: String?
            var notes: [String] = []
            switch f.support {
            case .primarySession:
                support = PC.Interval(nights.primary.start, nights.primary.end)
                sessionId = nights.primary.id
                if !nights.primaryInMain { notes.append(primaryOutsideMainSleep) }
            case .mainSleep:
                support = nights.mainSupport
                sessionId = nights.main.count == 1 ? nights.main[0].id : nil
                if nights.outsideCount > 0 { notes.append("\(aggregatePoolsOutsideSupport)=\(nights.outsideCount)") }
                if nights.splitGapS > 0 { notes.append("\(supportSpansSplitGap)=\(nights.splitGapS)") }
                if nights.mainFromNapFlagged { notes.append(mainSleepFromNapFlagged) }
            }
            let key = "daily.\(f.field)" + (notes.isEmpty ? "" : "#" + notes.sorted().joined(separator: ";"))
            let method = PC.MethodRef(id: "snapshot.\(f.name).night", algorithmVersion: scoringAlgorithmVersion,
                                      aggregation: .session, windowS: support.duration, units: f.units)
            let samples = f.field == "spo2_candidate_pct" ? s.values["spo2_candidate_samples"].map { Int($0) } : nil
            out.append(PC.MeasurementInput(
                metric: f.metric, method: method,
                source: PC.SourceRef(product: .scoringSnapshot, key: key,
                                     inputRevision: Int(s.inputRevision), resultRevision: Int(s.resultRevision)),
                value: value, support: support, sampleCount: samples, availableAt: s.availableAt,
                sessionId: sessionId))
        }
        return out
    }

    static func sleepInputs(_ s: Snapshot) -> [PC.SleepSessionInput] {
        s.sessions.map { x in
            PC.SleepSessionInput(id: x.id, interval: PC.Interval(x.start, x.end), isNap: x.isNap,
                                 efficiency: x.efficiency,
                                 stages: x.stages.map { PC.StageSpan(interval: PC.Interval($0.start, $0.end),
                                                                     stage: $0.stage) },
                                 availableAt: s.availableAt, sourceDay: s.day, detector: sleepDetector,
                                 dataThrough: s.dataThrough, timezoneId: s.timezone)
        }
    }

    // MARK: - Assemble (pure)

    struct Assembled {
        var input: PC.DayInput
        var history: PC.HistoryInput
        /// `Engine.causalView` counts of the unrestricted input (telemetry only; never in the document).
        var causalExcluded: [PC.Diagnostic]
        var rowCount: Int
        var measurementCount: Int
    }

    /// Per-minute latest availability of the raw rows a series point was computed from.
    struct AvailabilityIndex {
        private var latest: [Int: Int] = [:]
        mutating func add(ts: Int, at: Int?) {
            guard let at else { return }
            let m = ts >= 0 ? ts / 60 : (ts - 59) / 60
            if at > (latest[m] ?? Int.min) { latest[m] = at }
        }
        /// The latest availability of any row inside `interval`, or nil when none carried one.
        func availableAt(_ interval: PC.Interval) -> Int? {
            guard interval.isValid else { return nil }
            var best: Int?
            var m = interval.start / 60
            while m * 60 < interval.end {
                if let v = latest[m] { best = max(best ?? v, v) }
                m += 1
            }
            return best
        }
    }

    static func assemble(_ rows: Loaded, job: Job, windows w: Windows) -> Assembled {
        let loaded = rows.normalized()
        let causal = job.mode == .causalLive
        let cutoff = job.cutoff
        let family = DayScorer.skinTempFamilyForDevice(deviceFamily: loaded.device?.family,
                                                       sourceKind: loaded.device?.sourceKind)
        let anchor = family == .whoop4 ? (Whoop4SkinTemp.deviceAnchorRaw(loaded.skin.map(\.raw))
                                          ?? Whoop4SkinTemp.anchorRaw) : Whoop4SkinTemp.anchorRaw
        let skin = loaded.skin.map {
            PC.SkinTemperatureObservation(ts: $0.ts, celsius: finite(skinTempCelsius(raw: $0.raw, family: family,
                                                                                   anchorRaw: anchor)),
                                          availableAt: $0.availableAt)
        }
        let regime = deviceRegime(loaded.device)
        let identity = PC.DayIdentity(deviceScope: job.deviceId, day: job.day, timezoneId: w.timezoneId,
                                      dayWindow: w.dayWindow)

        let snapshot = loaded.snapshot
        let sleep = daySleep(snapshot: snapshot, others: loaded.otherSnapshots, windows: w)
        // Every input as stored, for the telemetry count of what a causal decision could not see.
        let unrestricted = PC.DayInput(
            identity: identity, mode: job.mode, availabilityCutoff: cutoff, generatedAt: job.generatedAt,
            heartRate: loaded.heartRate, beatIntervals: loaded.beatIntervals, motion: loaded.motion,
            steps: loaded.steps, skinTemperature: skin, wearEvents: loaded.wearEvents,
            bandSleepStates: loaded.bandSleep, sleepSessions: sleep, workouts: loaded.workouts,
            activityEpochs: loaded.epochs, activityIntervals: loaded.intervals, placements: loaded.placements,
            regime: regime, exposures: loaded.exposures)
        // The causal view first (so transport selection and the series see only what the decision could have
        // seen); a retrospective input passes through unchanged.
        let (view, excluded) = PC.Engine.causalView(unrestricted)

        // R-R transport selection over the visible beats, exactly as scoring selects them.
        let beats = selectTransports(view.beatIntervals)
        var available = AvailabilityIndex()
        let day = w.dayWindow
        for s in view.heartRate where day.contains(s.ts) { available.add(ts: s.ts, at: s.availableAt) }
        for b in beats where day.contains(b.ts) { available.add(ts: b.ts, at: b.availableAt) }
        for m in view.motion where day.contains(m.ts) { available.add(ts: m.ts, at: m.availableAt) }

        var measurements = seriesMeasurements(
            hr: view.heartRate, beats: beats, motion: view.motion, steps: view.steps, dayWindow: day,
            profile: userProfile(loaded.profile, dayStart: day.start), restingHR: snapshot?.restingHRInt,
            snapshot: snapshot, availability: available)
        if let snapshot {
            measurements += snapshotMeasurements(
                snapshot, offsetSec: scorerOffsetSeconds(snapshot, fallbackTimezoneId: w.timezoneId))
        }
        measurements.sort { ($0.support, $0.method.id) < ($1.support, $1.method.id) }

        var input = view
        input.beatIntervals = beats
        input.measurements = measurements
        // Revisions describe what the decision could see: in causal mode the epochs, decoder runs, placement and
        // exposure revisions available at the cutoff (the causal view), never rows stored after it — a count or a
        // maximum over the stored rows would leak a later upload into the live document (V10).
        var visible = loaded
        visible.epochs = view.activityEpochs
        visible.intervals = view.activityIntervals
        visible.placements = view.placements
        visible.exposures = view.exposures
        input.inputRevisions = inputRevisions(visible)

        var priorSleep = dedupedSessions(loaded.otherSnapshots.filter { $0.day < w.previousDay }.flatMap(sleepInputs))
        if causal { priorSleep = priorSleep.filter { ($0.availableAt ?? Int.min) <= cutoff } }
        priorSleep.sort { ($0.interval, $0.id) < ($1.interval, $1.id) }
        let history = PC.HistoryInput(
            dailyValues: loaded.historyValues.sorted { ($0.day, $0.seriesKey, $0.regimeKey) < ($1.day, $1.seriesKey, $1.regimeKey) },
            bouts: loaded.historyBouts.sorted { ($0.interval, $0.id) < ($1.interval, $1.id) },
            frozenReferences: loaded.frozen.sorted { ($0.seriesKey, $0.regimeKey, $0.version, $0.id) < ($1.seriesKey, $1.regimeKey, $1.version, $1.id) },
            priorSleep: priorSleep)
        return Assembled(input: input, history: history, causalExcluded: excluded, rowCount: loaded.rowCount,
                         measurementCount: measurements.count)
    }

    /// The device attributes stamped on a day's measurement regime (review RC-13). Only attributes that cannot
    /// change for a device row are used, because the lane reads the CURRENT `devices` row while it rebuilds days
    /// up to 120 days old (placement corrections, the 28-day `history_changed` cascade, retrospective reruns):
    ///  - `source_kind` (and the vendor derived from it) is fixed: it is part of the row's conflict key
    ///    `(user_id, source_kind, external_device_id)` and no write path updates it.
    ///  - `firmware` is NOT used: every upsert sets `firmware = coalesce(excluded.firmware, devices.firmware)` and
    ///    no firmware history exists, so today's value would be stamped on every rebuilt day and the regime
    ///    boundary would land at the rebuild horizon instead of at the real change. nil = unknown for every day
    ///    until an effective-dated firmware source exists.
    ///  - `device_family` is NOT used either: the same upserts fill or relabel it
    ///    (`coalesce(excluded.device_family, devices.device_family)`; labels such as "WHOOP", "WHOOP 5.0 / MG" and
    ///    "WHOOP 5B…" name the same strap). The device id is already the history scope, so leaving the family out
    ///    pools nothing across devices. (The skin-temperature conversion still reads the current family, exactly as
    ///    the scorer does.)
    static func deviceRegime(_ device: DeviceRow?) -> PC.DeviceRegimeInput {
        PC.DeviceRegimeInput(
            vendor: (device?.sourceKind ?? "").lowercased().contains("oura") ? "oura" : "whoop",
            deviceFamily: nil, sourceKind: device?.sourceKind, firmware: nil, decoderVersion: nil,
            scoringAlgorithmVersion: scoringAlgorithmVersion,
            seriesAlgorithmVersion: IntradaySeries.algorithmVersion)
    }

    /// The sessions the day's input carries: every session of the newest D−1, D and D+1 snapshots, each with the
    /// day that published it (`sourceDay`), its publication time and the snapshot's `dataThrough` / zone. The
    /// sleep system needs D+1's sessions to judge late-day awake evidence retrospectively; a causal view drops
    /// whatever was published after the cutoff. Ownership by end is the sleep system's rule; nothing is
    /// re-assigned here. `HistoryInput.priorSleep` takes D−14 … D−2.
    static func daySleep(snapshot: Snapshot?, others: [Snapshot], windows w: Windows) -> [PC.SleepSessionInput] {
        var sessions = snapshot.map(sleepInputs) ?? []
        for s in others where s.day == w.previousDay || s.day == w.nextDay { sessions += sleepInputs(s) }
        return dedupedSessions(sessions)
    }

    /// One session per id (the newest publication wins), in time order.
    static func dedupedSessions(_ sessions: [PC.SleepSessionInput]) -> [PC.SleepSessionInput] {
        var byId: [String: PC.SleepSessionInput] = [:]
        for s in sessions {
            if let old = byId[s.id], (old.sourceDay ?? "", old.availableAt ?? 0) >= (s.sourceDay ?? "", s.availableAt ?? 0) {
                continue
            }
            byId[s.id] = s
        }
        return byId.values.sorted { ($0.interval, $0.id) < ($1.interval, $1.id) }
    }

    /// `DayScorer.oneTransportPerHour` over the contract's beat observations. That function filters and keeps
    /// order, and a stored beat is unique by `(ts, rrMs, seq)`, so walking both lists recovers which observations
    /// (with their availability) were kept.
    static func selectTransports(_ beats: [PC.BeatIntervalObservation]) -> [PC.BeatIntervalObservation] {
        let rr = beats.map(rrInterval)
        let kept = DayScorer.oneTransportPerHour(rr)
        guard kept.count != rr.count else { return beats }
        var out: [PC.BeatIntervalObservation] = []
        out.reserveCapacity(kept.count)
        var i = 0
        for k in kept {
            while i < rr.count && rr[i] != k { i += 1 }
            guard i < rr.count else { break }
            out.append(beats[i])
            i += 1
        }
        return out
    }

    static func rrInterval(_ b: PC.BeatIntervalObservation) -> RRInterval {
        RRInterval(ts: b.ts, rrMs: b.rrMs, srcChannel: b.channel.flatMap(RRSourceChannel.init(rawValue:)),
                   ord: b.ord, seq: b.seq)
    }

    /// The profile the scorer would load (`DayScorer.loadProfile` defaults), with the age taken at the day's
    /// start instead of "now" so a replay is deterministic. It only reaches the step and calorie series, which the
    /// layer does not contextualize.
    static func userProfile(_ row: ProfileRow?, dayStart: Int) -> UserProfile {
        guard let row else { return UserProfile() }
        var age = 30.0
        if let dob = row.dateOfBirth {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(dob.prefix(10))) {
                age = max(1, (Double(dayStart) - d.timeIntervalSince1970) / 86_400.0 / 365.25)
            }
        }
        return UserProfile(weightKg: row.weightKg ?? 70.0, heightCm: row.heightCm ?? 170.0, age: age,
                           sex: row.sexModel.isEmpty ? "nonbinary" : row.sexModel)
    }

    /// Recompute the day's dense series with the scorer's builder and inputs (`IntradaySeries.build`: day heart
    /// rate, transport-selected R-R, day gravity and steps) and map the HRV, resting-HR and respiratory points to
    /// measurements with their actual supports.
    static func seriesMeasurements(hr: [PC.HeartRateObservation], beats: [PC.BeatIntervalObservation],
                                   motion: [PC.MotionObservation], steps: [PC.StepObservation],
                                   dayWindow: PC.Interval, profile: UserProfile, restingHR: Int?,
                                   snapshot: Snapshot?, availability: AvailabilityIndex) -> [PC.MeasurementInput] {
        let inDay = { (ts: Int) in dayWindow.contains(ts) }
        let points = IntradaySeries.build(IntradaySeries.Inputs(
            dayStart: dayWindow.start, dayEnd: dayWindow.end,
            hr: hr.filter { inDay($0.ts) }.map { HRSample(ts: $0.ts, bpm: $0.bpm) },
            rr: beats.map(rrInterval),
            gravity: motion.filter { inDay($0.ts) }.compactMap { m in
                guard let x = m.x, let y = m.y, let z = m.z else { return nil }
                return GravitySample(ts: m.ts, x: x, y: y, z: z, dynAccel: m.dynAccelG)
            },
            steps: steps.filter { inDay($0.ts) }.map { StepSample(ts: $0.ts, counter: $0.counter,
                                                                  activityClass: $0.activityClass) },
            profile: profile, restingHR: restingHR, energy: nil))
        return measurements(fromSeries: points, dayWindow: dayWindow, snapshot: snapshot, availability: availability)
    }

    static func measurements(fromSeries points: [IntradaySeries.Metric: [IntradaySeries.Point]],
                             dayWindow: PC.Interval, snapshot: Snapshot?,
                             availability: AvailabilityIndex) -> [PC.MeasurementInput] {
        var out: [PC.MeasurementInput] = []
        for metric in [IntradaySeries.Metric.hrv, .restingHR, .respRate] {
            guard let (kind, method) = seriesMethod(metric) else { continue }
            for p in (points[metric] ?? []).sorted(by: { $0.ts < $1.ts }) {
                guard p.value.isFinite, let (support, display) = seriesSupport(metric, bucket: p.ts,
                                                                              dayWindow: dayWindow) else { continue }
                out.append(PC.MeasurementInput(
                    metric: kind, method: method,
                    source: PC.SourceRef(product: .metricSeries, key: "\(metric.rawValue)@\(p.ts)",
                                         inputRevision: snapshot.map { Int($0.inputRevision) },
                                         resultRevision: snapshot.map { Int($0.resultRevision) }),
                    value: p.value, support: support, displayBucket: display, sampleCount: p.samples,
                    coverage: p.coverage.isFinite ? p.coverage : nil,
                    availableAt: availability.availableAt(support)))
            }
        }
        return out
    }

    /// Revisions of the inputs the document depends on (spec §6.3). Content-derived only (no job revision, no
    /// clock), so a retry over the same stored inputs records the same list. `assemble` passes the causally
    /// visible collections; snapshots and history are already cut off at the cutoff by their queries.
    static func inputRevisions(_ l: Loaded) -> [PC.InputRevision] {
        func maxOf(_ values: [Int]) -> String { values.max().map(String.init) ?? "none" }
        var out: [PC.InputRevision] = [
            PC.InputRevision(input: "scoring_snapshot", revision: l.snapshot.map { String($0.resultRevision) } ?? "none"),
            PC.InputRevision(input: "scoring_input", revision: l.snapshot.map { String($0.inputRevision) } ?? "none"),
            PC.InputRevision(input: "metric_series", revision: IntradaySeries.algorithmVersion),
            PC.InputRevision(input: "activity_epochs", revision: maxOf(l.epochs.map(\.revision))),
            PC.InputRevision(input: "activity_days", revision: maxOf(l.intervals.map(\.revision))),
            PC.InputRevision(input: "placement", revision: "\(l.placements.count):\(maxOf(l.placements.map(\.revision)))"),
            PC.InputRevision(input: "exposures", revision: "\(l.exposures.count):\(maxOf(l.exposures.map(\.availableAt)))"),
            PC.InputRevision(input: "other_day_snapshots", revision: maxOf(l.otherSnapshots.map { Int($0.resultRevision) })),
            PC.InputRevision(input: "history_daily_values", revision: String(l.historyValues.count)),
            PC.InputRevision(input: "history_bouts", revision: String(l.historyBouts.count)),
            PC.InputRevision(input: "frozen_references", revision: String(l.frozen.count)),
        ]
        for name in l.unavailable { out.append(PC.InputRevision(input: name, revision: "unavailable")) }
        return out.sorted { ($0.input, $0.revision) < ($1.input, $1.revision) }
    }
}
