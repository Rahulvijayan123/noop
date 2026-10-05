import Foundation

// PCEvaluation.swift — deterministic synthetic evaluation harness for System F (spec §12.3, §14; V11, V12).
//
// OWNER: statistics workstream. Pure: no clock, no file system, no global randomness; every number is a function of
// the seeds and configs passed in.
//
// SYNTHETIC ARITHMETIC CHECKS, NOT PHYSIOLOGICAL ACCURACY. The generators produce AR(1) Gaussian noise with known
// steps, drifts, artifacts and missing days on the transformed scale. Results say how the estimators and detectors
// behave on those series (false episodes per week, detection delay, missed changes, frozen-vs-rolling visibility,
// artifact handling); they say nothing about how often real nights shift, about any device, or about disease.
//
// Evaluation discipline (spec §14):
// - Forward chronological only: every series is processed day by day; each day is scored against references of
//   strictly earlier days (the production code path, `ChangeDetection.analyze`). Nothing is randomly split.
// - Replicate series are independent by construction (one per seed), like held-out users. Intervals on per-replicate
//   statistics (delays, missed rates) use a percentile bootstrap over replicates; intervals on per-week rates use a
//   stationary bootstrap of weeks (Politis & Romano 1994, research note 14) inside each replicate, because weekly
//   counts within one series are dependent through the shared 28-day reference.

extension PhysiologyContext {

    public enum Evaluation {

        // MARK: - Deterministic randomness

