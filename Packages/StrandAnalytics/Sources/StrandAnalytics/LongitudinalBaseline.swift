import Foundation
import WhoopStore

// LongitudinalBaseline.swift — Phase A in-process baseline API (not Charge).
//
// Spec: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_IMPLEMENTATION.md
// Contract: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_CONDENSED_PLAN.md
//
// Charge stays on Baselines.update / RecoveryScorer. This file never writes DailyMetric.recovery.
// Nothing here runs in strap firmware. Nothing here requires a server.
//
// Phase A: this week (7-day EWMA) + when-well (gapped 60-day median).
// Phase B: treatment events, qualify-before-freeze, Usual before / since. No UI.
//
// HOW TO TEST
//   cd Packages/StrandAnalytics
//   swift test --filter LongitudinalBaselineTests
//   swift test --filter LongitudinalBaselineTrialTests

// MARK: - Series identity (never mix rows across this table)

/// One independent history. Sleep RHR is never mixed with awake-rest HR or awake-active HR;
/// RMSSD is never mixed with SDNN; SpO₂ mean is never mixed with nadir; steps are never mixed
/// with active minutes; continuous means are never the average of the gated copies.
public enum LBSeries: String, Equatable, Sendable, CaseIterable, Codable {
    case sleepRHR = "sleep_rhr"
    case sleepHRVLn = "sleep_hrv_ln"
    case sleepTemp = "sleep_temp"
    case sleepResp = "sleep_resp"
    case sleepSpO2Mean = "sleep_spo2_mean"
    case sleepSpO2Nadir = "sleep_spo2_nadir"
    case awakeRestHR = "awake_rest_hr"
    case awakeRestHRVLn = "awake_rest_hrv_ln"
    case awakeRestSpO2Mean = "awake_rest_spo2_mean"
    case awakeActiveHR = "awake_active_hr"
    case awakeActiveHRVLn = "awake_active_hrv_ln"
    case awakeActiveSpO2Mean = "awake_active_spo2_mean"
    case continuousHR = "continuous_hr"
    case continuousHRVLn = "continuous_hrv_ln"
    case continuousSpO2Mean = "continuous_spo2_mean"
    case wakingSteps = "waking_steps"
    case wakingActiveMin = "waking_active_min"
    /// Daily mean movement energy from strap IMU (1 Hz gravity / dynAccel, or 100 Hz features).
    /// Never mixed with HR, RHR, or step count.
    case wakingImuEnergy = "waking_imu_energy"

    /// LABEL: series context
    /// Five contexts. Still/moving is a minute gate, not a sixth series.
    public var context: LBContext {
        switch self {
        case .sleepRHR, .sleepHRVLn, .sleepTemp, .sleepResp, .sleepSpO2Mean, .sleepSpO2Nadir:
            return .sleep
        case .awakeRestHR, .awakeRestHRVLn, .awakeRestSpO2Mean:
            return .awakeRest
        case .awakeActiveHR, .awakeActiveHRVLn, .awakeActiveSpO2Mean:
            return .awakeActive
        case .continuousHR, .continuousHRVLn, .continuousSpO2Mean:
            return .continuous
        case .wakingSteps, .wakingActiveMin, .wakingImuEnergy:
            return .wakingLoad
        }
    }

    /// LABEL: biometric family
    /// Quiet-column pick stays inside one family. Sleep RHR is never compared to steps.
    public var biometricFamily: String {
        switch self {
        case .sleepRHR, .awakeRestHR, .awakeActiveHR, .continuousHR: return "hr"
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return "hrv"
        case .sleepResp: return "resp"
        case .sleepTemp: return "temp"
        case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean:
            return "spo2"
        case .wakingSteps, .wakingActiveMin: return "motion"
        case .wakingImuEnergy: return "imu"
        }
    }

    /// LABEL: log-domain flag
    /// HRV math is on ln(RMSSD). Every other series stays in native units.
    public var usesLog: Bool {
        switch self {
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return true
        default: return false
        }
    }

    /// LABEL: established-nights family
    /// Activity-mix series need 21 long days; sleep and still-rest need 14.
    public var usesWakingEstablishedN: Bool {
        context == .wakingLoad || context == .awakeActive || context == .continuous
    }

    /// LABEL: DailyMetric wiring
    /// True when a nightly column already exists on git HEAD. Stub series stay fixture-only.
    public var hasDailyMetricColumn: Bool {
        switch self {
        case .sleepRHR, .sleepHRVLn, .sleepTemp, .sleepResp, .sleepSpO2Mean, .wakingSteps:
            return true
        default:
            return false
        }
    }

    /// LABEL: plan table row
    /// Implementation map §8 series list. Charge / still-vs-moving are not rows.
    public var planRow: LBPlanSeries {
        switch self {
        case .sleepRHR:
            return LBPlanSeries(series: self, planName: "Sleep resting heart rate",
                                context: .sleep, dailyMetricColumn: "restingHr",
                                condensedSection: "5.1", unit: "bpm")
        case .sleepHRVLn:
            return LBPlanSeries(series: self, planName: "Sleep HRV ln(RMSSD)",
                                context: .sleep, dailyMetricColumn: "avgHrv",
                                condensedSection: "5.3", unit: "ms")
        case .sleepTemp:
            return LBPlanSeries(series: self, planName: "Sleep wrist temperature",
                                context: .sleep, dailyMetricColumn: "skinTempC",
                                condensedSection: "5.6", unit: "°C")
        case .sleepResp:
            return LBPlanSeries(series: self, planName: "Sleep respiration",
                                context: .sleep, dailyMetricColumn: "respRateBpm",
                                condensedSection: "5.5", unit: "/min")
        case .sleepSpO2Mean:
            return LBPlanSeries(series: self, planName: "Sleep SpO₂ mean",
                                context: .sleep, dailyMetricColumn: "spo2Pct",
                                condensedSection: "5.7", unit: "%")
        case .sleepSpO2Nadir:
            return LBPlanSeries(series: self, planName: "Sleep SpO₂ nadir",
                                context: .sleep, dailyMetricColumn: nil,
                                condensedSection: "5.8", unit: "%")
        case .awakeRestHR:
            return LBPlanSeries(series: self, planName: "Awake-rest heart rate",
                                context: .awakeRest, dailyMetricColumn: nil,
                                condensedSection: "5.2", unit: "bpm")
        case .awakeRestHRVLn:
            return LBPlanSeries(series: self, planName: "Awake-rest HRV ln(RMSSD)",
                                context: .awakeRest, dailyMetricColumn: nil,
                                condensedSection: "5.4", unit: "ms")
        case .awakeRestSpO2Mean:
            return LBPlanSeries(series: self, planName: "Awake-rest SpO₂ mean",
                                context: .awakeRest, dailyMetricColumn: nil,
                                condensedSection: "5.9", unit: "%")
        case .awakeActiveHR:
            return LBPlanSeries(series: self, planName: "Awake-active heart rate",
                                context: .awakeActive, dailyMetricColumn: nil,
                                condensedSection: "5.12", unit: "bpm")
        case .awakeActiveHRVLn:
            return LBPlanSeries(series: self, planName: "Awake-active HRV ln(RMSSD)",
                                context: .awakeActive, dailyMetricColumn: nil,
                                condensedSection: "5.13", unit: "ms")
        case .awakeActiveSpO2Mean:
            return LBPlanSeries(series: self, planName: "Awake-active SpO₂ mean",
                                context: .awakeActive, dailyMetricColumn: nil,
                                condensedSection: "5.14", unit: "%")
        case .continuousHR:
            return LBPlanSeries(series: self, planName: "Continuous heart rate",
                                context: .continuous, dailyMetricColumn: nil,
                                condensedSection: "5.15", unit: "bpm")
        case .continuousHRVLn:
            return LBPlanSeries(series: self, planName: "Continuous HRV ln(RMSSD)",
                                context: .continuous, dailyMetricColumn: nil,
                                condensedSection: "5.16", unit: "ms")
        case .continuousSpO2Mean:
            return LBPlanSeries(series: self, planName: "Continuous SpO₂ mean",
                                context: .continuous, dailyMetricColumn: nil,
                                condensedSection: "5.17", unit: "%")
        case .wakingSteps:
            return LBPlanSeries(series: self, planName: "Daily steps",
                                context: .wakingLoad, dailyMetricColumn: "steps",
                                condensedSection: "5.10", unit: "steps")
        case .wakingActiveMin:
            return LBPlanSeries(series: self, planName: "Daily active minutes",
                                context: .wakingLoad, dailyMetricColumn: nil,
                                condensedSection: "5.11", unit: "min")
        case .wakingImuEnergy:
            return LBPlanSeries(series: self, planName: "Daily movement energy",
                                context: .wakingLoad, dailyMetricColumn: nil,
                                condensedSection: "5.18", unit: "g")
        }
    }
}

/// One row of the implementation-map series table. Still/moving is a gate, not a row.
public struct LBPlanSeries: Equatable, Sendable {
    public let series: LBSeries
    public let planName: String
    public let context: LBContext
    public let dailyMetricColumn: String?
    public let condensedSection: String
    public let unit: String
}

public enum LBContext: String, Equatable, Sendable {
    case sleep
    case awakeRest = "awake_rest"
    case awakeActive = "awake_active"
    case continuous
    case wakingLoad = "waking_load"
}

public enum LBQualityStatus: String, Equatable, Sendable {
    case ok
    case lowQuality = "low_quality"
    case missing
}

public enum LBQualityReason: String, Equatable, Sendable {
    case poorSignal = "poor_signal"
    case lowCoverage = "low_coverage"
    case outOfRange = "out_of_range"
    case sparseSleep = "sparse_sleep"
    case charging
    case deviceOff = "device_off"
    case appFail = "app_fail"
    case hospital
    case unknown
}

// MARK: - Daily observation

/// One civil day for one series. Missing is never stored as zero.
public struct LBDailyObservation: Equatable, Sendable {
    public var day: String
    /// Native units (bpm, ms RMSSD, °C, %, steps, minutes). Nil when missing.
    public var value: Double?
    public var qualityStatus: LBQualityStatus
    public var qualityReason: LBQualityReason?
    /// Still minutes, SpO₂ slot count, or other coverage. Nil when unknown.
    public var coverage: Double?
    /// True when a step/activity stream existed that day (zero steps is then a real 0).
    public var streamPresent: Bool

    public init(day: String, value: Double?, qualityStatus: LBQualityStatus,
                qualityReason: LBQualityReason? = nil, coverage: Double? = nil,
                streamPresent: Bool = true) {
        self.day = day
        self.value = value
        self.qualityStatus = qualityStatus
        self.qualityReason = qualityReason
        self.coverage = coverage
        self.streamPresent = streamPresent
    }
}

