import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Pure, DB-free tests for the F11 adapter fixes in DayScoring.swift:
/// calendar day bounds (DST), dataThrough derivation, the typed-status rule,
/// and the device-family mapping. These exercise `DayScorer`'s static pure
/// helpers — the same functions the DB-facing `scoreAndBuildPayloads` calls.
final class DayScoringAdapterTests: XCTestCase {

    // MARK: - Calendar day bounds (DST 23h/25h)

    func testDayStartParsesLocalMidnightInTimeZone() {
        let ny = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 00:00 EST = 2026-03-08 05:00 UTC (spring-forward day).
        XCTAssertEqual(DayScorer.dayStartUnix("2026-03-08", tz: ny), 1_772_946_000)
        // 2026-11-01 00:00 EDT = 2026-11-01 04:00 UTC (fall-back day).
        XCTAssertEqual(DayScorer.dayStartUnix("2026-11-01", tz: ny), 1_793_505_600)
    }

    func testDayStartRejectsMalformedDay() {
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(DayScorer.dayStartUnix("not-a-date", tz: ny))
        XCTAssertNil(DayScorer.dayStartUnix("2026-13-40", tz: ny))
    }

    func testNextDayStartUsesCalendarArithmeticAcrossDST() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: DST springs forward at 02:00 local → the day is 23 h.
        let spring = try XCTUnwrap(DayScorer.dayStartUnix("2026-03-08", tz: ny))
        let springNext = DayScorer.nextDayStartUnix(after: spring, tz: ny)
        XCTAssertEqual(springNext - spring, 23 * 3_600, "spring-forward day must be 23 h")

        // 2026-11-01: DST falls back at 02:00 local → the day is 25 h.
        let fall = try XCTUnwrap(DayScorer.dayStartUnix("2026-11-01", tz: ny))
        let fallNext = DayScorer.nextDayStartUnix(after: fall, tz: ny)
        XCTAssertEqual(fallNext - fall, 25 * 3_600, "fall-back day must be 25 h")

