import Foundation

// ActivityContextCorrections.swift — the wearer's corrections, applied to the activity context at read time.
//
// A `StretchFeedback` with verdict `incorrect` and a corrected label is the wearer saying "from start to end I
// was actually X" (D9-07). Until now those answers were stored and synced but no consumer saw them: the coach,
// the HRV windows and every phone reader kept the decoder's wrong label. This file is the overlay that fixes
// that, as a pure function from (decoder intervals, corrections) to the intervals a consumer should see.
//
// RULES.
//   - The decoder's rows are never rewritten. The overlay is applied when the context is READ, so a re-derived
//     day, a new decoder version or a deleted answer all take effect at once, and the store keeps what the model
//     actually said (the labels the corrections are meant to tune it against).
//   - Intervals are split at a correction's bounds; only the seconds the wearer answered for change.
//   - Where two corrections overlap, the more recently answered one wins (`updatedAt`, then input order).
//   - A correction only asserts what it names. `notWearing` makes the seconds off-wrist (`wear == .offWrist`,
//     class `offWrist`) and clears their physiology, so nothing measured then can enter a baseline. A class
//     correction (`StretchCorrection.activityClass`: asleep, lying down, sitting, standing, walking, …) sets that
//     class, the heads `StretchCorrection.partialHeads` names (nil where the wearer said nothing), the sleep state
//     the answer implies (asleep for `asleep`, awake otherwise) and on-wrist wear. A correction with no
//     one-to-one class (stairs, vehicle, typing, exercise, moving about, other) changes nothing: its partial
//     heads alone would put a label beside a class the wearer did not confirm.
//   - Every overridden piece has confidence 1 and `provenance == ActivityContextProvenance.userCorrection`.
//
// PHYSIOLOGY ON A SPLIT ROW. An interval's statistics are measured over the whole decoder row; the raw samples
// are not available here. A split piece keeps the row's intensive values (mean / min / max HR, slope, RMSSD,
// respiratory rate, cadence) and a time-proportional share of its additive components (beats, HR samples, steps,
// the RMSSD sums, breaths, transition count, absorbed seconds), apportioned so the pieces always sum back to the
// row. A rollup over the pieces (`ActivityContextAggregator`) therefore reads exactly what it read over the row,
// and nothing is ever counted twice. Per-sample joins through the store's `*Ctx` views do not see the overlay.

/// Where an interval's label came from, when it was not the decoder.
public enum ActivityContextProvenance {
    /// The wearer's own correction (`StretchFeedback`) overrode the decoder over these seconds.
    public static let userCorrection = "user_correction"
}

/// One user-asserted span: "over `[start, end)` I was actually `correction`".
public struct ActivityContextCorrection: Equatable, Sendable {
    /// Unix seconds, inclusive.
    public var start: Int
    /// Unix seconds, exclusive.
    public var end: Int
    public var correction: StretchCorrection
    /// When the wearer gave the answer; the later of two overlapping corrections wins.
    public var answeredAt: Date

    public init(start: Int, end: Int, correction: StretchCorrection, answeredAt: Date = .distantPast) {
        self.start = start; self.end = end; self.correction = correction; self.answeredAt = answeredAt
    }

    /// The correction a stored verdict asserts, or nil when it asserts none the overlay applies: a `correct`
    /// verdict, a wrong verdict without a corrected label, an empty span, or a label with no one-to-one class.
    public init?(feedback f: StretchFeedback) {
        guard f.verdict == .incorrect, let label = f.correctedLabel, f.endTs > f.startTs,
              ActivityContextCorrections.applies(label) else { return nil }
        self.init(start: f.startTs, end: f.endTs, correction: label, answeredAt: f.updatedAt)
    }
}

public enum ActivityContextCorrections {

    /// Whether the overlay applies `correction` at all (see the file header).
    public static func applies(_ correction: StretchCorrection) -> Bool {
        correction == .notWearing || correction.activityClass != nil
    }

    /// The corrections a set of stored verdicts asserts, in the order given.
    public static func corrections(from feedback: [StretchFeedback]) -> [ActivityContextCorrection] {
        feedback.compactMap(ActivityContextCorrection.init(feedback:))
    }

    /// `intervals` as a consumer should see them once the wearer's verdicts are applied.
    public static func applying(_ feedback: [StretchFeedback], to intervals: [ActivityContextInterval])
        -> [ActivityContextInterval] {
        apply(corrections(from: feedback), to: intervals)
    }