// MARK: - Carry (online hold + CUSUM)

/// State that yesterday's evaluate hands to today: last published centers and the CUSUM.
public struct LBCarry: Equatable, Sendable {
    public var center7: Double?
    public var spread7: Double?
    public var centerLong: Double?
    public var spreadLong: Double?
    public var nLong: Int
    public var establishedLong: Bool
    public var cusumS: Double
    /// z_long on the most recent quality-OK scored day (for `worse`).
    public var zLongPrev: Double?
    /// Consecutive |z_long| ≥ k_band quality-OK days as of the last scored T.
    public var runLength: Int
    /// Last up-to-3 quality-OK z_long values, oldest first (for hits_3).
    public var recentZLong: [Double]
    public var lastQualityOKEpoch: Int?
    public var slopeLong: Double?
    public var slopeUsable: Bool
    public var longOriginEpoch: Int?
    /// Logged felt-ill snapshot for Watchdog personal-off. Not a treatment freeze.
    public var usualFreeze: LBUsualFreeze? = nil
    public var usualEpochStart: Int? = nil
    public var weekOffStreak: Int = 0

    public init(center7: Double? = nil, spread7: Double? = nil,
                centerLong: Double? = nil, spreadLong: Double? = nil,
                nLong: Int = 0, establishedLong: Bool = false,
                cusumS: Double = 0, zLongPrev: Double? = nil,
                runLength: Int = 0, recentZLong: [Double] = [],
                lastQualityOKEpoch: Int? = nil,
                slopeLong: Double? = nil, slopeUsable: Bool = false,
                longOriginEpoch: Int? = nil,
                usualFreeze: LBUsualFreeze? = nil,
                usualEpochStart: Int? = nil,
                weekOffStreak: Int = 0) {
        self.center7 = center7
        self.spread7 = spread7
        self.centerLong = centerLong
        self.spreadLong = spreadLong
        self.nLong = nLong
        self.establishedLong = establishedLong
        self.cusumS = cusumS
        self.zLongPrev = zLongPrev
        self.runLength = runLength
        self.recentZLong = recentZLong
        self.lastQualityOKEpoch = lastQualityOKEpoch
        self.slopeLong = slopeLong
        self.slopeUsable = slopeUsable
        self.longOriginEpoch = longOriginEpoch
        self.usualFreeze = usualFreeze
        self.usualEpochStart = usualEpochStart
        self.weekOffStreak = weekOffStreak
    }

    public static let empty = LBCarry()
}

/// Frozen when-well copy after a **logged** felt-ill onset. Snapshot only — Layer 1
/// centers still skip-and-hold. Does not name a drug or infer a treatment start.
public struct LBUsualFreeze: Equatable, Sendable {
    public var t0CivilDay: String
    public var tFreeze: String
    public var reason: String
    public var version: Int
    public var centerLong: Double
    public var spreadLong: Double
    public var center7: Double
    public var spread7: Double

    public static let loggedIll = "logged_ill"
    public static let weekOffLong = "week_off_long"

    public init(t0CivilDay: String, tFreeze: String, reason: String, version: Int,
                centerLong: Double, spreadLong: Double, center7: Double, spread7: Double) {
        self.t0CivilDay = t0CivilDay
        self.tFreeze = tFreeze
        self.reason = reason
        self.version = version
        self.centerLong = centerLong
        self.spreadLong = spreadLong
        self.center7 = center7
        self.spread7 = spread7
    }
}

// MARK: - Snapshots

/// One copy (this week or when-well). Centers are in math space (ln for HRV).
public struct LBCopySnapshot: Equatable, Sendable {
    public var center: Double
    public var spread: Double
    public var centerDisplay: Double
    public var bandLoDisplay: Double
    public var bandHiDisplay: Double
    public var deltaDisplay: Double?
    public var z: Double?
    public var n: Int
    public var coverage: Double
    public var lastUpdate: String?
    public var version: String
    public var held: Bool

    public init(center: Double, spread: Double, centerDisplay: Double,
                bandLoDisplay: Double, bandHiDisplay: Double,
                deltaDisplay: Double? = nil, z: Double? = nil, n: Int,
                coverage: Double, lastUpdate: String? = nil, version: String, held: Bool) {
        self.center = center
        self.spread = spread
        self.centerDisplay = centerDisplay
        self.bandLoDisplay = bandLoDisplay
        self.bandHiDisplay = bandHiDisplay
        self.deltaDisplay = deltaDisplay
        self.z = z
        self.n = n
        self.coverage = coverage
        self.lastUpdate = lastUpdate
        self.version = version
        self.held = held
    }
}

public struct LBEvaluation: Equatable, Sendable {
    public var asOf: String
    public var series: LBSeries
    public var todayNative: Double?
    public var copy7: LBCopySnapshot?
    public var copyLong: LBCopySnapshot?
    public var center7Raw: Double?
    public var center7RawDisplay: Double?
    public var n7: Int
    public var nLearn: Double
    public var nLong: Int
    /// Student-t λ for [T−7 … T−1], oldest first. 0 when the slot did not train.
    public var lambdas: [Double]
    public var gap: Double?
    public var gapZ: Double?
    public var z7: Double?
    public var zLong: Double?
    public var show7: Bool
    public var showLong: Bool
    public var establishedLong: Bool
    public var confSpread: Bool
    public var alertEligible: Bool
    public var stale: Bool
    public var confidencePct7: Int
    public var confidencePctLong: Int
    /// Dashboard TRUST (item 4). Not Charge. Not “they are abnormal.”
    public var usualTrustPct7: Int = 0
    public var usualTrustPctLong: Int = 0
    public var howUnusualPct7: Int? = nil
    public var howUnusualPctLong: Int? = nil
    public var slopeLong: Double? = nil
    public var slopeUsable: Bool = false
    public var expectedLong: Double? = nil
    public var nEff7: Double = 0
    public var nEffLong: Double = 0
    /// Table prior vs live k from the stable-window residual 95th percentile.
    public var kBandTable: Double = 2
    public var kBandUsed: Double = 2
    public var stableWindow: LBStableWindow = .overnightSleep
    public var habitClass: LBHabitClass = .unspecified
    public var habitMatched: Bool = false
    /// Clean (unconfounded) nights that built the longer usual. Equal to nLong after the clean filter.
    public var nCleanLong: Int = 0
    public var pChange: Double
    public var cusumS: Double
    public var regimeShift: Bool
    /// Condensed §1.6 diagnostic: last-14 vs earlier median on the long list. Not the regime decision.
    public var twoBlockShift: Double?
    /// |S1| / |S| after k_learn trim. p_regime is the cutoff; this is how much was dropped.
    public var trimKeptFrac: Double?
    public var runLength: Int
    public var worse: Bool?
    public var hits3: Int
    public var twoOfThree: Bool
    public var paramSet: String
    public var carry: LBCarry
    /// Phase B trial overlay. `.none` when no treatment is marked (Phase A path).
    public var trial: LBTrialEvaluation = .none
    /// Optional “what else is going on?” for Phase C. Never a daily chore; never required to score.
    public var contextPrompt: LBOutOfBoundsPrompt = .silent
    /// Pre-illness snapshot after a logged felt-ill. Nil unless they logged it.
    public var usualFreeze: LBUsualFreeze? = nil

    /// LABEL: human-readable math dump
    /// One block you can print after a test failure to see both copies, gap, CUSUM, and confidence.
    public var consoleReport: String {
        var lines: [String] = []
        lines.append("LongitudinalBaseline  asOf=\(asOf)  series=\(series.rawValue)  param=\(paramSet)")
        if let t = todayNative {
            lines.append(String(format: "  today = %.4f", t))
        } else {
            lines.append("  today = missing")
        }
        if let c = copy7 {
            lines.append(String(format: "  this week  center=%.4f  spread=%.4f  n7=%d  n_learn=%.3f  z=%@",
                                c.center, c.spread, n7, nLearn, z7.map { String(format: "%.3f", $0) } ?? "—"))
            lines.append(String(format: "             display=%.4f  band=[%.4f, %.4f]  held=%@",
                                c.centerDisplay, c.bandLoDisplay, c.bandHiDisplay, c.held ? "yes" : "no"))
        } else {
            lines.append("  this week  (not shown; n7=\(n7) need \(LongitudinalBaseline.Params.n7Show))")
        }
        if let raw = center7Raw {
            lines.append(String(format: "  center_7_raw = %.4f", raw))
        }
        if let c = copyLong {
            lines.append(String(format: "  when-well  center=%.4f  spread=%.4f  n_long=%d  z=%@  held=%@",
                                c.center, c.spread, nLong,
                                zLong.map { String(format: "%.3f", $0) } ?? "—",
                                c.held ? "yes" : "no"))
        } else {
            lines.append("  when-well  (not shown; n_long=\(nLong))")
        }
        lines.append(String(format: "  gap=%@  gap_z=%@  p_change=%.3f  S=%.2f  regime=%@  two_block=%@  trim_kept=%@",
                            gap.map { String(format: "%.4f", $0) } ?? "—",
                            gapZ.map { String(format: "%.3f", $0) } ?? "—",
                            pChange, cusumS, regimeShift ? "1" : "0",
                            twoBlockShift.map { String(format: "%.3f", $0) } ?? "—",
                            trimKeptFrac.map { String(format: "%.2f", $0) } ?? "—"))
        lines.append("  conf_7=\(confidencePct7)%  conf_long=\(confidencePctLong)%  trust_7=\(usualTrustPct7)%  trust_long=\(usualTrustPctLong)%  how_off_7=\(howUnusualPct7.map(String.init) ?? "—")  how_off_long=\(howUnusualPctLong.map(String.init) ?? "—")")
        lines.append(String(format: "  k_table=%.2f  k_used=%.2f  window=%@  habit=%@ matched=%@  n_clean=%d",
                            kBandTable, kBandUsed, stableWindow.rawValue, habitClass.rawValue,
                            habitMatched ? "yes" : "no", nCleanLong))
        lines.append("  slope=\(slopeLong.map { String(format: "%.4f", $0) } ?? "—") usable=\(slopeUsable ? "1" : "0")  expected_long=\(expectedLong.map { String(format: "%.4f", $0) } ?? "—")  stale=\(stale)  alert_eligible=\(alertEligible)")
        lines.append("  persist run=\(runLength) hits3=\(hits3) two_of_three=\(twoOfThree) worse=\(worse.map { $0 ? "1" : "0" } ?? "—")")
        if contextPrompt.shouldAsk {
            lines.append("  context_prompt  \(contextPrompt.headline)")
        }
        if trial.phase != .none {
            lines.append(trial.consoleBlock)
        }
        return lines.joined(separator: "\n")
    }

