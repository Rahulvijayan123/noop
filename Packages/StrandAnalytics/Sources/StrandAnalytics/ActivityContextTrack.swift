import Foundation
import WhoopProtocol

// ActivityContextTrack.swift — from stored streams to decoded ActivityContext states, and a compact
// persistent form.
//
// The decoder (`ActivityContextDecoder`) is a streaming object that eats one `ActivityObservation` per
// second. Stored data is not shaped like that: heart rate, the gravity/dynAccel stream, the step counter
// and the encoder windows each arrive at their own cadence, and sleep / wear / workouts are intervals.
// `ActivityContextTrackBuilder` aligns them onto a one-second grid, feeds the decoder, and returns the
// published (5-s) states. `ActivityContextDayDocument` is the versioned persistent form: the states
// coalesced into runs of "the same belief", plus the decoder snapshot so a restart can continue.

// MARK: - Input

public struct ActivityContextTrackInput {
    public var dayStart: Int
    public var dayEnd: Int
    public var hr: [HRSample]
    /// 1 Hz gravity vector (g) with the strap's own gravity-removed motion magnitude when it has one.
    public var gravity: [GravitySample]
    /// Cumulative step counter + the strap's per-record still/walk/run label.
    public var steps: [StepSample]
    /// Logged sleep sessions.
    public var sleep: [DayStateSpan]
    /// True when sleep detection has run over this stretch, so time outside a session is "awake". For a
    /// live day the detector has not seen the present yet; pass false and it stays "unknown".
    public var sleepKnownOutsideSessions: Bool
    public var workouts: [DayStateWorkout]
    public var offWrist: [DayStateSpan]
    /// Optional short-window motion-encoder output (HART or the heuristic baseline), model-agnostic.
    public var encoderWindows: [ActivityWindowPrediction]
    public var encoderId: String
    public var encoderVersion: String
    /// Optional per-window features computed from the 30 Hz IMU branch (see `Tools/ActivityContext`).
    public var imuWindows: [ImuWindowFeatures]

    public init(dayStart: Int, dayEnd: Int,
                hr: [HRSample] = [], gravity: [GravitySample] = [], steps: [StepSample] = [],
                sleep: [DayStateSpan] = [], sleepKnownOutsideSessions: Bool = true,
                workouts: [DayStateWorkout] = [], offWrist: [DayStateSpan] = [],
                encoderWindows: [ActivityWindowPrediction] = [],
                encoderId: String = "hart", encoderVersion: String = "unknown",
                imuWindows: [ImuWindowFeatures] = []) {
        self.dayStart = dayStart; self.dayEnd = dayEnd
        self.hr = hr; self.gravity = gravity; self.steps = steps
        self.sleep = sleep; self.sleepKnownOutsideSessions = sleepKnownOutsideSessions
        self.workouts = workouts; self.offWrist = offWrist
        self.encoderWindows = encoderWindows; self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.imuWindows = imuWindows
    }
}

public struct ActivityContextTrack: Sendable {
    /// Published states, one per `publishIntervalS`, in time order.
    public var states: [ActivityContextState]
    /// Every distinct event flagged, in time order.
    public var events: [ActivityTransitionEvent]
    /// Decoder state after the last observation, for restart / chunked processing.
    public var snapshot: ActivityDecoderSnapshot
    public var restore: ActivityRestoreOutcome
    /// Seconds with at least one observation.
    public var observedSeconds: Int
    /// Last second fed to the decoder.
    public var lastTs: Int?

    /// This track followed by one that continued it from `snapshot` (events the decoder keeps flagging
    /// across the join are listed once).
    public func appending(_ next: ActivityContextTrack) -> ActivityContextTrack {
        var merged = events
        for e in next.events {
            if let i = merged.lastIndex(where: { $0.kind == e.kind && $0.ts == e.ts }) {
                merged[i].probability = max(merged[i].probability, e.probability)
            } else {
                merged.append(e)
            }
        }
        return ActivityContextTrack(states: states + next.states, events: merged, snapshot: next.snapshot,
                                    restore: restore, observedSeconds: observedSeconds + next.observedSeconds,
                                    lastTs: next.lastTs ?? lastTs)
    }
}

// MARK: - Builder

public enum ActivityContextTrackBuilder {

    /// Decode `[dayStart, dayEnd)`. Pass the snapshot from a previous run to continue it: observations at
    /// or before the snapshot's last second are ignored, later ones continue the same belief.
    public static func build(_ input: ActivityContextTrackInput,
                             config: ActivityDecoderConfig = ActivityDecoderConfig(),
                             resuming snapshot: ActivityDecoderSnapshot? = nil) -> ActivityContextTrack {
        decode(observations(for: input), config: config, resuming: snapshot)
    }

