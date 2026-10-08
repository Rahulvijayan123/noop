package com.noop.analytics.agreement

import com.noop.analytics.HrvFreqDomain
import org.json.JSONArray
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * Frequency-domain HRV agreement — the CONVENTION-ROBUST LF/HF ratio. Feeds gold NN windows through
 * [HrvFreqDomain.analyzeAssumingContiguous] (gold NN windows are gapless ECG recordings, so the contiguity
 * assumption holds) and compares the LF/HF ratio to an independent scipy Lomb-Scargle
 * reference (hrv_freq_cases.json). Since lomb_scargle_psd_ms2_v2 the band powers are absolute
 * (ms², S = 2·Δt̄·P with P = scipy.signal.lombscargle normalize=False), but the fixture only records the
 * ratio, and the v2 window rule (span-weighted 300 s windows) may differ from the reference's windowing.
 *
 * This confirms noop's LF/HF is in the right ballpark (Task-Force bands, correct spectral shape), within
 * a tolerance that reflects the residual windowing/detrend differences between the two implementations.
 * Local fixture; skips when absent.
 */
class HrvFreqAgreementTest {

    private val path: String = (System.getProperty("noop.hrvGoldFixtures")
        ?: "C:/Users/DavidGillot/Projects/whoop/whoop data/datasets/agreement-fixtures") + "/hrv_freq_cases.json"

    @Test
    fun lfHfRatioAgreesWithScipyReference() {
        val f = File(path)
        assumeTrue("freq fixture absent (local-only), skipping: $path", f.exists())
        val arr = JSONArray(f.readText())

        var compared = 0
        var sumRel = 0.0
        var maxRel = 0.0
        for (i in 0 until arr.length()) {
            val c = arr.getJSONObject(i)
            val nnArr = c.getJSONArray("nn")
            val nn = ArrayList<Double>(nnArr.length())
            for (j in 0 until nnArr.length()) nn.add(nnArr.getDouble(j))
            val bands = HrvFreqDomain.analyzeAssumingContiguous(nn).bands ?: continue
            val lfhf = bands.lfhf ?: continue
            if (c.isNull("refLfHf")) continue
            val ref = c.getDouble("refLfHf")
            if (ref <= 0.0) continue
            val rel = abs(lfhf - ref) / ref
            sumRel += rel; maxRel = maxOf(maxRel, rel); compared++
        }
        assumeTrue("no LF/HF-comparable windows (spans too short for LF)", compared > 0)
        val meanRel = sumRel / compared
        println("[freq] LF/HF ratio vs scipy: $compared windows, mean rel err=${"%.3f".format(meanRel)}, max=${"%.3f".format(maxRel)}")
        // Two independent Lomb-Scargle implementations agree on the ratio to within a modest tolerance
        // (windowing/detrend differ). Assert the MEAN relative error is bounded — the ratio is right, not noise.
        assertTrue("mean LF/HF relative error too high ($meanRel) — spectral shape diverges", meanRel < 0.5)
    }
}
