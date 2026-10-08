// SleepFeatureEnrichment.swift
//
// The sleep-phenotype enrichment lane (docs/SLEEP_FEATURES_CONTRACT.md):
// one bounded request per claimed day to the sidecar's dedicated
// POST /v1/sleep-features endpoint, and the validated response attached
// verbatim under `snapshot.daily.sleep_features`.
//
// Why a dedicated endpoint and NOT the /v1/infer candidate lane (spec 7.1):
// a bundle of descriptive features is neither a scalar result nor stage
// segments, and the candidate lane has promotion semantics a descriptive
// research feature must never touch. This is an enrichment, not a canonical
// candidate: V2 stays canonical, nothing is promoted, no composite score is
// introduced.
//
// Safety rules (spec 7.4):
//   * OFF unless FRWHOOP_INFERENCE_URL is set (the same dormant default as
//     the candidate lane); an absent sidecar leaves the snapshot
//     byte-identical to today.
//   * Bounded inputs: at most 8 nights, 16 h per night, 60k HR, 60k temp,
//     120k RR beats, 20k breath intervals, 31 history days (the Python
//     contract re-validates every bound; a violation is refused 4xx and the
//     snapshot publishes WITHOUT the key, core results intact).
//   * Bounded wall clock: 3500 ms transport budget around the sidecar's own
//     3000 ms compute budget. A timeout publishes the core snapshot with
//     `sleep_features.status = "timeout"` — never an error, never a hang; the
//     ordinary next eligible scoring pass retries.
//   * One enrichment request per claimed day, inside the payload build (a
//     plain loopback JSON call, not the waveform download / model inference
//     the spec keeps out of the repeatable-read transaction).
//   * The response is structurally validated (status string, nights array,
//     JSON-safe numbers) before it is attached; a malformed response is
//     dropped, not stored.

import Foundation
import WhoopProtocol
import StrandAnalytics

/// One staged night in the enrichment request.
struct SleepFeatureNightInput {
    let nightId: String
    let start: Int
    let end: Int
    let isNap: Bool
    let userEdited: Bool
    let stages: [StageSegment]
}

/// The 31-day sleep/wake history for the regularity block.
struct SleepFeatureHistory {
    /// (day, result_revision) pairs, oldest first — the revision digest is
    /// derived from these so ANY republished day in the window invalidates
    /// the rolling SRI (spec 7.4 freshness).
    let dayRevisions: [(day: String, revision: Int64)]
    /// (day, minuteStartTs, state, valid) — UTC minute grid.
    let minutes: [(day: String, ts: Int, state: Int, valid: Bool)]
    /// spec-02 §5.1 (docs/spec-02/CONTRACT.md): each history day's published snapshot sleep entries
    /// (`history.days[].nights`, for the next-night rebound block), from the same snapshot row the
    /// minute grid folds, so `dayRevisions` already versions them.
    var nightsByDay: [String: [SleepFeatureHistoryNight]] = [:]
    /// spec-02 §5.1: the IANA zone each history day's snapshot was interpreted in (`history.days[].timezone`).
    var timezoneByDay: [String: String] = [:]
}

/// One published snapshot sleep entry of a history day (spec-02 §5.1 `history.days[].nights[]`). A value
/// the snapshot did not publish (or published outside the sidecar's accepted range) is nil, never zero.
struct SleepFeatureHistoryNight: Equatable {
    let start: Int
    let end: Int
    let isNap: Bool
    let asleepMin: Double?
    let awakeMin: Double?
    /// As the snapshot published it (`AnalyticsEngine` session efficiency, a 0–1 fraction).
    let efficiency: Double?

    /// The sidecar accepts at most this many entries per history day (`MAX_HISTORY_NIGHTS_PER_DAY`).
    static let maxPerDay = 8

