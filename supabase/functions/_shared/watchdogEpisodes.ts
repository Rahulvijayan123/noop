// Phone Watchdog episodes and annotations (docs/context-watchdog/WATCHDOG_EPISODES.md;
// 20261009150000_watchdog_episodes.sql): POST and GET scores/watchdog-episodes.
import { reasonCode } from './reasonCodes.ts';
import { isSafeExternalDeviceId } from './keys.ts';
import type { SupabaseRest } from './rest.ts';

/** At most 50 episodes per call, each at most 16 KiB serialized; the body cap leaves room for the envelope. */
export const WATCHDOG_EPISODES_MAX = 50;
export const WATCHDOG_EPISODE_MAX_BYTES = 16 * 1024;
export const WATCHDOG_EPISODES_MAX_BODY_BYTES = WATCHDOG_EPISODES_MAX * WATCHDOG_EPISODE_MAX_BYTES + 4096;
/** GET: a range of at most 90 days (the phone keeps 21), at most 500 episodes. */
const WATCHDOG_EPISODES_MAX_RANGE_SECONDS = 90 * 86_400;
export const WATCHDOG_EPISODES_READ_LIMIT = 500;

const EARLIEST = 1_577_836_800; // 2020-01-01
const LATEST = 4_102_444_800;   // 2100-01-01
const EPISODE_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
const LABEL_RE = /^[A-Za-z0-9._:-]{1,64}$/;
const MAX_SEVERITIES = new Set(['candidate', 'active', 'severe']);
const PEAK_SEVERITIES = new Set(['withinLimits', 'note', 'candidate', 'active', 'severe', 'dataUnavailable']);
const DELIVERIES = new Set(['', 'queued', 'sent', 'denied', 'failed', 'skipped']);
const CERTAINTIES = new Set(['confirmed', 'inferred', 'unknown', 'measured']);
// WatchdogExerciseSnapshot / WatchdogEpisodeAnnotation enums (StrandAnalytics).
const EXERCISE_PHASES = new Set(['session', 'recovery', 'none']);
const REFERENCE_STATES = new Set(['established', 'learning']);
const ANNOTATION_STATUS = new Set(['pending', 'entered', 'skipped', 'expired']);
const EXERTION = new Set(['rest', 'light', 'hard']);
const STRESS = new Set(['low', 'high']);
const ILLNESS = new Set(['felt_off', 'not']);
const SENSOR = new Set(['loose', 'charging', 'just_on', 'other']);

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const isUnix = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= EARLIEST && (v as number) < LATEST;
const isCount = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= 1_000_000;
const isNumber = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
const optional = (v: unknown, ok: (x: unknown) => boolean) => v == null || ok(v);
const text = (max: number) => (v: unknown) => typeof v === 'string' && v.length <= max;
const oneOf = (set: Set<string>) => (v: unknown) => typeof v === 'string' && set.has(v);

/** WatchdogSignalEvidence: name, unit, energy, trustPct, rangeHalf; observed / usual / reconstructed may be null. */
function validSignal(s: unknown): boolean {
  if (!isObject(s)) return false;
  return text(32)(s.name) && (s.name as string).length > 0 && optional(s.unit, text(16))
    && optional(s.observed, isNumber) && optional(s.usual, isNumber) && optional(s.reconstructed, isNumber)
    && optional(s.energy, isNumber) && optional(s.trustPct, Number.isSafeInteger) && optional(s.rangeHalf, isNumber);
}

/** WatchdogExerciseSnapshot (rule exercise-session-1). */
function validExercise(x: unknown): boolean {
  if (!isObject(x)) return false;
  return text(64)(x.rule) && (x.rule as string).length > 0 && oneOf(EXERCISE_PHASES)(x.phase)
    && optional(x.sessionStartUnix, isUnix) && optional(x.sessionLastMovementUnix, isUnix)
    && optional(x.restReference, isNumber) && optional(x.restBasis, text(64))
    && optional(x.ceilingBpm, isNumber) && optional(x.ceilingBasis, text(64))
    && optional(x.sessionReference, oneOf(REFERENCE_STATES)) && optional(x.recoveryReference, oneOf(REFERENCE_STATES))
    && optional(x.routine, text(128));
}

