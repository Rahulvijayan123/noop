// In-app coach backend: an authenticated model relay plus the coach's conversation and memory store.
//
// The harness (system prompt, tool loop, tools over the owner's local data) runs on the phone; this
// function is the part that must not: it holds the model provider key, picks the model for each mode,
// bounds every request, meters usage per owner, runs the visual pipeline, and persists memory and history.
//
// This module is the router plus the model relay, the visual route and the profile. Threads, folders and
// messages live in coach_store.ts, memories in coach_memory.ts, the context library and recall in
// coach_context.ts, and the cheap-model side calls (titles, follow-ups, starters, maintenance) in
// coach_curator.ts (docs/COACH_MEMORY.md).
import { IdentityError, resolveUploadIdentity } from './tokens.ts';
import type { SupabaseRest } from './rest.ts';
import { parseVisualRequest, produceVisual, routeVisual, type VisualDeps } from './coach_visual.ts';
import { type CoachDeps, fail, isObject, readJson } from './coach_llm.ts';
import { foldersRoute, messagesRoute, threadsRoute } from './coach_store.ts';
import { memoriesRoute } from './coach_memory.ts';
import { contextRoute } from './coach_context.ts';
import { followupsRoute, maintainRoute, suggestionsRoute, titleRoute } from './coach_curator.ts';

export type CoachMode = 'chat' | 'vision';

export interface CoachConfig {
  fireworksKey: string;
  upstreamUrl: string;
  /** `utility` is the cheap JSON model for titles, follow-ups, starters, summaries, curation and recall. */
  models: Record<CoachMode | 'utility', string>;
  dailyCallLimit: number;
  /** COACH_UTILITY_API_KEY, else the chat key. */
  utilityKey: string;
  /** `reasoning_effort` for utility passes; '' leaves the parameter out. */
  utilityReasoning: string;
  /** Cheap-model calls per owner per UTC day (its own budget, never the chat quota). */
  dailyUtilityLimit: number;
  allowLegacyFleetUploads: boolean;
  allowLegacyEnrollment?: boolean;
  jevKey: string;
  /**
   * COACH_THREADS_DISABLED=1: the rollback switch. GET status stops advertising `features`, so thread-aware apps
   * fall back to single-thread behaviour, while every data rule (50,000-message retention, 200 active memories,
   * retired rows hidden, forget tombstones) stays as it is. Redeploying an older function would not keep them.
   */
  threadsDisabled?: boolean;
}

export function coachConfig(env: Record<string, string | undefined> = Deno.env.toObject()): CoachConfig {
  const pick = (name: string, fallback: string) => (env[name] ?? '').trim() || fallback;
  const limit = Number(pick('COACH_DAILY_CALL_LIMIT', '400'));
  const utilityLimit = Number(pick('COACH_DAILY_UTILITY_LIMIT', '600'));
  const chatModel = pick('COACH_MODEL_CHAT', 'accounts/fireworks/models/deepseek-v4p1-flash');
  const fireworksKey = pick('FIREWORKS_AI_API_KEY', '');
  return {
    fireworksKey,
    upstreamUrl: pick('COACH_UPSTREAM_URL', 'https://api.fireworks.ai/inference/v1/chat/completions'),
    models: {
      chat: chatModel,
      vision: pick('COACH_MODEL_VISION', 'accounts/fireworks/models/qwen3p8-max'),
      utility: pick('COACH_MODEL_UTILITY', chatModel),
    },
    dailyCallLimit: Number.isFinite(limit) && limit > 0 ? Math.trunc(limit) : 400,
    utilityKey: pick('COACH_UTILITY_API_KEY', fireworksKey),
    // Unset means `none`; set but empty means the parameter is omitted (some models reject it).
    utilityReasoning: env.COACH_UTILITY_REASONING === undefined ? 'none' : env.COACH_UTILITY_REASONING.trim(),
    dailyUtilityLimit: Number.isFinite(utilityLimit) && utilityLimit > 0 ? Math.trunc(utilityLimit) : 600,
    allowLegacyFleetUploads: pick('NOOP_ALLOW_LEGACY_FLEET_UPLOADS', '').toLowerCase() === 'true',
    allowLegacyEnrollment: pick('NOOP_ALLOW_LEGACY_ENROLLMENT', '').toLowerCase() === 'true',
    jevKey: pick('TYPESAFE_API_KEY', ''),
    threadsDisabled: ['1', 'true'].includes(pick('COACH_THREADS_DISABLED', '').toLowerCase()),
  };
}

