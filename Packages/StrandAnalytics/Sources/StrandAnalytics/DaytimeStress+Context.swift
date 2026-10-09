import Foundation
import WhoopProtocol

// DaytimeStress+Context.swift - the sleep / activity / posture context a daytime-stress hour is read in
// (D4-05, D6-05, D8-12).
//
// "Waking" used to mean the CLOCK (06:00-22:00) and nothing else, in both the day-relative scorer and the
// personal baseline aggregate. A sleep-in to 08:30 or an afternoon nap therefore put sleeping-HR hours into
// the calm floor, so ordinary seated hours read as stress afterwards; and the baseline aggregate had no
// ambulatory mask while the scorer did, so the two sides of the comparison sat in different regimes.
//
// `DayContext` carries the day's detected sleep / in-bed blocks and its stored activity-context intervals
// (both optional: an empty context is byte-identical to the pre-context read). Per hour bucket it yields
// a `HourContext` of time shares, and ONE mask rule that the scorer and the baseline aggregate both use:
//   - asleep: at least `sleepMaskShare` of the hour inside a sleep / in-bed block (or a `sleeping` run) ->
//     the hour is neither scored nor part of any calm reference or baseline aggregate;
//   - ambulatory: the gravity motion gate OR at least `activityMaskFraction` of the hour in an active /
//     locomotion run -> masked as activity (the existing semantics, now also reachable without gravity);
//   - posture (D8-12): of the hour's awake stationary time, a majority committed `standing` flags the hour
//     `uprightCommitted`; a majority with posture unresolved (`stationary`, `fidgeting`, `unknown`) flags
//     it `postureUnresolved`. Wrist IMU cannot reliably separate sitting from standing, so nothing here
//     invents a posture: unresolved stays unresolved, and the shares are provenance on the hour.
//     An upright-committed hour is still SCORED (its HR is real), but it is kept out of the calm reference
//     and the baseline aggregate (an orthostatic +8-12 bpm is not the seated calm floor), and it cannot on
//     its own back the sustained-high nudge.

public extension DaytimeStress {

    /// A detected sleep / in-bed block on the wall clock, `[start, end)` in unix seconds.
    struct SleepSpan: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    /// The day's context: detected sleep / in-bed blocks plus the stored activity-context intervals.
    struct DayContext: Equatable, Sendable {
        public let sleepSpans: [SleepSpan]
        public let intervals: [ActivityContextInterval]
        public init(sleepSpans: [SleepSpan] = [], intervals: [ActivityContextInterval] = []) {
            self.sleepSpans = sleepSpans
            self.intervals = intervals
        }
        /// No context: every read is byte-identical to the clock-only behaviour.
        public static let none = DayContext()
        public var isEmpty: Bool { sleepSpans.isEmpty && intervals.isEmpty }
    }

    /// The posture call for an hour's awake stationary time. Never a guess: `postureUnresolved` is the
    /// honest answer when the decoder itself did not commit.
    enum PostureFlag: String, Equatable, Sendable {
        /// Seated / lying majority, or too little stationary time to say anything.
        case none
        /// A majority of the stationary time was committed `standing`.
        case uprightCommitted
        /// A majority of the stationary time had no resolved posture.
        case postureUnresolved
    }

    /// Per-hour context shares (fractions of the hour, 0...1) and the posture flag derived from them.
    struct HourContext: Equatable, Sendable {
        /// Fraction of the hour covered by any activity-context interval.
        public let coveredShare: Double
        /// Asleep / in bed (detected blocks union `sleeping` runs).
        public let sleepShare: Double
        /// Active / locomotion runs (light activity and above).
        public let activeShare: Double
        /// Committed `standing`.
        public let uprightShare: Double
        /// `sitting` / `sitting_desk`.
        public let seatedShare: Double
        /// Awake `lying_down`.
        public let lyingShare: Double
        /// Stationary with posture unresolved (`stationary`, `fidgeting`, `unknown`).
        public let unresolvedShare: Double
        /// `off_wrist`.
        public let offWristShare: Double
        public let postureFlag: PostureFlag

        public init(coveredShare: Double, sleepShare: Double, activeShare: Double, uprightShare: Double,
                    seatedShare: Double, lyingShare: Double, unresolvedShare: Double, offWristShare: Double,
                    postureFlag: PostureFlag) {
            self.coveredShare = coveredShare; self.sleepShare = sleepShare; self.activeShare = activeShare
            self.uprightShare = uprightShare; self.seatedShare = seatedShare; self.lyingShare = lyingShare
            self.unresolvedShare = unresolvedShare; self.offWristShare = offWristShare
            self.postureFlag = postureFlag
        }
    }

    /// An hour at least this much inside a sleep / in-bed block is "mostly asleep" and leaves the read.
    static let sleepMaskShare: Double = 0.5
    /// A posture flag needs at least this much awake stationary time in the hour to mean anything.
    static let postureMinStationaryShare: Double = 0.25
    /// Majority rule for both posture flags.
    static let postureMajorityShare: Double = 0.5
}

extension DaytimeStress {

    /// A local hour-bucket start for `localTs`, offset by `phase` seconds (0 for the on-the-hour grid).
    static func bucketOf(_ localTs: Int, phase: Int) -> Int {
        floorDiv(localTs - phase, bucketSeconds) * bucketSeconds + phase
    }

