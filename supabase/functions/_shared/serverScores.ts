import { IdentityError, resolveUploadIdentity, resolveJwtUser, bearerToken, looksLikeJwt } from './tokens.ts';
import { createNoopDeviceResolver, findNoopDevice } from './devices.ts';
import { isSafeExternalDeviceId, isUuid } from './keys.ts';
import { STRETCH_FEEDBACK_MAX_BODY_BYTES, validateStretchFeedback } from './stretchFeedback.ts';
import {
  EXPOSURE_MAX_BODY_BYTES,
  parseContextHistoryQuery,
  parseContextQuery,
  parseExposureReadQuery,
  submitExposureEvents,
} from './physiologyContext.ts';
import { GROUND_TRUTH_LABELS_MAX_BODY_BYTES, submitGroundTruthLabels } from './groundTruthLabels.ts';
import { REASON_CODES_VERSION } from './reasonCodes.ts';
import {
  parseContextMinutesQuery, QUALITY_MINUTES_MAX_BODY_BYTES, readContextMinutes, submitQualityMinutes,
} from './measurementContext.ts';
import {
  WATCHDOG_EPISODES_MAX_BODY_BYTES,
  parseWatchdogEpisodesQuery,
  readWatchdogEpisodes,
  submitWatchdogEpisodes,
} from './watchdogEpisodes.ts';
import type { PushFunctionConfig } from './config.ts';
import type { SupabaseRest } from './rest.ts';

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function utcDay(at = new Date()): string {
  return at.toISOString().slice(0, 10);
}

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

/** The metrics with an AI-written explanation (metric_insight_jobs.metric; docs/METRIC_INSIGHTS.md). */
export const INSIGHT_METRICS: ReadonlySet<string> = new Set([
  'resting_hr', 'hrv_rmssd', 'hrv_sdnn', 'skin_temp', 'resp_rate', 'spo2', 'heart_rate', 'steps', 'calories',
]);

export async function readOwnerDayScores({ rest, userId, day, deviceId }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; day: string; deviceId: string | null;
}) {
  const date = new Date(day);
  if (!DAY_RE.test(day) || !Number.isFinite(date.getTime()) || utcDay(date) !== day) {
    throw fail('invalid_day', 400);
  }
  if (!deviceId) {
    return { server_scoring: await rest.rpc('server_scoring_pending_contract',{p_user:userId,p_day:day}) };
  }
  const overlay = await rest.rpc('server_scoring_for_device_day', {
    p_user: userId, p_day: day, p_device: deviceId,
  });
  return { server_scoring: overlay };
}

/**
 * The hosted NOOP worker's own published day result (`scoring_snapshots_v2`), for an enrolled installation.
 *
 * The worker runs the app's `AnalyticsEngine.analyzeDay` unchanged, so this is the number the offline app
 * would show for the same inputs. The family contract above keeps withholding legacy beat-timing values
 * from account clients; only the installation route attaches this. Null when nothing is published yet.
 */
export async function readHostedSnapshot({ rest, userId, deviceId, day }: {
  rest: Pick<SupabaseRest, 'select'>; userId: string; deviceId: string; day: string;
}) {
  const algorithms = await rest.select('scoring_algorithms_v2',
    'active=eq.true&enabled=eq.true&select=algorithm_version&limit=1');
  const algorithm = algorithms[0]?.algorithm_version;
  if (typeof algorithm !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(algorithm)) return null;
  const scope = `user_id=eq.${userId}&device_id=eq.${deviceId}&day=eq.${day}&algorithm_version=eq.${algorithm}`;
  const rows = await rest.select('scoring_snapshots_v2',
    `${scope}&select=result_revision,input_revision,computed_at,payload&order=result_revision.desc&limit=1`);
  const row = rows[0];
  const payload = row?.payload;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  const jobs = await rest.select('scoring_jobs_v2', `${scope}&select=input_revision&limit=1`);
  const requested = jobs[0]?.input_revision;
  return {
    algorithm_version: algorithm,
    result_revision: String(row.result_revision),
    input_revision: String(row.input_revision),
    computed_at: row.computed_at ?? null,
    pending: requested != null && Number(requested) > Number(row.input_revision),
    status: typeof payload.status === 'string' ? payload.status : null,
    status_reasons: Array.isArray(payload.statusReasons) ? payload.statusReasons : [],
    timezone: typeof payload.timezone === 'string' ? payload.timezone : null,
    data_through: payload.dataThrough ?? null,
    daily: payload.daily && typeof payload.daily === 'object' ? payload.daily : null,
    sleep: Array.isArray(payload.sleep) ? payload.sleep : [],
    coverage: payload.coverage && typeof payload.coverage === 'object' ? payload.coverage : null,
  };
}

/** Series names `server_metric_series` accepts (its CHECK constraint, and `server_metric_series_read`). */
export const SERIES_METRICS = ['hrv_rmssd_ms', 'resting_hr_bpm', 'resp_rate_bpm', 'steps', 'calories_kcal'] as const;
const SERIES_MAX_RANGE_SECONDS = 3 * 86_400;

/**
 * `GET /series?from=<unix>&to=<unix>[&metrics=a,b]`: a half-open range of at most three days (the RPC's own
 * limit, and about 4,300 rows) over the user's dense intraday series. Anything malformed is rejected before the
 * database is asked.
 */
export function parseSeriesQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) throw fail('invalid_range', 400);
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > SERIES_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  let metrics: string[] | null = null;
  const raw = params.get('metrics');
  if (raw != null) {
    metrics = raw.split(',');
    if (new Set(metrics).size !== metrics.length || metrics.some((m) => !(SERIES_METRICS as readonly string[]).includes(m))) {
      throw fail('invalid_metrics', 400);
    }
  }
  return { from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString(), metrics };
}

/** The raw-IMU lane's lineage: the only one that writes `activity_encoder_windows` today. */
const ACTIVITY_WINDOWS_ALGORITHM = 'hart-activity-1';
const ACTIVITY_WINDOWS_MAX_DAYS = 3;

/**
 * `GET /activity-windows?days=<YYYY-MM-DD>[,…][&known=<YYYY-MM-DD>:<revision>,…]`: HART's per-window output
 * (`hart-windows-1`) for up to three UTC days. A local day spans two UTC days, so the phone asks for both. A
 * day listed in `known` at its current result revision comes back without its windows (`unchanged: true`), so
 * an unchanged day costs a few bytes rather than its whole document.
 */
