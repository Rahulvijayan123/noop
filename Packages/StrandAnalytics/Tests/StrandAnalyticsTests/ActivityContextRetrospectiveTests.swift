import Foundation
import XCTest
@testable import StrandAnalytics

/// D8-10: retrospective smoothing of a final day's runs. One physically constant stillness after a walk is one
/// situation, the causal output is untouched and stamped causal, a short flagged stand survives, and the result is
/// deterministic. Runs are written the way the decoder stores them (mean head probabilities per run), so the tests
/// pin the smoother, not the decoder's current posteriors.
final class ActivityContextRetrospectiveTests: XCTestCase {

    static let t0 = 1_760_000_000

    static func run(_ start: Int, _ end: Int, posture: [PostureClass: Double] = [:],
                    locomotion: [LocomotionClass: Double] = [.stationary: 0.95],
                    arm: [ArmBehaviorClass: Double] = [.quiet: 0.8], confidence: Double = 0.8,
                    inBed: Bool = false) -> ActivityContextRun {
        ActivityContextRun(start: start, end: end, posture: HeadProbabilities(posture),
                           locomotion: HeadProbabilities(locomotion), armBehavior: HeadProbabilities(arm),
                           intensity: 0.2, overallConfidence: confidence, overallUncertainty: 0.2,
                           displayContext: nil, sleep: .awake, inBed: inBed, wear: .onWrist,
                           count: max(1, (end - start) / 5))
    }

    static func walk(_ s: Int, _ e: Int) -> ActivityContextRun {
        run(s, e, posture: [.uprightStationary: 0.6, .unknown: 0.4], locomotion: [.walking: 0.9, .stationary: 0.05])
    }
    static func standingLikely(_ s: Int, _ e: Int) -> ActivityContextRun {
        run(s, e, posture: [.uprightStationary: 0.55, .seatedLikely: 0.2, .unknown: 0.25])
    }
    static func unresolved(_ s: Int, _ e: Int) -> ActivityContextRun {
        run(s, e, posture: [.seatedLikely: 0.35, .uprightStationary: 0.3, .unknown: 0.35])
    }
    static func sitting(_ s: Int, _ e: Int) -> ActivityContextRun {
        run(s, e, posture: [.seatedLikely: 0.7, .uprightStationary: 0.1, .unknown: 0.2])
    }
    static func standing(_ s: Int, _ e: Int) -> ActivityContextRun {
        run(s, e, posture: [.uprightStationary: 0.7, .seatedLikely: 0.1, .unknown: 0.2])
    }

