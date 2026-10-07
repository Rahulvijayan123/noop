import XCTest
@testable import StrandAnalytics

/// End to end: synthetic wearers do the real guided protocol (`ActivityCalibrationProtocols.current`, its
/// countdowns, cue guards and transition timing exactly as the session runner records labels), the fitter
/// learns from those runs, and the result is judged on a day it never saw. A wearer the population profile
/// fits badly must come out measurably better; a wearer it already fits must never come out worse.
final class ActivityPersonalCalibrationEndToEndTests: XCTestCase {

    // MARK: Wearers

    struct Wearer {
        var name: String
        var sitHR = 64
        var standHR = 70
        var lieHR = 58
        /// Standing wrist movement (g): ~0.01 is a quiet stand, ~0.06 a busy one.
        var standDyn = 0.012
        var walkDyn = 0.135
        var briskDyn = 0.22
        var walkHR = 100
        var briskHR = 122
    }

    /// Fits the default profile: quiet stand, typical heart rates and pace.
    static let typical = Wearer(name: "typical")
    /// Stands busy (weight shifts, talking with the hands) with a raised heart rate: the defaults call it sitting.
    static let busyStander = Wearer(name: "busy stander", standHR: 94, standDyn: 0.06)
    /// Same busy stand, but a fit, low-pulse wearer: the heart-rate channel cannot help, only motion can.
    static let fitBusyStander = Wearer(name: "fit busy stander", sitHR: 52, standHR: 58, lieHR: 48, standDyn: 0.055,
                                       walkHR: 82, briskHR: 98)

    // MARK: Protocol simulator

    enum State { case seated, desk, fidget, standing, walking, brisk, lying }

    struct Session {
        var observations: [ActivityObservation]
        var labels: [ActivityGroundTruthLabel]
    }

    static func state(for task: ActivityCalibrationTask) -> State {
        if let kind = task.transitionKind {
            switch kind {
            case "sit_to_stand", "walk_stop", "getting_up": return .standing
            case "stand_to_sit": return .seated
            case "walk_start": return .walking
            case "lying_down": return .lying
            default: return .standing
            }
        }
        switch task.locomotion {
        case LocomotionClass.walking.rawValue?: return .walking
        case LocomotionClass.briskWalking.rawValue?: return .brisk
        default: break
        }
        switch task.posture {
        case PostureClass.uprightStationary.rawValue?: return .standing
        case PostureClass.recumbent.rawValue?: return .lying
        default: break
        }
        switch task.semanticTag {
        case ActivityGroundTruthSemanticTag.typing.rawValue?, ActivityGroundTruthSemanticTag.deskWork.rawValue?: return .desk
        case ActivityGroundTruthSemanticTag.fidgeting.rawValue?: return .fidget
        default: return .seated
        }
    }

    /// Orientation change of the move between two states (degrees); nil when the move is a gait start/stop.
    /// Sit/stand and lie/get-up turn the forearm 75–90°, the size the decoder's own scenarios use.
    static func shift(from: State, to: State) -> Double? {
        func level(_ s: State) -> Double? {
            switch s {
            case .seated, .desk, .fidget: return 0
            case .standing: return 75
            case .lying: return -15
            case .walking, .brisk: return nil
            }
        }
        guard let a = level(from), let b = level(to), a != b else { return nil }
        return b - a
    }

    struct Player {
        var sim: ActivitySim
        let w: Wearer
        var state: State = .seated

        mutating func second(_ s: State) {
            var opt = ActivitySim.Options()
            switch s {
            case .seated:
                opt.hr = w.sitHR
                sim.emit(dyn: max(0.003, 0.008 + sim.noise(0.003)), ticks: 0, cls: 0, rotate: sim.noise(0.15), opt: opt)
            case .desk:
                opt.hr = w.sitHR + 2
                sim.emit(dyn: 0.015 + sim.rand() * 0.05, ticks: 0, cls: 0, rotate: sim.noise(0.8), opt: opt)
            case .fidget:
                opt.hr = w.sitHR + 2
                if sim.rand() < 0.2 {
                    sim.emit(dyn: 0.10 + sim.rand() * 0.16, ticks: 0, cls: 0, rotate: sim.noise(0.3), jitter: sim.noise(22),
                             opt: opt)
                } else {
                    sim.emit(dyn: 0.010 + sim.rand() * 0.02, ticks: 0, cls: 0, rotate: sim.noise(0.4), opt: opt)
                }
            case .standing:
                opt.hr = w.standHR
                sim.emit(dyn: max(0.004, w.standDyn + sim.noise(w.standDyn * 0.35)), ticks: 0, cls: 0,
                         rotate: sim.noise(0.5), jitter: sim.noise(w.standDyn > 0.03 ? 4 : 1), opt: opt)
            case .walking, .brisk:
                let brisk = s == .brisk
                opt.hr = brisk ? w.briskHR : w.walkHR
                let base = brisk ? w.briskDyn : w.walkDyn
                let i = sim.observations.count
                sim.emit(dyn: base + sim.noise(0.04), ticks: (i % 2 == 0) ? 2 : (brisk ? 2 : 1), cls: 1,
                         rotate: sim.noise(0.3), jitter: sim.noise(10), opt: opt)
            case .lying:
                opt.hr = w.lieHR
                sim.emit(dyn: max(0.003, 0.006 + sim.noise(0.002)), ticks: 0, cls: 0, rotate: sim.noise(0.1), opt: opt)
            }
        }

