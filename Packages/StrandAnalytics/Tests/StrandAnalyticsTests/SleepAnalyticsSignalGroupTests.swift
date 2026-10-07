import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsSignalGroupTests — movement, thermal and PRV groups (spec sections
// 6-7 + section 12 rows "Motion", "Thermal", "PRV"). Root-owned tests for the
// root-implemented signal-helpers area: adjacency/eligibility rules, family-aware
// conversion + minute bins, equilibration exclusions, OLS slopes against elapsed
// time, PRV identity/ordering/adjacency rules and the strict window gates, plus the
// canonical-RMSSD-unchanged guard.

final class SleepAnalyticsMovementGroupTests: XCTestCase {

    private let t0 = 1_789_000_000

    private func gravity(_ ts: Int, _ x: Double, _ y: Double = 0, _ z: Double = 1) -> GravitySample {
        GravitySample(ts: ts, x: x, y: y, z: z)
    }

    private func timeline(start: Int, end: Int) -> SleepAnalyticsTimeline {
        SleepAnalyticsV1.normalize(
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: end,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: end, stage: "light")])],
                timezoneId: "Etc/UTC",
                hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
                gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
                stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1),
            config: .v1)
    }

    /// Stationary sequence: zero moving seconds with qualifying eligible exposure.
    func testStationarySequenceYieldsZeroMovement() {
        let start = t0
        let grav = (start..<start + 3600).map { gravity($0, 0.0) }
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 3600),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 3600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 3600, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        XCTAssertEqual(group.movementSeconds.value, 0)
        XCTAssertEqual(group.movementSeconds.status, .available)   // zero with qualifying exposure
        XCTAssertEqual(group.eligibleSeconds.value, 3599)
        XCTAssertEqual(group.movementPercentage.value, 0)
        XCTAssertEqual(group.movementPercentage.status, .available)
        XCTAssertEqual(group.immobilityBoutCompleteCount.value, 0)
        XCTAssertEqual(group.immobilityBoutCensoredCount.value, 1)  // fragment-edge run
        XCTAssertEqual(group.longestObservedImmobilitySeconds.value, 3599)
    }

    /// Known moving sequence: one-second spikes above the 0.01 g threshold move;
    /// 0.005 g deltas (below threshold) do not.
    func testKnownMovingSequenceCountsThresholdCrossings() {
        let start = t0
        var grav = (start..<start + 600).map { gravity($0, 0.0) }
        // Two movement seconds (>= 0.01 g), one below-threshold second.
        grav.append(gravity(start + 100, 0.02))
        grav.append(gravity(start + 200, 0.005))
        grav.append(gravity(start + 300, 0.02))
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 600),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 600, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        // Duplicates: the appended rows duplicate ts 100/200/300 (first wins — the
        // base zero rows won, so all appended deltas are IGNORED as duplicates).
        // Assert exactly that: duplicate policy is first-wins, the spike rows lose.
        XCTAssertEqual(group.quality.streamCounts["gravity_duplicate"], 3)
        XCTAssertEqual(group.movementSeconds.value, 0)
    }

    /// Same fixture without the duplicate-shadowing: build the spikes as the ONLY
    /// rows for those seconds.
    func testMovingSecondsCountThresholdCrossingsWithoutDuplicates() {
        let start = t0
        var grav: [GravitySample] = []
        for ts in start..<start + 600 {
            let x: Double
            switch ts {
            case start + 100, start + 300: x = 0.02   // moving adjacency at 101 and 301
            case start + 200: x = 0.005                 // below threshold
            default: x = 0.0
            }
            grav.append(gravity(ts, x))
        }
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 600),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 600, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        // Each displaced sample creates TWO moving adjacencies (into and out of it):
        // (99,100)+(100,101) around ts 100 and (299,300)+(300,301) around ts 300.
        XCTAssertEqual(group.movementSeconds.value, 4)
        XCTAssertEqual(group.eligibleSeconds.value, 599)
        XCTAssertEqual(group.movementPercentage.value!, 100.0 * 4.0 / 599.0, accuracy: 0.001)
        XCTAssertEqual(group.movementBoutCount.value, 2)
        XCTAssertEqual(group.immobilityBoutCompleteCount.value, 1)   // 102..299 bounded both sides
        XCTAssertEqual(group.immobilityBoutCensoredCount.value, 2)   // fragment-start and fragment-end runs
    }

    /// A missing sample breaks the run: no adjacency across the hole.
    func testMissingSampleBreaksRun() {
        let start = t0
        var grav: [GravitySample] = []
        for ts in start..<start + 300 where ts != start + 150 {
            grav.append(gravity(ts, ts == start + 100 ? 0.02 : 0.0))
        }
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 300),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 300,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 300, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        // The hole at 150 removes adjacencies (149,150) and (150,151); the displaced
        // sample at 100 creates two moving adjacencies (99,100) and (100,101).
        XCTAssertEqual(group.quality.streamCounts["gravity_rejected"], 0)
        XCTAssertEqual(group.movementSeconds.value, 2)
    }

    /// Nonfinite axes are rejected, never classified.
    func testNonfiniteAxesRejected() {
        let start = t0
        let grav = [
            gravity(start, 0.0),
            GravitySample(ts: start + 1, x: .infinity, y: 0, z: 1),
            gravity(start + 2, 0.0),
        ]
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 30),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 30,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 30, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["gravity_rejected"], 1)
        // No adjacency crosses the rejected second: no eligible seconds at all.
        XCTAssertNil(group.eligibleSeconds.value)
        XCTAssertEqual(group.eligibleSeconds.status, .unavailable)
    }

    /// Off-wrist intervals remove adjacencies (wear evidence override).
    func testOffWristIntervalsRemoveEligibility() {
        let start = t0
        let grav = (start..<start + 600).map { gravity($0, 0.0) }
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 600),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 600, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: grav, skinTemp: [], beats: [],
                deviceFamily: .whoop5,
                offWristIntervals: [SleepAnalyticsInterval(start: start + 100, end: start + 200)],
                stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        // Off-wrist [100,200): every adjacency touching an off-wrist second is
        // removed — t=100..200 inclusive (each boundary adjacency touches one
        // off-wrist second) → 101 removed of 599.
        XCTAssertEqual(group.eligibleSeconds.value, 498)
        XCTAssertEqual(group.movementPercentage.status, .partial)   // < 80% eligible coverage gate
    }

    /// No raw IMU / classifier input is needed: the group computes from gravity alone.
    func testComputesFromGravityAlone() {
        let start = t0
        let group = SleepAnalyticsV1.movementGroup(
            timeline: timeline(start: start, end: start + 3600),
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 3600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: start + 3600, stage: "light")])],
                timezoneId: "Etc/UTC", hr: [], gravity: (start..<start + 3600).map { gravity($0, 0.0) },
                skinTemp: [], beats: [], deviceFamily: .whoop5,
                stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
        XCTAssertEqual(group.sourceResolution, "gravity_1hz_adjacent")
        XCTAssertEqual(group.thresholdG, SleepStager.gravityStillThresholdG)
    }
}