// Tool rounds ask for ~1200 tokens and the final answer round for up to 4096; the ceilings here bound a hostile client.
const MODES: Record<CoachMode, { maxTokens: number }> = {
  chat: { maxTokens: 4096 },
  vision: { maxTokens: 1200 },
};
// The harness picks the reasoning effort per round: none on tool rounds, low or high on the final answer.
const EFFORTS = new Set(['none', 'low', 'high']);

const MAX_IMAGE_BYTES = 4_500_000;
const MAX_TEXT_CHARS = 60_000;
const MAX_MESSAGES = 80;
const MAX_TOOLS = 24;
const TOOL_NAME = /^[A-Za-z0-9_]{1,64}$/;
const IMAGE_URL = /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/;

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

type Deps = CoachDeps;

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

/** `EdgeRuntime.waitUntil` when the platform provides it, so maintenance can finish after the 202. */
function edgeWaitUntil(): ((work: Promise<unknown>) => void) | null {
  const runtime = (globalThis as any).EdgeRuntime;
  return typeof runtime?.waitUntil === 'function' ? (work) => runtime.waitUntil(work) : null;
}

export interface CoachRequestDeps {
  rest: SupabaseRest;
  cfg: CoachConfig;
  fetchImpl?: typeof fetch;
  now?: () => number;
  /** Background runner for maintenance; null forces it inline (tests), undefined detects EdgeRuntime. */
  background?: ((work: Promise<unknown>) => void) | null;
  timeScale?: number;
}

export async function handleCoachRequest(req: Request, deps: CoachRequestDeps): Promise<Response> {
  const d: Deps = {
    rest: deps.rest, cfg: deps.cfg, fetchImpl: deps.fetchImpl ?? fetch, now: deps.now ?? Date.now,
    background: deps.background === undefined ? edgeWaitUntil() : deps.background,
    timeScale: deps.timeScale && deps.timeScale > 0 ? deps.timeScale : 1,
  };
  try {
    const identity = await resolveUploadIdentity({
      headers: req.headers, rest: d.rest, allowLegacyFleetUploads: d.cfg.allowLegacyFleetUploads,
      allowLegacyEnrollment: d.cfg.allowLegacyEnrollment === true,
    });
    if (identity.authMode !== 'installation') throw new IdentityError('installation authorization required');
    const tail = new URL(req.url).pathname.replace(/^.*\/coach(?=\/|$)/, '').split('/').filter(Boolean);
    const [route, ...sub] = tail;
    if (route === 'status' && req.method === 'GET') {
      // `features` tells a thread-aware app it may use threads and the context tools; old servers never send it,
      // and neither does this one while COACH_THREADS_DISABLED is set.
      return Response.json({
        ok: true, configured: Boolean(d.cfg.fireworksKey), dailyCallLimit: d.cfg.dailyCallLimit,
        ...(d.cfg.threadsDisabled ? {} : { features: { threads: 1, context: 1 } }),
      });
    }
    if (route === 'chat' && req.method === 'POST') return await chat(req, identity.id, d);
    if (route === 'visual' && req.method === 'POST') return await visualRoute(req, identity.id, d);
    if (route === 'memories') return await memoriesRoute(req, identity.id, sub, d);
    if (route === 'messages') return await messagesRoute(req, identity.id, d);
    if (route === 'threads' && sub.length === 2 && sub[1] === 'title' && req.method === 'POST') {
      return await titleRoute(req, identity.id, sub[0], d);
    }
    if (route === 'threads' && sub.length === 2 && sub[1] === 'maintain' && req.method === 'POST') {
      return await maintainRoute(req, identity.id, sub[0], d);
    }
    if (route === 'threads') return await threadsRoute(req, identity.id, sub, d);
    if (route === 'folders') return await foldersRoute(req, identity.id, sub, d);
    if (route === 'followups' && req.method === 'POST') return await followupsRoute(req, identity.id, d);
    if (route === 'suggestions' && req.method === 'POST') return await suggestionsRoute(req, identity.id, d);
    if (route === 'context') return await contextRoute(req, identity.id, sub, d);
    if (route === 'profile') return await profileRoute(req, identity.id, d);
    return Response.json({ error: 'not_found' }, { status: 404 });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: err.code }, { status: err.status || 401 });
    if (err?.code && err?.status) return Response.json({ error: err.code }, { status: err.status });
    // Provider and database failures stay out of the response: they can carry prompt or row content.
    return Response.json({ error: 'coach_unavailable' }, { status: 502 });
  }
}
