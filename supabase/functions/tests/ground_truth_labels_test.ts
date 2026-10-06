// POST /scores/ground-truth-labels: the pure validator/normaliser, and the route against in-memory
// PostgREST doubles (auth, owner scoping, lenient device resolution, size limits, error shapes).
// The database half (RLS, the upsert RPC, last-writer-wins, raw_refs enrichment) is in
// ground_truth_labels_sql_test.ts and the route against a real database in
// ground_truth_labels_route_integration_test.ts.
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import {
  GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES,
  GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES,
  GROUND_TRUTH_SEMANTIC_TAGS,
  GROUND_TRUTH_SOURCES,
  parseGroundTruthLabelsEnvelope,
  validateGroundTruthLabelItem,
  validateGroundTruthLabels,
} from '../_shared/groundTruthLabels.ts';
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
    label_key: `guided:activity-session:${T0}`,
    source: 'guided',
    device_id: LOCAL,
    start_ts: T0,
    end_ts: T0 + 900,
    posture: 'seated_likely',
    locomotion: 'stationary',
    arm_behavior: 'desk_like',
    transition_kind: null,
    transition_ts: null,
    semantic_tag: 'desk_work',
    label_confidence: 0.92,
    user_unsure: false,
    note: 'desk session',
    cue_context: { instruction_ts: T0 - 30, cue_start_ts: T0, cue_stop_ts: T0 + 900 },
    sensor_quality: { expected_seconds: 900, covered_seconds: 900, sample_rate_hz: 100, gaps: [] },
    raw_refs: [{ store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }],
    model_context_at_label_time: { decoder: 'hsmm-1.3', display: 'Desk sitting' },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-07T16:00:00Z',
    client_updated_at: '2026-10-07T16:05:00.123Z',
    ...over,
  };
}

function reasonOf(over: Record<string, unknown>): string | null {
  const result = validateGroundTruthLabelItem(item(over));
  return result.ok ? null : result.rejection.reason;
}

Deno.test('ground truth validator: a full item is normalised for the RPC', () => {
  const result = validateGroundTruthLabelItem(item({ id: '5F0D3F0E-8F5A-4C8E-9D52-7D7A7F0C2A11' }));
  assert(result.ok);
  assertEquals(result.item, {
    client_id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11',
    label_key: `guided:activity-session:${T0}`,
    source: 'guided',
    session_id: null,
    protocol_version: null,
    repetition: null,
    external_device_id: LOCAL,
    device_id: null,
    start_ts: T0,
    end_ts: T0 + 900,
    posture: 'seated_likely',
    locomotion: 'stationary',
    arm_behavior: 'desk_like',
    transition_kind: null,
    transition_ts: null,
    semantic_tag: 'desk_work',
    label_confidence: 0.92,
    user_unsure: false,
    note: 'desk session',
    cue_context: { instruction_ts: T0 - 30, cue_start_ts: T0, cue_stop_ts: T0 + 900 },
    sensor_quality: { expected_seconds: 900, covered_seconds: 900, sample_rate_hz: 100, gaps: [] },
    raw_refs: [{ store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }],
    model_context_at_label_time: { decoder: 'hsmm-1.3', display: 'Desk sitting' },
    app_version: '11.8.0',
    app_build: '431',
    tz_offset_s: -25200,
    client_created_at: '2026-10-07T16:00:00.000Z',
    client_updated_at: '2026-10-07T16:05:00.123Z',
  });
});

