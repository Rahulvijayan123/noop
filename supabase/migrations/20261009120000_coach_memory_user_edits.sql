-- Sana memories the user edits (docs/COACH_MEMORY.md §3 coach_memory_apply_v1, §4 PATCH memories/<id>).
--
-- WHY
-- The memory sheet could only forget a fact, never correct it, and the store had nothing that kept a corrected
-- fact corrected: the curator could rewrite or retire a row the user had written, and could learn the old wording
-- again from the chat it came from. memory_revision moved only for important goal/injury/health/training rows, so
-- another phone's cached context kept a fact the user had changed or forgotten.
--
-- WHAT CHANGES (functions only; no table, column or constraint changes)
-- coach_memory_apply_v1, re-created with every existing rule, plus:
--   * an `update` by actor `user` sets source = 'user'. When it changes the text, its event keeps the old text's
--     token set (`tokens`, reason `user_edit`) and no old text: like a forget tombstone, it keeps the curator and
--     automatic saves from learning the old wording again, and the row's earlier events lose their text;
--   * a row with source 'user' is the user's own wording: the curator and the consolidator may still confirm it
--     or change its importance, but an update that changes its text or topic, a retire, or a merge that touches
--     it is skipped with reason `user_edited`. The 200-row cap evicts every other row before a user row;
--   * every op the user applies (add, update, forget, forget_all) moves memory_revision, whatever its topic or
--     importance, so every device's cached context is replaced after a change made on any of them;
--   * edit tombstones are kept like forget tombstones: past the newest 1,000 events, for 365 days.
-- coach_memories_ranked_v1, re-created with `version` on each row (the context manifest and GET memories?q=
-- carry it, so an edit can be version-guarded from any list the phone holds).
--
-- Safe to re-run (create or replace). Rollback: re-apply the two functions from
-- 20261007160000_coach_threads_memory.sql; rows written meanwhile stay valid under the old rules (a 'user'
-- source was always allowed).
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';

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
                            'confirmations', a.confirmations, 'pinned', c.pinned, 'version', a.version) order by c.pos)
                            from chosen c join active a on a.id = c.id), '[]'::jsonb),
    'total', (select count(*) from active),
    'topics', coalesce((select jsonb_object_agg(t.topic, t.n)
                          from (select a.topic, count(*) as n from active a group by a.topic) t), '{}'::jsonb))
    into v_result;
  return v_result;
end;
$$;

