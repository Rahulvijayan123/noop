import { assert, assertEquals } from 'jsr:@std/assert';
import { createInstallationLifecycle } from '../_shared/installationLifecycle.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const OWNER = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const P = '33333333-3333-4333-8333-333333333333';
const C = '44444444-4444-4444-8444-444444444444';
const TOKEN = 'noop_installationFixture';
const FLEET = 'noop_fleetFixture';
const marker = { code: 'PT409', message: 'retained_legacy_identity_v1' };

type Options = { failure?: unknown; failureStatus?: number; at?: string; external?: string; noAuth?: boolean; noFleet?: boolean; revoked?: boolean; admitted?: boolean; success?: unknown; method?: 'enrollment_code' | 'supabase_auth'; legacyEnrollment?: boolean };
async function invoke(options: Options = {}) {
  const calls: { path: string; query: string; body: any; method: string }[] = [];
  const rest = createSupabaseRest({ cfg: { supabaseUrl: 'https://retained-fixture.invalid', supabaseServiceRoleKey: 'fixture-service-role' },
    fetchImpl: async (input, init) => {
      const url = new URL(String(input));
      assertEquals(url.origin, 'https://retained-fixture.invalid');
      const path = url.pathname.slice('/rest/v1/'.length);
      const body = init?.body ? JSON.parse(String(init.body)) : null;
      calls.push({ path, query: url.search, body, method: init?.method || 'GET' });
      assertEquals((init?.headers as Record<string, string>).authorization, 'Bearer fixture-service-role');
      if (path === (options.at || 'rpc/confirm_noop_wearable') && options.failure !== undefined) {
        return Response.json(options.failure, { status: options.failureStatus || 409 });
      }
      if (init?.method === 'PATCH') return Response.json([]);
      if (path === 'noop_ingest_tokens') {
        const fleet = url.searchParams.get('token_hash') === `eq.${hashIngestToken(FLEET)}`;
        assert(fleet || url.searchParams.get('token_hash') === `eq.${hashIngestToken(TOKEN)}`);
        return Response.json([{ id: fleet ? C : P, user_id: fleet ? null : OWNER, token_kind: fleet ? 'fleet' : 'installation', source_id: fleet ? null : SOURCE,
          ...(fleet ? {} : { provisioning_method: options.method ?? 'enrollment_code' }) }]);
      }
      if (path === 'noop_app_installations') return Response.json([{ user_id: OWNER, source_id: SOURCE, revoked_at: options.revoked ? '2026-09-24T00:00:00Z' : null }]);
      if (path === 'devices') return Response.json([{ id: url.searchParams.get('external_device_id')?.includes('installation:') ? P : C }]);
      if (path === 'noop_wearable_aliases') return Response.json([]);
      if (path === 'rpc/admit_noop_request') return Response.json(options.admitted !== false);
      if (path === 'rpc/confirm_noop_wearable') return Response.json(options.success ?? C);
      throw new Error(`Unexpected fixture request ${path}`);
    },
  });
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (!options.noAuth) headers.authorization = `Bearer ${TOKEN}`;
  if (!options.noFleet) headers['x-noop-fleet-token'] = FLEET;
  const response = await createInstallationLifecycle(rest, { allowLegacyEnrollment: options.legacyEnrollment ?? true })(new Request('https://receiver.invalid/wearables/confirm', {
    method: 'POST', headers, body: JSON.stringify({ provisionalExternalDeviceId: options.external ?? 'my-whoop',
      userId: C, sourceId: C, evidence: { method: 'device_information_serial_v1', serial: 'ABCDEF123', receiptSha256: 'a'.repeat(64) } }),
  }), 'confirm');
  return { status: response.status, body: await response.json(), headers: response.headers, calls };
}

