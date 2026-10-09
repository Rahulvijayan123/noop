package com.noop.analytics

import com.noop.data.RrInterval
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/*
 * HrvFreqDomain.kt, frequency-domain pulse-rate variability (LF / HF / LF-HF / total power).
 *
 * Twin of StrandAnalytics/HRVFreqDomain.swift (spec-02 §1 correctness repair, method
 * `lomb_scargle_psd_ms2_v2`); read the Swift file header for the full derivation and citations. PURELY
 * ADDITIVE: no Charge / Effort / Rest / sleep output reads this; the time-domain HrvAnalyzer is called,
 * never modified. Optical pulse intervals: pulse-rate variability (`prv_optical`), not ECG HRV, and not a
 * measure of sympathetic / parasympathetic tone.
 *
 * 1. True interval-END timing: inside a contiguous run, t_k = Σ_{j<=k} rr_j over ALL raw intervals, so a
 *    cleaning-removed beat leaves its sample missing at its true time.
 * 2. Discontinuities split, never bridge: a run continues only while one offset θ satisfies every beat's
 *    whole-second timestamp constraint ts_k - slack <= θ + T_k < ts_k + 1 + slack; a source-channel change
 *    also breaks it; ambiguous beats at a break are excluded; exact retransmissions are deduplicated by
 *    observation identity; a cleaning-removed stretch longer than 3 s splits the run.
 * 3. Absolute PSD: S(f) = 2·Δt̄·P(f) [ms²/Hz] with P the classical Lomb–Scargle periodogram (Scargle 1982
 *    τ form, = scipy.signal.lombscargle normalize=False) and Δt̄ the mean sampling interval, so band
 *    integrals are ms² (a sinusoid of amplitude A ms integrates to A²/2).
 * 4. Windows: 300 s tiles of each split segment; >= 20 retained samples, span >= 60 s (HF) / >= 250 s
 *    (full: LF, LF/HF, total power), cleaning-rejection fraction <= 20%.
 * 5. Combination: span-weighted mean over FULL windows only (Bartlett/Welch); LF/HF = ratio of the
 *    averaged powers. Without a full window, HF only from the single longest short window.
 *
 * Task Force (1996) bands: VLF 0.0033–0.04 (total power only), LF 0.04–0.15, HF 0.15–0.40 Hz.
 * APPROXIMATE, non-clinical.
 */
object HrvFreqDomain {

    // ── Band edges (Hz), span gates (s) and window rules, mirror the Swift twin ──
    const val VLF_LOW_HZ: Double = 0.0033
    const val LF_LOW_HZ: Double = 0.04
    const val LF_HIGH_HZ: Double = 0.15
    const val HF_LOW_HZ: Double = 0.15
    const val HF_HIGH_HZ: Double = 0.40

    const val MIN_SPAN_FOR_HF_SEC: Double = 60.0
    const val MIN_SPAN_FOR_LF_SEC: Double = 250.0

    const val MIN_BEATS: Int = 20
    const val FREQ_STEP_HZ: Double = 0.005
    const val GRID_OVERSAMPLING: Double = 5.0
    const val ANALYSIS_WINDOW_SEC: Double = 300.0
    const val TIMING_SLACK_SEC: Double = 0.25
    const val MAX_MISSING_SAMPLE_GAP_SEC: Double = 3.0
    const val MAX_WINDOW_REJECTED_FRACTION: Double = 0.20
    internal const val AMBIGUITY_SCAN_LIMIT: Int = 64

    const val METHOD: String = "lomb_scargle_psd_ms2_v2"
    const val POWER_UNIT: String = "ms²"
    const val SOURCE: String = "prv_optical"

    enum class Tier(val wire: String) { FULL_WINDOWS("full_windows"), SHORT_WINDOW_HF_ONLY("short_window_hf_only") }

    enum class UnavailableReason(val wire: String) {
        NO_INTERVALS("no_rr_intervals"),
        NO_CONTIGUOUS_WINDOW("no_contiguous_window"),
        REJECTED_FRACTION_TOO_HIGH("rejected_fraction_too_high"),
    }

    /** Absolute band powers (ms²). [lf] / [lfhf] are null on the short tier. */
    data class Bands(
        val lf: Double?,
        val hf: Double,
        val lfhf: Double?,
        val totalPower: Double,
        val tier: Tier = Tier.FULL_WINDOWS,
        val windowCount: Int = 0,
        val usedSpanSec: Double = 0.0,
        val usedBeats: Int = 0,
        val observedSpanSec: Double = 0.0,
        val coverageFraction: Double? = null,
        val rejectedFraction: Double = 0.0,
        val method: String = METHOD,
        val unit: String = POWER_UNIT,
        val source: String = SOURCE,
    )

