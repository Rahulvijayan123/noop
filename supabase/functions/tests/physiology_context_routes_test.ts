// The physiology context routes of the `scores` function (contracts.md §8) against in-memory PostgREST
// doubles: GET /context, GET /context/history, POST /exposures, GET /exposures. Auth (installation bearer,
// signed-in account + registered source), owner always from the credential, device scope through
// findNoopDevice, query and body bounds, the exposure validator, error shapes, and that every route that
// existed before answers exactly as it did (an old server's 405 is what a new client treats as "context
// unavailable"). The database half is in physiology_context_sql_test.ts and exposure_events_sql_test.ts.
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import {
  EXPOSURE_MAX_BODY_BYTES,
  parseContextHistoryQuery,
  parseContextQuery,
  parseExposureReadQuery,
  validateExposureEvent,
} from '../_shared/physiologyContext.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';
const LOCAL = 'whoop-ABC123456';
const OTHER_LOCAL = 'whoop-ZZZ999999';
const DEVICE = noopDeviceId(USER, LOCAL);
const OTHER_DEVICE = noopDeviceId(OTHER, OTHER_LOCAL);
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };
const T0 = 1_791_000_000;

function event(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    event_id: 'caffeine-5f0d3f0e',
    revision: 1,
    kind: 'caffeine',
    label: 'Coffee',
    occurred: { start: T0, end: T0 + 1 },
    time_precision: 'exact',
    recorded_at: T0 + 60,
    source: 'user_entered',
    confirmation: 'confirmed',
    dose_amount: 95,
    dose_unit: 'mg',
    dose_provenance: 'user_entered',
    ...over,
  };
}

type Call = { name: string; args: any };

