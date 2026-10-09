import Foundation
import WhoopStore

// LongitudinalBaselineContext.swift — context-stratified daily values for Layer 1 v2 (docs/BASELINE_WATCHDOG_V2.md §3).
//
// The source is the activity-context interval table the phone already writes for the whole day (the existing
// activity classification system: HSMM decoder class + posture / locomotion / sleep / wear channels + per-interval
// HR and RMSSD components). v1's awake-rest series came from minutes sampled only while the Watchdog tick ran
// (i.e. while the app was open), so a "day" described the app's usage, not the person's day.
//
// Rules (each one from the audit):
//   • Off-wrist intervals never count. `on_wrist` is the decoder's default ("had data and no WRIST_OFF"), so it
//     is NOT positive wear evidence: an interval must also carry HR on ≥ 50 % of its seconds.
//   • Posture strata need the activity class AND the posture channel to agree, class confidence ≥ 0.6 and
//     evidence quality ≥ 0.5. Posture is the weakest wrist inference (decoder standing precision 0.13 on
//     capture24 in the 2026-10-07 activity audit), so anything less stays in the pooled awake-rest series only.
//   • Steady state: an interval that starts < 120 s after a posture change or locomotion, < 10 min after walking
//     or < 30 min after running / cycling / vigorous activity is excluded (orthostatic and post-exercise HR/HRV
//     transients; HRV fix E, `ActivityTransitionProximity`).
//   • Motion: intensity must be known and ≤ 0.40 (the HRV-fix motion gate, ≈ 49 mg); unknown motion is never rest.
//     An `in_vehicle` row (detail on a sitting row) is never rest either, however still the wrist reads.
//   • HR per stratum-day: sample-weighted mean of interval means. HRV: pooled √(Σd²/Σn) of the stored successive-
//     difference components (never an average of RMSSDs); rows older than v49 fall back to n = rrBeats − 1.
//   • Within-day scale: weighted MAD of the interval values (≥ 3 intervals) for live short-window comparisons.

/// Body position of an awake still stratum.
public enum LBPosture: String, Equatable, Sendable, Codable, CaseIterable {
    case supine
    case seated
    case upright
}

extension LongitudinalBaseline {

    public enum ContextMaterializer {
        public static let version = "lb-context-1"
        public static let minClassConfidence = 0.6
        public static let minEvidenceQuality = 0.5
        public static let maxStillIntensity = 0.40
        public static let minHrCoverage = 0.5
        public static let settleAfterTransitionS = 120
        public static let settleAfterWalkingS = 600
        public static let settleAfterVigorousS = 1800
        /// Steady walking: the first 180 s of a walking bout are the HR on-transient.
        public static let walkingOnTransientS = 180
        public static let minHRVPairs = 120
        /// "Long ago" sentinel for unix seconds (a minimum Int would overflow `now - sentinel`).
        static let never = -(1 << 40)

        static let vigorousClasses: Set<String> = ["running", "cycling", "vigorous_activity", "brisk_walking"]
        static let walkingClasses: Set<String> = ["walking"]

        /// Posture the interval supports, or nil when class and posture channel do not agree confidently.
        public static func posture(of r: ActivityContextIntervalRow) -> LBPosture? {
            guard r.confidence >= minClassConfidence, r.evidenceQuality >= minEvidenceQuality else { return nil }
            switch r.activityClass {
            case "lying_down":
                return (r.posture == nil || r.posture == "recumbent") ? .supine : nil
            case "sitting", "sitting_desk":
                return (r.posture == nil || r.posture == "seated_likely") ? .seated : nil
            case "standing":
                return (r.posture == nil || r.posture == "upright_stationary") ? .upright : nil
            default:
                return nil
            }
        }

        static func worn(_ r: ActivityContextIntervalRow) -> Bool {
            guard r.wearState != "off_wrist", r.durationSeconds > 0 else { return false }
            return Double(r.hrSamples) >= minHrCoverage * Double(r.durationSeconds)
        }

