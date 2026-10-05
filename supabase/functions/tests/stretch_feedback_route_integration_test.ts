import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

// The real POST /scores/stretch-feedback handler against a throwaway local PostgreSQL + PostgREST
// (EDGE_TEST_ARTIFACTS): installation-token auth from real token/installation rows, device resolution
// from the real devices table, the real upsert RPC, and RLS on the way back out. The handler is driven
// with the harness's service-role REST client, exactly as the deployed function drives Supabase.

const SOURCE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SOURCE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const LOCAL_A = 'whoop-A1B2C3D4';
const LOCAL_B = 'whoop-E5F6G7H8';
const DEVICE_A = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DEVICE_B = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const T0 = 1_760_072_000;
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };
const MIGRATION = '20261004171000_activity_stretch_feedback.sql';

function entry(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11',
    stretch_key: `activity_context:${T0}`,
    kind: 'activity_context',
    device_id: LOCAL_A,
    start_ts: T0,
    end_ts: T0 + 900,
    predicted_label: 'Walking',
    predicted_class: 'walking',
    predicted_confidence: 0.82,
    verdict: 'incorrect',
    corrected_label: 'running',
    note: null,
    model_context: { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu' },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-04T16:00:00Z',
    client_updated_at: '2026-10-04T16:05:00Z',
    ...over,
  };
}

