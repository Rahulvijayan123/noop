import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Worker repairs for the independent reviews (docs/physiology-context/notes/review-worker-repairs.md): nightly
/// supports (RC-03), the history length (R-F2), device attributes on rebuilt days (RC-13), placement scope
/// (RC-17) and the frozen-reference cutoff per mode. Each test names the finding it pins.
final class ContextLaneReviewRepairTests: XCTestCase {
    typealias PC = PhysiologyContext

    // 2026-10-03T00:00:00Z
    let dayStart = 1_790_985_600
    let h = 3_600

    private func job(mode: PC.ProcessingMode = .retrospective, claimedAt: Int? = nil) -> ContextInputs.Job {
        ContextInputs.Job(userId: "u", deviceId: "d", day: "2026-10-03", mode: mode, inputRevision: 3, leaseToken: "t",
                          timezoneId: "UTC", cutoffOverride: nil, claimedAt: claimedAt ?? (dayStart + 40 * 3_600))
    }

    private func windows() throws -> ContextInputs.Windows {
        try XCTUnwrap(ContextInputs.windows(day: "2026-10-03", timezoneId: "UTC"))
    }

    private func snapshot(_ sessions: [(start: Int, end: Int)], napFlags: Set<Int> = [],
                          timezone: String? = nil) throws -> ContextInputs.Snapshot {
        var payload = ContextDaySim.snapshotPayload(sessions: sessions)
        for start in napFlags {
            payload = payload.replacingOccurrences(of: "\"id\":\"sleep-dev-\(start)\",\"is_nap\":false",
                                                   with: "\"id\":\"sleep-dev-\(start)\",\"is_nap\":true")
        }
        if let timezone { payload = payload.replacingOccurrences(of: "\"timezone\":\"UTC\"",
                                                                 with: "\"timezone\":\"\(timezone)\"") }
        return try XCTUnwrap(ContextInputs.parseSnapshot(day: "2026-10-03", payloadText: payload, resultRevision: 41,
                                                         inputRevision: 9, availableAt: dayStart + 16 * h))
    }

    private func measurement(_ ms: [PC.MeasurementInput], _ metric: PC.MetricKind) throws -> PC.MeasurementInput {
        try XCTUnwrap(ms.first { $0.metric == metric && $0.method.id.hasPrefix("snapshot.") }, "\(metric)")
    }

    // MARK: - RC-03: nightly supports

    /// A nap day: before the repair the pooled nightly fields took the hull of the night AND the nap, which spans
    /// the awake hours between them, so System C judged the measurement not "taken during sleep" and the day had no
    /// `*.sleep_night` value. With the main-sleep support the night stays in the nightly references.
    func testRC03_aNapDayKeepsItsNightlyValuesInTheSleepReferences() throws {
        let night = (start: dayStart - 2 * h, end: dayStart + 6 * h)
        let nap = (start: dayStart + 14 * h, end: dayStart + 15 * h)
        var l = ContextInputs.Loaded()
        for ts in (dayStart - 4 * h)..<(dayStart + 18 * h) {
            l.heartRate.append(.init(ts: ts, bpm: 60, availableAt: ts + 60))
            l.beatIntervals.append(.init(ts: ts, rrMs: ts % 2 == 0 ? 990 : 1_010, seq: 0, channel: 5,
                                         availableAt: ts + 60))
        }
        l.snapshot = try snapshot([night, nap])
        l.device = .init(family: "WHOOP 5.0 / MG", firmware: "50.36", sourceKind: "noop_push")
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        let nightly = a.input.measurements.filter { $0.method.id.hasPrefix("snapshot.") && $0.metric != .restingHeartRate }
        XCTAssertFalse(nightly.isEmpty)
        for m in nightly {
            XCTAssertEqual(m.support, PC.Interval(night.start, night.end), "\(m.method.id): main-sleep support")
            XCTAssertTrue(m.source.key.hasSuffix("#aggregate_pools_sessions_outside_support=1"), m.source.key)
        }
        let doc = PC.Engine.buildDay(a.input, history: a.history)
        let hrv = try XCTUnwrap(doc.envelopes.first { $0.method.id == "snapshot.hrv_rmssd.night" })
        XCTAssertEqual(hrv.verdict(.sleepMeasurement)?.state, .eligible,
                       "sleep state \(hrv.sleepWear.sleepState), reasons \(hrv.verdict(.sleepMeasurement)?.reasons ?? [])")
        XCTAssertEqual(hrv.source.key, "daily.hrv_rmssd_ms#aggregate_pools_sessions_outside_support=1",
                       "the note travels into the document's envelope")
        XCTAssertTrue(doc.dailyValues.contains { $0.seriesKey == "hrv_rmssd.sleep_night" },
                      "the nap day keeps its nightly HRV value: \(doc.dailyValues.map(\.seriesKey))")
    }

