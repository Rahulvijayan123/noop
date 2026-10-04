// `POST /account/recover`: the Edge half of enrollment-code account recovery. The SQL half (the
// credential move itself) runs against real GoTrue in the release checklist; here the RPC is stubbed and
// what is pinned is everything the Edge decides on its own: who the caller is, what reaches Postgres,
// and how each outcome is reported.
import { assertEquals } from 'jsr:@std/assert';
import { createAccountRecovery } from '../_shared/accountRecovery.ts';
import { hashEnrollmentCode } from '../_shared/enrollment.ts';
import { RestAuthorityError } from '../_shared/rest.ts';

const PEPPER = 'test-pepper-that-is-at-least-32-bytes-long';
const USER = '11111111-1111-4111-8111-111111111111';
const LEGACY = '22222222-2222-4222-8222-222222222222';
const CODE = 'NARA-0123-4567-89AB-CDEF-GHJK';
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.c2ln';

function authUser(overrides: Record<string, unknown> = {}) {
  return (async () => Response.json({ id: USER, email: 'tester@example.com',
    email_confirmed_at: '2026-10-04T00:00:00Z', is_anonymous: false, ...overrides })) as unknown as typeof fetch;
}

function harness({ result, error, user = authUser(), pepper = PEPPER }: {
  result?: unknown; error?: unknown; user?: typeof fetch; pepper?: string;
} = {}) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const rest = {
    configured: true,
    rpc: async (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      if (error) throw error;
      return result;
    },
  } as any;
  const handler = createAccountRecovery({ rest, supabaseUrl: 'https://auth.example', anonKey: 'anon',
    pepper, fetchImpl: user });
  return { handler, calls };
}

function request(body: unknown, token: string | null = JWT) {
  return new Request('https://edge.example/functions/v1/push/account/recover', {
    method: 'POST',
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

Deno.test('a recovery sends only the verified user and the peppered code hash, and names the legacy account', async () => {
  const { handler, calls } = harness({ result: { status: 'recovered', userId: LEGACY } });
  const response = await handler(request({ code: CODE.toLowerCase(), userId: LEGACY }));
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  assertEquals(await response.json(), { type: 'accountRecovery', protocolVersion: '1.2',
    status: 'recovered', userId: LEGACY });
  assertEquals(calls, [{ name: 'recover_noop_account_from_enrollment',
    args: { p_new_user: USER, p_code_hash: hashEnrollmentCode(CODE, PEPPER) } }]);
});

Deno.test('the caller already being the code\'s account is a success', async () => {
  const { handler } = harness({ result: { status: 'same_account' } });
  const response = await handler(request({ code: CODE }));
  assertEquals(response.status, 200);
  assertEquals((await response.json()).userId, USER);
});

Deno.test('a reply that names the caller as the recovered account is not believed', async () => {
  const { handler } = harness({ result: { status: 'recovered', userId: USER } });
  const response = await handler(request({ code: CODE }));
  assertEquals(response.status, 500);
  assertEquals((await response.json()).code, 'recovery_failed');
});

for (const [status, http, retryAfter] of [
  ['invalid_code', 400, null],
  ['rate_limited', 429, '3600'],
  ['email_not_confirmed', 403, null],
  ['already_recovered', 409, null],
  ['account_active', 409, null],
  ['account_not_empty', 409, null],
] as const) {
  Deno.test(`the RPC outcome ${status} is reported as ${http}`, async () => {
    const { handler } = harness({ result: { status } });
    const response = await handler(request({ code: CODE }));
    assertEquals(response.status, http);
    assertEquals(response.headers.get('retry-after'), retryAfter);
    assertEquals(await response.json(), { type: 'error', protocolVersion: '1.2', code: status });
  });
}

Deno.test('no session, or an unverified one, never reaches the database', async () => {
  for (const [req, user, code, http] of [
    [request({ code: CODE }, null), authUser(), 'unauthorized', 401],
    [request({ code: CODE }), authUser({ email_confirmed_at: null, confirmed_at: null }), 'email_not_confirmed', 403],
    [request({ code: CODE }), authUser({ is_anonymous: true }), 'email_not_confirmed', 403],
    [request({ code: CODE }), (async () => new Response('{}', { status: 401 })) as unknown as typeof fetch,
      'unauthorized', 401],
  ] as const) {
    const { handler, calls } = harness({ result: { status: 'recovered', userId: LEGACY }, user });
    const response = await handler(req);
    assertEquals([response.status, (await response.json()).code], [http, code]);
    assertEquals(calls.length, 0);
  }
});

Deno.test('malformed requests and codes are refused before the database', async () => {
  for (const [body, code] of [
    ['not json', 'malformed_recovery_request'],
    [{}, 'malformed_enrollment_code'],
    [{ code: 'NARA-TOO-SHORT' }, 'malformed_enrollment_code'],
    [{ code: 'x'.repeat(5000) }, 'payload_too_large'],
  ] as const) {
    const { handler, calls } = harness({ result: { status: 'recovered', userId: LEGACY } });
    const response = await handler(request(body));
    assertEquals((await response.json()).code, code);
    assertEquals(calls.length, 0);
  }
});

Deno.test('a missing pepper or an unreachable database is a 503, never a guess', async () => {
  const noPepper = harness({ pepper: '' });
  const first = await noPepper.handler(request({ code: CODE }));
  assertEquals([first.status, (await first.json()).code], [503, 'recovery_not_configured']);
  assertEquals(noPepper.calls.length, 0);

  const down = harness({ error: new RestAuthorityError(401) });
  const second = await down.handler(request({ code: CODE }));
  assertEquals([second.status, (await second.json()).code], [503, 'recovery_unavailable']);

  const broken = harness({ error: new Error('relation does not exist: secret detail') });
  const third = await broken.handler(request({ code: CODE }));
  assertEquals(third.status, 500);
  assertEquals(await third.json(), { type: 'error', protocolVersion: '1.2', code: 'recovery_failed' });
});