    /// Parse one snapshot `sleep[]` entry; nil when it has no valid span.
    static func parse(_ entry: [String: Any]) -> SleepFeatureHistoryNight? {
        guard let startAt = entry["start_at"] as? String, let endAt = entry["end_at"] as? String,
              let start = SleepFeatureEnrichment.unixSeconds(startAt),
              let end = SleepFeatureEnrichment.unixSeconds(endAt), end > start else { return nil }
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = ContextInputs.number(entry[key]), v.isFinite, range.contains(v) else { return nil }
            return v
        }
        return SleepFeatureHistoryNight(start: start, end: end, isNap: (entry["is_nap"] as? Bool) ?? false,
                                        asleepMin: number("asleep_min", 0...1440),
                                        awakeMin: number("awake_min", 0...1440),
                                        efficiency: number("efficiency", 0...100))
    }

    /// The entries sent for one day: at most `maxPerDay`, the longest kept (the main night is never
    /// the one dropped), in start order.
    static func bounded(_ nights: [SleepFeatureHistoryNight]) -> [SleepFeatureHistoryNight] {
        let kept = nights.count <= maxPerDay ? nights
            : Array(nights.sorted { ($0.end - $0.start, $1.start) > ($1.end - $1.start, $0.start) }.prefix(maxPerDay))
        return kept.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    var wire: [String: Any] {
        ["start": start, "end": end, "is_nap": isNap,
         "asleep_min": asleepMin ?? NSNull(), "awake_min": awakeMin ?? NSNull(),
         "efficiency": efficiency ?? NSNull()]
    }
}

enum SleepFeatureEnrichment {

    static let algorithmVersion = "nara-sleep-features-1"
    static let schemaVersion = 1
    /// Transport budget around the sidecar's 3000 ms compute budget.
    static let budgetMS = 3500
    static let maxResponseBytes = 8 << 20

    // MARK: - Request assembly (pure; unit-tested)

    struct AssemblyInput {
        let userId: String
        let deviceId: String
        let day: String
        let timezoneId: String
        let inputRevision: Int64
        let intervalStart: Int
        let intervalEnd: Int
        let stageAlgorithmVersion: String
        let nights: [SleepFeatureNightInput]
        let hr: [HRSample]
        let tempCelsius: [(ts: Int, celsius: Double)]
        let beats: [RRInterval]
        let breathTrack: RespBreathTrack
        let history: SleepFeatureHistory?
        /// spec-02: the bounded multi-day `rhythm_history` (CONTRACT §5.1), assembled by
        /// `SleepFeatureRhythmHistory.assemble`; nil sends no key.
        var rhythmHistory: [String: Any]? = nil
    }

    /// What the sidecar reads around a night: the thermal baseline starts 90 min
    /// before sleep onset (settling reads 30 min), and the final-wake window runs
    /// 2 min past the end. Everything outside these spans is never read.
    static let leadInSeconds = 90 * 60
    static let tailSeconds = 3 * 60