    /// `intervals` (time-ordered on return) with `corrections` laid over them. With no applicable correction the
    /// input comes back unchanged.
    public static func apply(_ corrections: [ActivityContextCorrection],
                             to intervals: [ActivityContextInterval]) -> [ActivityContextInterval] {
        let segments = resolve(corrections.filter { $0.end > $0.start && applies($0.correction) })
        let sorted = intervals.sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return sorted }
        var out: [ActivityContextInterval] = []
        out.reserveCapacity(sorted.count)
        for iv in sorted {
            let touching = segments.filter { $0.end > iv.start && $0.start < iv.end }
            guard !touching.isEmpty else { out.append(iv); continue }
            // Cut points: the row's own bounds and every correction bound inside it.
            var cuts = Set([iv.start, iv.end])
            for s in touching {
                if s.start > iv.start { cuts.insert(s.start) }
                if s.end < iv.end { cuts.insert(s.end) }
            }
            let bounds = cuts.sorted()
            var pieces: [ActivityContextInterval] = []
            for k in 0..<(bounds.count - 1) {
                let a = bounds[k], b = bounds[k + 1]
                var piece = bounds.count == 2 ? iv : portion(of: iv, from: a, to: b)
                if let s = touching.first(where: { $0.start <= a && b <= $0.end }) {
                    override(&piece, with: s.correction)
                }
                pieces.append(piece)
            }
            out.append(contentsOf: pieces)
        }
        return out
    }

    // MARK: Precedence

    /// Disjoint, time-ordered spans, each carrying the correction that wins there (latest answer, then the later
    /// one in input order).
    static func resolve(_ corrections: [ActivityContextCorrection]) -> [(start: Int, end: Int, correction: StretchCorrection)] {
        guard !corrections.isEmpty else { return [] }
        let ranked = corrections.enumerated().sorted {
            ($0.element.answeredAt, $0.offset) < ($1.element.answeredAt, $1.offset)
        }.map(\.element)
        let bounds = Set(corrections.flatMap { [$0.start, $0.end] }).sorted()
        var out: [(start: Int, end: Int, correction: StretchCorrection)] = []
        for k in 0..<(bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            guard let winner = ranked.last(where: { $0.start <= a && b <= $0.end }) else { continue }
            if let last = out.last, last.end == a, last.correction == winner.correction {
                out[out.count - 1].end = b
            } else {
                out.append((a, b, winner.correction))
            }
        }
        return out
    }

    // MARK: Pieces

    /// The seconds `[from, to)` of `iv`: its intensive statistics, and a share of its additive components such
    /// that the shares of all pieces of one row sum back to the row's own values.
    static func portion(of iv: ActivityContextInterval, from: Int, to: Int) -> ActivityContextInterval {
        let duration = max(1, iv.end - iv.start)
        let lo = from - iv.start, hi = to - iv.start
        /// Cumulative rounding: Σ share(v) over consecutive pieces == v exactly.
        func share(_ v: Int) -> Int {
            Int((Double(v) * Double(hi) / Double(duration)).rounded())
                - Int((Double(v) * Double(lo) / Double(duration)).rounded())
        }
        var p = iv
        p.start = from; p.end = to
        p.stepTicks = share(iv.stepTicks)
        p.hrSamples = share(iv.hrSamples)
        p.rrBeats = share(iv.rrBeats)
        p.rrDiffCount = share(iv.rrDiffCount)
        p.rrDiffSqSumMs2 = iv.rrDiffSqSumMs2 * Double(to - from) / Double(duration)
        p.respBreaths = share(iv.respBreaths)
        p.transitionCount = iv.transitionCount.map(share)
        p.absorbedSeconds = iv.absorbedSeconds.map(share)
        // Settling seconds are the row's first seconds; the gap before the row belongs to its first piece.
        p.settlingSeconds = iv.settlingSeconds.map { max(0, min($0, hi) - max(0, lo)) }
        if from > iv.start { p.precededByGapS = 0 }
        return p
    }

    /// Replace the decoder's reading of `piece` with what the wearer said.
    static func override(_ piece: inout ActivityContextInterval, with correction: StretchCorrection) {
        piece.confidence = 1
        piece.runnerUp = nil
        piece.runnerUpConfidence = 0
        piece.uncertainty = 0
        piece.provenance = ActivityContextProvenance.userCorrection
        if correction == .notWearing {
            piece.activityClass = .offWrist
            piece.wear = .offWrist
            piece.posture = nil; piece.locomotion = nil; piece.armBehavior = nil
            // Nothing measured off the wrist is physiology.
            piece.hrSamples = 0; piece.hrMean = nil; piece.hrMin = nil; piece.hrMax = nil; piece.hrSlope = nil
            piece.rmssd = nil; piece.rrBeats = 0; piece.rrDiffSqSumMs2 = 0; piece.rrDiffCount = 0
            piece.respRateBpm = nil; piece.respBreaths = 0
            piece.cadenceSpm = nil; piece.gait = nil
            return
        }
        guard let cls = correction.activityClass else { return }
        piece.activityClass = cls
        let heads = StretchCorrection.partialHeads(for: correction)
        piece.posture = heads.posture.flatMap(PostureClass.init(rawValue:))
        piece.locomotion = heads.locomotion.flatMap(LocomotionClass.init(rawValue:))
        piece.armBehavior = heads.armBehavior.flatMap(ArmBehaviorClass.init(rawValue:))
        piece.sleep = cls == .sleeping ? .asleep : .awake
        piece.wear = .onWrist
    }
}
