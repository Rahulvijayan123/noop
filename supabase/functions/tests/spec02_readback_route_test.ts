// spec02_readback_route_test.ts
//
// Spec-02 readback (docs/spec-02/CONTRACT.md §4–§6): the routes the app reads must carry every new
// field VERBATIM — no projection, defaulting or key renaming between the worker's published
// document and the phone.
//   • GET scores (hosted snapshot): `daily.sleep_analytics_v1` with pNN50, morning_response and
//     stage_movement, and `daily.sleep_features` with the respiratory, PRV-nonlinear, rhythm,
//     rest-activity and rebound blocks, deep-equal through readHostedSnapshot and the route.
//   • GET scores/context: the day document's `pulse_episodes`, `sleep.day_night_heart_rate` and
//     `bouts[].recovery.respiratory_recovery` pass through the read RPC result unchanged.
//   • GET scores/context/history: bout payloads (with respiratory_recovery) pass through unchanged.
// A document without the new keys (older worker) is still served unchanged.
import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { handleScoresRequest, readHostedSnapshot } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const LOCAL = 'whoop-ABC123456';
const DEVICE = noopDeviceId(USER, LOCAL);
const DAY = '2026-10-05';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

const metric = (value: number | null, unit: string, status: string, reason?: string) =>
  ({ ...(value === null ? {} : { value }), unit, status, ...(reason ? { reason } : {}) });

function sleepAnalyticsSpec02() {
  const quality = { status: 'available', fragment_span_seconds: 28800, group_span_seconds: 28800,
    observed_labeled_seconds: 28800, unknown_seconds: 0, inferred_gap_awake_seconds: 0,
    input_supported_seconds: 28800, input_supported_fraction: 1, label_supported_fraction: 1,
    source_resolution_seconds: 30, stream_counts: { hr: 28800 } };
  const signal = (name: string, unit: string, before: number, after: number | null) => ({
    signal: name, unit, minute_rule: 'rule', points: [{ offset_min: -30, value: before, support: 52, valid: true },
      { offset_min: 0, value: after, support: after === null ? 3 : 52, valid: after !== null }],
    before_valid_minutes: 28, after_valid_minutes: after === null ? 4 : 26, eligible_minutes_each_side: 30,
    before_median: metric(before, unit, 'available'),
    after_median: after === null ? metric(null, unit, 'unavailable', 'insufficient_coverage') : metric(after, unit, 'available'),
    change: after === null ? metric(null, unit, 'unavailable', 'insufficient_coverage') : metric(after - before, unit, 'available'),
  });
  return {
    schema_version: 1, algorithm_version: 'nara-sleep-analytics-1', config_version: 'v1', scope: 'main_night',
    timezone: 'America/Los_Angeles', start: 1791334800, end: 1791363600,
    movement: { quality, movement_percentage: metric(2.5, '%', 'available'),
      stage_movement: [{ label: 'deep', eligible_seconds: metric(6000, 's', 'available'),
        movement_seconds: metric(60, 's', 'available'), movement_percentage: metric(1, '%', 'available'),
        movement_bout_starts: { value: 1, unit: 'count', status: 'available' },
        movement_bouts_per_eligible_hour: metric(0.6, 'per_h', 'available') }],
      stage_movement_note: 'stages_may_depend_on_motion' },
    prv_diagnostics: { quality, nightly_sd1_ms: metric(41.5, 'ms', 'available'),
      nightly_pnn50_pct: metric(12.396, '%', 'available'),
      pnn50_pair_count: { value: 9600, unit: 'count', status: 'available' },
      nn50_count: { value: 1190, unit: 'count', status: 'available' },
      pnn50_method: 'pnn50GapAware_original_adjacency_v1',
      windows: [{ start: 1791334800, sd1_ms: 40.1, sd2_ms: 86.2, pairs: 610, coverage: 0.97, pnn50_pct: 11.8, nn50_count: 72 }] },
    morning_response: { quality, anchor_kind: 'effective_window_end', anchor_ts: 1791363600,
      anchor_at: '2026-10-05T07:00:00Z', window_before_seconds: 1800, window_after_seconds: 1800,
      heart_rate: signal('heart_rate', 'bpm', 54, 63), skin_temperature: signal('skin_temperature', '°C', 33.1, 32.62),
      movement: signal('movement', 's/min', 1.5, null), algorithm_version: 'morning-response-1',
      interpretation: 'response_around_detected_boundary_not_awakening_physiology' },
  };
}

