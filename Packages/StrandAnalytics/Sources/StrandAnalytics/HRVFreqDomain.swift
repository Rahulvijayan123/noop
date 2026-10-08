import Foundation
import WhoopProtocol

// HRVFreqDomain.swift — frequency-domain pulse-rate variability (LF / HF / LF-HF / total power).
//
// PURELY ADDITIVE. No Charge / Effort / Rest / sleep output reads this file, and the time-domain
// `HRVAnalyzer` (canonical RMSSD / SDNN / pNN50 filtering) is called, never modified. The only consumer is
// the Stress screen's "Advanced" card (a today-only descriptive lens).
//
// OPTICAL SOURCE. The intervals are optical pulse intervals from a wrist sensor, so this is pulse-rate
// variability (`prv_optical`), not ECG-equivalent HRV, and nothing here measures "sympathetic" or
// "parasympathetic tone".
//
// ─── Spec-02 §1 correctness repair (method `lomb_scargle_psd_ms2_v2`) ─────────────────────────────────
// The v1 estimator (a) discarded the observed beat timestamps and rebuilt time from the cumulative sum of
// the CLEANED intervals, so every removed beat and every recording gap was spliced out of the time axis,
// and (b) divided the Lomb–Scargle periodogram by twice the variance (the dimensionless "normalized" form)
// while labelling the band integrals ms². Doubling a modulation's amplitude therefore did not quadruple
// its "power". v2 fixes both:
//
// 1. TRUE INTERVAL-END TIMING. A sample is the interval value `rr_k` placed at the time its interval
//    ENDS (the beat that closes it) — the standard tachogram convention. Inside one contiguous run the end
//    times are `t_k = t_run + Σ_{j ≤ k} rr_j` over ALL raw intervals of the run (rejected beats included:
//    their time elapsed even when their value is untrustworthy), so a removed beat leaves its sample
//    MISSING at its true time instead of shifting every later beat earlier.
//
// 2. DISCONTINUITIES SPLIT, NEVER BRIDGE. Stored timestamps are whole wall-clock seconds stamped on the
//    record that carried the interval, i.e. `ts_k = floor(t_k + θ)` for one unknown constant offset θ
//    per run (checked on a real WHOOP 5 night, 2026-10-07 04:00–07:00 PT, history channel: the
//    interval-END convention fits; the START convention breaks runs 2–3× more often). A run continues only
//    while some θ satisfies every beat's whole-second constraint (±`timingSlackSec`). A missing beat, a
//    wall-clock gap, a duplicate delivery that shifts the clock, or a source-channel change makes the
//    constraints infeasible and starts a new run. Beats whose run membership is ambiguous (consistent with
//    both the old and the new timing) are excluded from both. Exact retransmissions are removed by
//    observation identity first. Inside a run, cleaning (`HRVAnalyzer.cleanRRGapAware`: range filter +
//    Malik ectopic rejection, the canonical cleaner) removes samples; a stretch of removed samples longer
//    than `maxMissingSampleGapSec` is a discontinuity and splits the run, a shorter one stays a missing
//    sample at its true time (Lomb–Scargle needs no interpolation; removing — not interpolating — ectopic
//    beats is the recommended use, Clifford & Tarassenko 2005, IEEE TBME 52(4):630–638).
//
// 3. ABSOLUTE PSD (ms²/Hz). With the mean-removed samples y_i at times t_i (N samples), the classical
//    Lomb–Scargle periodogram (Lomb 1976; Scargle 1982 ApJ 263:835 eq. 10, with his time offset τ) is
//        P(f) = ½ [ (Σ y_i cos ω(t_i−τ))² / Σ cos² ω(t_i−τ) + (Σ y_i sin ω(t_i−τ))² / Σ sin² ω(t_i−τ) ],
//        ω = 2πf,  tan 2ωτ = Σ sin 2ωt_i / Σ cos 2ωt_i,
//    in ms² (for a sinusoid of amplitude A it peaks at N·A²/4; this is `scipy.signal.lombscargle` with
//    `normalize=False` on mean-removed data). For evenly sampled data P(f) equals the classical
//    periodogram |Σ y e^{−iωt}|²/N (Scargle 1982 §II), whose Parseval-scaled ONE-SIDED density is
//        S(f) = 2 · Δt̄ · P(f)   [ms²/Hz],   Δt̄ = (t_N − t_1)/(N − 1)  (mean sampling interval),
//    so ∫₀^{1/(2Δt̄)} S(f) df ≈ var(y), and a band integral ∫_{f1}^{f2} S(f) df is a band power in ms²
//    (a sinusoid of amplitude A ms integrates to A²/2 ms²). Missing samples raise Δt̄ and lower N
//    together, so the scaling stays consistent. The Swift tests pin it against the closed form and against
//    `scipy.signal.lombscargle` (reference values recorded in docs/spec-02/notes/cardiac.md).
//
// 4. QUALIFIED WINDOWS. Each split segment is tiled into consecutive `analysisWindowSec` (300 s, the
//    Task Force 1996 short-term length) windows anchored at its first sample. A window qualifies with
//    ≥ `minBeats` retained samples, sample span ≥ `minSpanForHFSec` (60 s) and a cleaning-rejection
//    fraction ≤ `maxWindowRejectedFraction`. Span ≥ `minSpanForLFSec` (250 s) makes it a FULL window
//    (LF, LF/HF, total power); 60–250 s gives HF only. The existing band edges and span gates are kept
//    and now apply PER WINDOW.
//
// 5. COMBINATION. When at least one full window exists, band powers are the span-weighted mean over the
//    FULL windows only (spans 250–300 s, comparable lengths) — the Bartlett/Welch principle of averaging
//    the spectra of equal-length segments, which reduces the periodogram's variance without mixing
//    resolutions; LF/HF is the ratio of those averaged band powers (never a mean of ratios). Short
//    windows are then ignored, never mixed in. With no full window, the single LONGEST short window gives
//    HF only (short windows differ in length and resolution, so they are not averaged).
//
// Band integrals use the trapezoid rule on a uniform grid of step ≤ 1/(`gridOversampling` · window span)
// (and ≤ `freqStepHz`), so a narrow spectral line is sampled ≥ 5 times per main lobe. The grid is
// evaluated with the Press & Rybicki trigonometric recurrence (re-seeded every 64 steps), so a whole
// day's beats cost multiply-adds, not transcendental calls.
//
// TASK FORCE (1996) BANDS: VLF 0.0033–0.04 Hz (folded into total power only), LF 0.04–0.15 Hz,
// HF 0.15–0.40 Hz. Mean removal only, no detrending (as in v1). APPROXIMATE, non-clinical.
// Kotlin twin: android/.../analytics/HrvFreqDomain.kt.