    data class Diagnostics(
        var inputBeats: Int = 0,
        var duplicatesRemoved: Int = 0,
        var timingRuns: Int = 0,
        var timingBreaks: Int = 0,
        var channelBreaks: Int = 0,
        var ambiguousBeats: Int = 0,
        var cleaningSplits: Int = 0,
        var windowsEvaluated: Int = 0,
        var windowsRejectedByCleaning: Int = 0,
        var fullWindows: Int = 0,
        var shortWindows: Int = 0,
    )

    data class Outcome(val bands: Bands?, val unavailableReason: UnavailableReason?, val diagnostics: Diagnostics)

    // ── Public API ──

    /** Frequency-domain PRV from timestamped R-R intervals (the app's only entry point). */
    fun analyze(rr: List<RrInterval>): Outcome {
        val diag = Diagnostics(inputBeats = rr.size)
        if (rr.isEmpty()) return Outcome(null, UnavailableReason.NO_INTERVALS, diag)
        // Stable by second (same-second emission order kept), then exact retransmissions collapse by
        // observation identity (second|rr|seq|ord|channel), never by RR value. Mirrors
        // SleepAnalyticsPrv.dedupByObservationIdentity on iOS.
        val seen = HashSet<String>()
        val ordered = rr.sortedBy { it.ts }.filter { b ->
            seen.add("${b.ts}|${b.rrMs}|${b.seq}|${b.ord ?: "-"}|${b.srcChannel ?: "-"}")
        }
        diag.duplicatesRemoved = rr.size - ordered.size
        val observedSpan = (ordered.last().ts - ordered.first().ts).toDouble()
        val windows = ArrayList<WindowPower>()
        for (run in timingRuns(ordered, diag)) {
            windows += windowsOf(run.map { it.rrMs.toDouble() }, diag)
        }
        return combine(windows, observedSpan, diag)
    }

    /** Convenience: the bands of [analyze], null when unavailable. */
    fun freqDomain(rr: List<RrInterval>): Bands? = analyze(rr).bands

    /**
     * REFERENCE-ONLY: an untimestamped series KNOWN to be one gapless recording (an ECG NN fixture). It
     * ASSUMES CONTIGUITY (a missing beat or gap cannot be detected without timestamps), so the app never
     * calls it. Timing = cumulative sum of ALL raw intervals; everything else is identical to [analyze].
     */
    fun analyzeAssumingContiguous(rawRR: List<Double>): Outcome {
        val diag = Diagnostics(inputBeats = rawRR.size)
        if (rawRR.isEmpty()) return Outcome(null, UnavailableReason.NO_INTERVALS, diag)
        diag.timingRuns = 1
        val windows = windowsOf(rawRR, diag)
        return combine(windows, rawRR.drop(1).sum() / 1000.0, diag)
    }

    // ── Timing runs ──

    internal fun timingRuns(beats: List<RrInterval>, diag: Diagnostics): List<List<RrInterval>> {
        val runs = ArrayList<List<RrInterval>>()
        if (beats.isEmpty()) return runs
        val slack = TIMING_SLACK_SEC
        var runStart = 0
        var lo = 0.0
        var hi = 0.0
        var cum = 0.0
        fun close(end: Int) { if (end > runStart) runs.add(beats.subList(runStart, end).toList()) }
        fun restart(k: Int) {
            runStart = k
            cum = beats[k].rrMs / 1000.0
            lo = beats[k].ts.toDouble() - cum - slack
            hi = beats[k].ts.toDouble() + 1.0 - cum + slack
        }
        restart(0)
        var k = 1
        while (k < beats.size) {
            val b = beats[k]
            if (b.srcChannel != beats[runStart].srcChannel) {
                diag.channelBreaks += 1
                close(k); restart(k); k += 1
                continue
            }
            val c = cum + b.rrMs / 1000.0
            val nlo = max(lo, b.ts.toDouble() - c - slack)
            val nhi = min(hi, b.ts.toDouble() + 1.0 - c + slack)
            if (nlo <= nhi) {
                lo = nlo; hi = nhi; cum = c; k += 1
                continue
            }
            diag.timingBreaks += 1
            var blo = Double.NEGATIVE_INFINITY
            var bhi = Double.POSITIVE_INFINITY
            var e = 0.0
            var j = k
            var i = k
            val lowest = max(runStart + 1, k - AMBIGUITY_SCAN_LIMIT)
            while (i >= lowest) {
                val tsI = beats[i].ts.toDouble()
                val ilo = max(blo, tsI - e - slack)
                val ihi = min(bhi, tsI + 1.0 - e + slack)
                if (ilo > ihi) break
                blo = ilo; bhi = ihi; j = i
                e -= beats[i].rrMs / 1000.0
                i -= 1
            }
            diag.ambiguousBeats += k - j
            close(j); restart(k); k += 1
        }
        close(beats.size)
        diag.timingRuns += runs.size
        return runs
    }

