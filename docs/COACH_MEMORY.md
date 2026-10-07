# Sana memory, threads and context (RLM-style)

This document is both the design and the implementation contract for Sana's persistent memory: chat
threads and folders, durable memories, and the context system the model uses to reach a user's history.
It covers the backend (`supabase/`) and the iOS client (`Strand/Coach`, `StrandiOS/Coach`). The macOS
and Android coaches use the user's own model key and are unchanged.

## 1. Why this shape

The coach's tool loop runs on the phone. The `coach` edge function holds the model key, relays model
calls, and stores conversations and memory. Wearable history lives on the phone: `Repository.days` holds
up to 4,000 days in memory. Conversations and memories live in Postgres.

The design borrows from Prime Agent and Recursive Language Models (RLM), adapted to that split:

| Prime / RLM idea | Sana equivalent |
|---|---|
| Context is a variable in the environment. The root model sees its type and size, not its contents. | A **context library manifest** in the dynamic tail of each turn's system prompt. It names what exists (earlier chats with dates, the most relevant earlier chats, saved memories by topic, wearable coverage) and which tool inspects each. It never includes contents. |
| Peek, grep and slice from code. | **Typed inspection tools** with capped results: `search_conversations` (ranked Postgres full-text, or browse by date), `read_conversation` (paged, or around matches), and `query_metric_history` / `find_days` (on the phone, over up to 4,000 days). |
| `llm_query` / `llm_batch` map over chunks. | **`recall_context`** runs server-side in one round trip. Lexical candidates, or every thread summary in a date window, are partitioned into chunks. A cheap model maps over the chunks in one bounded wave, and a reduce step merges them only when needed. Recursion depth is 1. There is a hard deadline. The sub-model's output is evidence, never the reply, and it reports coverage. |
| Ranked harness digest (top-k, lexical TF-IDF, "+N more, use search"). | **Relevant memories** are ranked per question (lexical relevance, importance, recency) instead of taking the first 8. Safety-critical memories (injury or health, importance 4 or more) are always included. Everything stays queryable through `get_memories`. |
| Incremental compaction: an `UPDATE` summary merge plus a recent tail. | A **rolling summary per thread**, built incrementally by a cheap model. The phone sends the newest 28 messages. A thread longer than that also gets the summary of its older turns. |
| Continual-harness refinement: review gate, JSON edit proposal, validated apply, audit. | A **memory curator** that runs after each turn on a cheap model. Ops are add, update, confirm or retire; "no ops" is the preferred outcome; at most 4 per batch. Deterministic guards on the server: grounding, transient and sensitive filters, number-aware near-duplicate checks, and tombstones for forgotten facts. Ops are applied atomically with the summary, fenced by a lease, and audited in `coach_memory_events`. A periodic **consolidation** pass merges duplicates. Retiring a memory is soft. |
| Side questions (`/btw`): tools blocked, nothing written to history. | **Titles, follow-ups and starter suggestions** are side calls to the cheap model. They are never chat messages. |
| An auxiliary model for background passes. | `COACH_MODEL_UTILITY` (cheap, JSON) is used for titles, follow-ups, suggestions, summaries, curation and recall. The answer model is unchanged. |

**What we do not do:**
- Dump history into the prompt.
- Use vector similarity as the intelligence layer. Search is lexical (Postgres `tsvector`, scoped by user through `btree_gin`) plus structure: threads, dates, topics and summaries.
- Run model-written code. A Prime process costs about 16–21 s and about 100k tokens per run.
- Spend the user's chat quota on background work. Background work has its own utility budget.

**Safety invariant.**
- Turns blocked by `CoachSafety.screenInput`, and their refusals, are stored with `meta.blocked = true`. The generated column `blocked` excludes them from summaries, curation, search, recall, follow-ups and suggestions.
- Every model-produced string the phone shows or feeds back into a prompt goes through `CoachSafety` on the phone first: titles, follow-ups, starters, memory lines and summary lines.

## 2. Data model: `supabase/migrations/20261007160000_coach_threads_memory.sql`

The migration is additive and can be re-applied safely. It runs `begin; set local lock_timeout='10s';
set local statement_timeout='120s'; … commit;`.

Every new table:
- is service-role only: RLS on, `revoke all … from public, anon, authenticated`, `grant all … to service_role`, and a `<t>_service` policy for `service_role`;
- has an owner column `user_id uuid not null references auth.users(id) on delete cascade`.

Helper and trigger functions live in schema `internal`. Public RPCs are `security definer set
search_path = ''`, revoked from clients, granted to `service_role`, and listed in
`SERVICE_ONLY_FUNCTIONS`.

`create extension if not exists btree_gin with schema extensions;`

### `coach_folders`
| Column | Type and notes |
|---|---|
| `id` | uuid pk (generated by the client) |
| `user_id` | uuid |
| `name` | text, trimmed length 1..60 |
| `sort_order` | int default 0 |
| `created_at`, `updated_at` | timestamptz |

Also `unique(id, user_id)` and an index on `(user_id, sort_order, created_at)`.

### `coach_threads`
| Column | Type and notes |
|---|---|
| `id` | uuid pk (generated by the client) |
| `user_id` | uuid |
| `title` | text, null or 1..120 characters |
| `title_source` | text default 'none', one of `none \| auto \| user \| fallback \| legacy` |
| `folder_id` | uuid, references `coach_folders(id)` on delete set null. Trigger `internal.coach_thread_folder_owner` raises `42501` if the folder belongs to another user. |
| `pinned` | bool default false |
| `origin` | text default 'app', one of `app \| legacy_client \| backfill` |
| `created_at`, `updated_at` | timestamptz |
| `last_message_at` | timestamptz |
| `message_count` | int default 0 |
| `preview` | text, ≤ 160 characters |
| `summary` | text, ≤ 2400 characters |
| `summary_topics` | text[] default '{}' |
| `open_loops` | jsonb default '[]' |
| `summary_through` | timestamptz |
| `summary_messages` | int default 0 |
| `curated_through` | timestamptz |
| `summarized_at` | timestamptz |
| `maintenance_token` | uuid |
| `maintenance_until` | timestamptz |
| `search` | tsvector generated stored: `setweight(to_tsvector('english', coalesce(title,'')),'A') \|\| setweight(to_tsvector('english', coalesce(summary,'')),'B')` |

