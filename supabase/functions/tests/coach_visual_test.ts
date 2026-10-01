import { assert, assertEquals } from 'jsr:@std/assert';
import { coachConfig, handleCoachRequest } from '../_shared/coach.ts';
import {
  axisIssues, correctnessIssues, parseVisualization, planTypes, produceVisual, routeVisual, type VisualDeps,
} from '../_shared/coach_visual.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const ANSWER = 'Your HRV climbed from 52 ms on Mar 3 to 61 ms on Mar 10 and 66 ms on Mar 17, so recovery is trending up.';
const DATA = 'HRV Mar 3: 52 ms\nHRV Mar 10: 61 ms\nHRV Mar 17: 66 ms';

const line = (over: Record<string, unknown> = {}) => ({
  type: 'line', title: 'HRV by week', yLabel: 'HRV (ms)', xLabel: 'Date', source: 'Apple Health',
  data: [{ label: 'Mar 3', value: 52 }, { label: 'Mar 10', value: 61 }, { label: 'Mar 17', value: 66 }], ...over,
});
const toolReply = (args: unknown, name = 'visualize_data') => ({
  choices: [{ message: { content: '', tool_calls: [{ id: 'c1', type: 'function', function: { name, arguments: JSON.stringify(args) } }] } }],
});
const verdict = (ok: boolean, issues: string[] = []) => ({ choices: [{ message: { content: JSON.stringify({ ok, issues }) } }] });

/** Scripted model: each call consumes the next reply and records the request body. */
function script(...replies: unknown[]): VisualDeps & { calls: any[] } {
  const calls: any[] = [];
  return {
    calls,
    callModel: async (body) => {
      calls.push(body);
      const next = replies.shift();
      if (next instanceof Error) throw next;
      return next;
    },
  };
}

Deno.test('visual spec: normalises a chart and rejects figures the source never states', () => {
  const parsed = parseVisualization('visualize_data', line());
  assert(parsed.ok);
  if (!parsed.ok) return;
  assertEquals(parsed.viz.points[0], { x: 'Mar 3', y: 52 });
  assertEquals(correctnessIssues(parsed.viz, `${ANSWER}\n${DATA}`), []);
  const invented = parseVisualization('visualize_data', line({ data: [{ label: 'Mar 3', value: 52 }, { label: 'Mar 10', value: 73 }] }));
  assert(invented.ok);
  if (invented.ok) assert(correctnessIssues(invented.viz, `${ANSWER}\n${DATA}`).some((i) => i.includes('73')));
});

Deno.test('visual spec: axis rules catch missing units, reversed time, wide bars and zero-based negatives', () => {
  const make = (over: Record<string, unknown>) => {
    const parsed = parseVisualization('visualize_data', line(over));
    if (!parsed.ok) throw new Error(parsed.issues.join());
    return parsed.viz;
  };
  assertEquals(axisIssues(make({})), []);
  assert(axisIssues(make({ yLabel: 'HRV' })).some((i) => i.includes('no unit')));
  assert(axisIssues(make({ data: [{ label: 'Mar 17', value: 66 }, { label: 'Mar 10', value: 61 }, { label: 'Mar 3', value: 52 }] })).some((i) => i.includes('oldest to newest')));
  const many = Array.from({ length: 9 }, (_, i) => ({ label: `L${i}`, value: i + 2 }));
  assert(axisIssues(make({ type: 'bar', xLabel: 'Lift', data: many })).some((i) => i.includes('vertical bars')));
  assert(axisIssues(make({ type: 'bar', xLabel: 'Lift', data: [{ label: 'A', value: -2 }, { label: 'B', value: 3 }] })).some((i) => i.includes('negative')));
});

Deno.test('visual route: kind families, and a confident Jev none stops without a fallback call', async () => {
  assertEquals(planTypes('trend_chart', null), ['line', 'area']);
  assertEquals(planTypes('kpi_facts', null), ['facts']);

  const model = script({ choices: [{ message: { content: '{"kind":"trend_chart"}' } }] });
  assertEquals(await routeVisual(model, 'How is my HRV?', ANSWER), { kind: 'trend_chart', types: ['line', 'area'], routedBy: 'chat_model' });
  assertEquals(await routeVisual(script({ choices: [{ message: { content: '{"kind":"none"}' } }] }), 'hi', ANSWER), null);
  assertEquals(await routeVisual(script(new Error('down')), 'hi', ANSWER), null);

  const jev = script();
  const jevDeps = { ...jev, jevKey: 'jev', fetchImpl: (async () => Response.json({ answers: { visual: { choice: 'none', probabilities: { none: 0.9 } } } })) as typeof fetch };
  assertEquals(await routeVisual(jevDeps, 'hi', ANSWER), null);
  assertEquals(jev.calls.length, 0);
});