    /// Fraction of each local bucket's activity records that clear the walk floor (the motion gate's
    /// input), from an already-derived `WorkoutDetector.activitySeries`. Shared by the scorer and the
    /// baseline aggregate so the two use one ambulatory definition.
    static func activeFractions(_ activity: [WorkoutDetector.ActivityPoint], tzOffsetSeconds: Int,
                                phase: Int) -> [Int: Double] {
        var out: [Int: Double] = [:]
        guard !activity.isEmpty else { return out }
        var counts: [Int: (active: Int, total: Int)] = [:]
        for p in activity {
            let bucket = bucketOf(p.ts + tzOffsetSeconds, phase: phase)
            var e = counts[bucket] ?? (0, 0)
            e.total += 1
            if p.intensity > WorkoutDetector.motionThreshold { e.active += 1 }
            counts[bucket] = e
        }
        for (b, e) in counts where e.total > 0 {
            out[b] = Double(e.active) / Double(e.total)
        }
        return out
    }

    /// Context, pre-merged for per-bucket lookups.
    struct ContextIndex {
        let sleepUnion: [(start: Int, end: Int)]
        let intervals: [ActivityContextInterval]
        let isEmpty: Bool

        init(_ ctx: DayContext) {
            var spans = ctx.sleepSpans.map { (start: $0.start, end: $0.end) }
            spans += ctx.intervals.filter { $0.activityClass == .sleeping }.map { (start: $0.start, end: $0.end) }
            spans = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
            var merged: [(start: Int, end: Int)] = []
            for s in spans {
                if let last = merged.last, s.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, s.end)
                } else {
                    merged.append(s)
                }
            }
            sleepUnion = merged
            intervals = ctx.intervals.filter { $0.end > $0.start }
            isEmpty = ctx.isEmpty
        }

        /// The hour context for the LOCAL bucket starting at `localBucket`, or nil when the day carried no
        /// context at all (so a context-free read is unchanged).
        func hour(localBucket: Int, tzOffsetSeconds: Int) -> HourContext? {
            guard !isEmpty else { return nil }
            let ws = localBucket - tzOffsetSeconds
            let we = ws + DaytimeStress.bucketSeconds
            let len = Double(DaytimeStress.bucketSeconds)
            func overlap(_ s: Int, _ e: Int) -> Int { max(0, min(e, we) - max(s, ws)) }
            var sleepS = 0
            for s in sleepUnion where s.end > ws && s.start < we { sleepS += overlap(s.start, s.end) }
            var covered = 0, active = 0, upright = 0, seated = 0, lying = 0, unresolved = 0, off = 0
            for iv in intervals where iv.end > ws && iv.start < we {
                let o = overlap(iv.start, iv.end)
                covered += o
                switch iv.activityClass {
                case .sleeping: break   // counted through the sleep union
                case .offWrist: off += o
                case .lyingDown: lying += o
                case .sitting, .sittingDesk: seated += o
                case .standing: upright += o
                case .stationary, .fidgeting, .unknown: unresolved += o
                case .lightActivity, .walking, .briskWalking, .running, .cycling, .vigorousActivity: active += o
                }
            }
            let sleepShare = min(1, Double(sleepS) / len)
            // Posture is judged on AWAKE stationary time only; time inside a sleep block is not posture
            // evidence for the awake hour (an in-bed lying run is the sleep share, not the lying share).
            let stationary = Double(upright + seated + lying + unresolved) / len
            let flag: PostureFlag
            if stationary < DaytimeStress.postureMinStationaryShare {
                flag = .none
            } else if Double(upright) / len >= DaytimeStress.postureMajorityShare * stationary {
                flag = .uprightCommitted
            } else if Double(unresolved) / len >= DaytimeStress.postureMajorityShare * stationary {
                flag = .postureUnresolved
            } else {
                flag = .none
            }
            return HourContext(coveredShare: min(1, Double(covered) / len), sleepShare: sleepShare,
                               activeShare: Double(active) / len, uprightShare: Double(upright) / len,
                               seatedShare: Double(seated) / len, lyingShare: Double(lying) / len,
                               unresolvedShare: Double(unresolved) / len, offWristShare: Double(off) / len,
                               postureFlag: flag)
        }
    }

    /// The ONE per-hour mask rule both the scorer and the baseline aggregate apply.
    static func hourMask(gravityActiveFraction: Double?, context: HourContext?)
        -> (asleep: Bool, ambulatory: Bool, upright: Bool) {
        let asleep = (context?.sleepShare ?? 0) >= sleepMaskShare
        let ambulatory = (gravityActiveFraction ?? 0) >= activityMaskFraction
            || (context?.activeShare ?? 0) >= activityMaskFraction
        let upright = context?.postureFlag == .uprightCommitted
        return (asleep, ambulatory, upright)
    }

    /// Memo-key fingerprint of a context (in-process only, like every `StreamFingerprint`).
    static func contextFingerprint(_ ctx: DayContext) -> StreamFingerprint {
        var items: [(ts: Int, q: Int)] = ctx.sleepSpans.map { (ts: $0.start, q: $0.end &* 2) }
        for iv in ctx.intervals {
            let cls = iv.activityClass.rawValue.utf8.reduce(0) { $0 &* 31 &+ Int($1) }
            items.append((ts: iv.start, q: iv.end &* 2 &+ 1 &+ cls &* 1_000_003))
        }
        return StreamFingerprint.of(items, ts: { $0.ts }, quant: { $0.q })
    }
}
