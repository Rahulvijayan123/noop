import Foundation

// MetabolicPriors.swift — what each activity costs before any sensor speaks (Compendium / ACSM), and how
// much each evidence source is trusted in each activity (the router).
//
// Priors are Gaussian MIXTURES, not single Gaussians, on purpose. A "stationary wrist" label means the
// wrist did not move; it does not mean the body did not work (cycling, rowing, isometric holds, carrying).
// Each activity therefore carries a light heavy-tail component, so strong physiological evidence (a
// sustained HR far above baseline) can overrule a still wrist — instead of a hard gate deciding for it.

enum MetabolicPriors {
    struct Component: Equatable {
        var weight: Double
        var mean: Double
        var sd: Double
    }

    // MARK: Per-activity prior mixtures (METs, standard 1 MET = 3.5 ml/kg/min)

    /// Compendium of Physical Activities (Ainsworth 2011 / Herrmann 2024) bands, widened for the spread
    /// across people. Cadence is NOT baked into these: it enters as evidence, not as a second prior.
    static func components(for activity: EnergyActivity) -> [Component] {
        switch activity {
        case .stationary:
            // Sitting/standing/lying 1.0–1.8 (Compendium 1.3 typical). Tail: wrist-still effort.
            return [Component(weight: 0.86, mean: 1.25, sd: 0.20), Component(weight: 0.14, mean: 4.0, sd: 2.2)]
        case .walking:
            // 2.0–4.0 mph = 2.8–5.0 METs.
            return [Component(weight: 0.85, mean: 3.4, sd: 0.9), Component(weight: 0.15, mean: 4.6, sd: 1.8)]
        case .running:
            // 5–7 mph = 8.3–11.0 METs.
            return [Component(weight: 0.90, mean: 9.8, sd: 1.8), Component(weight: 0.10, mean: 7.0, sd: 3.0)]
        case .otherMovement:
            // Household/occupational movement (2–3) up to gym/sport (4–8).
            return [Component(weight: 0.45, mean: 2.3, sd: 0.7), Component(weight: 0.55, mean: 5.0, sd: 2.3)]
        case .unknown:
            // The population-of-minutes prior: mostly sedentary, some light, a little vigorous.
            return [Component(weight: 0.55, mean: 1.3, sd: 0.3), Component(weight: 0.25, mean: 2.5, sd: 0.8),
                    Component(weight: 0.20, mean: 5.0, sd: 2.5)]
        }
    }

    /// Compendium priors for a detected workout window by coarse class.
    static func workoutComponent(_ cls: CoarseWorkoutClass) -> Component {
        switch cls {
        case .walk: return Component(weight: 1, mean: 4.0, sd: 1.0)
        case .run: return Component(weight: 1, mean: 9.5, sd: 2.0)
        case .strength: return Component(weight: 1, mean: 4.5, sd: 1.5)
        case .cycle: return Component(weight: 1, mean: 7.0, sd: 2.2)
        case .ski: return Component(weight: 1, mean: 6.5, sd: 2.0)
        case .other: return Component(weight: 1, mean: 5.0, sd: 2.2)
        }
    }

    /// Effective weight of each activity for one minute: the labeller's distribution scaled by its
    /// confidence, with the remainder assigned to `unknown`. Sums to 1.
    static func effectiveWeights(_ belief: ActivityBelief) -> [Double] {
        var w = [Double](repeating: 0, count: EnergyActivity.allCases.count)
        var known = 0.0
        for a in EnergyActivity.allCases where a != .unknown {
            w[a.rawValue] = belief.confidence * belief.probabilities[a.rawValue]
            known += w[a.rawValue]
        }
        w[EnergyActivity.unknown.rawValue] = max(0, 1 - known)
        return w
    }

    /// The mixture the fusion uses as its prior for one minute.
    static func mixture(belief: ActivityBelief, workoutClass: CoarseWorkoutClass?,
                        config: EnergyConfig) -> [Component] {
        let weights = effectiveWeights(belief)
        let wClass = workoutClass == nil ? 0.0 : config.workoutPriorWeight
        var out: [Component] = []
        for a in EnergyActivity.allCases where weights[a.rawValue] > 1e-6 {
            for c in components(for: a) {
                out.append(Component(weight: weights[a.rawValue] * c.weight * (1 - wClass), mean: c.mean, sd: c.sd))
            }
        }
        if let cls = workoutClass {
            var c = workoutComponent(cls)
            c.weight = wClass
            out.append(c)
        }
        return out
    }

