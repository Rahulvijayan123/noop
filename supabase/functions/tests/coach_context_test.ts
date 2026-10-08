// The context library (docs/COACH_MEMORY.md §4-§5): the manifest, search, thread excerpts and the RLM-style
// recall (partition, one concurrent map wave, optional reduce, hard deadline), over the in-memory fake.
import { assert, assertEquals } from 'jsr:@std/assert';
import { orQuery, recallShare } from '../_shared/coach_context.ts';
import { iso } from '../_shared/coach_llm.ts';
import { type Harness, harness, type ModelCall, OTHER, reply, USER, uuidsIn } from './coach_fake.ts';

type Turn = ['user' | 'assistant', string, Record<string, unknown>?];

/** A thread started at `start` (ISO), its messages one minute apart. */
function seed(h: Harness, turns: Turn[], over: Record<string, unknown> = {}, start = '2026-10-07T09:00:00Z', user = USER): any {
  const t = h.db.thread(user, { created_at: start, ...over });
  const t0 = Date.parse(start);
  turns.forEach(([role, content, extra], i) =>
    h.db.message(user, t.id, role, content, { created_at: new Date(t0 + i * 60_000).toISOString(), ...extra }));
  return h.db.threadRow(t.id);
}

const post = (h: Harness, path: string, body: unknown, token?: string) => h.json(`context${path}`, { method: 'POST', body, token });
const exhaust = (h: Harness, left = 0) => h.db.usage.set(USER, { calls: 0, utility_calls: h.cfg.dailyUtilityLimit - left, utility_tokens: 0 });
const sections = (c: ModelCall) => [...c.user.matchAll(/^## \[(t\d+)\] "([^"]*)"/gm)].map((m) => ({ ref: m[1], title: m[2] }));
const excerpts = (c: ModelCall) => c.user.split('Excerpts:\n')[1] ?? '';
/** A map reply with one dated note per chat in the chunk. */
const notesFor = (c: ModelCall) => ({ relevant: true, notes: sections(c).map((s) => `2026-08-18 [${s.ref}] User made a plan in ${s.title}`) });
const long = (word: string, n = 1_150) => `${word} ${'steady miles and recovery notes '.repeat(Math.ceil(n / 32))}`.slice(0, n);

// ------------------------------------------------------------------------------------------------
// POST context
// ------------------------------------------------------------------------------------------------

Deno.test('coach context: the manifest names what exists in camelCase, with no model call', async () => {
  const h = await harness();
  const current = seed(h, [['user', 'Plan my taper'], ['assistant', 'Sure.']],
    { title: 'Taper week', summary: 'The user is tapering.', summary_through: '2026-10-07T09:01:00Z', summary_messages: 2, open_loops: ['Check HRV on Friday'] });
  const knee = seed(h, [['user', 'My knee hurts after hill repeats'], ['assistant', 'Ease off hills.']],
    { title: 'Knee pain', summarized_at: '2026-10-06T10:00:00Z', open_loops: ['Report the knee after the long run', { text: 'Book a physio' }] }, '2026-10-06T09:00:00Z');
  const fuel = seed(h, [['user', 'What should I eat before a race?']], { title: 'Race fuel', summarized_at: '2026-09-01T10:00:00Z', open_loops: ['Old loop'] }, '2026-09-01T09:00:00Z');
  h.db.thread(USER, { title: 'Empty' });
  h.db.memory(USER, 'User is training for the Berlin marathon', { topic: 'goal', importance: 4 });
  h.db.memory(USER, 'User has asthma', { topic: 'health', importance: 5 });
  h.db.memory(OTHER, 'Theirs', { importance: 5 });
  seed(h, [['user', 'Their knee chat']], { title: 'Theirs' }, '2026-10-07T08:00:00Z', OTHER);

  const { status, body } = await post(h, '', { threadId: current.id, question: 'knee pain on hills' });
  assertEquals(status, 200);
  assertEquals(Object.keys(body).sort(), ['library', 'memories', 'memoryCount', 'memoryRevision', 'memoryTopics', 'openLoops', 'thread']);
  assertEquals(body.thread, {
    id: current.id, title: 'Taper week', summary: 'The user is tapering.', summaryThrough: '2026-10-07T09:01:00.000Z',
    summaryMessages: 2, messageCount: 2, openLoops: ['Check HRV on Friday'],
  });
  assertEquals(body.library.threadCount, 2, 'earlier chats: neither empty chats nor the current one count');
  assertEquals([body.library.firstAt, body.library.lastAt], [iso(fuel.created_at), '2026-10-07T09:01:00.000Z']);
  assertEquals(body.library.recent, [
    { id: knee.id, title: 'Knee pain', lastMessageAt: '2026-10-06T09:01:00.000Z' },
    { id: fuel.id, title: 'Race fuel', lastMessageAt: '2026-09-01T09:00:00.000Z' },
  ]);
  assertEquals(body.library.relevant.map((r: any) => [r.id, r.title]), [[knee.id, 'Knee pain']]);
  assert(body.library.relevant[0].snippet.includes('«knee»'));
  assertEquals(body.openLoops, [
    { threadId: knee.id, title: 'Knee pain', text: 'Report the knee after the long run' },
    { threadId: knee.id, title: 'Knee pain', text: 'Book a physio' },
  ], 'only chats summarised in the last 7 days, never the current one');
  assertEquals(body.memories.map((m: any) => [m.content, m.pinned]), [['User has asthma', true], ['User is training for the Berlin marathon', false]]);
  assertEquals([body.memoryCount, body.memoryTopics, body.memoryRevision], [2, { goal: 1, health: 1 }, 0]);
  assert(!JSON.stringify(body).includes('Their') && !JSON.stringify(body).includes('Theirs'));
  assertEquals(h.db.rpcCalls.find((c) => c.name === 'coach_context_manifest_v1')!.args, { p_user: USER, p_thread: current.id, p_query: 'knee pain on hills' });
  assertEquals(h.model.calls.length, 0);

  const bare = (await post(h, '', {})).body;
  assertEquals([bare.thread, bare.library.relevant, bare.library.recent.length], [null, [], 3]);
  assertEquals((await h.json('context', { method: 'POST', raw: '' })).status, 200, 'an empty body is {}');
  assertEquals((await post(h, '', { threadId: 'nope' })).status, 400);
  assertEquals((await h.json('context')).status, 405);
  assertEquals((await post(h, '/nope', {})).status, 404);
  const theirs = (await post(h, '', { threadId: current.id }, 'noop_other')).body;
  assertEquals([theirs.thread, theirs.library.threadCount, theirs.memories.map((m: any) => m.content)], [null, 1, ['Theirs']]);
});

// ------------------------------------------------------------------------------------------------
// POST context/search
// ------------------------------------------------------------------------------------------------

Deno.test('coach context/search: ranked hits grouped by chat, blocked turns excluded, browse by date', async () => {
  const h = await harness();
  const knee = seed(h, [['user', 'My left knee hurts after hill repeats'], ['assistant', 'Ease off the hills; knee pain usually settles.']], { title: 'Knee' });
  const blockedOnly = seed(h, [['user', 'knee secret', { meta: { blocked: true } }]], { title: 'Hidden' }, '2026-10-05T09:00:00Z');
  const aug = seed(h, [['user', 'Plan my marathon block']], { title: 'August block', summary: 'The user planned a marathon block.', summary_topics: ['marathon'] }, '2026-08-18T09:00:00Z');

  const { body } = await post(h, '/search', { query: 'knee' });
  assertEquals([body.terms, body.droppedTerms, body.totalHits, body.months], [['knee'], [], 2, [{ month: '2026-10', hits: 2 }]]);
  assertEquals(body.hits.map((x: any) => [x.threadId, x.title, x.role]).sort(), [[knee.id, 'Knee', 'assistant'], [knee.id, 'Knee', 'user']]);
  assert(body.hits.every((x: any) => x.at === new Date(x.at).toISOString() && x.snippet.includes('«')));
  assertEquals(body.threads.map((t: any) => [t.threadId, t.title, t.hits, t.summary, t.topics]), [[knee.id, 'Knee', 2, null, []]]);
  assertEquals(Object.keys(body.threads[0]).sort(), ['hits', 'lastMessageAt', 'snippet', 'summary', 'threadId', 'title', 'topics']);
  assert(!JSON.stringify(body).includes('secret') && !JSON.stringify(body).includes(blockedOnly.id));
  assertEquals((await post(h, '/search', { query: 'knee', excludeThreadId: knee.id })).body.threads, []);

  const august = (await post(h, '/search', { from: '2026-08-01', to: '2026-08-31' })).body;
  assertEquals([august.terms, august.hits, august.totalHits], [[], [], 0]);
  assertEquals(august.threads.map((t: any) => [t.threadId, t.hits, t.summary, t.topics]), [[aug.id, 0, 'The user planned a marathon block.', ['marathon']]]);
  const call = h.db.rpcCalls.filter((c) => c.name === 'coach_search_v1').at(-1)!;
  assertEquals([call.args.p_from, call.args.p_to, call.args.p_query], ['2026-08-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', '']);
  assertEquals((await post(h, '/search', { days: 30 })).body.threads.map((t: any) => t.threadId), [knee.id], 'the last 30 days');
  for (const bad of [{ from: '2026-02-31' }, { to: 'soon' }, { excludeThreadId: 'x' }]) assertEquals((await post(h, '/search', bad)).status, 400);
  assertEquals((await post(h, '/search', { query: 'knee' }, 'noop_other')).body.threads, []);
  assertEquals(h.model.calls.length, 0);
});

Deno.test('coach context/search: a query with no searchable words matches nothing instead of browsing recent chats', async () => {
  const h = await harness();
  for (let i = 0; i < 10; i++) seed(h, [['user', `Chat number ${i} about intervals`]], { title: `Chat ${i}`, summary: `Summary ${i}.` }, `2026-10-0${(i % 7) + 1}T09:00:00Z`);
  const { body } = await post(h, '/search', { query: 'what did we do' });
  assertEquals([body.terms, body.threads, body.hits, body.totalHits, body.months, body.noTerms], [[], [], [], 0, [], true]);
  const rpc = h.db.rpcCalls.filter((c) => c.name === 'coach_search_v1').at(-1)!;
  assertEquals(rpc.args.p_query, 'what did we do');
  // An empty query still browses, and a real match has no flag.
  assertEquals((await post(h, '/search', { days: 30 })).body.threads.length, 10);
  assert(!('noTerms' in (await post(h, '/search', { query: 'intervals' })).body));
});

Deno.test('coach context/search: words that match most of a long history are dropped', async () => {
  const h = await harness();
  const turns: Turn[] = Array.from({ length: 44 }, (_, i) => ['user', i === 7 ? 'run with a sore knee' : `run number ${i}`]);
  seed(h, turns, { title: 'Runs' });
  const { body } = await post(h, '/search', { query: 'run knee' });
  assertEquals([body.terms, body.droppedTerms, body.totalHits], [['knee'], ['run'], 1]);
});

// ------------------------------------------------------------------------------------------------
// POST context/thread
// ------------------------------------------------------------------------------------------------

Deno.test('coach context/thread: a capped recent window that pages back, or the windows around matches', async () => {
  const h = await harness();
  const turns: Turn[] = Array.from({ length: 20 }, (_, i) => [i % 2 ? 'assistant' : 'user', `${String(i).padStart(2, '0')} ${long('mile', 990)}`]);
  turns.splice(10, 0, ['user', 'hidden blocked words', { meta: { blocked: true } }]);
  turns.push(['user', `19b ${'x'.repeat(3_000)}`]);
  const t = seed(h, turns, { title: 'Long chat', summary: 'The user logged miles.' });

  const first = (await post(h, '/thread', { threadId: t.id })).body;
  assertEquals(first.thread, {
    id: t.id, title: 'Long chat', createdAt: iso(t.created_at), lastMessageAt: iso(h.db.threadRow(t.id).last_message_at),
    messageCount: 22, summary: 'The user logged miles.',
  });
  assertEquals(first.window, 'recent');
  assert(first.messages.reduce((n: number, m: any) => n + m.content.length, 0) <= 8_000);
  assertEquals(first.messages.at(-1).content.length, 1_500, 'each message cut to 1,500 characters');
  assert(first.messages.at(-1).content.endsWith('…'));
  assertEquals(Object.keys(first.messages[0]).sort(), ['at', 'content', 'role']);
  assert(first.hasMore && first.nextCursor);

  const seen: string[] = first.messages.map((m: any) => m.content.slice(0, 3));
  let cursor = first.nextCursor;
  for (let i = 0; cursor && i < 10; i++) {
    const page = (await post(h, '/thread', { threadId: t.id, cursor })).body;
    seen.unshift(...page.messages.map((m: any) => m.content.slice(0, 3)));
    cursor = page.nextCursor;
  }
  assertEquals(seen.length, 21, 'every non-blocked message exactly once');
  assertEquals(new Set(seen).size, 21);
  assert(!seen.some((s) => s.startsWith('hid')));

  const around = (await post(h, '/thread', { threadId: t.id, query: 'blocked 05' })).body;
  assertEquals(around.window, 'around_matches');
  assertEquals(around.messages.map((m: any) => m.content.slice(0, 2)), ['04', '05', '06'], 'the match and one message either side');

  assertEquals((await post(h, '/thread', { threadId: t.id }, 'noop_other')).status, 404);
  assertEquals((await post(h, '/thread', { threadId: crypto.randomUUID() })).body, { error: 'thread_not_found' });
  assertEquals((await post(h, '/thread', {})).status, 400);
  assertEquals((await post(h, '/thread', { threadId: t.id, cursor: 'bad' })).status, 400);
  assertEquals(h.model.calls.length, 0);
  assertEquals(orQuery("Don't over-train: 5k & 10k?"), 'don | over | train | 5k | 10k');
});

// ------------------------------------------------------------------------------------------------
// POST context/recall
// ------------------------------------------------------------------------------------------------

function seedMarathons(h: Harness) {
  const current = seed(h, [['user', 'Tell me about my marathon again'], ['assistant', 'Sure.']], { title: 'Today' });
  const aug = seed(h, [['user', 'Plan my marathon block for October'], ['assistant', 'Sixteen weeks, peaking at 80 km.'], ['user', 'thanks']],
    { title: 'August block', summary: 'The user planned a 16-week marathon block.' }, '2026-08-18T09:00:00Z');
  const sep = seed(h, [['user', 'Should my marathon long run be 32 km?'], ['assistant', 'Yes, once.'], ['user', 'secret marathon words', { meta: { blocked: true } }]],
    { title: 'Long run' }, '2026-09-10T09:00:00Z');
  seed(h, [['user', 'Best oats for breakfast?']], { title: 'Oats' }, '2026-09-20T09:00:00Z');
  return { current, aug, sep };
}

Deno.test('coach context/recall: matched chats are mapped in one wave and the notes stand on their own', async () => {
  const h = await harness({ map: notesFor });
  const { current, aug, sep } = seedMarathons(h);
  const res = await post(h, '/recall', { question: 'What marathon plans did I make?', keywords: 'marathon', threadId: current.id });
  assertEquals(res.status, 200);
  const body = res.body;
  assertEquals(body.status, 'answered');
  assertEquals(body.sources.map((s: any) => s.threadId).sort(), [aug.id, sep.id].sort());
  assertEquals(body.sources.find((s: any) => s.threadId === aug.id), { threadId: aug.id, title: 'August block', at: '2026-08-18T09:02:00.000Z' });
  assert(body.answer.includes('[August block, 2026-08-18]\n- 2026-08-18 User made a plan in August block'));
  assert(body.answer.includes('[Long run, 2026-09-10]'));
  assertEquals(body.coverage, { threadsMatched: 2, threadsExamined: 2, totalHits: 2, truncated: false });
  assertEquals(body.examined.chunks, 1);
  assertEquals(body.examined.subcalls, 1, 'two relevant chats or fewer: no reduce');
  assert(body.examined.messages >= 4);
  assertEquals(h.db.usage.get(USER)?.utility_calls, 2, 'chunks + 1 units, taken together');

  const [map] = h.model.of('map');
  assertEquals(map.body.max_tokens, 450);
  assertEquals(uuidsIn(promptOf(map)), []);
  assert(map.user.includes('Question: What marathon plans did I make?') && map.user.includes('Summary: The user planned a 16-week marathon block.'));
  assert(!map.user.includes('Tell me about my marathon again'), 'the current chat is excluded');
  assert(!map.user.includes('secret marathon words') && !map.user.includes('Oats'), 'blocked turns and unrelated chats never reach the model');
  assertEquals(h.model.of('reduce').length, 0);

  const all = (await post(h, '/recall', { question: 'marathon', threadId: current.id, includeCurrent: true })).body;
  assertEquals(all.coverage.threadsMatched, 3);
});

const promptOf = (c: ModelCall) => `${c.system}\n${c.user}`;

Deno.test('coach context/recall: at most four chunks of 10,000 characters, mapped concurrently, then reduced', async () => {
  const h = await harness({
    map: (c: ModelCall) => reply(notesFor(c), { delayMs: 25 }),
    reduce: { briefing: 'In August the user planned a 16-week block; by September the long run was 32 km.' },
  });
  for (let i = 0; i < 6; i++) {
    const turns: Turn[] = Array.from({ length: 6 }, (_, j) => [j % 2 ? 'assistant' : 'user', long(`ferritin${j} ferritin`)]);
    seed(h, turns, { title: `Iron chat ${i}` }, `2026-09-${String(10 + i).padStart(2, '0')}T09:00:00Z`);
  }
  const { body } = await post(h, '/recall', { question: 'What did we say about ferritin?' });
  const maps = h.model.of('map');
  // Each chat's share is sized for packing (4,999 characters for 5 to 8 chats), so two fit in a chunk and all six
  // are read; the hits that did not fit their chat's share are reported through `truncated`.
  assertEquals(maps.length, 3);
  assertEquals(h.model.stats.maxInFlight, 3, 'one wave: every chunk at once');
  for (const m of maps) assert(excerpts(m).length <= 10_000, `${excerpts(m).length} characters`);
  assertEquals(maps.map((m) => sections(m).length), [2, 2, 2]);
  assertEquals(body.status, 'answered');
  assertEquals(body.answer, 'In August the user planned a 16-week block; by September the long run was 32 km.');
  assertEquals(body.coverage, { threadsMatched: 6, threadsExamined: 6, totalHits: 36, truncated: true });
  assertEquals([body.examined.chunks, body.examined.subcalls], [3, 4]);
  assertEquals(body.sources.length, 6);
  const [reduce] = h.model.of('reduce');
  assertEquals(reduce.body.max_tokens, 600);
  assert(reduce.user.includes('Notes:\n[Iron chat'));
  assertEquals(h.db.usage.get(USER)?.utility_calls, 4);
});

Deno.test('coach context/recall: five matched chats whose sections the old share left at 5,000-7,600 characters are all read', async () => {
  const h = await harness({ map: notesFor, reduce: { briefing: 'Ferritin came up in five chats.' } });
  for (let i = 0; i < 5; i++) {
    const turns: Turn[] = [];
    for (let j = 0; j < 4; j++) turns.push(['user', `ferritin question ${j} ${'about iron stores '.repeat(16)}`], ['assistant', long('reply')]);
    seed(h, turns, { title: `Iron chat ${i}`, summary: `The user tracked iron. ${'Notes on diet and training. '.repeat(40)}` },
      `2026-09-${String(10 + i).padStart(2, '0')}T09:00:00Z`);
  }
  const { body } = await post(h, '/recall', { question: 'ferritin levels?' });
  const maps = h.model.of('map');
  assertEquals(body.coverage.threadsExamined, 5, 'none of the five is dropped');
  assertEquals(body.coverage.threadsMatched, 5);
  assert(maps.length <= 4 && maps.every((m) => excerpts(m).length <= 10_000));
  for (const m of maps) for (const part of excerpts(m).split(/\n\n(?=## )/)) assert(part.length <= recallShare(5), `${part.length} characters`);
  assertEquals([recallShare(1), recallShare(4), recallShare(5), recallShare(8), recallShare(9)], [10_000, 10_000, 4_999, 4_999, 3_332]);
});

Deno.test('coach context/recall: the hard deadline returns the notes gathered so far as partial', async () => {
  const slow: Promise<void>[] = [];
  const h = await harness({
    map: (c: ModelCall) => {
      if (!c.user.includes('Slow chat')) return notesFor(c);
      // A provider that ignores the abort: only the deadline can stop the wait.
      const late = new Promise<void>((resolve) => setTimeout(resolve, 600));
      slow.push(late);
      return late.then(() => notesFor(c));
    },
  }, {}, { timeScale: 0.01 });
  for (const title of ['Fast chat', 'Slow chat']) {
    seed(h, Array.from({ length: 5 }, (_, j): Turn => [j % 2 ? 'assistant' : 'user', long(`ferritin${j}`)]), { title }, title === 'Fast chat' ? '2026-09-01T09:00:00Z' : '2026-09-02T09:00:00Z');
  }
  const started = performance.now();
  const { body } = await post(h, '/recall', { question: 'ferritin0 ferritin1 ferritin2 ferritin3 ferritin4' });
  const elapsed = performance.now() - started;
  assertEquals(body.status, 'partial');
  assert(elapsed < 500, `answered at the deadline, not after the slow chunk (${Math.round(elapsed)} ms)`);
  assert(body.answer.includes('Fast chat') && !body.answer.includes('Slow chat'));
  assertEquals(body.sources.map((s: any) => s.title), ['Fast chat']);
  assertEquals(body.coverage.truncated, true);
  assertEquals(body.examined.chunks, 2);
  await Promise.all(slow);
});

Deno.test('coach context/recall: without budget it returns the lexical snippets; nothing to read is nothing_found', async () => {
  const h = await harness({ map: notesFor });
  seedMarathons(h);
  exhaust(h, 1);
  const { body } = await post(h, '/recall', { question: 'marathon' });
  assertEquals(body.status, 'budget', 'one unit left but the call needs chunks + 1');
  assert(body.answer.includes('[August block, 2026-08-18]') && body.answer.includes('marathon') && !body.answer.includes('«'));
  assertEquals(body.sources, []);
  assertEquals(body.coverage.threadsMatched, 3);
  assertEquals(h.model.calls.length, 0);

  const none = await harness({ map: notesFor });
  assertEquals((await post(none, '/recall', { question: 'marathon' })).body, {
    answer: '', sources: [], coverage: { threadsMatched: 0, threadsExamined: 0, totalHits: 0, truncated: false },
    examined: { chunks: 0, subcalls: 0, messages: 0 }, status: 'nothing_found',
  });

  const irrelevant = await harness({ map: { relevant: false, notes: [] } });
  seedMarathons(irrelevant);
  const miss = (await post(irrelevant, '/recall', { question: 'marathon' })).body;
  assertEquals([miss.status, miss.answer, miss.examined.chunks], ['nothing_found', '', 1]);

  const down = await harness({ map: reply(null, { status: 500 }) });
  seedMarathons(down);
  const unavailable = await post(down, '/recall', { question: 'marathon' });
  assertEquals(unavailable.body.status, 'unavailable');
  assert(!JSON.stringify(unavailable.body).includes('secret'));
  for (const bad of [{}, { question: '  ' }, { question: 'q', from: 'nope' }, { question: 'q', threadId: 'x' }]) {
    assertEquals((await post(down, '/recall', bad)).status, 400);
  }
  down.db.failing.add('coach_search_v1');
  assertEquals(await post(down, '/recall', { question: 'marathon' }), { status: 502, body: { error: 'coach_unavailable' } });
});

Deno.test('coach context/recall: no lexical match reads thread summaries: the window\'s, else the latest six', async () => {
  const h = await harness({ map: (c: ModelCall) => ({ relevant: true, notes: [`2026-08-0${sections(c).length % 9} User covered ${sections(c).length} chats`] }) });
  for (let i = 0; i < 14; i++) {
    seed(h, [['user', `topic ${i}`], ['assistant', 'ok']], { title: `Chat ${i}`, summary: `The user discussed subject number ${i} with Sana.` },
      `2026-08-${String(2 + i).padStart(2, '0')}T09:00:00Z`);
  }
  for (let i = 0; i < 8; i++) {
    seed(h, [['user', `later ${i}`]], { title: `September ${i}`, summary: `A September chat ${i}.` }, `2026-09-${String(2 + i).padStart(2, '0')}T09:00:00Z`);
  }
  const { body } = await post(h, '/recall', { question: 'What did we talk about?', from: '2026-08-01', to: '2026-08-31' });
  const maps = h.model.of('map');
  assertEquals(maps.length, 2, 'twelve summaries per chunk');
  assertEquals(maps.map((m) => sections(m).length).sort(), [12, 2]);
  assert(maps.every((m) => /Summary: The user discussed subject number \d+/.test(m.user) && !m.user.includes('September')));
  assertEquals([body.coverage.threadsMatched, body.coverage.threadsExamined, body.status], [14, 14, 'answered']);

  await post(h, '/recall', { question: 'zzqx' });
  const latest = h.model.of('map').slice(2);
  assertEquals(latest.length, 1);
  assertEquals(sections(latest[0]).map((s) => s.title), ['September 7', 'September 6', 'September 5', 'September 4', 'September 3', 'September 2']);
});