-- Applies resolved memory ops for one owner (docs/COACH_MEMORY.md §3). The ops arrive validated by the edge
-- function; ownership, retired state and lengths are re-checked here. Writers of one owner are
-- serialised on their coach_user_state row. Returns [{op, id, applied, reason?}], plus one
-- {op:'evict', id, applied:true, reason:'cap'} per evicted row.
-- Version guards, for ops resolved from an earlier read (the curator and the consolidator send them, and so does
-- an edit from the memory sheet): update and retire may carry expect_version, and merge may carry versions
-- {"<id>": version} for keep_id and every id. When a guarded row is missing, retired or at another version, the
-- whole op is skipped with reason stale. An op without a guard behaves as it always did.
-- A row the user wrote (source 'user') is not the curator's or the consolidator's to reword: their update of its
-- text or topic, their retire, and their merge touching it are skipped with reason user_edited (confirm and an
-- importance-only update still apply). The user's own update of a row makes it source 'user'; when it changes the
-- text, the event keeps the old text's tokens (an edit tombstone, reason user_edit) and no event keeps the old text.
-- Every op the user applies moves memory_revision.
-- Forget and forget-all stamp their tombstones and memory_floor_at with the clock read after taking the lock,
-- so they sort after every maintenance claim that came before them (coach_thread_claim_v1).
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
  v_others_user boolean;
  v_active integer;
  v_bump boolean := false;
  v_results jsonb := '[]'::jsonb;
  v_guard boolean;
  v_expect integer;
  v_versions jsonb;
  v_req uuid[];
  v_members uuid[];
  v_stale boolean;
  v_edited boolean;
  v_machine boolean := p_actor in ('curator', 'consolidator');
  v_now timestamptz;
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
  v_now := clock_timestamp();

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
      v_bump := v_bump or p_actor = 'user' or internal.coach_memory_revises(v_after.topic, v_after.importance);
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'add', 'id', v_after.id, 'applied', true));

    elsif v_kind in ('update', 'confirm', 'retire', 'forget') then
      v_guard := v_kind in ('update', 'retire') and v_op ? 'expect_version';
      v_expect := case when v_guard then internal.coach_int(v_op -> 'expect_version') end;
      select * into v_before from public.coach_memory_items m where m.id = v_id and m.user_id = p_user for update;
      if v_guard and (not found or v_before.retired_at is not null or v_expect is null
                      or v_before.version is distinct from v_expect) then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', false,
          'reason', 'stale'));
        continue;
      end if;
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
        -- The user's wording stays the user's: a pass may confirm it or move its importance, nothing else.
        if v_machine and v_before.source = 'user'
           and (v_content is distinct from v_before.content or v_topic is distinct from v_before.topic) then
          v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'update', 'id', v_id, 'applied', false,
            'reason', 'user_edited'));
          continue;
        end if;
        v_edited := p_actor = 'user' and v_content is distinct from v_before.content;
        update public.coach_memory_items m
           set content = v_content, topic = v_topic, importance = v_importance, version = m.version + 1,
               updated_at = now(), last_confirmed_at = now(),
               source = case when p_actor = 'user' then 'user' else m.source end
         where m.id = v_id and m.user_id = p_user
        returning * into v_after;
        if v_edited then
          -- An edit tombstone: the old text's tokens (the caller's, else the database's approximation), and no
          -- event of this row keeps the old text.
          v_tokens := coalesce(internal.coach_text_array(v_op -> 'tokens', 64, 64),
                               internal.coach_memory_tokens(v_before.content));
          update public.coach_memory_events e
             set before = case when e.before ? 'content' then e.before - 'content' else e.before end,
                 after = case when e.after ? 'content' then e.after - 'content' else e.after end
           where e.user_id = p_user and e.memory_id = v_id and (e.before ? 'content' or e.after ? 'content');
        end if;
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens)
        values (p_user, v_id, 'update', p_actor, internal.coach_memory_snapshot(v_before, not v_edited),
                internal.coach_memory_snapshot(v_after), p_thread,
                case when v_edited then 'user_edit' end, case when v_edited then v_tokens end);
        v_bump := v_bump or p_actor = 'user' or internal.coach_memory_revises(v_before.topic, v_before.importance)
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
        v_bump := v_bump or p_actor = 'user';

      elsif v_kind = 'retire' then
        if v_machine and v_before.source = 'user' then
          v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'retire', 'id', v_id, 'applied', false,
            'reason', 'user_edited'));
          continue;
        end if;
        v_reason := left(coalesce(nullif(btrim(coalesce(v_op ->> 'reason', '')), ''), 'retired'), 300);
        v_tokens := coalesce(internal.coach_text_array(v_op -> 'tokens', 64, 64),
                             internal.coach_memory_tokens(v_before.content));
        update public.coach_memory_items m set retired_at = now(), retired_reason = v_reason
         where m.id = v_id and m.user_id = p_user
        returning * into v_after;
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens)
        values (p_user, v_id, 'retire', p_actor, internal.coach_memory_snapshot(v_before),
                internal.coach_memory_snapshot(v_after), p_thread, v_reason, v_tokens);
        v_bump := v_bump or p_actor = 'user' or internal.coach_memory_revises(v_before.topic, v_before.importance);

      else -- forget: the row goes; its earlier events lose their content; the tombstone keeps only tokens.
        v_tokens := coalesce(internal.coach_text_array(v_op -> 'tokens', 64, 64),
                             internal.coach_memory_tokens(v_before.content));
        -- The rows a merge folded into this one (and into those, and so on) state the same fact in their own
        -- words: they go with it, each leaving its own tombstone.
        with recursive folded(id) as (
          select m.id from public.coach_memory_items m where m.user_id = p_user and m.merged_into = v_id
          union
          select m.id from public.coach_memory_items m join folded f on m.merged_into = f.id
           where m.user_id = p_user
        )
        select coalesce(array_agg(f.id), '{}'::uuid[]) into v_members from folded f;
        for r in
          delete from public.coach_memory_items m where m.user_id = p_user and m.id = any(v_members) returning m.*
        loop
          insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason,
                                                  tokens, created_at)
          values (p_user, r.id, 'forget', p_actor, internal.coach_memory_snapshot(r, false), null, p_thread,
                  'merged into a forgotten memory', internal.coach_memory_tokens(r.content), v_now);
          v_bump := v_bump or internal.coach_memory_revises(r.topic, r.importance);
        end loop;
        delete from public.coach_memory_items m where m.id = v_id and m.user_id = p_user;
        update public.coach_memory_events e
           set before = case when e.before ? 'content' then e.before - 'content' else e.before end,
               after = case when e.after ? 'content' then e.after - 'content' else e.after end
         where e.user_id = p_user and (e.memory_id = v_id or e.memory_id = any(v_members))
           and (e.before ? 'content' or e.after ? 'content');
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens,
                                                created_at)
        values (p_user, v_id, 'forget', p_actor, internal.coach_memory_snapshot(v_before, false), null, p_thread,
                left(nullif(btrim(coalesce(v_op ->> 'reason', '')), ''), 300), v_tokens, v_now);
        v_bump := v_bump or p_actor = 'user' or internal.coach_memory_revises(v_before.topic, v_before.importance);
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', v_kind, 'id', v_id, 'applied', true));

    elsif v_kind = 'merge' then
      v_guard := v_op ? 'versions';
      v_versions := case when jsonb_typeof(v_op -> 'versions') = 'object' then v_op -> 'versions' end;
      select * into v_before from public.coach_memory_items m where m.id = v_id and m.user_id = p_user for update;
      if v_guard and (v_versions is null or not found or v_before.retired_at is not null
                      or internal.coach_int(v_versions -> v_id::text) is distinct from v_before.version) then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', 'stale'));
        continue;
      end if;
      if not found or v_before.retired_at is not null then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', case when found then 'retired' else 'not_found' end));
        continue;
      end if;
      select coalesce(array_agg(distinct x.id), '{}'::uuid[]) into v_req
        from (select internal.coach_uuid(e.value #>> '{}') as id
                from jsonb_array_elements(case when jsonb_typeof(v_op -> 'ids') = 'array' then v_op -> 'ids'
                                               else '[]'::jsonb end) as e(value)) x
       where x.id is not null and x.id <> v_id;
      select count(*), coalesce(sum(m.confirmations), 0), max(m.last_confirmed_at),
             coalesce(bool_or(internal.coach_memory_revises(m.topic, m.importance)), false),
             coalesce(array_agg(m.id order by m.id), '{}'::uuid[]),
             coalesce(bool_or(internal.coach_int(v_versions -> m.id::text) is distinct from m.version), false),
             coalesce(bool_or(m.source = 'user'), false)
        into v_others, v_confirmations, v_last, v_others_revise, v_ids, v_stale, v_others_user
        from (select m.* from public.coach_memory_items m
               where m.user_id = p_user and m.id = any(v_req) and m.retired_at is null
               order by m.id for update) m;
      -- Guarded: every member must still be there, active and unchanged, or the merged text may restate a
      -- fact that has since been forgotten, retired or rewritten.
      if v_guard and (v_stale or v_others <> cardinality(v_req)) then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', 'stale'));
        continue;
      end if;
      if v_others = 0 then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', 'nothing_to_merge'));
        continue;
      end if;
      -- A merge rewords its kept row and retires the others: never one the user wrote, unless the user asks.
      if v_machine and (v_before.source = 'user' or v_others_user) then
        v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', false,
          'reason', 'user_edited'));
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
        update public.coach_memory_items m set retired_at = now(), retired_reason = 'merged', merged_into = v_id
         where m.user_id = p_user and m.id = any(v_ids) and m.retired_at is null
        returning m.*
      loop
        insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason)
        values (p_user, r.id, 'merge', p_actor, null,
                jsonb_build_object('retired_reason', 'merged', 'merged_into', v_id), p_thread, 'merged');
      end loop;
      v_bump := v_bump or p_actor = 'user' or v_others_revise
                       or internal.coach_memory_revises(v_before.topic, v_before.importance)
                       or internal.coach_memory_revises(v_after.topic, v_after.importance);
      v_results := v_results || jsonb_build_array(jsonb_build_object('op', 'merge', 'id', v_id, 'applied', true));

    elsif v_kind = 'forget_all' then
      with gone as (
        delete from public.coach_memory_items m where m.user_id = p_user returning m.*
      )
      insert into public.coach_memory_events (user_id, memory_id, op, actor, before, after, thread_id, reason, tokens,
                                              created_at)
      select p_user, g.id, 'forget', p_actor, internal.coach_memory_snapshot(g, false), null, p_thread,
             'forget_all', internal.coach_memory_tokens(g.content), v_now
        from gone g;
      update public.coach_memory_events e
         set before = case when e.before ? 'content' then e.before - 'content' else e.before end,
             after = case when e.after ? 'content' then e.after - 'content' else e.after end
       where e.user_id = p_user and (e.before ? 'content' or e.after ? 'content');
      update public.coach_user_state s
         set memory_floor_at = v_now, recent_searches = '[]'::jsonb, suggestions = '[]'::jsonb,
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

  -- The cap: the lowest-scoring active rows beyond 200 are soft-retired (the newest row can be one of them). Rows
  -- the user wrote go last.
  select count(*) into v_active from public.coach_memory_items m where m.user_id = p_user and m.retired_at is null;
  if v_active > 200 then
    for r in
      with victims as (
        select m.id from public.coach_memory_items m
         where m.user_id = p_user and m.retired_at is null
         order by m.source = 'user',
                  m.importance / 5.0
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

  -- Retention: retired rows for 30 days; the newest 1,000 events, with the tombstones (forget events and the
  -- user's edits that changed a text) kept for 365 days.
  delete from public.coach_memory_items m
   where m.user_id = p_user and m.retired_at < now() - interval '30 days';
  delete from public.coach_memory_events e
   using (select x.id from public.coach_memory_events x
           where x.user_id = p_user
           order by x.created_at desc, x.id desc
          offset 1000) old
   where e.id = old.id and e.user_id = p_user and e.op <> 'forget'
     and not (e.op = 'update' and e.actor = 'user' and e.tokens is not null);
  delete from public.coach_memory_events e
   where e.user_id = p_user and e.created_at < now() - interval '365 days'
     and (e.op = 'forget' or (e.op = 'update' and e.actor = 'user' and e.tokens is not null));

  if v_bump then
    update public.coach_user_state s set memory_revision = s.memory_revision + 1, updated_at = now()
     where s.user_id = p_user;
  end if;
  return v_results;
end;
$$;

revoke all on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) from public, anon, authenticated;
revoke all on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) to service_role;
grant execute on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) to service_role;

