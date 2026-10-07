import Foundation
import StrandAnalytics

/// The numbers and status lines behind the three Today hero rings. Pure and static so the truth tables
/// are testable with no view, clock or strap (`HeroRingsTests`).
enum HeroRings {

    // MARK: Baseline

    /// How much of the baseline-learning window has been seen, 0...100. The Baseline ring fills with this
    /// while the score itself is still calibrating, instead of reading as an empty "–".
    static func learningProgress(nights: Int, needed: Int) -> Double {
        guard needed > 0 else { return 0 }
        return min(100, max(0, Double(nights) / Double(needed) * 100))
    }

    // MARK: Watchdog

    /// How far the heart is working, 0...100: the share of heart-rate reserve in use. 0 sits at resting
    /// heart rate and 100 at max. Nil with no reading or an unusable range.
    static func heartLoad(bpm: Double?, resting: Double, max maxHR: Double) -> Double? {
        guard let bpm, bpm > 0, maxHR > resting else { return nil }
        return min(100, max(0, (bpm - resting) / (maxHR - resting) * 100))
    }

    static func watchdogStatus(load: Double?) -> String {
        guard let load else { return String(localized: "No data") }
        if load < 20 { return String(localized: "Calm") }
        if load < 55 { return String(localized: "Active") }
        return String(localized: "Elevated")
    }

    enum WatchdogState: Equatable {
        case calm, watching, alert, waiting, offWrist
    }

    /// The live Watchdog call for the last half-hour. Nil result means the service has not scored yet.
    static func watchdogState(_ result: WatchdogResult?) -> WatchdogState {
        guard let result else { return .waiting }
        if result.unavailable == .wristOff { return .offWrist }
        guard result.monitoringCurrent, result.unavailable == nil else { return .waiting }
        switch result.severity {
        case .withinLimits, .note: return .calm
        case .candidate: return .watching
        case .active, .severe: return .alert
        case .dataUnavailable: return .waiting
        }
    }

    /// How far the last half-hour sits from the usual, 0...100. 100 is the severe cut, so the ring is
    /// full exactly when Watchdog would call it severe. Nil while there is nothing current to score.
    static func watchdogDistance(_ result: WatchdogResult?) -> Double? {
        guard let result, result.monitoringCurrent, result.unavailable == nil,
              result.fusedEnergy.isFinite else { return nil }
        let cut = max(WatchdogCalibration.tSevere, 0.01)
        return min(100, max(0, result.fusedEnergy / cut * 100))
    }

    static func watchdogLabel(_ state: WatchdogState) -> String {
        switch state {
        case .calm: return String(localized: "Calm")
        case .watching: return String(localized: "Watching")
        case .alert: return String(localized: "Alert")
        case .waiting: return String(localized: "Waiting")
        case .offWrist: return String(localized: "Off wrist")
        }
    }

    // MARK: Recovery

    static func recoveryStatus(score: Double?) -> String {
        guard let score else { return String(localized: "No data") }
        if score >= 67 { return String(localized: "On track") }
        if score >= 34 { return String(localized: "Building") }
        return String(localized: "Behind")
    }
}

extension LiquidTodayView.ChargeDisplay {
    /// What the Baseline ring draws: the score, or learning progress while calibrating.
    var ringValue: Double? {
        switch self {
        case .scored(let pct), .carried(let pct, _): return pct
        case .calibrating(let nights):
            return HeroRings.learningProgress(nights: nights, needed: Baselines.minNightsSeed)
        case .noData: return nil
        }
    }

    var ringStatus: String {
        switch self {
        case .scored(let pct), .carried(let pct, _):
            if pct >= 67 { return String(localized: "Within range") }
            if pct >= 34 { return String(localized: "Slightly elevated") }
            return String(localized: "Elevated")
        case .calibrating(let nights):
            return String(localized: "Learning \(nights) of \(Baselines.minNightsSeed)")
        case .noData:
            return String(localized: "No data")
        }
    }
}