    /// Feed ready-made observations (one per second, time ordered) through a decoder.
    public static func decode(_ observations: [ActivityObservation],
                              config: ActivityDecoderConfig = ActivityDecoderConfig(),
                              resuming snapshot: ActivityDecoderSnapshot? = nil) -> ActivityContextTrack {
        var decoder = ActivityContextDecoder(config: config, restoring: snapshot)
        let floor = decoder.lastObservationTs
        var states: [ActivityContextState] = []
        var events: [ActivityTransitionEvent] = []
        var index: [String: Int] = [:]
        var accepted = 0
        for o in observations {
            if let floor, o.ts <= floor { continue }
            accepted += 1
            guard let s = decoder.ingest(o) else { continue }
            states.append(s)
            if let t = s.transition {
                let key = "\(t.kind.rawValue)@\(t.ts)"
                if let i = index[key] {
                    events[i].probability = max(events[i].probability, t.probability)
                } else {
                    index[key] = events.count
                    events.append(t)
                }
            }
        }
        return ActivityContextTrack(states: states, events: events, snapshot: decoder.snapshot(),
                                    restore: decoder.restoreOutcome, observedSeconds: accepted,
                                    lastTs: decoder.lastObservationTs)
    }

    /// Step ticks per second = counter delta between consecutive samples 1–2 s apart, bounded by the gait
    /// ceiling (a walking-bout credit of 6–20 ticks lands in one second and counts as the ceiling), and the
    /// strap's per-record still/walk/run label, both keyed by second.
    static func stepTicksAndClasses(_ samples: [StepSample], lo: Int, hi: Int)
        -> (ticks: [Int: Int], classes: [Int: Int]) {
        var tickAt: [Int: Int] = [:], classAt: [Int: Int] = [:]
        let steps = samples.sorted { $0.ts < $1.ts }
        for (k, s) in steps.enumerated() where s.ts >= lo && s.ts < hi {
            if let c = s.activityClass { classAt[s.ts] = c }
            guard k > 0 else { continue }
            let p = steps[k - 1]
            let dt = s.ts - p.ts
            let d = (s.counter - p.counter) & 0xFFFF
            if dt >= 1, dt <= 2, d < StepsCounter.maxStepDelta {
                tickAt[s.ts] = min(d, StepsCounter.maxTicksPerSecond * dt)
            }
        }
        return (tickAt, classAt)
    }

    /// One observation per second that has any data (or an off-wrist span), in time order.
    static func observations(for input: ActivityContextTrackInput) -> [ActivityObservation] {
        let lo = input.dayStart, hi = input.dayEnd
        guard hi > lo else { return [] }

        var hrAt: [Int: Int] = [:]
        for s in input.hr where s.ts >= lo && s.ts < hi && (30...220).contains(s.bpm) { hrAt[s.ts] = s.bpm }

        var gravAt: [Int: GravitySample] = [:]
        for s in input.gravity where s.ts >= lo && s.ts < hi { gravAt[s.ts] = s }

        let (tickAt, classAt) = stepTicksAndClasses(input.steps, lo: lo, hi: hi)

        var encoderAt: [Int: MotionEncoderOutput] = [:]
        for w in input.encoderWindows where w.endTs >= lo && w.endTs < hi {
            encoderAt[w.endTs] = MotionEncoderOutput(prediction: w, encoderId: input.encoderId,
                                                     encoderVersion: input.encoderVersion)
        }
        var imuAt: [Int: ImuWindowFeatures] = [:]
        for f in input.imuWindows where f.endTs >= lo && f.endTs < hi { imuAt[f.endTs] = f }

        let sleepSpans = input.sleep.sorted { $0.start < $1.start }
        let offSpans = input.offWrist.sorted { $0.start < $1.start }
        let workouts = input.workouts.sorted { $0.start < $1.start }
        let workoutKinds = workouts.map { WorkoutKind(sport: $0.sport) }
        var sleepCursor = 0, offCursor = 0, workoutCursor = 0

        func inside<S>(_ spans: [S], _ cursor: inout Int, _ ts: Int, start: (S) -> Int, end: (S) -> Int) -> Bool {
            while cursor < spans.count, end(spans[cursor]) <= ts { cursor += 1 }
            return cursor < spans.count && start(spans[cursor]) <= ts && ts < end(spans[cursor])
        }

        var out: [ActivityObservation] = []
        out.reserveCapacity(hi - lo)
        for ts in lo..<hi {
            let isOff = inside(offSpans, &offCursor, ts, start: \.start, end: \.end)
            let hasData = hrAt[ts] != nil || gravAt[ts] != nil || classAt[ts] != nil || tickAt[ts] != nil
                || encoderAt[ts] != nil || imuAt[ts] != nil
            guard isOff || hasData else { continue }

            var o = ActivityObservation(ts: ts)
            if isOff {
                o.wear = .offWrist
                out.append(o)
                continue
            }
            o.wear = .onWrist
            if let g = gravAt[ts] {
                o.gravity = [g.x, g.y, g.z]
                o.dynAccelG = g.dynAccel
            }
            o.hrBpm = hrAt[ts]
            o.stepTicks = tickAt[ts]
            o.strapClass = classAt[ts]
            o.encoder = encoderAt[ts]
            o.imu = imuAt[ts]
            if inside(sleepSpans, &sleepCursor, ts, start: \.start, end: \.end) {
                o.sleep = .asleep
            } else {
                o.sleep = input.sleepKnownOutsideSessions ? .awake : .unknown
            }
            if inside(workouts, &workoutCursor, ts, start: \.start, end: \.end) {
                o.loggedWorkout = true
                o.workoutKind = workoutKinds[workoutCursor]
            }
            out.append(o)
        }
        return out
    }
}