    /// walk(300) then still(1200), stored the way the causal decoder publishes it: "Standing (likely)" for the
    /// first minute, then "Still, sitting or standing", then "Sitting quietly". The walk stop is flagged 5 s after
    /// it happened, with its onset at the true stop.
    static var walkThenStill: (runs: [ActivityContextRun], events: [ActivityTransitionEvent], stop: Int) {
        let stop = t0 + 300
        let runs = [walk(t0, stop), standingLikely(stop, stop + 60), unresolved(stop + 60, stop + 180),
                    sitting(stop + 180, stop + 600), sitting(stop + 600, stop + 1200)]
        let events = [ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: stop + 5, onsetTs: stop,
                                              source: ActivityTransitionEvent.sourceDecoder)]
        return (runs, events, stop)
    }

    func testCausalBuildSplitsOneStillnessIntoThreeClassesAndIsStampedCausal() {
        let s = Self.walkThenStill
        let causal = ActivityContextIntervalBuilder.build(runs: s.runs, events: s.events)
        let after = causal.filter { $0.start >= s.stop }
        XCTAssertEqual(Set(after.map(\.activityClass)), [.standing, .stationary, .sitting],
                       "the causal artefact this pass exists for: \(after.map(\.activityClass))")
        XCTAssertTrue(causal.allSatisfy { $0.derivation == .causal })
        // Unchanged by the retrospective pass existing: the builder's default config never keeps fragments.
        XCTAssertFalse(ActivityContextIntervalBuilder.Config().keepEvidencedPostureFragments)
    }

    func testRetrospectiveDemotesTheContradictedStandAndMergesTheStillnessWithoutANewClaim() {
        let s = Self.walkThenStill
        let causal = ActivityContextIntervalBuilder.build(runs: s.runs, events: s.events)
        let retro = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events)
        XCTAssertTrue(retro.allSatisfy { $0.derivation == .retrospective })
        let walking = retro.filter { $0.activityClass == .walking }
        XCTAssertEqual(walking.count, 1)
        let after = retro.filter { $0.start >= walking[0].end }
        let causalAfter = causal.filter { $0.start >= s.stop }
        // The "Standing (likely)" minute the rest of the stillness contradicts is demoted to still-unresolved and
        // merges with the unresolved stretch after it; sitting stays where the causal build claimed it, and no
        // second gains a posture claim.
        XCTAssertFalse(after.contains { $0.activityClass == .standing })
        XCTAssertEqual(after.first?.activityClass, .stationary)
        XCTAssertEqual(after.first?.end, s.stop + 180)
        XCTAssertLessThan(after.count, causalAfter.count)
        XCTAssertLessThanOrEqual(abs(after[0].start - s.stop), 5)
        for (a, b) in zip(after, after.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        Self.assertPolicy(retro: retro, causal: causal)
    }

    func testRetrospectiveMovesALateWalkBoundaryOnlyIntoARowWithoutAPostureClaim() {
        let stop = Self.t0 + 300
        let events = [ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: stop + 14, onsetTs: stop + 3)]
        // Still-unresolved after the walk: the boundary moves back to the flagged onset.
        let runs = [Self.walk(Self.t0, stop + 12), Self.unresolved(stop + 12, stop + 900)]
        let retro = ActivityContextRetrospective.intervals(runs: runs, events: events)
        XCTAssertEqual(retro.first { $0.activityClass == .stationary }?.start, stop + 3)
        // Never further back than the decoder's own onset lead, and never leaving a walk shorter than 10 s.
        let far = [ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: stop + 14, onsetTs: stop - 5)]
        XCTAssertEqual(ActivityContextRetrospective.intervals(runs: runs, events: far)
                        .first { $0.activityClass == .stationary }?.start, stop + 12)
        let shortWalk = [Self.walk(stop - 2, stop + 12), Self.unresolved(stop + 12, stop + 900)]
        XCTAssertEqual(ActivityContextRetrospective.intervals(runs: shortWalk, events: events)
                        .first { $0.activityClass == .stationary }?.start, stop + 12)
        XCTAssertEqual(ActivityContextIntervalBuilder.build(runs: runs, events: events)
                        .first { $0.activityClass == .stationary }?.start, stop + 12, "causal keeps its own boundary")
        // Sitting after the walk: moving the boundary would claim sitting for seconds the causal build did not.
        let sat = [Self.walk(Self.t0, stop + 12), Self.sitting(stop + 12, stop + 900)]
        XCTAssertEqual(ActivityContextRetrospective.intervals(runs: sat, events: events)
                        .first { $0.activityClass == .sitting }?.start, stop + 12)
    }

    func testAShortFlaggedStandIsNotDemotedAndFragmentsAreKeptAsTheCausalBuildKeepsThem() {
        let t = Self.t0
        let runs = [Self.sitting(t, t + 300), Self.standing(t + 300, t + 310), Self.sitting(t + 310, t + 600)]
        let events = [
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.6, ts: t + 303, onsetTs: t + 299),
            ActivityTransitionEvent(kind: .standToSitLike, probability: 0.6, ts: t + 313, onsetTs: t + 309),
        ]
        // A flagged change on both sides: nothing carries across, the stand keeps its own reading.
        let smoothed = ActivityContextRetrospective.smooth(runs: runs, events: events)
        XCTAssertEqual(ActivityClassifier.classify(run: smoothed[1]).activityClass, .standing)
        // Without the flags too: the causal row around it is sitting and the smoothed stillness supports it, so
        // nothing is demoted (demotion is per causal row, never per run inside one).
        let unflagged = ActivityContextRetrospective.smooth(runs: runs, events: [])
        XCTAssertEqual(unflagged, runs)
        // The rows are the causal build's (the stand an absorbed fragment and two events), stamped retrospective.
        let causal = ActivityContextIntervalBuilder.build(runs: runs, events: events)
        let retro = ActivityContextRetrospective.intervals(runs: runs, events: events)
        XCTAssertEqual(retro.map(\.activityClass), causal.map(\.activityClass))
        XCTAssertEqual(retro.map(\.absorbedClasses), causal.map(\.absorbedClasses))
        XCTAssertEqual(retro.compactMap(\.transitionCount).reduce(0, +), 2)
        Self.assertPolicy(retro: retro, causal: causal)
    }

    func testALieDownNextToSittingIsNeverRelabelledWithoutAFlaggedChange() {
        let t = Self.t0
        let lying = { (s: Int, e: Int) in Self.run(s, e, posture: [.recumbent: 0.75, .unknown: 0.25]) }
        for runs in [[lying(t, t + 120), Self.sitting(t + 120, t + 900)],
                     [Self.sitting(t, t + 780), lying(t + 780, t + 900)]] {
            let causal = ActivityContextIntervalBuilder.build(runs: runs, events: [])
            let retro = ActivityContextRetrospective.intervals(runs: runs, events: [])
            XCTAssertEqual(retro.map(\.activityClass), causal.map(\.activityClass))
            XCTAssertTrue(retro.contains { $0.activityClass == .lyingDown })
            XCTAssertTrue(retro.contains { $0.activityClass == .sitting })
            XCTAssertEqual(ActivityContextRetrospective.smooth(runs: runs, events: []), runs)
            Self.assertPolicy(retro: retro, causal: causal)
        }
    }

    /// The policy, per second: every retrospective posture claim is a causal claim of the same posture, and no
    /// retrospective confidence exceeds the causal one.
    static func assertPolicy(retro: [ActivityContextInterval], causal: [ActivityContextInterval],
                             file: StaticString = #filePath, line: UInt = #line) {
        let lookup = ActivityContextLookup(intervals: causal)
        for iv in retro {
            for ts in iv.start..<iv.end {
                let c = lookup.interval(at: ts)
                if let p = ActivityContextRetrospective.claimedPosture(iv.activityClass) {
                    XCTAssertEqual(c.flatMap { ActivityContextRetrospective.claimedPosture($0.activityClass) }, p,
                                   "new \(iv.activityClass) claim at \(ts)", file: file, line: line)
                }
                if let c { XCTAssertLessThanOrEqual(iv.confidence, c.confidence, "raised at \(ts)", file: file, line: line) }
            }
        }
    }

    func testPropertyRetrospectiveNeverAddsAPostureClaimOrRaisesAConfidence() {
        var seed: UInt64 = 0x5eed
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        let makers: [(Int, Int) -> ActivityContextRun] = [
            Self.walk, Self.standingLikely, Self.unresolved, Self.sitting, Self.standing,
            { Self.run($0, $1, posture: [.recumbent: 0.7, .unknown: 0.3]) },
            { Self.run($0, $1, posture: [.seatedLikely: 0.5, .uprightStationary: 0.3, .unknown: 0.2],
                       arm: [.deskLike: 0.8]) },
            { Self.run($0, $1, posture: [.posturalTransition: 0.6, .unknown: 0.4]) },
            { Self.run($0, $1, posture: [.seatedLikely: 0.8, .unknown: 0.2], inBed: true) },
        ]
        let kinds: [ActivityTransitionKind] = [.sitToStandLike, .standToSitLike, .walkStop, .lyingDownLike]
        for _ in 0..<150 {
            var runs: [ActivityContextRun] = []
            var events: [ActivityTransitionEvent] = []
            var t = Self.t0
            for _ in 0..<(3 + Int(rand() * 12)) {
                if rand() < 0.15 { t += 1 + Int(rand() * 30) }   // a gap, sometimes past the merge gap
                let d = 5 * (1 + Int(rand() * 60))
                runs.append(makers[Int(rand() * Double(makers.count)) % makers.count](t, t + d))
                if rand() < 0.4 {
                    let ts = t + Int(rand() * 8)
                    events.append(ActivityTransitionEvent(kind: kinds[Int(rand() * Double(kinds.count)) % kinds.count],
                                                          probability: 0.3 + 0.6 * rand(), ts: ts,
                                                          onsetTs: ts - Int(rand() * 10)))
                }
                t += d
            }
            let causal = ActivityContextIntervalBuilder.build(runs: runs, events: events)
            let retro = ActivityContextRetrospective.intervals(runs: runs, events: events)
            Self.assertPolicy(retro: retro, causal: causal)
            let claimed = { (ivs: [ActivityContextInterval]) in
                ivs.filter { ActivityContextRetrospective.claimedPosture($0.activityClass) != nil }
                    .reduce(0) { $0 + $1.durationSeconds }
            }
            XCTAssertLessThanOrEqual(claimed(retro), claimed(causal))
            XCTAssertLessThanOrEqual(retro.count, causal.count)
        }
    }


    func testDeterministic() throws {
        let s = Self.walkThenStill
        let a = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events)
        let b = ActivityContextRetrospective.intervals(runs: s.runs.reversed(), events: s.events)
        XCTAssertEqual(a, b)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try enc.encode(a), try enc.encode(ActivityContextRetrospective.intervals(runs: s.runs,
                                                                                                 events: s.events)))
        XCTAssertEqual(a.map(\.storeRow), b.map(\.storeRow))
        XCTAssertTrue(a.map(\.storeRow).allSatisfy { $0.derivation == "retrospective" })
    }

    func testRetrospectiveRowsAreWrittenOnlyForFinalDays() {
        let s = Self.walkThenStill
        let input = ActivityContextTrackInput(dayStart: Self.t0, dayEnd: Self.t0 + 86_400)
        var doc = ActivityContextDayDocument(track: ActivityContextTrackBuilder.build(input), input: input,
                                             generatedAt: Self.t0)
        doc.runs = s.runs; doc.events = s.events
        XCTAssertTrue(ActivityContextPersistence.retrospectiveIntervals(
            document: doc, from: Self.t0, to: Self.t0 + 86_400, finality: "provisional").isEmpty)
        let final = ActivityContextPersistence.retrospectiveIntervals(
            document: doc, from: Self.t0, to: Self.t0 + 86_400, finality: "final")
        XCTAssertFalse(final.isEmpty)
        XCTAssertTrue(final.allSatisfy { $0.derivation == .retrospective })
    }

    func testACausalReaderNeverGetsRetrospectiveIntervals() {
        let s = Self.walkThenStill
        let causal = ActivityContextIntervalBuilder.build(runs: s.runs, events: s.events)
        let retro = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events)
        let day = Self.t0..<(Self.t0 + 86_400)
        // Even handed a mixed list, the causal reader gets only causal rows.
        let live = ActivityContextRetrospective.select(causal: causal + retro, retrospective: retro,
                                                       finalDays: [day], for: .causal)
        XCTAssertEqual(live, causal)
        // A historical reader of a final, smoothed day gets the smoothed rows, and only them, for that day.
        let history = ActivityContextRetrospective.select(causal: causal, retrospective: retro, finalDays: [day],
                                                          for: .historical)
        XCTAssertEqual(history, retro)
        // A day that is not final keeps its causal rows for every reader.
        XCTAssertEqual(ActivityContextRetrospective.select(causal: causal, retrospective: retro, finalDays: [],
                                                           for: .historical), causal)
    }

    func testAStoredRowReadsBackItsDerivation() {
        let s = Self.walkThenStill
        let retro = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events)
        XCTAssertEqual(retro.map { ActivityContextInterval(row: $0.storeRow) }, retro)
        let causal = ActivityContextIntervalBuilder.build(runs: s.runs, events: s.events)
        XCTAssertEqual(causal.map { ActivityContextInterval(row: $0.storeRow) }, causal)
        // A document written before the field existed reads causal.
        let enc = JSONEncoder()
        var obj = try! JSONSerialization.jsonObject(with: enc.encode(causal[0])) as! [String: Any]
        obj["derivation"] = nil
        let legacy = try! JSONDecoder().decode(ActivityContextInterval.self,
                                               from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(legacy.derivation, .causal)
    }

    func testPhysiologyContextCausalViewDropsRetrospectiveIntervalInputs() {
        typealias PC = PhysiologyContext
        let day = "2026-03-10"
        let window = PC.Engine.dayInterval(day, timezoneId: "UTC")
        let identity = PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: "UTC", dayWindow: window)
        let causalRun = PC.ActivityIntervalInput(interval: .init(window.start, window.start + 600),
                                                 activityClass: "standing", confidence: 0.7, revision: 1,
                                                 availableAt: window.start + 600)
        var smoothed = causalRun
        smoothed.activityClass = "sitting"
        smoothed.derivation = ActivityContextDerivation.retrospective.rawValue
        let input = PC.DayInput(identity: identity, mode: .causalLive, availabilityCutoff: window.start + 3_600,
                                generatedAt: window.start + 3_600, activityIntervals: [causalRun, smoothed],
                                regime: PC.DeviceRegimeInput(scoringAlgorithmVersion: "t"))
        let (view, _) = PC.Engine.causalView(input)
        XCTAssertEqual(view.activityIntervals, [causalRun])
    }

    /// The same scenario through the real decoder (walk 300 s, then 1200 s still at a desk-flat forearm). Asserts
    /// only structure, so it holds as the decoder's posteriors move: after the walk the retrospective day holds no
    /// more distinct still classes than the causal one, every row after the walk is still-family, and the first
    /// one starts within 5 s of where the causal day put the stop or of the true stop.
    func testDecodedWalkThenStillIsNotFragmentedFurtherByRetrospectiveSmoothing() {
        var sim = ActivitySim()
        sim.walk(300)
        let stop = sim.ts
        sim.still(1200)
        let input = sim.trackInput()
        let doc = ActivityContextDayDocument(track: ActivityContextTrackBuilder.build(input), input: input,
                                             generatedAt: sim.ts)
        let causal = ActivityContextIntervalBuilder.build(document: doc)
        let retro = ActivityContextRetrospective.intervals(runs: doc.runs, events: doc.events)
        func stillAfterWalk(_ ivs: [ActivityContextInterval]) -> [ActivityContextInterval] {
            guard let walkEnd = ivs.last(where: { $0.activityClass.isGait })?.end else { return [] }
            return ivs.filter { $0.start >= walkEnd }
        }
        let c = stillAfterWalk(causal), r = stillAfterWalk(retro)
        XCTAssertFalse(r.isEmpty)
        XCTAssertLessThanOrEqual(Set(r.map(\.activityClass)).count, Set(c.map(\.activityClass)).count)
        XCTAssertTrue(r.allSatisfy { $0.activityClass.isStationaryAwake || $0.activityClass == .lightActivity
                                     || $0.activityClass == .unknown },
                      "\(r.map(\.activityClass))")
        let firstStill = r.first { $0.activityClass.isStationaryAwake }
        XCTAssertNotNil(firstStill)
        XCTAssertLessThanOrEqual(min(abs((firstStill?.start ?? 0) - stop),
                                     abs((firstStill?.start ?? 0) - (c.first?.start ?? 0))), 5)
        print("D8-10 decoded causal:", c.map { "\($0.activityClass.rawValue)@\($0.start - stop)" },
              "retro:", r.map { "\($0.activityClass.rawValue)@\($0.start - stop)" })
    }
}
