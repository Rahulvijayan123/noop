import XCTest
import WhoopStore
@testable import StrandAnalytics

/// When a stored day must be derived again, decided from the ledger and the newest heart-rate second alone.
final class ActivityContextMaterializationTests: XCTestCase {
    private typealias M = ActivityContextMaterialization

    /// 2025-10-09 00:00:00 UTC; every fixture day is exactly 24 h.
    private let day0 = 1_759_968_000
    private lazy var now = day0 + 10 * 86_400 + 15 * 3_600      // 15:00 on the tenth day after day0

    private func day(_ offset: Int) -> M.Day {
        let start = day0 + offset * 86_400
        return M.Day(key: "d\(offset)", start: start, end: start + 86_400)
    }

    /// A ledger as the v50 materializer writes it: stamped with the current feature schema, and `final` unless
    /// a test asks for a provisional one (a finished day confirmed after its sleep settled).
    private func ledger(_ d: M.Day, through: Int? = nil, computedAt: Int? = nil,
                        decoder: String = ActivityContextVersions.decoder,
                        finality: String = ActivityContextDayRow.final, configTag: String? = nil,
                        fingerprint: String? = nil) -> ActivityContextDayRow {
        ActivityContextDayRow(
            day: d.key, dayStart: d.start, dayEnd: d.end, taxonomyVersion: ActivityClassVersions.taxonomy,
            decoderVersion: decoder, ontologyVersion: ActivityContextVersions.ontology,
            intervalVersion: ActivityClassVersions.interval, dataThrough: through ?? d.end - 600,
            observedSeconds: 50_000, intervalCount: 200, computedAt: computedAt ?? d.end + 60,
            featureSchema: ActivityContextVersions.featureSchema, configTag: configTag,
            inputFingerprint: fingerprint, finality: finality)
    }

    private func candidate(_ d: M.Day, ledger: ActivityContextDayRow? = nil, newest: Int? = nil,
                           check: M.Check? = nil) -> M.Candidate {
        M.Candidate(day: d, ledger: ledger, newestHeartRateTs: newest, lastCheck: check)
    }

    // MARK: Single-day rules

    func testADayWithoutHeartRateHasNothingToDescribe() {
        XCTAssertFalse(M.needsWork(candidate(day(2)), now: now))
        XCTAssertFalse(M.needsWork(candidate(day(2), ledger: ledger(day(2))), now: now))
    }

    func testADayWithHeartRateAndNoLedgerNeedsWork() {
        let d = day(2)
        XCTAssertTrue(M.needsWork(candidate(d, newest: d.start + 3_000), now: now))
    }

    func testTheFutureIsNeverDerived() {
        let d = M.Day(key: "later", start: now + 3_600, end: now + 90_000)
        XCTAssertFalse(M.needsWork(candidate(d, newest: now + 4_000), now: now))
    }

    func testALedgerFromAnOlderRuleSetIsStale() {
        let d = day(2)
        let old = ledger(d, decoder: "hsmm-0.9")
        XCTAssertTrue(M.needsWork(candidate(d, ledger: old, newest: d.start + 3_000), now: now))
        XCTAssertFalse(M.needsWork(candidate(d, ledger: old), now: now), "still nothing to describe without heart rate")
    }

    func testAFinishedUpToDateDayIsLeftAlone() {
        let d = day(2)
        let done = ledger(d)
        XCTAssertFalse(M.needsWork(candidate(d, ledger: done, newest: done.dataThrough! - 5), now: now))
    }

    func testHeartRateBeyondTheDecodedHorizonIsNewData() {
        let d = day(2)
        let done = ledger(d, through: d.start + 40_000)
        XCTAssertTrue(M.needsWork(candidate(d, ledger: done, newest: d.start + 40_000), now: now),
                      "a sample at the horizon was not decoded: the horizon is one past the last second used")
        XCTAssertTrue(M.needsWork(candidate(d, ledger: done, newest: d.start + 60_000), now: now))
        XCTAssertFalse(M.needsWork(candidate(d, ledger: done, newest: d.start + 39_999), now: now))
    }

