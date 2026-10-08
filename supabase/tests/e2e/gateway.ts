// One origin in front of the disposable end-to-end stack, so the app (and the tests) see a single Supabase-shaped
// base URL: /functions/v1/{push,scores,coach} -> the unmodified Edge functions running under Deno, /auth/v1 and /rest/v1
// -> the local Kong gateway (GoTrue and PostgREST), plus two test-only routes:
//
//   GET /__e2e/mail?to=<address>&since=<epoch ms>   the emails the Auth service handed to the SMTP sink, newest
//                                                   last, each with the numeric code found in its body
//   GET /__e2e/objects                              what the in-memory object store holds
//
// A second listener is a minimal in-memory, path-style S3 stand-in for the raw object store the push function
// archives to (Backblaze B2 in production). It accepts any credentials; it exists only so the real push code
// path, including its durability verification, runs without cloud storage.
//
// Developer machines only. It binds to loopback and adds no authentication of its own.

const env = (name: string, fallback = '') => Deno.env.get(name) ?? fallback;
const gatewayPort = Number(env('E2E_GATEWAY_PORT', '54431'));
const s3Port = Number(env('E2E_S3_PORT', '54432'));
const kong = env('E2E_KONG_URL');
const pushUrl = env('E2E_PUSH_URL');
const scoresUrl = env('E2E_SCORES_URL');
const coachUrl = env('E2E_COACH_URL');
const mailDir = env('E2E_MAIL_DIR');

const HOP = ['connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'host', 'content-length'];

async function forward(req: Request, base: string): Promise<Response> {
  const incoming = new URL(req.url);
  const target = new URL(incoming.pathname + incoming.search, base);
  const headers = new Headers(req.headers);
  for (const name of HOP) headers.delete(name);
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  const upstream = await fetch(target, {
    method: req.method,
    headers,
    body: hasBody ? req.body : undefined,
    redirect: 'manual',
    // @ts-ignore Deno accepts `duplex` for streamed request bodies.
    duplex: 'half',
  });
  const out = new Headers(upstream.headers);
  // Deno's fetch has already decoded the body; the client must not decode it a second time.
  for (const name of [...HOP, 'content-encoding']) out.delete(name);
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
}

function codeFrom(message: { text?: string; html?: string }): string | null {
  const strip = (message.html ?? '').replace(/<[^>]*>/g, ' ');
  for (const source of [message.text ?? '', strip]) {
    const hit = /(?<![\w.])(\d{6,10})(?![\w.])/.exec(source);
    if (hit) return hit[1];
  }
  return null;
}

async function mail(url: URL): Promise<Response> {
  const to = (url.searchParams.get('to') ?? '').trim().toLowerCase();
  const since = Number(url.searchParams.get('since') ?? 0);
  const files: string[] = [];
  try {
    for await (const entry of Deno.readDir(mailDir)) if (entry.name.endsWith('.json')) files.push(entry.name);
  } catch { /* nothing delivered yet */ }
  files.sort();
  const messages = [];
  for (const name of files) {
    try {
      const m = JSON.parse(await Deno.readTextFile(`${mailDir}/${name}`));
      const recipients: string[] = (m.to ?? []).map((r: string) => r.toLowerCase());
      if (to && !recipients.includes(to)) continue;
      if (Math.round(m.receivedAt * 1000) < since) continue;
      messages.push({
        file: name,
        to: recipients,
        subject: m.subject,
        receivedAt: Math.round(m.receivedAt * 1000),
        code: codeFrom(m),
        text: m.text,
      });
    } catch { /* a half-written file; the next poll sees it */ }
  }
  return Response.json({ messages });
}

const objects = new Map<string, { body: Uint8Array; type: string; etag: string }>();

async function etagOf(body: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', body as BufferSource));
  return '"' + [...digest.slice(0, 16)].map((b) => b.toString(16).padStart(2, '0')).join('') + '"';
}

async function objectStore(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const parts = url.pathname.split('/').filter(Boolean);
  const key = decodeURIComponent(parts.slice(1).join('/'));
  if (!key) {
    return new Response(
      '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>',
      { headers: { 'content-type': 'application/xml' } },
    );
  }
  if (req.method === 'PUT') {
    const copySource = req.headers.get('x-amz-copy-source');
    if (copySource) {
      const from = decodeURIComponent(copySource.replace(/^\/?[^/]+\//, ''));
      const found = objects.get(from);
      if (!found) return new Response('<Error><Code>NoSuchKey</Code></Error>', { status: 404 });
      objects.set(key, { ...found });
      return new Response('<CopyObjectResult><ETag>' + found.etag + '</ETag></CopyObjectResult>', {
        headers: { 'content-type': 'application/xml' },
      });
    }
    const body = new Uint8Array(await req.arrayBuffer());
    const etag = await etagOf(body);
    objects.set(key, { body, type: req.headers.get('content-type') ?? 'application/octet-stream', etag });
    return new Response(null, { status: 200, headers: { etag } });
  }
  const found = objects.get(key);
  if (req.method === 'DELETE') {
    objects.delete(key);
    return new Response(null, { status: found ? 204 : 404 });
  }
  if (!found) return new Response('<Error><Code>NoSuchKey</Code></Error>', { status: 404 });
  const headers = { 'content-type': found.type, etag: found.etag, 'content-length': String(found.body.length) };
  if (req.method === 'HEAD') return new Response(null, { status: 200, headers });
  return new Response(found.body as BodyInit, { status: 200, headers });
}

Deno.serve({ hostname: '127.0.0.1', port: s3Port, onListen: () => {} }, objectStore);

Deno.serve({ hostname: '127.0.0.1', port: gatewayPort, onListen: () => {} }, async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  try {
    if (path === '/__e2e/health') return Response.json({ ok: true });
    if (path === '/__e2e/mail') return await mail(url);
    if (path === '/__e2e/objects') {
      return Response.json({ count: objects.size, keys: [...objects.keys()].sort() });
    }
    if (path === '/functions/v1/push' || path.startsWith('/functions/v1/push/')) return await forward(req, pushUrl);
    if (path === '/functions/v1/scores' || path.startsWith('/functions/v1/scores/')) {
      return await forward(req, scoresUrl);
    }
    if (coachUrl && (path === '/functions/v1/coach' || path.startsWith('/functions/v1/coach/'))) {
      return await forward(req, coachUrl);
    }
    if (path.startsWith('/auth/v1/') || path.startsWith('/rest/v1/')) return await forward(req, kong);
    return new Response('not found', { status: 404 });
  } catch (error) {
    return Response.json({ error: 'gateway_upstream_failure', detail: String(error) }, { status: 502 });
  }
});
