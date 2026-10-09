import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// WP2 (transition-event lane, run / interval construction, latency, resume determinism). Each test replays a
/// realistic 1 Hz strap stream through the real track builder (the D2 audit probe scenarios, now pinned), or
/// exercises the run / interval layer on hand-made runs.
final class ActivityContextTransitionLaneTests: XCTestCase {

    // MARK: - Scenario streams

    /// Gravity directions in the strap frame (+x = forearm axis).
    static let seatedG: [Double] = [0.12, 0.30, 0.95]   // forearm resting on a thigh / desk
    static let standG: [Double] = [0.93, 0.25, 0.27]    // arm hanging
    static let lyingG: [Double] = [0.05, 0.96, 0.25]    // forearm flat, rotated

    /// A deterministic 1 Hz stream: heart rate, gravity with dynAccel, the step counter, and optional synthetic
    /// HART / IMU / transition-expert windows.
    struct Stream {
        var t0 = 1_760_000_000
        var ts: Int
        var seed: UInt64 = 11
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var steps: [StepSample] = []
        var counter = 1000
        var cur: [Double] = ActivityContextTransitionLaneTests.seatedG
        var dynAt: [Int: Double] = [:]
        var walking: Set<Int> = []
        init() { ts = t0 }

        mutating func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        mutating func n(_ a: Double) -> Double { (rand() - 0.5) * 2 * a }
        mutating func emit(_ g: [Double], dyn: Double, hrBpm: Int, ticks: Int = 0, cls: Int = 0) {
            grav.append(GravitySample(ts: ts, x: g[0] + n(0.01), y: g[1] + n(0.01), z: g[2] + n(0.01),
                                      dynAccel: max(0.003, dyn)))
            hr.append(HRSample(ts: ts, bpm: hrBpm))
            counter = (counter + ticks) & 0xFFFF
            steps.append(StepSample(ts: ts, counter: counter, activityClass: cls))
            dynAt[ts] = dyn
            ts += 1
        }
        /// Seconds since `t0`.
        var now: Int { ts - t0 }
        mutating func hold(_ g: [Double], _ s: Int, dyn: Double = 0.009, hr: Int = 66) {
            cur = g
            for _ in 0..<s { emit(g, dyn: dyn + n(dyn * 0.3), hrBpm: hr) }
        }
        /// Rotate from the current orientation to `to` over `s` seconds with a movement burst.
        mutating func move(to: [Double], _ s: Int = 3, dyn: Double = 0.22, hr: Int = 72) {
            let from = cur
            for i in 1...s {
                let f = Double(i) / Double(s)
                emit(zip(from, to).map { $0 + ($1 - $0) * f }, dyn: dyn + n(0.04), hrBpm: hr)
            }
            cur = to
        }
        mutating func walk(_ s: Int) {
            for i in 0..<s {
                walking.insert(ts)
                emit([0.85 + n(0.05), 0.3, 0.3], dyn: 0.135 + n(0.04), hrBpm: 100, ticks: i % 2 == 0 ? 2 : 1, cls: 1)
            }
            cur = [0.85, 0.3, 0.3]
        }
        /// Skip `s` seconds with no samples at all (a data gap / the strap off the wrist).
        mutating func skip(_ s: Int) { ts += s }

        /// Synthetic HART + IMU windows (4 s, 2 s hop), and transition-expert windows that name `transitions`
        /// (start, end, class index) at 0.80.
        func windows(transitions: [(Int, Int, Int)] = [])
            -> (enc: [ActivityWindowPrediction], imu: [ImuWindowFeatures], trans: [ActivityTransitionWindow]) {
            var enc: [ActivityWindowPrediction] = [], imu: [ImuWindowFeatures] = [], trans: [ActivityTransitionWindow] = []
            var s = t0
            while s + 4 <= ts {
                let ds = (s..<(s + 4)).compactMap { dynAt[$0] }
                let m = ds.isEmpty ? 0 : ds.reduce(0, +) / Double(ds.count)
                let probs: [String: Double]
                let label: MotionLabel
                if m > 0.25 {
                    probs = ["running": 0.1, "walking": 0.2, "other_movement": 0.6, "stationary": 0.1]; label = .otherMovement
                } else if m > 0.10 {
                    if (s..<(s + 4)).contains(where: { walking.contains($0) }) {
                        probs = ["walking": 0.85, "other_movement": 0.08, "stationary": 0.05, "running": 0.02]; label = .walking
                    } else {
                        probs = ["other_movement": 0.6, "stationary": 0.3, "walking": 0.08, "running": 0.02]; label = .otherMovement
                    }
                } else {
                    probs = ["stationary": 0.9, "other_movement": 0.06, "walking": 0.03, "running": 0.01]; label = .stationary
                }
                enc.append(ActivityWindowPrediction(startTs: s, endTs: s + 4, label: label, probs: probs, calibrated: false))
                imu.append(ImuWindowFeatures(startTs: s, endTs: s + 4, accelRmsG: max(0.004, m), gyroRmsDps: m * 300,
                                             jerkRms: m * 2, cadenceHz: nil, cadenceStrength: 0.05,
                                             orientationChangeDeg: m > 0.15 ? 60 : 2))
                var p = [0.92, 0.02, 0.02, 0.02, 0.02]
                for (a, b, k) in transitions where s < t0 + b && s + 4 > t0 + a { p = [0.12, 0.02, 0.02, 0.02, 0.02]; p[k] = 0.80 }
                trans.append(ActivityTransitionWindow(startTs: s, endTs: s + 4, probabilities: p,
                                                      modelVersion: "lane-test", preprocessingVersion: "lane-test"))
                s += 2
            }
            return (enc, imu, trans)
        }

