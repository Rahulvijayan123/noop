// Durable memories (docs/COACH_MEMORY.md §3-§4) and the deterministic rules of §6 they are held to.
import { assert, assertEquals } from 'jsr:@std/assert';
import {
  clip, containment, covers, fallbackTitle, findNearDuplicate, guardMemoryContent, isFigureToken, isSensitive, jaccard,
  likelyDuplicates, memoryTokens, nearDuplicate, parseJsonReply, Refs, sameFamily, sanitizeTitle, tokenSet, tokensNearMatch,
  toolOverlap, tsKey, windowBound,
} from '../_shared/coach_llm.ts';
import { saveTarget } from '../_shared/coach_memory.ts';
import { harness, OTHER, USER } from './coach_fake.ts';

const save = (h: any, body: unknown, token = 'noop_personal') => h.json('memories', { method: 'POST', body, token });

Deno.test('memory tokens: numbers and dates always kept, stop words dropped, light stemming, negations kept', () => {
  assertEquals(memoryTokens('User runs 5k on 2026-10-07 at 6:30'), ['run', '5k', '2026-10-07', '6:30']);
  assertEquals(new Set(memoryTokens('Running races')), new Set(memoryTokens('runs a race')));
  assertEquals(new Set(memoryTokens('hamstrings')), new Set(memoryTokens('hamstring')));
  assertEquals(memoryTokens('The user is in it'), []);
  assert(memoryTokens("User doesn't eat meat").includes('not'));
  assert(!tokenSet('User eats meat').has('not'));
  assertEquals(memoryTokens('Marathon on 3 May'), ['marathon', '3', 'may']);
  assertEquals(memoryTokens('User may run'), ['run'], '"may" is a month only next to a number');
  assertEquals(memoryTokens('ＦＵＬＬ　ｗｉｄｔｈ'), ['full', 'width'], 'NFKC first');
});

Deno.test('memory tokens: a unit stays on its number; a distance is a word, a measurement a figure', () => {
  assertEquals(memoryTokens("User's 10K PR is 47:10"), ['10k', '47:10']);
  assertEquals(memoryTokens('400m repeats 3x a week, squat 100kg at 6am'), ['400m', 'repeat', '3x', 'week', 'squat', '100kg', '6am']);
  assertEquals(memoryTokens('Two 5ks and a 1,500 m swim'), ['two', '5k', '1,500', 'swim']);
  assertEquals(memoryTokens('half-marathon'), memoryTokens('Half Marathons'));
  assertEquals(memoryTokens('half marathon'), ['halfmarathon']);
  for (const t of ['5k', '10km', '400m', '26.2mi']) assert(!isFigureToken(t), `${t} names the event`);
  for (const t of ['100kg', '3x', '6am', '2nd', '47:10', '2026-10-07', 'april']) assert(isFigureToken(t), `${t} is a figure`);
});

