import XCTest
@testable import StrandAnalytics

/// D4-08: the UniTS live prompt never falls back across measurement regimes silently.
final class UniTSPromptFallbackTests: XCTestCase {

    private func shown(_ series: LBSeries, _ center: Double, spread: Double = 3) -> LBEvaluation {
        var ev = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: series, carry: LBCarry())
        ev.showLong = true
        ev.usualTrustPctLong = 80
        ev.copyLong = LBCopySnapshot(center: center, spread: spread, centerDisplay: center,
                                     bandLoDisplay: center - 2 * spread, bandHiDisplay: center + 2 * spread,
                                     n: 20, coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        return ev
    }

    /// The continuous HR usual is a 24-h mean (sleep + effort minutes). With no awake-rest copy the
    /// instant-HR slot stays nil (population prior + cold-start sigma), never that 24-h mean.
    func testHrNeverFallsBackToTheContinuousMean() {
        let p = UniTSPrompt.from(evaluations: [shown(.continuousHR, 80)])
        XCTAssertNil(p.hr)
        XCTAssertNotEqual(p.hr ?? 0, 80)
        XCTAssertEqual(p.scaleHR, WatchdogConfig.hrScale, "no continuous-HR dispersion either")
        XCTAssertEqual(p.source, .population)
        // With the awake-rest copy shown, it is used.
        XCTAssertEqual(UniTSPrompt.from(evaluations: [shown(.continuousHR, 80), shown(.awakeRestHR, 62)]).hr ?? 0,
                       62, accuracy: 1e-9)
    }

    /// Daytime HRV with no awake-rest usual: an explicit, flagged, sleep-scaled fallback with widened sigma,
    /// never silently the sleep usual itself.
    func testDaytimeHrvWithoutAnAwakeUsualIsAnExplicitScaledFallback() {
        let p = UniTSPrompt.from(evaluations: [shown(.sleepHRVLn, 60)])
        XCTAssertEqual(p.hrv ?? 0, 60, accuracy: 1e-9, "the overnight usual is still carried as such")
        XCTAssertNil(p.hrvAwake)
        XCTAssertTrue(p.hrvAnchoredInSleep, "drives the widened HRV sigma")
        XCTAssertTrue(p.daytimeHRVFallbackUsed)
        let base = try! XCTUnwrap(p.daytimeHRV)
        XCTAssertNotEqual(base, 60, accuracy: 1)
        XCTAssertEqual(base, 60 * UniTSPrompt.awakeToSleepHRVRatio, accuracy: 1e-9)

        let awake = UniTSPrompt.from(evaluations: [shown(.sleepHRVLn, 60), shown(.awakeRestHRVLn, 42)])
        XCTAssertFalse(awake.daytimeHRVFallbackUsed)
        XCTAssertEqual(awake.daytimeHRV ?? 0, 42, accuracy: 1e-9)

        let none = UniTSPrompt.from(evaluations: [])
        XCTAssertNil(none.daytimeHRV)
        XCTAssertFalse(none.daytimeHRVFallbackUsed)
    }

    /// D4-08 review: the daytime fallback is AWAKE-only. A sleep-phase tick (a bound sleep interval open at now)
    /// with only a sleep-HRV copy compares against the sleep usual with the unscaled sleep MAD; the same window
    /// awake uses the flagged 0.65x centre. The Watchdog's expectation residual carries the phase.
    func testSleepPhaseUsesTheSleepUsualAndItsOwnMAD() throws {
        let p = UniTSPrompt.from(evaluations: [shown(.sleepHRVLn, 60, spread: 3)])
        // Unscaled sleep MAD: half-band (2 x 3) / k.
        let ev = shown(.sleepHRVLn, 60, spread: 3)
        XCTAssertEqual(p.scaleHRV, 6 / max(ev.kBandUsed, 1), accuracy: 1e-9)

        let now = 99_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 55, hrv: 60, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }

        XCTAssertFalse(UniTSRuntime.windowInSleep(win))
        XCTAssertEqual(p.phased(win).hrvCentre ?? 0, 60 * UniTSPrompt.awakeToSleepHRVRatio, accuracy: 1e-9)
        XCTAssertFalse(WatchdogExpectation.residual(window: win, evaluations: [ev], carryLastWorkoutEndUnix: 0).sleepPhase)

        win.bindActivityContext(lastWorkoutEndUnix: 0,
                                sleepIntervals: [WatchdogSleepInterval(startUnix: now - 3 * 3600, endUnix: now + 3600)])
        XCTAssertTrue(UniTSRuntime.windowInSleep(win))
        XCTAssertEqual(p.phased(win).hrvCentre ?? 0, 60, accuracy: 1e-9)
        XCTAssertTrue(WatchdogExpectation.residual(window: win, evaluations: [ev], carryLastWorkoutEndUnix: 0).sleepPhase)

        var sleepPrompt = p
        sleepPrompt.sleepPhase = true
        XCTAssertEqual(sleepPrompt.hrvCentre ?? 0, 60, accuracy: 1e-9)
        XCTAssertFalse(sleepPrompt.hrvCentreFallbackUsed)
        XCTAssertTrue(p.hrvCentreFallbackUsed)
    }
}