Deno.test('ground truth validator: optional fields may be null or absent', () => {
  const result = validateGroundTruthLabelItem({
    id: '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11',
    label_key: 'stretch_feedback:activity_context:1760072000',
    source: 'stretch_feedback',
    start_ts: T0, end_ts: T0 + 60,
    posture: 'recumbent', locomotion: 'stationary', arm_behavior: 'quiet',
    client_updated_at: '2026-10-07T16:05:00Z',
  });
  assert(result.ok);
  assertEquals(result.item.external_device_id, null);
  assertEquals(result.item.session_id, null);
  assertEquals(result.item.protocol_version, null);
  assertEquals(result.item.repetition, null);
  assertEquals(result.item.posture, 'recumbent');
  assertEquals(result.item.locomotion, 'stationary');
  assertEquals(result.item.arm_behavior, 'quiet');
  assertEquals(result.item.transition_kind, null);
  assertEquals(result.item.transition_ts, null);
  assertEquals(result.item.semantic_tag, null);
  assertEquals(result.item.label_confidence, null);
  assertEquals(result.item.user_unsure, false);
  assertEquals(result.item.note, null);
  assertEquals(result.item.cue_context, {});
  assertEquals(result.item.sensor_quality, {});
  assertEquals(result.item.raw_refs, []);
  assertEquals(result.item.model_context_at_label_time, {});
  assertEquals(result.item.app_version, null);
  assertEquals(result.item.app_build, null);
  assertEquals(result.item.tz_offset_s, null);
  assertEquals(result.item.client_created_at, null);

  const nulls = validateGroundTruthLabelItem(item({
    device_id: null, posture: null, locomotion: null, arm_behavior: null, transition_kind: null,
    transition_ts: null, semantic_tag: null, label_confidence: null, user_unsure: null,
    note: null, app_version: null, app_build: null, tz_offset_s: null, client_created_at: null,
  }));
  assert(nulls.ok);
  assertEquals(nulls.item.user_unsure, false);
  assertEquals(nulls.item.posture, null);
  assertEquals(nulls.item.raw_refs, [{ store_session_id: 'activity-device', start_ts: T0, end_ts: T0 + 900, sample_rate_hz: 100, covered_seconds: 900 }]);
});

Deno.test('ground truth validator: envelope problems are a 400 invalid_labels', () => {
  const tooMany = { labels: Array.from({ length: 26 }, () => item()) };
  for (const body of [null, 'x', 7, [], [item()], {}, { labels: null }, { labels: 'x' }, { labels: {} },
    { labels: [] }, tooMany]) {
    let thrown: any;
    try { parseGroundTruthLabelsEnvelope(body); } catch (error) { thrown = error; }
    assertEquals([thrown?.code, thrown?.status], ['invalid_labels', 400], JSON.stringify(body)?.slice(0, 40));
  }
  assertEquals(parseGroundTruthLabelsEnvelope({ labels: Array.from({ length: 25 }, () => item()) }).length, 25);
  assertEquals(parseGroundTruthLabelsEnvelope({ labels: [item()] }).length, 1);
});

