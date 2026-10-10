// Account sync health (20261009110000_account_sync_health.sql) on the production Postgres image through the full
// ordered migration chain, with real PostgREST role switching. Docker-gated like auth_isolation_sql_test.ts (same
// environment, run after `pipeline_db.sh reset`):
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   EDGE_TEST_ARTIFACTS=/tmp/edgeart deno test -A --no-lock tests/account_sync_health_sql_test.ts
//
// What it proves:
//  1. catalogue: both functions SECURITY DEFINER with an empty search_path and a comment; the fleet function is
//     executable by service_role only, the caller's own by authenticated only (never anon); a fresh create under
//     the image's default privileges (which grant EXECUTE to anon and authenticated) and a re-apply both keep it so;
//  2. account_sync_health_v1 lists exactly the confirmed, undeleted, unretired accounts with their newest accepted
//     upload, live (not revoked, not retired) installations, never_uploaded, stale and silent, honours p_user_id and
//     p_stale_after_hours, and refuses hours outside 1..720;
//  3. through PostgREST, anon and a signed-in caller cannot run it; my_sync_health_v1 answers each caller with its
//     own single row (two accounts), refuses anon and a token without a subject, and takes no owner argument;
//  4. the real provisioning handler and coach status on this database: provisioning carries syncPolicy, and GET
//     status reports the account's own sync health from the RPC.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { createInstallationProvisioning } from '../_shared/provisioning.ts';
import { coachConfig, handleCoachRequest } from '../_shared/coach.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';
const MIGRATION = '20261009110000_account_sync_health.sql';
const EMAIL_PREFIX = 'synchealth-';
const decoder = new TextDecoder();

async function psql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const result = await child.output();
  return { ok: result.code === 0, out: decoder.decode(result.stdout).trim(), err: decoder.decode(result.stderr) };
}
async function sql(text: string) {
  const result = await psql(text);
  assert.ok(result.ok, result.err);
  return result.out;
}
const sqlJson = async (text: string) => JSON.parse((await sql(text)) || 'null');
async function sqlFails(text: string, pattern: RegExp) {
  const result = await psql(text);
  assert.ok(!result.ok, `expected a failure matching ${pattern}, got ${result.out}`);
  assert.match(result.err, pattern);
}

function b64url(value: string) {
  return btoa(value).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
}
function signJwt(role: string, sub?: string) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ role, sub, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 }));
  return `${header}.${body}.${createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url')}`;
}
interface Reply { status: number; body: any }
async function rpcAs(token: string | null, name: string, args: Record<string, unknown> = {}): Promise<Reply> {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: 'POST',
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), 'content-type': 'application/json' },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let body: any = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: response.status, body };
}
const refused = (reply: Reply) => [401, 403].includes(reply.status);
const ms = (value: string | null) => (value == null ? null : Date.parse(value));

const serviceRest = createSupabaseRest({
  cfg: { supabaseUrl: restUrl ?? 'http://127.0.0.1:0', supabaseServiceRoleKey: signJwt('service_role') },
  fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(15000) }),
});

