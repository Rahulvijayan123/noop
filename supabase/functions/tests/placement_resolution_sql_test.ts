// Strap placement resolution (20261009150100) on the production Postgres image with the full migration chain: runs
// supabase/tests/placement_device_resolution.sql (bound devices, the resolved timeline, the route read, physiology
// context fingerprint and invalidation, the measurement-context builder) inside the pipeline container, then drives
// GET scores/placement?deviceId= through PostgREST with the service role (only the credential lookups are stubbed).
// Docker-gated like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/placement_resolution_sql_test.ts
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';

async function docker(args: string[], stdin: Uint8Array) {
  const child = new Deno.Command('docker', { args, stdin: 'piped', stdout: 'piped', stderr: 'piped' }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(stdin);
  await writer.close();
  const out = await child.output();
  return { code: out.code, stdout: new TextDecoder().decode(out.stdout), stderr: new TextDecoder().decode(out.stderr) };
}

async function psql(text: string) {
  const out = await docker(['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v',
    'ON_ERROR_STOP=1'], new TextEncoder().encode(text));
  assert.equal(out.code, 0, out.stderr);
  return out.stdout.trim();
}

function b64url(value: string) {
  return btoa(value).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
}
function signJwt(role: string) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ role, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 }));
  return `${header}.${body}.${createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url')}`;
}

Deno.test({
  name: 'placement resolution: bound devices, timeline, fingerprint, invalidation, builder (SQL)',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = await docker(['exec', '-e', 'PGAPPNAME=placement-device-resolution', '-i', container!, 'psql', '-U',
      'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
      await Deno.readFile(new URL('../../tests/placement_device_resolution.sql', import.meta.url)));
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /placement_device_resolution: ok/);
  },
});

