// Supabase-Auth installation credentials across every Edge consumer. The credential is the whole
// upload identity: no fleet header, no compatibility flag. Legacy enrollment-code credentials stay
// dead unless the operator explicitly re-opens them. Fixtures are in-memory PostgREST doubles;
// the real database rules are covered by auth_provisioning_integration_test.ts.
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert';
import { IdentityError, hashIngestToken, resolveUploadIdentity } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { coachConfig, handleCoachRequest } from '../_shared/coach.ts';
import { createInstallationLifecycle } from '../_shared/installationLifecycle.ts';
import { namedKey, pushConfig } from '../_shared/config.ts';
import { restConfigFromEnv, serviceKeyHeaders } from '../_shared/rest.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';
const LEGACY_SOURCE = '55555555-5555-4555-8555-555555555555';
const LOCAL = 'whoop-ABC123456';
const OTHER_LOCAL = 'whoop-ZZZ999999';
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };

async function fixture() {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'auth-a', token_hash: hashIngestToken('noop_auth_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
    { id: 'auth-b', token_hash: hashIngestToken('noop_auth_b'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'legacy', token_hash: hashIngestToken('noop_legacy_install'), token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: LEGACY_SOURCE },
    { id: 'bare', token_hash: hashIngestToken('noop_bare_install'), token_kind: 'installation', user_id: USER, source_id: SOURCE },
    { id: 'bogus', token_hash: hashIngestToken('noop_bogus_install'), token_kind: 'installation', provisioning_method: 'magic', user_id: USER, source_id: SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
    { id: 'upload', token_hash: hashIngestToken('noop_legacy_upload'), token_kind: 'legacy_upload', user_id: USER },
  ]);
  await rest.upsert('noop_app_installations', [
    { user_id: USER, source_id: SOURCE },
    { user_id: OTHER, source_id: OTHER_SOURCE },
    { user_id: USER, source_id: LEGACY_SOURCE },
  ]);
  await rest.upsert('devices', [
    { id: noopDeviceId(USER, LOCAL), user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL },
    { id: noopDeviceId(OTHER, OTHER_LOCAL), user_id: OTHER, source_kind: 'noop_push', external_device_id: OTHER_LOCAL },
  ]);
  const calls: Array<{ name: string; args: any }> = [];
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    if (name === 'admit_noop_request') return true;
    if (name === 'retire_noop_installation') return { retired: true, tokenHash: args.p_token_hash };
    return { schema_version: 2, user_id: args.p_user, day: args.p_day, features: {
      hrv: { device_id: args.p_device, status: 'unavailable', reason: 'awaiting_result' } } };
  };
  return { rest, calls };
}

const bearer = (token: string, extra: Record<string, string> = {}) =>
  new Headers({ authorization: `Bearer ${token}`, ...extra });
const code = (error: unknown) => (error as IdentityError).code;

Deno.test('Auth credential: the installation token alone is the upload identity', async () => {
  const { rest } = await fixture();
  const identity = await resolveUploadIdentity({ headers: bearer('noop_auth_a'), rest });
  assertEquals(identity.id, USER);
  assertEquals(identity.sourceId, SOURCE);
  assertEquals(identity.authMode, 'installation');
  assertEquals((identity as { provisioning?: string }).provisioning, 'supabase_auth');
  // The shared fleet header is no longer part of the contract; a stale or bogus one is ignored,
  // never required and never able to change the resolved owner.
  for (const fleet of ['noop_fleet', 'noop_not_a_fleet_token', 'garbage', 'header.payload.signature']) {
    const withFleet = await resolveUploadIdentity({ headers: bearer('noop_auth_a', { 'x-noop-fleet-token': fleet }), rest });
    assertEquals([withFleet.id, withFleet.sourceId], [USER, SOURCE]);
  }
  const other = await resolveUploadIdentity({ headers: bearer('noop_auth_b'), rest });
  assertEquals([other.id, other.sourceId], [OTHER, OTHER_SOURCE]);
});

