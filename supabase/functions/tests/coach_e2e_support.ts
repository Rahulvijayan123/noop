// Shared pieces for driving the `coach` function over real HTTP against the disposable Postgres + PostgREST
// of local_postgres.ts (docs/COACH_MEMORY.md §9): installation credentials seeded the way Supabase-Auth
// provisioning leaves them, the handler served on a loopback port, a small client that speaks to it the way
// the iOS app does, and a scripted OpenAI-compatible upstream that recognises each cheap-model pass by its
// prompt and answers with realistic JSON (or streams a chat answer as SSE).
//
// Used by coach_memory_e2e_test.ts, the real-model smoke (coach_memory_smoke.ts) and the simulator dev
// server (supabase/tests/e2e/coach_dev_server.ts). Everything here is synthetic; nothing reads a real account.
import { type CoachConfig, handleCoachRequest } from '../_shared/coach.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import type { SupabaseRest } from '../_shared/rest.ts';
import { type Pass, passOf } from './coach_fake.ts';

export type { Pass };

// ------------------------------------------------------------------------------------------------
// Credentials
// ------------------------------------------------------------------------------------------------

const lit = (v: string) => `'${v.replaceAll("'", "''")}'`;

/**
 * One Supabase-Auth-provisioned installation and its `noop_` bearer for `userId` (the account row must
 * exist). Needs `startLocalPostgres({ authProvisioning: true })`.
 */
export async function seedInstallation(sql: (s: string) => Promise<string>, userId: string, token: string,
  sourceId: string = crypto.randomUUID()): Promise<void> {
  await sql(`insert into public.noop_app_installations(source_id,user_id,provisioning_method,platform,app_version)
      values (${lit(sourceId)},${lit(userId)},'supabase_auth','ios','1.0.0');
    insert into public.noop_ingest_tokens(id,user_id,source_id,token_hash,token_kind,provisioning_method)
      values (${lit(crypto.randomUUID())},${lit(userId)},${lit(sourceId)},${lit(hashIngestToken(token))},'installation','supabase_auth');`);
}

// ------------------------------------------------------------------------------------------------
// The coach function on a loopback port
// ------------------------------------------------------------------------------------------------

export interface CoachServer { origin: string; url: string; close: () => Promise<void> }

/** Serves `handleCoachRequest` at `<origin>/functions/v1/coach`. Maintenance runs inline (no EdgeRuntime). */
export function serveCoach(rest: SupabaseRest, cfg: CoachConfig,
  { hostname = '127.0.0.1', port = 0, onError, fetchImpl }: {
    hostname?: string; port?: number; onError?: (err: unknown) => void; fetchImpl?: typeof fetch;
  } = {}): CoachServer {
  const server = Deno.serve({ hostname, port, onListen() {} }, async (req) => {
    if (!new URL(req.url).pathname.startsWith('/functions/v1/coach')) return Response.json({ error: 'not_found' }, { status: 404 });
    try {
      return await handleCoachRequest(req, { rest, cfg, background: null, fetchImpl });
    } catch (err) {
      onError?.(err);
      throw err;
    }
  });
  const origin = `http://${hostname}:${(server.addr as Deno.NetAddr).port}`;
  return { origin, url: `${origin}/functions/v1/coach`, close: () => server.shutdown() };
}

/**
 * The same client, recording every PostgREST call that failed. Several coach paths swallow a failure on
 * purpose (best-effort caches, accounting), so an end-to-end run checks this list rather than the responses.
 */
export function watchRest(rest: SupabaseRest): { rest: SupabaseRest; failures: string[] } {
  const failures: string[] = [];
  const wrapped: Record<string, unknown> = { ...rest };
  for (const key of ['request', 'select', 'rpc', 'patch', 'upsert', 'delete'] as const) {
    const fn = rest[key] as (...args: unknown[]) => Promise<unknown>;
    wrapped[key] = async (...args: unknown[]) => {
      try {
        return await fn(...args);
      } catch (err: any) {
        failures.push(`${key} ${String(args[0])}: ${err?.status ?? ''} ${String(err?.message ?? err).slice(0, 300)}`);
        throw err;
      }
    };
  }
  return { rest: wrapped as SupabaseRest, failures };
}

export interface Reply { status: number; body: any; text: string; headers: Headers; ms: number }