function sleepFeaturesSpec02() {
  return {
    schema_version: 1, algorithm_version: 'nara-sleep-features-1', status: 'partial', status_reasons: [],
    nights: [{
      night_id: 'night-2026-10-05-main', start_utc: '2026-10-04T23:00:00Z', end_utc: '2026-10-05T07:00:00Z',
      is_nap: false,
      respiratory_variability: { status: 'available', reasons: [], rate_bpm: 13.5, method_version: 'resp-variability-2',
        supported_range: { detector_band_bpm: [6, 24], min_peak_spacing_s: 2.5, display_rate_range_bpm: [8, 25],
          source: 'SleepStager.respBreathTrack' },
        interval_distribution: { status: 'available', reasons: [], n_intervals: 6120, median_s: 4.25, iqr_s: 0.6,
          p05_s: 3.41, p10_s: 3.62, p25_s: 3.98, p75_s: 4.58, p90_s: 4.97, p95_s: 5.22,
          source: 'consecutive_intervals_within_usable_runs' },
        stable_modulation: { status: 'partial', reasons: ['thin_data'], definition_version: 'stable-resp-modulation-1',
          criteria: { max_cv_interval: 0.15 }, stable_minutes: 250, evaluated_minutes: 390, unknown_minutes: 42,
          stable_fraction_of_evaluated: 0.641, stable_fraction_of_night: 0.521 },
        stage_conditioned: { deep: { rate_bpm: 12.9, cv_interval: 0.06, windows: 11, sd_interval_s: 0.31,
          rmssd_interval_s: 0.28, median_interval_s: 4.62, iqr_interval_s: 0.44 } } },
      prv_nonlinear: { status: 'available', reasons: [], method_version: 'prv-nonlinear-1', neurokit2: '0.2.13',
        source: 'prv_optical', secondary: true, config: { segment_beats: 300, sampen_dimension: 2,
          sampen_tolerance_sd: 0.2, dfa_scales: [4, 16], min_segments: 3 }, segments_used: 12, segments_rejected: 3,
        sample_entropy: { median: 1.42, iqr: 0.21, segments: 12 }, dfa_alpha1: { median: 0.98, iqr: 0.12, segments: 12 } },
      thermal: { status: 'available', reasons: [], observed_skin_temp_rhythm: { status: 'withheld',
        reasons: ['insufficient_daytime_temperature'], method_version: 'skin-temp-rhythm-1', qualifying_days: 2,
        phase_status: { status: 'unavailable', reason: 'insufficient_daytime_temperature' } } },
    }],
    rest_activity_rhythm: { status: 'withheld', reasons: ['movement_history_unavailable'],
      method_version: 'rest-activity-1', signal: 'gravity_movement_seconds_per_minute', epoch_seconds: 3600 },
    rebound: { status: 'available', reasons: [], definition_version: 'sleep-rebound-1',
      personal_reference: { median_asleep_min: 425, median_awake_min: 32, nights: 24 },
      after_short: { pairs: 4, next_night_asleep_diff_min: { median: 28, iqr: 40 } }, after_fragmented: { pairs: 0 } },
  };
}

async function seededRest(daily: Record<string, unknown>) {
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
    result_revision: 9, user_id: USER, device_id: DEVICE, day: DAY, algorithm_version: 'frwhoop-server-1',
    input_revision: 7, computed_at: '2026-10-05T08:00:00Z',
    payload: { status: 'available', statusReasons: [], daily: { algorithm_version: 'frwhoop-server-1', ...daily },
      sleep: [], coverage: {}, timezone: 'America/Los_Angeles', dataThrough: '2026-10-05T07:30:00Z' },
  });
  return rest;
}

Deno.test('spec-02: hosted snapshot carries the new sleep analytics and sleep features fields verbatim', async () => {
  const analytics = sleepAnalyticsSpec02();
  const features = sleepFeaturesSpec02();
  const rest = await seededRest({ sleep_analytics_v1: analytics, sleep_features: features });
  const hosted = await readHostedSnapshot({ rest, userId: USER, deviceId: DEVICE, day: DAY });
  assert(hosted);
  assertEquals(hosted.daily.sleep_analytics_v1, analytics);
  assertEquals(hosted.daily.sleep_features, features);
  // Nulls and withheld blocks stay exactly what the producer wrote (never defaulted to 0).
  assertEquals(hosted.daily.sleep_analytics_v1.morning_response.movement.after_median,
    { unit: 's/min', status: 'unavailable', reason: 'insufficient_coverage' });
  assertEquals(hosted.daily.sleep_features.rest_activity_rhythm.reasons, ['movement_history_unavailable']);
  assert(!('is' in hosted.daily.sleep_features.rest_activity_rhythm));
});

