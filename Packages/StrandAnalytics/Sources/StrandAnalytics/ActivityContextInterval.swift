import Foundation
import WhoopProtocol

// ActivityContextInterval.swift — the timestamp-aligned behavioural context that physiological data joins to.
//
// WHY INTERVALS AND NOT A LABEL ON EVERY SAMPLE. A day holds ~86,000 heart-rate seconds, tens of thousands
// of beats, and 1 Hz respiration / SpO2 / skin-temperature / gravity rows. The wearer's behaviour changes a
// few dozen times a day. Copying a class onto every sample would multiply the storage of every stream by
// the width of the label and would have to be rewritten each time the decoder improves. Instead one row
// says "from `start` to `end` the wearer was `activityClass` (confidence …)" and any observation is joined
// to it by timestamp (an as-of join: the interval whose [start, end) contains the sample). The raw streams
// are never touched.
//
// A few measurements have NO per-timestamp row on the phone to join against - heart-rate variability,
// respiratory rate (nightly aggregates only), step cadence, the HR trend. Those are computed once per
// interval from the same raw streams and stored beside the label, so "HRV + HR + respiratory rate + motion +
// activity + confidence" is a single row for them. Everything per-sample (HR, R-R, SpO2, skin temperature,
// raw respiration, gravity, steps) joins through the SQL views in `WhoopStore` or `ActivityContextLookup`.
//
// SHAPE. Intervals are derived from the decoder's runs (`ActivityContextRun`), which are already
// "consecutive published states with the same belief". Three things happen on the way:
//   1. each run is classified (`ActivityClassifier`), and neighbours with the same class, sleep and wear
//      context are merged (duration-weighted), so a seat/desk wording flip inside one situation is one row;
//   2. a non-movement fragment shorter than `foldFragmentS` between two stretches of the same situation is
//      absorbed, and the interval says so (`absorbedClasses`, `absorbedSeconds`): a sustained-state row stays
//      stable without pretending the stand never happened. A MOVEMENT fragment is never folded away (a
//      six-second walk to the kitchen is behaviour worth labelling, and the stand reminder cares about every
//      second of it), and neither is an off-wrist or no-claim (`unknown`) fragment or one whose wear, sleep or
//      in-bed context differs: absorbing those would assert a context the evidence never gave. The short changes
//      themselves are kept as events (`ActivityContextDayDocument.events`, counted per row in
//      `transitionCount`);
//   3. intervals longer than `maxIntervalS` are cut into near-equal parts, so every row's statistics are
//      local (a 15-minute HRV, not an eight-hour one) and "which interval contains t" is a bounded index
//      range.
// Gaps between intervals are real: the decoder saw no data there, and the lookup says so rather than
// carrying the previous label forward.
//
// TIMING. The decoder is causal, so a transition is recognised a few seconds after it happened and
// boundaries are only as sharp as its evidence window (~10-30 s). Statistics over an interval are exact
// for the interval as drawn; the interval is drawn with that lag.

/// One stretch of constant behavioural context and the physiology measured inside it.
public struct ActivityContextInterval: Equatable, Codable, Sendable {
    /// Unix seconds, inclusive.
    public var start: Int
    /// Unix seconds, exclusive.
    public var end: Int
    public var activityClass: ActivityClass
    /// Belief that the wearer was in this class — the SUBCLASS posterior mass (act-class-2),
    /// not the family mass; `ActivityClassification.familyConfidence` carries the family.
    public var confidence: Double
    public var runnerUp: ActivityClass?
    public var runnerUpConfidence: Double
    /// How good the evidence behind the reading was (sensor coverage, channel agreement, warm-up).
    public var evidenceQuality: Double
    /// The most common top reading of each head over the interval, nil when it was never resolved.
    public var posture: PostureClass?
    public var locomotion: LocomotionClass?
    public var armBehavior: ArmBehaviorClass?
    public var sleep: SleepContextState
    public var wear: WearContextState
    /// Mean motion intensity (0...1) the decoder published over the interval.
    public var intensity: Double?

    // Motion
    /// Steps the strap's counter added inside the interval.
    public var stepTicks: Int
    /// Mean steps per minute over the stretches in which a step was counted; nil below 20 s of stepping.
    public var cadenceSpm: Double?

    // Heart rate
    public var hrSamples: Int
    public var hrMean: Double?
    public var hrMin: Int?
    public var hrMax: Int?
    /// Least-squares trend over the interval in beats/min per minute; nil on thin or short data.
    public var hrSlope: Double?

