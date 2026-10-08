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
    /// Sleep: each night's sleep epochs, the staged hypnogram's non-wake stretches (`DayStateSpan.asleep`).
    /// A caller that only has whole sessions may pass those, at the cost of lying awake in bed reading as
    /// asleep.
    public var sleep: [DayStateSpan]
    /// Each night's in-bed window, the whole detected session: lying awake inside it is "in bed".
    public var inBed: [DayStateSpan]
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
    /// Optional learned raw-IMU transition-expert output (see `Tools/ActivityContext`), one entry per
    /// 4-s window, model-agnostic. Attached by end second exactly like `encoderWindows`; absent when
    /// the expert did not run for the day (the decoder's no-model fallback then stays in charge).
    public var transitionWindows: [ActivityTransitionWindow]
    /// Optional Inertia-1 motion-head windows and their bundle. Used only when the decode's
    /// `ActivityDecoderConfig.motionHeads` accepts the same bundle; otherwise nothing is attached.
    public var motionHeads: MotionHeadsTrackInput?
    /// Optional ElderNet gait-quality windows and their model. Used only when the decode's
    /// `ActivityDecoderConfig.gaitQuality` accepts the same model; otherwise nothing is attached.
    public var gaitQuality: GaitQualityTrackInput?
    /// Optional in-process ElderNet gait-expert windows (10 s, own hop), attached by end second. Ignored on
    /// any second where the gait-quality channel above is present.
    public var gaitWindows: [ActivityGaitWindow]

    public init(dayStart: Int, dayEnd: Int,
                hr: [HRSample] = [], gravity: [GravitySample] = [], steps: [StepSample] = [],
                sleep: [DayStateSpan] = [], inBed: [DayStateSpan] = [], sleepKnownOutsideSessions: Bool = true,
                workouts: [DayStateWorkout] = [], offWrist: [DayStateSpan] = [],
                encoderWindows: [ActivityWindowPrediction] = [],
                encoderId: String = "hart", encoderVersion: String = "unknown",
                imuWindows: [ImuWindowFeatures] = [],
                transitionWindows: [ActivityTransitionWindow] = [], motionHeads: MotionHeadsTrackInput? = nil,
                gaitQuality: GaitQualityTrackInput? = nil,
                gaitWindows: [ActivityGaitWindow] = []) {
        self.dayStart = dayStart; self.dayEnd = dayEnd
        self.hr = hr; self.gravity = gravity; self.steps = steps
        self.sleep = sleep; self.inBed = inBed; self.sleepKnownOutsideSessions = sleepKnownOutsideSessions
        self.workouts = workouts; self.offWrist = offWrist
        self.encoderWindows = encoderWindows; self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.imuWindows = imuWindows; self.transitionWindows = transitionWindows
        self.motionHeads = motionHeads; self.gaitQuality = gaitQuality
        self.gaitWindows = gaitWindows
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
    /// How Inertia-1 windows were attached and used, or why they were not (nil without a motion-heads config).
    public var motionHeads: MotionHeadsTrackReport? = nil
    /// How ElderNet windows were attached and used, or why they were not (nil without a gait config).
    public var gaitQuality: GaitQualityTrackReport? = nil

    /// This track followed by one that continued it from `snapshot` (events the decoder keeps flagging
    /// across the join are listed once).
    public func appending(_ next: ActivityContextTrack) -> ActivityContextTrack {
        let merged = ActivityTransitionEvent.merging(events, next.events)
        var report = motionHeads
        if let n = next.motionHeads { report = report?.merged(with: n) ?? n }
        var gait = gaitQuality
        if let n = next.gaitQuality { gait = gait?.continued(by: n) ?? n }
        return ActivityContextTrack(states: states + next.states, events: merged, snapshot: next.snapshot,
                                    restore: restore, observedSeconds: observedSeconds + next.observedSeconds,
                                    lastTs: next.lastTs ?? lastTs, motionHeads: report, gaitQuality: gait)
    }
}

// MARK: - Builder

public enum ActivityContextTrackBuilder {

    /// Decode `[dayStart, dayEnd)`. Pass the snapshot from a previous run to continue it: observations at
    /// or before the snapshot's last second are ignored, later ones continue the same belief.
    public static func build(_ input: ActivityContextTrackInput,
                             config: ActivityDecoderConfig = ActivityDecoderConfig(),
                             resuming snapshot: ActivityDecoderSnapshot? = nil) -> ActivityContextTrack {
        let prepared = observationsWithReports(for: input, config: config)
        var track = decode(prepared.observations, config: effectiveConfig(for: input, config: config), resuming: snapshot)
        if let attach = prepared.motionHeads {
            track.motionHeads = attach.merged(with: track.motionHeads ?? MotionHeadsTrackReport())
        }
        if let attach = prepared.gaitQuality {
            track.gaitQuality = attach.continued(by: track.gaitQuality ?? GaitQualityTrackReport())
        }
        return track
    }

    /// Whether `config`'s ElderNet evidence is actually accepted for `input`: the config accepts its model and the
    /// input carries windows from exactly that model.
    public static func acceptsGaitQuality(for input: ActivityContextTrackInput, config: ActivityDecoderConfig) -> Bool {
        guard let gait = config.gaitQuality, gait.evidenceRefusal == nil, let g = input.gaitQuality else { return false }
        return g.model == gait.model
    }

    /// Whether `config`'s Inertia evidence is actually accepted for `input`: the config accepts its bundle and
    /// the input carries windows from exactly that bundle.
    public static func acceptsMotionHeads(for input: ActivityContextTrackInput, config: ActivityDecoderConfig) -> Bool {
        guard let heads = config.motionHeads, heads.evidenceRefusal == nil, let mh = input.motionHeads else { return false }
        return mh.bundle.bundleSha256 == heads.bundle.bundleSha256 && mh.bundle == heads.bundle
    }

    /// The config a decode of `input` actually runs with: `config` itself when it has no motion-heads entry or
    /// when its Inertia evidence is accepted for this input (`acceptsMotionHeads`), and otherwise `config`
    /// without the entry. So the `inertia-1:` / `standin-test:` stamp, the held window in the snapshot and the
    /// cache-tag suffix appear only on a track Inertia evidence really shaped; a refused config, a bundle
    /// mismatch or an input without windows decodes (and is keyed) exactly like Inertia off.
    ///
    /// The same holds for the ElderNet entry (`acceptsGaitQuality`): no `eldernet:` stamp, held window, gait
    /// block or `-eg` suffix unless its evidence really shaped the track.
    public static func effectiveConfig(for input: ActivityContextTrackInput, config: ActivityDecoderConfig)
        -> ActivityDecoderConfig {
        var plain = config
        if config.motionHeads != nil, !acceptsMotionHeads(for: input, config: config) { plain.motionHeads = nil }
        if config.gaitQuality != nil, !acceptsGaitQuality(for: input, config: config) { plain.gaitQuality = nil }
        return plain
    }

