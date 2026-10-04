import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// Bench.swift — replay a day through both estimators and look for the two properties that matter.
//
// The pure pieces (per-minute signals, run finding, bout metrics, checks) take plain arrays so they can be
// unit-tested on synthetic days. `run` is the only function that touches `AnalyticsEngine`.

enum Bench {

    // MARK: Constants shared with the legacy estimator

    /// `Calories.dayActiveHRRFraction`. That constant is internal to StrandAnalytics, so the harness keeps
    /// its own copy; `LegacyGateTests.testLegacyGateConstantMatchesTheEstimator` fails if the two ever drift.
    static let legacyDayGateFraction = 0.50

    static func legacyGateBpm(restingHR: Double, hrmax: Double) -> Double {
        restingHR + legacyDayGateFraction * (hrmax - restingHR)
    }

    // MARK: Model-free per-minute view of the day

    struct Streams {
        var hr: [HRSample]
        var gravity: [GravitySample]
        var steps: [StepSample]
    }

    /// The harness's own reading of one minute. Deliberately simple (a mean, a counter delta): it must be
    /// obviously correct, because it is the yardstick the estimator is held against.
    struct MinuteSignal: Equatable {
        var hrMean: Double?
        /// Step-counter ticks in the minute, `StepsCounter`'s plausibility-filtered increments.
        var cadence: Double?
        var dynMean: Double?
    }

    static func minuteSignals(_ s: Streams, dayStart: Int, minutes: Int, options: BenchOptions) -> [MinuteSignal] {
        var hrSum = [Double](repeating: 0, count: minutes)
        var hrN = [Int](repeating: 0, count: minutes)
        for x in s.hr where x.ts >= dayStart {
            let m = (x.ts - dayStart) / 60
            guard m < minutes else { continue }
            hrSum[m] += Double(x.bpm)
            hrN[m] += 1
        }
        var dynSum = [Double](repeating: 0, count: minutes)
        var dynN = [Int](repeating: 0, count: minutes)
        for x in s.gravity where x.ts >= dayStart {
            guard let d = x.dynAccel else { continue }
            let m = (x.ts - dayStart) / 60
            guard m < minutes else { continue }
            dynSum[m] += d
            dynN[m] += 1
        }
        var stepRows = [[StepSample]](repeating: [], count: minutes)
        for x in s.steps where x.ts >= dayStart {
            let m = (x.ts - dayStart) / 60
            guard m < minutes else { continue }
            stepRows[m].append(x)
        }
        var out = [MinuteSignal](repeating: MinuteSignal(), count: minutes)
        for m in 0..<minutes {
            if hrN[m] >= options.minHRRowsPerMinute { out[m].hrMean = hrSum[m] / Double(hrN[m]) }
            if dynN[m] >= 10 { out[m].dynMean = dynSum[m] / Double(dynN[m]) }
            if stepRows[m].count >= 20, let ticks = StepsCounter.stepsInWindow(stepRows[m]) {
                out[m].cadence = Double(ticks)
            }
        }
        return out
    }

    // MARK: Run finding

    /// Maximal runs of `true`, bridged across at most `gapTolerance` consecutive `false` minutes, kept when
    /// at least `minLength` minutes long (bridged gaps count toward the length). Each run starts and ends
    /// on a `true` minute.
    static func runs(of flags: [Bool], minLength: Int, gapTolerance: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        let n = flags.count
        while i < n {
            guard flags[i] else { i += 1; continue }
            var end = i          // index of the last `true` in the run
            var j = i + 1
            while j < n {
                if flags[j] { end = j; j += 1; continue }
                var k = j
                while k < n, !flags[k] { k += 1 }
                if k < n, k - j <= gapTolerance { end = k; j = k + 1 } else { break }
            }
            if end - i + 1 >= minLength { out.append(i..<(end + 1)) }
            i = end + 1
        }
        return out
    }

    // MARK: Bouts

    struct BoutContext {
        var dayStart: Int
        var profile: UserProfile
        var hrmax: Double
        /// What `analyzeDay` handed to `Calories`: nil when the day has no resting HR.
        var appRestingHR: Double?
        /// `appRestingHR`, or the 60 bpm `Calories` assumes when it is nil. The session threshold and the
        /// legacy gate are measured from this.
        var restingHR: Double
        var gateBpm: Double
        var hr: [HRSample]
        var signals: [MinuteSignal]
        var asleep: [Bool]
        var fusionMinutes: [Int: EnergyMinute]
    }