        // A normal day is exactly 24 h.
        let normal = try XCTUnwrap(DayScorer.dayStartUnix("2026-06-15", tz: ny))
        let normalNext = DayScorer.nextDayStartUnix(after: normal, tz: ny)
        XCTAssertEqual(normalNext - normal, 24 * 3_600)
    }

    func testDayEndEqualsNextCalendarDayStart() throws {
        // Regression guard: dayEnd must be the next LOCAL midnight, not
        // dayStart + 86400 (F11/2).
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = try XCTUnwrap(DayScorer.dayStartUnix("2026-03-08", tz: ny))
        XCTAssertNotEqual(DayScorer.nextDayStartUnix(after: spring, tz: ny),
                          spring + 86_400, "spring-forward dayEnd must NOT be +86400")
        let fall = try XCTUnwrap(DayScorer.dayStartUnix("2026-11-01", tz: ny))
        XCTAssertNotEqual(DayScorer.nextDayStartUnix(after: fall, tz: ny),
                          fall + 86_400, "fall-back dayEnd must NOT be +86400")
    }

    // MARK: - dataThrough derivation

    func testDataThroughUsesMaxObservedTimestamp() {
        // Observed samples exist; dataThrough is their max.
        XCTAssertEqual(DayScorer.dataThroughUnix(maxObservedTs: 1_000, fallbackTs: 900, now: 10_000), 1_000)
    }

    func testDataThroughNeverEmitsFutureTimestamp() {
        // A clock-skewed/future sample is clamped to now.
        let now = 5_000
        XCTAssertEqual(DayScorer.dataThroughUnix(maxObservedTs: 50_000, fallbackTs: 1_000, now: now), now)
    }

    func testDataThroughFallsBackWhenWindowHasNoSamples() {
        // No samples at all → the day-start fallback.
        XCTAssertEqual(DayScorer.dataThroughUnix(maxObservedTs: nil, fallbackTs: 1_234, now: 10_000), 1_234)
    }

    func testDataThroughFloorsAtFallback() {
        // Observed below the fallback (shouldn't happen for a valid day) → floor.
        XCTAssertEqual(DayScorer.dataThroughUnix(maxObservedTs: 500, fallbackTs: 900, now: 10_000), 900)
    }

    // MARK: - Typed status rule (available / partial / no_data)

    func testStatusNoDataWhenHRTooSparse() {
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 199, rrCount: 5_000, respCount: 3_000,
                                                gravityCount: 3_000, detectedSessionCount: 1), "no_data")
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 0, rrCount: 0, respCount: 0,
                                                gravityCount: 0, detectedSessionCount: 0), "no_data")
    }

    func testStatusPartialWhenNoSleepSessionDetected() {
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 60_000, rrCount: 5_000, respCount: 3_000,
                                                gravityCount: 3_000, detectedSessionCount: 0), "partial")
    }

    func testStatusPartialWhenRequiredStreamEmpty() {
        // HR present + a session, but RR is empty → partial.
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 60_000, rrCount: 0, respCount: 3_000,
                                                gravityCount: 3_000, detectedSessionCount: 1), "partial")
        // HR present + a session, but gravity is empty → partial.
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 60_000, rrCount: 5_000, respCount: 3_000,
                                                gravityCount: 0, detectedSessionCount: 1), "partial")
    }

    func testStatusAvailableWithCompleteInputs() {
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 60_000, rrCount: 5_000, respCount: 3_000,
                                                gravityCount: 3_000, detectedSessionCount: 1), "available")
        // Secondary streams (resp/skinTemp/spo2/steps) are not required for the
        // core status — an empty resp stream still reports available.
        XCTAssertEqual(DayScorer.classifyStatus(hrCount: 60_000, rrCount: 5_000, respCount: 0,
                                                gravityCount: 3_000, detectedSessionCount: 1), "available")
    }

    func testPartialReasonsMirrorStatus() {
        XCTAssertEqual(DayScorer.partialReasons(rrCount: 5_000, gravityCount: 3_000,
                                                detectedSessionCount: 0), ["no_sleep_session"])
        XCTAssertEqual(DayScorer.partialReasons(rrCount: 0, gravityCount: 3_000,
                                                detectedSessionCount: 1), ["rr_empty"])
        XCTAssertEqual(DayScorer.partialReasons(rrCount: 5_000, gravityCount: 0,
                                                detectedSessionCount: 1), ["gravity_empty"])
        XCTAssertEqual(DayScorer.partialReasons(rrCount: 0, gravityCount: 0,
                                                detectedSessionCount: 0),
                       ["no_sleep_session", "rr_empty", "gravity_empty"])
        XCTAssertTrue(DayScorer.partialReasons(rrCount: 5_000, gravityCount: 3_000,
                                               detectedSessionCount: 1).isEmpty)
    }

    // MARK: - Device family mapping (real DB device_family values)

    private func expectFamily(_ deviceFamily: String?, _ sourceKind: String?, _ expected: DeviceFamily,
                              line: UInt = #line) {
        let df = deviceFamily ?? "<nil>"
        let sk = sourceKind ?? "<nil>"
        XCTAssertEqual(DayScorer.skinTempFamilyForDevice(deviceFamily: deviceFamily, sourceKind: sourceKind),
                       expected, "deviceFamily=\(df) sourceKind=\(sk)",
                       line: line)
    }

    func testDeviceFamilyForRealRegistryValues() {
        // Live DB values (public.devices.device_family):
        expectFamily("WHOOP 4.0", "whoop", .whoop4)
        expectFamily("WHOOP", "whoop", .whoop5)              // legacy "WHOOP" label → non-4.0 scale
        expectFamily("WHOOP 5.0 / MG", "whoop", .whoop5)
        expectFamily("WHOOP 5B00384569", "whoop", .whoop5)
        expectFamily("WHOOPSITO", "whoop", .whoop5)
        // Empty label on an imported (noop_push) device → non-4.0 scale.
        expectFamily("", "noop_push", .whoop5)
    }

    func testDeviceFamilyMissingRowCoalescesToWhoop5() {
        expectFamily(nil, nil, .whoop5)                      // missing device row
        expectFamily(nil, "whoop", .whoop5)                  // WHOOP row, no label
    }

    func testDeviceFamilyNonWhoopSourceKindDefersToModel() {
        // A non-WHOOP source kind carries no brand signal, so forRegistryDevice
        // sees a nil brand and the model label decides (mirrors the app).
        expectFamily("WHOOP 4.0", "noop_push", .whoop4)
        expectFamily("WHOOP 5.0 / MG", "noop_push", .whoop5)
        expectFamily(nil, "oura", .whoop5)
    }

    // MARK: - Main-session pick + stage minutes

    func testMainSleepSessionPicksLongestSpanTiesFirst() {
        let short = SleepSession(start: 0, end: 3_600, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let long = SleepSession(start: 10_000, end: 30_000, efficiency: 0.85, stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertEqual(DayScorer.mainSleepSession([short, long])?.start, 10_000)
        // Tie: the first session with the max span wins (deterministic).
        let a = SleepSession(start: 0, end: 7_200, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let b = SleepSession(start: 100, end: 7_300, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertEqual(DayScorer.mainSleepSession([a, b])?.start, 0)
        XCTAssertNil(DayScorer.mainSleepSession([]))
    }

    func testStageMinutes() {
        let stages = [
            StageSegment(start: 0, end: 1_800, stage: "light"),   // 30 min
            StageSegment(start: 1_800, end: 3_600, stage: "deep"), // 30 min
            StageSegment(start: 3_600, end: 5_400, stage: "rem"),  // 30 min
            StageSegment(start: 5_400, end: 6_600, stage: "wake"), // 20 min — not a stage total
        ]
        let (light, deep, rem) = DayScorer.stageMinutes(stages)
        XCTAssertEqual(light, 30, accuracy: 0.001)
        XCTAssertEqual(deep, 30, accuracy: 0.001)
        XCTAssertEqual(rem, 30, accuracy: 0.001)
        XCTAssertEqual(DayScorer.stageMinutes([]).light, 0)
    }
}
