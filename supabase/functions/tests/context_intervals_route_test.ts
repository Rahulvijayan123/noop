import { assert, assertEquals, assertThrows } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { validateContextIntervals } from '../_shared/contextIntervals.ts';
import { makeMemRest } from './helpers.ts';

// POST /scores/context-intervals: the phone's activity-context intervals (20261009190000), validated here and stored
// through phone_context_intervals_replace_v1 for the credential's owner and the caller's own device.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const OTHER = '7f2c9a10-4b3e-4d8a-9c11-00000000f002';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
const DAY = 1_789_948_800;

function fakeRest(calls: Array<{ name: string; args: any }>, { knownDevice = true } = {}) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') {
      assert(query.includes(`user_id=eq.${USER}`), 'devices are looked up for the credential owner only');
      return knownDevice ? [{ id: DEVICE }] : [];
    }
    return [];
  };
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    return { accepted: args.p_intervals.length, deleted: 2 };
  };
  return rest;
}

function post(body: unknown) {
  return new Request('https://example.test/functions/v1/scores/context-intervals', {
    method: 'POST', headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet',
      'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

const interval = (k: number, extra: Record<string, unknown> = {}) => ({
  start_ts: DAY + 600 * k, end_ts: DAY + 600 * (k + 1), activity_class: 'sitting', confidence: 0.9,
  evidence_quality: 0.8, posture: 'seated_likely', locomotion: 'stationary', sleep_state: 'awake',
  wear_state: 'on_wrist', intensity: 0.1, hr_samples: 590, hr_mean: 70.5, rmssd: 40, rr_beats: 700,
  rr_diff_sq_sum_ms2: 1_120_000, rr_diff_count: 700, detail: null, arm_behavior: null, ...extra,
});

Deno.test('context intervals: stored for the credential owner and the caller\'s device, normalized', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  const body = { device_id: LOCAL_DEVICE, version: 'lb-context-3', source_id: 'whoop-MGB0214654', user_id: OTHER,
    from: DAY, to: DAY + 86400,
    intervals: [interval(0), { start_ts: DAY + 600, end_ts: DAY + 660, activity_class: 'walking', extra: 1 }] };
  const res = await handleScoresRequest(post(body), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('cache-control'), 'no-store');
  assertEquals(await res.json(), { accepted: 2, deleted: 2 });
  assertEquals(calls.length, 1);
  const { name, args } = calls[0];
  assertEquals(name, 'phone_context_intervals_replace_v1');
  assertEquals([args.p_user, args.p_device, args.p_version, args.p_source, args.p_from, args.p_to],
    [USER, DEVICE, 'lb-context-3', 'whoop-MGB0214654', DAY, DAY + 86400]);
  assertEquals(args.p_intervals[0], interval(0));
  assertEquals(args.p_intervals[1], {
    start_ts: DAY + 600, end_ts: DAY + 660, activity_class: 'walking', confidence: 0, evidence_quality: 0,
    posture: null, locomotion: null, sleep_state: 'unknown', wear_state: 'unknown', intensity: null, hr_samples: 0,
    hr_mean: null, rmssd: null, rr_beats: 0, rr_diff_sq_sum_ms2: 0, rr_diff_count: 0, detail: null,
    arm_behavior: null });
});

Deno.test('context intervals: an empty day clears the range', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  const res = await handleScoresRequest(post({ device_id: LOCAL_DEVICE, version: 'lb-context-3', from: DAY,
    to: DAY + 86400, intervals: [] }), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(calls[0].args.p_intervals, []);
});

Deno.test('context intervals: an unknown strap is not stored', async () => {
  const calls: Array<{ name: string; args: any }> = [];
  const res = await handleScoresRequest(post({ device_id: LOCAL_DEVICE, version: 'lb-context-3', from: DAY,
    to: DAY + 86400, intervals: [interval(0)] }), { rest: fakeRest(calls, { knownDevice: false }), cfg });
  assertEquals(res.status, 409);
  assertEquals(calls, []);
});

Deno.test('context intervals: malformed payloads are rejected before the database', async () => {
  const now = DAY + 86400;
  const ok = { version: 'lb-context-3', from: DAY, to: DAY + 86400, intervals: [interval(0)] };
  validateContextIntervals(ok, now);
  const bad: Array<[Record<string, unknown>, string]> = [
    [{ ...ok, version: 'bad version' }, 'invalid_version'],
    [{ ...ok, to: DAY + 3 * 86400 }, 'invalid_range'],
    [{ ...ok, to: DAY }, 'invalid_range'],
    [{ ...ok, from: DAY + 5 * 86400, to: DAY + 6 * 86400 }, 'invalid_range'],
    [{ ...ok, intervals: [interval(-1)] }, 'invalid_interval'],
    [{ ...ok, intervals: [interval(0, { end_ts: DAY })] }, 'invalid_interval'],
    [{ ...ok, intervals: [interval(0), interval(0)] }, 'duplicate_interval'],
    [{ ...ok, intervals: [interval(0, { activity_class: null })] }, 'invalid_interval'],
    [{ ...ok, intervals: [interval(0, { hr_samples: -1 })] }, 'invalid_interval'],
    [{ ...ok, intervals: [interval(0, { hr_mean: 'x' })] }, 'invalid_interval'],
    [{ ...ok, intervals: [interval(0, { posture: 'drop table;' })] }, 'invalid_interval'],
    [{ ...ok, intervals: 'x' }, 'invalid_intervals'],
  ];
  for (const [body, code] of bad) {
    assertThrows(() => validateContextIntervals(body, now), Error, code);
  }
});
