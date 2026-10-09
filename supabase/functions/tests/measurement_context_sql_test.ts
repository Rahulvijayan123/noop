// The per-minute measurement context on the production Postgres image with the full migration chain: runs
// supabase/tests/measurement_context_minutes.sql (rule exercise-session-2 parity with
// contracts/reference/exercise-session-2.json, a synthetic day built from raw rows, active periods / other_movement /
// a growing period in the builder, idempotence, backfill, the pg_cron path, RLS between two owners) inside the
// pipeline container. Docker-gated like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/measurement_context_sql_test.ts
//
// The SQL files run in one transaction that they roll back. The route test drives the real scores handler against
// PostgREST with the service role (only the credential lookups are stubbed), so the RPCs run as production runs them,
// safeupdate included; it deletes its synthetic owner afterwards.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';

async function runSqlFile(file: URL, vars: Record<string, string>, appName: string) {
  const args = ['exec', '-e', `PGAPPNAME=${appName}`, '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres',
    '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'];
  for (const [k, v] of Object.entries(vars)) args.push('-v', `${k}=${v}`);
  const child = new Deno.Command('docker', { args, stdin: 'piped', stdout: 'piped', stderr: 'piped' }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(await Deno.readFile(file));
  await writer.close();
  const out = await child.output();
  return { code: out.code, stdout: new TextDecoder().decode(out.stdout), stderr: new TextDecoder().decode(out.stderr) };
}

Deno.test({
  name: 'measurement context minutes: exercise-session-2 parity, synthetic day, idempotence, backfill, cron, RLS',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const fixture = await Deno.readTextFile(new URL('../../../contracts/reference/exercise-session-2.json', import.meta.url));
    const run = await runSqlFile(new URL('../../tests/measurement_context_minutes.sql', import.meta.url), { fixture },
      'measurement-context-minutes');
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /measurement_context_minutes: ok/);
  },
});

Deno.test({
  name: 'measurement context minutes: the quality-minutes RPC re-derives quality (SQL)',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = await runSqlFile(new URL('../../tests/measurement_context_quality_minutes.sql', import.meta.url), {},
      'measurement-context-quality');
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /measurement_context_quality_minutes: ok/);
  },
});

function b64url(value: string) {
  return btoa(value).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
}
function signJwt(role: string) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ role, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 }));
  return `${header}.${body}.${createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url')}`;
}
async function psql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const out = await child.output();
  assert.equal(out.code, 0, new TextDecoder().decode(out.stderr));
  return new TextDecoder().decode(out.stdout).trim();
}

Deno.test({
  name: 'measurement context minutes: POST quality-minutes and GET context-minutes through PostgREST',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const user = crypto.randomUUID();
    const device = crypto.randomUUID();
    const other = crypto.randomUUID();
    const source = crypto.randomUUID();
    const t0 = Date.UTC(2026, 8, 17, 9, 0, 0) / 1000;
    await psql(`
      insert into auth.users (id) values ('${user}'), ('${other}');
      delete from public.scoring_timezone_history where user_id = '${user}';
      insert into public.scoring_timezone_history values ('${user}', '-infinity', 'America/Los_Angeles', 'initial_profile');
      insert into public.devices (id, user_id, source_kind) values ('${device}', '${user}', 'noop_push');
      insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
        select '${user}', '${device}', '${source}', t, 61, '${source}' from generate_series(${t0}, ${t0 + 1799}) t;`);
    try {
      const service = createSupabaseRest({
        cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
        fetchImpl: (input, init) =>
          fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(30000) }),
      });
      // Only the credential and device lookups are stubbed: the RPCs are the database's.
      const rest = {
        ...service,
        configured: true,
        select: async (table: string, query: string) => {
          if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_mc-token'))
            ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: user,
              source_id: source }]
            : [{ id: 'fleet', token_kind: 'fleet' }];
          if (table === 'noop_app_installations') return [{ user_id: user, source_id: source }];
          if (table === 'devices') return query.includes(`user_id=eq.${user}`) ? [{ id: device }] : [];
          return [];
        },
      } as any;
      const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
      const headers = { authorization: 'Bearer noop_mc-token', 'x-noop-fleet-token': 'noop_fleet',
        'content-type': 'application/json' };
      const body = { device_id: 'whoop-MGB0000001', version: 'phone-quality-1', minutes: [
        { minute_start: t0 + 300, v18_n: 60, sentinel_n: 1, baseline_max: 30, record_gap: null, hr_grade: 'good',
          beats_grade: 'good', reasons: [] },
        { minute_start: t0 + 360, v18_n: 60, sentinel_n: 48, baseline_max: 120, hr_grade: 'poor', beats_grade: 'poor',
          reasons: ['motion_mode_optics'] },
        { minute_start: t0 + 1800, record_gap: 'paused', reasons: ['strap_not_recording'] },
      ] };
      const post = () => handleScoresRequest(new Request('https://example.test/functions/v1/scores/quality-minutes',
        { method: 'POST', headers, body: JSON.stringify(body) }), { rest, cfg });
      let res = await post();
      assert.equal(res.status, 200, await res.clone().text());
      assert.deepEqual(await res.json(), { accepted: 3, changed: 3 });
      res = await post();
      assert.deepEqual(await res.json(), { accepted: 3, changed: 0 }, 'a replay changes nothing');

      res = await handleScoresRequest(new Request(
        `https://example.test/functions/v1/scores/context-minutes?deviceId=whoop-MGB0000001&from=${t0}&to=${t0 + 1860}`,
        { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      const read = await res.json();
      const byMinute = new Map(read.rows.map((r: any) => [r.minute_start, r]));
      const good: any = byMinute.get(t0 + 300);
      assert.equal(good.quality_class, 'good');
      assert.equal(good.hr_grade, 'good');
      assert.equal(good.v18_n, 60);
      assert.equal(good.device_id, device);
      assert.equal(good.user_id, undefined, 'no owner id in the payload');
      const poor: any = byMinute.get(t0 + 360);
      assert.equal(poor.quality_class, 'poor');
      assert.deepEqual(poor.reasons, [{ code: 'motion_artifact', certainty: 'inferred', effect: 'degraded', family: 'motion' }]);
      const paused: any = byMinute.get(t0 + 1800);
      assert.equal(paused.quality_class, 'off_wrist');
      assert.deepEqual(paused.missing_reasons[0],
        { code: 'strap_not_recording', certainty: 'confirmed', effect: 'excluded', family: 'link' });
      assert.equal(read.truncated, false);
      assert.ok(read.versions[String(good.context_version)], 'versions resolve every row');

      res = await handleScoresRequest(new Request('https://example.test/functions/v1/scores/quality-minutes',
        { method: 'POST', headers, body: JSON.stringify({ ...body, minutes: [{ minute_start: t0 + 30 }] }) }), { rest, cfg });
      assert.equal(res.status, 400);
      assert.equal((await res.json()).error, 'invalid_minute');
      assert.equal(await psql(`select count(*) from public.measurement_context_minutes where user_id = '${other}'`), '0');
    } finally {
      await psql(`delete from auth.users where id in ('${user}', '${other}');`);
    }
  },
});
