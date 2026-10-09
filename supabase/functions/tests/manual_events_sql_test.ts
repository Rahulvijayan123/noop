// The real /scores/manual-events routes on the production Postgres image, through PostgREST, the way the
// deployed function runs: installation-token auth from real rows, the append RPC with per-item results,
// the ground-truth projection, the retained history, and the timestamp-aligned context built from real
// sensor rows and classifier output. Then RLS and privileges from a client's point of view.
//
// Docker-gated like physiology_context_sql_test.ts: skipped unless PIPELINE_TEST_DATABASE_CONTAINER and
// PIPELINE_TEST_REST_URL are set (supabase/tests/e2e/pipeline_db.sh up, then reset between suites):
//   set -a; source ~/.cache/nara-pipeline-db/pipeline.env; set +a
//   deno test -A --no-lock tests/manual_events_sql_test.ts
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
async function client(token: string, method: string, path: string, body?: unknown) {
  const response = await fetch(`${restUrl}/${path}`, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

/** One account with an installation, a registered strap and the token the app would send. */
async function account() {
  const user = crypto.randomUUID();
  const source = crypto.randomUUID();
  const device = crypto.randomUUID();
  const token = `noop_me_${crypto.randomUUID()}`;
  await sql(`insert into auth.users(id, email) values ('${user}', 'me-${user}@example.test');
    insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
      values ('${source}', '${user}', 'ios', '1.0 (1)', 'supabase_auth');
    insert into public.noop_ingest_tokens(user_id, token_hash, token_kind, source_id, provisioning_method)
      values ('${user}', '${hashIngestToken(token)}', 'installation', '${source}', 'supabase_auth');
    insert into public.devices(id, user_id, source_kind, external_device_id)
      values ('${device}', '${user}', 'noop_push', 'installation:${source}:my-whoop');`);
  return { user, source, device, token };
}

/** A revision exactly as the app's JSONEncoder writes it: uppercase UUIDs, camelCase entry keys. */
function revision(entry: Record<string, unknown>, updatedAtMs: number, id = crypto.randomUUID()) {
  return { revision_id: id.toUpperCase(), updated_at_ms: updatedAtMs, entry };
}

Deno.test({
  name: 'manual events on the production image: append, project, history, context, isolation',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const a = await account();
  const b = await account();
  // A 20-minute walk: 60 bpm before, 112 during, 84 after; the classifier saw walking for most of it.
  await sql(`insert into public.noop_hr_samples(user_id, device_id, source_id, ts, bpm, batch_id)
      select '${a.user}', '${a.device}', '${a.source}', t,
             case when t < ${S} then 60 when t < ${S + 1200} then 112 else 84 end, gen_random_uuid()
        from generate_series(${S - 1800}, ${S + 2999}) t;
    insert into public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version, ontology_version,
      decoder_version, feature_schema, model_version, preprocessing_version, job_fingerprint, input_revision,
      publish_interval_s, observed_s, run_count, event_count, unclear_s, mean_confidence, document, result_revision, computed_at)
    values ('${a.user}', '${a.device}', (to_timestamp(${S}) at time zone 'UTC')::date, 'streams-activity-1', 2, 'o1', 'd1',
      'f1', 'streams-test', 'p1', repeat('b', 64), 1, 60, 4800, 2, 0, 0, 0.8, jsonb_build_object('runs', jsonb_build_array(
        jsonb_build_object('s', ${S - 1800}, 'e', ${S + 60}, 'activity_class', 'sitting', 'class_confidence', 0.7),
        jsonb_build_object('s', ${S + 60}, 'e', ${S + 3000}, 'activity_class', 'brisk_walking', 'class_confidence', 0.85))),
      1, now());`);

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
  const eventId = crypto.randomUUID();
  const type = { id: typeId.toUpperCase(), kind: 'event_type', label: 'Lunch walk', symbol: 'figure.walk', favorite: true,
    timeZoneIdentifier: 'UTC', archived: false, activityKind: 'walking' };
  const walk = { id: eventId.toUpperCase(), kind: 'event', label: 'Lunch walk', symbol: 'figure.walk', typeId: typeId.toUpperCase(),
    favorite: false, startUnixSeconds: S, endUnixSeconds: S + 1200, timeZoneIdentifier: 'America/Los_Angeles',
    archived: false, deviceId: 'my-whoop', activityKind: 'walking', note: 'After lunch' };
  const walkRevision = revision(walk, S * 1000 + 1300_000);

  // POST: both saved, one invalid revision refused on its own.
  let reply = await send(a.token, '/manual-events', 'POST', { revisions: [
    revision(type, S * 1000), walkRevision, revision({ ...walk, id: crypto.randomUUID(), activityKind: 'flying' }, S * 1000 + 5)] });
  assert.equal(reply.status, 200, JSON.stringify(reply.body));
  assert.equal(reply.body.saved.length, 2);
  assert.deepEqual(reply.body.rejected.map((r: any) => r.reason), ['invalid_activity_kind']);
  assert.deepEqual(reply.body.identity, { userId: a.user, sourceId: a.source });

  // The same revision UUID with other content: refused per item, never stored over the original.
  reply = await send(a.token, '/manual-events', 'POST', { revisions: [{ ...walkRevision, entry: { ...walk, label: 'Changed' } }] });
  assert.deepEqual([reply.status, reply.body.saved, reply.body.rejected[0].reason], [200, [], 'revision_conflict']);
  // An identical retry is acknowledged again.
  reply = await send(a.token, '/manual-events', 'POST', { revisions: [walkRevision] });
  assert.deepEqual(reply.body.saved.map((id: string) => id.toLowerCase()), [walkRevision.revision_id.toLowerCase()]);

  // The walk became an activity ground-truth label on the strap it was logged with.
  assert.equal(await sql(`select source || ':' || locomotion || ':' || (device_id = '${a.device}') || ':' || start_ts || ':' || end_ts
      from public.activity_ground_truth_labels where owner = '${a.user}' and label_key = 'manual_event:${eventId}'`),
    `manual_event:walking:true:${S}:${S + 1200}`);

  // History comes back exactly as sent, for this account only.
  reply = await send(a.token, '/manual-events?after=0');
  assert.equal(reply.status, 200);
  assert.deepEqual(reply.body.revisions.map((r: any) => r.entry.label).sort(), ['Lunch walk', 'Lunch walk']);
  assert.deepEqual(reply.body.revisions.find((r: any) => r.entry.kind === 'event'), walkRevision);
  assert.deepEqual((await send(b.token, '/manual-events?after=0')).body.revisions, []);

  // Context: aligned to the event, from the real sensor rows and classifier output.
  reply = await send(a.token, `/manual-events/context?ids=${eventId.toUpperCase()}`);
  assert.equal(reply.status, 200, JSON.stringify(reply.body));
  const context = reply.body.contexts[0];
  assert.equal(context.version, 'manual-event-context-1');
  assert.equal(context.status, 'ready');
  assert.deepEqual(context.device, { id: a.device, resolution: 'entry' });
  assert.deepEqual([context.heart_rate.pre.mean, context.heart_rate.during.mean, context.heart_rate.post.mean], [60, 112, 84]);
  assert.equal(context.comparisons.hr_during_minus_pre_bpm, 52);
  assert.equal(context.activity.during.classes[0].class, 'brisk_walking');
  assert.equal(context.activity.during.source, 'streams-activity-1');
  assert.equal(context.activity.agreement.status, 'agrees');
  assert.equal(context.projections.activity_ground_truth.status, 'projected');
  assert.equal(context.event.local_day, '2026-10-02');
  // Another account asking for the same id gets nothing.
  assert.deepEqual((await send(b.token, `/manual-events/context?ids=${eventId}`)).body.contexts, []);

  // Archive: a new revision; the label projection goes, the history stays.
  reply = await send(a.token, '/manual-events', 'POST', { revisions: [
    revision({ ...walk, archived: true, archivedAt: S + 90_000 }, S * 1000 + 90_000_000)] });
  assert.equal(reply.body.saved.length, 1);
  assert.equal(await sql(`select count(*) from public.activity_ground_truth_labels where owner = '${a.user}'`), '0');
  assert.equal(await sql(`select count(*) from public.manual_event_revisions where user_id = '${a.user}' and entity_id = '${eventId}'`), '2');

  // Clients: own rows only through RLS, no writes, no builder RPCs.
  const jwtA = signJwt('authenticated', a.user);
  const jwtB = signJwt('authenticated', b.user);
  const own = await client(jwtA, 'GET', `manual_event_contexts?select=entity_id,status`);
  assert.deepEqual([own.status, own.body.map((r: any) => r.entity_id)], [200, [eventId]]);
  assert.deepEqual((await client(jwtB, 'GET', 'manual_event_contexts?select=entity_id')).body, []);
  assert.deepEqual((await client(jwtB, 'GET', 'manual_event_projections?select=entity_id')).body, []);
  for (const [method, path, body] of [
    ['POST', 'rpc/manual_event_contexts_v1', { p_user: a.user, p_ids: [eventId] }],
    ['POST', 'rpc/append_manual_event_revisions', { p_user: a.user, p_source: a.source, p_items: [] }],
    ['POST', 'rpc/project_manual_event_v1', { p_user: a.user, p_entity: eventId }],
    ['PATCH', `manual_event_contexts?entity_id=eq.${eventId}`, { final: false }],
    ['DELETE', `manual_event_revisions?user_id=eq.${a.user}`, undefined],
  ] as const) {
    const response = await client(jwtA, method, path, body);
    assert.ok([401, 403, 404].includes(response.status) || (Array.isArray(response.body) && response.body.length === 0),
      `${method} ${path} answered ${response.status}`);
  }
  assert.equal(await sql(`select count(*) from public.manual_event_revisions where user_id = '${a.user}'`), '3');

  // Deleting the account removes every manual-event row of it.
  await sql(`delete from auth.users where id = '${a.user}'`);
  assert.equal(await sql(`select (select count(*) from public.manual_event_revisions where user_id = '${a.user}')
      + (select count(*) from public.manual_event_contexts where user_id = '${a.user}')
      + (select count(*) from public.manual_event_projections where user_id = '${a.user}')`), '0');
});
