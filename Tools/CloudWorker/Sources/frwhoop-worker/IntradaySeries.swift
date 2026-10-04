import Foundation
import StrandAnalytics
import WhoopProtocol

/// Dense intraday series for the five metrics the app shows moving through the day: HRV, resting heart rate,
/// respiratory rate, steps and calories.
///
/// The daily scorer produces one value per metric per day. This produces one value per metric per
/// `bucketSeconds` bucket instead, from the same raw streams and the same kernels, so the day's history is
/// a dense time series rather than a single number. It is recomputed for the whole day on every scoring
/// pass, which the queue triggers within minutes of new samples landing, so a bucket fills in as soon as
/// the data behind it is uploaded.
///
/// Everything here is pure: no database, no clock. The caller loads the day's inputs and publishes the
/// result (`ScoringLane.publishSeries`).
///
/// Design rules:
///  - A bucket is a fixed-width slice of the claimed LOCAL day, anchored at the day's own start, so buckets
///    partition the day exactly whatever the timezone offset or DST length.
///  - HRV and respiratory rate are only reported for buckets whose wrist was quiet. Wrist R-R is dominated
///    by motion artifact when the wearer is moving, so a missing point is the honest answer there.
///  - Steps and calories are ADDITIVE: the buckets of a day sum to the daily total the scorer publishes
///    (same kernels, same gates), so the two can never disagree.
///  - Resting heart rate is the lowest quiet 5-minute mean over the trailing hour, the same definition the
///    nightly value uses (`SleepStager.sessionRestingHR`), applied to a moving window.
///  - Every point carries how much data stands behind it (`samples`, `coverage`) and how much the wrist was
///    moving (`motion`), so a consumer can weigh or exclude it.
enum IntradaySeries {
    /// Width of the HRV and resting-heart-rate buckets, and the payload's default width.
    static let bucketSeconds = 300
    /// Width of the respiratory-rate, step and calorie buckets: one a minute, the finest the table accepts
    /// (`server_metric_series_bucket_check`) and a full 25-hour day still fits its 1,500-points-per-metric cap.
    static let fineBucketSeconds = 60
    static let algorithmVersion = "frwhoop-series-2"

    /// A metric's own bucket width. HRV needs ~45 clean beats and the resting floor is a 5-minute mean, so
    /// minute buckets would only repeat overlapping windows; the other three are read at one per minute.
    static func bucketSeconds(for metric: Metric) -> Int {
        switch metric {
        case .hrv, .restingHR: return bucketSeconds
        case .respRate, .steps, .calories: return fineBucketSeconds
        }
    }

    enum Metric: String, CaseIterable {
        case hrv = "hrv_rmssd_ms"
        case restingHR = "resting_hr_bpm"
        case respRate = "resp_rate_bpm"
        case steps = "steps"
        case calories = "calories_kcal"
    }

    struct Point: Equatable {
        /// Bucket start, unix seconds.
        let ts: Int
        let value: Double
        /// Observations behind the value: clean beats for HRV, breath intervals for respiratory rate, step
        /// records for steps, heart-rate samples for calories, and the winning bin's samples for resting heart rate.
        let samples: Int
        /// Share of the bucket the observations account for, 0...1.
        let coverage: Double
        /// Share of the bucket's motion records above the walking floor, 0...1; nil when the strap sent too
        /// little motion to say.
        let motion: Double?
    }