public enum HRVFreqDomain {

    // MARK: - Band edges (Hz), span gates (s) and window rules, mirrored in the Kotlin twin.

    /// VLF lower edge (Hz). Folded into total power; not reported alone.
    public static let vlfLowHz: Double = 0.0033
    /// LF band: [0.04, 0.15] Hz.
    public static let lfLowHz: Double = 0.04
    public static let lfHighHz: Double = 0.15
    /// HF band: [0.15, 0.40] Hz.
    public static let hfLowHz: Double = 0.15
    public static let hfHighHz: Double = 0.40

    /// Minimum sample span (s) of a window before it yields anything (HF needs at least this).
    public static let minSpanForHFSec: Double = 60.0
    /// Minimum sample span (s) before a window's LF band (and LF/HF, total power) is trusted.
    public static let minSpanForLFSec: Double = 250.0

    /// Minimum retained (clean) samples a window needs.
    public static let minBeats: Int = 20

    /// Upper bound on the frequency-grid step (Hz); the actual step is also ≤ 1/(oversampling·span).
    public static let freqStepHz: Double = 0.005
    /// Grid points per spectral main lobe (1/span); VanderPlas 2018 (ApJS 236:16) recommends 5–10.
    public static let gridOversampling: Double = 5.0

    /// Analysis window length (s): the Task Force short-term recording length.
    public static let analysisWindowSec: Double = 300.0
    /// Slack (s) on each whole-second timestamp constraint (absorbs ms rounding of the intervals and
    /// record-boundary jitter). On the real WHOOP 5 night above, 0.25 s keeps ~90% of beats in runs of
    /// ≥ 60 beats, while a dropped ~1 s beat still breaks the run.
    public static let timingSlackSec: Double = 0.25
    /// A stretch of cleaning-removed samples longer than this (s, between the retained samples on
    /// either side) is a discontinuity: the run splits there. Shorter stretches stay missing samples.
    public static let maxMissingSampleGapSec: Double = 3.0
    /// A window whose cleaning rejected more than this fraction of its beats does not qualify
    /// (Clifford & Tarassenko 2005: Lomb–Scargle with removed beats stays accurate to ~20% removal).
    public static let maxWindowRejectedFraction: Double = 0.20
    /// Backward search bound (beats) when locating where a broken run's ambiguity starts.
    static let ambiguityScanLimit: Int = 64

