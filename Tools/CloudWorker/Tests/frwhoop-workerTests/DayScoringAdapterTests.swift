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

    // MARK: - SpO₂ strap estimate

    func testSpo2EstimateKeysAreTheNightlyMeanOverReadingsInsideSleepOnly() {
        let sleep = SleepSession(start: 1_000, end: 2_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let readings = [
            V18AuxSample(ts: 900, auxByte82: 70),     // before sleep: not part of the night
            V18AuxSample(ts: 1_000, auxByte82: 96),
            V18AuxSample(ts: 1_500, auxByte82: 97),
            V18AuxSample(ts: 2_000, auxByte82: 98),
            V18AuxSample(ts: 2_100, auxByte82: 70),   // after sleep
        ]
        let keys = DayScorer.spo2EstimateKeys(sessions: [sleep], readings: readings)
        XCTAssertEqual(keys["spo2_candidate_pct"] as? Int, 97)
        XCTAssertEqual(keys["spo2_candidate_samples"] as? Int, 3)
        XCTAssertNil(keys["spo2_pct"], "a strap estimate is never the calibrated blood-oxygen key")
    }

    func testSpo2EstimateKeysAreAbsentWithoutASessionOrAnInBandReading() {
        let sleep = SleepSession(start: 1_000, end: 2_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertTrue(DayScorer.spo2EstimateKeys(sessions: [], readings: [V18AuxSample(ts: 1_500, auxByte82: 97)]).isEmpty)
        XCTAssertTrue(DayScorer.spo2EstimateKeys(sessions: [sleep], readings: []).isEmpty)
        XCTAssertTrue(DayScorer.spo2EstimateKeys(
            sessions: [sleep], readings: [V18AuxSample(ts: 1_500, auxByte82: 0), V18AuxSample(ts: 1_501, auxByte82: 128)]
        ).isEmpty)
    }

    // MARK: - R-R transport selection + intraday HRV

    /// `seconds` of 60 bpm beats from `start`, alternating 975/1025 ms so every successive difference is 50 ms
    /// and the RMSSD is exactly 50. Timestamps advance one whole second per beat.
    private func beats(from start: Int, seconds: Int, channel: RRSourceChannel?) -> [RRInterval] {
        (0..<seconds).map { RRInterval(ts: start + $0, rrMs: $0 % 2 == 0 ? 975 : 1_025, srcChannel: channel, seq: $0) }
    }

    private func coverage(_ rr: [RRInterval]) -> Double {
        HRVAnalyzer.rrCoverage(tsSec: rr.map(\.ts), rrMs: rr.map { Double($0.rrMs) })
    }

    func testBothWhoop5TransportsOverCountAndOneTransportRestoresCoverage() {
        let start = 1_790_000_000 - 1_790_000_000 % 3_600
        let both = beats(from: start, seconds: 3_000, channel: .whoop5Historical)
            + beats(from: start, seconds: 3_000, channel: .whoop5Standard)
        XCTAssertGreaterThan(coverage(both), HRVAnalyzer.coveragePlausibleCeiling)   // what the worker used to feed the HRV gate

        let one = DayScorer.oneTransportPerHour(both)
        XCTAssertEqual(one.count, 3_000)
        XCTAssertEqual(Set(one.compactMap(\.srcChannel)), [.whoop5Historical])       // tie: the lower channel, as the app
        XCTAssertLessThanOrEqual(coverage(one), HRVAnalyzer.coveragePlausibleCeiling)
    }

    func testFreshestHourKeepsTheLiveTransportWhileOffloadTrails() {
        let h0 = 1_790_000_000 - 1_790_000_000 % 3_600
        // Hour 0: both transports. Hour 1: the offload has only reached 10 minutes in, live has 30.
        let rr = beats(from: h0, seconds: 3_000, channel: .whoop5Historical)
            + beats(from: h0, seconds: 3_000, channel: .whoop5Standard)
            + beats(from: h0 + 3_600, seconds: 600, channel: .whoop5Historical)
            + beats(from: h0 + 3_600, seconds: 1_800, channel: .whoop5Standard)
        let one = DayScorer.oneTransportPerHour(rr)
        XCTAssertEqual(one.filter { $0.ts < h0 + 3_600 }.count, 3_000)
        let fresh = one.filter { $0.ts >= h0 + 3_600 }
        XCTAssertEqual(fresh.count, 1_800)
        XCTAssertEqual(Set(fresh.compactMap(\.srcChannel)), [.whoop5Standard])
    }

    func testWhoop4HourPicksOneTransportAndDropsUnlabelledCopies() {
        let h0 = 1_790_000_000 - 1_790_000_000 % 3_600
        let rr = beats(from: h0, seconds: 1_000, channel: .whoop4Historical)
            + beats(from: h0, seconds: 900, channel: .whoop4Standard)
            + beats(from: h0, seconds: 900, channel: nil)
        let one = DayScorer.oneTransportPerHour(rr)
        XCTAssertEqual(one.count, 1_000)
        XCTAssertEqual(Set(one.compactMap(\.srcChannel)), [.whoop4Historical])
    }

    func testHoursWithoutAStrapTransportAndLiveOnlyType40AreHandledLikeTheApp() {
        let h0 = 1_790_000_000 - 1_790_000_000 % 3_600
        let unlabelled = beats(from: h0, seconds: 600, channel: nil)
        let oura = beats(from: h0 + 3_600, seconds: 600, channel: .greenQuality)
        XCTAssertEqual(DayScorer.oneTransportPerHour(unlabelled + oura), unlabelled + oura)
        // Type-40 live on a 5/MG never scores on its own.
        XCTAssertTrue(DayScorer.oneTransportPerHour(beats(from: h0, seconds: 600, channel: .whoop5Realtime)).isEmpty)
    }

    func testHrvSlotsGiveOneRmssdPerFifteenMinutes() {
        let day = 1_790_000_000 - 1_790_000_000 % 900
        let rr = beats(from: day, seconds: 3_600, channel: .whoop5Standard)   // four slots
        let slots = DayScorer.hrvSlots(rr: rr, from: day, to: day + 86_400)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots.map { $0[0] as? Int }, [day, day + 900, day + 1_800, day + 2_700])
        for s in slots {
            XCTAssertEqual(s[1] as? Double ?? 0, 50, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(s[2] as? Int ?? 0, DayScorer.hrvSlotMinCleanBeats)
        }
    }

    func testHrvSlotsSkipThinOverCountedAndOutOfDaySlots() {
        let day = 1_790_000_000 - 1_790_000_000 % 900
        let thin = beats(from: day, seconds: 40, channel: .whoop5Standard)                     // slot 0: seconds of data
        let doubled = beats(from: day + 900, seconds: 800, channel: .whoop5Standard)
            + beats(from: day + 900, seconds: 800, channel: .whoop5Historical)                 // slot 1: both transports
        let good = beats(from: day + 1_800, seconds: 800, channel: .whoop5Standard)            // slot 2
        let before = beats(from: day - 900, seconds: 800, channel: .whoop5Standard)           // previous day
        let slots = DayScorer.hrvSlots(rr: before + thin + doubled + good, from: day, to: day + 86_400)
        XCTAssertEqual(slots.map { $0[0] as? Int }, [day + 1_800])
    }

    // MARK: - hrv_slots pinning for the attach path (audit P3-2)

    func testHrvSlotStartsFromPublishedPoints() {
        // points are [slotStartUnix, rmssdMs, cleanBeats] as in hrvSlots().
        let day = 1_790_000_000 - 1_790_000_000 % 900
        let points: [[Any]] = [
            [day, 45.3, 300],
            [day + 900, 52.1, 450],
            [day + 1_800, 38.9, 210],
        ]
        XCTAssertEqual(DayScorer.hrvSlotStarts(fromPoints: points),
                       Set([day, day + 900, day + 1_800]))
        XCTAssertEqual(DayScorer.hrvSlotStarts(fromPoints: []), Set<Int>())
        // Non-numeric first elements (malformed) are ignored, never crash.
        XCTAssertEqual(DayScorer.hrvSlotStarts(fromPoints: [["nope", 1.0, 2]]), Set<Int>())
    }

    // MARK: - Zone-correct analyzeDay dayWindow (repair-daybucket wiring)

    /// The call site in `scoreAndBuildPayloads` passes
    /// `LocalDayWindows(timeZone: tz).window(ofDayKey: claim.day)`. These tests
    /// pin the VALUE of that expression against the worker's own calendar math
    /// (`dayStartUnix`/`nextDayStartUnix`), so a regression to the old fixed
    /// 86,400 window would fail here: on DST days the window must be 23 h / 25 h,
    /// and its [start, end) must equal the worker's local midnights exactly.
    func testAnalyzeDayDayWindowAgreesWithWorkerCalendarBounds() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        for day in ["2026-03-08", "2026-11-01", "2026-06-15"] {
            let window = try XCTUnwrap(LocalDayWindows(timeZone: ny).window(ofDayKey: day))
            let start = try XCTUnwrap(DayScorer.dayStartUnix(day, tz: ny))
            let end = DayScorer.nextDayStartUnix(after: start, tz: ny)
            XCTAssertEqual(Int(window.start.timeIntervalSince1970), start,
                           "dayWindow start must equal the worker's local midnight for \(day)")
            XCTAssertEqual(Int(window.nextStart.timeIntervalSince1970), end,
                           "dayWindow nextStart must equal the worker's next local midnight for \(day)")
        }
    }

    func testAnalyzeDayDayWindowIsZoneCorrectOnDSTDays() {
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = LocalDayWindows(timeZone: ny).window(ofDayKey: "2026-03-08")!
        XCTAssertEqual(spring.nextStart.timeIntervalSince(spring.start), 23 * 3_600,
                       "spring-forward day window must be 23 h, not a fixed 86,400 block")
        let fall = LocalDayWindows(timeZone: ny).window(ofDayKey: "2026-11-01")!
        XCTAssertEqual(fall.nextStart.timeIntervalSince(fall.start), 25 * 3_600,
                       "fall-back day window must be 25 h, not a fixed 86,400 block")
        let normal = LocalDayWindows(timeZone: ny).window(ofDayKey: "2026-06-15")!
        XCTAssertEqual(normal.nextStart.timeIntervalSince(normal.start), 24 * 3_600)
    }

    // MARK: - Published activity epochs (audit D5-01 / D6-V02)

    func testPublishedEpochsKeepOneEpochPerSlotAndNameEveryLineage() {
        func row(_ day: String, _ s: Int, _ fp: String, _ rev: Int, _ m: String) -> [String: String] {
            ["day": day, "start_ts": String(s), "end_ts": String(s + 30), "motion_label": m,
             "posture": "unknown", "exercise_session": "unknown", "sleep_state": "unknown",
             "exertion_context": "unknown", "wear_state": "unknown", "confidence": "0.8",
             "observed_s": "30", "valid_s": "30", "model_version": "hart-\(rev)",
             "preprocessing_version": "p", "ontology_version": "v1", "fingerprint": fp,
             "result_revision": String(rev)]
        }
        let rows = [row("2026-10-06", 100, "b", 20, "walking"),
                    row("2026-10-06", 100, "b", 20, "running"),   // a repeated slot is dropped
                    row("2026-10-06", 130, "b", 20, "walking"),
                    row("2026-10-07", 160, "c", 30, "stationary")]
        let out = DayScorer.publishedEpochs(fromRows: rows, dayStart: 0)
        XCTAssertEqual(out.epochs.map(\.startTs), [100, 130, 160])
        XCTAssertEqual(out.epochs.first?.motion, .walking, "the first (newest) row of a slot wins")
        XCTAssertEqual(out.lineages, [
            .init(day: "2026-10-06", fingerprint: "b", resultRevision: 20, epochs: 2, modelVersion: "hart-20"),
            .init(day: "2026-10-07", fingerprint: "c", resultRevision: 30, epochs: 1, modelVersion: "hart-30"),
        ])
        XCTAssertEqual(out.maxEnd, 190)
    }

    func testPublishedEpochsSQLResolvesTheNewestPublishPerUtcDay() {
        let sql = DayScorer.publishedEpochsSQL
        XCTAssertTrue(sql.contains("generate_series"), "every UTC day the local window overlaps")
        XCTAssertTrue(sql.contains("max(x.result_revision)"))
        XCTAssertTrue(sql.contains("e.day = cur.day and e.result_revision = cur.result_revision"))
        XCTAssertFalse(sql.contains("limit 1"), "one revision for the whole window dropped a UTC day")
    }

    // MARK: - Nightly baselines hold absent days (audit D4-03 / D4-12)

    func testBaselineDayKeysCoverEveryCalendarDayBeforeTheClaim() throws {
        let keys = try XCTUnwrap(DayScorer.baselineDayKeys(before: "2026-03-10"))
        XCTAssertEqual(keys.count, 120)
        XCTAssertEqual(keys.last, "2026-03-09")
        XCTAssertEqual(keys.first, "2025-11-10")
        XCTAssertEqual(Set(keys).count, 120)
        XCTAssertNil(DayScorer.baselineDayKeys(before: "2026-02-30"))
    }

    func testBaselineFoldGoesStaleAfterALongAbsence() throws {
        // 40 nights of history, then nothing for 40 days before the claimed night.
        let keys = try XCTUnwrap(DayScorer.baselineDayKeys(before: "2026-06-01"))
        let rows: [[String: String]] = keys.prefix(80).suffix(40).enumerated().map { i, d in
            ["d": d, "hrv": String(50 + i % 5), "rhr": "55", "resp": "14.5", "st": "33.4"]
        }
        let padded = try DayScorer.foldBaselines(rows: rows, before: "2026-06-01")
        XCTAssertEqual(padded.hrv?.status, .stale, "40 nights without a reading is not a trusted baseline")
        XCTAssertEqual(padded.restingHR?.status, .stale)
        XCTAssertEqual(padded.hrv?.nightsSinceUpdate, 40)
        XCTAssertEqual(padded.hrv?.nValid, 40)
        // The old fold (rows only) saw 40 consecutive nights and called it trusted.
        let unpadded = Baselines.foldHistory(rows.map { Double($0["hrv"]!) }, cfg: Baselines.metricCfg["hrv"]!)
        XCTAssertEqual(unpadded.status, .trusted)
        XCTAssertEqual(unpadded.baseline, try XCTUnwrap(padded.hrv).baseline, accuracy: 1e-9,
                       "skip-and-hold leaves the centre where the last night put it")
    }

    /// The day back from a 40-night absence still publishes a recovery (the phone scores it too), but with
    /// `.building` confidence instead of `.solid`, and its provenance names the held baselines.
    func testTheDayBackFromALongAbsenceScoresOnTheHeldBaselineAndSaysSo() throws {
        let keys = try XCTUnwrap(DayScorer.baselineDayKeys(before: "2026-06-01"))
        let rows: [[String: String]] = keys.prefix(80).suffix(40).enumerated().map { i, d in
            ["d": d, "hrv": String(50 + i % 5), "rhr": "55", "resp": "14.5", "st": "33.4"]
        }
        let folded = try DayScorer.foldBaselines(rows: rows, before: "2026-06-01")
        let stale = try XCTUnwrap(folded.hrv)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertFalse(stale.usable, "scoring straight off the fold would withhold the recovery")
        XCTAssertNil(RecoveryScorer.recovery(hrv: 52, rhr: 55, resp: 14.5, hrvBaseline: RecoveryScorer.DriverBaseline(stale),
                                             rhrBaseline: nil, respBaseline: nil, sleepPerf: 0.85,
                                             hrvBaselineUsable: stale.usable))

        let (scoring, held) = DayScorer.scoringBaselines(folded)
        let hrv = try XCTUnwrap(scoring.hrv)
        XCTAssertEqual(hrv.status, .provisional)
        XCTAssertEqual(hrv.baseline, stale.baseline, "the centre is held, not re-estimated")
        XCTAssertEqual(hrv.spread, stale.spread)
        XCTAssertEqual(hrv.nightsSinceUpdate, 40)
        XCTAssertEqual(held, ["hrv": 40, "resting_hr": 40, "resp": 40, "skin_temp": 40])
        let recovery = RecoveryScorer.recovery(hrv: 52, rhr: 55, resp: 14.5, hrvBaseline: RecoveryScorer.DriverBaseline(hrv),
                                               rhrBaseline: nil, respBaseline: nil, sleepPerf: 0.85,
                                               hrvBaselineUsable: hrv.usable)
        XCTAssertNotNil(recovery, "the day back is scored")
        XCTAssertEqual(ScoreConfidence.charge(recovery: recovery, hrvBaseline: scoring.hrv), .building,
                       "with a downgraded confidence")

        var daily: [String: Any] = ["provenance": ["scope": "hrv_sleep"]]
        DayScorer.recordHeldBaselines(held, in: &daily)
        let provenance = try XCTUnwrap(daily["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["scope"] as? String, "hrv_sleep", "existing provenance is kept")
        XCTAssertEqual(provenance["baseline_fallback"] as? String, "held_stale")
        XCTAssertEqual(provenance["baseline_nights_since_update"] as? [String: Int], held)

        // An unbroken history holds nothing and publishes exactly what it did.
        let fresh = try DayScorer.foldBaselines(rows: keys.suffix(30).map {
            ["d": $0, "hrv": "50", "rhr": "55", "resp": "14.5", "st": "33.4"]
        }, before: "2026-06-01")
        let unchanged = DayScorer.scoringBaselines(fresh)
        XCTAssertTrue(unchanged.held.isEmpty)
        XCTAssertEqual(unchanged.baselines.hrv, fresh.hrv)
        var plain: [String: Any] = ["provenance": ["scope": "hrv_sleep"]]
        DayScorer.recordHeldBaselines(unchanged.held, in: &plain)
        XCTAssertNil((plain["provenance"] as? [String: Any])?["baseline_fallback"])
    }

    func testBaselineFoldOfAnUnbrokenHistoryIsUnchanged() throws {
        let keys = try XCTUnwrap(DayScorer.baselineDayKeys(before: "2026-06-01"))
        let rows: [[String: String]] = keys.suffix(30).enumerated().map { i, d in
            ["d": d, "hrv": String(48 + i % 7), "rhr": String(54 + i % 3), "resp": "14.5", "st": "33.4"]
        }
        let padded = try DayScorer.foldBaselines(rows: rows, before: "2026-06-01")
        let cfg = Baselines.metricCfg["hrv"]!
        let plain = Baselines.foldHistory(rows.map { Double($0["hrv"]!) }, cfg: cfg)
        XCTAssertEqual(padded.hrv?.status, .trusted)
        XCTAssertEqual(try XCTUnwrap(padded.hrv).baseline, plain.baseline, accuracy: 1e-9,
                       "leading empty days before the first night change nothing")
        XCTAssertEqual(try XCTUnwrap(padded.hrv).spread, plain.spread, accuracy: 1e-9)
        XCTAssertEqual(padded.hrv?.nValid, plain.nValid)
    }
}
