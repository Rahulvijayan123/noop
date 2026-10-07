import Foundation
import WhoopProtocol

// SleepAnalyticsThermal.swift — the thermal group (docs/sleep-analytics/spec.md
// section 6 "Temperature"). Root-owned implementation of the W2 signal-helpers area.
//
// APPROXIMATE WRIST-TEMPERATURE TRENDS: the conversion is the existing family-aware
// funnel path (WHOOP 5/MG centidegrees; the WHOOP 4.0 provisional per-device anchor),
// and the 28–42 °C plausibility band is the funnel's. Ambient temperature and bedding
// are unmeasured confounders. No core temperature, DLMO, true thermal sleep onset or
// body-clock minimum is computed. The pre-onset window is anchored to the OBSERVED
// supported sleep onset; the post-wake window follows the EFFECTIVE window end (the
// last fragment end) and is labelled after the estimated window END — never a
// measured awakening. The 2026 Oura finger-temperature study supports investigating
// trajectories; it does not validate any absolute threshold or detector on this
// wrist signal, so none is applied.
//
// Rules (spec section 6):
//   * Family/anchor conversion is reused exactly (`skinTempCelsius`, per-device
//     WHOOP 4 anchor, 4.0 raw-band rejection); devices/anchors are never combined
//     in one trend (one document = one device family + anchor identity).
//   * Accepted readings aggregate into UTC-minute bins by MEDIAN; a WHOOP 1 Hz
//     minute bin needs ≥30 distinct accepted sample seconds; no empty-bin
//     interpolation; duplicate samples cannot inflate coverage.
//   * Slopes are ORDINARY least squares of minute medians against ACTUAL elapsed
//     time (unix seconds — DST-immune by construction).
//   * A configurable 5-minute equilibration period after an explicit re-wear event
//     (the end of an off-wrist interval) is excluded; the exclusions and whether
//     event provenance was actually available are reported, never invented.

extension SleepAnalyticsV1 {

