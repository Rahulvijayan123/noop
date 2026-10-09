import XCTest
@testable import StrandAnalytics

final class ActivityPersonalProfileTests: XCTestCase {

    // MARK: Synthetic wearer

    /// A wearer whose standing is busy (weight shifts, hands moving: ~60 mg) with a raised heart rate, where
    /// the population profile expects a quiet stand. To the defaults that reads as desk-like sitting.
    struct Wearer {
        var standDyn = 0.06
        var standHR = 92
        var sitHR = 62
        /// When true, standing looks exactly like sitting: the labels name a difference the sensors cannot see.
        var standLooksLikeSitting = false
        var labelSeconds = 90
    }

    static func run(_ w: Wearer, session: String, seed: UInt64, start: Int) -> ActivityCalibrationRun {
        var sim = ActivitySim(start: start, seed: seed)
        var labels: [ActivityGroundTruthLabel] = []
        var sit = ActivitySim.Options(); sit.hr = w.sitHR
        var stand = ActivitySim.Options(); stand.hr = w.standLooksLikeSitting ? w.sitHR : w.standHR

        func label(_ from: Int, _ to: Int, posture: PostureClass? = nil, locomotion: LocomotionClass? = nil,
                   transition: ActivityGroundTruthTransitionKind? = nil, at ts: Int? = nil) {
            labels.append(ActivityGroundTruthLabel(
                labelKey: "guided:\(session):\(from)", source: .guided, sessionId: session,
                protocolVersion: "calibration-v2", startTs: from, endTs: to,
                posture: posture?.rawValue, locomotion: locomotion?.rawValue,
                transitionKind: transition?.rawValue, transitionTs: ts))
        }
        func shift(_ degrees: Double, _ opt: ActivitySim.Options) {
            if w.standLooksLikeSitting { sim.still(3, opt: sit) } else { sim.postureShift(netDegrees: degrees, opt: opt) }
        }
        func standing(_ seconds: Int) {
            if w.standLooksLikeSitting { sim.still(seconds, opt: stand); return }
            for _ in 0..<seconds {
                sim.emit(dyn: w.standDyn + sim.noise(0.02), ticks: 0, cls: 0, rotate: sim.noise(0.5),
                         jitter: sim.noise(4), opt: stand)
            }
        }

        sim.still(300, opt: sit)                                   // unlabelled lead-in, seated
        var a = sim.ts; sim.still(w.labelSeconds, opt: sit); label(a, sim.ts, posture: .seatedLikely)
        a = sim.ts; shift(40, stand)
        label(a - 3, sim.ts + 4, transition: .sitToStand, at: a + 1)
        a = sim.ts; standing(w.labelSeconds); label(a, sim.ts, posture: .uprightStationary)
        a = sim.ts; shift(-40, sit)
        label(a - 3, sim.ts + 4, transition: .standToSit, at: a + 1)
        a = sim.ts; sim.still(w.labelSeconds, opt: sit); label(a, sim.ts, posture: .seatedLikely)
        shift(40, stand)
        a = sim.ts; standing(w.labelSeconds); label(a, sim.ts, posture: .uprightStationary)
        a = sim.ts; sim.walk(w.labelSeconds, opt: stand); label(a, sim.ts, locomotion: .walking)
        return ActivityCalibrationRun(sessionId: session, observations: sim.observations, labels: labels)
    }

    static func runs(_ w: Wearer, count: Int) -> [ActivityCalibrationRun] {
        (0..<count).map { i in
            run(w, session: "session-\(i)", seed: UInt64(11 + 7 * i), start: 1_760_000_000 + i * 86_400)
        }
    }

    // MARK: Fit and adoption