    /// LABEL: Phase A statistic ledger
    /// Every condensed-plan §2 field this pass stores (trial freeze is Phase B and is omitted).
    public var phaseAStatisticLedger: [(planName: String, value: String)] {
        func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "—" }
        return [
            ("today", n(todayNative)),
            ("center_7", n(copy7?.center)),
            ("center_7_display", n(copy7?.centerDisplay)),
            ("spread_7", n(copy7?.spread)),
            ("band_7_lo", n(copy7?.bandLoDisplay)),
            ("band_7_hi", n(copy7?.bandHiDisplay)),
            ("delta_7", n(copy7?.deltaDisplay)),
            ("z_7", n(z7)),
            ("center_7_raw", n(center7Raw)),
            ("n_7", "\(n7)"),
            ("n_learn", String(format: "%.4f", nLearn)),
            ("coverage_7", n(copy7?.coverage)),
            ("last_update_7", copy7?.lastUpdate ?? "—"),
            ("version_7", copy7?.version ?? "—"),
            ("center_long", n(copyLong?.center)),
            ("spread_long", n(copyLong?.spread)),
            ("band_long_lo", n(copyLong?.bandLoDisplay)),
            ("band_long_hi", n(copyLong?.bandHiDisplay)),
            ("delta_long", n(copyLong?.deltaDisplay)),
            ("z_long", n(zLong)),
            ("n_long", "\(nLong)"),
            ("coverage_long", n(copyLong?.coverage)),
            ("last_update_long", copyLong?.lastUpdate ?? "—"),
            ("version_long", copyLong?.version ?? "—"),
            ("gap", n(gap)),
            ("gap_z", n(gapZ)),
            ("show_7", show7 ? "1" : "0"),
            ("show_long", showLong ? "1" : "0"),
            ("established_long", establishedLong ? "1" : "0"),
            ("conf_spread", confSpread ? "1" : "0"),
            ("alert_eligible", alertEligible ? "1" : "0"),
            ("stale", stale ? "1" : "0"),
            ("confidence_pct_7", "\(confidencePct7)"),
            ("confidence_pct_long", "\(confidencePctLong)"),
            ("usual_trust_pct_7", "\(usualTrustPct7)"),
            ("usual_trust_pct_long", "\(usualTrustPctLong)"),
            ("how_unusual_pct_7", howUnusualPct7.map(String.init) ?? "—"),
            ("how_unusual_pct_long", howUnusualPctLong.map(String.init) ?? "—"),
            ("slope_long", n(slopeLong)),
            ("slope_usable", slopeUsable ? "1" : "0"),
            ("expected_long", n(expectedLong)),
            ("p_change", n(pChange)),
            ("cusum_s", n(cusumS)),
            ("regime_shift", regimeShift ? "1" : "0"),
            ("two_block_shift", n(twoBlockShift)),
            ("trim_kept_frac", n(trimKeptFrac)),
            ("run_length", "\(runLength)"),
            ("hits_3", "\(hits3)"),
            ("two_of_three", twoOfThree ? "1" : "0"),
            ("worse", worse.map { $0 ? "1" : "0" } ?? "—"),
            ("param_set", paramSet),
            ("layer", "1"),
        ]
    }
}

// MARK: - Engine

public enum LongitudinalBaseline {

    /// v1 constants from condensed plan §1.7. Changing one writes a new param_set; it does not edit old snapshots.
    public enum Params {
        public static let paramSet = "v1.review"
        public static let version7 = "ewma-span7-mad-k2-7-t4"
        public static let versionLong = "gap7-med-mad-k2-60-cp1"
        public static let span7 = 7
        public static let alpha = 2.0 / (Double(span7) + 1.0)   // 0.25
        public static let lookbackLong = 60
        public static let gapDays = 7
        public static let longSlots = lookbackLong - gapDays     // 53
        public static let kBand = 2.0
        public static let kLearn = 2.0
        public static let nu = 4.0
        public static let kCusum = 0.5
        public static let hCusum = 20.0
        public static let pThr = 0.90
        public static let n7Show = 4
        public static let nLongShow = 4
        public static let nLongEstablished = 14
        public static let nLongWaking = 21
        public static let nBorrow = 7.0
        public static let pRegime = 0.35
        public static let staleDays = 14
        public static let madScale = 1.4826
        public static let spo2MinSlots = 8.0
        public static let awakeRestMinStill = 30.0
        /// Waking minutes that are moving (not still) before awake-active HR/HRV may train.
        public static let awakeActiveMinMoving = 30.0
        /// Valid minutes (sleep or wake, still or moving) before a continuous HR/HRV day may train.
        public static let continuousMinMinutes = 240.0
        /// Minutes of strap IMU before the movement-energy usual may train that day.
        public static let imuMinMinutes = 60.0
        /// Stored on the snapshot; trial clocks are Phase B and do not change Phase A math.
        public static let persistWindow = 3
        public static let persistHits = 2
        public static let washInDays = 7
        public static let washoutDays = 7
    }

    /// LABEL: v1 parameter ledger
    /// Every condensed-plan §1.7 constant, named. Tests pin these literals so a silent drift fails.
    public static var v1ParameterLedger: [(planName: String, value: String)] {
        [
            ("param_set", Params.paramSet),
            ("version_7", Params.version7),
            ("version_long", Params.versionLong),
            ("span_7", "\(Params.span7)"),
            ("alpha", String(Params.alpha)),
            ("lookback_long", "\(Params.lookbackLong)"),
            ("gap_days", "\(Params.gapDays)"),
            ("long_slots", "\(Params.longSlots)"),
            ("k_band", String(Params.kBand)),
            ("k_learn", String(Params.kLearn)),
            ("nu", String(Params.nu)),
            ("k_cusum", String(Params.kCusum)),
            ("h_cusum", String(Params.hCusum)),
            ("p_thr", String(Params.pThr)),
            ("n_7_show", "\(Params.n7Show)"),
            ("n_long_show", "\(Params.nLongShow)"),
            ("n_long_established", "\(Params.nLongEstablished)"),
            ("n_long_waking", "\(Params.nLongWaking)"),
            ("awake_rest_min_still", String(Params.awakeRestMinStill)),
            ("awake_active_min_moving", String(Params.awakeActiveMinMoving)),
            ("continuous_min_minutes", String(Params.continuousMinMinutes)),
            ("spo2_min_slots", String(Params.spo2MinSlots)),
            ("n_borrow", String(Params.nBorrow)),
            ("p_regime", String(Params.pRegime)),
            ("stale_days", "\(Params.staleDays)"),
            ("mad_scale", String(Params.madScale)),
            ("persist_window", "\(Params.persistWindow)"),
            ("persist_hits", "\(Params.persistHits)"),
            ("wash_in_days", "\(Params.washInDays)"),
            ("washout_days", "\(Params.washoutDays)"),
        ]
    }

    /// LABEL: series + floor catalog
    /// Human-readable table of every biometric in the plan. Charge is not a row.
    public static func planCatalogText() -> String {
        func pad(_ s: String, _ n: Int) -> String {
            if s.count >= n { return String(s.prefix(n)) }
            return s + String(repeating: " ", count: n - s.count)
        }
        var lines = [pad("fixture_id", 26) + pad("§", 6) + pad("context", 15)
                     + pad("DailyMetric", 16) + pad("floor", 8) + "unit"]
        for s in LBSeries.allCases {
            let row = s.planRow
            let spec = seriesSpec(s)
            lines.append(pad(s.rawValue, 26)
                         + pad(row.condensedSection, 6)
                         + pad(row.context.rawValue, 15)
                         + pad(row.dailyMetricColumn ?? "(none)", 16)
                         + pad(String(spec.floor), 8)
                         + row.unit)
        }
        return lines.joined(separator: "\n")
    }

    public enum MethodPhase: String, Equatable, Sendable {
        case phaseA = "phase_a"
        case diagnostic = "diagnostic"
        case phaseB = "phase_b"
        case later = "later_engine"
        case notThisEngine = "not_this_engine"
    }

    public struct StatisticalMethod: Equatable, Sendable {
        public let id: String
        public let planSection: String
        public let phase: MethodPhase
        public let symbol: String
    }