    // ── Cleaning splits and windows ──

    internal class WindowPower(
        val span: Double, val beats: Int, val rawBeats: Int, val rejected: Int,
        val hf: Double, val lf: Double?, val vlf: Double?,
    ) { val full: Boolean get() = lf != null }

    internal class WindowSamples(val t: DoubleArray, val rr: DoubleArray, val rawBeats: Int, val rejected: Int)

    internal fun windowsOf(values: List<Double>, diag: Diagnostics): List<WindowPower> =
        qualifiedWindows(values, diag).map { windowPower(it.t, it.rr, it.rawBeats, it.rejected) }

    internal fun qualifiedWindows(values: List<Double>, diag: Diagnostics): List<WindowSamples> {
        if (values.isEmpty()) return emptyList()
        val endTime = DoubleArray(values.size)
        var acc = 0.0
        for (i in 1 until values.size) { acc += values[i] / 1000.0; endTime[i] = acc }

        val cleaned = HrvAnalyzer.cleanRRGapAware(values)
        val kept = cleaned.keptOriginalIndices
        if (kept.isEmpty()) return emptyList()

        data class Segment(val lo: Int, val hi: Int, val keptLo: Int, val keptHi: Int)
        val segments = ArrayList<Segment>()
        var segStart = 0
        for (m in 1 until kept.size) {
            if (endTime[kept[m]] - endTime[kept[m - 1]] > MAX_MISSING_SAMPLE_GAP_SEC) {
                diag.cleaningSplits += 1
                segments.add(Segment(kept[segStart], kept[m - 1], segStart, m - 1))
                segStart = m
            }
        }
        segments.add(Segment(kept[segStart], kept[kept.size - 1], segStart, kept.size - 1))

        val out = ArrayList<WindowSamples>()
        for (seg in segments) {
            val t0 = endTime[seg.lo]
            var keptIdx = seg.keptLo
            var rawIdx = seg.lo
            var w = 0
            while (true) {
                val wStart = t0 + w * ANALYSIS_WINDOW_SEC
                val wEnd = wStart + ANALYSIS_WINDOW_SEC
                if (wStart > endTime[seg.hi]) break
                val t = ArrayList<Double>()
                val y = ArrayList<Double>()
                while (keptIdx <= seg.keptHi && endTime[kept[keptIdx]] < wEnd) {
                    t.add(endTime[kept[keptIdx]]); y.add(cleaned.nn[keptIdx]); keptIdx += 1
                }
                var raw = 0
                while (rawIdx <= seg.hi && endTime[rawIdx] < wEnd) { raw += 1; rawIdx += 1 }
                w += 1
                diag.windowsEvaluated += 1
                if (t.size < MIN_BEATS || t.last() - t.first() < MIN_SPAN_FOR_HF_SEC) continue
                val rejected = raw - t.size
                if (rejected.toDouble() / max(raw, 1).toDouble() > MAX_WINDOW_REJECTED_FRACTION) {
                    diag.windowsRejectedByCleaning += 1
                    continue
                }
                out.add(WindowSamples(t.toDoubleArray(), y.toDoubleArray(), raw, rejected))
            }
        }
        return out
    }

    internal fun windowPower(t: DoubleArray, rr: DoubleArray, rawBeats: Int, rejected: Int): WindowPower {
        val t0 = t[0]
        val rel = DoubleArray(t.size) { t[it] - t0 }
        val mean = rr.sum() / rr.size
        val y = DoubleArray(rr.size) { rr[it] - mean }
        val span = rel[rel.size - 1]
        val step = min(FREQ_STEP_HZ, 1.0 / (GRID_OVERSAMPLING * span))
        val dtMean = span / (rel.size - 1)
        val hf = bandPower(rel, y, HF_LOW_HZ, HF_HIGH_HZ, step, dtMean)
        var lf: Double? = null
        var vlf: Double? = null
        if (span >= MIN_SPAN_FOR_LF_SEC) {
            lf = bandPower(rel, y, LF_LOW_HZ, LF_HIGH_HZ, step, dtMean)
            vlf = bandPower(rel, y, VLF_LOW_HZ, LF_LOW_HZ, step, dtMean)
        }
        return WindowPower(span, rel.size, rawBeats, rejected, hf, lf, vlf)
    }

