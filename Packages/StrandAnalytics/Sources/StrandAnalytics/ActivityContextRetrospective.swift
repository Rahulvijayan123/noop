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
// WHAT IS SMOOTHED. Only the posture head of still runs (sitting, standing, still and unresolved, fidgeting,
// lying awake). Locomotion, arm behaviour, sleep, wear, in-bed and every event are the decoder's, unchanged: the
// smoother never invents movement or a change of position, and never removes one.
//
// MODEL. The decoder exposes its filtered output per run (the run's mean head probabilities), not per-second
// likelihoods, so the pass is a forward-backward over the runs of each still segment with:
//   - hidden state: the physical posture {recumbent, seated, upright}. The head's `unknown` mass is absence of
//     evidence, not a fourth posture, and `postural_transition` is the movement itself; neither is a state;
//   - emission: the run's posture head renormalised over the three postures, tempered by how much of it was
//     resolved and by its duration (at least one minute's weight, so a lone run keeps its own reading; capped,
//     because the decoder's posture memory is bounded and a 15-minute run is not 15 minutes of independent
//     evidence);
//   - transitions: a posture persists unless something changes it. Between runs with no supported change the
//     switch probability is `1 - exp(-d / unevidencedPostureDwellS)` over the run's duration d (small); at a
//     boundary a flagged change of position explains (an event at `eventMinProbability` or more whose
//     onset-to-detection span reaches the boundary) the transition is uniform: nothing carries across it.
// So a short stand bracketed by flagged changes keeps its own reading, while the unresolved and early hedged
// readings of a single still stretch take the reading the stretch's evidence as a whole supports. The smoothed
// head keeps the run's transition mass, and its unresolved mass becomes the duration-weighted mean of its block
// (the runs between supported changes): resolving a posture is the evidence's job, not the smoother's.
//
// BOUNDARIES. A walk / run stop the decoder flagged with an onset earlier than the drawn boundary moves the
// boundary back to that onset (the causal decoder recognises the stop after it happened).
//
// RULES.
//   - Finalised days only (`ActivityContextPersistence.retrospectiveIntervals` returns nothing otherwise).
//   - Output is stamped `derivation = .retrospective` and stored apart from the causal rows; a causal consumer
//     (live decisions, causal / as-of baselines) never reads it (`ActivityContextIntervalReading.causal`).
//   - Deterministic: same runs and events in, identical intervals out (fixed iteration order, values rounded the
//     way stored runs are).
//   - Every stored day names the smoother that wrote its rows (`ActivityContextDayRow.retrospectiveVersion`).

public enum ActivityContextRetrospective {