    func testTrailingSamplesTheDecoderIgnoresDoNotCauseEndlessWork() {
        // A heart-rate row the decoder drops (out of range) can sit past its horizon forever. Once this
        // process has looked at that exact tail, it does not look again until something newer arrives.
        let d = day(2)
        let done = ledger(d, through: d.start + 40_000)
        let looked = M.Check(at: now - 10, newestHeartRateTs: d.start + 40_500)
        XCTAssertFalse(M.needsWork(candidate(d, ledger: done, newest: d.start + 40_500, check: looked), now: now))
        XCTAssertTrue(M.needsWork(candidate(d, ledger: done, newest: d.start + 41_000, check: looked), now: now))
    }

    func testADayWrittenWhileLiveIsDerivedOnceItHasClosed() {
        let d = day(2)
        let live = ledger(d, through: d.end - 120, computedAt: d.end - 120)
        XCTAssertTrue(M.needsWork(candidate(d, ledger: live, newest: d.end - 121), now: now))
        // Looked at after it closed: the finished-day pass has happened, however it came out.
        let closed = M.Check(at: d.end + 30, newestHeartRateTs: d.end - 121)
        XCTAssertFalse(M.needsWork(candidate(d, ledger: live, newest: d.end - 121, check: closed), now: now))
        // A day that is still running is not "closed" yet.
        let running = day(10)
        let runningLedger = ledger(running, through: now - 60, computedAt: now - 60)
        XCTAssertFalse(M.needsWork(candidate(running, ledger: runningLedger, newest: now - 61,
                                             check: M.Check(at: now - 60, newestHeartRateTs: now - 61)), now: now))
    }

    func testRecentDaysAreReReadOnAScheduleAndOldDaysAreNot() {
        let config = M.Config()
        let recent = day(10)
        let fresh = ledger(recent, through: now - 30, computedAt: now - 30)
        let newest = now - 31
        XCTAssertFalse(M.needsWork(candidate(recent, ledger: fresh, newest: newest), now: now, config: config))
        let later = now + config.recheckIntervalS
        XCTAssertTrue(M.needsWork(candidate(recent, ledger: fresh, newest: newest), now: later, config: config),
                      "sleep, workouts and wrist events may have changed since it was derived")
        let seen = M.Check(at: later - 60, newestHeartRateTs: newest)
        XCTAssertFalse(M.needsWork(candidate(recent, ledger: fresh, newest: newest, check: seen), now: later, config: config),
                       "a look a minute ago counts, even if it found nothing to change")

        let old = day(2)
        let oldLedger = ledger(old)
        XCTAssertFalse(M.needsWork(candidate(old, ledger: oldLedger, newest: oldLedger.dataThrough! - 1), now: later + 86_400 * 30, config: config))
    }

    // MARK: Invalidation (spec §13): late backfills to old days' non-HR streams

    func testALateBackfillToAnOldDaysInputOutsideTheRecencyWindowRechecks() {
        let old = day(2)   // 8 days before now; far outside the 36 h recent window
        let done = ledger(old)
        let newest = done.dataThrough! - 1
        let looked = M.Check(at: now - 60, newestHeartRateTs: newest, inputFingerprint: "v3|g120|z45")
        // Same HR horizon, but the tracked input fingerprint moved: a late IMU/step/wear backfill landed
        // inside the covered span without producing a new heart-rate row. The old day must be re-examined
        // even though it is not recent (WS-10-F03).
        let c = M.Candidate(day: old, ledger: done, newestHeartRateTs: newest, lastCheck: looked,
                            inputFingerprint: "v3|g121|z45", storedInputFingerprint: "v3|g120|z45")
        XCTAssertTrue(M.needsWork(c, now: now))
    }

    func testAnInputFingerprintThatNoLongerMatchesTheLedgerRecordRechecks() {
        let old = day(2)
        let done = ledger(old)
        let newest = done.dataThrough! - 1
        // No lastCheck (the process restarted); the ledger recorded an older input fingerprint than the
        // streams now hold, so the day is flagged even though no heart-rate row moved.
        let c = M.Candidate(day: old, ledger: done, newestHeartRateTs: newest,
                            inputFingerprint: "v4|g300", storedInputFingerprint: "v3|g120")
        XCTAssertTrue(M.needsWork(c, now: now))
    }

