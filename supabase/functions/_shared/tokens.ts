// Port of the retired Node receiver + resolvePushUser.js, narrowed to the edge context:
// a bearer is either a Supabase Auth JWT (validated against auth/v1/user) or an opaque `noop_`
// ingest token (SHA-256 lookup in noop_ingest_tokens). There is no dev-user or device-token
// fallback here — the functions are always production.
import { createHash } from 'node:crypto';
import { isUuid } from './keys.ts';
import type { SupabaseRest } from './rest.ts';

export const INGEST_TOKEN_PREFIX = 'noop_';
export const FLEET_TOKEN_HEADER = 'x-noop-fleet-token';

export type TokenKind = 'legacy_upload' | 'fleet' | 'installation';
export type UploadAuthMode = 'installation' | 'legacy_fleet';
/**
 * Where an installation credential came from. `supabase_auth` credentials are minted by
 * provisioning behind a verified Supabase session and are the sole upload credential.
 * `enrollment_code` credentials predate Auth: they additionally need the shared fleet header and
 * are honored only while the server explicitly enables the legacy compatibility path.
 */
export type ProvisioningMethod = 'supabase_auth' | 'enrollment_code';

export class IdentityError extends Error {
  status: number;
  code: string;
  constructor(message: string, status = 401, code = 'unauthorized') {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function looksLikeJwt(token: unknown): boolean {
  const parts = String(token || '').split('.');
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

export function hashIngestToken(token: unknown): string {
  return createHash('sha256').update(String(token || ''), 'utf8').digest('hex');
}

export function bearerToken(headers: Headers): string {
  const auth = headers.get('authorization') || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7).trim();
  return '';
}

export function fleetToken(headers: Headers): string {
  const value = (headers.get(FLEET_TOKEN_HEADER) || '').trim();
  if (value.startsWith('Bearer ')) return value.slice(7).trim();
  return value;
}

// GoTrue reports malformed/expired JWTs as 403 with the machine code bad_jwt.
// Do not turn an arbitrary forbidden response or a message substring into renewal.
async function authFailureCode(response: Response): Promise<string | null> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const bytes: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.byteLength;
      if (size > 4096) return null;
      bytes.push(part.value);
    }
    const body = new Uint8Array(size); let offset = 0;
    for (const part of bytes) { body.set(part, offset); offset += part.byteLength; }
    const value = JSON.parse(new TextDecoder().decode(body));
    return typeof value?.error_code === 'string' ? value.error_code : null;
  } catch { return null; }
  finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}

export async function lookupAuthUser({ accessToken, supabaseUrl, anonKey, fetchImpl = fetch }: {
  accessToken: string;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  if (!accessToken || !supabaseUrl || !anonKey) return null;
  let res: Response;
  try {
    res = await fetchImpl(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(15_000),
    });
  } catch { throw new IdentityError('account authorization unavailable', 503, 'auth_service_unavailable'); }
  if (!res.ok) {
    if (res.status === 403 && await authFailureCode(res) === 'bad_jwt') return null;
    await res.body?.cancel();
    if (res.status === 401) return null;
    if (res.status === 403) throw new IdentityError('account access forbidden', 403, 'forbidden');
    throw new IdentityError('account authorization unavailable', 503, 'auth_service_unavailable');
  }
  const u = await res.json().catch(() => null);
  if (u?.id && isUuid(u.id)) {
    return {
      id: u.id as string,
      email: u.email || null,
      source: 'jwt',
      // GoTrue reports a confirmed address as a non-null timestamp; an anonymous user has no
      // address at all. Provisioning requires a real, verified account.
      emailConfirmed: Boolean(u.email) && (u.email_confirmed_at != null || u.confirmed_at != null),
      anonymous: u.is_anonymous === true,
    };
  }
  return null;
}

function tokenKind(row: any): TokenKind {
  const value = String(row?.token_kind || 'legacy_upload');
  if (value === 'fleet' || value === 'installation') return value;
  return 'legacy_upload';
}

/** Provenance of an installation token row; anything unrecognized is untrusted (null). */
export function provisioningMethod(row: any): ProvisioningMethod | null {
  const value = row?.provisioning_method;
  return value === 'supabase_auth' || value === 'enrollment_code' ? value : null;
}

function tokenExpired(row: any, now: Date): boolean {
  if (!row?.expires_at) return false;
  const expires = Date.parse(String(row.expires_at));
  return !Number.isFinite(expires) || expires <= now.getTime();
}

