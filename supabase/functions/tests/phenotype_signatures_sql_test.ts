// The real /scores routes of docs/PHENOTYPE_SIGNATURES.md on the production Postgres image, through PostgREST:
// observation periods and onset uncertainty through POST /manual-events, and the newest signature-report-1
// through GET /event-detection/signature (the json-path filter and ordering run in PostgREST). Then the runs
// table from a client's point of view.
//
// Docker-gated like manual_events_sql_test.ts: skipped unless PIPELINE_TEST_DATABASE_CONTAINER and
// PIPELINE_TEST_REST_URL are set (supabase/tests/e2e/pipeline_db.sh up, then reset between suites):
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   deno test -A --no-lock tests/phenotype_signatures_sql_test.ts
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';
const decoder = new TextDecoder();
const S = 1_791_000_000;

function b64url(value: string) {
  return btoa(value).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
}
function signJwt(role: string, sub?: string) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ role, sub, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 }));
  const signature = createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
  return `${header}.${body}.${signature}`;
}
async function sql(text: string) {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, decoder.decode(result.stderr));
  return decoder.decode(result.stdout).trim();
}
async function account() {
  const user = crypto.randomUUID(), source = crypto.randomUUID(), token = `noop_me_${crypto.randomUUID()}`;
  await sql(`insert into auth.users(id, email) values ('${user}', 'sig-${user}@example.test');
    insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
      values ('${source}', '${user}', 'ios', '1.0 (1)', 'supabase_auth');
    insert into public.noop_ingest_tokens(user_id, token_hash, token_kind, source_id, provisioning_method)
      values ('${user}', '${hashIngestToken(token)}', 'installation', '${source}', 'supabase_auth');`);
  return { user, source, token };
}
const revision = (entry: Record<string, unknown>, updatedAtMs: number) =>
  ({ revision_id: crypto.randomUUID().toUpperCase(), updated_at_ms: updatedAtMs, entry });

Deno.test({
  name: 'phenotype signatures on the production image: observations, onset uncertainty, signature reports',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const a = await account();
  const b = await account();
  const rest = createSupabaseRest({
    cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
    fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(15000) }),
  });
  const cfg = { supabaseUrl: 'https://project.test', supabaseAnonKey: 'sb_publishable_test' };
  const send = async (token: string, path: string, method = 'GET', body?: unknown) => {
    const response = await handleScoresRequest(new Request(`https://project.test/functions/v1/scores${path}`, {
      method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body) }), { rest, cfg });
    return { status: response.status, body: await response.json() };
  };

  const typeId = crypto.randomUUID();
  const type = { id: typeId.toUpperCase(), kind: 'event_type', label: 'Absence', symbol: 'brain.head.profile', favorite: true,
    timeZoneIdentifier: 'UTC', archived: false, activityKind: 'other' };
  const event = { id: crypto.randomUUID().toUpperCase(), kind: 'event', label: 'Absence', symbol: 'brain.head.profile',
    typeId: typeId.toUpperCase(), favorite: false, startUnixSeconds: S, endUnixSeconds: S + 30,
    timeZoneIdentifier: 'Europe/London', archived: false, activityKind: 'other', onsetUncertaintyMinutes: 15 };
  const observationId = crypto.randomUUID();
  const observation = { id: observationId.toUpperCase(), kind: 'observation', label: 'Observation', symbol: 'eye',
    favorite: false, startUnixSeconds: S - 3600, endUnixSeconds: S + 3600, timeZoneIdentifier: 'Europe/London',
    archived: false, note: 'Watched all afternoon' };
  let reply = await send(a.token, '/manual-events', 'POST', { revisions: [revision(type, S * 1000), revision(event, S * 1000 + 1),
    revision(observation, S * 1000 + 2), revision({ ...observation, id: crypto.randomUUID(), endUnixSeconds: S + 90_000 }, S * 1000 + 3),
    revision({ ...event, id: crypto.randomUUID(), onsetUncertaintyMinutes: 10 }, S * 1000 + 4)] });
  assert.equal(reply.status, 200, JSON.stringify(reply.body));
  assert.equal(reply.body.saved.length, 3);
  assert.deepEqual(reply.body.rejected.map((r: any) => r.reason).sort(), ['invalid_onset_uncertainty', 'invalid_time']);
  // Stored as sent; never projected, never given a context.
  reply = await send(a.token, '/manual-events?after=0');
  assert.deepEqual(reply.body.revisions.find((r: any) => r.entry.kind === 'observation').entry, observation);
  assert.equal(reply.body.revisions.find((r: any) => r.entry.kind === 'event').entry.onsetUncertaintyMinutes, 15);
  assert.equal(await sql(`select count(*) from public.manual_event_projections where entity_id = '${observationId}'`), '0');
  assert.deepEqual((await send(a.token, `/manual-events/context?ids=${observationId}`)).body.contexts, []);

  // Signature reports: the newest signature-report-1 of this owner and type.
  reply = await send(a.token, `/event-detection/signature?typeId=${typeId}`);
  assert.deepEqual([reply.status, reply.body.report], [200, null]);
  await sql(`insert into public.event_detector_settings(user_id, type_id, enabled) values
      ('${a.user}', '${typeId}', true), ('${b.user}', '${typeId}', true);
    insert into public.event_detector_runs(user_id, type_id, id, snapshot, report, created_at) values
      ('${a.user}', '${typeId}', gen_random_uuid(), 's', '{"version":"signature-report-1","status":"individual_context"}', now() - interval '2 hours'),
      ('${a.user}', '${typeId}', gen_random_uuid(), 's', '{"version":"signature-report-1","status":"emerging","extra":{"x":1}}', now() - interval '1 hour'),
      ('${a.user}', '${typeId}', gen_random_uuid(), 's', '{"version":"grid-0","status":"active"}', now()),
      ('${b.user}', '${typeId}', gen_random_uuid(), 's', '{"version":"signature-report-1","status":"established"}', now());`);
  reply = await send(a.token, `/event-detection/signature?typeId=${typeId.toUpperCase()}`);
  assert.equal(reply.status, 200, JSON.stringify(reply.body));
  assert.deepEqual(reply.body.report, { version: 'signature-report-1', status: 'emerging', extra: { x: 1 } });
  assert.deepEqual(reply.body.identity, { userId: a.user, sourceId: a.source });
  reply = await send(b.token, `/event-detection/signature?typeId=${typeId}`);
  assert.equal(reply.body.report.status, 'established');
  assert.equal((await send(a.token, '/event-detection/signature?typeId=nope')).status, 400);

  // Clients never read the runs table, their own rows included.
  for (const jwt of [signJwt('authenticated', a.user), signJwt('anon')]) {
    const response = await fetch(`${restUrl}/event_detector_runs?select=report`, { headers: { authorization: `Bearer ${jwt}` } });
    const body = await response.json();
    assert.ok([401, 403, 404].includes(response.status) || (Array.isArray(body) && body.length === 0),
      `runs answered ${response.status} ${JSON.stringify(body)}`);
  }
  await sql(`delete from auth.users where id in ('${a.user}', '${b.user}')`);
});
