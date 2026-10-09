import XCTest
@testable import StrandAnalytics

/// D8-08: the wake behind a transition depends on what the transition was and what the reading is for.
final class ActivityTransitionProximityTests: XCTestCase {
    private typealias P = ActivityTransitionProximity

    private func phase(_ events: [P.PrecedingEvent], lookbackS: Int? = nil,
                       policy: P.RecoveryPolicy = .hrvBaseline) -> ActivityPhysiologyPhase {
        P.windowPhase(preceding: events, transitionsInWindow: 0, eventsAvailable: true,
                      lookbackS: lookbackS, policy: policy)
    }

    func testPosturalChangeSettlesHeartRateIn120sButHRVOnlyAfter300s() {
        let sat = { (s: Int) in [P.PrecedingEvent(kind: .standToSitLike, secondsBefore: s)] }
        XCTAssertEqual(phase(sat(10), policy: .heartRate), .transition)
        XCTAssertEqual(phase(sat(60), policy: .heartRate), .recovery)
        XCTAssertEqual(phase(sat(130), policy: .heartRate), .steadyState)
        XCTAssertEqual(phase(sat(10)), .transition)
        XCTAssertEqual(phase(sat(200)), .recovery, "autonomic re-equilibration takes up to 5 min (Watanabe 2007)")
        XCTAssertEqual(phase(sat(300)), .steadyState)
        XCTAssertEqual(P.RecoveryPolicy.hrvBaseline.recoveryS(for: .lyingDownLike), 300)
        XCTAssertEqual(P.RecoveryPolicy.heartRate.recoveryS(for: .gettingUpLike), 120)
    }

    func testStoppingAWalkOrARunLeavesALongerWake() {
        // Before D8-08 every kind was steady 120 s after the event, including stopping a run.
        let walk = { (s: Int) in [P.PrecedingEvent(kind: .walkStop, secondsBefore: s)] }
        XCTAssertEqual(phase(walk(200), policy: .heartRate), .recovery, "a walk's wake outlasts 120 s even for HR")
        XCTAssertEqual(phase(walk(310), policy: .heartRate), .steadyState)
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .runStop, secondsBefore: 1_000)]), .recovery)
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .runStop, secondsBefore: 1_800)]), .steadyState)
        // Dose-scaled: a long walk, or a walk the lookup says was a run.
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .walkStop, secondsBefore: 1_000, boutS: 2_400)]), .recovery)
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .walkStop, secondsBefore: 1_000, boutS: 900)]), .steadyState)
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .walkStop, secondsBefore: 1_000, running: true)]), .recovery)
        // A locomotion start follows the postural rule.
        XCTAssertEqual(P.RecoveryPolicy.hrvBaseline.recoveryS(for: .walkStart), 300)
    }

    func testTheWorstEventWinsNotTheNearest() {
        // A run stopped 600 s ago is still recovering even though a later stand-up has settled.
        let events = [P.PrecedingEvent(kind: .runStop, secondsBefore: 600),
                      P.PrecedingEvent(kind: .sitToStandLike, secondsBefore: 400)]
        XCTAssertEqual(phase(events), .recovery)
        XCTAssertEqual(phase(events + [P.PrecedingEvent(kind: .standToSitLike, secondsBefore: 5)]), .transition)
    }

    func testALookbackShorterThanTheRecoveryIsUnknownNotSteady() {
        // No event in 100 s of history: a change of position 200 s ago cannot be ruled out.
        XCTAssertEqual(phase([], lookbackS: 100), .unknown)
        XCTAssertEqual(phase([], lookbackS: 300), .steadyState)
        XCTAssertEqual(phase([], lookbackS: nil), .steadyState, "nil: the caller vouches for its history")
        // An event that is itself still recovering is reported as such whatever the lookback.
        XCTAssertEqual(phase([P.PrecedingEvent(kind: .standToSitLike, secondsBefore: 60)], lookbackS: 90), .recovery)
        XCTAssertEqual(P.RecoveryPolicy.heartRate.requiredLookbackS, 300, "an undosed walk stop needs 300 s")
    }

    func testNoEventDataAndInWindowTransitionsKeepTheirMeaning() {
        XCTAssertEqual(P.windowPhase(preceding: [], transitionsInWindow: 0, eventsAvailable: false,
                                     lookbackS: 10_000, policy: .hrvBaseline), .unknown)
        XCTAssertEqual(P.windowPhase(preceding: [], transitionsInWindow: 2, eventsAvailable: true,
                                     lookbackS: 10_000, policy: .hrvBaseline), .transition)
    }
}
