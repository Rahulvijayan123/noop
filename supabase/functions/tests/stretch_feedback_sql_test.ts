import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import {
  STRETCH_FEEDBACK_MAX_CONTEXT_BYTES,
  validateStretchFeedbackItem,
} from '../_shared/stretchFeedback.ts';

// Proves 20261004171000_activity_stretch_feedback.sql against a throwaway local PostgreSQL + PostgREST
// (EDGE_TEST_ARTIFACTS), never a shared database:
//  1. the table, its constraints, indexes and comment exist, and the migration can be applied twice;
//  2. privilege hardening holds even when the schema's default privileges hand every new table to
//     anon/authenticated, the way Supabase's do;
//  3. RLS: an owner reads only their own rows, anon reads nothing, and no client role can insert,
//     update, delete or call the RPC;
//  4. upsert_activity_stretch_feedback: first write = revision 1, a newer or equal client_updated_at
//     overwrites and bumps the revision, an older one is ignored as stale and changes nothing, batches
//     keep their order, device ownership is enforced, bad input raises and rolls the whole call back;
//  5. everything the TypeScript validator accepts is storable (the CHECK constraints never reject it).

const OWN_DEVICE = '33333333-3333-4333-8333-333333333333';
const OTHER_DEVICE = '44444444-4444-4444-8444-444444444444';
const MISSING_DEVICE = '55555555-5555-4555-8555-555555555555';
const CLIENT_ID = '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11';
const T0 = 1_760_072_000;
const MIGRATION = '20261004171000_activity_stretch_feedback.sql';

function entry(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    client_id: CLIENT_ID,
    stretch_key: `activity_context:${T0}`,
    kind: 'activity_context',
    device_id: OWN_DEVICE,
    external_device_id: 'whoop-ABC123456',
    start_ts: T0,
    end_ts: T0 + 900,
    predicted_label: 'Walking',
    predicted_class: 'walking',
    predicted_confidence: 0.82,
    verdict: 'incorrect',
    corrected_label: 'running',
    note: 'it was a jog',
    model_context: { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu' },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-04T16:00:00.000Z',
    client_updated_at: '2026-10-04T16:05:00.000Z',
    ...over,
  };
}