    /// Sustained locomotion (step cadence, or wrist motion on a day with no step counter) and sustained
    /// heart-rate sessions with motion behind them, found WITHOUT the estimator. Locomotion runs that sit
    /// mostly inside a session are reported once, as the session.
    static func findBouts(_ ctx: BoutContext, hasSteps: Bool, hasGravity: Bool, options: BenchOptions) -> [BoutRow] {
        let n = ctx.signals.count
        var out: [BoutRow] = []

        var sessionFlags = [Bool](repeating: false, count: n)
        if hasSteps || hasGravity {
            let hrrFloor = ctx.restingHR + options.sessionHRRFraction * (ctx.hrmax - ctx.restingHR)
            for m in 0..<n where !ctx.asleep[m] {
                let s = ctx.signals[m]
                guard let hr = s.hrMean, hr >= hrrFloor else { continue }
                let moving = (s.dynMean ?? 0) >= options.sessionMinDyn || (s.cadence ?? 0) >= 20
                sessionFlags[m] = moving
            }
        }
        let sessions = runs(of: sessionFlags, minLength: options.sessionMinutes, gapTolerance: 3)

        var moveFlags = [Bool](repeating: false, count: n)
        for m in 0..<n where !ctx.asleep[m] {
            let s = ctx.signals[m]
            if hasSteps {
                moveFlags[m] = (s.cadence ?? 0) >= options.cadenceMoving
            } else if hasGravity {
                moveFlags[m] = (s.dynMean ?? 0) >= options.dynMoving
            }
        }
        let locomotion = runs(of: moveFlags, minLength: options.minBoutMinutes, gapTolerance: options.gapToleranceMinutes)
            .filter { run in
                let overlap = sessions.reduce(0) { acc, s in
                    acc + max(0, min(run.upperBound, s.upperBound) - max(run.lowerBound, s.lowerBound))
                }
                return Double(overlap) < 0.5 * Double(run.count)
            }

        for r in sessions { if let b = metrics(r, kind: .session, ctx, options) { out.append(b) } }
        for r in locomotion { if let b = metrics(r, kind: .locomotion, ctx, options) { out.append(b) } }
        return out.sorted { $0.startTs < $1.startTs }
    }

    private static func metrics(_ r: Range<Int>, kind: BoutKind, _ ctx: BoutContext, _ options: BenchOptions) -> BoutRow? {
        let hrMins = r.compactMap { ctx.signals[$0].hrMean }
        guard Double(hrMins.count) >= options.minHRCoverage * Double(r.count), !hrMins.isEmpty else { return nil }
        let startTs = ctx.dayStart + r.lowerBound * 60
        let endTs = ctx.dayStart + r.upperBound * 60
        let window = ctx.hr.filter { $0.ts >= startTs && $0.ts < endTs }

        let legacy = Calories.estimateDayEnergy(window, profile: ctx.profile, hrmax: ctx.hrmax, restingHR: ctx.appRestingHR)
        let gross = Calories.estimateBoutCalories(window, profile: ctx.profile, hrmax: ctx.hrmax, restingHR: ctx.appRestingHR).0
        let ungatedActive = max(0, gross - legacy.restingKcal)

        var fusionActive = 0.0, metSum = 0.0, confSum = 0.0, n = 0
        for m in r {
            guard let em = ctx.fusionMinutes[ctx.dayStart + m * 60], em.covered, !em.isSleep else { continue }
            fusionActive += em.activeKcal
            metSum += em.met
            confSum += em.confidence
            n += 1
        }
        guard n > 0 else { return nil }

        let cad = r.compactMap { ctx.signals[$0].cadence }
        let dyn = r.compactMap { ctx.signals[$0].dynMean }
        let above = hrMins.filter { $0 >= ctx.gateBpm }.count
        return BoutRow(
            kind: kind, startTs: startTs, minutes: r.count,
            meanHR: hrMins.reduce(0, +) / Double(hrMins.count), maxMinuteHR: hrMins.max() ?? 0,
            fractionAboveGate: Double(above) / Double(hrMins.count),
            meanCadence: cad.isEmpty ? nil : cad.reduce(0, +) / Double(cad.count),
            meanDyn: dyn.isEmpty ? nil : dyn.reduce(0, +) / Double(dyn.count),
            legacyActiveKcal: legacy.activeKcal, ungatedActiveKcal: ungatedActive,
            fusionActiveKcal: fusionActive, fusionMeanMET: metSum / Double(n),
            fusionMeanConfidence: confSum / Double(n),
            band: kind == .locomotion ? options.locomotionMETBand : options.sessionMETBand)
    }