    /// Build the wire request object. Pure: no I/O, no clock.
    ///
    /// The scoring pass loads an 84 h window per claim (hr/rr/skin temp for
    /// `dayStart-30h ..< dayStart+54h`); sent whole that was a 17.6 MB body on real data,
    /// refused 413. Only the samples inside a night's span are forwarded.
    static func buildRequest(_ input: AssemblyInput) -> [String: Any] {
        let spans = input.nights.map { (from: $0.start - leadInSeconds, to: $0.end + tailSeconds) }
        func inNight(_ ts: Int) -> Bool { spans.contains { $0.from <= ts && ts < $0.to } }
        let hr = input.hr.filter { inNight($0.ts) }
        let temp = input.tempCelsius.filter { inNight($0.ts) }
        let beats = input.beats.filter { inNight($0.ts) }
        let breathIntervals = input.breathTrack.intervals.filter { inNight($0.ts) }
        let breathRuns = input.breathTrack.runs.filter { run in
            spans.contains { run.start < $0.to && $0.from < run.end }
        }
        var nights: [[String: Any]] = []
        nights.reserveCapacity(input.nights.count)
        for n in input.nights {
            nights.append([
                "night_id": n.nightId,
                "start_utc": isoUTC(n.start),
                "end_utc": isoUTC(n.end),
                "is_nap": n.isNap,
                "user_edited": n.userEdited,
                "stages": n.stages.map { ["start": $0.start, "end": $0.end, "stage": $0.stage] },
            ])
        }
        var request: [String: Any] = [
            "schema_version": schemaVersion,
            "algorithm_version": algorithmVersion,
            "context": [
                "user_id": input.userId,
                "device_id": input.deviceId,
                "day": input.day,
                "iana_timezone": input.timezoneId,
                "input_revision": input.inputRevision,
                "interval_start_utc": isoUTC(input.intervalStart),
                "interval_end_utc": isoUTC(input.intervalEnd),
                // The canonical staging algorithm actually claimed for the day
                // (context-carried, echoed per response night; contract §9).
                "stage_algorithm_version": input.stageAlgorithmVersion,
            ],
            "nights": nights,
            "hr_samples": hr.map { ["ts": $0.ts, "bpm": Double($0.bpm)] },
            "skin_temp_samples": temp.map { ["ts": $0.ts, "celsius": $0.celsius] },
            "rr_beats": beats.map { [
                "ts": $0.ts,
                "rr_ms": Double($0.rrMs),
                "seq": $0.seq,
                "ord": $0.ord ?? NSNull(),
                "src_channel": $0.srcChannel?.rawValue ?? NSNull(),
            ] as [String: Any] },
            "resp_breaths": [
                "intervals": breathIntervals.map { ["ts": $0.ts, "seconds": $0.seconds] },
                "runs": breathRuns.map { ["start": $0.start, "end": $0.end] },
            ] as [String: Any],
        ]
        if let history = input.history, !history.dayRevisions.isEmpty {
            var digest = ""
            for (day, revision) in history.dayRevisions {
                digest += "\(day):\(revision)|"
            }
            request["history"] = [
                "pair_policy": "elapsed_24h",
                "days": Dictionary(grouping: history.minutes, by: \.day)
                    .sorted(by: { $0.key < $1.key })
                    .map { day, minutes in
                        var ms: [[String: Any]] = []
                        ms.reserveCapacity(minutes.count)
                        for m in minutes.sorted(by: { $0.ts < $1.ts }) {
                            ms.append(["ts": m.ts, "state": m.state, "valid": m.valid])
                        }
                        var entry: [String: Any] = ["day": day, "minutes": ms]
                        // spec-02 §5.1: the day's published sleep entries and zone (rebound).
                        if let nights = history.nightsByDay[day] {
                            entry["nights"] = SleepFeatureHistoryNight.bounded(nights).map(\.wire)
                        }
                        if let zone = history.timezoneByDay[day], !zone.isEmpty { entry["timezone"] = zone }
                        return entry
                    },
            ] as [String: Any]
            if let context = request["context"] as? [String: Any] {
                var c = context
                c["history_revision_digest"] = sha256Hex(Data(digest.utf8))
                request["context"] = c
            }
        }
        if let rhythm = input.rhythmHistory {
            request["rhythm_history"] = rhythm
        }
        return request
    }

    // MARK: - Response validation (pure; unit-tested)

    /// Structural validation before attaching: the object must be JSON-safe,
    /// carry a known status, and its nights must be a list of objects with the
    /// contract's required keys. Numbers are checked for finiteness by
    /// JSONSerialization's isValidJSONObject only in shape terms; NaN cannot
    /// survive a JSON round-trip from the sidecar (the Python contract
    /// renders NaN as absent), but a hostile/garbled body is refused here
    /// rather than persisted.
    static func validateResponse(_ raw: Data) -> [String: Any]? {
        guard raw.count <= maxResponseBytes else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        guard obj["schema_version"] as? Int == schemaVersion,
              let status = obj["status"] as? String,
              ["available", "partial", "withheld", "timeout", "error"].contains(status) else {
            return nil
        }
        guard let nights = obj["nights"] as? [[String: Any]] else { return nil }
        for n in nights {
            guard n["night_id"] is String,
                  n["start_utc"] is String,
                  n["end_utc"] is String else {
                return nil
            }
        }
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return obj
    }

    // MARK: - Call (sidecar transport)

    /// POST /v1/sleep-features through the shared loopback transport.
    /// Returns the validated response object, or nil on ANY failure (the
    /// caller then publishes the snapshot without the key — or, for a
    /// `timeout`/`error` status body, attaches the degraded status document
    /// so the client can say "unavailable right now" instead of nothing).
    static func enrich(request: [String: Any], client: InferenceClient) -> [String: Any]? {
        do {
            guard JSONSerialization.isValidJSONObject(request),
                  let body = try? JSONSerialization.data(withJSONObject: request) else {
                return nil
            }
            let raw = try client.sleepFeatures(body: body, timeoutMSOverride: budgetMS)
            return validateResponse(raw)
        } catch {
            return nil
        }
    }

