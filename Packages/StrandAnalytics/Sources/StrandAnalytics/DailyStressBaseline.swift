import Foundation
import WhoopStore

// DailyStressBaseline.swift — the personal baseline behind the Stress screen's DAILY autonomic proxy
// (BaselineStandard fix E, audit 2026-10-07 "StressView").
//
// What was wrong (StressView.StressModel): the baseline was the plain mean and POPULATION SD of up to 30 ROWS
// before the scored day, usable from ONE row, with an SD "floor" of 0.0001 (so two identical nights made any
// change read as a huge z), on raw-ms HRV; and the WHOLE trend line was rescored against TODAY's baseline, so
// every past point moved whenever a new night arrived (look-ahead for the past).
//
// What this does. Each day is judged against its OWN reference: the robust median / MAD (PhysiologyContext's
// small-sample factor) of the 30 CALENDAR days strictly before it (rules 2, 7), resting HR in bpm floored at
// 1 bpm, HRV on ln(RMSSD) floored at 0.05 (rules 1, 5), confounded and SDNN days out (rules 1, 3), stopping at a
// regime change or the reference epoch (rule 6), and no comparison below 4 valid days (rule 4). The combined
// raw score and the 0–3 logistic squash are the shipped ones (RHR up and HRV down both push it up).

public enum DailyStressBaseline {

    /// Calendar days in each day's reference window (the shipped "up to 30 days").
    public static let windowDays = 30

    /// The two references one day is judged against.
    public struct Reference: Equatable, Sendable {
        public let restingHR: BaselineStandard.Reference
        public let hrv: BaselineStandard.Reference
    }

    /// One day's derived stress read.
    public struct DayScore: Equatable, Sendable {
        public let day: String
        /// Combined autonomic z: (RHR − centre)/σ + (ln centre − ln HRV)/σ_ln over the signals with a usable
        /// reference.
        public let raw: Double
        /// `squash(raw)`, 0–3 (baseline 0 → 1.5).
        public let score: Double
        /// Resting HR minus the reference median (bpm); nil when that reference is not usable.
        public let rhrDelta: Double?
        /// HRV minus the reference centre in ms (exp of the ln median); nil when not usable.
        public let hrvDeltaMs: Double?
    }

    /// The references `day` is judged against (the 30 calendar days strictly before it).
    public static func reference(days: [DailyMetric], asOf day: String,
                                 context: BaselineStandard.Context = BaselineStandard.Context()) -> Reference {
        let rhr = BaselineStandard.series(days, day: \.day) { $0.restingHr.map(Double.init) }
        let hrv = BaselineStandard.series(days, day: \.day, value: \.avgHrv)
        return reference(rhr: rhr, hrv: hrv, asOf: day, context: context)
    }

    static func reference(rhr: [String: Double], hrv: [String: Double], asOf day: String,
                          context: BaselineStandard.Context) -> Reference {
        Reference(
            restingHR: BaselineStandard.windowReference(rhr, metric: .restingHR, asOf: day,
                                                        windowDays: windowDays, context: context),
            hrv: BaselineStandard.windowReference(hrv, metric: .hrvRmssd, asOf: day,
                                                  windowDays: windowDays, context: context))
    }

    /// Score one day against `reference`. nil when neither signal can be compared (no value, or a reference
    /// below 4 valid days, or an SDNN HRV against the RMSSD reference).
    public static func score(day: String, rhr: Double?, hrvMs: Double?, reference: Reference,
                             context: BaselineStandard.Context = BaselineStandard.Context()) -> DayScore? {
        let zR = rhr.flatMap { reference.restingHR.z($0) }
        let zH = context.comparable(day, metric: .hrvRmssd) ? hrvMs.flatMap { reference.hrv.z($0) } : nil
        guard zR != nil || zH != nil else { return nil }
        let raw = (zR ?? 0) - (zH ?? 0)
        return DayScore(day: day, raw: raw, score: squash(raw),
                        rhrDelta: zR != nil ? rhr.map { $0 - reference.restingHR.centerNative } : nil,
                        hrvDeltaMs: zH != nil ? hrvMs.map { $0 - reference.hrv.centerNative } : nil)
    }

    /// Every day's derived read, each against ITS OWN causal reference (never today's), keyed by day.
    public static func trend(days: [DailyMetric],
                             context: BaselineStandard.Context = BaselineStandard.Context()) -> [String: DayScore] {
        let rhr = BaselineStandard.series(days, day: \.day) { $0.restingHr.map(Double.init) }
        let hrv = BaselineStandard.series(days, day: \.day, value: \.avgHrv)
        var out: [String: DayScore] = [:]
        for d in days {
            let ref = reference(rhr: rhr, hrv: hrv, asOf: d.day, context: context)
            if let s = score(day: d.day, rhr: d.restingHr.map(Double.init), hrvMs: d.avgHrv,
                             reference: ref, context: context) {
                out[d.day] = s
            }
        }
        return out
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). The shipped curve.
    public static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }
}
