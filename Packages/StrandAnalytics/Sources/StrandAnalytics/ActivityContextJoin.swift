import Foundation

// ActivityContextJoin.swift — full-support joins from activity epochs to physiological
// support intervals (spec §9 / contract C4).
//
// Every physiological result in the repo already carries an explicit support interval (15-min HRV
// slots `[slot*900, (slot+1)*900)`, 5-min nightly windows, per-sleep-session RR/resting-HR spans).
// This join answers "what was the activity over the WHOLE interval" — never "whatever label
// happened at the final second". Every second of the support `[start, end)` is counted exactly
// once (spec §9 contract item 1): partial epochs are weighted by their overlap duration, abstained
// AND unobserved seconds within an epoch count toward unknown share (WS-10-F02), and seconds with
// no epoch at all (gaps/tails) count unknown too — so Sum(shares) + unknownShare == 1 over the
// full duration, always (A02). See `coverage(for:)` for the same-duration coverage measure.
//
// The resting-eligibility view here is the C4 NEW view only: exported for a future
// context-filtered resting HRV comparison, deliberately NOT wired to any existing metric or score.
// It consumes COARSE-POLICY epochs only (see the measurement-independence rule on
// `restingEligibility`): it never reads HR/HRV/respiration by construction.

public enum ActivityContextJoin {

    /// Resting-eligibility stationary floor (C4: >= 90% supported stationary time).
    public static let restingStationaryFloor: Double = 0.90
    /// Resting-eligibility coverage floor (C4: >= 90% qualified temporal coverage).
    public static let restingCoverageFloor: Double = 0.90
    /// Largest gap between two epochs across which a label change still counts as a transition — the
    /// interval builder's own merge gap (`ActivityContextIntervalBuilder.Config.mergeGapS`), so a sit/stand
    /// that straddles a few dropped seconds is not silently uncounted (D3-06).
    public static let transitionGapS: Int = ActivityContextIntervalBuilder.Config().mergeGapS

