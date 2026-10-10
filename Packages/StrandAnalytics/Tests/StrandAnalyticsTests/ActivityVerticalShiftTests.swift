import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The measured change of height (`ActivityVerticalShift`) on synthetic 100 Hz IMU with known physics.
final class ActivityVerticalShiftTests: XCTestCase {

    /// Minimum-jerk displacement of `dh` metres over `T` seconds: its acceleration at time `t`.
    private func minJerkAccel(_ t: Double, dh: Double, T: Double) -> Double {
        guard t >= 0, t <= T else { return 0 }
        let s = t / T
        return dh / (T * T) * (60 * s - 180 * s * s + 120 * s * s * s)
    }

    /// `still` s, a movement, `still` s at 100 Hz. `up` is the gravity direction in the sensor frame (any tilt);
    /// `vertical` adds a vertical displacement, `horizontal` a there-and-back horizontal one (a reach).
    private func run(vertical dh: Double = 0, horizontal reach: Double = 0, moveS: Double = 1.1, still: Double = 4,
                     up: (Double, Double, Double) = (0.87, -0.42, 0.15), noise: Double = 0.004,
                     seed: UInt64 = 1) -> [ActivityVerticalShift.Sample] {
        let fs = 100.0
        let l = (up.0 * up.0 + up.1 * up.1 + up.2 * up.2).squareRoot()
        let u = (up.0 / l, up.1 / l, up.2 / l)
        // A horizontal unit vector orthogonal to `u`.
        var hx = (-u.1, u.0, 0.0)
        let hl = (hx.0 * hx.0 + hx.1 * hx.1).squareRoot()
        hx = hl > 1e-9 ? (hx.0 / hl, hx.1 / hl, 0) : (1, 0, 0)
        var state = seed
        func rnd() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        let total = Int((2 * still + moveS) * fs)
        return (0..<total).map { i in
            let t = Double(i) / fs - still
            let av = minJerkAccel(t, dh: dh, T: moveS) / 9.80665
            // There and back: half the movement out, half back.
            let ah = t < moveS / 2 ? minJerkAccel(t, dh: reach, T: moveS / 2) / 9.80665
                : minJerkAccel(t - moveS / 2, dh: -reach, T: moveS / 2) / 9.80665
            return ActivityVerticalShift.Sample(
                ax: u.0 * (1 + av) + hx.0 * ah + noise * rnd(), ay: u.1 * (1 + av) + hx.1 * ah + noise * rnd(),
                az: u.2 * (1 + av) + hx.2 * ah + noise * rnd(), gx: noise * rnd(), gy: noise * rnd(), gz: noise * rnd())
        }
    }

    func testAStandUpRaisesTheStrap() throws {
        let shifts = ActivityVerticalShift.detect(run(vertical: 0.40), sampleRateHz: 100, startTs: 1_000)
        let s = try XCTUnwrap(shifts.first)
        XCTAssertEqual(shifts.count, 1)
        XCTAssertEqual(s.displacementM, 0.40, accuracy: 0.06)
        XCTAssertGreaterThan(s.quality, 0.5)
        XCTAssertLessThan(ActivityStillPosture.anchorLean(s)!, 0, "a rise anchors standing")
        XCTAssertGreaterThanOrEqual(s.startTs, 1_002); XCTAssertLessThanOrEqual(s.ts, 1_008)
    }

    func testASitDownLowersTheStrap() throws {
        let s = try XCTUnwrap(ActivityVerticalShift.detect(run(vertical: -0.42), sampleRateHz: 100, startTs: 0).first)
        XCTAssertEqual(s.displacementM, -0.42, accuracy: 0.06)
        XCTAssertGreaterThan(ActivityStillPosture.anchorLean(s)!, 0, "a drop anchors sitting")
    }

    func testAReachThatReturnsIsNotAShift() {
        XCTAssertTrue(ActivityVerticalShift.detect(run(horizontal: 0.35), sampleRateHz: 100, startTs: 0).isEmpty)
    }

