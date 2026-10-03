import Foundation

// ActivityContextJoin.swift — duration-weighted joins from activity epochs to physiological
// support intervals (spec §9 / contract C4).
//
// Every physiological result in the repo already carries an explicit support interval (15-min HRV
// slots `[slot*900, (slot+1)*900)`, 5-min nightly windows, per-sleep-session RR/resting-HR spans).
// This join answers "what was the activity over the WHOLE interval" — never "whatever label
// happened at the final second". Partial epochs are weighted by their overlap duration; abstained
// seconds within an epoch count toward unknown share, not toward any label.
//
// The resting-eligibility view here is the C4 NEW view only: exported for a future
// context-filtered resting HRV comparison, deliberately NOT wired to any existing metric or score.

public enum ActivityContextJoin {

    /// Resting-eligibility stationary floor (C4: >= 90% supported stationary time).
    public static let restingStationaryFloor: Double = 0.90
    /// Resting-eligibility coverage floor (C4: >= 90% qualified temporal coverage).
    public static let restingCoverageFloor: Double = 0.90

    /// Duration-weighted activity composition over `[start, end)`.
    ///
    /// - Returns: shares keyed by motion label (valid seconds only; `.unknown` never appears as a
    ///   key), `unknownShare` (abstained + unknown-epoch seconds), `transitions` (label changes
    ///   between consecutive overlapping epochs), `recentActivity` (seconds from the interval end
    ///   since the last supported non-stationary epoch ended; nil when none), `postureSource`
    ///   ("user_confirmed" | "none" in v1; "model" reserved), and derived `qualityReasons`.
    ///   Sum(shares) + unknownShare == 1.
    public static func context(for interval: [Int],
                               epochs: [ActivityEpoch],
                               config: ActivityPolicyConfig = .default) -> ActivityContextSummary {
        let start = interval[0]
        let end = interval[1]
        guard end > start else {
            return ActivityContextSummary(shares: [:], unknownShare: 1.0, transitions: 0,
                                          recentActivity: nil, postureSource: "none",
                                          qualityReasons: ["invalid_interval"])
        }
        let overlapping = epochs.filter { $0.startTs < end && $0.endTs > start }
        guard !overlapping.isEmpty else {
            return ActivityContextSummary(shares: [:], unknownShare: 1.0, transitions: 0,
                                          recentActivity: nil, postureSource: "none",
                                          qualityReasons: ["no_data"])
        }

        var totalWeight = 0.0
        var weighted: [(epoch: ActivityEpoch, weight: Double)] = []
        for e in overlapping {
            let w = Double(min(e.endTs, end) - max(e.startTs, start))
            totalWeight += w
            weighted.append((e, w))
        }

        var shares: [MotionLabel: Double] = [:]
        var unknown = 0.0
        for item in weighted {
            let validFraction = 1.0 - item.epoch.unknownFraction
            if item.epoch.motion != .unknown {
                shares[item.epoch.motion, default: 0] += item.weight * validFraction
            }
            unknown += item.weight * item.epoch.unknownFraction
        }
        guard totalWeight > 0 else {
            return ActivityContextSummary(shares: [:], unknownShare: 1.0, transitions: 0,
                                          recentActivity: nil, postureSource: "none",
                                          qualityReasons: ["no_data"])
        }
        for key in shares.keys { shares[key] = shares[key]! / totalWeight }
        let unknownShare = unknown / totalWeight

        // Transitions between CONSECUTIVE overlapping epochs (adjacent on the grid only).
        let ordered = overlapping.sorted { $0.startTs < $1.startTs }
        var transitions = 0
        for i in 1..<ordered.count where ordered[i - 1].endTs == ordered[i].startTs
            && ordered[i - 1].motion != ordered[i].motion {
            transitions += 1
        }

        // Recent supported non-stationary activity, measured from the interval end. This scans ALL
        // provided epochs (not only the overlapping ones): an HRV slot's interpretation needs the
        // activity that ended just before the slot began, which shares none of its bucket.
        var recentActivity: Int? = nil
        for e in epochs.sorted(by: { $0.startTs < $1.startTs })
        where e.isSupportedNonStationary && e.endTs <= end {
            recentActivity = end - e.endTs
        }

        let postureSource: String = ordered.contains { $0.posture != .unknown } ? "user_confirmed" : "none"

        var reasons: [String] = []
        let coverageRatio = totalWeight / Double(end - start)
        if coverageRatio < 0.5 { reasons.append("low_coverage") }
        if unknownShare >= 0.5 { reasons.append("unknown_motion") }
        if ordered.contains(where: { $0.wear == .offWrist }) { reasons.append("off_wrist") }
        if ordered.contains(where: { $0.exertion == .postActivity }) { reasons.append("post_activity") }
        if let recent = recentActivity, recent < config.postActivityWindowS { reasons.append("recent_activity") }

        return ActivityContextSummary(shares: shares, unknownShare: unknownShare,
                                      transitions: transitions, recentActivity: recentActivity,
                                      postureSource: postureSource, qualityReasons: reasons)
    }

