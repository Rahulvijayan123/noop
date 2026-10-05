// POST /scores/stretch-feedback: the pure validator/normaliser, and the route against in-memory
// PostgREST doubles (auth, owner scoping, lenient device resolution, size limits, error shapes).
// The database half (RLS, the upsert RPC, last-writer-wins) is in stretch_feedback_sql_test.ts and the
// route against a real database in stretch_feedback_route_integration_test.ts.
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import {
  parseStretchFeedbackEnvelope,
  STRETCH_CORRECTED_LABELS,
  STRETCH_FEEDBACK_MAX_CONTEXT_BYTES,
  validateStretchFeedback,
  validateStretchFeedbackItem,
} from '../_shared/stretchFeedback.ts';
import { makeMemRest } from './helpers.ts';

const T0 = 1_760_072_000;
const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';
const LOCAL = 'whoop-ABC123456';
const OTHER_LOCAL = 'whoop-ZZZ999999';
const DEVICE = noopDeviceId(USER, LOCAL);
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };

function item(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11',
    stretch_key: `activity_context:${T0}`,
    kind: 'activity_context',
    device_id: LOCAL,
    start_ts: T0,
    end_ts: T0 + 900,
    predicted_label: 'Walking',
    predicted_class: 'walking',
    predicted_confidence: 0.82,
    verdict: 'incorrect',
    corrected_label: 'running',
    note: 'it was a jog',
    model_context: { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu', versions: { model: 'hart-1' } },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-04T16:00:00Z',
    client_updated_at: '2026-10-04T16:05:00.123Z',
    ...over,
  };
}

function reasonOf(over: Record<string, unknown>): string | null {
  const result = validateStretchFeedbackItem(item(over));
  return result.ok ? null : result.rejection.reason;
}

Deno.test('stretch feedback validator: a full item is normalised for the RPC', () => {
  const result = validateStretchFeedbackItem(item({ id: '5F0D3F0E-8F5A-4C8E-9D52-7D7A7F0C2A11' }));
  assert(result.ok);
  assertEquals(result.item, {
    client_id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11',
    stretch_key: `activity_context:${T0}`,
    kind: 'activity_context',
    external_device_id: LOCAL,
    device_id: null,
    start_ts: T0,
    end_ts: T0 + 900,
    predicted_label: 'Walking',
    predicted_class: 'walking',
    predicted_confidence: 0.82,
    verdict: 'incorrect',
    corrected_label: 'running',
    note: 'it was a jog',
    model_context: { probabilities: { walking: 0.82, running: 0.11 }, basis: 'imu', versions: { model: 'hart-1' } },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-04T16:00:00.000Z',
    client_updated_at: '2026-10-04T16:05:00.123Z',
  });
});

Deno.test('stretch feedback validator: optional fields may be null or absent', () => {
  const result = validateStretchFeedbackItem({
    id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11', stretch_key: 'strap_state:1760072000', kind: 'strap_state',
    start_ts: T0, end_ts: T0 + 60, predicted_label: 'Not wearing', verdict: 'correct',
    client_updated_at: '2026-10-04T16:05:00Z',
  });
  assert(result.ok);
  assertEquals(result.item.external_device_id, null);
  assertEquals(result.item.predicted_class, null);
  assertEquals(result.item.predicted_confidence, null);
  assertEquals(result.item.corrected_label, null);
  assertEquals(result.item.note, null);
  assertEquals(result.item.model_context, {});
  assertEquals(result.item.app_version, null);
  assertEquals(result.item.app_build, null);
  assertEquals(result.item.tz_offset_s, null);
  assertEquals(result.item.client_created_at, null);

  const nulls = validateStretchFeedbackItem(item({
    device_id: null, predicted_class: null, predicted_confidence: null, corrected_label: null, verdict: 'correct',
    note: null, app_version: null, app_build: null, tz_offset_s: null, client_created_at: null,
  }));
  assert(nulls.ok);
  assertEquals(nulls.item.corrected_label, null);
});

