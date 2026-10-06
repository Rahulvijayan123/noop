// SleepAnalyticsAttachTests.swift
//
// Worker adapter tests for the Phase 1 sleep analytics document
// (`daily.sleep_analytics_v1`, docs/sleep-analytics/spec.md section 8 "Worker steps" +
// section 12 "Worker/backend" rows). Pure: no database, no sidecar.
//
// The compute()-dependent assertions run against the real
// `SleepAnalyticsV1.compute(input:config:)` once the parent merges the group computers
// (W1/W2) into this branch; until then they run against the local temporary stub.

import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import frwhoop_worker

final class SleepAnalyticsAttachTests: XCTestCase {

    // MARK: - Fixtures

    private let t0 = 1_789_000_000
    private let userId = "7f2c9a10-4b3e-4d8a-9c11-00000000f001"
    private let deviceId = "11111111-1111-4111-8111-111111111111"
    private let day = "2026-10-05"

    private func makeClaim(inputRevision: Int64 = 7, timezone: String = "America/Los_Angeles") -> DayScorer.Claim {
        DayScorer.Claim(userId: userId, deviceId: deviceId, day: day, timezoneId: timezone,
                        inputRevision: inputRevision, leaseToken: "lease", runId: "run",
                        measurementRevision: 0)
    }

    private func epochStages(start: Int, labels: [String]) -> [StageSegment] {
        labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
    }

    /// Spec section 12 hand fixture labels.
    private func handFixtureLabels() -> [String] {
        ["wake", "light", "light", "deep", "deep", "light",
         "rem", "rem", "wake", "light", "light", "wake"]
    }

