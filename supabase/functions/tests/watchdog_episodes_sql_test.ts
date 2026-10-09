// Watchdog episodes on the production Postgres image with the full migration chain: runs
// supabase/tests/watchdog_episodes.sql (idempotent last-writer-wins upsert, size caps and enums, the read, RLS between
// two owners) inside the pipeline container, then drives the real scores handler against PostgREST with the service
// role (only the credential and device lookups are stubbed), so the RPCs run as production runs them. Docker-gated
// like auth_isolation_sql_test.ts:
//
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   cd supabase/functions
//   deno test -A --no-lock tests/watchdog_episodes_sql_test.ts
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
  name: 'watchdog episodes: upsert, caps, read and RLS (SQL)',
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const run = await docker(['exec', '-e', 'PGAPPNAME=watchdog-episodes', '-i', container!, 'psql', '-U', 'postgres',
      '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
      await Deno.readFile(new URL('../../tests/watchdog_episodes.sql', import.meta.url)));
    assert.equal(run.code, 0, run.stderr.slice(-4000));
    assert.match(run.stdout, /watchdog_episodes: ok/);
  },
});

Deno.test({
  name: 'watchdog episodes: POST and GET scores/watchdog-episodes through PostgREST',
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
        values ('${device}', '${user}', 'noop_push', 'whoop-MGB0000009');`);
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
          if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_wd-token'))
            ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: user,
              source_id: source }]
            : [{ id: 'fleet', token_kind: 'fleet' }];
          if (table === 'noop_app_installations') return [{ user_id: user, source_id: source }];
          if (table === 'devices') return query.includes(`user_id=eq.${user}`) ? [{ id: device }] : [];
          return [];
        },
      } as any;
      const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
      const headers = { authorization: 'Bearer noop_wd-token', 'x-noop-fleet-token': 'noop_fleet',
        'content-type': 'application/json' };
      const episode = {
        episode_id: 'wd-1791438841', opened_at: 1791438841, last_at: 1791441000, closed_at: null,
        max_severity: 'severe', peak_severity: 'active', safety: false, personal_off: true, notify_delivery: 'sent',
        live_alerts: true, off_minute_count: 56, unavailable_minutes: 0, headline: 'Heart rate higher than usual',
        event_label: 'abnormal_multi_direction', activity_label: 'exercise_session', contributing: ['HR'],
        signals: [{ name: 'HR', unit: 'bpm', observed: 108, usual: 88, reconstructed: null, energy: 2.4,
          trustPct: 90, rangeHalf: 6.5 }],
        exercise: { rule: 'exercise-session-1', phase: 'recovery', sessionStartUnix: 1791433200,
          sessionLastMovementUnix: 1791438600, restReference: 66, restBasis: 'sleep_resting_hr', ceilingBpm: 185,
          ceilingBasis: 'age_formula', sessionReference: 'learning', recoveryReference: 'learning', routine: null },
        annotation: { episodeId: 'wd-1791438841', deviceId: 'my-whoop', eventUnix: 1791438900,
          enteredUnix: 1791439500, reporter: 'wearer', status: 'entered', exertion: 'hard', sensor: 'just_on' },
        quality_reasons: [{ code: 'context_not_comparable', subcode: 'recovery', certainty: 'inferred' }],
        versions: { watchdog: 'v3.1', exercise_rule: 'exercise-session-1', reason_codes: 'data-reason-1' },
        client_updated_at: 1791441210,
      };
      const post = (episodes: unknown[]) => handleScoresRequest(new Request(
        'https://example.test/functions/v1/scores/watchdog-episodes',
        { method: 'POST', headers, body: JSON.stringify({ device_id: 'whoop-MGB0000009', local_device_id: 'my-whoop',
          episodes }) }), { rest, cfg });
      let res = await post([episode]);
      assert.equal(res.status, 200, await res.clone().text());
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0 });
      res = await post([episode]);
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0 }, 'a replay is accepted and changes nothing');
      res = await post([{ ...episode, client_updated_at: 1791441000, notify_delivery: 'queued' }]);
      assert.deepEqual(await res.json(), { accepted: 0, skipped_stale: 1 }, 'an older copy is skipped');
      res = await post([{ ...episode, client_updated_at: 1791441500, closed_at: 1791441400 }]);
      assert.deepEqual(await res.json(), { accepted: 1, skipped_stale: 0 });

      res = await handleScoresRequest(new Request(
        'https://example.test/functions/v1/scores/watchdog-episodes?deviceId=whoop-MGB0000009&from=1791438000&to=1791442000',
        { headers }), { rest, cfg });
      assert.equal(res.status, 200, await res.clone().text());
      const read = await res.json();
      assert.equal(read.device_id, 'whoop-MGB0000009');
      assert.equal(read.truncated, false);
      assert.equal(read.episodes.length, 1);
      const got = read.episodes[0];
      assert.equal(got.device_id, 'whoop-MGB0000009');
      assert.equal(got.local_device_id, 'my-whoop');
      assert.equal(got.closed_at, 1791441400);
      assert.equal(got.client_updated_at, 1791441500);
      assert.equal(got.notify_delivery, 'sent');
      assert.deepEqual(got.exercise, episode.exercise);
      assert.deepEqual(got.annotation, episode.annotation);
      assert.deepEqual(got.signals, episode.signals);
      assert.deepEqual(got.quality_reasons, episode.quality_reasons);
      for (const key of Object.keys(episode)) assert.ok(key in got, `GET returns ${key}`);

      res = await post([{ ...episode, max_severity: 'loud' }]);
      assert.equal(res.status, 400);
      assert.equal((await res.json()).error, 'invalid_severity');
      assert.equal(await psql(`select count(*) from public.watchdog_episodes where user_id = '${user}'`), '1');
    } finally {
      await psql(`delete from auth.users where id = '${user}';`);
    }
  },
});
