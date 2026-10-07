import XCTest
@testable import Strand

/// The simplified key-metric screen's pure rules: which metrics route to it, which night the headline shows, how
/// the history chart windows and breaks its line, and the wording guard on the explanation.
final class KeyMetricDetailTests: XCTestCase {

    typealias H = KeyMetricHistory
    typealias F = MetricInsightFixtures

    private func date(_ day: String) -> Date { PhysiologyContextDates.date(day)! }

    // MARK: - Routing catalog

    func testRestingHeartRateFromTheStrapRoutesToTheKeyMetricScreen() throws {
        let rhr = try XCTUnwrap(MetricCatalog.metric(key: "rhr", source: "my-whoop"))
        let entry = try XCTUnwrap(KeyMetricCatalog.entry(for: rhr))
        XCTAssertEqual(entry.insightMetric, .restingHeartRate)
        XCTAssertEqual(entry.insightMetric.rawValue, "resting_hr")
        // The bare-key route (`TabRoute.metric("rhr")`, Today's tile) resolves to the same descriptor.
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "rhr" }?.id, rhr.id)
    }

    /// Follows the flag, so turning HRV on stays the one-line change in `KeyMetricCatalog`.
    func testHRVIsMappedAndRoutesOnlyWhenEnabled() throws {
        let hrv = try XCTUnwrap(MetricCatalog.metric(key: "hrv", source: "my-whoop"))
        let mapped = try XCTUnwrap(KeyMetricCatalog.entries.first { $0.catalogKey == "hrv" })
        XCTAssertEqual(mapped.insightMetric.rawValue, "hrv_rmssd")
        XCTAssertEqual(mapped.enabled, KeyMetricCatalog.hrvEnabled)
        if KeyMetricCatalog.hrvEnabled {
            XCTAssertEqual(KeyMetricCatalog.entry(for: hrv)?.insightMetric, .hrvRmssd)
        } else {
            XCTAssertNil(KeyMetricCatalog.entry(for: hrv), "HRV keeps the full dossier while hrvEnabled is false")
        }
    }

    func testEveryOtherMetricKeepsTheDossier() throws {
        let routed = MetricCatalog.all.filter { KeyMetricCatalog.entry(for: $0) != nil }.map(\.id)
        XCTAssertEqual(routed, ["my-whoop:hrv"].filter { _ in KeyMetricCatalog.hrvEnabled } + ["my-whoop:rhr"])
        // Another source's resting HR is different data from what the server explains.
        let miBand = try XCTUnwrap(MetricCatalog.metric(key: "rhr", source: "xiaomi-band"))
        XCTAssertNil(KeyMetricCatalog.entry(for: miBand))
    }

    func testEveryServerMetricHasACatalogEntry() {
        XCTAssertEqual(Set(KeyMetricCatalog.entries.map(\.insightMetric)), Set(MetricInsightMetric.allCases))
        XCTAssertEqual(Set(MetricInsightMetric.allCases.map(\.rawValue)), ["resting_hr", "hrv_rmssd"])
        for entry in KeyMetricCatalog.entries {
            XCTAssertNotNil(MetricCatalog.metric(key: entry.catalogKey, source: entry.source), entry.catalogKey)
        }
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
        XCTAssertEqual(H.measuredNights(series).map(\.day), ["2026-09-30", "2026-10-06"])
    }

    func testThereIsNoHeadlineWhenNothingWasMeasured() {
        XCTAssertNil(H.latestMeasured([]))
        XCTAssertNil(H.latestMeasured([("2026-10-01", 0), ("2026-10-02", .nan), ("2026-10-03", -1)]))
    }

    // MARK: - Chart gaps

    func testMissingNightsSplitTheLineAndNothingIsPlottedAtZero() {
        let nights = H.measuredNights([
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
        let nights = H.measuredNights((1...9).map { (day: "2026-10-0\($0)", value: 50 + Double($0)) })
        XCTAssertEqual(H.runs(nights).count, 1)
        // Across a month and a year boundary too.
        let boundary = H.measuredNights([("2025-12-31", 50), ("2026-01-01", 51), ("2026-01-31", 52),
                                         ("2026-02-01", 53)])
        XCTAssertEqual(H.runs(boundary).map(\.count), [2, 2])
        XCTAssertTrue(H.runs([]).isEmpty)
    }

    // MARK: - Windows

    func testAFiniteRangeEndsAtTheLatestMeasuredNight() throws {
        let nights = H.measuredNights([("2026-08-01", 60), ("2026-09-20", 55), ("2026-10-01", 54),
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
        let one = H.measuredNights([("2026-10-06", 52)])
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
        XCTAssertEqual(H.spanDays(H.measuredNights([("2026-10-01", 50), ("2026-10-11", 51)])), 10)
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
        XCTAssertNil(clean.forbiddenTerm)
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
            XCTAssertNotNil(decoded.forbiddenTerm, field)
            XCTAssertNil(MetricInsightStore.renderable(decoded), field)
        }
        XCTAssertEqual(MetricInsight.decode(F.insight(headline: "STRESS shows here"))?.forbiddenTerm, "stress",
                       "case-insensitive")
    }

    func testTheWordingGuardMatchesWholeWordsOnly() throws {
        let insight = try XCTUnwrap(MetricInsight.decode(F.insight(
            headline: "Resting heart rate is still near your usual range",
            observed: ["Distressing nothing: the illustration below shows the trend."])))
        XCTAssertNil(insight.forbiddenTerm, "'still' is not 'ill', 'distressing' and 'illustration' are not terms")
    }

    func testTheCardsOwnCopyPassesTheWordingGuard() {
        for text in MetricInsightCopy.allFixedText {
            XCTAssertNil(PhysiologyContextWording.containsForbiddenTerm(text), text)
            XCTAssertFalse(text.isEmpty)
        }
        let footer = MetricInsightCopy.footer(F.cleanInsight(), locale: Locale(identifier: "en_GB"))
        XCTAssertNotNil(footer)
        XCTAssertNil(footer.flatMap(PhysiologyContextWording.containsForbiddenTerm))
    }

    func testTheFooterSaysWhatTheExplanationCovered() throws {
        let gb = Locale(identifier: "en_GB")
        let full = try XCTUnwrap(MetricInsightCopy.footer(F.cleanInsight(), locale: gb))
        XCTAssertTrue(full.hasPrefix("Based on 28 nights through "), full)
        XCTAssertTrue(full.contains("2026"), full)
        XCTAssertTrue(full.contains(" · Generated "), full)

        let bare = try XCTUnwrap(MetricInsight.decode(["headline": "Only 2 nights measured so far"]))
        XCTAssertNil(MetricInsightCopy.footer(bare, locale: gb))

        let oneNight = try XCTUnwrap(MetricInsight.decode(F.insight(basis: ["nights": 1])))
        XCTAssertTrue(MetricInsightCopy.footer(oneNight, locale: gb)?.hasPrefix("Based on 1 night through ") == true)

        XCTAssertEqual(MetricInsightCopy.citation(.init(id: nil, title: "A study", year: 2020, url: nil)),
                       "A study (2020)")
        XCTAssertEqual(MetricInsightCopy.citation(.init(id: nil, title: "A study", year: nil, url: nil)), "A study")
    }
}
