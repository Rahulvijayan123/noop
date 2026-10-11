// The cheap-model side calls (docs/COACH_MEMORY.md §5): titles, follow-ups, starter suggestions, and per-thread
// maintenance (rolling summary + memory curation, then consolidation), over the in-memory fake and a scripted model.
import { assert, assertEquals } from 'jsr:@std/assert';
import {
  curatorLine, duplicatePairs, keywordFollowUps, maintenanceBatches, mergedAttributes, resolveConsolidationOps, resolveCuratorOps,
  validFollowUps,
} from '../_shared/coach_curator.ts';
import { day, iso, memoryTokens, Refs, tokenSet, validZone } from '../_shared/coach_llm.ts';
import { type Harness, harness, type ModelCall, OTHER, reply, USER, uuidsIn } from './coach_fake.ts';

const uuid = () => crypto.randomUUID();
/** 2026-10-07 09:00 UTC plus `minute` minutes. */
const at = (minute: number) => new Date(Date.UTC(2026, 9, 7, 9, 0, 0) + minute * 60_000).toISOString();

type Turn = ['user' | 'assistant', string, Record<string, unknown>?];

function seed(h: Harness, turns: Turn[], over: Record<string, unknown> = {}, start = 0): any {
  const t = h.db.thread(USER, over);
  turns.forEach(([role, content, extra], i) => h.db.message(USER, t.id, role, content, { created_at: at(start + i), ...extra }));
  return h.db.threadRow(t.id);
}

const maintain = (h: Harness, id: string, token?: string) => h.json(`threads/${id}/maintain`, { method: 'POST', body: {}, token });
/** Sets the clock to `at(minute)`: right after a turn the chat is not quiet yet, 10 minutes later it is. */
const clockAt = (h: Harness, minute: number) => { h.db.clock = Date.parse(at(minute)); };
const exhaust = (h: Harness, user = USER) => h.db.usage.set(user, { calls: 0, utility_calls: h.cfg.dailyUtilityLimit, utility_tokens: 0 });
const promptOf = (c: ModelCall) => `${c.system}\n${c.user}`;
/** The short ref the model was shown for the memory line containing `needle`. */
const refOf = (c: ModelCall, needle: string) => new RegExp(`^(m\\d+) \\[[^\\]]*\\] [^\\n]*${needle}`, 'm').exec(c.user)?.[1];

// ------------------------------------------------------------------------------------------------
// Titles
// ------------------------------------------------------------------------------------------------

Deno.test('coach title: a model title is sanitised and stored as auto through the utility request shape', async () => {
  const h = await harness({ title: { title: '"Chat about Marathon Taper!!" 🏃' } });
  const t = seed(h, [['user', 'How should I taper?']], { title: 'How should I taper', title_source: 'fallback' });
  const res = await h.json(`threads/${t.id}/title`, {
    method: 'POST', body: { question: 'How should I taper before my marathon?', answer: 'Cut volume by a third.', locale: 'en-GB' },
  });
  assertEquals(res, { status: 200, body: { title: 'Marathon Taper', titleSource: 'auto', generated: true } });
  assertEquals([h.db.threadRow(t.id).title, h.db.threadRow(t.id).title_source], ['Marathon Taper', 'auto']);

  const [call] = h.model.of('title');
  assertEquals(call.body.model, h.cfg.models.utility);
  assertEquals([call.body.stream, call.body.max_tokens, call.body.reasoning_effort], [false, 60, 'none']);
  assertEquals(call.body.response_format, { type: 'json_object' });
  assertEquals(call.authorization, 'Bearer fw-test-key');
  assert(call.user.includes('How should I taper before my marathon?') && call.system.includes('English'));
  assertEquals(uuidsIn(promptOf(call)), []);
  assertEquals(h.db.usage.get(USER)?.utility_calls, 1, 'one utility unit per pass');
  assertEquals(h.db.usage.get(USER)?.utility_tokens, 120, 'token usage recorded');
  assertEquals(h.db.usage.get(USER)?.calls ?? 0, 0, 'never the chat quota');

  // An auto title is not regenerated.
  assertEquals((await h.json(`threads/${t.id}/title`, { method: 'POST', body: { question: 'q?' } })).body,
    { title: 'Marathon Taper', titleSource: 'auto', generated: false });
  assertEquals(h.model.of('title').length, 1);
});

Deno.test('coach title: a user title is never replaced, even by a rename that lands during the model call', async () => {
  let target = '';
  const h = await harness({
    title: () => {
      Object.assign(h.db.threadRow(target), { title: 'My Race', title_source: 'user' });
      return { title: 'Model Title' };
    },
  });
  const named = seed(h, [['user', 'q']], { title: 'Mine', title_source: 'user' });
  assertEquals((await h.json(`threads/${named.id}/title`, { method: 'POST', body: { question: 'How do I taper?' } })).body,
    { title: 'Mine', titleSource: 'user', generated: false });
  assertEquals(h.model.calls.length, 0);

  target = seed(h, [['user', 'q']], { title: 'Fallback words', title_source: 'fallback' }).id;
  assertEquals((await h.json(`threads/${target}/title`, { method: 'POST', body: { question: 'How do I taper?' } })).body,
    { title: 'My Race', titleSource: 'user', generated: false });
  assertEquals(h.db.threadRow(target).title, 'My Race');

  for (const body of [{}, { question: '   ' }]) assertEquals((await h.json(`threads/${target}/title`, { method: 'POST', body })).status, 400);
  assertEquals((await h.json(`threads/${uuid()}/title`, { method: 'POST', body: { question: 'q' } })).status, 404);
  assertEquals((await h.json(`threads/${target}/title`, { method: 'POST', body: { question: 'q' }, token: 'noop_other' })).status, 404);
  assertEquals((await h.json('threads/nope/title', { method: 'POST', body: { question: 'q' } })).status, 400);
});

Deno.test('coach title: no budget, a truncated reply or a provider error falls back to the first words', async () => {
  const h = await harness({ title: reply({ title: 'Cut Off Ti' }, { finish: 'length', tokens: 55 }) });
  const t = seed(h, [['user', 'q']]);
  const res = await h.json(`threads/${t.id}/title`, { method: 'POST', body: { question: 'how should I taper before my marathon next month?' } });
  assertEquals(res.body, { title: 'How should I taper before my', titleSource: 'fallback', generated: false });
  assertEquals(h.db.usage.get(USER)?.utility_tokens, 55, 'a truncated reply still costs its tokens');

  const down = await harness({ title: reply(null, { status: 500 }) });
  const t2 = seed(down, [['user', 'q']]);
  const body = (await down.json(`threads/${t2.id}/title`, { method: 'POST', body: { question: 'Knee pain after running' } })).body;
  assertEquals(body, { title: 'Knee pain after running', titleSource: 'fallback', generated: false });
  assert(!JSON.stringify(body).includes('secret'));

  const broke = await harness({ title: { title: 'Never Asked' } });
  exhaust(broke);
  const t3 = seed(broke, [['user', 'q']]);
  assertEquals((await broke.json(`threads/${t3.id}/title`, { method: 'POST', body: { question: 'Sleep and caffeine' } })).body.titleSource, 'fallback');
  assertEquals(broke.model.calls.length, 0, 'no budget, no model call');
});

Deno.test('coach title: COACH_UTILITY_* choose the key, the model and whether reasoning_effort is sent', async () => {
  const h = await harness({ title: { title: 'Taper Plan' } },
    { COACH_UTILITY_API_KEY: 'util-key', COACH_MODEL_UTILITY: 'accounts/x/cheap', COACH_UTILITY_REASONING: '', COACH_DAILY_UTILITY_LIMIT: '2' });
  const t = seed(h, [['user', 'q']]);
  await h.json(`threads/${t.id}/title`, { method: 'POST', body: { question: 'Taper?' } });
  const [call] = h.model.calls;
  assertEquals([call.authorization, call.body.model, 'reasoning_effort' in call.body], ['Bearer util-key', 'accounts/x/cheap', false]);
  assertEquals(h.cfg.dailyUtilityLimit, 2);
  assertEquals(h.cfg.models.chat, 'accounts/fireworks/models/deepseek-v4p1-flash', 'the answer model is unchanged');
});

// ------------------------------------------------------------------------------------------------
// Follow-ups
// ------------------------------------------------------------------------------------------------

Deno.test('coach followups: validated against the question, the asked list and each other; title in the same call', async () => {
  const h = await harness({
    followups: {
      follow_ups: [
        'What is my HRV trend this month?', 'what is my hrv trend THIS month', 'Why?', 'How should I taper before my race?',
        'What dosage of melatonin should I take?', 'x'.repeat(81), '- Does my sleep look better than last week?',
        'One more good question here?', 'A fourth valid question?',
      ],
      title: 'Taper And HRV',
    },
  });
  const t = seed(h, [['user', 'How should I taper before my race?']], { title: 'How should I taper', title_source: 'fallback' });
  h.db.memory(USER, 'User is training for the Berlin marathon', { topic: 'goal', importance: 4 });
  const res = await h.json('followups', {
    method: 'POST',
    body: {
      threadId: t.id, question: 'How should I taper before my race?', answer: 'Your HRV is up 8% this week, so cut volume by a third.',
      asked: ['should I add a second rest day'], locale: 'en', wantTitle: true,
    },
  });
  assertEquals(res.status, 200);
  assertEquals(res.body, {
    followUps: ['What is my HRV trend this month?', 'Does my sleep look better than last week?', 'One more good question here?'],
    title: 'Taper And HRV',
  });
  assertEquals([h.db.threadRow(t.id).title, h.db.threadRow(t.id).title_source], ['Taper And HRV', 'auto']);
  const [call] = h.model.of('followups');
  assertEquals(call.body.max_tokens, 260);
  assert(call.system.includes('"title"') && call.user.includes('Berlin marathon') && call.user.includes('Already asked'));
  assertEquals(uuidsIn(promptOf(call)), []);
  assertEquals(h.db.usage.get(USER)?.utility_calls, 1, 'follow-ups and the title share one call');

  // A user title is kept and not even asked for.
  await h.json(`threads/${t.id}`, { method: 'PATCH', body: { title: 'Race week' } });
  const again = await h.json('followups', { method: 'POST', body: { threadId: t.id, question: 'q here?', answer: 'An answer.', wantTitle: true } });
  assert(!('title' in again.body));
  assert(!h.model.of('followups')[1].system.includes('"title"'));
  assertEquals(h.db.threadRow(t.id).title, 'Race week');
});

