import assert from 'node:assert/strict';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// Proves 20261008000000_metric_insights.sql against a throwaway local PostgreSQL + PostgREST built from the
// full migration chain (EDGE_TEST_ARTIFACTS), never a shared database:
//  1. the documented rollback drops everything, the migration applies twice, and its revokes hold even when
//     default privileges hand every new table and function to anon/authenticated, the way Supabase's do;
//  2. catalogue: RLS on both tables, owner-only SELECT on insights, nothing on the queue, service-only EXECUTE,
//     SECURITY DEFINER with an empty search_path, internal helpers unreachable even for service_role;
//  3. the request/claim/publish cycle: nothing measured, pending, ready, cache hits (no new revision; a
//     recompute that only rewrites metadata changes nothing), changed inputs served stale, inputs changing
//     mid-run (published_superseded, keyed by the claim's inputs so it is never served as fresh);
//  4. the fingerprint: the whole selected context document (the retrospective one first), exposures inside the
//     window, coach memory (topic included); another user's data does not move it;
//  5. fencing and failure: lost and expired leases, release on a newer revision, backoff, dead letter and its
//     reset by changed inputs, the daily bound, the 6 h request horizon, payload validation;
//  6. isolation: owners read only their own insights through PostgREST and never the queue or the RPCs; a
//     caller JWT for another user is refused; retired owners are refused and never claimed or published;
//     account deletion cascades; retention keeps the 20 newest superseded analyses;
//  7. the real scores handler on this database: POST /insights for an installation, owner from the credential.

const DEVICE_A = '33333333-3333-4333-8333-333333333333';
const DEVICE_B = '44444444-4444-4444-8444-444444444444';
const USER_C = '55555555-5555-4555-8555-555555555555';
const USER_D = '66666666-6666-4666-8666-666666666666';
const MIGRATION = '20261008000000_metric_insights.sql';
const PUBLIC_FUNCTIONS: Record<string, string> = {
  metric_insight_request_v1: 'uuid,text',
  metric_insight_claim_v1: 'text,integer',
  metric_insight_renew_v1: 'uuid,integer',
  metric_insight_fail_v1: 'uuid,bigint,text',
  metric_insight_publish_v1: 'uuid,bigint,jsonb',
};
const INTERNAL_FUNCTIONS: Record<string, string> = {
  metric_insight_version: '',
  metric_insight_context_document: 'uuid,uuid,date',
  metric_insight_inputs: 'uuid,text',
  metric_insight_json: 'public.metric_insights,boolean',
  metric_insight_is_text_list: 'jsonb,integer,integer',
};
// The migration header's rollback, verbatim in intent: the functions, then the two tables.
const ROLLBACK = `
  ${Object.entries(PUBLIC_FUNCTIONS).map(([name, args]) => `drop function public.${name}(${args});`).join('\n')}
  ${Object.entries(INTERNAL_FUNCTIONS).map(([name, args]) => `drop function internal.${name}(${args});`).join('\n')}
  drop table public.metric_insights;
  drop table public.metric_insight_jobs;`;

function payload(over: Record<string, unknown> = {}, insight: Record<string, unknown> = {}) {
  return {
    kind: 'explained',
    analysis_version: 'metric-insight-1',
    model: 'fixture-model',
    duration_ms: 1234,
    insight: {
      headline: 'Resting heart rate is back near your usual range',
      observed: ['Your resting heart rate was 45 bpm on Oct 6, 3 bpm below your 30-night median of 48 bpm.'],
      interpretation: ['Nights like this are within your usual variation.'],
      uncertainty: ['One night in the last week has no measurement.'],
      related: [{ metric: 'hrv_rmssd', label: 'HRV', summary: '85 ms, above your median', direction: 'up', estimated: false }],
      basis: { nights: 6, from: '2026-09-30', to: '2026-10-06', missing_nights: 1, comparison_status: 'ready' },
      ...insight,
    },
    evidence: { series: { nights: 6 } },
    citations: [{ id: 'pmid:00000001', title: 'Fixture citation', year: 2020, url: 'https://pubmed.ncbi.nlm.nih.gov/00000001/' }],
    ...over,
  };
}

