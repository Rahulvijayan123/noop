import XCTest
@testable import StrandAnalytics

/// hsmm-1.6 expert fusion, replayed on deterministic synthetic streams: HART's full 18-activity softmax,
/// the ElderNet gait expert and the learned transition expert each move the posterior the way their
/// training lets them, disagreements are resolved by the likelihood product (never a vote), flat evidence
/// stays `unknown`, and a mixed day decodes into one coherent run timeline with provenance.
final class ActivityExpertFusionReplayTests: XCTestCase {

    // MARK: Helpers

    private func decode(_ obs: [ActivityObservation]) -> [ActivityContextState] {
        var d = ActivityContextDecoder()
        return d.run(obs)
    }

    private func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    private func tail(_ states: [ActivityContextState], from: Int, to: Int) -> [ActivityContextState] {
        states.filter { $0.ts >= from && $0.ts < to }
    }

    /// A HART fine distribution: `peak` maps activity → mass, the remainder spread over the other 17.
    private func fine(_ peak: [String: Double]) -> [String: Double] {
        let rest = max(0, 1 - peak.values.reduce(0, +))
        let others = HartFineActivities.names.filter { peak[$0] == nil }
        var out = peak
        for n in others { out[n] = rest / Double(others.count) }
        return out
    }

    private func flatFine() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: HartFineActivities.names.map { ($0, 1 / Double(HartFineActivities.count)) })
    }

    /// The coarse four-way fold the server sends beside `fine` (`model.py`'s WISDM mapping).
    private func coarse(_ f: [String: Double]) -> [String: Double] {
        var c = ["stationary": 0.0, "walking": 0.0, "running": 0.0, "other_movement": 0.0]
        for (name, p) in f {
            switch name {
            case "walking": c["walking", default: 0] += p
            case "jogging": c["running", default: 0] += p
            case "sitting", "standing", "typing", "writing", "clapping", "folding_clothes":
                c["stationary", default: 0] += p
            default: c["other_movement", default: 0] += p
            }
        }
        return c
    }

    /// HART windows every 2 s carrying `f` (fine + its coarse fold), as served on the wire (uncalibrated).
    private func hart(_ f: [String: Double]) -> (Int) -> MotionEncoderOutput? {
        { ts in
            guard ts % 2 == 0 else { return nil }
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "test-1", startTs: ts - 4, endTs: ts,
                                       classProbs: self.coarse(f), calibrated: false, abstained: false,
                                       fineProbs: f)
        }
    }

    /// The same window with only the coarse fold (the pre-1.6 wire shape).
    private func hartCoarseOnly(_ f: [String: Double]) -> (Int) -> MotionEncoderOutput? {
        { ts in
            guard ts % 2 == 0 else { return nil }
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "test-1", startTs: ts - 4, endTs: ts,
                                       classProbs: self.coarse(f), calibrated: false, abstained: false)
        }
    }

    private func gait(_ q: Double, cadence: Double? = nil) -> GaitExpertEvidence {
        GaitExpertEvidence(gaitProb: q, isGait: q >= 0.5, prefiltered: false, cadenceSpm: q >= 0.5 ? cadence : nil,
                           modelVersion: "eldernet-test", endTs: 0)
    }

    /// ElderNet windows (10 s, hop 5 s) attached at their end second for `[from, to)`.
    private func withGait(_ obs: [ActivityObservation], from: Int, to: Int, q: Double,
                          cadence: Double? = nil) -> [ActivityObservation] {
        var out = obs
        for i in out.indices where out[i].ts >= from && out[i].ts < to && (out[i].ts - from) % 5 == 0 {
            var g = gait(q, cadence: cadence)
            g.endTs = out[i].ts
            out[i].gait = g
        }
        return out
    }

    private var walkFamily: (ActivityContextState) -> Double {
        { $0.locomotion[.walking] + $0.locomotion[.briskWalking] + $0.locomotion[.stairs] }
    }

    // MARK: HART fine distribution

    func testHartFineSeparatesSittingFromStandingWhereTheCoarseFoldCannot() {
        // Both readings fold to coarse `stationary`; only the 18-way softmax says which.
        func run(_ f: [String: Double], fineChannel: Bool) -> (seated: Double, upright: Double) {
            var sim = ActivitySim()
            var opt = ActivitySim.Options()
            opt.encoder = fineChannel ? hart(f) : hartCoarseOnly(f)
            sim.still(300, opt: opt)
            let s = tail(decode(sim.observations), from: sim.ts - 120, to: sim.ts)
            return (mean(s.map { $0.posture[.seatedLikely] }), mean(s.map { $0.posture[.uprightStationary] }))
        }
        let sit = run(fine(["sitting": 0.8]), fineChannel: true)
        let stand = run(fine(["standing": 0.8]), fineChannel: true)
        XCTAssertGreaterThan(sit.seated - stand.seated, 0.1, "HART 'sitting' must lift seated over HART 'standing'")
        XCTAssertGreaterThan(stand.upright - sit.upright, 0.1, "HART 'standing' must lift upright over HART 'sitting'")

        let sitCoarse = run(fine(["sitting": 0.8]), fineChannel: false)
        let standCoarse = run(fine(["standing": 0.8]), fineChannel: false)
        XCTAssertEqual(sitCoarse.seated, standCoarse.seated, accuracy: 1e-9,
                       "the coarse fold is identical for both, so it cannot separate them")
    }

    func testHartFineReachesStairsWhichWasUnreachableFromTheCoarseFold() {
        func run(_ f: [String: Double]) -> [ActivityContextState] {
            var sim = ActivitySim()
            var opt = ActivitySim.Options()
            opt.encoder = hart(f)
            sim.still(30, opt: opt)
            sim.walk(150, opt: opt)
            return tail(decode(sim.observations), from: sim.ts - 90, to: sim.ts)
        }
        let stairs = run(fine(["stairs": 0.85]))
        let flat = run(fine(["walking": 0.85]))
        let stairsMass = mean(stairs.map { $0.locomotion[.stairs] })
        XCTAssertGreaterThan(stairsMass, 0.4, "HART stairs on a gait stream must reach the stairs mode")
        XCTAssertLessThan(mean(flat.map { $0.locomotion[.stairs] }), 0.1)
        // Stairs is still walking at the stable class level, refined by `detail`.
        let k = stairs.last!.classification
        XCTAssertEqual(k.activityClass, .walking)
        XCTAssertEqual(k.detail, .stairs)
        XCTAssertGreaterThan(k.detailConfidence, 0.4)
        XCTAssertNil(flat.last!.classification.detail)
    }

    func testFineChannelReplacesTheCoarseOneInsteadOfAddingToIt() {
        // The fine and coarse vectors are the same softmax. A window carrying both must not count twice:
        // its walking pull is no stronger than the coarse-only window's on an ambiguous (step-less) stream.
        func run(_ enc: @escaping (Int) -> MotionEncoderOutput?) -> Double {
            var sim = ActivitySim()
            var opt = ActivitySim.Options()
            opt.steps = false
            opt.encoder = enc
            sim.walk(150, opt: opt)
            return mean(tail(decode(sim.observations), from: sim.ts - 60, to: sim.ts).map(walkFamily))
        }
        let f = fine(["walking": 0.85])
        let both = run(hart(f)), coarseOnly = run(hartCoarseOnly(f))
        XCTAssertLessThan(both, coarseOnly + 0.15, "fine + coarse must not double-count one softmax")
    }

    // MARK: ElderNet gait expert

    func testElderNetGaitRaisesWalkingAndNonGaitLowersIt() {
        // Step counter off: the stream's own gait evidence is weak, so the expert's say is visible.
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.steps = false
        sim.still(30, opt: opt)
        let start = sim.ts
        sim.walk(150, opt: opt)
        let plain = sim.observations
        let measure = { (obs: [ActivityObservation]) in self.mean(self.tail(self.decode(obs), from: sim.ts - 60, to: sim.ts).map(self.walkFamily)) }
        let base = measure(plain)
        let yes = measure(withGait(plain, from: start, to: sim.ts, q: 0.97, cadence: 108))
        let no = measure(withGait(plain, from: start, to: sim.ts, q: 0.02))
        XCTAssertGreaterThan(yes, base + 0.02, "ElderNet gait must add walking mass")
        XCTAssertLessThan(no, base - 0.02, "ElderNet non-gait must remove walking mass")
    }

    func testElderNetDoesNotVoteOnRunning() {
        // ElderNet was trained on walking vs not-walking; running is neutral in its likelihood, so a
        // "not gait" from it must not talk a clear run out of running.
        var sim = ActivitySim()
        sim.still(20)
        let start = sim.ts
        sim.run(150)
        let plain = sim.observations
        let runMass = { (obs: [ActivityObservation]) in
            self.mean(self.tail(self.decode(obs), from: sim.ts - 60, to: sim.ts).map { $0.locomotion[.running] })
        }
        let base = runMass(plain)
        let nonGait = runMass(withGait(plain, from: start, to: sim.ts, q: 0.02))
        XCTAssertGreaterThan(base, 0.5)
        XCTAssertEqual(nonGait, base, accuracy: 0.05, "running is neutral to the gait expert")
        XCTAssertEqual(GaitExpert.likelihood(0.02)[BodyMode.run.rawValue], GaitExpert.likelihood(0.98)[BodyMode.run.rawValue])
    }

    func testElderNetAloneIsNotCoverage() {
        // The expert never opens the evidence gate: gait windows over silence publish no confident claim.
        var obs: [ActivityObservation] = []
        for ts in 1_760_000_000..<1_760_000_120 {
            var o = ActivityObservation(ts: ts)
            if ts % 5 == 0 { var g = gait(0.97, cadence: 110); g.endTs = ts; o.gait = g }
            obs.append(o)
        }
        let states = decode(obs)
        for s in states {
            XCTAssertNotEqual(s.classification.activityClass, .walking, "at \(s.ts)")
        }
    }

    func testElderNetCadenceIsReportedAndReplacesRhythmCadence() {
        var sim = ActivitySim()
        sim.still(20)
        let start = sim.ts
        sim.walk(120)
        let states = decode(withGait(sim.observations, from: start, to: sim.ts, q: 0.96, cadence: 112))
        let late = tail(states, from: sim.ts - 30, to: sim.ts)
        XCTAssertFalse(late.isEmpty)
        for s in late {
            let g = try? XCTUnwrap(s.gait)
            XCTAssertEqual(g?.cadenceSpm, 112)
            XCTAssertTrue(s.evidence.experts.contains("eldernet"))
        }
    }

    // MARK: Conflicts and uncertainty

    func testHartAndElderNetDisagreementIsHedgedNotVoted() {
        // HART says sitting, ElderNet says gait, on an ambiguous step-less moving wrist. The posterior must
        // land between the two single-expert outcomes: the product of likelihoods, not either winner.
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.steps = false
        sim.still(30, opt: opt)
        let start = sim.ts
        var hartOpt = opt
        hartOpt.encoder = hart(fine(["sitting": 0.85]))
        sim.walk(150, opt: hartOpt)
        let hartOnly = sim.observations
        let measure = { (obs: [ActivityObservation]) in self.mean(self.tail(self.decode(obs), from: sim.ts - 60, to: sim.ts).map(self.walkFamily)) }

        var plainSim = ActivitySim()
        plainSim.still(30, opt: opt)
        plainSim.walk(150, opt: opt)
        let gaitOnly = withGait(plainSim.observations, from: start, to: plainSim.ts, q: 0.97)
        let both = withGait(hartOnly, from: start, to: sim.ts, q: 0.97)

        let wHart = measure(hartOnly), wGait = measure(gaitOnly), wBoth = measure(both)
        XCTAssertGreaterThan(wBoth, wHart, "the gait expert must pull a HART-sitting reading toward walking")
        XCTAssertLessThan(wBoth, wGait, "HART must temper the gait expert, not be outvoted")
    }

    func testFlatHartOverAnUninformativeStreamStaysUnknown() {
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.gravity = false; opt.dyn = false; opt.steps = false; opt.hr = nil
        opt.encoder = hart(flatFine())
        sim.still(180, opt: opt)
        let states = decode(sim.observations)
        let late = tail(states, from: sim.ts - 60, to: sim.ts)
        XCTAssertFalse(late.isEmpty)
        for s in late {
            XCTAssertEqual(s.classification.activityClass, .unknown, "at \(s.ts): flat evidence must not invent a class")
        }
    }

    func testFlatFineDistributionMovesNothing() {
        // A uniform softmax is no information: every body row scores it identically.
        let L = HartFineActivities.bodyLikelihood(HartFineActivities.vector(flatFine())!)
        let spread = (L.max() ?? 0) - (L.min() ?? 0)
        XCTAssertLessThan(spread, 1e-9)
    }

    // MARK: Coherent timeline

    func testMixedDayDecodesIntoACoherentTimelineWithProvenance() throws {
        // desk (HART typing) → stand up → walk (HART walking, ElderNet gait) → stairs (HART stairs, gait)
        // → walk → sit down → quiet sitting (HART sitting, ElderNet non-gait).
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.encoder = hart(fine(["typing": 0.7, "sitting": 0.15]))
        sim.desk(240, opt: opt)
        let standUp = sim.ts
        opt.encoder = hart(fine(["standing": 0.5, "walking": 0.3]))
        sim.postureShift(netDegrees: 70, seconds: 3, opt: opt)
        let walk1 = sim.ts
        opt.encoder = hart(fine(["walking": 0.85]))
        sim.walk(120, opt: opt)
        let stairs = sim.ts
        opt.encoder = hart(fine(["stairs": 0.85]))
        sim.walk(60, opt: opt)
        let walk2 = sim.ts
        opt.encoder = hart(fine(["walking": 0.85]))
        sim.walk(60, opt: opt)
        let sitDown = sim.ts
        opt.encoder = hart(fine(["sitting": 0.5, "standing": 0.3]))
        sim.postureShift(netDegrees: -70, seconds: 3, opt: opt)
        let rest = sim.ts
        opt.encoder = hart(fine(["sitting": 0.85]))
        sim.still(240, opt: opt)
        let end = sim.ts

        var obs = withGait(sim.observations, from: walk1, to: sitDown, q: 0.96, cadence: 110)
        obs = withGait(obs, from: rest, to: end, q: 0.02)
        for i in obs.indices where obs[i].ts >= standUp && obs[i].ts < standUp + 3 {
            obs[i].transition = TransitionEncoderEvidence(none: 0.05, sitToStand: 0.9, standToSit: 0.02, lieDown: 0.01,
                                                          getUp: 0.02, confidence: 0.9, modelVersion: "t",
                                                          preprocessingVersion: "t", abstained: false)
        }
        for i in obs.indices where obs[i].ts >= sitDown && obs[i].ts < sitDown + 3 {
            obs[i].transition = TransitionEncoderEvidence(none: 0.05, sitToStand: 0.02, standToSit: 0.9, lieDown: 0.01,
                                                          getUp: 0.02, confidence: 0.9, modelVersion: "t",
                                                          preprocessingVersion: "t", abstained: false)
        }

        let states = decode(obs)
        // Continuous: no silent holes in the published timeline.
        for (a, b) in zip(states, states.dropFirst()) {
            XCTAssertLessThanOrEqual(b.ts - a.ts, 5, "gap between \(a.ts) and \(b.ts)")
        }
        func dominant(_ from: Int, _ to: Int) -> ActivityClass? {
            var n: [ActivityClass: Int] = [:]
            for s in tail(states, from: from, to: to) { n[s.classification.activityClass, default: 0] += 1 }
            return n.max { $0.value < $1.value }?.key
        }
        XCTAssertTrue([.sittingDesk, .sitting].contains(dominant(standUp - 120, standUp)), "desk segment")
        XCTAssertTrue([.walking, .briskWalking].contains(dominant(walk1 + 30, stairs)), "first walk")
        XCTAssertEqual(dominant(stairs + 20, walk2), .walking, "stairs read as walking at class level")
        let stairsDetail = tail(states, from: stairs + 20, to: walk2).filter { $0.classification.detail == .stairs }
        XCTAssertGreaterThan(stairsDetail.count, tail(states, from: stairs + 20, to: walk2).count / 2,
                             "the stairs stretch carries detail=stairs")
        XCTAssertTrue(tail(states, from: walk2 + 30, to: sitDown).allSatisfy { $0.classification.detail != .stairs },
                      "detail returns to plain walking after the stairs")
        XCTAssertTrue([.sitting, .sittingDesk, .stationary].contains(dominant(rest + 90, end)), "seated rest")
        let restSeated = mean(tail(states, from: rest + 90, to: end).map { $0.posture[.seatedLikely] })
        let restUpright = mean(tail(states, from: rest + 90, to: end).map { $0.posture[.uprightStationary] })
        XCTAssertGreaterThan(restSeated, restUpright, "HART sitting + the stand-to-sit expert lean seated")

        // Provenance: every expert spoke somewhere, and runs carry it.
        let spoke = Set(states.flatMap { $0.evidence.experts })
        XCTAssertTrue(spoke.isSuperset(of: ["hart_fine", "eldernet", "transition"]), "\(spoke)")
        let runs = ActivityContextRuns.coalesce(states)
        XCTAssertTrue(runs.contains { $0.experts.contains("eldernet") && ($0.gaitProbability ?? 0) > 0.8 })
        XCTAssertTrue(runs.contains { ($0.gaitCadenceSpm ?? 0) > 100 })

        // The run document carries the refinement and provenance additively.
        let stairsRun = try XCTUnwrap(runs.first { $0.classification.detail == .stairs })
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stairsRun)) as? [String: Any]
        XCTAssertEqual(json?["activity_class"] as? String, ActivityClass.walking.rawValue)
        XCTAssertEqual(json?["activity_detail"] as? String, "stairs")
        XCTAssertNotNil(json?["detail_confidence"])
        XCTAssertNotNil(json?["experts"])
        let back = try JSONDecoder().decode(ActivityContextRun.self, from: JSONEncoder().encode(stairsRun))
        XCTAssertEqual(back.experts, stairsRun.experts)
        XCTAssertEqual(back.gaitStates, stairsRun.gaitStates)
    }

    // MARK: Persistence

    func testEncoderWindowDocumentRoundTripsFineAndGaitColumns() throws {
        let t0 = 1_760_000_000
        let f = fine(["stairs": 0.6, "walking": 0.2])
        let windows = [
            ActivityWindowPrediction(startTs: t0, endTs: t0 + 4, label: .walking, probs: coarse(f), fineProbs: f),
            ActivityWindowPrediction(startTs: t0 + 2, endTs: t0 + 6, label: .stationary,
                                     probs: ["stationary": 0.9, "walking": 0.1]),
        ]
        let gw = [
            ActivityGaitWindow(startTs: t0, endTs: t0 + 10, gaitProb: 0.931, isGait: true, cadenceSpm: 108.4,
                               speedMps: 1.234, strideM: 1.31, regularity: 0.8, steps: 18.1, modelVersion: "eldernet-x"),
            ActivityGaitWindow(startTs: t0 + 5, endTs: t0 + 15, gaitProb: 0.01, isGait: false, prefiltered: true,
                               modelVersion: "eldernet-x"),
        ]
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v", windows: windows, gaitWindows: gw)
        let data = try JSONSerialization.data(withJSONObject: set.jsonObject(dayStart: t0))
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(try JSONSerialization.jsonObject(with: data),
                                                                encoderId: "hart", encoderVersion: "v"))
        let w0 = try XCTUnwrap(back.windows.first { $0.startTs == t0 })
        let fineBack = try XCTUnwrap(w0.fineProbs)
        for (k, v) in f { XCTAssertEqual(fineBack[k] ?? -1, v, accuracy: 0.0006, k) }
        XCTAssertNil(back.windows.first { $0.startTs == t0 + 2 }?.fineProbs)
        XCTAssertEqual(back.gaitWindows.count, 2)
        let g0 = back.gaitWindows[0], g1 = back.gaitWindows[1]
        XCTAssertEqual(g0.gaitProb, 0.931, accuracy: 1e-9)
        XCTAssertTrue(g0.isGait)
        XCTAssertEqual(g0.cadenceSpm ?? 0, 108.4, accuracy: 1e-9)
        XCTAssertEqual(g0.speedMps ?? 0, 1.234, accuracy: 1e-9)
        XCTAssertEqual(g0.modelVersion, "eldernet-x")
        XCTAssertFalse(g1.isGait)
        XCTAssertTrue(g1.prefiltered)
        XCTAssertNil(g1.cadenceSpm)

        // A set without either writes the pre-1.6 document exactly.
        let plain = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v", windows: [windows[1]])
        let doc = plain.jsonObject(dayStart: t0)
        XCTAssertNil(doc["h"]); XCTAssertNil(doc["h_schema"]); XCTAssertNil(doc["g_schema"])
    }

    func testTrackInputCarriesGaitWindowsAndFingerprintMovesWithThem() {
        var sim = ActivitySim()
        sim.still(20)
        sim.walk(60)
        var input = sim.trackInput()
        let base = ActivityContextDayBuilder.fingerprint(input, through: nil)
        XCTAssertEqual(ActivityContextDayBuilder.fingerprint(input, through: nil), base)

        let lo = input.dayStart + 25
        input.gaitWindows = stride(from: lo, to: input.dayEnd - 10, by: 5).map {
            ActivityGaitWindow(startTs: $0, endTs: $0 + 10, gaitProb: 0.95, isGait: true, cadenceSpm: 110,
                               modelVersion: "eldernet-x")
        }
        let withGait = ActivityContextDayBuilder.fingerprint(input, through: nil)
        XCTAssertNotEqual(withGait, base, "new gait evidence must re-decode the day")
        input.gaitWindows[0].gaitProb = 0.4
        XCTAssertNotEqual(ActivityContextDayBuilder.fingerprint(input, through: nil), withGait)

        let track = ActivityContextTrackBuilder.build(input)
        XCTAssertTrue(track.states.contains { $0.gait?.cadenceSpm == 110 }, "gait windows reach the decoder")
    }
}

private extension ActivityContextState {
    var classification: ActivityClassification { ActivityClassifier.classify(state: self) }
}
