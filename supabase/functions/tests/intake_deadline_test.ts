import assert from 'node:assert/strict';
import { createS3 } from '../_shared/s3.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
import { boundedIntakeClients, INTAKE_ATTEMPT_BUDGET_MS, INTAKE_REPORT_BUDGET_MS } from '../_shared/intakeConsumer.ts';

Deno.test('intake deadline cancels actual slow object body and subsequent requests in the same attempt', async () => {
  let cancelled = false;
  let requests = 0;
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, (req) => {
    requests++;
    if (req.method === 'HEAD') return new Response(null, { headers: { 'content-length': '1' } });
    if (req.method === 'PUT') return new Response('<CopyObjectResult><ETag>x</ETag></CopyObjectResult>');
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array([1])); },
      cancel() { cancelled = true; },
    }));
  });
  const origin = `http://127.0.0.1:${server.addr.port}`;
  const raw = createS3({ endpoint: origin, bucket: 'fixture', region: 'fixture', accessKeyId: 'fixture', secretAccessKey: 'fixture' });
  const rest = createSupabaseRest({ cfg: { supabaseUrl: origin, supabaseServiceRoleKey: 'fixture' } });
  const signal = AbortSignal.timeout(100);
  const bounded = boundedIntakeClients(rest, raw, signal);
  try {
    assert.equal((await bounded.raw.head('upload'))?.contentLength, 1);
    await bounded.raw.copyObject('upload', 'verified');
    const response = await bounded.raw.getObjectStream('verified');
    assert.ok(response);
    // Receiving headers cannot reset the attempt deadline while the body stalls.
    await assert.rejects(response.arrayBuffer(), /abort|timeout/i);
    const before = requests;
    await assert.rejects(bounded.raw.head('other'));
    await assert.rejects(bounded.rest.rpc('must_not_publish', {}));
    assert.equal(requests, before);
    for (let n = 0; n < 20 && !cancelled; n++) await new Promise(r => setTimeout(r, 5));
    assert.ok(cancelled, 'the stream is cancelled, not abandoned behind a Promise.race');
  } finally { await server.shutdown(); }
});

Deno.test('intake whole-attempt and report budgets fit the actual unchanged canary evaluator', async () => {
  const script = `
import importlib.util, pathlib, sys
path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('guard_tests', path)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
attempt, report = int(sys.argv[2])/1000, int(sys.argv[3])/1000
assert attempt + report + 1 < t.POLICY['maximumLaneAgeSeconds']
state = t.status()
# There is no fabricated completion during an in-flight operation.
state['captured_at'] = t.timestamp(t.NOW + attempt + report + 1)
t.guard.Evaluator(t.POLICY, 0).evaluate(state, t.resources(), t.binding(), t.NOW + attempt + report + 1, 90)
state['captured_at'] = t.timestamp(t.NOW + 31)
try:
    t.guard.Evaluator(t.POLICY, 0).evaluate(state, t.resources(), t.binding(), t.NOW + 31, 95)
except ValueError as e:
    assert 'lane_stale' in str(e)
else:
    raise AssertionError('stalled lane incorrectly passed')
`;
  const guardTests = new URL('../../../infra/vps/scripts/test-scoped-canary-guard.py', import.meta.url);
  const result = await new Deno.Command('python3', { args: ['-c', script, decodeURIComponent(guardTests.pathname),
    String(INTAKE_ATTEMPT_BUDGET_MS), String(INTAKE_REPORT_BUDGET_MS)] }).output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
});