    /// Method/definition version carried with every result.
    public static let method = "lomb_scargle_psd_ms2_v2"
    /// Unit of every band power.
    public static let powerUnit = "ms²"
    /// The interval source label.
    public static let source = "prv_optical"

    // MARK: - Result

    /// Which windows the band powers come from.
    public enum Tier: String, Equatable, Sendable {
        /// Span-weighted mean over full (≥ 250 s) windows: LF, HF, LF/HF and total power.
        case fullWindows = "full_windows"
        /// No full window: HF from the single longest 60–250 s window; LF / LF-HF nil.
        case shortWindowHFOnly = "short_window_hf_only"
    }

    /// Frequency-domain PRV. All powers are absolute band powers in ms² (integrals of a one-sided PSD in
    /// ms²/Hz). `lf` / `lfhf` are nil on the `.shortWindowHFOnly` tier.
    public struct Bands: Equatable, Sendable {
        /// LF band power (0.04–0.15 Hz), ms². nil without a full window.
        public let lf: Double?
        /// HF band power (0.15–0.40 Hz), ms².
        public let hf: Double
        /// LF / HF (dimensionless): the ratio of the averaged band powers. nil when LF is nil or HF == 0.
        public let lfhf: Double?
        /// VLF+LF+HF (0.0033–0.40 Hz), ms², on full windows; equals `hf` on the short tier (never a
        /// misleading partial sum).
        public let totalPower: Double
        public let tier: Tier
        /// Windows the powers were combined from.
        public let windowCount: Int
        /// Σ sample span of those windows (s).
        public let usedSpanSec: Double
        /// Σ retained samples in those windows.
        public let usedBeats: Int
        /// Wall-clock span of the input (last − first timestamp, s).
        public let observedSpanSec: Double
        /// `usedSpanSec / observedSpanSec` (0…1); nil when the observed span is 0.
        public let coverageFraction: Double?
        /// Cleaning-rejected beats ÷ beats inside the used windows.
        public let rejectedFraction: Double
        public let method: String
        public let unit: String
        public let source: String

        public init(lf: Double?, hf: Double, lfhf: Double?, totalPower: Double,
                    tier: Tier = .fullWindows, windowCount: Int = 0, usedSpanSec: Double = 0,
                    usedBeats: Int = 0, observedSpanSec: Double = 0, coverageFraction: Double? = nil,
                    rejectedFraction: Double = 0) {
            self.lf = lf; self.hf = hf; self.lfhf = lfhf; self.totalPower = totalPower
            self.tier = tier; self.windowCount = windowCount; self.usedSpanSec = usedSpanSec
            self.usedBeats = usedBeats; self.observedSpanSec = observedSpanSec
            self.coverageFraction = coverageFraction; self.rejectedFraction = rejectedFraction
            self.method = HRVFreqDomain.method; self.unit = HRVFreqDomain.powerUnit
            self.source = HRVFreqDomain.source
        }
    }

    /// Why no band power was produced (machine-readable; the screen maps it to wording).
    public enum UnavailableReason: String, Equatable, Sendable {
        /// No R-R intervals at all.
        case noIntervals = "no_rr_intervals"
        /// No contiguous stretch of ≥ 60 s with ≥ 20 retained beats (gaps, dropped beats or timing
        /// that disagrees with the intervals broke every stretch).
        case noContiguousWindow = "no_contiguous_window"
        /// Contiguous stretches exist, but cleaning rejected too many beats in every one of them.
        case rejectedFractionTooHigh = "rejected_fraction_too_high"
    }