Deno.test('ground truth validator: every malformed field has its own reason code', () => {
  const cases: Array<[string, Record<string, unknown>]> = [
    ['invalid_label_key', { label_key: '' }],
    ['invalid_label_key', { label_key: 'has space' }],
    ['invalid_label_key', { label_key: 'semi;colon' }],
    ['invalid_label_key', { label_key: 'k'.repeat(97) }],
    ['invalid_label_key', { label_key: 5 }],
    ['invalid_label_key', { label_key: undefined }],
    ['invalid_id', { id: 'not-a-uuid' }],
    ['invalid_id', { id: undefined }],
    ['invalid_source', { source: 'sleep' }],
    ['invalid_source', { source: undefined }],
    ['invalid_time_range', { start_ts: 946_684_800 }],
    ['invalid_time_range', { start_ts: 0 }],
    ['invalid_time_range', { start_ts: -5 }],
    ['invalid_time_range', { start_ts: `${T0}` }],
    ['invalid_time_range', { start_ts: T0 + 0.5 }],
    ['invalid_time_range', { end_ts: T0 }],
    ['invalid_time_range', { end_ts: T0 - 1 }],
    ['invalid_time_range', { end_ts: T0 + 86_401 }],
    ['invalid_time_range', { end_ts: undefined }],
    ['invalid_session_id', { session_id: 's'.repeat(65) }],
    ['invalid_session_id', { session_id: 5 }],
    ['invalid_session_id', { session_id: 'bad\u0000id' }],
    ['invalid_protocol_version', { protocol_version: 'v'.repeat(33) }],
    ['invalid_protocol_version', { protocol_version: 5 }],
    ['invalid_repetition', { repetition: -1 }],
    ['invalid_repetition', { repetition: 1.5 }],
    ['invalid_repetition', { repetition: '2' }],
    ['invalid_posture', { posture: 'standing' }],
    ['invalid_posture', { posture: 3 }],
    ['invalid_locomotion', { locomotion: 'sitting' }],
    ['invalid_locomotion', { locomotion: 3 }],
    ['invalid_arm_behavior', { arm_behavior: 'typing' }],
    ['invalid_arm_behavior', { arm_behavior: 3 }],
    // Ground-truth transition kinds are definitive; the model's _like kinds are not labels.
    ['invalid_transition_kind', { transition_kind: 'sit_to_stand_like' }],
    ['invalid_transition_kind', { transition_kind: 'walk_start_like' }],
    ['invalid_transition_kind', { transition_kind: 3 }],
    ['invalid_transition_ts', { transition_ts: T0 - 1 }],
    ['invalid_transition_ts', { transition_ts: T0 + 901 }],
    ['invalid_transition_ts', { transition_ts: T0 + 0.5 }],
    ['invalid_transition_ts', { transition_ts: `${T0 + 10}` }],
    ['invalid_semantic_tag', { semantic_tag: 'running' }],
    ['invalid_semantic_tag', { semantic_tag: 3 }],
    ['invalid_label_confidence', { label_confidence: 1.01 }],
    ['invalid_label_confidence', { label_confidence: -0.01 }],
    ['invalid_label_confidence', { label_confidence: '0.5' }],
    ['invalid_user_unsure', { user_unsure: 'yes' }],
    ['invalid_user_unsure', { user_unsure: 1 }],
    ['invalid_note', { note: 'n'.repeat(281) }],
    ['invalid_note', { note: 12 }],
    ['invalid_note', { note: 'a\u0000b' }],
    ['invalid_cue_context', { cue_context: null }],
    ['invalid_cue_context', { cue_context: [] }],
    ['invalid_cue_context', { cue_context: 'x' }],
    ['invalid_sensor_quality', { sensor_quality: null }],
    ['invalid_sensor_quality', { sensor_quality: [] }],
    ['invalid_sensor_quality', { sensor_quality: 'x' }],
    ['invalid_raw_refs', { raw_refs: null }],
    ['invalid_raw_refs', { raw_refs: {} }],
    ['invalid_raw_refs', { raw_refs: 'x' }],
    ['invalid_raw_refs', { raw_refs: [5] }],
    ['invalid_raw_refs', { raw_refs: [null] }],
    ['invalid_raw_refs', { raw_refs: [{ store_session_id: 'a\u0000b' }] }],
    ['invalid_model_context_at_label_time', { model_context_at_label_time: null }],
    ['invalid_model_context_at_label_time', { model_context_at_label_time: [] }],
    ['invalid_model_context_at_label_time', { model_context_at_label_time: 'x' }],
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
    ['invalid_client_updated_at', { client_updated_at: '2026-10-07' }],
    ['invalid_client_updated_at', { client_updated_at: '2026-10-07T16:05:00' }],
  ];
  for (const [reason, over] of cases) {
    assertEquals(reasonOf(over), reason, JSON.stringify(over));
  }
});

Deno.test('ground truth validator: boundary values are accepted', () => {
  for (const over of [
    { start_ts: 946_684_801, end_ts: 946_684_802 },
    { end_ts: T0 + 86_400 },
    { label_key: 'k'.repeat(96) },
    { label_key: 'A-b_c.d:1' },
    { session_id: 's'.repeat(64) },
    { protocol_version: 'v'.repeat(32) },
    { repetition: 0 },
    { repetition: 1_000_000 },
    { transition_ts: T0 },
    { transition_ts: T0 + 900 },
    { label_confidence: 0 },
    { label_confidence: 1 },
    { user_unsure: true },
    { note: 'n'.repeat(280) },
    { app_version: 'v'.repeat(32), app_build: 'b'.repeat(32) },
    { tz_offset_s: 64_800 },
    { tz_offset_s: -64_800 },
    { tz_offset_s: 0 },
  ]) {
    assertEquals(reasonOf(over), null, JSON.stringify(over).slice(0, 80));
  }
});