- The trigger keeps `last_message_at`, `message_count`, `preview` and `updated_at` current.
- `unique(id, user_id)`.
- Indexes: `(user_id, pinned desc, last_message_at desc nulls last, id)`, and `gin (user_id, search)`.

### `coach_thread_tombstones`
- Columns: `(user_id, thread_id uuid, deleted_at timestamptz default now())`, pk `(user_id, thread_id)`.
- A save for a tombstoned thread is rejected with `thread_deleted`. The client then drops it.
- Rows older than 90 days are purged opportunistically by `coach_messages_save_v1`.

### `coach_messages` (existing table; additive changes)
- `thread_id uuid`, with composite FK `(thread_id, user_id)` → `coach_threads(id, user_id)` on delete cascade.
- `blocked boolean generated always as (coalesce((meta->>'blocked')::boolean, false)) stored`.
- `search tsvector generated always as (setweight(to_tsvector('english', left(content, 8000)), case when role = 'user' then 'A'::"char" else 'B'::"char" end)) stored`.
- Indexes: `(user_id, thread_id, created_at desc, id desc)` and `gin (user_id, search)`.
- Trigger `internal.coach_messages_thread_stats`, after insert, delete or update of thread_id/content:
  - adjusts the thread's `message_count`;
  - sets `last_message_at = greatest(...)`;
  - sets `preview` from the newest message (first 160 characters, whitespace collapsed);
  - sets `updated_at = now()`.
- **Backfill.**
  - Rows with a null `client_id` get `client_id = gen_random_uuid()`.
  - Rows with `thread_id is null` are grouped per user into threads, starting a new thread wherever consecutive messages are more than 3 hours apart.
  - Each group's title is the first user message with whitespace collapsed, cut at a word boundary to 60 characters; `title_source='legacy'`, `origin='backfill'`.
  - The thread's counts and preview are computed in the insert.
  - The stats trigger is created after the backfill, using `drop trigger if exists` first.

### `coach_memory_items` (existing table; additive changes)
- Columns:
  - `updated_at`, `last_confirmed_at` (backfilled from `created_at`);
  - `confirmations int default 1`;
  - `source text default 'tool'`, one of `tool | curator | user | legacy`;
  - `source_thread_id uuid`;
  - `version int default 1`;
  - `retired_at timestamptz`, `retired_reason text`;
  - `search tsvector generated stored` = `to_tsvector('english', topic || ' ' || content)`.
- Index `(user_id) where retired_at is null`.
- **Readers ignore retired rows.** Rows retired more than 30 days ago are purged by `coach_memory_apply_v1`.
- Topics accepted: `goal, injury, preference, achievement, lifestyle, routine, health, training, nutrition, sleep, general`. Anything else is stored as `general`.

### `coach_memory_events` (new; audit trail and tombstones)
- Columns:
  - `id bigint identity pk`, `user_id`, `memory_id uuid`;
  - `op`: `add | update | confirm | retire | merge | forget | evict`;
  - `actor`: `tool | curator | user | consolidator`;
  - `before jsonb`, `after jsonb`, `thread_id uuid`;
  - `reason text ≤ 300`;
  - `tokens text[]`: the normalised token set, set for `forget` (a tombstone) and for `retire`;
  - `created_at`.
- Index `(user_id, created_at desc)`.
- Each user keeps the newest 1,000 events, except that `forget` events are kept for 365 days.

### `coach_user_state` (new; one row per user)
- `user_id` pk
- `suggestions jsonb default '[]'`, `suggestions_fingerprint text`, `suggestions_at`
- `recent_searches jsonb default '[]'` (≤ 10 strings, newest first, deduplicated case-insensitively)
- `consolidated_at`, `consolidation_until`
- `memory_revision bigint default 0`. It is bumped only by add, update, retire, merge or forget of importance ≥ 4 `goal|injury|health|training` rows, or by forget-all. This keeps future fingerprints stable; see the metric-insight branch.
- `memory_floor_at timestamptz`. Set by forget-all. The curator never mines messages older than this.
- `updated_at`

### `coach_usage` (existing)
- Adds `utility_calls int default 0` and `utility_tokens bigint default 0`.

## 3. RPCs (all `public`, service role only)

**`coach_take_utility_quota(p_user_id uuid, p_limit int, p_units int default 1) returns boolean`**
- Atomic, the same shape as `coach_take_quota`, but it uses `utility_calls`.
- `coach_add_utility_tokens(p_user_id uuid, p_tokens int) returns void` adds to `utility_tokens`.

**`coach_messages_save_v1(p_user uuid, p_rows jsonb) returns jsonb`**
- Row shape: `{client_id uuid, thread_id uuid|null, role 'user'|'assistant', content text, meta jsonb, created_at timestamptz, thread_title text|null}`. The caller has already validated the rows.
- A row with a null `thread_id` comes from an old app build. It keeps the stored thread of an existing `client_id`. Otherwise it joins the user's newest `origin='legacy_client'` thread whose `last_message_at` is within 3 h. Otherwise a new uuid is used, with origin `legacy_client`.
- For each distinct thread:
  - A tombstone for this user rejects the thread's rows with `thread_deleted`.
  - A thread owned by another user rejects them with `thread_conflict`.
  - A missing thread is inserted with origin `app`, or `legacy_client` for a null input. Its `title` is `thread_title` (`title_source='fallback'`) when given; otherwise the title stays null.
- Messages are written with:

  ```
  insert … on conflict (user_id, client_id) do update set
    content = excluded.content,
    role    = excluded.role,
    meta    = coach_messages.meta || excluded.meta,
    thread_id = coalesce(coach_messages.thread_id, excluded.thread_id)
  ```
  `created_at` keeps its first value.
- Then the user's messages beyond **50,000** are pruned, oldest first.
- Returns `{saved:int, rejected:[{client_id, reason}], threads:[{id, created:bool}]}`.

**`coach_search_v1(p_user uuid, p_query text, p_limit int default 20, p_thread_limit int default 8, p_exclude_thread uuid default null, p_from timestamptz default null, p_to timestamptz default null) returns jsonb`**
- Only non-blocked messages are searched, inside `[p_from, p_to)` when given.
- **Terms:**
  - Distinct lexemes of `to_tsvector('english', p_query)`, at most 16.
  - When the user has 40 or more messages and 2 or more terms, drop every term that matches more than 15% of the user's messages (`dropped_terms`).
  - `q` = OR of the remaining terms.
