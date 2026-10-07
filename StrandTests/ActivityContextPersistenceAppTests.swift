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
        let stored = await repo.storedActivityContext(from: day.start, to: day.end)
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

        let stored = await repo.storedActivityContextWithStatus(from: old.start, to: recent.end)
        XCTAssertEqual(stored.intervals.map(\.activityClass), [.walking], "the old decoder's labels are not served")
        XCTAssertEqual(stored.days.map(\.status), [.stale, .current])
        XCTAssertEqual(stored.days.map(\.isProvisional), [false, true])
        XCTAssertEqual(stored.days.last?.decoderVersion, ActivityContextVersions.decoder)
        XCTAssertTrue(stored.hasProvisionalContext)
        XCTAssertEqual(stored.through, recent.start + 1_200)
        let plain = await repo.storedActivityContext(from: old.start, to: recent.end)
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
        repo.days = (1...10).map { night(String(format: "2026-09-%02d", $0), 50) }
        let before = repo.activityDecoderConfig(forDayStart: pastStart)
        let tagBefore = repo.activityContextLedgerConfigTag(dayStart: pastStart)
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

    func testASpotReadingKeepsItsOwnTimeSupportAndTheContextOverIt() {
        let result = HRVAnalyzer.HRVResult(rmssd: 48.5, sdnn: 52, meanNN: 950, pnn50: nil, nInput: 64, nClean: 61)
        let t0 = 1_791_000_000
        let context = Repository.StoredActivityContext(
            intervals: [
                ActivityContextInterval(start: t0 - 600, end: t0 + 10, activityClass: .walking, confidence: 0.9),
                ActivityContextInterval(start: t0 + 10, end: t0 + 900, activityClass: .sitting, confidence: 0.7,
                                        posture: .seatedLikely),
            ],
            through: t0 + 900,
            days: [Repository.StoredActivityContextDay(day: "d", dayStart: t0 - 3_600, dayEnd: t0 + 80_000,
                                                       deviceId: "s", status: .current, isProvisional: true,
                                                       decoderVersion: "hsmm-x", configTag: nil,
                                                       dataThrough: t0 + 900, computedAt: t0 + 900)])
        let reading = HRVSnapshot.reading(result: result, start: t0, end: t0 + 60, context: context, createdAt: t0 + 61)
        XCTAssertEqual(reading?.startTs, t0)
        XCTAssertEqual(reading?.endTs, t0 + 60)
        XCTAssertEqual(reading?.rmssd, 48.5)
        XCTAssertEqual(reading?.cleanBeats, 61)
        XCTAssertEqual(reading?.inputBeats, 64)
        XCTAssertEqual(reading?.source, "manual-hrv")
        XCTAssertEqual(reading?.methodVersion, HRVSnapshot.methodVersion)
        XCTAssertEqual(reading?.ctxClass, "sitting", "the interval covering most of the capture")
        XCTAssertEqual(reading?.ctxPosture, "seated_likely")
        XCTAssertEqual(reading?.ctxDecoderVersion, "hsmm-x")
        let bare = HRVSnapshot.reading(result: result, start: t0, end: t0 + 60, context: nil, createdAt: t0 + 61)
        XCTAssertNil(bare?.ctxClass, "no stored context yet: the time join stays the way to it")
        let none = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil, nInput: 10, nClean: 0)
        XCTAssertNil(HRVSnapshot.reading(result: none, start: t0, end: t0 + 60, context: nil, createdAt: t0))
    }
}
