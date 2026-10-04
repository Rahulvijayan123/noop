import Foundation
import StrandAnalytics

// Checks.swift — pass/fail statements about a set of replayed days.
//
// Two groups. WIRING checks say the two numbers being compared are the numbers the app computes (so the
// comparison means something). BEHAVIOUR checks are the two properties the fusion estimator is for.

enum Checks {

    static func evaluate(_ runs: [DayRun], options: BenchOptions) -> [BenchCheck] {
        [
            legacyReproduced(runs),
            fusionIsTheTimeline(runs),
            restingIsTwentyFourHours(runs),
            valuesAreSane(runs),
            subThresholdActivityCredited(runs),
            lightDaysNotOvercounted(runs, options: options),
        ]
    }

    static func allPassed(_ checks: [BenchCheck]) -> Bool {
        !checks.contains { $0.outcome == .fail }
    }

    // MARK: Wiring

    /// The "legacy" column is `Calories.estimateDayEnergy` on the day's heart rate; `analyzeDay(.legacyHR)`
    /// must publish exactly that, or the replay is not pricing what the app priced.
    static func legacyReproduced(_ runs: [DayRun]) -> BenchCheck {
        let name = "legacy-total-reproduced"
        let diffs = runs.compactMap { r in r.legacyReportedTotal.map { (r.day, abs($0 - r.legacyTotal)) } }
        guard let worst = diffs.max(by: { $0.1 < $1.1 }) else {
            return BenchCheck(name: name, outcome: .notApplicable, detail: "no day reported a legacy total")
        }
        let ok = worst.1 <= 0.01
        let off = diffs.filter { $0.1 > 0.01 }.map { String(format: "%@ %.2f", $0.0, $0.1) }
        return BenchCheck(name: name, outcome: ok ? .pass : .fail,
                          detail: String(format: "largest |analyzeDay(.legacyHR) − Calories.estimateDayEnergy| = %.4f kcal (%@)",
                                         worst.1, worst.0) + (off.isEmpty ? "" : "; off on: " + off.joined(separator: ", ")))
    }

    /// `activeKcalEst` under `.fusion` is the estimator's total, and the total is the sum of its minutes:
    /// a workout is a label on the timeline, never a second source of energy.
    static func fusionIsTheTimeline(_ runs: [DayRun]) -> BenchCheck {
        let name = "fusion-total-is-the-timeline"
        var worstReported = 0.0, worstSum = 0.0, worstSubset = -Double.infinity
        for r in runs {
            if let reported = r.fusionReportedTotal { worstReported = max(worstReported, abs(reported - r.fusion.totalKcal)) }
            let sum = r.fusion.minutes.reduce(0.0) { $0 + $1.activeKcal + $1.restingKcal }
            worstSum = max(worstSum, abs(sum - r.fusion.totalKcal))
            worstSubset = max(worstSubset, r.fusion.workoutKcal - r.fusion.activeKcal)
        }
        let ok = worstReported <= 0.01 && worstSum <= 0.5 && worstSubset <= 1e-6
        return BenchCheck(name: name, outcome: ok ? .pass : .fail,
                          detail: String(format: "reported vs timeline %.4f kcal, Σ minutes vs total %.4f kcal, workout ⊂ active (%.4f)",
                                         worstReported, worstSum, worstSubset))
    }

    /// Resting energy is RMR/1440 for every elapsed minute, whatever the strap covered.
    static func restingIsTwentyFourHours(_ runs: [DayRun]) -> BenchCheck {
        let name = "resting-is-24h-and-coverage-independent"
        guard !runs.isEmpty else { return BenchCheck(name: name, outcome: .notApplicable, detail: "no days") }
        var worst = 0.0
        var worstDay = ""
        for r in runs {
            let expected = r.fusion.rmrKcalPerDay / 1440.0 * Double(r.fusion.expectedMinutes)
            let rel = expected > 0 ? abs(r.fusion.restingKcal - expected) / expected : 1
            if rel > worst { worst = rel; worstDay = r.day }
            if !r.partial, r.fusion.expectedMinutes != 1440 { worst = max(worst, 1); worstDay = r.day }
        }
        let ok = worst <= 0.002
        let gappy = runs.filter { $0.fusion.gapMinutes > 0 }.count
        return BenchCheck(name: name, outcome: ok ? .pass : .fail,
                          detail: String(format: "worst deviation from RMR/1440 × elapsed minutes = %.3f %% (%@); %d of %d days had coverage gaps and still counted every minute",
                                         worst * 100, worstDay.isEmpty ? "—" : worstDay, gappy, runs.count))
    }

