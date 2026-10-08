import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// Stage-associated movement (spec-02 §4, docs/spec-02/CONTRACT.md §4.4): every classified one-second
// gravity adjacency joined to the normalized label at its second; unknown stays unknown; a bout belongs
// to the label at its first moving second; disclosure `stages_may_depend_on_motion`.
final class SleepAnalyticsStageMovementTests: XCTestCase {

    private let s = 1_789_000_200        // a multiple of 30 s: stage boundaries stay epoch-aligned

    /// light [0, 2400) · deep [2400, 3600) · rem [3600, 4110) · uncovered [4110, 4200) · wake [4200, 4800)
    /// (every boundary on the 30 s epoch grid)
    private var stages: [StageSegment] {
        [StageSegment(start: s, end: s + 2400, stage: "light"),
         StageSegment(start: s + 2400, end: s + 3600, stage: "deep"),
         StageSegment(start: s + 3600, end: s + 4110, stage: "rem"),
         StageSegment(start: s + 4200, end: s + 4800, stage: "wake")]
    }

    private func input(gravity: [GravitySample]) -> SleepAnalyticsInput {
        SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-stage-movement", start: s, end: s + 4800,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (s..<s + 4800).map { HRSample(ts: $0, bpm: 58) },
            gravity: gravity, skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
    }

    /// Still wrist except one displaced sample at each listed offset (each makes two moving
    /// adjacencies: into it at t = offset and out of it at t = offset + 1).
    private func gravity(spikesAt offsets: Set<Int>) -> [GravitySample] {
        (s..<s + 4800).map { ts in GravitySample(ts: ts, x: offsets.contains(ts - s) ? 0.02 : 0, y: 0, z: 1) }
    }

    private func movementGroup(_ input: SleepAnalyticsInput) -> SleepAnalyticsMovementGroup {
        SleepAnalyticsV1.movementGroup(timeline: SleepAnalyticsV1.normalize(input: input, config: .v1),
                                       input: input, config: .v1)
    }

    private func entry(_ g: SleepAnalyticsMovementGroup, _ label: SleepAnalyticsLabel) throws -> SleepAnalyticsStageMovement {
        try XCTUnwrap(g.stageMovement?.first { $0.label == label })
    }

    func testAdjacenciesJoinTheLabelAtTheirSecond() throws {
        // light spike at 100; a spike at 2399 straddles light→deep (moving t = 2399 light, 2400 deep,
        // one bout starting in light); deep spike at 2700; uncovered spike at 4150; wake spikes 4300, 4500.
        let g = movementGroup(input(gravity: gravity(spikesAt: [100, 2399, 2700, 4150, 4300, 4500])))
        XCTAssertEqual(g.stageMovement?.map(\.label), [.wake, .light, .deep, .rem, .unknown])
        XCTAssertEqual(g.stageMovementNote, "stages_may_depend_on_motion")

        let light = try entry(g, .light), deep = try entry(g, .deep), rem = try entry(g, .rem)
        let unknown = try entry(g, .unknown), wake = try entry(g, .wake)
        XCTAssertEqual(light.eligibleSeconds.value, 2399)        // t = s+1 … s+2399
        XCTAssertEqual(deep.eligibleSeconds.value, 1200)
        XCTAssertEqual(rem.eligibleSeconds.value, 510)
        XCTAssertEqual(unknown.eligibleSeconds.value, 90, "uncovered time stays unknown")
        XCTAssertEqual(wake.eligibleSeconds.value, 600)

        XCTAssertEqual(light.movementSeconds.value, 3)            // 100, 101, 2399
        XCTAssertEqual(deep.movementSeconds.value, 3)             // 2400, 2700, 2701
        XCTAssertEqual(rem.movementSeconds.value, 0)
        XCTAssertEqual(unknown.movementSeconds.value, 2)
        XCTAssertEqual(wake.movementSeconds.value, 4)

        XCTAssertEqual(light.movementBoutStarts.value, 2, "the straddling bout belongs to its first second")
        XCTAssertEqual(deep.movementBoutStarts.value, 1)
        XCTAssertEqual(rem.movementBoutStarts.value, 0)
        XCTAssertEqual(unknown.movementBoutStarts.value, 1)
        XCTAssertEqual(wake.movementBoutStarts.value, 2)

        XCTAssertEqual(try XCTUnwrap(light.movementPercentage.value), 100.0 * 3 / 2399, accuracy: 1e-12)
        XCTAssertEqual(light.movementPercentage.unit, "%")
        // ≥ 1800 eligible seconds → the per-hour rate is available; below it, partial.
        XCTAssertEqual(light.movementBoutsPerEligibleHour.status, .available)
        XCTAssertEqual(try XCTUnwrap(light.movementBoutsPerEligibleHour.value), 2 / (2399.0 / 3600), accuracy: 1e-12)
        XCTAssertEqual(deep.movementBoutsPerEligibleHour.status, .partial)
        XCTAssertEqual(light.movementBoutsPerEligibleHour.unit, "per_h")
        // REM: real exposure with no movement is a genuine zero, not null.
        XCTAssertEqual(rem.movementPercentage.value, 0)
        XCTAssertEqual(rem.movementPercentage.status, .available)
        XCTAssertEqual(rem.movementBoutsPerEligibleHour.value, 0)

        // The per-label split partitions the group totals exactly.
        let entries = try XCTUnwrap(g.stageMovement)
        XCTAssertEqual(entries.compactMap(\.eligibleSeconds.value).reduce(0, +), g.eligibleSeconds.value)
        XCTAssertEqual(entries.compactMap(\.movementSeconds.value).reduce(0, +), g.movementSeconds.value)
        XCTAssertEqual(entries.compactMap(\.movementBoutStarts.value).reduce(0, +), g.movementBoutCount.value)
    }

