import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The app side of the activity classifier work: the coordinator that saves each day's context to the store and
/// decides stand reminders, the saved-context reads, the coach tool, and the reminder's stored settings.
final class ActivityContextAppTests: XCTestCase {

    // MARK: Fixtures

    /// A wrist, second by second, with the shapes the decoder is built for (resting desk work, walking).
    private struct Wrist {
        var ts: Int
        private(set) var hr: [HRSample] = []
        private(set) var gravity: [GravitySample] = []
        private(set) var steps: [StepSample] = []
        private var counter = 5_000
        private var tick = 0

        init(start: Int) { ts = start }

        private mutating func noise() -> Double {
            tick += 1
            let x = sin(Double(tick) * 12.9898) * 43_758.5453
            return x - x.rounded(.down)
        }

        private mutating func add(dyn: Double, ticks: Int, bpm: Int, tiltDeg: Double, cls: Int) {
            let r = tiltDeg * .pi / 180
            gravity.append(GravitySample(ts: ts, x: 0.2, y: cos(r) * 0.9, z: sin(r) * 0.9 + 0.35, dynAccel: dyn))
            counter += ticks
            steps.append(StepSample(ts: ts, counter: counter, activityClass: cls))
            hr.append(HRSample(ts: ts, bpm: bpm))
            ts += 1
        }

        mutating func desk(_ seconds: Int, bpm: Int = 66) {
            for _ in 0..<seconds {
                add(dyn: 0.015 + noise() * 0.05, ticks: 0, bpm: bpm, tiltDeg: (noise() - 0.5) * 1.6, cls: 0)
            }
        }

        mutating func walk(_ seconds: Int) {
            for i in 0..<seconds {
                add(dyn: 0.135 + (noise() - 0.5) * 0.08, ticks: i % 2 == 0 ? 2 : 1, bpm: 104,
                    tiltDeg: (noise() - 0.5) * 20, cls: 1)
            }
        }

        var streams: Streams { Streams(hr: hr, gravity: gravity, steps: steps) }
    }

    private final class Recorder {
        var reminders: [(loops: UInt8, minutes: Int)] = []
        var logs: [String] = []
    }