    func testASmallVerticalMovementIsNotAShift() {
        XCTAssertTrue(ActivityVerticalShift.detect(run(vertical: 0.08), sampleRateHz: 100, startTs: 0).isEmpty,
                      "leaning forward a few centimetres is not a change of posture")
    }

    func testStillnessAloneFindsNothingAndShortRunsAreSkipped() {
        XCTAssertTrue(ActivityVerticalShift.detect(run(), sampleRateHz: 100, startTs: 0).isEmpty)
        XCTAssertTrue(ActivityVerticalShift.detect(Array(run(vertical: 0.4).prefix(300)), sampleRateHz: 100, startTs: 0).isEmpty)
        XCTAssertTrue(ActivityVerticalShift.detect([], sampleRateHz: 100, startTs: 0).isEmpty)
    }

    func testOrientationOfTheStrapDoesNotMatter() {
        for up in [(0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.5, 0.5, -0.7)] {
            let s = ActivityVerticalShift.detect(run(vertical: 0.38, up: up), sampleRateHz: 100, startTs: 0).first
            XCTAssertNotNil(s, "\(up)")
            XCTAssertEqual(s?.displacementM ?? 0, 0.38, accuracy: 0.06, "\(up)")
        }
    }

    func testTheWindowDocumentRoundTripsShifts() throws {
        var set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "t", windows: [
            ActivityWindowPrediction(startTs: 100, endTs: 104, label: .stationary, probs: ["stationary": 1])])
        set.verticalShifts = [ActivityVerticalShiftEvidence(ts: 130, startTs: 126, displacementM: 0.412, quality: 0.83)]
        let doc = set.jsonObject(dayStart: 0)
        let data = try JSONSerialization.data(withJSONObject: doc)
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(try JSONSerialization.jsonObject(with: data),
                                                                 encoderId: "hart", encoderVersion: "t"))
        XCTAssertEqual(back.verticalShifts, [ActivityVerticalShiftEvidence(ts: 130, startTs: 126, displacementM: 0.412,
                                                                           quality: 0.83)])
        XCTAssertEqual(back.clipped(from: 0, to: 120).verticalShifts, [])
        XCTAssertEqual(ActivityEncoderWindowSet.merged([back, back])?.verticalShifts.count, 1)
        // A set without shifts serialises exactly as before the block existed.
        set.verticalShifts = []
        XCTAssertNil(set.jsonObject(dayStart: 0)["v_schema"])
    }

    func testShiftsReachTheDecoderThroughTheTrackInput() {
        var sim = ActivitySim(start: 10_000, seed: 3)
        sim.forearm(0.9)
        sim.walk(60)
        sim.still(300)
        let shiftAt = sim.ts
        sim.still(300)
        var input = ActivityContextTrackInput(dayStart: 9_000, dayEnd: 12_000)
        let obs = sim.observations
        input.gravity = obs.compactMap { o in o.gravity.map { GravitySample(ts: o.ts, x: $0[0], y: $0[1], z: $0[2], dynAccel: o.dynAccelG) } }
        input.hr = obs.compactMap { o in o.hrBpm.map { HRSample(ts: o.ts, bpm: $0) } }
        input.verticalShifts = [ActivityVerticalShiftEvidence(ts: shiftAt, startTs: shiftAt - 2, displacementM: 0.4, quality: 0.9)]
        let built = ActivityContextTrackBuilder.observations(for: input)
        XCTAssertEqual(built.filter { $0.verticalShift != nil }.count, 1)
        var c = ActivityDecoderConfig()
        c.placements = [ActivityPlacementSpan(start: 0, end: nil, placement: .bicep)]
        XCTAssertNotEqual(ActivityContextDayBuilder.fingerprint(input, through: nil, config: c),
                          ActivityContextDayBuilder.fingerprint({ var i = input; i.verticalShifts = []; return i }(), through: nil, config: c),
                          "a late shift re-decodes the day")
    }
}
