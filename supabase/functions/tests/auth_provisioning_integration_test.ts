// Supabase-Auth installation provisioning against native PostgreSQL + real PostgREST.
// Only GoTrue is simulated (a fake `/auth/v1/user`); every database rule, grant, trigger and
// constraint below executes for real, and the Edge handlers run their production code.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { createInstallationProvisioning, CURRENT_INSTALLATION_TOKEN_HEADER } from '../_shared/provisioning.ts';
import { createInstallationLifecycle } from '../_shared/installationLifecycle.ts';
import { resolveUploadIdentity } from '../_shared/tokens.ts';
import { syncPolicyFromEnv } from '../_shared/syncPolicy.ts';

const SOURCE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const SOURCE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const USER_C = '33333333-3333-4333-8333-333333333333';
const sha = (value: string) => createHash('sha256').update(value).digest('hex');
const tokenOf = (label: string) => `noop_${label}${'x'.repeat(40)}`;

interface FakeUser { id: string; email: string | null; confirmed: boolean; anonymous?: boolean }

function fakeGoTrue(users: Record<string, FakeUser>): typeof fetch {
  return async (input, init) => {
    const url = String(input);
    assert.ok(url.endsWith('/auth/v1/user'), `unexpected auth call ${url}`);
    const headers = new Headers(init?.headers);
    assert.ok(headers.get('apikey'), 'GoTrue must be called with the publishable key');
    const jwt = (headers.get('authorization') ?? '').replace(/^Bearer /, '');
    const user = users[jwt];
    if (!user) return Response.json({ error_code: 'bad_jwt' }, { status: 403 });
    return Response.json({
      id: user.id,
      email: user.email,
      email_confirmed_at: user.confirmed ? '2026-10-03T00:00:00Z' : null,
      is_anonymous: user.anonymous === true,
    });
  };
}

const JWT_A = 'aaaa.aaaa.aaaa';
const JWT_B = 'bbbb.bbbb.bbbb';
const JWT_C = 'cccc.cccc.cccc';
const JWT_UNCONFIRMED = 'unconfirmed.unconfirmed.unconfirmed';
const JWT_ANON = 'anon.anon.anon';
const users: Record<string, FakeUser> = {
  [JWT_A]: { id: USER_A, email: 'a@example.test', confirmed: true },
  [JWT_B]: { id: USER_B, email: 'b@example.test', confirmed: true },
  [JWT_C]: { id: USER_C, email: 'c@example.test', confirmed: true },
  [JWT_UNCONFIRMED]: { id: USER_C, email: 'c@example.test', confirmed: false },
  [JWT_ANON]: { id: USER_C, email: null, confirmed: false, anonymous: true },
};