- **Rank:** `ts_rank_cd(search, q, 1|32) * (1 + 0.25*exp(-age_days/90))`.
- **Thread-grouped path:**
  - Group the message matches by thread, with `hits = count(*)` and `best = max(rank)`.
  - Union the threads whose title or summary matches `coach_threads.search @@ q`.
  - Order by `best * (1 + ln(hits))`, limited to `p_thread_limit`.
  - Snippets come from `ts_headline` (`MaxWords=26, MinWords=8, MaxFragments=1, StartSel=«, StopSel=»`), computed only for the best message of each returned thread and for the top `p_limit` hits.
- **Browse mode:** when `p_query` is empty or has no lexemes, it returns the threads with activity in `[p_from, p_to)` (newest first, up to `p_thread_limit`), with `hits` 0, and the title, summary and topics. That serves "what did we talk about in August".
- Returns:

  ```
  {terms, dropped_terms, total_hits,
   months:[{month:'YYYY-MM', hits}],
   hits:[{thread_id, message_id, role, created_at, rank, snippet}],
   threads:[{thread_id, title, last_message_at, hits, best_rank, snippet, summary, topics}]}
  ```
  `summary` is cut to 300 characters.
- Clamps: `p_limit` 1..50, `p_thread_limit` 1..30.

**`coach_memories_ranked_v1(p_user uuid, p_query text default null, p_limit int default 8, p_pin_safety boolean default true) returns jsonb`**
- Active rows only.
- If `p_pin_safety`, up to 3 `injury|health` rows with importance ≥ 4 come first, ordered by importance then `last_confirmed_at`.
- The remaining rows are ranked by:

  ```
  score = 3*lex + importance/5.0 + 0.5*exp(-days_since_last_confirmed/120) + 0.2*ln(1+confirmations)
  ```
  `lex = ts_rank_cd(search, q, 1|32) / max(rank over candidates)`. It is 0 when there is no query or no match.
- Returns `{memories:[{id, content, topic, importance, created_at, updated_at, source, confirmations, pinned}], total, topics:{topic:n}}`.

**`coach_context_manifest_v1(p_user uuid, p_thread uuid default null, p_query text default null) returns jsonb`**
- Assembled in a single call:
  - `memories`: `coach_memories_ranked_v1(p_user, p_query, 8)`, plus `memory_count` and `memory_topics`.
  - `thread`: the current thread `{id, title, summary, summary_through, summary_messages, message_count, open_loops}`, or null.
  - `library`:
    - `{thread_count, first_at, last_at}` excluding empty threads;
    - `recent`: the 5 most recent threads other than the current one `{id, title, last_message_at}`;
    - `relevant`: up to 3 threads other than the current one from `coach_search_v1(p_query, p_thread_limit:=3)` `{id, title, last_message_at, snippet}`, or `[]` without a query.
  - `open_loops`: up to 3 `{thread_id, title, text}`, from other threads summarised in the last 7 days.
  - `memory_revision`.

**`coach_thread_claim_v1(p_user uuid, p_thread uuid, p_lease_seconds int default 120) returns jsonb`**
- Takes the lease when it is null or expired.
- Returns `{claimed:true, token, summary, summary_through, summary_messages, curated_through, message_count, title, title_source, memory_floor_at}`, or `{claimed:false}`.

**`coach_thread_publish_v1(p_user uuid, p_thread uuid, p_token uuid, p_patch jsonb, p_ops jsonb) returns jsonb`**
- Runs in one transaction. It succeeds only while `maintenance_token = p_token` and the lease is unexpired.
- Applies `p_patch`, whose keys are `summary`, `summary_topics`, `open_loops`, `summary_through`, `summary_messages`, `curated_through`, `summarized_at`.
- Applies `p_ops` through `coach_memory_apply_v1(p_user, p_ops, 'curator', p_thread)`.
- Releases the lease.
- Returns `{applied:bool, reason:'published'|'lease_lost', ops:[…]}`.

**`coach_memory_apply_v1(p_user uuid, p_ops jsonb, p_actor text, p_thread uuid default null) returns jsonb`**

The ops arrive fully resolved and validated by TypeScript; SQL re-checks ownership, retired state and lengths.

| Op | Fields | Effect |
|---|---|---|
| `add` | `content, topic, importance, source` | inserts a row |
| `update` | `id, content?, topic?, importance?` | `version+1`, `updated_at`, `last_confirmed_at`; the event records before and after |
| `confirm` | `id` | `confirmations+1`, `last_confirmed_at = now()`; importance is not raised |
| `retire` | `id, reason, tokens` | soft-retires the row |
| `merge` | `keep_id, ids[], content, topic, importance` | updates the kept row with `confirmations` summed and `version+1`; soft-retires the others with reason `merged` |
| `forget` | `id, tokens` | hard-deletes the row and records a tombstone event |
| `forget_all` | – | deletes every memory, records one tombstone per row, sets `memory_floor_at = now()`, clears `recent_searches` and `suggestions`, bumps `memory_revision` |

After applying the ops:
- It enforces the cap of **200 active memories**, evicting the lowest score (importance, recency, confirmations) as a soft retire with reason `evict`.
- It writes the events and purges retired rows older than 30 days.
- It returns `[{op, id, applied, reason?}]`.

**`coach_consolidation_claim_v1(p_user uuid, p_lease_seconds int default 120) returns boolean`**
- Claims when `consolidation_until` is null or past, **and** either there are more than 120 active memories, or there are more than 40 and `consolidated_at` is null or older than 72 h.
- On success it sets `consolidation_until`. The apply step sets `consolidated_at` and clears the lease (op `consolidated`).

## 4. HTTP API (`/functions/v1/coach/...`)

**Authentication**
- Unchanged: an installation bearer only. The owner always comes from the credential.

**Compatibility**
- Every existing route keeps its request and response shape.
- New response fields are additive.
- Timestamps in new shapes are `Date#toISOString()`.

**Feature flag**
- `GET status` adds `features: {threads: 1, context: 1}`.
- Without it, the client stays on single-thread behaviour: no sidebar, no context tools, no titles. Old servers simply never return it.