Deno.test('spec-02: the scores route attaches the same documents unchanged', async () => {
  const analytics = sleepAnalyticsSpec02();
  const features = sleepFeaturesSpec02();
  const rest = await seededRest({ sleep_analytics_v1: analytics, sleep_features: features });
  rest.rpc = async (_name: string, args: any) => ({
    schema_version: 2, user_id: args.p_user, day: args.p_day, algorithm_version: 'frwhoop-server-1',
    features: {}, daily: { recovery: 61 }, nights: [], stale: false,
  });
  const res = await handleScoresRequest(new Request(`https://example.test/functions/v1/scores?day=${DAY}&deviceId=${LOCAL}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  }), { rest, cfg });
  assertEquals(res.status, 200);
  const hosted = (await res.json()).server_scoring.hosted_snapshot;
  assertEquals(hosted.daily.sleep_analytics_v1, analytics);
  assertEquals(hosted.daily.sleep_features, features);
});

Deno.test('spec-02: an older snapshot without the new keys is served unchanged', async () => {
  const old = { schema_version: 1, algorithm_version: 'nara-sleep-features-1', status: 'available', nights: [] };
  const rest = await seededRest({ sleep_features: old });
  const hosted = await readHostedSnapshot({ rest, userId: USER, deviceId: DEVICE, day: DAY });
  assert(hosted);
  assertEquals(hosted.daily.sleep_features, old);
  assert(!('sleep_analytics_v1' in hosted.daily));
});

function contextDocument() {
  return {
    header: { identity: { day: '2026-10-01', timezone_id: 'America/Los_Angeles' } },
    sleep: { episodes: [], reasons: [], day_night_heart_rate: { state: 'supported', awake_median_bpm: 64,
      sleep_median_bpm: 52, difference_bpm: 12, percent_dip: 18.75,
      percent_dip_definition: '100*(awake_median_bpm-sleep_median_bpm)/awake_median_bpm', awake_samples: 39400,
      sleep_samples: 26190, awake_eligible_s: 48000, sleep_eligible_s: 27000, awake_coverage: 0.82,
      sleep_coverage: 0.97, reasons: ['percent_dip_definition'] } },
    pulse_episodes: { version: 'pc-pulse-1', state: 'supported', thresholds: [{ name: 'high_enter_bpm', value: 100 }],
      qualified_inactive_s: 30000, qualified_asleep_s: 24000, qualified_awake_s: 6000, episodes: [],
      high_episode_count: 0, low_episode_count: null, high_episode_s: 0, low_episode_s: null,
      acceleration_events: [], acceleration_events_per_asleep_hour: null, acceleration_events_per_awake_hour: null,
      reasons: ['cause_not_attributed', 'not_rhythm_classification'] },
    bouts: [bout()],
  };
}

function bout() {
  return { id: 'bout-1', interval: { start: 1791000000, end: 1791001800 }, kind: 'walking', status: 'complete',
    recovery: { follow_up: { start: 1791001800, end: 1791002100 }, censoring: [],
      respiratory_recovery: { method: 'pc-resp-recovery-1', state: 'returned_by', reference_bpm: 14.2,
        reference_samples: 6, tolerance_bpm: 1.5, first_observation_offset_s: 240, returned_by_offset_s: 240,
        follow_up: { start: 1791001800, end: 1791003600 }, observations: [{ offset_s: 240, bpm: 14.9 }],
        censoring: [], reasons: ['respiratory_returned_by_first_observation'] } } };
}

async function contextRest(rpc: (name: string, args: any) => any) {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'auth-a', token_hash: hashIngestToken('noop_auth_a'), token_kind: 'installation',
      provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
  ]);
  await rest.upsert('noop_app_installations', { user_id: USER, source_id: SOURCE });
  await rest.upsert('devices', { id: DEVICE, user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL });
  rest.rpc = async (name: string, args: any) => rpc(name, args);
  return rest;
}

const contextRequest = (path: string) => new Request(`https://test.invalid/functions/v1/scores${path}`, {
  headers: { authorization: 'Bearer noop_auth_a', 'content-type': 'application/json' },
});

Deno.test('spec-02: GET /context passes the new day-document members through verbatim', async () => {
  const context = { status: 'available', mode: 'retrospective', context_revision: 7, document: contextDocument() };
  const rest = await contextRest(() => context);
  const response = await handleScoresRequest(contextRequest(`/context?deviceId=${LOCAL}&day=2026-10-01`),
    { rest, cfg: { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' } });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.context, context);
  assertEquals(body.context.document.pulse_episodes.low_episode_count, null, 'not evaluated stays null, never 0');
});

Deno.test('spec-02: GET /context/history passes bout respiratory returns through verbatim', async () => {
  const history = { mode: 'retrospective', days: [], daily_values: [], bouts: [bout()], episodes: [] };
  const rest = await contextRest(() => history);
  const response = await handleScoresRequest(
    contextRequest(`/context/history?deviceId=${LOCAL}&from=2026-09-01&to=2026-10-05`),
    { rest, cfg: { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' } });
  assertEquals(response.status, 200);
  assertEquals((await response.json()).history, history);
});