    /// Segmentation diagnostics (what the input looked like and why windows were lost).
    public struct Diagnostics: Equatable, Sendable {
        public var inputBeats = 0
        /// Exact retransmissions removed by observation identity.
        public var duplicatesRemoved = 0
        /// Contiguous timing runs found (before cleaning splits).
        public var timingRuns = 0
        /// Run breaks caused by timestamps that disagree with the intervals (gaps, dropped beats).
        public var timingBreaks = 0
        /// Run breaks caused by a source-channel change.
        public var channelBreaks = 0
        /// Beats excluded because their run membership was ambiguous at a break.
        public var ambiguousBeats = 0
        /// Splits caused by a cleaning-removed stretch longer than `maxMissingSampleGapSec`.
        public var cleaningSplits = 0
        public var windowsEvaluated = 0
        public var windowsRejectedByCleaning = 0
        public var fullWindows = 0
        public var shortWindows = 0
        public init() {}
    }

    /// The full outcome: bands when available, else a reason; diagnostics either way.
    public struct Outcome: Equatable, Sendable {
        public let bands: Bands?
        public let unavailableReason: UnavailableReason?
        public let diagnostics: Diagnostics
    }

    // MARK: - Public API

    /// Frequency-domain PRV from timestamped R-R intervals (the app's only entry point). See the file
    /// header for the timing, discontinuity, normalization and window rules.
    public static func analyze(rr: [RRInterval]) -> Outcome {
        var diag = Diagnostics()
        diag.inputBeats = rr.count
        guard !rr.isEmpty else {
            return Outcome(bands: nil, unavailableReason: .noIntervals, diagnostics: diag)
        }
        // Stable by second: same-second beats keep their emission order (#823); then exact
        // retransmissions collapse by observation identity (never by RR value).
        let ordered = SleepAnalyticsPrv.dedupByObservationIdentity(rr.sortedByTsStable())
        diag.duplicatesRemoved = rr.count - ordered.count
        let observedSpan = Double((ordered.last?.ts ?? 0) - (ordered.first?.ts ?? 0))

        let runs = timingRuns(ordered, diagnostics: &diag)
        var windows: [WindowPower] = []
        for run in runs {
            windows += windowsOf(values: run.map { Double($0.rrMs) }, diagnostics: &diag)
        }
        return combine(windows, observedSpanSec: observedSpan, diagnostics: diag)
    }

    /// Convenience: the bands of `analyze(rr:)`, nil when unavailable.
    public static func freqDomain(rr: [RRInterval]) -> Bands? {
        analyze(rr: rr).bands
    }

    /// REFERENCE-ONLY entry for an untimestamped series that is KNOWN to be one gapless recording (an
    /// ECG-derived NN fixture). It ASSUMES CONTIGUITY: with no timestamps a missing beat or a recording
    /// gap cannot be detected, so the app never calls this (`analyze(rr:)` is the app path). Timing is the
    /// cumulative sum of ALL raw intervals (removed beats keep their elapsed time); everything else —
    /// cleaning splits, windows, normalization, combination — is identical.
    public static func analyze(assumingContiguousRR rawRR: [Double]) -> Outcome {
        var diag = Diagnostics()
        diag.inputBeats = rawRR.count
        guard !rawRR.isEmpty else {
            return Outcome(bands: nil, unavailableReason: .noIntervals, diagnostics: diag)
        }
        diag.timingRuns = 1
        let windows = windowsOf(values: rawRR, diagnostics: &diag)
        let span = rawRR.dropFirst().reduce(0, +) / 1000.0
        return combine(windows, observedSpanSec: span, diagnostics: diag)
    }

    // MARK: - Timing runs

