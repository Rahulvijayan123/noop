// In-app coach backend: an authenticated model relay plus the coach's conversation and memory store.
//
// The harness (system prompt, tool loop, tools over the owner's local data) runs on the phone; this
// function is the part that must not: it holds the model provider key, picks the model for each mode,
// bounds every request, meters usage per owner, runs the visual pipeline, and persists memory and history.
import { IdentityError, resolveUploadIdentity } from './tokens.ts';
import { isUuid } from './keys.ts';
import type { SupabaseRest } from './rest.ts';
import { parseVisualRequest, produceVisual, routeVisual, type VisualDeps } from './coach_visual.ts';

export type CoachMode = 'chat' | 'vision';

export interface CoachConfig {
  fireworksKey: string;
  upstreamUrl: string;
  models: Record<CoachMode, string>;
  dailyCallLimit: number;
  allowLegacyFleetUploads: boolean;
  allowLegacyEnrollment?: boolean;
  jevKey: string;
}

export function coachConfig(env: Record<string, string | undefined> = Deno.env.toObject()): CoachConfig {
  const pick = (name: string, fallback: string) => (env[name] ?? '').trim() || fallback;
  const limit = Number(pick('COACH_DAILY_CALL_LIMIT', '400'));
  return {
    fireworksKey: pick('FIREWORKS_AI_API_KEY', ''),
    upstreamUrl: pick('COACH_UPSTREAM_URL', 'https://api.fireworks.ai/inference/v1/chat/completions'),
    models: {
      chat: pick('COACH_MODEL_CHAT', 'accounts/fireworks/models/deepseek-v4p1-flash'),
      vision: pick('COACH_MODEL_VISION', 'accounts/fireworks/models/qwen3p8-max'),
    },
    dailyCallLimit: Number.isFinite(limit) && limit > 0 ? Math.trunc(limit) : 400,
    allowLegacyFleetUploads: pick('NOOP_ALLOW_LEGACY_FLEET_UPLOADS', '').toLowerCase() === 'true',
    allowLegacyEnrollment: pick('NOOP_ALLOW_LEGACY_ENROLLMENT', '').toLowerCase() === 'true',
    jevKey: pick('TYPESAFE_API_KEY', ''),
  };
}

// Tool rounds ask for ~1200 tokens and the final answer round for up to 4096; the ceilings here bound a hostile client.
const MODES: Record<CoachMode, { maxTokens: number }> = {
  chat: { maxTokens: 4096 },
  vision: { maxTokens: 1200 },
};
// The harness picks the reasoning effort per round: none on tool rounds, low or high on the final answer.
const EFFORTS = new Set(['none', 'low', 'high']);

const MAX_BODY_BYTES = 6_000_000;
const MAX_IMAGE_BYTES = 4_500_000;
const MAX_TEXT_CHARS = 60_000;
const MAX_MESSAGES = 80;
const MAX_TOOLS = 24;
const MAX_MEMORIES = 50;
const MAX_STORED_MESSAGES = 500;
const MEMORY_TOPICS = new Set(['goal', 'injury', 'preference', 'achievement', 'lifestyle', 'general']);
const TOOL_NAME = /^[A-Za-z0-9_]{1,64}$/;
const IMAGE_URL = /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

const isObject = (v: unknown): v is Record<string, any> => !!v && typeof v === 'object' && !Array.isArray(v);

async function readJson(req: Request): Promise<any> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > MAX_BODY_BYTES) throw fail('payload_too_large', 413);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw fail('invalid_body', 400); }
}

