import { assert, assertEquals, assertThrows } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { parseUserWorkoutsQuery, USER_WORKOUT_MAX_BYTES, validateUserWorkouts } from '../_shared/userWorkouts.ts';
import { makeMemRest } from './helpers.ts';

// POST / GET scores/workouts (docs/context-watchdog/WORKOUTS.md): workout mode's logged workouts. Owner and uploading
// installation from the credential, device the strap the body names (resolved like every other route), the batch
// validated whole (catalogue types, times, sizes) before the RPC (user_workouts_upsert_v1) is asked.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f002';
const DEVICE = '11111111-1111-4111-8111-111111111112';
const SOURCE = '22222222-2222-4222-8222-222222222223';
const STRAP = 'whoop-MGB0000002';
const CLIENT = '33333333-3333-4333-8333-333333333333';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
const T0 = 1791433200;

function workout(overrides: Record<string, unknown> = {}) {
  return {
    client_id: CLIENT, type: 'strength', started_at: T0, ended_at: T0 + 4800, source: 'manual', deleted: false,
    client_updated_at: T0 + 4800, ...overrides,
  };
}

function fakeRest(calls: Array<{ fn: string; args: any }>, devices: Record<string, string> = { [STRAP]: DEVICE }) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') {
      assert(query.includes(`user_id=eq.${USER}`), 'devices are looked up for the credential owner only');
      const external = decodeURIComponent(/external_device_id=eq\.([^&]+)/.exec(query)?.[1] ?? '');
      return devices[external] ? [{ id: devices[external] }] : [];
    }
    return [];
  };
  rest.rpc = async (fn: string, args: any) => {
    calls.push({ fn, args });
    if (fn === 'user_workouts_upsert_v1') return { accepted: args.p_workouts.length, skipped_stale: 0, closed: 0 };
    if (fn === 'user_workouts_read_v1') {
      return { workouts: [{ client_id: CLIENT, device_id: STRAP, type: 'strength' }], truncated: false,
        catalogue_version: 'workout-types-1' };
    }
    throw new Error(`unexpected rpc ${fn}`);
  };
  return rest;
}