Deno.test('coach followups: without a list the thread\'s own non-blocked questions are used; minors get a safer prompt', async () => {
  const h = await harness({ followups: { follow_ups: ['How do I pace the first half?'] } });
  const t = seed(h, [['user', 'Earlier question about pacing'], ['user', 'secret blocked words', { meta: { blocked: true } }]]);
  h.db.insert('profiles', { id: USER, date_of_birth: '2012-03-01' });
  const res = await h.json('followups', { method: 'POST', body: { threadId: t.id, question: 'Race plan?', answer: 'Start easy.' } });
  assertEquals(res.body, { followUps: ['How do I pace the first half?'] });
  const [call] = h.model.calls;
  assert(call.user.includes('Earlier question about pacing'));
  assert(!promptOf(call).includes('secret blocked words'), 'blocked turns never reach a prompt');
  assert(call.system.includes('under 18'));
});

Deno.test('coach followups: when the combined reply has no usable title, one title pass still names the chat', async () => {
  const h = await harness({ followups: reply(null, { status: 500 }), title: { title: 'Sleep And HRV Dip' } });
  const t = seed(h, [['user', 'How is my sleep?']], { title: 'How is my sleep', title_source: 'fallback' });
  const body = { threadId: t.id, question: 'How is my sleep?', answer: 'Your sleep was short and your HRV dipped.', wantTitle: true };
  const res = await h.json('followups', { method: 'POST', body });
  assertEquals(res.body.title, 'Sleep And HRV Dip');
  assertEquals(res.body.followUps.length, 3, 'the follow-ups still fall back to keywords');
  assertEquals([h.db.threadRow(t.id).title, h.db.threadRow(t.id).title_source], ['Sleep And HRV Dip', 'auto']);
  assertEquals(h.model.of('title').length, 1);

  // A reply that answers the follow-ups but leaves the title out gets the same retry.
  const partial = await harness({ followups: { follow_ups: ['How does my sleep compare to last month?'] }, title: { title: 'Short Sleep Check' } });
  const u = seed(partial, [['user', 'How is my sleep?']], { title: 'How is my sleep', title_source: 'fallback' });
  assertEquals((await partial.json('followups', { method: 'POST', body: { ...body, threadId: u.id } })).body,
    { followUps: ['How does my sleep compare to last month?'], title: 'Short Sleep Check' });

  // After a timed-out combined call the retry only gets what is left of the phone's wait; then the first words stay.
  const slow = await harness({ followups: reply({ follow_ups: [] }, { delayMs: 400 }), title: reply({ title: 'Too Late' }, { delayMs: 400 }) },
    {}, { timeScale: 0.03 });
  const v = seed(slow, [['user', 'How is my sleep?']], { title: 'How is my sleep', title_source: 'fallback' });
  const started = performance.now();
  const late = await slow.json('followups', { method: 'POST', body: { ...body, threadId: v.id } });
  assert(performance.now() - started < 11_000 * 0.03 + 150, 'the route answers inside the phone\'s wait');
  assertEquals(late.body.title, undefined);
  assertEquals(slow.model.of('title').length, 1);
  assertEquals(slow.db.threadRow(v.id).title, 'How is my sleep');
});

Deno.test('coach followups: a failed or unbudgeted call falls back to keyword follow-ups (English only)', async () => {
  const h = await harness({ followups: reply(null, { status: 500 }) });
  const body = { question: 'How is my sleep?', answer: 'Your sleep was short and your HRV dipped.' };
  const res = await h.json('followups', { method: 'POST', body });
  assertEquals(res.body.followUps, ['How has my HRV trended lately?', 'What would improve my sleep the most?', 'How should this change my plan this week?']);
  assertEquals(res.body.followUps, keywordFollowUps(body.question, body.answer));
  assert(!JSON.stringify(res.body).includes('secret'));
  assertEquals((await h.json('followups', { method: 'POST', body: { ...body, locale: 'es-ES' } })).body, { followUps: [] });

  const broke = await harness({ followups: { follow_ups: ['never'] } });
  exhaust(broke);
  assertEquals((await broke.json('followups', { method: 'POST', body })).body.followUps.length, 3);
  assertEquals(broke.model.calls.length, 0);

  // A reply that is all invalid is treated like no reply.
  const junk = await harness({ followups: { follow_ups: ['Why?', 42, 'What dose of ibuprofen?'] } });
  assertEquals((await junk.json('followups', { method: 'POST', body })).body.followUps.length, 3);
  for (const bad of [{}, { question: 'q' }, { question: 'q', answer: 'a', threadId: 'x' }]) {
    assertEquals((await h.json('followups', { method: 'POST', body: bad })).status, 400);
  }
  assertEquals(validFollowUps(['Same thing again?', 'same thing again'], 'x', []), ['Same thing again?']);
  assertEquals(validFollowUps(['Should I add a second rest day?', 'Is a deload week due soon?'], 'q', ['should I add a second rest day']),
    ['Is a deload week due soon?'], 'never a question already asked');
});

// ------------------------------------------------------------------------------------------------
// Starter suggestions
// ------------------------------------------------------------------------------------------------

const STARTERS = [
  { text: 'Pick up my marathon plan', kind: 'continue', thread: 't1' },
  { text: 'Continue the knee chat', kind: 'continue', thread: 't9' },
  { text: 'Back to my sleep chat', kind: 'continue', thread: 't2' },
  { text: 'A third continue', kind: 'continue', thread: 't1' },
  { text: 'What dosage of magnesium helps sleep?', kind: 'explore' },
  { text: 'Why is my HRV down this morning?', kind: 'state' },
  { text: 'Help me hit my 3:30 goal', kind: 'goal' },
  { text: 'Something extra', kind: 'explore' },
];

function seedStarterWorld(h: Harness) {
  const sleep = seed(h, [['user', 'Why do I wake at 3am?'], ['assistant', 'Late caffeine.']],
    { title: 'Waking at 3am', summary_topics: ['sleep'], open_loops: ['Try no caffeine after noon'] }, 0);
  const marathon = seed(h, [['user', 'Plan my marathon block'], ['user', 'my secret blocked words', { meta: { blocked: true } }]],
    { title: 'Marathon block' }, 30);
  h.db.memory(USER, 'User likes oat milk', { topic: 'preference', importance: 2 });
  h.db.memory(USER, 'User aims for a 3:30 marathon', { topic: 'goal', importance: 4 });
  h.db.rows('coach_user_state').push({ user_id: USER, suggestions: [], recent_searches: ['ferritin', 'knee'], memory_revision: 0 });
  return { sleep, marathon };
}

Deno.test('coach suggestions: personalised by the model, continue items mapped back and capped, then cached by fingerprint', async () => {
  const h = await harness({ suggestions: { suggestions: STARTERS } });
  const { sleep, marathon } = seedStarterWorld(h);
  const state = { day: '2026-10-07', charge: 'red', hrv: 'down', dayPart: 'morning', weekday: 'Wednesday', flags: ['hrv_down'] };
  const fallback = ['How did I sleep?', 'What should I do today?'];
  const first = await h.json('suggestions', { method: 'POST', body: { state, fallback, locale: 'en' } });
  assertEquals(first.body, {
    suggestions: [
      { text: 'Pick up my marathon plan', kind: 'continue', threadId: marathon.id },
      { text: 'Back to my sleep chat', kind: 'continue', threadId: sleep.id },
      { text: 'Why is my HRV down this morning?', kind: 'state' },
      { text: 'Help me hit my 3:30 goal', kind: 'goal' },
    ],
    source: 'model',
  });
  const [call] = h.model.of('suggestions');
  assertEquals(call.body.max_tokens, 360);
  const prompt = promptOf(call);
  assertEquals(uuidsIn(prompt), []);
  assert(prompt.includes('[t1] "Marathon block"') && prompt.includes('open: Try no caffeine after noon'));
  assert(prompt.includes('- ferritin') && prompt.includes('hrv_down') && prompt.includes('Wednesday morning'));
  assert(prompt.indexOf('3:30 marathon') < prompt.indexOf('oat milk'), 'goals before preferences');
  assert(!prompt.includes('secret blocked words'));
  assert(!prompt.includes('"charge"'), 'charge is not computed, so it never reaches the starters');

  const cached = await h.json('suggestions', { method: 'POST', body: { state, fallback } });
  assertEquals(cached.body, { ...first.body, source: 'cache' });
  assertEquals(h.model.calls.length, 1);

  // Anything in the fingerprint moves it: refresh, state, locale, a revising memory change, chat activity, the 12 h TTL.
  await h.json('suggestions', { method: 'POST', body: { state, fallback, refresh: true } });
  assertEquals(h.model.calls.length, 2);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, sleep: 'short' }, fallback } });
  assertEquals(h.model.calls.length, 3);
  await h.json('memories', { method: 'POST', body: { content: 'User tore an ACL in 2024', topic: 'injury', importance: 5 } });
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, sleep: 'short' }, fallback } });
  assertEquals(h.model.calls.length, 4);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, sleep: 'short' }, fallback } });
  assertEquals(h.model.calls.length, 4, 'cached again');
  h.db.advance(13 * 3_600_000);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, sleep: 'short' }, fallback } });
  assertEquals(h.model.calls.length, 5, 'older than 12 h');
  h.db.message(USER, sleep.id, 'user', 'One more', { created_at: at(600) });
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, sleep: 'short' }, fallback } });
  assertEquals(h.model.calls.length, 6);
  const stored = h.db.rows('coach_user_state').find((s) => s.user_id === USER);
  assertEquals(stored.suggestions.length, 4);
  assert(typeof stored.suggestions_fingerprint === 'string' && stored.suggestions_fingerprint.length === 64);
});

