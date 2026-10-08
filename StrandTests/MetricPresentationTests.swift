import XCTest
import StrandDesign
@testable import Strand

/// Pins the metric detail page's per-metric presentation table (`MetricPresentation`): the chart each
/// kind of data gets, fixed scales where a metric has one, durations for minutes, signed deviations, the
/// display normalisation of sleep efficiency, deltas in points for percentages, and the ExploreRange ↔
/// ChartRange bridge. Presentation only; nothing here touches how a series is loaded or scored.
final class MetricPresentationTests: XCTestCase {

    private func presentation(_ key: String, _ source: String = "my-whoop") throws -> MetricPresentation {
        MetricPresentation.of(try XCTUnwrap(MetricCatalog.metric(key: key, source: source), "\(source):\(key)"))
    }

    // MARK: Every catalog entry has a presentation

    func testEveryCatalogMetricGetsAChartAndFourStatistics() {
        for metric in MetricCatalog.all {
            let p = MetricPresentation.of(metric)
            XCTAssertEqual(p.stats.count, 4, metric.id)
            XCTAssertFalse(p.emptyMessage.isEmpty, metric.id)
            XCTAssertFalse(p.about(title: metric.title, catalogDescription: metric.description).isEmpty, metric.id)
        }
    }

    // MARK: Chart per data type

    func testScoresAreBarsOnTheirFixedScale() throws {
        XCTAssertEqual(try presentation("recovery").chart, .scoreBars(.charge))
        XCTAssertEqual(try presentation("sleep_performance").chart, .scoreBars(.rest))
        XCTAssertEqual(try presentation("strain").chart, .scoreBars(.effort))
        XCTAssertEqual(try presentation("stress").chart, .scoreBars(.dayStress))
        XCTAssertEqual(try presentation("sleep_score", "xiaomi-band").chart, .scoreBars(.rest))
        XCTAssertTrue(try presentation("recovery").isBarChart)
    }

    func testVitalsAreLinesWithTheirMinimumSpansAndBands() throws {
        XCTAssertEqual(try presentation("hrv").chart, .line(minSpan: 20))
        XCTAssertEqual(try presentation("hrv").band, .hrv)
        XCTAssertEqual(try presentation("rhr").chart, .line(minSpan: 10))
        XCTAssertEqual(try presentation("rhr").band, .restingHR)
        XCTAssertEqual(try presentation("resp_rate").chart, .line(minSpan: 3))
        XCTAssertEqual(try presentation("resp_rate").band, .resp)
        XCTAssertNil(try presentation("rhr", "xiaomi-band").band)
    }

    func testOxygenAndEfficiencyAreFixedScalePercentages() throws {
        XCTAssertEqual(try presentation("spo2").chart, .fixedPoints(domain: 85...100, reference: 95, joined: false))
        XCTAssertEqual(try presentation("sleep_efficiency").chart,
                       .fixedPoints(domain: 50...100, reference: 85, joined: true))
    }

    func testSkinTemperatureDeviationIsDivergingAndAbsoluteIsALine() throws {
        let deviation = try presentation("skin_temp")
        XCTAssertEqual(deviation.chart, .diverging)
        XCTAssertEqual(deviation.valueStyle, .signed(decimals: 1))
        XCTAssertFalse(deviation.stats.contains(.vsPrevious), "no percent change of a deviation")
        let absolute = deviation.forSkinTemp(absolute: true)
        XCTAssertEqual(absolute.chart, .line(minSpan: 1))
        XCTAssertEqual(absolute.band, .skinAbsolute)
    }

    func testMinutesAreDurationsAndStagesStack() throws {
        XCTAssertEqual(try presentation("sleep_total_min").valueStyle, .duration)
        XCTAssertEqual(try presentation("sleep_total_min").chart, .totals(.mean))
        XCTAssertEqual(try presentation("sleep_deep_min").chart, .stacked(.sleepStages(highlight: "sleep_deep_min")))
        XCTAssertEqual(try presentation("sleep_deep_min").companions, ["sleep_rem_min", "sleep_light_min"])
        XCTAssertEqual(try presentation("sleep_debt_min").chart, .totals(.mean))
        XCTAssertEqual(try presentation("hr_zones_all_min").chart, .stacked(.zones))
        XCTAssertEqual(try presentation("hr_zones_all_min").companions,
                       ["hr_zone1_min", "hr_zone2_min", "hr_zone3_min", "hr_zone4_min", "hr_zone5_min"])
    }