    // MARK: - History loader (DB; one bounded query)

    /// Load the last `days` published snapshot sleep arrays (newest
    /// result_revision per day, under the CLAIMED algorithm version) and fold
    /// each history day to a full LOCAL-day UTC 1-minute sleep/wake grid.
    ///
    /// Validity policy (contract §5, both branches):
    ///   * inside a staged session span: `valid`, sleep where staged sleep
    ///     covers >= 30 s of the minute, wake otherwise (the staged decision);
    ///   * outside staged spans: `valid` with state WAKE when the minute has
    ///     >= 30 s of HR presence (worn — the strap streams HR ~1/s while
    ///     worn), `invalid` otherwise (off-wrist / unmonitored — never marked
    ///     awake, spec A3).
    /// A published night with NO stage array carries an unknown classification
    /// and contributes no staged minutes (never fabricated wake).
    ///
    /// Bounded: two queries per enrichment call — the snapshot sleep arrays
    /// (one per day) and one per-minute HR presence aggregate over the window.
    /// A DST day's local span is 23/25 h; the grid is the true local-day span,
    /// never a fixed 1440 minutes.
    static func loadHistory(db: PostgresClientProtocol, userId: String, deviceId: String,
                            days: Int, todayDay: String, ianaTimezone: String,
                            algorithmVersion: String) throws -> SleepFeatureHistory? {
        let tz = TimeZone(identifier: ianaTimezone) ?? TimeZone(identifier: "UTC")!
        // The window's unix bounds: the earliest local midnight in the window
        // to the current day's local midnight (DST-correct per day).
        guard let windowStart = localMidnight(dayBefore: days, of: todayDay, tz: tz),
              let windowEnd = localMidnight(dayBefore: 0, of: todayDay, tz: tz),
              windowEnd > windowStart else { return nil }

        // Query 1: the staged nights, newest revision per day UNDER THE CLAIMED
        // ALGORITHM (like-for-like device/algorithm comparison, spec 4.3; a
        // day republished under another algorithm never mixes into the window).
        let rows = try db.query("""
            select day::text as day, result_revision::text as rev, payload->'sleep' as sleep,
                   payload->>'timezone' as tz
              from public.scoring_snapshots_v2 s
             where user_id = $1::uuid and device_id = $2::uuid
               and algorithm_version = $5::text
               and day < $3::date
               and day >= ($3::date - make_interval(days => $4::int))
               and result_revision = (
                    select max(result_revision) from public.scoring_snapshots_v2 s2
                     where s2.user_id = s.user_id and s2.device_id = s.device_id
                       and s2.day = s.day and s2.algorithm_version = $5::text)
             order by day
            """, [userId, deviceId, todayDay, String(days), algorithmVersion])
        guard !rows.isEmpty else { return nil }

        // Query 2: per-minute HR presence over the same window (worn evidence).
        let hrRows = try db.query("""
            select ((ts / 60) * 60)::text as minute, count(*)::text as n
              from public.noop_hr_samples
             where user_id = $1::uuid and device_id = $2::uuid
               and ts >= $3::bigint and ts < $4::bigint
             group by 1
            """, [userId, deviceId, String(windowStart), String(windowEnd)])
        var hrByMinute: [Int: Int] = [:]
        hrByMinute.reserveCapacity(hrRows.count)
        for r in hrRows {
            if let m = Int(r["minute"] ?? ""), let n = Int(r["n"] ?? "") {
                hrByMinute[m] = n
            }
        }

        var dayRevisions: [(day: String, revision: Int64)] = []
        var minutes: [(day: String, ts: Int, state: Int, valid: Bool)] = []
        var nightsByDay: [String: [SleepFeatureHistoryNight]] = [:]
        var timezoneByDay: [String: String] = [:]
        for row in rows {
            let day = row["day"] ?? ""
            guard let rev = Int64(row["rev"] ?? "") else { continue }
            guard let dayStart = localMidnight(ofDay: day, tz: tz) else { continue }
            // next local midnight, DST-correct (23/25 h days)
            guard let nextDayStart = nextLocalMidnight(afterUnix: dayStart, tz: tz) else { continue }
            dayRevisions.append((day, rev))
            if let zone = row["tz"], !zone.isEmpty { timezoneByDay[day] = zone }

            // The day's staged spans (sleep seconds per minute + session spans).
            var sleepSecByMinute: [Int: Double] = [:]
            var sessionSpans: [(Int, Int)] = []
            if let sleepText = row["sleep"], !sleepText.isEmpty,
               let data = sleepText.data(using: .utf8),
               let nights = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                nightsByDay[day] = nights.compactMap(SleepFeatureHistoryNight.parse)
                for night in nights {
                    guard let startAt = night["start_at"] as? String, let endAt = night["end_at"] as? String,
                          let start = unixSeconds(startAt), let end = unixSeconds(endAt),
                          end > start else { continue }
                    sessionSpans.append((start, end))
                    guard let arr = night["stages"] as? [[String: Any]] else { continue }
                    for s in arr {
                        guard let st = s["start"] as? Int, let en = s["end"] as? Int,
                              let stage = s["stage"] as? String, en > st, stage != "wake" else { continue }
                        var m = (max(st, dayStart) / 60) * 60
                        let hi = min(en, nextDayStart)
                        while m < hi {
                            let lo = max(st, m)
                            let hiS = min(en, m + 60)
                            if hiS > lo {
                                sleepSecByMinute[m, default: 0.0] += Double(hiS - lo)
                            }
                            m += 60
                        }
                    }
                }
            }

            // The full local-day grid.
            var m = dayStart
            while m < nextDayStart {
                let staged = sessionSpans.contains { span in m >= span.0 && (m + 60) <= span.1 }
                if staged {
                    let sleepSec = sleepSecByMinute[m] ?? 0.0
                    minutes.append((day, m, sleepSec >= 30.0 ? 1 : 0, true))
                } else if (hrByMinute[m] ?? 0) >= 30 {
                    // Worn but outside any staged session: monitored awake.
                    minutes.append((day, m, 0, true))
                } else {
                    // Off-wrist / unmonitored: excluded, never awake.
                    minutes.append((day, m, 0, false))
                }
                m += 60
            }
        }
        guard !dayRevisions.isEmpty else { return nil }
        return SleepFeatureHistory(dayRevisions: dayRevisions, minutes: minutes,
                                   nightsByDay: nightsByDay, timezoneByDay: timezoneByDay)
    }

    /// Local midnight (unix) of `ofDay` ("YYYY-MM-DD") in `tz`.
    static func localMidnight(ofDay day: String, tz: TimeZone) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    /// Local midnight `days` before `ofDay` in `tz` (calendar days, not 86400 s).
    static func localMidnight(dayBefore days: Int, of day: String, tz: TimeZone) -> Int? {
        guard let base = localMidnight(ofDay: day, tz: tz) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let d = cal.date(byAdding: .day, value: -days, to: Date(timeIntervalSince1970: TimeInterval(base))) else {
            return nil
        }
        return Int(d.timeIntervalSince1970)
    }

    /// The next local midnight after `unix` in `tz` (DST-correct: 23/25 h days).
    static func nextLocalMidnight(afterUnix unix: Int, tz: TimeZone) -> Int? {
        var t = unix + 23 * 3600
        while t < unix + 26 * 3600 {
            let date = Date(timeIntervalSince1970: TimeInterval(t))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let comps = cal.dateComponents([.hour, .minute, .second], from: date)
            if comps.hour == 0 && comps.minute == 0 && comps.second == 0 {
                return t
            }
            t += 60
        }
        return nil
    }

    static func unixSeconds(_ iso: String) -> Int? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return Int(d.timeIntervalSince1970) }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: iso).map { Int($0.timeIntervalSince1970) }
    }

    static func isoUTC(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// The minimal surface `loadHistory` needs, so its unit tests can run without
/// a database (the same seam `DayScorer` uses for its loader tests).
protocol PostgresClientProtocol {
    func query(_ sql: String, _ params: [String]) throws -> [[String: String]]
}

extension PostgresClient: PostgresClientProtocol {}