    /// Convenience overload taking explicit start/end.
    public static func context(for start: Int, end: Int,
                               epochs: [ActivityEpoch],
                               config: ActivityPolicyConfig = .default) -> ActivityContextSummary {
        context(for: [start, end], epochs: epochs, config: config)
    }

    /// Per-slot activity composition for 15-min HRV slots (C10 `contexts.hrv_slots`).
    ///
    /// A slot's shares are duration-weighted over its WHOLE `[slot, slot+slotSeconds)` bucket, so
    /// a slot whose final 30-s epoch is walking but whose previous 870 s are stationary reads
    /// mostly stationary — it never inherits the final-second label.
    public static func hrvSlotContexts(slots: [Int],
                                       epochs: [ActivityEpoch],
                                       slotSeconds: Int = 900,
                                       config: ActivityPolicyConfig = .default) -> [HrvSlotContext] {
        slots.map { slot in
            let summary = context(for: slot, end: slot + slotSeconds, epochs: epochs, config: config)
            var rawShares: [String: Double] = [:]
            for (label, value) in summary.shares where label != .unknown {
                rawShares[label.rawValue] = value
            }
            let overlapping = epochs.filter { $0.startTs < slot + slotSeconds && $0.endTs > slot }
            let postActivity = overlapping.contains { $0.exertion == .postActivity }
            return HrvSlotContext(slotS: slot, shares: rawShares,
                                  unknownShare: summary.unknownShare,
                                  recentActivityS: summary.recentActivity,
                                  postActivity: postActivity)
        }
    }

    /// Per-session activity composition aligned to sleep sessions (C10 `contexts.sleep_sessions`).
    public static func sleepSessionContexts(sessions: [(start: Int, end: Int)],
                                            epochs: [ActivityEpoch],
                                            config: ActivityPolicyConfig = .default) -> [SleepSessionContext] {
        sessions.map { session in
            let summary = context(for: session.start, end: session.end, epochs: epochs, config: config)
            var rawShares: [String: Double] = [:]
            for (label, value) in summary.shares where label != .unknown {
                rawShares[label.rawValue] = value
            }
            return SleepSessionContext(start: session.start, end: session.end,
                                       shares: rawShares, unknownShare: summary.unknownShare)
        }
    }

