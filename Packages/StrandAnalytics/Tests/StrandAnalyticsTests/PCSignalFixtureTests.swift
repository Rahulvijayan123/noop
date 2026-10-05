import XCTest
@testable import StrandAnalytics

/// Shared fixtures for the signal / motion / eligibility tests (UTC day so local and UTC seconds coincide).
enum PCSignalFixtures {
    typealias PC = PhysiologyContext

    static let day = "2026-10-01"
    static let tzId = "UTC"

    static var identity: PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-signal", day: day, timezoneId: tzId,
                       dayWindow: PC.Engine.dayInterval(day, timezoneId: tzId))
    }
    static var dayStart: Int { identity.dayWindow.start }
    /// 10:00 on the fixture day.
    static var t0: Int { dayStart + 10 * 3600 }

    static func input(heartRate: [PC.HeartRateObservation] = [], beats: [PC.BeatIntervalObservation] = [],
                      motion: [PC.MotionObservation] = [], steps: [PC.StepObservation] = [],
                      skin: [PC.SkinTemperatureObservation] = [], measurements: [PC.MeasurementInput] = [],
                      placements: [PC.PlacementInput] = [], mode: PC.ProcessingMode = .retrospective,
                      cutoff: Int? = nil, regime: PC.DeviceRegimeInput? = nil) -> PC.DayInput {
        let id = identity
        return PC.DayInput(identity: id, mode: mode, availabilityCutoff: cutoff ?? (id.dayWindow.end + 40 * 3600),
                           generatedAt: id.dayWindow.end + 2 * 3600, heartRate: heartRate, beatIntervals: beats,
                           motion: motion, steps: steps, skinTemperature: skin, measurements: measurements,
                           placements: placements,
                           regime: regime ?? .init(scoringAlgorithmVersion: "frwhoop-server-1",
                                                   seriesAlgorithmVersion: "frwhoop-series-2"))
    }

    static func sanitize(_ input: PC.DayInput) -> (PC.SanitizedObservations, PC.InputContractReport) {
        PC.SignalValidityEngine.sanitize(input, config: .init())
    }

    static func method(_ id: String, aggregation: PC.Aggregation = .window, windowS: Int = 300,
                       units: String = "ms", version: String = "frwhoop-series-2") -> PC.MethodRef {
        PC.MethodRef(id: id, algorithmVersion: version, aggregation: aggregation, windowS: windowS, units: units)
    }

    static func measurement(_ metric: PC.MetricKind, _ support: PC.Interval, method m: PC.MethodRef? = nil,
                            value: Double? = 40) -> PC.MeasurementInput {
        let mm = m ?? method("series.\(metric.rawValue).5min")
        return PC.MeasurementInput(metric: metric, method: mm,
                                   source: .init(product: .metricSeries, key: "\(metric.rawValue)@\(support.start)"),
                                   value: value, support: support)
    }

    /// A hand-built HR-independent track from labelled spans.
    static func track(_ spans: [(Int, Int, String?)], source: PC.ActivitySource = .strapMotion,
                      heartRateDependent: Bool = false) -> PC.ResolvedTrack {
        let records = spans.map { s in
            PC.LabelRecord(interval: .init(s.0, s.1), label: s.2, unknownFraction: s.2 == nil ? 1 : 0,
                           tieBreak: "t:\(s.0)")
        }
        return PC.IntervalAlgebra.resolve(records, source: source, heartRateDependent: heartRateDependent)
    }

    /// 1 Hz beats with a given RR (ms) per beat index, one beat per second starting at `start`.
    static func beatsPerSecond(from start: Int, count: Int, channel: Int? = nil,
                               rr: (Int) -> Int = { _ in 1000 }) -> [PC.BeatIntervalObservation] {
        (0..<count).map { i in PC.BeatIntervalObservation(ts: start + i, rrMs: rr(i), seq: 0, channel: channel) }
    }

    static let awakeWorn = PC.SleepWearContext(sleepState: .awake, sleepEvidence: ["outside_detected_sleep"],
                                               sleepDependsOnHeartSignals: false, wearState: .worn,
                                               wearEvidence: ["wear_events"], reasons: [])
    static let validSignal = PC.SignalValidity(state: .valid, reasons: [])
}

/// Sanity checks of the fixtures themselves (so a broken fixture fails loudly, not as a mystery elsewhere).
final class PCSignalFixtureTests: XCTestCase {
    typealias F = PCSignalFixtures

    func testFixtureDayIsUTCAndTwentyFourHours() {
        XCTAssertEqual(F.identity.dayWindow.duration, 86_400)
        XCTAssertEqual(F.t0 - F.dayStart, 36_000)
    }

    func testHandBuiltTrackReconciles() {
        let tr = F.track([(F.t0, F.t0 + 100, "still"), (F.t0 + 150, F.t0 + 200, nil)])
        let c = PhysiologyContext.IntervalAlgebra.composition(over: .init(F.t0, F.t0 + 300), track: tr)
        XCTAssertEqual(c.seconds(of: "still"), 100)
        XCTAssertEqual(c.unknownS, 50)
        XCTAssertEqual(c.uncoveredS, 150)
        XCTAssertTrue(PhysiologyContext.IntervalAlgebra.reconciles(c))
    }
}
