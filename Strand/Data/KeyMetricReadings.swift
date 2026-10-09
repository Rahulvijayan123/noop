import Foundation
import WhoopProtocol
import StrandAnalytics

/// Measured readings the Skin Temp and Blood Oxygen Key Metrics tiles show between nightly scores.
///
/// Both signals reach the phone only through the strap's history offload, which runs about once a minute on a
/// connected 5.0/MG in cloud mode, and the phone banks every second of it before anything is uploaded. The
/// nightly scores (`skin_temp_c`, `spo2_candidate_pct`) are computed from the same rows, so a tile that reads
/// only them can be hours behind the strap. These helpers read the banked rows directly. A reading is shown
/// as a measurement and labelled with its age; nothing here is scored, averaged into a score, or written back.
enum KeyMetricReadings {

    // MARK: Skin temperature

    /// One banked skin-temperature sample, converted to °C.
    struct SkinTemp: Equatable {
        let ts: Int
        let celsius: Double
    }

    /// A wrist reading outside this range is the strap off the wrist (ambient reads ~22 °C) or a fault, not
    /// skin. The same 28...42 °C worn gate the hosted nightly skin-temperature mean applies.
    static let wornSkinTempRangeC: ClosedRange<Double> = 28...42

    /// A converted skin temperature outside this range is a conversion that went wrong (a wrong strap family
    /// applied to the register), never skin. The "every reading" card drops such values instead of plotting
    /// them, so a bad conversion shows as missing data and not as a 160 °C reading. Wider than
    /// `wornSkinTempRangeC`: a cold wrist is still a reading.
    static let plausibleSkinTempC: ClosedRange<Double> = 15...45

    /// How old the newest sample may be and still count as the current reading. The offload lands a sample
    /// 1 to 2 minutes after the strap took it, and iOS can hold the app for longer, so this is generous;
    /// past it the tile goes back to the nightly value rather than call an old sample "now".
    static let currentSkinTempSeconds = 30 * 60

    /// The strap's current skin temperature: the newest sample in `samples` if it is worn-range and no older
    /// than `currentSkinTempSeconds`; otherwise nil (the strap is off the wrist, or nothing has arrived).
    ///
    /// Only the 5.0/MG. Its register is centidegrees (`skinTempCelsius`, proven on real captures). The
    /// 4.0's is a raw ADC on a provisional, per-device-anchored map that the code itself calls "NOT a
    /// claimed-accurate absolute thermometer", so it never gets a live absolute reading.
    ///
    /// A sample stamped later than `now` (strap-clock skew) is treated as taken now.
    static func currentSkinTemp(_ samples: [SkinTempSample], family: DeviceFamily, now: Int) -> SkinTemp? {
        guard family == .whoop5, let newest = samples.max(by: { $0.ts < $1.ts }) else { return nil }
        let ts = min(newest.ts, now)
        guard now - ts <= currentSkinTempSeconds else { return nil }
        let celsius = skinTempCelsius(raw: newest.raw, family: family)
        guard wornSkinTempRangeC.contains(celsius) else { return nil }
        return SkinTemp(ts: ts, celsius: celsius)
    }

    // MARK: Blood oxygen

    /// The strap's own SpO₂ readings over a window.
    struct Spo2Readings: Equatable {
        /// In-band readings, at most one per strap-second.
        let count: Int
        /// When the newest one was taken.
        let latestTs: Int
    }

    /// The in-band `@82` readings in `aux`, counted by the SAME function that builds the uploaded
    /// `SPO2_STRAP_EST` event rows (`Spo2StrapEstimate.readings`), so this number and the number of
    /// readings sent to Supabase cannot drift apart. nil when there are none.
    ///
    /// The strap fills the byte only while its wearer is asleep and still, so a daytime window is
    /// legitimately empty. That is the strap's behaviour, not a capture gap.
    static func spo2Readings(_ aux: [V18AuxSample]) -> Spo2Readings? {
        let readings = Spo2StrapEstimate.readings(from: aux)
        guard let newest = readings.last else { return nil }
        return Spo2Readings(count: readings.count, latestTs: newest.ts)
    }

