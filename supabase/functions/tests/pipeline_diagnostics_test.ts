import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// G7 diagnostics surface (schema_version 2): verifies the extended
// server_pipeline_diagnostics fields — day bounds/zone, stream coverage +
// largest gap, scoring_jobs_v2 queue age, projection revision,
// durable-vs-verified archive, and explicit blockers — against a throwaway
// PostgreSQL on a Unix socket (no TCP, no production database ever touched).
//
// The local harness applies the base chain; this test additionally applies the
// physiology/diagnostics migrations in order, then seeds one owner's fixture
// and calls the RPC as service_role, exactly as the edge route does.

const OWNER = USER_A;
const OTHER = USER_B;
const SOURCE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const DEVICE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const ALGO = 'frwhoop-physiology-2';
const DAY = '2026-09-15';
const REVISION = 'f'.repeat(40);

// Migrations the extended diagnostics surface needs on top of the harness base.
const EXTRA_MIGRATIONS = [
  '20260918010000_physiology_revisions.sql',
  '20260918020000_physiology_publication.sql',
  '20260918030000_physiology_hrv_dependencies.sql',
  '20260918040000_rr_packet_provenance.sql',
  '20260918050000_physiology_calendar_ownership.sql',
  '20260918100000_physiology_independent_work.sql',
  '20260918110000_device_ownership_invariant.sql',
  '20260919020000_physiology_worker_heartbeats.sql',
  '20260919210000_enrolled_device_scores.sql',
  '20260921101000_server_pipeline_diagnostics.sql',
  '20261003220000_server_pipeline_diagnostics_extended.sql',
];

