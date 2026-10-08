import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import {
  GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES,
  validateGroundTruthLabelItem,
} from '../_shared/groundTruthLabels.ts';

// Proves 20261007090000_activity_ground_truth_labels.sql against a throwaway local PostgreSQL +
// PostgREST (EDGE_TEST_ARTIFACTS), never a shared database:
//  1. the table, its constraints, indexes and comment exist, and the migration can be applied twice;
//  2. privilege hardening holds even when the schema's default privileges hand every new table to
//     anon/authenticated, the way Supabase's do;
//  3. RLS: an owner reads only their own rows, anon reads nothing, and no client role can insert,
//     update, delete or call the RPC;
//  4. upsert_activity_ground_truth_labels: first write = revision 1, a newer or equal client_updated_at
//     overwrites and bumps the revision, an older one is ignored as stale and changes nothing, batches
//     keep their order, device ownership is enforced, bad input raises and rolls the whole call back;
//  5. raw_refs enrichment: ready rawImuSession object_manifests rows overlapping the label interval
//     are appended (owner- and device-scoped, ordered by start_at), non-overlapping / not-ready /
//     cross-user / cross-device rows are excluded, and the combined array is capped at 64 entries
//     and 16 KiB of jsonb text;
//  6. everything the TypeScript validator accepts is storable (the CHECK constraints never reject it);
//  7. 20261007090001_activity_stretch_feedback_corrections.sql replaces the unnamed inline
//     corrected_label check with a named one that accepts the extended vocabulary;
//  8. 20261008100500_activity_ground_truth_confirmation_source.sql adds source='confirmation' (short,
//     posture-only, no transition), everything the validator accepts for it is storable, and it re-applies.

const OWN_DEVICE = '33333333-3333-4333-8333-333333333333';
const OTHER_DEVICE = '44444444-4444-4444-8444-444444444444';
const MISSING_DEVICE = '55555555-5555-4555-8555-555555555555';
const CLIENT_ID = '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11';
const T0 = 1_760_072_000;
const MIGRATION = '20261007090000_activity_ground_truth_labels.sql';

function entry(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    client_id: CLIENT_ID,
    label_key: `guided:activity-session:${T0}`,
    source: 'guided',
    session_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    protocol_version: 'calibration-v1',
    repetition: 1,
    device_id: OWN_DEVICE,
    external_device_id: 'whoop-ABC123456',
    start_ts: T0,
    end_ts: T0 + 900,
    posture: 'seated_likely',
    locomotion: 'stationary',
    arm_behavior: 'desk_like',
    transition_kind: 'sit_to_stand',
    transition_ts: T0 + 450,
    semantic_tag: 'desk_work',
    label_confidence: 0.92,
    user_unsure: false,
    note: 'guided desk bout',
    cue_context: { instruction_ts: T0 - 30, cue_start_ts: T0, cue_stop_ts: T0 + 900 },
    sensor_quality: { expected_seconds: 900, covered_seconds: 900, sample_rate_hz: 100, gaps: [] },
    raw_refs: [{ store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }],
    model_context_at_label_time: { decoder: 'hsmm-1.3', display: 'Desk sitting' },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-07T16:00:00.000Z',
    client_updated_at: '2026-10-07T16:05:00.000Z',
    ...over,
  };
}

