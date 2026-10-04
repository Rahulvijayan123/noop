import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Prints what the fusion does in named scenarios, so the constants are tuned by looking at behaviour rather
/// than guessing and a reader can see the model's response at a glance. It asserts nothing (the behaviour
/// that matters is asserted in `MetabolicEstimatorTests`), so it only runs on request:
///
///     ENERGY_SCENARIOS=1 swift test --filter EnergyScenarioTable
final class EnergyScenarioTable: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENERGY_SCENARIOS"] != nil,
                          "set ENERGY_SCENARIOS=1 to print the scenario table")
    }

    private func run(_ name: String, _ seg: EnergySegment, motion: ((Int) -> [MotionEvidenceMinute])? = nil) {
        var d = SyntheticDay()
        d.add(.sitting(120))
        let a = d.add(seg)
        let n0 = (a.start - d.dayStart) / 60
        let n1 = (a.end - d.dayStart) / 60
        let ev = motion?(n0) ?? []
        let e = MetabolicEstimator.estimate(d.input(motionEvidence: ev))
        let tail = e.minutes[(n1 - seg.minutes / 2)..<n1]
        let met = meanOf(tail) { $0.met }
        let sd = meanOf(tail) { $0.metSigma }
        let conf = meanOf(tail) { $0.confidence }
        let share = tail.first!.share
        let flags = tail.first!.flags.names.joined(separator: ",")
        print(String(format: "SCENARIO %-46@ MET=%5.2f sd=%4.2f conf=%4.2f  motion=%4.2f hr=%4.2f prior=%4.2f  [%@]",
                     name as NSString, met, sd, conf, share.motion, share.heartRate, share.prior, flags as NSString))
    }

    func testPrintLightDay() {
        var d = SyntheticDay()
        d.add(.sleeping(8 * 60))
        d.add(.sitting(120, hr: 74, jitter: 4))
        d.add(.walking(15, hr: 92, cadence: 95, dyn: 0.2))
        d.add(.sitting(180, hr: 74, jitter: 4))
        d.add(EnergySegment(minutes: 5, hr: 102, hrJitter: 3, dyn: 0.02, cadence: 0, activityClass: 0))
        d.add(.sitting(660, hr: 74, jitter: 4))
        d.padToFullDay()
        let e = MetabolicEstimator.estimate(d.input())
        let old = Calories.estimateDayEnergy(d.hr, profile: SyntheticDay.profile, hrmax: 194, restingHR: 51)
        print(String(format: "LIGHTDAY rmr=%.0f resting=%.0f active=%.0f total=%.0f PAL=%.2f avgMET=%.2f conf=%.2f | legacy resting=%.0f active=%.0f",
                     e.rmrKcalPerDay, e.restingKcal, e.activeKcal, e.totalKcal, e.totalKcal / e.rmrKcalPerDay,
                     e.averageMET ?? 0, e.confidence, old.restingKcal, old.activeKcal))
    }

    func testPrintScenarioTable() {
        run("desk rest HR66", .sitting(30))
        run("desk stress HR95 sustained 30m", .sitting(30, hr: 95))
        run("desk stress HR110 sustained 30m", .sitting(30, hr: 110))
        run("desk HR125 sustained 30m (stationary ctx)", .sitting(30, hr: 125))
        run("desk HR140 sustained 30m (stationary ctx)", .sitting(30, hr: 140))
        run("brisk walk cad105 HR110 (below old gate)", .walking(30, hr: 110))
        run("walk cad105 HR80 (fit/low HR)", .walking(30, hr: 80))
        run("easy walk cad70 HR92", .walking(30, hr: 92, cadence: 70, dyn: 0.14))
        run("walk cad105 HR150 (heat/hill)", .walking(30, hr: 150))
        run("run cad165 HR165", .running(30, hr: 165))
        run("run cad165 HR135 (very fit)", .running(30, hr: 135))
        run("HR-only 110, no gravity/steps", EnergySegment(minutes: 30, hr: 110, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil))
        run("HR-only 80, no gravity/steps", EnergySegment(minutes: 30, hr: 80, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil))
        run("HR-only 140, no gravity/steps", EnergySegment(minutes: 30, hr: 140, hrJitter: 3, dyn: nil, cadence: nil, activityClass: nil))
        run("gym-ish: movement no steps dyn.15 HR120", EnergySegment(minutes: 30, hr: 120, hrJitter: 4, dyn: 0.15, cadence: 0, activityClass: 0))
        run("household: dyn.10 cad15 HR85", EnergySegment(minutes: 30, hr: 85, hrJitter: 3, dyn: 0.10, cadence: 15, activityClass: 1))
        run("cycling-ish: dyn.05 no steps HR140", EnergySegment(minutes: 30, hr: 140, hrJitter: 3, dyn: 0.05, cadence: 0, activityClass: 0))
        run("WristMET 3.2 + walk cad105 HR110", .walking(30, hr: 110)) { n0 in
            (0..<30).map { MotionEvidenceMinute(minuteStart: SyntheticDay.dayStart + (n0 + $0) * 60, imuSeconds: 60,
                wristMET: .init(met: 3.2, ood: 0.1, pActive: 0.97, model: "t"), wristMETDemographicOOD: 0.1) }
        }
        run("WristMET 1.0 (sedentary) + HR125", .sitting(30, hr: 125)) { n0 in
            (0..<30).map { MotionEvidenceMinute(minuteStart: SyntheticDay.dayStart + (n0 + $0) * 60, imuSeconds: 60,
                wristMET: .init(met: 1.0, ood: 0.1, pActive: 0.03, model: "t"), wristMETDemographicOOD: 0.1) }
        }
        run("WristMET 3.0 vs CNN 6.5 (disagree) walk", .walking(30, hr: 110)) { n0 in
            (0..<30).map { MotionEvidenceMinute(minuteStart: SyntheticDay.dayStart + (n0 + $0) * 60, imuSeconds: 60,
                wristMET: .init(met: 3.0, ood: 0.1, pActive: 0.97, model: "t"),
                cnn: .init(met: 6.5, ood: 0.1, model: "c"), wristMETDemographicOOD: 0.1) }
        }
        run("WristMET 3.0 vs CNN 3.2 (agree) walk", .walking(30, hr: 110)) { n0 in
            (0..<30).map { MotionEvidenceMinute(minuteStart: SyntheticDay.dayStart + (n0 + $0) * 60, imuSeconds: 60,
                wristMET: .init(met: 3.0, ood: 0.1, pActive: 0.97, model: "t"),
                cnn: .init(met: 3.2, ood: 0.1, model: "c"), wristMETDemographicOOD: 0.1) }
        }
        run("WristMET 3.0 OOD .9 + CNN OOD .9 walk", .walking(30, hr: 110)) { n0 in
            (0..<30).map { MotionEvidenceMinute(minuteStart: SyntheticDay.dayStart + (n0 + $0) * 60, imuSeconds: 60,
                wristMET: .init(met: 3.0, ood: 0.9, pActive: 0.97, model: "t"),
                cnn: .init(met: 3.2, ood: 0.9, model: "c"), wristMETDemographicOOD: 0.9) }
        }
    }
}
