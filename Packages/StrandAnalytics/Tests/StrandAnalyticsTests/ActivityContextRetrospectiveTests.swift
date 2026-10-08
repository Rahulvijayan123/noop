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

    func testRetrospectiveWalkThenStillIsOneStillnessIntervalNearTheTrueStop() {
        let s = Self.walkThenStill
        let retro = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events)
        XCTAssertTrue(retro.allSatisfy { $0.derivation == .retrospective })
        let walking = retro.filter { $0.activityClass == .walking }
        XCTAssertEqual(walking.count, 1)
        let after = retro.filter { $0.start >= walking[0].end }
        // One situation: every row after the walk is the same still class, contiguous; only the 900 s row cap cuts it.
        XCTAssertEqual(Set(after.map(\.activityClass)), [.sitting], "\(after.map(\.activityClass))")
        for (a, b) in zip(after, after.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertLessThanOrEqual(abs(after[0].start - s.stop), 5)
        XCTAssertEqual(after.last?.end, s.stop + 1200)

        // Without the row cap the stillness is exactly one interval.
        var config = ActivityContextRetrospective.Config()
        config.builder.maxIntervalS = 3_600
        let one = ActivityContextRetrospective.intervals(runs: s.runs, events: s.events, config: config)
            .filter { $0.start >= s.stop - 5 }
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.first?.activityClass, .sitting)
        XCTAssertLessThanOrEqual(abs((one.first?.start ?? 0) - s.stop), 5)
    }

    func testRetrospectiveMovesALateWalkBoundaryBackToTheFlaggedStopOnset() {
        // The causal decoder drew the boundary 12 s after the true stop; the stop it flagged has its onset there.
        let stop = Self.t0 + 300
        let runs = [Self.walk(Self.t0, stop + 12), Self.sitting(stop + 12, stop + 900)]
        let events = [ActivityTransitionEvent(kind: .walkStop, probability: 0.9, ts: stop + 14, onsetTs: stop + 1)]
        let retro = ActivityContextRetrospective.intervals(runs: runs, events: events)
        let still = retro.first { $0.activityClass == .sitting }
        XCTAssertNotNil(still)
        XCTAssertLessThanOrEqual(abs((still?.start ?? 0) - stop), 5)
        // Causal output keeps its own boundary.
        let causal = ActivityContextIntervalBuilder.build(runs: runs, events: events)
        XCTAssertEqual(causal.first { $0.activityClass == .sitting }?.start, stop + 12)
    }

    func testAShortStandWithFlaggedChangesSurvivesAsAnIntervalAndTheEventsAreKept() {
        let t = Self.t0
        let runs = [Self.sitting(t, t + 300), Self.standing(t + 300, t + 310), Self.sitting(t + 310, t + 600)]
        let events = [
            ActivityTransitionEvent(kind: .sitToStandLike, probability: 0.6, ts: t + 303, onsetTs: t + 299),
            ActivityTransitionEvent(kind: .standToSitLike, probability: 0.6, ts: t + 313, onsetTs: t + 309),
        ]
        // Causal: the 10 s stand is a hedge the still-dwell fold absorbs (kept only as events).
        let causal = ActivityContextIntervalBuilder.build(runs: runs, events: events)
        XCTAssertFalse(causal.contains { $0.activityClass == .standing })

        let smoothed = ActivityContextRetrospective.smooth(runs: runs, events: events)
        XCTAssertEqual(ActivityClassifier.classify(run: smoothed[1]).activityClass, .standing,
                       "a flagged change on both sides: nothing carries across, the stand keeps its own reading")
        let retro = ActivityContextRetrospective.intervals(runs: runs, events: events)
        let stand = retro.filter { $0.activityClass == .standing }
        XCTAssertEqual(stand.count, 1, "\(retro.map { ($0.activityClass, $0.start, $0.end) })")
        XCTAssertEqual(stand.first?.start, t + 300)
        XCTAssertEqual(stand.first?.end, t + 310)
        // The events are the decoder's, untouched; each row counts the ones inside it.
        XCTAssertEqual(retro.compactMap(\.transitionCount).reduce(0, +), 2)

        // The same stand with no flagged change is a hedge inside one stillness, smoothed into it.
        let unflagged = ActivityContextRetrospective.intervals(runs: runs, events: [])
        XCTAssertFalse(unflagged.contains { $0.activityClass == .standing })
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