Deno.test('stretch feedback validator: envelope problems are a 400 invalid_feedback', () => {
  const tooMany = { feedback: Array.from({ length: 26 }, () => item()) };
  for (const body of [null, 'x', 7, [], [item()], {}, { feedback: null }, { feedback: 'x' }, { feedback: {} },
    { feedback: [] }, tooMany]) {
    let thrown: any;
    try { parseStretchFeedbackEnvelope(body); } catch (error) { thrown = error; }
    assertEquals([thrown?.code, thrown?.status], ['invalid_feedback', 400], JSON.stringify(body)?.slice(0, 40));
  }
  assertEquals(parseStretchFeedbackEnvelope({ feedback: Array.from({ length: 25 }, () => item()) }).length, 25);
  assertEquals(parseStretchFeedbackEnvelope({ feedback: [item()] }).length, 1);
});

Deno.test('stretch feedback validator: every malformed field has its own reason code', () => {
  const cases: Array<[string, Record<string, unknown>]> = [
    ['invalid_stretch_key', { stretch_key: '' }],
    ['invalid_stretch_key', { stretch_key: 'has space' }],
    ['invalid_stretch_key', { stretch_key: 'semi;colon' }],
    ['invalid_stretch_key', { stretch_key: 'k'.repeat(97) }],
    ['invalid_stretch_key', { stretch_key: 5 }],
    ['invalid_stretch_key', { stretch_key: undefined }],
    ['invalid_id', { id: 'not-a-uuid' }],
    ['invalid_id', { id: undefined }],
    ['invalid_kind', { kind: 'sleep' }],
    ['invalid_kind', { kind: undefined }],
    ['invalid_time_range', { start_ts: 946_684_800 }],
    ['invalid_time_range', { start_ts: 0 }],
    ['invalid_time_range', { start_ts: -5 }],
    ['invalid_time_range', { start_ts: `${T0}` }],
    ['invalid_time_range', { start_ts: T0 + 0.5 }],
    ['invalid_time_range', { end_ts: T0 }],
    ['invalid_time_range', { end_ts: T0 - 1 }],
    ['invalid_time_range', { end_ts: T0 + 86_401 }],
    ['invalid_time_range', { end_ts: undefined }],
    ['invalid_predicted_label', { predicted_label: '' }],
    ['invalid_predicted_label', { predicted_label: 'x'.repeat(65) }],
    ['invalid_predicted_label', { predicted_label: null }],
    ['invalid_predicted_label', { predicted_label: 'bad\u0000label' }],
    ['invalid_predicted_class', { predicted_class: 'x'.repeat(65) }],
    ['invalid_predicted_class', { predicted_class: 4 }],
    ['invalid_predicted_confidence', { predicted_confidence: 1.01 }],
    ['invalid_predicted_confidence', { predicted_confidence: -0.01 }],
    ['invalid_predicted_confidence', { predicted_confidence: '0.5' }],
    ['invalid_verdict', { verdict: 'maybe' }],
    ['invalid_verdict', { verdict: undefined }],
    ['invalid_corrected_label', { corrected_label: 'swimming' }],
    ['invalid_corrected_label', { corrected_label: 'Running' }],
    ['invalid_corrected_label', { corrected_label: 3 }],
    ['invalid_note', { note: 'n'.repeat(281) }],
    ['invalid_note', { note: 12 }],
    ['invalid_note', { note: 'a\u0000b' }],
    ['invalid_model_context', { model_context: null }],
    ['invalid_model_context', { model_context: [] }],
    ['invalid_model_context', { model_context: 'x' }],
    ['invalid_app_version', { app_version: 'v'.repeat(33) }],
    ['invalid_app_version', { app_version: 11 }],
    ['invalid_app_build', { app_build: 'b'.repeat(33) }],
    ['invalid_tz_offset', { tz_offset_s: 64_801 }],
    ['invalid_tz_offset', { tz_offset_s: -64_801 }],
    ['invalid_tz_offset', { tz_offset_s: 3600.5 }],
    ['invalid_tz_offset', { tz_offset_s: '3600' }],
    ['invalid_client_created_at', { client_created_at: 'yesterday' }],
    ['invalid_client_created_at', { client_created_at: 1_760_072_000 }],
    ['invalid_client_updated_at', { client_updated_at: undefined }],
    ['invalid_client_updated_at', { client_updated_at: null }],
    ['invalid_client_updated_at', { client_updated_at: '2026-10-04' }],
    ['invalid_client_updated_at', { client_updated_at: '2026-10-04T16:05:00' }],
  ];
  for (const [reason, over] of cases) {
    assertEquals(reasonOf(over), reason, JSON.stringify(over));
  }
});

