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
}
