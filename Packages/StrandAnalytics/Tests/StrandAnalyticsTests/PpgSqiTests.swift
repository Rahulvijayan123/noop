import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Deterministic PPG signal-quality index (PpgSqi) over synthetic v26 waveforms.
///
/// Every waveform is built as the WHOOP 5/MG v26 wire form really arrives: one absolute baseCode
/// plus 24 i16 deltas per second, reconstructed inside PpgSqi with ppgWaveformAbsolute. All tests
/// are pure functions of the inputs — no files, no network, no clock — so they cannot flake.
final class PpgSqiTests: XCTestCase {
    private let fs = PpgHr.sampleRateHz   // 24 samples per 1-second record

    /// Per-second v26 records of a sine at `bpm` heart rate (bpm/60 Hz) with ADC-count amplitude
    /// `amplitude`. Deltas are the consecutive differences of 25 absolute samples per second
    /// (1 base + 24 deltas), with phase continuous across record boundaries.
    private func sineWave(bpm: Double, seconds: Int, amplitude: Double,
                          baseTs: Int = 1_780_000_000, base: Int = 100_000)
        -> [PpgWaveformSample] {
        records(hz: bpm / 60.0, seconds: seconds, amp: amplitude,
                baseTs: baseTs, base: base)
    }

    /// Build `seconds` consecutive v26 records of a `hz`-Hz sine at ADC-count amplitude `amp`, starting
    /// at `baseTs`. `saturateDeltas` clamps the first N deltas to the Int16 rails (encoder saturation);
    /// `constantDelta` overrides the sine with a fixed per-sample delta (flatline);
    /// `missingBase` drops the absolute baseCode from every record.
    private func records(hz: Double, seconds: Int, amp: Double,
                         baseTs: Int = 1_780_000_000, base: Int = 100_000,
                         saturateDeltas: Int = 0, constantDelta: Int? = nil,
                         missingBase: Bool = false, pulsePeriod: Int? = nil)
        -> [PpgWaveformSample] {
        var out: [PpgWaveformSample] = []
        for s in 0..<seconds {
            // 25 absolute samples per second (1 base + 24 deltas), continuous phase across seconds.
            let vals: [Int]
            if let cd = constantDelta {
                vals = (0...fs).map { base + cd * $0 }
            } else if let pulsePeriod {
                // Narrow spike every `pulsePeriod` samples (base + amp), flat otherwise. A very-low
                // bpm SINE is nearly a linear ramp, so its detrended residual autocorrelates
                // strongly at small lags; a sparse pulse train has ~zero ACF at every searched lag.
                vals = (0...fs).map { i in (i % pulsePeriod == 0) ? base + Int(amp) : base }
            } else {
                vals = (0...fs).map { i in
                    base + Int(amp * sin(2 * Double.pi * hz * Double(s * fs + i) / Double(fs)))
                }
            }
            var deltas = (0..<fs).map { vals[$0 + 1] - vals[$0] }
            if saturateDeltas > 0 {
                for j in 0..<min(saturateDeltas, deltas.count) {
                    deltas[j] = j % 2 == 0 ? Int(Int16.max) : Int(Int16.min)
                }
            }
            out.append(PpgWaveformSample(ts: baseTs + s, samples: deltas,
                                         burstIndex: nil, baseCode: missingBase ? nil : vals[0]))
        }
        return out
    }

    private let hardGateReasons = ["coverage_low", "flatline", "saturation",
                                   "amplitude_out_of_band", "base_code_missing"]

    // MARK: - Clean signals

    func testClean60BpmScoresHighWithNoHardGateReasons() throws {
        let r = PpgSqi.evaluate(sineWave(bpm: 60, seconds: 10, amplitude: 5800), strapHrBpm: 60)
        let score = try XCTUnwrap(r.score)
        XCTAssertGreaterThanOrEqual(score, 0.5, "clean 60 bpm should score high, got \(score)")
        for reason in hardGateReasons {
            XCTAssertFalse(r.reasons.contains(reason), "clean window must not report \(reason)")
        }
        let bpm = try XCTUnwrap(r.derivedBpm)
        XCTAssertTrue((50...70).contains(bpm), "derivedBpm \(bpm) outside 50...70")
        XCTAssertGreaterThanOrEqual(r.coverageSeconds, 3.0)
        XCTAssertEqual(r.templateCorrelation.map { $0 > 0.5 } ?? false, true)
    }

    func testClean120BpmDerivesCorrectHr() throws {
        let r = PpgSqi.evaluate(sineWave(bpm: 120, seconds: 10, amplitude: 5800), strapHrBpm: 120)
        let bpm = try XCTUnwrap(r.derivedBpm)
        XCTAssertTrue((110...130).contains(bpm), "derivedBpm \(bpm) outside 110...130")
        // 120 bpm's 12-sample beat is on the template band edge; must still produce a score, not nil.
        XCTAssertNotNil(r.score)
    }

    // MARK: - Hard gates

    func testFlatlineScoresZero() {
        let r = PpgSqi.evaluate(records(hz: 1.0, seconds: 10, amp: 5800, constantDelta: 0),
                                strapHrBpm: 60)
        XCTAssertEqual(r.score, 0)
        XCTAssertTrue(r.reasons.contains("flatline"))
        XCTAssertEqual(r.coverageSeconds, 10)
    }