Deno.test('ground truth validator: every vocabulary value is accepted and everything else is not', () => {
  // Source.
  for (const source of GROUND_TRUTH_SOURCES) {
    const accepted = validateGroundTruthLabelItem(item({ source }));
    assert(accepted.ok, source);
    assertEquals(accepted.item.source, source);
  }
  assertEquals(GROUND_TRUTH_SOURCES.length, 3);
  // Posture.
  for (const posture of ['recumbent', 'seated_likely', 'upright_stationary', 'postural_transition', 'unknown']) {
    assertEquals(reasonOf({ posture }), null, posture);
  }
  assertEquals(reasonOf({ posture: 'standing' }), 'invalid_posture');
  // Locomotion.
  for (const locomotion of ['stationary', 'walking', 'brisk_walking', 'running', 'stairs', 'cycling', 'vehicle_motion', 'other', 'unknown']) {
    assertEquals(reasonOf({ locomotion }), null, locomotion);
  }
  assertEquals(reasonOf({ locomotion: 'sitting' }), 'invalid_locomotion');
  // Arm behavior.
  for (const armBehavior of ['quiet', 'desk_like', 'fidgeting', 'repetitive_hand_motion', 'active_gesturing', 'exercise_motion', 'other', 'unknown']) {
    assertEquals(reasonOf({ arm_behavior: armBehavior }), null, armBehavior);
  }
  assertEquals(reasonOf({ arm_behavior: 'typing' }), 'invalid_arm_behavior');
  // Transition kinds are the definitive ground-truth set, never the _like model kinds.
  for (const kind of ['sit_to_stand', 'stand_to_sit', 'lying_down', 'getting_up', 'walk_start', 'walk_stop', 'run_start', 'run_stop']) {
    assertEquals(reasonOf({ transition_kind: kind }), null, kind);
  }
  assertEquals(reasonOf({ transition_kind: 'sit_to_stand_like' }), 'invalid_transition_kind');
  assertEquals(reasonOf({ transition_kind: 'walk_stop_like' }), 'invalid_transition_kind');
  // Semantic tags.
  for (const tag of GROUND_TRUTH_SEMANTIC_TAGS) {
    assertEquals(reasonOf({ semantic_tag: tag }), null, tag);
  }
  assertEquals(GROUND_TRUTH_SEMANTIC_TAGS.length, 8);
  assertEquals(reasonOf({ semantic_tag: 'running' }), 'invalid_semantic_tag');
});

Deno.test('ground truth validator: note and labels are counted in code points like the database', () => {
  assertEquals(reasonOf({ note: '😀'.repeat(280) }), null);
  assertEquals(reasonOf({ note: '😀'.repeat(281) }), 'invalid_note');
  assertEquals(reasonOf({ session_id: 'é'.repeat(64) }), null);
  assertEquals(reasonOf({ note: 'lone \ud800 surrogate' }), 'invalid_note');
  assertEquals(reasonOf({ note: 'lone \udc00 surrogate' }), 'invalid_note');
  assertEquals(reasonOf({ note: '' }), null);
  const blank = validateGroundTruthLabelItem(item({ note: '', session_id: '', protocol_version: '', app_version: '' }));
  assert(blank.ok);
  assertEquals([blank.item.note, blank.item.session_id, blank.item.protocol_version, blank.item.app_version],
    [null, null, null, null]);
});

Deno.test('ground truth validator: jsonb fields must be bounded JSON objects the database can store', () => {
  const fieldCases: Array<[string, string, Record<string, unknown>]> = [
    ['cue_context', 'invalid_cue_context', { cue_context: {} }],
    ['sensor_quality', 'invalid_sensor_quality', { sensor_quality: {} }],
    ['model_context_at_label_time', 'invalid_model_context_at_label_time', { model_context_at_label_time: {} }],
  ];
  const sized = (bytes: number) => {
    const base = JSON.stringify({ blob: '' }).length;
    return { blob: 'x'.repeat(bytes - base) };
  };
  for (const [field, reason, over] of fieldCases) {
    assertEquals(reasonOf(over), null, field);
    assertEquals(reasonOf({ [field]: { a: [1, 2, { b: null, c: true, d: 'x' }] } }), null, field);
    assertEquals(new TextEncoder().encode(JSON.stringify(sized(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES))).length,
      GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES);
    assertEquals(reasonOf({ [field]: sized(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES) }), null, field);
    assertEquals(reasonOf({ [field]: sized(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES + 1) }), reason, field);
    assertEquals(reasonOf({ [field]: { blob: 'é'.repeat(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES / 2) } }), reason, field);
    assertEquals(reasonOf({ [field]: { a: 'nul\u0000' } }), reason, field);
    assertEquals(reasonOf({ [field]: { 'k\u0000': 1 } }), reason, field);
    assertEquals(reasonOf({ [field]: { a: ['ok', 'bad \ud800'] } }), reason, field);
    assertEquals(reasonOf({ [field]: { a: Infinity } }), reason, field);
    assertEquals(reasonOf({ [field]: JSON.parse('{"a":1e999}') }), reason, field);
  }
  const nest = (depth: number) => {
    let value: unknown = 1;
    for (let level = 1; level <= depth; level++) value = { n: value };
    return value as Record<string, unknown>;
  };
  assertEquals(reasonOf({ cue_context: nest(32) }), null);
  assertEquals(reasonOf({ cue_context: nest(33) }), 'invalid_cue_context');
  assertEquals(reasonOf({ model_context_at_label_time: nest(32) }), null);
  assertEquals(reasonOf({ model_context_at_label_time: nest(33) }), 'invalid_model_context_at_label_time');
});