        func input(hart: Bool = false, transitions: [(Int, Int, Int)] = [], sleep: [DayStateSpan] = [],
                   inBed: [DayStateSpan] = [], offWrist: [DayStateSpan] = []) -> ActivityContextTrackInput {
            var i = ActivityContextTrackInput(dayStart: t0, dayEnd: ts, hr: hr, gravity: grav, steps: steps,
                                              sleep: sleep, inBed: inBed, sleepKnownOutsideSessions: true,
                                              offWrist: offWrist)
            if hart {
                let w = windows(transitions: transitions)
                i.encoderWindows = w.enc; i.imuWindows = w.imu; i.encoderVersion = "lane-test"
                i.transitionWindows = w.trans
            }
            return i
        }
    }

    struct Decoded {
        let track: ActivityContextTrack
        let document: ActivityContextDayDocument
        let intervals: [ActivityContextInterval]
    }

    func decode(_ input: ActivityContextTrackInput) -> Decoded {
        let track = ActivityContextTrackBuilder.build(input)
        let document = ActivityContextDayDocument(track: track, input: input, generatedAt: 0)
        return Decoded(track: track, document: document,
                       intervals: ActivityContextIntervalBuilder.build(document: document, hr: input.hr, steps: input.steps))
    }

    func describe(_ d: Decoded, _ t0: Int) -> String {
        "intervals " + d.intervals.map { "[\($0.start - t0),\($0.end - t0)) \($0.activityClass.rawValue)" }.joined(separator: " ")
            + " | events " + d.document.events.map { "\($0.kind.rawValue)@\($0.ts - t0)" }.joined(separator: " ")
    }

    /// sit 120 s, stand `standS` s, sit 150 s. Returns the stream and the stand / sit-back seconds (from t0).
    func shortStand(_ standS: Int, burst: Bool) -> (Stream, Int, Int) {
        var g = Stream()
        g.hold(Self.seatedG, 120)
        if burst { g.move(to: Self.standG) } else { g.move(to: Self.standG, dyn: 0.012, hr: 68) }
        let up = g.now
        g.hold(Self.standG, standS, hr: 72)
        if burst { g.move(to: Self.seatedG) } else { g.move(to: Self.seatedG, dyn: 0.012, hr: 68) }
        let back = g.now
        g.hold(Self.seatedG, 150)
        return (g, up, back)
    }

    // MARK: - D2-01: every flagged event reaches the document, at its peak probability

    func testEveryEventTheDecoderFlagsReachesTheDocumentAtItsHighestProbability() throws {
        // Sleep -> wake -> get up -> walk -> sit: the walk stop and the sit-down land inside one 5-s publish tick,
        // and a postural event's probability keeps rising after the tick that showed it.
        var g = Stream()
        g.hold(Self.lyingG, 600, dyn: 0.006, hr: 54)
        g.hold(Self.lyingG, 120, dyn: 0.01, hr: 60)
        g.move(to: Self.standG, 4, dyn: 0.25)
        g.walk(60)
        g.hold(Self.seatedG, 120)
        let input = g.input(sleep: [DayStateSpan(start: g.t0, end: g.t0 + 600)],
                            inBed: [DayStateSpan(start: g.t0, end: g.t0 + 720)])
        // Ground truth: the decoder's own history, read after every second, each event at its peak.
        var decoder = ActivityContextDecoder()
        var peak: [String: ActivityTransitionEvent] = [:]
        var order: [String] = []
        for o in ActivityContextTrackBuilder.observations(for: input) {
            _ = decoder.ingest(o)
            for e in decoder.recordedEvents {
                if let p = peak[e.identity] {
                    var n = e; n.probability = max(p.probability, e.probability); peak[e.identity] = n
                } else { peak[e.identity] = e; order.append(e.identity) }
            }
        }
        let expected = order.map { peak[$0]! }
        let doc = decode(input).document
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(doc.events, expected)
        XCTAssertTrue(doc.events.contains { $0.kind == .walkStop }, "\(doc.events)")
        XCTAssertTrue(doc.events.contains { $0.kind == .standToSitLike }, "\(doc.events)")
    }

