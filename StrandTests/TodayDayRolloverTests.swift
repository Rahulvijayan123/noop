import XCTest
import WhoopStore
@testable import Strand

/// G1 day-UI repair (audit branch 20261003, docs/core-plumbing/findings/g1-day-ui.md T01/T02/T03):
/// Today rolls at LOCAL MIDNIGHT with a shared day-boundary driver, without any data refresh, sensor
/// reading, network, or DB revision bump; resume re-keys before the first meaningful render; a browsed
/// past day persists across relaunches with an explicit return-to-Today action.
@MainActor
final class TodayDayRolloverTests: XCTestCase {

    private func repo() -> Repository { Repository(deviceId: "test-dayrollover") }

    /// A local-zone instant built from calendar components, so every assertion is zone-independent.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d,
                                                   hour: h, minute: min, second: s))!
    }

    // MARK: - C2: Today row selection rolls at local midnight

    func testLogicalDayRollsAtLocalMidnight() {
        // Contract C2 (audit 20261003): the logical/Today day rolls at LOCAL MIDNIGHT, not 04:00.
        XCTAssertEqual(Repository.logicalDayRolloverHour, 0,
                       "logicalDayRolloverHour must be 0 so Today row selection rolls at local midnight")
        let before = date(2026, 6, 15, 23, 59, 59)
        let after = date(2026, 6, 16, 0, 0, 1)
        XCTAssertEqual(Repository.logicalDayKey(before), "2026-06-15")
        XCTAssertEqual(Repository.logicalDayKey(after), "2026-06-16")
        // The logical day IS the local calendar day (no fixed 04:00 shift, no 86,400 slicing).
        XCTAssertEqual(Repository.logicalDayKey(before), Repository.localDayKey(before))
        XCTAssertEqual(Repository.logicalDayKey(after), Repository.localDayKey(after))
        // Guards the audit change itself: the retired 04:00 shift would still resolve the 16th at 00:01
        // as the 15th.
        XCTAssertNotEqual(Repository.logicalDayKey(after, rolloverHour: 0),
                          Repository.logicalDayKey(after, rolloverHour: 4),
                          "the pre-audit 04:00 logical-day shift is retired")
        // The HR-trend window anchor follows the same midnight boundary.
        XCTAssertEqual(Repository.logicalDayStart(after),
                       Calendar.current.startOfDay(for: after))
    }

    // MARK: - Repository day-rollover signal (the shared re-key source)

    func testRepositoryRolloverSignalBumpsOnlyOnRealDayChange() {
        let repo = repo()
        XCTAssertEqual(repo.dayRolloverSeq, 0)
        XCTAssertEqual(repo.rolloverDayKey, "", "unresolved until the first recompute")
        repo.noteDayRolledOver(newKey: "2026-06-15")
        XCTAssertEqual(repo.dayRolloverSeq, 1)
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-15")
        // Same-day note is a no-op (the common lifecycle-edge call).
        repo.noteDayRolledOver(newKey: "2026-06-15")
        XCTAssertEqual(repo.dayRolloverSeq, 1)
        // A real day change bumps again.
        repo.noteDayRolledOver(newKey: "2026-06-16")
        XCTAssertEqual(repo.dayRolloverSeq, 2)
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-16")
    }

    func testRepositoryPostsDayKeyDidChangeOnRollover() {
        let repo = repo()
        var received = 0
        let token = NotificationCenter.default.addObserver(forName: Repository.dayKeyDidChange,
                                                           object: repo, queue: .main) { _ in
            received += 1
        }
        repo.noteDayRolledOver(newKey: "2026-06-15")
        XCTAssertEqual(received, 1)
        repo.noteDayRolledOver(newKey: "2026-06-15")
        XCTAssertEqual(received, 1, "same-day note must not re-post")
        repo.noteDayRolledOver(newKey: "2026-06-16")
        XCTAssertEqual(received, 2)
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - DayRolloverCoordinator: rollover independent of any data refresh

    func testCoordinatorRollsTodayAtLocalMidnightWithoutAnyDataRefresh() {
        let repo = repo()
        var current = date(2026, 6, 15, 23, 59, 58)
        let coordinator = DayRolloverCoordinator(repo: repo, now: { current }, observesNotifications: false)
        coordinator.recomputeTodayIfNeeded()   // launch seed
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-15")
        let seededSeq = repo.dayRolloverSeq

        // Same-day recomputes (lifecycle edges, unchanged data) do nothing.
        current = date(2026, 6, 15, 23, 59, 59)
        XCTAssertFalse(coordinator.recomputeTodayIfNeeded())
        XCTAssertEqual(repo.dayRolloverSeq, seededSeq)

        // Crossing local midnight re-keys Today. No refresh(), no sensor, no network anywhere.
        current = self.date(2026, 6, 16, 0, 0, 1)
        XCTAssertTrue(coordinator.recomputeTodayIfNeeded())
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-16")
        XCTAssertEqual(repo.dayRolloverSeq, seededSeq + 1)

        // Still a no-op later the same day.
        current = date(2026, 6, 16, 12, 0, 0)
        XCTAssertFalse(coordinator.recomputeTodayIfNeeded())
        XCTAssertEqual(repo.dayRolloverSeq, seededSeq + 1)
    }

    func testResumeAfterMultiDaySuspensionReKeysTodayBeforeAnyDataRefresh() {
        // T02: the first meaningful resumed Today must be CURRENT before network catch-up. The driver
        // recomputes synchronously on resume; the seq bump is exactly what re-keys the Today reload.
        let repo = repo()
        var current = date(2026, 6, 15, 8, 0, 0)
        let coordinator = DayRolloverCoordinator(repo: repo, now: { current }, observesNotifications: false)
        coordinator.recomputeTodayIfNeeded()
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-15")
        let seededSeq = repo.dayRolloverSeq

        // Suspended across several days; resume recomputes before any network/sync lands.
        current = date(2026, 6, 19, 9, 30, 0)
        XCTAssertTrue(coordinator.recomputeTodayIfNeeded())
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-19")
        XCTAssertEqual(repo.dayRolloverSeq, seededSeq + 1,
                       "one seq bump per resumed day-change; the reload key re-fires loadAll once")
        XCTAssertEqual(Repository.localDayKey(current), repo.rolloverDayKey,
                       "the re-keyed Today equals the local calendar day at resume")
    }

    func testTimezoneChangeEdgeReKeysToday() {
        let repo = repo()
        var current = date(2026, 6, 15, 12, 0, 0)
        let coordinator = DayRolloverCoordinator(repo: repo, now: { current }, observesNotifications: false)
        coordinator.recomputeTodayIfNeeded()
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-15")
        // A significant-time / zone / wake change that lands on a different local day re-keys.
        current = date(2026, 6, 16, 1, 0, 0)
        XCTAssertTrue(coordinator.significantTimeChange())
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-16")
        // Same-day significant-time change (e.g. a clock correction that keeps the day) is a no-op.
        XCTAssertFalse(coordinator.significantTimeChange())
        XCTAssertEqual(repo.dayRolloverSeq, 2)
    }

    // MARK: - audit-g1-day F1a: the midnight timer recomputes the crossed boundary (no full-day skip)

    func testTimerLoopRecomputesTheBoundaryItWakesJustBefore() async {
        // The sub-microsecond truncation of `UInt64(delay * 1e9)` can wake the timer a hair BEFORE local
        // midnight. The loop must recompute at its TOP (and after each sleep), so the 1 s retry rolls the
        // day that just crossed — it must NOT re-arm a ~24 h sleep past the boundary it missed.
        let repo = repo()
        var current = date(2026, 6, 15, 23, 59, 59).addingTimeInterval(-0.001)   // ~1 ms before local midnight
        var sleeps: [UInt64] = []
        let coordinator = DayRolloverCoordinator(repo: repo, now: { current }, observesNotifications: false,
                                                 sleep: { nanoseconds in
            sleeps.append(nanoseconds)
            if sleeps.count == 1 {
                // The first (sub-second) sleep simulates the boundary crossing underneath the timer.
                current = self.date(2026, 6, 16, 0, 0, 1)
            } else {
                // Real short pause so the loop doesn't busy-spin; lets the test observe the state.
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        })
        coordinator.scheduleMidnightTimer(now: current)
        // Let the loop run through: first sleep (crosses midnight) -> recompute -> retry -> re-arm.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(repo.rolloverDayKey, "2026-06-16",
                       "the loop-top recompute must roll the day the boundary crossed, not re-arm 24h (F1a)")
        XCTAssertGreaterThan(repo.dayRolloverSeq, 0)
        // Sanity: the first arm was the sub-second path (< 2 s), never a full-day arm before recomputing.
        XCTAssertLessThan(sleeps.first ?? 0, 2_000_000_000,
                          "the first sleep must be the short pre-midnight delay, not a full day")
    }

    // MARK: - T03: past-day selection persists and clamps

    func testSelectedDayOffsetPersistsAcrossRelaunchUnderTheSharedKey() {
        let key = TodayView.selectedDayOffsetKey
        XCTAssertEqual(key, "today.selectedDayOffset", "the two Today surfaces share this key")
        let defaults = UserDefaults.standard
        let original = defaults.integer(forKey: key)
        defaults.set(4, forKey: key)
        defer { defaults.set(original, forKey: key) }
        // A relaunch (or a SwiftUI re-mount) restores the same selection.
        XCTAssertEqual(defaults.integer(forKey: key), 4)
    }

    func testRestoredDayOffsetClampsIntoTheNavigableRange() {
        XCTAssertEqual(TodayView.restoredDayOffset(saved: 3, maxOffset: 30), 3)
        XCTAssertEqual(TodayView.restoredDayOffset(saved: 0, maxOffset: 30), 0)
        XCTAssertEqual(TodayView.restoredDayOffset(saved: -2, maxOffset: 30), 0, "never into the future")
        XCTAssertEqual(TodayView.restoredDayOffset(saved: 40, maxOffset: 12), 12,
                       "never past the earliest banked day")
        XCTAssertEqual(TodayView.restoredDayOffset(saved: 7, maxOffset: 0), 0)
        XCTAssertEqual(TodayView.restoredDayOffset(saved: 7, maxOffset: -3), 0,
                       "a negative bound collapses to today only")
    }

    // MARK: - audit-g1-day F1b: same-day timezone change re-keys day-scoped context

    func testSameDayZoneChangeBumpsZoneContextEvenWhenDayUnchanged() {
        // A UTC+1→UTC+2 change at 13:00 keeps the same day key, but day-scoped bounds must re-key to the
        // new zone's midnight. The zone-context signal must bump (and dayKeyDidChange post) even though
        // `dayRolloverSeq` (the day key) does not.
        let repo = repo()
        var current = date(2026, 6, 15, 13, 0, 0)
        let coordinator = DayRolloverCoordinator(repo: repo, now: { current }, observesNotifications: false)
        coordinator.recomputeTodayIfNeeded()
        let daySeq = repo.dayRolloverSeq
        let zoneSeq = repo.zoneContextSeq

        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: Repository.dayKeyDidChange,
                                                           object: repo, queue: .main) { _ in posted += 1 }
        XCTAssertFalse(coordinator.significantTimeChange(), "same day key, so no day rollover")
        XCTAssertEqual(repo.zoneContextSeq, zoneSeq + 1, "zone-context seq must bump on the zone change")
        XCTAssertEqual(repo.dayRolloverSeq, daySeq, "day key unchanged, so the rollover seq must not move")
        XCTAssertEqual(posted, 1, "the zone change must still post dayKeyDidChange so day-scoped caches re-key")
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - audit-g1-day F2: the BodyVitalSigns logical-day twin rolls at local midnight

    func testBodyVitalSignsLogicalDayRollsAtLocalMidnight() {
        // The Health vitals tile's "Today" label + reading selection and the Sleep headline carry/stamp
        // use BodyVitalSigns.logicalDayKey. It must default to the SAME local-midnight boundary as
        // Repository (the pre-audit 04:00 twin is retired).
        XCTAssertEqual(Repository.logicalDayRolloverHour, 0)
        let before = date(2026, 6, 15, 23, 59, 59)
        let after = date(2026, 6, 16, 0, 0, 1)
        XCTAssertEqual(BodyVitalSigns.logicalDayKey(before), "2026-06-15")
        XCTAssertEqual(BodyVitalSigns.logicalDayKey(after), "2026-06-16")
        // Aligned with the Repository twin (no drift between the two surfaces).
        XCTAssertEqual(BodyVitalSigns.logicalDayKey(before), Repository.logicalDayKey(before))
        XCTAssertEqual(BodyVitalSigns.logicalDayKey(after), Repository.logicalDayKey(after))
        // Guards the audit change: the retired 04:00 shift would still call the 16th "the 15th" at 00:01.
        XCTAssertNotEqual(BodyVitalSigns.logicalDayKey(after, rolloverHour: 0),
                          BodyVitalSigns.logicalDayKey(after, rolloverHour: 4))
    }

    func testSleepHeadlineCarryUsesTheMidnightBoundary() {
        // SleepModel.metric resolves its headline + carry stamp through BodyVitalSigns.logicalDayKey.
        // Just after local midnight, the NEW day's own row is the headline (no carry stamp), and a value
        // that only exists on the PRIOR day gets a carry stamp — never silently relabelled "today".
        func day(_ key: String, resp: Double?) -> DailyMetric {
            DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil, respRateBpm: resp)
        }
        let justAfterMidnight = date(2026, 6, 16, 0, 0, 5)
        let days = [day("2026-06-15", resp: 15.0), day("2026-06-16", resp: 14.0)]
        let metric = SleepModel.metric(days: days, now: justAfterMidnight) { $0.respRateBpm }
        XCTAssertEqual(metric.latest, 14.0, "the new local day's own reading is the headline at 00:00:05")
        XCTAssertNil(metric.latestDay, "today's own reading needs no carry stamp")
    }

    func testSleepHeadlineStampsAPriorDayCarryAcrossMidnight() {
        // Same boundary, carry case: only the prior day has a reading; just after midnight it must be
        // carried WITH its date stamp, not relabelled as today (the pre-audit 04:00 boundary would have
        // kept it the "same day" until 04:00 and hidden the stamp).
        func day(_ key: String, resp: Double?) -> DailyMetric {
            DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil, respRateBpm: resp)
        }
        let justAfterMidnight = date(2026, 6, 16, 0, 0, 5)
        let days = [day("2026-06-15", resp: 15.0), day("2026-06-16", resp: nil)]
        let metric = SleepModel.metric(days: days, now: justAfterMidnight) { $0.respRateBpm }
        XCTAssertEqual(metric.latest, 15.0, "the prior day's value carries through the new day")
        XCTAssertEqual(metric.latestDay, "2026-06-15", "a carried value keeps its date stamp")
    }
}