    /// What attaching `windows` to `input`'s observed seconds would do, whatever any config says (the worker's
    /// shadow rows report it so window/second alignment can be checked before Inertia is ever evidence).
    public static func attachmentReport(for input: ActivityContextTrackInput,
                                        windows: [MotionHeadsWindow]) -> MotionHeadsTrackReport {
        var report = MotionHeadsTrackReport()
        report.windowsIn = windows.count
        var out = observations(for: input)
        attachMotionHeads(windows, to: &out, lo: input.dayStart, hi: input.dayEnd, report: &report)
        return report
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
        // Every event the decoder flags, drained from its own history after each second (D2-01): a published
        // state shows at most one event, so harvesting `state.transition` lost the earlier of two events inside
        // one 5-s tick and kept a postural event at the probability it had when last shown, not its peak. Events
        // restored with a snapshot were harvested by the decode that wrote it; they are listed again only if they
        // change. The same rule as `ActivityTransitionEvent.merging`: a newer reading replaces kind, onset and
        // source and keeps the higher probability.
        var seen = decoder.recordedEvents
        for o in observations {
            if let floor, o.ts <= floor { continue }
            accepted += 1
            let s = decoder.ingest(o)
            let now = decoder.recordedEvents
            if now != seen {
                for e in now where !seen.contains(e) {
                    let key = e.identity
                    if let i = index[key] {
                        let p = max(events[i].probability, e.probability)
                        events[i] = e
                        events[i].probability = p
                    } else {
                        index[key] = events.count
                        events.append(e)
                    }
                }
                seen = now
            }
            if let s { states.append(s) }
        }
        return ActivityContextTrack(states: states, events: events, snapshot: decoder.snapshot(),
                                    restore: decoder.restoreOutcome, observedSeconds: accepted,
                                    lastTs: decoder.lastObservationTs, motionHeads: decoder.motionHeadsReport,
                                    gaitQuality: decoder.gaitQualityReport)
    }

    /// The observations for `input` with its Inertia windows attached when `config.motionHeads` accepts their
    /// bundle (the same digest) — exactly `observations(for:)` otherwise. The report says what was attached
    /// and dropped, or why nothing was (nil when the config has no motion-heads entry at all).
    ///
    /// ElderNet windows are attached the same way when `config.gaitQuality` accepts their model
    /// (`observationsWithReports` also returns that report).
    public static func observations(for input: ActivityContextTrackInput, config: ActivityDecoderConfig)
        -> (observations: [ActivityObservation], report: MotionHeadsTrackReport?) {
        let prepared = observationsWithReports(for: input, config: config)
        return (prepared.observations, prepared.motionHeads)
    }

    /// `observations(for:config:)` with both attachment reports: Inertia's (nil without a motion-heads entry) and
    /// ElderNet's (nil without a gait entry).
    public static func observationsWithReports(for input: ActivityContextTrackInput, config: ActivityDecoderConfig)
        -> (observations: [ActivityObservation], motionHeads: MotionHeadsTrackReport?,
            gaitQuality: GaitQualityTrackReport?) {
        var out = observations(for: input)
        var motionReport: MotionHeadsTrackReport?
        if let heads = config.motionHeads {
            // The stamp is set only once the evidence is accepted for THIS input (config accepted, same bundle).
            var report = MotionHeadsTrackReport(stamp: nil, refusal: heads.evidenceRefusal)
            if let mh = input.motionHeads {
                report.windowsIn = mh.windows.count
                if report.refusal == nil {
                    if acceptsMotionHeads(for: input, config: config) {
                        report.stamp = heads.provenanceStamp
                        attachMotionHeads(mh.windows, to: &out, lo: input.dayStart, hi: input.dayEnd, report: &report)
                    } else {
                        report.refusal = "bundle_mismatch"
                    }
                }
            } else if report.refusal == nil {
                report.refusal = "no_motion_heads_input"
            }
            motionReport = report
        }
        var gaitReport: GaitQualityTrackReport?
        if let gait = config.gaitQuality {
            var report = GaitQualityTrackReport(stamp: nil, refusal: gait.evidenceRefusal)
            if let g = input.gaitQuality {
                report.windowsIn = g.windows.count
                if report.refusal == nil {
                    if acceptsGaitQuality(for: input, config: config) {
                        report.stamp = gait.provenanceStamp
                        attachGaitQuality(g.windows, to: &out, lo: input.dayStart, hi: input.dayEnd, report: &report)
                    } else {
                        report.refusal = "model_mismatch"
                    }
                }
            } else if report.refusal == nil {
                report.refusal = "no_gait_quality_input"
            }
            gaitReport = report
        }
        return (out, motionReport, gaitReport)
    }

    /// ElderNet never creates an observation second either: the same attachment rule as Inertia's (the first
    /// on-wrist observed second in `[e, e + 2]` inside `[lo, hi)`, the later of two windows on one second).
    static func attachGaitQuality(_ windows: [GaitQualityWindow], to out: inout [ActivityObservation],
                                  lo: Int, hi: Int, report: inout GaitQualityTrackReport) {
        guard !windows.isEmpty, hi > lo else { return }
        var indexAt: [Int: Int] = [:]
        for (i, o) in out.enumerated() where o.wear != .offWrist { indexAt[o.ts] = i }
        let ordered = windows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        for w in ordered {
            guard w.endTs < hi, w.endTs + 2 >= lo else { report.droppedOutOfRange += 1; continue }
            var target: Int?
            for ts in max(w.endTs, lo)...min(w.endTs + 2, hi - 1) {
                if let i = indexAt[ts] { target = i; break }
            }
            guard let i = target else { report.droppedNoObservation += 1; continue }
            if out[i].gaitQuality != nil { report.droppedSuperseded += 1; report.attached -= 1 }
            out[i].gaitQuality = w
            report.attached += 1
        }
    }