// MARK: - Runs (compact persistence)

/// A stretch of consecutive published states that carry the same belief at the resolution worth keeping.
/// Probabilities are the mean over the stretch, so a run is a faithful summary rather than its first tick.
/// Transition events are not part of a run: they are short and listed once, in the document's `events`.
public struct ActivityContextRun: Codable, Equatable, Sendable {
    /// First published second and one past the last (the states describe evidence up to their `ts`).
    public var start: Int
    public var end: Int
    public var posture: HeadProbabilities<PostureClass>
    public var locomotion: HeadProbabilities<LocomotionClass>
    public var armBehavior: HeadProbabilities<ArmBehaviorClass>
    public var intensity: Double?
    public var overallConfidence: Double
    public var overallUncertainty: Double
    public var displayContext: String?
    public var sleep: SleepContextState
    public var wear: WearContextState
    /// Published states merged into the run.
    public var count: Int

    public init(start: Int, end: Int, posture: HeadProbabilities<PostureClass>,
                locomotion: HeadProbabilities<LocomotionClass>, armBehavior: HeadProbabilities<ArmBehaviorClass>,
                intensity: Double?, overallConfidence: Double, overallUncertainty: Double,
                displayContext: String?, sleep: SleepContextState, wear: WearContextState, count: Int) {
        self.start = start; self.end = end; self.posture = posture; self.locomotion = locomotion
        self.armBehavior = armBehavior; self.intensity = intensity
        self.overallConfidence = overallConfidence; self.overallUncertainty = overallUncertainty
        self.displayContext = displayContext; self.sleep = sleep; self.wear = wear; self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case start = "s", end = "e", posture, locomotion
        case armBehavior = "arm_behavior"
        case intensity
        case overallConfidence = "overall_confidence", overallUncertainty = "overall_uncertainty"
        case displayContext = "display_context", sleep, wear, count = "n"
        // Derived on write from the fields above (`ActivityClassifier`), never read back: the document
        // carries them so SQL and other readers get the canonical class without re-implementing the mapping.
        case activityClass = "activity_class", classConfidence = "class_confidence"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        posture = try c.decode(HeadProbabilities<PostureClass>.self, forKey: .posture)
        locomotion = try c.decode(HeadProbabilities<LocomotionClass>.self, forKey: .locomotion)
        armBehavior = try c.decode(HeadProbabilities<ArmBehaviorClass>.self, forKey: .armBehavior)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
        overallConfidence = try c.decode(Double.self, forKey: .overallConfidence)
        overallUncertainty = try c.decode(Double.self, forKey: .overallUncertainty)
        displayContext = try c.decodeIfPresent(String.self, forKey: .displayContext)
        sleep = try c.decode(SleepContextState.self, forKey: .sleep)
        wear = try c.decode(WearContextState.self, forKey: .wear)
        count = try c.decode(Int.self, forKey: .count)
    }

    /// The canonical class of the run (see `ActivityClassifier`).
    public var classification: ActivityClassification { ActivityClassifier.classify(run: self) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(posture, forKey: .posture)
        try c.encode(locomotion, forKey: .locomotion)
        try c.encode(armBehavior, forKey: .armBehavior)
        if let intensity { try c.encode((intensity * 100).rounded() / 100, forKey: .intensity) }
        else { try c.encodeNil(forKey: .intensity) }
        try c.encode((overallConfidence * 100).rounded() / 100, forKey: .overallConfidence)
        try c.encode((overallUncertainty * 100).rounded() / 100, forKey: .overallUncertainty)
        if let displayContext { try c.encode(displayContext, forKey: .displayContext) }
        else { try c.encodeNil(forKey: .displayContext) }
        try c.encode(sleep, forKey: .sleep)
        try c.encode(wear, forKey: .wear)
        try c.encode(count, forKey: .count)
        let k = classification
        try c.encode(k.activityClass.rawValue, forKey: .activityClass)
        try c.encode((k.confidence * 100).rounded() / 100, forKey: .classConfidence)
    }