    func testMissingGravityKeepsEverythingUnknownAndUnavailable() throws {
        // A hole in the gravity stream inside deep removes those adjacencies from deep (never re-labelled).
        var grav = gravity(spikesAt: [])
        grav.removeAll { $0.ts >= s + 3000 && $0.ts < s + 3100 }
        let g = movementGroup(input(gravity: grav))
        XCTAssertEqual(try entry(g, .deep).eligibleSeconds.value, 1200 - 101)

        let none = movementGroup(input(gravity: []))
        for e in try XCTUnwrap(none.stageMovement) {
            XCTAssertEqual(e.eligibleSeconds.status, .unavailable)
            XCTAssertEqual(e.eligibleSeconds.reason, .noSamples)
            XCTAssertNil(e.movementPercentage.value)
            XCTAssertNil(e.movementBoutStarts.value)
        }
        XCTAssertEqual(none.stageMovementNote, "stages_may_depend_on_motion")
    }

    func testLabelWithNoExposureWithholdsRatios() throws {
        // Same night without REM staging: REM has zero eligible seconds — a real zero exposure, null ratios.
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "no-rem", start: s, end: s + 1800, sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: s, end: s + 1800, stage: "light")])],
            timezoneId: "Etc/UTC", hr: (s..<s + 1800).map { HRSample(ts: $0, bpm: 58) },
            gravity: (s..<s + 1800).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }, skinTemp: [], beats: [],
            deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let rem = try entry(movementGroup(input), .rem)
        XCTAssertEqual(rem.eligibleSeconds.value, 0)
        XCTAssertEqual(rem.eligibleSeconds.status, .available)
        XCTAssertNil(rem.movementPercentage.value)
        XCTAssertEqual(rem.movementPercentage.reason, .zeroDenominator)
        XCTAssertNil(rem.movementBoutsPerEligibleHour.value)
    }

    func testWireKeys() throws {
        let g = movementGroup(input(gravity: gravity(spikesAt: [100])))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as? [String: Any])
        XCTAssertEqual(json["stage_movement_note"] as? String, "stages_may_depend_on_motion")
        let first = try XCTUnwrap((json["stage_movement"] as? [[String: Any]])?.first { ($0["label"] as? String) == "light" })
        for key in ["eligible_seconds", "movement_seconds", "movement_percentage", "movement_bout_starts",
                    "movement_bouts_per_eligible_hour"] {
            XCTAssertNotNil(first[key], key)
        }
        let decoded = try JSONDecoder().decode(SleepAnalyticsMovementGroup.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(decoded, g)
    }
}
