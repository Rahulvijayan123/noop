import Foundation
import WhoopProtocol

// SleepAnalyticsMorning.swift — the 30-minute morning response group
// (`sleep_analytics_v1.morning_response`, docs/spec-02/CONTRACT.md §4.3). Owner: temperature /
// circadian workstream. Swift `sleep_analytics_v1` is the ONE producer of this response; Python's
// three-minute settling response (`sleep_features.nights[].settling`) is a separately defined output
// and is not touched.
//
// WHAT IT IS. Heart rate, skin temperature and wrist movement, minute by minute, over
// `[anchor − 30 min, anchor + 30 min)`, where the anchor is the EFFECTIVE window end (the last
// fragment end — the same boundary the thermal post-wake slope uses). It is a response around a
// DETECTED BOUNDARY, not proof of awakening physiology (`interpretation`), and each signal keeps its
// own coverage: the three are never pooled into one number.
//
// GRID. The points are the UTC minutes whose start lies in `[anchor − before, anchor + after)`;
// `offset_min = floor((minute − anchor) / 60)` (−30 … +29). UTC minutes, not anchor-relative
// minutes, so the temperature curve is EXACTLY the thermal group's accepted bins (built once in
// `thermalMinuteBins`, never re-binned) and all three signals share one grid. When the anchor sits
// on a minute boundary the offsets are exact; otherwise the minute that straddles the anchor counts
// as "before" (the same minute-start rule the slope windows use). Unix seconds throughout, so the
// grid is immune to DST and clock relabelling.
//
// MINUTE RULES (v1 of the group, `morning-response-1`):
//   * heart rate — median of the plausible HR seconds in the minute (config band, first sample per
//     second wins, explicit off-wrist seconds excluded); valid with ≥ 30 distinct seconds.
//   * skin temperature — the thermal group's accepted minute bin (worn-evidenced, plausible,
//     ≥ 30 distinct seconds, not inside a re-wear equilibration window); its median °C.
//   * movement — moving seconds among TRUE one-second gravity adjacencies `(t − 1, t)` with `t` in
//     the minute (both samples valid, consecutive seconds, neither off-wrist; the movement group's
//     threshold); valid with ≥ 30 eligible adjacencies and no explicit off-wrist time in the minute.
//     The value is the raw count (s per observed minute), never scaled up for missing adjacencies.
// Side medians need ≥ 1 valid minute (`partial` below the configured minimum, 20); the change
// (after − before) needs the minimum on BOTH sides, else null with `insufficient_coverage`.

extension SleepAnalyticsV1 {

    /// `morning_response.algorithm_version`.
    public static let morningResponseAlgorithmVersion = "morning-response-1"
    /// `morning_response.interpretation`.
    public static let morningResponseInterpretation = "response_around_detected_boundary_not_awakening_physiology"