    /// The run as the canonical published-state shape (provenance fields are carried by the document).
    public func state(at ts: Int, transition: ActivityTransitionEvent? = nil,
                      versions: ActivityStateVersions) -> ActivityContextState {
        func top<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>, _ unknown: C) -> Double
            where C.RawValue == String { h.top(excluding: unknown)?.1 ?? 0 }
        return ActivityContextState(
            ts: ts, posture: posture, locomotion: locomotion, armBehavior: armBehavior,
            intensity: intensity, transition: transition,
            sleep: SleepContext(state: sleep), wear: WearContext(state: wear, validity: wear == .offWrist ? 0 : 1),
            overallConfidence: overallConfidence, overallUncertainty: overallUncertainty,
            headConfidence: ActivityHeadConfidence(posture: top(posture, .unknown),
                                                   locomotion: top(locomotion, .unknown),
                                                   armBehavior: top(armBehavior, .unknown)),
            displayContext: displayContext,
            history: ActivityHistorySummary(sinceLocomotionS: nil, stationaryForS: 0, recentEvents: []),
            evidence: ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: false, gravity: false,
                                              steps: false, heartRate: false, sleep: false, coverage: 0),
            versions: versions)
    }
}

public enum ActivityContextRuns {

    /// Largest summed probability difference, per head, between a state and its run's mean for the state to
    /// join the run. Comparing to the mean (rather than bucketing) keeps a value that hovers on a bucket
    /// edge from splitting the run every few seconds.
    static let headTolerance = 0.45

    /// Coalesce consecutive states that describe the same situation: same display label, same wear and
    /// sleep context, and the body heads (posture, locomotion) within `headTolerance` of the run's mean.
    /// The arm head is a fast hand pattern that flips between desk-like, quiet and fidgeting every few
    /// seconds inside one situation, so it does not split a run: the run keeps its average.
    public static func coalesce(_ states: [ActivityContextState], intervalS: Int = 5) -> [ActivityContextRun] {
        var runs: [ActivityContextRun] = []
        var acc: Accumulator?
        let maxGap = max(intervalS, 1) * 2
        for s in states {
            if var a = acc, a.accepts(s, maxGap: maxGap) {
                a.add(s)
                acc = a
            } else {
                if let a = acc { runs.append(a.run(intervalS: intervalS)) }
                acc = Accumulator(first: s)
            }
        }
        if let a = acc { runs.append(a.run(intervalS: intervalS)) }
        return foldFragments(runs, maxFragmentS: 2 * max(intervalS, 1))
    }

    /// A run of a couple of ticks that sits next to a run with the same label, wear and sleep context is a
    /// wobble inside that situation (a posture head dipping for one tick), not a separate one: fold it in.
    static func foldFragments(_ runs: [ActivityContextRun], maxFragmentS: Int) -> [ActivityContextRun] {
        func sameSituation(_ a: ActivityContextRun, _ b: ActivityContextRun) -> Bool {
            a.displayContext == b.displayContext && a.wear == b.wear && a.sleep == b.sleep && b.start - a.end <= 10
        }
        var out: [ActivityContextRun] = []
        var i = 0
        while i < runs.count {
            var r = runs[i]
            if r.end - r.start <= maxFragmentS {
                if let prev = out.last, sameSituation(prev, r) {
                    out[out.count - 1] = merged(prev, r)
                    i += 1
                    continue
                }
                if i + 1 < runs.count, sameSituation(r, runs[i + 1]) {
                    r = merged(r, runs[i + 1])
                    i += 2
                    out.append(r)
                    continue
                }
            }
            out.append(r)
            i += 1
        }
        return out
    }