    private let defaultsKeys = [
        "inactivity.enabled", "inactivity.thresholdMinutes", "inactivity.reNudgeMinutes", "inactivity.buzzLoops",
        "inactivity.activeHoursEnabled", "notif.masterEnabled", "notif.onlyWhenWorn", "notif.quietHoursEnabled",
        "inactivity.stand.evaluatedThrough", "inactivity.stand.lastRemindAt",
    ]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedDefaults = defaultsKeys.reduce(into: [:]) { $0[$1] = d.object(forKey: $1) }
        defaultsKeys.forEach(d.removeObject(forKey:))
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for key in defaultsKeys {
            if let value = savedDefaults[key] { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func turnReminderOn(window: Int = 50) {
        let d = UserDefaults.standard
        d.set(true, forKey: "inactivity.enabled")
        d.set(true, forKey: "notif.masterEnabled")
        d.set(false, forKey: "notif.onlyWhenWorn")
        d.set(false, forKey: "notif.quietHoursEnabled")
        d.set(false, forKey: "inactivity.activeHoursEnabled")
        d.set(window, forKey: "inactivity.thresholdMinutes")
    }

    @MainActor
    private func fixture(deviceId: String = "act-ctx-\(UUID().uuidString)") async throws
        -> (repo: Repository, store: WhoopStore, deviceId: String) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        addTeardownBlock { ActivityContextFileStore.shared.removeAll(forDevice: deviceId) }
        return (repo, store, deviceId)
    }

    @MainActor
    private func coordinator(_ repo: Repository, _ recorder: Recorder, days: Int = 3) -> ActivityContextCoordinator {
        ActivityContextCoordinator(
            repo: repo, horizonDays: days, isWorn: { true },
            remind: { recorder.reminders.append(($0, $1)) }, log: { recorder.logs.append($0) })
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    private var localDays: [ActivityContextMaterialization.Day] {
        ActivityContextMaterialization.localDays(endingAt: now, count: 3, timeZone: .current)
    }

    // MARK: Saving the day's context

    @MainActor
    func testAClosedDayIsSavedOnceAndAnIdlePassWritesNothing() async throws {
        let (repo, store, id) = try await fixture()
        let day = localDays[1]
        var wrist = Wrist(start: day.start + 9 * 3_600)
        wrist.desk(2 * 3_600)
        wrist.walk(600)
        wrist.desk(900)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let recorder = Recorder()
        let sut = coordinator(repo, recorder)
        await sut.drainMaterialization(pauseNs: 0)

        let ledger = try await store.activityContextDay(deviceId: id, day: day.key)
        let row = try XCTUnwrap(ledger, "the day has a ledger row")
        XCTAssertTrue(ActivityContextPersistence.isCurrent(row))
        XCTAssertEqual(row.dayStart, day.start)
        XCTAssertEqual(row.dayEnd, day.end)
        XCTAssertGreaterThan(row.intervalCount, 0)

        let rows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        XCTAssertEqual(rows.count, row.intervalCount)
        XCTAssertGreaterThanOrEqual(rows.first?.startTs ?? 0, wrist.hr[0].ts - 30, "nothing is invented before the data")
        XCTAssertLessThanOrEqual(rows.last?.endTs ?? .max, wrist.ts + 30)
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endTs, b.startTs, "intervals never overlap")
        }
        XCTAssertTrue(rows.allSatisfy { ActivityClass(rawValue: $0.activityClass) != nil }, "only canonical codes are stored")

        let desk = try XCTUnwrap(rows.first { $0.startTs <= day.start + 10 * 3_600 && $0.endTs > day.start + 10 * 3_600 })
        let deskClass = try XCTUnwrap(ActivityClass(rawValue: desk.activityClass))
        XCTAssertTrue(deskClass.isStationaryAwake, "an hour into desk work the wearer is still: \(deskClass)")
        XCTAssertEqual(try XCTUnwrap(desk.hrMean), 66, accuracy: 1.5, "the interval carries the heart rate measured during it")

        let walkMid = day.start + 9 * 3_600 + 2 * 3_600 + 300
        let walk = try XCTUnwrap(rows.first { $0.startTs <= walkMid && $0.endTs > walkMid })
        XCTAssertTrue(try XCTUnwrap(ActivityClass(rawValue: walk.activityClass)).isMovement, "\(walk.activityClass)")
        XCTAssertGreaterThan(walk.stepTicks, 0)
        XCTAssertEqual(try XCTUnwrap(walk.hrMean), 104, accuracy: 2)

        // Nothing changed, so nothing is written again.
        let beforeRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let before = try XCTUnwrap(beforeRow)
        let logsBefore = recorder.logs.count
        await sut.drainMaterialization(pauseNs: 0)
        let afterRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let after = try XCTUnwrap(afterRow)
        XCTAssertEqual(before, after)
        XCTAssertEqual(recorder.logs.count, logsBefore, "an up-to-date day is not re-saved or logged")
    }

    @MainActor
    func testLaterHeartRateExtendsADayAndNothingOutsideItIsTouched() async throws {
        let (repo, store, id) = try await fixture()
        let day = localDays[1]
        var wrist = Wrist(start: day.start + 8 * 3_600)
        wrist.desk(1_800)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let sut = coordinator(repo, Recorder())
        await sut.drainMaterialization(pauseNs: 0)
        let firstRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let first = try XCTUnwrap(firstRow)

        var more = Wrist(start: wrist.ts)
        more.desk(1_800)
        _ = try await store.insert(more.streams, deviceId: id)
        await sut.drainMaterialization(pauseNs: 0)

        let secondRow = try await store.activityContextDay(deviceId: id, day: day.key)
        let second = try XCTUnwrap(secondRow)
        XCTAssertGreaterThan(try XCTUnwrap(second.dataThrough), try XCTUnwrap(first.dataThrough),
                             "the ledger reaches the new data")
        let rows = try await store.activityContextIntervals(deviceId: id, from: day.start, to: day.end)
        XCTAssertGreaterThanOrEqual(rows.last?.endTs ?? 0, more.ts - 30)
        let other = try await store.activityContextIntervals(deviceId: id, from: localDays[0].start, to: localDays[0].end)
        XCTAssertTrue(other.isEmpty, "today has no data and gets no rows")
    }

