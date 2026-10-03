package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the shared windowed step kernel [StepsCounter.stepsInWindow] (#398). The same wrap-aware
 * positive-delta math the daily total uses (see StepsAnalyticsTest), but exercised directly and
 * order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
 * the caller's `stepTicksPerStep` calibration). Byte-for-byte twin of the Swift StepsCounterTests.
 */
class StepsCounterTest {

    private fun step(ts: Long, counter: Int, activityClass: Int? = null) =
        StepSample(deviceId = "my-whoop", ts = ts, counter = counter, activityClass = activityClass)

    @Test fun sumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(0, 100), step(60, 150), step(120, 220))))
    }

    @Test fun sortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(120, 220), step(0, 100), step(60, 150))))
    }

    @Test fun handlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) and 0xFFFF = 56; then 20 -> 80 => 60. Total 116.
        assertEquals(116, StepsCounter.stepsInWindow(listOf(step(0, 65_500), step(60, 20), step(120, 80))))
    }

    @Test fun fewerThanTwoSamplesIsNull() {
        assertNull(StepsCounter.stepsInWindow(emptyList()))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100))))
    }

    @Test fun noForwardMovementIsNull() {
        // Flat counter across the window => no positive delta => null (not 0).
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 500), step(60, 500), step(120, 500))))
    }

    @Test fun dropsBigGapDeltaAsBoundary() {
        // A jump >= 512 is dropped; the real 40 + 30 survive => 70.
        assertEquals(70, StepsCounter.stepsInWindow(
            listOf(step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030))))
    }

    @Test fun maxStepDeltaBoundaryIsExclusive() {
        // Exactly MAX_STEP_DELTA (512) is dropped; 511 counts.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 0), step(128, 512))))
        assertEquals(511, StepsCounter.stepsInWindow(listOf(step(0, 0), step(128, 511))))
    }

    @Test fun rejectsBurstsThatAreNeitherGaitNorABoutBlock() {
        // Four ticks a second is the gait ceiling and six ticks is the smallest block the strap credits, so
        // five in one second is neither; twenty-one is above the largest block we accept.
        assertEquals(4, StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 104))))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 105))))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 121))))
        // The same seven ticks spread over time stay recoverable.
        assertEquals(7, StepsCounter.stepsInWindow(listOf(step(0, 100), step(2, 107))))
    }

    @Test fun boutBlockBoundsAreInclusive() {
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 105, 0))))
        assertEquals(6, StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 106, 0))))
        assertEquals(20, StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 120, 0))))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 121, 0))))
    }

    @Test fun boutBlockCountsWhateverItsLabelOnAClassedDay() {
        // A block of exactly six is always labelled still: the label flips to walk on the seventh step.
        assertEquals(6, StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 106, 0))))
        assertEquals(7, StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 107, 1))))
        // One missing 1 Hz record is tolerated; three seconds is no longer a block and the label decides.
        assertEquals(6, StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(2, 106, 0))))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(3, 106, 0))))
        // Small still-labelled increments are not blocks and stay rejected.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 102, 0))))
    }

    @Test fun unlabelledBlockOnAClassedDayIsStillRejected() {
        // Unknown stays unknown: a record with no label is rejected on a classed day, block or not.
        assertEquals(1, StepsCounter.stepsInWindow(listOf(step(0, 100, 1), step(1, 101, 1), step(2, 108, null))))
        // On a wholly unclassed legacy window every plausible increment counts, blocks included.
        assertEquals(7, StepsCounter.stepsInWindow(listOf(step(0, 100), step(1, 107))))
    }

    @Test fun boutBlockIsWrapAwareAndCounterResetsAreNotBlocks() {
        assertEquals(10, StepsCounter.stepsInWindow(listOf(step(0, 65_530, 0), step(1, 4, 0))))
        // A reset drops the counter, so the u16 difference is ~65,500: far above any block.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100, 0), step(1, 94, 0))))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 60_849, 0), step(1, 6, 0))))
    }

    /**
     * A live walking test on a WHOOP 5/MG: bouts of a few steps with brief stops between them, as
     * (second, increment, activity class) for every second the counter moved. Six bursts, each opening with
     * a 6 or 7 tick block, then one lone block 45 s after the last movement. The old class and 4 ticks/second
     * gates kept only the 42 smooth ticks of the bursts and discarded every block (39 ticks in the bursts).
     */
    private val walkTest = listOf(
        Triple(14, 6, 0), Triple(22, 7, 1), Triple(23, 1, 1), Triple(30, 6, 0), Triple(33, 1, 1),
        Triple(34, 2, 1), Triple(35, 1, 1), Triple(36, 2, 1), Triple(37, 1, 1), Triple(38, 1, 1),
        Triple(40, 2, 1), Triple(41, 2, 1), Triple(42, 1, 1), Triple(43, 2, 1), Triple(44, 1, 1),
        Triple(45, 2, 1), Triple(46, 1, 1), Triple(56, 7, 1), Triple(57, 2, 1), Triple(58, 1, 1),
        Triple(64, 6, 0), Triple(65, 2, 1), Triple(66, 1, 1), Triple(67, 1, 1), Triple(73, 7, 1),
        Triple(74, 1, 1), Triple(75, 2, 1), Triple(78, 2, 1), Triple(79, 2, 1), Triple(80, 1, 1),
        Triple(81, 2, 1), Triple(82, 2, 1), Triple(83, 1, 1), Triple(84, 2, 1), Triple(129, 6, 0),
    )

    private fun walkTestStream(last: Int): List<StepSample> {
        val moves = walkTest.associate { (at, ticks, cls) -> at to (ticks to cls) }
        var counter = 343
        return (0..last).map { second ->
            val move = moves[second] ?: return@map step(second.toLong(), counter, 0)
            counter += move.first
            step(second.toLong(), counter, move.second)
        }
    }

    @Test fun recordedWalkTestCountsEveryBoutBlock() {
        assertEquals(81, StepsCounter.stepsInWindow(walkTestStream(100)))
        assertEquals(87, StepsCounter.stepsInWindow(walkTestStream(130)))
    }

    @Test fun windowsThatShareOneBoundarySampleSumToTheDayTotal() {
        // The per-minute series re-reads the sample before each window's first increment. Because a block is
        // judged from that pair alone, any such partition of the day adds up to the whole.
        val stream = walkTestStream(130)
        val whole = StepsCounter.stepsInWindow(stream)!!
        for (width in listOf(2, 7, 11, 60)) {
            var parts = 0
            var start = 0
            while (start < stream.size - 1) {
                val end = minOf(start + width, stream.size)
                parts += StepsCounter.stepsInWindow(stream.subList(start, end)) ?: 0
                start = end - 1
            }
            assertEquals("window width $width", whole, parts)
        }
    }

    @Test fun classedStreamCountsOnlyWalkAndRunDeltas() {
        // Attribute each counter delta to the later sample, matching the strap's per-record class.
        // still: +10 ignored; walk: +20; run: +15; unknown: +25 ignored => 35 locomotion ticks.
        assertEquals(35, StepsCounter.stepsInWindow(listOf(
            step(0, 100, 0),
            step(10, 110, 0),
            step(20, 130, 1),
            step(30, 145, 2),
            step(40, 170, null),
        )))
    }

    @Test fun legacyUnclassedStreamKeepsCounterFallback() {
        // Rows written before activityClass existed must retain their historical estimate.
        assertEquals(70, StepsCounter.stepsInWindow(listOf(
            step(0, 100), step(10, 140), step(20, 170),
        )))
    }
}
