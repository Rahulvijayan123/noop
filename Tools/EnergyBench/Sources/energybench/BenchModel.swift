import Foundation
import StrandAnalytics

// BenchModel.swift — the harness's option set and result records. Plain values, no behaviour.

/// Everything the operator can tune. The defaults are the harness's own fixed definitions of "moving",
/// "sustained" and "reasonable"; they are NOT read from the estimator's `EnergyConfig`, so the check
/// stays an independent witness rather than the model grading itself.
struct BenchOptions {
    /// Indirect-calorimetry RMR (kcal/day) to use for the 24 h resting term; nil = the population equation.
    var measuredRmr: Double?

    // MARK: Independent motion evidence
    /// Step-counter ticks per minute at or above which a minute counts as sustained locomotion. 80/min is
    /// the slow end of "moderate" walking in the cadence literature (≈ 2.5–3 METs at ~100 steps/min).
    var cadenceMoving: Double = 80
    /// Gravity-removed wrist motion (g) at or above which a minute counts as moving on a day with no step
    /// counter. Brisk walking sits at 0.15–0.30 g on this strap; stationary p50 is 0.017 g.
    var dynMoving: Double = 0.15
    /// A bout is a run of moving minutes at least this long, bridged across gaps of at most this many
    /// non-moving minutes (a stop at a crossing is not the end of a walk).
    var minBoutMinutes: Int = 10
    var gapToleranceMinutes: Int = 2
    /// A heart-rate-defined session: this many minutes at or above `sessionHRRFraction` of heart-rate
    /// reserve, with real wrist motion behind it (`sessionMinDyn`), so a stress spike or a hot shower is not
    /// a "session".
    var sessionMinutes: Int = 20
    var sessionHRRFraction: Double = 0.30
    var sessionMinDyn: Double = 0.05
    /// Fewest 1 Hz heart-rate rows in a minute for its mean to speak for the minute.
    var minHRRowsPerMinute: Int = 20
    /// At least this share of a bout's minutes must carry a heart-rate mean to judge it against the gate.
    var minHRCoverage: Double = 0.8

    // MARK: Plausibility bands (METs)
    /// Sustained walking at ≥ 80 steps/min: Compendium 17190 (slow, 2.0) to 17220 (very brisk, ~5).
    var locomotionMETBand: ClosedRange<Double> = 2.0...5.5
    /// A heart-rate-defined session with motion behind it: light circuit work to a hard run.
    var sessionMETBand: ClosedRange<Double> = 2.0...8.0

    // MARK: Light-day guard
    /// Highest total/RMR for a day with no detected workout, no sustained session and little locomotion.
    /// Typical sedentary-to-lightly-active adults sit at 1.2–1.5; 1.55 is the generous edge.
    var lightDayMaxPAL: Double = 1.55
    /// A "light" day has fewer than this many moving minutes (cadence/dyn), across the whole day.
    var lightDayMaxMovingMinutes: Int = 90
}

/// What kind of independent evidence defined a bout.
enum BoutKind: String {
    case locomotion
    case session
}

struct BoutRow {
    let kind: BoutKind
    let startTs: Int
    let minutes: Int
    let meanHR: Double
    let maxMinuteHR: Double
    /// Share of the bout's minutes whose heart-rate mean is at or above the legacy day gate.
    let fractionAboveGate: Double
    let meanCadence: Double?
    let meanDyn: Double?
    /// Active (above-rest) energy the previous estimator credited inside the window.
    let legacyActiveKcal: Double
    /// What the 30 %-HRR-gate Keytel model credited above rest in the window (the earlier overcount).
    let ungatedActiveKcal: Double
    let fusionActiveKcal: Double
    let fusionMeanMET: Double
    let fusionMeanConfidence: Double
    let band: ClosedRange<Double>

    /// Every minute of the bout sat below the legacy gate: the old model credited it (almost) nothing.
    var subThreshold: Bool { fractionAboveGate == 0 }
    var fusionKcalPerMin: Double { minutes > 0 ? fusionActiveKcal / Double(minutes) : 0 }
    var inBand: Bool { band.contains(fusionMeanMET) }
}

enum Outcome: String {
    case pass = "PASS"
    case fail = "FAIL"
    /// The days supplied contain nothing this check can judge. Not a failure; not evidence either.
    case notApplicable = "N/A"
}

struct BenchCheck {
    let name: String
    let outcome: Outcome
    let detail: String
}

/// One day, both estimators, and the evidence around them.
struct DayRun {
    let day: String
    let dayStart: Int
    let tzOffsetSeconds: Int
    let partial: Bool
    let elapsedMinutes: Int
    let hrMinutes: Int
    let hasGravity: Bool
    let hasSteps: Bool
    let restingHR: Double?
    let hrmax: Double
    /// The legacy day gate in bpm (`Calories.dayActiveHRRFraction` of heart-rate reserve).
    let gateBpm: Double
    let sleepMinutes: Int
    let workoutsDetected: Int
    let movingMinutes: Int
    let sessionMinutes: Int

    /// `Calories.estimateDayEnergy` on the day's HR: the number the app showed before this change.
    let legacyResting: Double
    let legacyActive: Double
    /// `analyzeDay(energyModel: .legacyHR).daily.activeKcalEst` — must equal `legacyResting + legacyActive`.
    /// (`var` so the check's own tests can feed it a deliberately wrong copy.)
    var legacyReportedTotal: Double?
    /// `Calories.estimateBoutCalories` over the whole day: resting rate below the 30 % gate, gross Keytel
    /// above it. This is the pre-fix day model whose ordinary-daytime overcount motivated the 50 % gate.
    let ungatedTotal: Double

    let fusion: DayEnergy
    var fusionReportedTotal: Double?
    let estimatorMillis: Double

    let bouts: [BoutRow]
    let lightDay: Bool
    /// The harness's own per-minute view (HR mean, step ticks, wrist motion), for `--timeline`.
    let signals: [Bench.MinuteSignal]
    /// The sleep sessions attributed to the day, as local minutes since midnight `(start, end, provided)`.
    /// `provided` = taken from the bundle's scored nights rather than detected from the streams.
    let sleepSpans: [(start: Int, end: Int, provided: Bool)]

    var legacyTotal: Double { legacyResting + legacyActive }
    var fusionPAL: Double { fusion.rmrKcalPerDay > 0 ? fusion.totalKcal / fusion.rmrKcalPerDay : 0 }

    /// Share of the fusion model's active energy earned in minutes whose HR sat below the legacy gate. The
    /// legacy model's value is 0 by construction; the point of removing the gate is that this is not.
    var activeShareBelowGate: Double {
        var below = 0.0, total = 0.0
        for m in fusion.minutes where m.covered && !m.isSleep {
            total += m.activeKcal
            if (m.hr ?? 0) < gateBpm { below += m.activeKcal }
        }
        return total > 0 ? below / total : 0
    }
}
