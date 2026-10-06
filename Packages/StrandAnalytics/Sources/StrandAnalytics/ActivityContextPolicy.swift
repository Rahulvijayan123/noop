import Foundation

// ActivityContextPolicy.swift — pure temporal policy: window predictions -> 30-s activity epochs.
//
// This is the Swift half of spec §9 / contract C4. The Python service is a pure per-window
// classifier (4-s windows, 2-s hop); everything temporal lives here, unit-testable with no Python,
// storage or network:
//
//   • 30-s epochs on the absolute UTC grid (epoch k covers [k*30, (k+1)*30)),
//   • causal vote + hysteresis (a label change needs `requiredConsecutiveVotes` consecutive
//     disagreeing windows before it flips; the transition offset is the first disagreeing window),
//   • history reset at data gaps,
//   • abstention: a window labelled `unknown` or below the confidence/margin thresholds contributes
//     to the epoch's unknown seconds, never to a label vote,
//   • observed/valid seconds accounting (abstaining coverage is observed but not valid),
//   • exercise tri-state from existing ExerciseSession records (absence != false),
//   • sleep state from existing SleepSession records (awake/asleep/unknown, wake segments),
//   • exertion context (active / post_activity / resting_candidate / mixed / unknown),
//   • wear unknown by default — quiet IMU is never on-wrist evidence.
//
// The policy never reads HR. `post_activity` is therefore never cleared by HR, by construction.

/// Tunables for the temporal policy (all defaults per C2/C4/C10).
public struct ActivityPolicyConfig: Equatable, Sendable {
    /// Epoch grid width, seconds (C3: 30).
    public var epochSeconds: Int = 30
    /// A window abstains when its max class probability is below this (C2 default).
    public var abstainMinMaxProb: Double = 0.80
    /// A window abstains when its top-2 margin is below this (C2 default).
    public var abstainMinMargin: Double = 0.15
    /// Consecutive disagreeing windows required before the smoothed label flips.
    public var requiredConsecutiveVotes: Int = 2
    /// A window starting more than this many seconds after the previous window's end is a gap.
    public var gapResetSeconds: Int = 4
    /// Post-activity annotation window after supported activity ends, seconds (C2: 10 min).
    public var postActivityWindowS: Int = 600
    /// Sustained stillness required before an epoch may be `resting_candidate`, seconds (C4).
    public var minStillnessS: Int = 300
    /// Supported-active seconds inside an epoch for the `mixed` label (must be both sides).
    public var minMixedActiveS: Int = 10
    /// Stationary seconds inside an epoch for the `mixed` label.
    public var minMixedStillS: Int = 10

    public init() {}

    public static let `default` = ActivityPolicyConfig()
}

public enum ActivityContextPolicy {

    // MARK: - Window acceptance (abstention)

    /// Whether a window prediction is ACCEPTED (participates in votes and valid seconds).
    ///
    /// A window abstains when the model itself says `unknown`, when its top probability is below
    /// `abstainMinMaxProb`, or when the top-2 margin is below `abstainMinMargin`.
    public static func isAccepted(_ window: ActivityWindowPrediction, config: ActivityPolicyConfig = .default) -> Bool {
        guard window.label != .unknown else { return false }
        // No probability evidence at all (malformed / missing probs) cannot be confirmed.
        guard !window.probs.isEmpty else { return false }
        if let maxProb = window.maxProb, maxProb < config.abstainMinMaxProb { return false }
        if let margin = window.top2Margin, margin < config.abstainMinMargin { return false }
        return true
    }

    // MARK: - Epoch building

