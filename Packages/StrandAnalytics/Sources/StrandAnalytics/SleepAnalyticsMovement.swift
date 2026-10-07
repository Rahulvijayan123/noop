import Foundation
import WhoopProtocol

// SleepAnalyticsMovement.swift — the movement group (docs/sleep-analytics/spec.md
// section 6 "Movement"). Root-owned implementation of the W2 signal-helpers area
// (the first signal-helpers worker stalled before writing code; the spec section
// and the shared contract are unchanged).
//
// A WRIST-MOVEMENT DESCRIPTOR, not an activity or sleep measure: `delta_g` over the
// 1 Hz gravity stream is a device-specific movement proxy. Quiet wrist time is never
// called sleep, limb movement, PLMI, apnea, posture or cortical arousal. The threshold
// is the shared stager stillness threshold (`SleepStager.gravityStillThresholdG`,
// 0.01 g at this baseline) and travels with the output. This is NOT kRA/kAR or SFI:
// the published estimators use run-duration survival/hazard curves over an explicitly
// comparable activity signal; naive transition counts are not the same estimator, so
// nothing here is named after them.
//
// Rules (spec section 6):
//   * Only a TRUE one-second supported adjacency contributes a classified second:
//     both t-1 and t inside the SAME fragment, both samples valid (finite, |g| in
//     the plausibility band), exactly consecutive seconds, unique per second, and
//     neither second inside an explicit off-wrist interval.
//   * Missing samples, off-wrist intervals and fragment boundaries break runs — a
//     bout never joins across them, even when timestamps touch.
//   * `dynAccel` is NOT interchangeable without a validated feature definition; v1
//     never substitutes it. Absent raw IMU / the activity classifier changes nothing
//     here: this group needs only the gravity stream (a test pins that).
//   * Wear evidence is the adapter's explicit off-wrist intervals (paired
//     WRIST_OFF/WRIST_ON events); absent HR is unknown evidence, never proof of
//     nonwear. Movement is never derived from a plotted/smoothed chart.

extension SleepAnalyticsV1 {