    /// Nonzero `@82` bytes that are NOT in-band readings: sub-70 diagnostic codes and bit-7 saturation
    /// sentinels (`Spo2StrapEstimate.band`). The strap writes them inside the same 30-second windows as the
    /// real percentages (a night on a real 5.0/MG held 720 nonzero bytes, 178 of them percentages). They are
    /// not readings and are never uploaded; the count exists so the screen can say what was left out.
    /// One per strap-second, like `Spo2StrapEstimate.readings`.
    static func spo2StatusByteCount(_ aux: [V18AuxSample]) -> Int {
        var bySecond: [Int: Int] = [:]
        for sample in aux {
            if let value = sample.auxByte82, value != 0 { bySecond[sample.ts] = value }
        }
        return bySecond.values.filter { !Spo2StrapEstimate.band.contains($0) }.count
    }

    // MARK: Every banked reading in a window

    /// Everything one signal banked over a window, ready to draw and to count.
    struct BankedSeries: Equatable {
        struct Point: Equatable, Identifiable {
            let ts: Int
            let value: Double
            /// Raw readings this point stands for: 1 for a single reading, or the number averaged into a bucket.
            var n = 1
            var id: Int { ts }
        }
        /// What to plot: every reading when `bucketSeconds <= 1`, otherwise the mean of each bucket.
        var points: [Point] = []
        /// Readings behind `points` (one per strap-second), before any bucketing.
        var count = 0
        var firstTs: Int?
        var lastTs: Int?
        /// The newest raw reading (not a bucket mean).
        var lastValue: Double?
        var minValue: Double?
        var maxValue: Double?
        /// SpO₂ only: nonzero bytes that are not percentages (see `spo2StatusByteCount`).
        var statusBytes = 0
    }

    /// Summarise `readings` (one per second, any order). `bucketSeconds <= 1` keeps every reading as its own
    /// point (SpO₂: a night is a few hundred); larger buckets plot the mean of each bucket, stamped at the
    /// bucket start (skin temperature: a day is up to 86,400 per-second samples). `count`, `minValue` and
    /// `maxValue` always describe the raw readings, never the bucket means.
    static func bankedSeries(_ readings: [(ts: Int, value: Double)], bucketSeconds: Int,
                             statusBytes: Int = 0) -> BankedSeries {
        guard !readings.isEmpty else { return BankedSeries(statusBytes: statusBytes) }
        let sorted = readings.sorted { $0.ts < $1.ts }
        var out = BankedSeries(count: sorted.count, firstTs: sorted.first?.ts, lastTs: sorted.last?.ts,
                               lastValue: sorted.last?.value, minValue: sorted.map(\.value).min(), maxValue: sorted.map(\.value).max(),
                               statusBytes: statusBytes)
        if bucketSeconds <= 1 {
            out.points = sorted.map { BankedSeries.Point(ts: $0.ts, value: $0.value) }
            return out
        }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in sorted {
            let bucket = r.ts - r.ts % bucketSeconds
            let s = sums[bucket] ?? (0, 0)
            sums[bucket] = (s.sum + r.value, s.n + 1)
        }
        out.points = sums.keys.sorted().map {
            BankedSeries.Point(ts: $0, value: sums[$0]!.sum / Double(sums[$0]!.n), n: sums[$0]!.n)
        }
        return out
    }

    /// One mark on a day's running step total.
    struct CumulativePoint: Equatable {
        /// The end of the slice, unix seconds.
        let ts: Int
        /// Steps counted from the start of the day up to `ts`.
        let steps: Double
    }

