import XCTest
@testable import StrandAnalytics

/// Inertia-1 heads as decoder evidence (INERTIA1.md §7, `ActivityContextMotionHeadsFusion.swift`): what the
/// channels do, what they never do, and every way they are refused.
final class MotionHeadsDecoderTests: XCTestCase {

    private let P = MotionHead.posture.classOrder
    private let L = MotionHead.locomotion.classOrder
    private let A = MotionHead.armBehavior.classOrder

    private func decode(_ obs: [ActivityObservation], _ config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> ActivityContextTrack {
        ActivityContextTrackBuilder.decode(obs, config: config)
    }

    private func mean(_ states: [ActivityContextState], from: Int, _ value: (ActivityContextState) -> Double) -> Double {
        let xs = states.filter { $0.ts >= from }.map(value)
        return xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    private func encoded(_ track: ActivityContextTrack) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(track.states), as: UTF8.self)
            + String(decoding: try e.encode(track.snapshot), as: UTF8.self)
    }

    /// A quiet wrist with no sleep evidence: seated and upright are equally plausible from the strap streams.
    private func quietWrist(_ seconds: Int = 300, start: Int = 1_760_000_000) -> ActivitySim {
        var sim = ActivitySim(start: start, seed: 3)
        var o = ActivitySim.Options()
        o.sleep = .awake
        sim.still(seconds, opt: o)
        return sim
    }

    // MARK: - Neutrality

    func testAnUninformativeHeadIsNeutral() throws {
        // q = π: every likelihood ratio is 1, for every head and every mode / arm state.
        let bundle = MotionHeadsKit.bundle()
        let config = MotionHeadsKit.config(bundle, locomotion: 0.5, posture: 0.3, arm: 0.5)
        let (prepared, refusal) = PreparedMotionHeads.prepare(config.motionHeads)
        XCTAssertNil(refusal)
        let mh = try XCTUnwrap(prepared)
        let uninformative = MotionHeadsWindow(
            startTs: 0, endTs: 10, posture: bundle.heads[.posture]!.prior, locomotion: bundle.heads[.locomotion]!.prior,
            armBehavior: bundle.heads[.armBehavior]!.prior, isOOD: false)
        let t = try XCTUnwrap(mh.terms(for: uninformative, hartSpeaks: false))
        for x in t.locomotion!.L + t.posture!.L + t.arm!.L { XCTAssertEqual(x, 1, accuracy: 1e-12) }
        XCTAssertTrue(t.opens.isEmpty)

        // And through the decoder: the published heads do not move.
        let sim = quietWrist(200)
        let off = decode(sim.observations)
        let on = decode(MotionHeadsKit.attach(sim.observations) { _ in uninformative }, config)
        XCTAssertEqual(off.states.count, on.states.count)
        for (a, b) in zip(off.states, on.states) {
            for c in PostureClass.allCases { XCTAssertEqual(a.posture[c], b.posture[c], accuracy: 1e-9) }
            for c in LocomotionClass.allCases { XCTAssertEqual(a.locomotion[c], b.locomotion[c], accuracy: 1e-9) }
            for c in ArmBehaviorClass.allCases { XCTAssertEqual(a.armBehavior[c], b.armBehavior[c], accuracy: 1e-9) }
            XCTAssertEqual(a.displayContext, b.displayContext)
        }
    }

