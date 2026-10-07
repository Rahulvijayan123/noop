// The cheap-model side calls (docs/COACH_MEMORY.md §5): titles, follow-ups, starter suggestions, and per-thread
// maintenance (rolling summary + memory curation, then consolidation), over the in-memory fake and a scripted model.
import { assert, assertEquals } from 'jsr:@std/assert';
import { curatorLine, keywordFollowUps, maintenanceBatches, validFollowUps } from '../_shared/coach_curator.ts';
import { iso, memoryTokens } from '../_shared/coach_llm.ts';
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

  const cached = await h.json('suggestions', { method: 'POST', body: { state, fallback } });
  assertEquals(cached.body, { ...first.body, source: 'cache' });
  assertEquals(h.model.calls.length, 1);

  // Anything in the fingerprint moves it: refresh, state, locale, a revising memory change, chat activity, the 12 h TTL.
  await h.json('suggestions', { method: 'POST', body: { state, fallback, refresh: true } });
  assertEquals(h.model.calls.length, 2);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, charge: 'green' }, fallback } });
  assertEquals(h.model.calls.length, 3);
  await h.json('memories', { method: 'POST', body: { content: 'User tore an ACL in 2024', topic: 'injury', importance: 5 } });
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, charge: 'green' }, fallback } });
  assertEquals(h.model.calls.length, 4);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, charge: 'green' }, fallback } });
  assertEquals(h.model.calls.length, 4, 'cached again');
  h.db.advance(13 * 3_600_000);
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, charge: 'green' }, fallback } });
  assertEquals(h.model.calls.length, 5, 'older than 12 h');
  h.db.message(USER, sleep.id, 'user', 'One more', { created_at: at(600) });
  await h.json('suggestions', { method: 'POST', body: { state: { ...state, charge: 'green' }, fallback } });
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

Deno.test('coach maintain: memory ops need a new user message; the summary needs 4 new messages (2 for the first)', async () => {
  const h = await harness({ curator: (c: ModelCall) => (c.system.includes('"summary"') ? summaryReply('The user and Sana kept talking about training.') : { memory_ops: [] }) });
  const summarised = { summary: 'Earlier summary of the chat.', summary_through: at(0), curated_through: at(0), summary_messages: 1 };
  const cases: [string, Turn[], Record<string, unknown>, string][] = [
    ['three assistant messages', [['assistant', 'a'], ['assistant', 'b'], ['assistant', 'c']], summarised, 'skipped'],
    ['one user message', [['user', 'I run on Tuesdays']], summarised, 'memory'],
    ['four assistant messages', [['assistant', 'a'], ['assistant', 'b'], ['assistant', 'c'], ['assistant', 'd']], summarised, 'summary'],
    ['a lone first question', [['user', 'I run on Tuesdays']], {}, 'memory'],
    ['a first exchange', [['user', 'I run on Tuesdays'], ['assistant', 'Nice.']], {}, 'both'],
  ];
  for (const [label, turns, over, expected] of cases) {
    const t = h.db.thread(USER, over);
    if (over.summary) h.db.message(USER, t.id, 'user', 'old message', { created_at: at(0) });
    turns.forEach(([role, content], i) => h.db.message(USER, t.id, role, content, { created_at: at(10 + i) }));
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
  await maintain(h, t.id);
  assertEquals(iso(h.db.threadRow(t.id).curated_through), at(11));
  assertEquals((await h.json(`threads/${t.id}`)).body.thread.pendingMessages, 2, 'two new messages wait for the next summary');
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
  const older = h.db.memory(USER, 'User runs five days a week', { topic: 'training', created_at: '2026-01-01T00:00:00Z' });
  const newer = h.db.memory(USER, 'User runs 5 days a week, mostly easy', { topic: 'training', created_at: '2026-05-01T00:00:00Z' });
  const oat = h.db.memory(USER, 'User likes oat milk', { topic: 'preference' });
  h.db.memory(USER, 'User likes oat milk in coffee', { topic: 'preference' });
  for (let i = 0; i < 40; i++) h.db.memory(USER, `Filler fact ${'abcdefghij'[i % 10]}${'abcdefghij'[Math.floor(i / 10)]}q`, { importance: 1 });
  const t = h.db.thread(USER, { summary: 'An earlier summary.', summary_through: at(0), curated_through: at(0) });
  h.db.message(USER, t.id, 'user', 'old', { created_at: at(0) });
  h.db.message(USER, t.id, 'user', 'Thanks for that', { created_at: at(1) });

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

  // Consolidated recently and under 120 rows: not claimed again.
  h.db.message(USER, t.id, 'user', 'And another thing', { created_at: at(2) });
  assertEquals((await maintain(h, t.id)).body.consolidated, false);
  assertEquals(h.model.of('consolidation').length, 1);
  assertEquals((await h.json(`threads/${t.id}/maintain`, { method: 'POST', token: 'noop_other' })).status, 404);
  assert(!h.db.rows('coach_memory_items').some((m) => m.user_id === OTHER));
});