Deno.test('metric insights: schema, privileges, caching, fencing, failure bounds and owner isolation', async (t) => {
  const db = await startLocalPostgres({ fullChain: true });
  const apply = async () => {
    const path = new URL(`../../migrations/${MIGRATION}`, import.meta.url);
    const result = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
        '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!result.success) throw new Error(`apply failed: ${new TextDecoder().decode(result.stderr).slice(-2000)}`);
  };
  const json = async (statement: string) => JSON.parse((await db.sql(statement)) || 'null');
  const rpc = (name: string, args: Record<string, unknown>) => db.rest.rpc(name, args);
  const request = (user: string, metric = 'resting_hr') =>
    rpc('metric_insight_request_v1', { p_user: user, p_metric: metric });
  const claim = async () => {
    const rows = await rpc('metric_insight_claim_v1', { p_worker: 'fixture-worker', p_lease_seconds: 300 });
    assert.ok(Array.isArray(rows) && rows.length <= 1);
    return rows[0] ?? null;
  };
  const publish = (token: string, revision: number, body: unknown = payload()) =>
    rpc('metric_insight_publish_v1', { p_token: token, p_revision: revision, p_payload: body });
  const fail = (token: string, revision: number, error = 'fixture failure') =>
    rpc('metric_insight_fail_v1', { p_token: token, p_revision: revision, p_error: error });
  const renew = (token: string) => rpc('metric_insight_renew_v1', { p_token: token, p_lease_seconds: 300 });
  const job = (user: string, metric = 'resting_hr') => json(
    `select row_to_json(q) from public.metric_insight_jobs q where user_id = '${user}' and metric = '${metric}'`);
  const fingerprint = (user: string, metric = 'resting_hr') =>
    db.sql(`select fingerprint from internal.metric_insight_inputs('${user}', '${metric}')`);
  const count = async (where: string) =>
    Number(await db.sql(`select count(*) from public.metric_insights where ${where}`));
  // Skip the backoff and the daily bound: the next claim may take the job at once.
  const due = () => db.sql(`update public.metric_insight_jobs set not_before = clock_timestamp(), runs_count = 0`);
  const lit = (value: number | null) => value == null ? 'null' : String(value);
  const score = (user: string, day: string, rhr: number | null, hrv: number | null = null, device = DEVICE_A) =>
    db.sql(`insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm, hrv_rmssd_ms)
      values ('${user}', '${day}', 'frwhoop-server-1', '${device}', ${lit(rhr)}, ${lit(hrv)})
      on conflict (user_id, day, algorithm_version) do update
        set resting_hr_bpm = excluded.resting_hr_bpm, hrv_rmssd_ms = excluded.hrv_rmssd_ms`);
  const isRejected = (status: number) => (err: any) => {
    assert.equal(err?.status, status, String(err?.message ?? err));
    return true;
  };
  /** Claim and publish until nothing is due; returns the users served, so a test can assert who never is. */
  const drain = async () => {
    const served: string[] = [];
    for (let lease = await claim(); lease; lease = await claim()) {
      served.push(lease.user_id);
      await publish(lease.lease_token, lease.input_revision);
    }
    return served;
  };

  try {
    await t.step('rollback, re-apply, and the revokes hold under Supabase-style default privileges', async () => {
      await db.sql(ROLLBACK);
      assert.equal(await db.sql(`select count(*) from pg_proc where proname like 'metric_insight%'`), '0');
      assert.equal(await db.sql(`select count(*) from pg_class where relname like 'metric_insight%'`), '0');
      await db.sql(`alter default privileges in schema public grant all on tables to anon, authenticated;
        alter default privileges in schema public grant all on sequences to anon, authenticated;
        alter default privileges in schema public grant execute on functions to anon, authenticated;`);
      await apply();
      await apply();
      await db.sql("notify pgrst, 'reload schema';");
      let reloaded = false;
      for (let attempt = 0; attempt < 100 && !reloaded; attempt++) {
        try { await request(USER_B); reloaded = true; } catch { await new Promise((r) => setTimeout(r, 100)); }
      }
      assert.ok(reloaded, 'PostgREST did not pick up the re-applied functions');
    });

    await t.step('catalogue: RLS, table privileges, policies and function hardening', async () => {
      assert.deepEqual(await json(`select json_object_agg(relname, relrowsecurity order by relname) from pg_class
        where relnamespace = 'public'::regnamespace and relname in ('metric_insight_jobs', 'metric_insights')`),
      { metric_insight_jobs: true, metric_insights: true });
      assert.deepEqual(await json(`select json_build_object(
          'anon_jobs', has_table_privilege('anon', 'public.metric_insight_jobs', 'select,insert,update,delete,truncate'),
          'authenticated_jobs', has_table_privilege('authenticated', 'public.metric_insight_jobs', 'select,insert,update,delete,truncate'),
          'anon_insights', has_table_privilege('anon', 'public.metric_insights', 'select,insert,update,delete,truncate'),
          'authenticated_read', has_table_privilege('authenticated', 'public.metric_insights', 'select'),
          'authenticated_write', has_table_privilege('authenticated', 'public.metric_insights', 'insert,update,delete,truncate'),
          'client_sequence', has_sequence_privilege('authenticated', 'public.metric_insights_id_seq', 'usage,select,update')
            or has_sequence_privilege('anon', 'public.metric_insights_id_seq', 'usage,select,update'),
          'service_jobs', has_table_privilege('service_role', 'public.metric_insight_jobs', 'select,insert,update,delete'),
          'service_insights', has_table_privilege('service_role', 'public.metric_insights', 'select,insert,update,delete'))`),
      { anon_jobs: false, authenticated_jobs: false, anon_insights: false, authenticated_read: true,
        authenticated_write: false, client_sequence: false, service_jobs: true, service_insights: true });
      const policies = await json(`select json_agg(json_build_object('table', tablename, 'name', policyname,
          'roles', roles, 'cmd', cmd, 'qual', qual) order by tablename, policyname)
        from pg_policies where tablename in ('metric_insight_jobs', 'metric_insights')`);
      assert.deepEqual(policies.map((p: any) => [p.table, p.name, p.roles, p.cmd]), [
        ['metric_insight_jobs', 'metric_insight_jobs_service', ['service_role'], 'ALL'],
        ['metric_insights', 'metric_insights_select_own', ['authenticated'], 'SELECT'],
        ['metric_insights', 'metric_insights_service', ['service_role'], 'ALL'],
      ]);
      assert.match(policies[1].qual, /auth\.uid\(\)/);
      for (const [schema, functions] of [['public', PUBLIC_FUNCTIONS], ['internal', INTERNAL_FUNCTIONS]] as const) {
        for (const [name, args] of Object.entries(functions)) {
          const row = await json(`select json_build_object('definer', p.prosecdef, 'config', p.proconfig,
              'public', exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                                 where a.grantee = 0 and a.privilege_type = 'EXECUTE'),
              'anon', has_function_privilege('anon', p.oid, 'execute'),
              'authenticated', has_function_privilege('authenticated', p.oid, 'execute'),
              'service', has_function_privilege('service_role', p.oid, 'execute'))
            from pg_proc p where p.oid = '${schema}.${name}(${args})'::regprocedure`);
          assert.deepEqual(row.config, ['search_path=""'], `${name} search_path`);
          assert.deepEqual([row.public, row.anon, row.authenticated], [false, false, false], `${name} client EXECUTE`);
          if (schema === 'public') {
            assert.equal(row.definer, true, `${name} SECURITY DEFINER`);
            assert.equal(row.service, true, `${name} service EXECUTE`);
          } else {
            assert.equal(row.service, false, `${name} internal helper reachable by service_role`);
          }
        }
      }
      // Both tables go with the account.
      assert.deepEqual(await json(`select json_agg(confdeltype::text order by conrelid::regclass::text) from pg_constraint
        where contype = 'f' and confrelid = 'auth.users'::regclass
          and conrelid in ('public.metric_insight_jobs'::regclass, 'public.metric_insights'::regclass)`), ['c', 'c']);
    });

    await db.sql(`insert into public.profiles(id, timezone) values ('${USER_A}', 'America/Los_Angeles')
        on conflict (id) do update set timezone = excluded.timezone;
      insert into public.devices(id, user_id, source_kind, external_device_id)
        values ('${DEVICE_A}', '${USER_A}', 'noop_push', 'whoop-MIA00001'), ('${DEVICE_B}', '${USER_B}', 'noop_push', 'whoop-MIB00001')`);

    await t.step('nothing measured: unavailable, nothing queued; a NULL day is not a measurement', async () => {
      assert.deepEqual(await request(USER_A), { status: 'unavailable', metric: 'resting_hr', reason: 'no_measured_data', insight: null });
      await score(USER_A, '2026-10-08', null, null);
      assert.deepEqual(await request(USER_A), { status: 'unavailable', metric: 'resting_hr', reason: 'no_measured_data', insight: null });
      assert.equal(await job(USER_A), null);
      await assert.rejects(request(USER_A, 'recovery_score'), isRejected(400));
      await assert.rejects(rpc('metric_insight_request_v1', { p_user: null, p_metric: 'resting_hr' }), isRejected(400));
    });

    const week: Array<[string, number | null, number | null]> = [
      ['2026-09-30', 47, 83.8], ['2026-10-01', 50, 74.1], ['2026-10-02', 51, 66.0], ['2026-10-03', 53, 53.7],
      ['2026-10-04', 51, null], ['2026-10-05', 48, 78.0], ['2026-10-06', 45, 85.4], ['2026-10-07', null, null],
    ];
    for (const [day, rhr, hrv] of week) await score(USER_A, day, rhr, hrv);
    let firstInsight = 0;

    await t.step('first visit queues once; claim, renew, publish; then cache hits', async () => {
      assert.deepEqual(await request(USER_A), { status: 'pending', metric: 'resting_hr', insight: null, retry_after_s: 10 });
      const queued = await job(USER_A);
      assert.deepEqual([queued.input_revision, queued.completed_revision, queued.anchor_day], [1, 0, '2026-10-06']);
      assert.match(queued.fingerprint, /^[0-9a-f]{64}$/);
      assert.equal((await request(USER_A)).status, 'pending');
      assert.equal((await job(USER_A)).input_revision, 1, 'a second visit re-queued the same inputs');

      const lease = await claim();
      assert.deepEqual([lease.user_id, lease.metric, lease.input_revision, lease.anchor_day, lease.fingerprint,
        lease.timezone_id, lease.analysis_version, lease.claim_count],
      [USER_A, 'resting_hr', 1, '2026-10-06', queued.fingerprint, 'America/Los_Angeles', 'metric-insight-1', 1]);
      assert.equal(await claim(), null, 'a held lease was handed out twice');
      assert.equal(await renew(lease.lease_token), true);

      const published = await publish(lease.lease_token, 1);
      assert.deepEqual(published, { applied: true, insight_id: published.insight_id, reason: 'published' });
      firstInsight = published.insight_id;
      const ready = await request(USER_A);
      assert.equal(ready.status, 'ready');
      assert.deepEqual([ready.insight.id, ready.insight.metric, ready.insight.kind, ready.insight.stale,
        ready.insight.data_through, ready.insight.analysis_version, ready.insight.headline],
      [firstInsight, 'resting_hr', 'explained', false, '2026-10-06', 'metric-insight-1', payload().insight.headline]);
      assert.deepEqual(ready.insight.observed, payload().insight.observed);
      assert.deepEqual(ready.insight.citations, payload().citations);
      assert.deepEqual(ready.insight.basis, payload().insight.basis);
      assert.ok(!('evidence' in ready.insight), 'the deterministic evidence is never sent to the app');
      assert.match(ready.insight.generated_at, /^\d{4}-\d{2}-\d{2}T/);

      assert.equal((await request(USER_A)).status, 'ready');
      assert.equal((await job(USER_A)).input_revision, 1, 'a cache hit queued work');
      assert.equal(await claim(), null);
      // A recompute that only rewrites provenance and timestamps leaves the analysis current.
      await db.sql(`update public.server_daily_scores set provenance = '{"run": 2}'::jsonb,
        computed_at = now() + interval '1 minute' where user_id = '${USER_A}'`);
      assert.equal((await request(USER_A)).status, 'ready');
      assert.equal((await job(USER_A)).input_revision, 1);
    });

    await t.step('changed inputs are served stale and re-analysed; a mid-run change publishes as superseded', async () => {
      await score(USER_A, '2026-10-06', 46, 85.4);
      const stale = await request(USER_A);
      assert.deepEqual([stale.status, stale.insight.id, stale.insight.stale, stale.retry_after_s], ['pending', firstInsight, true, 10]);
      assert.equal((await job(USER_A)).input_revision, 2);
      const run = await claim();
      assert.equal(run.input_revision, 2);

      // A new night lands while the run is in flight; the next visit queues it.
      await score(USER_A, '2026-10-07', 44, 90.1);
      assert.equal((await request(USER_A)).status, 'pending');
      const moved = await job(USER_A);
      assert.deepEqual([moved.input_revision, moved.anchor_day], [3, '2026-10-07']);
      assert.notEqual(moved.fingerprint, run.fingerprint);

      const late = await publish(run.lease_token, 2);
      assert.deepEqual([late.applied, late.reason], [true, 'published_superseded']);
      assert.deepEqual(await json(`select json_build_object('fp', input_fingerprint, 'anchor', anchor_day, 'revision', job_revision)
        from public.metric_insights where id = ${late.insight_id}`), { fp: run.fingerprint, anchor: '2026-10-06', revision: 2 });
      const after = await request(USER_A);
      assert.deepEqual([after.status, after.insight.id, after.insight.stale], ['pending', late.insight_id, true],
        'an analysis of older inputs was served as fresh');
      assert.equal((await job(USER_A)).completed_revision, 1);

      const next = await claim();
      assert.deepEqual([next.input_revision, next.anchor_day], [3, '2026-10-07']);
      assert.equal((await publish(next.lease_token, 3)).reason, 'published');
      const fresh = await request(USER_A);
      assert.deepEqual([fresh.status, fresh.insight.stale, fresh.insight.data_through], ['ready', false, '2026-10-07']);
      assert.equal(await count(`user_id = '${USER_A}' and metric = 'resting_hr' and superseded_at is null`), 1);
      assert.equal(await count(`user_id = '${USER_A}' and metric = 'resting_hr'`), 3);
    });

    await t.step('fingerprint: the selected context document, retrospective first, exposures in the window, coach memory', async () => {
      const context = (rhrDifference: number, hrvDifference: number, mode: string, input: string) =>
        db.sql(`insert into public.physiology_context_days(user_id, device_id, day, mode, job_revision, finality, status,
            availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint, input_fingerprint,
            document, document_bytes)
          values ('${USER_A}', '${DEVICE_A}', '2026-10-07', '${mode}', 1, 'provisional', 'available', 1791400000, 1791400000,
            'physiology-context-1', 1, 'fixture-policy', '${input}', $doc$${JSON.stringify({
              comparisons: [
                { series_key: 'resting_hr.sleep_night', reference: 'rolling', status: 'ready', signed_difference: rhrDifference },
                { series_key: 'hrv_rmssd.sleep_night', reference: 'rolling', status: 'ready', signed_difference: hrvDifference },
              ],
              episodes: [{ series_key: 'hrv_rmssd.sleep_night', kind: 'usualVariation' }],
              availability: { resting_hr: 'measured' }, sleep: { timing: { wake: { local_day: '2026-10-07' } } },
              exertion: [{ window_h: 24, bout_count: 1 }], status: 'available', features: { unrelated: 1 },
            })}$doc$::jsonb, 100)`);
      const before = { rhr: await fingerprint(USER_A), hrv: await fingerprint(USER_A, 'hrv_rmssd') };
      await context(-3.1, 4.0, 'causal_live', 'fixture-live');
      const live = { rhr: await fingerprint(USER_A), hrv: await fingerprint(USER_A, 'hrv_rmssd') };
      assert.notEqual(live.rhr, before.rhr, 'the context document is not an input');
      assert.notEqual(live.hrv, before.hrv);
      // Any section the worker reads (bouts, daily values, exposure categories, ...) is input: the whole selected
      // document is hashed, so a republish of any part of it is a new analysis.
      await db.sql(`update public.physiology_context_days set document = jsonb_set(document, '{features,unrelated}', '2')
        where user_id = '${USER_A}' and mode = 'causal_live'`);
      const edited = await fingerprint(USER_A);
      assert.notEqual(edited, live.rhr);
      assert.notEqual(await fingerprint(USER_A, 'hrv_rmssd'), live.hrv);
      // The retrospective document wins over the live one.
      await context(-1.0, 4.0, 'retrospective', 'fixture-retro');
      const retrospective = await fingerprint(USER_A);
      assert.notEqual(retrospective, edited);
      await db.sql(`update public.physiology_context_days set document = jsonb_set(document,
          '{comparisons,0,signed_difference}', '-7.0') where user_id = '${USER_A}' and mode = 'causal_live'`);
      assert.equal(await fingerprint(USER_A), retrospective, 'the live document still counted next to the retrospective one');

      // Exposures: inside [anchor - 14 d, anchor + 1 d) in the owner's zone count; older ones do not.
      const localTs = async (stamp: string) =>
        Number(await db.sql(`select extract(epoch from ('${stamp}'::timestamp at time zone 'America/Los_Angeles'))::bigint`));
      const exposure = async (eventId: string, start: number) => {
        const body = { event_id: eventId, revision: 1, kind: 'caffeine', label: 'Coffee', occurred: { start, end: start + 60 },
          time_precision: 'exact', recorded_at: start + 120, source: 'user_entered', confirmation: 'confirmed',
          dose_amount: 95, dose_unit: 'mg', dose_provenance: 'user_entered' };
        const saved = await json(`select public.record_exposure_event_v1('${USER_A}', null, $ex$${JSON.stringify(body)}$ex$::jsonb)`);
        assert.equal(saved.status, 'saved');
      };
      await exposure('caffeine-old', await localTs('2026-09-01 08:00'));
      assert.equal(await fingerprint(USER_A), retrospective, 'an exposure outside the window moved the fingerprint');
      await exposure('caffeine-recent', await localTs('2026-10-06 08:00'));
      const withExposure = await fingerprint(USER_A);
      assert.notEqual(withExposure, retrospective);

      await db.sql(`insert into public.coach_memory_items(user_id, content, topic, importance)
        values ('${USER_A}', 'Trains for a marathon on weekends', 'training', 4)`);
      const noted = await fingerprint(USER_A);
      assert.notEqual(noted, withExposure);
      await db.sql(`update public.coach_memory_items set topic = 'sleep' where user_id = '${USER_A}'`);
      const withMemory = await fingerprint(USER_A);
      assert.notEqual(withMemory, noted, 'a memory item\'s topic is input too');

      // Another user's data never moves this user's inputs.
      await db.sql(`insert into public.coach_memory_items(user_id, content, importance) values ('${USER_B}', 'Other user', 5)`);
      await score(USER_B, '2026-10-07', 60, 40, DEVICE_B);
      assert.equal(await fingerprint(USER_A), withMemory);

      // ... and every change above re-queues the analysis on the next visit.
      const requeued = await request(USER_A);
      assert.deepEqual([requeued.status, requeued.insight.stale], ['pending', true]);
      assert.deepEqual(await drain(), [USER_A]);
      assert.equal((await request(USER_A)).status, 'ready');
    });

    await t.step('failures back off, dead-letter at the third, and reset when the inputs change', async () => {
      await due();
      await score(USER_A, '2026-10-07', 43, 90.1);
      assert.equal((await request(USER_A)).status, 'pending');
      let lease = await claim();
      let failed = await fail(lease.lease_token, lease.input_revision);
      assert.deepEqual([failed.status, failed.consecutive_failures, failed.dead_letter], ['failed', 1, false]);
      const backoff = Number(await db.sql(`select extract(epoch from not_before - clock_timestamp())::integer
        from public.metric_insight_jobs where user_id = '${USER_A}' and metric = 'resting_hr'`));
      assert.ok(backoff > 20 && backoff <= 30, `first backoff ${backoff}s`);
      assert.equal(await claim(), null, 'a backed-off job was claimed');
      const waiting = await request(USER_A);
      assert.equal(waiting.status, 'pending');
      assert.ok(waiting.retry_after_s >= 20 && waiting.retry_after_s <= 30, `retry_after_s ${waiting.retry_after_s}`);

      await due();
      lease = await claim();
      failed = await fail(lease.lease_token, lease.input_revision);
      assert.deepEqual([failed.consecutive_failures, failed.dead_letter], [2, false]);
      await due();
      lease = await claim();
      failed = await fail(lease.lease_token, lease.input_revision, 'x'.repeat(5000));
      assert.deepEqual([failed.consecutive_failures, failed.dead_letter], [3, true]);
      assert.equal((await job(USER_A)).last_error.length, 2000);
      const dead = await request(USER_A);
      assert.deepEqual([dead.status, dead.reason, dead.insight.stale], ['unavailable', 'analysis_failed', true]);
      await due();
      assert.equal(await claim(), null, 'a dead-lettered job was claimed');

      // Back to values that already have an analysis would be a cache hit; new values re-arm the job.
      await score(USER_A, '2026-10-07', 42, 90.1);
      assert.equal((await request(USER_A)).status, 'pending');
      const revived = await job(USER_A);
      assert.deepEqual([revived.dead_letter, revived.consecutive_failures], [false, 0]);

      // A failure reported for a revision that has since moved on is a clean release, due at once.
      lease = await claim();
      await score(USER_A, '2026-10-07', 45, 90.1);
      assert.equal((await request(USER_A)).status, 'pending');
      const released = await fail(lease.lease_token, lease.input_revision);
      assert.deepEqual([released.status, released.consecutive_failures, released.dead_letter], ['released', 0, false]);
      const retaken = await claim();
      assert.equal(retaken.input_revision, lease.input_revision + 1);
      assert.equal((await publish(retaken.lease_token, retaken.input_revision)).reason, 'published');
    });

    await t.step('leases: lost and expired leases write nothing; an expired lease is claimable again', async () => {
      await due();
      await score(USER_A, '2026-10-07', 46, 90.1);
      await request(USER_A);
      const lease = await claim();
      const before = await count(`user_id = '${USER_A}'`);
      const expiries = (await job(USER_A)).lease_expiry_count;
      assert.deepEqual(await publish(crypto.randomUUID(), lease.input_revision), { applied: false, insight_id: null, reason: 'lease_lost' });
      assert.deepEqual(await fail(crypto.randomUUID(), lease.input_revision), { status: 'lease_lost' });
      assert.equal(await renew(crypto.randomUUID()), false);
      await db.sql(`update public.metric_insight_jobs set lease_until = clock_timestamp() - interval '1 second'
        where lease_token = '${lease.lease_token}'`);
      assert.equal(await renew(lease.lease_token), false);
      assert.equal((await publish(lease.lease_token, lease.input_revision)).reason, 'lease_expired');
      assert.deepEqual(await fail(lease.lease_token, lease.input_revision), { status: 'lease_expired' });
      assert.equal(await count(`user_id = '${USER_A}'`), before);

      const again = await claim();
      assert.equal(again.user_id, USER_A);
      assert.notEqual(again.lease_token, lease.lease_token);
      assert.equal((await job(USER_A)).lease_expiry_count, expiries + 1);
      assert.equal((await publish(again.lease_token, again.input_revision)).reason, 'published');
      // A worker retrying a publish that already landed gets lease_lost, never a duplicate row.
      assert.equal((await publish(again.lease_token, again.input_revision)).reason, 'lease_lost');
      assert.equal(await count(`user_id = '${USER_A}'`), before + 1);
      await assert.rejects(rpc('metric_insight_claim_v1', { p_worker: 'bad worker!', p_lease_seconds: 300 }), isRejected(400));
      await assert.rejects(rpc('metric_insight_claim_v1', { p_worker: 'fixture-worker', p_lease_seconds: 5 }), isRejected(400));
      await assert.rejects(rpc('metric_insight_renew_v1', { p_token: 'not-a-uuid', p_lease_seconds: 300 }), isRejected(400));
    });

    await t.step('payload validation: malformed analyses raise and write nothing', async () => {
      await due();
      await score(USER_A, '2026-10-07', 47, 90.1);
      await request(USER_A);
      const lease = await claim();
      const before = await count('true');
      const bad: Array<[string, unknown]> = [
        ['kind', payload({ kind: 'diagnosis' })],
        ['version', payload({ analysis_version: 'bad version!' })],
        ['model length', payload({ model: 'm'.repeat(201) })],
        ['model type', payload({ model: 7 })],
        ['empty headline', payload({}, { headline: '' })],
        ['long headline', payload({}, { headline: 'h'.repeat(241) })],
        ['observed type', payload({}, { observed: 'one sentence' })],
        ['observed count', payload({}, { observed: Array.from({ length: 7 }, (_, i) => `item ${i}`) })],
        ['observed length', payload({}, { observed: ['o'.repeat(401)] })],
        ['uncertainty item', payload({}, { uncertainty: [3] })],
        ['interpretation missing', payload({}, { interpretation: undefined })],
        ['related count', payload({}, { related: Array.from({ length: 9 }, () => ({ metric: 'hrv_rmssd' })) })],
        ['basis type', payload({}, { basis: [] })],
        ['citation count', payload({ citations: Array.from({ length: 9 }, (_, i) => ({ id: `c${i}` })) })],
        ['citation type', payload({ citations: ['pmid:1'] })],
        ['evidence type', payload({ evidence: [] })],
        ['size', payload({ evidence: { blob: 'e'.repeat(270000) } })],
        ['payload type', []],
      ];
      for (const [label, body] of bad) {
        await assert.rejects(publish(lease.lease_token, lease.input_revision, body), isRejected(400), label);
      }
      assert.equal(await count('true'), before);
      assert.equal(await renew(lease.lease_token), true, 'a rejected payload cost the lease');
      const minimal = payload({ kind: 'insufficient_data', model: null, citations: undefined, evidence: undefined },
        { related: undefined, basis: undefined, observed: [], interpretation: [], uncertainty: ['Only 2 nights are measured.'] });
      assert.equal((await publish(lease.lease_token, lease.input_revision, minimal)).reason, 'published');
      const ready = await request(USER_A);
      assert.deepEqual([ready.status, ready.insight.kind, ready.insight.citations], ['ready', 'insufficient_data', []]);
    });

    await t.step('bounds: 8 claims per UTC day, queued work at the bound, the 6 h request horizon', async () => {
      await due();
      await score(USER_A, '2026-10-07', 48, 90.1);
      await db.sql(`update public.metric_insight_jobs set runs_day = (now() at time zone 'UTC')::date, runs_count = 8
        where user_id = '${USER_A}' and metric = 'resting_hr'`);
      const limited = await request(USER_A);
      assert.deepEqual([limited.status, limited.reason, limited.insight.stale], ['unavailable', 'daily_limit', true]);
      assert.equal((await job(USER_A)).completed_revision, (await job(USER_A)).input_revision, 'work was queued at the bound');

      await due();
      assert.equal((await request(USER_A)).status, 'pending');
      await db.sql(`update public.metric_insight_jobs set runs_day = (now() at time zone 'UTC')::date, runs_count = 8
        where user_id = '${USER_A}' and metric = 'resting_hr'`);
      assert.equal((await request(USER_A)).reason, 'daily_limit', 'queued work at the bound reported as pending');
      assert.equal(await claim(), null);
      // The bound is per UTC day: yesterday's count does not hold today's work back.
      await db.sql(`update public.metric_insight_jobs set runs_day = (now() at time zone 'UTC')::date - 1
        where user_id = '${USER_A}' and metric = 'resting_hr'`);
      const lease = await claim();
      assert.equal(lease.user_id, USER_A);
      assert.equal((await job(USER_A)).runs_count, 1);
      assert.equal((await publish(lease.lease_token, lease.input_revision)).reason, 'published');

      // A request nobody repeated for 6 h is not worked; the next visit re-arms it.
      await due();
      await score(USER_A, '2026-10-07', 49, 90.1);
      assert.equal((await request(USER_A)).status, 'pending');
      await db.sql(`update public.metric_insight_jobs set requested_at = clock_timestamp() - interval '7 hours'
        where user_id = '${USER_A}' and metric = 'resting_hr'`);
      assert.equal(await claim(), null, 'an abandoned request was worked');
      assert.equal((await request(USER_A)).status, 'pending');
      assert.deepEqual(await drain(), [USER_A]);
    });

    await t.step('each metric is its own analysis', async () => {
      const hrv = await request(USER_A, 'hrv_rmssd');
      assert.deepEqual([hrv.status, hrv.metric, hrv.insight], ['pending', 'hrv_rmssd', null]);
      assert.equal((await job(USER_A, 'hrv_rmssd')).anchor_day, '2026-10-07');
      assert.equal((await request(USER_A)).status, 'ready', 'queuing HRV disturbed the RHR analysis');
      const lease = await claim();
      assert.deepEqual([lease.metric, lease.user_id], ['hrv_rmssd', USER_A]);
      await publish(lease.lease_token, lease.input_revision);
      const ready = await request(USER_A, 'hrv_rmssd');
      assert.deepEqual([ready.status, ready.insight.metric], ['ready', 'hrv_rmssd']);
    });

    await t.step('the real scores handler on this database: POST /insights for an installation', async () => {
      const source = '77777777-7777-4777-8777-777777777777';
      const token = `noop_mi_${crypto.randomUUID()}`;
      await db.sql(`insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
          values ('${source}', '${USER_A}', 'ios', '1.0 (1)', 'supabase_auth');
        insert into public.noop_ingest_tokens(user_id, token_hash, token_kind, source_id, provisioning_method)
          values ('${USER_A}', '${hashIngestToken(token)}', 'installation', '${source}', 'supabase_auth');`);
      const cfg = { supabaseUrl: 'https://project.test', supabaseAnonKey: 'sb_publishable_test' };
      const send = (body: unknown) => handleScoresRequest(new Request('https://project.test/functions/v1/scores/insights', {
        method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(body) }), { rest: db.rest, cfg });
      let response = await send({ metric: 'resting_hr', user: USER_B });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      let body = await response.json();
      assert.deepEqual([body.status, body.metric, body.insight.stale], ['ready', 'resting_hr', false]);
      assert.equal((await db.sql(`select user_id from public.metric_insights where id = ${body.insight.id}`)), USER_A);
      await due();
      await score(USER_A, '2026-10-07', 50, 90.1);
      response = await send({ metric: 'resting_hr' });
      body = await response.json();
      assert.deepEqual([response.status, body.status, body.insight.stale, body.retry_after_s], [200, 'pending', true, 10]);
      assert.deepEqual(await drain(), [USER_A]);
      assert.equal((await (await send({ metric: 'resting_hr' })).json()).status, 'ready');
      response = await send({ metric: 'recovery_score' });
      assert.deepEqual([response.status, await response.json()], [400, { error: 'invalid_metric' }]);
    });

    await t.step('isolation: owners read only their own insights; the queue and the RPCs stay closed', async () => {
      await due();
      assert.equal((await request(USER_B)).status, 'pending');
      assert.deepEqual(await drain(), [USER_B]);
      const ownA = await db.request('metric_insights?select=user_id,metric', 'authenticated', USER_A);
      assert.equal(ownA.status, 200);
      assert.ok(ownA.body.length > 2 && ownA.body.every((r: any) => r.user_id === USER_A));
      const ownB = await db.request('metric_insights?select=user_id,metric', 'authenticated', USER_B);
      assert.deepEqual(ownB.body, [{ user_id: USER_B, metric: 'resting_hr' }]);
      const crossRead = await db.request(`metric_insights?select=id&user_id=eq.${USER_A}`, 'authenticated', USER_B);
      assert.deepEqual(crossRead.body, []);
      const anon = await db.request('metric_insights?select=id', 'anon');
      assert.ok([401, 403].includes(anon.status), `anon read: ${anon.status}`);
      for (const role of ['authenticated', 'anon']) {
        const queue = await db.request('metric_insight_jobs?select=*', role, USER_A);
        assert.ok([401, 403].includes(queue.status), `${role} queue read: ${queue.status}`);
      }
      const forged = { user_id: USER_A, metric: 'resting_hr', input_fingerprint: 'a'.repeat(64), job_revision: 1,
        analysis_version: 'x', kind: 'explained', insight: { headline: 'forged' } };
      const insert = await db.request('metric_insights', 'authenticated', USER_A, 'POST', forged);
      assert.ok([401, 403].includes(insert.status), `owner insert: ${insert.status}`);
      const patch = await db.request(`metric_insights?user_id=eq.${USER_A}`, 'authenticated', USER_A, 'PATCH', { kind: 'insufficient_data' });
      assert.ok([401, 403].includes(patch.status), `owner update: ${patch.status}`);
      const remove = await db.request(`metric_insights?user_id=eq.${USER_A}`, 'authenticated', USER_A, 'DELETE');
      assert.ok([401, 403].includes(remove.status), `owner delete: ${remove.status}`);
      const jobsBefore = await db.sql(`select count(*) || ':' || sum(input_revision) from public.metric_insight_jobs`);
      const calls: Array<[string, Record<string, unknown>]> = [
        ['metric_insight_request_v1', { p_user: USER_A, p_metric: 'resting_hr' }],
        ['metric_insight_claim_v1', { p_worker: 'client', p_lease_seconds: 300 }],
        ['metric_insight_renew_v1', { p_token: crypto.randomUUID(), p_lease_seconds: 300 }],
        ['metric_insight_fail_v1', { p_token: crypto.randomUUID(), p_revision: 1, p_error: 'x' }],
        ['metric_insight_publish_v1', { p_token: crypto.randomUUID(), p_revision: 1, p_payload: payload() }],
      ];
      for (const [name, args] of calls) {
        for (const role of ['authenticated', 'anon']) {
          const call = await db.request(`rpc/${name}`, role, USER_A, 'POST', args);
          assert.ok([401, 403, 404].includes(call.status), `${role} ${name}: ${call.status}`);
        }
      }
      assert.equal(await db.sql(`select count(*) || ':' || sum(input_revision) from public.metric_insight_jobs`), jobsBefore);
      assert.equal(await count(`insight ->> 'headline' = 'forged'`), 0);

      // A caller JWT naming another user is refused even on the service path.
      await assert.rejects(db.sql(`begin; set local role service_role;
          set local request.jwt.claims = '{"sub": "${USER_B}", "role": "authenticated"}';
          select public.metric_insight_request_v1('${USER_A}', 'resting_hr'); commit;`), /cross_user_caller/);
      await db.sql(`begin; set local role service_role;
          set local request.jwt.claims = '{"sub": "${USER_A}", "role": "authenticated"}';
          select public.metric_insight_request_v1('${USER_A}', 'resting_hr'); commit;`);
    });

    await t.step('retired owners: refused, never claimed, never published', async () => {
      await db.sql(`insert into auth.users(id) values ('${USER_C}')`);
      await score(USER_C, '2026-10-06', 55, 50);
      assert.equal((await request(USER_C)).status, 'pending');
      const lease = await claim();
      assert.equal(lease.user_id, USER_C);
      await score(USER_C, '2026-10-07', 56, 50);
      assert.equal((await request(USER_C)).status, 'pending');
      await db.sql(`insert into public.noop_account_retirements(user_id) values ('${USER_C}')`);
      assert.deepEqual(await publish(lease.lease_token, lease.input_revision),
        { applied: false, insight_id: null, reason: 'owner_retired' });
      assert.equal(await count(`user_id = '${USER_C}'`), 0);
      await due();
      assert.ok(!(await drain()).includes(USER_C), 'a retired owner was claimed');
      await assert.rejects(request(USER_C), (err: any) => {
        assert.ok([401, 403].includes(err?.status), String(err?.message ?? err));
        return true;
      });
    });

    await t.step('retention keeps the 20 newest superseded analyses; account deletion cascades', async () => {
      await db.sql(`insert into auth.users(id) values ('${USER_D}')`);
      for (let i = 0; i < 23; i++) {
        await due();
        await score(USER_D, '2026-10-06', 50 + i, 60);
        assert.equal((await request(USER_D)).status, 'pending');
        const lease = await claim();
        assert.equal(lease.user_id, USER_D);
        assert.equal((await publish(lease.lease_token, lease.input_revision)).reason, 'published');
      }
      assert.equal(await count(`user_id = '${USER_D}' and superseded_at is null`), 1);
      assert.equal(await count(`user_id = '${USER_D}' and superseded_at is not null`), 20);
      assert.equal(await db.sql(`select min(job_revision) from public.metric_insights where user_id = '${USER_D}'`), '3');

      await db.sql(`delete from auth.users where id = '${USER_B}'`);
      assert.equal(await count(`user_id = '${USER_B}'`), 0);
      assert.equal(await db.sql(`select count(*) from public.metric_insight_jobs where user_id = '${USER_B}'`), '0');
      assert.ok(await count(`user_id = '${USER_A}'`) > 0, 'another owner lost analyses');
    });
  } finally {
    await db.close();
  }
});