function cleanContent(content: unknown, mode: CoachMode): string | unknown[] {
  if (typeof content === 'string') {
    if (content.length > MAX_TEXT_CHARS) throw fail('message_too_large', 413);
    return content;
  }
  if (!Array.isArray(content) || !content.length) throw fail('invalid_messages', 400);
  let imageBytes = 0;
  const parts = content.map((part: any) => {
    if (part?.type === 'text' && typeof part.text === 'string' && part.text.length <= MAX_TEXT_CHARS) {
      return { type: 'text', text: part.text };
    }
    const url = part?.type === 'image_url' ? part.image_url?.url : undefined;
    if (mode === 'vision' && typeof url === 'string' && IMAGE_URL.test(url)) {
      imageBytes += url.length;
      return { type: 'image_url', image_url: { url } };
    }
    throw fail('invalid_messages', 400);
  });
  if (imageBytes > MAX_IMAGE_BYTES) throw fail('image_too_large', 413);
  return parts;
}

/** Keeps only the OpenAI message fields the harness uses, so a client cannot smuggle provider parameters. */
export function cleanMessages(raw: unknown, mode: CoachMode) {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_MESSAGES) throw fail('invalid_messages', 400);
  return raw.map((m: any) => {
    if (!isObject(m) || !['system', 'user', 'assistant', 'tool'].includes(m.role)) throw fail('invalid_messages', 400);
    if (m.role === 'tool') {
      if (typeof m.tool_call_id !== 'string' || typeof m.content !== 'string') throw fail('invalid_messages', 400);
      return { role: 'tool', tool_call_id: m.tool_call_id.slice(0, 128), content: cleanContent(m.content, mode) };
    }
    if (m.role === 'assistant' && Array.isArray(m.tool_calls)) {
      const calls = m.tool_calls.slice(0, 16).map((c: any) => {
        if (typeof c?.id !== 'string' || !TOOL_NAME.test(c?.function?.name ?? '') || typeof c.function.arguments !== 'string') {
          throw fail('invalid_messages', 400);
        }
        return { id: c.id.slice(0, 128), type: 'function', function: { name: c.function.name, arguments: c.function.arguments.slice(0, 8000) } };
      });
      const content = typeof m.content === 'string' && m.content ? cleanContent(m.content, mode) : undefined;
      return content === undefined ? { role: 'assistant', tool_calls: calls } : { role: 'assistant', content, tool_calls: calls };
    }
    return { role: m.role, content: cleanContent(m.content, mode) };
  });
}

export function cleanTools(raw: unknown) {
  if (raw == null) return undefined;
  if (!Array.isArray(raw) || raw.length > MAX_TOOLS) throw fail('invalid_tools', 400);
  return raw.map((t: any) => {
    const fn = t?.function;
    if (!isObject(fn) || !TOOL_NAME.test(fn.name ?? '') || typeof fn.description !== 'string'
        || fn.description.length > 3000 || !isObject(fn.parameters)) throw fail('invalid_tools', 400);
    return { type: 'function', function: { name: fn.name, description: fn.description, parameters: fn.parameters } };
  });
}

/** Provider streams name the chain of thought `reasoning_content`; the harness reads `reasoning`. */
export function normalizeSseChunk(line: string): string {
  if (!line.startsWith('data:')) return line;
  const payload = line.slice(5).trim();
  if (!payload || payload === '[DONE]') return line;
  try {
    const chunk = JSON.parse(payload);
    for (const choice of chunk.choices ?? []) {
      const delta = choice.delta;
      if (delta && 'reasoning_content' in delta) {
        if (delta.reasoning_content) delta.reasoning = delta.reasoning_content;
        delete delta.reasoning_content;
      }
    }
    return `data: ${JSON.stringify(chunk)}`;
  } catch {
    return line;
  }
}

function normalizeStream(upstream: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let carry = '';
  return upstream.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      carry += decoder.decode(chunk, { stream: true });
      const lines = carry.split('\n');
      carry = lines.pop() ?? '';
      for (const line of lines) controller.enqueue(encoder.encode(`${normalizeSseChunk(line.replace(/\r$/, ''))}\n`));
    },
    flush(controller) {
      if (carry) controller.enqueue(encoder.encode(`${normalizeSseChunk(carry)}\n`));
    },
  }));
}