    /// Folds window predictions into 30-s UTC epochs for one or more contiguous runs.
    ///
    /// - Parameters:
    ///   - windows: model windows (any order; sorted internally). Windows outside `[runStart, runEnd)`
    ///     or with `endTs <= startTs` are dropped.
    ///   - runStart/runEnd: the sample timeline of the run(s); coverage outside it is ignored.
    ///   - exerciseSessions/sleepSessions/postureAnnotations/wearIntervals: enrichment evidence.
    ///     All optional; absence never invents a label.
    public static func buildEpochs(windows: [ActivityWindowPrediction],
                                   runStart: Int,
                                   runEnd: Int,
                                   exerciseSessions: [ExerciseSession] = [],
                                   sleepSessions: [SleepSession] = [],
                                   postureAnnotations: [PostureAnnotation] = [],
                                   wearIntervals: [WearInterval] = [],
                                   config: ActivityPolicyConfig = .default) -> ActivityEpochBuild {
        let valid = windows
            .filter { $0.startTs >= runStart && $0.endTs <= runEnd && $0.endTs > $0.startTs }
            .sorted { $0.startTs < $1.startTs || ($0.startTs == $1.startTs && $0.endTs < $1.endTs) }
        guard !valid.isEmpty else { return ActivityEpochBuild(epochs: [], transitions: []) }

        // Split at data gaps so hysteresis history never bridges missing data.
        var segments: [[ActivityWindowPrediction]] = []
        var segment: [ActivityWindowPrediction] = []
        var lastEnd: Int? = nil
        for w in valid {
            if let end = lastEnd, w.startTs > end + config.gapResetSeconds {
                segments.append(segment); segment = []
            }
            segment.append(w)
            lastEnd = max(lastEnd ?? w.endTs, w.endTs)
        }
        segments.append(segment)

        // Causal smoothing with hysteresis, per segment.
        var smoothed: [(window: ActivityWindowPrediction, label: MotionLabel)] = []
        var transitions: [ActivityTransition] = []
        for seg in segments {
            var currentLabel: MotionLabel? = nil
            var disagreeCount = 0
            var firstDisagreeStart: Int? = nil
            for w in seg where isAccepted(w, config: config) {
                if let current = currentLabel {
                    if w.label == current {
                        disagreeCount = 0
                        firstDisagreeStart = nil
                    } else {
                        if disagreeCount == 0 { firstDisagreeStart = w.startTs }
                        disagreeCount += 1
                        if disagreeCount >= config.requiredConsecutiveVotes {
                            transitions.append(ActivityTransition(from: current, to: w.label,
                                                                  offset: firstDisagreeStart ?? w.startTs))
                            currentLabel = w.label
                            disagreeCount = 0
                            firstDisagreeStart = nil
                        }
                    }
                } else {
                    currentLabel = w.label
                    disagreeCount = 0
                    firstDisagreeStart = nil
                }
                smoothed.append((w, currentLabel!))
            }
        }

        // Group coverage into 30-s UTC buckets. Each window contributes every covered second to the
        // bucket that second falls in, so a window straddling an epoch boundary is split correctly
        // and no second is lost even when the next window is missing.
        let epochS = config.epochSeconds
        var buckets: [Int: BucketAccumulator] = [:]
        for (window, label) in smoothed {
            let maxProb = window.maxProb ?? 0
            for t in window.startTs..<window.endTs {
                let bucketStart = (t / epochS) * epochS
                let acc = buckets[bucketStart] ?? BucketAccumulator(startTs: bucketStart, endTs: bucketStart + epochS)
                acc.observed.insert(t)
                acc.valid.insert(t)
                // WS-05-F11: assign each real second exactly one label — that of the chronologically
                // latest accepted window covering it (windows are visited in sorted start order, so a
                // later visit overwrites an earlier one, matching the epoch tie-break rule). The 4-s /
                // 2-s-hop overlap therefore never double-counts a second in activeS/stillS.
                acc.secondLabels[t] = label
                acc.votes[label, default: 0] += 1
                acc.totalWeight += 1
                acc.confidenceWeight += maxProb
                // Tie-break: a label wins outright on strictly more seconds; on equal seconds the
                // chronologically later window's label wins (deterministic, causal).
                if acc.votes[label]! > acc.bestVotes {
                    acc.bestLabel = label
                    acc.bestVotes = acc.votes[label]!
                } else if acc.votes[label]! == acc.bestVotes, window.endTs >= acc.bestEndTs {
                    acc.bestLabel = label
                    acc.bestVotes = acc.votes[label]!
                    acc.bestEndTs = window.endTs
                }
                buckets[bucketStart] = acc
            }
        }
        // Abstaining windows still count toward observed coverage (never valid).
        for w in valid where !isAccepted(w, config: config) {
            for t in w.startTs..<w.endTs {
                let bucketStart = (t / epochS) * epochS
                let acc = buckets[bucketStart] ?? BucketAccumulator(startTs: bucketStart, endTs: bucketStart + epochS)
                acc.observed.insert(t)
                buckets[bucketStart] = acc
            }
        }

        var drafts: [EpochDraft] = []
        for key in buckets.keys.sorted() {
            let acc = buckets[key]!
            let observed = acc.observed.count
            let validCount = acc.valid.count
            let motion = validCount > 0 ? (acc.bestLabel ?? .unknown) : .unknown
            let confidence = acc.totalWeight > 0 ? acc.confidenceWeight / acc.totalWeight : 0
            let epoch = ActivityEpoch(startTs: acc.startTs, endTs: acc.endTs,
                                      motion: motion, posture: .unknown, exercise: .unknown,
                                      sleepState: .unknown, exertion: .unknown, wear: .unknown,
                                      confidence: confidence, observedS: observed, validS: validCount)
            // WS-05-F11: activeS/stillS count real seconds, one per second (deduplicated across
            // overlapping 4-s / 2-s-hop windows), consistent with validS. Each valid second is
            // assigned exactly one label, so activeS + stillS <= validS <= observedS always holds.
            var activeS = 0
            var stillS = 0
            for (_, label) in acc.secondLabels {
                switch label {
                case .walking, .running: activeS += 1
                case .stationary: stillS += 1
                default: break
                }
            }
            drafts.append(EpochDraft(epoch: epoch, activeS: activeS, stillS: stillS))
        }

        applyEnrichment(&drafts, exerciseSessions: exerciseSessions, sleepSessions: sleepSessions,
                        postureAnnotations: postureAnnotations, wearIntervals: wearIntervals)
        applyExertion(&drafts, config: config)
        return ActivityEpochBuild(epochs: drafts.map(\.epoch), transitions: transitions)
    }