    @MainActor
    func testADayWithNoHeartRateIsNeitherDecodedNorGivenALedgerRow() async throws {
        let (repo, store, id) = try await fixture()
        let sut = coordinator(repo, Recorder())
        await sut.drainMaterialization(pauseNs: 0)
        for day in localDays {
            let ledger = try await store.activityContextDay(deviceId: id, day: day.key)
            XCTAssertNil(ledger)
        }
    }

    @MainActor
    func testTheSavedContextIsReadBackAcrossDevicesWithTheActiveStrapFirst() async throws {
        let (repo, store, id) = try await fixture()
        let day = localDays[1]
        let t0 = day.start + 10 * 3_600
        func ledger(_ through: Int) -> ActivityContextDayRow {
            ActivityContextDayRow(day: day.key, dayStart: day.start, dayEnd: day.end,
                                  taxonomyVersion: ActivityClassVersions.taxonomy,
                                  decoderVersion: ActivityContextVersions.decoder,
                                  ontologyVersion: ActivityContextVersions.ontology,
                                  intervalVersion: ActivityClassVersions.interval,
                                  dataThrough: through, observedSeconds: 600, intervalCount: 1, computedAt: day.end + 60)
        }
        try await store.replaceActivityContext(
            deviceId: id, day: ledger(t0 + 600),
            intervals: [ActivityContextIntervalRow(startTs: t0, endTs: t0 + 600, activityClass: "sitting_desk", confidence: 0.8)])
        try await store.replaceActivityContext(
            deviceId: "my-whoop", day: ledger(t0 + 1_200),
            intervals: [
                ActivityContextIntervalRow(startTs: t0 + 300, endTs: t0 + 900, activityClass: "walking", confidence: 0.7),
                ActivityContextIntervalRow(startTs: t0 + 900, endTs: t0 + 1_200, activityClass: "running", confidence: 0.7),
            ])

        let stored = await repo.storedActivityContext(from: t0 - 60, to: t0 + 1_500)
        XCTAssertEqual(stored.intervals.map(\.activityClass), [.sittingDesk, .running],
                       "the walking stretch overlaps what the active strap already accounts for")
        XCTAssertEqual(stored.intervals.map(\.start), [t0, t0 + 900])
        XCTAssertEqual(stored.through, t0 + 1_200, "the latest horizon among the days in the window")

        let empty = await repo.storedActivityContext(from: t0 + 5_000, to: t0 + 6_000)
        XCTAssertTrue(empty.intervals.isEmpty)
        XCTAssertNil(empty.through)
    }

    // MARK: Stand reminder

    private func liveDayHasRoom() throws {
        let today = localDays[0]
        try XCTSkipIf(now - today.start < 3 * 3_600, "needs three hours of today behind it")
    }

    @MainActor
    func testAnHourOfDeskWorkMakesTheCoordinatorRemind() async throws {
        try liveDayHasRoom()
        turnReminderOn()
        let (repo, store, id) = try await fixture()
        var wrist = Wrist(start: now - 3_600)
        wrist.desk(3_570)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let recorder = Recorder()
        await coordinator(repo, recorder).evaluateStandReminder()

        XCTAssertEqual(recorder.reminders.count, 1, recorder.logs.joined(separator: "\n"))
        XCTAssertEqual(recorder.reminders.first?.minutes, 50)
        XCTAssertEqual(recorder.reminders.first?.loops, 2)
        XCTAssertTrue(recorder.logs.contains { $0.hasPrefix("Stand reminder: remind") }, "\(recorder.logs)")
        XCTAssertGreaterThan(InactivityPrefs.loadStandState().lastRemindAt, 0, "the reminder is remembered")
    }

    @MainActor
    func testAMinuteAndAHalfOfWalkingInTheWindowKeepsItQuietAndTheSameDataIsNotJudgedTwice() async throws {
        try liveDayHasRoom()
        turnReminderOn()
        let (repo, store, id) = try await fixture()
        var wrist = Wrist(start: now - 3_600)
        wrist.desk(1_500)
        wrist.walk(90)
        wrist.desk(1_950)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let recorder = Recorder()
        let sut = coordinator(repo, recorder)
        await sut.evaluateStandReminder()
        XCTAssertTrue(recorder.reminders.isEmpty, recorder.logs.joined(separator: "\n"))
        XCTAssertTrue(recorder.logs.contains { $0.hasPrefix("Stand reminder: movedEnough") }, "\(recorder.logs)")

        let judged = InactivityPrefs.loadStandState().lastEvaluatedThrough
        XCTAssertGreaterThan(judged, 0)
        let logs = recorder.logs.count
        await sut.evaluateStandReminder()
        XCTAssertEqual(recorder.logs.count, logs, "an unchanged outcome is not logged again")
        XCTAssertEqual(InactivityPrefs.loadStandState().lastEvaluatedThrough, judged)
    }

