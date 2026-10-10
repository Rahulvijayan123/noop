import XCTest
import StrandAnalytics
@testable import Strand

/// Workout mode on the phone (docs/context-watchdog/WORKOUTS.md): the log survives a relaunch, edits wait in the
/// offline queue until the server accepts them, the strap screen's section reads its states from the log, and the
/// decoder sees a logged workout by its type.
@MainActor
final class WorkoutModeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "WorkoutModeStoreTests"
    private let t0 = 1_790_000_000

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRunningWorkoutSurvivesARelaunch() throws {
        let store = WorkoutModeStore(defaults: defaults)
        try store.mutate { try $0.start(typeId: "indoor_walk", now: t0, id: "a") }
        let relaunched = WorkoutModeStore(defaults: defaults)
        XCTAssertEqual(relaunched.active?.id, "a")
        XCTAssertEqual(relaunched.active?.typeId, "indoor_walk")
        XCTAssertEqual(relaunched.spans(from: t0, to: t0 + 3600, now: t0 + 600),
                       [LoggedWorkoutSpan(startUnix: t0, endUnix: t0 + 600, typeId: "indoor_walk", open: true)])
        // A throwing edit changes nothing on disk either.
        XCTAssertThrowsError(try relaunched.mutate { try $0.start(typeId: "yoga", now: t0 + 60) })
        XCTAssertEqual(WorkoutModeStore(defaults: defaults).log, relaunched.log)
    }

    func testACorruptOrForeignEntryIsDropped() throws {
        let log = WorkoutModeLog(entries: [
            WorkoutModeEntry(id: "ok", typeId: "yoga", startUnix: t0, endUnix: t0 + 600, updatedUnix: t0),
            WorkoutModeEntry(id: "unknown", typeId: "no_such_type", startUnix: t0, updatedUnix: t0),
            WorkoutModeEntry(id: "inverted", typeId: "yoga", startUnix: t0, endUnix: t0 - 1, updatedUnix: t0),
        ])
        defaults.set(try JSONEncoder().encode(log), forKey: WorkoutModeStore.defaultsKey)
        XCTAssertEqual(WorkoutModeStore(defaults: defaults).log.entries.map(\.id), ["ok"])
        defaults.set(Data("garbage".utf8), forKey: WorkoutModeStore.defaultsKey)
        XCTAssertEqual(WorkoutModeStore(defaults: defaults).log, .empty)
    }

    /// Offline first: nothing is marked sent until the server accepted it; a failed upload is sent again; closed
    /// workouts go before the open one; the queue drains in batches.
    func testSyncQueue() async throws {
        let store = WorkoutModeStore(defaults: defaults)
        try store.mutate { log in
            try log.logPast(typeId: "strength", startUnix: t0 - 7200, endUnix: t0 - 3600, now: t0, id: "past")
            try log.start(typeId: "indoor_cycling", now: t0, id: "open")
        }
        var bodies: [[String: Any]] = []
        await store.sync(serverDeviceId: "whoop-MG1", localDeviceId: "my-whoop", now: t0, force: true) { body in
            bodies.append(body)
            return false
        }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(store.log.pendingSync.count, 2, "offline: still pending")
        XCTAssertEqual(WorkoutModeStore(defaults: defaults).log.pendingSync.count, 2, "and still pending after a relaunch")

        bodies = []
        await store.sync(serverDeviceId: "whoop-MG1", localDeviceId: "my-whoop", now: t0 + 1, force: true) { body in
            bodies.append(body)
            return true
        }
        let sent = try XCTUnwrap(bodies.first?["workouts"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["client_id"] as? String }, ["past", "open"], "closed ones first")
        XCTAssertEqual(bodies.first?["device_id"] as? String, "whoop-MG1")
        XCTAssertTrue(store.log.pendingSync.isEmpty)

        // A stop is an edit: pending again, then sent.
        try store.mutate { _ = try $0.stop(now: t0 + 1800) }
        XCTAssertEqual(store.log.pendingSync.map(\.id), ["open"])
        bodies = []
        await store.sync(serverDeviceId: "whoop-MG1", localDeviceId: nil, now: t0 + 30) { body in
            bodies.append(body)
            return true
        }
        XCTAssertTrue(bodies.isEmpty, "a background retry within a minute of the last attempt is throttled")
        await store.sync(serverDeviceId: nil, localDeviceId: nil, now: t0 + 1900, force: true) { _ in
            XCTFail("no strap device on the account yet: nothing is sent")
            return true
        }
        await store.sync(serverDeviceId: "whoop-MG1", localDeviceId: nil, now: t0 + 1902, force: true) { body in
            bodies.append(body)
            return true
        }
        let stop = try XCTUnwrap((bodies.first?["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["ended_at"] as? Int, t0 + 1800)
        XCTAssertTrue(store.log.pendingSync.isEmpty)

        // More than one batch.
        try store.mutate { log in
            for i in 0..<(WorkoutModeLog.syncBatch + 5) {
                try log.logPast(typeId: "yoga", startUnix: t0 + 10_000 + i * 200, endUnix: t0 + 10_100 + i * 200,
                                now: t0 + 30_000, id: "y\(i)")
            }
        }
        var batches = 0
        await store.sync(serverDeviceId: "whoop-MG1", localDeviceId: nil, now: t0 + 30_000, force: true) { body in
            batches += 1
            XCTAssertLessThanOrEqual((body["workouts"] as? [Any])?.count ?? 0, WorkoutModeLog.syncBatch)
            return true
        }
        XCTAssertEqual(batches, 2)
        XCTAssertTrue(store.log.pendingSync.isEmpty)
    }

    func testSectionModelStates() throws {
        var log = WorkoutModeLog.empty
        var model = WorkoutModeSectionModel(log: log, now: t0)
        XCTAssertFalse(model.running)
        XCTAssertNil(model.elapsedText)
        XCTAssertTrue(model.recent.isEmpty)

        try log.start(typeId: "strength", now: t0, id: "a")
        model = WorkoutModeSectionModel(log: log, now: t0 + 42 * 60)
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.typeId, "strength")
        XCTAssertEqual(model.title, "Strength training")
        XCTAssertEqual(model.elapsedText, "42 min")
        XCTAssertEqual(model.symbolSport, "Strength")
        // Past the cap the running clock stops at 4 h (the next tick auto-ends it).
        XCTAssertEqual(WorkoutModeSectionModel(log: log, now: t0 + 6 * 3600).elapsedText, "4 h 00 min")

        _ = log.autoEndIfOverdue(now: t0 + 6 * 3600)
        try log.logPast(typeId: "indoor_walk", startUnix: t0 + 7 * 3600, endUnix: t0 + 7 * 3600 + 1800,
                        now: t0 + 8 * 3600, id: "b")
        model = WorkoutModeSectionModel(log: log, now: t0 + 8 * 3600)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.recent.map(\.id), ["b", "a"], "newest first")
        XCTAssertEqual(model.recent.map(\.autoEnded), [false, true])
        XCTAssertTrue(model.recent[0].detail.hasSuffix("30 min"), model.recent[0].detail)
    }

    func testDurationText() {
        XCTAssertEqual(WorkoutModeSectionModel.duration(45), "0:45")
        XCTAssertEqual(WorkoutModeSectionModel.duration(60), "1 min")
        XCTAssertEqual(WorkoutModeSectionModel.duration(3600 + 5 * 60), "1 h 05 min")
    }

    /// The decoder's day input: a running workout up to now, and a logged one with no saved row, under its type's
    /// stored sport name; a saved row at the same start is that workout.
    func testDecoderInputGetsLoggedWorkoutsByType() {
        let stored = [DayStateWorkout(start: t0, end: t0 + 1800, sport: "Strength")]
        let logged = [LoggedWorkoutSpan(startUnix: t0 + 20, endUnix: t0 + 1800, typeId: "strength"),
                      LoggedWorkoutSpan(startUnix: t0 + 7200, endUnix: t0 + 7500, typeId: "indoor_cycling", open: true)]
        let out = Repository.withLoggedWorkouts(stored, logged: logged)
        XCTAssertEqual(out, [DayStateWorkout(start: t0, end: t0 + 1800, sport: "Strength"),
                             DayStateWorkout(start: t0 + 7200, end: t0 + 7500, sport: "Indoor cycle")])
        XCTAssertEqual(WorkoutKind(sport: out[1].sport), .cycling)
    }
}
