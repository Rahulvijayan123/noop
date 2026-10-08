import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsThermalRepairTests — spec-02 §3 / CONTRACT §4.2 acceptance for the thermal repair:
// every qualified UTC-minute bin is built ONCE over the peri-sleep analysis span; the nightly
// summary uses the in-fragment subset (unchanged by post-wake observations); the pre-onset slope
// uses [onset − 60 min, onset) — including minutes BEFORE the first fragment — and the post-wake
// slope uses [window end, window end + 30 min). Before the repair the post-wake slope could never
// be computed (its minutes were filtered out with the out-of-fragment ones) and the pre-onset
// window was clipped to the fragment.

/// A deterministic peri-sleep fixture: 1 Hz HR, skin temperature and gravity from `t0` (= onset − 60
/// min) through `dataEnd`; one fragment `[onset − 10 min, onset + 4 h)` staged wake (10 min) then
/// light, so the onset prefix is observed. Every stream is a closure over the absolute second, so a
/// test can thin, drop, duplicate or reshape any part of it.
struct PeriSleepFixture {
    var t0: Int = 1_789_000_000 - 1_789_000_000 % 60
    var onset: Int { t0 + 3600 }
    var fragStart: Int { onset - 600 }
    var fragEnd: Int { onset + 4 * 3600 }
    var dataEnd: Int { fragEnd + 2400 }
    var timezoneId = "Etc/UTC"
    var offWrist: [SleepAnalyticsInterval] = []
    /// Copies of every temperature sample (duplicates must never inflate support).
    var tempCopies = 1
    var tempRaw: ((PeriSleepFixture, Int) -> Int?) = PeriSleepFixture.defaultTemp
    var hrBpm: ((PeriSleepFixture, Int) -> Int?) = { f, ts in ts < f.fragEnd ? 55 : 75 }
    var gravityX: ((PeriSleepFixture, Int) -> Double?) = { f, ts in
        ts < f.fragEnd ? 0 : ((((ts % 60) + 60) % 60) < 10 ? 0.05 : 0)
    }

    /// Pre-onset ramp +0.01 °C/min (0.6 °C/h), a night that cycles 34.00…34.06 °C, a post-wake ramp of
    /// −0.02 °C/min (−1.2 °C/h), then a flat 34.40 °C.
    static func defaultTemp(_ f: PeriSleepFixture, _ ts: Int) -> Int? {
        if ts < f.onset { return 3300 + (ts - f.t0) / 60 }
        if ts < f.fragEnd { return 3400 + ((ts - f.onset) / 60) % 7 }
        if ts < f.fragEnd + 1800 { return 3500 - 2 * ((ts - f.fragEnd) / 60) }
        return 3440
    }

    func input() -> SleepAnalyticsInput {
        var hr: [HRSample] = [], temp: [SkinTempSample] = [], gravity: [GravitySample] = []
        for ts in t0..<dataEnd {
            if let bpm = hrBpm(self, ts) { hr.append(HRSample(ts: ts, bpm: bpm)) }
            if let raw = tempRaw(self, ts) {
                for _ in 0..<tempCopies { temp.append(SkinTempSample(ts: ts, raw: raw)) }
            }
            if let x = gravityX(self, ts) { gravity.append(GravitySample(ts: ts, x: x, y: 0, z: 1)) }
        }
        return SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(fragStart)", start: fragStart, end: fragEnd,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: fragStart, end: onset, stage: "wake"),
                         StageSegment(start: onset, end: fragEnd, stage: "light")])],
            timezoneId: timezoneId, hr: hr, gravity: gravity, skinTemp: temp, beats: [],
            deviceFamily: .whoop5, offWristIntervals: offWrist,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 3)
    }

    func thermal(_ config: SleepAnalyticsConfig = SleepAnalyticsConfig()) -> SleepAnalyticsThermalGroup {
        let input = input()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        return SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: config)
    }

    func morning(_ config: SleepAnalyticsConfig = SleepAnalyticsConfig()) -> SleepAnalyticsMorningResponseGroup? {
        let input = input()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        return SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input, config: config)
    }
}

final class SleepAnalyticsThermalRepairTests: XCTestCase {

    /// The in-fragment minute medians are 10 pre-onset minutes (33.50…33.59 °C) plus 240 night minutes
    /// cycling 34.00…34.06 °C (34.00 and 34.01 ×35, the rest ×34); the 125th/126th order statistics
    /// are both 34.03 °C.
    private let expectedNightMedian = 34.03