    func testTheMergeRuleKeepsTheNewestReadingAtThePeakProbability() {
        let a = ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.45, ts: 100, onsetTs: 98, source: "hsmm")
        // The same excursion, later resolved to the other direction at a lower current mass.
        let b = ActivityTransitionEvent(kind: .standToSitLike, probability: 0.30, ts: 100, onsetTs: 98,
                                        source: "transition_expert")
        let walk = ActivityTransitionEvent(kind: .walkStart, probability: 0.8, ts: 100)
        let merged = ActivityTransitionEvent.merging([a], [b, walk])
        XCTAssertEqual(merged.count, 2, "one postural excursion per second, a walk start is its own event")
        XCTAssertEqual(merged[0].kind, .standToSitLike)
        XCTAssertEqual(merged[0].probability, 0.45)
        XCTAssertEqual(merged[0].source, "transition_expert")
        XCTAssertEqual(merged[1], walk)
    }

    func testAnEventWrittenBeforeOnsetAndSourceExistedStillDecodes() throws {
        let old = #"{"kind":"sit_to_stand_like","probability":0.42,"ts":1760000124}"#
        let e = try JSONDecoder().decode(ActivityTransitionEvent.self, from: Data(old.utf8))
        XCTAssertEqual(e, ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.42, ts: 1_760_000_124))
        XCTAssertNil(e.onsetTs)
        XCTAssertNil(e.source)
        // And an event without them encodes exactly as before.
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        XCTAssertFalse(json.contains("onset_ts"))
        XCTAssertFalse(json.contains("source"))
    }

    // MARK: - D2-05: onset and source

    func testEventsCarryACausalOnsetAndTheirSource() throws {
        let (g, up, _) = shortStand(10, burst: true)
        let plain = decode(g.input()).document.events
        XCTAssertFalse(plain.isEmpty)
        for e in plain {
            let onset = try XCTUnwrap(e.onsetTs, "\(e)")
            XCTAssertLessThanOrEqual(onset, e.ts)
            XCTAssertLessThanOrEqual(e.ts - onset, ActivityTransitionEvent.maxOnsetLeadS)
            XCTAssertEqual(e.source, ActivityTransitionEvent.sourceDecoder)
        }
        let standUp = try XCTUnwrap(plain.first { $0.kind == .sitToStandLike })
        XCTAssertLessThanOrEqual(abs(standUp.onsetTs! - (g.t0 + up - 3)), 5, "the onset is the burst, not the detection")

        // With the learned expert naming the stand-up, the event says so.
        let expert = decode(g.input(hart: true, transitions: [(up - 3, up, 1)])).document.events
        let flagged = try XCTUnwrap(expert.first { $0.kind == .sitToStandLike }, "\(expert)")
        XCTAssertEqual(flagged.source, ActivityTransitionEvent.sourceTransitionExpert)
    }

    // MARK: - D2-12: the inverse direction opens its own event

    func testABobUpFlagsBothDirections() throws {
        // Stand up and straight back down (2 s each way, 2 s up), the expert naming both windows.
        var g = Stream()
        g.hold(Self.seatedG, 120)
        g.move(to: Self.standG, 2, dyn: 0.25)
        g.hold(Self.standG, 2)
        g.move(to: Self.seatedG, 2, dyn: 0.25)
        g.hold(Self.seatedG, 120)
        let d = decode(g.input(hart: true, transitions: [(120, 122, 1), (124, 126, 2)]))
        let postural = d.document.events.filter(\.isPostural)
        XCTAssertTrue(postural.contains { $0.kind == .sitToStandLike }, describe(d, g.t0))
        XCTAssertTrue(postural.contains { $0.kind == .standToSitLike }, describe(d, g.t0))
        let up = try XCTUnwrap(postural.first { $0.kind == .sitToStandLike })
        let down = try XCTUnwrap(postural.first { $0.kind == .standToSitLike })
        XCTAssertLessThan(up.ts, down.ts)
        XCTAssertLessThanOrEqual(down.ts - (g.t0 + 126), 10)
    }

    // MARK: - Short stands: no stale standing, events both ways, nothing lost

    func testShortStandsNeverStoreStandingAfterTheReturnAndKeepTheirEvents() throws {
        for standS in [5, 10, 15] {
            for burst in [true, false] {
                for hart in [false, true] {
                    let (g, up, back) = shortStand(standS, burst: burst)
                    let d = decode(g.input(hart: hart, transitions: [(up - 3, up, 1), (back - 3, back, 2)]))
                    let name = "stand \(standS) s burst=\(burst) hart=\(hart): \(describe(d, g.t0))"
                    // No 'standing' second persisted after the wearer sat back down.
                    let lookup = ActivityContextLookup(intervals: d.intervals)
                    for t in (g.t0 + back)..<(g.t0 + back + 120) {
                        XCTAssertNotEqual(lookup.interval(at: t)?.activityClass, .standing, "\(name) @\(t - g.t0)")
                    }
                    let postural = d.document.events.filter(\.isPostural)
                    if burst {
                        // A burst both ways: the stand-up is always flagged, the sit-down whenever the expert or
                        // a stand long enough for the return shift to be measured supports it.
                        XCTAssertTrue(postural.contains { $0.kind == .sitToStandLike && abs($0.ts - (g.t0 + up)) <= 10 }, name)
                        if hart || standS >= 10 {
                            XCTAssertTrue(postural.contains { $0.kind == .standToSitLike && $0.ts >= g.t0 + back - 3
                                && $0.ts - (g.t0 + back) <= 15 }, name)
                        }
                        // Every event lands on a stored row that counts it.
                        for e in postural {
                            let iv = try XCTUnwrap(lookup.interval(at: e.ts), name)
                            XCTAssertGreaterThanOrEqual(iv.transitionCount ?? 0, 1, name)
                        }
                    }
                }
            }
        }
    }

    func testAStandUpThenWalkingOffFlagsBothTheStandAndTheWalk() throws {
        for hart in [false, true] {
            var g = Stream()
            g.hold(Self.seatedG, 120)
            g.move(to: Self.standG)
            g.hold(Self.standG, 2)
            let walkOn = g.now
            g.walk(40)
            g.move(to: Self.seatedG)
            g.hold(Self.seatedG, 120)
            let d = decode(g.input(hart: hart, transitions: [(120, 123, 1), (walkOn + 40, walkOn + 43, 2)]))
            let name = "hart=\(hart): \(describe(d, g.t0))"
            XCTAssertTrue(d.document.events.contains { $0.kind == .sitToStandLike && $0.ts - g.t0 <= 130 }, name)
            XCTAssertTrue(d.document.events.contains { $0.kind == .walkStart && $0.ts - g.t0 <= walkOn + 10 }, name)
            let walk = try XCTUnwrap(d.intervals.first { $0.activityClass.isGait }, name)
            XCTAssertLessThanOrEqual(abs(walk.start - (g.t0 + walkOn)), 10, name)
        }
    }

    // MARK: - D2-03 / D2-08: runs from the class, boundaries near the truth

    func testShortWalksBetweenSitsLeaveAWalkingInterval() throws {
        for (walkS, hart) in [(6, true), (10, false), (10, true), (15, false), (15, true)] {
            var g = Stream()
            g.hold(Self.seatedG, 120)
            g.move(to: Self.standG, 2)
            let on = g.now
            g.walk(walkS)
            let off = g.now
            g.move(to: Self.seatedG, 2)
            g.hold(Self.seatedG, 150)
            let d = decode(g.input(hart: hart, transitions: [(on - 2, on, 1), (off, off + 2, 2)]))
            let name = "walk \(walkS) s hart=\(hart): \(describe(d, g.t0))"
            let gait = d.intervals.filter { $0.activityClass.isGait }
            XCTAssertFalse(gait.isEmpty, name)
            if walkS >= 10 {
                XCTAssertLessThanOrEqual(abs(gait.first!.start - (g.t0 + on)), 10, name)
                XCTAssertLessThanOrEqual(abs(gait.last!.end - (g.t0 + off)), 10, name)
            }
        }
    }

    func testAWalkEndsInTheStoredContextAndTheLabelWithinTenSecondsOfTheStop() throws {
        for (walkS, hart) in [(30, false), (30, true), (60, false), (60, true)] {
            var g = Stream()
            g.hold(Self.seatedG, 120)
            g.move(to: Self.standG, 2)
            let on = g.now
            g.walk(walkS)
            let off = g.now
            g.move(to: Self.seatedG, 2)
            g.hold(Self.seatedG, 150)
            let d = decode(g.input(hart: hart, transitions: [(on - 2, on, 1), (off, off + 2, 2)]))
            let name = "walk \(walkS) s hart=\(hart): \(describe(d, g.t0))"
            let gait = d.intervals.filter { $0.activityClass.isGait }
            let start = try XCTUnwrap(gait.first?.start, name), end = try XCTUnwrap(gait.last?.end, name)
            XCTAssertLessThanOrEqual(abs(start - (g.t0 + on)), 10, name)
            XCTAssertLessThanOrEqual(abs(end - (g.t0 + off)), 10, name)
            // The label leaves "Walking" within 10 s of the stop: the stop event confirms leaving the moving kind and
            // the hold no longer restarts as the label passes through standing and changing position.
            let lastWalkingLabel = try XCTUnwrap(d.track.states.last { $0.displayContext == "Walking" }?.ts, name)
            XCTAssertLessThanOrEqual(lastWalkingLabel + 5 - (g.t0 + off), 10, name)
        }
    }

    func testAWalkThenAShortStandThenSittingIsNotStoredAsWalking() throws {
        // D2-03: during the 10-30 s label hold the stand and the first seconds of sitting were stored as walking.
        for hart in [false, true] {
            var g = Stream()
            g.hold(Self.seatedG, 120)
            g.move(to: Self.standG)
            g.walk(60)
            let stop = g.now
            g.hold(Self.standG, 10)
            g.move(to: Self.seatedG)
            let sit = g.now
            g.hold(Self.seatedG, 150)
            let d = decode(g.input(hart: hart, transitions: [(120, 123, 1), (sit - 3, sit, 2)]))
            let name = "hart=\(hart): \(describe(d, g.t0))"
            let walk = try XCTUnwrap(d.intervals.last { $0.activityClass.isGait }, name)
            XCTAssertLessThanOrEqual(walk.end - (g.t0 + stop), 10, name)
            // Seconds stored under a class whose run key differs from the state-level class: at most the lag of a tick
            // at each of the four changes.
            let lookup = ActivityContextLookup(intervals: d.intervals)
            var mismatched = 0
            for s in d.track.states {
                guard let iv = lookup.interval(at: s.ts) else { continue }
                let stored = ActivityClassifier.runKey(ActivityClassification(activityClass: iv.activityClass, confidence: 0,
                                                                             posture: iv.posture))
                if stored != ActivityClassifier.runKey(ActivityClassifier.classify(state: s)) { mismatched += 5 }
            }
            XCTAssertLessThanOrEqual(mismatched, 20, name)
        }
    }

    // MARK: - D2-09: resume is a fresh decode

    func testResumingAtAnyCadenceStoresExactlyWhatAFreshDecodeStores() throws {
        var g = Stream()
        g.hold(Self.seatedG, 120)
        g.move(to: Self.standG)
        g.walk(60)
        g.hold(Self.standG, 10)
        g.move(to: Self.seatedG)
        g.hold(Self.seatedG, 150)
        g.move(to: Self.standG)
        g.hold(Self.standG, 10)
        g.move(to: Self.seatedG)
        g.hold(Self.seatedG, 200)
        // Compared as stored: through a JSON round trip, as the phone's file cache and the server keep documents.
        func stored(_ d: ActivityContextDayDocument) throws -> ActivityContextDayDocument {
            try JSONDecoder().decode(ActivityContextDayDocument.self, from: JSONEncoder().encode(d))
        }
        for hart in [false, true] {
            let full = g.input(hart: hart, transitions: [(120, 123, 1), (193, 196, 2), (346, 349, 1), (359, 362, 2)])
            let freshInMemory = ActivityContextDayBuilder.update(cached: nil, input: full, now: 0).document
            let fresh = try stored(freshInMemory)
            let freshIv = ActivityContextIntervalBuilder.build(document: fresh, hr: full.hr, steps: full.steps)
            // The decoder hands out runs in their stored form: the document as built and as read back are the same,
            // and so is everything built from them (the phone builds intervals from the in-memory document).
            XCTAssertEqual(freshInMemory.runs, fresh.runs, "hart=\(hart)")
            XCTAssertEqual(freshInMemory.summary, fresh.summary, "hart=\(hart)")
            XCTAssertEqual(ActivityContextIntervalBuilder.build(document: freshInMemory, hr: full.hr, steps: full.steps),
                           freshIv, "hart=\(hart)")
            for step in [7, 13, 30, 61, 120] {
                var cached: ActivityContextDayDocument?
                var inMemory: ActivityContextDayDocument?
                var cut = g.t0 + step
                var resumed = 0
                while true {
                    let hi = min(cut, g.ts)
                    var part = full
                    part.dayEnd = hi
                    part.hr = full.hr.filter { $0.ts < hi }
                    part.gravity = full.gravity.filter { $0.ts < hi }
                    part.steps = full.steps.filter { $0.ts < hi }
                    part.encoderWindows = full.encoderWindows.filter { $0.endTs < hi }
                    part.imuWindows = full.imuWindows.filter { $0.endTs < hi }
                    part.transitionWindows = full.transitionWindows.filter { $0.endTs < hi }
                    let r = ActivityContextDayBuilder.update(cached: cached, input: part, now: 0)
                    if case .resumed = r.how { resumed += 1 }
                    inMemory = r.document
                    cached = try stored(r.document)
                    if hi >= g.ts { break }
                    cut += step
                }
                let doc = try XCTUnwrap(cached)
                let name = "hart=\(hart) step=\(step)"
                XCTAssertGreaterThan(resumed, 0, name)
                XCTAssertEqual(doc.runs, fresh.runs, name)
                XCTAssertEqual(doc.events, fresh.events, name)
                XCTAssertEqual(doc.runsTail, fresh.runsTail, name)
                XCTAssertEqual(doc.summary, fresh.summary, name)
                XCTAssertEqual(ActivityContextIntervalBuilder.build(document: doc, hr: full.hr, steps: full.steps), freshIv, name)
                let live = try XCTUnwrap(inMemory)
                XCTAssertEqual(live.runs, freshInMemory.runs, name)
                XCTAssertEqual(live.summary, freshInMemory.summary, name)
                XCTAssertEqual(ActivityContextIntervalBuilder.build(document: live, hr: full.hr, steps: full.steps), freshIv, name)
            }
        }
    }

    func testTheSameInputDecodedFreshOrIncrementallyPersistsTheSameDocument() throws {
        // Causal vs retrospective: everything persisted (runs, events, their onsets, the tail that continues them)
        // is a function of the input, not of how the decode was chunked.
        var g = Stream()
        g.hold(Self.lyingG, 600, dyn: 0.006, hr: 54)
        g.hold(Self.lyingG, 120, dyn: 0.01, hr: 60)
        g.move(to: Self.standG, 4, dyn: 0.25)
        g.walk(60)
        g.hold(Self.seatedG, 120)
        let full = g.input(sleep: [DayStateSpan(start: g.t0, end: g.t0 + 600)],
                           inBed: [DayStateSpan(start: g.t0, end: g.t0 + 720)])
        let fresh = ActivityContextDayBuilder.update(cached: nil, input: full, now: 0).document
        let chunked = ActivityContextDayBuilder.update(cached: nil, input: full, now: 0, chunkObservations: 60,
                                                       progress: { _ in }).document
        var half = full
        half.dayEnd = g.t0 + 731
        half.hr = full.hr.filter { $0.ts < half.dayEnd }
        half.gravity = full.gravity.filter { $0.ts < half.dayEnd }
        half.steps = full.steps.filter { $0.ts < half.dayEnd }
        let first = ActivityContextDayBuilder.update(cached: nil, input: half, now: 0).document
        let (resumed, how) = ActivityContextDayBuilder.update(cached: first, input: full, now: 0)
        XCTAssertEqual(how, .resumed(fromTs: g.t0 + 731))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(chunked), try encoder.encode(fresh))
        XCTAssertEqual(try encoder.encode(resumed), try encoder.encode(fresh))
    }

    // MARK: - Night, wear and gaps

    func testSleepThenWakeThenGettingUpFollowsTheNightAndThenTheWalk() throws {
        var g = Stream()
        g.hold(Self.lyingG, 600, dyn: 0.006, hr: 54)
        g.hold(Self.lyingG, 120, dyn: 0.01, hr: 60)
        g.move(to: Self.standG, 4, dyn: 0.25)
        let walkOn = g.now
        g.walk(60)
        let walkOff = g.now
        g.hold(Self.seatedG, 120)
        let d = decode(g.input(sleep: [DayStateSpan(start: g.t0, end: g.t0 + 600)],
                               inBed: [DayStateSpan(start: g.t0, end: g.t0 + 720)]))
        let name = describe(d, g.t0)
        let lookup = ActivityContextLookup(intervals: d.intervals)
        XCTAssertEqual(lookup.interval(at: g.t0 + 300)?.activityClass, .sleeping, name)
        let awake = try XCTUnwrap(lookup.interval(at: g.t0 + 660), name)
        XCTAssertEqual(awake.activityClass, .lyingDown, name)
        XCTAssertEqual(awake.inBed, true, name)
        XCTAssertNotEqual(lookup.interval(at: g.t0 + 700)?.activityClass, .sleeping, "asleep is released at the staged wake")
        XCTAssertTrue(d.document.events.contains { $0.kind == .gettingUpLike && abs($0.ts - (g.t0 + 720)) <= 10 }, name)
        let walk = try XCTUnwrap(d.intervals.first { $0.activityClass.isGait }, name)
        XCTAssertLessThanOrEqual(abs(walk.start - (g.t0 + walkOn)), 10, name)
        XCTAssertLessThanOrEqual(abs(walk.end - (g.t0 + walkOff)), 10, name)
        // Sitting after the walk starts by settling.
        let sit = try XCTUnwrap(lookup.interval(at: g.t0 + walkOff + 60), name)
        XCTAssertGreaterThan(sit.settlingSeconds ?? 0, 0, name)
    }

    func testOffWristAtANonGridSecondIsOffFromThatSecond() throws {
        var g = Stream()
        g.hold(Self.seatedG, 203)
        let off = g.now
        g.skip(297)
        let on = g.now
        g.hold(Self.seatedG, 200)
        let span = DayStateSpan(start: g.t0 + off, end: g.t0 + on)
        let d = decode(g.input(offWrist: [span]))
        let name = describe(d, g.t0)
        let offRows = d.intervals.filter { $0.activityClass == .offWrist }
        XCTAssertEqual(offRows.count, 1, name)
        XCTAssertEqual(offRows.first?.start, span.start, name)
        XCTAssertEqual(offRows.first?.end, span.end, name)
        // Nothing on either side claims those seconds.
        let lookup = ActivityContextLookup(intervals: d.intervals)
        XCTAssertNotEqual(lookup.interval(at: span.start)?.wear, .onWrist)
        XCTAssertNotEqual(lookup.interval(at: span.start - 1)?.wear, .offWrist)
    }

    func testARowAfterADataGapSaysHowLongTheGapWas() throws {
        var g = Stream()
        g.hold(Self.seatedG, 300)
        g.skip(90)
        g.hold(Self.standG, 120)
        let d = decode(g.input())
        let name = describe(d, g.t0)
        let after = try XCTUnwrap(d.intervals.first { $0.start >= g.t0 + 390 }, name)
        XCTAssertEqual(after.precededByGapS, 90, name)
        XCTAssertNil(d.intervals.first?.precededByGapS)
        XCTAssertTrue(d.intervals.dropFirst().filter { $0.start < g.t0 + 300 }.allSatisfy { $0.precededByGapS == 0 }, name)
    }

    // MARK: - Interval fold (D2-04, D3-06, D3-08)

    let t0 = 1_760_000_000

    func run(_ s: Int, _ e: Int, posture: [PostureClass: Double], locomotion: [LocomotionClass: Double] = [.stationary: 0.97, .unknown: 0.03],
             sleep: SleepContextState = .awake, inBed: Bool = false, wear: WearContextState = .onWrist,
             confidence: Double = 0.8, uncertainty: Double = 0.2, intensity: Double = 0.1,
             experts: [String] = []) -> ActivityContextRun {
        ActivityContextRun(start: t0 + s, end: t0 + e, posture: HeadProbabilities(posture), locomotion: HeadProbabilities(locomotion),
                           armBehavior: HeadProbabilities([.quiet: 1]), intensity: intensity, overallConfidence: confidence,
                           overallUncertainty: uncertainty, displayContext: nil, sleep: sleep, inBed: inBed, wear: wear,
                           count: max(1, (e - s) / 5), experts: experts)
    }
    let seated: [PostureClass: Double] = [.seatedLikely: 0.84, .uprightStationary: 0.1, .unknown: 0.06]
    let upright: [PostureClass: Double] = [.uprightStationary: 0.72, .seatedLikely: 0.2, .unknown: 0.08]
    let lying: [PostureClass: Double] = [.recumbent: 0.9, .unknown: 0.1]

    func testTheFoldKeepsSustainedSittingButRecordsTheStandItAbsorbedAndItsEvents() {
        let runs = [run(0, 120, posture: seated), run(120, 125, posture: upright), run(125, 240, posture: seated)]
        let events = [ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.5, ts: t0 + 120),
                      ActivityTransitionEvent(kind: .standToSitLike, probability: 0.3, ts: t0 + 126)]
        let iv = ActivityContextIntervalBuilder.build(runs: runs, events: events)
        XCTAssertEqual(iv.map(\.activityClass), [.sitting], "a 5-s stand stays folded into the sustained state")
        XCTAssertEqual(iv.first?.absorbedClasses, [.standing])
        XCTAssertEqual(iv.first?.absorbedSeconds, 5)
        XCTAssertEqual(iv.first?.transitionCount, 2)
        XCTAssertEqual(iv.first?.settlingSeconds, 120, "two minutes from the stand-up, inside the row")
    }

    func testABriefLightActivityBlipInsideSittingIsAbsorbedButAShortWalkIsNot() {
        let moving: [LocomotionClass: Double] = [.other: 0.8, .stationary: 0.2]
        let walking: [LocomotionClass: Double] = [.walking: 0.85, .stationary: 0.15]
        let blip = ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated),
                                                               run(120, 125, posture: [.unknown: 1], locomotion: moving),
                                                               run(125, 240, posture: seated)])
        XCTAssertEqual(blip.map(\.activityClass), [.sitting])
        XCTAssertEqual(blip.first?.absorbedClasses, [.lightActivity])
        let walk = ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated),
                                                               run(120, 125, posture: [.unknown: 1], locomotion: walking),
                                                               run(125, 240, posture: seated)])
        XCTAssertEqual(walk.map(\.activityClass), [.sitting, .walking, .sitting])
    }

    func testTheFoldNeverAbsorbsOffWristOrAnotherContext() {
        let offWrist = run(120, 125, posture: [.unknown: 1], locomotion: [.unknown: 1], wear: .offWrist)
        let otherSleep = run(120, 125, posture: upright, sleep: .unknown)
        let wearUnknown = run(120, 125, posture: [.unknown: 1], locomotion: [.unknown: 1], wear: .unknown)
        for (name, mid) in [("off wrist", offWrist), ("other sleep context", otherSleep), ("wear unknown", wearUnknown)] {
            let iv = ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated), mid, run(125, 240, posture: seated)])
            XCTAssertEqual(iv.count, 3, "\(name): \(iv.map(\.activityClass))")
            XCTAssertTrue(iv.allSatisfy { $0.absorbedSeconds == 0 }, name)
        }
    }

    func testAFewUnreadableSecondsOnTheWristAreAbsorbedAndRecordedAsUnknown() {
        // Review fix: no-claim ticks inside a sustained stretch split it into three rows (2.6 unknown rows < 10 s per
        // hour on capture-24, and sleep seconds stored as unknown went up 4x). Absorbed, they are recorded as such.
        let noClaim = run(120, 125, posture: [.unknown: 1], locomotion: [.unknown: 1], confidence: 0.1)
        let iv = ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated), noClaim, run(125, 240, posture: seated)])
        XCTAssertEqual(iv.map(\.activityClass), [.sitting])
        XCTAssertEqual(iv.first?.absorbedClasses, [.unknown])
        XCTAssertEqual(iv.first?.absorbedSeconds, 5)
        // Inside a night, where the stager said asleep throughout and only the body heads were unreadable, up to the
        // still dwell (sleep seconds stored as unknown on capture-24: 205 -> 645 before this, mostly 10-30 s rows).
        let night = ActivityContextIntervalBuilder.build(runs: [
            run(0, 600, posture: lying, sleep: .asleep, inBed: true),
            run(600, 620, posture: [.unknown: 1], locomotion: [.unknown: 1], sleep: .asleep, inBed: true, confidence: 0.1),
            run(620, 1_200, posture: lying, sleep: .asleep, inBed: true)])
        XCTAssertEqual(night.map(\.activityClass), [.sleeping, .sleeping], "one night, cut at the 15-minute cap only")
        XCTAssertEqual(night.compactMap(\.absorbedClasses).flatMap { $0 }, [.unknown])
        XCTAssertEqual(night.compactMap(\.absorbedSeconds).reduce(0, +), 20)
        // Awake, ten seconds or more of no claim is a row of its own.
        let longer = run(120, 130, posture: [.unknown: 1], locomotion: [.unknown: 1], confidence: 0.1)
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated), longer,
                                                                   run(130, 240, posture: seated)]).count, 3)
    }

    func testAPostureHedgeFlippingForAFewTicksDoesNotSplitAStillRow() {
        // Review fix: runs follow the per-state class, so a posture hedge that flips for a few ticks split a sitting
        // stretch (stationary rows < 60 s went 3.1 -> 10.8 per hour on capture-24, and their seconds lost RMSSD).
        let unresolved: [PostureClass: Double] = [.seatedLikely: 0.4, .uprightStationary: 0.35, .unknown: 0.25]
        let moving: [LocomotionClass: Double] = [.other: 0.8, .stationary: 0.2]
        let hedge = ActivityContextIntervalBuilder.build(runs: [
            run(0, 300, posture: seated), run(300, 320, posture: unresolved), run(320, 600, posture: seated)])
        XCTAssertEqual(hedge.map(\.activityClass), [.sitting])
        XCTAssertEqual(hedge.first?.absorbedClasses, [.stationary])
        XCTAssertEqual(hedge.first?.absorbedSeconds, 20)
        // A chain of short readings, still and light, under the same 30 s.
        let chain = ActivityContextIntervalBuilder.build(runs: [
            run(0, 300, posture: seated), run(300, 315, posture: unresolved),
            run(315, 320, posture: [.unknown: 1], locomotion: moving), run(320, 328, posture: upright),
            run(328, 600, posture: seated)])
        XCTAssertEqual(chain.map(\.activityClass), [.sitting])
        XCTAssertEqual(chain.first?.absorbedSeconds, 28)
        XCTAssertEqual(Set(chain.first?.absorbedClasses ?? []), [.stationary, .lightActivity, .standing])
        // Thirty seconds of another reading is a row of its own; so is a still pause inside a walk past 10 s.
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: [
            run(0, 300, posture: seated), run(300, 330, posture: unresolved), run(330, 600, posture: seated)]).count, 3)
        let walking: [LocomotionClass: Double] = [.walking: 0.85, .stationary: 0.15]
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: [
            run(0, 300, posture: upright, locomotion: walking), run(300, 315, posture: upright),
            run(315, 600, posture: upright, locomotion: walking)]).count, 3)
    }

    func testLyingInBedAndLyingOnTheSofaAreDifferentSituations() {
        let runs = [run(0, 300, posture: lying, sleep: .awake, inBed: true), run(300, 600, posture: lying, sleep: .awake, inBed: false)]
        let iv = ActivityContextIntervalBuilder.build(runs: runs)
        XCTAssertEqual(iv.map(\.activityClass), [.lyingDown, .lyingDown])
        XCTAssertEqual(iv.map(\.inBed), [true, false])
        // And a short in-bed fragment between two sofa stretches is never absorbed into them.
        let mixed = [run(0, 300, posture: lying), run(300, 305, posture: lying, inBed: true), run(305, 600, posture: lying)]
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: mixed).count, 3)
    }

    func testIntervalsCarryTheirRunsUncertaintyAndExperts() {
        let runs = [run(0, 100, posture: seated, uncertainty: 0.2, experts: ["encoder"]),
                    run(100, 200, posture: seated, uncertainty: 0.4, experts: ["encoder", "transition"])]
        let iv = ActivityContextIntervalBuilder.build(runs: runs)
        XCTAssertEqual(iv.count, 1)
        XCTAssertEqual(iv.first?.uncertainty ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(iv.first?.experts, ["encoder", "transition"])
    }

    func testOnlyAChangeOfPositionWorthShowingStartsSettling() {
        // Review fix: weak postural readings (under 0.40, mostly shifting in a chair or in bed) anchored settling, so
        // 87 % of sitting seconds on capture-24 read as settling.
        let runs = [run(0, 600, posture: seated)]
        let weak = ActivityTransitionEvent(kind: .standToSitLike, probability: 0.3, ts: t0 + 300)
        let shown = ActivityTransitionEvent(kind: .standToSitLike, probability: 0.5, ts: t0 + 300)
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: runs, events: [weak]).first?.settlingSeconds, 0)
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: runs, events: [weak]).first?.transitionCount, 1,
                       "still counted as a transition inside the row")
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: runs, events: [shown]).first?.settlingSeconds, 120)
    }

    func testTheStillTickBeforeAFlaggedWalkJoinsTheWalk() {
        // Review fix: sit -> one still tick -> walk left a 5-s still row carrying the walk's first raised heart rate.
        let walking: [LocomotionClass: Double] = [.walking: 0.85, .stationary: 0.15]
        let unresolved: [PostureClass: Double] = [.seatedLikely: 0.4, .uprightStationary: 0.35, .unknown: 0.25]
        let runs = [run(0, 120, posture: seated), run(120, 125, posture: unresolved),
                    run(125, 185, posture: upright, locomotion: walking)]
        let start = ActivityTransitionEvent(kind: .walkStart, probability: 0.8, ts: t0 + 125)
        let folded = ActivityContextRuns.foldFragments(runs, maxFragmentS: 10, events: [start])
        XCTAssertEqual(folded.map { ActivityClassifier.runKey($0.classification) }, ["seated", "walking"])
        XCTAssertEqual(folded.last?.start, t0 + 120)
        XCTAssertEqual(folded.last?.count, 13)
        // Without a flagged start (or with one flagged elsewhere) the tick is the decoder's reading and stays.
        XCTAssertEqual(ActivityContextRuns.foldFragments(runs, maxFragmentS: 10).count, 3)
        let elsewhere = ActivityTransitionEvent(kind: .walkStart, probability: 0.8, ts: t0 + 160)
        XCTAssertEqual(ActivityContextRuns.foldFragments(runs, maxFragmentS: 10, events: [elsewhere]).count, 3)
    }

    func testAContextFieldReadsBackAsRecordedAndARowWithoutItAsNotRecorded() throws {
        // Review fix: the ctx-int-2 fields used to read back as 0 / false (fully certain, no transitions, not in bed)
        // from a store row with no columns for them. The row now carries them (INT-A), so they read back exactly;
        // a row written without them (a pre-ctx-int-2 row) still reads nil: not recorded.
        let built = ActivityContextIntervalBuilder.build(runs: [run(0, 120, posture: seated), run(120, 125, posture: upright),
                                                                run(125, 240, posture: seated)])
        let iv = try XCTUnwrap(built.first)
        XCTAssertEqual(iv.inBed, false)
        XCTAssertEqual(iv.uncertainty ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(iv.transitionCount, 0)
        XCTAssertEqual(iv.absorbedSeconds, 5)
        XCTAssertEqual(iv.settlingSeconds, 0)
        XCTAssertEqual(ActivityContextInterval(row: iv.storeRow), iv)
        var legacy = iv.storeRow
        legacy.inBed = nil; legacy.uncertainty = nil; legacy.experts = nil; legacy.transitionCount = nil
        legacy.absorbedClasses = nil; legacy.absorbedSeconds = nil; legacy.precededByGapS = nil
        legacy.settlingSeconds = nil
        let back = ActivityContextInterval(row: legacy)
        XCTAssertNil(back.inBed)
        XCTAssertNil(back.uncertainty)
        XCTAssertNil(back.experts)
        XCTAssertNil(back.transitionCount)
        XCTAssertNil(back.absorbedClasses)
        XCTAssertNil(back.absorbedSeconds)
        XCTAssertNil(back.precededByGapS)
        XCTAssertNil(back.settlingSeconds)
    }

    func testARunStopIsBackDatedToWhenTheRunningEnded() throws {
        // Review fix: a run slowing into a walk keeps the moving mass high, so the run stop's onset (taken from the
        // moving mass) was always its detection second.
        var sim = ActivitySim(start: t0)
        sim.desk(300); sim.run(180); sim.walk(180); sim.desk(300)
        let input = sim.trackInput()
        let events = ActivityContextTrackBuilder.build(input).events
        let stop = try XCTUnwrap(events.first { $0.kind == .runStop }, "\(events.map(\.kind))")
        let onset = try XCTUnwrap(stop.onsetTs)
        XCTAssertLessThan(onset, stop.ts, "back-dated")
        XCTAssertGreaterThanOrEqual(onset, stop.ts - ActivityTransitionEvent.maxOnsetLeadS)
    }

    func testSplitPartsReadTheirOwnIntensityAndConfidence() throws {
        // 45 minutes of sitting, the restless part in the last 15: each part reads its own seconds (D3-13).
        let runs = [run(0, 1_800, posture: seated, confidence: 0.9, intensity: 0.1),
                    run(1_800, 2_700, posture: seated, confidence: 0.6, intensity: 0.35)]
        let iv = ActivityContextIntervalBuilder.build(runs: runs)
        XCTAssertEqual(iv.count, 3)
        XCTAssertEqual(iv[0].intensity ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(iv[2].intensity ?? 0, 0.35, accuracy: 1e-9)
        XCTAssertLessThan(iv[2].evidenceQuality, iv[0].evidenceQuality)
    }

    func testAnOldIntervalJSONDecodesWithNothingRecorded() throws {
        let iv = ActivityContextInterval(start: 1, end: 2, activityClass: .sitting, confidence: 0.5)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(iv)) as? [String: Any])
        for key in ["inBed", "uncertainty", "experts", "transitionCount", "absorbedClasses", "absorbedSeconds",
                    "precededByGapS", "settlingSeconds"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(ActivityContextInterval.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old, iv)
    }

    func testTheIntervalRulesVersionMovedOn() {
        XCTAssertEqual(ActivityClassVersions.interval, "ctx-int-2")
    }
}