    // Beat-to-beat
    /// RMSSD in ms over the interval's cleaned R-R; nil unless enough clean, trustworthy beats exist and
    /// wrist motion was low enough for beat timing to be trusted (see
    /// `ActivityContextIntervalBuilder.variabilityAllowed` — a continuous motion gate, not a fixed list of
    /// excluded activity classes).
    public var rmssd: Double?
    /// Clean beats behind `rmssd` (0 when it is nil).
    public var rrBeats: Int
    /// Sum of squared successive NN differences behind `rmssd` (ms²), UNROUNDED; 0 when `rmssd` is nil.
    /// Lets a downstream rollup recombine RMSSD across several intervals as `sqrt(Σ this / Σ rrDiffCount)`
    /// instead of averaging already-square-rooted RMSSD values (`ActivityContextAggregator`).
    public var rrDiffSqSumMs2: Double
    /// Successive-difference pairs behind `rrDiffSqSumMs2`. Not the same as `rrBeats`: a beat dropped by
    /// cleaning removes one pair without removing a beat on either side of it, so this is `rrBeats − 1`
    /// only when every clean beat was contiguous with its predecessor.
    public var rrDiffCount: Int
    /// Breaths per minute from respiratory sinus arrhythmia in the interval; nil unless the wearer was
    /// still enough, long enough, and enough breaths were found.
    public var respRateBpm: Double?
    /// Breath intervals behind `respRateBpm` (0 when it is nil).
    public var respBreaths: Int

    // Gait (reported, not evidence)
    /// ElderNet's gait metrics over the gait windows inside the interval. nil (and absent from the JSON) unless
    /// the day was decoded with the ElderNet channel and the interval's runs carried gait. Not part of
    /// `ActivityContextIntervalRow`: the phone's store does not hold it.
    public var gait: ActivityGaitSummary?

    // Context (ctx-int-2). Plain stored values with defaults; absent keys decode to them, so an interval written
    // before they existed reads back as "nothing recorded".
    /// Inside a detected night's in-bed window (lying awake in bed vs on a sofa).
    public var inBed: Bool
    /// Duration-weighted mean of the decoder's overall uncertainty over the interval's runs, in [0, 1].
    public var uncertainty: Double
    /// Experts that spoke during the interval's runs (`ActivityContextRun.experts`, union, fixed order).
    public var experts: [String]
    /// Decoder events (any kind: a change of position, a walk or run starting or stopping) flagged inside
    /// `[start, end)` by their detection second. A sitting row with a stand inside it says so here.
    public var transitionCount: Int
    /// Classes of the short fragments the sustained-state fold absorbed into this row, most seconds first, and
    /// their total seconds. Empty / 0 when the row is what its runs said throughout.
    public var absorbedClasses: [ActivityClass]
    public var absorbedSeconds: Int
    /// Seconds without any decoded state between the previous row's end and this row's start (0 when they
    /// touch). nil for the first row of a build (nothing before it to measure from).
    public var precededByGapS: Int?
    /// Seconds of the row within `ActivityContextIntervalBuilder.Config.settlingS` (~2 min, the orthostatic
    /// settling time) after a preceding movement row ended or a change of position / end of a walk was flagged.
    /// Rest statistics over those seconds still carry the recovery. 0 for movement rows.
    public var settlingSeconds: Int

    public var durationSeconds: Int { end - start }

