import assertNode from 'node:assert/strict';
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

// G4 placement edge route (spec §6 / g34 findings item 1): the app's PlacementCloudSync
// POSTs/GETs /scores/placement with the SAME installation credential as every other score
// read. The edge resolves the OWNER from that identity and calls set_placement_interval —
// a client-supplied owner is never accepted. This test drives the real route against a
// throwaway PostgreSQL on a Unix socket: owner allow, first-declaration + correction flows,
// invalid input deny, and cross-owner deny.

const USER = USER_A;
const OTHER = USER_B;
const SOURCE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SOURCE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const LOCAL = 'whoop-A1B2C3D4';
const LOCAL_B = 'whoop-E5F6G7H8';
const DEVICE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DEVICE_B = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const CODE = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const TOKEN = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const FLEET = '11111111-2222-4333-8444-555555555555';
// The fixtures are enrollment-code installations (pre-Auth), which the route accepts only with legacy enrollment on.
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public', allowLegacyEnrollment: true };

const EXTRA_MIGRATIONS = [
  '20261003210000_placement_intervals.sql',
];

function placementRequest(path: string, body?: unknown, bearer = 'noop_personal', fleet = 'noop_fleet') {
  return new Request(`https://test.invalid/functions/v1/scores${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${bearer}`, 'x-noop-fleet-token': fleet, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

Deno.test('placement route: owner allow, corrections, invalid deny, cross-owner deny', {
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  // authProvisioning: the credential lookup reads noop_ingest_tokens.provisioning_method (20261004120000).
  const db = await startLocalPostgres({ installationLifecycle: true, authProvisioning: true });
  try {
    const sql = db.sql;
    for (const name of EXTRA_MIGRATIONS) {
      const text = await Deno.readTextFile(new URL(`../../migrations/${name}`, import.meta.url));
      await sql(text);
    }
    // findNoopDevice's alias look-up touches noop_wearable_aliases; the real table is created
    // by 20260921111000_wearable_lifecycle which drags in the whole append-projection chain.
    // This route test only needs the shape the lookup reads (no aliases are seeded), so a
    // minimal identical-column stub is created instead — no alias behavior is asserted here.
    await sql(`create table public.noop_wearable_aliases (
        user_id uuid not null, source_id uuid not null,
        provisional_device_id uuid not null, canonical_device_id uuid not null,
        evidence jsonb not null, confirmed_at timestamptz not null default clock_timestamp(),
        primary key(user_id,provisional_device_id));`);
    await sql(`select pg_notify('pgrst', 'reload schema');`);
    await new Promise((resolve) => setTimeout(resolve, 300));

    // Enrollment + devices for both owners. FK order: codes -> installations -> tokens -> devices.
    await sql(`insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values ('${CODE}','${USER}','${'a'.repeat(64)}', now() + interval '1 day'),
               ('99999999-9999-4999-8999-999999999999','${OTHER}','${'b'.repeat(64)}', now() + interval '1 day');`);
    await sql(`insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values ('${SOURCE}','${USER}','${CODE}','ios','1.0.0'),
               ('${SOURCE_B}','${OTHER}','99999999-9999-4999-8999-999999999999','ios','1.0.0');`);
    await sql(`insert into public.noop_ingest_tokens(id,user_id,source_id,token_hash,token_kind,enrollment_code_id)
        values ('${TOKEN}','${USER}','${SOURCE}','${hashIngestToken('noop_personal')}','installation','${CODE}'),
               ('${FLEET}','${USER}',null,'${hashIngestToken('noop_fleet')}','fleet',null),
               ('22222222-3333-4444-8555-666666666666','${OTHER}','${SOURCE_B}',
                 '${hashIngestToken('noop_other')}','installation','99999999-9999-4999-8999-999999999999');`);
    await sql(`insert into public.devices(id,user_id,source_kind,external_device_id,is_active)
        values ('${DEVICE}','${USER}','noop_push','${LOCAL}',true),
               ('${DEVICE_B}','${OTHER}','noop_push','${LOCAL_B}',true);`);

    async function post(body: unknown) {
      return handleScoresRequest(placementRequest('/placement', body), { rest: db.rest as any, cfg,
        fetchImpl: async () => Response.json({ error: 'unused' }, { status: 401 }) });
    }
    async function get() {
      return handleScoresRequest(placementRequest('/placement'), { rest: db.rest as any, cfg,
        fetchImpl: async () => Response.json({ error: 'unused' }, { status: 401 }) });
    }

    // 1. First declaration (user-level): accepted, revision 1, open-ended.
    let res = await post({ placement: 'wrist', effective_start: '2026-10-01T00:00:00Z' });
    assertEquals(res.status, 200, 'placement POST must be accepted');
    let body: any = await res.json();
    assertEquals(body.interval.owner, USER);
    assertEquals(body.interval.placement, 'wrist');
    assertEquals(body.interval.revision, 1);
    assertEquals(body.interval.device_id, null);
    assertEquals(body.interval.effective_end, null);

    // 2. Correction: closes the overlapping interval, new open interval, revision bumped.
    res = await post({ placement: 'bicep', effective_start: '2026-10-03T00:00:00Z' });
    assertEquals(res.status, 200, 'placement POST must be accepted');
    body = await res.json();
    assertEquals(body.interval.placement, 'bicep');
    assertEquals(body.interval.revision, 2);
    const rows = (await db.sql(`select placement,(effective_start at time zone 'UTC')::text,
        (effective_end at time zone 'UTC')::text,revision,source
        from public.placement_intervals where owner='${USER}' order by effective_start`)).split('\n').filter(Boolean);
    assertEquals(rows.length, 2);
    assert(rows[0].startsWith('wrist|2026-10-01 00:00:00|2026-10-03 00:00:00|'), 'first interval closed at correction: ' + rows[0]);
    assert(rows[1].startsWith('bicep|2026-10-03 00:00:00||'), 'second interval open bicep: ' + rows[1]);

    // 3. Device-scoped declaration resolves the external id to the owned internal device.
    res = await post({ placement: 'wrist', effective_start: '2026-10-05T00:00:00Z', device_id: LOCAL });
    assertEquals(res.status, 200, 'placement POST must be accepted');
    body = await res.json();
    assertEquals(body.interval.device_id, DEVICE);

    // 4. Invalid placement / missing effective_start → 400 with safe codes.
    res = await post({ placement: 'neck', effective_start: '2026-10-01T00:00:00Z' });
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, 'invalid_placement');
    res = await post({ placement: 'wrist' });
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, 'invalid_effective_start');

    // 5. Cross-owner device: OWNER cannot scope a declaration to OTHER's device.
    res = await post({ placement: 'wrist', effective_start: '2026-10-06T00:00:00Z', device_id: LOCAL_B });
    assertEquals(res.status, 409);
    assertEquals((await res.json()).error, 'device_registration_pending');

    // 6. GET returns the owner's intervals with EXTERNAL device ids (phone grouping contract).
    res = await get();
    assertEquals(res.status, 200, 'placement POST must be accepted');
    const payload: any = await res.json();
    assert(Array.isArray(payload.intervals));
    assertEquals(payload.intervals.length, 3);
    const byRevision = Object.fromEntries(payload.intervals.map((i: any) => [i.revision, i]));
    // PostgREST renders timestamptz in the session zone; the phone's ISO8601DateFormatter
    // parses it, so compare instants rather than literal strings.
    const first = byRevision[1];
    const second = byRevision[2];
    const scoped = byRevision[3];
    assertEquals(first.placement, 'wrist');
    assertEquals(first.device_id, null);
    assertEquals(first.source, 'user');
    assertEquals(second.placement, 'bicep');
    // The correction closed the first interval at its own start. The user-level bicep
    // interval stays open: the RPC's cap query is scope-aware (user-level rows are not
    // capped by a later device-scoped declaration), so a user-level open interval and a
    // device-scoped open interval coexist — exactly the placement_intervals semantics.
    assertEquals(new Date(first.effective_end).getTime(), new Date(second.effective_start).getTime());
    assertEquals(second.effective_end, null);
    assertEquals(scoped.placement, 'wrist');
    assertEquals(scoped.device_id, LOCAL, 'GET returns the EXTERNAL device id for phone grouping');
    assertEquals(scoped.effective_end, null);
    for (const i of payload.intervals) {
      assert(i.id && i.placement && i.effective_start && i.revision && i.source);
    }

    // 7. Direct RPC guards: mismatched owner/device raises device_owner_mismatch, and an
    //    authenticated caller cannot declare placement for another owner (cross_user_caller).
    await assertNode.rejects(
      () => db.rest.rpc('set_placement_interval', {
        p_owner: USER, p_placement: 'wrist', p_effective_start: '2026-10-01T00:00:00Z', p_device: DEVICE_B,
      }),
      (error: any) => error.code === 'device_owner_mismatch' && error.status === 403,
    );
    const cross = await db.request('rpc/set_placement_interval', 'authenticated', USER, 'POST', {
      p_owner: OTHER, p_placement: 'wrist', p_effective_start: '2026-10-01T00:00:00Z',
    });
    assert(cross.status === 403, `cross-owner write must be rejected 403, got ${cross.status}: ${JSON.stringify(cross.body)}`);
    assert((cross.body as any)?.message === 'cross_user_caller', `cross-owner code must propagate, got ${JSON.stringify(cross.body)}`);
    // And nothing landed for OTHER from that rejected write.
    const otherRows = (await db.sql(`select count(*) from public.placement_intervals where owner='${OTHER}'`)).trim();
    assertEquals(otherRows, '0');
  } finally {
    await db.close();
  }
});
