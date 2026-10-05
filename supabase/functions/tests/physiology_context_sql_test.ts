// 20261005120000_physiology_context.sql on the production Postgres image, through the full ordered migration
// chain (supabase/tests/e2e/pipeline_db.sh builds it, with GoTrue's auth schema and PostgREST in front).
// Docker-gated like auth_isolation_sql_test.ts: skipped unless PIPELINE_TEST_DATABASE_CONTAINER and
// PIPELINE_TEST_REST_URL are set. Run it on a fresh database (`pipeline_db.sh reset`): the enqueue step counts
// every completed scoring job in the database.
//
//   supabase/tests/e2e/pipeline_db.sh up      # or `reset` before each suite
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   EDGE_TEST_ARTIFACTS=/tmp/edgeart deno test -A --no-lock tests/physiology_context_sql_test.ts
//
// What it proves (contracts.md §6/§8, spec V15/V16, C07-C09): the catalogue (RLS, grants, service-only EXECUTE,
// SECURITY DEFINER with an empty search_path, cascading foreign keys), owner isolation through PostgREST, the
// enqueue from scoring completions (never writing scoring tables), claim/renew/fail with backoff and dead letter,
// publish fencing (stale revision, expired and lost leases), idempotent retries and restarts (one revision, no
// duplicate rows or episodes), retention, the episode rule, insert-only frozen references, the cross-day cascade
// bounded by D+28 and today, the read and history RPCs (status, mode choice, metric filter, pairing), the
// placement trigger (set_placement_interval keeps working for clients), account and device deletion, and the
// real scores handler against this database. Exposure events are in exposure_events_sql_test.ts.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';
const EMAIL_PREFIX = 'pcsql-';
const decoder = new TextDecoder();

const TABLES = ['physiology_context_jobs', 'physiology_context_days', 'physiology_context_daily_values',
  'physiology_context_bouts', 'physiology_context_episodes', 'physiology_context_frozen_references',
  'exposure_event_revisions', 'exposure_events'];
const OWNER_READABLE = TABLES.filter((table) => table !== 'physiology_context_jobs');
const FUNCTIONS: Record<string, string> = {
  enqueue_physiology_context_days_v1: 'integer',
  invalidate_physiology_context_span_v1: 'uuid,uuid,date,date,text',
  claim_physiology_context_v1: 'text,integer',
  renew_physiology_context_v1: 'uuid,integer',
  fail_physiology_context_v1: 'uuid,bigint,text',
  publish_physiology_context_v1: 'uuid,bigint,jsonb',
  physiology_context_read_v1: 'uuid,uuid,date,text,text',
  physiology_context_history_read_v1: 'uuid,uuid,date,date,text',
  record_exposure_event_v1: 'uuid,uuid,jsonb',
  exposure_events_read_v1: 'uuid,bigint,bigint,boolean',
};

function b64url(value: string) {
  return btoa(value).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
}
function signJwt(role: string, sub?: string) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ role, sub, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 }));
  const signature = createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
  return `${header}.${body}.${signature}`;
}

async function psql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const result = await child.output();
  return { ok: result.code === 0, out: decoder.decode(result.stdout).trim(), err: decoder.decode(result.stderr) };
}
async function sql(text: string) {
  const result = await psql(text);
  assert.ok(result.ok, result.err);
  return result.out;
}
const sqlJson = async (text: string) => JSON.parse((await sql(text)) || 'null');
async function sqlFails(text: string, pattern: RegExp) {
  const result = await psql(text);
  assert.ok(!result.ok, `expected a failure matching ${pattern}, got ${result.out}`);
  assert.match(result.err, pattern);
}
const count = async (table: string, where: string) => Number(await sql(`select count(*) from public.${table} where ${where}`));