        mutating func hold(_ seconds: Int) { for _ in 0..<seconds { second(state) } }

        /// Move to `next`: a 3-s posture shift, or an immediate gait change.
        mutating func move(to next: State) {
            if let degrees = ActivityPersonalCalibrationEndToEndTests.shift(from: state, to: next) {
                var opt = ActivitySim.Options()
                opt.hr = w.standHR
                sim.postureShift(netDegrees: degrees, opt: opt)
                state = next
            } else {
                state = next
                second(state)
            }
        }
    }

    /// One guided run as the session runner records it: a 3-s countdown holding the current state before each
    /// step, label interval `[cue + guard, cue + duration - guard)`, transitions cued at `cue + preState`.
    static func session(_ w: Wearer, id: String, seed: UInt64, start: Int, leadIn: Int = 600) -> Session {
        var p = Player(sim: ActivitySim(start: start, seed: seed), w: w)
        var labels: [ActivityGroundTruthLabel] = []
        p.hold(leadIn)
        for task in ActivityCalibrationProtocols.current.tasks {
            p.hold(ActivityCalibrationSessionCountdown.seconds)
            let cue = p.sim.ts
            let target = state(for: task)
            var transitionTs: Int?
            if task.transitionKind != nil {
                let pre = task.preStateSeconds ?? 0
                p.hold(pre)
                transitionTs = p.sim.ts
                p.move(to: target)
                p.hold(max(0, cue + task.durationSeconds - p.sim.ts))
            } else {
                if p.state != target { p.move(to: target) }
                p.hold(max(0, cue + task.durationSeconds - p.sim.ts))
            }
            labels.append(ActivityGroundTruthLabel(
                labelKey: "guided:\(id):\(cue)", source: .guided, sessionId: id,
                protocolVersion: ActivityCalibrationProtocols.current.version, repetition: 0,
                startTs: cue + task.guardSeconds, endTs: cue + task.durationSeconds - task.guardSeconds,
                posture: task.posture, locomotion: task.locomotion, armBehavior: task.armBehavior,
                transitionKind: task.transitionKind, transitionTs: transitionTs, semanticTag: task.semanticTag,
                labelConfidence: 1))
        }
        p.hold(30)
        return Session(observations: p.sim.observations, labels: labels)
    }

    static func runs(_ w: Wearer, count: Int, seed: UInt64 = 1) -> [ActivityCalibrationRun] {
        (0..<count).map { i in
            let s = session(w, id: "\(w.name)-\(i)", seed: seed &+ UInt64(31 * i), start: 1_760_000_000 + i * 86_400)
            return ActivityCalibrationRun(sessionId: "\(w.name)-\(i)", observations: s.observations, labels: s.labels)
        }
    }

    // MARK: Scoring an unseen day

    struct DayScore {
        var balanced: Double
        var recall: [BodyMode: Double]
    }

    static func score(_ run: ActivityCalibrationRun, config: ActivityDecoderConfig) -> DayScore {
        let replay = ActivityPersonalProfileFitter.replay(run, config: config)
        var total: [BodyMode: Int] = [:], hit: [BodyMode: Int] = [:]
        for s in replay.samples {
            total[s.truth, default: 0] += 1
            if s.predicted == s.truth { hit[s.truth, default: 0] += 1 }
        }
        var recall: [BodyMode: Double] = [:]
        for (mode, n) in total where n >= 10 { recall[mode] = Double(hit[mode] ?? 0) / Double(n) }
        let balanced = recall.isEmpty ? 0 : recall.values.reduce(0, +) / Double(recall.count)
        return DayScore(balanced: balanced, recall: recall)
    }

    /// Fit on `calibrationRuns` guided runs, then decode a fresh run (new seed, new day) with and without the result.
    static func calibrate(_ w: Wearer, calibrationRuns: Int = 3, seed: UInt64 = 1)
        -> (result: ActivityPersonalFitResult, before: DayScore, after: DayScore) {
        let result = ActivityPersonalProfileFitter.fit(runs: runs(w, count: calibrationRuns, seed: seed),
                                                       config: ActivityDecoderConfig(), now: 1_770_000_000)
        let fresh = session(w, id: "\(w.name)-unseen", seed: 9_001 &+ seed, start: 1_765_000_000)
        let unseen = ActivityCalibrationRun(sessionId: "unseen", observations: fresh.observations, labels: fresh.labels)
        var personal = ActivityDecoderConfig()
        personal.personalProfile = result.profile
        return (result, score(unseen, config: ActivityDecoderConfig()), score(unseen, config: personal))
    }

