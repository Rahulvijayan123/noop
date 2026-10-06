import Foundation

// DetachShadow.swift — DETACH-derived NON-WEAR SHADOW detector (never authoritative).
//
// DETACH (Nimbalkar et al., "DETACH: A Wearable System to Detect and Track Wear of a Strap",
// IEEE IoT Journal 2023; MIT reference implementation https://github.com/nimbal/nimbaldetach)
// detects strap detachment from two corroborating channels: accelerometer motion (a strap left
// on a table is nearly motionless, so per-axis acceleration SD collapses) and skin temperature
// (a worn strap is warmed toward ~30 C by the wrist; a detached strap cools toward ambient).
// This file is a RE-IMPLEMENTATION of that core idea against the Nara/WHOOP 30-s epoch pipeline
// — not a copy of the reference code — and it is deliberately a SHADOW, never a decision maker:
//
//   - PURE: Foundation-only, deterministic, versioned (detach-shadow-1.0.0), no I/O or clock.
//   - Input is per-30-s-epoch aggregates (IMU quiescence energy in g + raw skin temp in C), NOT
//     DETACH's raw 60-100 Hz accelerometer stream. DETACH's per-axis SD ~8 mg threshold does not
//     transfer to our 4-s/1-Hz aggregates, so the motion channel here is an energy-quiescence
//     shadow, not DETACH proper — every threshold that depends on resolution is CALIBRATE.
//   - Temperature is RAW and carries per-device offsets: WHOOP 4 raw ADC must never be compared
//     to a universal 26/30 C band, and the WHOOP 5/MG worn mean (~30.57 C) sits only 0.57 C
//     under DETACH's 30 C cutoff, so an absolute cutoff would false-positive on worn straps.
//     The band threshold is therefore a CALIBRATE placeholder and the temperature-FALLING
//     channel (a per-device-offset-invariant comparison) is the robust half of the rule.
//   - It NEVER establishes wear and NEVER decides a state alone: it feeds
//     `WearSignalEvidence.detachShadowNonWear` ONLY, which the engine treats as a shadow —
//     AND-gated behind HR absence, at most a veto, never off_wrist authority (red-team 11 F6).
//   - Missing evidence stays missing: a window missing either channel is uncovered and counts
//     toward abstention, never toward a verdict.

/// One 30-s epoch of aggregates fed to `DetachShadow.evaluate`. Every field is Optional: nil
/// means the aggregate is MISSING for that epoch (not zero) — a missing channel never
/// contributes to a verdict, it only consumes a rolling-window slot.
public struct DetachShadowEpoch: Equatable, Sendable {
    /// Epoch start (Unix seconds). Used only for data-gap detection, never wall-clock expiry.
    public let epochStart: Int
    /// Per-30-s IMU quiescence energy in g (caller-computed, e.g. RMS of the high-passed
    /// acceleration magnitude). CALIBRATE: 4-s/1-Hz aggregates are not DETACH's raw 60-100 Hz,
    /// so the energy threshold must be measured against real captures, not taken from DETACH.
    public let imuEnergyG: Double?
    /// Per-30-s mean skin temperature in Celsius, RAW strap reading (uncalibrated). Per-device
    /// offsets mean this must never be compared to an absolute band (CALIBRATE; see below).
    public let skinTempCelsius: Double?

    public init(epochStart: Int, imuEnergyG: Double?, skinTempCelsius: Double?) {
        self.epochStart = epochStart
        self.imuEnergyG = imuEnergyG
        self.skinTempCelsius = skinTempCelsius
    }

    /// True when BOTH channels are present, i.e. the window is decision-capable. A window
    /// missing either channel cannot satisfy the AND of (quiescent AND temp-condition), so it
    /// counts toward abstention, never toward a verdict.
    public var isCovered: Bool { imuEnergyG != nil && skinTempCelsius != nil }
}

/// Versioned thresholds for `DetachShadow`. Everything touching resolution or raw temperature
/// is CALIBRATE (placeholder defaults with no labeled WHOOP ground truth behind them yet).
public struct DetachShadowConfig: Equatable, Sendable {
    /// Rolling window length in epochs (30 s each → 15 = a rolling minute).
    public var windowCount: Int = 15
    /// Minimum COVERED windows in the rolling window before the shadow speaks. Below this it
    /// abstains (returns nil) — the shadow never guesses from a sparse window.
    public var minCoverageWindows: Int = 12
    /// Minimum quiescent (and minimum temp-condition) windows in the rolling window. The AND
    /// of both channels must each hold in this many of the last `windowCount` slots.
    public var minQuiescentWindows: Int = 12
    /// CALIBRATE: per-30-s IMU energy below which an epoch counts as quiet. DETACH's per-axis
    /// SD ~8 mg at raw 60-100 Hz (~14 mg magnitude RMS across 3 axes) does not transfer to our
    /// 4-s/1-Hz aggregates; 0.02 g is a placeholder to be measured against captures.
    public var quiescenceThresholdG: Double = 0.02
    /// CALIBRATE: raw skin temperature below which an epoch counts as "cold". MUST be
    /// raw-relative per device — WHOOP 4 raw ADC has per-device offsets (never a universal
    /// 26/30 C band), and the WHOOP 5/MG worn mean ~30.57 C sits only 0.57 C under DETACH's
    /// 30 C cutoff, so an absolute 30 C would false-positive on worn straps. 29.0 is a
    /// placeholder below that mean; `tempFallDeltaCelsius` is the offset-invariant half.
    public var tempBelowCelsius: Double = 29.0
    /// CALIBRATE: minimum raw-temp drop from the most recent COVERED epoch before an epoch
    /// counts as "falling". Relative, so per-device offsets cancel.
    public var tempFallDeltaCelsius: Double = 0.2