    func testAnOODWindowContributesNothing() throws {
        let sim = quietWrist(200)
        let config = MotionHeadsKit.config()
        let off = decode(sim.observations)
        let on = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(self.P, "recumbent", 0.97),
                                  locomotion: MotionHeadsKit.peaked(self.L, "stairs", 0.97),
                                  arm: MotionHeadsKit.peaked(self.A, "exercise_motion", 0.97), ood: true)
        }, config)
        XCTAssertEqual(try MotionHeadsKit.statesWithoutProvenance(on.states),
                       try MotionHeadsKit.statesWithoutProvenance(off.states))
        XCTAssertEqual(on.snapshot.body, off.snapshot.body)
        XCTAssertEqual(on.snapshot.arm, off.snapshot.arm)
        XCTAssertEqual(on.motionHeads?.oodWindows, on.motionHeads?.windowsIngested)
        XCTAssertGreaterThan(on.motionHeads?.oodWindows ?? 0, 0)
        XCTAssertEqual(on.motionHeads?.evidenceSeconds, 0)
    }

    // MARK: - What the channels do

    func testInertiaAloneMovesPostureWithinTheStationaryModes() throws {
        let sim = quietWrist(300)
        let off = decode(sim.observations)
        let config = MotionHeadsKit.config(posture: 0.5)
        let upright = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(self.P, "upright_stationary", 0.9))
        }, config)
        let seated = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(self.P, "seated_likely", 0.9))
        }, config)
        let from = sim.observations[0].ts + 120
        let baseUpright = mean(off.states, from: from) { $0.posture[.uprightStationary] }
        XCTAssertGreaterThan(mean(upright.states, from: from) { $0.posture[.uprightStationary] }, baseUpright + 0.05)
        XCTAssertLessThan(mean(seated.states, from: from) { $0.posture[.uprightStationary] }, baseUpright - 0.05)
        XCTAssertGreaterThan(mean(seated.states, from: from) { $0.posture[.seatedLikely] },
                             mean(off.states, from: from) { $0.posture[.seatedLikely] } + 0.05)
        // A wrist cannot see body height: even sustained, confident posture evidence leaves real ambiguity.
        XCTAssertLessThan(seated.states.last!.posture[.seatedLikely], 0.95)
        XCTAssertTrue(seated.states.last!.versions.motionHeads?.hasPrefix("inertia-1:") ?? false)
        XCTAssertNil(seated.states.last!.versions.encoderId, "no encoder spoke: Inertia is not reported as one")
    }

    func testInertiaAloneMovesLocomotion() throws {
        // Walking without the step counter: movement says "something rhythmic", nothing names it.
        var sim = ActivitySim(start: 1_760_000_000, seed: 9)
        var o = ActivitySim.Options()
        o.steps = false
        o.sleep = .awake
        sim.walk(240, opt: o)
        let off = decode(sim.observations)
        let config = MotionHeadsKit.config(locomotion: 0.5, posture: 0, arm: 0)
        let walking = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, locomotion: MotionHeadsKit.peaked(self.L, "walking", 0.9))
        }, config)
        let stationary = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, locomotion: MotionHeadsKit.peaked(self.L, "stationary", 0.9))
        }, config)
        let from = sim.observations[0].ts + 60
        let base = mean(off.states, from: from) { $0.locomotion[.walking] }
        XCTAssertGreaterThan(mean(walking.states, from: from) { $0.locomotion[.walking] }, base + 0.03)
        XCTAssertLessThan(mean(stationary.states, from: from) { $0.locomotion[.walking] }, base - 0.03)
    }

    func testThePostureChannelNeverChangesTheStationaryMassAtAStep() throws {
        // Two decoders with identical beliefs; at one step both see the same second with a confident posture
        // window, one with the posture channel on and one with it at weight 0. The total mass of the
        // stationary / transition set must be the same after the step; only its split may differ.
        let streams: [ActivitySim] = {
            var a = quietWrist(120)
            var b = ActivitySim(start: 1_760_000_000, seed: 4)
            b.desk(80); b.walk(40)
            var c = ActivitySim(start: 1_760_000_000, seed: 8)
            c.walk(60); c.still(30); c.postureShift(netDegrees: 60); c.still(20)
            a.still(1); b.walk(1); c.still(1)
            return [a, b, c]
        }()
        for (k, sim) in streams.enumerated() {
            for top in P {
                var on = ActivityContextDecoder(config: MotionHeadsKit.config(locomotion: 0, posture: 0.5, arm: 0))
                var zero = ActivityContextDecoder(config: MotionHeadsKit.config(locomotion: 0, posture: 0, arm: 0))
                let obs = sim.observations
                for o in obs.dropLast() { on.ingest(o); zero.ingest(o) }
                XCTAssertEqual(on.snapshot().body, zero.snapshot().body)
                var last = obs.last!
                last.motionHeads = MotionHeadsKit.window(endingAt: last.ts, posture: MotionHeadsKit.peaked(P, top, 0.95))
                on.ingest(last); zero.ingest(last)
                let a = MotionHeadsKit.modeMass(on.snapshot()), b = MotionHeadsKit.modeMass(zero.snapshot())
                let sa = MotionHeadsKit.postureSet.reduce(0) { $0 + a[$1.rawValue] }
                let sb = MotionHeadsKit.postureSet.reduce(0) { $0 + b[$1.rawValue] }
                XCTAssertEqual(sa, sb, accuracy: 1e-12, "stream \(k), posture \(top)")
                for m in BodyMode.allCases where !MotionHeadsKit.postureSet.contains(m) {
                    XCTAssertEqual(a[m.rawValue], b[m.rawValue], accuracy: 1e-12, "stream \(k), \(m) moved")
                }
                if top == "recumbent" {
                    XCTAssertGreaterThan(a[BodyMode.bedRest.rawValue], b[BodyMode.bedRest.rawValue])
                }
            }
        }
    }

    func testTheArmHeadReachesOnlyTheArmChain() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 2)
        sim.desk(200)
        let off = decode(sim.observations)
        let on = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, arm: MotionHeadsKit.peaked(self.A, "fidgeting", 0.9))
        }, MotionHeadsKit.config(locomotion: 0, posture: 0, arm: 0.5))
        XCTAssertEqual(on.snapshot.body, off.snapshot.body, "the body chain never sees the arm head")
        let from = sim.observations[0].ts + 60
        let before = mean(off.states, from: from) { $0.armBehavior[.fidgeting] }
        let after = mean(on.states, from: from) { $0.armBehavior[.fidgeting] }
        XCTAssertGreaterThan(after, before + 0.02)
        XCTAssertGreaterThan(after, before * 3)
    }

    // MARK: - HART and Inertia are distinct channels

    func testHartAndInertiaAreDistinctTemperedChannelsNotAnAverage() throws {
        // A fast gait with no step counter (so the encoders matter): HART is sure of walking, Inertia of running.
        var sim = ActivitySim(start: 1_760_000_000, seed: 12)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking", p: 0.9)
        o.steps = false
        sim.run(240, opt: o)
        let inertiaRunning = MotionHeadsKit.peaked(L, "running", 0.9)
        let both = decode(MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, locomotion: inertiaRunning)
        }, MotionHeadsKit.config(locomotion: 0.5, posture: 0, arm: 0))

        // The forbidden baseline: 0.5·HART + 0.5·Inertia (mapped to the v1 labels) in the encoder slot.
        let averaged = sim.observations.map { obs -> ActivityObservation in
            var obs = obs
            guard let enc = obs.encoder else { return obs }
            var v1: [String: Double] = ["stationary": 0, "walking": 0, "running": 0, "other_movement": 0]
            for (c, p) in inertiaRunning {
                switch c {
                case "stationary": v1["stationary"]! += p
                case "walking", "brisk_walking", "stairs": v1["walking"]! += p
                case "running": v1["running"]! += p
                default: v1["other_movement"]! += p
                }
            }
            var mix: [String: Double] = [:]
            for k in Set(enc.classProbs.keys).union(v1.keys) {
                mix[k] = 0.5 * (enc.classProbs[k] ?? 0) + 0.5 * (v1[k] ?? 0)
            }
            obs.encoder = MotionEncoderOutput(encoderId: enc.encoderId, encoderVersion: enc.encoderVersion,
                                              startTs: enc.startTs, endTs: enc.endTs, classProbs: mix,
                                              calibrated: enc.calibrated, abstained: enc.abstained)
            return obs
        }
        let average = decode(averaged)
        let hartOnly = decode(sim.observations)
        let from = sim.observations[0].ts + 60
        func meanHead(_ t: ActivityContextTrack) -> [Double] {
            LocomotionClass.allCases.map { c in mean(t.states, from: from) { $0.locomotion[c] } }
        }
        func l1(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } }
        let fused = meanHead(both), avg = meanHead(average), hart = meanHead(hartOnly)
        let running = LocomotionClass.allCases.firstIndex(of: .running)!
        // Averaging hands the encoder slot (weight 0.8) a confident running vote and the decode flips to
        // running; as its own budgeted, tempered channel Inertia cannot outvote a confident HART.
        XCTAssertGreaterThan(avg[running], 0.5, "\(avg)")
        XCTAssertLessThan(fused[running], 0.2, "\(fused)")
        XCTAssertGreaterThan(l1(fused, avg), 0.5, "fusion is not the naive average: \(fused) vs \(avg)")
        XCTAssertGreaterThan(l1(fused, hart), 0.005, "Inertia does contribute")
        XCTAssertGreaterThan(fused[running], hart[running])
        // Averaging rewrites the HART channel itself; fusion leaves it intact and adds a tempered term, so
        // the fused locomotion head stays closer to HART's than the averaged one does.
        XCTAssertLessThan(l1(fused, hart), l1(avg, hart))
        // Each expert stays identifiable in the provenance.
        XCTAssertEqual(both.states.last?.versions.encoderId, "hart")
        XCTAssertTrue(both.states.last?.versions.motionHeads?.hasPrefix("inertia-1:") ?? false)
        XCTAssertNil(average.states.last?.versions.motionHeads)
    }

    func testTheInertiaTermIsBoundedByTheTemperatureAndBudget() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 12)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking")
        sim.walk(60, opt: o)
        let config = MotionHeadsKit.config(locomotion: 0.8, posture: 0.8, arm: 0.8)  // body sum 1.6 → budget 0.5
        let mh = try XCTUnwrap(PreparedMotionHeads.prepare(config.motionHeads).prepared)
        let w = mh.effectiveWeights(hartSpeaks: true)
        XCTAssertEqual(w.locomotion + w.posture, 0.5, accuracy: 1e-12, "the body budget is shared")
        XCTAssertEqual(w.locomotion / w.posture, 0.5, accuracy: 1e-12, "HART redundancy halves locomotion first")
        XCTAssertEqual(w.arm, 0.5, "the arm weight is capped")

        var window = ActivityFeatureWindow()
        var lastF: ActivityFeatures?
        for obs in sim.observations { lastF = window.push(obs, restingHR: 60, maxHR: 190, motionHeadsHoldS: 5) }
        var f = try XCTUnwrap(lastF)
        XCTAssertNotNil(f.encoder)
        f.motionHeads = MotionHeadsKit.window(endingAt: f.ts, locomotion: MotionHeadsKit.peaked(L, "running", 1.0))
        let T = 0.35
        let base = ActivityContextModel.score(f, temperature: T)
        let with = ActivityContextModel.score(f, temperature: T, motionHeads: mh)
        let bound = T * w.locomotion * log(10) + 1e-12
        for m in 0..<BodyMode.count {
            XCTAssertLessThanOrEqual(abs(with.logL[m] - base.logL[m]), bound, "mode \(m)")
        }
        XCTAssertEqual(with.logL[BodyMode.unknown.rawValue], base.logL[BodyMode.unknown.rawValue])
        XCTAssertEqual(with.channels, base.channels, "Inertia never counts as an evidence channel")
        XCTAssertGreaterThan(with.logL[BodyMode.run.rawValue] - base.logL[BodyMode.run.rawValue], 0)
    }

    // MARK: - Class reliability, merging, covers, gates

    func testAnAbstainedClassMergedIntoItsPartnerCarriesNoSplit() throws {
        let supported = L
        var heads = MotionHeadsKit.bundle().heads
        heads[.locomotion] = MotionHeadsKit.spec(.locomotion, supported: supported, status: ["stairs": .abstain],
                                                 mergeInto: ["stairs": "walking"])
        let bundle = MotionHeadsKit.bundle(heads: heads)
        // Exactly representable masses, so both splits leave the other classes bit-identical.
        func q(_ stairs: Double, _ walking: Double) -> [String: Double] {
            var out: [String: Double] = [:]
            let rest = (1 - stairs - walking) / Double(supported.count - 2)
            for c in supported { out[c] = c == "stairs" ? stairs : (c == "walking" ? walking : rest) }
            return out
        }
        var sim = ActivitySim(start: 1_760_000_000, seed: 21)
        sim.walk(200)
        let config = MotionHeadsKit.config(bundle, locomotion: 0.5, posture: 0, arm: 0)
        let a = decode(MotionHeadsKit.attach(sim.observations) { MotionHeadsKit.window(endingAt: $0, locomotion: q(0.5, 0.25)) }, config)
        let b = decode(MotionHeadsKit.attach(sim.observations) { MotionHeadsKit.window(endingAt: $0, locomotion: q(0.25, 0.5)) }, config)
        // (The snapshots differ only in the window they hold.)
        XCTAssertEqual(a.states, b.states, "the stairs-vs-walking split is not evidence")
        XCTAssertEqual(a.snapshot.body, b.snapshot.body)
        XCTAssertEqual(a.snapshot.arm, b.snapshot.arm)
        // Without the merge the split does matter.
        var strongHeads = heads
        strongHeads[.locomotion] = MotionHeadsKit.spec(.locomotion, supported: supported)
        let strong = MotionHeadsKit.config(MotionHeadsKit.bundle(heads: strongHeads), locomotion: 0.5, posture: 0, arm: 0)
        let c = decode(MotionHeadsKit.attach(sim.observations) { MotionHeadsKit.window(endingAt: $0, locomotion: q(0.5, 0.25)) }, strong)
        let d = decode(MotionHeadsKit.attach(sim.observations) { MotionHeadsKit.window(endingAt: $0, locomotion: q(0.25, 0.5)) }, strong)
        XCTAssertNotEqual(c.snapshot.body, d.snapshot.body)
    }

    func testAWeakClassCarriesHalfTheWeightAndAnUnpartneredAbstainedClassNone() throws {
        func prepared(_ status: [String: MotionHeadClassStatus]) -> PreparedMotionHead {
            PreparedMotionHead.prepare(MotionHeadsKit.spec(.locomotion, status: status), head: .locomotion,
                                       targets: BodyMode.count, neutralTargets: [0]) { m, c in
                LocomotionClass(rawValue: c).flatMap { ActivityContextModel.profiles[m].locomotion[$0] } ?? 0
            }!
        }
        let q = MotionHeadsKit.peaked(L, "walking", 0.9)
        let strong = prepared([:]).evaluate(q)!
        let weak = prepared(["walking": .weak]).evaluate(q)!
        XCTAssertEqual(strong.rel, 1, accuracy: 1e-12)
        XCTAssertEqual(weak.rel, 0.9 * 0.5 + 0.1, accuracy: 1e-12)
        let abstained = prepared(["walking": .abstain])
        XCTAssertEqual(abstained.dropped, ["walking"])
        XCTAssertEqual(abstained.evaluate(q)!.rel, 0.1, accuracy: 1e-12)
        // Through the decoder: the weak reading moves the walk mode less than the strong one.
        var sim = ActivitySim(start: 1_760_000_000, seed: 9)
        var o = ActivitySim.Options()
        o.steps = false
        sim.walk(200, opt: o)
        func walkMass(_ status: [String: MotionHeadClassStatus]) -> Double {
            var heads = MotionHeadsKit.bundle().heads
            heads[.locomotion] = MotionHeadsKit.spec(.locomotion, status: status)
            let t = decode(MotionHeadsKit.attach(sim.observations) { MotionHeadsKit.window(endingAt: $0, locomotion: q) },
                           MotionHeadsKit.config(MotionHeadsKit.bundle(heads: heads), locomotion: 0.5, posture: 0, arm: 0))
            return mean(t.states, from: sim.observations[0].ts + 60) { $0.locomotion[.walking] }
        }
        let base = mean(decode(sim.observations).states, from: sim.observations[0].ts + 60) { $0.locomotion[.walking] }
        let s = walkMass([:]) - base, w = walkMass(["walking": .weak])
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThan(w - base, s)
        XCTAssertGreaterThan(w - base, 0)
    }

    func testACoveringClassReadsAsEveryClassItCovers() throws {
        let supported = L.filter { $0 != "brisk_walking" }
        func prepared(_ covers: [String: [String]]) -> PreparedMotionHead {
            PreparedMotionHead.prepare(MotionHeadsKit.spec(.locomotion, supported: supported, covers: covers),
                                       head: .locomotion, targets: BodyMode.count, neutralTargets: [0]) { m, c in
                LocomotionClass(rawValue: c).flatMap { ActivityContextModel.profiles[m].locomotion[$0] } ?? 0
            }!
        }
        let plain = prepared([:]), covering = prepared(["walking": ["walking", "brisk_walking"]])
        let brisk = BodyMode.briskWalk.rawValue, walk = BodyMode.walk.rawValue, run = BodyMode.run.rawValue
        let w = covering.roots.firstIndex(of: "walking")!
        // The covering class's compat is the max over the covered classes' rows: the brisk-walk mode reads
        // brisk_walking 0.88 through `walking` instead of its residual 0.08.
        XCTAssertGreaterThan(covering.compat[brisk]![w], plain.compat[brisk]![w])
        XCTAssertEqual(covering.compat[walk]![w], plain.compat[walk]![w], accuracy: 1e-12, "max(0.93, 0.04) = 0.93")
        // The run mode had brisk_walking 0.04 next to walking 0: covering walking now gives it that share.
        XCTAssertGreaterThan(covering.compat[run]![w], plain.compat[run]![w])
        let q = MotionHeadsKit.peaked(supported, "walking", 0.9)
        XCTAssertGreaterThan(covering.evaluate(q)!.L[brisk], plain.evaluate(q)!.L[brisk])
        XCTAssertGreaterThan(covering.evaluate(q)!.L[brisk], 1, "pace-unknown walking supports a brisk walk")
        for row in covering.compat.compactMap({ $0 }) { XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-12) }
    }

    func testOnlyAStrongClassAboveItsThresholdOpensASpecialistGate() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 31)
        sim.walk(180)
        func stairsShare(_ q: Double, status: MotionHeadClassStatus = .strong, ood: Bool = false,
                         weight: Double = 0.5) -> (Double, Int) {
            var heads = MotionHeadsKit.bundle().heads
            heads[.locomotion] = MotionHeadsKit.spec(.locomotion, status: ["stairs": status], tau: 0.8)
            let t = decode(MotionHeadsKit.attach(sim.observations) { e in
                MotionHeadsKit.window(endingAt: e, locomotion: MotionHeadsKit.peaked(self.L, "stairs", q), ood: ood)
            }, MotionHeadsKit.config(MotionHeadsKit.bundle(heads: heads), locomotion: weight, posture: 0, arm: 0))
            return (mean(t.states, from: sim.observations[0].ts + 60) { $0.locomotion[.stairs] },
                    t.motionHeads?.specialistOpenings ?? -1)
        }
        let base = mean(decode(sim.observations).states, from: sim.observations[0].ts + 60) { $0.locomotion[.stairs] }
        let open = stairsShare(0.9)
        XCTAssertGreaterThan(open.1, 0)
        XCTAssertGreaterThan(open.0, base + 0.05, "a strong stairs reading above τ lets the stairs mode in")
        for (label, r) in [("below τ", stairsShare(0.7)), ("weak", stairsShare(0.9, status: .weak)),
                           ("OOD", stairsShare(0.9, ood: true)), ("zero weight", stairsShare(0.9, weight: 0))] {
            XCTAssertEqual(r.1, 0, label)
            XCTAssertLessThan(r.0, base + 0.03, label)
        }
    }

    // MARK: - Refusals

    func testWhoMayFeedTheDecoder() {
        XCTAssertNil(MotionHeadsKit.config().motionHeads!.evidenceRefusal)
        XCTAssertEqual(MotionHeadsKit.config(MotionHeadsKit.bundle(kind: .standin)).motionHeads!.evidenceRefusal,
                       "encoder_kind_standin")
        XCTAssertEqual(MotionHeadsKit.config(MotionHeadsKit.bundle(tier: .shadow)).motionHeads!.evidenceRefusal,
                       "evidence_tier_shadow")
        XCTAssertEqual(MotionHeadsKit.config(mode: .shadow).motionHeads!.evidenceRefusal, "shadow_mode")
        XCTAssertEqual(MotionHeadsKit.config(mode: .production).motionHeads!.evidenceRefusal, "evidence_tier_candidate")
        XCTAssertNil(MotionHeadsKit.config(MotionHeadsKit.bundle(tier: .production), mode: .production).motionHeads!.evidenceRefusal)
        // The test-only override admits a stand-in, and its provenance never claims Inertia-1.
        let standIn = MotionHeadsKit.config(MotionHeadsKit.bundle(kind: .standin, tier: .shadow), standInOverride: true)
        XCTAssertNil(standIn.motionHeads!.evidenceRefusal)
        XCTAssertTrue(standIn.motionHeads!.provenanceStamp!.hasPrefix("standin-test:"))
        XCTAssertFalse(MotionHeadsEvidenceConfig.candidate(bundle: MotionHeadsKit.bundle()).allowStandInEvidenceForTesting)
    }

    func testARefusedBundleIsIgnoredAndReported() throws {
        let sim = quietWrist(120)
        let heads = MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(self.P, "recumbent", 0.95))
        }
        let config = MotionHeadsKit.config(MotionHeadsKit.bundle(kind: .standin))
        let refused = decode(heads, config)
        let off = decode(sim.observations)
        XCTAssertEqual(try encoded(refused), try encoded(off))
        XCTAssertEqual(refused.motionHeads?.refusal, "encoder_kind_standin")
        XCTAssertNil(refused.motionHeads?.stamp)
        XCTAssertEqual(config.cacheTag, ActivityDecoderConfig().cacheTag)
        let decoder = ActivityContextDecoder(config: config)
        XCTAssertEqual(decoder.motionHeadsRefusal, "encoder_kind_standin")
        XCTAssertNil(decoder.motionHeadsStamp)
        // With the override the same windows are evidence.
        let admitted = decode(heads, MotionHeadsKit.config(MotionHeadsKit.bundle(kind: .standin), standInOverride: true))
        XCTAssertNotEqual(try encoded(admitted), try encoded(off))
    }

    func testConfigBoundsAreValidated() throws {
        let b = MotionHeadsKit.bundle()
        typealias V = MotionHeadsEvidenceConfig.ValidationError
        func check(_ c: MotionHeadsEvidenceConfig, _ expected: V) {
            XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? V, expected) }
            XCTAssertNotNil(c.evidenceRefusal)
            var dc = ActivityDecoderConfig()
            dc.motionHeads = c
            XCTAssertEqual(dc.cacheTag, ActivityDecoderConfig().cacheTag)
            XCTAssertNil(ActivityContextDecoder(config: dc).motionHeadsStamp)
        }
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, locomotionWeight: 0.9), .aboveCeiling("locomotionWeight"))
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, armWeight: -0.1), .negative("armWeight"))
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, postureWeight: .nan), .nonFinite("postureWeight"))
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, bodyBudget: 0.81), .aboveCeiling("bodyBudget"))
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, hartRedundancy: 1.5), .redundancyOutOfRange)
        check(MotionHeadsEvidenceConfig(mode: .candidate, bundle: b, transitionWeight: 0.1), .transitionWeightUnsupported)
        XCTAssertNoThrow(try MotionHeadsEvidenceConfig.candidate(bundle: b).validate())
        let d = MotionHeadsEvidenceConfig.candidate(bundle: b)
        XCTAssertEqual([d.locomotionWeight, d.postureWeight, d.armWeight, d.transitionWeight, d.bodyBudget, d.armBudget,
                        d.hartRedundancy], [0.25, 0.25, 0.25, 0, 0.5, 0.5, 0.5])
    }

    // MARK: - Provenance, cache tag, restore, determinism

    func testProvenanceAndCacheTagAppearOnlyWhenActive() throws {
        let off = ActivityDecoderConfig.personalized(restingHeartRate: 57, maxHeartRate: 188)
        let on = MotionHeadsKit.config(base: off)
        let stamp = try XCTUnwrap(on.motionHeads?.provenanceStamp)
        XCTAssertEqual(stamp, "inertia-1:\(MotionHeadsKit.bundleSha.prefix(12)):\(on.motionHeads!.configTag)")
        XCTAssertEqual(on.cacheTag, off.cacheTag + "-ih\(MotionHeadsKit.bundleSha.prefix(12))\(on.motionHeads!.configTag)")
        XCTAssertTrue(on.cacheTag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "filename-safe")
        XCTAssertNotEqual(MotionHeadsKit.config(base: off, locomotion: 0.2).cacheTag, on.cacheTag)
        XCTAssertNotEqual(MotionHeadsKit.config(MotionHeadsKit.bundle(sha: String(repeating: "ef", count: 32)), base: off).cacheTag,
                          on.cacheTag)

        let sim = quietWrist(60)
        let t = decode(sim.observations, on)
        XCTAssertEqual(t.snapshot.versions.motionHeads, stamp)
        XCTAssertTrue(t.states.allSatisfy { $0.versions.motionHeads == stamp })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t.states.last!)) as? [String: Any])
        XCTAssertEqual((json["versions"] as? [String: Any])?["motion_heads"] as? String, stamp)
    }

    func testRestoreRejectsAMotionHeadsProvenanceMismatch() throws {
        let sim = quietWrist(120)
        let obs = MotionHeadsKit.attach(sim.observations) { e in
            MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(self.P, "seated_likely", 0.8))
        }
        let on = MotionHeadsKit.config()
        let first = decode(Array(obs.prefix(60)), on)
        let snap = try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: JSONEncoder().encode(first.snapshot))
        XCTAssertEqual(ActivityContextDecoder(config: on, restoring: snap).restoreOutcome, .resumed)
        XCTAssertEqual(ActivityContextDecoder(config: ActivityDecoderConfig(), restoring: snap).restoreOutcome,
                       .discarded("motion_heads_mismatch"))
        XCTAssertEqual(ActivityContextDecoder(config: MotionHeadsKit.config(posture: 0.3), restoring: snap).restoreOutcome,
                       .discarded("motion_heads_mismatch"))
        // …and a snapshot written without Inertia is not continued with it.
        let plain = decode(Array(sim.observations.prefix(60))).snapshot
        XCTAssertEqual(ActivityContextDecoder(config: on, restoring: plain).restoreOutcome, .discarded("motion_heads_mismatch"))
        // Resuming with the same config continues exactly.
        let whole = decode(obs, on)
        let resumed = ActivityContextTrackBuilder.decode(Array(obs.dropFirst(60)), config: on, resuming: snap)
        XCTAssertEqual(first.states + resumed.states, whole.states)
        XCTAssertEqual(resumed.snapshot, whole.snapshot)
    }

    func testDecodingTheSameInputTwiceIsIdentical() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 41)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking")
        sim.desk(120); sim.walk(120, opt: o); sim.run(60); sim.still(60)
        let obs = MotionHeadsKit.attach(sim.observations) { ActivityContextGoldenTests.loudWindow($0) }
        let config = MotionHeadsKit.config(locomotion: 0.3, posture: 0.2, arm: 0.4)
        XCTAssertEqual(try encoded(decode(obs, config)), try encoded(decode(obs, config)))
    }

    // MARK: - Track builder

    func testInertiaNeverCreatesAnObservationSecond() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 5)
        sim.desk(30)
        sim.gap(40)
        sim.desk(30)
        let input = sim.trackInput()
        let start = input.dayStart
        let windows = [
            MotionHeadsKit.window(endingAt: start + 20),          // attaches at e
            MotionHeadsKit.window(endingAt: start + 29),          // e observed (the last desk second)
            MotionHeadsKit.window(endingAt: start + 45),          // inside the gap: no second in [e, e+2]
            MotionHeadsKit.window(endingAt: start + 68),          // e+2 = 70 is the first second after the gap
            MotionHeadsKit.window(endingAt: start + 10_000),      // past the day
        ]
        var withHeads = input
        withHeads.motionHeads = MotionHeadsTrackInput(bundle: MotionHeadsKit.bundle(), windows: windows)
        let config = MotionHeadsKit.config()
        let plain = ActivityContextTrackBuilder.observations(for: input)
        let (obs, report) = ActivityContextTrackBuilder.observations(for: withHeads, config: config)
        XCTAssertEqual(obs.map(\.ts), plain.map(\.ts), "no second is created")
        XCTAssertEqual(obs.filter { $0.motionHeads != nil }.map(\.ts), [start + 20, start + 29, start + 70])
        XCTAssertEqual(report?.attached, 3)
        XCTAssertEqual(report?.droppedNoObservation, 1)
        XCTAssertEqual(report?.droppedOutOfRange, 1)
        XCTAssertEqual(report?.windowsIn, 5)
        let track = ActivityContextTrackBuilder.build(withHeads, config: config)
        XCTAssertEqual(track.observedSeconds, plain.count)
        XCTAssertEqual(track.motionHeads?.attached, 3)
        XCTAssertEqual(track.motionHeads?.windowsIngested, 3)

        // A config for another bundle attaches nothing.
        let other = MotionHeadsKit.config(MotionHeadsKit.bundle(sha: String(repeating: "01", count: 32)))
        let (none, mismatch) = ActivityContextTrackBuilder.observations(for: withHeads, config: other)
        XCTAssertTrue(none.allSatisfy { $0.motionHeads == nil })
        XCTAssertEqual(mismatch?.refusal, "bundle_mismatch")
        // No config: nothing attached, no report.
        let (bare, noReport) = ActivityContextTrackBuilder.observations(for: withHeads, config: ActivityDecoderConfig())
        XCTAssertTrue(bare.allSatisfy { $0.motionHeads == nil })
        XCTAssertNil(noReport)
    }

    func testAWindowAppliesForOneHopFromTheSecondItArrived() throws {
        var window = ActivityFeatureWindow()
        var obs = ActivityObservation(ts: 100, dynAccelG: 0.01, wear: .onWrist)
        obs.motionHeads = MotionHeadsKit.window(endingAt: 100)
        XCTAssertNotNil(window.push(obs, restingHR: 60, maxHR: 190, motionHeadsHoldS: 5).motionHeads)
        for ts in 101...104 {
            XCTAssertNotNil(window.push(ActivityObservation(ts: ts, dynAccelG: 0.01, wear: .onWrist),
                                        restingHR: 60, maxHR: 190, motionHeadsHoldS: 5).motionHeads, "\(ts)")
        }
        XCTAssertNil(window.push(ActivityObservation(ts: 105, dynAccelG: 0.01, wear: .onWrist),
                                 restingHR: 60, maxHR: 190, motionHeadsHoldS: 5).motionHeads)
        // Off (hold 0): never kept.
        var off = ActivityFeatureWindow()
        XCTAssertNil(off.push(obs, restingHR: 60, maxHR: 190).motionHeads)
        XCTAssertNil(off.motionHeads)
    }
}