Deno.test('ground truth validator: raw_refs must be a bounded array of plain objects', () => {
  assertEquals(reasonOf({ raw_refs: [] }), null);
  assertEquals(reasonOf({ raw_refs: [{ store_session_id: 's', start_ts: T0, end_ts: T0 + 10 }] }), null);
  assertEquals(reasonOf({ raw_refs: [{ a: [1, 2, { b: null }] }] }), null);
  const sized = (bytes: number) => {
    const base = JSON.stringify([{ store_session_id: '' }]).length;
    return [{ store_session_id: 'x'.repeat(bytes - base) }];
  };
  assertEquals(new TextEncoder().encode(JSON.stringify(sized(GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES))).length,
    GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES);
  assertEquals(reasonOf({ raw_refs: sized(GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES) }), null);
  assertEquals(reasonOf({ raw_refs: sized(GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES + 1) }), 'invalid_raw_refs');
  assertEquals(reasonOf({ raw_refs: [{ store_session_id: 'x'.repeat(GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES) }] }),
    'invalid_raw_refs');
});

Deno.test('ground truth validator: timestamps are checked field by field and normalised to UTC', () => {
  const normalised = (value: string) => {
    const result = validateGroundTruthLabelItem(item({ client_updated_at: value }));
    return result.ok ? result.item.client_updated_at : null;
  };
  assertEquals(normalised('2026-10-07T16:05:00Z'), '2026-10-07T16:05:00.000Z');
  assertEquals(normalised('2026-10-07T16:05:00.5Z'), '2026-10-07T16:05:00.500Z');
  assertEquals(normalised('2026-10-07T16:05:00.123456789Z'), '2026-10-07T16:05:00.123Z');
  assertEquals(normalised('2026-10-07T09:05:00-07:00'), '2026-10-07T16:05:00.000Z');
  assertEquals(normalised('2026-10-07T21:35:00+05:30'), '2026-10-07T16:05:00.000Z');
  assertEquals(normalised('2028-02-29T00:00:00Z'), '2028-02-29T00:00:00.000Z');
  for (const bad of ['2026-02-30T00:00:00Z', '2026-13-01T00:00:00Z', '2026-00-10T00:00:00Z', '2027-02-29T00:00:00Z',
    '2026-10-07T24:00:00Z', '2026-10-07T16:60:00Z', '2026-10-07T16:05:60Z', '2026-10-07T16:05:00+24:00',
    '2026-10-07T16:05:00+05:60', '2026-10-07 16:05:00Z', '0000-01-01T00:00:00Z', '9999-12-31T23:59:59-01:00',
    '']) {
    assertEquals(normalised(bad), null, bad);
  }
});

