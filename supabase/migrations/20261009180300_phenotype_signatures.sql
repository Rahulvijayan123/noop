-- Phenotype signatures, app/server part (docs/PHENOTYPE_SIGNATURES.md, "Caregiver evidence").
-- Applies after 20261009180000_manual_events.sql, 20261009180100_manual_event_context.sql and
-- 20261009180200_personal_event_detection.sql, all of which stay unchanged.
--
-- 1. A fourth manual entry kind, 'observation': "I was watching from ... to ...; every event that happened is
--    logged". It is caregiver evidence for the signature engine (preferred negative time for matched controls
--    and false-alert certification), never an event: it has no type, no activity kind, a start and an end
--    (end > start, at most 24 h), and it is archived and restored like any other entry. The edge validator
--    (manualEventRevisionProblem) holds the full rules; the database repeats the kind as a backstop:
--      - the table's kind CHECK (unnamed in part 1; Postgres generated manual_event_revisions_body_check1 on a
--        database built from the migrations) is found by its definition, dropped, and replaced by the named
--        constraint manual_event_revisions_kind_check that also allows 'observation';
--      - append_manual_event_revisions is re-created exactly as 20261008100000 left it, with 'observation'
--        added to its kind check and nothing else changed (signature, lock, per-item results, projection).
--    Every consumer of the log keeps filtering on its own kind: the context builder, the activity-label
--    projection and the background refresh read only kind = 'event'; PR #5's manual_events_current consumers
--    (event_detection_command) and the event_type archive fence read only 'event' / 'event_type'.
-- 2. Events may carry onsetUncertaintyMinutes (0, 5, 15 or 60): how sure the logger was of the start. It is an
--    entry field like activityKind, validated at the edge; the database stores it inside the body unchanged.
-- 3. Signature reports (signature-report-1) are stored by the engine in PR #5's event_detector_runs.report and
--    read by GET /scores/event-detection/signature through the service role. Clients keep no grant on the runs
--    table (row-level security on, every privilege revoked from anon and authenticated in 20261009090000);
--    the index below serves the route's "newest report of this owner and type" read.
--
-- Rollback: re-create the 20261008100000 append function, then drop manual_event_revisions_kind_check and
-- restore the part-1 kind check (only possible while no observation revision is stored; revisions are never
-- deleted, so once one exists the wider check stays). Drop event_detector_runs_signature_latest.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------------------------------------------------
-- 1. The kind CHECK on manual_event_revisions
-- ---------------------------------------------------------------------------------------------------------
do $$
declare c record;
begin
  -- Part 1 declared the check without a name. Find it by what it says, not by the generated name.
  for c in
    select con.conname from pg_constraint con
     where con.conrelid = 'public.manual_event_revisions'::regclass and con.contype = 'c'
       and con.conname <> 'manual_event_revisions_kind_check'
       and pg_get_constraintdef(con.oid) like '%kind%'
       and pg_get_constraintdef(con.oid) like '%preset%'
  loop
    execute format('alter table public.manual_event_revisions drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.manual_event_revisions drop constraint if exists manual_event_revisions_kind_check;
alter table public.manual_event_revisions add constraint manual_event_revisions_kind_check
  check (body -> 'entry' ->> 'kind' is not null
         and body -> 'entry' ->> 'kind' in ('event', 'event_type', 'preset', 'observation')) not valid;
alter table public.manual_event_revisions validate constraint manual_event_revisions_kind_check;

-- ---------------------------------------------------------------------------------------------------------
-- 2. Append: 20261008100000's function with 'observation' added to the kind check, nothing else changed
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.append_manual_event_revisions(p_user uuid, p_source uuid, p_items jsonb)
returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  item jsonb;
  previous jsonb;
  saved jsonb := '[]'::jsonb;
  rejected jsonb := '[]'::jsonb;
  touched uuid[] := '{}';
  v_entity uuid;
  -- The kind each touched type lent before this call, to re-project its events only when that changes.
  kinds_before jsonb := '{}'::jsonb;
  v_type text;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 25 then
    raise exception 'invalid_manual_events';
  end if;
  if not exists (select 1 from public.noop_app_installations
                 where user_id = p_user and source_id = p_source and revoked_at is null)
     and not exists (select 1 from public.compute_account_sources
                     where user_id = p_user and source_id = p_source and revoked_at is null) then
    raise exception 'manual_events_source_mismatch' using errcode = '42501';
  end if;
  -- Serialize inserts per owner before assigning sequence numbers: pagination cannot skip a late commit.
  perform pg_advisory_xact_lock(hashtextextended('manual-events:' || p_user::text, 0));
  for item in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(item -> 'entry') is distinct from 'object'
       or item -> 'entry' ->> 'kind' is null or item -> 'entry' ->> 'kind' not in ('event', 'event_type', 'preset', 'observation')
       or item -> 'entry' ->> 'label' is null or char_length(btrim(item -> 'entry' ->> 'label')) not between 1 and 100
       or octet_length(item::text) > 16384 then
      raise exception 'invalid_manual_event';
    end if;
    if item -> 'entry' ->> 'kind' = 'event_type' and not kinds_before ? lower(item -> 'entry' ->> 'id') then
      -- A type with no stored revision yet lends its factory default (or nothing).
      kinds_before := kinds_before || jsonb_build_object(lower(item -> 'entry' ->> 'id'), coalesce(
        (select public.manual_event_activity_kind_v1(p_user, c.entry)
           from public.manual_event_current_v1(p_user, (item -> 'entry' ->> 'id')::uuid) c),
        public.manual_event_activity_kind_v1(p_user, jsonb_build_object('kind', 'event_type', 'id', item -> 'entry' -> 'id'))));
    end if;
    select body into previous from public.manual_event_revisions
      where user_id = p_user and revision_id = (item ->> 'revision_id')::uuid;
    if found then
      if previous is distinct from item then
        rejected := rejected || jsonb_build_array(jsonb_build_object(
          'revision_id', item ->> 'revision_id', 'reason', 'revision_conflict'));
        continue;
      end if;
    else
      insert into public.manual_event_revisions(user_id, source_id, revision_id, entity_id, updated_at_ms, body)
        values (p_user, p_source, (item ->> 'revision_id')::uuid, (item -> 'entry' ->> 'id')::uuid,
                (item ->> 'updated_at_ms')::bigint, item);
      touched := touched || (item -> 'entry' ->> 'id')::uuid;
    end if;
    saved := saved || jsonb_build_array(item ->> 'revision_id');
  end loop;
  for v_entity in select distinct t from unnest(touched) t loop
    perform public.project_manual_event_v1(p_user, v_entity);
  end loop;
  -- A type whose lent kind changed re-projects the events that inherit it (no activityKind of their own).
  for v_type in select k from jsonb_object_keys(kinds_before) k loop
    if (kinds_before ->> v_type) is distinct from (
         select public.manual_event_activity_kind_v1(p_user, c.entry)
           from public.manual_event_current_v1(p_user, v_type::uuid) c) then
      for v_entity in
        select cur.entity_id
          from (select distinct on (r.entity_id) r.entity_id, r.body -> 'entry' as entry
                  from public.manual_event_revisions r
                 where r.user_id = p_user and r.body -> 'entry' ->> 'kind' = 'event'
                 order by r.entity_id, r.updated_at_ms desc, r.revision_id desc) cur
         where (cur.entry ->> 'typeId')::uuid = v_type::uuid and cur.entry ->> 'activityKind' is null
      loop
        perform public.project_manual_event_v1(p_user, v_entity);
      end loop;
    end if;
  end loop;
  return jsonb_build_object('saved', saved, 'rejected', rejected);
end $$;
revoke all on function public.append_manual_event_revisions(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.append_manual_event_revisions(uuid, uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 3. Signature reports: the newest report of an owner and type
-- ---------------------------------------------------------------------------------------------------------
create index if not exists event_detector_runs_signature_latest
  on public.event_detector_runs (user_id, type_id, created_at desc, id desc)
  where report ->> 'version' = 'signature-report-1';

comment on constraint manual_event_revisions_kind_check on public.manual_event_revisions is
  'Entry kinds: event, event_type, preset, observation (a watched period in which every event is logged).';

commit;
