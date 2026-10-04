import Foundation

// EnergyFusion.swift — activity-aware fusion of independent evidence into one MET per minute.
//
// Per minute:
//   1. Activity context (the existing classifier's epochs; step counter / motion magnitude when a day has
//      none) → a distribution over {stationary, walking, running, other movement, unknown}.
//   2. Evidence, each with its own 1-sigma in METs:
//        motion family  WristMET, wrist CNN, step cadence (Compendium/ACSM), motion-magnitude proxy
//        GPS family     ACSM speed/grade equations
//        cardiac family continuous heart-rate physiology (baseline, reserve, sustain, slope, recovery)
//      Estimators that read the same wrist acceleration are NOT independent: the motion family's
//      variance is inflated by an equicorrelation factor instead of being averaged as if they were.
//   3. The router (`EvidenceRouter`) scales each source's sigma by how much that source is worth in the
//      current activity (wrist motion for walking, HR for sustained aerobic work, …).
//   4. Activity-conditional prior mixtures (Compendium) with heavy tails are updated by the combined
//      evidence (conjugate Gaussian, per component). The posterior mixture's mean and variance are the
//      estimate. No threshold anywhere: a lower-trust source only widens, never switches off.
//   5. Confidence components (agreement, context, quality, distribution, plausibility) are reported
//      alongside; `MetabolicEstimator` combines them with the post-smoothing precision.

// MARK: - Activity context adapter

enum ActivityBeliefBuilder {
    static func smoothstep(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return x >= hi ? 1 : 0 }
        let t = ((x - lo) / (hi - lo)).clamped(0, 1)
        return t * t * (3 - 2 * t)
    }

    /// The existing classifier when it covered the minute; otherwise a belief reconstructed from the strap's
    /// own step counter and motion magnitude (clearly labelled, and trusted less).
    static func belief(for s: MinuteSignals, config: EnergyConfig) -> (belief: ActivityBelief, evidence: EnergyEvidenceSet) {
        if let b = s.epochBelief { return (b, .hart) }

        if let cadence = s.cadence {
            var run = smoothstep(cadence, config.cadenceRunLow, config.cadenceRunFull)
            if s.runClassShare >= 0.5 { run = max(run, 0.7) }
            let walk = smoothstep(cadence, config.cadenceWalkLow, config.cadenceWalkFull) * (1 - run)
            let move = s.dyn.map { smoothstep($0, config.dynMoveLow, config.dynMoveFull) } ?? 0.25
            let other = max(0, 1 - run - walk) * move
            let stationary = max(0, 1 - run - walk - other)
            let belief = ActivityBelief(probabilities: [stationary, walk, run, other, 0],
                                        confidence: config.stepClassBeliefConfidence, source: .stepClass)
            return (belief, .stepClass)
        }

        if let dyn = s.dyn {
            let other = smoothstep(dyn, config.dynMoveLow, config.dynMoveFull)
            let belief = ActivityBelief(probabilities: [1 - other, 0, 0, other, 0],
                                        confidence: config.motionProxyBeliefConfidence, source: .motionProxy)
            return (belief, .motionProxy)
        }
        return (.none, [])
    }
}

// MARK: - Fusion

struct MinuteFusionInput {
    var belief: ActivityBelief
    var workoutClass: CoarseWorkoutClass?
    var cadence: Double?
    var dyn: Double?
    var motion: MotionEvidenceMinute?
    var gpsSpeedMps: Double?
    var gpsGradePct: Double?
    var hr: Double?
    var hrSource: EnergyHRSource
    /// HR slope in bpm/min over the last few minutes (positive = rising).
    var hrSlopeBpmPerMin: Double
    var sustainedMinutes: Int
    /// 0…1: this minute looks like recovery from effort (HR high but falling after a recent peak).
    var recovery: Double
    var heightM: Double
}

struct FusionResult {
    var mean: Double
    var sd: Double
    var share: EvidenceShare
    var evidence: EnergyEvidenceSet
    var flags: EnergyQualityFlags
    /// Confidence components, each in (0, 1].
    var agreement: Double
    var context: Double
    var quality: Double
    var distribution: Double
    var plausibility: Double
}

