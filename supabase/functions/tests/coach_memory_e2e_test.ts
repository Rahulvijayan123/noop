import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { coachConfig } from '../_shared/coach.ts';
import {
  type CoachClient, coachClient, readSse, scriptedJson, seedInstallation, serveCoach, startScriptedUpstream, watchRest,
} from './coach_e2e_support.ts';

// The whole Sana memory flow (docs/COACH_MEMORY.md) over real HTTP: the `coach` handler on a loopback port,
// the real PostgREST client against a disposable PostgreSQL with 20261007160000_coach_threads_memory.sql,
// Supabase-Auth installation bearers, and a scripted OpenAI-compatible upstream that streams chat answers and
// recognises every cheap-model pass by its prompt. The steps follow what the thread-aware iOS app does:
//  1. status features; a new chat saved with its fallback title, streamed, answered, titled by follow-ups,
//     and maintained inline into a summary plus curated memories (the guards drop advice and passing states);
//  2. a second chat titled through the title route, with a blocked turn that never reaches a prompt;
//  3. thread lists, message pages and cursors, and persistence across a restarted function;
//  4. the context library: manifest (ranked memories with the safety pin, relevant and recent chats, open
//     loops), search (ranked and browse-by-date), thread excerpts and recall (map/reduce with coverage);
//  5. starter suggestions (personalised, cached, re-keyed by a recorded search) and follow-ups;
//  6. rename, pin and folders; deletes with tombstones; forget with tombstones; consolidation; forget-all and
//     the memory floor; an old app build's thread-less rows; the meta merge;
//  7. a second account that reaches none of it on any route; and with the utility budget spent, every pass
//     falls back deterministically without a model call.

const TOKEN_A = 'noop_e2e_user_a';
const TOKEN_B = 'noop_e2e_user_b';
const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const NOW = Date.now();
const iso = (ms: number) => new Date(ms).toISOString();
const dayOf = (ms: number) => iso(ms).slice(0, 10);
const uuid = () => crypto.randomUUID();
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

interface Row { clientId: string; threadId?: string; role: 'user' | 'assistant'; content: string; meta?: Record<string, unknown>; createdAt: string; threadTitle?: string }