    static func valuesAreSane(_ runs: [DayRun]) -> BenchCheck {
        let name = "values-are-finite-and-bounded"
        var problems: [String] = []
        for r in runs {
            let f = r.fusion
            if !(f.totalKcal.isFinite && f.activeKcal >= 0 && f.restingKcal > 0) { problems.append("\(r.day): totals") }
            if !(0...1).contains(f.confidence) { problems.append("\(r.day): day confidence \(f.confidence)") }
            for m in f.minutes {
                let ok = m.met.isFinite && m.met >= 1 && m.activeKcal.isFinite && m.activeKcal >= 0
                    && m.metSigma.isFinite && m.metSigma >= 0 && (0...1).contains(m.confidence)
                if !ok { problems.append("\(r.day): minute \(m.startTs)"); break }
            }
        }
        return BenchCheck(name: name, outcome: problems.isEmpty ? .pass : .fail,
                          detail: problems.isEmpty ? "every minute: MET ≥ 1, kcal ≥ 0, σ ≥ 0, confidence in [0, 1]"
                              : problems.prefix(5).joined(separator: "; "))
    }

    // MARK: Behaviour

    /// Sustained moderate activity whose every minute sat below the old HR gate is credited, at a MET a
    /// compendium would recognise for that activity, and strictly more than the old model credited.
    static func subThresholdActivityCredited(_ runs: [DayRun]) -> BenchCheck {
        subThresholdActivityCredited(bouts: runs.flatMap { r in r.bouts.filter(\.subThreshold).map { (r.day, $0) } })
    }

    /// The same judgement over bouts already known to be sub-gate (the part unit tests can feed directly).
    static func subThresholdActivityCredited(bouts: [(String, BoutRow)]) -> BenchCheck {
        let name = "sub-threshold-moderate-activity-credited"
        guard !bouts.isEmpty else {
            return BenchCheck(name: name, outcome: .notApplicable,
                              detail: "no sustained sub-gate bout found in these days (nothing to judge)")
        }
        var failures: [String] = []
        for (day, b) in bouts {
            let credited = b.fusionActiveKcal > b.legacyActiveKcal + 0.5 * Double(b.minutes)
            if !credited || !b.inBand {
                failures.append(String(format: "%@ %dmin MET %.2f (band %.1f–%.1f) fusion %.0f vs legacy %.0f kcal",
                                       day, b.minutes, b.fusionMeanMET, b.band.lowerBound, b.band.upperBound,
                                       b.fusionActiveKcal, b.legacyActiveKcal))
            }
        }
        let minutes = bouts.reduce(0) { $0 + $1.1.minutes }
        let fusion = bouts.reduce(0.0) { $0 + $1.1.fusionActiveKcal }
        let legacy = bouts.reduce(0.0) { $0 + $1.1.legacyActiveKcal }
        let summary = String(format: "%d bouts, %d min: fusion %.0f kcal vs legacy %.0f kcal above rest", bouts.count, minutes, fusion, legacy)
        return BenchCheck(name: name, outcome: failures.isEmpty ? .pass : .fail,
                          detail: failures.isEmpty ? summary : summary + "; failing: " + failures.prefix(4).joined(separator: " | "))
    }

    /// A day with no workout, no sustained session and little locomotion stays in sedentary-to-light
    /// territory: total energy within `lightDayMaxPAL` × RMR. The 30 %-gate figure is shown for context
    /// but is not a bound: it is itself a bad estimate, and on a day whose HR never reaches that gate it is
    /// resting-only, so "below it" would punish ordinary light movement.
    static func lightDaysNotOvercounted(_ runs: [DayRun], options: BenchOptions) -> BenchCheck {
        let name = "light-days-not-overcounted"
        let light = runs.filter { $0.lightDay && !$0.partial }
        guard !light.isEmpty else {
            return BenchCheck(name: name, outcome: .notApplicable, detail: "no complete light day in these days")
        }
        var failures: [String] = []
        for r in light where r.fusionPAL > options.lightDayMaxPAL {
            failures.append(String(format: "%@ PAL %.2f (max %.2f), fusion %.0f kcal (30%%-gate model %.0f)",
                                   r.day, r.fusionPAL, options.lightDayMaxPAL, r.fusion.totalKcal, r.ungatedTotal))
        }
        let worst = light.map(\.fusionPAL).max() ?? 0
        let summary = String(format: "%d light days, highest PAL %.2f (bound %.2f)", light.count, worst, options.lightDayMaxPAL)
        return BenchCheck(name: name, outcome: failures.isEmpty ? .pass : .fail,
                          detail: failures.isEmpty ? summary : summary + "; failing: " + failures.joined(separator: " | "))
    }
}