/** A coach client for one bearer: JSON in, JSON (or the raw SSE text) out. */
export function coachClient(base: string, token: string) {
  async function call(method: string, path: string, body?: unknown): Promise<Reply> {
    const started = performance.now();
    const res = await fetch(`${base}/${path}`, {
      method,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json: any = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* SSE or plain text */ }
    return { status: res.status, body: json, text, headers: res.headers, ms: Math.round(performance.now() - started) };
  }
  return {
    get: (path: string) => call('GET', path),
    post: (path: string, body: unknown = {}) => call('POST', path, body),
    patch: (path: string, body: unknown) => call('PATCH', path, body),
    del: (path: string) => call('DELETE', path),
    call,
  };
}

export type CoachClient = ReturnType<typeof coachClient>;

/** The assistant text and the reasoning of a relayed SSE stream, the way CoachSSEParser reads it. */
export function readSse(text: string): { content: string; reasoning: string; done: boolean; raw: string[] } {
  let content = '';
  let reasoning = '';
  let done = false;
  const raw: string[] = [];
  for (const line of text.split('\n')) {
    if (!line.startsWith('data:')) continue;
    const payload = line.slice(5).trim();
    raw.push(payload);
    if (payload === '[DONE]') { done = true; continue; }
    try {
      for (const choice of JSON.parse(payload).choices ?? []) {
        if (typeof choice.delta?.content === 'string') content += choice.delta.content;
        if (typeof choice.delta?.reasoning === 'string') reasoning += choice.delta.reasoning;
      }
    } catch { /* keep-alive */ }
  }
  return { content, reasoning, done, raw };
}

// ------------------------------------------------------------------------------------------------
// The scripted upstream
// ------------------------------------------------------------------------------------------------

export interface UpstreamCall { pass: Pass | 'chat' | null; body: any; system: string; user: string }

const clipTo = (s: string, max: number) => (s.length <= max ? s : `${s.slice(0, max - 1).trimEnd()}…`);
const STOP = new Set(['what', 'when', 'where', 'which', 'with', 'about', 'that', 'this', 'from', 'have', 'into', 'your', 'were',
  'did', 'does', 'should', 'would', 'could', 'there', 'their', 'them', 'they', 'then', 'than', 'been', 'over', 'chat', 'chats',
  'earlier', 'talk', 'talked', 'said', 'tell', 'remind', 'again']);
const keywordsOf = (s: string) =>
  [...new Set((s.toLowerCase().match(/[a-z0-9]+/g) ?? []).filter((w) => w.length >= 4 && !STOP.has(w)))];

function lastUserText(body: any): string {
  const users = (Array.isArray(body?.messages) ? body.messages : []).filter((m: any) => m?.role === 'user');
  const content = users[users.length - 1]?.content;
  if (typeof content === 'string') return content;
  return Array.isArray(content) ? content.filter((p: any) => p?.type === 'text').map((p: any) => p.text).join('\n') : '';
}

/** The chat answer for a question: specific to what was asked, like the real model's would be. */
export function chatAnswer(question: string): string {
  if (/marathon/i.test(question)) {
    return 'With the Berlin marathon on 2026-11-29 you have about eight weeks. Build the Sunday long run to 32 km by early '
      + 'November, keep the two days after each long run easy, and hold intensity to one tempo session a week while the '
      + 'Achilles settles. Ease off if your HRV stays below your 30-day range for three days.';
  }
  if (/protein|vegetarian/i.test(question)) {
    return 'Lentils, tofu, tempeh, Greek yoghurt and eggs cover most of what a vegetarian runner needs. Aim for a protein '
      + 'source at every meal and a recovery snack within an hour of long runs.';
  }
  if (/sleep/i.test(question)) {
    return 'Your sleep has been shorter on nights after late sessions. Moving hard workouts before 18:00 and keeping a '
      + 'fixed wind-down should lift your sleep efficiency back toward 90%.';
  }
  return 'Your recent days look steady. Keep easy days easy, and plan your next hard session for a morning with a green charge.';
}

function titleFor(question: string): string {
  const race = /\bthe ([A-Z][a-z]+) marathon/.exec(question)?.[1];
  if (/marathon/i.test(question)) return `${race ?? 'Marathon'} ${race ? 'Marathon ' : ''}Training Plan`;
  if (/protein|vegetarian/i.test(question)) return 'Vegetarian Protein Ideas';
  if (/sleep/i.test(question)) return 'Sleep After Late Workouts';
  if (/swim/i.test(question)) return 'Weekly Swim Routine';
  if (/\bbike\b|\bride\b/i.test(question)) return 'Fueling Long Bike Rides';
  if (/asthma/i.test(question)) return 'Running With Asthma';
  return 'Weekly Training Check';
}

function followUpsFor(question: string): string[] {
  if (/marathon/i.test(question)) {
    return ['How long should my longest run be before Berlin?', question,
      'What dosage of ibuprofen helps my Achilles?', 'How do I taper in the last two weeks?',
      'Which pace should my tempo session be?'];
  }
  if (/protein|vegetarian/i.test(question)) {
    return ['How much protein do I need on long run days?', 'What is a good vegetarian recovery snack?', 'Can I get enough iron without meat?'];
  }
  if (/sleep/i.test(question)) {
    return ['How late can I train without hurting my sleep?', 'What should my wind-down routine look like?', 'Does my sleep affect my HRV?'];
  }
  return ['What should my next hard session be?', 'How is my recovery trending this month?', 'Should I add a rest day this week?'];
}

/** Durable facts the scripted curator recognises in user messages (and two it proposes that the guards must drop). */
function curatorOps(userLines: string[], sanaLines: string[], saved: { ref: string; topic: string; content: string }[]) {
  const ops: any[] = [];
  for (const text of userLines) {
    const m = /training for the (\w+) marathon on (\d{4}-\d{2}-\d{2})/i.exec(text);
    if (m) {
      const existing = saved.find((s) => /marathon/i.test(s.content));
      ops.push(existing ? { op: 'confirm', ref: existing.ref }
        : { op: 'add', topic: 'goal', importance: 4, content: `User is training for the ${m[1]} marathon on ${m[2]}` });
    }
    if (/recurring left achilles/i.test(text)) {
      ops.push({ op: 'add', topic: 'injury', importance: 4, content: 'User has a recurring left Achilles tendon injury' });
    }
    if (/\bvegetarian\b/i.test(text)) ops.push({ op: 'add', topic: 'nutrition', importance: 3, content: 'User is vegetarian' });
    if (/\bswim/i.test(text) && /tuesday/i.test(text)) ops.push({ op: 'add', topic: 'routine', importance: 3, content: 'User swims on Tuesdays' });
    if (/\basthma\b/i.test(text)) ops.push({ op: 'add', topic: 'health', importance: 4, content: 'User has mild asthma' });
    if (/\bcycle to work\b/i.test(text)) ops.push({ op: 'add', topic: 'routine', importance: 3, content: 'User cycles to work on weekdays' });
    if (/left knee (hurts|pain) on long runs/i.test(text)) {
      ops.push({ op: 'add', topic: 'injury', importance: 4, content: 'User has left knee pain on long runs' });
    }
    // What the real model did in the simulator run: it updated the older knee memory to the physio's finding and
    // left the copy Sana's save_memory tool had written in this chat beside it (the server folds the two).
    const knee = saved.find((s) => /left knee pain/i.test(s.content));
    if (/\bphysio\b/i.test(text) && /\bIT band\b/i.test(text) && knee) {
      ops.push({ op: 'update', ref: knee.ref, content: 'User saw a physio for mild IT band irritation in the left knee, which no longer hurts' });
    }
    const slept = /slept (\d+) hours last night/i.exec(text);
    // A passing state: the transient guard must drop it.
    if (slept) ops.push({ op: 'add', topic: 'sleep', importance: 2, content: `User slept ${slept[1]} hours last night` });
  }
  // Sana's own advice, phrased as a fact: the grounding guard must drop it.
  if (sanaLines.some((l) => /tempo session/i.test(l))) {
    ops.push({ op: 'add', topic: 'training', importance: 3, content: 'User should hold intensity to one tempo session a week' });
  }
  return ops;
}

function curatorReply(system: string, user: string) {
  const wantSummary = system.includes('"summary"');
  const wantMemory = system.includes('"memory_ops"');
  const prior = /^Summary so far: (.*)$/m.exec(user)?.[1];
  const saved = [...user.matchAll(/^(m\d+) \[(\w+), importance \d\] (.*)$/gm)].map((m) => ({ ref: m[1], topic: m[2], content: m[3] }));
  const messages = (user.split('New messages:\n')[1] ?? '').split('\n')
    .map((l) => /^\[(\d{4}-\d{2}-\d{2})\] (User|Sana): (.*)$/.exec(l)).filter((m): m is RegExpExecArray => !!m);
  const userLines = messages.filter((m) => m[2] === 'User');
  const out: Record<string, unknown> = {};
  if (wantSummary) {
    const told = userLines.map((m) => `On ${m[1]} the user asked: ${clipTo(m[3], 90)}`).join(' ');
    const base = prior && prior !== '(none yet)' ? `${prior} ` : '';
    out.summary = clipTo(`${base}${told} Sana answered with specific guidance.`, 1150);
    const text = messages.map((m) => m[3]).join(' ').toLowerCase();
    out.topics = ['marathon', 'achilles', 'nutrition', 'sleep', 'swimming', 'asthma'].filter((t) => text.includes(t.slice(0, 5)));
    out.open_loops = /report back/i.test(text) ? ['Report back after the Sunday long run'] : [];
  }
  if (wantMemory) out.memory_ops = curatorOps(userLines.map((m) => m[3]), messages.filter((m) => m[2] === 'Sana').map((m) => m[3]), saved);
  return out;
}

function suggestionsReply(user: string) {
  const threads = [...user.matchAll(/^\[(t\d+)\] "(.*?)" \((\d{4}-\d{2}-\d{2})\)/gm)].map((m) => ({ ref: m[1], title: m[2] }));
  const searches = (user.split('Recent searches:\n')[1] ?? '').split('\n').map((l) => /^- (.*)$/.exec(l)?.[1]).filter(Boolean) as string[];
  const flagged = /"flags":\["([^"]+)"/.exec(user)?.[1];
  const items: any[] = [];
  if (threads[0]) items.push({ text: clipTo(`Continue my ${threads[0].title} chat`, 64), kind: 'continue', thread: threads[0].ref });
  // A thread the prompt never listed: validation must drop it.
  items.push({ text: 'Pick up the chat about my old injury', kind: 'continue', thread: 't9' });
  items.push({ text: flagged ? `Why is my ${flagged.replace(/_/g, ' ')} today?` : 'How did I recover overnight?', kind: 'state' });
  if (/marathon/i.test(user)) items.push({ text: 'Am I on track for my Berlin marathon?', kind: 'goal' });
  items.push({ text: searches[0] ? `Show me more on ${searches[0]}` : 'What should I eat before a long run?', kind: 'explore' });
  items.push({ text: 'What dosage of melatonin should I take?', kind: 'explore' });
  return { suggestions: items };
}

