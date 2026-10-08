import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// With dense gravity, detection calls a sample still only when orientation sits on a plateau across
/// `stillPlateauSpanS`. At 1 Hz a per-sample 0.01 g test passed slow awake movement as still. Kotlin
/// twin: `SleepStagerStillPlateauTest`.
final class SleepStagerStillPlateauTests: XCTestCase {

    private var refMidnight: Int { 1_749_513_600 }
    private func at(_ hour: Int, _ minute: Int = 0) -> Int { refMidnight + hour * 3_600 + minute * 60 }

    private func still(_ from: Int, _ toExclusive: Int, x: Double = 0, z: Double = 1.0) -> [GravitySample] {
        (from ..< toExclusive).map { GravitySample(ts: $0, x: x, y: 0, z: z) }
    }
    private func moving(_ from: Int, _ toExclusive: Int) -> [GravitySample] {
        (from ..< toExclusive).map { t in
            t % 2 == 0 ? GravitySample(ts: t, x: 1.0, y: 0, z: 0) : GravitySample(ts: t, x: 0, y: 1.0, z: 0)
        }
    }
    /// Slow rotation: 0.004 g per second (still to a per-sample test), ~0.24 g per minute.
    private func drifting(_ from: Int, _ toExclusive: Int) -> [GravitySample] {
        (from ..< toExclusive).map { t in
            let a = 0.004 * Double(t - from)
            return GravitySample(ts: t, x: sin(a), y: 0, z: cos(a))
        }
    }
    private func hr(_ from: Int, _ toExclusive: Int, _ bpm: Int) -> [HRSample] {
        (from ..< toExclusive).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testSlowDriftIsStillPerSampleButNotOnAPlateau() {
        let g = drifting(0, 300)
        let deltas = SleepStager.gravityDeltas(g)
        XCTAssertTrue(deltas.allSatisfy { $0 < SleepStager.gravityStillThresholdG })
        XCTAssertTrue(SleepStager.plateauStill(g, deltas)[20 ..< 280].allSatisfy { !$0 })
    }

    func testASingleRollCostsOnlyItsOwnSecondsAndTheSpanEitherSide() {
        let g = still(0, 600) + still(600, 1200, x: 0.6, z: 0.8)
        let moving = SleepStager.plateauStill(g, SleepStager.gravityDeltas(g)).filter { !$0 }.count
        XCTAssertLessThanOrEqual(moving, 2 * SleepStager.stillPlateauSpanS + 1)
    }

    func testAtMinuteCadenceTheOriginalPerSampleTestApplies() {
        let g = stride(from: 0, to: 3600, by: 60).enumerated().map { i, t in
            GravitySample(ts: t, x: Double(i % 3) * 0.004, y: 0, z: 1.0)
        }
        let deltas = SleepStager.gravityDeltas(g)
        XCTAssertEqual(SleepStager.plateauStill(g, deltas), deltas.map { $0 < SleepStager.gravityStillThresholdG })
    }

    /// Field shape (2026-10-07): dense 1 Hz night, alarm, up, strap off ~25 min for a shower, back on,
    /// then ~25 min of slow movement getting ready. The per-sample test called that stretch sleep and
    /// the sparse bridge (switched on by the shower hole) glued it onto the night — wake reported at
    /// 11:13 for a 10:00 get-up.
    func testGettingReadyAfterAShowerDoesNotExtendTheNight() {
        let wake = at(6), off = at(6, 10), on = at(6, 35), settle = at(6, 48), up = at(7, 12)
        let grav = still(at(0), wake) + moving(wake, off)
            + moving(on, settle) + drifting(settle, up) + moving(up, at(16))
        let hrs = hr(at(0), wake, 50) + hr(wake, off, 62)
            + hr(on, settle, 62) + hr(settle, up, 58) + hr(up, at(16), 75)
        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hrs), "the shower hole alone must read as sparse")
        let sessions = SleepStager.detectSleep(hr: hrs, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertLessThanOrEqual(sessions[0].end, off,
                                 "night ran to \((sessions[0].end - refMidnight) / 60) min past midnight")
    }

    /// The plateau test must not fragment real sleep: a night with a roll every 20 minutes is one night.
    func testPostureChangesDuringSleepDoNotSplitTheNight() {
        var grav: [GravitySample] = []
        for (k, t) in stride(from: at(0), to: at(7), by: 1_200).enumerated() {
            grav += k % 2 == 0 ? still(t, t + 1_200) : still(t, t + 1_200, x: 0.6, z: 0.8)
        }
        grav += moving(at(7), at(16))
        let hrs = hr(at(0), at(7), 50) + hr(at(7), at(16), 75)
        let sessions = SleepStager.detectSleep(hr: hrs, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertGreaterThan(sessions[0].end - sessions[0].start, 6 * 3_600 + 30 * 60)
    }

    // MARK: - Strap-off gaps are not dropouts

    func testAStrapOffGapDoesNotMakeDenseGravitySparse() {
        let grav = still(at(0), at(3)) + still(at(3, 30), at(6))
        let hrs = hr(at(0), at(6), 50)
        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hrs))
        XCTAssertFalse(SleepStager.isGravitySparse(grav, hr: hrs, wristOff: [(start: at(3), end: at(3, 30))]))
        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hrs, wristOff: [(start: at(3), end: at(3, 5))]),
                      "only the worn part of a gap counts")
    }

    /// Field shape (2026-10-05): a shower the previous morning was the window's only long gap, so the
    /// sparse bridge joined a still stretch before bed onto the night across 35 minutes of recorded
    /// movement. Bed was at ~02:57.
    func testAPreBedStillStretchIsNotBridgedOntoTheNightAcrossRecordedMovement() {
        let off = at(-14), on = at(-14, 25)
        let grav = moving(at(-16), off) + moving(on, at(1, 55)) + still(at(1, 55), at(2, 17))
            + moving(at(2, 17), at(2, 52)) + still(at(2, 52), at(9)) + moving(at(9), at(14))
        let hrs = hr(at(-16), off, 75) + hr(on, at(1, 55), 75) + hr(at(1, 55), at(2, 17), 66)
            + hr(at(2, 17), at(2, 52), 70) + hr(at(2, 52), at(9), 52) + hr(at(9), at(14), 75)
        let wristOff = [(start: off, end: on)]
        XCTAssertFalse(SleepStager.isGravitySparse(grav, hr: hrs, wristOff: wristOff))
        let sessions = SleepStager.detectSleep(hr: hrs, gravity: grav, wristOff: wristOff)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertGreaterThanOrEqual(sessions[0].start, at(2, 50),
                                    "night began \((sessions[0].start - refMidnight) / 60) min past midnight")
    }
}
