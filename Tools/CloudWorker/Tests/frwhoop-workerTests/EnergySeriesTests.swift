import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The worker's side of the energy-fusion estimator: the calorie series read from the metabolic timeline
/// (so its buckets still sum to the published daily total), the compact `energy` object in the snapshot, and
/// the optional measured-RMR input.
final class EnergySeriesTests: XCTestCase {
    private let dayStart = 1_790_035_200
    private let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")

    private func hr(_ from: Int, _ to: Int, bpm: Int) -> [HRSample] {
        stride(from: from, to: to, by: 1).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// A morning with the strap on, then nothing: most of the day is a coverage gap.
    private func partlyCoveredDay() -> (hr: [HRSample], energy: DayEnergy) {
        let samples = hr(dayStart + 8 * 3600, dayStart + 9 * 3600, bpm: 70)
            + hr(dayStart + 9 * 3600, dayStart + 9 * 3600 + 1800, bpm: 112)
        let energy = MetabolicEstimator.estimate(EnergyDayInput(
            dayStart: dayStart, dayEnd: dayStart + 86_400, hr: samples, profile: profile,
            hrmax: 194, restingHR: 51))
        return (samples, energy)
    }

    private func seriesInputs(_ hr: [HRSample], energy: DayEnergy?) -> IntradaySeries.Inputs {
        IntradaySeries.Inputs(dayStart: dayStart, dayEnd: dayStart + 86_400, hr: hr, rr: [], gravity: [],
                              steps: [], profile: profile, restingHR: 51, energy: energy)
    }

    func testCalorieBucketsSumToTheTimelineTotalIncludingTheUncoveredMinutes() throws {
        let day = partlyCoveredDay()
        let series = IntradaySeries.build(seriesInputs(day.hr, energy: day.energy))
        let points = try XCTUnwrap(series[.calories])
        XCTAssertEqual(points.count, 1440, "one point per elapsed minute, covered or not")
        XCTAssertEqual(points.reduce(0.0) { $0 + $1.value }, day.energy.totalKcal, accuracy: 1e-3)
        XCTAssertGreaterThan(day.energy.restingGapKcal, 1000, "most of the day is a gap")
    }

    func testAnUncoveredMinuteCarriesRestingEnergyAndSaysItHasNoSamples() throws {
        let day = partlyCoveredDay()
        let series = IntradaySeries.build(seriesInputs(day.hr, energy: day.energy))
        let overnight = try XCTUnwrap(series[.calories]?.first { $0.ts == dayStart + 3 * 3600 })
        XCTAssertEqual(overnight.samples, 0)
        XCTAssertEqual(overnight.coverage, 0)
        XCTAssertEqual(overnight.value, day.energy.rmrKcalPerDay / 1440.0, accuracy: 1e-3)
        let walking = try XCTUnwrap(series[.calories]?.first { $0.ts == dayStart + 9 * 3600 + 600 })
        XCTAssertEqual(walking.samples, 60)
        XCTAssertGreaterThan(walking.value, overnight.value * 2, "a brisk-walk minute outweighs resting energy")
    }

    func testWithoutATimelineTheSeriesKeepsTheHeartRateOnlyApportioning() throws {
        let day = partlyCoveredDay()
        let legacy = IntradaySeries.build(seriesInputs(day.hr, energy: nil))
        let expected = Calories.estimateDayEnergy(day.hr, profile: profile, hrmax: StrainScorer.tanakaHRmax(age: 35),
                                                  restingHR: 51).totalKcal
        XCTAssertEqual(try XCTUnwrap(legacy[.calories]).reduce(0.0) { $0 + $1.value }, expected, accuracy: 1e-4)
        XCTAssertLessThan(try XCTUnwrap(legacy[.calories]).count, 200, "legacy emits only minutes that have heart rate")
    }

    func testEnergyJSONCarriesTheSplitAndTheEvidence() throws {
        let energy = partlyCoveredDay().energy
        let json = DayScorer.energyJSON(energy)
        XCTAssertEqual(json["model_version"] as? String, energy.modelVersion)
        XCTAssertEqual(json["rmr_source"] as? String, "equation")
        XCTAssertEqual(try XCTUnwrap(json["total_kcal"] as? Double), energy.totalKcal, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(json["resting_kcal"] as? Double) + (json["active_kcal"] as? Double ?? 0),
                       try XCTUnwrap(json["total_kcal"] as? Double), accuracy: 0.02)
        XCTAssertEqual(json["gap_min"] as? Int, energy.gapMinutes)
        XCTAssertNotNil(json["evidence_min"] as? [String: Int])
        XCTAssertNil(json["projected_total_kcal"], "a complete day has no projection")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json), "must be valid jsonb")
    }

    func testAProjectionIsPublishedForADayStillInProgress() throws {
        let samples = hr(dayStart + 8 * 3600, dayStart + 9 * 3600, bpm: 70)
        let energy = MetabolicEstimator.estimate(EnergyDayInput(
            dayStart: dayStart, dayEnd: dayStart + 86_400, asOf: dayStart + 9 * 3600, hr: samples, profile: profile,
            hrmax: 194, restingHR: 51))
        let json = DayScorer.energyJSON(energy)
        let projected = try XCTUnwrap(json["projected_total_kcal"] as? Double)
        XCTAssertGreaterThan(projected, energy.totalKcal + 1000)
    }

    func testMeasuredRmrIsOnlyAcceptedWhenPlausible() {
        XCTAssertEqual(DayScorer.parseMeasuredRmr("1987"), 1987)
        XCTAssertEqual(DayScorer.parseMeasuredRmr(" 2104.5 "), 2104.5)
        XCTAssertNil(DayScorer.parseMeasuredRmr(nil))
        XCTAssertNil(DayScorer.parseMeasuredRmr(""))
        XCTAssertNil(DayScorer.parseMeasuredRmr("abc"))
        XCTAssertNil(DayScorer.parseMeasuredRmr("350"), "below any adult RMR")
        XCTAssertNil(DayScorer.parseMeasuredRmr("9000"), "above any adult RMR")
        XCTAssertNil(DayScorer.parseMeasuredRmr("nan"))
    }
}