    public init(start: Int, end: Int, activityClass: ActivityClass, confidence: Double,
                runnerUp: ActivityClass? = nil, runnerUpConfidence: Double = 0, evidenceQuality: Double = 0,
                posture: PostureClass? = nil, locomotion: LocomotionClass? = nil,
                armBehavior: ArmBehaviorClass? = nil,
                sleep: SleepContextState = .unknown, wear: WearContextState = .onWrist, intensity: Double? = nil,
                stepTicks: Int = 0, cadenceSpm: Double? = nil,
                hrSamples: Int = 0, hrMean: Double? = nil, hrMin: Int? = nil, hrMax: Int? = nil,
                hrSlope: Double? = nil, rmssd: Double? = nil, rrBeats: Int = 0,
                rrDiffSqSumMs2: Double = 0, rrDiffCount: Int = 0,
                respRateBpm: Double? = nil, respBreaths: Int = 0, gait: ActivityGaitSummary? = nil,
                inBed: Bool = false, uncertainty: Double = 0, experts: [String] = [], transitionCount: Int = 0,
                absorbedClasses: [ActivityClass] = [], absorbedSeconds: Int = 0, precededByGapS: Int? = nil,
                settlingSeconds: Int = 0) {
        self.start = start; self.end = end
        self.activityClass = activityClass; self.confidence = confidence
        self.runnerUp = runnerUp; self.runnerUpConfidence = runnerUpConfidence
        self.evidenceQuality = evidenceQuality
        self.posture = posture; self.locomotion = locomotion; self.armBehavior = armBehavior
        self.sleep = sleep; self.wear = wear; self.intensity = intensity
        self.stepTicks = stepTicks; self.cadenceSpm = cadenceSpm
        self.hrSamples = hrSamples; self.hrMean = hrMean; self.hrMin = hrMin; self.hrMax = hrMax
        self.hrSlope = hrSlope
        self.rmssd = rmssd; self.rrBeats = rrBeats
        self.rrDiffSqSumMs2 = rrDiffSqSumMs2; self.rrDiffCount = rrDiffCount
        self.respRateBpm = respRateBpm; self.respBreaths = respBreaths
        self.gait = gait
        self.inBed = inBed; self.uncertainty = uncertainty; self.experts = experts
        self.transitionCount = transitionCount
        self.absorbedClasses = absorbedClasses; self.absorbedSeconds = absorbedSeconds
        self.precededByGapS = precededByGapS; self.settlingSeconds = settlingSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        activityClass = try c.decode(ActivityClass.self, forKey: .activityClass)
        confidence = try c.decode(Double.self, forKey: .confidence)
        runnerUp = try c.decodeIfPresent(ActivityClass.self, forKey: .runnerUp)
        runnerUpConfidence = try c.decode(Double.self, forKey: .runnerUpConfidence)
        evidenceQuality = try c.decode(Double.self, forKey: .evidenceQuality)
        posture = try c.decodeIfPresent(PostureClass.self, forKey: .posture)
        locomotion = try c.decodeIfPresent(LocomotionClass.self, forKey: .locomotion)
        armBehavior = try c.decodeIfPresent(ArmBehaviorClass.self, forKey: .armBehavior)
        sleep = try c.decode(SleepContextState.self, forKey: .sleep)
        wear = try c.decode(WearContextState.self, forKey: .wear)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
        stepTicks = try c.decode(Int.self, forKey: .stepTicks)
        cadenceSpm = try c.decodeIfPresent(Double.self, forKey: .cadenceSpm)
        hrSamples = try c.decode(Int.self, forKey: .hrSamples)
        hrMean = try c.decodeIfPresent(Double.self, forKey: .hrMean)
        hrMin = try c.decodeIfPresent(Int.self, forKey: .hrMin)
        hrMax = try c.decodeIfPresent(Int.self, forKey: .hrMax)
        hrSlope = try c.decodeIfPresent(Double.self, forKey: .hrSlope)
        rmssd = try c.decodeIfPresent(Double.self, forKey: .rmssd)
        rrBeats = try c.decode(Int.self, forKey: .rrBeats)
        rrDiffSqSumMs2 = try c.decode(Double.self, forKey: .rrDiffSqSumMs2)
        rrDiffCount = try c.decode(Int.self, forKey: .rrDiffCount)
        respRateBpm = try c.decodeIfPresent(Double.self, forKey: .respRateBpm)
        respBreaths = try c.decode(Int.self, forKey: .respBreaths)
        gait = try c.decodeIfPresent(ActivityGaitSummary.self, forKey: .gait)
        inBed = try c.decodeIfPresent(Bool.self, forKey: .inBed) ?? false
        uncertainty = try c.decodeIfPresent(Double.self, forKey: .uncertainty) ?? 0
        experts = try c.decodeIfPresent([String].self, forKey: .experts) ?? []
        transitionCount = try c.decodeIfPresent(Int.self, forKey: .transitionCount) ?? 0
        absorbedClasses = try c.decodeIfPresent([ActivityClass].self, forKey: .absorbedClasses) ?? []
        absorbedSeconds = try c.decodeIfPresent(Int.self, forKey: .absorbedSeconds) ?? 0
        precededByGapS = try c.decodeIfPresent(Int.self, forKey: .precededByGapS)
        settlingSeconds = try c.decodeIfPresent(Int.self, forKey: .settlingSeconds) ?? 0
    }

    /// Whether `ts` falls inside the interval.
    public func contains(_ ts: Int) -> Bool { ts >= start && ts < end }
}

// MARK: - Builder

public enum ActivityContextIntervalBuilder {