    func testSaturatedDeltasTriggerSaturation() {
        // 10 of 240 deltas on the Int16 rails = 4.2% > the 2% gate.
        let r = PpgSqi.evaluate(records(hz: 1.0, seconds: 10, amp: 5800, saturateDeltas: 10),
                                strapHrBpm: 60)
        XCTAssertEqual(r.score, 0)
        XCTAssertTrue(r.reasons.contains("saturation"))
    }

    func testMissingBaseCodeIsUnusable() {
        let r = PpgSqi.evaluate(records(hz: 1.0, seconds: 10, amp: 5800, missingBase: true),
                                strapHrBpm: 60)
        XCTAssertNil(r.score)
        XCTAssertTrue(r.reasons.contains("base_code_missing"))
    }

    func testCoverageBelowMinimumScoresZero() {
        let r = PpgSqi.evaluate(records(hz: 1.0, seconds: 2, amp: 5800), strapHrBpm: 60)
        XCTAssertEqual(r.score, 0)
        XCTAssertTrue(r.reasons.contains("coverage_low"))
        XCTAssertEqual(r.coverageSeconds, 2)
    }

    func testTinyAmplitudeIsOutOfBand() {
        // amp 5 -> detrended RMS ~3.5 counts, far below the CALIBRATE 200...8000 band floor.
        let r = PpgSqi.evaluate(records(hz: 1.0, seconds: 10, amp: 5), strapHrBpm: 60)
        XCTAssertEqual(r.score, 0)
        XCTAssertTrue(r.reasons.contains("amplitude_out_of_band"))
    }

    // MARK: - Agreement gate

    func testAliased50HzWithStrap60IsPenalized() throws {
        // 50 Hz sampled at 24 Hz aliases to a clean ~120 bpm equivalent (period 12 samples), so the
        // waveform itself is perfectly periodic — only the strap-HR disagreement can catch it.
        let r = PpgSqi.evaluate(records(hz: 50.0, seconds: 10, amp: 5800), strapHrBpm: 60)
        let score = try XCTUnwrap(r.score)
        XCTAssertTrue(r.reasons.contains("hr_disagreement"))
        XCTAssertLessThan(score, 0.5, "aliased waveform must not score clean (got \(score))")
        // The disagreement penalty (0.3) caps the score below 0.5 even with perfect components.
        XCTAssertLessThanOrEqual(score, 0.31)
    }

    // MARK: - Component edge cases

    func testVeryLowBpmBeyondBandIsGraceful() {
        // 10 bpm (144-sample period) is far below the 30...220 bpm ACF band. A sparse pulse train at
        // that rate has ~zero autocorrelation at every searched lag (7...48 samples), so PpgHr
        // reports no pulsatile peak and every periodicity-derived component comes back nil —
        // gracefully, without a crash.
        let r = PpgSqi.evaluate(records(hz: 1.0 / 6.0, seconds: 20, amp: 5800,
                                        pulsePeriod: 144), strapHrBpm: nil)
        XCTAssertEqual(r.score, 0)
        XCTAssertNil(r.periodicityConfidence)
        XCTAssertNil(r.templateCorrelation)
        XCTAssertNil(r.derivedBpm)
        XCTAssertTrue(r.reasons.contains("periodicity_low"))
    }

    func testHighBpmBeatBelowTemplateFloorIsGraceful() throws {
        // 150 bpm -> ~10-sample beat, below the 12-sample template floor. PpgHr still resolves the
        // rate (144 bpm here), but the beat is too short to template, so tmcc is nil and the source
        // reports the observation reason "template_too_short_or_long"; the score still computes with
        // renormalised weights (skew + amplitude only) instead of crashing or forcing 0.
        let r = PpgSqi.evaluate(sineWave(bpm: 150, seconds: 10, amplitude: 5800), strapHrBpm: 150)
        XCTAssertNil(r.templateCorrelation)
        XCTAssertTrue(r.reasons.contains("template_too_short_or_long"))
        XCTAssertNotNil(try XCTUnwrap(r.derivedBpm))
        XCTAssertNotNil(r.periodicityConfidence)
        let score = try XCTUnwrap(r.score)
        XCTAssertGreaterThanOrEqual(score, 0, "renormalised score must still be computed")
        XCTAssertGreaterThan(score, 0)
    }

    func testNoStrapHrReportsReferenceButNoPenalty() throws {
        let r = PpgSqi.evaluate(sineWave(bpm: 60, seconds: 10, amplitude: 5800), strapHrBpm: nil)
        XCTAssertTrue(r.reasons.contains("no_hr_reference"))
        XCTAssertFalse(r.reasons.contains("hr_disagreement"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.score), 0.5, "no reference must not penalise")
    }

    // MARK: - Determinism

    func testDeterministicSameInputTwice() {
        let input = sineWave(bpm: 60, seconds: 10, amplitude: 5800)
        let a = PpgSqi.evaluate(input, strapHrBpm: 60)
        let b = PpgSqi.evaluate(input, strapHrBpm: 60)
        XCTAssertEqual(a, b)
        // And the evaluation is a pure function: re-running on an identical but fresh array matches too.
        let c = PpgSqi.evaluate(sineWave(bpm: 60, seconds: 10, amplitude: 5800), strapHrBpm: 60)
        XCTAssertEqual(a, c)
    }
}
