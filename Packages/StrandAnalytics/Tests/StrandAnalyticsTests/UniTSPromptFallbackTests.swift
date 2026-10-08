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
        // The live HRV reconstruction seeds from the fallback, not from 60.
        let seeded = UniTSRuntime.reconstructHRV(observed: [nil, nil, nil], prompt: p, occupancy: [0, 0, 0])
        XCTAssertEqual(seeded.first??.rounded() ?? 0, base.rounded())

        let awake = UniTSPrompt.from(evaluations: [shown(.sleepHRVLn, 60), shown(.awakeRestHRVLn, 42)])
        XCTAssertFalse(awake.daytimeHRVFallbackUsed)
        XCTAssertEqual(awake.daytimeHRV ?? 0, 42, accuracy: 1e-9)

        let none = UniTSPrompt.from(evaluations: [])
        XCTAssertNil(none.daytimeHRV)
        XCTAssertFalse(none.daytimeHRVFallbackUsed)
    }

    /// D4-08 review: the daytime fallback is AWAKE-only. A sleep-phase tick (a bound sleep interval open at now)
    /// with only a sleep-HRV copy reconstructs at the sleep usual with the unscaled sleep MAD; the same window
    /// awake uses the flagged 0.65x centre. Before the fix the sleep tick also seeded at 0.65 x 60 = 39 ms and the
    /// prompt's MAD was narrowed by 0.65.
    func testSleepPhaseUsesTheSleepUsualAndItsOwnMAD() throws {
        let p = UniTSPrompt.from(evaluations: [shown(.sleepHRVLn, 60, spread: 3)])
        // Unscaled sleep MAD: half-band (2 x 3) / k.
        let ev = shown(.sleepHRVLn, 60, spread: 3)
        XCTAssertEqual(p.scaleHRV, 6 / max(ev.kBandUsed, 1), accuracy: 1e-9)

        let now = 99_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 55, hrv: 60, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }
        win.hrv = Array(repeating: nil, count: win.hrv.count)   // seed-only: no observed HRV to follow

        let awake = UniTSRuntime.physicsResidual(window: win, prompt: p, occupancy: Array(repeating: 0, count: win.seqLen))
        XCTAssertFalse(awake.sleepPhase)
        XCTAssertEqual(UniTSRuntime.resolvedBases(window: win, prompt: p)[2] ?? 0,
                       60 * UniTSPrompt.awakeToSleepHRVRatio, accuracy: 1e-9)
        XCTAssertEqual(awake.reconstructedHRV.compactMap { $0 }.last ?? 0,
                       60 * UniTSPrompt.awakeToSleepHRVRatio, accuracy: 1)

        win.bindActivityContext(lastWorkoutEndUnix: 0,
                                sleepIntervals: [WatchdogSleepInterval(startUnix: now - 3 * 3600, endUnix: now + 3600)])
        XCTAssertTrue(UniTSRuntime.windowInSleep(win))
        XCTAssertEqual(UniTSRuntime.resolvedBases(window: win, prompt: p)[2] ?? 0, 60, accuracy: 1e-9)
        let asleep = UniTSRuntime.physicsResidual(window: win, prompt: p, occupancy: Array(repeating: 0, count: win.seqLen))
        XCTAssertTrue(asleep.sleepPhase)
        XCTAssertEqual(asleep.reconstructedHRV.compactMap { $0 }.last ?? 0, 60, accuracy: 1)
        // The public entry point phases the same way (Core ML absent in tests -> physics prior).
        let viaReconstruct = try UniTSRuntime().reconstruct(win, prompt: p)
        XCTAssertTrue(viaReconstruct.sleepPhase)

        var sleepPrompt = p
        sleepPrompt.sleepPhase = true
        XCTAssertEqual(sleepPrompt.hrvCentre ?? 0, 60, accuracy: 1e-9)
        XCTAssertFalse(sleepPrompt.hrvCentreFallbackUsed)
        XCTAssertTrue(p.hrvCentreFallbackUsed)
    }
}
