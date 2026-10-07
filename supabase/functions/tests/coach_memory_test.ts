// Durable memories (docs/COACH_MEMORY.md §3-§4) and the deterministic rules of §6 they are held to.
import { assert, assertEquals } from 'jsr:@std/assert';
import {
  clip, containment, fallbackTitle, findNearDuplicate, guardMemoryContent, isSensitive, jaccard, memoryTokens, nearDuplicate,
  parseJsonReply, Refs, sameFamily, sanitizeTitle, tokenSet, tsKey, windowBound,
} from '../_shared/coach_llm.ts';
import { harness, OTHER, USER } from './coach_fake.ts';

const save = (h: any, body: unknown, token = 'noop_personal') => h.json('memories', { method: 'POST', body, token });

Deno.test('memory tokens: numbers and dates always kept, stop words dropped, light stemming, negations kept', () => {
  assertEquals(memoryTokens('User runs 5k on 2026-10-07 at 6:30'), ['run', '5', '2026-10-07', '6:30']);
  assertEquals(new Set(memoryTokens('Running races')), new Set(memoryTokens('runs a race')));
  assertEquals(new Set(memoryTokens('hamstrings')), new Set(memoryTokens('hamstring')));
  assertEquals(memoryTokens('The user is in it'), []);
  assert(memoryTokens("User doesn't eat meat").includes('not'));
  assert(!tokenSet('User eats meat').has('not'));
  assertEquals(memoryTokens('Marathon on 3 May'), ['marathon', '3', 'may']);
  assertEquals(memoryTokens('User may run'), ['run'], '"may" is a month only next to a number');
  assertEquals(memoryTokens('ＦＵＬＬ　ｗｉｄｔｈ'), ['full', 'width'], 'NFKC first');
});

Deno.test('near-duplicates: same, number-aware supersede, longer, covered, and distinct facts', () => {
  assertEquals(nearDuplicate('has a TIGHT left hamstring', 'Has a tight left hamstring'), 'same');
  assertEquals(nearDuplicate("User's marathon goal is 3:30", "User's marathon goal is 3:45"), 'supersede');
  assertEquals(nearDuplicate('User trains for a marathon on 3 May 2027', 'User trains for a marathon on 12 April 2027'), 'supersede');
  assertEquals(nearDuplicate('User is vegetarian and avoids eggs at breakfast', 'User is vegetarian'), 'longer');
  assertEquals(nearDuplicate('User is vegetarian', 'User is vegetarian and avoids eggs at breakfast'), 'covered');
  // Saying less never overwrites a figure: no numbers in the new text means it is covered by the old row.
  assertEquals(nearDuplicate('User has a marathon goal time', "User's marathon goal time is 3:45"), 'covered');
  assertEquals(nearDuplicate('User does not eat meat', 'User eats meat'), 'supersede');
  assertEquals(nearDuplicate('User eats meat again', 'User does not eat meat again'), 'supersede');
  assertEquals(nearDuplicate('User swims on Mondays', 'User has a tight hamstring'), null);
  assertEquals(jaccard(new Set(['a', 'b']), new Set(['b', 'c'])), 1 / 3);
  assertEquals(containment(new Set(['a', 'b']), new Set(['a', 'b', 'c', 'd'])), 1);
  assert(sameFamily('goal', 'training') && sameFamily('injury', 'health') && sameFamily('sleep', 'nutrition'));
  assert(!sameFamily('goal', 'injury') && sameFamily('general', 'injury') && sameFamily('goal', 'general'));
  const pool = [
    { id: 'a', content: 'User has a tight left hamstring', topic: 'injury' },
    { id: 'b', content: 'User has a tight left hamstring', topic: 'goal' },
  ];
  assertEquals(findNearDuplicate('User has a tight left hamstring', 'health', pool)?.row.id, 'a', 'within the topic family only');
  assertEquals(findNearDuplicate('User has a tight left hamstring', 'preference', pool), null);
});

