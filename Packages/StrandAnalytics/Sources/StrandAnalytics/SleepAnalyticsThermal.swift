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
//   * The bins are built ONCE over the whole peri-sleep analysis span
//     `[first observed onset − 60 min, last fragment end + 30 min)` (widened to the
//     morning-response window when that reaches further; spec-02 §3, CONTRACT §4.2).
//     The nightly summary reads the in-fragment subset only, so post-wake and
//     pre-onset observations never change it; the pre-onset slope reads
//     `[onset − 60 min, onset)` (minutes BEFORE the first fragment included) and the
//     post-wake slope `[window end, window end + 30 min)`. Before this repair both
//     slopes read the in-fragment subset, so the post-wake slope could never exist.
//   * Accepted readings aggregate into UTC-minute bins by MEDIAN; a WHOOP 1 Hz
//     minute bin needs ≥30 distinct accepted sample seconds; no empty-bin
//     interpolation; duplicate samples cannot inflate coverage.
//   * Slopes are ORDINARY least squares of minute medians against ACTUAL elapsed
//     time (unix seconds — DST-immune by construction).
//   * A configurable 5-minute equilibration period after an explicit re-wear event
//     (the end of an off-wrist interval) is excluded; the exclusions and whether
//     event provenance was actually available are reported, never invented.

extension SleepAnalyticsV1 {

    // MARK: - Qualified minute bins (built ONCE over the peri-sleep analysis span)

    /// The qualified UTC-minute skin-temperature bins over the whole peri-sleep analysis span
    /// (docs/spec-02/CONTRACT.md §4.2). Built ONCE; the nightly summary, both slopes and the
    /// morning-response temperature curve read subsets of these same bins — nothing re-bins.
    struct ThermalMinuteBins {
        /// Half-open analysis span `[spanStart, spanEnd)` (unix seconds): from
        /// min(first fragment start, first observed onset − pre-onset window, window end − morning
        /// window) to max(window end + post-wake window, window end + morning window).
        let spanStart: Int
        let spanEnd: Int
        /// Accepted minute bins (qualified AND not equilibration-excluded), ascending by minute.
        let accepted: [(minute: Int, median: Double)]
        /// Distinct accepted sample seconds per UTC minute, for every minute holding ≥ 1 accepted
        /// second (thin, qualified and excluded minutes alike). Duplicates never count twice.
        let support: [Int: Int]
        /// Qualified minutes removed by the post-re-wear equilibration rule.
        let excludedMinutes: Set<Int>
        /// True when an explicit re-wear event (an off-wrist interval END) backed an exclusion
        /// window overlapping the span.
        let rewearVerified: Bool
        /// Per-sample stream diagnostics over the span (closed-vocabulary keys).
        let sampleCounts: [String: Int]

        /// The accepted bin median at `minute`, or nil (thin, excluded or absent).
        func acceptedMedian(at minute: Int) -> Double? {
            acceptedIndex[minute]
        }
        private let acceptedIndex: [Int: Double]

        init(spanStart: Int, spanEnd: Int, accepted: [(minute: Int, median: Double)],
             support: [Int: Int], excludedMinutes: Set<Int>, rewearVerified: Bool,
             sampleCounts: [String: Int]) {
            self.spanStart = spanStart; self.spanEnd = spanEnd
            self.accepted = accepted; self.support = support
            self.excludedMinutes = excludedMinutes; self.rewearVerified = rewearVerified
            self.sampleCounts = sampleCounts
            var index: [Int: Double] = [:]
            index.reserveCapacity(accepted.count)
            for bin in accepted { index[bin.minute] = bin.median }
            self.acceptedIndex = index
        }
    }

