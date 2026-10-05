package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The settled-onset rule: lying awake in bed before the wrist settles is wake, however still and low-HR it
 * was. Android twin of the Swift `SleepStagerV2SettledOnsetTests`.
 */
class SleepStagerV2SettledOnsetTest {

    private val dev = "test"
    private val start = 1_791_190_077L

    /** A wrist that holds still between brief repositionings every [everyMin] minutes (4 s each). */
    private fun gravity(from: Long, durationS: Int, everyMin: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val minute = i / 60
            val shifting = minute > 0 && minute % everyMin == 0 && (i % 60) < 4
            if (shifting) GravitySample(deviceId = dev, ts = from + i, x = 0.35, y = 0.30, z = 0.87)
            else GravitySample(deviceId = dev, ts = from + i, x = 0.0, y = 0.0, z = 1.0)
        }

    private fun heartRate(from: Long, durationS: Int, base: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = from + it, bpm = base + (it / 90) % 3) }

    private fun asleepMinutes(segs: List<StageSegment>): Double =
        segs.filter { it.stage != "wake" }.sumOf { (it.end - it.start).toDouble() } / 60.0

    @Test
    fun onsetIsFirstSleepLabelOnceTheWristSettles() {
        val w = SleepStagerV2.settledOnsetEpochs
        val settled = (0 until 40 + w).map { it >= 40 || it % 4 != 0 }
        assertEquals(33, SleepStagerV2.settledOnset(settled, List(settled.size) { "light" }))
    }

    @Test
    fun oneStirInsideTheRunStillSettles() {
        val w = SleepStagerV2.settledOnsetEpochs
        val settled = MutableList(w + 10) { true }.also { it[5] = false }
        val labels = listOf("awake", "awake") + List(w + 8) { "light" }
        assertEquals(2, SleepStagerV2.settledOnset(settled, labels))
    }

    @Test
    fun wristThatNeverSettlesLeavesTheNightAlone() {
        val w = SleepStagerV2.settledOnsetEpochs
        val settled = (0 until 4 * w).map { it % 8 != 0 }
        assertNull(SleepStagerV2.settledOnset(settled, List(settled.size) { "light" }))
    }

    /** An hour lying awake (still, 64 bpm, shifting every 5 min), then five hours of settled sleep. */
    @Test
    fun lyingAwakeBeforeSettlingIsStagedWake() {
        val awakeS = 60 * 60; val sleepS = 5 * 60 * 60
        val settleTs = start + awakeS
        val segs = SleepStagerV2.stageSession(
            start, settleTs + sleepS,
            gravity(start, awakeS, everyMin = 5) + gravity(settleTs, sleepS, everyMin = 90),
            heartRate(start, awakeS, base = 64) + heartRate(settleTs, sleepS, base = 58),
            emptyList(), emptyList())
        val onset = segs.first { it.stage != "wake" }.start
        // The awake hour's last shift is at minute 55; the wrist is settled from 55:04.
        assertTrue("no sleep before the wrist settles (onset $onset)", onset >= start + 55 * 60 + 4)
        assertTrue("sleep starts soon after it settles", onset <= settleTs + 5 * 60)
        assertTrue("the settled five hours still stage as sleep", asleepMinutes(segs) > 4 * 60)
    }
}