Deno.test('curator guards: grounding, transient phrasing, metric readings, sensitive facts, tombstones', () => {
  const userText = 'I have a tight left hamstring and I want to run a marathon in April';
  const ctx = { userTokens: tokenSet(userText), userText, tombstones: [tokenSet('User has a dog named Max')] };
  assertEquals(guardMemoryContent('User has a tight left hamstring', ctx), null);
  assertEquals(guardMemoryContent('User should foam roll every evening', ctx), 'ungrounded');
  assertEquals(guardMemoryContent('User has a tight hamstring today', ctx), 'transient');
  assertEquals(guardMemoryContent('User wants to run a marathon right now', ctx), 'transient');
  assertEquals(guardMemoryContent('User has a hamstring and a resting HR of 52 bpm', { ...ctx, userTokens: tokenSet('hamstring resting 52 bpm') }), 'transient');
  assertEquals(guardMemoryContent('User marathon effort at 80%', { ...ctx, userTokens: tokenSet('marathon effort 80') }), 'transient');
  const personal = { ...ctx, userText: 'my wife Sarah runs too', userTokens: tokenSet('my wife Sarah runs too') };
  assertEquals(guardMemoryContent("User's wife Sarah runs", personal), 'sensitive');
  assertEquals(guardMemoryContent("User's wife Sarah runs", { ...personal, userText: 'please remember my wife Sarah runs too' }), null);
  assert(isSensitive('User is reachable at sam@example.com') && isSensitive('Call 415 555 1234'));
  assert(!isSensitive('User raced on 2026-10-07 and 2026-10-14'), 'ISO dates are not phone numbers');
  assert(isSensitive('User has been bingeing and purging'));
  const dog = { ...ctx, userText: 'I have a dog named Max', userTokens: tokenSet('I have a dog named Max'), tombstones: [tokenSet('User has a dog named Max')] };
  assertEquals(guardMemoryContent('User has a dog', { ...dog, userText: 'remember I have a dog' }), 'forgotten');
});

Deno.test('model replies and strings: JSON extraction, titles, refs, timestamps, windows', () => {
  assertEquals(parseJsonReply('<think>hmm {"no": 1}</think>```json\n{"title": "A"}\n```'), { title: 'A' });
  assertEquals(parseJsonReply('Sure! Here it is: {"a": {"b": "}"}} trailing'), { a: { b: '}' } });
  assertEquals(parseJsonReply('<think>never closed {"x":1}'), null);
  assertEquals(parseJsonReply(42), null);
  assertEquals(sanitizeTitle('"Chat about Marathon Taper Plan!!" 🏃'), 'Marathon Taper Plan');
  assertEquals(sanitizeTitle('Question about: my HRV.'), 'My HRV');
  assertEquals(sanitizeTitle("Rahul's Knee Rehab"), "Rahul's Knee Rehab");
  assertEquals(sanitizeTitle('A really very long title that keeps going well past the limit of the sidebar'), 'A really very long title that keeps going well');
  assertEquals(sanitizeTitle('🏃‍♂️'), null);
  assertEquals(sanitizeTitle('{"title": "x"}'), null);
  assertEquals(fallbackTitle('  how should I taper before my marathon next month?'), 'How should I taper before my');
  assertEquals(fallbackTitle('🙂'), null);
  const refs = new Refs('m');
  assertEquals([refs.ref('id-a'), refs.ref('id-b'), refs.ref('id-a')], ['m1', 'm2', 'm1']);
  assertEquals([refs.resolve('m2'), refs.resolve('[M1]'), refs.resolve('t1'), refs.resolve('m9'), refs.resolve(3)], ['id-b', 'id-a', undefined, undefined, undefined]);
  assert(tsKey('2026-10-07T12:00:00.000002+00:00') > tsKey('2026-10-07T12:00:00.000001+00:00'));
  assertEquals(tsKey('2026-10-07T12:00:00Z'), Date.UTC(2026, 9, 7, 12) * 1000);
  assertEquals(windowBound('2026-08-31', true), '2026-09-01T00:00:00.000Z');
  assertEquals(windowBound('2026-02-31'), null);
  assertEquals(clip('one two three four', 10), 'one two…');
});