    struct Tuning: Equatable {
        /// Clean beats an HRV bucket needs. A 45-beat slice (about 45 s) lands within ~9% of its full 5-minute
        /// RMSSD at the median and ~23% at the 90th percentile on this strap's quiet nights, which is the
        /// accuracy the `samples` and `coverage` fields let a consumer discount for.
        var hrvMinCleanBeats = 45
        /// Successive differences an HRV bucket needs. A bucket cut into many short runs by dropouts can pass
        /// the beat count and still hold almost no usable pair.
        var hrvMinPairs = 30
        /// Clean beat-time over bucket length. 0.2 is one minute of a five-minute bucket; the strap sends
        /// daytime R-R in bursts, and the ultra-short-term RMSSD literature accepts a minute.
        var hrvMinCoverage = 0.2
        /// Same noise ceiling the app's spot reading applies.
        var hrvMaxRejectedFraction = HRVAnalyzer.defaultSpotMaxRejectedFraction
        /// One-minute buckets the respiratory estimate pools breaths over, the current one included. The
        /// strap's daytime R-R arrives in runs of a minute or two between dropouts, so the estimate is read per
        /// run (`SleepStager.respBreathTrack`) and pooled over two minutes: about 25 breaths at rest, enough
        /// for a stable median, with a fresh point every minute.
        var respWindowBuckets = 2
        /// Beats the pooled window must hold (about 30 s of them).
        var respMinBeats = 30
        /// The current minute must contribute this many beats, so a point is never just its predecessor again.
        var respMinCurrentBeats = 10
        /// Breath intervals the pooled window, and its current minute, must hold.
        var respMinIntervals = 6
        var respMinCurrentIntervals = 2
        /// Beat-time over window length: at least 40 s of a two-minute window must sit in usable runs.
        var respMinCoverage = 0.33
        /// Wall-clock seconds by which a beat may trail the previous one's own length before the gap counts as
        /// a dropout rather than a late timestamp (`SleepStager.rsaGapToleranceS`).
        var spliceToleranceSeconds = 3.0
        /// A bucket whose share of ambulatory records exceeds this is exertion, not rest.
        var maxAmbulatoryShare = DaytimeStress.activityMaskFraction
        /// Stricter bar for the resting-heart-rate bins: they must be near-still.
        var restingMaxAmbulatoryShare = 0.10
        var restingTrailingBuckets = 12
        var restingMinBuckets = 3
        /// Motion records a 5-minute bucket needs before its ambulatory share means anything (10% of 1 Hz).
        var motionMinRecords = 30
        /// A motion delta across a longer gap than this is a sensor gap, not movement.
        var motionMaxGapSeconds = 5

        /// The same 10%-of-1-Hz bar for `seconds` of data, whatever the bucket width.
        func motionMinRecords(forSeconds seconds: Int) -> Int {
            max(1, Int((Double(motionMinRecords) * Double(seconds) / 300.0).rounded(.up)))
        }
    }

    /// Values outside these are dropped, not clamped. HRV, resting heart rate and respiratory rate use the
    /// app's own baseline plausibility bands (`Baselines.metricCfg`); steps and energy only bound a single
    /// 5-minute bucket to something a wrist can produce.
    static let plausibleRange: [Metric: ClosedRange<Double>] = [
        .hrv: 5...250,
        .restingHR: 30...120,
        .respRate: 4...40,
        .steps: 0...5_000,
        .calories: 0...500,
    ]

    struct Inputs {
        var dayStart: Int
        var dayEnd: Int
        var hr: [HRSample]
        var rr: [RRInterval]
        var gravity: [GravitySample]
        var steps: [StepSample]
        var profile: UserProfile
        /// The day's resting heart rate as the scorer used it for the energy model.
        var restingHR: Int?
        /// The scorer's metabolic timeline for the day. When present the calorie series is read straight from
        /// it, so the buckets sum to the published daily total; nil keeps the heart-rate-only apportioning.
        var energy: DayEnergy?
        var tuning = Tuning()
    }

    // MARK: - Entry point