    /// Inertia never creates an observation second: each window is attached to the first on-wrist observed
    /// second in `[e, e + 2]` inside `[lo, hi)`, or dropped and counted. Two windows on one second keep the
    /// later one (it supersedes the other, as it would a second later).
    static func attachMotionHeads(_ windows: [MotionHeadsWindow], to out: inout [ActivityObservation],
                                  lo: Int, hi: Int, report: inout MotionHeadsTrackReport) {
        guard !windows.isEmpty, hi > lo else { return }
        var indexAt: [Int: Int] = [:]
        for (i, o) in out.enumerated() where o.wear != .offWrist { indexAt[o.ts] = i }
        let ordered = windows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        for w in ordered {
            guard w.endTs < hi, w.endTs + 2 >= lo else { report.droppedOutOfRange += 1; continue }
            var target: Int?
            for ts in max(w.endTs, lo)...min(w.endTs + 2, hi - 1) {
                if let i = indexAt[ts] { target = i; break }
            }
            guard let i = target else { report.droppedNoObservation += 1; continue }
            if out[i].motionHeads != nil { report.droppedSuperseded += 1; report.attached -= 1 }
            out[i].motionHeads = w
            report.attached += 1
        }
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
        // Valid pulse seconds (including the look-back before the day) for the wear evidence, ascending. A pulse
        // this recent is contact evidence.
        let wearPulseWindowS = 60
        let pulseTs = input.hr.filter { $0.ts < hi && $0.ts >= lo - wearPulseWindowS
            && (30...220).contains($0.bpm) }.map(\.ts).sorted()
        var pulseCursor = 0
        func lastPulseTs(atOrBefore ts: Int) -> Int? {
            while pulseCursor + 1 < pulseTs.count, pulseTs[pulseCursor + 1] <= ts { pulseCursor += 1 }
            guard pulseCursor < pulseTs.count, pulseTs[pulseCursor] <= ts else { return nil }
            return pulseTs[pulseCursor]
        }

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

        // Learned transition-expert windows, keyed by end second exactly like the encoder windows.
        var transitionAt: [Int: TransitionEncoderEvidence] = [:]
        for w in input.transitionWindows where w.endTs >= lo && w.endTs < hi {
            func classProb(_ index: Int) -> Double {
                guard index < w.probabilities.count, w.probabilities[index].isFinite else { return 0 }
                return min(1, max(0, w.probabilities[index]))
            }
            // Canonical class order: none, sit_to_stand, stand_to_sit, lie_down, get_up.
            let none = classProb(0), sitToStand = classProb(1), standToSit = classProb(2)
            let lieDown = classProb(3), getUp = classProb(4)
            transitionAt[w.endTs] = TransitionEncoderEvidence(
                none: none, sitToStand: sitToStand, standToSit: standToSit, lieDown: lieDown, getUp: getUp,
                confidence: max(none, max(sitToStand, max(standToSit, max(lieDown, getUp)))),
                modelVersion: w.modelVersion, preprocessingVersion: w.preprocessingVersion,
                abstained: w.abstained)
        }
        var gaitAt: [Int: GaitExpertEvidence] = [:]
        for w in input.gaitWindows where w.endTs >= lo && w.endTs < hi && w.gaitProb.isFinite {
            gaitAt[w.endTs] = GaitExpertEvidence(window: w)
        }

        let sleepSpans = input.sleep.sorted { $0.start < $1.start }
        let bedSpans = input.inBed.sorted { $0.start < $1.start }
        let offSpans = input.offWrist.sorted { $0.start < $1.start }
        let workouts = input.workouts.sorted { $0.start < $1.start }
        let workoutKinds = workouts.map { WorkoutKind(sport: $0.sport) }
        var sleepCursor = 0, bedCursor = 0, offCursor = 0, workoutCursor = 0

        func inside<S>(_ spans: [S], _ cursor: inout Int, _ ts: Int, start: (S) -> Int, end: (S) -> Int) -> Bool {
            while cursor < spans.count, end(spans[cursor]) <= ts { cursor += 1 }
            return cursor < spans.count && start(spans[cursor]) <= ts && ts < end(spans[cursor])
        }

        var out: [ActivityObservation] = []
        out.reserveCapacity(hi - lo)
        for ts in lo..<hi {
            let isOff = inside(offSpans, &offCursor, ts, start: \.start, end: \.end)
            let hasData = hrAt[ts] != nil || gravAt[ts] != nil || classAt[ts] != nil || tickAt[ts] != nil
                || encoderAt[ts] != nil || imuAt[ts] != nil || transitionAt[ts] != nil || gaitAt[ts] != nil
            guard isOff || hasData else { continue }

            var o = ActivityObservation(ts: ts)
            if isOff {
                o.wear = .offWrist
                out.append(o)
                continue
            }
            // On the wrist only with contact evidence: a valid pulse in the last `wearPulseWindowS` (causal, so
            // a progressive decode agrees with a whole-day one). Gravity, steps or IMU alone are no evidence
            // anyone is wearing the strap: a strap on a table has them too (D1-05, D1V-03).
            if let last = lastPulseTs(atOrBefore: ts), ts - last <= wearPulseWindowS {
                o.wear = .onWrist
            } else {
                o.wear = .unknown
            }
            if let g = gravAt[ts] {
                o.gravity = [g.x, g.y, g.z]
                o.dynAccelG = g.dynAccel
            }
            o.hrBpm = hrAt[ts]
            o.stepTicks = tickAt[ts]
            o.strapClass = classAt[ts]
            o.encoder = encoderAt[ts]
            o.imu = imuAt[ts]
            o.transition = transitionAt[ts]
            o.gait = gaitAt[ts]
            let inBedSpan = inside(bedSpans, &bedCursor, ts, start: \.start, end: \.end)
            if inside(sleepSpans, &sleepCursor, ts, start: \.start, end: \.end) {
                o.sleep = .asleep
                o.inBed = true
            } else if inBedSpan {
                // Inside the night but not on a sleep epoch: lying awake, which the stager knows.
                o.sleep = .awake
                o.inBed = true
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
    /// First published second and one past the last (the states describe evidence up to their `ts`). A boundary
    /// that a flagged event explains is back-dated to the event's onset (`ActivityContextRuns.aligned`).
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
    /// Inside a detected night's in-bed window (`SleepContext.inBed`).
    public var inBed: Bool
    public var wear: WearContextState
    /// Published states merged into the run.
    public var count: Int
    /// ElderNet's gait metrics over every gait window the run's states counted (reported, not evidence). nil
    /// (and absent from the JSON) unless the decode had the gait channel and its states carried a gait block.
    public var gait: ActivityGaitSummary?
    /// Experts that spoke during the run (`ActivityEvidenceSummary.experts`, union, fixed order).
    public var experts: [String]
    /// Mean ElderNet gait probability over the run's states that had an in-process gait reading, how many did,
    /// and the mean cadence over those that ElderNet called gait. nil / 0 without the in-process gait expert.
    public var gaitProbability: Double?
    public var gaitStates: Int
    public var gaitCadenceSpm: Double?

    public init(start: Int, end: Int, posture: HeadProbabilities<PostureClass>,
                locomotion: HeadProbabilities<LocomotionClass>, armBehavior: HeadProbabilities<ArmBehaviorClass>,
                intensity: Double?, overallConfidence: Double, overallUncertainty: Double,
                displayContext: String?, sleep: SleepContextState, inBed: Bool = false,
                wear: WearContextState, count: Int, gait: ActivityGaitSummary? = nil,
                experts: [String] = [],
                gaitProbability: Double? = nil, gaitStates: Int = 0, gaitCadenceSpm: Double? = nil) {
        self.start = start; self.end = end; self.posture = posture; self.locomotion = locomotion
        self.armBehavior = armBehavior; self.intensity = intensity
        self.overallConfidence = overallConfidence; self.overallUncertainty = overallUncertainty
        self.displayContext = displayContext; self.sleep = sleep; self.inBed = inBed; self.wear = wear
        self.count = count; self.gait = gait; self.experts = experts
        self.gaitProbability = gaitProbability; self.gaitStates = gaitStates; self.gaitCadenceSpm = gaitCadenceSpm
    }

    enum CodingKeys: String, CodingKey {
        case start = "s", end = "e", posture, locomotion
        case armBehavior = "arm_behavior"
        case intensity
        case overallConfidence = "overall_confidence", overallUncertainty = "overall_uncertainty"
        case displayContext = "display_context", sleep, inBed = "in_bed", wear, count = "n"
        case experts, gaitProbability = "gait_p", gaitStates = "gait_n", gaitCadenceSpm = "gait_cadence_spm"
        // Derived on write from the fields above (`ActivityClassifier`), never read back: the document
        // carries them so SQL and other readers get the canonical class without re-implementing the mapping.
        case activityClass = "activity_class", classConfidence = "class_confidence"
        case gait
        case activityDetail = "activity_detail", detailConfidence = "detail_confidence"
    }

    /// Canonical order of `experts` (a union keeps it).
    static let expertOrder = ["encoder", "hart_fine", "transition", "eldernet"]
    static func union(_ a: [String], _ b: [String]) -> [String] {
        let s = Set(a).union(b)
        return expertOrder.filter(s.contains) + s.subtracting(expertOrder).sorted()
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
        inBed = try c.decodeIfPresent(Bool.self, forKey: .inBed) ?? false
        wear = try c.decode(WearContextState.self, forKey: .wear)
        count = try c.decode(Int.self, forKey: .count)
        gait = try c.decodeIfPresent(ActivityGaitSummary.self, forKey: .gait)
        experts = try c.decodeIfPresent([String].self, forKey: .experts) ?? []
        gaitProbability = try c.decodeIfPresent(Double.self, forKey: .gaitProbability)
        gaitStates = try c.decodeIfPresent(Int.self, forKey: .gaitStates) ?? 0
        gaitCadenceSpm = try c.decodeIfPresent(Double.self, forKey: .gaitCadenceSpm) ?? nil
    }

    /// The canonical class of the run (see `ActivityClassifier`).
    public var classification: ActivityClassification { ActivityClassifier.classify(run: self) }

    /// The run exactly as its stored JSON reads back: probabilities to 0.001 (entries under the report floor
    /// dropped), confidence, uncertainty and intensity to 0.01, the gait fields to their stored precision. The
    /// decoder hands out runs in this form, so a run, its class and everything built from it (intervals, the
    /// day summary) are the same in memory and read back from a document.
    var quantized: ActivityContextRun {
        func r(_ x: Double, _ scale: Double) -> Double { (x * scale).rounded() / scale }
        func head<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>) -> HeadProbabilities<C>
            where C.RawValue == String {
            var m: [C: Double] = [:]
            for (c, p) in h.values where p >= HeadProbabilities<C>.reportFloor { m[c] = r(p, 1000) }
            return HeadProbabilities(m)
        }
        var q = self
        q.posture = head(posture); q.locomotion = head(locomotion); q.armBehavior = head(armBehavior)
        q.intensity = intensity.map { r($0, 100) }
        q.overallConfidence = r(overallConfidence, 100)
        q.overallUncertainty = r(overallUncertainty, 100)
        q.gaitProbability = gaitStates > 0 ? gaitProbability.map { r($0, 1000) } : nil
        q.gaitCadenceSpm = gaitCadenceSpm.map { r($0, 10) }
        // The gait summary rounds itself on write; reading it back is the one exact way to get its stored form.
        if let g = gait, let data = try? JSONEncoder().encode(g) {
            q.gait = try? JSONDecoder().decode(ActivityGaitSummary.self, from: data)
        }
        return q
    }

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
        // Written only when set, so a run outside any night encodes as it did before the field existed.
        if inBed { try c.encode(true, forKey: .inBed) }
        try c.encode(wear, forKey: .wear)
        try c.encode(count, forKey: .count)
        // Each written only when there is something to say, so a run without the experts encodes as before.
        if !experts.isEmpty { try c.encode(experts, forKey: .experts) }
        if let gaitProbability, gaitStates > 0 {
            try c.encode((gaitProbability * 1000).rounded() / 1000, forKey: .gaitProbability)
            try c.encode(gaitStates, forKey: .gaitStates)
        }
        if let gaitCadenceSpm { try c.encode((gaitCadenceSpm * 10).rounded() / 10, forKey: .gaitCadenceSpm) }
        let k = classification
        try c.encode(k.activityClass.rawValue, forKey: .activityClass)
        try c.encode((k.confidence * 100).rounded() / 100, forKey: .classConfidence)
        // Written only when present, so a run decoded without ElderNet encodes as it always did.
        if let gait { try c.encode(gait, forKey: .gait) }
        if let detail = k.detail {
            try c.encode(detail.rawValue, forKey: .activityDetail)
            try c.encode((k.detailConfidence * 100).rounded() / 100, forKey: .detailConfidence)
        }
    }

    /// The run as the canonical published-state shape (provenance fields are carried by the document).
    public func state(at ts: Int, transition: ActivityTransitionEvent? = nil,
                      versions: ActivityStateVersions) -> ActivityContextState {
        func top<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>, _ unknown: C) -> Double
            where C.RawValue == String { h.top(excluding: unknown)?.1 ?? 0 }
        return ActivityContextState(
            ts: ts, posture: posture, locomotion: locomotion, armBehavior: armBehavior,
            intensity: intensity, transition: transition,
            sleep: SleepContext(state: sleep, inBed: inBed),
            wear: WearContext(state: wear, validity: wear == .offWrist ? 0 : 1),
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

    /// Coalesce consecutive states that describe the same situation: the same canonical class at the state
    /// itself (`ActivityClassifier.runKey`, no label hysteresis), the same wear, sleep and in-bed context, and the
    /// body heads (posture, locomotion) within `headTolerance` of the run's mean. The arm head is a fast hand
    /// pattern that flips between desk-like, quiet and fidgeting every few seconds inside one situation, so it
    /// does not split a run: the run keeps its average.
    ///
    /// Runs used to split on the display label, which holds a wording for 10-30 s so a timeline does not
    /// flicker: every persisted boundary inherited that lag, and the seconds after a walk ended (already standing
    /// or sitting at the state) were stored as walking (D2-03). The label is now only a run attribute (the
    /// wording most of the run's states carried).
    ///
    /// A state's `gait` block is its walking stretch so far, so a run counts what each state ADDED to the stretch
    /// (the windows since the previous state of the same stretch): a stretch that spans two runs is split
    /// between them, never counted twice.
    public static func coalesce(_ states: [ActivityContextState], intervalS: Int = 5,
                                events: [ActivityTransitionEvent] = []) -> [ActivityContextRun] {
        coalesce(states, intervalS: intervalS, events: events, resuming: nil, final: []).runs
    }

    /// `coalesce`, continued from where an earlier pass stopped (D2-09). `tail` is the pass's open part (the raw
    /// runs of its last, still revisable runs and the run still accumulating) and `final` the runs it had already
    /// settled. The result, and the new tail, are exactly what one pass over all the states would give: a resumed
    /// day and a day decoded from scratch store the same runs, at any offload cadence.
    static func coalesce(_ states: [ActivityContextState], intervalS: Int, events: [ActivityTransitionEvent],
                         resuming tail: ActivityContextRunsTail?, final: [ActivityContextRun],
                         offWrist: [DayStateSpan] = [])
        -> (runs: [ActivityContextRun], tail: ActivityContextRunsTail) {
        // Raw runs are kept as their exact running sums (a run's JSON is rounded), so a continuation folds the
        // same numbers a single pass does.
        var rawSums = tail?.raw ?? []
        var acc = tail?.open
        let maxGap = max(intervalS, 1) * 2
        var previousGait = tail?.previousGait
        for s in states {
            var added: GaitTotals?
            if let g = s.gait {
                let now = GaitTotals(summary: g)
                if let p = previousGait, p.since == now.since, p.provenance == now.provenance, now.windows >= p.windows {
                    added = now.minus(p)
                } else {
                    added = now
                }
            }
            previousGait = s.gait.map(GaitTotals.init(summary:))
            let key = ActivityClassifier.runKey(ActivityClassifier.classify(state: s))
            if var a = acc, a.accepts(s, key: key, maxGap: maxGap) {
                a.add(s, gait: added)
                acc = a
            } else {
                if let a = acc { rawSums.append(a) }
                acc = Accumulator(first: s, key: key, gait: added)
            }
        }
        let closed = rawSums.count
        var all = rawSums.map { $0.run(intervalS: intervalS) }
        if let a = acc { all.append(a.run(intervalS: intervalS)) }
        let (unrounded, firstRaw) = foldFragmentsIndexed(all, maxFragmentS: 2 * max(intervalS, 1), events: events,
                                                         intervalS: intervalS)
        // In their stored form, so a settled run read back from the document is the run this pass produced.
        let folded = unrounded.map(\.quantized)

        // The settled runs, the last one's end put back where it was before the seam was aligned, then the rest.
        var runs = final
        if let end = tail?.finalEnd, !runs.isEmpty { runs[runs.count - 1].end = end }
        let seam = runs.count
        runs += folded
        let wearChanges = offWrist.flatMap { [$0.start, $0.end] }.sorted()
        runs = aligned(runs, to: events, intervalS: intervalS, fromBoundary: max(1, seam), wearChanges: wearChanges)

        // What stays revisable: every run holding one of the last `revisableRawRuns` raw runs (a fold decision
        // looks one raw run ahead, and the last raw run is still growing), so everything before is settled.
        let keepFrom = max(0, all.count - revisableRawRuns)
        let fj = firstRaw.lastIndex { $0 <= keepFrom } ?? 0
        let rawStart = firstRaw.isEmpty ? closed : min(closed, firstRaw[fj])
        let finalEnd: Int? = fj > 0 ? folded[fj - 1].end : (seam > 0 ? (tail?.finalEnd ?? final.last?.end) : nil)
        let next = ActivityContextRunsTail(finalRuns: seam + fj, finalEnd: finalEnd,
                                           raw: Array(rawSums[rawStart..<closed]), open: acc, previousGait: previousGait)
        return (runs, next)
    }

    /// Raw runs at the end of a pass that stay revisable (`ActivityContextRunsTail`).
    static let revisableRawRuns = 3

    /// Whether `event` explains a change from a run of key `from` to one of key `to` (`ActivityClassifier.runKey`).
    /// A change of position explains only boundaries between still or changing-position runs, and a walk or
    /// run start / stop only boundaries into or out of moving, so each event moves the one boundary it is about.
    static func explains(_ event: ActivityTransitionEvent, from: String, to: String) -> Bool {
        let moving: Set<String> = ["walking", "running", "cycling", "active"]
        let gait: Set<String> = ["walking", "running"]
        if event.isPostural, gait.contains(from) || gait.contains(to) { return false }
        switch event.kind {
        case .walkStart, .runStart: return moving.contains(to) && !moving.contains(from)
        case .walkStop, .runStop: return gait.contains(from) && !gait.contains(to)
        case .sitToStandLike: return ["upright", "active", "stationary"].contains(to) && from != to
        case .standToSitLike: return ["seated", "active", "stationary"].contains(to) && from != to
        case .lyingDownLike: return ["lying", "active"].contains(to) && from != to
        case .gettingUpLike: return ["lying", "sleeping"].contains(from) && !["lying", "sleeping"].contains(to)
        }
    }

    /// Back-dates each boundary between two touching runs to the onset of the event that explains it (D2-08).
    /// A run starts on the first published state that carries its class, which is up to a tick after the decoder
    /// flagged the change and some seconds after the change began. When a flagged event of a compatible kind
    /// (a walk start into walking, a stand-up into standing or changing position …) was detected within a tick of
    /// the boundary, the boundary moves back to the event's onset (`ActivityTransitionEvent.onsetTs`, its
    /// detection second when the onset is unknown), never later than it was, and never so far that the earlier run
    /// keeps less than its own first tick. The onset is the decoder's own causal reading (at most `maxOnsetLeadS`
    /// before detection), so a boundary moves by at most ~15 s, and only where the decoder said the change began.
    ///
    /// Wear is a hard gate known to the second: a boundary into or out of an off-wrist run moves to the off-wrist
    /// span's own start or end (`wearChanges`) when that second falls inside the tick before the boundary, so a
    /// strap taken off at 10:00:03 is off from 10:00:03, not from the next 5-s tick.
    static func aligned(_ runs: [ActivityContextRun], to events: [ActivityTransitionEvent],
                        intervalS: Int, fromBoundary first: Int = 1,
                        wearChanges: [Int] = []) -> [ActivityContextRun] {
        guard runs.count > 1, !(events.isEmpty && wearChanges.isEmpty), first < runs.count else { return runs }
        let step = max(1, intervalS)
        let ordered = events.sorted { $0.ts < $1.ts }
        var out = runs
        let keys = runs.map { ActivityClassifier.runKey($0.classification) }
        var cursor = 0
        for i in max(1, first)..<out.count {
            let a = out[i - 1], b = out[i]
            guard a.end == b.start, keys[i - 1] != keys[i] else { continue }
            let offWrist = ActivityClass.offWrist.rawValue
            if (keys[i - 1] == offWrist) != (keys[i] == offWrist) {
                if let c = wearChanges.last(where: { $0 > b.start - step && $0 <= b.start }), c > a.start, c < b.start {
                    out[i - 1].end = c
                    out[i].start = c
                }
                continue
            }
            while cursor < ordered.count, ordered[cursor].ts < b.start - step { cursor += 1 }
            var target: Int?
            var j = cursor
            while j < ordered.count, ordered[j].ts < b.start + step {
                let e = ordered[j]
                if explains(e, from: keys[i - 1], to: keys[i]) {
                    let t = e.onsetTs ?? e.ts
                    target = min(target ?? t, t)
                }
                j += 1
            }
            guard let t = target else { continue }
            let boundary = max(a.start + step, min(b.start, t))
            guard boundary < b.start else { continue }
            out[i - 1].end = boundary
            out[i].start = boundary
        }
        return out
    }

    /// A run of a couple of ticks that sits next to a run with the same class key, wear and sleep context is a
    /// wobble inside that situation (a posture head dipping for one tick), not a separate one: fold it in. A short
    /// run of a DIFFERENT class (a five-second stand between two sitting runs) is not a wobble and stays: the
    /// interval layer decides what a sustained stretch absorbs, and records it (`ActivityContextInterval`).
    ///
    /// One exception looks at the events: a single still tick straight before a walk or run whose start event
    /// was flagged at that boundary is the walk's own first reading (the class lags the first steps by a tick), and
    /// it joins the walk. Left alone it is a five-second still row carrying the walk's first raised heart rate.
    static func foldFragments(_ runs: [ActivityContextRun], maxFragmentS: Int,
                              events: [ActivityTransitionEvent] = [], intervalS: Int = 5) -> [ActivityContextRun] {
        foldFragmentsIndexed(runs, maxFragmentS: maxFragmentS, events: events, intervalS: intervalS).runs
    }

    /// `foldFragments`, with the index of the first input run behind each output run.
    static func foldFragmentsIndexed(_ runs: [ActivityContextRun], maxFragmentS: Int,
                                     events: [ActivityTransitionEvent] = [], intervalS: Int = 5)
        -> (runs: [ActivityContextRun], firstRaw: [Int]) {
        let step = max(1, intervalS)
        let still: Set<String> = ["seated", "upright", "stationary", "lying"]
        let starts = events.filter { $0.kind == .walkStart || $0.kind == .runStart }.map(\.ts).sorted()
        /// `r` is one still tick touching `next`, a walk or run whose start was flagged at their boundary.
        func leadsInto(_ r: ActivityContextRun, _ next: ActivityContextRun) -> Bool {
            guard r.count == 1, next.start == r.end, r.wear == next.wear, r.sleep == next.sleep, r.inBed == next.inBed
            else { return false }
            let from = ActivityClassifier.runKey(r.classification), to = ActivityClassifier.runKey(next.classification)
            guard still.contains(from), to == "walking" || to == "running",
                  starts.contains(where: { $0 >= next.start - step && $0 < next.start + step }) else { return false }
            return ActivityClassifier.runKey(merged(r, next).classification) == to
        }
        func sameSituation(_ a: ActivityContextRun, _ b: ActivityContextRun) -> Bool {
            ActivityClassifier.runKey(a.classification) == ActivityClassifier.runKey(b.classification)
                && a.wear == b.wear && a.sleep == b.sleep && a.inBed == b.inBed
                && b.start - a.end <= 10
        }
        var out: [ActivityContextRun] = []
        var firstRaw: [Int] = []
        var i = 0
        while i < runs.count {
            var r = runs[i]
            if r.end - r.start <= maxFragmentS {
                if let prev = out.last, sameSituation(prev, r) {
                    out[out.count - 1] = merged(prev, r)
                    i += 1
                    continue
                }
                if i + 1 < runs.count, sameSituation(r, runs[i + 1]) || leadsInto(r, runs[i + 1]) {
                    r = merged(r, runs[i + 1])
                    out.append(r); firstRaw.append(i)
                    i += 2
                    continue
                }
            }
            out.append(r); firstRaw.append(i)
            i += 1
        }
        return (out, firstRaw)
    }

    /// Two adjacent runs as one, probabilities averaged by the number of states each covers. The label is the
    /// one that covers more states (the first on a tie).
    static func merged(_ first: ActivityContextRun, _ second: ActivityContextRun) -> ActivityContextRun {
        var last = first
        let a = Double(first.count), b = Double(second.count), n = a + b
        if second.count > first.count { last.displayContext = second.displayContext }
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
        last.gait = ActivityGaitSummary.combine(first.gait, second.gait)
        last.experts = ActivityContextRun.union(first.experts, second.experts)
        let ga = Double(first.gaitStates), gb = Double(second.gaitStates)
        if ga + gb > 0 {
            last.gaitProbability = ((first.gaitProbability ?? 0) * ga + (second.gaitProbability ?? 0) * gb) / (ga + gb)
        }
        last.gaitStates = first.gaitStates + second.gaitStates
        if let x = first.gaitCadenceSpm, let y = second.gaitCadenceSpm { last.gaitCadenceSpm = (x * ga + y * gb) / max(1, ga + gb) }
        else { last.gaitCadenceSpm = first.gaitCadenceSpm ?? second.gaitCadenceSpm }
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

    /// The running sums of one raw run. Codable, so a pass can stop with a run still open and continue it
    /// exactly (`ActivityContextRunsTail`).
    struct Accumulator: Codable, Equatable, Sendable {
        var startTs: Int
        var wear: WearContextState
        var sleep: SleepContextState
        var inBed: Bool
        /// `ActivityClassifier.runKey` of the first state: what every state of the run is.
        var key: String
        var lastTs: Int
        /// States per display label ("" = none), and the order labels first appeared in (ties go to the earliest).
        var labelCounts: [String: Int] = [:]
        var labelOrder: [String] = []
        var count = 0
        var posture: [String: Double] = [:]
        var locomotion: [String: Double] = [:]
        var arm: [String: Double] = [:]
        var intensitySum = 0.0, intensityN = 0
        var confidenceSum = 0.0, uncertaintySum = 0.0
        var gait: GaitTotals?
        var experts: [String] = []
        var gaitSum = 0.0, gaitN = 0, cadenceSum = 0.0, cadenceN = 0

        init(first: ActivityContextState, key: String, gait: GaitTotals? = nil) {
            startTs = first.ts; wear = first.wear.state; sleep = first.sleep.state; inBed = first.sleep.inBed
            self.key = key; self.lastTs = first.ts
            add(first, gait: gait)
        }

        func accepts(_ s: ActivityContextState, key: String, maxGap: Int) -> Bool {
            guard s.ts - lastTs <= maxGap, key == self.key,
                  s.wear.state == wear, s.sleep.state == sleep, s.sleep.inBed == inBed else { return false }
            let n = Double(count)
            func far<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>, _ sums: [String: Double]) -> Bool
                where C.RawValue == String {
                C.allCases.reduce(0) { $0 + abs(h[$1] - (sums[$1.rawValue] ?? 0) / n) } > ActivityContextRuns.headTolerance
            }
            return !(far(s.posture, posture) || far(s.locomotion, locomotion))
        }

        mutating func add(_ s: ActivityContextState, gait added: GaitTotals? = nil) {
            if let added {
                if gait == nil { gait = added } else { gait!.add(added) }
            }
            count += 1
            lastTs = s.ts
            let label = s.displayContext ?? ""
            if labelCounts[label] == nil { labelOrder.append(label) }
            labelCounts[label, default: 0] += 1
            for c in PostureClass.allCases { posture[c.rawValue, default: 0] += s.posture[c] }
            for c in LocomotionClass.allCases { locomotion[c.rawValue, default: 0] += s.locomotion[c] }
            for c in ArmBehaviorClass.allCases { arm[c.rawValue, default: 0] += s.armBehavior[c] }
            if let i = s.intensity { intensitySum += i; intensityN += 1 }
            confidenceSum += s.overallConfidence
            uncertaintySum += s.overallUncertainty
            let e = s.evidence.experts
            if !e.isEmpty, e != experts { experts = ActivityContextRun.union(experts, e) }
            if let g = s.gaitReading {
                gaitSum += g.probability; gaitN += 1
                if g.isGait, let c = g.cadenceSpm { cadenceSum += c; cadenceN += 1 }
            }
        }

        /// The wording most of the run's states carried (nil = "Unclear").
        var label: String? {
            var best: String?, bestN = 0
            for l in labelOrder where labelCounts[l]! > bestN { best = l; bestN = labelCounts[l]! }
            return best.flatMap { $0.isEmpty ? nil : $0 }
        }

        func run(intervalS: Int) -> ActivityContextRun {
            let n = Double(count)
            // Mean over the stretch, thin classes dropped and the rest renormalized: a run is a summary, and
            // a long tail of 1–2 % entries only costs bytes.
            func head<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ sums: [String: Double], floor: Double) -> HeadProbabilities<C>
                where C.RawValue == String {
                var m: [C: Double] = [:]
                for c in C.allCases { if let v = sums[c.rawValue], v / n >= floor { m[c] = v / n } }
                return HeadProbabilities(m).normalized()
            }
            return ActivityContextRun(
                start: startTs, end: lastTs + max(1, intervalS),
                posture: head(posture, floor: 0.02),
                locomotion: head(locomotion, floor: 0.02),
                armBehavior: head(arm, floor: 0.04),
                intensity: intensityN > 0 ? intensitySum / Double(intensityN) : nil,
                overallConfidence: confidenceSum / n, overallUncertainty: uncertaintySum / n,
                displayContext: label, sleep: sleep, inBed: inBed,
                wear: wear, count: count, gait: gait.flatMap { $0.isEmpty ? nil : $0.summary },
                experts: experts,
                gaitProbability: gaitN > 0 ? gaitSum / Double(gaitN) : nil, gaitStates: gaitN,
                gaitCadenceSpm: cadenceN > 0 ? cadenceSum / Double(cadenceN) : nil)
        }
    }
}

/// Where a coalescing pass stopped, so the next one continues it exactly (D2-09): which of the document's runs
/// are settled, the unaligned end of the last settled one, the raw (unfolded) runs behind the runs still
/// revisable, the raw run still accumulating, and the gait stretch so far. Opaque to readers. A document written
/// before it existed has none and is decoded again from the start once.
public struct ActivityContextRunsTail: Codable, Equatable, Sendable {
    var finalRuns: Int
    var finalEnd: Int?
    var raw: [ActivityContextRuns.Accumulator]
    var open: ActivityContextRuns.Accumulator?
    var previousGait: GaitTotals?

