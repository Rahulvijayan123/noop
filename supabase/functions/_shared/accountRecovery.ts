// Enrollment-code account recovery.
//
// A tester who used the app before Supabase Auth has an ops-created account that owns all of their
// data, and an enrollment code that proves it is theirs. After signing up and verifying an address,
// the app sends that code here; `recover_noop_account_from_enrollment` moves the verified sign-in onto
// the code's account and deletes the empty sign-up. The caller then signs in again and is the account
// that owns their history. The account comes from the verified JWT alone; the code is hashed with the
// enrollment pepper here and only the hash reaches Postgres.
import { RestAuthorityError, type SupabaseRest } from './rest.ts';
import { EnrollmentError, hashEnrollmentCode } from './enrollment.ts';
import { IdentityError, resolveJwtUser } from './tokens.ts';
import { isUuid } from './keys.ts';

export const ACCOUNT_RECOVERY_PROTOCOL_VERSION = '1.2';
const MAX_BODY_BYTES = 4 * 1024;

class RecoveryError extends Error {
  constructor(readonly code: string, readonly status: number, readonly retryAfterSeconds?: number) {
    super(code);
  }
}

/** RPC outcomes that are answers, not faults. `recovered` and `same_account` are successes. */
const OUTCOMES: Record<string, [number, number?]> = {
  invalid_code: [400],
  rate_limited: [429, 3600],
  email_not_confirmed: [403],
  already_recovered: [409],
  account_active: [409],
  account_not_empty: [409],
};

async function readBounded(req: Request, limit: number): Promise<Uint8Array> {
  const reader = req.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) throw new RecoveryError('payload_too_large', 413);
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

/**
 * `POST /account/recover` `{ "code": "NARA-…" }` — authenticated by a verified Supabase access token.
 *
 * 200 `{ status: "recovered", userId }`: sign in again; the session presented here no longer exists.
 * 200 `{ status: "same_account", userId }`: the caller already is the code's account.
 */
export function createAccountRecovery({
  rest,
  supabaseUrl,
  anonKey,
  pepper,
  fetchImpl = fetch,
}: {
  rest: SupabaseRest;
  supabaseUrl: string;
  anonKey: string;
  pepper: string;
  fetchImpl?: typeof fetch;
}) {
  const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
    Response.json(body, { status, headers: { 'cache-control': 'no-store', ...extra } });
  const failure = (code: string, status: number, extra: Record<string, string> = {}) =>
    reply({ type: 'error', protocolVersion: ACCOUNT_RECOVERY_PROTOCOL_VERSION, code }, status, extra);

  return async (req: Request): Promise<Response> => {
    try {
      if (!rest.configured) throw new RecoveryError('recovery_unavailable', 503);

      let user: Awaited<ReturnType<typeof resolveJwtUser>>;
      try {
        user = await resolveJwtUser({ headers: req.headers, supabaseUrl, anonKey, fetchImpl });
      } catch (err) {
        if (err instanceof IdentityError) throw new RecoveryError(err.code, err.status || 401);
        throw err;
      }
      if (user.anonymous || !user.emailConfirmed) throw new RecoveryError('email_not_confirmed', 403);

      let parsed: any;
      try {
        parsed = JSON.parse(new TextDecoder().decode(await readBounded(req, MAX_BODY_BYTES)));
      } catch (err) {
        if (err instanceof RecoveryError) throw err;
        throw new RecoveryError('malformed_recovery_request', 400);
      }
      let codeHash: string;
      try {
        codeHash = hashEnrollmentCode(parsed?.code, pepper);
      } catch (err) {
        if (err instanceof EnrollmentError) {
          throw new RecoveryError(err.code === 'enrollment_not_configured' ? 'recovery_not_configured' : err.code,
            err.status);
        }
        throw err;
      }

      let result: any;
      try {
        result = await rest.rpc('recover_noop_account_from_enrollment', {
          p_new_user: user.id,
          p_code_hash: codeHash,
        });
      } catch (err) {
        if (err instanceof RestAuthorityError) throw new RecoveryError('recovery_unavailable', 503);
        throw new RecoveryError('recovery_failed', 500);
      }
      const row = Array.isArray(result) ? result[0] : result;
      const status = String(row?.status ?? '');
      if (status === 'recovered' && isUuid(row?.userId) && row.userId !== user.id) {
        return reply({ type: 'accountRecovery', protocolVersion: ACCOUNT_RECOVERY_PROTOCOL_VERSION,
          status, userId: row.userId });
      }
      if (status === 'same_account') {
        return reply({ type: 'accountRecovery', protocolVersion: ACCOUNT_RECOVERY_PROTOCOL_VERSION,
          status, userId: user.id });
      }
      const outcome = OUTCOMES[status];
      if (outcome) throw new RecoveryError(status, outcome[0], outcome[1]);
      throw new RecoveryError('recovery_failed', 500);
    } catch (err) {
      if (err instanceof RecoveryError) {
        return failure(err.code, err.status,
          err.retryAfterSeconds ? { 'retry-after': String(err.retryAfterSeconds) } : {});
      }
      console.error('[push] account recovery failed:', (err as Error)?.name ?? 'error');
      return failure('recovery_failed', 500);
    }
  };
}