    func testWorkoutMinutesSumOnTheCalendarAndCountWorkoutDays() throws {
        let zones = try presentation("hr_zones45_min")
        XCTAssertEqual(zones.chart, .totals(.sum))
        XCTAssertEqual(zones.cadence, .workoutDays)
        XCTAssertEqual(zones.stats, [.total, .perActiveDay, .activeDays, .high])
    }

    func testWeeklyEstimatesAreStepLinesAndBodyMetricsArePoints() throws {
        XCTAssertEqual(try presentation("vo2max_est").chart, .stepLine(fixed: nil, minSpan: 5))
        XCTAssertTrue(try presentation("vo2max_est").isEstimateSeries)
        XCTAssertEqual(try presentation("vitality").chart, .stepLine(fixed: 0...100, minSpan: 10))
        XCTAssertTrue(try presentation("fitness_age").referencesAge)
        XCTAssertEqual(try presentation("fitness_age").defaultRange, .half)
        XCTAssertEqual(try presentation("weight", "apple-health").chart, .sparsePoints(minSpan: 2, references: []))
        XCTAssertEqual(try presentation("bmi", "apple-health").chart, .sparsePoints(minSpan: 2, references: [18.5, 25, 30]))
        XCTAssertEqual(try presentation("mood", "noop-mood").chart, .dotStrip)
    }

    func testStepsAndCaloriesMarkOnDeviceDaysAsEstimates() throws {
        XCTAssertTrue(try presentation("energy_kcal").marksOnDeviceDaysAsEstimates)
        XCTAssertTrue(try presentation("steps", "apple-health").marksOnDeviceDaysAsEstimates)
        XCTAssertTrue(try presentation("steps_est").isEstimateSeries)
    }

    // MARK: Values

    func testSleepEfficiencyFractionsAreShownAsPercentages() throws {
        let p = try presentation("sleep_efficiency")
        XCTAssertEqual(p.display(0.9, units: MetricUnitContext(), unitLabel: "%"), 90, accuracy: 1e-9)
        XCTAssertEqual(p.display(91, units: MetricUnitContext(), unitLabel: "%"), 91, accuracy: 1e-9)
    }

    func testDurationsPrintHoursAndMinutes() throws {
        let p = try presentation("sleep_total_min")
        XCTAssertEqual(p.text(402), "6 h 42 m")
        XCTAssertEqual(p.text(42), "42 m")
        XCTAssertNil(p.unit(catalogUnit: "min", units: MetricUnitContext()))
        XCTAssertEqual(p.deltaText(-48, unit: nil), "−48 m")
    }

    func testPercentagesChangeInPointsAndDeviationsInTheirUnit() throws {
        let charge = try presentation("recovery")
        XCTAssertEqual(charge.deltaText(4, unit: "%"), "+4 pts")
        let skin = try presentation("skin_temp")
        XCTAssertEqual(skin.text(0.34), "+0.3")
        XCTAssertEqual(skin.text(-0.26), "−0.3")
        XCTAssertEqual(skin.deltaText(0.2, unit: "°C"), "+0.2 °C")
    }

    func testUnitsFollowTheChosenSystemAndScoresCarryNoUnit() throws {
        let weight = try presentation("weight", "apple-health")
        let imperial = MetricUnitContext(system: .imperial, temperature: .fahrenheit, effortScale: .whoop)
        XCTAssertEqual(weight.unit(catalogUnit: "kg", units: imperial), "lb")
        XCTAssertEqual(weight.display(10, units: imperial, unitLabel: "kg"), 22.0462, accuracy: 1e-4)
        let effort = try presentation("strain")
        XCTAssertNil(effort.unit(catalogUnit: "/100", units: imperial))
        XCTAssertEqual(effort.display(100, units: imperial, unitLabel: "/100"), 21, accuracy: 1e-9)
        let skin = try presentation("skin_temp")
        XCTAssertEqual(skin.display(0.5, units: imperial, unitLabel: "°C"), 0.9, accuracy: 1e-9, "a deviation has no +32")
        XCTAssertEqual(skin.display(34, units: imperial, unitLabel: "°C"), 93.2, accuracy: 1e-9)
    }