enum MinuteFusion {
    private struct Item {
        var kind: EnergyEvidenceSet
        var mean: Double
        var sd: Double
        var ood: Double
    }

    static func fuse(_ input: MinuteFusionInput, physiology: HeartRatePhysiology,
                     config: EnergyConfig) -> FusionResult {
        let weights = MetabolicPriors.effectiveWeights(input.belief)
        var evidence: EnergyEvidenceSet = []
        var flags: EnergyQualityFlags = []

        // ---- motion family ------------------------------------------------------------------------
        var motionItems: [Item] = []
        var modelCount = 0

        if let m = input.motion, m.imuSeconds >= 30 {
            let imuScale = (60.0 / Double(m.imuSeconds)).squareRoot()
            if let w = m.wristMET {
                // The sedentary call (MET 1.0) and the regressor behind a non-sedentary call have very
                // different validated errors; weight them by the classifier's own probability.
                let pActive = (w.pActive ?? (w.met > 1.0001 ? 1 : 0)).clamped(0, 1)
                let base = ((1 - pActive) * pow(config.wristMETSigmaSedentary, 2)
                            + pActive * pow(config.wristMETSigmaActive, 2)).squareRoot()
                var sd = base * EvidenceRouter.blendedGeometric(EvidenceRouter.wristMETSigmaMultiplier, weights)
                sd *= 1 + config.oodSigmaGain * w.ood.clamped(0, 1)
                let demog = (m.wristMETDemographicOOD ?? 0).clamped(0, 1)
                sd *= 1 + config.demographicOODSigmaGain * demog
                if let p = w.pActive { sd *= 1 + 1.5 * (1 - abs(2 * p.clamped(0, 1) - 1)) }
                sd *= imuScale
                let ood = max(w.ood.clamped(0, 1), demog)
                motionItems.append(Item(kind: .wristMET, mean: max(1, w.met), sd: sd, ood: ood))
                evidence.insert(.wristMET)
                modelCount += 1
                if ood > 0.5 { flags.insert(.wristMETOutOfDistribution) }
            }
            if let c = m.cnn {
                var sd = config.cnnSigma * EvidenceRouter.blendedGeometric(EvidenceRouter.cnnSigmaMultiplier, weights)
                sd *= 1 + config.oodSigmaGain * c.ood.clamped(0, 1)
                sd *= imuScale
                motionItems.append(Item(kind: .wristCNN, mean: max(1, c.met), sd: sd, ood: c.ood.clamped(0, 1)))
                evidence.insert(.wristCNN)
                modelCount += 1
                if c.ood > 0.5 { flags.insert(.cnnOutOfDistribution) }
            }
        }

        let walkRunWeight = weights[EnergyActivity.walking.rawValue] + weights[EnergyActivity.running.rawValue]
        if let cadence = input.cadence, cadence >= config.cadenceWalkLow, walkRunWeight > 0.3 {
            let runP = weights[EnergyActivity.running.rawValue] / max(walkRunWeight, 1e-9)
            let running = runP > 0.5
            let mean = running
                ? MetabolicPriors.runningMET(cadenceSpm: cadence, heightM: input.heightM)
                : MetabolicPriors.walkingMET(cadenceSpm: cadence, heightM: input.heightM)
            var sd = running ? config.cadenceRunSigma : config.cadenceWalkSigma
            if runP > 0.3 && runP < 0.7 { sd *= 1.5 }
            motionItems.append(Item(kind: .cadence, mean: mean, sd: sd, ood: 0.1))
            evidence.insert(.cadence)
        }

        // A still wrist is already in the activity belief. It is not a measurement of low energy: legs
        // (cycling), grip (lifting) and isometric work all leave the wrist quiet, so it only speaks once
        // the wrist is actually moving.
        let wristOOD = motionItems.first { $0.kind == .wristMET }?.ood ?? 0
        if let dyn = input.dyn, dyn >= config.dynMoveLow, modelCount == 0 || wristOOD > 0.6 {
            let mean = 1.2 + config.dynProxyGain * max(0, dyn - config.dynProxyFloorG)
            // A barely-moving wrist (0.04–0.12 g) is compatible with anything from standing to leg-driven
            // exercise, so the proxy is nearly uninformative there and sharpens as the wrist moves more.
            let quiet = 1 - ActivityBeliefBuilder.smoothstep(dyn, config.dynMoveLow, config.dynMoveFull)
            let sd = (config.dynSigmaBase + config.dynSigmaPerMET * (mean - 1) + config.dynQuietSigmaExtra * quiet)
                * EvidenceRouter.blendedGeometric(EvidenceRouter.dynSigmaMultiplier, weights)
            motionItems.append(Item(kind: .motionProxy, mean: mean, sd: sd, ood: 0.15))
            evidence.insert(.motionProxy)
        }

        var motion: (mean: Double, sd: Double)?
        if !motionItems.isEmpty {
            var family = combine(motionItems.map { ($0.mean, $0.sd) },
                                 inflation: 1 + config.motionFamilyCorrelation * Double(motionItems.count - 1))
            // Correlated estimators are worth less than independent ones, but never worth less than the best
            // one alone: adding a weaker model must not make the family's answer vaguer than its member's.
            if let best = motionItems.map({ $0.sd }).min() { family.sd = min(family.sd, best) }
            motion = family
        }

        // ---- GPS family ---------------------------------------------------------------------------
        var gps: Item?
        if let v = input.gpsSpeedMps, v >= 0.5, walkRunWeight > 0.3 {
            let grade = input.gpsGradePct ?? 0
            let runP = weights[EnergyActivity.running.rawValue] / max(walkRunWeight, 1e-9)
            let mean = (runP > 0.5 || v > 2.2)
                ? MetabolicPriors.acsmRunningMET(speedMps: v, gradePct: grade)
                : MetabolicPriors.acsmWalkingMET(speedMps: v, gradePct: grade)
            let sd = config.gpsSigma * (input.gpsGradePct == nil ? 1.2 : 1.0)
            gps = Item(kind: .gps, mean: mean, sd: sd, ood: 0.05)
            evidence.insert(.gps)
        }

        // ---- cardiac family -----------------------------------------------------------------------
        var hrItem: Item?
        if let hr = input.hr {
            let lead = (config.hrLeadGain * input.hrSlopeBpmPerMin).clamped(-config.hrLeadClampBpm, config.hrLeadClampBpm)
            let offset = EvidenceRouter.blendedLinear(EvidenceRouter.hrNonMetabolicOffsetBpm, weights)
            let met = physiology.met(effectiveHR: hr + lead, offsetBpm: offset)
            let sd = physiology.sigma(
                met: met,
                reserve: physiology.reserveFraction(effectiveHR: hr + lead, offsetBpm: offset),
                activityMultiplier: EvidenceRouter.blendedGeometric(EvidenceRouter.hrSigmaMultiplier, weights),
                sustainedMinutes: input.sustainedMinutes,
                movementSupport: EvidenceRouter.blendedLinear(EvidenceRouter.movementSupport, weights),
                recovery: input.recovery,
                carried: input.hrSource == .carried)
            let ood = hr > physiology.hrmax + 10 ? 1.0 : 0.0
            hrItem = Item(kind: .heartRate, mean: met, sd: sd, ood: ood)
            evidence.insert(.heartRate)
            if input.hrSource == .carried { flags.insert(.hrCarried) }
        } else {
            flags.insert(.hrAbsent)
        }

        // ---- prior mixture ------------------------------------------------------------------------
        let prior = MetabolicPriors.mixture(belief: input.belief, workoutClass: input.workoutClass, config: config)
        if input.workoutClass != nil { evidence.insert(.workoutPrior) }
        let priorMoments = MetabolicPriors.mixtureMoments(prior)

        // ---- external load the limbs cannot show --------------------------------------------------------
        // Movement-based estimates are one-sided: grade, stairs, carrying and rail-holding add cost the
        // wrist and the step rate do not see. If heart rate has stayed well above the movement's estimate
        // while movement is expected to support it, the motion family is given a wider upward tolerance
        // (it still counts; it just stops vetoing the heart rate). Below the movement's estimate, or with
        // a still wrist, or for a brief spike, nothing changes.
        if var m = motion, let h = hrItem, config.loadBlindSpotSigmaGain > 1 {
            let support = EvidenceRouter.blendedLinear(EvidenceRouter.movementSupport, weights)
            let gap = ActivityBeliefBuilder.smoothstep(h.mean - m.mean, config.loadBlindSpotGapLow, config.loadBlindSpotGapFull)
            let sustained = ActivityBeliefBuilder.smoothstep(
                Double(input.sustainedMinutes), 0.5 * Double(config.sustainMinutes), 1.5 * Double(config.sustainMinutes))
            m.sd *= 1 + (config.loadBlindSpotSigmaGain - 1) * support * gap * sustained
            motion = m
        }

        // ---- combine independent families ---------------------------------------------------------
        var families: [(mean: Double, sd: Double)] = []
        if let m = motion { families.append(m) }
        if let g = gps { families.append((g.mean, g.sd)) }
        if let h = hrItem { families.append((h.mean, h.sd)) }

        let posterior: (mean: Double, sd: Double)
        if families.isEmpty {
            posterior = (priorMoments.mean, priorMoments.variance.squareRoot())
            flags.insert(.noMotionEvidence)
        } else {
            let e = combine(families, inflation: 1)
            posterior = update(prior: prior, evidenceMean: e.mean, evidenceSD: e.sd)
        }
        // "No motion evidence" means no motion CHANNEL: a still wrist on a day that has a channel is
        // information (it is in the belief), not an absence of it.
        let noChannel = input.belief.source == .none
        if motionItems.isEmpty && noChannel { flags.insert(.noMotionEvidence) }
        if motionItems.isEmpty && noChannel && gps == nil && hrItem != nil { flags.insert(.hrOnly) }
        if input.belief.confidence < 0.4 { flags.insert(.lowContextConfidence) }

        // ---- shares -------------------------------------------------------------------------------
        let pPrior = 1 / priorMoments.variance
        let pMotion = (motion.map { 1 / ($0.sd * $0.sd) } ?? 0) + (gps.map { 1 / ($0.sd * $0.sd) } ?? 0)
        let pHR = hrItem.map { 1 / ($0.sd * $0.sd) } ?? 0
        let pTotal = pPrior + pMotion + pHR
        let share = EvidenceShare(motion: pMotion / pTotal, heartRate: pHR / pTotal, prior: pPrior / pTotal)

        // ---- confidence components ----------------------------------------------------------------
        var allItems = motionItems
        if let g = gps { allItems.append(g) }
        if let h = hrItem { allItems.append(h) }
        let agreement = agreementScore(means: allItems.map { $0.mean }, sds: allItems.map { $0.sd },
                                       floor: config.agreementFloor)
        if allItems.count >= 2 && agreement < 0.5 { flags.insert(.estimatorsDisagree) }

        let context: Double = input.belief.source == .none ? 0.4 : max(0.3, input.belief.confidence)

        let hrQuality: Double
        switch input.hrSource {
        case .measured: hrQuality = 1.0
        case .carried: hrQuality = 0.75
        case .absent: hrQuality = 0.55
        }
        var motionQuality: Double
        if modelCount > 0 {
            motionQuality = 1.0
            if let m = input.motion { motionQuality = min(1, Double(m.imuSeconds) / 60.0 + 0.2) }
        } else if !motionItems.isEmpty {
            motionQuality = 0.9
        } else {
            switch input.belief.source {
            case .hart: motionQuality = 0.95
            case .stepClass, .motionProxy: motionQuality = 0.85
            case .none: motionQuality = 0.7
            }
        }
        let quality = hrQuality * motionQuality

        // Out-of-distribution is judged on the inputs themselves, not on their post-inflation weight: a
        // model that is far outside its training data has already been widened (so it cannot mislead the
        // estimate), but the minute still lost the evidence it was supposed to have.
        let oodItems = motionItems + (hrItem.map { [$0] } ?? [])
        let meanOOD = oodItems.isEmpty ? 0 : oodItems.reduce(0.0) { $0 + $1.ood } / Double(oodItems.count)
        let distribution = (1 - config.oodConfidencePenalty * meanOOD).clamped(0.05, 1)

        var plausibility = 1.0
        if posterior.mean > config.plausibleMaxMET { plausibility *= 0.3; flags.insert(.implausible) }
        if !families.isEmpty, let dom = prior.max(by: { $0.weight < $1.weight }) {
            let e = combine(families, inflation: 1)
            let z = abs(e.mean - dom.mean) / (dom.sd * dom.sd + e.sd * e.sd).squareRoot()
            plausibility *= 1 - 0.4 * ActivityBeliefBuilder.smoothstep(z, 2.5, 5)
        }

        return FusionResult(mean: max(1, posterior.mean), sd: posterior.sd, share: share,
                            evidence: evidence, flags: flags, agreement: agreement, context: context,
                            quality: quality, distribution: distribution, plausibility: plausibility.clamped(0.05, 1))
    }