    /// The smoother's semantics. Bumped whenever the retrospective rows it writes would change meaning, so stored
    /// days stay attributable to the version that made them.
    public static let version = "ctx-retro-1"

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
        /// How far a walk / run stop's onset may lie before the drawn boundary and still move it.
        public var stopOnsetMaxLeadS = 30
        /// The interval build the smoothed runs go through: the causal build's, plus keeping a short posture
        /// fragment a flagged change explains as its own row.
        public var builder: ActivityContextIntervalBuilder.Config = {
            var c = ActivityContextIntervalBuilder.Config()
            c.keepEvidencedPostureFragments = true
            return c
        }()
        public init() {}
    }

    static let postures: [PostureClass] = [.recumbent, .seatedLikely, .uprightStationary]

    // MARK: - Intervals

    /// Retrospective intervals of a finished day: `smooth` the runs, then the ordinary interval build (statistics
    /// from the same streams), stamped `.retrospective`. The caller decides that the day is final.
    public static func intervals(runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                                 hr: [HRSample] = [], steps: [StepSample] = [], rr: [RRInterval] = [],
                                 config: Config = Config()) -> [ActivityContextInterval] {
        let smoothed = smooth(runs: runs, events: events, config: config)
        return ActivityContextIntervalBuilder.build(runs: smoothed, events: events, hr: hr, steps: steps, rr: rr,
                                                    config: config.builder)
            .map { var iv = $0; iv.derivation = .retrospective; return iv }
    }

    // MARK: - Smoothing

    /// The runs with stop boundaries aligned and the posture head of every still segment smoothed. Runs outside
    /// still segments are returned as they were (boundaries aside).
    public static func smooth(runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                              config: Config = Config()) -> [ActivityContextRun] {
        var rs = runs.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
            .filter { $0.end > $0.start }
        guard !rs.isEmpty else { return [] }
        alignStops(&rs, events: events, config: config)
        let still = rs.map(isStill)
        let posturalSpans: [(Int, Int)] = events
            .filter { $0.isPostural && $0.probability >= config.eventMinProbability }
            .map { (min($0.onsetTs ?? $0.ts, $0.ts), $0.ts) }
            .sorted { $0 < $1 }

        var i = 0
        while i < rs.count {
            guard still[i] else { i += 1; continue }
            var j = i
            while j + 1 < rs.count, still[j + 1], continues(rs[j], rs[j + 1], config: config) { j += 1 }
            if j > i { smoothSegment(&rs, i...j, spans: posturalSpans, config: config) }
            i = j + 1
        }
        return rs
    }

    /// A still run: awake (not staged asleep), on the wrist, not a vehicle, class in the still family or lying awake.
    static func isStill(_ r: ActivityContextRun) -> Bool {
        guard r.wear == .onWrist, r.sleep != .asleep else { return false }
        let k = ActivityClassifier.classify(run: r)
        guard k.detail != .inVehicle else { return false }
        return k.activityClass.isStationaryAwake || k.activityClass == .lyingDown
    }

    static func continues(_ a: ActivityContextRun, _ b: ActivityContextRun, config: Config) -> Bool {
        b.start - a.end <= config.mergeGapS && a.wear == b.wear && a.sleep == b.sleep && a.inBed == b.inBed
    }

    /// Whether a flagged change of position explains the boundary at `ts`.
    static func supported(_ ts: Int, spans: [(Int, Int)], toleranceS: Int) -> Bool {
        let lo = ts - max(0, toleranceS), hi = ts + max(0, toleranceS)
        return spans.contains { $0.0 <= hi && $0.1 >= lo }
    }

    static func smoothSegment(_ rs: inout [ActivityContextRun], _ range: ClosedRange<Int>, spans: [(Int, Int)],
                              config: Config) {
        let idx = Array(range)
        let n = idx.count
        let k = postures.count
        // Emissions (log) and the unresolved / transition masses.
        var logE = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        var unresolved = [Double](repeating: 0, count: n)
        var transition = [Double](repeating: 0, count: n)
        var seconds = [Double](repeating: 0, count: n)
        for (a, r) in idx.enumerated() {
            let head = rs[r].posture
            let phys = postures.map { max(0, head[$0]) }
            let resolved = phys.reduce(0, +)
            transition[a] = min(1, max(0, head[.posturalTransition]))
            unresolved[a] = min(1 - transition[a], max(0, head[.unknown]))
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
        var block = [Int](repeating: 0, count: n)
        for a in 0..<(n - 1) {
            let boundary = rs[idx[a + 1]].start
            if supported(boundary, spans: spans, toleranceS: config.eventToleranceS) {
                stay[a] = 1.0 / Double(k)
                block[a + 1] = block[a] + 1
            } else {
                let h = 1 - exp(-seconds[a] / max(1, config.unevidencedPostureDwellS))
                stay[a] = 1 - h
                block[a + 1] = block[a]
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
        // Unresolved mass per block: the duration-weighted mean of its runs'.
        var blockUnresolved: [Int: (Double, Double)] = [:]
        for a in 0..<n {
            let cur = blockUnresolved[block[a], default: (0, 0)]
            blockUnresolved[block[a]] = (cur.0 + unresolved[a] * seconds[a], cur.1 + seconds[a])
        }
        for (a, r) in idx.enumerated() {
            let (u, w) = blockUnresolved[block[a]]!
            let unknown = min(1 - transition[a], w > 0 ? u / w : unresolved[a])
            let rest = max(0, 1 - transition[a] - unknown)
            var values: [PostureClass: Double] = [:]
            for (s, p) in postures.enumerated() { values[p] = rest * gamma[a][s] }
            values[.unknown] = unknown
            values[.posturalTransition] = transition[a]
            rs[r].posture = quantizedHead(values)
        }
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

    /// Move a gait-to-still boundary back to the onset of the walk / run stop the decoder flagged for it.
    static func alignStops(_ rs: inout [ActivityContextRun], events: [ActivityTransitionEvent], config: Config) {
        let stops = events.filter { $0.kind == .walkStop || $0.kind == .runStop }
            .map { (onset: min($0.onsetTs ?? $0.ts, $0.ts), ts: $0.ts) }
            .sorted { ($0.onset, $0.ts) < ($1.onset, $1.ts) }
        guard !stops.isEmpty, rs.count >= 2 else { return }
        for i in 0..<(rs.count - 1) {
            let a = rs[i], b = rs[i + 1]
            guard a.end == b.start, ActivityClassifier.classify(run: a).activityClass.isGait, isStill(b) else { continue }
            let boundary = b.start
            // The stop that explains this boundary: detected at or after the boundary's lead window, onset before it.
            guard let stop = stops.first(where: {
                $0.onset < boundary && $0.onset >= boundary - config.stopOnsetMaxLeadS
                    && $0.ts <= boundary + config.stopOnsetMaxLeadS
            }), stop.onset > a.start else { continue }
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