    public struct Config: Equatable, Sendable {
        /// Largest gap between two runs of the same situation that still joins them.
        public var mergeGapS = 10
        /// A non-movement stretch shorter than this, between two stretches of the same situation, is absorbed.
        public var foldFragmentS = 10
        /// Longest single row; longer stretches are cut into near-equal parts.
        public var maxIntervalS = 900
        /// Shortest interval that gets an HRV / respiratory-rate reading.
        public var minVariabilityIntervalS = 60
        /// Motion-magnitude ceiling (`ActivityIntensity`'s 0...1 log scale) above which RR beat timing is
        /// treated as corrupted. Replaces a fixed per-`ActivityClass` exclusion list: RR trustworthiness is
        /// a property of what the wrist actually did, not of the semantic label attached to it afterwards.
        /// 0.40 ≈ `ActivityIntensity.scale(g: 0.049)`, under 50 mg of gravity-removed wrist motion —
        /// comfortably above this strap's own resting-wrist anchor (≈7 mg, intensity ≈0.17) and comfortably
        /// below a committed walk (≈135 mg median, intensity ≈0.52) or run (≈400 mg median). A still
        /// interval mislabelled as `walking`, or a brief lull inside a real walk, is now judged on its own
        /// motion rather than refused on sight; a bursty, mislabelled `lightActivity` or `sitting` stretch
        /// is correctly excluded instead of silently passing through the old list.
        public var maxVariabilityIntensity = 0.40
        /// Clean beats RMSSD needs.
        public var minRmssdBeats = 20
        /// Breath intervals respiratory rate needs.
        public var minRespBreaths = 6
        /// Heart-rate samples and span the trend needs.
        public var hrSlopeMinSamples = 30
        public var hrSlopeMinSpanS = 90
        /// Trend clamp, beats/min per minute: faster than this is a sensor artefact, not physiology.
        public var hrSlopeClip = 30.0
        /// Seconds of stepping needed before a cadence is reported.
        public var cadenceMinActiveS = 20
        /// Seconds after a movement row ends, or a change of position / end of a walk is flagged, that count as
        /// settling (`ActivityContextInterval.settlingSeconds`): heart rate and blood pressure take one to two
        /// minutes to settle after an orthostatic change or light exertion.
        public var settlingS = 120
        public init() {}
    }

    /// Intervals for a day's runs, enriched from the streams that were decoded and the events it flagged.
    public static func build(document: ActivityContextDayDocument,
                             hr: [HRSample] = [], steps: [StepSample] = [], rr: [RRInterval] = [],
                             config: Config = Config()) -> [ActivityContextInterval] {
        build(runs: document.runs, events: document.events, hr: hr, steps: steps, rr: rr, config: config)
    }

    public static func build(runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                             hr: [HRSample] = [], steps: [StepSample] = [], rr: [RRInterval] = [],
                             config: Config = Config()) -> [ActivityContextInterval] {
        let shaped = split(fold(merge(pieces(runs), config: config), config: config), config: config)
        guard !shaped.isEmpty else { return [] }
        let context = Context(shaped, events: events, config: config)

        let lo = shaped.first!.start, hi = shaped.last!.end
        let heart = Heart(hr, lo: lo, hi: hi)
        let ticks = ActivityContextTrackBuilder.stepTicksAndClasses(steps, lo: lo, hi: hi).ticks
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { (ts: $0.key, d: $0.value) }
        let beats = rr.isEmpty ? [] : rr.filter { $0.ts >= lo && $0.ts < hi }.sortedByTsStable()
        let breathing = beats.count >= 2 ? SleepStager.respBreathTrack(beats) : RespBreathTrack.empty

        return shaped.enumerated().map { i, acc in
            var out = acc.interval
            context.fill(&out, index: i)
            heart.fill(&out, config: config)
            fillSteps(&out, ticks: ticks, config: config)
            fillVariability(&out, beats: beats, breathing: breathing, config: config)
            return out
        }
    }

    // MARK: Shaping

    /// A weighted accumulation of adjacent stretches that are one situation.
    struct Accumulation {
        /// One run inside the stretch, with its own reading, and the class of the fragment it came in with when
        /// the fold absorbed it (nil for the stretch's own runs).
        struct Member {
            var run: ActivityContextRun
            var classification: ActivityClassification
            var absorbedAs: ActivityClass?
        }

        var start: Int
        var end: Int
        var activityClass: ActivityClass
        var sleep: SleepContextState
        var wear: WearContextState
        var inBed: Bool
        var seconds = 0.0
        var confidenceSum = 0.0, qualitySum = 0.0, uncertaintySum = 0.0
        var runnerUpMass: [ActivityClass: Double] = [:]
        var posture: [PostureClass: Double] = [:]
        var locomotion: [LocomotionClass: Double] = [:]
        var arm: [ArmBehaviorClass: Double] = [:]
        var intensitySum = 0.0, intensitySeconds = 0.0
        var gait: GaitTotals?
        var experts: [String] = []
        /// Seconds per class the fold absorbed.
        var absorbed: [ActivityClass: Double] = [:]
        /// The runs behind the stretch, so a split part re-derives its summary from its own seconds (D3-13).
        var members: [Member] = []

