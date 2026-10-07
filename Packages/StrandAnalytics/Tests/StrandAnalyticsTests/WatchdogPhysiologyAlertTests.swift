import XCTest
@testable import StrandAnalytics

final class WatchdogPhysiologyAlertTests: XCTestCase {
    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let all = [true, false, true, true, true, true]

    func testOneOrTwoVitalsDoNotPage() {
        let one = WatchdogPhysiologyAlert.marks(
            absR: [2.5, 0, 0, 0, 0, 0], mask: [true, false, false, false, false, false])
        let twoNote = WatchdogPhysiologyAlert.marks(
            absR: [1.1, 0, 1.2, 0, 0, 0], mask: [true, false, true, false, false, false])
        let twoActive = WatchdogPhysiologyAlert.marks(
            absR: [1.8, 0, 1.7, 0, 0, 0], mask: [true, false, true, false, false, false])
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: one, safety: false))
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: twoNote, safety: false))
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: twoActive, safety: false))
    }

    func testPersonalOffDoesNotPage() {
        let quiet = WatchdogPhysiologyAlert.marks(
            absR: [0.2, 0, 0.1, 0, 0, 0], mask: [true, false, true, false, false, false])
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: quiet, safety: false, personalOff: true))
    }

    func testThreeNoteWithoutTwoActiveDoesNotPage() {
        let mild = WatchdogPhysiologyAlert.marks(
            absR: [1.1, 0, 1.0, 1.05, 0, 0], mask: all)
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: mild, safety: false))
    }

    func testThreeVitalsWithTwoActivePages() {
        let extreme = WatchdogPhysiologyAlert.marks(
            absR: [1.8, 0, 1.7, 1.1, 0, 0], mask: all)
        XCTAssertTrue(WatchdogPhysiologyAlert.shouldAlert(marks: extreme, safety: false))
    }

    func testSafetyPagesEvenIfOnlyOneVital() {
        let one = WatchdogPhysiologyAlert.marks(
            absR: [0.4, 0, 0, 0, 0, 0], mask: [true, false, false, false, false, false])
        XCTAssertTrue(WatchdogPhysiologyAlert.shouldAlert(marks: one, safety: true))
    }

    func testQuietEvaluateDoesNotNotify() {
        let now = 88_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now)
        XCTAssertFalse(r.physiologyOff)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertEqual(r.severity, .withinLimits)
    }

    func testMildTwoChannelEvaluateDoesNotNotify() {
        let now = 88_110_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 72, hrv: 36, temp: 33.2, resp: 15, motion: 0)
        var carry = WatchdogCarry.empty
        carry.consecutiveMismatchTicks = 4
        let r = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed),
                                  prompt: prompt, nowUnix: now, previous: carry)
        XCTAssertFalse(r.physiologyOff)
        XCTAssertFalse(r.shouldNotify)
    }

    func testInjectSevereStillPagesOnce() {
        let now = 88_120_000
        let first = Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                      nowUnix: now, inject: .severe)
        XCTAssertTrue(first.physiologyOff || first.severity == .severe)
        XCTAssertTrue(first.shouldNotify)
        let second = Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                       nowUnix: now + 60, previous: first.carry, inject: .severe)
        XCTAssertFalse(second.shouldNotify)
    }
}
