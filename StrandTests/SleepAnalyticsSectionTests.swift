import XCTest
import StrandAnalytics
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

// SleepAnalyticsSectionTests.swift — app-side tests for the Phase-1 sleep analytics document
// (`daily.sleep_analytics_v1`, docs/sleep-analytics/spec.md §8 app steps 1–5):
//
//   • HostedDayResult decode: new snapshot with all groups decodes; old snapshot (no key) -> nil,
//     day intact; malformed / future schema (schema_version 99) / corrupt leaf -> nil or tolerant
//     subset, day always intact; offline relaunch preserves the document through the disk cache;
//     owner switch never serves another owner's cached document.
//   • Staleness guard: matching night -> shown; bounds mismatch / edited night / id mismatch /
//     fragment-count mismatch / empty night -> withheld.
//   • Display state matrix: available / partial / unavailable-with-reason / disabled (PRV) /
//     zero-event (count 0 with qualifying exposure renders 0, never null) — via the pure
//     state-decision + formatting helpers (spec §12 "partial/unavailable/zero-event states render
//     differently"; SwiftUI view testing is not established in StrandTests, so the pure functions
//     are what get pinned).
//
// Wire keys follow the SHARED `SleepAnalyticsDocument` synthesized Codable (camelCase property
// names) — the exact format a JSONEncoder over that struct emits, so a rename on either side is a
// failing test, not a silent nil day.
final class SleepAnalyticsSectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-sleep-analytics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixture

    /// A representative document with every group present (all durations in seconds on the wire).
    static func fullDocumentJSON() -> [String: Any] {
        let quality: [String: Any] = [
            "status": "available",
            "fragment_span_seconds": 28_800, "group_span_seconds": 28_800,
            "observed_labeled_seconds": 27_000, "unknown_seconds": 0,
            "inferred_gap_awake_seconds": 600, "input_supported_seconds": 27_800,
            "input_supported_fraction": 0.965, "label_supported_fraction": 0.94,
            "source_resolution_seconds": 30,
            "stream_counts": ["hr_seconds": 28_800, "gravity_seconds": 27_900],
        ]
        func metric(_ value: Double?, _ unit: String, _ status: String, _ reason: String? = nil) -> [String: Any] {
            var m: [String: Any] = ["unit": unit, "status": status]
            if let value { m["value"] = value }
            if let reason { m["reason"] = reason }
            return m
        }
        func count(_ value: Int?, _ status: String, _ reason: String? = nil) -> [String: Any] {
            var m: [String: Any] = ["unit": "count", "status": status]
            if let value { m["value"] = value }
            if let reason { m["reason"] = reason }
            return m
        }
        let stageSeconds = { (label: String, seconds: Double) -> [String: Any] in
            ["label": label, "seconds": metric(seconds, "s", "available")]
        }
        let stageBouts = { (label: String, bouts: Int, complete: Int, censored: Int,
                            longest: Double, median: Double, p90: Double) -> [String: Any] in
            ["label": label,
             "bout_count": count(bouts, "available"),
             "complete_bout_count": count(complete, "available"),
             "censored_bout_count": count(censored, "available"),
             "longest_observed_seconds": metric(longest, "s", "available"),
             "median_complete_bout_seconds": metric(median, "s", "available"),
             "p90_complete_bout_seconds": metric(p90, "s", "available")]
        }
        let slope = { (value: Double, start: Int, end: Int, valid: Int, eligible: Int) -> [String: Any] in
            ["value": metric(value, "c_per_h", "available"),
             "window_start": start, "window_end": end,
             "valid_minutes": valid, "eligible_minutes": eligible,
             "coverage": Double(valid) / Double(eligible), "longest_missing_run_seconds": 120]
        }
        let qualityStart = 1_762_383_600
        let qualityEnd = qualityStart + 28_800
        let fragments: [[String: Any]] = [
            ["id": "sleep-my-whoop-\(qualityStart)",
             "source_kind": "native_whoop_v2",
             "start_at": "2025-11-05T23:00:00Z", "end_at": "2025-11-06T07:00:00Z",
             "edited": false, "start": qualityStart, "end": qualityEnd],
        ]
        let continuity: [String: Any] = [
            "quality": quality,
            "observed_asleep_seconds": metric(25_200, "s", "available"),
            "observed_waso_seconds": metric(1_800, "s", "available"),
            "inferred_gap_awake_seconds_within_sleep_period": metric(600, "s", "available"),
            "estimated_waso_including_inferred_gaps_seconds": metric(2_400, "s", "available"),
            "onset_delay_from_window_seconds": metric(300, "s", "available"),
            "sleep_onset_latency_from_marker_seconds": metric(nil, "s", "unavailable", "missing_marker"),
            "rem_latency_from_sleep_onset_seconds": metric(4_800, "s", "available"),
            "deep_latency_from_sleep_onset_seconds": metric(1_200, "s", "available"),
            "longest_observed_sleep_bout_seconds": metric(7_200, "s", "available"),
            "longest_bout_censored": false,
            "awakening_bout_count": count(3, "available"),
            "censored_wake_stretch_count": count(1, "available"),
            "sleep_to_wake_transition_count": count(5, "available"),
            "sleep_to_wake_transitions_per_asleep_hour": metric(0.7, "per_h", "available"),
        ]
        let stageDynamics: [String: Any] = [
            "quality": quality,
            "stage_seconds": [
                stageSeconds("light", 12_000), stageSeconds("deep", 6_000),
                stageSeconds("rem", 4_800), stageSeconds("wake", 1_800),
            ],
            "stage_bouts": [
                stageBouts("light", 8, 6, 2, 3_600, 1_500, 2_100),
                stageBouts("deep", 4, 4, 0, 2_400, 1_500, 1_800),
                stageBouts("rem", 5, 4, 1, 1_800, 900, 1_200),
                stageBouts("wake", 3, 3, 0, 1_200, 600, 900),
            ],
            "epoch_transitions": [
                "counts": [[120, 8, 4, 2], [10, 300, 40, 5], [6, 60, 180, 20], [3, 5, 30, 90]],
                "row_exposure": [134, 355, 266, 128],
                "row_probabilities": [
                    [0.895, 0.06, 0.03, 0.015],
                    [0.028, 0.845, 0.113, 0.014],
                    [0.023, 0.226, 0.677, 0.075],
                    [0.023, 0.039, 0.234, 0.703],
                ],
                "epoch_seconds": 30,
                "eligible_pair_count": count(883, "available"),
                "stage_change_count": count(116, "available"),
            ],
        ]
        let movement: [String: Any] = [
            "quality": quality,
            "movement_seconds": metric(1_200, "s", "available"),
            "eligible_seconds": metric(26_000, "s", "available"),
            "movement_percentage": metric(4.6, "%", "available"),
            "movement_bout_count": count(18, "available"),
            "movement_bouts_per_eligible_hour": metric(2.5, "per_h", "available"),
            "immobility_bout_complete_count": count(12, "available"),
            "immobility_bout_censored_count": count(2, "available"),
            "longest_observed_immobility_seconds": metric(5_400, "s", "available"),
            "median_complete_immobility_bout_seconds": metric(2_400, "s", "available"),
            "p90_complete_immobility_bout_seconds": metric(3_600, "s", "available"),
            "threshold_g": 0.01,
            "source_resolution": "gravity_1hz_adjacent",
            "algorithm_version": "nara-sleep-analytics-1",
        ]
        let thermal: [String: Any] = [
            "quality": quality,
            "night_median_c": metric(30.4, "c", "available"),
            "night_iqr_c": metric(0.6, "c", "available"),
            "night_p95_minus_p05_c": metric(1.2, "c", "available"),
            "pre_onset_slope_c_per_hour": slope(-0.3, qualityStart - 3_600, qualityStart, 48, 60),
            "post_wake_slope_c_per_hour": slope(0.4, qualityEnd, qualityEnd + 1_800, 24, 30),
            "equilibration_excluded_minutes": 5,
            "rewear_event_verified": false,
            "conversion_identity": "whoop5:anchor",
        ]
        let prv: [String: Any] = [
            "quality": quality,
            "nightly_sd1_ms": metric(41.2, "ms", "available"),
            "nightly_sd2_ms": metric(88.5, "ms", "available"),
            "nightly_ratio": metric(0.47, "", "available"),
            "eligible_window_count": count(16, "available"),
            "withheld_window_count": count(4, "available"),
            "rejection_fraction": metric(0.02, "", "available"),
            "valid_pairs": count(9_600, "available"),
            "timing_method": "rr_seq_ord",
            "source": "prv_optical",
            "windows": [
                ["start": qualityStart, "sd1_ms": 40.1, "sd2_ms": 86.2, "pairs": 610, "coverage": 0.97],
                ["start": qualityStart + 300, "sd1_ms": 42.3, "sd2_ms": 90.8, "pairs": 590, "coverage": 0.95],
            ],
        ]
        return [
            "schema_version": 1,
            "algorithm_version": "nara-sleep-analytics-1",
            "config_version": "v1",
            "scope": "main_night",
            "timezone": "Etc/UTC",
            "start_at": "2025-11-05T23:00:00Z", "end_at": "2025-11-06T07:00:00Z",
            "start": qualityStart, "end": qualityEnd,
            "fragments": fragments,
            "fingerprint": "0" + String(repeating: "a", count: 63),
            "stage_source_version": "sleep-stager-v2-test",
            "native_epoch_resolution_seconds": 30,
            "input_revision": 7,
            "continuity": continuity,
            "stage_dynamics": stageDynamics,
            "movement": movement,
            "thermal": thermal,
            "prv_diagnostics": prv,
        ]
    }

    static func decode(_ json: [String: Any]) -> SleepAnalyticsDocument? {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
    }

    static func document(mutating body: (inout [String: Any]) -> Void) -> SleepAnalyticsDocument? {
        var json = fullDocumentJSON()
        body(&json)
        return decode(json)
    }

    /// One stored session of the fixture night (canonical start 1762383600, end 1762412400).
    static func currentSession(edited: Bool = false, deviceId: String? = "my-whoop",
                               startTs: Int = 1_762_383_600,
                               startTsAdjusted: Int? = nil,
                               endTs: Int = 1_762_412_400) -> CachedSleepSession {
        CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: 0.9, restingHr: 52,
                           avgHrv: 61.2, stagesJSON: nil, userEdited: edited,
                           startTsAdjusted: startTsAdjusted, stagingSparse: false, deviceId: deviceId)
    }

    // MARK: - HostedDayResult decode (spec §8 app step 1)

    func testPayloadWithDocumentDecodesAllGroupsOnHostedResult() throws {
        let raw = try XCTUnwrap(Self.fullDocumentJSON() as NSDictionary)
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_analytics_v1": raw, "sleep_total_min": 414, "sleep_efficiency": 0.91],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2025-11-06", object: object)
        let doc = try XCTUnwrap(result?.sleepAnalytics)
        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(doc.algorithmVersion, "nara-sleep-analytics-1")
        XCTAssertEqual(doc.scope, "main_night")
        XCTAssertEqual(doc.start, 1_762_383_600)
        XCTAssertEqual(doc.end, 1_762_412_400)
        XCTAssertEqual(doc.fragments.first?.id, "sleep-my-whoop-1762383600")
        XCTAssertEqual(doc.fragments.first?.edited, false)
        // continuity
        XCTAssertEqual(doc.continuity.observedWasoSeconds.value ?? -1, 1_800, accuracy: 0.01)
        XCTAssertEqual(doc.continuity.inferredGapAwakeSecondsWithinSleepPeriod.value ?? -1, 600, accuracy: 0.01)
        XCTAssertEqual(doc.continuity.estimatedWasoIncludingInferredGapsSeconds.value ?? -1, 2_400, accuracy: 0.01)
        XCTAssertEqual(doc.continuity.awakeningBoutCount.value ?? -1, 3)
        XCTAssertEqual(doc.continuity.remLatencyFromSleepOnsetSeconds.value ?? -1, 4_800, accuracy: 0.01)
        // stage dynamics
        XCTAssertEqual(doc.stageDynamics.stageSeconds.count, 4)
        XCTAssertEqual(doc.stageDynamics.stageBouts.count, 4)
        XCTAssertEqual(doc.stageDynamics.epochTransitions?.eligiblePairCount.value ?? -1, 883)
        XCTAssertEqual(doc.stageDynamics.epochTransitions?.stageChangeCount.value ?? -1, 116)
        // movement / thermal / PRV
        XCTAssertEqual(doc.movement.movementPercentage.value ?? -1, 4.6, accuracy: 0.01)
        XCTAssertEqual(doc.thermal.nightP95MinusP05C.value ?? -1, 1.2, accuracy: 0.01)
        XCTAssertEqual(doc.thermal.preOnsetSlopeCPerHour?.value.value ?? -1, -0.3, accuracy: 0.01)
        XCTAssertEqual(doc.prvDiagnostics.nightlySd1Ms.value ?? -1, 41.2, accuracy: 0.01)
        XCTAssertEqual(doc.prvDiagnostics.eligibleWindowCount.value ?? -1, 16)
        // the rest of the day survives
        XCTAssertEqual(result?.resultRevision, "sha256:abc")
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 414)
    }

    func testPayloadWithoutSleepAnalyticsYieldsNilAndDayIntact() {
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_total_min": 414, "sleep_efficiency": 0.91],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2025-11-06", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepAnalytics)
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 414)
        XCTAssertEqual(result?.resultRevision, "sha256:abc")
    }

    func testPayloadWithMalformedSleepAnalyticsYieldsNilAndDayIntact() {
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_analytics_v1": "not-an-object", "sleep_total_min": 400],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2025-11-06", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepAnalytics)
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 400)
    }

    func testFutureSchemaVersionYieldsNilAndDayIntact() {
        // Mutate the RAW fixture dict (a decoded document is not a JSON object; the wire
        // payload is rebuilt from the mutated dict, not from a re-encoded model).
        var json = Self.fullDocumentJSON()
        json["schema_version"] = 99
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_analytics_v1": json, "sleep_total_min": 400],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2025-11-06", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepAnalytics, "an unsupported schema version must decode to nil")
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 400)
    }

    func testCorruptLeafNeverFailsTheDay() {
        // A required leaf with the wrong type makes the whole document decode to nil, day intact.
        var bad = Self.fullDocumentJSON()
        bad["stage_source_version"] = 42
        var object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_analytics_v1": bad, "sleep_total_min": 400],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2025-11-06", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepAnalytics)
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 400)

        // A tolerant leaf (a metric's value) degrades to unavailable WITHOUT losing the document.
        var json = Self.fullDocumentJSON()
        var continuity = json["continuity"] as! [String: Any]
        var waso = continuity["observed_waso_seconds"] as! [String: Any]
        waso["value"] = "not-a-number"
        continuity["observed_waso_seconds"] = waso
        json["continuity"] = continuity
        let doc = try! XCTUnwrap(Self.decode(json))
        // The tolerant leaf decode keeps the wrapper (status stays "available") but drops the
        // corrupt value; the display layer treats a value-less wrapper as Unavailable.
        XCTAssertEqual(doc.continuity.observedWasoSeconds.status, .available)
        XCTAssertNil(doc.continuity.observedWasoSeconds.value)
    }

    func testOfflineRelaunchPreservesDocumentThroughDiskCache() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let repo = ServerScoreRepository(session: ScoreStub.session(),
                                         endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                         directory: directory,
                                         identity: { CloudPushIdentity(ownerId: owner, sourceId: "22222222-2222-4222-8222-222222222222",
                                                                       tokenId: "t", uploadToken: "noop_x") })
        let body: [String: Any] = ["server_scoring": [
            "schema_version": 2, "day": "2025-11-06", "algorithm_version": "per_feature",
            "hosted_snapshot": [
                "result_revision": "sha256:abc",
                "daily": ["sleep_analytics_v1": Self.fullDocumentJSON(), "sleep_total_min": 414],
                "sleep": [],
            ],
        ]]
        ScoreStub.response = body
        ScoreStub.status = 200

        let fetched = try await repo.refresh(day: "2025-11-06", deviceId: "my-whoop")
        XCTAssertEqual(fetched.hostedResult?.sleepAnalytics?.schemaVersion, 1)

        // Offline relaunch: the cache stores the verbatim daily payload and a cached read re-parses
        // through `snapshot()`, exactly like `cachedDay` — so the document survives with no network.
        let readBack = await repo.cachedDay(day: "2025-11-06", deviceId: "my-whoop")
        let cached = try XCTUnwrap(readBack?.hostedResult?.sleepAnalytics)
        XCTAssertEqual(cached.continuity.awakeningBoutCount.value, 3)
        XCTAssertEqual(cached.movement.movementPercentage.value ?? -1, 4.6, accuracy: 0.01)
    }

    func testOwnerSwitchIsolationNeverServesAnotherOwnersDocument() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let other = "33333333-3333-4333-8333-333333333333"
        let repo = ServerScoreRepository(session: ScoreStub.session(),
                                         endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                         directory: directory,
                                         identity: { CloudPushIdentity(ownerId: owner, sourceId: "22222222-2222-4222-8222-222222222222",
                                                                       tokenId: "t", uploadToken: "noop_x") })
        let body: [String: Any] = ["server_scoring": [
            "schema_version": 2, "day": "2025-11-06",
            "hosted_snapshot": [
                "result_revision": "sha256:abc",
                "daily": ["sleep_analytics_v1": Self.fullDocumentJSON()],
                "sleep": [],
            ],
        ]]
        ScoreStub.response = body
        ScoreStub.status = 200
        _ = try await repo.refresh(day: "2025-11-06", deviceId: "my-whoop")

        let otherRepo = ServerScoreRepository(session: ScoreStub.session(),
                                              endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                              directory: directory,
                                              identity: { CloudPushIdentity(ownerId: other, sourceId: "44444444-4444-4444-8444-444444444444",
                                                                            tokenId: "t", uploadToken: "noop_y") })
        let foreign = await otherRepo.cachedDay(day: "2025-11-06", deviceId: "my-whoop")
        XCTAssertNil(foreign?.hostedResult?.sleepAnalytics,
                     "another owner's cached document must never be served")
        let stillThere = await repo.cachedDay(day: "2025-11-06", deviceId: "my-whoop")
        XCTAssertNotNil(stillThere?.hostedResult?.sleepAnalytics, "the original owner's cache survives")
    }

    // MARK: - Staleness guard (spec §8 app step 5)

    func testMatchingNightIsCurrentAndShown() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        let sessions = [Self.currentSession()]
        XCTAssertTrue(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: sessions))
        XCTAssertEqual(SleepAnalyticsStaleness.currentFragments(from: sessions).count, 1)
    }

    func testBoundsMismatchIsWithheld() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        // The night's effective end moved (an edit, a recompute, a different result revision).
        let sessions = [Self.currentSession(endTs: 1_762_413_000)]
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: sessions))
    }

    func testEditedNightIsWithheld() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        // The user edited the night after the document was computed.
        let sessions = [Self.currentSession(edited: true)]
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: sessions))
    }

    func testDocumentClaimsEditThatCurrentNightDoesNotIsWithheld() throws {
        var json = Self.fullDocumentJSON()
        var fragments = json["fragments"] as! [[String: Any]]
        fragments[0]["edited"] = true
        json["fragments"] = fragments
        let doc = try XCTUnwrap(Self.decode(json))
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: [Self.currentSession(edited: false)]))
    }

    func testIdMismatchIsWithheld() throws {
        var json = Self.fullDocumentJSON()
        var fragments = json["fragments"] as! [[String: Any]]
        fragments[0]["id"] = "sleep-my-whoop-999999999"
        json["fragments"] = fragments
        let doc = try XCTUnwrap(Self.decode(json))
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: [Self.currentSession()]))
    }

    func testAnotherDevicesFragmentIsWithheld() throws {
        var json = Self.fullDocumentJSON()
        var fragments = json["fragments"] as! [[String: Any]]
        fragments[0]["id"] = "sleep-other-device-1762383600"
        json["fragments"] = fragments
        let doc = try XCTUnwrap(Self.decode(json))
        // Same start-key suffix, but the device segment does not match the current session's.
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: [Self.currentSession(deviceId: "my-whoop")]))
    }

    func testFragmentCountMismatchIsWithheld() throws {
        var json = Self.fullDocumentJSON()
        var fragments = json["fragments"] as! [[String: Any]]
        fragments.append(fragments[0])
        json["fragments"] = fragments
        let doc = try XCTUnwrap(Self.decode(json))
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: [Self.currentSession()]))
    }

    func testEmptyCurrentNightIsWithheld() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: []))
    }

    func testEditedEffectiveBoundsChangeIsWithheld() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        // A startTsAdjusted edit moves effectiveStartTs while the canonical start key stays.
        let sessions = [Self.currentSession(edited: true, startTsAdjusted: 1_762_383_300)]
        XCTAssertFalse(SleepAnalyticsStaleness.isCurrent(document: doc, sessions: sessions))
    }

    // MARK: - Display state matrix (spec §8 app step 4)

    func testAvailableRowsShowValuesAndGapExplanation() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])

        let waso = try XCTUnwrap(model.rows.first { $0.id == "waso" })
        XCTAssertEqual(waso.value, "30 min")
        XCTAssertTrue(waso.caption?.contains("incl. 10 min inferred from a split-night gap") == true)
        XCTAssertTrue(waso.caption?.contains("est. total 40 min") == true)

        let stretch = try XCTUnwrap(model.rows.first { $0.id == "longestStretch" })
        XCTAssertEqual(stretch.value, "2 h 00 m")

        let awakenings = try XCTUnwrap(model.rows.first { $0.id == "awakenings" })
        XCTAssertEqual(awakenings.value, "3")
        XCTAssertTrue(awakenings.caption?.contains("complete awakenings") == true)

        let rem = try XCTUnwrap(model.rows.first { $0.id == "remLatency" })
        XCTAssertEqual(rem.value, "1 h 20 m")
        XCTAssertTrue(rem.caption?.contains("estimated") == true)

        let movement = try XCTUnwrap(model.rows.first { $0.id == "movement" })
        XCTAssertEqual(movement.value, "5% · 18 bouts")

        let temp = try XCTUnwrap(model.rows.first { $0.id == "tempSpread" })
        XCTAssertEqual(temp.value, "1.2 °C")
    }

    func testPartialRendersObservedPartialMarker() throws {
        var json = Self.fullDocumentJSON()
        var continuity = json["continuity"] as! [String: Any]
        var waso = continuity["observed_waso_seconds"] as! [String: Any]
        waso["status"] = "partial"
        continuity["observed_waso_seconds"] = waso
        json["continuity"] = continuity
        let doc = try XCTUnwrap(Self.decode(json))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])
        let wasoRow = try XCTUnwrap(model.rows.first { $0.id == "waso" })
        XCTAssertTrue(wasoRow.caption?.contains("Observed/partial") == true)
    }

    func testUnavailableRendersReasonAndCoverageNeverZero() throws {
        var json = Self.fullDocumentJSON()
        var continuity = json["continuity"] as! [String: Any]
        continuity["rem_latency_from_sleep_onset_seconds"] = ["unit": "s", "status": "unavailable", "reason": "no_observed_rem"]
        json["continuity"] = continuity
        let doc = try XCTUnwrap(Self.decode(json))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])
        let rem = try XCTUnwrap(model.rows.first { $0.id == "remLatency" })
        XCTAssertEqual(rem.value, "Unavailable")
        XCTAssertNotNil(rem.caption)
        XCTAssertTrue(rem.caption?.contains("no REM observed") == true)
        XCTAssertFalse(rem.value.contains("0"), "a null metric never renders as a fabricated 0")
    }

    func testZeroEventCountRendersZeroNotNull() throws {
        var json = Self.fullDocumentJSON()
        var continuity = json["continuity"] as! [String: Any]
        continuity["awakening_bout_count"] = ["unit": "count", "status": "available", "value": 0]
        json["continuity"] = continuity
        let doc = try XCTUnwrap(Self.decode(json))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])
        let awakenings = try XCTUnwrap(model.rows.first { $0.id == "awakenings" })
        XCTAssertEqual(awakenings.value, "0", "a genuine zero with qualifying exposure renders 0, never null")
    }

    func testDisabledPrvRendersDisabledWording() throws {
        var json = Self.fullDocumentJSON()
        var prv = json["prv_diagnostics"] as! [String: Any]
        var quality = prv["quality"] as! [String: Any]
        quality["status"] = "disabled"
        prv["quality"] = quality
        json["prv_diagnostics"] = prv
        let doc = try XCTUnwrap(Self.decode(json))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])
        let prvDetail = try XCTUnwrap(model.details.first { $0.id == "prv" })
        XCTAssertTrue(prvDetail.summary.contains("Disabled"))
        XCTAssertTrue(prvDetail.summary.contains("pulse diagnostics are off"))
    }

    func testCoverageDetailHasOneLinePerGroup() throws {
        let doc = try XCTUnwrap(Self.decode(Self.fullDocumentJSON()))
        let model = SleepAnalyticsDisplayModel(document: doc, sessions: [Self.currentSession()])
        let coverage = try XCTUnwrap(model.details.first { $0.id == "coverage" })
        XCTAssertEqual(coverage.rows.count, 5)
        XCTAssertTrue(coverage.rows.contains { $0.label == "Continuity" && $0.value.contains("label-supported") })
    }

    // MARK: - Wording + formatting helpers

    func testEveryMachineReasonHasSensibleWording() {
        let words = SleepAnalyticsReason.allCases.map { SleepAnalyticsWording.reason($0) }
        XCTAssertEqual(words.count, SleepAnalyticsReason.allCases.count)
        for word in words {
            XCTAssertFalse(word.isEmpty)
            XCTAssertFalse(word.contains("nil") || word.contains("null"), "wording must be human, not a raw value: \(word)")
        }
    }

    func testMinutesFormatting() {
        XCTAssertEqual(SleepAnalyticsFormat.minutes(nil), SleepAnalyticsFormat.unavailable)
        XCTAssertEqual(SleepAnalyticsFormat.minutes(1_800), "30 min")
        XCTAssertEqual(SleepAnalyticsFormat.minutes(12_300), "3 h 25 m")
        XCTAssertEqual(SleepAnalyticsFormat.minutes(20), "<1 min")
        XCTAssertEqual(SleepAnalyticsFormat.minutes(45), "1 min")
        XCTAssertEqual(SleepAnalyticsFormat.minutes(2_400), "40 min")
    }

    func testTemperatureFormatting() {
        XCTAssertEqual(SleepAnalyticsFormat.temperature(nil), SleepAnalyticsFormat.unavailable)
        XCTAssertEqual(SleepAnalyticsFormat.temperature(1.2), "+1.2 °C")
        XCTAssertEqual(SleepAnalyticsFormat.temperature(-0.4), "−0.4 °C")
        XCTAssertEqual(SleepAnalyticsFormat.magnitude(1.2), "1.2 °C")
        XCTAssertEqual(SleepAnalyticsFormat.temperaturePerHour(-0.3), "−0.3 °C/h")
    }

    func testPercentFormatting() {
        XCTAssertEqual(SleepAnalyticsFormat.fractionPercent(0.95), "95%")
        XCTAssertEqual(SleepAnalyticsFormat.percentValue(4.6), "5%")
        XCTAssertEqual(SleepAnalyticsFormat.value(41.2, unit: "ms"), "41.2 ms")
    }
}
