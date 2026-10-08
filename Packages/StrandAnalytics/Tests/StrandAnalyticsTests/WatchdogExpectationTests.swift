import XCTest
@testable import StrandAnalytics

/// The Watchdog's expected values are the person's own established baselines for each minute's context — never a
/// model — and nothing at all where no baseline is established or the minute is not at steady state.
final class WatchdogExpectationTests: XCTestCase {
    private func ctx(_ kind: WatchdogMinuteContextKind, posture: LBPosture? = nil, sinceEffortS: Int? = nil,
                     sinceWalkingS: Int? = nil, transition: Bool = false, minute: Int = 0) -> WatchdogMinuteContext {
        WatchdogMinuteContext(minuteUnix: 1_800_000_000 + minute * 60, kind: kind, posture: posture,
                              sinceEffortS: sinceEffortS, sinceWalkingS: sinceWalkingS,
                              recentTransition: transition)
    }

    private func ref(_ refs: [LBEvaluation], _ s: LBSeries) -> WatchdogLiveReference {
        WatchdogLiveReferences.lookup(refs, series: [s])!
    }

    func testEachContextUsesItsOwnBaseline() {
        let refs = WatchdogV2ScenarioTests.references()
        let minutes = [ctx(.asleep), ctx(.awakeStill, posture: .seated), ctx(.walking), ctx(.active), ctx(.unknown)]
        let hr = WatchdogExpectation.track(channel: "HR", context: minutes, evaluations: refs)
        XCTAssertEqual(hr.series, [.sleepHR, .awakeRestHR, .walkingHR, nil, nil],
                       "seated stratum not established → pooled awake rest, never a sleep series")
        XCTAssertEqual(hr.center[0]!, ref(refs, .sleepHR).center, accuracy: 1e-9)
        XCTAssertEqual(hr.scale[0]!, ref(refs, .sleepHR).scale, accuracy: 1e-9)
        XCTAssertEqual(hr.center[2]!, ref(refs, .walkingHR).center, accuracy: 1e-9)
        XCTAssertNil(hr.center[3], "vigorous minutes have no expectation")
        XCTAssertNil(hr.center[4])

        let temp = WatchdogExpectation.track(channel: "Temp", context: minutes, evaluations: refs)
        XCTAssertEqual(temp.series, [.sleepTemp, nil, nil, nil, nil], "awake skin temperature has no reference")
        let resp = WatchdogExpectation.track(channel: "Resp", context: minutes, evaluations: refs)
        XCTAssertEqual(resp.series, [.sleepResp, nil, nil, nil, nil])
        let spo2 = WatchdogExpectation.track(channel: "SpO2", context: minutes, evaluations: refs)
        XCTAssertEqual(spo2.series.first!, .sleepSpO2Mean)
    }

    func testHRVIsDrawnInMillisecondsFromTheLnReference() {
        let refs = WatchdogV2ScenarioTests.references()
        let t = WatchdogExpectation.track(channel: "HRV", context: [ctx(.awakeStill, posture: .supine)],
                                          evaluations: refs)
        let r = ref(refs, .awakeRestHRVLn)
        XCTAssertEqual(t.center[0]!, exp(r.center), accuracy: 1e-9)
        XCTAssertEqual(t.scale[0]!, exp(r.center) * sinh(r.scale), accuracy: 1e-9)
    }

    func testRecoveryAndTransitionsHaveNoExpectation() {
        let refs = WatchdogV2ScenarioTests.references()
        let minutes = [
            ctx(.awakeStill, sinceEffortS: 20 * 60),      // 20 min after vigorous: recovering
            ctx(.awakeStill, sinceEffortS: 31 * 60),      // past 30 min: steady
            ctx(.awakeStill, sinceWalkingS: 5 * 60),      // 5 min after walking: settling
            ctx(.awakeStill, sinceWalkingS: 11 * 60),
            ctx(.asleep, transition: true),               // sleep edge
        ]
        let hr = WatchdogExpectation.track(channel: "HR", context: minutes, evaluations: refs)
        XCTAssertNil(hr.center[0])
        XCTAssertNotNil(hr.center[1])
        XCTAssertNil(hr.center[2])
        XCTAssertNotNil(hr.center[3])
        XCTAssertNil(hr.center[4])
    }

    func testNoEstablishedBaselineMeansNothingIsDrawn() {
        let minutes = [ctx(.asleep), ctx(.awakeStill, posture: .upright), ctx(.walking)]
        for ch in ["HR", "RHR", "HRV", "Temp", "Resp", "SpO2"] {
            let t = WatchdogExpectation.track(channel: ch, context: minutes, evaluations: [])
            XCTAssertTrue(t.center.allSatisfy { $0 == nil }, ch)
        }
    }

    func testAnEstablishedPostureStratumIsPreferredOverThePooledOne() {
        var refs = WatchdogV2ScenarioTests.references()
        let asOf = "2026-09-30"
        let tE = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs: [LBDailyObservation] = (1...70).map { i in
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(tE - i),
                               value: 63 + Double(i % 5) * 0.4, qualityStatus: .ok, coverage: 300,
                               withinDayScale: 3)
        }
        refs.append(LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeSeatedHR, observations: obs))
        let t = WatchdogExpectation.track(channel: "HR", context: [ctx(.awakeStill, posture: .seated),
                                                                   ctx(.awakeStill, posture: .upright)],
                                          evaluations: refs)
        XCTAssertEqual(t.series, [.awakeSeatedHR, .awakeRestHR])
    }
}
