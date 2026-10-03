import XCTest
@testable import Strand

/// "Low refresh" (Settings → Power saving sub-option) moves the BASE periodic-offload cadence from 15 min
/// to 60 min. The invariant that matters is COMPOSITION: every other lever stretches FROM that base with
/// `max`, so no lever can ever hand back a faster cadence than the user asked for, and a lever that would
/// have stretched a 15-min base is a no-op once the base is already longer.
///
/// Cadence only, by design: low refresh deliberately does NOT touch the keep-alive (that tick re-arms the
/// WHOOP 4 realtime burst each cycle and evaluates the 120 s stall fuse) and does NOT release continuous
/// HRV capture (that is the separate "Pause HRV capture" lever / #927's overnight window). Those are the
/// two places a quieter radio would cost real data rather than merely delaying it.
//
// BLEManager is @MainActor, so its static helpers are main-actor-isolated; the test methods must run on
// the main actor to call them (matches Whoop5BatteryBackfillThrottleTests etc.). Class-level @MainActor
// covers all.
@MainActor
final class LowRefreshCadenceTests: XCTestCase {

    func testBaseIsFifteenMinutesWhenOff() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: false), BLEManager.backfillIntervalSeconds)
        XCTAssertEqual(BLEManager.backfillIntervalSeconds, 900)
    }

    func testBaseIsHourlyWhenOn() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: true), BLEManager.lowRefreshBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.lowRefreshBackfillIntervalSeconds, 3600)
    }

    /// The low-battery lever (45 min) is SHORTER than low refresh (60 min): composed with `max` it must
    /// leave the hourly cadence alone rather than speeding it back up.
    func testLowBatteryLeverNeverShortensLowRefresh() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: true)
        let composed = BLEManager.offloadInterval(
            baseSeconds: base,
            lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
            batteryPct: 10, charging: false, thresholdPct: 20)   // lever fully engaged
        XCTAssertEqual(composed, BLEManager.lowRefreshBackfillIntervalSeconds)
    }

    /// Without low refresh the same engaged lever still stretches 15 → 45 min, i.e. this change is inert
    /// for everyone who does not turn it on.
    func testDefaultBehaviourIsUnchangedWhenOff() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: false)
        XCTAssertEqual(
            BLEManager.offloadInterval(baseSeconds: base,
                                       lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                                       batteryPct: 10, charging: false, thresholdPct: 20),
            BLEManager.lowBatteryBackfillIntervalSeconds)
        // …and an idle/charged strap keeps the plain 15-min cadence.
        XCTAssertEqual(
            BLEManager.offloadInterval(baseSeconds: base,
                                       lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                                       batteryPct: 90, charging: false, thresholdPct: 20),
            BLEManager.backfillIntervalSeconds)
    }

    /// The 5/MG empty-history stretch (45 min) composes the same way: it may quieten a 15-min base, but
    /// must not pull an already-hourly cadence back down.
    func testWhoop5EmptyHistoryStretchNeverShortensLowRefresh() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: true)
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: base,
                lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                historyEmpty: true),
            BLEManager.lowRefreshBackfillIntervalSeconds)
    }

    // MARK: - Fresh data (minute cadence)

    func testFreshSyncMakesTheBaseOneMinute() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: false, freshSync: true),
                       BLEManager.freshBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.freshBackfillIntervalSeconds, 60)
    }

    /// The user's hourly cadence is the more deliberate request, so it wins over the minute cadence.
    func testLowRefreshOutranksFreshSync() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: true, freshSync: true),
                       BLEManager.lowRefreshBackfillIntervalSeconds)
    }

    /// Every power lever composes with `max`, so a low strap battery still pushes the minute cadence out
    /// to 45 min, and a charged strap keeps the minute.
    func testPowerLeversStillStretchTheFreshCadence() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: false, freshSync: true)
        let low = max(base, BLEManager.lowBatteryBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.offloadInterval(baseSeconds: base, lowSeconds: low,
                                                  batteryPct: 10, charging: false, thresholdPct: 20),
                       BLEManager.lowBatteryBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.offloadInterval(baseSeconds: base, lowSeconds: low,
                                                  batteryPct: 90, charging: false, thresholdPct: 20),
                       BLEManager.freshBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.whoop5EmptyHistoryBackfillInterval(baseSeconds: base, lowSeconds: low,
                                                                     historyEmpty: true),
                       BLEManager.lowBatteryBackfillIntervalSeconds)
    }

    /// Only the minute timer lowers the periodic floor; the 15-min, hourly and stretched cadences keep 15 min.
    func testOnlyTheMinuteCadenceLowersThePeriodicFloor() {
        XCTAssertEqual(BLEManager.periodicBackfillFloor(forInterval: BLEManager.freshBackfillIntervalSeconds),
                       BackfillPolicy.freshPeriodicFloorSeconds)
        for seconds in [BLEManager.backfillIntervalSeconds, BLEManager.lowBatteryBackfillIntervalSeconds,
                        BLEManager.lowRefreshBackfillIntervalSeconds] {
            XCTAssertEqual(BLEManager.periodicBackfillFloor(forInterval: seconds),
                           BackfillPolicy.periodicFloorSeconds)
        }
    }

    func testPeriodicTickRunsAtTheFreshFloorAndNotBefore() {
        let floor = BackfillPolicy.freshPeriodicFloorSeconds
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000 + floor, lastBackfillAt: 1_000,
                                               periodicFloor: floor))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000 + floor - 1, lastBackfillAt: 1_000,
                                                periodicFloor: floor))
        // Unchanged default: a 60 s old sync still blocks a plain 15-min periodic tick.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_060, lastBackfillAt: 1_000))
    }

    /// An off-wrist or caught-up strap that banks nothing must not be polled every minute: the empty-streak
    /// backoff stretches the minute floor exactly as it stretches the 15-min one.
    func testEmptyStreakStillBacksOffTheFreshFloor() {
        let floor = BackfillPolicy.freshPeriodicFloorSeconds
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000 + floor * 2 - 1, lastBackfillAt: 1_000,
                                                emptyStreak: BackfillPolicy.emptyBackoffThreshold,
                                                periodicFloor: floor))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000 + floor * 2, lastBackfillAt: 1_000,
                                               emptyStreak: BackfillPolicy.emptyBackoffThreshold,
                                               periodicFloor: floor))
    }
}