    // MARK: Replay one day

    /// The wearer's already-scored nights as pre-staged sessions (a single "light" segment each). The
    /// energy model only needs where the night starts and ends; handing `analyzeDay` the scored span keeps
    /// the replay from re-deriving sleep out of a stream that begins at local midnight, mid-night.
    static func providedSleep(_ rows: [DayBundle.SleepRow]) -> [SleepSession] {
        rows.compactMap { row in
            guard row.end > row.start else { return nil }
            return SleepSession(
                start: row.start, end: row.end, efficiency: 0.9,
                stages: [StageSegment(start: row.start, end: row.end, stage: "light")],
                restingHR: row.restingHr, avgHRV: nil)
        }
    }

    static func run(_ b: DayBundle, options: BenchOptions) throws -> DayRun {
        let hr = try StreamCodec.heartRate(b.hr)
        let gravity = try b.gravity.map(StreamCodec.gravity) ?? []
        let steps = try b.steps.map(StreamCodec.steps) ?? []
        return try run(day: b.day, tzOffsetSeconds: b.tzOffsetSeconds, dayStart: b.dayStart, asOf: b.asOf,
                       profile: b.profile, bundleRestingHR: b.restingHr, sleep: b.sleep,
                       streams: Streams(hr: hr, gravity: gravity, steps: steps), options: options)
    }