    /// Two adjacent runs as one, probabilities averaged by the number of states each covers.
    static func merged(_ first: ActivityContextRun, _ second: ActivityContextRun) -> ActivityContextRun {
        var last = first
        let a = Double(first.count), b = Double(second.count), n = a + b
        func mix<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ x: HeadProbabilities<C>, _ y: HeadProbabilities<C>) -> HeadProbabilities<C>
            where C.RawValue == String {
            var m: [C: Double] = [:]
            for c in C.allCases { m[c] = (x[c] * a + y[c] * b) / n }
            return HeadProbabilities(m)
        }
        last.posture = mix(first.posture, second.posture)
        last.locomotion = mix(first.locomotion, second.locomotion)
        last.armBehavior = mix(first.armBehavior, second.armBehavior)
        if let x = first.intensity, let y = second.intensity { last.intensity = (x * a + y * b) / n }
        else { last.intensity = first.intensity ?? second.intensity }
        last.overallConfidence = (first.overallConfidence * a + second.overallConfidence * b) / n
        last.overallUncertainty = (first.overallUncertainty * a + second.overallUncertainty * b) / n
        last.end = second.end
        last.count = first.count + second.count
        return last
    }

    /// Re-expand runs into one state per interval (lossy only by the run averaging). Events are laid back
    /// on the ticks they were held for.
    public static func expand(_ runs: [ActivityContextRun], events: [ActivityTransitionEvent] = [],
                              versions: ActivityStateVersions, intervalS: Int = 5,
                              eventHoldS: Int = 15) -> [ActivityContextState] {
        var out: [ActivityContextState] = []
        let step = max(1, intervalS)
        let ordered = events.sorted { $0.ts < $1.ts }
        var cursor = 0
        for r in runs {
            var t = r.start
            while t < r.end {
                while cursor < ordered.count, ordered[cursor].ts + eventHoldS <= t { cursor += 1 }
                let event = cursor < ordered.count && ordered[cursor].ts <= t ? ordered[cursor] : nil
                out.append(r.state(at: t, transition: event, versions: versions))
                t += step
            }
        }
        return out
    }

    /// `new` after `old`, folding the last old run into the first new one when they describe the same
    /// situation without a gap, so repeatedly extending a day does not leave a seam at every extension.
    public static func append(_ old: [ActivityContextRun], _ new: [ActivityContextRun]) -> [ActivityContextRun] {
        guard let last = old.last, let first = new.first else { return old + new }
        guard first.start - last.end <= 5, last.displayContext == first.displayContext,
              last.wear == first.wear, last.sleep == first.sleep,
              distance(last.posture, first.posture) <= headTolerance,
              distance(last.locomotion, first.locomotion) <= headTolerance else { return old + new }
        var out = Array(old.dropLast())
        out.append(merged(last, first))
        out.append(contentsOf: new.dropFirst())
        return out
    }

    static func distance<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ x: HeadProbabilities<C>, _ y: HeadProbabilities<C>) -> Double
        where C.RawValue == String {
        C.allCases.reduce(0) { $0 + abs(x[$1] - y[$1]) }
    }

    private struct Accumulator {
        var first: ActivityContextState
        var lastTs: Int
        var count = 0
        var posture: [PostureClass: Double] = [:]
        var locomotion: [LocomotionClass: Double] = [:]
        var arm: [ArmBehaviorClass: Double] = [:]
        var intensitySum = 0.0, intensityN = 0
        var confidenceSum = 0.0, uncertaintySum = 0.0

        init(first: ActivityContextState) {
            self.first = first; self.lastTs = first.ts
            add(first)
        }

        func accepts(_ s: ActivityContextState, maxGap: Int) -> Bool {
            guard s.ts - lastTs <= maxGap, s.displayContext == first.displayContext,
                  s.wear.state == first.wear.state, s.sleep.state == first.sleep.state else { return false }
            let n = Double(count)
            func far<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>, _ sums: [C: Double]) -> Bool
                where C.RawValue == String {
                C.allCases.reduce(0) { $0 + abs(h[$1] - (sums[$1] ?? 0) / n) } > ActivityContextRuns.headTolerance
            }
            return !(far(s.posture, posture) || far(s.locomotion, locomotion))
        }

        mutating func add(_ s: ActivityContextState) {
            count += 1
            lastTs = s.ts
            for c in PostureClass.allCases { posture[c, default: 0] += s.posture[c] }
            for c in LocomotionClass.allCases { locomotion[c, default: 0] += s.locomotion[c] }
            for c in ArmBehaviorClass.allCases { arm[c, default: 0] += s.armBehavior[c] }
            if let i = s.intensity { intensitySum += i; intensityN += 1 }
            confidenceSum += s.overallConfidence
            uncertaintySum += s.overallUncertainty
        }

        func run(intervalS: Int) -> ActivityContextRun {
            let n = Double(count)
            // Mean over the stretch, thin classes dropped and the rest renormalized: a run is a summary, and
            // a long tail of 1–2 % entries only costs bytes.
            func head<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ sums: [C: Double], floor: Double) -> HeadProbabilities<C>
                where C.RawValue == String {
                HeadProbabilities(sums.mapValues { $0 / n }.filter { $0.value >= floor }).normalized()
            }
            return ActivityContextRun(
                start: first.ts, end: lastTs + max(1, intervalS),
                posture: head(posture, floor: 0.02),
                locomotion: head(locomotion, floor: 0.02),
                armBehavior: head(arm, floor: 0.04),
                intensity: intensityN > 0 ? intensitySum / Double(intensityN) : nil,
                overallConfidence: confidenceSum / n, overallUncertainty: uncertaintySum / n,
                displayContext: first.displayContext, sleep: first.sleep.state, wear: first.wear.state, count: count)
        }
    }
}

