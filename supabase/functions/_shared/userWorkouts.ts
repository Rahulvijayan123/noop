// Workout mode (docs/context-watchdog/WORKOUTS.md; 20261009170000_user_workouts.sql): POST and GET scores/workouts.
import { isSafeExternalDeviceId, isUuid } from './keys.ts';
import { workoutType } from './workoutTypes.ts';
import type { SupabaseRest } from './rest.ts';

/** At most 50 workouts per call, each at most 4 KiB serialized. */
export const USER_WORKOUTS_MAX = 50;
export const USER_WORKOUT_MAX_BYTES = 4 * 1024;
export const USER_WORKOUTS_MAX_BODY_BYTES = USER_WORKOUTS_MAX * USER_WORKOUT_MAX_BYTES + 4096;
/** GET: a range of at most 90 days, at most 500 workouts. */
const USER_WORKOUTS_MAX_RANGE_SECONDS = 90 * 86_400;
export const USER_WORKOUTS_READ_LIMIT = 500;
/** A workout lasts at most a day; a start or end may be at most this far ahead of the server clock. */
const MAX_DURATION_SECONDS = 86_400;
const CLOCK_SKEW_SECONDS = 120;

const EARLIEST = 1_577_836_800; // 2020-01-01
const LATEST = 4_102_444_800;   // 2100-01-01
const SOURCES = new Set(['manual', 'auto_ended']);
const CATALOGUE_RE = /^workout-types-[0-9]+$/;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const isUnix = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= EARLIEST && (v as number) < LATEST;

export interface UserWorkoutsUpload {
  localDeviceId: string | null;
  workouts: Record<string, unknown>[];
}

/**
 * The body the phone sends: `{device_id, local_device_id?, catalogue_version?, workouts: [{client_id, type,
 * started_at, ended_at|null, source, deleted, notes?, client_updated_at}]}`. A batch with any malformed workout is
 * refused whole with the first problem's code (400), or 413 for a workout over 4 KiB. Unknown members are dropped.
 */
export function validateUserWorkouts(body: unknown, nowSeconds = Math.floor(Date.now() / 1000)): UserWorkoutsUpload {
  if (!isObject(body)) throw fail('invalid_body', 400);
  const local = body.local_device_id ?? null;
  if (local !== null && !isSafeExternalDeviceId(local)) throw fail('invalid_local_device_id', 400);
  if (body.catalogue_version != null
      && (typeof body.catalogue_version !== 'string' || !CATALOGUE_RE.test(body.catalogue_version))) {
    throw fail('invalid_catalogue_version', 400);
  }
  const list = body.workouts;
  if (!Array.isArray(list) || list.length < 1 || list.length > USER_WORKOUTS_MAX) throw fail('invalid_workouts', 400);
  const seen = new Set<string>();
  const workouts = list.map((item) => {
    if (!isObject(item)) throw fail('invalid_workout', 400);
    if (new TextEncoder().encode(JSON.stringify(item)).length > USER_WORKOUT_MAX_BYTES) {
      throw fail('workout_too_large', 413);
    }
    const w = item;
    if (!isUuid(w.client_id)) throw fail('invalid_client_id', 400);
    const id = (w.client_id as string).toLowerCase();
    if (seen.has(id)) throw fail('duplicate_client_id', 400);
    seen.add(id);
    if (!workoutType(w.type)) throw fail('invalid_workout_type', 400);
    const ahead = nowSeconds + CLOCK_SKEW_SECONDS;
    if (!isUnix(w.started_at) || w.started_at > ahead) throw fail('invalid_workout_times', 400);
    if (w.ended_at != null && (!isUnix(w.ended_at) || w.ended_at <= w.started_at || w.ended_at > ahead
                               || w.ended_at - w.started_at > MAX_DURATION_SECONDS)) {
      throw fail('invalid_workout_times', 400);
    }
    if (!isUnix(w.client_updated_at)) throw fail('invalid_client_updated_at', 400);
    if (w.source != null && (typeof w.source !== 'string' || !SOURCES.has(w.source))) throw fail('invalid_source', 400);
    if (w.deleted != null && typeof w.deleted !== 'boolean') throw fail('invalid_workout', 400);
    if (w.notes != null && (typeof w.notes !== 'string' || w.notes.length > 500)) throw fail('invalid_notes', 400);
    return {
      client_id: id, type: w.type, started_at: w.started_at, ended_at: w.ended_at ?? null,
      source: w.source ?? 'manual', deleted: w.deleted ?? false, notes: w.notes ?? null,
      client_updated_at: w.client_updated_at,
    };
  });
  return { localDeviceId: local as string | null, workouts };
}

/**
 * Store the phone's workouts for the owner's resolved strap device (user_workouts_upsert_v1: last writer wins on
 * client_updated_at, idempotent; one workout runs at a time). `accepted` counts workouts the server now holds as sent,
 * `skipped_stale` the ones it already holds a newer copy of, `closed` open workouts closed by a later one.
 */
export async function submitUserWorkouts({ rest, userId, sourceId, deviceId, body }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; sourceId: string; deviceId: string; body: unknown;
}) {
  const { localDeviceId, workouts } = validateUserWorkouts(body);
  const out = await rest.rpc('user_workouts_upsert_v1', {
    p_user: userId, p_device: deviceId, p_source: sourceId, p_local_device: localDeviceId, p_workouts: workouts,
  });
  return {
    accepted: Number(out?.accepted ?? 0), skipped_stale: Number(out?.skipped_stale ?? 0),
    closed: Number(out?.closed ?? 0),
  };
}

/** `GET /workouts?from=<unix>&to=<unix>[&deviceId=<id>][&includeDeleted=1]`: a half-open range of at most 90 days. */
export function parseUserWorkoutsQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) {
    throw fail('invalid_range', 400);
  }
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > USER_WORKOUTS_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  const deleted = params.get('includeDeleted');
  if (deleted != null && deleted !== '0' && deleted !== '1') throw fail('invalid_include_deleted', 400);
  return {
    from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString(), includeDeleted: deleted === '1',
  };
}

/** The owner's workouts overlapping the range, oldest first, each with its type's attributes. */
export async function readUserWorkouts({ rest, userId, deviceId, from, to, includeDeleted }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string | null; from: string; to: string;
  includeDeleted: boolean;
}) {
  const read = await rest.rpc('user_workouts_read_v1', {
    p_user: userId, p_device: deviceId, p_from: from, p_to: to, p_limit: USER_WORKOUTS_READ_LIMIT,
    p_include_deleted: includeDeleted,
  });
  return {
    workouts: Array.isArray(read?.workouts) ? read.workouts : [], truncated: read?.truncated === true,
    catalogue_version: typeof read?.catalogue_version === 'string' ? read.catalogue_version : null,
  };
}

/** The episode snapshot's workout-mode lineage (WatchdogExerciseSnapshot.basis / workoutType). */
export function validExerciseWorkoutLineage(x: Record<string, unknown>): boolean {
  return (x.basis == null || x.basis === 'logged' || x.basis === 'inferred')
    && (x.workoutType == null || workoutType(x.workoutType) !== undefined);
}
