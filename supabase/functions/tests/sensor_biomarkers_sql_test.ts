import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// Sensor-biomarker DB contract (docs/sensor-biomarkers/CONTRACTS.md §5, spec-31 §8): runs inside the
// isolated, fully migrated test database with 20261007140000_sensor_biomarkers.sql applied on top.
// No deployed credentials or data are touched. Every fixture uses its own user/device/day and is
// deleted afterwards (the user deletion cascades to everything the fixture wrote).
//
// Proves: the schema and PKs; the fingerprint function's determinism; idempotent enqueue with
// revision bumps for a late object OR a family-set change; claim/lease/renew/expiry; bounded
// backoff + dead-letter; fenced publish (a stale lease / wrong revision / expired lease publishes
// NULL and never writes a day row, and a newer result is never overwritten by an older one); the
// document contract (family whitelist, statuses, the 256 KiB budget, UTC interval bounds);
// owner-isolation RLS through real PostgREST roles; device/account deletion cascades; and the
// bounded reconcile scan mapping ready rawImuSession + ppgWaveformSample objects to day jobs.

const ANALYSIS = 'sensor-biomarkers/1.0.0';
const FAMILIES = ['movement', 'oscillation', 'ppg_quality', 'pulse_shape',
  'perfusion_research', 'tremor', 'arm_swing', 'rhythm_shadow'];

async function applyMigration(db: Awaited<ReturnType<typeof startLocalPostgres>>, file: string) {
  const path = new URL(`../../migrations/${file}`, import.meta.url);
  const r = await new Deno.Command('/opt/homebrew/bin/psql', {
    args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
      '-f', decodeURIComponent(path.pathname)],
    stdout: 'piped', stderr: 'piped', clearEnv: true,
  }).output();
  if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
}

function dayBounds(day: string) {
  const start = Date.UTC(Number(day.slice(0, 4)), Number(day.slice(5, 7)) - 1, Number(day.slice(8, 10)));
  return { lo: Math.floor(start / 1000), hi: Math.floor(start / 1000) + 86_400 - 1 };
}

async function fingerprintOf(db: any, digests: string[], day: string) {
  const { lo, hi } = dayBounds(day);
  const list = digests.map((d) => `'${d}'`).join(',');
  return (await db.sql(
    `select public.sensor_biomarkers_fingerprint(array[${list}], ${lo}, ${hi}, '${ANALYSIS}')::text;`,
  )).trim();
}

function validDocument(day: string, inputRevision = 'sha256:' + 'a'.repeat(64)) {
  const { lo, hi } = dayBounds(day);
  const start = new Date(lo * 1000).toISOString();
  const end = new Date((hi + 1) * 1000).toISOString();
  const processed = new Date((hi + 2) * 1000).toISOString();
  return {
    schema_version: 1,
    analysis_version: ANALYSIS,
    input_revision: inputRevision,
    interval_start_utc: start,
    interval_end_utc: end,
    processed_at_utc: processed,
    families: {
      movement: {
        status: 'ok', release_tier: 'descriptive', provider_revision: 'imu-biomarkers/1.0.0',
        observed_seconds: 3600, eligible_seconds: 3000, contact_state: 'on_wrist',
        measurements: { enmo_median_mg: { value: 12.5, unit: 'mg', denominator: 'valid 5s epochs', count: 17280 } },
        reason_counts: {},
      },
      tremor: { status: 'withheld', release_tier: 'research',
        provider_revision: 'paradigma/1.0.0', measurements: {}, reason_counts: {},
        reason: 'unknown_wrist_placement' },
    },
  };
}

function publishPayload(day: string, overrides: Record<string, unknown> = {}) {
  return {
    day,
    status: 'completed',
    run_ms: 1234,
    document: validDocument(day),
    ...overrides,
  };
}

async function seedOwner(db: any, user: string, device: string) {
  await db.sql(`insert into auth.users(id) values ('${user}');`);
  await db.sql(`insert into public.devices(id,user_id,source_kind) values ('${device}','${user}','noop_push');`);
}