Deno.test('ground truth validator: the device never fails an item', () => {
  const external = (value: unknown) => {
    const result = validateGroundTruthLabelItem(item({ device_id: value }));
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

Deno.test('ground truth validator: items are judged individually and the owner is never read from them', () => {
  const { valid, rejected } = validateGroundTruthLabels({
    labels: [
      item({ label_key: 'guided:a:1', start_ts: T0, end_ts: T0 + 100 }),
      item({ label_key: 'guided:a:2', source: 'sleep' }),
      'not an object',
      null,
      item({ label_key: 'bad key', source: 'sleep' }),
      item({ label_key: 'guided:a:3', owner: OTHER, user_id: OTHER, revision: 99 }),
    ],
  });
  assertEquals(valid.map((entry) => entry.label_key), ['guided:a:1', 'guided:a:3']);
  assertEquals(rejected, [
    { label_key: 'guided:a:2', reason: 'invalid_source' },
    { label_key: null, reason: 'invalid_item' },
    { label_key: null, reason: 'invalid_item' },
    { label_key: null, reason: 'invalid_label_key' },
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

function post(body: unknown, { path = '/ground-truth-labels', method = 'POST', bearer = 'noop_auth_a', raw }: {
  path?: string; method?: string; bearer?: string | null; raw?: string;
} = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  return new Request(`https://test.invalid/functions/v1/scores${path}`, {
    method, headers,
    body: method === 'GET' ? undefined : (raw ?? JSON.stringify(body)),
  });
}

Deno.test('ground truth route: owner comes from the credential; valid items reach the RPC with the resolved device', async () => {
  const { rest, calls } = await fixture({
    saved: [{ label_key: 'guided:a:1', revision: 1 }, { label_key: 'guided:a:2', revision: 4 }],
    ignored: [{ label_key: 'guided:a:3', reason: 'stale' }],
  });
  const response = await handleScoresRequest(post({
    owner: OTHER, user_id: OTHER, p_owner: OTHER, device_id: 'whoop-ZZZ999999',
    labels: [
      item({ label_key: 'guided:a:1', start_ts: T0, end_ts: T0 + 100 }),
      item({ label_key: 'guided:a:2', start_ts: T0, end_ts: T0 + 100 }),
      item({ label_key: 'guided:a:3', start_ts: T0, end_ts: T0 + 100 }),
      item({ label_key: 'guided:a:4', start_ts: T0, end_ts: T0 + 100, source: 'sleep' }),
    ],
  }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  assertEquals(await response.json(), {
    saved: [{ label_key: 'guided:a:1', revision: 1 }, { label_key: 'guided:a:2', revision: 4 }],
    ignored: [{ label_key: 'guided:a:3', reason: 'stale' }],
    rejected: [{ label_key: 'guided:a:4', reason: 'invalid_source' }],
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, 'upsert_activity_ground_truth_labels');
  assertEquals(Object.keys(calls[0].args).sort(), ['p_items', 'p_owner']);
  assertEquals(calls[0].args.p_owner, USER);
  const sent = calls[0].args.p_items;
  assertEquals(sent.map((entry: any) => entry.label_key), ['guided:a:1', 'guided:a:2', 'guided:a:3']);
  for (const entry of sent) {
    assertEquals([entry.device_id, entry.external_device_id], [DEVICE, LOCAL]);
    assertFalse('owner' in entry || 'user_id' in entry || 'id' in entry);
    assertEquals(entry.client_id, '5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11');
  }
});

Deno.test('ground truth route: an unresolvable device is stored as no device and the item is kept', async () => {
  const { rest, calls, deviceQueries } = await fixture((args: any) => ({
    saved: args.p_items.map((entry: any) => ({ label_key: entry.label_key, revision: 1 })), ignored: [],
  }));
  const response = await handleScoresRequest(post({
    labels: [
      item({ label_key: 'guided:a:1', start_ts: T0, end_ts: T0 + 100, device_id: 'whoop-NEVERSEEN1' }),
      item({ label_key: 'guided:a:2', start_ts: T0, end_ts: T0 + 100, device_id: OTHER_LOCAL }),
      item({ label_key: 'guided:a:3', start_ts: T0, end_ts: T0 + 100, device_id: null }),
      item({ label_key: 'guided:a:4', start_ts: T0, end_ts: T0 + 100, device_id: 'x@example.com' }),
      item({ label_key: 'guided:a:5', start_ts: T0, end_ts: T0 + 100, device_id: LOCAL }),
      item({ label_key: 'guided:a:6', start_ts: T0, end_ts: T0 + 100, device_id: LOCAL }),
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

Deno.test('ground truth route: when every item is rejected the database is not called', async () => {
  const { rest, calls } = await fixture();
  const response = await handleScoresRequest(post({
    labels: [item({ source: 'sleep' }), { nonsense: true }],
  }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    saved: [], ignored: [],
    rejected: [{ label_key: `guided:activity-session:${T0}`, reason: 'invalid_source' }, { label_key: null, reason: 'invalid_label_key' }],
  });
  assertEquals(calls, []);
});

Deno.test('ground truth route: malformed envelopes are 400 with the shared error shape', async () => {
  const { rest, calls } = await fixture();
  const cases: Array<[unknown, string | undefined, string]> = [
    [undefined, '{not json', 'invalid_body'],
    [undefined, '', 'invalid_body'],
    [{}, undefined, 'invalid_labels'],
    [{ labels: 'x' }, undefined, 'invalid_labels'],
    [{ labels: [] }, undefined, 'invalid_labels'],
    [[item()], undefined, 'invalid_labels'],
    [null, undefined, 'invalid_labels'],
    [{ labels: Array.from({ length: 26 }, (_, index) => item({ label_key: `k:${index}` })) }, undefined, 'invalid_labels'],
  ];
  for (const [body, raw, error] of cases) {
    const response = await handleScoresRequest(post(body, { raw }), { rest, cfg });
    assertEquals(response.status, 400, error);
    assertEquals(await response.json(), { error });
  }
  assertEquals(calls, []);
});

Deno.test('ground truth route: the body limit is 128 KiB, not the 8 KiB of the other POST routes', async () => {
  const { rest, calls } = await fixture((args: any) => ({
    saved: args.p_items.map((entry: any) => ({ label_key: entry.label_key, revision: 1 })), ignored: [],
  }));
  const big = (index: number) => item({
    label_key: `guided:a:${index}`, start_ts: T0, end_ts: T0 + 100,
    model_context_at_label_time: { blob: 'x'.repeat(GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES - 20) },
  });
  const accepted = { labels: Array.from({ length: 6 }, (_, index) => big(index)) };
  const acceptedBytes = new TextEncoder().encode(JSON.stringify(accepted)).length;
  assert(acceptedBytes > 8192 && acceptedBytes < 128 * 1024, String(acceptedBytes));
  const ok = await handleScoresRequest(post(accepted), { rest, cfg });
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).saved.length, 6);

  const oversized = { labels: [item({ note: 'x'.repeat(128 * 1024) })] };
  const refused = await handleScoresRequest(post(oversized), { rest, cfg });
  assertEquals(refused.status, 413);
  assertEquals(await refused.json(), { error: 'payload_too_large' });
  assertEquals(calls.length, 1);

  // The other body-carrying routes keep their own 8 KiB limit.
  const placement = await handleScoresRequest(post({ placement: 'wrist', effective_start: '2026-10-01T00:00:00Z',
    pad: 'x'.repeat(9000) }, { path: '/placement' }), { rest, cfg });
  assertEquals(placement.status, 413);
});

Deno.test('ground truth route: no credential, a wrong credential or another account cannot write', async () => {
  const { rest, calls } = await fixture();
  const body = { labels: [item()] };
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

Deno.test('ground truth route: a signed-in account is accepted with its registered source, and only then', async () => {
  const { rest, calls } = await fixture({ saved: [{ label_key: `guided:activity-session:${T0}`, revision: 1 }], ignored: [] });
  await rest.upsert('compute_account_sources', { user_id: USER, source_id: SOURCE, revoked_at: null });
  const account = (headers: Record<string, string>) => {
    const request = post({ labels: [item()] }, { bearer: 'header.payload.signature' });
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

Deno.test('ground truth route: unsupported methods and paths behave like the other routes', async () => {
  const { rest, calls } = await fixture();
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE']) {
    const response = await handleScoresRequest(post({ labels: [item()] }, { method }), { rest, cfg });
    assertEquals([method, response.status], [method, 405]);
    assertEquals(await response.json(), { error: 'method_not_allowed' });
  }
  for (const path of ['/ground-truth-labels/', '/ground-truth-label', '/ground_truth_labels']) {
    const response = await handleScoresRequest(post({ labels: [item()] }, { path }), { rest, cfg });
    assertEquals([path, response.status], [path, 405]);
  }
  assertEquals(calls, []);
});

Deno.test('ground truth route: a database failure is a generic 500 that leaks nothing', async () => {
  const { rest } = await fixture(() => { throw new Error('connection to db.internal:5432 refused; password=hunter2'); });
  const response = await handleScoresRequest(post({ labels: [item()] }), { rest, cfg });
  assertEquals(response.status, 500);
  assertEquals(await response.json(), { error: 'scores_unavailable' });
});