async function chat(req: Request, userId: string, { rest, cfg, fetchImpl }: Deps): Promise<Response> {
  if (!cfg.fireworksKey) return Response.json({ error: 'coach_unconfigured' }, { status: 503 });
  const body = await readJson(req);
  const mode = body?.mode as CoachMode;
  if (!isObject(body) || !(mode in MODES)) throw fail('invalid_mode', 400);
  const limits = MODES[mode];
  const stream = body.stream !== false;
  const messages = cleanMessages(body.messages, mode);
  const tools = mode === 'vision' ? undefined : cleanTools(body.tools);
  const toolChoice = tools && ['auto', 'none', 'required'].includes(body.tool_choice) ? body.tool_choice : undefined;
  const maxTokens = Number.isFinite(body.max_tokens)
    ? Math.max(16, Math.min(limits.maxTokens, Math.trunc(body.max_tokens))) : limits.maxTokens;
  const temperature = Number.isFinite(body.temperature) ? Math.max(0, Math.min(1, body.temperature)) : 0.4;
  const effort = mode === 'vision' ? 'none' : EFFORTS.has(body.reasoning_effort) ? body.reasoning_effort : 'low';

  // Reserve the budget only once the request is known to be well-formed.
  if (!(await rest.rpc('coach_take_quota', { p_user_id: userId, p_limit: cfg.dailyCallLimit }))) {
    return Response.json({ error: 'daily_limit' }, { status: 429 });
  }

  const upstream = await fetchImpl(cfg.upstreamUrl, {
    method: 'POST',
    headers: { authorization: `Bearer ${cfg.fireworksKey}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(170_000),
    body: JSON.stringify({
      model: cfg.models[mode], messages, stream, max_tokens: maxTokens, temperature,
      reasoning_effort: effort,
      ...(stream ? { stream_options: { include_usage: true } } : {}),
      ...(tools ? { tools } : {}), ...(toolChoice ? { tool_choice: toolChoice } : {}),
    }),
  });
  if (!upstream.ok) {
    await upstream.body?.cancel();
    return Response.json({ error: 'upstream_error', status: upstream.status }, { status: upstream.status === 429 ? 429 : 502 });
  }
  if (stream && upstream.body) {
    return new Response(normalizeStream(upstream.body), {
      headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store', 'x-accel-buffering': 'no' },
    });
  }
  const json = await upstream.json();
  return Response.json({ content: json?.choices?.[0]?.message?.content ?? '' });
}

function memoryInput(body: any) {
  const content = typeof body?.content === 'string' ? body.content.trim() : '';
  if (!content || content.length > 500) throw fail('invalid_memory', 400);
  const importance = Number.isFinite(body.importance) ? Math.max(1, Math.min(5, Math.round(body.importance))) : 3;
  const topic = typeof body.topic === 'string' && MEMORY_TOPICS.has(body.topic.toLowerCase()) ? body.topic.toLowerCase() : 'general';
  return { content, importance, topic };
}

const publicMemory = (r: any) => ({ id: r.id, content: r.content, topic: r.topic, importance: r.importance, createdAt: r.created_at });

async function memoriesRoute(req: Request, userId: string, tail: string[], { rest }: Deps): Promise<Response> {
  const owner = `user_id=eq.${userId}`;
  const ranked = `${owner}&order=importance.desc,created_at.desc&select=id,content,topic,importance,created_at`;
  if (req.method === 'GET') {
    return Response.json({ memories: (await rest.select('coach_memory_items', `${ranked}&limit=${MAX_MEMORIES}`)).map(publicMemory) });
  }
  if (req.method === 'POST') {
    const input = memoryInput(await readJson(req));
    const existing = await rest.select('coach_memory_items', ranked);
    const dup = existing.find((r: any) => r.content.trim().toLowerCase() === input.content.toLowerCase());
    if (dup) return Response.json({ memory: publicMemory(dup), deduped: true });
    const [row] = await rest.request('coach_memory_items', { method: 'POST', body: { user_id: userId, ...input } });
    // Past the cap the lowest-ranked fact goes, which may be the one just saved if it ranks last.
    const rank = (a: any, b: any) => (b.importance - a.importance) || (a.created_at < b.created_at ? 1 : -1);
    const overflow = [...existing, row].sort(rank).slice(MAX_MEMORIES).map((r: any) => r.id);
    if (overflow.length) await rest.delete('coach_memory_items', `${owner}&id=in.(${overflow.join(',')})`);
    return Response.json({ memory: publicMemory(row), kept: !overflow.includes(row.id) });
  }
  if (req.method === 'DELETE') {
    if (tail[0] && !isUuid(tail[0])) throw fail('invalid_id', 400);
    await rest.delete('coach_memory_items', tail[0] ? `${owner}&id=eq.${tail[0]}` : owner);
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

const publicMessage = (r: any) => ({
  id: r.id, clientId: r.client_id, role: r.role, content: r.content, meta: r.meta ?? {}, createdAt: r.created_at,
});

function messageRow(userId: string, m: any) {
  if (!isObject(m) || !isUuid(m.clientId) || !['user', 'assistant'].includes(m.role)
      || typeof m.content !== 'string' || m.content.length > MAX_TEXT_CHARS) throw fail('invalid_message', 400);
  const meta = isObject(m.meta) ? m.meta : {};
  if (JSON.stringify(meta).length > 20_000) throw fail('invalid_message', 400);
  // Always present: PostgREST bulk upserts write NULL for a key missing from any row, and created_at is NOT NULL.
  const created = typeof m.createdAt === 'string' && Number.isFinite(Date.parse(m.createdAt)) ? m.createdAt : new Date().toISOString();
  return { user_id: userId, client_id: m.clientId, role: m.role, content: m.content, meta, created_at: created };
}

async function messagesRoute(req: Request, userId: string, { rest }: Deps): Promise<Response> {
  const owner = `user_id=eq.${userId}`;
  if (req.method === 'GET') {
    const asked = Number(new URL(req.url).searchParams.get('limit') ?? 60);
    const limit = Number.isFinite(asked) ? Math.max(1, Math.min(200, Math.trunc(asked))) : 60;
    const rows = await rest.select('coach_messages',
      `${owner}&order=created_at.desc,id.desc&limit=${limit}&select=id,client_id,role,content,meta,created_at`);
    return Response.json({ messages: rows.map(publicMessage).reverse() });
  }
  if (req.method === 'POST') {
    const body = await readJson(req);
    if (!Array.isArray(body?.messages) || !body.messages.length || body.messages.length > 40) throw fail('invalid_message', 400);
    const rows = body.messages.map((m: any) => messageRow(userId, m));
    await rest.upsert('coach_messages', rows, { onConflict: 'user_id,client_id', prefer: 'resolution=merge-duplicates,return=minimal' });
    const stale = await rest.select('coach_messages', `${owner}&order=created_at.desc,id.desc&offset=${MAX_STORED_MESSAGES}&limit=200&select=id`);
    if (stale.length) await rest.delete('coach_messages', `${owner}&id=in.(${stale.map((r: any) => r.id).join(',')})`);
    return Response.json({ saved: rows.length });
  }
  if (req.method === 'DELETE') {
    await rest.delete('coach_messages', owner);
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

const PROFILE_SEXES = new Set(['male', 'female', 'nonbinary']);
const PROFILE_COLUMNS = 'display_name,date_of_birth,sex_model,height_cm,weight_kg,timezone,updated_at';

export function ageOn(dob: string, now: Date): number {
  const [y, m, d] = dob.split('-').map(Number);
  const birthdayPassed = now.getUTCMonth() + 1 > m || (now.getUTCMonth() + 1 === m && now.getUTCDate() >= d);
  return now.getUTCFullYear() - y - (birthdayPassed ? 0 : 1);
}

function profileNumber(v: unknown, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max) throw fail('invalid_profile', 400);
  return v;
}

/** Only the keys the client sent are written, so a partial update never blanks the rest of the row. */
function profileInput(body: any): Record<string, unknown> {
  if (!isObject(body)) throw fail('invalid_profile', 400);
  const row: Record<string, unknown> = {};
  if ('displayName' in body) {
    const name = typeof body.displayName === 'string' ? body.displayName.trim() : '';
    if (typeof body.displayName !== 'string' || name.length > 80) throw fail('invalid_profile', 400);
    row.display_name = name;
  }
  if ('dateOfBirth' in body) {
    const dob = body.dateOfBirth;
    const t = typeof dob === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(dob) ? Date.parse(`${dob}T00:00:00Z`) : NaN;
    // The round trip rejects dates the parser silently rolls over (2026-02-31).
    if (!Number.isFinite(t) || new Date(t).toISOString().slice(0, 10) !== dob || dob < '1900-01-01' || t > Date.now()) {
      throw fail('invalid_profile', 400);
    }
    row.date_of_birth = dob;
    // The Kotlin scorer reads age from `reported_age_years` (CHECK 18..90) rather than the birth date.
    // Outside that range the column is cleared so a stale age can never outlive the date it came from.
    const age = ageOn(dob, new Date());
    row.reported_age_years = age >= 18 && age <= 90 ? age : null;
  }
  if ('sex' in body) {
    if (typeof body.sex !== 'string' || !PROFILE_SEXES.has(body.sex)) throw fail('invalid_profile', 400);
    row.sex_model = body.sex;
  }
  if ('heightCm' in body) row.height_cm = profileNumber(body.heightCm, 50, 260);
  if ('weightKg' in body) row.weight_kg = profileNumber(body.weightKg, 20, 350);
  if ('timezone' in body) {
    // The phone's local IANA zone is the day/time authority (spec G1/C2). Null is accepted as
    // no-change; a string must be a plausible IANA id — the database's scoring_record_timezone
    // trigger is the authority that rejects unknown ids against pg_timezone_names, surfaced
    // by the route as a 400.
    if (body.timezone == null) {
      // no-change
    } else if (typeof body.timezone !== 'string') {
      throw fail('invalid_profile', 400);
    } else {
      const zone = body.timezone.trim();
      if (zone.length < 1 || zone.length > 64 || !/^[A-Za-z0-9_+/-]{1,64}$/.test(zone)) {
        throw fail('invalid_profile', 400);
      }
      row.timezone = zone;
    }
  }
  if (!Object.keys(row).length) throw fail('invalid_profile', 400);
  return row;
}

/** null until the owner has saved something: the row exists from sign-up with every field empty. */
function publicProfile(r: any) {
  if (!r || (!r.display_name && r.date_of_birth == null && r.sex_model == null && r.height_cm == null
      && r.weight_kg == null && r.timezone == null)) return null;
  const num = (v: unknown) => (v == null ? null : Number(v));
  return {
    displayName: r.display_name ?? '', dateOfBirth: r.date_of_birth ?? null, sex: r.sex_model ?? null,
    heightCm: num(r.height_cm), weightKg: num(r.weight_kg),
    timezone: r.timezone ?? null, updatedAt: r.updated_at ?? null,
  };
}

// The same `profiles` row the scoring worker reads for age, sex and body size, so what the owner enters in
// Settings is also what server-side scoring uses. Its update trigger re-queues scoring only when one of
// those values actually changes.
async function profileRoute(req: Request, userId: string, { rest }: Deps): Promise<Response> {
  if (req.method === 'GET') {
    const [row] = await rest.select('profiles', `id=eq.${userId}&select=${PROFILE_COLUMNS}`);
    return Response.json({ profile: publicProfile(row) });
  }
  if (req.method === 'PUT') {
    const row = profileInput(await readJson(req));
    let saved: any;
    try {
      [saved] = await rest.upsert('profiles', { id: userId, ...row, updated_at: new Date().toISOString() }, { onConflict: 'id' });
    } catch (err: any) {
      // The profiles.timezone trigger (scoring_record_timezone, 20260918050000) rejects unknown
      // zones against pg_timezone_names; surface that authority's rejection as a 400.
      if (/timezone/i.test(String(err?.message ?? ''))) throw fail('invalid_profile', 400);
      throw err;
    }
    return Response.json({ profile: publicProfile(saved) });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

interface Deps { rest: SupabaseRest; cfg: CoachConfig; fetchImpl: typeof fetch }

/** Runs after the answer has streamed. `route_only` returns just the routing decision so the app can show its placeholder. */
async function visualRoute(req: Request, userId: string, { rest, cfg, fetchImpl }: Deps): Promise<Response> {
  if (!cfg.fireworksKey) return Response.json({ error: 'coach_unconfigured' }, { status: 503 });
  const request = parseVisualRequest(await readJson(req));
  if (!request) throw fail('invalid_visual_request', 400);
  // One unit per visual request, however many model calls the pipeline makes.
  if (!(await rest.rpc('coach_take_quota', { p_user_id: userId, p_limit: cfg.dailyCallLimit }))) {
    return Response.json({ error: 'daily_limit' }, { status: 429 });
  }
  const deps: VisualDeps = {
    jevKey: cfg.jevKey || undefined,
    fetchImpl,
    callModel: async (body, timeoutMs) => {
      const res = await fetchImpl(cfg.upstreamUrl, {
        method: 'POST',
        headers: { authorization: `Bearer ${cfg.fireworksKey}`, 'content-type': 'application/json' },
        signal: AbortSignal.timeout(timeoutMs),
        body: JSON.stringify({ model: cfg.models.chat, stream: false, ...body }),
      });
      if (!res.ok) { await res.body?.cancel(); throw new Error(`upstream_${res.status}`); }
      return res.json();
    },
  };
  const route = request.route ?? await routeVisual(deps, request.question, request.answer);
  if (!route) return Response.json({ visual: null, outcome: 'not_routed' });
  if (request.routeOnly) return Response.json({ visual: null, outcome: 'routed', route });
  try {
    const { viz, audit, stats } = await produceVisual(deps, { question: request.question, answer: request.answer, evidence: request.evidence, route });
    return Response.json({ visual: viz, outcome: viz ? 'visual' : audit, kind: route.kind, audit, stats });
  } catch {
    return Response.json({ visual: null, outcome: 'error' });
  }
}

export async function handleCoachRequest(req: Request, deps: { rest: SupabaseRest; cfg: CoachConfig; fetchImpl?: typeof fetch }): Promise<Response> {
  const d: Deps = { ...deps, fetchImpl: deps.fetchImpl ?? fetch };
  try {
    const identity = await resolveUploadIdentity({
      headers: req.headers, rest: d.rest, allowLegacyFleetUploads: d.cfg.allowLegacyFleetUploads,
      allowLegacyEnrollment: d.cfg.allowLegacyEnrollment === true,
    });
    if (identity.authMode !== 'installation') throw new IdentityError('installation authorization required');
    const tail = new URL(req.url).pathname.replace(/^.*\/coach(?=\/|$)/, '').split('/').filter(Boolean);
    const [route, ...sub] = tail;
    if (route === 'status' && req.method === 'GET') {
      return Response.json({ ok: true, configured: Boolean(d.cfg.fireworksKey), dailyCallLimit: d.cfg.dailyCallLimit });
    }
    if (route === 'chat' && req.method === 'POST') return await chat(req, identity.id, d);
    if (route === 'visual' && req.method === 'POST') return await visualRoute(req, identity.id, d);
    if (route === 'memories') return await memoriesRoute(req, identity.id, sub, d);
    if (route === 'messages') return await messagesRoute(req, identity.id, d);
    if (route === 'profile') return await profileRoute(req, identity.id, d);
    return Response.json({ error: 'not_found' }, { status: 404 });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: err.code }, { status: err.status || 401 });
    if (err?.code && err?.status) return Response.json({ error: err.code }, { status: err.status });
    // Provider and database failures stay out of the response: they can carry prompt or row content.
    return Response.json({ error: 'coach_unavailable' }, { status: 502 });
  }
}