// MARK: - Day document

public struct ActivityContextDaySummary: Codable, Equatable, Sendable {
    /// Seconds spent under each display label (the unlabelled remainder is `unclear_s`).
    public var labelSeconds: [String: Int]
    public var unclearSeconds: Int
    public var meanConfidence: Double
    /// Seconds per canonical `ActivityClass` code (every class, `unknown` included). nil on documents
    /// written before the taxonomy existed.
    public var classSeconds: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case labelSeconds = "label_s", unclearSeconds = "unclear_s", meanConfidence = "mean_confidence"
        case classSeconds = "class_s"
    }

    public init(labelSeconds: [String: Int], unclearSeconds: Int, meanConfidence: Double,
                classSeconds: [String: Int]? = nil) {
        self.labelSeconds = labelSeconds; self.unclearSeconds = unclearSeconds; self.meanConfidence = meanConfidence
        self.classSeconds = classSeconds
    }

    public init(runs: [ActivityContextRun]) {
        var labelSeconds: [String: Int] = [:]
        var classSeconds: [String: Int] = [:]
        var unclear = 0
        var confSum = 0.0
        var total = 0
        for r in runs {
            let seconds = r.end - r.start
            if let l = r.displayContext { labelSeconds[l, default: 0] += seconds } else { unclear += seconds }
            classSeconds[ActivityClassifier.classify(run: r).activityClass.rawValue, default: 0] += seconds
            confSum += r.overallConfidence * Double(seconds)
            total += seconds
        }
        self.init(labelSeconds: labelSeconds, unclearSeconds: unclear,
                  meanConfidence: (confSum / Double(max(1, total)) * 1000).rounded() / 1000,
                  classSeconds: classSeconds)
    }
}

/// The persisted, versioned form of one day's ActivityContext. Additive over the v1 document: nothing
/// here changes what v1 readers see.
public struct ActivityContextDayDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var versions: ActivityStateVersions
    public var dayStart: Int
    public var dayEnd: Int
    public var publishIntervalS: Int
    /// Unix seconds when the document was computed.
    public var generatedAt: Int
    /// One past the last second of input the decoder consumed.
    public var dataThrough: Int?
    /// Seconds of input the decoder consumed to get here. A later run compares this with what the stored
    /// streams now hold before the covered span (data that arrived late) to decide whether to continue.
    public var observedSeconds: Int
    /// Whether time outside logged sleep was treated as awake (a finished day) or unknown (a live one).
    public var sleepKnownOutsideSessions: Bool
    /// Hash of the sleep, workout and off-wrist spans inside the covered range. Editing a night, adding a
    /// workout or a late wrist-off event changes it, and the day is then decoded again from the start.
    public var contextFingerprint: String?
    public var runs: [ActivityContextRun]
    public var events: [ActivityTransitionEvent]
    public var latest: ActivityContextState?
    public var summary: ActivityContextDaySummary
    /// Decoder state after the last observation (restart / continuation). Opaque to readers.
    public var snapshot: ActivityDecoderSnapshot?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", versions
        case dayStart = "day_start", dayEnd = "day_end", publishIntervalS = "publish_interval_s"
        case generatedAt = "generated_at", dataThrough = "data_through", observedSeconds = "observed_s"
        case sleepKnownOutsideSessions = "sleep_known_outside", contextFingerprint = "context_fp"
        case runs, events, latest, summary, snapshot
    }

    public init(track: ActivityContextTrack, input: ActivityContextTrackInput, generatedAt: Int,
                config: ActivityDecoderConfig = ActivityDecoderConfig(), includeSnapshot: Bool = true) {
        let interval = max(1, config.publishIntervalS)
        let runs = ActivityContextRuns.coalesce(track.states, intervalS: interval)
        self.schemaVersion = ActivityContextVersions.schema
        self.versions = track.snapshot.versions
        self.dayStart = input.dayStart; self.dayEnd = input.dayEnd
        self.publishIntervalS = interval
        self.generatedAt = generatedAt
        self.dataThrough = track.lastTs.map { $0 + 1 }
        self.observedSeconds = track.observedSeconds
        self.sleepKnownOutsideSessions = input.sleepKnownOutsideSessions
        self.contextFingerprint = ActivityContextDayBuilder.fingerprint(input, through: track.lastTs.map { $0 + 1 })
        self.runs = runs
        self.events = track.events
        self.latest = track.states.last
        self.summary = ActivityContextDaySummary(runs: runs)
        self.snapshot = includeSnapshot ? track.snapshot : nil
    }

    /// True when this document was written by the current ontology / decoder / feature schema, so it can
    /// be shown and its snapshot resumed. Anything else must be recomputed from the source streams.
    public var isCurrent: Bool {
        schemaVersion == ActivityContextVersions.schema
            && versions.ontology == ActivityContextVersions.ontology
            && versions.decoder == ActivityContextVersions.decoder
            && versions.featureSchema == ActivityContextVersions.featureSchema
    }
}