    func testCompletePrePostFixtureYieldsBothSlopesWithAnalyticValues() throws {
        let f = PeriSleepFixture()
        let g = f.thermal()
        let pre = try XCTUnwrap(g.preOnsetSlopeCPerHour)
        XCTAssertEqual(pre.value.status, .available)
        XCTAssertEqual(pre.value.unit, "°C/h")
        XCTAssertEqual(pre.value.value ?? .nan, 0.6, accuracy: 1e-9)
        // 50 of these 60 minutes lie BEFORE the first fragment: the repair stops clipping them.
        XCTAssertEqual(pre.validMinutes, 60)
        XCTAssertEqual(pre.windowStart, f.onset - 3600)
        XCTAssertEqual(pre.windowEnd, f.onset)
        XCTAssertEqual(pre.longestMissingRunSeconds, 0)

        let post = try XCTUnwrap(g.postWakeSlopeCPerHour)
        XCTAssertEqual(post.value.status, .available, "the post-wake slope is computable after the repair")
        XCTAssertEqual(post.value.value ?? .nan, -1.2, accuracy: 1e-9)
        XCTAssertEqual(post.windowStart, f.fragEnd)
        XCTAssertEqual(post.windowEnd, f.fragEnd + 1800)
        XCTAssertEqual(post.validMinutes, 30)
        XCTAssertEqual(post.eligibleMinutes, 30)
        XCTAssertEqual(post.coverage ?? -1, 1.0, accuracy: 1e-12)

        XCTAssertEqual(g.nightMedianC.status, .available)
        XCTAssertEqual(g.nightMedianC.value ?? .nan, expectedNightMedian, accuracy: 1e-9)
        XCTAssertEqual(g.quality.streamCounts["temp_valid_minutes"], 250)
        XCTAssertEqual(g.quality.streamCounts["temp_eligible_minutes"], 250)
    }