    func testAnUnchangedInputFingerprintLeavesAnOldDayAlone() {
        let old = day(2)
        let done = ledger(old)
        let newest = done.dataThrough! - 1
        let looked = M.Check(at: now - 60, newestHeartRateTs: newest, inputFingerprint: "v3|g120|z45")
        let c = M.Candidate(day: old, ledger: done, newestHeartRateTs: newest, lastCheck: looked,
                            inputFingerprint: "v3|g120|z45", storedInputFingerprint: "v3|g120|z45")
        XCTAssertFalse(M.needsWork(c, now: now), "unchanged input is not re-derived every pass")
    }

    func testAFingerprintMismatchConvergesOnceTheDayIsReDerived() {
        let old = day(2)
        let done = ledger(old)
        let newest = done.dataThrough! - 1
        let c = M.Candidate(day: old, ledger: done, newestHeartRateTs: newest,
                            inputFingerprint: "v4|g300", storedInputFingerprint: "v3|g120")
        XCTAssertTrue(M.needsWork(c, now: now))
        // The pass re-derived the day and wrote back the fingerprint it saw; the same input asks for
        // nothing further, so the mismatch route can never re-decode the day every pass.
        let settled = M.Candidate(day: old, ledger: done, newestHeartRateTs: newest,
                                  lastCheck: M.Check(at: now, newestHeartRateTs: newest, inputFingerprint: "v4|g300"),
                                  inputFingerprint: "v4|g300", storedInputFingerprint: "v4|g300")
        XCTAssertFalse(M.needsWork(settled, now: now))
    }

    // MARK: v50: derivation key, persisted fingerprint, finality

    func testAChangedDecoderConfigMakesADayStaleAndItReplansThroughTheBacklog() {
        let config = "r55m190-eg01b2"
        let all = (0...10).map { i -> M.Candidate in
            let d = day(i)
            return M.Candidate(day: d, ledger: ledger(d, configTag: config), newestHeartRateTs: d.end - 700,
                               configTag: config)
        }
        XCTAssertTrue(M.plan(all, now: now).filter { !M.isRecent($0, now: now) }.isEmpty, "the same config asks for nothing old")
        let changed = all.map { c -> M.Candidate in var c = c; c.configTag = "r52m190-eg01b2"; return c }
        let plan = M.plan(changed, now: now)
        XCTAssertEqual(plan.filter { !M.isRecent($0, now: now) }.count, M.Config().maxBacklogPerPass,
                       "a new HR reference re-derives old days, two per pass")
        XCTAssertFalse(M.needsWork(M.Candidate(day: day(2), ledger: ledger(day(2), configTag: config),
                                               newestHeartRateTs: day(2).end - 700), now: now),
                       "a caller that does not pass a tag does not compare it")
    }

    func testALedgerWrittenBeforeItRecordedItsFeatureSchemaIsDerivedAgain() {
        let d = day(2)
        var legacy = ledger(d)
        legacy.featureSchema = nil
        XCTAssertTrue(M.needsWork(candidate(d, ledger: legacy, newest: d.end - 700), now: now))
        legacy.featureSchema = "feat-0"
        XCTAssertTrue(M.needsWork(candidate(d, ledger: legacy, newest: d.end - 700), now: now))
    }

    func testTheLedgersOwnFingerprintCatchesAnOldDaysBackfillAfterARelaunch() {
        // D5-05: the fingerprint the day was derived from is in its ledger, so a relaunched process (no
        // lastCheck) still sees that the input moved.
        let old = day(2)
        let done = ledger(old, fingerprint: "acx1|a|sl1|wk1|enc[]")
        let newest = done.dataThrough! - 1
        XCTAssertTrue(M.needsWork(M.Candidate(day: old, ledger: done, newestHeartRateTs: newest,
                                              inputFingerprint: "acx1|a|sl2|wk1|enc[]"), now: now),
                      "a re-staged night under an unchanged HR horizon")
        XCTAssertFalse(M.needsWork(M.Candidate(day: old, ledger: done, newestHeartRateTs: newest,
                                               inputFingerprint: "acx1|a|sl1|wk1|enc[]"), now: now))
    }

