import Foundation
import WhoopProtocol

// ActivityContextRetrospective.swift — retrospective (fixed-interval) smoothing of a FINAL day's runs (D8-10).
//
// WHY. The decoder is a causal forward filter: a second's state uses evidence up to that second only. Live, that
// is the only honest answer. For a finished day it leaves artefacts that later evidence of the same day resolves:
// one physically constant stillness after a walk is published "Standing (likely)" (the posture head has seen
// nothing yet), then "Still, sitting or standing", then "Sitting quietly" once the arm pattern speaks, so the
// stored day splits one situation into three intervals with three classes, and next-day analysis joins an HRV
// window at t+90 s to "standing" and one at t+300 s to "sitting" for the same bout of stillness. Offline wrist
// pipelines smooth over the whole sequence for exactly this (Willetts 2018 and Ellis 2016: HMM / Viterbi over
// per-epoch outputs; HSMMs are normally decoded forward-backward, Yu 2010).
//
// POLICY (ctx-retro-2). Never force sitting vs standing beyond the evidence. ctx-retro-1 wrote the smoothed
// posture head back into the runs and re-classified them; measured on the D7 replays that spread a posture into
// stretches the causal decoder had deliberately left `stationary` (Capture-24 wrong posture claims on still truth
// 1,760 -> 8,717 s, standing claims at precision 0.08, FORTH sitting precision 1.0 -> 0.73). The pass is now
// restricted, and the restriction is enforced on the output, not only intended:
//   1. it may DEMOTE a causal posture claim (sitting, desk sitting, standing, lying down) to `stationary` when the
//      smoothed posterior contradicts it;
//   2. rows that then share class, sleep and wear merge in the ordinary interval build, so a contradicted
//      "Standing (likely)" right after a walk becomes still-unresolved and joins the stillness after it;
//   3. it may move a walk / run stop boundary back to the stop's flagged onset (at most `stopOnsetMaxLeadS`),
//      only when the row it extends makes no posture claim;
//   4. short fragments are kept exactly as the causal build keeps them (as events, `absorbedClasses`).
// It never adds a posture claim for a second the causal build did not claim with the same posture, and never
// raises a confidence: `guarded` demotes any row that would, and caps every row's confidence at the lowest causal
// confidence over its seconds. Property tests pin both.
//
// MODEL (used only to decide demotions). The decoder exposes its filtered output per run (the run's mean head
// probabilities), not per-second likelihoods, so the posterior is a forward-backward over the runs of each still
// segment with:
//   - hidden state: the physical posture {recumbent, seated, upright}. The head's `unknown` mass is absence of
//     evidence, not a fourth posture, and `postural_transition` is the movement itself; neither is a state;
//   - emission: the run's posture head renormalised over the three postures, tempered by how much of it was
//     resolved and by its duration (at least one minute's weight, capped: the decoder's posture memory is bounded);
//   - transitions: a posture persists unless something changes it. Between runs with no supported change the
//     switch probability is `1 - exp(-d / unevidencedPostureDwellS)`; at a boundary a flagged change of position
//     explains, the transition is uniform: nothing carries across it (so a flagged short stand keeps its reading).
// A run's claim is contradicted when the smoothed mass of its own posture is below `demoteBelow` and another
// posture leads.
//
// RULES.
//   - Finalised days only (`ActivityContextPersistence.retrospectiveIntervals` returns nothing otherwise).
//   - Output is stamped `derivation = .retrospective` and stored apart from the causal rows; a causal consumer
//     (live decisions, causal / as-of baselines) never reads it (`ActivityContextIntervalReading.causal`).
//   - Deterministic: same runs and events in, identical intervals out.
//   - Every stored day names the smoother that wrote its rows (`ActivityContextDayRow.retrospectiveVersion`).

public enum ActivityContextRetrospective {

    /// The smoother's semantics. Bumped whenever the retrospective rows it writes would change meaning, so stored
    /// days stay attributable to the version that made them.
    public static let version = "ctx-retro-2"

