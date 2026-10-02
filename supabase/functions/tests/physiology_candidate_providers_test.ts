// Candidate provider lane (spec 4/6/7): native SQL proof on a disposable local PostgreSQL.
//
// Fixture-free. This suite builds its own cluster on a private Unix socket, so it opens no TCP
// port and cannot collide with a running local stack. It never accepts a database URL, an
// environment file or a production credential, and it applies the actual prerequisite
// migrations plus 20261002090000_physiology_candidate_providers.sql before asserting behaviour.
//
//   cd supabase/functions
//   deno test --allow-env --allow-read --allow-write=/tmp \
//     --allow-run=/opt/homebrew/bin/initdb,/opt/homebrew/bin/pg_ctl,/opt/homebrew/bin/psql \
//     tests/physiology_candidate_providers_test.ts
//
// EDGE_TEST_PG_BIN may name a keg directory holding initdb/pg_ctl/psql.
// EDGE_TEST_ARTIFACTS may name an existing absolute directory outside the checkout to hold the
// cluster, its logs and the evidence file; otherwise a temporary directory is used.
//
// Scope: this proves the candidate lane's SQL contract, including the active-mode promotion
// gate, which is validated against the repository's real signed-promotion objects
// (internal.physiology_approval_valid, physiology_promotion_approvals,
// physiology_promotion_revocations, internal.physiology_approval_keys), and the per-stream
// staleness trigger mapping (13 streams, each with its real start/end time columns). It does not
// prove deployed Supabase version behaviour, provider accuracy, or that any metric is enabled
// anywhere.

import { assert, assertEquals, assertMatch, assertStringIncludes } from 'jsr:@std/assert';

const decoder = new TextDecoder();
const CANDIDATE_MIGRATION = '20261002090000_physiology_candidate_providers.sql';
// The actual prerequisite lineage for this lane, applied in dependency order. The house harness
// applies a curated subset for the same reason: filename order alone cannot satisfy
// object_manifests.durability_receipt, which is added after 20260918040000.
const PREREQUISITE_MIGRATIONS = [
  '20260819190000_frwhoop_base_schema.sql',
  // Creates sessions.device_id (nullable, ON DELETE SET NULL) and object_manifests.
  '20260824180000_production_persistence.sql',
  '20260907133000_noop_hr_samples.sql',
  '20260907133100_noop_append_stream_projections.sql',
  // Creates noop_signal_windows (start_ts/end_ts) and noop_event_labels (start_ts/end_ts).
  '20260907170000_noop_raw_object_lane.sql',
  '20260911120000_noop_remaining_append_projections.sql',
  '20260916160000_scoring_service_state.sql',
  '20260916170000_scoring_work_items_device_id.sql',
  '20260918010000_production_scoring_durability.sql',
  // The signed-promotion surface the active-mode gate is validated against.
  '20260918020000_physiology_publication.sql',
  // Creates noop_step_samples (ts).
  '20260918050000_production_scoring_history.sql',
  '20260918230000_physiology_signed_promotion.sql',
];
// Every stream this subset creates, so each must receive the third, candidate-only trigger family.
// noop_event_labels and noop_signal_windows carry start_ts/end_ts rather than ts, and sessions
// carries start_at/end_at; the D1 regression step below is what catches a mis-mapped column.
const EXPECTED_STREAM_TABLES = [
  'noop_event_labels', 'noop_events', 'noop_gravity_samples', 'noop_hr_samples',
  'noop_ppg_hr_samples', 'noop_resp_samples', 'noop_rr_intervals', 'noop_signal_windows',
  'noop_skin_temp_samples', 'noop_sleep_state_samples', 'noop_spo2_samples', 'noop_step_samples',
  'sessions',
];
// The exact per-table start/end time columns the migration maps, asserted as trigger arguments.
const EXPECTED_TRIGGER_ARGS: Record<string, [string, string]> = {
  noop_event_labels: ['start_ts', 'end_ts'],
  noop_events: ['ts', 'ts'],
  noop_gravity_samples: ['ts', 'ts'],
  noop_hr_samples: ['ts', 'ts'],
  noop_ppg_hr_samples: ['ts', 'ts'],
  noop_resp_samples: ['ts', 'ts'],
  noop_rr_intervals: ['ts', 'ts'],
  noop_signal_windows: ['start_ts', 'end_ts'],
  noop_skin_temp_samples: ['ts', 'ts'],
  noop_sleep_state_samples: ['ts', 'ts'],
  noop_spo2_samples: ['ts', 'ts'],
  noop_step_samples: ['ts', 'ts'],
  sessions: ['start_at', 'end_at'],
};
const RECORD_SIGNATURE = 'public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,' +
  'timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,' +
  'jsonb,integer)';
const CANDIDATE_TABLES = [
  'physiology_backfill_jobs', 'physiology_candidate_debt', 'physiology_candidate_results',
  'physiology_provider_defaults', 'physiology_provider_overrides',
];

const USER_A = '11111111-1111-4111-8111-111111111111';
const USER_B = '22222222-2222-4222-8222-222222222222';
const USER_C = '33333333-3333-4333-8333-333333333333';
const USER_D = '44444444-4444-4444-8444-444444444444';
const DEV_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const DEV_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const DEV_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DEV_D = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const DAY = '2026-09-30';
const SHA_A = 'a'.repeat(64);
const SHA_B = 'b'.repeat(64);
const SHA_C = 'c'.repeat(64);
const SHA_F = 'f'.repeat(64);
const PROVIDER = { id: 'hrv-production', version: 'runs.v1', config: 'cfg-1' };
const USER_E = '55555555-5555-4555-8555-555555555555';
const DEV_E = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const RESP_PROVIDER = 'resp-provider';
const RESP_CONFIG = 'resp-c1';
const SIGNING_SECRET = 'frwhoop-candidate-test-signing-key-0123456789';
const SIGNING_REVIEWER = 'w-b test reviewer';

const lit = (value: string) => `'${value.replaceAll("'", "''")}'`;
const checkoutRoot = decodeURIComponent(new URL('../../../', import.meta.url).pathname).replace(/\/$/, '');

type Harness = {
  base: string;
  sql: (statement: string) => Promise<string>;
  sqlError: (statement: string) => Promise<string | null>;
  applyMigration: (file: string) => Promise<string>;
  close: () => Promise<void>;
};

