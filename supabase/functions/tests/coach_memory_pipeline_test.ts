import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { coachConfig } from '../_shared/coach.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
import {
  coachClient, readSse, scriptedJson, seedInstallation, serveCoach, startScriptedUpstream, watchRest,
} from './coach_e2e_support.ts';

// An edited Sana memory end to end on the production database image (supabase/tests/e2e/pipeline_db.sh: Supabase's
// Postgres 17 with its roles and default privileges, every migration applied in production order, PostgREST
// configured as hosted Supabase configures it), through the real `coach` handler on a loopback port and a scripted
// model (docs/COACH_MEMORY.md §3-§5). coach_memory_e2e_test.ts proves the whole memory flow on a disposable local
// PostgreSQL; this one proves the edit path on the image production runs:
//  1. save, then PATCH with the version: the store holds one row with the new text and source 'user'; the old text is
//     kept only as an edit tombstone's tokens; memory_revision moved;
//  2. every read returns that row: GET memories (each shape the app asks for), coach_memories_ranked_v1,
//     coach_context_manifest_v1 and POST context (what the app puts in the prompt); a stale version gets 409;
//  3. a curator pass over a chat that restates the old wording neither restores it nor rewords the user's row, and
//     coach_memory_apply_v1 refuses the curator's and the consolidator's rewording (`user_edited`);
//  4. forgotten, the text (old or new) never comes back through an automatic save; an explicit save still works;
//  5. a retired memory is no input to the metric insights fingerprint;
//  6. another account reaches none of it, and no PostgREST call failed.
// Skipped unless the pipeline variables are set. Run `pipeline_db.sh reset` before it.

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const JWT_SECRET = 'isolated-pipeline-jwt-secret-never-used-outside-tests';
const MINUTE = 60_000;
const uuid = () => crypto.randomUUID();
const iso = (ms: number) => new Date(ms).toISOString();

function signJwt(role: string) {
  const b64 = (v: string) => btoa(v).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const header = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64(JSON.stringify({ role, exp: Math.floor(Date.now() / 1000) + 3600 }));
  return `${header}.${body}.${createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url')}`;
}

