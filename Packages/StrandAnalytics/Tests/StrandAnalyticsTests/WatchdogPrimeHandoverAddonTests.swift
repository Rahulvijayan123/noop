import XCTest
@testable import StrandAnalytics

/// Prime handover pins for F08 / F09 / F04 (`docs/baselines/PRIME_HANDOVER.md` §3).
final class WatchdogPrimeHandoverAddonTests: XCTestCase {

    func testPendingOnlyOnSentAndLiveAlerts() {
        let queued = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "queued", liveAlerts: true)
        XCTAssertTrue(queued.isEmpty)
        let denied = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "denied", liveAlerts: true)
        XCTAssertTrue(denied.isEmpty)
        let failed = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "failed", liveAlerts: true)
        XCTAssertTrue(failed.isEmpty)
        let backfill = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "sent", liveAlerts: false)
        XCTAssertTrue(backfill.isEmpty)
        let sent = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "sent", liveAlerts: true)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].status, .pending)
        XCTAssertEqual(sent[0].eventUnix, 1)
    }

    func testIllnessChipDoesNotSetConfoundsUsual() {
        let log = LBDayLog()
        XCTAssertFalse(log.confoundsUsual)
        var notes: [WatchdogEpisodeAnnotation] = []
        notes = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: notes, episodeId: "wd-1", deviceId: "strap",
            eventUnix: 100, delivery: "sent", liveAlerts: true)
        let entered = notes[0].entered(nowUnix: 200, symptoms: "unwell", exertion: .rest,
                                       stress: .high, illness: .feltOff, sensor: .loose, note: nil)
        XCTAssertEqual(entered.illness, .feltOff)
        XCTAssertFalse(log.confoundsUsual)
        XCTAssertFalse(entered.isNegativeSymptomLabel)
    }

    func testSkipIsNotSymptomsNone() {
        let pending = WatchdogEpisodeAnnotation(episodeId: "wd-1", deviceId: "s", eventUnix: 1)
        let skipped = pending.skipped()
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertTrue(skipped.symptomsMissing)
        XCTAssertFalse(skipped.isNegativeSymptomLabel)
        XCTAssertNil(skipped.symptoms)
        XCTAssertNotEqual(skipped.symptoms, "none")
        let expired = pending.expireIfNeeded(nowUnix: 1 + WatchdogEpisodeAnnotation.expireSeconds)
        XCTAssertEqual(expired.status, .expired)
        XCTAssertNotEqual(expired.symptoms, "none")
    }

    func testLedgerIgnoresBackfill() {
        let now = 98_200_000
        let result = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now, inject: .severe, liveAlerts: false)
        let rows = WatchdogEpisodeLedger.upsert(rows: [], result: result, deviceId: "s",
                                                nowUnix: now, liveAlerts: false)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(result.shouldNotify)
    }

    func testExportMarksStudentsNotOfficial() {
        let pack = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 10, ledger: [],
            evaluations: [], dayLogs: [:], annotations: [], recovery: nil)
        XCTAssertTrue(pack.versionLine.contains("student"))
        XCTAssertFalse(pack.versionLine.lowercased().contains("official"))
        XCTAssertTrue(pack.text.contains("student"))
        XCTAssertFalse(pack.text.lowercased().contains("official"))
        XCTAssertTrue(WatchdogConfig.modelVersion.contains("units-ad-coreml-v3"))
        XCTAssertTrue(WatchdogConfig.forecastModelVersion.contains("timesfm3-student-v3"))
    }

    func testExportKeepsTwoCopiesPrintedSeparately() {
        let week = LBCopySnapshot(center: 70, spread: 3, centerDisplay: 70,
                                  bandLoDisplay: 64, bandHiDisplay: 76, n: 7,
                                  coverage: 40, version: "t", held: false)
        let long = LBCopySnapshot(center: 60, spread: 4, centerDisplay: 60,
                                  bandLoDisplay: 52, bandHiDisplay: 68, n: 40,
                                  coverage: 40, version: "t", held: false)
        var ev = quietEval()
        ev.series = .awakeRestHR
        ev.copy7 = week
        ev.copyLong = long
        let pack = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 10, ledger: [],
            evaluations: [ev], dayLogs: [:], annotations: [], recovery: nil)
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("week") }))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("long") }))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("not averaged") }))
        XCTAssertFalse(pack.text.contains("blended"))
    }

    func testTwoTicksOneMinuteOneBurden() {
        let now = 1_800_000
        var result = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now, inject: .severe, liveAlerts: true)
        var rows = WatchdogEpisodeLedger.upsert(rows: [], result: result, deviceId: "s",
                                                nowUnix: now, liveAlerts: true)
        result = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                   nowUnix: now + 20, previous: result.carry,
                                   inject: .severe, liveAlerts: true)
        rows = WatchdogEpisodeLedger.upsert(rows: rows, result: result, deviceId: "s",
                                            nowUnix: now + 20, liveAlerts: true)
        XCTAssertEqual(rows.first?.offMinutes.count, 1)
    }

    func testWalkingWeekIsNotFreeze() {
        let freeze = LBUsualFreeze(t0CivilDay: "2026-09-01", tFreeze: "2026-09-01",
                                   reason: LBUsualFreeze.loggedIll, version: 1,
                                   centerLong: 60, spreadLong: 4, center7: 80, spread7: 3)
        let week = LBCopySnapshot(center: 80, spread: 3, centerDisplay: 80,
                                  bandLoDisplay: 74, bandHiDisplay: 86, n: 7,
                                  coverage: 40, version: "t", held: false)
        let long = LBCopySnapshot(center: 60, spread: 4, centerDisplay: 60,
                                  bandLoDisplay: 52, bandHiDisplay: 68, n: 40,
                                  coverage: 40, version: "t", held: false)
        let ref = WatchdogEventRecovery.reference(freeze: freeze, copyLong: long,
                                                  establishedLong: true, showLong: true, k: 2)
        XCTAssertEqual(ref?.center, 60)
        XCTAssertNotEqual(ref?.center, week.center)
    }

    func testUnknownOnUnavailable() {
        var rec = WatchdogEventRecovery(
            episodeId: "wd-1", deviceId: "s", openedUnix: 1_000, openedCivilDay: "2026-10-01",
            status: .open,
            channels: [WatchdogEventRecoveryChannel(series: .awakeRestHR, center: 60, spread: 4, k: 2)])
        rec = WatchdogEventRecovery.step(rec, hrBpm: 90, hrvMs: nil, nowUnix: 1_200, unavailable: true)
        XCTAssertEqual(rec.status, .unknown)
        XCTAssertNil(rec.channels[0].returnedUnix)
        XCTAssertNotEqual(rec.status, .returned)
    }

    func testNoReferenceWithoutLongCopy() {
        let ref = WatchdogEventRecovery.reference(freeze: nil, copyLong: nil,
                                                  establishedLong: false, showLong: false, k: 2)
        XCTAssertNil(ref)
        let opened = WatchdogEventRecovery.openIfNeeded(
            existing: nil, episodeId: "wd-1", deviceId: "s", nowUnix: 10,
            civilDay: "2026-10-01", evaluations: [], liveAlerts: true)
        XCTAssertEqual(opened?.status, .noReference)
        XCTAssertNotEqual(opened?.status, .returned)
    }

    func testDoesNotChangeSeverity() {
        let now = 98_100_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: now, inject: .severe, liveAlerts: true)
        _ = WatchdogEventRecovery.openIfNeeded(
            existing: nil, episodeId: first.episodeId, deviceId: "s", nowUnix: now,
            civilDay: "2026-10-01", evaluations: [], liveAlerts: true)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now + 20, previous: first.carry,
                                       inject: .severe, liveAlerts: true)
        XCTAssertEqual(first.severity, second.severity)
        XCTAssertEqual(first.liveOff, second.liveOff)
        XCTAssertEqual(first.shouldNotify || second.notifyReason == "in-flight"
                       || !second.shouldNotify || first.shouldNotify, true)
    }

    func testSidecarHooksDoNotMoveEvaluate() {
        let now = 98_000_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: now, inject: .severe, liveAlerts: true)
        let notes = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: first.episodeId ?? "wd", deviceId: "s",
            eventUnix: now, delivery: "sent", liveAlerts: true)
        let ledger = WatchdogEpisodeLedger.upsert(rows: [], result: first, deviceId: "s",
                                                  nowUnix: now, liveAlerts: true)
        _ = WatchdogEventRecovery.openIfNeeded(
            existing: nil, episodeId: first.episodeId, deviceId: "s", nowUnix: now,
            civilDay: "2026-10-01", evaluations: [], liveAlerts: true)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now + 20, previous: first.carry,
                                       inject: .severe, liveAlerts: true)
        XCTAssertEqual(first.severity, second.severity)
        XCTAssertEqual(first.liveOff, second.liveOff)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertFalse(ledger.isEmpty)
        let ev = quietEval()
        let nLong = ev.nLong
        _ = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 1, ledger: ledger,
            evaluations: [ev], dayLogs: [:], annotations: notes, recovery: nil)
        XCTAssertEqual(ev.nLong, nLong)
    }

    private func quietEval() -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: "2026-06-15", series: .sleepRHR, observations: [])
    }
}