Deno.test('Auth credential: revoked, expired, orphaned and unclassified credentials fail closed', async () => {
  const mutate = [
    ['revoked token', (r: any) => { r.tables.get('noop_ingest_tokens')[0].revoked_at = '2026-01-01T00:00:00Z'; }, 'installation_revoked'],
    ['expired token', (r: any) => { r.tables.get('noop_ingest_tokens')[0].expires_at = '2020-01-01T00:00:00Z'; }, 'unauthorized'],
    ['revoked installation', (r: any) => { r.tables.get('noop_app_installations')[0].revoked_at = '2026-01-01T00:00:00Z'; }, 'installation_revoked'],
    ['missing installation', (r: any) => { r.tables.set('noop_app_installations', []); }, 'unauthorized'],
    ['deleted account', (r: any) => {
      for (const table of ['noop_ingest_tokens', 'noop_app_installations']) {
        r.tables.set(table, r.tables.get(table).filter((row: any) => row.user_id !== USER));
      }
    }, 'unauthorized'],
  ] as const;
  for (const [name, change, expected] of mutate) {
    const { rest } = await fixture();
    change(rest);
    const error = await assertRejects(() => resolveUploadIdentity({ headers: bearer('noop_auth_a'), rest }), IdentityError, '', name);
    assertEquals(error.status, 401, name);
    assertEquals(error.code, expected, name);
  }
  // Rows with no recognizable provenance can be neither credential model.
  const { rest } = await fixture();
  for (const token of ['noop_bare_install', 'noop_bogus_install']) {
    for (const flags of [{}, { allowLegacyEnrollment: true }]) {
      const error = await assertRejects(() => resolveUploadIdentity({
        headers: bearer(token, { 'x-noop-fleet-token': 'noop_fleet' }), rest, ...flags }), IdentityError);
      assertEquals([error.status, error.code], [401, 'unauthorized']);
    }
  }
  // A fleet credential, a legacy upload token and a JWT can never be an installation identity.
  for (const token of ['noop_fleet', 'noop_legacy_upload', 'header.payload.signature']) {
    const error = await assertRejects(() => resolveUploadIdentity({ headers: bearer(token), rest }), IdentityError);
    assertEquals(error.status, 401);
  }
});

Deno.test('Legacy enrollment credentials are closed by default and still need the fleet credential when reopened', async () => {
  const { rest } = await fixture();
  const fleet = { 'x-noop-fleet-token': 'noop_fleet' };
  const closed = await assertRejects(() => resolveUploadIdentity({
    headers: bearer('noop_legacy_install', fleet), rest }), IdentityError);
  assertEquals([closed.status, closed.code], [401, 'legacy_enrollment_disabled']);
  const noFleet = await assertRejects(() => resolveUploadIdentity({
    headers: bearer('noop_legacy_install'), rest, allowLegacyEnrollment: true }), IdentityError);
  assertEquals(noFleet.status, 401);
  const reopened = await resolveUploadIdentity({
    headers: bearer('noop_legacy_install', fleet), rest, allowLegacyEnrollment: true });
  assertEquals([reopened.id, reopened.sourceId], [USER, LEGACY_SOURCE]);
  assertEquals((reopened as { provisioning?: string }).provisioning, 'enrollment_code');
  // Reopening the compatibility switch changes nothing for Auth credentials.
  assertEquals((await resolveUploadIdentity({ headers: bearer('noop_auth_a'), rest, allowLegacyEnrollment: true })).sourceId, SOURCE);
});