    /// A split night (two fragments the scorer bridges into one main night, 40 min apart) plus a nap: the support
    /// is the hull of the main fragments only, and it says how much of it is the unmeasured gap.
    func testRC03_aSplitNightIsSupportedByItsMainFragmentsAndRecordsTheGap() throws {
        let first = (start: dayStart - 2 * h, end: dayStart + 2 * h)
        let second = (start: dayStart + 2 * h + 2_400, end: dayStart + 6 * h)
        let nap = (start: dayStart + 14 * h, end: dayStart + 15 * h)
        let s = try snapshot([first, second, nap])
        let nights = try XCTUnwrap(ContextInputs.nightlySessions(s.sessions, offsetSec: 0))
        XCTAssertEqual(nights.main.map(\.start), [first.start, second.start])
        XCTAssertEqual(nights.outsideCount, 1)
        XCTAssertEqual(nights.splitGapS, 2_400)
        let ms = ContextInputs.snapshotMeasurements(s, offsetSec: 0)
        let hrv = try measurement(ms, .hrvRmssd)
        XCTAssertEqual(hrv.support, PC.Interval(first.start, second.end))
        XCTAssertNil(hrv.sessionId, "the support is more than one session")
        XCTAssertEqual(hrv.method.windowS, second.end - first.start)
        XCTAssertEqual(hrv.source.key,
                       "daily.hrv_rmssd_ms#aggregate_pools_sessions_outside_support=1;support_spans_split_sleep_gap_s=2400")
        let rest = try measurement(ms, .restingHeartRate)
        XCTAssertEqual(rest.support, PC.Interval(first.start, first.end), "resting HR: the longest session only")
        XCTAssertEqual(rest.source.key, "daily.resting_hr_bpm", "the primary session is part of the main night")

        // A night with no nap and no split carries the plain key (unchanged from before the repair).
        let plain = ContextInputs.snapshotMeasurements(try snapshot([first]), offsetSec: 0)
        XCTAssertEqual(try measurement(plain, .hrvRmssd).source.key, "daily.hrv_rmssd_ms")
        XCTAssertEqual(try measurement(plain, .hrvRmssd).support, PC.Interval(first.start, first.end))
    }

    /// A session the scorer flagged `is_nap: true` is never main sleep, even when it is the longest; resting HR
    /// keeps the scorer's primary (longest) session and says it lies outside the main night.
    func testRC03_aNapFlaggedSessionIsNeverMainSleep() throws {
        let night = (start: dayStart - h, end: dayStart + 5 * h)
        let longNap = (start: dayStart + 11 * h, end: dayStart + 18 * h)
        let s = try snapshot([night, longNap], napFlags: [longNap.start])
        let ms = ContextInputs.snapshotMeasurements(s, offsetSec: 0)
        XCTAssertEqual(try measurement(ms, .hrvSdnn).support, PC.Interval(night.start, night.end))
        let rest = try measurement(ms, .restingHeartRate)
        XCTAssertEqual(rest.support, PC.Interval(longNap.start, longNap.end), "the scorer's longest session")
        XCTAssertEqual(rest.source.key, "daily.resting_hr_bpm#primary_session_outside_main_sleep")

        // Every session flagged: the main-night rule runs over all of them, and says so.
        let allFlagged = try snapshot([night, longNap], napFlags: [night.start, longNap.start])
        let resp = try measurement(ContextInputs.snapshotMeasurements(allFlagged, offsetSec: 0), .respiratoryRate)
        XCTAssertTrue(resp.source.key.contains("main_sleep_from_nap_flagged_sessions"), resp.source.key)
    }

