import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsMorningResponseTests — the 30-minute morning response (CONTRACT §4.3): known curves,
// separate per-signal coverage, missing sides, off-wrist, duplicates, the UTC-minute grid, and the
// producer → JSON → app-decoder round trip of the thermal + morning groups.
final class SleepAnalyticsMorningResponseTests: XCTestCase {

    /// HR 55 → 75 bpm, temperature (night cycle → post-wake ramp), movement 0 → 2 s/min across the
    /// anchor. Every value is hand-computed from the fixture definition.
    func testKnownCurvesAroundTheAnchor() throws {
        let f = PeriSleepFixture()
        let g = try XCTUnwrap(f.morning())
        XCTAssertEqual(g.anchorKind, "effective_window_end")
        XCTAssertEqual(g.anchorTs, f.fragEnd)
        XCTAssertEqual(g.anchorAt, SleepAnalyticsV1.isoUTC(f.fragEnd))
        XCTAssertEqual(g.windowBeforeSeconds, 1800)
        XCTAssertEqual(g.windowAfterSeconds, 1800)
        XCTAssertEqual(g.algorithmVersion, "morning-response-1")
        XCTAssertEqual(g.interpretation, "response_around_detected_boundary_not_awakening_physiology")
        XCTAssertEqual(g.quality.status, .available)

        for window in [g.heartRate, g.skinTemperature, g.movement] {
            XCTAssertEqual(window.points.map(\.offsetMinutes), Array(-30..<30), window.signal)
            XCTAssertEqual(window.eligibleMinutesEachSide, 30)
            XCTAssertEqual(window.beforeValidMinutes, 30, window.signal)
            XCTAssertEqual(window.afterValidMinutes, 30, window.signal)
            XCTAssertEqual(window.change.status, .available, window.signal)
        }
        XCTAssertEqual(g.heartRate.signal, "heart_rate")
        XCTAssertEqual(g.heartRate.unit, "bpm")
        XCTAssertEqual(g.heartRate.beforeMedian.value, 55)
        XCTAssertEqual(g.heartRate.afterMedian.value, 75)
        XCTAssertEqual(g.heartRate.change.value, 20)
        XCTAssertTrue(g.heartRate.points.allSatisfy { $0.support == 60 })

        XCTAssertEqual(g.skinTemperature.unit, "°C")
        // Before: night minutes 210…239 → 34.00 + 0.01·(k mod 7); 15th/16th order statistics 34.03.
        XCTAssertEqual(g.skinTemperature.beforeMedian.value ?? .nan, 34.03, accuracy: 1e-9)
        // After: 35.00 − 0.02·k for k = 0…29 → median at k = 14.5 → 34.71.
        XCTAssertEqual(g.skinTemperature.afterMedian.value ?? .nan, 34.71, accuracy: 1e-9)
        XCTAssertEqual(g.skinTemperature.change.value ?? .nan, 0.68, accuracy: 1e-9)

        XCTAssertEqual(g.movement.unit, "s/min")
        // A genuine zero with exposure before; two moving adjacencies per minute after (seconds 0, 10).
        XCTAssertEqual(g.movement.beforeMedian.value, 0)
        XCTAssertEqual(g.movement.beforeMedian.status, .available)
        XCTAssertEqual(g.movement.afterMedian.value, 2)
        XCTAssertEqual(g.movement.change.value, 2)
        XCTAssertTrue(g.movement.points.allSatisfy { $0.support == 60 })
    }

    /// No data after the anchor: each signal reports its own missing side; nothing is zero-filled.
    func testMissingAfterSideIsNullNotZero() throws {
        var f = PeriSleepFixture()
        f.tempRaw = { f, ts in ts < f.fragEnd ? PeriSleepFixture.defaultTemp(f, ts) : nil }
        f.gravityX = { f, ts in ts < f.fragEnd ? 0 : nil }
        let g = try XCTUnwrap(f.morning())
        // HR is still present after the anchor: its coverage is separate from the others.
        XCTAssertEqual(g.heartRate.change.status, .available)
        for window in [g.skinTemperature, g.movement] {
            XCTAssertEqual(window.afterValidMinutes, 0, window.signal)
            XCTAssertEqual(window.afterMedian.status, .unavailable, window.signal)
            XCTAssertEqual(window.afterMedian.reason, .noSamples, window.signal)
            XCTAssertNil(window.afterMedian.value, window.signal)
            XCTAssertEqual(window.change.reason, .insufficientCoverage, window.signal)
            XCTAssertNil(window.change.value, window.signal)
            XCTAssertTrue(window.points.filter { $0.offsetMinutes >= 0 }.allSatisfy { $0.value == nil && !$0.valid })
            XCTAssertEqual(window.beforeMedian.status, .available, window.signal)
        }
        XCTAssertEqual(g.quality.status, .partial)
    }

