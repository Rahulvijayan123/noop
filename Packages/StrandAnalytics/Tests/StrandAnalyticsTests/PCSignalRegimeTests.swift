import XCTest
@testable import StrandAnalytics

/// V04: regime boundaries and comparability; the availability / comparability matrix.
final class PCSignalRegimeTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias E = PhysiologyContext.SignalValidityEngine

    var d0: Int { F.dayStart }
    let device = PC.DeviceRegimeInput(vendor: "whoop", deviceFamily: "whoop5", sourceKind: "push", firmware: "41.2.0",
                                      decoderVersion: "dec-7", scoringAlgorithmVersion: "frwhoop-server-1",
                                      seriesAlgorithmVersion: "frwhoop-series-2")

    func regimeAt(_ start: Int, _ timeline: PC.RegimeTimeline, duration: Int = 300,
                  method: PC.MethodRef? = nil, device dev: PC.DeviceRegimeInput? = nil) -> PC.MeasurementRegime {
        E.regime(for: F.measurement(.hrvRmssd, .init(start, start + duration), method: method), timeline: timeline,
                 device: dev ?? device)
    }

    func incompatibleReasons(_ c: PC.RegimeComparability) -> [PC.ReasonCode]? {
        if case .incompatible(let r) = c { return r }
        return nil
    }

    // MARK: Placement

    func testPlacementChangeMidDayIsABoundaryWithDifferentRegimeKeys() {
        let placements = [
            PC.PlacementInput(start: d0 + 2 * 3600, end: nil, placement: "wrist", source: "user", revision: 1),
            PC.PlacementInput(start: d0 + 12 * 3600, end: nil, placement: "bicep", source: "user", revision: 2),
        ]
        let timeline = E.regimeTimeline(F.input(placements: placements), config: .init())
        let window = E.readWindow(F.identity)
        XCTAssertEqual(timeline.placements, [
            .init(interval: .init(window.start, d0 + 2 * 3600), placement: "unknown", placementSource: "none"),
            .init(interval: .init(d0 + 2 * 3600, d0 + 12 * 3600), placement: "wrist", placementSource: "user"),
            .init(interval: .init(d0 + 12 * 3600, window.end), placement: "bicep", placementSource: "user"),
        ])
        XCTAssertEqual(timeline.boundaries.map(\.kind), ["placement_history_start", "placement"])
        XCTAssertEqual(timeline.boundaries[1].at, d0 + 12 * 3600)
        XCTAssertEqual(timeline.boundaries[1].fromValue, "wrist")
        XCTAssertEqual(timeline.boundaries[1].toValue, "bicep")

        let morning = regimeAt(d0 + 3 * 3600, timeline)
        let evening = regimeAt(d0 + 13 * 3600, timeline)
        XCTAssertEqual(morning.placement, "wrist")
        XCTAssertEqual(evening.placement, "bicep")
        XCTAssertNotEqual(morning.key, evening.key)
        XCTAssertEqual(incompatibleReasons(E.comparability(morning, evening, config: .init())), [E.placementDiffers])
        // A support that spans the change belongs to neither placement.
        let spanning = regimeAt(d0 + 12 * 3600 - 120, timeline)
        XCTAssertEqual(spanning.placement, "mixed")
        XCTAssertEqual(incompatibleReasons(E.comparability(spanning, morning, config: .init())), [E.placementMixed])
    }

    func testHistoryBeforeTheFirstPlacementRecordIsUnknownNotBackFilled() {
        let placements = [PC.PlacementInput(start: d0 + 6 * 3600, end: nil, placement: "wrist", source: "user",
                                            revision: 1)]
        let timeline = E.regimeTimeline(F.input(placements: placements), config: .init())
        let before = regimeAt(d0 + 3600, timeline)
        let after = regimeAt(d0 + 7 * 3600, timeline)
        XCTAssertEqual(before.placement, "unknown")
        XCTAssertEqual(before.placementSource, "none")
        XCTAssertEqual(after.placement, "wrist")
        XCTAssertEqual(incompatibleReasons(E.comparability(before, after, config: .init())), [E.placementUnknown])
        // No records at all: everything is unknown, nothing is assumed from "today".
        let none = E.regimeTimeline(F.input(), config: .init())
        XCTAssertEqual(none.placements.map(\.placement), ["unknown"])
        XCTAssertEqual(none.boundaries, [])
    }

    func testOverlappingPlacementRecordsResolveByRevisionAndGapsStayUnknown() {
        let placements = [
            PC.PlacementInput(start: d0 + 4 * 3600, end: d0 + 6 * 3600, placement: "bicep", source: "device", revision: 1),
            PC.PlacementInput(start: d0 + 2 * 3600, end: d0 + 10 * 3600, placement: "Wrist", source: "user", revision: 3),
            PC.PlacementInput(start: d0 + 14 * 3600, end: nil, placement: "wrist", source: "user", revision: 4),
        ]
        let timeline = E.regimeTimeline(F.input(placements: placements), config: .init())
        let named = timeline.placements.filter { $0.placement != "unknown" }
        XCTAssertEqual(named.map(\.interval), [.init(d0 + 2 * 3600, d0 + 10 * 3600), .init(d0 + 14 * 3600, E.readWindow(F.identity).end)])
        XCTAssertTrue(named.allSatisfy { $0.placement == "wrist" })
        XCTAssertEqual(regimeAt(d0 + 12 * 3600, timeline).placement, "unknown", "a gap between records is not bridged")
        let gap = timeline.boundaries.first { $0.at == d0 + 10 * 3600 }
        XCTAssertEqual(gap?.reasons, [E.placementRecordGap])
    }

    /// RC-17: the worker reads device-scoped and account-level (`device_id is null`) placement rows together. A
    /// device-scoped record wins where they overlap, whatever the revisions (the app's `PlacementStore` rule);
    /// the account-level record applies only where the device has no record; one scope resolves by revision.
    func testDeviceScopedPlacementWinsOverAnAccountLevelOneWhereTheyOverlap() {
        let placements = [
            // An account-level declaration with a high revision, covering 02:00 onwards.
            PC.PlacementInput(start: d0 + 2 * 3600, end: nil, placement: "bicep", source: "user", revision: 9,
                              scope: "account"),
            // Device-scoped records (nil scope = device), older revisions, overlapping it 06:00–12:00.
            PC.PlacementInput(start: d0 + 6 * 3600, end: d0 + 12 * 3600, placement: "wrist", source: "user",
                              revision: 1),
            PC.PlacementInput(start: d0 + 8 * 3600, end: d0 + 10 * 3600, placement: "other", source: "device",
                              revision: 2, scope: "device"),
        ]
        let timeline = E.regimeTimeline(F.input(placements: placements), config: .init())
        let end = E.readWindow(F.identity).end
        XCTAssertEqual(timeline.placements.filter { $0.placement != "unknown" }.map { "\($0.placement)|\($0.scope ?? "-")" },
                       ["bicep|account", "wrist|-", "other|-", "wrist|-", "bicep|account"])
        XCTAssertEqual(timeline.placements.filter { $0.placement != "unknown" }.map(\.interval), [
            .init(d0 + 2 * 3600, d0 + 6 * 3600), .init(d0 + 6 * 3600, d0 + 8 * 3600),
            .init(d0 + 8 * 3600, d0 + 10 * 3600), .init(d0 + 10 * 3600, d0 + 12 * 3600), .init(d0 + 12 * 3600, end),
        ])
        XCTAssertEqual(regimeAt(d0 + 7 * 3600, timeline).placement, "wrist", "device record beats revision 9")
        XCTAssertEqual(regimeAt(d0 + 9 * 3600, timeline).placement, "other", "same scope: higher revision wins")
        XCTAssertEqual(regimeAt(d0 + 3 * 3600, timeline).placement, "bicep", "account record fills the device's gap")
        XCTAssertEqual(regimeAt(d0 + 14 * 3600, timeline).placement, "bicep")
        XCTAssertEqual(regimeAt(d0 + 3600, timeline).placement, "unknown", "never back-filled before any record")
        // Input order does not matter, and an all-device input resolves exactly as before (scope nil == device).
        XCTAssertEqual(E.regimeTimeline(F.input(placements: placements.reversed()), config: .init()), timeline)
        let deviceOnly = placements.map { p -> PC.PlacementInput in var q = p; q.scope = nil; return q }
        let legacy = E.regimeTimeline(F.input(placements: deviceOnly), config: .init())
        XCTAssertEqual(regimeAt(d0 + 7 * 3600, legacy).placement, "bicep", "one scope: revision 9 wins")
        XCTAssertTrue(legacy.placements.allSatisfy { $0.scope == nil })
    }

    // MARK: Device and method

    func testFirmwareVendorAndUnknownAttributesAreIncompatible() {
        let timeline = E.regimeTimeline(F.input(), config: .init())
        let a = regimeAt(F.t0, timeline)
        var other = device
        other.firmware = "42.0.0"
        let b = regimeAt(F.t0, timeline, device: other)
        XCTAssertEqual(incompatibleReasons(E.comparability(a, b, config: .init())), [E.firmwareDiffers])
        other.firmware = nil
        XCTAssertEqual(incompatibleReasons(E.comparability(a, regimeAt(F.t0, timeline, device: other), config: .init())),
                       [E.firmwareUnknown])
        var polar = device
        polar.vendor = "polar"
        XCTAssertEqual(incompatibleReasons(E.comparability(a, regimeAt(F.t0, timeline, device: polar), config: .init())),
                       [E.vendorDiffers])
    }

    func testMethodAlgorithmAndWindowChangesAreIncompatible() {
        let timeline = E.regimeTimeline(F.input(), config: .init())
        let base = regimeAt(F.t0, timeline)
        let newAlgo = regimeAt(F.t0, timeline, method: F.method("series.hrv_rmssd.5min", version: "frwhoop-series-3"))
        XCTAssertEqual(incompatibleReasons(E.comparability(base, newAlgo, config: .init())), [E.algorithmVersionDiffers])
        let oneMinute = regimeAt(F.t0, timeline, duration: 60, method: F.method("series.hrv_rmssd.5min", windowS: 60))
        XCTAssertEqual(incompatibleReasons(E.comparability(base, oneMinute, config: .init())), [E.windowDiffers])
        let nightly = regimeAt(F.t0, timeline, method: F.method("snapshot.hrv_rmssd.night", aggregation: .session,
                                                                windowS: 27_000, version: "frwhoop-server-1"))
        let reasons = incompatibleReasons(E.comparability(base, nightly, config: .init())) ?? []
        XCTAssertTrue(reasons.contains(E.methodDiffers))
        XCTAssertTrue(reasons.contains(E.aggregationDiffers))
    }

    func testIdenticalRegimesAreComparableAndSessionLengthIsNotAWindowChange() {
        let timeline = E.regimeTimeline(F.input(), config: .init())
        let a = regimeAt(F.t0, timeline)
        let b = regimeAt(F.t0 + 3600, timeline)
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(E.comparability(a, b, config: .init()), .comparable(rule: "identical_regime"))
        // Two nights of different length are the same session-aggregate method.
        let n1 = regimeAt(F.t0, timeline, method: F.method("snapshot.hrv_rmssd.night", aggregation: .session,
                                                           windowS: 25_000, version: "frwhoop-server-1"))
        let n2 = regimeAt(F.t0, timeline, method: F.method("snapshot.hrv_rmssd.night", aggregation: .session,
                                                           windowS: 29_000, version: "frwhoop-server-1"))
        XCTAssertEqual(n1.key, n2.key)
        XCTAssertEqual(E.comparability(n1, n2, config: .init()),
                       .comparable(rule: "identical_regime_session_length_varies"))
        // The decoder version is recorded, not keyed.
        var newer = device
        newer.decoderVersion = "dec-8"
        let c = regimeAt(F.t0, timeline, device: newer)
        XCTAssertEqual(c.key, a.key)
        XCTAssertEqual(E.comparability(a, c, config: .init()), .comparable(rule: "identical_regime_decoder_differs"))
    }

    func testAlgorithmVersionChangeAcrossTheDayIsAMethodBoundary() {
        let old = F.measurement(.hrvRmssd, .init(F.t0, F.t0 + 300), method: F.method("series.hrv_rmssd.5min"))
        let new = F.measurement(.hrvRmssd, .init(F.t0 + 300, F.t0 + 600),
                                method: F.method("series.hrv_rmssd.5min", version: "frwhoop-series-3"))
        let timeline = E.regimeTimeline(F.input(measurements: [new, old]), config: .init())
        XCTAssertEqual(timeline.boundaries, [
            .init(at: F.t0 + 300, kind: "method", fromValue: "series.hrv_rmssd.5min@frwhoop-series-2",
                  toValue: "series.hrv_rmssd.5min@frwhoop-series-3", reasons: [E.methodVersionChanged]),
        ])
    }

    func testEngineDocumentRegistersBothPlacementRegimes() {
        let placements = [
            PC.PlacementInput(start: d0, end: d0 + 12 * 3600, placement: "wrist", source: "user", revision: 1),
            PC.PlacementInput(start: d0 + 12 * 3600, end: nil, placement: "bicep", source: "user", revision: 2),
        ]
        let hr = (0..<600).map { PC.HeartRateObservation(ts: d0 + 11 * 3600 + 3300 + $0, bpm: 60 + $0 % 5) }
        let doc = PC.Engine.buildDay(F.input(heartRate: hr, placements: placements), history: .empty)
        let placementsSeen = Set(doc.regimes.registry.map(\.placement))
        XCTAssertEqual(placementsSeen, ["wrist", "bicep"])
        let keys = Set(doc.envelopes.map(\.regimeKey))
        XCTAssertEqual(keys.count, 2)
    }

    // MARK: Availability matrix

    func row(_ rows: [PC.AvailabilityEntry], _ assessment: String, _ source: String? = nil) -> PC.AvailabilityEntry? {
        rows.first { $0.assessment == assessment && (source == nil || $0.source == source) }
    }

    func testAvailabilityMatrixStatesUnsupportedAndUnverifiedRowsExplicitly() {
        let t = F.t0
        let motion = (0..<120).map { PC.MotionObservation(ts: t + $0, dynAccelG: nil, x: 0, y: 0, z: 1) }
        let input = F.input(heartRate: (0..<120).map { .init(ts: t + $0, bpm: 60) },
                            motion: motion,
                            skin: (0..<120).map { .init(ts: t + $0, celsius: 33) })
        let (o, _) = F.sanitize(input)
        let rows = E.availabilityMatrix(input, observations: o, config: .init())
        XCTAssertEqual(row(rows, "ppg_waveform_quality")?.state, .unsupported)
        XCTAssertEqual(row(rows, "ppg_waveform_quality")?.reasons, [E.noQualifiedWaveform])
        XCTAssertEqual(row(rows, "core_temperature")?.state, .unsupported)
        XCTAssertEqual(row(rows, "spo2_signal_validity")?.state, .unverified)
        XCTAssertEqual(row(rows, "spo2_signal_validity")?.comparability, "excluded_from_comparisons")
        let skin = row(rows, "skin_temperature_signal_validity")
        XCTAssertEqual(skin?.state, .supported)
        XCTAssertEqual(skin?.comparability, "relative_within_regime_only")
        XCTAssertEqual(skin?.reasons, [E.skinNotCoreTemperature])
        XCTAssertEqual(row(rows, "posture")?.state, .unverified)
        XCTAssertEqual(row(rows, "posture")?.reasons, [E.wristOrientationLikelihoodOnly])
        XCTAssertEqual(row(rows, "hrv_signal_validity")?.state, .unavailable)
        XCTAssertEqual(row(rows, "heart_rate_signal_validity")?.state, .supported)
        let strap = row(rows, "activity_composition", "strap_motion")
        XCTAssertEqual(strap?.state, .supported)
        XCTAssertTrue(strap?.reasons.contains(PC.MotionEvidence.basisGravityDelta) ?? false,
                      "the gravity-delta fallback basis is visible")
        XCTAssertFalse(strap?.reasons.contains(PC.MotionEvidence.basisDynamicAcceleration) ?? true)
        let decoder = row(rows, "activity_composition", "decoder_intervals")
        XCTAssertTrue(decoder?.reasons.contains(PC.IntervalAlgebra.heartRateDependentSource) ?? false)
        XCTAssertEqual(row(rows, "stable_awake_eligibility")?.state, .unavailable,
                       "no sleep evidence: stable awake cannot be established")
        XCTAssertEqual(row(rows, "hrv_signal_validity", "strap_rr_intervals")?.metric, .hrvRmssd)
        XCTAssertTrue(rows.contains { $0.metric == .hrvSdnn && $0.comparability == "identical_window_length_only" })
    }

    func testAvailabilityMatrixInLiveModeListsOnlyMeasurementsAvailableAtTheCutoff() {
        let cutoff = F.t0 + 600
        var early = F.measurement(.hrvRmssd, .init(F.t0, F.t0 + 300))
        early.availableAt = F.t0 + 400
        var late = F.measurement(.respiratoryRate, .init(F.t0 + 600, F.t0 + 720))
        late.availableAt = F.t0 + 800
        let input = F.input(measurements: [early, late], mode: .causalLive, cutoff: cutoff)
        let (o, _) = F.sanitize(input)
        let products = E.availabilityMatrix(input, observations: o, config: .init())
            .filter { $0.assessment == "measurement_product" }
        XCTAssertEqual(products.map(\.metric), [.hrvRmssd])
    }
}