function isCalendarDay(day: string): boolean {
  const at = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(at.getTime()) && at.toISOString().slice(0, 10) === day;
}

export function parseActivityWindowsQuery(params: URLSearchParams) {
  const raw = params.get('days');
  if (raw == null) throw fail('invalid_days', 400);
  const days = raw.split(',');
  if (days.length < 1 || days.length > ACTIVITY_WINDOWS_MAX_DAYS || new Set(days).size !== days.length
      || days.some((d) => !DAY_RE.test(d) || !isCalendarDay(d))) {
    throw fail('invalid_days', 400);
  }
  const known = new Map<string, string>();
  const rawKnown = params.get('known');
  if (rawKnown != null && rawKnown !== '') {
    for (const entry of rawKnown.split(',')) {
      const m = /^(\d{4}-\d{2}-\d{2}):(\d{1,18})$/.exec(entry);
      if (!m || !days.includes(m[1])) throw fail('invalid_known', 400);
      known.set(m[1], m[2]);
    }
  }
  // `authority=1`: the caller applies the shared release policy itself (ActivityExpertSelection), so it may be sent
  // expert rows below production with everything needed to decode them. Without it (every phone built before the
  // policy) nothing below production is sent in a form that build turns into decoder evidence.
  const rawAuthority = params.get('authority');
  if (rawAuthority != null && !/^[1-9][0-9]{0,2}$/.test(rawAuthority)) throw fail('invalid_authority', 400);
  return { days, known, authorityAware: rawAuthority != null };
}

/**
 * A `hart-windows-1` object for a caller without the authority capability: the HART-embedded ElderNet columns
 * (`g_*`, no release of their own, so shadow) are left out, because such a build adds them to its decoder input as
 * gait-expert evidence. HART's own windows, features, fine labels and transition columns are unchanged.
 */
export function legacyHartWindows(windows: unknown): unknown {
  if (!windows || typeof windows !== 'object' || Array.isArray(windows)) return windows;
  return Object.fromEntries(Object.entries(windows as Record<string, unknown>).filter(([k]) => !k.startsWith('g_')));
}

export async function readActivityWindows({ rest, userId, deviceId, days, known, authorityAware = false }: {
  rest: SupabaseRest; userId: string; deviceId: string; days: string[]; known: Map<string, string>;
  authorityAware?: boolean;
}) {
  const owner = `user_id=eq.${userId}&device_id=eq.${deviceId}&algorithm_version=eq.${ACTIVITY_WINDOWS_ALGORITHM}`;
  const heads = await rest.select('activity_encoder_windows', `${owner}&day=in.(${days.join(',')})`
    + '&select=day,encoder_id,model_version,preprocessing_version,feature_schema,window_count,first_ts,last_ts,'
    + 'input_revision,result_revision,computed_at') ?? [];
  const wanted = heads.filter((h: any) => known.get(h.day) !== String(h.result_revision)).map((h: any) => h.day);
  const bodies = wanted.length
    ? await rest.select('activity_encoder_windows',
      `${owner}&day=in.(${wanted.join(',')})&select=day,result_revision,windows`) ?? []
    : [];
  const bodyByDay = new Map(bodies.map((b: any) => [b.day, b]));
  return heads.map((h: any) => {
    const body: any = bodyByDay.get(h.day);
    // Release (docs/model-integration/activity-authority.md): HART is the production producer; the ElderNet copy
    // embedded in HART's service (`g_*` in hart-windows-1) records no release of its own, so it is shadow.
    const authority = { input_revision: String(h.input_revision), release_mode: 'production',
      embedded_gait_release_mode: 'shadow' };
    // A republish between the two reads makes the body newer than its head; the body's revision is the one
    // that describes the windows sent.
    return body
      ? { ...h, ...authority, result_revision: String(body.result_revision),
        windows: authorityAware ? body.windows : legacyHartWindows(body.windows) }
      : { ...h, ...authority, result_revision: String(h.result_revision), unchanged: true };
  });
}

/**
 * The release an expert row may be shown as: its stored release (the migration's trigger keeps it at or below the
 * row's mode), else its recorded mode for a row written before the release column existed, and shadow for anything
 * else. Never production: no expert table holds a production row.
 */
const RELEASE_RANK: Record<string, number> = { shadow: 0, candidate: 1, production: 2 };

/** The weaker of `recorded` (unknown text reads as shadow) and `cap`. */
function lowerRelease(recorded: unknown, cap: 'shadow' | 'candidate'): 'shadow' | 'candidate' {
  const rank = typeof recorded === 'string' ? RELEASE_RANK[recorded] ?? 0 : 0;
  return Math.min(rank, RELEASE_RANK[cap]) >= 1 ? 'candidate' : 'shadow';
}

export function expertReleaseMode(row: { release_mode?: unknown; mode?: unknown }): 'shadow' | 'candidate' {
  const recorded = row.release_mode ?? row.mode;
  return recorded === 'candidate' && row.mode === 'candidate' ? 'candidate' : 'shadow';
}

/**
 * `GET /sensor-biomarkers?day=YYYY-MM-DD[&deviceId=...]` (or `days=a,b,c`, up to 31 UTC days):
 * the sensor-biomarker day documents (docs/sensor-biomarkers/CONTRACTS.md §6, spec-31 §8) for the
 * credential owner's device. The latest `analysis_version` row wins per day; a day with no stored
 * document is simply absent. No cross-owner reads: owner and device come from the credential,
 * never from the query.
 */
export const SENSOR_BIOMARKERS_MAX_DAYS = 31;

export function parseSensorBiomarkersQuery(params: URLSearchParams) {
  const day = params.get('day');
  const daysRaw = params.get('days');
  if (day != null && daysRaw != null) throw fail('invalid_days', 400);
  const raw = day ?? daysRaw;
  if (raw == null) throw fail('invalid_days', 400);
  const days = raw.split(',');
  if (days.length < 1 || days.length > SENSOR_BIOMARKERS_MAX_DAYS || new Set(days).size !== days.length
      || days.some((d) => !DAY_RE.test(d) || !isCalendarDay(d))) {
    throw fail('invalid_days', 400);
  }
  return { days };
}