    enum CodingKeys: String, CodingKey {
        case finalRuns = "final_runs", finalEnd = "final_end", raw, open
        case previousGait = "previous_gait"
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
    /// Hash of the sleep, in-bed, workout and off-wrist spans inside the covered range, the workout sport kinds,
    /// and a per-stream digest of the covered samples (including late-arriving encoder windows). Editing a
    /// night, adding a workout, a late wrist-off event, a sport rename, or a corrected value changes it, and
    /// the day is then decoded again from the start.
    public var contextFingerprint: String?
    public var runs: [ActivityContextRun]
    public var events: [ActivityTransitionEvent]
    public var latest: ActivityContextState?
    public var summary: ActivityContextDaySummary
    /// Decoder state after the last observation (restart / continuation). Opaque to readers.
    public var snapshot: ActivityDecoderSnapshot?
    /// Where coalescing the states into `runs` stopped, so a continuation stores exactly the runs a decode from
    /// scratch would (D2-09). Opaque to readers; nil on documents written before it existed (and without a snapshot).
    public var runsTail: ActivityContextRunsTail?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", versions
        case dayStart = "day_start", dayEnd = "day_end", publishIntervalS = "publish_interval_s"
        case generatedAt = "generated_at", dataThrough = "data_through", observedSeconds = "observed_s"
        case sleepKnownOutsideSessions = "sleep_known_outside", contextFingerprint = "context_fp"
        case runs, events, latest, summary, snapshot
        case runsTail = "runs_tail"
    }

