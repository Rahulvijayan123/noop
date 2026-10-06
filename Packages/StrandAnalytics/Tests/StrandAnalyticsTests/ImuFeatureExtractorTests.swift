import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins `ImuFeatureExtractor` — activity features from decoded 5/MG raw IMU (#423), imu-feat-2
/// contract (WS-04-F01..F06). Cadence is validated to recover MULTIPLE distinct injected rates,
/// gyro is validated as true RMS (not mean), jerk is validated as per-second (g/s, rate-invariant
/// within the documented bandwidth tolerance), and the cross-runtime golden fixture is pinned
/// numerically against the values computed by the Python 30 Hz pipeline.
final class ImuFeatureExtractorTests: XCTestCase {

    /// 100 Hz samples: gravity on Z + a sinusoidal wobble of amplitude `amp` g at `cadence` Hz on Z,
    /// and an optional constant gyro rotation `gyroDps` on gx.
    private func gaitSamples(cadence: Double, amp: Double = 0.2, seconds: Double = 6,
                             gyroDps: Double = 0) -> [RawImuSample] {
        let rate = 100.0, n = Int(seconds * rate)
        return (0..<n).map { i in
            let az = 1.0 + amp * sin(2 * .pi * cadence * Double(i) / rate)
            return RawImuSample(ax: 0, ay: 0, az: az, gx: gyroDps, gy: 0, gz: 0)
        }
    }

    /// The shared imu-feat-2 golden signal (Tools/ActivityContext/fixtures/imu_feat2_golden.json):
    /// az = 1.0 + 0.25·sin(2π·2.0·t) g and gx = 45.0·sin(2π·2.0·t) °/s. The zero-mean gyro is
    /// exactly the case where RMS (31.82) differs from the imu-feat-1 mean (28.65), so a
    /// mean-vs-RMS regression cannot hide.
    private func goldenSamples(rate: Int, seconds: Double = 4) -> [RawImuSample] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let az = 1.0 + 0.25 * sin(2 * .pi * 2.0 * t)
            let gx = 45.0 * sin(2 * .pi * 2.0 * t)
            return RawImuSample(ax: 0, ay: 0, az: az, gx: gx, gy: 0, gz: 0)
        }
    }

    func testRecoversMultipleDistinctCadences() {
        // The load-bearing test: the extractor must track a VARYING input, not manufacture one rate.
        for target in [1.4, 1.8, 2.4, 3.0] {
            let f = ImuFeatureExtractor.extract(gaitSamples(cadence: target), sampleRateHz: 100)
            XCTAssertNotNil(f.cadenceHz, "cadence \(target) Hz should be detected")
            XCTAssertEqual(f.cadenceHz ?? -9, target, accuracy: 0.15,
                           "recovered cadence should match the injected \(target) Hz")
            XCTAssertGreaterThan(f.cadenceStrength, 0.4, "a clean sinusoid should read as strongly rhythmic")
        }
    }

    func testStillHasNoCadenceAndLowEnergy() {
        // Gravity only, negligible noise.
        let still = (0..<600).map { _ in RawImuSample(ax: 0, ay: 0, az: 1.0, gx: 0, gy: 0, gz: 0) }
        let f = ImuFeatureExtractor.extract(still, sampleRateHz: 100)
        XCTAssertNil(f.cadenceHz, "a still wrist has no gait cadence")
        XCTAssertLessThan(f.accelEnergyG, 0.01)
        XCTAssertLessThan(f.gyroRmsDps, 0.01)
    }

    func testEnergyAndJerkRiseWithMotion() {
        let still = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, amp: 0.0), sampleRateHz: 100)
        let moving = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, amp: 0.3), sampleRateHz: 100)
        XCTAssertGreaterThan(moving.accelEnergyG, still.accelEnergyG + 0.05)
        XCTAssertGreaterThan(moving.jerkRmsGps, still.jerkRmsGps)
    }

    func testGyroIsTrueRmsNotMean() {
        // Constant 45 dps: RMS == mean == 45 (the imu-feat-1 hiding case, kept as a regression pin).
        let constant = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, gyroDps: 45), sampleRateHz: 100)
        XCTAssertEqual(constant.gyroRmsDps, 45, accuracy: 1.0, "constant 45 dps rotation should read back")
        // Zero-mean 45 dps sinusoid: RMS = 45/√2 ≈ 31.82; the imu-feat-1 mean read 28.65. Asserting
        // the RMS value (WS-04-F01) makes a mean-vs-RMS regression fail loudly.
        let f = ImuFeatureExtractor.extract(goldenSamples(rate: 100), sampleRateHz: 100)
        XCTAssertEqual(f.gyroRmsDps, 31.82, accuracy: 0.02, "true RMS of a 45 dps sinusoid is 31.82")
        XCTAssertGreaterThan(f.gyroRmsDps, 31.0, "must be RMS (~31.8), not mean (~28.6)")
    }

    func testJerkIsPerSecondAndRateInvariantWithinTolerance() {
        // imu-feat-2 jerk is per-second (g/s): the same physical 4-s window at 100 Hz and at 30 Hz
        // must agree within the documented bandwidth tolerance (≤5% clean, WS-04-F02). The old
        // per-sample value differed 3.1× across rates.
        let f100 = ImuFeatureExtractor.extract(goldenSamples(rate: 100), sampleRateHz: 100)
        let f30 = ImuFeatureExtractor.extract(goldenSamples(rate: 30), sampleRateHz: 30)
        XCTAssertGreaterThan(f100.jerkRmsGps, 1.0, "per-second jerk is in g/s, not per-sample")
        let rel = abs(f100.jerkRmsGps - f30.jerkRmsGps) / f30.jerkRmsGps
        XCTAssertLessThanOrEqual(rel, 0.05, "per-second jerk must converge across 30/100 Hz")
    }

    func testGoldenFixtureMatchesSharedContract() {
        // Cross-runtime golden (WS-04-F06): the Swift 100 Hz extractor must reproduce the values
        // pinned in Tools/ActivityContext/fixtures/imu_feat2_golden.json (computed by the Python
        // 30 Hz pipeline). Hardcoded here so this test runs without file access.
        let f = ImuFeatureExtractor.extract(goldenSamples(rate: 100), sampleRateHz: 100)
        XCTAssertEqual(f.accelEnergyG, 0.17678, accuracy: 0.001, "golden accel_rms_g")
        XCTAssertEqual(f.gyroRmsDps, 31.82, accuracy: 0.01, "golden gyro_rms_dps")
        XCTAssertEqual(f.jerkRmsGps, 2.21722, accuracy: 0.005, "golden jerk_rms_gps (100 Hz)")
        XCTAssertEqual(f.cadenceHz ?? -9, 2.0, accuracy: 0.01, "golden cadence_hz")
        XCTAssertEqual(f.cadenceStrength, 0.875, accuracy: 0.01, "golden cadence_strength")
    }

    func testSlowGaitCadenceReportedInWidenedBand() {
        // imu-feat-2 band is 0.8–3.5 Hz (was 1.2–3.5, WS-04-F03): a 0.9 Hz (54 spm) gait is now
        // reported instead of nil/other_movement. The FEATURE is honest; classifier thresholds stay
        // conservative and slow-gait recognition still needs longer windows (~8 s).
        let f = ImuFeatureExtractor.extract(gaitSamples(cadence: 0.9, amp: 0.2, seconds: 4), sampleRateHz: 100)
        XCTAssertNotNil(f.cadenceHz)
        XCTAssertTrue((0.8...3.5).contains(f.cadenceHz ?? -9))
        XCTAssertEqual(f.cadenceHz ?? -9, 0.9, accuracy: 0.15)
        XCTAssertGreaterThanOrEqual(f.cadenceStrength, ImuFeatureExtractor.minCadenceStrength)
    }

    func testExtractFromDecodedFrames() {
        // End-to-end from the WhoopProtocol decoder: two frames concatenate into one feature window.
        let frame = Whoop5ImuFrame(baseTs: 0, sampleRateHz: 100, samples: gaitSamples(cadence: 2.2))
        let f = ImuFeatureExtractor.extract(frames: [frame, frame])
        XCTAssertEqual(f.sampleCount, frame.samples.count * 2)
        XCTAssertEqual(f.cadenceHz ?? -9, 2.2, accuracy: 0.15)
    }

    func testMotionEncoderOutputCalibrationDefaultsToFalse() {
        // A01: calibrated must NOT be inferred from encoder identity / baseline. The heuristic
        // baseline stays false; a HART-labelled window with no artifact also decodes false.
        let p = ActivityWindowPrediction(startTs: 0, endTs: 4, label: .walking,
                                         probs: ["walking": 0.9], baseline: false)
        let out = MotionEncoderOutput(prediction: p, encoderVersion: "v1")
        XCTAssertEqual(out.encoderId, "hart")
        XCTAssertFalse(out.calibrated, "no calibration artifact -> uncalibrated even for HART")

        let baseline = ActivityWindowPrediction(startTs: 0, endTs: 4, label: .walking,
                                                probs: ["walking": 1.0], baseline: true)
        XCTAssertFalse(MotionEncoderOutput(prediction: baseline, encoderVersion: "v1").calibrated,
                       "the heuristic baseline is never calibrated")

        // The explicit flag exists for the wire plumbing (serve response `calibrated`).
        let wired = MotionEncoderOutput(prediction: p, encoderVersion: "v1", calibrated: true)
        XCTAssertTrue(wired.calibrated)
    }
}