    func testCatalogUnitsNameVo2MaxAndSteps() throws {
        XCTAssertEqual(try XCTUnwrap(MetricCatalog.metric(key: "vo2max", source: "apple-health")).unit, "ml/kg/min")
        XCTAssertEqual(try XCTUnwrap(MetricCatalog.metric(key: "vo2max_est", source: "my-whoop")).unit, "ml/kg/min")
        XCTAssertEqual(try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "apple-health")).unit, "steps")
        XCTAssertNotEqual(try XCTUnwrap(MetricCatalog.metric(key: "restorative_pct", source: "my-whoop")).title,
                          try XCTUnwrap(MetricCatalog.metric(key: "restorative_min", source: "my-whoop")).title)
    }

    // MARK: Empty copy per source

    func testEmptyCopyNamesWhereTheDataComesFrom() throws {
        XCTAssertEqual(try presentation("hrv").emptyMessage, "No readings yet")
        XCTAssertEqual(try presentation("avg_hr").emptyMessage, "Comes from a WHOOP export")
        XCTAssertEqual(try presentation("weight", "apple-health").emptyMessage, "No Apple Health readings yet")
        XCTAssertEqual(try presentation("mood", "noop-mood").emptyMessage, "No check-ins yet")
        for metric in MetricCatalog.all where metric.source == "my-whoop" {
            XCTAssertFalse(MetricPresentation.of(metric).emptyMessage.contains("Import your history"), metric.id)
        }
    }

    // MARK: Statistics

    func testStatisticsOfAScoreCountDaysAtTheTopBand() throws {
        let p = try presentation("recovery")
        let input = MetricStatsInput(window: [("2026-10-01", 30), ("2026-10-02", 70), ("2026-10-03", 80)],
                                     previous: [50, 50], typical: nil, unit: "%")
        let items = MetricStats.items(p, input: input)
        XCTAssertEqual(items.map(\.label).first, "Average")
        XCTAssertEqual(items[0].value, "60")
        XCTAssertEqual(items[1].value, "30")
        XCTAssertEqual(items[2].value, "80")
        XCTAssertEqual(items[3].value, "2", "days at or above 67")
    }

    func testVsPreviousIsASignedDeltaNeverAPercent() throws {
        let p = try presentation("hrv")
        let item = MetricStats.item(for: .vsPrevious, p: p,
                                    input: MetricStatsInput(window: [("2026-10-01", 70), ("2026-10-02", 74)],
                                                            previous: [60, 64], typical: nil, unit: "ms"))
        XCTAssertEqual(item.value, "+10")
        XCTAssertEqual(item.unit, "ms")
        XCTAssertNotEqual(item.unit, "%")
    }

    func testWeeklyTotalsStartOnMonday() {
        let weeks = MetricStats.weeklyTotals([("2026-10-05", 30), ("2026-10-11", 20), ("2026-10-12", 10)])
        XCTAssertEqual(weeks.map(\.monday), ["2026-10-05", "2026-10-12"])
        XCTAssertEqual(weeks.map(\.total), [50, 10])
    }

    // MARK: Range bridge

    func testExploreRangeBridgesToTheSixChips() {
        for range in ChartRange.allCases {
            XCTAssertEqual(ExploreRange(range).chartRange, range)
        }
        XCTAssertNil(ExploreRange.twoWeeks.chartRange)
        XCTAssertNil(ExploreRange.threeWeeks.chartRange)
    }

    func testCoercionLimitedToChipsMatchesTheRangeControl() {
        // 15 days of history: M is locked, 2W is unlocked but has no chip, so the control shows W.
        let span = 15
        func unlocked(_ r: ExploreRange) -> Bool {
            switch r {
            case .week, .all: return true
            case .twoWeeks: return span > 7
            case .threeWeeks: return span > 14
            case .month: return span > 21
            default: return false
            }
        }
        let coerced = ExploreRangeGating.coerced(selection: .month, isUnlocked: { unlocked($0) && $0.chartRange != nil })
        XCTAssertEqual(coerced, .week)
        let visible = RangeControl.visibleOptions(ChartRange.allCases, isAvailable: { unlocked(ExploreRange($0)) })
        XCTAssertEqual(RangeControl.displayedSelection(.month, visible: visible), coerced.chartRange)
    }
}