Deno.test('Auth credential: scores resolve the token owner without any fleet header, per account', async () => {
  const { rest, calls } = await fixture();
  const read = (token: string, device: string, extraHeaders: Record<string, string> = {}, config: any = cfg) =>
    handleScoresRequest(new Request(`https://test.invalid/functions/v1/scores?day=2026-09-19&deviceId=${device}&userId=${OTHER}`, {
      headers: { authorization: `Bearer ${token}`, ...extraHeaders } }), { rest, cfg: config });

  const own = await read('noop_auth_a', LOCAL);
  assertEquals(own.status, 200);
  const body = await own.json();
  assertEquals(body.identity, { userId: USER, sourceId: SOURCE, deviceId: noopDeviceId(USER, LOCAL), externalDeviceId: LOCAL, project: cfg.supabaseUrl });
  assertEquals(calls.at(-1)!.args.p_user, USER, 'a client-supplied userId must never select the owner');

  // A cannot address B's strap with A's credential, and B cannot address A's.
  const crossAB = await (await read('noop_auth_a', OTHER_LOCAL)).json();
  assertEquals(crossAB.identity.deviceId, null);
  assertEquals(crossAB.identity.userId, USER);
  const crossBA = await (await read('noop_auth_b', LOCAL)).json();
  assertEquals(crossBA.identity.deviceId, null);
  assertEquals(crossBA.identity.userId, OTHER);
  assertEquals((await (await read('noop_auth_b', OTHER_LOCAL)).json()).identity.deviceId, noopDeviceId(OTHER, OTHER_LOCAL));

  // The shared fleet credential grants nothing here, and a legacy credential is closed by default.
  assertEquals((await read('noop_fleet', LOCAL)).status, 401);
  assertEquals((await read('noop_legacy_upload', LOCAL)).status, 401);
  const legacyClosed = await read('noop_legacy_install', LOCAL, { 'x-noop-fleet-token': 'noop_fleet' });
  assertEquals(legacyClosed.status, 401);
  assertEquals((await legacyClosed.json()).error, 'legacy_enrollment_disabled');
  assertEquals((await read('noop_legacy_install', LOCAL, { 'x-noop-fleet-token': 'noop_fleet' },
    { ...cfg, allowLegacyEnrollment: true })).status, 200);
});

Deno.test('Auth credential: coach routes need only the installation token', async () => {
  const { rest } = await fixture();
  const fetchImpl = (() => { throw new Error('provider must not be reached'); }) as unknown as typeof fetch;
  const call = (token: string, extra: Record<string, string> = {}, config = coachConfig({ FIREWORKS_AI_API_KEY: 'k' })) =>
    handleCoachRequest(new Request('https://test.invalid/functions/v1/coach/status', {
      headers: { authorization: `Bearer ${token}`, ...extra } }), { rest, cfg: config, fetchImpl });
  assertEquals((await call('noop_auth_a')).status, 200);
  assertEquals((await call('noop_auth_a', { 'x-noop-fleet-token': 'noop_stale' })).status, 200);
  assertEquals((await call('noop_fleet')).status, 401);
  assertEquals((await call('noop_bare_install', { 'x-noop-fleet-token': 'noop_fleet' })).status, 401);
  assertEquals((await call('noop_legacy_install', { 'x-noop-fleet-token': 'noop_fleet' })).status, 401);
  assertEquals((await call('noop_legacy_install', { 'x-noop-fleet-token': 'noop_fleet' },
    coachConfig({ FIREWORKS_AI_API_KEY: 'k', NOOP_ALLOW_LEGACY_ENROLLMENT: 'true' }))).status, 200);
});

Deno.test('Auth credential: wearable lifecycle and retirement work without a fleet credential', async () => {
  const { rest, calls } = await fixture();
  const lifecycle = createInstallationLifecycle(rest);
  const post = (path: string, token: string, extra: Record<string, string> = {}, body: unknown = {}) =>
    new Request(`https://test.invalid/functions/v1/push${path}`, {
      method: 'POST', body: JSON.stringify(body), headers: { authorization: `Bearer ${token}`, ...extra } });

  // retire: Auth token needs nothing else; legacy provenance needs the switch AND the fleet credential.
  const retired = await lifecycle(post('/installation/retire', 'noop_auth_a'), 'retire');
  assertEquals(retired.status, 200);
  assertEquals(calls.at(-1), { name: 'retire_noop_installation', args: { p_token_hash: hashIngestToken('noop_auth_a') } });
  const fleet = { 'x-noop-fleet-token': 'noop_fleet' };
  for (const [token, extra] of [['noop_legacy_install', fleet], ['noop_bare_install', fleet], ['noop_fleet', {}],
    ['noop_unknown_token', {}], ['header.payload.signature', {}]] as Array<[string, Record<string, string>]>) {
    calls.length = 0;
    assertEquals((await lifecycle(post('/installation/retire', token, extra), 'retire')).status, 401, token);
    assertEquals(calls, [], `${token} must not reach retirement`);
  }
  const reopened = createInstallationLifecycle(rest, { allowLegacyEnrollment: true });
  assertEquals((await reopened(post('/installation/retire', 'noop_legacy_install'), 'retire')).status, 401);
  assertEquals((await reopened(post('/installation/retire', 'noop_legacy_install', fleet), 'retire')).status, 200);

  // confirm/handoff resolve the owner from the credential, then the admission gate runs.
  calls.length = 0;
  const handoff = await lifecycle(post('/wearables/handoff', 'noop_auth_a', {}, { externalDeviceId: LOCAL }), 'handoff');
  assertEquals(calls[0], { name: 'admit_noop_request', args: { p_user: USER, p_source: SOURCE } });
  assert([200, 404, 409, 503].includes(handoff.status));
  calls.length = 0;
  const denied = await lifecycle(post('/wearables/handoff', 'noop_legacy_install', fleet, { externalDeviceId: LOCAL }), 'handoff');
  assertEquals(denied.status, 401);
  assertEquals(calls, []);
});