    /// Split the ordered, deduplicated beats into runs whose whole-second timestamps are jointly
    /// consistent with interval-END timing: ∃θ with ts_k − slack ≤ θ + T_k < ts_k + 1 + slack for every
    /// beat k of the run, T_k the cumulative interval sum. On a break, beats consistent with BOTH the old
    /// and the new timing are ambiguous and excluded from both runs.
    static func timingRuns(_ beats: [RRInterval], diagnostics diag: inout Diagnostics) -> [[RRInterval]] {
        var runs: [[RRInterval]] = []
        guard !beats.isEmpty else { return runs }
        let slack = timingSlackSec
        var runStart = 0
        var lo = 0.0, hi = 0.0
        var cum = 0.0                           // Σ rr (s) over the current run, through the current beat

        func close(_ end: Int) {                // half-open [runStart, end)
            if end > runStart { runs.append(Array(beats[runStart..<end])) }
        }
        func restart(at k: Int) {
            runStart = k
            cum = Double(beats[k].rrMs) / 1000.0
            lo = Double(beats[k].ts) - cum - slack
            hi = Double(beats[k].ts) + 1.0 - cum + slack
        }
        restart(at: 0)
        var k = 1
        while k < beats.count {
            let b = beats[k]
            if b.srcChannel != beats[runStart].srcChannel {
                diag.channelBreaks += 1
                close(k)
                restart(at: k)
                k += 1
                continue
            }
            let c = cum + Double(b.rrMs) / 1000.0
            let nlo = max(lo, Double(b.ts) - c - slack)
            let nhi = min(hi, Double(b.ts) + 1.0 - c + slack)
            if nlo <= nhi {
                lo = nlo; hi = nhi; cum = c
                k += 1
                continue
            }
            // Infeasible at k. Find the earliest j (> runStart) such that beats j…k are jointly feasible:
            // the beats in [j, k) fit both timings, so their membership is ambiguous.
            diag.timingBreaks += 1
            var blo = -Double.infinity, bhi = Double.infinity
            var e = 0.0                         // end time of beat i relative to beat k's end (s)
            var j = k
            var i = k
            let lowest = max(runStart + 1, k - ambiguityScanLimit)
            while i >= lowest {
                let tsI = Double(beats[i].ts)
                let ilo = max(blo, tsI - e - slack)
                let ihi = min(bhi, tsI + 1.0 - e + slack)
                if ilo > ihi { break }
                blo = ilo; bhi = ihi; j = i
                e -= Double(beats[i].rrMs) / 1000.0
                i -= 1
            }
            diag.ambiguousBeats += k - j
            close(j)
            restart(at: k)
            k += 1
        }
        close(beats.count)
        diag.timingRuns += runs.count
        return runs
    }

    // MARK: - Cleaning splits and windows

    struct WindowPower {
        let span: Double
        let beats: Int
        let rawBeats: Int
        let rejected: Int
        let hf: Double
        let lf: Double?
        let vlf: Double?
        var full: Bool { lf != nil }
    }

    /// One qualified window's retained samples: `t` = true interval-END times (s, relative to the run's
    /// first interval end), `rr` = the cleaned interval values (ms).
    struct WindowSamples {
        let t: [Double]
        let rr: [Double]
        let rawBeats: Int
        let rejected: Int
    }

    /// One contiguous run's raw interval values (ms, original order) → its qualified windows' powers.
    static func windowsOf(values: [Double], diagnostics diag: inout Diagnostics) -> [WindowPower] {
        qualifiedWindows(values: values, diagnostics: &diag).map {
            windowPower(t: $0.t, rr: $0.rr, rawBeats: $0.rawBeats, rejected: $0.rejected)
        }
    }