    @MainActor
    func testTwentySecondsOfWalkingIsNotEnough() async throws {
        try liveDayHasRoom()
        turnReminderOn()
        let (repo, store, id) = try await fixture()
        var wrist = Wrist(start: now - 3_600)
        wrist.desk(1_500)
        wrist.walk(20)
        wrist.desk(2_020)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let recorder = Recorder()
        await coordinator(repo, recorder).evaluateStandReminder()
        XCTAssertEqual(recorder.reminders.count, 1, recorder.logs.joined(separator: "\n"))
    }

    @MainActor
    func testNothingHappensUnlessTheUserTurnedTheReminderOn() async throws {
        try liveDayHasRoom()
        let (repo, store, id) = try await fixture()
        var wrist = Wrist(start: now - 3_600)
        wrist.desk(3_570)
        _ = try await store.insert(wrist.streams, deviceId: id)

        let recorder = Recorder()
        await coordinator(repo, recorder).evaluateStandReminder()
        XCTAssertTrue(recorder.reminders.isEmpty)
        XCTAssertTrue(recorder.logs.isEmpty)
        XCTAssertEqual(InactivityPrefs.loadStandState(), StandReminderEngine.State.initial)
    }

    // MARK: Settings

    @MainActor
    func testTheStoredThresholdIsTheRollingWindowAndDefaultsToFiftyMinutes() {
        XCTAssertEqual(InactivityPrefs.loadStandConfig().windowMinutes, 50)
        UserDefaults.standard.set(30, forKey: "inactivity.thresholdMinutes")
        XCTAssertEqual(InactivityPrefs.loadStandConfig().windowMinutes, 30)
        UserDefaults.standard.set(5_000, forKey: "inactivity.thresholdMinutes")
        XCTAssertEqual(InactivityPrefs.loadStandConfig().windowMinutes, 240, "a corrupt value is clamped, not trusted")
        UserDefaults.standard.set(0, forKey: "inactivity.thresholdMinutes")
        XCTAssertEqual(InactivityPrefs.loadStandConfig().windowMinutes, 5)
    }

    @MainActor
    func testTheReminderStateSurvivesARelaunch() {
        XCTAssertEqual(InactivityPrefs.loadStandState(), .initial)
        InactivityPrefs.saveStandState(.init(lastEvaluatedThrough: 1_790_000_000, lastRemindAt: 1_789_999_000))
        XCTAssertEqual(InactivityPrefs.loadStandState(),
                       StandReminderEngine.State(lastEvaluatedThrough: 1_790_000_000, lastRemindAt: 1_789_999_000))
    }

    @MainActor
    func testTheLogLineSaysWhatTheRuleSaw() {
        let window = StandReminderEngine.Window(start: 0, end: 3_000, movementSeconds: 42, sedentarySeconds: 2_700,
                                                observedSeconds: 2_940, lastMovementEnd: 100)
        let decision = StandReminderEngine.Decision(shouldRemind: false, reason: .movedEnough, window: window,
                                                    buzzLoops: 2, nextState: .initial)
        XCTAssertEqual(ActivityContextCoordinator.standLogLine(decision, windowMinutes: 50),
                       "Stand reminder: movedEnough (50-min window: 42 s standing or moving, 98% observed, 90% seated)")
        let bare = StandReminderEngine.Decision(shouldRemind: false, reason: .staleData, window: nil,
                                                buzzLoops: 2, nextState: .initial)
        XCTAssertEqual(ActivityContextCoordinator.standLogLine(bare, windowMinutes: 50), "Stand reminder: staleData")
    }

    // MARK: Coach

