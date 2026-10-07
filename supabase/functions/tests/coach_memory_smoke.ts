// Real-model smoke for Sana's memory (docs/COACH_MEMORY.md §9). Not a Deno.test and not part of the default
// run: it spends Fireworks tokens. It starts the same disposable PostgreSQL + PostgREST and loopback `coach`
// function as coach_memory_e2e_test.ts, but with the real upstream, seeds two invented conversations over HTTP
// (no real account or data), and prints what the cheap model produced for each pass: titles, follow-ups,
// curator ops with the resulting memories and summaries, a recall answer with its coverage, starter
// suggestions, and per-pass latency with the utility token totals.
//
//   cd supabase/functions && set -a && . <path to .env> && set +a && \
//     EDGE_TEST_ARTIFACTS=/tmp/edgeart DENO_DIR=/tmp/deno-cache deno run -A --no-lock tests/coach_memory_smoke.ts
//
// Only FIREWORKS_AI_API_KEY and the COACH_* settings are read from the environment; nothing else in it (in
// particular no database URL or service key) is used. The key is never printed.
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { coachConfig } from '../_shared/coach.ts';
import { coachClient, readSse, seedInstallation, serveCoach, watchRest } from './coach_e2e_support.ts';
import { passOf } from './coach_fake.ts';

const key = (Deno.env.get('FIREWORKS_AI_API_KEY') ?? '').trim();
if (!key) {
  console.error('FIREWORKS_AI_API_KEY is not set; load it from the .env first.');
  Deno.exit(2);
}
if (!Deno.env.get('EDGE_TEST_ARTIFACTS')) Deno.env.set('EDGE_TEST_ARTIFACTS', await Deno.makeTempDir({ dir: '/tmp', prefix: 'cms' }));

const env: Record<string, string> = { FIREWORKS_AI_API_KEY: key };
for (const name of ['COACH_MODEL_CHAT', 'COACH_MODEL_UTILITY', 'COACH_UTILITY_REASONING', 'COACH_UTILITY_API_KEY', 'COACH_DAILY_UTILITY_LIMIT']) {
  const v = Deno.env.get(name);
  if (v !== undefined) env[name] = v;
}
const cfg = coachConfig(env);

// ------------------------------------------------------------------------------------------------
// Per-pass latency and tokens, measured on the function's own upstream calls
// ------------------------------------------------------------------------------------------------

type Stat = { calls: number; ms: number[]; tokens: number; failed: number };
const stats = new Map<string, Stat>();
const replies: { pass: string; content: string }[] = [];
const stat = (pass: string) => stats.get(pass) ?? stats.set(pass, { calls: 0, ms: [], tokens: 0, failed: 0 }).get(pass)!;

const measuredFetch: typeof fetch = async (input, init) => {
  const url = input instanceof Request ? input.url : String(input);
  if (url !== cfg.upstreamUrl) return await fetch(input, init);
  let body: any = {};
  try { body = JSON.parse(String(init?.body ?? '{}')); } catch { /* not ours */ }
  const system = body.messages?.find((m: any) => m.role === 'system')?.content ?? '';
  const pass = body.response_format?.type === 'json_object' ? passOf(String(system)) ?? 'unknown' : 'chat';
  const s = stat(pass);
  s.calls++;
  const started = performance.now();
  let res: Response;
  try {
    res = await fetch(input, init);
  } catch (err) {
    s.failed++;
    s.ms.push(Math.round(performance.now() - started));
    throw err;
  }
  if (pass === 'chat') {
    s.ms.push(Math.round(performance.now() - started));
    if (!res.ok) s.failed++;
    return res;
  }
  const text = await res.text();
  s.ms.push(Math.round(performance.now() - started));
  try {
    const json = JSON.parse(text);
    s.tokens += Number(json?.usage?.total_tokens ?? 0) || 0;
    const choice = json?.choices?.[0];
    if (!res.ok || !choice || choice.finish_reason === 'length') s.failed++;
    replies.push({ pass, content: String(choice?.message?.content ?? `(HTTP ${res.status})`) });
  } catch {
    s.failed++;
    replies.push({ pass, content: `(HTTP ${res.status}, unreadable body)` });
  }
  return new Response(text, { status: res.status, headers: res.headers });
};