Deno.test('coach suggestions: the phone\'s list is the fallback when the model fails or the budget is spent', async () => {
  const h = await harness({ suggestions: reply(null, { status: 503 }) });
  seedStarterWorld(h);
  const fallback = ['How did I sleep?', 'What dose of melatonin?', 'What should I do today?', 'x'.repeat(70)];
  const res = await h.json('suggestions', { method: 'POST', body: { fallback } });
  assertEquals(res.body, {
    suggestions: [{ text: 'How did I sleep?', kind: 'explore' }, { text: 'What should I do today?', kind: 'explore' }],
    source: 'fallback',
  });
  assertEquals(h.db.rows('coach_user_state').find((s) => s.user_id === USER).suggestions_fingerprint ?? null, null, 'nothing cached');

  const broke = await harness({ suggestions: { suggestions: STARTERS } });
  exhaust(broke);
  assertEquals((await broke.json('suggestions', { method: 'POST', body: { fallback: ['Plan my week'] } })).body,
    { suggestions: [{ text: 'Plan my week', kind: 'explore' }], source: 'fallback' });
  assertEquals(broke.model.calls.length, 0);

  // Continue items that name no chat the model was shown are dropped; a short model set is topped up from the list.
  const thin = await harness({ suggestions: { suggestions: [{ text: 'Back to that chat', kind: 'continue', thread: 't1' }, { text: 'Fuel for a long run', kind: 'explore' }] } });
  const body = (await thin.json('suggestions', { method: 'POST', body: { fallback: ['Plan my week', 'fuel for a LONG run'] } })).body;
  assertEquals(body, { suggestions: [{ text: 'Fuel for a long run', kind: 'explore' }, { text: 'Plan my week', kind: 'explore' }], source: 'model' });
  assertEquals((await thin.json('suggestions', { method: 'POST', raw: '{bad' })).status, 400);
  assertEquals((await thin.json('suggestions', { method: 'POST', raw: '' })).status, 200, 'an empty body is {}');
});

// ------------------------------------------------------------------------------------------------
// Maintenance
// ------------------------------------------------------------------------------------------------

const summaryReply = (text: string, extra: Record<string, unknown> = {}) => ({ summary: text, topics: ['Marathon', 'taper'], open_loops: ['Report back after the long run'], memory_ops: [], ...extra });

Deno.test('coach maintain: a first exchange gets a summary and curated memory, published together', async () => {
  const h = await harness({
    curator: summaryReply('The user is training for the Berlin marathon on 2027-04-25 and asked about tapering.', {
      memory_ops: [{ op: 'add', topic: 'goal', importance: 4, content: 'User is training for the Berlin marathon on 2027-04-25' }],
    }),
  });
  const t = seed(h, [['user', 'I am training for the Berlin marathon on 2027-04-25. How do I taper?'], ['assistant', 'Cut volume by a third.']]);
  const res = await maintain(h, t.id);
  assertEquals(res, { status: 200, body: { status: 'done', summarized: true, memoryOps: 1, consolidated: false } });
  const row = h.db.threadRow(t.id);
  assertEquals(row.summary, 'The user is training for the Berlin marathon on 2027-04-25 and asked about tapering.');
  assertEquals([row.summary_topics, row.open_loops, row.summary_messages], [['marathon', 'taper'], ['Report back after the long run'], 2]);
  assertEquals([row.summary_through, row.curated_through], [h.db.rows('coach_messages').at(-1).created_at, h.db.rows('coach_messages').at(-1).created_at]);
  assertEquals([row.maintenance_token, row.maintenance_until], [null, null], 'the lease is released');
  const [mem] = h.db.activeMemories();
  assertEquals([mem.content, mem.source, mem.source_thread_id, mem.topic], ['User is training for the Berlin marathon on 2027-04-25', 'curator', t.id, 'goal']);
  const [call] = h.model.of('curator');
  assertEquals(call.body.max_tokens, 1_400);
  assert(call.system.includes('"summary"') && call.system.includes('"memory_ops"'));
  assert(call.user.includes('[2026-10-07] User: I am training') && call.user.includes('Summary so far: (none yet)'));
  assertEquals(uuidsIn(promptOf(call)), []);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.pendingMessages, 0);

  // Nothing new: skipped without a model call, and the lease is free again.
  assertEquals((await maintain(h, t.id)).body, { status: 'skipped', summarized: false, memoryOps: 0, consolidated: false });
  assertEquals(h.model.calls.length, 1);
  assertEquals(h.db.threadRow(t.id).maintenance_token, null);
});

Deno.test('coach maintain: memory ops need a new user message; the summary needs 4 new messages (2 for the first, 1 once quiet)', async () => {
  const h = await harness({ curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user and Sana kept talking about training.') : { memory_ops: [] }) });
  const summarised = { summary: 'Earlier summary of the chat.', summary_through: at(0), curated_through: at(0), summary_messages: 1 };
  const cases: [string, Turn[], Record<string, unknown>, string, boolean?][] = [
    ['three assistant messages', [['assistant', 'a'], ['assistant', 'b'], ['assistant', 'c']], summarised, 'skipped'],
    ['one user message', [['user', 'I run on Tuesdays']], summarised, 'memory'],
    ['four assistant messages', [['assistant', 'a'], ['assistant', 'b'], ['assistant', 'c'], ['assistant', 'd']], summarised, 'summary'],
    ['a lone first question', [['user', 'I run on Tuesdays']], {}, 'memory'],
    ['a first exchange', [['user', 'I run on Tuesdays'], ['assistant', 'Nice.']], {}, 'both'],
    // Quiet for 10 minutes: whatever is left is folded, so a finished chat's last turns reach the summary.
    ['three assistant messages, quiet', [['assistant', 'a'], ['assistant', 'b'], ['assistant', 'c']], summarised, 'summary', true],
    ['one user message, quiet', [['user', 'I run on Tuesdays']], summarised, 'both', true],
    ['a lone first question, quiet', [['user', 'I run on Tuesdays']], {}, 'both', true],
  ];
  for (const [label, turns, over, expected, quiet] of cases) {
    const t = h.db.thread(USER, over);
    if (over.summary) h.db.message(USER, t.id, 'user', 'old message', { created_at: at(0) });
    turns.forEach(([role, content], i) => h.db.message(USER, t.id, role, content, { created_at: at(10 + i) }));
    clockAt(h, 10 + turns.length - 1 + (quiet ? 10 : 1));
    const before = h.model.calls.length;
    const { body } = await maintain(h, t.id);
    const call = h.model.calls[before];
    if (expected === 'skipped') {
      assertEquals([body.status, h.model.calls.length], ['skipped', before], label);
      continue;
    }
    assertEquals(body.status, 'done', label);
    assertEquals(call.system.includes('"summary"'), expected !== 'memory', `${label}: summary`);
    assertEquals(call.system.includes('"memory_ops"'), expected !== 'summary', `${label}: memory`);
    assertEquals(body.summarized, expected !== 'memory', label);
    const row = h.db.threadRow(t.id);
    assertEquals(iso(row.curated_through), at(10 + turns.length - 1), `${label}: curated through the batch`);
    assertEquals(iso(row.summary_through), expected === 'memory' ? (over.summary_through ?? null) : at(10 + turns.length - 1), `${label}: summary cursor`);
  }
});

Deno.test('coach maintain: blocked turns right after the folded messages move the summary cursor with them', async () => {
  const h = await harness({ curator: () => summaryReply('The user asked about pacing and got a plan.') });
  const t = seed(h, [['user', 'How should I pace my 10k?'], ['assistant', 'Start 10 s slower than goal pace.'],
    ['user', 'my secret blocked words', { meta: { blocked: true } }], ['assistant', 'I can\'t help with that.', { meta: { blocked: true } }]]);
  assertEquals((await maintain(h, t.id)).body.status, 'done');
  const row = h.db.threadRow(t.id);
  assertEquals([iso(row.summary_through), iso(row.curated_through), row.summary_messages], [at(3), at(3), 4]);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.pendingMessages, 0);
  assert(!promptOf(h.model.of('curator')[0]).includes('secret blocked'));
  // A later turn is new material again, counted once.
  h.db.message(USER, t.id, 'user', 'And for a half marathon?', { created_at: at(10) });
  h.db.message(USER, t.id, 'assistant', 'Hold back for the first 5 km.', { created_at: at(11) });
  clockAt(h, 12);
  await maintain(h, t.id);
  assertEquals(iso(h.db.threadRow(t.id).curated_through), at(11));
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.pendingMessages, 2, 'right after the turn two new messages wait for more');
});