    public struct Config: Equatable, Sendable {
        /// Mean seconds a still posture lasts with no flagged change of position (the per-second switch hazard is
        /// its inverse). Long: an unflagged change is rare, and a real one leaves the evidence that flags it.
        public var unevidencedPostureDwellS = 3_600.0
        /// A postural event at or above this probability supports a change (the display / settling threshold).
        public var eventMinProbability = PositionChanges.minimumProbability
        /// Seconds an event's `[onset, detection]` span may lie from a run boundary and still explain it.
        public var eventToleranceS = 5
        /// Seconds of a run that count as posture evidence, and the evidence weight per minute of them.
        public var evidenceCapS = 120.0
        public var evidencePerMinute = 1.0
        /// Floor on a posture's probability inside the emission (no run can veto a posture outright).
        public var emissionFloor = 0.02
        /// Largest gap between two runs that still continues one still segment.
        public var mergeGapS = 10
        /// How far a walk / run stop's onset may lie before the drawn boundary and still move it: the decoder's own
        /// longest onset back-date (ctx-retro-2; 30 s in ctx-retro-1 cut walks into sub-10 s rows on Capture-24).
        public var stopOnsetMaxLeadS = ActivityTransitionEvent.maxOnsetLeadS
        /// The walk / run row must keep at least this many seconds after the move (never a new short fragment).
        public var minGaitRowAfterMoveS = 10
        /// A causal posture claim is demoted when the smoothed mass of its own posture is below this and another
        /// posture leads.
        public var demoteBelow = 0.5
        /// The interval build: the causal build's own config (both builds must use the same one, so the guard
        /// compares like with like).
        public var builder = ActivityContextIntervalBuilder.Config()
        public init() {}
    }

    static let postures: [PostureClass] = [.recumbent, .seatedLikely, .uprightStationary]

    // MARK: - Intervals

    /// Retrospective intervals of a finished day: the causal build, then `smooth` (demotions and stop boundaries),
    /// the same interval build over the smoothed runs, and `guarded` against the causal build. Stamped
    /// `.retrospective`. The caller decides that the day is final.
    public static func intervals(runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                                 hr: [HRSample] = [], steps: [StepSample] = [], rr: [RRInterval] = [],
                                 config: Config = Config()) -> [ActivityContextInterval] {
        let causal = ActivityContextIntervalBuilder.build(runs: runs, events: events, hr: hr, steps: steps, rr: rr,
                                                          config: config.builder)
        let smoothed = smooth(runs: runs, events: events, config: config)
        let built = ActivityContextIntervalBuilder.build(runs: smoothed, events: events, hr: hr, steps: steps, rr: rr,
                                                         config: config.builder)
        return guarded(built, causal: causal).map { var iv = $0; iv.derivation = .retrospective; return iv }
    }

    /// The posture a class claims (nil: no posture claim). Desk sitting and sitting are one posture.
    static func claimedPosture(_ c: ActivityClass) -> PostureClass? {
        switch c {
        case .sitting, .sittingDesk: return .seatedLikely
        case .standing: return .uprightStationary
        case .lyingDown: return .recumbent
        default: return nil
        }
    }

    /// Enforce the policy on `rows` against the causal build: a row claiming a posture for any second the causal
    /// build did not claim with that posture is demoted to `stationary`, and every row's confidence is capped at the
    /// lowest causal confidence over the seconds it shares with the causal rows.
    static func guarded(_ rows: [ActivityContextInterval],
                        causal: [ActivityContextInterval]) -> [ActivityContextInterval] {
        let lookup = ActivityContextLookup(intervals: causal)
        return rows.map { iv in
            var out = iv
            let overlapping = lookup.intervals(from: iv.start, to: iv.end)
            if let p = claimedPosture(iv.activityClass) {
                let covered = overlapping.reduce(0) { acc, c in
                    claimedPosture(c.activityClass) == p ? acc + (min(c.end, iv.end) - max(c.start, iv.start)) : acc
                }
                if covered < iv.end - iv.start {
                    out.runnerUp = iv.activityClass
                    out.runnerUpConfidence = 0
                    out.activityClass = .stationary
                    out.posture = nil
                }
            }
            if let lowest = overlapping.map(\.confidence).min() { out.confidence = min(out.confidence, lowest) }
            out.runnerUpConfidence = min(out.runnerUpConfidence, out.confidence)
            return out
        }
    }