    /// LABEL: statistical-method registry
    /// Condensed-plan estimators. Phase A tests must witness every `.phaseA` and `.diagnostic` row.
    public static let statisticalMethods: [StatisticalMethod] = [
        StatisticalMethod(id: "as_of_windows", planSection: "1.0", phase: .phaseA,
                          symbol: "scoreOneDay / [T−7,T−1] / [T−60,T−8]"),
        StatisticalMethod(id: "finite_ewma", planSection: "1.1", phase: .phaseA,
                          symbol: "rawEwmaWeight / ewmaCenter"),
        StatisticalMethod(id: "ewma_renormalize", planSection: "1.1", phase: .phaseA,
                          symbol: "ewmaCenter"),
        StatisticalMethod(id: "gapped_long_median", planSection: "1.2", phase: .phaseA,
                          symbol: "median on [T−60,T−8]"),
        StatisticalMethod(id: "inclusive_53", planSection: "1.2", phase: .phaseA,
                          symbol: "longWindowLength"),
        StatisticalMethod(id: "night_lifecycle", planSection: "1.3", phase: .phaseA,
                          symbol: "T in neither window"),
        StatisticalMethod(id: "student_t_lambda", planSection: "1.4", phase: .phaseA,
                          symbol: "studentTLambda"),
        StatisticalMethod(id: "huber_lambda", planSection: "1.4", phase: .phaseA,
                          symbol: "huberLambda (not v1 default)"),
        StatisticalMethod(id: "hold_n_learn", planSection: "1.4", phase: .phaseA,
                          symbol: "center_7 hold if n_learn < 4"),
        StatisticalMethod(id: "center_7_raw_gap", planSection: "1.4", phase: .phaseA,
                          symbol: "center7Raw / gap / gapZ"),
        StatisticalMethod(id: "borrowed_spread", planSection: "1.5", phase: .phaseA,
                          symbol: "borrowedSpread"),
        StatisticalMethod(id: "mad_14826", planSection: "1.2/2", phase: .phaseA,
                          symbol: "robustSpread"),
        StatisticalMethod(id: "mad_around_ewma", planSection: "1.1", phase: .phaseA,
                          symbol: "MAD vs center_7 not vs median"),
        StatisticalMethod(id: "spread_floor", planSection: "2", phase: .phaseA,
                          symbol: "seriesSpec.floor"),
        StatisticalMethod(id: "trim_k_learn", planSection: "1.2/1.6", phase: .phaseA,
                          symbol: "trimLongList"),
        StatisticalMethod(id: "cusum_p_change", planSection: "1.6", phase: .phaseA,
                          symbol: "cusumStep / changeProbability"),
        StatisticalMethod(id: "cusum_missing_hold", planSection: "1.6", phase: .phaseA,
                          symbol: "missing days skip S, do not reset"),
        StatisticalMethod(id: "two_block_median", planSection: "1.6", phase: .diagnostic,
                          symbol: "twoBlockMedianShift"),
        StatisticalMethod(id: "trim_kept_frac", planSection: "1.6", phase: .diagnostic,
                          symbol: "trimKeptFrac vs p_regime"),
        StatisticalMethod(id: "confidence_pct", planSection: "1.7", phase: .phaseA,
                          symbol: "confidencePct7 / confidencePctLong"),
        StatisticalMethod(id: "persistence", planSection: "1.7", phase: .phaseA,
                          symbol: "runLength / hits3 / twoOfThree / worse"),
        StatisticalMethod(id: "z_and_band", planSection: "2", phase: .phaseA,
                          symbol: "z = (today-center)/spread ; ± k_band"),
        StatisticalMethod(id: "ln_rmssd", planSection: "2/3", phase: .phaseA,
                          symbol: "toMath / toDisplay"),
        StatisticalMethod(id: "missing_not_zero", planSection: "2/3", phase: .phaseA,
                          symbol: "trainableNative"),
        StatisticalMethod(id: "quality_reasons", planSection: "1.7", phase: .phaseA,
                          symbol: "LBQualityStatus / LBQualityReason"),
        StatisticalMethod(id: "layer1_no_blend", planSection: "1.7", phase: .phaseA,
                          symbol: "one series per evaluate"),
        StatisticalMethod(id: "charge_isolated", planSection: "0", phase: .notThisEngine,
                          symbol: "Baselines.update / RecoveryScorer"),
        StatisticalMethod(id: "no_weekday_split", planSection: "within-day", phase: .phaseA,
                          symbol: "civil days only"),
        StatisticalMethod(id: "still_moving_gate", planSection: "within-day", phase: .phaseA,
                          symbol: "minute gate → awake_rest vs awake_active"),
        StatisticalMethod(id: "context_continuous", planSection: "within-day", phase: .phaseA,
                          symbol: "all valid samples that civil day"),
        StatisticalMethod(id: "never_average_contexts", planSection: "3", phase: .phaseA,
                          symbol: "five contexts; copies never averaged"),
        StatisticalMethod(id: "trial_freeze", planSection: "1.8", phase: .phaseB,
                          symbol: "Usual before / since treatment"),
        StatisticalMethod(id: "theil_sen_slope", planSection: "1.8", phase: .phaseB,
                          symbol: "slope_long"),
        StatisticalMethod(id: "sigma_meas_mdc", planSection: "1.8", phase: .phaseB,
                          symbol: "σ_meas / MDC_95"),
        StatisticalMethod(id: "sigma_bio", planSection: "1.8", phase: .phaseB,
                          symbol: "σ_bio² = max(spread_long² − σ_meas², 0)"),
        StatisticalMethod(id: "lag1_r1", planSection: "1.8", phase: .phaseB,
                          symbol: "r1 / n_eff (freeze window)"),
        StatisticalMethod(id: "r1_live", planSection: "1.8", phase: .phaseB,
                          symbol: "r1 on each trial day; freeze r1 unchanged"),
        StatisticalMethod(id: "frozen_center_7_deltas", planSection: "1.8", phase: .phaseB,
                          symbol: "today vs center_7_frozen (not primary)"),
        StatisticalMethod(id: "missingness_counts", planSection: "1.8", phase: .phaseB,
                          symbol: "Why missing histogram on the trial log"),
        StatisticalMethod(id: "state_space", planSection: "1.9", phase: .later,
                          symbol: "robust state-space successor"),
        StatisticalMethod(id: "bounded_long_ewma", planSection: "1.2", phase: .later,
                          symbol: "not the returned longer center"),
        StatisticalMethod(id: "layer2_combo", planSection: "1.7", phase: .later,
                          symbol: "multi-series watchdog"),
    ]

    /// LABEL: EWMA half-life
    /// (1−α)^h = 1/2 ⇒ h = ln(2) / ln(4/3) ≈ 2.41 days for span-7 α = 0.25.
    public static func ewmaHalfLifeDays() -> Double {
        log(2.0) / log(1.0 / (1.0 - Params.alpha))
    }

    // MARK: - Public API (implementation map §3)

    /// LABEL: observations from DailyMetric
    /// Pulls one series out of nightly rows. Stub series return []. Missing stays missing.
    /// Zero steps with a present stream is a real 0. Charge / recovery is never read.
    public static func observations(from days: [DailyMetric], series: LBSeries) -> [LBDailyObservation] {
        guard series.hasDailyMetricColumn else { return [] }
        return days.map { day in
            let extracted = nativeValue(from: day, series: series)
            return observation(day: day.day, native: extracted.value,
                               streamPresent: extracted.streamPresent,
                               sleepHrOnly: day.sleepHrOnly == true,
                               series: series)
        }
    }

    /// LABEL: score civil day T
    /// Builds when-well first, then this week. Default `replay` walks the tape so CUSUM and hold
    /// are online. `T` is compared to both copies and is not folded into either.
    /// `trial: .none` is Phase A. A start event qualifies, freezes Usual before, and (only if
    /// freeze OK) opens a new long epoch so on-treatment nights do not mix into the control.
    public static func evaluate(asOf t: String,
                                series: LBSeries,
                                observations: [LBDailyObservation],
                                carry: LBCarry = .empty,
                                replay: Bool = true,
                                trial: LBTrialRequest = .none) -> LBEvaluation {
        let byDay = indexByDay(observations, series: series)
        guard let tEpoch = isoEpochDay(t) else {
            return emptyEvaluation(asOf: t, series: series, carry: carry)
        }

        var request = trial
        var reasons: [String] = []
        let clock = trialClock(events: trial.events, asOf: t)
        if request.freeze == nil, let start = clock.start, t >= start.civilDay,
           let freezeDay = freezeAsOfDay(t0CivilDay: start.civilDay) {
            let pre = evaluate(asOf: freezeDay, series: series, observations: observations,
                               replay: true, trial: .none)
            reasons = qualifyReasons(pre: pre, observations: observations)
            if reasons.isEmpty {
                request.freeze = makeFreezeBundle(pre: pre, start: start, observations: observations,
                                                  provenance: trial.provenanceNow)
            }
        }
        let trialEpoch: Int? = request.freeze.flatMap { isoEpochDay($0.t0CivilDay) }
        var illnessFreeze: LBUsualFreeze? = nil
        if trialEpoch == nil,
           let onset = firstFeltIllOnset(dayLogs: request.dayLogsByDay, through: t),
           let freezeDay = freezeAsOfDay(t0CivilDay: onset), freezeDay < t {
            let preReq = LBTrialRequest(dayLogsByDay: request.dayLogsByDay)
            let pre = evaluate(asOf: freezeDay, series: series, observations: observations,
                               replay: true, trial: preReq)
            if qualifyReasons(pre: pre, observations: observations).isEmpty,
               let bundle = makeUsualFreeze(pre: pre, t0CivilDay: onset, reason: LBUsualFreeze.loggedIll) {
                illnessFreeze = bundle
            }
        }
        let scored: LBEvaluation
        if replay {
            let epochs = byDay.keys.sorted()
            let startDay = epochs.first ?? tEpoch
            var state = carry
            if let bundle = illnessFreeze {
                state.usualFreeze = bundle
            }
            var last = emptyEvaluation(asOf: t, series: series, carry: carry)
            var d = startDay
            var resetEpoch = false
            while d <= tEpoch {
                if let es = trialEpoch, d >= es, !resetEpoch {
                    state.centerLong = nil
                    state.spreadLong = nil
                    state.nLong = 0
                    state.establishedLong = false
                    state.cusumS = 0
                    resetEpoch = true
                }
                let es = trialEpoch.flatMap { d >= $0 ? trialEpoch : nil }
                last = scoreOneDay(tEpoch: d, series: series, byDay: byDay, carry: state,
                                   epochStart: es, dayLogs: request.dayLogsByDay)
                var next = last.carry
                next.usualFreeze = state.usualFreeze
                last.carry = next
                last.usualFreeze = next.usualFreeze
                state = next
                d += 1
            }
            scored = last
        } else {
            var state = carry
            if let bundle = illnessFreeze {
                state.usualFreeze = bundle
            }
            let es = trialEpoch.flatMap { tEpoch >= $0 ? trialEpoch : nil }
            var one = scoreOneDay(tEpoch: tEpoch, series: series, byDay: byDay, carry: state,
                                  epochStart: es, dayLogs: request.dayLogsByDay)
            one.carry.usualFreeze = state.usualFreeze
            one.usualFreeze = state.usualFreeze
            scored = one
        }
        var out = scored
        out.usualFreeze = scored.carry.usualFreeze ?? illnessFreeze
        out.trial = attachTrial(to: scored, request: request, observations: observations,
                                qualifyReasons: reasons)
        if out.trial.phase != .none, !out.trial.trialFreezeOk {
            out.usualTrustPctLong = clipPct(Double(out.usualTrustPctLong) * 0.4)
        }
        if !request.acuteFlags(on: t).isEmpty {
            out.usualTrustPct7 = clipPct(Double(out.usualTrustPct7) * 0.5)
            out.usualTrustPctLong = clipPct(Double(out.usualTrustPctLong) * 0.5)
        }
        out.contextPrompt = outOfBoundsPrompt(for: out)
        return out
    }

    /// LABEL: shadow metricSeries points
    /// Writes lb_v1_{series}_{field} for wired series only. Never writes "recovery".
    public static func shadowPoints(asOf t: String, days: [DailyMetric]) -> [MetricPoint] {
        var points: [MetricPoint] = []
        for series in LBSeries.allCases where series.hasDailyMetricColumn {
            let obs = observations(from: days, series: series)
            let ev = evaluate(asOf: t, series: series, observations: obs)
            points.append(contentsOf: shadowPoints(from: ev))
        }
        return points
    }