function mapReply(user: string) {
  const question = /^Question: (.*)$/m.exec(user)?.[1] ?? '';
  const keys = keywordsOf(question);
  const notes: string[] = [];
  let ref = 't1';
  let sectionDay = '';
  for (const line of user.split('\n')) {
    const header = /^## \[(t\d+)\] ".*?" \((\d{4}-\d{2}-\d{2})/.exec(line);
    if (header) { ref = header[1]; sectionDay = header[2]; continue; }
    const m = /^(\d{4}-\d{2}-\d{2}) (User|Sana): (.*)$/.exec(line);
    const summary = /^Summary: (.*)$/.exec(line);
    const text = m ? m[3] : summary ? summary[1] : '';
    if (!text || !keys.some((k) => text.toLowerCase().includes(k))) continue;
    notes.push(clipTo(`${m ? m[1] : sectionDay} [${ref}] ${m ? (m[2] === 'User' ? 'User said' : 'Sana advised') : 'Summary'}: ${text}`, 220));
  }
  return { relevant: notes.length > 0, notes: notes.slice(0, 5) };
}

function consolidationReply(user: string) {
  const rows = [...user.matchAll(/^(m\d+) \[(\w+), importance (\d), \d{4}-\d{2}-\d{2}\] (.*)$/gm)]
    .map((m) => ({ ref: m[1], topic: m[2], importance: Number(m[3]), content: m[4] }));
  const groups = new Map<string, typeof rows>();
  for (const r of rows) groups.set(r.content.toLowerCase(), [...(groups.get(r.content.toLowerCase()) ?? []), r]);
  const ops = [...groups.values()].filter((g) => g.length > 1).map((g) => ({
    op: 'merge', refs: g.map((r) => r.ref), content: g[0].content, topic: g[0].topic, importance: Math.max(...g.map((r) => r.importance)),
  }));
  return { ops };
}