    // MARK: - Smoothing

    /// The runs with contradicted posture claims demoted (their posture head made unresolved, so they classify
    /// `stationary`) and stop boundaries moved back to their flagged onsets where the row extended claims no
    /// posture. Nothing else changes: a posture head is never sharpened or moved toward another posture.
    public static func smooth(runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                              config: Config = Config()) -> [ActivityContextRun] {
        var rs = runs.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
            .filter { $0.end > $0.start }
        guard !rs.isEmpty else { return [] }
        let still = rs.map(isStill)
        let posturalSpans: [(Int, Int)] = events
            .filter { $0.isPostural && $0.probability >= config.eventMinProbability }
            .map { (min($0.onsetTs ?? $0.ts, $0.ts), $0.ts) }
            .sorted { $0 < $1 }
        // Smoothed posterior per run (nil outside a still segment of two or more runs: nothing to compare with).
        var gamma = [[Double]?](repeating: nil, count: rs.count)
        var i = 0
        while i < rs.count {
            guard still[i] else { i += 1; continue }
            var j = i
            while j + 1 < rs.count, still[j + 1], continues(rs[j], rs[j + 1], config: config) { j += 1 }
            if j > i {
                for (a, g) in posterior(rs, i...j, spans: posturalSpans, config: config).enumerated() { gamma[i + a] = g }
            }
            i = j + 1
        }
        // Demotion is decided per causal row (the stretch the causal build drew), never per run inside it, so a
        // demotion can only turn a whole row into still-unresolved: it never cuts a row into more rows.
        let causal = ActivityContextIntervalBuilder.build(runs: rs, events: events, config: config.builder)
        var demote = [Bool](repeating: false, count: rs.count)
        var r0 = 0
        for iv in causal {
            guard iv.inBed != true, let p = claimedPosture(iv.activityClass),
                  let s = postures.firstIndex(of: p) else { continue }
            while r0 < rs.count, rs[r0].end <= iv.start { r0 += 1 }
            var mass = [Double](repeating: 0, count: postures.count)
            var seconds = 0.0
            var members: [Int] = []
            var r = r0
            while r < rs.count, rs[r].start < iv.end {
                let o = Double(min(rs[r].end, iv.end) - max(rs[r].start, iv.start))
                if o > 0 {
                    members.append(r)
                    if let g = gamma[r] { for k in mass.indices { mass[k] += g[k] * o }; seconds += o }
                }
                r += 1
            }
            guard seconds > 0 else { continue }
            let mean = mass.map { $0 / seconds }
            let leader = mean.enumerated().max { $0.element < $1.element }!.offset
            if mean[s] < config.demoteBelow && leader != s { for m in members { demote[m] = true } }
        }
        for r in rs.indices where demote[r] {
            // Only the posture head: a still run's claim becomes unresolved; a movement fragment the row absorbed
            // keeps its own reading.
            guard isStill(rs[r]) else { continue }
            let t = min(1, max(0, rs[r].posture[.posturalTransition]))
            rs[r].posture = quantizedHead([.unknown: 1 - t, .posturalTransition: t])
        }
        alignStops(&rs, events: events, config: config)
        return rs
    }

    /// A still run: awake (not staged asleep), on the wrist, not a vehicle, class in the still family or lying awake.
    static func isStill(_ r: ActivityContextRun) -> Bool {
        guard r.wear == .onWrist, r.sleep != .asleep else { return false }
        let k = ActivityClassifier.classify(run: r)
        guard k.detail != .inVehicle else { return false }
        return k.activityClass.isStationaryAwake || k.activityClass == .lyingDown
    }