        init(run: ActivityContextRun, classification k: ActivityClassification) {
            start = run.start; end = run.end
            activityClass = k.activityClass; sleep = run.sleep; wear = run.wear; inBed = run.inBed
            add(Member(run: run, classification: k, absorbedAs: nil))
        }

        /// An empty accumulation over `[start, end)` with `like`'s shared reading.
        private init(empty like: Accumulation, start: Int, end: Int) {
            self.start = start; self.end = end
            activityClass = like.activityClass; sleep = like.sleep; wear = like.wear; inBed = like.inBed
        }

        var duration: Int { end - start }

        /// Adds `m`, weighted by `seconds` of it (its whole run unless a part takes a slice).
        mutating func add(_ m: Member, seconds part: Double? = nil, extendBounds: Bool = true) {
            let full = Double(max(0, m.run.end - m.run.start))
            let w = part ?? full
            let k = m.classification
            seconds += w
            confidenceSum += k.confidence * w
            qualitySum += k.evidenceQuality * w
            uncertaintySum += m.run.overallUncertainty * w
            if let r = k.runnerUp { runnerUpMass[r, default: 0] += k.runnerUpConfidence * w }
            if let p = k.posture { posture[p, default: 0] += w }
            if let l = k.locomotion { locomotion[l, default: 0] += w }
            if let a = k.armBehavior { arm[a, default: 0] += w }
            if let i = m.run.intensity { intensitySum += i * w; intensitySeconds += w }
            // Gait windows carry no position inside a run: a slice gets its share of them.
            if let g = m.run.gait {
                let totals = GaitTotals(summary: g)
                addGait(part == nil || full <= 0 ? totals : totals.scaled(w / full))
            }
            if !m.run.experts.isEmpty { experts = ActivityContextRun.union(experts, m.run.experts) }
            if let c = m.absorbedAs { absorbed[c, default: 0] += w }
            members.append(m)
            if extendBounds {
                end = max(end, m.run.end)
                start = min(start, m.run.start)
            }
        }

        mutating func addGait(_ g: GaitTotals) {
            if gait == nil { gait = g } else { gait!.add(g) }
        }

        /// `other` folded in; `as` marks its runs as an absorbed fragment of that class.
        mutating func absorb(_ other: Accumulation, as fragment: ActivityClass? = nil) {
            for m in other.members {
                var m = m
                if let fragment { m.absorbedAs = fragment }
                add(m)
            }
            start = min(start, other.start); end = max(end, other.end)
        }

        func sameSituation(_ other: Accumulation) -> Bool {
            activityClass == other.activityClass && sleep == other.sleep && wear == other.wear
                && inBed == other.inBed
        }

        /// The accumulation over `[from, to)` only: the shared class, with intensity, confidence, posture and the
        /// rest summed over the seconds of its own runs inside the part (a part whose motion was concentrated
        /// in it reads that motion, D3-13). Re-merging the parts reproduces the whole.
        func part(_ from: Int, _ to: Int) -> Accumulation {
            var p = Accumulation(empty: self, start: from, end: to)
            for m in members {
                let o = min(to, m.run.end) - max(from, m.run.start)
                guard o > 0 else { continue }
                p.add(m, seconds: Double(o), extendBounds: false)
            }
            return p
        }

        var interval: ActivityContextInterval {
            let w = max(seconds, 1e-9)
            let runner = runnerUpMass.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }
            func mode<C: Hashable>(_ m: [C: Double], _ tieBreak: (C, C) -> Bool) -> C? {
                m.max { $0.value < $1.value || ($0.value == $1.value && tieBreak($0.key, $1.key)) }?.key
            }
            let absorbedOrder = absorbed.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            return ActivityContextInterval(
                start: start, end: end, activityClass: activityClass,
                confidence: Self.round(confidenceSum / w, 1000),
                runnerUp: runner.flatMap { $0.value / w >= 0.02 ? $0.key : nil },
                runnerUpConfidence: runner.map { $0.value / w >= 0.02 ? Self.round($0.value / w, 1000) : 0 } ?? 0,
                evidenceQuality: Self.round(qualitySum / w, 1000),
                posture: mode(posture) { $0.rawValue > $1.rawValue },
                locomotion: mode(locomotion) { $0.rawValue > $1.rawValue },
                armBehavior: mode(arm) { $0.rawValue > $1.rawValue },
                sleep: sleep, wear: wear,
                intensity: intensitySeconds > 0 ? Self.round(intensitySum / intensitySeconds, 1000) : nil,
                gait: gait.flatMap { $0.isEmpty ? nil : $0.summary },
                inBed: inBed, uncertainty: Self.round(uncertaintySum / w, 1000), experts: experts,
                absorbedClasses: absorbedOrder.map(\.key),
                absorbedSeconds: Int(absorbedOrder.reduce(0) { $0 + $1.value }.rounded()))
        }

