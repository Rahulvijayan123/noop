import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// Proves 20261007160000_coach_threads_memory.sql (docs/COACH_MEMORY.md §2, §3) against a throwaway local
// PostgreSQL + PostgREST (EDGE_TEST_ARTIFACTS), never a shared database:
//  1. the tables, generated columns, indexes, triggers, RLS and comments exist, and the file re-applies
//     harmlessly (the harness applies it under Supabase-style default privileges, the test applies it again
//     with legacy rows present, and once more at the end);
//  2. no client role can reach a new table or call a new RPC; every RPC is SECURITY DEFINER, search_path '';
//  3. the backfill: client ids, 3-hour grouping per owner, legacy titles, counts and previews;
//  4. the thread-stats trigger under single and bulk inserts, edits, moves and deletes;
//  5. the composite foreign key (a message cannot join another owner's thread) and the folder-owner trigger;
//  6. coach_messages_save_v1: new threads, fallback titles, the meta merge, created_at kept, the rules for
//     thread-less rows from older builds, tombstones, thread_conflict and the retention cap;
//  7. coach_search_v1: ranking, grouping, snippets, months, dropped terms, browse mode, blocked rows,
//     exclusion and owner isolation;
//  8. coach_memories_ranked_v1 and coach_context_manifest_v1;
//  9. the maintenance lease (claim / publish), coach_memory_apply_v1, the consolidation claim and the
//     utility quota.

const MIGRATION = '20261007160000_coach_threads_memory.sql';
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const NOW = Date.now();

// One account per area keeps the steps independent of each other's rows.
const U_LEGACY = '30000000-0000-4000-8000-000000000001';
const U_PRUNE = '30000000-0000-4000-8000-000000000002';
const U_SEARCH = '30000000-0000-4000-8000-000000000003';
const U_DROP = '30000000-0000-4000-8000-000000000004';
const U_RANK = '30000000-0000-4000-8000-000000000005';
const U_APPLY = '30000000-0000-4000-8000-000000000006';
const U_CAP = '30000000-0000-4000-8000-000000000007';
const U_CONS = '30000000-0000-4000-8000-000000000008';
const U_QUOTA = '30000000-0000-4000-8000-000000000009';
const U_POOL = '30000000-0000-4000-8000-00000000000a';
const EXTRA_USERS = [U_LEGACY, U_PRUNE, U_SEARCH, U_DROP, U_RANK, U_APPLY, U_CAP, U_CONS, U_QUOTA, U_POOL];

/** The ten public RPCs of the migration, by signature. */
const RPC_SIGNATURES = [
  'coach_take_utility_quota(uuid,integer,integer)',
  'coach_add_utility_tokens(uuid,integer)',
  'coach_messages_save_v1(uuid,jsonb)',
  'coach_search_v1(uuid,text,integer,integer,uuid,timestamptz,timestamptz)',
  'coach_memories_ranked_v1(uuid,text,integer,boolean)',
  'coach_context_manifest_v1(uuid,uuid,text)',
  'coach_thread_claim_v1(uuid,uuid,integer)',
  'coach_thread_publish_v1(uuid,uuid,uuid,jsonb,jsonb)',
  'coach_memory_apply_v1(uuid,jsonb,text,uuid)',
  'coach_consolidation_claim_v1(uuid,integer)',
];
const NEW_TABLES = ['coach_folders', 'coach_threads', 'coach_thread_tombstones', 'coach_memory_events', 'coach_user_state'];

const uuid = () => crypto.randomUUID();
const iso = (ms: number) => new Date(ms).toISOString();
const at = (value: unknown) => value == null ? null : new Date(String(value)).getTime();
const lit = (value: string) => `'${value.replaceAll("'", "''")}'`;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Message = { id?: string; user: string; thread?: string | null; role?: string; content: string; at: number;
  client?: string | null; meta?: Record<string, unknown> };

