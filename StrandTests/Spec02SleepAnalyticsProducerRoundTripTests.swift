import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Spec-02 producer → app round trip for `daily.sleep_analytics_v1`. The document is computed in the test by the real
/// producer (`SleepAnalyticsV1.compute(input:config: .v2)`) on a realistic night. It is encoded exactly as the worker
/// does (`SleepAnalyticsAttach`: `JSONEncoder` with sorted keys, rehydrated to a JSON object), put under
/// `daily.sleep_analytics_v1` of a snapshot, sent through JSON bytes, and decoded by the app's own path
/// (`HostedDayResult`). The display model must then show the producer's values, with only display formatting applied.
final class Spec02SleepAnalyticsProducerRoundTripTests: XCTestCase {

    static let readStart = 1_789_000_000 - 1_789_000_000 % 300
    static let nightStart = readStart + 14 * 3600   // 22:00 in the read
    static let nightEnd = nightStart + 8 * 3600     // 06:00

    /// An 8-hour native night: 1 Hz HR, gravity and skin temperature over a 24-hour read (so the hour before onset and
    /// the 30 minutes after the window end are observed), stages in ~15-minute blocks with wake at both ends, a brief
    /// wrist movement every 97 s, and one optical beat per second across the night with genuine beat-to-beat
    /// variation and original adjacency (consecutive ord / seq).
    static func input() -> SleepAnalyticsInput {
        let cycle = ["light", "light", "deep", "deep", "light", "rem"]
        var stages: [StageSegment] = [StageSegment(start: nightStart, end: nightStart + 600, stage: "wake")]
        var t = nightStart + 600
        var k = 0
        while t < nightEnd - 600 {
            stages.append(StageSegment(start: t, end: min(t + 900, nightEnd - 600), stage: cycle[k % cycle.count]))
            t += 900; k += 1
        }
        stages.append(StageSegment(start: nightEnd - 600, end: nightEnd, stage: "wake"))

        let readEnd = readStart + 24 * 3600
        var hr: [HRSample] = [], gravity: [GravitySample] = [], temp: [SkinTempSample] = []
        for ts in readStart..<readEnd {
            let asleep = ts >= nightStart + 600 && ts < nightEnd - 600
            let phase = Double(ts - readStart) / 86_400.0 * 2 * .pi
            hr.append(HRSample(ts: ts, bpm: (asleep ? 54 : 66) + Int(4 * sin(phase)) + (ts % 7 == 0 ? 1 : 0)))
            let wiggle = (ts % 97 == 0) ? 0.05 : 0.0
            gravity.append(GravitySample(ts: ts, x: wiggle, y: 0, z: 1))
            // Skin temperature rises through the night and falls after the window ends.
            let sinceOnset = Double(ts - nightStart) / 3600.0
            let ramp = ts < nightStart ? 0.0 : (ts < nightEnd ? min(1.0, sinceOnset / 2.0) * 80 : 80 - Double(ts - nightEnd) / 60.0)
            temp.append(SkinTempSample(ts: ts, raw: 3250 + Int(30 * cos(phase)) + Int(max(0, ramp))))
        }
        let rrCycle = [1000, 1060, 1000, 1020, 980, 1040, 1000]
        var beats: [RRInterval] = []
        var seq = 0
        for ts in (nightStart + 600)..<(nightEnd - 600) {
            beats.append(RRInterval(ts: ts, rrMs: rrCycle[seq % rrCycle.count], srcChannel: nil, ord: seq, seq: seq))
            seq += 1
        }
        return SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-whoop-RT-\(nightStart)", start: nightStart, end: nightEnd,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stageGridAnchorSeconds: nightStart,
                stages: stages)],
            timezoneId: "Etc/UTC", hr: hr, gravity: gravity, skinTemp: temp, beats: beats,
            deviceFamily: .whoop5, stageSourceVersion: "sleep-stager-v2-roundtrip", inputRevision: 7)
    }

    /// The producer's document, and the app's decode of it after the worker's encoding and the snapshot JSON.
    static func produce() throws -> (producer: SleepAnalyticsDocument, app: SleepAnalyticsDocument) {
        let producer = SleepAnalyticsV1.compute(input: input(), config: .v2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]                  // SleepAnalyticsAttach
        let json = try JSONSerialization.jsonObject(with: encoder.encode(producer))
        let snapshot: [String: Any] = ["result_revision": "sha256:roundtrip",
                                       "daily": ["sleep_analytics_v1": json, "sleep_total_min": 440], "sleep": []]
        let wire = try JSONSerialization.data(withJSONObject: snapshot)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let hosted = try XCTUnwrap(HostedDayResult(day: "2026-09-10", object: object))
        return (producer, try XCTUnwrap(hosted.sleepAnalytics, "the app must decode the producer's document"))
    }

    private func row(_ m: SleepAnalyticsDisplayModel, _ group: String, _ label: String) -> String? {
        m.details.first { $0.id == group }?.rows.first { $0.label == label }?.value
    }

    func testTheAppDecodesExactlyWhatTheProducerComputed() throws {
        let (producer, app) = try Self.produce()
        XCTAssertEqual(app, producer)
        XCTAssertEqual(app.algorithmVersion, SleepAnalyticsV1.algorithmVersion)
        // Every spec-02 output is really computed on this night (not a vacuous comparison of absent values).
        XCTAssertEqual(producer.prvDiagnostics.nightlyPnn50Pct?.status, .available)
        XCTAssertGreaterThan(producer.prvDiagnostics.pnn50PairCount?.value ?? 0, 1000)
        XCTAssertEqual(producer.thermal.preOnsetSlopeCPerHour?.value.status, .available)
        XCTAssertEqual(producer.thermal.postWakeSlopeCPerHour?.value.status, .available)
        let morning = try XCTUnwrap(producer.morningResponse)
        XCTAssertEqual(morning.heartRate.change.status, .available)
        XCTAssertEqual(morning.skinTemperature.change.status, .available)
        XCTAssertNotNil(producer.movement.stageMovement)
    }

    func testPnn50AndItsDenominatorShowTheProducerValues() throws {
        let (producer, app) = try Self.produce()
        let m = SleepAnalyticsDisplayModel(document: app, sessions: [])
        let prv = producer.prvDiagnostics
        let pct = try XCTUnwrap(prv.nightlyPnn50Pct?.value)
        let pairs = try XCTUnwrap(prv.pnn50PairCount?.value)
        let nn50 = try XCTUnwrap(prv.nn50Count?.value)
        XCTAssertEqual(pct, 100.0 * Double(nn50) / Double(pairs), accuracy: 1e-9, "a pooled proportion")
        XCTAssertEqual(row(m, "prv", "pNN50 (optical PRV)"),
                       "\(String(format: "%.1f", pct))% · \(SleepAnalyticsFormat.count(nn50)) of "
                       + "\(SleepAnalyticsFormat.count(pairs)) adjacent pairs differ by > 50 ms")
        XCTAssertEqual(row(m, "prv", "pNN50 definition"), prv.pnn50Method)
        XCTAssertEqual(row(m, "prv", "Source"), "Optical pulse intervals (pulse-rate variability), not ECG")
    }

    func testBothThermalSlopesShowTheProducerValues() throws {
        let (producer, app) = try Self.produce()
        let m = SleepAnalyticsDisplayModel(document: app, sessions: [])
        for (label, slope) in [("Hour before sleep onset", producer.thermal.preOnsetSlopeCPerHour),
                               ("30 min after estimated window end", producer.thermal.postWakeSlopeCPerHour)] {
            let s = try XCTUnwrap(slope)
            let v = try XCTUnwrap(s.value.value)
            let sign = v < 0 ? "−" : "+"
            let shown = try XCTUnwrap(row(m, "thermalTrend", label), label)
            XCTAssertTrue(shown.hasPrefix("\(sign)\(String(format: "%.1f", abs(v))) °C/h over \(s.validMinutes) of "
                                          + "\(s.eligibleMinutes) min"), "\(label): \(shown)")
        }
    }

    func testTheMorningResponseShowsEachSignalsOwnMediansAndCoverage() throws {
        let (producer, app) = try Self.produce()
        let m = SleepAnalyticsDisplayModel(document: app, sessions: [])
        let morning = try XCTUnwrap(producer.morningResponse)
        for (label, w) in [("Heart rate, 30 min before → after", morning.heartRate),
                           ("Skin temperature, 30 min before → after", morning.skinTemperature),
                           ("Movement, 30 min before → after", morning.movement)] {
            let coverage = "before \(w.beforeValidMinutes) of \(w.eligibleMinutesEachSide) min · after "
                + "\(w.afterValidMinutes) of \(w.eligibleMinutesEachSide) min valid"
            let shown = try XCTUnwrap(row(m, "morningResponse", label), label)
            XCTAssertTrue(shown.hasSuffix(coverage), "\(label): \(shown)")
            if let before = w.beforeMedian.value, let after = w.afterMedian.value {
                XCTAssertTrue(shown.hasPrefix("\(SleepAnalyticsFormat.signalValue(before, unit: w.unit)) → "
                                              + "\(SleepAnalyticsFormat.signalValue(after, unit: w.unit))"),
                              "\(label): \(shown)")
                if let change = w.change.value {
                    XCTAssertTrue(shown.contains("(\(SleepAnalyticsFormat.signedSignalValue(change, unit: w.unit)))"),
                                  "\(label): \(shown)")
                }
            } else {
                XCTAssertTrue(shown.hasPrefix("Unavailable"), "\(label): \(shown)")
            }
        }
        XCTAssertEqual(row(m, "morningResponse", "Definition"), morning.algorithmVersion)
    }

    func testStageMovementShowsTheProducerShares() throws {
        let (producer, app) = try Self.produce()
        let m = SleepAnalyticsDisplayModel(document: app, sessions: [])
        let stages = try XCTUnwrap(producer.movement.stageMovement)
        var checked = 0
        for s in stages where s.label != .unknown {
            let title = ["wake": "Wake", "light": "Light", "deep": "Deep", "rem": "REM"][s.label.rawValue]! + " (est.)"
            let shown = try XCTUnwrap(row(m, "stageMovement", title), title)
            if let pct = s.movementPercentage.value, s.movementPercentage.status != .unavailable {
                XCTAssertTrue(shown.hasPrefix(SleepAnalyticsFormat.percentValue(pct)), "\(title): \(shown)")
                if let eligible = s.eligibleSeconds.value {
                    XCTAssertTrue(shown.contains("of \(SleepAnalyticsFormat.minutes(eligible)) moving"), "\(title): \(shown)")
                }
                if let rate = s.movementBoutsPerEligibleHour.value {
                    XCTAssertTrue(shown.contains(String(format: "%.1f bouts/h", rate)), "\(title): \(shown)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
        XCTAssertEqual(row(m, "stageMovement", "Note"),
                       "Stages are estimated partly from wrist movement, so movement and stage are not independent")
    }
}