    internal fun combine(windows: List<WindowPower>, observedSpanSec: Double, diag: Diagnostics): Outcome {
        val full = windows.filter { it.full }
        diag.fullWindows = full.size
        diag.shortWindows = windows.size - full.size
        val chosen: List<WindowPower>
        val tier: Tier
        if (full.isNotEmpty()) {
            chosen = full; tier = Tier.FULL_WINDOWS
        } else {
            val longest = windows.maxByOrNull { it.span }
            if (longest == null) {
                val reason = if (diag.windowsRejectedByCleaning > 0) UnavailableReason.REJECTED_FRACTION_TOO_HIGH
                else UnavailableReason.NO_CONTIGUOUS_WINDOW
                return Outcome(null, reason, diag)
            }
            chosen = listOf(longest); tier = Tier.SHORT_WINDOW_HF_ONLY
        }
        val weight = chosen.sumOf { it.span }
        fun weighted(value: (WindowPower) -> Double): Double = chosen.sumOf { it.span * value(it) } / weight
        val hf = weighted { it.hf }
        val lf: Double? = if (tier == Tier.FULL_WINDOWS) weighted { it.lf ?: 0.0 } else null
        val vlf: Double? = if (tier == Tier.FULL_WINDOWS) weighted { it.vlf ?: 0.0 } else null
        val lfhf: Double? = if (lf != null && hf > 0) lf / hf else null
        val raw = chosen.sumOf { it.rawBeats }
        val rejected = chosen.sumOf { it.rejected }
        val bands = Bands(
            lf = lf, hf = hf, lfhf = lfhf, totalPower = (lf ?: 0.0) + (vlf ?: 0.0) + hf, tier = tier,
            windowCount = chosen.size, usedSpanSec = weight, usedBeats = chosen.sumOf { it.beats },
            observedSpanSec = observedSpanSec,
            coverageFraction = if (observedSpanSec > 0) min(1.0, weight / observedSpanSec) else null,
            rejectedFraction = if (raw > 0) rejected.toDouble() / raw else 0.0,
        )
        return Outcome(bands, null, diag)
    }

    // ── Lomb–Scargle PSD band integral ──

    /** ∫ S(f) df over [fLow, fHigh] (ms²), S = 2·Δt̄·P; trapezoid on a uniform grid of step <= maxStep. */
    internal fun bandPower(
        times: DoubleArray, y: DoubleArray, fLow: Double, fHigh: Double, maxStep: Double, dtMean: Double,
    ): Double {
        if (fHigh <= fLow || times.size < 2 || dtMean <= 0 || maxStep <= 0) return 0.0
        val steps = max(1, ceil((fHigh - fLow) / maxStep - 1e-9).toInt())
        val df = (fHigh - fLow) / steps
        val n = times.size
        val c = DoubleArray(n)
        val s = DoubleArray(n)
        val dw = 2.0 * PI * df
        val dc = DoubleArray(n) { cos(dw * times[it]) }
        val ds = DoubleArray(n) { sin(dw * times[it]) }
        var integral = 0.0
        var prev = 0.0
        for (k in 0..steps) {
            if (k % 64 == 0) {
                val w = 2.0 * PI * (fLow + k * df)
                for (i in 0 until n) { c[i] = cos(w * times[i]); s[i] = sin(w * times[i]) }
            }
            val p = periodogram(c, s, y)
            if (k > 0) integral += 0.5 * (p + prev) * df
            prev = p
            for (i in 0 until n) {
                val cn = c[i] * dc[i] - s[i] * ds[i]
                s[i] = s[i] * dc[i] + c[i] * ds[i]
                c[i] = cn
            }
        }
        return 2.0 * dtMean * integral
    }

    /** Classical Lomb–Scargle P(f) (ms²) with Scargle's τ: tan 2ωτ = 2·Σcs / (Σc² − Σs²). */
    internal fun periodogram(c: DoubleArray, s: DoubleArray, y: DoubleArray): Double {
        var yc = 0.0; var ys = 0.0; var cc = 0.0; var ss = 0.0; var cs = 0.0
        for (i in y.indices) {
            yc += y[i] * c[i]; ys += y[i] * s[i]
            cc += c[i] * c[i]; ss += s[i] * s[i]; cs += c[i] * s[i]
        }
        val phi = 0.5 * atan2(2.0 * cs, cc - ss)
        val cp = cos(phi)
        val sp = sin(phi)
        val ycT = yc * cp + ys * sp
        val ysT = ys * cp - yc * sp
        val ccT = cc * cp * cp + 2.0 * cs * cp * sp + ss * sp * sp
        val ssT = ss * cp * cp - 2.0 * cs * cp * sp + cc * sp * sp
        val tiny = 1e-12 * y.size
        val a = if (ccT > tiny) ycT * ycT / ccT else 0.0
        val b = if (ssT > tiny) ysT * ysT / ssT else 0.0
        return 0.5 * (a + b)
    }
}