        static func round(_ x: Double, _ scale: Double) -> Double { (x * scale).rounded() / scale }
    }

    /// What a row knows about its neighbours and the day's events: the gap before it, the events inside it, the
    /// settling after movement and changes of position.
    struct Context {
        let starts: [Int]
        let ends: [Int]
        let movement: [Bool]
        /// Event detection seconds, sorted (every kind, for `transitionCount`).
        let eventTs: [Int]
        /// Seconds settling starts from, sorted: the end of each movement row, each change of position and each
        /// end of a walk or run.
        let anchors: [Int]
        let settlingS: Int

        init(_ shaped: [Accumulation], events: [ActivityTransitionEvent], config: Config) {
            starts = shaped.map(\.start); ends = shaped.map(\.end)
            movement = shaped.map { $0.activityClass.isMovement }
            eventTs = events.map(\.ts).sorted()
            var a = events.filter { $0.isPostural || $0.kind == .walkStop || $0.kind == .runStop }.map(\.ts)
            for (i, s) in shaped.enumerated() where s.activityClass.isMovement { a.append(ends[i]) }
            anchors = a.sorted()
            settlingS = max(0, config.settlingS)
        }

        func fill(_ iv: inout ActivityContextInterval, index i: Int) {
            iv.precededByGapS = i > 0 ? max(0, starts[i] - ends[i - 1]) : nil
            let lo = iv.start, hi = iv.end
            iv.transitionCount = eventTs.reduce(0) { $0 + ($1 >= lo && $1 < hi ? 1 : 0) }
            guard !movement[i], settlingS > 0 else { iv.settlingSeconds = 0; return }
            // Union of [a, a + settlingS) over the anchors at or before the row's end, clipped to the row.
            var covered = 0, reach = iv.start
            for a in anchors where a < iv.end && a + settlingS > iv.start {
                let lo = max(reach, max(a, iv.start)), hi = min(iv.end, a + settlingS)
                if hi > lo { covered += hi - lo; reach = hi }
            }
            iv.settlingSeconds = covered
        }
    }

    static func pieces(_ runs: [ActivityContextRun]) -> [Accumulation] {
        runs.sorted { $0.start < $1.start }
            .filter { $0.end > $0.start }
            .map { Accumulation(run: $0, classification: ActivityClassifier.classify(run: $0)) }
    }

    static func merge(_ pieces: [Accumulation], config: Config) -> [Accumulation] {
        var out: [Accumulation] = []
        for p in pieces {
            if var last = out.last, last.sameSituation(p), p.start - last.end <= config.mergeGapS {
                last.absorb(p)
                out[out.count - 1] = last
            } else {
                out.append(p)
            }
        }
        return out
    }

    static func fold(_ merged: [Accumulation], config: Config) -> [Accumulation] {
        var out: [Accumulation] = []
        var i = 0
        while i < merged.count {
            let cur = merged[i]
            // Never absorbed: movement (behaviour worth its own row), off the wrist or no claim (absorbing would
            // assert a context nobody measured), or a fragment in another wear / sleep / in-bed context.
            let absorbable = !cur.activityClass.isMovement && cur.activityClass != .offWrist
                && cur.activityClass != .unknown
            if cur.duration < config.foldFragmentS, absorbable,
               let prev = out.last, i + 1 < merged.count {
                let next = merged[i + 1]
                if prev.sameSituation(next), cur.wear == prev.wear, cur.sleep == prev.sleep, cur.inBed == prev.inBed,
                   cur.start - prev.end <= config.mergeGapS,
                   next.start - cur.end <= config.mergeGapS {
                    var joined = prev
                    joined.absorb(cur, as: cur.activityClass)
                    joined.absorb(next)
                    out[out.count - 1] = joined
                    i += 2
                    continue
                }
            }
            out.append(cur)
            i += 1
        }
        return out
    }

    static func split(_ stretches: [Accumulation], config: Config) -> [Accumulation] {
        let cap = max(60, config.maxIntervalS)
        var out: [Accumulation] = []
        for s in stretches {
            let d = s.duration
            guard d > cap else { out.append(s); continue }
            let parts = (d + cap - 1) / cap
            let length = (d + parts - 1) / parts
            var t = s.start
            while t < s.end {
                let next = min(s.end, t + length)
                out.append(s.part(t, next))
                t = next
            }
        }
        return out
    }

    // MARK: Enrichment

    /// Heart rate in time order, valid readings only, with an index for range reads.
    private struct Heart {
        let samples: [(ts: Int, bpm: Int)]

        init(_ hr: [HRSample], lo: Int, hi: Int) {
            var byTs: [Int: Int] = [:]
            for s in hr where s.ts >= lo && s.ts < hi && (30...220).contains(s.bpm) { byTs[s.ts] = s.bpm }
            samples = byTs.map { (ts: $0.key, bpm: $0.value) }.sorted { $0.ts < $1.ts }
        }

        func lowerBound(_ ts: Int) -> Int {
            var l = 0, h = samples.count
            while l < h {
                let m = (l + h) / 2
                if samples[m].ts < ts { l = m + 1 } else { h = m }
            }
            return l
        }

        func fill(_ iv: inout ActivityContextInterval, config: Config) {
            let from = lowerBound(iv.start), to = lowerBound(iv.end)
            guard to > from else { return }
            let slice = samples[from..<to]
            iv.hrSamples = slice.count
            var sum = 0, lo = Int.max, hi = Int.min
            for s in slice { sum += s.bpm; lo = min(lo, s.bpm); hi = max(hi, s.bpm) }
            iv.hrMean = (Double(sum) / Double(slice.count) * 10).rounded() / 10
            iv.hrMin = lo; iv.hrMax = hi

            let span = slice.last!.ts - slice.first!.ts
            guard slice.count >= config.hrSlopeMinSamples, span >= config.hrSlopeMinSpanS else { return }
            let t0 = Double(slice.first!.ts)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for s in slice {
                let x = (Double(s.ts) - t0) / 60, y = Double(s.bpm)
                sx += x; sy += y; sxx += x * x; sxy += x * y
            }
            let n = Double(slice.count)
            let denom = n * sxx - sx * sx
            guard denom > 1e-9 else { return }
            let slope = (n * sxy - sx * sy) / denom
            iv.hrSlope = (min(config.hrSlopeClip, max(-config.hrSlopeClip, slope)) * 100).rounded() / 100
        }
    }

    /// `ticks` is the per-second step delta, time ordered, zeros dropped.
    private static func fillSteps(_ iv: inout ActivityContextInterval, ticks: [(ts: Int, d: Int)],
                                  config: Config) {
        var l = 0, h = ticks.count
        while l < h {
            let m = (l + h) / 2
            if ticks[m].ts < iv.start { l = m + 1 } else { h = m }
        }
        var total = 0
        var activeBins = Set<Int>()
        var i = l
        while i < ticks.count, ticks[i].ts < iv.end {
            total += ticks[i].d
            activeBins.insert((ticks[i].ts - iv.start) / 5)
            i += 1
        }
        iv.stepTicks = total
        let activeSeconds = activeBins.count * 5
        if activeSeconds >= config.cadenceMinActiveS {
            iv.cadenceSpm = (Double(total) * 60 / Double(activeSeconds) * 10).rounded() / 10
        }
    }

    /// Motion corrupts beat timing. Gated on wear and on the interval's own measured motion magnitude
    /// (`maxVariabilityIntensity`), never on the semantic activity class: see the config field's comment.
    /// `nil` intensity (no motion stream for the interval) does not exclude — absence of a motion reading
    /// is not evidence of motion, the same convention `HRVAnalyzer.beatAccurateFraction` uses for a short
    /// series.
    private static func variabilityAllowed(_ iv: ActivityContextInterval, config: Config) -> Bool {
        guard iv.wear != .offWrist else { return false }
        if let intensity = iv.intensity, intensity > config.maxVariabilityIntensity { return false }
        return true
    }

    private static func fillVariability(_ iv: inout ActivityContextInterval, beats: [RRInterval],
                                        breathing: RespBreathTrack, config: Config) {
        guard iv.durationSeconds >= config.minVariabilityIntervalS,
              variabilityAllowed(iv, config: config) else { return }

        if !beats.isEmpty {
            let a = lowerBound(beats, iv.start), b = lowerBound(beats, iv.end)
            if let r = rmssd(Array(beats[a..<b]), minBeats: config.minRmssdBeats) {
                iv.rmssd = (r.value * 10).rounded() / 10
                iv.rrBeats = r.beats
                iv.rrDiffSqSumMs2 = r.sumSq
                iv.rrDiffCount = r.diffCount
            }
        }
        if let e = breathing.estimate(from: iv.start, to: iv.end, currentFrom: iv.start,
                                      minIntervals: config.minRespBreaths), e.intervals >= config.minRespBreaths {
            iv.respRateBpm = (e.breathsPerMinute * 10).rounded() / 10
            iv.respBreaths = e.intervals
        }
    }

    private static func lowerBound(_ beats: [RRInterval], _ ts: Int) -> Int {
        var l = 0, h = beats.count
        while l < h {
            let m = (l + h) / 2
            if beats[m].ts < ts { l = m + 1 } else { h = m }
        }
        return l
    }

    /// RMSSD over a stretch of beats, with the same trust gates the rolling and nightly paths apply: a window
    /// whose beat time exceeds its wall clock (a doubled beat reads LOW) or whose beats are banked rather than
    /// timed is refused rather than shown.
    static func rmssd(_ rows: [RRInterval], minBeats: Int) -> (value: Double, beats: Int, sumSq: Double, diffCount: Int)? {
        guard rows.count >= minBeats else { return nil }
        let tsSec = rows.map(\.ts)
        let ms = rows.map { Double($0.rrMs) }
        let verdict = HRVAnalyzer.classifyCoverage(coverage: HRVAnalyzer.rrCoverage(tsSec: tsSec, rrMs: ms),
                                                   collapsed: HRVAnalyzer.collapsedCoverage(tsSec: tsSec, rrMs: ms))
        guard HRVAnalyzer.successiveDiffIsTrustworthy(verdict),
              HRVAnalyzer.beatValuesAreTrustworthy(
                beatAccurateFraction: HRVAnalyzer.beatAccurateFraction(tsSec: tsSec, rrMs: ms)) else { return nil }
        let clean = HRVAnalyzer.cleanRRGapAware(ms)
        guard clean.nn.count >= minBeats else { return nil }
        let components = HRVAnalyzer.rmssdSumSquaresGapAware(clean.nn, clean.contiguous)
        guard components.count >= 1 else { return nil }
        let value = (components.sumSq / Double(components.count)).squareRoot()
        return (value, clean.nn.count, components.sumSq, components.count)
    }
}