async function startDisposablePostgres(): Promise<Harness> {
  const bin = Deno.env.get('EDGE_TEST_PG_BIN') ?? '/opt/homebrew/bin';
  const parent = Deno.env.get('EDGE_TEST_ARTIFACTS') ?? '/tmp';
  assert(parent.startsWith('/'), 'the cluster parent must be an absolute path');
  assert(
    parent !== checkoutRoot && !parent.startsWith(`${checkoutRoot}/`),
    'the cluster must live outside the checkout',
  );
  const base = await Deno.makeTempDir({ dir: parent, prefix: 'frwhoop-candidate-pg' });
  // macOS caps a Unix socket path at 103 bytes, including the socket file name.
  assert(
    new TextEncoder().encode(`${base}/.s.PGSQL.5432`).length <= 103,
    'the cluster path is too long for a PostgreSQL Unix socket',
  );
  const data = `${base}/data`;
  const env = { PATH: `${bin}:/usr/bin:/bin`, TMPDIR: base, LC_ALL: 'C' };
  let started = false;
  const logs: string[] = [];

  async function run(executable: string, args: string[]): Promise<string> {
    const result = await new Deno.Command(executable, {
      args, env, clearEnv: true, stdout: 'piped', stderr: 'piped',
    }).output();
    const out = decoder.decode(result.stdout);
    const errText = decoder.decode(result.stderr);
    logs.push(`${executable.split('/').pop()} ${args[0]}: ${out}${errText}`);
    if (!result.success) throw new Error(`${executable.split('/').pop()} failed: ${errText.slice(-2000)}`);
    return out.trim();
  }
  const psqlArgs = (args: string[]) => ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', base, '-U', 'edge_test', '-d', 'postgres', ...args];
  const sql = (statement: string) => run(`${bin}/psql`, psqlArgs(['-c', statement]));
  async function sqlError(statement: string): Promise<string | null> {
    const result = await new Deno.Command(`${bin}/psql`, {
      args: psqlArgs(['-c', statement]), env, clearEnv: true, stdout: 'piped', stderr: 'piped',
    }).output();
    if (result.success) return null;
    const errText = decoder.decode(result.stderr);
    for (const line of errText.split('\n')) if (line.startsWith('ERROR:')) return line.trim();
    return errText.trim().split('\n')[0] ?? 'unknown error';
  }
  const applyMigration = (file: string) =>
    run(`${bin}/psql`, psqlArgs(['-1', '-f', `${checkoutRoot}/supabase/migrations/${file}`]));
  const close = async () => {
    if (started) await run(`${bin}/pg_ctl`, ['-D', data, '-m', 'fast', '-w', 'stop']).catch(() => '');
    await Deno.writeTextFile(`${base}/harness.log`, logs.join('\n'));
  };

  try {
    await run(`${bin}/initdb`, ['-D', data, '-U', 'edge_test', '--auth-local=trust',
      '--auth-host=reject', '--no-locale', '--encoding=UTF8']);
    const socketDirectory = `'${base.replaceAll("'", "'\\''")}'`;
    // listen_addresses='' keeps the cluster off every TCP port.
    await run(`${bin}/pg_ctl`, ['-D', data, '-l', `${base}/postgres.log`, '-o',
      `-k ${socketDirectory} -c listen_addresses='' -c unix_socket_permissions=0700 -c max_connections=30`,
      '-w', 'start']);
    started = true;
    await sql(`
      create role postgres nologin; create role anon nologin; create role authenticated nologin;
      create role service_role nologin bypassrls; create role authenticator login noinherit;
      grant anon,authenticated,service_role to authenticator;
      create schema auth; create schema extensions;
      create publication supabase_realtime;
      create table auth.users (id uuid primary key, raw_user_meta_data jsonb default '{}'::jsonb, email text);
      create function auth.uid() returns uuid language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
          nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
      create function auth.role() returns text language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
          nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_user::text) $$;
      grant usage on schema public,auth,extensions to anon,authenticated,service_role;
      alter default privileges in schema public grant all on tables to service_role;
      alter default privileges in schema public grant all on sequences to service_role;
    `);
    for (const migration of [...PREREQUISITE_MIGRATIONS, CANDIDATE_MIGRATION]) await applyMigration(migration);
    return { base, sql, sqlError, applyMigration, close };
  } catch (error) {
    await close();
    throw error;
  }
}

/** Call the candidate write RPC with named arguments, as PostgREST would. */
function recordCandidate(overrides: Record<string, string> = {}): string {
  const named: Record<string, string> = {
    p_user: lit(USER_A), p_device: lit(DEV_A), p_metric: lit('hrv'), p_period_day: lit(DAY),
    p_interval_start_at: lit('2026-09-30 00:00:00+00'), p_interval_end_at: lit('2026-09-30 00:05:00+00'),
    p_input_sha256: lit(SHA_A), p_input_revision: '1', p_provider_id: lit(PROVIDER.id),
    p_provider_version: lit(PROVIDER.version), p_adapter_version: lit('adapter-1'),
    p_preprocessing_version: lit('prep-1'), p_config_version: lit(PROVIDER.config),
    p_status: lit('ok'), p_value: '42.5', p_unit: lit('ms'),
    ...overrides,
  };
  const args = Object.entries(named).map(([key, value]) => `${key} => ${value}`).join(', ');
  return `select coalesce(public.physiology_record_candidate_result(${args})::text, 'null')`;
}

/**
 * Insert a real signed promotion approval: signing key, algorithm version, feature manifest and
 * the HMAC-SHA256 signature over the exact payload bytes, using the same objects and the same
 * internal.physiology_approval_valid() liveness check the production promotion path uses.
 * Approvals and manifests are immutable, so every case needs its own version.
 */
function signedApprovalSql(options: {
  version: string; feature: string; approvalId: string; approvedAt: string; referenceKind: string;
}): string {
  const keyId = `encode(sha256(convert_to(${lit(SIGNING_SECRET)},'UTF8')),'hex')`;
  const algorithmManifest = `{"algorithm":"${options.version}"}`;
  return `
    insert into internal.physiology_approval_keys(key_id,secret,reviewer)
      values (${keyId}, convert_to(${lit(SIGNING_SECRET)},'UTF8'), ${lit(SIGNING_REVIEWER)})
      on conflict (key_id) do nothing;
    insert into public.physiology_algorithm_versions(algorithm_version,manifest,manifest_hash,
      computation_kind,qualification)
      values (${lit(options.version)}, ${lit(algorithmManifest)}::jsonb,
        encode(sha256(convert_to(${lit(algorithmManifest)},'UTF8')),'hex'),'deterministic','shadow');
    with m as (select jsonb_build_object(
        'algorithm_version',${lit(options.version)},'feature',${lit(options.feature)},
        'checkpoint_sha256',repeat('a',64),'preprocessing_version','prep-1',
        'preprocessing_sha256',repeat('b',64),'quality_policy_version','policy-1',
        'quality_policy_sha256',repeat('c',64)) as manifest)
    insert into public.physiology_feature_manifests(algorithm_version,feature,manifest,canonical_manifest,
      manifest_sha256,algorithm_manifest_sha256,checkpoint_sha256,preprocessing_version,preprocessing_sha256,
      quality_policy_version,quality_policy_sha256)
    select ${lit(options.version)},${lit(options.feature)},m.manifest,m.manifest::text,
      encode(sha256(convert_to(m.manifest::text,'UTF8')),'hex'),
      (select manifest_hash from public.physiology_algorithm_versions where algorithm_version=${lit(options.version)}),
      repeat('a',64),'prep-1',repeat('b',64),'policy-1',repeat('c',64) from m;
    with m as (select * from public.physiology_feature_manifests
        where algorithm_version=${lit(options.version)} and feature=${lit(options.feature)}),
      p as (select jsonb_build_object(
        'schema_version','1','purpose','physiology_feature_promotion',
        'approval_id',${lit(options.approvalId)},'key_id',${keyId},
        'reviewer',${lit(SIGNING_REVIEWER)},'decision','approved',
        'algorithm_version',${lit(options.version)},'feature',${lit(options.feature)},
        'manifest_sha256',m.manifest_sha256,'algorithm_manifest_sha256',m.algorithm_manifest_sha256,
        'checkpoint_sha256',m.checkpoint_sha256,'preprocessing_version',m.preprocessing_version,
        'preprocessing_sha256',m.preprocessing_sha256,'quality_policy_version',m.quality_policy_version,
        'quality_policy_sha256',m.quality_policy_sha256,
        'evaluation_sha256',repeat('d',64),'policy_sha256',repeat('e',64),
        'reference_artifact_sha256',repeat('f',64),
        'reference_kind',${lit(options.referenceKind)},'evaluation_partition','test',
        'participant_disjoint',true,'functional_gates_passed',true,'promotion_policy_passed',true,
        'policy_frozen_at','2026-01-01T00:00:00Z','evaluation_started_at','2026-01-02T00:00:00Z',
        'evaluation_finished_at','2026-01-03T00:00:00Z','approved_at',${lit(options.approvedAt)})::text
        as payload from m)
    insert into public.physiology_promotion_approvals(approval_id,algorithm_version,feature,key_id,
      signed_payload,signature_hex)
    select ${lit(options.approvalId)}::uuid,${lit(options.version)},${lit(options.feature)},k.key_id,
      p.payload, encode(extensions.hmac(convert_to(p.payload,'UTF8'),k.secret,'sha256'),'hex')
    from p join internal.physiology_approval_keys k on k.key_id=${keyId};
  `;
}