/** WatchdogEpisodeAnnotation; its episodeId must be the episode it is sent with. */
function validAnnotation(a: unknown, episodeId: string): boolean {
  if (!isObject(a)) return false;
  return a.episodeId === episodeId && optional(a.deviceId, text(255)) && isUnix(a.eventUnix)
    && optional(a.enteredUnix, isUnix) && optional(a.reporter, text(32)) && oneOf(ANNOTATION_STATUS)(a.status)
    && optional(a.symptoms, text(1000)) && optional(a.exertion, oneOf(EXERTION)) && optional(a.stress, oneOf(STRESS))
    && optional(a.illness, oneOf(ILLNESS)) && optional(a.sensor, oneOf(SENSOR)) && optional(a.note, text(2000));
}

/** Canonical data reasons (contracts/reason-codes.json): a registered code, a certainty, a listed subcode. */
function validReason(r: unknown): boolean {
  if (!isObject(r) || typeof r.code !== 'string') return false;
  const known = reasonCode(r.code);
  if (!known || !oneOf(CERTAINTIES)(r.certainty)) return false;
  return r.subcode == null || (typeof r.subcode === 'string' && (known.subcodes ?? []).includes(r.subcode));
}

function validVersions(v: unknown): boolean {
  if (!isObject(v)) return false;
  const entries = Object.entries(v);
  return entries.length <= 16 && entries.every(([k, s]) => LABEL_RE.test(k) && typeof s === 'string' && s.length <= 128);
}

export interface WatchdogEpisodesUpload {
  localDeviceId: string | null;
  episodes: Record<string, unknown>[];
}

/**
 * The body the phone sends: `{device_id, local_device_id?, episodes: [...]}` (docs/context-watchdog/WATCHDOG_EPISODES.md).
 * A batch with any malformed episode is refused whole with the first problem's code (400), or 413 for an episode
 * over 16 KiB. Unknown members of an episode are dropped (a newer phone may send more); the nested exercise,
 * annotation and signal objects are kept as sent once their known members check out.
 */
