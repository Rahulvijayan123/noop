import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// HRVFreqDomain v2 (spec-02 §1 HF power correctness repair). The v1 tests only checked RELATIVE band
/// dominance (HF > 3·LF) and span gates, which a variance-normalized, timestamp-free estimator passes; they
/// could not see that its "ms²" were dimensionless or that gaps were spliced out. These tests pin ABSOLUTE
/// power against the closed form (a sinusoid of amplitude A ms carries A²/2 ms²), against an independent
/// reference (`scipy.signal.lombscargle`, normalize=False, scipy 1.18.1 / numpy 2.5.3 in the sidecar venv,
/// same grid, same S = 2·Δt̄·P scaling — script and values in docs/spec-02/notes/cardiac.md), and pin the
/// timing rules (true interval-END times, gaps never bridged, removed beats missing at their true times).
final class HRVFreqDomainTests: XCTestCase {

    private static let t0 = 1_790_000_000

    /// Deterministic tachogram: each interval is `base + amp·sin(2π f0 t)` ms (rounded half-up to whole
    /// ms, as stored), where t is the previous beat's END time; each beat is stamped with the whole second
    /// in which its interval ends (the WHOOP record convention). `ends` are the exact END times (s).
    /// Bit-identical to `fixture()` in the Python reference script.
    private func fixture(base: Double, amp: Double, f0: Double, duration: Double,
                         phaseT0: Double = 0, tsOffset: Int = 0) -> (beats: [RRInterval], ends: [Double]) {
        var t = 0.0
        var beats: [RRInterval] = []
        var ends: [Double] = []
        while t < duration {
            let rr = Int((base + amp * sin(2 * Double.pi * f0 * (t + phaseT0)) + 0.5).rounded(.down))
            t += Double(rr) / 1000.0
            beats.append(RRInterval(ts: Self.t0 + tsOffset + Int(t.rounded(.down)), rrMs: rr))
            ends.append(t)
        }
        return (beats, ends)
    }

