import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { createS3 } from '../_shared/s3.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
import { createIntakeConsumer, INTAKE_ATTEMPT_BUDGET_MS, INTAKE_REPORT_BUDGET_MS } from '../_shared/intakeConsumer.ts';
import { verifyStoredObject } from '../_shared/durability.ts';
import { PushProtocolError } from '../_shared/registry.ts';

// Independent review: exercise the real consumer, reconciler, signed HTTP client,
// decompressor and cancellation path, not only the bounded-client adapter.
Deno.test('a real timed-out projection settles retry debt and reports a completed failed poll within supervision', async () => {
  const owner = '22222222-2222-4222-8222-222222222222';
  const device = '33333333-3333-4333-8333-333333333333';
  const object = '44444444-4444-4444-8444-444444444444';
  const lease = '55555555-5555-4555-8555-555555555555';
  const requests: string[] = [];
  const reports: Record<string, unknown>[] = [];
  let cancelled = false;
  const manifest = {
    id: object, user_id: owner, device_id: device, format: 'ndjson', compression: 'gzip', object_key: 'retained.gz',
    durability_receipt: { version: 1, state: 'verified_indexed', objectId: object, ownerUserId: owner,
      deviceId: device, objectKey: 'retained.gz', uncompressedBytes: 400, compressedBytes: 300,
      wireSha256: 'a'.repeat(64), contentSha256: 'b'.repeat(64) },
  };
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, async req => {
    const path = new URL(req.url).pathname;
    requests.push(path);
    if (path.endsWith('/noop_seed_projection_debt_scoped')) return Response.json(1);
    if (path.endsWith('/noop_claim_projection_debt_scoped')) return Response.json({ manifest, leaseToken: lease });
    if (path.endsWith('/noop_fail_projection_debt')) return Response.json(true);
    if (path.endsWith('/noop_intake_consumer_poll_v2')) { reports.push(await req.json()); return Response.json(true); }
    if (path === '/fixture/retained.gz') return new Response(new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(gzipSync('incomplete projection archive').subarray(0, 10)); },
      cancel() { cancelled = true; },
    }));
    return new Response('unexpected fixture request', { status: 500 });
  });
  const endpoint = `http://127.0.0.1:${server.addr.port}`;
  const consumer = createIntakeConsumer(
    createSupabaseRest({ cfg: { supabaseUrl: endpoint, supabaseServiceRoleKey: 'synthetic-only' } }),
    createS3({ endpoint, bucket: 'fixture', region: 'fixture', accessKeyId: 'fixture', secretAccessKey: 'fixture' }),
    { processId: crypto.randomUUID(), instanceId: crypto.randomUUID(), sourceRevision: 'a'.repeat(40),
      admission: { mode: 'canary', ownerId: owner, deviceId: device } });
  const started = performance.now();
  let error: unknown;
  try {
    try { await consumer.poll('projection'); } catch (caught) { error = caught; }
    const elapsed = performance.now() - started;
    for (let n = 0; n < 20 && !cancelled; n++) await new Promise(resolve => setTimeout(resolve, 5));
    assert.ok(cancelled, 'timed-out raw read must actually cancel the stream');
    assert.ok(elapsed >= INTAKE_ATTEMPT_BUDGET_MS - 500 && elapsed < 28_000, `unbounded projection: ${elapsed} ms`);
    assert.equal(error, undefined, `bounded failure escaped without lane settlement/report: ${String(error)}`);
    assert.equal(requests.filter(path => path.endsWith('/noop_fail_projection_debt')).length, 1);
    assert.equal(reports.length, 1);
    assert.equal(reports[0].p_claimed, 1);
    assert.equal(reports[0].p_completed, 0);
    assert.equal(reports[0].p_failures, 1);
  } finally { await server.shutdown(); }
});