Deno.test('coach maintain: a quiet chat folds its last turns into the summary, then needs no more maintenance (finding 10)', async () => {
  const h = await harness({ curator: (c: ModelCall) => (c.system.includes('"summary"')
    ? summaryReply('The user will test the new taper next week and report back.', { open_loops: ['Report back on the new taper'] }) : { memory_ops: [] }) });
  const t = seed(h, [['user', 'How should I taper?'], ['assistant', 'Cut volume by a third.']]);
  clockAt(h, 2);
  assertEquals((await maintain(h, t.id)).body.summarized, true, 'the first exchange');
  h.db.message(USER, t.id, 'user', "I'll test the new taper next week and report back", { created_at: at(5) });
  h.db.message(USER, t.id, 'assistant', 'Great, tell me how it goes.', { created_at: at(6) });
  clockAt(h, 7);
  assertEquals((await maintain(h, t.id)).body.summarized, false, 'right after the turn: memory only');
  let thread = (await h.json(`threads/${t.id}`)).body.thread;
  assertEquals([thread.pendingMessages, thread.needsMaintenance], [2, false], 'nothing to do until the chat goes quiet');

  clockAt(h, 16);
  thread = (await h.json(`threads/${t.id}`)).body.thread;
  assertEquals([thread.pendingMessages, thread.needsMaintenance], [2, true], 'quiet: the tail is due');
  const res = (await maintain(h, t.id)).body;
  assertEquals([res.status, res.summarized], ['done', true]);
  const row = h.db.threadRow(t.id);
  assertEquals([iso(row.summary_through), row.open_loops], [at(6), ['Report back on the new taper']]);
  thread = (await h.json(`threads/${t.id}`)).body.thread;
  assertEquals([thread.pendingMessages, thread.needsMaintenance], [0, false]);
  const calls = h.model.calls.length;
  assertEquals((await maintain(h, t.id)).body.status, 'skipped');
  assertEquals(h.model.calls.length, calls, 'and the next launch does nothing');
});

Deno.test('coach maintain: a skipped pass steps the memory cursor over a reply saved after the curated question (I7)', async () => {
  const h = await harness({ curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user asked about tapering.') : { memory_ops: [] }) });
  const t = seed(h, [['user', 'How should I taper?'], ['assistant', 'Cut volume by a third.']]);
  clockAt(h, 2);
  await maintain(h, t.id);
  // The pass ran between the question's save and the answer's.
  h.db.message(USER, t.id, 'user', 'And the week before?', { created_at: at(5) });
  clockAt(h, 5.5);
  assertEquals((await maintain(h, t.id)).body.summarized, false);
  assertEquals(iso(h.db.threadRow(t.id).curated_through), at(5));
  h.db.message(USER, t.id, 'assistant', 'Keep one short session.', { created_at: at(6) });
  clockAt(h, 7);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.needsMaintenance, true, 'something arrived after the cursor');
  const calls = h.model.calls.length;
  assertEquals((await maintain(h, t.id)).body.status, 'skipped');
  assertEquals(h.model.calls.length, calls, 'no new question: no model call');
  assertEquals(iso(h.db.threadRow(t.id).curated_through), at(6));
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.needsMaintenance, false, 'so the chat is not offered again right away');
  clockAt(h, 17);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.needsMaintenance, true, 'until it goes quiet with turns to fold');
  assertEquals((await maintain(h, t.id)).body.summarized, true);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.needsMaintenance, false);
});