    private func sleepSession(start: Int, end: Int, labels: [String]) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9,
                     stages: epochStages(start: start, labels: labels),
                     restingHR: nil, avgHRV: nil)
    }

    private func fullHR(start: Int, end: Int) -> [HRSample] {
        (start..<end).map { HRSample(ts: $0, bpm: 58) }
    }

    private func makeDayResult(blocks: [(start: Int, end: Int)],
                               sessions: [SleepSession]) -> AnalyticsEngine.DayResult {
        let daily = DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        return AnalyticsEngine.DayResult(
            daily: daily, sleepSessions: sessions, cachedSleep: [], workouts: [],
            recovery: nil, strain: nil,
            mainNightBlocks: blocks.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) })
    }

    private func sleepEdit(entity: String = "edit", revision: Int64,
                           originalStart: Int, originalEnd: Int) -> DayScorer.CandidateSleepEdit {
        DayScorer.CandidateSleepEdit(entity: entity, revision: revision,
                                     payload: JSONValue(any: [
                                        "originalStart": Double(originalStart),
                                        "originalEnd": Double(originalEnd),
                                     ]))
    }

    private func nightResult(start: Int? = nil, minutes: Int = 6,
                             labels: [String]? = nil) -> AnalyticsEngine.DayResult {
        let start = start ?? t0
        let end = start + minutes * 60
        return makeDayResult(blocks: [(start, end)],
                             sessions: [sleepSession(start: start, end: end,
                                                     labels: labels ?? handFixtureLabels())])
    }

    // MARK: - Input assembly: main-night fragment selection (spec worker step 1)

    func testInputPicksExactlyMainNightFragmentsAndExcludesNap() throws {
        // One 6-minute main night (the spec hand fixture) + a 2-hour nap NOT in the main-night
        // group. The nap must stay out even though it spans many epochs.
        let night = (start: t0, end: t0 + 12 * 30)
        let nap = (start: t0 + 3_600, end: t0 + 3_600 + 240 * 30)
        let result = makeDayResult(
            blocks: [night],
            sessions: [sleepSession(start: night.start, end: night.end, labels: handFixtureLabels()),
                       sleepSession(start: nap.start, end: nap.end,
                                    labels: Array(repeating: "light", count: 240))])
        let input = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: fullHR(start: night.start, end: night.end), rr: [], gravity: [], skinTemp: [],
            skinFamily: .whoop5, edits: [], offWristIntervals: []))
        XCTAssertEqual(input.fragments.count, 1)
        let fragment = input.fragments[0]
        XCTAssertEqual(fragment.id, "sleep-\(deviceId)-\(night.start)")
        XCTAssertEqual(fragment.start, night.start)
        XCTAssertEqual(fragment.end, night.end)
        XCTAssertEqual(fragment.sourceKind, .nativeWhoop)
        XCTAssertEqual(fragment.sourceEpochSeconds, 30)
        XCTAssertEqual(fragment.edited, false)
        XCTAssertNil(fragment.editRevision)
        XCTAssertEqual(fragment.stages, epochStages(start: night.start, labels: handFixtureLabels()))
    }

    func testInputPicksEveryMainNightFragmentSortedByStart() throws {
        // A fragmented main night: two blocks, listed in reverse order in mainNightBlocks.
        let early = (start: t0, end: t0 + 3_600)
        let late = (start: t0 + 4_000, end: t0 + 7_600)
        let result = makeDayResult(
            blocks: [late, early],
            sessions: [sleepSession(start: late.start, end: late.end, labels: ["light"]),
                       sleepSession(start: early.start, end: early.end, labels: ["light"])])
        let input = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: []))
        XCTAssertEqual(input.fragments.map(\.start), [early.start, late.start])
        XCTAssertEqual(input.fragments.count, 2)
    }

    func testInputNilWhenNoMainNightFragments() {
        // No blocks and/or no sessions: the day has no main-night group → document withheld.
        let noSessions = makeDayResult(blocks: [(t0, t0 + 3_600)], sessions: [])
        XCTAssertNil(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: noSessions, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: []))
        let napOnly = makeDayResult(
            blocks: [], sessions: [sleepSession(start: t0, end: t0 + 3_600, labels: ["light"])])
        XCTAssertNil(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: napOnly, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: []))
    }

    // MARK: - Input assembly: edit lineage (same rule as attachSleepFeatures)

    func testInputEditedFlagAndRevisionFromOverlappingEdit() throws {
        let night = (start: t0, end: t0 + 12 * 30)
        let result = makeDayResult(blocks: [night],
                                   sessions: [sleepSession(start: night.start, end: night.end,
                                                           labels: handFixtureLabels())])
        // Two overlapping accepted edits: the NEWEST revision (9) is the authoritative one
        // stamped on the fragment, regardless of the order the caller passes them in
        // (loadSleepEdits returns newest-first, but the adapter must not depend on it).
        let edits = [sleepEdit(entity: "old", revision: 3, originalStart: t0 - 60, originalEnd: t0 + 60),
                     sleepEdit(entity: "new", revision: 9, originalStart: t0 - 30, originalEnd: t0 + 120)]
        let edited = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: edits,
            offWristIntervals: []))
        XCTAssertEqual(edited.fragments[0].edited, true)
        XCTAssertEqual(edited.fragments[0].editRevision, 9)

        // A non-overlapping edit (fully outside the session) must not mark the fragment.
        let nonOverlapping = [sleepEdit(revision: 5, originalStart: t0 + 4_000, originalEnd: t0 + 5_000)]
        let clean = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5,
            edits: nonOverlapping, offWristIntervals: []))
        XCTAssertEqual(clean.fragments[0].edited, false)
        XCTAssertNil(clean.fragments[0].editRevision)

        // An edit payload without originalStart/originalEnd is never treated as an overlap.
        let malformed = DayScorer.CandidateSleepEdit(entity: "e", revision: 2,
                                                     payload: JSONValue(any: ["start": 1.0]))
        let malformedResult = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [malformed],
            offWristIntervals: []))
        XCTAssertEqual(malformedResult.fragments[0].edited, false)
    }

    // MARK: - Input assembly: off-wrist + thermal anchor lineage (worker step 2)

    func testInputOffWristAndAnchorLineage() throws {
        let result = nightResult()
        // Whoop 5: no anchor; off-wrist pairs map to SleepAnalyticsInterval.
        let whoop5 = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: [(100, 200), (900, 1_000)]))
        XCTAssertNil(whoop5.skinTempAnchorRaw)
        XCTAssertEqual(whoop5.offWristIntervals,
                       [SleepAnalyticsInterval(start: 100, end: 200),
                        SleepAnalyticsInterval(start: 900, end: 1_000)])

        // Whoop 4 with enough in-band worn raws: the per-device anchor is derived exactly like
        // attachSleepFeatures does (Whoop4SkinTemp.deviceAnchorRaw over the loaded raws).
        let raws = (0..<200).map { _ in 826 }
        let whoop4 = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: raws.map { SkinTempSample(ts: t0 + $0, raw: 826) },
            skinFamily: .whoop4, edits: [], offWristIntervals: []))
        XCTAssertNotNil(whoop4.skinTempAnchorRaw)
        XCTAssertEqual(whoop4.skinTempAnchorRaw, 826.0)
        XCTAssertEqual(whoop4.deviceFamily, .whoop4)
    }

    // MARK: - Input assembly: lineage fields (worker steps 1–2, 7)

    func testInputStageSourceVersionAndInputRevision() throws {
        let result = nightResult()
        let input = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "sleep-stager-v2-test", result: result,
            claim: makeClaim(inputRevision: 42), hr: [], rr: [], gravity: [], skinTemp: [],
            skinFamily: .whoop5, edits: [], offWristIntervals: []))
        XCTAssertEqual(input.stageSourceVersion, "sleep-stager-v2-test")
        XCTAssertEqual(input.inputRevision, 42)
        XCTAssertEqual(input.timezoneId, "America/Los_Angeles")
        XCTAssertNil(input.attemptedSleepMarker)   // Phase 1 wires none
        // Beats are the observation-identity-deduped rows (the candidate lane's rule).
        let beats = [RRInterval(ts: t0, rrMs: 1_000, srcChannel: nil, ord: nil, seq: 0),
                     RRInterval(ts: t0, rrMs: 1_000, srcChannel: nil, ord: nil, seq: 0),
                     RRInterval(ts: t0, rrMs: 1_000, srcChannel: nil, ord: nil, seq: 1)]
        let deduped = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "x", result: result, claim: makeClaim(),
            hr: [], rr: beats, gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: []))
        XCTAssertEqual(deduped.beats.count, 2)
    }

    // MARK: - Document serialization round-trip (hand-built document; no compute needed)

    func testHandBuiltDocumentJSONRoundTrip() throws {
        // Build a wire-format document by hand, decode into the typed SleepAnalyticsDocument,
        // re-encode, and assert the metadata + all five groups survive.
        let dict = Self.documentDictionary(start: t0, end: t0 + 360, fingerprint: "fp")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let document = try JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.algorithmVersion, "nara-sleep-analytics-1")
        XCTAssertEqual(document.configVersion, "v1")
        XCTAssertEqual(document.scope, "main_night")
        XCTAssertEqual(document.timezone, "America/Los_Angeles")
        XCTAssertEqual(document.start, t0)
        XCTAssertEqual(document.end, t0 + 360)
        XCTAssertEqual(document.inputRevision, 7)

        let reencoded = try JSONEncoder().encode(document)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["algorithmVersion"] as? String, "nara-sleep-analytics-1")
        XCTAssertEqual(obj["scope"] as? String, "main_night")
        for key in ["continuity", "stageDynamics", "movement", "thermal", "prvDiagnostics"] {
            XCTAssertNotNil(obj[key], key)
        }
        XCTAssertTrue(DayScorer.isFiniteJSON(obj))
    }

    func testHandBuiltDocumentDecodesTolerantLeavesAndExplicitNull() throws {
        // A metric with a null value and no reason decodes to unavailable with no reason and
        // re-encodes as explicit null (never a fabricated zero).
        var dict = Self.documentDictionary(start: t0, end: t0 + 360, fingerprint: "fp")
        var continuity = dict["continuity"] as! [String: Any]
        continuity["observedWasoSeconds"] = ["value": NSNull(), "unit": "s",
                                             "status": "unavailable", "reason": "no_samples"]
        dict["continuity"] = continuity
        let data = try JSONSerialization.data(withJSONObject: dict)
        let document = try JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
        let waso = document.continuity.observedWasoSeconds
        XCTAssertNil(waso.value)
        XCTAssertEqual(waso.status, .unavailable)
        XCTAssertEqual(waso.reason, .noSamples)
    }

    // MARK: - Fingerprint (stale-document guard)

    func testFingerprintDeterministicAndChangesWithBounds() throws {
        func input(_ start: Int, _ end: Int) throws -> SleepAnalyticsInput {
            try XCTUnwrap(DayScorer.sleepAnalyticsInput(
                stageSourceVersion: "frwhoop-server-1",
                result: makeDayResult(blocks: [(start, end)],
                                      sessions: [sleepSession(start: start, end: end, labels: ["light"])]),
                claim: makeClaim(), hr: [], rr: [], gravity: [], skinTemp: [],
                skinFamily: .whoop5, edits: [], offWristIntervals: []))
        }
        let a = try input(t0, t0 + 360)
        let timelineA = SleepAnalyticsV1.normalize(input: a, config: .v1)
        let fpA1 = SleepAnalyticsV1.documentFingerprint(input: a, timeline: timelineA, config: .v1)
        let fpA2 = SleepAnalyticsV1.documentFingerprint(input: a, timeline: timelineA, config: .v1)
        XCTAssertEqual(fpA1, fpA2, "same input → same fingerprint")

        let b = try input(t0, t0 + 390)   // end moved
        let timelineB = SleepAnalyticsV1.normalize(input: b, config: .v1)
        let fpB = SleepAnalyticsV1.documentFingerprint(input: b, timeline: timelineB, config: .v1)
        XCTAssertNotEqual(fpA1, fpB, "bounds change → fingerprint changes (stale-document guard)")

        // An edit also changes the fingerprint (lineage change → stale pre-edit doc).
        let edited = try XCTUnwrap(DayScorer.sleepAnalyticsInput(
            stageSourceVersion: "frwhoop-server-1",
            result: makeDayResult(blocks: [(t0, t0 + 360)],
                                  sessions: [sleepSession(start: t0, end: t0 + 360, labels: ["light"])]),
            claim: makeClaim(), hr: [], rr: [], gravity: [], skinTemp: [],
            skinFamily: .whoop5,
            edits: [sleepEdit(revision: 4, originalStart: t0 - 30, originalEnd: t0 + 30)],
            offWristIntervals: []))
        let timelineEdited = SleepAnalyticsV1.normalize(input: edited, config: .v1)
        let fpEdited = SleepAnalyticsV1.documentFingerprint(input: edited, timeline: timelineEdited, config: .v1)
        XCTAssertNotEqual(fpA1, fpEdited)
    }

    // MARK: - Full payload (compute-dependent; runs against the merged compute or the stub)

    func testPayloadDocumentMetadataAndAllFiveGroups() throws {
        let payload = try XCTUnwrap(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1", result: nightResult(),
            claim: makeClaim(), hr: fullHR(start: t0, end: t0 + 360), rr: [], gravity: [],
            skinTemp: [], skinFamily: .whoop5, edits: [], offWristIntervals: []))
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["algorithmVersion"] as? String, "nara-sleep-analytics-1")
        XCTAssertEqual(payload["scope"] as? String, "main_night")
        XCTAssertEqual(payload["timezone"] as? String, "America/Los_Angeles")
        XCTAssertEqual(payload["start"] as? Int, t0)
        XCTAssertEqual(payload["end"] as? Int, t0 + 360)
        for key in ["continuity", "stageDynamics", "movement", "thermal", "prvDiagnostics"] {
            XCTAssertNotNil(payload[key], key)
        }
    }

    func testPayloadCarriesFragmentLineage() throws {
        let payload = try XCTUnwrap(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1", result: nightResult(),
            claim: makeClaim(), hr: fullHR(start: t0, end: t0 + 360), rr: [], gravity: [],
            skinTemp: [], skinFamily: .whoop5, edits: [], offWristIntervals: []))
        let fragments = try XCTUnwrap(payload["fragments"] as? [[String: Any]])
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0]["id"] as? String, "sleep-\(deviceId)-\(t0)")
        XCTAssertEqual(fragments[0]["sourceKind"] as? String, "native_whoop_v2")
        XCTAssertEqual(fragments[0]["edited"] as? Bool, false)
        XCTAssertEqual(fragments[0]["start"] as? Int, t0)
        XCTAssertEqual(fragments[0]["end"] as? Int, t0 + 360)
        XCTAssertEqual(payload["inputRevision"] as? Int64, 7)
        XCTAssertEqual(payload["stageSourceVersion"] as? String, "frwhoop-server-1")
    }

    func testPayloadFingerprintDeterministicAcrossCallsAndChangesWithBounds() throws {
        func payloadFor(_ start: Int, _ end: Int) throws -> [String: Any]? {
            DayScorer.sleepAnalyticsPayload(
                stageSourceVersion: "frwhoop-server-1",
                result: makeDayResult(blocks: [(start, end)],
                                      sessions: [sleepSession(start: start, end: end, labels: ["light"])]),
                claim: makeClaim(), hr: fullHR(start: start, end: end), rr: [], gravity: [],
                skinTemp: [], skinFamily: .whoop5, edits: [], offWristIntervals: [])
        }
        let a = try XCTUnwrap(payloadFor(t0, t0 + 360))
        let a2 = try XCTUnwrap(payloadFor(t0, t0 + 360))
        XCTAssertEqual(a["fingerprint"] as? String, a2["fingerprint"] as? String)
        let b = try XCTUnwrap(payloadFor(t0, t0 + 390))
        XCTAssertNotEqual(a["fingerprint"] as? String, b["fingerprint"] as? String)
    }

    func testPayloadReturnsNilOnEmptySessionsWithoutCrashing() {
        let empty = makeDayResult(blocks: [], sessions: [])
        XCTAssertNil(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1", result: empty, claim: makeClaim(),
            hr: [], rr: [], gravity: [], skinTemp: [], skinFamily: .whoop5, edits: [],
            offWristIntervals: []))
    }

    func testPayloadIsFiniteAndCompactForARealisticEightHourNight() throws {
        // Full 8-hour night: 30-s stage variety, 1 Hz HR, sparse gravity, minute skin temp,
        // ~1 beat per second (~29k beats). The document must be finite and ≤ 64 KiB even with
        // dense inputs (it carries aggregates, never raw per-second arrays).
        let start = t0
        let end = t0 + 8 * 3_600
        let pattern = ["wake", "light", "deep", "rem"]
        let labels = (0..<(8 * 3_600 / 30)).map { pattern[$0 % pattern.count] }
        let hr = fullHR(start: start, end: end)
        let gravity = stride(from: start, to: end, by: 30).map { GravitySample(ts: $0, x: 0.5, y: 0.6, z: 0.7) }
        let skinTemp = stride(from: start, to: end, by: 60).map { SkinTempSample(ts: $0, raw: 826) }
        let beats = (start..<end).map { RRInterval(ts: $0, rrMs: 1_000, srcChannel: .whoop5Standard, ord: 0, seq: 0) }
        XCTAssertEqual(beats.count, 8 * 3_600)
        let payload = try XCTUnwrap(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1",
            result: makeDayResult(blocks: [(start, end)],
                                  sessions: [sleepSession(start: start, end: end, labels: labels)]),
            claim: makeClaim(), hr: hr, rr: beats, gravity: gravity, skinTemp: skinTemp,
            skinFamily: .whoop4, edits: [], offWristIntervals: []))
        XCTAssertTrue(DayScorer.isFiniteJSON(payload))
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertLessThanOrEqual(data.count, 64 * 1_024,
                                 "document must stay ≤ 64 KiB for a realistic night")
    }

    func testPayloadAddsNoOuterAlgorithmVersionKey() throws {
        // Spec worker step 6: new fields must not change the algorithm version reported by the
        // legacy compatibility code. The document's own algorithmVersion lives NESTED inside
        // sleep_analytics_v1; the payload never carries an outer algorithm_version/version key,
        // so attaching it to snapshotDaily cannot clobber daily["algorithm_version"].
        let payload = try XCTUnwrap(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1", result: nightResult(),
            claim: makeClaim(), hr: fullHR(start: t0, end: t0 + 360), rr: [], gravity: [],
            skinTemp: [], skinFamily: .whoop5, edits: [], offWristIntervals: []))
        // The document's own algorithm_version lives as `algorithmVersion` (camelCase, the
        // synthesized Codable key) INSIDE sleep_analytics_v1. It must never add the legacy
        // snake_case `algorithm_version` (or a stray `recovery`) to the daily object.
        XCTAssertEqual(payload["algorithmVersion"] as? String, "nara-sleep-analytics-1")
        XCTAssertNil(payload["algorithm_version"])
        XCTAssertNil(payload["schema_version"])
        XCTAssertNil(payload["recovery"])

        // Simulating the DayScoring attach: the only added key is sleep_analytics_v1.
        var daily: [String: Any] = ["algorithm_version": "frwhoop-server-1", "recovery": 61.0,
                                    "hrv_rmssd_ms": 42.5]
        daily["sleep_analytics_v1"] = payload
        XCTAssertEqual(daily["algorithm_version"] as? String, "frwhoop-server-1")
        XCTAssertEqual(daily["recovery"] as? Double, 61.0)
        XCTAssertEqual(daily["hrv_rmssd_ms"] as? Double, 42.5)
    }

    func testPayloadEditedFragmentCarriesEditLineage() throws {
        let night = (start: t0, end: t0 + 12 * 30)
        let result = makeDayResult(blocks: [night],
                                   sessions: [sleepSession(start: night.start, end: night.end,
                                                           labels: handFixtureLabels())])
        let payload = try XCTUnwrap(DayScorer.sleepAnalyticsPayload(
            stageSourceVersion: "frwhoop-server-1", result: result, claim: makeClaim(),
            hr: fullHR(start: night.start, end: night.end), rr: [], gravity: [], skinTemp: [],
            skinFamily: .whoop5,
            edits: [sleepEdit(revision: 6, originalStart: night.start - 30, originalEnd: night.start + 90)],
            offWristIntervals: []))
        let fragments = try XCTUnwrap(payload["fragments"] as? [[String: Any]])
        XCTAssertEqual(fragments[0]["edited"] as? Bool, true)
        XCTAssertEqual((fragments[0]["editRevision"] as? NSNumber)?.int64Value, 6)
    }

    // MARK: - Finite-JSON validation helper

    func testIsFiniteJSONAcceptsValidTreesAndRejectsNonFiniteNumbers() {
        XCTAssertTrue(DayScorer.isFiniteJSON(["a": 1.0, "b": [NSNull(), "x", true], "c": ["d": -0.5]]))
        XCTAssertTrue(DayScorer.isFiniteJSON(NSNull()))
        XCTAssertTrue(DayScorer.isFiniteJSON("string"))
        XCTAssertTrue(DayScorer.isFiniteJSON(true))
        XCTAssertFalse(DayScorer.isFiniteJSON(["a": Double.nan]))
        XCTAssertFalse(DayScorer.isFiniteJSON(["a": Double.infinity]))
        XCTAssertFalse(DayScorer.isFiniteJSON(["a": -Double.infinity]))
        XCTAssertFalse(DayScorer.isFiniteJSON([1.0, Double.nan]))
        XCTAssertFalse(DayScorer.isFiniteJSON(["a": ["b": ["c": Double.nan]]]))
    }

    // MARK: - Wire-format document helper (hand-built; synthesized memberwise inits of the
    // group structs are internal, so the tests build via decode like the adapter's consumers)

    /// A complete wire-format `sleep_analytics_v1` document dictionary with all five groups.
    static func documentDictionary(start: Int, end: Int, fingerprint: String) -> [String: Any] {
        func metric(_ value: Double?, unit: String, status: String, reason: String? = nil) -> [String: Any] {
            var d: [String: Any] = ["unit": unit, "status": status]
            d["value"] = value.map { NSNumber(value: $0) } ?? NSNull()
            if let r = reason { d["reason"] = r }
            return d
        }
        func count(_ value: Int?, status: String, reason: String? = nil) -> [String: Any] {
            var d: [String: Any] = ["unit": "count", "status": status]
            d["value"] = value.map { NSNumber(value: $0) } ?? NSNull()
            if let r = reason { d["reason"] = r }
            return d
        }
        let quality: [String: Any] = [
            "status": "available",
            "fragmentSpanSeconds": Double(max(0, end - start)),
            "groupSpanSeconds": Double(max(0, end - start)),
            "observedLabeledSeconds": Double(max(0, end - start)),
            "unknownSeconds": 0.0,
            "inferredGapAwakeSeconds": 0.0,
            "inputSupportedSeconds": Double(max(0, end - start)),
            "inputSupportedFraction": 1.0,
            "labelSupportedFraction": 1.0,
            "sourceResolutionSeconds": 30,
            "streamCounts": ["hr": 3600, "beats": 3600],
        ]
        let continuity: [String: Any] = [
            "quality": quality,
            "observedAsleepSeconds": metric(Double(max(0, end - start)), unit: "s", status: "available"),
            "observedWasoSeconds": metric(0, unit: "s", status: "available"),
            "inferredGapAwakeSecondsWithinSleepPeriod": metric(0, unit: "s", status: "available"),
            "estimatedWasoIncludingInferredGapsSeconds": metric(0, unit: "s", status: "available"),
            "onsetDelayFromWindowSeconds": metric(30, unit: "s", status: "available"),
            "sleepOnsetLatencyFromMarkerSeconds": metric(nil, unit: "s", status: "unavailable", reason: "missing_marker"),
            "remLatencyFromSleepOnsetSeconds": metric(150, unit: "s", status: "available"),
            "deepLatencyFromSleepOnsetSeconds": metric(60, unit: "s", status: "available"),
            "longestObservedSleepBoutSeconds": metric(210, unit: "s", status: "available"),
            "longestBoutCensored": false,
            "awakeningBoutCount": count(1, status: "available"),
            "censoredWakeStretchCount": count(0, status: "available"),
            "sleepToWakeTransitionCount": count(2, status: "available"),
            "sleepToWakeTransitionsPerAsleepHour": metric(nil, unit: "per h", status: "unavailable", reason: "insufficient_duration"),
        ]
        let stageSeconds: [[String: Any]] = [
            ["label": "wake", "seconds": metric(90, unit: "s", status: "available")],
            ["label": "light", "seconds": metric(120, unit: "s", status: "available")],
            ["label": "deep", "seconds": metric(60, unit: "s", status: "available")],
            ["label": "rem", "seconds": metric(60, unit: "s", status: "available")],
        ]
        func bout(_ label: String) -> [String: Any] {
            ["label": label,
             "boutCount": count(1, status: "available"),
             "completeBoutCount": count(1, status: "available"),
             "censoredBoutCount": count(0, status: "available"),
             "longestObservedSeconds": metric(120, unit: "s", status: "available"),
             "medianCompleteBoutSeconds": metric(120, unit: "s", status: "available"),
             "p90CompleteBoutSeconds": metric(120, unit: "s", status: "available")]
        }
        let stageDynamics: [String: Any] = [
            "quality": quality, "stageSeconds": stageSeconds,
            "stageBouts": [bout("wake"), bout("light"), bout("deep"), bout("rem")],
            "epochTransitions": NSNull(),
        ]
        let movement: [String: Any] = [
            "quality": quality,
            "movementSeconds": metric(0, unit: "s", status: "available"),
            "eligibleSeconds": metric(300, unit: "s", status: "available"),
            "movementPercentage": metric(0, unit: "%", status: "available"),
            "movementBoutCount": count(0, status: "available"),
            "movementBoutsPerEligibleHour": metric(0, unit: "per h", status: "available"),
            "immobilityBoutCompleteCount": count(1, status: "available"),
            "immobilityBoutCensoredCount": count(0, status: "available"),
            "longestObservedImmobilitySeconds": metric(300, unit: "s", status: "available"),
            "medianCompleteImmobilityBoutSeconds": metric(300, unit: "s", status: "available"),
            "p90CompleteImmobilityBoutSeconds": metric(300, unit: "s", status: "available"),
            "thresholdG": 0.01, "sourceResolution": "gravity_1hz_adjacent",
            "algorithmVersion": "nara-sleep-analytics-1",
        ]
        let thermal: [String: Any] = [
            "quality": quality,
            "nightMedianC": metric(32.5, unit: "°C", status: "available"),
            "nightIqrC": metric(0.6, unit: "°C", status: "available"),
            "nightP95MinusP05C": metric(1.1, unit: "°C", status: "available"),
            "preOnsetSlopeCPerHour": NSNull(), "postWakeSlopeCPerHour": NSNull(),
            "equilibrationExcludedMinutes": 0, "rewearEventVerified": false,
            "conversionIdentity": "whoop5",
        ]
        let prv: [String: Any] = [
            "quality": quality,
            "nightlySd1Ms": metric(18.5, unit: "ms", status: "available"),
            "nightlySd2Ms": metric(42.1, unit: "ms", status: "available"),
            "nightlyRatio": metric(0.44, unit: "", status: "available"),
            "eligibleWindowCount": count(0, status: "available"),
            "withheldWindowCount": count(1, status: "available"),
            "rejectionFraction": metric(0.0, unit: "", status: "available"),
            "validPairs": count(0, status: "available"),
            "timingMethod": "rr_seq_ord", "source": "prv_optical", "windows": [],
        ]
        return [
            "schemaVersion": 1, "algorithmVersion": "nara-sleep-analytics-1",
            "configVersion": "v1", "scope": "main_night",
            "timezone": "America/Los_Angeles",
            "startAt": "2026-09-15T23:00:00Z", "endAt": "2026-09-16T07:00:00Z",
            "start": start, "end": end,
            "fragments": [["id": "sleep-d-\(start)", "sourceKind": "native_whoop_v2",
                           "startAt": "2026-09-15T23:00:00Z", "endAt": "2026-09-16T07:00:00Z",
                           "edited": false, "editRevision": NSNull(), "start": start, "end": end]],
            "fingerprint": fingerprint,
            "stageSourceVersion": "frwhoop-server-1",
            "nativeEpochResolutionSeconds": 30,
            "inputRevision": 7,
            "continuity": continuity, "stageDynamics": stageDynamics,
            "movement": movement, "thermal": thermal, "prvDiagnostics": prv,
        ]
    }
}
