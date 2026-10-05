import XCTest
@testable import StrandAnalytics

/// V05 and the input contract: observation identity, contract rejections, timing diagnostics and breaks.
/// Expected values are derived by hand from the fixture rows, not read back from the implementation.
final class PCSignalSanitizeTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias E = PhysiologyContext.SignalValidityEngine

    // MARK: Identity

    func testExactHeartRateDuplicatesCollapseAndConflictsAreRejectedNeverAveraged() {
        let t = F.t0
        let rows: [PC.HeartRateObservation] = [
            .init(ts: t, bpm: 60, availableAt: t + 10),
            .init(ts: t, bpm: 60, availableAt: t + 5),      // exact duplicate (earlier availability)
            .init(ts: t + 1, bpm: 70, availableAt: t + 10),
            .init(ts: t + 1, bpm: 80, availableAt: t + 10), // conflicting value at the same second
            .init(ts: t + 2, bpm: 65, availableAt: t + 10),
        ]
        let (o, r) = F.sanitize(F.input(heartRate: rows))
        XCTAssertEqual(o.heartRate, [.init(ts: t, bpm: 60, availableAt: t + 5), .init(ts: t + 2, bpm: 65, availableAt: t + 10)])
        XCTAssertFalse(o.heartRate.contains { $0.bpm == 75 }, "conflicting values must never be averaged")
        XCTAssertEqual(r.count("heart_rate.input"), 5)
        XCTAssertEqual(r.count("heart_rate.kept"), 2)
        XCTAssertEqual(r.count("heart_rate.exact_duplicates_collapsed"), 1)
        XCTAssertEqual(r.count("heart_rate.conflicting_duplicates_rejected"), 2)
        XCTAssertEqual(r.count("heart_rate.conflicting_identities"), 1)
        XCTAssertTrue(r.reasons.contains(E.exactDuplicatesCollapsed))
        XCTAssertTrue(r.reasons.contains(E.conflictingDuplicatesRejected))
        XCTAssertEqual(r.availabilityBasis, "ingested_at")
    }

    func testEqualBeatIntervalsInOneSecondAreDistinctBeatsAndOnlyIdentityDuplicatesCollapse() {
        let t = F.t0
        let rows: [PC.BeatIntervalObservation] = [
            .init(ts: t, rrMs: 500, seq: 0, availableAt: t),
            .init(ts: t, rrMs: 500, seq: 1, availableAt: t),
            .init(ts: t, rrMs: 500, seq: 1, availableAt: t + 3), // same (ts, rrMs, seq): a transport duplicate
            .init(ts: t + 1, rrMs: 500, seq: 0, availableAt: t + 1),
        ]
        let (o, r) = F.sanitize(F.input(beats: rows))
        XCTAssertEqual(o.beatIntervals.count, 3)
        XCTAssertEqual(o.beatIntervals.map(\.seq), [0, 1, 0])
        XCTAssertEqual(o.beatIntervals[1].availableAt, t, "the collapsed copy keeps the earliest availability")
        XCTAssertEqual(r.count("beat_intervals.exact_duplicates_collapsed"), 1)
        XCTAssertEqual(r.count("beat_intervals.conflicting_duplicates_rejected"), 0)
    }

    // MARK: Ordering (contracts.md §2: streams are sorted by ts, then identity)

    func testEveryStreamIsSortedBySensorTimeWhateverTheInputOrder() {
        let t = F.t0
        var state: UInt64 = 42
        func shuffled<T>(_ a: [T]) -> [T] {
            var out = a
            for i in stride(from: out.count - 1, to: 0, by: -1) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                out.swapAt(i, Int(state >> 33) % (i + 1))
            }
            return out
        }
        let n = 200
        let input = F.input(
            heartRate: shuffled((0..<n).map { .init(ts: t + $0, bpm: 60 + $0 % 9, availableAt: t + n) }),
            beats: shuffled((0..<n).flatMap { i -> [PC.BeatIntervalObservation] in
                // Two beats per second; the transport order puts the LONGER interval first.
                [.init(ts: t + i, rrMs: 520, seq: 0, ord: 0, availableAt: t + n),
                 .init(ts: t + i, rrMs: 480, seq: 0, ord: 1, availableAt: t + n)]
            }),
            motion: shuffled((0..<n).map { .init(ts: t + $0, dynAccelG: 0.003, availableAt: t + n) }),
            steps: shuffled((0..<n).map { .init(ts: t + $0, counter: $0, activityClass: 0, availableAt: t + n) }),
            skin: shuffled((0..<n).map { .init(ts: t + $0, celsius: 33, availableAt: t + n) }))
        let (o, _) = F.sanitize(input)
        func sorted(_ ts: [Int]) -> Bool { zip(ts, ts.dropFirst()).allSatisfy { $0 < $1 } }
        XCTAssertTrue(sorted(o.heartRate.map(\.ts)))
        XCTAssertTrue(sorted(o.motion.map(\.ts)))
        XCTAssertTrue(sorted(o.steps.map(\.ts)))
        XCTAssertTrue(sorted(o.skinTemperature.map(\.ts)))
        XCTAssertEqual(o.beatIntervals.count, 2 * n)
        XCTAssertTrue(zip(o.beatIntervals, o.beatIntervals.dropFirst()).allSatisfy { $0.ts <= $1.ts })
        // Within a second the known transport order is kept (520 then 480), not re-sorted by value.
        XCTAssertEqual(o.beatIntervals.prefix(4).map(\.rrMs), [520, 480, 520, 480])
        // Same rows in another order: identical output.
        XCTAssertEqual(F.sanitize(F.input(heartRate: input.heartRate.reversed(), beats: input.beatIntervals.reversed(),
                                          motion: input.motion.reversed(), steps: input.steps.reversed(),
                                          skin: input.skinTemperature.reversed())).0, o)
    }

    func testBeatsWithoutTransportOrderFallBackToIdentityOrder() {
        let t = F.t0
        let beats: [PC.BeatIntervalObservation] = [.init(ts: t + 1, rrMs: 700, seq: 0), .init(ts: t, rrMs: 900, seq: 1),
                                                   .init(ts: t, rrMs: 900, seq: 0), .init(ts: t, rrMs: 400, seq: 0)]
        let (o, _) = F.sanitize(F.input(beats: beats))
        XCTAssertEqual(o.beatIntervals.map { [$0.ts - t, $0.rrMs, $0.seq] }, [[0, 400, 0], [0, 900, 0], [0, 900, 1], [1, 700, 0]])
    }

    // MARK: Contract

    func testUnitAndRangeContractFailuresAreCountedPerStream() {
        let t = F.t0
        let hr: [PC.HeartRateObservation] = [.init(ts: t, bpm: 19), .init(ts: t + 1, bpm: 251),
                                             .init(ts: t + 2, bpm: 20), .init(ts: t + 3, bpm: 250)]
        let rr: [PC.BeatIntervalObservation] = [.init(ts: t, rrMs: 49), .init(ts: t + 1, rrMs: 30_001),
                                                .init(ts: t + 2, rrMs: 50)]
        let motion: [PC.MotionObservation] = [
            .init(ts: t, dynAccelG: -0.1),                                   // no valid value left → rejected
            .init(ts: t + 1, dynAccelG: .nan, x: 0, y: 0, z: 1),             // dyn nulled, vector kept
            .init(ts: t + 2, dynAccelG: 0.02, x: 1000, y: 0, z: 0),          // vector in mg nulled, dyn kept
            .init(ts: t + 3, dynAccelG: 9.0),                                // beyond the decoder's 8 g gate
        ]
        let skin: [PC.SkinTemperatureObservation] = [.init(ts: t, celsius: 61), .init(ts: t + 1, celsius: -1),
                                                     .init(ts: t + 2, celsius: nil), .init(ts: t + 3, celsius: 33)]
        let steps: [PC.StepObservation] = [.init(ts: t, counter: 70_000), .init(ts: t + 1, counter: 10)]
        let (o, r) = F.sanitize(F.input(heartRate: hr, beats: rr, motion: motion, steps: steps, skin: skin))
        XCTAssertEqual(o.heartRate.map(\.bpm), [20, 250])
        XCTAssertEqual(r.count("heart_rate.contract_rejected"), 2)
        XCTAssertEqual(o.beatIntervals.map(\.rrMs), [50])
        XCTAssertEqual(r.count("beat_intervals.contract_rejected"), 2)
        XCTAssertEqual(o.motion.map(\.ts), [t + 1, t + 2])
        XCTAssertNil(o.motion[0].dynAccelG)
        XCTAssertEqual(o.motion[0].z, 1)
        XCTAssertEqual(o.motion[1].dynAccelG, 0.02)
        XCTAssertNil(o.motion[1].x)
        XCTAssertEqual(r.count("motion.contract_rejected"), 2)
        XCTAssertEqual(r.count("motion.dyn_accel_contract_rejected"), 3)
        XCTAssertEqual(r.count("motion.vector_contract_rejected"), 1)
        XCTAssertEqual(o.skinTemperature.map(\.celsius), [33])
        XCTAssertEqual(r.count("skin_temperature.contract_rejected"), 3)
        XCTAssertEqual(o.steps.map(\.counter), [10])
        XCTAssertEqual(r.count("steps.contract_rejected"), 1)
        XCTAssertTrue(r.reasons.contains(E.outOfContractUnits))
        XCTAssertEqual(r.availabilityBasis, "sensor_time")
        XCTAssertTrue(r.reasons.contains(E.availabilityBasisSensorTime))
    }

    func testTimestampsOutsideTheReadWindowOrAfterGenerationAreRejected() {
        let window = E.readWindow(F.identity)
        let generated = F.identity.dayWindow.end + 2 * 3600
        let hr: [PC.HeartRateObservation] = [
            .init(ts: window.start - 1, bpm: 60, availableAt: window.start),
            .init(ts: window.start, bpm: 60, availableAt: window.start),
            .init(ts: generated + 3600, bpm: 60, availableAt: generated + 3600), // inside the window, after generation
            .init(ts: window.end, bpm: 60, availableAt: window.end),
        ]
        let (o, r) = F.sanitize(F.input(heartRate: hr))
        XCTAssertEqual(o.heartRate.map(\.ts), [window.start])
        XCTAssertEqual(r.count("heart_rate.outside_read_window"), 2)
        XCTAssertEqual(r.count("heart_rate.future_timestamp_rejected"), 1)
        XCTAssertTrue(r.reasons.contains(E.outsideReadWindow))
        XCTAssertTrue(r.reasons.contains(E.futureTimestamp))
    }

    // MARK: Timing

    func testDisconnectionGapProducesABreakOverTheUnobservedStretch() {
        let t = F.t0
        let hr = (0..<100).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: t + 400) }
            + (200..<300).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: t + 400) }
        let (o, r) = F.sanitize(F.input(heartRate: hr))
        XCTAssertEqual(o.breaks, [PC.Interval(t + 100, t + 200)])
        XCTAssertEqual(r.count("breaks.disconnection"), 1)
        XCTAssertTrue(r.reasons.contains(E.disconnection))
        XCTAssertTrue(o.breakSeparates(t + 99, t + 200))
        XCTAssertFalse(o.breakSeparates(t + 98, t + 99))
        XCTAssertFalse(o.breakSeparates(t + 200, t + 201))
    }

    func testAShortHoleIsNotADisconnection() {
        let t = F.t0
        let hr = (0..<100).map { PC.HeartRateObservation(ts: t + $0, bpm: 60) }
            + (159..<200).map { PC.HeartRateObservation(ts: t + $0, bpm: 60) }   // a 60 s step between rows
        let (o, _) = F.sanitize(F.input(heartRate: hr))
        XCTAssertEqual(o.breaks, [], "a 60 s step is at the threshold, not beyond it")
    }

    func testClockResetInsideOneDeliveryIsDetectedAndItsOverlappedSpanIsABreak() {
        let t = F.t0
        let batch = t + 900
        // One delivery: 600 s at 60 bpm, then the strap clock jumps back 400 s and writes 200 s at 70 bpm.
        let first = (0..<600).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: batch) }
        let second = (200..<400).map { PC.HeartRateObservation(ts: t + $0, bpm: 70, availableAt: batch) }
        let (o, r) = F.sanitize(F.input(heartRate: first + second))
        XCTAssertEqual(r.count("heart_rate.clock_resets"), 1)
        XCTAssertEqual(r.count("heart_rate.non_monotonic_steps"), 1)
        XCTAssertTrue(r.reasons.contains(E.clockResetDetected))
        // Seconds written by both clocks disagree: all rejected, none averaged.
        XCTAssertEqual(r.count("heart_rate.conflicting_identities"), 200)
        XCTAssertEqual(r.count("heart_rate.conflicting_duplicates_rejected"), 400)
        XCTAssertTrue(r.reasons.contains(E.overlappingTimelinesSuspected))
        XCTAssertEqual(o.heartRate.count, 400)
        XCTAssertTrue(o.heartRate.allSatisfy { $0.bpm == 60 })
        // Reset span [t+200, t+600) — the clock-reset break absorbs the conflict and disconnection breaks.
        XCTAssertEqual(o.breaks, [PC.Interval(t + 200, t + 600)])
        XCTAssertFalse(o.heartRate.contains { $0.ts >= t + 200 && $0.ts < t + 400 })
    }

    func testABackfillDeliveredLaterIsNotAClockReset() {
        let t = F.t0
        let live = (600..<700).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: t + 700) }
        let backfill = (0..<100).map { PC.HeartRateObservation(ts: t + $0, bpm: 62, availableAt: t + 4000) }
        let (o, r) = F.sanitize(F.input(heartRate: live + backfill))
        XCTAssertEqual(r.count("heart_rate.non_monotonic_steps"), 1)
        XCTAssertEqual(r.count("heart_rate.clock_resets"), 0)
        XCTAssertFalse(r.reasons.contains(E.clockResetDetected))
        XCTAssertEqual(o.heartRate.count, 200)
        XCTAssertEqual(o.heartRate.first?.ts, t, "output is sorted by sensor time")
        XCTAssertEqual(o.breaks, [PC.Interval(t + 100, t + 600)], "the hole between them is a disconnection")
    }

    func testAnIsolatedTimestampSpikeIsRejected() {
        let t = F.t0
        let hr: [PC.HeartRateObservation] = [.init(ts: t, bpm: 60), .init(ts: t + 1, bpm: 60),
                                             .init(ts: t + 5000, bpm: 61), .init(ts: t + 2, bpm: 60),
                                             .init(ts: t + 3, bpm: 60)]
        let (o, r) = F.sanitize(F.input(heartRate: hr))
        XCTAssertEqual(o.heartRate.map(\.ts), [t, t + 1, t + 2, t + 3])
        XCTAssertEqual(r.count("heart_rate.timestamp_spike_rejected"), 1)
        XCTAssertEqual(r.count("heart_rate.clock_resets"), 0)
        XCTAssertTrue(r.reasons.contains(E.timestampSpike))
    }

    func testSourceChannelChangeIsABreakEvenInsideContinuousBeats() {
        let t = F.t0
        let beats = F.beatsPerSecond(from: t, count: 20, channel: 5) + F.beatsPerSecond(from: t + 20, count: 20, channel: 6)
        let (o, r) = F.sanitize(F.input(beats: beats))
        XCTAssertEqual(r.count("breaks.source_change"), 1)
        XCTAssertTrue(r.reasons.contains(E.sourceChange))
        XCTAssertEqual(o.breaks, [PC.Interval(t + 20, t + 21)])
        XCTAssertTrue(o.breakSeparates(t + 19, t + 20))
    }

    func testDeviceClockAheadOfAvailabilityIsFlaggedButKept() {
        let t = F.t0
        let hr: [PC.HeartRateObservation] = [.init(ts: t, bpm: 60, availableAt: t - 600)]
        let (o, r) = F.sanitize(F.input(heartRate: hr))
        XCTAssertEqual(o.heartRate.count, 1)
        XCTAssertEqual(r.count("heart_rate.sensor_time_after_availability"), 1)
        XCTAssertTrue(r.reasons.contains(E.deviceClockAhead))
    }

    // MARK: Causal

    func testLiveReportNeverCountsDataBeyondTheCutoff() {
        let t = F.t0
        let cutoff = t + 300
        let early = (0..<300).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: t + $0 + 5) }
        let late = (300..<600).map { PC.HeartRateObservation(ts: t + $0, bpm: 60, availableAt: t + $0 + 5) }
        let delayed = (0..<50).map { PC.HeartRateObservation(ts: t + $0, bpm: 90, availableAt: cutoff + 100) }
        let a = PC.Engine.buildDay(F.input(heartRate: early, mode: .causalLive, cutoff: cutoff), history: .empty)
        let b = PC.Engine.buildDay(F.input(heartRate: early + late + delayed, mode: .causalLive, cutoff: cutoff),
                                   history: .empty)
        XCTAssertEqual(a.inputReport, b.inputReport)
        // `early` rows with availableAt > cutoff (i > 295) are excluded by the engine before sanitize.
        XCTAssertEqual(b.inputReport.count("heart_rate.input"), 296)
        XCTAssertEqual(b.inputReport.count("heart_rate.conflicting_identities"), 0,
                       "a delayed conflicting copy must not even be visible as a conflict")
    }
}