    /// The side gate: 19 valid minutes is partial with no change; 20 is enough.
    func testSideMinimumBoundary() throws {
        func hrWindow(afterMinutes: Int) throws -> SleepAnalyticsSignalWindow {
            var f = PeriSleepFixture()
            f.hrBpm = { f, ts in
                if ts < f.fragEnd { return 55 }
                return (ts - f.fragEnd) / 60 < afterMinutes ? 75 : nil
            }
            return try XCTUnwrap(f.morning()).heartRate
        }
        let thin = try hrWindow(afterMinutes: 19)
        XCTAssertEqual(thin.afterValidMinutes, 19)
        XCTAssertEqual(thin.afterMedian.status, .partial)
        XCTAssertEqual(thin.afterMedian.value, 75)
        XCTAssertEqual(thin.change.status, .unavailable)
        XCTAssertEqual(thin.change.reason, .insufficientCoverage)
        let enough = try hrWindow(afterMinutes: 20)
        XCTAssertEqual(enough.afterMedian.status, .available)
        XCTAssertEqual(enough.change.value, 20)
    }

    /// Explicit off-wrist time: HR seconds and temperature samples inside it are excluded, movement
    /// minutes that touch it are invalid, and the temperature equilibration window follows it.
    func testOffWristMinutesAreInvalid() throws {
        var f = PeriSleepFixture()
        f.offWrist = [SleepAnalyticsInterval(start: f.fragEnd + 300, end: f.fragEnd + 900)]   // minutes 5…14
        let g = try XCTUnwrap(f.morning())
        let offMinutes = Set(5..<15)
        for p in g.heartRate.points where offMinutes.contains(p.offsetMinutes) {
            XCTAssertFalse(p.valid); XCTAssertEqual(p.support, 0); XCTAssertNil(p.value)
        }
        for p in g.movement.points where offMinutes.contains(p.offsetMinutes) {
            XCTAssertFalse(p.valid); XCTAssertNil(p.value)
        }
        // Temperature: off-wrist minutes rejected, then 5 equilibration minutes (15…19) excluded even
        // though they carry 60 accepted seconds each.
        for p in g.skinTemperature.points where p.offsetMinutes >= 5 && p.offsetMinutes < 20 {
            XCTAssertFalse(p.valid, "minute \(p.offsetMinutes)")
        }
        XCTAssertEqual(g.skinTemperature.points.first { $0.offsetMinutes == 17 }?.support, 60)
        XCTAssertEqual(g.heartRate.afterValidMinutes, 20)
        XCTAssertEqual(g.movement.afterValidMinutes, 20)
        XCTAssertEqual(g.skinTemperature.afterValidMinutes, 15)
        XCTAssertEqual(g.skinTemperature.change.reason, .insufficientCoverage)
        XCTAssertEqual(g.heartRate.change.status, .available)
    }