    public init(track: ActivityContextTrack, input: ActivityContextTrackInput, generatedAt: Int,
                config: ActivityDecoderConfig = ActivityDecoderConfig(), includeSnapshot: Bool = true) {
        let interval = max(1, config.publishIntervalS)
        let coalesced = ActivityContextRuns.coalesce(track.states, intervalS: interval, events: track.events,
                                                      resuming: nil, final: [], offWrist: input.offWrist)
        let runs = coalesced.runs
        self.schemaVersion = ActivityContextVersions.schema
        self.versions = track.snapshot.versions
        self.dayStart = input.dayStart; self.dayEnd = input.dayEnd
        self.publishIntervalS = interval
        self.generatedAt = generatedAt
        self.dataThrough = track.lastTs.map { $0 + 1 }
        self.observedSeconds = track.observedSeconds
        self.sleepKnownOutsideSessions = input.sleepKnownOutsideSessions
        self.contextFingerprint = ActivityContextDayBuilder.fingerprint(input, through: track.lastTs.map { $0 + 1 },
                                                                         config: config)
        self.runs = runs
        self.events = track.events
        self.latest = track.states.last
        self.summary = ActivityContextDaySummary(runs: runs)
        self.snapshot = includeSnapshot ? track.snapshot : nil
        self.runsTail = includeSnapshot ? coalesced.tail : nil
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

    /// FNV-1a over the sleep, workout and off-wrist spans clipped to `[dayStart, through)`, the workout
    /// sport kinds the decoder sees, and a per-stream digest of the covered span's samples. Spans and
    /// samples at or past `through` are excluded, so a stretch still open at `through` (or data the day
    /// has not read yet) hashes the same once the day has grown past it — but a sport rename with
    /// identical bounds, a corrected sample value, or a re-served encoder window now changes the hash,
    /// and the day is decoded again instead of reusing a stale document (spec §4 A07, WS-10-F04).
    static func fingerprint(_ input: ActivityContextTrackInput, through: Int?,
                            config: ActivityDecoderConfig = ActivityDecoderConfig()) -> String {
        let hi = min(through ?? input.dayEnd, input.dayEnd)
        func clipped(_ spans: [(Int, Int)]) -> [String] {
            spans.compactMap { s, e -> String? in
                let lo = max(s, input.dayStart), end = min(e, hi)
                return end > lo ? "\(lo)-\(end)" : nil
            }.sorted()
        }
        // Workout spans carry the sport KIND the decoder actually sees. `WorkoutKind` folds free-text
        // spellings ("Run" and "Running" are the same evidence), so a rename that does not change the
        // decoded behaviour hashes the same; a rename to a different kind does not.
        let workouts = input.workouts.compactMap { w -> String? in
            let lo = max(w.start, input.dayStart), end = min(w.end, hi)
            guard end > lo else { return nil }
            return "\(lo)-\(end):\(WorkoutKind(sport: w.sport).rawValue)"
        }.sorted()
        let parts: [(String, [String])] = [
            ("s", clipped(input.sleep.map { ($0.start, $0.end) })),
            ("b", clipped(input.inBed.map { ($0.start, $0.end) })),
            ("w", workouts),
            ("o", clipped(input.offWrist.map { ($0.start, $0.end) })),
        ]
        let text = parts.map { "\($0.0):" + $0.1.joined(separator: ",") }.joined(separator: "|")

        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        // Per-stream content digest over the covered span, folded in the streams' own (time-ordered)
        // delivery, one pass per stream. The decoder consumes all of these, so an equal-count
        // replacement — a corrected HR row, edited gravity or steps, a re-served encoder window, new
        // IMU features — changes the hash even though no span bound and no row count moved.
        foldString(input.encoderId, into: &h)
        foldString(input.encoderVersion, into: &h)
        fold(input.hr, into: &h, lo: input.dayStart, hi: hi, ts: { $0.ts }) { s, h in
            foldInt(s.bpm, into: &h)
        }
        fold(input.gravity, into: &h, lo: input.dayStart, hi: hi, ts: { $0.ts }) { s, h in
            foldWord(s.x.bitPattern, into: &h)
            foldWord(s.y.bitPattern, into: &h)
            foldWord(s.z.bitPattern, into: &h)
            foldWord(s.dynAccel?.bitPattern ?? .max, into: &h)
        }
        fold(input.steps, into: &h, lo: input.dayStart, hi: hi, ts: { $0.ts }) { s, h in
            foldInt(s.counter, into: &h)
            foldWord(s.activityClass.map(UInt64.init) ?? .max, into: &h)
        }
        // Encoder windows reach the phone from the server minutes after the strap's own streams, and merged
        // per-UTC-day sets carry no ordering promise, so they are folded in a fixed order: an unchanged set must
        // never read as changed (that would re-decode the whole day on every pass).
        let encoderWindows = input.encoderWindows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        let imuWindows = input.imuWindows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        fold(encoderWindows, into: &h, lo: input.dayStart, hi: hi, ts: { $0.endTs }) { w, h in
            foldInt(w.startTs, into: &h)
            foldString(w.label.rawValue, into: &h)
            // `probs` is a dictionary; fold in sorted-key order so the hash never depends on its
            // internal iteration order.
            for key in w.probs.keys.sorted() {
                foldString(key, into: &h)
                foldWord(w.probs[key]!.bitPattern, into: &h)
            }
            foldWord(w.baseline ? 1 : 0, into: &h)
            foldWord(w.calibrated ? 1 : 0, into: &h)
            // Folded only when present, so a window without the fine head hashes as before.
            if let fine = w.fineProbs {
                foldString("h", into: &h)
                for key in fine.keys.sorted() {
                    foldString(key, into: &h)
                    foldWord(fine[key]!.bitPattern, into: &h)
                }
            }
        }
        fold(imuWindows, into: &h, lo: input.dayStart, hi: hi, ts: { $0.endTs }) { f, h in
            foldWord(f.accelRmsG.bitPattern, into: &h)
            foldWord(f.gyroRmsDps.bitPattern, into: &h)
            foldWord(f.jerkRms.bitPattern, into: &h)
            foldWord(f.cadenceHz?.bitPattern ?? .max, into: &h)
            foldWord(f.cadenceStrength.bitPattern, into: &h)
            foldWord(f.orientationChangeDeg?.bitPattern ?? .max, into: &h)
        }
        // Learned transition-expert windows arrive with the encoder windows and change the same seconds'
        // evidence, so they fold the same way. A day without any hashes exactly as before.
        let transitionWindows = input.transitionWindows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        fold(transitionWindows, into: &h, lo: input.dayStart, hi: hi, ts: { $0.endTs }) { w, h in
            foldInt(w.startTs, into: &h)
            for p in w.probabilities { foldWord(p.bitPattern, into: &h) }
            foldWord(w.abstained ? 1 : 0, into: &h)
            foldString(w.modelVersion, into: &h)
            foldString(w.preprocessingVersion, into: &h)
        }
        // ElderNet and Inertia windows also arrive from the server after the strap's streams; a late batch must
        // re-decode the day. Folded only when the config accepts them, so a day without accepted windows hashes
        // exactly as before.
        if let gait = input.gaitQuality, !gait.windows.isEmpty,
           ActivityContextTrackBuilder.acceptsGaitQuality(for: input, config: config) {
            foldString("eg", into: &h)
            foldString(gait.model.modelVersion, into: &h)
            for key in gait.model.weights.keys.sorted() { foldString(gait.model.weights[key] ?? "", into: &h) }
            foldEncoded(gait.windows.filter { $0.endTs >= input.dayStart && $0.endTs < hi }
                            .sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }, into: &h)
        }
        if let heads = input.motionHeads, !heads.windows.isEmpty,
           ActivityContextTrackBuilder.acceptsMotionHeads(for: input, config: config) {
            foldString("ih", into: &h)
            foldEncoded(heads.bundle, into: &h)
            foldEncoded(heads.windows.filter { $0.endTs >= input.dayStart && $0.endTs < hi }
                            .sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }, into: &h)
        }
        let gaitWindows = input.gaitWindows.sorted { ($0.endTs, $0.startTs) < ($1.endTs, $1.startTs) }
        fold(gaitWindows, into: &h, lo: input.dayStart, hi: hi, ts: { $0.endTs }) { w, h in
            foldInt(w.startTs, into: &h)
            foldWord(w.gaitProb.bitPattern, into: &h)
            foldWord((w.isGait ? 1 : 0) | (w.prefiltered ? 2 : 0), into: &h)
            foldWord(w.cadenceSpm?.bitPattern ?? .max, into: &h)
            foldWord(w.speedMps?.bitPattern ?? .max, into: &h)
            foldString(w.modelVersion, into: &h)
        }
        return String(h, radix: 16)
    }

