import Foundation
import WhoopStore

// ExerciseSession.swift — rule `exercise-session-2` (docs/context-watchdog/EXERCISE_SESSION.md).
//
// A strap sees resistance training as mostly still: between sets and during leg work it barely moves while heart rate
// is 100–150 bpm. A session is a period opened by movement that keeps its still minutes, followed by a recovery phase.
// Readings inside them are compared with the person's own exercise and recovery references (or none yet), never with
// a sitting or resting one. Heart rate only qualifies a period that movement opened, so a still, high heart rate never
// opens a session and resting tachycardia keeps being judged against rest.
//
// Since -2 a session is `confirmed` once its period holds `minConfirmStrong` strong minutes, or when it starts at most
// `inheritMinutes` after the last evidence minute of a confirmed session (a workout split by a long rest). Only a
// confirmed session gets a recovery phase and trains the exercise references. An unconfirmed one, once it has ended,
// is phase `active`: movement (never rest, never an exercise reference) with no recovery after it. Live opening is
// unchanged: an open period is `session` from the moment conditions 1–3 hold, confirmed or not.
//
// Pinned to contracts/reference/exercise-session-2.json (ExerciseSessionTests). The server minute builder implements
// the same rule.

public enum ExerciseSessionPhase: String, Equatable, Sendable, Codable {
    case none
    /// Inside a session: an open one (confirmed or not yet), or a confirmed one that has ended.
    case session
    /// After a confirmed session's last evidence minute, until heart rate returns or the cap.
    case recovery
    /// An ended, unconfirmed session's minutes (rule exercise-session-2): movement, never rest and never an exercise
    /// reference; no recovery follows it.
    case active
}

/// One minute of HR-free movement evidence plus its heart rate (the load check only).
public struct ExerciseSessionMinute: Equatable, Sendable, Codable {
    public var minuteUnix: Int
    public var hr: Double?
    public var strong: Bool
    public var weak: Bool
    public init(minuteUnix: Int, hr: Double?, strong: Bool, weak: Bool) {
        self.minuteUnix = minuteUnix; self.hr = hr; self.strong = strong; self.weak = weak
    }
    public var evidence: Bool { strong || weak }
}

public struct ExerciseSessionSpan: Equatable, Sendable, Codable {
    /// First and last evidence minute (minute starts, unix seconds).
    public var startUnix: Int
    public var endUnix: Int
    /// Start of the first minute no longer in recovery (the minute after `endUnix` for an unconfirmed session); nil
    /// while the session is still open.
    public var recoveryEndUnix: Int?
    /// Median HR 45–10 minutes before the start (bpm).
    public var preReference: Double
    /// Still open at `nowUnix` (newest evidence ≤ 10 minutes old); its duration has not been checked yet.
    public var open: Bool
    public var hrP50: Double?
    public var hrP90: Double?
    public var hrPeak: Double?
    /// Σ max(0, HR − rest) over the session's minutes, bpm·min.
    public var load: Double
    /// Rule exercise-session-2: `minConfirmStrong` strong minutes so far, or inherited from a confirmed session that
    /// ended at most `inheritMinutes` before this one started. Only a confirmed session has a recovery and trains the
    /// exercise references.
    public var confirmed: Bool = true
    /// Start of the minute that confirmed it (the session start when inherited); nil when unconfirmed.
    public var confirmedAtUnix: Int? = nil
    public var durationMinutes: Int { (endUnix - startUnix) / 60 + 1 }
}

extension ExerciseSessionSpan {
    private enum CodingKeys: String, CodingKey {
        case startUnix, endUnix, recoveryEndUnix, preReference, open, hrP50, hrP90, hrPeak, load, confirmed,
             confirmedAtUnix
    }

