import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// `analyzeDay` is the one seam every consumer of `DailyMetric.activeKcalEst` goes through (the app, the
/// coach, the push batch, the hosted worker). These tests pin how it hands the day to the metabolic
/// estimator: the default model, the preserved legacy model, and what each input stream becomes.
final class AnalyticsEngineEnergyTests: XCTestCase {
    private let day = AnalyticsEngine.dayString(SyntheticDay.dayStart)
    private let profile = SyntheticDay.profile

    private func moderateAfternoonDay() -> SyntheticDay {
        var d = SyntheticDay()
        d.add(.sitting(180, hr: 72, jitter: 4))
        d.add(.walking(40, hr: 112))
        d.add(.sitting(240, hr: 72, jitter: 4))
        return d
    }

    private func analyze(_ d: SyntheticDay, model: EnergyModelChoice = .fusion, profile: UserProfile? = nil,
                         asOf: Int? = nil, wristOff: [(start: Int, end: Int)] = [],
                         epochs: [ActivityEpoch] = [], motion: [MotionEvidenceMinute] = []) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(
            day: day, dayHr: d.hr, daySteps: d.steps, dayGravity: d.gravity,
            profile: profile ?? self.profile, maxHROverride: SyntheticDay.hrmax, tzOffsetSeconds: 0,
            wristOff: wristOff, energyModel: model, activityEpochs: epochs, motionEvidence: motion,
            energyAsOf: asOf)
    }

    func testFusionIsTheDefaultAndPublishesTheTimeline() throws {
        let result = analyze(moderateAfternoonDay())
        let energy = try XCTUnwrap(result.energy)
        XCTAssertEqual(try XCTUnwrap(result.daily.activeKcalEst), energy.totalKcal, accuracy: 1e-9)
        XCTAssertEqual(energy.modelVersion, EnergyConfig.modelVersion)
        XCTAssertEqual(energy.minutes.count, 1440)
        XCTAssertGreaterThan(energy.activeKcal, 0)
        XCTAssertEqual(energy.totalKcal, energy.restingKcal + energy.activeKcal, accuracy: 1e-6)
    }

    func testRestingEnergyCoversTheWholeDayEvenThoughTheStrapOnlyCoveredAFraction() throws {
        let d = moderateAfternoonDay()
        XCTAssertLessThan(d.hr.count, 86_400 / 2, "fixture must leave most of the day uncovered")
        let energy = try XCTUnwrap(analyze(d).energy)
        XCTAssertEqual(energy.restingKcal, energy.rmrKcalPerDay, accuracy: 1.0,
                       "24 h of resting energy, independent of strap coverage")
        XCTAssertGreaterThan(energy.gapMinutes, 600)
    }

    func testLegacyChoiceKeepsTheHeartRateOnlyEstimateAndNoTimeline() throws {
        let d = moderateAfternoonDay()
        let result = analyze(d, model: .legacyHR)
        XCTAssertNil(result.energy)
        let expected = Calories.estimateDayCalories(
            d.hr, profile: profile, hrmax: SyntheticDay.hrmax, restingHR: result.daily.restingHr.map(Double.init))
        XCTAssertEqual(try XCTUnwrap(result.daily.activeKcalEst), expected, accuracy: 1e-9)
    }

    func testFusionCreditsTheSubThresholdWalkTheLegacyGateDropped() throws {
        let d = moderateAfternoonDay()
        let legacy = try XCTUnwrap(analyze(d, model: .legacyHR).daily.activeKcalEst)
        let fusion = try XCTUnwrap(analyze(d).energy)
        let walk = (minuteIndex(SyntheticDay.dayStart + 180 * 60)..<minuteIndex(SyntheticDay.dayStart + 220 * 60))
        let walkActive = fusion.minutes[walk].reduce(0.0) { $0 + $1.activeKcal }
        XCTAssertGreaterThan(walkActive, 90, "a 40-minute brisk walk at HR 112 is worth ~100+ kcal net of rest")
        XCTAssertGreaterThan(fusion.totalKcal, legacy)
    }

    func testADayWithNoHeartRateHasNoEnergyEstimate() {
        let result = AnalyticsEngine.analyzeDay(day: day, dayHr: [], profile: profile, tzOffsetSeconds: 0)
        XCTAssertNil(result.daily.activeKcalEst)
        XCTAssertNil(result.energy)
    }

    func testDayInProgressCountsRestingEnergyOnlyUpToNow() throws {
        let d = moderateAfternoonDay()
        let eight = SyntheticDay.dayStart + 8 * 3600
        let early = try XCTUnwrap(analyze(d, asOf: eight).energy)
        let complete = try XCTUnwrap(analyze(d).energy)
        XCTAssertEqual(early.restingKcal, complete.rmrKcalPerDay / 3.0, accuracy: 1.0)
        XCTAssertLessThan(early.totalKcal, complete.totalKcal)
        XCTAssertEqual(try XCTUnwrap(early.projectedTotalKcal), early.totalKcal
                       + early.rmrKcalPerDay * (2.0 / 3.0), accuracy: 40,
                       "the projection adds only resting energy for the unobserved remainder")
    }

    func testMeasuredRmrReplacesTheEquationThroughTheProfile() throws {
        let d = moderateAfternoonDay()
        let equation = try XCTUnwrap(analyze(d).energy)
        XCTAssertEqual(equation.rmrSource, .equation)
        let measuredProfile = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                          age: profile.age, sex: profile.sex, measuredRmrKcalPerDay: 2050)
        let measured = try XCTUnwrap(analyze(d, profile: measuredProfile).energy)
        XCTAssertEqual(measured.rmrSource, .measured)
        XCTAssertEqual(measured.rmrKcalPerDay, 2050, accuracy: 1e-9)
        XCTAssertEqual(measured.restingKcal, 2050, accuracy: 1.0)
        XCTAssertGreaterThan(measured.totalKcal, equation.totalKcal + 200)
    }

    func testWristOffIntervalsCarryNoActiveEnergy() throws {
        let d = moderateAfternoonDay()
        let off = (start: SyntheticDay.dayStart + 190 * 60, end: SyntheticDay.dayStart + 215 * 60)
        let energy = try XCTUnwrap(analyze(d, wristOff: [off]).energy)
        let offMinutes = energy.minutes[minuteIndex(off.start)..<minuteIndex(off.end)]
        XCTAssertTrue(offMinutes.allSatisfy { !$0.covered && $0.activeKcal == 0 })
        let onMinutes = energy.minutes[minuteIndex(SyntheticDay.dayStart + 181 * 60)..<minuteIndex(off.start - 60)]
        XCTAssertGreaterThan(onMinutes.reduce(0.0) { $0 + $1.activeKcal }, 0)
    }

    func testExistingActivityEpochsAreReadNotRecomputed() throws {
        let d = moderateAfternoonDay()
        let walkStart = SyntheticDay.dayStart + 180 * 60
        let epochs = stride(from: walkStart, to: walkStart + 40 * 60, by: 30).map { s in
            ActivityEpoch(startTs: s, endTs: s + 30, motion: .walking, posture: .unknown, exercise: .unknown,
                          sleepState: .unknown, exertion: .unknown, wear: .unknown, confidence: 0.9,
                          observedS: 30, validS: 30)
        }
        let energy = try XCTUnwrap(analyze(d, epochs: epochs).energy)
        let inside = energy.minutes[minuteIndex(walkStart + 5 * 60)]
        XCTAssertTrue(inside.evidence.contains(.hart))
        XCTAssertEqual(inside.activity, .walking)
        let outside = energy.minutes[minuteIndex(SyntheticDay.dayStart + 30 * 60)]
        XCTAssertFalse(outside.evidence.contains(.hart))
    }

    func testOfflineWristMotionEvidenceReachesTheFusion() throws {
        let d = moderateAfternoonDay()
        let walkStart = SyntheticDay.dayStart + 180 * 60
        let motion = stride(from: walkStart, to: walkStart + 40 * 60, by: 60).map { t in
            MotionEvidenceMinute(minuteStart: t, imuSeconds: 60,
                                 wristMET: .init(met: 3.1, ood: 0.05, pActive: 0.98, model: "wristmet-test"),
                                 cnn: .init(met: 3.4, ood: 0.1, model: "cnn-test"),
                                 wristMETDemographicOOD: 0.1)
        }
        let energy = try XCTUnwrap(analyze(d, motion: motion).energy)
        let minute = energy.minutes[minuteIndex(walkStart + 10 * 60)]
        XCTAssertTrue(minute.evidence.contains(.wristMET))
        XCTAssertTrue(minute.evidence.contains(.wristCNN))
    }

    func testEnergyTimelineIsIdenticalWhenStreamsAreNotPreTrimmedToTheDay() throws {
        let d = moderateAfternoonDay()
        var spill = d
        for s in 1...1800 {
            spill.hr.append(HRSample(ts: SyntheticDay.dayStart - s, bpm: 150))
            spill.hr.append(HRSample(ts: SyntheticDay.dayStart + 86_400 + s, bpm: 150))
        }
        spill.hr.sort { $0.ts < $1.ts }
        let clean = try XCTUnwrap(analyze(d).energy)
        let spilled = try XCTUnwrap(analyze(spill).energy)
        XCTAssertEqual(clean.totalKcal, spilled.totalKcal, accuracy: 1e-9)
    }

    private func minuteIndex(_ ts: Int) -> Int { (ts - SyntheticDay.dayStart) / 60 }
}