    private static func foldEncoded<T: Encodable>(_ value: T, into h: inout UInt64) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    }

    /// FNV-1a fold of one 64-bit word's raw little-endian bytes, so values hash by their stored bits
    /// (deterministic for the same stored sample) rather than by a decimal spelling.
    private static func foldWord(_ word: UInt64, into h: inout UInt64) {
        for i in 0..<8 {
            let b = UInt8(truncatingIfNeeded: word >> (UInt64(i) * 8))
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
    }

    /// FNV-1a fold of an integer's raw bits.
    private static func foldInt(_ value: Int, into h: inout UInt64) {
        foldWord(UInt64(bitPattern: Int64(value)), into: &h)
    }

    /// FNV-1a fold of a string's UTF-8 bytes.
    private static func foldString(_ string: String, into h: inout UInt64) {
        for b in string.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    }

    /// Fold every sample of `stream` whose timestamp is inside `[lo, hi)` (the covered span), starting
    /// with its timestamp and then whatever `body` folds. Samples at or past `hi` are excluded exactly
    /// like open spans, so data the day has not read yet never moves the fingerprint.
    private static func fold<S>(_ stream: [S], into h: inout UInt64, lo: Int, hi: Int,
                                ts: (S) -> Int, body: (S, inout UInt64) -> Void) {
        for s in stream {
            let t = ts(s)
            guard t >= lo, t < hi else { continue }
            foldInt(t, into: &h)
            body(s, &h)
        }
    }

    /// Bring a day's document up to date with the streams now stored. Continues the stored decoder when the
    /// stored span is unchanged (same ontology / decoder, same number of observed seconds before the cut,
    /// and the same fingerprint over the covered span), and decodes the whole day otherwise: a newer
    /// ontology or decoder, a different day, or data that arrived late inside the already-covered span (a
    /// backfill, a sport rename, a corrected value) would otherwise be silently missed.
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
        let all = ActivityContextTrackBuilder.observations(for: input, config: config).observations
        // Decoded without the Inertia entry unless its evidence is accepted for this input (no stamp otherwise).
        let decodeConfig = ActivityContextTrackBuilder.effectiveConfig(for: input, config: config)

        func fresh(_ reason: String) -> (ActivityContextDayDocument, ActivityContextDayUpdate) {
            let document = decodeFromStart(all, input: input, now: now, config: decodeConfig,
                                           chunkObservations: chunkObservations, progress: progress)
            return (document, .recomputed(reason: reason))
        }

        guard let cached else { return fresh("no_cache") }
        guard cached.isCurrent else { return fresh("version_changed") }
        guard cached.dayStart == input.dayStart else { return fresh("day_changed") }
        guard cached.publishIntervalS == max(1, config.publishIntervalS) else { return fresh("config_changed") }
        guard let through = cached.dataThrough, let snapshot = cached.snapshot else { return fresh("no_snapshot") }
        // Without the coalescing tail the stored runs cannot be continued exactly (a document from before it).
        guard let runsTail = cached.runsTail, runsTail.finalRuns <= cached.runs.count else { return fresh("no_runs_tail") }
        guard cached.sleepKnownOutsideSessions == input.sleepKnownOutsideSessions else { return fresh("sleep_context_changed") }
        let covered = all.prefix { $0.ts < through }.count
        guard covered == cached.observedSeconds else { return fresh("late_data") }
        // A same-count change — a corrected value, a sport rename, a re-served encoder window — leaves
        // the observation count alone, so only the fingerprint (which now carries sport kinds and a
        // per-stream content digest) can see it.
        guard cached.contextFingerprint == fingerprint(input, through: through, config: decodeConfig) else { return fresh("context_changed") }
        let newer = Array(all.dropFirst(covered))
        guard !newer.isEmpty else {
            var same = cached
            same.dayEnd = max(cached.dayEnd, input.dayEnd)
            return (same, .reused)
        }

        let track = ActivityContextTrackBuilder.decode(newer, config: decodeConfig, resuming: snapshot)
        guard track.restore == .resumed else { return fresh("restore_\(track.restore)") }

        var doc = cached
        let interval = cached.publishIntervalS
        doc.events = ActivityTransitionEvent.merging(cached.events, track.events)
        // The settled runs stay; the revisable tail is coalesced again together with the new states (D2-09), so
        // the seam folds and aligns exactly as one pass over the whole day would.
        let coalesced = ActivityContextRuns.coalesce(track.states, intervalS: interval, events: doc.events,
                                                      resuming: runsTail,
                                                      final: Array(cached.runs.prefix(runsTail.finalRuns)),
                                                      offWrist: input.offWrist)
        doc.runs = coalesced.runs
        doc.runsTail = coalesced.tail
        doc.latest = track.states.last ?? cached.latest
        doc.dayEnd = max(cached.dayEnd, input.dayEnd)
        doc.generatedAt = now
        doc.dataThrough = track.lastTs.map { $0 + 1 } ?? cached.dataThrough
        doc.observedSeconds = cached.observedSeconds + track.observedSeconds
        doc.contextFingerprint = fingerprint(input, through: doc.dataThrough, config: decodeConfig)
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
    /// Awake inside the night's in-bed window ("Resting in bed"), so a classifier reading the episode can
    /// name the same body state its label does.
    public var inBed: Bool = false

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
                            uncertainty: $0.overallUncertainty, sleep: $0.sleep, wear: $0.wear,
                            inBed: $0.inBed)
        }
    }
}