    /// Build every qualified UTC-minute bin once over the analysis span with the funnel's worn,
    /// plausibility, distinct-second and re-wear equilibration rules (spec-02 §3, CONTRACT §4.2).
    static func thermalMinuteBins(timeline: SleepAnalyticsTimeline,
                                  input: SleepAnalyticsInput,
                                  config: SleepAnalyticsConfig) -> ThermalMinuteBins {
        let windowEnd = timeline.fragments.last?.end ?? 0
        var spanStart = timeline.fragments.first?.start ?? 0
        if let onset = timeline.firstSupportedAsleepStart {
            spanStart = min(spanStart, onset - config.preOnsetSlopeWindowSeconds)
        }
        spanStart = min(spanStart, windowEnd - config.morningWindowBeforeSeconds)
        let spanEnd = windowEnd + max(config.postWakeSlopeWindowSeconds, config.morningWindowAfterSeconds)
        // Samples are read on WHOLE UTC minutes covering the span, so a minute bin at the span
        // edge holds exactly the samples it would hold with no span filter at all (the nightly
        // summary is byte-identical to a whole-read binning).
        let readStart = spanStart - ((spanStart % 60) + 60) % 60
        let readEnd = spanEnd + (60 - ((spanEnd % 60) + 60) % 60) % 60

        // ── Worn gate + conversion (the funnel's own rules) ─────────────────────
        // A sample is worn when its second carries valid HR presence (exact-second
        // match, the WHOOP co-sampled path — tolerance 0 like the funnel's default)
        // and it is not inside an explicit off-wrist interval. The 4.0 raw band is
        // rejected BEFORE conversion (the funnel's wornMin/wornMax gate); the 5/MG
        // centidegree path converts directly; then the 28–42 °C plausibility band
        // (config) rejects implausible conversions.
        var hrSeconds = Set<Int>()
        for s in input.hr where s.ts >= readStart && s.ts < readEnd
            && Double(s.bpm) >= config.hrPlausibleMinBpm && Double(s.bpm) <= config.hrPlausibleMaxBpm {
            hrSeconds.insert(s.ts)
        }
        let anchor: Double
        switch input.deviceFamily {
        case .whoop4: anchor = input.skinTempAnchorRaw ?? Whoop4SkinTemp.anchorRaw
        case .whoop5: anchor = 0   // unused by the centidegree path
        }
        let offWrist = input.offWristIntervals.filter { $0.end > readStart && $0.start < readEnd }

        var received = 0, duplicate = 0, rejected = 0
        var outOfBand = 0, offWristRejected = 0, implausible = 0
        var acceptedBySecond: [Int: Double] = [:]      // second → °C (deduped, first wins)
        for sample in input.skinTemp where sample.ts >= readStart && sample.ts < readEnd {
            received += 1
            guard acceptedBySecond[sample.ts] == nil else { duplicate += 1; continue }
            if input.deviceFamily == .whoop4,
               !(Double(sample.raw) >= Double(Whoop4SkinTemp.wornMinRaw)
                   && Double(sample.raw) <= Double(Whoop4SkinTemp.wornMaxRaw)) {
                outOfBand += 1; rejected += 1; continue
            }
            if offWrist.contains(where: { $0.start <= sample.ts && sample.ts < $0.end }) {
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
        // `acceptedBySecond` is keyed by second, so each value is one DISTINCT second:
        // duplicates collapsed above and cannot inflate a bin's support.
        var binValues: [Int: [Double]] = [:]
        for (ts, c) in acceptedBySecond {
            binValues[ts - ((ts % 60) + 60) % 60, default: []].append(c)
        }
        var support: [Int: Int] = [:]
        support.reserveCapacity(binValues.count)
        var qualified: [(minute: Int, median: Double)] = []
        qualified.reserveCapacity(binValues.count)
        for (minute, values) in binValues {
            support[minute] = values.count
            guard values.count >= config.tempMinuteMinDistinctSampleSeconds else {
                continue      // a thin bin is missing, never interpolated
            }
            qualified.append((minute, median(values)))
        }
        qualified.sort { $0.minute < $1.minute }

        // ── Equilibration exclusions after an explicit re-wear event ────────────
        // A re-wear event = the END of an off-wrist interval. The configurable window after
        // it is excluded from every subset (summary, slopes, morning curve). An event just
        // before the span still excludes the part of its window that overlaps the span. If no
        // event backs an exclusion, `rewearVerified` stays false — warmup was not verified,
        // never invented (spec section 6).
        let qualifiedMinutes = Set(qualified.map(\.minute))
        var excluded = Set<Int>()
        var rewearVerified = false
        for interval in input.offWristIntervals {
            let from = interval.end
            let to = from + config.thermalRewearExclusionSeconds
            guard to > spanStart, from < spanEnd else { continue }
            rewearVerified = true
            var m = from - ((from % 60) + 60) % 60
            while m < to {
                if qualifiedMinutes.contains(m) { excluded.insert(m) }
                m += 60
            }
        }
        let accepted = qualified.filter { !excluded.contains($0.minute) }

        return ThermalMinuteBins(
            spanStart: spanStart, spanEnd: spanEnd, accepted: accepted, support: support,
            excludedMinutes: excluded, rewearVerified: rewearVerified,
            sampleCounts: [
                "temp_received": received,
                "temp_valid": acceptedBySecond.count,
                "temp_duplicate": duplicate,
                "temp_rejected": rejected,
                "temp_whoop4_raw_band_rejected": outOfBand,
                "temp_off_wrist_rejected": offWristRejected,
                "temp_not_worn_evidenced": rejected - outOfBand - offWristRejected - implausible,
                "temp_implausible_rejected": implausible,
                "temp_span_accepted_minutes": accepted.count,
            ])
    }

    // MARK: - Thermal group

    static func thermalGroup(timeline: SleepAnalyticsTimeline,
                             input: SleepAnalyticsInput,
                             config: SleepAnalyticsConfig,
                             bins: ThermalMinuteBins? = nil) -> SleepAnalyticsThermalGroup {
        let bins = bins ?? thermalMinuteBins(timeline: timeline, input: input, config: config)
        let anchorResolved = input.skinTempAnchorRaw ?? Whoop4SkinTemp.anchorRaw
        let rewearExcludedMinutes = bins.excludedMinutes.count
        let rewearVerified = bins.rewearVerified
        // Every slope reads the span's accepted bins; the nightly summary reads ONLY the
        // in-fragment subset (a minute whose start lies inside a fragment), so post-wake and
        // pre-onset observations can never move the night's values.
        let spanMinutes = bins.accepted
        let summaryMinutes = spanMinutes.filter { bin in
            timeline.fragments.contains(where: { $0.start <= bin.minute && bin.minute < $0.end })
        }

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
                            minutes: spanMinutes, onsetObserved: timeline.onsetPrefixObserved,
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
                             minutes: spanMinutes, onsetObserved: true,
                             requiredValid: config.postWakeSlopeMinValidMinutes,
                             eligibleMinutes: config.postWakeSlopeWindowSeconds / 60,
                             maxMissingRun: config.slopeMaxMissingRunSeconds, config: config)
        } else {
            postWake = nil
        }

        let mergedStreamCounts = timeline.streamCounts
            .merging(bins.sampleCounts) { _, new in new }
            .merging([
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

    /// Ordinary least-squares slope of y against x (unix seconds), per SECOND (callers scale to
    /// per hour). CENTRED form Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²: the raw-sum form `n·Σx² − (Σx)²` cancels
    /// catastrophically at unix-second magnitudes (~1.8e9 s), which biased a 30-minute slope by
    /// ~0.2 % (spec-02 thermal repair). Mathematically identical; numerically exact on a line.
    private static func olsSlope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + $1.x } / n
        let my = points.reduce(0.0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - mx
            sxx += dx * dx
            sxy += dx * (p.y - my)
        }
        guard sxx > 1e-12 else { return nil }   // zero_denominator: constant time
        return sxy / sxx
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