/** An account with its own device; `confirmed: false` leaves email_confirmed_at NULL. */
async function account({ confirmed = true, deleted = false } = {}) {
  const user = crypto.randomUUID();
  const device = crypto.randomUUID();
  await sql(`
    insert into auth.users(id, email, email_confirmed_at, deleted_at)
      values ('${user}', '${EMAIL_PREFIX}${user}@example.test', ${confirmed ? 'now()' : 'null'}, ${deleted ? 'now()' : 'null'});
    insert into public.devices(id, user_id, source_kind, external_device_id)
      values ('${device}', '${user}', 'noop_push', 'sync-${device}');`);
  return { user, device };
}
/** A provisioned installation: live, revoked, or retired (retired is revoked too, as retirement leaves it). */
async function installation(user: string, state: 'live' | 'revoked' | 'retired' = 'live') {
  const source = crypto.randomUUID();
  const ended = state === 'live' ? 'null' : 'now()';
  await sql(`insert into public.noop_app_installations(source_id, user_id, enrollment_code_id, provisioning_method,
      platform, app_version, revoked_at, retired_at, retirement_id)
    values ('${source}', '${user}', null, 'supabase_auth', 'ios', 'fixture', ${ended},
      ${state === 'retired' ? 'now()' : 'null'}, ${state === 'retired' ? 'gen_random_uuid()' : 'null'})`);
  return source;
}
/** An accepted upload `hoursAgo` hours before now(); returns its accepted_at as the database renders it. */
async function receipt(user: string, device: string, source: string | null, hoursAgo: number) {
  return await sqlJson(`insert into public.noop_upload_receipts(id, user_id, source_id, device_id, auth_mode, lane, stream,
      batch_id, body_sha256, accepted_status, accepted_rows, accepted_at)
    values (gen_random_uuid(), '${user}', ${source ? `'${source}'` : 'null'}, '${device}', 'installation', 'inline',
      'hrSample', gen_random_uuid(), repeat('a', 64), 'accepted', 1, now() - make_interval(hours => ${hoursAgo}))
    returning to_json(accepted_at)`) as string;
}
/** account_sync_health_v1 rows for the given users, as postgres (the function's owner) sees them. */
async function health(users: string[], hours = 24) {
  const rows: any[] = await sqlJson(`select coalesce(json_agg(h order by h.user_id), '[]')
    from public.account_sync_health_v1(${hours}) h where h.user_id in (${users.map((u) => `'${u}'`).join(',')})`);
  return Object.fromEntries(rows.map((row) => [row.user_id, row]));
}