Deno.test({
  name: 'placement resolution: GET scores/placement?deviceId= through PostgREST',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const user = crypto.randomUUID();
    const strap = crypto.randomUUID();
    const installationDevice = crypto.randomUUID();
    const source = crypto.randomUUID();
    await psql(`
      insert into auth.users (id) values ('${user}');
      insert into public.noop_app_installations (source_id, user_id, platform, app_version, provisioning_method)
        values ('${source}', '${user}', 'ios', '1.0', 'supabase_auth');
      insert into public.devices (id, user_id, source_kind, external_device_id) values
        ('${strap}', '${user}', 'noop_push', 'whoop-MGB0000007'),
        ('${installationDevice}', '${user}', 'noop_push', 'installation:${source}:my-whoop');
      insert into public.noop_upload_receipts (id, user_id, source_id, device_id, auth_mode, lane, stream, batch_id,
                                               body_sha256, accepted_status, accepted_at)
        values (gen_random_uuid(), '${user}', '${source}', '${strap}', 'installation', 'inline', 'hr',
                gen_random_uuid(), repeat('b', 64), 'accepted', '2026-10-05 00:00:00+00');
      select public.set_placement_interval('${user}', 'bicep', '2026-10-04 21:49:41+00', '${installationDevice}');`);
    try {
      const service = createSupabaseRest({
        cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
        fetchImpl: (input, init) =>
          fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(30000) }),
      });
      // Only the credential lookups are stubbed; devices, aliases and placement rows are the database's.
      const rest = {
        ...service,
        configured: true,
        select: async (table: string, query: string) => {
          if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_pl-token'))
            ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: user,
              source_id: source }]
            : [{ id: 'fleet', token_kind: 'fleet' }];
          if (table === 'noop_app_installations') return [{ user_id: user, source_id: source }];
          return service.select(table, query);
        },
      } as any;
      const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon' };
      const headers = { authorization: 'Bearer noop_pl-token' };
      let res = await handleScoresRequest(new Request(
        'https://example.test/functions/v1/scores/placement?deviceId=whoop-MGB0000007', { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      const body = await res.json();
      // The owner's rows exactly as before (the declaration sits on the installation device, under its external id).
      assert.equal(body.intervals.length, 1);
      assert.equal(body.intervals[0].device_id, `installation:${source}:my-whoop`);
      // And the strap's resolved placement: the installation's bicep, unsupported for wrist-trained models.
      assert.equal(body.resolved.device_id, 'whoop-MGB0000007');
      assert.equal(body.resolved.intervals.length, 1);
      const piece = body.resolved.intervals[0];
      assert.equal(piece.placement, 'bicep');
      assert.equal(piece.scope, 'device');
      assert.equal(piece.basis, 'installation');
      assert.equal(piece.declared_device_id, `installation:${source}:my-whoop`);
      assert.equal(piece.effective_end, null);
      assert.equal(new Date(piece.effective_start).getTime(), Date.parse('2026-10-04T21:49:41Z'));
      assert.deepEqual(piece.wrist_model_reason, { code: 'placement_unsupported', certainty: 'confirmed' });

      // The phone's local id resolves to its installation device, which carries the declaration itself.
      res = await handleScoresRequest(new Request(
        'https://example.test/functions/v1/scores/placement?deviceId=my-whoop', { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      assert.equal((await res.json()).resolved.intervals[0].basis, 'strap');
      // Without deviceId the response is what it always was.
      res = await handleScoresRequest(new Request('https://example.test/functions/v1/scores/placement', { headers }),
        { rest, cfg });
      assert.equal('resolved' in await res.json(), false);
    } finally {
      await psql(`delete from auth.users where id = '${user}';`);
    }
  },
});

Deno.test({
  name: 'placement resolution: deploy/placement-rescope-strap.sql dry run, apply, copy',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const user = crypto.randomUUID();
    const strap = crypto.randomUUID();
    const first = crypto.randomUUID();
    const second = crypto.randomUUID();
    const s1 = crypto.randomUUID();
    const s2 = crypto.randomUUID();
    const today = new Date().toISOString().slice(0, 10);
    const dayBefore = new Date(Date.now() - 2 * 86_400_000).toISOString().slice(0, 10);
    // The owner's shape: bicep declared on two installation devices, data (and derived jobs) on the strap.
    await psql(`
      insert into auth.users (id) values ('${user}');
      insert into public.devices (id, user_id, source_kind, external_device_id) values
        ('${strap}', '${user}', 'noop_push', 'whoop-MGB0000005'),
        ('${first}', '${user}', 'noop_push', 'installation:${s1}:my-whoop'),
        ('${second}', '${user}', 'noop_push', 'installation:${s2}:my-whoop');
      insert into public.noop_upload_receipts (id, user_id, source_id, device_id, auth_mode, lane, stream, batch_id,
                                               body_sha256, accepted_status, accepted_at)
      values (gen_random_uuid(), '${user}', '${s1}', '${strap}', 'installation', 'inline', 'hr', gen_random_uuid(),
              repeat('e', 64), 'accepted', '${dayBefore} 01:00:00+00'),
             (gen_random_uuid(), '${user}', '${s2}', '${strap}', 'installation', 'inline', 'hr', gen_random_uuid(),
              repeat('e', 64), 'accepted', '${today} 00:30:00+00');
      insert into public.placement_intervals (owner, device_id, placement, effective_start, source, revision) values
        ('${user}', '${first}', 'bicep', '${dayBefore} 00:00:00+00', 'user', 1),
        ('${user}', '${second}', 'bicep', '${today} 00:10:00+00', 'user', 2);
      select internal.physiology_context_touch('${user}', '${strap}', '${dayBefore}', 'retrospective', 'scoring', null);
      insert into public.sensor_biomarker_jobs (user_id, device_id, day, fingerprint, input_revision, completed_revision)
        values ('${user}', '${strap}', '${dayBefore}', repeat('f', 64), 1, 1);`);
    const script = await Deno.readFile(new URL('../../../deploy/placement-rescope-strap.sql', import.meta.url));
    const run = (vars: string[]) => docker(['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X',
      '-v', 'ON_ERROR_STOP=1', '-v', `owner=${user}`, ...vars.flatMap((v) => ['-v', v])], script);
    const state = () => psql(`
      select (select input_revision from public.physiology_context_jobs where user_id = '${user}'
                and device_id = '${strap}' and day = '${dayBefore}' and mode = 'retrospective') || ':' ||
             (select input_revision from public.sensor_biomarker_jobs where user_id = '${user}'
                and device_id = '${strap}' and day = '${dayBefore}') || ':' ||
             (select count(*) from public.placement_intervals where owner = '${user}' and device_id = '${strap}');`);
    try {
      const before = await state();
      assert.equal(before, '1:1:0');
      let out = await run([]);
      assert.equal(out.code, 0, out.stderr);
      assert.match(out.stdout, /installation/);
      assert.match(out.stdout, /dry run: nothing written/);
      assert.equal(await state(), before, 'a dry run writes nothing');
      out = await run(['apply=1']);
      assert.equal(out.code, 0, out.stderr);
      assert.match(out.stdout, /applied/);
      assert.equal(await state(), '2:2:0', 'apply re-queues the strap\'s derived days and writes no placement row');
      out = await run(['apply=1', 'copy=1']);
      assert.equal(out.code, 0, out.stderr);
      const [ctx, sensor, rows] = (await state()).split(':');
      assert.ok(Number(ctx) >= 3 && sensor === '3' && rows === '2', `copy re-declares both pieces on the strap: ${ctx}:${sensor}:${rows}`);
      // The originals are untouched and the resolved placement is the same.
      assert.equal(await psql(`select count(*) from public.placement_intervals where owner = '${user}'
                                  and device_id in ('${first}', '${second}')`), '2');
      assert.equal(await psql(`select string_agg(placement, ',' order by effective_start) from
                                  internal.placement_intervals_for_device_v1('${user}', '${strap}', null, null)`),
        'bicep,bicep');
    } finally {
      await psql(`delete from auth.users where id = '${user}';`);
    }
  },
});