        /// A vehicle ride is seated but not rest (`ActivityContextInterval.detail`), so it never feeds a rest stratum.
        static func still(_ r: ActivityContextIntervalRow) -> Bool {
            guard r.detail != ActivityDetail.inVehicle.rawValue else { return false }
            guard let i = r.intensity, i <= maxStillIntensity else { return false }
            return (r.locomotion ?? "stationary") == "stationary"
                && !vigorousClasses.contains(r.activityClass) && !walkingClasses.contains(r.activityClass)
        }

        /// Civil day of an awake interval (its start) or a sleep interval (midpoint + 6 h: the wake day).
        static func civilDay(_ r: ActivityContextIntervalRow, calendar: Calendar, asleep: Bool) -> String {
            let ts = asleep ? (r.startTs + r.endTs) / 2 + 6 * 3600 : r.startTs
            let comps = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        }

        struct Acc {
            var hrW = 0.0, hrSum = 0.0
            var sq = 0.0, pairs = 0
            var minutes = 0.0
            var hrValues: [(Double, Double)] = []      // (interval mean, weight)
            var lnRmssdValues: [(Double, Double)] = []

            mutating func add(_ r: ActivityContextIntervalRow, hr: Bool, hrv: Bool) {
                if hr, let m = r.hrMean, m.isFinite, m >= 30, m <= 220, r.hrSamples > 0 {
                    hrW += Double(r.hrSamples)
                    hrSum += m * Double(r.hrSamples)
                    minutes += Double(r.hrSamples) / 60
                    hrValues.append((m, Double(r.hrSamples)))
                }
                if hrv {
                    var n = r.rrDiffCount
                    var s = r.rrDiffSqSumMs2
                    if n == 0, let rm = r.rmssd, rm > 0, r.rrBeats >= 2 {
                        // Pre-v49 row: recover the components from the stored RMSSD (HRV fix A fallback).
                        n = r.rrBeats - 1
                        s = rm * rm * Double(n)
                    }
                    if n > 0, s > 0 {
                        sq += s
                        pairs += n
                        lnRmssdValues.append((log((s / Double(n)).squareRoot()), Double(n)))
                    }
                }
            }

            static func weightedMedian(_ xs: [(Double, Double)]) -> Double? {
                let s = xs.filter { $0.0.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
                let total = s.reduce(0) { $0 + $1.1 }
                guard total > 0 else { return nil }
                var acc = 0.0
                for (v, w) in s {
                    acc += w
                    if acc >= total / 2 { return v }
                }
                return s.last?.0
            }

            static func weightedMADScale(_ xs: [(Double, Double)]) -> Double? {
                guard xs.count >= 3, let m = weightedMedian(xs) else { return nil }
                guard let mad = weightedMedian(xs.map { (abs($0.0 - m), $0.1) }) else { return nil }
                return PhysiologyContext.RobustStats.madNormalConsistency * mad
                    * PhysiologyContext.RobustStats.madSmallSampleFactor(xs.count)
            }
        }

