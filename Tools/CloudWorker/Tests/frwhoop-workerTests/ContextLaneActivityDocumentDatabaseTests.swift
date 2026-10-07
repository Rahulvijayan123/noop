import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The lane's activity reads against a real Postgres (D3-02, D5-04, D5-07): one epoch revision per UTC day, the
/// ranked decoder document per UTC day, and transition events from that same document. Needs FRWHOOP_TEST_DB_URL
/// (skipped otherwise), e.g. `supabase/tests/e2e/pipeline_db.sh up`. Each test makes its own owner and deletes it.
final class ContextLaneActivityDocumentDatabaseTests: XCTestCase {
    typealias PC = PhysiologyContext

    private var db: PostgresClient!
    private var owners: [String] = []
    // 2026-10-03T00:00:00Z
    let dayStart = 1_790_985_600
    let day = "2026-10-03"

    override func setUpWithError() throws {
        db = try ContextLaneDatabaseTests.connect()
    }

    override func tearDownWithError() throws {
        for user in owners { try? db?.exec("delete from auth.users where id = '\(user)'") }
        owners = []
    }

    private func owner() throws -> (user: String, device: String) {
        let user = UUID().uuidString.lowercased(), device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        owners.append(user)
        _ = try db.query("""
            insert into public.devices(id, user_id, source_kind, device_family, firmware)
            values ($1::uuid, $2::uuid, 'noop_push', 'WHOOP 5.0 / MG', '50.36.1.0')
            """, [device, user])
        return (user, device)
    }

    /// One published epoch lineage of the day: 30-s stationary epochs over `[from, to)` (seconds after midnight).
    private func publishEpochs(_ o: (user: String, device: String), from: Int, to: Int, revision: Int,
                               fingerprint: Character, computedAt: Int, wearSignal: String? = nil) throws {
        _ = try db.query("""
            insert into public.activity_context_epochs(user_id, device_id, day, start_ts, end_ts, motion_label,
              wear_signal, confidence, observed_s, valid_s, model_version, preprocessing_version, ontology_version,
              fingerprint, result_revision, computed_at)
            select $1::uuid, $2::uuid, $3::date, t, t + 30, 'stationary', nullif($8, ''), 0.9, 30, 30,
                   'hart-' || $7, '1.0.0', 'v1', repeat($7, 64), $6::bigint, to_timestamp($9::bigint)
              from generate_series($4::bigint, $5::bigint - 30, 30) t
            """, [o.user, o.device, day, String(dayStart + from), String(dayStart + to), String(revision),
                  String(fingerprint), wearSignal ?? "", String(computedAt)])
    }

    private func publishDocument(_ o: (user: String, device: String), algorithm: String, decoder: String,
                                 dataThrough: Int?, revision: Int, computedAt: Int, runClass: String,
                                 eventKind: String) throws {
        let doc = """
            {"runs":[{"s":\(dayStart + 3600),"e":\(dayStart + 7200),"activity_class":"\(runClass)",\
            "class_confidence":0.7,"overall_confidence":0.6,"sleep":"awake","wear":"on_wrist","in_bed":true}],\
            "events":[{"ts":\(dayStart + 5000),"kind":"\(eventKind)","probability":0.66}]}
            """
        _ = try db.query("""
            insert into public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version,
              ontology_version, decoder_version, feature_schema, model_version, preprocessing_version, job_fingerprint,
              input_revision, publish_interval_s, observed_s, data_through, run_count, event_count, unclear_s,
              mean_confidence, document, result_revision, computed_at)
            values ($1::uuid, $2::uuid, $3::date, $4, 2, 'v2.0', $5, 'imu-feat-2', 'm', '1.0.0', repeat('b', 64), 1,
                    300, 3600, nullif($6, '')::bigint, 1, 1, 0, 0.6, $7::jsonb, $8::bigint, to_timestamp($9::bigint))
            """, [o.user, o.device, day, algorithm, decoder, dataThrough.map(String.init) ?? "", doc, String(revision),
                  String(computedAt)])
    }

    private func read(_ sql: String, _ o: (user: String, device: String), _ extra: [String]) throws -> [[String: String]] {
        try db.query(sql, [o.user, o.device, String(dayStart - 3600), String(dayStart + 86_400 + 3600)] + extra)
    }