    static func describe(_ w: Wearer, _ c: (result: ActivityPersonalFitResult, before: DayScore, after: DayScore)) -> String {
        let modes: [BodyMode] = [.seated, .upright, .bedRest, .walk, .briskWalk]
        let classes = modes.compactMap { m -> String? in
            guard let b = c.before.recall[m], let a = c.after.recall[m] else { return nil }
            return "\(m.personalKey) \(Int(b * 100))->\(Int(a * 100))"
        }
        return "\(w.name): \(c.result.status.rawValue), unseen day balanced \(Int(c.before.balanced * 100))% -> "
            + "\(Int(c.after.balanced * 100))% [\(classes.joined(separator: ", "))], adapted "
            + "\(c.result.profile?.modes.keys.sorted() ?? [])"
    }

    // MARK: Tests

    func testTheGuidedProtocolProducesUsableTrainingData() throws {
        let run = try XCTUnwrap(Self.runs(Self.busyStander, count: 1).first)
        let truth = ActivityPersonalProfileFitter.truthBySecond(run.labels)
        let seconds = Dictionary(grouping: truth.values, by: { $0 }).mapValues(\.count)
        XCTAssertGreaterThanOrEqual(seconds[.upright] ?? 0, ActivityPersonalProfileFitter.minModeSeconds,
                                    "one run's standing must clear the minimum")
        XCTAssertGreaterThanOrEqual(seconds[.seated] ?? 0, ActivityPersonalProfileFitter.minModeSeconds)
        XCTAssertGreaterThanOrEqual(seconds[.walk] ?? 0, ActivityPersonalProfileFitter.minModeSeconds)
        XCTAssertGreaterThan(seconds[.bedRest] ?? 0, 0)
        XCTAssertGreaterThan(seconds[.briskWalk] ?? 0, 0)
        XCTAssertEqual(run.labels.filter { $0.transitionKind != nil }.count, 10)
    }

    func testCalibrationFixesAWearerTheDefaultsMisread() {
        for w in [Self.busyStander, Self.fitBusyStander] {
            let c = Self.calibrate(w)
            let line = Self.describe(w, c)
            print("CALIBRATION", line)
            XCTAssertEqual(c.result.status, .adopted, line)
            XCTAssertGreaterThanOrEqual(c.after.balanced - c.before.balanced, 0.05, line)
            XCTAssertGreaterThan((c.after.recall[.upright] ?? 0) - (c.before.recall[.upright] ?? 0), 0.3,
                                 "standing is what the defaults got wrong: \(line)")
            for (mode, before) in c.before.recall {
                XCTAssertGreaterThanOrEqual(c.after.recall[mode] ?? 0, before - 0.05, "\(mode.personalKey) got worse: \(line)")
            }
        }
    }

    /// The same result across independent noise draws, not one lucky seed.
    func testCalibrationHoldsAcrossSeeds() {
        for seed: UInt64 in [2, 17, 404, 8_191] {
            for w in [Self.busyStander, Self.fitBusyStander, Self.typical] {
                let c = Self.calibrate(w, seed: seed)
                let line = "seed \(seed) " + Self.describe(w, c)
                print("CALIBRATION", line)
                for (mode, before) in c.before.recall {
                    XCTAssertGreaterThanOrEqual(c.after.recall[mode] ?? 0, before - 0.05, "\(mode.personalKey) got worse: \(line)")
                }
                if w.name != Self.typical.name {
                    XCTAssertEqual(c.result.status, .adopted, line)
                    XCTAssertGreaterThanOrEqual(c.after.balanced - c.before.balanced, 0.05, line)
                }
            }
        }
    }

    func testTwoGuidedRunsAreEnoughToCalibrate() {
        let c = Self.calibrate(Self.busyStander, calibrationRuns: 2)
        let line = Self.describe(Self.busyStander, c)
        print("CALIBRATION", line)
        XCTAssertEqual(c.result.status, .adopted, line)
        XCTAssertNotNil(c.result.profile?.modes["upright"], "standing adapts from two runs: \(line)")
        XCTAssertGreaterThanOrEqual(c.after.balanced - c.before.balanced, 0.05, line)
    }

    func testAWearerTheDefaultsAlreadyFitIsNeverMadeWorse() {
        let c = Self.calibrate(Self.typical)
        let line = Self.describe(Self.typical, c)
        print("CALIBRATION", line)
        XCTAssertGreaterThanOrEqual(c.after.balanced, c.before.balanced - 0.02, line)
        for (mode, before) in c.before.recall {
            XCTAssertGreaterThanOrEqual(c.after.recall[mode] ?? 0, before - 0.05, "\(mode.personalKey) got worse: \(line)")
        }
        if c.result.status != .adopted {
            XCTAssertNil(c.result.profile)
            XCTAssertEqual(c.after.balanced, c.before.balanced, "a refused profile leaves the decoder untouched")
        }
    }

    func testOneGuidedRunIsNotEnough() {
        let c = Self.calibrate(Self.busyStander, calibrationRuns: 1)
        XCTAssertEqual(c.result.outcome, .needsMoreRuns(have: 1, need: 2))
        XCTAssertEqual(c.after.balanced, c.before.balanced)
    }
}

/// The session runner's pre-step countdown, mirrored here because the runner lives in the app target.
enum ActivityCalibrationSessionCountdown {
    static let seconds = 3
}