/** A respiration candidate call, so the promotion-gate steps never disturb the hrv fixture. */
function recordRespiration(version: string, sha: string, overrides: Record<string, string> = {}): string {
  return recordCandidate({
    p_user: lit(USER_E), p_device: lit(DEV_E), p_metric: lit('respiration'),
    p_provider_id: lit(RESP_PROVIDER), p_provider_version: lit(version),
    p_config_version: lit(RESP_CONFIG), p_input_sha256: lit(sha), p_value: '12', p_unit: lit('bpm'),
    ...overrides,
  });
}

Deno.test('candidate provider lane: SQL contract on a disposable local PostgreSQL', async (t) => {
  const pg = await startDisposablePostgres();
  const sql = pg.sql;
  let currentRevision = '0';
  let currentRevisionC = '0';

  try {
    await t.step('lineage applies with the lane dormant and no client policy', async () => {
      assertEquals(await sql(`select count(*)||'|'||count(*) filter (where mode='off') from public.physiology_provider_defaults`), '4|4');
      assertEquals(await sql(`select count(*) from pg_policies where schemaname='public' and tablename in ('${CANDIDATE_TABLES.join("','")}')`), '0');
      assertEquals(await sql(`select count(*) from pg_class where relnamespace='public'::regnamespace and relname in ('${CANDIDATE_TABLES.join("','")}') and relrowsecurity`), '5');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), '0');
      assertEquals(await sql(`select count(*) from public.physiology_backfill_jobs`), '0');
      assertEquals(await sql(`select string_agg(p.proname,',' order by p.proname) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('physiology_candidate_activation','physiology_candidate_feature','physiology_selected_provider','physiology_record_candidate_result','physiology_candidate_debt_read','physiology_backfill_claim','physiology_backfill_advance','physiology_backfill_finish')`), 'physiology_backfill_advance,physiology_backfill_claim,physiology_backfill_finish,physiology_candidate_activation,physiology_candidate_debt_read,physiology_candidate_feature,physiology_record_candidate_result,physiology_selected_provider');
    });

    await t.step('the staleness trigger family covers every input stream', async () => {
      assertEquals(await sql(`select string_agg(distinct c.relname, ',' order by c.relname) from pg_trigger g join pg_class c on c.oid=g.tgrelid where g.tgname like 'physiology_candidate_%' and not g.tgisinternal`), EXPECTED_STREAM_TABLES.join(','));
      assertEquals(await sql(`select count(*) from pg_trigger g where g.tgname like 'physiology_candidate_%' and not g.tgisinternal`), String(EXPECTED_STREAM_TABLES.length * 3));
      // Every covered table carries the ACTUAL start/end column pair as trigger arguments. A
      // wrong name (the D1 defect: noop_event_labels has start_ts/end_ts, not ts) would make the
      // trigger a silent no-op, so it is asserted table by table, not by count.
      for (const [table, [startColumn, endColumn]] of Object.entries(EXPECTED_TRIGGER_ARGS)) {
        assertEquals(await sql(`select distinct encode(tgargs,'escape') from pg_trigger where tgrelid=${lit(`public.${table}`)}::regclass and not tgisinternal and tgname like 'physiology_candidate_%'`), `${startColumn}\\000${endColumn}\\000`, table);
      }
      // The existing two families are untouched.
      assert(Number(await sql(`select count(*) from pg_trigger g where g.tgname like 'scoring_%_v2' and not g.tgisinternal`)) > 0);
      // Every covered table also has a resolvable start/end column, so the migration's own
      // guard (physiology_candidate_trigger_column_missing) would have fired otherwise.
      for (const [table, [startColumn, endColumn]] of Object.entries(EXPECTED_TRIGGER_ARGS)) {
        const expectedColumns = startColumn === endColumn ? '1' : '2';
        assertEquals(await sql(`select count(distinct a.attname) from pg_attribute a where a.attrelid=${lit(`public.${table}`)}::regclass and a.attname in (${lit(startColumn)},${lit(endColumn)}) and a.attnum>0 and not a.attisdropped`), expectedColumns, table);
      }
    });

    await t.step('an unconfigured metric resolves to mode off and records nothing', async () => {
      assertEquals(await sql(`select public.physiology_selected_provider(${lit(USER_A)},'hrv')->>'mode'`), 'off');
      assertEquals(await sql(recordCandidate()), 'null');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), '0');
    });

    await t.step('while every mode is off an input insert creates no staleness debt', async () => {
      await sql(`insert into auth.users(id) values (${lit(USER_A)}),(${lit(USER_B)}),(${lit(USER_C)}),(${lit(USER_D)}) on conflict (id) do nothing`);
      for (const [user, device] of [[USER_A, DEV_A], [USER_B, DEV_B], [USER_C, DEV_C], [USER_D, DEV_D]]) {
        // handle_new_user() already created the profile row for every inserted account.
        await sql(`insert into public.profiles(id,timezone) values (${lit(user)},'UTC') on conflict (id) do nothing`);
        await sql(`insert into public.devices(id,user_id,source_kind) values (${lit(device)},${lit(user)},'strap') on conflict (id) do nothing`);
      }
      const ts = await sql(`select extract(epoch from ${lit(`${DAY} 12:00:00+00`)}::timestamptz)::bigint`);
      await sql(`insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values (${lit(USER_A)},${lit(DEV_A)},${lit(DEV_A)},${ts},60,${lit(DEV_A)})`);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt`), '0');
    });

    await t.step('shadow mode records a candidate, then replays idempotently', async () => {
      await sql(`update public.physiology_provider_defaults set provider_id=${lit(PROVIDER.id)}, provider_version=${lit(PROVIDER.version)}, config_version=${lit(PROVIDER.config)}, mode='shadow', updated_at=clock_timestamp() where metric='hrv'`);
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_A)},'hrv')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_A)},'hrv')->>'source')`), 'shadow|default');
      // The same insert now dirties the candidate lane, and the canonical job advances with it.
      const ts = await sql(`select extract(epoch from ${lit(`${DAY} 13:00:00+00`)}::timestamptz)::bigint`);
      await sql(`insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values (${lit(USER_A)},${lit(DEV_A)},${lit(DEV_A)},${ts},61,${lit(DEV_A)})`);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(USER_A)} and device_id=${lit(DEV_A)} and day=${lit(DAY)}`), '1');
      assertStringIncludes(await sql(`select public.physiology_candidate_debt_read(${lit(USER_A)},${lit(DEV_A)},${lit(DAY)})::text`), '"debt": true');

      currentRevision = await sql(`select max(input_revision)::text from public.scoring_jobs_v2 where user_id=${lit(USER_A)} and day=${lit(DAY)}`);
      assertMatch(await sql(recordCandidate({ p_input_revision: currentRevision })), /^[0-9a-f-]{36}$/);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), '1');
      assertEquals(await sql(`select status||'|'||value||'|'||unit||'|'||provider_id||'|'||provider_version||'|'||config_version||'|'||metric from public.physiology_candidate_results`), `ok|42.5|ms|${PROVIDER.id}|${PROVIDER.version}|${PROVIDER.config}|hrv`);
      // Repeated upload/replay must not create a second result.
      assertEquals(await sql(recordCandidate({ p_input_revision: currentRevision })), 'null');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), '1');
    });

    await t.step('D1/D2/D5 regression: every covered stream marks candidate staleness', async () => {
      // The lane is open (hrv is shadow from the previous step). Each insert targets a brand-new
      // day so a working trigger MUST add debt rows; a silently skipped stream adds none.
      // A dedicated owner keeps USER_A's deletion path (see the later step) free of sessions rows:
      // deleting an owner that has sessions trips a pre-existing user_sync_state FK in this repo.
      const streamUser = crypto.randomUUID();
      await sql(`insert into auth.users(id) values (${lit(streamUser)})`);
      const streamDevice = await sql(`insert into public.devices(id,user_id,source_kind) values (gen_random_uuid(),${lit(streamUser)},'strap') returning id`);
      const deviceOf = async (user: string) =>
        sql(`insert into public.devices(id,user_id,source_kind) values (gen_random_uuid(),${lit(user)},'strap') returning id`);
      const dayOf = (iso: string) => sql(`select extract(epoch from ${lit(iso)}::timestamptz)::bigint`);
      const debtOn = (user: string, day: string) =>
        sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(user)} and day=${lit(day)}`);

      // D1: noop_event_labels carries start_ts/end_ts. With the old 'ts' mapping this inserted
      // nothing at all, so this is the regression that the mapping bug escaped.
      const labelStart = await dayOf('2026-10-10 13:00:00+00');
      await sql(`insert into public.noop_event_labels(user_id,device_id,label,start_ts,end_ts,source,confidence) values (${lit(streamUser)},${lit(streamDevice)},'seizure',${labelStart},${Number(labelStart) + 60},'patient','confirmed')`);
      assertEquals(await debtOn(streamUser, '2026-10-10'), '1', 'noop_event_labels insert must mark staleness');

      // D5: noop_step_samples carries ts.
      const stepTs = await dayOf('2026-11-15 15:00:00+00');
      await sql(`insert into public.noop_step_samples(user_id,device_id,source_id,ts,counter,batch_id) values (${lit(streamUser)},${lit(streamDevice)},${lit(streamDevice)},${stepTs},100,${lit(streamDevice)})`);
      assertEquals(await debtOn(streamUser, '2026-11-15'), '1', 'noop_step_samples insert must mark staleness');

      // D5: noop_signal_windows carries start_ts/end_ts and needs a manifest row.
      const windowTs = await dayOf('2026-11-20 15:00:00+00');
      const objectId = await sql(`insert into public.object_manifests(user_id,device_id,object_class,object_kind,provider,object_key,status,retention_class) values (${lit(streamUser)},${lit(streamDevice)},'raw','raw_imu','b2',${lit('w-b-test/window')},'ready','raw') returning id`);
      await sql(`insert into public.noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,received_records) values (${lit(streamUser)},${lit(streamDevice)},'hr',${windowTs},${lit(objectId)},${lit('w-b-test/window')},${windowTs},${Number(windowTs) + 3600},0)`);
      assertEquals(await debtOn(streamUser, '2026-11-20'), '1', 'noop_signal_windows insert must mark staleness');

      // D2: sessions.device_id is nullable (ON DELETE SET NULL). A device-less change fans the
      // debt out to EVERY device of the owner, matching scoring_dirty_projection.
      const deviceB = await deviceOf(streamUser);
      await sql(`insert into public.sessions(id,user_id,device_id,kind,start_at,end_at) values (gen_random_uuid(),${lit(streamUser)},null,'sleep','2026-12-05 22:00:00+00','2026-12-06 07:00:00+00')`);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(streamUser)} and day='2026-12-05'`), '2', 'a device-less change fans out to every device');
      assertEquals(await sql(`select string_agg(device_id,',' order by device_id) from public.physiology_candidate_debt where user_id=${lit(streamUser)} and day='2026-12-05'`), [streamDevice, deviceB].sort().join(','), 'fan-out covers both devices');
      assertStringIncludes(await sql(`select public.physiology_candidate_debt_read(${lit(streamUser)},${lit(streamDevice)},'2026-12-05')::text`), '"debt": true');
      assertStringIncludes(await sql(`select public.physiology_candidate_debt_read(${lit(streamUser)},${lit(deviceB)},'2026-12-05')::text`), '"debt": true');

      // D2b: an owner with NO device cannot fan out, so one any-device row (device_id='') is
      // recorded and physiology_candidate_debt_read reports it for every device.
      const ownerless = crypto.randomUUID();
      await sql(`insert into auth.users(id) values (${lit(ownerless)})`);
      await sql(`insert into public.sessions(id,user_id,device_id,kind,start_at,end_at) values (gen_random_uuid(),${lit(ownerless)},null,'sleep','2026-11-05 22:00:00+00','2026-11-06 07:00:00+00')`);
      assertEquals(await sql(`select count(*)||'|'||string_agg('['||device_id||']',',') from public.physiology_candidate_debt where user_id=${lit(ownerless)} and day='2026-11-05'`), '1|[]', 'exactly one any-device row');
      assertStringIncludes(await sql(`select public.physiology_candidate_debt_read(${lit(ownerless)},${lit('99999999-9999-4999-8999-999999999999')},'2026-11-05')::text`), '"debt": true');
      assertEquals(await sql(`select public.physiology_candidate_debt_read(${lit(ownerless)},${lit('99999999-9999-4999-8999-999999999999')},'2026-11-20')::text`), '{"debt": false, "invalidated_at": null}');
      // Idempotent: a second device-less change the same day does not duplicate the row.
      await sql(`insert into public.sessions(id,user_id,device_id,kind,start_at,end_at) values (gen_random_uuid(),${lit(ownerless)},null,'sleep','2026-11-05 23:00:00+00','2026-11-06 06:00:00+00')`);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(ownerless)} and day='2026-11-05'`), '1', 'any-device row is deduped by the primary key');
    });

    await t.step('a stale claim and a moved provider generation are refused', async () => {
      const staleRevision = currentRevision;
      // A newer ingest generation arrives after the worker read its input snapshot.
      currentRevision = await sql(`select public.enqueue_scoring_v2(${lit(USER_A)},${lit(DEV_A)},${lit(DAY)},'frwhoop-server-1','test')::text`);
      assert(Number(currentRevision) > Number(staleRevision));
      assertEquals(await sql(recordCandidate({ p_input_revision: staleRevision, p_input_sha256: lit(SHA_B) })), 'null');
      assertEquals(await sql(recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit(SHA_B), p_provider_version: lit('runs.v2') })), 'null');
      assertEquals(await sql(recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit(SHA_B), p_config_version: lit('cfg-2') })), 'null');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), '1');
    });

    await t.step('withheld and stage results are persisted with their contract fields', async () => {
      assertMatch(await sql(recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit(SHA_B), p_status: lit('withheld'), p_withheld_reason: lit('insufficient_coverage'), p_value: 'null' })), /^[0-9a-f-]{36}$/);
      // A withheld result is a first-class record, not an absence: it is stored and replayable.
      assertEquals(await sql(recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit(SHA_B), p_status: lit('withheld'), p_withheld_reason: lit('insufficient_coverage'), p_value: 'null' })), 'null');
      assertEquals(await sql(`select status||'|'||coalesce(value::text,'null')||'|'||withheld_reason from public.physiology_candidate_results where input_sha256=${lit(SHA_B)}`), 'withheld|null|insufficient_coverage');
      await sql(`update public.physiology_provider_defaults set provider_id='stage-provider', provider_version='v1', config_version='c1', mode='shadow' where metric='sleep_stage'`);
      assertMatch(await sql(recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_input_sha256: lit(SHA_C), p_provider_id: lit('stage-provider'), p_provider_version: lit('v1'), p_config_version: lit('c1'), p_value: 'null', p_unit: 'null', p_stages: lit('[{"stage":"light","minutes":30}]') + '::jsonb', p_label_space: lit('wake_light_deep_rem') })), /^[0-9a-f-]{36}$/);
      assertEquals(await sql(`select stages::text||'|'||label_space from public.physiology_candidate_results where input_sha256=${lit(SHA_C)}`), '[{"stage": "light", "minutes": 30}]|wake_light_deep_rem');
      // 'error' is a separate status: it requires a reason but not the withheld vocabulary.
      assertMatch(await sql(recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit(SHA_F), p_status: lit('error'), p_withheld_reason: lit('provider_crash'), p_value: 'null' })), /^[0-9a-f-]{36}$/);
      assertEquals(await sql(`select status||'|'||withheld_reason from public.physiology_candidate_results where input_sha256=${lit(SHA_F)}`), 'error|provider_crash');
    });

    await t.step('shape, bounds and finiteness are rejected before any write', async () => {
      const invalid: [string, string, string][] = [
        ['NaN value', recordCandidate({ p_input_revision: currentRevision, p_value: `'NaN'` }), 'invalid_candidate_value'],
        ['Infinity value', recordCandidate({ p_input_revision: currentRevision, p_value: `'Infinity'` }), 'invalid_candidate_value'],
        ['negative Infinity', recordCandidate({ p_input_revision: currentRevision, p_value: `'-Infinity'` }), 'invalid_candidate_value'],
        ['hrv above bound', recordCandidate({ p_input_revision: currentRevision, p_value: '5000' }), 'candidate_value_out_of_bounds'],
        ['hrv below bound', recordCandidate({ p_input_revision: currentRevision, p_value: '-1' }), 'candidate_value_out_of_bounds'],
        ['respiration below bound', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('respiration'), p_value: '2' }), 'candidate_value_out_of_bounds'],
        ['sleep_stage above bound', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: '1e10' }), 'candidate_value_out_of_bounds'],
        ['interval end before start', recordCandidate({ p_input_revision: currentRevision, p_interval_end_at: lit('2026-09-29 00:00:00+00') }), 'invalid_candidate_interval'],
        ['missing interval bound', recordCandidate({ p_input_revision: currentRevision, p_interval_start_at: 'null' }), 'invalid_candidate_interval'],
        ['malformed input hash', recordCandidate({ p_input_revision: currentRevision, p_input_sha256: lit('xyz') }), 'invalid_candidate_input_hash'],
        ['unknown metric', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('resting_hr') }), 'invalid_candidate_metric'],
        ['unknown status', recordCandidate({ p_input_revision: currentRevision, p_status: lit('fallback') }), 'invalid_candidate_status'],
        ['zero revision', recordCandidate({ p_input_revision: '0' }), 'invalid_candidate_input_revision'],
        ['ok without a result', recordCandidate({ p_input_revision: currentRevision, p_value: 'null' }), 'invalid_candidate_result'],
        ['ok with a withheld reason', recordCandidate({ p_input_revision: currentRevision, p_withheld_reason: lit('timeout') }), 'invalid_candidate_result'],
        ['ok without a unit', recordCandidate({ p_input_revision: currentRevision, p_unit: 'null' }), 'invalid_candidate_unit'],
        ['withheld with a value', recordCandidate({ p_input_revision: currentRevision, p_status: lit('withheld'), p_withheld_reason: lit('timeout'), p_value: '10' }), 'invalid_candidate_result'],
        ['withheld outside the vocabulary', recordCandidate({ p_input_revision: currentRevision, p_status: lit('withheld'), p_withheld_reason: lit('because'), p_value: 'null' }), 'invalid_candidate_reason'],
        ['withheld without a reason', recordCandidate({ p_input_revision: currentRevision, p_status: lit('withheld'), p_value: 'null' }), 'invalid_candidate_reason'],
        ['error without a reason', recordCandidate({ p_input_revision: currentRevision, p_status: lit('error'), p_value: 'null' }), 'invalid_candidate_reason'],
        ['negative runtime', recordCandidate({ p_input_revision: currentRevision, p_runtime_ms: '-5' }), 'invalid_candidate_runtime'],
        ['stages that are not an array', recordCandidate({ p_input_revision: currentRevision, p_stages: `'{}'::jsonb` }), 'invalid_candidate_stages'],
        ['stage element that is not an object', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_stages: `'[1,2]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stages'],
        ['stage outside the label space', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_stages: `'[{"stage":"zzz","minutes":1}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_label'],
        ['stage with a negative duration', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_stages: `'[{"stage":"light","minutes":-5}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_duration'],
        ['stage with an unparseable epoch', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_interval_end_at: lit('2026-09-30 08:00:00+00'), p_stages: `'[{"stage":"light","start_at":"nope","end_at":"2026-09-30T02:00:00Z"}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_epoch'],
        ['stage with start not before end', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_interval_end_at: lit('2026-09-30 08:00:00+00'), p_stages: `'[{"stage":"light","start_at":"2026-09-30T02:00:00Z","end_at":"2026-09-30T02:00:00Z"}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_interval'],
        ['stage outside the candidate interval', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_interval_end_at: lit('2026-09-30 08:00:00+00'), p_stages: `'[{"stage":"light","start_at":"2026-09-30T01:00:00Z","end_at":"2026-09-30T09:00:00Z"}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_interval'],
        ['overlapping stage epochs', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_interval_end_at: lit('2026-09-30 08:00:00+00'), p_stages: `'[{"stage":"light","start_at":"2026-09-30T01:00:00Z","end_at":"2026-09-30T03:00:00Z"},{"stage":"deep","start_at":"2026-09-30T02:00:00Z","end_at":"2026-09-30T04:00:00Z"}]'::jsonb`, p_label_space: lit('wake_light_deep_rem') }), 'invalid_candidate_stage_overlap'],
        ['stage epochs without a label space', recordCandidate({ p_input_revision: currentRevision, p_metric: lit('sleep_stage'), p_value: 'null', p_unit: 'null', p_stages: `'[{"stage":"light","start_at":"2026-09-30T01:00:00Z","end_at":"2026-09-30T02:00:00Z"}]'::jsonb`, p_label_space: 'null' }), 'invalid_candidate_label_space'],
        ['coverage that is not an object', recordCandidate({ p_input_revision: currentRevision, p_coverage: `'[]'::jsonb` }), 'invalid_candidate_coverage'],
        ['dependencies that are not an object', recordCandidate({ p_input_revision: currentRevision, p_dependency_versions: `'[]'::jsonb` }), 'invalid_candidate_dependencies'],
        ['empty adapter version', recordCandidate({ p_input_revision: currentRevision, p_adapter_version: `''` }), 'invalid_candidate_provider'],
        ['diagnostics that are not an object', recordCandidate({ p_input_revision: currentRevision, p_diagnostics: `'[]'::jsonb` }), 'invalid_candidate_diagnostics'],
        ['unknown metric in the selector', `select public.physiology_selected_provider(${lit(USER_A)},'resting_hr')`, 'invalid_candidate_metric'],
      ];
      const before = await sql(`select count(*) from public.physiology_candidate_results`);
      for (const [name, statement, expected] of invalid) {
        assertEquals(await pg.sqlError(statement), `ERROR:  ${expected}`, name);
      }
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results`), before);
    });

    await t.step('a per-user override beats the fleet default', async () => {
      await sql(`insert into public.physiology_provider_overrides(user_id,metric,provider_id,provider_version,config_version,mode) values (${lit(USER_B)},'hrv','legacy','v0','c0','off')`);
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_B)},'hrv')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_B)},'hrv')->>'source')`), 'off|user_override');
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_A)},'hrv')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_A)},'hrv')->>'source')`), 'shadow|default');
      // The override turns the lane off for that owner only.
      assertEquals(await sql(recordCandidate({ p_user: lit(USER_B), p_device: lit(DEV_B), p_input_revision: currentRevision })), 'null');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_B)}`), '0');
      // A candidate cannot be attributed to another owner's device.
      assertEquals(await sql(recordCandidate({ p_user: lit(USER_B), p_device: lit(DEV_A), p_input_sha256: lit('d'.repeat(64)) })), 'null');
    });

    await t.step('client roles hold no table or function privilege', async () => {
      for (const table of CANDIDATE_TABLES) {
        assertEquals(await sql(`select has_table_privilege('authenticated','public.${table}','select')`), 'f');
        assertEquals(await sql(`select has_table_privilege('anon','public.${table}','select')`), 'f');
      }
      assertEquals(await sql(`select has_function_privilege('authenticated',${lit(RECORD_SIGNATURE)},'execute')`), 'f');
      assertEquals(await sql(`select has_function_privilege('anon',${lit(RECORD_SIGNATURE)},'execute')`), 'f');
      assertEquals(await sql(`select has_function_privilege('service_role',${lit(RECORD_SIGNATURE)},'execute')`), 't');
      assertEquals(await sql(`select has_function_privilege('service_role','public.physiology_selected_provider(uuid,text)','execute')`), 't');
      assertEquals(await sql(`select has_function_privilege('authenticated','public.physiology_candidate_activation(uuid,text)','execute')`), 'f');
      assertEquals(await sql(`select has_function_privilege('anon','public.physiology_candidate_feature(text)','execute')`), 'f');
      assertEquals(await sql(`select has_function_privilege('service_role','public.physiology_candidate_activation(uuid,text)','execute')`), 't');
      assertStringIncludes(String(await pg.sqlError(`set role authenticated; select count(*) from public.physiology_candidate_results`)), 'permission denied for table');
      assertStringIncludes(String(await pg.sqlError(`set role authenticated; select public.physiology_record_candidate_result(${lit(USER_A)},${lit(DEV_A)},'hrv',${lit(DAY)}::date,now(),now(),${lit(SHA_A)},1,'a','b','c','d','e','ok')`)), 'permission denied for function');
      // The service role reaches the lane with its bypass attribute, as the worker does.
      assertEquals(await sql(`set role service_role; select count(*) from public.physiology_provider_defaults`), '4');
    });

    await t.step('an active mode without a live promotion approval is demoted and refused', async () => {
      await sql(`insert into auth.users(id) values (${lit(USER_E)}) on conflict (id) do nothing`);
      await sql(`insert into public.devices(id,user_id,source_kind) values (${lit(DEV_E)},${lit(USER_E)},'strap') on conflict (id) do nothing`);
      await sql(`update public.physiology_provider_defaults set provider_id=${lit(RESP_PROVIDER)}, provider_version='resp-unapproved', config_version=${lit(RESP_CONFIG)}, mode='active', updated_at=clock_timestamp() where metric='respiration'`);
      // The worker never sees an unapproved provider as active.
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'shadow|default_demoted_unapproved');
      const activation = await sql(`select public.physiology_candidate_activation(${lit(USER_E)},'respiration')::text`);
      assertStringIncludes(activation, '"requested_mode": "active"');
      assertStringIncludes(activation, '"mode": "shadow"');
      assertStringIncludes(activation, '"demoted": true');
      assertStringIncludes(activation, '"approved": false');
      assertStringIncludes(activation, '"reason": "promotion_approval_required"');
      assertStringIncludes(activation, '"feature": "respiration"');
      // An active write is refused outright rather than silently downgraded to a shadow row.
      assertEquals(await sql(recordRespiration('resp-unapproved', '1'.repeat(64))), 'null');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_E)}`), '0');
      // The metric-to-feature map is the one the signed-promotion table can express.
      assertEquals(await sql(`select public.physiology_candidate_feature('hrv')||','||public.physiology_candidate_feature('sleep_boundary')||','||public.physiology_candidate_feature('sleep_stage')||','||public.physiology_candidate_feature('respiration')`), 'hrv,sleep,sleep,respiration');
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_candidate_activation(${lit(USER_E)},'resting_hr')`)), 'invalid_candidate_metric');
    });

    await t.step('a live signed promotion approval enables an active write', async () => {
      const approvalId = crypto.randomUUID();
      await sql(signedApprovalSql({ version: 'resp-approved-v1', feature: 'respiration', approvalId,
        approvedAt: '2026-01-04T00:00:00Z', referenceKind: 'synchronized_respiratory_reference' }));
      // The fixture satisfies the repository's own liveness check, not a stand-in.
      assertEquals(await sql(`select internal.physiology_approval_valid(a)::text from public.physiology_promotion_approvals a where approval_id=${lit(approvalId)}`), 'true');
      await sql(`update public.physiology_provider_defaults set provider_version='resp-approved-v1', updated_at=clock_timestamp() where metric='respiration'`);
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'active|default');
      const activation = await sql(`select public.physiology_candidate_activation(${lit(USER_E)},'respiration')::text`);
      assertStringIncludes(activation, '"approved": true');
      assertStringIncludes(activation, '"demoted": false');
      assertStringIncludes(activation, `"approval_id": "${approvalId}"`);
      // The approval's manifest identity is reported, so the worker can compare its own versions.
      assertStringIncludes(activation, '"preprocessing_version": "prep-1"');
      assertStringIncludes(activation, '"quality_policy_version": "policy-1"');
      assertMatch(await sql(recordRespiration('resp-approved-v1', '2'.repeat(64))), /^[0-9a-f-]{36}$/);
      assertEquals(await sql(`select provider_version||'|'||value from public.physiology_candidate_results where user_id=${lit(USER_E)}`), 'resp-approved-v1|12');
    });

    await t.step('a revoked, not-yet-valid or key-revoked approval demotes the metric again', async () => {
      // (a) approval revocation
      const revokedId = crypto.randomUUID();
      await sql(signedApprovalSql({ version: 'resp-revoked-v1', feature: 'respiration', approvalId: revokedId,
        approvedAt: '2026-01-04T00:00:00Z', referenceKind: 'synchronized_respiratory_reference' }));
      await sql(`update public.physiology_provider_defaults set provider_version='resp-revoked-v1', updated_at=clock_timestamp() where metric='respiration'`);
      assertEquals(await sql(`select public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode'`), 'active');
      await sql(`insert into public.physiology_promotion_revocations(approval_id,reason) values (${lit(revokedId)},'superseded by parent decision')`);
      assertEquals(await sql(`select internal.physiology_approval_valid(a)::text from public.physiology_promotion_approvals a where approval_id=${lit(revokedId)}`), 'false');
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'shadow|default_demoted_unapproved');
      assertEquals(await sql(recordRespiration('resp-revoked-v1', '3'.repeat(64))), 'null');

      // (b) not yet valid: the schema has no expiry column, so a future approved_at is the
      //     only time-based invalidation the signed payload can express.
      const futureId = crypto.randomUUID();
      await sql(signedApprovalSql({ version: 'resp-future-v1', feature: 'respiration', approvalId: futureId,
        approvedAt: '2099-01-01T00:00:00Z', referenceKind: 'synchronized_respiratory_reference' }));
      assertEquals(await sql(`select internal.physiology_approval_valid(a)::text from public.physiology_promotion_approvals a where approval_id=${lit(futureId)}`), 'false');
      await sql(`update public.physiology_provider_defaults set provider_version='resp-future-v1', updated_at=clock_timestamp() where metric='respiration'`);
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'shadow|default_demoted_unapproved');
      assertEquals(await sql(recordRespiration('resp-future-v1', '4'.repeat(64))), 'null');

      // (c) signing-key revocation invalidates an otherwise valid approval
      const keyRevokedId = crypto.randomUUID();
      await sql(signedApprovalSql({ version: 'resp-keyrevoked-v1', feature: 'respiration', approvalId: keyRevokedId,
        approvedAt: '2026-01-04T00:00:00Z', referenceKind: 'synchronized_respiratory_reference' }));
      await sql(`update public.physiology_provider_defaults set provider_version='resp-keyrevoked-v1', updated_at=clock_timestamp() where metric='respiration'`);
      assertEquals(await sql(`select public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode'`), 'active');
      await sql(`update internal.physiology_approval_keys set revoked_at=clock_timestamp() where key_id=encode(sha256(convert_to(${lit(SIGNING_SECRET)},'UTF8')),'hex')`);
      assertEquals(await sql(`select internal.physiology_approval_valid(a)::text from public.physiology_promotion_approvals a where approval_id=${lit(keyRevokedId)}`), 'false');
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'shadow|default_demoted_unapproved');
      assertEquals(await sql(recordRespiration('resp-keyrevoked-v1', '5'.repeat(64))), 'null');
      // Only the one approved candidate was ever recorded for this owner.
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_E)}`), '1');

      // A per-user override to active is gated the same way.
      await sql(`insert into public.physiology_provider_overrides(user_id,metric,provider_id,provider_version,config_version,mode) values (${lit(USER_E)},'respiration',${lit(RESP_PROVIDER)},'resp-unapproved',${lit(RESP_CONFIG)},'active')`);
      assertEquals(await sql(`select (public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode')||'|'||(public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'source')`), 'shadow|user_override_demoted_unapproved');
      assertEquals(await sql(recordRespiration('resp-unapproved', '6'.repeat(64))), 'null');
      // Shadow is never gated: the same override set to shadow records normally.
      await sql(`update public.physiology_provider_overrides set mode='shadow' where user_id=${lit(USER_E)} and metric='respiration'`);
      assertEquals(await sql(`select public.physiology_selected_provider(${lit(USER_E)},'respiration')->>'mode'`), 'shadow');
      assertMatch(await sql(recordRespiration('resp-unapproved', '7'.repeat(64))), /^[0-9a-f-]{36}$/);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_E)}`), '2');
      // Leave the fixture metric off so the remaining steps see the shipped default.
      await sql(`delete from public.physiology_provider_overrides where user_id=${lit(USER_E)} and metric='respiration'`);
      await sql(`update public.physiology_provider_defaults set provider_id='none', provider_version='none', config_version='none', mode='off', updated_at=clock_timestamp() where metric='respiration'`);
    });

    await t.step('backfill dry run writes nothing and apply enqueues the canonical recompute', async () => {
      currentRevisionC = await sql(`select public.enqueue_scoring_v2(${lit(USER_C)},${lit(DEV_C)},${lit(DAY)},'frwhoop-server-1','test')::text`);
      assertMatch(await sql(recordCandidate({ p_user: lit(USER_C), p_device: lit(DEV_C), p_input_revision: currentRevisionC, p_input_sha256: lit('9'.repeat(64)) })), /^[0-9a-f-]{36}$/);
      const newJob = (mode: string) => sql(`insert into public.physiology_backfill_jobs(mode,metric,from_provider_id,from_provider_version,to_provider_id,to_provider_version,scope_user,scope_from_day,scope_through_day,max_users) values (${lit(mode)},'hrv','legacy','v0',${lit(PROVIDER.id)},${lit(PROVIDER.version)},${lit(USER_C)},'2026-09-29','2026-10-01',1) returning job_id`);
      const claim = async (jobId: string) => {
        const claimed = await sql(`select job_id||'|'||lease_token from public.physiology_backfill_claim(300,'tester')`);
        const [claimedId, token] = claimed.split('|');
        assertEquals(claimedId, jobId);
        return token;
      };

      const dryId = await newJob('dry_run');
      const dryToken = await claim(dryId);
      const dry = await sql(`select public.physiology_backfill_advance(${lit(dryId)},${lit(dryToken)},1)::text`);
      assertStringIncludes(dry, '"enqueued": 0');
      assertStringIncludes(dry, '"state": "running"');
      assertEquals(await sql(`select state||'|'||processed_days from public.physiology_backfill_jobs where job_id=${lit(dryId)}`), 'running|0');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(USER_C)}`), '0');
      assertEquals(await sql(`select max(input_revision)::text from public.scoring_jobs_v2 where user_id=${lit(USER_C)} and day=${lit(DAY)}`), currentRevisionC);

      const applyId = await newJob('apply');
      const applyToken = await claim(applyId);
      const applied = await sql(`select public.physiology_backfill_advance(${lit(applyId)},${lit(applyToken)},5)::text`);
      assertStringIncludes(applied, '"enqueued": 1');
      assertStringIncludes(applied, '"done": true');
      assertEquals(await sql(`select state||'|'||processed_days from public.physiology_backfill_jobs where job_id=${lit(applyId)}`), 'complete|1');
      assertEquals(await sql(`select (max(input_revision)::int > ${currentRevisionC}::int)::text from public.scoring_jobs_v2 where user_id=${lit(USER_C)} and day=${lit(DAY)}`), 'true');
      // The completed job released its lease, so a finished lease cannot be reused.
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_advance(${lit(applyId)},${lit(applyToken)},1)`)), 'backfill_lease_lost');
    });

    await t.step('backfill rollback fences in-flight candidate writes', async () => {
      const jobId = await sql(`insert into public.physiology_backfill_jobs(mode,metric,to_provider_id,to_provider_version,scope_user,scope_from_day,scope_through_day,max_users) values ('rollback','hrv',${lit(PROVIDER.id)},${lit(PROVIDER.version)},${lit(USER_C)},'2026-09-29','2026-10-01',1) returning job_id`);
      const claimed = await sql(`select job_id||'|'||lease_token from public.physiology_backfill_claim(300,'tester')`);
      const [claimedId, token] = claimed.split('|');
      assertEquals(claimedId, jobId);
      const advanced = await sql(`select public.physiology_backfill_advance(${lit(jobId)},${lit(token)},5)::text`);
      assertStringIncludes(advanced, '"mode": "rollback"');
      assertStringIncludes(advanced, '"enqueued": 1');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(USER_C)} and device_id=${lit(DEV_C)} and day=${lit(DAY)}`), '1');
      assertStringIncludes(await sql(`select public.physiology_candidate_debt_read(${lit(USER_C)},${lit(DEV_C)},${lit(DAY)})::text`), '"debt": true');
    });

    await t.step('backfill advance is bounded per call and resumes from its cursor', async () => {
      for (const day of ['2026-09-29', DAY, '2026-10-01']) {
        await sql(`select public.enqueue_scoring_v2(${lit(USER_D)},${lit(DEV_D)},${lit(day)},'frwhoop-server-1','test')`);
      }
      const jobId = await sql(`insert into public.physiology_backfill_jobs(mode,metric,to_provider_id,to_provider_version,scope_user,scope_from_day,scope_through_day,max_users) values ('dry_run','hrv',${lit(PROVIDER.id)},${lit(PROVIDER.version)},${lit(USER_D)},'2026-09-29','2026-10-01',1) returning job_id`);
      const claimed = await sql(`select job_id||'|'||lease_token from public.physiology_backfill_claim(300,'tester')`);
      const [claimedId, token] = claimed.split('|');
      assertEquals(claimedId, jobId);
      const cursors: string[] = [];
      for (let call = 0; call < 3; call++) {
        const result = await sql(`select public.physiology_backfill_advance(${lit(jobId)},${lit(token)},1)::text`);
        assertStringIncludes(result, '"scanned": 1');
        assertStringIncludes(result, '"done": false');
        cursors.push(result.split('"cursorDay": "')[1].split('"')[0]);
      }
      assertEquals(cursors, ['2026-09-29', DAY, '2026-10-01']);
      const exhausted = await sql(`select public.physiology_backfill_advance(${lit(jobId)},${lit(token)},1)::text`);
      assertStringIncludes(exhausted, '"done": true');
      assertStringIncludes(exhausted, '"scanned": 0');
      const progress = await sql(`select state||'|'||(progress->>'scannedDays')||'|'||(progress->>'processedDays')||'|'||processed_days from public.physiology_backfill_jobs where job_id=${lit(jobId)}`);
      assertEquals(progress, 'complete|3|0|0');
      // A dry run leaves the canonical ledger untouched.
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(USER_D)}`), '0');
      // max_users bounds the DISTINCT users one call may process, independently of p_max_days.
      await sql(`select public.enqueue_scoring_v2(${lit(USER_C)},${lit(DEV_C)},'2026-09-29','frwhoop-server-1','test')`);
      const cappedId = await sql(`insert into public.physiology_backfill_jobs(mode,metric,to_provider_id,to_provider_version,scope_from_day,scope_through_day,max_users) values ('dry_run','hrv',${lit(PROVIDER.id)},${lit(PROVIDER.version)},'2026-09-29','2026-09-30',1) returning job_id`);
      const cappedClaim = await sql(`select job_id||'|'||lease_token||'|'||lease_seconds from public.physiology_backfill_claim(120,'tester')`);
      const [cappedClaimed, cappedToken, cappedLease] = cappedClaim.split('|');
      assertEquals(cappedClaimed, cappedId);
      // The claim honours the caller's lease length instead of a fixed default.
      assertEquals(cappedLease, '120');
      const cappedResult = await sql(`select public.physiology_backfill_advance(${lit(cappedId)},${lit(cappedToken)},10)::text`);
      // Two eligible owners exist, but max_users=1 lets one call touch only one of them.
      assertEquals(await sql(`select progress->>'usersSeen' from public.physiology_backfill_jobs where job_id=${lit(cappedId)}`), '1');
      assertStringIncludes(cappedResult, '"done": false');
      assertEquals(await sql(`select state from public.physiology_backfill_jobs where job_id=${lit(cappedId)}`), 'running');
      // The renewed lease keeps the granted length, not the old hardcoded 900 s.
      assertEquals(await sql(`select round(extract(epoch from (lease_until-clock_timestamp())))::text from public.physiology_backfill_jobs where job_id=${lit(cappedId)}`), '120');
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_advance(${lit(jobId)},${lit(token)},0)`)), 'invalid_backfill_bound');
      // A lease outside 1..3600 and an unknown job are named rejections, not generic failures.
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_claim(0,'tester')`)), 'invalid_lease');
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_claim(3601,'tester')`)), 'invalid_lease');
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_advance('00000000-0000-4000-8000-000000000000','00000000-0000-4000-8000-000000000000',1)`)), 'unknown_backfill_job');
    });

    await t.step('backfill finish needs the live lease and a known state', async () => {
      const jobId = await sql(`insert into public.physiology_backfill_jobs(mode,metric,to_provider_id,to_provider_version,scope_user,scope_from_day,scope_through_day,max_users) values ('apply','hrv',${lit(PROVIDER.id)},${lit(PROVIDER.version)},${lit(USER_D)},'2026-09-29','2026-10-01',1) returning job_id`);
      const claimed = await sql(`select job_id||'|'||lease_token from public.physiology_backfill_claim(300,'tester')`);
      const [claimedId, token] = claimed.split('|');
      assertEquals(claimedId, jobId);
      assertEquals(await sql(`select public.physiology_backfill_finish(${lit(jobId)},'00000000-0000-4000-8000-000000000000','complete')`), 'f');
      assertEquals(await sql(`select public.physiology_backfill_finish(${lit(jobId)},${lit(token)},'cancelled','operator stop')`), 't');
      assertEquals(await sql(`select state||'|'||coalesce(lease_token::text,'-')||'|'||last_error from public.physiology_backfill_jobs where job_id=${lit(jobId)}`), 'cancelled|-|operator stop');
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_finish(${lit(jobId)},${lit(token)},'done')`)), 'invalid_backfill_state');

      // A live lease on a job that is not running is refused, so a paused job cannot be advanced.
      const pausedId = await sql(`insert into public.physiology_backfill_jobs(mode,metric,to_provider_id,to_provider_version,scope_user,scope_from_day,scope_through_day,max_users) values ('apply','hrv',${lit(PROVIDER.id)},${lit(PROVIDER.version)},${lit(USER_D)},'2026-09-29','2026-10-01',1) returning job_id`);
      const pausedClaim = await sql(`select job_id||'|'||lease_token from public.physiology_backfill_claim(300,'tester')`);
      const [pausedClaimed, pausedToken] = pausedClaim.split('|');
      assertEquals(pausedClaimed, pausedId);
      await sql(`update public.physiology_backfill_jobs set state='paused' where job_id=${lit(pausedId)}`);
      assertStringIncludes(String(await pg.sqlError(`select public.physiology_backfill_advance(${lit(pausedId)},${lit(pausedToken)},1)`)), 'backfill_not_running');
    });

    await t.step('deleting the owner removes every candidate-lane row and refuses new writes', async () => {
      assert(Number(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_A)}`)) > 0);
      await sql(`delete from auth.users where id=${lit(USER_A)}`);
      assertEquals(await sql(`select count(*) from public.physiology_candidate_results where user_id=${lit(USER_A)}`), '0');
      assertEquals(await sql(`select count(*) from public.physiology_candidate_debt where user_id=${lit(USER_A)}`), '0');
      assert(Number(await sql(`select count(*) from public.physiology_candidate_results where user_id<>${lit(USER_A)}`)) > 0);
      assertEquals(await sql(recordCandidate()), 'null');
    });

    await t.step('re-applying the migration preserves operator state', async () => {
      const before = await sql(`select metric||'|'||mode||'|'||provider_id from public.physiology_provider_defaults order by metric`);
      await pg.applyMigration(CANDIDATE_MIGRATION);
      assertEquals(await sql(`select metric||'|'||mode||'|'||provider_id from public.physiology_provider_defaults order by metric`), before);
      assertEquals(await sql(`select count(*) from public.physiology_provider_defaults`), '4');
      assertEquals(await sql(`select count(*) from pg_policies where schemaname='public' and tablename in ('${CANDIDATE_TABLES.join("','")}')`), '0');
      assertMatch(await sql(`select public.physiology_selected_provider(${lit(USER_C)},'hrv')->>'mode'`), /^(off|shadow|active)$/);
    });

    console.log(`Disposable cluster retained at ${pg.base}`);
  } finally {
    await pg.close();
  }
});
