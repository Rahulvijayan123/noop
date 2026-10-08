package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.floor
import kotlin.math.sin

/**
 * Twin of HRVFreqDomainTests.swift (spec-02 §1 HF power repair, method lomb_scargle_psd_ms2_v2): absolute
 * ms² against the closed form (A²/2) and the scipy.signal.lombscargle reference values recorded in
 * docs/spec-02/notes/cardiac.md, fixed-timestamp amplitude doubling (4×), gaps retained, missing beats,
 * duplicates, invalid intervals, units. Same deterministic fixture as the Swift and Python references.
 */
class HrvFreqDomainTest {

    private val t0 = 1_790_000_000L

    private class Fixture(val beats: List<RrInterval>, val ends: List<Double>)

    private fun fixture(base: Double, amp: Double, f0: Double, duration: Double,
                        phaseT0: Double = 0.0, tsOffset: Long = 0L): Fixture {
        var t = 0.0
        val beats = ArrayList<RrInterval>()
        val ends = ArrayList<Double>()
        while (t < duration) {
            val rr = floor(base + amp * sin(2 * PI * f0 * (t + phaseT0)) + 0.5).toInt()
            t += rr / 1000.0
            beats.add(RrInterval(deviceId = "d", ts = t0 + tsOffset + floor(t).toLong(), rrMs = rr))
            ends.add(t)
        }
        return Fixture(beats, ends)
    }

    @Test
    fun hfSinusoidRecoveredWithAbsolutePower() {
        val b = HrvFreqDomain.analyze(fixture(900.0, 30.0, 0.25, 299.0).beats).bands
        assertNotNull(b)
        assertEquals(HrvFreqDomain.Tier.FULL_WINDOWS, b!!.tier)
        assertEquals(1, b.windowCount)
        assertEquals(450.0, b.hf, 4.5)                       // closed form A²/2
        assertEquals(448.612207270, b.hf, 448.612207270 * 1e-6) // scipy reference
        assertEquals(0.380885395, b.lf!!, 1e-5)
        assertEquals("ms²", b.unit)
        assertEquals("lomb_scargle_psd_ms2_v2", b.method)
        assertEquals("prv_optical", b.source)
    }

    @Test
    fun lfSinusoidRecoveredWithAbsolutePower() {
        val b = HrvFreqDomain.freqDomain(fixture(900.0, 30.0, 0.10, 299.0).beats)!!
        assertEquals(448.182016470, b.lf!!, 448.182016470 * 1e-6)
        assertEquals(1.131841221, b.hf, 1e-5)
    }

    @Test
    fun doublingAmplitudeAtFixedTimestampsQuadruplesPower() {
        val fx = fixture(900.0, 30.0, 0.25, 299.0)
        val t = DoubleArray(fx.ends.size) { fx.ends[it] - fx.ends[0] }
        val y = DoubleArray(t.size) { 30 * sin(2 * PI * 0.25 * t[it]) }
        val p1 = HrvFreqDomain.windowPower(t, DoubleArray(t.size) { 900 + y[it] }, t.size, 0)
        val p2 = HrvFreqDomain.windowPower(t, DoubleArray(t.size) { 900 + 2 * y[it] }, t.size, 0)
        assertEquals(4.0, p2.hf / p1.hf, 1e-9)
        assertEquals(448.1293897089, p1.hf, 448.13 * 1e-6)
    }

    @Test
    fun recordingGapIsRetainedNotBridged() {
        val a = fixture(900.0, 30.0, 0.25, 299.0)
        val b = fixture(900.0, 30.0, 0.25, 299.0, phaseT0 = 1.3, tsOffset = 420L)
        val out = HrvFreqDomain.analyze(a.beats + b.beats)
        assertEquals(1, out.diagnostics.timingBreaks)
        assertEquals(2, out.bands!!.windowCount)
        assertEquals(450.0, out.bands!!.hf, 9.0)
    }

    @Test
    fun levelShiftAcrossGapIsNotLowFrequencyPower() {
        val a = fixture(900.0, 30.0, 0.25, 150.0)
        val b = fixture(1100.0, 30.0, 0.25, 150.0, tsOffset = 1800L)
        val split = HrvFreqDomain.analyze(a.beats + b.beats).bands!!
        assertEquals(HrvFreqDomain.Tier.SHORT_WINDOW_HF_ONLY, split.tier)
        assertNull(split.lf)
        val bridged = HrvFreqDomain.analyzeAssumingContiguous((a.beats + b.beats).map { it.rrMs.toDouble() }).bands!!
        assertTrue(bridged.lf!! > 50.0)
    }

    @Test
    fun missingBeatRowSplitsTheRun() {
        val beats = fixture(900.0, 30.0, 0.25, 600.0).beats.toMutableList()
        beats.removeAt(330)
        val out = HrvFreqDomain.analyze(beats)
        assertEquals(1, out.diagnostics.timingBreaks)
        assertEquals(2, out.diagnostics.timingRuns)
        assertEquals(2, out.bands!!.windowCount)
    }

    @Test
    fun exactDuplicatesAreRemoved() {
        val fx = fixture(900.0, 30.0, 0.25, 299.0)
        val once = HrvFreqDomain.analyze(fx.beats).bands
        val twice = HrvFreqDomain.analyze(fx.beats + fx.beats)
        assertEquals(fx.beats.size, twice.diagnostics.duplicatesRemoved)
        assertEquals(once, twice.bands)
    }

    @Test
    fun unavailableReasons() {
        assertEquals(HrvFreqDomain.UnavailableReason.NO_INTERVALS, HrvFreqDomain.analyze(emptyList()).unavailableReason)
        val short = HrvFreqDomain.analyze(fixture(1000.0, 20.0, 0.25, 40.0).beats)
        assertNull(short.bands)
        assertEquals(HrvFreqDomain.UnavailableReason.NO_CONTIGUOUS_WINDOW, short.unavailableReason)
    }

    @Test
    fun shortSpanGivesHfOnly() {
        val b = HrvFreqDomain.freqDomain(fixture(900.0, 30.0, 0.25, 120.0).beats)!!
        assertEquals(HrvFreqDomain.Tier.SHORT_WINDOW_HF_ONLY, b.tier)
        assertNull(b.lf)
        assertNull(b.lfhf)
        assertEquals(b.hf, b.totalPower, 1e-12)
    }
}
