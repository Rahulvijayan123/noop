import { assert, assertEquals, assertThrows } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import {
  WATCHDOG_EPISODE_MAX_BYTES,
  parseWatchdogEpisodesQuery,
  validateWatchdogEpisodes,
} from '../_shared/watchdogEpisodes.ts';
import { makeMemRest } from './helpers.ts';

// POST / GET scores/watchdog-episodes (docs/context-watchdog/WATCHDOG_EPISODES.md): the phone's Watchdog journal and
// annotations. Owner and uploading installation from the credential, device the strap the body names (resolved like
// every other route), the batch validated whole before the RPC (watchdog_episodes_upsert_v1) is asked.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const STRAP = 'whoop-MGB0000001';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

function episode(overrides: Record<string, unknown> = {}) {
  return {
    episode_id: 'wd-1791438841', opened_at: 1791438841, last_at: 1791441000, closed_at: null,
    max_severity: 'severe', peak_severity: 'active', safety: false, personal_off: true, notify_delivery: 'sent',
    live_alerts: true, off_minute_count: 56, unavailable_minutes: 0, headline: 'Heart rate higher than usual',
    event_label: 'abnormal_multi_direction', activity_label: 'exercise_session', contributing: ['HR'],
    signals: [{ name: 'HR', unit: 'bpm', observed: 108, usual: 88, reconstructed: null, energy: 2.4, trustPct: 90,
      rangeHalf: 6.5 }],
    exercise: { rule: 'exercise-session-1', phase: 'recovery', sessionStartUnix: 1791433200,
      sessionLastMovementUnix: 1791438600, restReference: 66, restBasis: 'sleep_resting_hr', ceilingBpm: 185,
      ceilingBasis: 'age_formula', sessionReference: 'learning', recoveryReference: 'learning', routine: null },
    annotation: { episodeId: 'wd-1791438841', deviceId: 'my-whoop', eventUnix: 1791438900, enteredUnix: 1791439500,
      reporter: 'wearer', status: 'entered', exertion: 'hard', sensor: 'just_on' },
    quality_reasons: [{ code: 'context_not_comparable', subcode: 'recovery', certainty: 'inferred' }],
    versions: { watchdog: 'v3.1', baseline: 'lb-context-1', exercise_rule: 'exercise-session-1',
      reason_codes: 'data-reason-1' },
    client_updated_at: 1791441210,
    ...overrides,
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
    if (fn === 'watchdog_episodes_upsert_v1') return { accepted: args.p_episodes.length, skipped_stale: 0 };
    if (fn === 'watchdog_episodes_read_v1') return { episodes: [{ episode_id: 'wd-1', device_id: STRAP }], truncated: false };
    throw new Error(`unexpected rpc ${fn}`);
  };
  return rest;
}