export async function readSensorBiomarkers({ rest, userId, deviceId, days }: {
  rest: Pick<SupabaseRest, 'select'>; userId: string; deviceId: string; days: string[];
}) {
  const scope = `user_id=eq.${userId}&device_id=eq.${deviceId}&day=in.(${days.join(',')})`;
  const rows = (await rest.select('sensor_biomarker_days',
    `${scope}&select=day,analysis_version,input_revision,interval_start_utc,interval_end_utc,status,` +
    `document,families_ok,withheld_reasons,run_ms,model_revisions,published_at,updated_at` +
    `&order=day.asc,analysis_version.desc`)) ?? [];
  // One row per requested day: the first row per day in analysis_version.desc order is the latest.
  const byDay = new Map<string, unknown>();
  for (const r of rows as Array<Record<string, unknown>>) {
    if (!byDay.has(String(r.day))) byDay.set(String(r.day), r);
  }
  return days.map((d) => byDay.get(d)).filter((r): r is Record<string, unknown> => r != null);
}

/**
 * `GET /anomaly-candidates?since=<result_revision>[&limit=<1..200>][&windows_from=<unix>&windows_to=<unix>]`: anomaly
 * windows published by the VPS model service (TimesFM 3.0 forecast + UniTS reconstruction;
 * supabase/migrations/20261007180000_anomaly_service.sql) for the credential's owner and the resolved device, oldest
 * change first, after the caller's cursor. A candidate is NOT an alert: the phone's verification stage decides
 * (WatchdogVerifier.swift). Retracted rows are returned so the phone can drop them. `cursor` is the newest
 * result_revision returned (or the caller's `since` when none).
 *
 * Opt-in (20261009150200): with `windows_from` / `windows_to` (both, at most 3 days) the response also carries
 * `windows`, every half-hour window the service judged or withheld that starts in the range, oldest first:
 * `{start_ts, end_ts, usable, reason, context: {kind, mix_basis, minutes, mix}, models: [{model, channel_group,
 * score, p, usable, reason}]}`. `reason` is canonical (contracts/reason-codes.json data-reason-1:
 * `{code, certainty, subcode?, legacy}`, `legacy` the service's own value), null for a scored window; `context.mix`
 * the shares of the window's minutes in an exercise session / recovery / neither / unknown, asleep, off the wrist,
 * per activity class and quality class (measurement_context_minutes; null with `mix_basis: none` when no minute row
 * exists), and `reason_codes_version` names the vocabulary. Without the parameters the response is unchanged.
 */
export const ANOMALY_CANDIDATES_MAX_ROWS = 200;
const ANOMALY_WINDOWS_MAX_RANGE_SECONDS = 3 * 86_400;

export function parseAnomalyCandidatesQuery(params: URLSearchParams) {
  const since = params.get('since') ?? '0';
  const limit = params.get('limit') ?? String(ANOMALY_CANDIDATES_MAX_ROWS);
  if (!/^\d{1,16}$/.test(since) || !Number.isSafeInteger(Number(since))) throw fail('invalid_cursor', 400);
  if (!/^\d{1,3}$/.test(limit) || Number(limit) < 1 || Number(limit) > ANOMALY_CANDIDATES_MAX_ROWS) {
    throw fail('invalid_limit', 400);
  }
  const from = params.get('windows_from');
  const to = params.get('windows_to');
  if (from == null && to == null) return { since: Number(since), limit: Number(limit) };
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)
      || Number(to) <= Number(from) || Number(to) - Number(from) > ANOMALY_WINDOWS_MAX_RANGE_SECONDS) {
    throw fail('invalid_windows_range', 400);
  }
  return { since: Number(since), limit: Number(limit), windows: {
    from: new Date(Number(from) * 1000).toISOString(), to: new Date(Number(to) * 1000).toISOString() } };
}

export async function readAnomalyCandidates({ rest, userId, deviceId, since, limit, windows }: {
  rest: Pick<SupabaseRest, 'select'> & Partial<Pick<SupabaseRest, 'rpc'>>; userId: string; deviceId: string;
  since: number; limit: number; windows?: { from: string; to: string };
}) {
  const rows = (await rest.select('anomaly_candidates',
    `user_id=eq.${userId}&device_id=eq.${deviceId}&result_revision=gt.${since}` +
    `&select=candidate_key,start_ts,end_ts,local_day,channels,flagged_by,model_p,score,severity,direction,` +
    `expected,observed,context,quality,model_versions,status,suppressed_reason,result_revision,computed_at` +
    `&order=result_revision.asc&limit=${limit}`)) ?? [];
  const list = rows as Array<Record<string, unknown>>;
  const cursor = list.reduce((m, r) => Math.max(m, Number(r.result_revision) || 0), since);
  if (!windows) return { candidates: list, cursor };
  const read = await rest.rpc!('anomaly_windows_read_v1', {
    p_user: userId, p_device: deviceId, p_from: windows.from, p_to: windows.to,
  });
  return { candidates: list, cursor, windows: Array.isArray(read) ? read : [], reason_codes_version: REASON_CODES_VERSION };
}

/** `GET /exercise-windows`: at most a day per request, at most this many windows per page. */
export const EXERCISE_WINDOWS_MAX_RANGE_SECONDS = 86_400;
export const EXERCISE_WINDOWS_MAX_ROWS = 5_000;

/**
 * `GET /exercise-windows?deviceId=<id>&from=<unix s>&to=<unix s>[&limit=<n>]`: the RecGym exercise head's SHADOW windows
 * (20261009160000_activity_exercise_windows.sql) that start in [from, to), oldest first, owner and device from the
 * credential. `to - from` is at most a day; a full page carries `next_from` to continue from. Every row says its
 * release (`release_mode`, always shadow), the placement the strap was declared at and whether the wrist-trained
 * model supports it. For inspection only: nothing in the app decodes, scores or alerts on these rows.
 */
export function parseExerciseWindowsQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  const limit = params.get('limit') ?? String(EXERCISE_WINDOWS_MAX_ROWS);
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)
      || Number(to) <= Number(from) || Number(to) - Number(from) > EXERCISE_WINDOWS_MAX_RANGE_SECONDS) {
    throw fail('invalid_range', 400);
  }
  if (!/^\d{1,5}$/.test(limit) || Number(limit) < 1 || Number(limit) > EXERCISE_WINDOWS_MAX_ROWS) {
    throw fail('invalid_limit', 400);
  }
  return { from: Number(from), to: Number(to), limit: Number(limit) };
}