/** The JSON a utility pass answers with. */
export function scriptedJson(pass: Pass | null, system: string, user: string): Record<string, unknown> | null {
  const question = /^Question: (.*)$/m.exec(user)?.[1] ?? '';
  switch (pass) {
    case 'title': return { title: `"${titleFor(question)}."` };
    case 'followups': {
      const out: Record<string, unknown> = { follow_ups: followUpsFor(question) };
      if (/^title:/m.test(system)) out.title = titleFor(question);
      return out;
    }
    case 'suggestions': return suggestionsReply(user);
    case 'curator': return curatorReply(system, user);
    case 'consolidation': return consolidationReply(user);
    case 'map': return mapReply(user);
    case 'reduce': return { briefing: clipTo(`Across the earlier chats: ${(user.split('Notes:\n')[1] ?? '').replace(/\s+/g, ' ')}`, 1400) };
    default: return null;
  }
}

function sseStream(answer: string): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const words = answer.split(/(?<= )/);
  const chunks = [
    { choices: [{ index: 0, delta: { role: 'assistant', reasoning_content: 'Checking the plan against the race date. ' } }] },
    ...words.map((w) => ({ choices: [{ index: 0, delta: { content: w } }] })),
    { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 900, completion_tokens: words.length, total_tokens: 900 + words.length } },
  ];
  return new ReadableStream({
    start(controller) {
      for (const c of chunks) controller.enqueue(encoder.encode(`data: ${JSON.stringify(c)}\n\n`));
      controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
    },
  });
}