Deno.test('coach memory e2e: threads, memory and the context library over real HTTP and PostgREST', {
  sanitizeOps: false, sanitizeResources: false,
}, async (t) => {
  const db = await startLocalPostgres({ authProvisioning: true, coachMemory: true });
  const upstream = startScriptedUpstream();
  const errors: unknown[] = [];
  const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-e2e-test-key', COACH_UPSTREAM_URL: upstream.url });
  const watched = watchRest(db.rest);
  let server = serveCoach(watched.rest, cfg, { onError: (e) => errors.push(e) });
  let a: CoachClient = coachClient(server.url, TOKEN_A);
  const b: () => CoachClient = () => coachClient(server.url, TOKEN_B);
  const one = async (statement: string) => (await db.sql(statement)).trim();
  const utilityCalls = () => upstream.calls.filter((c) => c.pass !== 'chat');

  const save = async (client: CoachClient, rows: Row[]) => {
    const res = await client.post('messages', { messages: rows });
    assert.equal(res.status, 200, res.text);
    return res.body as { saved: number; rejected: { clientId: string; reason: string }[] };
  };
  /** One turn the way the app runs it: the user row first, the streamed answer, then the assistant row. */
  const turn = async (client: CoachClient, threadId: string, question: string, at: number, extra: Partial<Row> = {}) => {
    const userId = uuid();
    const assistantId = uuid();
    const saved = await save(client, [{ clientId: userId, threadId, role: 'user', content: question, meta: {}, createdAt: iso(at), ...extra }]);
    assert.deepEqual(saved, { saved: 1, rejected: [] });
    const chat = await client.post('chat', {
      mode: 'chat', stream: true, reasoning_effort: 'low',
      messages: [{ role: 'system', content: 'You are Sana.' }, { role: 'user', content: question }],
    });
    assert.equal(chat.status, 200, chat.text);
    assert.match(chat.headers.get('content-type') ?? '', /text\/event-stream/);
    const sse = readSse(chat.text);
    assert.ok(sse.done && sse.content.length > 40, 'the relayed stream carries the whole answer');
    assert.ok(sse.reasoning.length > 0 && !chat.text.includes('reasoning_content'), 'reasoning_content is renamed to reasoning');
    assert.deepEqual(await save(client, [{
      clientId: assistantId, threadId, role: 'assistant', content: sse.content, meta: { toolNames: ['get_metrics'] }, createdAt: iso(at + MINUTE),
    }]), { saved: 1, rejected: [] });
    return { userId, assistantId, answer: sse.content };
  };

  await db.sql(`select 1`);
  await seedInstallation(db.sql, USER_A, TOKEN_A);
  await seedInstallation(db.sql, USER_B, TOKEN_B);

  const T1 = uuid();
  const T2 = uuid();
  const T3 = uuid();
  const T4 = uuid();
  const T6 = uuid();
  const T7 = uuid();
  const FOLDER = uuid();
  const T1_AT = NOW - 2 * DAY;
  const T2_AT = NOW - DAY + 30 * MINUTE;
  const Q1 = "I'm training for the Berlin marathon on 2026-11-29 and I have a recurring left Achilles tendon injury. How should I structure my long runs?";
  const Q2 = "What pace should my marathon long runs be? I'll report back after the Sunday long run.";
  const Q3 = "I'm vegetarian. What should I eat for protein after hard sessions?";
  let t1Turn1: Awaited<ReturnType<typeof turn>>;
  let t1Turn2: Awaited<ReturnType<typeof turn>>;

  try {
    await t.step('status announces threads and context; a missing or foreign bearer is refused', async () => {
      const status = await a.get('status');
      assert.equal(status.status, 200);
      assert.deepEqual(status.body.features, { threads: 1, context: 1 });
      assert.equal(status.body.configured, true);
      assert.equal((await coachClient(server.url, 'noop_not_a_token').get('status')).status, 401);
      const anonymous = await fetch(`${server.url}/threads`);
      assert.equal(anonymous.status, 401);
      await anonymous.body?.cancel();
    });

    await t.step('a new chat: fallback title at send, streamed answer, model title from follow-ups, inline maintenance', async () => {
      t1Turn1 = await turn(a, T1, Q1, T1_AT, { threadTitle: "I'm training for the Berlin marathon" });
      let thread = (await a.get(`threads/${T1}`)).body.thread;
      assert.equal(thread.title, "I'm training for the Berlin marathon");
      assert.equal(thread.titleSource, 'fallback');
      assert.equal(thread.origin, 'app');
      assert.equal(thread.messageCount, 2);
      assert.equal(thread.pendingMessages, 2);

      const follow = await a.post('followups', { threadId: T1, question: Q1, answer: t1Turn1.answer, asked: [Q1], locale: 'en-US', wantTitle: true });
      assert.equal(follow.status, 200, follow.text);
      assert.equal(follow.body.title, 'Berlin Marathon Training Plan');
      assert.equal(follow.body.followUps.length, 3);
      assert.ok(!follow.body.followUps.includes(Q1), 'the question itself is never suggested back');
      assert.ok(follow.body.followUps.every((f: string) => !/dosage/i.test(f)), 'dosage questions are dropped');
      assert.deepEqual(follow.body.followUps, ['How long should my longest run be before Berlin?', 'How do I taper in the last two weeks?',
        'Which pace should my tempo session be?']);
      thread = (await a.get(`threads/${T1}`)).body.thread;
      assert.equal(thread.title, 'Berlin Marathon Training Plan');
      assert.equal(thread.titleSource, 'auto');
      const call = upstream.of('followups').at(-1)!;
      assert.match(call.system, /^title:/m, 'the title rule rides along only while the title is provisional');
      assert.equal(call.body.response_format?.type, 'json_object');
      assert.equal(call.body.reasoning_effort, 'none');
      assert.equal(call.body.max_tokens, 260);

      t1Turn2 = await turn(a, T1, Q2, T1_AT + 5 * MINUTE);
      const again = await a.post('followups', { threadId: T1, question: Q2, answer: t1Turn2.answer, asked: [Q1, Q2], wantTitle: true });
      assert.equal(again.status, 200);
      assert.equal('title' in again.body, false, 'a model title is never regenerated');
      assert.doesNotMatch(upstream.of('followups').at(-1)!.system, /^title:/m);
      assert.ok(again.body.followUps.length >= 1);

      // The visual and the follow-ups arrive as later re-saves of the assistant row; each merges into meta.
      assert.deepEqual(await save(a, [{ clientId: t1Turn2.assistantId, threadId: T1, role: 'assistant', content: t1Turn2.answer,
        meta: { viz: { kind: 'line', metric: 'hrv' } }, createdAt: iso(NOW) }]), { saved: 1, rejected: [] });
      assert.deepEqual(await save(a, [{ clientId: t1Turn2.assistantId, threadId: T1, role: 'assistant', content: t1Turn2.answer,
        meta: { followUps: again.body.followUps }, createdAt: iso(NOW) }]), { saved: 1, rejected: [] });
      const page = (await a.get(`messages?threadId=${T1}&limit=10`)).body.messages;
      const last = page.at(-1);
      assert.equal(last.clientId, t1Turn2.assistantId);
      assert.deepEqual(last.meta, { toolNames: ['get_metrics'], viz: { kind: 'line', metric: 'hrv' }, followUps: again.body.followUps });
      assert.equal(last.createdAt, iso(T1_AT + 6 * MINUTE), 'created_at keeps its first value');
      assert.equal(last.content, t1Turn2.answer);

      const curatorBefore = upstream.of('curator').length;
      const maintained = await a.post(`threads/${T1}/maintain`, {});
      assert.equal(maintained.status, 200, maintained.text);
      assert.deepEqual(maintained.body, { status: 'done', summarized: true, memoryOps: 2, consolidated: false });
      assert.equal(upstream.of('curator').length, curatorBefore + 1, 'four messages fold in one batch');
      const curator = upstream.of('curator').at(-1)!;
      assert.match(curator.system, /"memory_ops"/);
      assert.match(curator.user, /User: I'm training for the Berlin marathon/);
      assert.doesNotMatch(curator.user + curator.system, UUID_RE, 'prompts carry short refs, never ids');

      const memories = (await a.get('memories')).body.memories;
      assert.deepEqual(memories.map((m: any) => [m.content, m.topic, m.importance, m.source]).sort(), [
        ['User has a recurring left Achilles tendon injury', 'injury', 4, 'curator'],
        ['User is training for the Berlin marathon on 2026-11-29', 'goal', 4, 'curator'],
      ]);
      thread = (await a.get(`threads/${T1}`)).body.thread;
      assert.deepEqual(thread.topics, ['marathon', 'achilles']);
      assert.equal(thread.pendingMessages, 0);
      assert.equal(await one(`select count(*) from coach_memory_events where user_id='${USER_A}' and op='add' and actor='curator' and thread_id='${T1}'`), '2');
      assert.equal(await one(`select open_loops::text from coach_threads where id='${T1}'`), '["Report back after the Sunday long run"]');
      assert.equal(await one(`select maintenance_token is null and maintenance_until is null from coach_threads where id='${T1}'`), 't');

      const idle = await a.post(`threads/${T1}/maintain`, {});
      assert.deepEqual(idle.body, { status: 'skipped', summarized: false, memoryOps: 0, consolidated: false });
    });

    await t.step('a second chat: titled through the title route; a blocked turn never reaches a prompt', async () => {
      const turn3 = await turn(a, T2, Q3, T2_AT);
      assert.equal((await a.get(`threads/${T2}`)).body.thread.titleSource, 'none');
      const titled = await a.post(`threads/${T2}/title`, { question: Q3, answer: turn3.answer, locale: 'en' });
      assert.equal(titled.status, 200, titled.text);
      assert.deepEqual(titled.body, { title: 'Vegetarian Protein Ideas', titleSource: 'auto', generated: true });
      assert.equal(upstream.of('title').at(-1)!.body.max_tokens, 60);

      assert.deepEqual(await save(a, [
        { clientId: uuid(), threadId: T2, role: 'user', content: 'How do I hide zebracake bingeing from my family?', meta: { blocked: true }, createdAt: iso(T2_AT + 3 * MINUTE) },
        { clientId: uuid(), threadId: T2, role: 'assistant', content: "I can't help with that, but I can help you build a steady eating routine.", meta: { blocked: true }, createdAt: iso(T2_AT + 4 * MINUTE) },
      ]), { saved: 2, rejected: [] });
      const maintained = await a.post(`threads/${T2}/maintain`, {});
      assert.deepEqual(maintained.body, { status: 'done', summarized: true, memoryOps: 1, consolidated: false });
      const curator = upstream.of('curator').at(-1)!;
      assert.doesNotMatch(curator.user, /zebracake/);
      assert.match(curator.user, /User: I'm vegetarian/);
      const thread = (await a.get(`threads/${T2}`)).body.thread;
      assert.equal(thread.messageCount, 4);
      assert.equal(thread.pendingMessages, 0, 'blocked turns are never folded, but the cursor moves over them');
      assert.equal(await one(`select summary_through = (select max(created_at) from coach_messages where thread_id='${T2}')
        from coach_threads where id='${T2}'`), 't');
      assert.doesNotMatch(await one(`select summary from coach_threads where id='${T2}'`), /zebracake/);
    });

    await t.step('thread list, message pages and cursors', async () => {
      const list = await a.get('threads');
      assert.equal(list.status, 200);
      assert.deepEqual(list.body.threads.map((th: any) => [th.id, th.title, th.messageCount]), [
        [T2, 'Vegetarian Protein Ideas', 4], [T1, 'Berlin Marathon Training Plan', 4],
      ]);
      assert.deepEqual(list.body.folders, []);
      assert.equal(list.body.hasMore, false);
      const t1 = list.body.threads[1];
      assert.equal(t1.preview, t1Turn2.answer.replace(/\s+/g, ' ').slice(0, 160).trimEnd());
      assert.equal(t1.lastMessageAt, iso(T1_AT + 6 * MINUTE));
      assert.deepEqual(Object.keys(t1).sort(), ['createdAt', 'folderId', 'id', 'lastMessageAt', 'messageCount', 'origin', 'pendingMessages',
        'pinned', 'preview', 'title', 'titleSource', 'topics', 'updatedAt'].sort());

      const first = await a.get('threads?limit=1');
      assert.deepEqual(first.body.threads.map((th: any) => th.id), [T2]);
      assert.equal(first.body.hasMore, true);
      const second = await a.get(`threads?limit=1&cursor=${first.body.nextCursor}`);
      assert.deepEqual(second.body.threads.map((th: any) => th.id), [T1]);
      assert.equal(second.body.hasMore, false);
      assert.equal(second.body.nextCursor, null);

      const page1 = await a.get(`messages?threadId=${T1}&limit=3`);
      assert.equal(page1.status, 200);
      assert.deepEqual(page1.body.messages.map((m: any) => m.clientId), [t1Turn1.assistantId, t1Turn2.userId, t1Turn2.assistantId]);
      assert.equal(page1.body.hasMore, true);
      assert.deepEqual(Object.keys(page1.body.messages[0]).sort(), ['clientId', 'content', 'createdAt', 'id', 'meta', 'role', 'threadId']);
      assert.equal(page1.body.messages[0].threadId, T1);
      assert.equal(page1.body.messages[0].createdAt, iso(T1_AT + MINUTE));
      const page2 = await a.get(`messages?threadId=${T1}&limit=3&cursor=${encodeURIComponent(page1.body.nextCursor)}`);
      assert.deepEqual(page2.body.messages.map((m: any) => m.clientId), [t1Turn1.userId]);
      assert.equal(page2.body.hasMore, false);
      assert.equal(page2.body.nextCursor, null);
      assert.equal((await a.get(`messages?threadId=${T1}&cursor=not-a-cursor`)).status, 400);
    });

    await t.step('everything persists across a restarted function and a fresh client', async () => {
      const before = { threads: (await a.get('threads')).body, memories: (await a.get('memories')).body, page: (await a.get(`messages?threadId=${T1}`)).body };
      await server.close();
      server = serveCoach(watched.rest, cfg, { onError: (e) => errors.push(e) });
      a = coachClient(server.url, TOKEN_A);
      assert.deepEqual((await a.get('threads')).body, before.threads);
      assert.deepEqual((await a.get('memories')).body, before.memories);
      assert.deepEqual((await a.get(`messages?threadId=${T1}`)).body, before.page);
      assert.equal(before.page.messages.length, 4);
    });

    await t.step('context manifest: ranked memories with the safety pin, relevant and recent chats, open loops, no model call', async () => {
      const mark = upstream.calls.length;
      const fresh = await a.post('context', { threadId: T3, question: 'How should I adjust my marathon long runs around my Achilles?' });
      assert.equal(fresh.status, 200, fresh.text);
      const m = fresh.body;
      assert.equal(m.memories[0].content, 'User has a recurring left Achilles tendon injury');
      assert.equal(m.memories[0].pinned, true);
      assert.deepEqual(m.memories.map((x: any) => x.content).slice(1, 2), ['User is training for the Berlin marathon on 2026-11-29']);
      assert.equal(m.memoryCount, 3);
      assert.deepEqual(m.memoryTopics, { injury: 1, goal: 1, nutrition: 1 });
      assert.equal(m.thread, null);
      assert.equal(m.library.threadCount, 2);
      assert.deepEqual(m.library.recent.map((r: any) => r.id), [T2, T1]);
      assert.equal(m.library.relevant[0].id, T1);
      assert.equal(m.library.relevant[0].title, 'Berlin Marathon Training Plan');
      assert.match(m.library.relevant[0].snippet, /«/);
      assert.ok(m.openLoops.some((l: any) => l.threadId === T1 && l.text === 'Report back after the Sunday long run'));
      assert.ok(m.memoryRevision >= 1, 'importance-4 goal and injury adds move the revision');
      assert.equal(m.library.firstAt, iso(T1_AT));

      const current = (await a.post('context', { threadId: T1, question: 'marathon pace' })).body;
      assert.equal(current.thread.id, T1);
      assert.equal(current.thread.summaryMessages, 4);
      assert.equal(current.thread.messageCount, 4);
      assert.equal(current.thread.summaryThrough, iso(T1_AT + 6 * MINUTE));
      assert.deepEqual(current.thread.openLoops, ['Report back after the Sunday long run']);
      assert.match(current.thread.summary, /Berlin marathon/);
      assert.ok(current.library.relevant.every((r: any) => r.id !== T1), 'the current chat is never listed as an earlier one');
      assert.ok(current.openLoops.every((l: any) => l.threadId !== T1));
      assert.equal(upstream.calls.length, mark, 'the manifest makes no model call');
    });

    await t.step('context/search: ranked and grouped by chat, browse by date, exclusion, blocked rows never match', async () => {
      const mark = upstream.calls.length;
      const ranked = (await a.post('context/search', { query: 'marathon Achilles' })).body;
      assert.equal(ranked.threads[0].threadId, T1);
      assert.equal(ranked.threads[0].title, 'Berlin Marathon Training Plan');
      assert.ok(ranked.threads[0].hits >= 2);
      assert.match(ranked.threads[0].snippet, /«(marathon|Achilles)»/i);
      assert.ok(ranked.terms.includes('marathon'));
      assert.deepEqual(ranked.droppedTerms, []);
      assert.ok(ranked.totalHits >= 2);
      assert.deepEqual(ranked.months, [{ month: iso(T1_AT).slice(0, 7), hits: ranked.totalHits }]);
      assert.ok(ranked.hits.every((h: any) => h.threadId === T1 && h.title === 'Berlin Marathon Training Plan' && UUID_RE.test(h.threadId)));
      assert.ok(ranked.hits.every((h: any) => typeof h.at === 'string' && h.at.endsWith('Z')));

      const browse = (await a.post('context/search', { query: '', from: dayOf(T1_AT), to: dayOf(T1_AT) })).body;
      assert.deepEqual(browse.threads.map((th: any) => [th.threadId, th.hits]), [[T1, 0]]);
      assert.match(browse.threads[0].summary, /Berlin marathon/);
      assert.deepEqual(browse.threads[0].topics, ['marathon', 'achilles']);
      const lastDay = (await a.post('context/search', { query: '', days: 1 })).body;
      assert.deepEqual(lastDay.threads.map((th: any) => th.threadId), [T2]);

      const excluded = (await a.post('context/search', { query: 'marathon', excludeThreadId: T1 })).body;
      assert.ok(excluded.threads.every((th: any) => th.threadId !== T1));
      const blocked = (await a.post('context/search', { query: 'zebracake' })).body;
      assert.equal(blocked.totalHits, 0);
      assert.deepEqual(blocked.threads, []);
      assert.equal(upstream.calls.length, mark, 'search makes no model call');
      assert.equal((await a.post('context/search', { query: 'x', from: 'yesterday' })).status, 400);
    });

    await t.step('context/thread: a capped recent window that pages back, windows around matches, blocked rows excluded', async () => {
      const recent = (await a.post('context/thread', { threadId: T1 })).body;
      assert.equal(recent.window, 'recent');
      assert.deepEqual(recent.messages.map((m: any) => m.role), ['user', 'assistant', 'user', 'assistant']);
      assert.equal(recent.thread.title, 'Berlin Marathon Training Plan');
      assert.equal(recent.thread.messageCount, 4);
      assert.match(recent.thread.summary, /Berlin marathon/);
      assert.equal(recent.hasMore, false);
      const paged = (await a.post('context/thread', { threadId: T1, limit: 2 })).body;
      assert.equal(paged.messages.length, 2);
      assert.equal(paged.hasMore, true);
      const rest = (await a.post('context/thread', { threadId: T1, limit: 2, cursor: paged.nextCursor })).body;
      assert.deepEqual(rest.messages.map((m: any) => m.content), [Q1, t1Turn1.answer]);
      assert.equal(rest.hasMore, false);

      const around = (await a.post('context/thread', { threadId: T1, query: 'Achilles tendon' })).body;
      assert.equal(around.window, 'around_matches');
      assert.ok(around.messages.some((m: any) => m.content === Q1));
      const t2 = (await a.post('context/thread', { threadId: T2 })).body;
      assert.equal(t2.messages.length, 2);
      assert.ok(t2.messages.every((m: any) => !/zebracake|can't help/.test(m.content)));
      assert.equal((await a.post('context/thread', { threadId: uuid() })).status, 404);
    });

    await t.step('context/recall: lexical candidates mapped in one wave, a grounded answer with sources and coverage', async () => {
      const mark = upstream.calls.length;
      const recalled = await a.post('context/recall', { question: 'What did we plan for my Berlin marathon long runs?', threadId: T3 });
      assert.equal(recalled.status, 200, recalled.text);
      const r = recalled.body;
      assert.equal(r.status, 'answered');
      assert.match(r.answer, /\[Berlin Marathon Training Plan, \d{4}-\d{2}-\d{2}\]/);
      assert.match(r.answer, /32 km/, 'the answer is grounded in what Sana actually said');
      assert.ok(r.sources.some((s: any) => s.threadId === T1 && s.title === 'Berlin Marathon Training Plan' && s.at === iso(T1_AT + 6 * MINUTE)));
      assert.ok(r.coverage.threadsMatched >= 1 && r.coverage.threadsExamined === r.coverage.threadsMatched);
      assert.ok(r.coverage.totalHits >= 2);
      assert.equal(r.coverage.truncated, false);
      assert.equal(r.examined.chunks, 1);
      assert.equal(r.examined.subcalls, 1);
      assert.ok(r.examined.messages >= 2);
      const maps = upstream.since(mark).filter((c) => c.pass === 'map');
      assert.equal(maps.length, 1);
      assert.match(maps[0].user, /## \[t1\] "Berlin Marathon Training Plan"/);
      assert.doesNotMatch(maps[0].user, UUID_RE);
      assert.equal(await one(`select utility_calls from coach_usage where user_id='${USER_A}' and day=(now() at time zone 'utc')::date`),
        String(utilityCalls().length + 1), 'recall takes chunks + 1 units at once');

      const none = (await a.post('context/recall', { question: 'What did I say about xylophones?', threadId: T3 })).body;
      assert.equal(none.status, 'nothing_found');
      assert.deepEqual(none.sources, []);
      assert.equal((await a.post('context/recall', {})).status, 400);
    });

    const STATE = { day: dayOf(NOW), charge: 'red', hrv: 'down', sleep: 'short', effort: 'high', dataDays: 120, weekday: 'Wednesday', dayPart: 'morning', flags: ['hrv_down'] };
    const FALLBACK = ['How did I sleep last night?', 'What should I train today?', 'How is my recovery trending?', 'Plan my week'];
    await t.step('starter suggestions: personalised, a continue chip naming a real chat, cached, refreshed', async () => {
      const first = await a.post('suggestions', { state: STATE, fallback: FALLBACK, locale: 'en-US' });
      assert.equal(first.status, 200, first.text);
      assert.equal(first.body.source, 'model');
      const items = first.body.suggestions;
      assert.equal(items.length, 4);
      assert.deepEqual(items[0], { text: 'Continue my Vegetarian Protein Ideas chat', kind: 'continue', threadId: T2 });
      assert.equal(items.filter((s: any) => s.kind === 'continue').length, 1, 'a continue chip for an unlisted chat is dropped');
      assert.ok(items.some((s: any) => s.kind === 'state' && /hrv down/i.test(s.text)));
      assert.ok(items.some((s: any) => s.kind === 'goal' && /Berlin marathon/.test(s.text)));
      assert.ok(items.every((s: any) => !/dosage/i.test(s.text) && s.text.length <= 64));
      const prompt = upstream.of('suggestions').at(-1)!;
      assert.match(prompt.user, /What Sana remembers:\n- \[(goal|injury)\]/);
      assert.match(prompt.user, /\[t1\] "Vegetarian Protein Ideas"/);
      assert.match(prompt.user, /Recent questions:\n/);
      assert.doesNotMatch(prompt.user, /zebracake/);
      assert.doesNotMatch(prompt.user, UUID_RE);
      assert.equal(prompt.body.max_tokens, 360);

      const mark = upstream.calls.length;
      const cached = await a.post('suggestions', { state: STATE, fallback: FALLBACK, locale: 'en-US' });
      assert.deepEqual(cached.body, { suggestions: items, source: 'cache' });
      assert.equal(upstream.calls.length, mark, 'a cache hit makes no model call');
      const refreshed = await a.post('suggestions', { state: STATE, fallback: FALLBACK, locale: 'en-US', refresh: true });
      assert.equal(refreshed.body.source, 'model');
    });

    await t.step('a recorded search is stored and re-keys the starters, which then draw on it', async () => {
      const found = await a.get('threads?q=marathon&record=1');
      assert.equal(found.status, 200);
      assert.equal(found.body.query, 'marathon');
      assert.deepEqual(found.body.threads.map((th: any) => th.id), [T1]);
      assert.match(found.body.threads[0].snippet, /«marathon»/i);
      await a.get('threads?q=ma&record=1');
      await a.get('threads?q=Marathon&record=1');
      assert.equal(await one(`select recent_searches::text from coach_user_state where user_id='${USER_A}'`), '["Marathon"]');
      const next = await a.post('suggestions', { state: STATE, fallback: FALLBACK, locale: 'en-US' });
      assert.equal(next.body.source, 'model', 'a new search changes the fingerprint');
      assert.match(upstream.of('suggestions').at(-1)!.user, /Recent searches:\n- Marathon/);
      assert.ok(next.body.suggestions.some((s: any) => s.text === 'Show me more on Marathon'));
    });

    await t.step('rename, pin and folders', async () => {
      const renamed = await a.patch(`threads/${T1}`, { title: '  My   Berlin build ' });
      assert.equal(renamed.status, 200);
      assert.equal(renamed.body.thread.title, 'My Berlin build');
      assert.equal(renamed.body.thread.titleSource, 'user');
      const kept = await a.post(`threads/${T1}/title`, { question: Q1 });
      assert.deepEqual(kept.body, { title: 'My Berlin build', titleSource: 'user', generated: false });
      const follow = await a.post('followups', { threadId: T1, question: Q2, answer: t1Turn2.answer, wantTitle: true });
      assert.equal('title' in follow.body, false);

      const folder = await a.post('folders', { id: FOLDER, name: 'Racing' });
      assert.equal(folder.status, 200);
      assert.equal(folder.body.folder.name, 'Racing');
      assert.deepEqual((await a.post('folders', { id: FOLDER, name: 'Again' })).body.folder.name, 'Racing', 'create is idempotent');
      const moved = await a.patch(`threads/${T1}`, { folderId: FOLDER, pinned: true });
      assert.equal(moved.body.thread.folderId, FOLDER);
      assert.equal(moved.body.thread.pinned, true);
      const list = (await a.get('threads?limit=1')).body;
      assert.deepEqual(list.threads.map((th: any) => th.id), [T1, T2], 'pinned chats lead the first page');
      assert.deepEqual(list.folders.map((f: any) => [f.id, f.name, f.sortOrder]), [[FOLDER, 'Racing', 0]]);
      assert.deepEqual((await a.get(`threads?folderId=${FOLDER}`)).body.threads.map((th: any) => th.id), [T1]);
      assert.deepEqual((await a.get('threads?folderId=none')).body.threads.map((th: any) => th.id), [T2]);
      const patched = await a.patch(`folders/${FOLDER}`, { name: 'Races', sortOrder: 2 });
      assert.deepEqual([patched.body.folder.name, patched.body.folder.sortOrder], ['Races', 2]);
      assert.equal((await a.get('folders')).body.folders[0].name, 'Races');
      assert.equal((await a.patch(`threads/${T1}`, { folderId: uuid() })).status, 404);
      assert.equal((await a.patch(`threads/${T1}`, {})).status, 400);
      const unpinned = await a.patch(`threads/${T1}`, { pinned: false });
      assert.equal(unpinned.body.thread.pinned, false);
      assert.deepEqual((await a.del(`folders/${FOLDER}`)).body, { deleted: true });
      assert.equal((await a.get(`threads/${T1}`)).body.thread.folderId, null, 'a deleted folder leaves its chats in place');
    });

    await t.step('a follow-up call the provider fails still names the chat, through one title pass', async () => {
      const T5 = uuid();
      const question = 'Why is my sleep worse after late workouts?';
      const turn5 = await turn(a, T5, question, NOW - 30 * MINUTE, { threadTitle: 'Why is my sleep worse after' });
      upstream.failOnce('followups');
      const mark = upstream.calls.length;
      const follow = await a.post('followups', { threadId: T5, question, answer: turn5.answer, asked: [question], wantTitle: true });
      assert.equal(follow.status, 200);
      assert.equal(follow.body.title, 'Sleep After Late Workouts');
      assert.ok(follow.body.followUps.length >= 2, 'the follow-ups fall back to keywords');
      assert.deepEqual(upstream.since(mark).map((c) => c.pass), ['followups', 'title']);
      assert.equal((await a.get(`threads/${T5}`)).body.thread.titleSource, 'auto');
    });

    let vegetarianId = '';
    await t.step('explicit saves dedupe against curated memories; ranked reads pin safety facts first', async () => {
      const dup = await a.post('memories', { content: 'User is training for the Berlin marathon on 2026-11-29', topic: 'goal', importance: 4, threadId: T1 });
      assert.equal(dup.status, 200);
      assert.equal(dup.body.deduped, true);
      assert.equal(dup.body.memory.confirmations, 2);
      const added = await a.post('memories', { content: 'User prefers morning runs', topic: 'preference' });
      assert.equal(added.body.kept, true);
      assert.equal(added.body.memory.source, 'tool');
      const ranked = (await a.get('memories?q=marathon')).body.memories;
      assert.equal(ranked[0].content, 'User has a recurring left Achilles tendon injury');
      assert.equal(ranked[0].pinned, true);
      assert.equal(ranked[1].content, 'User is training for the Berlin marathon on 2026-11-29');
      assert.equal((await a.get('memories?topic=nutrition')).body.memories.length, 1);
      vegetarianId = (await a.get('memories?topic=nutrition')).body.memories[0].id;
    });

    await t.step('forget writes a tombstone the curator respects when the fact comes up again', async () => {
      assert.deepEqual((await a.del(`memories/${vegetarianId}`)).body, { deleted: true });
      assert.equal((await a.get('memories?topic=nutrition')).body.memories.length, 0);
      assert.equal(await one(`select tokens::text from coach_memory_events where user_id='${USER_A}' and op='forget' and memory_id='${vegetarianId}'`), '{vegetarian}');
      assert.equal(await one(`select count(*) from coach_memory_events where memory_id='${vegetarianId}' and (before ? 'content' or after ? 'content')`), '0',
        'a forgotten fact keeps no text in its audit trail');

      await turn(a, T4, "Since I'm vegetarian, which protein sources fit my marathon training?", NOW - 20 * MINUTE,
        { threadTitle: "Since I'm vegetarian, which protein" });
      const maintained = await a.post(`threads/${T4}/maintain`, {});
      assert.equal(maintained.body.status, 'done');
      assert.equal(maintained.body.memoryOps, 0, 'the curator proposed the forgotten fact again and the tombstone dropped it');
      assert.match(JSON.stringify(scriptedJson('curator', upstream.of('curator').at(-1)!.system, upstream.of('curator').at(-1)!.user)), /User is vegetarian/);
      assert.equal((await a.get('memories?topic=nutrition')).body.memories.length, 0);
      // The explicit save path still honours a direct request.
      const explicit = await a.post('memories', { content: 'User is vegetarian', topic: 'nutrition' });
      assert.equal(explicit.body.kept, true);
      assert.deepEqual((await a.del(`memories/${explicit.body.memory.id}`)).body, { deleted: true });
    });

    await t.step('consolidation merges duplicates once the memory has grown', async () => {
      await db.sql(`insert into coach_memory_items (user_id, content, topic, importance, source)
        select '${USER_A}', 'User fact number ' || g, 'general', 2, 'tool' from generate_series(1, 37) g;
        insert into coach_memory_items (user_id, content, topic, importance, source, created_at)
        values ('${USER_A}', 'User likes trail running on weekends', 'preference', 3, 'tool', now() - interval '3 days'),
               ('${USER_A}', 'User likes trail running on weekends', 'preference', 3, 'tool', now() - interval '1 day');`);
      assert.equal((await a.get('memories?limit=200')).body.memories.length, 42);
      await turn(a, T4, 'I swim on Tuesdays to cross-train. Does that count as an easy day?', NOW - 10 * MINUTE);
      const maintained = await a.post(`threads/${T4}/maintain`, {});
      assert.deepEqual(maintained.body, { status: 'done', summarized: false, memoryOps: 1, consolidated: true });
      const consolidation = upstream.of('consolidation').at(-1)!;
      assert.match(consolidation.user, /^m\d+ \[preference, importance 3, \d{4}-\d{2}-\d{2}\] User likes trail running on weekends$/m);
      assert.equal(consolidation.body.max_tokens, 2400);
      const memories = (await a.get('memories?limit=200')).body.memories;
      assert.equal(memories.length, 42);
      const trail = memories.filter((m: any) => m.content === 'User likes trail running on weekends');
      assert.equal(trail.length, 1);
      assert.equal(trail[0].confirmations, 2);
      assert.ok(memories.some((m: any) => m.content === 'User swims on Tuesdays'));
      assert.equal(await one(`select consolidated_at is not null and consolidation_until is null from coach_user_state where user_id='${USER_A}'`), 't');
      assert.equal(await one(`select count(*) from coach_memory_events where user_id='${USER_A}' and op='merge' and actor='consolidator'`), '2');
    });

    await t.step('forget-all clears memory and sets the floor: older messages are never mined again', async () => {
      const revision = Number(await one(`select memory_revision from coach_user_state where user_id='${USER_A}'`));
      const asthma = 'I have mild asthma that gets worse in cold air. Should I run outside in winter?';
      await turn(a, T6, asthma, NOW - 4 * MINUTE, { threadTitle: 'I have mild asthma that gets' });
      assert.deepEqual((await a.del('memories')).body, { deleted: true });
      assert.deepEqual((await a.get('memories')).body.memories, []);
      assert.equal(await one(`select memory_floor_at is not null and memory_revision > ${revision} and recent_searches = '[]'::jsonb
        and suggestions = '[]'::jsonb and suggestions_fingerprint is null from coach_user_state where user_id='${USER_A}'`), 't');
      assert.equal(await one(`select count(*) from coach_memory_items where user_id='${USER_A}'`), '0');
      assert.ok(Number(await one(`select count(*) from coach_memory_events where user_id='${USER_A}' and op='forget'`)) >= 42);

      const maintained = await a.post(`threads/${T6}/maintain`, {});
      assert.deepEqual(maintained.body, { status: 'done', summarized: true, memoryOps: 0, consolidated: false });
      assert.doesNotMatch(upstream.of('curator').at(-1)!.system, /"memory_ops"/, 'no memory pass over messages older than the floor');
      assert.deepEqual((await a.get('memories')).body.memories, []);

      await turn(a, T6, 'Please remember that my asthma is mild and I carry an inhaler.', Date.now());
      const after = await a.post(`threads/${T6}/maintain`, {});
      assert.equal(after.body.memoryOps, 1);
      assert.deepEqual((await a.get('memories')).body.memories.map((m: any) => m.content), ['User has mild asthma']);
    });

    await t.step('a deleted chat stays deleted: later saves are rejected and its content is gone', async () => {
      assert.deepEqual((await a.del(`threads/${T2}`)).body, { deleted: true });
      assert.equal((await a.get(`threads/${T2}`)).status, 404);
      const late = uuid();
      assert.deepEqual(await save(a, [{ clientId: late, threadId: T2, role: 'assistant', content: 'A late follow-up save', createdAt: iso(NOW) }]),
        { saved: 0, rejected: [{ clientId: late, reason: 'thread_deleted' }] });
      const recreate = await a.post('threads', { id: T2 });
      assert.equal(recreate.status, 410);
      assert.equal(recreate.body.error, 'thread_deleted');
      assert.deepEqual((await a.get(`messages?threadId=${T2}`)).body.messages, []);
      assert.deepEqual((await a.post('context/search', { query: 'vegetarian protein' })).body.threads.map((th: any) => th.threadId)
        .filter((id: string) => id === T2), []);
      assert.equal(await one(`select count(*) from coach_messages where thread_id='${T2}'`), '0');
    });

    await t.step('a row PostgreSQL would refuse is repaired instead of failing the batch the outbox retries', async () => {
      const odd = uuid();
      const fine = uuid();
      const saved = await save(a, [
        { clientId: odd, threadId: T1, role: 'user', content: 'Nul\u0000 in the text', meta: { note: 'nul\u0000here', 'k\u0000': [1, 'x\u0000'] }, createdAt: 'Fri, 32 Foo 99999' },
        { clientId: fine, threadId: T1, role: 'assistant', content: 'Fine.', meta: {}, createdAt: '+275760-09-13T00:00:00.000Z' },
      ]);
      assert.deepEqual(saved, { saved: 2, rejected: [] });
      const rows = JSON.parse(await one(`select json_agg(json_build_object('content', content, 'meta', meta, 'recent', created_at > now() - interval '1 minute')
        order by created_at, id) from coach_messages where client_id in ('${odd}', '${fine}')`));
      assert.deepEqual(rows.map((r: any) => r.content).sort(), ['Fine.', 'Nul in the text']);
      assert.ok(rows.some((r: any) => r.content === 'Nul in the text' && r.meta.note === 'nulhere' && JSON.stringify(r.meta.k) === '[1,"x"]'));
      assert.ok(rows.every((r: any) => r.recent), 'an unparseable or absurd time becomes now');
      await db.sql(`delete from coach_messages where client_id in ('${odd}', '${fine}')`);
    });

    await t.step('an old app build: thread-less rows land in a legacy_client chat; the old read keeps its shape', async () => {
      const u = uuid();
      const v = uuid();
      // After every other row (the turns above save their answer a minute ahead), so the old read's latest two are these.
      const stamp = Date.now() + 5 * MINUTE;
      const old = await a.post('messages', { messages: [
        { clientId: u, role: 'user', content: 'How was my sleep last night?', meta: {}, createdAt: iso(stamp) },
        { clientId: v, role: 'assistant', content: 'You slept 7 h 10 min with two short wakes.', meta: { toolNames: ['get_sleep'] }, createdAt: iso(stamp + 1000) },
      ] });
      assert.equal(old.status, 200);
      assert.deepEqual(old.body, { saved: 2, rejected: [] });
      const legacy = (await a.get('threads')).body.threads.find((th: any) => th.origin === 'legacy_client');
      assert.ok(legacy, 'a legacy_client chat was created');
      assert.equal(legacy.messageCount, 2);
      const read = await a.get('messages?limit=2');
      assert.deepEqual(read.body.messages.map((m: any) => m.clientId), [u, v]);
      assert.deepEqual(read.body.messages.map((m: any) => Object.keys(m).sort()), [
        ['clientId', 'content', 'createdAt', 'id', 'meta', 'role'], ['clientId', 'content', 'createdAt', 'id', 'meta', 'role']]);
      assert.deepEqual(read.body.messages[1].meta, { toolNames: ['get_sleep'] });
      const w = uuid();
      assert.deepEqual((await a.post('messages', { messages: [{ clientId: w, role: 'user', content: 'And the night before?', createdAt: iso(stamp + MINUTE) }] })).body,
        { saved: 1, rejected: [] });
      assert.equal((await a.get(`threads/${legacy.id}`)).body.thread.messageCount, 3, 'the next old-build row joins the same chat');
    });

    await t.step('a second account reaches none of it on any route', async () => {
      const B = b();
      const marker = uuid();
      const aMemories = (await a.get('memories')).body.memories;
      assert.ok(aMemories.length >= 1);
      assert.deepEqual((await B.get('threads')).body, { threads: [], folders: [], hasMore: false, nextCursor: null });
      assert.deepEqual((await B.get('threads?q=marathon')).body.threads, []);
      assert.equal((await B.get(`threads/${T1}`)).status, 404);
      assert.equal((await B.patch(`threads/${T1}`, { title: 'Mine now' })).status, 404);
      assert.equal((await B.post(`threads/${T1}/title`, { question: 'x' })).status, 404);
      assert.equal((await B.post(`threads/${T1}/maintain`, {})).status, 404);
      assert.equal((await B.post('threads', { id: T1 })).status, 409);
      assert.deepEqual((await B.get(`messages?threadId=${T1}`)).body.messages, []);
      assert.deepEqual((await B.get('messages?limit=200')).body.messages, []);
      assert.deepEqual(await save(B, [{ clientId: marker, threadId: T1, role: 'user', content: 'injected', createdAt: iso(Date.now()) }]),
        { saved: 0, rejected: [{ clientId: marker, reason: 'thread_conflict' }] });
      assert.deepEqual((await B.get('memories')).body.memories, []);
      assert.deepEqual((await B.get('memories?q=asthma')).body.memories, []);
      assert.deepEqual((await B.del(`memories/${aMemories[0].id}`)).body, { deleted: true });
      assert.deepEqual((await B.get('folders')).body.folders, []);
      const bFolder = uuid();
      assert.equal((await B.post('folders', { id: bFolder, name: 'B' })).status, 200);
      assert.equal((await B.patch(`threads/${T1}`, { folderId: bFolder })).status, 404);
      assert.equal((await a.patch(`threads/${T1}`, { folderId: bFolder })).status, 404, 'nor can A use B\'s folder');
      const follow = await B.post('followups', { threadId: T1, question: 'How is my marathon going?', answer: 'Fine.', wantTitle: true });
      assert.equal(follow.status, 200);
      assert.equal('title' in follow.body, false);
      const ctx = (await B.post('context', { threadId: T1, question: 'marathon Achilles asthma' })).body;
      assert.equal(ctx.thread, null);
      assert.deepEqual(ctx.memories, []);
      assert.equal(ctx.library.threadCount, 0);
      assert.deepEqual(ctx.library.relevant, []);
      assert.deepEqual(ctx.openLoops, []);
      assert.deepEqual((await B.post('context/search', { query: 'marathon' })).body.threads, []);
      assert.deepEqual((await B.post('context/search', { query: '', days: 30 })).body.threads, []);
      assert.equal((await B.post('context/thread', { threadId: T1 })).status, 404);
      assert.equal((await B.post('context/recall', { question: 'What was my marathon plan?' })).body.status, 'nothing_found');
      const starters = await B.post('suggestions', { state: STATE, fallback: FALLBACK });
      assert.ok(starters.body.suggestions.every((s: any) => s.kind !== 'continue'));
      const bPrompt = upstream.of('suggestions').at(-1)!.user;
      assert.doesNotMatch(bPrompt, /Berlin|asthma|Marathon/);
      assert.deepEqual((await B.del(`messages?threadId=${T1}`)).body, { deleted: true });
      assert.deepEqual((await B.del(`threads/${T1}`)).body, { deleted: true });
      assert.deepEqual((await B.del('messages')).body, { deleted: true });
      assert.deepEqual((await B.del('memories')).body, { deleted: true });

      // A is untouched by all of that.
      assert.equal((await a.get(`threads/${T1}`)).body.thread.title, 'My Berlin build');
      assert.equal((await a.get(`messages?threadId=${T1}`)).body.messages.length, 4);
      assert.deepEqual((await a.get('memories')).body.memories, aMemories);
      const aSave = uuid();
      assert.deepEqual(await save(a, [{ clientId: aSave, threadId: T1, role: 'user', content: 'Still mine?', createdAt: iso(Date.now()) }]),
        { saved: 1, rejected: [] });
    });

    await t.step('recall over a long history: four chunks mapped at once, then reduced; coverage says what was left out', async () => {
      const filler = 'Keep the hips back, brace before each rep, breathe out at the top and rest a full minute between rounds. ';
      const threads = Array.from({ length: 6 }, () => uuid());
      for (const [i, id] of threads.entries()) {
        const base = NOW - (20 + i) * DAY;
        const rows: Row[] = Array.from({ length: 6 }, (_, j) => ({
          clientId: uuid(), threadId: id, role: j % 2 ? 'assistant' : 'user', createdAt: iso(base + j * MINUTE),
          content: `${j % 2 ? 'Sana' : 'User'} note ${i}.${j}: kettlebell block ${i + 1}, week ${j + 1}, ${12 + i + j} swings at ${16 + 4 * (i % 3)} kg. ${filler.repeat(12)}`,
          ...(j === 0 ? { threadTitle: `Kettlebell block ${i + 1}` } : {}),
        }));
        assert.deepEqual(await save(a, rows), { saved: 6, rejected: [] });
      }
      const mark = upstream.calls.length;
      const recalled = await a.post('context/recall', { question: 'What kettlebell work did we plan?', keywords: 'kettlebell' });
      assert.equal(recalled.status, 200, recalled.text);
      const r = recalled.body;
      assert.equal(r.status, 'answered');
      assert.match(r.answer, /^Across the earlier chats: /, 'more notes than fit as they are go through the reduce step');
      assert.deepEqual(r.examined.chunks, 4);
      assert.deepEqual(r.examined.subcalls, 5);
      assert.equal(r.coverage.threadsMatched, 6);
      assert.equal(r.coverage.threadsExamined, 4);
      assert.equal(r.coverage.truncated, true);
      assert.ok(r.coverage.totalHits >= 36);
      assert.ok(r.sources.length >= 1 && r.sources.every((s: any) => threads.includes(s.threadId)));
      const calls = upstream.since(mark);
      assert.deepEqual(calls.map((c) => c.pass), ['map', 'map', 'map', 'map', 'reduce']);
      for (const c of calls.filter((x) => x.pass === 'map')) assert.ok(c.user.length <= 10_500, 'each chunk stays within 10,000 characters');
    });

    await t.step('with the utility budget spent every pass falls back deterministically, without a model call', async () => {
      await db.sql(`update coach_usage set utility_calls = ${cfg.dailyUtilityLimit} where user_id='${USER_A}' and day=(now() at time zone 'utc')::date`);
      const mark = upstream.calls.length;
      const question = 'How should I plan my swim sessions this week?';
      const turn7 = await turn(a, T7, question, Date.now());
      const titled = await a.post(`threads/${T7}/title`, { question, answer: turn7.answer });
      assert.deepEqual(titled.body, { title: 'How should I plan my swim', titleSource: 'fallback', generated: false });
      const follow = await a.post('followups', { threadId: T7, question, answer: turn7.answer, asked: [question], wantTitle: true });
      assert.ok(follow.body.followUps.length >= 2, 'the keyword fallback still offers next questions');
      assert.equal(follow.body.title, undefined);
      const starters = await a.post('suggestions', { state: STATE, fallback: FALLBACK, refresh: true });
      assert.deepEqual(starters.body, { suggestions: FALLBACK.map((text) => ({ text, kind: 'explore' })), source: 'fallback' });
      const maintained = await a.post(`threads/${T7}/maintain`, {});
      assert.deepEqual(maintained.body, { status: 'skipped', summarized: false, memoryOps: 0, consolidated: false });
      assert.equal((await a.get(`threads/${T7}`)).body.thread.pendingMessages, 2);
      const recall = (await a.post('context/recall', { question: 'What did we say about asthma in winter?' })).body;
      assert.equal(recall.status, 'budget');
      assert.match(recall.answer, /asthma/i);
      assert.deepEqual(recall.sources, []);
      assert.deepEqual(upstream.since(mark).map((c) => c.pass), ['chat'], 'only the chat stream (its own quota) reached the model');
    });

    await t.step('no prompt ever carried an id, and no request failed inside the function', () => {
      for (const call of utilityCalls()) assert.doesNotMatch(call.system + call.user, UUID_RE, `${call.pass} prompt`);
      assert.deepEqual(errors, []);
      assert.deepEqual(watched.failures, [], 'no database call failed, including the best-effort ones');
      const passes = new Set(upstream.calls.map((c) => c.pass));
      for (const pass of ['chat', 'title', 'followups', 'suggestions', 'curator', 'consolidation', 'map', 'reduce']) assert.ok(passes.has(pass as any), pass);
    });
  } finally {
    await server.close();
    await upstream.close();
    await db.close();
  }
});