    static func run(day: String, tzOffsetSeconds: Int, dayStart: Int, asOf: Int?, profile p: DayBundle.Profile,
                    bundleRestingHR: Double?, sleep: [DayBundle.SleepRow], streams: Streams,
                    options: BenchOptions) throws -> DayRun {
        let profile = UserProfile(weightKg: p.weightKg, heightCm: p.heightCm, age: p.age, sex: p.sex,
                                  measuredRmrKcalPerDay: options.measuredRmr)
        let provided = providedSleep(sleep)
        let dayEnd = dayStart + 86_400
        let effectiveEnd = min(dayEnd, asOf ?? dayEnd)
        let elapsedMinutes = (effectiveEnd - dayStart + 59) / 60

        func analyze(_ model: EnergyModelChoice) -> AnalyticsEngine.DayResult {
            AnalyticsEngine.analyzeDay(
                day: day, hr: streams.hr, gravity: streams.gravity, steps: streams.steps,
                dayHr: streams.hr, daySteps: streams.steps, dayGravity: streams.gravity,
                profile: profile, tzOffsetSeconds: tzOffsetSeconds, providedSleep: provided,
                energyModel: model, energyAsOf: asOf)
        }
        let legacyResult = analyze(.legacyHR)
        let fusionResult = analyze(.fusion)
        guard let fusion = fusionResult.energy else {
            throw BundleError.malformed(stream: "fusion", item: -1)
        }

        // The day's resting HR and HRmax exactly as analyzeDay resolved them, so the replay below prices
        // the same inputs analyzeDay did. A day with no resting HR passes nil to `Calories` (which then
        // gates at a 60 bpm baseline AND drops the fitness-adjusted Keytel equation); substituting 60
        // here would price a different model than the app ran.
        let appRestingHR: Double? = fusionResult.daily.restingHr.map(Double.init)
        let restingHR = appRestingHR ?? 60
        let hrmax = StrainScorer.tanakaHRmax(age: p.age)
        let gate = legacyGateBpm(restingHR: restingHR, hrmax: hrmax)

        let legacy = Calories.estimateDayEnergy(streams.hr, profile: profile, hrmax: hrmax, restingHR: appRestingHR)
        let ungated = Calories.estimateBoutCalories(streams.hr, profile: profile, hrmax: hrmax, restingHR: appRestingHR).0

        let signals = minuteSignals(streams, dayStart: dayStart, minutes: elapsedMinutes, options: options)
        var fusionByStart: [Int: EnergyMinute] = [:]
        for m in fusion.minutes { fusionByStart[m.startTs] = m }
        var asleep = [Bool](repeating: false, count: elapsedMinutes)
        for m in 0..<elapsedMinutes { asleep[m] = fusionByStart[dayStart + m * 60]?.isSleep ?? false }

        let hasGravity = streams.gravity.contains { $0.dynAccel != nil }
        let hasSteps = !streams.steps.isEmpty
        let ctx = BoutContext(dayStart: dayStart, profile: profile, hrmax: hrmax, appRestingHR: appRestingHR,
                              restingHR: restingHR, gateBpm: gate, hr: streams.hr, signals: signals,
                              asleep: asleep, fusionMinutes: fusionByStart)
        let bouts = findBouts(ctx, hasSteps: hasSteps, hasGravity: hasGravity, options: options)

        let moving = movingMinutes(signals, asleep: asleep, hasSteps: hasSteps, hasGravity: hasGravity, options: options)
        let hrMinutes = signals.filter { $0.hrMean != nil }.count
        let sessionMinutes = bouts.filter { $0.kind == .session }.reduce(0) { $0 + $1.minutes }
        let aboveGateMinutes = zip(signals, asleep).filter { !$1 && ($0.hrMean ?? 0) >= gate }.count
        let lightDay = fusionResult.workouts.isEmpty && sessionMinutes == 0 && aboveGateMinutes < 10
            && moving < options.lightDayMaxMovingMinutes

        let estimatorMillis = timeEstimator(
            dayStart: dayStart, dayEnd: dayEnd, asOf: asOf, streams: streams, profile: profile,
            hrmax: hrmax, restingHR: appRestingHR, sessions: fusionResult.sleepSessions)

        return DayRun(
            day: day, dayStart: dayStart, tzOffsetSeconds: tzOffsetSeconds, partial: asOf != nil,
            elapsedMinutes: elapsedMinutes, hrMinutes: hrMinutes,
            hasGravity: hasGravity, hasSteps: hasSteps, restingHR: appRestingHR, hrmax: hrmax, gateBpm: gate,
            sleepMinutes: fusion.sleepMinutes, workoutsDetected: fusionResult.workouts.count,
            movingMinutes: moving, sessionMinutes: sessionMinutes,
            legacyResting: legacy.restingKcal, legacyActive: legacy.activeKcal,
            legacyReportedTotal: legacyResult.daily.activeKcalEst, ungatedTotal: ungated,
            fusion: fusion, fusionReportedTotal: fusionResult.daily.activeKcalEst,
            estimatorMillis: estimatorMillis, bouts: bouts, lightDay: lightDay, signals: signals,
            sleepSpans: fusionResult.sleepSessions
                .filter { $0.end >= dayStart && $0.end < dayEnd }
                .map { s in (start: (s.start - dayStart) / 60, end: (s.end - dayStart) / 60,
                             provided: provided.contains { $0.start == s.start && $0.end == s.end }) })
    }

    static func movingMinutes(_ signals: [MinuteSignal], asleep: [Bool], hasSteps: Bool, hasGravity: Bool,
                              options: BenchOptions) -> Int {
        var n = 0
        for (s, sleeping) in zip(signals, asleep) where !sleeping {
            if hasSteps { if (s.cadence ?? 0) >= options.cadenceMoving { n += 1 } }
            else if hasGravity { if (s.dynMean ?? 0) >= options.dynMoving { n += 1 } }
        }
        return n
    }

    /// Wall-clock cost of the estimator alone (best of three), release builds only meaningful.
    private static func timeEstimator(dayStart: Int, dayEnd: Int, asOf: Int?, streams: Streams, profile: UserProfile,
                                      hrmax: Double, restingHR: Double?, sessions: [SleepSession]) -> Double {
        let input = EnergyDayInput(
            dayStart: dayStart, dayEnd: dayEnd, asOf: asOf, hr: streams.hr, gravity: streams.gravity,
            steps: streams.steps, profile: profile, hrmax: hrmax, restingHR: restingHR,
            sleepIntervals: sessions.map { EnergyInterval(start: $0.start, end: $0.end) })
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = MetabolicEstimator.estimate(input)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            best = min(best, ms)
        }
        return best
    }
}