Deno.test('sensor biomarkers: schema, fingerprint, enqueue, claim/publish fencing, RLS', async (t) => {
  const db = await startLocalPostgres();
  try {
    // The activity migrations' (user_id, id) FK needs the devices_owner_identity unique
    // constraint (20260918110000_device_ownership_invariant.sql), which the shared harness does
    // not apply; add it the way activity_context_contract.sql expects.
    await db.sql('alter table public.devices add constraint devices_owner_identity unique(user_id,id);');
    await applyMigration(db, '20261007140000_sensor_biomarkers.sql');
    // PostgREST caches the schema at startup; the new tables/RPCs are not visible until a reload.
    await db.sql("notify pgrst, 'reload schema';");
    await new Promise((resolve) => setTimeout(resolve, 700));

    const U = 'a1000000-0000-4000-8000-000000000001';
    const DEV = 'a1000000-0000-4000-8000-000000000011';
    const DAY = '2026-10-07';
    const { lo, hi } = dayBounds(DAY);

    await t.step('schema: tables, PKs, checks and grants exist', async () => {
      const cols = await db.sql(`
        select table_name || ':' || column_name || ':' || data_type
        from information_schema.columns
        where table_schema = 'public'
          and table_name in ('sensor_biomarker_jobs','sensor_biomarker_days')
        order by table_name, ordinal_position;`);
      const set = new Set(cols.trim().split('\n'));
      assert.ok(set.has('sensor_biomarker_jobs:user_id:uuid'));
      assert.ok(set.has('sensor_biomarker_jobs:device_id:uuid'));
      assert.ok(set.has('sensor_biomarker_jobs:day:date'));
      assert.ok(set.has('sensor_biomarker_jobs:analysis_version:text'));
      assert.ok(set.has('sensor_biomarker_jobs:enabled_families:ARRAY'));
      assert.ok(set.has('sensor_biomarker_jobs:input_revision:bigint'));
      assert.ok(set.has('sensor_biomarker_jobs:lease_token:uuid'));
      assert.ok(set.has('sensor_biomarker_days:day:date'));
      assert.ok(set.has('sensor_biomarker_days:analysis_version:text'));
      assert.ok(set.has('sensor_biomarker_days:input_revision:text'));
      assert.ok(set.has('sensor_biomarker_days:document:jsonb'));
      assert.ok(set.has('sensor_biomarker_days:families_ok:ARRAY'));
      assert.ok(set.has('sensor_biomarker_days:withheld_reasons:ARRAY'));
      assert.ok(set.has('sensor_biomarker_days:run_ms:bigint'));
      assert.ok(set.has('sensor_biomarker_days:model_revisions:jsonb'));
      const pk = await db.sql(`
        select pg_get_constraintdef(oid) from pg_constraint
        where conrelid = 'public.sensor_biomarker_days'::regclass and contype = 'p';`);
      assert.ok(pk.includes('user_id'), 'days PK has user_id');
      assert.ok(pk.includes('device_id'), 'days PK has device_id');
      assert.ok(pk.includes('day'), 'days PK has day');
      assert.ok(pk.includes('analysis_version'), 'days PK has analysis_version');
      const rls = await db.sql(`
        select relrowsecurity from pg_class where oid in
          ('public.sensor_biomarker_jobs'::regclass, 'public.sensor_biomarker_days'::regclass);`);
      assert.ok(rls.trim().split('\n').every((v: string) => v === 't'), 'both tables have RLS enabled');
    });

    await seedOwner(db, U, DEV);

    await t.step('fingerprint: deterministic, digest-order-insensitive, range/version-sensitive', async () => {
      const a = await fingerprintOf(db, ['b'.repeat(64), 'a'.repeat(64)], DAY);
      const b = await fingerprintOf(db, ['a'.repeat(64), 'b'.repeat(64)], DAY);
      assert.equal(a, b, 'sorted digests must commute');
      assert.match(a, /^[0-9a-f]{64}$/);
      const other = await fingerprintOf(db, ['a'.repeat(64), 'c'.repeat(64)], DAY);
      assert.notEqual(a, other, 'a changed digest must change the fingerprint');
      const otherDay = await fingerprintOf(db, ['a'.repeat(64), 'b'.repeat(64)], '2026-10-08');
      assert.notEqual(a, otherDay, 'a changed UTC range must change the fingerprint');
    });

    await t.step('enqueue: idempotent replay is a no-op; late object and family change bump the revision', async () => {
      const fp1 = await fingerprintOf(db, ['a'.repeat(64)], DAY);
      const fp2 = await fingerprintOf(db, ['b'.repeat(64)], DAY);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${DAY}'::date,
          array['a1000000-0000-4000-8000-0000000000a1'::uuid], array['${'a'.repeat(64)}'], '${fp1}',
          array['movement']);`);
      let rev = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      assert.equal(rev, '1', 'fresh enqueue starts at input_revision 1');
      const dirty = (await db.sql(
        `select dirty_at from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      // Identical replay: no bump, no new dirty stamp.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${DAY}'::date,
          array['a1000000-0000-4000-8000-0000000000a1'::uuid], array['${'a'.repeat(64)}'], '${fp1}',
          array['movement']);`);
      rev = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      assert.equal(rev, '1', 'same fingerprint + same families must not bump');
      assert.equal((await db.sql(
        `select dirty_at from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim(), dirty,
      'same fingerprint + same families must not dirty');
      // Late verified object: new fingerprint bumps.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${DAY}'::date,
          array['a1000000-0000-4000-8000-0000000000a2'::uuid], array['${'b'.repeat(64)}'], '${fp2}',
          array['movement']);`);
      rev = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      assert.equal(rev, '2', 'a late object must bump the revision');
      // A family flag toggled (tremor enabled) with the SAME input bumps again.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${DAY}'::date,
          array['a1000000-0000-4000-8000-0000000000a2'::uuid], array['${'b'.repeat(64)}'], '${fp2}',
          array['movement','tremor']);`);
      rev = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      assert.equal(rev, '3', 'a family-set change must bump the revision');
      assert.equal((await db.sql(
        `select array_to_string(enabled_families, ',') from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim(),
      'movement,tremor', 'enabled_families must be stored');
      // Replay of the same fingerprint+families after the bump stays at 3.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${DAY}'::date,
          array['a1000000-0000-4000-8000-0000000000a2'::uuid], array['${'b'.repeat(64)}'], '${fp2}',
          array['movement','tremor']);`);
      rev = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${DAY}';`)).trim();
      assert.equal(rev, '3', 'post-bump replay must stay a no-op');
    });

    // The enqueue step left day 2026-10-07 dirty (revision 3, unfinished); complete it so the
    // claim/lease/fail steps exercise only their own fresh days.
    await db.sql(`
      update public.sensor_biomarker_jobs set completed_revision = input_revision,
        lease_token = null, lease_until = null
      where user_id='${U}' and device_id='${DEV}' and day='2026-10-07';`);

    await t.step('claim/lease/renew/expiry: single winner, renewal, expiry reclaim', async () => {
      // Fresh day so the earlier bumps do not interfere.
      const D = '2026-10-08';
      const fp = await fingerprintOf(db, ['c'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a3'::uuid], array['${'c'.repeat(64)}'], '${fp}',
          array['movement']);`);
      const first = await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`);
      const tok = first.trim();
      assert.notEqual(tok, '', 'claim must grant a lease token');
      const none = await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`);
      assert.equal(none.trim(), '', 'live lease must not be re-claimed');
      const ok = (await db.sql(`select public.renew_sensor_biomarker_day('${tok}'::uuid, 600)::text;`)).trim();
      assert.equal(ok, 'true', 'renew must succeed for a live lease');
      await db.sql(`
        update public.sensor_biomarker_jobs set lease_until = clock_timestamp() - interval '1 second'
        where lease_token = '${tok}'::uuid;`);
      const tok2 = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      assert.notEqual(tok2, tok, 'expired lease must be re-claimable with a fresh token');
      assert.equal((await db.sql(
        `select lease_expiry_count::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      '1', 'expiry must be counted');
    });

    await t.step('fail: bounded backoff, stale-release is clean, dead-letter after 8', async () => {
      const D = '2026-10-09';
      const fp = await fingerprintOf(db, ['d'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a4'::uuid], array['${'d'.repeat(64)}'], '${fp}',
          array['movement']);`);
      // Stale-revision failure releases without counting.
      let tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      await db.sql(`select public.fail_sensor_biomarker_day('${tok}'::uuid, 999, 'stale worker');`);
      assert.equal((await db.sql(
        `select consecutive_failures::text from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      '0', 'stale-revision failure must not count');
      assert.equal((await db.sql(
        `select lease_token is null from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      't', 'fail must clear the lease');
      // Eight real failures dead-letter.
      for (let i = 0; i < 8; i++) {
        await db.sql(`update public.sensor_biomarker_jobs set not_before = clock_timestamp()
          where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
        tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
        assert.notEqual(tok, '', 'job must stay claimable before dead-letter');
        await db.sql(`select public.fail_sensor_biomarker_day('${tok}'::uuid, 1, 'model error');`);
        if (i < 7) {
          assert.equal((await db.sql(
            `select dead_letter from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
          'f', 'must not dead-letter before 8');
        }
      }
      assert.equal((await db.sql(
        `select dead_letter and consecutive_failures = 8 from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      't', 'eighth failure must dead-letter');
      const nb = (await db.sql(
        `select not_before > clock_timestamp() from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim();
      assert.equal(nb, 't', 'dead-letter must still schedule a backoff');
      const claimed = await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`);
      assert.equal(claimed.trim(), '', 'dead-lettered job must not be claimable');
    });

    await t.step('publish fencing: stale token / wrong revision / expired lease publish NULL and write nothing', async () => {
      const D = '2026-10-10';
      const fp = await fingerprintOf(db, ['e'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a5'::uuid], array['${'e'.repeat(64)}'], '${fp}',
          array['movement','tremor']);`);
      const tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      const payload = JSON.stringify(publishPayload(D));
      const countDays = () => db.sql(
        `select count(*)::text from public.sensor_biomarker_days where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
      // Wrong revision.
      const r1 = (await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 999, '${payload.replaceAll("'", "''")}'::jsonb)::text;`)).trim();
      assert.equal(r1, '', 'stale revision must publish NULL');
      // Unknown token.
      const r2 = (await db.sql(
        `select public.publish_sensor_biomarker_day('a1000000-0000-4000-8000-0000000000ff'::uuid, 1, '${payload.replaceAll("'", "''")}'::jsonb)::text;`)).trim();
      assert.equal(r2, '', 'unknown token must publish NULL');
      // Expired lease.
      await db.sql(`update public.sensor_biomarker_jobs set lease_until = clock_timestamp() - interval '1 second'
        where lease_token = '${tok}'::uuid;`);
      const r3 = (await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${payload.replaceAll("'", "''")}'::jsonb)::text;`)).trim();
      assert.equal(r3, '', 'expired lease must publish NULL');
      assert.equal((await countDays()).trim(), '0', 'NULL publishes must never write a day row');
      // A newer result must never be overwritten by a stale worker: enqueue a new object (bump),
      // then publish with the OLD claimed revision -> NULL and the newer day row untouched.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a6'::uuid], array['${'f'.repeat(64)}'],
          '${await fingerprintOf(db, ['f'.repeat(64)], D)}', array['movement','tremor']);`);
      // Restore the stale lease so the stale worker's publish is evaluated against the NEW revision.
      await db.sql(`update public.sensor_biomarker_jobs set lease_token = '${tok}'::uuid,
        lease_until = clock_timestamp() + interval '10 minutes' where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
      const stale = (await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${payload.replaceAll("'", "''")}'::jsonb)::text;`)).trim();
      assert.equal(stale, '', 'a stale worker must not publish over a newer revision');
      assert.equal((await countDays()).trim(), '0', 'the stale publish must not write the day');
    });

    await t.step('publish: valid publish writes the day row, completes the job, republish replaces', async () => {
      const D = '2026-10-11';
      const fp = await fingerprintOf(db, ['g'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a7'::uuid], array['${'g'.repeat(64)}'], '${fp}',
          array['movement','tremor']);`);
      let tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      const payload = JSON.stringify(publishPayload(D));
      const rev = (await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${payload.replaceAll("'", "''")}'::jsonb)::text;`)).trim();
      assert.equal(rev, '1', 'valid publish must return a result');
      const row = await db.sql(`
        select input_revision, status, run_ms, families_ok, withheld_reasons,
               interval_start_utc, interval_end_utc
        from public.sensor_biomarker_days where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
      assert.ok(row.includes('sha256:' + 'a'.repeat(64)), 'input_revision column must be the document digest');
      assert.ok(row.includes('completed'), 'status column must be completed');
      assert.ok(row.includes('1234'), 'run_ms column must be recorded');
      assert.ok(row.includes('{movement}'), 'families_ok must contain only the ok family');
      assert.ok(row.includes('unknown_wrist_placement'), 'withheld_reasons must contain the withheld reason');
      assert.equal((await db.sql(
        `select completed_revision = input_revision and lease_token is null from public.sensor_biomarker_jobs where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      't', 'publish must complete the job and clear the lease');
      // A republish (new claim, same revision after the enqueue replay stays a no-op) replaces the row.
      await db.sql(`update public.sensor_biomarker_jobs set not_before = clock_timestamp()
        where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
      // Re-bump by adding a family so the job is dirty again.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a7'::uuid], array['${'g'.repeat(64)}'], '${fp}',
          array['movement','tremor','oscillation']);`);
      tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      const payload2 = JSON.stringify(publishPayload(D, {
        document: validDocument(D, 'sha256:' + 'b'.repeat(64)),
      }));
      await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 2, '${payload2.replaceAll("'", "''")}'::jsonb);`);
      const row2 = await db.sql(`
        select input_revision, families_ok from public.sensor_biomarker_days
        where user_id='${U}' and device_id='${DEV}' and day='${D}';`);
      assert.ok(row2.includes('sha256:' + 'b'.repeat(64)), 'republish must replace the row');
      assert.equal((await db.sql(
        `select count(*)::text from public.sensor_biomarker_days where user_id='${U}' and device_id='${DEV}' and day='${D}';`)).trim(),
      '1', 'republish must not leave a second row');
    });

    await t.step('publish: document contract — bad family, bad status, oversized, bad day are rejected', async () => {
      const D = '2026-10-12';
      const fp = await fingerprintOf(db, ['h'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${U}'::uuid, '${DEV}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a8'::uuid], array['${'h'.repeat(64)}'], '${fp}',
          array['movement']);`);
      const claim = async () => (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      const attempt = async (payload: unknown) => {
        const tok = await claim();
        if (!tok) return 'no_job';
        try {
          await db.sql(
            `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${JSON.stringify(payload).replaceAll("'", "''")}'::jsonb);`);
          return 'ok';
        } catch (e) {
          // A rejected document leaves the lease alive; release it so the next attempt re-claims.
          await db.sql(`
            update public.sensor_biomarker_jobs set lease_token = null, lease_until = null,
              not_before = clock_timestamp() where lease_token = '${tok}'::uuid;`);
          return String(e);
        }
      };
      // Unknown family key.
      const badFamily = publishPayload(D);
      badFamily.document = validDocument(D);
      (badFamily.document as any).families.extra_family = { status: 'ok', release_tier: 'descriptive',
        provider_revision: 'x/1', measurements: {}, reason_counts: {} };
      assert.ok(String(await attempt(badFamily)).includes('invalid_sensor_biomarker_family'));
      // Bad family status.
      const badStatus = publishPayload(D);
      (badStatus.document as any).families.movement.status = 'maybe';
      assert.ok(String(await attempt(badStatus)).includes('invalid_sensor_biomarker_family'));
      // Wrong day.
      const wrongDay = publishPayload('2026-10-13');
      assert.ok(String(await attempt(wrongDay)).includes('invalid_sensor_biomarker_payload'));
      // Oversized document (256 KiB budget).
      const huge = publishPayload(D);
      (huge.document as any).families.movement.measurements.big = 'x'.repeat(300_000);
      assert.ok(String(await attempt(huge)).includes('invalid_sensor_biomarker_size'));
    });

    await t.step('RLS: owners read only their own rows; no authenticated writes; service role can', async () => {
      const UB = 'a1000000-0000-4000-8000-000000000002';
      const DEVB = 'a1000000-0000-4000-8000-000000000012';
      await seedOwner(db, UB, DEVB);
      // USER_A (the harness's auth identity) owns a device with a published day; the owner
      // read below proves the select policy lets the REAL owner through.
      const DEVA = 'a1000000-0000-4000-8000-000000000013';
      await db.sql(`insert into public.devices(id,user_id,source_kind) values ('${DEVA}','${USER_A}','noop_push');`);
      const DA = '2026-10-17';
      const fpA = await fingerprintOf(db, ['z'.repeat(64)], DA);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${USER_A}'::uuid, '${DEVA}'::uuid, '${DA}'::date,
          array['a1000000-0000-4000-8000-0000000000c1'::uuid], array['${'z'.repeat(64)}'], '${fpA}',
          array['movement']);`);
      const tokA = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      await db.sql(
        `select public.publish_sensor_biomarker_day('${tokA}'::uuid, 1, '${JSON.stringify(publishPayload(DA)).replaceAll("'", "''")}'::jsonb);`);
      const D = '2026-10-14';
      const fp = await fingerprintOf(db, ['i'.repeat(64)], D);
      // A's job/day for B's device (cross-owner) and B's own job.
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${UB}'::uuid, '${DEVB}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000a9'::uuid], array['${'i'.repeat(64)}'], '${fp}',
          array['movement']);`);
      const tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${JSON.stringify(publishPayload(D)).replaceAll("'", "''")}'::jsonb);`);
      // As USER_A (owner of U), reading B's rows through PostgREST must see nothing.
      const asA = await db.request(`sensor_biomarker_days?user_id=eq.${UB}&select=user_id,day`, 'authenticated', USER_A);
      assert.equal(asA.status, 200);
      assert.equal(asA.body.length, 0, 'cross-owner day read must be empty');
      const asAJobs = await db.request(`sensor_biomarker_jobs?user_id=eq.${UB}&select=user_id`, 'authenticated', USER_A);
      assert.equal(asAJobs.body.length, 0, 'cross-owner job read must be empty');
      // A can read its own rows (the publish for USER_A's own device above).
      const own = await db.request(`sensor_biomarker_days?user_id=eq.${USER_A}&device_id=eq.${DEVA}&day=eq.${DA}&select=user_id,day`, 'authenticated', USER_A);
      assert.equal(own.status, 200);
      assert.equal(own.body.length, 1, 'owner must read their own day');
      // Authenticated users can never write the worker tables.
      const write = await db.request('sensor_biomarker_days?user_id=eq.0', 'authenticated', USER_A, 'POST', {});
      assert.ok(write.status === 401 || write.status === 403, `authenticated write must be refused (got ${write.status})`);
      // And cannot run the worker RPCs.
      const claimAuth = await db.request('rpc/claim_sensor_biomarker_day', 'authenticated', USER_A, 'POST', { p_lease_seconds: 300 });
      assert.ok(claimAuth.status === 401 || claimAuth.status === 403, `authenticated claim must be refused (got ${claimAuth.status})`);
      const enqueueAuth = await db.request('rpc/enqueue_sensor_biomarker_day', 'authenticated', USER_A, 'POST', {
        p_user: UB, p_device: DEVB, p_day: '2026-10-14',
        p_object_ids: ['a1000000-0000-4000-8000-0000000000a9'], p_digests: ['i'.repeat(64)],
        p_fingerprint: fp, p_enabled_families: ['movement'],
      });
      assert.ok(enqueueAuth.status === 401 || enqueueAuth.status === 403, `authenticated enqueue must be refused (got ${enqueueAuth.status})`);
      // Service role sees the queue.
      const svc = await db.rest.select('sensor_biomarker_jobs', `select=user_id&limit=100`);
      assert.ok(Array.isArray(svc) && svc.length > 0, 'service role must see the queue');
    });

    await t.step('reconcile: maps ready IMU + PPG objects to day jobs idempotently; late object bumps', async () => {
      const UR = 'a1000000-0000-4000-8000-000000000010';
      const DEVR = 'a1000000-0000-4000-8000-000000000020';
      await seedOwner(db, UR, DEVR);
      const DAYR = '2026-10-15';
      const imu = 'a1000000-0000-4000-8000-0000000000b1';
      const ppg = 'a1000000-0000-4000-8000-0000000000b2';
      await db.sql(`
        insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
          start_at,end_at,sha256,sha256_source,status,verified_at)
        values
          ('${imu}'::uuid,'${UR}'::uuid,'${DEVR}'::uuid,'raw','rawImuSession','sb-imu-1',
           '2026-10-15T00:10:00Z'::timestamptz,'2026-10-15T01:10:00Z'::timestamptz,
           '${'j'.repeat(64)}','server_verified','ready',clock_timestamp()),
          ('${ppg}'::uuid,'${UR}'::uuid,'${DEVR}'::uuid,'raw','ppgWaveformSample','sb-ppg-1',
           '2026-10-15T00:10:00Z'::timestamptz,'2026-10-15T01:10:00Z'::timestamptz,
           '${'k'.repeat(64)}','server_verified','ready',clock_timestamp());`);
      await db.sql(`select public.reconcile_sensor_biomarkers('30 days'::interval, array['movement','tremor']);`);
      const rev1 = (await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim();
      assert.equal(rev1, '1', 'reconcile must create the day job at revision 1');
      assert.equal((await db.sql(
        `select array_to_string(enabled_families, ',') from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim(),
      'movement,tremor', 'reconcile must pass the worker family set');
      assert.equal((await db.sql(
        `select cardinality(input_object_ids)::text from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim(),
      '2', 'reconcile must aggregate BOTH IMU and PPG objects');
      // Idempotent re-run: no revision bump.
      await db.sql(`select public.reconcile_sensor_biomarkers('30 days'::interval, array['movement','tremor']);`);
      assert.ok((await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim() === '1',
      'an identical reconcile must be a no-op');
      // A late object (new digest) bumps the revision.
      await db.sql(`
        insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
          start_at,end_at,sha256,sha256_source,status,verified_at)
        values ('a1000000-0000-4000-8000-0000000000b3'::uuid,'${UR}'::uuid,'${DEVR}'::uuid,'raw','rawImuSession',
          'sb-imu-2','2026-10-15T01:10:00Z'::timestamptz,'2026-10-15T02:10:00Z'::timestamptz,
          '${'l'.repeat(64)}','server_verified','ready',clock_timestamp());`);
      await db.sql(`select public.reconcile_sensor_biomarkers('30 days'::interval, array['movement','tremor']);`);
      assert.ok((await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim() === '2',
      'a late object must bump the revision');
      // A family flag change (only families differ) bumps even with unchanged inputs.
      await db.sql(`select public.reconcile_sensor_biomarkers('30 days'::interval, array['movement','tremor','oscillation']);`);
      assert.ok((await db.sql(
        `select input_revision::text from public.sensor_biomarker_jobs where user_id='${UR}' and device_id='${DEVR}' and day='${DAYR}';`)).trim() === '3',
      'a family-set change must bump the revision');
    });

    await t.step('deletion cascade: device and account deletion remove jobs and days', async () => {
      // Device cascade.
      const UD = 'a1000000-0000-4000-8000-000000000031';
      const DEVD = 'a1000000-0000-4000-8000-000000000041';
      await seedOwner(db, UD, DEVD);
      const D = '2026-10-16';
      const fp = await fingerprintOf(db, ['m'.repeat(64)], D);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${UD}'::uuid, '${DEVD}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000b4'::uuid], array['${'m'.repeat(64)}'], '${fp}',
          array['movement']);`);
      const tok = (await db.sql(`select lease_token::text from public.claim_sensor_biomarker_day(300);`)).trim();
      await db.sql(
        `select public.publish_sensor_biomarker_day('${tok}'::uuid, 1, '${JSON.stringify(publishPayload(D)).replaceAll("'", "''")}'::jsonb);`);
      await db.sql(`delete from public.devices where id = '${DEVD}'::uuid;`);
      assert.equal((await db.sql(
        `select count(*)::text from public.sensor_biomarker_jobs where user_id='${UD}' and device_id='${DEVD}';`)).trim(), '0');
      assert.equal((await db.sql(
        `select count(*)::text from public.sensor_biomarker_days where user_id='${UD}' and device_id='${DEVD}';`)).trim(), '0');
      // Account cascade: a second device for the same user, then delete the user.
      const DEVD2 = 'a1000000-0000-4000-8000-000000000042';
      await db.sql(`insert into public.devices(id,user_id,source_kind) values ('${DEVD2}','${UD}','noop_push');`);
      await db.sql(`
        select public.enqueue_sensor_biomarker_day('${UD}'::uuid, '${DEVD2}'::uuid, '${D}'::date,
          array['a1000000-0000-4000-8000-0000000000b4'::uuid], array['${'m'.repeat(64)}'], '${fp}',
          array['movement']);`);
      await db.sql(`delete from auth.users where id = '${UD}';`);
      assert.equal((await db.sql(
        `select count(*)::text from public.sensor_biomarker_jobs where user_id='${UD}';`)).trim(), '0');
      assert.equal((await db.sql(
        `select count(*)::text from public.sensor_biomarker_days where user_id='${UD}';`)).trim(), '0');
    });

    assert.ok(FAMILIES.length > 0, 'family fixture sanity');
  } finally {
    await db.close();
  }
});