Deno.test('coach memories: GET keeps the original order and default limit, skips retired rows, adds optional fields', async () => {
  const h = await harness();
  for (let i = 0; i < 60; i++) h.db.memory(USER, `Fact number ${'abcdefghij'[i % 10]}${'abcdefghij'[Math.floor(i / 10)]}x`, { importance: (i % 5) + 1 });
  const retired = h.db.memory(USER, 'Old retired fact', { importance: 5, retired_at: '2026-10-01T00:00:00Z' });
  h.db.memory(OTHER, 'Theirs', { importance: 5 });
  const { body } = await h.json('memories');
  assertEquals(body.memories.length, 50);
  assert(body.memories.every((m: any, i: number, a: any[]) => i === 0 || a[i - 1].importance >= m.importance));
  assert(!body.memories.some((m: any) => m.id === retired.id || m.content === 'Theirs'));
  assertEquals(Object.keys(body.memories[0]).sort(), ['confirmations', 'content', 'createdAt', 'id', 'importance', 'source', 'topic', 'updatedAt']);
  assertEquals((await h.json('memories?limit=200')).body.memories.length, 60);
  assertEquals((await h.json('memories?limit=5000')).body.memories.length, 60);
  h.db.memory(USER, 'Knee pain on stairs', { topic: 'injury' });
  assertEquals((await h.json('memories?topic=injury')).body.memories.map((m: any) => m.content), ['Knee pain on stairs']);
  assertEquals((await h.json('memories?topic=nonsense')).body.memories, []);
});

Deno.test('coach memories: a query ranks through the RPC, safety pins first', async () => {
  const h = await harness();
  h.db.memory(USER, 'User has asthma', { topic: 'health', importance: 5 });
  h.db.memory(USER, 'User likes oat milk in coffee', { topic: 'preference', importance: 2 });
  h.db.memory(USER, 'User is training for the Berlin marathon', { topic: 'goal', importance: 4 });
  const { body } = await h.json('memories?q=marathon%20training&limit=2');
  assertEquals(body.memories.map((m: any) => [m.content, m.pinned]), [['User has asthma', true], ['User is training for the Berlin marathon', false]]);
  const call = h.db.rpcCalls.find((c) => c.name === 'coach_memories_ranked_v1')!;
  assertEquals(call.args, { p_user: USER, p_query: 'marathon training', p_limit: 2, p_pin_safety: true });
  assertEquals((await h.json('memories?q=coffee&topic=preference')).body.memories.map((m: any) => m.content), ['User likes oat milk in coffee']);
});

Deno.test('coach memories: POST dedupes against active rows (confirm, number-aware update) and otherwise adds', async () => {
  const h = await harness();
  const first = (await save(h, { content: '  Has a tight left hamstring ', topic: 'INJURY', importance: 5 })).body;
  assertEquals([first.memory.content, first.memory.topic, first.kept], ['Has a tight left hamstring', 'injury', true]);
  assertEquals(h.db.activeMemories()[0].source, 'tool');

  const again = (await save(h, { content: 'has a TIGHT left hamstring', importance: 1, topic: 'health' })).body;
  assertEquals([again.deduped, again.memory.id, again.memory.confirmations], [true, first.memory.id, 2]);
  assertEquals(h.db.activeMemories()[0].confirmations, 2);

  const goal = (await save(h, { content: "User's marathon goal is 3:45", topic: 'goal', importance: 3 })).body.memory;
  const faster = (await save(h, { content: "User's marathon goal is 3:30", topic: 'training', importance: 4, threadId: crypto.randomUUID() })).body;
  assertEquals([faster.deduped, faster.updated, faster.memory.id, faster.memory.content, faster.memory.importance], [true, true, goal.id, "User's marathon goal is 3:30", 4]);
  assertEquals(h.db.activeMemories().length, 2);
  const update = h.db.rows('coach_memory_events').find((e) => e.op === 'update')!;
  assertEquals([update.before.content, update.after.content, update.actor], ["User's marathon goal is 3:45", "User's marathon goal is 3:30", 'tool']);

  // Another topic family is a different fact; general matches every family.
  assertEquals((await save(h, { content: 'Has a tight left hamstring', topic: 'goal' })).body.kept, true);
  assertEquals((await save(h, { content: 'Has a tight left hamstring', topic: 'general' })).body.deduped, true);
  assertEquals(h.db.activeMemories().length, 3);
  assertEquals((await save(h, { content: 'Odd topic', topic: 'nonsense', importance: 99 })).body.memory, {
    ...(await h.json('memories?topic=general')).body.memories[0], importance: 5,
  });
  for (const bad of [{ content: '' }, { content: 'x'.repeat(501) }, { content: 5 }]) assertEquals((await save(h, bad)).status, 400);
});