    // MARK: Math

    /// Precision-weighted combination of independent Gaussian estimates, variance multiplied by `inflation`.
    private static func combine(_ items: [(mean: Double, sd: Double)], inflation: Double) -> (mean: Double, sd: Double) {
        var prec = 0.0
        var acc = 0.0
        for it in items {
            let p = 1 / (it.sd * it.sd)
            prec += p
            acc += p * it.mean
        }
        return (acc / prec, (inflation / prec).squareRoot())
    }

    /// Posterior mean/sd of a Gaussian-mixture prior given one Gaussian evidence summary.
    private static func update(prior: [MetabolicPriors.Component], evidenceMean: Double,
                               evidenceSD: Double) -> (mean: Double, sd: Double) {
        let ve = evidenceSD * evidenceSD
        var logW: [Double] = []
        var means: [Double] = []
        var vars: [Double] = []
        for c in prior {
            let vc = c.sd * c.sd
            let total = vc + ve
            let d = evidenceMean - c.mean
            logW.append(log(max(c.weight, 1e-12)) - 0.5 * d * d / total - 0.5 * log(total))
            let pv = 1 / (1 / vc + 1 / ve)
            means.append(pv * (c.mean / vc + evidenceMean / ve))
            vars.append(pv)
        }
        let top = logW.max() ?? 0
        let w = logW.map { exp($0 - top) }
        let z = w.reduce(0, +)
        var mean = 0.0
        for i in w.indices { mean += w[i] / z * means[i] }
        var second = 0.0
        for i in w.indices { second += w[i] / z * (vars[i] + means[i] * means[i]) }
        return (mean, max(1e-6, second - mean * mean).squareRoot())
    }