    /// The main night is the scorer's pick, which reads the user's clock: the snapshot's zone offset at the start of
    /// its day. The same two blocks resolve differently at UTC and at UTC+10.
    func testRC03_theMainNightRuleUsesTheScorersZoneOffset() throws {
        let a = (start: dayStart + 13 * h, end: dayStart + 19 * h)          // 23:00-05:00 at UTC+10
        let b = (start: dayStart + 26 * h, end: dayStart + 32 * h + 1_800)  // 02:00-08:30 UTC
        let utc = try snapshot([a, b])
        XCTAssertEqual(ContextInputs.nightlySessions(utc.sessions, offsetSec: 0)?.main.map(\.start), [b.start])
        XCTAssertEqual(ContextInputs.nightlySessions(utc.sessions, offsetSec: 10 * h)?.main.map(\.start), [a.start])

        let brisbane = try snapshot([a, b], timezone: "Australia/Brisbane")
        XCTAssertEqual(ContextInputs.scorerOffsetSeconds(brisbane, fallbackTimezoneId: "UTC"), 10 * h)
        XCTAssertEqual(ContextInputs.scorerOffsetSeconds(utc, fallbackTimezoneId: "Australia/Brisbane"), 0,
                       "the snapshot's own zone wins over the job's")
        var zoneless = utc
        zoneless.timezone = nil
        XCTAssertEqual(ContextInputs.scorerOffsetSeconds(zoneless, fallbackTimezoneId: "Australia/Brisbane"), 10 * h)
    }

    // MARK: - R-F2: history length

    func testRF2_historyCoversTheChangeDetectorsFullBurnIn() throws {
        XCTAssertEqual(ContextInputs.historyDays, 160, "90-day window + 14-day guard + 56-day autocorrelation window")
        let w = try windows()
        XCTAssertEqual(ContextInputs.shiftDay(w.historyFrom, by: 160), "2026-10-03")
        // Derived from the policy, so a tuning change moves the load with it.
        var policy = PC.Policy.default
        policy.change.windowDays = 30
        XCTAssertEqual(ContextInputs.historyDays(for: policy), 30 + 14 + 56)
        policy.change.cusumAutocorrelationAdjustment = false
        XCTAssertEqual(ContextInputs.historyDays(for: policy), 30 + 28, "no φ̂: the rolling reference alone")
        XCTAssertEqual(try XCTUnwrap(ContextInputs.windows(day: "2026-10-03", timezoneId: "UTC", historyDays: 58))
                        .historyFrom, "2026-08-06")
    }

    // MARK: - RC-13: no current device attribute on a rebuilt day

    /// The lane reads today's `devices` row while it rebuilds days up to 120 days old. Firmware (and the mutable
    /// family label) must not be stamped on them: two rebuilds of the same stored day under different current
    /// device rows are the same document.
    func testRC13_aRebuiltDayCarriesNoCurrentFirmwareOrFamilyLabel() throws {
        var before = ContextDaySim.representativeDay(dayStart: dayStart).loaded()
        before.snapshot = try snapshot([(dayStart - h, dayStart + 7 * h)])
        before.device = .init(family: nil, firmware: nil, sourceKind: "noop_push")
        var after = before
        after.device = .init(family: "WHOOP 5.0 / MG", firmware: "51.2.0.0", sourceKind: "noop_push")
        let w = try windows()
        let a = ContextInputs.assemble(before, job: job(), windows: w)
        let b = ContextInputs.assemble(after, job: job(), windows: w)
        XCTAssertNil(b.input.regime.firmware)
        XCTAssertNil(b.input.regime.deviceFamily)
        XCTAssertEqual(b.input.regime.sourceKind, "noop_push", "source kind is immutable for a device row")
        XCTAssertEqual(a.input.regime, b.input.regime)
        let da = PC.Engine.buildDay(a.input, history: a.history)
        let db = PC.Engine.buildDay(b.input, history: b.history)
        XCTAssertEqual(da.header.inputFingerprint, db.header.inputFingerprint)
        XCTAssertEqual(Set(da.envelopes.map(\.regimeKey)), Set(db.envelopes.map(\.regimeKey)),
                       "no regime boundary at the rebuild horizon")
        XCTAssertFalse(db.regimes.registry.isEmpty)
        XCTAssertTrue(db.regimes.registry.allSatisfy { $0.firmware == nil && $0.deviceFamily == nil },
                      "firmware and family are unknown on every regime")
        // The vendor still follows the immutable source kind.
        XCTAssertEqual(ContextInputs.deviceRegime(.init(family: nil, firmware: nil, sourceKind: "oura_ring")).vendor,
                       "oura")
    }