Deno.test('stretch feedback validator: boundary values are accepted', () => {
  for (const over of [
    { start_ts: 946_684_801, end_ts: 946_684_802 },
    { end_ts: T0 + 86_400 },
    { stretch_key: 'k'.repeat(96) },
    { stretch_key: 'A-b_c.d:1' },
    { predicted_label: 'x'.repeat(64) },
    { predicted_class: 'c'.repeat(64) },
    { predicted_confidence: 0 },
    { predicted_confidence: 1 },
    { note: 'n'.repeat(280) },
    { app_version: 'v'.repeat(32), app_build: 'b'.repeat(32) },
    { tz_offset_s: 64_800 },
    { tz_offset_s: -64_800 },
    { tz_offset_s: 0 },
  ]) {
    assertEquals(reasonOf(over), null, JSON.stringify(over).slice(0, 80));
  }
});

Deno.test('stretch feedback validator: corrected_label is only for an incorrect verdict', () => {
  for (const label of STRETCH_CORRECTED_LABELS) {
    const accepted = validateStretchFeedbackItem(item({ verdict: 'incorrect', corrected_label: label }));
    assert(accepted.ok, label);
    assertEquals(accepted.item.corrected_label, label);
    assertEquals(reasonOf({ verdict: 'correct', corrected_label: label }), 'invalid_corrected_label', label);
  }
  assertEquals(STRETCH_CORRECTED_LABELS.length, 12);
  const incorrectWithoutLabel = validateStretchFeedbackItem(item({ verdict: 'incorrect', corrected_label: null }));
  assert(incorrectWithoutLabel.ok);
  assertEquals(incorrectWithoutLabel.item.corrected_label, null);
  const correct = validateStretchFeedbackItem(item({ verdict: 'correct', corrected_label: null }));
  assert(correct.ok);
  assertEquals(correct.item.corrected_label, null);
});

Deno.test('stretch feedback validator: note and labels are counted in code points like the database', () => {
  assertEquals(reasonOf({ note: '😀'.repeat(280) }), null);
  assertEquals(reasonOf({ note: '😀'.repeat(281) }), 'invalid_note');
  assertEquals(reasonOf({ predicted_label: 'é'.repeat(64) }), null);
  assertEquals(reasonOf({ note: 'lone \ud800 surrogate' }), 'invalid_note');
  assertEquals(reasonOf({ note: 'lone \udc00 surrogate' }), 'invalid_note');
  assertEquals(reasonOf({ note: '' }), null);
  const blank = validateStretchFeedbackItem(item({ note: '', predicted_class: '', app_version: '' }));
  assert(blank.ok);
  assertEquals([blank.item.note, blank.item.predicted_class, blank.item.app_version], [null, null, null]);
});