export function validateWatchdogEpisodes(body: unknown): WatchdogEpisodesUpload {
  if (!isObject(body)) throw fail('invalid_body', 400);
  const local = body.local_device_id ?? null;
  if (local !== null && !isSafeExternalDeviceId(local)) throw fail('invalid_local_device_id', 400);
  const list = body.episodes;
  if (!Array.isArray(list) || list.length < 1 || list.length > WATCHDOG_EPISODES_MAX) throw fail('invalid_episodes', 400);
  const seen = new Set<string>();
  const episodes = list.map((item) => {
    if (!isObject(item)) throw fail('invalid_episode', 400);
    if (new TextEncoder().encode(JSON.stringify(item)).length > WATCHDOG_EPISODE_MAX_BYTES) {
      throw fail('episode_too_large', 413);
    }
    const e = item;
    if (typeof e.episode_id !== 'string' || !EPISODE_ID_RE.test(e.episode_id)) throw fail('invalid_episode_id', 400);
    if (seen.has(e.episode_id)) throw fail('duplicate_episode_id', 400);
    seen.add(e.episode_id);
    if (!isUnix(e.opened_at) || !isUnix(e.last_at) || e.last_at < e.opened_at
        || !optional(e.closed_at, (c) => isUnix(c) && c >= (e.opened_at as number))) {
      throw fail('invalid_episode_times', 400);
    }
    if (!isUnix(e.client_updated_at)) throw fail('invalid_client_updated_at', 400);
    if (!oneOf(MAX_SEVERITIES)(e.max_severity) || !optional(e.peak_severity, oneOf(PEAK_SEVERITIES))) {
      throw fail('invalid_severity', 400);
    }
    if (typeof e.safety !== 'boolean' || !optional(e.personal_off, (v) => typeof v === 'boolean')
        || !optional(e.live_alerts, (v) => typeof v === 'boolean')) throw fail('invalid_episode', 400);
    if (!optional(e.notify_delivery, oneOf(DELIVERIES))) throw fail('invalid_notify_delivery', 400);
    if (!optional(e.off_minute_count, isCount) || !optional(e.unavailable_minutes, isCount)) {
      throw fail('invalid_episode', 400);
    }
    if (!optional(e.headline, text(500)) || !optional(e.event_label, (v) => typeof v === 'string' && LABEL_RE.test(v))
        || !optional(e.activity_label, (v) => typeof v === 'string' && LABEL_RE.test(v))) {
      throw fail('invalid_episode', 400);
    }
    if (!optional(e.contributing, (v) => Array.isArray(v) && v.length <= 16 && v.every(text(32)))) {
      throw fail('invalid_episode', 400);
    }
    if (!optional(e.signals, (v) => Array.isArray(v) && v.length <= 16 && v.every(validSignal))) {
      throw fail('invalid_signals', 400);
    }
    if (!optional(e.exercise, validExercise)) throw fail('invalid_exercise', 400);
    if (!optional(e.annotation, (a) => validAnnotation(a, e.episode_id as string))) throw fail('invalid_annotation', 400);
    if (!optional(e.quality_reasons, (v) => Array.isArray(v) && v.length <= 32 && v.every(validReason))) {
      throw fail('invalid_quality_reasons', 400);
    }
    if (!optional(e.versions, validVersions)) throw fail('invalid_versions', 400);
    return {
      episode_id: e.episode_id, opened_at: e.opened_at, last_at: e.last_at, closed_at: e.closed_at ?? null,
      max_severity: e.max_severity, peak_severity: e.peak_severity ?? null, safety: e.safety,
      personal_off: e.personal_off ?? false, notify_delivery: e.notify_delivery ?? '', live_alerts: e.live_alerts ?? true,
      off_minute_count: e.off_minute_count ?? 0, unavailable_minutes: e.unavailable_minutes ?? 0,
      headline: e.headline ?? null, event_label: e.event_label ?? null, activity_label: e.activity_label ?? null,
      contributing: e.contributing ?? null, signals: e.signals ?? null, exercise: e.exercise ?? null,
      annotation: e.annotation ?? null, quality_reasons: e.quality_reasons ?? null, versions: e.versions ?? {},
      client_updated_at: e.client_updated_at,
    };
  });
  return { localDeviceId: local as string | null, episodes };
}

/**
 * Store the phone's episodes for the owner's resolved strap device (watchdog_episodes_upsert_v1: last writer wins on
 * client_updated_at, idempotent). `accepted` counts episodes the server now holds as sent, `skipped_stale` the ones
 * it already holds a newer copy of.
 */
export async function submitWatchdogEpisodes({ rest, userId, sourceId, deviceId, body }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; sourceId: string; deviceId: string; body: unknown;
}) {
  const { localDeviceId, episodes } = validateWatchdogEpisodes(body);
  const out = await rest.rpc('watchdog_episodes_upsert_v1', {
    p_user: userId, p_device: deviceId, p_source: sourceId, p_local_device: localDeviceId, p_episodes: episodes,
  });
  return { accepted: Number(out?.accepted ?? 0), skipped_stale: Number(out?.skipped_stale ?? 0) };
}

/** `GET /watchdog-episodes?from=<unix>&to=<unix>[&deviceId=<id>]`: a half-open range of at most 90 days. */
export function parseWatchdogEpisodesQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) {
    throw fail('invalid_range', 400);
  }
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > WATCHDOG_EPISODES_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  return { from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString() };
}

/** The owner's episodes overlapping the range, oldest first, in the shape the phone sends. */
export async function readWatchdogEpisodes({ rest, userId, deviceId, from, to }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string | null; from: string; to: string;
}) {
  const read = await rest.rpc('watchdog_episodes_read_v1', {
    p_user: userId, p_device: deviceId, p_from: from, p_to: to, p_limit: WATCHDOG_EPISODES_READ_LIMIT,
  });
  return { episodes: Array.isArray(read?.episodes) ? read.episodes : [], truncated: read?.truncated === true };
}