    // MARK: - RC-17: placement scope

    func testRC17_placementRecordsCarryTheirScope() throws {
        let device = ContextInputs.parsePlacement(["s": "100", "e": "", "placement": "wrist", "source": "user",
                                                   "revision": "1", "at": "50", "user_level": "false"])
        let account = ContextInputs.parsePlacement(["s": "100", "e": "200", "placement": "bicep", "source": "user",
                                                    "revision": "2", "at": "60", "user_level": "true"])
        XCTAssertEqual(device?.scope, "device")
        XCTAssertEqual(account?.scope, "account")
        XCTAssertTrue(ContextSQL.placements.contains("(device_id is null)::text as user_level"))

        // Both reach the engine with their scope, in a total order (scope is the last key).
        var l = ContextDaySim.representativeDay(dayStart: dayStart).loaded()
        l.snapshot = try snapshot([(dayStart - h, dayStart + 7 * h)])
        l.placements = [try XCTUnwrap(account), try XCTUnwrap(device)].map {
            var p = $0
            p.start = dayStart + 8 * h; p.end = nil; p.placement = "wrist"; p.revision = 1; p.recordedAt = dayStart
            return p
        }
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        XCTAssertEqual(a.input.placements.map(\.scope), ["account", "device"])
        var reversed = l
        reversed.placements.reverse()
        XCTAssertEqual(ContextInputs.assemble(reversed, job: job(), windows: try windows()).input.placements,
                       a.input.placements)
    }

    // MARK: - Frozen references per mode

    /// Retrospective: every reference registered for the device (the engine scores against the registered one
    /// and a back-filled day never registers a second "version 1"). Causal: only those registered by the cutoff.
    func testFrozenReferencesRetrospectiveReadsEveryRegisteredOneCausalOnlyByTheCutoff() throws {
        XCTAssertEqual(ContextInputs.historyCutoffParameter(job(mode: .retrospective, claimedAt: dayStart + 9 * h)), "")
        XCTAssertEqual(ContextInputs.historyCutoffParameter(job(mode: .causalLive, claimedAt: dayStart + 9 * h)),
                       String(dayStart + 9 * h))
        XCTAssertTrue(ContextSQL.frozenReferences.contains("nullif($3, '') is null or f.registered_at <="))

        // Whatever was loaded reaches the engine unfiltered by the worker.
        var l = ContextDaySim.representativeDay(dayStart: dayStart).loaded()
        l.frozen = (0..<3).map { i in
            PC.FrozenReference(id: "f\(i)", seriesKey: "hrv_rmssd.sleep_night", regimeKey: "r\(i)", version: 1,
                               fromDay: "2026-09-0\(i + 1)", toDay: "2026-10-0\(i + 1)", supportDays: 14, center: 45,
                               scale: 6, transform: "ln", selectionRule: "first_14", createdForDay: "2026-10-04",
                               policyFingerprint: "x")
        }
        let a = ContextInputs.assemble(l, job: job(), windows: try windows())
        XCTAssertEqual(a.history.frozenReferences.map(\.id), ["f0", "f1", "f2"],
                       "including references created for a later day (a back-filled retrospective day)")
    }
}
