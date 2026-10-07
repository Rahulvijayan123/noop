import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest, parseSensorBiomarkersQuery } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/sensor-biomarkers: the sensor-biomarker day documents (CONTRACTS.md §6). The owner
// and device come from the credential (never the query), at most 31 UTC days are read per request,
// the latest analysis_version row wins per day, and a request with no stored document is a 404.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

function docRow(day: string, analysisVersion = 'sensor-biomarkers/1.0.0') {
  return {
    day,
    analysis_version: analysisVersion,
    input_revision: `sha256:${'a'.repeat(64)}`,
    interval_start_utc: `${day}T00:00:00Z`,
    interval_end_utc: `2026-10-0${day[9] === '6' ? '7' : '8'}T00:00:00Z`,
    status: 'completed',
    families_ok: ['movement', 'oscillation'],
    withheld_reasons: [],
    run_ms: 1200,
    model_revisions: { movement: 'imu-biomarkers/1.0.0' },
    published_at: `${day}T01:00:00Z`,
    updated_at: `${day}T01:00:00Z`,
    document: {
      schema_version: 1,
      analysis_version: analysisVersion,
      input_revision: `sha256:${'a'.repeat(64)}`,
      interval_start_utc: `${day}T00:00:00Z`,
      interval_end_utc: `2026-10-0${day[9] === '6' ? '7' : '8'}T00:00:00Z`,
      processed_at_utc: `${day}T01:00:00Z`,
      families: {
        movement: { status: 'ok', release_tier: 'descriptive', provider_revision: 'imu-biomarkers/1.0.0',
          observed_seconds: 3600, eligible_seconds: 3000, contact_state: 'on_wrist',
          measurements: { enmo_median_mg: { value: 12.5, unit: 'mg' } }, reason_counts: {} },
        tremor: { status: 'withheld', release_tier: 'research', provider_revision: 'paradigma/1.0.0',
          reason: 'unknown_wrist_placement', measurements: {}, reason_counts: {} },
      },
    },
  };
}

function fakeRest(rows: Array<ReturnType<typeof docRow>>, reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'sensor_biomarker_days') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`),
        'every read is scoped to the credential owner and the resolved device');
      assert(query.includes('order=day.asc,analysis_version.desc'),
        'the read must pick the latest analysis_version per day');
      const days = /day=in\.\(([^)]*)\)/.exec(query)![1].split(',');
      return rows
        .filter((r) => days.includes(r.day))
        .sort((a, b) => a.day === b.day ? (a.analysis_version < b.analysis_version ? 1 : -1) : (a.day < b.day ? -1 : 1));
    }
    return [];
  };
  return rest;
}

function get(query: string, headers: Record<string, string> = {}) {
  return new Request(`https://example.test/functions/v1/scores/sensor-biomarkers?deviceId=${LOCAL_DEVICE}&${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet', ...headers },
  });
}

Deno.test('sensor biomarkers: returns the owner\'s latest document per day', async () => {
  const reads: string[] = [];
  const rest = fakeRest([docRow('2026-10-06'), docRow('2026-10-07')], reads);
  const res = await handleScoresRequest(get('days=2026-10-06,2026-10-07'), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.identity.deviceId, DEVICE);
  assertEquals(body.days.length, 2);
  assertEquals(body.days[0].day, '2026-10-06');
  assertEquals(body.days[0].document.families.movement.measurements.enmo_median_mg.value, 12.5);
  assertEquals(body.days[0].document.families.tremor.reason, 'unknown_wrist_placement');
  assertEquals(body.days[1].day, '2026-10-07');
  assertEquals(reads.length, 1);
});

Deno.test('sensor biomarkers: two analysis versions of one day return only the latest', async () => {
  const reads: string[] = [];
  const older = docRow('2026-10-06', 'sensor-biomarkers/0.9.0');
  const latest = docRow('2026-10-06');
  const res = await handleScoresRequest(get('day=2026-10-06'), { rest: fakeRest([older, latest], reads), cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.days.length, 1);
  assertEquals(body.days[0].analysis_version, 'sensor-biomarkers/1.0.0');
});

Deno.test('sensor biomarkers: a day with no stored document is a 404', async () => {
  const reads: string[] = [];
  const res = await handleScoresRequest(get('day=2026-10-06'), { rest: fakeRest([], reads), cfg });
  assertEquals(res.status, 404);
  assertEquals((await res.json()).error, 'not_found');
});

Deno.test('sensor biomarkers: partial multi-day request returns only the stored days', async () => {
  const reads: string[] = [];
  const res = await handleScoresRequest(get('days=2026-10-06,2026-10-07'), {
    rest: fakeRest([docRow('2026-10-06')], reads), cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.days.length, 1);
  assertEquals(body.days[0].day, '2026-10-06');
});

Deno.test('sensor biomarkers: unauthorized requests are refused', async () => {
  const reads: string[] = [];
  const res = await handleScoresRequest(
    new Request(`https://example.test/functions/v1/scores/sensor-biomarkers?deviceId=${LOCAL_DEVICE}&day=2026-10-06`),
    { rest: fakeRest([], reads), cfg });
  assertEquals(res.status, 401);
  assertEquals(reads.length, 0);
});

Deno.test('sensor biomarkers: malformed or unbounded queries are rejected before the database is asked', async () => {
  const bad = [
    '',                       // no day
    'day=2026-13-45',         // invalid month
    'day=2026-02-30',         // invalid calendar day
    'day=2026-10-06;drop',    // injection shape
    'day=2026-10-06&days=2026-10-07', // both forms
    'days=' + Array.from({ length: 32 }, (_, i) => `2026-11-${String(i + 1).padStart(2, '0')}`).join(','), // 32 days
    'days=2026-10-06,2026-10-06', // duplicate
  ];
  for (const query of bad) {
    const reads: string[] = [];
    const res = await handleScoresRequest(get(query), { rest: fakeRest([], reads), cfg });
    assertEquals(res.status, 400, query);
    assertEquals(reads.length, 0, query);
  }
});

Deno.test('sensor biomarkers: a registered device is required', async () => {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') return [];
    return [];
  };
  const res = await handleScoresRequest(get('day=2026-10-06'), { rest, cfg });
  assertEquals(res.status, 409);
});

Deno.test('sensor biomarkers: query parser', () => {
  const single = parseSensorBiomarkersQuery(new URLSearchParams('day=2026-10-06'));
  assertEquals(single.days, ['2026-10-06']);
  const multi = parseSensorBiomarkersQuery(new URLSearchParams('days=2026-10-06,2026-10-07'));
  assertEquals(multi.days, ['2026-10-06', '2026-10-07']);
});