    /// The nightly summary is identical with no post-wake temperature, with the fixture's post-wake
    /// ramp, and with wildly different post-wake values.
    func testNightlySummaryUnchangedByPostWakeObservations() {
        var without = PeriSleepFixture()
        without.tempRaw = { f, ts in ts < f.fragEnd ? PeriSleepFixture.defaultTemp(f, ts) : nil }
        var hot = PeriSleepFixture()
        hot.tempRaw = { f, ts in ts < f.fragEnd ? PeriSleepFixture.defaultTemp(f, ts) : 4100 }
        let reference = PeriSleepFixture().thermal()
        for variant in [without.thermal(), hot.thermal()] {
            XCTAssertEqual(variant.nightMedianC, reference.nightMedianC)
            XCTAssertEqual(variant.nightIqrC, reference.nightIqrC)
            XCTAssertEqual(variant.nightP95MinusP05C, reference.nightP95MinusP05C)
            XCTAssertEqual(variant.preOnsetSlopeCPerHour, reference.preOnsetSlopeCPerHour)
            XCTAssertEqual(variant.quality.streamCounts["temp_valid_minutes"],
                           reference.quality.streamCounts["temp_valid_minutes"])
            XCTAssertEqual(variant.quality.status, reference.quality.status)
        }
        XCTAssertEqual(without.thermal().postWakeSlopeCPerHour?.value.reason, .insufficientCoverage)
        XCTAssertEqual(hot.thermal().postWakeSlopeCPerHour?.value.value ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(reference.nightMedianC.value ?? .nan, expectedNightMedian, accuracy: 1e-9)
    }

    /// Thin bins (29 distinct seconds) are missing, never interpolated.
    func testThinPostWakeBinsAreMissing() {
        var f = PeriSleepFixture()
        f.tempRaw = { f, ts in
            if ts >= f.fragEnd, ts < f.fragEnd + 1800, ((ts % 60) + 60) % 60 >= 29 { return nil }
            return PeriSleepFixture.defaultTemp(f, ts)
        }
        let post = f.thermal().postWakeSlopeCPerHour
        XCTAssertEqual(post?.validMinutes, 0)
        XCTAssertEqual(post?.value.status, .unavailable)
        XCTAssertEqual(post?.value.reason, .insufficientCoverage)
        XCTAssertNil(post?.value.value)
    }

    /// A 5-minute hole passes the missing-run gate; a 6-minute hole fails it (`insufficient_duration`)
    /// even though ≥ 20 of 30 minutes stay valid.
    func testPostWakeMissingRunBoundary() {
        func slope(hole: Int) -> SleepAnalyticsSlope? {
            var f = PeriSleepFixture()
            f.tempRaw = { f, ts in
                let k = (ts - f.fragEnd) / 60
                if ts >= f.fragEnd, k >= 10, k < 10 + hole { return nil }
                return PeriSleepFixture.defaultTemp(f, ts)
            }
            return f.thermal().postWakeSlopeCPerHour
        }
        let five = slope(hole: 5)
        XCTAssertEqual(five?.validMinutes, 25)
        XCTAssertEqual(five?.longestMissingRunSeconds, 300)
        XCTAssertEqual(five?.value.status, .available)
        XCTAssertEqual(five?.value.value ?? .nan, -1.2, accuracy: 1e-9)
        let six = slope(hole: 6)
        XCTAssertEqual(six?.validMinutes, 24)
        XCTAssertEqual(six?.longestMissingRunSeconds, 360)
        XCTAssertEqual(six?.value.reason, .insufficientDuration)
        // 19 valid minutes (an 11-minute hole) fails coverage first.
        XCTAssertEqual(slope(hole: 11)?.value.reason, .insufficientCoverage)
    }

    /// An off-wrist minute in the post-wake window rejects its samples, and the 5-minute equilibration
    /// after the re-wear removes the next five minutes from the slope — the nightly summary is unchanged.
    func testRewearInPostWakeWindowIsExcluded() {
        var f = PeriSleepFixture()
        f.offWrist = [SleepAnalyticsInterval(start: f.fragEnd + 600, end: f.fragEnd + 660)]
        let g = f.thermal()
        XCTAssertTrue(g.rewearEventVerified)
        XCTAssertEqual(g.equilibrationExcludedMinutes, 5)
        XCTAssertEqual(g.quality.streamCounts["temp_off_wrist_rejected"], 60)
        let post = g.postWakeSlopeCPerHour
        XCTAssertEqual(post?.validMinutes, 24)
        XCTAssertEqual(post?.longestMissingRunSeconds, 360)
        XCTAssertEqual(post?.value.reason, .insufficientDuration)
        XCTAssertEqual(g.nightMedianC, PeriSleepFixture().thermal().nightMedianC)
    }

    /// A re-wear just BEFORE the analysis span still excludes the part of its equilibration window that
    /// overlaps the span (here the first three pre-onset minutes).
    func testRewearJustBeforeSpanExcludesOverlap() {
        var f = PeriSleepFixture()
        f.offWrist = [SleepAnalyticsInterval(start: f.t0 - 600, end: f.t0 - 120)]
        let g = f.thermal()
        XCTAssertTrue(g.rewearEventVerified)
        XCTAssertEqual(g.equilibrationExcludedMinutes, 3)
        XCTAssertEqual(g.preOnsetSlopeCPerHour?.validMinutes, 57)
        XCTAssertEqual(g.preOnsetSlopeCPerHour?.longestMissingRunSeconds, 180)
        XCTAssertEqual(g.preOnsetSlopeCPerHour?.value.value ?? .nan, 0.6, accuracy: 1e-9)
    }

    /// Duplicated samples never inflate a bin: 20 distinct seconds sent three times stay a thin bin.
    func testDuplicatesDoNotInflatePostWakeCoverage() {
        var f = PeriSleepFixture()
        f.tempCopies = 3
        f.tempRaw = { f, ts in
            if ts >= f.fragEnd, ts < f.fragEnd + 1800, ((ts % 60) + 60) % 60 >= 20 { return nil }
            return PeriSleepFixture.defaultTemp(f, ts)
        }
        let g = f.thermal()
        XCTAssertEqual(g.postWakeSlopeCPerHour?.validMinutes, 0)
        XCTAssertEqual(g.postWakeSlopeCPerHour?.value.reason, .insufficientCoverage)
        XCTAssertGreaterThan(g.quality.streamCounts["temp_duplicate"] ?? 0, 0)
        XCTAssertEqual(g.nightMedianC.value ?? .nan, expectedNightMedian, accuracy: 1e-9)
    }

    /// Unix-second arithmetic: a night spanning the 2026-11-01 Los Angeles DST fall-back produces the
    /// same thermal group as the same night labelled UTC, with the analytic slopes.
    func testDstTransitionIsIrrelevant() {
        var la = PeriSleepFixture()
        la.t0 = 1_793_523_600 - 4 * 3600          // 2026-11-01T05:00Z; fall-back at 09:00Z
        la.timezoneId = "America/Los_Angeles"
        var utc = la
        utc.timezoneId = "Etc/UTC"
        let a = la.thermal(), b = utc.thermal()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.preOnsetSlopeCPerHour?.value.value ?? .nan, 0.6, accuracy: 1e-9)
        XCTAssertEqual(a.postWakeSlopeCPerHour?.value.value ?? .nan, -1.2, accuracy: 1e-9)
    }

    func testVersionsBumpedForTheMeaningChange() {
        XCTAssertEqual(SleepAnalyticsV1.algorithmVersion, "nara-sleep-analytics-2")
        XCTAssertEqual(SleepAnalyticsConfig().version, "v2")
        XCTAssertEqual(SleepAnalyticsConfig.v2.version, "v2")
        let doc = SleepAnalyticsV1.compute(input: PeriSleepFixture().input())
        XCTAssertEqual(doc.algorithmVersion, "nara-sleep-analytics-2")
        XCTAssertEqual(doc.configVersion, "v2")
        XCTAssertTrue(SleepAnalyticsConfig().gateFingerprint.hasPrefix("v2|"))
    }
}
