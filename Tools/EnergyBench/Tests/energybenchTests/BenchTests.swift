import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import energybench

final class RunFindingTests: XCTestCase {
    private func flags(_ s: String) -> [Bool] { s.map { $0 == "x" } }

    func testRunsAreMaximalAndStartAndEndOnMovingMinutes() {
        XCTAssertEqual(Bench.runs(of: flags("..xxxx.."), minLength: 3, gapTolerance: 0), [2..<6])
    }

    func testAShortGapIsBridgedAndCountsTowardTheLength() {
        XCTAssertEqual(Bench.runs(of: flags("xxx..xxx"), minLength: 5, gapTolerance: 2), [0..<8])
    }

    func testAGapLongerThanTheToleranceSplitsTheRun() {
        XCTAssertEqual(Bench.runs(of: flags("xxxx...xxxx"), minLength: 3, gapTolerance: 2), [0..<4, 7..<11])
    }

    func testRunsShorterThanTheMinimumAreDropped() {
        XCTAssertEqual(Bench.runs(of: flags("xx...xxxxx"), minLength: 4, gapTolerance: 1), [5..<10])
    }

    func testATrailingGapIsNotPartOfTheRun() {
        XCTAssertEqual(Bench.runs(of: flags("xxxxx.."), minLength: 3, gapTolerance: 2), [0..<5])
    }

    func testNoMovingMinutesNoRuns() {
        XCTAssertTrue(Bench.runs(of: flags("......"), minLength: 1, gapTolerance: 2).isEmpty)
        XCTAssertTrue(Bench.runs(of: [], minLength: 1, gapTolerance: 2).isEmpty)
    }
}

final class MinuteSignalTests: XCTestCase {
    func testMinuteSignalsAreMeansAndCounterDeltasAndSparseMinutesStayEmpty() {
        var d = TestDay()
        d.add(.walking(3, hr: 100, cadence: 90, dyn: 0.2))
        let s = Bench.minuteSignals(d.streams, dayStart: TestDay.dayStart, minutes: 3, options: BenchOptions())
        XCTAssertEqual(s.count, 3)
        for m in s {
            XCTAssertEqual(m.hrMean ?? 0, 100, accuracy: 1.0)
            XCTAssertEqual(m.dynMean ?? 0, 0.2, accuracy: 0.03)
            XCTAssertEqual(m.cadence ?? 0, 90, accuracy: 3)
        }
        // A minute with fewer than 20 heart-rate rows says nothing rather than something noisy.
        let sparse = Bench.Streams(hr: (0..<5).map { HRSample(ts: TestDay.dayStart + $0, bpm: 150) }, gravity: [], steps: [])
        XCTAssertNil(Bench.minuteSignals(sparse, dayStart: TestDay.dayStart, minutes: 1, options: BenchOptions())[0].hrMean)
    }

    func testSamplesBeforeTheDayStartAreIgnored() {
        let early = Bench.Streams(hr: (1...60).map { HRSample(ts: TestDay.dayStart - $0, bpm: 200) }, gravity: [], steps: [])
        XCTAssertNil(Bench.minuteSignals(early, dayStart: TestDay.dayStart, minutes: 2, options: BenchOptions())[0].hrMean)
    }
}

final class LegacyGateTests: XCTestCase {
    /// The harness keeps its own copy of `Calories.dayActiveHRRFraction` (internal to the package). If the
    /// estimator's gate ever moves, this fails and the report's "Gate bpm" column would otherwise lie.
    func testLegacyGateConstantMatchesTheEstimator() {
        let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
        let rhr = 51.0, hrmax = 194.0
        let gate = Bench.legacyGateBpm(restingHR: rhr, hrmax: hrmax)
        func active(at bpm: Int) -> Double {
            let hr = (0..<600).map { HRSample(ts: 1_000 + $0, bpm: bpm) }
            return Calories.estimateDayEnergy(hr, profile: profile, hrmax: hrmax, restingHR: rhr).activeKcal
        }
        XCTAssertEqual(active(at: Int(gate.rounded(.down)) - 1), 0, "just below the harness gate the old model credits nothing")
        XCTAssertGreaterThan(active(at: Int(gate.rounded(.up)) + 1), 0, "just above it, the old model switches on")
    }
}

final class BenchRunTests: XCTestCase {
    private func options(_ configure: (inout BenchOptions) -> Void = { _ in }) -> BenchOptions {
        var o = BenchOptions(); configure(&o); return o
    }