Deno.test('stretch feedback route on a real database: auth, owner scoping, device resolution and last-writer-wins', {
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const db = await startLocalPostgres({ installationLifecycle: true, authProvisioning: true });
  try {
    const migration = await Deno.readTextFile(new URL(`../../migrations/${MIGRATION}`, import.meta.url));
    await db.sql(migration);
    // findNoopDevice also reads noop_wearable_aliases, which the real chain creates in a migration the
    // harness does not apply; an empty table of the same shape is all the look-up needs (see
    // placement_route_test.ts).
    await db.sql(`create table public.noop_wearable_aliases (
        user_id uuid not null, source_id uuid not null,
        provisional_device_id uuid not null, canonical_device_id uuid not null,
        evidence jsonb not null, confirmed_at timestamptz not null default clock_timestamp(),
        primary key(user_id,provisional_device_id));`);
    await db.sql(`select pg_notify('pgrst', 'reload schema');`);
    await new Promise((resolve) => setTimeout(resolve, 700));

    await db.sql(`insert into public.noop_app_installations(source_id,user_id,provisioning_method,platform,app_version)
        values ('${SOURCE_A}','${USER_A}','supabase_auth','ios','1.0.0'),
               ('${SOURCE_B}','${USER_B}','supabase_auth','ios','1.0.0');`);
    await db.sql(`insert into public.noop_ingest_tokens(id,user_id,source_id,token_hash,token_kind,provisioning_method)
        values ('ffffffff-ffff-4fff-8fff-ffffffffffff','${USER_A}','${SOURCE_A}','${hashIngestToken('noop_token_a')}','installation','supabase_auth'),
               ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','${USER_B}','${SOURCE_B}','${hashIngestToken('noop_token_b')}','installation','supabase_auth');`);
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id,is_active)
        values ('${DEVICE_A}','${USER_A}','noop_push','${LOCAL_A}',true),
               ('${DEVICE_B}','${USER_B}','noop_push','${LOCAL_B}',true);`);

    const send = (body: unknown, { bearer = 'noop_token_a', method = 'POST', raw, path = '/stretch-feedback' }: {
      bearer?: string | null; method?: string; raw?: string; path?: string;
    } = {}) => handleScoresRequest(new Request(`https://test.invalid/functions/v1/scores${path}`, {
      method,
      headers: { ...(bearer ? { authorization: `Bearer ${bearer}` } : {}), 'content-type': 'application/json' },
      body: method === 'GET' ? undefined : (raw ?? JSON.stringify(body)),
    }), { rest: db.rest as any, cfg, fetchImpl: async () => Response.json({ error: 'unused' }, { status: 401 }) });
    const rows = async (owner: string) => JSON.parse(await db.sql(
      `select coalesce(json_agg(f order by f.stretch_key), '[]'::json) from public.activity_stretch_feedback f where owner='${owner}'`));

    // 1. First write: saved at revision 1, device resolved for an owned device, null for another account's.
    let response = await send({
      feedback: [
        entry(),
        entry({ stretch_key: `activity_context:${T0 + 1000}`, device_id: LOCAL_B, verdict: 'correct', corrected_label: null }),
        entry({ stretch_key: `activity_context:${T0 + 2000}`, device_id: null }),
        entry({ stretch_key: `activity_context:${T0 + 3000}`, verdict: 'sort of' }),
      ],
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), {
      saved: [
        { stretch_key: `activity_context:${T0}`, revision: 1 },
        { stretch_key: `activity_context:${T0 + 1000}`, revision: 1 },
        { stretch_key: `activity_context:${T0 + 2000}`, revision: 1 },
      ],
      ignored: [],
      rejected: [{ stretch_key: `activity_context:${T0 + 3000}`, reason: 'invalid_verdict' }],
    });
    let stored = await rows(USER_A);
    assert.equal(stored.length, 3);
    const byKey = (key: string) => stored.find((row: any) => row.stretch_key === key);
    assert.equal(byKey(`activity_context:${T0}`).device_id, DEVICE_A);
    assert.equal(byKey(`activity_context:${T0}`).external_device_id, LOCAL_A);
    assert.equal(byKey(`activity_context:${T0 + 1000}`).device_id, null, "another account's strap is never attached");
    assert.equal(byKey(`activity_context:${T0 + 1000}`).external_device_id, LOCAL_B);
    assert.equal(byKey(`activity_context:${T0 + 2000}`).external_device_id, null);
    assert.equal(byKey(`activity_context:${T0}`).owner, USER_A);
    assert.deepEqual(byKey(`activity_context:${T0}`).model_context, { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu' });

    // 2. Re-validating overwrites and bumps the revision; an older write is ignored; the client treats both as done.
    response = await send({ feedback: [entry({ verdict: 'correct', corrected_label: null, client_updated_at: '2026-10-04T16:10:00Z' })] });
    assert.deepEqual(await response.json(), {
      saved: [{ stretch_key: `activity_context:${T0}`, revision: 2 }], ignored: [], rejected: [] });
    response = await send({ feedback: [entry({ corrected_label: 'cycling', client_updated_at: '2026-10-04T16:09:59Z' })] });
    assert.deepEqual(await response.json(), {
      saved: [], ignored: [{ stretch_key: `activity_context:${T0}`, reason: 'stale' }], rejected: [] });
    stored = await rows(USER_A);
    assert.equal(byKey(`activity_context:${T0}`).verdict, 'correct');
    assert.equal(byKey(`activity_context:${T0}`).corrected_label, null);
    assert.equal(byKey(`activity_context:${T0}`).revision, 2);

    // 3. The owner is the credential's, whatever the body says; the same stretch_key is a separate row per account.
    response = await send({
      owner: USER_A, user_id: USER_A, p_owner: USER_A,
      feedback: [entry({ device_id: LOCAL_B, verdict: 'incorrect', corrected_label: 'sitting', client_updated_at: '2026-10-04T12:00:00Z' })],
    }, { bearer: 'noop_token_b' });
    assert.deepEqual(await response.json(), {
      saved: [{ stretch_key: `activity_context:${T0}`, revision: 1 }], ignored: [], rejected: [] });
    const asB = await rows(USER_B);
    assert.equal(asB.length, 1);
    assert.equal(asB[0].device_id, DEVICE_B);
    assert.equal(asB[0].corrected_label, 'sitting');
    assert.equal((await rows(USER_A)).length, 3, "B's write touched none of A's rows");
    assert.equal((await rows(USER_A)).find((row: any) => row.stretch_key === `activity_context:${T0}`).revision, 2);

    // 4. What a client reads back through RLS is only its own rows.
    const readA = await db.request('activity_stretch_feedback?select=stretch_key,owner', 'authenticated', USER_A);
    assert.equal(readA.status, 200);
    assert.equal(readA.body.length, 3);
    assert.ok(readA.body.every((row: any) => row.owner === USER_A));

    // 5. Failures write nothing and keep the shared error shape.
    const before = Number((await db.sql('select count(*) from public.activity_stretch_feedback')).trim());
    for (const [attempt, status, error] of [
      [await send({ feedback: [entry()] }, { bearer: null }), 401, 'unauthorized'],
      [await send({ feedback: [entry()] }, { bearer: 'noop_unknown' }), 401, undefined],
      [await send(undefined, { raw: 'not json' }), 400, 'invalid_body'],
      [await send({ feedback: [] }), 400, 'invalid_feedback'],
      [await send({ feedback: Array.from({ length: 26 }, (_, n) => entry({ stretch_key: `k:${n}` })) }), 400, 'invalid_feedback'],
      [await send({ feedback: [entry({ note: 'x'.repeat(128 * 1024) })] }), 413, 'payload_too_large'],
      [await send({ feedback: [entry()] }, { method: 'GET' }), 405, 'method_not_allowed'],
      [await send({ feedback: [entry()] }, { method: 'DELETE' }), 405, 'method_not_allowed'],
    ] as Array<[Response, number, string | undefined]>) {
      assert.equal(attempt.status, status);
      if (error) assert.equal((await attempt.json()).error, error);
    }
    assert.equal(Number((await db.sql('select count(*) from public.activity_stretch_feedback')).trim()), before);

    // 6. A batch of large contexts is accepted well past the 8 KiB limit of the other POST routes.
    const large = Array.from({ length: 6 }, (_, n) => entry({
      stretch_key: `activity_context:${T0 + 10_000 + n}`,
      model_context: { blob: 'x'.repeat(16_000) },
    }));
    response = await send({ feedback: large });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).saved.length, 6);
  } finally {
    await db.close();
  }
});
