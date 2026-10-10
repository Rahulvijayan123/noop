// The account-sync policy (_shared/syncPolicy.ts) and the provisioning reply that carries it, over in-memory
// doubles. The capabilities reply is covered in registry_test.ts, coach status in coach_test.ts, and all three
// against the real database in account_sync_health_sql_test.ts.
import assert from 'node:assert/strict';
import {
  DEFAULT_SYNC_STALE_AFTER_HOURS,
  MAX_SYNC_STALE_AFTER_HOURS,
  syncPolicyBody,
  syncPolicyFromEnv,
} from '../_shared/syncPolicy.ts';
import { createInstallationProvisioning, PROVISIONING_PROTOCOL_VERSION } from '../_shared/provisioning.ts';
import type { SupabaseRest } from '../_shared/rest.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const SOURCE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const TOKEN_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const JWT = 'header.payload.signature';

Deno.test('sync policy: required with a 24 h window unless the operator says otherwise', () => {
  assert.deepEqual(syncPolicyFromEnv({}), { required: true, staleAfterHours: 24 });
  assert.equal(DEFAULT_SYNC_STALE_AFTER_HOURS, 24);
  // Only an explicit off switch relaxes it; anything else, including typos, keeps it on.
  for (const value of ['0', 'false', 'FALSE', 'no', 'No', 'off', ' off ']) {
    assert.equal(syncPolicyFromEnv({ NOOP_SYNC_REQUIRED: value }).required, false, value);
  }
  for (const value of [undefined, '', '1', 'true', 'yes', 'on', 'disabled', 'nope', '00']) {
    assert.equal(syncPolicyFromEnv({ NOOP_SYNC_REQUIRED: value }).required, true, String(value));
  }
});

Deno.test('sync policy: the stale window is a whole number of hours, capped at 720, otherwise 24', () => {
  const hours = (value: string | undefined) => syncPolicyFromEnv({ NOOP_SYNC_STALE_AFTER_HOURS: value }).staleAfterHours;
  assert.equal(hours('1'), 1);
  assert.equal(hours('48'), 48);
  assert.equal(hours(' 72 '), 72);
  assert.equal(hours('720'), 720);
  assert.equal(hours('721'), MAX_SYNC_STALE_AFTER_HOURS);
  assert.equal(hours('9999999999'), 720);
  assert.equal(hours('9'.repeat(400)), 720);
  for (const invalid of [undefined, '', '0', '000', '-1', '+5', '1.5', '24h', 'abc', 'Infinity', 'NaN', '1e3', '0x10']) {
    assert.equal(hours(invalid), 24, String(invalid));
  }
  // The two settings are independent.
  assert.deepEqual(syncPolicyFromEnv({ NOOP_SYNC_REQUIRED: 'off', NOOP_SYNC_STALE_AFTER_HOURS: '6' }),
    { required: false, staleAfterHours: 6 });
});

Deno.test('sync policy: the wire body is a fresh object with exactly the two keys', () => {
  const policy = { required: true, staleAfterHours: 12, extra: 'x' } as any;
  const body = syncPolicyBody(policy);
  assert.deepEqual(body, { required: true, staleAfterHours: 12 });
  assert.notEqual(body, policy);
});

/** GoTrue's `/auth/v1/user` for one confirmed account, and a provisioning RPC that answers `action`. */
function doubles(action: 'created' | 'reused' | 'rotated' | 'upgraded') {
  const fetchImpl = ((input: string | URL | Request, init?: RequestInit) => {
    assert.ok(String(input).endsWith('/auth/v1/user'));
    const bearer = new Headers(init?.headers).get('authorization');
    return Promise.resolve(bearer === `Bearer ${JWT}`
      ? Response.json({ id: USER, email: 'a@example.test', email_confirmed_at: '2026-10-09T00:00:00Z', is_anonymous: false })
      : Response.json({ error_code: 'bad_jwt' }, { status: 403 }));
  }) as typeof fetch;
  const rest = {
    configured: true,
    rpc: (name: string, args: any) => {
      assert.equal(name, 'provision_noop_installation');
      return Promise.resolve({ userId: args.p_user_id, sourceId: args.p_source_id, tokenId: TOKEN_ID, action,
        expiresAt: '2027-10-09T00:00:00.000Z' });
    },
  } as unknown as SupabaseRest;
  return { fetchImpl, rest };
}
const provisionRequest = (jwt = JWT) => new Request('https://x.test/functions/v1/push/installations/provision', {
  method: 'POST',
  headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
  body: JSON.stringify({ sourceId: SOURCE, platform: 'ios', appVersion: '1.0 (1)' }),
});

Deno.test('provisioning: every success carries syncPolicy; the protocol version is unchanged; errors do not', async () => {
  for (const action of ['created', 'reused', 'rotated', 'upgraded'] as const) {
    const { fetchImpl, rest } = doubles(action);
    const injected = { required: false, staleAfterHours: 6 };
    const provision = createInstallationProvisioning({
      rest, fetchImpl, supabaseUrl: 'https://project.test', anonKey: 'sb_publishable_test',
      newToken: () => `noop_${'t'.repeat(43)}`, syncPolicy: injected,
    });
    const response = await provision(provisionRequest());
    const body = await response.json();
    assert.equal(response.status, action === 'created' ? 201 : 200, action);
    assert.equal(body.type, 'installationProvisioning');
    assert.equal(body.protocolVersion, PROVISIONING_PROTOCOL_VERSION);
    assert.equal(PROVISIONING_PROTOCOL_VERSION, '1.2', 'additive: no protocol bump');
    assert.deepEqual(body.syncPolicy, injected, action);
    assert.equal('installationToken' in body, action !== 'reused');

    const refused = await provision(provisionRequest('other.jwt.value'));
    assert.equal(refused.status, 401);
    assert.equal('syncPolicy' in await refused.json(), false, 'a failure reply has no policy');
  }

  // Not injected: the environment decides, exactly as syncPolicyFromEnv reads it.
  const { fetchImpl, rest } = doubles('created');
  const provision = createInstallationProvisioning({
    rest, fetchImpl, supabaseUrl: 'https://project.test', anonKey: 'sb_publishable_test',
    newToken: () => `noop_${'t'.repeat(43)}`,
  });
  assert.deepEqual((await (await provision(provisionRequest())).json()).syncPolicy, syncPolicyFromEnv());
});