interface Reply { status: number; body: any }
async function call(token: string | null, method: string, path: string, body?: unknown): Promise<Reply> {
  const response = await fetch(`${restUrl}/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), 'content-type': 'application/json',
      prefer: 'return=representation' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let parsed: any = null;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = text; }
  return { status: response.status, body: parsed };
}
const refused = (reply: Reply) => [401, 403].includes(reply.status);

function addDays(day: string, n: number) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + n);
  return date.toISOString().slice(0, 10);
}

async function owner(zone = 'UTC', devices = 1) {
  const user = crypto.randomUUID();
  const ids = Array.from({ length: devices }, () => crypto.randomUUID());
  await sql(`
    insert into auth.users(id, email) values ('${user}', '${EMAIL_PREFIX}${user}@example.test');
    insert into public.profiles(id, timezone) values ('${user}', '${zone}')
      on conflict (id) do update set timezone = excluded.timezone;
    ${ids.map((id, index) => `insert into public.devices(id, user_id, source_kind, external_device_id)
      values ('${id}', '${user}', 'noop_push', 'whoop-PC${index}${user.slice(0, 8).toUpperCase()}');`).join('\n')}`);
  return { user, device: ids[0], devices: ids };
}
async function todayIn(zone: string) {
  return await sql(`select to_char((now() at time zone '${zone}')::date, 'YYYY-MM-DD')`);
}
async function scored(user: string, device: string, day: string, revision = 1) {
  await sql(`insert into public.scoring_jobs_v2(user_id, device_id, day, algorithm_version, input_revision,
      completed_revision, last_completed_at)
    values ('${user}', '${device}', '${day}', 'frwhoop-server-1', ${revision}, ${revision}, clock_timestamp())
    on conflict (user_id, device_id, day, algorithm_version) do update set input_revision = excluded.input_revision,
      completed_revision = excluded.completed_revision, last_completed_at = excluded.last_completed_at`);
}
/** A completed job for (user, device, day, mode), as if an earlier run had published it. */
async function completedJob(user: string, device: string, day: string, mode: string) {
  await sql(`insert into public.physiology_context_jobs(user_id, device_id, day, mode, input_revision, completed_revision,
      dirty_at) values ('${user}', '${device}', '${day}', '${mode}', 1, 1, clock_timestamp() - interval '1 day')
    on conflict (user_id, device_id, day, mode) do update set completed_revision = public.physiology_context_jobs.input_revision`);
}
async function job(user: string, device: string, day: string, mode: string) {
  return await sqlJson(`select row_to_json(j) from public.physiology_context_jobs j where user_id = '${user}'
    and device_id = '${device}' and day = '${day}' and mode = '${mode}'`);
}
/** Claim exactly this job: every other due job in the database is parked for the call, then released. */
async function claimJob(user: string, device: string, day: string, mode: string, lease = 300) {
  await sql(`update public.physiology_context_jobs set not_before = now() + interval '40 days'
    where completed_revision < input_revision and not_before <= now()
      and not (user_id = '${user}' and device_id = '${device}' and day = '${day}' and mode = '${mode}')`);
  const claimed = await sqlJson(`select coalesce((select row_to_json(c) from
    public.claim_physiology_context_v1('pc-sql-test', ${lease}) c), 'null'::json)`);
  await sql(`update public.physiology_context_jobs set not_before = now() where not_before > now() + interval '39 days'`);
  return claimed;
}
async function claimAny(user: string, lease = 300) {
  await sql(`update public.physiology_context_jobs set not_before = now() + interval '40 days'
    where completed_revision < input_revision and not_before <= now() and user_id <> '${user}'`);
  const claimed = await sqlJson(`select coalesce((select row_to_json(c) from
    public.claim_physiology_context_v1('pc-sql-test', ${lease}) c), 'null'::json)`);
  await sql(`update public.physiology_context_jobs set not_before = now() where not_before > now() + interval '39 days'`);
  return claimed;
}

function dailyValue(day: string, mode: string, series = 'hrv_rmssd.sleep_night', value = 42.5, over: Record<string, unknown> = {}) {
  return { day, series_key: series, regime_key: 'regime-a', metric: 'hrv_rmssd', value, units: 'ms', support_count: 1,
    support_unit: 'nights', support_s: 25200, mode, finality: 'provisional', source_ids: [], reasons: [], ...over };
}
function episode(id: string, day: string, over: Record<string, unknown> = {}) {
  return { id, series_key: 'hrv_rmssd.sleep_night', regime_key: 'regime-a', state: 'transient_deviation', direction: -1,
    start_day: day, last_day: day, ongoing: true, duration_days: 1, finality: 'provisional', reasons: [], ...over };
}
function frozen(id: string, day: string, over: Record<string, unknown> = {}) {
  return { id, series_key: 'hrv_rmssd.sleep_night', regime_key: 'regime-a', version: 1, from_day: addDays(day, -20),
    to_day: addDays(day, -7), support_days: 14, center: 3.7, scale: 0.21, transform: 'ln',
    selection_rule: 'first_14_supported_days_in_regime', created_for_day: day, policy_fingerprint: 'pol-1', ...over };
}
function bout(id: string, day: string, start: number) {
  return { id, interval: { start, end: start + 900 }, day, kind: 'walking', status: 'complete', duration_s: 900, reasons: [] };
}
function payload(day: string, mode: string, over: {
  input?: string; policy?: string; values?: unknown[]; bouts?: unknown[]; episodes?: unknown[]; frozen?: unknown[];
  scoringResult?: number | null; finality?: string; cutoff?: number; envelopes?: unknown[]; header?: Record<string, unknown>;
} = {}) {
  const policy = over.policy ?? 'pol-1';
  const input = over.input ?? 'in-1';
  const cutoff = over.cutoff ?? 1_791_000_000;
  const envelopes = over.envelopes ?? [
    { id: 'hrv@1-2', metric: 'hrv_rmssd', value: 41 }, { id: 'hr@1-2', metric: 'heart_rate', value: 60 },
    { id: 'hrv@3-4', metric: 'hrv_rmssd', value: 44 },
  ];
  return {
    header: { mode, day, finality: over.finality ?? 'provisional', status: 'available', availability_cutoff: cutoff,
      generated_at: cutoff, contract_version: 'pc-contract-1', schema_version: 1, policy_fingerprint: policy,
      input_fingerprint: input, versions: { contract: 'pc-contract-1', engine: 'pc-engine-1' }, ...over.header },
    document: {
      header: { schema_version: 1, contract_version: 'pc-contract-1', policy_fingerprint: policy, input_fingerprint: input,
        identity: { device_scope: 'scope', day, timezone_id: 'UTC', day_window: { start: 0, end: 86400 } },
        interpretation: { mode, finality: over.finality ?? 'provisional', availability_cutoff: cutoff, generated_at: cutoff } },
      status: 'available', envelopes,
    },
    scoring_result_revision: over.scoringResult ?? null,
    scoring_input_revision: over.scoringResult ? 1 : null,
    duration_ms: 12,
    daily_values: over.values ?? [dailyValue(day, mode)],
    bouts: over.bouts ?? [],
    episodes: over.episodes ?? [],
    new_frozen_references: over.frozen ?? [],
  };
}
async function publish(token: string, revision: number, body: unknown) {
  return await sqlJson(`select public.publish_physiology_context_v1('${token}', ${revision}, $pc$${JSON.stringify(body)}$pc$::jsonb)`);
}
/** Create (or bump) the job, claim it and publish. */
async function publishDay(user: string, device: string, day: string, mode: string, body: unknown) {
  await sql(`select internal.physiology_context_touch('${user}', '${device}', '${day}', '${mode}', 'test', null)`);
  const claimed = await claimJob(user, device, day, mode);
  assert.ok(claimed, `no claim for ${day} ${mode}`);
  return await publish(claimed.lease_token, claimed.input_revision, body);
}
const read = (user: string, device: string, day: string, mode: string | null = null, metric: string | null = null) =>
  sqlJson(`select public.physiology_context_read_v1('${user}', '${device}', '${day}',
    ${mode ? `'${mode}'` : 'null'}, ${metric ? `'${metric}'` : 'null'})`);

const ready = async () => {
  for (let attempt = 0; attempt < 60; attempt++) {
    const reply = await call(signJwt('service_role'), 'GET', 'devices?select=id&limit=1').catch(() => null);
    if (reply?.status === 200) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('PostgREST did not answer');
};

Deno.test({
  name: 'physiology context: schema, privileges, queue, publication, reads, invalidation and deletion on the production image',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    await ready();
    await sql(`delete from auth.users where email like '${EMAIL_PREFIX}%'`);

    await t.step('catalogue: RLS, grants, policies, definer functions, triggers and cascading keys', async () => {
      for (const table of TABLES) {
        assert.equal(await sql(`select relrowsecurity from pg_class where oid = 'public.${table}'::regclass`), 't', table);
        const has = async (role: string, privilege: string) =>
          (await sql(`select has_table_privilege('${role}', 'public.${table}', '${privilege}')`)) === 't';
        for (const privilege of ['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']) {
          assert.equal(await has('anon', privilege), false, `anon ${privilege} ${table}`);
          if (privilege !== 'select') assert.equal(await has('authenticated', privilege), false, `authenticated ${privilege} ${table}`);
        }
        assert.equal(await has('authenticated', 'select'), OWNER_READABLE.includes(table), `authenticated select ${table}`);
        for (const privilege of ['select', 'insert', 'update', 'delete']) {
          assert.equal(await has('service_role', privilege), true, `service_role ${privilege} ${table}`);
        }
        const policies = await sql(`select policyname || ':' || cmd || ':' || array_to_string(roles, ',') || ':' || coalesce(qual, '')
          from pg_policies where schemaname = 'public' and tablename = '${table}' order by policyname`);
        const column = table.startsWith('exposure') ? 'owner' : 'user_id';
        assert.equal(policies, [
          ...(OWNER_READABLE.includes(table) ? [`${table}_select_own:SELECT:authenticated:(( SELECT auth.uid() AS uid) = ${column})`] : []),
          `${table}_service:ALL:service_role:true`,
        ].join('\n'), table);
        // Every foreign key cascades on delete; none sets NULL (an UPDATE the immutability triggers would refuse).
        const rules = await sql(`select string_agg(distinct confdeltype::text, ',') from pg_constraint
          where conrelid = 'public.${table}'::regclass and contype = 'f'`);
        assert.equal(rules, 'c', `${table} foreign keys: ${rules}`);
      }
      for (const table of TABLES.filter((name) => name.startsWith('physiology'))) {
        assert.equal(await sql(`select count(*) from pg_constraint where conrelid = 'public.${table}'::regclass and contype = 'f'
          and confrelid = 'public.devices'::regclass and pg_get_constraintdef(oid) like 'FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE'`), '1', table);
      }
      for (const [name, args] of Object.entries(FUNCTIONS)) {
        const fn = `'public.${name}(${args})'::regprocedure`;
        assert.equal(await sql(`select has_function_privilege('anon', ${fn}, 'execute')`), 'f', `anon ${name}`);
        assert.equal(await sql(`select has_function_privilege('authenticated', ${fn}, 'execute')`), 'f', `authenticated ${name}`);
        assert.equal(await sql(`select has_function_privilege('service_role', ${fn}, 'execute')`), 't', `service_role ${name}`);
        assert.equal(await sql(`select count(*) from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
          where p.oid = ${fn} and a.grantee = 0`), '0', `PUBLIC keeps EXECUTE on ${name}`);
        assert.equal(await sql(`select prosecdef || '|' || array_to_string(proconfig, ',') from pg_proc where oid = ${fn}`),
          'true|search_path=""', name);
      }
      const helpers = await sqlJson(`select coalesce(json_agg(json_build_object('name', p.proname,
          'reachable', has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('service_role', p.oid, 'execute'))), '[]')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'internal' and (p.proname like 'physiology_context%' or p.proname like 'exposure_%')`);
      assert.ok(helpers.length >= 13, JSON.stringify(helpers));
      assert.deepEqual(helpers.filter((row: any) => row.reachable), [], 'an internal helper is executable by a role');
      const triggers = await sql(`select tgrelid::regclass || ':' || tgname from pg_trigger
        where not tgisinternal and tgname in ('physiology_context_frozen_reference_immutable',
          'exposure_event_revision_immutable', 'physiology_context_placement_changed') order by 1`);
      assert.equal(triggers, ['exposure_event_revisions:exposure_event_revision_immutable',
        'physiology_context_frozen_references:physiology_context_frozen_reference_immutable',
        'placement_intervals:physiology_context_placement_changed'].join('\n'));
      // Nothing was attached to scoring or noop_* tables.
      assert.equal(await sql(`select count(*) from pg_trigger t join pg_proc p on p.oid = t.tgfoid
        where not t.tgisinternal and p.proname like 'physiology_context%' and t.tgrelid::regclass::text <> 'placement_intervals'
          and t.tgrelid::regclass::text not like 'physiology_context%' and t.tgrelid::regclass::text not like 'exposure%'`), '0');
    });

    await t.step('enqueue: from scoring completions, D-1..D+1, causal today, 10-minute rebuild interval, never writes scoring', async () => {
      const a = await owner('UTC');
      const today = await todayIn('UTC');
      const days = [addDays(today, -10), addDays(today, -1), today];
      for (const day of days) await scored(a.user, a.device, day);
      await scored(a.user, a.device, addDays(today, -200)); // outside the 120-day window: ignored
      const scoringState = () => sql(`select md5(coalesce(string_agg(row_to_json(s)::text, ',' order by user_id, device_id, day,
        algorithm_version), '')) from public.scoring_jobs_v2 s`);
      const scoringBefore = await scoringState();
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(2)'), '2', 'the limit holds');
      assert.equal(Number(await sql('select public.enqueue_physiology_context_days_v1(50)')), 4);
      assert.equal(await scoringState(), scoringBefore, 'the enqueue never writes scoring_jobs_v2');
      const jobs = await sqlJson(`select json_agg(json_build_object('day', to_char(day, 'YYYY-MM-DD'), 'mode', mode,
          'rev', input_revision, 'reasons', reasons, 'fp', fingerprint is not null) order by day)
        from public.physiology_context_jobs where user_id = '${a.user}'`);
      assert.deepEqual(jobs.map((row: any) => [row.day, row.mode, row.rev, row.reasons, row.fp]), [
        [addDays(today, -11), 'retrospective', 1, ['scoring_completed'], true],
        [addDays(today, -10), 'retrospective', 1, ['scoring_completed'], true],
        [addDays(today, -9), 'retrospective', 1, ['scoring_completed'], true],
        [addDays(today, -2), 'retrospective', 1, ['scoring_completed'], true],
        [addDays(today, -1), 'retrospective', 1, ['scoring_completed'], true],
        [today, 'causal_live', 1, ['scoring_completed'], true],
      ]);
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(50)'), '0', 'an unchanged state is a no-op');

      // Pending jobs are never bumped by the enqueue, even when scoring moves on.
      await scored(a.user, a.device, today, 2);
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(50)'), '0');
      // Completed and dirtied less than 10 minutes ago: held back.
      await sql(`update public.physiology_context_jobs set completed_revision = input_revision where user_id = '${a.user}'`);
      await scored(a.user, a.device, today, 3);
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(50)'), '0', 'the 10-minute interval holds');
      // Ten minutes later the changed fingerprint bumps today and the neighbour whose D+1 scoring moved.
      await sql(`update public.physiology_context_jobs set dirty_at = now() - interval '11 minutes' where user_id = '${a.user}'`);
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(50)'), '2');
      assert.deepEqual((await job(a.user, a.device, today, 'causal_live')).reasons, ['inputs_changed', 'scoring_completed']);
      assert.equal((await job(a.user, a.device, today, 'causal_live')).input_revision, 2);
      assert.equal((await job(a.user, a.device, addDays(today, -1), 'retrospective')).input_revision, 2);
      assert.equal((await job(a.user, a.device, addDays(today, -10), 'retrospective')).input_revision, 1);
      const scoringAfterBump = await scoringState();
      assert.equal(await sql('select public.enqueue_physiology_context_days_v1(50)'), '0');
      assert.equal(await scoringState(), scoringAfterBump, 'the enqueue never writes scoring_jobs_v2');
      assert.equal(await count('scoring_jobs_v2', `user_id = '${a.user}'`), 4, 'the enqueue created no scoring rows');

      // A retired owner (account deletion under way) is skipped entirely.
      const r = await owner('UTC');
      await sql(`insert into public.noop_account_retirements(user_id) values ('${r.user}')`);
      await scored(r.user, r.device, today);
      await sql('select public.enqueue_physiology_context_days_v1(50)');
      assert.equal(await count('physiology_context_jobs', `user_id = '${r.user}'`), 0);
      await sql(`delete from public.noop_account_retirements where user_id = '${r.user}'`);
    });

    await t.step('claim: owner zone and local day window, causal first, then the oldest retrospective day; skips retired owners', async () => {
      const zone = 'America/Los_Angeles';
      const a = await owner(zone);
      const today = await todayIn(zone);
      for (const day of [addDays(today, -5), addDays(today, -3)]) {
        await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      }
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${today}', 'causal_live', 'test', null)`);
      const first = await claimAny(a.user);
      assert.deepEqual([first.day, first.mode, first.timezone_id, first.input_revision, first.claim_count],
        [today, 'causal_live', zone, 1, 1]);
      const window = await sqlJson(`select json_build_object('start', extract(epoch from ('${today}'::timestamp at time zone '${zone}'))::bigint,
        'end', extract(epoch from (('${today}'::date + 1)::timestamp at time zone '${zone}'))::bigint)`);
      assert.deepEqual([first.day_start, first.day_end], [window.start, window.end]);
      assert.equal((await claimAny(a.user)).day, addDays(today, -5), 'retrospective days run oldest first');
      assert.equal((await claimAny(a.user)).day, addDays(today, -3));
      assert.equal(await claimAny(a.user), null, 'leased jobs are not handed out twice');
      // A DST day reports its real length when one is inside the window.
      const dst = await sqlJson(`select coalesce(json_agg(json_build_object('zone', z, 'day', to_char(d, 'YYYY-MM-DD'))), '[]')
        from unnest(array['Australia/Sydney', 'America/Los_Angeles', 'Europe/London']) z,
             generate_series((now() at time zone 'UTC')::date - 100, (now() at time zone 'UTC')::date - 1, interval '1 day') d
        where ((d::date + 1)::timestamp at time zone z) - (d::date::timestamp at time zone z) <> interval '24 hours'`);
      if (dst.length > 0) {
        const d = await owner(dst[0].zone);
        await sql(`select internal.physiology_context_touch('${d.user}', '${d.device}', '${dst[0].day}', 'retrospective', 'test', null)`);
        const claimed = await claimJob(d.user, d.device, dst[0].day, 'retrospective');
        assert.ok([82800, 90000].includes(claimed.day_end - claimed.day_start), JSON.stringify(claimed));
      } else {
        console.log('no DST transition in the last 100 days; DST window length not asserted');
      }
      const r = await owner('UTC');
      await sql(`select internal.physiology_context_touch('${r.user}', '${r.device}', '${await todayIn('UTC')}', 'causal_live', 'test', null);
        insert into public.noop_account_retirements(user_id) values ('${r.user}');`);
      assert.equal(await claimAny(r.user), null, 'a retired owner is never handed out');
      await sql(`delete from public.noop_account_retirements where user_id = '${r.user}'`);
      await sqlFails(`select * from public.claim_physiology_context_v1('w', 0)`, /invalid_lease/);
      await sqlFails(`select * from public.claim_physiology_context_v1('bad worker', 60)`, /invalid_worker/);
    });

    await t.step('renew and fail: backoff 5 * 2^n capped at an hour, dead letter at 8, revision mismatch is a clean release', async () => {
      const a = await owner('UTC');
      const day = addDays(await todayIn('UTC'), -4);
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      let claimed = await claimJob(a.user, a.device, day, 'retrospective', 60);
      assert.equal(await sql(`select public.renew_physiology_context_v1('${claimed.lease_token}', 600)`), 't');
      const until = await sql(`select round(extract(epoch from lease_until - now())) from public.physiology_context_jobs
        where lease_token = '${claimed.lease_token}'`);
      assert.ok(Number(until) > 590 && Number(until) <= 600, until);
      assert.equal(await sql(`select public.renew_physiology_context_v1('${crypto.randomUUID()}', 60)`), 'f');
      const backoffs: number[] = [];
      for (let attempt = 1; attempt <= 8; attempt++) {
        const failed = await sqlJson(`select public.fail_physiology_context_v1('${claimed.lease_token}', ${claimed.input_revision}, 'boom ${attempt}')`);
        assert.equal(failed.status, 'failed');
        assert.equal(failed.consecutive_failures, attempt);
        assert.equal(failed.dead_letter, attempt >= 8);
        backoffs.push(Number(await sql(`select round(extract(epoch from not_before - now())) from public.physiology_context_jobs
          where user_id = '${a.user}' and day = '${day}'`)));
        await sql(`update public.physiology_context_jobs set not_before = now() where user_id = '${a.user}' and day = '${day}'`);
        claimed = attempt < 8 ? await claimJob(a.user, a.device, day, 'retrospective') : claimed;
      }
      for (const [index, expected] of [5, 10, 20, 40, 80, 160, 320, 640].entries()) {
        assert.ok(Math.abs(backoffs[index] - expected) <= 2, `backoff ${index}: ${backoffs}`);
      }
      assert.equal((await job(a.user, a.device, day, 'retrospective')).last_error, 'boom 8');
      assert.equal(await claimJob(a.user, a.device, day, 'retrospective'), null, 'a dead-lettered job is not claimed');
      // New inputs resurrect it.
      await sql(`select public.invalidate_physiology_context_span_v1('${a.user}', '${a.device}', '${day}', '${day}', 'operator_retry')`);
      const revived = await job(a.user, a.device, day, 'retrospective');
      assert.deepEqual([revived.dead_letter, revived.consecutive_failures, revived.input_revision], [false, 0, 2]);
      claimed = await claimJob(a.user, a.device, day, 'retrospective');
      // The inputs change while the worker runs: its failure releases the job without counting.
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      const released = await sqlJson(`select public.fail_physiology_context_v1('${claimed.lease_token}', ${claimed.input_revision}, 'late')`);
      assert.deepEqual([released.status, released.consecutive_failures, released.dead_letter], ['released', 0, false]);
      assert.equal((await job(a.user, a.device, day, 'retrospective')).lease_token, null);
      // An expired lease or a lost token changes nothing.
      claimed = await claimJob(a.user, a.device, day, 'retrospective');
      await sql(`update public.physiology_context_jobs set lease_until = now() - interval '1 second' where lease_token = '${claimed.lease_token}'`);
      assert.equal((await sqlJson(`select public.fail_physiology_context_v1('${claimed.lease_token}', ${claimed.input_revision}, 'x')`)).status, 'lease_expired');
      assert.equal((await sqlJson(`select public.fail_physiology_context_v1('${crypto.randomUUID()}', 1, 'x')`)).status, 'lease_lost');
      assert.equal((await job(a.user, a.device, day, 'retrospective')).consecutive_failures, 0);
    });

    await t.step('publish: fenced on a live lease and the current revision; malformed payloads write nothing', async () => {
      const a = await owner('UTC');
      const day = addDays(await todayIn('UTC'), -6);
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      let claimed = await claimJob(a.user, a.device, day, 'retrospective');
      // The inputs change while the worker computes: the stale result is refused and the lease released.
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'exposure_changed', null)`);
      const stale = await publish(claimed.lease_token, claimed.input_revision, payload(day, 'retrospective'));
      assert.deepEqual([stale.applied, stale.reason, stale.context_revision], [false, 'stale_revision', null]);
      assert.equal((await job(a.user, a.device, day, 'retrospective')).lease_token, null);
      // An expired lease is refused and nothing is written.
      claimed = await claimJob(a.user, a.device, day, 'retrospective');
      await sql(`update public.physiology_context_jobs set lease_until = now() - interval '1 second' where lease_token = '${claimed.lease_token}'`);
      assert.equal((await publish(claimed.lease_token, claimed.input_revision, payload(day, 'retrospective'))).reason, 'lease_expired');
      assert.equal((await publish(crypto.randomUUID(), 1, payload(day, 'retrospective'))).reason, 'lease_lost');
      claimed = await claimJob(a.user, a.device, day, 'retrospective');
      const bad: Array<[unknown, RegExp]> = [
        [{ ...payload(day, 'retrospective'), header: { ...payload(day, 'retrospective').header, day: addDays(day, 1) } }, /invalid_physiology_context_identity/],
        [{ ...payload(day, 'retrospective'), header: { ...payload(day, 'retrospective').header, mode: 'causal_live' } }, /invalid_physiology_context_identity/],
        [{ ...payload(day, 'retrospective'), header: { ...payload(day, 'retrospective').header, finality: 'done' } }, /invalid_physiology_context_header/],
        [{ ...payload(day, 'retrospective'), header: { ...payload(day, 'retrospective').header, availability_cutoff: 1.5 } }, /invalid_physiology_context_header/],
        [payload(day, 'retrospective', { input: 'in 1' }), /invalid_physiology_context_header/],
        [{ ...payload(day, 'retrospective'), document: [] }, /invalid_physiology_context_document/],
        [payload(day, 'retrospective', { values: [dailyValue(addDays(day, 1), 'retrospective')] }), /invalid_physiology_context_daily_value/],
        [payload(day, 'retrospective', { values: [dailyValue(day, 'retrospective'), dailyValue(day, 'retrospective', undefined, 7)] }), /duplicate/],
        [payload(day, 'retrospective', { values: [dailyValue(day, 'retrospective', 'bad key')] }), /invalid_physiology_context_daily_value/],
        [payload(day, 'retrospective', { bouts: [bout('b1', addDays(day, -1), 1_791_000_000)] }), /invalid_physiology_context_bout/],
        [payload(day, 'retrospective', { episodes: [episode('e1', day, { state: 'illness' })] }), /invalid_physiology_context_episode/],
        [payload(day, 'retrospective', { episodes: [episode('e1', day, { last_day: '2026-02-30' })] }), /invalid_physiology_context_episode/],
        [payload(day, 'retrospective', { frozen: [frozen('f1', day, { version: 0 })] }), /invalid_physiology_context_frozen_reference/],
        [{ ...payload(day, 'retrospective'), scoring_result_revision: 'five' }, /invalid_physiology_context_scoring_revision/],
        ['[]', /invalid_physiology_context_payload/],
      ];
      for (const [body, pattern] of bad) {
        const text = typeof body === 'string' ? body : JSON.stringify(body);
        await sqlFails(`select public.publish_physiology_context_v1('${claimed.lease_token}', ${claimed.input_revision}, $pc$${text}$pc$::jsonb)`, pattern);
      }
      for (const table of TABLES.filter((name) => name !== 'physiology_context_jobs' && name.startsWith('physiology'))) {
        assert.equal(await count(table, `user_id = '${a.user}'`), 0, `${table} was written by a refused publish`);
      }
      const leased = await job(a.user, a.device, day, 'retrospective');
      assert.equal(leased.lease_token, claimed.lease_token, 'a malformed payload leaves the lease to the worker');
      assert.equal(leased.completed_revision, 0);
      const ok = await publish(claimed.lease_token, claimed.input_revision, payload(day, 'retrospective'));
      assert.deepEqual([ok.applied, ok.reason], [true, 'published']);
    });

    await t.step('idempotent retry and restart: one revision, no duplicate rows, episodes or references', async () => {
      const a = await owner('UTC');
      const day = addDays(await todayIn('UTC'), -8);
      const body = payload(day, 'retrospective', {
        scoringResult: 10, episodes: [episode('ep-1', day)], frozen: [frozen('fr-1', day)],
        bouts: [bout('bout-1', day, 1_791_000_000), bout('bout-2', day, 1_791_002_000)],
        values: [dailyValue(day, 'retrospective'), dailyValue(day, 'retrospective', 'resting_hr.sleep_night', 52)],
      });
      // Restart: the first worker's lease expires mid-run; a second worker reclaims and publishes.
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      const first = await claimJob(a.user, a.device, day, 'retrospective');
      await sql(`update public.physiology_context_jobs set lease_until = now() - interval '1 second' where lease_token = '${first.lease_token}'`);
      const second = await claimJob(a.user, a.device, day, 'retrospective');
      assert.notEqual(second.lease_token, first.lease_token);
      assert.equal((await job(a.user, a.device, day, 'retrospective')).lease_expiry_count, 1);
      const published = await publish(second.lease_token, second.input_revision, body);
      assert.deepEqual([published.applied, published.reason, published.cascaded_days, published.frozen_references_inserted,
        published.episodes_replaced], [true, 'published', 0, 1, true]);
      // The first worker wakes up and publishes the same result: refused, nothing changes.
      assert.equal((await publish(first.lease_token, first.input_revision, body)).reason, 'lease_lost');
      const snapshot = async () => ({
        days: await count('physiology_context_days', `user_id = '${a.user}'`),
        values: await count('physiology_context_daily_values', `user_id = '${a.user}'`),
        bouts: await count('physiology_context_bouts', `user_id = '${a.user}'`),
        episodes: await count('physiology_context_episodes', `user_id = '${a.user}'`),
        frozen: await count('physiology_context_frozen_references', `user_id = '${a.user}'`),
      });
      assert.deepEqual(await snapshot(), { days: 1, values: 2, bouts: 2, episodes: 1, frozen: 1 });
      // A retry with identical fingerprints (a re-run after a new, identical snapshot) adds nothing.
      const retry = await publishDay(a.user, a.device, day, 'retrospective', { ...body, scoring_result_revision: 11 });
      assert.deepEqual([retry.applied, retry.reason, retry.context_revision, retry.cascaded_days],
        [false, 'unchanged', published.context_revision, 0]);
      assert.deepEqual(await snapshot(), { days: 1, values: 2, bouts: 2, episodes: 1, frozen: 1 });
      const after = await job(a.user, a.device, day, 'retrospective');
      assert.deepEqual([after.completed_revision === after.input_revision, after.lease_token, after.unchanged_count,
        after.last_outcome, after.reasons], [true, null, 1, 'unchanged', []]);
      assert.equal(await sql(`select scoring_result_revision from public.physiology_context_days where user_id = '${a.user}'`), '11',
        'the identical document is paired with the newer snapshot');
    });

    await t.step('retention keeps the current and previous rows; revisions only increase; A -> B -> A gets a new revision', async () => {
      const a = await owner('UTC');
      const back = addDays(await todayIn('UTC'), -10);
      const abaRevisions: number[] = [];
      for (const input of ['in-a', 'in-b', 'in-a']) {
        abaRevisions.push((await publishDay(a.user, a.device, back, 'retrospective', payload(back, 'retrospective', { input }))).context_revision);
      }
      assert.ok(abaRevisions[2] > abaRevisions[1] && abaRevisions[1] > abaRevisions[0], JSON.stringify(abaRevisions));
      assert.deepEqual(await sqlJson(`select json_agg(json_build_object('rev', context_revision, 'input', input_fingerprint,
          'superseded_by', superseded_by) order by context_revision) from public.physiology_context_days
          where user_id = '${a.user}' and day = '${back}'`), [
        { rev: abaRevisions[1], input: 'in-b', superseded_by: abaRevisions[2] },
        { rev: abaRevisions[2], input: 'in-a', superseded_by: null },
      ]);
      const day = addDays(await todayIn('UTC'), -9);
      const revisions: number[] = [];
      for (const input of ['in-a', 'in-b', 'in-c', 'in-a']) {
        const result = await publishDay(a.user, a.device, day, 'retrospective', payload(day, 'retrospective', { input }));
        assert.equal(result.applied, true, input);
        revisions.push(result.context_revision);
      }
      assert.deepEqual([...revisions].sort((x, y) => x - y), revisions, 'revisions increase');
      const rows = await sqlJson(`select json_agg(json_build_object('rev', context_revision, 'input', input_fingerprint,
          'superseded_by', superseded_by) order by context_revision) from public.physiology_context_days
          where user_id = '${a.user}' and day = '${day}'`);
      assert.deepEqual(rows, [
        { rev: revisions[2], input: 'in-c', superseded_by: revisions[3] },
        { rev: revisions[3], input: 'in-a', superseded_by: null },
      ]);
    });

    await t.step('episodes: only the latest published day (or a newer one) replaces the set; frozen references are insert-only', async () => {
      const a = await owner('UTC');
      const today = await todayIn('UTC');
      const newer = addDays(today, -3);
      const older = addDays(today, -4);
      const episodes = async () => await sqlJson(`select json_agg(episode_id || '@' || to_char(as_of_day, 'YYYY-MM-DD')
        order by episode_id) from public.physiology_context_episodes where user_id = '${a.user}'`);
      await publishDay(a.user, a.device, newer, 'retrospective', payload(newer, 'retrospective', {
        episodes: [episode('ep-new-1', newer), episode('ep-new-2', newer)], frozen: [frozen('fr-1', newer)] }));
      const late = await publishDay(a.user, a.device, older, 'retrospective', payload(older, 'retrospective', {
        episodes: [episode('ep-old', older)], frozen: [frozen('fr-1', older, { center: 9.9 }), frozen('fr-2', older, { version: 2 })] }));
      assert.equal(late.episodes_replaced, false);
      assert.deepEqual(await episodes(), [`ep-new-1@${newer}`, `ep-new-2@${newer}`]);
      assert.equal(late.frozen_references_inserted, 1, 'fr-1 already exists; only fr-2 is new');
      assert.equal(await sql(`select center from public.physiology_context_frozen_references where user_id = '${a.user}' and reference_id = 'fr-1'`), '3.7');
      // The same (series, regime, version) under a new id is also left alone.
      const sameVersion = await publishDay(a.user, a.device, newer, 'retrospective', payload(newer, 'retrospective', {
        input: 'in-2', episodes: [episode('ep-new-3', newer)], frozen: [frozen('fr-3', newer)] }));
      assert.deepEqual([sameVersion.episodes_replaced, sameVersion.frozen_references_inserted], [true, 0]);
      assert.deepEqual(await episodes(), [`ep-new-3@${newer}`]);
      await sqlFails(`update public.physiology_context_frozen_references set center = 1 where user_id = '${a.user}'`,
        /physiology_context_frozen_references_immutable/);
      // Modes are separate keys: a causal publish of today does not touch the retrospective episodes.
      await publishDay(a.user, a.device, today, 'causal_live', payload(today, 'causal_live', { episodes: [episode('ep-live', today)] }));
      assert.deepEqual(await episodes(), [`ep-live@${today}`, `ep-new-3@${newer}`]);
    });

    await t.step('cross-day cascade: changed retrospective values bump D+1 .. min(today - 1, D + 28); unchanged values do not', async () => {
      const a = await owner('UTC');
      const today = await todayIn('UTC');
      const d = addDays(today, -40);
      for (let k = 1; k <= 39; k++) await completedJob(a.user, a.device, addDays(d, k), 'retrospective');
      await completedJob(a.user, a.device, today, 'causal_live');
      const first = await publishDay(a.user, a.device, d, 'retrospective', payload(d, 'retrospective'));
      assert.equal(first.cascaded_days, 28);
      const bumped = await sqlJson(`select json_agg(to_char(day, 'YYYY-MM-DD') order by day) from public.physiology_context_jobs
        where user_id = '${a.user}' and mode = 'retrospective' and completed_revision < input_revision`);
      assert.deepEqual(bumped, Array.from({ length: 28 }, (_, index) => addDays(d, index + 1)));
      assert.deepEqual((await job(a.user, a.device, addDays(d, 1), 'retrospective')).reasons, ['history_changed']);
      // Same values, different document: no cascade.
      await sql(`update public.physiology_context_jobs set completed_revision = input_revision where user_id = '${a.user}'`);
      const same = await publishDay(a.user, a.device, d, 'retrospective', payload(d, 'retrospective', { input: 'in-2' }));
      assert.deepEqual([same.applied, same.daily_values_changed, same.cascaded_days], [true, false, 0]);
      // Near today the horizon stops at yesterday and never reaches today's live job.
      const near = addDays(today, -3);
      const result = await publishDay(a.user, a.device, near, 'retrospective', payload(near, 'retrospective', {
        values: [dailyValue(near, 'retrospective', 'hrv_rmssd.sleep_night', 50)] }));
      assert.equal(result.cascaded_days, 2);
      assert.equal((await job(a.user, a.device, today, 'causal_live')).completed_revision, 1);
      assert.equal(await count('physiology_context_jobs', `user_id = '${a.user}' and completed_revision < input_revision`), 2);
      // A causal publish never cascades.
      const live = await publishDay(a.user, a.device, today, 'causal_live', payload(today, 'causal_live', {
        values: [dailyValue(today, 'causal_live', 'hrv_rmssd.sleep_night', 99)] }));
      assert.deepEqual([live.daily_values_changed, live.cascaded_days], [true, 0]);
    });

    await t.step('read: status none / pending / available, mode choice, metric filter, document sizes and snapshot pairing', async () => {
      const a = await owner('UTC');
      const b = await owner('UTC');
      const day = addDays(await todayIn('UTC'), -2);
      let context = await read(a.user, a.device, day);
      assert.deepEqual([context.status, context.mode, context.document, context.job, context.pairing.consistent],
        ['none', 'causal_live', null, null, false]);
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'test', null)`);
      context = await read(a.user, a.device, day);
      assert.deepEqual([context.status, context.mode, context.job.pending], ['pending', 'retrospective', true]);
      const claimed = await claimJob(a.user, a.device, day, 'retrospective');
      await publish(claimed.lease_token, claimed.input_revision, payload(day, 'retrospective', { scoringResult: 1 }));
      // The newest snapshot of the day decides the pairing.
      await sql(`begin;
        alter table public.scoring_snapshots_v2 disable trigger scoring_history_publication_v3;
        insert into public.scoring_snapshots_v2(user_id, device_id, day, algorithm_version, input_revision, computed_at, payload)
          values ('${a.user}', '${a.device}', '${day}', 'frwhoop-server-1', 1, now(), '{}');
        alter table public.scoring_snapshots_v2 enable trigger scoring_history_publication_v3;
        commit;`);
      const snapshot = Number(await sql(`select max(result_revision) from public.scoring_snapshots_v2 where user_id = '${a.user}'`));
      context = await read(a.user, a.device, day);
      assert.deepEqual([context.status, context.mode, context.available_modes, context.job.pending],
        ['available', 'retrospective', ['retrospective'], false]);
      assert.deepEqual(context.pairing, { snapshot_result_revision: snapshot, context_scoring_result_revision: 1, consistent: snapshot === 1 });
      const paired = await publishDay(a.user, a.device, day, 'retrospective', payload(day, 'retrospective', { scoringResult: snapshot }));
      assert.equal(paired.reason, 'unchanged');
      context = await read(a.user, a.device, day, null, 'hrv_rmssd');
      assert.equal(context.pairing.consistent, true);
      assert.deepEqual(context.document.envelopes.map((row: any) => row.id), ['hrv@1-2', 'hrv@3-4']);
      assert.deepEqual([context.envelope_count, context.returned_envelope_count], [3, 2]);
      assert.ok(context.returned_document_bytes < context.document_bytes && context.document_bytes > 0);
      assert.equal(context.header.input_fingerprint, 'in-1');
      assert.equal((await read(a.user, a.device, day, null, 'spo2_candidate')).document.envelopes.length, 0);
      // A causal document of the same day is a separate row, never presented as the retrospective one.
      await publishDay(a.user, a.device, day, 'causal_live', payload(day, 'causal_live', { input: 'live-1' }));
      assert.deepEqual((await read(a.user, a.device, day)).available_modes, ['causal_live', 'retrospective']);
      assert.equal((await read(a.user, a.device, day)).mode, 'retrospective');
      assert.equal((await read(a.user, a.device, day, 'causal_live')).header.input_fingerprint, 'live-1');
      // A pending recomputation still serves the current document, marked pending.
      await sql(`select internal.physiology_context_touch('${a.user}', '${a.device}', '${day}', 'retrospective', 'exposure_changed', null)`);
      context = await read(a.user, a.device, day);
      assert.deepEqual([context.status, context.context_revision != null, context.job.reasons], ['pending', true, ['exposure_changed']]);
      // Another owner's device, bad arguments and a retired owner are refused.
      await sqlFails(`select public.physiology_context_read_v1('${b.user}', '${a.device}', '${day}', null, null)`, /device_owner_mismatch/);
      await sqlFails(`select public.physiology_context_read_v1('${a.user}', '${a.device}', '${day}', 'live', null)`, /invalid_mode/);
      await sqlFails(`select public.physiology_context_read_v1('${a.user}', '${a.device}', '${day}', null, 'HRV')`, /invalid_metric/);
      await sql(`insert into public.noop_account_retirements(user_id) values ('${b.user}')`);
      await sqlFails(`select public.physiology_context_read_v1('${b.user}', '${b.device}', '${day}', null, null)`, /account_retired/);
      await sql(`delete from public.noop_account_retirements where user_id = '${b.user}'`);
    });

    await t.step('history read: at most 120 days of the exact published items, per mode', async () => {
      const a = await owner('UTC');
      const today = await todayIn('UTC');
      const d1 = addDays(today, -5);
      const d2 = addDays(today, -4);
      await publishDay(a.user, a.device, d1, 'retrospective', payload(d1, 'retrospective', {
        bouts: [bout('bout-a', d1, 1_791_000_000)], frozen: [frozen('fr-h', d1)] }));
      await publishDay(a.user, a.device, d2, 'retrospective', payload(d2, 'retrospective', {
        episodes: [episode('ep-h', d1, { last_day: d2, duration_days: 2 })] }));
      const history = await sqlJson(`select public.physiology_context_history_read_v1('${a.user}', '${a.device}', '${addDays(today, -119)}', '${today}', null)`);
      assert.equal(history.mode, 'retrospective');
      assert.deepEqual(history.days.map((row: any) => row.day), [d1, d2]);
      assert.deepEqual(history.daily_values.map((row: any) => row.day), [d1, d2]);
      assert.deepEqual(history.daily_values[0], dailyValue(d1, 'retrospective'), 'items come back exactly as published');
      assert.deepEqual(history.bouts, [bout('bout-a', d1, 1_791_000_000)]);
      assert.deepEqual(history.episodes.map((row: any) => row.id), ['ep-h']);
      assert.deepEqual(history.episodes_as_of.day, d2);
      assert.deepEqual(history.frozen_references, [frozen('fr-h', d1)]);
      assert.equal(history.pending_days, 0);
      const live = await sqlJson(`select public.physiology_context_history_read_v1('${a.user}', '${a.device}', '${d1}', '${d2}', 'causal_live')`);
      assert.deepEqual([live.days, live.daily_values, live.bouts], [[], [], []]);
      await sqlFails(`select public.physiology_context_history_read_v1('${a.user}', '${a.device}', '${addDays(today, -120)}', '${today}', null)`, /invalid_range/);
      await sqlFails(`select public.physiology_context_history_read_v1('${a.user}', '${a.device}', '${today}', '${d1}', null)`, /invalid_range/);
    });

    await t.step('placement: a declaration invalidates its device (or every device) from its local day through today; set_placement_interval keeps working for clients', async () => {
      const a = await owner('UTC', 2);
      const today = await todayIn('UTC');
      for (const device of a.devices) {
        for (let k = 0; k <= 6; k++) await scored(a.user, device, addDays(today, -k));
      }
      await sql(`update public.physiology_context_jobs set completed_revision = input_revision where user_id = '${a.user}'`);
      const touched = async () => await sqlJson(`select coalesce(json_agg(json_build_object('device', device_id, 'day', to_char(day, 'YYYY-MM-DD'),
          'mode', mode) order by device_id, day), '[]') from public.physiology_context_jobs where user_id = '${a.user}'
          and 'placement_changed' = any (reasons)`);
      // Device-scoped declaration three days ago, through the client path (PostgREST as the owner).
      const reply = await call(signJwt('authenticated', a.user), 'POST', 'rpc/set_placement_interval', {
        p_owner: a.user, p_placement: 'bicep', p_effective_start: `${addDays(today, -3)}T12:00:00Z`, p_device: a.devices[0],
      });
      assert.equal(reply.status, 200, JSON.stringify(reply.body));
      assert.deepEqual((await touched()).map((row: any) => [row.device, row.day, row.mode]), [
        [a.devices[0], addDays(today, -3), 'retrospective'], [a.devices[0], addDays(today, -2), 'retrospective'],
        [a.devices[0], addDays(today, -1), 'retrospective'], [a.devices[0], today, 'causal_live'],
      ].sort((x, y) => `${x[0]}${x[1]}`.localeCompare(`${y[0]}${y[1]}`)));
      // A user-level declaration reaches every device of the owner; a correction (close + insert) works.
      await sql(`update public.physiology_context_jobs set reasons = '{}', completed_revision = input_revision where user_id = '${a.user}'`);
      await sql(`select public.set_placement_interval('${a.user}', 'wrist', '${addDays(today, -1)}T08:00:00Z'::timestamptz)`);
      await sql(`select public.set_placement_interval('${a.user}', 'other', '${today}T00:30:00Z'::timestamptz)`);
      const both = await touched();
      assert.deepEqual(new Set(both.map((row: any) => row.device)), new Set(a.devices));
      assert.deepEqual(both.filter((row: any) => row.device === a.devices[1]).map((row: any) => row.day), [addDays(today, -1), today]);
      // Future-dated: accepted, nothing to invalidate yet.
      await sql(`update public.physiology_context_jobs set reasons = '{}' where user_id = '${a.user}'`);
      const future = await call(signJwt('authenticated', a.user), 'POST', 'rpc/set_placement_interval', {
        p_owner: a.user, p_placement: 'wrist', p_effective_start: `${addDays(today, 5)}T00:00:00Z`,
      });
      assert.equal(future.status, 200, JSON.stringify(future.body));
      assert.deepEqual(await touched(), []);
      // Very old corrections are capped at the most recent 120 days.
      await scored(a.user, a.devices[1], addDays(today, -119));
      await scored(a.user, a.devices[1], addDays(today, -125));
      await sql(`select public.set_placement_interval('${a.user}', 'bicep', '${addDays(today, -300)}T00:00:00Z'::timestamptz, '${a.devices[1]}')`);
      const capped = (await touched()).map((row: any) => row.day);
      assert.ok(capped.includes(addDays(today, -119)) && !capped.includes(addDays(today, -125)), JSON.stringify(capped));
      // The invalidation RPC refuses another owner's device and bad spans.
      const b = await owner('UTC');
      await sqlFails(`select public.invalidate_physiology_context_span_v1('${b.user}', '${a.device}', '${today}', '${today}', 'x')`, /device_owner_mismatch/);
      await sqlFails(`select public.invalidate_physiology_context_span_v1('${a.user}', null, '${today}', '${addDays(today, -1)}', 'x')`, /invalid_span/);
      await sqlFails(`select public.invalidate_physiology_context_span_v1('${a.user}', null, '${today}', '${today}', 'Bad Reason')`, /invalid_reason/);
      assert.equal(await sql(`select public.invalidate_physiology_context_span_v1('${b.user}', null, '${today}', '${today}', 'x')`), '0',
        'a device without data on the day has nothing to invalidate');
    });

    await t.step('owner isolation through PostgREST: own rows only, no writes, no RPCs', async () => {
      const a = await owner('UTC');
      const b = await owner('UTC');
      const day = addDays(await todayIn('UTC'), -3);
      for (const who of [a, b]) {
        await publishDay(who.user, who.device, day, 'retrospective', payload(day, 'retrospective', {
          bouts: [bout(`bout-${who.user}`, day, 1_791_000_000)], episodes: [episode(`ep-${who.user}`, day)],
          frozen: [frozen(`fr-${who.user}`, day)] }));
        await sql(`select public.record_exposure_event_v1('${who.user}', null, $pc$${JSON.stringify({
          event_id: `ev-${who.user.slice(0, 8)}`, revision: 1, kind: 'caffeine', label: 'Coffee',
          occurred: { start: 1_791_000_000, end: 1_791_000_001 }, time_precision: 'exact', recorded_at: 1_791_000_100,
          source: 'user_entered', confirmation: 'confirmed' })}$pc$::jsonb)`);
      }
      const jwtA = signJwt('authenticated', a.user);
      for (const table of OWNER_READABLE) {
        const column = table.startsWith('exposure') ? 'owner' : 'user_id';
        const mine = await call(jwtA, 'GET', `${table}?select=${column}`);
        assert.equal(mine.status, 200, `${table}: ${JSON.stringify(mine.body)}`);
        assert.ok(mine.body.length >= 1, `${table}: A sees its own rows`);
        assert.ok(mine.body.every((row: any) => row[column] === a.user), `${table}: A saw another account's rows`);
        const theirs = await call(jwtA, 'GET', `${table}?${column}=eq.${b.user}&select=${column}`);
        assert.deepEqual(theirs.body, [], `${table}: A read B's rows`);
        const anon = await call(null, 'GET', `${table}?select=${column}`);
        assert.ok(refused(anon) || (anon.status === 200 && anon.body.length === 0), `${table}: anon read rows`);
        for (const [method, path, body] of [['POST', table, { [column]: a.user }], ['PATCH', `${table}?${column}=eq.${a.user}`, { [column]: b.user }],
          ['DELETE', `${table}?${column}=eq.${a.user}`, undefined]] as Array<[string, string, unknown]>) {
          const write = await call(jwtA, method, path, body);
          assert.ok(refused(write), `${table}: ${method} answered ${write.status}`);
        }
      }
      assert.ok(refused(await call(jwtA, 'GET', 'physiology_context_jobs?select=user_id')), 'the queue is service-only');
      for (const name of Object.keys(FUNCTIONS)) {
        for (const token of [jwtA, null]) {
          const reply = await call(token, 'POST', `rpc/${name}`, {});
          assert.ok(refused(reply) || reply.status === 404, `${name} answered a client (${reply.status})`);
        }
      }
      const forged = await call(jwtA, 'POST', 'rpc/physiology_context_read_v1', { p_user: b.user, p_device: b.device, p_day: day });
      assert.ok(refused(forged) || forged.status === 404, `read as another owner answered ${forged.status}`);
    });

    await t.step('the real scores handler on this database: context, history and exposures for an installation', async () => {
      const a = await owner('UTC');
      const source = crypto.randomUUID();
      const token = `noop_pc_${crypto.randomUUID()}`;
      const external = `whoop-PC0${a.user.slice(0, 8).toUpperCase()}`;
      await sql(`insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
          values ('${source}', '${a.user}', 'ios', '1.0 (1)', 'supabase_auth');
        insert into public.noop_ingest_tokens(user_id, token_hash, token_kind, source_id, provisioning_method)
          values ('${a.user}', '${hashIngestToken(token)}', 'installation', '${source}', 'supabase_auth');`);
      const rest = createSupabaseRest({
        cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
        fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(15000) }),
      });
      const cfg = { supabaseUrl: 'https://project.test', supabaseAnonKey: 'sb_publishable_test' };
      const send = (path: string, method = 'GET', body?: unknown) => handleScoresRequest(new Request(
        `https://project.test/functions/v1/scores${path}`, { method, headers: { authorization: `Bearer ${token}`,
          'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) }), { rest, cfg });
      const today = await todayIn('UTC');
      const day = addDays(today, -1);
      await scored(a.user, a.device, day);
      let response = await send(`/context?deviceId=${external}&day=${day}`);
      assert.equal(response.status, 200);
      let body = await response.json();
      assert.deepEqual([body.context.status, body.identity.userId, body.identity.deviceId], ['none', a.user, a.device]);
      await publishDay(a.user, a.device, day, 'retrospective', payload(day, 'retrospective', { bouts: [bout('bout-r', day, 1_791_000_000)] }));
      response = await send(`/context?deviceId=${external}&day=${day}&metric=hrv_rmssd`);
      body = await response.json();
      assert.deepEqual([body.context.status, body.context.mode, body.context.returned_envelope_count], ['available', 'retrospective', 2]);
      response = await send(`/context/history?deviceId=${external}&from=${addDays(today, -30)}&to=${today}`);
      body = await response.json();
      assert.deepEqual([response.status, body.history.bouts.map((row: any) => row.id)], [200, ['bout-r']]);
      const occurred = await sqlJson(`select extract(epoch from ('${day}'::timestamp at time zone 'UTC'))::bigint + 7200`);
      response = await send('/exposures', 'POST', { events: [
        { event_id: 'caf-route-1', revision: 1, kind: 'caffeine', label: 'Espresso', occurred: { start: occurred, end: occurred + 1 },
          time_precision: 'exact', recorded_at: occurred + 5, source: 'user_entered', confirmation: 'confirmed',
          dose_amount: 63, dose_unit: 'mg', dose_provenance: 'user_entered' },
        { event_id: 'bad', revision: 1, kind: 'caffeine', label: '', occurred: { start: occurred, end: occurred + 1 },
          time_precision: 'exact', recorded_at: occurred, source: 'user_entered', confirmation: 'confirmed' },
      ] });
      body = await response.json();
      assert.equal(response.status, 200, JSON.stringify(body));
      assert.deepEqual(body.results.map((row: any) => [row.event_id, row.status, row.reason]),
        [['caf-route-1', 'saved', null], ['bad', 'rejected', 'invalid_label']]);
      assert.ok(Number.isSafeInteger(body.results[0].received_at));
      assert.equal(await sql(`select upload_source_id from public.exposure_event_revisions where owner = '${a.user}'`), source);
      assert.deepEqual((await job(a.user, a.device, day, 'retrospective')).reasons, ['exposure_changed']);
      response = await send(`/exposures?from=${occurred - 10}&to=${occurred + 10}&history=1`);
      body = await response.json();
      assert.deepEqual([response.status, body.events.map((row: any) => row.event_id), body.revisions.length], [200, ['caf-route-1'], 1]);
      response = await send(`/context?deviceId=whoop-NOTMINE00001&day=${day}`);
      assert.equal(response.status, 409);
    });

    await t.step('deleting a device or the account removes every row, frozen references and exposure history included', async () => {
      const a = await owner('UTC', 2);
      const day = addDays(await todayIn('UTC'), -2);
      for (const device of a.devices) {
        await scored(a.user, device, day);
        await publishDay(a.user, device, day, 'retrospective', payload(day, 'retrospective', {
          bouts: [bout(`bout-${device}`, day, 1_791_000_000)], episodes: [episode(`ep-${device}`, day)],
          frozen: [frozen(`fr-${device}`, day)] }));
      }
      await sql(`select public.set_placement_interval('${a.user}', 'wrist', now() - interval '1 day', '${a.devices[1]}')`);
      await sql(`select public.record_exposure_event_v1('${a.user}', null, $pc$${JSON.stringify({
        event_id: 'ev-del', revision: 1, kind: 'meal', label: 'Dinner', occurred: { start: 1_791_000_000, end: 1_791_003_600 },
        time_precision: 'approximate', recorded_at: 1_791_004_000, source: 'user_entered', confirmation: 'confirmed' })}$pc$::jsonb)`);
      await sql(`select public.record_exposure_event_v1('${a.user}', null, $pc$${JSON.stringify({
        event_id: 'ev-del', revision: 2, kind: 'meal', label: 'Dinner', occurred: { start: 1_791_000_000, end: 1_791_003_600 },
        time_precision: 'approximate', recorded_at: 1_791_005_000, source: 'user_entered', confirmation: 'retracted' })}$pc$::jsonb)`);
      // Device deletion: that device's context rows go; the placement row keeps its history with no device.
      await sql(`delete from public.devices where id = '${a.devices[1]}'`);
      for (const table of TABLES.filter((name) => name.startsWith('physiology'))) {
        assert.equal(await count(table, `device_id = '${a.devices[1]}'`), 0, table);
        assert.ok(await count(table, `device_id = '${a.devices[0]}'`) >= 1, table);
      }
      assert.equal(await count('placement_intervals', `owner = '${a.user}' and device_id is null`), 1);
      // Account deletion: everything goes, through the foreign keys, immutable rows included.
      assert.equal(await count('exposure_event_revisions', `owner = '${a.user}'`), 2);
      await sql(`delete from auth.users where id = '${a.user}'`);
      for (const table of TABLES) {
        const column = table.startsWith('exposure') ? 'owner' : 'user_id';
        assert.equal(await count(table, `${column} = '${a.user}'`), 0, `${table} kept the deleted account's rows`);
      }
    });

    await sql(`delete from auth.users where email like '${EMAIL_PREFIX}%'`);
  },
});