    static func movementGroup(timeline: SleepAnalyticsTimeline,
                              input: SleepAnalyticsInput,
                              config: SleepAnalyticsConfig) -> SleepAnalyticsMovementGroup {

        // ── Valid, deduped gravity samples (stream diagnostics, spec section 4) ──
        var received = 0, duplicate = 0, rejected = 0
        var bySecond: [Int: (x: Double, y: Double, z: Double)] = [:]
        bySecond.reserveCapacity(input.gravity.count)
        for g in input.gravity {
            received += 1
            guard bySecond[g.ts] == nil else { duplicate += 1; continue }
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            if g.x.isFinite && g.y.isFinite && g.z.isFinite,
               norm >= config.gravityNormMinG, norm <= config.gravityNormMaxG {
                bySecond[g.ts] = (g.x, g.y, g.z)
            } else {
                rejected += 1        // nonfinite axes / implausible |g|: never classified
            }
        }

        func offWrist(_ ts: Int) -> Bool {
            input.offWristIntervals.contains { $0.start <= ts && ts < $0.end }
        }

        var eligible = 0
        var moving = 0
        var movementBouts = 0
        var immobilityComplete = 0, immobilityCensored = 0
        var immobilityDurations: [Double] = []
        var longestImmobility: Double = 0

        // ── Per-fragment classified adjacencies, ascending ──────────────────────
        // A classified adjacency at t is the one-second pair (t-1, t). Runs are built
        // over adjacency time; two adjacencies are CONTIGUOUS exactly when their t's
        // differ by 1 (a missing classified second between them breaks the run).
        for fragment in timeline.fragments {
            var adjacencies: [(t: Int, moving: Bool)] = []
            adjacencies.reserveCapacity(max(0, fragment.end - fragment.start))
            var ts = fragment.start + 1
            while ts < fragment.end {
                if let prev = bySecond[ts - 1], let cur = bySecond[ts],
                   !offWrist(ts - 1), !offWrist(ts) {
                    let dx = cur.x - prev.x, dy = cur.y - prev.y, dz = cur.z - prev.z
                    let deltaG = (dx * dx + dy * dy + dz * dz).squareRoot()
                    adjacencies.append((ts, deltaG >= config.movementThresholdG))
                }
                ts += 1
            }
            eligible += adjacencies.count
            moving += adjacencies.filter(\.moving).count

            // ── Runs over adjacency time ────────────────────────────────────────
            // A movement bout: a maximal run of CONTIGUOUS moving adjacencies.
            // An immobility bout: a maximal run of CONTIGUOUS still adjacencies.
            // An immobility bout is COMPLETE only when it is bounded by a moving
            // adjacency on BOTH sides (adjacency runStart-1 moving AND adjacency
            // runEnd moving — both observed); anything else (discontinuity, missing
            // sample, fragment edge) is CENSORED (spec: edge/unknown-censored
            // stretches are reported separately, never silently counted complete).
            var i = 0
            while i < adjacencies.count {
                let isMoving = adjacencies[i].moving
                var j = i
                while j + 1 < adjacencies.count,
                      adjacencies[j + 1].moving == isMoving,
                      adjacencies[j + 1].t == adjacencies[j].t + 1 {
                    j += 1
                }
                let runStartT = adjacencies[i].t
                let runEndT = adjacencies[j].t + 1      // half-open over adjacency time
                let length = runEndT - runStartT
                if isMoving {
                    movementBouts += 1
                } else if length > 0 {
                    longestImmobility = max(longestImmobility, Double(length))
                    let leftBounded = i > 0 && adjacencies[i - 1].moving
                        && adjacencies[i - 1].t == runStartT - 1
                    let rightBounded = j + 1 < adjacencies.count && adjacencies[j + 1].moving
                        && adjacencies[j + 1].t == runEndT
                    if leftBounded && rightBounded {
                        immobilityComplete += 1
                        immobilityDurations.append(Double(length))
                    } else {
                        immobilityCensored += 1
                    }
                }
                i = j + 1
            }
        }

        // ── Gate: the primary rate needs eligible coverage AND observed time ────
        let fragmentSpan = timeline.fragmentSpanSeconds
        let eligibleSeconds = Double(eligible)
        let eligibleFraction = fragmentSpan > 0 ? eligibleSeconds / fragmentSpan : nil
        let coverageOK = eligibleFraction.map { $0 >= config.motionMinEligibleFraction } ?? false
        let observedOK = eligibleSeconds >= Double(config.motionMinObservedMinutes * 60)
        let rateGate = coverageOK && observedOK

        let movementPct: SleepAnalyticsMetric
        if eligible > 0 {
            movementPct = rateGate
                ? .available(100.0 * Double(moving) / eligibleSeconds, unit: "%")
                : .partial(100.0 * Double(moving) / eligibleSeconds, unit: "%")
        } else {
            movementPct = .unavailable(.zeroDenominator, unit: "%")
        }

        // Qualifying observed exposure with no event is a ZERO count/rate, never null.
        let boutRate: SleepAnalyticsMetric
        if eligibleSeconds > 0 {
            let rate = Double(movementBouts) / (eligibleSeconds / 3600.0)
            boutRate = rateGate ? .available(rate, unit: "per_h") : .partial(rate, unit: "per_h")
        } else {
            boutRate = .unavailable(.noSamples, unit: "per_h")
        }

        let immobilityCount = immobilityComplete + immobilityCensored
        let longestMetric: SleepAnalyticsMetric = immobilityCount > 0
            ? .available(longestImmobility, unit: "s") : .unavailable(.noSamples)
        let quantiles = SleepAnalyticsV1.boutQuantiles(complete: immobilityDurations,
                                                        minBouts: config.minCompleteBoutsForQuantiles)

        let mergedStreamCounts = timeline.streamCounts.merging([
                "gravity_received": received,
                "gravity_valid": bySecond.count,
                "gravity_duplicate": duplicate,
                "gravity_rejected": rejected,
                "hr_received": input.hr.count,
            ]) { _, new in new }
        let quality = SleepAnalyticsQuality(
            status: eligible > 0 ? (rateGate ? .available : .partial) : .unavailable,
            fragmentSpanSeconds: fragmentSpan,
            groupSpanSeconds: Double(max(0, timeline.windowEnd - timeline.windowStart)),
            observedLabeledSeconds: timeline.totalLabelSupportedSeconds,
            unknownSeconds: max(0, fragmentSpan - timeline.totalLabelSupportedSeconds),
            inferredGapAwakeSeconds: timeline.inferredGapIntervals.reduce(0.0) { $0 + Double($1.end - $1.start) },
            inputSupportedSeconds: timeline.totalInputSupportedSeconds,
            inputSupportedFraction: fragmentSpan > 0 ? timeline.totalInputSupportedSeconds / fragmentSpan : nil,
            labelSupportedFraction: fragmentSpan > 0 ? timeline.totalLabelSupportedSeconds / fragmentSpan : nil,
            sourceResolutionSeconds: nil,
            streamCounts: mergedStreamCounts,
            duplicateFragmentCount: timeline.duplicateFragmentCount > 0 ? timeline.duplicateFragmentCount : nil,
            fragmentOverlapSeconds: timeline.fragmentOverlapSeconds > 0 ? timeline.fragmentOverlapSeconds : nil)

        return SleepAnalyticsMovementGroup(
            quality: quality,
            movementSeconds: eligible > 0 ? .available(Double(moving), unit: "s") : .unavailable(.noSamples),
            eligibleSeconds: eligible > 0 ? .available(eligibleSeconds, unit: "s") : .unavailable(.noSamples),
            movementPercentage: movementPct,
            movementBoutCount: eligible > 0 ? .available(movementBouts) : .unavailable(.noSamples),
            movementBoutsPerEligibleHour: boutRate,
            immobilityBoutCompleteCount: eligible > 0 ? .available(immobilityComplete) : .unavailable(.noSamples),
            immobilityBoutCensoredCount: eligible > 0 ? .available(immobilityCensored) : .unavailable(.noSamples),
            longestObservedImmobilitySeconds: longestMetric,
            medianCompleteImmobilityBoutSeconds: quantiles.median,
            p90CompleteImmobilityBoutSeconds: quantiles.p90,
            thresholdG: config.movementThresholdG,
            sourceResolution: "gravity_1hz_adjacent",
            algorithmVersion: SleepAnalyticsV1.algorithmVersion + "-movement-1")
    }
}

extension SleepAnalyticsV1 {
    /// Median + nearest-rank p90 over COMPLETE bout durations (spec section 5:
    /// nearest-rank p90 = the sorted value at ceil(0.9·n)−1; the median is the mean
    /// of the two middle values for even n). Both null with `insufficient_bouts`
    /// below the configured minimum complete-bout count; shared by the movement and
    /// stage-bout quantiles so the two definitions cannot drift.
    static func boutQuantiles(complete: [Double], minBouts: Int) -> (median: SleepAnalyticsMetric,
                                                                    p90: SleepAnalyticsMetric) {
        guard complete.count >= max(1, minBouts) else {
            return (.unavailable(.insufficientBouts), .unavailable(.insufficientBouts))
        }
        let sorted = complete.sorted()
        let n = sorted.count
        let median: Double = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        let p90Index = max(0, Int(ceil(0.9 * Double(n))) - 1)
        return (.available(median, unit: "s"), .available(sorted[p90Index], unit: "s"))
    }
}
