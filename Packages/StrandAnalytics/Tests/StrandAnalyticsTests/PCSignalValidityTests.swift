import XCTest
@testable import StrandAnalytics

/// Per-metric validity (spec §7): separate decisions per metric, signal quality never judged from the value (V03),
/// valid beat adjacency with repeated equal RR values and no pairs across gaps (V05).
final class PCSignalValidityTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias E = PhysiologyContext.SignalValidityEngine

    var support: PC.Interval { PC.Interval(F.t0, F.t0 + 300) }
    var stillTrack: PC.ResolvedTrack { F.track([(F.t0 - 1800, F.t0 + 3600, "still")]) }

    func assess(_ metric: PC.MetricKind, hr: [PC.HeartRateObservation] = [], beats: [PC.BeatIntervalObservation] = [],
                skin: [PC.SkinTemperatureObservation] = [], track: PC.ResolvedTrack? = nil,
                support s: PC.Interval? = nil, method: PC.MethodRef? = nil) -> PC.SignalValidity {
        let (o, _) = F.sanitize(F.input(heartRate: hr, beats: beats, skin: skin))
        return E.assess(F.measurement(metric, s ?? support, method: method), observations: o,
                        motion: track ?? stillTrack, config: .init())
    }

    func hr(_ count: Int, from start: Int? = nil, bpm: (Int) -> Int) -> [PC.HeartRateObservation] {
        (0..<count).map { PC.HeartRateObservation(ts: (start ?? F.t0) + $0, bpm: bpm($0)) }
    }

    // MARK: Heart rate

    func testHeartRateFullCoverageIsValidAndElevatedValuesAreNotArtifacts() {
        let normal = assess(.heartRate, hr: hr(300) { 60 + $0 % 5 })
        XCTAssertEqual(normal.state, .valid)
        XCTAssertEqual(normal.coverage, 1)
        XCTAssertEqual(normal.observedS, 300)
        XCTAssertEqual(normal.confidence, .notApplicable)
        // V03: a resting 150 bpm is a measurement, not a signal failure.
        let elevated = assess(.heartRate, hr: hr(300) { 150 + $0 % 3 })
        XCTAssertEqual(elevated.state, .valid)
        XCTAssertEqual(elevated.reasons, [])
    }

    func testHeartRateCoverageGates() {
        let partial = assess(.heartRate, hr: hr(100) { 60 + $0 % 5 })   // 100/300 = 0.33
        XCTAssertEqual(partial.state, .degraded)
        XCTAssertTrue(partial.reasons.contains(E.partialCoverage))
        let sparse = assess(.heartRate, hr: hr(20) { 60 + $0 % 5 })     // 20/300 = 0.067 < 0.10
        XCTAssertEqual(sparse.state, .invalid)
        XCTAssertTrue(sparse.reasons.contains(E.insufficientCoverage))
        let none = assess(.heartRate)
        XCTAssertEqual(none.state, .missing)
        XCTAssertEqual(none.reasons, [E.noHeartRateSamples])
    }

    func testHeartRateFlatlineIsASignalFailureNotAValueJudgement() {
        // An hour-long support holding one value for 3600 s (≥ 900 s and ≥ 0.8 × 3600): a stuck signal.
        let hour = PC.Interval(F.t0 - 3300, F.t0 + 300)
        let stuck = assess(.restingHeartRate, hr: hr(3600, from: F.t0 - 3300) { _ in 72 }, support: hour)
        XCTAssertEqual(stuck.state, .invalid)
        XCTAssertTrue(stuck.reasons.contains(E.flatline))
        XCTAssertEqual(stuck.diagnostic("longest_flatline_s"), 3600)
        // Five constant minutes in a 5-minute window: degraded (deep sleep can hold an integer bpm), not invalid.
        let window = assess(.heartRate, hr: hr(300) { _ in 52 })
        XCTAssertEqual(window.state, .degraded)
        XCTAssertTrue(window.reasons.contains(E.flatlineRun))
        // Two constant minutes: below the bar.
        XCTAssertEqual(assess(.heartRate, hr: hr(300) { $0 < 120 ? 72 : 60 + $0 % 5 }).state, .valid)
    }

    func testMovementNeverInvalidatesHeartRate() {
        let walking = F.track([(F.t0 - 600, F.t0 + 600, "walking")])
        let v = assess(.heartRate, hr: hr(300) { 110 + $0 % 7 }, track: walking)
        XCTAssertEqual(v.state, .valid)
        XCTAssertEqual(v.diagnostic("movement_share"), 1)
    }

    func testRestingHeartRateUsesCoverageOverItsWholeTrailingSupport() {
        // Trailing 60-minute support with samples only in its last 5 minutes: 300 / 3600 = 0.083 < 0.10.
        let trailing = PC.Interval(F.t0 - 3300, F.t0 + 300)
        let v = assess(.restingHeartRate, hr: hr(300) { 55 + $0 % 4 }, support: trailing,
                       method: F.method("series.resting_heart_rate.trailing_60min", aggregation: .minimumOfBins,
                                        windowS: 3600, units: "bpm"))
        XCTAssertEqual(v.state, .invalid)
        XCTAssertTrue(v.reasons.contains(E.insufficientCoverage))
        XCTAssertEqual(v.observedS, 300)
    }

    // MARK: HRV

    func testLowHrvAtRestIsValid() {
        // V03: RMSSD ≈ 10 ms. 300 beats, alternation ±5 ms, all within the ectopic band.
        let beats = F.beatsPerSecond(from: F.t0, count: 300) { $0 % 2 == 0 ? 1005 : 995 }
        let v = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(v.state, .valid, "\(v.reasons)")
        XCTAssertEqual(v.diagnostic("clean_beats"), 300)
        XCTAssertEqual(v.diagnostic("valid_pairs"), 299)
        XCTAssertEqual(v.diagnostic("rejected_fraction"), 0)
        XCTAssertEqual(v.coverage, 1)
    }

    func testRepeatedEqualIntervalsInOneSecondAreDistinctBeatsWithValidAdjacency() {
        // 120 bpm: two 500 ms beats per whole second, stored as (ts, 500, seq 0) and (ts, 500, seq 1).
        var beats: [PC.BeatIntervalObservation] = []
        for s in 0..<300 {
            beats.append(.init(ts: F.t0 + s, rrMs: 500, seq: 0))
            beats.append(.init(ts: F.t0 + s, rrMs: 500, seq: 1))
        }
        let v = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(v.state, .valid, "\(v.reasons)")
        XCTAssertEqual(v.diagnostic("beats"), 600)
        XCTAssertEqual(v.diagnostic("clean_beats"), 600)
        XCTAssertEqual(v.diagnostic("valid_pairs"), 599)
        XCTAssertEqual(v.diagnostic("runs"), 1)
        XCTAssertEqual(v.diagnostic("equal_value_same_second_beats"), 300)
        XCTAssertTrue(v.reasons.contains(E.equalValueBeatsKept))
        XCTAssertEqual(v.observedS, 300)
    }

    func testAGapSplitsRunsAndNoPairIsFabricatedAcrossIt() {
        // 100 beats, 100 s with nothing (a disconnection), 100 beats: 99 + 99 pairs, never 199.
        let beats = F.beatsPerSecond(from: F.t0, count: 100) + F.beatsPerSecond(from: F.t0 + 200, count: 100)
        let v = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(v.diagnostic("valid_pairs"), 198)
        XCTAssertEqual(v.diagnostic("runs"), 2)
        XCTAssertEqual(v.diagnostic("clean_beats"), 200)
        XCTAssertEqual(v.diagnostic("breaks_in_support"), 1)
        XCTAssertTrue(v.reasons.contains(E.containsBreak))
        XCTAssertTrue(v.reasons.contains(E.rrUnderCovered))   // 200 s of beats over a 299 s span
        XCTAssertEqual(v.state, .valid)                       // 0.667 coverage ≥ 0.5, 198 pairs ≥ 30
    }

    func testASourceChannelChangeSplitsAdjacency() {
        let beats = F.beatsPerSecond(from: F.t0, count: 150, channel: 5) + F.beatsPerSecond(from: F.t0 + 150, count: 150, channel: 6)
        let v = assess(.hrvRmssd, beats: beats)
        // The change sits between adjacent whole seconds, so its break is the second [t+150, t+151): the pair
        // across the change is never formed, and on a whole-second axis the pair (t+150, t+151) touching that
        // second is given up too (149 + 0 + 148 pairs). Losing a pair is the safe direction; inventing one is not.
        XCTAssertEqual(v.diagnostic("valid_pairs"), 297)
        XCTAssertEqual(v.diagnostic("runs"), 3)
    }

    func testSameSecondOverCountIsInvalid() {
        // Every second holds the beat twice (1000 and 1010 ms): coverage ≈ 2, same-second collapse fixes it.
        var beats: [PC.BeatIntervalObservation] = []
        for s in 0..<300 {
            beats.append(.init(ts: F.t0 + s, rrMs: 1000))
            beats.append(.init(ts: F.t0 + s, rrMs: 1010))
        }
        let v = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(v.state, .invalid)
        XCTAssertTrue(v.reasons.contains(E.rrOverCountSameSecond))
    }

    func testCrossSecondOverCountIsInvalid() {
        // A second copy of every beat lands one second later with a 100 ms offset (no same-second collapse).
        var beats: [PC.BeatIntervalObservation] = []
        for s in 0..<300 {
            beats.append(.init(ts: F.t0 + s, rrMs: 1000))
            if s + 1 < 300 { beats.append(.init(ts: F.t0 + s + 1, rrMs: 1100)) }
        }
        let v = assess(.hrvSdnn, beats: beats)
        XCTAssertEqual(v.state, .invalid)
        XCTAssertTrue(v.reasons.contains(E.rrOverCountCrossSecond))
    }

    func testExcessRejectedBeatsInvalidateAndAreCountedByCause() {
        // Indices 0,1 of every 5 are 250 ms (outside the 300–2000 ms kernel band): 120 of 300 rejected (0.40).
        let beats = F.beatsPerSecond(from: F.t0, count: 300) { $0 % 5 < 2 ? 250 : 1000 }
        let v = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(v.state, .invalid)
        XCTAssertTrue(v.reasons.contains(E.excessRejectedBeats))
        XCTAssertTrue(v.reasons.contains(E.beatsOutsideKernelRange))
        XCTAssertEqual(v.diagnostic("out_of_range_beats"), 120)
        XCTAssertEqual(v.diagnostic("clean_beats"), 180)
        XCTAssertEqual(v.diagnostic("valid_pairs"), 120)   // two adjacent survivors per block of five
        XCTAssertEqual(v.diagnostic("rejected_fraction")!, 0.4, accuracy: 1e-12)
    }

    func testBankedBeatValuesInvalidateSdnnButOnlyDegradeRmssd() {
        // 50 records of six equal 1000 ms intervals stamped on one coarse timestamp every 6 s.
        var beats: [PC.BeatIntervalObservation] = []
        for r in 0..<50 { for k in 0..<6 { beats.append(.init(ts: F.t0 + 6 * r, rrMs: 1000, seq: k)) } }
        let sdnn = assess(.hrvSdnn, beats: beats, method: F.method("series.hrv_sdnn.5min"))
        XCTAssertEqual(sdnn.state, .invalid)
        XCTAssertTrue(sdnn.reasons.contains(E.beatValuesUntrustworthy))
        XCTAssertTrue(sdnn.reasons.contains(E.windowLengthDependent))
        XCTAssertEqual(sdnn.diagnostic("window_s"), 300)
        let rmssd = assess(.hrvRmssd, beats: beats)
        XCTAssertEqual(rmssd.state, .degraded)
        XCTAssertTrue(rmssd.reasons.contains(E.beatValuesUntrustworthy))
    }

    func testMotionContaminatesOpticalBeatTiming() {
        let beats = F.beatsPerSecond(from: F.t0, count: 300) { $0 % 2 == 0 ? 1005 : 995 }
        let walking = F.track([(F.t0 - 600, F.t0 + 600, "walking")])
        let moving = assess(.hrvRmssd, beats: beats, track: walking)
        XCTAssertEqual(moving.state, .invalid)
        XCTAssertTrue(moving.reasons.contains(E.motionContaminated))
        // 60 of 300 labelled seconds moving: 0.20 → degraded, not invalid.
        let some = F.track([(F.t0, F.t0 + 240, "still"), (F.t0 + 240, F.t0 + 300, "other_movement")])
        let partly = assess(.hrvRmssd, beats: beats, track: some)
        XCTAssertEqual(partly.state, .degraded)
        XCTAssertTrue(partly.reasons.contains(E.motionPresent))
        XCTAssertEqual(partly.diagnostic("movement_share")!, 0.2, accuracy: 1e-12)
        // No motion evidence: recorded, but the signal state is not invented either way.
        let unobserved = assess(.hrvRmssd, beats: beats, track: .empty(.strapMotion))
        XCTAssertEqual(unobserved.state, .valid)
        XCTAssertTrue(unobserved.reasons.contains(E.motionUnobserved))
    }

    func testNightlySupportIsJudgedPerFiveMinuteWindow() {
        let night = PC.Interval(F.t0, F.t0 + 3600)   // 12 windows
        let snapshot = F.method("snapshot.hrv_rmssd.night", aggregation: .session, windowS: 3600,
                                version: "frwhoop-server-1")
        // Beats in the first 20 minutes only: 4 of 12 windows qualify → degraded.
        let partial = assess(.hrvRmssd, beats: F.beatsPerSecond(from: F.t0, count: 1200) { $0 % 2 == 0 ? 1010 : 990 },
                             support: night, method: snapshot)
        XCTAssertEqual(partial.state, .degraded, "\(partial.reasons)")
        XCTAssertEqual(partial.diagnostic("windows"), 12)
        XCTAssertEqual(partial.diagnostic("qualified_windows"), 4)
        XCTAssertTrue(partial.reasons.contains(E.partialWindowCoverage))
        // Ten beats per window never reaches the 20-beat window gate → invalid.
        var sparse: [PC.BeatIntervalObservation] = []
        for w in 0..<12 { sparse += F.beatsPerSecond(from: F.t0 + 300 * w, count: 10) }
        let none = assess(.hrvRmssd, beats: sparse, support: night, method: snapshot)
        XCTAssertEqual(none.state, .invalid)
        XCTAssertTrue(none.reasons.contains(E.insufficientCleanBeats))
    }

    // MARK: Respiration

    /// Beats whose intervals carry a 5 s (12 breaths/min) sinusoidal RSA modulation, placed on whole seconds.
    func rsaBeats(seconds: Int) -> [PC.BeatIntervalObservation] {
        var out: [PC.BeatIntervalObservation] = []
        var t = 0.0
        var seqInSecond: [Int: Int] = [:]
        while t < Double(seconds) {
            let rr = Int((1000 + 80 * sin(2 * Double.pi * t / 5.0)).rounded())
            t += Double(rr) / 1000
            let ts = F.t0 - 60 + Int(t)
            let seq = seqInSecond[ts, default: 0]
            seqInSecond[ts] = seq + 1
            out.append(.init(ts: ts, rrMs: rr, seq: seq))
        }
        return out
    }

    func testRespiratoryRateIsValidAtRestAndInvalidWhenMoving() {
        let window = PC.Interval(F.t0 - 60, F.t0 + 60)     // trailing 2-minute support
        let beats = rsaBeats(seconds: 120)
        let rest = assess(.respiratoryRate, beats: beats, support: window,
                          method: F.method("series.respiratory_rate.2min", windowS: 120, units: "breaths_per_min"))
        XCTAssertEqual(rest.state, .valid, "\(rest.reasons) \(rest.diagnostics)")
        XCTAssertTrue(rest.reasons.contains(E.rsaOnlyEstimate), "RSA-only is always stated as a limit")
        XCTAssertGreaterThanOrEqual(rest.diagnostic("breath_intervals") ?? 0, 6)
        let walking = F.track([(F.t0 - 600, F.t0 + 600, "walking")])
        let moving = assess(.respiratoryRate, beats: beats, track: walking, support: window,
                            method: F.method("series.respiratory_rate.2min", windowS: 120, units: "breaths_per_min"))
        XCTAssertEqual(moving.state, .invalid)
        XCTAssertTrue(moving.reasons.contains(E.motionContaminated))
        let none = assess(.respiratoryRate, support: window)
        XCTAssertEqual(none.state, .missing)
    }

    func testValidHeartRateDoesNotEstablishValidRespiration() {
        // Plenty of HR, too few beats for respiration: separate decisions.
        let window = PC.Interval(F.t0 - 60, F.t0 + 60)
        let (o, _) = F.sanitize(F.input(heartRate: hr(120, from: F.t0 - 60) { 60 + $0 % 5 },
                                        beats: F.beatsPerSecond(from: F.t0 - 60, count: 10)))
        let hrV = E.assess(F.measurement(.heartRate, window), observations: o, motion: stillTrack, config: .init())
        let respV = E.assess(F.measurement(.respiratoryRate, window), observations: o, motion: stillTrack, config: .init())
        XCTAssertEqual(hrV.state, .valid)
        XCTAssertEqual(respV.state, .invalid)
        XCTAssertTrue(respV.reasons.contains(E.insufficientBeats))
    }

    // MARK: Skin temperature and SpO2

    func testSkinTemperatureIsNeverCoreAndOffWristRangeIsInvalid() {
        let warm = (0..<300).map { PC.SkinTemperatureObservation(ts: F.t0 + $0, celsius: 33.2) }
        let v = assess(.skinTemperature, skin: warm)
        XCTAssertEqual(v.state, .valid)
        XCTAssertTrue(v.reasons.contains(E.skinNotCoreTemperature))
        let ambient = (0..<300).map { PC.SkinTemperatureObservation(ts: F.t0 + $0, celsius: 22.5) }
        let off = assess(.skinTemperature, skin: ambient)
        XCTAssertEqual(off.state, .invalid)
        XCTAssertTrue(off.reasons.contains(E.noInBandSamples))
        XCTAssertTrue(off.reasons.contains(E.skinNotCoreTemperature))
        // 100 in band (< 150 needed for a 300 s support) and a 1/3 in-band share.
        let mixed = assess(.skinTemperature, skin: Array(warm.prefix(100)) + Array(ambient.suffix(200)))
        XCTAssertEqual(mixed.state, .degraded)
        XCTAssertTrue(mixed.reasons.contains(E.insufficientInBandSamples))
        XCTAssertTrue(mixed.reasons.contains(E.partialInBand))
    }

    func testSpo2CandidateIsAlwaysUnverified() {
        let v = assess(.spo2Candidate, hr: hr(300) { 60 + $0 % 5 },
                       method: F.method("snapshot.spo2_candidate.night", aggregation: .session, units: "percent"))
        XCTAssertEqual(v.state, .unverified)
        XCTAssertEqual(v.reasons, [E.unverifiedStrapEstimate])
        XCTAssertNil(v.coverage)
        XCTAssertEqual(v.confidence, .notApplicable)
    }

    func testEveryDiagnosticIsFiniteAndTheDocumentEncodes() throws {
        let hrRows = hr(600) { 60 + $0 % 5 }
        let beats = F.beatsPerSecond(from: F.t0, count: 600) { $0 % 2 == 0 ? 1005 : 995 }
        let input = F.input(heartRate: hrRows, beats: beats,
                            measurements: [F.measurement(.hrvRmssd, support), F.measurement(.hrvSdnn, support)])
        let doc = PC.Engine.buildDay(input, history: .empty)
        _ = try PC.encoder().encode(doc)   // throws on NaN / infinity
        XCTAssertTrue(doc.envelopes.allSatisfy { $0.validity.state != .missing || $0.metric == .spo2Candidate })
        let hrv = doc.envelopes.first { $0.metric == .hrvRmssd }!
        XCTAssertEqual(hrv.validity.state, .valid)
    }
}
