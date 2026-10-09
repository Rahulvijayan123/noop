// Account-sync policy: what the server tells the app about keeping a signed-in account in sync.
//
// A signed-in account must keep syncing. The server says so (provisioning, push capabilities and coach status
// all carry `syncPolicy`), and the app enforces it: it never treats cloud sync as optional for an account and
// warns once the last accepted upload is older than `staleAfterHours`. The switch exists only so the rule can
// be relaxed later without an app release; nothing on the server stops accepting uploads because of it.
//
//   NOOP_SYNC_REQUIRED             on unless exactly `0`, `false`, `no` or `off` (any case)
//   NOOP_SYNC_STALE_AFTER_HOURS    a whole number of hours, 1..720 (larger is capped); anything else is 24

export interface SyncPolicy {
  required: boolean;
  staleAfterHours: number;
}

export const DEFAULT_SYNC_STALE_AFTER_HOURS = 24;
/** The same bounds account_sync_health_v1 / my_sync_health_v1 enforce (20261009110000_account_sync_health.sql). */
export const MIN_SYNC_STALE_AFTER_HOURS = 1;
export const MAX_SYNC_STALE_AFTER_HOURS = 720;

const OFF = new Set(['0', 'false', 'no', 'off']);

export function syncPolicyFromEnv(env: Record<string, string | undefined> = Deno.env.toObject()): SyncPolicy {
  const required = !OFF.has(String(env.NOOP_SYNC_REQUIRED ?? '').trim().toLowerCase());
  const hours = String(env.NOOP_SYNC_STALE_AFTER_HOURS ?? '').trim();
  const parsed = /^\d+$/.test(hours) ? Number(hours) : NaN;
  const staleAfterHours = parsed >= MIN_SYNC_STALE_AFTER_HOURS
    ? Math.min(parsed, MAX_SYNC_STALE_AFTER_HOURS)
    : DEFAULT_SYNC_STALE_AFTER_HOURS;
  return { required, staleAfterHours };
}

/** The wire shape: a fresh object, so a caller can never mutate a shared policy through a reply. */
export function syncPolicyBody(policy: SyncPolicy): SyncPolicy {
  return { required: policy.required, staleAfterHours: policy.staleAfterHours };
}
