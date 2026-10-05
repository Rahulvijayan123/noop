import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HRVWindowTests: XCTestCase {
    private let t0 = 1_760_000_000

    /// Beats at a constant interval, timestamped beat-accurately (`ts` advances by `ms`/1000 each beat,
    /// matching the convention `ActivityContextIntervalTests.rsa` uses) so the trust gates pass.
    private func beats(constantMs: Double, from: Int, seconds: Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        let end = Double(from + seconds)
        while t < end {
            out.append(RRInterval(ts: Int(t), rrMs: Int(constantMs)))
            t += constantMs / 1000.0
        }
        return out
    }

    /// A slow linear drift: tiny successive differences (low RMSSD) but a wide overall range (high SDNN),
    /// proving the two are computed independently rather than one derived from the other.
    private func drifting(from: Int, beatCount: Int, startMs: Double = 700, stepMs: Double = 2) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        for k in 0..<beatCount {
            let rr = startMs + stepMs * Double(k)
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr)))
            t += rr / 1000.0
        }
        return out
    }

    private func interval(_ s: Int, _ e: Int, _ c: ActivityClass) -> ActivityContextInterval {
        ActivityContextInterval(start: s, end: e, activityClass: c, confidence: 0.9)
    }

    // MARK: Canonical windowing

    func testCanonicalWindowingTilesTheSpanAndDropsATrailingPartial() {
        let rr = beats(constantMs: 800, from: t0, seconds: 720) // 12 minutes of data
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 720, rr: rr)
        XCTAssertEqual(windows.count, 2, "two full 5-min windows; the trailing 120 s is not a canonical window")
        XCTAssertEqual(windows.map(\.start), [t0, t0 + 300])
        XCTAssertEqual(windows.map(\.end), [t0 + 300, t0 + 600])
        XCTAssertTrue(windows.allSatisfy { $0.durationSeconds == 300 })
    }

    func testNoRRDataMeansNoWindowEmitted() {
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: [])
        XCTAssertTrue(windows.isEmpty, "never invent an observation where there is no R-R data")
    }

    func testThreeKindsHaveDistinctCanonicalDurations() {
        XCTAssertEqual(HRVWindowKind.canonical5m.durationSeconds, 300)
        XCTAssertEqual(HRVWindowKind.secondary2m.durationSeconds, 120)
        XCTAssertEqual(HRVWindowKind.exploratory1m.durationSeconds, 60)
    }

    // MARK: RMSSD / SDNN independence

    func testRmssdAndSdnnAreComputedIndependently() throws {
        let rr = drifting(from: t0, beatCount: 150)
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr)
        let w = try XCTUnwrap(windows.first)
        let rmssd = try XCTUnwrap(w.rmssd)
        let sdnn = try XCTUnwrap(w.sdnn)
        XCTAssertLessThan(rmssd, 10, "tiny constant successive differences")
        XCTAssertGreaterThan(sdnn, 50, "a wide linear drift spreads the whole-window SD, unlike RMSSD")
        XCTAssertGreaterThan(sdnn, rmssd * 5, "SDNN must not be a scaled copy of RMSSD")
    }

    func testMeanAndMedianNNAreReportedBesideRmssdAndSdnn() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertEqual(try XCTUnwrap(w.meanNN), 800, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(w.medianNN), 800, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(w.rmssd), 0, accuracy: 1e-6, "no variation at all between constant beats")
    }

    // MARK: Never a cross-window difference

    func testNoDifferenceIsEverFormedAcrossAWindowBoundary() throws {
        // Each window is internally dead flat (rmssd 0), but the LAST beat of window 1 and the FIRST beat
        // of window 2 are set to a huge, deliberately mismatched pair. If a diff were ever taken across
        // the window boundary, both windows' rmssd would spike; because each window is sliced and cleaned
        // from ITS OWN beats only, neither does.
        var rr = beats(constantMs: 800, from: t0, seconds: 300)
        rr[rr.count - 1] = RRInterval(ts: rr[rr.count - 1].ts, rrMs: 1_400)
        var rr2 = beats(constantMs: 800, from: t0 + 300, seconds: 300)
        rr2[0] = RRInterval(ts: rr2[0].ts, rrMs: 300)
        let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 600, rr: rr + rr2)
        XCTAssertEqual(windows.count, 2)
        for w in windows {
            XCTAssertLessThan(try XCTUnwrap(w.rmssd), 50,
                              "a cross-window splice would read in the hundreds of ms; neither window saw one")
        }
    }

    // MARK: Motion

    func testMotionRmsPrefersImuWindowsOverGravityFallback() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let imu = [ImuWindowFeatures(startTs: t0, endTs: t0 + 300, accelRmsG: 0.05, gyroRmsDps: 3, jerkRms: 0,
                                     cadenceHz: nil, cadenceStrength: 0)]
        let gravity = (0..<300).map { GravitySample(ts: t0 + $0, x: 0, y: 0, z: 1, dynAccel: 0.5) }
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      imuWindows: imu, gravity: gravity).first)
        XCTAssertEqual(try XCTUnwrap(w.motionRmsG), 0.05, accuracy: 1e-9, "IMU window features take priority")
        XCTAssertEqual(try XCTUnwrap(w.gyroRmsDps), 3, accuracy: 1e-9)
    }

    func testMotionRmsFallsBackToGravityDynAccelWhenNoImuWindowOverlaps() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let gravity = (0..<300).map { GravitySample(ts: t0 + $0, x: 0, y: 0, z: 1, dynAccel: 0.02) }
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      gravity: gravity).first)
        XCTAssertEqual(try XCTUnwrap(w.motionRmsG), 0.02, accuracy: 1e-9)
        XCTAssertNil(w.gyroRmsDps, "no 1 Hz gyro stream to fall back to")
    }

    func testMotionIsNilNotZeroWithoutAnyMotionStream() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertNil(w.motionRmsG, "absence of a motion reading is not evidence of stillness")
        XCTAssertNil(w.gyroRmsDps)
    }

    // MARK: Activity-context join and lookback (metadata, not a gate)

    func testActivityContextIsTheCoverageWeightedDominantClassAndItsShare() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let lookup = ActivityContextLookup(intervals: [
            interval(t0, t0 + 200, .sitting), interval(t0 + 200, t0 + 300, .walking),
        ])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: lookup).first)
        XCTAssertEqual(w.activityContext, .sitting)
        XCTAssertEqual(try XCTUnwrap(w.activityConfidence), 200.0 / 300.0, accuracy: 1e-9)
    }

    func testSecondsSinceLocomotionAndExerciseLookBackThroughTheActivityLookup() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let lookup = ActivityContextLookup(intervals: [
            interval(t0 - 500, t0 - 50, .walking),
            interval(t0 - 1_000, t0 - 800, .vigorousActivity),
        ])
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                      activity: lookup).first)
        // Measured from the window's own right edge (t0 + 300), matching `ActivityHistorySummary`'s
        // "as of now" convention.
        XCTAssertEqual(w.secondsSinceLocomotion, (t0 + 300) - (t0 - 50))
        XCTAssertEqual(w.secondsSinceExercise, (t0 + 300) - (t0 - 800))
    }

    func testNoActivityLookupLeavesContextFieldsNilRatherThanGuessing() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertNil(w.activityContext)
        XCTAssertNil(w.activityConfidence)
        XCTAssertNil(w.secondsSinceLocomotion)
        XCTAssertNil(w.secondsSinceExercise)
    }

    // MARK: Transition / recovery / steady-state

    func testPhaseAndEligibilityThroughATransitionsWake() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 10_000)
        let transitionTs = t0 + 500
        let events = [ActivityTransitionEvent(kind: .standToSitLike, probability: 0.9, ts: transitionTs)]

        func window(startOffset: Int) throws -> HRVWindow {
            let start = t0 + startOffset
            return try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: start, dayEnd: start + 300,
                                                        rr: rr, transitionEvents: events).first)
        }

        // Window ending 10 s after the transition: deep inside the transition guard.
        let justAfter = try window(startOffset: 500 + 10 - 300)
        XCTAssertEqual(justAfter.phase, .transition)
        XCTAssertFalse(justAfter.eligibleForBaseline)

        // Window ending 60 s after: past the 30 s transition guard, inside the 120 s recovery guard.
        let recovering = try window(startOffset: 500 + 60 - 300)
        XCTAssertEqual(recovering.phase, .recovery)
        XCTAssertFalse(recovering.eligibleForBaseline, "recovery is real physiology, but not a baseline observation")

        // Window ending 200 s after: past both guards.
        let steady = try window(startOffset: 500 + 200 - 300)
        XCTAssertEqual(steady.phase, .steadyState)
        XCTAssertTrue(steady.eligibleForBaseline)
    }

    func testNoKnownTransitionReadsAsSteadyStateNotExcluded() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr).first)
        XCTAssertNil(w.secondsSinceTransition)
        XCTAssertEqual(w.phase, .steadyState, "absence of a transition event is not evidence one just happened")
        XCTAssertTrue(w.eligibleForBaseline)
    }

    // MARK: Eligibility is motion/quality-gated, not semantic-class-gated

    private func baseEligibleWindow(activityContext: ActivityClass? = .sitting, motionRmsG: Double? = 0.01,
                                    gyroRmsDps: Double? = nil, artifactFraction: Double? = 0.05,
                                    phase: ActivityPhysiologyPhase = .steadyState, rmssd: Double? = 30,
                                    trustworthy: Bool = true) -> HRVWindow {
        HRVWindow(kind: .canonical5m, start: t0, end: t0 + 300, rmssd: rmssd, sdnn: 40, meanNN: 800,
                 medianNN: 800, rrDiffSqSumMs2: 1_000, rrDiffCount: 100, nnM2: 2_000, validRRCount: 300,
                 artifactFraction: artifactFraction,
                 signalQuality: HRVSignalQuality(coverageVerdict: .plausible, beatAccurateFraction: 0.99,
                                                 trustworthy: trustworthy),
                 motionRmsG: motionRmsG, gyroRmsDps: gyroRmsDps, activityContext: activityContext,
                 activityConfidence: 0.9, secondsSinceTransition: 300, secondsSinceLocomotion: nil,
                 secondsSinceExercise: nil, phase: phase, eligibleForBaseline: false)
    }

    func testEligibilityPassesOnCleanSteadyStateMotion() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow()))
    }

    func testEligibilityDoesNotCareWhichNonOffWristClassIsAttached() {
        // The whole point of the item-D fix: a `walking` or `lightActivity` LABEL does not by itself
        // decide trust. A clean, steady, low-motion window reads eligible under either label.
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .walking)))
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .lightActivity)))
    }

    func testEligibilityFailsOffWristRegardlessOfEverythingElse() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(activityContext: .offWrist)))
    }

    func testEligibilityFailsWithoutRmssd() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(rmssd: nil)))
    }

    func testEligibilityFailsWhenNotSteadyState() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(phase: .transition)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(phase: .recovery)))
    }

    func testEligibilityFailsOnHighMotionOrGyroEvenUnderAStillLabel() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(activityContext: .sitting, motionRmsG: 0.5)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(activityContext: .sitting, gyroRmsDps: 50)))
    }

    func testEligibilityIsNotPenalizedByAbsentMotionReadings() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(motionRmsG: nil, gyroRmsDps: nil)))
    }

    func testEligibilityFailsOnHighArtifactFractionOrUntrustworthySignal() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(artifactFraction: 0.9)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(trustworthy: false)))
    }
}
