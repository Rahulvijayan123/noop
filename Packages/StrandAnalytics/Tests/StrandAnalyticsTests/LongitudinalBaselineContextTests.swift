import XCTest
import WhoopStore
@testable import StrandAnalytics

final class LongitudinalBaselineContextTests: XCTestCase {

    private func sitting(_ start: Int, _ end: Int, hr: Double, detail: String? = nil) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: end, activityClass: "sitting", confidence: 0.9,
                                   evidenceQuality: 0.9, posture: "seated_likely", locomotion: "stationary",
                                   sleepState: "awake", wearState: "on_wrist", intensity: 0.05,
                                   hrSamples: end - start, hrMean: hr, detail: detail)
    }

    func testAVehicleRideNeverFeedsTheRestStrata() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = 1_780_000_000 - 1_780_000_000 % 86_400 + 12 * 3600
        let rows = [sitting(noon, noon + 600, hr: 60),
                    sitting(noon + 600, noon + 2400, hr: 60),
                    sitting(noon + 2400, noon + 4200, hr: 95, detail: ActivityDetail.inVehicle.rawValue)]
        let obs = LongitudinalBaseline.ContextMaterializer.observations(rows: rows, calendar: cal)
        for series in [LBSeries.awakeRestHR, .awakeSeatedHR] {
            let value = try XCTUnwrap(obs[series]?.first?.value, "\(series)")
            XCTAssertEqual(value, 60, accuracy: 1e-9, "\(series) mixed the ride's heart rate into seated rest")
        }
    }
}