    /// 8 h of scored sleep, a desk, then a 45-minute brisk walk whose every minute sits below the old gate
    /// (~117 bpm here) yet above 30 % of heart-rate reserve with real motion behind it, which is what the
    /// harness calls a "session".
    private func dayWithBriskWalk() -> (TestDay, (start: Int, end: Int)) {
        var d = TestDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120))
        let walk = d.add(.walking(45, hr: 108))
        d.add(.sitting(120))
        return (d, walk)
    }

    /// The same shape with an easy 45-minute walk under 30 % HRR: found only by its step cadence.
    private func dayWithEasyWalk() -> (TestDay, (start: Int, end: Int)) {
        var d = TestDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120))
        let walk = d.add(.walking(45, hr: 84, cadence: 95, dyn: 0.18))
        d.add(.sitting(120))
        return (d, walk)
    }

    func testTheIndependentFinderLocatesTheBriskWalkAsASessionBelowTheOldGate() throws {
        let (d, walk) = dayWithBriskWalk()
        let run = try d.run()
        let bout = try XCTUnwrap(run.bouts.first { $0.subThreshold })
        XCTAssertEqual(bout.kind, .session)
        XCTAssertEqual(bout.startTs, walk.start, accuracy: 120)
        XCTAssertEqual(bout.minutes, 45, accuracy: 3)
        XCTAssertLessThan(bout.maxMinuteHR, run.gateBpm, "premise: HR 108 stays under the old gate")
        XCTAssertEqual(bout.legacyActiveKcal, 0, accuracy: 1e-9, "the previous estimator credited the walk nothing")
    }

    func testTheIndependentFinderLocatesAnEasyWalkByItsCadenceAlone() throws {
        let (d, walk) = dayWithEasyWalk()
        let run = try d.run()
        let bout = try XCTUnwrap(run.bouts.first { $0.subThreshold })
        XCTAssertEqual(bout.kind, .locomotion)
        XCTAssertEqual(bout.startTs, walk.start, accuracy: 120)
        XCTAssertEqual(bout.minutes, 45, accuracy: 3)
        XCTAssertEqual(bout.legacyActiveKcal, 0, accuracy: 1e-9)
    }

    func testTheFusionCreditsTheBriskWalkAtACompendiumMagnitude() throws {
        let (d, _) = dayWithBriskWalk()
        let run = try d.run()
        let bout = try XCTUnwrap(run.bouts.first { $0.subThreshold })
        XCTAssertTrue(bout.inBand, "MET \(bout.fusionMeanMET) outside \(bout.band)")
        // 45 min × (≈ 3.4 − 1) METs × 1.225 kcal/min/MET ≈ 132 kcal for 70 kg.
        XCTAssertGreaterThan(bout.fusionActiveKcal, 90)
        XCTAssertLessThan(bout.fusionActiveKcal, 240)
        XCTAssertLessThan(bout.fusionActiveKcal, bout.ungatedActiveKcal,
                          "credited well below what pricing every beat at the Keytel exercise rate would give")
    }

    func testTheFusionCreditsTheEasyWalkWithoutTheHeartRateGate() throws {
        let (d, _) = dayWithEasyWalk()
        let run = try d.run()
        let bout = try XCTUnwrap(run.bouts.first { $0.subThreshold })
        XCTAssertTrue(bout.inBand, "MET \(bout.fusionMeanMET) outside \(bout.band)")
        XCTAssertGreaterThan(bout.fusionActiveKcal, bout.legacyActiveKcal + 0.5 * Double(bout.minutes))
        XCTAssertGreaterThan(run.activeShareBelowGate, 0.05, "part of the day's active energy is earned below the old gate")
    }

    func testAllWiringChecksPassOnASyntheticDayAndTheGateCheckPasses() throws {
        let (d, _) = dayWithBriskWalk()
        let run = try d.run()
        let checks = Checks.evaluate([run], options: BenchOptions())
        for c in checks where c.outcome == .fail { XCTFail("\(c.name): \(c.detail)") }
        XCTAssertEqual(checks.first { $0.name == "sub-threshold-moderate-activity-credited" }?.outcome, .pass)
        XCTAssertEqual(checks.first { $0.name == "legacy-total-reproduced" }?.outcome, .pass)
        XCTAssertEqual(checks.first { $0.name == "resting-is-24h-and-coverage-independent" }?.outcome, .pass)
    }

    func testALightDayIsRecognisedAndStaysUnderTheActivityBound() throws {
        var d = TestDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(8 * 60))
        d.add(.walking(12, hr: 92, cadence: 70, dyn: 0.16))
        d.add(.sitting(5 * 60))
        let run = try d.run()
        XCTAssertTrue(run.lightDay)
        XCTAssertLessThan(run.fusionPAL, 1.55)
        XCTAssertEqual(Checks.lightDaysNotOvercounted([run], options: BenchOptions()).outcome, .pass)
        XCTAssertEqual(Checks.lightDaysNotOvercounted([run], options: options { $0.lightDayMaxPAL = 1.0 }).outcome, .fail,
                       "the guard has teeth: a tighter bound fails the same day")
    }

    func testADayWithAHardSessionIsNotCalledLight() throws {
        var d = TestDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120))
        d.add(.running(40, hr: 160))
        d.add(.sitting(120))
        let run = try d.run()
        XCTAssertFalse(run.lightDay)
        XCTAssertTrue(run.bouts.contains { $0.kind == .session })
    }

    func testAnInProgressDayIsPartialAndCountsRestingToTheLastSample() throws {
        var d = TestDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120))
        let asOf = d.cursor
        let run = try d.run(asOf: asOf)
        XCTAssertTrue(run.partial)
        XCTAssertEqual(run.elapsedMinutes, 600)
        XCTAssertEqual(run.fusion.expectedMinutes, 600)
        XCTAssertEqual(run.fusion.restingKcal, run.fusion.rmrKcalPerDay / 1440 * 600, accuracy: 0.5)
        XCTAssertNotNil(run.fusion.projectedTotalKcal)
        XCTAssertEqual(Checks.lightDaysNotOvercounted([run], options: BenchOptions()).outcome, .notApplicable,
                       "a day still in progress is never judged against a 24 h bound")
    }

    func testAMeasuredRmrFlowsThroughToTheRestingTerm() throws {
        let (d, _) = dayWithBriskWalk()
        let measured = try d.run(options: options { $0.measuredRmr = 1_900 })
        XCTAssertEqual(measured.fusion.rmrKcalPerDay, 1_900)
        XCTAssertEqual(measured.fusion.rmrSource, .measured)
        XCTAssertEqual(measured.fusion.restingKcal, 1_900, accuracy: 1.0)
    }

    private func bout(fractionAboveGate: Double = 0, legacy: Double = 0, fusion: Double, met: Double,
                      band: ClosedRange<Double> = 2.0...5.5, kind: BoutKind = .locomotion) -> BoutRow {
        BoutRow(kind: kind, startTs: 0, minutes: 20, meanHR: 95, maxMinuteHR: 100,
                fractionAboveGate: fractionAboveGate, meanCadence: 100, meanDyn: 0.2, legacyActiveKcal: legacy,
                ungatedActiveKcal: 100, fusionActiveKcal: fusion, fusionMeanMET: met, fusionMeanConfidence: 0.5,
                band: band)
    }

    func testNoSubGateBoutIsNotApplicableRatherThanPassing() {
        XCTAssertEqual(Checks.subThresholdActivityCredited(bouts: []).outcome, .notApplicable)
    }

    func testTheCreditCheckPassesForAWalkCreditedAtACompendiumMET() {
        XCTAssertEqual(Checks.subThresholdActivityCredited(bouts: [("d", bout(fusion: 60, met: 3.4))]).outcome, .pass)
    }

    func testTheCreditCheckFailsWhenTheEstimatorWouldCreditNothing() {
        let r = Checks.subThresholdActivityCredited(bouts: [("d", bout(fusion: 0, met: 1.0))])
        XCTAssertEqual(r.outcome, .fail)
        XCTAssertTrue(r.detail.contains("failing"))
    }

    func testTheCreditCheckFailsWhenTheEstimatorOverstatesAModerateWalk() {
        XCTAssertEqual(Checks.subThresholdActivityCredited(bouts: [("d", bout(fusion: 250, met: 9.0))]).outcome, .fail,
                       "9 METs is not a walk")
    }

    func testAMixedBoutIsNotSubThresholdSoTheGateClaimDoesNotJudgeIt() {
        let mixed = bout(fractionAboveGate: 0.3, legacy: 40, fusion: 120, met: 3.6, band: 2.0...8.0, kind: .session)
        XCTAssertFalse(mixed.subThreshold)
        XCTAssertEqual(Checks.subThresholdActivityCredited([]).outcome, .notApplicable)
    }

    // MARK: Wiring checks have teeth

    func testTheLegacyReproductionCheckFailsWhenTheReplayPricesADifferentModel() throws {
        let (d, _) = dayWithBriskWalk()
        var run = try d.run()
        XCTAssertEqual(Checks.legacyReproduced([run]).outcome, .pass)
        run.legacyReportedTotal = run.legacyTotal + 5
        let off = Checks.legacyReproduced([run])
        XCTAssertEqual(off.outcome, .fail)
        XCTAssertTrue(off.detail.contains(run.day))
        run.legacyReportedTotal = nil
        XCTAssertEqual(Checks.legacyReproduced([run]).outcome, .notApplicable)
    }

    func testTheTimelineCheckFailsWhenTheReportedTotalIsNotTheSumOfTheMinutes() throws {
        let (d, _) = dayWithBriskWalk()
        var run = try d.run()
        XCTAssertEqual(Checks.fusionIsTheTimeline([run]).outcome, .pass)
        run.fusionReportedTotal = run.fusion.totalKcal + 40   // e.g. workout kcal added on top of the timeline
        XCTAssertEqual(Checks.fusionIsTheTimeline([run]).outcome, .fail)
    }

    func testADayWithNoRestingHeartRateIsReplayedAsNilNotAsASixtyBpmStandIn() throws {
        // A nil resting HR is a different question for the old model (60 bpm baseline AND the base Keytel
        // equation instead of the fitness-adjusted one) than an explicit 60, so the replay has to hand
        // `Calories` exactly what the app did. Substituting 60 once put 9–30 kcal of error on real days.
        var d = TestDay()
        d.add(.sitting(8, hr: 72)); d.add(.walking(10, hr: 134)); d.add(.sitting(8, hr: 72))
        let run = try d.run()
        XCTAssertNil(run.restingHR, "premise: 26 minutes is no night, so the day has no resting HR")
        XCTAssertGreaterThan(run.legacyActive, 0, "premise: the walk is above the legacy gate")
        XCTAssertEqual(Checks.legacyReproduced([run]).outcome, .pass)

        let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
        let hrmax = StrainScorer.tanakaHRmax(age: 35)
        let standIn = Calories.estimateDayEnergy(d.streams.hr, profile: profile, hrmax: hrmax, restingHR: 60)
        XCTAssertNotEqual(standIn.activeKcal, run.legacyActive, accuracy: 0.5,
                          "premise: the stand-in would have priced the same minutes differently")
    }
}