### Existing routes
| Route | Change |
|---|---|
| `GET messages?limit=N` | Unchanged: the latest N across the whole user, oldest first. It now skips rows whose `client_id` is null (there are none after the backfill). |
| `GET messages?threadId=<uuid>&limit=1..200(60)&cursor=<opaque>` | New: one page of a thread, oldest first. Returns `{messages:[{id, clientId, threadId, role, content, meta, createdAt}], hasMore, nextCursor}`. The cursor encodes `(created_at, id)`. |
| `POST messages` | Each message may carry `threadId`, plus an optional `threadTitle` for a new thread. Up to 40 messages per call. Goes through `coach_messages_save_v1`. Returns `{saved, rejected:[{clientId, reason}]}`, with 2xx even when some rows were rejected. Values PostgreSQL would refuse are repaired rather than failing the batch (which the outbox would retry forever): NUL characters are stripped from content, title and meta, and `createdAt` is re-rendered as ISO, with an unparseable time or one outside 2000..2200 replaced by now. |
| `DELETE messages` | No query: tombstones and deletes all of the user's threads and messages. `?threadId=`: that thread only. |
| `GET memories?q=&topic=&limit=` | Without `q`, the default order and the limit of 50 are unchanged. With `q`, ranked through `coach_memories_ranked_v1`. `limit` goes up to 200. Rows gain optional `updatedAt, source, confirmations, pinned`. |
| `POST memories {content, topic?, importance?, threadId?}` | The dedupe (§6) either confirms an existing row (`{memory, deduped:true}`) or applies `add` (`{memory, kept}`). Content that near-matches a tombstone is still saved, because the user asked explicitly. |
| `DELETE memories/<id>` | Op `forget`. |
| `DELETE memories` | Op `forget_all`. |

### New routes
| Route | Request | Response |
|---|---|---|
| `GET threads?limit=1..100(50)&cursor=&folderId=<uuid\|none>` | – | `{threads:[Thread], folders:[Folder], hasMore, nextCursor}`. Pinned threads come first on the first page. The cursor covers unpinned threads only. |
| `GET threads?q=<text>[&record=1]` | – | `{threads:[Thread with snippet], query}`, via `coach_search_v1` (thread-grouped). `record=1` with a query of 3 or more characters stores it in `recent_searches`. |
| `POST threads` | `{id, title?, folderId?}` | `{thread}`, idempotent. Errors: 409 `thread_conflict`, 410 `thread_deleted`. |
| `GET threads/:id` | – | `{thread}`, or 404 `thread_not_found` |
| `PATCH threads/:id` | `{title?, folderId?: uuid\|null, pinned?}` | `{thread}`. A title set here gets `title_source='user'`. |
| `DELETE threads/:id` | – | `{deleted:true}` (writes a tombstone) |
| `POST threads/:id/title` | `{question, answer?, locale?}` | `{title, titleSource, generated}`. Regenerates only when `title_source` is `none`, `fallback` or `legacy`. |
| `POST threads/:id/maintain` | `{}` | 202 `{status:'queued'}` when `EdgeRuntime.waitUntil` exists. Otherwise it runs inline and returns `{status:'done'\|'skipped'\|'busy', summarized, memoryOps, consolidated}`. |
| `GET folders` / `POST folders {id, name}` / `PATCH folders/:id {name?, sortOrder?}` / `DELETE folders/:id` | – | `{folders}` / `{folder}` / `{folder}` / `{deleted:true}` |
| `POST followups` | `{threadId?, question, answer, asked?:[string], locale?, wantTitle?}` | `{followUps:[string], title?:string}`. `title` is generated in the same call when `wantTitle` is set and the thread still has a generated or legacy title. |
| `POST suggestions` | `{state?, fallback?:[string], refresh?, locale?}` | `{suggestions:[{text, kind:'continue'\|'state'\|'goal'\|'explore', threadId?}], source:'model'\|'cache'\|'fallback'}` |
| `POST context` | `{threadId?, question?}` | The manifest from `coach_context_manifest_v1`, converted to camelCase. |
| `POST context/search` | `{query?, from?, to?, days?, limit?, excludeThreadId?}` | `{terms, droppedTerms, totalHits, months, hits:[{threadId, title, at, role, snippet}], threads:[{threadId, title, lastMessageAt, hits, snippet, summary, topics}]}`. An empty `query` with `from`/`to`/`days` browses by date. |
| `POST context/thread` | `{threadId, query?, cursor?, limit?}` | `{thread:{id, title, createdAt, lastMessageAt, messageCount, summary}, messages:[{role, at, content}], window:'recent'\|'around_matches', hasMore, nextCursor}`. At most 8,000 characters of content, and each message is cut to 1,500. Blocked rows are excluded. |
| `POST context/recall` | `{question, keywords?, threadId?, includeCurrent?, from?, to?}` | `{answer, sources:[{threadId, title, at}], coverage:{threadsMatched, threadsExamined, totalHits, truncated}, examined:{chunks, subcalls, messages}, status:'answered'\|'partial'\|'nothing_found'\|'budget'\|'unavailable'}` |

**Shapes**
- `Thread` = `{id, title, titleSource, folderId, pinned, origin, createdAt, updatedAt, lastMessageAt, messageCount, preview, topics, pendingMessages, snippet?}`, where `pendingMessages = message_count - summary_messages`.
- `Folder` = `{id, name, sortOrder, createdAt, updatedAt}`.

**Quotas**
- `chat` and `visual` take the chat quota, as before.
- Each cheap-model call takes 1 unit of `COACH_DAILY_UTILITY_LIMIT` (default 600). Recall takes `chunks + 1` units in a single call.
- Token usage is recorded through `coach_add_utility_tokens`.
- When the utility quota runs out, the deterministic fallbacks are used:
  - title from the first words of the question;
  - follow-ups from keywords;
  - suggestions from the local list;
  - the summary is skipped;
  - recall returns `budget` with the lexical snippets.
- The `context`, `context/search` and `context/thread` routes make no model calls.

## 5. Cheap-model passes

All passes go through `callUtility` (`_shared/coach_llm.ts`).

**Request.**
- Model `cfg.models.utility`, using `COACH_UTILITY_API_KEY` if set, otherwise the chat key.
- `stream:false` and `response_format:{type:'json_object'}`.
- `reasoning_effort` is `COACH_UTILITY_REASONING` (default `none`; the parameter is omitted when the setting is empty).