    /// Compute the morning response. `thermalBins` are the thermal group's bins (the document path
    /// passes the SAME bins the thermal group used); nil builds them (test/convenience path).
    /// Returns nil only when the night has no fragment to anchor on.
    static func morningResponseGroup(timeline: SleepAnalyticsTimeline,
                                     input: SleepAnalyticsInput,
                                     config: SleepAnalyticsConfig,
                                     thermalBins: ThermalMinuteBins? = nil) -> SleepAnalyticsMorningResponseGroup? {
        guard let anchor = timeline.fragments.last?.end, anchor > 0 else { return nil }
        let before = max(60, config.morningWindowBeforeSeconds)
        let after = max(60, config.morningWindowAfterSeconds)
        let bins = thermalBins ?? thermalMinuteBins(timeline: timeline, input: input, config: config)

        // UTC minutes whose start lies in [anchor − before, anchor + after).
        let lowest = anchor - before
        let firstMinute = lowest + (60 - ((lowest % 60) + 60) % 60) % 60
        var minutes: [Int] = []
        var m = firstMinute
        while m < anchor + after { minutes.append(m); m += 60 }
        guard let gridStart = minutes.first, let lastMinute = minutes.last else { return nil }
        let gridEnd = lastMinute + 60
        let offWrist = input.offWristIntervals.filter { $0.end > gridStart - 1 && $0.start < gridEnd }
        func isOffWrist(_ ts: Int) -> Bool { offWrist.contains { $0.start <= ts && ts < $0.end } }

        // ── Heart rate: plausible, deduped seconds (first wins), off-wrist excluded ──
        var hrBySecond: [Int: Double] = [:]
        var hrReceived = 0, hrDuplicate = 0, hrRejected = 0
        for s in input.hr where s.ts >= gridStart && s.ts < gridEnd {
            hrReceived += 1
            guard hrBySecond[s.ts] == nil else { hrDuplicate += 1; continue }
            let bpm = Double(s.bpm)
            guard bpm >= config.hrPlausibleMinBpm, bpm <= config.hrPlausibleMaxBpm, !isOffWrist(s.ts) else {
                hrRejected += 1; continue
            }
            hrBySecond[s.ts] = bpm
        }
        var hrByMinute: [Int: [Double]] = [:]
        for (ts, bpm) in hrBySecond { hrByMinute[ts - ((ts % 60) + 60) % 60, default: []].append(bpm) }

        // ── Movement: valid, deduped gravity seconds; true one-second adjacencies ──
        let gravity = morningGravityBySecond(input.gravity, from: gridStart - 1, to: gridEnd, config: config)
        var eligibleByMinute: [Int: Int] = [:], movingByMinute: [Int: Int] = [:]
        var t = gridStart
        while t < gridEnd {
            if let prev = gravity.bySecond[t - 1], let cur = gravity.bySecond[t],
               !isOffWrist(t - 1), !isOffWrist(t) {
                let minute = t - ((t % 60) + 60) % 60
                eligibleByMinute[minute, default: 0] += 1
                let dx = cur.x - prev.x, dy = cur.y - prev.y, dz = cur.z - prev.z
                if (dx * dx + dy * dy + dz * dz).squareRoot() >= config.movementThresholdG {
                    movingByMinute[minute, default: 0] += 1
                }
            }
            t += 1
        }

        func offset(_ minute: Int) -> Int {
            let delta = minute - anchor
            return delta >= 0 ? delta / 60 : -((-delta + 59) / 60)
        }

        let hrPoints = minutes.map { minute -> SleepAnalyticsCurvePoint in
            let values = hrByMinute[minute] ?? []
            let valid = values.count >= config.morningHrMinuteMinDistinctSeconds
            return SleepAnalyticsCurvePoint(offsetMinutes: offset(minute),
                                            value: valid ? median(values) : nil,
                                            support: values.count, valid: valid)
        }
        let tempPoints = minutes.map { minute -> SleepAnalyticsCurvePoint in
            let value = bins.acceptedMedian(at: minute)
            return SleepAnalyticsCurvePoint(offsetMinutes: offset(minute), value: value,
                                            support: bins.support[minute] ?? 0, valid: value != nil)
        }
        let movementPoints = minutes.map { minute -> SleepAnalyticsCurvePoint in
            let eligible = eligibleByMinute[minute] ?? 0
            let touchesOffWrist = offWrist.contains { $0.start < minute + 60 && $0.end > minute }
            let valid = eligible >= config.morningMovementMinuteMinAdjacencies && !touchesOffWrist
            return SleepAnalyticsCurvePoint(offsetMinutes: offset(minute),
                                            value: valid ? Double(movingByMinute[minute] ?? 0) : nil,
                                            support: eligible, valid: valid)
        }

        let eachSide = before / 60
        let heartRate = morningSignalWindow(signal: "heart_rate", unit: "bpm",
                                            minuteRule: "median_plausible_hr_seconds_min_\(config.morningHrMinuteMinDistinctSeconds)_distinct_off_wrist_excluded",
                                            points: hrPoints, eligibleEachSide: eachSide, config: config)
        let skinTemperature = morningSignalWindow(signal: "skin_temperature", unit: "°C",
                                                  minuteRule: "thermal_group_accepted_minute_bin",
                                                  points: tempPoints, eligibleEachSide: eachSide, config: config)
        let movement = morningSignalWindow(signal: "movement", unit: "s/min",
                                           minuteRule: "moving_seconds_among_true_1s_gravity_adjacencies_min_\(config.morningMovementMinuteMinAdjacencies)_no_off_wrist",
                                           points: movementPoints, eligibleEachSide: eachSide, config: config)

        let windows = [heartRate, skinTemperature, movement]
        let anyValid = windows.contains { $0.beforeValidMinutes + $0.afterValidMinutes > 0 }
        let allChanges = windows.allSatisfy { $0.change.status == .available }
        let fragmentSpan = timeline.fragmentSpanSeconds
        let quality = SleepAnalyticsQuality(
            status: allChanges ? .available : (anyValid ? .partial : .unavailable),
            fragmentSpanSeconds: fragmentSpan,
            groupSpanSeconds: Double(before + after),
            observedLabeledSeconds: timeline.totalLabelSupportedSeconds,
            unknownSeconds: max(0, fragmentSpan - timeline.totalLabelSupportedSeconds),
            inferredGapAwakeSeconds: timeline.inferredGapIntervals.reduce(0.0) { $0 + Double($1.end - $1.start) },
            inputSupportedSeconds: timeline.totalInputSupportedSeconds,
            inputSupportedFraction: fragmentSpan > 0 ? timeline.totalInputSupportedSeconds / fragmentSpan : nil,
            labelSupportedFraction: fragmentSpan > 0 ? timeline.totalLabelSupportedSeconds / fragmentSpan : nil,
            sourceResolutionSeconds: 60,
            streamCounts: [
                "hr_received": hrReceived,
                "hr_duplicate": hrDuplicate,
                "hr_rejected": hrRejected,
                "gravity_received": gravity.received,
                "gravity_duplicate": gravity.duplicate,
                "gravity_rejected": gravity.rejected,
                "hr_valid_minutes": heartRate.beforeValidMinutes + heartRate.afterValidMinutes,
                "temp_valid_minutes": skinTemperature.beforeValidMinutes + skinTemperature.afterValidMinutes,
                "movement_valid_minutes": movement.beforeValidMinutes + movement.afterValidMinutes,
            ],
            duplicateFragmentCount: timeline.duplicateFragmentCount > 0 ? timeline.duplicateFragmentCount : nil,
            fragmentOverlapSeconds: timeline.fragmentOverlapSeconds > 0 ? timeline.fragmentOverlapSeconds : nil)

        return SleepAnalyticsMorningResponseGroup(
            quality: quality,
            anchorKind: "effective_window_end",
            anchorTs: anchor,
            anchorAt: isoUTC(anchor),
            windowBeforeSeconds: before,
            windowAfterSeconds: after,
            heartRate: heartRate,
            skinTemperature: skinTemperature,
            movement: movement,
            algorithmVersion: morningResponseAlgorithmVersion,
            interpretation: morningResponseInterpretation)
    }