Deno.test('coach maintain: the curator never mines messages older than forget-all, nor blocked turns', async () => {
  const h = await harness({ curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user asked about knee pain and running.') : { memory_ops: [] }) });
  const t = seed(h, [['user', 'My knee hurts when I run'], ['assistant', 'Ease off hills.']]);
  h.db.rows('coach_user_state').push({ user_id: USER, memory_floor_at: at(30), suggestions: [], recent_searches: [], memory_revision: 1 });
  await maintain(h, t.id);
  const [call] = h.model.of('curator');
  assert(call.system.includes('"summary"') && !call.system.includes('"memory_ops"'), 'summary only: the user message predates the floor');

  const b = seed(h, [['user', 'my secret blocked words', { meta: { blocked: true } }], ['assistant', 'I can\'t help with that.', { meta: { blocked: true } }]],
    { summary: 'An earlier summary.', summary_through: at(39), curated_through: at(39) }, 40);
  assertEquals((await maintain(h, b.id)).body.status, 'skipped', 'blocked turns are not new material');
  // ...but they count as handled, so a chat that ends on a blocked turn is not offered for maintenance forever.
  assertEquals([iso(h.db.threadRow(b.id).summary_through), h.db.threadRow(b.id).summary_messages], [at(41), 2]);
  assertEquals((await h.json(`threads/${b.id}`)).body.thread.pendingMessages, 0);
  assertEquals(h.db.threadRow(b.id).summary, 'An earlier summary.');
  const c = seed(h, [['user', 'I swim on Mondays'], ['user', 'my secret blocked words', { meta: { blocked: true } }], ['assistant', 'Great routine.']], {}, 50);
  await maintain(h, c.id);
  const last = h.model.calls.at(-1)!;
  assert(last.user.includes('I swim on Mondays') && !promptOf(last).includes('secret blocked'));
});

Deno.test('coach maintain: photo turns carry what the vision model saw; batches fold oldest first within their limits', async () => {
  const words = (n: number, seedWord: string) => Array.from({ length: n }, (_, i) => `${seedWord}${i % 7}`).join(' ');
  let calls = 0;
  const h = await harness({ curator: (c: ModelCall) => summaryReply(`Summary after batch ${++calls} of the long chat.`, c.system.includes('"memory_ops"') ? {} : {}) });
  const turns: Turn[] = [['user', 'What is in this?', { meta: { imageContext: 'A bowl of oats with blueberries' } }]];
  for (let i = 1; i < 80; i++) turns.push([i % 2 ? 'assistant' : 'user', i === 5 ? 'z'.repeat(5_000) : words(100, i % 2 ? 'answer' : 'question')]);
  const t = seed(h, turns);
  const res = await maintain(h, t.id);
  assertEquals(res.body.status, 'done');
  const curator = h.model.of('curator');
  assertEquals(curator.length, 3, 'at most 3 batches per call');
  let folded = 0;
  curator.forEach((c, i) => {
    const block = c.user.split('New messages:\n')[1];
    const lines = block.split('\n');
    assert(lines.length <= 24, `batch ${i}: ${lines.length} messages`);
    assert(block.length <= 14_000, `batch ${i}: ${block.length} characters`);
    assert(lines.every((l) => l.length <= 1_500 + 24), 'each message cut to 1,500 characters');
    if (i > 0) assert(c.user.includes(`Summary so far: Summary after batch ${i} of the long chat.`), 'recursive: each batch folds into the last summary');
    folded += lines.length;
  });
  assert(curator[0].user.includes('User: [Photo: A bowl of oats with blueberries] What is in this?'));
  const rows = h.db.rows('coach_messages').filter((m) => m.thread_id === t.id);
  const row = h.db.threadRow(t.id);
  assertEquals(row.summary_messages, folded);
  assertEquals(row.summary_through, rows[folded - 1].created_at);
  assertEquals(row.summary, 'Summary after batch 3 of the long chat.');

  // The next call picks up where this one stopped and finishes the thread.
  await maintain(h, t.id);
  assertEquals(h.db.threadRow(t.id).summary_messages, 80);
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.pendingMessages, 0);
  assertEquals(maintenanceBatches(Array.from({ length: 100 }, (_, i) => ({ role: 'user', content: `m${i}`, created_at: at(i) }))).map((b) => b.length), [24, 24, 24]);
  assertEquals(curatorLine({ role: 'assistant', content: ' a \n b ', created_at: at(0) }), '[2026-10-07] Sana: a b');
});

Deno.test('coach dates: prompts carry the owner\'s calendar day, not the next UTC one', () => {
  // 02:44 UTC on the 8th is 19:44 on the 7th in Pacific time: a memory mined from it must say the 7th.
  const evening = '2026-10-08T02:44:32.329Z';
  assertEquals(day(evening), '2026-10-08');
  assertEquals(day(evening, 'America/Los_Angeles'), '2026-10-07');
  assertEquals(day('2026-10-07T15:39:53.811363-07:00', 'America/Los_Angeles'), '2026-10-07');
  assertEquals(curatorLine({ role: 'user', content: 'hi', created_at: evening }, 'America/Los_Angeles'), '[2026-10-07] User: hi');
  assertEquals(validZone('Europe/Berlin'), 'Europe/Berlin');
  assertEquals(validZone('Mars/Olympus'), 'UTC');
  assertEquals(validZone(null), 'UTC');
});

Deno.test('coach maintain: refs map back, number-aware supersede, and every §6 guard drops what it should', async () => {
  let shown: ModelCall | undefined;
  const h = await harness({
    curator: (c: ModelCall) => {
      shown = c;
      return {
        memory_ops: [
          { op: 'confirm', ref: refOf(c, 'hamstring') },
          { op: 'add', topic: 'goal', importance: 4, content: "User's marathon goal is 3:30" },
          { op: 'retire', ref: refOf(c, 'coffee'), reason: 'User said they no longer drink coffee' },
          { op: 'add', topic: 'routine', importance: 3, content: 'User should stretch daily' },
          { op: 'add', topic: 'sleep', importance: 2, content: 'User slept 5 hours last night' },
          { op: 'add', topic: 'lifestyle', importance: 2, content: "User's wife Sarah runs with them" },
          { op: 'add', topic: 'health', importance: 5, content: 'User is allergic to peanuts' },
          { op: 'update', ref: 'm99', content: 'Ghost' },
          { op: 'add', topic: 'routine', importance: 3, content: 'User swims on Mondays' },
          { op: 'add', topic: 'routine', importance: 3, content: 'User cycles on Fridays' },
        ],
      };
    },
  });
  const forgotten = (await h.json('memories', { method: 'POST', body: { content: 'User is allergic to peanuts', topic: 'health' } })).body.memory;
  await h.json(`memories/${forgotten.id}`, { method: 'DELETE' });
  const t = h.db.thread(USER, { summary: 'An earlier summary.', summary_through: at(0), curated_through: at(0), summary_messages: 1 });
  h.db.message(USER, t.id, 'user', 'old', { created_at: at(0) });
  const ham = h.db.memory(USER, 'User has a tight left hamstring', { topic: 'injury', importance: 4, source: 'tool', source_thread_id: t.id });
  const goal = h.db.memory(USER, "User's marathon goal is 3:45", { topic: 'goal', importance: 3 });
  const coffee = h.db.memory(USER, 'User drinks coffee every morning', { topic: 'nutrition', importance: 2 });
  for (let i = 0; i < 30; i++) h.db.memory(USER, `Unrelated filler ${'abcdefghij'[i % 10]}${'abcdefghij'[Math.floor(i / 10)]}q`, { importance: 1 });
  h.db.message(USER, t.id, 'user', [
    'My left hamstring is tight again. I switched my marathon goal to 3:30. I don\'t drink coffee anymore.',
    'I slept 5 hours last night. My wife Sarah runs with me. I\'m allergic to peanuts. I swim on Mondays and I cycle on Fridays.',
  ].join(' '), { created_at: at(5) });
  clockAt(h, 6);

  const res = await maintain(h, t.id);
  assertEquals(res.body, { status: 'done', summarized: false, memoryOps: 4, consolidated: false });
  assert(shown && !shown.system.includes('"summary"'), 'memory only');
  assertEquals(uuidsIn(promptOf(shown!)), []);
  assert(/^m1 \[injury, importance 4\] User has a tight left hamstring/m.test(shown!.user), "this thread's tool memories come first");
  assertEquals(shown!.user.split('\n').filter((l) => /^m\d+ \[/.test(l)).length, 24, 'at most 24 candidates');

  const byId = (id: string) => h.db.rows('coach_memory_items').find((m) => m.id === id);
  assertEquals(byId(ham.id).confirmations, 2);
  assertEquals([byId(goal.id).content, byId(goal.id).importance, byId(goal.id).version], ["User's marathon goal is 3:30", 4, 2], 'supersede, not a second goal');
  assertEquals([Boolean(byId(coffee.id).retired_at), byId(coffee.id).retired_reason], [true, 'User said they no longer drink coffee']);
  const retire = h.db.rows('coach_memory_events').find((e) => e.op === 'retire' && e.memory_id === coffee.id);
  assertEquals(retire.tokens, memoryTokens('User drinks coffee every morning'), 'the edge function\'s own tokens');
  const active = h.db.activeMemories().map((m) => m.content);
  assert(active.includes('User swims on Mondays'));
  for (const dropped of ['User should stretch daily', 'User slept 5 hours last night', "User's wife Sarah runs with them", 'User is allergic to peanuts', 'User cycles on Fridays', 'Ghost']) {
    assert(!active.includes(dropped), dropped);
  }
  assertEquals(h.db.activeMemories().filter((m) => m.content.includes('marathon goal')).length, 1);
  assertEquals(h.db.activeMemories().find((m) => m.content === 'User swims on Mondays').source, 'curator');
});

Deno.test('coach maintain: "remember" lets a sensitive fact through; duplicates of stored facts confirm instead of adding', async () => {
  const h = await harness({
    curator: {
      memory_ops: [
        { op: 'add', topic: 'lifestyle', importance: 3, content: "User's wife Sarah runs with them" },
        { op: 'add', topic: 'injury', importance: 4, content: 'User has a tight left hamstring' },
        { op: 'add', topic: 'goal', importance: 3, content: 'User wants to run a marathon right now' },
      ],
    },
  });
  const ham = h.db.memory(USER, 'User has a tight left hamstring', { topic: 'injury', importance: 4 });
  const t = seed(h, [['user', 'Please remember my wife Sarah runs with me. My left hamstring is still tight. I want to run a marathon right now.']]);
  clockAt(h, 1);
  const { body } = await maintain(h, t.id);
  assertEquals(body.memoryOps, 2);
  assert(h.db.activeMemories().some((m) => m.content === "User's wife Sarah runs with them"));
  assertEquals(h.db.activeMemories().filter((m) => m.content.includes('hamstring')).length, 1);
  assertEquals(h.db.rows('coach_memory_items').find((m) => m.id === ham.id).confirmations, 2);
  assert(!h.db.activeMemories().some((m) => m.content.includes('right now')), 'transient phrasing');
});

Deno.test('coach maintain: a held lease is busy, a lost lease publishes nothing, and missing threads are 404', async () => {
  const h = await harness({ curator: summaryReply('The user talked about intervals and recovery days.') });
  const held = seed(h, [['user', 'Intervals?'], ['assistant', 'Twice a week.']],
    { maintenance_token: uuid(), maintenance_until: new Date(h.db.clock + 60_000).toISOString() });
  assertEquals((await maintain(h, held.id)).body, { status: 'busy', summarized: false, memoryOps: 0, consolidated: false });
  assertEquals(h.model.calls.length, 0);
  h.db.advance(61_000);
  assertEquals((await maintain(h, held.id)).body.status, 'done', 'an expired lease is taken over');

  const lost = await harness({
    curator: () => {
      // Another worker took over while the model was thinking.
      h2Thread().maintenance_token = uuid();
      return summaryReply('The user talked about intervals and recovery days.', { memory_ops: [{ op: 'add', topic: 'routine', importance: 3, content: 'User does intervals twice a week' }] });
    },
  });
  const t = seed(lost, [['user', 'I do intervals twice a week'], ['assistant', 'Good.']]);
  const h2Thread = () => lost.db.threadRow(t.id);
  assertEquals((await maintain(lost, t.id)).body.status, 'busy');
  assertEquals([h2Thread().summary, lost.db.activeMemories().length], [null, 0]);

  assertEquals(await maintain(h, uuid()), { status: 404, body: { error: 'thread_not_found' } });
  assertEquals((await maintain(h, held.id, 'noop_other')).status, 404);
  assertEquals((await maintain(h, 'nope')).status, 400);
});

Deno.test('coach maintain: no budget skips the summary; a model fault keeps every cursor where it was', async () => {
  const h = await harness({ curator: summaryReply('Never written.') });
  exhaust(h);
  const t = seed(h, [['user', 'I run on Tuesdays'], ['assistant', 'Nice.']]);
  assertEquals((await maintain(h, t.id)).body.status, 'skipped');
  assertEquals([h.db.threadRow(t.id).summary, h.db.threadRow(t.id).curated_through, h.model.calls.length], [null, null, 0]);

  const bad = await harness({ curator: reply(null, { content: 'not json at all' }) });
  const t2 = seed(bad, [['user', 'I run on Tuesdays'], ['assistant', 'Nice.']]);
  assertEquals((await bad.json(`threads/${t2.id}/maintain`, { method: 'POST' })).body.status, 'skipped');
  assertEquals([bad.db.threadRow(t2.id).summary_through, bad.db.threadRow(t2.id).maintenance_token], [null, null]);
});

Deno.test('coach maintain: with EdgeRuntime.waitUntil the work is queued behind a 202', async () => {
  const queued: Promise<unknown>[] = [];
  const h = await harness({ curator: summaryReply('The user asked about recovery after a long run.') }, {}, { background: (p) => queued.push(p) });
  const t = seed(h, [['user', 'Recovery after a long run?'], ['assistant', 'Easy day next.']]);
  assertEquals(await maintain(h, t.id), { status: 202, body: { status: 'queued' } });
  assertEquals(queued.length, 1);
  await Promise.all(queued);
  assertEquals(h.db.threadRow(t.id).summary, 'The user asked about recovery after a long run.');
});

Deno.test('coach maintain: consolidation merges into the oldest row and retires covered duplicates', async () => {
  let consolidationCall: ModelCall | undefined;
  const h = await harness({
    curator: { memory_ops: [] },
    consolidation: (c: ModelCall) => {
      consolidationCall = c;
      const run = [refOf(c, 'runs five days'), refOf(c, 'runs 5 days')];
      const filler = [refOf(c, 'Filler fact aaq'), refOf(c, 'Filler fact baq')];
      return {
        ops: [
          { op: 'merge', refs: run, content: 'User runs 5 days a week, mostly easy', topic: 'training', importance: 3 },
          { op: 'retire', ref: refOf(c, 'oat milk$'), reason: 'duplicate' },
          { op: 'merge', refs: [filler[0]], content: 'Filler fact aaq' },
          { op: 'merge', refs: filler, content: 'User invented something entirely new here' },
          { op: 'retire', ref: refOf(c, 'Filler fact caq'), reason: 'duplicate' },
        ],
      };
    },
  });
  clockAt(h, 0);
  const older = h.db.memory(USER, 'User runs five days a week', { topic: 'training', created_at: '2026-01-01T00:00:00Z' });
  const newer = h.db.memory(USER, 'User runs 5 days a week, mostly easy', { topic: 'training', created_at: '2026-05-01T00:00:00Z' });
  const oat = h.db.memory(USER, 'User likes oat milk', { topic: 'preference' });
  h.db.memory(USER, 'User likes oat milk in coffee', { topic: 'preference' });
  for (let i = 0; i < 40; i++) h.db.memory(USER, `Filler fact ${'abcdefghij'[i % 10]}${'abcdefghij'[Math.floor(i / 10)]}q`, { importance: 1 });
  const t = h.db.thread(USER, { summary: 'An earlier summary.', summary_through: at(0), curated_through: at(0) });
  h.db.message(USER, t.id, 'user', 'old', { created_at: at(0) });
  h.db.message(USER, t.id, 'user', 'Thanks for that', { created_at: at(1) });
  clockAt(h, 2);

  assertEquals((await maintain(h, t.id)).body, { status: 'done', summarized: false, memoryOps: 0, consolidated: true });
  assertEquals(consolidationCall!.body.max_tokens, 2_400);
  assertEquals(uuidsIn(promptOf(consolidationCall!)), []);
  assertEquals(consolidationCall!.user.split('\n').filter((l) => /^m\d+ \[/.test(l)).length, 44, 'every active memory');
  const byId = (id: string) => h.db.rows('coach_memory_items').find((m) => m.id === id);
  assertEquals([byId(older.id).content, byId(older.id).confirmations, byId(older.id).retired_at], ['User runs 5 days a week, mostly easy', 2, null], 'the oldest row is kept');
  assertEquals(byId(newer.id).retired_reason, 'merged');
  assertEquals(byId(oat.id).retired_reason, 'duplicate');
  assertEquals(h.db.activeMemories().length, 42, 'invented merges and uncovered retires are refused');
  const state = h.db.rows('coach_user_state').find((s) => s.user_id === USER);
  assert(state.consolidated_at && !state.consolidation_until);

  // Consolidated recently and under 120 rows: not claimed again (and, 40 minutes on, no pair is fresh enough for a
  // targeted pass either).
  h.db.message(USER, t.id, 'user', 'And another thing', { created_at: at(40) });
  clockAt(h, 41);
  assertEquals((await maintain(h, t.id)).body.consolidated, false);
  assertEquals(h.model.of('consolidation').length, 1);
  assertEquals((await h.json(`threads/${t.id}/maintain`, { method: 'POST', token: 'noop_other' })).status, 404);
  assert(!h.db.rows('coach_memory_items').some((m) => m.user_id === OTHER));
});

// ------------------------------------------------------------------------------------------------
// Review fixes
// ------------------------------------------------------------------------------------------------

/** Letters-only words unique to `i`, so seeded memories never look alike. */
const tag = (i: number) => `${'abcdefghijklmnopqrstuvwxyz'[i % 26]}${'abcdefghijklmnopqrstuvwxyz'[Math.floor(i / 26) % 26]}`;
const distinct = (i: number) => `User likes ${tag(i)}x ${tag(i)}w ${tag(i)}z`;
const applied = (h: Harness) => h.db.rpcCalls.filter((c) => c.name === 'coach_memory_apply_v1' || c.name === 'coach_thread_publish_v1')
  .flatMap((c) => c.args.p_ops ?? []);

Deno.test('coach maintain: a forget-all or a forget that lands while the curator runs is honoured (finding 6)', async () => {
  let during: () => Promise<unknown> = async () => {};
  const h = await harness({
    curator: async () => {
      await during();
      return summaryReply('The user is training for the Berlin marathon on 2027-04-25.', {
        memory_ops: [{ op: 'add', topic: 'goal', importance: 4, content: 'User is training for the Berlin marathon on 2027-04-25' }],
      });
    },
  });
  clockAt(h, 0);
  h.db.memory(USER, 'User likes oat milk', { topic: 'preference' });
  const t = seed(h, [['user', 'I am training for the Berlin marathon on 2027-04-25'], ['assistant', 'Great, let us plan it.']]);
  clockAt(h, 2);
  during = () => h.json('memories', { method: 'DELETE' });
  const res = (await maintain(h, t.id)).body;
  assertEquals([res.status, res.summarized, res.memoryOps], ['done', true, 0]);
  assertEquals(h.db.activeMemories(), [], 'nothing mined before Forget all comes back');
  const row = h.db.threadRow(t.id);
  assertEquals([row.summary, row.curated_through], ['The user is training for the Berlin marathon on 2027-04-25.', null], 'the summary lands, curation does not');
  const thread = (await h.json(`threads/${t.id}`)).body.thread;
  assertEquals([thread.pendingMessages, thread.needsMaintenance], [0, false], 'messages older than the floor are not maintenance');
  during = async () => {};
  assertEquals((await maintain(h, t.id)).body.status, 'skipped', 'the floor keeps them out of the next pass');
  assertEquals(h.db.activeMemories(), []);

  // A single forget: the curator words the fact under another topic, so the stale pool would not catch it.
  let forget: () => Promise<unknown> = async () => {};
  const g = await harness({
    curator: async () => {
      await forget();
      return { memory_ops: [{ op: 'add', topic: 'training', importance: 4, content: 'User has a sore left knee since 2026-09-20' }] };
    },
  });
  clockAt(g, 0);
  const knee = g.db.memory(USER, 'User has a sore left knee since 2026-09-20', { topic: 'injury', importance: 4 });
  const u = seed(g, [['user', 'My left knee has been sore since 2026-09-20']]);
  clockAt(g, 1);
  forget = () => g.json(`memories/${knee.id}`, { method: 'DELETE' });
  assertEquals((await maintain(g, u.id)).body.memoryOps, 0);
  assertEquals(g.db.activeMemories(), []);
  assertEquals(g.db.threadRow(u.id).curated_through, null);
  forget = async () => {};
  const again = (await maintain(g, u.id)).body;
  assertEquals([again.status, again.memoryOps], ['done', 0], 'mined again, now against the tombstone');
  assertEquals(g.db.activeMemories(), []);
});

Deno.test('coach maintain: above 120 memories consolidation waits for 6 hours or 8 changed memories (finding 7)', async () => {
  const h = await harness({
    curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user kept sharing thoughts.') : { memory_ops: [] }),
    consolidation: { ops: [] },
  });
  clockAt(h, 0);
  for (let i = 0; i < 130; i++) h.db.memory(USER, distinct(i), { topic: 'preference', importance: 2 });
  const t = h.db.thread(USER, { summary: 'An earlier summary.', summary_through: at(0), curated_through: at(0), summary_messages: 1 });
  h.db.message(USER, t.id, 'user', 'old', { created_at: at(0) });
  let minute = 1;
  const turn = async () => {
    h.db.message(USER, t.id, 'user', `Another thought number ${tag(minute)}x`, { created_at: new Date(h.db.clock + 1_000).toISOString() });
    h.db.advance(2_000);
    minute++;
    return (await maintain(h, t.id)).body.consolidated;
  };
  assertEquals(await turn(), true, 'the first pass is due');
  for (let i = 0; i < 3; i++) assertEquals(await turn(), false, 'nothing changed since: not again');
  assertEquals(h.model.of('consolidation').length, 1);
  for (let i = 0; i < 8; i++) h.db.memory(USER, distinct(200 + i), { topic: 'preference', importance: 2 });
  assertEquals(await turn(), true, 'eight new memories');
  assertEquals(await turn(), false);
  h.db.advance(6 * 3_600_000);
  assertEquals(await turn(), true, 'six hours later');
  assertEquals(h.model.of('consolidation').length, 3);
});

Deno.test('coach followups: a title asked for before the first save lands comes back as titlePending (finding 18)', async () => {
  const h = await harness({ followups: { follow_ups: ['How should I pace my long run?'], title: 'Never Stored' }, title: { title: 'Taper Plan' } });
  const id = uuid();
  const body = { threadId: id, question: 'How do I taper?', answer: 'Cut volume by a third.', wantTitle: true };
  const res = await h.json('followups', { method: 'POST', body });
  assertEquals(res.body, { followUps: ['How should I pace my long run?'], titlePending: true });
  assert(!h.model.of('followups')[0].system.includes('"title"'), 'no title is asked of the model yet');
  assertEquals(h.db.threadRow(id), undefined);
  // Once the rows are saved the phone asks once, and the first-words title is replaced.
  await h.json('messages', { method: 'POST', body: { messages: [{ clientId: uuid(), threadId: id, role: 'user', content: 'How do I taper?', createdAt: at(0), threadTitle: 'How do I taper' }] } });
  assertEquals((await h.json(`threads/${id}/title`, { method: 'POST', body: { question: body.question, answer: body.answer } })).body,
    { title: 'Taper Plan', titleSource: 'auto', generated: true });
  // A saved thread, no wantTitle, or no threadId: no flag.
  assert(!('titlePending' in (await h.json('followups', { method: 'POST', body })).body));
  assert(!('titlePending' in (await h.json('followups', { method: 'POST', body: { ...body, threadId: uuid(), wantTitle: false } })).body));
  assert(!('titlePending' in (await h.json('followups', { method: 'POST', body: { question: 'q here?', answer: 'An answer.', wantTitle: true } })).body));
});

Deno.test('coach suggestions: forgetting one memory drops the cached starters that may quote it (findings 19, 36)', async () => {
  const h = await harness({ suggestions: { suggestions: [{ text: 'Plan lactose-free meals for this week', kind: 'goal' }] } });
  const pref = (await h.json('memories', { method: 'POST', body: { content: 'User is lactose intolerant', topic: 'preference', importance: 3 } })).body.memory;
  const body = { state: { dayPart: 'morning' }, fallback: ['How did I sleep?'] };
  assertEquals((await h.json('suggestions', { method: 'POST', body })).body.source, 'model');
  assertEquals((await h.json('suggestions', { method: 'POST', body })).body.source, 'cache');
  const state = () => h.db.rows('coach_user_state').find((r) => r.user_id === USER);
  const revision = state().memory_revision;
  await h.json(`memories/${pref.id}`, { method: 'DELETE' });
  assertEquals([state().suggestions, state().suggestions_fingerprint, state().suggestions_at], [[], null, null]);
  assertEquals(state().memory_revision, revision + 1, 'every change the user makes moves the revision, so other phones drop their cached context');
  assertEquals((await h.json('suggestions', { method: 'POST', body })).body.source, 'model');
  assert(!h.model.of('suggestions')[1].user.includes('lactose'));
  // Forgetting an id that is not there leaves the cache alone.
  await h.json(`memories/${uuid()}`, { method: 'DELETE' });
  assertEquals((await h.json('suggestions', { method: 'POST', body })).body.source, 'cache');
});

Deno.test('coach consolidation: a merge never strips the safety pin or lowers importance; ops carry versions (findings 24, I3)', () => {
  const rows = [
    { id: 'acl', content: 'User tore the left ACL on 2026-03-02', topic: 'injury', importance: 5, created_at: '2026-03-02T00:00:00Z', version: 1 },
    { id: 'rehab', content: 'User does knee rehab twice a week', topic: 'routine', importance: 3, created_at: '2026-04-01T00:00:00Z', version: 3 },
    { id: 'oat', content: 'User likes oat milk', topic: 'preference', importance: 2, created_at: '2026-04-01T00:00:00Z', version: 1 },
    { id: 'oat2', content: 'User likes oat milk in coffee', topic: 'preference', importance: 2, created_at: '2026-05-01T00:00:00Z', version: 2 },
  ];
  const refs = new Refs('m');
  rows.forEach((r) => refs.ref(r.id));
  const content = 'User tore the left ACL on 2026-03-02 and does knee rehab twice a week';
  for (const topic of ['training', 'injuries', undefined]) {
    const [merge] = resolveConsolidationOps([{ op: 'merge', refs: ['m1', 'm2'], content, topic, importance: 3 }], refs, rows);
    assertEquals([merge.keep_id, merge.ids, merge.topic, merge.importance, merge.versions], ['acl', ['rehab'], 'injury', 5, { acl: 1, rehab: 3 }], String(topic));
  }
  assertEquals(mergedAttributes({ topic: 'health', importance: 1 }, rows.slice(0, 2), rows[0]), { topic: 'health', importance: 5 });
  assertEquals(mergedAttributes({ topic: 'lifestyle', importance: 1 }, rows.slice(2), rows[2]), { topic: 'lifestyle', importance: 2 });
  assertEquals(mergedAttributes({ topic: 'bogus' }, rows.slice(2), rows[2]), { topic: 'preference', importance: 2 });
  const [retire] = resolveConsolidationOps([{ op: 'retire', ref: 'm3', reason: 'duplicate' }], refs, rows);
  assertEquals([retire.op, retire.id, retire.expect_version], ['retire', 'oat', 1]);
});

Deno.test('coach maintain: a merge or retire against memories that changed meanwhile is stale and changes nothing (I3)', async () => {
  let row: any;
  const h = await harness({
    curator: { memory_ops: [] },
    consolidation: (c: ModelCall) => {
      // Another writer (a tool save) updates one member while the model is thinking.
      const stored = h.db.rows('coach_memory_items').find((m) => m.id === row.id);
      Object.assign(stored, { content: 'User runs 6 days a week now', version: stored.version + 1 });
      return { ops: [{ op: 'merge', refs: [refOf(c, 'runs five days'), refOf(c, 'runs 5 days')], content: 'User runs 5 days a week' }] };
    },
  });
  clockAt(h, 0);
  h.db.memory(USER, 'User runs five days a week', { topic: 'training', created_at: '2026-01-01T00:00:00Z' });
  row = h.db.memory(USER, 'User runs 5 days a week, mostly easy', { topic: 'training' });
  for (let i = 0; i < 40; i++) h.db.memory(USER, distinct(i), { importance: 1 });
  const t = seed(h, [['user', 'Thanks for the plan'], ['assistant', 'Any time.']], { summary: 'An earlier summary.', summary_through: at(-1), curated_through: at(-1) });
  clockAt(h, 2);
  assertEquals((await maintain(h, t.id)).body.consolidated, true);
  const merge = applied(h).find((o: any) => o.op === 'merge');
  assertEquals(Object.keys(merge.versions).length, 2);
  assertEquals(h.db.activeMemories().filter((m) => m.topic === 'training').map((m) => m.content).sort(), ['User runs 6 days a week now', 'User runs five days a week']);
  assert(h.db.rows('coach_memory_events').every((e) => e.op !== 'merge'), 'the whole merge was refused as stale');
});

Deno.test('coach maintain: the curator merges a memory the tool saved in this chat into the older copy (I10)', async () => {
  let shown: ModelCall | undefined;
  const merged = 'User had left knee pain on long runs; a physio found mild IT band irritation and the knee no longer hurts';
  const h = await harness({
    curator: (c: ModelCall) => {
      shown = c;
      return summaryReply('The user saw a physio about the knee.', {
        memory_ops: [{ op: 'merge', refs: [refOf(c, 'saw a physio'), refOf(c, 'left knee pain')], content: merged, topic: 'training', importance: 3 }],
      });
    },
  });
  clockAt(h, 0);
  const old = h.db.memory(USER, 'User has left knee pain on long runs', { topic: 'injury', importance: 4, source: 'curator', created_at: '2026-09-20T00:00:00Z' });
  h.db.memory(USER, 'User likes oat milk', { topic: 'preference' });
  const t = seed(h, [['user', 'Saw a physio: mild IT band irritation, my knee no longer hurts.'], ['assistant', 'Good news.']]);
  const tool = h.db.memory(USER, 'User saw a physio: mild IT band irritation in the left knee, which no longer hurts',
    { topic: 'injury', importance: 4, source: 'tool', source_thread_id: t.id });
  clockAt(h, 2);
  const res = (await maintain(h, t.id)).body;
  assertEquals(res.memoryOps, 1);
  assert(/^Saved during this chat:\nm1 \[injury, importance 4\] User saw a physio[^\n]*\nSaved earlier:\nm2 /m.test(shown!.user), shown!.user);
  assert(shown!.system.includes('"op":"merge"') && shown!.system.includes('merge them'));
  const byId = (id: string) => h.db.rows('coach_memory_items').find((m) => m.id === id);
  assertEquals([byId(old.id).content, byId(old.id).topic, byId(old.id).importance, byId(old.id).version, byId(old.id).retired_at], [merged, 'injury', 4, 2, null],
    'kept in the older row, still pinned as an injury');
  assertEquals(byId(tool.id).retired_reason, 'merged');
  assertEquals(applied(h).find((o: any) => o.op === 'merge').versions, { [old.id]: 1, [tool.id]: 1 });
  assertEquals(h.db.activeMemories().filter((m) => m.topic === 'injury').length, 1);
});

Deno.test('coach maintain: an update that restates a memory the tool saved in this chat becomes a merge (simulator run)', async () => {
  // The real model updated the old injury memory and left the tool's copy beside it.
  const h = await harness({
    curator: (c: ModelCall) => ({ memory_ops: [{ op: 'update', ref: refOf(c, 'left knee pain'), content: 'User saw a physio for mild IT band irritation in the left knee, which no longer hurts' }] }),
  });
  clockAt(h, 0);
  const old = h.db.memory(USER, 'User has left knee pain on long runs', { topic: 'injury', importance: 4, source: 'curator', created_at: '2026-09-20T00:00:00Z' });
  const t = seed(h, [['user', 'Saw a physio: mild IT band irritation in the left knee, it no longer hurts. I run 5 days a week at 6am.']]);
  const tool = h.db.memory(USER, 'User saw a physio: mild IT band irritation in the left knee, which no longer hurts',
    { topic: 'injury', importance: 4, source: 'tool', source_thread_id: t.id });
  const routine = h.db.memory(USER, 'User runs 5 days a week at 6am and is training for the Berlin marathon',
    { topic: 'routine', importance: 3, source: 'tool', source_thread_id: t.id });
  clockAt(h, 1);
  assertEquals((await maintain(h, t.id)).body.memoryOps, 1);
  const injuries = h.db.activeMemories().filter((m) => m.topic === 'injury');
  assertEquals(injuries.map((m) => [m.id, m.content]), [[old.id, 'User saw a physio for mild IT band irritation in the left knee, which no longer hurts']]);
  assertEquals(h.db.rows('coach_memory_items').find((m) => m.id === tool.id).retired_reason, 'merged');
  assert(h.db.activeMemories().some((m) => m.id === routine.id), 'another family is never folded in');

  // The rule in isolation: only what the new text fully restates, only memories saved in this chat.
  const pool = [
    { id: 'o', content: 'User has left knee pain on long runs', topic: 'injury', importance: 4, version: 1, created_at: '2026-01-01T00:00:00Z' },
    { id: 'x', content: 'User has right knee pain', topic: 'injury', importance: 3, version: 1, source: 'tool', source_thread_id: 'T', created_at: '2026-02-01T00:00:00Z' },
  ];
  const refs = new Refs('m');
  pool.forEach((p) => refs.ref(p.id));
  const text = 'I have left knee pain on long runs and on hills';
  const guard = { userTokens: tokenSet(text), userText: text, tombstones: [] };
  const ops = resolveCuratorOps([{ op: 'update', ref: 'm1', content: 'User has left knee pain on long runs and on hills' }], refs, structuredClone(pool), guard, 'T');
  assertEquals(ops, [{ op: 'update', id: 'o', content: 'User has left knee pain on long runs and on hills', expect_version: 1 }]);
});

Deno.test('coach maintain: two memories that look alike get a targeted consolidation, at most once per 30 minutes (I10)', async () => {
  let dedupe: ModelCall | undefined;
  const h = await harness({
    curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user described a running routine.') : { memory_ops: [] }),
    consolidation: (c: ModelCall) => {
      dedupe = c;
      return { ops: [{ op: 'merge', refs: [refOf(c, 'before work'), refOf(c, 'at 6am$')], content: 'User runs 5 days a week at 6am before work' }] };
    },
  });
  clockAt(h, 0);
  const older = h.db.memory(USER, 'User runs 5 days a week at 6am', { topic: 'routine', source: 'curator', created_at: '2026-09-01T00:00:00Z', updated_at: '2026-09-01T00:00:00Z' });
  for (let i = 0; i < 5; i++) h.db.memory(USER, distinct(i), { created_at: '2026-09-01T00:00:00Z', updated_at: '2026-09-01T00:00:00Z' });
  const t = seed(h, [['user', 'I run 5 days a week at 6am before work'], ['assistant', 'Nice routine.']]);
  const tool = h.db.memory(USER, 'User runs 5 days a week at 6am before work', { topic: 'routine', source: 'tool', source_thread_id: t.id });
  clockAt(h, 2);
  assertEquals((await maintain(h, t.id)).body.consolidated, true);
  assert(dedupe!.system.includes('look alike'));
  assertEquals(dedupe!.user.split('\n').filter((l) => /^m\d+ \[/.test(l)).length, 2, 'only the pair');
  assertEquals(h.db.activeMemories().filter((m) => m.topic === 'routine').map((m) => [m.id, m.content]), [[older.id, 'User runs 5 days a week at 6am before work']]);
  assertEquals(h.db.rows('coach_memory_items').find((m) => m.id === tool.id).retired_reason, 'merged');
  const lease = h.db.rows('coach_user_state').find((s) => s.user_id === USER).consolidation_until;
  assertEquals(Date.parse(lease), h.db.clock + 30 * 60_000);

  // Another fresh pair inside the 30 minutes waits; after them it is reviewed.
  h.db.memory(USER, 'User swims 2 days a week at the lake', { topic: 'routine', source: 'tool', source_thread_id: t.id });
  h.db.memory(USER, 'User swims 2 days a week at the lake in summer', { topic: 'routine' });
  h.db.message(USER, t.id, 'user', 'I swim 2 days a week at the lake', { created_at: at(3) });
  clockAt(h, 4);
  assertEquals((await maintain(h, t.id)).body.consolidated, false);
  assertEquals(h.model.of('consolidation').length, 1);
  h.db.message(USER, t.id, 'user', 'Mostly in summer', { created_at: at(33) });
  clockAt(h, 34);
  await maintain(h, t.id);
  assertEquals(h.model.of('consolidation').length, 2);

  // Only pairs with a fresh member are offered, so a pair the model left alone is not offered again.
  const rows = [
    { id: 'a', content: 'User has a tight left hamstring', topic: 'injury' },
    { id: 'b', content: 'User has a tight right hamstring', topic: 'injury' },
    { id: 'c', content: 'User likes oat milk', topic: 'preference' },
  ];
  assertEquals(duplicatePairs(rows, () => false), []);
  assertEquals(duplicatePairs(rows, (m) => m.id === 'b').map((m) => m.id).sort(), ['a', 'b']);
});

// ------------------------------------------------------------------------------------------------
// Memories in the user's own words (edited or added in the memory sheet)
// ------------------------------------------------------------------------------------------------

Deno.test('coach maintain: a memory in the user\'s own words is confirmed but never reworded, merged or retired; an edit\'s old wording is not learned again', async () => {
  let shown: ModelCall | undefined;
  const h = await harness({
    curator: (c: ModelCall) => {
      shown = c;
      const swim = refOf(c, 'swims on Thursdays');
      const goal = refOf(c, 'marathon goal');
      return {
        memory_ops: [
          { op: 'add', topic: 'routine', importance: 3, content: 'User swims on Tuesdays' },
          { op: 'add', topic: 'goal', importance: 4, content: "User's marathon goal is 3:30" },
          { op: 'update', ref: goal, content: "User's marathon goal is 3:30" },
          { op: 'retire', ref: swim, reason: 'User said Tuesdays' },
          { op: 'merge', refs: [swim, refOf(c, 'lake swims')], content: 'User swims on Thursdays at the lake' },
          { op: 'add', topic: 'routine', importance: 3, content: 'User swims on Thursdays at the lake' },
          { op: 'update', ref: goal, importance: 5 },
        ],
      };
    },
  });
  clockAt(h, 0);
  // The user changed Tuesdays to Thursdays in the memory sheet, and wrote the goal themselves.
  const swim = (await h.json('memories', { method: 'POST', body: { content: 'User swims on Tuesdays', topic: 'routine' } })).body.memory;
  assertEquals((await h.json(`memories/${swim.id}`, { method: 'PATCH', body: { content: 'User swims on Thursdays', version: 1 } })).status, 200);
  const goal = h.db.memory(USER, "User's marathon goal is 3:45", { topic: 'goal', importance: 3, source: 'user' });
  const lake = h.db.memory(USER, 'User enjoys lake swims in summer', { topic: 'routine', source: 'curator' });
  // A chat that still says the old day (an older message the curator reads again, say) and a new goal time.
  const t = seed(h, [['user', 'I swim on Tuesdays and on Thursdays at the lake. My marathon goal is 3:30 now, and lake swims are my favourite.']]);
  clockAt(h, 1);

  const res = (await maintain(h, t.id)).body;
  assertEquals(res.memoryOps, 2, 'the confirm and the importance change; every rewording was dropped');
  assert(shown && refOf(shown, 'swims on Thursdays') && !shown.user.includes('Tuesdays\n'), 'the prompt shows the edited text');
  const byId = (id: string) => h.db.rows('coach_memory_items').find((m) => m.id === id);
  assertEquals([byId(swim.id).content, byId(swim.id).source, byId(swim.id).confirmations, byId(swim.id).retired_at],
    ['User swims on Thursdays', 'user', 2, null], 'a restatement that says more confirms the user\'s row');
  assertEquals([byId(goal.id).content, byId(goal.id).importance, byId(goal.id).source], ["User's marathon goal is 3:45", 5, 'user'],
    'only its importance moved');
  assertEquals([byId(lake.id).retired_at, byId(lake.id).content], [null, 'User enjoys lake swims in summer'], 'never merged into the user\'s row');
  assert(!h.db.activeMemories().some((m) => /Tuesdays/.test(m.content)), 'the old wording is not learned again');
  assertEquals(h.db.activeMemories().length, 3);
  assert(!applied(h).some((o: any) => o.op === 'retire' || o.op === 'merge'));
});

Deno.test('coach curator and consolidation: ops on a row in the user\'s own words (the rule in isolation)', () => {
  const pool = [
    { id: 'u', content: 'User runs 5 days a week at 6am', topic: 'routine', importance: 3, version: 2, source: 'user', created_at: '2026-01-01T00:00:00Z' },
    { id: 'c', content: 'User runs 5 days a week at 6am before work', topic: 'routine', importance: 3, version: 1, source: 'curator', created_at: '2026-02-01T00:00:00Z' },
    { id: 'k', content: 'User has a tight left hamstring', topic: 'injury', importance: 4, version: 1, source: 'tool', source_thread_id: 'T', created_at: '2026-03-01T00:00:00Z' },
  ];
  const refs = new Refs('m');
  pool.forEach((p) => refs.ref(p.id));
  const text = 'I run 5 days a week at 6am before work, now 6 days. My left hamstring is tight.';
  const guard = { userTokens: tokenSet(text), userText: text, tombstones: [] };
  const ops = resolveCuratorOps([
    { op: 'update', ref: 'm1', content: 'User runs 6 days a week at 6am' },
    { op: 'merge', refs: ['m1', 'm2'], content: 'User runs 5 days a week at 6am before work' },
    { op: 'retire', ref: 'm1', reason: 'now 6 days' },
    { op: 'add', topic: 'routine', importance: 3, content: 'User runs 6 days a week at 6am' },
    { op: 'update', ref: 'm1', importance: 4 },
  ], refs, structuredClone(pool), guard, 'T');
  assertEquals(ops, [{ op: 'update', id: 'u', importance: 4, expect_version: 2 }]);
  // An update of another row never folds the user's row into a merge.
  const fold = resolveCuratorOps([{ op: 'update', ref: 'm2', content: 'User runs 5 days a week at 6am before work, now on trails' }],
    refs, structuredClone(pool).map((p) => (p.id === 'u' ? { ...p, source_thread_id: 'T' } : p)), guard, 'T');
  assertEquals(fold.map((o) => [o.op, o.id]), [['update', 'c']]);
  // Consolidation: no merge or retire of the user's row; it may still be what covers a retired duplicate.
  const consolidation = resolveConsolidationOps([
    { op: 'merge', refs: ['m1', 'm2'], content: 'User runs 5 days a week at 6am before work' },
    { op: 'retire', ref: 'm1', reason: 'duplicate' },
    { op: 'retire', ref: 'm2', reason: 'duplicate' },
  ], refs, pool);
  assertEquals(consolidation.map((o) => [o.op, o.id]), [['retire', 'c']]);
});

Deno.test('coach maintain: consolidation leaves a row in the user\'s own words alone and retires the copy it covers', async () => {
  const h = await harness({
    curator: { memory_ops: [] },
    consolidation: (c: ModelCall) => ({
      ops: [
        { op: 'merge', refs: [refOf(c, 'oat milk$'), refOf(c, 'oat milk in coffee')], content: 'User likes oat milk in coffee' },
        { op: 'retire', ref: refOf(c, 'oat milk$'), reason: 'duplicate' },
        { op: 'retire', ref: refOf(c, 'oat milk in coffee'), reason: 'duplicate' },
      ],
    }),
  });
  clockAt(h, 0);
  const mine = h.db.memory(USER, 'User likes oat milk', { topic: 'preference', source: 'user', created_at: '2026-01-01T00:00:00Z' });
  const copy = h.db.memory(USER, 'User likes oat milk in coffee', { topic: 'preference', source: 'curator' });
  for (let i = 0; i < 40; i++) h.db.memory(USER, distinct(i), { importance: 1 });
  const t = seed(h, [['user', 'Thanks for the plan'], ['assistant', 'Any time.']], { summary: 'An earlier summary.', summary_through: at(-1), curated_through: at(-1) });
  clockAt(h, 2);
  assertEquals((await maintain(h, t.id)).body.consolidated, true);
  const byId = (id: string) => h.db.rows('coach_memory_items').find((m) => m.id === id);
  assertEquals([byId(mine.id).content, byId(mine.id).retired_at, byId(mine.id).version], ['User likes oat milk', null, 1]);
  assertEquals(byId(copy.id).retired_reason, 'duplicate');
});