**Per-pass limits.**

| Pass | `max_tokens` | Timeout |
|---|---|---|
| title | 60 | 6 s |
| follow-ups (+ title) | 260 | 8 s |
| suggestions | 360 | 9 s |
| map | 450 | 9 s |
| reduce | 600 | 5 s |
| curator | 1,400 | 15 s |
| consolidation | 2,400 | 20 s |

**Result handling.**
- `callUtility` takes a quota unit before calling.
- `finish_reason === 'length'` counts as a failure.
- Parsing uses the `parseJsonReply` logic from `coach_visual.ts` (strip `<think>`, strip code fences, extract the first object).
- On any failure it returns `null`, and the caller falls back.
- It never logs prompts or content.

**Short references.** Prompts never contain UUIDs. Memories are `m1…`, threads `t1…`, chunks `c1…`, and the server maps them back.

**Locale.** Model-written user-facing strings are in the user's `locale` language (BCP-47, default `en`).

**Title**
- Input: the first question (≤ 600 characters) and the first answer (≤ 1,200).
- Output: `{"title"}`, 2–6 words, Title Case.
- Sanitising: strip quotes, emoji and trailing punctuation; collapse whitespace; ≤ 48 characters; drop "Chat about", "Question about" and similar.
- The client sets a local fallback title at send: the first 6 words of the question.
- The model title is written with a PATCH filtered on `title_source=in.(none,fallback,legacy)`.

**Follow-ups**
- Input:
  - the question and the answer (≤ 3,000 characters);
  - the thread summary (≤ 600);
  - questions already asked in the thread (≤ 12);
  - the top 4 memories;
  - `isMinor`.
- Output: `{"follow_ups":[3], "title"?}`.
- Each follow-up is the user's next question, 8–80 characters, specific to what the answer covered (its metric, plan or claim).
- Rules: no diagnosis or dosage questions, and nothing about models or vendors.
- Validation: normalised dedupe against the asked questions and against each other, plus the length bounds.
- **Title retry.** With `wantTitle`, when the combined reply failed or carried no usable title, the title pass
  runs once in the time left of an 11 s route deadline (the phone waits 12 s), costing one more unit. The
  phone only asks for a title with the first answer, so without this a single provider fault would leave the
  first-words title for good.

**Starter suggestions**
- Input:
  - the phone's coarse `state` (§7.5);
  - up to 8 memories (goals, injuries, routines and preferences first);
  - up to 6 recent threads (title, date, topics, open loops);
  - up to 10 recent non-blocked user questions;
  - up to 5 recent searches;
  - the local weekday and day part.
- Output: `{"suggestions":[{"text","kind","thread":"t2"?}]}`, 4 items, each ≤ 64 characters, first person.
- Constraints: at most 2 `continue` items, which must reference a thread from the input. At least 1 item should be grounded in a notable `state` flag when there is one. No diagnosis or dosage.
- **Cache:**
  - stored in `coach_user_state`;
  - keyed by `sha256(version, state, locale, memory_revision, the ids and last_message_at of the recent threads, recent_searches, local day part)`;
  - reused for 12 h; `refresh` skips the cache.

**Maintain (curator + summary)**
1. Claim the lease.
2. **Load new messages.** Fetch the non-blocked messages newer than `min(summary_through, curated_through)`, oldest first, at most 72.
3. **Decide what to run.**
   - **Memory ops** run when at least 1 new **user** message has `created_at > max(curated_through, memory_floor_at)`.
   - **The summary** runs when there are at least 4 new messages, or when there is no summary yet and at least 2 messages.
   - If neither applies, finish with `skipped`.
4. **Batch.** At most 24 messages and 14,000 characters per batch, each message cut to 1,500 characters. A user message that carries `meta.imageContext` is rendered as `[Photo: …]`. Batches fold into the summary oldest first, so this is recursive summarisation. At most 3 batches run per call.
5. **Memory candidates.** At most 24, labelled `m1..m24`:
   - first, this thread's `source='tool'` memories;
   - then `coach_memories_ranked_v1(<the batch's user text>, 12, false)`;
   - then the top memories by importance and recency, to fill.
6. **Output:**

   ```
   {"summary": "≤1200 chars, third person, absolute dates",
    "topics": ["≤6"],
    "open_loops": ["≤3"],
    "memory_ops": [≤4 of {"op":"add","topic","importance","content"}
                        | {"op":"update","ref":"m3","content"?,"importance"?}
                        | {"op":"confirm","ref"}
                        | {"op":"retire","ref","reason"}]}
   ```
   Rules given to the model:
   - Store only durable facts the **user** stated about themselves.
   - Never store Sana's advice, daily metric values or transient states.
   - Write in the third person ("User …") with absolute dates.
   - `retire` is allowed only when a user message in the batch contradicts the memory.
   - No ops is the preferred outcome.
7. **Deterministic guards** (§6) run before publishing.
8. `coach_thread_publish_v1` applies the summary and the ops together. `curated_through` and `summary_through` advance only for the work that actually ran.
   Blocked rows are never folded, but they count as handled: when they directly follow the last folded
   message (or lead the pending ones), both cursors move over them and `summary_messages` includes them, even
   on a `skipped` pass. Otherwise a chat ending on a blocked turn would keep `pendingMessages > 0` and be
   offered for maintenance on every launch.
9. **Consolidation**, when `coach_consolidation_claim_v1` succeeds:
   - Input: every active memory (≤ 200), labelled `m1…`.
   - Output: `{"ops":[≤12 of {"op":"merge","refs":[…],"content","topic","importance"} | {"op":"retire","ref","reason":"superseded|duplicate"}]}`.
   - A merge keeps the oldest row.

**Recall** (`context/recall`, RLM partition, map and reduce; hard server deadline **18 s**)
1. **Candidates.**
   - Run `coach_search_v1(keywords || question, 40, 6, <current thread unless includeCurrent>, from, to)`.
   - If there are no hits and the request has a date window (or an empty query), run in summary scope: take the thread summaries in the window, newest first, up to 36.
   - If there are no hits and no window, use the 6 most recent threads that have summaries.
   - If nothing is left after that, return `nothing_found`.