        /// Daily observations for every context series from interval rows (any order, any days).
        public static func observations(rows: [ActivityContextIntervalRow],
                                        calendar: Calendar = .current) -> [LBSeries: [LBDailyObservation]] {
            let sorted = rows.sorted { $0.startTs < $1.startTs }
            var acc: [LBSeries: [String: Acc]] = [:]
            // Start of the current still bout of one posture (a posture change, movement, sleep, a gap or
            // off-wrist ends a bout). The first interval of a bout and anything within 120 s of its start is the
            // orthostatic transient and is excluded.
            var boutStart = Self.never
            var lastWalkingEnd = Self.never
            var lastVigorousEnd = Self.never
            var prevStillPosture: LBPosture?? = nil   // .none = previous interval was not awake-still
            var walkingBoutStart: Int? = nil
            var prevEnd = Self.never

            for r in sorted {
                let contiguous = r.startTs - prevEnd <= 60
                defer { prevEnd = r.endTs }
                let isAsleep = r.sleepState == "asleep"
                let isAwake = r.sleepState == "awake"
                let isVigorous = vigorousClasses.contains(r.activityClass)
                    || r.locomotion == "running" || r.locomotion == "brisk_walking"
                let isWalking = walkingClasses.contains(r.activityClass) || r.locomotion == "walking"

                defer {
                    if isVigorous { lastVigorousEnd = r.endTs }
                    if isWalking { lastWalkingEnd = r.endTs }
                }

                guard worn(r) else {
                    walkingBoutStart = nil
                    prevStillPosture = nil
                    continue
                }

                if isAsleep {
                    let day = civilDay(r, calendar: calendar, asleep: true)
                    acc[.sleepHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                    prevStillPosture = nil
                    walkingBoutStart = nil
                    continue
                }
                guard isAwake else { prevStillPosture = nil; walkingBoutStart = nil; continue }
                let day = civilDay(r, calendar: calendar, asleep: false)

                // Steady walking.
                if isWalking, !isVigorous, (r.intensity ?? 0) > 0 {
                    if walkingBoutStart == nil || !contiguous { walkingBoutStart = r.startTs }
                    if r.startTs - (walkingBoutStart ?? r.startTs) >= walkingOnTransientS {
                        acc[.walkingHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                    }
                    prevStillPosture = nil
                    continue
                }
                walkingBoutStart = nil

                guard still(r) else {
                    prevStillPosture = nil
                    continue
                }
                let p = posture(of: r)
                let sameBout: Bool = {
                    guard contiguous, let prev = prevStillPosture else { return false }
                    return prev == p
                }()
                if !sameBout { boutStart = r.startTs }
                prevStillPosture = .some(p)
                let settled = r.startTs - boutStart >= settleAfterTransitionS
                    && r.startTs - lastWalkingEnd >= settleAfterWalkingS
                    && r.startTs - lastVigorousEnd >= settleAfterVigorousS
                guard settled else { continue }

                acc[.awakeRestHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                acc[.awakeRestHRVLn, default: [:]][day, default: Acc()].add(r, hr: false, hrv: true)
                switch p {
                case .supine?:
                    acc[.awakeSupineHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                    acc[.awakeSupineHRVLn, default: [:]][day, default: Acc()].add(r, hr: false, hrv: true)
                case .seated?:
                    acc[.awakeSeatedHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                    acc[.awakeSeatedHRVLn, default: [:]][day, default: Acc()].add(r, hr: false, hrv: true)
                case .upright?:
                    acc[.awakeUprightHR, default: [:]][day, default: Acc()].add(r, hr: true, hrv: false)
                    acc[.awakeUprightHRVLn, default: [:]][day, default: Acc()].add(r, hr: false, hrv: true)
                case nil:
                    break
                }
            }

            var out: [LBSeries: [LBDailyObservation]] = [:]
            for (series, days) in acc {
                var obs: [LBDailyObservation] = []
                for (day, a) in days.sorted(by: { $0.key < $1.key }) {
                    let native: Double?
                    let coverage: Double
                    let within: Double?
                    if series.usesLog {
                        native = a.pairs >= minHRVPairs ? (a.sq / Double(a.pairs)).squareRoot() : nil
                        coverage = Double(a.pairs) / 60      // ≈ minutes of clean beat pairs at 60 bpm
                        within = Acc.weightedMADScale(a.lnRmssdValues)
                    } else {
                        native = a.hrW > 0 ? a.hrSum / a.hrW : nil
                        coverage = a.minutes
                        within = Acc.weightedMADScale(a.hrValues)
                    }
                    var o = LongitudinalBaseline.observation(day: day, native: native, streamPresent: true,
                                                             sleepHrOnly: false, series: series)
                    o.coverage = coverage
                    o.withinDayScale = within
                    obs.append(LongitudinalBaseline.applyCoverageGate(o, series: series))
                }
                out[series] = obs
            }
            return out
        }
    }
}
