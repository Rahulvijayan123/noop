import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class ActivityContextProgressiveDecodeTests: XCTestCase {

    private func day() -> ActivityContextTrackInput {
        var sim = ActivitySim()
        sim.desk(420); sim.postureShift(netDegrees: 40); sim.still(200); sim.walk(240)
        sim.fidget(300); sim.postureShift(netDegrees: -40); sim.desk(360); sim.run(120); sim.still(180)
        return sim.trackInput()
    }

    func testDecodingInPiecesGivesTheSameDocumentAsDecodingInOne() throws {
        let input = day()
        let (whole, wholeHow) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 500)
        XCTAssertEqual(wholeHow, .recomputed(reason: "no_cache"))

        var seen = 0
        let (pieces, how) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 500,
                                                             chunkObservations: 300) { _ in seen += 1 }
        XCTAssertEqual(how, .recomputed(reason: "no_cache"))
        XCTAssertGreaterThan(seen, 2, "a day this long is reported on more than once")
        XCTAssertEqual(pieces, whole)
    }

    func testEachReportIsTheDaySoFarAndGrows() throws {
        let input = day()
        var reports: [ActivityContextDayDocument] = []
        let (final, _) = ActivityContextDayBuilder.update(cached: nil, input: input, now: 500,
                                                          chunkObservations: 400) { reports.append($0) }
        XCTAssertFalse(reports.isEmpty)

        var previousThrough = input.dayStart
        for r in reports {
            let through = try XCTUnwrap(r.dataThrough)
            XCTAssertGreaterThan(through, previousThrough)
            previousThrough = through
            XCTAssertNil(r.snapshot, "a partial day must never be stored as a resumable one")
            XCTAssertEqual(r.dayStart, input.dayStart)
            XCTAssertEqual(r.dayEnd, through)
            XCTAssertLessThanOrEqual(r.runs.last?.end ?? 0, through + r.publishIntervalS)
        }
        XCTAssertLessThan(previousThrough, try XCTUnwrap(final.dataThrough))
        XCTAssertNotNil(final.snapshot)
    }

    func testAShortDayIsDecodedInOnePassWithNoReports() {
        var sim = ActivitySim()
        sim.desk(120)
        var calls = 0
        let (doc, _) = ActivityContextDayBuilder.update(cached: nil, input: sim.trackInput(), now: 1,
                                                        chunkObservations: 3_600) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(doc.runs.isEmpty)
    }

    func testResumingAfterAChunkedDecodeStillWorks() throws {
        let full = day()
        var head = full
        head.dayEnd = full.dayStart + 900
        let (cached, _) = ActivityContextDayBuilder.update(cached: nil, input: head, now: 100,
                                                           chunkObservations: 200) { _ in }
        let stored = try JSONDecoder().decode(ActivityContextDayDocument.self, from: JSONEncoder().encode(cached))
        let (resumed, how) = ActivityContextDayBuilder.update(cached: stored, input: full, now: 200)
        guard case .resumed = how else { return XCTFail("expected a resume, got \(how)") }
        let (whole, _) = ActivityContextDayBuilder.update(cached: nil, input: full, now: 200)
        XCTAssertEqual(resumed.snapshot, whole.snapshot)
        XCTAssertEqual(resumed.events, whole.events)
        XCTAssertEqual(resumed.summary.labelSeconds, whole.summary.labelSeconds)
    }

    func testDayStateSegmentsSurviveTheDiskCache() throws {
        let seg = DayStateSegment(state: .walking, basis: .strapActivityClass, start: 100, end: 400,
                                  avgHr: 98, minHr: 80, maxHr: 120, motionG: 0.31, locomotionShare: 0.9,
                                  stepTicks: 540, workoutSport: nil)
        let still = DayStateSegment(state: .still, basis: .motion, start: 400, end: 900,
                                    avgHr: nil, minHr: nil, maxHr: nil, motionG: nil, locomotionShare: nil,
                                    workoutSport: nil)
        let back = try JSONDecoder().decode([DayStateSegment].self, from: JSONEncoder().encode([seg, still]))
        XCTAssertEqual(back, [seg, still])
    }
}
