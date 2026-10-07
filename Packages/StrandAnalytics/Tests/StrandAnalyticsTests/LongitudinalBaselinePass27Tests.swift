import XCTest
@testable import StrandAnalytics

/// Medication labels + IMU usual. Charge / the other 17 rows stay on their own tapes.
final class LongitudinalBaselinePass27Tests: XCTestCase {

    func testScheduledTakenDoesNotConfoundUsual() {
        let taken = LBDayLog(extraMed: false, scheduledMed: .taken)
        XCTAssertFalse(taken.confoundsUsual)
        XCTAssertTrue(taken.summaryLine.contains("Took scheduled"))
        let extra = LBDayLog(extraMed: true, scheduledMed: .taken)
        XCTAssertTrue(extra.confoundsUsual)
        let missed = LBDayLog(scheduledMed: .missed)
        XCTAssertFalse(missed.confoundsUsual)
    }

    func testOldDayLogJSONStillDecodes() throws {
        let old = #"{"workout":"none","alcohol":false,"travel":false,"feltIll":false,"sleepTypical":true,"dietTypical":true,"extraMed":false,"mood":"okay","activeWindow":"spread","energy":"steady"}"#
        let decoded = try JSONDecoder().decode(LBDayLog.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.scheduledMed, .unspecified)
        XCTAssertNil(decoded.medNote)
    }

    func testMedicationLabelNeverClaimsCause() {
        let start = LBTreatmentEvent(trialId: "t", type: .start, civilDay: "2026-04-01",
                                     clockTime: "08:00", displayName: "Course A", kind: .medication,
                                     doseText: "5 mg", schedule: .daily)
        let log = LBDayLog(extraMed: true, scheduledMed: .taken)
        let card = LBMedicationDayLabel.make(asOf: "2026-04-12", events: [start], log: log)
        XCTAssertTrue(card.wearerLine.contains("Course A 5 mg"))
        XCTAssertTrue(card.wearerLine.contains("Took scheduled"))
        XCTAssertTrue(card.wearerLine.contains("Another medication"))
        XCTAssertFalse(card.wearerLine.lowercased().contains("caused"))
        XCTAssertTrue(log.confoundsUsual)
    }

    func testOldTreatmentJSONGetsDailySchedule() throws {
        let old = #"{"trialId":"t","type":"start","civilDay":"2026-04-01","clockTime":"08:00","displayName":"Course A","kind":"medication","enteredBy":"patient","primarySeries":[]}"#
        let ev = try JSONDecoder().decode(LBTreatmentEvent.self, from: Data(old.utf8))
        XCTAssertEqual(ev.schedule, .daily)
    }

    func testImuEnergyIsItsOwnSeries() {
        XCTAssertEqual(LBSeries.wakingImuEnergy.context, .wakingLoad)
        XCTAssertEqual(LBSeries.wakingImuEnergy.biometricFamily, "imu")
        XCTAssertNotEqual(LBSeries.wakingImuEnergy.biometricFamily, LBSeries.wakingSteps.biometricFamily)
        XCTAssertFalse(LBSeries.wakingImuEnergy.hasDailyMetricColumn)
        XCTAssertFalse(LBSeries.wakingImuEnergy.usesLog)
        XCTAssertEqual(LongitudinalBaseline.nLongEstablished(for: .wakingImuEnergy), 21)
    }

    func testImuDayEnergyAndMerge() {
        let still = (0..<120).map { WatchdogIMUSample(ts: 1_700_000_000 + $0, x: 0, y: 0, z: 1, dynAccel: 0.02) }
        let move = (0..<120).map { WatchdogIMUSample(ts: 1_700_000_000 + $0, x: 0.4, y: 0, z: 1, dynAccel: 0.40) }
        let a = LBImuDaily.dayEnergy(from: still)!
        let b = LBImuDaily.dayEnergy(from: move)!
        XCTAssertLessThan(a.energy, b.energy)
        XCTAssertGreaterThan(a.minutes, 0)
        let first = LBImuDaily.merge(existing: nil, day: "2026-09-01", energy: 0.10, minutes: 40)
        XCTAssertEqual(first.qualityStatus, .lowQuality)
        let second = LBImuDaily.merge(existing: first, day: "2026-09-01", energy: 0.20, minutes: 40)
        XCTAssertEqual(second.qualityStatus, .ok)
        XCTAssertEqual(second.coverage ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(second.value ?? 0, 0.15, accuracy: 0.02)
    }

    func testOverlappingImuWindowsDoNotDoubleCount() {
        let window = (0..<4_000).map { WatchdogIMUSample(ts: 1_700_000_000 + $0, x: 0, y: 0, z: 1, dynAccel: 0.10) }
        var acc = LBImuDayAccumulator(day: "2026-09-01")
        XCTAssertTrue(acc.add(window))
        let minutesOnce = acc.minutes
        let meanOnce = acc.meanEnergy ?? 0
        XCTAssertFalse(acc.add(window), "same timestamps must be ignored")
        XCTAssertEqual(acc.minutes, minutesOnce, accuracy: 0.01)
        XCTAssertEqual(acc.meanEnergy ?? 0, meanOnce, accuracy: 1e-9)
        let next = (4_000..<4_120).map { WatchdogIMUSample(ts: 1_700_000_000 + $0, x: 0, y: 0, z: 1, dynAccel: 0.50) }
        XCTAssertTrue(acc.add(next))
        XCTAssertGreaterThan(acc.minutes, minutesOnce)
        XCTAssertGreaterThan(acc.meanEnergy ?? 0, meanOnce)
        XCTAssertEqual(acc.observation.qualityStatus, .ok)
    }

    func testImuUsualDoesNotTrainOnSleepRHRTape() {
        let t = LongitudinalBaseline.isoEpochDay("2026-05-01")!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        let rhr = (t - 60...t).map {
            LBDailyObservation(day: iso($0), value: 60, qualityStatus: .ok)
        }
        let imuEmpty = LongitudinalBaseline.evaluate(asOf: "2026-05-01", series: .wakingImuEnergy,
                                                     observations: rhr, replay: false)
        XCTAssertNil(imuEmpty.copy7)
        let imuTape = (t - 60...t).map {
            LBDailyObservation(day: iso($0), value: 0.14, qualityStatus: .ok, coverage: 90)
        }
        let imu = LongitudinalBaseline.evaluate(asOf: "2026-05-01", series: .wakingImuEnergy,
                                                observations: imuTape, replay: true)
        XCTAssertTrue(imu.show7)
        XCTAssertTrue(imu.establishedLong)
        XCTAssertEqual(imu.series, .wakingImuEnergy)
    }
}