// MARK: - Lookup

/// How a stretch of time divides between classes.
public struct ActivityComposition: Equatable, Sendable {
    public let from: Int
    public let to: Int
    /// Seconds per class inside `[from, to)`. Only classes that occurred are present.
    public let seconds: [ActivityClass: Int]

    public var windowSeconds: Int { max(0, to - from) }
    /// Seconds of the window that any interval covers.
    public var coveredSeconds: Int { seconds.values.reduce(0, +) }

    /// Share of the covered time spent in `c` (0 when nothing is covered).
    public func share(of c: ActivityClass) -> Double {
        let covered = coveredSeconds
        return covered > 0 ? Double(seconds[c] ?? 0) / Double(covered) : 0
    }

    /// The class with the most time, ties broken by the stable class order.
    public var dominant: ActivityClass? {
        seconds.max { a, b in
            a.value != b.value ? a.value < b.value
                : (ActivityClass.allCases.firstIndex(of: a.key) ?? 0) > (ActivityClass.allCases.firstIndex(of: b.key) ?? 0)
        }?.key
    }
}

/// Answers "what was the wearer doing at time t" over a sorted, non-overlapping set of intervals.
public struct ActivityContextLookup: Sendable {
    public let intervals: [ActivityContextInterval]

    public init(intervals: [ActivityContextInterval]) {
        self.intervals = intervals.sorted { $0.start < $1.start }
    }