    /// Do the estimators tell the same story? Cochran's heterogeneity statistic Q = Σ (μᵢ − μ̄)² / σᵢ² about
    /// the precision-weighted mean μ̄ has expectation k − 1 when every estimator measures the same thing
    /// with the stated noise. Only the EXCESS over that expectation counts against agreement:
    /// `exp(-½ · max(0, Q − (k − 1)) / k)` is 1 for consistent estimators, ≈0.9 at a 1.2σ spread between
    /// two, ≈0.5 at 2σ, ≈0.14 at 3σ. A lone estimator has nothing to disagree with but nothing to
    /// corroborate it either: 0.75. Floored, so a disagreeing minute loses confidence but is never zeroed.
    static func agreementScore(means: [Double], sds: [Double], floor: Double) -> Double {
        guard means.count >= 2 else { return means.isEmpty ? 0.5 : 0.75 }
        var prec = 0.0, acc = 0.0
        for i in means.indices { let p = 1 / (sds[i] * sds[i]); prec += p; acc += p * means[i] }
        let mu = acc / prec
        var q = 0.0
        for i in means.indices { let d = means[i] - mu; q += d * d / (sds[i] * sds[i]) }
        let k = Double(means.count)
        let excess = max(0, q - (k - 1))
        return floor + (1 - floor) * exp(-0.5 * excess / k)
    }
}
