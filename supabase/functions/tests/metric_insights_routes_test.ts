// POST /scores/insights (20261008000000_metric_insights.sql) against in-memory PostgREST doubles: auth
// (installation bearer, signed-in account + registered source), owner always from the credential and never
// the body, no device scope, the metric allow-list, body bounds, error shapes, and that the route only ever
// forwards to metric_insight_request_v1. The database half is metric_insights_sql_test.ts.
import { assertEquals } from 'jsr:@std/assert';
import { handleScoresRequest, INSIGHT_METRICS } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };
const READY = {
  status: 'ready', metric: 'resting_hr',
  insight: { id: 7, kind: 'explained', stale: false, headline: 'Resting heart rate is near your usual range',
    observed: [], interpretation: [], uncertainty: [], related: [], citations: [], data_through: '2026-10-06' },
};

type Call = { name: string; args: any };

async function fixture(rpc: (call: Call) => any = () => READY) {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'auth-a', token_hash: hashIngestToken('noop_auth_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
    { id: 'auth-b', token_hash: hashIngestToken('noop_auth_b'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet', user_id: USER, source_id: null },
  ]);
  await rest.upsert('noop_app_installations', [
    { user_id: USER, source_id: SOURCE },
    { user_id: OTHER, source_id: OTHER_SOURCE },
  ]);
  const calls: Call[] = [];
  rest.rpc = async (name: string, args: any) => {
    const call = { name, args };
    calls.push(call);
    return rpc(call);
  };
  return { rest, calls };
}

function request({ method = 'POST', bearer = 'noop_auth_a', body = { metric: 'resting_hr' }, raw, headers = {} }: {
  method?: string; bearer?: string | null; body?: unknown; raw?: string; headers?: Record<string, string>;
} = {}) {
  const all: Record<string, string> = { 'content-type': 'application/json', ...headers };
  if (bearer) all.authorization = `Bearer ${bearer}`;
  return new Request('https://test.invalid/functions/v1/scores/insights', {
    method, headers: all,
    body: method === 'GET' || method === 'HEAD' ? undefined : (raw ?? JSON.stringify(body)),
  });
}

Deno.test('POST /insights: owner from the credential, no device, the RPC outcome passed through uncached', async () => {
  const { rest, calls } = await fixture();
  const response = await handleScoresRequest(request({ body: { metric: 'resting_hr', user: OTHER, p_user: OTHER,
    deviceId: 'whoop-NOTMINE00' } }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  assertEquals(await response.json(), READY);
  assertEquals(calls, [{ name: 'metric_insight_request_v1', args: { p_user: USER, p_metric: 'resting_hr' } }]);

  const other = await handleScoresRequest(request({ bearer: 'noop_auth_b', body: { metric: 'hrv_rmssd' } }), { rest, cfg });
  assertEquals(other.status, 200);
  assertEquals(calls[1], { name: 'metric_insight_request_v1', args: { p_user: OTHER, p_metric: 'hrv_rmssd' } });
  assertEquals([...INSIGHT_METRICS].sort(), ['calories', 'heart_rate', 'hrv_rmssd', 'hrv_sdnn', 'resp_rate',
    'resting_hr', 'skin_temp', 'spo2', 'steps']);
});

Deno.test('POST /insights: only the allow-listed metrics, a bounded JSON body, and POST only', async () => {
  const { rest, calls } = await fixture();
  for (const body of [{}, { metric: 'recovery_score' }, { metric: 'RESTING_HR' }, { metric: ['resting_hr'] }, { metric: 7 }, null]) {
    const response = await handleScoresRequest(request({ body }), { rest, cfg });
    assertEquals([JSON.stringify(body), response.status, await response.json()],
      [JSON.stringify(body), 400, { error: 'invalid_metric' }]);
  }
  const malformed = await handleScoresRequest(request({ raw: '{"metric":' }), { rest, cfg });
  assertEquals(malformed.status, 400);
  const oversized = await handleScoresRequest(request({ raw: JSON.stringify({ metric: 'resting_hr', pad: 'x'.repeat(9000) }) }),
    { rest, cfg });
  assertEquals(oversized.status, 413);
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const response = await handleScoresRequest(request({ method }), { rest, cfg });
    assertEquals([method, response.status], [method, 405]);
  }
  assertEquals(calls, []);
});

Deno.test('POST /insights: credentials are required and must be live installation or account credentials', async () => {
  const { rest, calls } = await fixture();
  for (const bearer of [null, 'noop_unknown', 'noop_fleet']) {
    const response = await handleScoresRequest(request({ bearer }), { rest, cfg });
    assertEquals([bearer, response.status], [bearer, 401]);
  }
  rest.tables.get('noop_ingest_tokens').find((row: any) => row.id === 'auth-a').revoked_at = '2026-10-05T00:00:00Z';
  assertEquals((await handleScoresRequest(request(), { rest, cfg })).status, 401);
  assertEquals(calls, []);

  await rest.upsert('compute_account_sources', { user_id: USER, source_id: SOURCE, revoked_at: null });
  const fetchImpl = async () => Response.json({ id: USER });
  const account = (headers: Record<string, string>) => request({ bearer: 'header.payload.signature', headers });
  assertEquals((await handleScoresRequest(account({ 'x-noop-source-id': SOURCE }), { rest, cfg, fetchImpl })).status, 200);
  assertEquals((await handleScoresRequest(account({}), { rest, cfg, fetchImpl })).status, 401);
  assertEquals((await handleScoresRequest(account({ 'x-noop-source-id': OTHER_SOURCE }), { rest, cfg, fetchImpl })).status, 403);
  assertEquals(calls, [{ name: 'metric_insight_request_v1', args: { p_user: USER, p_metric: 'resting_hr' } }]);
});

Deno.test('POST /insights: database failures map to bounded errors, never a partial explanation', async () => {
  const rejected = await fixture(() => { throw Object.assign(new Error('invalid_metric'), { status: 400 }); });
  let response = await handleScoresRequest(request(), { rest: rejected.rest, cfg });
  assertEquals([response.status, await response.json()], [400, { error: 'request_rejected' }]);

  const broken = await fixture(() => { throw new Error('connection reset'); });
  response = await handleScoresRequest(request(), { rest: broken.rest, cfg });
  assertEquals([response.status, await response.json()], [500, { error: 'scores_unavailable' }]);

  const unconfigured = await fixture();
  unconfigured.rest.configured = false;
  response = await handleScoresRequest(request(), { rest: unconfigured.rest, cfg });
  assertEquals([response.status, await response.json()], [503, { error: 'service_role_unconfigured' }]);
});