    func testNewEncoderWindowsForARecentDayDoNotWaitForTheRecheckInterval() {
        let recent = day(10)   // today
        let newest = now - 120
        let fresh = ledger(recent, through: newest + 1, computedAt: now - 60, finality: ActivityContextDayRow.provisional,
                           fingerprint: M.inputFingerprint(store: "s", configTag: "t"))
        let looked = M.Check(at: now - 60, newestHeartRateTs: newest, inputFingerprint: fresh.inputFingerprint)
        let unchanged = M.Candidate(day: recent, ledger: fresh, newestHeartRateTs: newest, lastCheck: looked,
                                    inputFingerprint: fresh.inputFingerprint)
        XCTAssertFalse(M.needsWork(unchanged, now: now), "looked a minute ago, nothing new")
        var arrived = unchanged
        arrived.inputFingerprint = M.inputFingerprint(store: "s", encoderRevisions: [String(recent.key): "rev-7"], configTag: "t")
        XCTAssertTrue(M.needsWork(arrived, now: now), "HART windows for the day bypass the 30-minute throttle")
    }

    func testAProvisionalDayIsConfirmedOnceItsSleepHasSettled() {
        let d = day(9)   // yesterday
        let early = d.end + 3_600
        let row = ledger(d, through: d.end - 600, computedAt: d.end + 300, finality: ActivityContextDayRow.provisional)
        let c = candidate(d, ledger: row, newest: d.end - 700)
        XCTAssertFalse(M.needsWork(c, now: early, config: { var k = M.Config(); k.recentWindowS = 0; return k }()),
                       "before the night is settled there is nothing to confirm")
        let settled = d.end + ActivityContextPersistence.sleepSettleS
        var noRecent = M.Config()
        noRecent.recentWindowS = 0
        XCTAssertTrue(M.needsWork(c, now: settled, config: noRecent))
        let looked = M.Check(at: settled, newestHeartRateTs: d.end - 700)
        XCTAssertFalse(M.needsWork(candidate(d, ledger: row, newest: d.end - 700, check: looked), now: settled + 60, config: noRecent),
                       "looked at once after settling: not again this launch")
        let confirmed = ledger(d, through: d.end - 600, computedAt: d.end + 300, finality: ActivityContextDayRow.final)
        XCTAssertFalse(M.needsWork(candidate(d, ledger: confirmed, newest: d.end - 700), now: settled + 86_400, config: noRecent))
    }

