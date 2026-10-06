import XCTest
@testable import StrandAnalytics

/// ElderNet as decoder evidence (ELDERNET.md §5, `ActivityContextGaitQualityFusion.swift`): what the channel does,
/// what it never does, how it shares the accelerometer with HART and Inertia, the reported gait block, and every
/// way it is refused.
final class GaitQualityDecoderTests: XCTestCase {

    private let L = MotionHead.locomotion.classOrder
    private let P = MotionHead.posture.classOrder
    private let T = 0.35

    private func decode(_ obs: [ActivityObservation], _ config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> ActivityContextTrack {
        ActivityContextTrackBuilder.decode(obs, config: config)
    }

    private func mean(_ states: [ActivityContextState], from: Int, to: Int = .max,
                      _ value: (ActivityContextState) -> Double) -> Double {
        let xs = states.filter { $0.ts >= from && $0.ts < to }.map(value)
        return xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    private func encoded(_ track: ActivityContextTrack) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(track.states), as: UTF8.self)
            + String(decoding: try e.encode(track.snapshot), as: UTF8.self)
    }

    private func prepared(_ config: ActivityDecoderConfig) throws -> PreparedGaitQuality {
        let (p, why) = PreparedGaitQuality.prepare(config.gaitQuality)
        XCTAssertNil(why)
        return try XCTUnwrap(p)
    }

    private func inertia(locomotion wl: Double, posture wp: Double, bodyBudget: Double) throws -> PreparedMotionHeads {
        let c = MotionHeadsEvidenceConfig(mode: .candidate, bundle: MotionHeadsKit.bundle(), locomotionWeight: wl,
                                          postureWeight: wp, armWeight: 0, bodyBudget: bodyBudget, hartRedundancy: 0.5)
        return try XCTUnwrap(PreparedMotionHeads.prepare(c).prepared)
    }

    /// Walking with no step counter and no encoder: movement says "something rhythmic", nothing names it.
    private func bareWalk(_ seconds: Int = 240, seed: UInt64 = 9) -> ActivitySim {
        var sim = ActivitySim(start: 1_760_000_000, seed: seed)
        var o = ActivitySim.Options()
        o.steps = false
        o.sleep = .awake
        sim.walk(seconds, opt: o)
        return sim
    }

    /// The features at the last second of `sim`.
    private func lastFeatures(_ sim: ActivitySim) throws -> ActivityFeatures {
        var window = ActivityFeatureWindow()
        var last: ActivityFeatures?
        for obs in sim.observations { last = window.push(obs, restingHR: 60, maxHR: 190, motionHeadsHoldS: 5,
                                                         gaitQualityHoldS: 5) }
        return try XCTUnwrap(last)
    }

    // MARK: - Neutrality