Deno.test('extended server_pipeline_diagnostics reports the G7 fields honestly', {
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const db = await startLocalPostgres({ installationLifecycle: true });
  try {
    const sql = db.sql;
    for (const name of EXTRA_MIGRATIONS) {
      const text = await Deno.readTextFile(new URL(`../../migrations/${name}`, import.meta.url));
      await sql(text);
    }
    // PostgREST started before the extra migrations were applied; reload its schema
    // cache so the extended RPC is visible to the REST client.
    await sql(`select pg_notify('pgrst', 'reload schema');`);
    await new Promise((resolve) => setTimeout(resolve, 300));

    // Owner fixture: profile timezone history, device, enrollment, algorithm
    // qualifications, one published result, one verified archive row, a pending
    // v2 job, signal windows with a real gap, and a live worker heartbeat.
    await sql(`insert into public.scoring_timezone_history
        (user_id,effective_at,timezone_id,provenance)
        values ('${OWNER}','-infinity','America/Los_Angeles','initial_profile')
        on conflict (user_id,effective_at) do update set timezone_id=excluded.timezone_id;`);
    await sql(`insert into public.devices(id,user_id,source_kind,external_device_id,is_active)
        values ('${DEVICE}','${OWNER}','noop_push','my-whoop',true);`);
    await sql(`insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','${OWNER}',
          '${'e'.repeat(64)}', now() + interval '1 day');`);
    await sql(`insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values ('${SOURCE}','${OWNER}','cccccccc-cccc-4ccc-8ccc-cccccccccccc','ios','1.0.0');`);
    // physiology_algorithm_versions / feature_defaults / feature_qualifications are
    // already seeded by 20260918020000 (frwhoop-server-1 baseline for all features).
    // The v2 queue algorithm is enabled-but-not-active, so the eligible gate counts it.
    await sql(`insert into public.scoring_algorithms_v2(algorithm_version,enabled,active)
        values ('${ALGO}',true,false);`);

    // Published results through the real path: scoring_capture_measurement_revision
    // requires a physiology_work_items row whose input_revision matches. Advance the
    // work item between inserts so rev 1 then rev 2 both carry measurement_revision.
    // Rev 2 is the durable-accepted head whose payload carries the coverage scoring
    // saw; rev 1 is durable but was never archived.
    await sql(`insert into public.physiology_work_items
        (user_id,device_id,day,dirty_at,input_revision,failure_revision,consecutive_failures,next_attempt_at,status,timezone_id,measurement_revision)
        values ('${OWNER}','${DEVICE}','${DAY}', now() - interval '3 hours', 1, 1, 0, now(), 'pending', 'America/Los_Angeles', 1);`);
    await sql(`insert into public.server_physiology_results
        (user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
        values ('${OWNER}','${DEVICE}','${DAY}','frwhoop-server-1',1,
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          '${'c'.repeat(64)}',
          '{"coverage":{"hr":{"received":50000}},"daily":{"status":"available"}}'::jsonb,
          '${'b'.repeat(64)}', now() - interval '2 hours','final');`);
    await sql(`update public.physiology_work_items
        set input_revision=2, measurement_revision=2, dirty_at=now() - interval '5 minutes', next_attempt_at=now()
        where user_id='${OWNER}' and device_id='${DEVICE}' and day='${DAY}';`);
    await sql(`insert into public.server_physiology_results
        (user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
        values ('${OWNER}','${DEVICE}','${DAY}','frwhoop-server-1',2,
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          '${'c'.repeat(64)}',
          '{"coverage":{"hr":{"received":86000},"rr":{"received":76000}},"daily":{"status":"available"},"timezone":"America/Los_Angeles"}'::jsonb,
          '${'b'.repeat(64)}', now() - interval '10 minutes','final');`);

    // Verified archive outbox row for that result (verified archival).
    await sql(`insert into public.physiology_archive_outbox
        (user_id,device_id,period_day,algorithm_version,input_revision,object_key,status,attempts,content_sha256,uploaded_at,verified_at)
        values ('${OWNER}','${DEVICE}','${DAY}','frwhoop-server-1',2,'diag/object-2.ndjson','verified',1,
          '${'a'.repeat(64)}', now() - interval '9 minutes', now() - interval '8 minutes');`);
    // One failed outbox row to exercise the archive_failed blocker.
    await sql(`insert into public.physiology_archive_outbox
        (user_id,device_id,period_day,algorithm_version,input_revision,object_key,status,attempts,next_attempt_at)
        values ('${OWNER}','${DEVICE}','${DAY}','frwhoop-server-1',1,'diag/object-1.ndjson','failed',8,
          now() + interval '60 seconds');`);

    // Signal windows: two hr windows with a 120 s gap between them, inside the day.
    // Inserting them fires invalidate_scoring_stream_v2, which auto-enqueues a v2 job
    // per ENABLED algorithm for the day (real pipeline behavior) — the settle block
    // below then pins the v2 jobs to a deterministic state.
    await sql(`insert into public.object_manifests
        (id,user_id,device_id,source_id,object_class,object_kind,object_key,period_day,format,status,created_at)
        values ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','${OWNER}','${DEVICE}','${SOURCE}','raw','hr',
          'diag/hr-1.ndjson','${DAY}','ndjson','ready', now() - interval '1 hour'),
               ('ffffffff-ffff-4fff-8fff-ffffffffffff','${OWNER}','${DEVICE}','${SOURCE}','raw','hr',
          'diag/hr-2.ndjson','${DAY}','ndjson','ready', now() - interval '1 hour');`);
    const dayStart = 1789455600; // 2026-09-15T07:00:00Z = America/Los_Angeles midnight (UTC-7)
    await sql(`insert into public.noop_signal_windows
        (user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,received_records,expected_records,coverage,uncompressed_bytes)
        values ('${OWNER}','${DEVICE}','hr',${dayStart},'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','diag/hr-1.ndjson',
          ${dayStart},${dayStart}+3600,3600,3600,1.0,4096),
               ('${OWNER}','${DEVICE}','hr',${dayStart},'ffffffff-ffff-4fff-8fff-ffffffffffff','diag/hr-2.ndjson',
          ${dayStart}+3720,${dayStart}+7320,3600,3600,1.0,4096);`);

    // Settle the v2 jobs the window insert enqueued: pin the v2 lane to a pending
    // job (input 3 > completed 2, dirty 5 min ago, eligible now) and mark the
    // frwhoop-server-1 job complete so exactly one pending row remains.
    await sql(`update public.scoring_jobs_v2 set
        input_revision=3, completed_revision=2,
        dirty_at=now() - interval '5 minutes', not_before=now() - interval '60 seconds',
        last_claimed_at=now() - interval '4 minutes', consecutive_failures=0, dead_letter=false
      where user_id='${OWNER}' and device_id='${DEVICE}' and day='${DAY}' and algorithm_version='${ALGO}';`);
    await sql(`update public.scoring_jobs_v2 set completed_revision=input_revision
      where user_id='${OWNER}' and device_id='${DEVICE}' and day='${DAY}' and algorithm_version='frwhoop-server-1';`);

    // Live worker heartbeat for the selected algorithm.
    await sql(`insert into public.physiology_worker_heartbeats
        (worker_instance_id,process_instance_id,source_revision,algorithm_version,started_at,last_poll_at,last_score_at)
        values ('11111111-2222-4333-8444-555555555555','66666666-7777-4888-8999-000000000000',
          '${REVISION}','frwhoop-server-1', now() - interval '1 hour', now() - interval '10 seconds', now() - interval '12 minutes');`);

    // Cross-owner isolation: OTHER owns a device AND an installation, but has no
    // pipeline data at all. The RPC must (a) reject a mismatched owner/device pair
    // outright, and (b) answer honestly for OTHER with not_measured everywhere.
    await sql(`insert into public.devices(id,user_id,source_kind,external_device_id,is_active)
        values ('99999999-9999-4999-8999-999999999999','${OTHER}','noop_push','other-whoop',true);`);
    await sql(`insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values ('dddddddd-eeee-4eee-8eee-eeeeeeeeeeee','${OTHER}',
          '${'d'.repeat(64)}', now() + interval '1 day');`);
    await sql(`insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','${OTHER}','dddddddd-eeee-4eee-8eee-eeeeeeeeeeee','ios','1.0.0');`);

    const diag = await db.rest.rpc('server_pipeline_diagnostics', {
      p_user: OWNER, p_source: SOURCE, p_device: DEVICE, p_day: DAY,
    });

    // Response is the RPC result object (route returns it verbatim).
    assert.equal(diag.schema_version, 2);
    assert.equal(diag.scope, 'enrolled_owner_source_device_day');

    // G7 privacy contract (mirrors server_pipeline_sql_test for the v2 shape): the surface is
    // owner-scoped by AUTH, never by content — no raw owner/source/device UUID anywhere in
    // the diagnostics JSON (selected_features strips device_id; worker UUIDs are unrelated).
    const encoded = JSON.stringify(diag);
    assert.ok(!encoded.includes(OWNER), 'diagnostics must not leak the owner UUID');
    assert.ok(!encoded.includes(SOURCE), 'diagnostics must not leak the source UUID');
    assert.ok(!encoded.includes(DEVICE), 'diagnostics must not leak the device UUID');

    // Day bounds + zone policy from the canonical scoring_day_segments primitive.
    assert.deepEqual(diag.day_bounds.zone, 'America/Los_Angeles');
    assert.equal(diag.day_bounds.zone_policy, 'local_calendar_midnight');
    assert.equal(diag.day_bounds.bounds_half_open, true);
    assert.ok(Array.isArray(diag.day_bounds.segments));
    assert.ok(diag.day_bounds.segments.length >= 1);
    assert.ok(diag.day_bounds.segments[0].start_ts < diag.day_bounds.segments[0].end_ts);

    // Streams: observed, per-stream windows, snapshot coverage, measured largest gap.
    assert.equal(diag.streams.status, 'observed');
    assert.equal(diag.streams.signal_windows.hr.windows, 2);
    assert.equal(diag.streams.signal_windows.hr.received_records, 7200);
    assert.equal(diag.streams.largest_gap.status, 'measured');
    assert.equal(diag.streams.largest_gap.stream, 'hr');
    assert.equal(diag.streams.largest_gap.seconds, 120);
    assert.equal(diag.streams.coverage['frwhoop-server-1'].hr.received, 86000);

    // Queue age from scoring_jobs_v2: pending + eligible, dirty 300 s ago.
    assert.equal(diag.queue.scoring_v2.status, 'pending');
    assert.equal(diag.queue.scoring_v2.pending, 1);
    assert.equal(diag.queue.scoring_v2.dead_lettered, 0);
    assert.equal(diag.queue.scoring_v2.invalidation_suppressed, 0);
    assert.equal(diag.queue.scoring_v2.eligible, 1);
    assert.equal(diag.queue.scoring_v2.input_revision, 3);
    assert.equal(diag.queue.scoring_v2.completed_revision, 2);
    assert.ok(diag.queue.scoring_v2.oldest_dirty_age_seconds >= 290);
    assert.ok(diag.queue.scoring_v2.oldest_dirty_age_seconds <= 360);
    assert.ok(diag.queue.scoring_v2.oldest_eligible_age_seconds >= 55);

    // Projection revision: published 2 vs required 3 -> behind.
    assert.equal(diag.projection.status, 'behind');
    assert.equal(diag.projection.published_revision, 2);
    assert.equal(diag.projection.required_revision, 3);
    assert.equal(diag.projection.behind, true);

    // Durable acceptance vs verified archival: 2 published revisions, 1 verified,
    // 1 failed (revision 1 was never archived).
    assert.equal(diag.archive.durable_published, 2);
    assert.equal(diag.archive.verified, 1);
    assert.equal(diag.archive.statuses.verified, 1);
    assert.equal(diag.archive.statuses.failed, 1);

    // Blockers: pending v2 job + failed archive; no worker blocker (heartbeat live).
    const blockerCodes = diag.blockers.map((b: any) => b.code);
    assert.ok(blockerCodes.includes('v2_job_pending'));
    assert.ok(blockerCodes.includes('archive_failed'));
    assert.ok(!blockerCodes.includes('worker_unavailable'));

    // Work items list stays intact (legacy surface untouched).
    assert.ok(Array.isArray(diag.work));
    assert.ok(Array.isArray(diag.publications));
    assert.equal(diag.publications[0].input_revision, 2);
    // Owner mismatch: OTHER's source is not paired with OWNER's device -> rejected.
    await assert.rejects(
      () => db.rest.rpc('server_pipeline_diagnostics', {
        p_user: OWNER, p_source: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        p_device: DEVICE, p_day: DAY,
      }),
      /supabase_authority_rejected/,
    );

    // Honest not_measured surface for OTHER: enrolled, no pipeline data.
    const empty = await db.rest.rpc('server_pipeline_diagnostics', {
      p_user: OTHER, p_source: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      p_device: '99999999-9999-4999-8999-999999999999', p_day: DAY,
    });
    assert.equal(empty.schema_version, 2);
    const emptyEncoded = JSON.stringify(empty);
    assert.ok(!emptyEncoded.includes(OTHER), 'empty diagnostics must not leak the owner UUID');
    assert.ok(!emptyEncoded.includes('99999999-9999-4999-8999-999999999999'), 'empty diagnostics must not leak the device UUID');
    assert.equal(empty.streams.status, 'not_observed');
    assert.equal(empty.streams.largest_gap.status, 'not_measured');
    assert.equal(empty.queue.scoring_v2.status, 'none');
    assert.equal(empty.projection.status, 'not_observed');
    assert.equal(empty.archive.durable_published, 0);
    assert.equal(empty.archive.verified, 0);
    assert.equal(empty.stages.acquired.status, 'not_measured');
    assert.equal(empty.stages.durable.status, 'not_measured');
    // Worker heartbeats are global per algorithm (liveness, not owner data), so
    // the seeded frwhoop-server-1 heartbeat keeps OTHER's worker healthy too; the
    // honest point is that OWNER's pipeline state never leaks into OTHER's list.
    assert.ok(Array.isArray(empty.blockers));
    assert.ok(!empty.blockers.some((b: any) => b.code === 'v2_job_pending'));
    assert.ok(!empty.blockers.some((b: any) => b.code === 'archive_failed'));
    // Empty day still reports the canonical day bounds from scoring_day_segments.
    assert.equal(empty.day_bounds.zone, 'UTC');
    assert.ok(Array.isArray(empty.day_bounds.segments));
  } finally {
    await db.close();
  }
});