Deno.test('visual pipeline: design, fact-check and ship', async () => {
  const model = script(toolReply(line()), verdict(true));
  const out = await produceVisual(model, { question: 'How is my HRV?', answer: ANSWER, evidence: DATA, route: { kind: 'trend_chart', types: ['line', 'area'] } });
  assertEquals(out.audit, 'passed');
  assertEquals(out.viz.type, 'line');
  assertEquals(out.stats.design_calls, 1);
  assertEquals(model.calls[0].tool_choice, 'required');
  assert(model.calls[1].messages[1].content.includes('"Mar 17"'));
});

Deno.test('visual pipeline: bad designs go back to the model, a failed fact-check redesigns once, and the check is fail-closed', async () => {
  const unitless = script(toolReply(line({ yLabel: 'HRV' })), toolReply(line()), verdict(true));
  const fixed = await produceVisual(unitless, { question: 'q', answer: ANSWER, evidence: DATA, route: { kind: 'trend_chart', types: ['line'] } });
  assertEquals(fixed.audit, 'passed');
  assert(unitless.calls[1].messages.some((m: any) => m.role === 'tool' && m.content.includes('no unit')));

  const redesigned = script(toolReply(line()), verdict(false, ['wrong']), toolReply(line()), verdict(true));
  const second = await produceVisual(redesigned, { question: 'q', answer: ANSWER, evidence: DATA, route: { kind: 'trend_chart', types: ['line'] } });
  assertEquals([second.audit, second.stats.redesigns], ['passed', 1]);

  const unreadable = script(toolReply(line()), { choices: [{ message: { content: 'not json' } }] }, toolReply(line()), new Error('boom'));
  const dropped = await produceVisual(unreadable, { question: 'q', answer: ANSWER, evidence: DATA, route: { kind: 'trend_chart', types: ['line'] } });
  assertEquals([dropped.viz, dropped.audit], [null, 'rejected']);
});

Deno.test('visual pipeline: pure text cards skip the fact-check call', async () => {
  const model = script(toolReply({
    type: 'alerts', title: 'Watch these', alerts: [{ tone: 'warning', title: 'Sharp pain means stop' }],
  }, 'present_cards'));
  const out = await produceVisual(model, { question: 'q', answer: ANSWER, evidence: '', route: { kind: 'risk_alerts', types: ['alerts'] } });
  assertEquals(out.audit, 'deterministic_pass');
  assertEquals(model.calls.length, 1);
});

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

const USER = '11111111-1111-4111-8111-111111111111';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-test-key', COACH_DAILY_CALL_LIMIT: '2' });

async function handlerFixture() {
  const base = makeMemRest() as any;
  await base.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', user_id: USER, source_id: SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await base.upsert('noop_app_installations', [{ user_id: USER, source_id: SOURCE }]);
  let used = 0;
  return { ...base, rpc: async () => ++used <= 2 } as any;
}

const visualRequest = (body: unknown) => new Request('https://test.invalid/functions/v1/coach/visual', {
  method: 'POST', body: JSON.stringify(body),
  headers: { authorization: 'Bearer noop_personal', 'x-noop-fleet-token': 'noop_fleet', 'content-type': 'application/json' },
});

Deno.test('coach visual route: validates, meters, routes, and draws through the relay', async () => {
  const rest = await handlerFixture();
  const replies: unknown[] = [
    { choices: [{ message: { content: '{"kind":"trend_chart"}' } }] },
    toolReply(line()), verdict(true),
  ];
  const seen: any[] = [];
  const fetchImpl = (async (_url: string, init: any) => {
    seen.push(JSON.parse(init.body));
    return Response.json(replies.shift());
  }) as typeof fetch;
  const send = (body: unknown) => handleCoachRequest(visualRequest(body), { rest, cfg, fetchImpl });

  assertEquals((await send({ question: 'q', answer: 'short' })).status, 400);
  assertEquals(seen.length, 0);

  const routed = await (await send({ question: 'How is my HRV?', answer: ANSWER, route_only: true })).json();
  assertEquals(routed.outcome, 'routed');
  assertEquals(routed.route.types, ['line', 'area']);
  assertEquals(seen[0].model, cfg.models.chat);

  const drawn = await (await send({ question: 'How is my HRV?', answer: ANSWER, evidence: DATA, route: routed.route })).json();
  assertEquals(drawn.outcome, 'visual');
  assertEquals(drawn.visual.points.length, 3);
  assertEquals(seen.length, 3);

  assertEquals((await send({ question: 'q', answer: ANSWER, route_only: true })).status, 429);
});