    func testAWindowThatSaysThePriorIsExactlyNeutral() throws {
        let config = GaitKit.config(prior: 0.2, gait: 0.5)
        let g = try prepared(config)
        for x in g.likelihood(0.2) { XCTAssertEqual(x, 1, "q = π gives r ≡ 1 on every mode, exactly") }
        let up = g.likelihood(0.9), down = g.likelihood(0.01)
        for m in PreparedGaitQuality.gaitModes { XCTAssertGreaterThan(up[m.rawValue], 1); XCTAssertLessThan(down[m.rawValue], 1) }
        for m in PreparedGaitQuality.nonGaitModes { XCTAssertLessThan(up[m.rawValue], 1); XCTAssertGreaterThan(down[m.rawValue], 1) }
        for m in [BodyMode.unknown, .run, .otherExercise, .sitToStand, .standToSit, .lyingDown, .gettingUp] {
            XCTAssertEqual(up[m.rawValue], 1, "\(m) is neutral"); XCTAssertEqual(down[m.rawValue], 1)
        }
        for x in up + down { XCTAssertTrue(PreparedGaitQuality.lrClip.contains(x)) }

        // Through the decoder: the published heads do not move and the score is untouched mode by mode.
        let sim = bareWalk(200)
        let off = decode(sim.observations)
        let on = decode(GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.2) }, config)
        XCTAssertEqual(off.states.count, on.states.count)
        for (a, b) in zip(off.states, on.states) {
            for c in PostureClass.allCases { XCTAssertEqual(a.posture[c], b.posture[c], accuracy: 1e-9) }
            for c in LocomotionClass.allCases { XCTAssertEqual(a.locomotion[c], b.locomotion[c], accuracy: 1e-9) }
            XCTAssertEqual(a.displayContext, b.displayContext)
        }
        var f = try lastFeatures(sim)
        f.gaitQuality = GaitKit.window(endingAt: f.ts, p: 0.2)
        let base = ActivityContextModel.score(f, temperature: T)
        let with = ActivityContextModel.score(f, temperature: T, gaitQuality: g)
        XCTAssertEqual(with.logL, base.logL, "an uninformative window adds exactly nothing to any mode")
        XCTAssertTrue(with.gaitQualityApplied)
    }

    // MARK: - What the channel does

    func testElderNetAloneMovesLocomotionBothWays() throws {
        let sim = bareWalk()
        let config = GaitKit.config(gait: 0.5)
        let off = decode(sim.observations)
        let gait = decode(GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.97) }, config)
        let still = decode(GaitKit.attach(sim.observations) { GaitKit.prefiltered(endingAt: $0) }, config)
        let from = sim.observations[0].ts + 60
        let base = mean(off.states, from: from) { $0.locomotion[.walking] + $0.locomotion[.briskWalking] }
        XCTAssertGreaterThan(mean(gait.states, from: from) { $0.locomotion[.walking] + $0.locomotion[.briskWalking] },
                             base + 0.02)
        XCTAssertLessThan(mean(still.states, from: from) { $0.locomotion[.walking] + $0.locomotion[.briskWalking] },
                          base - 0.02)
        XCTAssertTrue(gait.states.last!.versions.gaitQuality?.hasPrefix("eldernet:\(GaitKit.version):") ?? false)
        XCTAssertNil(gait.states.last!.versions.encoderId, "ElderNet is not reported as an encoder")
        XCTAssertNil(gait.states.last!.versions.motionHeads)
        XCTAssertGreaterThan(gait.gaitQuality?.evidenceSeconds ?? 0, 200)
        XCTAssertEqual(still.gaitQuality?.prefilteredWindows, still.gaitQuality?.windowsIngested)
    }

    func testTheGaitTermIsTemperedWeightedDiscountedAndNeverAnEvidenceChannel() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 12)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking")
        sim.walk(60, opt: o)
        let config = GaitKit.config(gait: 0.8, hartRedundancy: 0.65, inertiaRedundancy: 0.5, budget: 0.8)
        let g = try prepared(config)
        XCTAssertEqual(g.effectiveWeights(hartSpeaks: false, inertiaLocomotionSpeaks: false).gait, 0.8, accuracy: 1e-12)
        XCTAssertEqual(g.effectiveWeights(hartSpeaks: true, inertiaLocomotionSpeaks: false).gait, 0.8 * 0.35, accuracy: 1e-12)
        XCTAssertEqual(g.effectiveWeights(hartSpeaks: false, inertiaLocomotionSpeaks: true).gait, 0.8 * 0.5, accuracy: 1e-12)
        XCTAssertEqual(g.effectiveWeights(hartSpeaks: true, inertiaLocomotionSpeaks: true).gait, 0.8 * 0.35 * 0.5,
                       accuracy: 1e-12, "each overlap is discounted on its own")
        XCTAssertEqual(try prepared(GaitKit.config(gait: 0.8, budget: 0.3)).effectiveWeights(hartSpeaks: false,
                       inertiaLocomotionSpeaks: false).gait, 0.3, "never above the accelerometer budget")

        var f = try lastFeatures(sim)
        XCTAssertNotNil(f.encoder)
        for q in [0.999, 0.0] {
            f.gaitQuality = q == 0 ? GaitKit.prefiltered(endingAt: f.ts) : GaitKit.window(endingAt: f.ts, p: q)
            let base = ActivityContextModel.score(f, temperature: T)
            let with = ActivityContextModel.score(f, temperature: T, gaitQuality: g)
            let bound = T * 0.8 * 0.35 * log(10) + 1e-12
            for m in 0..<BodyMode.count {
                XCTAssertLessThanOrEqual(abs(with.logL[m] - base.logL[m]), bound, "q \(q), mode \(BodyMode(rawValue: m)!)")
            }
            XCTAssertEqual(with.logL[BodyMode.unknown.rawValue], base.logL[BodyMode.unknown.rawValue])
            XCTAssertEqual(with.channels, base.channels, "ElderNet never counts as an evidence channel")
            let walk = BodyMode.walk.rawValue, seated = BodyMode.seated.rawValue
            if q > 0.5 {
                XCTAssertGreaterThan(with.logL[walk] - base.logL[walk], 0)
                XCTAssertLessThan(with.logL[seated] - base.logL[seated], 0)
            } else {
                XCTAssertLessThan(with.logL[walk] - base.logL[walk], 0)
                XCTAssertGreaterThan(with.logL[seated] - base.logL[seated], 0)
            }
            XCTAssertEqual(with.logL[BodyMode.run.rawValue], base.logL[BodyMode.run.rawValue], "run is neutral")
        }
    }

    func testElderNetCannotOpenTheStairsGate() throws {
        let sim = bareWalk(60)
        var f = try lastFeatures(sim)
        f.gaitQuality = GaitKit.window(endingAt: f.ts, p: 0.999)
        let g = try prepared(GaitKit.config(gait: 0.8, budget: 0.8))
        let base = ActivityContextModel.score(f, temperature: T)
        let with = ActivityContextModel.score(f, temperature: T, gaitQuality: g)
        let stairs = BodyMode.stairs.rawValue, walk = BodyMode.walk.rawValue
        // The gait term reaches stairs exactly as it reaches walk; the gate's 0.04 stays.
        XCTAssertEqual(with.logL[stairs] - base.logL[stairs], with.logL[walk] - base.logL[walk], accuracy: 1e-12)
        XCTAssertFalse(with.specialistOpenedByMotionHeads)
        XCTAssertLessThan(with.logL[stairs], with.logL[walk] - T * log(10), "stairs stays behind its gate")
    }

    // MARK: - HART, Inertia and ElderNet share one accelerometer

    /// Per second and per mode, every accelerometer-derived term together — Inertia's locomotion term, its
    /// posture term inside S, any specialist gate Inertia opened, the gait term and the brisk split — stays
    /// within T · max(B_acc, B_Inertia) · ln 10, with HART present or not.
    func testHartGaitAndInertiaStayInsideTheSharedAccelerometerBudget() throws {
        var walk = ActivitySim(start: 1_760_000_000, seed: 12)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking")
        walk.walk(60, opt: o)
        var still = ActivitySim(start: 1_760_000_000, seed: 3)
        var so = ActivitySim.Options()
        so.sleep = .awake
        still.still(60, opt: so)
        let sims = [walk, still, bareWalk(60)]

        let inertiaCases: [(String, [String: Double], [String: Double]?)] = [
            ("stairs", MotionHeadsKit.peaked(L, "stairs", 0.99), nil),
            ("cycling", MotionHeadsKit.peaked(L, "cycling", 0.99), nil),
            ("vehicle + seated", MotionHeadsKit.peaked(L, "vehicle_motion", 0.99), MotionHeadsKit.peaked(P, "seated_likely", 0.99)),
            ("walking", MotionHeadsKit.peaked(L, "walking", 0.99), nil),
            ("stationary + upright", MotionHeadsKit.peaked(L, "stationary", 0.99), MotionHeadsKit.peaked(P, "upright_stationary", 0.99)),
        ]
        let gaitWindows: [(String, (Int) -> GaitQualityWindow)] = [
            ("gait 0.999 brisk", { GaitKit.window(endingAt: $0, p: 0.999, cadence: 140) }),
            ("gait 0.97 easy", { GaitKit.window(endingAt: $0, p: 0.97, cadence: 70) }),
            ("non-gait 0.01", { GaitKit.window(endingAt: $0, p: 0.01) }),
            ("prefiltered", { GaitKit.prefiltered(endingAt: $0) }),
        ]
        // (Inertia locomotion, posture, body budget, gait weight, brisk weight, accelerometer budget)
        let weightings: [(Double, Double, Double, Double, Double, Double)] = [
            (0.25, 0.25, 0.5, 0.25, 0, 0.5), (0.5, 0, 0.5, 0.8, 0.8, 0.5), (0.8, 0.8, 0.5, 0.8, 0.8, 0.5),
            (0.8, 0.8, 0.8, 0.8, 0.8, 0.8), (0.8, 0.8, 0.5, 0.8, 0.8, 0.8), (0.8, 0.8, 0.8, 0.8, 0.8, 0.25),
            (0, 0, 0.5, 0.8, 0.8, 0.5),
        ]
        var checked = 0, limited = 0
        for sim in sims {
            var f = try lastFeatures(sim)
            XCTAssertEqual(f.encoder?.classProbs["stairs"] ?? 0, 0, "no other evidence names a specialist")
            for (label, loco, posture) in inertiaCases {
                for (gaitLabel, make) in gaitWindows {
                    for (wl, wp, bodyBudget, wg, wb, budget) in weightings {
                        let mh = try inertia(locomotion: wl, posture: wp, bodyBudget: bodyBudget)
                        let g = try prepared(GaitKit.config(gait: wg, brisk: wb, inertiaRedundancy: 0, budget: budget))
                        f.motionHeads = MotionHeadsKit.window(endingAt: f.ts, posture: posture, locomotion: loco)
                        f.gaitQuality = make(f.ts)
                        let base = ActivityContextModel.score(f, temperature: T)
                        let with = ActivityContextModel.score(f, temperature: T, motionHeads: mh, gaitQuality: g)
                        let bound = T * max(budget, bodyBudget) * log(10) + 1e-12
                        for m in 0..<BodyMode.count {
                            let pull = abs(with.logL[m] - base.logL[m]) + abs(with.postureShift?[m] ?? 0)
                                + abs(with.briskShift?[m] ?? 0)
                            XCTAssertLessThanOrEqual(pull, bound, "\(label) / \(gaitLabel), weights \(wl)/\(wp)/\(bodyBudget)/"
                                                     + "\(wg)/\(wb)/\(budget): mode \(BodyMode(rawValue: m)!)")
                        }
                        XCTAssertEqual(with.logL[BodyMode.unknown.rawValue], base.logL[BodyMode.unknown.rawValue])
                        XCTAssertEqual(with.channels, base.channels)
                        if with.gaitBudgetLimited { limited += 1 }
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 3 * 5 * 4 * 7)
        XCTAssertGreaterThan(limited, 0, "the budget actually binds in some of these cases")
    }

    func testWithoutInertiaTheGaitTermIsBoundedByItsOwnWeightAndTheBudget() throws {
        let sim = bareWalk(60)
        var f = try lastFeatures(sim)
        for (wg, budget) in [(0.25, 0.5), (0.8, 0.5), (0.8, 0.8), (0.5, 0.2)] {
            let g = try prepared(GaitKit.config(gait: wg, brisk: 0.8, budget: budget))
            for q in [0.999, 0.001] {
                f.gaitQuality = GaitKit.window(endingAt: f.ts, p: q, cadence: 140)
                let base = ActivityContextModel.score(f, temperature: T)
                let with = ActivityContextModel.score(f, temperature: T, gaitQuality: g)
                for m in 0..<BodyMode.count {
                    let pull = abs(with.logL[m] - base.logL[m]) + abs(with.briskShift?[m] ?? 0)
                    XCTAssertLessThanOrEqual(pull, T * budget * log(10) + 1e-12)
                    XCTAssertLessThanOrEqual(abs(with.logL[m] - base.logL[m]), T * min(wg, budget) * log(10) + 1e-12)
                }
            }
        }
    }

    func testHartAndElderNetAreDistinctTemperedChannelsNotAnAverage() throws {
        // A walk the strap's pedometer missed, HART (wrongly) sure the wrist is stationary, ElderNet sure of gait.
        var sim = ActivitySim(start: 1_760_000_000, seed: 12)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("stationary", p: 0.9)
        o.steps = false
        sim.walk(240, opt: o)
        let gaitWindow: (Int) -> GaitQualityWindow = { GaitKit.window(endingAt: $0, p: 0.97) }
        let fused = decode(GaitKit.attach(sim.observations, make: gaitWindow), GaitKit.config(gait: 0.5))
        let hartOnly = decode(sim.observations)

        // The forbidden baseline: 0.5·HART + 0.5·ElderNet (gait → walking) in the encoder slot.
        let averaged = sim.observations.map { obs -> ActivityObservation in
            var obs = obs
            guard let enc = obs.encoder else { return obs }
            let q = 0.97
            let eldernet: [String: Double] = ["walking": q, "stationary": 1 - q]
            var mix: [String: Double] = [:]
            for k in Set(enc.classProbs.keys).union(eldernet.keys).sorted() {
                mix[k] = 0.5 * (enc.classProbs[k] ?? 0) + 0.5 * (eldernet[k] ?? 0)
            }
            obs.encoder = MotionEncoderOutput(encoderId: enc.encoderId, encoderVersion: enc.encoderVersion,
                                              startTs: enc.startTs, endTs: enc.endTs, classProbs: mix,
                                              calibrated: enc.calibrated, abstained: enc.abstained)
            return obs
        }
        let average = decode(averaged)
        let from = sim.observations[0].ts + 60
        func head(_ t: ActivityContextTrack) -> [Double] {
            LocomotionClass.allCases.map { c in mean(t.states, from: from) { $0.locomotion[c] } }
        }
        func l1(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } }
        let fh = head(fused), ah = head(average), hh = head(hartOnly)
        // Averaging rewrites HART's vote (weight 0.8) and the decode moves far; as its own discounted, tempered
        // channel ElderNet moves it only as far as its budget allows.
        XCTAssertGreaterThan(l1(fh, ah), 0.2, "fusion is not the naive average: \(fh) vs \(ah)")
        XCTAssertLessThan(l1(fh, hh), l1(ah, hh), "the fused decode stays nearer HART than the average does")
        XCTAssertGreaterThan(l1(fh, hh), 0, "but ElderNet does speak")
    }

    // MARK: - Refusals

    func testWhoMayFeedTheDecoder() {
        let m = GaitKit.model()
        XCTAssertNil(GaitKit.config().gaitQuality!.evidenceRefusal)
        XCTAssertEqual(GaitKit.config(mode: .shadow).gaitQuality!.evidenceRefusal, "shadow_mode")
        XCTAssertEqual(GaitKit.config(mode: .production).gaitQuality!.evidenceRefusal, "production_needs_pins")
        XCTAssertNil(GaitKit.config(mode: .production, pinVersion: m.modelVersion, pinDigest: m.weightsDigest)
            .gaitQuality!.evidenceRefusal)
        XCTAssertEqual(GaitKit.config(pinVersion: "eldernet-other").gaitQuality!.evidenceRefusal, "model_version_mismatch")
        XCTAssertEqual(GaitKit.config(pinDigest: String(repeating: "0", count: 64)).gaitQuality!.evidenceRefusal,
                       "weights_digest_mismatch")
        XCTAssertEqual(GaitKit.config(gait: 0.9).gaitQuality!.evidenceRefusal?.hasPrefix("invalid_config"), true)
        XCTAssertNil(GaitKit.config(mode: .shadow).gaitQuality!.provenanceStamp)
        let d = GaitQualityEvidenceConfig.candidate(model: m, gaitPrior: 0.2)
        XCTAssertEqual([d.gaitWeight, d.briskWeight, d.hartRedundancy, d.inertiaRedundancy, d.accelerometerBudget,
                        d.briskCadenceSpm, d.briskSpeedMps], [0.25, 0, 0.65, 0.65, 0.5, 100, 1.34])
        XCTAssertEqual(d.briskRule, .cadence)
    }

    func testConfigBoundsAreValidated() throws {
        let m = GaitKit.model()
        typealias V = GaitQualityEvidenceConfig.ValidationError
        func check(_ c: GaitQualityEvidenceConfig, _ expected: V, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try c.validate(), file: file, line: line) { XCTAssertEqual($0 as? V, expected, file: file, line: line) }
            XCTAssertNotNil(c.evidenceRefusal, file: file, line: line)
            var dc = ActivityDecoderConfig()
            dc.gaitQuality = c
            XCTAssertEqual(dc.cacheTag, ActivityDecoderConfig().cacheTag, file: file, line: line)
            XCTAssertNil(ActivityContextDecoder(config: dc).gaitQualityStamp, file: file, line: line)
            XCTAssertNotNil(ActivityContextDecoder(config: dc).gaitQualityRefusal, file: file, line: line)
        }
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, gaitWeight: 0.81), .aboveCeiling("gaitWeight"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, briskWeight: -0.1), .negative("briskWeight"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, gaitWeight: .nan), .nonFinite("gaitWeight"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, accelerometerBudget: 0.9),
              .aboveCeiling("accelerometerBudget"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0), .outOfRange("gaitPrior"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 1), .outOfRange("gaitPrior"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: .infinity), .nonFinite("gaitPrior"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, hartRedundancy: 1.2),
              .outOfRange("hartRedundancy"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, inertiaRedundancy: -0.1),
              .outOfRange("inertiaRedundancy"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, briskCadenceSpm: 200),
              .outOfRange("briskCadenceSpm"))
        check(GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.2, briskSpeedMps: 0.1),
              .outOfRange("briskSpeedMps"))
        XCTAssertNoThrow(try GaitQualityEvidenceConfig.candidate(model: m, gaitPrior: 0.2).validate())
    }

    func testARefusedConfigOrAnotherModelDecodesExactlyLikeElderNetOff() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 5)
        sim.desk(60); sim.walk(120); sim.still(60)
        let input = sim.trackInput()
        let windows = stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map { GaitKit.window(endingAt: $0, p: 0.95) }
        let off = ActivityContextTrackBuilder.build(input)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var withWindows = input
        withWindows.gaitQuality = GaitQualityTrackInput(model: GaitKit.model(), windows: windows)
        var foreign = input
        foreign.gaitQuality = GaitQualityTrackInput(model: GaitKit.model(seed: "z"), windows: windows)
        let cases: [(String, ActivityContextTrackInput, ActivityDecoderConfig, String)] = [
            ("shadow mode", withWindows, GaitKit.config(mode: .shadow), "shadow_mode"),
            ("pinned to another digest", withWindows, GaitKit.config(pinDigest: String(repeating: "1", count: 64)),
             "weights_digest_mismatch"),
            ("another model's windows", foreign, GaitKit.config(), "model_mismatch"),
            ("no windows", input, GaitKit.config(), "no_gait_quality_input"),
        ]
        for (label, variant, config, refusal) in cases {
            XCTAssertFalse(ActivityContextTrackBuilder.acceptsGaitQuality(for: variant, config: config), label)
            let t = ActivityContextTrackBuilder.build(variant, config: config)
            XCTAssertEqual(t.gaitQuality?.refusal, refusal, label)
            XCTAssertNil(t.gaitQuality?.stamp, label)
            XCTAssertNil(t.snapshot.versions.gaitQuality, label)
            XCTAssertTrue(t.states.allSatisfy { $0.versions.gaitQuality == nil && $0.gait == nil }, label)
            XCTAssertEqual(try e.encode(t.states), try e.encode(off.states), label)
            XCTAssertEqual(try e.encode(t.snapshot), try e.encode(off.snapshot), label)
            XCTAssertEqual(ActivityContextTrackBuilder.cacheTag(for: variant, config: config), ActivityDecoderConfig().cacheTag,
                           label)
            let doc = ActivityContextDayBuilder.update(cached: nil, input: variant, now: input.dayEnd, config: config).document
            XCTAssertNil(doc.versions.gaitQuality, label)
            XCTAssertTrue(doc.runs.allSatisfy { $0.gait == nil }, label)
        }
        // Accepted: the stamp and the suffix, on the track and on the persisted day.
        let config = GaitKit.config()
        XCTAssertTrue(ActivityContextTrackBuilder.acceptsGaitQuality(for: withWindows, config: config))
        let on = ActivityContextTrackBuilder.build(withWindows, config: config)
        let stamp = try XCTUnwrap(config.gaitQuality?.provenanceStamp)
        XCTAssertEqual(on.gaitQuality?.stamp, stamp)
        XCTAssertEqual(on.snapshot.versions.gaitQuality, stamp)
        XCTAssertEqual(ActivityContextTrackBuilder.cacheTag(for: withWindows, config: config), config.cacheTag)
        let doc = ActivityContextDayBuilder.update(cached: nil, input: withWindows, now: input.dayEnd, config: config).document
        XCTAssertEqual(doc.versions.gaitQuality, stamp)
    }

    // MARK: - Provenance, cache tag, restore, determinism

    func testProvenanceAndCacheTagAppearOnlyWhenActive() throws {
        let off = ActivityDecoderConfig.personalized(restingHeartRate: 57, maxHeartRate: 188)
        let on = GaitKit.config(base: off)
        let m = GaitKit.model()
        let stamp = try XCTUnwrap(on.gaitQuality?.provenanceStamp)
        XCTAssertEqual(stamp, "eldernet:\(GaitKit.version):\(m.weights12):\(on.gaitQuality!.configTag)")
        XCTAssertEqual(on.cacheTag, off.cacheTag + "-eg\(m.weights12)\(on.gaitQuality!.configTag)")
        XCTAssertTrue(on.cacheTag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "filename-safe")
        // Everything that changes the decode changes the tag; the digest is beside it.
        XCTAssertNotEqual(GaitKit.config(base: off, gait: 0.2).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(base: off, prior: 0.3).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(base: off, brisk: 0.1).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(GaitKit.model(seed: "b"), base: off).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(GaitKit.model(hopS: 10), base: off).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(GaitKit.model(threshold: 0.6), base: off).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(GaitKit.model(version: "eldernet-x"), base: off).cacheTag, on.cacheTag)
        XCTAssertNotEqual(GaitKit.config(GaitKit.model(calibration: ["gait_prob": .init(method: "temperature", fit: "val",
                                                                                         parameters: ["T": 1.3])]),
                                         base: off).cacheTag, on.cacheTag)
        // With Inertia active too, both suffixes, Inertia's first.
        var both = MotionHeadsKit.config(base: on)
        both.gaitQuality = on.gaitQuality
        XCTAssertEqual(both.cacheTag, off.cacheTag + "-ih\(MotionHeadsKit.bundleSha.prefix(12))\(both.motionHeads!.configTag)"
                       + "-eg\(m.weights12)\(on.gaitQuality!.configTag)")

        let t = decode(bareWalk(60).observations, on)
        XCTAssertEqual(t.snapshot.versions.gaitQuality, stamp)
        XCTAssertTrue(t.states.allSatisfy { $0.versions.gaitQuality == stamp })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t.states.last!)) as? [String: Any])
        XCTAssertEqual((json["versions"] as? [String: Any])?["gait_quality"] as? String, stamp)
    }

    func testRestoreRejectsAGaitProvenanceMismatch() throws {
        let sim = bareWalk(180)
        let obs = GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.95) }
        let on = GaitKit.config()
        let first = decode(Array(obs.prefix(90)), on)
        let snap = try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: JSONEncoder().encode(first.snapshot))
        XCTAssertEqual(ActivityContextDecoder(config: on, restoring: snap).restoreOutcome, .resumed)
        XCTAssertEqual(ActivityContextDecoder(config: ActivityDecoderConfig(), restoring: snap).restoreOutcome,
                       .discarded("gait_quality_mismatch"))
        XCTAssertEqual(ActivityContextDecoder(config: GaitKit.config(gait: 0.3), restoring: snap).restoreOutcome,
                       .discarded("gait_quality_mismatch"))
        let plain = decode(Array(sim.observations.prefix(90))).snapshot
        XCTAssertEqual(ActivityContextDecoder(config: on, restoring: plain).restoreOutcome, .discarded("gait_quality_mismatch"))
        // Resuming with the same config continues exactly — the held window and the walking stretch included.
        let whole = decode(obs, on)
        let resumed = ActivityContextTrackBuilder.decode(Array(obs.dropFirst(90)), config: on, resuming: snap)
        XCTAssertEqual(first.states + resumed.states, whole.states)
        XCTAssertEqual(resumed.snapshot, whole.snapshot)
        XCTAssertNotNil(whole.states.last?.gait)
    }

    func testDecodingTheSameInputTwiceIsIdentical() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 41)
        var o = ActivitySim.Options()
        o.encoder = SimEncoder.coarse("walking")
        sim.desk(120); sim.walk(120, opt: o); sim.run(60); sim.walk(90, brisk: true); sim.still(60)
        var obs = MotionHeadsKit.attach(sim.observations) { ActivityContextGoldenTests.loudWindow($0) }
        obs = GaitKit.attach(obs) { e in GaitKit.window(endingAt: e, p: [0.97, 0.3, 0.88, 0.05][(e / 5) % 4],
                                                        cadence: Double(80 + (e % 50))) }
        var config = GaitKit.config(gait: 0.4, brisk: 0.3)
        config.motionHeads = MotionHeadsKit.config(locomotion: 0.3, posture: 0.2, arm: 0.4).motionHeads
        XCTAssertEqual(try encoded(decode(obs, config)), try encoded(decode(obs, config)))
    }

    // MARK: - Track builder

    func testElderNetNeverCreatesAnObservationSecond() throws {
        var sim = ActivitySim(start: 1_760_000_000, seed: 5)
        sim.desk(30); sim.gap(40); sim.desk(30)
        let input = sim.trackInput()
        let start = input.dayStart
        let windows = [
            GaitKit.window(endingAt: start + 20, p: 0.9),     // attaches at e
            GaitKit.window(endingAt: start + 29, p: 0.1),     // e observed (the last desk second)
            GaitKit.window(endingAt: start + 45, p: 0.9),     // inside the gap: no second in [e, e+2]
            GaitKit.window(endingAt: start + 68, p: 0.9),     // e+2 = 70 is the first second after the gap
            GaitKit.window(endingAt: start + 10_000, p: 0.9), // past the day
        ]
        var withGait = input
        withGait.gaitQuality = GaitQualityTrackInput(model: GaitKit.model(), windows: windows)
        let config = GaitKit.config()
        let plain = ActivityContextTrackBuilder.observations(for: input)
        let prepared = ActivityContextTrackBuilder.observationsWithReports(for: withGait, config: config)
        XCTAssertEqual(prepared.observations.map(\.ts), plain.map(\.ts), "no second is created")
        XCTAssertEqual(prepared.observations.filter { $0.gaitQuality != nil }.map(\.ts), [start + 20, start + 29, start + 70])
        XCTAssertNil(prepared.motionHeads, "no motion-heads entry, no motion-heads report")
        let report = try XCTUnwrap(prepared.gaitQuality)
        XCTAssertEqual(report.attached, 3)
        XCTAssertEqual(report.droppedNoObservation, 1)
        XCTAssertEqual(report.droppedOutOfRange, 1)
        XCTAssertEqual(report.windowsIn, 5)
        XCTAssertEqual(ActivityContextTrackBuilder.gaitAttachmentReport(for: withGait, windows: windows).attached, 3)
        let track = ActivityContextTrackBuilder.build(withGait, config: config)
        XCTAssertEqual(track.observedSeconds, plain.count)
        XCTAssertEqual(track.gaitQuality?.attached, 3)
        XCTAssertEqual(track.gaitQuality?.windowsIngested, 3)
        XCTAssertEqual(track.gaitQuality?.gaitWindows, 2)
        // The motion-heads path is untouched: the old entry point returns the same observations.
        XCTAssertEqual(ActivityContextTrackBuilder.observations(for: withGait, config: config).observations,
                       prepared.observations)
        // No gait config: nothing attached, no report.
        let bare = ActivityContextTrackBuilder.observationsWithReports(for: withGait, config: ActivityDecoderConfig())
        XCTAssertTrue(bare.observations.allSatisfy { $0.gaitQuality == nil })
        XCTAssertNil(bare.gaitQuality)
    }

    func testAWindowAppliesForOneHopFromTheSecondItArrived() throws {
        var window = ActivityFeatureWindow()
        var obs = ActivityObservation(ts: 100, dynAccelG: 0.01, wear: .onWrist)
        obs.gaitQuality = GaitKit.window(endingAt: 100, p: 0.9)
        XCTAssertNotNil(window.push(obs, restingHR: 60, maxHR: 190, gaitQualityHoldS: 5).gaitQuality)
        for ts in 101...104 {
            XCTAssertNotNil(window.push(ActivityObservation(ts: ts, dynAccelG: 0.01, wear: .onWrist),
                                        restingHR: 60, maxHR: 190, gaitQualityHoldS: 5).gaitQuality, "\(ts)")
        }
        XCTAssertNil(window.push(ActivityObservation(ts: 105, dynAccelG: 0.01, wear: .onWrist),
                                 restingHR: 60, maxHR: 190, gaitQualityHoldS: 5).gaitQuality)
        // Off (hold 0): never kept, so the snapshot does not change.
        var off = ActivityFeatureWindow()
        XCTAssertNil(off.push(obs, restingHR: 60, maxHR: 190).gaitQuality)
        XCTAssertNil(off.gaitQuality)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(off), as: UTF8.self).contains("gaitQuality"))
    }

    // MARK: - The reported gait block

    private func walkDay(steps: Bool = false) -> ActivitySim {
        var sim = ActivitySim(start: 1_760_000_000, seed: 21)
        var o = ActivitySim.Options()
        o.steps = steps
        o.sleep = .awake
        sim.still(150, opt: o)
        sim.walk(300, opt: o)
        sim.still(150, opt: o)
        return sim
    }

    private func walkDayWindows(_ sim: ActivitySim, gaitDuringWalk p: Double = 0.95) -> [ActivityObservation] {
        let walkFrom = sim.observations[0].ts + 150, walkTo = walkFrom + 300
        return GaitKit.attach(sim.observations) { e in
            if e - 10 >= walkFrom && e <= walkTo { return GaitKit.window(endingAt: e, p: p) }
            return GaitKit.prefiltered(endingAt: e)
        }
    }

    func testTheGaitBlockAppearsOnlyOnGaitWithTheStretchMetrics() throws {
        let sim = walkDay()
        let config = GaitKit.config()
        let t = decode(walkDayWindows(sim), config)
        let walkFrom = sim.observations[0].ts + 150, walkTo = walkFrom + 300
        let withGait = t.states.filter { $0.gait != nil }
        XCTAssertGreaterThan(withGait.count, 30, "most of the walk carries the block")
        for s in withGait {
            XCTAssertGreaterThanOrEqual(s.ts, walkFrom)
            XCTAssertLessThanOrEqual(s.ts, walkTo + 5)
            let pGait = s.locomotion[.walking] + s.locomotion[.briskWalking] + s.locomotion[.stairs]
            XCTAssertGreaterThan(pGait, 0.4, "the posterior is on the gait modes")
            let g = try XCTUnwrap(s.gait)
            XCTAssertEqual(g.speedMps ?? 0, 1.2, accuracy: 1e-9)
            XCTAssertEqual(g.cadenceSpm ?? 0, 108, accuracy: 1e-9)
            XCTAssertEqual(g.strideM ?? 0, 1.3, accuracy: 1e-9)
            XCTAssertEqual(g.regularity ?? 0, 0.8, accuracy: 1e-9)
            XCTAssertEqual(g.gaitProbability, 0.95, accuracy: 1e-9)
            // 18 steps per 10-s window on a 5-s hop: 9 new steps per window.
            XCTAssertEqual(g.steps ?? 0, Double(g.windows) * 9, accuracy: 1e-9)
            XCTAssertEqual(g.provenance, config.gaitQuality!.provenanceStamp)
            XCTAssertNotNil(g.since)
        }
        // One stretch: the window count grows by one per hop.
        let counts = withGait.map(\.gait!.windows)
        XCTAssertEqual(counts, counts.sorted())
        XCTAssertEqual(Set(withGait.map(\.gait!.since)).count, 1)
        XCTAssertEqual(t.gaitQuality?.gaitBlockStates, withGait.count)
        XCTAssertTrue(t.states.filter { $0.ts < walkFrom || $0.ts > walkTo + 10 }.allSatisfy { $0.gait == nil })

        // The JSON carries the block on those states only.
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let walkingJSON = String(decoding: try e.encode(withGait[0]), as: UTF8.self)
        XCTAssertTrue(walkingJSON.contains("\"gait\":{"))
        XCTAssertTrue(walkingJSON.contains("\"speed_mps\":1.2"))
        XCTAssertFalse(walkingJSON.contains("speed_windows"), "per-metric counts only when they differ")
        let stillJSON = String(decoding: try e.encode(t.states[0]), as: UTF8.self)
        XCTAssertFalse(stillJSON.contains("\"gait\""))

        // ElderNet saying non-gait through the walk: no block, ever. No config: no block either.
        XCTAssertTrue(decode(walkDayWindows(sim, gaitDuringWalk: 0.2), config).states.allSatisfy { $0.gait == nil })
        XCTAssertTrue(decode(walkDayWindows(sim)).states.allSatisfy { $0.gait == nil })
        // Zero weights still report (the block is reporting, not evidence) and leave the posterior alone.
        let zero = decode(walkDayWindows(sim), GaitKit.config(gait: 0, brisk: 0))
        XCTAssertEqual(try GaitKit.statesWithoutGait(zero.states), try GaitKit.statesWithoutGait(decode(sim.observations).states))
    }

    func testTheGaitBlockNeedsThePosteriorOnGait() throws {
        // ElderNet sure of gait while every other channel says the wrist is still: the posterior never reaches
        // the gait modes, so no block is published although every window is gait.
        var sim = ActivitySim(start: 1_760_000_000, seed: 3)
        var o = ActivitySim.Options()
        o.sleep = .awake
        o.encoder = SimEncoder.coarse("stationary", p: 0.95)
        sim.still(300, opt: o)
        let t = decode(GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.99) }, GaitKit.config())
        XCTAssertGreaterThan(t.gaitQuality?.gaitWindows ?? 0, 50)
        XCTAssertTrue(t.states.allSatisfy { $0.gait == nil })
        XCTAssertEqual(t.gaitQuality?.gaitBlockStates, 0)
    }

    // MARK: - Walk vs brisk walk

    func testTheBriskSplitIsLoggedOnlyByDefault() throws {
        let sim = bareWalk(240)
        let config = GaitKit.config()  // brisk weight 0
        let brisk = decode(GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.95, cadence: 130) }, config)
        let easy = decode(GaitKit.attach(sim.observations) { GaitKit.window(endingAt: $0, p: 0.95, cadence: 80) }, config)
        XCTAssertEqual(brisk.snapshot.body, easy.snapshot.body, "at weight 0 the cadence never reaches the posterior")
        XCTAssertGreaterThan(brisk.gaitQuality?.briskFavouredSeconds ?? 0, 200)
        XCTAssertEqual(brisk.gaitQuality?.walkFavouredSeconds, 0)
        XCTAssertGreaterThan(easy.gaitQuality?.walkFavouredSeconds ?? 0, 200)
        XCTAssertEqual(brisk.gaitQuality?.briskAppliedSeconds, 0)
    }

    func testTheBriskSplitMovesMassOnlyBetweenWalkAndBriskWalk() throws {
        let streams: [ActivitySim] = [bareWalk(80, seed: 4), bareWalk(60, seed: 8), {
            var s = ActivitySim(start: 1_760_000_000, seed: 2); s.desk(60); s.walk(30); return s
        }()]
        for (k, sim) in streams.enumerated() {
            for (rule, value) in [(GaitQualityEvidenceConfig.BriskRule.cadence, 135.0), (.cadence, 75), (.speed, 1.8)] {
                var on = ActivityContextDecoder(config: GaitKit.config(gait: 0, brisk: 0.5, rule: rule))
                var zero = ActivityContextDecoder(config: GaitKit.config(gait: 0, brisk: 0, rule: rule))
                let obs = sim.observations
                for o in obs.dropLast() { on.ingest(o); zero.ingest(o) }
                XCTAssertEqual(on.snapshot().body, zero.snapshot().body)
                var last = obs.last!
                last.gaitQuality = GaitKit.window(endingAt: last.ts, p: 0.95, speed: rule == .speed ? value : 1.2,
                                                  cadence: rule == .cadence ? value : 108)
                on.ingest(last); zero.ingest(last)
                let a = MotionHeadsKit.modeMass(on.snapshot()), b = MotionHeadsKit.modeMass(zero.snapshot())
                let walk = BodyMode.walk.rawValue, brisk = BodyMode.briskWalk.rawValue
                XCTAssertEqual(a[walk] + a[brisk], b[walk] + b[brisk], accuracy: 1e-12, "stream \(k): the pair keeps its mass")
                for m in BodyMode.allCases where !PreparedGaitQuality.briskPair.contains(m) {
                    XCTAssertEqual(a[m.rawValue], b[m.rawValue], accuracy: 1e-12, "stream \(k), \(m) moved")
                }
                let favoursBrisk = rule == .cadence ? value > 100 : value > 1.34
                if favoursBrisk {
                    XCTAssertGreaterThan(a[brisk], b[brisk], "stream \(k), \(rule) \(value)")
                } else {
                    XCTAssertLessThan(a[brisk], b[brisk], "stream \(k), \(rule) \(value)")
                }
            }
        }
    }

    // MARK: - Runs, intervals, aggregates

    func testRunsIntervalsAndAggregatesCarryTheGaitOfTheirStates() throws {
        let sim = walkDay(steps: true)
        let config = GaitKit.config()
        let t = decode(walkDayWindows(sim), config)
        let stretches = Dictionary(grouping: t.states.compactMap(\.gait), by: { $0.since ?? -1 })
        let counted = stretches.values.reduce(0) { $0 + ($1.map(\.windows).max() ?? 0) }
        XCTAssertGreaterThan(counted, 0)

        let runs = ActivityContextRuns.coalesce(t.states)
        XCTAssertEqual(runs.compactMap(\.gait).reduce(0) { $0 + $1.windows }, counted,
                       "each window is counted once across runs, however the stretch was cut")
        for r in runs.compactMap(\.gait) {
            XCTAssertEqual(r.speedMps ?? 0, 1.2, accuracy: 1e-9)
            XCTAssertEqual(r.steps ?? 0, Double(r.windows) * 9, accuracy: 1e-6)
        }
        XCTAssertTrue(runs.contains { $0.gait == nil }, "runs without gait windows carry none")

        // A run round-trips (rounded means), and a run JSON without the block is unchanged.
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        for r in runs {
            let back = try JSONDecoder().decode(ActivityContextRun.self, from: e.encode(r))
            XCTAssertEqual(back.gait?.windows, r.gait?.windows)
            XCTAssertEqual(back.gait?.speedMps ?? -1, r.gait?.speedMps ?? -1, accuracy: 0.005)
            if r.gait == nil { XCTAssertFalse(String(decoding: try e.encode(r), as: UTF8.self).contains("\"gait\"")) }
        }

        let intervals = ActivityContextIntervalBuilder.build(runs: runs)
        let ivWindows = intervals.compactMap(\.gait).reduce(0.0) { $0 + Double($1.windows) }
        XCTAssertEqual(ivWindows, Double(counted), accuracy: Double(intervals.count))
        // An interval carries the gait its states counted: nearly all of it lands in movement intervals (a state
        // at the edge of the walk may sit in a neighbouring interval while its label catches up).
        let inMovement = intervals.filter { $0.activityClass.isMovement }.compactMap(\.gait).reduce(0) { $0 + $1.windows }
        XCTAssertGreaterThanOrEqual(Double(inMovement), 0.8 * Double(counted))
        XCTAssertTrue(intervals.filter { $0.end <= sim.observations[0].ts + 140 }.allSatisfy { $0.gait == nil },
                      "nothing before the walk")
        let summary = ActivityContextAggregator.summarize(intervals, from: sim.observations[0].ts, to: sim.ts)
        let gaitClasses = summary.classes.filter { $0.gait != nil }
        XCTAssertFalse(gaitClasses.isEmpty)
        for c in gaitClasses { XCTAssertEqual(c.gait!.cadenceSpm ?? 0, 108, accuracy: 1e-6) }
        let walkingClass = try XCTUnwrap(summary.classes.first { $0.activityClass == .walking })
        XCTAssertGreaterThanOrEqual(Double(walkingClass.gait?.windows ?? 0), 0.8 * Double(counted))

        // The persisted day document carries it on its runs, and a document from before decodes with none.
        let input = sim.trackInput()
        var withGait = input
        withGait.gaitQuality = GaitQualityTrackInput(
            model: GaitKit.model(), windows: walkDayWindows(sim).compactMap(\.gaitQuality))
        let doc = ActivityContextDayBuilder.update(cached: nil, input: withGait, now: input.dayEnd, config: config).document
        XCTAssertTrue(doc.runs.contains { $0.gait != nil })
        XCTAssertEqual(try JSONDecoder().decode(ActivityContextDayDocument.self, from: e.encode(doc)).runs.map(\.gait?.windows),
                       doc.runs.map(\.gait?.windows))
    }

    func testTheSummaryCombinesExactlyAndKeepsPerMetricCountsWhenTheyDiffer() throws {
        var a = GaitTotals(since: 100, provenance: "eldernet:x:y:z")
        a.add(GaitKit.window(endingAt: 110, p: 0.9, speed: 1.0, cadence: nil), stepShare: 0.5)
        a.add(GaitKit.window(endingAt: 115, p: 0.8, speed: 1.4, cadence: 120), stepShare: 0.5)
        let s = a.summary
        XCTAssertEqual(s.windows, 2)
        XCTAssertEqual(s.speedMps ?? 0, 1.2, accuracy: 1e-12)
        XCTAssertEqual(s.cadenceSpm, 120)
        XCTAssertEqual(s.cadenceWindows, 1)
        XCTAssertEqual(s.steps ?? 0, 18, accuracy: 1e-12)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertTrue(json.contains("\"cadence_windows\":1"))
        XCTAssertFalse(json.contains("speed_windows"))
        let back = try JSONDecoder().decode(ActivityGaitSummary.self, from: Data(json.utf8))
        XCTAssertEqual(back.cadenceWindows, 1)
        XCTAssertEqual(back.speedWindows, 2)
        let both = s.combined(with: s)
        XCTAssertEqual(both.windows, 4)
        XCTAssertEqual(both.cadenceWindows, 2)
        XCTAssertEqual(both.speedMps ?? 0, 1.2, accuracy: 1e-12)
        XCTAssertEqual(both.steps ?? 0, 36, accuracy: 1e-9)
        XCTAssertEqual(GaitTotals(summary: s).summary, s)
    }

    // MARK: - Codable

    func testConfigAndReportRoundTripAndAnUnpinnedConfigEncodesNoPin() throws {
        let m = GaitKit.model(calibration: ["gait_prob": .init(method: "temperature", fit: "val", parameters: ["T": 1.1])])
        let pinned = GaitQualityEvidenceConfig(mode: .candidate, model: m, gaitPrior: 0.22, gaitWeight: 0.3, briskWeight: 0.1,
                                               briskRule: .speed, expectedModelVersion: m.modelVersion,
                                               expectedWeightsDigest: m.weightsDigest)
        XCTAssertEqual(try JSONDecoder().decode(GaitQualityEvidenceConfig.self, from: JSONEncoder().encode(pinned)), pinned)
        let unpinned = String(decoding: try JSONEncoder().encode(GaitQualityEvidenceConfig.candidate(model: m, gaitPrior: 0.2)),
                              as: UTF8.self)
        XCTAssertFalse(unpinned.contains("expectedWeightsDigest"))
        var dc = ActivityDecoderConfig()
        dc.gaitQuality = pinned
        XCTAssertEqual(try JSONDecoder().decode(ActivityDecoderConfig.self, from: JSONEncoder().encode(dc)), dc)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ActivityDecoderConfig()), as: UTF8.self).contains("gaitQuality"))

        let t = decode(walkDayWindows(walkDay()), GaitKit.config())
        let report = try XCTUnwrap(t.gaitQuality)
        XCTAssertEqual(try JSONDecoder().decode(GaitQualityTrackReport.self, from: JSONEncoder().encode(report)), report)
        // A model refused in a stored config is refused on decode too.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pinned)) as! [String: Any]
        var model = obj["model"] as! [String: Any]
        model["window_s"] = 30
        obj["model"] = model
        XCTAssertThrowsError(try JSONDecoder().decode(GaitQualityEvidenceConfig.self,
                                                      from: JSONSerialization.data(withJSONObject: obj)))
    }

    func testOldDocumentsWithoutTheNewFieldsStillDecode() throws {
        let versions = try JSONDecoder().decode(ActivityStateVersions.self, from: Data(
            #"{"schema":2,"ontology":"o","decoder":"d","feature_schema":"f","motion_heads":"inertia-1:x:y"}"#.utf8))
        XCTAssertNil(versions.gaitQuality)
        XCTAssertEqual(versions.motionHeads, "inertia-1:x:y")
        let root = ActivityContextGoldenTests.fixtureRoot()
        for name in ["stored_streams_day"] {
            let doc = try JSONDecoder().decode(ActivityContextDayDocument.self,
                                               from: Data(contentsOf: root.appendingPathComponent("\(name)/document.json")))
            XCTAssertTrue(doc.runs.allSatisfy { $0.gait == nil })
            XCTAssertNil(doc.latest?.gait)
            XCTAssertNil(doc.versions.gaitQuality)
        }
        for name in ["mixed_observations", "specialists", "resumed_half", "stored_streams_day"] {
            let snap = try JSONDecoder().decode(ActivityDecoderSnapshot.self,
                                                from: Data(contentsOf: root.appendingPathComponent("\(name)/snapshot.json")))
            XCTAssertNil(snap.versions.gaitQuality)
            XCTAssertNil(snap.window.gaitQuality)
            XCTAssertNil(snap.tracking.gaitStretch)
            XCTAssertEqual(ActivityContextDecoder(config: ActivityDecoderConfig(), restoring: snap).restoreOutcome, .resumed)
        }
        let interval = try JSONDecoder().decode(ActivityContextInterval.self, from: JSONEncoder().encode(
            ActivityContextInterval(start: 0, end: 60, activityClass: .walking, confidence: 0.9)))
        XCTAssertNil(interval.gait)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(interval), as: UTF8.self).contains("gait"))
    }
}