    /// One contiguous run's raw interval values → the samples of its qualified windows (file header §1,
    /// §2 cleaning splits, §4 gates).
    static func qualifiedWindows(values: [Double], diagnostics diag: inout Diagnostics) -> [WindowSamples] {
        guard !values.isEmpty else { return [] }
        // End time (s) of every raw interval, relative to the run's first interval end; removed beats
        // keep their elapsed time.
        var endTime = [Double](repeating: 0, count: values.count)
        var acc = 0.0
        if values.count > 1 {
            for i in 1..<values.count { acc += values[i] / 1000.0; endTime[i] = acc }
        }

        let cleaned = HRVAnalyzer.cleanRRGapAware(values)
        let kept = cleaned.keptOriginalIndices
        guard !kept.isEmpty else { return [] }

        // Split at removed stretches longer than the allowed missing-sample gap. A segment covers the
        // ORIGINAL indices [lo, hi] and the kept positions [keptLo, keptHi]; removed beats inside it stay
        // missing samples at their true times.
        var segments: [(lo: Int, hi: Int, keptLo: Int, keptHi: Int)] = []
        var segStart = 0
        if kept.count > 1 {
            for m in 1..<kept.count where endTime[kept[m]] - endTime[kept[m - 1]] > maxMissingSampleGapSec {
                diag.cleaningSplits += 1
                segments.append((kept[segStart], kept[m - 1], segStart, m - 1))
                segStart = m
            }
        }
        segments.append((kept[segStart], kept[kept.count - 1], segStart, kept.count - 1))

        var out: [WindowSamples] = []
        for seg in segments {
            let t0 = endTime[seg.lo]
            var keptIdx = seg.keptLo
            var rawIdx = seg.lo
            var w = 0
            while true {
                let wStart = t0 + Double(w) * analysisWindowSec
                let wEnd = wStart + analysisWindowSec
                guard wStart <= endTime[seg.hi] else { break }
                var t: [Double] = [], y: [Double] = []
                while keptIdx <= seg.keptHi, endTime[kept[keptIdx]] < wEnd {
                    t.append(endTime[kept[keptIdx]]); y.append(cleaned.nn[keptIdx]); keptIdx += 1
                }
                var raw = 0
                while rawIdx <= seg.hi, endTime[rawIdx] < wEnd { raw += 1; rawIdx += 1 }
                w += 1
                diag.windowsEvaluated += 1
                guard t.count >= minBeats, let first = t.first, let last = t.last,
                      last - first >= minSpanForHFSec else { continue }
                let rejected = raw - t.count
                if Double(rejected) / Double(max(raw, 1)) > maxWindowRejectedFraction {
                    diag.windowsRejectedByCleaning += 1
                    continue
                }
                out.append(WindowSamples(t: t, rr: y, rawBeats: raw, rejected: rejected))
            }
        }
        return out
    }

    /// Band powers of one qualified window (absolute, ms²).
    static func windowPower(t: [Double], rr: [Double], rawBeats: Int, rejected: Int) -> WindowPower {
        let t0 = t[0]
        let rel = t.map { $0 - t0 }
        let mean = rr.reduce(0, +) / Double(rr.count)
        let y = rr.map { $0 - mean }
        let span = rel[rel.count - 1]
        let step = min(freqStepHz, 1.0 / (gridOversampling * span))
        let dtMean = span / Double(rel.count - 1)
        let hf = bandPower(times: rel, y: y, fLow: hfLowHz, fHigh: hfHighHz, maxStep: step, dtMean: dtMean)
        var lf: Double? = nil, vlf: Double? = nil
        if span >= minSpanForLFSec {
            lf = bandPower(times: rel, y: y, fLow: lfLowHz, fHigh: lfHighHz, maxStep: step, dtMean: dtMean)
            vlf = bandPower(times: rel, y: y, fLow: vlfLowHz, fHigh: lfLowHz, maxStep: step, dtMean: dtMean)
        }
        return WindowPower(span: span, beats: rel.count, rawBeats: rawBeats, rejected: rejected,
                           hf: hf, lf: lf, vlf: vlf)
    }

    /// Combine qualified windows (file header §5).
    static func combine(_ windows: [WindowPower], observedSpanSec: Double,
                        diagnostics: Diagnostics) -> Outcome {
        var diag = diagnostics
        let full = windows.filter(\.full)
        diag.fullWindows = full.count
        diag.shortWindows = windows.count - full.count
        let chosen: [WindowPower]
        let tier: Tier
        if !full.isEmpty {
            chosen = full; tier = .fullWindows
        } else if let longest = windows.max(by: { $0.span < $1.span }) {
            chosen = [longest]; tier = .shortWindowHFOnly
        } else {
            let reason: UnavailableReason = diag.windowsRejectedByCleaning > 0
                ? .rejectedFractionTooHigh : .noContiguousWindow
            return Outcome(bands: nil, unavailableReason: reason, diagnostics: diag)
        }
        let weight = chosen.reduce(0) { $0 + $1.span }
        func weighted(_ value: (WindowPower) -> Double) -> Double {
            chosen.reduce(0) { $0 + $1.span * value($1) } / weight
        }
        let hf = weighted { $0.hf }
        let lf: Double? = tier == .fullWindows ? weighted { $0.lf ?? 0 } : nil
        let vlf: Double? = tier == .fullWindows ? weighted { $0.vlf ?? 0 } : nil
        var lfhf: Double? = nil
        if let lf, hf > 0 { lfhf = lf / hf }
        let total = (lf ?? 0) + (vlf ?? 0) + hf
        let raw = chosen.reduce(0) { $0 + $1.rawBeats }
        let rejected = chosen.reduce(0) { $0 + $1.rejected }
        let bands = Bands(lf: lf, hf: hf, lfhf: lfhf, totalPower: total, tier: tier,
                          windowCount: chosen.count, usedSpanSec: weight,
                          usedBeats: chosen.reduce(0) { $0 + $1.beats },
                          observedSpanSec: observedSpanSec,
                          coverageFraction: observedSpanSec > 0 ? min(1, weight / observedSpanSec) : nil,
                          rejectedFraction: raw > 0 ? Double(rejected) / Double(raw) : 0)
        return Outcome(bands: bands, unavailableReason: nil, diagnostics: diag)
    }