    static func thermalGroup(timeline: SleepAnalyticsTimeline,
                             input: SleepAnalyticsInput,
                             config: SleepAnalyticsConfig) -> SleepAnalyticsThermalGroup {

        // ── Worn gate + conversion (the funnel's own rules) ─────────────────────
        // A sample is worn when its second carries valid HR presence (exact-second
        // match, the WHOOP co-sampled path — tolerance 0 like the funnel's default)
        // and it is not inside an explicit off-wrist interval. The 4.0 raw band is
        // rejected BEFORE conversion (the funnel's wornMin/wornMax gate); the 5/MG
        // centidegree path converts directly; then the 28–42 °C plausibility band
        // (config) rejects implausible conversions.
        var hrSeconds = Set<Int>()
        for s in input.hr where Double(s.bpm) >= config.hrPlausibleMinBpm
            && Double(s.bpm) <= config.hrPlausibleMaxBpm {
            hrSeconds.insert(s.ts)
        }

        let anchor: Double
        switch input.deviceFamily {
        case .whoop4: anchor = input.skinTempAnchorRaw ?? Whoop4SkinTemp.anchorRaw
        case .whoop5: anchor = 0   // unused by the centidegree path
        }
        let anchorResolved = input.skinTempAnchorRaw ?? Whoop4SkinTemp.anchorRaw

        var received = 0, duplicate = 0, rejected = 0
        var outOfBand = 0, offWristRejected = 0, implausible = 0
        var acceptedBySecond: [Int: Double] = [:]      // second → °C (deduped, first wins)
        for sample in input.skinTemp {
            received += 1
            guard acceptedBySecond[sample.ts] == nil else { duplicate += 1; continue }
            if input.deviceFamily == .whoop4,
               !(Double(sample.raw) >= Double(Whoop4SkinTemp.wornMinRaw)
                   && Double(sample.raw) <= Double(Whoop4SkinTemp.wornMaxRaw)) {
                outOfBand += 1; rejected += 1; continue
            }
            if input.offWristIntervals.contains(where: { $0.start <= sample.ts && sample.ts < $0.end }) {
                offWristRejected += 1; rejected += 1; continue
            }
            if !hrSeconds.contains(sample.ts) {
                // Not worn-evidenced at this second: unknown evidence, never counted
                // as accepted coverage (the funnel's exact-second worn gate).
                rejected += 1; continue
            }
            let c = skinTempCelsius(raw: sample.raw, family: input.deviceFamily, anchorRaw: anchor)
            guard c.isFinite, c >= config.tempPlausibilityMinC, c <= config.tempPlausibilityMaxC else {
                implausible += 1; rejected += 1; continue
            }
            acceptedBySecond[sample.ts] = c
        }

        // ── UTC-minute bins, medians, ≥30 distinct accepted seconds ────────────
        // Duplicate samples in one minute collapse into the second map first, so
        // coverage counts DISTINCT seconds and cannot be inflated by repeats.
        var binSeconds: [Int: Set<Int>] = [:]
        var binValues: [Int: [Double]] = [:]
        for (ts, c) in acceptedBySecond {
            let minute = ts - ts % 60
            binSeconds[minute, default: []].insert(ts)
            binValues[minute, default: []].append(c)
        }
        // In-fragment minute medians: only minutes INSIDE a fragment are the night.
        var minuteMedians: [(minute: Int, median: Double)] = []
        minuteMedians.reserveCapacity(binValues.count)
        for (minute, values) in binValues {
            guard timeline.fragments.contains(where: { $0.start <= minute && minute < $0.end }) else { continue }
            guard let seconds = binSeconds[minute], seconds.count >= config.tempMinuteMinDistinctSampleSeconds else {
                continue      // a thin bin is missing, never interpolated
            }
            minuteMedians.append((minute, median(values)))
        }
        minuteMedians.sort { $0.minute < $1.minute }

        // ── Equilibration exclusions after an explicit re-wear event ────────────
        // A re-wear event = the END of an off-wrist interval. The configurable
        // window after it is excluded from the slope/summary minutes. If NO
        // off-wrist interval end exists in the analysis span, no exclusion is
        // claimed and `rewearEventVerified` stays false — warmup was not verified,
        // never invented (spec section 6).
        let analysisStart = min(timeline.fragments.first?.start ?? 0,
                                (timeline.firstSupportedAsleepStart ?? Int.max) - config.preOnsetSlopeWindowSeconds)
        let analysisEnd = (timeline.fragments.last?.end ?? 0) + config.postWakeSlopeWindowSeconds
        var rewearExcludedMinutes = 0
        var rewearVerified = false
        var excludedMinutes = Set<Int>()
        for interval in input.offWristIntervals {
            let rewearAt = interval.end
            guard rewearAt > analysisStart, rewearAt < analysisEnd else { continue }
            rewearVerified = true
            let from = rewearAt
            let to = rewearAt + config.thermalRewearExclusionSeconds
            var m = from - from % 60
            while m < to {
                if minuteMedians.contains(where: { $0.minute == m }) {
                    excludedMinutes.insert(m)
                }
                m += 60
            }
        }
        rewearExcludedMinutes = excludedMinutes.count
        let summaryMinutes = minuteMedians.filter { !excludedMinutes.contains($0.minute) }

        // ── Nightly summary (spec table: ≥30 valid minutes + ≥80% eligible) ────
        let fragmentSpan = timeline.fragmentSpanSeconds
        let eligibleMinutes = Int(fragmentSpan / 60.0)
        let validCount = summaryMinutes.count
        let coverage = eligibleMinutes > 0 ? Double(validCount) / Double(eligibleMinutes) : nil
        let summaryGate = validCount >= config.thermalMinValidMinutes
            && (coverage ?? 0) >= config.thermalMinEligibleMinuteFraction
        let values = summaryMinutes.map(\.median)

        let nightMedian: SleepAnalyticsMetric
        let nightIqr: SleepAnalyticsMetric
        let nightSpread: SleepAnalyticsMetric
        if values.isEmpty {
            nightMedian = .unavailable(.noSamples); nightIqr = .unavailable(.noSamples)
            nightSpread = .unavailable(.noSamples)
        } else {
            let med = median(values)
            nightMedian = summaryGate ? .available(med, unit: "°C") : .partial(med, unit: "°C")
            let q25 = quantile(values, 0.25), q75 = quantile(values, 0.75)
            nightIqr = summaryGate ? .available(q75 - q25, unit: "°C") : .partial(q75 - q25, unit: "°C")
            let q05 = quantile(values, 0.05), q95 = quantile(values, 0.95)
            nightSpread = summaryGate ? .available(q95 - q05, unit: "°C") : .partial(q95 - q05, unit: "°C")
        }

        // ── Pre-onset slope: [onset − 60 min, onset) ────────────────────────────
        // Requires an OBSERVED onset (the window anchor is the supported sleep
        // onset; a left-censored onset cannot anchor a physiological pre-onset
        // trend — spec: report the delay only as a boundary estimate), ≥45 of 60
        // valid minutes, no missing run > 5 min.
        let preOnset: SleepAnalyticsSlope?
        if let onset = timeline.firstSupportedAsleepStart {
            let wStart = onset - config.preOnsetSlopeWindowSeconds
            let wEnd = onset
            preOnset = slope(windowStart: wStart, windowEnd: wEnd,
                            minutes: summaryMinutes, onsetObserved: timeline.onsetPrefixObserved,
                            requiredValid: config.preOnsetSlopeMinValidMinutes,
                            eligibleMinutes: config.preOnsetSlopeWindowSeconds / 60,
                            maxMissingRun: config.slopeMaxMissingRunSeconds, config: config)
        } else {
            preOnset = nil
        }

        // ── Post-wake slope: [effective final night end, end + 30 min) ──────────
        // Labelled after the ESTIMATED window end (the last fragment end), never a
        // measured awakening; ≥20 of 30 valid minutes, no missing run > 5 min.
        let windowEnd = timeline.fragments.last?.end ?? 0
        let postWake: SleepAnalyticsSlope?
        if windowEnd > 0 {
            postWake = slope(windowStart: windowEnd,
                             windowEnd: windowEnd + config.postWakeSlopeWindowSeconds,
                             minutes: summaryMinutes, onsetObserved: true,
                             requiredValid: config.postWakeSlopeMinValidMinutes,
                             eligibleMinutes: config.postWakeSlopeWindowSeconds / 60,
                             maxMissingRun: config.slopeMaxMissingRunSeconds, config: config)
        } else {
            postWake = nil
        }

        let mergedStreamCounts = timeline.streamCounts.merging([
                "temp_received": received,
                "temp_valid": acceptedBySecond.count,
                "temp_duplicate": duplicate,
                "temp_rejected": rejected,
                "temp_whoop4_raw_band_rejected": outOfBand,
                "temp_off_wrist_rejected": offWristRejected,
                "temp_not_worn_evidenced": rejected - outOfBand - offWristRejected - implausible,
                "temp_implausible_rejected": implausible,
                "temp_valid_minutes": validCount,
                "temp_eligible_minutes": eligibleMinutes,
                "temp_rewear_excluded_minutes": rewearExcludedMinutes,
            ]) { _, new in new }
        let quality = SleepAnalyticsQuality(
            status: values.isEmpty ? .unavailable : (summaryGate ? .available : .partial),
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

        return SleepAnalyticsThermalGroup(
            quality: quality,
            nightMedianC: nightMedian,
            nightIqrC: nightIqr,
            nightP95MinusP05C: nightSpread,
            preOnsetSlopeCPerHour: preOnset,
            postWakeSlopeCPerHour: postWake,
            equilibrationExcludedMinutes: rewearExcludedMinutes,
            rewearEventVerified: rewearVerified,
            conversionIdentity: conversionIdentity(family: input.deviceFamily,
                                                   anchorRaw: input.skinTempAnchorRaw,
                                                   resolvedAnchor: anchorResolved))
    }

    // MARK: - Slope (OLS against actual elapsed time)

    /// OLS slope (°C per HOUR) of minute medians against actual elapsed time
    /// (unix seconds — DST-immune), with the spec's window gates: ≥`requiredValid`
    /// valid minutes of the window, no missing run > `maxMissingRun`. Onset
    /// observability gates the PRE-onset window only (the post-wake window's
    /// anchor is the fragment end, always effective).
    private static func slope(windowStart: Int, windowEnd: Int,
                              minutes: [(minute: Int, median: Double)],
                              onsetObserved: Bool,
                              requiredValid: Int, eligibleMinutes: Int,
                              maxMissingRun: Int, config: SleepAnalyticsConfig) -> SleepAnalyticsSlope? {
        let inWindow = minutes.filter { $0.minute >= windowStart && $0.minute < windowEnd }
            .sorted { $0.minute < $1.minute }
        let valid = inWindow.count
        let coverage = eligibleMinutes > 0 ? Double(valid) / Double(eligibleMinutes) : nil

        // Missing-run bound: the longest run of missing minutes ANYWHERE inside the
        // window — between consecutive valid minutes AND from both window edges to
        // their nearest valid minute (review P2-6: a hole at the window start or end
        // is a missing run just the same; the gate is "no missing run > 5 min").
        var longestMissing = 0
        if let first = inWindow.first {
            longestMissing = max(longestMissing, first.minute - windowStart)
        } else {
            longestMissing = max(longestMissing, windowEnd - windowStart)
        }
        if let last = inWindow.last {
            longestMissing = max(longestMissing, windowEnd - last.minute - 60)
        }
        if inWindow.count >= 2 {
            for k in 1..<inWindow.count {
                longestMissing = max(longestMissing, inWindow[k].minute - inWindow[k - 1].minute - 60)
            }
        }
        let gatesPass = onsetObserved && valid >= requiredValid && longestMissing <= maxMissingRun
        let slopeValue: Double? = gatesPass ? olsSlope(inWindow) : nil

        return SleepAnalyticsSlope(
            value: slopeValue.map { SleepAnalyticsMetric.available($0 * 3600.0, unit: "°C/h") }
                ?? SleepAnalyticsMetric.unavailable(
                    !onsetObserved ? .onsetNotObserved
                        : (valid < requiredValid ? .insufficientCoverage : .insufficientDuration),
                    unit: "°C/h"),
            windowStart: windowStart,
            windowEnd: windowEnd,
            validMinutes: valid,
            eligibleMinutes: eligibleMinutes,
            coverage: coverage,
            longestMissingRunSeconds: longestMissing)
    }

    /// Ordinary least-squares slope of y against x (unix seconds), per hour.
    private static func olsSlope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let sx = points.reduce(0.0) { $0 + $1.x }
        let sy = points.reduce(0.0) { $0 + $1.y }
        let sxx = points.reduce(0.0) { $0 + $1.x * $1.x }
        let sxy = points.reduce(0.0) { $0 + $1.x * $1.y }
        let denominator = n * sxx - sx * sx
        guard denominator.magnitude > 1e-12 else { return nil }   // zero_denominator: constant time
        return (n * sxy - sx * sy) / denominator
    }

    private static func olsSlope(_ minutes: [(minute: Int, median: Double)]) -> Double? {
        olsSlope(minutes.map { (x: Double($0.minute), y: $0.median) })
    }

    // MARK: - Statistics

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    /// Linear-interpolation quantile (the documented IQR method): position
    /// (n−1)·p between the two neighbouring order statistics.
    static func quantile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let pos = Double(sorted.count - 1) * p
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = pos - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }

    private static func conversionIdentity(family: DeviceFamily, anchorRaw: Double?,
                                           resolvedAnchor: Double) -> String {
        switch family {
        case .whoop5:
            return "whoop5-centidegree"
        case .whoop4:
            let anchor = anchorRaw.map { String(format: "%.0f", $0) } ?? String(format: "%.0f", resolvedAnchor)
            return "whoop4-provisional-anchor-\(anchor)"
        }
    }
}