    /// Lenient: a span encoded before exercise-session-2 had a recovery like every -1 session (confirmed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startUnix = try c.decode(Int.self, forKey: .startUnix)
        endUnix = try c.decode(Int.self, forKey: .endUnix)
        recoveryEndUnix = try c.decodeIfPresent(Int.self, forKey: .recoveryEndUnix)
        preReference = try c.decode(Double.self, forKey: .preReference)
        open = try c.decode(Bool.self, forKey: .open)
        hrP50 = try c.decodeIfPresent(Double.self, forKey: .hrP50)
        hrP90 = try c.decodeIfPresent(Double.self, forKey: .hrP90)
        hrPeak = try c.decodeIfPresent(Double.self, forKey: .hrPeak)
        load = try c.decode(Double.self, forKey: .load)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? true
        confirmedAtUnix = try c.decodeIfPresent(Int.self, forKey: .confirmedAtUnix)
    }
}

public enum ExerciseSessionRule {
    public static let rule = "exercise-session-2"
    public static let mergeGapMinutes = 10
    /// A weak evidence minute counts only within this many minutes of a strong one.
    public static let anchorMinutes = 20
    public static let spanMinutes = 10
    public static let minEvidenceInSpan = 3
    public static let minStrong = 2
    public static let loadDeltaBpm = 25.0
    public static let minLoadMinutes = 8
    public static let minDurationMinutes = 12
    public static let returnDeltaBpm = 10.0
    public static let returnRunMinutes = 5
    public static let recoveryCapMinutes = 30...120
    public static let preWindowMinutes = (from: 45, to: 10)
    /// A session is confirmed at its `minConfirmStrong`-th strong minute (owner audit 2026-10-09: the weakest of 9 gym
    /// sessions had 19; non-gym "sessions" had far fewer).
    public static let minConfirmStrong = 15
    /// …or when it starts at most this many minutes after the last evidence minute of a confirmed session.
    public static let inheritMinutes = 30
    /// The resting rule (> 120 bpm for 10 still minutes) applies to recovery minutes from this long after the
    /// session's last evidence minute.
    public static let recoveryRestingRuleAfterSeconds = 15 * 60

    /// Per-minute evidence thresholds (dynamic acceleration, g).
    public static let strongDynG = 0.10
    public static let weakDynG = 0.05
    /// The decoder's log-scaled motion intensity: 0.40 ≈ 49 mg (the HRV motion gate), 0.48 ≈ 100 mg.
    public static let strongIntensity = 0.48
    public static let weakIntensity = 0.40
    static let strongLocomotion: Set<String> = ["walking", "brisk_walking", "running"]
    static let strongClasses: Set<String> = ["brisk_walking", "running", "cycling", "vigorous_activity"]
    static let weakClasses: Set<String> = ["light_activity"]

    // MARK: Evidence

    /// Evidence from one stored decoder interval (class, locomotion, arm behaviour, intensity). Wear-off and asleep
    /// intervals are never evidence.
    public static func evidence(of r: ActivityContextIntervalRow) -> (strong: Bool, weak: Bool) {
        guard r.wearState != "off_wrist", r.sleepState != "asleep" else { return (false, false) }
        let strong = strongLocomotion.contains(r.locomotion ?? "")
            || strongClasses.contains(r.activityClass)
            || r.armBehavior == "exercise_motion"
            || (r.intensity.map { $0 >= strongIntensity } ?? false)
        let weak = weakClasses.contains(r.activityClass) || (r.intensity.map { $0 >= weakIntensity } ?? false)
        return (strong, weak)
    }

    /// One live minute's evidence: dynamic acceleration, the strap's step classes and the decoder interval covering
    /// the minute's midpoint. Heart rate is carried for the load check only.
    public static func minute(minuteUnix: Int, hr: Double?, dynMean: Double?, walkRunTicks: Int, stepTicks: Int,
                              interval: ActivityContextIntervalRow?) -> ExerciseSessionMinute {
        // Asleep or off the wrist is never evidence, whatever the motion.
        if let iv = interval, iv.sleepState == "asleep" || iv.wearState == "off_wrist" {
            return ExerciseSessionMinute(minuteUnix: minuteUnix, hr: hr, strong: false, weak: false)
        }
        let fromInterval: (strong: Bool, weak: Bool) = interval.map(evidence(of:)) ?? (false, false)
        let steps = stepTicks > 0 && Double(walkRunTicks) >= 0.5 * Double(stepTicks)
        let strong = steps || (dynMean.map { $0 >= strongDynG } ?? false) || fromInterval.strong
        let weak = (dynMean.map { $0 >= weakDynG } ?? false) || fromInterval.weak
        return ExerciseSessionMinute(minuteUnix: minuteUnix, hr: hr, strong: strong, weak: weak)
    }