Deno.test('stretch feedback validator: model_context must be a bounded JSON object the database can store', () => {
  assertEquals(reasonOf({ model_context: {} }), null);
  assertEquals(reasonOf({ model_context: { a: [1, 2, { b: null, c: true, d: 'x' }] } }), null);

  const sized = (bytes: number) => {
    const base = JSON.stringify({ blob: '' }).length;
    return { blob: 'x'.repeat(bytes - base) };
  };
  assertEquals(new TextEncoder().encode(JSON.stringify(sized(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES))).length,
    STRETCH_FEEDBACK_MAX_CONTEXT_BYTES);
  assertEquals(reasonOf({ model_context: sized(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES) }), null);
  assertEquals(reasonOf({ model_context: sized(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES + 1) }), 'invalid_model_context');
  // The limit is on UTF-8 bytes, not characters.
  assertEquals(reasonOf({ model_context: { blob: 'é'.repeat(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES / 2) } }),
    'invalid_model_context');

  assertEquals(reasonOf({ model_context: { a: 'nul\u0000' } }), 'invalid_model_context');
  assertEquals(reasonOf({ model_context: { 'k\u0000': 1 } }), 'invalid_model_context');
  assertEquals(reasonOf({ model_context: { a: ['ok', 'bad \ud800'] } }), 'invalid_model_context');
  assertEquals(reasonOf({ model_context: { a: Infinity } }), 'invalid_model_context');
  assertEquals(reasonOf({ model_context: JSON.parse('{"a":1e999}') }), 'invalid_model_context');

  const nest = (depth: number) => {
    let value: unknown = 1;
    for (let level = 1; level <= depth; level++) value = { n: value };
    return value as Record<string, unknown>;
  };
  assertEquals(reasonOf({ model_context: nest(32) }), null);
  assertEquals(reasonOf({ model_context: nest(33) }), 'invalid_model_context');
});

Deno.test('stretch feedback validator: timestamps are checked field by field and normalised to UTC', () => {
  const normalised = (value: string) => {
    const result = validateStretchFeedbackItem(item({ client_updated_at: value }));
    return result.ok ? result.item.client_updated_at : null;
  };
  assertEquals(normalised('2026-10-04T16:05:00Z'), '2026-10-04T16:05:00.000Z');
  assertEquals(normalised('2026-10-04T16:05:00.5Z'), '2026-10-04T16:05:00.500Z');
  assertEquals(normalised('2026-10-04T16:05:00.123456789Z'), '2026-10-04T16:05:00.123Z');
  assertEquals(normalised('2026-10-04T09:05:00-07:00'), '2026-10-04T16:05:00.000Z');
  assertEquals(normalised('2026-10-04T21:35:00+05:30'), '2026-10-04T16:05:00.000Z');
  assertEquals(normalised('2028-02-29T00:00:00Z'), '2028-02-29T00:00:00.000Z');
  for (const bad of ['2026-02-30T00:00:00Z', '2026-13-01T00:00:00Z', '2026-00-10T00:00:00Z', '2027-02-29T00:00:00Z',
    '2026-10-04T24:00:00Z', '2026-10-04T16:60:00Z', '2026-10-04T16:05:60Z', '2026-10-04T16:05:00+24:00',
    '2026-10-04T16:05:00+05:60', '2026-10-04 16:05:00Z', '0000-01-01T00:00:00Z', '9999-12-31T23:59:59-01:00',
    '']) {
    assertEquals(normalised(bad), null, bad);
  }
});

Deno.test('stretch feedback validator: the device never fails an item', () => {
  const external = (value: unknown) => {
    const result = validateStretchFeedbackItem(item({ device_id: value }));
    assert(result.ok, JSON.stringify(value));
    return result.item.external_device_id;
  };
  assertEquals(external(LOCAL), LOCAL);
  assertEquals(external(undefined), null);
  assertEquals(external(null), null);
  assertEquals(external(''), null);
  assertEquals(external(42), null);
  assertEquals(external({ id: LOCAL }), null);
  assertEquals(external('x'.repeat(256)), null);
  assertEquals(external('someone@example.com'), null);
  assertEquals(external('+1 415 555 0100'), null);
  assertEquals(external('control\u0007char'), null);
  assertEquals(external('x'.repeat(255)), 'x'.repeat(255));
});

