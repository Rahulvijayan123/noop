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

    func testTwoRunsAreEnoughToAdopt() {
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(Wearer(), count: 2), config: ActivityDecoderConfig(),
                                                       now: 0)
        XCTAssertEqual(result.status, .adopted)
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

    func testAPersonalProfileFixesTheWearersStandingOnHeldOutRuns() throws {
        let result = ActivityPersonalProfileFitter.fit(runs: Self.runs(Wearer(), count: 3),
                                                       config: ActivityDecoderConfig(), now: 1_770_000_000)
        let v = try XCTUnwrap(result.validation)
        let upright = try XCTUnwrap(v.classes["upright"])
        XCTAssertEqual(result.status, .adopted, "validation: \(v)")
        XCTAssertGreaterThanOrEqual(v.gain, 0.03)
        XCTAssertGreaterThan(upright.personalRecall, upright.baselineRecall + 0.2,
                             "the defaults read busy standing as sitting; the wearer's own profile should not")
        XCTAssertLessThanOrEqual(v.worstRecallDrop, 0.05)
        let profile = try XCTUnwrap(result.profile)
        XCTAssertEqual(profile.sessionIds, ["session-0", "session-1", "session-2"])
        XCTAssertNotNil(profile.modes["upright"])
        XCTAssertEqual(profile.validation, v)
        if case .adopted(let p) = result.outcome { XCTAssertEqual(p, profile) } else { XCTFail("outcome") }
    }

    func testTheAdoptedProfileChangesWhatTheDecoderSays() throws {
        let runs = Self.runs(Wearer(), count: 3)
        let profile = try XCTUnwrap(ActivityPersonalProfileFitter.fit(runs: runs, config: ActivityDecoderConfig(),
                                                                      now: 0).profile)
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
        let replay = ActivityPersonalProfileFitter.replay(
            Self.run({ var w = Wearer(); w.standHR = 180; w.labelSeconds = 400; return w }(),
                     session: "s", seed: 5, start: 1_760_000_000),
            config: ActivityDecoderConfig())
        let upright = try XCTUnwrap(ActivityPersonalProfileFitter.fitModes(replay.samples)["upright"])
        let hr = try XCTUnwrap(upright.hrRel)
        XCTAssertEqual(hr, ActivityContextModel.profiles[BodyMode.upright.rawValue].hrRel + 0.15, accuracy: 1e-4)
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
        XCTAssertEqual(upright.hrRel, 0.2)
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
}