export async function readExerciseWindows({ rest, userId, deviceId, from, to, limit }: {
  rest: Pick<SupabaseRest, 'select'>; userId: string; deviceId: string; from: number; to: number; limit: number;
}) {
  const iso = (t: number) => encodeURIComponent(new Date(t * 1000).toISOString());
  const rows = ((await rest.select('activity_exercise_windows',
    `user_id=eq.${userId}&device_id=eq.${deviceId}&window_start=gte.${iso(from)}&window_start=lt.${iso(to)}`
    + '&select=window_start,window_s,model_id,model_version,weights_sha256,scaler_version,preprocessing_version,'
    + 'placement,placement_supported,placement_reason,top_class,top_p,p_null,probs,input_sha256,release_mode,'
    + `input_revision,result_revision,computed_at&order=window_start.asc&limit=${limit}`)) ?? []) as Array<Record<string, any>>;
  const windows: Array<Record<string, any>> = rows.map((r) => ({ ...r, release_mode: 'shadow',
    input_revision: String(r.input_revision), result_revision: String(r.result_revision) }));
  const last = windows.at(-1);
  const nextFrom = windows.length === limit && last
    ? Math.floor(Date.parse(String(last.window_start)) / 1000) + 1 : null;
  return { windows, next_from: nextFrom, release_mode: 'shadow' };
}

const GAIT_WINDOWS_HEAD = 'day,mode,model_version,hop_s,window_s,gait_threshold,n_windows,n_gait,n_prefiltered,'
  + 'input_revision,release_mode,result_revision,computed_at';

/**
 * `GET /gait-windows?days=<YYYY-MM-DD>[,…][&known=<YYYY-MM-DD>:<revision>,…]`: ElderNet's per-window gait
 * detection and gait quality (`gait-windows-1`) plus its own day summary, for up to three UTC days. Same query
 * and `known` rule as `/activity-windows`. A day can hold a shadow and a candidate row (and rows of an older
 * model); the newest computed one is returned. The candidate decode document is never sent. Every row says the
 * release it may be used under (`release_mode`, never production) and the input revision it was computed from; a
 * full row adds the model identity and the producer's authority block (null on older rows), which a client feeds
 * to the shared selection policy (ActivityExpertSelection) rather than trusting.
 */
export async function readGaitWindows({ rest, userId, deviceId, days, known, authorityAware = false }: {
  rest: SupabaseRest; userId: string; deviceId: string; days: string[]; known: Map<string, string>;
  authorityAware?: boolean;
}) {
  const owner = `user_id=eq.${userId}&device_id=eq.${deviceId}`;
  const rows = await rest.select('activity_gait_windows_days',
    `${owner}&day=in.(${days.join(',')})&select=${GAIT_WINDOWS_HEAD}&order=computed_at.desc`) ?? [];
  const newest = new Map<string, any>();
  for (const row of rows) if (!newest.has(row.day)) newest.set(row.day, row);
  const out = [];
  for (const head of newest.values()) {
    const revision = String(head.result_revision);
    const release = { release_mode: expertReleaseMode(head), input_revision: String(head.input_revision) };
    if (known.get(head.day) === revision) {
      out.push({ ...head, ...release, result_revision: revision, unchanged: true });
      continue;
    }
    const body = (await rest.select('activity_gait_windows_days',
      `${owner}&day=eq.${head.day}&mode=eq.${encodeURIComponent(head.mode)}`
      + `&model_version=eq.${encodeURIComponent(head.model_version)}`
      + '&select=result_revision,input_revision,release_mode,mode,authority,summary,windows,model_id,weights,'
      + 'weights_digest,upstream_commit,preprocessing_version'))?.[0];
    if (!body) continue;
    const bodyRelease = expertReleaseMode(body);
    // A caller without the authority capability (a phone built before the policy) installs any row that names a
    // model whose digest checks out as production gait evidence, whatever its mode. No row here is production, so
    // such a caller gets the windows and the day summary (its walking card) but no model, identity or authority
    // block: it stores nothing for its decoder and decodes on HART alone.
    if (!authorityAware) {
      out.push({
        ...head,
        release_mode: bodyRelease,
        input_revision: String(body.input_revision),
        result_revision: String(body.result_revision),
        summary: {
          gait: body.summary?.gait ?? null,
          mean_gait_prob: body.summary?.mean_gait_prob ?? null,
          windows_omitted: body.summary?.windows_omitted === true,
        },
        windows: body.windows ?? null,
      });
      continue;
    }
    out.push({
      ...head,
      // The body's own release and revision describe the windows sent (a republish between the reads).
      release_mode: bodyRelease,
      input_revision: String(body.input_revision),
      identity: {
        model_id: body.model_id,
        model_version: head.model_version,
        weights_digest: body.weights_digest,
        upstream_commit: body.upstream_commit,
        preprocessing_version: body.preprocessing_version,
      },
      // The producer's view, never above the row's release.
      authority: body.authority && typeof body.authority === 'object' && !Array.isArray(body.authority)
        ? { ...body.authority, release_mode: lowerRelease(body.authority.release_mode, bodyRelease) }
        : null,
      result_revision: String(body.result_revision),
      // Enough for a client to rebuild the model the windows came from and pin it (`GaitQualityModelInfo`).
      model: {
        model_id: body.model_id,
        model_version: head.model_version,
        weights: body.weights,
        weights_digest: body.weights_digest,
        upstream_commit: body.upstream_commit,
        preprocessing_version: body.preprocessing_version,
        window_s: head.window_s,
        hop_s: head.hop_s,
        gait_threshold: head.gait_threshold,
      },
      summary: {
        gait: body.summary?.gait ?? null,
        mean_gait_prob: body.summary?.mean_gait_prob ?? null,
        windows_omitted: body.summary?.windows_omitted === true,
      },
      windows: body.windows ?? null,
    });
  }
  return out;
}

/**
 * `GET /placement?deviceId=<id>`: the strap's resolved placement timeline (20261009150100): the declarations on the
 * strap, its aliases and the installations provably bound to it (the phone's own `installation:<source>:my-whoop`
 * declarations included), later declaration winning, plus the owner's device-less declarations (`scope: account`).
 * Each piece names the device it was declared on (external id) and what it means for a wrist-trained model
 * (`wrist_model_reason`: none for wrist, `placement_unsupported` confirmed for bicep / other, `placement_unknown`
 * for unknown). Null when no deviceId was asked for; the device resolves like every other route's.
 */
