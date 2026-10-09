// Per-minute measurement context (docs/context-watchdog/MEASUREMENT_CONTEXT.md;
// 20261009130100_measurement_context_minutes.sql): the scores route's read of the stored minutes.
import type { SupabaseRest } from './rest.ts';

/** One call returns at most a day of minutes per device (and at most this many rows in all). */
export const CONTEXT_MINUTES_MAX_ROWS = 1440;
const CONTEXT_MINUTES_MAX_RANGE_SECONDS = CONTEXT_MINUTES_MAX_ROWS * 60;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

/**
 * `GET /context-minutes?from=<unix>&to=<unix>[&deviceId=<id>]`: the half-open range [from, to) of at most 1440
 * minutes. Anything malformed is rejected before the database is asked.
 */
export function parseContextMinutesQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) throw fail('invalid_range', 400);
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > CONTEXT_MINUTES_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  return { from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString() };
}

/**
 * The owner's minutes in the range: one device, or every device of the owner when `deviceId` is null. Rows come back
 * oldest first with canonical reasons (each with its effect and family), the version rows they reference, and
 * `truncated` when more than 1440 rows matched. Owner and device are checked again by the RPC.
 */
export async function readContextMinutes({ rest, userId, deviceId, from, to }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string | null; from: string; to: string;
}) {
  const read = await rest.rpc('measurement_context_minutes_read_v1', {
    p_user: userId, p_device: deviceId, p_from: from, p_to: to,
  });
  return {
    rows: Array.isArray(read?.rows) ? read.rows : [],
    versions: read?.versions && typeof read.versions === 'object' && !Array.isArray(read.versions) ? read.versions : {},
    truncated: read?.truncated === true,
  };
}