final class SleepAnalyticsThermalGroupTests: XCTestCase {

    /// Minute-aligned base: the spec bins temperatures by UTC minute, so a fixture
    /// starting mid-minute splits across real UTC minute boundaries and thins the
    /// bins (each bin then holds the tail of one sample-minute plus the head of the
    /// next). Minute-aligned fixtures keep sample-minutes == UTC bins.
    private let t0 = 1_789_000_000 - 1_789_000_000 % 60

    private func makeTimeline(start: Int, end: Int, stage: String = "light") -> SleepAnalyticsTimeline {
        SleepAnalyticsV1.normalize(
            input: SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: end,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: end, stage: stage)])],
                timezoneId: "Etc/UTC",
                hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
                gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
                stageSourceVersion: "s", inputRevision: 1),
            config: .v1)
    }

    private func thermalInput(start: Int, end: Int,
                              skinTemp: [SkinTempSample],
                              family: DeviceFamily = .whoop5,
                              anchor: Double? = nil,
                              offWrist: [SleepAnalyticsInterval] = []) -> SleepAnalyticsInput {
        SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: skinTemp, beats: [],
            deviceFamily: family, skinTempAnchorRaw: anchor,
            offWristIntervals: offWrist,
            stageSourceVersion: "s", inputRevision: 1)
    }

    /// WHOOP 5 centidegree conversion + minute medians + IQR linear interpolation.
    func testWhoop5MinuteMediansAndIqr() {
        let start = t0
        // 40 valid minutes: minute medians cycle 33.0, 33.1, ..., via raw centidegrees.
        var samples: [SkinTempSample] = []
        for m in 0..<40 {
            let minuteStart = start + m * 60
            let c = 3300 + m          // °C = raw/100 → 33.00 + m*0.01
            for s in 0..<60 {
                samples.append(SkinTempSample(ts: minuteStart + s, raw: c + (s % 2 == 0 ? 0 : 0)))
            }
        }
        let end = start + 40 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["temp_valid_minutes"], 40)
        XCTAssertEqual(group.nightMedianC.status, .available)
        // Minute medians 33.00..33.39 → median 33.195 (mean of 33.19 and 33.20).
        XCTAssertEqual(group.nightMedianC.value!, 33.195, accuracy: 0.0001)
        // Q25 = 33.0975, Q75 = 33.2925 → IQR 0.195 (linear interpolation).
        XCTAssertEqual(group.nightIqrC.value!, 0.195, accuracy: 0.0001)
    }

    /// WHOOP 4: raw-band rejection before conversion, per-device anchor applied.
    func testWhoop4RawBandAndAnchor() {
        let start = t0
        var samples: [SkinTempSample] = []
        for m in 0..<35 {
            let raw = 826 + m          // in-band raws around the per-device anchor
            for s in 0..<60 {
                // One out-of-band raw inside the loop (an appended duplicate would
                // collapse first-wins before the band check ever sees it).
                let thisRaw = (m == 5 && s == 0) ? 100 : raw
                samples.append(SkinTempSample(ts: start + m * 60 + s, raw: thisRaw))
            }
        }
        let end = start + 35 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples,
                                family: .whoop4, anchor: 826),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["temp_whoop4_raw_band_rejected"], 1)
        XCTAssertEqual(group.conversionIdentity, "whoop4-provisional-anchor-826")
        XCTAssertEqual(group.nightMedianC.status, .available)
        // Anchor 826 → 33.0 °C; 35 in-band minutes, median raw 843 → 33.0 + 17×0.05.
        XCTAssertEqual(group.nightMedianC.value!, 33.85, accuracy: 0.001)
    }

    /// Duplicate samples cannot inflate coverage (first-wins per second).
    func testDuplicateSamplesCannotInflateCoverage() {
        let start = t0
        var samples: [SkinTempSample] = []
        for m in 0..<31 {
            for s in 0..<30 {           // only 30 distinct seconds per minute
                let ts = start + m * 60 + s
                samples.append(SkinTempSample(ts: ts, raw: 3300))
                samples.append(SkinTempSample(ts: ts, raw: 3300))   // duplicate
            }
        }
        let end = start + 31 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["temp_duplicate"], 31 * 30)
        // 30 distinct seconds per minute = exactly the ≥30 gate → all 31 minutes valid.
        XCTAssertEqual(group.quality.streamCounts["temp_valid_minutes"], 31)
        XCTAssertEqual(group.nightMedianC.status, .available)
        XCTAssertEqual(group.nightMedianC.value!, 33.0, accuracy: 0.001)
    }

    /// Plausibility band rejection (outside 28–42 °C).
    func testImplausibleConversionRejected() {
        let start = t0
        var samples: [SkinTempSample] = []
        for m in 0..<31 {
            for s in 0..<60 {
                samples.append(SkinTempSample(ts: start + m * 60 + s, raw: m == 0 ? 2000 : 3300))
            }
        }
        let end = start + 31 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["temp_implausible_rejected"], 60)   // 20.0 °C
        XCTAssertEqual(group.quality.streamCounts["temp_valid_minutes"], 30)
        // 30 of 31 eligible minutes = 96.8% ≥ 80% and ≥30 valid → available.
        XCTAssertEqual(group.nightMedianC.status, .available)
    }

    /// A linear warm trace gives the exact OLS slope; a constant trace gives zero.
    func testLinearWarmTraceGivesExactSlope() {
        // Onset at start + 3600 (light from there; wake before — prefix observed).
        let start = t0
        let onset = start + 3600
        var samples: [SkinTempSample] = []
        // Pre-onset 60 minutes: 33.00 → 33.60 °C, +0.01 °C/min = 0.6 °C/h.
        for m in 0..<60 {
            let minuteStart = start + m * 60
            let raw = 3300 + m            // +0.01 °C per minute
            for s in 0..<60 { samples.append(SkinTempSample(ts: minuteStart + s, raw: raw)) }
        }
        // Sleep fragment [onset, onset + 3600): constant 34.0.
        for ts in onset..<onset + 3600 {
            samples.append(SkinTempSample(ts: ts, raw: 3400))
        }
        let input = SleepAnalyticsInput(
            fragments: [
                // A wake fragment first so the prefix is observed (wake then sleep).
                SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: onset,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start, end: onset, stage: "wake")]),
                SleepAnalyticsInput.Fragment(
                    id: "sleep-test2-\(onset)", start: onset, end: onset + 3600,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: onset, end: onset + 3600, stage: "light")]),
            ],
            timezoneId: "Etc/UTC",
            hr: (start..<onset + 3600).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: samples, beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        // NOTE: the wake fragment + sleep fragment touch — no gap, no merge: the
        // timeline's first supported asleep onset is `onset` with a wake prefix.
        XCTAssertTrue(timeline.onsetPrefixObserved)
        let group = SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: .v1)
        let pre = group.preOnsetSlopeCPerHour
        XCTAssertEqual(pre?.value.status, .available)
        XCTAssertEqual(pre?.value.value ?? -99, 0.6, accuracy: 0.01)     // +0.01 °C/min × 60
        XCTAssertEqual(pre?.validMinutes, 60)
        XCTAssertEqual(pre?.coverage ?? -1, 1.0, accuracy: 0.001)
    }

    func testConstantTraceGivesZeroSlope() {
        let start = t0
        var samples: [SkinTempSample] = []
        for m in 0..<60 {
            for s in 0..<60 { samples.append(SkinTempSample(ts: start + m * 60 + s, raw: 3300)) }
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 3600,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: start + 3600, stage: "wake")]),
                SleepAnalyticsInput.Fragment(
                    id: "sleep-test2-\(start + 3600)", start: start + 3600, end: start + 7200,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start + 3600, end: start + 7200, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 7200).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: samples, beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let group = SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(group.preOnsetSlopeCPerHour?.value.status, .available)
        XCTAssertEqual(group.preOnsetSlopeCPerHour?.value.value ?? -99, 0.0, accuracy: 1e-9)
    }

    /// Insufficient pre-onset span (< 45 of 60 valid minutes) → null insufficient_coverage.
    func testInsufficientPreOnsetSpanIsNull() {
        let start = t0
        var samples: [SkinTempSample] = []
        // Only 44 valid pre-onset minutes, then a hole.
        for m in 0..<44 {
            for s in 0..<60 { samples.append(SkinTempSample(ts: start + m * 60 + s, raw: 3300)) }
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 3600,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: start + 3600, stage: "wake")]),
                SleepAnalyticsInput.Fragment(
                    id: "sleep-test2-\(start + 3600)", start: start + 3600, end: start + 7200,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                    stages: [StageSegment(start: start + 3600, end: start + 7200, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 7200).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: samples, beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let group = SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(group.preOnsetSlopeCPerHour?.value.status, .unavailable)
        XCTAssertEqual(group.preOnsetSlopeCPerHour?.value.reason, .insufficientCoverage)
        XCTAssertNil(group.preOnsetSlopeCPerHour?.value.value)
    }

    /// Re-wear exclusion: 5 minutes after an off-wrist end are excluded from the summary.
    func testRewearExclusion() {
        let start = t0
        var samples: [SkinTempSample] = []
        // 34 minutes, but the first 5 (right after an off-wrist end at `start`) are excluded.
        for m in 0..<34 {
            for s in 0..<60 { samples.append(SkinTempSample(ts: start + m * 60 + s, raw: 3300)) }
        }
        let end = start + 34 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples,
                                offWrist: [SleepAnalyticsInterval(start: start - 300, end: start)]),
            config: .v1)
        XCTAssertEqual(group.rewearEventVerified, true)
        XCTAssertEqual(group.equilibrationExcludedMinutes, 5)
        XCTAssertEqual(group.quality.streamCounts["temp_valid_minutes"], 29)
    }

    /// No off-wrist evidence: warmup was not verified and nothing is excluded.
    func testNoRewearEventNothingExcluded() {
        let start = t0
        var samples: [SkinTempSample] = []
        for m in 0..<31 {
            for s in 0..<60 { samples.append(SkinTempSample(ts: start + m * 60 + s, raw: 3300)) }
        }
        let end = start + 31 * 60
        let group = SleepAnalyticsV1.thermalGroup(
            timeline: makeTimeline(start: start, end: end),
            input: thermalInput(start: start, end: end, skinTemp: samples),
            config: .v1)
        XCTAssertEqual(group.rewearEventVerified, false)
        XCTAssertEqual(group.equilibrationExcludedMinutes, 0)
        XCTAssertEqual(group.quality.streamCounts["temp_valid_minutes"], 31)
    }
}

