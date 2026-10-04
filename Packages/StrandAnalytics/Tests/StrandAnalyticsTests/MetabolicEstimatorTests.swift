import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Behavioural tests of the energy-fusion model against the requirements it was built for:
/// no HR gate, sub-threshold sustained activity credited, light days not over-counted, activity-aware
/// weighting, honest confidence, temporal smoothness, and resting/active accounting.
final class MetabolicEstimatorTests: XCTestCase {
    private let profile = SyntheticDay.profile
    private let start = SyntheticDay.dayStart

    private func minuteIndex(_ ts: Int) -> Int { (ts - start) / 60 }

    private func evidence(for range: (start: Int, end: Int), wristMET: Double? = nil, cnn: Double? = nil,
                          wristOOD: Double = 0.1, cnnOOD: Double = 0.1, demog: Double = 0.1,
                          pActive: Double = 0.97) -> [MotionEvidenceMinute] {
        stride(from: range.start, to: range.end, by: 60).map { t in
            MotionEvidenceMinute(
                minuteStart: t, imuSeconds: 60,
                wristMET: wristMET.map { .init(met: $0, ood: wristOOD, pActive: pActive, model: "wristmet-test") },
                cnn: cnn.map { .init(met: $0, ood: cnnOOD, model: "cnn-test") },
                wristMETDemographicOOD: demog)
        }
    }

    private func epochs(_ range: (start: Int, end: Int), _ motion: MotionLabel, confidence: Double) -> [ActivityEpoch] {
        stride(from: range.start, to: range.end, by: 30).map { s in
            ActivityEpoch(startTs: s, endTs: s + 30, motion: motion, posture: .unknown, exercise: .unknown,
                          sleepState: .unknown, exertion: .unknown, wear: .unknown, confidence: confidence,
                          observedS: 30, validS: 30)
        }
    }

    private func activeKcal(_ e: DayEnergy, _ range: (start: Int, end: Int)) -> Double {
        e.minutes[minuteIndex(range.start)..<minuteIndex(range.end)].reduce(0.0) { $0 + $1.activeKcal }
    }

    private func meanConfidence(_ e: DayEnergy, _ range: (start: Int, end: Int)) -> Double {
        meanOf(e.minutes[minuteIndex(range.start)..<minuteIndex(range.end)]) { $0.confidence }
    }

    private func legacy(_ d: SyntheticDay) -> Calories.DayEnergyEstimate {
        Calories.estimateDayEnergy(d.hr, profile: profile, hrmax: SyntheticDay.hrmax, restingHR: SyntheticDay.restingHR)
    }

    /// Keytel (fitness-adjusted) gross-minus-resting kcal applied to every sample at or above `threshold`:
    /// the "credit every elevated reading at the exercise rate" behaviour behind the old light-day overcount.
    private func naiveKeytelActive(_ hr: [HRSample], threshold: Double) -> Double {
        let c = Calories.resolveCoeffs(profile.sex)
        let rest = Calories.restingKcalPerS(c, weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age)
        let vo2 = Calories.vo2maxFor(hrmax: SyntheticDay.hrmax, restingHR: SyntheticDay.restingHR)
        var total = 0.0
        for s in hr where Double(s.bpm) >= threshold {
            total += max(0, Calories.activeKcalPerS(c, hr: Double(s.bpm), hrmax: SyntheticDay.hrmax,
                                                    weightKg: profile.weightKg, age: profile.age, vo2max: vo2) - rest)
        }
        return total
    }

    // MARK: - Heart rate is a continuous signal, not a gate

