import XCTest
@testable import StrandAnalytics

/// Engine-level contract tests: determinism, JSON round trip, causal cutoff, history guard.
final class PCEngineTests: XCTestCase {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let tzId = "America/Los_Angeles"

    static func identity() -> PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: tzId,
                       dayWindow: PC.Engine.dayInterval(day, timezoneId: tzId))
    }

    static func input(mode: PC.ProcessingMode = .retrospective, cutoff: Int? = nil,
                      extraHR: [PC.HeartRateObservation] = []) -> PC.DayInput {
        let id = identity()
        let start = id.dayWindow.start
        var hr: [PC.HeartRateObservation] = []
        for t in stride(from: start + 3600, to: start + 3600 * 3, by: 1) {
            hr.append(.init(ts: t, bpm: 60 + (t % 7), availableAt: t + 120))
        }
        hr += extraHR
        let series = PC.MeasurementInput(
            metric: .hrvRmssd,
            method: .init(id: "series.hrv_rmssd.5min", algorithmVersion: "frwhoop-series-2", aggregation: .window,
                          windowS: 300, units: "ms"),
            source: .init(product: .metricSeries, key: "hrv_rmssd_ms@\(start + 3900)"),
            value: 42, support: .init(start + 3900, start + 4200), sampleCount: 300, coverage: 1,
            availableAt: start + 4500)
        return PC.DayInput(identity: id, mode: mode, availabilityCutoff: cutoff ?? (id.dayWindow.end + 40 * 3600),
                           generatedAt: id.dayWindow.end + 40 * 3600, heartRate: hr, measurements: [series],
                           regime: .init(scoringAlgorithmVersion: "frwhoop-server-1",
                                         seriesAlgorithmVersion: "frwhoop-series-2"))
    }

    func testDocumentIsDeterministicAndRoundTripsThroughJSON() throws {
        let a = PC.Engine.buildDay(Self.input(), history: .empty)
        let b = PC.Engine.buildDay(Self.input(), history: .empty)
        let ea = try PC.encoder().encode(a)
        let eb = try PC.encoder().encode(b)
        XCTAssertEqual(ea, eb)
        let decoded = try PC.decoder().decode(PC.DayDocument.self, from: ea)
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(try PC.encoder().encode(decoded), ea)
        XCTAssertEqual(a.header.interpretation.finality, .final)
        XCTAssertEqual(a.header.schemaVersion, PC.schemaVersion)
        XCTAssertFalse(a.header.policyFingerprint.isEmpty)
    }

    func testEveryEnvelopeHasItsWholeSupportAndADeterministicId() {
        let doc = PC.Engine.buildDay(Self.input(), history: .empty)
        let hrv = doc.envelopes.filter { $0.metric == .hrvRmssd }
        XCTAssertEqual(hrv.count, 1)
        XCTAssertEqual(hrv[0].support.duration, 300)
        XCTAssertEqual(hrv[0].id, "series.hrv_rmssd.5min@\(hrv[0].support.start)-\(hrv[0].support.end)")
        // Derived heart-rate windows: 2 h of samples → 24 windows of 5 minutes.
        let hr = doc.envelopes.filter { $0.metric == .heartRate }
        XCTAssertEqual(hr.count, 24)
        XCTAssertTrue(hr.allSatisfy { $0.support.duration == 300 && $0.source.product == .contextDerived })
        for e in doc.envelopes { XCTAssertTrue(PC.IntervalAlgebra.reconciles(e.activity)) }
    }

    func testCausalReplayAtTheSameCutoffIgnoresLaterData() throws {
        let id = Self.identity()
        let cutoff = id.dayWindow.start + 3600 * 2
        let original = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff), history: .empty)
        // Late rows: a backfill whose sensor time is inside the window but which arrived after the cutoff,
        // plus rows from after the cutoff.
        let late = (0..<600).map { PC.HeartRateObservation(ts: id.dayWindow.start + 3600 + $0, bpm: 140,
                                                            availableAt: cutoff + 10) }
        let replay = PC.Engine.buildDay(Self.input(mode: .causalLive, cutoff: cutoff, extraHR: late),
                                        history: .empty)
        XCTAssertEqual(original.header.inputFingerprint, replay.header.inputFingerprint)
        XCTAssertEqual(try PC.encoder().encode(original), try PC.encoder().encode(replay))
        XCTAssertEqual(original.header.interpretation.mode, .causalLive)
        XCTAssertEqual(original.header.interpretation.finality, .provisional)
        // A measurement whose support ends after the cutoff is not part of the live document.
        XCTAssertTrue(original.envelopes.allSatisfy { $0.support.end <= cutoff })
    }

    func testHistoryFromTheSameDayOrLaterIsDropped() {
        let v = PC.DailyValue(day: Self.day, seriesKey: "hrv_rmssd.sleep_night", regimeKey: "r", metric: .hrvRmssd,
                              value: 50, units: "ms", supportCount: 1, supportUnit: "night", supportS: 1,
                              mode: .retrospective, finality: .final)
        let doc = PC.Engine.buildDay(Self.input(), history: .init(dailyValues: [v]))
        XCTAssertTrue(doc.statusReasons.contains(PC.Engine.historyFromFutureDropped))
    }

    func testPolicyChangeChangesTheFingerprint() {
        var p = PC.Policy()
        let a = p.fingerprint
        p.join.precedingLookbackS += 1
        XCTAssertNotEqual(a, p.fingerprint)
    }
}
