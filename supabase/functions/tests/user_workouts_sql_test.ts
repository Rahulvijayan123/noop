// Workout mode on the production Postgres image with the full migration chain: runs supabase/tests/user_workouts.sql
// (idempotent last-writer-wins upsert, refusals, one workout at a time, the builder's queue, the read, the pipelines'
// logged-workout list, the measurement-context builder, RLS between two owners) inside the pipeline container, then
// drives the real scores handler against PostgREST with the service role (only the credential and device lookups are
// stubbed), so the RPCs run as production runs them. Docker-gated like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/user_workouts_sql_test.ts
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
  name: 'user workouts: upsert, refusals, one at a time, read, logged list, builder and RLS (SQL)',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = await docker(['exec', '-e', 'PGAPPNAME=user-workouts', '-i', container!, 'psql', '-U', 'postgres',
      '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
      await Deno.readFile(new URL('../../tests/user_workouts.sql', import.meta.url)));
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /user_workouts: ok/);
  },
});

Deno.test({
  name: 'user workouts: POST and GET scores/workouts through PostgREST',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const user = crypto.randomUUID();
    const device = crypto.randomUUID();
    const source = crypto.randomUUID();
    await psql(`
      insert into auth.users (id) values ('${user}');
      insert into public.devices (id, user_id, source_kind, external_device_id)
        values ('${device}', '${user}', 'noop_push', 'whoop-MGB0000010');`);
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
          if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_uw-token'))
            ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: user,
              source_id: source }]
            : [{ id: 'fleet', token_kind: 'fleet' }];
          if (table === 'noop_app_installations') return [{ user_id: user, source_id: source }];
          if (table === 'devices') return query.includes(`user_id=eq.${user}`) ? [{ id: device }] : [];
          return [];
        },
      } as any;
      const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
      const headers = { authorization: 'Bearer noop_uw-token', 'x-noop-fleet-token': 'noop_fleet',
        'content-type': 'application/json' };
      const started = 1790305200;
      const workout = {
        client_id: '00000000-0000-4000-8000-0000000000d1', type: 'indoor_cycling', started_at: started,
        ended_at: null, source: 'manual', deleted: false, client_updated_at: started,
      };
      const post = (workouts: unknown[]) => handleScoresRequest(new Request(
        'https://example.test/functions/v1/scores/workouts',
        { method: 'POST', headers, body: JSON.stringify({ device_id: 'whoop-MGB0000010', local_device_id: 'my-whoop',
          catalogue_version: 'workout-types-1', workouts }) }), { rest, cfg });
      let res = await post([workout]);
      assert.equal(res.status, 200, await res.clone().text());
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0, closed: 0 });
      res = await post([workout]);
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0, closed: 0 }, 'a replay changes nothing');
      res = await post([{ ...workout, ended_at: started + 2700, client_updated_at: started + 2700 }]);
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0, closed: 0 }, 'stopped');
      res = await post([{ ...workout, type: 'yoga', client_updated_at: started + 100 }]);
      assert.deepEqual(await res.json(), { accepted: 0, skipped_stale: 1, closed: 0 }, 'an older copy is skipped');

      res = await handleScoresRequest(new Request(
        `https://example.test/functions/v1/scores/workouts?deviceId=whoop-MGB0000010&from=${started - 60}&to=${started + 3600}`,
        { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      const read = await res.json();
      assert.equal(read.device_id, 'whoop-MGB0000010');
      assert.equal(read.truncated, false);
      assert.equal(read.catalogue_version, 'workout-types-1');
      assert.equal(read.workouts.length, 1);
      const got = read.workouts[0];
      assert.equal(got.client_id, workout.client_id);
      assert.equal(got.type, 'indoor_cycling');
      assert.equal(got.started_at, started);
      assert.equal(got.ended_at, started + 2700);
      assert.equal(got.local_device_id, 'my-whoop');
      assert.deepEqual(got.attributes, { name: 'Indoor cycling', sport_name: 'Indoor cycle', decoder_kind: 'cycling',
        environment: 'indoor', locomotion: 'cycling', effort: 'moderate', gait_expected: false, arm_motion: 'fixed',
        steps_expected: false });

      res = await post([{ ...workout, type: 'gym' }]);
      assert.equal(res.status, 400);
      assert.equal((await res.json()).error, 'invalid_workout_type');
      assert.equal(await psql(`select count(*) from public.user_workouts where user_id = '${user}'`), '1');
    } finally {
      await psql(`delete from auth.users where id = '${user}';`);
    }
  },
});