function post(body: unknown) {
  return new Request('https://example.test/functions/v1/scores/watchdog-episodes', {
    method: 'POST', body: JSON.stringify(body),
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet', 'content-type': 'application/json' },
  });
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/watchdog-episodes?${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('watchdog episodes POST: owner, installation and strap device from the server, batch passed to the RPC', async () => {
  const calls: Array<{ fn: string; args: any }> = [];
  const res = await handleScoresRequest(post({ device_id: STRAP, local_device_id: 'my-whoop',
    episodes: [episode(), episode({ episode_id: 'wd-2', annotation: null, exercise: null })] }),
    { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals(await res.json(), { accepted: 2, skipped_stale: 0 });
  assertEquals(res.headers.get('cache-control'), 'no-store');
  assertEquals(calls.length, 1);
  const args = calls[0].args;
  assertEquals(args.p_user, USER);
  assertEquals(args.p_device, DEVICE);
  assertEquals(args.p_source, SOURCE);
  assertEquals(args.p_local_device, 'my-whoop');
  assertEquals(args.p_episodes[0].exercise.phase, 'recovery');
  assertEquals(args.p_episodes[0].signals[0].reconstructed, null, 'nested objects pass through as sent');
  assertEquals(args.p_episodes[1].annotation, null);
});

Deno.test('watchdog episodes POST: unknown strap is 409, missing device is 400, no RPC call', async () => {
  const calls: Array<{ fn: string; args: any }> = [];
  let res = await handleScoresRequest(post({ device_id: 'whoop-UNKNOWN01', episodes: [episode()] }),
    { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'device_registration_pending');
  res = await handleScoresRequest(post({ episodes: [episode()] }), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_device_id');
  assertEquals(calls.length, 0);
});

Deno.test('watchdog episodes POST: an invalid batch is refused whole with its first problem', async () => {
  const cases: Array<[unknown, number, string]> = [
    [{ device_id: STRAP, episodes: [] }, 400, 'invalid_episodes'],
    [{ device_id: STRAP, episodes: Array.from({ length: 51 }, (_, i) => episode({ episode_id: `wd-${i}` })) },
      400, 'invalid_episodes'],
    [{ device_id: STRAP, episodes: [episode(), episode()] }, 400, 'duplicate_episode_id'],
    [{ device_id: STRAP, episodes: [episode({ max_severity: 'loud' })] }, 400, 'invalid_severity'],
    [{ device_id: STRAP, episodes: [episode({ peak_severity: 'loud' })] }, 400, 'invalid_severity'],
    [{ device_id: STRAP, episodes: [episode({ notify_delivery: 'maybe' })] }, 400, 'invalid_notify_delivery'],
    [{ device_id: STRAP, episodes: [episode({ last_at: 1791438000 })] }, 400, 'invalid_episode_times'],
    [{ device_id: STRAP, episodes: [episode({ opened_at: 1791438841.5 })] }, 400, 'invalid_episode_times'],
    [{ device_id: STRAP, episodes: [episode({ closed_at: 1700000000 })] }, 400, 'invalid_episode_times'],
    [{ device_id: STRAP, episodes: [episode({ client_updated_at: '1791441210' })] }, 400, 'invalid_client_updated_at'],
    [{ device_id: STRAP, episodes: [episode({ episode_id: 'wd 1' })] }, 400, 'invalid_episode_id'],
    [{ device_id: STRAP, episodes: [episode({ safety: 'no' })] }, 400, 'invalid_episode'],
    [{ device_id: STRAP, episodes: [episode({ exercise: { rule: 'exercise-session-1', phase: 'gym' } })] },
      400, 'invalid_exercise'],
    [{ device_id: STRAP, episodes: [episode({ annotation: { ...episode().annotation, episodeId: 'wd-other' } })] },
      400, 'invalid_annotation'],
    [{ device_id: STRAP, episodes: [episode({ annotation: { ...episode().annotation, exertion: 'max' } })] },
      400, 'invalid_annotation'],
    [{ device_id: STRAP, episodes: [episode({ quality_reasons: [{ code: 'gym', certainty: 'inferred' }] })] },
      400, 'invalid_quality_reasons'],
    [{ device_id: STRAP, episodes: [episode({ quality_reasons: [{ code: 'off_wrist', certainty: 'sure' }] })] },
      400, 'invalid_quality_reasons'],
    [{ device_id: STRAP, episodes: [episode({ quality_reasons: [{ code: 'off_wrist', subcode: 'gym',
      certainty: 'inferred' }] })] }, 400, 'invalid_quality_reasons'],
    [{ device_id: STRAP, episodes: [episode({ signals: [{ unit: 'bpm' }] })] }, 400, 'invalid_signals'],
    [{ device_id: STRAP, episodes: [episode({ versions: { watchdog: 3 } })] }, 400, 'invalid_versions'],
    [{ device_id: STRAP, episodes: [episode({ headline: 'x'.repeat(WATCHDOG_EPISODE_MAX_BYTES) })] },
      413, 'episode_too_large'],
    [{ device_id: STRAP, local_device_id: 'me@example.com', episodes: [episode()] }, 400, 'invalid_local_device_id'],
  ];
  for (const [body, status, code] of cases) {
    const calls: Array<{ fn: string; args: any }> = [];
    const res = await handleScoresRequest(post(body), { rest: fakeRest(calls), cfg });
    assertEquals(res.status, status, `${code}: ${await res.clone().text()}`);
    assertEquals((await res.json()).error, code);
    assertEquals(calls.length, 0, `${code}: nothing reaches the database`);
  }
});

Deno.test('watchdog episodes: validation keeps known members and drops unknown ones', () => {
  const out = validateWatchdogEpisodes({ device_id: STRAP, episodes: [episode({ future_member: 1, closed_at: undefined,
    peak_severity: undefined, notify_delivery: undefined })] });
  assertEquals(out.localDeviceId, null);
  const e = out.episodes[0] as any;
  assertEquals('future_member' in e, false);
  assertEquals(e.closed_at, null);
  assertEquals(e.peak_severity, null);
  assertEquals(e.notify_delivery, '');
  // Exactly 50 episodes at a realistic size is fine.
  const fifty = validateWatchdogEpisodes({ episodes: Array.from({ length: 50 },
    (_, i) => episode({ episode_id: `wd-${i}`, annotation: null })) });
  assertEquals(fifty.episodes.length, 50);
});

Deno.test('watchdog episodes GET: one device or all of the owner, range checked', async () => {
  let calls: Array<{ fn: string; args: any }> = [];
  let res = await handleScoresRequest(get(`deviceId=${STRAP}&from=1791400000&to=1791500000`), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200, await res.clone().text());
  assertEquals(await res.json(), { device_id: STRAP, episodes: [{ episode_id: 'wd-1', device_id: STRAP }], truncated: false });
  assertEquals(calls[0].fn, 'watchdog_episodes_read_v1');
  assertEquals(calls[0].args.p_user, USER);
  assertEquals(calls[0].args.p_device, DEVICE);
  assertEquals(calls[0].args.p_from, new Date(1791400000 * 1000).toISOString());
  assertEquals(calls[0].args.p_limit, 500);

  calls = [];
  res = await handleScoresRequest(get('from=1791400000&to=1791500000'), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(calls[0].args.p_device, null, 'no deviceId: every device of the owner');
  assertEquals('device_id' in await res.json(), false);

  res = await handleScoresRequest(get('deviceId=whoop-UNKNOWN01&from=1&to=2'), { rest: fakeRest([]), cfg });
  assertEquals(res.status, 409);
  for (const q of ['from=10&to=10', 'from=a&to=2', 'to=2', `from=0&to=${91 * 86400}`]) {
    assertThrows(() => parseWatchdogEpisodesQuery(new URLSearchParams(q)), Error, 'invalid_range');
  }
  res = await handleScoresRequest(get('from=10&to=5'), { rest: fakeRest([]), cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_range');
});

Deno.test('watchdog episodes: other methods are not allowed', async () => {
  const req = new Request('https://example.test/functions/v1/scores/watchdog-episodes', {
    method: 'DELETE', headers: { authorization: 'Bearer noop_test-token' } });
  const res = await handleScoresRequest(req, { rest: fakeRest([]), cfg });
  assertEquals(res.status, 405);
});