final class ReportTests: XCTestCase {
    func testClockFormatsMinutesSinceMidnightAndWrapsSafely() {
        XCTAssertEqual(Report.clock(0), "00:00")
        XCTAssertEqual(Report.clock(21 * 3600 + 37 * 60), "21:37")
        XCTAssertEqual(Report.clock(25 * 3600), "01:00")
        XCTAssertEqual(Report.clock(-60), "23:59")
    }

    func testMarkdownJSONAndTimelineRenderForASyntheticDay() throws {
        var d = TestDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(60)); d.add(.walking(30, hr: 104)); d.add(.sitting(60))
        let run = try d.run()
        let checks = Checks.evaluate([run], options: BenchOptions())

        let md = Report.markdown(runs: [run], checks: checks, options: BenchOptions())
        XCTAssertTrue(md.contains("# EnergyBench report"))
        XCTAssertTrue(md.contains("| 2026-09-22 |"))
        XCTAssertTrue(md.contains("sub-threshold-moderate-activity-credited"))

        let json = try Report.json(runs: [run], checks: checks, options: BenchOptions())
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(doc["format"] as? String, "energy-bench-report-v1")
        XCTAssertEqual((doc["days"] as? [[String: Any]])?.count, 1)

        let timeline = Report.timeline(run: run, fromMinute: 9 * 60, toMinute: 9 * 60 + 5)
        XCTAssertEqual(timeline.split(separator: "\n").count, 6, "header + five minutes")
        let csv = Report.timelineCSV(run: run)
        XCTAssertEqual(csv.split(separator: "\n").count, run.signals.count + 1)
    }

    func testNoRawSampleLeavesThroughTheReports() throws {
        var d = TestDay()
        d.add(.sleeping(8 * 60)); d.add(.sitting(30))
        let run = try d.run()
        let checks = Checks.evaluate([run], options: BenchOptions())
        let md = Report.markdown(runs: [run], checks: checks, options: BenchOptions())
        let json = String(data: try Report.json(runs: [run], checks: checks, options: BenchOptions()), encoding: .utf8) ?? ""
        for text in [md, json] {
            XCTAssertFalse(text.contains("\"hr\":"), "reports carry derived numbers, never the sample stream")
            XCTAssertFalse(text.contains(String(TestDay.dayStart + 1)), "no raw timestamps from the sample stream")
        }
    }
}
