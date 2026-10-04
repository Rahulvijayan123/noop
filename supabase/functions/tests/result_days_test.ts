import { assertEquals } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { makeMemRest } from './helpers.ts';

const user = '11111111-1111-4111-8111-111111111111';
const source = '33333333-3333-4333-8333-333333333333';
const local = 'whoop-ABC123456';
const device = noopDeviceId(user, local);
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public', allowLegacyEnrollment: true };
async function fixture(method: 'enrollment_code' | 'supabase_auth' = 'enrollment_code') {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', provisioning_method: method, user_id: user, source_id: source },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await rest.upsert('noop_app_installations', { user_id: user, source_id: source });
  await rest.upsert('compute_account_sources', { user_id: user, source_id: source });
  await rest.upsert('devices', { id: device, user_id: user, source_kind: 'noop_push', external_device_id: local });
  const calls: any[] = [];
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    return { schema_version: 1, days: [{ day: '2026-01-01', change_revision: 42 }], next_cursor: 42,
      scope_revision: 'a'.repeat(32), has_more: true };
  };
  return { rest, calls };
}
function request(query = '', account = false, fleet = true) {
  return new Request(`https://test.invalid/functions/v1/scores/days?deviceId=${local}${query}`, {
    headers: { authorization: `Bearer ${account ? 'header.payload.signature' : 'noop_personal'}`,
      ...(fleet ? { 'x-noop-fleet-token': 'noop_fleet' } : {}), 'x-noop-source-id': source },
  });
}
Deno.test('result days: both authorized routes use exact canonical identity and preserve old-day cursor', async () => {
  const { rest, calls } = await fixture();
  for (const account of [false, true]) {
    const response = await handleScoresRequest(request('&cursor=41&limit=3&scopeRevision=' + 'a'.repeat(32), account),
      { rest, cfg, fetchImpl: async () => Response.json({ id: user }) });
    assertEquals(response.status, 200);
    const page = await response.json();
    assertEquals(page.days[0].day, '2026-01-01');
    assertEquals(page.identity.deviceId, device);
    assertEquals(response.headers.get('cache-control'), 'no-store');
  }
  assertEquals(calls.length, 2);
  assertEquals(calls[0], calls[1]);
  assertEquals(calls[0], { name: 'server_result_days_page', args: {
    p_user: user, p_device: device, p_source: source, p_after: 41, p_limit: 3, p_scope_revision: 'a'.repeat(32),
  } });
});
Deno.test('result days: invalid cursor, unbounded limit and revoked identity never reach discovery RPC', async () => {
  for (const query of ['&cursor=-1', '&cursor=1.1', '&cursor=9007199254740992', '&limit=0', '&limit=33', '&scopeRevision=foreign']) {
    const { rest, calls } = await fixture();
    assertEquals((await handleScoresRequest(request(query), { rest, cfg })).status, 400);
    assertEquals(calls.length, 0);
  }
  const { rest, calls } = await fixture();
  rest.tables.get('noop_app_installations')[0].revoked_at = '2026-01-01T00:00:00Z';
  assertEquals((await handleScoresRequest(request(), { rest, cfg })).status, 401);
  assertEquals(calls.length, 0);
});
Deno.test('result days: unknown device cannot fall back to another device', async () => {
  const { rest, calls } = await fixture();
  rest.tables.set('devices', []);
  assertEquals((await handleScoresRequest(request(), { rest, cfg })).status, 409);
  assertEquals(calls.length, 0);
});
Deno.test('result days: an Auth-provisioned installation needs no fleet credential, and legacy enrollment is closed by default', async () => {
  const authProvisioned = await fixture('supabase_auth');
  const closed = { supabaseUrl: cfg.supabaseUrl, supabaseAnonKey: cfg.supabaseAnonKey };
  const ok = await handleScoresRequest(request('', false, false), { rest: authProvisioned.rest, cfg: closed });
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).identity.deviceId, device);
  assertEquals(authProvisioned.calls.length, 1);

  const legacy = await fixture('enrollment_code');
  assertEquals((await handleScoresRequest(request(), { rest: legacy.rest, cfg: closed })).status, 401);
  assertEquals(legacy.calls.length, 0, 'a refused credential never reaches the discovery RPC');
});
