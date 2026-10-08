import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

/// The display-only aggregation behind the Workouts pages: training minutes per day, the bar size per range,
/// zone minutes per bar, and the duration and distance wording. None of it scores anything; these pin that
/// the bars total what the rows say and that the words match the house patterns.
final class WorkoutTrainingPresentationTests: XCTestCase {

    private let cal = Calendar.current

    private func row(_ start: Date, minutes: Double, sport: String = "Running", zones: String? = nil) -> WorkoutRow {
        let ts = Int(start.timeIntervalSince1970)
        return WorkoutRow(startTs: ts, endTs: ts + Int(minutes * 60), sport: sport, source: "whoop",
                          durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                          distanceM: nil, zonesJSON: zones, notes: nil, steps: nil)
    }

    private func day(_ offset: Int, hour: Int = 18) -> Date {
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: offset, to: today)!)!
    }

    func testMinutesPerDaySumsSessionsOnTheSameLocalDay() {
        let points = WorkoutTraining.minutesPerDay([row(day(-1, hour: 7), minutes: 30),
                                                    row(day(-1, hour: 18), minutes: 45),
                                                    row(day(-3), minutes: 20)])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.day, cal.startOfDay(for: day(-3)))
        XCTAssertEqual(points.last?.value ?? 0, 75, accuracy: 0.001)
    }

    func testBarsAreDailyForAWeekWeeklyToThreeMonthsAndMonthlyBeyond() {
        let window = ChartAxis.window(.month, firstDataDay: nil)
        XCTAssertEqual(WorkoutTraining.bin(for: .week, window: window), .day)
        XCTAssertEqual(WorkoutTraining.bin(for: .month, window: window), .weekOfYear)
        XCTAssertEqual(WorkoutTraining.bin(for: .quarter, window: window), .weekOfYear)
        XCTAssertEqual(WorkoutTraining.bin(for: .year, window: window), .month)
    }

    func testAWeeklyBarTotalsItsSessionsRatherThanAveragingThem() {
        // Two sessions in one week: the readout reads the same `.sum` binning the chart draws.
        let points = WorkoutTraining.minutesPerDay([row(day(-1), minutes: 40), row(day(-2), minutes: 50)])
        let weekly = DailyBarChart.bin(points, by: .weekOfYear, aggregation: .sum)
        let total = weekly.reduce(0) { $0 + $1.value }
        XCTAssertEqual(total, 90, accuracy: 0.001)
    }

    func testZoneBarsCarryTheWeeksTotalNotItsMeanDay() {
        let zones = #"{"z1":10,"z2":40,"z3":30,"z4":15,"z5":5}"#
        let rows = [row(day(-1), minutes: 60, zones: zones), row(day(-2), minutes: 30, zones: zones)]
        let days = WorkoutZonesView.zoneDays(WorkoutZonesView.zoneSources(rows), bin: .weekOfYear)
        // However the two days fall across week boundaries, every minute lands in exactly one bar.
        let total = days.reduce(0) { $0 + $1.values.values.reduce(0, +) }
        XCTAssertEqual(total, 90, accuracy: 0.001)
        // And the chart's own per-bin mean leaves each pre-summed bar unchanged.
        let rebinned = StackedBarChart.bin(days, by: .weekOfYear)
        XCTAssertEqual(rebinned.reduce(0) { $0 + $1.values.values.reduce(0, +) }, 90, accuracy: 0.001)
    }

    func testZoneTotalsSkipRowsWithoutZones() {
        let zones = #"{"zone1":20,"zone2":30,"zone3":30,"zone4":20}"#
        let totals = WorkoutZonesView.totals(WorkoutZonesView.zoneSources([row(day(-1), minutes: 50, zones: zones), row(day(-2), minutes: 30)]))
        XCTAssertEqual(totals.count, 5)
        XCTAssertEqual(totals.reduce(0, +), 50, accuracy: 0.001)
        XCTAssertEqual(totals[1], 15, accuracy: 0.001)
    }

    func testStrapEstimatesFillInForSessionsWithoutAnImportedSplit() {
        let zones = #"{"z1":10,"z2":40,"z3":30,"z4":15,"z5":5}"#
        let imported = row(day(-1), minutes: 60, zones: zones)
        let bare = row(day(-2), minutes: 30)
        let sources = WorkoutZonesView.zoneSources([imported, bare], estimated: [bare.startTs: [5, 10, 10, 5, 0]])
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.filter(\.isEstimate).count, 1)
        XCTAssertEqual(WorkoutZonesView.totals(sources).reduce(0, +), 90, accuracy: 0.001)
        // A bin made mostly of strap estimates is drawn as one; a mostly-imported bin is not.
        let days = WorkoutZonesView.zoneDays(sources, bin: .day)
        XCTAssertEqual(days.first(where: { $0.day == self.cal.startOfDay(for: self.day(-2)) })?.isEstimate, true)
        XCTAssertEqual(days.first(where: { $0.day == self.cal.startOfDay(for: self.day(-1)) })?.isEstimate, false)
    }

    func testDurationWording() {
        XCTAssertEqual(WorkoutFormat.duration(minutes: 38), "38 min")
        XCTAssertEqual(WorkoutFormat.duration(minutes: 72), "1 h 12 m")
        XCTAssertEqual(WorkoutFormat.duration(minutes: 120), "2 h")
        XCTAssertNil(WorkoutFormat.duration(seconds: nil))
        XCTAssertNil(WorkoutFormat.duration(seconds: 0))
    }

    func testDistanceSplitsTheUnitFromTheValue() {
        let metric = WorkoutFormat.distance(meters: 22_000, system: .metric)
        XCTAssertEqual(metric.value, "22.0")
        XCTAssertEqual(metric.unit, "km")
        let short = WorkoutFormat.distance(meters: 850, system: .metric)
        XCTAssertEqual(short.value, "850")
        XCTAssertEqual(short.unit, "m")
    }

    func testRangesAppearOnlyWhenTheHistoryReachesPastTheSmallerOne() {
        let now = Date()
        let tenDaysAgo = Int(now.timeIntervalSince1970) - 10 * 86_400
        XCTAssertTrue(WorkoutTraining.isAvailable(.week, oldestTs: tenDaysAgo, now: now))
        XCTAssertTrue(WorkoutTraining.isAvailable(.month, oldestTs: tenDaysAgo, now: now))
        XCTAssertFalse(WorkoutTraining.isAvailable(.quarter, oldestTs: tenDaysAgo, now: now))
        XCTAssertFalse(WorkoutTraining.isAvailable(.year, oldestTs: tenDaysAgo, now: now))
        XCTAssertFalse(WorkoutTraining.isAvailable(.week, oldestTs: nil, now: now))
    }
}