    /// Duplicated HR and gravity rows never add support: 20 distinct seconds per minute stay invalid.
    func testDuplicatesDoNotInflateSupport() throws {
        let f = PeriSleepFixture()
        let base = f.input()
        let keep: (Int) -> Bool = { ts in ts < f.fragEnd || ((ts % 60) + 60) % 60 < 20 }
        let hr = base.hr.filter { keep($0.ts) }
        let gravity = base.gravity.filter { keep($0.ts) }
        let input = SleepAnalyticsInput(
            fragments: base.fragments, timezoneId: base.timezoneId,
            hr: hr + hr + hr, gravity: gravity + gravity, skinTemp: base.skinTemp, beats: [],
            deviceFamily: base.deviceFamily, offWristIntervals: base.offWristIntervals,
            stageSourceVersion: base.stageSourceVersion, inputRevision: base.inputRevision)
        let config = SleepAnalyticsConfig()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        let g = try XCTUnwrap(SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input, config: config))
        for p in g.heartRate.points where p.offsetMinutes >= 0 {
            XCTAssertEqual(p.support, 20); XCTAssertFalse(p.valid)
        }
        for p in g.movement.points where p.offsetMinutes >= 0 {
            XCTAssertLessThanOrEqual(p.support, 20); XCTAssertFalse(p.valid)
        }
        XCTAssertEqual(g.heartRate.afterValidMinutes, 0)
        XCTAssertGreaterThan(g.quality.streamCounts["hr_duplicate"] ?? 0, 0)
        XCTAssertGreaterThan(g.quality.streamCounts["gravity_duplicate"] ?? 0, 0)
    }

    /// An anchor off the minute grid: the points are still the 60 UTC minutes in the window, offsets
    /// −30…29 unique, and the straddling minute counts as "before".
    func testUnalignedAnchorUsesUtcMinutes() throws {
        let f = PeriSleepFixture()
        let base = f.input()
        let end = f.fragEnd + 30
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: base.fragments[0].id, start: f.fragStart, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: f.fragStart, end: f.onset, stage: "wake"),
                         StageSegment(start: f.onset, end: end, stage: "light")])],
            timezoneId: base.timezoneId, hr: base.hr, gravity: base.gravity, skinTemp: base.skinTemp,
            beats: [], deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let config = SleepAnalyticsConfig()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        let g = try XCTUnwrap(SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input, config: config))
        XCTAssertEqual(g.anchorTs, end)
        XCTAssertEqual(g.heartRate.points.map(\.offsetMinutes), Array(-30..<30))
        // The minute starting at fragEnd (30 s before the anchor) is offset −1: HR 75 there.
        XCTAssertEqual(g.heartRate.points.first { $0.offsetMinutes == -1 }?.value, 75)
    }

    /// No fragment → no group (the document omits the key).
    func testNoFragmentsNoGroup() {
        let input = SleepAnalyticsInput(fragments: [], timezoneId: "Etc/UTC", hr: [], gravity: [],
                                        skinTemp: [], beats: [], deviceFamily: .whoop5,
                                        stageSourceVersion: "s", inputRevision: 1)
        let config = SleepAnalyticsConfig()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        XCTAssertNil(SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input, config: config))
    }

    /// The document path builds the bins once and both groups read them: the morning temperature curve
    /// after the anchor is exactly the post-wake slope's minutes.
    func testMorningTemperatureCurveReusesThermalBins() throws {
        let f = PeriSleepFixture()
        let doc = SleepAnalyticsV1.compute(input: f.input(), config: SleepAnalyticsConfig())
        let morning = try XCTUnwrap(doc.morningResponse)
        let after = morning.skinTemperature.points.filter { $0.offsetMinutes >= 0 }
        XCTAssertEqual(after.filter(\.valid).count, doc.thermal.postWakeSlopeCPerHour?.validMinutes)
        for p in after {
            XCTAssertEqual(p.value ?? .nan, 35.00 - 0.02 * Double(p.offsetMinutes), accuracy: 1e-9)
        }
    }

    /// Thin post-wake temperature bins (20 distinct seconds, each sent three times) show their true
    /// support on the curve and stay invalid.
    func testDuplicatedThinTemperatureBinsStayInvalidOnTheCurve() throws {
        var f = PeriSleepFixture()
        f.tempCopies = 3
        f.tempRaw = { f, ts in
            if ts >= f.fragEnd, ts < f.fragEnd + 1800, ((ts % 60) + 60) % 60 >= 20 { return nil }
            return PeriSleepFixture.defaultTemp(f, ts)
        }
        let temp = try XCTUnwrap(f.morning()).skinTemperature
        XCTAssertTrue(temp.points.filter { $0.offsetMinutes >= 0 }.allSatisfy { $0.support == 20 && !$0.valid })
        XCTAssertEqual(temp.afterValidMinutes, 0)
    }

    /// Unix seconds throughout: the same night labelled Los Angeles across the DST fall-back gives the
    /// same morning group as when labelled UTC.
    func testMorningGroupIgnoresDst() {
        var la = PeriSleepFixture()
        la.t0 = 1_793_523_600 - 4 * 3600
        la.timezoneId = "America/Los_Angeles"
        var utc = la
        utc.timezoneId = "Etc/UTC"
        XCTAssertNotNil(la.morning())
        XCTAssertEqual(la.morning(), utc.morning())
    }

    func testMorningGatesEnterTheFingerprint() {
        var changed = SleepAnalyticsConfig()
        changed.morningMinValidMinutesPerSide = 25
        XCTAssertNotEqual(changed.gateFingerprint, SleepAnalyticsConfig().gateFingerprint)
        var hr = SleepAnalyticsConfig()
        hr.morningHrMinuteMinDistinctSeconds = 40
        XCTAssertNotEqual(hr.gateFingerprint, SleepAnalyticsConfig().gateFingerprint)
    }

    // MARK: - Producer → JSON → app decoder

    /// The exact path the published document takes: `JSONEncoder` (worker adapter) → JSON object
    /// (`snapshot.daily.sleep_analytics_v1`, stored and served verbatim) → `JSONSerialization` →
    /// `JSONDecoder` into the shared type (`ServerScoreRepository.sleepAnalytics(from:)`).
    func testThermalAndMorningSurviveTheWireRoundTrip() throws {
        let doc = SleepAnalyticsV1.compute(input: PeriSleepFixture().input(), config: .v2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let published = try JSONSerialization.jsonObject(with: encoder.encode(doc)) as! [String: Any]

        XCTAssertEqual(published["algorithm_version"] as? String, "nara-sleep-analytics-2")
        XCTAssertEqual(published["config_version"] as? String, "v2")
        let thermal = try XCTUnwrap(published["thermal"] as? [String: Any])
        let post = try XCTUnwrap(thermal["post_wake_slope_c_per_hour"] as? [String: Any])
        let postValue = try XCTUnwrap(post["value"] as? [String: Any])
        XCTAssertEqual(postValue["status"] as? String, "available")
        XCTAssertEqual(postValue["unit"] as? String, "°C/h")
        XCTAssertEqual((postValue["value"] as? Double) ?? .nan, -1.2, accuracy: 1e-9)
        let morning = try XCTUnwrap(published["morning_response"] as? [String: Any])
        XCTAssertEqual(morning["anchor_kind"] as? String, "effective_window_end")
        XCTAssertEqual(morning["interpretation"] as? String,
                       "response_around_detected_boundary_not_awakening_physiology")
        let hr = try XCTUnwrap(morning["heart_rate"] as? [String: Any])
        let points = try XCTUnwrap(hr["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 60)
        XCTAssertEqual(points.first?["offset_min"] as? Int, -30)
        XCTAssertNotNil(hr["before_median"]); XCTAssertNotNil(hr["eligible_minutes_each_side"])
        XCTAssertTrue(SleepAnalyticsMorningResponseTests.isFinite(published))

        let data = try JSONSerialization.data(withJSONObject: published)
        let decoded = try JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
        XCTAssertEqual(decoded.thermal, doc.thermal)
        XCTAssertEqual(decoded.morningResponse, doc.morningResponse)
        XCTAssertEqual(decoded.algorithmVersion, doc.algorithmVersion)
    }

    /// A malformed morning group withholds only itself: the rest of the document still decodes.
    func testMalformedMorningGroupDoesNotDropTheDocument() throws {
        let doc = SleepAnalyticsV1.compute(input: PeriSleepFixture().input(), config: .v2)
        var published = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as! [String: Any]
        published["morning_response"] = ["anchor_kind": 7, "bogus": true]
        let decoded = try JSONDecoder().decode(SleepAnalyticsDocument.self,
                                               from: JSONSerialization.data(withJSONObject: published))
        XCTAssertNil(decoded.morningResponse)
        XCTAssertEqual(decoded.thermal, doc.thermal)
        // An older document without the key decodes with nil (old producers stay readable).
        published.removeValue(forKey: "morning_response")
        let old = try JSONDecoder().decode(SleepAnalyticsDocument.self,
                                           from: JSONSerialization.data(withJSONObject: published))
        XCTAssertNil(old.morningResponse)
    }

    static func isFinite(_ value: Any) -> Bool {
        if let n = value as? NSNumber { return n.doubleValue.isFinite }
        if let d = value as? [String: Any] { return d.values.allSatisfy(isFinite) }
        if let a = value as? [Any] { return a.allSatisfy(isFinite) }
        return true
    }
}
