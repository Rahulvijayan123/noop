// sleep_analytics_route_test.ts
//
// Worker/backend contract for Phase 1 sleep analytics (docs/sleep-analytics/spec.md
// section 12 "Worker/backend" rows): the v2 scores route must preserve the nested
// `daily.sleep_analytics_v1` document VERBATIM (publish_scoring_snapshot_v2 stores the
// free-form jsonb payload, and readHostedSnapshot passes payload.daily through unchanged),
// owner/device fencing must be unchanged, and the new fields must not disturb the pending/
// status semantics or the legacy algorithm-version reporting.
import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest, readHostedSnapshot } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const DEVICE = '44444444-4444-4444-8444-444444444444';
const OTHER_DEVICE = '55555555-5555-5555-8555-555555555555';
const LOCAL = 'whoop-ABC123456';
const DAY = '2026-10-05';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

/// A representative REDACTED sleep_analytics_v1 document (schema 1, five groups, no raw
/// physiology): exactly the shape the worker adapter publishes under daily.
function redactedDocument() {
  return {
    schemaVersion: 1,
    algorithmVersion: 'nara-sleep-analytics-1',
    configVersion: 'v1',
    scope: 'main_night',
    timezone: 'America/Los_Angeles',
    startAt: '2026-10-04T23:00:00Z',
    endAt: '2026-10-05T07:00:00Z',
    start: 1791334800,
    end: 1791363600,
    fragments: [{ id: `sleep-${DEVICE}-1791334800`, sourceKind: 'native_whoop_v2',
      startAt: '2026-10-04T23:00:00Z', endAt: '2026-10-05T07:00:00Z', edited: false,
      start: 1791334800, end: 1791363600 }],
    fingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    stageSourceVersion: 'frwhoop-server-1',
    nativeEpochResolutionSeconds: 30,
    inputRevision: 7,
    continuity: { quality: { status: 'available', fragmentSpanSeconds: 28800, groupSpanSeconds: 28800,
      observedLabeledSeconds: 28800, unknownSeconds: 0, inferredGapAwakeSeconds: 0,
      inputSupportedSeconds: 28800, inputSupportedFraction: 1, labelSupportedFraction: 1,
      sourceResolutionSeconds: 30, streamCounts: { hr: 28800, beats: 28800 } },
      observedAsleepSeconds: { value: 27000, unit: 's', status: 'available' },
      observedWasoSeconds: { value: 1800, unit: 's', status: 'available' } },
    stageDynamics: { quality: { status: 'available' } },
    movement: { quality: { status: 'available' }, movementPercentage: { value: 2.5, unit: '%', status: 'available' } },
    thermal: { quality: { status: 'available' }, nightMedianC: { value: 32.6, unit: '°C', status: 'available' } },
    prvDiagnostics: { quality: { status: 'disabled' }, timingMethod: 'rr_seq_ord', source: 'prv_optical', windows: [] },
  };
}