    static func build(_ inputs: Inputs) -> [Metric: [Point]] {
        let layout = Layout(dayStart: inputs.dayStart, dayEnd: inputs.dayEnd)
        let fine = Layout(dayStart: inputs.dayStart, dayEnd: inputs.dayEnd, width: fineBucketSeconds)
        guard layout.count > 0 else { return Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, []) }) }

        let hr = inputs.hr.filter { $0.ts >= inputs.dayStart && $0.ts < inputs.dayEnd }
        let rr = inputs.rr.filter { $0.ts >= inputs.dayStart && $0.ts < inputs.dayEnd }
        let gravity = inputs.gravity.filter { $0.ts >= inputs.dayStart && $0.ts < inputs.dayEnd }
        let steps = inputs.steps.filter { $0.ts >= inputs.dayStart && $0.ts < inputs.dayEnd }

        let motion = motionByBucket(gravity: gravity, layout: layout, tuning: inputs.tuning)
        let fineMotion = motionByBucket(gravity: gravity, layout: fine, tuning: inputs.tuning)
        var beatsByBucket = [[RRInterval]](repeating: [], count: layout.count)
        var beatsByMinute = [[RRInterval]](repeating: [], count: fine.count)
        for beat in rr {
            beatsByBucket[layout.index(beat.ts)].append(beat)
            beatsByMinute[fine.index(beat.ts)].append(beat)
        }

        var out: [Metric: [Point]] = [:]
        out[.hrv] = hrvPoints(beatsByBucket: beatsByBucket, motion: motion, layout: layout, tuning: inputs.tuning)
        out[.respRate] = respPoints(beatsByBucket: beatsByMinute, rr: rr, motion: fineMotion, layout: fine,
                                    tuning: inputs.tuning)
        out[.restingHR] = restingPoints(hr: hr, motion: motion, layout: layout, tuning: inputs.tuning)
        out[.steps] = stepPoints(steps: steps, motion: fineMotion, layout: fine, profile: inputs.profile,
                                 tuning: inputs.tuning)
        if let energy = inputs.energy {
            out[.calories] = energyCaloriePoints(energy: energy, hr: hr, motion: fineMotion, layout: fine,
                                                 tuning: inputs.tuning)
        } else {
            out[.calories] = caloriePoints(hr: hr, motion: fineMotion, layout: fine, profile: inputs.profile,
                                           restingHR: inputs.restingHR, tuning: inputs.tuning)
        }
        for (metric, points) in out {
            guard let range = plausibleRange[metric] else { continue }
            out[metric] = points.filter { $0.value.isFinite && range.contains($0.value) }
        }
        return out
    }

    // MARK: - Payload for `publish_metric_series_v1`

    /// `{algorithm_version, bucket_seconds, metric_bucket_seconds, window, metrics}`; each metric is a list of
    /// `[bucket_start, value, samples, coverage, motion|null]`. Every metric is present, even when empty,
    /// because a present-but-empty metric tells the database the day now has none of it (a replacement),
    /// while an absent one leaves what is stored alone.
    ///
    /// `bucket_seconds` is the default width and `metric_bucket_seconds` names each metric's own. A database
    /// that predates the per-metric field ignores it and labels every row with the default, so the migration
    /// that adds it (`20261002120000_metric_series_per_metric_buckets.sql`) must be applied first.
    static func payload(dayStart: Int, dayEnd: Int, series: [Metric: [Point]]) -> [String: Any] {
        var metrics: [String: Any] = [:]
        for metric in Metric.allCases {
            metrics[metric.rawValue] = (series[metric] ?? []).map { p -> [Any] in
                [p.ts, p.value, p.samples, p.coverage, p.motion.map { $0 as Any } ?? NSNull()]
            }
        }
        return [
            "algorithm_version": algorithmVersion,
            "bucket_seconds": bucketSeconds,
            "metric_bucket_seconds": Dictionary(uniqueKeysWithValues: Metric.allCases.map {
                ($0.rawValue, bucketSeconds(for: $0))
            }),
            "window": ["start": dayStart, "end": dayEnd],
            "metrics": metrics,
        ]
    }

    // MARK: - Layout

    /// Buckets partition `[dayStart, dayEnd)`; the last one is short when the day is not a multiple of the
    /// bucket width.
    struct Layout {
        let dayStart: Int
        let dayEnd: Int
        let width: Int

        init(dayStart: Int, dayEnd: Int, width: Int = IntradaySeries.bucketSeconds) {
            self.dayStart = dayStart; self.dayEnd = dayEnd; self.width = width
        }

        var count: Int { dayEnd > dayStart ? (dayEnd - dayStart + width - 1) / width : 0 }
        func index(_ ts: Int) -> Int { (ts - dayStart) / width }
        func start(_ index: Int) -> Int { dayStart + index * width }
        func length(_ index: Int) -> Int { min(width, dayEnd - start(index)) }
    }

    // MARK: - Motion

    struct Motion: Equatable {
        var ambulatory = 0
        var records = 0
        func share(minRecords: Int) -> Double? {
            records >= minRecords ? Double(ambulatory) / Double(records) : nil
        }
    }

    /// Per-bucket count of motion records above `WorkoutDetector.motionThreshold`, the walking floor the
    /// daytime stress mask already uses, over consecutive records at most `motionMaxGapSeconds` apart.
    static func motionByBucket(gravity: [GravitySample], layout: Layout, tuning: Tuning) -> [Motion] {
        var out = [Motion](repeating: Motion(), count: layout.count)
        let activity = WorkoutDetector.activitySeries(gravity)
        guard activity.count > 1 else { return out }
        for i in 1..<activity.count {
            let dt = activity[i].ts - activity[i - 1].ts
            guard dt > 0, dt <= tuning.motionMaxGapSeconds else { continue }
            let b = layout.index(activity[i].ts)
            guard b >= 0, b < layout.count else { continue }
            out[b].records += 1
            if activity[i].intensity > WorkoutDetector.motionThreshold { out[b].ambulatory += 1 }
        }
        return out
    }

    // MARK: - HRV

    /// RMSSD per bucket with the nightly kernel's cleaning, but with successive differences also skipped
    /// across a wall-clock dropout: beats lost before storage never reach the cleaner, so only the
    /// timestamps reveal that two stored beats were not adjacent.
    static func hrvPoints(beatsByBucket: [[RRInterval]], motion: [Motion], layout: Layout, tuning: Tuning) -> [Point] {
        var out: [Point] = []
        for b in 0..<layout.count {
            let beats = beatsByBucket[b]
            guard beats.count >= tuning.hrvMinCleanBeats else { continue }
            let share = motion[b].share(minRecords: tuning.motionMinRecords)
            if let share, share > tuning.maxAmbulatoryShare { continue }

            let ms = beats.map { Double($0.rrMs) }
            let ts = beats.map(\.ts)
            guard HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms) <= HRVAnalyzer.coveragePlausibleCeiling,
                  HRVAnalyzer.beatValuesAreTrustworthy(
                    beatAccurateFraction: HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: ms))
            else { continue }

            var sumSq = 0.0, pairs = 0, clean = 0, cleanMs = 0.0
            for run in continuousRuns(beats, toleranceSeconds: tuning.spliceToleranceSeconds) {
                let cleaned = HRVAnalyzer.cleanRRGapAware(run)
                clean += cleaned.nn.count
                cleanMs += cleaned.nn.reduce(0, +)
                guard cleaned.nn.count > 1 else { continue }
                for i in 1..<cleaned.nn.count where cleaned.contiguous[i] {
                    let d = cleaned.nn[i] - cleaned.nn[i - 1]
                    sumSq += d * d
                    pairs += 1
                }
            }
            guard clean >= tuning.hrvMinCleanBeats, pairs >= tuning.hrvMinPairs else { continue }
            let rejected = 1.0 - Double(clean) / Double(ms.count)
            guard rejected <= tuning.hrvMaxRejectedFraction else { continue }
            let coverage = min(1.0, cleanMs / (Double(layout.length(b)) * 1000.0))
            guard coverage >= tuning.hrvMinCoverage else { continue }
            let rmssd = (sumSq / Double(pairs)).squareRoot()
            guard rmssd.isFinite else { continue }
            out.append(Point(ts: layout.start(b), value: round(rmssd, 1), samples: clean,
                             coverage: round(coverage, 3), motion: share.map { round($0, 3) }))
        }
        return out
    }

    /// Splits beats wherever the wall clock ran ahead of the beat's own length by more than the tolerance.
    static func continuousRuns(_ beats: [RRInterval], toleranceSeconds: Double) -> [[Double]] {
        var runs: [[Double]] = []
        var current: [Double] = []
        var previousTs: Int?
        for beat in beats {
            let rr = Double(beat.rrMs)
            if let previousTs, Double(beat.ts - previousTs) - rr / 1000.0 > toleranceSeconds, !current.isEmpty {
                runs.append(current)
                current = []
            }
            current.append(rr)
            previousTs = beat.ts
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: - Respiratory rate

    /// Respiratory sinus arrhythmia estimate, one point per minute, over the trailing `respWindowBuckets`
    /// minutes ending at this one. The WHOOP 5/MG sends no breathing channel, so the R-R stream is the only
    /// source. Consecutive points overlap by design.
    ///
    /// The nightly kernel (`SleepStager.respRateFromRR`) cannot do this: it discards every 300 s window that
    /// holds a dropout, and a daytime stream has one every minute or two. `SleepStager.respBreathTrack` reads
    /// the same tachogram per unbroken run instead, and this pools its breaths over the window.
    ///
    /// `beatsByBucket` holds the beats of each minute of `layout`; `rr` is the same beats for the whole day.
    static func respPoints(beatsByBucket: [[RRInterval]], rr: [RRInterval], motion: [Motion], layout: Layout,
                           tuning: Tuning) -> [Point] {
        let track = SleepStager.respBreathTrack(rr)
        guard !track.intervals.isEmpty else { return [] }
        var out: [Point] = []
        for b in 0..<layout.count {
            guard beatsByBucket[b].count >= tuning.respMinCurrentBeats else { continue }
            let lo = max(0, b - tuning.respWindowBuckets + 1)
            let beats = (lo...b).flatMap { beatsByBucket[$0] }
            guard beats.count >= tuning.respMinBeats else { continue }

            var pooled = Motion()
            for j in lo...b {
                pooled.ambulatory += motion[j].ambulatory
                pooled.records += motion[j].records
            }
            let share = pooled.share(minRecords: tuning.motionMinRecords(forSeconds: layout.width * (b - lo + 1)))
            if let share, share > tuning.maxAmbulatoryShare { continue }

            let ms = beats.map { Double($0.rrMs) }
            let ts = beats.map(\.ts)
            guard HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms) <= HRVAnalyzer.coveragePlausibleCeiling,
                  HRVAnalyzer.beatValuesAreTrustworthy(
                    beatAccurateFraction: HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: ms))
            else { continue }

            let windowStart = layout.start(lo)
            let windowEnd = layout.start(b) + layout.length(b)
            guard let estimate = track.estimate(from: windowStart, to: windowEnd, currentFrom: layout.start(b),
                                                minIntervals: tuning.respMinIntervals,
                                                minCurrentIntervals: tuning.respMinCurrentIntervals) else { continue }
            let coverage = min(1.0, estimate.coveredSeconds / Double(windowEnd - windowStart))
            guard coverage >= tuning.respMinCoverage else { continue }
            out.append(Point(ts: layout.start(b), value: round(estimate.breathsPerMinute, 1), samples: estimate.intervals,
                             coverage: round(coverage, 3), motion: share.map { round($0, 3) }))
        }
        return out
    }

    // MARK: - Resting heart rate

    /// For each bucket that has heart-rate samples, the lowest mean among the quiet, well-populated 5-minute
    /// bins of the trailing `restingTrailingBuckets` buckets (the bucket itself included). Needs at least
    /// `restingMinBuckets` such bins, so a stretch of activity yields a gap rather than a stale floor.
    static func restingPoints(hr: [HRSample], motion: [Motion], layout: Layout, tuning: Tuning) -> [Point] {
        var sum = [Double](repeating: 0, count: layout.count)
        var count = [Int](repeating: 0, count: layout.count)
        for sample in hr {
            let b = layout.index(sample.ts)
            sum[b] += Double(sample.bpm)
            count[b] += 1
        }
        var qualifyingMean = [Double?](repeating: nil, count: layout.count)
        for b in 0..<layout.count where count[b] >= SleepStager.rhrMinBinSamples {
            let mean = sum[b] / Double(count[b])
            guard mean >= SleepStager.rhrMinPlausibleBpm else { continue }
            if let share = motion[b].share(minRecords: tuning.motionMinRecords), share > tuning.restingMaxAmbulatoryShare {
                continue
            }
            qualifyingMean[b] = mean
        }

        var out: [Point] = []
        for b in 0..<layout.count where count[b] >= SleepStager.rhrMinBinSamples {
            let lo = max(0, b - tuning.restingTrailingBuckets + 1)
            var best: (mean: Double, samples: Int)?
            var qualifying = 0
            for j in lo...b {
                guard let mean = qualifyingMean[j] else { continue }
                qualifying += 1
                if best == nil || mean < best!.mean { best = (mean, count[j]) }
            }
            guard qualifying >= tuning.restingMinBuckets, let best else { continue }
            out.append(Point(ts: layout.start(b), value: round(best.mean, 1), samples: best.samples,
                             coverage: round(Double(qualifying) / Double(tuning.restingTrailingBuckets), 3),
                             motion: motion[b].share(minRecords: tuning.motionMinRecords).map { round($0, 3) }))
        }
        return out
    }

    // MARK: - Steps

    /// Locomotion ticks per bucket from the strap's cumulative step counter, divided by the calibrated
    /// ticks-per-step exactly as the daily total is. An increment belongs to the bucket of the LATER sample,
    /// which is how `StepsCounter` attributes it, so the buckets sum to the daily total.
    static func stepPoints(steps: [StepSample], motion: [Motion], layout: Layout, profile: UserProfile,
                           tuning: Tuning) -> [Point] {
        let sorted = steps.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [] }
        let dayHasClasses = sorted.contains { $0.activityClass != nil }
        let ticksPerStep = max(profile.stepTicksPerStep, 0.5)

        var firstIndex = [Int?](repeating: nil, count: layout.count)
        var lastIndex = [Int?](repeating: nil, count: layout.count)
        for (i, sample) in sorted.enumerated() {
            let b = layout.index(sample.ts)
            if firstIndex[b] == nil { firstIndex[b] = i }
            lastIndex[b] = i
        }

        var out: [Point] = []
        for b in 0..<layout.count {
            guard let first = firstIndex[b], let last = lastIndex[b] else { continue }
            // The increment into the bucket's first sample comes from the sample before it, even when that one
            // sits in an earlier bucket. The day's first sample has no predecessor and contributes nothing.
            let from = max(0, first - 1)
            let window = Array(sorted[from...last])
            guard window.count >= 2 else { continue }
            let windowHasClasses = window.contains { $0.activityClass != nil }
            // `stepsInWindow` judges "classed" per window, the daily total per day: a window of unclassed
            // records inside a classed day counts nothing in the day total, so it must count nothing here.
            let ticks = (dayHasClasses && !windowHasClasses) ? 0 : (StepsCounter.stepsInWindow(window) ?? 0)
            let observed = last - from
            out.append(Point(ts: layout.start(b), value: Double(ticks) / ticksPerStep, samples: observed,
                             coverage: round(min(1.0, Double(window.count - 1) / Double(layout.length(b))), 3),
                             motion: motion[b].share(minRecords: tuning.motionMinRecords(forSeconds: layout.width))
                                 .map { round($0, 3) }))
        }
        return out
    }

    // MARK: - Calories

    /// Energy per bucket from `Calories.estimateDayEnergy`, apportioned the way that function sums it: a
    /// sample carries its resting energy for the gap to the next sample (capped at `maxGapSeconds`) and, when
    /// its heart rate clears the exercise gate, the energy above resting for the gap capped at the inferred
    /// cadence. The two per-second rates are read back from the engine itself with one-sample probes rather
    /// than reimplemented, so the buckets track any change to the model and sum to the daily figure.
    static func caloriePoints(hr: [HRSample], motion: [Motion], layout: Layout, profile: UserProfile,
                              restingHR: Int?, tuning: Tuning) -> [Point] {
        let ordered = hr.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.bpm > $1.bpm }
        guard !ordered.isEmpty else { return [] }
        let hrmax: Double? = profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil
        let rest = restingHR.map(Double.init)

        func probe(_ bpm: Int) -> Calories.DayEnergyEstimate {
            Calories.estimateDayEnergy([HRSample(ts: 0, bpm: bpm)], profile: profile, hrmax: hrmax, restingHR: rest)
        }
        let restingRate = probe(60).restingKcal
        var activeAboveRest: [Int: Double] = [:]
        func active(_ bpm: Int) -> Double {
            if let cached = activeAboveRest[bpm] { return cached }
            let value = probe(bpm).activeKcal
            activeAboveRest[bpm] = value
            return value
        }

        let gaps = zip(ordered, ordered.dropFirst()).map { Double($1.ts - $0.ts) }.filter { $0 > 0 }.sorted()
        let nominal: Double = {
            guard !gaps.isEmpty else { return 1.0 }
            let mid = gaps.count / 2
            let median = gaps.count.isMultiple(of: 2) ? (gaps[mid - 1] + gaps[mid]) / 2.0 : gaps[mid]
            return min(median, maxGapSeconds)
        }()

        var kcal = [Double](repeating: 0, count: layout.count)
        var seconds = [Double](repeating: 0, count: layout.count)
        var samples = [Int](repeating: 0, count: layout.count)
        for (i, sample) in ordered.enumerated() {
            let b = layout.index(sample.ts)
            let restingSeconds: Double
            let activeSeconds: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - sample.ts)
                restingSeconds = gap > 0 ? min(gap, maxGapSeconds) : 0
                activeSeconds = gap > 0 ? min(gap, nominal) : 0
            } else {
                restingSeconds = nominal
                activeSeconds = nominal
            }
            kcal[b] += restingRate * restingSeconds + active(sample.bpm) * activeSeconds
            seconds[b] += restingSeconds
            samples[b] += 1
        }

        var out: [Point] = []
        for b in 0..<layout.count where samples[b] > 0 {
            out.append(Point(ts: layout.start(b), value: round(kcal[b], 6), samples: samples[b],
                             coverage: round(min(1.0, seconds[b] / Double(layout.length(b))), 3),
                             motion: motion[b].share(minRecords: tuning.motionMinRecords(forSeconds: layout.width))
                                 .map { round($0, 3) }))
        }
        return out
    }

    /// One point per elapsed minute of the scorer's metabolic timeline: that minute's resting plus active
    /// energy, so the buckets still sum to the daily total (`DayEnergy.totalKcal`) the snapshot publishes.
    ///
    /// A minute the strap did not cover still carries its resting energy (metabolism does not stop with the
    /// sensor), reported with `samples == 0` and `coverage == 0` so a consumer can tell it from a measured
    /// minute and shade or skip it. Only minutes aligned to a bucket start are emitted; on a 23 h or 25 h day
    /// the 24 h energy window and the calendar day disagree by an hour at one end, and that hour is simply
    /// not drawn rather than shifted.
    static func energyCaloriePoints(energy: DayEnergy, hr: [HRSample], motion: [Motion], layout: Layout,
                                    tuning: Tuning) -> [Point] {
        var samples = [Int](repeating: 0, count: layout.count)
        for sample in hr {
            let b = layout.index(sample.ts)
            if b >= 0, b < layout.count { samples[b] += 1 }
        }
        var out: [Point] = []
        out.reserveCapacity(energy.minutes.count)
        for minute in energy.minutes {
            let b = layout.index(minute.startTs)
            guard b >= 0, b < layout.count, layout.start(b) == minute.startTs else { continue }
            out.append(Point(ts: minute.startTs, value: round(minute.totalKcal, 6), samples: samples[b],
                             coverage: round(min(1.0, Double(samples[b]) / Double(layout.length(b))), 3),
                             motion: motion[b].share(minRecords: tuning.motionMinRecords(forSeconds: layout.width))
                                 .map { round($0, 3) }))
        }
        return out
    }

    /// Mirrors `Calories.dayMaxObservedGapS`, which is internal to the package. The calorie parity test sums
    /// the buckets against `estimateDayEnergy`, so a change there fails this suite rather than drifting.
    static let maxGapSeconds = 60.0

    // MARK: - Helpers

    private static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}