Deno.test('stretch feedback validator: items are judged individually and the owner is never read from them', () => {
  const { valid, rejected } = validateStretchFeedback({
    feedback: [
      item({ stretch_key: 'activity_context:1', verdict: 'incorrect' }),
      item({ stretch_key: 'activity_context:2', verdict: 'maybe' }),
      'not an object',
      null,
      item({ stretch_key: 'bad key', verdict: 'maybe' }),
      item({ stretch_key: 'activity_context:3', owner: OTHER, user_id: OTHER, revision: 99 }),
    ],
  });
  assertEquals(valid.map((entry) => entry.stretch_key), ['activity_context:1', 'activity_context:3']);
  assertEquals(rejected, [
    { stretch_key: 'activity_context:2', reason: 'invalid_verdict' },
    { stretch_key: null, reason: 'invalid_item' },
    { stretch_key: null, reason: 'invalid_item' },
    { stretch_key: null, reason: 'invalid_stretch_key' },
  ]);
  for (const entry of valid) {
    assertFalse('owner' in entry || 'user_id' in entry || 'revision' in entry || 'id' in entry);
  }
});

// ------------------------------------------------------------------------------------------------------
// The route, against in-memory PostgREST doubles.
// ------------------------------------------------------------------------------------------------------

async function fixture(rpcResult: any = { saved: [], ignored: [] }) {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'auth-a', token_hash: hashIngestToken('noop_auth_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
    { id: 'auth-b', token_hash: hashIngestToken('noop_auth_b'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: OTHER, source_id: OTHER_SOURCE },
  ]);
  await rest.upsert('noop_app_installations', [
    { user_id: USER, source_id: SOURCE },
    { user_id: OTHER, source_id: OTHER_SOURCE },
  ]);
  await rest.upsert('devices', [
    { id: DEVICE, user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL },
    { id: noopDeviceId(OTHER, OTHER_LOCAL), user_id: OTHER, source_kind: 'noop_push', external_device_id: OTHER_LOCAL },
  ]);
  const calls: Array<{ name: string; args: any }> = [];
  const deviceQueries: string[] = [];
  const select = rest.select.bind(rest);
  rest.select = async (table: string, query?: string) => {
    if (table === 'devices') deviceQueries.push(String(query));
    return select(table, query);
  };
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    return typeof rpcResult === 'function' ? rpcResult(args) : rpcResult;
  };
  return { rest, calls, deviceQueries };
}

function post(body: unknown, { path = '/stretch-feedback', method = 'POST', bearer = 'noop_auth_a', raw }: {
  path?: string; method?: string; bearer?: string | null; raw?: string;
} = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  return new Request(`https://test.invalid/functions/v1/scores${path}`, {
    method, headers,
    body: method === 'GET' ? undefined : (raw ?? JSON.stringify(body)),
  });
}

