-- Sana threads, folders, durable memory and the context library (docs/COACH_MEMORY.md §2 and §3).
-- Additive only: five new owner-scoped tables, new columns on coach_messages, coach_memory_items and
-- coach_usage, generated search columns with user-scoped GIN indexes (btree_gin), two trigger functions,
-- a one-time grouping of the existing conversation into threads, and ten service-role-only RPCs.
--
-- Tables:
--   coach_folders             the owner's chat folders (client-generated ids)
--   coach_threads             one row per chat: title, pin, folder, live stats, rolling summary, maintenance lease
--   coach_thread_tombstones   deleted thread ids; a save for one is rejected with thread_deleted (kept 90 days)
--   coach_memory_events       audit trail of every memory change; `forget` rows double as tombstones
--   coach_user_state          one row per owner: suggestion cache, recent searches, consolidation lease,
--                             memory_revision and memory_floor_at
--
-- Write paths: the `coach` edge function authenticates the installation and calls the RPCs below with the
-- owner taken from the credential. Thread, folder and user-state rows are also read and patched by that
-- function through PostgREST with the service role. No client role has any privilege on a new table or
-- function: RLS is on with only a service_role policy, and EXECUTE is revoked from public, anon and
-- authenticated (Supabase's default privileges grant it on new functions, so the revokes are load-bearing).
-- Helper and trigger functions live in `internal`.
--
-- Existing conversation: every coach_messages row without a client_id gets one, and every row without a
-- thread is grouped per owner into `backfill` threads, a new thread wherever consecutive messages are more
-- than 3 hours apart. The thread-stats trigger is created after that, so the backfill's own counts are the
-- only ones written. Re-applying the file runs the grouping again for rows that are still thread-less (for
-- example ones the previous coach function wrote between this migration and its deploy).
--
-- Deletion: every new table cascades from auth.users; coach_messages cascade from their thread through the
-- composite (thread_id, user_id) foreign key, which also keeps a message from joining another owner's thread.
--
-- Safe to re-run (if not exists / create or replace / drop ... if exists). Rollback: redeploy the previous
-- `coach` function; the new objects can stay. To remove them: drop the three coach_messages_thread_stats_*
-- triggers and coach_threads_folder_owner, the functions below, the new columns, and the five tables.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';

create extension if not exists btree_gin with schema extensions;

-- ---------------------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------------------

create table if not exists public.coach_folders (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coach_folders_id_user_key unique (id, user_id)
);

create index if not exists coach_folders_user_order_idx
  on public.coach_folders (user_id, sort_order, created_at);

create table if not exists public.coach_threads (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text check (title is null or char_length(title) between 1 and 120),
  title_source text not null default 'none'
    check (title_source in ('none', 'auto', 'user', 'fallback', 'legacy')),
  -- Ownership of the folder is enforced by internal.coach_thread_folder_owner (42501).
  folder_id uuid references public.coach_folders(id) on delete set null,
  pinned boolean not null default false,
  origin text not null default 'app' check (origin in ('app', 'legacy_client', 'backfill')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Kept current by internal.coach_messages_thread_stats.
  last_message_at timestamptz,
  message_count integer not null default 0 check (message_count >= 0),
  preview text check (preview is null or char_length(preview) <= 160),
  -- Rolling summary of the older turns, written by coach_thread_publish_v1.
  summary text check (summary is null or char_length(summary) <= 2400),
  summary_topics text[] not null default '{}'::text[],
  open_loops jsonb not null default '[]'::jsonb check (jsonb_typeof(open_loops) = 'array'),
  summary_through timestamptz,
  summary_messages integer not null default 0 check (summary_messages >= 0),
  curated_through timestamptz,
  summarized_at timestamptz,
  -- Maintenance lease (coach_thread_claim_v1 / coach_thread_publish_v1).
  maintenance_token uuid,
  maintenance_until timestamptz,
  search tsvector generated always as (
    setweight(to_tsvector('english', coalesce(title, '')), 'A')
    || setweight(to_tsvector('english', coalesce(summary, '')), 'B')) stored,
  constraint coach_threads_id_user_key unique (id, user_id)
);

create index if not exists coach_threads_user_list_idx
  on public.coach_threads (user_id, pinned desc, last_message_at desc nulls last, id);
create index if not exists coach_threads_user_search_idx
  on public.coach_threads using gin (user_id, search);
create index if not exists coach_threads_folder_idx
  on public.coach_threads (folder_id) where folder_id is not null;

create table if not exists public.coach_thread_tombstones (
  user_id uuid not null references auth.users(id) on delete cascade,
  thread_id uuid not null,
  deleted_at timestamptz not null default now(),
  primary key (user_id, thread_id)
);

create table if not exists public.coach_memory_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  memory_id uuid,
  op text not null check (op in ('add', 'update', 'confirm', 'retire', 'merge', 'forget', 'evict')),
  actor text not null check (actor in ('tool', 'curator', 'user', 'consolidator')),
  before jsonb,
  after jsonb,
  thread_id uuid,
  reason text check (reason is null or char_length(reason) <= 300),
  -- Normalised token set of the memory's content; set for forget (the tombstone) and retire.
  tokens text[],
  created_at timestamptz not null default now()
);

create index if not exists coach_memory_events_user_created_idx
  on public.coach_memory_events (user_id, created_at desc);

create table if not exists public.coach_user_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  suggestions jsonb not null default '[]'::jsonb check (jsonb_typeof(suggestions) = 'array'),
  suggestions_fingerprint text,
  suggestions_at timestamptz,
  recent_searches jsonb not null default '[]'::jsonb
    check (jsonb_typeof(recent_searches) = 'array' and jsonb_array_length(recent_searches) <= 10),
  consolidated_at timestamptz,
  consolidation_until timestamptz,
  memory_revision bigint not null default 0 check (memory_revision >= 0),
  memory_floor_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------------------------------------
-- 2. Additive columns on the existing coach tables
-- ---------------------------------------------------------------------------------------------------------

-- `blocked` is true for the JSON value true and for the strings PostgreSQL reads as boolean true. It never
-- raises, so an odd `meta.blocked` cannot make a save (or this ALTER) fail.
alter table public.coach_messages
  add column if not exists thread_id uuid,
  add column if not exists blocked boolean generated always as (
    coalesce(lower(btrim(meta ->> 'blocked')) in ('true', 't', 'yes', 'y', 'on', '1'), false)) stored,
  add column if not exists search tsvector generated always as (
    setweight(to_tsvector('english', left(content, 8000)),
      case when role = 'user' then 'A'::"char" else 'B'::"char" end)) stored;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.coach_messages'::regclass and conname = 'coach_messages_thread_fkey') then
    alter table public.coach_messages
      add constraint coach_messages_thread_fkey foreign key (thread_id, user_id)
      references public.coach_threads (id, user_id) on delete cascade;
  end if;
end $$;

create index if not exists coach_messages_user_thread_idx
  on public.coach_messages (user_id, thread_id, created_at desc, id desc);
create index if not exists coach_messages_user_search_idx
  on public.coach_messages using gin (user_id, search);

-- updated_at and last_confirmed_at start as created_at for existing rows, then default to now().
alter table public.coach_memory_items
  add column if not exists updated_at timestamptz,
  add column if not exists last_confirmed_at timestamptz,
  add column if not exists confirmations integer not null default 1 check (confirmations >= 0),
  -- Existing rows are 'legacy'; the default for new rows is set to 'tool' just below.
  add column if not exists source text not null default 'legacy'
    check (source in ('tool', 'curator', 'user', 'legacy')),
  add column if not exists source_thread_id uuid,
  add column if not exists version integer not null default 1 check (version >= 1),
  add column if not exists retired_at timestamptz,
  add column if not exists retired_reason text check (retired_reason is null or char_length(retired_reason) <= 300),
  add column if not exists search tsvector generated always as (
    to_tsvector('english', topic || ' ' || content)) stored;

update public.coach_memory_items set updated_at = created_at where updated_at is null;
update public.coach_memory_items set last_confirmed_at = created_at where last_confirmed_at is null;
alter table public.coach_memory_items
  alter column updated_at set default now(),
  alter column updated_at set not null,
  alter column last_confirmed_at set default now(),
  alter column last_confirmed_at set not null,
  alter column source set default 'tool';

create index if not exists coach_memory_items_user_active_idx
  on public.coach_memory_items (user_id) where retired_at is null;

alter table public.coach_usage
  add column if not exists utility_calls integer not null default 0,
  add column if not exists utility_tokens bigint not null default 0;

-- ---------------------------------------------------------------------------------------------------------
-- 3. Internal helpers (never client-reachable; the internal schema has no client USAGE)
-- ---------------------------------------------------------------------------------------------------------

-- Every RPC acts for p_user only. A request that carries a signed-in identity must be that identity.
create or replace function internal.coach_owner_check(p_user uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_user is null then
    raise exception 'invalid_owner' using errcode = '22023';
  end if;
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
end;
$$;

-- A uuid from JSON text, or null when it is not one (never raises).
create or replace function internal.coach_uuid(p text) returns uuid
language sql immutable set search_path = '' as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end
$$;

-- Whitespace collapsed to single spaces and trimmed. Only the first 4,000 characters are looked at.
create or replace function internal.coach_collapse(p text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(left(coalesce(p, ''), 4000), '\s+', ' ', 'g'))
$$;

-- A thread preview: the first 160 characters of the collapsed text, or null when there is none.
create or replace function internal.coach_preview_text(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(rtrim(left(internal.coach_collapse(left(p, 2000)), 160)), '')
$$;

-- A legacy title: the collapsed text cut at a word boundary to at most 60 characters.
create or replace function internal.coach_thread_title(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text := internal.coach_collapse(p);
  v_cut text;
begin
  if v = '' then
    return null;
  end if;
  if char_length(v) <= 60 then
    return v;
  end if;
  v_cut := rtrim(substring(left(v, 61) from '^(.*) '));
  if v_cut is null or v_cut = '' then
    return left(v, 60);
  end if;
  return v_cut;
end;
$$;

-- The preview of a thread's newest message (any role).
create or replace function internal.coach_thread_preview(p_user uuid, p_thread uuid) returns text
language sql stable security definer set search_path = '' as $$
  select internal.coach_preview_text(m.content)
    from public.coach_messages m
   where m.user_id = p_user and m.thread_id = p_thread
   order by m.created_at desc, m.id desc
   limit 1
$$;

-- The user's messages beyond this count are pruned, oldest first, by coach_messages_save_v1. A function
-- rather than a literal so the rule can be exercised on a small number in the SQL test.
create or replace function internal.coach_messages_cap() returns integer
language sql stable set search_path = '' as $$ select 50000 $$;

-- Search terms: the distinct lexemes of the english tsvector of the query, in order of first appearance,
-- at most p_max (16 for coach_search_v1; memory ranking reads longer text, such as a curator batch).
create or replace function internal.coach_query_terms(p_query text, p_max integer default 16) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(s.lexeme order by s.first_pos, s.lexeme), '{}'::text[])
    from (select u.lexeme, min(p.pos) as first_pos
            from unnest(to_tsvector('english'::regconfig, left(coalesce(p_query, ''), 4000)))
                   as u(lexeme, positions, weights)
            cross join lateral unnest(coalesce(u.positions, '{1}'::smallint[])) as p(pos)
           group by u.lexeme
           order by min(p.pos), u.lexeme
           limit greatest(coalesce(p_max, 16), 1)) s
$$;

-- OR of already-normalised lexemes (no second stemming pass), or null for no terms.
create or replace function internal.coach_terms_tsquery(p_terms text[]) returns tsquery
language sql immutable set search_path = '' as $$
  select nullif(string_agg('''' || replace(replace(t, '\', '\\'), '''', '''''') || '''', ' | ' order by o), '')::tsquery
    from unnest(coalesce(p_terms, '{}'::text[])) with ordinality as u(t, o)
   where t <> ''
$$;

-- Topics accepted for a memory; anything else is stored as general.
create or replace function internal.coach_memory_topic(p text) returns text
language sql immutable set search_path = '' as $$
  select case when lower(btrim(coalesce(p, ''))) in ('goal', 'injury', 'preference', 'achievement', 'lifestyle',
    'routine', 'health', 'training', 'nutrition', 'sleep', 'general') then lower(btrim(p)) else 'general' end
$$;

-- Importance from JSON (number or numeric string), rounded and clamped to 1..5; p_default otherwise.
create or replace function internal.coach_memory_importance(p jsonb, p_default integer) returns integer
language sql immutable set search_path = '' as $$
  select case
    when jsonb_typeof(p) = 'number' then least(greatest(round((p #>> '{}')::numeric)::integer, 1), 5)
    when jsonb_typeof(p) = 'string' and btrim(p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$'
      then least(greatest(round(btrim(p #>> '{}')::numeric)::integer, 1), 5)
    else p_default end
$$;

-- Memory content: trimmed, 1..500 characters (the table's own bound), or null.
create or replace function internal.coach_memory_content(p text) returns text
language sql immutable set search_path = '' as $$
  select case when char_length(btrim(coalesce(p, ''))) between 1 and 500 then btrim(p) end
$$;

-- A row whose change moves memory_revision: importance >= 4 and a goal, injury, health or training topic.
create or replace function internal.coach_memory_revises(p_topic text, p_importance integer) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_importance >= 4 and p_topic in ('goal', 'injury', 'health', 'training'), false)
$$;

-- A JSON array of strings as text[]: trimmed, non-empty, each cut to p_len, at most p_max. Null when p is
-- not an array.
create or replace function internal.coach_text_array(p jsonb, p_max integer, p_len integer) returns text[]
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'array' then coalesce(
    (select array_agg(left(btrim(e.value #>> '{}'), p_len) order by e.ord)
       from jsonb_array_elements(p) with ordinality as e(value, ord)
      where jsonb_typeof(e.value) = 'string' and btrim(e.value #>> '{}') <> '' and e.ord <= p_max),
    '{}'::text[]) end
$$;

-- Fallback for tombstone tokens when the caller sent none (forget_all, or an older caller). It approximates
-- docs/COACH_MEMORY.md §6: NFKC, lowercase, words of 3+ characters minus English stop words with light
-- stemming (ing, ed, es, s), and every number or date token whatever its length. The edge function's own
-- tokens are preferred whenever it sends them.
create or replace function internal.coach_memory_tokens(p text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct s.tok order by s.tok), '{}'::text[])
    from (select case
                   when w.tok ~ '[0-9]' then w.tok
                   when w.tok ~ 'ing$' and char_length(w.tok) > 5 then left(w.tok, -3)
                   when w.tok ~ 'ed$' and char_length(w.tok) > 4 then left(w.tok, -2)
                   when w.tok ~ 'es$' and char_length(w.tok) > 4 then left(w.tok, -2)
                   when w.tok ~ 's$' and w.tok !~ 'ss$' and char_length(w.tok) > 3 then left(w.tok, -1)
                   else w.tok end as tok
            from (select m[1] as tok
                    from regexp_matches(lower(normalize(left(coalesce(p, ''), 4000), NFKC)),
                                        '([0-9]+(?:[./:-][0-9]+)*|[[:alpha:]]+)', 'g') as m) w
           where w.tok ~ '[0-9]'
              or (char_length(w.tok) >= 3 and w.tok <> all (array[
                'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'any', 'can', 'had', 'her', 'was', 'one',
                'our', 'out', 'has', 'have', 'him', 'his', 'how', 'its', 'may', 'now', 'she', 'too', 'use', 'who',
                'did', 'get', 'got', 'let', 'with', 'that', 'this', 'from', 'they', 'them', 'then', 'than',
                'there', 'their', 'what', 'when', 'where', 'which', 'while', 'will', 'would', 'about', 'after',
                'again', 'also', 'been', 'being', 'both', 'each', 'into', 'just', 'like', 'more', 'most', 'much',
                'must', 'only', 'other', 'over', 'same', 'some', 'such', 'very', 'were', 'your', 'yours',
                'because', 'before', 'between', 'could', 'does', 'doing', 'during', 'should', 'these', 'those',
                'through', 'under', 'until', 'here', 'having', 'user', 'users']))) s
$$;

-- The audit snapshot of a memory row. Forget events are written without content.
create or replace function internal.coach_memory_snapshot(m public.coach_memory_items, p_content boolean default true)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', m.id, 'content', case when p_content then m.content end, 'topic', m.topic,
    'importance', m.importance, 'source', m.source, 'source_thread_id', m.source_thread_id,
    'confirmations', m.confirmations, 'version', m.version, 'created_at', m.created_at,
    'updated_at', m.updated_at, 'last_confirmed_at', m.last_confirmed_at,
    'retired_at', m.retired_at, 'retired_reason', m.retired_reason))
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. Trigger functions
-- ---------------------------------------------------------------------------------------------------------

-- A thread may only sit in one of its owner's folders.
create or replace function internal.coach_thread_folder_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid;
begin
  if new.folder_id is not null then
    select f.user_id into v_owner from public.coach_folders f where f.id = new.folder_id;
    if found and v_owner is distinct from new.user_id then
      raise exception 'folder_not_owned' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- Keeps coach_threads.message_count, last_message_at, preview and updated_at current. INSERT and DELETE are
-- statement-level triggers with transition tables, so a bulk write updates each thread once; UPDATE is a
-- row-level trigger on thread_id/content that only fires when one of them actually changes.
create or replace function internal.coach_messages_thread_stats() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_level = 'ROW' then
    if old.thread_id is not null and (old.thread_id, old.user_id) is distinct from (new.thread_id, new.user_id) then
      update public.coach_threads t
         set message_count = greatest(t.message_count - 1, 0),
             last_message_at = (select max(m.created_at) from public.coach_messages m
                                 where m.user_id = t.user_id and m.thread_id = t.id),
             preview = internal.coach_thread_preview(t.user_id, t.id),
             updated_at = now()
       where t.id = old.thread_id and t.user_id = old.user_id;
    end if;
    if new.thread_id is not null then
      update public.coach_threads t
         set message_count = t.message_count
               + case when (old.thread_id, old.user_id) is distinct from (new.thread_id, new.user_id) then 1 else 0 end,
             last_message_at = (select max(m.created_at) from public.coach_messages m
                                 where m.user_id = t.user_id and m.thread_id = t.id),
             preview = internal.coach_thread_preview(t.user_id, t.id),
             updated_at = now()
       where t.id = new.thread_id and t.user_id = new.user_id;
    end if;
    return null;
  end if;

  if tg_op = 'INSERT' then
    with d as (
      select n.user_id, n.thread_id, count(*)::integer as n, max(n.created_at) as newest
        from new_rows n
       where n.thread_id is not null
       group by n.user_id, n.thread_id)
    update public.coach_threads t
       set message_count = t.message_count + d.n,
           last_message_at = greatest(t.last_message_at, d.newest),
           preview = internal.coach_thread_preview(t.user_id, t.id),
           updated_at = now()
      from d
     where t.id = d.thread_id and t.user_id = d.user_id;
  elsif tg_op = 'DELETE' then
    with d as (
      select o.user_id, o.thread_id, count(*)::integer as n
        from old_rows o
       where o.thread_id is not null
       group by o.user_id, o.thread_id)
    update public.coach_threads t
       set message_count = greatest(t.message_count - d.n, 0),
           last_message_at = (select max(m.created_at) from public.coach_messages m
                               where m.user_id = t.user_id and m.thread_id = t.id),
           preview = internal.coach_thread_preview(t.user_id, t.id),
           updated_at = now()
      from d
     where t.id = d.thread_id and t.user_id = d.user_id;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 5. Backfill: client ids, then legacy rows grouped into threads, then the stats trigger
-- ---------------------------------------------------------------------------------------------------------

drop trigger if exists coach_messages_thread_stats_insert on public.coach_messages;
drop trigger if exists coach_messages_thread_stats_update on public.coach_messages;
drop trigger if exists coach_messages_thread_stats_delete on public.coach_messages;

update public.coach_messages set client_id = gen_random_uuid() where client_id is null;

-- One group per owner and run of messages no more than 3 hours apart.
create temporary table coach_backfill_rows on commit drop as
with ordered as (
  select m.id, m.user_id, m.created_at,
         case when lag(m.created_at) over w is null
                or m.created_at - lag(m.created_at) over w > interval '3 hours' then 1 else 0 end as starts
    from public.coach_messages m
   where m.thread_id is null
  window w as (partition by m.user_id order by m.created_at, m.id)
)
select o.id, o.user_id, sum(o.starts) over (partition by o.user_id order by o.created_at, o.id) as grp
  from ordered o;

create temporary table coach_backfill_groups on commit drop as
select b.user_id, b.grp, gen_random_uuid() as thread_id,
       min(m.created_at) as first_at, max(m.created_at) as last_at, count(*)::integer as n,
       (array_agg(internal.coach_thread_title(m.content) order by m.created_at, m.id)
          filter (where m.role = 'user' and not m.blocked and internal.coach_thread_title(m.content) is not null))[1] as title,
       (array_agg(left(m.content, 2000) order by m.created_at desc, m.id desc))[1] as newest
  from coach_backfill_rows b
  join public.coach_messages m on m.id = b.id
 group by b.user_id, b.grp;

insert into public.coach_threads (id, user_id, title, title_source, origin, created_at, updated_at,
                                  last_message_at, message_count, preview)
select g.thread_id, g.user_id, g.title, case when g.title is null then 'none' else 'legacy' end, 'backfill',
       g.first_at, now(), g.last_at, g.n, internal.coach_preview_text(g.newest)
  from coach_backfill_groups g;

update public.coach_messages m
   set thread_id = g.thread_id
  from coach_backfill_rows b
  join coach_backfill_groups g on g.user_id = b.user_id and g.grp = b.grp
 where m.id = b.id and m.thread_id is null;

create trigger coach_messages_thread_stats_insert
  after insert on public.coach_messages
  referencing new table as new_rows
  for each statement execute function internal.coach_messages_thread_stats();
create trigger coach_messages_thread_stats_delete
  after delete on public.coach_messages
  referencing old table as old_rows
  for each statement execute function internal.coach_messages_thread_stats();
create trigger coach_messages_thread_stats_update
  after update of thread_id, content on public.coach_messages
  for each row
  when (old.thread_id is distinct from new.thread_id or old.content is distinct from new.content)
  execute function internal.coach_messages_thread_stats();

drop trigger if exists coach_threads_folder_owner on public.coach_threads;
create trigger coach_threads_folder_owner
  before insert or update of folder_id, user_id on public.coach_threads
  for each row execute function internal.coach_thread_folder_owner();

-- ---------------------------------------------------------------------------------------------------------
-- 6. RPCs (public, service role only)
-- ---------------------------------------------------------------------------------------------------------

-- Cheap-model budget, the same atomic shape as coach_take_quota but on utility_calls. p_units are taken
-- together or not at all.
create or replace function public.coach_take_utility_quota(p_user_id uuid, p_limit integer, p_units integer default 1)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_units integer := greatest(coalesce(p_units, 1), 1);
  v_used integer;
begin
  perform internal.coach_owner_check(p_user_id);
  if p_limit is null or v_units > p_limit then
    return false;
  end if;
  insert into public.coach_usage as u (user_id, day, utility_calls)
  values (p_user_id, (now() at time zone 'utc')::date, v_units)
  on conflict (user_id, day) do update
    set utility_calls = u.utility_calls + v_units
    where u.utility_calls + v_units <= p_limit
  returning u.utility_calls into v_used;
  return v_used is not null;
end;
$$;

create or replace function public.coach_add_utility_tokens(p_user_id uuid, p_tokens integer)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform internal.coach_owner_check(p_user_id);
  if coalesce(p_tokens, 0) <= 0 then
    return;
  end if;
  insert into public.coach_usage as u (user_id, day, utility_tokens)
  values (p_user_id, (now() at time zone 'utc')::date, p_tokens)
  on conflict (user_id, day) do update
    set utility_tokens = u.utility_tokens + excluded.utility_tokens;
end;
$$;

-- Stores a batch of chat messages (docs/COACH_MEMORY.md §3). Rows arrive validated by the edge function:
-- {client_id, thread_id|null, role, content, meta, created_at, thread_title|null}. A row without a thread
-- (an old app build) keeps the stored thread of its client_id, else joins the owner's newest legacy_client
-- thread whose last message is within 3 hours of the row, else starts a new legacy_client thread. Each
-- thread is then checked once: tombstoned -> thread_deleted, another owner's -> thread_conflict, missing ->
-- created. Messages upsert on (user_id, client_id) keeping their first created_at and thread, merging meta.
create or replace function public.coach_messages_save_v1(p_user uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_row record;
  v_thread uuid;
  v_found_last timestamptz;
  v_legacy_thread uuid;
  v_legacy_last timestamptz;
  v_work jsonb := '[]'::jsonb;
  v_status jsonb := '{}'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_threads jsonb := '[]'::jsonb;
  v_saved integer := 0;
  v_owner uuid;
  v_title text;
  v_r jsonb;
begin
  perform internal.coach_owner_check(p_user);
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 200 then
    raise exception 'invalid_rows' using errcode = '22023';
  end if;

  -- 1. Resolve every row's thread. Thread-less rows are taken oldest first so a batch from an old build
  --    stays together.
  for v_row in
    select e.ord, e.value as r, internal.coach_uuid(e.value ->> 'client_id') as client_id,
           internal.coach_uuid(e.value ->> 'thread_id') as thread_id,
           coalesce((e.value ->> 'created_at')::timestamptz, now()) as created_at
      from jsonb_array_elements(p_rows) with ordinality as e(value, ord)
     order by 5, 1
  loop
    if jsonb_typeof(v_row.r) is distinct from 'object' or v_row.client_id is null
       or (v_row.r ->> 'role') is distinct from 'user' and (v_row.r ->> 'role') is distinct from 'assistant'
       or jsonb_typeof(v_row.r -> 'content') is distinct from 'string'
       or (v_row.r ? 'thread_id' and jsonb_typeof(v_row.r -> 'thread_id') <> 'null' and v_row.thread_id is null) then
      v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
        'client_id', case when jsonb_typeof(v_row.r) = 'object' then v_row.r ->> 'client_id' end, 'reason', 'invalid_row'));
      continue;
    end if;
    v_thread := v_row.thread_id;
    if v_thread is null then
      select m.thread_id into v_thread
        from public.coach_messages m where m.user_id = p_user and m.client_id = v_row.client_id;
      if v_thread is null then
        if v_legacy_thread is not null
           and abs(extract(epoch from (v_row.created_at - v_legacy_last))) <= 10800 then
          v_thread := v_legacy_thread;
        else
          v_found_last := null;
          select t.id, t.last_message_at into v_thread, v_found_last
            from public.coach_threads t
           where t.user_id = p_user and t.origin = 'legacy_client'
             and t.last_message_at between v_row.created_at - interval '3 hours'
                                       and v_row.created_at + interval '3 hours'
           order by t.last_message_at desc, t.id
           limit 1;
          if v_thread is null then
            v_thread := gen_random_uuid();
          end if;
          v_legacy_thread := v_thread;
          v_legacy_last := coalesce(v_found_last, v_row.created_at);
        end if;
        v_legacy_last := greatest(v_legacy_last, v_row.created_at);
      end if;
    end if;
    v_work := v_work || jsonb_build_array(jsonb_build_object(
      'ord', v_row.ord, 'client_id', v_row.client_id, 'thread_id', v_thread,
      'legacy', v_row.thread_id is null, 'created_at', v_row.created_at,
      'thread_title', left(nullif(internal.coach_collapse(v_row.r ->> 'thread_title'), ''), 120)));
  end loop;

  -- 2. Check or create each distinct thread once.
  for v_row in
    select w.thread_id, bool_and(w.legacy) as legacy, min(w.created_at) as first_at,
           (array_agg(w.thread_title order by w.ord) filter (where w.thread_title is not null))[1] as title
      from jsonb_to_recordset(v_work) as w(ord integer, thread_id uuid, legacy boolean, created_at timestamptz,
                                           thread_title text)
     group by w.thread_id
  loop
    if exists (select 1 from public.coach_thread_tombstones d where d.user_id = p_user and d.thread_id = v_row.thread_id) then
      v_status := v_status || jsonb_build_object(v_row.thread_id::text, 'thread_deleted');
      continue;
    end if;
    insert into public.coach_threads (id, user_id, title, title_source, origin, created_at, updated_at)
    values (v_row.thread_id, p_user, v_row.title, case when v_row.title is null then 'none' else 'fallback' end,
            case when v_row.legacy then 'legacy_client' else 'app' end, least(now(), v_row.first_at), now())
    on conflict (id) do nothing;
    if found then
      v_status := v_status || jsonb_build_object(v_row.thread_id::text, 'ok');
      v_threads := v_threads || jsonb_build_array(jsonb_build_object('id', v_row.thread_id, 'created', true));
      continue;
    end if;
    select t.user_id into v_owner from public.coach_threads t where t.id = v_row.thread_id;
    if v_owner is distinct from p_user then
      v_status := v_status || jsonb_build_object(v_row.thread_id::text, 'thread_conflict');
      continue;
    end if;
    -- A thread created without a title (POST threads) takes the first message's fallback title.
    if v_row.title is not null then
      update public.coach_threads t set title = v_row.title, title_source = 'fallback'
       where t.id = v_row.thread_id and t.user_id = p_user and t.title is null and t.title_source = 'none';
    end if;
    v_status := v_status || jsonb_build_object(v_row.thread_id::text, 'ok');
    v_threads := v_threads || jsonb_build_array(jsonb_build_object('id', v_row.thread_id, 'created', false));
  end loop;

  -- 3. Write the messages in input order. One statement per row keeps a repeated client_id in a batch
  --    well-defined (later wins for content and role, meta merges in order).
  for v_row in
    select w.ord, w.client_id, w.thread_id
      from jsonb_to_recordset(v_work) as w(ord integer, client_id uuid, thread_id uuid)
     order by w.ord
  loop
    if v_status ->> v_row.thread_id::text is distinct from 'ok' then
      v_rejected := v_rejected || jsonb_build_array(jsonb_build_object(
        'client_id', v_row.client_id, 'reason', v_status ->> v_row.thread_id::text));
      continue;
    end if;
    v_r := p_rows -> (v_row.ord - 1)::integer;
    insert into public.coach_messages as m (user_id, client_id, thread_id, role, content, meta, created_at)
    values (p_user, v_row.client_id, v_row.thread_id, v_r ->> 'role', v_r ->> 'content',
            case when jsonb_typeof(v_r -> 'meta') = 'object' then v_r -> 'meta' else '{}'::jsonb end,
            coalesce((v_r ->> 'created_at')::timestamptz, now()))
    on conflict (user_id, client_id) do update set
      content = excluded.content,
      role = excluded.role,
      meta = m.meta || excluded.meta,
      thread_id = coalesce(m.thread_id, excluded.thread_id);
    v_saved := v_saved + 1;
  end loop;

  -- 4. Retention: the newest messages up to the cap, and tombstones for 90 days. The threads' message counts
  --    are a cheap gate, so a save only walks the owner's messages once they are actually over the cap.
  if (select coalesce(sum(t.message_count), 0) from public.coach_threads t where t.user_id = p_user)
       > internal.coach_messages_cap() then
    delete from public.coach_messages m
     using (select x.id from public.coach_messages x
             where x.user_id = p_user
             order by x.created_at desc, x.id desc
            offset internal.coach_messages_cap()) old
     where m.id = old.id and m.user_id = p_user;
  end if;
  delete from public.coach_thread_tombstones d
   where d.user_id = p_user and d.deleted_at < now() - interval '90 days';

  return jsonb_build_object('saved', v_saved, 'rejected', v_rejected, 'threads', v_threads);
end;
$$;

-- Ranked full-text search over the owner's non-blocked messages and thread titles/summaries, grouped by
-- thread; or, for a query without lexemes, the threads with activity in [p_from, p_to), newest first.
create or replace function public.coach_search_v1(p_user uuid, p_query text, p_limit integer default 20,
  p_thread_limit integer default 8, p_exclude_thread uuid default null, p_from timestamptz default null,
  p_to timestamptz default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_thread_limit integer := least(greatest(coalesce(p_thread_limit, 8), 1), 30);
  v_opts constant text := 'StartSel=«, StopSel=», MaxWords=26, MinWords=8, MaxFragments=1';
  v_terms text[] := internal.coach_query_terms(p_query);
  v_kept text[];
  v_dropped text[] := '{}'::text[];
  v_total bigint;
  v_q tsquery;
  v_result jsonb;
begin
  perform internal.coach_owner_check(p_user);

  if cardinality(v_terms) = 0 then
    -- Browse: the threads whose span overlaps the window, each placed by its newest non-blocked message
    -- inside it (one index probe per thread, never a scan of the whole history).
    with act as (
      select t.id, t.title, t.last_message_at, t.summary, t.summary_topics, a.last_at
        from public.coach_threads t
        cross join lateral (
          select m.created_at as last_at
            from public.coach_messages m
           where m.user_id = p_user and m.thread_id = t.id and not m.blocked
             and (p_from is null or m.created_at >= p_from) and (p_to is null or m.created_at < p_to)
           order by m.created_at desc, m.id desc
           limit 1) a
       where t.user_id = p_user and t.message_count > 0
         and (p_exclude_thread is null or t.id <> p_exclude_thread)
         and (p_from is null or t.last_message_at >= p_from)
    ), top as (
      select a.* from act a order by a.last_at desc, a.id limit v_thread_limit
    )
    select jsonb_build_object('terms', '[]'::jsonb, 'dropped_terms', '[]'::jsonb, 'total_hits', 0,
             'months', '[]'::jsonb, 'hits', '[]'::jsonb,
             'threads', coalesce(jsonb_agg(jsonb_build_object(
               'thread_id', x.id, 'title', x.title, 'last_message_at', x.last_message_at, 'hits', 0,
               'best_rank', 0, 'snippet', null, 'summary', left(x.summary, 300),
               'topics', to_jsonb(x.summary_topics)) order by x.last_at desc, x.id), '[]'::jsonb))
      into v_result
      from top x;
    return v_result;
  end if;

  -- Terms that match more than 15% of a larger history carry no signal; they are dropped, unless every term
  -- is that common, in which case none is (dropping them all would leave nothing to search for). The size of
  -- the history is the threads' message counts, which the stats trigger keeps, rather than a count(*).
  v_kept := v_terms;
  if cardinality(v_terms) >= 2 then
    select coalesce(sum(t.message_count), 0) into v_total from public.coach_threads t where t.user_id = p_user;
    if v_total >= 40 then
      -- Each count stops one past the threshold: beyond it the exact number does not matter. Materialized,
      -- so each term's count runs once rather than once per filter below.
      with freq as materialized (
        select u.term, u.ord,
               (select count(*) from (select 1 from public.coach_messages m
                                       where m.user_id = p_user and not m.blocked
                                         and m.search @@ internal.coach_terms_tsquery(array[u.term])
                                       limit floor(0.15 * v_total)::bigint + 1) c) as n
          from unnest(v_terms) with ordinality as u(term, ord)
      )
      select array_agg(f.term order by f.ord) filter (where f.n <= 0.15 * v_total),
             array_agg(f.term order by f.ord) filter (where f.n > 0.15 * v_total)
        into v_kept, v_dropped
        from freq f;
      if v_kept is null then
        v_kept := v_terms;
        v_dropped := null;
      end if;
      v_dropped := coalesce(v_dropped, '{}'::text[]);
    end if;
  end if;
  v_q := internal.coach_terms_tsquery(v_kept);

  -- Every match counts towards total_hits and months, but only the newest 5,000 are ranked: ranking is the
  -- expensive step, and a query that broad is better narrowed with a date window (which this then honours)
  -- than ranked across a whole history. Below 5,000 matches the result is exact.
  with all_matches as materialized (
    select m.id, m.created_at
      from public.coach_messages m
     where m.user_id = p_user and m.search @@ v_q and not m.blocked and m.thread_id is not null
       and (p_from is null or m.created_at >= p_from) and (p_to is null or m.created_at < p_to)
       and (p_exclude_thread is null or m.thread_id <> p_exclude_thread)
  ), matches as (
    select m.id, m.thread_id, m.role, m.created_at,
           ts_rank_cd(m.search, v_q, 1 | 32)
             * (1 + 0.25 * exp(-greatest(extract(epoch from (now() - m.created_at))::float8, 0) / 86400.0 / 90.0))
             as rank
      from (select a.id from all_matches a order by a.created_at desc, a.id desc limit 5000) pool
      join public.coach_messages m on m.id = pool.id
  ), by_thread as (
    select x.thread_id, count(*) as hits, max(x.rank) as best from matches x group by x.thread_id
  ), thread_matches as (
    select t.id as thread_id,
           ts_rank_cd(t.search, v_q, 1 | 32)
             * (1 + 0.25 * exp(-greatest(extract(epoch from (now() - coalesce(t.last_message_at, t.created_at)))::float8, 0)
                               / 86400.0 / 90.0)) as rank
      from public.coach_threads t
     where t.user_id = p_user and t.search @@ v_q and t.message_count > 0
       and (p_exclude_thread is null or t.id <> p_exclude_thread)
       and (p_from is null or t.last_message_at >= p_from)
       and exists (select 1 from public.coach_messages m
                    where m.user_id = p_user and m.thread_id = t.id and not m.blocked
                      and (p_from is null or m.created_at >= p_from) and (p_to is null or m.created_at < p_to))
  ), candidates as (
    select coalesce(b.thread_id, tm.thread_id) as thread_id, coalesce(b.hits, 0) as hits,
           greatest(coalesce(b.best, 0), coalesce(tm.rank, 0)) as best
      from by_thread b full join thread_matches tm on tm.thread_id = b.thread_id
  ), top_threads as (
    select c.thread_id, c.hits, c.best, t.title, t.last_message_at, t.summary, t.summary_topics,
           row_number() over (order by c.best * (1 + ln(greatest(c.hits, 1)::float8)) desc,
                                       t.last_message_at desc nulls last, c.thread_id) as pos
      from candidates c join public.coach_threads t on t.id = c.thread_id and t.user_id = p_user
     order by pos
     limit v_thread_limit
  ), best_message as (
    select distinct on (x.thread_id) x.thread_id, x.id
      from matches x
     where x.thread_id in (select tt.thread_id from top_threads tt)
     order by x.thread_id, x.rank desc, x.created_at desc, x.id
  ), top_hits as (
    select x.*, row_number() over (order by x.rank desc, x.created_at desc, x.id) as pos
      from matches x
     order by x.rank desc, x.created_at desc, x.id
     limit v_limit
  )
  select jsonb_build_object(
    'terms', to_jsonb(v_kept),
    'dropped_terms', to_jsonb(v_dropped),
    'total_hits', (select count(*) from all_matches),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', mo.month, 'hits', mo.hits) order by mo.month)
                          from (select to_char(x.created_at at time zone 'UTC', 'YYYY-MM') as month, count(*) as hits
                                  from all_matches x group by 1) mo), '[]'::jsonb),
    'hits', coalesce((select jsonb_agg(jsonb_build_object(
                        'thread_id', h.thread_id, 'message_id', h.id, 'role', h.role, 'created_at', h.created_at,
                        'rank', round(h.rank::numeric, 6),
                        'snippet', ts_headline('english', left(m.content, 8000), v_q, v_opts)) order by h.pos)
                        from top_hits h join public.coach_messages m on m.id = h.id), '[]'::jsonb),
    'threads', coalesce((select jsonb_agg(jsonb_build_object(
                           'thread_id', tt.thread_id, 'title', tt.title, 'last_message_at', tt.last_message_at,
                           'hits', tt.hits, 'best_rank', round(tt.best::numeric, 6),
                           'snippet', case when bm.id is not null
                                        then ts_headline('english', left(m.content, 8000), v_q, v_opts)
                                        else ts_headline('english', coalesce(tt.summary, tt.title, ''), v_q, v_opts) end,
                           'summary', left(tt.summary, 300), 'topics', to_jsonb(tt.summary_topics)) order by tt.pos)
                           from top_threads tt
                           left join best_message bm on bm.thread_id = tt.thread_id
                           left join public.coach_messages m on m.id = bm.id), '[]'::jsonb))
    into v_result;
  return v_result;
end;
$$;

-- The owner's active memories for one question: up to 3 safety pins (injury/health, importance >= 4), then
-- the rest by 3*lex + importance/5 + 0.5*exp(-days/120) + 0.2*ln(1+confirmations).
create or replace function public.coach_memories_ranked_v1(p_user uuid, p_query text default null,
  p_limit integer default 8, p_pin_safety boolean default true)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 8), 1), 200);
  v_q tsquery := internal.coach_terms_tsquery(internal.coach_query_terms(p_query, 64));
  v_result jsonb;
begin
  perform internal.coach_owner_check(p_user);
  with active as (
    select a.* from public.coach_memory_items a where a.user_id = p_user and a.retired_at is null
  ), pins as (
    select a.id, row_number() over (order by a.importance desc, a.last_confirmed_at desc, a.id) as pos
      from active a
     where coalesce(p_pin_safety, true) and a.topic in ('injury', 'health') and a.importance >= 4
     order by a.importance desc, a.last_confirmed_at desc, a.id
     limit least(3, v_limit)
  ), raw as (
    select a.id,
           case when v_q is not null and a.search @@ v_q then ts_rank_cd(a.search, v_q, 1 | 32) else 0 end::float8 as lex
      from active a
     where a.id not in (select p.id from pins p)
  ), scored as (
    select a.id,
           3 * case when max(r.lex) over () > 0 then r.lex / max(r.lex) over () else 0 end
             + a.importance / 5.0
             + 0.5 * exp(-greatest(extract(epoch from (now() - a.last_confirmed_at))::float8, 0) / 86400.0 / 120.0)
             + 0.2 * ln(1 + a.confirmations) as score,
           a.last_confirmed_at
      from raw r join active a on a.id = r.id
  ), chosen as (
    select p.id, true as pinned, p.pos as pos from pins p
    union all
    select s.id, false, 3 + row_number() over (order by s.score desc, s.last_confirmed_at desc, s.id)
      from (select * from scored s order by s.score desc, s.last_confirmed_at desc, s.id
             limit greatest(v_limit - (select count(*) from pins), 0)) s
  )
  select jsonb_build_object(
    'memories', coalesce((select jsonb_agg(jsonb_build_object(
                            'id', a.id, 'content', a.content, 'topic', a.topic, 'importance', a.importance,
                            'created_at', a.created_at, 'updated_at', a.updated_at, 'source', a.source,
                            'confirmations', a.confirmations, 'pinned', c.pinned) order by c.pos)
                            from chosen c join active a on a.id = c.id), '[]'::jsonb),
    'total', (select count(*) from active),
    'topics', coalesce((select jsonb_object_agg(t.topic, t.n)
                          from (select a.topic, count(*) as n from active a group by a.topic) t), '{}'::jsonb))
    into v_result;
  return v_result;
end;
$$;

-- Everything the phone needs to describe the context library for one turn, in one call. It names what
-- exists; it never returns message contents.
create or replace function public.coach_context_manifest_v1(p_user uuid, p_thread uuid default null,
  p_query text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_memories jsonb;
  v_thread jsonb;
  v_library jsonb;
  v_recent jsonb;
  v_relevant jsonb := '[]'::jsonb;
  v_loops jsonb;
  v_revision bigint;
begin
  perform internal.coach_owner_check(p_user);
  v_memories := public.coach_memories_ranked_v1(p_user, p_query, 8);

  select jsonb_build_object('id', t.id, 'title', t.title, 'summary', t.summary,
           'summary_through', t.summary_through, 'summary_messages', t.summary_messages,
           'message_count', t.message_count, 'open_loops', t.open_loops)
    into v_thread
    from public.coach_threads t where t.id = p_thread and t.user_id = p_user;

  select jsonb_build_object('thread_count', count(*), 'first_at', min(t.created_at), 'last_at', max(t.last_message_at))
    into v_library
    from public.coach_threads t where t.user_id = p_user and t.message_count > 0;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'last_message_at', r.last_message_at)
                            order by r.last_message_at desc nulls last, r.id), '[]'::jsonb)
    into v_recent
    from (select t.id, t.title, t.last_message_at from public.coach_threads t
           where t.user_id = p_user and t.message_count > 0 and (p_thread is null or t.id <> p_thread)
             -- A chat that is nothing but blocked turns is never offered to the model.
             and exists (select 1 from public.coach_messages m
                          where m.user_id = p_user and m.thread_id = t.id and not m.blocked)
           order by t.last_message_at desc nulls last, t.id
           limit 5) r;

  if cardinality(internal.coach_query_terms(p_query)) > 0 then
    select coalesce(jsonb_agg(jsonb_build_object('id', e.value -> 'thread_id', 'title', e.value -> 'title',
                                'last_message_at', e.value -> 'last_message_at', 'snippet', e.value -> 'snippet')
                              order by e.ord), '[]'::jsonb)
      into v_relevant
      from jsonb_array_elements(public.coach_search_v1(p_user, p_query, 1, 3, p_thread) -> 'threads')
             with ordinality as e(value, ord);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('thread_id', l.thread_id, 'title', l.title, 'text', l.text)
                            order by l.summarized_at desc, l.thread_id, l.ord), '[]'::jsonb)
    into v_loops
    from (select t.id as thread_id, t.title, t.summarized_at, e.ord,
                 case jsonb_typeof(e.value) when 'string' then e.value #>> '{}' else e.value ->> 'text' end as text
            from public.coach_threads t
            cross join lateral jsonb_array_elements(t.open_loops) with ordinality as e(value, ord)
           where t.user_id = p_user and (p_thread is null or t.id <> p_thread)
             and t.summarized_at >= now() - interval '7 days'
             and coalesce(btrim(case jsonb_typeof(e.value) when 'string' then e.value #>> '{}'
                                                            else e.value ->> 'text' end), '') <> ''
           order by t.summarized_at desc, t.id, e.ord
           limit 3) l;

  select s.memory_revision into v_revision from public.coach_user_state s where s.user_id = p_user;

  return jsonb_build_object(
    'memories', v_memories -> 'memories',
    'memory_count', v_memories -> 'total',
    'memory_topics', v_memories -> 'topics',
    'thread', v_thread,
    'library', v_library || jsonb_build_object('recent', v_recent, 'relevant', v_relevant),
    'open_loops', v_loops,
    'memory_revision', coalesce(v_revision, 0));
end;
$$;

-- Takes the thread's maintenance lease when it is free or expired.
create or replace function public.coach_thread_claim_v1(p_user uuid, p_thread uuid, p_lease_seconds integer default 120)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_lease integer := least(greatest(coalesce(p_lease_seconds, 120), 10), 900);
  v_t public.coach_threads;
  v_floor timestamptz;
begin
  perform internal.coach_owner_check(p_user);
  update public.coach_threads t
     set maintenance_token = gen_random_uuid(),
         maintenance_until = now() + make_interval(secs => v_lease)
   where t.id = p_thread and t.user_id = p_user
     and (t.maintenance_until is null or t.maintenance_until <= now())
  returning t.* into v_t;
  if not found then
    return jsonb_build_object('claimed', false);
  end if;
  select s.memory_floor_at into v_floor from public.coach_user_state s where s.user_id = p_user;
  return jsonb_build_object('claimed', true, 'token', v_t.maintenance_token, 'summary', v_t.summary,
    'summary_through', v_t.summary_through, 'summary_messages', v_t.summary_messages,
    'curated_through', v_t.curated_through, 'message_count', v_t.message_count, 'title', v_t.title,
    'title_source', v_t.title_source, 'memory_floor_at', v_floor);
end;
$$;

-- Publishes a maintenance pass in one transaction: the summary patch and the curator's memory ops together,
-- only while p_token still holds an unexpired lease. Releases the lease.
create or replace function public.coach_thread_publish_v1(p_user uuid, p_thread uuid, p_token uuid,
  p_patch jsonb, p_ops jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_patch jsonb := case when jsonb_typeof(p_patch) = 'object' then p_patch else '{}'::jsonb end;
  v_ops jsonb := '[]'::jsonb;
begin
  perform internal.coach_owner_check(p_user);
  perform 1 from public.coach_threads t
   where t.id = p_thread and t.user_id = p_user and p_token is not null
     and t.maintenance_token = p_token and t.maintenance_until > now()
     for update;
  if not found then
    return jsonb_build_object('applied', false, 'reason', 'lease_lost', 'ops', '[]'::jsonb);
  end if;

  update public.coach_threads t set
    summary = case when v_patch ? 'summary'
                   then nullif(left(btrim(coalesce(v_patch ->> 'summary', '')), 2400), '') else t.summary end,
    summary_topics = case when v_patch ? 'summary_topics'
                          then coalesce(internal.coach_text_array(v_patch -> 'summary_topics', 12, 60), '{}'::text[])
                          else t.summary_topics end,
    open_loops = case when v_patch ? 'open_loops'
                      then coalesce((select jsonb_agg(e.value order by e.ord)
                                       from jsonb_array_elements(case when jsonb_typeof(v_patch -> 'open_loops') = 'array'
                                                                      then v_patch -> 'open_loops' else '[]'::jsonb end)
                                              with ordinality as e(value, ord)
                                      where e.ord <= 6), '[]'::jsonb)
                      else t.open_loops end,
    summary_through = case when v_patch ? 'summary_through'
                           then (v_patch ->> 'summary_through')::timestamptz else t.summary_through end,
    summary_messages = case when v_patch ? 'summary_messages'
                            then greatest(coalesce(round((v_patch ->> 'summary_messages')::numeric)::integer, 0), 0)
                            else t.summary_messages end,
    curated_through = case when v_patch ? 'curated_through'
                           then (v_patch ->> 'curated_through')::timestamptz else t.curated_through end,
    summarized_at = case when v_patch ? 'summarized_at'
                         then (v_patch ->> 'summarized_at')::timestamptz else t.summarized_at end,
    updated_at = case when v_patch ?| array['summary', 'summary_topics', 'open_loops'] then now() else t.updated_at end,
    maintenance_token = null,
    maintenance_until = null
   where t.id = p_thread and t.user_id = p_user;

  if jsonb_typeof(p_ops) = 'array' and jsonb_array_length(p_ops) > 0 then
    v_ops := public.coach_memory_apply_v1(p_user, p_ops, 'curator', p_thread);
  end if;

  return jsonb_build_object('applied', true, 'reason', 'published', 'ops', v_ops);
end;
$$;

-- Applies resolved memory ops in order (docs/COACH_MEMORY.md §3), then the 200-row cap (soft retire,
-- reason evict), the event retention and the 30-day purge of retired rows. Writers for one owner are
-- serialised on their coach_user_state row. Returns [{op, id, applied, reason?}], plus one
-- {op:'evict', id, applied:true, reason:'cap'} per evicted row.
create or replace function public.coach_memory_apply_v1(p_user uuid, p_ops jsonb, p_actor text, p_thread uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_op jsonb;
  v_kind text;
  v_id uuid;
  v_before public.coach_memory_items;
  v_after public.coach_memory_items;
  v_content text;
  v_topic text;
  v_importance integer;
  v_source text;
  v_reason text;
  v_tokens text[];
  v_ids uuid[];
  v_others integer;
  v_confirmations integer;
  v_last timestamptz;
  v_others_revise boolean;
  v_active integer;
  v_bump boolean := false;
  v_results jsonb := '[]'::jsonb;
  r public.coach_memory_items;
begin
  perform internal.coach_owner_check(p_user);
  if p_actor is null or p_actor not in ('tool', 'curator', 'user', 'consolidator') then
    raise exception 'invalid_actor' using errcode = '22023';
  end if;
  if jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) > 100 then
    raise exception 'invalid_ops' using errcode = '22023';
  end if;

  insert into public.coach_user_state (user_id) values (p_user) on conflict (user_id) do nothing;
  perform 1 from public.coach_user_state s where s.user_id = p_user for update;

  for v_op in select e.value from jsonb_array_elements(p_ops) with ordinality as e(value, ord) order by e.ord loop
    v_kind := case when jsonb_typeof(v_op) = 'object' then v_op ->> 'op' end;
    v_id := case when jsonb_typeof(v_op) = 'object'
                 then internal.coach_uuid(coalesce(v_op ->> 'id', v_op ->> 'keep_id')) end;

    if v_kind = 'add' then
      v_content := internal.coach_memory_content(v_op ->> 'content');
      if v_content is null then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'add', 'id', null, 'applied', false,
          'reason', 'invalid_content'));
        continue;
      end if;
      v_source := case when v_op ->> 'source' in ('tool', 'curator', 'user', 'legacy') then v_op ->> 'source'
                       when p_actor = 'consolidator' then 'curator' else p_actor end;
      insert into public.coach_memory_items (user_id, content, topic, importance, source, source_thread_id,
                                             created_at, updated_at, last_confirmed_at)
      values (p_user, v_content, internal.coach_memory_topic(v_op ->> 'topic'),
              internal.coach_memory_importance(v_op -> 'importance', 3), v_source, p_thread, now(), now(), now())
      returning * into v_after;
      insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id)
      values (p_user, v_after.id, 'add', p_actor, null, internal.coach_memory_snapshot(v_after), p_thread);
      v_bump := v_bump or internal.coach_memory_revises(v_after.topic, v_after.importance);
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'add', 'id', v_after.id, 'applied', true));

    elsif v_kind in ('update', 'confirm', 'retire', 'forget') then
      select * into v_before from public.coach_memory_items m where m.id = v_id and m.user_id = p_user for update;
      if not found then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', false,
          'reason', 'not_found'));
        continue;
      end if;
      if v_before.retired_at is not null and v_kind <> 'forget' then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', false,
          'reason', 'retired'));
        continue;
      end if;

      if v_kind = 'update' then
        v_content := case when jsonb_typeof(v_op -> 'content') = 'string'
                          then internal.coach_memory_content(v_op ->> 'content') else v_before.content end;
        if v_content is null then
          v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'update', 'id', v_id, 'applied', false,
            'reason', 'invalid_content'));
          continue;
        end if;
        v_topic := case when jsonb_typeof(v_op -> 'topic') = 'string'
                        then internal.coach_memory_topic(v_op ->> 'topic') else v_before.topic end;
        v_importance := internal.coach_memory_importance(v_op -> 'importance', v_before.importance);
        update public.coach_memory_items m
           set content = v_content, topic = v_topic, importance = v_importance, version = m.version + 1,
               updated_at = now(), last_confirmed_at = now()
         where m.id = v_id and m.user_id = p_user
        returning * into v_after;
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id)
        values (p_user, v_id, 'update', p_actor, internal.coach_memory_snapshot(v_before),
                internal.coach_memory_snapshot(v_after), p_thread);
        v_bump := v_bump or internal.coach_memory_revises(v_before.topic, v_before.importance)
                         or internal.coach_memory_revises(v_after.topic, v_after.importance);

      elsif v_kind = 'confirm' then
        update public.coach_memory_items m
           set confirmations = m.confirmations + 1, last_confirmed_at = now()
         where m.id = v_id and m.user_id = p_user
        returning * into v_after;
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id)
        values (p_user, v_id, 'confirm', p_actor,
                jsonb_build_object('confirmations', v_before.confirmations, 'last_confirmed_at', v_before.last_confirmed_at),
                jsonb_build_object('confirmations', v_after.confirmations, 'last_confirmed_at', v_after.last_confirmed_at),
                p_thread);

      elsif v_kind = 'retire' then
        v_reason := left(coalesce(nullif(btrim(coalesce(v_op ->> 'reason', '')), ''), 'retired'), 300);
        v_tokens := coalesce(internal.coach_text_array(v_op -> 'tokens', 64, 64),
                             internal.coach_memory_tokens(v_before.content));
        update public.coach_memory_items m set retired_at = now(), retired_reason = v_reason
         where m.id = v_id and m.user_id = p_user
        returning * into v_after;
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens)
        values (p_user, v_id, 'retire', p_actor, internal.coach_memory_snapshot(v_before),
                internal.coach_memory_snapshot(v_after), p_thread, v_reason, v_tokens);
        v_bump := v_bump or internal.coach_memory_revises(v_before.topic, v_before.importance);

      else -- forget: the row goes; its earlier events lose their content; the tombstone keeps only tokens.
        v_tokens := coalesce(internal.coach_text_array(v_op -> 'tokens', 64, 64),
                             internal.coach_memory_tokens(v_before.content));
        delete from public.coach_memory_items m where m.id = v_id and m.user_id = p_user;
        update public.coach_memory_events e
           set before = case when e.before ? 'content' then e.before - 'content' else e.before end,
               after = case when e.after ? 'content' then e.after - 'content' else e.after end
         where e.user_id = p_user and e.memory_id = v_id and (e.before ? 'content' or e.after ? 'content');
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens)
        values (p_user, v_id, 'forget', p_actor, internal.coach_memory_snapshot(v_before, false), null, p_thread,
                left(nullif(btrim(coalesce(v_op ->> 'reason', '')), ''), 300), v_tokens);
        v_bump := v_bump or internal.coach_memory_revises(v_before.topic, v_before.importance);
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', true));

    elsif v_kind = 'merge' then
      select * into v_before from public.coach_memory_items m where m.id = v_id and m.user_id = p_user for update;
      if not found or v_before.retired_at is not null then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', case when found then 'retired' else 'not_found' end));
        continue;
      end if;
      select coalesce(array_agg(distinct x.id), '{}'::uuid[]) into v_ids
        from (select internal.coach_uuid(e.value #>> '{}') as id
                from jsonb_array_elements(case when jsonb_typeof(v_op -> 'ids') = 'array' then v_op -> 'ids'
                                               else '[]'::jsonb end) as e(value)) x
       where x.id is not null and x.id <> v_id;
      select count(*), coalesce(sum(m.confirmations), 0), max(m.last_confirmed_at),
             coalesce(bool_or(internal.coach_memory_revises(m.topic, m.importance)), false),
             coalesce(array_agg(m.id order by m.id), '{}'::uuid[])
        into v_others, v_confirmations, v_last, v_others_revise, v_ids
        from (select m.* from public.coach_memory_items m
               where m.user_id = p_user and m.id = any(v_ids) and m.retired_at is null
               order by m.id for update) m;
      if v_others = 0 then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', 'nothing_to_merge'));
        continue;
      end if;
      v_content := coalesce(internal.coach_memory_content(v_op ->> 'content'), v_before.content);
      v_topic := case when jsonb_typeof(v_op -> 'topic') = 'string'
                      then internal.coach_memory_topic(v_op ->> 'topic') else v_before.topic end;
      v_importance := internal.coach_memory_importance(v_op -> 'importance', v_before.importance);
      update public.coach_memory_items m
         set content = v_content, topic = v_topic, importance = v_importance,
             confirmations = m.confirmations + v_confirmations, version = m.version + 1, updated_at = now(),
             last_confirmed_at = greatest(m.last_confirmed_at, v_last)
       where m.id = v_id and m.user_id = p_user
      returning * into v_after;
      insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason)
      values (p_user, v_id, 'merge', p_actor, internal.coach_memory_snapshot(v_before),
              internal.coach_memory_snapshot(v_after) || jsonb_build_object('merged_ids', to_jsonb(v_ids)), p_thread,
              left(nullif(btrim(coalesce(v_op ->> 'reason', '')), ''), 300));
      for r in
        update public.coach_memory_items m set retired_at = now(), retired_reason = 'merged'
         where m.user_id = p_user and m.id = any(v_ids) and m.retired_at is null
        returning m.*
      loop
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason)
        values (p_user, r.id, 'merge', p_actor, null,
                jsonb_build_object('retired_reason', 'merged', 'merged_into', v_id), p_thread, 'merged');
      end loop;
      v_bump := v_bump or v_others_revise or internal.coach_memory_revises(v_before.topic, v_before.importance)
                       or internal.coach_memory_revises(v_after.topic, v_after.importance);
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', true));

    elsif v_kind = 'forget_all' then
      with gone as (
        delete from public.coach_memory_items m where m.user_id = p_user returning m.*
      )
      insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens)
      select p_user, g.id, 'forget', p_actor, internal.coach_memory_snapshot(g, false), null, p_thread,
             'forget_all', internal.coach_memory_tokens(g.content)
        from gone g;
      update public.coach_memory_events e
         set before = case when e.before ? 'content' then e.before - 'content' else e.before end,
             after = case when e.after ? 'content' then e.after - 'content' else e.after end
       where e.user_id = p_user and (e.before ? 'content' or e.after ? 'content');
      update public.coach_user_state s
         set memory_floor_at = now(), recent_searches = '[]'::jsonb, suggestions = '[]'::jsonb,
             suggestions_fingerprint = null, suggestions_at = null, updated_at = now()
       where s.user_id = p_user;
      v_bump := true;
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'forget_all', 'id', null, 'applied', true));

    elsif v_kind = 'consolidated' then
      update public.coach_user_state s
         set consolidated_at = now(), consolidation_until = null, updated_at = now()
       where s.user_id = p_user;
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'consolidated', 'id', null, 'applied', true));

    else
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', false,
        'reason', 'unknown_op'));
    end if;
  end loop;

  -- The cap: the lowest-scoring active rows beyond 200 are soft-retired (the newest row can be one of them).
  select count(*) into v_active from public.coach_memory_items m where m.user_id = p_user and m.retired_at is null;
  if v_active > 200 then
    for r in
      with victims as (
        select m.id from public.coach_memory_items m
         where m.user_id = p_user and m.retired_at is null
         order by m.importance / 5.0
                    + 0.5 * exp(-greatest(extract(epoch from (now() - m.last_confirmed_at))::float8, 0) / 86400.0 / 120.0)
                    + 0.2 * ln(1 + m.confirmations),
                  m.last_confirmed_at, m.created_at, m.id
         limit v_active - 200
      )
      update public.coach_memory_items m set retired_at = now(), retired_reason = 'evict'
        from victims v
       where m.id = v.id and m.user_id = p_user
      returning m.*
    loop
      insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason)
      values (p_user, r.id, 'evict', p_actor, null, internal.coach_memory_snapshot(r), p_thread, 'cap');
      v_bump := v_bump or internal.coach_memory_revises(r.topic, r.importance);
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'evict', 'id', r.id, 'applied', true,
        'reason', 'cap'));
    end loop;
  end if;

  -- Retention: retired rows for 30 days; the newest 1,000 events, with forget tombstones kept for 365 days.
  delete from public.coach_memory_items m
   where m.user_id = p_user and m.retired_at < now() - interval '30 days';
  delete from public.coach_memory_events e
   using (select x.id from public.coach_memory_events x
           where x.user_id = p_user
           order by x.created_at desc, x.id desc
          offset 1000) old
   where e.id = old.id and e.user_id = p_user and e.op <> 'forget';
  delete from public.coach_memory_events e
   where e.user_id = p_user and e.op = 'forget' and e.created_at < now() - interval '365 days';

  if v_bump then
    update public.coach_user_state s set memory_revision = s.memory_revision + 1, updated_at = now()
     where s.user_id = p_user;
  end if;
  return v_results;