    func testTheInputFingerprintNamesEveryNonStoreInput() {
        let base = M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "b"],
                                      gaitRevisions: ["2026-10-07": "g"], configTag: "r55", dismissedWorkouts: "")
        XCTAssertEqual(base, M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-07": "b", "2026-10-06": "a"],
                                                gaitRevisions: ["2026-10-07": "g"], configTag: "r55"),
                       "revision order does not matter")
        let variants = [
            M.inputFingerprint(store: "s2", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "b"], gaitRevisions: ["2026-10-07": "g"], configTag: "r55"),
            M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "c"], gaitRevisions: ["2026-10-07": "g"], configTag: "r55"),
            M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "b"], gaitRevisions: [:], configTag: "r55"),
            M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "b"], gaitRevisions: ["2026-10-07": "g"], configTag: "r52"),
            M.inputFingerprint(store: "s", encoderRevisions: ["2026-10-06": "a", "2026-10-07": "b"], gaitRevisions: ["2026-10-07": "g"], configTag: "r55", dismissedWorkouts: "1-2"),
        ]
        for v in variants { XCTAssertNotEqual(v, base) }
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testDaysThatLostTheirHeartRateAreOrphaned() {
        let days = (0...4).map(day)
        let orphans = M.orphanedDays(days, ledgerDays: [day(1).start, day(2).start, day(3).start],
                                     owned: [day(2).start, day(4).start])
        XCTAssertEqual(orphans.map(\.key), ["d1", "d3"])
    }

    func testAFailedOwnerProbeOrphansNothingThatPass() {
        let days = (0...4).map(day)
        let ledgers: Set<Int> = [day(1).start, day(2).start, day(3).start]
        // d3's probe threw: it is not "no heart rate", and neither is any other day trusted this pass.
        XCTAssertEqual(M.orphanedDays(days, ledgerDays: ledgers, owned: [day(2).start], unanswered: [day(3).start]).map(\.key), [])
        XCTAssertEqual(M.orphanedDays(days, ledgerDays: ledgers, owned: [day(2).start], unanswered: []).map(\.key),
                       ["d1", "d3"])
    }

    // MARK: Planning

    func testTheNewestDaysComeFirstAndOldWorkIsMetered() {
        // Ten days, none materialized: today and yesterday are recent (no limit), the rest are backlog.
        let all = (0...10).map { candidate(day($0), newest: day($0).start + 5_000) }
        let plan = M.plan(all, now: now)
        XCTAssertEqual(plan.map(\.key), ["d10", "d9", "d8", "d7"], "two recent days, then two days of backlog, newest first")
    }

    func testBacklogDrainsAcrossPasses() {
        var candidates = (0...10).map { candidate(day($0), newest: day($0).start + 5_000) }
        var order: [String] = []
        for _ in 0..<8 {
            let plan = M.plan(candidates, now: now)
            if plan.isEmpty { break }
            order += plan.map(\.key)
            for d in plan {
                let i = candidates.firstIndex { $0.day == d }!
                // Derived: the ledger now covers the day, and this process has looked at it.
                let done = ledger(d, through: d.start + 6_000, computedAt: now - 1)
                candidates[i] = candidate(d, ledger: done, newest: d.start + 5_000,
                                          check: M.Check(at: now, newestHeartRateTs: d.start + 5_000))
            }
        }
        XCTAssertEqual(Set(order).count, 11, "every day with data is eventually derived")
        XCTAssertEqual(order.count, 11, "and none is derived twice")
        XCTAssertTrue(M.plan(candidates, now: now).isEmpty, "a settled database asks for nothing")
    }

    func testRecentDaysAreNeverCrowdedOutByTheBacklog() {
        let all = (0...10).map { candidate(day($0), newest: day($0).start + 5_000) }
        var config = M.Config()
        config.maxBacklogPerPass = 0
        let plan = M.plan(all, now: now, config: config)
        XCTAssertEqual(plan.map(\.key), ["d10", "d9"], "with no backlog budget, today and yesterday still run")
    }

    func testDaysWithNoDataAreSkippedAndDoNotUseTheBacklogBudget() {
        let empty = (3...8).map { candidate(day($0)) }
        let real = [candidate(day(2), newest: day(2).start + 100), candidate(day(1), newest: day(1).start + 100)]
        let plan = M.plan(empty + real, now: now)
        XCTAssertEqual(plan.map(\.key), ["d2", "d1"])
    }

    // MARK: Does the stored day already equal this document?

    private func document(through: Int?, generatedAt: Int, dayStart: Int) -> ActivityContextDayDocument {
        var sim = ActivitySim(start: dayStart)
        sim.desk(120)
        let input = sim.trackInput(start: dayStart, end: dayStart + 86_400)
        let track = ActivityContextTrackBuilder.build(input)
        var doc = ActivityContextDayDocument(track: track, input: input, generatedAt: generatedAt)
        doc.dataThrough = through
        return doc
    }

    func testALedgerCoversTheDocumentItWasMadeFrom() {
        let d = day(2)
        let doc = document(through: d.start + 5_000, generatedAt: 777, dayStart: d.start)
        let row = ActivityContextPersistence.dayRow(day: d.key, document: doc, intervalCount: 5,
                                                    computedAt: doc.generatedAt, dayEnd: d.end)
        XCTAssertTrue(M.covers(row, document: doc))
        XCTAssertEqual(row.dayEnd, d.end, "the ledger carries the local day, not where decoding stopped")
        XCTAssertEqual(row.dataThrough, d.start + 5_000)

        var newer = doc
        newer.generatedAt = 778
        XCTAssertFalse(M.covers(row, document: newer), "a document decoded again is a different one, even if it reaches as far")
        var longer = doc
        longer.dataThrough = d.start + 5_300
        XCTAssertFalse(M.covers(row, document: longer))
        XCTAssertFalse(M.covers(nil, document: doc))
        var stale = row
        stale.intervalVersion = "ctx-int-0"
        XCTAssertFalse(M.covers(stale, document: doc), "a ledger from older interval rules never covers anything")
    }

    func testTheLedgerHorizonNeverRunsPastTheLocalDay() {
        let d = day(2)
        let doc = document(through: d.end + 3_600, generatedAt: 5, dayStart: d.start)
        let row = ActivityContextPersistence.dayRow(day: d.key, document: doc, intervalCount: 0,
                                                    computedAt: 5, dayEnd: d.end)
        XCTAssertEqual(row.dataThrough, d.end, "a 23-hour day's decode reaches an hour into the next one")
        XCTAssertTrue(M.covers(row, document: doc))
    }

    // MARK: Local days

    private func epoch(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        return Int(date.timeIntervalSince1970)
    }

    func testLocalDaysRunNewestFirstFromMidnightToMidnight() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = epoch(2026, 10, 4, 15, in: la)
        let days = M.localDays(endingAt: now, count: 3, timeZone: la)
        XCTAssertEqual(days.map(\.key), ["2026-10-04", "2026-10-03", "2026-10-02"])
        XCTAssertEqual(days[0].start, epoch(2026, 10, 4, 0, in: la))
        XCTAssertEqual(days[0].end, epoch(2026, 10, 5, 0, in: la))
        XCTAssertEqual(days[1].end, days[0].start, "days tile the timeline without a gap or an overlap")
        XCTAssertEqual(days[2].end, days[1].start)
        XCTAssertTrue(days[0].start <= now && now < days[0].end)
    }

    func testLocalDaysFollowDaylightSavingInBothDirections() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let fall = M.localDays(endingAt: epoch(2026, 11, 2, 12, in: la), count: 3, timeZone: la)
        XCTAssertEqual(fall.map(\.key), ["2026-11-02", "2026-11-01", "2026-10-31"])
        XCTAssertEqual(fall[1].end - fall[1].start, 25 * 3_600, "the clocks went back")
        XCTAssertEqual(fall[0].end - fall[0].start, 24 * 3_600)

        let spring = M.localDays(endingAt: epoch(2026, 3, 9, 12, in: la), count: 3, timeZone: la)
        XCTAssertEqual(spring.map(\.key), ["2026-03-09", "2026-03-08", "2026-03-07"])
        XCTAssertEqual(spring[1].end - spring[1].start, 23 * 3_600, "the clocks went forward")
    }

    func testLocalDayKeysIgnoreAZoneOffsetAheadOfUtcAndANonPositiveCount() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = epoch(2026, 1, 1, 1, in: tokyo)
        XCTAssertEqual(M.localDays(endingAt: now, count: 2, timeZone: tokyo).map(\.key), ["2026-01-01", "2025-12-31"])
        XCTAssertTrue(M.localDays(endingAt: now, count: 0, timeZone: tokyo).isEmpty)
        XCTAssertTrue(M.localDays(endingAt: now, count: -4, timeZone: tokyo).isEmpty)
    }

    // MARK: Resting heart rate

    func testTypicalRestingHeartRateIsTheMedianOfTheLatestNights() {
        XCTAssertNil(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: []))
        XCTAssertNil(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: [52, nil, 54]), "two nights is too thin")
        XCTAssertEqual(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: [52, 54, 50]), 52)
        XCTAssertEqual(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: [50, 52, 54, 56]), 53, "even count averages the middle pair")
        let long: [Int?] = (0..<30).map { $0 < 16 ? 80 : 50 }
        XCTAssertEqual(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: long), 50, "only the latest 14 nights count")
        let gaps: [Int?] = [80, nil, nil, 50, 51, nil, 49]
        XCTAssertEqual(ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: gaps), 50.5, "missing nights are skipped, not counted")
    }
}