Deno.test({
  name: 'account sync health: catalogue, fleet and own-account reads, isolation and the coach status route',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    assert.equal(new URL(restUrl!).hostname, '127.0.0.1');
    for (let attempt = 0; ; attempt++) {
      try {
        await serviceRest.select('devices', 'select=id&limit=1');
        break;
      } catch (error) {
        if (attempt === 59) throw error;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }
    await sql(`delete from public.noop_account_retirements r using auth.users u
        where u.id = r.user_id and u.email like '${EMAIL_PREFIX}%';
      delete from auth.users where email like '${EMAIL_PREFIX}%'`);

    const catalogue = () => sqlJson(`select json_object_agg(p.proname, json_build_object(
        'definer', p.prosecdef, 'config', p.proconfig, 'volatile', p.provolatile,
        'anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
        'authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
        'service', has_function_privilege('service_role', p.oid, 'EXECUTE'),
        'public', exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                          where a.grantee = 0 and a.privilege_type = 'EXECUTE'),
        'comment', obj_description(p.oid, 'pg_proc') is not null))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('account_sync_health_v1', 'my_sync_health_v1')`);
    const assertCatalogue = async (label: string) => {
      const fns = await catalogue();
      assert.deepEqual(Object.keys(fns ?? {}).sort(), ['account_sync_health_v1', 'my_sync_health_v1'], label);
      for (const [name, fn] of Object.entries<any>(fns)) {
        assert.equal(fn.definer, true, `${label}: ${name} SECURITY DEFINER`);
        assert.deepEqual(fn.config, ['search_path=""'], `${label}: ${name} search_path`);
        assert.equal(fn.volatile, 's', `${label}: ${name} is STABLE (read-only)`);
        assert.equal(fn.anon, false, `${label}: ${name} anon`);
        assert.equal(fn.public, false, `${label}: ${name} PUBLIC`);
        assert.equal(fn.comment, true, `${label}: ${name} comment`);
      }
      assert.deepEqual([fns.account_sync_health_v1.authenticated, fns.account_sync_health_v1.service], [false, true], label);
      assert.equal(fns.my_sync_health_v1.authenticated, true, label);
    };
    const migration = decodeURIComponent(new URL(`../../migrations/${MIGRATION}`, import.meta.url).pathname);
    const apply = async () => sql(await Deno.readTextFile(migration));

    await t.step('catalogue: definer, empty search_path, comments, and the grants hold on create and re-apply', async () => {
      await assertCatalogue('as migrated');
      // A fresh create gets the image's default privileges (EXECUTE for anon and authenticated); the revokes must win.
      const defaults = await sql(`select count(*) from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a
        where d.defaclobjtype = 'f' and a.grantee = 'anon'::regrole and a.privilege_type = 'EXECUTE'`);
      assert.ok(Number(defaults) > 0, 'the image no longer grants EXECUTE on new functions to anon; the fresh-create check proves nothing');
      await sql(`drop function public.my_sync_health_v1(integer); drop function public.account_sync_health_v1(integer, uuid);`);
      await apply();
      await assertCatalogue('fresh create');
      await apply();
      await assertCatalogue('re-applied');
    });

    const a = await account(), b = await account(), c = await account(), g = await account();
    const unconfirmed = await account({ confirmed: false });
    const deleted = await account({ deleted: true });
    const retired = await account();
    const sa = await installation(a.user);
    await installation(a.user, 'revoked');
    await installation(a.user, 'retired');
    const sb = await installation(b.user);
    await installation(g.user);
    const su = await installation(unconfirmed.user);
    await receipt(a.user, a.device, sa, 72);
    const aLatest = await receipt(a.user, a.device, sa, 1);
    await receipt(a.user, a.device, null, 50);
    const bLatest = await receipt(b.user, b.device, sb, 30);
    await receipt(unconfirmed.user, unconfirmed.device, su, 2);
    await receipt(deleted.user, deleted.device, null, 2);
    await receipt(retired.user, retired.device, null, 2);
    await sql(`insert into public.noop_account_retirements(user_id) values ('${retired.user}')`);
    const everyone = [a, b, c, g, unconfirmed, deleted, retired].map((x) => x.user);

    await t.step('account_sync_health_v1: confirmed live accounts, newest upload, stale, never uploaded, silent', async () => {
      const rows = await health(everyone);
      assert.deepEqual(Object.keys(rows).sort(), [a.user, b.user, c.user, g.user].sort(),
        'unconfirmed, Auth-deleted and retired accounts are not listed');
      const shape = (row: any) => [row.live_installations, ms(row.last_upload_at), row.never_uploaded, row.stale, row.silent];
      assert.deepEqual(shape(rows[a.user]), [1, ms(aLatest), false, false, false], 'one live of three; the newest of three receipts');
      assert.deepEqual(shape(rows[b.user]), [1, ms(bLatest), false, true, true], '30 h ago is stale at 24 h');
      assert.deepEqual(shape(rows[c.user]), [0, null, true, true, true], 'no installation, never uploaded');
      assert.deepEqual(shape(rows[g.user]), [1, null, true, true, true], 'linked but never uploaded is stale');
      assert.deepEqual(Object.keys(rows[a.user]).sort(),
        ['last_upload_at', 'live_installations', 'never_uploaded', 'silent', 'stale', 'user_id']);

      const relaxed = await health(everyone, 48);
      assert.deepEqual([relaxed[b.user].stale, relaxed[b.user].silent], [false, false], '30 h ago is fresh at 48 h');
      assert.deepEqual([relaxed[c.user].stale, relaxed[g.user].stale], [true, true], 'never uploaded is always stale');
      const strict = await health(everyone, 1);
      assert.equal(strict[a.user].stale, true, '1 h ago is stale at 1 h');

      // p_user_id narrows to that account; an excluded account gives nothing, even asked for by id.
      const only: any[] = await sqlJson(`select json_agg(h) from public.account_sync_health_v1(24, '${b.user}') h`);
      assert.deepEqual(only.map((row) => row.user_id), [b.user]);
      for (const user of [unconfirmed.user, deleted.user, retired.user, crypto.randomUUID()]) {
        assert.equal(await sql(`select count(*) from public.account_sync_health_v1(24, '${user}')`), '0', user);
      }
      // Bounds on the window.
      for (const hours of ['0', '721', '-1', 'null']) {
        await sqlFails(`select * from public.account_sync_health_v1(${hours})`, /sync_stale_hours_invalid/);
        await sqlFails(`select * from public.account_sync_health_v1(${hours}, '${a.user}')`, /sync_stale_hours_invalid/);
      }
      assert.equal(await sql(`select count(*) from public.account_sync_health_v1(720, '${a.user}')`), '1');
    });

    await t.step('service role through PostgREST: the coach route\'s exact call', async () => {
      const rows = await serviceRest.rpc('account_sync_health_v1', { p_stale_after_hours: 24, p_user_id: a.user });
      assert.equal(rows.length, 1);
      assert.deepEqual([rows[0].user_id, ms(rows[0].last_upload_at), rows[0].stale], [a.user, ms(aLatest), false]);
      const fleet = await serviceRest.rpc('account_sync_health_v1', { p_stale_after_hours: 24 });
      const mine = fleet.filter((row: any) => everyone.includes(row.user_id)).map((row: any) => row.user_id).sort();
      assert.deepEqual(mine, [a.user, b.user, c.user, g.user].sort());
      await assert.rejects(() => serviceRest.rpc('account_sync_health_v1', { p_stale_after_hours: 0, p_user_id: a.user }));
    });

    await t.step('clients cannot run the fleet function; each caller reads only its own row', async () => {
      const jwtA = signJwt('authenticated', a.user), jwtB = signJwt('authenticated', b.user);
      for (const token of [null, jwtA, signJwt('anon')]) {
        for (const args of [{}, { p_stale_after_hours: 24 }, { p_stale_after_hours: 24, p_user_id: a.user }]) {
          const reply = await rpcAs(token, 'account_sync_health_v1', args);
          assert.ok(refused(reply), `${token ? 'signed-in' : 'anon'} ran account_sync_health_v1: ${reply.status} ${JSON.stringify(reply.body)}`);
        }
      }

      const own = async (token: string, args: Record<string, unknown> = {}) => {
        const reply = await rpcAs(token, 'my_sync_health_v1', args);
        assert.equal(reply.status, 200, JSON.stringify(reply.body));
        assert.equal(reply.body.length, 1, 'always exactly one row');
        assert.deepEqual(Object.keys(reply.body[0]).sort(), ['last_upload_at', 'live_installations', 'stale']);
        return reply.body[0];
      };
      const mineA = await own(jwtA);
      const mineB = await own(jwtB);
      assert.deepEqual([ms(mineA.last_upload_at), mineA.stale, mineA.live_installations], [ms(aLatest), false, 1]);
      assert.deepEqual([ms(mineB.last_upload_at), mineB.stale, mineB.live_installations], [ms(bLatest), true, 1]);
      assert.equal((await own(jwtB, { p_stale_after_hours: 48 })).stale, false);
      assert.deepEqual(await own(signJwt('authenticated', c.user)), { last_upload_at: null, stale: true, live_installations: 0 });
      // The caller's own row does not depend on the fleet listing's filters.
      const mineUnconfirmed = await own(signJwt('authenticated', unconfirmed.user));
      assert.deepEqual([mineUnconfirmed.stale, mineUnconfirmed.live_installations], [false, 1]);

      // No owner argument exists to point at someone else; PostgREST cannot find such an overload.
      const smuggled = await rpcAs(jwtA, 'my_sync_health_v1', { p_stale_after_hours: 24, p_user_id: b.user });
      assert.ok(smuggled.status >= 400, `an owner argument was accepted: ${smuggled.status}`);
      for (const hours of [0, 721]) {
        assert.equal((await rpcAs(jwtA, 'my_sync_health_v1', { p_stale_after_hours: hours })).status, 400);
      }
      assert.ok(refused(await rpcAs(null, 'my_sync_health_v1')), 'anon');
      assert.ok(refused(await rpcAs(signJwt('anon'), 'my_sync_health_v1')), 'anon token');
      const noSubject = await rpcAs(signJwt('authenticated'), 'my_sync_health_v1');
      assert.ok(refused(noSubject), `a signed-in role without a subject: ${noSubject.status}`);
      assert.match(JSON.stringify(noSubject.body), /authentication_required/);
    });

    await t.step('the real provisioning handler and coach status carry the policy and the account\'s own health', async () => {
      const h = await account();
      const jwtH = signJwt('authenticated', h.user);
      const goTrue: typeof fetch = (input, init) => {
        assert.ok(String(input).endsWith('/auth/v1/user'));
        const bearer = String(new Headers(init?.headers).get('authorization') ?? '').replace(/^Bearer /, '');
        return Promise.resolve(bearer === jwtH
          ? Response.json({ id: h.user, email: `${EMAIL_PREFIX}${h.user}@example.test`, email_confirmed_at: '2026-10-09T00:00:00Z', is_anonymous: false })
          : Response.json({ error_code: 'bad_jwt' }, { status: 403 }));
      };
      const provision = createInstallationProvisioning({
        rest: serviceRest, supabaseUrl: 'https://project.test', anonKey: 'sb_publishable_test', fetchImpl: goTrue,
        syncPolicy: { required: true, staleAfterHours: 6 },
      });
      const source = crypto.randomUUID();
      const provisioned = await provision(new Request('https://x.test/functions/v1/push/installations/provision', {
        method: 'POST', headers: { authorization: `Bearer ${jwtH}`, 'content-type': 'application/json' },
        body: JSON.stringify({ sourceId: source, platform: 'ios', appVersion: '1.0 (1)' }),
      }));
      const reply = await provisioned.json();
      assert.equal(provisioned.status, 201, JSON.stringify(reply));
      assert.deepEqual(reply.syncPolicy, { required: true, staleAfterHours: 6 });

      const status = async (env: Record<string, string>) => {
        const response = await handleCoachRequest(new Request('https://x.test/functions/v1/coach/status', {
          headers: { authorization: `Bearer ${reply.installationToken}` },
        }), { rest: serviceRest, cfg: coachConfig({ FIREWORKS_AI_API_KEY: 'k', ...env }) });
        assert.equal(response.status, 200);
        return await response.json();
      };
      const fresh = await status({});
      assert.deepEqual(fresh.syncPolicy, { required: true, staleAfterHours: 24 });
      assert.deepEqual(fresh.sync, { required: true, lastUploadAt: null, stale: true, staleAfterHours: 24 }, 'never uploaded');

      const uploaded = await receipt(h.user, h.device, source, 2);
      const recent = await status({});
      assert.deepEqual(recent.sync, { required: true, lastUploadAt: new Date(ms(uploaded)!).toISOString(), stale: false, staleAfterHours: 24 });
      const tight = await status({ NOOP_SYNC_STALE_AFTER_HOURS: '1' });
      assert.deepEqual([tight.syncPolicy.staleAfterHours, tight.sync.stale], [1, true]);
      const relaxed = await status({ NOOP_SYNC_REQUIRED: 'off', NOOP_SYNC_STALE_AFTER_HOURS: '1' });
      assert.deepEqual(relaxed.syncPolicy, { required: false, staleAfterHours: 1 });
      assert.deepEqual([relaxed.sync.required, relaxed.sync.stale], [false, false], 'not required is never stale');
    });

    await sql(`delete from public.noop_account_retirements where user_id = '${retired.user}';
      delete from auth.users where email like '${EMAIL_PREFIX}%'`);
  },
});