export async function readResolvedPlacement({ rest, userId, sourceId, externalDeviceId }: {
  rest: Pick<SupabaseRest, 'select' | 'rpc'>; userId: string; sourceId: string; externalDeviceId: string | null;
}) {
  if (externalDeviceId == null) return null;
  if (!isSafeExternalDeviceId(externalDeviceId)) throw fail('invalid_device_id', 400);
  const deviceId = await findNoopDevice({ rest, userId, sourceId, externalDeviceId });
  if (!deviceId) throw fail('device_registration_pending', 409);
  const intervals = await rest.rpc('placement_resolved_read_v1', { p_user: userId, p_device: deviceId });
  return { device_id: externalDeviceId, intervals: Array.isArray(intervals) ? intervals : [] };
}

async function boundedBody(req: Request, maxBytes = 8192): Promise<any> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > maxBytes) throw fail('payload_too_large', 413);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw fail('invalid_body', 400); }
}

/**
 * `POST /stretch-feedback`: validate every item, resolve each item's optional device to one the caller
 * owns (an id that does not resolve is stored as no device, never an error), and hand only the valid items
 * to `upsert_activity_stretch_feedback` with the owner taken from the credential. Rejected items are
 * reported back individually; the last-writer-wins decision (saved vs ignored/stale) is the RPC's.
 */
export async function submitStretchFeedback({ rest, userId, sourceId, body }: {
  rest: Pick<SupabaseRest, 'select' | 'rpc'>; userId: string; sourceId: string; body: unknown;
}) {
  const { valid, rejected } = validateStretchFeedback(body);
  const resolved = new Map<string, string | null>();
  const items = [];
  for (const item of valid) {
    const external = item.external_device_id;
    if (external != null && !resolved.has(external)) {
      resolved.set(external, await findNoopDevice({ rest, userId, sourceId, externalDeviceId: external }));
    }
    items.push({ ...item, device_id: external != null ? (resolved.get(external) ?? null) : null });
  }
  let saved: unknown[] = [];
  let ignored: unknown[] = [];
  if (items.length > 0) {
    const result = await rest.rpc('upsert_activity_stretch_feedback', { p_owner: userId, p_items: items });
    saved = Array.isArray(result?.saved) ? result.saved : [];
    ignored = Array.isArray(result?.ignored) ? result.ignored : [];
  }
  return { saved, ignored, rejected };
}

function sleepArguments(value: any, canonicalDevice: string) {
  const keys = ['p_id', 'p_device', 'p_original_start', 'p_original_end', 'p_start', 'p_end',
    'p_tombstone', 'p_expected_revision'];
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).some((key) => !keys.includes(key) && key !== 'p_legacy_revision')
      || keys.some((key) => !(key in value))
      || !isUuid(value.p_id) || value.p_device !== canonicalDevice
      || typeof value.p_tombstone !== 'boolean'
      || !Number.isSafeInteger(value.p_expected_revision) || value.p_expected_revision < 0
      || (value.p_legacy_revision != null && !/^[0-9a-f]{64}$/.test(value.p_legacy_revision))) {
    throw fail('invalid_override', 400);
  }
  for (const key of ['p_original_start', 'p_original_end', 'p_start', 'p_end']) {
    if (typeof value[key] !== 'string' || !Number.isFinite(Date.parse(value[key]))) {
      throw fail('invalid_override', 400);
    }
  }
  return { ...value, p_legacy_revision: value.p_legacy_revision ?? null };
}