Deno.test('stretch feedback route: owner comes from the credential; valid items reach the RPC with the resolved device', async () => {
  const { rest, calls } = await fixture({
    saved: [{ stretch_key: 'activity_context:1', revision: 1 }, { stretch_key: 'activity_context:2', revision: 4 }],
    ignored: [{ stretch_key: 'activity_context:3', reason: 'stale' }],
  });
  const response = await handleScoresRequest(post({
    owner: OTHER, user_id: OTHER, p_owner: OTHER, device_id: 'whoop-ZZZ999999',
    feedback: [
      item({ stretch_key: 'activity_context:1' }),
      item({ stretch_key: 'activity_context:2', verdict: 'correct', corrected_label: null }),
      item({ stretch_key: 'activity_context:3' }),
      item({ stretch_key: 'activity_context:4', verdict: 'maybe' }),
    ],
  }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  assertEquals(await response.json(), {
    saved: [{ stretch_key: 'activity_context:1', revision: 1 }, { stretch_key: 'activity_context:2', revision: 4 }],
    ignored: [{ stretch_key: 'activity_context:3', reason: 'stale' }],
    rejected: [{ stretch_key: 'activity_context:4', reason: 'invalid_verdict' }],
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, 'upsert_activity_stretch_feedback');
  assertEquals(Object.keys(calls[0].args).sort(), ['p_items', 'p_owner']);
  assertEquals(calls[0].args.p_owner, USER);
  const sent = calls[0].args.p_items;
  assertEquals(sent.map((entry: any) => entry.stretch_key),
    ['activity_context:1', 'activity_context:2', 'activity_context:3']);
  for (const entry of sent) {
    assertEquals([entry.device_id, entry.external_device_id], [DEVICE, LOCAL]);
    assertFalse('owner' in entry || 'user_id' in entry || 'id' in entry);
    assertEquals(entry.client_id, '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11');
  }
});

Deno.test('stretch feedback route: an unresolvable device is stored as no device and the item is kept', async () => {
  const { rest, calls, deviceQueries } = await fixture((args: any) => ({
    saved: args.p_items.map((entry: any) => ({ stretch_key: entry.stretch_key, revision: 1 })), ignored: [],
  }));
  const response = await handleScoresRequest(post({
    feedback: [
      item({ stretch_key: 'activity_context:1', device_id: 'whoop-NEVERSEEN1' }),
      item({ stretch_key: 'activity_context:2', device_id: OTHER_LOCAL }),
      item({ stretch_key: 'activity_context:3', device_id: null }),
      item({ stretch_key: 'activity_context:4', device_id: 'x@example.com' }),
      item({ stretch_key: 'activity_context:5', device_id: LOCAL }),
      item({ stretch_key: 'activity_context:6', device_id: LOCAL }),
    ],
  }), { rest, cfg });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.saved.length, 6);
  assertEquals(body.rejected, []);
  const sent = calls[0].args.p_items;
  assertEquals(sent.map((entry: any) => [entry.device_id, entry.external_device_id]), [
    [null, 'whoop-NEVERSEEN1'],
    [null, OTHER_LOCAL],
    [null, null],
    [null, null],
    [DEVICE, LOCAL],
    [DEVICE, LOCAL],
  ]);
  // One look-up per distinct device, not per item, and always scoped to the caller.
  assertEquals(deviceQueries.length, 3);
  assert(deviceQueries.every((query) => query.includes(`user_id=eq.${USER}`)));
});

Deno.test('stretch feedback route: when every item is rejected the database is not called', async () => {
  const { rest, calls } = await fixture();
  const response = await handleScoresRequest(post({
    feedback: [item({ verdict: 'maybe' }), { nonsense: true }],
  }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    saved: [], ignored: [],
    rejected: [{ stretch_key: `activity_context:${T0}`, reason: 'invalid_verdict' }, { stretch_key: null, reason: 'invalid_stretch_key' }],
  });
  assertEquals(calls, []);
});

Deno.test('stretch feedback route: malformed envelopes are 400 with the shared error shape', async () => {
  const { rest, calls } = await fixture();
  const cases: Array<[unknown, string | undefined, string]> = [
    [undefined, '{not json', 'invalid_body'],
    [undefined, '', 'invalid_body'],
    [{}, undefined, 'invalid_feedback'],
    [{ feedback: 'x' }, undefined, 'invalid_feedback'],
    [{ feedback: [] }, undefined, 'invalid_feedback'],
    [[item()], undefined, 'invalid_feedback'],
    [null, undefined, 'invalid_feedback'],
    [{ feedback: Array.from({ length: 26 }, (_, index) => item({ stretch_key: `k:${index}` })) }, undefined, 'invalid_feedback'],
  ];
  for (const [body, raw, error] of cases) {
    const response = await handleScoresRequest(post(body, { raw }), { rest, cfg });
    assertEquals(response.status, 400, error);
    assertEquals(await response.json(), { error });
  }
  assertEquals(calls, []);
});

Deno.test('stretch feedback route: the body limit is 128 KiB, not the 8 KiB of the other POST routes', async () => {
  const { rest, calls } = await fixture((args: any) => ({
    saved: args.p_items.map((entry: any) => ({ stretch_key: entry.stretch_key, revision: 1 })), ignored: [],
  }));
  const big = (index: number) => item({
    stretch_key: `activity_context:${index}`, model_context: { blob: 'x'.repeat(STRETCH_FEEDBACK_MAX_CONTEXT_BYTES - 20) },
  });
  const accepted = { feedback: Array.from({ length: 6 }, (_, index) => big(index)) };
  const acceptedBytes = new TextEncoder().encode(JSON.stringify(accepted)).length;
  assert(acceptedBytes > 8192 && acceptedBytes < 128 * 1024, String(acceptedBytes));
  const ok = await handleScoresRequest(post(accepted), { rest, cfg });
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).saved.length, 6);

  const oversized = { feedback: [item({ note: 'x'.repeat(128 * 1024) })] };
  const refused = await handleScoresRequest(post(oversized), { rest, cfg });
  assertEquals(refused.status, 413);
  assertEquals(await refused.json(), { error: 'payload_too_large' });
  assertEquals(calls.length, 1);

  // The other body-carrying routes keep their own 8 KiB limit.
  const placement = await handleScoresRequest(post({ placement: 'wrist', effective_start: '2026-10-01T00:00:00Z',
    pad: 'x'.repeat(9000) }, { path: '/placement' }), { rest, cfg });
  assertEquals(placement.status, 413);
});