end;
$$;

-- Claims the owner's consolidation pass: free (or expired) lease, and more than 120 active memories, or more
-- than 40 with no consolidation in the last 72 hours. The `consolidated` op of coach_memory_apply_v1 ends it.
create or replace function public.coach_consolidation_claim_v1(p_user uuid, p_lease_seconds integer default 120)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_lease integer := least(greatest(coalesce(p_lease_seconds, 120), 10), 900);
  v_active integer;
begin
  perform internal.coach_owner_check(p_user);
  insert into public.coach_user_state (user_id) values (p_user) on conflict (user_id) do nothing;
  select count(*) into v_active from public.coach_memory_items m where m.user_id = p_user and m.retired_at is null;
  update public.coach_user_state s
     set consolidation_until = now() + make_interval(secs => v_lease), updated_at = now()
   where s.user_id = p_user
     and (s.consolidation_until is null or s.consolidation_until <= now())
     and (v_active > 120
          or (v_active > 40 and (s.consolidated_at is null or s.consolidated_at < now() - interval '72 hours')));
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['coach_folders', 'coach_threads', 'coach_thread_tombstones', 'coach_memory_events',
                           'coach_user_state'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_service', t);
    execute format('create policy %I on public.%I for all to service_role using (true) with check (true)',
                   t || '_service', t);
  end loop;
  execute format('revoke all on sequence %s from public, anon, authenticated',
                 pg_get_serial_sequence('public.coach_memory_events', 'id'));
  execute format('grant usage, select on sequence %s to service_role',
                 pg_get_serial_sequence('public.coach_memory_events', 'id'));
end $$;

revoke all on function internal.coach_owner_check(uuid) from public, anon, authenticated, service_role;
revoke all on function internal.coach_uuid(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_collapse(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_preview_text(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_thread_title(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_thread_preview(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function internal.coach_messages_cap() from public, anon, authenticated, service_role;
revoke all on function internal.coach_query_terms(text, integer) from public, anon, authenticated, service_role;
revoke all on function internal.coach_terms_tsquery(text[]) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_topic(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_importance(jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_content(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_revises(text, integer) from public, anon, authenticated, service_role;
revoke all on function internal.coach_text_array(jsonb, integer, integer) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_tokens(text) from public, anon, authenticated, service_role;
revoke all on function internal.coach_memory_snapshot(public.coach_memory_items, boolean)
  from public, anon, authenticated, service_role;
revoke all on function internal.coach_thread_folder_owner() from public, anon, authenticated, service_role;
revoke all on function internal.coach_messages_thread_stats() from public, anon, authenticated, service_role;

revoke all on function public.coach_take_utility_quota(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.coach_add_utility_tokens(uuid, integer) from public, anon, authenticated;
revoke all on function public.coach_messages_save_v1(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.coach_search_v1(uuid, text, integer, integer, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
revoke all on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) from public, anon, authenticated;
revoke all on function public.coach_context_manifest_v1(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.coach_thread_claim_v1(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.coach_thread_publish_v1(uuid, uuid, uuid, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function public.coach_consolidation_claim_v1(uuid, integer) from public, anon, authenticated;

grant execute on function public.coach_take_utility_quota(uuid, integer, integer) to service_role;
grant execute on function public.coach_add_utility_tokens(uuid, integer) to service_role;
grant execute on function public.coach_messages_save_v1(uuid, jsonb) to service_role;
grant execute on function public.coach_search_v1(uuid, text, integer, integer, uuid, timestamptz, timestamptz)
  to service_role;
grant execute on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) to service_role;
grant execute on function public.coach_context_manifest_v1(uuid, uuid, text) to service_role;
grant execute on function public.coach_thread_claim_v1(uuid, uuid, integer) to service_role;
grant execute on function public.coach_thread_publish_v1(uuid, uuid, uuid, jsonb, jsonb) to service_role;
grant execute on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) to service_role;
grant execute on function public.coach_consolidation_claim_v1(uuid, integer) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 8. Comments
-- ---------------------------------------------------------------------------------------------------------

comment on table public.coach_folders is
  'Sana chat folders. Client-generated ids; a thread may only sit in its owner''s folder (coach_thread_folder_owner). Service role only.';
comment on table public.coach_threads is
  'One row per Sana chat. Stats (message_count, last_message_at, preview) are kept by the coach_messages triggers; the rolling summary and the maintenance lease are written by coach_thread_publish_v1 / coach_thread_claim_v1. Service role only.';
comment on column public.coach_threads.title_source is
  'none | auto (model) | user (renamed) | fallback (first words of the question) | legacy (backfill). Only none, fallback and legacy titles are regenerated.';
comment on column public.coach_threads.origin is
  'app (client thread id) | legacy_client (saved by an app build without threads) | backfill (grouped by the 20261007160000 migration).';
comment on column public.coach_threads.summary_through is
  'Newest message created_at folded into summary; summary_messages counts those messages.';
comment on column public.coach_threads.curated_through is
  'Newest message created_at the memory curator has read.';
comment on column public.coach_threads.search is
  'Title (weight A) and summary (weight B), english. Indexed with user_id through btree_gin.';
comment on table public.coach_thread_tombstones is
  'Thread ids the owner deleted. coach_messages_save_v1 rejects rows for them with thread_deleted; purged after 90 days. Service role only.';
comment on table public.coach_memory_events is
  'Audit trail of coach_memory_items changes (add, update, confirm, retire, merge, forget, evict). forget rows are the tombstones the curator checks (tokens only, no content). Newest 1,000 per owner, forget rows for 365 days. Service role only.';
comment on column public.coach_memory_events.tokens is
  'Normalised token set of the memory content (docs/COACH_MEMORY.md §6), for forget and retire.';
comment on table public.coach_user_state is
  'One row per owner: starter-suggestion cache, recent searches, the consolidation lease, memory_revision (moves only on changes to importance >= 4 goal/injury/health/training rows, or forget-all) and memory_floor_at (set by forget-all; the curator never mines older messages). Service role only.';
comment on column public.coach_messages.thread_id is
  'The chat this message belongs to (coach_threads, same owner through the composite foreign key).';
comment on column public.coach_messages.blocked is
  'meta.blocked: a turn screened out by CoachSafety, or its refusal. Excluded from summaries, curation, search, recall, follow-ups and suggestions.';
comment on column public.coach_messages.search is
  'english tsvector of the first 8,000 characters; user messages weight A, assistant messages weight B.';
comment on column public.coach_memory_items.source is
  'tool (save_memory) | curator (maintenance pass) | user (asked explicitly) | legacy (before 20261007160000).';
comment on column public.coach_memory_items.retired_at is
  'Soft retirement (retire, merge, evict). Readers ignore retired rows; they are purged after 30 days.';
comment on column public.coach_usage.utility_calls is
  'Cheap-model calls today (coach_take_utility_quota against COACH_DAILY_UTILITY_LIMIT).';
comment on column public.coach_usage.utility_tokens is
  'Cheap-model tokens today (coach_add_utility_tokens).';
comment on function public.coach_messages_save_v1(uuid, jsonb) is
  'Stores a validated batch of chat rows for p_user: resolves legacy thread-less rows, checks tombstones and ownership per thread, creates missing threads, upserts on (user_id, client_id) merging meta, prunes beyond 50,000 messages. Returns {saved, rejected[{client_id, reason}], threads[{id, created}]}.';
comment on function public.coach_search_v1(uuid, text, integer, integer, uuid, timestamptz, timestamptz) is
  'Ranked lexical search of p_user''s non-blocked messages and thread titles/summaries, grouped by thread; browse by date window for a query without lexemes.';
comment on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) is
  'Active memories ranked for a question, safety pins first.';
comment on function public.coach_context_manifest_v1(uuid, uuid, text) is
  'The context library manifest for one turn: ranked memories, the current thread''s summary, library counts, recent and relevant threads, open loops, memory_revision. Never message contents.';
comment on function public.coach_thread_claim_v1(uuid, uuid, integer) is
  'Takes a thread''s maintenance lease when free or expired.';
comment on function public.coach_thread_publish_v1(uuid, uuid, uuid, jsonb, jsonb) is
  'Applies a maintenance pass (summary patch and curator memory ops) atomically while the lease token is current; releases the lease. {applied:false, reason:lease_lost} otherwise.';
comment on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) is
  'Applies resolved memory ops (add, update, confirm, retire, merge, forget, forget_all, consolidated), enforces the 200-row cap, audits every change in coach_memory_events.';
comment on function public.coach_consolidation_claim_v1(uuid, integer) is
  'Claims the owner''s memory consolidation pass when it is due.';
comment on function public.coach_take_utility_quota(uuid, integer, integer) is
  'Takes p_units of the owner''s daily cheap-model budget atomically; false when that would exceed p_limit.';
comment on function public.coach_add_utility_tokens(uuid, integer) is
  'Adds cheap-model token usage to the owner''s day.';

commit;