export async function handleScoresRequest(req: Request, { rest, cfg: _cfg, fetchImpl: _fetchImpl = fetch }: {
  rest: SupabaseRest;
  cfg: Pick<PushFunctionConfig, 'supabaseUrl' | 'supabaseAnonKey'> & Partial<Pick<PushFunctionConfig, 'allowLegacyEnrollment'>>;
  fetchImpl?: typeof fetch;
}): Promise<Response> {
  const url = new URL(req.url);
  const route = url.pathname.replace(/^\/functions\/v1/, '').replace(/^\/scores/, '') || '/';
  const isRead = req.method === 'GET' && route === '/';
  const isDays = req.method === 'GET' && route === '/days';
  const isSeries = req.method === 'GET' && route === '/series';
  const isActivityWindows = req.method === 'GET' && route === '/activity-windows';
  const isGaitWindows = req.method === 'GET' && route === '/gait-windows';
  // RecGym exercise windows, shadow only (20261009160000): one device, a time range.
  const isExerciseWindows = req.method === 'GET' && route === '/exercise-windows';
  const isDiagnostics = req.method === 'GET' && route === '/diagnostics';
  const isRegister = req.method === 'POST' && route === '/devices';
  const isOverride = req.method === 'POST' && route === '/sleep-overrides';
  const isComputeSubmit = req.method === 'POST' && route === '/compute-requests';
  const isComputeRead = req.method === 'GET' && route === '/compute-requests';
  const isPlacementPost = req.method === 'POST' && route === '/placement';
  const isPlacementGet = req.method === 'GET' && route === '/placement';
  const isStretchFeedback = req.method === 'POST' && route === '/stretch-feedback';
  // Physiology context (contracts.md §8). Device-scoped reads take deviceId from the query like /series;
  // exposure events are account-level and take no device.
  const isContext = req.method === 'GET' && route === '/context';
  const isContextHistory = req.method === 'GET' && route === '/context/history';
  const isExposurePost = req.method === 'POST' && route === '/exposures';
  const isExposureGet = req.method === 'GET' && route === '/exposures';
  const isGroundTruthLabels = req.method === 'POST' && route === '/ground-truth-labels';
  const isSensorBiomarkers = req.method === 'GET' && route === '/sensor-biomarkers';
  const isAnomalyCandidates = req.method === 'GET' && route === '/anomaly-candidates';
  // Metric explanations (20261008000000_metric_insights.sql): account-level, no device.
  const isInsights = req.method === 'POST' && route === '/insights';
  // Per-minute measurement context (20261009130100): one device (deviceId) or every device of the owner.
  const isContextMinutes = req.method === 'GET' && route === '/context-minutes';
  // The phone's per-minute optical evidence (20261009130200); device_id in the body, like /placement.
  const isQualityMinutes = req.method === 'POST' && route === '/quality-minutes';
  // Phone Watchdog episodes + annotations (20261009150000): POST with device_id in the body like /placement; GET
  // for one device (deviceId) or every device of the owner, like /context-minutes.
  const isWatchdogEpisodesPost = req.method === 'POST' && route === '/watchdog-episodes';
  const isWatchdogEpisodesGet = req.method === 'GET' && route === '/watchdog-episodes';
  if (!isRead && !isDays && !isSeries && !isActivityWindows && !isGaitWindows && !isDiagnostics && !isRegister && !isOverride
      && !isComputeSubmit && !isComputeRead && !isPlacementPost && !isPlacementGet && !isStretchFeedback
      && !isContext && !isContextHistory && !isExposurePost && !isExposureGet && !isGroundTruthLabels
      && !isSensorBiomarkers && !isAnomalyCandidates && !isInsights && !isContextMinutes && !isQualityMinutes
      && !isWatchdogEpisodesPost && !isWatchdogEpisodesGet && !isExerciseWindows) {
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (!rest.configured) return Response.json({ error: 'service_role_unconfigured' }, { status: 503 });
  try {
    const jwt = looksLikeJwt(bearerToken(req.headers));
    let user: {id: string; sourceId: string};
    if (jwt) {
      const account = await resolveJwtUser({headers:req.headers,supabaseUrl:_cfg.supabaseUrl,
        anonKey:_cfg.supabaseAnonKey,fetchImpl:_fetchImpl});
      const sourceId = req.headers.get('x-noop-source-id');
      if (!isUuid(sourceId)) throw new IdentityError('registered source required');
      if (isRegister) {
        await rest.rpc('register_account_compute_source',{p_user:account.id,p_source:sourceId});
      } else {
        const registered = await rest.select('compute_account_sources',
          `source_id=eq.${sourceId}&select=user_id,source_id,revoked_at`);
        const installation = await rest.select('noop_app_installations',
          `source_id=eq.${sourceId}&select=user_id,revoked_at`);
        if ((registered?.[0] && registered[0].user_id!==account.id) ||
          (installation?.[0] && installation[0].user_id!==account.id)) {
          throw new IdentityError('source owner mismatch', 403, 'forbidden');
        }
        if (registered?.[0]?.revoked_at!=null || installation?.[0]?.revoked_at!=null) {
          throw new IdentityError('source revoked', 401, 'source_revoked');
        }
        if (!registered?.[0] && !installation?.[0]) throw new IdentityError('registered source required');
      }
      user={id:account.id,sourceId:sourceId!};
    } else {
      const installation=await resolveUploadIdentity({headers:req.headers,rest,allowLegacyFleetUploads:false,
        allowLegacyEnrollment:_cfg.allowLegacyEnrollment===true});
      if (installation.authMode!=='installation' || !installation.sourceId) throw new IdentityError('installation required');
      user={id:installation.id,sourceId:installation.sourceId};
    }
    const requestBody = isRead || isDays || isSeries || isActivityWindows || isGaitWindows || isDiagnostics || isComputeRead
        || isPlacementGet || isContext || isContextHistory || isExposureGet || isSensorBiomarkers
        || isAnomalyCandidates || isContextMinutes || isWatchdogEpisodesGet || isExerciseWindows
      ? null : await boundedBody(req, isStretchFeedback ? STRETCH_FEEDBACK_MAX_BODY_BYTES
        : isExposurePost ? EXPOSURE_MAX_BODY_BYTES
        : isGroundTruthLabels ? GROUND_TRUTH_LABELS_MAX_BODY_BYTES
        : isQualityMinutes ? QUALITY_MINUTES_MAX_BODY_BYTES
        : isWatchdogEpisodesPost ? WATCHDOG_EPISODES_MAX_BODY_BYTES : undefined);
    const externalDeviceId = isRead || isDays || isSeries || isActivityWindows || isGaitWindows || isDiagnostics || isComputeRead
        || isContext || isContextHistory || isSensorBiomarkers || isAnomalyCandidates || isContextMinutes
        || isWatchdogEpisodesGet || isExerciseWindows
      ? url.searchParams.get('deviceId')
      : (isPlacementGet || isStretchFeedback || isExposurePost || isExposureGet || isGroundTruthLabels
        || isInsights) ? null
      : (isPlacementPost || isQualityMinutes || isWatchdogEpisodesPost) ? (requestBody?.device_id ?? null)
      : requestBody?.deviceId;
    // Placement is owner-scoped: GET takes no device, and a POST without device_id is a
    // user-level declaration (the RPC's NULL device scope). Stretch feedback and ground-truth labels
    // carry a device per item, which is resolved leniently inside their handlers, so they have no
    // request-level device.
    if (!isPlacementGet && !isStretchFeedback && !isExposurePost && !isExposureGet && !isGroundTruthLabels
        && !isInsights && !(isPlacementPost && externalDeviceId == null)
        && !((isContextMinutes || isWatchdogEpisodesGet) && externalDeviceId == null)
        && !isSafeExternalDeviceId(externalDeviceId)) throw fail('invalid_device_id', 400);
    const lookup = { userId: user.id, sourceId: user.sourceId, externalDeviceId };
    // Placement resolves its own device scope inside the handlers (POST with device_id,
    // user-level when absent; GET is owner-scoped and never device-scoped).
    const deviceId = isRegister
      ? await createNoopDeviceResolver({ rest })(lookup)
      : (isPlacementPost || isPlacementGet || isStretchFeedback || isExposurePost || isExposureGet
        || isGroundTruthLabels || isInsights
        || ((isContextMinutes || isWatchdogEpisodesGet) && externalDeviceId == null)) ? null
      : await findNoopDevice({ rest, ...lookup });
    const project = _cfg.supabaseUrl.replace(/\/+$/,'');
    const identity = { userId: user.id, sourceId: user.sourceId, deviceId, externalDeviceId, project };
    if (isRegister) return Response.json({ identity });
    if (isDays) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const cursor = url.searchParams.get('cursor') ?? '0';
      const limit = url.searchParams.get('limit') ?? '8';
      const scope = url.searchParams.get('scopeRevision');
      if (!/^\d{1,16}$/.test(cursor) || !Number.isSafeInteger(Number(cursor)) ||
          !/^\d{1,2}$/.test(limit) || Number(limit) < 1 || Number(limit) > 32 ||
          (scope != null && !/^[a-f0-9]{32}$/.test(scope))) throw fail('invalid_cursor', 400);
      const page = await rest.rpc('server_result_days_page', { p_user: user.id, p_device: deviceId,
        p_source: user.sourceId, p_after: Number(cursor), p_limit: Number(limit), p_scope_revision: scope });
      return Response.json({ ...page, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isSeries) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseSeriesQuery(url.searchParams);
      const series = await rest.rpc('server_metric_series_read', {
        p_user: user.id, p_from: query.from, p_to: query.to, ...(query.metrics ? { p_metrics: query.metrics } : {}),
      });
      return Response.json({ series, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isActivityWindows) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseActivityWindowsQuery(url.searchParams);
      const days = await readActivityWindows({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ days, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isSensorBiomarkers) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseSensorBiomarkersQuery(url.searchParams);
      const days = await readSensorBiomarkers({ rest, userId: user.id, deviceId, ...query });
      // No stored document for any requested day: 404 (the contract's explicit absent answer).
      if (days.length === 0) throw fail('not_found', 404);
      return Response.json({ days, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isAnomalyCandidates) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseAnomalyCandidatesQuery(url.searchParams);
      const page = await readAnomalyCandidates({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ ...page, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isExerciseWindows) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseExerciseWindowsQuery(url.searchParams);
      const page = await readExerciseWindows({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ ...page, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isGaitWindows) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const query = parseActivityWindowsQuery(url.searchParams);
      const days = await readGaitWindows({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ days, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isComputeSubmit || isComputeRead) {
      if (!deviceId) throw fail('device_registration_pending',409);
      let result: any;
      if (isComputeSubmit) {
        const request=requestBody?.request;
        const keys=['id','family','session_id','event_start','event_end','timezone_id','input_revision',
          'algorithm_version','configuration_version','consent','expires_at'];
        if (!request || Object.keys(request).some(k=>!keys.includes(k)) || keys.some(k=>!(k in request)) ||
          !isUuid(request.id) || !isUuid(request.session_id) || typeof request.family!=='string' ||
          typeof request.timezone_id!=='string' || !Number.isSafeInteger(request.input_revision) || request.input_revision<0 ||
          request.algorithm_version!=='vps-only-1' || request.configuration_version!=='vps-only-1' ||
          typeof request.consent!=='boolean' || !Number.isFinite(Date.parse(request.event_start)) ||
          (request.event_end!==null && !Number.isFinite(Date.parse(request.event_end))) ||
          (request.expires_at!==null && !Number.isFinite(Date.parse(request.expires_at)))) throw fail('invalid_compute_request',400);
        result=await rest.rpc('submit_compute_session_request',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:request});
      } else {
        const requestId=url.searchParams.get('requestId');
        if (!isUuid(requestId)) throw fail('invalid_request_id',400);
        result=await rest.rpc('read_compute_session_result',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:requestId});
      }
      if (result?.result) result.result={...result.result,project};
      return Response.json({...result,identity},{headers:{'cache-control':'no-store'}});
    }
    if (isPlacementPost) {
      // G4 manual placement declaration (spec §6). The edge resolves the OWNER from the
      // installation identity and passes it to set_placement_interval — a client-supplied
      // owner is never accepted. Same auth as every other score read; no new auth path.
      const body = requestBody ?? {};
      const placement = body?.placement;
      const effectiveStart = body?.effective_start;
      const suppliedDevice = body?.device_id ?? null;
      if (typeof placement !== 'string' || !['wrist', 'bicep', 'other', 'unknown'].includes(placement)) {
        throw fail('invalid_placement', 400);
      }
      if (typeof effectiveStart !== 'string' || !Number.isFinite(Date.parse(effectiveStart))) {
        throw fail('invalid_effective_start', 400);
      }
      if (suppliedDevice != null && !isSafeExternalDeviceId(suppliedDevice)) throw fail('invalid_device_id', 400);
      let scopeDevice: string | null = null;
      if (suppliedDevice != null) {
        scopeDevice = await findNoopDevice({ rest, userId: user.id, sourceId: user.sourceId,
          externalDeviceId: suppliedDevice });
        if (!scopeDevice) throw fail('device_registration_pending', 409);
      }
      const interval = await rest.rpc('set_placement_interval', {
        p_owner: user.id, p_placement: placement, p_effective_start: effectiveStart, p_device: scopeDevice,
      });
      return Response.json({ interval }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isStretchFeedback) {
      // Model-tuning labels. The owner comes from the credential, never from the body; same auth as
      // every other score route, no new auth path.
      const outcome = await submitStretchFeedback({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isQualityMinutes) {
      // Owner from the credential, device the caller's own (findNoopDevice; the RPC checks both again).
      if (!deviceId) throw fail('device_registration_pending', 409);
      const outcome = await submitQualityMinutes({ rest, userId: user.id, deviceId, body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isWatchdogEpisodesPost) {
      // The phone's Watchdog journal for the strap it names (findNoopDevice: the canonical strap device, alias-aware);
      // owner and uploading installation from the credential. The RPC checks owner and device again.
      if (!deviceId) throw fail('device_registration_pending', 409);
      const outcome = await submitWatchdogEpisodes({ rest, userId: user.id, sourceId: user.sourceId, deviceId,
        body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isWatchdogEpisodesGet) {
      if (externalDeviceId != null && !deviceId) throw fail('device_registration_pending', 409);
      const query = parseWatchdogEpisodesQuery(url.searchParams);
      const read = await readWatchdogEpisodes({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ ...(externalDeviceId != null ? { device_id: externalDeviceId } : {}), ...read },
        { headers: { 'cache-control': 'no-store' } });
    }
    if (isContextMinutes) {
      // The owner's per-minute measurement context: the credential's owner, and the caller's own device when one
      // is named (findNoopDevice; the RPC checks both again), else every device of the owner.
      if (externalDeviceId != null && !deviceId) throw fail('device_registration_pending', 409);
      const query = parseContextMinutesQuery(url.searchParams);
      const minutes = await readContextMinutes({ rest, userId: user.id, deviceId, ...query });
      return Response.json({ ...minutes, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isContext || isContextHistory) {
      // One device-day's context document, or the device's episodes/bouts/daily values over a range. The
      // owner is the credential's and the device the caller's own (findNoopDevice); the RPCs check both again.
      if (!deviceId) throw fail('device_registration_pending', 409);
      if (isContext) {
        const query = parseContextQuery(url.searchParams);
        const context = await rest.rpc('physiology_context_read_v1', {
          p_user: user.id, p_device: deviceId, p_day: query.day, p_mode: query.mode, p_metric: query.metric,
        });
        return Response.json({ context, identity }, { headers: { 'cache-control': 'no-store' } });
      }
      const query = parseContextHistoryQuery(url.searchParams);
      const history = await rest.rpc('physiology_context_history_read_v1', {
        p_user: user.id, p_device: deviceId, p_from: query.from, p_to: query.to, p_mode: query.mode,
      });
      return Response.json({ history, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isExposurePost) {
      // Account-level exposure revisions; owner and uploading source from the credential, never the body.
      const outcome = await submitExposureEvents({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json({ ...outcome, identity }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isExposureGet) {
      const query = parseExposureReadQuery(url.searchParams);
      const read = await rest.rpc('exposure_events_read_v1', {
        p_owner: user.id, p_from: query.from, p_to: query.to, p_include_history: query.history,
      });
      return Response.json({
        events: Array.isArray(read?.events) ? read.events : [],
        ...(query.history ? { revisions: Array.isArray(read?.revisions) ? read.revisions : [] } : {}),
        truncated: read?.truncated === true,
        identity,
      }, { headers: { 'cache-control': 'no-store' } });
    }
    if (isInsights) {
      // The cached explanation of one metric when its inputs are unchanged; otherwise the insight worker is
      // queued and the previous explanation comes back marked stale. The owner comes from the credential. The
      // app draws the value and the chart from its own data, so any failure here only hides the explanation.
      const metric = requestBody?.metric;
      if (typeof metric !== 'string' || !INSIGHT_METRICS.has(metric)) throw fail('invalid_metric', 400);
      const outcome = await rest.rpc('metric_insight_request_v1', { p_user: user.id, p_metric: metric });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isGroundTruthLabels) {
      // Ground-truth activity labels. The owner comes from the credential, never from the body; same
      // auth as every other score route, no new auth path.
      const outcome = await submitGroundTruthLabels({ rest, userId: user.id, sourceId: user.sourceId, body: requestBody });
      return Response.json(outcome, { headers: { 'cache-control': 'no-store' } });
    }
    if (isPlacementGet) {
      // Owner-scoped read for reconciliation. device_id is returned as the EXTERNAL device id
      // (the id the phone registered and sends on ingest), so the phone's per-device grouping
      // in PlacementCloudSync.reconcile matches its local store.
      const rows = (await rest.select('placement_intervals',
        `owner=eq.${user.id}&select=id,device_id,placement,effective_start,effective_end,source,revision&order=effective_start.asc`)) ?? [];
      const internalIds = [...new Set(rows.map((r: any) => r.device_id).filter(Boolean))];
      let externalById: Record<string, string | null> = {};
      if (internalIds.length > 0) {
        const devices = (await rest.select('devices',
          `user_id=eq.${user.id}&id=in.(${internalIds.join(',')})&select=id,external_device_id`)) ?? [];
        for (const d of devices) externalById[d.id] = d.external_device_id ?? null;
      }
      const intervals = rows.map((r: any) => ({
        id: r.id,
        device_id: r.device_id != null ? (externalById[r.device_id] ?? r.device_id) : null,
        placement: r.placement,
        effective_start: r.effective_start,
        effective_end: r.effective_end ?? null,
        source: r.source,
        revision: r.revision,
      }));
      // `deviceId` (optional): the strap's placement as every server lane now reads it
      // (20261009150100 placement_resolved_read_v1).
      const resolved = await readResolvedPlacement({ rest, userId: user.id, sourceId: user.sourceId,
        externalDeviceId: url.searchParams.get('deviceId') });
      return Response.json({ intervals, ...(resolved ? { resolved } : {}) },
        { headers: { 'cache-control': 'no-store' } });
    }
    if (isOverride) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const args = sleepArguments(requestBody?.arguments, deviceId);
      const revision = await rest.rpc('enrolled_physiology_sleep_override', { ...args, p_user: user.id });
      return Response.json(revision);
    }
    if (isDiagnostics) {
      const day = url.searchParams.get('day') || utcDay();
      const parsed = new Date(day);
      if (!DAY_RE.test(day) || !Number.isFinite(parsed.getTime()) || utcDay(parsed) !== day) throw fail('invalid_day', 400);
      if (!deviceId) throw fail('device_registration_pending', 409);
      // G7 single owner-scoped diagnostic surface. The RPC (schema_version 2) reports
      // day bounds/zone, stream status + coverage + largest gap, scoring_jobs_v2 queue
      // age, projection revision, durable-vs-verified archive, and explicit blockers,
      // all for THIS owner/source/device/day only. Same auth as every other score read;
      // no new auth paths, and NO owner/device identity in the payload (the route is
      // owner-scoped by auth, exactly as before).
      const diagnostics = await rest.rpc('server_pipeline_diagnostics', {
        p_user: user.id, p_source: user.sourceId, p_device: deviceId, p_day: day,
      });
      return Response.json(diagnostics, { headers: { 'cache-control': 'no-store' } });
    }
    const day = url.searchParams.get('day') || utcDay();
    const body = await readOwnerDayScores({ rest, userId: user.id, day, deviceId });
    const overlay = body.server_scoring as any;
    if (overlay?.compute) {
      overlay.compute={...overlay.compute,project,source_id:user.sourceId};
      for (const result of Object.values(overlay.compute.families ?? {}) as any[]) {
        result.project=project; result.source_id=user.sourceId;
      }
    }
    if (!jwt && deviceId && overlay && typeof overlay === 'object') {
      try {
        const hosted = await readHostedSnapshot({ rest, userId: user.id, deviceId, day });
        if (hosted) overlay.hosted_snapshot = hosted;
      } catch {
        console.error('[scores] hosted snapshot read failed');
      }
    }
    return Response.json({ ...body, identity }, { headers: { 'cache-control': 'no-store' } });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: err.code }, { status: err.status || 401 });
    if ([400, 403, 404, 409, 413].includes(err?.status)) {
      return Response.json({ error: err.code || 'request_rejected' }, { status: err.status });
    }
    console.error('[scores] request failed');
    return Response.json({ error: 'scores_unavailable' }, { status: 500 });
  }
}