2. **Chunks.**
   - Each matched thread contributes its title, its dates, its summary, and the matched messages with ±1 neighbour, each cut to 1,200 characters. Those messages are loaded in one REST call per thread.
   - In summary scope, a chunk holds up to 12 summaries.
   - A chunk holds at most 10,000 characters; more material is split into further chunks.
   - **At most 4 chunks**, which are mapped in one wave.
3. **Map.** All chunks run concurrently, each with a 9 s timeout. Output per chunk: `{"relevant":bool, "notes":["≤5 bullets ≤220 chars, each starting with YYYY-MM-DD"]}`.
4. **Reduce.**
   - With 2 or fewer relevant chunks and ≤ 2,500 characters of notes, the notes are concatenated deterministically under `[title, date]` headers.
   - Otherwise one reduce call (5 s) produces `{"briefing":"≤1400 chars"}`.
   - If the deadline passes, the notes gathered so far are returned with `status:'partial'`.
5. **Coverage** reports the threads matched and examined, the total hits, and `truncated` when the threads matched or the hits exceed what was examined.

## 6. Deterministic ranking, dedupe and guards (`_shared/coach_llm.ts`)

**Tokens.**
- Text is NFKC-normalised and lowercased, then split into words.
- Words of 3 or more characters are kept after removing English stop words, with light stemming (drop `ing`, `ed`, `es`, `s`).
- **Every number and date token is kept**, whatever its length.

**Near-duplicate.**
- Compare token sets A and B, where `A_w` and `B_w` are the word-only tokens.
- If `A == B` after normalisation, it is a **duplicate**: confirm.
- If `jaccard(A_w, B_w) ≥ 0.72` and the number or date tokens differ, it is a **supersede**: update the old row to the new content.
- If `jaccard(A, B) ≥ 0.72`, or `containment ≥ 0.9`, it is a **duplicate**. If the new content is longer, it becomes an update to the longer content; otherwise a confirm.
- This applies within the same topic family: `goal|achievement|training`, `injury|health`, `preference|lifestyle|routine|nutrition|sleep`, and `general`, which matches every family.