export async function lookupOpaqueToken({
  token,
  rest,
  now = () => new Date(),
}: {
  token: string;
  rest: SupabaseRest;
  now?: () => Date;
}) {
  if (!token.startsWith(INGEST_TOKEN_PREFIX) || token.length <= INGEST_TOKEN_PREFIX.length) return null;
  const tokenHash = hashIngestToken(token);
  const rows = await rest.select(
    'noop_ingest_tokens',
    `token_hash=eq.${tokenHash}&select=id,user_id,label,token_kind,source_id,expires_at,enrollment_code_id,provisioning_method,created_at,last_used_at,revoked_at`,
  );
  const row = rows?.[0];
  if (row?.revoked_at != null) {
    if (tokenKind(row) === 'installation') {
      throw new IdentityError('installation revoked', 401, 'installation_revoked');
    }
    return null;
  }
  if (!row?.id || tokenExpired(row, now())) return null;
  try {
    await rest.patch('noop_ingest_tokens', { last_used_at: now().toISOString() }, `id=eq.${row.id}`);
  } catch {
    // Authentication remains valid if the best-effort usage timestamp cannot be written.
  }
  return {
    ...row,
    token_kind: tokenKind(row),
  };
}

export async function resolveJwtUser({ headers, supabaseUrl, anonKey, fetchImpl = fetch }: {
  headers: Headers;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  const token = bearerToken(headers);
  if (!token || !looksLikeJwt(token)) throw new IdentityError('authentication required');
  const user = await lookupAuthUser({ accessToken: token, supabaseUrl, anonKey, fetchImpl });
  if (!user) throw new IdentityError('authentication required');
  return user;
}

/**
 * Resolve the FRWHOOP user for NOOP push. Order with an Authorization: Bearer:
 *   1. JWT-shaped bearer validated against Supabase Auth → source `jwt`
 *   2. If JWT-shaped and validation failed → fail closed (401)
 *   3. Opaque ingest token (SHA-256 hash lookup) → source `ingest_token`
 * No bearer at all → 401. (The Node backend's device-token/dev-user fallbacks are dev-only and
 * deliberately absent here.)
 */
export async function resolvePushUser({ headers, rest, supabaseUrl, anonKey, fetchImpl = fetch }: {
  headers: Headers;
  rest: SupabaseRest;
  supabaseUrl: string;
  anonKey: string;
  fetchImpl?: typeof fetch;
}) {
  const token = bearerToken(headers);
  if (!token) throw new IdentityError('authentication required');

  if (looksLikeJwt(token)) {
    const jwtUser = await lookupAuthUser({ accessToken: token, supabaseUrl, anonKey, fetchImpl });
    if (jwtUser) return jwtUser;
    throw new IdentityError('authentication required');
  }

  const row = await lookupOpaqueToken({ token, rest });
  if (!row?.user_id || row.token_kind === 'fleet') throw new IdentityError('authentication required');
  return {
    id: row.user_id as string,
    email: null,
    source: 'ingest_token',
    tokenId: row.id,
    tokenKind: row.token_kind as TokenKind,
    sourceId: row.source_id || null,
  };
}

/** Validate the lower-trust build/fleet credential. It must be explicitly classified as fleet. */
export async function resolveFleetAuthorization({
  headers,
  rest,
  fromAuthorization = false,
}: {
  headers: Headers;
  rest: SupabaseRest;
  fromAuthorization?: boolean;
}) {
  const token = fromAuthorization ? bearerToken(headers) : fleetToken(headers);
  if (!token || looksLikeJwt(token)) throw new IdentityError('fleet authorization required');
  const row = await lookupOpaqueToken({ token, rest });
  if (!row || row.token_kind !== 'fleet') {
    throw new IdentityError('fleet authorization required');
  }
  return { tokenId: row.id as string, tokenKind: row.token_kind as TokenKind };
}

/**
 * Upload identity is fail-closed. A Supabase-Auth-provisioned installation token is bound
 * server-side to exactly (user_id, source_id) and is the whole credential: no shared build/fleet
 * secret exists on that path. A pre-Auth enrollment-code installation token additionally needs the
 * separate fleet credential and is honored only while the server explicitly enables
 * `allowLegacyEnrollment`. The optional legacy path applies only when no identity header is present
 * and is explicitly enabled by the server environment.
 */
export async function resolveUploadIdentity({
  headers,
  rest,
  allowLegacyFleetUploads = false,
  allowLegacyEnrollment = false,
}: {
  headers: Headers;
  rest: SupabaseRest;
  allowLegacyFleetUploads?: boolean;
  allowLegacyEnrollment?: boolean;
}) {
  const token = bearerToken(headers);
  if (!token || looksLikeJwt(token)) throw new IdentityError('installation authorization required');
  const identity = await lookupOpaqueToken({ token, rest });
  if (!identity) throw new IdentityError('installation authorization required');

  if (identity.token_kind === 'installation') {
    if (!identity.user_id || !isUuid(identity.user_id) || !identity.source_id || !isUuid(identity.source_id)) {
      throw new IdentityError('installation authorization required');
    }
    const provisioning = provisioningMethod(identity);
    if (provisioning === 'enrollment_code') {
      if (!allowLegacyEnrollment) {
        throw new IdentityError('legacy enrollment is disabled', 401, 'legacy_enrollment_disabled');
      }
      await resolveFleetAuthorization({ headers, rest });
    } else if (provisioning !== 'supabase_auth') {
      // Unknown provenance is never trusted: it cannot be classified as either credential model.
      throw new IdentityError('installation authorization required');
    }
    const installations = await rest.select(
      'noop_app_installations',
      `user_id=eq.${identity.user_id}&source_id=eq.${identity.source_id}&select=user_id,source_id,revoked_at`,
    );
    if (!installations?.[0]) throw new IdentityError('installation authorization required');
    if (installations[0].revoked_at != null) {
      throw new IdentityError('installation revoked', 401, 'installation_revoked');
    }
    try {
      await rest.patch(
        'noop_app_installations',
        { last_seen_at: new Date().toISOString() },
        `source_id=eq.${identity.source_id}&user_id=eq.${identity.user_id}`,
      );
    } catch {
      // A telemetry timestamp cannot make an otherwise valid upload identity unavailable.
    }
    return {
      id: identity.user_id as string,
      email: null,
      source: 'installation_token',
      sourceId: identity.source_id as string,
      tokenId: identity.id as string,
      authMode: 'installation' as UploadAuthMode,
      provisioning: provisioning as ProvisioningMethod,
    };
  }

  // Presence of a malformed/wrong-kind fleet header must never make an invalid installation token
  // fall through to the rollout path.
  if (fleetToken(headers)) throw new IdentityError('installation authorization required');
  if (!allowLegacyFleetUploads || identity.token_kind !== 'legacy_upload' || !isUuid(identity.user_id)) {
    throw new IdentityError('installation authorization required');
  }
  return {
    id: identity.user_id as string,
    email: null,
    source: 'legacy_ingest_token',
    sourceId: null,
    tokenId: identity.id as string,
    authMode: 'legacy_fleet' as UploadAuthMode,
  };
}

/** Public shape of an ingest-token row (never the hash). Mirrors the retired Node receiver */
export function publicIngestTokenRow(row: any): Record<string, unknown> | null {
  if (!row) return null;
  return {
    id: row.id,
    label: row.label || '',
    tokenKind: tokenKind(row),
    sourceId: row.source_id || null,
    expiresAt: row.expires_at || null,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at || null,
    revokedAt: row.revoked_at || null,
  };
}

/**
 * Mint / list / revoke opaque `noop_` ingest tokens over the service-role REST client.
 * Port of the retired Node receiver createIngestTokenStore — the Edge half of the
 * token lifecycle that Phase 1 of the backend retirement adds (POST/GET/DELETE /tokens).
 */
/** Base64url (RFC 4648 §5) from raw bytes — mirrors Node Buffer.toString('base64url'). */
function bytesToBase64Url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function generateIngestToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `${INGEST_TOKEN_PREFIX}${bytesToBase64Url(bytes)}`;
}