    /// The interval containing `ts`, or nil when the decoder had no data there.
    public func interval(at ts: Int) -> ActivityContextInterval? {
        let i = firstIndex(endingAfter: ts)
        guard i < intervals.count, intervals[i].start <= ts else { return nil }
        return intervals[i]
    }

    /// Intervals overlapping `[from, to)`, in time order.
    public func intervals(from: Int, to: Int) -> ArraySlice<ActivityContextInterval> {
        guard to > from else { return [] }
        let lo = firstIndex(endingAfter: from)
        var hi = lo
        while hi < intervals.count, intervals[hi].start < to { hi += 1 }
        return intervals[lo..<hi]
    }

    /// Seconds per class inside `[from, to)`.
    public func composition(from: Int, to: Int) -> ActivityComposition {
        var seconds: [ActivityClass: Int] = [:]
        for iv in intervals(from: from, to: to) {
            let s = max(iv.start, from), e = min(iv.end, to)
            if e > s { seconds[iv.activityClass, default: 0] += e - s }
        }
        return ActivityComposition(from: from, to: to, seconds: seconds)
    }

    /// Each item paired with the interval that covers its timestamp (nil where there is none). The items
    /// themselves are not copied into the context, so any observation series can be annotated this way.
    public func attach<T>(_ items: [T], at ts: (T) -> Int) -> [(item: T, context: ActivityContextInterval?)] {
        items.map { ($0, interval(at: ts($0))) }
    }

    /// Index of the first interval whose end is after `ts`.
    private func firstIndex(endingAfter ts: Int) -> Int {
        var l = 0, h = intervals.count
        while l < h {
            let m = (l + h) / 2
            if intervals[m].end <= ts { l = m + 1 } else { h = m }
        }
        return l
    }
}
