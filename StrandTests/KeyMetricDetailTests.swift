import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The simplified key-metric screen's pure rules: which metrics route to it, where each one's values come from,
/// which night or day the headline shows, how the history chart windows and breaks its line, the night and day
/// wording, and the wording guard on the explanation.
final class KeyMetricDetailTests: XCTestCase {

    typealias H = KeyMetricHistory
    typealias F = MetricInsightFixtures
    typealias V = KeyMetricValues

    private func date(_ day: String) -> Date { PhysiologyContextDates.date(day)! }

    private func row(_ day: String, hrv: Double? = nil, sdnn: Double? = nil, skinC: Double? = nil,
                     skinDev: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skinDev, avgSdnn: sdnn, skinTempC: skinC)
    }

    // MARK: - Routing catalog

    func testRestingHeartRateFromTheStrapRoutesToTheKeyMetricScreen() throws {
        let rhr = try XCTUnwrap(MetricCatalog.metric(key: "rhr", source: "my-whoop"))
        let entry = try XCTUnwrap(KeyMetricCatalog.entry(for: rhr))
        XCTAssertEqual(entry.metrics, [.restingHeartRate])
        XCTAssertEqual(entry.metrics.map(\.rawValue), ["resting_hr"])
        // The bare-key route (`TabRoute.metric("rhr")`, Today's tile) resolves to the same descriptor.
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "rhr" }?.id, rhr.id)
    }

    /// Each contract metric opens from the strap's own descriptor, with the id the explanation is asked for by.
    func testEveryContractMetricRoutesFromTheStrapsDescriptor() throws {
        let expected: [(key: String, metrics: [String])] = [
            ("rhr", ["resting_hr"]), ("hrv", ["hrv_rmssd", "hrv_sdnn"]), ("skin_temp", ["skin_temp"]),
            ("resp_rate", ["resp_rate"]), ("spo2", ["spo2"]), ("stable_awake_hr", ["heart_rate"]),
            ("steps", ["steps"]), ("energy_kcal", ["calories"]),
        ]
        for (key, metrics) in expected {
            let descriptor = try XCTUnwrap(MetricCatalog.metric(key: key, source: "my-whoop"), key)
            let entry = try XCTUnwrap(KeyMetricCatalog.entry(for: descriptor), key)
            XCTAssertEqual(entry.metrics.map(\.rawValue), metrics, key)
        }
        XCTAssertEqual(KeyMetricCatalog.entries.count, expected.count)
    }

    /// One HRV screen: RMSSD first (the side shown on arrival), SDNN beside it, each asking for its own explanation.
    func testHRVIsOneScreenWithAnRMSSDAndAnSDNNSide() throws {
        let hrv = try XCTUnwrap(MetricCatalog.metric(key: "hrv", source: "my-whoop"))
        let entry = try XCTUnwrap(KeyMetricCatalog.entry(for: hrv))
        XCTAssertEqual(entry.metrics, [.hrvRmssd, .hrvSdnn])
        XCTAssertEqual(entry.metrics.map(\.rawValue), ["hrv_rmssd", "hrv_sdnn"])
        XCTAssertEqual(entry.metrics.map(\.switchLabel), ["RMSSD", "SDNN"])
        XCTAssertEqual(entry.title, "Heart rate variability")
        XCTAssertEqual(KeyMetricSeries.explore, MetricInsightMetric.hrvRmssd.series, "RMSSD is the Explore HRV series")
        XCTAssertEqual(MetricInsightMetric.hrvSdnn.series, .sdnn)
        XCTAssertTrue(entry.metrics.allSatisfy { $0.period == .night && $0.measurement == .measured })
    }

    func testImportedAndOtherSourcesKeepTheirDossiers() throws {
        let routed = MetricCatalog.all.filter { KeyMetricCatalog.entry(for: $0) != nil }.map(\.id)
        XCTAssertEqual(routed, ["my-whoop:stable_awake_hr", "my-whoop:energy_kcal", "my-whoop:hrv", "my-whoop:rhr",
                                "my-whoop:resp_rate", "my-whoop:spo2", "my-whoop:skin_temp", "my-whoop:steps"])
        // Another source's reading is different data from what the server explains, and so are the WHOOP 4.0 motion
        // estimate and the fused 30-day steps view.
        for (key, source) in [("rhr", "xiaomi-band"), ("spo2", "xiaomi-band"), ("energy_kcal", "xiaomi-band"),
                              ("steps", "apple-health"), ("steps", "xiaomi-band"), ("active_kcal", "apple-health"),
                              ("steps_est", "my-whoop"), ("steps", MetricCatalog.combinedStepsSource)] {
            let descriptor = try XCTUnwrap(MetricCatalog.metric(key: key, source: source), "\(source):\(key)")
            XCTAssertNil(KeyMetricCatalog.entry(for: descriptor), "\(source):\(key)")
        }
    }

    func testEveryServerMetricHasACatalogEntry() {
        XCTAssertEqual(Set(KeyMetricCatalog.entries.flatMap(\.metrics)), Set(MetricInsightMetric.allCases))
        XCTAssertEqual(KeyMetricCatalog.entries.flatMap(\.metrics).count, MetricInsightMetric.allCases.count,
                       "each metric opens from exactly one screen")
        XCTAssertEqual(Set(MetricInsightMetric.allCases.map(\.rawValue)),
                       ["resting_hr", "hrv_rmssd", "hrv_sdnn", "skin_temp", "resp_rate", "spo2", "heart_rate", "steps",
                        "calories"])
        for entry in KeyMetricCatalog.entries {
            XCTAssertNotNil(MetricCatalog.metric(key: entry.catalogKey, source: entry.source), entry.catalogKey)
            XCTAssertFalse(entry.metrics.isEmpty, entry.catalogKey)
        }
    }

    /// The contract's period, title and measured-or-estimated column, metric by metric.
    func testEachMetricFollowsTheContractsPeriodTitleAndLabel() {
        let table: [(MetricInsightMetric, MetricInsightPeriod, String, String?)] = [
            (.restingHeartRate, .night, "Resting heart rate", nil),
            (.hrvRmssd, .night, "Heart rate variability", nil),
            (.hrvSdnn, .night, "Heart rate variability", nil),
            (.skinTemp, .night, "Wrist temperature", nil),
            (.respRate, .night, "Respiratory rate", "Estimated"),
            (.spo2, .night, "Blood oxygen", "Estimated, unverified"),
            (.heartRate, .day, "Stable awake heart rate", nil),
            (.steps, .day, "Steps", "Estimated"),
            (.calories, .day, "Calories", "Estimated"),
        ]
        XCTAssertEqual(table.count, MetricInsightMetric.allCases.count)
        for (metric, period, title, label) in table {
            XCTAssertEqual(metric.period, period, metric.rawValue)
            XCTAssertEqual(metric.title, title, metric.rawValue)
            XCTAssertEqual(metric.measurement.label, label, metric.rawValue)
        }
        let skin = MetricCatalog.metric(key: "skin_temp", source: "my-whoop")!
        XCTAssertEqual(KeyMetricCatalog.entry(for: skin)?.title, "Wrist temperature", "the screen's title, not the row's")
    }

    /// The new Explore row: a heart metric from the strap whose values only the server holds.
    func testStableAwakeHeartRateIsAnExploreRowReadFromTheContextHistory() throws {
        let stable = try XCTUnwrap(MetricCatalog.all.first { $0.key == "stable_awake_hr" })
        XCTAssertEqual(stable.source, "my-whoop")
        XCTAssertEqual(stable.category, "Heart")
        XCTAssertEqual(stable.unit, "bpm")
        XCTAssertEqual(MetricCatalog.all.filter { $0.key == "stable_awake_hr" }.count, 1)
        XCTAssertEqual(KeyMetricCatalog.entry(for: stable)?.metrics, [.heartRate])
        XCTAssertEqual(MetricInsightMetric.heartRate.series, .contextHistory(seriesKey: "heart_rate.stable_awake_5min"))
        XCTAssertEqual(MetricInsightMetric.heartRate.measurement, .measured)
        // The Explore list cannot probe it, so it never shows the "no data" dot; every other row can.
        XCTAssertFalse(KeyMetricCatalog.hasLocalSeries(stable))
        XCTAssertTrue(MetricCatalog.all.filter { $0.id != stable.id }.allSatisfy(KeyMetricCatalog.hasLocalSeries))
        // The route serves 120 days a read, so the chips stop at 3M.
        XCTAssertEqual(MetricInsightMetric.heartRate.historyDays, 120)
        XCTAssertEqual(H.ranges(historyDays: MetricInsightMetric.heartRate.historyDays), [.week, .month, .quarter, .all])
        XCTAssertEqual(H.ranges(historyDays: MetricInsightMetric.steps.historyDays), H.ranges)
        XCTAssertFalse(H.isUnlocked(.half, spanDays: 119, hasHistory: true, among: [.week, .month, .quarter, .all]))
        XCTAssertTrue(H.isUnlocked(.quarter, spanDays: 119, hasHistory: true, among: [.week, .month, .quarter, .all]))
    }

    // MARK: - Value sources

    /// The wrist temperature screen is the temperature: never the baseline deviation `exploreSeries` returns.
    func testWristTemperatureIsTheAbsoluteNeverTheDeviation() {
        XCTAssertEqual(MetricInsightMetric.skinTemp.series, .absoluteSkinTemp)
        let days = [
            row("2026-10-01", skinC: 33.6, skinDev: 0.2),    // strap night: absolute and deviation
            row("2026-10-02", skinDev: -0.4),                // scored before skinTempC shipped: deviation only
            row("2026-10-03", skinDev: 34.1),                // a WHOOP CSV import: an absolute in the deviation column
            row("2026-10-04", skinC: 33.9),                  // calibrating: absolute only
            row("2026-10-05"),
        ]
        let series = V.absoluteSkinTemp(days)
        XCTAssertEqual(series.map(\.day), ["2026-10-01", "2026-10-03", "2026-10-04"])
        XCTAssertEqual(series.map(\.value), [33.6, 34.1, 33.9])
        XCTAssertTrue(series.allSatisfy { VitalBands.isAbsoluteSkinTemp($0.value) }, "no deviation leaks in")
    }

    func testSDNNComesFromTheNightlySDNNIndexNotRMSSD() {
        let days = [row("2026-10-02", hrv: 48, sdnn: 71), row("2026-10-01", hrv: 52, sdnn: 66),
                    row("2026-10-03", hrv: 50), row("2026-10-04", sdnn: 0)]
        let series = V.sdnn(days)
        XCTAssertEqual(series.map(\.day), ["2026-10-01", "2026-10-02", "2026-10-04"], "ascending, SDNN nights only")
        XCTAssertEqual(series.map(\.value), [66, 71, 0])
        XCTAssertEqual(H.measured(series, for: .hrvSdnn, today: "2026-10-07").map(\.value), [66, 71],
                       "a zero SDNN is a placeholder")
    }

    func testBloodOxygenFillsOnlyTheNightsItLacksFromTheCandidate() {
        XCTAssertEqual(MetricInsightMetric.spo2.series, .spo2WithCandidate)
        let filled = V.filling([("2026-10-02", 96), ("2026-10-04", 97)],
                               from: [("2026-10-01", 94), ("2026-10-02", 91), ("2026-10-03", 95)])
        XCTAssertEqual(filled.map(\.day), ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
        XCTAssertEqual(filled.map(\.value), [94, 96, 95, 97], "a calibrated night is never replaced by the candidate")
        XCTAssertEqual(V.filling([], from: []).count, 0)
    }

    /// Zero steps on a worn day is a real 0; for every other metric zero is a placeholder.
    func testStepsKeepARealZeroDayAndOtherMetricsDropIt() {
        let series: [(day: String, value: Double)] = [("2026-10-01", 8123), ("2026-10-02", 0), ("2026-10-03", -5),
                                                      ("2026-10-04", .nan), ("2026-10-05", 4200)]
        XCTAssertTrue(MetricInsightMetric.steps.keepsZero)
        XCTAssertEqual(MetricInsightMetric.steps.series, .resolved, "the Steps page's own read, not exploreSeries")
        XCTAssertEqual(H.measured(series, for: .steps, today: "2026-10-07").map(\.day),
                       ["2026-10-01", "2026-10-02", "2026-10-05"])
        XCTAssertEqual(H.measured(series, for: .steps, today: "2026-10-07")[1].value, 0)
        XCTAssertEqual(H.runs(H.measured(series, for: .steps, today: "2026-10-07")).map(\.count), [2, 1],
                       "the zero day joins the line; the unmeasured days break it")
        for metric in MetricInsightMetric.allCases where metric != .steps {
            XCTAssertFalse(metric.keepsZero, metric.rawValue)
            XCTAssertEqual(H.measured(series, for: metric, today: "2026-10-07").map(\.day), ["2026-10-01", "2026-10-05"],
                           metric.rawValue)
        }
    }

    /// A day metric's headline is the latest COMPLETE local day; a night metric keeps last night, which is keyed by
    /// the day it ends (today).
    func testADayMetricShowsTheLatestCompleteDayNeverToday() throws {
        let series: [(day: String, value: Double)] = [("2026-10-05", 7100), ("2026-10-06", 9400), ("2026-10-07", 1200),
                                                      ("2026-10-08", 300)]
        for metric in [MetricInsightMetric.steps, .calories, .heartRate] {
            let shown = H.measured(series, for: metric, today: "2026-10-07")
            let latest = try XCTUnwrap(shown.last, metric.rawValue)
            XCTAssertEqual(latest.day, "2026-10-06", "\(metric.rawValue): today is still running")
            XCTAssertEqual(latest.value, 9400)
            XCTAssertEqual(shown.map(\.day), ["2026-10-05", "2026-10-06"], "the chart ends there too")
        }
        let nights = Array(series.prefix(3))
        for metric in [MetricInsightMetric.restingHeartRate, .hrvRmssd, .hrvSdnn, .skinTemp, .respRate, .spo2] {
            XCTAssertEqual(H.measured(nights, for: metric, today: "2026-10-07").last?.day, "2026-10-07",
                           "\(metric.rawValue): last night ends today")
        }
        XCTAssertEqual(H.latestMeasured(series, before: "2026-10-07")?.day, "2026-10-06")
        XCTAssertNil(H.latestMeasured([("2026-10-07", 500)], before: "2026-10-07"), "only today: nothing complete yet")
    }

    // MARK: - Stable awake heart rate (context history)

    private func dv(_ day: String, _ value: Double, series: String = V.stableAwakeHeartRateSeries,
                    mode: PhysiologyContext.ProcessingMode = .retrospective, regime: String = "r1",
                    support: Int = 4, seconds: Int = 1200) -> PhysiologyContext.DailyValue {
        PhysiologyContext.DailyValue(day: day, seriesKey: series, regimeKey: regime, metric: .heartRate, value: value,
                                     units: "bpm", supportCount: support, supportUnit: "window", supportS: seconds,
                                     mode: mode, finality: .final)
    }

    func testStableAwakeHeartRateIsOneValuePerDayPreferringTheRetrospective() {
        let values = [
            dv("2026-10-04", 61, mode: .causalLive), dv("2026-10-04", 63),                  // both modes: retrospective
            dv("2026-10-05", 66, mode: .causalLive),                                         // live only
            dv("2026-10-03", 70, support: 2), dv("2026-10-03", 64, regime: "r2", support: 6), // two regimes: most support
            dv("2026-10-02", 58, series: "heart_rate.stable_awake_5min.band_06_12"),          // a time-band stratum
            dv("2026-10-02", 49, series: "hrv_rmssd.stable_awake_5min"),                       // another metric
            dv("2026-10-01", 0), dv("2026-10-06", .nan),                                        // not readings
        ]
        let series = V.contextDaily(values, seriesKey: V.stableAwakeHeartRateSeries)
        XCTAssertEqual(series.map(\.day), ["2026-10-03", "2026-10-04", "2026-10-05"])
        XCTAssertEqual(series.map(\.value), [64, 63, 66])
        // Order-independent, and a tie in mode and support goes to the first regime key, whatever the input order.
        XCTAssertEqual(V.contextDaily(values.reversed(), seriesKey: V.stableAwakeHeartRateSeries).map(\.value), [64, 63, 66])
        let tie = [dv("2026-10-04", 70, regime: "r9"), dv("2026-10-04", 60, regime: "r1")]
        XCTAssertEqual(V.contextDaily(tie, seriesKey: V.stableAwakeHeartRateSeries).map(\.value), [60])
        XCTAssertEqual(V.contextDaily(tie.reversed(), seriesKey: V.stableAwakeHeartRateSeries).map(\.value), [60])
        XCTAssertTrue(V.contextDaily([], seriesKey: V.stableAwakeHeartRateSeries).isEmpty, "no context: the empty state")
    }

    /// One retrospective read over the route's longest range and one live read of the last week, both ending at the
    /// latest complete day.
    func testTheContextReadsCoverTheRoutesRangeAndTheLastWeekLive() {
        let reads = V.contextReads(through: "2026-10-06")
        XCTAssertEqual(reads, [V.ContextRead(from: "2026-06-09", to: "2026-10-06", mode: .retrospective),
                               V.ContextRead(from: "2026-09-30", to: "2026-10-06", mode: .causalLive)])
        XCTAssertEqual(PhysiologyContextDates.inclusiveDays(from: reads[0].from, to: reads[0].to),
                       PhysiologyContextRepository.maxHistoryDays, "the route's longest range, never refused")
        XCTAssertEqual(PhysiologyContextDates.inclusiveDays(from: reads[1].from, to: reads[1].to), V.liveContextDays)
    }

    // MARK: - Format

    private func formatter(_ metric: MetricInsightMetric, key: String, temperature: TemperatureUnit = .celsius,
                           locale: String = "en_US") -> KeyMetricFormatter {
        KeyMetricFormatter(metric: metric, descriptor: MetricCatalog.metric(key: key, source: "my-whoop")!,
                           system: .metric, temperature: temperature, locale: Locale(identifier: locale))
    }

    func testStepsAndCaloriesReadWithAThousandsSeparator() {
        let steps = formatter(.steps, key: "steps")
        XCTAssertEqual(steps.text(8123), "8,123 steps")
        XCTAssertEqual(steps.text(0), "0 steps")
        XCTAssertEqual(steps.parts(8123).number, "8,123")
        XCTAssertEqual(steps.parts(8123).unit, "steps")
        let kcal = formatter(.calories, key: "energy_kcal")
        XCTAssertEqual(kcal.text(2350.4), "2,350 kcal")
        XCTAssertEqual(kcal.parts(2350).number, "2,350")
        XCTAssertEqual(kcal.parts(2350).unit, "kcal")
        XCTAssertEqual(formatter(.calories, key: "energy_kcal", locale: "de_DE").parts(2350).number, "2.350",
                       "the app language's grouping")
    }

    func testTheVitalsReadInTheirOwnUnits() {
        XCTAssertEqual(formatter(.restingHeartRate, key: "rhr").text(52), "52 bpm")
        XCTAssertEqual(formatter(.hrvSdnn, key: "hrv").text(71.4), "71 ms", "SDNN reads in the HRV descriptor's ms")
        XCTAssertEqual(formatter(.respRate, key: "resp_rate").text(15.24), "15.2 rpm")
        XCTAssertEqual(formatter(.spo2, key: "spo2").text(96), "96 %")
        XCTAssertEqual(formatter(.heartRate, key: "stable_awake_hr").parts(64).number, "64")
        XCTAssertEqual(formatter(.heartRate, key: "stable_awake_hr").parts(64).unit, "bpm")
    }

    /// The absolute wrist temperature follows the reader's °C / °F choice, on the headline and on the chart's axis.
    func testWristTemperatureFollowsTheTemperatureUnitOnTheAxisToo() {
        let celsius = formatter(.skinTemp, key: "skin_temp")
        XCTAssertEqual(celsius.text(34.2), "34.2 °C")
        XCTAssertEqual(celsius.parts(34.2).number, "34.2")
        XCTAssertEqual(celsius.parts(34.2).unit, "°C")
        XCTAssertEqual(celsius.plotted(34.2), 34.2)
        let fahrenheit = formatter(.skinTemp, key: "skin_temp", temperature: .fahrenheit)
        XCTAssertEqual(fahrenheit.text(34.2), "93.6 °F")
        XCTAssertEqual(fahrenheit.parts(34.2).unit, "°F")
        XCTAssertEqual(fahrenheit.plotted(34.2), 93.56, accuracy: 1e-9)
        XCTAssertEqual(formatter(.restingHeartRate, key: "rhr", temperature: .fahrenheit).plotted(52), 52,
                       "only a temperature is converted")
    }

    /// Narrow-range signals keep a fitted axis instead of a line squashed by a bpm-sized pad.
    func testNarrowRangeSignalsGetAFittedAxis() throws {
        let temperature = try XCTUnwrap(H.valueDomain([33.4, 33.6, 34.0], minimumPad: MetricInsightMetric.skinTemp.minimumPad))
        XCTAssertEqual(temperature.lowerBound, 33.1, accuracy: 1e-9)
        XCTAssertEqual(temperature.upperBound, 34.3, accuracy: 1e-9)
        let oxygen = try XCTUnwrap(H.valueDomain([93, 96, 98], minimumPad: MetricInsightMetric.spo2.minimumPad))
        XCTAssertEqual(oxygen.lowerBound, 92, accuracy: 1e-9)
        XCTAssertEqual(oxygen.upperBound, 99, accuracy: 1e-9)
        let breathing = try XCTUnwrap(H.valueDomain([14.8, 15.2], minimumPad: MetricInsightMetric.respRate.minimumPad))
        XCTAssertEqual(breathing.upperBound - breathing.lowerBound, 1.4, accuracy: 1e-9)
        // Steps sit on a zero floor, never below it.
        let steps = try XCTUnwrap(H.valueDomain([0, 8123, 12000], minimumPad: MetricInsightMetric.steps.minimumPad))
        XCTAssertEqual(steps.lowerBound, 0)
        XCTAssertEqual(steps.upperBound, 13800, accuracy: 1e-9)
        for metric in MetricInsightMetric.allCases { XCTAssertGreaterThan(metric.minimumPad, 0, metric.rawValue) }
    }

    // MARK: - Night and day wording

    func testNightMetricsSpeakOfNightsAndDayMetricsOfFullDays() {
        XCTAssertEqual(KeyMetricCopy.latest(.night), "Latest measured night")
        XCTAssertEqual(KeyMetricCopy.latest(.day), "Latest full day")
        XCTAssertEqual(KeyMetricCopy.measured(5, of: 7, .night), "5 of 7 nights measured")
        XCTAssertEqual(KeyMetricCopy.measured(1, of: 30, .night), "1 of 30 nights measured")
        XCTAssertEqual(KeyMetricCopy.measured(5, of: 7, .day), "5 of 7 days measured")
        XCTAssertEqual(KeyMetricCopy.measured(1, of: 30, .day), "1 of 30 days measured")
        XCTAssertEqual(KeyMetricCopy.axis(.night), "Night")
        XCTAssertEqual(KeyMetricCopy.axis(.day), "Day")
        XCTAssertEqual(KeyMetricCopy.noneYet(.day), "No measured days yet")
        XCTAssertEqual(KeyMetricCopy.nothingToChart(.night), "No measured nights to chart yet.")
        // The first half is the night copy, the second the day copy; neither borrows the other's word.
        let all = KeyMetricCopy.allPeriodText
        XCTAssertFalse(all.prefix(all.count / 2).contains { $0.lowercased().contains("day") }, "\(all)")
        XCTAssertFalse(all.suffix(all.count / 2).contains { $0.lowercased().contains("night") }, "\(all)")
        XCTAssertEqual(all.count, Set(all).count, "every string is distinct")
    }

    // MARK: - Headline value

    func testTheHeadlineIsTheLatestMeasuredNight() throws {
        let series: [(day: String, value: Double)] = [
            ("2026-10-01", 54), ("2026-10-02", 53), ("2026-10-04", 55),
            ("2026-10-05", 0), ("2026-10-06", .nan), ("2026-10-07", -3), ("2026-10-08", .infinity),
        ]
        let latest = try XCTUnwrap(H.latestMeasured(series))
        XCTAssertEqual(latest.day, "2026-10-04", "zero, negative and non-finite nights are missing, not measured")
        XCTAssertEqual(latest.value, 55)
        XCTAssertEqual(latest.date, date("2026-10-04"))
    }

    func testTheHeadlineIgnoresInputOrderAndDuplicateDays() throws {
        let series: [(day: String, value: Double)] = [("2026-10-06", 52), ("2026-09-30", 58), ("2026-10-06", 99),
                                                      ("not-a-day", 50)]
        XCTAssertEqual(H.latestMeasured(series)?.value, 52, "the first reading of a day is kept")
        XCTAssertEqual(H.measured(series).map(\.day), ["2026-09-30", "2026-10-06"])
    }

    func testThereIsNoHeadlineWhenNothingWasMeasured() {
        XCTAssertNil(H.latestMeasured([]))
        XCTAssertNil(H.latestMeasured([("2026-10-01", 0), ("2026-10-02", .nan), ("2026-10-03", -1)]))
    }

    // MARK: - Chart gaps

    func testMissingNightsSplitTheLineAndNothingIsPlottedAtZero() {
        let nights = H.measured([
            ("2026-10-01", 54), ("2026-10-02", 53), ("2026-10-03", 0),     // the 3rd is missing
            ("2026-10-04", 55), ("2026-10-05", 56),
            ("2026-10-08", 52),                                           // 6th and 7th never arrived
            ("2026-10-10", .nan), ("2026-10-11", 51),
        ])
        let runs = H.runs(nights)
        XCTAssertEqual(runs.map { $0.map(\.day) }, [
            ["2026-10-01", "2026-10-02"],
            ["2026-10-04", "2026-10-05"],
            ["2026-10-08"],
            ["2026-10-11"],
        ])
        XCTAssertFalse(runs.joined().contains { $0.value <= 0 || !$0.value.isFinite }, "no zero or placeholder point")
        XCTAssertEqual(runs.joined().count, nights.count, "every measured night is drawn exactly once")
    }

    func testConsecutiveNightsAreOneLine() {
        let nights = H.measured((1...9).map { (day: "2026-10-0\($0)", value: 50 + Double($0)) })
        XCTAssertEqual(H.runs(nights).count, 1)
        // Across a month and a year boundary too.
        let boundary = H.measured([("2025-12-31", 50), ("2026-01-01", 51), ("2026-01-31", 52),
                                         ("2026-02-01", 53)])
        XCTAssertEqual(H.runs(boundary).map(\.count), [2, 2])
        XCTAssertTrue(H.runs([]).isEmpty)
    }

    // MARK: - Windows

    func testAFiniteRangeEndsAtTheLatestMeasuredNight() throws {
        let nights = H.measured([("2026-08-01", 60), ("2026-09-20", 55), ("2026-10-01", 54),
                                       ("2026-10-06", 52)])
        let week = try XCTUnwrap(H.domain(nights, range: .week))
        XCTAssertEqual(week.lowerBound, date("2026-09-30"))
        XCTAssertEqual(week.upperBound, date("2026-10-06"))
        XCTAssertEqual(H.dayCount(week), 7)
        XCTAssertEqual(H.window(nights, domain: week).map(\.day), ["2026-10-01", "2026-10-06"])

        let month = try XCTUnwrap(H.domain(nights, range: .month))
        XCTAssertEqual(H.dayCount(month), 30)
        XCTAssertEqual(H.window(nights, domain: month).map(\.day), ["2026-09-20", "2026-10-01", "2026-10-06"])

        let all = try XCTUnwrap(H.domain(nights, range: .all))
        XCTAssertEqual(all.lowerBound, date("2026-08-01"))
        XCTAssertEqual(all.upperBound, date("2026-10-06"))
        XCTAssertEqual(H.window(nights, domain: all).count, 4)
    }

    func testASingleNightStillHasAnAxisAndNoHistoryHasNoWindow() throws {
        let one = H.measured([("2026-10-06", 52)])
        let all = try XCTUnwrap(H.domain(one, range: .all))
        XCTAssertEqual(H.dayCount(all), 7)
        XCTAssertEqual(H.window(one, domain: all).map(\.day), ["2026-10-06"])
        XCTAssertNil(H.domain([], range: .month))
        XCTAssertTrue(H.window([], domain: nil).isEmpty)
    }

    func testLongerRangesUnlockAsHistoryBuilds() {
        func unlocked(_ span: Int) -> [ExploreRange] {
            H.ranges.filter { H.isUnlocked($0, spanDays: span, hasHistory: true) }
        }
        XCTAssertEqual(unlocked(3), [.week, .all])
        XCTAssertEqual(unlocked(8), [.week, .month, .all])
        XCTAssertEqual(unlocked(31), [.week, .month, .quarter, .all])
        XCTAssertEqual(unlocked(91), [.week, .month, .quarter, .half, .all])
        XCTAssertEqual(unlocked(400), H.ranges)
        XCTAssertEqual(H.ranges.filter { H.isUnlocked($0, spanDays: 0, hasHistory: false) }, H.ranges,
                       "nothing locks before there is history")
        XCTAssertFalse(H.isUnlocked(.twoWeeks, spanDays: 400, hasHistory: true), "not one of this screen's chips")
        // A locked default renders as the largest unlocked chip below it.
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .month,
                                                  isUnlocked: { H.isUnlocked($0, spanDays: 3, hasHistory: true) }),
                       .week)
        XCTAssertEqual(ExploreRangeGating.coerced(selection: .year,
                                                  isUnlocked: { H.isUnlocked($0, spanDays: 40, hasHistory: true) }),
                       .quarter)
        XCTAssertEqual(H.spanDays(H.measured([("2026-10-01", 50), ("2026-10-11", 51)])), 10)
    }

    func testTheValueAxisFitsTheReadingsAndNeverStartsAtZeroForThem() throws {
        let fitted = try XCTUnwrap(H.valueDomain([50, 80]))
        XCTAssertEqual(fitted.lowerBound, 45.5, accuracy: 1e-9, "15% of the span either side")
        XCTAssertEqual(fitted.upperBound, 84.5, accuracy: 1e-9)
        let narrow = try XCTUnwrap(H.valueDomain([50, 60]))
        XCTAssertEqual(narrow.lowerBound, 47, accuracy: 1e-9, "at least 3 either side")
        XCTAssertEqual(narrow.upperBound, 63, accuracy: 1e-9)
        let flat = try XCTUnwrap(H.valueDomain([52, 52]))
        XCTAssertEqual(flat.lowerBound, 49)
        XCTAssertEqual(flat.upperBound, 55)
        XCTAssertNil(H.valueDomain([]))
    }

    func testTheHeadlineNumberAndUnitSplit() {
        XCTAssertEqual(H.splitUnit("52 bpm", unit: "bpm").number, "52")
        XCTAssertEqual(H.splitUnit("52 bpm", unit: "bpm").unit, "bpm")
        XCTAssertEqual(H.splitUnit("52", unit: "").number, "52")
        XCTAssertNil(H.splitUnit("52", unit: "").unit)
        XCTAssertEqual(H.splitUnit("52 ms", unit: "bpm").number, "52 ms", "a mismatched unit is left whole")
        XCTAssertNil(H.splitUnit(" bpm", unit: "bpm").unit)
    }

    // MARK: - Wording guard

    func testTheWordingGuardRejectsAForbiddenTermInAnyField() throws {
        let clean = try XCTUnwrap(MetricInsight.decode(F.insight()))
        XCTAssertNil(clean.wordingViolation)
        XCTAssertNotNil(MetricInsightStore.renderable(clean))

        let cases: [(String, [String: Any])] = [
            ("headline", F.insight(headline: "Stress may be raising your resting heart rate")),
            ("observed", F.insight(observed: ["Your heart rate rose during the illness."])),
            ("interpretation", F.insight(interpretation: ["This often follows a stressful week."])),
            ("uncertainty", F.insight(uncertainty: ["We cannot rule out a fever."])),
            ("related label", F.insight(related: [["label": "Mood", "summary": "logged 3 of 5"]])),
            ("related summary", F.insight(related: [["label": "HRV", "summary": "lower while sick"]])),
            ("citation title", F.insight(citations: [["title": "Resting heart rate and anxiety", "year": 2019]])),
        ]
        for (field, insight) in cases {
            let decoded = try XCTUnwrap(MetricInsight.decode(insight), field)
            XCTAssertNotNil(decoded.wordingViolation, field)
            XCTAssertNil(MetricInsightStore.renderable(decoded), field)
        }
        XCTAssertEqual(MetricInsight.decode(F.insight(headline: "STRESS shows here"))?.wordingViolation,
                       .forbiddenTerm("stress"), "case-insensitive")
    }

    func testTheWordingGuardMatchesWholeWordsOnly() throws {
        let insight = try XCTUnwrap(MetricInsight.decode(F.insight(
            headline: "Resting heart rate is still near your usual range",
            observed: ["Distressing nothing: the illustration below shows the trend."])))
        XCTAssertNil(insight.wordingViolation, "'still' is not 'ill', 'distressing' and 'illustration' are not terms")
    }

    // MARK: - Wording guard hardening

    typealias G = MetricInsightWordingGuard

    /// The term a string trips, when it trips one.
    private func term(_ text: String) -> String? {
        if case .forbiddenTerm(let term)? = G.violation(in: text) { return term }
        return nil
    }

    func testTheGuardNormalisesWithNFKCAndLowercaseBeforeMatching() {
        XCTAssertEqual(G.normalized("ＲＥＳＴ\u{00A0}Hr"), "rest hr")
        XCTAssertEqual(term("Ｓｔｒｅｓｓ shows here"), "stress", "fullwidth letters fold to ASCII")
        XCTAssertEqual(term("A SIDE\u{00A0}EFFECT of the week"), "side effect", "a no-break space folds to a space")
        XCTAssertEqual(term("a ﬁlled fever chart"), "fever", "a ligature folds and the term is still found")
        XCTAssertEqual(term("Possible side-effects"), "side effect", "a hyphen may join the words of a term")
    }

    func testTheGuardCatchesSimpleInflections() {
        XCTAssertEqual(term("Two illnesses this month"), "illness")
        XCTAssertEqual(term("The week stresses your heart"), "stress")
        XCTAssertEqual(term("Possible side effects"), "side effect")
        XCTAssertEqual(term("Recent infections"), "infection")
        XCTAssertEqual(term("We cannot diagnose this"), "diagnose")
        XCTAssertNotNil(term("Nobody diagnoses from one night"))
        XCTAssertEqual(term("Diagnosing needs a clinician"), "diagnosing")
        for text in ["Stressing over sleep", "Moods vary", "Fevers can do this", "Calming down helps", "Tiredness shows",
                     "Fully recovered", "Drug effects can last"] {
            XCTAssertNotNil(term(text), text)
        }
        XCTAssertEqual(G.extraForms, ["diagnose", "diagnoses", "diagnosing", "infections"])
        XCTAssertEqual(G.inflections, ["s", "es", "ed", "ing", "ness", "nesses"])
    }

    func testAnInvisibleFormCharacterRejectsTheInsightOutright() throws {
        let formCharacters: [(String, UInt32)] = [("zero-width space", 0x200B), ("zero-width joiner", 0x200D),
                                                  ("soft hyphen", 0x00AD), ("word joiner", 0x2060),
                                                  ("left-to-right mark", 0x200E)]
        for (name, value) in formCharacters {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            XCTAssertEqual(G.violation(in: "Your resting heart\(Character(scalar)) rate is steady."),
                           .invisibleCharacter(value), name)
        }
        XCTAssertEqual(G.violation(in: "st\u{200B}ress"), .invisibleCharacter(0x200B),
                       "a term split by a zero-width space is rejected, not read as two clean words")
        let hidden = try XCTUnwrap(MetricInsight.decode(F.insight(uncertainty: ["Two nights\u{200D} were not measured."])))
        XCTAssertEqual(hidden.wordingViolation, .invisibleCharacter(0x200D))
        XCTAssertNil(MetricInsightStore.renderable(hidden))
    }

    func testAWordMixingLatinWithCyrillicOrGreekRejectsTheInsight() throws {
        XCTAssertEqual(G.violation(in: "Your str\u{0435}ss is high"), .mixedScriptWord("str\u{0435}ss"),
                       "a Cyrillic е inside a Latin word")
        XCTAssertEqual(G.violation(in: "A m\u{03BF}od change"), .mixedScriptWord("m\u{03BF}od"), "a Greek ο")
        XCTAssertEqual(G.violation(in: "R\u{0435}sting heart rate"), .mixedScriptWord("r\u{0435}sting"),
                       "rejected even when the word itself is not a term")
        XCTAssertNil(G.violation(in: "Пульс в покое"), "a word in one script is not mixed")
        XCTAssertNil(G.violation(in: "Ruhepuls σταθερός"), "words of different scripts side by side are fine")
        let spoofed = try XCTUnwrap(MetricInsight.decode(F.insight(related: [["label": "HRV",
                                                                             "summary": "lower aft\u{0435}r a long day"]])))
        XCTAssertEqual(spoofed.wordingViolation, .mixedScriptWord("aft\u{0435}r"))
        XCTAssertNil(MetricInsightStore.renderable(spoofed))
    }

    func testACleanInsightStillPassesTheHardenedGuard() throws {
        XCTAssertNil(try XCTUnwrap(MetricInsight.decode(F.insight())).wordingViolation)
        for text in ["Resting heart rate is still near your usual range",
                     "Recovery of your usual range took two nights",
                     "The illustration below shows the trend; nothing distressing",
                     "Night-to-night variation, 6.3 h of estimated sleep, VO₂ max about 44",
                     "52 bpm · café · 30-night median"] {
            XCTAssertNil(G.violation(in: text), text)
        }
        XCTAssertNil(term("still"), "'still' is not 'ill'")
        XCTAssertNil(term("recovery"), "'recovery' is not 'recovered'")
    }

    /// The section labels read plainly for patients, and the card carries no medical-advice line (that rule lives in
    /// the model prompt). The AI attribution stays.
    func testTheCardReadsPlainlyAndCarriesNoAdviceLine() {
        XCTAssertEqual(MetricInsightCopy.observed, "What we noticed")
        XCTAssertEqual(MetricInsightCopy.interpretation, "What may be behind it")
        XCTAssertEqual(MetricInsightCopy.uncertainty, "What we can't tell yet")
        XCTAssertEqual(MetricInsightCopy.writtenBy(.night), "Written by AI from your measured nights.")
        XCTAssertEqual(MetricInsightCopy.writtenBy(.day), "Written by AI from your measured days.")
        XCTAssertFalse(MetricInsightCopy.allFixedText.contains { $0.localizedCaseInsensitiveContains("medical advice") },
                       "\(MetricInsightCopy.allFixedText)")
        XCTAssertEqual(MetricInsightCopy.allFixedText.count, Set(MetricInsightCopy.allFixedText).count,
                       "every fixed string is distinct")
    }

    /// The card's lines with no explanation to read a period from speak of the screen metric's period.
    func testTheCardsWaitingLinesFollowThePeriod() {
        XCTAssertEqual(MetricInsightCopy.preparing(.night), "Looking at your recent nights…")
        XCTAssertEqual(MetricInsightCopy.preparing(.day), "Looking at your recent days…")
        XCTAssertEqual(MetricInsightCopy.notEnoughData(.night), "Not enough measured nights yet")
        XCTAssertEqual(MetricInsightCopy.notEnoughData(.day), "Not enough measured days yet")
        XCTAssertEqual(MetricInsightCopy.signedOut(.day), "Sign in to see an explanation of your recent days.")
        for period in MetricInsightPeriod.allCases {
            let other = period == .night ? "day" : "night"
            for text in [MetricInsightCopy.preparing(period), MetricInsightCopy.notEnoughData(period),
                         MetricInsightCopy.signedOut(period), MetricInsightCopy.writtenBy(period)] {
                XCTAssertFalse(text.lowercased().contains(other), text)
            }
        }
    }

    func testTheCardsOwnCopyPassesTheWordingGuard() {
        // The screen's own words too: its titles, the period copy and the estimate labels sit right above the
        // explanation (and the server writes about the same metrics by the same names).
        let screen = KeyMetricCopy.allPeriodText + MetricInsightMetric.allCases.compactMap(\.measurement.label)
            + MetricInsightMetric.allCases.flatMap { [$0.title, $0.switchLabel] }
            + KeyMetricCatalog.entries.compactMap { MetricCatalog.metric(key: $0.catalogKey, source: $0.source)?.title }
        for text in MetricInsightCopy.allFixedText + screen {
            XCTAssertNil(PhysiologyContextWording.containsForbiddenTerm(text), text)
            XCTAssertNil(MetricInsightWordingGuard.violation(in: text), text)
            XCTAssertFalse(text.isEmpty)
        }
        let lines = MetricInsightCopy.footerLines(F.cleanInsight(), locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(lines.count, 2)
        for line in lines { XCTAssertNil(PhysiologyContextWording.containsForbiddenTerm(line), line) }
    }

    /// Two lines: what the explanation covered (with the year), then when it was written (without the year), in the
    /// reader's locale and time zone.
    func testTheFooterSaysWhatTheExplanationCoveredAndWhenItWasWritten() throws {
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let insight = F.cleanInsight()   // basis 28 nights, data through 2026-10-06, generated 2026-10-07T02:43:31Z
        let lines = MetricInsightCopy.footerLines(insight, locale: us, timeZone: utc)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(lines.first, "Based on 28 nights through Oct 6, 2026")
        let generated = try XCTUnwrap(lines.last)
        XCTAssertTrue(generated.hasPrefix("Generated Oct 7, 2:43"), generated)
        XCTAssertFalse(generated.contains("2026"), "the generated time carries no year: \(generated)")
        XCTAssertFalse(lines.joined().contains(" · "), "no joined single line any more")

        let british = try XCTUnwrap(MetricInsightCopy.generated(insight, locale: gb, timeZone: utc))
        XCTAssertTrue(british.hasPrefix("Generated 7 Oct, "), british)
        // The locale's own 24-hour clock (zero padding varies with the OS's locale data), never an AM/PM marker.
        let britishTime = british.components(separatedBy: ", ").last ?? ""
        XCTAssertTrue(["2:43", "02:43"].contains(britishTime), "24-hour clock where the locale uses one: \(british)")
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertTrue(MetricInsightCopy.generated(insight, locale: us, timeZone: pacific)?
            .hasPrefix("Generated Oct 6, 7:43") == true, "the reader's own time zone")

        let bare = try XCTUnwrap(MetricInsight.decode(["headline": "Only 2 nights measured so far"]))
        XCTAssertEqual(MetricInsightCopy.footerLines(bare, locale: gb), [])

        let oneNight = try XCTUnwrap(MetricInsight.decode(F.insight(basis: ["nights": 1])))
        XCTAssertTrue(MetricInsightCopy.basis(oneNight, locale: gb)?.hasPrefix("Based on 1 night through ") == true)

        // A day metric's explanation counts days (the basis keeps its shape: `nights` holds the count).
        let days = try XCTUnwrap(MetricInsight.decode(F.insight(extra: ["period": "day", "metric": "steps"])))
        XCTAssertEqual(MetricInsightCopy.basis(days, locale: us), "Based on 28 days through Oct 6, 2026")
        let oneDay = try XCTUnwrap(MetricInsight.decode(F.insight(basis: ["nights": 1], extra: ["period": "day"])))
        XCTAssertTrue(MetricInsightCopy.basis(oneDay, locale: gb)?.hasPrefix("Based on 1 day through ") == true)
        let undatedDays = try XCTUnwrap(MetricInsight.decode(F.insight(basis: ["nights": 9],
                                                                       extra: ["period": "day",
                                                                               "data_through": NSNull()])))
        XCTAssertEqual(MetricInsightCopy.basis(undatedDays, locale: us), "Based on 9 days")
        let undated = try XCTUnwrap(MetricInsight.decode(F.insight(extra: ["data_through": NSNull(),
                                                                           "generated_at": NSNull()])))
        XCTAssertEqual(MetricInsightCopy.footerLines(undated, locale: us), ["Based on 28 nights through Oct 6, 2026"],
                       "basis.to stands in for data_through; an unreadable time drops its line")

        XCTAssertEqual(MetricInsightCopy.citation(.init(id: nil, title: "A study", year: 2020, url: nil)),
                       "A study (2020)")
        XCTAssertEqual(MetricInsightCopy.citation(.init(id: nil, title: "A study", year: nil, url: nil)), "A study")
    }
}