Deno.test('coach threads and memory: schema, privileges, backfill, triggers and every RPC', async (t) => {
  const db = await startLocalPostgres({ coachMemory: true });
  const apply = async () => {
    const path = new URL(`../../migrations/${MIGRATION}`, import.meta.url);
    const result = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
        '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!result.success) throw new Error(`apply failed: ${new TextDecoder().decode(result.stderr).slice(-2000)}`);
  };
  const one = async (statement: string) => (await db.sql(statement)).trim();
  const json = async (statement: string) => JSON.parse((await db.sql(statement)) || 'null');
  const rpc = (name: string, args: Record<string, unknown>): Promise<any> => db.rest.rpc(name, args);
  const save = (user: string, rows: unknown[]) => rpc('coach_messages_save_v1', { p_user: user, p_rows: rows });
  const search = (user: string, query: string, extra: Record<string, unknown> = {}) =>
    rpc('coach_search_v1', { p_user: user, p_query: query, ...extra });
  const applyOps = (user: string, ops: unknown[], actor = 'tool', thread: string | null = null) =>
    rpc('coach_memory_apply_v1', { p_user: user, p_ops: ops, p_actor: actor, p_thread: thread });
  const thread = (id: string) => json(`select to_jsonb(t) - 'search' from public.coach_threads t where t.id = '${id}'`);
  const threadsOf = (user: string) => json(`select coalesce(jsonb_agg(to_jsonb(t) - 'search' order by t.created_at, t.id), '[]')
    from public.coach_threads t where t.user_id = '${user}'`);
  const message = (clientId: string) => json(`select to_jsonb(m) - 'search' from public.coach_messages m
    where m.client_id = '${clientId}'`);
  const memory = (id: string) => json(`select to_jsonb(m) - 'search' from public.coach_memory_items m where m.id = '${id}'`);
  const userState = (user: string) => json(`select to_jsonb(s) from public.coach_user_state s where s.user_id = '${user}'`);
  const revision = async (user: string) => Number(await one(
    `select coalesce((select memory_revision from public.coach_user_state where user_id = '${user}'), 0)`));
  const count = async (from: string) => Number(await one(`select count(*) from ${from}`));
  const insertMessages = async (rows: Message[]) => {
    const ids = rows.map((row) => row.id ?? uuid());
    const values = rows.map((row, index) => `(${lit(ids[index])}::uuid, ${lit(row.user)}::uuid, ` +
      `${row.thread ? `${lit(row.thread)}::uuid` : 'null'}, ${lit(row.role ?? 'user')}, ${lit(row.content)}, ` +
      `${lit(iso(row.at))}::timestamptz, ${row.client === null ? 'null' : `${lit(row.client ?? uuid())}::uuid`}, ` +
      `${lit(JSON.stringify(row.meta ?? {}))}::jsonb)`);
    await db.sql(`insert into public.coach_messages (id, user_id, thread_id, role, content, created_at, client_id, meta)
      values ${values.join(', ')}`);
    return ids;
  };
  const newThread = async (user: string, over: Record<string, string> = {}) => {
    const id = uuid();
    const columns = { id: lit(id), user_id: lit(user), ...over };
    await db.sql(`insert into public.coach_threads (${Object.keys(columns).join(', ')})
      values (${Object.values(columns).join(', ')})`);
    return id;
  };
  const row = (over: Record<string, unknown> = {}) => ({
    client_id: uuid(), thread_id: null, role: 'user', content: 'hello', meta: {}, created_at: iso(NOW),
    thread_title: null, ...over,
  });

  try {
    await db.sql(`insert into auth.users (id) values ${EXTRA_USERS.map((id) => `('${id}')`).join(', ')}`);

    await t.step('schema: tables, generated columns, indexes, triggers, RLS, policies and comments', async () => {
      assert.equal(await one(`select extnamespace::regnamespace::text from pg_extension where extname = 'btree_gin'`),
        'extensions');
      for (const table of NEW_TABLES) {
        assert.equal(await one(`select relrowsecurity from pg_class where oid = 'public.${table}'::regclass`), 't',
          `${table} has RLS`);
        assert.equal(await one(`select string_agg(policyname || ':' || cmd || ':' || array_to_string(roles, ','), ' ')
          from pg_policies where schemaname = 'public' and tablename = '${table}'`), `${table}_service:ALL:service_role`);
        assert.equal(await one(`select confdeltype from pg_constraint where conrelid = 'public.${table}'::regclass
          and contype = 'f' and confrelid = 'auth.users'::regclass`), 'c', `${table} cascades from auth.users`);
        assert.match(await one(`select obj_description('public.${table}'::regclass, 'pg_class')`), /Service role only/);
      }
      const generated = await one(`select string_agg(attrelid::regclass::text || '.' || attname || ':' || attgenerated::text, ' '
          order by attrelid::regclass::text, attname)
        from pg_attribute where attgenerated <> '' and not attisdropped
         and attrelid in ('public.coach_messages'::regclass, 'public.coach_threads'::regclass,
                          'public.coach_memory_items'::regclass)`);
      assert.equal(generated, 'coach_memory_items.search:s coach_messages.blocked:s coach_messages.search:s coach_threads.search:s');
      const indexes = await one(`select string_agg(indexdef, E'\\n') from pg_indexes where schemaname = 'public'
        and tablename in ('coach_messages', 'coach_threads', 'coach_folders', 'coach_memory_items', 'coach_memory_events')`);
      assert.match(indexes, /coach_messages USING gin \(user_id, search\)/);
      assert.match(indexes, /coach_threads USING gin \(user_id, search\)/);
      assert.match(indexes, /coach_messages USING btree \(user_id, thread_id, created_at DESC, id DESC\)/);
      assert.match(indexes, /coach_threads USING btree \(user_id, pinned DESC, last_message_at DESC NULLS LAST, id\)/);
      assert.match(indexes, /coach_folders USING btree \(user_id, sort_order, created_at\)/);
      assert.match(indexes, /coach_memory_items USING btree \(user_id\) WHERE \(retired_at IS NULL\)/);
      assert.match(indexes, /coach_memory_events USING btree \(user_id, created_at DESC\)/);
      assert.match(indexes, /UNIQUE INDEX coach_threads_id_user_key ON public.coach_threads USING btree \(id, user_id\)/);
      assert.match(indexes, /UNIQUE INDEX coach_folders_id_user_key ON public.coach_folders USING btree \(id, user_id\)/);
      assert.equal(await one(`select confdeltype::text || ':' || pg_get_constraintdef(oid) from pg_constraint
        where conname = 'coach_messages_thread_fkey'`),
        'c:FOREIGN KEY (thread_id, user_id) REFERENCES coach_threads(id, user_id) ON DELETE CASCADE');
      assert.equal(await one(`select string_agg(tgname || ':' || tgfoid::regproc::text, ' ' order by tgname) from pg_trigger
        where not tgisinternal and tgrelid in ('public.coach_messages'::regclass, 'public.coach_threads'::regclass)`),
        ['coach_messages_thread_stats_delete:internal.coach_messages_thread_stats',
          'coach_messages_thread_stats_insert:internal.coach_messages_thread_stats',
          'coach_messages_thread_stats_update:internal.coach_messages_thread_stats',
          'coach_threads_folder_owner:internal.coach_thread_folder_owner'].join(' '));
      const columns = await one(`select string_agg(table_name || '.' || column_name || ':' || data_type || ':' ||
          coalesce(column_default, '-'), E'\\n')
        from information_schema.columns where table_schema = 'public'
         and table_name in ('coach_memory_items', 'coach_usage', 'coach_user_state', 'coach_threads')`);
      for (const expected of [
        'coach_memory_items.confirmations:integer:1', "coach_memory_items.source:text:'tool'::text",
        'coach_memory_items.version:integer:1', 'coach_memory_items.updated_at:timestamp with time zone:now()',
        'coach_memory_items.last_confirmed_at:timestamp with time zone:now()',
        'coach_memory_items.retired_at:timestamp with time zone:-', 'coach_memory_items.source_thread_id:uuid:-',
        'coach_usage.utility_calls:integer:0', 'coach_usage.utility_tokens:bigint:0',
        'coach_user_state.memory_revision:bigint:0', 'coach_user_state.memory_floor_at:timestamp with time zone:-',
        "coach_user_state.recent_searches:jsonb:'[]'::jsonb", "coach_threads.title_source:text:'none'::text",
        "coach_threads.origin:text:'app'::text", "coach_threads.open_loops:jsonb:'[]'::jsonb",
        "coach_threads.summary_topics:ARRAY:'{}'::text[]", 'coach_threads.message_count:integer:0',
      ]) assert.ok(columns.split('\n').includes(expected), `missing column ${expected}`);
      // The generated `blocked` column never raises on an odd meta.blocked (probed in a rolled-back insert).
      assert.equal(await one(`begin;
        with probe as (
          insert into public.coach_messages (user_id, role, content, meta)
          select '${USER_A}', 'user', u.o::text, jsonb_build_object('blocked', u.v)
            from unnest(array['true'::jsonb, '"true"', '1', 'false', '"nope"', 'null', '{}']) with ordinality as u(v, o)
          returning content, meta, blocked)
        select string_agg((meta -> 'blocked')::text || '=' || blocked::text, ' ' order by content::integer) from probe;
        rollback;`), 'true=true "true"=true 1=true false=false "nope"=false null=false {}=false');
    });

    await t.step('privileges: no client role reaches a new table or RPC; RPCs are definer with an empty search_path', async () => {
      for (const table of NEW_TABLES) {
        for (const role of ['anon', 'authenticated']) {
          for (const privilege of ['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']) {
            assert.equal(await one(`select has_table_privilege('${role}', 'public.${table}', '${privilege}')`), 'f',
              `${role} ${privilege} on ${table}`);
          }
        }
        for (const privilege of ['select', 'insert', 'update', 'delete']) {
          assert.equal(await one(`select has_table_privilege('service_role', 'public.${table}', '${privilege}')`), 't');
        }
      }
      assert.equal(await one(`select has_sequence_privilege('authenticated',
        pg_get_serial_sequence('public.coach_memory_events', 'id'), 'usage')`), 'f');
      const coachFunctions = await one(`select string_agg(proname, ' ' order by proname) from pg_proc
        where pronamespace = 'public'::regnamespace and proname like 'coach%'`);
      assert.equal(coachFunctions, [...RPC_SIGNATURES.map((s) => s.split('(')[0]), 'coach_take_quota'].sort().join(' '),
        'every public coach function is reviewed here');
      for (const signature of RPC_SIGNATURES) {
        const fn = `'public.${signature}'::regprocedure`;
        for (const role of ['anon', 'authenticated']) {
          assert.equal(await one(`select has_function_privilege('${role}', ${fn}, 'execute')`), 'f', `${role} ${signature}`);
        }
        assert.equal(await one(`select has_function_privilege('service_role', ${fn}, 'execute')`), 't', signature);
        assert.equal(await one(`select count(*) from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
          where p.oid = ${fn} and a.grantee = 0`), '0', `PUBLIC keeps no EXECUTE on ${signature}`);
        assert.equal(await one(`select prosecdef || '|' || coalesce(array_to_string(proconfig, ','), '') from pg_proc
          where oid = ${fn}`), 'true|search_path=""', `${signature} is SECURITY DEFINER with an empty search_path`);
      }
      const internal = await json(`select jsonb_agg(jsonb_build_object('fn', p.oid::regprocedure::text,
          'reachable', has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                       or has_function_privilege('service_role', p.oid, 'execute')))
        from pg_proc p where p.pronamespace = 'internal'::regnamespace and p.proname like 'coach%'`);
      assert.ok(internal.length >= 18, 'the internal helpers exist');
      for (const helper of internal) assert.equal(helper.reachable, false, `${helper.fn} is reachable`);
    });

    await t.step('privileges: PostgREST refuses every client call to a new RPC or table', async () => {
      const args: Record<string, Record<string, unknown>> = {
        coach_take_utility_quota: { p_user_id: USER_A, p_limit: 5 },
        coach_add_utility_tokens: { p_user_id: USER_A, p_tokens: 5 },
        coach_messages_save_v1: { p_user: USER_A, p_rows: [row()] },
        coach_search_v1: { p_user: USER_A, p_query: 'knee' },
        coach_memories_ranked_v1: { p_user: USER_A },
        coach_context_manifest_v1: { p_user: USER_A },
        coach_thread_claim_v1: { p_user: USER_A, p_thread: uuid() },
        coach_thread_publish_v1: { p_user: USER_A, p_thread: uuid(), p_token: uuid(), p_patch: {}, p_ops: [] },
        coach_memory_apply_v1: { p_user: USER_A, p_ops: [{ op: 'add', content: 'User x', topic: 'goal' }], p_actor: 'user' },
        coach_consolidation_claim_v1: { p_user: USER_A },
      };
      assert.deepEqual(Object.keys(args).sort(), RPC_SIGNATURES.map((s) => s.split('(')[0]).sort());
      for (const [name, body] of Object.entries(args)) {
        for (const role of ['authenticated', 'anon']) {
          const reply = await db.request(`rpc/${name}`, role, USER_A, 'POST', body);
          assert.ok([401, 403].includes(reply.status), `${role} ${name} answered ${reply.status}`);
        }
      }
      for (const table of NEW_TABLES) {
        for (const role of ['authenticated', 'anon']) {
          const reply = await db.request(`${table}?select=*`, role, USER_A);
          assert.ok([401, 403].includes(reply.status), `${role} read ${table}: ${reply.status}`);
        }
      }
      assert.equal(await count('public.coach_messages'), 0, 'nothing was written');
      assert.equal(await count('public.coach_memory_items'), 0);
      assert.equal(await count('public.coach_usage'), 0);
    });

    const KEEP_CLIENT = uuid();
    const TB = NOW - 30 * DAY;
    let backfillA: any[] = [];
    await t.step('backfill: client ids, 3-hour groups per owner, legacy titles, counts and previews', async () => {
      // Rows the previous coach function wrote: no thread, most without a client id.
      await insertMessages([
        { user: USER_A, content: '  How should I   train for a half marathon in the spring when my knee hurts sometimes?  ',
          at: TB, client: null },
        { user: USER_A, role: 'assistant', content: 'Start with easy mileage.', at: TB + 5 * MINUTE, client: null },
        // Exactly 2 h 55 min after the previous message: same chat.
        { user: USER_A, content: 'And after that?', at: TB + 3 * HOUR, client: KEEP_CLIENT },
        // 3 h and 1 s after the previous message: a new chat that starts with the assistant.
        { user: USER_A, role: 'assistant', content: 'Welcome back.', at: TB + 6 * HOUR + 1000, client: null },
        { user: USER_A, content: 'Second\n\nsession   question', at: TB + 6 * HOUR + MINUTE + 1000, client: null },
        // A chat with nothing but a blocked question and its refusal has no title.
        { user: USER_A, content: 'something unsafe', at: TB + 2 * DAY, client: null, meta: { blocked: true } },
        { user: USER_A, role: 'assistant', content: "I can't help with that.", at: TB + 2 * DAY + MINUTE, client: null,
          meta: { blocked: true } },
        // Another owner at the same instant is grouped separately.
        { user: USER_B, content: "B's own question", at: TB, client: null },
      ]);
      await apply();
      assert.equal(await count(`public.coach_messages where client_id is null`), 0, 'every row has a client id');
      assert.equal(await count(`public.coach_messages where thread_id is null`), 0, 'every row has a thread');
      assert.equal(await one(`select content from public.coach_messages where client_id = '${KEEP_CLIENT}'`), 'And after that?',
        'an existing client id is kept');
      backfillA = await threadsOf(USER_A);
      assert.equal(backfillA.length, 3);
      const [first, second, third] = backfillA;
      assert.deepEqual([first.title, first.title_source, first.origin, first.message_count, first.preview],
        ['How should I train for a half marathon in the spring when my', 'legacy', 'backfill', 3, 'And after that?']);
      assert.ok(first.title.length <= 60);
      assert.equal(at(first.created_at), TB);
      assert.equal(at(first.last_message_at), TB + 3 * HOUR);
      assert.deepEqual([second.title, second.title_source, second.message_count, second.preview],
        ['Second session question', 'legacy', 2, 'Second session question']);
      assert.equal(at(second.created_at), TB + 6 * HOUR + 1000);
      assert.equal(at(second.last_message_at), TB + 6 * HOUR + MINUTE + 1000);
      assert.deepEqual([third.title, third.title_source, third.origin, third.message_count],
        [null, 'none', 'backfill', 2]);
      const threadOfB = await threadsOf(USER_B);
      assert.equal(threadOfB.length, 1);
      assert.deepEqual([threadOfB[0].title, threadOfB[0].message_count], ["B's own question", 1]);
      assert.equal(await count(`public.coach_messages m join public.coach_threads t on t.id = m.thread_id
        where t.user_id <> m.user_id`), 0, 'no message sits in another owner thread');
    });

    await t.step('re-applying the migration changes nothing that exists', async () => {
      await apply();
      assert.deepEqual(await threadsOf(USER_A), backfillA);
      assert.equal(await count(`pg_trigger where not tgisinternal and tgname like 'coach_%'`), 4);
    });

    await t.step('stats trigger: single and bulk inserts, edits, moves and deletes', async () => {
      const t1 = await newThread(USER_A);
      const t2 = await newThread(USER_A);
      const stats = async (id: string) => {
        const row = await thread(id);
        return [row.message_count, at(row.last_message_at), row.preview];
      };
      const before = at((await thread(t1)).updated_at)!;
      await sleep(5);
      const [m1] = await insertMessages([{ user: USER_A, thread: t1, content: 'first', at: NOW - 5 * HOUR }]);
      assert.deepEqual(await stats(t1), [1, NOW - 5 * HOUR, 'first']);
      assert.ok(at((await thread(t1)).updated_at)! > before, 'updated_at moves');
      const long = '  newest   message ' + 'x'.repeat(200);
      const [m2, m3, m4, m5] = await insertMessages([
        { user: USER_A, thread: t1, content: 'second', at: NOW - 4 * HOUR },
        { user: USER_A, thread: t1, content: 'older', at: NOW - 6 * HOUR },
        { user: USER_A, thread: t1, role: 'assistant', content: long, at: NOW - 3 * HOUR },
        { user: USER_A, thread: t2, content: 'other thread', at: NOW - 2 * HOUR },
      ]);
      assert.deepEqual(await stats(t1), [4, NOW - 3 * HOUR, 'newest message ' + 'x'.repeat(145)]);
      assert.deepEqual(await stats(t2), [1, NOW - 2 * HOUR, 'other thread']);
      await db.sql(`update public.coach_messages set content = 'edited newest' where id = '${m4}'`);
      assert.deepEqual(await stats(t1), [4, NOW - 3 * HOUR, 'edited newest']);
      await db.sql(`update public.coach_messages set content = 'older edited' where id = '${m3}'`);
      assert.deepEqual(await stats(t1), [4, NOW - 3 * HOUR, 'edited newest'], 'an older edit leaves the preview');
      await db.sql(`update public.coach_messages set meta = '{"followUps": ["x"]}' where id = '${m4}'`);
      assert.deepEqual(await stats(t1), [4, NOW - 3 * HOUR, 'edited newest'], 'a meta-only update changes nothing');
      await db.sql(`update public.coach_messages set thread_id = '${t2}' where id = '${m4}'`);
      assert.deepEqual(await stats(t1), [3, NOW - 4 * HOUR, 'second']);
      assert.deepEqual(await stats(t2), [2, NOW - 2 * HOUR, 'other thread']);
      await db.sql(`delete from public.coach_messages where id = '${m2}'`);
      assert.deepEqual(await stats(t1), [2, NOW - 5 * HOUR, 'first']);
      await db.sql(`delete from public.coach_messages where id in ('${m1}', '${m5}')`);
      assert.deepEqual(await stats(t1), [1, NOW - 6 * HOUR, 'older edited']);
      assert.deepEqual(await stats(t2), [1, NOW - 3 * HOUR, 'edited newest']);
      await db.sql(`delete from public.coach_messages where thread_id = '${t1}'`);
      assert.deepEqual(await stats(t1), [0, null, null]);
      // A bulk insert that is an upsert counts only the rows it actually inserted.
      const client = uuid();
      await insertMessages([{ user: USER_A, thread: t1, content: 'one', at: NOW - HOUR, client }]);
      await db.sql(`insert into public.coach_messages (user_id, client_id, thread_id, role, content, created_at)
        values ('${USER_A}', '${client}', '${t1}', 'user', 'one, edited', now()),
               ('${USER_A}', gen_random_uuid(), '${t1}', 'assistant', 'two', now() - interval '2 hours')
        on conflict (user_id, client_id) do update set content = excluded.content`);
      assert.deepEqual(await stats(t1), [2, NOW - HOUR, 'one, edited']);
      const recount = await one(`select count(*) filter (where t.message_count is distinct from
          (select count(*) from public.coach_messages m where m.thread_id = t.id)) from public.coach_threads t`);
      assert.equal(recount, '0', 'every count matches the messages');
    });

    await t.step('composite foreign key: a message cannot join another owner thread; a thread cascades its messages', async () => {
      const [threadOfB] = await threadsOf(USER_B);
      await assert.rejects(() => insertMessages([{ user: USER_A, thread: threadOfB.id, content: 'sneak', at: NOW }]),
        /coach_messages_thread_fkey/);
      const own = await newThread(USER_A);
      const [mine] = await insertMessages([{ user: USER_A, thread: own, content: 'mine', at: NOW }]);
      await assert.rejects(() => db.sql(`update public.coach_messages set thread_id = '${threadOfB.id}' where id = '${mine}'`),
        /coach_messages_thread_fkey/);
      // A signed-in client still holds its old own-row grants on coach_messages: the key refuses it too.
      const reply = await db.request('coach_messages', 'authenticated', USER_A, 'POST',
        { user_id: USER_A, thread_id: threadOfB.id, client_id: uuid(), role: 'user', content: 'via rest' });
      assert.equal(reply.status, 409, `foreign key violation, got ${reply.status}`);
      assert.equal((await thread(threadOfB.id)).message_count, 1, "B's chat is untouched");
      await db.sql(`delete from public.coach_threads where id = '${own}'`);
      assert.equal(await count(`public.coach_messages where id = '${mine}'`), 0, 'deleting a thread deletes its messages');
    });

    await t.step('folders: a thread may only sit in one of its owner folders', async () => {
      const folderA = uuid(), folderB = uuid();
      await db.sql(`insert into public.coach_folders (id, user_id, name) values
        ('${folderA}', '${USER_A}', 'Training'), ('${folderB}', '${USER_B}', 'B stuff')`);
      await assert.rejects(() => newThread(USER_A, { folder_id: lit(folderB) }), /folder_not_owned/);
      const inFolder = await newThread(USER_A, { folder_id: lit(folderA) });
      await assert.rejects(() => db.sql(`update public.coach_threads set folder_id = '${folderB}' where id = '${inFolder}'`),
        /folder_not_owned/);
      await assert.rejects(() => db.sql(`insert into public.coach_folders (id, user_id, name) values (gen_random_uuid(), '${USER_A}', '   ')`),
        /check constraint/);
      await assert.rejects(() => db.sql(`insert into public.coach_folders (id, user_id, name)
        values (gen_random_uuid(), '${USER_A}', '${'n'.repeat(61)}')`), /check constraint/);
      await db.sql(`delete from public.coach_folders where id = '${folderA}'`);
      assert.equal((await thread(inFolder)).folder_id, null, 'deleting a folder keeps its chats');
      await db.sql(`delete from public.coach_threads where id = '${inFolder}'`);
    });

    await t.step('save_v1: new threads, fallback titles, meta merge, created_at kept', async () => {
      const t1 = uuid();
      const first = row({ thread_id: t1, content: 'How do I taper?', meta: { a: 1 }, created_at: iso(NOW - HOUR),
        thread_title: '  Taper   plan  ' });
      const reply = row({ thread_id: t1, role: 'assistant', content: 'Cut volume.', created_at: iso(NOW - HOUR + 1000) });
      assert.deepEqual(await save(USER_A, [first, reply]), { saved: 2, rejected: [], threads: [{ id: t1, created: true }] });
      const created = await thread(t1);
      assert.deepEqual([created.origin, created.title, created.title_source, created.message_count, created.preview],
        ['app', 'Taper plan', 'fallback', 2, 'Cut volume.']);
      assert.equal(at(created.created_at), NOW - HOUR, 'a new thread starts at its first message');
      // The same client id again: content and role replaced, meta merged, created_at and thread kept.
      assert.deepEqual(await save(USER_A, [{ ...first, content: 'How do I taper well?', meta: { b: 2 },
        created_at: iso(NOW), thread_title: 'Other title' }]), { saved: 1, rejected: [], threads: [{ id: t1, created: false }] });
      const stored = await message(first.client_id);
      assert.equal(stored.content, 'How do I taper well?');
      assert.deepEqual(stored.meta, { a: 1, b: 2 });
      assert.equal(at(stored.created_at), NOW - HOUR);
      assert.equal(stored.thread_id, t1);
      const after = await thread(t1);
      assert.deepEqual([after.title, after.title_source, after.message_count], ['Taper plan', 'fallback', 2]);
      await save(USER_A, [{ ...reply, meta: { followUps: ['What about week 2?'] } }]);
      assert.deepEqual((await message(reply.client_id)).meta, { followUps: ['What about week 2?'] });
      // A thread made by POST threads (no title) takes the first fallback title; a user title is never replaced.
      const untitled = await newThread(USER_A);
      const named = await newThread(USER_A, { title: `'Mine'`, title_source: `'user'` });
      await save(USER_A, [row({ thread_id: untitled, thread_title: 'From first message' }),
        row({ thread_id: named, thread_title: 'Ignored' })]);
      assert.deepEqual([(await thread(untitled)).title, (await thread(untitled)).title_source], ['From first message', 'fallback']);
      assert.deepEqual([(await thread(named)).title, (await thread(named)).title_source], ['Mine', 'user']);
      const bare = uuid();
      await save(USER_A, [row({ thread_id: bare })]);
      assert.deepEqual([(await thread(bare)).title, (await thread(bare)).title_source], [null, 'none']);
      // Blocked turns are stored, marked by the generated column.
      const blocked = row({ thread_id: bare, meta: { blocked: true } });
      await save(USER_A, [blocked]);
      assert.equal((await message(blocked.client_id)).blocked, true);
      // A client id twice in one batch: the later content wins and meta merges in order.
      const twice = uuid();
      assert.equal((await save(USER_A, [row({ client_id: twice, thread_id: bare, content: 'one', meta: { k: 1 } }),
        row({ client_id: twice, thread_id: bare, content: 'two', meta: { j: 2 } })])).saved, 2);
      assert.deepEqual([(await message(twice)).content, (await message(twice)).meta], ['two', { k: 1, j: 2 }]);
      // Malformed rows are rejected one by one.
      const good = row({ thread_id: bare, content: 'still saved' });
      const result = await save(USER_A, [row({ thread_id: bare, role: 'system' }), { ...row({ thread_id: bare }), client_id: 'nope' },
        row({ thread_id: bare, content: 42 }), row({ thread_id: 'not-a-uuid' }), good]);
      assert.equal(result.saved, 1);
      assert.deepEqual(result.rejected.map((r: any) => r.reason), ['invalid_row', 'invalid_row', 'invalid_row', 'invalid_row']);
      assert.equal((await message(good.client_id)).content, 'still saved');
      await assert.rejects(() => save(USER_A, { rows: [] } as unknown as unknown[]), /invalid_rows/);
    });

    await t.step('save_v1: thread-less rows from older builds', async () => {
      const T = NOW - 10 * DAY;
      const r1 = row({ content: 'old build 1', created_at: iso(T) });
      const first = await save(U_LEGACY, [r1]);
      assert.equal(first.saved, 1);
      assert.equal(first.threads.length, 1);
      const x = first.threads[0].id;
      assert.equal(first.threads[0].created, true);
      assert.deepEqual([(await thread(x)).origin, (await thread(x)).title, (await thread(x)).title_source],
        ['legacy_client', null, 'none']);
      // Within 3 hours of the newest legacy_client thread's last message: joins it.
      assert.deepEqual((await save(U_LEGACY, [row({ content: 'old build 2', created_at: iso(T + 2 * HOUR) })])).threads,
        [{ id: x, created: false }]);
      assert.equal((await thread(x)).message_count, 2);
      // More than 3 hours later: a new legacy_client thread.
      const third = await save(U_LEGACY, [row({ content: 'old build 3', created_at: iso(T + 5 * HOUR + 10 * MINUTE) })]);
      const y = third.threads[0].id;
      assert.notEqual(y, x);
      assert.equal(third.threads[0].created, true);
      // In one batch, oldest first: rows within 3 hours of each other share a thread; a 4-hour gap starts another.
      const batch = await save(U_LEGACY, [row({ content: 'b3', created_at: iso(T + 35 * HOUR) }),
        row({ content: 'b1', created_at: iso(T + 30 * HOUR) }), row({ content: 'b2', created_at: iso(T + 31 * HOUR) })]);
      assert.equal(batch.saved, 3);
      assert.equal(batch.threads.length, 2);
      assert.ok(batch.threads.every((entry: any) => entry.created));
      const threadOf = async (content: string) => one(`select thread_id from public.coach_messages
        where user_id = '${U_LEGACY}' and content = '${content}'`);
      assert.equal(await threadOf('b1'), await threadOf('b2'));
      assert.notEqual(await threadOf('b3'), await threadOf('b1'));
      // A thread-less row whose client id is stored keeps its stored thread, whatever its time.
      assert.deepEqual((await save(U_LEGACY, [{ ...r1, content: 'old build 1, edited', created_at: iso(T + 100 * HOUR) }])).threads,
        [{ id: x, created: false }]);
      const edited = await message(r1.client_id);
      assert.deepEqual([edited.thread_id, edited.content, at(edited.created_at)], [x, 'old build 1, edited', T]);
      // An app thread is never joined by a thread-less row, however recent.
      const app = uuid();
      await save(U_LEGACY, [row({ thread_id: app, content: 'new build', created_at: iso(T + 50 * HOUR) })]);
      const late = await save(U_LEGACY, [row({ content: 'old build again', created_at: iso(T + 50 * HOUR + 30 * MINUTE) })]);
      assert.notEqual(late.threads[0].id, app);
      assert.equal((await thread(late.threads[0].id)).origin, 'legacy_client');
      assert.equal((await thread(app)).origin, 'app');
      assert.equal(await count(`public.coach_threads where user_id = '${U_LEGACY}'`), 6);
    });

    await t.step('save_v1: tombstones, other owners and the 90-day tombstone purge', async () => {
      const deleted = uuid(), fresh = uuid(), old = uuid(), recent = uuid(), oldOfB = uuid();
      await db.sql(`insert into public.coach_thread_tombstones (user_id, thread_id, deleted_at) values
        ('${USER_A}', '${deleted}', now()), ('${USER_A}', '${old}', now() - interval '91 days'),
        ('${USER_A}', '${recent}', now() - interval '89 days'), ('${USER_B}', '${oldOfB}', now() - interval '91 days')`);
      const [threadOfB] = await threadsOf(USER_B);
      const gone = row({ thread_id: deleted }), conflict = row({ thread_id: threadOfB.id }), ok = row({ thread_id: fresh });
      const result = await save(USER_A, [gone, conflict, ok]);
      assert.equal(result.saved, 1);
      assert.deepEqual(result.rejected, [{ client_id: gone.client_id, reason: 'thread_deleted' },
        { client_id: conflict.client_id, reason: 'thread_conflict' }]);
      assert.deepEqual(result.threads, [{ id: fresh, created: true }]);
      assert.equal(await thread(deleted), null, 'a tombstoned thread is not recreated');
      assert.equal(await message(gone.client_id), null);
      assert.equal(await message(conflict.client_id), null);
      assert.equal((await thread(threadOfB.id)).message_count, 1, "B's chat is untouched");
      assert.equal((await thread(threadOfB.id)).user_id, USER_B);
      assert.equal(await one(`select string_agg(thread_id::text, ',' order by thread_id) from public.coach_thread_tombstones
        where user_id = '${USER_A}'`), [deleted, recent].sort().join(','), 'tombstones older than 90 days are purged');
      assert.equal(await count(`public.coach_thread_tombstones where thread_id = '${oldOfB}'`), 1, "only the caller's");
    });

    await t.step('save_v1: messages beyond the cap are pruned oldest first, for the caller only', async () => {
      // The 50,000 cap is internal.coach_messages_cap(); the rule is exercised on 5 and the file restores it.
      await db.sql(`create or replace function internal.coach_messages_cap() returns integer
        language sql stable set search_path = '' as $$ select 5 $$`);
      try {
        const p1 = uuid(), p2 = uuid();
        const rows = Array.from({ length: 7 }, (_, n) => row({ thread_id: n < 4 ? p1 : p2, content: `m${n}`,
          created_at: iso(NOW - (10 - n) * MINUTE) }));
        await save(U_PRUNE, rows.slice(0, 4));
        assert.equal(await count(`public.coach_messages where user_id = '${U_PRUNE}'`), 4);
        const othersBefore = await count(`public.coach_messages where user_id = '${USER_A}'`);
        assert.ok(othersBefore > 5);
        await save(U_PRUNE, rows.slice(4));
        assert.equal(await one(`select string_agg(content, ',' order by created_at) from public.coach_messages
          where user_id = '${U_PRUNE}'`), 'm2,m3,m4,m5,m6');
        assert.deepEqual([(await thread(p1)).message_count, (await thread(p2)).message_count], [2, 3]);
        assert.equal(at((await thread(p1)).last_message_at), NOW - 7 * MINUTE);
        assert.equal(await count(`public.coach_messages where user_id = '${USER_A}'`), othersBefore);
      } finally {
        await apply();
      }
      assert.equal(await one(`select internal.coach_messages_cap()`), '50000');
    });

    // Search fixtures: six chats for one owner on fixed dates, and a knee mention for B.
    const S = { knee: uuid(), breakfast: uuid(), blocked: uuid(), taper: uuid(), brace: uuid(), answer: uuid() };
    const SB = uuid();
    let injuryMemory = '';
    await t.step('search fixtures', async () => {
      const m = (thread: string, role: string, content: string, when: string, extra: Record<string, unknown> = {}) =>
        row({ thread_id: thread, role, content, created_at: when, ...extra });
      const result = await save(U_SEARCH, [
        m(S.knee, 'user', 'My knee hurts after long runs', '2026-09-20T10:00:00Z', { thread_title: 'Knee pain while running' }),
        m(S.knee, 'assistant', 'Knee pain after running is often an overuse issue; ease off the long run.', '2026-09-20T10:01:00Z'),
        m(S.breakfast, 'user', 'What should I eat before a race?', '2026-08-15T10:00:00Z', { thread_title: 'Race breakfast' }),
        m(S.breakfast, 'assistant', 'Oats and a banana work well, and they are gentle on a sore knee too.', '2026-08-15T10:01:00Z'),
        m(S.blocked, 'user', 'blocked knee text', '2026-09-25T10:00:00Z', { meta: { blocked: true } }),
        m(S.blocked, 'assistant', "I can't help with that knee request.", '2026-09-25T10:01:00Z', { meta: { blocked: true } }),
        m(S.taper, 'user', 'Plan my taper', '2026-07-10T10:00:00Z', { thread_title: 'Marathon taper' }),
        m(S.taper, 'assistant', 'Reduce volume over three weeks.', '2026-07-10T10:01:00Z'),
        m(S.brace, 'user', 'knee brace advice', '2026-09-01T10:00:00Z', { thread_title: 'Brace question' }),
        m(S.answer, 'assistant', 'knee brace advice', '2026-09-01T10:00:00Z', { thread_title: 'Brace answer' }),
      ]);
      assert.equal(result.saved, 10);
      await save(USER_B, [row({ thread_id: SB, content: 'My knee is fine, thanks', thread_title: 'B knee' })]);
      await db.sql(`update public.coach_threads set summary = ${lit('User is training for the Berlin marathon. ' +
        'Long runs are on Sundays and the taper starts three weeks out. '.repeat(6))}, summary_topics = '{marathon,taper}'
        where id = '${S.taper}'`);
    });

    await t.step('search_v1: ranking, grouping, snippets, months, blocked rows and owner isolation', async () => {
      const result = await search(U_SEARCH, 'knee');
      assert.deepEqual([result.terms, result.dropped_terms, result.total_hits], [['knee'], [], 5]);
      assert.deepEqual(result.months, [{ month: '2026-08', hits: 1 }, { month: '2026-09', hits: 4 }]);
      const ids = result.threads.map((entry: any) => entry.thread_id);
      assert.deepEqual([...ids].sort(), [S.knee, S.breakfast, S.brace, S.answer].sort(), 'blocked and other owners excluded');
      assert.ok(ids.indexOf(S.knee) < ids.indexOf(S.breakfast), 'a user mention outranks an assistant one');
      assert.ok(ids.indexOf(S.brace) < ids.indexOf(S.answer));
      const byId = (id: string) => result.threads.find((entry: any) => entry.thread_id === id);
      assert.deepEqual(Object.keys(byId(S.knee)).sort(),
        ['best_rank', 'hits', 'last_message_at', 'snippet', 'summary', 'thread_id', 'title', 'topics']);
      assert.deepEqual([byId(S.knee).hits, byId(S.breakfast).hits, byId(S.knee).title], [2, 1, 'Knee pain while running']);
      assert.match(byId(S.knee).snippet, /«knee»/i);
      const hit = (threadId: string) => result.hits.find((entry: any) => entry.thread_id === threadId);
      assert.deepEqual(Object.keys(hit(S.brace)).sort(), ['created_at', 'message_id', 'rank', 'role', 'snippet', 'thread_id']);
      assert.ok(hit(S.brace).rank > hit(S.answer).rank, 'the same words rank higher from the user');
      assert.deepEqual([hit(S.brace).role, hit(S.answer).role], ['user', 'assistant']);
      assert.equal(hit(S.brace).snippet, '«knee» brace advice');
      assert.ok(result.hits.every((entry: any, index: number) => index === 0 || result.hits[index - 1].rank >= entry.rank));
      assert.deepEqual((await search(U_SEARCH, 'knee', { p_exclude_thread: S.knee })).threads.map((e: any) => e.thread_id)
        .includes(S.knee), false);
      const ofB = await search(USER_B, 'knee');
      assert.deepEqual(ofB.threads.map((entry: any) => entry.thread_id), [SB]);
      assert.equal((await search(USER_B, 'taper')).total_hits, 0);
      assert.deepEqual((await search(USER_B, 'taper')).threads, []);
      // Title and summary matches join the thread list without a message hit; the summary is cut to 300.
      const berlin = await search(U_SEARCH, 'berlin');
      assert.deepEqual([berlin.total_hits, berlin.hits, berlin.months], [0, [], []]);
      assert.deepEqual(berlin.threads.map((entry: any) => [entry.thread_id, entry.hits]), [[S.taper, 0]]);
      assert.ok(berlin.threads[0].best_rank > 0);
      assert.match(berlin.threads[0].snippet, /«Berlin»/);
      assert.equal(berlin.threads[0].summary.length, 300);
      assert.deepEqual(berlin.threads[0].topics, ['marathon', 'taper']);
      // Clamps.
      assert.equal((await search(U_SEARCH, 'knee', { p_limit: 0 })).hits.length, 1);
      assert.equal((await search(U_SEARCH, 'knee', { p_thread_limit: 0 })).threads.length, 1);
      // A window keeps hits inside [from, to).
      const august = await search(U_SEARCH, 'knee', { p_from: '2026-08-01T00:00:00Z', p_to: '2026-08-15T10:01:00Z' });
      assert.equal(august.total_hits, 0, 'p_to is exclusive');
      assert.equal((await search(U_SEARCH, 'knee', { p_from: '2026-08-01T00:00:00Z', p_to: '2026-09-01T00:00:00Z' })).total_hits, 1);
    });

    await t.step('search_v1: browse mode lists chats with activity in the window, newest first', async () => {
      const window = await search(U_SEARCH, '', { p_from: '2026-08-01T00:00:00Z', p_to: '2026-09-15T00:00:00Z' });
      assert.deepEqual([window.terms, window.dropped_terms, window.total_hits, window.hits, window.months], [[], [], 0, [], []]);
      const ids = window.threads.map((entry: any) => entry.thread_id);
      assert.deepEqual([...ids].sort(), [S.breakfast, S.brace, S.answer].sort());
      assert.equal(ids[2], S.breakfast);
      assert.ok(window.threads.every((entry: any) => entry.hits === 0 && entry.snippet === null));
      // A query with no lexemes is a browse too; a blocked-only chat never shows.
      const stopWords = await search(U_SEARCH, 'the and of', { p_from: '2026-09-16T00:00:00Z', p_to: '2026-09-26T00:00:00Z' });
      assert.deepEqual(stopWords.threads.map((entry: any) => entry.thread_id), [S.knee]);
      const all = await search(U_SEARCH, '', { p_thread_limit: 30 });
      const allIds = all.threads.map((entry: any) => entry.thread_id);
      assert.equal(allIds.length, 5);
      assert.deepEqual([allIds[0], allIds[3], allIds[4]], [S.knee, S.breakfast, S.taper]);
      assert.equal(allIds.includes(S.blocked), false);
      const taper = all.threads.find((entry: any) => entry.thread_id === S.taper);
      assert.deepEqual([taper.title, taper.summary.length, taper.topics], ['Marathon taper', 300, ['marathon', 'taper']]);
      assert.deepEqual((await search(U_SEARCH, '', { p_exclude_thread: S.knee, p_thread_limit: 1 })).threads
        .map((entry: any) => entry.thread_id).includes(S.knee), false);
    });

    await t.step('search_v1: terms in more than 15% of a 40+ message history are dropped', async () => {
      const chat = uuid();
      const rows = Array.from({ length: 50 }, (_, n) => row({ thread_id: chat, created_at: iso(NOW - (60 - n) * MINUTE),
        content: n < 20 ? 'sleep was rough last night' : n < 22 ? 'ferritin came back low' : `general chat number ${n}` }));
      assert.equal((await save(U_DROP, rows)).saved, 50);
      const mixed = await search(U_DROP, 'sleep ferritin');
      assert.deepEqual([mixed.terms, mixed.dropped_terms, mixed.total_hits], [['ferritin'], ['sleep'], 2]);
      const single = await search(U_DROP, 'sleep');
      assert.deepEqual([single.terms, single.dropped_terms, single.total_hits], [['sleep'], [], 20], 'one term is never dropped');
      const common = await search(U_DROP, 'sleep night');
      assert.deepEqual([common.terms, common.dropped_terms, common.total_hits], [['sleep', 'night'], [], 20],
        'when every term is common, none is dropped');
      // A short history keeps every term.
      const short = await search(U_SEARCH, 'knee brace');
      assert.deepEqual([short.terms, short.dropped_terms], [['knee', 'brace'], []]);
    });

    await t.step('search_v1: only the newest 5,000 matches are ranked; a window reaches older ones', async () => {
      const oldChat = await newThread(U_POOL), newChat = await newThread(U_POOL);
      // 100 old messages that would rank highest, then 5,000 newer, weaker matches.
      await db.sql(`insert into public.coach_messages (user_id, thread_id, client_id, role, content, created_at)
          select '${U_POOL}', '${oldChat}', gen_random_uuid(), 'user', 'zinc zinc zinc zinc',
                 timestamptz '2024-03-01T00:00:00Z' + n * interval '1 minute' from generate_series(1, 100) n;
        insert into public.coach_messages (user_id, thread_id, client_id, role, content, created_at)
          select '${U_POOL}', '${newChat}', gen_random_uuid(), 'assistant',
                 'a long answer that mentions zinc once among many other words about training and recovery ' || n,
                 timestamptz '2026-06-01T00:00:00Z' + n * interval '1 minute' from generate_series(1, 5000) n;`);
      const all = await search(U_POOL, 'zinc', { p_limit: 50 });
      assert.equal(all.total_hits, 5100, 'every match is counted');
      assert.deepEqual(all.months, [{ month: '2024-03', hits: 100 }, { month: '2026-06', hits: 5000 }]);
      assert.deepEqual(all.threads.map((entry: any) => [entry.thread_id, entry.hits]), [[newChat, 5000]]);
      assert.ok(all.hits.every((entry: any) => entry.thread_id === newChat));
      const older = await search(U_POOL, 'zinc', { p_to: '2025-01-01T00:00:00Z' });
      assert.equal(older.total_hits, 100);
      assert.deepEqual(older.threads.map((entry: any) => [entry.thread_id, entry.hits]), [[oldChat, 100]]);
      assert.match(older.hits[0].snippet, /«zinc»/);
    });

    await t.step('memories_ranked_v1: safety pins, lexical relevance, fallback order, retired rows', async () => {
      const ids: Record<string, string> = {};
      const add = async (key: string, topic: string, importance: number, content: string, daysAgo: number, retired = false) => {
        ids[key] = uuid();
        await db.sql(`insert into public.coach_memory_items (id, user_id, content, topic, importance, created_at,
            updated_at, last_confirmed_at, retired_at)
          values ('${ids[key]}', '${U_RANK}', ${lit(content)}, '${topic}', ${importance}, now() - interval '${daysAgo} days',
            now() - interval '${daysAgo} days', now() - interval '${daysAgo} days', ${retired ? 'now()' : 'null'})`);
      };
      await add('inj1', 'injury', 5, 'User has a torn left meniscus', 1);
      await add('inj2', 'health', 4, 'User has asthma', 2);
      await add('inj3', 'injury', 4, 'User had Achilles tendinopathy', 10);
      await add('inj4', 'health', 4, 'User takes thyroid medication', 30);
      await add('goal', 'goal', 2, 'User wants to run the Chicago marathon', 5);
      await add('lift', 'training', 5, 'User lifts weights three times a week', 1);
      await add('old', 'goal', 5, 'User wants to run the Chicago marathon in under 3 hours', 1, true);
      const ranked = (query: string | null, limit = 8, pin = true) =>
        rpc('coach_memories_ranked_v1', { p_user: U_RANK, p_query: query, p_limit: limit, p_pin_safety: pin });
      const keyOf = (id: string) => Object.entries(ids).find(([, value]) => value === id)![0];
      const marathon = await ranked('Should I run the marathon?');
      assert.deepEqual(marathon.memories.map((m: any) => [keyOf(m.id), m.pinned]),
        [['inj1', true], ['inj2', true], ['inj3', true], ['goal', false], ['lift', false], ['inj4', false]]);
      assert.equal(marathon.total, 6, 'retired rows are not counted');
      assert.deepEqual(marathon.topics, { goal: 1, health: 2, injury: 2, training: 1 });
      assert.deepEqual(Object.keys(marathon.memories[0]).sort(), ['confirmations', 'content', 'created_at', 'id', 'importance',
        'pinned', 'source', 'topic', 'updated_at']);
      const plain = await ranked(null);
      assert.deepEqual(plain.memories.map((m: any) => keyOf(m.id)), ['inj1', 'inj2', 'inj3', 'lift', 'inj4', 'goal']);
      assert.deepEqual((await ranked('', 2)).memories.map((m: any) => keyOf(m.id)), ['inj1', 'inj2']);
      const unpinned = await ranked('marathon', 3, false);
      assert.equal(keyOf(unpinned.memories[0].id), 'goal');
      assert.ok(unpinned.memories.every((m: any) => m.pinned === false));
      assert.equal(unpinned.memories.length, 3);
      assert.deepEqual((await rpc('coach_memories_ranked_v1', { p_user: USER_B })).memories, [], 'owner scoped');
    });

    await t.step('context_manifest_v1: memories, thread, library and open loops in one call', async () => {
      const added = await applyOps(U_SEARCH, [{ op: 'add', content: 'User has a sore left knee', topic: 'injury',
        importance: 4, source: 'tool' }]);
      injuryMemory = added[0].id;
      await db.sql(`update public.coach_threads set
          open_loops = '["Pick a race-morning breakfast", {"text": "Check the knee after the long run"}]',
          summarized_at = now() - interval '1 day' where id = '${S.breakfast}';
        update public.coach_threads set open_loops = '["Old loop"]', summarized_at = now() - interval '10 days'
          where id = '${S.taper}';
        update public.coach_threads set open_loops = '["Own loop"]', summarized_at = now(), summary = 'User has knee pain.'
          where id = '${S.knee}';`);
      const manifest = await rpc('coach_context_manifest_v1', { p_user: U_SEARCH, p_thread: S.knee, p_query: 'knee' });
      assert.deepEqual(Object.keys(manifest).sort(), ['library', 'memories', 'memory_count', 'memory_revision',
        'memory_topics', 'open_loops', 'thread']);
      assert.deepEqual(manifest.memories.map((m: any) => [m.id, m.pinned]), [[injuryMemory, true]]);
      assert.deepEqual([manifest.memory_count, manifest.memory_topics, manifest.memory_revision], [1, { injury: 1 }, 1]);
      assert.deepEqual(manifest.thread, { id: S.knee, title: 'Knee pain while running', summary: 'User has knee pain.',
        summary_through: null, summary_messages: 0, message_count: 2, open_loops: ['Own loop'] });
      assert.deepEqual(Object.keys(manifest.library).sort(), ['first_at', 'last_at', 'recent', 'relevant', 'thread_count']);
      assert.equal(manifest.library.thread_count, 6);
      assert.equal(at(manifest.library.first_at), at('2026-07-10T10:00:00Z'));
      assert.equal(at(manifest.library.last_at), at('2026-09-25T10:01:00Z'));
      const recent = manifest.library.recent.map((entry: any) => entry.id);
      assert.equal(recent.length, 4, 'the current chat and a blocked-only chat are left out');
      assert.deepEqual([recent[2], recent[3]], [S.breakfast, S.taper]);
      assert.deepEqual(Object.keys(manifest.library.recent[0]).sort(), ['id', 'last_message_at', 'title']);
      const relevant = manifest.library.relevant;
      assert.ok(relevant.length > 0 && relevant.length <= 3);
      assert.ok(relevant.every((entry: any) => entry.id !== S.knee && entry.id !== S.blocked));
      assert.deepEqual(Object.keys(relevant[0]).sort(), ['id', 'last_message_at', 'snippet', 'title']);
      assert.match(relevant[0].snippet, /«knee»/i);
      assert.deepEqual(manifest.open_loops, [
        { thread_id: S.breakfast, title: 'Race breakfast', text: 'Pick a race-morning breakfast' },
        { thread_id: S.breakfast, title: 'Race breakfast', text: 'Check the knee after the long run' }]);
      const bare = await rpc('coach_context_manifest_v1', { p_user: U_SEARCH });
      assert.deepEqual([bare.thread, bare.library.relevant, bare.library.recent.length], [null, [], 5]);
      assert.equal(bare.open_loops.length, 3);
      const empty = await rpc('coach_context_manifest_v1', { p_user: U_QUOTA, p_query: 'knee' });
      assert.deepEqual(empty, { memories: [], memory_count: 0, memory_topics: {}, thread: null,
        library: { thread_count: 0, first_at: null, last_at: null, recent: [], relevant: [] }, open_loops: [], memory_revision: 0 });
      assert.equal((await rpc('coach_context_manifest_v1', { p_user: USER_B, p_thread: S.knee })).thread, null,
        "another owner's thread is never described");
    });

    await t.step('thread lease: claim, fencing, lease_lost and ops published atomically with the patch', async () => {
      const claim = (user = U_SEARCH, lease?: number) =>
        rpc('coach_thread_claim_v1', { p_user: user, p_thread: S.knee, ...(lease ? { p_lease_seconds: lease } : {}) });
      const publish = (token: string, patch: unknown, ops: unknown) =>
        rpc('coach_thread_publish_v1', { p_user: U_SEARCH, p_thread: S.knee, p_token: token, p_patch: patch, p_ops: ops });
      const claimed = await claim();
      assert.equal(claimed.claimed, true);
      assert.match(claimed.token, /^[0-9a-f-]{36}$/);
      assert.deepEqual({ ...claimed, token: undefined }, { claimed: true, token: undefined, summary: 'User has knee pain.',
        summary_through: null, summary_messages: 0, curated_through: null, message_count: 2,
        title: 'Knee pain while running', title_source: 'fallback', memory_floor_at: null });
      assert.deepEqual(await claim(), { claimed: false }, 'a held lease is not handed out twice');
      assert.deepEqual(await claim(USER_B), { claimed: false }, 'another owner cannot claim it');
      assert.deepEqual(await publish(uuid(), { summary: 'wrong token' }, []), { applied: false, reason: 'lease_lost', ops: [] });
      assert.equal((await thread(S.knee)).summary, 'User has knee pain.');
      // A failing op rolls the whole publish back: the summary is unchanged and the lease is still held.
      await assert.rejects(() => publish(claimed.token, { summary: 'partial' },
        Array.from({ length: 101 }, () => ({ op: 'confirm', id: injuryMemory }))), /invalid_ops/);
      assert.deepEqual([(await thread(S.knee)).summary, (await thread(S.knee)).maintenance_token],
        ['User has knee pain.', claimed.token]);
      const through = '2026-09-20T10:01:00.000Z';
      const published = await publish(claimed.token, { summary: 'User has knee pain after long runs.',
        summary_topics: ['knee', 'running'], open_loops: ['Check knee in a week'], summary_through: through, summary_messages: 2,
        curated_through: through, summarized_at: iso(NOW) },
        [{ op: 'add', content: 'User runs long on Sundays', topic: 'training', importance: 3, source: 'curator' },
          { op: 'confirm', id: injuryMemory }]);
      assert.equal(published.applied, true);
      assert.equal(published.reason, 'published');
      assert.deepEqual(published.ops.map((op: any) => [op.op, op.applied]), [['add', true], ['confirm', true]]);
      assert.deepEqual(published.ops[1].id, injuryMemory);
      const after = await thread(S.knee);
      assert.deepEqual([after.summary, after.summary_topics, after.open_loops, at(after.summary_through), after.summary_messages,
        at(after.curated_through), at(after.summarized_at), after.maintenance_token, after.maintenance_until],
        ['User has knee pain after long runs.', ['knee', 'running'], ['Check knee in a week'], at(through), 2, at(through), NOW,
          null, null]);
      const curated = await memory(published.ops[0].id);
      assert.deepEqual([curated.source, curated.source_thread_id, curated.topic], ['curator', S.knee, 'training']);
      assert.equal((await memory(injuryMemory)).confirmations, 2);
      assert.equal(await one(`select string_agg(actor || ':' || op, ',' order by id) from public.coach_memory_events
        where user_id = '${U_SEARCH}' and thread_id = '${S.knee}'`), 'curator:add,curator:confirm');
      assert.deepEqual(await publish(claimed.token, { summary: 'again' }, []), { applied: false, reason: 'lease_lost', ops: [] },
        'publishing releases the lease');
      // An expired lease is lost to its holder and can be taken by the next claim.
      const second = await claim(undefined, 30);
      assert.equal(second.claimed, true);
      assert.equal(second.summary, 'User has knee pain after long runs.');
      await db.sql(`update public.coach_threads set maintenance_until = now() - interval '1 second' where id = '${S.knee}'`);
      assert.equal((await publish(second.token, { summary: 'too late' }, [])).reason, 'lease_lost');
      const third = await claim();
      assert.equal(third.claimed, true);
      assert.notEqual(third.token, second.token);
      assert.deepEqual(await publish(third.token, {}, []), { applied: true, reason: 'published', ops: [] });
      assert.equal((await thread(S.knee)).summary, 'User has knee pain after long runs.', 'an empty patch changes nothing');
    });

    await t.step('memory_apply_v1: add, update, confirm, retire, merge, forget and the memory_revision rules', async () => {
      const results = (ops: any[]) => ops.map((op) => [op.op, op.applied, op.reason ?? null]);
      // add: an important goal moves the revision; a low preference or a general row does not.
      const [goal] = await applyOps(U_APPLY, [{ op: 'add', content: 'User wants to run a sub-3 marathon', topic: 'goal',
        importance: 4, source: 'tool' }]);
      assert.equal(goal.applied, true);
      assert.equal(await revision(U_APPLY), 1);
      const [pref, shoes] = await applyOps(U_APPLY, [
        { op: 'add', content: 'User prefers morning runs', topic: 'preference', importance: 2, source: 'curator' },
        { op: 'add', content: 'User likes trail shoes', topic: 'astrology', importance: '7' }], 'curator');
      assert.equal(await revision(U_APPLY), 1);
      assert.deepEqual([(await memory(shoes.id)).topic, (await memory(shoes.id)).importance, (await memory(shoes.id)).source],
        ['general', 5, 'curator']);
      assert.deepEqual([(await memory(pref.id)).version, (await memory(pref.id)).confirmations], [1, 1]);
      // update: version, updated_at and last_confirmed_at move; the event records before and after.
      const prefBefore = await memory(pref.id);
      await sleep(5);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'update', id: pref.id, content: 'User prefers early morning runs' }])),
        [['update', true, null]]);
      const prefAfter = await memory(pref.id);
      assert.deepEqual([prefAfter.content, prefAfter.version, prefAfter.importance], ['User prefers early morning runs', 2, 2]);
      assert.ok(at(prefAfter.updated_at)! > at(prefBefore.updated_at)!);
      assert.ok(at(prefAfter.last_confirmed_at)! > at(prefBefore.last_confirmed_at)!);
      const event = await json(`select to_jsonb(e) from public.coach_memory_events e where memory_id = '${pref.id}' and op = 'update'`);
      assert.deepEqual([event.actor, event.before.content, event.after.content, event.after.version],
        ['tool', 'User prefers morning runs', 'User prefers early morning runs', 2]);
      assert.equal(await revision(U_APPLY), 1);
      await applyOps(U_APPLY, [{ op: 'update', id: goal.id, importance: 5 }]);
      assert.equal(await revision(U_APPLY), 2, 'an update of an important goal moves the revision');
      // confirm: confirmations and last_confirmed_at only; importance is never raised.
      await sleep(5);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'confirm', id: pref.id, importance: 5 }])), [['confirm', true, null]]);
      const confirmed = await memory(pref.id);
      assert.deepEqual([confirmed.confirmations, confirmed.importance, confirmed.version], [2, 2, 2]);
      assert.ok(at(confirmed.last_confirmed_at)! > at(prefAfter.last_confirmed_at)!);
      assert.equal(await revision(U_APPLY), 2);
      // retire: soft, with its reason and tokens; a retired row takes no further op except forget.
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'retire', id: goal.id, reason: 'contradicted',
        tokens: ['sub', 'marathon'] }], 'curator')), [['retire', true, null]]);
      const retired = await memory(goal.id);
      assert.ok(retired.retired_at);
      assert.equal(retired.retired_reason, 'contradicted');
      assert.deepEqual(await json(`select to_jsonb(tokens) from public.coach_memory_events where memory_id = '${goal.id}' and op = 'retire'`),
        ['sub', 'marathon']);
      assert.equal(await revision(U_APPLY), 3);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'retire', id: goal.id, reason: 'again' },
        { op: 'update', id: goal.id, content: 'User x' }, { op: 'confirm', id: goal.id }])),
        [['retire', false, 'retired'], ['update', false, 'retired'], ['confirm', false, 'retired']]);
      assert.equal((await rpc('coach_memories_ranked_v1', { p_user: U_APPLY })).memories.some((m: any) => m.id === goal.id), false);
      // merge: the kept row sums confirmations and takes the merged content; the others retire as merged.
      const garmin = await applyOps(U_APPLY, [
        { op: 'add', content: 'User owns a Garmin watch', topic: 'general', importance: 2 },
        { op: 'add', content: 'User has a Garmin', topic: 'general', importance: 2 },
        { op: 'add', content: 'User wears a Garmin Forerunner', topic: 'general', importance: 2 }]);
      const [keep, m2, m3] = garmin.map((op: any) => op.id);
      await db.sql(`update public.coach_memory_items set confirmations = 2 where id = '${keep}'`);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'merge', keep_id: keep, ids: [m2, m3, uuid(), keep],
        content: 'User wears a Garmin Forerunner watch', topic: 'general', importance: 3 }], 'consolidator')),
        [['merge', true, null]]);
      const kept = await memory(keep);
      assert.deepEqual([kept.content, kept.confirmations, kept.version, kept.importance, kept.retired_at],
        ['User wears a Garmin Forerunner watch', 4, 2, 3, null]);
      assert.deepEqual([(await memory(m2)).retired_reason, (await memory(m3)).retired_reason], ['merged', 'merged']);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_APPLY}' and op = 'merge' and actor = 'consolidator'`), 3);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'merge', keep_id: keep, ids: [m2], content: 'x' }])),
        [['merge', false, 'nothing_to_merge']]);
      assert.equal(await revision(U_APPLY), 3, 'general rows never move the revision');
      // forget: the row goes, earlier events lose their content, the tombstone keeps only tokens.
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'forget', id: pref.id }], 'user')), [['forget', true, null]]);
      assert.equal(await memory(pref.id), null);
      const tombstone = await json(`select to_jsonb(e) from public.coach_memory_events e where memory_id = '${pref.id}' and op = 'forget'`);
      assert.deepEqual([tombstone.actor, tombstone.tokens, tombstone.after], ['user', ['early', 'morn', 'prefer', 'run'], null]);
      assert.equal(tombstone.before.content, undefined);
      assert.equal(await count(`public.coach_memory_events where memory_id = '${pref.id}'
        and (before ? 'content' or after ? 'content')`), 0, 'no event keeps the forgotten content');
      await applyOps(U_APPLY, [{ op: 'forget', id: shoes.id, tokens: ['trail', 'shoe'] }], 'user');
      assert.deepEqual(await json(`select to_jsonb(tokens) from public.coach_memory_events where memory_id = '${shoes.id}' and op = 'forget'`),
        ['trail', 'shoe']);
      assert.equal(await revision(U_APPLY), 3);
      // Ownership, unknown ops, bad content and a bad actor.
      const [ofB] = await applyOps(USER_B, [{ op: 'add', content: 'User B fact', topic: 'goal', importance: 2 }]);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'update', id: ofB.id, content: 'hijacked' },
        { op: 'forget', id: ofB.id }, { op: 'merge', keep_id: keep, ids: [ofB.id], content: 'x' }])),
        [['update', false, 'not_found'], ['forget', false, 'not_found'], ['merge', false, 'nothing_to_merge']]);
      assert.deepEqual([(await memory(ofB.id)).content, (await memory(ofB.id)).retired_at], ['User B fact', null]);
      assert.deepEqual(results(await applyOps(U_APPLY, [{ op: 'explode' }, { op: 'add', content: '   ' },
        { op: 'add', content: 'x'.repeat(501) }])),
        [['explode', false, 'unknown_op'], ['add', false, 'invalid_content'], ['add', false, 'invalid_content']]);
      await assert.rejects(() => applyOps(U_APPLY, [], 'robot'), /invalid_actor/);
      await assert.rejects(() => applyOps(U_APPLY, { op: 'add' } as unknown as unknown[]), /invalid_ops/);
    });

    await t.step('memory_apply_v1: forget_all clears everything and sets the floor', async () => {
      await db.sql(`update public.coach_user_state set recent_searches = '["knee pain"]', suggestions = '[{"text": "x"}]',
        suggestions_fingerprint = 'abc', suggestions_at = now() where user_id = '${U_APPLY}'`);
      const rows = await count(`public.coach_memory_items where user_id = '${U_APPLY}'`);
      assert.ok(rows >= 4, 'active and retired rows exist');
      const before = await revision(U_APPLY);
      assert.deepEqual(await applyOps(U_APPLY, [{ op: 'forget_all' }], 'user'), [{ op: 'forget_all', id: null, applied: true }]);
      assert.equal(await count(`public.coach_memory_items where user_id = '${U_APPLY}'`), 0);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_APPLY}' and op = 'forget'
        and reason = 'forget_all' and cardinality(tokens) > 0`), rows);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_APPLY}'
        and (before ? 'content' or after ? 'content')`), 0);
      const state = await userState(U_APPLY);
      assert.ok(state.memory_floor_at);
      assert.deepEqual([state.recent_searches, state.suggestions, state.suggestions_fingerprint, state.suggestions_at],
        [[], [], null, null]);
      assert.equal(await revision(U_APPLY), before + 1);
      assert.equal(await count(`public.coach_memory_items where user_id = '${USER_B}'`), 1, "B's memories are untouched");
    });

    await t.step('memory_apply_v1: the 200-row cap evicts softly; retention of retired rows and events', async () => {
      const victim = uuid();
      await db.sql(`insert into public.coach_memory_items (user_id, content, topic, importance)
          select '${U_CAP}', 'Fact number ' || n, 'general', 3 from generate_series(1, 199) n;
        insert into public.coach_memory_items (id, user_id, content, topic, importance, created_at, updated_at, last_confirmed_at)
          values ('${victim}', '${U_CAP}', 'An old minor fact', 'general', 1, now() - interval '300 days',
                  now() - interval '300 days', now() - interval '300 days');`);
      const result = await applyOps(U_CAP, [{ op: 'add', content: 'User swims on Fridays', topic: 'routine', importance: 3 }]);
      assert.equal(result.length, 2);
      assert.deepEqual(result[1], { op: 'evict', id: victim, applied: true, reason: 'cap' });
      assert.deepEqual([(await memory(victim)).retired_reason, Boolean((await memory(victim)).retired_at)], ['evict', true]);
      assert.equal(await count(`public.coach_memory_items where user_id = '${U_CAP}' and retired_at is null`), 200);
      assert.equal(await count(`public.coach_memory_events where memory_id = '${victim}' and op = 'evict'`), 1);
      assert.equal(await revision(U_CAP), 0, 'neither the routine add nor a minor eviction moves the revision');
      // Retired rows are purged after 30 days.
      await db.sql(`update public.coach_memory_items set retired_at = now() - interval '31 days', retired_reason = 'x'
          where id = '${victim}';
        update public.coach_memory_items set retired_at = now() - interval '29 days', retired_reason = 'x'
          where user_id = '${U_CAP}' and content = 'Fact number 1';`);
      // Events: the newest 1,000 are kept; forget tombstones beyond them stay for 365 days.
      await db.sql(`insert into public.coach_memory_events (user_id, op, actor, created_at)
          select '${U_CAP}', 'confirm', 'tool', now() - interval '2 days' + n * interval '1 millisecond'
            from generate_series(1, 1005) n;
        insert into public.coach_memory_events (user_id, op, actor, tokens, created_at)
          select '${U_CAP}', 'forget', 'user', '{a}', now() - interval '10 days' from generate_series(1, 3);
        insert into public.coach_memory_events (user_id, op, actor, tokens, created_at)
          values ('${U_CAP}', 'forget', 'user', '{old}', now() - interval '400 days');`);
      const fact = await one(`select id from public.coach_memory_items where user_id = '${U_CAP}' and content = 'Fact number 2'`);
      await applyOps(U_CAP, [{ op: 'confirm', id: fact }]);
      assert.equal(await memory(victim), null, 'retired for more than 30 days: purged');
      assert.equal(await count(`public.coach_memory_items where user_id = '${U_CAP}' and content = 'Fact number 1'`), 1);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_CAP}' and op <> 'forget'`), 1000);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_CAP}' and op = 'forget'`), 3);
      assert.equal(await count(`public.coach_memory_events where user_id = '${U_CAP}' and op = 'confirm' and memory_id = '${fact}'`), 1,
        'the newest event survives');
    });

    await t.step('consolidation_claim_v1: due by size or age, one holder at a time', async () => {
      const claim = () => rpc('coach_consolidation_claim_v1', { p_user: U_CONS });
      const memories = (from: number, to: number) => db.sql(`insert into public.coach_memory_items (user_id, content, topic)
        select '${U_CONS}', 'Memory ' || n, 'general' from generate_series(${from}, ${to}) n`);
      await memories(1, 40);
      assert.equal(await claim(), false, '40 memories are not enough');
      await memories(41, 41);
      assert.equal(await claim(), true, 'more than 40 and never consolidated');
      assert.ok((await userState(U_CONS)).consolidation_until);
      assert.equal(await claim(), false, 'the lease is held');
      assert.deepEqual(await applyOps(U_CONS, [{ op: 'consolidated' }], 'consolidator'),
        [{ op: 'consolidated', id: null, applied: true }]);
      const state = await userState(U_CONS);
      assert.deepEqual([Boolean(state.consolidated_at), state.consolidation_until], [true, null]);
      assert.equal(await claim(), false, 'consolidated within 72 hours');
      await db.sql(`update public.coach_user_state set consolidated_at = now() - interval '73 hours' where user_id = '${U_CONS}'`);
      assert.equal(await claim(), true, 'more than 72 hours ago');
      await applyOps(U_CONS, [{ op: 'consolidated' }], 'consolidator');
      await memories(42, 121);
      assert.equal(await claim(), true, 'more than 120 memories, however recent');
      await db.sql(`update public.coach_user_state set consolidation_until = now() - interval '1 second' where user_id = '${U_CONS}'`);
      assert.equal(await claim(), true, 'an expired lease can be taken');
      await db.sql(`update public.coach_memory_items set retired_at = now() where user_id = '${U_CONS}'
        and content <> all (array(select 'Memory ' || n from generate_series(1, 41) n))`);
      await applyOps(U_CONS, [{ op: 'consolidated' }], 'consolidator');
      await db.sql(`update public.coach_user_state set consolidated_at = now() - interval '73 hours' where user_id = '${U_CONS}'`);
      assert.equal(await claim(), true, 'retired rows are not counted, 41 active is still over 40');
      assert.equal(await rpc('coach_consolidation_claim_v1', { p_user: USER_B }), false);
    });

    await t.step('utility quota: atomic, all units or none, separate from the chat quota', async () => {
      const take = (limit: number, units?: number) =>
        rpc('coach_take_utility_quota', { p_user_id: U_QUOTA, p_limit: limit, ...(units ? { p_units: units } : {}) });
      assert.deepEqual([await take(3), await take(3), await take(3), await take(3)], [true, true, true, false]);
      assert.equal(await one(`select utility_calls || ':' || calls from public.coach_usage where user_id = '${U_QUOTA}'`), '3:0');
      assert.equal(await take(10, 4), true);
      assert.equal(await take(10, 4), false, 'would reach 11');
      assert.equal(await take(10, 3), true);
      assert.equal(await one(`select utility_calls from public.coach_usage where user_id = '${U_QUOTA}'`), '10');
      assert.equal(await take(0), false);
      assert.equal(await take(100, 101), false);
      assert.equal(await rpc('coach_take_quota', { p_user_id: U_QUOTA, p_limit: 1 }), true, 'the chat quota is its own');
      // Concurrent callers never overshoot.
      const replies = await Promise.all(Array.from({ length: 20 },
        () => rpc('coach_take_utility_quota', { p_user_id: U_PRUNE, p_limit: 5 })));
      assert.equal(replies.filter(Boolean).length, 5);
      assert.equal(await one(`select utility_calls from public.coach_usage where user_id = '${U_PRUNE}'`), '5');
      await rpc('coach_add_utility_tokens', { p_user_id: U_QUOTA, p_tokens: 1200 });
      await rpc('coach_add_utility_tokens', { p_user_id: U_QUOTA, p_tokens: 34 });
      await rpc('coach_add_utility_tokens', { p_user_id: U_QUOTA, p_tokens: -50 });
      await rpc('coach_add_utility_tokens', { p_user_id: U_CONS, p_tokens: 0 });
      assert.equal(await one(`select utility_tokens || ':' || utility_calls || ':' || calls from public.coach_usage
        where user_id = '${U_QUOTA}'`), '1234:10:1');
      assert.equal(await count(`public.coach_usage where user_id = '${U_CONS}'`), 0, 'zero tokens write nothing');
    });

    await t.step('a caller signed in as someone else is refused', async () => {
      const rows = JSON.stringify([row({ thread_id: uuid(), content: 'cross' })]).replaceAll("'", "''");
      await assert.rejects(() => db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub', '${USER_B}', true);
        select public.coach_messages_save_v1('${USER_A}'::uuid, '${rows}'::jsonb); rollback;`), /cross_user_caller/);
      await assert.rejects(() => db.sql(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub', '${USER_B}', true);
        select public.coach_search_v1('${USER_A}'::uuid, 'knee'); rollback;`), /cross_user_caller/);
      await assert.rejects(() => db.sql(`select public.coach_memories_ranked_v1(null)`), /invalid_owner/);
      assert.equal(await count(`public.coach_messages where content = 'cross'`), 0);
      const own = await one(`begin; set local role service_role;
        select set_config('request.jwt.claim.sub', '${USER_A}', true);
        select (public.coach_messages_save_v1('${USER_A}'::uuid, '${rows}'::jsonb) ->> 'saved'); rollback;`);
      assert.match(own, /\n1$/);
    });

    await t.step('deleting the account removes every coach row, in the deletion order and through the cascade', async () => {
      const coachTables = ['coach_messages', ...NEW_TABLES, 'coach_memory_items', 'coach_usage'];
      const rowsOf = async (user: string) => {
        const counts: Record<string, number> = {};
        for (const table of coachTables) counts[table] = await count(`public.${table} where user_id = '${user}'`);
        return counts;
      };
      // The deletion worker's order (DELETION_TABLES): messages, then tombstones, threads and folders.
      await db.sql(`insert into public.coach_folders (id, user_id, name) values (gen_random_uuid(), '${U_LEGACY}', 'Old');
        insert into public.coach_thread_tombstones (user_id, thread_id) values ('${U_LEGACY}', gen_random_uuid());`);
      for (const table of ['coach_messages', 'coach_thread_tombstones', 'coach_threads', 'coach_folders']) {
        await db.rest.delete(table, `user_id=eq.${U_LEGACY}`);
      }
      const legacy = await rowsOf(U_LEGACY);
      for (const table of ['coach_messages', 'coach_thread_tombstones', 'coach_threads', 'coach_folders']) {
        assert.equal(legacy[table], 0, `${table} emptied by the worker`);
      }
      // The auth.users cascade, with every kind of row present.
      await db.sql(`insert into public.coach_folders (id, user_id, name) values (gen_random_uuid(), '${U_SEARCH}', 'Runs');
        insert into public.coach_thread_tombstones (user_id, thread_id) values ('${U_SEARCH}', gen_random_uuid());`);
      await rpc('coach_take_utility_quota', { p_user_id: U_SEARCH, p_limit: 5 });
      const before = await rowsOf(U_SEARCH);
      assert.ok(Object.values(before).every((n) => n > 0), JSON.stringify(before));
      const others = await count(`public.coach_messages where user_id <> '${U_SEARCH}'`);
      await db.sql(`delete from auth.users where id = '${U_SEARCH}'`);
      assert.ok(Object.values(await rowsOf(U_SEARCH)).every((n) => n === 0));
      assert.equal(await count(`public.coach_messages where user_id <> '${U_SEARCH}'`), others);
    });

    await t.step('re-applying the migration at the end keeps every row and count', async () => {
      const snapshot = () => json(`select jsonb_build_object(
          'threads', (select jsonb_agg(jsonb_build_array(id, message_count, last_message_at, preview, title, summary) order by id)
                        from public.coach_threads),
          'messages', (select count(*) from public.coach_messages),
          'memories', (select count(*) from public.coach_memory_items),
          'events', (select count(*) from public.coach_memory_events),
          'state', (select jsonb_agg(to_jsonb(s) order by user_id) from public.coach_user_state s))`);
      const before = await snapshot();
      await apply();
      assert.deepEqual(await snapshot(), before);
      assert.equal(await count(`pg_trigger where not tgisinternal and tgname like 'coach_%'`), 4);
      assert.equal(await count(`pg_policies where schemaname = 'public' and tablename like 'coach_%' and policyname like '%_service'`), 5);
    });
  } finally {
    await db.close();
  }
});