    /// LABEL: shadow points from one evaluation
    /// Same keys IntelligenceEngine will persist later. Finite values only.
    public static func shadowPoints(from ev: LBEvaluation) -> [MetricPoint] {
        let prefix = "lb_v1_\(ev.series.rawValue)_"
        var out: [MetricPoint] = []
        func add(_ field: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            out.append(MetricPoint(day: ev.asOf, key: prefix + field, value: value))
        }
        add("n_7", Double(ev.n7))
        add("n_learn", ev.nLearn)
        add("n_long", Double(ev.nLong))
        add("usual_trust_pct_7", Double(ev.usualTrustPct7))
        add("usual_trust_pct_long", Double(ev.usualTrustPctLong))
        add("how_unusual_pct_7", ev.howUnusualPct7.map(Double.init))
        add("how_unusual_pct_long", ev.howUnusualPctLong.map(Double.init))
        add("slope_long_live", ev.slopeLong)
        add("slope_usable", ev.slopeUsable ? 1 : 0)
        add("p_change", ev.pChange)
        add("cusum_s", ev.cusumS)
        add("regime_shift", ev.regimeShift ? 1 : 0)
        add("show_7", ev.show7 ? 1 : 0)
        add("show_long", ev.showLong ? 1 : 0)
        add("established_long", ev.establishedLong ? 1 : 0)
        add("alert_eligible", ev.alertEligible ? 1 : 0)
        add("stale", ev.stale ? 1 : 0)
        add("run_length", Double(ev.runLength))
        add("hits_3", Double(ev.hits3))
        add("two_of_three", ev.twoOfThree ? 1 : 0)
        if let w = ev.worse { add("worse", w ? 1 : 0) }
        add("center_7", ev.copy7?.center)
        add("spread_7", ev.copy7?.spread)
        add("center_7_raw", ev.center7Raw)
        add("center_long", ev.copyLong?.center)
        add("spread_long", ev.copyLong?.spread)
        add("gap", ev.gap)
        add("gap_z", ev.gapZ)
        add("z_7", ev.z7)
        add("z_long", ev.zLong)
        add("today", ev.todayNative)
        add("k_band_used", ev.kBandUsed)
        add("habit_matched", ev.habitMatched ? 1 : 0)
        if ev.trial.trialFreezeOk {
            add("trial_freeze_ok", 1)
            add("center_long_frozen", ev.trial.freeze?.centerLong)
            add("slope_long", ev.trial.freeze?.slopeLong)
            add("z_trial_traj", ev.trial.zTrialTraj)
            add("z_trial_level", ev.trial.zTrialLevel)
            add("mdc_95", ev.trial.mdc95)
            add("above_mdc", ev.trial.aboveMdc.map { $0 ? 1 : 0 })
            add("r1", ev.trial.r1)
            add("sigma_bio", ev.trial.freeze?.sigmaBio)
            add("r1_live", ev.trial.r1Live)
            add("z_trial_level_7", ev.trial.zTrialLevel7)
            add("delta_trial_level_7", ev.trial.deltaTrialLevel7)
            add("missing_none", Double(ev.trial.missingness.none))
            add("missing_hospital", Double(ev.trial.missingness.hospital))
            add("provenance_break", ev.trial.provenanceBreak ? 1 : 0)
        }
        return out
    }

    /// LABEL: parse a fixture CSV
    /// Columns: day,value,quality_status,quality_reason,coverage
    public static func observations(fromCSV csv: String) -> [LBDailyObservation] {
        var rows: [LBDailyObservation] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if i == 0 && line.lowercased().hasPrefix("day,") { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard cols.count >= 3 else { continue }
            let day = cols[0]
            let value: Double? = cols[1].isEmpty ? nil : Double(cols[1])
            let status = LBQualityStatus(rawValue: cols[2]) ?? .missing
            let reason: LBQualityReason? = {
                guard cols.count > 3, !cols[3].isEmpty else { return nil }
                return LBQualityReason(rawValue: cols[3])
            }()
            let coverage: Double? = {
                guard cols.count > 4, !cols[4].isEmpty else { return nil }
                return Double(cols[4])
            }()
            rows.append(LBDailyObservation(day: day, value: value, qualityStatus: status,
                                           qualityReason: reason, coverage: coverage,
                                           streamPresent: status != .missing || value != nil))
        }
        return rows
    }

    // MARK: - Series gates

    /// LABEL: native range + floor
    /// Physiological min/max and MAD floor for this series (condensed §2).
    public static func seriesSpec(_ series: LBSeries) -> (minVal: Double, maxVal: Double, floor: Double) {
        switch series {
        case .sleepRHR: return (30, 120, 2)
        case .awakeRestHR: return (35, 160, 3)
        case .awakeActiveHR: return (40, 200, 4)
        case .continuousHR: return (35, 190, 5)
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn:
            return (5, 250, 0.08)   // native ms range; floor is on ln
        case .sleepResp: return (4, 40, 0.5)
        case .sleepTemp: return (20, 42, 0.3)
        case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean,
             .awakeActiveSpO2Mean, .continuousSpO2Mean:
            return (70, 100, 0.5)
        case .wakingSteps: return (0, 200_000, 500)
        case .wakingActiveMin: return (0, 1_440, 10)
        case .wakingImuEnergy: return (0, 8, 0.02)
        }
    }

    /// LABEL: established-nights gate
    /// Rest series need 14 long nights; waking_load needs 21.
    public static func nLongEstablished(for series: LBSeries) -> Int {
        params(for: series).nLongEstablished
    }

    /// LABEL: native → math space
    /// ln(RMSSD) for HRV; identity otherwise. Non-positive HRV is not a number.
    public static func toMath(_ native: Double, series: LBSeries) -> Double? {
        guard native.isFinite else { return nil }
        if series.usesLog {
            guard native > 0 else { return nil }
            return log(native)
        }
        return native
    }

    /// LABEL: math → display space
    /// exp for HRV so the band is in milliseconds; identity otherwise.
    public static func toDisplay(_ math: Double, series: LBSeries) -> Double {
        series.usesLog ? exp(math) : math
    }

    // MARK: - Calendar (inclusive windows; 60-day lookback is 53 long slots)

    /// LABEL: ISO day → epoch day
    /// Same Hinnant civil-from-epoch as Baselines.isoEpochDay so Swift/Kotlin day math matches.
    public static func isoEpochDay(_ iso: String) -> Int? {
        Baselines.isoEpochDay(iso)
    }

    /// LABEL: epoch day → ISO
    /// Inverse of isoEpochDay. Used to name T−60 … T without DateFormatter / time zones.
    public static func isoFromEpochDay(_ z: Int) -> String {
        let zz = z + 719_468
        let era = (zz >= 0 ? zz : zz - 146_096) / 146_097
        let doe = zz - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let yy = m <= 2 ? y + 1 : y
        return String(format: "%04d-%02d-%02d", yy, m, d)
    }

    /// LABEL: inclusive window length
    /// (T−8) − (T−60) + 1 = 53. Off-by-one here is a spec bug.
    public static func longWindowLength() -> Int {
        Params.longSlots
    }

    // MARK: - 1.1 7-day EWMA

    /// LABEL: raw exponential weight
    /// w_raw = α × (1−α)^age with age 0 at T−1 and age 6 at T−7. Missing nights are not passed in.
    public static func rawEwmaWeight(age: Int) -> Double {
        Params.alpha * pow(1.0 - Params.alpha, Double(age))
    }

    /// LABEL: full-week normalized EWMA weights
    /// Oldest → newest for a complete quality-OK week. T−1 ≈ 0.289, T−7 ≈ 0.051.
    public static func fullWeekNormalizedWeights() -> [Double] {
        let raw = (0...6).reversed().map { rawEwmaWeight(age: $0) }
        let w = raw.reduce(0, +)
        return raw.map { $0 / w }
    }

    /// LABEL: 7-day EWMA center
    /// Renormalized weighted mean of learn-weights × values. Empty mass returns nil.
    public static func ewmaCenter(values: [Double], weights: [Double]) -> Double? {
        precondition(values.count == weights.count)
        var num = 0.0, den = 0.0
        for i in 0..<values.count {
            num += weights[i] * values[i]
            den += weights[i]
        }
        guard den > 0 else { return nil }
        return num / den
    }

    // MARK: - 1.4 Student-t downweight

    /// LABEL: Student-t learn weight
    /// λ = min(1, (ν+1) / (ν + z_long²)). Moderate |z| still trains; |z|=4.2 → λ≈0.23.
    public static func studentTLambda(zLong: Double, nu: Double = Params.nu) -> Double {
        min(1.0, (nu + 1.0) / (nu + zLong * zLong))
    }

    /// LABEL: Huber learn weight (not v1 default)
    /// λ = 1 inside ±k_learn, else k_learn / |z|. Kept for comparison; evaluate uses Student-t.
    public static func huberLambda(zLong: Double, kLearn: Double = Params.kLearn) -> Double {
        let a = abs(zLong)
        if a <= kLearn { return 1 }
        guard a > 0 else { return 1 }
        return kLearn / a
    }

    // MARK: - 1.5 Borrowed 7-day spread

    /// LABEL: mix this week's MAD with when-well scale
    /// λ_s = n_learn / 7. Until a full train set, borrow spread_long so a 4-point MAD cannot explode.
    public static func borrowedSpread(spread7Raw: Double, spreadLong: Double?,
                                      nLearn: Double, establishedLong: Bool,
                                      floor: Double) -> (spread: Double, borrowed: Bool) {
        let raw = max(spread7Raw, floor)
        let lambdaS = min(1.0, nLearn / Params.nBorrow)
        if establishedLong, let sl = spreadLong {
            let mixed = lambdaS * raw + (1.0 - lambdaS) * sl
            return (max(mixed, floor), lambdaS < 1.0)
        }
        return (raw, false)
    }

    // MARK: - 1.2 Longer median + 1.6 CUSUM

    /// LABEL: robust scale from MAD
    /// spread = max(1.4826 × MAD, floor). Never a sample SD.
    public static func robustSpread(values: [Double], center: Double, floor: Double) -> Double {
        let mad = median(values.map { abs($0 - center) }) ?? 0
        return max(Params.madScale * mad, floor)
    }

    /// LABEL: trim fever days from the long list
    /// Keep days with |x − m0| / spread0 < k_learn. If too many are dropped, refuse to absorb.
    public static func trimLongList(_ values: [Double], floor: Double) -> (kept: [Double], absorbed: Bool, keptFrac: Double) {
        guard !values.isEmpty else { return ([], false, 0) }
        guard let m0 = median(values) else { return ([], false, 0) }
        let s0 = robustSpread(values: values, center: m0, floor: floor)
        let s1 = values.filter { abs($0 - m0) / s0 < Params.kLearn }
        let frac = Double(s1.count) / Double(values.count)
        let absorbed = frac >= (1.0 - Params.pRegime) && s1.count >= Params.nLongShow
        return (absorbed ? s1 : values, absorbed, frac)
    }

    /// LABEL: two-block median shift (diagnostic)
    /// median(last 14) − median(earlier) when |S| ≥ 28. Logged; CUSUM p_change is the regime decision.
    public static func twoBlockMedianShift(_ valuesOldestFirst: [Double],
                                           block: Int = 14, minN: Int = 28) -> Double? {
        guard valuesOldestFirst.count >= minN, valuesOldestFirst.count >= block else { return nil }
        let tail = Array(valuesOldestFirst.suffix(block))
        let head = Array(valuesOldestFirst.dropLast(block))
        guard let mNew = median(tail), let mOld = median(head) else { return nil }
        return mNew - mOld
    }