Deno.test('retained identity: production REST error decoder and lifecycle return exact fenced 202', async () => {
  const r = await invoke({ failure: marker });
  assertEquals(r.status, 202);
  assertEquals(r.body, { version: 1, state: 'deferred', reason: 'retained_identity_requires_review', userId: OWNER, sourceId: SOURCE, provisionalExternalDeviceId: 'my-whoop', deviceId: P });
  assertEquals(r.headers.get('cache-control'), 'no-store');
  const rpc = r.calls.find(x => x.path === 'rpc/confirm_noop_wearable')!;
  assertEquals(rpc.body.p_user, OWNER); assertEquals(rpc.body.p_source, SOURCE);
  assertEquals(rpc.body.p_provisional, P); assertEquals(rpc.body.p_canonical, C);
  assertEquals(r.calls.filter(x => x.path === 'rpc/confirm_noop_wearable').length, 1);
  assert(!r.calls.some(x => x.path === 'noop_wearable_aliases' && x.method !== 'GET'));
});

Deno.test('retained identity: normal confirmed association remains successful', async () => {
  const r = await invoke(); assertEquals(r.status, 200);
  assertEquals(r.body, { userId: OWNER, sourceId: SOURCE, deviceId: C, state: 'confirmed' });
});

Deno.test('retained identity: generic timeout and marker lookalikes cannot authorize deferral', async () => {
  for (const failure of [
    { code: '57014', message: 'canceling statement due to statement timeout' },
    { code: 'P0001', message: marker.message },
    { code: marker.code, message: marker.message + '_extra' },
    { message: marker.message }, marker.message,
  ]) {
    const r = await invoke({ failure, failureStatus: 503 });
    assertEquals(r.status, 503); assertEquals(r.body, { code: 'lifecycle_unavailable' });
  }
});

Deno.test('retained identity: unrelated RPC marker cannot authorize deferral', async () => {
  const r = await invoke({ failure: marker, at: 'rpc/admit_noop_request' });
  assertEquals(r.status, 409); assertEquals(r.body, { code: 'lifecycle_conflict' });
  assert(!r.calls.some(x => x.path === 'rpc/confirm_noop_wearable'));
});

Deno.test('retained identity: nonlegacy pairing is never deferred', async () => {
  const r = await invoke({ failure: marker, external: 'whoop-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' });
  assertEquals(r.status, 409); assertEquals(r.body, { code: 'lifecycle_conflict' });
});

Deno.test('retained identity: authorization, retirement and rate admission remain fail closed', async () => {
  for (const options of [{ noAuth: true }, { noFleet: true }, { revoked: true }]) {
    const r = await invoke(options); assertEquals(r.status, 401);
    assert(!r.calls.some(x => x.path === 'rpc/confirm_noop_wearable'));
  }
  const limited = await invoke({ admitted: false }); assertEquals(limited.status, 429);
  for (const status of [401, 403, 409]) {
    const r = await invoke({ failure: { code: '42501', message: 'forbidden' }, failureStatus: status });
    assertEquals(r.status, status === 409 ? 409 : 401); assert(r.body.state !== 'deferred');
  }
});

Deno.test('retained identity: exact SQL marker requires HTTP409 and cannot mask other status', async () => {
  for (const status of [401, 403, 503]) {
    const r = await invoke({ failure: marker, failureStatus: status });
    assertEquals(r.status, status === 403 ? 401 : status);
    assert(r.body.state !== 'deferred');
  }
  const conflict = await invoke({ failure: { code: 'PT409', message: 'retained_legacy_identity_source_conflict_v1' } });
  assertEquals(conflict.status, 409); assertEquals(conflict.body, { code: 'lifecycle_conflict' });
});

Deno.test('retained identity: an Auth-provisioned installation needs no fleet credential and is fenced the same way', async () => {
  const confirmed = await invoke({ method: 'supabase_auth', noFleet: true, legacyEnrollment: false });
  assertEquals(confirmed.status, 200);
  assertEquals(confirmed.body, { userId: OWNER, sourceId: SOURCE, deviceId: C, state: 'confirmed' });
  const deferred = await invoke({ method: 'supabase_auth', noFleet: true, legacyEnrollment: false, failure: marker });
  assertEquals(deferred.status, 202);
  assertEquals(deferred.body.state, 'deferred');
  assertEquals(deferred.body.userId, OWNER);
});

Deno.test('retained identity: a pre-Auth enrollment credential is refused while legacy enrollment is off', async () => {
  const r = await invoke({ legacyEnrollment: false });
  assertEquals(r.status, 401);
  assert(!r.calls.some(x => x.path === 'rpc/confirm_noop_wearable'));
});