/**
 * An OpenAI-compatible endpoint on a loopback port. Chat requests (`stream: true`) get an SSE answer;
 * utility requests are recognised by their system prompt (coach_fake.ts `passOf`) and answered by
 * `scriptedJson`, or by `override` when it returns something for that call.
 */
export function startScriptedUpstream(override?: (call: UpstreamCall) => Response | Record<string, unknown> | null | undefined) {
  const calls: UpstreamCall[] = [];
  /** Passes whose next call fails with a provider error (each entry is used once). */
  const failNext: (Pass | 'chat')[] = [];
  /** Work to run while a pass's next call is in flight, before it is answered (each entry is used once). */
  const holdNext: { pass: Pass | 'chat'; work: (call: UpstreamCall) => Promise<void> }[] = [];
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, async (req) => {
    const body = await req.json().catch(() => null);
    if (!body || !Array.isArray(body.messages)) return Response.json({ error: 'bad request' }, { status: 400 });
    const system = body.messages.find((m: any) => m?.role === 'system')?.content ?? '';
    const user = lastUserText(body);
    const isChat = body.response_format?.type !== 'json_object';
    const call: UpstreamCall = { pass: isChat ? 'chat' : passOf(String(system)), body, system: String(system), user };
    calls.push(call);
    const fault = failNext.indexOf(call.pass as Pass);
    if (fault >= 0) {
      failNext.splice(fault, 1);
      return Response.json({ error: { message: 'scripted provider fault' } }, { status: 503 });
    }
    const hold = holdNext.findIndex((h) => h.pass === call.pass);
    if (hold >= 0) await holdNext.splice(hold, 1)[0].work(call);
    const custom = override?.(call);
    if (custom instanceof Response) return custom;
    if (isChat) {
      const answer = chatAnswer(user);
      if (body.stream === false) return Response.json({ choices: [{ message: { content: answer }, finish_reason: 'stop' }] });
      return new Response(sseStream(answer), { headers: { 'content-type': 'text/event-stream' } });
    }
    const json = custom ?? scriptedJson(call.pass as Pass | null, call.system, user);
    if (!json) return Response.json({ error: 'no script for this prompt' }, { status: 500 });
    return Response.json({
      choices: [{ message: { content: JSON.stringify(json) }, finish_reason: 'stop' }],
      usage: { prompt_tokens: Math.ceil((call.system.length + user.length) / 4), completion_tokens: 60,
        total_tokens: Math.ceil((call.system.length + user.length) / 4) + 60 },
    });
  });
  const url = `http://127.0.0.1:${(server.addr as Deno.NetAddr).port}/inference/v1/chat/completions`;
  return {
    url, calls,
    failOnce: (pass: Pass | 'chat') => { failNext.push(pass); },
    /** Runs `work` while the next `pass` call waits for its answer: something the user does mid-pass. */
    duringNext: (pass: Pass | 'chat', work: (call: UpstreamCall) => Promise<void>) => { holdNext.push({ pass, work }); },
    of: (pass: Pass | 'chat') => calls.filter((c) => c.pass === pass),
    since: (mark: number) => calls.slice(mark),
    close: () => server.shutdown(),
  };
}

export type ScriptedUpstream = ReturnType<typeof startScriptedUpstream>;