    // MARK: - Enrichment (exercise / sleep / posture / wear)

    private static func applyEnrichment(_ drafts: inout [EpochDraft],
                                        exerciseSessions: [ExerciseSession],
                                        sleepSessions: [SleepSession],
                                        postureAnnotations: [PostureAnnotation],
                                        wearIntervals: [WearInterval]) {
        for i in drafts.indices {
            let e = drafts[i].epoch
            let exercise = exerciseSessions.contains { $0.start < e.endTs && $0.end > e.startTs }
                ? ExerciseState.true : .unknown
            let sleep = sleepState(for: e, sessions: sleepSessions)
            let posture = bestAnnotation(overlapping: e,
                                         in: postureAnnotations.map { ($0.start, $0.end, $0.posture) })
            let wear = bestAnnotation(overlapping: e,
                                      in: wearIntervals.map { ($0.start, $0.end, $0.wear) })
            drafts[i].epoch = ActivityEpoch(startTs: e.startTs, endTs: e.endTs, motion: e.motion,
                                            posture: posture ?? .unknown, exercise: exercise,
                                            sleepState: sleep, exertion: e.exertion,
                                            wear: wear ?? .unknown, confidence: e.confidence,
                                            observedS: e.observedS, validS: e.validS)
        }
    }

    /// Sleep state from existing sleep sessions + their wake segments.
    ///
    /// An epoch overlapping a session's `wake` stage segment is `awake`; otherwise overlapping a
    /// session's `[start, end)` is `asleep`; otherwise `unknown`. Stillness alone never sets sleep.
    public static func sleepState(for epoch: ActivityEpoch, sessions: [SleepSession]) -> SleepStateLabel {
        for s in sessions {
            for seg in s.stages where seg.stage == "wake" {
                if seg.start < epoch.endTs && seg.end > epoch.startTs { return .awake }
            }
        }
        for s in sessions where s.start < epoch.endTs && s.end > epoch.startTs { return .asleep }
        return .unknown
    }