    /// Two runs continue one still segment: close, same wear / sleep / in-bed, and not a lying claim next to an
    /// upright (sitting / standing) one. The forearm axis separates lying from upright far better than sitting from
    /// standing, so such a change is treated as evidenced and never smoothed across (a lie-down is not relabelled
    /// by the sitting around it).
    static func continues(_ a: ActivityContextRun, _ b: ActivityContextRun, config: Config) -> Bool {
        guard b.start - a.end <= config.mergeGapS, a.wear == b.wear, a.sleep == b.sleep, a.inBed == b.inBed else {
            return false
        }
        let pa = claimedPosture(ActivityClassifier.classify(run: a).activityClass)
        let pb = claimedPosture(ActivityClassifier.classify(run: b).activityClass)
        if let pa, let pb, (pa == .recumbent) != (pb == .recumbent) { return false }
        return true
    }

    /// Whether a flagged change of position explains the boundary at `ts`.
    static func supported(_ ts: Int, spans: [(Int, Int)], toleranceS: Int) -> Bool {
        let lo = ts - max(0, toleranceS), hi = ts + max(0, toleranceS)
        return spans.contains { $0.0 <= hi && $0.1 >= lo }
    }

    /// The smoothed posture posterior of each run of a still segment, over `postures`.
    static func posterior(_ rs: [ActivityContextRun], _ range: ClosedRange<Int>, spans: [(Int, Int)],
                          config: Config) -> [[Double]] {
        let idx = Array(range)
        let n = idx.count
        let k = postures.count
        // Emissions (log) and the unresolved / transition masses.
        var logE = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        var seconds = [Double](repeating: 0, count: n)
        for (a, r) in idx.enumerated() {
            let head = rs[r].posture
            let phys = postures.map { max(0, head[$0]) }
            let resolved = phys.reduce(0, +)
            seconds[a] = Double(rs[r].end - rs[r].start)
            guard resolved > 1e-9 else { continue }
            // At least one run's worth (the run's head is already the decoder's posterior over its seconds, so a
            // block of one run keeps its own reading), up to the capped duration for longer runs.
            let minutes = min(max(seconds[a], 60), max(60, config.evidenceCapS)) / 60
            let weight = min(1, resolved) * minutes * config.evidencePerMinute
            for s in 0..<k {
                logE[a][s] = weight * log(max(config.emissionFloor, phys[s] / resolved))
            }
        }
        // Boundary a -> a+1: supported (uniform) or a small duration-scaled switch probability.
        var stay = [Double](repeating: 1, count: max(0, n - 1))
        for a in 0..<max(0, n - 1) {
            let boundary = rs[idx[a + 1]].start
            if supported(boundary, spans: spans, toleranceS: config.eventToleranceS) {
                stay[a] = 1.0 / Double(k)
            } else {
                stay[a] = exp(-seconds[a] / max(1, config.unevidencedPostureDwellS))
            }
        }
        func step(_ v: [Double], stay p: Double) -> [Double] {
            // A = p I + (1 - p)/(k - 1) (J - I); symmetric, so forward and backward use the same product.
            let total = v.reduce(0, +)
            let off = (1 - p) / Double(k - 1)
            return v.map { p * $0 + off * (total - $0) }
        }
        func normalized(_ v: [Double]) -> [Double] {
            let t = v.reduce(0, +)
            return t > 0 && t.isFinite ? v.map { $0 / t } : [Double](repeating: 1 / Double(k), count: k)
        }
        func emission(_ a: Int) -> [Double] {
            let m = logE[a].max() ?? 0
            return logE[a].map { exp($0 - m) }
        }
        var alpha = [[Double]](repeating: [], count: n)
        alpha[0] = normalized(emission(0))
        for a in 1..<n {
            let e = emission(a)
            alpha[a] = normalized(zip(step(alpha[a - 1], stay: stay[a - 1]), e).map { $0 * $1 })
        }
        var beta = [Double](repeating: 1 / Double(k), count: k)
        var gamma = [[Double]](repeating: [], count: n)
        gamma[n - 1] = normalized(alpha[n - 1])
        if n >= 2 {
            for a in stride(from: n - 2, through: 0, by: -1) {
                let e = emission(a + 1)
                beta = normalized(step(zip(e, beta).map { $0 * $1 }, stay: stay[a]))
                gamma[a] = normalized(zip(alpha[a], beta).map { $0 * $1 })
            }
        }
        return gamma
    }