    /// Full-support duration-weighted activity composition over `[start, end)` (spec §9 / A02).
    ///
    /// Every second of the support is counted EXACTLY once against the full `end - start`
    /// duration: covered-valid seconds go to their label; abstained seconds, unobserved
    /// seconds inside covered epochs, and fully uncovered seconds (gaps and tails) all count
    /// toward `unknownShare`. Invariants (spec §9 contract item 2):
    ///   • Sum(shares) + unknownShare == 1 over the FULL interval, always;
    ///   • coverage = covered support seconds / (end - start) <= 1 (see `coverage(for:)`),
    ///     with `low_coverage` firing at `coverage <= 0.5` (boundary decided explicitly).
    ///
    /// - Returns: shares keyed by motion label (valid seconds only; `.unknown` never appears as a
    ///   key), `unknownShare`, `transitions` (label changes between consecutive overlapping
    ///   epochs, including across a gap of at most `transitionGapS`), `recentActivity` (seconds from
    ///   the last supported non-stationary epoch's end to the interval START; 0 when such an epoch
    ///   overlaps the interval, i.e. the activity is ongoing or happened inside it; nil when none),
    ///   `postureSource` ("user_confirmed" | "none"
    ///   in v1; "model" reserved), and derived `qualityReasons`.
    public static func context(for interval: [Int],
                               epochs: [ActivityEpoch],
                               config: ActivityPolicyConfig = .default) -> ActivityContextSummary {
        let start = interval[0]
        let end = interval[1]
        let duration = Double(end - start)
        guard duration > 0 else {
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

        // Full-support accounting (spec §9 contract item 2, A02): shares + unknownShare
        // sum to 1 over the WHOLE `[start, end)` support, not just the epoch-covered
        // weight. Uncovered seconds and within-epoch unobserved seconds both count
        // unknown (WS-10-F02), so `shares + unknownShare == 1` always holds.
        let accounting = account(start: start, end: end, epochs: overlapping)
        var shares = accounting.shares
        for key in shares.keys { shares[key] = shares[key]! / duration }
        let unknownShare = accounting.unknownSeconds / duration

        // Transitions between CONSECUTIVE overlapping epochs: adjacent on the grid, or separated by a
        // gap no longer than `transitionGapS` (label -> short gap -> other label is still a change).
        let ordered = overlapping.sorted { $0.startTs < $1.startTs }
        var transitions = 0
        for i in 1..<ordered.count where (0...transitionGapS).contains(ordered[i].startTs - ordered[i - 1].endTs)
            && ordered[i - 1].motion != ordered[i].motion {
            transitions += 1
        }

        // Recent supported non-stationary activity, measured from the interval START (run1 D3-17): a
        // walk that ended right as a 15-min slot began is 0 s before it, not 900 s. An activity epoch
        // overlapping the interval (still going at its end, or inside it) is ongoing and reads 0. This
        // scans ALL provided epochs (not only the overlapping ones): an HRV slot's interpretation needs
        // the activity that ended just before the slot began, which shares none of its bucket.
        var recentActivity: Int? = nil
        for e in epochs where e.isSupportedNonStationary && e.startTs < end {
            let since = max(0, start - e.endTs)
            if recentActivity == nil || since < recentActivity! { recentActivity = since }
        }

        let postureSource: String = ordered.contains { $0.posture != .unknown } ? "user_confirmed" : "none"

        var reasons: [String] = []
        let coverageRatio = accounting.coveredSeconds / duration
        // Boundary decided explicitly (A02 / WS-10-F01): coverage is measured against the
        // same full-support duration, and at exactly 0.5 the interval is half data-missing,
        // so low_coverage MUST fire there (the old strict < silently cleared the warning at
        // the spec's own example value). Uncovered seconds are data-missing and
        // distinguishable from the fully-empty "no_data" case.
        if coverageRatio <= 0.5 { reasons.append("low_coverage") }
        if unknownShare >= 0.5 { reasons.append("unknown_motion") }
        if ordered.contains(where: { $0.wear == .offWrist }) { reasons.append("off_wrist") }
        if ordered.contains(where: { $0.exertion == .postActivity }) { reasons.append("post_activity") }
        if let recent = recentActivity, recent < config.postActivityWindowS { reasons.append("recent_activity") }

        return ActivityContextSummary(shares: shares, unknownShare: unknownShare,
                                      transitions: transitions, recentActivity: recentActivity,
                                      postureSource: postureSource, qualityReasons: reasons)
    }

    /// Full-support coverage of `[start, end)` (spec §9 contract item 2).
    ///
    /// Fraction of the support interval covered by at least one epoch, in [0, 1],
    /// measured against the SAME duration as `context(for:)`. Uncovered seconds are
    /// data-missing: they are exactly what pushes `unknownShare` above the
    /// covered-internal abstention, and they are signalled by the `low_coverage`
    /// reason (firing at `coverage <= 0.5`, boundary decided explicitly per A02).
    public static func coverage(for start: Int, end: Int, epochs: [ActivityEpoch]) -> Double {
        let duration = Double(end - start)
        guard duration > 0 else { return 0 }
        let overlapping = epochs.filter { $0.startTs < end && $0.endTs > start }
        guard !overlapping.isEmpty else { return 0 }
        return account(start: start, end: end, epochs: overlapping).coveredSeconds / duration
    }

    /// Convenience overload taking explicit start/end.
    public static func coverage(for interval: [Int], epochs: [ActivityEpoch]) -> Double {
        coverage(for: interval[0], end: interval[1], epochs: epochs)
    }

    /// Per-second accounting over `[start, end)`.
    ///
    /// Every second of the support is counted EXACTLY once:
    ///   • a second inside a winning epoch contributes the epoch's valid fraction to
    ///     its label share and the rest to unknown (abstained `observed - valid` AND
    ///     unobserved `duration - observed` seconds both count unknown — WS-10-F02);
    ///   • a second with no epoch (gap or interval tail) is fully unknown.
    /// `shares + unknownSeconds == end - start` by construction (up to fp rounding), so
    /// normalizing by `end - start` yields `Sum(shares) + unknownShare == 1` always.
    ///
    /// Valid seconds are allocated proportionally across the winning width: an epoch
    /// stores only `validS`/`observedS`, not per-second validity, so the join uses
    /// `validS / durationSeconds` (equivalently, treats the winning span as a uniform
    /// sample of the epoch's grid).
    ///
    /// Overlap rule (deterministic, spec §9 contract item 1): when epochs share a
    /// second, the earliest-start epoch owns it; ties break by earliest end, then input
    /// order. The coarse-policy grid never overlaps by construction, so this only
    /// guards malformed/merged input and prevents a shared second from being
    /// double-counted (incl. duplicate copies of one epoch).
    private static func account(start: Int, end: Int,
                                epochs: [ActivityEpoch]) -> (shares: [MotionLabel: Double],
                                                             unknownSeconds: Double,
                                                             coveredSeconds: Double) {
        let segments = epochs.enumerated().map { (index, e) in
            (index: index, epoch: e, s: max(e.startTs, start), e2: min(e.endTs, end))
        }.sorted { a, b in
            if a.s != b.s { return a.s < b.s }
            if a.e2 != b.e2 { return a.e2 < b.e2 }
            return a.index < b.index
        }

        var shares: [MotionLabel: Double] = [:]
        var unknown = 0.0
        var covered = 0.0
        var cursor = start
        for seg in segments {
            if seg.e2 <= cursor { continue }            // fully claimed by an earlier epoch
            if seg.s > cursor {
                unknown += Double(seg.s - cursor)       // uncovered gap -> data-missing
            }
            let width = Double(seg.e2 - max(seg.s, cursor))
            guard width > 0 else { continue }
            let grid = Double(seg.epoch.durationSeconds)
            // Clamped to [0, 1] so a malformed epoch (validS > grid width) can never
            // push shares + unknownShare above 1: the conservation contract holds for
            // any input.
            let validFraction = grid > 0 ? min(1.0, Double(seg.epoch.validS) / grid) : 0
            if seg.epoch.motion != .unknown {
                shares[seg.epoch.motion, default: 0] += width * validFraction
            }
            unknown += width * (1 - validFraction)
            covered += width
            cursor = max(cursor, seg.e2)
        }
        if cursor < end {
            unknown += Double(end - cursor)             // uncovered tail -> data-missing
        }
        return (shares, unknown, covered)
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
    /// MEASUREMENT-INDEPENDENCE RULE (spec §8 circularity, WS-08-F01/F02): eligibility for a
    /// physiological comparison consumes COARSE-POLICY epochs only (motion/steps/contact/
    /// annotations — `ActivityContextPolicy` never reads HR by construction, and `ActivityEpoch`
    /// carries no HR/HRV/respiration field). The GRANULAR HSMM decoder path IS HR-fused upstream:
    /// `MotionEncoderOutput.classProbs` feeds windows whose confidence/abstention can shift with
    /// hrRel (ActivityContextModel HR channels), so a granular head can change epoch abstention
    /// and flip resting eligibility for the same motion. Granular-decoder epochs MUST NOT gate
    /// resting pools without an hr-free variant; only the coarse-policy epoch path may feed this
    /// verdict. Counterfactual invariance is pinned by
    /// `testJoinAndEligibilityInvariantToNonConsumedEpochFields`.
    ///
    /// Eligible when, over `[window.start, window.end)`:
    ///   • >= 90% supported stationary time (stationary seconds / window duration),
    ///   • >= 90% qualified temporal coverage (valid epoch seconds / window duration),
    ///   • >= `minStillnessS` (300 s default) of sustained stationary seconds immediately before
    ///     the window (a trailing stationary run with no gaps, no supported activity),
    ///   • on-wrist (at least one on_wrist epoch, none off_wrist),
    ///   • awake (no asleep epoch, at least one awake epoch).
    ///
    /// Full-duration accounting: `stationaryFraction` and `coverageFraction` are measured against
    /// the whole `window` duration (never the overlapping-epoch weight), and unobserved seconds
    /// inside a partially-observed epoch are NOT valid coverage (WS-10-F02: the valid fraction is
    /// `validS / durationSeconds`, not `validS / observedS`).
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
            // WS-10-F02: unobserved seconds inside the epoch (duration - observed) are NOT
            // valid coverage — the valid fraction is validS / durationSeconds, not
            // validS / observedS. Clamped to [0, 1] against malformed input.
            let validFraction = e.durationSeconds > 0
                ? min(1.0, Double(e.validS) / Double(e.durationSeconds)) : 0
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
