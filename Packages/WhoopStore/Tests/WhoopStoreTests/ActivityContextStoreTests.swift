import XCTest
import GRDB
@testable import WhoopStore

private extension WhoopStore {
    func execForTest(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws {
        try syncWrite { db in try db.execute(sql: sql, arguments: arguments) }
    }

    func rowsForTest(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        try syncRead { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
    }

    func countForTest(_ table: String, deviceId: String) throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?", arguments: [deviceId]) ?? 0
        }
    }

    func seedHeartRateForTest(deviceId: String, timestamps: [Int], bpm: Int = 70) throws {
        try syncWrite { db in
            for ts in timestamps {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                               arguments: [deviceId, ts, bpm])
            }
        }
    }
}

final class ActivityContextStoreTests: XCTestCase {
    private let dev = "my-whoop"
    private let day0: Int = 1_760_000_000

    private func interval(_ start: Int, _ length: Int, _ cls: String = "sitting_desk",
                          confidence: Double = 0.8) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: start + length, activityClass: cls, confidence: confidence)
    }

    private func ledger(_ dayStart: Int, day: String = "2025-10-09", length: Int = 86_400,
                        decoder: String = "hsmm-1.2", computedAt: Int = 1) -> ActivityContextDayRow {
        ActivityContextDayRow(day: day, dayStart: dayStart, dayEnd: dayStart + length,
                              taxonomyVersion: "act-class-1", decoderVersion: decoder,
                              ontologyVersion: "2.0", intervalVersion: "ctx-int-1", dataThrough: dayStart + length,
                              observedSeconds: 1_000, intervalCount: 99, computedAt: computedAt)
    }

    private func fullRow(_ start: Int) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(
            startTs: start, endTs: start + 300, activityClass: "brisk_walking", confidence: 0.81,
            runnerUp: "walking", runnerUpConfidence: 0.19, evidenceQuality: 0.9,
            posture: "upright", locomotion: "walking", armBehavior: "swinging",
            sleepState: "awake", wearState: "on_wrist", intensity: 0.62, stepTicks: 610, cadenceSpm: 121.5,
            hrSamples: 298, hrMean: 112.4, hrMin: 98, hrMax: 131, hrSlope: 3.25,
            rmssd: 31.5, rrBeats: 540, rrDiffSqSumMs2: 535_491.0, rrDiffCount: 539,
            respRateBpm: 17.2, respBreaths: 83)
    }

    // MARK: - Migration

    func testMigrationCreatesTablesIndicesAndEveryView() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("activityContextInterval"))
        XCTAssertTrue(tables.contains("activityContextDay"))
        let intervalPk = try await store.primaryKeyColumns("activityContextInterval")
        let dayPk = try await store.primaryKeyColumns("activityContextDay")
        XCTAssertEqual(intervalPk, ["deviceId", "startTs"])
        XCTAssertEqual(dayPk, ["deviceId", "dayStart"])
        let intervalIndices = try await store.indexNamesForTest(table: "activityContextInterval")
        XCTAssertTrue(intervalIndices.contains("idx_activityContextInterval_class"))
        let dayIndices = try await store.indexNamesForTest(table: "activityContextDay")
        XCTAssertTrue(dayIndices.contains("idx_activityContextDay_day"))

        // Querying each view compiles its SELECT against the live stream tables, so a renamed or dropped
        // column in a source table fails here and not in a user's query.
        for view in ActivityContextViews.sampleViewNames + [ActivityContextViews.dayClassView, ActivityContextViews.intervalTransitionsView,
                                                            ActivityContextViews.spotHrvReadingView] {
            _ = try await store.rowsForTest("SELECT * FROM \(view) LIMIT 1")
        }
    }

    func testSampleViewsExposeSourceColumnsThenTheContextColumns() async throws {
        let store = try await WhoopStore.inMemory()
        for spec in ActivityContextViews.specs {
            let columns = try await store.columnNamesForTest(table: spec.view)
            XCTAssertEqual(columns, spec.columns + ActivityContextViews.contextColumns, spec.view)
            let source = try await store.columnNamesForTest(table: spec.table)
            for column in spec.columns {
                XCTAssertTrue(source.contains(column), "\(spec.table) has no column \(column)")
            }
        }
    }

    func testMigrationIsRegisteredLast() {
        XCTAssertEqual(WhoopStore.makeMigrator().migrations.last, "v50-activity-context-provenance")
    }

    // MARK: - Replace / read

    func testReplaceRoundTripsEveryField() async throws {
        let store = try await WhoopStore.inMemory()
        let row = fullRow(day0 + 600)
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [row])

        let back = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(back, [row])
        let ledgerBack = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(ledgerBack?.intervalCount, 1, "the ledger counts the rows actually written")
        XCTAssertEqual(ledgerBack?.decoderVersion, "hsmm-1.2")
        XCTAssertEqual(ledgerBack?.taxonomyVersion, "act-class-1")
        XCTAssertEqual(ledgerBack?.ontologyVersion, "2.0")
        XCTAssertEqual(ledgerBack?.intervalVersion, "ctx-int-1")
    }

    func testReplaceKeepsNullableFieldsNull() async throws {
        let store = try await WhoopStore.inMemory()
        let bare = interval(day0, 60)
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [bare])
        let back = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 60)
        XCTAssertEqual(back.first, bare)
        XCTAssertNil(back.first?.hrMean)
        XCTAssertNil(back.first?.rmssd)
        XCTAssertNil(back.first?.respRateBpm)
        XCTAssertNil(back.first?.cadenceSpm)
        XCTAssertNil(back.first?.posture)
    }

    func testReplacingADayDropsItsOldIntervalsAndLeavesOtherDaysAlone() async throws {
        let store = try await WhoopStore.inMemory()
        let nextDay = day0 + 86_400
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0 + 100, 100, "sitting"), interval(day0 + 200, 100, "walking"), interval(day0 + 300, 100, "sitting"),
        ])
        try await store.replaceActivityContext(deviceId: dev, day: ledger(nextDay, day: "2025-10-10"), intervals: [
            interval(nextDay + 100, 100, "running"),
        ])

        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, computedAt: 2), intervals: [
            interval(day0 + 150, 100, "standing"),
        ])

        let first = try await store.activityContextIntervals(deviceId: dev, from: day0, to: nextDay)
        XCTAssertEqual(first.map(\.activityClass), ["standing"], "the old day's rows are gone, not merged")
        let second = try await store.activityContextIntervals(deviceId: dev, from: nextDay, to: nextDay + 86_400)
        XCTAssertEqual(second.map(\.activityClass), ["running"], "the neighbouring day is untouched")
        let ledgerBack = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(ledgerBack?.computedAt, 2)
        XCTAssertEqual(ledgerBack?.intervalCount, 1)
        let rows = try await store.rowsForTest("SELECT COUNT(*) AS n FROM activityContextDay WHERE deviceId = ?", [dev])
        XCTAssertEqual(rows.first?["n"] as Int?, 2, "re-materializing a day updates its ledger row in place")
    }

    func testReplacingWithNoIntervalsEmptiesTheDayButRecordsItAsDone() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0 + 10, 60)])
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, computedAt: 5), intervals: [])
        let rows = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertTrue(rows.isEmpty)
        let ledgerBack = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(ledgerBack?.intervalCount, 0)
        XCTAssertEqual(ledgerBack?.computedAt, 5)
    }

    func testInvalidIntervalsAreRejectedBeforeAnythingIsWritten() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0 + 10, 60, "sitting")])

        let bad: [(String, [ActivityContextIntervalRow], ActivityContextStoreError)] = [
            ("empty", [interval(day0 + 500, 0)], .invalidInterval(startTs: day0 + 500, endTs: day0 + 500)),
            ("inverted", [ActivityContextIntervalRow(startTs: day0 + 600, endTs: day0 + 500, activityClass: "sitting", confidence: 0.5)],
             .invalidInterval(startTs: day0 + 600, endTs: day0 + 500)),
            ("over the cap", [interval(day0 + 700, ActivityContextStore.maxIntervalSeconds + 1)],
             .invalidInterval(startTs: day0 + 700, endTs: day0 + 700 + ActivityContextStore.maxIntervalSeconds + 1)),
            ("overlapping", [interval(day0 + 800, 100), interval(day0 + 850, 100)], .intervalsOverlap(startTs: day0 + 850)),
            ("out of order", [interval(day0 + 900, 100), interval(day0 + 800, 50)], .intervalsOverlap(startTs: day0 + 800)),
        ]
        for (name, rows, expected) in bad {
            do {
                try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, computedAt: 9), intervals: rows)
                XCTFail("\(name): expected a throw")
            } catch let error as ActivityContextStoreError {
                XCTAssertEqual(error, expected, name)
            }
        }
        let survivors = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(survivors.map(\.activityClass), ["sitting"], "a rejected replace leaves the stored day exactly as it was")
        let ledgerBack = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(ledgerBack?.computedAt, 1)
    }

    func testBackToBackIntervalsAreAllowedAndAnEmptyDayRangeIsNot() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0, 100), interval(day0 + 100, 100, "walking"),
        ])
        let rows = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 200)
        XCTAssertEqual(rows.count, 2)
        do {
            try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, length: 0), intervals: [])
            XCTFail("a zero-length day must throw")
        } catch let error as ActivityContextStoreError {
            XCTAssertEqual(error, .invalidDay("2025-10-09"))
        }
    }

    func testAnIntervalOutsideTheDayRangeStillReplacesCleanly() async throws {
        let store = try await WhoopStore.inMemory()
        let dayEnd = day0 + 86_400
        let spill = interval(dayEnd + 30, 100, "walking")   // starts past the declared day
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [spill])
        // A second pass with the same output must neither collide on the primary key nor duplicate.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, computedAt: 3), intervals: [spill])
        let rows = try await store.activityContextIntervals(deviceId: dev, from: dayEnd, to: dayEnd + 1_000)
        XCTAssertEqual(rows, [spill])
    }

    func testRangeReadsAreHalfOpenAndKeepAnIntervalRunningAcrossTheStart() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0, 100, "sitting"), interval(day0 + 100, 100, "walking"), interval(day0 + 250, 100, "standing"),
        ])
        func classes(_ from: Int, _ to: Int) async throws -> [String] {
            try await store.activityContextIntervals(deviceId: dev, from: from, to: to).map(\.activityClass)
        }
        let a = try await classes(day0, day0 + 100)
        XCTAssertEqual(a, ["sitting"], "an interval starting exactly at `to` is excluded")
        let b = try await classes(day0 + 100, day0 + 101)
        XCTAssertEqual(b, ["walking"], "an interval ending exactly at `from` is excluded")
        let c = try await classes(day0 + 50, day0 + 260)
        XCTAssertEqual(c, ["sitting", "walking", "standing"], "an interval already running at `from` is included")
        let d = try await classes(day0 + 200, day0 + 250)
        XCTAssertEqual(d, [], "the gap between two intervals has no context")
        let e = try await classes(day0 + 10, day0 + 10)
        XCTAssertEqual(e, [], "an empty range reads nothing")
    }

    func testAsOfLookupHonoursBoundsAndGaps() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0 + 100, 100, "sitting"), interval(day0 + 200, 50, "walking"),
        ])
        let before = try await store.activityContextInterval(deviceId: dev, at: day0 + 99)
        XCTAssertNil(before)
        let atStart = try await store.activityContextInterval(deviceId: dev, at: day0 + 100)
        XCTAssertEqual(atStart?.activityClass, "sitting")
        let lastSecond = try await store.activityContextInterval(deviceId: dev, at: day0 + 199)
        XCTAssertEqual(lastSecond?.activityClass, "sitting")
        let handover = try await store.activityContextInterval(deviceId: dev, at: day0 + 200)
        XCTAssertEqual(handover?.activityClass, "walking", "the end bound is exclusive: the next interval owns that second")
        let gap = try await store.activityContextInterval(deviceId: dev, at: day0 + 250)
        XCTAssertNil(gap)
        let far = try await store.activityContextInterval(deviceId: dev, at: day0 + 90_000)
        XCTAssertNil(far)
    }

    func testClassFilteredRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0, 100, "sitting"), interval(day0 + 100, 100, "walking"),
            interval(day0 + 200, 100, "sitting"), interval(day0 + 300, 100, "walking"),
        ])
        let walking = try await store.activityContextIntervals(deviceId: dev, activityClass: "walking",
                                                               from: day0, to: day0 + 400)
        XCTAssertEqual(walking.map(\.startTs), [day0 + 100, day0 + 300])
        let none = try await store.activityContextIntervals(deviceId: dev, activityClass: "running", from: day0, to: day0 + 400)
        XCTAssertTrue(none.isEmpty)
    }

    func testDevicesNeverSeeEachOthersContext() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: "strap-a", day: ledger(day0), intervals: [interval(day0, 100, "sitting")])
        try await store.replaceActivityContext(deviceId: "strap-b", day: ledger(day0), intervals: [interval(day0, 100, "running")])
        let a = try await store.activityContextIntervals(deviceId: "strap-a", from: day0, to: day0 + 100)
        let b = try await store.activityContextIntervals(deviceId: "strap-b", from: day0, to: day0 + 100)
        XCTAssertEqual(a.map(\.activityClass), ["sitting"])
        XCTAssertEqual(b.map(\.activityClass), ["running"])
        // Replacing one device's day leaves the other's identical-timestamp rows alone.
        try await store.replaceActivityContext(deviceId: "strap-a", day: ledger(day0, computedAt: 4), intervals: [])
        let bStill = try await store.activityContextIntervals(deviceId: "strap-b", from: day0, to: day0 + 100)
        XCTAssertEqual(bStill.count, 1)
        let asOf = try await store.activityContextInterval(deviceId: "strap-a", at: day0 + 50)
        XCTAssertNil(asOf)
    }

    func testLedgerReadsByDayKeyAndRange() async throws {
        let store = try await WhoopStore.inMemory()
        for (i, key) in ["2025-10-09", "2025-10-10", "2025-10-11"].enumerated() {
            let start = day0 + i * 86_400
            try await store.replaceActivityContext(deviceId: dev, day: ledger(start, day: key),
                                                   intervals: [interval(start + 10, 60)])
        }
        let range = try await store.activityContextDays(deviceId: dev, from: "2025-10-10", to: "2025-10-11")
        XCTAssertEqual(range.map(\.day), ["2025-10-10", "2025-10-11"])
        let single = try await store.activityContextDay(deviceId: dev, day: "2025-10-11")
        XCTAssertEqual(single?.dayStart, day0 + 2 * 86_400)
        let missing = try await store.activityContextDay(deviceId: dev, day: "2025-12-31")
        XCTAssertNil(missing)
    }

    func testDayClassSecondsView() async throws {
        let store = try await WhoopStore.inMemory()
        let nextDay = day0 + 86_400
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0, 300, "sitting"), interval(day0 + 300, 120, "walking"), interval(day0 + 420, 200, "sitting"),
        ])
        try await store.replaceActivityContext(deviceId: dev, day: ledger(nextDay, day: "2025-10-10"), intervals: [
            interval(nextDay, 60, "running"),
        ])
        let rows = try await store.activityContextDayClassSeconds(deviceId: dev, from: "2025-10-09", to: "2025-10-10")
        XCTAssertEqual(rows, [
            ActivityContextDayClassRow(day: "2025-10-09", activityClass: "sitting", seconds: 500, intervals: 2),
            ActivityContextDayClassRow(day: "2025-10-09", activityClass: "walking", seconds: 120, intervals: 1),
            ActivityContextDayClassRow(day: "2025-10-10", activityClass: "running", seconds: 60, intervals: 1),
        ])
    }

    func testClearRemovesIntervalsAndLedgerFromAGivenDayOnward() async throws {
        let store = try await WhoopStore.inMemory()
        let nextDay = day0 + 86_400
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 60)])
        try await store.replaceActivityContext(deviceId: dev, day: ledger(nextDay, day: "2025-10-10"), intervals: [interval(nextDay, 60)])
        try await store.replaceActivityContext(deviceId: "other", day: ledger(nextDay, day: "2025-10-10"), intervals: [interval(nextDay, 60)])

        try await store.clearActivityContext(deviceId: dev, fromDayStart: nextDay)
        let intervalsLeft = try await store.countForTest("activityContextInterval", deviceId: dev)
        let ledgersLeft = try await store.countForTest("activityContextDay", deviceId: dev)
        XCTAssertEqual(intervalsLeft, 1)
        XCTAssertEqual(ledgersLeft, 1)
        let otherLeft = try await store.countForTest("activityContextInterval", deviceId: "other")
        XCTAssertEqual(otherLeft, 1, "another device's context is not touched")

        try await store.clearActivityContext(deviceId: dev)
        let allGone = try await store.countForTest("activityContextInterval", deviceId: dev)
        XCTAssertEqual(allGone, 0)
    }

    func testAnOverlappingLedgerRowFromAnotherTimeZoneIsRetired() async throws {
        let store = try await WhoopStore.inMemory()
        let shifted = day0 + 3 * 3_600
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0 + 100, 60)])
        try await store.replaceActivityContext(deviceId: dev, day: ledger(shifted, day: "2025-10-09"),
                                               intervals: [interval(shifted + 100, 60)])
        var starts = try await store.rowsForTest("SELECT dayStart FROM activityContextDay WHERE deviceId = ? ORDER BY dayStart", [dev])
            .map { $0["dayStart"] as Int }
        XCTAssertEqual(starts, [shifted], "two ledger rows may never claim the same instants")

        // A neighbouring, non-overlapping day is not touched, and neither is another device's ledger.
        let nextDay = shifted + 86_400
        try await store.replaceActivityContext(deviceId: dev, day: ledger(nextDay, day: "2025-10-10"), intervals: [])
        try await store.replaceActivityContext(deviceId: "other", day: ledger(shifted, day: "2025-10-09"), intervals: [])
        starts = try await store.rowsForTest("SELECT dayStart FROM activityContextDay WHERE deviceId = ? ORDER BY dayStart", [dev])
            .map { $0["dayStart"] as Int }
        XCTAssertEqual(starts, [shifted, nextDay])
        let others = try await store.countForTest("activityContextDay", deviceId: "other")
        XCTAssertEqual(others, 1)
    }

    func testClearByRangeRemovesOnlyThatDevicesRowsInsideTheRange() async throws {
        let store = try await WhoopStore.inMemory()
        let nextDay = day0 + 86_400
        for id in [dev, "other"] {
            try await store.replaceActivityContext(deviceId: id, day: ledger(day0), intervals: [interval(day0 + 100, 60), interval(day0 + 500, 60)])
            try await store.replaceActivityContext(deviceId: id, day: ledger(nextDay, day: "2025-10-10"), intervals: [interval(nextDay + 100, 60)])
        }

        try await store.clearActivityContext(deviceId: dev, from: day0, to: nextDay)
        let left = try await store.activityContextIntervals(deviceId: dev, from: day0, to: nextDay + 86_400)
        XCTAssertEqual(left.map(\.startTs), [nextDay + 100], "the day after the range keeps its rows")
        let ledgers = try await store.rowsForTest("SELECT dayStart FROM activityContextDay WHERE deviceId = ?", [dev])
        XCTAssertEqual(ledgers.map { $0["dayStart"] as Int }, [nextDay], "the cleared day is no longer recorded as materialized")
        let otherIntervals = try await store.countForTest("activityContextInterval", deviceId: "other")
        let otherLedgers = try await store.countForTest("activityContextDay", deviceId: "other")
        XCTAssertEqual(otherIntervals, 3)
        XCTAssertEqual(otherLedgers, 2)

        // A range that only grazes a day still retires that day's ledger row: its intervals are partly gone.
        try await store.clearActivityContext(deviceId: "other", from: nextDay - 10, to: nextDay + 10)
        let grazed = try await store.rowsForTest("SELECT dayStart FROM activityContextDay WHERE deviceId = ? ORDER BY dayStart", ["other"])
        XCTAssertTrue(grazed.isEmpty, "both days touch the range")

        try await store.clearActivityContext(deviceId: dev, from: day0, to: day0)
        let empty = try await store.countForTest("activityContextInterval", deviceId: dev)
        XCTAssertEqual(empty, 1, "an empty range clears nothing")
    }

    func testNewestHeartRateIsADeviceAndRangeScopedSeek() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.seedHeartRateForTest(deviceId: dev, timestamps: [day0 + 10, day0 + 500, day0 + 86_400 + 5])
        try await store.seedHeartRateForTest(deviceId: "other", timestamps: [day0 + 9_000])
        let first = try await store.newestHeartRateTs(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(first, day0 + 500)
        let atTheEdge = try await store.newestHeartRateTs(deviceId: dev, from: day0, to: day0 + 500)
        XCTAssertEqual(atTheEdge, day0 + 10, "the range is half-open")
        let next = try await store.newestHeartRateTs(deviceId: dev, from: day0 + 86_400, to: day0 + 2 * 86_400)
        XCTAssertEqual(next, day0 + 86_400 + 5)
        let none = try await store.newestHeartRateTs(deviceId: dev, from: day0 + 600, to: day0 + 86_000)
        XCTAssertNil(none)
        let wrongDevice = try await store.newestHeartRateTs(deviceId: "nobody", from: day0, to: day0 + 86_400)
        XCTAssertNil(wrongDevice)
        let empty = try await store.newestHeartRateTs(deviceId: dev, from: day0, to: day0)
        XCTAssertNil(empty)
    }

    // MARK: - Joins against the physiological streams

    private func seedHeartRate(_ store: WhoopStore, _ points: [(Int, Int)], device: String? = nil) async throws {
        for (ts, bpm) in points {
            try await store.execForTest("INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                                        [device ?? dev, ts, bpm])
        }
    }

    func testHeartRateSamplesPickUpTheCoveringIntervalAndGapsStayVisible() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [
            interval(day0 + 100, 100, "sitting", confidence: 0.7), interval(day0 + 200, 50, "walking", confidence: 0.9),
        ])
        try await seedHeartRate(store, [(day0 + 50, 60), (day0 + 100, 61), (day0 + 199, 62), (day0 + 200, 95),
                                        (day0 + 249, 96), (day0 + 250, 70), (day0 + 400, 71)])
        let rows = try await store.rowsForTest("SELECT ts, bpm, ctxClass, ctxConfidence, ctxStartTs, ctxEndTs FROM hrSampleCtx WHERE deviceId = ? ORDER BY ts", [dev])
        let got = rows.map { ($0["ts"] as Int, $0["ctxClass"] as String?, $0["ctxConfidence"] as Double?) }
        XCTAssertEqual(got.map(\.0), [day0 + 50, day0 + 100, day0 + 199, day0 + 200, day0 + 249, day0 + 250, day0 + 400],
                       "every sample survives the join, including those with no context")
        XCTAssertEqual(got.map { $0.1 ?? "-" }, ["-", "sitting", "sitting", "walking", "walking", "-", "-"])
        XCTAssertEqual(got[1].2, 0.7)
        XCTAssertEqual(got[3].2, 0.9)
        XCTAssertEqual(rows[1]["ctxStartTs"] as Int?, day0 + 100)
        XCTAssertEqual(rows[1]["ctxEndTs"] as Int?, day0 + 200)
    }

    /// v50 (D5-09 / D3V-02): a day's context is stored once, under the day's owner, while its streams are read
    /// across every raw id, so a sample recorded under another id joins the OWNER's interval — the same answer
    /// `Repository.storedActivityContext` gives for that second. (Before v50 the join was same-device only and
    /// this sample read NULL context.) A device's own ledger still wins where both have one.
    func testASampleUnderAnotherIdJoinsItsDayOwnersContext() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: "strap-a", day: ledger(day0), intervals: [interval(day0, 1_000, "sitting")])
        try await seedHeartRate(store, [(day0 + 10, 60)], device: "strap-a")
        try await seedHeartRate(store, [(day0 + 10, 90), (day0 + 2_000, 91)], device: "strap-b")
        try await seedHeartRate(store, [(day0 - 100, 92)], device: "strap-b")
        let rows = try await store.rowsForTest("SELECT deviceId, ts, ctxClass, ctxDeviceId FROM hrSampleCtx ORDER BY deviceId, ts")
        XCTAssertEqual(rows.map { $0["deviceId"] as String }, ["strap-a", "strap-b", "strap-b", "strap-b"])
        XCTAssertEqual(rows[0]["ctxClass"] as String?, "sitting")
        XCTAssertEqual(rows[2]["ctxClass"] as String?, "sitting", "strap-b's sample inside the owned day joins its owner's context")
        XCTAssertEqual(rows[2]["ctxDeviceId"] as String?, "strap-a")
        XCTAssertNil(rows[1]["ctxClass"] as String?, "a sample before any materialized day has no context")
        XCTAssertNil(rows[3]["ctxClass"] as String?, "a gap inside the owned day stays a gap")

        // Where strap-b has its own ledger for the instant, its own context wins.
        try await store.replaceActivityContext(deviceId: "strap-b", day: ledger(day0), intervals: [interval(day0, 1_000, "running")])
        let own = try await store.rowsForTest("SELECT ctxClass FROM hrSampleCtx WHERE deviceId = 'strap-b' AND ts = ?", [day0 + 10])
        XCTAssertEqual(own.first?["ctxClass"] as String?, "running")
    }

    func testEveryPhysiologicalStreamJoinsToItsInterval() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 1_000, "lying_down", confidence: 0.66)])
        let inside = day0 + 500
        let outside = day0 + 5_000
        // Each statement takes (deviceId, ts); the other columns are fixed.
        let inserts: [(view: String, sql: String)] = [
            ("hrSampleCtx", "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, 58)"),
            ("rrIntervalCtx", "INSERT INTO rrInterval (deviceId, ts, rrMs, seq) VALUES (?, ?, 1010, 0)"),
            ("ppgHrSampleCtx", "INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, 57, 3)"),
            ("spo2SampleCtx", "INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, 1000, 2000)"),
            ("skinTempSampleCtx", "INSERT INTO skinTempSample (deviceId, ts, raw) VALUES (?, ?, 800)"),
            ("respSampleCtx", "INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, 2048)"),
            ("gravitySampleCtx", "INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES (?, ?, 0.0, 0.0, 1.0)"),
            ("stepSampleCtx", "INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, 4, 1)"),
        ]
        XCTAssertEqual(Set(inserts.map(\.view)), Set(ActivityContextViews.sampleViewNames),
                       "this test must cover every context view")
        for insert in inserts {
            try await store.execForTest(insert.sql, [dev, inside])
            try await store.execForTest(insert.sql, [dev, outside])
        }
        for insert in inserts {
            let rows = try await store.rowsForTest("SELECT ts, ctxClass, ctxConfidence FROM \(insert.view) WHERE deviceId = ? ORDER BY ts", [dev])
            XCTAssertEqual(rows.count, 2, "\(insert.view) keeps every sample")
            XCTAssertEqual(rows.first?["ctxClass"] as String?, "lying_down", insert.view)
            XCTAssertEqual(rows.first?["ctxConfidence"] as Double?, 0.66, insert.view)
            XCTAssertNil(rows.last?["ctxClass"] as String?, "\(insert.view): a sample past the interval has no context")
        }
    }

    func testRRBeatsInOneSecondAllShareItsContext() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0), intervals: [interval(day0, 600, "sitting")])
        for (i, rr) in [980, 1004, 1011].enumerated() {
            try await store.execForTest("INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord) VALUES (?, ?, ?, 0, ?)",
                                        [dev, day0 + 30, rr, i])
        }
        let rows = try await store.rowsForTest("SELECT rrMs, ord, ctxClass FROM rrIntervalCtx WHERE deviceId = ? ORDER BY ord", [dev])
        XCTAssertEqual(rows.map { $0["rrMs"] as Int }, [980, 1004, 1011])
        XCTAssertEqual(Set(rows.map { $0["ctxClass"] as String? }), ["sitting"])
    }

    func testViewAgreesWithABruteForceLookupOverManyRandomSamples() async throws {
        let store = try await WhoopStore.inMemory()
        var generator = SystemRandomNumberGenerator()
        var intervals: [ActivityContextIntervalRow] = []
        var cursor = day0
        let classes = ["sitting", "walking", "standing", "running", "lying_down"]
        for i in 0..<300 {
            cursor += Int.random(in: 0...400, using: &generator)   // 0 = back to back, otherwise a gap
            let length = Int.random(in: 1...900, using: &generator)
            intervals.append(interval(cursor, length, classes[i % classes.count]))
            cursor += length
        }
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, length: cursor - day0 + 10), intervals: intervals)

        var samples = Set<Int>()
        while samples.count < 2_500 { samples.insert(Int.random(in: (day0 - 500)...(cursor + 500), using: &generator)) }
        try await store.seedHeartRateForTest(deviceId: dev, timestamps: Array(samples))

        let rows = try await store.rowsForTest("SELECT ts, ctxClass FROM hrSampleCtx WHERE deviceId = ?", [dev])
        XCTAssertEqual(rows.count, samples.count)
        var mismatches = 0
        for row in rows {
            let ts: Int = row["ts"]
            let expected = intervals.first { $0.startTs <= ts && ts < $0.endTs }?.activityClass
            if (row["ctxClass"] as String?) != expected { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0)
    }

    /// The view must stay a keyed range read on the source table: a day of samples should not be scanned to
    /// answer a one-hour question. Pinned through SQLite's own plan so a rewrite that loses the pushdown fails.
    func testRangeQueriesOnAViewSearchTheSourceTableByItsKey() async throws {
        let store = try await WhoopStore.inMemory()
        let plan = try await store.rowsForTest("""
            EXPLAIN QUERY PLAN
            SELECT * FROM hrSampleCtx WHERE deviceId = ? AND ts >= ? AND ts < ?
            """, [dev, day0, day0 + 3_600])
        let details = plan.map { $0["detail"] as String }
        let scanned = details.filter { $0.hasPrefix("SCAN") && !$0.contains("USING INDEX") && !$0.contains("USING COVERING INDEX") }
        XCTAssertTrue(scanned.isEmpty, "unexpected full scan in plan: \(details)")
        XCTAssertTrue(details.contains { $0.contains("hrSample") && $0.contains("deviceId=?") },
                      "the source table should be searched by deviceId and ts: \(details)")
    }

    // MARK: - Privacy

    func testBothTablesAreDeviceScoped() {
        for table in ["activityContextInterval", "activityContextDay"] {
            XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains(table),
                          "\(table) missing from deviceScopedTables — deleteAllData would leave it behind")
        }
    }

    func testDeleteAllDataForgetsTheDevicesContextOnly() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)
        try dbq.write { db in
            for device in ["strap-a", "strap-b"] {
                try db.execute(sql: """
                    INSERT INTO activityContextInterval (deviceId, startTs, endTs, activityClass, confidence, sleepState, wearState)
                    VALUES (?, 100, 200, 'sitting', 0.5, 'awake', 'on_wrist')
                    """, arguments: [device])
                try db.execute(sql: """
                    INSERT INTO activityContextDay (deviceId, dayStart, day, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion, intervalVersion, computedAt)
                    VALUES (?, 0, '2025-10-09', 86400, 'act-class-1', 'hsmm-1.2', '2.0', 'ctx-int-1', 1)
                    """, arguments: [device])
            }
        }
        try DeviceRegistryStore(dbQueue: dbq).deleteAllData(deviceId: "strap-a")
        let counts = try dbq.read { db in
            try ["activityContextInterval", "activityContextDay"].map { table in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = 'strap-a'") ?? -1,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = 'strap-b'") ?? -1)
            }
        }
        for (gone, kept) in counts {
            XCTAssertEqual(gone, 0)
            XCTAssertEqual(kept, 1)
        }
    }
}