    /// LABEL: one CUSUM step
    /// S_t = max(0, S_{t−1} + |e|/spread − k). Missing days are not passed in (no increment, no reset).
    public static func cusumStep(previousS: Double, value: Double, center: Double, spread: Double) -> Double {
        guard spread > 0 else { return previousS }
        let increment = abs(value - center) / spread - Params.kCusum
        return max(0, previousS + increment)
    }

    /// LABEL: change probability
    /// p_change = 1 − exp(−S / h). regime_shift when p ≥ 0.90.
    public static func changeProbability(cusumS: Double) -> Double {
        1.0 - exp(-cusumS / Params.hCusum)
    }

    // MARK: - 1.7 Confidence

    /// LABEL: confidence this week
    /// valid × coverage × quality × stability, rounded 0–100. Not Charge.
    /// Full quality week (n_learn = 7) → stability 1 → 100. Four good nights with when-well borrow
    /// → stability 0.70 → 40. Stale → 0. Internal `conf_spread` stays a separate boolean.
    public static func confidencePct7(n7: Int, nLowQuality: Int, nLearn: Double,
                                      stale: Bool, establishedLongBorrowed: Bool) -> Int {
        let valid = min(Double(n7) / Double(Params.n7Show), 1)
        let coverage = Double(n7) / Double(Params.span7)
        let quality = qualityFrac(nOk: n7, nLowQuality: nLowQuality)
        let stability: Double
        if stale { stability = 0 }
        else if nLearn + 1e-9 >= Double(Params.span7) { stability = 1 }
        else if establishedLongBorrowed { stability = 0.70 }
        else { stability = 0.45 }
        return clipPct(100.0 * valid * coverage * quality * stability)
    }

    /// LABEL: confidence when-well
    /// valid × coverage × quality × stability on the 53-slot window.
    public static func confidencePctLong(nLong: Int, nLowQuality: Int, series: LBSeries,
                                         stale: Bool, regimeShift: Bool) -> Int {
        let need = Double(nLongEstablished(for: series))
        let valid = min(Double(nLong) / need, 1)
        let coverage = Double(nLong) / Double(Params.longSlots)
        let quality = qualityFrac(nOk: nLong, nLowQuality: nLowQuality)
        let stability: Double
        if stale { stability = 0 }
        else if regimeShift { stability = 0.70 }
        else { stability = 1 }
        return clipPct(100.0 * valid * coverage * quality * stability)
    }

    /// LABEL: quality fraction
    /// ok / (ok + low_quality). Missing days are Why missing, not this fraction.
    public static func qualityFrac(nOk: Int, nLowQuality: Int) -> Double {
        Double(nOk) / Double(max(nOk + nLowQuality, 1))
    }

    // MARK: - Robust helpers