    func testHeartRateCurveIsContinuousAcrossTheOldGate() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        let oldGate = 51 + 0.5 * (194 - 51)  // 122.5 bpm: where the previous model switched on
        var previous = physiology.met(effectiveHR: 60, offsetBpm: 3)
        for bpm in stride(from: 61.0, through: 190.0, by: 1.0) {
            let met = physiology.met(effectiveHR: bpm, offsetBpm: 3)
            XCTAssertGreaterThanOrEqual(met, previous - 1e-9, "HR→MET must never fall as HR rises (bpm \(bpm))")
            XCTAssertLessThan(met - previous, 0.45, "no cliff anywhere on the curve (bpm \(bpm))")
            previous = met
        }
        let below = physiology.met(effectiveHR: oldGate - 0.5, offsetBpm: 3)
        let above = physiology.met(effectiveHR: oldGate + 0.5, offsetBpm: 3)
        XCTAssertLessThan(above - below, 0.15, "nothing special happens at the old 122.6 bpm gate")
        XCTAssertGreaterThan(physiology.met(effectiveHR: 100, offsetBpm: 3), 1.4,
                             "100 bpm is well below the old gate yet still carries signal")
    }

    func testFusedEstimateIsContinuousInHeartRateAtEveryContext() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        let contexts: [ActivityBelief] = [
            .none,
            .fromLabel(.stationary, confidence: 0.9, source: .hart),
            .fromLabel(.walking, confidence: 0.9, source: .hart),
            .fromLabel(.otherMovement, confidence: 0.8, source: .hart),
        ]
        for belief in contexts {
            var previous: Double?
            for bpm in stride(from: 60.0, through: 180.0, by: 1.0) {
                let input = MinuteFusionInput(
                    belief: belief, workoutClass: nil, cadence: nil, dyn: nil, motion: nil, gpsSpeedMps: nil,
                    gpsGradePct: nil, hr: bpm, hrSource: .measured, hrSlopeBpmPerMin: 0, sustainedMinutes: 10,
                    recovery: 0, heightM: 1.75)
                let met = MinuteFusion.fuse(input, physiology: physiology, config: config).mean
                if let p = previous {
                    XCTAssertGreaterThanOrEqual(met, p - 0.02, "monotone in HR (\(belief.dominant), \(bpm) bpm)")
                    XCTAssertLessThan(met - p, 0.6, "no gate-like jump (\(belief.dominant), \(bpm) bpm)")
                }
                previous = met
            }
        }
    }

    // MARK: - Sustained moderate activity below the old threshold

    func testSustainedModerateActivityBelowOldThresholdIsCredited() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(150))
        let walk = d.add(.walking(45, hr: 110))   // brisk walk, cadence 105; the old gate is 122.6 bpm
        d.add(.sitting(60))
        let old = legacy(d)
        XCTAssertEqual(old.activeKcal, 0, accuracy: 1e-9, "premise: every reading stays below the old gate")

        let e = MetabolicEstimator.estimate(d.input(workouts: [EnergyWorkoutInterval(start: walk.start, end: walk.end)]))
        let walkKcal = activeKcal(e, walk)
        // 45 min × (≈3.4 METs − 1) × 1.225 kcal/min/MET ≈ 130 kcal. Compendium puts a 3.0–3.5 mph walk at
        // 3.5–4.3 METs, so ≈ 95–190 kcal is the physiologically reasonable band for 70 kg.
        XCTAssertGreaterThan(walkKcal, 90)
        XCTAssertLessThan(walkKcal, 200)
        XCTAssertEqual(e.workouts.first?.activeKcal ?? 0, walkKcal, accuracy: 1.0, "workout window reads the same timeline")
        let walkMET = meanOf(e.minutes[(minuteIndex(walk.start) + 5)..<minuteIndex(walk.end)]) { $0.met }
        XCTAssertGreaterThan(walkMET, 3.0)
        XCTAssertLessThan(walkMET, 4.3)
    }

    func testHeartRateOnlyModerateActivityBelowOldThresholdIsCreditedWithLowerConfidence() {
        func day(withMotion: Bool) -> (DayEnergy, (start: Int, end: Int)) {
            var d = SyntheticDay()
            d.add(.sleeping(8 * 60))
            d.add(withMotion ? .sitting(150) : EnergySegment(minutes: 150, hr: 66, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil))
            let seg = withMotion
                ? EnergySegment.walking(45, hr: 110)
                : EnergySegment(minutes: 45, hr: 110, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil)
            let w = d.add(seg)
            return (MetabolicEstimator.estimate(d.input()), w)
        }
        let (hrOnly, w1) = day(withMotion: false)
        let (withMotion, w2) = day(withMotion: true)
        let hrOnlyKcal = activeKcal(hrOnly, w1)
        XCTAssertGreaterThan(hrOnlyKcal, 60, "HR alone at ~110 bpm for 45 min is credited, not zeroed")
        XCTAssertLessThan(hrOnlyKcal, 200)
        XCTAssertLessThan(meanConfidence(hrOnly, w1), meanConfidence(withMotion, w2) - 0.1,
                          "HR-only is credited but less confidently than movement-backed activity")
        let flags = hrOnly.minutes[minuteIndex(w1.end) - 5].flags
        XCTAssertTrue(flags.contains(.hrOnly))
    }

    // MARK: - Light day: no reintroduced overcount

    /// A sedentary day for a wearer with a 51 bpm resting HR whose awake sitting HR is ~74 bpm (typical:
    /// awake HR runs well above the sleeping resting HR), with two easy walks, some household movement and
    /// two short stress bumps. Most of the day sits at 70–80 bpm: precisely where "credit every elevated
    /// reading at the exercise rate" overcounts by thousands of kcal.
    private func lightDay() -> SyntheticDay {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120, hr: 74, jitter: 4))
        d.add(.walking(15, hr: 92, cadence: 95, dyn: 0.2))
        d.add(.sitting(180, hr: 74, jitter: 4))
        d.add(EnergySegment(minutes: 5, hr: 102, hrJitter: 3, dyn: 0.02, cadence: 0, activityClass: 0))  // stress bump
        d.add(.sitting(60, hr: 74, jitter: 4))
        d.add(EnergySegment(minutes: 40, hr: 86, hrJitter: 3, dyn: 0.10, cadence: 15, activityClass: 1))  // household
        d.add(.sitting(150, hr: 74, jitter: 4))
        d.add(.walking(15, hr: 94, cadence: 95, dyn: 0.2))
        d.add(.sitting(120, hr: 74, jitter: 4))
        d.add(EnergySegment(minutes: 5, hr: 100, hrJitter: 3, dyn: 0.02, cadence: 0, activityClass: 0))  // stress bump
        d.add(.sitting(100, hr: 74, jitter: 4))
        d.add(.walking(20, hr: 88, cadence: 80, dyn: 0.15))
        d.add(.sitting(130, hr: 74, jitter: 4))
        d.padToFullDay()
        return d
    }

    func testLightDayIsNotOvercounted() {
        let d = lightDay()
        let e = MetabolicEstimator.estimate(d.input())
        let rmr = e.rmrKcalPerDay
        // Physical activity level of a light day: total ≈ 1.2–1.45 × RMR. Active energy above RMR should be
        // a few hundred kcal (NEAT, fidgeting, ~50 minutes of easy walking), never thousands.
        XCTAssertLessThan(e.activeKcal, 0.30 * rmr)
        XCTAssertGreaterThan(e.activeKcal, 100, "it is not a zero-activity day either")
        XCTAssertLessThan(e.totalKcal / rmr, 1.45)

        let naiveAll = naiveKeytelActive(d.hr, threshold: SyntheticDay.restingHR + 10)
        XCTAssertGreaterThan(naiveAll, 1_500, "premise: crediting every elevated reading at the exercise rate overcounts badly")
        XCTAssertLessThan(e.activeKcal, 0.30 * naiveAll)

        XCTAssertEqual(e.highMinutes, 0)
        XCTAssertEqual(e.moderateMinutes, 0, "a light day has no moderate-intensity minutes")
    }

    func testLightDayIsHigherThanLegacyOnlyByTheSedentaryAwakeFloorAndEasyWalking() {
        let d = lightDay()
        let e = MetabolicEstimator.estimate(d.input())
        let old = legacy(d)
        XCTAssertEqual(old.activeKcal, 0, accuracy: 1e-9, "premise: legacy gate credits nothing on this day")
        // The difference is real and bounded: awake-sedentary time at ≈1.3 METs plus ~50 min of easy walking.
        let awakeMinutes = Double(e.coverageMinutes - e.sleepMinutes)
        let kcalPerMET = MetabolicEstimator.kcalPerMETMinute(weightKg: profile.weightKg)
        let sedentaryFloor = awakeMinutes * 0.45 * kcalPerMET   // generous: up to 1.45 METs for every awake minute
        let walkingAllowance = 50.0 * 2.5 * kcalPerMET          // 50 minutes up to 3.5 METs
        XCTAssertLessThan(e.activeKcal, sedentaryFloor + walkingAllowance)
    }

    func testStressSpikeWithoutMovementDoesNotBecomeExercise() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(200))
        let spike = d.add(EnergySegment(minutes: 6, hr: 108, hrJitter: 3, dyn: 0.02, cadence: 0, activityClass: 0))
        d.add(.sitting(100))
        let e = MetabolicEstimator.estimate(d.input())
        let kcal = activeKcal(e, spike)
        let asExercise = naiveKeytelActive(Array(d.hr.filter { $0.ts >= spike.start && $0.ts < spike.end }), threshold: 0)
        XCTAssertLessThan(kcal, 0.35 * asExercise, "a short sedentary HR bump is credited far below the exercise rate")
        XCTAssertGreaterThan(kcal, 0, "…but a raised HR is still evidence, never exactly zero")
    }

    // MARK: - Activity-aware routing

    private func fuse(belief: ActivityBelief, hr: Double?, cadence: Double? = nil, dyn: Double? = nil,
                      motion: MotionEvidenceMinute? = nil, sustained: Int = 10) -> FusionResult {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        let input = MinuteFusionInput(
            belief: belief, workoutClass: nil, cadence: cadence, dyn: dyn, motion: motion, gpsSpeedMps: nil,
            gpsGradePct: nil, hr: hr, hrSource: hr == nil ? .absent : .measured, hrSlopeBpmPerMin: 0,
            sustainedMinutes: sustained, recovery: 0, heightM: 1.75)
        return MinuteFusion.fuse(input, physiology: physiology, config: config)
    }

    /// WristMET reports 1.0 MET only when its classifier says sedentary, so a sedentary window carries a low
    /// `pActive` and an active window a high one. Evidence that contradicts that (1.0 MET with p = 0.97) would
    /// be a model that disagrees with itself, which no real window can produce.
    private func wristMinute(_ met: Double, ood: Double = 0.1, pActive: Double? = nil) -> MotionEvidenceMinute {
        MotionEvidenceMinute(minuteStart: start, imuSeconds: 60,
                             wristMET: .init(met: met, ood: ood, pActive: pActive ?? (met > 1.0001 ? 0.97 : 0.03),
                                             model: "t"),
                             wristMETDemographicOOD: 0.1)
    }

    func testWristMotionIsTrustedMoreForWalkingThanForOtherMovement() {
        let walking = fuse(belief: .fromLabel(.walking, confidence: 0.9, source: .hart), hr: 135, motion: wristMinute(3.0))
        let other = fuse(belief: .fromLabel(.otherMovement, confidence: 0.9, source: .hart), hr: 135, motion: wristMinute(3.0))
        XCTAssertGreaterThan(walking.share.motion, 1.5 * other.share.motion,
                             "the same WristMET evidence carries more weight when the wearer is walking")
        XCTAssertLessThan(walking.mean, other.mean,
                          "with a hot HR, the walking minute stays nearer the motion model's 3.0 METs")
    }

    func testWristMETRegressorIsTrustedFarLessThanItsSedentaryCall() {
        let config = EnergyConfig()
        XCTAssertGreaterThan(config.wristMETSigmaActive, 3 * config.wristMETSigmaSedentary,
                             "validated error: 1.31 MET on active windows vs 0.32 MET on sedentary ones")
        let belief = ActivityBelief.fromLabel(.stationary, confidence: 0.9, source: .hart)
        let sedentary = fuse(belief: belief, hr: 100, motion: wristMinute(1.0))
        let active = fuse(belief: belief, hr: 100, motion: wristMinute(4.0))
        XCTAssertGreaterThan(sedentary.share.motion, 3 * active.share.motion,
                             "a sedentary call is far more informative than the regressor behind an active one")
    }

    func testWristMETWeightFollowsTheClassifierProbability() {
        let belief = ActivityBelief.fromLabel(.walking, confidence: 0.9, source: .hart)
        func share(_ p: Double) -> Double {
            fuse(belief: belief, hr: 110, motion: wristMinute(p > 0.5 ? 2.6 : 1.0, pActive: p)).share.motion
        }
        XCTAssertGreaterThan(share(0.03), share(0.97), "a confident sedentary call is the most reliable output")
        XCTAssertLessThan(share(0.48), share(0.97), "a coin-flip classification is trusted less than a confident active one")
        XCTAssertLessThan(share(0.52), share(0.97))
        XCTAssertLessThan(share(0.48), share(0.03))
    }

    func testHeartRateGainsWeightInSustainedAerobicRunning() {
        let running = fuse(belief: .fromLabel(.running, confidence: 0.9, source: .hart), hr: 160, sustained: 15)
        let stationary = fuse(belief: .fromLabel(.stationary, confidence: 0.9, source: .hart), hr: 160, sustained: 15)
        XCTAssertGreaterThan(running.share.heartRate, stationary.share.heartRate)
        XCTAssertGreaterThan(running.mean, stationary.mean, "supported HR is credited more than unsupported HR")
    }

    func testElevatedHeartRateWithoutMovementIsReducedButNeitherZeroNorFull() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        let unsupported = fuse(belief: .fromLabel(.stationary, confidence: 0.9, source: .hart), hr: 125, dyn: 0.01)
        let hrAlone = physiology.met(effectiveHR: 125, offsetBpm: 0)
        let creditFraction = (unsupported.mean - 1) / (hrAlone - 1)
        XCTAssertGreaterThan(creditFraction, 0.15, "not zero")
        XCTAssertLessThan(creditFraction, 0.90, "not the full HR-implied exercise energy")
        XCTAssertGreaterThan(unsupported.mean, 1.5)
        let supported = fuse(belief: .fromLabel(.running, confidence: 0.9, source: .hart), hr: 125, sustained: 10)
        XCTAssertGreaterThan((supported.mean - 1) / (hrAlone - 1), creditFraction,
                             "movement support raises the share of HR energy that is believed")
    }

    func testSedentaryWristModelOverridesATransientHeartRateSpike() {
        let r = fuse(belief: .fromLabel(.stationary, confidence: 0.9, source: .hart), hr: 125, motion: wristMinute(1.0))
        XCTAssertLessThan(r.mean, 2.0)
        XCTAssertGreaterThan(r.mean, 1.0)
    }

    func testWristStillCyclingIsNotForcedToSedentaryByTheWrist() {
        let r = fuse(belief: ActivityBelief(probabilities: [0.55, 0, 0, 0.45, 0], confidence: 0.6, source: .stepClass),
                     hr: 142, dyn: 0.05)
        XCTAssertGreaterThan(r.mean, 4.0, "sustained 142 bpm with a quiet wrist resolves toward exercise")
    }

    func testWorkoutClassPriorPullsAnAmbiguousMinuteTowardTheCompendiumValue() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        func run(_ cls: CoarseWorkoutClass?) -> Double {
            let input = MinuteFusionInput(
                belief: .none, workoutClass: cls, cadence: nil, dyn: nil, motion: nil, gpsSpeedMps: nil,
                gpsGradePct: nil, hr: nil, hrSource: .absent, hrSlopeBpmPerMin: 0, sustainedMinutes: 0,
                recovery: 0, heightM: 1.75)
            return MinuteFusion.fuse(input, physiology: physiology, config: config).mean
        }
        XCTAssertGreaterThan(run(.run), run(.walk) + 2)
        XCTAssertGreaterThan(run(.walk), run(nil))
    }

    func testGPSSpeedSharpensLocomotionEstimate() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        let belief = ActivityBelief.fromLabel(.walking, confidence: 0.9, source: .hart)
        func run(speed: Double?, grade: Double?) -> FusionResult {
            let input = MinuteFusionInput(
                belief: belief, workoutClass: nil, cadence: nil, dyn: nil, motion: nil, gpsSpeedMps: speed,
                gpsGradePct: grade, hr: 100, hrSource: .measured, hrSlopeBpmPerMin: 0, sustainedMinutes: 5,
                recovery: 0, heightM: 1.75)
            return MinuteFusion.fuse(input, physiology: physiology, config: config)
        }
        let withGPS = run(speed: 1.8, grade: 0)    // 6.5 km/h
        let without = run(speed: nil, grade: nil)
        XCTAssertTrue(withGPS.evidence.contains(.gps))
        XCTAssertGreaterThan(withGPS.mean, without.mean, "ACSM walking at 1.8 m/s is ≈ 4.1 METs")
        let uphill = run(speed: 1.8, grade: 8)
        XCTAssertGreaterThan(uphill.mean, withGPS.mean + 0.8, "grade is honoured when supplied")
    }

    // MARK: - Confidence

    func testConfidenceFallsWhenEstimatorsDisagree() {
        func walkConfidence(cnn: Double) -> Double {
            var d = SyntheticDay()
            d.add(.sleeping(8 * 60)); d.add(.sitting(150))
            let w = d.add(.walking(30, hr: 110))
            let ev = evidence(for: w, wristMET: 3.1, cnn: cnn)
            return meanConfidence(MetabolicEstimator.estimate(d.input(motionEvidence: ev)), w)
        }
        let agree = walkConfidence(cnn: 3.3)
        let disagree = walkConfidence(cnn: 6.8)
        XCTAssertLessThan(disagree, agree - 0.08)
    }

    func testConfidenceFallsOutsideTheModelsTrainingDistribution() {
        func walkConfidence(ood: Double, demog: Double) -> Double {
            var d = SyntheticDay()
            d.add(.sleeping(8 * 60)); d.add(.sitting(150))
            let w = d.add(.walking(30, hr: 110))
            let ev = evidence(for: w, wristMET: 3.1, cnn: 3.3, wristOOD: ood, cnnOOD: ood, demog: demog)
            return meanConfidence(MetabolicEstimator.estimate(d.input(motionEvidence: ev)), w)
        }
        XCTAssertLessThan(walkConfidence(ood: 0.9, demog: 0.9), walkConfidence(ood: 0.05, demog: 0.05) - 0.08)
    }

    func testOutOfDistributionModelIsWidenedSoItCannotDragTheEstimate() {
        let inDist = fuse(belief: .fromLabel(.walking, confidence: 0.9, source: .hart), hr: 105, motion: wristMinute(6.0, ood: 0.05))
        let outDist = fuse(belief: .fromLabel(.walking, confidence: 0.9, source: .hart), hr: 105, motion: wristMinute(6.0, ood: 0.95))
        XCTAssertLessThan(outDist.mean, inDist.mean, "an out-of-distribution 6.0 pulls the estimate less")
        XCTAssertTrue(outDist.flags.contains(.wristMETOutOfDistribution))
    }

    func testConfidenceFollowsClassifierConfidence() {
        func confidence(_ c: Double) -> Double {
            var d = SyntheticDay()
            d.add(.sleeping(8 * 60)); d.add(.sitting(150))
            let w = d.add(.walking(30, hr: 110))
            return meanConfidence(MetabolicEstimator.estimate(d.input(epochs: epochs(w, .walking, confidence: c))), w)
        }
        XCTAssertLessThan(confidence(0.5), confidence(0.97) - 0.05)
    }

    func testConfidenceFallsWithHeartRateDropouts() {
        func confidence(dropout: Bool) -> Double {
            var d = SyntheticDay()
            d.add(.sleeping(8 * 60)); d.add(.sitting(150))
            var seg = EnergySegment.walking(30, hr: 110)
            seg.hrPresent = !dropout
            let w = d.add(seg)
            return meanConfidence(MetabolicEstimator.estimate(d.input()), w)
        }
        XCTAssertLessThan(confidence(dropout: true), confidence(dropout: false) - 0.1)
    }

    func testMissingHeartRateStillProducesAMotionOnlyEstimateWithFlag() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(150))
        var seg = EnergySegment.walking(30, hr: 110)
        seg.hrPresent = false
        let w = d.add(seg)
        let e = MetabolicEstimator.estimate(d.input())
        let mid = e.minutes[minuteIndex(w.start) + 15]
        XCTAssertTrue(mid.flags.contains(.hrAbsent))
        XCTAssertGreaterThan(mid.met, 2.2, "cadence alone still says someone is walking")
        XCTAssertEqual(mid.hrSource, .absent)
    }

    func testConfidenceIsBoundedAndSleepIsHighConfidenceRMR() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60))
        let e = MetabolicEstimator.estimate(d.input())
        for m in e.minutes where m.covered {
            XCTAssertGreaterThanOrEqual(m.confidence, 0)
            XCTAssertLessThanOrEqual(m.confidence, 1)
        }
        XCTAssertEqual(e.minutes[60].met, 1.0, accuracy: 1e-9)
        XCTAssertEqual(e.minutes[60].activeKcal, 0, accuracy: 1e-12)
        XCTAssertTrue(e.minutes[60].isSleep)
    }

    // MARK: - Temporal consistency

    func testSittingToRunningTransitionIsSmoothButNotLaggy() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(90))
        let run = d.add(.running(30, hr: 150))
        d.add(.sitting(60))
        let e = MetabolicEstimator.estimate(d.input())
        let r0 = minuteIndex(run.start)
        XCTAssertLessThan(e.minutes[r0 - 3].met, 1.8)
        XCTAssertGreaterThan(e.minutes[r0 + 3].met, 7.0, "reaches running intensity within a few minutes")
        let slew = EnergyConfig().maxSlewMetPerMin
        for i in 1..<e.minutes.count where e.minutes[i].covered && e.minutes[i - 1].covered {
            XCTAssertLessThanOrEqual(abs(e.minutes[i].met - e.minutes[i - 1].met), slew + 1e-9,
                                     "minute \(i): no unphysical jump")
        }
    }

    func testLoneNoisyMinuteIsAbsorbedByTheSmoother() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(90))
        d.add(.walking(14, hr: 100))
        let spike = d.add(EnergySegment(minutes: 1, hr: 165, hrJitter: 1, dyn: 0.22, cadence: 105, activityClass: 1))
        d.add(.walking(15, hr: 100))
        d.add(.sitting(30))
        let e = MetabolicEstimator.estimate(d.input())
        let i = minuteIndex(spike.start)
        let neighbours = (e.minutes[i - 4].met + e.minutes[i + 4].met) / 2
        XCTAssertLessThan(e.minutes[i].met - neighbours, 1.5, "a single hot minute is not allowed to leap")
    }

    func testStableActivityHasSmallMinuteToMinuteVariation() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60))
        let w = d.add(.walking(60, hr: 108))
        let e = MetabolicEstimator.estimate(d.input())
        let slice = Array(e.minutes[(minuteIndex(w.start) + 10)..<(minuteIndex(w.end) - 5)])
        var maxStep = 0.0
        for i in 1..<slice.count { maxStep = max(maxStep, abs(slice[i].met - slice[i - 1].met)) }
        XCTAssertLessThan(maxStep, 0.35)
    }

    // MARK: - Resting vs active accounting

    func testRestingIsCountedForTheFullDayRegardlessOfCoverage() {
        var d = SyntheticDay()
        d.add(.sitting(180))
        d.add(.walking(30, hr: 105))
        d.padToFullDay()   // strap off for the remaining ~20.5 h
        let e = MetabolicEstimator.estimate(d.input())
        XCTAssertEqual(e.restingKcal, e.rmrKcalPerDay, accuracy: 0.01, "24 h of RMR, covered or not")
        XCTAssertEqual(e.expectedMinutes, 1440)
        // 210 recorded minutes, plus at most the one minute a held last reading may bridge.
        XCTAssertTrue((210...211).contains(e.coverageMinutes), "coverage \(e.coverageMinutes)")
        XCTAssertEqual(e.gapMinutes, 1440 - e.coverageMinutes)
        XCTAssertEqual(e.restingGapKcal, e.rmrKcalPerDay * Double(e.gapMinutes) / 1440, accuracy: 0.01)
        XCTAssertEqual(e.totalKcal, e.restingKcal + e.activeKcal, accuracy: 1e-9)
        let uncovered = e.minutes.filter { !$0.covered }
        XCTAssertTrue(uncovered.allSatisfy { $0.activeKcal == 0 }, "a gap is never zero-filled into active energy")
    }

    func testPopulationEquationRMRMatchesTheExistingBMRFormulaAndMeasuredRMRWins() {
        let p = profile
        let coeffs = Calories.resolveCoeffs(p.sex)
        let expected = Calories.restingKcalPerS(coeffs, weightKg: p.weightKg, heightCm: p.heightCm, age: p.age) * 86_400
        let eq = MetabolicEstimator.resolveRMR(profile: p)
        XCTAssertEqual(eq.kcalPerDay, expected, accuracy: 1e-6)
        XCTAssertEqual(eq.source, .equation)

        var measured = p
        measured.measuredRmrKcalPerDay = 1_912
        let m = MetabolicEstimator.resolveRMR(profile: measured)
        XCTAssertEqual(m.kcalPerDay, 1_912)
        XCTAssertEqual(m.source, .measured)

        var implausible = p
        implausible.measuredRmrKcalPerDay = 310
        XCTAssertEqual(MetabolicEstimator.resolveRMR(profile: implausible).source, .equation)

        var d = SyntheticDay()
        d.add(.sitting(60))
        d.padToFullDay()
        let e = MetabolicEstimator.estimate(d.input(profile: measured))
        XCTAssertEqual(e.restingKcal, 1_912, accuracy: 0.01)
        XCTAssertEqual(e.rmrSource, .measured)
    }

    func testWorkoutEnergyIsASubsetOfActiveEnergyAndNeverAddedTwice() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(120))
        let w = d.add(.running(30, hr: 158))
        d.add(.sitting(120))
        d.padToFullDay()
        let without = MetabolicEstimator.estimate(d.input())
        let with = MetabolicEstimator.estimate(d.input(workouts: [EnergyWorkoutInterval(start: w.start, end: w.end)]))
        XCTAssertEqual(with.workoutKcal, with.workouts.reduce(0) { $0 + $1.activeKcal }, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(with.workoutKcal, with.activeKcal)
        XCTAssertGreaterThan(with.workoutKcal, 0.5 * with.activeKcal, "the run dominates this day's active energy")
        XCTAssertEqual(with.totalKcal, with.restingKcal + with.activeKcal, accuracy: 1e-9, "workout kcal are not a third term")
        XCTAssertEqual(without.activeKcal, with.activeKcal, accuracy: 1e-6,
                       "declaring a workout window relabels minutes; it does not add energy")
        XCTAssertEqual(without.workoutKcal, 0)
    }

    func testPartialDayCountsRestingOnlyUpToNowAndProjectsTheRest() {
        var d = SyntheticDay()
        d.add(.sleeping(6 * 60)); d.add(.sitting(180))
        let asOf = d.cursor
        let e = MetabolicEstimator.estimate(d.input(asOf: asOf))
        let elapsed = Double(asOf - start)
        XCTAssertEqual(e.restingKcal, e.rmrKcalPerDay * elapsed / 86_400, accuracy: 0.05)
        XCTAssertEqual(e.expectedMinutes, 9 * 60)
        let projected = try! XCTUnwrap(e.projectedTotalKcal)
        XCTAssertEqual(projected, e.totalKcal + e.rmrKcalPerDay * (86_400 - elapsed) / 86_400, accuracy: 0.05)
        XCTAssertNil(MetabolicEstimator.estimate(d.input()).projectedTotalKcal)
    }

    func testNoDataDayStillCountsFullRestingAndZeroActive() {
        let e = MetabolicEstimator.estimate(EnergyDayInput(dayStart: start, dayEnd: start + 86_400, hr: [], profile: profile))
        XCTAssertEqual(e.activeKcal, 0)
        XCTAssertEqual(e.restingKcal, e.rmrKcalPerDay, accuracy: 0.01)
        XCTAssertEqual(e.coverageMinutes, 0)
        XCTAssertEqual(e.confidence, 0)
        XCTAssertNil(e.averageMET)
    }

    func testIntensityMinutesPartitionCoveredAwakeMinutes() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(120)); d.add(.walking(30, hr: 108)); d.add(.running(20, hr: 160))
        let e = MetabolicEstimator.estimate(d.input())
        XCTAssertEqual(e.sleepMinutes + e.sedentaryMinutes + e.lightMinutes + e.moderateMinutes + e.highMinutes,
                       e.coverageMinutes)
        XCTAssertGreaterThan(e.highMinutes, 10)
        XCTAssertGreaterThan(e.moderateMinutes, 15)
        XCTAssertGreaterThan(e.peakMET ?? 0, 7)
    }

    // MARK: - Existing activity classifier is an input

    func testExistingActivityEpochsDriveTheContext() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(150))
        let w = d.add(EnergySegment(minutes: 30, hr: 112, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil))
        let e = MetabolicEstimator.estimate(d.input(epochs: epochs(w, .walking, confidence: 0.95)))
        let mid = e.minutes[minuteIndex(w.start) + 15]
        XCTAssertEqual(mid.activity, .walking)
        XCTAssertTrue(mid.evidence.contains(.hart))
        XCTAssertFalse(mid.flags.contains(.noMotionEvidence))
        XCTAssertEqual(e.evidenceMinutes["hart"], 30)
    }

    func testEpochsOnlyDescribeContext_TheyDoNotChangeHowMuchIsAdded() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(120))
        let w = d.add(.walking(30, hr: 108))
        let base = MetabolicEstimator.estimate(d.input())
        let hart = MetabolicEstimator.estimate(d.input(epochs: epochs(w, .walking, confidence: 0.95)))
        XCTAssertEqual(base.totalKcal, hart.totalKcal, accuracy: 0.12 * base.totalKcal,
                       "a consistent classifier agrees with the step-counter context")
    }

    // MARK: - Motion-model evidence

    func testWristModelEvidenceIsUsedAndRecorded() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(150))
        let w = d.add(EnergySegment(minutes: 30, hr: 100, hrJitter: 3, dyn: 0.2, cadence: 100, activityClass: 1))
        let high = MetabolicEstimator.estimate(d.input(motionEvidence: evidence(for: w, wristMET: 4.4, cnn: 4.0)))
        let low = MetabolicEstimator.estimate(d.input(motionEvidence: evidence(for: w, wristMET: 2.2, cnn: 2.0)))
        let i = minuteIndex(w.start) + 15
        let mid = high.minutes[i]
        XCTAssertTrue(mid.evidence.contains(.wristMET))
        XCTAssertTrue(mid.evidence.contains(.wristCNN))
        XCTAssertGreaterThan(mid.share.motion, 0.45)
        XCTAssertGreaterThan(mid.met, low.minutes[i].met + 0.25,
                             "the model outputs move the estimate, in the direction they point (modestly: " +
                             "cadence is the better walking evidence and the wrist regressor is wide)")
        XCTAssertGreaterThan(mid.met, 3.0)
        XCTAssertLessThan(mid.met, 4.6)
        XCTAssertEqual(high.evidenceMinutes["wristmet"], 30)
    }

    func testShortImuMinutesAreIgnored() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(150))
        let w = d.add(.walking(30, hr: 108))
        let short = stride(from: w.start, to: w.end, by: 60).map {
            MotionEvidenceMinute(minuteStart: $0, imuSeconds: 12, wristMET: .init(met: 8, ood: 0, pActive: 1, model: "t"))
        }
        let e = MetabolicEstimator.estimate(d.input(motionEvidence: short))
        XCTAssertFalse(e.minutes[minuteIndex(w.start) + 15].evidence.contains(.wristMET))
    }

    func testMotionEvidenceJSONRoundTripsAndRejectsOtherSchemas() throws {
        let doc = MotionEvidenceDocument(minutes: [
            MotionEvidenceMinute(minuteStart: 1_790_035_200, imuSeconds: 60,
                                 wristMET: .init(met: 2.9, ood: 0.1, pActive: 0.97, model: "wristmet-rf-1"),
                                 cnn: .init(met: 3.4, ood: 0.2, model: "wrist-cnn-9ca77ea"),
                                 wristMETDemographicOOD: 0.7)
        ])
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try MotionEvidenceDocument.decode(data), doc)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"imu_s\""))
        XCTAssertTrue(text.contains("\"p_active\""))
        XCTAssertTrue(text.contains("\"demog_ood\""))

        let wrong = text.replacingOccurrences(of: MotionEvidenceDocument.schema, with: "something-else")
        XCTAssertThrowsError(try MotionEvidenceDocument.decode(Data(wrong.utf8)))
    }

    // MARK: - Priors and profile

    func testCompendiumAndACSMPriorsMatchPublishedValues() {
        XCTAssertEqual(MetabolicPriors.walkingMET(cadenceSpm: 100, heightM: 1.70), 3.0, accuracy: 0.35)
        XCTAssertEqual(MetabolicPriors.walkingMET(cadenceSpm: 120, heightM: 1.75), 3.7, accuracy: 0.5)
        XCTAssertEqual(MetabolicPriors.runningMET(cadenceSpm: 165, heightM: 1.75), 10.0, accuracy: 1.5)
        XCTAssertEqual(MetabolicPriors.acsmWalkingMET(speedMps: 1.34, gradePct: 0), 3.3, accuracy: 0.05)   // 3 mph
        XCTAssertEqual(MetabolicPriors.acsmRunningMET(speedMps: 2.68, gradePct: 0), 10.2, accuracy: 0.1)   // 6 mph
        XCTAssertGreaterThan(MetabolicPriors.walkingMET(cadenceSpm: 30, heightM: 1.7), 1.7, "stepping is not rest")
    }

    func testEveryPriorMixtureIsNormalisedAndHasAHeavyTail() {
        for a in EnergyActivity.allCases {
            let comps = MetabolicPriors.components(for: a)
            XCTAssertEqual(comps.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-9, "\(a)")
            XCTAssertGreaterThan(comps.map { $0.sd }.max() ?? 0, 0.7, "\(a) keeps room for the unexpected")
        }
    }

    func testUserProfileCacheKeyIsUnchangedUntilAMeasuredRMRIsSet() {
        let p = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
        let before = "w=\(70.0.bitPattern),h=\(175.0.bitPattern),a=\(35.0.bitPattern),s=male,t=\(1.0.bitPattern)"
        XCTAssertEqual(p.cacheKey, before)
        var q = p
        q.measuredRmrKcalPerDay = 1_900
        XCTAssertNotEqual(q.cacheKey, before)
    }

    func testEstimatorIsDeterministic() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60)); d.add(.walking(20, hr: 104)); d.add(.sitting(30))
        XCTAssertEqual(MetabolicEstimator.estimate(d.input()), MetabolicEstimator.estimate(d.input()))
    }

    // MARK: - Heart rate at the quiet baseline is rest, not the population average

    func testHeartRateSigmaIsTightAtBaselineAndWidensToTheLightIntensityScatter() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        func sigma(_ reserve: Double) -> Double {
            physiology.sigma(met: 1.2, reserve: reserve, activityMultiplier: 1, sustainedMinutes: 0,
                             movementSupport: 0.5, recovery: 0, carried: false)
        }
        XCTAssertLessThan(sigma(0), 0.3, "nothing but rest or posture produces a baseline heart rate")
        XCTAssertGreaterThan(sigma(config.hrSigmaRampReserve), 0.85, "a few beats up, light activity is back in play")
        var previous = sigma(0)
        for r in stride(from: 0.01, through: 0.30, by: 0.01) {
            XCTAssertGreaterThanOrEqual(sigma(r), previous - 1e-12, "the scatter never narrows as HR rises (reserve \(r))")
            previous = sigma(r)
        }
    }

    func testOnAHeartRateOnlyDayHeartRateStillSeparatesRestFromLightEffort() {
        // Regression: with a flat σ the activity prior's heavy tails dominated and every minute of a day
        // with no motion channel read ≈ 1.45 MET whether HR was 64 or 84 (or the wearer was asleep).
        func meanMET(hr: Double) -> Double {
            var d = SyntheticDay()
            d.add(EnergySegment(minutes: 120, hr: 62, hrJitter: 2, dyn: nil, cadence: nil, activityClass: nil))
            let seg = d.add(EnergySegment(minutes: 90, hr: hr, hrJitter: 2, dyn: nil, cadence: nil, activityClass: nil))
            let e = MetabolicEstimator.estimate(d.input(restingHR: nil))
            return meanOf(e.minutes[(minuteIndex(seg.start) + 20)..<minuteIndex(seg.end)]) { $0.met }
        }
        let rest = meanMET(hr: 62)
        let light = meanMET(hr: 84)
        let brisk = meanMET(hr: 108)
        XCTAssertLessThan(rest, 1.35, "a heart rate at the day's own baseline is sedentary")
        // With no motion channel +22 bpm is as likely a stressful email as a stroll, so it is credited
        // modestly (the unsupported-elevation discount), not ignored and not read as exercise.
        XCTAssertGreaterThan(light - rest, 0.25, "+22 bpm over baseline is not rest")
        XCTAssertLessThan(light, 2.2, "…and is not exercise either")
        XCTAssertGreaterThan(brisk - light, 0.8, "+46 bpm is moderate")
    }

    // MARK: - Load the limbs cannot show

    private func estimate(_ d: SyntheticDay, loadAllowance: Bool) -> DayEnergy {
        var config = EnergyConfig()
        if !loadAllowance { config.loadBlindSpotSigmaGain = 1 }
        return MetabolicEstimator.estimate(d.input(), config: config)
    }

    private func meanMET(_ e: DayEnergy, _ range: (start: Int, end: Int), skipping skip: Int = 0) -> Double {
        meanOf(e.minutes[(minuteIndex(range.start) + skip)..<minuteIndex(range.end)]) { $0.met }
    }

    func testSustainedHeartRateFarAboveWhatTheStepRateImpliesIsCreditedAsExternalLoad() {
        // The same steady 106 steps/min the whole time; heart rate tells the walk is on a grade or stairs.
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60))
        let climb = d.add(.walking(40, hr: 150, cadence: 106, dyn: 0.16))
        d.add(.sitting(30))
        let off = estimate(d, loadAllowance: false)
        let on = estimate(d, loadAllowance: true)

        let level = meanMET(off, climb, skipping: 15)
        let loaded = meanMET(on, climb, skipping: 15)
        XCTAssertGreaterThan(loaded - level, 0.7, "the heart rate gets a say once it has stayed this far above the cadence's cost")
        XCTAssertLessThan(loaded, 7.5, "but the cadence is still evidence: nothing like the 9+ METs the heart rate alone implies")
        XCTAssertGreaterThan(loaded, 4.0)
        let flagged = on.minutes[(minuteIndex(climb.start) + 15)..<minuteIndex(climb.end)]
        XCTAssertTrue(flagged.allSatisfy { $0.flags.contains(.estimatorsDisagree) }, "the disagreement is still reported")
        XCTAssertLessThan(meanOf(flagged) { $0.confidence }, 0.65, "…and still costs confidence")
    }

    func testTheLoadAllowanceIsOneSided() {
        // A very fit runner whose heart rate sits BELOW the cadence's cost: heart rate never overrules upward.
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60))
        let run = d.add(.running(40, hr: 128, cadence: 165, dyn: 0.8))
        d.add(.sitting(30))
        XCTAssertEqual(meanMET(estimate(d, loadAllowance: true), run, skipping: 15),
                       meanMET(estimate(d, loadAllowance: false), run, skipping: 15), accuracy: 0.02)
    }

    func testTheLoadAllowanceNeedsSustainedElevationAndMovementBehindIt() {
        // A brief spike during an easy walk, and a high heart rate at a desk, are not external load.
        var spike = SyntheticDay()
        spike.add(.sleeping(8 * 60)); spike.add(.sitting(60))
        spike.add(.walking(20, hr: 110, cadence: 106, dyn: 0.16))
        let burst = spike.add(.walking(3, hr: 152, cadence: 106, dyn: 0.16))
        spike.add(.walking(10, hr: 110, cadence: 106, dyn: 0.16))
        XCTAssertEqual(meanMET(estimate(spike, loadAllowance: true), burst),
                       meanMET(estimate(spike, loadAllowance: false), burst), accuracy: 0.2)

        var desk = SyntheticDay()
        desk.add(.sleeping(8 * 60)); desk.add(.sitting(60))
        let tense = desk.add(.sitting(40, hr: 140, jitter: 3))
        desk.add(.sitting(30))
        XCTAssertEqual(meanMET(estimate(desk, loadAllowance: true), tense, skipping: 15),
                       meanMET(estimate(desk, loadAllowance: false), tense, skipping: 15), accuracy: 0.25,
                       "a still wrist is not a context in which movement is expected to support the heart rate")
    }

    func testTheLoadAllowanceIsContinuousInTheGapBetweenTheEstimators() {
        let config = EnergyConfig()
        let physiology = HeartRatePhysiology(restingHR: 51, hrmax: 194, quietAwakeHR: 64, config: config)
        var previous: Double?
        for bpm in stride(from: 100.0, through: 170.0, by: 1.0) {
            let input = MinuteFusionInput(
                belief: .fromLabel(.walking, confidence: 0.9, source: .hart), workoutClass: nil, cadence: 106,
                dyn: 0.16, motion: nil, gpsSpeedMps: nil, gpsGradePct: nil, hr: bpm, hrSource: .measured,
                hrSlopeBpmPerMin: 0, sustainedMinutes: 20, recovery: 0, heightM: 1.75)
            let met = MinuteFusion.fuse(input, physiology: physiology, config: config).mean
            if let p = previous {
                XCTAssertGreaterThanOrEqual(met, p - 0.02, "monotone in HR at \(bpm) bpm")
                XCTAssertLessThan(met - p, 0.35, "no jump where the allowance starts or saturates (\(bpm) bpm)")
            }
            previous = met
        }
    }

    // MARK: - The heart rate can overrule a sleep interval

    func testVigorousHeartRateInsideASleepIntervalIsAwakeAndIsCredited() {
        var d = SyntheticDay()
        d.add(.sleeping(180))
        let workout = d.add(.running(25, hr: 150))
        d.add(.sleeping(180))
        d.sleep = [EnergyInterval(start: SyntheticDay.dayStart, end: d.cursor)]   // one over-long "night"
        let e = MetabolicEstimator.estimate(d.input())

        let inside = e.minutes[(minuteIndex(workout.start) + 3)..<minuteIndex(workout.end)]
        XCTAssertTrue(inside.allSatisfy { !$0.isSleep }, "a run is not sleep, whatever the interval says")
        XCTAssertTrue(inside.allSatisfy { $0.flags.contains(.sleepContradicted) })
        XCTAssertGreaterThan(meanOf(inside) { $0.met }, 6, "and it is priced as the run it is")
        XCTAssertEqual(e.sleepMinutes, 360 - 3 - 3, accuracy: 8, "the genuine sleep either side stays sleep")
        let night = e.minutes[0..<150]
        XCTAssertTrue(night.allSatisfy { $0.isSleep && $0.activeKcal == 0 && !$0.flags.contains(.sleepContradicted) })
    }

    func testTheSleepersOwnHeartRateIsTheReferenceWhenTheDayHasNoRestingHR() {
        var d = SyntheticDay()
        d.add(.sleeping(120, hr: 52))
        let up = d.add(.walking(30, hr: 120, cadence: 110))
        d.add(.sleeping(120, hr: 52))
        d.sleep = [EnergyInterval(start: SyntheticDay.dayStart, end: d.cursor)]
        let e = MetabolicEstimator.estimate(d.input(restingHR: nil))
        let inside = e.minutes[(minuteIndex(up.start) + 3)..<minuteIndex(up.end)]
        XCTAssertTrue(inside.allSatisfy { !$0.isSleep }, "52 bpm asleep makes 120 bpm obviously not asleep")
    }

    func testAnOrdinaryNightIsLeftAloneByTheSleepCheck() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60, hr: 50))
        d.add(.sitting(120))
        let e = MetabolicEstimator.estimate(d.input())
        XCTAssertEqual(e.sleepMinutes, 480)
        XCTAssertFalse(e.minutes.contains { $0.flags.contains(.sleepContradicted) })
    }
}
