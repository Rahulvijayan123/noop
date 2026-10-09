import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The phone's persisted activity context after v50: re-derivation across launches, the atomic owner
/// hand-off on a strap change, stale-day cleanup, one id set for every stream, the 25-hour day, serving
/// status, the gait lane's mode and the timestamped spot HRV record.
final class ActivityContextPersistenceAppTests: XCTestCase {

    /// Desk work at a steady heart rate, second by second.
    private func desk(from start: Int, seconds: Int, bpm: Int = 64) -> Streams {
        var hr: [HRSample] = [], gravity: [GravitySample] = [], steps: [StepSample] = []
        for i in 0..<seconds {
            let ts = start + i
            let wobble = sin(Double(i) * 12.9898).truncatingRemainder(dividingBy: 1) * 0.01
            gravity.append(GravitySample(ts: ts, x: 0.2, y: 0.9, z: 0.35 + wobble, dynAccel: 0.02 + abs(wobble)))
            steps.append(StepSample(ts: ts, counter: 1_000, activityClass: 0))
            hr.append(HRSample(ts: ts, bpm: bpm))
        }
        return Streams(hr: hr, gravity: gravity, steps: steps)
    }

    @MainActor
    private func fixture(deviceId: String = "acx-wp3-\(UUID().uuidString)") async throws
        -> (repo: Repository, store: WhoopStore, deviceId: String) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        addTeardownBlock {
            ActivityContextFileStore.shared.removeAll(forDevice: deviceId)
            ActivityContextFileStore.shared.removeAll(forDevice: Repository.whoopSource)
        }
        return (repo, store, deviceId)
    }

    @MainActor
    private func coordinator(_ repo: Repository, days: Int = 5, logs: @escaping (String) -> Void = { _ in })
        -> ActivityContextCoordinator {
        ActivityContextCoordinator(repo: repo, horizonDays: days, isWorn: { true }, remind: { _, _ in }, log: logs)
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    /// A day at least two days old: outside the 36 h "recent" window, so only rules 1, 2, 5 and 6 can touch it.
    private var oldDay: ActivityContextMaterialization.Day {
        ActivityContextMaterialization.localDays(endingAt: now, count: 4, timeZone: .current)[3]
    }

    // MARK: Re-derivation after a relaunch (D5-05, D5-V01, D3-05, D6-12)

    @MainActor
    func testAnOldDayIsDerivedAgainAfterARelaunchWhenItsNightIsDetectedLater() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 3_600), deviceId: id)
        _ = try await store.insert(desk(from: day.start + 22 * 3_600, seconds: 1_800, bpm: 54), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let firstRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let first = try XCTUnwrap(firstRow)
        XCTAssertNotNil(first.inputFingerprint, "the ledger records the input it was derived from")
        XCTAssertEqual(first.configTag, repo.activityContextLedgerConfigTag(dayStart: day.start))
        XCTAssertEqual(first.featureSchema, ActivityContextVersions.featureSchema)
        XCTAssertEqual(first.finality, "final", "an old, closed day decoded after its sleep settled")

        // A relaunch with nothing new: nothing is written.
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let idleRow = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertEqual(idleRow, first)

        // The night is detected later (no new heart rate): after another relaunch the day is derived again and
        // its late evening reads as asleep.
        let night = CachedSleepSession(startTs: day.start + 22 * 3_600, endTs: day.end + 6 * 3_600,
                                       efficiency: 0.9, restingHr: 52, avgHrv: 60, stagesJSON: nil)
        _ = try await store.upsertSleepSessions([night], deviceId: id + "-noop")
        var logs: [String] = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        let secondRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let second = try XCTUnwrap(secondRow)
        XCTAssertNotEqual(second.inputFingerprint, first.inputFingerprint)
        XCTAssertTrue(logs.contains { $0.hasPrefix("Activity context: saved") && $0.hasSuffix(day.key) },
                      "the day was decoded and written again: \(logs)")
        let late = try await store.activityContextInterval(deviceId: id, at: day.start + 22 * 3_600 + 900)
        XCTAssertEqual(late?.sleepState, "asleep")
    }

    @MainActor
    func testAWorkoutImportedForAnOldDayReDerivesItAfterARelaunch() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 10 * 3_600, seconds: 3_600), deviceId: id)
        var logs: [String] = []
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let beforeRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let before = try XCTUnwrap(beforeRow)
        try await store.upsertWorkouts([WorkoutRow(startTs: day.start + 10 * 3_600, endTs: day.start + 10 * 3_600 + 1_800,
                                                   sport: "Cycling", source: "apple-health", durationS: 1_800,
                                                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)],
                                       deviceId: WorkoutSource.appleHealthSource)
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        let afterRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let after = try XCTUnwrap(afterRow)
        XCTAssertNotEqual(after.inputFingerprint, before.inputFingerprint)
        XCTAssertTrue(logs.contains { $0.hasPrefix("Activity context: saved") && $0.hasSuffix(day.key) },
                      "the day is decoded and written again, not only re-stamped: \(logs)")
    }

    // MARK: Retrospective intervals (D8-10)

    @MainActor
    func testAFinalDayGainsRetrospectiveRowsThatOnlyHistoricalReadsServe() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 3_600), deviceId: id)
        var logs: [String] = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)

        let ledgerRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let ledger = try XCTUnwrap(ledgerRow)
        XCTAssertEqual(ledger.finality, "final")
        XCTAssertEqual(ledger.retrospectiveVersion, ActivityContextRetrospective.version,
                       "the ledger names the smoother whose rows it holds")
        let causal = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        let smoothed = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end,
                                                                reading: .retrospective)
        XCTAssertFalse(causal.isEmpty)
        XCTAssertFalse(smoothed.isEmpty, "a final day is written with its retrospective rows: \(logs)")
        XCTAssertTrue(causal.allSatisfy { $0.derivation == ActivityContextIntervalRow.causal })
        XCTAssertTrue(smoothed.allSatisfy { $0.derivation == ActivityContextIntervalRow.retrospective })

        // Causal readers (every live consumer and every baseline) are unchanged: the decoder's own rows.
        let live = await repo.storedActivityContext(from: day.start, to: day.end, feedback: [])
        XCTAssertEqual(live.intervals, causal.map(ActivityContextInterval.init(row:)))
        XCTAssertTrue(live.intervals.allSatisfy { $0.derivation == .causal })
        // A historical read of the finished day prefers the retrospective rows.
        let past = await repo.storedActivityContextWithStatus(from: day.start, to: day.end, feedback: [],
                                                              reading: .historical)
        XCTAssertEqual(past.intervals, smoothed.map(ActivityContextInterval.init(row:)))
        XCTAssertTrue(past.intervals.allSatisfy { $0.derivation == .retrospective })
    }

    @MainActor
    func testARelaunchDoesNotRePlanADayAlreadyAtTheCurrentRetrospectiveVersion() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let firstRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let first = try XCTUnwrap(firstRow)
        XCTAssertEqual(first.retrospectiveVersion, ActivityContextRetrospective.version)

        var logs: [String] = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        let againRow = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertEqual(againRow, first, "nothing is rewritten")
        XCTAssertFalse(logs.contains { $0.hasSuffix(day.key) && $0.hasPrefix("Activity context: saved") },
                       "the day is not derived again: \(logs)")
    }

    @MainActor
    func testAFinalDayWithoutTheSmootherGainsItOnceThenStops() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        // A day saved by a build that wrote no retrospective rows: same causal rows, ledger names no smoother.
        let savedRow = try await store.activityContextDay(deviceId: id, day: day.key)
        var saved = try XCTUnwrap(savedRow)
        let causal = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        saved.retrospectiveVersion = nil
        try await store.replaceActivityContext(deviceId: id, day: saved, intervals: causal)

        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let upgradedRow = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertEqual(upgradedRow?.retrospectiveVersion, ActivityContextRetrospective.version)
        let smoothed = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end,
                                                                reading: .retrospective)
        XCTAssertFalse(smoothed.isEmpty)
    }

    @MainActor
    func testAFinalDaySmoothedToNothingIsRecordedOnceAndNotRePlannedOnRelaunch() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: id)
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let calls = Calls()
        let nothing: ActivityContextCoordinator.Smoother = { _, _, _, _, _, _, _, finality in
            if finality == ActivityContextDayRow.final { calls.bump() }
            return []
        }
        func run(_ logs: @escaping (String) -> Void = { _ in }) async {
            await ActivityContextCoordinator(repo: repo, horizonDays: 5, isWorn: { true }, remind: { _, _ in },
                                             log: logs, smooth: nothing)
                .drainMaterialization(pauseNs: 0)
        }

        await run()
        let firstRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let first = try XCTUnwrap(firstRow)
        XCTAssertEqual(first.finality, "final")
        XCTAssertEqual(first.retrospectiveVersion, ActivityContextRetrospective.version,
                       "an empty smoothing result is recorded in the ledger: smoothed, nothing to store")
        let smoothed = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end,
                                                                reading: .retrospective)
        XCTAssertTrue(smoothed.isEmpty)
        XCTAssertEqual(calls.count, 1, "smoothed once in the first launch, never looped")

        var logs: [String] = []
        await run { logs.append($0) }
        XCTAssertFalse(logs.contains { $0.hasPrefix("Activity context: saved") && $0.hasSuffix(day.key) },
                       "an empty smoothing result is a result: the day is not decoded again: \(logs)")
        let againRow = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertEqual(againRow, first)
        XCTAssertEqual(calls.count, 1)
        // Historical reads of such a day are its causal rows.
        let causal = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        let past = await repo.storedActivityContextWithStatus(from: day.start, to: day.end, feedback: [],
                                                              reading: .historical)
        XCTAssertEqual(past.intervals, causal.map(ActivityContextInterval.init(row:)))
    }

    @MainActor
    func testAProvisionalDayGetsNoRetrospectiveRows() async throws {
        let (repo, store, id) = try await fixture()
        let today = ActivityContextMaterialization.localDays(endingAt: now, count: 1, timeZone: .current)[0]
        let start = max(today.start, now - 1_800)
        let seconds = min(1_200, now - start - 1)
        guard seconds >= 300 else { throw XCTSkip("too close to local midnight for a day in progress") }
        _ = try await store.insert(desk(from: start, seconds: seconds), deviceId: id)
        await coordinator(repo, days: 1).drainMaterialization(pauseNs: 0)

        let ledgerRow = try await store.activityContextDay(deviceId: id, day: today.key)
        let ledger = try XCTUnwrap(ledgerRow)
        XCTAssertEqual(ledger.finality, "provisional")
        XCTAssertNil(ledger.retrospectiveVersion)
        let smoothed = try await store.activityContextIntervals(deviceId: id, from: today.start, to: today.end,
                                                                reading: .retrospective)
        XCTAssertTrue(smoothed.isEmpty, "a day still in progress is never smoothed")
        let causal = try await store.activityContextIntervals(deviceId: id, from: today.start, to: today.end)
        XCTAssertFalse(causal.isEmpty)
        let past = await repo.storedActivityContextWithStatus(from: today.start, to: today.end, feedback: [],
                                                              reading: .historical)
        XCTAssertEqual(past.intervals, causal.map(ActivityContextInterval.init(row:)),
                       "a historical read of a provisional day is the causal one")
    }

    // MARK: Interval context columns (INT-A)

    @MainActor
    func testAMaterializedDayStoresEveryIntervalContextFieldNotDefaults() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let rows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertNotNil(row.inBed, "in-bed is recorded, not left NULL")
            XCTAssertNotNil(row.uncertainty)
            XCTAssertNotNil(row.experts)
            XCTAssertNotNil(row.transitionCount)
            XCTAssertNotNil(row.absorbedClasses)
            XCTAssertNotNil(row.absorbedSeconds)
            XCTAssertNotNil(row.settlingSeconds)
            if !(ActivityClass(rawValue: row.activityClass)?.isMovement ?? true) {
                XCTAssertNotNil(row.settledFromTs, "a still row says where its settled part starts")
            }
        }
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.precededByGapS != nil })
        // What the coach reads back is the context the builder produced, field for field.
        let stored = await repo.storedActivityContext(from: day.start, to: day.end)
        XCTAssertEqual(stored.intervals, rows.map(ActivityContextInterval.init(row:)))
    }

    // MARK: The previous day's tail (INT-A review)

    @MainActor
    func testADayIsDerivedAgainWhenTheDayBeforeItEndsInAWalkAndItsFirstRowSettlesOnIt() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        let previous = ActivityContextMaterialization.localDays(endingAt: now, count: 5, timeZone: .current)[4]
        XCTAssertEqual(previous.end, day.start)
        _ = try await store.insert(desk(from: previous.end - 3_600, seconds: 3_600), deviceId: id)
        _ = try await store.insert(desk(from: day.start, seconds: 1_800), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let blindRows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        XCTAssertFalse(blindRows.isEmpty)
        XCTAssertTrue(blindRows.allSatisfy { ($0.settlingSeconds ?? 0) == 0 }, "nothing before the day yet")
        let firstLedgerRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let firstLedger = try XCTUnwrap(firstLedgerRow)

        // The previous day, as stored, ends in a walk 30 s before midnight.
        let previousLedgerRow = try await store.activityContextDay(deviceId: id, day: previous.key)
        let previousLedger = try XCTUnwrap(previousLedgerRow)
        let previousRows = try await store.activityContextIntervals(deviceId: id, from: previous.start, to: previous.end)
        var previousEvents = try await store.activityContextTransitions(deviceId: id, from: previous.start, to: previous.end)
        previousEvents.append(ActivityContextTransitionRow(ts: day.start - 30, kind: "walk_stop", probability: 0.9,
                                                           decoderVersion: previousLedger.decoderVersion))
        // Rewritten with its retrospective rows too, so the previous day stays at the current smoother version and
        // is not re-derived (which would replace the injected event with the decoder's own).
        let previousSmoothed = try await store.activityContextIntervals(deviceId: id, from: previous.start,
                                                                        to: previous.end, reading: .retrospective)
        try await store.replaceActivityContext(deviceId: id, day: previousLedger, intervals: previousRows,
                                               transitions: previousEvents,
                                               retrospective: previousSmoothed.filter { $0.startTs >= previous.start })

        var logs: [String] = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        XCTAssertTrue(logs.contains { $0.hasPrefix("Activity context: saved") && $0.hasSuffix(day.key) },
                      "the day's input changed with the day before it: \(logs)")
        XCTAssertFalse(logs.contains { $0.hasPrefix("Activity context: saved") && $0.hasSuffix(previous.key) })
        let secondLedgerRow = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertNotEqual(secondLedgerRow?.inputFingerprint, firstLedger.inputFingerprint)
        let seenRows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        // Every still row in the first 90 s settles on the walk (the decode can open with a few-second fragment).
        let opening = seenRows.filter { $0.startTs < day.start + 90 }
        XCTAssertFalse(opening.isEmpty)
        for row in opening where !(ActivityClass(rawValue: row.activityClass)?.isMovement ?? true) {
            XCTAssertEqual(row.settledFromTs, min(row.endTs, day.start + 90), "settles after the walk: \(row.startTs - day.start)")
            XCTAssertEqual(row.settlingSeconds, min(row.endTs, day.start + 90) - row.startTs)
        }
        XCTAssertTrue(opening.contains { $0.settledFromTs == day.start + 90 }, "the row holding +90 s settles from it")

        // Nothing new: nothing is written again.
        logs = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        XCTAssertFalse(logs.contains { $0.hasPrefix("Activity context: saved") }, "\(logs)")
    }

    // MARK: Strap change (D5-08)

    @MainActor
    func testADayHandedToANewStrapIsStoredUnderItAloneInOneWrite() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        // First only the canonical history holds the day.
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: Repository.whoopSource)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let canonicalLedger = try await store.activityContextDay(deviceId: Repository.whoopSource, day: day.key)
        XCTAssertNotNil(canonicalLedger)

        // Then the active strap's own data for the same day arrives: it owns the day now.
        _ = try await store.insert(desk(from: day.start + 12 * 3_600, seconds: 1_800), deviceId: id)
        await coordinator(repo).drainMaterialization(pauseNs: 0)
        let owned = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertNotNil(owned)
        let leftover = try await store.activityContextDay(deviceId: Repository.whoopSource, day: day.key)
        XCTAssertNil(leftover, "the old owner's ledger went with the hand-off")
        let leftoverRows = try await store.activityContextIntervals(deviceId: Repository.whoopSource, from: day.start, to: day.end)
        XCTAssertTrue(leftoverRows.isEmpty)
        let stored = await repo.storedActivityContext(from: day.start, to: day.end, feedback: [])
        XCTAssertTrue(stored.intervals.contains { $0.start <= day.start + 9 * 3_600 + 60 && day.start + 9 * 3_600 + 60 < $0.end },
                      "the canonical history's stretch is described by the new owner's decode")
    }

    // MARK: Stale days (D5-11)

    @MainActor
    func testADayThatLostItsHeartRateIsCleared() async throws {
        let (repo, store, id) = try await fixture()
        let day = oldDay
        _ = try await store.insert(desk(from: day.start + 9 * 3_600, seconds: 1_800), deviceId: id)
        var logs: [String] = []
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        let saved = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertNotNil(saved)

        // Every raw row is purged (as the implausible-timestamp heal does with a bad clock's rows).
        try await store.healImplausibleTimestamps(now: 0)
        await coordinator(repo, logs: { logs.append($0) }).drainMaterialization(pauseNs: 0)
        let gone = try await store.activityContextDay(deviceId: id, day: day.key)
        XCTAssertNil(gone)
        let rows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("cleared \(day.key)") })
    }

    // MARK: One id set for every stream (D5-10), the 25-hour day (D3-12)

    @MainActor
    func testStepsAndWristEventsAreReadUnderEveryRawIdLikeHeartRate() async throws {
        let (repo, store, id) = try await fixture()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "whoop-retained", brand: "WHOOP", model: "4.0",
            sourceKind: .liveBLE, capabilities: [.hr], status: .archived, addedAt: 1, lastSeenAt: 1))
        XCTAssertFalse(repo.importedReadIds.contains("whoop-retained"))
        let day = oldDay
        var streams = desk(from: day.start + 9 * 3_600, seconds: 600)
        streams.events = [WhoopEvent(ts: day.start + 9 * 3_600 + 300, kind: "WRIST_OFF", payload: [:])]
        _ = try await store.insert(streams, deviceId: "whoop-retained")
        let loaded = await repo.dayStreams(dayStart: Date(timeIntervalSince1970: TimeInterval(day.start)),
                                           dayEnd: Date(timeIntervalSince1970: TimeInterval(day.end)))
        let read = try XCTUnwrap(loaded)
        XCTAssertEqual(read.hr.count, 600)
        XCTAssertEqual(read.stepCounter.count, 600, "the retained strap's step counter is read with its heart rate")
        XCTAssertFalse(read.offWrist.isEmpty, "and its wrist-off event")
        XCTAssertEqual(read.ownerId, "whoop-retained")
        XCTAssertFalse(repo.serverWindowsApply(toDayOwnedBy: read.ownerId),
                       "the active strap's server windows never decode a day another strap owns")
        XCTAssertTrue(repo.serverWindowsApply(toDayOwnedBy: id))
    }

    func testTheFallBackDayIsTwentyFiveHoursLong() throws {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = Int(la.date(from: DateComponents(year: 2026, month: 11, day: 1))!.timeIntervalSince1970)
        XCTAssertEqual(Repository.localDayEnd(startingAt: start, calendar: la) - start, 90_000)
        let spring = Int(la.date(from: DateComponents(year: 2026, month: 3, day: 8))!.timeIntervalSince1970)
        XCTAssertEqual(Repository.localDayEnd(startingAt: spring, calendar: la) - spring, 82_800)
        XCTAssertEqual(Repository.localDayEnd(startingAt: start + 60, calendar: la) - start - 60, 86_400,
                       "a start that is not a local midnight reads 24 hours")
    }

    @MainActor
    func testTheLastHourOfAFallBackDayIsRead() async throws {
        let (repo, store, id) = try await fixture()
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // 2025-11-02 is the latest fall-back day already in the past.
        let start = Int(la.date(from: DateComponents(year: 2025, month: 11, day: 2))!.timeIntervalSince1970)
        let end = start + 90_000
        _ = try await store.insert(desk(from: end - 1_800, seconds: 1_800), deviceId: id)
        let loaded = await repo.dayStreams(dayStart: Date(timeIntervalSince1970: TimeInterval(start)),
                                           dayEnd: Date(timeIntervalSince1970: TimeInterval(end)))
        let read = try XCTUnwrap(loaded)
        XCTAssertEqual(read.end - read.start, 90_000)
        XCTAssertEqual(read.hr.count, 1_800, "23:30-24:00 local is the 25th hour and is decoded")
        XCTAssertFalse(read.isLiveDay)
    }

    // MARK: Serving (D5-V02, D3-15)

    @MainActor
    func testStoredContextLeavesOutDaysFromAnotherRuleSetAndFlagsProvisionalOnes() async throws {
        let (repo, store, id) = try await fixture()
        let days = ActivityContextMaterialization.localDays(endingAt: now, count: 3, timeZone: .current)
        func ledger(_ d: ActivityContextMaterialization.Day, decoder: String, finality: String) -> ActivityContextDayRow {
            ActivityContextDayRow(day: d.key, dayStart: d.start, dayEnd: d.end,
                                  taxonomyVersion: ActivityClassVersions.taxonomy, decoderVersion: decoder,
                                  ontologyVersion: ActivityContextVersions.ontology,
                                  intervalVersion: ActivityClassVersions.interval, dataThrough: d.start + 1_200,
                                  computedAt: d.end, featureSchema: ActivityContextVersions.featureSchema,
                                  configTag: repo.activityContextLedgerConfigTag(dayStart: d.start), finality: finality)
        }
        let old = days[2], recent = days[1]
        try await store.replaceActivityContext(
            deviceId: id, day: ledger(old, decoder: "hsmm-0.1", finality: "final"),
            intervals: [ActivityContextIntervalRow(startTs: old.start + 600, endTs: old.start + 1_200, activityClass: "sitting", confidence: 0.8)])
        try await store.replaceActivityContext(
            deviceId: id, day: ledger(recent, decoder: ActivityContextVersions.decoder, finality: "provisional"),
            intervals: [ActivityContextIntervalRow(startTs: recent.start + 600, endTs: recent.start + 1_200, activityClass: "walking", confidence: 0.8)])

        let stored = await repo.storedActivityContextWithStatus(from: old.start, to: recent.end, feedback: [])
        XCTAssertEqual(stored.intervals.map(\.activityClass), [.walking], "the old decoder's labels are not served")
        XCTAssertEqual(stored.days.map(\.status), [.stale, .current])
        XCTAssertEqual(stored.days.map(\.isProvisional), [false, true])
        XCTAssertEqual(stored.days.last?.decoderVersion, ActivityContextVersions.decoder)
        XCTAssertTrue(stored.hasProvisionalContext)
        XCTAssertEqual(stored.through, recent.start + 1_200)
        let plain = await repo.storedActivityContext(from: old.start, to: recent.end, feedback: [])
        XCTAssertEqual(plain.intervals, stored.intervals)
    }

    // MARK: HR reference as of each day (D1-14)

    @MainActor
    func testANewNightDoesNotChangeThePastDaysDecoderConfig() async throws {
        let (repo, _, _) = try await fixture()
        func night(_ day: String, _ rhr: Int) -> DailyMetric {
            DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        }
        var la = Calendar(identifier: .gregorian)
        la.timeZone = .current
        let pastStart = Int(la.date(from: DateComponents(year: 2026, month: 9, day: 10))!.timeIntervalSince1970)
        // Four earlier nights, median 55 (the reference rounds it to 54); one more night at 90 would make it 60.
        repo.days = [(6, 50), (7, 50), (8, 60), (9, 60)].map { night(String(format: "2026-09-%02d", $0.0), $0.1) }
        let before = repo.activityDecoderConfig(forDayStart: pastStart)
        XCTAssertEqual(before.restingHeartRate, 54)
        let tagBefore = repo.activityContextLedgerConfigTag(dayStart: pastStart)
        // The day's own night (keyed by its wake day, so it ends on the morning of the 10th) is later than the
        // day's first seconds: a causal decode of the 10th never reads it.
        repo.days.append(night("2026-09-10", 90))
        XCTAssertEqual(repo.activityDecoderConfig(forDayStart: pastStart).restingHeartRate, before.restingHeartRate,
                       "the day's own night is not part of its reference")
        repo.days += (11...30).map { night(String(format: "2026-09-%02d", $0), 70) }
        XCTAssertEqual(repo.activityDecoderConfig(forDayStart: pastStart).restingHeartRate, before.restingHeartRate,
                       "later nights never reach back into a past day's reference")
        XCTAssertEqual(repo.activityContextLedgerConfigTag(dayStart: pastStart), tagBefore,
                       "so the past day's stored context stays current")
        XCTAssertGreaterThan(repo.activityDecoderConfig.restingHeartRate, before.restingHeartRate + 10,
                             "today's reference follows the latest nights")
        repo.days = []
    }

    // MARK: Gait lane mode (D1-06)

    func testShadowGaitDaysNeverReachTheDecoderAndTheModeIsRecorded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scope = ActivityEncoderWindowStore.Scope(ownerId: "owner-1", deviceId: "whoop-1")
        let store = GaitWindowStore(directory: dir, scope: { scope })
        let model = GaitQualityModelInfo(modelVersion: GaitWindowStore.Pins.modelVersion,
                                         weights: ["gait_detection": String(repeating: "a", count: 64)],
                                         upstreamCommit: "437a38b", hopS: 5)
        func record(_ day: String, _ mode: String) -> GaitWindowStore.DayRecord {
            GaitWindowStore.DayRecord(day: day, resultRevision: "rev-\(day)", mode: mode, model: model, windowsJSON: "{}")
        }
        XCTAssertTrue(store.save(record("2026-10-06", "shadow"), scope: scope))
        XCTAssertNil(store.latestModel, "a shadow-only lane gives the decoder nothing")
        XCTAssertNil(store.latestMode)
        XCTAssertTrue(store.save(record("2026-10-05", "candidate"), scope: scope))
        XCTAssertEqual(store.latestModel, model, "the newest non-shadow day names the model")
        XCTAssertEqual(store.latestMode, "candidate")
    }

    // MARK: Spot HRV (D3-04, D6-16)

    func testASpotReadingKeepsItsOwnTimeSupportAndNoCopyOfTheContext() {
        let result = HRVAnalyzer.HRVResult(rmssd: 48.5, sdnn: 52, meanNN: 950, pnn50: nil, nInput: 64, nClean: 61)
        let t0 = 1_791_000_000
        let reading = HRVSnapshot.reading(result: result, start: t0, end: t0 + 60, createdAt: t0 + 61)
        XCTAssertEqual(reading?.startTs, t0)
        XCTAssertEqual(reading?.endTs, t0 + 60)
        XCTAssertEqual(reading?.rmssd, 48.5)
        XCTAssertEqual(reading?.sdnn, 52)
        XCTAssertEqual(reading?.meanNN, 950)
        XCTAssertEqual(reading?.cleanBeats, 61)
        XCTAssertEqual(reading?.inputBeats, 64)
        XCTAssertEqual(reading?.source, "manual-hrv")
        XCTAssertEqual(reading?.methodVersion, HRVSnapshot.methodVersion)
        XCTAssertEqual(reading?.createdAt, t0 + 61)
        XCTAssertNil(HRVSnapshot.reading(result: result, start: t0, end: t0, createdAt: t0), "an empty capture span")
        let none = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil, nInput: 10, nClean: 0)
        XCTAssertNil(HRVSnapshot.reading(result: none, start: t0, end: t0 + 60, createdAt: t0))
    }
}