// ------------------------------------------------------------------------------------------------
// The invented user
// ------------------------------------------------------------------------------------------------

const SYSTEM = 'You are Sana, the health and fitness assistant in the Nara app. Answer in under 130 words, '
  + 'specific and practical, with no medical diagnosis.';
const DAY = 86_400_000;
const MINUTE = 60_000;
const NOW = Date.now();
const iso = (ms: number) => new Date(ms).toISOString();
const T1 = crypto.randomUUID();
const T2 = crypto.randomUUID();
const T3 = crypto.randomUUID();
const T4 = crypto.randomUUID();
const TOKEN = `noop_smoke_${crypto.randomUUID().replaceAll('-', '')}`;

type Turn = { q: string; a?: string };
const THREAD_1: Turn[] = [
  { q: "I'm training for the Valencia marathon on 2026-12-06 and I have a recurring left Achilles tendon injury that flares up "
    + 'after hill repeats. How should I structure my long runs over the next eight weeks?' },
  { q: 'I usually run at 6am before work, and I can only train five days a week. Does that change the plan?',
    a: 'Five days works well. Put the long run on Sunday, an easy run on Monday, a steady run on Tuesday, a rest day on '
      + 'Wednesday, an easy run on Thursday with strides, and a moderate run on Saturday. Keep hills flat for now to protect the Achilles.' },
  { q: 'My HRV was 38 ms this morning and I slept 5 hours last night. Should I skip today\'s tempo?',
    a: 'Yes, swap the tempo for 30 easy minutes or rest. One short night is not a problem, but a low HRV after short sleep '
      + 'means a hard session will cost more than it gives. Move the tempo to Thursday if tonight\'s sleep is better.' },
  { q: "OK. I'll report back after Sunday's 28 km long run.",
    a: 'Sounds good. Keep the first 20 km conversational, take a gel every 40 minutes, and note how the Achilles feels the next morning.' },
];
const THREAD_2: Turn[] = [
  { q: "I've been vegetarian for six years and I don't eat eggs. What should I eat after long runs to recover?" },
  { q: "Also, I'm lactose intolerant, so whey shakes are out. What else works?",
    a: 'Pea or soy protein isolate works as well as whey. Lactose-free Greek yoghurt, tofu scrambles, tempeh and lentil '
      + 'dishes are good real-food options. Aim for about 25 g of protein within an hour of long runs.' },
];

// A later session that restates one known fact and changes another: the curator should confirm or update, not add.
const THREAD_3: Turn[] = [
  { q: "Quick update: I'm still vegetarian, and I've moved to six training days a week since my Achilles feels better. "
    + 'Can I add a second quality session?',
    a: 'Yes, carefully. Keep one tempo and add a short interval session on flat ground, at least 48 hours apart, and keep the '
      + 'sixth day truly easy. If the Achilles stiffens the next morning, drop the intervals for a week.' },
];

const header = (s: string) => console.log(`\n=== ${s} ${'='.repeat(Math.max(0, 90 - s.length))}`);
const show = (label: string, v: unknown) => console.log(`${label}:`, typeof v === 'string' ? v : JSON.stringify(v, null, 2));

const db = await startLocalPostgres({ authProvisioning: true, coachMemory: true });
const watched = watchRest(db.rest);
const server = serveCoach(watched.rest, cfg, { fetchImpl: measuredFetch });
const api = coachClient(server.url, TOKEN);
const timings: Record<string, number[]> = {};
const timed = async <T extends { ms: number }>(route: string, work: Promise<T>): Promise<T> => {
  const r = await work;
  (timings[route] ??= []).push(r.ms);
  return r;
};