async function fixture(rpc: (call: Call) => any = () => null) {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'auth-a', token_hash: hashIngestToken('noop_auth_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
    { id: 'auth-b', token_hash: hashIngestToken('noop_auth_b'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet', user_id: USER, source_id: null },
  ]);
  await rest.upsert('noop_app_installations', [
    { user_id: USER, source_id: SOURCE },
    { user_id: OTHER, source_id: OTHER_SOURCE },
  ]);
  await rest.upsert('devices', [
    { id: DEVICE, user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL },
    { id: OTHER_DEVICE, user_id: OTHER, source_kind: 'noop_push', external_device_id: OTHER_LOCAL },
  ]);
  const calls: Call[] = [];
  rest.rpc = async (name: string, args: any) => {
    const call = { name, args };
    calls.push(call);
    return rpc(call);
  };
  return { rest, calls };
}

function request(path: string, { method = 'GET', bearer = 'noop_auth_a', body, raw, headers = {} }: {
  method?: string; bearer?: string | null; body?: unknown; raw?: string; headers?: Record<string, string>;
} = {}) {
  const all: Record<string, string> = { 'content-type': 'application/json', ...headers };
  if (bearer) all.authorization = `Bearer ${bearer}`;
  return new Request(`https://test.invalid/functions/v1/scores${path}`, {
    method, headers: all,
    body: method === 'GET' || method === 'HEAD' ? undefined : (raw ?? JSON.stringify(body ?? {})),
  });
}

// ------------------------------------------------------------------------------------------------------
// Query parsers and the exposure validator
// ------------------------------------------------------------------------------------------------------

Deno.test('context query: day is a real calendar day, mode and metric are optional and bounded', () => {
  const q = (text: string) => parseContextQuery(new URLSearchParams(text));
  assertEquals(q('day=2026-10-05'), { day: '2026-10-05', mode: null, metric: null });
  assertEquals(q('day=2026-10-05&mode=retrospective&metric=hrv_rmssd'),
    { day: '2026-10-05', mode: 'retrospective', metric: 'hrv_rmssd' });
  assertEquals(q('day=2026-10-05&mode=&metric='), { day: '2026-10-05', mode: null, metric: null });
  for (const [text, code] of [
    ['', 'invalid_day'], ['day=2026-02-30', 'invalid_day'], ['day=20261005', 'invalid_day'],
    ['day=2026-10-05T00:00:00Z', 'invalid_day'], ['day=2026-10-05&mode=live', 'invalid_mode'],
    ['day=2026-10-05&metric=HRV', 'invalid_metric'], ['day=2026-10-05&metric=hrv-rmssd', 'invalid_metric'],
    ['day=2026-10-05&metric=' + 'a'.repeat(49), 'invalid_metric'],
  ] as const) {
    try {
      q(text);
      throw new Error(`accepted ${text}`);
    } catch (error: any) {
      assertEquals([text, error.code, error.status], [text, code, 400]);
    }
  }
});

Deno.test('context history query: inclusive local days, at most 120', () => {
  const q = (text: string) => parseContextHistoryQuery(new URLSearchParams(text));
  assertEquals(q('from=2026-06-08&to=2026-10-05'), { from: '2026-06-08', to: '2026-10-05', mode: null });
  assertEquals(q('from=2026-10-05&to=2026-10-05&mode=causal_live').mode, 'causal_live');
  for (const text of ['from=2026-06-07&to=2026-10-05', 'from=2026-10-06&to=2026-10-05', 'from=2026-10-05',
    'from=x&to=2026-10-05', 'from=2026-10-01&to=2026-10-05&mode=nope']) {
    try {
      q(text);
      throw new Error(`accepted ${text}`);
    } catch (error: any) {
      assertEquals(error.status, 400, text);
    }
  }
});

Deno.test('exposure read query: unix seconds, half-open, at most 366 days; history flag is strict', () => {
  const q = (text: string) => parseExposureReadQuery(new URLSearchParams(text));
  assertEquals(q(`from=${T0}&to=${T0 + 86_400}`), { from: T0, to: T0 + 86_400, history: false });
  assertEquals(q(`from=${T0}&to=${T0 + 1}&history=1`).history, true);
  assertEquals(q(`from=${T0}&to=${T0 + 1}&history=true`).history, true);
  assertEquals(q(`from=${T0}&to=${T0 + 1}&history=0`).history, false);
  assertEquals(q(`from=${T0}&to=${T0 + 366 * 86_400}`).to, T0 + 366 * 86_400);
  for (const [text, code] of [
    [`from=${T0}&to=${T0}`, 'invalid_range'], [`from=${T0}&to=${T0 + 366 * 86_400 + 1}`, 'invalid_range'],
    [`from=-1&to=${T0}`, 'invalid_range'], [`to=${T0}`, 'invalid_range'], [`from=${T0}.5&to=${T0 + 9}`, 'invalid_range'],
    [`from=${T0}&to=${T0 + 1}&history=yes`, 'invalid_history'],
  ] as const) {
    try {
      q(text);
      throw new Error(`accepted ${text}`);
    } catch (error: any) {
      assertEquals([text, error.code], [text, code]);
    }
  }
});

Deno.test('exposure validator: a full event is normalised; unknown keys and a client received_at are dropped', () => {
  const checked = validateExposureEvent({ ...event(), received_at: 5, owner: OTHER, user_id: OTHER, extra: { a: 1 } });
  assert(checked.ok);
  assertEquals(checked.event, {
    event_id: 'caffeine-5f0d3f0e', revision: 1, kind: 'caffeine', label: 'Coffee',
    occurred: { start: T0, end: T0 + 1 }, time_precision: 'exact', recorded_at: T0 + 60,
    source: 'user_entered', confirmation: 'confirmed', dose_amount: 95, dose_unit: 'mg',
    dose_provenance: 'user_entered',
  });
  const minimal = validateExposureEvent(event({ dose_amount: undefined, dose_unit: null, dose_provenance: undefined }));
  assert(minimal.ok);
  assertEquals([minimal.event.dose_amount, minimal.event.dose_unit, minimal.event.dose_provenance], [null, null, null]);
});

Deno.test('exposure validator: every malformed field has its own reason code, matching the database', () => {
  const reasonOf = (raw: unknown) => {
    const checked = validateExposureEvent(raw);
    return checked.ok ? null : checked.rejection.reason;
  };
  const cases: Array<[unknown, string]> = [
    [null, 'invalid_event'], [[event()], 'invalid_event'], ['x', 'invalid_event'],
    [event({ event_id: '' }), 'invalid_event_id'], [event({ event_id: '-x' }), 'invalid_event_id'],
    [event({ event_id: 'a b' }), 'invalid_event_id'], [event({ event_id: 'a'.repeat(129) }), 'invalid_event_id'],
    [event({ event_id: 7 }), 'invalid_event_id'],
    [event({ revision: 0 }), 'invalid_revision'], [event({ revision: 1.5 }), 'invalid_revision'],
    [event({ revision: '1' }), 'invalid_revision'], [event({ revision: 2_147_483_648 }), 'invalid_revision'],
    [event({ kind: 'coffee' }), 'invalid_kind'],
    [event({ label: '' }), 'invalid_label'], [event({ label: 'x'.repeat(201) }), 'invalid_label'],
    [event({ label: 'a\nb' }), 'invalid_label'], [event({ label: 'a\u0000b' }), 'invalid_label'],
    [event({ label: 'a\ud800b' }), 'invalid_label'], [event({ label: 'a\u0085b' }), 'invalid_label'],
    [event({ occurred: null }), 'invalid_occurred'], [event({ occurred: { start: T0, end: T0 } }), 'invalid_occurred'],
    [event({ occurred: { start: T0, end: T0 + 31 * 86_400 + 1 } }), 'invalid_occurred'],
    [event({ occurred: { start: 946_684_799, end: 946_684_900 } }), 'invalid_occurred'],
    [event({ occurred: { start: 4_102_444_799, end: 4_102_444_801 } }), 'invalid_occurred'],
    [event({ occurred: { start: String(T0), end: T0 + 1 } }), 'invalid_occurred'],
    [event({ time_precision: 'minute' }), 'invalid_time_precision'],
    [event({ recorded_at: 946_684_799 }), 'invalid_recorded_at'], [event({ recorded_at: null }), 'invalid_recorded_at'],
    [event({ source: 'healthkit' }), 'invalid_source'],
    [event({ confirmation: 'yes' }), 'invalid_confirmation'],
    [event({ source: 'inferred_candidate', confirmation: 'confirmed' }), 'invalid_confirmation'],
    [event({ dose_amount: -1 }), 'invalid_dose_amount'], [event({ dose_amount: '95' }), 'invalid_dose_amount'],
    [event({ dose_amount: 1e9 + 1 }), 'invalid_dose_amount'],
    [event({ dose_unit: '' }), 'invalid_dose_unit'], [event({ dose_unit: 'm'.repeat(33) }), 'invalid_dose_unit'],
    [event({ dose_unit: 7 }), 'invalid_dose_unit'],
    [event({ dose_provenance: 'guess' }), 'invalid_dose_provenance'],
  ];
  for (const [raw, reason] of cases) assertEquals([JSON.stringify(raw), reasonOf(raw)], [JSON.stringify(raw), reason]);
  // Boundaries that are valid.
  for (const raw of [
    event({ label: 'x'.repeat(200), dose_unit: 'm'.repeat(32), revision: 2_147_483_647 }),
    event({ occurred: { start: T0, end: T0 + 31 * 86_400 } }), event({ dose_amount: 0 }), event({ dose_amount: 1e9 }),
    event({ source: 'inferred_candidate', confirmation: 'candidate' }), event({ label: 'Café 😀' }),
    event({ time_precision: 'day_only', source: 'journal_day_answer', confirmation: 'denied' }),
    event({ confirmation: 'retracted' }),
  ]) assertEquals(reasonOf(raw), null, JSON.stringify(raw));
  // A rejection echoes only a well-formed id and revision, never arbitrary client text.
  const rejected = validateExposureEvent(event({ event_id: '<script>', kind: 'nope' }));
  assertFalse(rejected.ok);
  if (!rejected.ok) assertEquals([rejected.rejection.event_id, rejected.rejection.revision], [null, 1]);
});

// ------------------------------------------------------------------------------------------------------
// GET /context and /context/history
// ------------------------------------------------------------------------------------------------------

Deno.test('GET /context: owner from the credential, device from deviceId, query forwarded, no-store', async () => {
  const context = { status: 'available', mode: 'retrospective', context_revision: 7 };
  const { rest, calls } = await fixture(() => context);
  const response = await handleScoresRequest(
    request(`/context?deviceId=${LOCAL}&day=2026-10-04&metric=hrv_rmssd&user_id=${OTHER}&p_user=${OTHER}`),
    { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  const body = await response.json();
  assertEquals(body.context, context);
  assertEquals(body.identity, { userId: USER, sourceId: SOURCE, deviceId: DEVICE, externalDeviceId: LOCAL, project: 'https://test.invalid' });
  assertEquals(calls, [{ name: 'physiology_context_read_v1', args: {
    p_user: USER, p_device: DEVICE, p_day: '2026-10-04', p_mode: null, p_metric: 'hrv_rmssd' } }]);
});

Deno.test('GET /context: the stored document passes through whole, spec-02 cardiac blocks included', async () => {
  // The route projects nothing: pulse_episodes and sleep.day_night_heart_rate (spec-02, CONTRACT §6) reach the
  // app exactly as the worker published them, so an app build that decodes them sees the persisted values.
  const document = {
    header: { policy_fingerprint: 'abc123', versions: { pulse: 'pc-pulse-1' } },
    sleep: {
      day_night_heart_rate: {
        state: 'supported', awake_median_bpm: 75, sleep_median_bpm: 55, difference_bpm: 20,
        percent_dip: 26.666666666666668,
        percent_dip_definition: '100*(awake_median_bpm-sleep_median_bpm)/awake_median_bpm',
        awake_samples: 50400, sleep_samples: 28800, awake_eligible_s: 61200, sleep_eligible_s: 28800,
        awake_coverage: 0.8235294117647058, sleep_coverage: 1, method: 'pc-day-night-hr-1', units: 'bpm',
        reasons: ['labels_read_heart_rate', 'percent_dip_definition', 'rhythm_proxy_only'],
      },
    },
    pulse_episodes: {
      version: 'pc-pulse-1', state: 'supported', units: 'bpm', qualified_inactive_s: 4500,
      episodes: [{ id: 'pulse_1', kind: 'sustained_high', interval: { start: T0, end: T0 + 900 }, duration_s: 900,
        median_bpm: 105, extreme_bpm: 105, qualified_s: 900, context: 'awake', censoring: ['episode_censored_gap'],
        reasons: ['pulse_episode_high'] }],
      acceleration_events: [], high_episode_count: 1, low_episode_count: 0,
      reasons: ['cause_not_attributed', 'not_rhythm_classification'],
    },
  };
  const context = { status: 'available', mode: 'retrospective', context_revision: 9, document, envelope_tables: [] };
  const { rest } = await fixture(() => context);
  const response = await handleScoresRequest(request(`/context?deviceId=${LOCAL}&day=2026-10-04`), { rest, cfg });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.context, context);
  assertEquals(body.context.document.pulse_episodes, document.pulse_episodes);
  assertEquals(body.context.document.sleep.day_night_heart_rate, document.sleep.day_night_heart_rate);
});

Deno.test('GET /context/history: bounded range forwarded with the resolved device', async () => {
  const { rest, calls } = await fixture(() => ({ days: [], daily_values: [], bouts: [], episodes: [] }));
  const ok = await handleScoresRequest(
    request(`/context/history?deviceId=${LOCAL}&from=2026-09-01&to=2026-10-05&mode=retrospective`), { rest, cfg });
  assertEquals(ok.status, 200);
  assertEquals(ok.headers.get('cache-control'), 'no-store');
  const body = await ok.json();
  assertEquals(Object.keys(body).sort(), ['history', 'identity']);
  assertEquals(calls, [{ name: 'physiology_context_history_read_v1', args: {
    p_user: USER, p_device: DEVICE, p_from: '2026-09-01', p_to: '2026-10-05', p_mode: 'retrospective' } }]);
  const tooLong = await handleScoresRequest(
    request(`/context/history?deviceId=${LOCAL}&from=2026-06-07&to=2026-10-05`), { rest, cfg });
  assertEquals([tooLong.status, await tooLong.json()], [400, { error: 'invalid_range' }]);
  assertEquals(calls.length, 1);
});

Deno.test('GET /context: another account\'s device, an unknown device or a bad device id never reach the database', async () => {
  const { rest, calls } = await fixture(() => ({ status: 'available' }));
  for (const [deviceId, status, error] of [
    [OTHER_LOCAL, 409, 'device_registration_pending'],
    ['whoop-NEVERSEEN1', 409, 'device_registration_pending'],
    ['', 400, 'invalid_device_id'],
    ['x@example.com', 400, 'invalid_device_id'],
  ] as const) {
    for (const path of [`/context?deviceId=${encodeURIComponent(deviceId)}&day=2026-10-04`,
      `/context/history?deviceId=${encodeURIComponent(deviceId)}&from=2026-10-01&to=2026-10-04`]) {
      const response = await handleScoresRequest(request(path), { rest, cfg });
      assertEquals([path, response.status, await response.json()], [path, status, { error }]);
    }
  }
  const missing = await handleScoresRequest(request('/context?day=2026-10-04'), { rest, cfg });
  assertEquals([missing.status, await missing.json()], [400, { error: 'invalid_device_id' }]);
  assertEquals(calls, []);
  // B's own credential reads B's device as B.
  const asB = await handleScoresRequest(request(`/context?deviceId=${OTHER_LOCAL}&day=2026-10-04`, { bearer: 'noop_auth_b' }),
    { rest, cfg });
  assertEquals(asB.status, 200);
  assertEquals([calls[0].args.p_user, calls[0].args.p_device], [OTHER, OTHER_DEVICE]);
});

Deno.test('GET /context: malformed queries are 400 with the shared error shape', async () => {
  const { rest, calls } = await fixture();
  for (const [query, error] of [
    ['day=2026-13-01', 'invalid_day'], ['', 'invalid_day'], ['day=2026-10-04&mode=both', 'invalid_mode'],
    ['day=2026-10-04&metric=%27x', 'invalid_metric'],
  ] as const) {
    const response = await handleScoresRequest(request(`/context?deviceId=${LOCAL}&${query}`), { rest, cfg });
    assertEquals([query, response.status, await response.json()], [query, 400, { error }]);
  }
  assertEquals(calls, []);
});

Deno.test('context and exposure routes: no credential, a wrong one, a fleet token or a revoked source cannot read or write', async () => {
  const { rest, calls } = await fixture(() => ({ status: 'saved', event_id: 'x', revision: 1, reason: null }));
  const paths: Array<[string, string, unknown?]> = [
    ['GET', `/context?deviceId=${LOCAL}&day=2026-10-04`],
    ['GET', `/context/history?deviceId=${LOCAL}&from=2026-10-01&to=2026-10-04`],
    ['GET', `/exposures?from=${T0}&to=${T0 + 1}`],
    ['POST', '/exposures', { events: [event()] }],
  ];
  for (const [method, path, body] of paths) {
    for (const bearer of [null, 'noop_unknown', 'noop_fleet']) {
      const response = await handleScoresRequest(request(path, { method, bearer, body }), { rest, cfg });
      assertEquals([method, path, bearer, response.status], [method, path, bearer, 401]);
    }
  }
  await rest.upsert('noop_app_installations', { user_id: USER, source_id: SOURCE, revoked_at: '2026-10-05T00:00:00Z' },
    { onConflict: 'source_id' });
  rest.tables.get('noop_ingest_tokens').find((row: any) => row.id === 'auth-a').revoked_at = '2026-10-05T00:00:00Z';
  for (const [method, path, body] of paths) {
    const response = await handleScoresRequest(request(path, { method, body }), { rest, cfg });
    assertEquals([method, path, response.status], [method, path, 401]);
  }
  assertEquals(calls, []);
});

Deno.test('context and exposure routes: a signed-in account needs its own registered source', async () => {
  const { rest, calls } = await fixture(() => ({ status: 'available' }));
  await rest.upsert('compute_account_sources', { user_id: USER, source_id: SOURCE, revoked_at: null });
  const fetchImpl = async () => Response.json({ id: USER });
  const account = (path: string, headers: Record<string, string>) =>
    request(path, { bearer: 'header.payload.signature', headers });
  const path = `/context?deviceId=${LOCAL}&day=2026-10-04`;
  assertEquals((await handleScoresRequest(account(path, { 'x-noop-source-id': SOURCE }), { rest, cfg, fetchImpl })).status, 200);
  assertEquals((await handleScoresRequest(account(path, {}), { rest, cfg, fetchImpl })).status, 401);
  assertEquals((await handleScoresRequest(account(path, { 'x-noop-source-id': OTHER_SOURCE }), { rest, cfg, fetchImpl })).status, 403);
  const exposures = await handleScoresRequest(account(`/exposures?from=${T0}&to=${T0 + 1}`, { 'x-noop-source-id': SOURCE }),
    { rest, cfg, fetchImpl });
  assertEquals(exposures.status, 200);
  assertEquals(calls.map((call) => [call.name, call.args.p_user ?? call.args.p_owner]),
    [['physiology_context_read_v1', USER], ['exposure_events_read_v1', USER]]);
});

// ------------------------------------------------------------------------------------------------------
// POST /exposures and GET /exposures
// ------------------------------------------------------------------------------------------------------

Deno.test('POST /exposures: owner and source from the credential; valid events reach the RPC in order, invalid ones are rejected individually', async () => {
  const { rest, calls } = await fixture(({ args }) => {
    if (args.p_event.event_id === 'dup') return { status: 'ignored', event_id: 'dup', revision: 1, reason: 'duplicate', received_at: T0 };
    if (args.p_event.event_id === 'conflict') return { status: 'rejected', event_id: 'conflict', revision: 2, reason: 'revision_conflict' };
    return { status: 'saved', event_id: args.p_event.event_id, revision: args.p_event.revision, reason: null, received_at: T0 + 99 };
  });
  const response = await handleScoresRequest(request('/exposures', { method: 'POST', body: {
    owner: OTHER, user_id: OTHER, p_owner: OTHER,
    events: [
      event({ event_id: 'a', received_at: 1 }),
      event({ event_id: 'bad', kind: 'coffee' }),
      event({ event_id: 'dup' }),
      event({ event_id: 'conflict', revision: 2 }),
      event({ event_id: 'b', revision: 3, owner: OTHER }),
    ],
  } }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  const body = await response.json();
  assertEquals(body.results, [
    { event_id: 'a', revision: 1, status: 'saved', reason: null, received_at: T0 + 99 },
    { event_id: 'bad', revision: 1, status: 'rejected', reason: 'invalid_kind' },
    { event_id: 'dup', revision: 1, status: 'ignored', reason: 'duplicate', received_at: T0 },
    { event_id: 'conflict', revision: 2, status: 'rejected', reason: 'revision_conflict', received_at: null },
    { event_id: 'b', revision: 3, status: 'saved', reason: null, received_at: T0 + 99 },
  ]);
  assertEquals(body.identity, { userId: USER, sourceId: SOURCE, deviceId: null, externalDeviceId: null, project: 'https://test.invalid' });
  assertEquals(calls.map((call) => call.args.p_event.event_id), ['a', 'dup', 'conflict', 'b']);
  for (const call of calls) {
    assertEquals(call.name, 'record_exposure_event_v1');
    assertEquals(Object.keys(call.args).sort(), ['p_event', 'p_owner', 'p_source']);
    assertEquals([call.args.p_owner, call.args.p_source], [USER, SOURCE]);
    assertFalse('received_at' in call.args.p_event || 'owner' in call.args.p_event);
  }
});

Deno.test('POST /exposures: envelope problems are 400 invalid_events and the database is not called', async () => {
  const { rest, calls } = await fixture(() => ({ status: 'saved' }));
  for (const [body, raw, error] of [
    [undefined, '{not json', 'invalid_body'], [undefined, '', 'invalid_body'],
    [{}, undefined, 'invalid_events'], [{ events: 'x' }, undefined, 'invalid_events'],
    [{ events: [] }, undefined, 'invalid_events'], [[event()], undefined, 'invalid_events'],
    [{ events: Array.from({ length: 26 }, (_, i) => event({ event_id: `e${i}` })) }, undefined, 'invalid_events'],
  ] as Array<[unknown, string | undefined, string]>) {
    const response = await handleScoresRequest(request('/exposures', { method: 'POST', body, raw }), { rest, cfg });
    assertEquals([raw ?? JSON.stringify(body).slice(0, 40), response.status, await response.json()],
      [raw ?? JSON.stringify(body).slice(0, 40), 400, { error }]);
  }
  assertEquals(calls, []);
  // 25 events is the limit and is accepted.
  const full = await handleScoresRequest(request('/exposures', { method: 'POST',
    body: { events: Array.from({ length: 25 }, (_, i) => event({ event_id: `e${i}` })) } }), { rest, cfg });
  assertEquals(full.status, 200);
  assertEquals(calls.length, 25);
});

Deno.test('POST /exposures: the body limit is 64 KiB for this route only; the other POST routes keep 8 KiB', async () => {
  const { rest, calls } = await fixture(({ args }) => ({ status: 'saved', event_id: args.p_event.event_id, revision: 1, reason: null }));
  const padded = { events: Array.from({ length: 25 }, (_, i) => event({ event_id: `e${i}`, label: 'x'.repeat(200) })),
    note: 'p'.repeat(40_000) };
  const bytes = new TextEncoder().encode(JSON.stringify(padded)).length;
  assert(bytes > 8192 && bytes < EXPOSURE_MAX_BODY_BYTES, String(bytes));
  const accepted = await handleScoresRequest(request('/exposures', { method: 'POST', body: padded }), { rest, cfg });
  assertEquals(accepted.status, 200);
  const oversized = await handleScoresRequest(request('/exposures', { method: 'POST',
    body: { events: [event()], note: 'p'.repeat(EXPOSURE_MAX_BODY_BYTES) } }), { rest, cfg });
  assertEquals([oversized.status, await oversized.json()], [413, { error: 'payload_too_large' }]);
  assertEquals(calls.length, 25);
  const placement = await handleScoresRequest(request('/placement', { method: 'POST',
    body: { placement: 'wrist', effective_start: '2026-10-01T00:00:00Z', pad: 'x'.repeat(9000) } }), { rest, cfg });
  assertEquals(placement.status, 413);
  const register = await handleScoresRequest(request('/devices', { method: 'POST',
    body: { deviceId: LOCAL, pad: 'x'.repeat(9000) } }), { rest, cfg });
  assertEquals(register.status, 413);
});

Deno.test('GET /exposures: owner-scoped, history only when asked', async () => {
  const read = { events: [{ event_id: 'a' }], revisions: [{ event_id: 'a', revision: 1 }], truncated: false };
  const { rest, calls } = await fixture(() => read);
  const plain = await handleScoresRequest(request(`/exposures?from=${T0}&to=${T0 + 86_400}&owner=${OTHER}`), { rest, cfg });
  assertEquals(plain.status, 200);
  assertEquals(plain.headers.get('cache-control'), 'no-store');
  const plainBody = await plain.json();
  assertEquals(Object.keys(plainBody).sort(), ['events', 'identity', 'truncated']);
  assertEquals(plainBody.events, read.events);
  const history = await handleScoresRequest(request(`/exposures?from=${T0}&to=${T0 + 86_400}&history=1`), { rest, cfg });
  assertEquals((await history.json()).revisions, read.revisions);
  assertEquals(calls.map((call) => call.args), [
    { p_owner: USER, p_from: T0, p_to: T0 + 86_400, p_include_history: false },
    { p_owner: USER, p_from: T0, p_to: T0 + 86_400, p_include_history: true },
  ]);
  const bad = await handleScoresRequest(request(`/exposures?from=${T0}`), { rest, cfg });
  assertEquals([bad.status, await bad.json()], [400, { error: 'invalid_range' }]);
});

// ------------------------------------------------------------------------------------------------------
// Errors and compatibility
// ------------------------------------------------------------------------------------------------------

Deno.test('context and exposure routes: database rejections keep their code; anything else is a generic 500', async () => {
  const authority = Object.assign(new Error('rejected'), { status: 403, code: 'device_owner_mismatch' });
  let failure: unknown = authority;
  const { rest } = await fixture(() => { throw failure; });
  const denied = await handleScoresRequest(request(`/context?deviceId=${LOCAL}&day=2026-10-04`), { rest, cfg });
  assertEquals([denied.status, await denied.json()], [403, { error: 'device_owner_mismatch' }]);
  failure = new Error('connection to db.internal:5432 refused; password=hunter2');
  for (const [method, path, body] of [
    ['GET', `/context?deviceId=${LOCAL}&day=2026-10-04`], ['GET', `/context/history?deviceId=${LOCAL}&from=2026-10-01&to=2026-10-04`],
    ['GET', `/exposures?from=${T0}&to=${T0 + 1}`], ['POST', '/exposures', { events: [event()] }],
  ] as Array<[string, string, unknown?]>) {
    const response = await handleScoresRequest(request(path, { method, body }), { rest, cfg });
    assertEquals([path, response.status, await response.json()], [path, 500, { error: 'scores_unavailable' }]);
  }
  // A record RPC that answers something unexpected is not reported as saved.
  failure = null;
  const odd = await fixture(() => ({ status: 'maybe' }));
  const response = await handleScoresRequest(request('/exposures', { method: 'POST', body: { events: [event()] } }), { rest: odd.rest, cfg });
  assertEquals(response.status, 500);
});

Deno.test('unsupported methods and near-miss paths stay 405 before any authentication', async () => {
  const { rest, calls } = await fixture();
  const cases: Array<[string, string]> = [
    ['POST', '/context'], ['PUT', '/context'], ['DELETE', '/context'], ['PATCH', '/context/history'],
    ['POST', '/context/history'], ['PUT', '/exposures'], ['DELETE', '/exposures'], ['PATCH', '/exposures'],
    ['GET', '/context/'], ['GET', '/contexts'], ['GET', '/context/history/'], ['GET', '/context/history/x'],
    ['GET', '/exposures/'], ['GET', '/exposure'], ['POST', '/exposures/batch'], ['GET', '/scores/context'],
    ['GET', '/physiology-context'], ['GET', '/stretch-feedback'], ['PUT', '/series'], ['POST', '/'],
  ];
  for (const [method, path] of cases) {
    const response = await handleScoresRequest(request(path, { method, bearer: null, body: {} }), { rest, cfg });
    assertEquals([method, path, response.status, await response.json()], [method, path, 405, { error: 'method_not_allowed' }]);
  }
  assertEquals(calls, []);
});

Deno.test('existing routes answer exactly as before', async () => {
  const { rest, calls } = await fixture(({ name }) => {
    if (name === 'server_metric_series_read') return { metrics: {} };
    if (name === 'server_scoring_for_device_day') return { status: 'pending' };
    if (name === 'set_placement_interval') return { id: 'p1', revision: 1 };
    if (name === 'server_pipeline_diagnostics') return { schema_version: 2 };
    if (name === 'server_result_days_page') return { days: [] };
    return null;
  });
  const series = await handleScoresRequest(request(`/series?deviceId=${LOCAL}&from=${T0}&to=${T0 + 3600}&metrics=hrv_rmssd_ms`), { rest, cfg });
  assertEquals(series.status, 200);
  assertEquals((await series.json()).series, { metrics: {} });
  const day = await handleScoresRequest(request(`/?deviceId=${LOCAL}&day=2026-10-04`), { rest, cfg });
  assertEquals(day.status, 200);
  const days = await handleScoresRequest(request(`/days?deviceId=${LOCAL}`), { rest, cfg });
  assertEquals(days.status, 200);
  const diagnostics = await handleScoresRequest(request(`/diagnostics?deviceId=${LOCAL}&day=2026-10-04`), { rest, cfg });
  assertEquals(diagnostics.status, 200);
  const placement = await handleScoresRequest(request('/placement', { method: 'POST',
    body: { placement: 'wrist', effective_start: '2026-10-01T00:00:00Z' } }), { rest, cfg });
  assertEquals([placement.status, await placement.json()], [200, { interval: { id: 'p1', revision: 1 } }]);
  const placements = await handleScoresRequest(request('/placement'), { rest, cfg });
  assertEquals([placements.status, await placements.json()], [200, { intervals: [] }]);
  const unregistered = await handleScoresRequest(request('/series?deviceId=whoop-NEVERSEEN1&from=1&to=2'), { rest, cfg });
  assertEquals([unregistered.status, await unregistered.json()], [409, { error: 'device_registration_pending' }]);
  assertEquals(calls.map((call) => call.name), ['server_metric_series_read', 'server_scoring_for_device_day',
    'server_result_days_page', 'server_pipeline_diagnostics', 'set_placement_interval']);
  assertEquals(calls[0].args, { p_user: USER, p_from: new Date(T0 * 1000).toISOString(),
    p_to: new Date((T0 + 3600) * 1000).toISOString(), p_metrics: ['hrv_rmssd_ms'] });
  assertEquals(calls[4].args, { p_owner: USER, p_placement: 'wrist', p_effective_start: '2026-10-01T00:00:00Z', p_device: null });
  assert(!calls.some((call) => /physiology|exposure/.test(call.name)), 'no existing route touches the context layer');
});