    /// Two runs are enough to validate (leave-one-out over two runs). This protocol labels no lying, so its
    /// stationary adaptations are refused (personal-profile-3, `validatesEveryStationaryPosture`); the decision is
    /// a validated refusal, not a request for more runs.
    func testTwoRunsAreEnoughToValidate() {
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(Wearer(), count: 2), config: ActivityDecoderConfig(),
                                                       now: 0)
        XCTAssertNotEqual(result.status, .needsMoreRuns)
        XCTAssertEqual(result.validation?.runs, 2)
    }

    /// Each activity alone holds every posture it covers long enough that the leave-one-out folds of
    /// `runsToPersonalise` runs clear the per-mode minimum, so skipping the other activity never strands one.
    func testEachActivityClearsTheMinimumForItsPosturesAcrossTheFold() {
        let foldRuns = ActivityCalibrationProtocols.runsToPersonalise - 1
        let fitter = ActivityPersonalProfileFitter.self
        let main: [String: [String]] = [
            "sit-stand": [PostureClass.seatedLikely.rawValue, PostureClass.uprightStationary.rawValue],
            "lie-down": [PostureClass.recumbent.rawValue],
        ]
        for activity in ActivityCalibrationProtocols.current.activities {
            var seconds: [String: Int] = [:]
            for task in activity.tasks {
                guard let posture = task.posture else { continue }
                seconds[posture, default: 0] += task.durationSeconds - 2 * task.guardSeconds
                    - fitter.settleSeconds - fitter.endGuardSeconds
            }
            for posture in main[activity.id] ?? [] {
                XCTAssertGreaterThanOrEqual((seconds[posture] ?? 0) * foldRuns, fitter.minModeSeconds,
                                            "\(activity.id): \(posture)")
            }
        }
    }

    func testShortRunsAskForTheRunsTheirDataNeeds() {
        var w = Wearer()
        w.labelSeconds = 25
        let run = Self.run(w, session: "s", seed: 3, start: 1_760_000_000)
        let seated = ActivityPersonalProfileFitter.truthBySecond(run.labels).values.filter { $0 == .seated }.count
        XCTAssertTrue((30..<60).contains(seated), "one run's best-covered mode: \(seated) s")
        let result = ActivityPersonalProfileFitter.fit(runs: [run], config: ActivityDecoderConfig(), now: 0)
        XCTAssertEqual(result.outcome, .needsMoreRuns(have: 1, need: 3),
                       "under 60 s of any mode per run: a fold needs two runs, so three in all")
    }

    /// Enough runs on average, but leaving out the one long run leaves no mode at the minimum: that is
    /// missing data, reported as such, not a profile that was tried and refused.
    func testFoldsWithoutEnoughOfAnyModeAreMissingDataNotARefusal() {
        let long = Self.run(Wearer(), session: "session-0", seed: 11, start: 1_760_000_000)
        var w = Wearer()
        w.labelSeconds = 25
        let short = (1...2).map { i -> ActivityCalibrationRun in
            var run = Self.run(w, session: "session-\(i)", seed: UInt64(11 + 7 * i), start: 1_760_000_000 + i * 86_400)
            run.labels = run.labels.filter { $0.locomotion != nil }
            return run
        }
        let result = ActivityPersonalProfileFitter.fit(runs: [long] + short, config: ActivityDecoderConfig(), now: 0)
        XCTAssertEqual(result.status, .needsMoreRuns)
        XCTAssertEqual(result.runs, 3)
        XCTAssertEqual(result.runsNeeded, 4)
        XCTAssertNil(result.profile)
    }

    /// The wearer's own profile fixes their busy standing on held-out runs, and passes every per-class guard on
    /// the classes it saw. It is still refused: the protocol labels no lying, and narrowing a stationary mode moves
    /// where lying seconds land without any guard able to see it (personal-profile-3; on the calibration simulator
    /// such a profile doubled the unseen day's wrong claims, the lie-down read as sitting).
    func testAPersonalProfileFixesTheWearersStandingOnHeldOutRunsButNeedsLyingValidatedToBeAdopted() throws {
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(Wearer(), count: 3),
                                                       config: ActivityDecoderConfig(), now: 1_770_000_000)
        let v = try XCTUnwrap(result.validation)
        let upright = try XCTUnwrap(v.classes["upright"])
        XCTAssertGreaterThanOrEqual(v.gain, 0.03)
        XCTAssertGreaterThan(upright.personalRecall, upright.baselineRecall + 0.2,
                             "the defaults read busy standing as sitting; the wearer's own profile should not")
        XCTAssertLessThanOrEqual(v.worstRecallDrop, 0.05)
        XCTAssertTrue(ActivityPersonalProfileFitter.guardsHold(v), "validation: \(v)")
        XCTAssertNil(v.classes["bedRest"], "no lying labelled")
        XCTAssertFalse(ActivityPersonalProfileFitter.validatesEveryStationaryPosture(v, adapting: ["upright"]))
        XCTAssertEqual(result.status, .notBetter, "validation: \(v)")
        XCTAssertNil(result.profile)
    }

    func testAProfileChangesWhatTheDecoderSays() throws {
        // The adaptation itself (as the fitter would build it from these runs), applied directly: the decoder reads
        // the wearer's busy stand as standing. Adoption is the fitter's separate decision (above).
        let runs = Self.runs(Wearer(), count: 3)
        let samples = runs.flatMap { ActivityPersonalProfileFitter.replay($0, config: ActivityDecoderConfig()).samples }
        let modes = ActivityPersonalProfileFitter.fitModes(samples)
        XCTAssertNotNil(modes["upright"])
        let profile = ActivityPersonalProfile(fittedAt: 0, sessionIds: runs.map(\.sessionId), modes: modes)
        var personal = ActivityDecoderConfig()
        personal.personalProfile = profile
        let fresh = Self.run(Wearer(), session: "fresh", seed: 99, start: 1_761_000_000)
        let before = ActivityPersonalProfileFitter.replay(fresh, config: ActivityDecoderConfig())
        let after = ActivityPersonalProfileFitter.replay(fresh, config: personal)
        func uprightRecall(_ r: ActivityPersonalProfileFitter.Replay) -> Double {
            let upright = r.samples.filter { $0.truth == .upright }
            return Double(upright.filter { $0.predicted == .upright }.count) / Double(max(1, upright.count))
        }
        XCTAssertGreaterThan(uprightRecall(after), uprightRecall(before) + 0.2)
    }

    func testAProfileThatCannotHelpIsRefused() throws {
        var w = Wearer()
        w.standLooksLikeSitting = true
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(w, count: 3), config: ActivityDecoderConfig(),
                                                       now: 0)
        XCTAssertEqual(result.status, .notBetter)
        XCTAssertNil(result.profile)
        let v = try XCTUnwrap(result.validation)
        XCTAssertLessThan(v.gain, 0.03)
        if case .notBetter(let baseline, let personal) = result.outcome {
            XCTAssertEqual(baseline, v.baselineBalancedAccuracy)
            XCTAssertEqual(personal, v.personalBalancedAccuracy)
        } else {
            XCTFail("outcome")
        }
    }

    func testOneRunIsNotEnough() {
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(Wearer(), count: 1), config: ActivityDecoderConfig(),
                                                       now: 0)
        XCTAssertEqual(result.outcome, .needsMoreRuns(have: 1, need: 2))
        XCTAssertNil(result.validation)
        XCTAssertNil(result.profile)
    }

    func testRunsWithoutStaticLabelsDoNotCount() {
        var runs = Self.runs(Wearer(), count: 2)
        runs[1].labels = runs[1].labels.filter { $0.transitionKind != nil }
        let result = ActivityPersonalProfileFitter.fit(runs: runs, config: ActivityDecoderConfig(), now: 0)
        XCTAssertEqual(result.outcome, .needsMoreRuns(have: 1, need: 2))
    }

    // MARK: Shrinkage and clamps

    func testTwentyLabelledSecondsNeverMoveAProfile() {
        var w = Wearer()
        w.labelSeconds = 30
        let replay = ActivityPersonalProfileFitter.replay(Self.run(w, session: "s", seed: 3, start: 1_760_000_000),
                                                          config: ActivityDecoderConfig())
        let upright = replay.samples.filter { $0.truth == .upright }
        XCTAssertGreaterThanOrEqual(upright.count, 20)
        XCTAssertLessThan(upright.count, ActivityPersonalProfileFitter.minModeSeconds)
        XCTAssertTrue(ActivityPersonalProfileFitter.fitModes(Array(upright.prefix(20))).isEmpty)
        XCTAssertNil(ActivityPersonalProfileFitter.fitModes(replay.samples)["upright"],
                     "two short standing bouts are still under the 60-second minimum")
    }

    func testShrinkageScalesWithLabelledSecondsAndShiftsAreClamped() throws {
        let prior = 0.0...0.5
        let far = [Double](repeating: 0.95, count: 400)
        let r = try XCTUnwrap(ActivityPersonalProfileFitter.shrinkRange(prior, toward: far, w: 0.9, bounds: 0...1,
                                                                       minWidth: 0.06))
        XCTAssertEqual(r.lo, 0.25, accuracy: 1e-9, "no end moves more than half the default width")
        XCTAssertEqual(r.hi, 0.75, accuracy: 1e-9)

        let narrow = [Double](repeating: 0.2, count: 400)
        let n = try XCTUnwrap(ActivityPersonalProfileFitter.shrinkRange(prior, toward: narrow, w: 1, bounds: 0...1,
                                                                       minWidth: 0.06))
        XCTAssertGreaterThanOrEqual(n.hi - n.lo, 0.06 - 1e-9, "never narrower than the minimum width")

        let small = ActivityPersonalProfileFitter.shrinkRange(prior, toward: far, w: 60.0 / 180.0, bounds: 0...1,
                                                              minWidth: 0.06)
        let large = ActivityPersonalProfileFitter.shrinkRange(prior, toward: far, w: 600.0 / 720.0, bounds: 0...1,
                                                              minWidth: 0.06)
        XCTAssertLessThan(try XCTUnwrap(small).hi, try XCTUnwrap(large).hi, "more seconds, more weight on the wearer")
    }

    func testHeartRateShiftIsClamped() throws {
        // 400 labelled seconds at hrRel 0.9: a walking level shifts by at most 0.15.
        var f = heldFeatures(ux: 0.5, sign: nil)
        f.hrRel = 0.9
        let walk = try XCTUnwrap(ActivityPersonalProfileFitter.fitMode(.walk, Array(repeating: f, count: 400)))
        let hr = try XCTUnwrap(walk.hrRel)
        XCTAssertEqual(hr, ActivityContextModel.profiles[BodyMode.walk.rawValue].hrRel + 0.15, accuracy: 1e-4)
    }

    func testNoStationaryPostureAdaptsAHeartRateLevel() throws {
        // D9-02: a standing rate 118 bpm above the sitting one (the old fitter moved upright's level by +0.15)
        // adapts no stationary heart-rate level; heart rate is not posture evidence.
        let replay = ActivityPersonalProfileFitter.replay(
            Self.run({ var w = Wearer(); w.standHR = 180; w.labelSeconds = 400; return w }(),
                     session: "s", seed: 5, start: 1_760_000_000),
            config: ActivityDecoderConfig())
        let modes = ActivityPersonalProfileFitter.fitModes(replay.samples)
        let upright = try XCTUnwrap(modes["upright"])
        XCTAssertNil(upright.hrRel)
        XCTAssertNil(modes["seated"]?.hrRel)
        var f = heldFeatures(ux: 0.5, sign: nil)
        f.hrRel = 0.9
        for mode in [BodyMode.bedRest, .seated, .upright] {
            XCTAssertNil(ActivityPersonalProfileFitter.fitMode(mode, Array(repeating: f, count: 400))?.hrRel, "\(mode)")
        }
    }

    // MARK: Decoder plumbing

    func testNoProfileDecodesExactlyAsBefore() {
        let run = Self.run(Wearer(), session: "s", seed: 8, start: 1_760_000_000)
        var empty = ActivityDecoderConfig()
        empty.personalProfile = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [:])
        let plain = ActivityContextTrackBuilder.decode(run.observations, config: ActivityDecoderConfig())
        let withEmpty = ActivityContextTrackBuilder.decode(run.observations, config: empty)
        XCTAssertEqual(plain.states, withEmpty.states)
        XCTAssertEqual(empty.cacheTag, ActivityDecoderConfig().cacheTag)
        XCTAssertEqual(ActivityContextModel.profiles(for: nil).map(\.move), ActivityContextModel.profiles.map(\.move))
    }

    func testAProfileChangesTheCacheTagAndIsCodable() throws {
        let adjustment = ActivityPersonalModeAdjustment(seconds: 120, move: ActivityPersonalRange(lo: 0.2, hi: 0.5),
                                                        hrRel: 0.2)
        let profile = ActivityPersonalProfile(fittedAt: 1, sessionIds: ["b", "a"], modes: ["upright": adjustment])
        XCTAssertEqual(profile.sessionIds, ["a", "b"])
        XCTAssertEqual(profile.version, "personal-profile-3", "bumped with the per-class wrong-claim guard: an older profile is refit")
        var config = ActivityDecoderConfig()
        config.personalProfile = profile
        XCTAssertEqual(config.cacheTag, ActivityDecoderConfig().cacheTag + "-pp\(profile.tag)")
        XCTAssertEqual(profile.tag.count, 8)

        var other = adjustment
        other.hrRel = 0.21
        XCTAssertNotEqual(ActivityPersonalProfile(fittedAt: 1, sessionIds: [], modes: ["upright": other]).tag, profile.tag)
        XCTAssertEqual(ActivityPersonalProfile(fittedAt: 99, sessionIds: ["z"], modes: ["upright": adjustment]).tag,
                       profile.tag, "the tag names the adjustments, not when or from what they were fit")

        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ActivityDecoderConfig.self, from: data), config)

        let table = ActivityContextModel.profiles(for: profile)
        let upright = table[BodyMode.upright.rawValue]
        XCTAssertEqual(upright.move, 0.2...0.5)
        // A stored per-posture heart-rate level (an older fitter's) is kept in the profile but never applied (D9-02).
        XCTAssertEqual(profile.modes["upright"]?.hrRel, 0.2)
        XCTAssertEqual(upright.hrRel, ActivityContextModel.stationaryHrRel)
        XCTAssertEqual(upright.orientPath, ActivityContextModel.profiles[BodyMode.upright.rawValue].orientPath)
        XCTAssertEqual(table[BodyMode.seated.rawValue].move, ActivityContextModel.profiles[BodyMode.seated.rawValue].move)
    }

    func testOnlyGuidedConfidentStaticLabelsAreTruth() {
        func label(_ source: ActivityGroundTruthSource, unsure: Bool = false, transition: String? = nil) -> ActivityGroundTruthLabel {
            var l = ActivityGroundTruthLabel(labelKey: "k", source: source, startTs: 0, endTs: 10,
                                             posture: PostureClass.seatedLikely.rawValue, transitionKind: transition)
            l.userUnsure = unsure
            return l
        }
        XCTAssertEqual(ActivityPersonalProfileFitter.staticMode(of: label(.guided)), .seated)
        XCTAssertNil(ActivityPersonalProfileFitter.staticMode(of: label(.stretchFeedback)))
        XCTAssertNil(ActivityPersonalProfileFitter.staticMode(of: label(.guided, unsure: true)))
        XCTAssertNil(ActivityPersonalProfileFitter.staticMode(of: label(.guided, transition: "sit_to_stand")))
        let truth = ActivityPersonalProfileFitter.truthBySecond([label(.guided)])
        XCTAssertEqual(truth.keys.sorted(), Array(3..<9), "settle and guard edges are dropped")
    }

    // MARK: Personal held-forearm orientation (channel 3c) and what validation scores

    private func heldFeatures(ux: Double, sign: Double?) -> ActivityFeatures {
        var f = ActivityFeatures(ts: 0, m4: 0.05, m10: 0.05, m30: 0.05, mMed30: 0.05, mBurst10: 0.06, cv30: 0.5,
                                 gaitPresence: 0, cadenceSpm: nil, runShare6: nil, rhythm: nil, orientPath10: 0.2,
                                 net5: 1, net30: 1, shiftNet: nil, hr: nil, hrRel: nil, hrSlope: nil,
                                 wear: .onWrist, sleep: .awake, loggedWorkout: false, workoutKind: .other,
                                 encoder: nil, encoderAgeS: 0,
                                 evidence: ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: true,
                                                                   gravity: true, steps: true, heartRate: false,
                                                                   sleep: true, coverage: 1),
                                 windowFill: 10)
        f.heldUx = ux
        f.forearmSign = sign
        return f
    }

    func testOrientationSharesAreFitPerFrameAndShrunkTowardThePopulation() throws {
        let fitter = ActivityPersonalProfileFitter.self
        let flatSigned = [ActivityFeatures](repeating: heldFeatures(ux: 0.0, sign: 1), count: 300)
        let shares = try XCTUnwrap(fitter.orientationShares(.bedRest, flatSigned, signed: true))
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-3)
        // w = 300 / 420: about 0.29 · 0.42 + 0.71 · 1 of the mass is flat.
        XCTAssertGreaterThan(shares[1], ActivityContextModel.orientationRows.bed[1] + 0.3)
        XCTAssertTrue(shares.allSatisfy { $0 >= 0.005 }, "no category becomes impossible: \(shares)")
        XCTAssertNil(fitter.orientationShares(.bedRest, flatSigned, signed: false), "no uncalibrated seconds")
        XCTAssertNil(fitter.orientationShares(.walk, flatSigned, signed: true), "stationary modes only")
        XCTAssertNil(fitter.orientationShares(.bedRest, Array(flatSigned.prefix(59)), signed: true))

        let flatUnsigned = [ActivityFeatures](repeating: heldFeatures(ux: 0.0, sign: nil), count: 300)
        let unsigned = try XCTUnwrap(fitter.orientationShares(.bedRest, flatUnsigned, signed: false))
        XCTAssertEqual(unsigned[0], 0, "|x| cannot see a raised hand")

        // fitMode carries them on stationary modes, never on walking ones.
        XCTAssertNotNil(fitter.fitMode(.bedRest, flatSigned)?.orientation)
        XCTAssertNil(fitter.fitMode(.walk, flatSigned)?.orientation)
    }

    func testAWearersOwnOrientationRowsReplaceThePopulationRowsOnlyWhenFitted() throws {
        // This wearer lies with the forearm flat (owner's production data: 69 % flat in bed) and sits with it
        // inclined (3 % flat by day).
        let profile = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [
            "bedRest": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.09, 0.69, 0.17, 0.05]),
            "seated": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.006, 0.03, 0.70, 0.264]),
        ])
        let table = ActivityContextModel.profiles(for: profile)
        XCTAssertEqual(try XCTUnwrap(table[BodyMode.bedRest.rawValue].orientation)[1], 0.69, accuracy: 1e-9)
        XCTAssertNil(table[BodyMode.upright.rawValue].orientation, "unfitted modes keep the population row")
        XCTAssertNil(table[BodyMode.bedRest.rawValue].orientationUnsigned)
        // Population default: no profile, no rows.
        XCTAssertTrue(ActivityContextModel.profiles(for: nil).allSatisfy { $0.orientation == nil && $0.orientationUnsigned == nil })

        func evidence(_ ux: Double, _ t: [ModeProfile]) -> ActivityContextModel.PostureEvidence {
            ActivityContextModel.score(heldFeatures(ux: ux, sign: 1), temperature: 1, table: t).postureEvidence
        }
        let population = ActivityContextModel.profiles
        // A flat forearm is much stronger recumbent evidence for this wearer than for the population (LR ~23 vs 1.4) ...
        XCTAssertGreaterThan(evidence(0.0, table).recumbentOrientation, evidence(0.0, population).recumbentOrientation + 0.08)
        // ... and an inclined one argues against lying more strongly.
        XCTAssertLessThan(evidence(0.5, table).recumbentOrientation, evidence(0.5, population).recumbentOrientation - 0.03)
        // With the sign uncalibrated, the (unfitted) unsigned rows are the population's: identical evidence.
        XCTAssertEqual(ActivityContextModel.score(heldFeatures(ux: 0.0, sign: nil), temperature: 1, table: table).postureEvidence,
                       ActivityContextModel.score(heldFeatures(ux: 0.0, sign: nil), temperature: 1).postureEvidence)
        // A malformed stored row is ignored.
        let bad = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [
            "bedRest": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.5, 0.5]),
            "seated": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0, 0, 0, 0]),
        ])
        XCTAssertTrue(ActivityContextModel.profiles(for: bad).allSatisfy { $0.orientation == nil })
    }

    func testAnOlderProfileWithoutOrientationDecodesAndKeepsItsTag() throws {
        let json = #"{"seconds":120,"move":{"lo":0.2,"hi":0.5}}"#
        let adj = try JSONDecoder().decode(ActivityPersonalModeAdjustment.self, from: Data(json.utf8))
        XCTAssertNil(adj.orientation)
        XCTAssertNil(adj.orientationUnsigned)
        let encoded = String(decoding: try JSONEncoder().encode(adj), as: UTF8.self)
        XCTAssertFalse(encoded.contains("orientation"), "absent rows are not written, so stored tags do not change")
    }

    func testValidationScoresThePublishedClassNotTheBodyModeArgmax() throws {
        // Quiet sitting with no posture evidence: the decoder publishes "stationary" (posture unresolved), which
        // claims neither posture. The body-mode argmax used to call those seconds standing.
        var sim = ActivitySim(start: 1_760_000_000, seed: 5)
        sim.forearm(0.55)
        sim.still(300)
        let a = sim.ts
        sim.still(300)
        let label = ActivityGroundTruthLabel(labelKey: "guided:s:\(a)", source: .guided, sessionId: "s",
                                             protocolVersion: "calibration-v2", startTs: a, endTs: sim.ts,
                                             posture: PostureClass.seatedLikely.rawValue)
        let run = ActivityCalibrationRun(sessionId: "s", observations: sim.observations, labels: [label])
        let samples = ActivityPersonalProfileFitter.replay(run, config: ActivityDecoderConfig()).samples
        XCTAssertGreaterThan(samples.count, 200)
        XCTAssertEqual(samples.filter { $0.predicted == .upright }.count, 0, "a hedged second is not a standing claim")
        var d = ActivityContextDecoder(config: ActivityDecoderConfig())
        let published = d.run(sim.observations).filter { $0.ts >= a + 3 && $0.ts < sim.ts - 1 }
        XCTAssertTrue(published.allSatisfy { ActivityClassifier.classify(state: $0).activityClass == .stationary })
        XCTAssertTrue(samples.allSatisfy { $0.predicted == .unknown })
        XCTAssertEqual(ActivityPersonalProfileFitter.publishedMode(
            ActivityClassification(activityClass: .stationary, confidence: 0.9)), .unknown)
        XCTAssertEqual(ActivityPersonalProfileFitter.publishedMode(
            ActivityClassification(activityClass: .fidgeting, confidence: 0.6, posture: .uprightStationary)), .upright)
        XCTAssertEqual(ActivityPersonalProfileFitter.publishedMode(
            ActivityClassification(activityClass: .sittingDesk, confidence: 0.6)), .seated)
    }
}