        /// SplitMix64: small, fast and fully determined by its seed.
        public struct SeededGenerator: RandomNumberGenerator, Sendable {
            public private(set) var state: UInt64
            public init(seed: UInt64) { state = seed }
            public mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            /// Uniform in (0, 1).
            public mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992.0 }
            /// Standard normal (Box–Muller; two uniforms per value).
            public mutating func normal() -> Double {
                let u1 = uniform(), u2 = uniform()
                return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * Double.pi * u2)
            }
            public mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
        }

        /// Seed of replicate `r` of the experiment `name` (FNV-1a 64 of `base|name|r`).
        public static func streamSeed(_ base: UInt64, _ name: String, _ r: Int) -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in "\(base)|\(name)|\(r)".utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
            return h
        }

        // MARK: - Synthetic series

        public struct Scenario: Codable, Equatable, Sendable {
            public var days = 200
            /// AR(1) coefficient of the daily noise; innovations are scaled by `sqrt(1 - φ²)` so the marginal SD is 1.
            public var phi = 0.0
            public var stepDay: Int?
            /// Step size in marginal-SD units.
            public var stepSigma = 0.0
            public var driftStartDay: Int?
            /// Linear drift per day in marginal-SD units.
            public var driftSigmaPerDay = 0.0
            public var artifactDays: [Int] = []
            public var artifactSigma = 8.0
            /// Independent probability that a day has no value (artifact days are never missing).
            public var missingRate = 0.0
            /// Every value identical (zero spread).
            public var constant = false
            public init() {}
        }

        /// Days in marginal-SD units on the transformed scale; nil = missing. The same seed gives the same noise
        /// and the same missing days whatever the step / drift / artifact settings (paired comparisons).
        public static func generate(_ s: Scenario, seed: UInt64) -> [Double?] {
            var g = SeededGenerator(seed: seed)
            let innovation = max(0, 1 - s.phi * s.phi).squareRoot()
            var e = g.normal()
            var out: [Double?] = []
            out.reserveCapacity(s.days)
            for d in 0..<max(0, s.days) {
                if d > 0 { e = s.phi * e + innovation * g.normal() }
                let missingDraw = g.uniform()
                var x = s.constant ? 0 : e
                if let sd = s.stepDay, d >= sd { x += s.stepSigma }
                if let dd = s.driftStartDay, d >= dd { x += s.driftSigmaPerDay * Double(d - dd + 1) }
                let artifact = s.artifactDays.contains(d)
                if artifact { x += s.artifactSigma }
                out.append(!artifact && missingDraw < s.missingRate ? nil : x)
            }
            return out
        }

        /// How synthetic SD units map to a series.
        public struct SeriesSpec: Codable, Equatable, Sendable {
            public var seriesKey: String
            public var regimeKey = "synthetic"
            public var units: String
            /// Center and SD on the series' transformed scale.
            public var center: Double
            public var sigma: Double
            /// Original-unit rounding resolution (e.g. 1 bpm); 0 = none.
            public var resolution: Double
            public var firstDay = "2025-01-01"
            public init(seriesKey: String, units: String, center: Double, sigma: Double, resolution: Double = 0) {
                self.seriesKey = seriesKey; self.units = units; self.center = center; self.sigma = sigma
                self.resolution = resolution
            }
            /// Nightly RMSSD: 45 ms, day-to-day SD 0.12 on the ln scale (the order of the ~12 % typical error
            /// Buchheit 2014 reports for resting Ln rMSSD; a modelling choice, not a WHOOP estimate).
            public static let rmssd = SeriesSpec(seriesKey: "hrv_rmssd.sleep_night", units: "ms",
                                                 center: Foundation.log(45), sigma: 0.12)
            /// Nightly resting HR: 55 bpm, SD 1.2 bpm, integer bpm (the scale floor binds often).
            public static let restingHR = SeriesSpec(seriesKey: "resting_hr.sleep_night", units: "bpm",
                                                     center: 55, sigma: 1.2, resolution: 1)
        }

        /// Original-unit value of a synthetic day.
        static func originalValue(_ x: Double, spec: SeriesSpec, log: Bool) -> Double {
            var v = log ? exp(spec.center + spec.sigma * x) : spec.center + spec.sigma * x
            if spec.resolution > 0 { v = (v / spec.resolution).rounded() * spec.resolution }
            return v
        }

        /// The synthetic days as daily values (one per present day, consecutive calendar days from `firstDay`).
        public static func dailyValues(_ xs: [Double?], spec: SeriesSpec, mode: ProcessingMode = .retrospective,
                                       reference: ReferenceConfig = .init()) -> [DailyValue] {
            guard let first = ContextReferences.dayNumber(spec.firstDay) else { return [] }
            let log = ContextReferences.isLog(spec.seriesKey, config: reference)
            return xs.enumerated().compactMap { d, x in
                guard let x else { return nil }
                return DailyValue(day: ContextReferences.dayKey(first + d), seriesKey: spec.seriesKey,
                                  regimeKey: spec.regimeKey, metric: nil, value: originalValue(x, spec: spec, log: log),
                                  units: spec.units, supportCount: 1, supportUnit: "night", supportS: 28_800,
                                  mode: mode, finality: .final, sourceIds: ["synthetic@\(d)"])
            }
        }

        static func points(_ xs: [Double?], spec: SeriesSpec, reference: ReferenceConfig) -> [ContextReferences.RefPoint] {
            guard let first = ContextReferences.dayNumber(spec.firstDay) else { return [] }
            let log = ContextReferences.isLog(spec.seriesKey, config: reference)
            return xs.enumerated().compactMap { d, x in
                guard let x else { return nil }
                let v = originalValue(x, spec: spec, log: log)
                guard let tx = ContextReferences.forward(v, log: log) else { return nil }
                return ContextReferences.RefPoint(dayNum: first + d, day: ContextReferences.dayKey(first + d),
                                                  value: v, x: tx)
            }
        }

        /// A whole series processed forward in time by the production path, with the frozen reference the
        /// production rule would register (usable only after its selection window).
        struct SeriesRun {
            var analysis: ChangeDetection.SegmentAnalysis
            var frozen: FrozenReference?
            var frozenRuns: [ChangeDetection.FrozenRun]
            var firstDayNum: Int
            func dayIndex(_ scoreIdx: Int) -> Int { analysis.scores[scoreIdx].dayNum - firstDayNum }
        }

        static func run(_ xs: [Double?], spec: SeriesSpec, change: ChangeConfig,
                        reference: ReferenceConfig) -> SeriesRun {
            let pts = points(xs, spec: spec, reference: reference)
            let first = ContextReferences.dayNumber(spec.firstDay) ?? 0
            let frozen = ContextReferences.frozenSelection(pts, config: reference).flatMap {
                ContextReferences.makeFrozen($0, seriesKey: spec.seriesKey, regimeKey: spec.regimeKey,
                                             createdForDay: $0.last!.day, policyFingerprint: "evaluation",
                                             config: reference)
            }
            let analysis = ChangeDetection.analyze(points: pts, windowStart: first, todayNum: pts.last?.dayNum ?? first,
                                                   frozen: frozen, boundaryDays: [], seriesKey: spec.seriesKey,
                                                   change: change, reference: reference)
            return SeriesRun(analysis: analysis, frozen: frozen,
                             frozenRuns: ChangeDetection.frozenRuns(analysis.scores, change: change),
                             firstDayNum: first)
        }

        static func primaryName(_ change: ChangeConfig) -> String {
            change.detector == "persistence" ? "persistence" : "cusum"
        }

        // MARK: - Bootstrap

        /// Percentile bootstrap of `statistic` over independent units (replicate series).
        public static func percentileBootstrapCI(_ values: [Double], statistic: ([Double]) -> Double?,
                                                 resamples: Int, level: Double = 0.95,
                                                 seed: UInt64) -> (lo: Double, hi: Double)? {
            guard !values.isEmpty, resamples > 0 else { return nil }
            var g = SeededGenerator(seed: seed)
            var stats: [Double] = []
            stats.reserveCapacity(resamples)
            for _ in 0..<resamples {
                let sample = (0..<values.count).map { _ in values[g.below(values.count)] }
                if let s = statistic(sample), s.isFinite { stats.append(s) }
            }
            guard let lo = RobustStats.quantile(stats, (1 - level) / 2),
                  let hi = RobustStats.quantile(stats, 1 - (1 - level) / 2) else { return nil }
            return (lo, hi)
        }

        /// Stationary bootstrap (Politis & Romano 1994) of the mean of dependent per-week values. Each resample
        /// concatenates blocks of geometric length (mean `meanBlock`) starting at a uniform week of a uniformly
        /// chosen independent unit and wrapping circularly inside that unit, until the original total is reached.
        public static func stationaryBootstrapMeanCI(_ units: [[Double]], meanBlock: Double, resamples: Int,
                                                     level: Double = 0.95,
                                                     seed: UInt64) -> (lo: Double, hi: Double)? {
            let us = units.filter { !$0.isEmpty }
            let total = us.reduce(0) { $0 + $1.count }
            guard total > 0, resamples > 0 else { return nil }
            var g = SeededGenerator(seed: seed)
            let p = 1 / max(1, meanBlock)
            var means: [Double] = []
            means.reserveCapacity(resamples)
            for _ in 0..<resamples {
                var sum = 0.0, count = 0, u = 0, pos = 0, fresh = true
                while count < total {
                    if fresh { u = g.below(us.count); pos = g.below(us[u].count) } else { pos = (pos + 1) % us[u].count }
                    sum += us[u][pos]; count += 1
                    fresh = g.uniform() < p
                }
                means.append(sum / Double(total))
            }
            guard let lo = RobustStats.quantile(means, (1 - level) / 2),
                  let hi = RobustStats.quantile(means, 1 - (1 - level) / 2) else { return nil }
            return (lo, hi)
        }

        // MARK: - Null behaviour (false episodes)

        public struct RateEstimate: Equatable, Sendable {
            public var perWeek: Double
            public var ciLow: Double
            public var ciHigh: Double
            public var weeks: Int
            public var events: Int
        }

        public struct NullResult: Equatable, Sendable {
            public var phi: Double
            public var missingRate: Double
            public var replicates: Int
            /// Persistent-shift alarms of the configured detector.
            public var primary: RateEstimate
            /// Persistent-shift alarms of the other detector.
            public var alternative: RateEstimate
            /// Frozen-reference persistence firings.
            public var frozen: RateEstimate
            /// Transient excursions (|z| ≥ deviationZ), including those inside recurring clusters.
            public var excursions: RateEstimate
            public var recurring: RateEstimate
            /// Share of replicates with at least one primary alarm in their first 90 monitored days.
            public var primaryAlarmIn90DaysShare: Double
        }

        static func rate(_ weekly: [[Double]], resamples: Int, seed: UInt64) -> RateEstimate {
            let weeks = weekly.reduce(0) { $0 + $1.count }
            let events = weekly.reduce(0.0) { $0 + $1.reduce(0, +) }
            let ci = stationaryBootstrapMeanCI(weekly, meanBlock: 4, resamples: resamples, seed: seed)
            return RateEstimate(perWeek: weeks == 0 ? 0 : events / Double(weeks), ciLow: ci?.lo ?? 0,
                                ciHigh: ci?.hi ?? 0, weeks: weeks, events: Int(events))
        }

        /// False episodes per week on series with no change (null), counted after `burnIn` days.
        public static func evaluateNull(phi: Double, replicates: Int, days: Int = 400, burnIn: Int = 35,
                                        missingRate: Double = 0, spec: SeriesSpec = .rmssd,
                                        change: ChangeConfig = .init(), reference: ReferenceConfig = .init(),
                                        resamples: Int = 500, seed: UInt64) -> NullResult {
            var s = Scenario(); s.days = days; s.phi = phi; s.missingRate = missingRate
            let nWeeks = max(0, (days - burnIn) / 7)
            var p: [[Double]] = [], a: [[Double]] = [], f: [[Double]] = [], e: [[Double]] = [], r: [[Double]] = []
            var early = 0
            let name = primaryName(change)
            for rep in 0..<replicates {
                let sr = run(generate(s, seed: streamSeed(seed, "null|\(phi)|\(missingRate)", rep)), spec: spec,
                             change: change, reference: reference)
                var wp = [Double](repeating: 0, count: nWeeks), wa = wp, wf = wp, we = wp, wr = wp
                func bin(_ day: Int, _ w: inout [Double], _ n: Double = 1) {
                    let k = (day - burnIn) / 7
                    if day >= burnIn && k < nWeeks { w[k] += n }
                }
                var earlyHit = false
                for d in sr.analysis.drafts where d.state == .persistentShift && d.detector == name {
                    if let al = d.alarmIdx {
                        let day = sr.dayIndex(al)
                        bin(day, &wp)
                        if day >= burnIn && day < burnIn + 90 { earlyHit = true }
                    }
                }
                if earlyHit { early += 1 }
                for d in sr.analysis.alternative { if let al = d.alarmIdx { bin(sr.dayIndex(al), &wa) } }
                for fr in sr.frozenRuns { bin(sr.dayIndex(fr.alarmIdx), &wf) }
                for d in sr.analysis.drafts {
                    switch d.state {
                    case .transientDeviation: bin(sr.dayIndex(d.startIdx), &we)
                    case .recurringEpisode:
                        bin(sr.dayIndex(d.startIdx), &we, Double(d.occurrences))
                        bin(sr.dayIndex(d.alarmIdx ?? d.startIdx), &wr)
                    default: break
                    }
                }
                p.append(wp); a.append(wa); f.append(wf); e.append(we); r.append(wr)
            }
            let base = streamSeed(seed, "null-bootstrap|\(phi)|\(missingRate)", 0)
            return NullResult(phi: phi, missingRate: missingRate, replicates: replicates,
                              primary: rate(p, resamples: resamples, seed: base),
                              alternative: rate(a, resamples: resamples, seed: base &+ 1),
                              frozen: rate(f, resamples: resamples, seed: base &+ 2),
                              excursions: rate(e, resamples: resamples, seed: base &+ 3),
                              recurring: rate(r, resamples: resamples, seed: base &+ 4),
                              primaryAlarmIn90DaysShare: replicates == 0 ? 0 : Double(early) / Double(replicates))
        }

        // MARK: - Step changes (detection delay, missed changes, adaptation)

        public struct DelaySummary: Equatable, Sendable {
            /// Raised an alarm within the horizon, or an earlier same-direction alarm was still sustained at the step.
            public var detectedShare: Double
            /// Share already in a same-direction alarm (raised before the step) when the step happened; no delay.
            public var alreadyFlaggedShare: Double
            public var medianDelay: Double?
            public var p25: Double?
            public var p75: Double?
            public var p90: Double?
            public var medianDelayCI: (lo: Double, hi: Double)?
            public var missedShareCI: (lo: Double, hi: Double)?
            public var missedShare: Double { 1 - detectedShare }
            public static func == (a: DelaySummary, b: DelaySummary) -> Bool {
                a.detectedShare == b.detectedShare && a.alreadyFlaggedShare == b.alreadyFlaggedShare
                    && a.medianDelay == b.medianDelay && a.p25 == b.p25
                    && a.p75 == b.p75 && a.p90 == b.p90 && a.medianDelayCI?.lo == b.medianDelayCI?.lo
                    && a.medianDelayCI?.hi == b.medianDelayCI?.hi && a.missedShareCI?.lo == b.missedShareCI?.lo
                    && a.missedShareCI?.hi == b.missedShareCI?.hi
            }
        }

        public struct StepResult: Equatable, Sendable {
            public var phi: Double
            public var magnitudeSigma: Double
            public var missingRate: Double
            public var replicates: Int
            public var horizonDays: Int
            public var primary: DelaySummary
            public var alternative: DelaySummary
            public var frozen: DelaySummary
            /// Share of replicates whose median |rolling z| over days step+36…step+42 is below 1 (rolling adapted).
            public var rollingAdaptedShare: Double
            /// Share whose median frozen z over the same days is beyond 2 in the step direction (frozen visible).
            public var frozenVisibleShare: Double
        }

        /// `delays[i]`: days from the step to the alarm, `-1` when already flagged at the step, nil when missed.
        static func summarize(_ delays: [Double?], horizon: Int, resamples: Int, seed: UInt64) -> DelaySummary {
            let detected = delays.compactMap { $0 }.filter { $0 >= 0 }
            let flagged = delays.compactMap { $0 }.filter { $0 < 0 }.count
            let n = Double(max(1, delays.count))
            let missed = delays.map { $0 == nil ? 1.0 : 0.0 }
            return DelaySummary(
                detectedShare: Double(detected.count + flagged) / n, alreadyFlaggedShare: Double(flagged) / n,
                medianDelay: RobustStats.median(detected),
                p25: RobustStats.quantile(detected, 0.25), p75: RobustStats.quantile(detected, 0.75),
                p90: RobustStats.quantile(detected, 0.90),
                medianDelayCI: percentileBootstrapCI(detected, statistic: { RobustStats.median($0) },
                                                     resamples: resamples, seed: seed),
                missedShareCI: percentileBootstrapCI(missed, statistic: { RobustStats.mean($0) },
                                                     resamples: resamples, seed: seed &+ 7))
        }

        /// Sustained step of `magnitudeSigma` at day `stepDay`; detection = first alarm in the step direction within
        /// `horizon` days of the step (delay in days from the step).
        public static func evaluateStep(phi: Double, magnitudeSigma: Double, replicates: Int, stepDay: Int = 70,
                                        horizon: Int = 28, missingRate: Double = 0, spec: SeriesSpec = .rmssd,
                                        change: ChangeConfig = .init(), reference: ReferenceConfig = .init(),
                                        resamples: Int = 500, seed: UInt64) -> StepResult {
            var s = Scenario(); s.days = stepDay + 63; s.phi = phi; s.stepDay = stepDay; s.stepSigma = magnitudeSigma
            s.missingRate = missingRate
            let dir = magnitudeSigma >= 0 ? 1 : -1
            let name = primaryName(change)
            var dp: [Double?] = [], da: [Double?] = [], df: [Double?] = []
            var adapted = 0, visible = 0
            /// (alarm day, last sustained day) pairs → delay, -1 (already flagged at the step) or nil (missed).
            func first(_ alarms: [(Int, Int)]) -> Double? {
                if let d = alarms.map(\.0).filter({ $0 >= stepDay && $0 < stepDay + horizon }).min() {
                    return Double(d - stepDay)
                }
                return alarms.contains { $0.0 < stepDay && $0.1 >= stepDay } ? -1 : nil
            }
            for rep in 0..<replicates {
                let sr = run(generate(s, seed: streamSeed(seed, "step|\(phi)|\(missingRate)", rep)), spec: spec,
                             change: change, reference: reference)
                dp.append(first(sr.analysis.drafts.filter {
                    $0.state == .persistentShift && $0.detector == name && $0.direction == dir
                }.compactMap { d in d.alarmIdx.map { (sr.dayIndex($0), sr.dayIndex(d.lastIdx)) } }))
                da.append(first(sr.analysis.alternative.filter { $0.direction == dir }
                    .compactMap { d in d.alarmIdx.map { (sr.dayIndex($0), sr.dayIndex(d.lastIdx)) } }))
                df.append(first(sr.frozenRuns.filter { $0.direction == dir }
                    .map { (sr.dayIndex($0.alarmIdx), sr.dayIndex($0.lastIdx)) }))
                let late = sr.analysis.scores.filter {
                    let d = $0.dayNum - sr.firstDayNum
                    return d >= stepDay + 36 && d <= stepDay + 42
                }
                if let m = RobustStats.median(late.compactMap(\.rollingZ)), abs(m) < 1 { adapted += 1 }
                if let m = RobustStats.median(late.compactMap(\.frozenZ)), Double(dir) * m >= 2 { visible += 1 }
            }
            let base = streamSeed(seed, "step-bootstrap|\(phi)|\(magnitudeSigma)|\(missingRate)", 0)
            let n = Double(max(1, replicates))
            return StepResult(phi: phi, magnitudeSigma: magnitudeSigma, missingRate: missingRate,
                              replicates: replicates, horizonDays: horizon,
                              primary: summarize(dp, horizon: horizon, resamples: resamples, seed: base),
                              alternative: summarize(da, horizon: horizon, resamples: resamples, seed: base &+ 11),
                              frozen: summarize(df, horizon: horizon, resamples: resamples, seed: base &+ 23),
                              rollingAdaptedShare: Double(adapted) / n, frozenVisibleShare: Double(visible) / n)
        }

        // MARK: - Gradual drift (frozen vs rolling visibility, raw trend)

        public struct DriftResult: Equatable, Sendable {
            public var phi: Double
            public var perDaySigma: Double
            public var driftDays: Int
            public var replicates: Int
            /// Medians over replicates of the median z over the last 7 days.
            public var finalRollingZ: Double
            public var finalFrozenZ: Double
            /// Share of replicates whose episode output on the last day contains an ongoing persistent shift in
            /// the drift direction (any detector), and the share where it came from the frozen reference.
            public var ongoingPersistentShare: Double
            public var frozenSourcedShare: Double
            public var primaryAlarmDuringDriftShare: Double
            /// Median of (reported Theil–Sen trend / true trend).
            public var trendRatio: Double
        }

        /// Linear drift of `perDaySigma` per day starting at day `startDay` for `driftDays` days; read through the
        /// public `ChangeDetection.episodes` at the last day (90-day window), as a document would show it.
        public static func evaluateDrift(phi: Double, perDaySigma: Double, replicates: Int, startDay: Int = 70,
                                         driftDays: Int = 60, spec: SeriesSpec = .rmssd,
                                         change: ChangeConfig = .init(), reference: ReferenceConfig = .init(),
                                         seed: UInt64) -> DriftResult {
            var s = Scenario(); s.days = startDay + driftDays; s.phi = phi; s.driftStartDay = startDay
            s.driftSigmaPerDay = perDaySigma
            let dir = perDaySigma >= 0 ? 1 : -1
            let name = primaryName(change)
            var rz: [Double] = [], fz: [Double] = [], ratios: [Double] = []
            var ongoing = 0, frozenSourced = 0, alarmed = 0
            let log = ContextReferences.isLog(spec.seriesKey, config: reference)
            for rep in 0..<replicates {
                let xs = generate(s, seed: streamSeed(seed, "drift|\(phi)", rep))
                let r = run(xs, spec: spec, change: change, reference: reference)
                let last7 = r.analysis.scores.suffix(7)
                if let m = RobustStats.median(last7.compactMap(\.rollingZ)) { rz.append(m) }
                if let m = RobustStats.median(last7.compactMap(\.frozenZ)) { fz.append(m) }
                if r.analysis.drafts.contains(where: {
                    $0.state == .persistentShift && $0.detector == name && $0.direction == dir
                        && ($0.alarmIdx.map { r.dayIndex($0) >= startDay } ?? false)
                }) { alarmed += 1 }
                let values = dailyValues(xs, spec: spec, reference: reference)
                guard let today = values.last else { continue }
                let eps = ChangeDetection.episodes(today: [today], history: Array(values.dropLast()),
                                                   frozen: r.frozen.map { [$0] } ?? [], boundaries: [],
                                                   day: today.day, mode: .retrospective, finality: .final,
                                                   policyFingerprint: "evaluation", change: change,
                                                   reference: reference)
                if let e = eps.first(where: { $0.state == .persistentShift && $0.ongoing && $0.direction == dir }) {
                    ongoing += 1
                    if e.detector == "frozen_persistence" || e.reasons.contains(ChangeDetection.rollingAdaptedFrozenDeviationPersists) {
                        frozenSourced += 1
                    }
                }
                // True slope in original units per week at the window's midpoint (ln series: d exp / dt).
                if let trend = eps.compactMap(\.trendPerWeek).first {
                    let mid = Double(driftDays / 2 + 1) * perDaySigma
                    let truth = log ? exp(spec.center + spec.sigma * mid) * spec.sigma * perDaySigma * 7
                                    : spec.sigma * perDaySigma * 7
                    if truth != 0 { ratios.append(trend / truth) }
                }
            }
            let n = Double(max(1, replicates))
            return DriftResult(phi: phi, perDaySigma: perDaySigma, driftDays: driftDays, replicates: replicates,
                               finalRollingZ: RobustStats.median(rz) ?? 0, finalFrozenZ: RobustStats.median(fz) ?? 0,
                               ongoingPersistentShare: Double(ongoing) / n, frozenSourcedShare: Double(frozenSourced) / n,
                               primaryAlarmDuringDriftShare: Double(alarmed) / n,
                               trendRatio: RobustStats.median(ratios) ?? 0)
        }

        // MARK: - Isolated artifacts

        public struct ArtifactResult: Equatable, Sendable {
            public var phi: Double
            public var magnitudeSigma: Double
            public var replicates: Int
            /// The artifact day starts or sits in a transient / recurring excursion and in no persistent episode.
            public var transientShare: Double
            /// A primary persistent alarm within 14 days of the artifact (and the same with no artifact, paired).
            public var persistentShare: Double
            public var persistentShareWithoutArtifact: Double
            /// Median over replicates of the largest |rolling center (with) − rolling center (without)| over the
            /// 28 days after the artifact, in SD units (reference contamination).
            public var maxCenterShiftSigma: Double
            /// Median over replicates of the largest scale ratio (with / without) over the same days.
            public var maxScaleRatio: Double
            /// The stored daily value equals the raw artifact value in every replicate (raw preserved).
            public var rawPreserved: Bool
        }

        public static func evaluateArtifact(phi: Double, magnitudeSigma: Double, replicates: Int,
                                            artifactDay: Int = 80, spec: SeriesSpec = .rmssd,
                                            change: ChangeConfig = .init(), reference: ReferenceConfig = .init(),
                                            seed: UInt64) -> ArtifactResult {
            var with = Scenario(); with.days = artifactDay + 40; with.phi = phi
            with.artifactDays = [artifactDay]; with.artifactSigma = magnitudeSigma
            var without = with; without.artifactDays = []
            let name = primaryName(change)
            var transient = 0, persistent = 0, persistentBase = 0
            var shifts: [Double] = [], ratios: [Double] = []
            var raw = true
            let log = ContextReferences.isLog(spec.seriesKey, config: reference)
            for rep in 0..<replicates {
                let sd = streamSeed(seed, "artifact|\(phi)", rep)
                let xa = generate(with, seed: sd), xb = generate(without, seed: sd)
                let a = run(xa, spec: spec, change: change, reference: reference)
                let b = run(xb, spec: spec, change: change, reference: reference)
                let idx = a.analysis.scores.firstIndex { $0.dayNum - a.firstDayNum == artifactDay }
                if let idx {
                    let expected = originalValue(xa[artifactDay]!, spec: spec, log: log)
                    if a.analysis.scores[idx].value != expected { raw = false }
                    let inPersistent = a.analysis.drafts.contains {
                        $0.state == .persistentShift && idx >= $0.startIdx && idx <= $0.lastIdx
                    }
                    let inExcursion = a.analysis.drafts.contains {
                        ($0.state == .transientDeviation || $0.state == .recurringEpisode)
                            && idx >= $0.startIdx && idx <= $0.lastIdx
                    }
                    if inExcursion && !inPersistent { transient += 1 }
                }
                func alarmed(_ r: SeriesRun) -> Bool {
                    r.analysis.drafts.contains {
                        $0.state == .persistentShift && $0.detector == name
                            && ($0.alarmIdx.map { (artifactDay...(artifactDay + 14)).contains(r.dayIndex($0)) } ?? false)
                    }
                }
                if alarmed(a) { persistent += 1 }
                if alarmed(b) { persistentBase += 1 }
                var maxShift = 0.0, maxRatio = 1.0
                for (sa, sb) in zip(a.analysis.scores, b.analysis.scores) {
                    let d = sa.dayNum - a.firstDayNum
                    guard d > artifactDay && d <= artifactDay + 28, let ca = sa.rollingCenterX,
                          let cb = sb.rollingCenterX, let ka = sa.rollingScale, let kb = sb.rollingScale else { continue }
                    maxShift = max(maxShift, abs(ca - cb) / spec.sigma)
                    maxRatio = max(maxRatio, ka / kb)
                }
                shifts.append(maxShift); ratios.append(maxRatio)
            }
            let n = Double(max(1, replicates))
            return ArtifactResult(phi: phi, magnitudeSigma: magnitudeSigma, replicates: replicates,
                                  transientShare: Double(transient) / n, persistentShare: Double(persistent) / n,
                                  persistentShareWithoutArtifact: Double(persistentBase) / n,
                                  maxCenterShiftSigma: RobustStats.median(shifts) ?? 0,
                                  maxScaleRatio: RobustStats.median(ratios) ?? 1, rawPreserved: raw)
        }

        // MARK: - Recent window (trajectory view)

        public struct RecentWindowResult: Equatable, Sendable {
            public var windowDays: Int
            /// SD of the recent center under the null (SD units) — its noise.
            public var nullCenterSD: Double
            /// Median days after a 2-SD step until the recent center has moved ≥ 1 SD.
            public var daysToFollowStep: Double?
        }

        public static func evaluateRecentWindow(windowDays: Int, phi: Double, replicates: Int,
                                                reference base: ReferenceConfig = .init(),
                                                seed: UInt64) -> RecentWindowResult {
            var reference = base
            reference.recentWindowDays = windowDays
            reference.recentMinDays = min(base.recentMinDays, windowDays)
            let spec = SeriesSpec(seriesKey: "synthetic.identity", units: "sd", center: 0, sigma: 1)
            var centers: [Double] = [], follow: [Double] = []
            let stepDay = 60
            for rep in 0..<replicates {
                var s = Scenario(); s.days = 120; s.phi = phi
                let sd = streamSeed(seed, "recent|\(phi)", rep)
                let null = points(generate(s, seed: sd), spec: spec, reference: reference)
                s.stepDay = stepDay; s.stepSigma = 2
                let step = points(generate(s, seed: sd), spec: spec, reference: reference)
                func center(_ pts: [ContextReferences.RefPoint], _ t: Int) -> Double? {
                    let w = pts.filter { $0.dayNum >= t - windowDays && $0.dayNum <= t - 1 }
                    guard w.count >= reference.recentMinDays else { return nil }
                    return ContextReferences.stats(w, seriesKey: spec.seriesKey, estimator: "median_mad",
                                                   config: reference).center
                }
                let first = null.first!.dayNum
                for t in (first + 30)..<(first + stepDay) { if let c = center(null, t) { centers.append(c) } }
                for k in 0..<40 {
                    if let c = center(step, first + stepDay + k), c >= 1 { follow.append(Double(k)); break }
                }
            }
            return RecentWindowResult(windowDays: windowDays, nullCenterSD: RobustStats.standardDeviation(centers) ?? 0,
                                      daysToFollowStep: RobustStats.median(follow))
        }

        // MARK: - CUSUM arithmetic check (known parameters)

        /// Mean days to the first two-sided alarm of the production CUSUM fed the TRUE standardized values (no
        /// reference estimation, no autocorrelation adjustment, no clamp): reproduces the ARL0 values of research
        /// note 8 (≈ 168–172 at φ = 0, ≈ 54 at φ = 0.3, ≈ 35 at φ = 0.5 for k = 0.5, h = 4).
        public static func knownParameterARL(phi: Double, k: Double, h: Double, replicates: Int,
                                             maxDays: Int = 5000, seed: UInt64) -> (mean: Double, censored: Int) {
            var change = ChangeConfig()
            change.cusumK = k; change.cusumH = h; change.cusumClampZ = 1e9; change.cusumAutocorrelationAdjustment = false
            change.maxGapDays = Int.max / 4
            var total = 0.0, censored = 0
            var s = Scenario(); s.days = maxDays; s.phi = phi
            for rep in 0..<replicates {
                let xs = generate(s, seed: streamSeed(seed, "arl|\(phi)", rep))
                let scores = xs.enumerated().map { d, x in
                    ChangeDetection.DayScore(dayNum: d, day: "", value: x!, x: x!, rollingZ: x!, rollingCenterX: 0,
                                             rollingScale: 1, frozenZ: nil, phi: nil, resetBefore: nil)
                }
                let alarms = ChangeDetection.cusumDrafts(scores, scored: Array(scores.indices), change: change)
                    .compactMap(\.alarmIdx)
                if let first = alarms.min() { total += Double(first + 1) } else { total += Double(maxDays); censored += 1 }
            }
            return (total / Double(max(1, replicates)), censored)
        }

        // MARK: - Small-sample MAD factor

        /// Mean of `1.4826 * MAD` (with and without `madSmallSampleFactor`) over Gaussian samples of size n.
        public static func madFactorCheck(n: Int, replicates: Int, seed: UInt64) -> (corrected: Double, raw: Double) {
            var g = SeededGenerator(seed: seed)
            var c = 0.0, r = 0.0
            for _ in 0..<replicates {
                let xs = (0..<n).map { _ in g.normal() }
                let m = RobustStats.median(xs)!
                r += RobustStats.madScale(xs, center: m, smallSampleCorrection: false)!
                c += RobustStats.madScale(xs, center: m, smallSampleCorrection: true)!
            }
            return (c / Double(replicates), r / Double(replicates))
        }

        // MARK: - Sensitivity

        public struct Variant: Sendable {
            public var name: String
            public var change: ChangeConfig
            public var reference: ReferenceConfig
            public var spec: SeriesSpec
        }

        public static func sensitivityVariants() -> [Variant] {
            let c = ChangeConfig(), r = ReferenceConfig()
            func v(_ name: String, spec: SeriesSpec = .rmssd, _ f: (inout ChangeConfig, inout ReferenceConfig) -> Void) -> Variant {
                var cc = c, rr = r
                f(&cc, &rr)
                return Variant(name: name, change: cc, reference: rr, spec: spec)
            }
            return [
                v("default: AR-adjusted CUSUM k=0.25 h=7, clamp 2, rolling 28 d median/MAD") { _, _ in },
                v("AR-adjusted CUSUM k=0.25 h=6") { c, _ in c.cusumH = 6 },
                v("AR-adjusted CUSUM k=0.25 h=8") { c, _ in c.cusumH = 8 },
                v("AR-adjusted CUSUM k=0.5 h=5") { c, _ in c.cusumK = 0.5; c.cusumH = 5 },
                v("AR-adjusted CUSUM clamp 3") { c, _ in c.cusumClampZ = 3 },
                v("unadjusted CUSUM k=0.25 h=7") { c, _ in c.cusumAutocorrelationAdjustment = false },
                v("unadjusted classic CUSUM k=0.5 h=4, no clamp") { c, _ in
                    c.cusumAutocorrelationAdjustment = false; c.cusumK = 0.5; c.cusumH = 4; c.cusumClampZ = 1e6
                },
                v("AR-adjusted, no autocorrelation guard band") { c, _ in c.autocorrelationGuardDays = 1 },
                v("persistence 3 of 5, abs z ≥ 2") { c, _ in c.detector = "persistence" },
                v("persistence 4 of 7, abs z ≥ 2") { c, _ in c.detector = "persistence"; c.persistenceCount = 4; c.persistenceWindow = 7 },
                v("persistence 3 of 5, abs z ≥ 2.5") { c, _ in c.detector = "persistence"; c.persistenceZ = 2.5 },
                v("rolling 14 d (min 7)") { _, r in r.rollingWindowDays = 14 },
                v("rolling 42 d") { _, r in r.rollingWindowDays = 42 },
                v("winsorized mean/SD reference") { _, r in r.rollingEstimator = "winsorized_mean_sd" },
                v("no small-sample MAD factor") { _, r in r.smallSampleCorrection = false },
                v("frozen rule abs z ≥ 1.5, 5 of 7") { c, _ in c.frozenPersistenceZ = 1.5 },
                v("resting HR (integer bpm), floor 1 bpm (default)", spec: .restingHR) { _, _ in },
                v("resting HR, floor 0.5 bpm", spec: .restingHR) { _, r in
                    r.scaleFloors = r.scaleFloors.map { $0.seriesPrefix == "resting_hr." ? ScaleFloor(seriesPrefix: $0.seriesPrefix, floor: 0.5) : $0 }
                },
                v("resting HR, floor 2 bpm", spec: .restingHR) { _, r in
                    r.scaleFloors = r.scaleFloors.map { $0.seriesPrefix == "resting_hr." ? ScaleFloor(seriesPrefix: $0.seriesPrefix, floor: 2.0) : $0 }
                },
            ]
        }

        public struct SensitivityRow: Equatable, Sendable {
            public var name: String
            public var phi: Double
            public var null: NullResult
            public var step1: StepResult
            public var step2: StepResult
        }

        public static func sensitivity(phi: Double, replicates: Int, resamples: Int = 300,
                                       seed: UInt64) -> [SensitivityRow] {
            sensitivityVariants().map { v in
                SensitivityRow(name: v.name, phi: phi,
                               null: evaluateNull(phi: phi, replicates: replicates, spec: v.spec, change: v.change,
                                                  reference: v.reference, resamples: resamples, seed: seed),
                               step1: evaluateStep(phi: phi, magnitudeSigma: -1, replicates: replicates, spec: v.spec,
                                                   change: v.change, reference: v.reference, resamples: resamples,
                                                   seed: seed),
                               step2: evaluateStep(phi: phi, magnitudeSigma: -2, replicates: replicates, spec: v.spec,
                                                   change: v.change, reference: v.reference, resamples: resamples,
                                                   seed: seed))
            }
        }

        // MARK: - Report

        static func f(_ v: Double?, _ digits: Int = 2) -> String {
            guard let v, v.isFinite else { return "—" }
            return String(format: "%.\(digits)f", v)
        }
        static func ci(_ c: (lo: Double, hi: Double)?, _ digits: Int = 2) -> String {
            guard let c else { return "—" }
            return "\(f(c.lo, digits))–\(f(c.hi, digits))"
        }
        static func pct(_ v: Double) -> String { String(format: "%.0f %%", v * 100) }

        /// The markdown tables in `notes/statistics.md` (§ Evaluation results).
        public static func report(replicates: Int, sensitivityReplicates: Int, resamples: Int,
                                  seed: UInt64) -> String {
            var out: [String] = []
            out.append("Seed \(seed); \(replicates) replicate series per cell (\(sensitivityReplicates) in the sensitivity table); \(resamples) bootstrap resamples. Synthetic arithmetic checks only.")
            out.append("")
            out.append("**Null (no change), default policy, nightly ln RMSSD spec, 400 days, counted after day 35.** Rates per series-week, 95 % stationary-bootstrap interval (mean block 4 weeks).")
            out.append("")
            out.append("| φ | missing | CUSUM persistent / wk | persistence-rule / wk | frozen persistence / wk | excursions / wk | recurring / wk | ≥1 CUSUM alarm in 90 d |")
            out.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
            for (phi, miss) in [(0.0, 0.0), (0.3, 0.0), (0.5, 0.0), (0.3, 0.3)] {
                let r = evaluateNull(phi: phi, replicates: replicates, missingRate: miss, resamples: resamples, seed: seed)
                func cell(_ e: RateEstimate) -> String { "\(f(e.perWeek, 3)) (\(f(e.ciLow, 3))–\(f(e.ciHigh, 3)))" }
                out.append("| \(f(phi, 1)) | \(pct(miss)) | \(cell(r.primary)) | \(cell(r.alternative)) | \(cell(r.frozen)) | \(cell(r.excursions)) | \(cell(r.recurring)) | \(pct(r.primaryAlarmIn90DaysShare)) |")
            }
            out.append("")
            out.append("**Sustained step down at day 70, horizon 28 days.** Delay in days from the step among detected series; 95 % percentile bootstrap over replicates.")
            out.append("")
            out.append("| φ | step | missing | CUSUM missed | CUSUM delay median (CI) | p25–p75 / p90 | persistence-rule missed / median | frozen-rule missed / median | rolling adapted by +42 d | frozen still ≥ 2 at +42 d |")
            out.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
            for (phi, m, miss) in [(0.0, -1.0, 0.0), (0.0, -2.0, 0.0), (0.3, -1.0, 0.0), (0.3, -2.0, 0.0),
                                   (0.5, -1.0, 0.0), (0.5, -2.0, 0.0), (0.3, -1.0, 0.3), (0.3, -2.0, 0.3)] {
                let r = evaluateStep(phi: phi, magnitudeSigma: m, replicates: replicates, missingRate: miss,
                                     resamples: resamples, seed: seed)
                out.append("| \(f(phi, 1)) | \(f(m, 0)) SD | \(pct(miss)) | \(pct(r.primary.missedShare)) (\(ci(r.primary.missedShareCI))) | \(f(r.primary.medianDelay, 1)) (\(ci(r.primary.medianDelayCI, 1))) | \(f(r.primary.p25, 0))–\(f(r.primary.p75, 0)) / \(f(r.primary.p90, 0)) | \(pct(r.alternative.missedShare)) / \(f(r.alternative.medianDelay, 1)) | \(pct(r.frozen.missedShare)) / \(f(r.frozen.medianDelay, 1)) | \(pct(r.rollingAdaptedShare)) | \(pct(r.frozenVisibleShare)) |")
            }
            out.append("")
            out.append("**Gradual drift down (0.05 SD/day for 60 days = 3 SD), read through `ChangeDetection.episodes` on the last day.**")
            out.append("")
            out.append("| φ | median rolling z (last 7 d) | median frozen z (last 7 d) | ongoing persistent shift | of which frozen-sourced | CUSUM alarmed during drift | reported trend / true trend |")
            out.append("| --- | --- | --- | --- | --- | --- | --- |")
            for phi in [0.0, 0.3, 0.5] {
                let r = evaluateDrift(phi: phi, perDaySigma: -0.05, replicates: replicates, seed: seed)
                out.append("| \(f(phi, 1)) | \(f(r.finalRollingZ)) | \(f(r.finalFrozenZ)) | \(pct(r.ongoingPersistentShare)) | \(pct(r.frozenSourcedShare)) | \(pct(r.primaryAlarmDuringDriftShare)) | \(f(r.trendRatio)) |")
            }
            out.append("")
            out.append("**Isolated artifact (one day +8 SD at day 80), paired with the same series without it.**")
            out.append("")
            out.append("| φ | artifact day → transient only | CUSUM alarm ≤ 14 d (with / without) | max rolling-center shift (SD) | max scale ratio | raw value preserved |")
            out.append("| --- | --- | --- | --- | --- | --- |")
            for phi in [0.0, 0.3, 0.5] {
                let r = evaluateArtifact(phi: phi, magnitudeSigma: 8, replicates: replicates, seed: seed)
                out.append("| \(f(phi, 1)) | \(pct(r.transientShare)) | \(pct(r.persistentShare)) / \(pct(r.persistentShareWithoutArtifact)) | \(f(r.maxCenterShiftSigma, 3)) | \(f(r.maxScaleRatio, 3)) | \(r.rawPreserved ? "yes" : "no") |")
            }
            out.append("")
            out.append("**Recent window (trajectory view), φ = 0.3.**")
            out.append("")
            out.append("| recent window | null SD of recent center (SD) | days until center follows a 2-SD step by ≥ 1 SD |")
            out.append("| --- | --- | --- |")
            for w in [3, 5, 7, 10] {
                let r = evaluateRecentWindow(windowDays: w, phi: 0.3, replicates: replicates, seed: seed)
                out.append("| \(w) d | \(f(r.nullCenterSD)) | \(f(r.daysToFollowStep, 1)) |")
            }
            out.append("")
            out.append("**CUSUM arithmetic check: known-parameter two-sided ARL0 (days to first false alarm), production CUSUM fed the true standardized values.** Research note 8: ≈ 168–172 (φ = 0), ≈ 54 (φ = 0.3), ≈ 35 (φ = 0.5) for k = 0.5, h = 4.")
            out.append("")
            out.append("| φ | k = 0.5, h = 4 | k = 0.25, h = 7 (unadjusted, unclamped) |")
            out.append("| --- | --- | --- |")
            for phi in [0.0, 0.3, 0.5] {
                let a = knownParameterARL(phi: phi, k: 0.5, h: 4, replicates: replicates, seed: seed)
                let b = knownParameterARL(phi: phi, k: 0.25, h: 7, replicates: replicates, seed: seed)
                out.append("| \(f(phi, 1)) | \(f(a.mean, 1)) | \(f(b.mean, 1)) |")
            }
            out.append("")
            out.append("**Small-sample MAD factor (Gaussian, mean of 1.4826·MAD; target 1.000).**")
            out.append("")
            out.append("| n | raw | corrected |")
            out.append("| --- | --- | --- |")
            for n in [3, 5, 7, 10, 14, 28] {
                let r = madFactorCheck(n: n, replicates: 20_000, seed: streamSeed(seed, "mad", n))
                out.append("| \(n) | \(f(r.raw, 3)) | \(f(r.corrected, 3)) |")
            }
            out.append("")
            out.append("**Sensitivity, φ = 0.3** (null false CUSUM-or-rule persistent episodes per week; 1-SD and 2-SD steps down, 28-day horizon).")
            out.append("")
            out.append("| variant | null / wk (CI) | frozen rule null / wk | 1 SD missed | 1 SD median delay | 2 SD missed | 2 SD median delay |")
            out.append("| --- | --- | --- | --- | --- | --- | --- |")
            for row in sensitivity(phi: 0.3, replicates: sensitivityReplicates, resamples: resamples, seed: seed) {
                out.append("| \(row.name) | \(f(row.null.primary.perWeek, 3)) (\(f(row.null.primary.ciLow, 3))–\(f(row.null.primary.ciHigh, 3))) | \(f(row.null.frozen.perWeek, 3)) | \(pct(row.step1.primary.missedShare)) | \(f(row.step1.primary.medianDelay, 1)) | \(pct(row.step2.primary.missedShare)) | \(f(row.step2.primary.medianDelay, 1)) |")
            }
            return out.joined(separator: "\n")
        }
    }
}