    /// C4 resting-eligibility verdict for a fixed measurement window — NEW view, not wired anywhere.
    ///
    /// Eligible when, over `[window.start, window.end)`:
    ///   • >= 90% supported stationary time (stationary seconds / window duration),
    ///   • >= 90% qualified temporal coverage (valid epoch seconds / window duration),
    ///   • >= `minStillnessS` (300 s default) of sustained stationary seconds immediately before
    ///     the window (a trailing stationary run with no gaps, no supported activity),
    ///   • on-wrist (at least one on_wrist epoch, none off_wrist),
    ///   • awake (no asleep epoch, at least one awake epoch).
    ///
    /// With default v1 inputs (wear unknown, sleep unknown) the verdict is `not eligible` with an
    /// explicit reason — the policy never pretends quiet IMU proves on-wrist or awake.
    public static func restingEligibility(window: [Int],
                                          priorSeconds: Int,
                                          epochs: [ActivityEpoch],
                                          config: ActivityPolicyConfig = .default) -> RestingEligibility {
        let start = window[0]
        let end = window[1]
        let duration = Double(end - start)
        guard duration > 0 else {
            return RestingEligibility(eligible: false, reasons: ["invalid_window"],
                                      stationaryFraction: 0, coverageFraction: 0,
                                      priorStillnessS: 0, onWrist: false, awake: false)
        }

        let overlapping = epochs.filter { $0.startTs < end && $0.endTs > start }
        var validWeight = 0.0
        var stationaryWeight = 0.0
        for e in overlapping {
            let w = Double(min(e.endTs, end) - max(e.startTs, start))
            let validFraction = 1.0 - e.unknownFraction
            validWeight += w * validFraction
            if e.motion == .stationary { stationaryWeight += w * validFraction }
        }
        let stationaryFraction = min(1.0, stationaryWeight / duration)
        let coverageFraction = min(1.0, validWeight / duration)

        let priorStillness = trailingStillness(before: start, epochs: epochs, lookback: priorSeconds)
        let onWrist = overlapping.contains { $0.wear == .onWrist }
            && !overlapping.contains { $0.wear == .offWrist }
        let awake = overlapping.contains { $0.sleepState == .awake }
            && !overlapping.contains { $0.sleepState == .asleep }

        var reasons: [String] = []
        if stationaryFraction < restingStationaryFloor { reasons.append("insufficient_stationary") }
        if coverageFraction < restingCoverageFloor { reasons.append("insufficient_coverage") }
        if priorStillness < config.minStillnessS { reasons.append("insufficient_prior_stillness") }
        if overlapping.contains(where: { $0.wear == .offWrist }) {
            reasons.append("off_wrist")
        } else if !onWrist {
            reasons.append("wear_unknown")
        }
        if overlapping.contains(where: { $0.sleepState == .asleep }) {
            reasons.append("asleep")
        } else if !awake {
            reasons.append("sleep_unknown")
        }
        let eligible = reasons.isEmpty

        return RestingEligibility(eligible: eligible, reasons: reasons,
                                  stationaryFraction: stationaryFraction,
                                  coverageFraction: coverageFraction,
                                  priorStillnessS: priorStillness,
                                  onWrist: onWrist, awake: awake)
    }

    /// Convenience overload for restingEligibility taking explicit start/end.
    public static func restingEligibility(start: Int, end: Int, priorSeconds: Int,
                                          epochs: [ActivityEpoch],
                                          config: ActivityPolicyConfig = .default) -> RestingEligibility {
        restingEligibility(window: [start, end], priorSeconds: priorSeconds, epochs: epochs, config: config)
    }

    /// Seconds of sustained stationary coverage immediately before `start`, walking the epoch grid
    /// backward. A non-stationary epoch, an unknown epoch, or a coverage gap ends the run. Only
    /// epochs within `[start - lookback, start)` count — the lookback bounds how far back the
    /// stillness run may claim credit.
    private static func trailingStillness(before start: Int, epochs: [ActivityEpoch], lookback: Int) -> Int {
        let prior = epochs
            .filter { $0.startTs < start && $0.startTs >= start - lookback }
            .sorted { $0.startTs < $1.startTs }
        var accumulated = 0
        var consumedStart: Int? = nil
        var i = prior.count - 1
        while i >= 0 {
            let e = prior[i]
            if let laterStart = consumedStart, e.endTs != laterStart { break }  // gap
            guard e.motion == .stationary else { break }
            if e.endTs <= start {
                accumulated += e.validS
            } else {
                accumulated += (start - e.startTs)  // epoch overlapping the window's leading edge
            }
            consumedStart = e.startTs
            i -= 1
        }
        return accumulated
    }
}