comment on function public.coach_memories_ranked_v1(uuid, text, integer, boolean) is
  'Active memories ranked for a question, safety pins first. Each row carries its version.';
comment on function public.coach_memory_apply_v1(uuid, jsonb, text, uuid) is
  'Applies resolved memory ops (add, update, confirm, retire, merge, forget, forget_all, consolidated), enforces the 200-row cap (user rows evicted last), audits every change in coach_memory_events. Optional version guards (expect_version, versions) skip a stale op with reason stale; forget also deletes the rows merged into the forgotten one. A user update makes the row source user and, when it changes the text, leaves an edit tombstone (tokens, reason user_edit) and no old text; the curator and the consolidator never reword, retire or merge a user row (reason user_edited). Every user op moves memory_revision.';
comment on table public.coach_user_state is
  'One row per owner: starter-suggestion cache, recent searches, the consolidation lease, memory_revision (moves on every user change, on changes to importance >= 4 goal/injury/health/training rows, and on forget-all) and memory_floor_at (set by forget-all; the curator never mines older messages). Service role only.';
comment on table public.coach_memory_events is
  'Audit trail of coach_memory_items changes (add, update, confirm, retire, merge, forget, evict). The tombstones the curator and automatic saves check keep tokens only, no content: forget rows, and update rows by the user that changed a text (reason user_edit). Newest 1,000 per owner, tombstones for 365 days. Service role only.';

commit;