Deno.test('near-duplicates: same, number-aware supersede, longer, covered, and distinct facts', () => {
  assertEquals(nearDuplicate('has a TIGHT left hamstring', 'Has a tight left hamstring'), 'same');
  assertEquals(nearDuplicate("User's marathon goal is 3:30", "User's marathon goal is 3:45"), 'supersede');
  assertEquals(nearDuplicate('User trains for a marathon on 3 May 2027', 'User trains for a marathon on 12 April 2027'), 'supersede');
  assertEquals(nearDuplicate('User has a tight left hamstring and foam rolls it', 'User has a tight left hamstring'), 'longer');
  assertEquals(nearDuplicate('User has a tight left hamstring', 'User has a tight left hamstring and foam rolls it'), 'covered');
  // A one-word memory is not "contained" in every longer sentence that uses its word.
  assertEquals(nearDuplicate('User is vegetarian and avoids eggs at breakfast', 'User is vegetarian'), null);
  assertEquals(nearDuplicate('User is vegetarian', 'User is vegetarian and avoids eggs at breakfast'), null);
  // Saying less never overwrites a figure: no numbers in the new text means it is covered by the old row.
  assertEquals(nearDuplicate('User has a marathon goal time', "User's marathon goal time is 3:45"), 'covered');
  assertEquals(nearDuplicate('User does not eat meat', 'User eats meat'), 'supersede');
  assertEquals(nearDuplicate('User eats meat again', 'User does not eat meat again'), 'supersede');
  assertEquals(nearDuplicate('User swims on Mondays', 'User has a tight hamstring'), null);
  assertEquals(nearDuplicate("User's 5k personal best is 21:50", "User's 5k personal best is 22:30"), 'supersede', 'same distance, new time');
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

Deno.test('near-duplicates: different distances are different facts, never a supersede (finding 4)', () => {
  const pairs: [string, string][] = [
    ["User's 10k personal best is 47:10", "User's 5k personal best is 22:30"],
    ['User wants to run a 10k in under 50 minutes', 'User wants to run a 5k in under 25 minutes'],
    ['User is training for a 10k race in November', 'User is training for a 5k race in November'],
    ["User's 10K PR is 47 minutes", "User's 5K PR is 22 minutes"],
    ['User does 800m repeats 3x a week', 'User does 400m repeats 3x a week'],
    ["User's half marathon personal best is 1:45:00", "User's marathon personal best is 3:50:00"],
    // Words swapped is another fact, even with most words shared.
    ['User has a torn meniscus in the right knee since 2026-03-02 and does rehab twice a week',
      'User has a torn meniscus in the left knee since 2026-03-01 and does rehab twice a week'],
  ];
  for (const [next, old] of pairs) {
    assertEquals(nearDuplicate(next, old), null, `${next} / ${old}`);
    assertEquals(nearDuplicate(old, next), null, `${old} / ${next}`);
    assert(!tokensNearMatch(tokenSet(next), tokenSet(old)), `tombstone: ${next} / ${old}`);
  }
  const pb5 = { id: 'pb5', content: "User's 5k personal best is 22:30", topic: 'achievement' };
  assertEquals(findNearDuplicate("User's 10k personal best is 47:10", 'achievement', [pb5]), null);
  // Forgetting the 5k goal does not stop the 10k goal from being learned.
  const userText = 'I want to run a 10k in under 50 minutes';
  const ctx = { userTokens: tokenSet(userText), userText, tombstones: [tokenSet('User wants to run a 5k in under 25 minutes')] };
  assertEquals(guardMemoryContent('User wants to run a 10k in under 50 minutes', ctx), null);
});

Deno.test("near-duplicates: a fact about someone else is never the user's own (finding 5)", () => {
  const pairs: [string, string][] = [
    ["User's daughter has asthma", 'User has asthma'],
    ["User's daughter has asthma and uses an inhaler", 'User has asthma'],
    ["User's partner is vegan and cooks plant-based meals", 'User is vegan'],
    ["User's mother has type 2 diabetes", 'User has type 2 diabetes'],
    ['User coaches a vegan athlete', 'User is vegan'],
  ];
  for (const [next, old] of pairs) {
    assertEquals(nearDuplicate(next, old), null, `${next} / ${old}`);
    assertEquals(nearDuplicate(old, next), null, `${old} / ${next}`);
    assert(!tokensNearMatch(tokenSet(next), tokenSet(old)), `cover/tombstone: ${next} / ${old}`);
  }
  const own = { id: 'own', content: 'User has asthma', topic: 'health' };
  assertEquals(findNearDuplicate("User's daughter has asthma", 'health', [own]), null);
  // Forgetting the daughter's fact does not block the user's own; forgetting a fact still covers its parts.
  assert(!tokensNearMatch(tokenSet('User has asthma'), tokenSet("User's daughter has asthma")));
  assert(tokensNearMatch(tokenSet('User has a dog'), tokenSet('User has a dog named Max')));
});

Deno.test('near-duplicates: the save path overlap, the duplicate-pair check and covering (I10)', () => {
  assertEquals(toolOverlap('User has mild IT band irritation in the left knee per the physio', 'User has mild IT band irritation in the left knee'), 'supersedes');
  assertEquals(toolOverlap('User has mild IT band irritation in the knee', 'User has mild IT band irritation in the left knee'), 'covered');
  assertEquals(toolOverlap('User has IT band irritation', 'User has mild IT band irritation in the left knee'), null, 'too little overlap');
  assertEquals(toolOverlap('User has right knee pain', 'User has left knee pain'), null, 'swapped words are another fact');
  assertEquals(toolOverlap("User's daughter has mild IT band irritation", 'User has mild IT band irritation'), null);
  const injury = (id: string, content: string) => ({ id, content, topic: 'injury' });
  assert(likelyDuplicates(injury('a', 'User saw a physio for mild IT band irritation; the knee no longer hurts'),
    injury('b', 'User had mild IT band irritation in the knee, which no longer hurts after physio')));
  assert(!likelyDuplicates(injury('a', 'User has mild IT band irritation'), { id: 'b', content: 'User has mild IT band irritation', topic: 'goal' }));
  assert(!likelyDuplicates(injury('a', 'User has asthma'), injury('b', "User's daughter has asthma")));
  assert(!likelyDuplicates({ id: 'a', content: 'User runs on Tuesdays', topic: 'routine' }, { id: 'b', content: 'User swims on Tuesdays', topic: 'routine' }));
  assert(covers('User had mild IT band irritation in the left knee; a physio saw it and it no longer hurts', 'User saw a physio: mild IT band irritation, no longer hurts'));
  assert(!covers('User has left knee pain', 'User has right knee pain'));
  assert(!covers('User has asthma and uses an inhaler', "User's daughter has asthma"));

  const active = [
    { id: 'old', content: 'User has mild IT band irritation in the left knee', topic: 'injury', importance: 4 },
    { id: 'pb', content: "User's 5k personal best is 22:30", topic: 'achievement', importance: 3 },
  ];
  assertEquals(saveTarget('User has mild IT band irritation in the left knee, confirmed by a physio', 'injury', active), { row: active[0], update: true });
  assertEquals(saveTarget('User has mild IT band irritation in the knee', 'health', active), { row: active[0], update: false });
  assertEquals(saveTarget("User's 10k personal best is 47:10", 'achievement', active), null, 'a new distance is a new fact');
  assertEquals(saveTarget('User has mild IT band irritation in the left knee', 'goal', active), null, 'another topic family');
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

Deno.test('coach memories: a save that updates a row is version-guarded; when another writer moved it first the match is redone (I3)', async () => {
  const h = await harness();
  const goal = (await save(h, { content: "User's marathon goal is 3:45", topic: 'goal' })).body.memory;
  const rpc = h.rest.rpc;
  let raced = false;
  h.rest.rpc = async (name: string, args: any) => {
    if (name === 'coach_memory_apply_v1' && args.p_ops?.[0]?.op === 'update' && !raced) {
      raced = true;
      // The curator rewrites the row between this save's read and its write.
      await rpc('coach_memory_apply_v1', { p_user: USER, p_ops: [{ op: 'update', id: goal.id, content: "User's marathon goal is 3:40" }], p_actor: 'curator' });
    }
    return await rpc(name, args);
  };
  const res = (await save(h, { content: "User's marathon goal is 3:30", topic: 'goal' })).body;
  assertEquals([res.updated, res.memory.id, res.memory.content], [true, goal.id, "User's marathon goal is 3:30"]);
  const updates = h.db.rpcCalls.filter((c) => c.name === 'coach_memory_apply_v1' && c.args.p_ops[0].op === 'update' && c.args.p_actor === 'tool');
  assertEquals(updates.map((c) => c.args.p_ops[0].expect_version), [1, 2], 'the first attempt was stale, the second read the new version');
  assertEquals(h.db.activeMemories().map((m) => [m.content, m.version]), [["User's marathon goal is 3:30", 3]]);
  // A row forgotten in between: the save is simply added.
  const knee = (await save(h, { content: 'User has a sore left knee', topic: 'injury' })).body.memory;
  h.rest.rpc = async (name: string, args: any) => {
    if (name === 'coach_memory_apply_v1' && args.p_ops?.[0]?.op === 'update') {
      await rpc('coach_memory_apply_v1', { p_user: USER, p_ops: [{ op: 'forget', id: knee.id }], p_actor: 'user' });
    }
    return await rpc(name, args);
  };
  const again = (await save(h, { content: 'User has a sore left knee and ices it after runs', topic: 'injury' })).body;
  assertEquals([again.kept, again.memory.content], [true, 'User has a sore left knee and ices it after runs']);
});