    /// Minute evidence from stored decoder intervals alone (Layer 1 strata, history). A minute is strong (weak) when
    /// strong (any evidence) intervals cover ≥ 20 s of it; HR is the sample-weighted mean of the covering intervals.
    public static func minutes(fromIntervals rows: [ActivityContextIntervalRow]) -> [ExerciseSessionMinute] {
        let sorted = rows.sorted { $0.startTs < $1.startTs }
        guard let first = sorted.first, let last = sorted.map(\.endTs).max() else { return [] }
        let start = first.startTs - ((first.startTs % 60) + 60) % 60
        var strongS: [Int: Int] = [:], evidS: [Int: Int] = [:]
        var hrW: [Int: Double] = [:], hrSum: [Int: Double] = [:]
        for r in sorted where r.endTs > r.startTs {
            let ev = evidence(of: r)
            let rate = Double(r.hrSamples) / Double(r.endTs - r.startTs)
            var t = r.startTs - ((r.startTs % 60) + 60) % 60
            while t < r.endTs {
                let overlap = min(r.endTs, t + 60) - max(r.startTs, t)
                if overlap > 0 {
                    if ev.strong { strongS[t, default: 0] += overlap }
                    if ev.strong || ev.weak { evidS[t, default: 0] += overlap }
                    if let m = r.hrMean, m.isFinite, r.hrSamples > 0, r.wearState != "off_wrist" {
                        let w = rate * Double(overlap)
                        hrW[t, default: 0] += w
                        hrSum[t, default: 0] += m * w
                    }
                }
                t += 60
            }
        }
        var out: [ExerciseSessionMinute] = []
        var t = start
        while t < last {
            let hr = (hrW[t] ?? 0) > 0 ? hrSum[t]! / hrW[t]! : nil
            let strong = (strongS[t] ?? 0) >= 20
            out.append(ExerciseSessionMinute(minuteUnix: t, hr: hr, strong: strong,
                                             weak: !strong && (evidS[t] ?? 0) >= 20))
            t += 60
        }
        return out
    }

