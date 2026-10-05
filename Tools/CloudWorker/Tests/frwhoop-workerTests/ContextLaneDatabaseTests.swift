import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The physiology-context lane against a real Postgres (spec V15, V16, V17): stored strap streams → the REAL
/// scoring lane publishes the day's snapshot → `enqueue_physiology_context_days_v1` → the context lane claims,
/// reads, builds and publishes → the stored day, daily values and bouts, read back through
/// `physiology_context_read_v1`.
///
/// Needs a scratch database with every migration applied, `20261005120000_physiology_context.sql` included:
/// set FRWHOOP_TEST_DB_URL (skipped otherwise), for example the harness database
/// `supabase/tests/e2e/pipeline_db.sh up`. Each test creates its own owners and devices and deletes them
/// afterwards (the account cascade removes everything they wrote). The lanes claim whatever is due, so run against
/// a database with no other owners' pending scoring or context work.
final class ContextLaneDatabaseTests: XCTestCase {
    typealias PC = PhysiologyContext

    // MARK: - Fixture

    struct Owner {
        let user: String
        let device: String
    }

    private var db: PostgresClient!
    /// A second connection, as the worker gives each lane its own.
    private var scoringDB: PostgresClient!
    private var owners: [String] = []

    static func connect() throws -> PostgresClient {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the physiology context migration")
        }
        return try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-context-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 120_000, idleTransactionTimeoutMS: 120_000))
    }

    override func setUpWithError() throws {
        db = try Self.connect()
        let present = try db.query(ContextSQL.tablesPresent, []).first?["present"]
        guard present.map(isTrue) == true else {
            throw XCTSkip("apply 20261005120000_physiology_context.sql to the scratch database")
        }
        scoringDB = try Self.connect()
    }

    override func tearDownWithError() throws {
        for user in owners {
            // `sessions` rows first: their delete trigger (`bump_user_revision`) upserts `user_sync_state` for the
            // user, which fails inside the account cascade and would leave the owner (and its queued work) behind.
            try? db?.exec("delete from public.sessions where user_id = '\(user)'")
            do {
                try db?.exec("delete from auth.users where id = '\(user)'")
            } catch {
                XCTFail("fixture owner \(user) was not removed: \(error)")
            }
        }
        owners = []
    }

    private func makeOwner(timezone: String = "UTC", family: String = "WHOOP 5.0 / MG") throws -> Owner {
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        owners.append(user)
        _ = try db.query("""
            insert into public.profiles(id, timezone, date_of_birth, sex_model, height_cm, weight_kg)
            values ($1::uuid, $2, '1990-01-01', 'male', 180, 75)
            on conflict (id) do update set timezone = excluded.timezone, date_of_birth = excluded.date_of_birth,
              sex_model = excluded.sex_model, height_cm = excluded.height_cm, weight_kg = excluded.weight_kg
            """, [user, timezone])
        try addDevice(user: user, device: device, family: family)
        return Owner(user: user, device: device)
    }

    private func addDevice(user: String, device: String, family: String = "WHOOP 5.0 / MG") throws {
        _ = try db.query("""
            insert into public.devices(id, user_id, source_kind, device_family, firmware)
            values ($1::uuid, $2::uuid, 'noop_push', $3, '50.36.1.0')
            """, [device, user, family])
    }

    /// Yesterday (UTC): a closed day, so the queue gives it a retrospective job.
    var dayStart: Int { Int(Date().timeIntervalSince1970) / 86_400 * 86_400 - 86_400 }
    var day: String { ContextInputs.utcDay(dayStart) }

    /// The night before and the morning of `dayStart`: sitting, asleep 23:00–07:00, awake, a walk.
    func morningSim(_ dayStart: Int, seed: UInt64 = 11) -> ContextDaySim {
        var sim = ContextDaySim(seed: seed)
        let h = 3_600
        sim.run(.sit, from: dayStart - 3 * h, to: dayStart - h)
        sim.run(.sleep, from: dayStart - h, to: dayStart + 7 * h)
        sim.run(.sit, from: dayStart + 7 * h, to: dayStart + 8 * h)
        sim.run(.walk, from: dayStart + 8 * h, to: dayStart + 8 * h + 1_200)
        sim.run(.sit, from: dayStart + 8 * h + 1_200, to: dayStart + 10 * h)
        return sim
    }

    private func jsonText(_ rows: [[Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// Store the simulated streams the way ingest does (one batch per call), with `ingested_at` set from each
    /// row's availability.
    func seed(_ o: Owner, _ sim: ContextDaySim, events: [(ts: Int, kind: String)] = []) throws {
        let source = UUID().uuidString.lowercased()
        let ids = [o.user, o.device, source]
        func chunks<T>(_ rows: [T], _ body: ([T]) throws -> Void) rethrows {
            var i = 0
            while i < rows.count { try body(Array(rows[i..<min(rows.count, i + 20_000)])); i += 20_000 }
        }
        try chunks(sim.hr) { part in
            _ = try db.query("""
                insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id,ingested_at)
                select $1::uuid,$2::uuid,$3::uuid,(r->>0)::bigint,(r->>1)::integer,$3::uuid,to_timestamp((r->>2)::bigint)
                from jsonb_array_elements($4::jsonb) r
                """, ids + [try jsonText(part.map { [$0.ts, $0.bpm, $0.at] })])
        }
        try chunks(sim.rr) { part in
            _ = try db.query("""
                insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"srcChannel",batch_id,ingested_at)
                select $1::uuid,$2::uuid,$3::uuid,(r->>0)::bigint,(r->>1)::integer,(r->>2)::integer,(r->>3)::integer,
                       $3::uuid,to_timestamp((r->>4)::bigint)
                from jsonb_array_elements($4::jsonb) r
                on conflict do nothing
                """, ids + [try jsonText(part.map { [$0.ts, $0.rr, $0.seq, $0.ch, $0.at] })])
        }
        try chunks(sim.gravity) { part in
            _ = try db.query("""
                insert into public.noop_gravity_samples(user_id,device_id,source_id,ts,x,y,z,"dynAccel",batch_id,ingested_at)
                select $1::uuid,$2::uuid,$3::uuid,(r->>0)::bigint,(r->>1)::float8,(r->>2)::float8,(r->>3)::float8,
                       (r->>4)::float8,$3::uuid,to_timestamp((r->>5)::bigint)
                from jsonb_array_elements($4::jsonb) r
                """, ids + [try jsonText(part.map { [$0.ts, $0.x, $0.y, $0.z, $0.dyn, $0.at] })])
        }
        try chunks(sim.steps) { part in
            _ = try db.query("""
                insert into public.noop_step_samples(user_id,device_id,source_id,ts,counter,"activityClass",batch_id,ingested_at)
                select $1::uuid,$2::uuid,$3::uuid,(r->>0)::bigint,(r->>1)::integer,(r->>2)::integer,$3::uuid,
                       to_timestamp((r->>3)::bigint)
                from jsonb_array_elements($4::jsonb) r
                """, ids + [try jsonText(part.map { [$0.ts, $0.counter, $0.cls, $0.at] })])
        }
        if !events.isEmpty {
            _ = try db.query("""
                insert into public.noop_events(user_id,device_id,source_id,ts,kind,"payloadJSON",batch_id)
                select $1::uuid,$2::uuid,$3::uuid,(r->>0)::bigint,r->>1,'{}',$3::uuid
                from jsonb_array_elements($4::jsonb) r
                """, ids + [try jsonText(events.map { [$0.ts, $0.kind] })])
        }
    }

    func scoringLane() -> ScoringLane {
        ScoringLane(db: scoringDB, scorer: DayScorer(db: scoringDB), ingestSecret: "context-tests",
                    publishesSeries: true, legacyQuietSeconds: 0, legacyMaxDeferSeconds: 1, v2InputGateSeconds: 0)
    }

    func contextLane() -> ContextLane {
        var lane = ContextLane(db: db, workerName: "context-tests", leaseSeconds: 300, enqueueIntervalSeconds: 0)
        lane.enqueueLimit = 500
        return lane
    }

    /// Score every dirty day of the fixture with the real scoring lane (v2 snapshot + series).
    @discardableResult
    func score(_ o: Owner, maxPasses: Int = 6) throws -> [String: String] {
        _ = try db.query("""
            insert into public.scoring_jobs_v2(user_id, device_id, day, algorithm_version)
            values ($1::uuid, $2::uuid, $3::date, 'frwhoop-server-1')
            on conflict (user_id, device_id, day, algorithm_version) do update
              set input_revision = public.scoring_jobs_v2.input_revision + 1, dirty_at = clock_timestamp(),
                  not_before = clock_timestamp()
            """, [o.user, o.device, day])
        // Test-only: lift the queue's 45 s per-day re-claim cooldown so a re-score runs now.
        _ = try db.query("update public.scoring_jobs_v2 set last_claimed_at = null where user_id = $1::uuid", [o.user])
        var lane = scoringLane()
        for _ in 0..<maxPasses {
            lane.drain(budget: 8)
            let pending = try db.query("""
                select count(*)::text as n from public.scoring_jobs_v2
                where user_id = $1::uuid and completed_revision < input_revision and not dead_letter
                """, [o.user]).first?["n"]
            if pending == "0" { break }
        }
        let snap = try db.query("""
            select result_revision::text as rev, payload->>'status' as status,
                   jsonb_array_length(coalesce(payload->'sleep','[]'::jsonb))::text as sessions
            from public.scoring_snapshots_v2
            where user_id = $1::uuid and device_id = $2::uuid and day = $3::date
            order by result_revision desc limit 1
            """, [o.user, o.device, day]).first ?? [:]
        XCTAssertNotNil(snap["rev"], "the scoring lane published a snapshot; lane error: \(lane.stats.lastError ?? "none")")
        return snap
    }

    func contextDays(_ o: Owner, mode: String = "retrospective") throws -> [[String: String]] {
        try db.query("""
            select context_revision::text as rev, (superseded_by is null)::text as current,
                   input_fingerprint, policy_fingerprint, document_bytes::text as bytes
            from public.physiology_context_days
            where user_id = $1::uuid and device_id = $2::uuid and day = $3::date and mode = $4
            order by context_revision
            """, [o.user, o.device, day, mode])
    }

    /// The stored revision as clients rebuild it: the summary document joined with its envelope tables
    /// (`physiology_context_envelope_tables`, contracts §6.1) when the database has them; the summary alone
    /// otherwise (`tables` false).
    func storedDocument(revision: String) throws -> (doc: PC.DayDocument, tables: Bool) {
        let text = try XCTUnwrap(try db.query(
            "select document::text as doc from public.physiology_context_days where context_revision = $1::bigint",
            [revision]).first?["doc"])
        let summary = try PC.decoder().decode(PC.DayDocument.self, from: Data(text.utf8))
        guard try envelopeTablesInstalled() else { return (summary, false) }
        let tables = try db.query("""
            select envelope_table::text as t from public.physiology_context_envelope_tables
            where context_revision = $1::bigint order by metric
            """, [revision]).map { try PC.decoder().decode(PC.EnvelopeTable.self, from: Data(($0["t"] ?? "").utf8)) }
        return (PC.StoredDocument.join(summary: summary, tables: tables), true)
    }

    func envelopeTablesInstalled() throws -> Bool {
        try db.query("select (to_regclass('public.physiology_context_envelope_tables') is not null)::text as p",
                     []).first?["p"] == "true"
    }

    func job(_ o: Owner, mode: String = "retrospective", day: String? = nil) throws -> [String: String] {
        try db.query("""
            select input_revision::text as rev, completed_revision::text as done,
                   (lease_token is null)::text as free, consecutive_failures::text as failures,
                   dead_letter::text as dead, coalesce(last_error, '') as error,
                   coalesce(last_outcome, '') as outcome, coalesce(cutoff_override::text, '') as cutoff_override
            from public.physiology_context_jobs
            where user_id = $1::uuid and device_id = $2::uuid and day = $3::date and mode = $4
            """, [o.user, o.device, day ?? self.day, mode]).first ?? [:]
    }

    /// Make the day due for the context lane without waiting for the queue's settle time.
    func invalidate(_ o: Owner, reason: String = "test") throws {
        _ = try db.callFunctionForJSON(
            "select public.invalidate_physiology_context_span_v1($1::uuid,$2::uuid,$3::date,$3::date,$4)::text",
            [o.user, o.device, day, reason])
    }

    // MARK: - V17: stored streams → scoring → context → storage → read

    /// HART epochs (v1, published by the activity lane) and a logged workout over the 08:00 walk: the heart-rate
    /// independent evidence an exertion bout is built from.
    func seedWalkEvidence(_ o: Owner) throws {
        let walk = (dayStart + 8 * 3_600, dayStart + 8 * 3_600 + 1_200)
        _ = try db.query("""
            insert into public.activity_context_epochs(user_id, device_id, day, start_ts, end_ts, motion_label,
              confidence, observed_s, valid_s, model_version, preprocessing_version, ontology_version, fingerprint,
              result_revision, computed_at)
            select $1::uuid, $2::uuid, (to_timestamp(t) at time zone 'UTC')::date, t, t + 30,
                   case when t >= $3::bigint and t < $4::bigint then 'walking' else 'stationary' end,
                   0.9, 30, 30, 'hart-test', '1.0.0', 'v1', repeat('a', 64), 1, clock_timestamp()
              from generate_series($3::bigint - 3600, $4::bigint + 3570, 30) t
            """, [o.user, o.device, String(walk.0), String(walk.1)])
        _ = try db.query("""
            insert into public.sessions(user_id, device_id, kind, source, start_at, end_at, summary)
            values ($1::uuid, $2::uuid, 'manual_workout', 'manual', to_timestamp($3::bigint), to_timestamp($4::bigint),
                    '{"type":"walking"}'::jsonb)
            """, [o.user, o.device, String(walk.0), String(walk.1)])
    }

    func testScoredDayBecomesAStoredContextDocumentWithItsProducts() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try seedWalkEvidence(o)
        let snap = try score(o)
        try invalidate(o)
        var lane = contextLane()
        lane.drain(budget: 8)
        XCTAssertEqual(lane.stats.failed, 0, lane.stats.lastError ?? "")
        XCTAssertGreaterThanOrEqual(lane.stats.published, 1, lane.stats.lastError ?? "")

        let days = try contextDays(o)
        XCTAssertEqual(days.filter { $0["current"] == "true" }.count, 1, "\(days)")
        let current = try XCTUnwrap(days.last)
        XCTAssertGreaterThan(Int(current["bytes"] ?? "") ?? 0, 0)
        XCTAssertEqual(current["policy_fingerprint"], PC.Policy.default.fingerprint)
        let j = try job(o)
        XCTAssertEqual(j["done"], j["rev"], "the job completed: \(j)")
        XCTAssertEqual(j["free"], "true")

        // The stored document decodes into the shared type and carries the series and nightly measurements
        // with their supports, paired with the snapshot it read.
        let docText = try XCTUnwrap(try db.query("""
            select document::text as doc, coalesce(scoring_result_revision::text,'') as srev
            from public.physiology_context_days where context_revision = $1::bigint
            """, [current["rev"] ?? "0"]).first)
        XCTAssertEqual(docText["srev"], snap["rev"])
        let summary = try PC.decoder().decode(PC.DayDocument.self, from: Data((docText["doc"] ?? "").utf8))
        XCTAssertTrue(summary.envelopes.isEmpty, "the stored document is the summary (contracts §6.1)")
        let index = try XCTUnwrap(summary.envelopeIndex)
        XCTAssertTrue(Set(index.map(\.metric)).isSuperset(of: [.heartRate, .restingHeartRate, .respiratoryRate]),
                      "\(index)")
        let (doc, joined) = try storedDocument(revision: current["rev"] ?? "0")
        XCTAssertEqual(doc.header.identity.deviceScope, o.device)
        XCTAssertEqual(doc.header.interpretation.mode, .retrospective)
        let methods = Set(doc.envelopes.map(\.method.id))
        if joined {
            XCTAssertEqual(doc.envelopes.count, index.map(\.envelopeCount).reduce(0, +))
            XCTAssertTrue(methods.contains("series.resting_hr.60min_min5"), "\(methods)")
            XCTAssertTrue(methods.contains(PC.Engine.heartRateWindowMethod.id))
            for e in doc.envelopes where e.method.id == "series.resting_hr.60min_min5" {
                XCTAssertLessThanOrEqual(e.support.duration, 3_600)
                XCTAssertEqual(e.displayBucket?.duration, 300)
            }
        } else {
            print("context-v17: physiology_context_envelope_tables is not installed; envelope tables not verified")
        }

        // Normalized products match the document.
        let values = try db.query("""
            select count(*)::text as n from public.physiology_context_daily_values
            where user_id = $1::uuid and device_id = $2::uuid and day = $3::date and mode = 'retrospective'
            """, [o.user, o.device, day]).first?["n"]
        XCTAssertEqual(Int(values ?? ""), doc.dailyValues.count)
        let bouts = try db.query("""
            select count(*)::text as n from public.physiology_context_bouts
            where user_id = $1::uuid and device_id = $2::uuid and mode = 'retrospective'
            """, [o.user, o.device]).first?["n"]
        XCTAssertEqual(Int(bouts ?? ""), doc.bouts.filter { $0.day == day }.count)
        XCTAssertFalse(doc.bouts.isEmpty, "the logged walk with HART epochs is a bout")
        XCTAssertGreaterThan(Int(values ?? "") ?? 0, 0)
        // A stored bout decodes back into the shared type.
        if let boutText = try db.query("""
            select payload::text as p from public.physiology_context_bouts
            where user_id = $1::uuid and device_id = $2::uuid and mode = 'retrospective' limit 1
            """, [o.user, o.device]).first?["p"] {
            let bout = try PC.decoder().decode(PC.ExertionBout.self, from: Data(boutText.utf8))
            XCTAssertEqual(bout.day, day)
        }

        let eligible = doc.envelopes.filter { $0.eligibility.contains { $0.state == .eligible } }.count
        print("context-v17: envelopes=\(index.map(\.envelopeCount).reduce(0, +)) joined=\(joined) eligible_envelopes=\(eligible) "
              + "daily_values=\(doc.dailyValues.count) bouts=\(doc.bouts.count) episodes=\(doc.episodes.count) "
              + "sleep_episodes=\(doc.sleep.episodes.count) status=\(doc.status.rawValue) "
              + "methods=\(methods.sorted().joined(separator: ","))")

        // The read surface returns the document, paired with the current snapshot.
        let readText = try XCTUnwrap(try db.callFunctionForJSON(
            "select public.physiology_context_read_v1($1::uuid,$2::uuid,$3::date,NULL,NULL)::text",
            [o.user, o.device, day]))
        let read = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(readText.utf8)) as? [String: Any])
        XCTAssertEqual(read["status"] as? String, "available", readText.prefix(400).description)
        XCTAssertEqual((read["pairing"] as? [String: Any])?["consistent"] as? Bool, true)
    }

    // MARK: - V15: retries, restarts, corrections

    func testRetryingTheSameInputsStoresNoNewRevision() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try score(o)
        try invalidate(o)
        var lane = contextLane()
        // The queue also creates the neighbouring days' jobs (D-1 … today); drain them all.
        lane.drain(budget: 8)
        XCTAssertGreaterThanOrEqual(lane.stats.published, 1, lane.stats.lastError ?? "")
        let first = try contextDays(o)
        XCTAssertEqual(first.count, 1, "\(first)")
        let publishedBefore = lane.stats.published

        try invalidate(o, reason: "retry")
        lane.drain(budget: 8)
        XCTAssertEqual(lane.stats.unchanged, 1, "same fingerprints → unchanged; \(lane.stats.lastError ?? "")")
        XCTAssertEqual(lane.stats.published, publishedBefore)
        XCTAssertEqual(try contextDays(o), first, "no duplicate revision")
        let j = try job(o)
        XCTAssertEqual(j["done"], j["rev"])
        XCTAssertEqual(j["outcome"], "unchanged")
    }

    func testAWorkerThatDiesMidJobIsReplacedByOneThatPublishesOnce() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try score(o)
        try invalidate(o)
        // Worker A claims and dies before publishing.
        let dead = contextLane()
        let row = try XCTUnwrap(try dead.claimRow())
        let deadJob = try XCTUnwrap(ContextInputs.parseJob(row))
        XCTAssertEqual(deadJob.userId, o.user)
        // While the lease is live nobody else gets the job.
        var other = contextLane()
        XCTAssertNil(try other.claimRow())
        // The lease runs out.
        _ = try db.query("update public.physiology_context_jobs set lease_until = clock_timestamp() - interval '1 second' where lease_token = $1::uuid",
                         [deadJob.leaseToken])
        other.drain(budget: 8)
        XCTAssertGreaterThanOrEqual(other.stats.published, 1, other.stats.lastError ?? "")
        let reclaimed = try job(o)
        XCTAssertEqual(reclaimed["done"], reclaimed["rev"], "\(reclaimed)")
        // Worker A comes back. Its lease is gone: the first renew says so and nothing is read or written…
        var zombie = contextLane()
        XCTAssertThrowsError(try zombie.process(deadJob)) { error in
            XCTAssertEqual((error as? PostgresClient.Error)?.kind, .stale)
        }
        // …and a publish it had already built is fenced by the RPC.
        let w = try XCTUnwrap(ContextInputs.windows(day: deadJob.day, timezoneId: deadJob.timezoneId))
        let loaded = try ContextInputs.load(db: db, job: deadJob, windows: w)
        let a = ContextInputs.assemble(loaded, job: deadJob, windows: w)
        let built = try ContextLane.publishPayload(document: PC.Engine.buildDay(a.input, history: a.history),
                                                   snapshot: loaded.snapshot)
        let outcome = try zombie.publish(deadJob, payload: built.payloadText)
        XCTAssertEqual(outcome, .fenced(reason: "lease_lost"))
        let days = try contextDays(o)
        XCTAssertEqual(days.count, 1, "\(days)")
        XCTAssertEqual(days.first?["current"], "true")
    }

    func testAnExposureCorrectionRevisesTheDay() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try score(o)
        try invalidate(o)
        var lane = contextLane()
        lane.drain(budget: 8)
        let before = try XCTUnwrap(try contextDays(o).last)

        // A caffeine intake at 08:30 entered late, then corrected.
        let source = UUID().uuidString.lowercased()
        let event: [String: Any] = [
            "event_id": "caffeine-\(o.user.prefix(8))", "revision": 1, "kind": "caffeine", "label": "coffee",
            "occurred": ["start": dayStart + 8 * 3_600 + 1_800, "end": dayStart + 8 * 3_600 + 1_801],
            "time_precision": "exact", "recorded_at": dayStart + 20 * 3_600, "source": "user_entered",
            "confirmation": "confirmed", "dose_amount": 95, "dose_unit": "mg", "dose_provenance": "user_entered",
        ]
        let saved = try recordExposure(o, source: source, event: event)
        XCTAssertEqual(saved["status"] as? String, "saved", "\(saved)")
        let dirty = try job(o)
        XCTAssertNotEqual(dirty["done"], dirty["rev"], "the correction dirtied the day: \(dirty)")
        lane.drain(budget: 8)
        let after = try contextDays(o)
        XCTAssertEqual(after.filter { $0["current"] == "true" }.count, 1)
        let current = try XCTUnwrap(after.last)
        XCTAssertGreaterThan(Int(current["rev"] ?? "") ?? 0, Int(before["rev"] ?? "") ?? 0)
        XCTAssertNotEqual(current["input_fingerprint"], before["input_fingerprint"])

        var corrected = event
        corrected["revision"] = 2
        corrected["dose_amount"] = 190
        XCTAssertEqual(try recordExposure(o, source: source, event: corrected)["status"] as? String, "saved")
        lane.drain(budget: 8)
        let third = try XCTUnwrap(try contextDays(o).last)
        XCTAssertGreaterThan(Int(third["rev"] ?? "") ?? 0, Int(current["rev"] ?? "") ?? 0)
    }

    func recordExposure(_ o: Owner, source: String, event: [String: Any]) throws -> [String: Any] {
        let text = try XCTUnwrap(try db.callFunctionForJSON(
            "select public.record_exposure_event_v1($1::uuid,$2::uuid,$3::jsonb)::text",
            [o.user, source, String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)]))
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - V10: a causal replay at a fixed cutoff ignores what arrived later

    func testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try score(o)
        let cutoff = dayStart + 9 * 3_600
        // An operator replay: the day decided live as of 09:00 (cutoff_override), not as of the claim.
        func replay() throws {
            _ = try db.query("""
                insert into public.physiology_context_jobs (user_id, device_id, day, mode, cutoff_override, reasons)
                values ($1::uuid, $2::uuid, $3::date, 'causal_live', $4::bigint, array['replay'])
                on conflict (user_id, device_id, day, mode) do update set
                  input_revision = public.physiology_context_jobs.input_revision + 1, cutoff_override = excluded.cutoff_override,
                  dirty_at = clock_timestamp(), not_before = clock_timestamp(), reasons = array['replay']
                """, [o.user, o.device, day, String(cutoff)])
        }
        try replay()
        var lane = contextLane()
        lane.enqueueIntervalSeconds = 3_600
        lane.lastEnqueueAt = Date()  // only the replay job is due
        lane.drain(budget: 2)
        XCTAssertEqual(lane.stats.published, 1, lane.stats.lastError ?? "")
        let first = try XCTUnwrap(try contextDays(o, mode: "causal_live").last)
        let stored = try XCTUnwrap(try db.query("""
            select availability_cutoff::text as cutoff, generated_at::text as generated,
                   coalesce(scoring_result_revision::text, '') as srev
            from public.physiology_context_days where context_revision = $1::bigint
            """, [first["rev"] ?? "0"]).first)
        XCTAssertEqual(stored["cutoff"], String(cutoff))
        XCTAssertGreaterThan(Int(stored["generated"] ?? "") ?? 0, cutoff, "generatedAt is the claim time")
        XCTAssertEqual(stored["srev"], "", "the snapshot was published after the cutoff and is not read")
        XCTAssertEqual(try job(o, mode: "causal_live")["cutoff_override"], "", "cleared by the publish")

        // Late arrivals with earlier sensor times: extra beats, a wear event, an exposure entered now.
        let source = UUID().uuidString.lowercased()
        _ = try db.query("""
            insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"srcChannel",batch_id)
            select $1::uuid,$2::uuid,$3::uuid,t,700,9,5,$3::uuid from generate_series($4::bigint,$4::bigint+300) t
            """, [o.user, o.device, source, String(dayStart + 8 * 3_600)])
        _ = try db.query("""
            insert into public.noop_events(user_id,device_id,source_id,ts,kind,"payloadJSON",batch_id)
            values ($1::uuid,$2::uuid,$3::uuid,$4::bigint,'WRIST_OFF','{}',$3::uuid)
            """, [o.user, o.device, source, String(dayStart + 8 * 3_600 + 60)])
        let event: [String: Any] = [
            "event_id": "late-\(o.user.prefix(8))", "revision": 1, "kind": "caffeine", "label": "coffee",
            "occurred": ["start": dayStart + 7 * 3_600, "end": dayStart + 7 * 3_600 + 1], "time_precision": "exact",
            "recorded_at": dayStart + 7 * 3_600 + 10, "source": "user_entered", "confirmation": "confirmed"]
        _ = try recordExposure(o, source: source, event: event)

        try replay()
        lane.drain(budget: 4)
        XCTAssertEqual(lane.stats.unchanged, 1, "same cutoff, same visible inputs: \(lane.stats.lastError ?? "")")
        let after = try contextDays(o, mode: "causal_live")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.last?["input_fingerprint"], first["input_fingerprint"])
    }

    // MARK: - V16: owners, devices, failure isolation

    func testOwnersAndDevicesNeverSeeEachOthersData() throws {
        let a = try makeOwner()
        let b = try makeOwner()
        let a2 = Owner(user: a.user, device: UUID().uuidString.lowercased())
        try addDevice(user: a.user, device: a2.device)
        try seed(a, morningSim(dayStart, seed: 1))
        try score(a)
        for o in [a, a2, b] { try invalidate(o) }
        var lane = contextLane()
        lane.drain(budget: 8)
        XCTAssertEqual(lane.stats.failed, 0, lane.stats.lastError ?? "")

        func document(_ o: Owner) throws -> PC.DayDocument? {
            guard let rev = try db.query("""
                select context_revision::text as rev from public.physiology_context_days
                where user_id = $1::uuid and device_id = $2::uuid and day = $3::date and superseded_by is null
                """, [o.user, o.device, day]).first?["rev"] else { return nil }
            return try storedDocument(revision: rev).doc
        }
        func envelopeCount(_ d: PC.DayDocument) -> Int {
            d.envelopes.isEmpty ? (d.envelopeIndex ?? []).map(\.envelopeCount).reduce(0, +) : d.envelopes.count
        }
        let docA = try XCTUnwrap(try document(a))
        XCTAssertGreaterThan(envelopeCount(docA), 0)
        for other in [a2, b] {
            guard let doc = try document(other) else { continue }
            XCTAssertEqual(doc.header.identity.deviceScope, other.device)
            XCTAssertEqual(envelopeCount(doc), 0, "no other device's or owner's observations leak in")
            XCTAssertNotEqual(doc.header.inputFingerprint, docA.header.inputFingerprint)
        }
        if try envelopeTablesInstalled() {
            let foreignTables = try db.query("""
                select count(*)::text as n from public.physiology_context_envelope_tables t
                join public.physiology_context_days d on d.context_revision = t.context_revision
                where t.user_id <> d.user_id or t.device_id <> d.device_id
                """, []).first?["n"]
            XCTAssertEqual(foreignTables, "0")
        }
        // Every stored product row belongs to the owner and device it was computed for.
        let foreign = try db.query("""
            select count(*)::text as n from public.physiology_context_daily_values v
            where v.user_id = $1::uuid and v.device_id <> all ($2::uuid[])
            """, [a.user, "{\(a.device),\(a2.device)}"]).first?["n"]
        XCTAssertEqual(foreign, "0")
    }

    func testAFailingContextLaneDoesNotStopScoring() throws {
        let o = try makeOwner()
        try seed(o, morningSim(dayStart))
        try score(o)
        // Break context publication for this owner only.
        try db.exec("""
            create or replace function public.pc_worker_test_reject() returns trigger language plpgsql as $$
            begin raise exception 'pc_worker_test_reject'; end $$
            """)
        try db.exec("""
            create trigger pc_worker_test_reject before insert on public.physiology_context_days
            for each row when (new.user_id = '\(o.user)'::uuid) execute function public.pc_worker_test_reject()
            """)
        defer {
            try? db.exec("drop trigger if exists pc_worker_test_reject on public.physiology_context_days")
            try? db.exec("drop function if exists public.pc_worker_test_reject()")
        }
        try invalidate(o)
        var lane = contextLane()
        lane.drain(budget: 8)
        XCTAssertGreaterThanOrEqual(lane.stats.failed, 1)
        XCTAssertGreaterThanOrEqual(lane.stats.failuresPersisted, 1)
        let failedJob = try job(o)
        XCTAssertEqual(failedJob["failures"], "1", "\(failedJob)")
        XCTAssertFalse((failedJob["error"] ?? "").contains("\n"))

        // New data arrives; scoring publishes a fresh snapshot regardless.
        let before = try db.query("select count(*)::text as n from public.scoring_snapshots_v2 where user_id = $1::uuid",
                                  [o.user]).first?["n"]
        var more = ContextDaySim(seed: 99)
        more.run(.sit, from: dayStart + 10 * 3_600, to: dayStart + 11 * 3_600)
        try seed(o, more)
        try score(o)
        let after = try db.query("select count(*)::text as n from public.scoring_snapshots_v2 where user_id = $1::uuid",
                                 [o.user]).first?["n"]
        XCTAssertGreaterThan(Int(after ?? "") ?? 0, Int(before ?? "") ?? 0)
    }

    // MARK: - Profile against the scoring lane (opt-in: FRWHOOP_CONTEXT_PROFILE=1)

    func testProfileAFullDayAgainstTheScoringLane() throws {
        guard ProcessInfo.processInfo.environment["FRWHOOP_CONTEXT_PROFILE"] == "1" else {
            throw XCTSkip("set FRWHOOP_CONTEXT_PROFILE=1 to profile the lanes on a full stored day")
        }
        let o = try makeOwner()
        // The evening before, then a whole day: 86,400 s of heart rate and gravity on the day itself.
        var sim = ContextDaySim(seed: 21)
        sim.run(.sit, from: dayStart - 6 * 3_600, to: dayStart - 3_600)
        sim.run(.sleep, from: dayStart - 3_600, to: dayStart)
        let day = ContextDaySim.representativeDay(dayStart: dayStart, seed: 21)
        var merged = sim
        merged.append(day)
        let seedStarted = Date()
        try seed(o, merged)
        let seedS = Date().timeIntervalSince(seedStarted)
        let scoringStarted = Date()
        try score(o)
        let scoringWallMS = Int(Date().timeIntervalSince(scoringStarted) * 1000)
        let scoringJob = try db.query("""
            select coalesce(last_duration_ms::text, '') as ms from public.scoring_jobs_v2
            where user_id = $1::uuid and device_id = $2::uuid and day = $3::date
            """, [o.user, o.device, self.day]).first?["ms"] ?? ""
        try invalidate(o)
        var lane = contextLane()
        lane.enqueueIntervalSeconds = 3_600
        lane.lastEnqueueAt = Date()
        let contextStarted = Date()
        lane.drain(budget: 1)
        let contextWallMS = Int(Date().timeIntervalSince(contextStarted) * 1000)
        XCTAssertEqual(lane.stats.published, 1, lane.stats.lastError ?? "")
        let stored = try XCTUnwrap(try contextDays(o).last)
        print("context-profile-db: rows_hr=\(merged.hr.count) rows_rr=\(merged.rr.count) rows_gravity=\(merged.gravity.count) "
              + "seed_s=\(Int(seedS)) scoring_wall_ms_all_dirty_days=\(scoringWallMS) scoring_day_compute_ms=\(scoringJob) "
              + "context_wall_ms=\(contextWallMS) context_load_ms=\(lane.stats.loadMsMax) "
              + "context_build_ms=\(lane.stats.buildMsMax) context_rows=\(lane.stats.inputsRowsMax) "
              + "context_measurements=\(lane.stats.measurementsMax) summary_bytes=\(lane.stats.summaryBytesMax) "
              + "table_bytes=\(lane.stats.tableBytesMax) doc_bytes_encoded=\(lane.stats.docBytesMax) "
              + "doc_bytes_stored=\(stored["bytes"] ?? "")")
    }

    func testTheLaneIdlesWhenTheTablesAreMissing() throws {
        // A database without the migration: the lane must idle and say so, never throw or claim.
        try db.exec("select 1")
        let exists = try db.query("select 1 from pg_database where datname = 'pc_worker_no_context'", []).first
        if exists == nil { try db.exec("create database pc_worker_no_context") }
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"],
              let range = url.range(of: "/", options: .backwards) else { throw XCTSkip("no url") }
        let other = String(url[..<range.lowerBound]) + "/pc_worker_no_context"
        let empty = try PostgresClient(options: PostgresOptions(
            connectionString: other, sslMode: "disable", sslRootCert: nil, applicationName: "context-tests",
            allowInsecure: true, connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 10_000, idleTransactionTimeoutMS: 10_000))
        var lane = ContextLane(db: empty)
        lane.drain(budget: 2)
        lane.drain(budget: 2)
        XCTAssertEqual(lane.tablesPresent, false)
        XCTAssertGreaterThanOrEqual(lane.stats.tablesMissing, 2)
        XCTAssertEqual(lane.stats.claimed, 0)
        XCTAssertEqual(lane.stats.lastErrorKind, "context_tables_missing")
    }
}