**Curator guards.** An `add` or `update` is dropped when:
- (a) it shares less than 40% of its word tokens with the batch's user messages (grounding);
- (b) it contains transient phrasing (`today|yesterday|tonight|last night|this week|this morning|right now`) or a metric reading (a number followed by `bpm|ms|%|kcal|hrs?|hours|steps`);
- (c) it matches the sensitive list (self-harm, suicide, eating-disorder behaviours, other people's names, contact details), unless the batch's user text includes "remember";
- (d) it near-matches a `forget` tombstone from the last 365 days;
- (e) it would add more than 4 ops.

## 7. iOS client

### 7.1 Code layout
Everything under `Strand/` must build for macOS 13 and iOS 17, so it uses `ObservableObject`, not `@Observable`.

**Moved.** `CoachChatViewModel` (with `CoachChatMessage`, `CoachToolMark`, `CoachThinkingPhase` and `CoachConnection`) moves from `StrandiOS/Coach` to `Strand/Coach/CoachChatViewModel.swift`, so `StrandTests` can test it. Any iOS-only dependency it has moves too, or is split out.

**New files in `Strand/Coach/`:**
- **`CoachThreads.swift`**
  - Models: `CoachThread`, `CoachFolder`, `CoachThreadPage`, `CoachMessagePage`.
  - `CoachThreadSections.sections(threads:folders:now:calendar:)`, which groups into Pinned → each folder → Today → Yesterday → Previous 7 Days → Previous 30 Days → Older.
  - `CoachThreadTitle.fallback(from:)`.
  - `CoachDates.parse(_:)`, which accepts ISO 8601 with or without fractional seconds.
- **`CoachLocalStore.swift`**
  - The per-owner root `<AppSupport>/OpenWhoop/Coach/<ownerId>/`. The base directory can be injected for tests.
  - Files: `threads.json`, `suggestions.json`, `manifests/<threadId>.json`, and `messages/<threadId>.json` (the last 60 messages of the 10 most recently opened threads).
  - `removeAll(ownerId:)` runs on sign-out or account reset.
- **`CoachThreadStore.swift`**
  - `@MainActor ObservableObject`, holding `threads`, `folders`, the precomputed `sections`, `searchResults` and `phase`.
  - Operations: load and page, a search debounced at 300 ms (cached titles are filtered locally first, then the server is asked), and `recordSearch` on submit or when a result is tapped.
  - Optimistic rename, move, pin and delete, plus folder CRUD, `touch`, and `setTitle`.
  - It resets when the owner changes.
- **`CoachOutbox.swift`**
  - An `actor`, persisted per owner. Entries are stamped with `ownerId` and require a `threadId`.
  - Merging by `clientId` is field by field: a non-nil field wins, and meta keys merge.
  - Only one flush runs at a time, in chunks of at most 20 rows grouped by thread.
  - Network errors, 5xx and 429 are retried with backoff.
  - Rows rejected by the server, or failing with 400, 409 or 410, are bisected and quarantined. A 410 or `thread_deleted` drops the row.
  - The file is capped at 2 MB.
  - `purge(threadId:)` empties a thread's entries.
  - `flush()` returns which client ids were saved.
- **`CoachContextPrompt.swift`**: builds the prompt blocks (§7.4) from a `CoachContextManifest` plus a local `CoachDataCoverage`.
- **`CoachMetricHistory.swift`**: `query_metric_history` and `find_days` over `[DailyMetric]`.
  - At most 120 rows: the grouping coarsens automatically, newest first.
  - A header gives the metric, unit, from, to, the number of days measured and the coverage.
  - A dash means not measured.
- **`CoachStarterSuggestions.swift`**:
  - the coarse `CoachUserStateSnapshot`: rounded values plus band and flag strings;
  - local fallbacks: `CoachSuggestions` bands first, then `CoachPrompts.suggestions`;
  - merge, dedupe and safety screening;
  - an SF Symbol per kind.
- **`CoachChromeState.swift`**: `ObservableObject { @Published var drawerOpen }`, injected into `RootTabView` and `CoachChatView` only.

**`CoachAPI.swift`** gains every new route. Model changes:
- `CoachStoredMessage` gains `var threadId: String? = nil`.
- `CoachMessageMeta` gains `var followUps: [String]? = nil`, `var blocked: Bool? = nil` and `var imageContext: String? = nil`.
- `CoachMemory` gains optional `var`s.
- Pages decode row by row, dropping rows that fail.
- `features` is read from `status`.
- Per-route timeouts: recall 30 s, search and read 10 s, follow-ups 12 s, suggestions 12 s, maintain 10 s, everything else 15 s.

**DEBUG seam.** `CoachAPI.shared` honours the process environment variables `NARA_COACH_URL`, `NARA_COACH_TOKEN` and `NARA_COACH_OWNER`. They are accepted only for a loopback or `.local` host and a `noop_` token, and only in DEBUG builds. `simctl launch` passes them through `SIMCTL_CHILD_*`.

### 7.2 Tools (`CoachToolExecutor`)

New tools, in the core bundle on every turn:

| Tool | Arguments | Backed by |
|---|---|---|
| `search_conversations` | `query` (distinctive keywords; empty with `days`/`from`/`to` browses by date), `days`, `from`, `to` | `POST context/search` |
| `read_conversation` | `thread_id` (required), `query`, `cursor` | `POST context/thread` |
| `recall_context` | `question` (required), `keywords`, `from`, `to` | `POST context/recall` |
| `query_metric_history` | `metric` (required; the `CoachChartMetric` names), `from`, `to`, `days` (365; at most 4,000), `group` (`day\|week\|month\|year`, default `month`), `stat` (`mean\|min\|max\|sum`) | on device |
| `find_days` | `metric` (required), `below`, `above`, `from`, `to`, `limit` (10; at most 30), `order` (`recent\|lowest\|highest`) | on device |

- `get_memories` gains optional `query` and `topic`. The `save_memory` topic list matches the server's.
- Display labels: "Past chats", "Earlier chat", "Recalled from past chats", "Long-term history" and "Matching days".
- `query_metric_history` and `find_days` join `CoachVisualEvidence.dataTools`.
- Tool results show threads as short refs plus the UUID: `[t1 <uuid>]`.
- **Execution.** Calls in one round run concurrently, and results are appended in call order. A 5 s heartbeat advances `lastActivity` while tools run, so the stall watchdog does not fire mid-tool.

### 7.3 Turn flow
1. **`attach()`**
   - Reads the owner (`CloudPushIdentityStore.current()?.ownerId`, or the DEBUG owner) and loads the per-owner caches synchronously.
   - Picks the launch thread: if the newest cached thread was active on the same local day, that thread opens, with its cached messages showing at once and the server page reconciled afterwards. Otherwise a new chat starts.
   - This choice is never revisited after a send or a pending prompt.
2. **`start()`**
   - Checks the connection and reads `features`.
   - Refreshes the thread list and starter suggestions, and drains the outbox.
   - Prefetches the manifest for the open thread.
   - Calls maintain for up to 3 threads with `pendingMessages > 0` that have been quiet for more than 10 minutes.
3. **Send**
   - PII scrubbing and `screenInput` run as before. A blocked turn and its refusal are stored with `meta.blocked = true`.
   - The user row is enqueued and flushed **immediately**, carrying `threadTitle` = the fallback title for a new thread. The thread store gets an optimistic row.
   - The streaming tool loop is unchanged, except that it **mutates the streaming message by id**.
   - The manifest comes from the cache, refreshed in parallel with a 1.2 s cap. Photo turns overlap it with the description.
   - `meta.imageContext` (≤ 1,200 characters) is saved on the user row.
4. **Finish**
   - The assistant row goes into the outbox, and then three things run concurrently:
     - (a) the visual pipeline, unchanged;
     - (b) `POST followups` with `wantTitle` on the thread's first answer: the follow-ups go into `meta`, and the title goes into the store and the header;
     - (c) after the flush succeeds, `maintain`, followed by a refresh of the manifest and suggestion prefetch.
   - Model strings go through `CoachSafety` before they are shown.
5. **`open(thread)`**
   - Requires `!isGenerating`.
   - Clears the per-thread UI state: error, scrub notice, pending image, follow-ups shown. The composer draft resets because of `.id(threadId)`.
   - `threadPhase` moves `.loading` → `.ready`. Cached messages show at once, the server page is merged in by `clientId`, and the thread's outbox rows merge in too.
   - "Load earlier" pages with the cursor, and the scroll position is kept.
6. **New chat:** a client UUID; nothing is stored until the first send.
7. **Delete**
   - Cancels the thread's tasks, purges its outbox entries, and removes it locally and on the server.
   - Deleting the open thread starts a new chat.
8. **Pending prompts** (Today launcher, Siri, `--coach-prompt`)
   - `queuePrompt(_:)` starts a new chat and sends there. While a reply is generating, the prompt waits until that reply ends.
   - `pendingPrompt` is cleared only once the prompt is accepted.
   - Siri routes through `pendingPrompt`, only when Coach is enabled, and drops prompts older than 10 minutes.

### 7.4 Prompting
- **Unchanged:** `CoachPrompt.persona`, `answerDirective`, `toolHint` and `dateContext`. `system(memories:imageContext:userAge:now:)` keeps its exact output.
- **New overload:** `system(context: CoachTurnContext, imageContext:userAge:now:)` builds:
  1. the same fixed prefix;
  2. `REMEMBERED CONTEXT (from previous sessions):` with the ranked memories, in the existing line format and header;
  3. `EARLIER IN THIS CONVERSATION (summary through YYYY-MM-DD; older than the messages below):`, only when `messageCount > 28`;
  4. `CONTEXT LIBRARY (queryable, not loaded):`. This block includes:
     - the counts and date ranges;
     - up to 3 relevant earlier chats `[t1] "Title" (date)`;
     - on the first turn of a new chat only, up to 2 open loops;
     - memory topics;
     - wearable coverage (days, first and last day, workouts and journal days);
     - a `HOW TO USE IT` paragraph: which tool fits which question; say "at least" when coverage is truncated; facts are captured automatically, so call `save_memory` only when the user asks to remember something or shares a critical fact; never mention the tools or the library.
- **Screening.** Every memory, summary and open-loop line passes `CoachSafety.screenInput(...).blocked == false` first.
- **Leak markers.** `CoachSafety` adds `"context library (queryable"` and `"earlier in this conversation (summary"`.

### 7.5 State snapshot for suggestions
`CoachUserStateSnapshot` is sent as `state` and includes:
- `day`;
- the charge band (`red|yellow|green`);
- HRV against the 30-day mean (`down|normal|up`);
- the last night's sleep band (`short|ok|long`);
- the effort band;
- the Watchdog headline;
- the days since the last workout and its sport;
- `dataDays`;
- the local weekday and day part.

Values are bands, not raw readings, so the fingerprint stays stable.

### 7.6 UI (`StrandiOS/Coach/`)

**Header**
- A sidebar button (`sidebar.left`, at least a 44 pt hit area, id `coachSidebarButton`).
- "Sana", unchanged.
- The subtitle: the thread title, otherwise "Your health assistant", with id `coachThreadTitle`.
- A New chat button (`square.and.pencil`, id `coachNewChatButton`, disabled while generating).
- `BrandMark`.

**Drawer: `CoachSidebar(store:)`**
- It observes only `CoachThreadStore` and `CoachChromeState`, never the view model.
- **On iPhone** it slides in from the leading edge over a scrim; the scrim is a "Close chats" button. Width is `min(320, 84%)`.
  - It closes on the scrim, the button, a leftward drag, selecting a row, or `.onDisappear`.
  - Edge-pan does not open it.
- **On iPad (regular width)** it sits inline at 300 pt, open by default, in one stable `HStack` tree.
- **Rows**
  - Search ("Search chats", with `«»` rendered as bold), and New chat.
  - Folders: collapsible, each with a count.
  - Date-grouped chats.
- **Context menu on a chat:** Rename, Move to folder (or New folder…), Pin/Unpin, and Delete (with confirmation).
- **Footer:** "What Sana remembers", a memory sheet that pages with `limit=200`, with Forget and Forget all. Its copy says that chats stay in history.
- **Tab swipe:** `RootTabView` suppresses it with `including: (tabPaths[selectedTab].isEmpty && !(selectedTab == 4 && chrome.drawerOpen)) ? .all : .subviews`.
- **Accessibility:** `.isModal` on the panel, the chat column hidden while the drawer is open, the escape action, and the `.isSelected` trait on the current row.
- **Identifiers:** `coachThreadRow.<id>`, `coachFolderRow.<id>`, `coachSidebarSearch`, `coachSuggestion.<i>` and `coachFollowUp.<i>`.

**Welcome screen**
- Same layout, showing `vm.starterSuggestions`.
- They come from the cached server set when it is from the same day; otherwise the local set shows, and the server set replaces it only if it arrives within 1.5 s and the user hasn't touched anything.
- Each kind has an icon.
- A `continue` chip opens its thread and sends there.

**Follow-ups**
- The same `followUpList` rows, fed by `meta.followUps`. The keyword fallback appears only after a 4 s timeout or a failure.
- Up to 3 rows.
- Their arrival triggers the auto-scroll.

**Message list**
- `.id(threadId)`.
- Auto-scroll is keyed on `messages.last?.id`.
- A "Load earlier" row keeps the reading position.
- A loading placeholder shows during `.loading`.

## 8. Configuration

| Env | Default |
|---|---|
| `COACH_MODEL_UTILITY` | `COACH_MODEL_CHAT` (`deepseek-v4p1-flash`). Measured at about 1.9 s for a curator batch with clean JSON. `nemotron-lightning-3p5-30b-a3b` produced broken JSON. `gpt-oss-120b` and `glm-5p3-flash` rejected `reasoning_effort:none`. |
| `COACH_UTILITY_REASONING` | `none` (empty means the parameter is omitted) |
| `COACH_UTILITY_API_KEY` | the chat key |
| `COACH_DAILY_UTILITY_LIMIT` | 600 |

## 9. Tests

**Deno, mocked:**
- `tests/coach_threads_test.ts`
- `tests/coach_memory_test.ts`
- `tests/coach_curator_test.ts`
- `tests/coach_context_test.ts`
- `tests/coach_test.ts`, updated: the prune now happens in the RPC and the memory cap is now 200.

**Deno, real Postgres:**
- `tests/coach_threads_sql_test.ts` covers:
  - the migration applies and re-applies;
  - backfill;
  - trigger counts;
  - composite-FK isolation;
  - tombstones and the meta merge;
  - search ranking, browse mode, dropped terms, blocked exclusion and isolation;
  - memory ranking with safety pins;
  - apply ops including cap, eviction, tombstones and forget-all;
  - the lease;
  - quotas;
  - revokes.
- `tests/coach_memory_e2e_test.ts` runs the full HTTP flow over real PostgREST with a scripted fake model:
  the handler on a loopback port, Supabase-Auth installation bearers for two accounts, and an
  OpenAI-compatible stand-in (`tests/coach_e2e_support.ts`) that streams chat answers and recognises every
  cheap-model pass by its prompt. It also asserts that no PostgREST call failed, including the best-effort
  ones whose failures the routes swallow.

**Real-model smoke:** `supabase/functions/tests/coach_memory_smoke.ts` runs against Fireworks on synthetic data. It is not part of the default run:
`deno run -A --no-lock tests/coach_memory_smoke.ts` with `FIREWORKS_AI_API_KEY` set (only that key and the
`COACH_*` settings are read).

**Simulator dev server:** `supabase/tests/e2e/coach_dev_server.ts [--seed]` serves the same stack on
`127.0.0.1:54460/functions/v1/coach` (Fireworks when the key is set, otherwise the scripted stand-in) and
prints the `SIMCTL_CHILD_NARA_COACH_URL`, `_TOKEN` and `_OWNER` values for the §7.1 DEBUG seam.

**StrandTests:**
- `CoachThreadsTests`: sections, title fallback, dates, local store, owner isolation.
- `CoachOutboxTests`: merge, chunking, quarantine, 410.
- `CoachContextPromptTests`: the legacy prompt is byte-identical; blocks; safety screening.
- `CoachMetricHistoryTests`
- `CoachStarterSuggestionsTests`
- `CoachAPIThreadTests`: a URLProtocol stub on a private session; new routes; lossy decode; an old server returning 404.
- `CoachChatViewModelThreadTests`: the launch decision, streaming by id, refusing to switch while generating, queued prompts.

## 10. Rollout

1. Apply the migration (see `docs/BACKEND.md`).
2. Deploy `coach`.
3. Ship the app.

Old apps keep working: their messages land in `legacy_client` threads. A new app talking to an old server
has no `features`, so it stays single-thread.