    /// The day's energy through the hours, in the same running-total form (`steps` carries kilocalories here).
    /// Each `sliceSeconds` slice of heart rate is run through the day-energy model on its own, the slices are summed
    /// into a running total, and the total is scaled so the last mark equals `dayTotal` (the figure the Calories
    /// headline shows). The hours therefore carry when the energy was spent; the total is the headline's. Without
    /// a `dayTotal` the model's own sum stands. Empty when there is no heart rate.
    static func cumulativeCalories(_ hr: [HRSample], from: Int, to: Int, sliceSeconds: Int, profile: UserProfile,
                                   hrmax: Double?, restingHR: Double?, dayTotal: Double?) -> [CumulativePoint] {
        guard to > from, sliceSeconds > 0, !hr.isEmpty else { return [] }
        let sorted = hr.sorted { $0.ts < $1.ts }
        var raw: [(ts: Int, kcal: Double)] = []
        var running = 0.0
        var index = 0
        var start = from
        while start < to {
            let end = min(start + sliceSeconds, to)
            var slice: [HRSample] = []
            while index < sorted.count, sorted[index].ts < end {
                if sorted[index].ts >= start { slice.append(sorted[index]) }
                index += 1
            }
            if !slice.isEmpty {
                running += Calories.estimateDayEnergy(slice, profile: profile, hrmax: hrmax, restingHR: restingHR).totalKcal
            }
            raw.append((end, running))
            start = end
        }
        guard running > 0 else { return [] }
        let scale = (dayTotal ?? 0) > 0 ? dayTotal! / running : 1
        return raw.map { CumulativePoint(ts: $0.ts, steps: $0.kcal * scale) }
    }

    /// The running step total at the end of each `sliceSeconds` slice of `[from, to]`, from the strap's step
    /// counter. Slice k holds the samples inside it plus the last sample before it, so no increment between two
    /// adjacent samples is lost or counted twice and the slices add up to the whole window's count. Slices with
    /// no counter movement repeat the total (a flat stretch). Empty when nothing was counted at all.
    static func cumulativeSteps(_ samples: [StepSample], from: Int, to: Int, sliceSeconds: Int,
                                ticksPerStep: Double) -> [CumulativePoint] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2, sliceSeconds > 0, to > from else { return [] }
        let scale = max(0.5, ticksPerStep)
        var points: [CumulativePoint] = []
        var total = 0.0
        var cursor = 0   // first sample at or after the current slice's start
        var end = from + sliceSeconds
        var slice = from
        while slice < to {
            end = min(slice + sliceSeconds, to)
            while cursor < sorted.count, sorted[cursor].ts < slice { cursor += 1 }
            var last = cursor
            while last < sorted.count, sorted[last].ts < end { last += 1 }
            let first = max(0, cursor - 1)
            if last - first >= 2, let ticks = StepsCounter.stepsInWindow(Array(sorted[first..<last])) {
                total += Double(ticks) / scale
            }
            points.append(CumulativePoint(ts: end, steps: total))
            slice = end
        }
        return total > 0 ? points : []
    }

    /// Readings per clock hour, oldest first, from the points' own counts. Shows how densely the strap sampled:
    /// a worn hour of skin temperature is 3,600, and an hour the strap was off the wrist is absent (or short).
    /// Hours are UTC-aligned whole hours (`ts - ts % 3600`), which is also every whole local hour in the
    /// zones with whole-hour offsets; a half-hour-offset zone draws its bars half an hour early, which only
    /// shifts the bar's position, never its height.
    static func hourlyCounts(_ points: [BankedSeries.Point]) -> [(hourStart: Int, count: Int)] {
        var byHour: [Int: Int] = [:]
        for p in points { byHour[p.ts - p.ts % 3600, default: 0] += p.n }
        return byHour.keys.sorted().map { (hourStart: $0, count: byHour[$0]!) }
    }

    /// Split `points` into runs wherever consecutive points are more than `maxGapSeconds` apart, so a chart
    /// draws a gap (the strap off the wrist, or not yet synced) as a gap, never as a line across it.
    static func runs(_ points: [BankedSeries.Point], maxGapSeconds: Int) -> [[BankedSeries.Point]] {
        var runs: [[BankedSeries.Point]] = []
        var current: [BankedSeries.Point] = []
        for p in points {
            if let last = current.last, p.ts - last.ts > maxGapSeconds {
                runs.append(current)
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The window that holds the night a day is named for: 18:00 the evening before through 18:00 that day
    /// (clamped to `now` for today). An evening sleep onset and a morning wake both fall inside it, and
    /// consecutive days' windows do not overlap. Local calendar, like every other day window on Today.
    static func spo2NightWindow(dayStart: Date, now: Date, calendar: Calendar = .current) -> (from: Int, to: Int) {
        let from = calendar.date(byAdding: .hour, value: -6, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: 18, to: dayStart) ?? dayStart
        let to = min(end, now)
        return (Int(from.timeIntervalSince1970), max(Int(from.timeIntervalSince1970), Int(to.timeIntervalSince1970)))
    }
}
