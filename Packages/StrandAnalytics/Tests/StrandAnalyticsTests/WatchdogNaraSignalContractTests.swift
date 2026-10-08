import XCTest
@testable import StrandAnalytics

/// The Nara tick can add a sleep interval or drop wrist IMU before `evaluate`.
/// Those inputs use doors the engines already had. They do not move Off or a Layer 1 center.
final class WatchdogNaraSignalContractTests: XCTestCase {
    func testSleepIntervalDoesNotMoveOffOnAQuietWindow() throws {
        let now = 97_400_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        let plain = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        let covered = Watchdog.evaluate(
            window: .success(win), prompt: UniTSPrompt(), nowUnix: now,
            sleepSessionOpen: true,
            sleepIntervals: [WatchdogSleepInterval(startUnix: now - 600, endUnix: now + 60)])
        let beside = Watchdog.evaluate(
            window: .success(win), prompt: UniTSPrompt(), nowUnix: now,
            sleepIntervals: [WatchdogSleepInterval(startUnix: now + 3_600, endUnix: now + 7_200)])
        XCTAssertEqual(plain.severity, covered.severity)
        XCTAssertEqual(plain.shouldNotify, covered.shouldNotify)
        XCTAssertEqual(plain.liveOff, covered.liveOff)
        XCTAssertFalse(plain.liveOff)
        XCTAssertEqual(plain.severity, beside.severity)
        XCTAssertEqual(plain.shouldNotify, beside.shouldNotify)
        XCTAssertEqual(plain.carry.presentMinutes(channel: 0), beside.carry.presentMinutes(channel: 0))
    }

    func testSleepIntervalStillBlocksAwakeRestAndLeavesTheLongCopyUntouched() {
        let now = 97_500_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityFeatures = (0..<30).map { _ in
            var row = Array(repeating: 0.0, count: 20)
            row[19] = 1
            return row
        }
        var tape = LBDayTape(day: "2026-10-01")
        _ = tape.ingest(window: win, nowUnix: now)
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertGreaterThan(tape.allHR.n, 0)
        let asleep = LongitudinalBaseline.evaluate(
            asOf: "2026-10-01", series: .sleepRHR, observations: [])
        let awake = LongitudinalBaseline.evaluate(
            asOf: "2026-10-01", series: .awakeRestHR, observations: [])
        XCTAssertNil(asleep.center7Raw)
        XCTAssertNil(awake.center7Raw)
        XCTAssertEqual(asleep.nLong, 0)
        XCTAssertEqual(awake.nLong, 0)
    }

    func testEmptyImuWindowDoesNotNotify() {
        let now = 97_600_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.imu = []
        let result = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertFalse(result.shouldNotify)
        XCTAssertFalse(result.liveOff)
    }

    /// Walking minutes never feed the resting-HR stream; still minutes do.
    func testWalkingLeavesRHREmptyAndStillFillsIt() throws {
        let now = 97_700_000
        let stillFeed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        let walkFeed = Watchdog.syntheticFeed(now: now, hr: 110, hrv: 20, temp: 33.2, resp: 18,
                                              motion: 0.70, stepsPerMin: 100)
        guard case .success(let still) = WatchdogWindowBuilder.build(stillFeed),
              case .success(let walk) = WatchdogWindowBuilder.build(walkFeed) else {
            return XCTFail("window")
        }
        XCTAssertTrue(walk.rhr.allSatisfy { $0 == nil })
        XCTAssertFalse(still.rhr.compactMap { $0 }.isEmpty)
    }

    /// Heart rate with no motion sample is not a resting minute.
    func testMissingMotionDoesNotEnterRestingHR() {
        let now = 97_800_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 108, hrv: 20, temp: 33.0, resp: 16, motion: 0)
        feed.motion = []
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        XCTAssertTrue(win.rhr.allSatisfy { $0 == nil })
    }


}