    /// The earliest second from which `new` gives any minute different interval evidence than `old` (a re-decode
    /// rewrote the stored decoder intervals): the first interval, in start order, whose bounds or evidence fields
    /// (class, locomotion, arm behaviour, intensity, sleep and wear state) differ. nil when nothing differs.
    public static func earliestEvidenceChange(old: [ActivityContextIntervalRow],
                                              new: [ActivityContextIntervalRow]) -> Int? {
        let a = old.sorted { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        let b = new.sorted { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        func same(_ x: ActivityContextIntervalRow, _ y: ActivityContextIntervalRow) -> Bool {
            x.startTs == y.startTs && x.endTs == y.endTs && x.activityClass == y.activityClass
                && x.locomotion == y.locomotion && x.armBehavior == y.armBehavior && x.intensity == y.intensity
                && x.sleepState == y.sleepState && x.wearState == y.wearState
        }
        for i in 0..<max(a.count, b.count) {
            guard i < a.count else { return b[i].startTs }
            guard i < b.count else { return a[i].startTs }
            if !same(a[i], b[i]) { return min(a[i].startTs, b[i].startTs) }
        }
        return nil
    }

    // MARK: Rule

    /// Sessions over a contiguous, minute-aligned run of minutes (gaps in the input are filled as no evidence, no
    /// HR). Completed sessions need every condition; with `nowUnix`, a period whose newest evidence minute is at most
    /// `mergeGapMinutes` old is returned `open` once conditions 1–3 hold.
    public static func sessions(minutes input: [ExerciseSessionMinute], restReference rest: Double,
                                nowUnix: Int? = nil) -> [ExerciseSessionSpan] {
        let grid = contiguous(input)
        guard !grid.isEmpty else { return [] }
        let n = grid.count
        let t0 = grid[0].minuteUnix
        // Counted evidence: strong minutes, and weak minutes within `anchorMinutes` of a strong one.
        let strongIdx = (0..<n).filter { grid[$0].strong }
        var counted = [Bool](repeating: false, count: n)
        var j = 0
        for i in 0..<n {
            if grid[i].strong { counted[i] = true; continue }
            guard grid[i].weak else { continue }
            while j < strongIdx.count && strongIdx[j] < i - anchorMinutes { j += 1 }
            counted[i] = j < strongIdx.count && strongIdx[j] <= i + anchorMinutes
        }
        var periods: [(Int, Int)] = []
        for i in 0..<n where counted[i] {
            if let last = periods.last, i - last.1 <= mergeGapMinutes {
                periods[periods.count - 1].1 = i
            } else {
                periods.append((i, i))
            }
        }
        let nowIndex = nowUnix.map { ($0 - t0) / 60 }
        var found: [(a: Int, b: Int, open: Bool)] = []
        for (a, b) in periods {
            let dense = (a...b).contains { s in
                (s..<min(s + spanMinutes, b + 1)).filter { counted[$0] }.count >= minEvidenceInSpan
            }
            let strong = (a...b).filter { grid[$0].strong }.count
            let load = (a...b).filter { (grid[$0].hr ?? 0) >= rest + loadDeltaBpm }.count
            guard dense, strong >= minStrong, load >= minLoadMinutes else { continue }
            let open = nowIndex.map { $0 - b <= mergeGapMinutes } ?? false
            guard open || b - a + 1 >= minDurationMinutes else { continue }
            found.append((a, b, open))
        }
        var out: [ExerciseSessionSpan] = []
        var busy = Set<Int>()
        var previousPre: Double?
        var lastConfirmedEnd: Int?
        for (k, s) in found.enumerated() {
            let lo = max(0, s.a - preWindowMinutes.from), hi = max(0, s.a - preWindowMinutes.to)
            let preVals = (lo..<hi).compactMap { busy.contains($0) ? nil : grid[$0].hr }
            let pre = median(preVals) ?? previousPre ?? rest
            previousPre = pre
            let confirmedAt = confirmation(a: s.a, b: s.b, grid: grid, lastConfirmedEnd: lastConfirmedEnd)
            if confirmedAt != nil { lastConfirmedEnd = s.b }
            var recoveryEnd: Int?
            if !s.open, confirmedAt == nil {
                // Unconfirmed (stored as `active`): no recovery. Its minutes stay out of later pre-references.
                recoveryEnd = t0 + (s.b + 1) * 60
                busy.formUnion(s.a...s.b)
            } else if !s.open {
                let duration = s.b - s.a + 1
                let cap = min(max(duration, recoveryCapMinutes.lowerBound), recoveryCapMinutes.upperBound)
                var limit = min(n, s.b + 1 + cap)
                if k + 1 < found.count { limit = min(limit, found[k + 1].a) }
                var end = limit
                var run = 0
                for i in (s.b + 1)..<max(s.b + 1, limit) {
                    if let h = grid[i].hr, h <= pre + returnDeltaBpm {
                        run += 1
                        if run == returnRunMinutes { end = i - returnRunMinutes + 1; break }
                    } else {
                        run = 0
                    }
                }
                // A cap that runs past the data is not an end yet unless a later session closed it.
                if end == n, s.b + 1 + cap > n, k + 1 >= found.count, nowUnix != nil {
                    recoveryEnd = nil
                } else {
                    recoveryEnd = t0 + end * 60
                }
                busy.formUnion(s.a..<end)
            } else {
                busy.formUnion(s.a..<n)
            }
            let hrs = (s.a...s.b).compactMap { grid[$0].hr }.sorted()
            out.append(ExerciseSessionSpan(
                startUnix: t0 + s.a * 60, endUnix: t0 + s.b * 60, recoveryEndUnix: recoveryEnd,
                preReference: pre, open: s.open,
                hrP50: quantile(hrs, 0.5), hrP90: quantile(hrs, 0.9), hrPeak: hrs.last,
                load: hrs.reduce(0) { $0 + max(0, $1 - rest) },
                confirmed: confirmedAt != nil, confirmedAtUnix: confirmedAt.map { t0 + $0 * 60 }))
        }
        return out
    }

    /// Grid index that confirms the session `[a, b]`, or nil: `a` when it starts at most `inheritMinutes` after the
    /// last evidence minute of the previous confirmed session (inheritance chains forward only), else the
    /// `minConfirmStrong`-th strong minute of the period.
    static func confirmation(a: Int, b: Int, grid: [ExerciseSessionMinute], lastConfirmedEnd: Int?) -> Int? {
        if let last = lastConfirmedEnd, a - last <= inheritMinutes { return a }
        var count = 0
        for i in a...b where grid[i].strong {
            count += 1
            if count == minConfirmStrong { return i }
        }
        return nil
    }

    /// The phase of each minute in `[fromUnix, toUnix)`: inside a session (open sessions run to `toUnix`, confirmed
    /// or not), in a confirmed session's recovery, inside an ended unconfirmed session (`active`), or none.
    public static func phases(_ spans: [ExerciseSessionSpan], fromUnix: Int, toUnix: Int) -> [ExerciseSessionPhase] {
        stride(from: fromUnix, to: toUnix, by: 60).map { m in
            for s in spans {
                let sessionEnd = s.open ? Int.max : s.endUnix
                if m >= s.startUnix && m <= sessionEnd { return s.open || s.confirmed ? .session : .active }
                if !s.open, s.confirmed, m > s.endUnix, m < (s.recoveryEndUnix ?? Int.max) { return .recovery }
            }
            return .none
        }
    }

    /// The session (open, or whose recovery covers `unix`; an unconfirmed one only up to its end) a minute belongs to.
    public static func span(at unix: Int, in spans: [ExerciseSessionSpan]) -> ExerciseSessionSpan? {
        spans.last { s in
            unix >= s.startUnix && (s.open || unix < (s.recoveryEndUnix ?? Int.max))
        }
    }

    // MARK: Helpers

    static func contiguous(_ minutes: [ExerciseSessionMinute]) -> [ExerciseSessionMinute] {
        let sorted = minutes.sorted { $0.minuteUnix < $1.minuteUnix }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var byMinute: [Int: ExerciseSessionMinute] = [:]
        for m in sorted { byMinute[m.minuteUnix] = m }
        return stride(from: first.minuteUnix, through: last.minuteUnix, by: 60).map {
            byMinute[$0] ?? ExerciseSessionMinute(minuteUnix: $0, hr: nil, strong: false, weak: false)
        }
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}

// MARK: - Recurring routine (interpretation and display only)

/// When this person usually exercises: sessions grouped by day type (weekday / weekend) and start time. A routine
/// explains ("this matches your usual weekday evening session"); it never opens a session, widens a bound or turns
/// an alert into "usual".
public struct ExerciseRoutine: Equatable, Sendable, Codable {
    public struct Cluster: Equatable, Sendable, Codable {
        public var dayType: String          // "weekday" | "weekend"
        /// Typical local start, minutes after midnight (circular median).
        public var startMinute: Int
        /// Half-width of the start band, minutes.
        public var spreadMinutes: Int
        public var sessions: Int
        /// Matching days with a session in the last 14 days ÷ matching days in the last 14 days.
        public var recentShare: Double
        public var durationMinutesP50: Int
        public var hrP50: Double?
        public var hrP90: Double?
        /// 90th percentile of the sessions' peak HR (the personal in-session ceiling's basis).
        public var hrPeakP90: Double?
        /// Active: seen on ≥ 50 % of matching days in the last 14 days. A lapsed routine is kept but not described
        /// as usual.
        public var active: Bool
    }
    public var clusters: [Cluster]
    public var sessionCount: Int
    public var rule: String = ExerciseSessionRule.rule

    public static let empty = ExerciseRoutine(clusters: [], sessionCount: 0)
    public static let minSessionsPerCluster = 3
    public static let clusterBandMinutes = 90

    /// Builds the routine from completed, confirmed sessions (rule exercise-session-2: an unconfirmed period never
    /// trains a routine or the in-session ceiling). `calendar` carries the person's time zone. `historyStartUnix` is
    /// when the evidence history begins (days before it are not misses); nil = the first session's day.
    public static func build(_ spans: [ExerciseSessionSpan], nowUnix: Int, historyStartUnix: Int? = nil,
                             calendar: Calendar = .current) -> ExerciseRoutine {
        let done = spans.filter { !$0.open && $0.confirmed }
        func local(_ unix: Int) -> (minute: Int, weekend: Bool, day: Int) {
            let d = Date(timeIntervalSince1970: TimeInterval(unix))
            let c = calendar.dateComponents([.hour, .minute, .weekday], from: d)
            let day = Int(calendar.startOfDay(for: d).timeIntervalSince1970)
            return ((c.hour ?? 0) * 60 + (c.minute ?? 0), c.weekday == 1 || c.weekday == 7, day)
        }
        var clusters: [Cluster] = []
        for weekend in [false, true] {
            let group = done.filter { local($0.startUnix).weekend == weekend }
            var remaining = group.sorted { local($0.startUnix).minute < local($1.startUnix).minute }
            while !remaining.isEmpty {
                // Greedy band: the densest clusterBandMinutes-wide window of start times.
                let starts = remaining.map { local($0.startUnix).minute }
                var best = (lo: 0, count: 0)
                for (i, s) in starts.enumerated() {
                    let count = starts[i...].prefix { $0 - s <= clusterBandMinutes }.count
                    if count > best.count { best = (i, count) }
                }
                let members = Array(remaining[best.lo..<(best.lo + best.count)])
                remaining.removeSubrange(best.lo..<(best.lo + best.count))
                guard members.count >= minSessionsPerCluster else { continue }
                let ms = members.map { local($0.startUnix).minute }.sorted()
                let center = ms[ms.count / 2]
                let spread = ms.map { abs($0 - center) }.max() ?? 0
                let durations = members.map(\.durationMinutes).sorted()
                let p50s = members.compactMap(\.hrP50)
                let p90s = members.compactMap(\.hrP90)
                let peaks = members.compactMap(\.hrPeak).sorted()
                // Recent share over matching days in the last 14 days.
                let today = local(nowUnix).day
                let since = local(historyStartUnix ?? done.map(\.startUnix).min() ?? nowUnix).day
                let matchingDays = (0..<14).map { today - $0 * 86_400 }.filter { $0 >= since }.filter { day in
                    let wd = calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(day + 43_200)))
                    return (wd == 1 || wd == 7) == weekend
                }
                let sessionDays = Set(members.map { local($0.startUnix).day })
                let hit = matchingDays.filter { sessionDays.contains($0) }.count
                let share = matchingDays.isEmpty ? 0 : Double(hit) / Double(matchingDays.count)
                clusters.append(Cluster(dayType: weekend ? "weekend" : "weekday", startMinute: center,
                                        spreadMinutes: spread, sessions: members.count, recentShare: share,
                                        durationMinutesP50: durations[durations.count / 2],
                                        hrP50: ExerciseSessionRule.median(p50s), hrP90: ExerciseSessionRule.median(p90s),
                                        hrPeakP90: ExerciseSessionRule.quantile(peaks, 0.9),
                                        active: share >= 0.5))
            }
        }
        return ExerciseRoutine(clusters: clusters, sessionCount: done.count)
    }

    /// The active cluster a session starting at `unix` belongs to, if any.
    public func match(startUnix unix: Int, calendar: Calendar = .current) -> Cluster? {
        let d = Date(timeIntervalSince1970: TimeInterval(unix))
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: d)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let dayType = (c.weekday == 1 || c.weekday == 7) ? "weekend" : "weekday"
        return clusters.first { $0.active && $0.dayType == dayType
            && abs($0.startMinute - minute) <= max($0.spreadMinutes, 30) + 30 }
    }
}