export function createIngestTokenStore({ rest }: { rest: SupabaseRest }) {
  return {
    configured: rest.configured,
    async mint({ userId, label = '' }: { userId: string; label?: string }) {
      const token = generateIngestToken();
      const tokenHash = hashIngestToken(token);
      const rows = await rest.upsert('noop_ingest_tokens', {
        user_id: userId,
        token_hash: tokenHash,
        label: String(label || '').slice(0, 120),
        token_kind: 'legacy_upload',
      });
      const row = Array.isArray(rows) ? rows[0] : rows;
      return { token, row: publicIngestTokenRow(row) };
    },
    async list({ userId }: { userId: string }) {
      const rows = await rest.select(
        'noop_ingest_tokens',
        `user_id=eq.${userId}&order=created_at.desc&select=id,label,token_kind,source_id,expires_at,created_at,last_used_at,revoked_at`,
      );
      return (rows || []).map(publicIngestTokenRow);
    },
    async revoke({ userId, id }: { userId: string; id: string }) {
      const rows = await rest.patch(
        'noop_ingest_tokens',
        { revoked_at: new Date().toISOString() },
        `id=eq.${id}&user_id=eq.${userId}&revoked_at=is.null&select=id,label,token_kind,source_id,expires_at,created_at,last_used_at,revoked_at`,
      );
      const row = Array.isArray(rows) ? rows[0] : rows;
      return publicIngestTokenRow(row);
    },
  };
}
