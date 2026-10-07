import XCTest
@testable import StrandAnalytics

final class WatchdogAddonSidecarTests: XCTestCase {
    func testAnnotationDoesNotSetConfoundsUsual() {
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

    func testAnnotationDoesNotChangeSeverity() {
        let now = 98_000_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: now, inject: .severe, liveAlerts: true)
        _ = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: first.episodeId ?? "wd", deviceId: "s",
            eventUnix: now, delivery: "sent", liveAlerts: true)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now + 20, previous: first.carry,
                                       inject: .severe, liveAlerts: true)
        XCTAssertEqual(first.severity, second.severity)
        XCTAssertEqual(first.liveOff, second.liveOff)
    }

    func testSkippedIsNotNegativeLabel() {
        let pending = WatchdogEpisodeAnnotation(episodeId: "wd-1", deviceId: "s", eventUnix: 1)
        let skipped = pending.skipped()
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertTrue(skipped.symptomsMissing)
        XCTAssertFalse(skipped.isNegativeSymptomLabel)
        XCTAssertNil(skipped.symptoms)
        XCTAssertNotEqual(skipped.symptoms, "none")
    }

    func testEventTimeIsEpisodeOpenNotSave() {
        let row = WatchdogEpisodeAnnotation(episodeId: "wd-9", deviceId: "s", eventUnix: 50)
            .entered(nowUnix: 80, symptoms: "none", exertion: nil, stress: nil,
                     illness: nil, sensor: nil, note: nil)
        XCTAssertEqual(row.eventUnix, 50)
        XCTAssertEqual(row.enteredUnix, 80)
        XCTAssertEqual(row.symptoms, "none")
    }

    func testNoAnnotationOnQueuedOrBackfill() {
        let q = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "queued", liveAlerts: true)
        XCTAssertTrue(q.isEmpty)
        let b = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: [], episodeId: "wd-1", deviceId: "s", eventUnix: 1,
            delivery: "sent", liveAlerts: false)
        XCTAssertTrue(b.isEmpty)
    }

    func testSurveyNotifyIsNotWatchdogPage() {
        XCTAssertEqual(WatchdogEpisodeAnnotation.noteCategory, "watchdog-episode-note")
        XCTAssertNotEqual(WatchdogEpisodeAnnotation.noteCategory, "watchdog")
        let (want, reason) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: true, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 0)
        XCTAssertNotEqual(reason, WatchdogEpisodeAnnotation.noteCategory)
        _ = want
    }

    func testEventRecoveryFreezeIgnoresWalkingWeek() {
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
        var rec = WatchdogEventRecovery(
            episodeId: "wd-1", deviceId: "s", openedUnix: 1_000, openedCivilDay: "2026-10-01",
            status: .open,
            channels: [WatchdogEventRecoveryChannel(series: .awakeRestHR, center: 60, spread: 4, k: 2)])
        rec = WatchdogEventRecovery.step(rec, hrBpm: 90, hrvMs: nil, nowUnix: 1_200, unavailable: false)
        XCTAssertEqual(rec.status, .open)
        XCTAssertGreaterThan(rec.channels[0].remainingZ ?? 0, 2)
    }

    func testEventRecoveryUnknownOnUnavailable() {
        var rec = WatchdogEventRecovery(
            episodeId: "wd-1", deviceId: "s", openedUnix: 1_000, openedCivilDay: "2026-10-01",
            status: .open,
            channels: [WatchdogEventRecoveryChannel(series: .awakeRestHR, center: 60, spread: 4, k: 2)])
        rec = WatchdogEventRecovery.step(rec, hrBpm: 90, hrvMs: nil, nowUnix: 1_200, unavailable: true)
        XCTAssertEqual(rec.status, .unknown)
        XCTAssertNil(rec.channels[0].returnedUnix)
    }

    func testEventRecoveryIgnoresHeldMinute() {
        var rec = WatchdogEventRecovery(
            episodeId: "wd-1", deviceId: "s", openedUnix: 1_000, openedCivilDay: "2026-10-01",
            status: .open,
            channels: [WatchdogEventRecoveryChannel(series: .awakeRestHR, center: 60, spread: 4, k: 2)])
        rec = WatchdogEventRecovery.step(rec, hrBpm: 90, hrvMs: nil, nowUnix: 1_200, unavailable: false)
        let z = rec.channels[0].remainingZ
        rec = WatchdogEventRecovery.step(rec, hrBpm: 50, hrvMs: nil, nowUnix: 1_220, unavailable: false)
        XCTAssertEqual(rec.channels[0].remainingZ, z)
        XCTAssertEqual(rec.channels[0].lastEligibleUnix, 1_200 - 1_200 % 60)
    }

    func testEventRecoveryTwoEligibleMinutesToReturn() {
        var rec = WatchdogEventRecovery(
            episodeId: "wd-1", deviceId: "s", openedUnix: 1_000, openedCivilDay: "2026-10-01",
            status: .open,
            channels: [WatchdogEventRecoveryChannel(series: .awakeRestHR, center: 60, spread: 4, k: 2)])
        rec = WatchdogEventRecovery.step(rec, hrBpm: 61, hrvMs: nil, nowUnix: 1_200, unavailable: false)
        XCTAssertEqual(rec.status, .returning)
        XCTAssertNil(rec.channels[0].returnedUnix)
        rec = WatchdogEventRecovery.step(rec, hrBpm: 61, hrvMs: nil, nowUnix: 1_260, unavailable: false)
        XCTAssertEqual(rec.status, .returned)
        XCTAssertNotNil(rec.hoursToReturn)
    }

    func testEventRecoveryNoReferenceWithoutLongCopy() {
        let ref = WatchdogEventRecovery.reference(freeze: nil, copyLong: nil,
                                                  establishedLong: false, showLong: false, k: 2)
        XCTAssertNil(ref)
        let opened = WatchdogEventRecovery.openIfNeeded(
            existing: nil, episodeId: "wd-1", deviceId: "s", nowUnix: 10,
            civilDay: "2026-10-01", evaluations: [], liveAlerts: true)
        XCTAssertEqual(opened?.status, .noReference)
    }

    func testEventRecoveryNoOpenOnBackfill() {
        XCTAssertNil(WatchdogEventRecovery.openIfNeeded(
            existing: nil, episodeId: "wd-1", deviceId: "s", nowUnix: 10,
            civilDay: "2026-10-01", evaluations: [], liveAlerts: false))
    }

    func testEventRecoveryDoesNotChangeSeverityOrNotify() {
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
    }

    func testLedgerIgnoresBackfill() {
        let now = 98_200_000
        let result = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                       nowUnix: now, inject: .severe, liveAlerts: false)
        let rows = WatchdogEpisodeLedger.upsert(rows: [], result: result, deviceId: "s",
                                                nowUnix: now, liveAlerts: false)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(result.shouldNotify)
        XCTAssertNotEqual(result.carry.notifyDelivery, "queued")
    }

    func testExportBurdenUsesEligibleMinutes() {
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

    func testExportMarksStudentsAndKeepsTwoCopies() {
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
        XCTAssertTrue(pack.versionLine.contains("student"))
        XCTAssertFalse(pack.versionLine.lowercased().contains("official"))
        XCTAssertTrue(pack.text.contains("student"))
        XCTAssertFalse(pack.text.lowercased().contains("official"))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("week") }))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("long") }))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("not averaged") }))
    }

    func testExportSkippedAnnotationIsMissing() {
        let skipped = WatchdogEpisodeAnnotation(episodeId: "wd-1", deviceId: "s", eventUnix: 5)
            .skipped()
        let pack = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 10, ledger: [],
            evaluations: [], dayLogs: [:], annotations: [skipped], recovery: nil)
        XCTAssertTrue(pack.text.contains("missing"))
        XCTAssertFalse(pack.text.contains("symptoms=none"))
    }

    func testExportActiveStrapOnly() {
        let row = WatchdogEpisodeLedgerRow(
            episodeId: "wd-x", deviceId: "other", openedUnix: 1, lastUnix: 2,
            maxSeverity: "severe", safety: true, personalOff: false,
            notifyDelivery: "sent", liveAlerts: true, offMinutes: [60])
        let pack = WatchdogClinicianExport.build(
            deviceId: "mine", startUnix: 0, endUnix: 10, ledger: [row],
            evaluations: [], dayLogs: [:], annotations: [], recovery: nil)
        XCTAssertTrue(pack.episodes.isEmpty)
        XCTAssertEqual(pack.offMinuteCount, 0)
    }

    func testExportDoesNotWriteLayer1() {
        var ev = quietEval()
        ev.nLong = 40
        let before = ev.nLong
        _ = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 1, ledger: [],
            evaluations: [ev], dayLogs: [:], annotations: [], recovery: nil)
        XCTAssertEqual(ev.nLong, before)
    }

    private func quietEval() -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: "2026-06-15", series: .sleepRHR, observations: [])
    }
}