    // MARK: - Lomb–Scargle PSD band integral

    /// ∫_{fLow}^{fHigh} S(f) df (ms²), S = 2·Δt̄·P the one-sided absolute PSD (file header §3), by the
    /// trapezoid rule on a uniform grid of step ≤ `maxStep`. `times` are seconds (any origin), `y` the
    /// mean-removed samples (ms).
    static func bandPower(times: [Double], y: [Double], fLow: Double, fHigh: Double,
                          maxStep: Double, dtMean: Double) -> Double {
        guard fHigh > fLow, times.count >= 2, dtMean > 0, maxStep > 0 else { return 0 }
        let steps = max(1, Int(((fHigh - fLow) / maxStep - 1e-9).rounded(.up)))
        let df = (fHigh - fLow) / Double(steps)
        let n = times.count
        var c = [Double](repeating: 0, count: n)
        var s = c, dc = c, ds = c
        let dw = 2.0 * Double.pi * df
        for i in 0..<n { dc[i] = cos(dw * times[i]); ds[i] = sin(dw * times[i]) }
        var integral = 0.0
        var prev = 0.0
        for k in 0...steps {
            if k % 64 == 0 {                    // re-seed: bounds the recurrence's rounding drift
                let w = 2.0 * Double.pi * (fLow + Double(k) * df)
                for i in 0..<n { c[i] = cos(w * times[i]); s[i] = sin(w * times[i]) }
            }
            let p = periodogram(c: c, s: s, y: y)
            if k > 0 { integral += 0.5 * (p + prev) * df }
            prev = p
            // Rotate every sample's phase by 2π·df·t_i (Press & Rybicki trigonometric recurrence).
            for i in 0..<n {
                let cn = c[i] * dc[i] - s[i] * ds[i]
                s[i] = s[i] * dc[i] + c[i] * ds[i]
                c[i] = cn
            }
        }
        return 2.0 * dtMean * integral
    }

    /// Classical Lomb–Scargle P(f) (ms²) from the phases c_i = cos ωt_i, s_i = sin ωt_i, using Scargle's
    /// τ: tan 2ωτ = Σ sin 2ωt / Σ cos 2ωt = 2·Σcs / (Σc² − Σs²).
    static func periodogram(c: [Double], s: [Double], y: [Double]) -> Double {
        var yc = 0.0, ys = 0.0, cc = 0.0, ss = 0.0, cs = 0.0
        for i in 0..<y.count {
            yc += y[i] * c[i]; ys += y[i] * s[i]
            cc += c[i] * c[i]; ss += s[i] * s[i]; cs += c[i] * s[i]
        }
        let phi = 0.5 * atan2(2.0 * cs, cc - ss)
        let cp = cos(phi), sp = sin(phi)
        let ycT = yc * cp + ys * sp
        let ysT = ys * cp - yc * sp
        let ccT = cc * cp * cp + 2.0 * cs * cp * sp + ss * sp * sp
        let ssT = ss * cp * cp - 2.0 * cs * cp * sp + cc * sp * sp
        let tiny = 1e-12 * Double(y.count)
        let a = ccT > tiny ? ycT * ycT / ccT : 0
        let b = ssT > tiny ? ysT * ysT / ssT : 0
        return 0.5 * (a + b)
    }
}