try {
  await seedInstallation(db.sql, USER_A, TOKEN);
  console.log(`models: chat=${cfg.models.chat} utility=${cfg.models.utility} reasoning=${cfg.utilityReasoning || '(omitted)'}`);
  const status = await api.get('status');
  show('status.features', status.body?.features);

  /** Saves a turn; streams the answer from the real chat model unless one is scripted. */
  const runTurn = async (threadId: string, turn: Turn, at: number, history: { role: string; content: string }[], title?: string) => {
    const save = (rows: unknown[]) => timed('POST messages', api.post('messages', { messages: rows }));
    const u = await save([{ clientId: crypto.randomUUID(), threadId, role: 'user', content: turn.q, meta: {}, createdAt: iso(at), ...(title ? { threadTitle: title } : {}) }]);
    if (u.status !== 200 || u.body?.saved !== 1) throw new Error(`save failed: ${u.status} ${u.text}`);
    let answer = turn.a;
    if (!answer) {
      const chat = await timed('POST chat (stream)', api.post('chat', {
        mode: 'chat', stream: true, reasoning_effort: 'none', max_tokens: 600,
        messages: [{ role: 'system', content: SYSTEM }, ...history, { role: 'user', content: turn.q }],
      }));
      if (chat.status !== 200) throw new Error(`chat failed: ${chat.status} ${chat.text.slice(0, 200)}`);
      answer = readSse(chat.text).content.trim();
      if (!answer) throw new Error('the chat stream carried no answer');
    }
    await save([{ clientId: crypto.randomUUID(), threadId, role: 'assistant', content: answer, meta: {}, createdAt: iso(at + MINUTE) }]);
    history.push({ role: 'user', content: turn.q }, { role: 'assistant', content: answer });
    return answer;
  };

  header('Thread 1: marathon (9 days ago)');
  const h1: { role: string; content: string }[] = [];
  const a1 = await runTurn(T1, THREAD_1[0], NOW - 9 * DAY, h1, "I'm training for the Valencia marathon");
  show('answer 1', a1);
  const f1 = await timed('POST followups', api.post('followups', { threadId: T1, question: THREAD_1[0].q, answer: a1, asked: [THREAD_1[0].q], locale: 'en-US', wantTitle: true }));
  show('title (followups wantTitle)', f1.body?.title ?? '(none)');
  show('follow-ups for answer 1', f1.body?.followUps);
  for (const [i, turn] of THREAD_1.slice(1).entries()) await runTurn(T1, turn, NOW - 9 * DAY + (i + 1) * 10 * MINUTE, h1);

  header('Thread 2: vegetarian recovery (3 days ago)');
  const h2: { role: string; content: string }[] = [];
  const a2 = await runTurn(T2, THREAD_2[0], NOW - 3 * DAY, h2);
  show('answer 1', a2);
  const t2 = await timed('POST threads/:id/title', api.post(`threads/${T2}/title`, { question: THREAD_2[0].q, answer: a2, locale: 'en-US' }));
  show('title (title route)', t2.body);
  const f2 = await timed('POST followups', api.post('followups', { threadId: T2, question: THREAD_2[0].q, answer: a2, asked: [THREAD_2[0].q], locale: 'en-US' }));
  show('follow-ups for answer 1', f2.body?.followUps);
  await runTurn(T2, THREAD_2[1], NOW - 3 * DAY + 10 * MINUTE, h2);

  header('Thread 3: a later session (1 hour ago)');
  const a3 = await runTurn(T3, THREAD_3[0], NOW - 60 * MINUTE, [], 'Quick update: I\'m still vegetarian');
  const f3 = await timed('POST followups', api.post('followups', { threadId: T3, question: THREAD_3[0].q, answer: a3, asked: [THREAD_3[0].q], locale: 'en-US', wantTitle: true }));
  show('title (followups wantTitle)', f3.body?.title ?? '(none)');
  show('follow-ups', f3.body?.followUps);

  header('Maintain (curator + summary)');
  for (const [label, id] of [['thread 1', T1], ['thread 2', T2], ['thread 3', T3]] as const) {
    const m = await timed('POST threads/:id/maintain', api.post(`threads/${id}/maintain`, {}));
    show(`maintain ${label}`, m.body);
    const events = JSON.parse(await db.sql(`select coalesce(json_agg(json_build_object('op', op, 'actor', actor,
        'content', coalesce(after->>'content', before->>'content'), 'topic', coalesce(after->>'topic', before->>'topic'),
        'importance', coalesce(after->>'importance', before->>'importance')) order by id), '[]'::json)
      from coach_memory_events where thread_id = '${id}'`));
    show(`curator ops applied (${label})`, events);
    const thread = JSON.parse(await db.sql(`select json_build_object('title', title, 'summary', summary, 'topics', summary_topics,
        'open_loops', open_loops, 'summary_messages', summary_messages, 'message_count', message_count) from coach_threads where id = '${id}'`));
    show(`summary (${label})`, thread);
  }
  const memories = await api.get('memories');
  show('memories now', memories.body?.memories?.map((m: any) => `[${m.topic}, ${m.importance}, ${m.source}] ${m.content}`));

  header('Recall about thread 1, from a new chat');
  const recall = await timed('POST context/recall', api.post('context/recall', {
    question: 'What did we decide about my long runs and the Achilles?', threadId: T4,
  }));
  show('recall.status', recall.body?.status);
  show('recall.answer', recall.body?.answer);
  show('recall.sources', recall.body?.sources);
  show('recall.coverage', recall.body?.coverage);
  show('recall.examined', recall.body?.examined);

  header('Context manifest for the new chat (no model call)');
  const manifest = await timed('POST context', api.post('context', { threadId: T4, question: 'How should I adjust this week around my Achilles?' }));
  show('manifest.memories', manifest.body?.memories?.map((m: any) => `${m.pinned ? '[pinned] ' : ''}${m.content}`));
  show('manifest.library.relevant', manifest.body?.library?.relevant);
  show('manifest.openLoops', manifest.body?.openLoops);

  header('Starter suggestions');
  const state = { day: iso(NOW).slice(0, 10), charge: 'yellow', hrv: 'down', sleep: 'short', effort: 'high', dataDays: 140,
    daysSinceWorkout: 1, lastSport: 'running', weekday: new Date(NOW).toLocaleDateString('en-US', { weekday: 'long' }),
    dayPart: 'morning', flags: ['hrv_down', 'short_sleep'] };
  const fallback = ['How did I sleep last night?', 'What should I train today?', 'How is my recovery trending?', 'Plan my week'];
  const starters = await timed('POST suggestions', api.post('suggestions', { state, fallback, locale: 'en-US' }));
  show('suggestions', starters.body);
  const cached = await timed('POST suggestions', api.post('suggestions', { state, fallback, locale: 'en-US' }));
  show('second call source', cached.body?.source);

  header('Per-pass latency (upstream round trip) and tokens');
  for (const [pass, s] of stats) {
    const sorted = [...s.ms].sort((x, y) => x - y);
    console.log(`${pass.padEnd(14)} calls=${s.calls} failed=${s.failed} ms=[${s.ms.join(', ')}] median=${sorted[Math.floor(sorted.length / 2)] ?? 0} tokens=${s.tokens}`);
  }
  header('Route latency (client round trip)');
  for (const [route, ms] of Object.entries(timings)) console.log(`${route.padEnd(28)} ${ms.join(', ')} ms`);
  const usage = (await db.sql(`select coalesce(sum(utility_calls), 0) || ' units, ' || coalesce(sum(utility_tokens), 0) || ' tokens, chat calls ' || coalesce(sum(calls), 0)
    from coach_usage where user_id = '${USER_A}'`)).trim();
  console.log(`utility budget used: ${usage}`);
  if (watched.failures.length) show('database call failures', watched.failures);

  header('Raw utility replies (synthetic data)');
  for (const r of replies) console.log(`[${r.pass}] ${r.content.replace(/\s+/g, ' ').slice(0, 1500)}`);
} finally {
  await server.close();
  await db.close();
}