    /// The shipped configuration.
    public static let standard = DetachShadowConfig()

    public init() {}

    /// Full memberwise init so tests and callers can tune one field without mutating after
    /// init (same pattern as `WearSignalQualityConfig` / `PpgSqiConfig`).
    public init(windowCount: Int = 15, minCoverageWindows: Int = 12, minQuiescentWindows: Int = 12,
                quiescenceThresholdG: Double = 0.02, tempBelowCelsius: Double = 29.0,
                tempFallDeltaCelsius: Double = 0.2) {
        self.windowCount = windowCount
        self.minCoverageWindows = minCoverageWindows
        self.minQuiescentWindows = minQuiescentWindows
        self.quiescenceThresholdG = quiescenceThresholdG
        self.tempBelowCelsius = tempBelowCelsius
        self.tempFallDeltaCelsius = tempFallDeltaCelsius
    }

    /// Algorithm version, persisted with every verdict for auditability.
    public let version = "detach-shadow-1.0.0"
}

/// Caller-owned rolling state for `DetachShadow` (hysteresis/coverage bookkeeping, spec §12
/// pattern). The shadow stays pure: threading the state explicitly keeps every verdict
/// reproducible from (epoch, state) pairs.
public struct DetachShadowState: Equatable, Sendable {
    /// One rolling-window slot (internal; tests assert it via `@testable import`).
    struct Slot: Equatable, Sendable {
        let covered: Bool
        let quiescent: Bool
        let tempCondition: Bool
    }

    /// Per-slot records over the rolling window, oldest first.
    var slots: [Slot] = []
    /// Raw skin temp of the most recent COVERED epoch, for the falling comparison.
    var lastCoveredTempCelsius: Double? = nil
    /// Epoch start of the most recent call (data-gap detection).
    var lastEpochStart: Int? = nil

    public init() {}
}

/// DETACH-derived non-wear shadow. One call per 30-s epoch, in epoch order.
public enum DetachShadow {

    /// Evaluate one 30-s epoch against the rolling window and update `state`.
    ///
    /// The rule (DETACH's core idea, re-implemented):
    ///   (a) IMU energy stays below the quiescence threshold in >= `minQuiescentWindows` of the
    ///       last `windowCount` windows, AND
    ///   (b) skin temp is below the raw-relative band OR falling relative to the most recent
    ///       covered window, also in >= `minQuiescentWindows` windows, AND
    ///   (c) coverage (windows with BOTH channels) >= `minCoverageWindows`, else ABSTAIN.
    ///
    /// - Returns: `true` = non-wear candidate, `false` = not a candidate, `nil` = ABSTAIN
    ///   because coverage is too low. The shadow never returns a verdict from a sparse window
    ///   and never establishes wear — the caller AND-gates it behind HR absence and uses it at
    ///   most as a veto.
    public static func evaluate(_ epoch: DetachShadowEpoch,
                                config: DetachShadowConfig = .standard,
                                state: inout DetachShadowState) -> Bool? {
        // Data gap: > 90 s since the last epoch — the rolling window is not comparable across
        // a gap, so reset the accumulators (same policy as `WearSignalQualityEngine`).
        if let last = state.lastEpochStart, epoch.epochStart - last > 90 {
            state.slots = []
            state.lastCoveredTempCelsius = nil
        }
        state.lastEpochStart = epoch.epochStart

        // Append this slot, covered or not. A missing channel still consumes a slot so the
        // fixed-size window keeps its denominator — that is what makes coverage meaningful.
        if epoch.isCovered {
            let quiescent = epoch.imuEnergyG! < config.quiescenceThresholdG
            let below = epoch.skinTempCelsius! < config.tempBelowCelsius
            let falling = state.lastCoveredTempCelsius
                .map { epoch.skinTempCelsius! < $0 - config.tempFallDeltaCelsius } ?? false
            state.slots.append(DetachShadowState.Slot(covered: true, quiescent: quiescent,
                                                      tempCondition: below || falling))
            state.lastCoveredTempCelsius = epoch.skinTempCelsius
        } else {
            state.slots.append(DetachShadowState.Slot(covered: false, quiescent: false,
                                                      tempCondition: false))
        }
        if state.slots.count > config.windowCount {
            state.slots.removeFirst(state.slots.count - config.windowCount)
        }

        // (c) Coverage gate: abstain when too few decision-capable windows.
        let coverage = state.slots.lazy.filter { $0.covered }.count
        guard coverage >= config.minCoverageWindows else { return nil }

        // (a) AND (b): both channels must each hold in enough of the rolling window.
        let quiescentCount = state.slots.lazy.filter { $0.quiescent }.count
        let tempCount = state.slots.lazy.filter { $0.tempCondition }.count
        return quiescentCount >= config.minQuiescentWindows && tempCount >= config.minQuiescentWindows
    }
}
