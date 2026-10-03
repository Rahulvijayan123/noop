import Foundation
import WhoopProtocol

/// Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
/// total (`AnalyticsEngine.analyzeDay`) and any windowed total (a manual workout's `[start, end]`, #398).
///
/// `step_motion_counter@57` is a CUMULATIVE u16 motion counter: it climbs for both locomotion and some
/// non-step wrist motion, and wraps at 65536. On classed WHOOP 5/MG records, the increment ending at each
/// sample is counted only when the strap labels that sample walk (1) or run (2); still (0) and unknown are
/// rejected, apart from a bout block (below). A wholly unclassed legacy window retains the old counter-only
/// estimate so pre-migration history remains readable. The caller applies its per-user `stepTicksPerStep`
/// calibration afterwards. The result is still an estimate, not cloud/clinical parity.
///
/// Bout blocks. The strap behaves as if it holds back the first steps of a walking bout, then credits about
/// six of them in a single record (+6 or +7, rarely a few more) and publishes the rest at 1-4 ticks a
/// second. A block of exactly six is always labelled still; the label turns walk only once the count passes
/// six. Neither the class gate nor the per-second rate gate may reject it, so an increment of
/// `minBoutBlockTicks...maxBoutBlockTicks` across at most `maxBoutBlockSeconds` is counted whatever its
/// label. The rule looks only at the two adjacent samples, so any partition of a day into windows (the
/// per-minute series) still sums to the day total. Evidence: docs/CURRENT_ALGORITHMS.md, "Bout blocks".
///
/// Kept byte-for-byte in lockstep with the Kotlin twin `StepsCounter.stepsInWindow`.
public enum StepsCounter {
    private static let locomotionActivityClasses: Set<Int> = [1, 2]

    static func hasActivityClasses(_ samples: [StepSample]) -> Bool {
        samples.contains { $0.activityClass != nil }
    }

    /// A bout block keeps its own label (still for exactly six) out of the decision, but a record with no
    /// label at all stays unknown and is rejected on a classed day like any other increment.
    ///
    /// Kotlin twin: `StepsCounter.shouldCountDelta`.
    static func shouldCountDelta(activityClass: Int?, hasActivityClasses: Bool, isBoutBlock: Bool) -> Bool {
        !hasActivityClasses
            || activityClass.map(locomotionActivityClasses.contains) == true
            || (isBoutBlock && activityClass != nil)
    }

    /// Absolute reboot/wrap guard, independent from the per-second plausibility gate below.
    public static let maxStepDelta = 512
    public static let maxTicksPerSecond = 4

    /// Size and spacing of the strap's one-shot credit for the start of a walking bout.
    public static let minBoutBlockTicks = 6
    public static let maxBoutBlockTicks = 20
    public static let maxBoutBlockSeconds = 2

    /// Kotlin twin: `StepsCounter.isBoutBlock`.
    static func isBoutBlock(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        let elapsed = currentTs - previousTs
        return elapsed >= 1 && elapsed <= maxBoutBlockSeconds
            && delta >= minBoutBlockTicks && delta <= maxBoutBlockTicks
    }

    /// Kotlin twin: `StepsCounter.isPlausibleDelta`.
    static func isPlausibleDelta(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        guard delta >= 1, delta < maxStepDelta else { return false }
        let elapsed = currentTs - previousTs
        guard elapsed > 0 else { return false }
        if isBoutBlock(previousTs: previousTs, currentTs: currentTs, delta: delta) { return true }
        let rateAllowance = elapsed >= maxStepDelta / maxTicksPerSecond
            ? maxStepDelta - 1
            : elapsed * maxTicksPerSecond
        return delta <= rateAllowance
    }

    /// Raw wrap-aware locomotion-tick total across `samples`. When any sample carries `activityClass`, each
    /// positive increment is attributed to the later sample and retained only for walk/run, or for a bout
    /// block whatever its label. When the whole window is legacy-unclassed, all valid increments retain the
    /// historical counter-only fallback. Sorts by `ts` internally and returns `nil` for fewer than two
    /// samples or no retained movement.
    public static func stepsInWindow(_ samples: [StepSample]) -> Int? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        if sorted.count < 2 { return nil }
        let hasActivityClasses = hasActivityClasses(sorted)
        var total = 0
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
            let block = isBoutBlock(previousTs: sorted[i - 1].ts, currentTs: sorted[i].ts, delta: delta)
            let isLocomotion = shouldCountDelta(
                activityClass: sorted[i].activityClass,
                hasActivityClasses: hasActivityClasses,
                isBoutBlock: block)
            if isLocomotion && isPlausibleDelta(
                previousTs: sorted[i - 1].ts, currentTs: sorted[i].ts, delta: delta) {
                total += delta
            }
        }
        return total > 0 ? total : nil
    }
}
