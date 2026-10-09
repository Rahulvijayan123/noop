import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// A reading the server left unclear takes the label of the activity run it falls in; calories run up through the day.
final class KeyMetricActivityLanesTests: XCTestCase {
    private let lane = [
        KeyMetricContextSpan(start: 0, end: 600, context: .sitting),
        KeyMetricContextSpan(start: 600, end: 900, context: .moving),
        KeyMetricContextSpan(start: 900, end: 1200, context: .unclear),
    ]

    func testUnclearTakesTheRunItFallsIn() {
        XCTAssertEqual(KeyMetricActivityLanes.filled(.unclear, start: 100, end: 400, lane: lane), .sitting)
        XCTAssertEqual(KeyMetricActivityLanes.filled(.unclear, start: 500, end: 900, lane: lane), .moving)
    }

    func testServerLabelAndGapsStayAsTheyAre() {
        XCTAssertEqual(KeyMetricActivityLanes.filled(.sleep, start: 100, end: 400, lane: lane), .sleep)
        XCTAssertEqual(KeyMetricActivityLanes.filled(.unclear, start: 950, end: 1100, lane: lane), .unclear)
        XCTAssertEqual(KeyMetricActivityLanes.filled(.unclear, start: 5000, end: 5300, lane: lane), .unclear)
    }

    func testUnclearLaneStretchIsRecut() {
        let out = KeyMetricActivityLanes.filled([KeyMetricContextSpan(start: 300, end: 1000, context: .unclear)], lane: lane)
        XCTAssertEqual(out.map(\.context), [.sitting, .moving, .unclear])
        XCTAssertEqual(out.first?.start, 300)
        XCTAssertEqual(out.last?.end, 1000)
    }

    func testCaloriesRunUpAndEndOnTheDayTotal() {
        let hr = (0..<3600).map { HRSample(ts: $0, bpm: $0 < 1800 ? 60 : 150) }
        let user = UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male")
        let points = KeyMetricReadings.cumulativeCalories(hr, from: 0, to: 3600, sliceSeconds: 900, profile: user,
                                                          hrmax: 190, restingHR: 55, dayTotal: 400)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.last?.steps ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(points.map(\.steps), points.map(\.steps).sorted())
        // The active half burns more than the quiet half.
        XCTAssertGreaterThan(points[3].steps - points[2].steps, points[1].steps - points[0].steps)
    }
}