Deno.test('Supabase-Auth installation provisioning: ownership, credentials, isolation and fail-closed behavior', async () => {
  const db = await startLocalPostgres({ installationLifecycle: true, authProvisioning: true });
  try {
    await db.sql(`insert into auth.users(id,email) values('${USER_C}','c@example.test') on conflict do nothing`);
    let counter = 0;
    const minted: string[] = [];
    const provision = createInstallationProvisioning({
      rest: db.rest, supabaseUrl: 'https://project.test', anonKey: 'sb_publishable_test',
      fetchImpl: fakeGoTrue(users),
      newToken: () => { const value = tokenOf(`mint${++counter}`); minted.push(value); return value; },
    });
    const lifecycle = createInstallationLifecycle(db.rest);
    const call = async (jwt: string | null, body: unknown, current?: string, raw?: string) => {
      const response = await provision(new Request('https://x.test/functions/v1/push/installations/provision', {
        method: 'POST',
        headers: {
          ...(jwt ? { authorization: `Bearer ${jwt}` } : {}),
          'content-type': 'application/json',
          ...(current ? { [CURRENT_INSTALLATION_TOKEN_HEADER]: current } : {}),
        },
        body: raw ?? JSON.stringify(body),
      }));
      return { status: response.status, headers: response.headers, body: await response.json() };
    };
    const upload = (token: string, extra: Record<string, string> = {}) =>
      resolveUploadIdentity({ headers: new Headers({ authorization: `Bearer ${token}`, ...extra }), rest: db.rest });
    const valid = { sourceId: SOURCE_A, platform: 'ios', appVersion: '1.0 (1)' };

    // ---- authentication of the provisioning request itself -----------------------------------
    for (const [jwt, status, code] of [
      [null, 401, 'unauthorized'],
      ['not-a-jwt', 401, 'unauthorized'],
      ['forged.forged.forged', 401, 'unauthorized'],
      [tokenOf('opaque'), 401, 'unauthorized'],
      [JWT_UNCONFIRMED, 403, 'email_not_confirmed'],
      [JWT_ANON, 403, 'email_not_confirmed'],
    ] as Array<[string | null, number, string]>) {
      const rejected = await call(jwt, valid);
      assert.equal(rejected.status, status, `${jwt}`);
      assert.equal(rejected.body.code, code, `${jwt}`);
      assert.equal(rejected.body.installationToken, undefined);
    }
    assert.equal(await db.sql('select count(*) from noop_app_installations'), '0');

    // ---- malformed requests never reach the database ----------------------------------------
    for (const body of [
      { ...valid, sourceId: 'not-a-uuid' },
      { ...valid, sourceId: undefined },
      { ...valid, platform: 'windows' },
      { ...valid, appVersion: '' },
      { ...valid, appVersion: 'x'.repeat(65) },
      { ...valid, appVersion: 'bad\u0007version' },
    ]) assert.equal((await call(JWT_A, body)).status, 400);
    assert.equal((await call(JWT_A, null, undefined, '{not json')).body.code, 'malformed_provisioning_request');
    assert.equal((await call(JWT_A, valid, 'not-a-noop-token')).body.code, 'invalid_installation_token');
    assert.equal((await call(JWT_A, null, undefined, JSON.stringify({ pad: 'x'.repeat(6000) }))).status, 413);
    assert.equal(await db.sql('select count(*) from noop_app_installations'), '0');

    // ---- created: ownership comes from the JWT, never from the body --------------------------
    const created = await call(JWT_A, { ...valid, userId: USER_B, user_id: USER_B });
    assert.equal(created.status, 201);
    assert.equal(created.headers.get('cache-control'), 'no-store');
    assert.equal(created.body.action, 'created');
    assert.equal(created.body.userId, USER_A, 'a client-supplied user id must be ignored');
    assert.equal(created.body.sourceId, SOURCE_A);
    // A signed-in account must keep syncing: the reply says so, from the environment when not injected.
    assert.deepEqual(created.body.syncPolicy, syncPolicyFromEnv());
    const tokenA1 = created.body.installationToken as string;
    assert.equal(tokenA1, minted[0]);
    assert.equal(await db.sql(`select user_id||'|'||provisioning_method||'|'||coalesce(enrollment_code_id::text,'null')
      from noop_app_installations where source_id='${SOURCE_A}'`), `${USER_A}|supabase_auth|null`);

    // Only the hash is stored; the plaintext credential is nowhere in the database.
    assert.equal(await db.sql(`select token_hash from noop_ingest_tokens where id='${created.body.tokenId}'`), sha(tokenA1));

    // The credential alone authenticates uploads: no fleet header exists anywhere on this path.
    const identity = await upload(tokenA1);
    assert.equal(identity.id, USER_A);
    assert.equal(identity.sourceId, SOURCE_A);
    assert.equal(identity.authMode, 'installation');
    assert.equal((identity as { provisioning?: string }).provisioning, 'supabase_auth');
    // A stray fleet header from an older client is simply ignored, never trusted or required.
    assert.equal((await upload(tokenA1, { 'x-noop-fleet-token': 'noop_stale_fleet' })).id, USER_A);

    // ---- reused: presenting the live credential issues nothing new ---------------------------
    const reused = await call(JWT_A, { ...valid, appVersion: '1.1 (2)' }, tokenA1);
    assert.equal(reused.status, 200);
    assert.equal(reused.body.action, 'reused');
    assert.equal(reused.body.tokenId, created.body.tokenId);
    assert.equal(reused.body.installationToken, undefined, 'a reused credential must not be re-issued');
    assert.deepEqual(reused.body.syncPolicy, syncPolicyFromEnv());
    assert.equal(await db.sql(`select app_version from noop_app_installations where source_id='${SOURCE_A}'`), '1.1 (2)');
    assert.equal((await upload(tokenA1)).id, USER_A);

    // ---- rotated: lost credential (no/incorrect proof) replaces and revokes the old one ------
    const rotated = await call(JWT_A, valid);
    assert.equal(rotated.body.action, 'rotated');
    assert.notEqual(rotated.body.tokenId, created.body.tokenId);
    const tokenA2 = rotated.body.installationToken as string;
    await assert.rejects(upload(tokenA1), (error: unknown) => (error as { code?: string }).code === 'installation_revoked');
    assert.equal((await upload(tokenA2)).sourceId, SOURCE_A);
    const wrongProof = await call(JWT_A, valid, tokenOf('someoneelse'));
    assert.equal(wrongProof.body.action, 'rotated');
    const tokenA3 = wrongProof.body.installationToken as string;
    await assert.rejects(upload(tokenA2), (error: unknown) => (error as { code?: string }).code === 'installation_revoked');
    assert.equal(await db.sql(`select count(*) from noop_ingest_tokens where source_id='${SOURCE_A}' and revoked_at is null`), '1');

    // ---- B can neither adopt nor learn anything about A's source -----------------------------
    const stolen = await call(JWT_B, valid, tokenA3);
    assert.equal(stolen.status, 409);
    assert.equal(stolen.body.code, 'installation_unavailable');
    assert.equal(stolen.body.installationToken, undefined);
    assert.equal((await call(JWT_B, valid)).body.code, 'installation_unavailable');
    assert.equal((await upload(tokenA3)).id, USER_A, 'A is untouched by B probing the source');
    assert.equal(await db.sql(`select user_id from noop_app_installations where source_id='${SOURCE_A}'`), USER_A);

    // ---- two users, two installations, independent credentials ------------------------------
    const bCreated = await call(JWT_B, { ...valid, sourceId: SOURCE_B });
    assert.equal(bCreated.body.action, 'created');
    assert.equal(bCreated.body.userId, USER_B);
    const bToken = bCreated.body.installationToken as string;
    assert.equal((await upload(bToken)).id, USER_B);
    assert.equal((await upload(bToken)).sourceId, SOURCE_B);
    assert.equal((await upload(tokenA3)).sourceId, SOURCE_A);
    // A cannot present B's credential to take over B's source either.
    const crossProof = await call(JWT_A, { ...valid, sourceId: SOURCE_B }, bToken);
    assert.equal(crossProof.body.code, 'installation_unavailable');
    assert.equal((await upload(bToken)).id, USER_B);

    // ---- the source/owner binding is permanent at the database level -------------------------
    await assert.rejects(db.sql(`update noop_app_installations set user_id='${USER_B}' where source_id='${SOURCE_A}'`),
      /installation_epoch_immutable/);
    await assert.rejects(db.sql(`update noop_app_installations set source_id=gen_random_uuid() where source_id='${SOURCE_A}'`),
      /installation_epoch_immutable|violates foreign key/);
    const codeB = crypto.randomUUID();
    await db.sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${codeB}','${USER_B}',repeat('b',64),now()+interval '1 day')`);
    await assert.rejects(db.rest.rpc('redeem_noop_enrollment', {
      p_code_hash: 'b'.repeat(64), p_source_id: SOURCE_A, p_platform: 'ios', p_app_version: '1',
      p_token_hash: sha(tokenOf('legacyb')), p_retry_window_seconds: 300 }), /enrollment_source_already_bound/);
    // Even the owner's own legacy code cannot pull an Auth-bound installation back to code enrollment.
    const codeA = crypto.randomUUID();
    await db.sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${codeA}','${USER_A}',repeat('c',64),now()+interval '1 day')`);
    await assert.rejects(db.rest.rpc('redeem_noop_enrollment', {
      p_code_hash: 'c'.repeat(64), p_source_id: SOURCE_A, p_platform: 'ios', p_app_version: '1',
      p_token_hash: sha(tokenOf('legacya')), p_retry_window_seconds: 300 }), /enrollment_source_already_bound/);
    assert.equal(await db.sql(`select count(*) from noop_ingest_tokens where token_hash='${sha(tokenOf('legacya'))}'`), '0');

    // ---- legacy enrollment-code installations: adopted only by their own account --------------
    const legacySource = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const legacyToken = tokenOf('legacyinstall');
    await db.sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${crypto.randomUUID()}','${USER_C}',repeat('d',64),now()+interval '1 day')`);
    const legacyRedeemed = await db.rest.rpc('redeem_noop_enrollment', {
      p_code_hash: 'd'.repeat(64), p_source_id: legacySource, p_platform: 'ios', p_app_version: '0.9',
      p_token_hash: sha(legacyToken), p_retry_window_seconds: 300 });
    assert.equal((Array.isArray(legacyRedeemed) ? legacyRedeemed[0] : legacyRedeemed).user_id, USER_C);
    assert.equal(await db.sql(`select provisioning_method from noop_ingest_tokens where token_hash='${sha(legacyToken)}'`),
      'enrollment_code');
    // Default posture: a pre-Auth credential is dead without the explicit compatibility switch.
    await assert.rejects(upload(legacyToken), (error: unknown) => (error as { code?: string }).code === 'legacy_enrollment_disabled');
    await assert.rejects(upload(legacyToken, { 'x-noop-fleet-token': 'noop_anything' }),
      (error: unknown) => (error as { code?: string }).code === 'legacy_enrollment_disabled');
    // Another account cannot adopt it, even with the legacy credential in hand.
    const hijack = await call(JWT_A, { ...valid, sourceId: legacySource }, legacyToken);
    assert.equal(hijack.body.code, 'installation_unavailable');
    assert.equal(await db.sql(`select user_id from noop_app_installations where source_id='${legacySource}'`), USER_C);
    // The owner upgrades it in place: same source id, same canonical owner, new Auth-bound credential.
    const upgraded = await call(JWT_C, { ...valid, sourceId: legacySource }, legacyToken);
    assert.equal(upgraded.body.action, 'upgraded');
    assert.equal(upgraded.body.userId, USER_C);
    assert.equal(await db.sql(`select provisioning_method||'|'||coalesce(enrollment_code_id::text,'null')
      from noop_app_installations where source_id='${legacySource}'`), 'supabase_auth|null');
    await assert.rejects(upload(legacyToken), (error: unknown) => (error as { code?: string }).code === 'installation_revoked');
    assert.equal((await upload(upgraded.body.installationToken)).id, USER_C);

    // ---- retirement is permanent and cannot be undone by provisioning ------------------------
    const retired = await lifecycle(new Request('https://x.test/functions/v1/push/installation/retire', {
      method: 'POST', headers: { authorization: `Bearer ${upgraded.body.installationToken}` } }), 'retire');
    assert.equal(retired.status, 200, 'an Auth-provisioned token retires without any fleet credential');
    await assert.rejects(upload(upgraded.body.installationToken), (error: unknown) => (error as { code?: string }).code === 'installation_revoked');
    const afterRetirement = await call(JWT_C, { ...valid, sourceId: legacySource });
    assert.equal(afterRetirement.status, 403);
    assert.equal(afterRetirement.body.code, 'installation_retired');
    assert.equal(afterRetirement.body.installationToken, undefined);
    // The retired source is not reusable by anyone, and the owner simply uses a new source id.
    assert.equal((await call(JWT_B, { ...valid, sourceId: legacySource })).body.code, 'installation_unavailable');
    assert.equal((await call(JWT_C, { ...valid, sourceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' })).body.action, 'created');

    // ---- operator revocation fails closed ---------------------------------------------------
    await db.sql(`update noop_app_installations set revoked_at=now() where source_id='${SOURCE_B}'`);
    await assert.rejects(upload(bToken), (error: unknown) => (error as { code?: string }).code === 'installation_revoked');
    assert.equal((await call(JWT_B, { ...valid, sourceId: SOURCE_B }, bToken)).body.code, 'installation_revoked');

    // ---- deleted account: cascade removes every credential -----------------------------------
    const cToken = (await call(JWT_C, { ...valid, sourceId: 'ffffffff-ffff-4fff-8fff-ffffffffffff' })).body.installationToken;
    assert.equal((await upload(cToken)).id, USER_C);
    await db.sql(`delete from auth.users where id='${USER_C}'`);
    await assert.rejects(upload(cToken), (error: unknown) => (error as { code?: string }).code === 'unauthorized');
    assert.equal(await db.sql(`select count(*) from noop_app_installations where user_id='${USER_C}'`), '0');
    assert.equal(await db.sql(`select count(*) from noop_ingest_tokens where user_id='${USER_C}'`), '0');

    // No plaintext credential, at any point in its life, is persisted anywhere.
    const dump = await db.sql(`select row_to_json(t)::text from noop_ingest_tokens t
      union all select row_to_json(i)::text from noop_app_installations i
      union all select row_to_json(e)::text from noop_installation_provisioning_events e`);
    for (const secret of minted) {
      assert.ok(!dump.includes(secret) && !dump.includes(secret.slice(5)), 'plaintext credential persisted');
    }
  } finally {
    await db.close();
  }
});

Deno.test('Supabase-Auth installation provisioning: shape constraints, grants, limits and RLS', async () => {
  const db = await startLocalPostgres({ installationLifecycle: true, authProvisioning: true });
  try {
    const tokenSql = (kind: string, method: string | null, source: string | null, user: string | null,
      code: string | null, label: string) =>
      `insert into noop_ingest_tokens(user_id,token_hash,label,token_kind,source_id,expires_at,enrollment_code_id,provisioning_method)
       values(${user ? `'${user}'` : 'null'},'${sha(label)}','${label}','${kind}',${source ? `'${source}'` : 'null'},
       now()+interval '1 day',${code ? `'${code}'` : 'null'},${method ? `'${method}'` : 'null'})`;
    await db.sql(`insert into noop_app_installations(source_id,user_id,enrollment_code_id,provisioning_method,platform,app_version)
      values('${SOURCE_A}','${USER_A}',null,'supabase_auth','ios','1')`);

    // Provenance/shape: every combination that is not an explicit, coherent credential is refused.
    await assert.rejects(db.sql(tokenSql('installation', null, SOURCE_A, USER_A, null, 'no-provenance')), /identity_shape_check/);
    await assert.rejects(db.sql(tokenSql('installation', 'enrollment_code', SOURCE_A, USER_A, null, 'code-method-without-code')), /identity_shape_check/);
    await assert.rejects(db.sql(tokenSql('installation', 'bogus', SOURCE_A, USER_A, null, 'bogus-method')), /identity_shape_check/);
    await assert.rejects(db.sql(tokenSql('installation', 'supabase_auth', null, USER_A, null, 'no-source')), /identity_shape_check/);
    await db.sql(tokenSql('fleet', 'supabase_auth', null, null, null, 'fleet-provenance-cleared'));
    assert.equal(await db.sql(`select coalesce(provisioning_method,'null') from noop_ingest_tokens where label='fleet-provenance-cleared'`),
      'null', 'only installation tokens may carry provenance');
    await db.sql(tokenSql('installation', 'supabase_auth', SOURCE_A, USER_A, null, 'valid-auth-token'));
    await assert.rejects(db.sql(tokenSql('installation', 'supabase_auth', SOURCE_A, USER_A, null, 'second-active-token')),
      /noop_ingest_tokens_active_installation_uidx/);
    await assert.rejects(db.sql(`insert into noop_app_installations(source_id,user_id,enrollment_code_id,provisioning_method,platform,app_version)
      values(gen_random_uuid(),'${USER_A}',null,'enrollment_code','ios','1')`), /provisioning_check/);
    await assert.rejects(db.sql(`insert into noop_app_installations(source_id,user_id,enrollment_code_id,provisioning_method,platform,app_version)
      values(gen_random_uuid(),'${USER_A}',gen_random_uuid(),'supabase_auth','ios','1')`), /provisioning_check|foreign key/);

    // Grants: no client role can run the RPC or read credential/audit tables, however it is addressed.
    const rpcArgs = { p_user_id: USER_A, p_source_id: SOURCE_B, p_platform: 'ios', p_app_version: '1',
      p_new_token_hash: sha('x') };
    for (const role of ['anon', 'authenticated']) {
      const denied = await db.request('rpc/provision_noop_installation', role, USER_A, 'POST', rpcArgs);
      assert.ok([401, 403].includes(denied.status), `${role} executed provisioning: ${JSON.stringify(denied)}`);
      for (const table of ['noop_ingest_tokens', 'noop_app_installations', 'noop_installation_provisioning_events']) {
        const read = await db.request(`${table}?select=*`, role, USER_A);
        assert.ok(read.status === 401 || read.status === 403 || (read.status === 200 && read.body.length === 0),
          `${role} could read ${table}: ${JSON.stringify(read)}`);
      }
    }
    assert.equal(await db.sql(`select count(*) from noop_app_installations where source_id='${SOURCE_B}'`), '0');
    // Even service_role must name a principal itself: the function refuses non-service callers outright.
    await assert.rejects(db.sql(`select public.provision_noop_installation('${USER_A}','${SOURCE_B}','ios','1','${sha('y')}')`),
      /provision_service_role_required/);

    // Input validation inside the function is independent of the Edge validation.
    for (const [override, message] of [
      [{ p_new_token_hash: 'short' }, /provision_hash_invalid/],
      [{ p_new_token_hash: 'G'.repeat(64) }, /provision_hash_invalid/],
      [{ p_current_token_hash: 'nothex' }, /provision_hash_invalid/],
      [{ p_platform: 'windows' }, /provision_platform_invalid/],
      [{ p_app_version: '' }, /provision_app_version_invalid/],
      [{ p_app_version: 'v'.repeat(65) }, /provision_app_version_invalid/],
      [{ p_ttl_seconds: 10 }, /provision_ttl_invalid/],
      [{ p_user_id: null }, /provision_identity_invalid/],
    ] as Array<[Record<string, unknown>, RegExp]>) {
      await assert.rejects(db.rest.rpc('provision_noop_installation', { ...rpcArgs, ...override }), message);
    }
    assert.equal(await db.sql(`select count(*) from noop_app_installations where source_id='${SOURCE_B}'`), '0');

    // Rate limit: credential-changing calls are capped per account per hour.
    await db.sql(`insert into auth.users(id) values('${USER_C}')`);
    for (let n = 0; n < 20; n++) {
      const result = await db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_C,
        p_source_id: crypto.randomUUID(), p_new_token_hash: sha(`rate${n}`) });
      assert.equal(result.action, 'created');
    }
    await assert.rejects(db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_C,
      p_source_id: crypto.randomUUID(), p_new_token_hash: sha('rate-over') }), /provision_rate_limited/);
    await assert.rejects(db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_C,
      p_source_id: SOURCE_B, p_new_token_hash: sha('rate-over-2') }), /provision_rate_limited/);
    // The limit is per account: another user is not affected.
    assert.equal((await db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_B,
      p_source_id: SOURCE_B, p_new_token_hash: sha('other-user') })).action, 'created');
    // Reuse of a live credential never consumes the budget.
    const live = await db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_B,
      p_source_id: SOURCE_B, p_new_token_hash: sha('unused'), p_current_token_hash: sha('other-user') });
    assert.equal(live.action, 'reused');

    // Installation cap per account.
    await db.sql(`insert into noop_app_installations(source_id,user_id,enrollment_code_id,provisioning_method,platform,app_version)
      select gen_random_uuid(),'${USER_B}',null,'supabase_auth','ios','1' from generate_series(1,24)`);
    await assert.rejects(db.rest.rpc('provision_noop_installation', { ...rpcArgs, p_user_id: USER_B,
      p_source_id: crypto.randomUUID(), p_new_token_hash: sha('cap') }), /installation_limit/);

    // Provisioning audit rows are append-only evidence tied to their installation.
    assert.equal(await db.sql(`select count(*) from noop_installation_provisioning_events where user_id='${USER_C}'`), '20');
    assert.equal(await db.sql(`select count(distinct action) from noop_installation_provisioning_events`), '1');
  } finally {
    await db.close();
  }
});
