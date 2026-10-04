// Supabase-Auth installation provisioning.
//
// A verified Supabase session (JWT) is the only proof of account ownership. The account comes from
// that JWT alone — the request never carries a user id — and the opaque installation credential
// minted here is bound server-side to exactly (user_id, source_id). Only its SHA-256 hash is stored.
// This is deliberately not a second identity system: `auth.users.id` is the sole cloud user id.
import { isUuid } from './keys.ts';
import { RestAuthorityError, type SupabaseRest } from './rest.ts';
import {
  IdentityError,
  INGEST_TOKEN_PREFIX,
  generateIngestToken,
  hashIngestToken,
  resolveJwtUser,
} from './tokens.ts';

export const PROVISIONING_PROTOCOL_VERSION = '1.2';
export const CURRENT_INSTALLATION_TOKEN_HEADER = 'x-noop-installation-token';
const MAX_BODY_BYTES = 4 * 1024;
const ALLOWED_PLATFORMS = new Set(['ios', 'macos', 'android']);
const TOKEN_SHAPE = /^noop_[A-Za-z0-9_-]{1,256}$/;

export class ProvisioningError extends Error {
  constructor(readonly code: string, readonly status: number, readonly retryAfterSeconds?: number) {
    super(code);
  }
}

function hasControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const code = character.charCodeAt(0);
    return code < 0x20 || code === 0x7f;
  });
}

/** Maps a bounded set of server-controlled RPC messages; arbitrary SQL text is never echoed. */
function rpcProvisioningError(err: unknown): ProvisioningError {
  if (err instanceof RestAuthorityError) return new ProvisioningError('provisioning_unavailable', 503);
  const message = String((err as { message?: unknown })?.message ?? '');
  const mappings: Array<[string, number, number?]> = [
    ['installation_unavailable', 409],
    ['installation_retired', 403],
    ['installation_revoked', 403],
    ['account_retired', 403],
    ['installation_limit', 409],
    ['provision_rate_limited', 429, 300],
    ['provision_identity_invalid', 400],
    ['provision_hash_invalid', 400],
    ['provision_platform_invalid', 400],
    ['provision_app_version_invalid', 400],
    ['provision_ttl_invalid', 500],
    ['provision_service_role_required', 503],
  ];
  for (const [code, status, retryAfter] of mappings) {
    if (message.includes(code)) return new ProvisioningError(code, status, retryAfter);
  }
  return new ProvisioningError('provisioning_failed', 500);
}

export function validateProvisioningRequest(body: unknown) {
  const value = (body && typeof body === 'object' && !Array.isArray(body)
    ? body
    : {}) as Record<string, unknown>;
  const sourceId = typeof value.sourceId === 'string' ? value.sourceId.toLowerCase() : '';
  const platform = typeof value.platform === 'string' ? value.platform.toLowerCase() : '';
  const appVersion = typeof value.appVersion === 'string' ? value.appVersion.trim() : '';
  if (!isUuid(sourceId)) throw new ProvisioningError('invalid_source_id', 400);
  if (!ALLOWED_PLATFORMS.has(platform)) throw new ProvisioningError('invalid_platform', 400);
  if (!appVersion || appVersion.length > 64 || hasControlCharacter(appVersion)) {
    throw new ProvisioningError('invalid_app_version', 400);
  }
  return { sourceId, platform, appVersion };
}

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
      if (size > limit) throw new ProvisioningError('payload_too_large', 413);
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
 * `POST /installations/provision` — authenticated by a verified Supabase access token.
 *
 * - `created`  : first time this account provisions this source id.
 * - `reused`   : the caller presented its still-valid credential; no new secret is issued.
 * - `rotated`  : the account re-provisions its own source (lost/expired/revoked credential).
 * - `upgraded` : a pre-Auth enrollment-code installation of the same account is adopted.
 *
 * A source id that belongs to any other account is reported exactly like a source that does not
 * exist (`installation_unavailable`), so provisioning cannot be used to probe other accounts.
 */
export function createInstallationProvisioning({
  rest,
  supabaseUrl,
  anonKey,
  fetchImpl = fetch,
  newToken = generateIngestToken,
}: {
  rest: SupabaseRest;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
  newToken?: () => string;
}) {
  const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
    Response.json(body, { status, headers: { 'cache-control': 'no-store', ...extra } });
  const failure = (code: string, status: number, extra: Record<string, string> = {}) =>
    reply({ type: 'error', protocolVersion: PROVISIONING_PROTOCOL_VERSION, code }, status, extra);

  return async (req: Request): Promise<Response> => {
    try {
      if (!rest.configured) throw new ProvisioningError('provisioning_unavailable', 503);

      let user: Awaited<ReturnType<typeof resolveJwtUser>>;
      try {
        user = await resolveJwtUser({ headers: req.headers, supabaseUrl, anonKey, fetchImpl });
      } catch (err) {
        if (err instanceof IdentityError) throw new ProvisioningError(err.code, err.status || 401);
        throw err;
      }
      if (user.anonymous || !user.emailConfirmed) {
        throw new ProvisioningError('email_not_confirmed', 403);
      }

      const bytes = await readBounded(req, MAX_BODY_BYTES);
      let parsed: unknown;
      try {
        parsed = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        throw new ProvisioningError('malformed_provisioning_request', 400);
      }
      const request = validateProvisioningRequest(parsed);

      const presented = (req.headers.get(CURRENT_INSTALLATION_TOKEN_HEADER) ?? '').trim();
      if (presented && !TOKEN_SHAPE.test(presented)) {
        throw new ProvisioningError('invalid_installation_token', 400);
      }

      const candidate = newToken();
      if (!candidate.startsWith(INGEST_TOKEN_PREFIX)) throw new ProvisioningError('provisioning_failed', 500);

      let result: any;
      try {
        result = await rest.rpc('provision_noop_installation', {
          p_user_id: user.id,
          p_source_id: request.sourceId,
          p_platform: request.platform,
          p_app_version: request.appVersion,
          p_new_token_hash: hashIngestToken(candidate),
          p_current_token_hash: presented ? hashIngestToken(presented) : null,
        });
      } catch (err) {
        throw rpcProvisioningError(err);
      }
      const row = Array.isArray(result) ? result[0] : result;
      const action = row?.action;
      if (
        !row || row.userId !== user.id || row.sourceId !== request.sourceId ||
        !isUuid(row.tokenId) || !['created', 'reused', 'rotated', 'upgraded'].includes(action)
      ) {
        // The RPC derives ownership from the same arguments; a mismatch is a server fault.
        throw new ProvisioningError('provisioning_failed', 500);
      }

      return reply({
        type: 'installationProvisioning',
        protocolVersion: PROVISIONING_PROTOCOL_VERSION,
        userId: row.userId,
        sourceId: row.sourceId,
        tokenId: row.tokenId,
        action,
        expiresAt: row.expiresAt,
        ...(action === 'reused' ? {} : { installationToken: candidate }),
      }, action === 'created' ? 201 : 200);
    } catch (err) {
      if (err instanceof ProvisioningError) {
        return failure(
          err.code,
          err.status,
          err.retryAfterSeconds ? { 'retry-after': String(err.retryAfterSeconds) } : {},
        );
      }
      if (err instanceof IdentityError) return failure(err.code, err.status || 401);
      console.error('[push] installation provisioning failed:', (err as Error)?.name ?? 'error');
      return failure('provisioning_failed', 500);
    }
  };
}