Deno.test('stretch feedback route: no credential, a wrong credential or another account cannot write', async () => {
  const { rest, calls } = await fixture();
  const body = { feedback: [item()] };
  assertEquals((await handleScoresRequest(post(body, { bearer: null }), { rest, cfg })).status, 401);
  assertEquals((await handleScoresRequest(post(body, { bearer: 'noop_unknown' }), { rest, cfg })).status, 401);
  assertEquals((await handleScoresRequest(post(body, { bearer: 'noop_fleet' }), { rest, cfg })).status, 401);
  assertEquals(calls, []);
  // B's credential writes as B, never as A, whatever the body claims.
  const other = await handleScoresRequest(post({ ...body, owner: USER }, { bearer: 'noop_auth_b' }), { rest, cfg });
  assertEquals(other.status, 200);
  assertEquals(calls.map((call) => call.args.p_owner), [OTHER]);
  assertEquals(calls[0].args.p_items[0].device_id, null);
  assertEquals(calls[0].args.p_items[0].external_device_id, LOCAL);
});

Deno.test('stretch feedback route: a signed-in account is accepted with its registered source, and only then', async () => {
  const { rest, calls } = await fixture({ saved: [{ stretch_key: `activity_context:${T0}`, revision: 1 }], ignored: [] });
  await rest.upsert('compute_account_sources', { user_id: USER, source_id: SOURCE, revoked_at: null });
  const account = (headers: Record<string, string>) => {
    const request = post({ feedback: [item()] }, { bearer: 'header.payload.signature' });
    for (const [key, value] of Object.entries(headers)) request.headers.set(key, value);
    return request;
  };
  const fetchImpl = async () => Response.json({ id: USER });
  const accepted = await handleScoresRequest(account({ 'x-noop-source-id': SOURCE }), { rest, cfg, fetchImpl });
  assertEquals(accepted.status, 200);
  assertEquals(calls.map((call) => call.args.p_owner), [USER]);
  assertEquals((await handleScoresRequest(account({}), { rest, cfg, fetchImpl })).status, 401);
  assertEquals((await handleScoresRequest(account({ 'x-noop-source-id': OTHER_SOURCE }), { rest, cfg, fetchImpl })).status, 403);
  assertEquals(calls.length, 1);
});

Deno.test('stretch feedback route: unsupported methods and paths behave like the other routes', async () => {
  const { rest, calls } = await fixture();
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE']) {
    const response = await handleScoresRequest(post({ feedback: [item()] }, { method }), { rest, cfg });
    assertEquals([method, response.status], [method, 405]);
    assertEquals(await response.json(), { error: 'method_not_allowed' });
  }
  for (const path of ['/stretch-feedback/', '/stretch-feedbacks', '/stretch_feedback']) {
    const response = await handleScoresRequest(post({ feedback: [item()] }, { path }), { rest, cfg });
    assertEquals([path, response.status], [path, 405]);
  }
  assertEquals(calls, []);
});

Deno.test('stretch feedback route: a database failure is a generic 500 that leaks nothing', async () => {
  const { rest } = await fixture(() => { throw new Error('connection to db.internal:5432 refused; password=hunter2'); });
  const response = await handleScoresRequest(post({ feedback: [item()] }), { rest, cfg });
  assertEquals(response.status, 500);
  assertEquals(await response.json(), { error: 'scores_unavailable' });
});