    /// Probabilities to 0.001 with entries under the report floor dropped, as a stored run holds them, so the
    /// smoothed runs and everything built from them are identical in memory and read back.
    static func quantizedHead(_ values: [PostureClass: Double]) -> HeadProbabilities<PostureClass> {
        var m: [PostureClass: Double] = [:]
        for c in PostureClass.allCases {
            let p = values[c] ?? 0
            if p >= HeadProbabilities<PostureClass>.reportFloor { m[c] = (p * 1000).rounded() / 1000 }
        }
        return HeadProbabilities(m)
    }

    /// Move a gait-to-still boundary back (at most `stopOnsetMaxLeadS`) to the onset of the walk / run stop the
    /// decoder flagged for it, when the still row claims no posture.
    static func alignStops(_ rs: inout [ActivityContextRun], events: [ActivityTransitionEvent], config: Config) {
        let stops = events.filter { $0.kind == .walkStop || $0.kind == .runStop }
            .map { (onset: min($0.onsetTs ?? $0.ts, $0.ts), ts: $0.ts) }
            .sorted { ($0.onset, $0.ts) < ($1.onset, $1.ts) }
        guard !stops.isEmpty, rs.count >= 2 else { return }
        for i in 0..<(rs.count - 1) {
            let a = rs[i], b = rs[i + 1]
            // Only a row that claims no posture may grow into the walk's tail (never a new posture claim).
            guard a.end == b.start, ActivityClassifier.classify(run: a).activityClass.isGait, isStill(b),
                  claimedPosture(ActivityClassifier.classify(run: b).activityClass) == nil else { continue }
            let boundary = b.start
            // The stop that explains this boundary: detected at or after the boundary's lead window, onset before it.
            guard let stop = stops.first(where: {
                $0.onset < boundary && $0.onset >= boundary - config.stopOnsetMaxLeadS
                    && $0.ts <= boundary + config.stopOnsetMaxLeadS
            }), stop.onset - a.start >= max(1, config.minGaitRowAfterMoveS) else { continue }
            rs[i].end = stop.onset
            rs[i + 1].start = stop.onset
        }
    }
}

// MARK: - Derivation choice for in-memory readers

extension ActivityContextRetrospective {

    /// Who is reading: live / causal consumers (decisions, causal and as-of baselines) or historical display and
    /// next-day analysis.
    public enum Reader: Sendable {
        case causal
        case historical
    }

    /// The intervals a reader of `days` should use, deterministically: a causal reader gets the causal intervals,
    /// always; a historical reader gets, for each final day with retrospective intervals, those, and the causal
    /// intervals for every other second. `finalDays` are the `[start, end)` ranges of days that are final and were
    /// smoothed. A day is served wholly by one derivation; the result is sorted by start.
    public static func select(causal: [ActivityContextInterval], retrospective: [ActivityContextInterval],
                              finalDays: [Range<Int>], for reader: Reader) -> [ActivityContextInterval] {
        let live = causal.filter { $0.derivation == .causal }
        guard reader == .historical else { return live.sorted { $0.start < $1.start } }
        let smoothed = retrospective.filter { $0.derivation == .retrospective }
        let served = finalDays.filter { day in smoothed.contains { day.contains($0.start) } }
        func retro(_ ts: Int) -> Bool { served.contains { $0.contains(ts) } }
        return (live.filter { !retro($0.start) } + smoothed.filter { retro($0.start) })
            .sorted { ($0.start, $0.derivation.rawValue) < ($1.start, $1.derivation.rawValue) }
    }
}
