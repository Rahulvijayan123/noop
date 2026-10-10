// The anomaly windows behind GET scores/anomaly-candidates (20261009150200) on the production Postgres image with the
// full migration chain: runs supabase/tests/anomaly_windows_read.sql inside the pipeline container, then publishes a
// job result through the real publish_anomaly_result_v1 and reads it back through the scores handler against
// PostgREST with the service role (only the credential and device lookups are stubbed). Docker-gated like
// auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/anomaly_windows_sql_test.ts
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
  name: 'anomaly windows: reasons, context mix, range and ownership (SQL)',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = await docker(['exec', '-e', 'PGAPPNAME=anomaly-windows-read', '-i', container!, 'psql', '-U',
      'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
      await Deno.readFile(new URL('../../tests/anomaly_windows_read.sql', import.meta.url)));
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /anomaly_windows_read: ok/);
  },
});

Deno.test({
  name: 'anomaly windows: a published job read back through GET scores/anomaly-candidates',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const user = crypto.randomUUID();
    const device = crypto.randomUUID();
    const source = crypto.randomUUID();
    const token = crypto.randomUUID();
    const t0 = Date.UTC(2026, 9, 7, 21, 0, 0) / 1000;
    const iso = (t: number) => new Date(t * 1000).toISOString();
    const payload = {
      scored_from: iso(t0), scored_to: iso(t0 + 7200), run_ms: 5, worker: 'test',
      candidates: [],
      window_scores: [
        // The service before 20261009140100: no reason fields; publish maps them.
        { window_start: iso(t0), window_end: iso(t0 + 1800), channel_group: 'all', model: 'none', usable: false,
          context_kind: 'rest', withheld_reason: 'activity' },
        { window_start: iso(t0 + 1800), window_end: iso(t0 + 3600), channel_group: 'all', model: 'none',
          usable: false, context_kind: 'rest', withheld_reason: 'recovery', reason_code: 'context_not_comparable/recovery',
          reason_certainty: 'inferred' },
        { window_start: iso(t0 + 3600), window_end: iso(t0 + 5400), channel_group: 'all', model: 'timesfm-3.0',
          usable: true, context_kind: 'rest', score: 0.4, p: 0.6, withheld_reason: null },
      ],
    };
    await psql(`
      insert into auth.users (id) values ('${user}');
      insert into public.devices (id, user_id, source_kind) values ('${device}', '${user}', 'noop_push');
      insert into public.anomaly_jobs (user_id, device_id, input_revision, lease_token, lease_until)
        values ('${user}', '${device}', 1, '${token}', clock_timestamp() + interval '10 minutes');
      select public.publish_anomaly_result_v1('${token}', 1, '${JSON.stringify(payload)}'::jsonb);`);
    try {
      const service = createSupabaseRest({
        cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
        fetchImpl: (input, init) =>
          fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(30000) }),
      });
      const rest = {
        ...service,
        configured: true,
        select: async (table: string, query: string) => {
          if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_aw-token'))
            ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: user,
              source_id: source }]
            : [{ id: 'fleet', token_kind: 'fleet' }];
          if (table === 'noop_app_installations') return [{ user_id: user, source_id: source }];
          if (table === 'devices') return query.includes(`user_id=eq.${user}`) ? [{ id: device }] : [];
          return service.select(table, query);
        },
      } as any;
      const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
      const headers = { authorization: 'Bearer noop_aw-token', 'x-noop-fleet-token': 'noop_fleet' };
      const res = await handleScoresRequest(new Request('https://example.test/functions/v1/scores/anomaly-candidates'
        + `?deviceId=whoop-MGB0000008&since=0&windows_from=${t0}&windows_to=${t0 + 7200}`, { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      const body = await res.json();
      assert.deepEqual(body.candidates, []);
      assert.equal(body.reason_codes_version, 'data-reason-1');
      assert.equal(body.windows.length, 3);
      assert.deepEqual(body.windows[0].reason,
        { code: 'context_not_comparable', subcode: 'movement', certainty: 'inferred', legacy: 'activity' });
      assert.deepEqual(body.windows[1].reason,
        { code: 'context_not_comparable', subcode: 'recovery', certainty: 'inferred', legacy: 'recovery' });
      assert.equal(body.windows[2].reason, null);
      assert.equal(body.windows[2].usable, true);
      assert.equal(body.windows[2].models[0].model, 'timesfm-3.0');
      assert.equal(body.windows[0].context.mix_basis, 'none', 'no minute rows built for this synthetic owner');
    } finally {
      await psql(`delete from auth.users where id = '${user}';`);
    }
  },
});