    /// One signal's window: side counts, side medians and the change, each with its own status.
    private static func morningSignalWindow(signal: String, unit: String, minuteRule: String,
                                            points: [SleepAnalyticsCurvePoint], eligibleEachSide: Int,
                                            config: SleepAnalyticsConfig) -> SleepAnalyticsSignalWindow {
        let beforeValues = points.filter { $0.offsetMinutes < 0 && $0.valid }.compactMap(\.value)
        let afterValues = points.filter { $0.offsetMinutes >= 0 && $0.valid }.compactMap(\.value)
        let minimum = max(1, config.morningMinValidMinutesPerSide)
        func sideMedian(_ values: [Double]) -> SleepAnalyticsMetric {
            guard !values.isEmpty else { return .unavailable(.noSamples, unit: unit) }
            let med = median(values)
            return values.count >= minimum ? .available(med, unit: unit) : .partial(med, unit: unit)
        }
        let beforeMedian = sideMedian(beforeValues)
        let afterMedian = sideMedian(afterValues)
        let change: SleepAnalyticsMetric
        if beforeValues.count >= minimum, afterValues.count >= minimum,
           let b = beforeMedian.value, let a = afterMedian.value {
            change = .available(a - b, unit: unit)
        } else {
            change = .unavailable(beforeValues.isEmpty && afterValues.isEmpty ? .noSamples : .insufficientCoverage,
                                  unit: unit)
        }
        return SleepAnalyticsSignalWindow(
            signal: signal, unit: unit, minuteRule: minuteRule, points: points,
            beforeValidMinutes: beforeValues.count, afterValidMinutes: afterValues.count,
            eligibleMinutesEachSide: eligibleEachSide,
            beforeMedian: beforeMedian, afterMedian: afterMedian, change: change)
    }

    /// Valid, deduped 1 Hz gravity samples inside `[from, to)`. The SAME acceptance rule as the
    /// movement group (`SleepAnalyticsMovement.swift`: first sample per second is examined, finite
    /// axes, |g| inside the config band; an invalid first sample leaves the second open). Kept here
    /// rather than factored out of the movement file because another workstream edits that file;
    /// the lead may fold both call sites onto one helper at integration (docs/spec-02/notes/thermal.md).
    static func morningGravityBySecond(_ samples: [GravitySample], from: Int, to: Int,
                                       config: SleepAnalyticsConfig)
        -> (bySecond: [Int: (x: Double, y: Double, z: Double)], received: Int, duplicate: Int, rejected: Int) {
        var bySecond: [Int: (x: Double, y: Double, z: Double)] = [:]
        var received = 0, duplicate = 0, rejected = 0
        for g in samples where g.ts >= from && g.ts < to {
            received += 1
            guard bySecond[g.ts] == nil else { duplicate += 1; continue }
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            if g.x.isFinite && g.y.isFinite && g.z.isFinite,
               norm >= config.gravityNormMinG, norm <= config.gravityNormMaxG {
                bySecond[g.ts] = (g.x, g.y, g.z)
            } else {
                rejected += 1
            }
        }
        return (bySecond, received, duplicate, rejected)
    }
}
