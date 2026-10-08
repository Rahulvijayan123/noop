import XCTest
import GRDB
@testable import WhoopStore

/// v50-activity-context-provenance: the ledger's derivation key and finality, the interval run fields, durable
/// transition events, the atomic owner hand-off, the decode-input witness, the owner-joined views and the
/// timestamped spot HRV readings.
private extension WhoopStore {
    func provenanceExecForTest(_ sql: String, _ arguments: StatementArguments) throws {
        try syncWrite { db in try db.execute(sql: sql, arguments: arguments) }
    }

    func provenanceRowsForTest(_ sql: String, _ arguments: StatementArguments) throws -> [Row] {
        try syncRead { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
    }
}

final class ActivityContextProvenanceStoreTests: XCTestCase {
    private let dev = "strap-a"
    private let day0: Int = 1_760_000_000

    private func interval(_ start: Int, _ length: Int, _ cls: String = "sitting") -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: start + length, activityClass: cls, confidence: 0.8)
    }

    private func ledger(_ dayStart: Int, through: Int? = nil, finality: String = ActivityContextDayRow.provisional,
                        fingerprint: String? = nil) -> ActivityContextDayRow {
        ActivityContextDayRow(day: "2025-10-09", dayStart: dayStart, dayEnd: dayStart + 86_400,
                              taxonomyVersion: "act-class-1", decoderVersion: "hsmm-1.9", ontologyVersion: "v2.0",
                              intervalVersion: "ctx-int-1", dataThrough: through ?? dayStart + 86_400,
                              observedSeconds: 1_000, computedAt: 7, inputFingerprint: fingerprint,
                              finality: finality)
    }

    private func exec(_ store: WhoopStore, _ sql: String, _ args: StatementArguments = StatementArguments()) async throws {
        try await store.provenanceExecForTest(sql, args)
    }

    private func rows(_ store: WhoopStore, _ sql: String, _ args: StatementArguments = StatementArguments()) async throws -> [Row] {
        try await store.provenanceRowsForTest(sql, args)
    }

    private func count(_ store: WhoopStore, _ table: String, _ id: String) async throws -> Int {
        try await rows(store, "SELECT COUNT(*) AS n FROM \(table) WHERE deviceId = ?", [id]).first?["n"] ?? 0
    }

    // MARK: Ledger provenance

    func testTheLedgerRoundTripsItsDerivationKeyAndStatus() async throws {
        let store = try await WhoopStore.inMemory()
        var row = ledger(day0, finality: ActivityContextDayRow.final, fingerprint: "fp-1")
        row.featureSchema = "acx-feat-3"
        row.encoderId = "hart"
        row.encoderVersion = "hart-v1.2"
        row.motionHeads = "inertia-1:abc:def"
        row.gaitQuality = "eldernet:437a38b:01b2f982a0a2:ffff"
        row.configTag = "r55m190-eg01b2"
        row.sleepKnownOutsideSessions = true
        try await store.replaceActivityContext(deviceId: dev, day: row, intervals: [interval(day0 + 10, 60)])
        let back = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        var expected = row
        expected.intervalCount = 1
        XCTAssertEqual(back, expected)
        XCTAssertEqual(back?.isFinal, true)
        XCTAssertEqual(back?.decodeMode, "causal")
    }

    func testAPreV50DatabaseUpgradesWithConservativeDefaults() throws {
        let dbq = try DatabaseQueue()
        let d0 = day0
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v49-rr-diff-components")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO activityContextDay (deviceId, dayStart, day, dayEnd, taxonomyVersion, decoderVersion,
                    ontologyVersion, intervalVersion, dataThrough, computedAt)
                VALUES ('strap-a', ?, '2025-10-09', ?, 'act-class-1', 'hsmm-1.9', 'v2.0', 'ctx-int-1', ?, 1)
                """, arguments: [d0, d0 + 86_400, d0 + 86_400])
            try db.execute(sql: """
                INSERT INTO activityContextInterval (deviceId, startTs, endTs, activityClass, confidence, sleepState, wearState)
                VALUES ('strap-a', ?, ?, 'sitting', 0.5, 'awake', 'on_wrist')
                """, arguments: [d0, d0 + 600])
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap-a', ?, 61)", arguments: [d0 + 30])
        }
        try WhoopStore.makeMigrator().migrate(dbq)
        try dbq.read { db in
            let day = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM activityContextDay"))
            XCTAssertEqual(day["finality"] as String, "provisional", "an old row cannot claim to be final")
            XCTAssertEqual(day["decodeMode"] as String, "causal")
            XCTAssertNil(day["featureSchema"] as String?)
            XCTAssertNil(day["configTag"] as String?)
            XCTAssertNil(day["inputFingerprint"] as String?)
            let iv = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM activityContextInterval"))
            XCTAssertNil(iv["transitionCount"] as Int?, "an old row did not record its transitions: unknown, not none")
            XCTAssertNil(iv["absorbedSeconds"] as Int?)
            XCTAssertNil(iv["inBed"] as Int?)
            let ctx = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT ctxClass, ctxDecoderVersion, ctxProvisional FROM hrSampleCtx"))
            XCTAssertEqual(ctx["ctxClass"] as String?, "sitting", "the rebuilt views still join the old rows")
            XCTAssertEqual(ctx["ctxDecoderVersion"] as String?, "hsmm-1.9")
            XCTAssertEqual(ctx["ctxProvisional"] as Int?, 1)
        }
    }

    func testIntervalRunFieldsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        var row = interval(day0 + 100, 300, "lying_down")
        row.inBed = true
        row.uncertainty = 0.31
        row.experts = "hart,eldernet"
        row.transitionCount = 2
        row.absorbedSeconds = 9
        row.precededByGapS = 45
        row.settlingSeconds = 60
        row.absorbedClasses = "sitting,light_activity"
        row.detail = "in_vehicle"
        row.detailConfidence = 0.74
        row.precedingClass = "walking"
        row.settledFromTs = day0 + 220
        row.hrMeanSettled = 61.5
        row.hrSamplesSettled = 178
        row.rmssdSettled = 48.2
        row.rrDiffSqSumMs2Settled = 395_123.25
        row.rrDiffCountSettled = 170
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [row, interval(day0 + 400, 60)])
        let back = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(back.first, row)
        let at = try await store.activityContextInterval(deviceId: dev, at: day0 + 150)
        XCTAssertEqual(at, row, "the as-of read carries the same columns")
        XCTAssertNil(back.last?.inBed, "a row the builder did not fill reads as not recorded")
        XCTAssertNil(back.last?.transitionCount, "not recorded is not the same as no transitions")
        XCTAssertNil(back.last?.absorbedSeconds)
        XCTAssertNil(back.last?.absorbedClasses)
        XCTAssertNil(back.last?.detail)
        XCTAssertNil(back.last?.precedingClass)
        XCTAssertNil(back.last?.settledFromTs)
        XCTAssertNil(back.last?.hrMeanSettled)
        XCTAssertNil(back.last?.rmssdSettled)
        var none = interval(day0 + 500, 60)
        none.transitionCount = 0
        none.absorbedSeconds = 0
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [row, none])
        let zero = try await store.activityContextIntervals(deviceId: dev, from: day0 + 500, to: day0 + 560)
        XCTAssertEqual(zero.first?.transitionCount, 0, "a recorded zero stays a zero")
        XCTAssertEqual(zero.first?.absorbedSeconds, 0)
    }

    // MARK: Transition events

    private func event(_ ts: Int, _ kind: String = "sit_to_stand_like", p: Double = 0.8) -> ActivityContextTransitionRow {
        ActivityContextTransitionRow(ts: ts, kind: kind, probability: p, decoderVersion: "hsmm-1.9")
    }

    func testTransitionEventsAreWrittenWithTheirDayAndReplacedWithIt() async throws {
        let store = try await WhoopStore.inMemory()
        let a = event(day0 + 130), b = event(day0 + 140, "stand_to_sit_like", p: 0.6)
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0 + 100, 300)],
                                               transitions: [a, b])
        let first = try await store.activityContextTransitions(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(first, [a, b])
        XCTAssertNil(first[0].onsetTs)
        XCTAssertNil(first[0].source)

        // A neighbouring day's events are not touched by replacing this one.
        let next = day0 + 86_400
        var nextLedger = ledger(next)
        nextLedger.day = "2025-10-10"
        try await store.replaceActivityContext(deviceId: dev, day: nextLedger, intervals: [], transitions: [event(next + 5)])

        let c = ActivityContextTransitionRow(ts: day0 + 900, kind: "posture_shift", probability: 0.7, onsetTs: day0 + 896,
                                             source: "transition_expert", decoderVersion: "hsmm-1.9")
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0 + 100, 300)],
                                               transitions: [c])
        let second = try await store.activityContextTransitions(deviceId: dev, from: day0, to: day0 + 2 * 86_400)
        XCTAssertEqual(second, [c, event(next + 5)], "the day's old events are replaced, the next day's kept")
    }

    func testAnEventOutsideTheDayIsRejectedBeforeAnythingIsWritten() async throws {
        let store = try await WhoopStore.inMemory()
        do {
            try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 60)],
                                                   transitions: [event(day0 + 86_400 + 5)])
            XCTFail("expected a throw")
        } catch let error as ActivityContextStoreError {
            XCTAssertEqual(error, .transitionOutsideDay(ts: day0 + 86_400 + 5))
        }
        let n1 = try await count(store, "activityContextInterval", dev)
        XCTAssertEqual(n1, 0)
        let n2 = try await count(store, "activityContextDay", dev)
        XCTAssertEqual(n2, 0)
    }

    func testTransitionsInsideAnIntervalAreCountedHalfOpen() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(
            deviceId: dev, day: ledger(day0),
            intervals: [interval(day0 + 100, 100), interval(day0 + 200, 100, "standing")],
            transitions: [event(day0 + 100), event(day0 + 150, p: 0.2), event(day0 + 200), event(day0 + 299)])
        let inFirst = try await store.activityContextTransitionCount(deviceId: dev, from: day0 + 100, to: day0 + 200)
        XCTAssertEqual(inFirst, 2, "the start second counts, the end second belongs to the next interval")
        let confident = try await store.activityContextTransitionCount(deviceId: dev, from: day0 + 100, to: day0 + 200,
                                                                       minProbability: 0.5)
        XCTAssertEqual(confident, 1)
        let view = try await rows(store, "SELECT startTs, transitionEvents FROM \(ActivityContextViews.intervalTransitionsView) WHERE deviceId = ? ORDER BY startTs", [dev])
        XCTAssertEqual(view.map { $0["transitionEvents"] as Int }, [2, 2])
    }

    // MARK: Owner hand-off

    func testHandingADayToAnotherOwnerClearsTheOldOwnerInTheSameWrite() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: "strap-b", day: ledger(day0), intervals: [interval(day0, 600, "running")],
                                               transitions: [event(day0 + 10)])
        // Outside the day: untouched.
        try await store.replaceActivityContext(deviceId: "strap-b", day: ledger(day0 + 86_400), intervals: [interval(day0 + 86_400, 60)])

        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 600)],
                                               clearingOtherIds: ["strap-b", dev])
        let b = try await store.activityContextIntervals(deviceId: "strap-b", from: day0, to: day0 + 2 * 86_400)
        XCTAssertEqual(b.map(\.startTs), [day0 + 86_400])
        let bEvents = try await store.activityContextTransitions(deviceId: "strap-b", from: day0, to: day0 + 86_400)
        XCTAssertTrue(bEvents.isEmpty)
        let bLedgers = try await rows(store, "SELECT dayStart FROM activityContextDay WHERE deviceId = 'strap-b'").map { $0["dayStart"] as Int }
        XCTAssertEqual(bLedgers, [day0 + 86_400])
        let a = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(a.count, 1, "naming the owner among the others never clears its own new rows")
    }

    func testAFailedHandOffLeavesTheOldOwnerInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: "strap-b", day: ledger(day0), intervals: [interval(day0, 600, "running")])
        // Make the new owner's ledger write fail inside the transaction, after the old owner's rows were deleted.
        try await exec(store, """
            CREATE TRIGGER failNewOwner BEFORE INSERT ON activityContextDay WHEN NEW.deviceId = 'strap-a'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        do {
            try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 600)],
                                                   clearingOtherIds: ["strap-b"])
            XCTFail("expected the injected failure")
        } catch {}
        let b = try await store.activityContextIntervals(deviceId: "strap-b", from: day0, to: day0 + 86_400)
        XCTAssertEqual(b.map(\.activityClass), ["running"], "the old owner still describes the day")
        let n3 = try await count(store, "activityContextDay", "strap-b")
        XCTAssertEqual(n3, 1)
        let n4 = try await count(store, "activityContextInterval", dev)
        XCTAssertEqual(n4, 0, "and the new owner wrote nothing")
    }

    func testClearingSeveralIdsIsOneWrite() async throws {
        let store = try await WhoopStore.inMemory()
        for id in [dev, "strap-b"] {
            try await store.replaceActivityContext(deviceId: id, day: ledger(day0), intervals: [interval(day0, 60)],
                                                   transitions: [event(day0 + 5)])
        }
        try await store.clearActivityContext(deviceIds: [dev, "strap-b"], from: day0, to: day0 + 86_400)
        for id in [dev, "strap-b"] {
            let n5 = try await count(store, "activityContextInterval", id)
            XCTAssertEqual(n5, 0)
            let n6 = try await count(store, "activityContextDay", id)
            XCTAssertEqual(n6, 0)
            let n7 = try await count(store, "activityContextTransition", id)
            XCTAssertEqual(n7, 0)
        }
    }

    func testUpdatingADaysStatusTouchesOnlyTheFingerprintAndFinality() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, fingerprint: "old"), intervals: [interval(day0, 60)])
        let before = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        let updated = try await store.updateActivityContextDayStatus(deviceId: dev, dayStart: day0, inputFingerprint: "new",
                                                                     finality: ActivityContextDayRow.final)
        XCTAssertTrue(updated)
        let after = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        var expected = try XCTUnwrap(before)
        expected.inputFingerprint = "new"
        expected.finality = "final"
        XCTAssertEqual(after, expected)
        let missing = try await store.updateActivityContextDayStatus(deviceId: dev, dayStart: day0 + 1, inputFingerprint: "x",
                                                                     finality: "final")
        XCTAssertFalse(missing)
    }

    // MARK: Views

    func testViewsCarryTheDaysDecoderVersionAndWhetherTheContextCanStillChange() async throws {
        let store = try await WhoopStore.inMemory()
        let next = day0 + 86_400
        // A final day, decoded through +1000: an interval inside the decoded span is final, one reaching past it not.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, through: day0 + 1_000, finality: "final"),
                                               intervals: [interval(day0, 600), interval(day0 + 600, 600, "walking")])
        // A provisional (live) day: everything is provisional.
        var live = ledger(next, finality: "provisional")
        live.day = "2025-10-10"
        try await store.replaceActivityContext(deviceId: dev, day: live, intervals: [interval(next, 600)])
        for ts in [day0 + 10, day0 + 700, next + 10, next + 5_000] {
            try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, 60)", [dev, ts])
        }
        let got = try await rows(store, "SELECT ts, ctxDecoderVersion, ctxProvisional FROM hrSampleCtx WHERE deviceId = ? ORDER BY ts", [dev])
        XCTAssertEqual(got.map { $0["ctxProvisional"] as Int? }, [0, 1, 1, nil])
        XCTAssertEqual(got.map { $0["ctxDecoderVersion"] as String? }, ["hsmm-1.9", "hsmm-1.9", "hsmm-1.9", nil],
                       "a sample with no covering interval carries no context at all")
    }

    func testViewsCarryTheIntervalsInBedUncertaintyAndDetail() async throws {
        let store = try await WhoopStore.inMemory()
        var drive = interval(day0, 600)
        drive.detail = "in_vehicle"
        drive.uncertainty = 0.42
        drive.inBed = false
        var bed = interval(day0 + 600, 600, "lying_down")
        bed.inBed = true
        bed.uncertainty = 0.18
        let legacy = interval(day0 + 1_200, 600)
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [drive, bed, legacy])
        for ts in [day0 + 10, day0 + 700, day0 + 1_300, day0 + 5_000] {
            try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, 60)", [dev, ts])
        }
        let got = try await rows(store, "SELECT ctxClass, ctxDetail, ctxInBed, ctxUncertainty FROM hrSampleCtx "
                                     + "WHERE deviceId = ? ORDER BY ts", [dev])
        XCTAssertEqual(got.map { $0["ctxClass"] as String? }, ["sitting", "lying_down", "sitting", nil])
        XCTAssertEqual(got.map { $0["ctxDetail"] as String? }, ["in_vehicle", nil, nil, nil],
                       "a drive never groups with plain sitting")
        XCTAssertEqual(got.map { $0["ctxInBed"] as Int? }, [0, 1, nil, nil])
        XCTAssertEqual(got.map { $0["ctxUncertainty"] as Double? }, [0.42, 0.18, nil, nil])
    }

    func testTheOwnerJoinedViewAgreesWithABruteForceLookupAcrossTwoIds() async throws {
        let store = try await WhoopStore.inMemory()
        var generator = SystemRandomNumberGenerator()
        // Day 0 owned by strap-a, day 1 by strap-b; samples under both ids on both days.
        var expected: [String: [ActivityContextIntervalRow]] = [:]
        for (i, owner) in [dev, "strap-b"].enumerated() {
            let start = day0 + i * 86_400
            var cursor = start, list: [ActivityContextIntervalRow] = []
            while cursor < start + 86_000 {
                cursor += Int.random(in: 0...300, using: &generator)
                let length = Int.random(in: 1...900, using: &generator)
                guard cursor + length <= start + 86_400 else { break }
                list.append(interval(cursor, length, ["sitting", "walking", "standing"][list.count % 3]))
                cursor += length
            }
            var day = ledger(start)
            day.day = i == 0 ? "2025-10-09" : "2025-10-10"
            try await store.replaceActivityContext(deviceId: owner, day: day, intervals: list)
            expected[owner] = list
        }
        let all = (expected[dev] ?? []) + (expected["strap-b"] ?? [])
        var samples: [(String, Int)] = []
        for id in [dev, "strap-b"] {
            var seen = Set<Int>()
            while seen.count < 800 { seen.insert(Int.random(in: (day0 - 300)...(day0 + 2 * 86_400 + 300), using: &generator)) }
            samples += seen.map { (id, $0) }
        }
        for (id, ts) in samples {
            try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, 60)", [id, ts])
        }
        let got = try await rows(store, "SELECT deviceId, ts, ctxClass, ctxStartTs FROM hrSampleCtx")
        XCTAssertEqual(got.count, samples.count)
        var mismatches = 0
        for row in got {
            let ts: Int = row["ts"]
            let want = all.first { $0.startTs <= ts && ts < $0.endTs }
            if (row["ctxStartTs"] as Int?) != want?.startTs || (row["ctxClass"] as String?) != want?.activityClass {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: Decode-input witness

    func testTheInputFingerprintSeesEveryInputTheDecodeReads() async throws {
        let store = try await WhoopStore.inMemory()
        let ids = [dev, "strap-b"], sleepIds = [dev, "strap-a-noop"], workoutIds = [dev, "apple-health"]
        func fp() async throws -> String {
            try await store.activityContextInputFingerprint(streamIds: ids, sleepIds: sleepIds, workoutIds: workoutIds,
                                                            from: day0, to: day0 + 86_400)
        }
        var seen: [String] = [try await fp()]
        func assertChanged(_ what: String, line: UInt = #line) async throws {
            let now = try await fp()
            XCTAssertFalse(seen.contains(now), "\(what) must change the fingerprint", line: line)
            seen.append(now)
        }

        try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap-b', ?, 70)", [day0 + 100])
        try await assertChanged("measured HR under a secondary raw id")
        try await exec(store, "INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES ('strap-b', ?, 10, 1)", [day0 + 100])
        try await assertChanged("a step sample under a secondary raw id")
        try await exec(store, "INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES ('strap-b', ?, 'WRIST_OFF', '{}')", [day0 - 600])
        try await assertChanged("a wrist event before midnight that opens a span into the day")
        try await exec(store, """
            INSERT INTO sleepSession (deviceId, startTs, endTs, stagesJSON) VALUES ('strap-a-noop', ?, ?, '[{"s":"light"}]')
            """, [day0 - 3_600, day0 + 7 * 3_600])
        try await assertChanged("a detected night")
        try await exec(store, "UPDATE sleepSession SET stagesJSON = '[{\"s\":\"deep\"}]' WHERE deviceId = 'strap-a-noop'")
        try await assertChanged("a re-staged night")
        try await exec(store, "UPDATE sleepSession SET startTsAdjusted = ? WHERE deviceId = 'strap-a-noop'", [day0 - 1_800])
        try await assertChanged("an edited sleep onset")
        try await exec(store, """
            INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('apple-health', ?, ?, 'Running', 'apple')
            """, [day0 + 36_000, day0 + 39_600])
        try await assertChanged("an imported workout")
        try await exec(store, "UPDATE workout SET sport = 'Cycling'")
        try await assertChanged("a workout sport change")

        // Outside the day, and ids the decode does not read, change nothing.
        try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap-b', ?, 70)", [day0 + 90_000])
        try await exec(store, "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('oura-1', ?, 70)", [day0 + 100])
        try await exec(store, "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES (?, ?, ?)", [dev, day0 + 100_000, day0 + 120_000])
        let unchanged = try await fp()
        XCTAssertEqual(unchanged, seen.last)
        let again = try await fp()
        XCTAssertEqual(again, unchanged, "the witness is deterministic")
    }

    // MARK: Spot HRV

    func testSpotReadingsAreTimestampedAndASecondReadingTheSameDayIsKept() async throws {
        let store = try await WhoopStore.inMemory()
        let morning = SpotHrvReadingRow(startTs: day0 + 7 * 3_600, endTs: day0 + 7 * 3_600 + 60, rmssd: 72, sdnn: 61,
                                        meanNN: 1_010, cleanBeats: 58, inputBeats: 60, source: "manual-hrv",
                                        methodVersion: "spot-rmssd-1", createdAt: day0 + 7 * 3_600 + 61)
        let afternoon = SpotHrvReadingRow(startTs: day0 + 13 * 3_600, endTs: day0 + 13 * 3_600 + 60, rmssd: 41,
                                          cleanBeats: 70, inputBeats: 72, source: "manual-hrv",
                                          methodVersion: "spot-rmssd-1", createdAt: day0 + 13 * 3_600 + 61)
        try await store.saveSpotHrvReading(morning, deviceId: dev)
        try await store.saveSpotHrvReading(afternoon, deviceId: dev)
        try await store.saveSpotHrvReading(afternoon, deviceId: dev)   // a double tap on Save
        let back = try await store.spotHrvReadings(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(back, [morning, afternoon])
        let other = try await store.spotHrvReadings(deviceId: "strap-b", from: day0, to: day0 + 86_400)
        XCTAssertTrue(other.isEmpty)
    }

    /// A reading saved on the live day, before its context was decoded, joins the context the day is later given,
    /// and follows the day when it is derived again: nothing on the row can go stale.
    func testASpotReadingJoinsItsContextByTimeAndFollowsARederivedDay() async throws {
        let store = try await WhoopStore.inMemory()
        let start = day0 + 7 * 3_600
        let reading = SpotHrvReadingRow(startTs: start, endTs: start + 60, rmssd: 72, cleanBeats: 58, inputBeats: 60,
                                        source: "manual-hrv", methodVersion: "spot-rmssd-1", createdAt: start + 61)
        try await store.saveSpotHrvReading(reading, deviceId: dev)
        let sql = """
            SELECT startTs, endTs, rmssd, ctxClass, ctxDecoderVersion, ctxProvisional, ctxDeviceId
            FROM \(ActivityContextViews.spotHrvReadingView) WHERE deviceId = ?
            """
        let before = try await rows(store, sql, [dev])
        XCTAssertEqual(before.count, 1, "a reading with no context yet still appears")
        XCTAssertNil(before.first?["ctxClass"] as String?)
        XCTAssertNil(before.first?["ctxProvisional"] as Int?)

        // The live day is decoded: provisional context.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, through: start + 600),
                                               intervals: [interval(start - 300, 900, "sitting")])
        let live = try await rows(store, sql, [dev])
        XCTAssertEqual(live.first?["ctxClass"] as String?, "sitting")
        XCTAssertEqual(live.first?["ctxProvisional"] as Int?, 1, "the live day's context is marked provisional")
        XCTAssertEqual(live.first?["rmssd"] as Double?, 72)

        // Derived again once settled, with another label: the reading follows, and it is final now.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: ActivityContextDayRow.final),
                                               intervals: [interval(start - 300, 900, "lying_down")])
        let settled = try await rows(store, sql, [dev])
        XCTAssertEqual(settled.first?["ctxClass"] as String?, "lying_down")
        XCTAssertEqual(settled.first?["ctxProvisional"] as Int?, 0)
        XCTAssertEqual(settled.first?["ctxDecoderVersion"] as String?, "hsmm-1.9")

        // A reading under another id on a day this strap owns joins the owner's context.
        let other = SpotHrvReadingRow(startTs: start + 120, endTs: start + 180, rmssd: 60, cleanBeats: 50,
                                      inputBeats: 52, source: "manual-hrv", methodVersion: "spot-rmssd-1",
                                      createdAt: start + 181)
        try await store.saveSpotHrvReading(other, deviceId: "strap-b")
        let swapped = try await rows(store, sql, ["strap-b"])
        XCTAssertEqual(swapped.first?["ctxClass"] as String?, "lying_down")
        XCTAssertEqual(swapped.first?["ctxDeviceId"] as String?, dev)

        let columns = try await store.provenanceRowsForTest("PRAGMA table_info(spotHrvReading)", [])
            .map { $0["name"] as String }
        XCTAssertFalse(columns.contains { $0.hasPrefix("ctx") }, "the reading stores no copy of its context")
    }

    func testNewTablesAreDeviceScoped() throws {
        for table in ["activityContextTransition", "spotHrvReading"] {
            XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains(table), table)
        }
    }
}
