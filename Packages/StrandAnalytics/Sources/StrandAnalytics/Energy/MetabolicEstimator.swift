import Foundation
import WhoopProtocol

// MetabolicEstimator.swift — the energy-fusion model for one day.
//
//   streams ──► minute signals ──► activity belief ──► activity-aware fusion ──► temporal filter
//                                                         (MET + sigma per minute)      │
//   RMR (measured, else equation) × all elapsed minutes ─────────────────────────────────┤
//                                                                                        ▼
//                                     day = resting (24 h, coverage-independent) + active (covered awake minutes)
//
// Resting and active energy are kept apart. Resting is RMR/1440 for EVERY elapsed minute, whether or not the
// strap was on: metabolism does not stop when the sensor does. Active is `max(0, MET - 1) * kcalPerMET` over
// the minutes that have evidence; a coverage gap contributes no active energy (it is never zero-filled into
// "sedentary" nor extrapolated from neighbours), and a gap is reported, not hidden.
//
// A workout is a labelled stretch of the same timeline, not a second source of energy: `workoutKcal` is the
// part of `activeKcal` inside workout windows and is never added to the total.

public enum MetabolicEstimator {

    // MARK: Resting metabolic rate

    /// 24 h resting energy. A measured RMR from indirect calorimetry wins when it is plausible; otherwise the
    /// population equation already used by `Calories` (revised Harris–Benedict, sex/age/height/weight).
    public static func resolveRMR(profile: UserProfile) -> (kcalPerDay: Double, source: RmrSource) {
        if let measured = profile.measuredRmrKcalPerDay, measured.isFinite, measured >= 800, measured <= 5000 {
            return (measured, .measured)
        }
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = Calories.resolveCoeffs(profile.sex)
        let perDay = Calories.restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age) * 86_400.0
        return (perDay, .equation)
    }

    /// kcal per minute per MET above rest: 3.5 ml O2/kg/min × weight × 5 kcal/L.
    public static func kcalPerMETMinute(weightKg: Double) -> Double {
        3.5 * (weightKg > 0 ? weightKg : 70.0) / 200.0
    }

    // MARK: Estimate

    public static func estimate(_ input: EnergyDayInput, config: EnergyConfig = EnergyConfig()) -> DayEnergy {
        let rmr = resolveRMR(profile: input.profile)
        let rmrPerMinute = rmr.kcalPerDay / 1440.0
        let kcalPerMET = kcalPerMETMinute(weightKg: input.profile.weightKg)
        let heightM = (input.profile.heightCm > 0 ? input.profile.heightCm : 170.0) / 100.0

        let signals = MinuteSignalBuilder.build(input, config: config)
        let n = signals.count
        let effectiveEnd = min(input.dayEnd, input.asOf ?? input.dayEnd)
        let complete = effectiveEnd >= input.dayEnd

        // ---- context, per minute ----------------------------------------------------------------------
        var beliefs = [ActivityBelief](repeating: .none, count: n)
        var beliefEvidence = [EnergyEvidenceSet](repeating: [], count: n)
        for i in 0..<n {
            let b = ActivityBeliefBuilder.belief(for: signals[i], config: config)
            beliefs[i] = b.belief
            beliefEvidence[i] = b.evidence
        }

        let physiology = HeartRatePhysiology(
            restingHR: input.restingHR, hrmax: input.hrmax,
            quietAwakeHR: quietAwakeHR(signals: signals, beliefs: beliefs, config: config),
            config: config)

        // ---- fusion, per minute -----------------------------------------------------------------------
        var fused = [FusionResult?](repeating: nil, count: n)
        for i in 0..<n {
            let s = signals[i]
            guard s.covered, !s.sleep, !s.offWrist else { continue }
            let dyn = hrDynamics(at: i, signals: signals, baseline: physiology.baseline)
            let workoutClass = s.workoutIndex.flatMap { input.workouts[$0].coarseClass }
            let inp = MinuteFusionInput(
                belief: beliefs[i], workoutClass: workoutClass, cadence: s.cadence, dyn: s.dyn,
                motion: s.motion, gpsSpeedMps: s.gpsSpeedMps, gpsGradePct: s.gpsGradePct,
                hr: s.hr, hrSource: s.hrSource, hrSlopeBpmPerMin: dyn.slope,
                sustainedMinutes: dyn.sustained, recovery: dyn.recovery, heightM: heightM)
            fused[i] = MinuteFusion.fuse(inp, physiology: physiology, config: config)
        }

        // ---- temporal consistency ---------------------------------------------------------------------
        var obs: [TemporalObservation] = []
        obs.reserveCapacity(n)
        for i in 0..<n {
            let s = signals[i]
            let transition = transitionMagnitude(at: i, signals: signals, beliefs: beliefs)
            if s.sleep && !s.offWrist && s.covered {
                obs.append(TemporalObservation(value: 1.0, variance: config.sleepMetSigma * config.sleepMetSigma,
                                               transition: transition))
            } else if let f = fused[i] {
                obs.append(TemporalObservation(value: f.mean, variance: f.sd * f.sd, transition: transition))
            } else {
                obs.append(TemporalObservation(value: nil, variance: 1, transition: max(transition, 0.5)))
            }
        }
        let smooth = MetabolicTemporalFilter.smooth(obs, config: config)

        // ---- per-minute outputs -----------------------------------------------------------------------
        var minutes: [EnergyMinute] = []
        minutes.reserveCapacity(n)
        for i in 0..<n {
            let s = signals[i]
            let lenFrac = Double(s.lengthS) / 60.0
            let resting = rmrPerMinute * lenFrac
            let inWorkout = s.workoutIndex != nil
            let dominant = beliefs[i].dominant

            if !s.covered || s.offWrist {
                minutes.append(EnergyMinute(
                    startTs: s.startTs, met: 1.0, metSigma: 0, confidence: 0, activeKcal: 0, restingKcal: resting,
                    activity: .unknown, isSleep: false, covered: false, inWorkout: inWorkout, hr: nil,
                    hrSource: .absent, evidence: [], share: .priorOnly, flags: [.uncovered]))
                continue
            }
            if s.sleep {
                var flags: EnergyQualityFlags = [.sleep]
                if s.hrSource == .carried { flags.insert(.hrCarried) }
                if s.hrSource == .absent { flags.insert(.hrAbsent) }
                let conf = config.sleepConfidence * (s.hrSource == .measured ? 1.0 : 0.85)
                minutes.append(EnergyMinute(
                    startTs: s.startTs, met: 1.0, metSigma: config.sleepMetSigma, confidence: conf,
                    activeKcal: 0, restingKcal: resting, activity: .stationary, isSleep: true, covered: true,
                    inWorkout: inWorkout, hr: s.hr, hrSource: s.hrSource, evidence: s.hr == nil ? [] : [.heartRate],
                    share: .priorOnly, flags: flags))
                continue
            }

            guard let f = fused[i] else { continue }
            let sm = smooth[i]
            let met = sm.mean.clamped(1.0, config.plausibleMaxMET)
            var flags = f.flags
            if sm.slewLimited { flags.insert(.slewLimited) }
            if s.sleepContradicted { flags.insert(.sleepContradicted) }
            let sigma = (sm.variance + pow(config.systematicErrorShare * f.sd, 2)).squareRoot()
            let precision = 1 / (1 + pow(sigma / config.confidenceHalfSigma, 2))
            let confidence = weightedProduct([
                (f.agreement, config.confidenceWeightAgreement),
                (f.context, config.confidenceWeightContext),
                (f.quality, config.confidenceWeightQuality),
                (f.distribution, config.confidenceWeightDistribution),
                (f.plausibility, config.confidenceWeightPlausibility),
                (precision, config.confidenceWeightPrecision),
            ], normalizer: config.confidenceNormalizer).clamped(config.confidenceFloor, 1)
            let active = max(0, met - 1.0) * kcalPerMET * lenFrac
            minutes.append(EnergyMinute(
                startTs: s.startTs, met: met, metSigma: sigma, confidence: confidence, activeKcal: active,
                restingKcal: resting, activity: dominant, isSleep: false, covered: true, inWorkout: inWorkout,
                hr: s.hr, hrSource: s.hrSource, evidence: f.evidence.union(beliefEvidence[i]), share: f.share,
                flags: flags))
        }

        return aggregate(minutes: minutes, input: input, config: config, rmr: rmr, effectiveEnd: effectiveEnd,
                         complete: complete)
    }

    // MARK: Heart-rate context

    /// Low percentile of the day's own quiet, awake heart rate: the wearer's calm baseline for today.
    private static func quietAwakeHR(signals: [MinuteSignals], beliefs: [ActivityBelief],
                                     config: EnergyConfig) -> Double? {
        var quiet: [Double] = []
        var awake: [Double] = []
        for i in signals.indices {
            let s = signals[i]
            guard s.hrSource == .measured, let hr = s.hr, !s.sleep, !s.offWrist, s.workoutIndex == nil else { continue }
            awake.append(hr)
            if beliefs[i].source != .none {
                let w = MetabolicPriors.effectiveWeights(beliefs[i])
                let stillByContext = w[EnergyActivity.stationary.rawValue] >= 0.5
                let stillByMotion = (s.dyn ?? 0) < config.dynMoveLow
                if stillByContext && stillByMotion { quiet.append(hr) }
            }
        }
        if quiet.count >= 20 { return quantile(quiet.sorted(), 0.20) }
        if awake.count >= 30 { return quantile(awake.sorted(), 0.10) }
        return nil
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// Slope (bpm/min), sustained-elevation run (minutes) and a recovery score for minute `i`.
    private static func hrDynamics(at i: Int, signals: [MinuteSignals], baseline: Double)
        -> (slope: Double, sustained: Int, recovery: Double) {
        guard let hr = signals[i].hr else { return (0, 0, 0) }
        var slope = 0.0
        if i >= 2, let prev = signals[i - 2].hr { slope = (hr - prev) / 2.0 }

        var sustained = 0
        let elevation = hr - baseline
        if elevation >= 10 {
            let floor = max(8.0, 0.6 * elevation)
            var j = i
            while j >= 0, i - j < 30, let h = signals[j].hr, h - baseline >= floor, !signals[j].sleep {
                sustained += 1
                j -= 1
            }
        }

        var recovery = 0.0
        if i >= 1, elevation >= 8 {
            var peak = 0.0
            for j in max(0, i - 10)..<i { if let h = signals[j].hr { peak = max(peak, h) } }
            if peak - hr >= 12, slope <= -0.5 {
                recovery = ((peak - hr - 8) / 30).clamped(0, 1)
            }
        }
        return (slope, sustained, recovery)
    }

    /// How much the underlying state is expected to differ from the previous minute, in [0, 1].
    private static func transitionMagnitude(at i: Int, signals: [MinuteSignals], beliefs: [ActivityBelief]) -> Double {
        guard i > 0 else { return 0 }
        let a = signals[i - 1], b = signals[i]
        if a.sleep != b.sleep { return 1 }
        if (a.workoutIndex == nil) != (b.workoutIndex == nil) { return 0.6 }
        if !a.covered || !b.covered { return 0.5 }
        let wa = MetabolicPriors.effectiveWeights(beliefs[i - 1])
        let wb = MetabolicPriors.effectiveWeights(beliefs[i])
        var tv = 0.0
        for k in 0..<wa.count { tv += abs(wa[k] - wb[k]) }
        var t = 0.5 * tv
        if let ca = a.cadence, let cb = b.cadence, abs(ca - cb) >= 30 { t = max(t, 0.5) }
        return t.clamped(0, 1)
    }

    /// Π valueᵢ^(weightᵢ / normalizer): a weighted geometric combination in which a single weak component
    /// cannot be averaged away.
    private static func weightedProduct(_ parts: [(value: Double, weight: Double)], normalizer: Double) -> Double {
        var logSum = 0.0
        for p in parts { logSum += p.weight * log(max(p.value, 1e-6)) }
        return exp(logSum / max(normalizer, 1e-6))
    }

    // MARK: Day aggregation

    private static func aggregate(minutes: [EnergyMinute], input: EnergyDayInput, config: EnergyConfig,
                                  rmr: (kcalPerDay: Double, source: RmrSource), effectiveEnd: Int,
                                  complete: Bool) -> DayEnergy {
        var resting = 0.0, restingGap = 0.0, active = 0.0, workout = 0.0
        var sedentary = 0, light = 0, moderate = 0, high = 0, sleepMin = 0, covered = 0
        var metSum = 0.0, metCount = 0, peak: Double?
        var confNum = 0.0, confDen = 0.0
        var evidenceMinutes: [String: Int] = [:]
        var perWorkout = [(kcal: Double, metSum: Double, confSum: Double, n: Int)](
            repeating: (0, 0, 0, 0), count: input.workouts.count)
        let epsilon = 0.05 * kcalPerMETMinute(weightKg: input.profile.weightKg)

        for m in minutes {
            resting += m.restingKcal
            if !m.covered { restingGap += m.restingKcal; continue }
            covered += 1
            if m.isSleep { sleepMin += 1; continue }
            active += m.activeKcal
            metSum += m.met; metCount += 1
            peak = max(peak ?? 0, m.met)
            if m.met < config.lightMET { sedentary += 1 }
            else if m.met < config.moderateMET { light += 1 }
            else if m.met < config.highMET { moderate += 1 }
            else { high += 1 }
            let w = m.activeKcal + epsilon
            confNum += w * m.confidence
            confDen += w
            for name in m.evidence.names { evidenceMinutes[name, default: 0] += 1 }
            if m.inWorkout, let wi = workoutIndex(for: m.startTs, in: input.workouts) {
                workout += m.activeKcal
                perWorkout[wi].kcal += m.activeKcal
                perWorkout[wi].metSum += m.met
                perWorkout[wi].confSum += m.confidence
                perWorkout[wi].n += 1
            }
        }

        let expected = minutes.count
        let coverageFraction = expected > 0 ? Double(covered) / Double(expected) : 0
        let confidence = confDen > 0 ? (confNum / confDen) * (0.4 + 0.6 * coverageFraction) : 0

        let projected: Double? = complete ? nil
            : resting + active + rmr.kcalPerDay / 86_400.0 * Double(max(0, input.dayEnd - effectiveEnd))

        let workouts: [WorkoutEnergy] = input.workouts.enumerated().map { (i, w) in
            let p = perWorkout[i]
            return WorkoutEnergy(start: w.start, end: w.end, activeKcal: p.kcal,
                                 averageMET: p.n > 0 ? p.metSum / Double(p.n) : nil,
                                 confidence: p.n > 0 ? p.confSum / Double(p.n) : 0)
        }

        return DayEnergy(
            modelVersion: EnergyConfig.modelVersion, featureVersion: EnergyConfig.featureVersion,
            rmrKcalPerDay: rmr.kcalPerDay, rmrSource: rmr.source,
            restingKcal: resting, restingGapKcal: restingGap, activeKcal: active, workoutKcal: workout,
            totalKcal: resting + active, projectedTotalKcal: projected,
            averageMET: metCount > 0 ? metSum / Double(metCount) : nil, peakMET: peak,
            sleepMinutes: sleepMin, sedentaryMinutes: sedentary, lightMinutes: light,
            moderateMinutes: moderate, highMinutes: high,
            expectedMinutes: expected, coverageMinutes: covered, gapMinutes: expected - covered,
            confidence: confidence, evidenceMinutes: evidenceMinutes, workouts: workouts, minutes: minutes)
    }

    private static func workoutIndex(for ts: Int, in workouts: [EnergyWorkoutInterval]) -> Int? {
        let center = ts + 30
        return workouts.firstIndex { center >= $0.start && center < $0.end }
    }
}