    static func mixtureMoments(_ comps: [Component]) -> (mean: Double, variance: Double) {
        let total = comps.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return (1.3, 1.0) }
        let mean = comps.reduce(0.0) { $0 + $1.weight * $1.mean } / total
        let second = comps.reduce(0.0) { $0 + $1.weight * ($1.sd * $1.sd + $1.mean * $1.mean) } / total
        return (mean, max(1e-6, second - mean * mean))
    }

    // MARK: Cadence and speed → MET (ACSM)

    /// Walking at a cadence (steps/min) for a given height. Stride length from cadence and height is the
    /// standard linear model (SL ≈ h·(0.30 + 0.0012·cadence), fitted to treadmill-gait data), speed = cadence·SL,
    /// then the ACSM level-walking equation VO2 = 0.1·v + 3.5 (v in m/min). Floored at 1.8 METs: a wrist
    /// that counts steps is not at rest.
    static func walkingMET(cadenceSpm: Double, heightM: Double) -> Double {
        let stride = heightM * (0.30 + 0.0012 * cadenceSpm)
        let v = cadenceSpm * stride
        return max(1.8, (0.1 * v + 3.5) / 3.5)
    }

    /// Running at a cadence. SL ≈ h·(0.55 + 0.0016·(cadence − 150)); ACSM running VO2 = 0.2·v + 3.5.
    static func runningMET(cadenceSpm: Double, heightM: Double) -> Double {
        let stride = heightM * (0.55 + 0.0016 * (cadenceSpm - 150))
        let v = cadenceSpm * stride
        return (0.2 * v + 3.5) / 3.5
    }

    /// ACSM walking, speed in m/s and grade in percent (VO2 = 0.1·v + 1.8·v·g + 3.5, v in m/min).
    static func acsmWalkingMET(speedMps: Double, gradePct: Double) -> Double {
        let v = speedMps * 60
        return (0.1 * v + 1.8 * v * (gradePct / 100) + 3.5) / 3.5
    }

    /// ACSM running (VO2 = 0.2·v + 0.9·v·g + 3.5).
    static func acsmRunningMET(speedMps: Double, gradePct: Double) -> Double {
        let v = speedMps * 60
        return (0.2 * v + 0.9 * v * (gradePct / 100) + 3.5) / 3.5
    }
}

// MARK: - Router: how much each evidence source is trusted in each activity

/// Multipliers are applied to a source's sigma (so > 1 widens it = trusts it less), blended over the
/// activity weights geometrically. Order: stationary, walking, running, other movement, unknown.
///
/// The reasoning, not a fitted table (no labelled ground truth exists for the owner's days):
///  * Wrist-motion models were built and validated mostly on ambulatory movement. They are best for
///    walking, a little worse for running (impact dominates, arm swing saturates), and poor for
///    activities where the arms do little work for the legs' effort or vice versa (cycling, lifting).
///  * Heart rate is the most informative witness in sustained aerobic exercise, and the least in
///    short, non-aerobic or emotional episodes. A "stationary" label with high HR is more often
///    non-metabolic (stress, caffeine, heat, posture change) than not.
enum EvidenceRouter {
    /// Bpm of the heart-rate elevation attributed to non-metabolic causes, per activity.
    static let hrNonMetabolicOffsetBpm: [Double] = [8, 3, 2, 4, 6]
    static let hrSigmaMultiplier: [Double] = [1.1, 1.1, 0.85, 0.9, 1.2]
    static let dynSigmaMultiplier: [Double] = [1.0, 1.0, 1.2, 2.0, 1.5]
    static let wristMETSigmaMultiplier: [Double] = [1.0, 1.0, 1.25, 1.8, 1.4]
    static let cnnSigmaMultiplier: [Double] = [1.0, 1.0, 1.2, 1.6, 1.3]

    /// Share of "this activity is metabolically supported by movement" used to decide how readily a
    /// sustained HR elevation is believed.
    static let movementSupport: [Double] = [0.05, 0.9, 1.0, 0.8, 0.5]

    static func blendedLinear(_ table: [Double], _ weights: [Double]) -> Double {
        var s = 0.0
        for i in 0..<table.count { s += table[i] * weights[i] }
        return s
    }