    private static func bestAnnotation<T: Equatable>(overlapping epoch: ActivityEpoch,
                                                     in annotations: [(Int, Int, T)]) -> T? {
        var best: T? = nil
        var bestOverlap = 0
        for (aStart, aEnd, value) in annotations {
            let overlap = min(aEnd, epoch.endTs) - max(aStart, epoch.startTs)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = value
            }
        }
        return best
    }

    // MARK: - Exertion context

    private static func applyExertion(_ drafts: inout [EpochDraft], config: ActivityPolicyConfig) {
        var lastSupportedActivityEnd: Int? = nil
        var stillnessRunS = 0
        var lastEpochEnd: Int? = nil

        for i in drafts.indices {
            let e = drafts[i].epoch
            let activeS = drafts[i].activeS
            let stillS = drafts[i].stillS
            let contiguous = (lastEpochEnd != nil) && e.startTs == lastEpochEnd
            if !contiguous { stillnessRunS = 0 }
            let priorStillness = stillnessRunS
            let inPostWindow = lastSupportedActivityEnd.map { e.startTs < $0 + config.postActivityWindowS } ?? false

            var exertion: ExertionContext = .unknown
            // "Active" follows the epoch's OWN label (the smoothed majority) plus any confirmed
            // exercise session. A 4-s hysteresis residue of the previous label inside the first
            // epoch of a new run does NOT keep the epoch active: the mixed check below still uses
            // the raw composition (activeS/stillS) so a genuinely mixed epoch is recognized.
            let activePresent = e.motion == .walking || e.motion == .running || e.exercise == .true
            let stillPresent = stillS > 0
            let sustainedStillInside = priorStillness + stillS >= config.minStillnessS

            if activeS > 0 && stillPresent && activeS >= config.minMixedActiveS
                && stillS >= config.minMixedStillS && sustainedStillInside {
                exertion = .mixed
            } else if activePresent {
                exertion = .active
                if e.endTs > (lastSupportedActivityEnd ?? Int.min) { lastSupportedActivityEnd = e.endTs }
            } else if inPostWindow {
                exertion = .postActivity
            } else if e.motion == .stationary && priorStillness >= config.minStillnessS {
                exertion = .restingCandidate
            } else {
                exertion = .unknown
            }

            // Trailing stillness run: only stationary-labelled epochs with no supported-active
            // seconds extend it; unknown/other_movement/gaps break it (conservative).
            if e.motion == .stationary && activeS == 0 {
                stillnessRunS += stillS
            } else {
                stillnessRunS = 0
            }
            lastEpochEnd = e.endTs

            drafts[i].epoch = ActivityEpoch(startTs: e.startTs, endTs: e.endTs, motion: e.motion,
                                            posture: e.posture, exercise: e.exercise,
                                            sleepState: e.sleepState, exertion: exertion, wear: e.wear,
                                            confidence: e.confidence, observedS: e.observedS, validS: e.validS)
        }
    }

    // MARK: - Day-level helpers

    /// Day-level snapshot summary over a full epoch grid (C10 `summary`).
    public static func daySummary(epochs: [ActivityEpoch]) -> ActivitySnapshotSummary {
        var supported = 0
        var observed = 0
        var transitions = 0
        let sorted = epochs.sorted { $0.startTs < $1.startTs }
        var prev: ActivityEpoch? = nil
        for e in sorted {
            supported += e.validS
            observed += e.observedS
            if let p = prev, p.endTs == e.startTs, p.motion != e.motion { transitions += 1 }
            prev = e
        }
        let unknown = observed > 0 ? Double(observed - supported) / Double(observed) : 1.0
        return ActivitySnapshotSummary(supportedS: supported, unknownShare: unknown, transitions: transitions)
    }

    /// Snapshot availability status + reasons over the epoch grid (C10 `status`).
    ///
    /// No epochs (or zero observed seconds) is `no_data` — never `stationary`. `partial` when more
    /// than half the observed seconds abstained or nothing was accepted. `pending` is never derived
    /// here; the worker sets it while a job is queued/in flight.
    public static func snapshotStatus(epochs: [ActivityEpoch]) -> (ActivityStatus, [String]) {
        let summary = daySummary(epochs: epochs)
        let hasAnyCoverage = epochs.contains { $0.observedS > 0 }
        guard !epochs.isEmpty, hasAnyCoverage else { return (.noData, ["no_epochs"]) }
        var reasons: [String] = []
        if summary.unknownShare >= 0.5 { reasons.append("high_unknown_share") }
        if summary.supportedS == 0 { reasons.append("no_supported_seconds") }
        return (reasons.isEmpty ? .available : .partial, reasons)
    }

    /// Elapsed seconds of post-activity for an epoch: the gap between the epoch's start and the
    /// end of the most recent epoch marked `active` (spec §9 "with elapsed time ... retained").
    /// nil when the epoch is not `post_activity` or no active epoch precedes it.
    public static func postActivityElapsedS(for epoch: ActivityEpoch, epochs: [ActivityEpoch]) -> Int? {
        guard epoch.exertion == .postActivity else { return nil }
        var bestEnd: Int? = nil
        for e in epochs where e.endTs <= epoch.startTs && e.exertion == .active {
            if bestEnd == nil || e.endTs > bestEnd! { bestEnd = e.endTs }
        }
        guard let end = bestEnd else { return nil }
        return epoch.startTs - end
    }

    /// Coalesces consecutive equivalent epochs into runs (C3 payload limit), keeping gaps explicit.
    ///
    /// Two adjacent epochs merge when their motion/posture/exercise/sleep/exertion/wear are all
    /// equal. `observedS`/`validS` sum; `confidence` is observed-weighted. Non-adjacent epochs (a
    /// data gap) never merge, so gaps stay explicit. The snapshot summary is computed from the FULL
    /// grid before coalescing, so transitions are preserved.
    public static func coalescedEpochs(_ epochs: [ActivityEpoch]) -> [ActivityEpoch] {
        let sorted = epochs.sorted { $0.startTs < $1.startTs }
        var result: [ActivityEpoch] = []
        for e in sorted {
            guard let last = result.last, last.endTs == e.startTs,
                  last.motion == e.motion, last.posture == e.posture,
                  last.exercise == e.exercise, last.sleepState == e.sleepState,
                  last.exertion == e.exertion, last.wear == e.wear else {
                result.append(e)
                continue
            }
            let observed = last.observedS + e.observedS
            let confidence = observed > 0
                ? (last.confidence * Double(last.observedS) + e.confidence * Double(e.observedS)) / Double(observed)
                : 0
            result[result.count - 1] = ActivityEpoch(startTs: last.startTs, endTs: e.endTs,
                                                     motion: e.motion, posture: e.posture,
                                                     exercise: e.exercise, sleepState: e.sleepState,
                                                     exertion: e.exertion, wear: e.wear,
                                                     confidence: confidence, observedS: observed,
                                                     validS: last.validS + e.validS)
        }
        return result
    }
}

// MARK: - Bucket accumulator / draft

private final class BucketAccumulator {
    let startTs: Int
    let endTs: Int
    var observed: Set<Int> = []
    var valid: Set<Int> = []
    var votes: [MotionLabel: Double] = [:]
    /// Per-second label assignment used for second-accurate activeS/stillS (WS-05-F11).
    /// Each valid second appears exactly once with the label of the latest covering window.
    var secondLabels: [Int: MotionLabel] = [:]
    var totalWeight: Double = 0
    var confidenceWeight: Double = 0
    var bestLabel: MotionLabel? = nil
    var bestVotes: Double = 0
    var bestEndTs: Int = -1

    init(startTs: Int, endTs: Int) {
        self.startTs = startTs
        self.endTs = endTs
    }
}

private struct EpochDraft {
    var epoch: ActivityEpoch
    /// Supported-active seconds (smoothed walking/running) inside the epoch.
    let activeS: Int
    /// Stationary seconds (smoothed) inside the epoch.
    let stillS: Int
}