    /// The same series with beat `k` (for each k in `positions`) split into a 250 ms artifact and the
    /// remainder: total elapsed time is unchanged, both pieces are removed by cleaning (range, ectopic).
    private func withSplitBeats(_ beats: [RRInterval], at positions: Set<Int>) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = 0.0
        for (k, b) in beats.enumerated() {
            if positions.contains(k) {
                let first = t + 0.25
                out.append(RRInterval(ts: Self.t0 + Int(first.rounded(.down)), rrMs: 250))
                t += Double(b.rrMs) / 1000.0
                out.append(RRInterval(ts: Self.t0 + Int(t.rounded(.down)), rrMs: b.rrMs - 250))
            } else {
                t += Double(b.rrMs) / 1000.0
                out.append(RRInterval(ts: Self.t0 + Int(t.rounded(.down)), rrMs: b.rrMs))
            }
        }
        return out
    }

    /// Power (ms²) of one window's samples inside [lo, hi] Hz, with the production grid and scaling.
    private func narrowPower(_ w: HRVFreqDomain.WindowSamples, _ lo: Double, _ hi: Double) -> Double {
        let rel = w.t.map { $0 - w.t[0] }
        let mean = w.rr.reduce(0, +) / Double(w.rr.count)
        let span = rel.last!
        return HRVFreqDomain.bandPower(times: rel, y: w.rr.map { $0 - mean }, fLow: lo, fHigh: hi,
                                       maxStep: min(HRVFreqDomain.freqStepHz, 1 / (5 * span)),
                                       dtMean: span / Double(rel.count - 1))
    }

    // MARK: - Absolute power (closed form + scipy reference)

    func testHFSinusoidRecoveredWithAbsolutePowerInMs2() throws {
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let out = HRVFreqDomain.analyze(rr: fx.beats)
        let b = try XCTUnwrap(out.bands)
        XCTAssertEqual(b.tier, .fullWindows)
        XCTAssertEqual(b.windowCount, 1)
        XCTAssertEqual(b.usedBeats, 333)
        // Closed form: A²/2 = 450 ms² (within 1%: rounding to whole ms and finite-window leakage).
        XCTAssertEqual(b.hf, 450, accuracy: 4.5)
        // Independent reference: scipy.signal.lombscargle on the same window, same grid and scaling.
        XCTAssertEqual(b.hf, 448.612207270, accuracy: 448.612207270 * 1e-6)
        XCTAssertEqual(try XCTUnwrap(b.lf), 0.380885395, accuracy: 1e-5)
        XCTAssertEqual(b.totalPower, 448.612207270 + 0.380885395 + 0.078985421, accuracy: 1e-3)
        XCTAssertGreaterThan(try XCTUnwrap(b.lfhf), 0)
        XCTAssertLessThan(try XCTUnwrap(b.lfhf), 0.01, "an HF sinusoid puts almost nothing in LF")
    }

    func testLFSinusoidRecoveredWithAbsolutePowerInMs2() throws {
        let fx = fixture(base: 900, amp: 30, f0: 0.10, duration: 299)
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: fx.beats))
        let lf = try XCTUnwrap(b.lf)
        XCTAssertEqual(lf, 450, accuracy: 4.5)
        XCTAssertEqual(lf, 448.182016470, accuracy: 448.182016470 * 1e-6)    // scipy reference
        XCTAssertEqual(b.hf, 1.131841221, accuracy: 1e-5)                     // scipy reference
        XCTAssertGreaterThan(try XCTUnwrap(b.lfhf), 100)
    }

    func testDoublingAmplitudeAtFixedTimestampsQuadruplesPower() throws {
        // FIXED timestamps: the same sample times, values 900 + y and 900 + 2y.
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let t = fx.ends.map { $0 - fx.ends[0] }
        let y = t.map { 30 * sin(2 * Double.pi * 0.25 * $0) }
        let p1 = HRVFreqDomain.windowPower(t: t, rr: y.map { 900 + $0 }, rawBeats: t.count, rejected: 0)
        let p2 = HRVFreqDomain.windowPower(t: t, rr: y.map { 900 + 2 * $0 }, rawBeats: t.count, rejected: 0)
        XCTAssertEqual(p2.hf / p1.hf, 4.0, accuracy: 1e-9)
        XCTAssertEqual(p1.hf, 448.1293897089, accuracy: 448.13 * 1e-6)        // scipy reference
        // Through the public path the timing moves with the values, so ≈ 4 (scipy reference 1785.2277).
        let big = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: fixture(base: 900, amp: 60, f0: 0.25, duration: 299).beats))
        XCTAssertEqual(big.hf, 1785.227739745, accuracy: 1785.23 * 1e-6)
        let small = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: fx.beats))
        XCTAssertEqual(big.hf / small.hf, 4.0, accuracy: 0.05)
    }

    func testWhiteNoiseIntegratesToItsVariance() {
        // Parseval check of the one-sided PSD scaling: evenly sampled white noise integrates to var(y).
        var state: UInt64 = 12345
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var y = (0..<300).map { _ in (next() - 0.5) * 100 }
        let mean = y.reduce(0, +) / 300
        y = y.map { $0 - mean }
        let variance = y.reduce(0) { $0 + $1 * $1 } / 300
        let t = (0..<300).map(Double.init)
        let power = HRVFreqDomain.bandPower(times: t, y: y, fLow: 0.0033, fHigh: 0.499,
                                            maxStep: 1 / (5 * 299.0), dtMean: 1.0)
        XCTAssertEqual(power / variance, 0.9948579251, accuracy: 1e-3)     // scipy reference ratio
    }

    func testSinusoidPeakIsAtTheRightFrequencyUnderIrregularSpacing() throws {
        // Strongly irregular spacing: ±100 ms deterministic jitter on every interval plus a 0.30 Hz,
        // 60 ms modulation. The narrow band around 0.30 Hz must dominate narrow bands elsewhere in HF.
        var state: UInt64 = 99
        func jitter() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 200
        }
        var t = 0.0
        var beats: [RRInterval] = []
        while t < 299 {
            let rr = Int((900 + 60 * sin(2 * Double.pi * 0.30 * t) + jitter()).rounded())
            t += Double(rr) / 1000
            beats.append(RRInterval(ts: Self.t0 + Int(t.rounded(.down)), rrMs: rr))
        }
        var diag = HRVFreqDomain.Diagnostics()
        let w = try XCTUnwrap(HRVFreqDomain.qualifiedWindows(values: beats.map { Double($0.rrMs) },
                                                               diagnostics: &diag).first)
        let atPeak = narrowPower(w, 0.29, 0.31)
        for other in [0.20, 0.25, 0.36] {
            XCTAssertGreaterThan(atPeak, 3 * narrowPower(w, other - 0.01, other + 0.01), "at \(other) Hz")
        }
    }

    // MARK: - Timing: gaps retained, removed beats keep their true time

    func testRecordingGapIsRetainedNotBridged() throws {
        let a = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let b = fixture(base: 900, amp: 30, f0: 0.25, duration: 299, phaseT0: 1.3, tsOffset: 420)
        let out = HRVFreqDomain.analyze(rr: a.beats + b.beats)
        XCTAssertEqual(out.diagnostics.timingBreaks, 1, "the 120 s hole breaks the run")
        let bands = try XCTUnwrap(out.bands)
        XCTAssertEqual(bands.windowCount, 2, "one window per side; none spans the gap")
        XCTAssertLessThan(bands.usedSpanSec, 600)
        XCTAssertEqual(bands.hf, 450, accuracy: 9)
        XCTAssertEqual(bands.observedSpanSec, Double(b.beats.last!.ts - a.beats.first!.ts))
    }

    func testLevelShiftAcrossAGapDoesNotBecomeLowFrequencyPower() throws {
        // 150 s at RR≈900 ms, a 30-minute hole, 150 s at RR≈1100 ms. Bridging the hole (what cumulative
        // sums of the surviving intervals did) turns the level shift into a step that floods LF/VLF.
        let a = fixture(base: 900, amp: 30, f0: 0.25, duration: 150)
        let b = fixture(base: 1100, amp: 30, f0: 0.25, duration: 150, tsOffset: 1800)
        let split = try XCTUnwrap(HRVFreqDomain.analyze(rr: a.beats + b.beats).bands)
        XCTAssertEqual(split.tier, .shortWindowHFOnly, "two 150 s stretches: HF only, no LF claimed")
        XCTAssertNil(split.lf)
        XCTAssertEqual(split.hf, 450, accuracy: 25)
        let bridged = try XCTUnwrap(HRVFreqDomain.analyze(
            assumingContiguousRR: (a.beats + b.beats).map { Double($0.rrMs) }).bands)
        XCTAssertGreaterThan(try XCTUnwrap(bridged.lf), 50, "a bridged step is spurious low-frequency power")
    }

    func testRemovedBeatsStayMissingAtTheirTrueTimes() throws {
        let clean = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let positions: Set<Int> = [40, 80, 120, 160, 200, 240, 280]
        let artifact = withSplitBeats(clean.beats, at: positions)
        var diag = HRVFreqDomain.Diagnostics()
        let windows = HRVFreqDomain.qualifiedWindows(values: artifact.map { Double($0.rrMs) }, diagnostics: &diag)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(diag.cleaningSplits, 0, "a 1.8 s missing stretch is a missing sample, not a split")
        let w = windows[0]
        XCTAssertEqual(w.rawBeats - w.t.count, w.rejected)
        XCTAssertEqual(w.t.count, 333 - 7, "each split beat leaves one missing sample")
        // Every retained sample sits at the TRUE end time of its interval.
        let trueEnds = Set(clean.ends.map { (($0 - clean.ends[0]) * 1e6).rounded() })
        for t in w.t { XCTAssertTrue(trueEnds.contains((t * 1e6).rounded()), "sample at \(t) s is off its true time") }
        // The 0.25 Hz line keeps its power at the right frequency; splicing the time axis smears it.
        var cleanDiag = HRVFreqDomain.Diagnostics()
        let cleanWindow = HRVFreqDomain.qualifiedWindows(values: clean.beats.map { Double($0.rrMs) },
                                                         diagnostics: &cleanDiag)[0]
        let reference = narrowPower(cleanWindow, 0.24, 0.26)
        XCTAssertEqual(narrowPower(w, 0.24, 0.26) / reference, 1.0, accuracy: 0.05)
        var spliced: [Double] = []
        var acc = 0.0
        for v in w.rr { spliced.append(acc); acc += v / 1000 }   // v1: time = cumsum of survivors
        let splicedWindow = HRVFreqDomain.WindowSamples(t: spliced, rr: w.rr, rawBeats: w.rawBeats,
                                                        rejected: w.rejected)
        XCTAssertLessThan(narrowPower(splicedWindow, 0.24, 0.26) / reference, 0.93)
    }

    func testMissingBeatRowSplitsTheRun() throws {
        var beats = fixture(base: 900, amp: 30, f0: 0.25, duration: 600).beats
        beats.remove(at: 330)                   // one beat never delivered
        let out = HRVFreqDomain.analyze(rr: beats)
        XCTAssertEqual(out.diagnostics.timingBreaks, 1)
        XCTAssertEqual(out.diagnostics.timingRuns, 2)
        let bands = try XCTUnwrap(out.bands)
        XCTAssertEqual(bands.windowCount, 2)
        XCTAssertEqual(bands.hf, 450, accuracy: 9)
    }

    func testTimingRunsBreakOnDisagreeingTimestampsAndChannelChange() {
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 120)
        // Re-stamp the second half 3 s late: the intervals no longer fit the clock.
        let shifted = fx.beats.enumerated().map { k, b in
            k < 60 ? b : RRInterval(ts: b.ts + 3, rrMs: b.rrMs)
        }
        var diag = HRVFreqDomain.Diagnostics()
        let runs = HRVFreqDomain.timingRuns(shifted, diagnostics: &diag)
        XCTAssertEqual(diag.timingBreaks, 1)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count + runs[1].count + diag.ambiguousBeats, shifted.count)
        XCTAssertEqual(runs[1].first?.ts, shifted[60].ts, "the new run starts at the first late beat")

        let mixed = fx.beats.enumerated().map { k, b in
            RRInterval(ts: b.ts, rrMs: b.rrMs, srcChannel: k < 60 ? .whoop5Historical : .whoop5Standard)
        }
        var diag2 = HRVFreqDomain.Diagnostics()
        XCTAssertEqual(HRVFreqDomain.timingRuns(mixed, diagnostics: &diag2).count, 2)
        XCTAssertEqual(diag2.channelBreaks, 1)
        XCTAssertEqual(diag2.timingBreaks, 0)
    }

    func testExactDuplicatesAreRemovedNotDoubleCounted() throws {
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let once = try XCTUnwrap(HRVFreqDomain.analyze(rr: fx.beats).bands)
        let twiceOut = HRVFreqDomain.analyze(rr: fx.beats + fx.beats)
        XCTAssertEqual(twiceOut.diagnostics.duplicatesRemoved, fx.beats.count)
        XCTAssertEqual(try XCTUnwrap(twiceOut.bands), once)
    }

    // MARK: - Gates, invalid data, unavailable

    func testNoIntervalsIsUnavailableWithReason() {
        let out = HRVFreqDomain.analyze(rr: [])
        XCTAssertNil(out.bands)
        XCTAssertEqual(out.unavailableReason, .noIntervals)
    }

    func testUnderSixtySecondsAbstains() {
        let out = HRVFreqDomain.analyze(rr: fixture(base: 1000, amp: 20, f0: 0.25, duration: 40).beats)
        XCTAssertNil(out.bands)
        XCTAssertEqual(out.unavailableReason, .noContiguousWindow)
    }

    func testShortSpanGivesHFOnly() throws {
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: fixture(base: 900, amp: 30, f0: 0.25, duration: 120).beats))
        XCTAssertEqual(b.tier, .shortWindowHFOnly)
        XCTAssertNil(b.lf)
        XCTAssertNil(b.lfhf)
        XCTAssertEqual(b.totalPower, b.hf, accuracy: 1e-12)
        XCTAssertEqual(b.hf, 450, accuracy: 25)
    }

    func testAllInvalidIntervalsAreUnavailable() {
        // 100 ms "intervals" stamped consistently: every one fails the range filter.
        var t = 0.0
        let beats: [RRInterval] = (0..<2000).map { _ in
            t += 0.1
            return RRInterval(ts: Self.t0 + Int(t.rounded(.down)), rrMs: 100)
        }
        let out = HRVFreqDomain.analyze(rr: beats)
        XCTAssertNil(out.bands)
        XCTAssertEqual(out.unavailableReason, .noContiguousWindow)
    }

    func testHeavilyRejectedWindowsAreWithheld() {
        // Every 4th beat split into artifacts: 40% of each window's beats are removed by cleaning.
        let clean = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let artifact = withSplitBeats(clean.beats, at: Set(stride(from: 2, to: clean.beats.count, by: 4)))
        let out = HRVFreqDomain.analyze(rr: artifact)
        XCTAssertNil(out.bands)
        XCTAssertEqual(out.unavailableReason, .rejectedFractionTooHigh)
        XCTAssertGreaterThan(out.diagnostics.windowsRejectedByCleaning, 0)
    }

    func testUnitsMethodSourceAndCoverage() throws {
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 900)
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rr: fx.beats))
        XCTAssertEqual(b.unit, "ms²")
        XCTAssertEqual(b.method, "lomb_scargle_psd_ms2_v2")
        XCTAssertEqual(b.source, "prv_optical")
        XCTAssertEqual(b.windowCount, 3)
        XCTAssertEqual(b.rejectedFraction, 0, accuracy: 1e-12)
        let coverage = try XCTUnwrap(b.coverageFraction)
        XCTAssertGreaterThan(coverage, 0.98)
        XCTAssertLessThanOrEqual(coverage, 1)
    }

    func testContiguousReferencePathMatchesTimestampedPathOnGaplessData() throws {
        let fx = fixture(base: 900, amp: 30, f0: 0.25, duration: 299)
        let timed = try XCTUnwrap(HRVFreqDomain.analyze(rr: fx.beats).bands)
        let assumed = try XCTUnwrap(HRVFreqDomain.analyze(assumingContiguousRR: fx.beats.map { Double($0.rrMs) }).bands)
        XCTAssertEqual(assumed.hf, timed.hf, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(assumed.lf), try XCTUnwrap(timed.lf), accuracy: 1e-9)
    }
}