// MARK: - Keeping a day's document up to date

public enum ActivityContextDayUpdate: Equatable, Sendable {
    /// Nothing new since the stored document; it is returned as it was.
    case reused
    /// The stored decoder state was restored and only the new seconds were decoded.
    case resumed(fromTs: Int)
    /// Decoded from the start of the day, for the stated reason.
    case recomputed(reason: String)
}

public enum ActivityContextDayBuilder {

    /// FNV-1a over the sleep, workout and off-wrist spans clipped to `[dayStart, through)`. Spans are clipped
    /// so a stretch still open at `through` hashes the same once the day has grown past it.
    static func fingerprint(_ input: ActivityContextTrackInput, through: Int?) -> String {
        let hi = min(through ?? input.dayEnd, input.dayEnd)
        func clipped(_ spans: [(Int, Int)]) -> [String] {
            spans.compactMap { s, e -> String? in
                let lo = max(s, input.dayStart), end = min(e, hi)
                return end > lo ? "\(lo)-\(end)" : nil
            }.sorted()
        }
        let text = "s:" + clipped(input.sleep.map { ($0.start, $0.end) }).joined(separator: ",")
            + "|w:" + clipped(input.workouts.map { ($0.start, $0.end) }).joined(separator: ",")
            + "|o:" + clipped(input.offWrist.map { ($0.start, $0.end) }).joined(separator: ",")
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Bring a day's document up to date with the streams now stored. Continues the stored decoder when the
    /// stored span is unchanged (same ontology / decoder, same number of observed seconds before the cut),
    /// and decodes the whole day otherwise: a newer ontology or decoder, a different day, or data that
    /// arrived late inside the already-covered span (a backfill) would otherwise be silently missed.
    ///
    /// `progress` is for the one case that takes noticeable time, decoding a whole day from scratch. When it
    /// is given, the day is decoded in pieces of `chunkObservations` seconds and every finished piece before
    /// the last reports the day so far (without a decoder snapshot, so it can be shown but never stored). The
    /// returned document is the same as the one an uninterrupted decode produces.
    public static func update(cached: ActivityContextDayDocument?, input: ActivityContextTrackInput, now: Int,
                              config: ActivityDecoderConfig = ActivityDecoderConfig(),
                              chunkObservations: Int = 3_600,
                              progress: ((ActivityContextDayDocument) -> Void)? = nil)
        -> (document: ActivityContextDayDocument, how: ActivityContextDayUpdate) {
        let all = ActivityContextTrackBuilder.observations(for: input)

        func fresh(_ reason: String) -> (ActivityContextDayDocument, ActivityContextDayUpdate) {
            let document = decodeFromStart(all, input: input, now: now, config: config,
                                           chunkObservations: chunkObservations, progress: progress)
            return (document, .recomputed(reason: reason))
        }

        guard let cached else { return fresh("no_cache") }
        guard cached.isCurrent else { return fresh("version_changed") }
        guard cached.dayStart == input.dayStart else { return fresh("day_changed") }
        guard cached.publishIntervalS == max(1, config.publishIntervalS) else { return fresh("config_changed") }
        guard let through = cached.dataThrough, let snapshot = cached.snapshot else { return fresh("no_snapshot") }
        guard cached.sleepKnownOutsideSessions == input.sleepKnownOutsideSessions else { return fresh("sleep_context_changed") }
        guard cached.contextFingerprint == fingerprint(input, through: through) else { return fresh("context_changed") }

        let covered = all.prefix { $0.ts < through }.count
        guard covered == cached.observedSeconds else { return fresh("late_data") }
        let newer = Array(all.dropFirst(covered))
        guard !newer.isEmpty else {
            var same = cached
            same.dayEnd = max(cached.dayEnd, input.dayEnd)
            return (same, .reused)
        }

        let track = ActivityContextTrackBuilder.decode(newer, config: config, resuming: snapshot)
        guard track.restore == .resumed else { return fresh("restore_\(track.restore)") }

        var doc = cached
        let interval = cached.publishIntervalS
        doc.runs = ActivityContextRuns.append(cached.runs, ActivityContextRuns.coalesce(track.states, intervalS: interval))
        for e in track.events {
            if let i = doc.events.lastIndex(where: { $0.kind == e.kind && $0.ts == e.ts }) {
                doc.events[i].probability = max(doc.events[i].probability, e.probability)
            } else {
                doc.events.append(e)
            }
        }
        doc.latest = track.states.last ?? cached.latest
        doc.dayEnd = max(cached.dayEnd, input.dayEnd)
        doc.generatedAt = now
        doc.dataThrough = track.lastTs.map { $0 + 1 } ?? cached.dataThrough
        doc.observedSeconds = cached.observedSeconds + track.observedSeconds
        doc.contextFingerprint = fingerprint(input, through: doc.dataThrough)
        doc.snapshot = track.snapshot
        doc.versions = track.snapshot.versions
        doc.summary = ActivityContextDaySummary(runs: doc.runs)
        return (doc, .resumed(fromTs: through))
    }

    /// Decode a day from its first second. Without `progress` this is one pass. With it, the observations
    /// go through the decoder in pieces, each continuing from the snapshot the one before left, and the
    /// pieces are joined as tracks so the final document is built exactly as an uninterrupted decode builds it.
    static func decodeFromStart(_ all: [ActivityObservation], input: ActivityContextTrackInput, now: Int,
                                config: ActivityDecoderConfig, chunkObservations: Int,
                                progress: ((ActivityContextDayDocument) -> Void)?) -> ActivityContextDayDocument {
        let size = max(60, chunkObservations)
        guard let progress, all.count > size else {
            let track = ActivityContextTrackBuilder.decode(all, config: config)
            return ActivityContextDayDocument(track: track, input: input, generatedAt: now, config: config)
        }
        var track: ActivityContextTrack?
        var offset = 0
        while offset < all.count {
            let end = min(all.count, offset + size)
            let piece = ActivityContextTrackBuilder.decode(Array(all[offset..<end]), config: config,
                                                           resuming: track?.snapshot)
            let joined = track?.appending(piece) ?? piece
            track = joined
            offset = end
            if offset < all.count {
                var sofar = input
                sofar.dayEnd = (joined.lastTs ?? input.dayStart) + 1
                progress(ActivityContextDayDocument(track: joined, input: sofar, generatedAt: now,
                                                    config: config, includeSnapshot: false))
            }
        }
        return ActivityContextDayDocument(track: track ?? ActivityContextTrackBuilder.decode([], config: config),
                                          input: input, generatedAt: now, config: config)
    }
}


// MARK: - Episodes (what a timeline shows)

/// Consecutive runs under one display label, as the stretches a person would describe.
public struct ActivityEpisode: Equatable, Sendable, Identifiable {
    public var start: Int
    public var end: Int
    /// The display label, or "Unclear" when the evidence did not support one.
    public var label: String
    public var posture: HeadProbabilities<PostureClass>
    public var locomotion: HeadProbabilities<LocomotionClass>
    public var armBehavior: HeadProbabilities<ArmBehaviorClass>
    public var intensity: Double?
    public var confidence: Double
    public var uncertainty: Double
    public var sleep: SleepContextState
    public var wear: WearContextState

    public var id: Int { start }
    public var durationSeconds: Int { end - start }
}

public enum ActivityContextEpisodes {
    public static let unclear = "Unclear"

    /// Join consecutive runs that carry the same label, wear and sleep context (allowing a small gap).
    public static func build(_ runs: [ActivityContextRun], maxGapS: Int = 10) -> [ActivityEpisode] {
        var joined: [ActivityContextRun] = []
        for r in runs {
            if let last = joined.last, last.displayContext == r.displayContext, last.wear == r.wear,
               last.sleep == r.sleep, r.start - last.end <= maxGapS {
                joined[joined.count - 1] = ActivityContextRuns.merged(last, r)
            } else {
                joined.append(r)
            }
        }
        return joined.map {
            ActivityEpisode(start: $0.start, end: $0.end, label: $0.displayContext ?? unclear,
                            posture: $0.posture, locomotion: $0.locomotion, armBehavior: $0.armBehavior,
                            intensity: $0.intensity, confidence: $0.overallConfidence,
                            uncertainty: $0.overallUncertainty, sleep: $0.sleep, wear: $0.wear)
        }
    }
}