    static func blendedGeometric(_ table: [Double], _ weights: [Double]) -> Double {
        var s = 0.0
        for i in 0..<table.count { s += weights[i] * log(table[i]) }
        return exp(s)
    }
}

// MARK: - Heart rate as a continuous physiological signal

/// Maps a heart rate to a MET estimate and an uncertainty. There is no threshold: every bpm contributes,
/// smoothly, in proportion to how far it sits above the wearer's own quiet-awake baseline.
struct HeartRatePhysiology {
    let baseline: Double
    let restingHR: Double
    let hrmax: Double
    let metMax: Double
    let config: EnergyConfig

    /// - Parameters:
    ///   - restingHR: sleeping/lowest resting HR (nil → configured default).
    ///   - hrmax: effective maximum HR (nil → configured default).
    ///   - quietAwakeHR: low percentile of the day's own quiet awake HR, when enough quiet minutes exist.
    init(restingHR: Double?, hrmax: Double?, quietAwakeHR: Double?, config: EnergyConfig) {
        let rhr = (restingHR ?? config.defaultRestingHR).clamped(35, 110)
        let hmax = max(rhr + 40, hrmax ?? config.defaultHRmax)
        let lo = rhr + 3
        let hi = rhr + config.hrBaselineMaxAboveRestingBpm
        let fallback = rhr + config.hrBaselineFallbackAboveRestingBpm
        self.restingHR = rhr
        self.hrmax = hmax
        self.baseline = (quietAwakeHR ?? fallback).clamped(lo, hi)
        // Uth–Sørensen–Overgaard–Pedersen: VO2max ≈ 15.3·HRmax/HRrest, in METs. Capped: the ratio
        // overstates fitness at the low-RHR end.
        let metMaxRaw = 15.3 * hmax / rhr / 3.5
        self.metMax = metMaxRaw.clamped(config.metMaxFloor, config.metMaxCap)
        self.config = config
    }

    /// Fractional heart-rate reserve above baseline, after removing the non-metabolic offset.
    func reserveFraction(effectiveHR: Double, offsetBpm: Double) -> Double {
        let span = max(hrmax - baseline, 20)
        return min(1.15, max(0, effectiveHR - baseline - offsetBpm) / span)
    }

    /// MET implied by heart rate alone.
    func met(effectiveHR: Double, offsetBpm: Double) -> Double {
        let x = reserveFraction(effectiveHR: effectiveHR, offsetBpm: offsetBpm)
        return config.hrMetFloor + (metMax - config.hrMetFloor) * pow(x, config.hrCurveExponent)
    }

    /// 1-sigma of the HR-implied MET.
    /// - Parameters:
    ///   - met: the HR-implied MET.
    ///   - reserve: `reserveFraction` for the same reading. The scatter of MET at a given heart rate is
    ///     small at the wearer's quiet baseline and widens to the light-intensity scatter over the first
    ///     `hrSigmaRampReserve` of reserve.
    ///   - activityMultiplier: router blend (`EvidenceRouter.hrSigmaMultiplier`).
    ///   - sustainedMinutes: consecutive minutes of comparable elevation.
    ///   - movementSupport: router blend (`EvidenceRouter.movementSupport`).
    ///   - recovery: 0…1, how strongly this minute looks like post-effort recovery.
    ///   - carried: HR was interpolated/held rather than measured in the minute.
    func sigma(met: Double, reserve: Double, activityMultiplier: Double, sustainedMinutes: Int,
               movementSupport: Double, recovery: Double, carried: Bool) -> Double {
        let ramp = ActivityBeliefBuilder.smoothstep(reserve, 0, config.hrSigmaRampReserve)
        let base = config.hrSigmaAtBaseline + (config.hrSigmaBase - config.hrSigmaAtBaseline) * ramp
        var s = (base * base + pow(config.hrSigmaPerMET * max(0, met - 1), 2)).squareRoot()
        s *= activityMultiplier
        if sustainedMinutes >= config.sustainMinutes {
            s *= movementSupport > 0.5 ? config.sustainSigmaFactorSupported : config.sustainSigmaFactorUnsupported
        }
        s *= 1 + config.recoverySigmaGain * recovery
        if carried { s *= 1.3 }
        return s
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