    /// LABEL: median
    /// Odd count: middle value. Even count: mean of the two central values.
    public static func median(_ values: [Double]) -> Double? {
        let s = values.sorted()
        guard !s.isEmpty else { return nil }
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// Newest 28 long nights: a 21-day drift lives here. Whole-window Theil–Sen is dominated by the flat pre-period.
    static let slopeFitNights = 28

    /// Newest 7 long nights' median sits ≥ k_learn spreads from the older nights: a step, not a drift.
    static func recentBlockIsLevelStep(pairs: [(epoch: Int, value: Double)],
                                       olderMedian: Double, spread: Double) -> Bool {
        let newest = Array(pairs.suffix(7))
        guard newest.count >= 7, spread > 0 else { return false }
        let older = Array(pairs.dropLast(7))
        let ref = median(older.map(\.value)) ?? olderMedian
        guard let recent = median(newest.map(\.value)), ref.isFinite else { return false }
        return abs(recent - ref) / spread >= Params.kLearn * 0.75
    }

    // MARK: - One-day score (longer copy first, then 7-day)

    /// LABEL: score one civil day against history strictly before it
    /// Order: CUSUM on the night that just aged into when-well → trim/median → Student-t EWMA →
    /// borrow spread → today z → gap → confidence → persistence.
    static func scoreOneDay(tEpoch: Int, series: LBSeries, byDay: [Int: LBDailyObservation],
                            carry: LBCarry, epochStart: Int? = nil,
                            dayLogs: [String: LBDayLog] = [:]) -> LBEvaluation {
        let spec = seriesSpec(series)
        let p = params(for: series)
        let tISO = isoFromEpochDay(tEpoch)
        let todayObs = byDay[tEpoch]
        let todayNative = trainableNative(todayObs, series: series)
        let todayMath = todayNative.flatMap { toMath($0, series: series) }

        var lastOK = lastQualityOKEpoch(byDay: byDay, series: series, through: tEpoch, dayLogs: dayLogs)
        var stale: Bool = {
            guard let lastOK else { return true }
            return tEpoch - lastOK > Params.staleDays
        }()

        var longEpochs = Array((tEpoch - Params.lookbackLong)...(tEpoch - Params.gapDays - 1))
        if let epochStart {
            longEpochs = longEpochs.filter { $0 >= epochStart }
        }
        longEpochs = longEpochs.filter { nightIsClean($0, dayLogs: dayLogs) }
        let longTrain = mathValues(epochs: longEpochs, byDay: byDay, series: series)
        var nLongLowQ = countStatus(epochs: longEpochs, byDay: byDay, status: .lowQuality)
        let trim = trimLongList(longTrain, floor: spec.floor)
        let trimKeptFrac: Double? = longTrain.isEmpty ? nil : trim.keptFrac
        let twoBlockShift = twoBlockMedianShift(longTrain)
        let nEst = p.nLongEstablished

        var centerLong: Double? = nil
        var spreadLong: Double? = nil
        var nLong = 0
        var longHeld = false
        var lastLongUpdate: String? = nil

        if trim.absorbed, let med = median(trim.kept) {
            centerLong = med
            spreadLong = robustSpread(values: trim.kept, center: med, floor: spec.floor)
            nLong = trim.kept.count
            lastLongUpdate = lastUpdate(epochs: longEpochs, byDay: byDay, series: series,
                                       dayLogs: dayLogs)
        } else if let med = median(longTrain), longTrain.count >= Params.nLongShow {
            centerLong = med
            spreadLong = robustSpread(values: longTrain, center: med, floor: spec.floor)
            nLong = longTrain.count
            lastLongUpdate = lastUpdate(epochs: longEpochs, byDay: byDay, series: series,
                                       dayLogs: dayLogs)
        } else if let heldC = carry.centerLong, let heldS = carry.spreadLong {
            centerLong = heldC
            spreadLong = heldS
            nLong = carry.nLong
            longHeld = true
            lastLongUpdate = lastUpdate(epochs: longEpochs, byDay: byDay, series: series,
                                       dayLogs: dayLogs)
        }

        let longPairsAll: [(epoch: Int, value: Double)] = longEpochs.compactMap { e in
            guard let x = trainableMath(byDay[e], series: series) else { return nil }
            return (e, x)
        }
        let todayLog = dayLogs[tISO]
        let habitToday = todayLog?.habitClass ?? .unspecified
        var habitMatched = false
        var longPairs = longPairsAll
        if habitToday == .rest || habitToday == .trained {
            let matched = longPairsAll.filter { pair in
                let d = isoFromEpochDay(pair.epoch)
                return (dayLogs[d]?.habitClass ?? .unspecified) == habitToday
            }
            if matched.count >= 7 {
                longPairs = matched
                habitMatched = true
                if let med = median(matched.map(\.value)) {
                    centerLong = med
                    spreadLong = robustSpread(values: matched.map(\.value), center: med, floor: spec.floor)
                    nLong = matched.count
                }
                lastOK = lastQualityOKEpoch(byDay: byDay, series: series, through: tEpoch,
                                            dayLogs: dayLogs, habit: habitToday)
                stale = {
                    guard let lastOK else { return true }
                    return tEpoch - lastOK > Params.staleDays
                }()
                lastLongUpdate = longPairs.last.map { isoFromEpochDay($0.epoch) }
                let habitEpochs = longEpochs.filter {
                    habitMatches($0, habit: habitToday, dayLogs: dayLogs)
                }
                nLongLowQ = countStatus(epochs: habitEpochs, byDay: byDay, status: .lowQuality)
            }
        }
        if longHeld, let iso = lastLongUpdate, let heldEpoch = isoEpochDay(iso) {
            lastOK = heldEpoch
            stale = tEpoch - heldEpoch > Params.staleDays
        }
        let establishedLong = nLong >= nEst
        let showLong = nLong >= Params.nLongShow && centerLong != nil
        let slopePairs = Array(longPairs.suffix(slopeFitNights))
        let slope: Double? = theilSenSlope(xs: slopePairs.map { Double($0.epoch) },
                                           ys: slopePairs.map(\.value))
        let lastLongNight = longPairs.last?.epoch ?? (tEpoch - Params.gapDays - 1)
        var origin = slopePairs.isEmpty ? lastLongNight
            : (slopePairs.first!.epoch + slopePairs.last!.epoch) / 2
        let recentStep = recentBlockIsLevelStep(pairs: longPairs,
                                                olderMedian: centerLong ?? 0,
                                                spread: spreadLong ?? spec.floor)
        // Anchor the path so it passes through the last long night: intercept stays the long median.
        if !recentStep, let s = slope, let c = centerLong, let last = slopePairs.last, abs(s) > 1e-9 {
            let dt = (last.value - c) / s
            if dt.isFinite, abs(dt) < Double(Params.lookbackLong * 2) {
                origin = last.epoch - Int(dt.rounded())
            }
        }
        var residualSpread = spreadLong ?? spec.floor
        if !recentStep, let c = centerLong, let s = slope, !slopePairs.isEmpty {
            let resid = slopePairs.map { $0.value - (c + s * Double($0.epoch - origin)) }
            residualSpread = robustSpread(values: resid, center: 0, floor: spec.floor)
        }
        let slopeUsable = !recentStep
            && slopeIsUsable(slope: slope ?? 0, spread: spreadLong ?? spec.floor,
                             n: slopePairs.count, residualSpread: residualSpread,
                             established: establishedLong)
            && (tEpoch - lastLongNight) <= slopeHorizonDays
        let slopeValue = slope ?? 0

        // CUSUM on nights the slow path does not explain. A usable slope is the drift; do not
        // keep a CUSUM that piled up while the ramp was being fitted.
        var cusumS = carry.cusumS
        let entering = tEpoch - (Params.gapDays + 1)
        if slopeUsable {
            cusumS = 0
        } else if let liveCenter = carry.centerLong, let liveSpread = carry.spreadLong,
           epochStart.map({ entering >= $0 }) ?? true,
           nightIsClean(entering, dayLogs: dayLogs),
           let x = trainableMath(byDay[entering], series: series) {
            cusumS = cusumStep(previousS: cusumS, value: x, center: liveCenter, spread: liveSpread)
        }
        let pChange = changeProbability(cusumS: cusumS)
        let regimeShift = pChange >= Params.pThr && !slopeUsable

        if regimeShift, let heldC = carry.centerLong, let heldS = carry.spreadLong, carry.establishedLong {
            centerLong = heldC
            spreadLong = heldS
            nLong = max(nLong, carry.nLong)
            longHeld = true
            if let iso = lastLongUpdate, let heldEpoch = isoEpochDay(iso) {
                lastOK = heldEpoch
                stale = tEpoch - heldEpoch > Params.staleDays
            }
        }

        let expectedToday: Double? = centerLong.map {
            expectedOnPath(center: $0, slope: slopeValue, usable: slopeUsable,
                           day: tEpoch, origin: origin, lastNight: lastLongNight)
        }

        let absZ: [Double] = {
            guard let c = centerLong, let spr = spreadLong, spr > 0 else { return [] }
            return longPairs.map { pair in
                let exp = expectedOnPath(center: c, slope: slopeValue, usable: slopeUsable,
                                         day: pair.epoch, origin: origin, lastNight: lastLongNight)
                return abs(pair.value - exp) / spr
            }
        }()
        let kUsed = kBandFromStableWindow(tableK: p.kBand, absResidualZ: absZ, nLong: nLong)

        let weekEpochs = Array((tEpoch - p.span7)...(tEpoch - 1))
        var weekMath: [Double?] = []
        var lambdas: [Double] = []
        var n7 = 0
        for e in weekEpochs {
            if nightIsClean(e, dayLogs: dayLogs), let x = trainableMath(byDay[e], series: series) {
                n7 += 1
                var lambda = 1.0
                if establishedLong, let c = centerLong, let s = spreadLong, s > 0 {
                    let exp = expectedOnPath(center: c, slope: slopeValue, usable: slopeUsable,
                                             day: e, origin: origin, lastNight: lastLongNight)
                    lambda = studentTLambda(zLong: (x - exp) / s)
                }
                weekMath.append(x)
                lambdas.append(lambda)
            } else {
                weekMath.append(nil)
                lambdas.append(0)
            }
        }
        let nLearn = lambdas.reduce(0, +)
        let n7LowQ = countStatus(epochs: weekEpochs, byDay: byDay, status: .lowQuality)

        var rawNum = 0.0, rawDen = 0.0
        var learnNum = 0.0, learnDen = 0.0
        var madPool: [(x: Double, lambda: Double)] = []
        for (i, slot) in weekMath.enumerated() {
            guard let x = slot else { continue }
            let age = p.span7 - 1 - i
            let wRaw = rawEwmaWeight(age: age, alpha: p.alpha)
            rawNum += wRaw * x
            rawDen += wRaw
            let wLearn = wRaw * lambdas[i]
            learnNum += wLearn * x
            learnDen += wLearn
            madPool.append((x, lambdas[i]))
        }
        let center7Raw = rawDen > 0 ? rawNum / rawDen : nil

        var center7: Double? = nil
        var spread7: Double? = nil
        var weekHeld = false
        if nLearn >= Double(Params.n7Show), learnDen > 0 {
            center7 = learnNum / learnDen
        } else if let held = carry.center7, n7 >= Params.n7Show {
            center7 = held
            spread7 = carry.spread7
            weekHeld = true
        }

        var spread7Raw: Double? = nil
        if let c7 = center7, !weekHeld {
            let madSrc: [Double]
            let strong = madPool.filter { $0.lambda >= 0.5 }.map(\.x)
            if strong.count >= 3 { madSrc = strong }
            else { madSrc = madPool.map(\.x) }
            spread7Raw = robustSpread(values: madSrc, center: c7, floor: spec.floor)
            let mix = borrowedSpread(spread7Raw: spread7Raw ?? spec.floor,
                                     spreadLong: spreadLong,
                                     nLearn: nLearn,
                                     establishedLong: establishedLong,
                                     floor: spec.floor)
            spread7 = mix.spread
        }

        let show7 = n7 >= Params.n7Show && (center7 != nil || center7Raw != nil)
        if show7, center7 == nil, let raw = center7Raw {
            center7 = raw
            spread7Raw = robustSpread(values: madPool.map(\.x), center: raw, floor: spec.floor)
            spread7 = borrowedSpread(spread7Raw: spread7Raw ?? spec.floor, spreadLong: spreadLong,
                                     nLearn: nLearn, establishedLong: establishedLong,
                                     floor: spec.floor).spread
        }

        let confSpread: Bool = {
            if nLearn >= Double(p.span7) - 1e-9 { return true }
            if nLearn >= Double(Params.n7Show) && establishedLong { return true }
            return false
        }()

        let borrowedFromLong = establishedLong && nLearn + 1e-9 < Params.nBorrow
        let c7pct = confidencePct7(n7: n7, nLowQuality: n7LowQ, nLearn: nLearn,
                                   stale: stale, establishedLongBorrowed: borrowedFromLong)
        let cLongPct = confidencePctLong(nLong: nLong, nLowQuality: nLongLowQ, series: series,
                                         stale: stale, regimeShift: regimeShift)

        let alertEligible = establishedLong && !stale && !regimeShift

        func zScore(today: Double?, center: Double?, spread: Double?) -> Double? {
            guard let today, let center, let spread, spread > 0 else { return nil }
            return (today - center) / spread
        }
        let z7 = zScore(today: todayMath, center: center7, spread: spread7)
        let zLong = zScore(today: todayMath, center: expectedToday ?? centerLong, spread: spreadLong)

        let gap: Double?
        let gapZ: Double?
        if let raw = center7Raw, let cl = expectedToday ?? centerLong {
            gap = raw - cl
            gapZ = (spreadLong ?? 0) > 0 ? gap! / spreadLong! : nil
        } else {
            gap = nil
            gapZ = nil
        }

        var runLength = carry.runLength
        var recent = carry.recentZLong
        var worse: Bool? = nil
        if let z = zLong, todayMath != nil {
            worse = carry.zLongPrev.map { abs(z) > abs($0) }
            if abs(z) >= kUsed {
                runLength = carry.runLength + 1
            } else {
                runLength = 0
            }
            recent.append(z)
            if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        } else if todayMath == nil {
            runLength = 0
        }
        let hits3 = recent.suffix(3).filter { abs($0) >= kUsed }.count
        let twoOfThree = hits3 >= 2

        let weekVals = weekMath.compactMap { $0 }
        let r1Week = lag1R1(residuals: weekVals.map { $0 - (center7 ?? $0) }) ?? 0
        let r1Long = lag1R1(residuals: longPairs.map {
            $0.value - expectedOnPath(center: centerLong ?? $0.value, slope: slopeValue,
                                      usable: slopeUsable, day: $0.epoch, origin: origin,
                                      lastNight: lastLongNight)
        }) ?? 0
        let nEff7 = nEff(n: n7, r1: r1Week)
        let nEffLong = nEff(n: nLong, r1: r1Long)
        let ageLast = lastOK.map { tEpoch - $0 }
        let tonight = todayObs?.qualityStatus
        let trust7 = usualTrustPct(LBTrustInputs(
            nOk: n7, nWindow: p.span7, nLowQuality: n7LowQ, nEff: nEff7, nEstablish: p.span7,
            ageLastOk: ageLast, staleDays: Params.staleDays, slopeUsable: true,
            freezeOk: 1, confoundToday: false, tonightStatus: tonight))
        let trustLong = usualTrustPct(LBTrustInputs(
            nOk: nLong, nWindow: Params.longSlots, nLowQuality: nLongLowQ, nEff: nEffLong,
            nEstablish: nEst, ageLastOk: ageLast, staleDays: Params.staleDays,
            slopeUsable: slopeUsable, freezeOk: 1, confoundToday: false, tonightStatus: tonight))
        let how7 = howUnusualPct(z: z7, nEff: nEff7)
        let howLong = howUnusualPct(z: zLong, nEff: nEffLong)

        func copySnapshot(center: Double?, spread: Double?, n: Int, coverageDenom: Double,
                          lastUpdate: String?, version: String, held: Bool,
                          z: Double?, k: Double) -> LBCopySnapshot? {
            guard let center, let spread, n > 0 else { return nil }
            let lo = center - k * spread
            let hi = center + k * spread
            let delta: Double?
            if let tn = todayNative, let tm = todayMath {
                delta = series.usesLog ? (tn - toDisplay(center, series: series)) : (tm - center)
            } else {
                delta = nil
            }
            return LBCopySnapshot(
                center: center, spread: spread,
                centerDisplay: toDisplay(center, series: series),
                bandLoDisplay: toDisplay(lo, series: series),
                bandHiDisplay: toDisplay(hi, series: series),
                deltaDisplay: delta, z: z, n: n,
                coverage: Double(n) / coverageDenom,
                lastUpdate: lastUpdate, version: version, held: held)
        }

        let bandCenterLong = expectedToday ?? centerLong
        let copy7 = show7 ? copySnapshot(center: center7, spread: spread7, n: n7,
                                         coverageDenom: Double(p.span7),
                                         lastUpdate: lastUpdate(epochs: weekEpochs, byDay: byDay, series: series,
                                                                dayLogs: dayLogs),
                                         version: Params.version7, held: weekHeld, z: z7, k: kUsed) : nil
        let copyLong = showLong ? copySnapshot(center: bandCenterLong, spread: spreadLong, n: nLong,
                                               coverageDenom: Double(Params.longSlots),
                                               lastUpdate: lastLongUpdate,
                                               version: Params.versionLong, held: longHeld, z: zLong,
                                               k: kUsed) : nil

        let newCarry = LBCarry(
            center7: center7 ?? carry.center7,
            spread7: spread7 ?? carry.spread7,
            centerLong: centerLong ?? carry.centerLong,
            spreadLong: spreadLong ?? carry.spreadLong,
            nLong: nLong,
            establishedLong: establishedLong,
            cusumS: cusumS,
            zLongPrev: zLong ?? carry.zLongPrev,
            runLength: runLength,
            recentZLong: recent,
            lastQualityOKEpoch: lastOK,
            slopeLong: slope,
            slopeUsable: slopeUsable,
            longOriginEpoch: origin)

        return LBEvaluation(
            asOf: tISO, series: series, todayNative: todayNative,
            copy7: copy7, copyLong: copyLong,
            center7Raw: center7Raw,
            center7RawDisplay: center7Raw.map { toDisplay($0, series: series) },
            n7: n7, nLearn: nLearn, nLong: nLong, lambdas: lambdas,
            gap: gap, gapZ: gapZ, z7: z7, zLong: zLong,
            show7: show7, showLong: showLong, establishedLong: establishedLong,
            confSpread: confSpread, alertEligible: alertEligible, stale: stale,
            confidencePct7: c7pct, confidencePctLong: cLongPct,
            usualTrustPct7: trust7, usualTrustPctLong: trustLong,
            howUnusualPct7: how7, howUnusualPctLong: howLong,
            slopeLong: slope, slopeUsable: slopeUsable, expectedLong: expectedToday,
            nEff7: nEff7, nEffLong: nEffLong,
            kBandTable: p.kBand, kBandUsed: kUsed,
            stableWindow: stableWindow(for: series),
            habitClass: habitToday, habitMatched: habitMatched,
            nCleanLong: nLong,
            pChange: pChange, cusumS: cusumS, regimeShift: regimeShift,
            twoBlockShift: twoBlockShift, trimKeptFrac: trimKeptFrac,
            runLength: runLength, worse: worse, hits3: hits3, twoOfThree: twoOfThree,
            paramSet: Params.paramSet, carry: newCarry)
    }

    // MARK: - Observation helpers

    /// LABEL: DailyMetric column pick
    /// One native number per series. avgSdnn and recovery are never used.
    static func nativeValue(from day: DailyMetric, series: LBSeries) -> (value: Double?, streamPresent: Bool) {
        switch series {
        case .sleepRHR: return (day.restingHr.map(Double.init), day.restingHr != nil)
        case .sleepHRVLn: return (day.avgHrv, day.avgHrv != nil)
        case .sleepTemp: return (day.skinTempC, day.skinTempC != nil)
        case .sleepResp: return (day.respRateBpm, day.respRateBpm != nil)
        case .sleepSpO2Mean: return (day.spo2Pct, day.spo2Pct != nil)
        case .wakingSteps: return (day.steps.map(Double.init), day.steps != nil)
        default: return (nil, false)
        }
    }

    /// LABEL: apply range / coverage / sparse-sleep gates
    /// Writes quality_status + quality_reason. Out-of-range 200 bpm is not an observation that trains.
    public static func observation(day: String, native: Double?, streamPresent: Bool,
                            sleepHrOnly: Bool, series: LBSeries) -> LBDailyObservation {
        let spec = seriesSpec(series)
        if series == .wakingSteps {
            if !streamPresent {
                return LBDailyObservation(day: day, value: nil, qualityStatus: .missing,
                                          qualityReason: .unknown, streamPresent: false)
            }
            guard let native else {
                return LBDailyObservation(day: day, value: nil, qualityStatus: .missing,
                                          qualityReason: .unknown, streamPresent: true)
            }
            if native > spec.maxVal {
                return LBDailyObservation(day: day, value: native, qualityStatus: .lowQuality,
                                          qualityReason: .outOfRange, streamPresent: true)
            }
            return LBDailyObservation(day: day, value: native, qualityStatus: .ok,
                                      streamPresent: true)
        }
        guard let native else {
            return LBDailyObservation(day: day, value: nil, qualityStatus: .missing,
                                      qualityReason: .unknown, streamPresent: streamPresent)
        }
        if native < spec.minVal || native > spec.maxVal {
            return LBDailyObservation(day: day, value: native, qualityStatus: .lowQuality,
                                      qualityReason: .outOfRange, streamPresent: streamPresent)
        }
        if series.context == .sleep, sleepHrOnly {
            return LBDailyObservation(day: day, value: native, qualityStatus: .lowQuality,
                                      qualityReason: .sparseSleep, streamPresent: streamPresent)
        }
        return LBDailyObservation(day: day, value: native, qualityStatus: .ok, streamPresent: streamPresent)
    }

    /// LABEL: index observations by epoch
    /// Last row for a duplicate day wins. Coverage gates for awake-rest / SpO₂ run here.
    static func indexByDay(_ observations: [LBDailyObservation], series: LBSeries) -> [Int: LBDailyObservation] {
        var out: [Int: LBDailyObservation] = [:]
        for obs in observations {
            guard let e = isoEpochDay(obs.day) else { continue }
            out[e] = applyCoverageGate(obs, series: series)
        }
        return out
    }

    /// LABEL: coverage gate
    /// Awake-rest ≥30 still minutes; awake-active ≥30 moving minutes; continuous ≥240 minutes;
    /// SpO₂ ≥8 valid 30-minute slots in that context when coverage is present.
    public static func applyCoverageGate(_ obs: LBDailyObservation, series: LBSeries) -> LBDailyObservation {
        var o = obs
        switch series {
        case .awakeRestHR, .awakeRestHRVLn:
            if o.qualityStatus == .ok {
                guard let c = o.coverage else {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                    break
                }
                if c < Params.awakeRestMinStill {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                }
            }
        case .awakeActiveHR, .awakeActiveHRVLn:
            if o.qualityStatus == .ok {
                guard let c = o.coverage else {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                    break
                }
                if c < Params.awakeActiveMinMoving {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                }
            }
        case .continuousHR, .continuousHRVLn:
            if o.qualityStatus == .ok {
                guard let c = o.coverage else {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                    break
                }
                if c < Params.continuousMinMinutes {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                }
            }
        case .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean:
            guard let c = o.coverage else {
                o.qualityStatus = .missing
                o.qualityReason = .lowCoverage
                o.value = nil
                break
            }
            if c < Params.spo2MinSlots {
                o.qualityStatus = .missing
                o.qualityReason = .lowCoverage
                o.value = nil
            }
        case .sleepSpO2Mean, .sleepSpO2Nadir:
            if let c = o.coverage, c < Params.spo2MinSlots {
                o.qualityStatus = .missing
                o.qualityReason = .lowCoverage
                o.value = nil
            }
        case .wakingImuEnergy:
            if o.qualityStatus == .ok {
                guard let c = o.coverage else {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                    break
                }
                if c < Params.imuMinMinutes {
                    o.qualityStatus = .lowQuality
                    o.qualityReason = .lowCoverage
                }
            }
        default:
            break
        }
        return o
    }

    /// LABEL: trainable native value
    /// Quality-OK + in range + finite. Low-quality and missing return nil (not 0).
    static func trainableNative(_ obs: LBDailyObservation?, series: LBSeries) -> Double? {
        guard let obs, obs.qualityStatus == .ok, let v = obs.value, v.isFinite else { return nil }
        let spec = seriesSpec(series)
        if v < spec.minVal || v > spec.maxVal { return nil }
        if series.usesLog, v <= 0 { return nil }
        return v
    }

    /// LABEL: trainable math value
    static func trainableMath(_ obs: LBDailyObservation?, series: LBSeries) -> Double? {
        trainableNative(obs, series: series).flatMap { toMath($0, series: series) }
    }

    static func mathValues(epochs: [Int], byDay: [Int: LBDailyObservation], series: LBSeries) -> [Double] {
        epochs.compactMap { trainableMath(byDay[$0], series: series) }
    }

    static func countStatus(epochs: [Int], byDay: [Int: LBDailyObservation], status: LBQualityStatus) -> Int {
        epochs.filter { byDay[$0]?.qualityStatus == status }.count
    }

    static func habitMatches(_ epoch: Int, habit: LBHabitClass?,
                             dayLogs: [String: LBDayLog]) -> Bool {
        guard let habit, habit == .rest || habit == .trained else { return true }
        return (dayLogs[isoFromEpochDay(epoch)]?.habitClass ?? .unspecified) == habit
    }

    static func lastUpdate(epochs: [Int], byDay: [Int: LBDailyObservation], series: LBSeries,
                           dayLogs: [String: LBDayLog] = [:]) -> String? {
        for e in epochs.reversed() {
            if nightIsClean(e, dayLogs: dayLogs), trainableMath(byDay[e], series: series) != nil {
                return isoFromEpochDay(e)
            }
        }
        return nil
    }

    static func firstFeltIllOnset(dayLogs: [String: LBDayLog], through t: String) -> String? {
        guard let tEpoch = isoEpochDay(t) else { return nil }
        var onset: String?
        let epochs = dayLogs.keys.compactMap(isoEpochDay).filter { $0 <= tEpoch }.sorted()
        guard let first = epochs.first, first <= tEpoch else { return nil }
        for e in first...tEpoch {
            let day = isoFromEpochDay(e)
            let ill = dayLogs[day]?.feltIll == true
            let prevIll = dayLogs[isoFromEpochDay(e - 1)]?.feltIll == true
            if ill && !prevIll { onset = day }
        }
        return onset
    }

    static func makeUsualFreeze(pre: LBEvaluation, t0CivilDay: String, reason: String) -> LBUsualFreeze? {
        guard let cl = pre.copyLong?.center, let sl = pre.copyLong?.spread,
              let c7 = pre.copy7?.center, let s7 = pre.copy7?.spread else { return nil }
        return LBUsualFreeze(t0CivilDay: t0CivilDay, tFreeze: pre.asOf, reason: reason, version: 2,
                             centerLong: cl, spreadLong: sl, center7: c7, spread7: s7)
    }

    static func lastQualityOKEpoch(byDay: [Int: LBDailyObservation], series: LBSeries, through t: Int,
                                  dayLogs: [String: LBDayLog] = [:],
                                  habit: LBHabitClass? = nil) -> Int? {
        byDay.keys.filter {
            $0 <= t && trainableMath(byDay[$0], series: series) != nil
                && nightIsClean($0, dayLogs: dayLogs)
                && habitMatches($0, habit: habit, dayLogs: dayLogs)
        }.max()
    }

    static func clipPct(_ x: Double) -> Int {
        Int((min(100, max(0, x))).rounded())
    }

    static func emptyEvaluation(asOf: String, series: LBSeries, carry: LBCarry) -> LBEvaluation {
        LBEvaluation(asOf: asOf, series: series, todayNative: nil,
                     copy7: nil, copyLong: nil, center7Raw: nil, center7RawDisplay: nil,
                     n7: 0, nLearn: 0, nLong: 0, lambdas: Array(repeating: 0, count: 7),
                     gap: nil, gapZ: nil, z7: nil, zLong: nil,
                     show7: false, showLong: false, establishedLong: false,
                     confSpread: false, alertEligible: false, stale: true,
                     confidencePct7: 0, confidencePctLong: 0,
                     pChange: 0, cusumS: carry.cusumS, regimeShift: false,
                     twoBlockShift: nil, trimKeptFrac: nil,
                     runLength: 0, worse: nil, hits3: 0, twoOfThree: false,
                     paramSet: Params.paramSet, carry: carry)
    }
}