Deno.test('stretch feedback: schema, privileges, RLS and the last-writer-wins upsert', async (t) => {
  const db = await startLocalPostgres();
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
  const stored = (owner = USER_A) => json(
    `select coalesce(json_agg(f order by f.stretch_key), '[]'::json) from public.activity_stretch_feedback f where owner = '${owner}'`);
  const count = async (where = 'true') =>
    Number((await db.sql(`select count(*) from public.activity_stretch_feedback where ${where}`)).trim());
  const upsert = (owner: string, items: unknown[]) =>
    db.rest.rpc('upsert_activity_stretch_feedback', { p_owner: owner, p_items: items });
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  try {
    // Supabase hands every new table and function to anon/authenticated through default privileges. Model
    // that here so the migration's own revokes are what is being proven, not the harness's absence of grants.
    await db.sql(`alter default privileges in schema public grant all on tables to anon, authenticated;
      alter default privileges in schema public grant execute on functions to anon, authenticated;`);
    await apply();
    await db.sql("notify pgrst, 'reload schema';");
    await sleep(700);
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id)
      values ('${OWN_DEVICE}','${USER_A}','noop_push','whoop-ABC123456'),
             ('${OTHER_DEVICE}','${USER_B}','noop_push','whoop-ZZZ999999');`);

    await t.step('schema: columns, constraints, indexes and purpose comment', async () => {
      const columns = await db.sql(`select column_name || ':' || data_type || ':' || is_nullable
        from information_schema.columns where table_schema='public' and table_name='activity_stretch_feedback'
        order by ordinal_position`);
      for (const expected of ['id:uuid:NO', 'owner:uuid:NO', 'client_id:uuid:NO', 'stretch_key:text:NO', 'kind:text:NO',
        'device_id:uuid:YES', 'external_device_id:text:YES', 'start_ts:bigint:NO', 'end_ts:bigint:NO',
        'predicted_label:text:NO', 'predicted_class:text:YES', 'predicted_confidence:real:YES', 'verdict:text:NO',
        'corrected_label:text:YES', 'note:text:YES', 'model_context:jsonb:NO', 'app_version:text:YES',
        'app_build:text:YES', 'tz_offset_s:integer:YES', 'client_created_at:timestamp with time zone:YES',
        'client_updated_at:timestamp with time zone:NO', 'revision:integer:NO', 'created_at:timestamp with time zone:NO',
        'updated_at:timestamp with time zone:NO']) {
        assert(columns.includes(expected), `missing column ${expected}`);
      }
      const indexes = await db.sql(`select indexdef from pg_indexes where schemaname='public' and tablename='activity_stretch_feedback'`);
      assert.match(indexes, /UNIQUE.*\(owner, stretch_key\)/);
      assert.match(indexes, /\(owner, start_ts\)/);
      assert.match(indexes, /\(kind, verdict, predicted_class\)/);
      const comment = await db.sql(`select obj_description('public.activity_stretch_feedback'::regclass,'pg_class')`);
      assert.match(comment, /model-tuning/i);
      assert.match(await db.sql(`select relrowsecurity from pg_class where oid='public.activity_stretch_feedback'::regclass`), /^t$/);
      const owner = await db.sql(`select confdeltype from pg_constraint
        where conrelid='public.activity_stretch_feedback'::regclass and contype='f' and confrelid='auth.users'::regclass`);
      assert.equal(owner.trim(), 'c', 'deleting the account deletes its feedback');
      const device = await db.sql(`select confdeltype from pg_constraint
        where conrelid='public.activity_stretch_feedback'::regclass and contype='f' and confrelid='public.devices'::regclass`);
      assert.equal(device.trim(), 'n', 'deleting a device keeps the label and clears the device');
    });

    await t.step('privileges: clients may only select; only the service role writes or executes the RPC', async () => {
      const has = async (role: string, privileges: string) => (await db.sql(
        `select has_table_privilege('${role}','public.activity_stretch_feedback','${privileges}')`)).trim() === 't';
      assert.equal(await has('anon', 'select'), false);
      for (const privilege of ['insert', 'update', 'delete', 'truncate', 'references', 'trigger']) {
        assert.equal(await has('anon', privilege), false, `anon ${privilege}`);
        assert.equal(await has('authenticated', privilege), false, `authenticated ${privilege}`);
      }
      assert.equal(await has('authenticated', 'select'), true);
      for (const privilege of ['select', 'insert', 'update', 'delete']) {
        assert.equal(await has('service_role', privilege), true, `service_role ${privilege}`);
      }
      const fn = `'public.upsert_activity_stretch_feedback(uuid,jsonb)'::regprocedure`;
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
        from pg_policies where schemaname='public' and tablename='activity_stretch_feedback' order by policyname`);
      assert.equal(policies, [
        'activity_stretch_feedback_select_own:SELECT:authenticated',
        'activity_stretch_feedback_service:ALL:service_role',
      ].join('\n'));
    });

    await t.step('RPC: first write is revision 1 and is readable', async () => {
      const result: any = await upsert(USER_A, [entry()]);
      assert.deepEqual(result, { saved: [{ stretch_key: `activity_context:${T0}`, revision: 1 }], ignored: [] });
      const [row] = await stored();
      assert.equal(row.owner, USER_A);
      assert.equal(row.client_id, CLIENT_ID);
      assert.equal(row.device_id, OWN_DEVICE);
      assert.equal(row.external_device_id, 'whoop-ABC123456');
      assert.equal(row.verdict, 'incorrect');
      assert.equal(row.corrected_label, 'running');
      assert.equal(row.predicted_confidence, 0.82);
      assert.deepEqual(row.model_context, { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu' });
      assert.equal(row.revision, 1);
      assert.equal(row.start_ts, T0);
      assert.equal(row.tz_offset_s, -25200);
      assert.equal(new Date(row.client_updated_at).toISOString(), '2026-10-04T16:05:00.000Z');
    });

    await t.step('RLS: an owner reads only their own rows; anon reads nothing', async () => {
      await upsert(USER_B, [entry({ stretch_key: `activity_context:${T0 + 3600}`, device_id: OTHER_DEVICE, note: 'b-only' })]);
      const own = await db.request('activity_stretch_feedback?select=stretch_key,note', 'authenticated', USER_A);
      assert.equal(own.status, 200);
      assert.deepEqual(own.body.map((row: any) => row.stretch_key), [`activity_context:${T0}`]);
      const asB = await db.request('activity_stretch_feedback?select=stretch_key,note', 'authenticated', USER_B);
      assert.deepEqual(asB.body.map((row: any) => row.note), ['b-only']);
      const probe = await db.request(`activity_stretch_feedback?owner=eq.${USER_B}`, 'authenticated', USER_A);
      assert.equal(probe.status, 200);
      assert.deepEqual(probe.body, [], 'A must not see B rows even when asking for them');
      const anon = await db.request('activity_stretch_feedback', 'anon', USER_A);
      assert.ok([401, 403].includes(anon.status), `anon must be refused, got ${anon.status}`);
    });

    await t.step('no client role can insert, update, delete or call the RPC', async () => {
      const before = await stored();
      const insert = await db.request('activity_stretch_feedback', 'authenticated', USER_A, 'POST', {
        owner: USER_A, client_id: CLIENT_ID, stretch_key: 'activity_context:1999999999', kind: 'activity_context',
        start_ts: T0, end_ts: T0 + 60, predicted_label: 'x', verdict: 'correct', client_updated_at: '2026-10-04T16:05:00Z',
      });
      assert.ok([401, 403].includes(insert.status), `insert refused, got ${insert.status}`);
      const update = await db.request(`activity_stretch_feedback?owner=eq.${USER_A}`, 'authenticated', USER_A, 'PATCH',
        { verdict: 'correct', corrected_label: null });
      assert.ok([401, 403].includes(update.status), `update refused, got ${update.status}`);
      const remove = await db.request(`activity_stretch_feedback?owner=eq.${USER_A}`, 'authenticated', USER_A, 'DELETE');
      assert.ok([401, 403].includes(remove.status), `delete refused, got ${remove.status}`);
      for (const role of ['authenticated', 'anon']) {
        const rpc = await db.request('rpc/upsert_activity_stretch_feedback', role, USER_A, 'POST',
          { p_owner: USER_A, p_items: [entry({ stretch_key: 'activity_context:1888888888' })] });
        assert.ok([401, 403].includes(rpc.status), `${role} rpc refused, got ${rpc.status}`);
      }
      assert.deepEqual(await stored(), before, 'nothing changed');
      assert.equal(await count(), 2);
    });

    await t.step('RPC: a newer client_updated_at overwrites everything and bumps the revision', async () => {
      const [before] = await stored();
      await sleep(5);
      const result: any = await upsert(USER_A, [entry({
        client_id: '6a1e4c5d-2b3f-4d6e-8f70-1a2b3c4d5e6f', verdict: 'correct', corrected_label: null, note: null,
        predicted_label: 'Running', predicted_class: 'running', predicted_confidence: 0.4, kind: 'activity_context',
        model_context: { replaced: true }, app_version: '11.8.1', app_build: '432', tz_offset_s: 3600,
        start_ts: T0 + 1, end_ts: T0 + 1000, client_created_at: null,
        client_updated_at: '2026-10-04T16:06:00.000Z',
      })]);
      assert.deepEqual(result, { saved: [{ stretch_key: `activity_context:${T0}`, revision: 2 }], ignored: [] });
      const rows = await stored();
      assert.equal(rows.length, 1, 'same (owner, stretch_key) stays one row');
      const [after] = rows;
      assert.equal(after.id, before.id);
      assert.equal(after.created_at, before.created_at);
      assert.ok(new Date(after.updated_at) > new Date(before.updated_at));
      assert.equal(after.client_id, '6a1e4c5d-2b3f-4d6e-8f70-1a2b3c4d5e6f');
      assert.equal(after.verdict, 'correct');
      assert.equal(after.corrected_label, null);
      assert.equal(after.note, null);
      assert.equal(after.predicted_label, 'Running');
      assert.equal(after.predicted_class, 'running');
      assert.equal(after.predicted_confidence, 0.4);
      assert.deepEqual(after.model_context, { replaced: true });
      assert.equal(after.app_version, '11.8.1');
      assert.equal(after.tz_offset_s, 3600);
      assert.equal(after.start_ts, T0 + 1);
      assert.equal(after.revision, 2);
      assert.equal(new Date(after.client_updated_at).toISOString(), '2026-10-04T16:06:00.000Z');
      assert.equal(new Date(after.client_created_at).toISOString(), '2026-10-04T16:00:00.000Z',
        'a missing client_created_at does not erase the original');
    });

    await t.step('RPC: an older client_updated_at is ignored as stale and changes nothing', async () => {
      const before = await stored();
      const result: any = await upsert(USER_A, [entry({
        verdict: 'incorrect', corrected_label: 'cycling', note: 'stale write',
        client_updated_at: '2026-10-04T16:05:59.999Z',
      })]);
      assert.deepEqual(result, { saved: [], ignored: [{ stretch_key: `activity_context:${T0}`, reason: 'stale' }] });
      assert.deepEqual(await stored(), before);
    });

    await t.step('RPC: an equal client_updated_at is not older, so it overwrites and bumps the revision', async () => {
      const result: any = await upsert(USER_A, [entry({ note: 'same instant', verdict: 'incorrect', corrected_label: 'walking',
        client_updated_at: '2026-10-04T16:06:00.000Z' })]);
      assert.deepEqual(result.saved, [{ stretch_key: `activity_context:${T0}`, revision: 3 }]);
      const [row] = await stored();
      assert.equal(row.note, 'same instant');
      assert.equal(row.revision, 3);
    });

    await t.step('RPC: a batch is applied in order with a per-item outcome', async () => {
      const key = (n: number) => `activity_context:${T0 + n * 1000}`;
      const result: any = await upsert(USER_A, [
        entry({ stretch_key: key(1), client_updated_at: '2026-10-04T17:00:00.000Z' }),
        entry({ stretch_key: `activity_context:${T0}`, client_updated_at: '2026-10-04T10:00:00.000Z' }),
        entry({ stretch_key: key(2), client_updated_at: '2026-10-04T17:00:00.000Z' }),
        entry({ stretch_key: key(1), note: 'again', client_updated_at: '2026-10-04T17:00:01.000Z' }),
        entry({ stretch_key: key(2), note: 'older duplicate', client_updated_at: '2026-10-04T16:59:00.000Z' }),
      ]);
      assert.deepEqual(result, {
        saved: [{ stretch_key: key(1), revision: 1 }, { stretch_key: key(2), revision: 1 }, { stretch_key: key(1), revision: 2 }],
        ignored: [{ stretch_key: `activity_context:${T0}`, reason: 'stale' }, { stretch_key: key(2), reason: 'stale' }],
      });
      const rows = await stored();
      assert.equal(rows.find((row: any) => row.stretch_key === key(1)).note, 'again');
      assert.equal(rows.find((row: any) => row.stretch_key === key(2)).note, 'it was a jog');
    });

    await t.step('RPC: a device the owner does not have is stored as no device, and the item is kept', async () => {
      const result: any = await upsert(USER_A, [
        entry({ stretch_key: 'strap_state:100000001', kind: 'strap_state', device_id: OTHER_DEVICE, external_device_id: 'whoop-ZZZ999999' }),
        entry({ stretch_key: 'strap_state:100000002', kind: 'strap_state', device_id: MISSING_DEVICE }),
        entry({ stretch_key: 'strap_state:100000003', kind: 'strap_state', device_id: null, external_device_id: null }),
        entry({ stretch_key: 'strap_state:100000004', kind: 'strap_state', device_id: OWN_DEVICE }),
      ]);
      assert.equal(result.saved.length, 4);
      const rows = await stored();
      const byKey = (key: string) => rows.find((row: any) => row.stretch_key === key);
      assert.equal(byKey('strap_state:100000001').device_id, null);
      assert.equal(byKey('strap_state:100000001').external_device_id, 'whoop-ZZZ999999');
      assert.equal(byKey('strap_state:100000002').device_id, null);
      assert.equal(byKey('strap_state:100000003').device_id, null);
      assert.equal(byKey('strap_state:100000004').device_id, OWN_DEVICE);
      // Another account's identical stretch_key is a different row.
      await upsert(USER_B, [entry({ stretch_key: 'strap_state:100000004', device_id: OTHER_DEVICE })]);
      assert.equal(await count(`stretch_key = 'strap_state:100000004'`), 2);
      assert.equal(byKey('strap_state:100000004').owner, USER_A);
    });

    await t.step('RPC: bad input raises and rolls the whole call back', async () => {
      const before = await stored();
      const bad = (message: RegExp, owner: unknown, items: unknown) =>
        assert.rejects(() => db.rest.rpc('upsert_activity_stretch_feedback', { p_owner: owner, p_items: items }), message);
      await bad(/invalid_items/, USER_A, []);
      await bad(/invalid_items/, USER_A, Array.from({ length: 26 }, (_, n) => entry({ stretch_key: `activity_context:${2e9 + n}` })));
      await bad(/invalid_items/, USER_A, { stretch_key: 'x' });
      await bad(/invalid_items/, USER_A, null);
      await bad(/invalid_owner|null value|violates|failed/, null, [entry()]);
      await bad(/violates check constraint|failed \(400\)/, USER_A, [
        entry({ stretch_key: 'activity_context:2100000001' }), entry({ stretch_key: 'activity_context:2100000002', verdict: 'maybe' })]);
      await bad(/failed/, '66666666-6666-4666-8666-666666666666', [entry({ stretch_key: 'activity_context:2100000003' })]);
      assert.deepEqual(await stored(), before, 'a failed call leaves no partial batch behind');
      assert.equal(await count(`stretch_key like 'activity_context:21%'`), 0);
    });

    await t.step('RPC: a caller that is signed in as someone else is refused', async () => {
      const item = JSON.stringify([entry({ stretch_key: 'activity_context:2200000001' })]).replaceAll("'", "''");
      await assert.rejects(() => db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub','${USER_B}',true);
        select public.upsert_activity_stretch_feedback('${USER_A}'::uuid,'${item}'::jsonb); rollback;`), /cross_user_caller/);
      assert.equal(await count(`stretch_key = 'activity_context:2200000001'`), 0);
      const own = await db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub','${USER_A}',true);
        select public.upsert_activity_stretch_feedback('${USER_A}'::uuid,'${item}'::jsonb)::jsonb->'saved'; rollback;`);
      assert.match(own, /"revision": 1/);
    });

    await t.step('CHECK constraints are a backstop for anything that bypasses the edge validation', async () => {
      const insert = (over: Record<string, string>) => {
        const values: Record<string, string> = {
          owner: `'${USER_A}'`, client_id: `'${CLIENT_ID}'`, stretch_key: `'activity_context:2300000001'`,
          kind: `'activity_context'`, start_ts: `${T0}`, end_ts: `${T0 + 60}`, predicted_label: `'Walking'`,
          verdict: `'incorrect'`, corrected_label: 'null', model_context: `'{}'::jsonb`,
          client_updated_at: `'2026-10-04T16:05:00Z'`, ...over,
        };
        return db.sql(`insert into public.activity_stretch_feedback(${Object.keys(values).join(',')})
          values (${Object.values(values).join(',')})`);
      };
      await insert({});
      await db.sql(`delete from public.activity_stretch_feedback where stretch_key = 'activity_context:2300000001'`);
      const rejections: Record<string, Record<string, string>> = {
        'bad stretch_key': { stretch_key: `'has space'` },
        'empty stretch_key': { stretch_key: `''` },
        'long stretch_key': { stretch_key: `'${'k'.repeat(97)}'` },
        'kind': { kind: `'sleep'` },
        'start before 2000': { start_ts: '946684800', end_ts: '946684900' },
        'end not after start': { end_ts: `${T0}` },
        'span over a day': { end_ts: `${T0 + 86401}` },
        'empty label': { predicted_label: `''` },
        'long label': { predicted_label: `'${'x'.repeat(65)}'` },
        'confidence over 1': { predicted_confidence: '1.5' },
        'confidence under 0': { predicted_confidence: '-0.1' },
        'verdict': { verdict: `'maybe'` },
        'corrected label not in list': { corrected_label: `'swimming'` },
        'corrected label on a correct verdict': { verdict: `'correct'`, corrected_label: `'running'` },
        'long note': { note: `'${'n'.repeat(281)}'` },
        'model_context array': { model_context: `'[]'::jsonb` },
        'model_context scalar': { model_context: `'1'::jsonb` },
        'model_context too large': { model_context: `jsonb_build_object('blob', repeat('x', 33000))` },
        'long app_version': { app_version: `'${'v'.repeat(33)}'` },
        'tz offset': { tz_offset_s: '64801' },
        'revision': { revision: '0' },
        'external device id': { external_device_id: `''` },
      };
      for (const [name, over] of Object.entries(rejections)) {
        await assert.rejects(() => insert(over), /violates check constraint/, name);
      }
      assert.equal(await count(`stretch_key like 'activity_context:23%'`), 0);
    });

    await t.step('everything the validator accepts can be stored', async () => {
      // The largest growth a JSON text can see when jsonb renders it: single digits, one comma between
      // each, which become ", " in jsonb's text form.
      const worstCaseNumbers = { a: Array.from({ length: 8188 }, () => 1) };
      assert.equal(new TextEncoder().encode(JSON.stringify(worstCaseNumbers)).length, STRETCH_FEEDBACK_MAX_CONTEXT_BYTES - 1);
      const nested = (() => {
        let value: unknown = { leaf: 'é' };
        for (let level = 1; level < 32; level++) value = { n: value };
        return value as Record<string, unknown>;
      })();
      const inputs = [
        { stretch_key: 'activity_context:3000000001', note: '😀'.repeat(280), predicted_label: 'é'.repeat(64) },
        { stretch_key: 'activity_context:3000000002', model_context: worstCaseNumbers },
        { stretch_key: 'activity_context:3000000003', model_context: nested },
        { stretch_key: 'activity_context:3000000004', model_context: { blob: 'é'.repeat(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES / 2 - 8) } },
        { stretch_key: 'activity_context:3000000005', model_context: { tiny: 5e-324, big: 1.7976931348623157e308, neg: -0, n: [1e21, 1e-7] } },
        { stretch_key: 'activity_context:3000000006', client_updated_at: '2026-10-04T09:05:00.123456-07:00', client_created_at: '2028-02-29T23:59:59Z' },
        { stretch_key: 'strap_state:3000000007', kind: 'strap_state', verdict: 'correct', corrected_label: null,
          predicted_class: undefined, predicted_confidence: undefined, note: undefined, model_context: undefined,
          app_version: undefined, app_build: undefined, tz_offset_s: undefined, client_created_at: undefined, device_id: undefined },
        { stretch_key: 'activity_context:3000000008', start_ts: 946684801, end_ts: 946684802, tz_offset_s: -64800, predicted_confidence: 1 },
        { stretch_key: 'k'.repeat(96), start_ts: T0, end_ts: T0 + 86400, tz_offset_s: 64800, predicted_confidence: 0 },
      ];
      const items = inputs.map((over) => {
        const result = validateStretchFeedbackItem({
          id: CLIENT_ID, kind: 'activity_context', start_ts: T0, end_ts: T0 + 60, predicted_label: 'Walking',
          verdict: 'incorrect', corrected_label: 'other', client_updated_at: '2026-10-04T16:05:00Z',
          ...over,
        });
        assert.ok(result.ok, `${over.stretch_key} must validate: ${JSON.stringify((result as any).rejection)}`);
        return { ...result.item, device_id: null };
      });
      const result: any = await upsert(USER_A, items);
      assert.equal(result.saved.length, inputs.length);
      assert.deepEqual(result.ignored, []);
      const rows = await stored();
      const row = (key: string) => rows.find((candidate: any) => candidate.stretch_key === key);
      assert.equal(row('activity_context:3000000001').note, '😀'.repeat(280));
      assert.deepEqual(row('activity_context:3000000003').model_context, nested);
      assert.equal(new Date(row('activity_context:3000000006').client_updated_at).toISOString(), '2026-10-04T16:05:00.123Z');
      assert.equal(new Date(row('activity_context:3000000006').client_created_at).toISOString(), '2028-02-29T23:59:59.000Z');
      assert.equal(row('strap_state:3000000007').model_context && Object.keys(row('strap_state:3000000007').model_context).length, 0);
      assert.equal(row('k'.repeat(96)).end_ts - row('k'.repeat(96)).start_ts, 86400);
      const sizes = await json(`select json_agg(octet_length(model_context::text) order by stretch_key)
        from public.activity_stretch_feedback where stretch_key = 'activity_context:3000000002'`);
      assert.ok(sizes[0] > STRETCH_FEEDBACK_MAX_CONTEXT_BYTES && sizes[0] <= 32768,
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
      await apply();
      assert.deepEqual(await stored(), before);
      assert.equal((await db.sql(`select count(*) from pg_policies where tablename='activity_stretch_feedback'`)).trim(), '2');
      const result: any = await upsert(USER_A, [entry({ stretch_key: 'activity_context:3100000001' })]);
      assert.equal(result.saved[0].revision, 1);
    });
  } finally {
    await db.close();
  }
});