Deno.test('verification timeout has one finite cleanup budget and cannot publish or fabricate a failed-cleanup poll', async () => {
  const outcomes = await Promise.allSettled([false, true].map(async stallCleanup => {
    const owner = '66666666-6666-4666-8666-666666666666';
    const device = '77777777-7777-4777-8777-777777777777';
    const object = '88888888-8888-4888-8888-888888888888';
    const lease = '99999999-9999-4999-8999-999999999999';
    const requests: string[] = [];
    const reports: Record<string, unknown>[] = [];
    const settlements: Record<string, unknown>[] = [];
    let rawCancelled = false;
    let cleanupCancelled = false;
    const row = { id: object, user_id: owner, device_id: device, status: 'pending',
      object_key: 'upload.gz', upload_object_key: 'upload.gz', compression: 'gzip',
      compressed_bytes: 300, uncompressed_bytes: 400, sha256: 'a'.repeat(64), format: 'binary' };
    const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, async req => {
      const path = new URL(req.url).pathname;
      requests.push(path);
      if (path.endsWith('/noop_claim_object_verification_scoped')) return Response.json({ manifest: row, token: lease });
      if (path.endsWith('/noop_current_object_receipt')) return Response.json(null);
      if (path.endsWith('/devices')) return Response.json([{ id: device }]);
      if (path.endsWith('/noop_reserve_copy_intent')) return Response.json({ id: lease,
        lease_token: lease, upload_key: 'upload.gz', verified_key: 'verified.gz' });
      if (path.endsWith('/noop_abandon_copy_intent')) {
        if (stallCleanup) return new Response(new ReadableStream<Uint8Array>({
          start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
          cancel() { cleanupCancelled = true; },
        }), { headers: { 'content-type': 'application/json' } });
        return Response.json(true);
      }
      if (path.endsWith('/noop_finish_object_verification')) { settlements.push(await req.json()); return Response.json(true); }
      if (path.endsWith('/noop_intake_consumer_poll_v2')) { reports.push(await req.json()); return Response.json(true); }
      if (path.startsWith('/fixture/')) {
        if (req.method === 'HEAD') return new Response(null, { headers: { 'content-length': '300' } });
        if (req.method === 'PUT') return new Response('<CopyObjectResult><ETag>fixture</ETag></CopyObjectResult>');
        return new Response(new ReadableStream<Uint8Array>({
          start(controller) { controller.enqueue(gzipSync('retained fixture').subarray(0, 10)); },
          cancel() { rawCancelled = true; },
        }));
      }
      return new Response('unexpected fixture request', { status: 500 });
    });
    const endpoint = `http://127.0.0.1:${server.addr.port}`;
    const consumer = createIntakeConsumer(
      createSupabaseRest({ cfg: { supabaseUrl: endpoint, supabaseServiceRoleKey: 'synthetic-only' } }),
      createS3({ endpoint, bucket: 'fixture', region: 'fixture', accessKeyId: 'fixture', secretAccessKey: 'fixture' }),
      { processId: crypto.randomUUID(), instanceId: crypto.randomUUID(), sourceRevision: 'a'.repeat(40),
        admission: { mode: 'canary', ownerId: owner, deviceId: device } });
    const started = performance.now();
    let error: unknown;
    try {
      try { await consumer.poll('verification'); } catch (caught) { error = caught; }
      const elapsed = performance.now() - started;
      for (let n = 0; n < 20 && (!rawCancelled || (stallCleanup && !cleanupCancelled)); n++) {
        await new Promise(resolve => setTimeout(resolve, 5));
      }
      assert.ok(rawCancelled);
      assert.ok(elapsed < 28_000, `verification exceeded supervision budget: ${elapsed} ms`);
      assert.equal(requests.some(path => path.includes('commit_receipt') || path.includes('commit_projection')), false);
      if (stallCleanup) {
        assert.ok(error instanceof Error);
        assert.ok(cleanupCancelled, 'cleanup HTTP body must also be cancelled');
        assert.ok(elapsed >= INTAKE_ATTEMPT_BUDGET_MS + INTAKE_REPORT_BUDGET_MS - 500);
        assert.equal(settlements.length, 0, 'expired cleanup must not renew its budget for the next RPC');
        assert.equal(reports.length, 0, 'unsettled/failed cleanup is not a completed lane poll');
      } else {
        assert.equal(error, undefined);
        assert.equal(settlements.length, 1);
        assert.equal(settlements[0].p_object_id, object);
        assert.equal(settlements[0].p_lease_token, lease);
        assert.equal(settlements[0].p_failure_code, 'verification_failed');
        assert.equal(settlements[0].p_retryable, true);
        assert.equal(reports.length, 1);
        assert.equal(reports[0].p_claimed, 1);
        assert.equal(reports[0].p_completed, 0);
        assert.equal(reports[0].p_failures, 1);
      }
    } finally { await server.shutdown(); }
  }));
  for (const outcome of outcomes) if (outcome.status === 'rejected') throw outcome.reason;
});

Deno.test('raw transport errors are not corruption, while complete malformed gzip remains non-retryable', async () => {
  const row = { compressed_bytes: 300, uncompressed_bytes: 400, compression: 'gzip',
    format: 'binary', sha256: 'a'.repeat(64) };
  const transport = new TypeError('synthetic connection closed during raw body');
  const interrupted = { getObjectStream: async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(gzipSync('retained fixture').subarray(0, 10));
      queueMicrotask(() => controller.error(transport));
    },
  })) };
  await assert.rejects(verifyStoredObject(interrupted as any, row, 'same-immutable-key'), error => {
    assert.ok(!(error instanceof PushProtocolError) || error.status >= 500,
      'an interrupted response must remain retryable, not permanently pause verified source');
    return true;
  });
  const malformed = { getObjectStream: async () => new Response(new TextEncoder().encode('complete but not gzip')) };
  await assert.rejects(verifyStoredObject(malformed as any, row, 'same-immutable-key'), error => {
    assert.ok(error instanceof PushProtocolError);
    assert.equal(error.status, 409);
    assert.equal(error.code, 'invalid_compressed_object');
    return true;
  });
});
