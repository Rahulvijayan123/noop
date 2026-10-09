import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// D4-09 worker inputs: the predecessor-regime read (other devices' parent daily values, causal cutoff), the
/// positively identified hardware family it is judged by, and the decoder version on the day's regime. The day's
/// own regime still carries no current device family or firmware (RC-13).
final class ContextLanePredecessorRegimeTests: XCTestCase {
    typealias PC = PhysiologyContext

    // 2026-10-03T00:00:00Z
    let dayStart = 1_790_985_600

    func testHardwareFamilyIsPositivelyIdentifiedOrUnknown() {
        func f(_ family: String?, _ kind: String? = "noop_push") -> String? {
            ContextInputs.hardwareFamily(.init(family: family, firmware: nil, sourceKind: kind))
        }
        XCTAssertEqual(f("WHOOP 4.0"), "whoop4")
        XCTAssertEqual(f("4.0"), "whoop4")
        XCTAssertEqual(f("WHOOP 5.0 / MG"), "whoop5")
        XCTAssertEqual(f("WHOOP MG"), "whoop5")
        XCTAssertNil(f("WHOOP"), "a bare label is written for both families")
        XCTAssertNil(f(nil))
        XCTAssertEqual(f(nil, "oura_ring"), "oura_ring")
        XCTAssertNil(ContextInputs.hardwareFamily(nil))
    }

    func testPredecessorRowsGroupPerDeviceWithTheirFamilies() throws {
        func value(_ day: String, _ v: Double) -> String {
            let dv = PC.DailyValue(day: day, seriesKey: "heart_rate.stable_awake_5min", regimeKey: "r1",
                                   metric: .heartRate, value: v, units: "bpm", supportCount: 4, supportUnit: "window",
                                   supportS: 1200, mode: .retrospective, finality: .final)
            return String(data: try! JSONEncoder().encode(dv), encoding: .utf8)!
        }
        let rows: [[String: String]] = [
            ["device_id": "b", "value": value("2026-09-01", 66), "family": "WHOOP 4.0", "firmware": "41", "source_kind": "noop_push"],
            ["device_id": "a", "value": value("2026-09-01", 65), "family": "WHOOP 5.0 / MG", "firmware": "", "source_kind": "noop_push"],
            ["device_id": "a", "value": value("2026-09-02", 67), "family": "WHOOP 5.0 / MG", "firmware": "", "source_kind": "noop_push"],
            ["device_id": "a", "value": "not json", "family": "WHOOP 5.0 / MG", "firmware": "", "source_kind": "noop_push"],
        ]
        var skipped = 0
        let ps = ContextInputs.predecessorHistories(rows, successorFamily: "whoop5", skipped: &skipped)
        XCTAssertEqual(ps.map(\.deviceScope), ["a", "b"])
        XCTAssertEqual(ps[0].dailyValues.map(\.value), [65, 67])
        XCTAssertEqual(ps[0].hardwareFamily, "whoop5")
        XCTAssertEqual(ps[1].hardwareFamily, "whoop4")
        XCTAssertEqual(ps[0].successorHardwareFamily, "whoop5")
        XCTAssertNil(ps[1].firmware, "no effective-dated firmware: never used to split")
        XCTAssertEqual(skipped, 1)
        // The SQL reads other devices only, parent series only, under the causal cutoff.
        let sql = ContextInputs.predecessorDailyValuesSQL
        XCTAssertTrue(sql.contains("v.device_id <> $2::uuid"))
        XCTAssertTrue(sql.contains("position('.ctx_' in v.series_key) = 0"))
        XCTAssertTrue(sql.contains("pd.published_at <= to_timestamp"))
        XCTAssertEqual(ContextInputs.predecessorHorizonDays, 28 + 56)
    }

    func testTheDaysRegimeCarriesItsDecoderVersionButNoCurrentDeviceAttribute() {
        let runs = [
            PC.ActivityIntervalInput(interval: .init(dayStart, dayStart + 60), activityClass: "sitting",
                                     confidence: 0.8, revision: 1, decoderVersion: "hsmm-1.8"),
            PC.ActivityIntervalInput(interval: .init(dayStart + 60, dayStart + 120), activityClass: "sitting",
                                     confidence: 0.8, revision: 1, decoderVersion: "hsmm-1.7"),
        ]
        let r = ContextInputs.deviceRegime(.init(family: "WHOOP 5.0 / MG", firmware: "51", sourceKind: "noop_push"),
                                           intervals: runs)
        XCTAssertEqual(r.decoderVersion, "hsmm-1.7+hsmm-1.8")
        XCTAssertNil(r.deviceFamily)
        XCTAssertNil(r.firmware)
        XCTAssertNil(ContextInputs.deviceRegime(nil).decoderVersion)
    }

    func testAssembleHandsThePredecessorsToTheEngineHistory() throws {
        var l = ContextDaySim.representativeDay(dayStart: dayStart).loaded()
        let p = PC.PredecessorRegimeHistory(deviceScope: "old", hardwareFamily: "whoop5",
                                            successorHardwareFamily: "whoop5", dailyValues: [])
        l.predecessors = [p]
        let job = ContextInputs.Job(userId: "u", deviceId: "d", day: "2026-10-03", mode: .retrospective,
                                    inputRevision: 3, leaseToken: "t", timezoneId: "UTC", cutoffOverride: nil,
                                    claimedAt: dayStart + 40 * 3_600)
        let a = ContextInputs.assemble(l, job: job,
                                       windows: try XCTUnwrap(ContextInputs.windows(day: "2026-10-03", timezoneId: "UTC")))
        XCTAssertEqual(a.history.predecessors, [p])
        XCTAssertTrue(a.input.inputRevisions.contains { $0.input == "predecessor_daily_values" && $0.revision == "old:0:whoop5" })
    }
}