    func testEpochsComeFromTheNewestRevisionOfTheDayOnlyAndCausallyFromTheNewestByTheCutoff() throws {
        let o = try owner()
        // Lineage A (older) covers 0-100 min; lineage B (newer fingerprint) covers only 0-50 min.
        try publishEpochs(o, from: 0, to: 6000, revision: 10, fingerprint: "a", computedAt: dayStart + 7000)
        try publishEpochs(o, from: 0, to: 3000, revision: 20, fingerprint: "c", computedAt: dayStart + 9000,
                          wearSignal: "on_wrist_loose")
        let params = [day, day]
        let retro = try read(ContextSQL.activityEpochs, o, params + [""]).compactMap(ContextInputs.parseEpoch)
        XCTAssertEqual(Set(retro.map(\.revision)), [20], "only the newest lineage of the day")
        XCTAssertEqual(retro.count, 100)
        XCTAssertFalse(retro.contains { $0.epoch.startTs >= dayStart + 3000 }, "no stale fill from lineage A")
        XCTAssertEqual(retro.first?.epoch.wearSignal, .onWristLoose)
        XCTAssertEqual(retro.first?.provenance, "hart-c@1.0.0")
        // A causal replay whose cutoff precedes B reads A, the newest published by then.
        let causal = try read(ContextSQL.activityEpochs, o, params + [String(dayStart + 8000)])
            .compactMap(ContextInputs.parseEpoch)
        XCTAssertEqual(Set(causal.map(\.revision)), [10])
        XCTAssertEqual(causal.count, 200)
        XCTAssertNil(causal.first?.epoch.wearSignal)
    }

    func testRunsAndEventsComeFromTheRankedDocumentOfTheDay() throws {
        let o = try owner()
        let current = ActivityContextVersions.decoder
        // The HART document is older and from an older decoder; the stream document is current.
        try publishDocument(o, algorithm: "hart-activity-1", decoder: "hsmm-1.1", dataThrough: dayStart + 80_000,
                            revision: 10, computedAt: dayStart + 80_100, runClass: "standing",
                            eventKind: "walk_start")
        try publishDocument(o, algorithm: "streams-activity-1", decoder: current, dataThrough: dayStart + 70_000,
                            revision: 20, computedAt: dayStart + 70_100, runClass: "sitting",
                            eventKind: "sit_to_stand_like")
        let params = [day, day, current]
        let runs = try read(ContextSQL.activityRuns, o, params + [""]).compactMap(ContextInputs.parseRun)
        XCTAssertEqual(runs.map(\.activityClass), ["sitting"], "the current decoder wins over raw-IMU source rank")
        XCTAssertEqual(runs.first?.provenance, "streams-activity-1/\(current)")
        XCTAssertEqual(runs.first?.inBed, true)
        XCTAssertEqual(runs.first?.confidence ?? 0, 0.7, accuracy: 1e-6)
        let events = try read(ContextSQL.activityTransitions, o, params + [""]).compactMap(ContextInputs.parseTransition)
        XCTAssertEqual(events.map(\.kind), ["sit_to_stand_like"], "events from the same document as the runs")
        XCTAssertEqual(events.first?.probability ?? 0, 0.66, accuracy: 1e-6)
        XCTAssertEqual(events.first?.revision, 20)
        // With both on the current decoder, the later data_through wins, then raw-IMU before streams.
        try db.exec("update public.activity_context_days set decoder_version = '\(current)' where user_id = '\(o.user)'")
        XCTAssertEqual(try read(ContextSQL.activityRuns, o, params + [""]).compactMap(ContextInputs.parseRun)
                        .map(\.activityClass), ["standing"])
        try db.exec("update public.activity_context_days set data_through = null where user_id = '\(o.user)'")
        XCTAssertEqual(try read(ContextSQL.activityRuns, o, params + [""]).compactMap(ContextInputs.parseRun)
                        .map(\.activityClass), ["standing"], "source rank decides between equals")
        // A causal job ranks only documents computed by its cutoff.
        XCTAssertEqual(try read(ContextSQL.activityRuns, o, params + [String(dayStart + 75_000)])
                        .compactMap(ContextInputs.parseRun).map(\.activityClass), ["sitting"])
        XCTAssertTrue(try read(ContextSQL.activityTransitions, o, params + [String(dayStart + 1_000)]).isEmpty)
    }
}