Deno.test('ground truth labels: schema, privileges, RLS, the last-writer-wins upsert and raw_refs enrichment', async (t) => {
  const db = await startLocalPostgres();
  const apply = async (name: string) => {
    const path = new URL(`../../migrations/${name}`, import.meta.url);
    const result = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
        '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!result.success) throw new Error(`apply failed: ${new TextDecoder().decode(result.stderr).slice(-2000)}`);
  };
  const json = async (statement: string) => JSON.parse((await db.sql(statement)) || 'null');
  const stored = (owner = USER_A) => json(
    `select coalesce(json_agg(f order by f.label_key), '[]'::json) from public.activity_ground_truth_labels f where owner = '${owner}'`);
  const count = async (where = 'true') =>
    Number((await db.sql(`select count(*) from public.activity_ground_truth_labels where ${where}`)).trim());
  const countStretch = async (where = 'true') =>
    Number((await db.sql(`select count(*) from public.activity_stretch_feedback where ${where}`)).trim());
  const upsert = (owner: string, items: unknown[]) =>
    db.rest.rpc('upsert_activity_ground_truth_labels', { p_owner: owner, p_items: items });
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  const insertObject = (over: Record<string, unknown>) => db.sql(
    `insert into public.object_manifests(id, user_id, device_id, object_kind, object_key, status, start_at, end_at, sha256)
     values ('${over.id}', '${over.user_id}', ${over.device_id == null ? 'null' : `'${over.device_id}'`},
             'rawImuSession', '${over.object_key}', '${over.status}', ${over.start_at}, ${over.end_at}, '${over.sha256}')`);

  try {
    // Supabase hands every new table and function to anon/authenticated through default privileges. Model
    // that here so the migration's own revokes are what is being proven, not the harness's absence of grants.
    await db.sql(`alter default privileges in schema public grant all on tables to anon, authenticated;
      alter default privileges in schema public grant execute on functions to anon, authenticated;`);
    await apply(MIGRATION);
    await db.sql("notify pgrst, 'reload schema';");
    await sleep(700);
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id)
      values ('${OWN_DEVICE}','${USER_A}','noop_push','whoop-ABC123456'),
             ('${OTHER_DEVICE}','${USER_B}','noop_push','whoop-ZZZ999999');`);

    await t.step('schema: columns, constraints, indexes and purpose comment', async () => {
      const columns = await db.sql(`select column_name || ':' || data_type || ':' || is_nullable
        from information_schema.columns where table_schema='public' and table_name='activity_ground_truth_labels'
        order by ordinal_position`);
      for (const expected of ['id:uuid:NO', 'owner:uuid:NO', 'client_id:uuid:NO', 'label_key:text:NO', 'source:text:NO',
        'session_id:text:YES', 'protocol_version:text:YES', 'repetition:integer:YES', 'device_id:uuid:YES',
        'external_device_id:text:YES', 'start_ts:bigint:NO', 'end_ts:bigint:NO', 'posture:text:YES',
        'locomotion:text:YES', 'arm_behavior:text:YES', 'transition_kind:text:YES', 'transition_ts:bigint:YES',
        'semantic_tag:text:YES', 'label_confidence:real:YES', 'user_unsure:boolean:NO', 'note:text:YES',
        'cue_context:jsonb:NO', 'sensor_quality:jsonb:NO', 'raw_refs:jsonb:NO', 'model_context_at_label_time:jsonb:NO',
        'app_version:text:YES', 'app_build:text:YES', 'tz_offset_s:integer:YES', 'client_created_at:timestamp with time zone:YES',
        'client_updated_at:timestamp with time zone:NO', 'revision:integer:NO', 'created_at:timestamp with time zone:NO',
        'updated_at:timestamp with time zone:NO']) {
        assert(columns.includes(expected), `missing column ${expected}`);
      }
      const indexes = await db.sql(`select indexdef from pg_indexes where schemaname='public' and tablename='activity_ground_truth_labels'`);
      assert.match(indexes, /UNIQUE.*\(owner, label_key\)/);
      assert.match(indexes, /\(owner, start_ts\)/);
      assert.match(indexes, /\(source\)/);
      assert.match(indexes, /\(device_id\) WHERE/);
      const comment = await db.sql(`select obj_description('public.activity_ground_truth_labels'::regclass,'pg_class')`);
      assert.match(comment, /ground-truth/i);
      assert.match(await db.sql(`select relrowsecurity from pg_class where oid='public.activity_ground_truth_labels'::regclass`), /^t$/);
      const owner = await db.sql(`select confdeltype from pg_constraint
        where conrelid='public.activity_ground_truth_labels'::regclass and contype='f' and confrelid='auth.users'::regclass`);
      assert.equal(owner.trim(), 'c', 'deleting the account deletes its labels');
      const device = await db.sql(`select confdeltype from pg_constraint
        where conrelid='public.activity_ground_truth_labels'::regclass and contype='f' and confrelid='public.devices'::regclass`);
      assert.equal(device.trim(), 'n', 'deleting a device keeps the label and clears the device');
    });

    await t.step('privileges: clients may only select; only the service role writes or executes the RPC', async () => {
      const has = async (role: string, privileges: string) => (await db.sql(
        `select has_table_privilege('${role}','public.activity_ground_truth_labels','${privileges}')`)).trim() === 't';
      assert.equal(await has('anon', 'select'), false);
      for (const privilege of ['insert', 'update', 'delete', 'truncate', 'references', 'trigger']) {
        assert.equal(await has('anon', privilege), false, `anon ${privilege}`);
        assert.equal(await has('authenticated', privilege), false, `authenticated ${privilege}`);
      }
      assert.equal(await has('authenticated', 'select'), true);
      for (const privilege of ['select', 'insert', 'update', 'delete']) {
        assert.equal(await has('service_role', privilege), true, `service_role ${privilege}`);
      }
      const fn = `'public.upsert_activity_ground_truth_labels(uuid,jsonb)'::regprocedure`;
      const canExecute = async (role: string) =>
        (await db.sql(`select has_function_privilege('${role}', ${fn}, 'execute')`)).trim() === 't';
      assert.equal(await canExecute('anon'), false);
      assert.equal(await canExecute('authenticated'), false);
      assert.equal(await canExecute('service_role'), true);
      const publicGrants = await db.sql(`select count(*) from pg_proc p,
        aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = ${fn} and a.grantee = 0`);
      assert.equal(publicGrants.trim(), '0', 'PUBLIC must not keep EXECUTE');
      const definer = await db.sql(`select prosecdef || '|' || coalesce(array_to_string(proconfig, ','), '') from pg_proc where oid = ${fn}`);
      assert.match(definer, /^true\|search_path=""$/, 'SECURITY DEFINER with an empty search_path');
      const policies = await db.sql(`select policyname || ':' || cmd || ':' || array_to_string(roles, ',')
        from pg_policies where schemaname='public' and tablename='activity_ground_truth_labels' order by policyname`);
      assert.equal(policies, [
        'activity_ground_truth_labels_select_own:SELECT:authenticated',
        'activity_ground_truth_labels_service:ALL:service_role',
      ].join('\n'));
    });

    await t.step('RPC: first write is revision 1 and is readable', async () => {
      const result: any = await upsert(USER_A, [entry()]);
      assert.deepEqual(result, { saved: [{ label_key: `guided:activity-session:${T0}`, revision: 1 }], ignored: [] });
      const [row] = await stored();
      assert.equal(row.owner, USER_A);
      assert.equal(row.client_id, CLIENT_ID);
      assert.equal(row.source, 'guided');
      assert.equal(row.device_id, OWN_DEVICE);
      assert.equal(row.external_device_id, 'whoop-ABC123456');
      assert.equal(row.posture, 'seated_likely');
      assert.equal(row.locomotion, 'stationary');
      assert.equal(row.arm_behavior, 'desk_like');
      assert.equal(row.transition_kind, 'sit_to_stand');
      assert.equal(row.transition_ts, T0 + 450);
      assert.equal(row.semantic_tag, 'desk_work');
      assert.equal(row.label_confidence, 0.92);
      assert.equal(row.user_unsure, false);
      assert.deepEqual(row.cue_context, { instruction_ts: T0 - 30, cue_start_ts: T0, cue_stop_ts: T0 + 900 });
      assert.deepEqual(row.sensor_quality, { expected_seconds: 900, covered_seconds: 900, sample_rate_hz: 100, gaps: [] });
      assert.equal(row.revision, 1);
      assert.equal(row.start_ts, T0);
      assert.equal(row.tz_offset_s, -25200);
      assert.equal(new Date(row.client_updated_at).toISOString(), '2026-10-07T16:05:00.000Z');
      // No manifests exist yet, so the enriched array is exactly the phone's own facts.
      assert.deepEqual(row.raw_refs, [{ store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }]);
    });

    await t.step('raw_refs enrichment: ready overlapping manifests are appended, everything else excluded', async () => {
      // Object 1 and 2 overlap the label interval on A's own device; 3 is after the interval;
      // 4 overlaps but is not ready; 5 overlaps but belongs to a different device; 6 is B's object.
      await insertObject({ id: '10000000-0000-4000-8000-000000000001', user_id: USER_A, device_id: OWN_DEVICE,
        object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj1.bin.zst', status: 'ready',
        start_at: `to_timestamp(${T0 - 100})`, end_at: `to_timestamp(${T0 + 400})`, sha256: 'a'.repeat(64) });
      await insertObject({ id: '10000000-0000-4000-8000-000000000002', user_id: USER_A, device_id: OWN_DEVICE,
        object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj2.bin.zst', status: 'ready',
        start_at: `to_timestamp(${T0 + 400})`, end_at: `to_timestamp(${T0 + 1000})`, sha256: 'b'.repeat(64) });
      await insertObject({ id: '10000000-0000-4000-8000-000000000003', user_id: USER_A, device_id: OWN_DEVICE,
        object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj3.bin.zst', status: 'ready',
        start_at: `to_timestamp(${T0 + 2000})`, end_at: `to_timestamp(${T0 + 3000})`, sha256: 'c'.repeat(64) });
      await insertObject({ id: '10000000-0000-4000-8000-000000000004', user_id: USER_A, device_id: OWN_DEVICE,
        object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj4.bin.zst', status: 'pending',
        start_at: `to_timestamp(${T0 - 50})`, end_at: `to_timestamp(${T0 + 500})`, sha256: 'd'.repeat(64) });
      await insertObject({ id: '10000000-0000-4000-8000-000000000005', user_id: USER_A, device_id: OTHER_DEVICE,
        object_key: 'v3/research/users/a/devices/e/rawImuSession/2026/10/07/00/obj5.bin.zst', status: 'ready',
        start_at: `to_timestamp(${T0 - 50})`, end_at: `to_timestamp(${T0 + 500})`, sha256: 'e'.repeat(64) });
      await insertObject({ id: '10000000-0000-4000-8000-000000000006', user_id: USER_B, device_id: OTHER_DEVICE,
        object_key: 'v3/research/users/b/devices/f/rawImuSession/2026/10/07/00/obj6.bin.zst', status: 'ready',
        start_at: `to_timestamp(${T0 - 50})`, end_at: `to_timestamp(${T0 + 500})`, sha256: 'f'.repeat(64) });

      // A's own device: obj1 and obj2 are appended (ordered by start_at), nothing else.
      const result: any = await upsert(USER_A, [entry({ label_key: `guided:activity-session:${T0 + 1}`,
        client_updated_at: '2026-10-07T16:06:00.000Z' })]);
      assert.equal(result.saved.length, 1);
      const row = (await stored()).find((r: any) => r.label_key === `guided:activity-session:${T0 + 1}`);
      assert.equal(row.raw_refs.length, 3);
      assert.deepEqual(row.raw_refs[0], { store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 });
      assert.deepEqual(row.raw_refs[1], {
        id: '10000000-0000-4000-8000-000000000001', object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj1.bin.zst',
        sha256: 'a'.repeat(64), start_ts: T0 - 100, end_ts: T0 + 400 });
      assert.deepEqual(row.raw_refs[2], {
        id: '10000000-0000-4000-8000-000000000002', object_key: 'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj2.bin.zst',
        sha256: 'b'.repeat(64), start_ts: T0 + 400, end_ts: T0 + 1000 });

      // No device (or an unowned one): enrichment spans every ready object of the owner, so obj5 joins.
      const noDevice: any = await upsert(USER_A, [entry({ label_key: 'guided:activity-session:2000000001',
        start_ts: T0, end_ts: T0 + 900, device_id: null, external_device_id: null,
        client_updated_at: '2026-10-07T16:07:00.000Z' })]);
      assert.equal(noDevice.saved.length, 1);
      const rows = await stored();
      const nodev = rows.find((r: any) => r.label_key === 'guided:activity-session:2000000001');
      const keys = nodev.raw_refs.map((r: any) => r.object_key).filter(Boolean);
      assert.deepEqual(keys, [
        'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj1.bin.zst',
        'v3/research/users/a/devices/e/rawImuSession/2026/10/07/00/obj5.bin.zst',
        'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj2.bin.zst',
      ], "no-device labels enrich across all of the owner's ready objects, ordered by start, still excluding B and not-ready rows");

      // A label from B enriches only B's objects.
      const other: any = await upsert(USER_B, [entry({ label_key: 'guided:activity-session:2000000002',
        start_ts: T0, end_ts: T0 + 900, device_id: OTHER_DEVICE, external_device_id: 'whoop-ZZZ999999',
        client_updated_at: '2026-10-07T16:08:00.000Z' })]);
      assert.equal(other.saved.length, 1);
      const bRows = await stored(USER_B);
      const brow = bRows.find((r: any) => r.label_key === 'guided:activity-session:2000000002');
      assert.deepEqual(brow.raw_refs.map((r: any) => r.object_key).filter(Boolean),
        ['v3/research/users/b/devices/f/rawImuSession/2026/10/07/00/obj6.bin.zst']);
    });

    await t.step('raw_refs caps: at most 64 entries, and 16 KiB of jsonb text', async () => {
      // 70 overlapping ready objects on A's device, in an interval isolated from the earlier labels.
      for (let n = 0; n < 70; n++) {
        const id = `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
        await db.sql(`insert into public.object_manifests(id, user_id, device_id, object_kind, object_key, status, start_at, end_at, sha256)
          values ('${id}', '${USER_A}', '${OWN_DEVICE}', 'rawImuSession', 'v3/research/cap/obj${n}.bin.zst',
                  'ready', to_timestamp(${T0 + 10_000 + n}), to_timestamp(${T0 + 10_000 + n + 100}), '${'0'.repeat(64)}')`);
      }
      const capped: any = await upsert(USER_A, [entry({ label_key: 'guided:a:cap:1',
        start_ts: T0 + 10_000, end_ts: T0 + 10_900, transition_kind: null, transition_ts: null,
        device_id: OWN_DEVICE, raw_refs: [],
        client_updated_at: '2026-10-07T16:09:00.000Z' })]);
      assert.equal(capped.saved.length, 1);
      const rows = await stored();
      const row = rows.find((r: any) => r.label_key === 'guided:a:cap:1');
      assert.equal(row.raw_refs.length, 64, 'the enriched array is capped at 64 entries');
      // Earliest objects win: they are ordered by start_at and the tail is cut.
      assert.equal(row.raw_refs[0].id, '20000000-0000-4000-8000-000000000000');
      assert.equal(row.raw_refs[63].id, '20000000-0000-4000-8000-000000000063');
      assert.ok(Number((await db.sql(`select octet_length(raw_refs::text) from public.activity_ground_truth_labels
        where label_key='guided:a:cap:1'`)).trim()) <= 16384);

      // A client raw_refs array at the validator's 16 KiB compact-JSON edge (exactly 16384 bytes)
      // grows past 16 KiB once jsonb renders it; the RPC trims from the end until the stored text
      // fits, so the table CHECK never rejects it. One over-budget ref is dropped entirely.
      const bigRefs = [{ store_session_id: 'x'.repeat(16_273), start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }];
      const compactBytes = new TextEncoder().encode(JSON.stringify(bigRefs)).length;
      assert.ok(compactBytes <= 16 * 1024, `compact raw_refs is ${compactBytes} bytes`);
      const trimmed: any = await upsert(USER_A, [entry({ label_key: 'guided:a:cap:2',
        start_ts: T0 + 11_000, end_ts: T0 + 11_900, transition_kind: null, transition_ts: null,
        device_id: OWN_DEVICE, raw_refs: bigRefs,
        client_updated_at: '2026-10-07T16:10:00.000Z' })]);
      assert.equal(trimmed.saved.length, 1);
      const rows2 = await stored();
      const row2 = rows2.find((r: any) => r.label_key === 'guided:a:cap:2');
      assert.deepEqual(row2.raw_refs, [], 'an over-budget ref is trimmed away rather than violating the CHECK');
      const storedBytes = Number((await db.sql(`select octet_length(raw_refs::text) from public.activity_ground_truth_labels
        where label_key='guided:a:cap:2'`)).trim());
      assert.ok(storedBytes <= 16384, `stored raw_refs text is ${storedBytes} bytes`);
    });

    await t.step('RLS: an owner reads only their own rows; anon reads nothing', async () => {
      const own = await db.request('activity_ground_truth_labels?select=label_key,note', 'authenticated', USER_A);
      assert.equal(own.status, 200);
      assert.ok(own.body.length >= 2);
      assert.ok(own.body.every((row: any) => typeof row.label_key === 'string'));
      const probe = await db.request(`activity_ground_truth_labels?owner=eq.${USER_B}`, 'authenticated', USER_A);
      assert.equal(probe.status, 200);
      assert.deepEqual(probe.body, [], 'A must not see B rows even when asking for them');
      const anon = await db.request('activity_ground_truth_labels', 'anon', USER_A);
      assert.ok([401, 403].includes(anon.status), `anon must be refused, got ${anon.status}`);
    });

    await t.step('no client role can insert, update, delete or call the RPC', async () => {
      const before = await stored();
      const insert = await db.request('activity_ground_truth_labels', 'authenticated', USER_A, 'POST', {
        owner: USER_A, client_id: CLIENT_ID, label_key: 'guided:x:1999999999', source: 'guided',
        start_ts: T0, end_ts: T0 + 60, client_updated_at: '2026-10-07T16:05:00Z',
      });
      assert.ok([401, 403].includes(insert.status), `insert refused, got ${insert.status}`);
      const update = await db.request(`activity_ground_truth_labels?owner=eq.${USER_A}`, 'authenticated', USER_A, 'PATCH',
        { user_unsure: true });
      assert.ok([401, 403].includes(update.status), `update refused, got ${update.status}`);
      const remove = await db.request(`activity_ground_truth_labels?owner=eq.${USER_A}`, 'authenticated', USER_A, 'DELETE');
      assert.ok([401, 403].includes(remove.status), `delete refused, got ${remove.status}`);
      for (const role of ['authenticated', 'anon']) {
        const rpc = await db.request('rpc/upsert_activity_ground_truth_labels', role, USER_A, 'POST',
          { p_owner: USER_A, p_items: [entry({ label_key: 'guided:x:1888888888' })] });
        assert.ok([401, 403].includes(rpc.status), `${role} rpc refused, got ${rpc.status}`);
      }
      assert.deepEqual(await stored(), before, 'nothing changed');
    });

    await t.step('RPC: a newer client_updated_at overwrites everything and bumps the revision', async () => {
      const [before] = (await stored()).filter((r: any) => r.label_key === `guided:activity-session:${T0}`);
      await sleep(5);
      const result: any = await upsert(USER_A, [entry({
        client_id: '6a1e4c5d-2b3f-4d6e-8f70-1a2b3c4d5e6f', source: 'stretch_feedback',
        session_id: null, protocol_version: null, repetition: null,
        posture: null, locomotion: 'walking', arm_behavior: null, transition_kind: null,
        transition_ts: null, semantic_tag: null, label_confidence: null, user_unsure: true,
        note: null, cue_context: {}, sensor_quality: {}, raw_refs: [],
        model_context_at_label_time: {}, app_version: '11.8.1', app_build: '432', tz_offset_s: 3600,
        start_ts: T0 + 1, end_ts: T0 + 1000, client_created_at: null,
        client_updated_at: '2026-10-07T16:11:00.000Z',
      })]);
      assert.deepEqual(result, { saved: [{ label_key: `guided:activity-session:${T0}`, revision: 2 }], ignored: [] });
      const rows = await stored();
      const after = rows.find((r: any) => r.label_key === `guided:activity-session:${T0}`);
      assert.equal(rows.filter((r: any) => r.label_key === `guided:activity-session:${T0}`).length, 1, 'same (owner, label_key) stays one row');
      assert.equal(after.id, before.id);
      assert.equal(after.created_at, before.created_at);
      assert.ok(new Date(after.updated_at) > new Date(before.updated_at));
      assert.equal(after.client_id, '6a1e4c5d-2b3f-4d6e-8f70-1a2b3c4d5e6f');
      assert.equal(after.source, 'stretch_feedback');
      assert.equal(after.posture, null);
      assert.equal(after.locomotion, 'walking');
      assert.equal(after.user_unsure, true);
      assert.equal(after.label_confidence, null);
      assert.equal(after.app_version, '11.8.1');
      assert.equal(after.tz_offset_s, 3600);
      assert.equal(after.start_ts, T0 + 1);
      assert.equal(after.revision, 2);
      // The update re-runs raw_refs enrichment for the new interval: obj1 and obj2 overlap
      // [T0+1, T0+1000] on the owner's device, so they are appended to the empty client array.
      assert.deepEqual(after.raw_refs.map((r: any) => r.object_key).filter(Boolean), [
        'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj1.bin.zst',
        'v3/research/users/a/devices/d/rawImuSession/2026/10/07/00/obj2.bin.zst',
      ]);
      assert.equal(new Date(after.client_updated_at).toISOString(), '2026-10-07T16:11:00.000Z');
      assert.equal(new Date(after.client_created_at).toISOString(), '2026-10-07T16:00:00.000Z',
        'a missing client_created_at does not erase the original');
    });

    await t.step('RPC: an older client_updated_at is ignored as stale and changes nothing', async () => {
      const before = await stored();
      const result: any = await upsert(USER_A, [entry({
        note: 'stale write', user_unsure: true,
        client_updated_at: '2026-10-07T16:10:59.999Z',
      })]);
      assert.deepEqual(result, { saved: [], ignored: [{ label_key: `guided:activity-session:${T0}`, reason: 'stale' }] });
      assert.deepEqual(await stored(), before);
    });

    await t.step('RPC: an equal client_updated_at is not older, so it overwrites and bumps the revision', async () => {
      const result: any = await upsert(USER_A, [entry({ note: 'same instant',
        client_updated_at: '2026-10-07T16:11:00.000Z' })]);
      assert.deepEqual(result.saved, [{ label_key: `guided:activity-session:${T0}`, revision: 3 }]);
      const after = (await stored()).find((r: any) => r.label_key === `guided:activity-session:${T0}`);
      assert.equal(after.note, 'same instant');
      assert.equal(after.revision, 3);
    });

    await t.step('RPC: a batch is applied in order with a per-item outcome', async () => {
      const key = (n: number) => `guided:activity-session:${T0 + n * 1000}`;
      const result: any = await upsert(USER_A, [
        entry({ label_key: key(1), client_updated_at: '2026-10-07T17:00:00.000Z' }),
        entry({ label_key: `guided:activity-session:${T0}`, client_updated_at: '2026-10-07T10:00:00.000Z' }),
        entry({ label_key: key(2), client_updated_at: '2026-10-07T17:00:00.000Z' }),
        entry({ label_key: key(1), note: 'again', client_updated_at: '2026-10-07T17:00:01.000Z' }),
        entry({ label_key: key(2), note: 'older duplicate', client_updated_at: '2026-10-07T16:59:00.000Z' }),
      ]);
      assert.deepEqual(result, {
        saved: [{ label_key: key(1), revision: 1 }, { label_key: key(2), revision: 1 }, { label_key: key(1), revision: 2 }],
        ignored: [{ label_key: `guided:activity-session:${T0}`, reason: 'stale' }, { label_key: key(2), reason: 'stale' }],
      });
      const rows = await stored();
      assert.equal(rows.find((r: any) => r.label_key === key(1)).note, 'again');
      assert.equal(rows.find((r: any) => r.label_key === key(2)).note, 'guided desk bout');
    });

    await t.step('RPC: a device the owner does not have is stored as no device, and the item is kept', async () => {
      const result: any = await upsert(USER_A, [
        entry({ label_key: 'guided:a:100000001', device_id: OTHER_DEVICE, external_device_id: 'whoop-ZZZ999999' }),
        entry({ label_key: 'guided:a:100000002', device_id: MISSING_DEVICE }),
        entry({ label_key: 'guided:a:100000003', device_id: null, external_device_id: null }),
        entry({ label_key: 'guided:a:100000004', device_id: OWN_DEVICE }),
      ]);
      assert.equal(result.saved.length, 4);
      const rows = await stored();
      const byKey = (key: string) => rows.find((r: any) => r.label_key === key);
      assert.equal(byKey('guided:a:100000001').device_id, null);
      assert.equal(byKey('guided:a:100000001').external_device_id, 'whoop-ZZZ999999');
      assert.equal(byKey('guided:a:100000002').device_id, null);
      assert.equal(byKey('guided:a:100000003').device_id, null);
      assert.equal(byKey('guided:a:100000004').device_id, OWN_DEVICE);
      // Another account's identical label_key is a different row.
      await upsert(USER_B, [entry({ label_key: 'guided:a:100000004', device_id: OTHER_DEVICE })]);
      assert.equal(await count(`label_key = 'guided:a:100000004'`), 2);
      assert.equal(byKey('guided:a:100000004').owner, USER_A);
    });

    await t.step('RPC: bad input raises and rolls the whole call back', async () => {
      const before = await stored();
      const bad = (message: RegExp, owner: unknown, items: unknown) =>
        assert.rejects(() => db.rest.rpc('upsert_activity_ground_truth_labels', { p_owner: owner, p_items: items }), message);
      await bad(/invalid_items/, USER_A, []);
      await bad(/invalid_items/, USER_A, Array.from({ length: 26 }, (_, n) => entry({ label_key: `guided:a:${2e9 + n}` })));
      await bad(/invalid_items/, USER_A, { label_key: 'x' });
      await bad(/invalid_items/, USER_A, null);
      await bad(/invalid_owner|null value|violates|failed/, null, [entry()]);
      await bad(/violates check constraint|failed \(400\)/, USER_A, [
        entry({ label_key: 'guided:a:2100000001' }), entry({ label_key: 'guided:a:2100000002', source: 'sleep' })]);
      await bad(/failed/, '66666666-6666-4666-8666-666666666666', [entry({ label_key: 'guided:a:2100000003' })]);
      assert.deepEqual(await stored(), before, 'a failed call leaves no partial batch behind');
      assert.equal(await count(`label_key like 'guided:a:21%'`), 0);
    });

    await t.step('RPC: a caller that is signed in as someone else is refused', async () => {
      const item = JSON.stringify([entry({ label_key: 'guided:a:2200000001' })]).replaceAll("'", "''");
      await assert.rejects(() => db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub','${USER_B}',true);
        select public.upsert_activity_ground_truth_labels('${USER_A}'::uuid,'${item}'::jsonb); rollback;`), /cross_user_caller/);
      assert.equal(await count(`label_key = 'guided:a:2200000001'`), 0);
      const own = await db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub','${USER_A}',true);
        select public.upsert_activity_ground_truth_labels('${USER_A}'::uuid,'${item}'::jsonb)::jsonb->'saved'; rollback;`);
      assert.match(own, /"revision": 1/);
    });

    await t.step('CHECK constraints are a backstop for anything that bypasses the edge validation', async () => {
      const insert = (over: Record<string, string>) => {
        const values: Record<string, string> = {
          owner: `'${USER_A}'`, client_id: `'${CLIENT_ID}'`, label_key: `'guided:a:2300000001'`,
          source: `'guided'`, start_ts: `${T0}`, end_ts: `${T0 + 60}`, posture: 'null',
          locomotion: 'null', arm_behavior: 'null', transition_kind: 'null', transition_ts: 'null',
          semantic_tag: 'null', label_confidence: 'null', note: 'null', cue_context: `'{}'::jsonb`,
          sensor_quality: `'{}'::jsonb`, raw_refs: `'[]'::jsonb`, model_context_at_label_time: `'{}'::jsonb`,
          client_updated_at: `'2026-10-07T16:05:00Z'`, ...over,
        };
        return db.sql(`insert into public.activity_ground_truth_labels(${Object.keys(values).join(',')})
          values (${Object.values(values).join(',')})`);
      };
      await insert({});
      await db.sql(`delete from public.activity_ground_truth_labels where label_key = 'guided:a:2300000001'`);
      const rejections: Record<string, Record<string, string>> = {
        'bad label_key': { label_key: `'has space'` },
        'empty label_key': { label_key: `''` },
        'long label_key': { label_key: `'${'k'.repeat(97)}'` },
        'source': { source: `'sleep'` },
        'start before 2000': { start_ts: '946684800', end_ts: '946684900' },
        'end not after start': { end_ts: `${T0}` },
        'span over a day': { end_ts: `${T0 + 86401}` },
        'posture': { posture: `'standing'` },
        'locomotion': { locomotion: `'sitting'` },
        'arm_behavior': { arm_behavior: `'typing'` },
        'transition kind _like': { transition_kind: `'sit_to_stand_like'` },
        'transition ts outside': { transition_ts: `${T0 + 61}` },
        'semantic tag': { semantic_tag: `'running'` },
        'confidence over 1': { label_confidence: '1.5' },
        'confidence under 0': { label_confidence: '-0.1' },
        'long note': { note: `'${'n'.repeat(281)}'` },
        'cue_context array': { cue_context: `'[]'::jsonb` },
        'cue_context scalar': { cue_context: `'1'::jsonb` },
        'cue_context too large': { cue_context: `jsonb_build_object('blob', repeat('x', 33000))` },
        'sensor_quality array': { sensor_quality: `'[]'::jsonb` },
        'model_context array': { model_context_at_label_time: `'[]'::jsonb` },
        'raw_refs object': { raw_refs: `'{}'::jsonb` },
        'raw_refs too large': { raw_refs: `jsonb_build_array(jsonb_build_object('store_session_id', repeat('x', 17000)))` },
        'long app_version': { app_version: `'${'v'.repeat(33)}'` },
        'tz offset': { tz_offset_s: '64801' },
        'revision': { revision: '0' },
        'external device id': { external_device_id: `''` },
      };
      for (const [name, over] of Object.entries(rejections)) {
        await assert.rejects(() => insert(over), /violates check constraint/, name);
      }
      assert.equal(await count(`label_key like 'guided:a:23%'`), 0);
    });

    await t.step('everything the validator accepts can be stored', async () => {
      const worstCaseNumbers = { a: Array.from({ length: 8188 }, () => 1) };
      assert.equal(new TextEncoder().encode(JSON.stringify(worstCaseNumbers)).length, GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES - 1);
      const nested = (() => {
        let value: unknown = { leaf: 'é' };
        for (let level = 1; level < 32; level++) value = { n: value };
        return value as Record<string, unknown>;
      })();
      const inputs = [
        { label_key: 'guided:a:3000000001', note: '😀'.repeat(280), session_id: 'é'.repeat(64) },
        { label_key: 'guided:a:3000000002', cue_context: worstCaseNumbers },
        { label_key: 'guided:a:3000000003', sensor_quality: nested },
        { label_key: 'guided:a:3000000004', model_context_at_label_time: { blob: 'é'.repeat(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES / 2 - 8) } },
        { label_key: 'guided:a:3000000005', raw_refs: [{ store_session_id: 's'.repeat(2000), start_ts: T0, end_ts: T0 + 60, sample_rate_hz: 100, covered_seconds: 60 }] },
        { label_key: 'guided:a:3000000006', client_updated_at: '2026-10-07T09:05:00.123456-07:00', client_created_at: '2028-02-29T23:59:59Z' },
        { label_key: 'guided:a:3000000007', source: 'imported', session_id: undefined, protocol_version: undefined,
          repetition: undefined, posture: undefined, locomotion: undefined, arm_behavior: undefined,
          transition_kind: undefined, transition_ts: undefined, semantic_tag: undefined, label_confidence: undefined,
          user_unsure: undefined, note: undefined, cue_context: undefined, sensor_quality: undefined,
          raw_refs: undefined, model_context_at_label_time: undefined, app_version: undefined, app_build: undefined,
          tz_offset_s: undefined, client_created_at: undefined, device_id: undefined },
        { label_key: 'guided:a:3000000008', start_ts: 946684801, end_ts: 946684802, tz_offset_s: -64800, label_confidence: 1, repetition: 0, user_unsure: true, transition_ts: 946684801 },
        { label_key: 'k'.repeat(96), start_ts: T0, end_ts: T0 + 86400, tz_offset_s: 64800, label_confidence: 0 },
      ];
      const items = inputs.map((over) => {
        const result = validateGroundTruthLabelItem({
          id: CLIENT_ID, source: 'guided', start_ts: T0, end_ts: T0 + 60,
          posture: 'recumbent', locomotion: 'stationary', arm_behavior: 'quiet', transition_kind: 'sit_to_stand',
          transition_ts: T0 + 30, client_updated_at: '2026-10-07T16:05:00Z', ...over,
        });
        assert.ok(result.ok, `${over.label_key} must validate: ${JSON.stringify((result as any).rejection)}`);
        return { ...result.item, device_id: null };
      });
      const result: any = await upsert(USER_A, items);
      assert.equal(result.saved.length, inputs.length);
      assert.deepEqual(result.ignored, []);
      const rows = await stored();
      const row = (key: string) => rows.find((candidate: any) => candidate.label_key === key);
      assert.equal(row('guided:a:3000000001').note, '😀'.repeat(280));
      assert.deepEqual(row('guided:a:3000000003').sensor_quality, nested);
      assert.equal(new Date(row('guided:a:3000000006').client_updated_at).toISOString(), '2026-10-07T16:05:00.123Z');
      assert.equal(new Date(row('guided:a:3000000006').client_created_at).toISOString(), '2028-02-29T23:59:59.000Z');
      assert.equal(Object.keys(row('guided:a:3000000007').cue_context).length, 0);
      assert.equal(row('k'.repeat(96)).end_ts - row('k'.repeat(96)).start_ts, 86400);
      const sizes = await json(`select json_agg(octet_length(cue_context::text) order by label_key)
        from public.activity_ground_truth_labels where label_key = 'guided:a:3000000002'`);
      assert.ok(sizes[0] > GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES && sizes[0] <= 32768,
        `worst-case jsonb text is ${sizes[0]} bytes: over the edge cap, inside the database bound`);
    });

    await t.step('deleting a device keeps the label; deleting the account removes it', async () => {
      await db.sql(`delete from public.devices where id = '${OWN_DEVICE}'`);
      assert.equal(await count(`owner = '${USER_A}' and device_id is not null`), 0);
      assert.ok(await count(`owner = '${USER_A}'`) > 0);
      await db.sql(`delete from auth.users where id = '${USER_B}'`);
      assert.equal(await count(`owner = '${USER_B}'`), 0);
      assert.ok(await count(`owner = '${USER_A}'`) > 0);
    });

    await t.step('the migration can be applied again without error or data loss', async () => {
      const before = await stored();
      await apply(MIGRATION);
      assert.deepEqual(await stored(), before);
      assert.equal((await db.sql(`select count(*) from pg_policies where tablename='activity_ground_truth_labels'`)).trim(), '2');
      const result: any = await upsert(USER_A, [entry({ label_key: 'guided:a:3100000001' })]);
      assert.equal(result.saved[0].revision, 1);
    });

    await t.step('20261007090001: the corrected_label vocabulary is extended by a named constraint', async () => {
      await apply('20261004171000_activity_stretch_feedback.sql');
      await apply('20261007090001_activity_stretch_feedback_corrections.sql');
      const checks = await db.sql(`select conname from pg_constraint
        where conrelid='public.activity_stretch_feedback'::regclass and contype='c' order by conname`);
      assert.match(checks, /activity_stretch_feedback_corrected_label_check/);
      const insert = (index: number, label: string) => db.sql(`insert into public.activity_stretch_feedback(
          owner, client_id, stretch_key, kind, start_ts, end_ts, predicted_label, verdict, corrected_label, client_updated_at)
        values ('${USER_A}', '${CLIENT_ID}', 'activity_context:400000000${index}', 'activity_context', ${T0}, ${T0 + 60},
                'Walking', 'incorrect', '${label}', '2026-10-07T16:05:00Z')`);
      for (const [index, label] of [1, 2, 3, 4, 5].map((n, i) => [n, ['desk_work', 'brisk_walking', 'typing', 'fidgeting', 'stairs'][i]] as const)) {
        await insert(index, label);
      }
      await assert.rejects(() => insert(6, 'nonsense'), /violates check constraint/, 'nonsense must be refused');
      assert.equal(await countStretch(`stretch_key like 'activity_context:400000000%'`), 5);
      // Idempotent: re-applying drops the named constraint and re-creates it, keeping the rows.
      await apply('20261007090001_activity_stretch_feedback_corrections.sql');
      await assert.rejects(() => insert(6, 'nonsense'), /violates check constraint/);
      assert.equal(await countStretch(`stretch_key like 'activity_context:400000000%'`), 5);
      await db.sql(`delete from public.activity_stretch_feedback where stretch_key like 'activity_context:400000000%'`);
    });

    await t.step('20261008100500: confirmation answers are stored; the CHECKs refuse what the validator refuses', async () => {
      const confirmation = (key: string, over: Record<string, unknown> = {}) => {
        const result = validateGroundTruthLabelItem({
          id: CLIENT_ID, label_key: key, source: 'confirmation', start_ts: T0, end_ts: T0 + 60,
          posture: 'seated_likely', label_confidence: 1, client_updated_at: '2026-10-07T16:05:00Z', ...over,
        });
        assert.ok(result.ok, `${key} must validate: ${JSON.stringify((result as any).rejection)}`);
        return { ...result.item, device_id: null };
      };
      // Before the migration the old source CHECK refuses it.
      await assert.rejects(() => upsert(USER_A, [confirmation('confirmation:prompt:5000000000')]));
      await apply('20261008100500_activity_ground_truth_confirmation_source.sql');
      const result: any = await upsert(USER_A, [
        confirmation('confirmation:prompt:5000000001'),
        confirmation('confirmation:prompt:5000000002', { posture: 'upright_stationary' }),
        confirmation('confirmation:prompt:5000000003', { posture: 'unknown', end_ts: T0 + 120 }),
      ]);
      assert.equal(result.saved.length, 3);
      const bad = (over: Record<string, unknown>) =>
        upsert(USER_A, [{ ...confirmation('confirmation:prompt:5000000009'), ...over }]);
      for (const over of [{ end_ts: T0 + 121 }, { posture: null }, { posture: 'recumbent' },
        { transition_kind: 'sit_to_stand' }, { transition_ts: T0 + 30 }, { source: 'sleep' }]) {
        await assert.rejects(() => bad(over), /check constraint/, JSON.stringify(over));
      }
      assert.equal(await count(`source = 'confirmation'`), 3);
      // Other sources keep their rules: long, transition-bearing guided labels still store.
      const guided: any = await upsert(USER_A, [entry({ label_key: 'guided:a:5100000001' })]);
      assert.equal(guided.saved.length, 1);
      // Idempotent: re-applying keeps the rows and the rules.
      await apply('20261008100500_activity_ground_truth_confirmation_source.sql');
      assert.equal(await count(`source = 'confirmation'`), 3);
      await assert.rejects(() => bad({ end_ts: T0 + 121 }), /check constraint/);
      const checks = await db.sql(`select conname from pg_constraint
        where conrelid='public.activity_ground_truth_labels'::regclass and contype='c'
          and pg_get_constraintdef(oid) like '%source%' order by conname`);
      assert.equal(checks.trim().split('\n').join(','),
        'activity_ground_truth_labels_confirmation_shape,activity_ground_truth_labels_source_check');
    });
  } finally {
    await db.close();
  }
});
