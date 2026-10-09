import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { parseContextMinutesQuery } from '../_shared/measurementContext.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/context-minutes: the owner's per-minute measurement context (20261009130100). The owner comes from the
// credential (never the query), the device from the caller's own devices (or every device of the owner when none is
// named), at most 1440 minutes per call, through measurement_context_minutes_read_v1.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const OTHER = '7f2c9a10-4b3e-4d8a-9c11-00000000f002';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
const FROM = 1_789_999_980;

function fakeRest(calls: Array<{ name: string; args: any }>, { knownDevice = true } = {}) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') {
      assert(query.includes(`user_id=eq.${USER}`), 'devices are looked up for the credential owner only');
      return knownDevice ? [{ id: DEVICE }] : [];
    }
    return [];
  };
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    return { rows: [{ minute_start: FROM, device_id: DEVICE, quality_class: 'good', reasons: [] }],
      versions: { '1': { builder_version: 'mcm-1' } }, truncated: false };
  };
  return rest;
}

function get(query: string, method = 'GET') {
  return new Request(`https://example.test/functions/v1/scores/context-minutes?${query}`, {
    method, headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('context minutes: one device, owner and device from the credential, range as ISO', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  const res = await handleScoresRequest(
    get(`deviceId=${LOCAL_DEVICE}&from=${FROM}&to=${FROM + 3600}&user_id=${OTHER}`), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('cache-control'), 'no-store');
  const body = await res.json();
  assertEquals(calls, [{ name: 'measurement_context_minutes_read_v1', args: {
    p_user: USER, p_device: DEVICE, p_from: new Date(FROM * 1000).toISOString(),
    p_to: new Date((FROM + 3600) * 1000).toISOString() } }]);
  assertEquals(body.rows.length, 1);
  assertEquals(body.versions['1'].builder_version, 'mcm-1');
  assertEquals(body.truncated, false);
  assertEquals(body.identity.userId, USER);
});

Deno.test('context minutes: no deviceId reads every device of the owner', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  const res = await handleScoresRequest(get(`from=${FROM}&to=${FROM + 86_400}`), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(calls[0].args.p_device, null);
  assertEquals(calls[0].args.p_user, USER);
});

Deno.test('context minutes: a device the caller does not own is 409, a malformed one 400', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  let res = await handleScoresRequest(get(`deviceId=${LOCAL_DEVICE}&from=${FROM}&to=${FROM + 60}`),
    { rest: fakeRest(calls, { knownDevice: false }), cfg });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'device_registration_pending');
  res = await handleScoresRequest(get(`deviceId=${encodeURIComponent('\u00e9t\u00e9')}&from=${FROM}&to=${FROM + 60}`),
    { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 400);
  assertEquals(calls.length, 0, 'the database is never asked');
});

Deno.test('context minutes: ranges are at most 1440 minutes, half-open and well formed', async () => {
  for (const q of [`from=${FROM}&to=${FROM + 86_401}`, `from=${FROM}&to=${FROM}`, `from=${FROM + 60}&to=${FROM}`,
    `from=abc&to=${FROM}`, `to=${FROM}`, `from=${FROM}`, `from=-1&to=${FROM}`, `from=${FROM}.5&to=${FROM + 60}`]) {
    let threw = false;
    try { parseContextMinutesQuery(new URLSearchParams(q)); } catch (e: any) { threw = e.code === 'invalid_range'; }
    assert(threw, q);
  }
  assertEquals(parseContextMinutesQuery(new URLSearchParams(`from=${FROM}&to=${FROM + 86_400}`)),
    { from: new Date(FROM * 1000).toISOString(), to: new Date((FROM + 86_400) * 1000).toISOString() });
  const calls: Array<{ name: string; args: any }> = [];
  const res = await handleScoresRequest(get(`from=${FROM}&to=${FROM + 86_460}`), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_range');
  assertEquals(calls.length, 0);
});

Deno.test('context minutes: POST is not allowed, no credential is 401', async () => {
  const res = await handleScoresRequest(get(`from=${FROM}&to=${FROM + 60}`, 'POST'), { rest: fakeRest([]), cfg });
  assertEquals(res.status, 405);
  const anon = new Request(`https://example.test/functions/v1/scores/context-minutes?from=${FROM}&to=${FROM + 60}`);
  const res2 = await handleScoresRequest(anon, { rest: fakeRest([]), cfg });
  assertEquals(res2.status, 401);
});