function get(query = `day=${DAY}&deviceId=${LOCAL}`) {
  return new Request(`https://example.test/functions/v1/scores?${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('sleep analytics: readHostedSnapshot preserves daily.sleep_analytics_v1 deep-equal', async () => {
  const doc = redactedDocument();
  const rest = makeMemRest() as any;
  await rest.upsert('scoring_algorithms_v2', { algorithm_version: 'frwhoop-server-1', enabled: true, active: true });
  await rest.upsert('scoring_snapshots_v2', {
    result_revision: 9, user_id: USER, device_id: DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 7,
    computed_at: '2026-10-05T08:00:00Z',
    payload: { status: 'available', statusReasons: [], daily: { algorithm_version: 'frwhoop-server-1',
        recovery: 61, sleep_analytics_v1: doc },
      sleep: [], coverage: {}, timezone: 'America/Los_Angeles', dataThrough: '2026-10-05T07:30:00Z' },
  });
  const reads: string[] = [];
  const scoped = rest.select.bind(rest);
  rest.select = async (table: string, query: string) => {
    reads.push(`${table} ${query}`);
    return scoped(table, query);
  };
  const hosted = await readHostedSnapshot({ rest, userId: USER, deviceId: DEVICE, day: DAY });
  assert(hosted, 'hosted snapshot must be read');
  // The nested document comes back VERBATIM (deep-equal), free-form jsonb passthrough.
  assertEquals(hosted.daily.sleep_analytics_v1, doc);
  // The read is owner+device scoped: the scope query pins both the user and the device.
  const snapRead = reads.find((r) => r.startsWith('scoring_snapshots_v2 '));
  assert(snapRead?.includes(`user_id=eq.${USER}`), 'snapshot read must be owner-scoped');
  assert(snapRead?.includes(`device_id=eq.${DEVICE}`), 'snapshot read must be device-scoped');
});

Deno.test('sleep analytics: cross-owner/cross-device rows are never returned (fencing unchanged)', async () => {
  const rest = makeMemRest() as any;
  await rest.upsert('scoring_algorithms_v2', { algorithm_version: 'frwhoop-server-1', enabled: true, active: true });
  // Only rows for OTHER owner / OTHER device exist.
  await rest.upsert('scoring_snapshots_v2', {
    result_revision: 9, user_id: OTHER, device_id: OTHER_DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 7,
    payload: { status: 'available', daily: { sleep_analytics_v1: redactedDocument() },
      timezone: 'Etc/UTC', dataThrough: '2026-10-05T07:30:00Z' },
  });
  const hosted = await readHostedSnapshot({ rest, userId: USER, deviceId: DEVICE, day: DAY });
  assertEquals(hosted, null, 'the owner scoped read must not see another owner/device row');
});

Deno.test('sleep analytics: route attaches hosted_snapshot with nested document verbatim', async () => {
  const doc = redactedDocument();
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'tok', token_hash: hashIngestToken('noop_test-token'), token_kind: 'installation',
      provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await rest.upsert('noop_app_installations', { user_id: USER, source_id: SOURCE });
  await rest.upsert('devices', { id: DEVICE, user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL });
  await rest.upsert('scoring_algorithms_v2', { algorithm_version: 'frwhoop-server-1', enabled: true, active: true });
  await rest.upsert('scoring_snapshots_v2', {
    result_revision: 9, user_id: USER, device_id: DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 7,
    computed_at: '2026-10-05T08:00:00Z',
    payload: { status: 'available', statusReasons: [],
      daily: { algorithm_version: 'frwhoop-server-1', hrv_rmssd_ms: 42.5, sleep_analytics_v1: doc },
      sleep: [], coverage: {}, timezone: 'America/Los_Angeles', dataThrough: '2026-10-05T07:30:00Z' },
  });
  await rest.upsert('scoring_jobs_v2', { user_id: USER, device_id: DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 8 });
  rest.rpc = async (name: string, args: any) => ({
    schema_version: 2, user_id: args.p_user, day: args.p_day,
    algorithm_version: 'frwhoop-server-1',
    features: { hrv: { device_id: args.p_device, status: 'available' } },
    daily: { hrv_rmssd_ms: 42.5, recovery: 61 }, nights: [], stale: false,
  });
  const res = await handleScoresRequest(get(), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  const hosted = body.server_scoring.hosted_snapshot;
  assert(hosted, 'enrolled installation read must attach the hosted snapshot');
  assertEquals(hosted.daily.sleep_analytics_v1, doc, 'nested document must pass through verbatim');
  // Pending/status semantics are untouched by the new fields: a newer requested input
  // revision keeps pending=true, and payload.status/status_reasons pass through.
  assertEquals(hosted.pending, true);
  assertEquals(hosted.status, 'available');
  assertEquals(hosted.status_reasons, []);
  assertEquals(hosted.input_revision, '7');
  assertEquals(hosted.result_revision, '9');
  // Legacy algorithm-version reporting is untouched: the outer daily keeps its own version
  // while the document's version stays nested under its own camelCase key.
  assertEquals(hosted.daily.algorithm_version, 'frwhoop-server-1');
  assertEquals(hosted.daily.sleep_analytics_v1.algorithmVersion, 'nara-sleep-analytics-1');
  assert(!('algorithm_version' in hosted.daily.sleep_analytics_v1),
    'the nested document must not leak a legacy snake_case algorithm_version into daily');
});

Deno.test('sleep analytics: pending is false when no newer requested revision exists', async () => {
  const rest = makeMemRest() as any;
  await rest.upsert('scoring_algorithms_v2', { algorithm_version: 'frwhoop-server-1', enabled: true, active: true });
  await rest.upsert('scoring_snapshots_v2', {
    result_revision: 9, user_id: USER, device_id: DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 7,
    payload: { status: 'partial', statusReasons: ['gravity_empty'],
      daily: { sleep_analytics_v1: redactedDocument() },
      timezone: 'America/Los_Angeles', dataThrough: '2026-10-05T07:30:00Z' },
  });
  await rest.upsert('scoring_jobs_v2', { user_id: USER, device_id: DEVICE, day: DAY,
    algorithm_version: 'frwhoop-server-1', input_revision: 7 });
  const hosted = await readHostedSnapshot({ rest, userId: USER, deviceId: DEVICE, day: DAY });
  assert(hosted);
  assertEquals(hosted.pending, false);
  assertEquals(hosted.status, 'partial');
  assertEquals(hosted.status_reasons, ['gravity_empty']);
});