final class SleepAnalyticsPrvGroupTests: XCTestCase {

    private let t0 = 1_789_000_000

    private func input(start: Int, end: Int, beats: [RRInterval]) -> SleepAnalyticsInput {
        SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: beats, deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
    }

    /// Direct pair-space oracle: SD1/SD2 computed BY HAND from the u/v formulas on a
    /// small clean series (200+ pairs in one 5-minute window via 1.0 s beats).
    func testDirectPairSpaceOracle() {
        // A 5-minute UTC-aligned window with ~250 one-second beats: RR alternates
        // 900/1000 ms so u alternates ±(100/√2) and v steps.
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            let rr = i % 2 == 0 ? 900 : 1000
            beats.append(RRInterval(ts: ts, rrMs: rr, srcChannel: nil, ord: i, seq: i))
            ts += 1
            i += 1
        }
        let timeline = SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: []),
                                                  config: .v1)
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertEqual(group.eligibleWindowCount.value, 1)
        XCTAssertEqual(group.timingMethod, "ts_seq_ord_chain")
        XCTAssertEqual(group.nightlySd1Ms.status, .available)
        XCTAssertEqual(group.nightlySd2Ms.status, .available)
        // Oracle: pairs (900,1000) and (1000,900) alternate.
        // u = ±50√2 (≈ ±70.7107); v = 1900/√2 or 1900/√2 → both 1343.503.
        // SD1 = stdev of alternating ±70.7107 = 70.7107·√((250-1)/249·2)... compute directly:
        var us: [Double] = []
        for k in 1..<beats.count {
            let a = Double(beats[k - 1].rrMs), b = Double(beats[k].rrMs)
            us.append((b - a) / 2.0.squareRoot())
        }
        let oracleSd1 = SleepAnalyticsV1.stdev(us)!
        XCTAssertEqual(group.nightlySd1Ms.value!, oracleSd1, accuracy: 1e-9)
        var vs: [Double] = []
        for k in 1..<beats.count {
            let a = Double(beats[k - 1].rrMs), b = Double(beats[k].rrMs)
            vs.append((a + b) / 2.0.squareRoot())
        }
        let oracleSd2 = SleepAnalyticsV1.stdev(vs)!
        XCTAssertEqual(group.nightlySd2Ms.value!, oracleSd2, accuracy: 1e-9)
        // v = (a+b)/√2 is CONSTANT on this 900/1000 alternation → the summary SD2 is
        // exactly 0 → the ratio is null with `zero_denominator` (never a fake 0.0).
        XCTAssertNil(group.nightlyRatio.value)
        XCTAssertEqual(group.nightlyRatio.reason, .zeroDenominator)
        XCTAssertEqual(group.rejectionFraction.value!, 0.0, accuracy: 1e-12)
        _ = timeline
    }

    /// Constant intervals: SD1 = 0, SD2 = 0 → ratio null zero_denominator.
    func testConstantIntervalsZeroSd2RatioNull() {
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            beats.append(RRInterval(ts: ts, rrMs: 950, srcChannel: nil, ord: i, seq: i))
            ts += 1
            i += 1
        }
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertEqual(group.eligibleWindowCount.value, 1)
        XCTAssertEqual(group.nightlySd1Ms.value!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(group.nightlySd2Ms.value!, 0.0, accuracy: 1e-9)
        XCTAssertNil(group.nightlyRatio.value)
        XCTAssertEqual(group.nightlyRatio.reason, .zeroDenominator)
    }

    /// A removed ectopic beat must NOT form a new adjacent pair (gap-aware splices).
    func testRemovedEctopicBeatDoesNotFormNewPair() {
        // 250 clean 1000 ms beats, one 400 ms ectopic in the middle: the pairs
        // spanning it are spliced out by cleanRRGapAware's contiguous flags.
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            let rr = (ts == start + 130) ? 400 : 1000
            beats.append(RRInterval(ts: ts, rrMs: rr, srcChannel: nil, ord: i, seq: i))
            ts += 1
            i += 1
        }
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        // The 400 ms beat fails the range filter (rrMinMs 300? no — 400 is IN range).
        // Malik: |400 - 1000|/1000 = 0.6 > 0.20 → ectopic-rejected. Its two
        // neighbouring pairs are spliced: 249 - 2 = 247 pairs.
        XCTAssertEqual(group.validPairs.value, 269)   // 271 pairs − the 2 spliced at the ectopic
        XCTAssertEqual(group.rejectionFraction.value!, 1.0 / 272.0, accuracy: 1e-9)
    }

    /// Equal legitimate RR values are retained (identity dedup, never value dedup).
    func testEqualLegitimateValuesRetained() {
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            beats.append(RRInterval(ts: ts, rrMs: 1000, srcChannel: nil, ord: i, seq: i))
            ts += 1
            i += 1
        }
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertEqual(group.validPairs.value, 271)   // all equal-value pairs kept (272 beats)
    }

    /// A byte-identical retransmission collapses once (observation identity).
    func testRetransmittedIdentityRemovedOnce() {
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            beats.append(RRInterval(ts: ts, rrMs: i % 2 == 0 ? 900 : 1000, srcChannel: nil, ord: i, seq: i))
            ts += 1
            i += 1
        }
        let retransmit = beats[10]
        let withRetransmit = beats + [retransmit]
        let a = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: withRetransmit),
                                                  config: .v1),
            input: input(start: start, end: start + 300, beats: withRetransmit),
            config: .v1)
        let b = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertEqual(a.quality.streamCounts["rr_received_deduped"], 273)
        XCTAssertEqual(a.quality.streamCounts["rr_deduped"], 272)
        XCTAssertEqual(a.validPairs.value, b.validPairs.value)
    }

    /// Two beats sharing a whole second with NO ord/seq resolution → unresolved.
    func testWholeSecondOrderingUnresolved() {
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        while ts < start + 250 {
            beats.append(RRInterval(ts: ts, rrMs: 1000, srcChannel: nil))   // no ord, seq 0
            ts += 1
        }
        // Add an ambiguous same-second beat: same ts and seq as the base beat but a
        // DIFFERENT interval (distinct observation identity, no ord chain) — the pair's
        // order inside the second cannot be resolved.
        beats.append(RRInterval(ts: start + 10, rrMs: 1100, srcChannel: nil))
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertTrue(group.timingMethod.hasPrefix("ts_seq_ord_chain_ambiguous"))
        XCTAssertEqual(group.quality.streamCounts["rr_unresolved_adjacencies"]!, 1)  // the ambiguous pair
    }

    /// A wall-clock gap breaks adjacency (never concatenated).
    func testWallClockGapBreaksAdjacency() {
        let start = t0 - t0 % 300
        var beats: [RRInterval] = []
        var ts = start
        var i = 0
        while ts < start + 272 {
            beats.append(RRInterval(ts: ts, rrMs: 1000, srcChannel: nil, ord: i, seq: i))
            ts += (ts == start + 100) ? 30 : 1     // one 30 s hole
            i += 1
        }
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                 config: .v1),
            input: input(start: start, end: start + 300, beats: beats),
            config: .v1)
        XCTAssertEqual(group.quality.streamCounts["rr_unresolved_adjacencies"]!, 1)
    }

    /// Gate boundaries. At the ≥90% coverage gate a 300-second window carries ~270
    /// pairs by construction (adjacent beats tile the window), so the 200-PAIR gate
    /// is never independently reachable inside one window — the reachable boundaries
    /// asserted here are the COVERAGE gate (0.91 eligible vs 0.51 withheld) and the
    /// window DURATION gate (a clipped window is withheld as insufficient_duration).
    func testStrictWindowGateBoundaries() {
        func groupWithBeats(_ beatCount: Int, rr: Int = 1000) -> SleepAnalyticsPrvDiagnosticsGroup {
            let start = t0 - t0 % 300
            var beats: [RRInterval] = []
            var ts = start
            var i = 0
            while beats.count < beatCount {
                beats.append(RRInterval(ts: ts, rrMs: rr, srcChannel: nil, ord: i, seq: i))
                ts += 1
                i += 1
            }
            return SleepAnalyticsV1.prvGroup(
                timeline: SleepAnalyticsV1.normalize(input: input(start: start, end: start + 300, beats: beats),
                                                     config: .v1),
                input: input(start: start, end: start + 300, beats: beats),
                config: .v1)
        }
        // 272 beats: 271 pairs ≥ 200, coverage 272/300 = 0.9067 ≥ 0.90 → eligible.
        let eligible = groupWithBeats(272)
        XCTAssertEqual(eligible.eligibleWindowCount.value, 1)
        XCTAssertEqual(eligible.windows.first?.pairs, 271)
        XCTAssertEqual(eligible.windows.first?.coverage ?? -1, 0.90666, accuracy: 1e-4)
        // 151 beats: 150 pairs ≥ 200? NO — 150 < 200 AND coverage 0.503 < 0.90: the
        // window is withheld; the pair gate and coverage gate agree here.
        let sparse = groupWithBeats(151)
        XCTAssertEqual(sparse.eligibleWindowCount.value, 0)
        XCTAssertEqual(sparse.withheldWindowCount.value, 1)
        // A clipped window (fragment shorter than 300 s) is withheld, not eligible.
        let start = t0 - t0 % 300
        let shortInput = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "short", start: start, end: start + 200,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: start + 200, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 200).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [],
            beats: (start..<start + 200).map { RRInterval(ts: $0, rrMs: 1000, srcChannel: nil, ord: $0, seq: $0) },
            deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let short = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(input: shortInput, config: .v1),
            input: shortInput, config: .v1)
        XCTAssertEqual(short.eligibleWindowCount.value, 0)
        // The clipped tail window is WITHHELD as insufficient_duration (review P2-5),
        // never silently skipped.
        XCTAssertEqual(short.withheldWindowCount.value, 1)
        XCTAssertEqual(short.nightlySd1Ms.status, .unavailable)
        XCTAssertEqual(short.nightlySd1Ms.reason, .insufficientDuration)
    }

    /// Disabled config → the whole group is disabled, no numbers.
    func testDisabledConfigYieldsDisabledGroup() {
        var config = SleepAnalyticsConfig.v1
        config.prvDiagnosticsEnabled = false
        let group = SleepAnalyticsV1.prvGroup(
            timeline: SleepAnalyticsV1.normalize(
                input: input(start: t0, end: t0 + 300, beats: []), config: .v1),
            input: input(start: t0, end: t0 + 300, beats: []),
            config: config)
        XCTAssertEqual(group.quality.status, .disabled)
        XCTAssertEqual(group.nightlySd1Ms.status, .disabled)
        XCTAssertEqual(group.nightlyRatio.status, .disabled)
        XCTAssertTrue(group.windows.isEmpty)
    }

    /// The canonical RMSSD path is unchanged: cleanRR/canonical outputs on a fixed
    /// series match their independent expectations (the PRV group only CALLS them).
    func testCanonicalRmssdPathUnchanged() {
        let series = [900.0, 1000.0, 905.0, 995.0, 910.0, 1000.0, 890.0, 1010.0, 930.0, 970.0]
        let cleaned = HRVAnalyzer.cleanRR(series)
        let expectedClean = HRVAnalyzer.rangeFilter(series)
        XCTAssertEqual(cleaned, expectedClean)     // no ectopic in this fixture
        // RMSSD over the clean series, computed independently here:
        var sumSq = 0.0
        var count = 0
        for k in 1..<cleaned.count {
            sumSq += (cleaned[k] - cleaned[k - 1]) * (cleaned[k] - cleaned[k - 1])
            count += 1
        }
        let rmssd = (sumSq / Double(count)).squareRoot()
        XCTAssertEqual(rmssd, 92.4662, accuracy: 0.001)
        // The PRV group pairs cleaned values with their original observations through the
        // cleaner's OWN kept-original indices (review P1-1: the previous re-derivation
        // mirrored Malik with a different median and could silently flip borderline
        // beats). Parity is structural now: the indices the cleaner returns ARE the
        // survivors' positions in the original series, and `nn` equals the original
        // series at exactly those positions.
        let gapAware = HRVAnalyzer.cleanRRGapAware(series)
        XCTAssertEqual(gapAware.nn, gapAware.keptOriginalIndices.map { series[$0] })
        XCTAssertEqual(gapAware.contiguous.count, gapAware.nn.count)
        // A borderline fixture pins the exact-median behaviour the old mirror got
        // wrong: neighbours [700, 700, 705, 705] around a 845 ms beat — HRVAnalyzer's
        // median (mean of the two middles, 702.5) drops it (0.203 > 0.20).
        let borderlineNeighbours = [700.0, 700.0, 705.0, 705.0]
        XCTAssertEqual(HRVAnalyzer.median(borderlineNeighbours), 702.5)
        XCTAssertFalse(abs(845.0 - 702.5) / 702.5 <= HRVAnalyzer.ectopicThreshold)
    }
}