Deno.test('Server key configuration: publishable/secret keys and the legacy compatibility switch', () => {
  assertEquals(namedKey('{"default":"sb_publishable_abc","other":"sb_publishable_xyz"}', 'sb_publishable_'), 'sb_publishable_abc');
  assertEquals(namedKey('{"first":"sb_secret_one"}', 'sb_secret_'), 'sb_secret_one');
  assertEquals(namedKey('{"default":"eyJ.legacy.jwt"}', 'sb_publishable_'), '', 'a mislabeled key is never adopted');
  assertEquals(namedKey('sb_publishable_bare', 'sb_publishable_'), 'sb_publishable_bare');
  assertEquals(namedKey('', 'sb_secret_'), '');
  assertEquals(namedKey('not json', 'sb_secret_'), '');

  const none = pushConfig({});
  assertEquals([none.supabaseAnonKey, none.supabaseServiceRoleKey, none.allowLegacyEnrollment, none.allowLegacyFleetUploads],
    ['', '', false, false]);
  const modern = pushConfig({
    SUPABASE_URL: 'https://p.supabase.co/',
    SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_pub"}',
    SUPABASE_SECRET_KEYS: '{"default":"sb_secret_srv"}',
  });
  assertEquals([modern.supabaseUrl, modern.supabaseAnonKey, modern.supabaseServiceRoleKey],
    ['https://p.supabase.co', 'sb_publishable_pub', 'sb_secret_srv']);
  // Existing deployments keep their legacy keys: they win while present, so rotating to the new
  // key model is an explicit operator step rather than a silent behavior change.
  const mixed = pushConfig({
    SUPABASE_ANON_KEY: 'legacy-anon', SUPABASE_SERVICE_ROLE_KEY: 'legacy-service',
    SUPABASE_SECRET_KEYS: '{"default":"sb_secret_srv"}',
  });
  assertEquals([mixed.supabaseAnonKey, mixed.supabaseServiceRoleKey], ['legacy-anon', 'legacy-service']);
  assertEquals(pushConfig({ SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_direct', SUPABASE_ANON_KEY: 'legacy-anon' }).supabaseAnonKey,
    'sb_publishable_direct');
  assertEquals(restConfigFromEnv({ SUPABASE_URL: 'https://p.supabase.co', SUPABASE_SECRET_KEY: 'sb_secret_direct' }).supabaseServiceRoleKey,
    'sb_secret_direct');
  for (const value of ['true', 'TRUE']) assertEquals(pushConfig({ NOOP_ALLOW_LEGACY_ENROLLMENT: value }).allowLegacyEnrollment, true);
  for (const value of ['', '1', 'yes', 'false']) assertEquals(pushConfig({ NOOP_ALLOW_LEGACY_ENROLLMENT: value }).allowLegacyEnrollment, false);

  // Opaque secret keys are apikey-only; legacy service_role JWTs also travel as a bearer.
  assertEquals(serviceKeyHeaders('sb_secret_abc'), { apikey: 'sb_secret_abc' });
  assertEquals(serviceKeyHeaders('eyJ.legacy.jwt'), { apikey: 'eyJ.legacy.jwt', authorization: 'Bearer eyJ.legacy.jwt' });
});