async function sql(text: string): Promise<string> {
  const child = new Deno.Command('docker', {
    args: ['exec', '-i', container!, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
    stdin: 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(text));
  await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}

Deno.test({
  name: 'coach memory on the production image: an edit is stored, read everywhere, kept by the curator, and stays forgotten',
  ignore: !container || !restUrl,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    const rest = createSupabaseRest({
      cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: signJwt('service_role') },
      fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(15000) }),
    });
    const A = uuid();
    const B = uuid();
    const TOKEN_A = `noop_pipe_a_${A.slice(0, 8)}`;
    const TOKEN_B = `noop_pipe_b_${B.slice(0, 8)}`;
    await sql(`insert into auth.users(id, email) values ('${A}', 'coach-a-${A.slice(0, 8)}@example.test'), ('${B}', 'coach-b-${B.slice(0, 8)}@example.test')`);
    await seedInstallation(sql, A, TOKEN_A);
    await seedInstallation(sql, B, TOKEN_B);
    await sql(`notify pgrst, 'reload schema'`);

    const upstream = startScriptedUpstream();
    const errors: unknown[] = [];
    const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-pipeline-test-key', COACH_UPSTREAM_URL: upstream.url });
    const watched = watchRest(rest);
    const server = serveCoach(watched.rest, cfg, { onError: (e) => errors.push(e) });
    const a = coachClient(server.url, TOKEN_A);
    const b = coachClient(server.url, TOKEN_B);
    const one = sql;
    const swims = (rows: any[]) => rows.filter((m: any) => /\bswims\b/.test(m.content)).map((m: any) => [m.id, m.content, m.version]);
    const revisionNow = async () => Number(await one(`select coalesce((select memory_revision from public.coach_user_state where user_id='${A}'), 0)`));

    try {
      let id = '';
      let revision = 0;
      await t.step('save, then the user\'s PATCH: one row with the new text, the old wording only as tokens', async () => {
        for (let attempt = 0; ; attempt++) {
          const status = await a.get('status');
          if (status.status === 200) break;
          if (attempt === 40) assert.fail(`coach status ${status.status} ${status.text}`);
          await new Promise((resolve) => setTimeout(resolve, 250));
        }
        const saved = await a.post('memories', { content: 'User swims on Tuesdays', topic: 'routine', importance: 3 });
        assert.equal(saved.status, 200, saved.text);
        assert.deepEqual([saved.body.kept, saved.body.memory.version, saved.body.memory.source], [true, 1, 'tool']);
        id = saved.body.memory.id;
        revision = await revisionNow();
        const edited = await a.patch(`memories/${id}`, { content: 'User swims on Thursdays', version: 1 });
        assert.equal(edited.status, 200, edited.text);
        assert.deepEqual([edited.body.memory.id, edited.body.memory.content, edited.body.memory.version, edited.body.memory.source],
          [id, 'User swims on Thursdays', 2, 'user']);
        assert.equal(await one(`select count(*) from public.coach_memory_items where user_id='${A}' and content ~ '\\mswims\\M'`), '1');
        assert.equal(await one(`select content || '|' || source || '|' || version from public.coach_memory_items where id='${id}'`),
          'User swims on Thursdays|user|2');
        assert.equal(await one(`select count(*) from public.coach_memory_events where memory_id='${id}'
          and coalesce(before::text, '') || coalesce(after::text, '') like '%Tuesdays%'`), '0');
        assert.equal(await one(`select tokens::text || '|' || reason || '|' || actor from public.coach_memory_events
          where memory_id='${id}' and op='update'`), '{swim,tuesday}|user_edit|user');
        assert.equal(await revisionNow(), revision + 1);
      });

      await t.step('every read returns the edited row; a stale version gets 409', async () => {
        for (const path of ['memories', 'memories?limit=200', 'memories?q=swim', 'memories?topic=routine']) {
          assert.deepEqual(swims((await a.get(path)).body.memories), [[id, 'User swims on Thursdays', 2]], path);
        }
        const ranked = await rest.rpc('coach_memories_ranked_v1', { p_user: A, p_query: 'When do I swim?', p_limit: 8, p_pin_safety: true });
        assert.deepEqual(swims(ranked.memories), [[id, 'User swims on Thursdays', 2]]);
        const manifest = await rest.rpc('coach_context_manifest_v1', { p_user: A, p_thread: null, p_query: 'When do I swim?' });
        assert.deepEqual(swims(manifest.memories), [[id, 'User swims on Thursdays', 2]]);
        assert.equal(Number(manifest.memory_revision), revision + 1);
        const context = (await a.post('context', { question: 'When do I swim?' })).body;
        assert.deepEqual(swims(context.memories), [[id, 'User swims on Thursdays', 2]]);
        assert.equal(context.memoryRevision, revision + 1);
        const stale = await a.patch(`memories/${id}`, { content: 'User swims on Fridays', version: 1 });
        assert.deepEqual([stale.status, stale.body.error, stale.body.memory.content], [409, 'version_conflict', 'User swims on Thursdays']);
      });

      await t.step('the curator keeps the user\'s row and never relearns the old wording', async () => {
        const thread = uuid();
        const question = 'I swim on Tuesdays before work. Is that a good recovery day?';
        const at = Date.now();
        const rows = (role: string, content: string, ms: number, extra: Record<string, unknown> = {}) =>
          ({ clientId: uuid(), threadId: thread, role, content, meta: {}, createdAt: iso(ms), ...extra });
        assert.deepEqual((await a.post('messages', { messages: [rows('user', question, at, { threadTitle: 'I swim on Tuesdays' })] })).body,
          { saved: 1, rejected: [] });
        const chat = await a.post('chat', { mode: 'chat', stream: true, messages: [{ role: 'user', content: question }] });
        assert.equal(chat.status, 200, chat.text);
        assert.deepEqual((await a.post('messages', { messages: [rows('assistant', readSse(chat.text).content, at + MINUTE)] })).body,
          { saved: 1, rejected: [] });
        const maintained = await a.post(`threads/${thread}/maintain`, {});
        assert.equal(maintained.status, 200, maintained.text);
        assert.deepEqual([maintained.body.status, maintained.body.memoryOps], ['done', 0]);
        const curator = upstream.of('curator').at(-1)!;
        assert.match(curator.user, /^m\d+ \[routine, importance 3\] User swims on Thursdays$/m);
        assert.match(JSON.stringify(scriptedJson('curator', curator.system, curator.user)), /User swims on Tuesdays/, 'the model proposed the old wording');
        assert.deepEqual(swims((await a.get('memories?limit=200')).body.memories), [[id, 'User swims on Thursdays', 2]]);
        for (const actor of ['curator', 'consolidator']) {
          const result = await rest.rpc('coach_memory_apply_v1', {
            p_user: A, p_actor: actor, p_thread: null,
            p_ops: [{ op: 'update', id, content: 'User swims on Tuesdays' }, { op: 'retire', id, reason: 'contradicted' }, { op: 'confirm', id }],
          });
          assert.deepEqual(result.map((r: any) => [r.op, r.applied, r.reason ?? null]),
            [['update', false, 'user_edited'], ['retire', false, 'user_edited'], ['confirm', true, null]], actor);
        }
      });

      await t.step('forgotten, it never comes back through an automatic save; an explicit one still works', async () => {
        assert.deepEqual((await a.del(`memories/${id}`)).body, { deleted: true });
        for (const content of ['User swims on Thursdays', 'User swims on Tuesdays']) {
          const auto = await a.post('memories', { content, topic: 'routine', importance: 3, auto: true });
          assert.deepEqual([auto.status, auto.body], [200, { skipped: 'forgotten' }], content);
        }
        assert.deepEqual(swims((await a.get('memories?limit=200')).body.memories), []);
        assert.equal(await one(`select count(*) from public.coach_memory_items where user_id='${A}' and content ~ '\\mswims\\M'`), '0');
        const explicit = await a.post('memories', { content: 'User swims on Thursdays', topic: 'routine' });
        assert.equal(explicit.body.kept, true);
        assert.deepEqual((await a.del(`memories/${explicit.body.memory.id}`)).body, { deleted: true });
      });

      await t.step('a retired memory is no input to the metric insights fingerprint', async () => {
        const device = uuid();
        await sql(`insert into public.devices(id, user_id, source_kind, external_device_id) values ('${device}', '${A}', 'noop_push', 'whoop-PIPE${A.slice(0, 4)}');
          insert into public.server_daily_scores(user_id, day, algorithm_version, source_device_id, resting_hr_bpm)
            values ('${A}', current_date - 1, 'frwhoop-server-1', '${device}', 52);
          insert into public.coach_memory_items(user_id, content, topic, importance) values ('${A}', 'User trains for a marathon', 'goal', 3);`);
        const fingerprint = () => sql(`select fingerprint from internal.metric_insight_inputs('${A}', 'resting_hr')`);
        const active = await fingerprint();
        assert.match(active, /^[0-9a-f]{64}$/);
        await sql(`insert into public.coach_memory_items(user_id, content, topic, importance, retired_at, retired_reason)
          values ('${A}', 'User used to run ultras', 'achievement', 5, now(), 'merged')`);
        assert.equal(await fingerprint(), active);
        await sql(`update public.coach_memory_items set retired_at = now(), retired_reason = 'contradicted'
          where user_id = '${A}' and content = 'User trains for a marathon'`);
        assert.notEqual(await fingerprint(), active);
      });

      await t.step('another account reaches none of it; no request failed', async () => {
        const mine = (await a.post('memories', { content: 'User likes oat milk', topic: 'preference' })).body.memory;
        assert.equal((await b.patch(`memories/${mine.id}`, { content: 'Mine now', version: mine.version })).status, 404);
        assert.deepEqual((await b.get('memories')).body.memories, []);
        assert.equal(await one(`select content || '|' || source || '|' || version from public.coach_memory_items where id='${mine.id}'`),
          'User likes oat milk|tool|1');
        assert.deepEqual(errors, []);
        assert.deepEqual(watched.failures, [], 'no database call failed, including the best-effort ones');
      });
    } finally {
      await server.close();
      await upstream.close();
      await sql(`delete from auth.users where id in ('${A}', '${B}')`);
    }
  },
});