Deno.test('coach memories: an explicit save is kept even when it matches a forgotten fact; the cap evicts the weakest', async () => {
  const h = await harness();
  const dog = (await save(h, { content: 'User has a dog named Max', topic: 'lifestyle' })).body.memory;
  await h.json(`memories/${dog.id}`, { method: 'DELETE' });
  assertEquals((await save(h, { content: 'User has a dog named Max', topic: 'lifestyle' })).body.kept, true);

  for (let i = 0; i < 199; i++) h.db.memory(USER, `Strong fact ${i} kept`, { importance: 5, topic: 'goal' });
  assertEquals(h.db.activeMemories().length, 200);
  const weak = (await save(h, { content: 'User owns a blue water bottle', topic: 'preference', importance: 1 })).body;
  assertEquals(weak.kept, false, 'past the cap the lowest score goes, here the row just saved');
  assertEquals(h.db.activeMemories().length, 200);
  const evicted = h.db.rows('coach_memory_items').find((m) => m.id === weak.memory.id)!;
  assertEquals(evicted.retired_reason, 'evict');
  assert(!(await h.json('memories?limit=200')).body.memories.some((m: any) => m.id === weak.memory.id));
});

Deno.test('coach memories: forget keeps a token tombstone without the text; forget-all resets the floor and caches', async () => {
  const h = await harness();
  const a = (await save(h, { content: 'User trains at 6:30 on weekdays', topic: 'routine' })).body.memory;
  const b = (await save(h, { content: 'User has asthma', topic: 'health', importance: 5 })).body.memory;
  await save(h, { content: 'Only mine', topic: 'general' }, 'noop_other');
  h.db.rows('coach_user_state').find((s) => s.user_id === USER).recent_searches = ['asthma'];

  assertEquals((await h.json(`memories/${a.id}`, { method: 'DELETE', token: 'noop_other' })).body, { deleted: true });
  assert(h.db.activeMemories().some((m) => m.id === a.id), "another owner's delete is a no-op");
  assertEquals((await h.json(`memories/${a.id}`, { method: 'DELETE' })).body, { deleted: true });
  const tomb = h.db.rows('coach_memory_events').find((e) => e.op === 'forget' && e.memory_id === a.id)!;
  assertEquals(tomb.tokens, memoryTokens('User trains at 6:30 on weekdays'));
  assert(!JSON.stringify(h.db.rows('coach_memory_events').filter((e) => e.memory_id === a.id)).includes('weekdays'));
  assertEquals((await h.json('memories/not-a-uuid', { method: 'DELETE' })).status, 400);

  const revision = h.db.rows('coach_user_state').find((s) => s.user_id === USER).memory_revision;
  assertEquals((await h.json('memories', { method: 'DELETE' })).body, { deleted: true });
  const state = h.db.rows('coach_user_state').find((s) => s.user_id === USER);
  assertEquals([state.recent_searches, state.suggestions, state.memory_revision > revision, Boolean(state.memory_floor_at)], [[], [], true, true]);
  assertEquals((await h.json('memories')).body.memories, []);
  assert(h.db.rows('coach_memory_events').some((e) => e.op === 'forget' && e.memory_id === b.id));
  assertEquals((await h.json('memories', { token: 'noop_other' })).body.memories.map((m: any) => m.content), ['Only mine']);
});