function post(body: unknown) {
  return new Request('https://example.test/functions/v1/scores/workouts', {
    method: 'POST', body: JSON.stringify(body),
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet', 'content-type': 'application/json' },
  });
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/workouts?${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('workouts POST: owner, installation and strap device from the server, batch passed to the RPC', async () => {
  const calls: Array<{ fn: string; args: any }> = [];
  const open = workout({ client_id: '44444444-4444-4444-8444-444444444444', type: 'indoor_walk',
    started_at: T0 + 6000, ended_at: null, client_updated_at: T0 + 6000 });
  const res = await handleScoresRequest(post({ device_id: STRAP, local_device_id: 'my-whoop',
    catalogue_version: 'workout-types-1', workouts: [workout(), open] }), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals(await res.json(), { accepted: 2, skipped_stale: 0, closed: 0 });
  assertEquals(res.headers.get('cache-control'), 'no-store');
  assertEquals(calls.length, 1);
  const args = calls[0].args;
  assertEquals(args.p_user, USER);
  assertEquals(args.p_device, DEVICE);
  assertEquals(args.p_source, SOURCE);
  assertEquals(args.p_local_device, 'my-whoop');
  assertEquals(args.p_workouts[0], { ...workout(), notes: null });
  assertEquals(args.p_workouts[1].ended_at, null, 'a running workout');
  assertEquals(args.p_workouts[1].type, 'indoor_walk');
});

Deno.test('workouts POST: unknown strap is 409, missing device is 400, no RPC call', async () => {
  const calls: Array<{ fn: string; args: any }> = [];
  let res = await handleScoresRequest(post({ device_id: 'whoop-UNKNOWN01', workouts: [workout()] }),
    { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'device_registration_pending');
  res = await handleScoresRequest(post({ workouts: [workout()] }), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_device_id');
  assertEquals(calls.length, 0);
});

Deno.test('workouts POST: an invalid batch is refused whole with its first problem', async () => {
  const now = Math.floor(Date.now() / 1000);
  const cases: Array<[unknown, number, string]> = [
    [{ device_id: STRAP, workouts: [] }, 400, 'invalid_workouts'],
    [{ device_id: STRAP, workouts: Array.from({ length: 51 }, () => workout()) }, 400, 'invalid_workouts'],
    [{ device_id: STRAP, workouts: [workout(), workout()] }, 400, 'duplicate_client_id'],
    [{ device_id: STRAP, workouts: [workout(), workout({ client_id: CLIENT.toUpperCase() })] }, 400,
      'duplicate_client_id'],
    [{ device_id: STRAP, workouts: [workout({ client_id: 'w-1' })] }, 400, 'invalid_client_id'],
    [{ device_id: STRAP, workouts: [workout({ type: 'gym' })] }, 400, 'invalid_workout_type'],
    [{ device_id: STRAP, workouts: [workout({ type: 'constructor' })] }, 400, 'invalid_workout_type'],
    [{ device_id: STRAP, workouts: [workout({ ended_at: T0 })] }, 400, 'invalid_workout_times'],
    [{ device_id: STRAP, workouts: [workout({ ended_at: T0 + 86_401 })] }, 400, 'invalid_workout_times'],
    [{ device_id: STRAP, workouts: [workout({ started_at: T0 + 0.5 })] }, 400, 'invalid_workout_times'],
    [{ device_id: STRAP, workouts: [workout({ started_at: now + 3600, ended_at: null })] }, 400,
      'invalid_workout_times'],
    [{ device_id: STRAP, workouts: [workout({ client_updated_at: '1791441210' })] }, 400, 'invalid_client_updated_at'],
    [{ device_id: STRAP, workouts: [workout({ source: 'phone' })] }, 400, 'invalid_source'],
    [{ device_id: STRAP, workouts: [workout({ deleted: 'yes' })] }, 400, 'invalid_workout'],
    [{ device_id: STRAP, workouts: [workout({ notes: 'x'.repeat(501) })] }, 400, 'invalid_notes'],
    [{ device_id: STRAP, workouts: [workout({ padding: 'x'.repeat(USER_WORKOUT_MAX_BYTES) })] }, 413,
      'workout_too_large'],
    [{ device_id: STRAP, catalogue_version: 'v2', workouts: [workout()] }, 400, 'invalid_catalogue_version'],
    [{ device_id: STRAP, local_device_id: 'me@example.com', workouts: [workout()] }, 400, 'invalid_local_device_id'],
  ];
  for (const [body, status, code] of cases) {
    const calls: Array<{ fn: string; args: any }> = [];
    const res = await handleScoresRequest(post(body), { rest: fakeRest(calls), cfg });
    assertEquals(res.status, status, `${code}: ${await res.clone().text()}`);
    assertEquals((await res.json()).error, code);
    assertEquals(calls.length, 0, `${code}: nothing reaches the database`);
  }
});

Deno.test('workouts: validation keeps known members, lowercases ids and fills defaults', () => {
  const out = validateUserWorkouts({ workouts: [{ client_id: CLIENT.toUpperCase(), type: 'yoga', started_at: T0,
    client_updated_at: T0, future_member: 1 }] });
  assertEquals(out.localDeviceId, null);
  assertEquals(out.workouts[0], { client_id: CLIENT, type: 'yoga', started_at: T0, ended_at: null, source: 'manual',
    deleted: false, notes: null, client_updated_at: T0 });
});

Deno.test('workouts GET: one device or all of the owner, range and deleted flag checked', async () => {
  let calls: Array<{ fn: string; args: any }> = [];
  let res = await handleScoresRequest(get(`deviceId=${STRAP}&from=1791400000&to=1791500000`),
    { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals(await res.json(), { device_id: STRAP, workouts: [{ client_id: CLIENT, device_id: STRAP, type: 'strength' }],
    truncated: false, catalogue_version: 'workout-types-1' });
  assertEquals(calls[0].fn, 'user_workouts_read_v1');
  assertEquals(calls[0].args.p_user, USER);
  assertEquals(calls[0].args.p_device, DEVICE);
  assertEquals(calls[0].args.p_from, new Date(1791400000 * 1000).toISOString());
  assertEquals(calls[0].args.p_limit, 500);
  assertEquals(calls[0].args.p_include_deleted, false);

  calls = [];
  res = await handleScoresRequest(get('from=1791400000&to=1791500000&includeDeleted=1'), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(calls[0].args.p_device, null, 'no deviceId: every device of the owner');
  assertEquals(calls[0].args.p_include_deleted, true);
  assertEquals('device_id' in await res.json(), false);

  res = await handleScoresRequest(get('deviceId=whoop-UNKNOWN01&from=1&to=2'), { rest: fakeRest([]), cfg });
  assertEquals(res.status, 409);
  for (const q of ['from=10&to=10', 'from=a&to=2', 'to=2', `from=0&to=${91 * 86400}`]) {
    assertThrows(() => parseUserWorkoutsQuery(new URLSearchParams(q)), Error, 'invalid_range');
  }
  assertThrows(() => parseUserWorkoutsQuery(new URLSearchParams('from=1&to=2&includeDeleted=yes')), Error,
    'invalid_include_deleted');
});

Deno.test('workouts: other methods are not allowed', async () => {
  const req = new Request('https://example.test/functions/v1/scores/workouts', {
    method: 'DELETE', headers: { authorization: 'Bearer noop_test-token' } });
  const res = await handleScoresRequest(req, { rest: fakeRest([]), cfg });
  assertEquals(res.status, 405);
});

Deno.test('watchdog episodes: the exercise snapshot may carry workout-mode lineage, checked against the catalogue', async () => {
  const episode = (exercise: Record<string, unknown>) => ({
    episode_id: 'wd-1', opened_at: T0, last_at: T0 + 60, max_severity: 'candidate', safety: false,
    client_updated_at: T0 + 60, exercise: { rule: 'exercise-session-2', phase: 'session', ...exercise },
  });
  const calls: Array<{ fn: string; args: any }> = [];
  const rest = fakeRest(calls);
  rest.rpc = async (fn: string, args: any) => {
    calls.push({ fn, args });
    return { accepted: args.p_episodes.length, skipped_stale: 0 };
  };
  const req = (exercise: Record<string, unknown>) => new Request('https://example.test/functions/v1/scores/watchdog-episodes',
    { method: 'POST', body: JSON.stringify({ device_id: STRAP, episodes: [episode(exercise)] }),
      headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet',
        'content-type': 'application/json' } });
  let res = await handleScoresRequest(req({ basis: 'logged', workoutType: 'strength', confirmed: true }), { rest, cfg });
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals(calls[0].args.p_episodes[0].exercise.workoutType, 'strength', 'kept as sent');
  res = await handleScoresRequest(req({ basis: 'guessed' }), { rest, cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_exercise');
  res = await handleScoresRequest(req({ basis: 'logged', workoutType: 'gym' }), { rest, cfg });
  assertEquals(res.status, 400);
  assertEquals(calls.length, 1);
});