    private func interval(_ start: Int, _ end: Int, _ cls: ActivityClass, conf: Double = 0.8, hr: Double? = nil,
                          rmssd: Double? = nil, resp: Double? = nil, ticks: Int = 0, cadence: Double? = nil) -> ActivityContextInterval {
        ActivityContextInterval(
            start: start, end: end, activityClass: cls, confidence: conf, stepTicks: ticks, cadenceSpm: cadence,
            hrSamples: hr == nil ? 0 : end - start, hrMean: hr, hrMin: hr.map { Int($0) - 5 }, hrMax: hr.map { Int($0) + 10 },
            rmssd: rmssd, rrBeats: rmssd == nil ? 0 : (end - start) / 2,
            respRateBpm: resp, respBreaths: resp == nil ? 0 : (end - start) / 4)
    }

    func testCoachTextBreaksTheWindowDownByActivityWithTheMeasurementsOfEach() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let from = 1_790_870_400     // 2026-10-01 09:00 America/Los_Angeles
        let items = [
            interval(from, from + 3_600, .sittingDesk, hr: 68, rmssd: 54, resp: 14.2),
            interval(from + 3_600, from + 4_200, .walking, conf: 0.7, hr: 104, ticks: 1_100, cadence: 110),
            interval(from + 4_200, from + 5_400, .sittingDesk, hr: 70, rmssd: 50, resp: 13.8),
        ]
        let text = CoachActivityContext.describe(intervals: items, from: from, to: from + 7_200,
                                                 storedThrough: from + 5_400, timeZone: zone,
                                                 now: Date(timeIntervalSince1970: TimeInterval(from + 5_460)))
        XCTAssertTrue(text.contains("Thu Oct 1 09:00 to Thu Oct 1 11:00 (America/Los_Angeles)"), text)
        XCTAssertTrue(text.contains("Classified 1 h 30 min of the 2 h window (75%)"), text)
        XCTAssertTrue(text.contains("Saved through 10:30."), text)
        XCTAssertTrue(text.contains("• Sitting at a desk, 1 h 20 min (89%)"), text)
        XCTAssertTrue(text.contains("HRV (RMSSD) 53 ms"), "beat-weighted across the two desk stretches: \(text)")
        XCTAssertTrue(text.contains("• Walking, 10 min (11%)"), text)
        XCTAssertTrue(text.contains("1100 steps at about 110 steps/min"), text)
        XCTAssertTrue(text.contains("no HRV or respiratory rate"), "a moving stretch reports none rather than inventing one: \(text)")
        XCTAssertTrue(text.contains("09:00-10:00 Sitting at a desk, 1 h, heart rate 68 bpm, HRV 54 ms"), text)
        XCTAssertTrue(text.contains("Notes: sitting and standing cannot be told apart from a wrist"), text)
    }

    func testCoachTextCanBeScopedToOneActivityAndSaysSoWhenThereIsNone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let from = 1_790_870_400
        let items = [interval(from, from + 3_000, .sittingDesk, hr: 66), interval(from + 3_000, from + 3_600, .walking, hr: 100)]
        let walking = CoachActivityContext.describe(intervals: items, from: from, to: from + 3_600, activity: .walking, timeZone: zone)
        XCTAssertTrue(walking.contains("Only Walking is listed"), walking)
        XCTAssertTrue(walking.contains("• Walking, 10 min (17%)"), walking)
        XCTAssertFalse(walking.contains("• Sitting at a desk"), walking)

        let running = CoachActivityContext.describe(intervals: items, from: from, to: from + 3_600, activity: .running, timeZone: zone)
        XCTAssertTrue(running.contains("None of that time was classified as Running. It was spent as: Sitting at a desk 50 min, Walking 10 min."), running)
    }

    func testCoachTextAdmitsWhenNothingWasSaved() throws {
        let text = CoachActivityContext.describe(intervals: [], from: 1_790_870_400, to: 1_790_874_000,
                                                 timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        XCTAssertTrue(text.hasPrefix("No saved activity context between"), text)
        XCTAssertTrue(text.contains("Do not guess what the user was doing."), text)
    }

    func testCoachTextShowsOnlyTheLatestStretchesAndMergesAdjacentOnes() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let from = 1_790_870_400
        var items: [ActivityContextInterval] = []
        for i in 0..<20 {
            let start = from + i * 1_200
            items.append(interval(start, start + 600, i % 2 == 0 ? .sittingDesk : .walking))
            items.append(interval(start + 600, start + 1_200, i % 2 == 0 ? .sittingDesk : .walking))
        }
        let text = CoachActivityContext.describe(intervals: items, from: from, to: from + 24_000, timeZone: zone, maxStretches: 5)
        XCTAssertTrue(text.contains("Stretches, oldest first (the latest 5 of 20):"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }.count, 5)
    }

    func testActivityNamesAcceptTheCodesAndTheWordsAModelUses() {
        XCTAssertEqual(CoachActivityContext.activity(named: "sitting_desk"), .sittingDesk)
        XCTAssertEqual(CoachActivityContext.activity(named: "Sitting at a desk"), .sittingDesk)
        XCTAssertEqual(CoachActivityContext.activity(named: "brisk-walking"), .briskWalking)
        XCTAssertEqual(CoachActivityContext.activity(named: "HIIT"), .vigorousActivity)
        XCTAssertEqual(CoachActivityContext.activity(named: "asleep"), .sleeping)
        XCTAssertNil(CoachActivityContext.activity(named: "dancing"))
        for c in ActivityClass.allCases {
            XCTAssertEqual(CoachActivityContext.activity(named: c.rawValue), c, "every code round-trips")
        }
    }

    func testDurationsReadNaturally() {
        XCTAssertEqual(CoachActivityContext.duration(0), "0 s")
        XCTAssertEqual(CoachActivityContext.duration(45), "45 s")
        XCTAssertEqual(CoachActivityContext.duration(60), "1 min")
        XCTAssertEqual(CoachActivityContext.duration(3_600), "1 h")
        XCTAssertEqual(CoachActivityContext.duration(3_900), "1 h 5 min")
        XCTAssertEqual(CoachActivityContext.duration(-5), "0 s")
    }

    @MainActor
    func testEveryCoachBundleCanReachTheActivityContextAndTheModelIsToldWhenToUseIt() {
        for question in ["plot my hrv", "show my last workout", "what should I eat", "was my heart rate high while I was sitting",
                         "how was my sleep this week", "should i train hard today"] {
            let names = Set(CoachToolExecutor.definitions(for: question)
                .compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            XCTAssertTrue(names.contains("get_activity_context"), question)
        }
        XCTAssertTrue(CoachVisualEvidence.dataTools.contains("get_activity_context"))
        XCTAssertTrue(CoachPrompt.toolHint.contains("get_activity_context"))
        XCTAssertEqual(CoachToolDisplayNames.label(for: "get_activity_context"), "Activity context")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CoachToolExecutor.definitions))
    }

    @MainActor
    func testTheCoachToolReadsTheSavedContextAndRejectsAnUnknownActivity() async throws {
        let (repo, store, id) = try await fixture()
        let t = now - 3_000
        let day = ActivityContextMaterialization.localDays(endingAt: t, count: 1, timeZone: .current)[0]
        try await store.replaceActivityContext(
            deviceId: id,
            day: ActivityContextDayRow(day: day.key, dayStart: day.start, dayEnd: day.end,
                                       taxonomyVersion: ActivityClassVersions.taxonomy,
                                       decoderVersion: ActivityContextVersions.decoder,
                                       ontologyVersion: ActivityContextVersions.ontology,
                                       intervalVersion: ActivityClassVersions.interval,
                                       dataThrough: t + 1_800, observedSeconds: 1_800, intervalCount: 1, computedAt: t + 1_800),
            intervals: [ActivityContextIntervalRow(startTs: t, endTs: t + 1_800, activityClass: "sitting_desk",
                                                   confidence: 0.8, hrSamples: 1_800, hrMean: 67, hrMin: 60, hrMax: 80)])

        let executor = CoachToolExecutor(repo: repo, engine: AICoachEngine(repo: repo), api: CoachAPI.shared)
        let text = await executor.execute(name: "get_activity_context", arguments: #"{"hours": 2}"#)
        XCTAssertTrue(text.contains("• Sitting at a desk, 30 min"), text)
        XCTAssertTrue(text.contains("heart rate mean 67 bpm (range 60-80)"), text)

        let unknown = await executor.execute(name: "get_activity_context", arguments: #"{"activity": "dancing"}"#)
        XCTAssertTrue(unknown.hasPrefix("Unknown activity. Use one of: off_wrist|sleeping"), unknown)

        let none = await executor.execute(name: "get_activity_context", arguments: #"{"hours": 1, "activity": "running"}"#)
        XCTAssertTrue(none.contains("None of that time was classified as Running"), none)
    }
}
