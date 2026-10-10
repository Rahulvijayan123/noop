-- Manual events, part 2: per-item sync results, timestamp-aligned context, and the activity-label projection.
-- Applies after 20261009180000_manual_events.sql, which stays unchanged (migration files are immutable once
-- applied). Every object here is additive or `create or replace`; the append RPC keeps its signature, its
-- 'manual-events:<owner>' advisory lock and its body shape, so callers built on part 1 keep working.
--
-- 1. append_manual_event_revisions reports a revision whose UUID already holds different content as
--    `rejected: [{revision_id, reason: 'revision_conflict'}]` instead of failing the whole batch. One bad
--    revision used to block every later write of the account forever (the client sends oldest first).
-- 2. Activity-kind events are projected into activity_ground_truth_labels with source 'manual_event'
--    (label_key 'manual_event:<entity>'), next to guided and stretch-feedback labels. They are weak labels
--    (self-logged, not cued) and carry no raw-IMU coverage facts (sensor_quality says so), so the evaluation
--    harness leaves them out by default and uses them, as weak, only when asked to include labels that are
--    not evaluation-ready. Only definitive kinds map (rest -> stationary, walking, running, cycling,
--    stairs); 'exercise' and 'other' have no definitive head label and are recorded as skipped. Archiving the
--    event, or changing its kind away from a mappable one, removes the projected row; the manual log keeps
--    every revision. manual_event_projections records the outcome per event. A type change re-projects only
--    when the kind it lends actually changed, and only the events that inherit it.
-- 3. manual_event_contexts holds one context document per event (manual-event-context-1): the pre / during /
--    post windows aligned to the event's own start and end, with
--      heart rate (per-second noop_hr_samples: n, coverage, mean, min, max, p10/p50/p90, and a binned trace),
--      wrist motion (noop_gravity_samples.dynAccel),
--      canonical server series (server_metric_series: HRV RMSSD and resting HR at 5 min, respiration, steps
--        and calories at 1 min) exactly as the scoring worker published them,
--      the activity classifier's runs (activity_context_runs: class seconds, mean class confidence, sleep and
--        wear seconds) and whether they agree with the logged activity kind,
--      wear events, placement, overlapping sleep, Watchdog candidates (anomaly_candidates), confirmed
--        exposures near the event, other logged events, personal baselines (7-day canonical resting HR and
--        HRV, causal frozen references, active baseline episodes) and the history of the same event type.
--    Nothing here re-implements a model: the classes, HRV and baselines are the published outputs of the
--    VPS workers, and the rest are plain summaries of measured samples. A context is recomputed while it can
--    still change (event running, data not yet uploaded, worker outputs still arriving) and frozen
--    (`final`) 72 hours after the post window closes.
--    Reads: GET /scores/manual-events/context?ids=... calls manual_event_contexts_v1 (read-through cache).
--    Background: pg_cron runs refresh_manual_event_contexts_v1 every 10 minutes for events that ended in
--    the last 14 days, so a context exists without the app being opened.
--
-- Privileges: clients may SELECT their own context and projection rows; every function is SECURITY DEFINER
-- with an empty search_path, EXECUTE revoked from public/anon/authenticated and granted to service_role.
-- Deletion: both new tables cascade from auth.users. The projected ground-truth rows cascade the same way.
-- Rollback: unschedule 'nara-manual-event-context', drop the functions and the two tables, restore the part-1
-- append function, and delete activity_ground_truth_labels rows with source = 'manual_event' before restoring
-- the old source check.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- ---------------------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------------------
create table if not exists public.manual_event_contexts (
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_id uuid not null,
  revision_id uuid not null,
  context_version text not null,
  status text not null check (status in ('running', 'awaiting_data', 'insufficient_data', 'ready')),
  final boolean not null default false,
  device_id uuid,
  computed_at timestamptz not null default clock_timestamp(),
  context jsonb not null check (jsonb_typeof(context) = 'object' and octet_length(context::text) <= 131072),
  primary key (user_id, entity_id)
);
create index if not exists manual_event_contexts_refresh
  on public.manual_event_contexts (final, computed_at) where not final;

create table if not exists public.manual_event_projections (
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_id uuid not null,
  target text not null check (target in ('activity_ground_truth')),
  revision_id uuid not null,
  status text not null check (status in ('projected', 'removed', 'skipped')),
  reason text check (reason is null or char_length(reason) between 1 and 64),
  label_key text,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, entity_id, target)
);

alter table public.manual_event_contexts enable row level security;
alter table public.manual_event_projections enable row level security;
revoke all on public.manual_event_contexts, public.manual_event_projections from public, anon, authenticated, service_role;
grant select on public.manual_event_contexts, public.manual_event_projections to authenticated;
grant select on public.manual_event_contexts, public.manual_event_projections to service_role;
drop policy if exists manual_event_contexts_owner_read on public.manual_event_contexts;
create policy manual_event_contexts_owner_read on public.manual_event_contexts
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists manual_event_projections_owner_read on public.manual_event_projections;
create policy manual_event_projections_owner_read on public.manual_event_projections
  for select to authenticated using (user_id = (select auth.uid()));

-- Manual events become one more ground-truth source. The edge validator still refuses it from clients
-- (GROUND_TRUTH_SOURCES), so only the projection below writes it.
alter table public.activity_ground_truth_labels drop constraint if exists activity_ground_truth_labels_source_check;
alter table public.activity_ground_truth_labels add constraint activity_ground_truth_labels_source_check
  check (source in ('guided', 'stretch_feedback', 'imported', 'confirmation', 'manual_event'));

-- ---------------------------------------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------------------------------------

-- The current revision of one entity: latest client timestamp, then revision UUID (the app's own rule).
create or replace function public.manual_event_current_v1(p_user uuid, p_entity uuid)
returns table (revision_id uuid, updated_at_ms bigint, source_id uuid, entry jsonb, seq bigint)
language sql stable security definer set search_path = '' as $$
  select r.revision_id, r.updated_at_ms, r.source_id, r.body -> 'entry', r.seq
    from public.manual_event_revisions r
   where r.user_id = p_user and r.entity_id = p_entity
   order by r.updated_at_ms desc, r.revision_id desc
   limit 1
$$;

-- The activity kind of an event: its own field, else its type's current field, else the fixed default
-- catalog (Rest, Walking, Exercise keep their original UUIDs, and their seed revisions predate the field).
create or replace function public.manual_event_activity_kind_v1(p_user uuid, p_entry jsonb)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_kind text := p_entry ->> 'activityKind';
  v_type uuid;
begin
  if v_kind is not null then return v_kind; end if;
  begin
    v_type := case when p_entry ->> 'kind' = 'event_type' then (p_entry ->> 'id')::uuid
                   else (p_entry ->> 'typeId')::uuid end;
  exception when others then return null;
  end;
  if v_type is null then return null; end if;
  if p_entry ->> 'kind' <> 'event_type' then
    select c.entry ->> 'activityKind' into v_kind from public.manual_event_current_v1(p_user, v_type) c;
    if v_kind is not null then return v_kind; end if;
  end if;
  return case v_type
    when '00000000-0000-4000-8000-000000000001'::uuid then 'rest'
    when '00000000-0000-4000-8000-000000000002'::uuid then 'walking'
    when '00000000-0000-4000-8000-000000000011'::uuid then 'exercise'
  end;
end $$;

-- The server device an event was recorded on. The app stores its own device id (activeDeviceId) on the
-- event; it is resolved exactly as findNoopDevice resolves it (installation-scoped unless it is a WHOOP
-- serial, then the confirmed-wearable alias), trying the source of every revision of the event. When the
-- id does not resolve, the device with the most heart-rate samples inside the event is used.
create or replace function public.manual_event_device_v1(p_user uuid, p_entity uuid, p_entry jsonb,
  p_from bigint, p_to bigint)
returns table (device_id uuid, resolution text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_external text := p_entry ->> 'deviceId';
  v_serial text;
  v_source uuid;
  v_key text;
  v_device uuid;
begin
  -- An app that already knows the server's id for the strap may store that UUID instead.
  if v_external ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select d.id into v_device from public.devices d where d.user_id = p_user and d.id = v_external::uuid;
    if v_device is not null then
      return query select v_device, 'entry'::text;
      return;
    end if;
  end if;
  if v_external is not null and v_external ~ '^[\x20-\x7e]{1,255}$' then
    v_serial := case when v_external like 'whoop-%' then substr(v_external, 7) else '' end;
    for v_source in
      select r.source_id from public.manual_event_revisions r
       where r.user_id = p_user and r.entity_id = p_entity group by r.source_id order by min(r.seq)
    loop
      v_key := case when v_serial ~ '^[A-Z0-9-]{6,}$'
                         and v_serial !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    then v_external
                    else 'installation:' || lower(v_source::text) || ':' || v_external end;
      select d.id into v_device from public.devices d
       where d.user_id = p_user and d.source_kind = 'noop_push' and d.external_device_id = v_key
       limit 1;
      if v_device is not null then
        select coalesce((select a.canonical_device_id from public.noop_wearable_aliases a
                          where a.user_id = p_user and a.provisional_device_id = v_device limit 1), v_device)
          into v_device;
        return query select v_device, 'entry'::text;
        return;
      end if;
    end loop;
  end if;
  select h.device_id into v_device from public.noop_hr_samples h
   where h.user_id = p_user and h.ts >= p_from and h.ts < greatest(p_to, p_from + 1)
   group by h.device_id order by count(*) desc, h.device_id limit 1;
  if v_device is not null then
    return query select v_device, 'coverage'::text;
  else
    return query select null::uuid, 'none'::text;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. Ground-truth projection
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.project_manual_event_v1(p_user uuid, p_entity uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  cur record;
  v_kind text;
  v_key text := 'manual_event:' || p_entity::text;
  v_start bigint;
  v_end bigint;
  v_device uuid;
  v_offset integer;
  v_status text;
  v_reason text;
  v_item jsonb;
  v_locomotion text;
begin
  select * into cur from public.manual_event_current_v1(p_user, p_entity);
  if not found or cur.entry ->> 'kind' <> 'event' then return null; end if;
  v_kind := public.manual_event_activity_kind_v1(p_user, cur.entry);
  v_locomotion := case v_kind when 'rest' then 'stationary' when 'walking' then 'walking'
    when 'running' then 'running' when 'cycling' then 'cycling' when 'stairs' then 'stairs' end;
  v_start := floor((cur.entry ->> 'startUnixSeconds')::double precision)::bigint;
  v_end := floor((cur.entry ->> 'endUnixSeconds')::double precision)::bigint;

  if coalesce((cur.entry ->> 'archived')::boolean, false) then v_reason := 'archived';
  elsif v_kind is null or v_kind = 'other' then v_reason := 'no_activity_kind';
  elsif v_locomotion is null then v_reason := 'no_definitive_label';
  elsif v_end is null then v_reason := 'running';
  elsif v_end <= v_start then v_reason := 'too_short';
  elsif v_end - v_start > 86400 then v_reason := 'longer_than_24h';
  elsif v_start <= 946684800 then v_reason := 'invalid_time';
  end if;

  if v_reason is not null then
    delete from public.activity_ground_truth_labels g
     where g.owner = p_user and g.label_key = v_key and g.source = 'manual_event';
    v_status := case when found then 'removed' else 'skipped' end;
  else
    select d.device_id into v_device
      from public.manual_event_device_v1(p_user, p_entity, cur.entry, v_start, v_end) d;
    begin
      v_offset := extract(epoch from (to_timestamp(v_start) at time zone (cur.entry ->> 'timeZoneIdentifier'))
                                     - (to_timestamp(v_start) at time zone 'UTC'))::integer;
      if v_offset not between -64800 and 64800 then v_offset := null; end if;
    exception when others then v_offset := null;
    end;
    v_item := jsonb_build_object(
      'client_id', p_entity, 'label_key', v_key, 'source', 'manual_event',
      'device_id', v_device, 'external_device_id', left(cur.entry ->> 'deviceId', 255),
      'start_ts', v_start, 'end_ts', v_end, 'locomotion', v_locomotion,
      'posture', null, 'arm_behavior', null, 'transition_kind', null, 'transition_ts', null,
      'semantic_tag', null, 'label_confidence', null, 'user_unsure', false,
      'note', nullif(left(cur.entry ->> 'note', 280), ''),
      'cue_context', jsonb_build_object('manual_event', jsonb_build_object(
        'entity_id', p_entity, 'revision_id', cur.revision_id, 'type_id', cur.entry -> 'typeId',
        'label', cur.entry -> 'label', 'activity_kind', v_kind)),
      -- No sample-level IMU coverage is known for a self-logged event: expected_seconds 0 keeps it out of
      -- evaluation-ready sets rather than claiming coverage from session spans.
      'sensor_quality', jsonb_build_object('basis', 'manual_event', 'imu_coverage', 'unknown', 'expected_seconds', 0),
      'raw_refs', '[]'::jsonb, 'model_context_at_label_time', '{}'::jsonb,
      'tz_offset_s', v_offset,
      'client_created_at', (select to_timestamp(min(r.updated_at_ms) / 1000.0) from public.manual_event_revisions r
                             where r.user_id = p_user and r.entity_id = p_entity),
      'client_updated_at', to_timestamp(cur.updated_at_ms / 1000.0));
    -- Re-projecting an unchanged event must not bump the label's revision or rewrite its raw_refs.
    if not exists (select 1 from public.activity_ground_truth_labels g
                    where g.owner = p_user and g.label_key = v_key and g.source = 'manual_event'
                      and g.client_updated_at = to_timestamp(cur.updated_at_ms / 1000.0)
                      and g.locomotion = v_locomotion and g.start_ts = v_start and g.end_ts = v_end
                      and g.device_id is not distinct from v_device) then
      perform public.upsert_activity_ground_truth_labels(p_user, jsonb_build_array(v_item));
    end if;
    v_status := 'projected';
  end if;

  insert into public.manual_event_projections as p (user_id, entity_id, target, revision_id, status, reason,
    label_key, updated_at)
  values (p_user, p_entity, 'activity_ground_truth', cur.revision_id, v_status, v_reason,
    case when v_status = 'projected' then v_key end, clock_timestamp())
  on conflict (user_id, entity_id, target) do update set revision_id = excluded.revision_id,
    status = case when excluded.status = 'skipped' and p.status in ('projected', 'removed') then 'removed'
                  else excluded.status end,
    reason = excluded.reason, label_key = excluded.label_key, updated_at = excluded.updated_at;
  return v_status;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. Append: per-item results, then the projection of every entity it touched
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
       or item -> 'entry' ->> 'kind' is null or item -> 'entry' ->> 'kind' not in ('event', 'event_type', 'preset')
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

-- ---------------------------------------------------------------------------------------------------------
-- 5. Context
-- ---------------------------------------------------------------------------------------------------------

-- Heart-rate statistics over [p_from, p_to) from per-second samples (physiological range only).
create or replace function public.manual_event_hr_stats_v1(p_user uuid, p_device uuid, p_from bigint, p_to bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when count(*) = 0 then jsonb_build_object('n', 0, 'coverage', 0) else jsonb_build_object(
      'n', count(*),
      'coverage', round(least(1, count(*)::numeric / greatest(1, p_to - p_from)), 3),
      'mean', round(avg(h.bpm)::numeric, 1),
      'min', min(h.bpm), 'max', max(h.bpm),
      'p10', round(percentile_cont(0.1) within group (order by h.bpm)::numeric, 1),
      'p50', round(percentile_cont(0.5) within group (order by h.bpm)::numeric, 1),
      'p90', round(percentile_cont(0.9) within group (order by h.bpm)::numeric, 1)) end
    from public.noop_hr_samples h
   where p_device is not null and p_to > p_from
     and h.user_id = p_user and h.device_id = p_device and h.ts >= p_from and h.ts < p_to
     and h.bpm between 25 and 250
$$;

-- Wrist motion over [p_from, p_to): mean and p90 of the gravity stream's dynamic acceleration.
create or replace function public.manual_event_motion_stats_v1(p_user uuid, p_device uuid, p_from bigint, p_to bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when count(*) = 0 then jsonb_build_object('n', 0) else jsonb_build_object(
      'n', count(*),
      'dyn_accel_mean', round(avg(g."dynAccel")::numeric, 4),
      'dyn_accel_p90', round(percentile_cont(0.9) within group (order by g."dynAccel")::numeric, 4)) end
    from public.noop_gravity_samples g
   where p_device is not null and p_to > p_from
     and g.user_id = p_user and g.device_id = p_device and g.ts >= p_from and g.ts < p_to
     and g."dynAccel" is not null
$$;

-- Canonical server series overlapping [p_from, p_to), one entry per metric: median for rates, sum for counts.
create or replace function public.manual_event_series_stats_v1(p_user uuid, p_from bigint, p_to bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(s.metric, s.summary), '{}'::jsonb) from (
    select m.metric, jsonb_build_object(
        'buckets', count(*),
        'bucket_seconds', max(m.bucket_seconds),
        'value', round((case when m.metric in ('steps', 'calories_kcal') then sum(m.value)
                             else percentile_cont(0.5) within group (order by m.value) end)::numeric, 2),
        'coverage', round(avg(m.coverage)::numeric, 3),
        'motion', round(avg(m.motion)::numeric, 3)) as summary
      from public.server_metric_series m
     where p_to > p_from and m.user_id = p_user
       and m.bucket_start < to_timestamp(p_to)
       and m.bucket_start > to_timestamp(p_from) - interval '1 hour'
       and m.bucket_start + make_interval(secs => m.bucket_seconds) > to_timestamp(p_from)
     group by m.metric) s
$$;

-- The activity classifier's runs over [p_from, p_to): class seconds and confidence, sleep and off-wrist
-- seconds. When both the raw-IMU (HART) and the stream document cover the window, the one covering more
-- of it wins (HART on a tie), so seconds are never counted twice.
create or replace function public.manual_event_activity_stats_v1(p_user uuid, p_device uuid, p_from bigint, p_to bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  with runs as (
    select r.source_rank, r.algorithm_version, r.activity_class, r.class_confidence, r.sleep_state, r.wear_state,
           r.model_version,
           least(r.end_ts, p_to) - greatest(r.start_ts, p_from) as overlap
      from public.activity_context_runs r
     where p_device is not null and p_to > p_from and r.user_id = p_user and r.device_id = p_device
       and r.day between (to_timestamp(p_from) at time zone 'UTC')::date
                     and (to_timestamp(greatest(p_to - 1, p_from)) at time zone 'UTC')::date
       and r.start_ts < p_to and r.end_ts > p_from
  ), pick as (
    select source_rank from runs group by source_rank order by sum(overlap) desc, source_rank limit 1
  ), chosen as (
    select runs.* from runs join pick using (source_rank)
  ), classes as (
    select coalesce(activity_class, 'unknown') as class, sum(overlap) as seconds,
           sum(overlap * class_confidence) / nullif(sum(overlap) filter (where class_confidence is not null), 0) as conf
      from chosen group by 1
  )
  select case when not exists (select 1 from chosen) then jsonb_build_object('covered_s', 0) else
    jsonb_build_object(
      'covered_s', (select sum(overlap) from chosen),
      'coverage', round(least(1, (select sum(overlap) from chosen)::numeric / greatest(1, p_to - p_from)), 3),
      'source', (select min(algorithm_version) from chosen),
      'model_version', (select min(model_version) from chosen),
      'classes', (select jsonb_agg(jsonb_build_object('class', class, 'seconds', seconds,
                    'confidence', round(conf::numeric, 3)) order by seconds desc, class) from classes),
      'sleep_s', (select coalesce(sum(overlap) filter (where sleep_state = 'asleep'), 0) from chosen),
      'off_wrist_s', (select coalesce(sum(overlap) filter (where wear_state = 'off_wrist'
                                                             or activity_class = 'off_wrist'), 0) from chosen))
  end
$$;

-- The whole context of one event, computed now. Pure: it writes nothing.
create or replace function public.manual_event_context_build_v1(p_user uuid, p_entity uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  cur record;
  e jsonb;
  v_now bigint := extract(epoch from clock_timestamp())::bigint;
  v_start bigint;
  v_end bigint;
  v_running boolean;
  v_point boolean;
  v_during_end bigint;
  v_pad constant integer := 1800;
  v_max_during constant integer := 86400;
  -- Uploads and worker outputs may arrive this long after an event; then the context is frozen.
  v_settle constant integer := 72 * 3600;
  v_truncated boolean := false;
  v_pre_a bigint; v_post_b bigint;
  v_device uuid;
  v_resolution text;
  v_kind text;
  v_zone text;
  v_day date;
  v_hr jsonb; v_hr_pre jsonb; v_hr_post jsonb;
  v_act jsonb; v_act_pre jsonb; v_act_post jsonb;
  v_series jsonb; v_series_pre jsonb; v_series_post jsonb;
  v_trace jsonb;
  v_hrv_trace jsonb;
  v_motion_trace jsonb;
  v_bin integer;
  v_through bigint;
  v_status text;
  v_expected text[];
  v_matched numeric;
  v_agreement jsonb;
  v_rest numeric; v_hrv numeric; v_rest_n integer; v_hrv_n integer;
  v_history jsonb;
  v_type_median numeric;
  v_comparisons jsonb := '{}'::jsonb;
  v_missing text[] := '{}';
begin
  select * into cur from public.manual_event_current_v1(p_user, p_entity);
  if not found then return null; end if;
  e := cur.entry;
  if e ->> 'kind' <> 'event' then return null; end if;

  v_start := floor((e ->> 'startUnixSeconds')::double precision)::bigint;
  v_end := ceil((e ->> 'endUnixSeconds')::double precision)::bigint;
  v_running := v_end is null;
  v_during_end := coalesce(v_end, greatest(v_start, least(v_now, v_start + v_max_during)));
  v_point := v_during_end <= v_start;
  if v_during_end - v_start > v_max_during then
    v_during_end := v_start + v_max_during;
    v_truncated := true;
  end if;
  v_pre_a := v_start - v_pad;
  v_post_b := coalesce(v_end, v_during_end) + v_pad;
  v_kind := public.manual_event_activity_kind_v1(p_user, e);
  v_zone := coalesce(nullif(e ->> 'timeZoneIdentifier', ''), 'UTC');
  begin
    v_day := (to_timestamp(v_start) at time zone v_zone)::date;
  exception when others then
    v_zone := 'UTC';
    v_day := (to_timestamp(v_start) at time zone 'UTC')::date;
  end;

  select d.device_id, d.resolution into v_device, v_resolution
    from public.manual_event_device_v1(p_user, p_entity, e, v_pre_a, v_post_b) d;

  -- Measurements, aligned to the event's own start and end.
  v_hr_pre := public.manual_event_hr_stats_v1(p_user, v_device, v_pre_a, v_start);
  v_hr := case when v_point then null else public.manual_event_hr_stats_v1(p_user, v_device, v_start, v_during_end) end;
  v_hr_post := case when v_running then null
                    else public.manual_event_hr_stats_v1(p_user, v_device, coalesce(v_end, v_during_end), v_post_b) end;
  v_series_pre := public.manual_event_series_stats_v1(p_user, v_pre_a, v_start);
  v_series := case when v_point then null else public.manual_event_series_stats_v1(p_user, v_start, v_during_end) end;
  v_series_post := case when v_running then null
                        else public.manual_event_series_stats_v1(p_user, coalesce(v_end, v_during_end), v_post_b) end;
  v_act_pre := public.manual_event_activity_stats_v1(p_user, v_device, v_pre_a, v_start);
  v_act := case when v_point then null else public.manual_event_activity_stats_v1(p_user, v_device, v_start, v_during_end) end;
  v_act_post := case when v_running then null
                     else public.manual_event_activity_stats_v1(p_user, v_device, coalesce(v_end, v_during_end), v_post_b) end;

  -- A heart-rate trace for charts: at most ~240 bins across pre + during + post.
  v_bin := greatest(60, ceil((least(v_post_b, v_now) - v_pre_a) / 240.0)::integer);
  select coalesce(jsonb_agg(jsonb_build_array(b.t, b.mean, b.lo, b.hi, b.n) order by b.t), '[]'::jsonb) into v_trace
    from (select v_pre_a + ((h.ts - v_pre_a) / v_bin) * v_bin as t, round(avg(h.bpm)::numeric, 1) as mean,
                 min(h.bpm) as lo, max(h.bpm) as hi, count(*) as n
            from public.noop_hr_samples h
           where v_device is not null and h.user_id = p_user and h.device_id = v_device
             and h.ts >= v_pre_a and h.ts < v_post_b and h.bpm between 25 and 250
           group by 1) b;

  -- HRV as the scoring lane published it (canonical, motion-gated buckets), and wrist movement on the same
  -- bins as the heart-rate trace: [t, value, support seconds].
  select coalesce(jsonb_agg(jsonb_build_array(extract(epoch from m.bucket_start)::bigint, round(m.value::numeric, 1),
           m.bucket_seconds) order by m.bucket_start), '[]'::jsonb) into v_hrv_trace
    from public.server_metric_series m
   where m.user_id = p_user and m.metric = 'hrv_rmssd_ms'
     and m.bucket_start >= to_timestamp(v_pre_a) and m.bucket_start < to_timestamp(v_post_b);
  select coalesce(jsonb_agg(jsonb_build_array(b.t, b.v, v_bin) order by b.t), '[]'::jsonb) into v_motion_trace
    from (select v_pre_a + ((g.ts - v_pre_a) / v_bin) * v_bin as t, round(avg(g."dynAccel")::numeric, 4) as v
            from public.noop_gravity_samples g
           where v_device is not null and g.user_id = p_user and g.device_id = v_device
             and g.ts >= v_pre_a and g.ts < v_post_b and g."dynAccel" is not null
           group by 1) b;

  -- How far this device's uploads reach: the context waits until they cover the post window.
  select max(h.ts) into v_through from public.noop_hr_samples h
   where v_device is not null and h.user_id = p_user and h.device_id = v_device and h.ts <= v_now + 300;

  -- Agreement between the logged activity kind and the classifier during the event.
  v_expected := case v_kind
    when 'rest' then array['sitting', 'sitting_desk', 'standing', 'stationary', 'lying_down', 'fidgeting']
    when 'walking' then array['walking', 'brisk_walking']
    when 'running' then array['running']
    when 'cycling' then array['cycling']
    when 'stairs' then array['walking', 'brisk_walking', 'vigorous_activity']
    when 'exercise' then array['light_activity', 'walking', 'brisk_walking', 'running', 'cycling', 'vigorous_activity']
  end;
  if v_expected is null or v_point then
    v_agreement := jsonb_build_object('status', 'not_applicable', 'activity_kind', v_kind);
  elsif coalesce((v_act ->> 'covered_s')::numeric, 0) < 0.5 * (v_during_end - v_start) then
    v_agreement := jsonb_build_object('status', 'insufficient_coverage', 'activity_kind', v_kind,
      'expected_classes', to_jsonb(v_expected));
  else
    select coalesce(sum((c ->> 'seconds')::numeric), 0) / nullif((v_act ->> 'covered_s')::numeric, 0) into v_matched
      from jsonb_array_elements(v_act -> 'classes') c where c ->> 'class' = any (v_expected);
    v_agreement := jsonb_build_object('activity_kind', v_kind, 'expected_classes', to_jsonb(v_expected),
      'matched_share', round(v_matched, 3),
      'status', case when v_matched >= 0.6 then 'agrees' when v_matched >= 0.3 then 'partly' else 'disagrees' end);
  end if;

  -- Personal baselines before the event: the canonical series over the previous 7 days.
  select percentile_cont(0.5) within group (order by m.value), count(*) into v_rest, v_rest_n
    from public.server_metric_series m
   where m.user_id = p_user and m.metric = 'resting_hr_bpm'
     and m.bucket_start >= to_timestamp(v_start) - interval '7 days' and m.bucket_start < to_timestamp(v_start);
  select percentile_cont(0.5) within group (order by m.value), count(*) into v_hrv, v_hrv_n
    from public.server_metric_series m
   where m.user_id = p_user and m.metric = 'hrv_rmssd_ms'
     and m.bucket_start >= to_timestamp(v_start) - interval '7 days' and m.bucket_start < to_timestamp(v_start);

  -- The same event type before this one: how often, and its typical heart rate during the event.
  select jsonb_build_object(
      'type_id', e -> 'typeId',
      'previous_count', count(*),
      'last_start', max((c.entry ->> 'startUnixSeconds')::double precision),
      'typical_hr_during_mean', round(percentile_cont(0.5) within group (
          order by (x.context #>> '{heart_rate,during,mean}')::numeric)::numeric, 1),
      'typical_from', count(x.context #>> '{heart_rate,during,mean}'))
    into v_history
    from (select distinct on (r.entity_id) r.entity_id, r.body -> 'entry' as entry
            from public.manual_event_revisions r
           where r.user_id = p_user and r.entity_id <> p_entity and r.body -> 'entry' ->> 'kind' = 'event'
           order by r.entity_id, r.updated_at_ms desc, r.revision_id desc) c
    left join public.manual_event_contexts x
      on x.user_id = p_user and x.entity_id = c.entity_id and x.status = 'ready'
   where (c.entry ->> 'typeId')::uuid = (e ->> 'typeId')::uuid
     and not coalesce((c.entry ->> 'archived')::boolean, false)
     and (c.entry ->> 'startUnixSeconds')::double precision < v_start;
  v_type_median := (v_history ->> 'typical_hr_during_mean')::numeric;

  if v_hr ? 'mean' and v_hr_pre ? 'mean' then
    v_comparisons := v_comparisons || jsonb_build_object('hr_during_minus_pre_bpm',
      round((v_hr ->> 'mean')::numeric - (v_hr_pre ->> 'mean')::numeric, 1));
  end if;
  if v_hr_post ? 'mean' and v_hr_pre ? 'mean' then
    v_comparisons := v_comparisons || jsonb_build_object('hr_post_minus_pre_bpm',
      round((v_hr_post ->> 'mean')::numeric - (v_hr_pre ->> 'mean')::numeric, 1));
  end if;
  if v_hr ? 'mean' and v_rest is not null then
    v_comparisons := v_comparisons || jsonb_build_object(
      'hr_during_minus_resting_7d_bpm', round((v_hr ->> 'mean')::numeric - v_rest::numeric, 1),
      'hr_during_over_resting_7d', round((v_hr ->> 'mean')::numeric / nullif(v_rest::numeric, 0), 3));
  end if;
  if v_series -> 'hrv_rmssd_ms' ? 'value' and v_hrv is not null then
    v_comparisons := v_comparisons || jsonb_build_object('hrv_during_minus_7d_ms',
      round((v_series #>> '{hrv_rmssd_ms,value}')::numeric - v_hrv::numeric, 1));
  end if;
  if v_hr ? 'mean' and v_type_median is not null then
    v_comparisons := v_comparisons || jsonb_build_object('hr_during_minus_type_typical_bpm',
      round((v_hr ->> 'mean')::numeric - v_type_median, 1));
  end if;

  -- Status: complete data, still arriving, or not enough to say anything.
  if v_device is null then v_missing := v_missing || 'device'::text; end if;
  if coalesce((v_hr_pre ->> 'n')::integer, 0) + coalesce((v_hr ->> 'n')::integer, 0)
     + coalesce((v_hr_post ->> 'n')::integer, 0) = 0 then v_missing := v_missing || 'heart_rate'::text; end if;
  if coalesce((v_act ->> 'covered_s')::integer, 0) + coalesce((v_act_pre ->> 'covered_s')::integer, 0) = 0 then
    v_missing := v_missing || 'activity'::text;
  end if;
  v_status := case
    when v_running then 'running'
    when v_now < v_post_b then 'awaiting_data'
    when (v_through is null or v_through < v_post_b - 120) and v_now < v_post_b + v_settle then 'awaiting_data'
    when 'heart_rate' = any (v_missing) and 'activity' = any (v_missing) then 'insufficient_data'
    else 'ready' end;

  return jsonb_build_object(
    'version', 'manual-event-context-1',
    'status', v_status,
    'final', v_status in ('ready', 'insufficient_data') and v_now > v_post_b + v_settle,
    'computed_at', v_now,
    'event', jsonb_build_object('id', p_entity, 'revision_id', cur.revision_id, 'type_id', e -> 'typeId',
      'label', e -> 'label', 'activity_kind', v_kind, 'start', v_start, 'end', v_end,
      'duration_s', case when v_end is null then null else v_end - v_start end,
      'running', v_running, 'point', v_point, 'archived', coalesce((e ->> 'archived')::boolean, false),
      'time_zone', v_zone, 'local_day', v_day),
    'device', jsonb_build_object('id', v_device, 'resolution', v_resolution),
    'windows', jsonb_build_object('pre', jsonb_build_array(v_pre_a, v_start),
      'during', case when v_point then null else jsonb_build_array(v_start, v_during_end) end,
      'post', case when v_running then null else jsonb_build_array(coalesce(v_end, v_during_end), v_post_b) end,
      'padding_s', v_pad, 'during_truncated', v_truncated),
    'heart_rate', jsonb_build_object('pre', v_hr_pre, 'during', v_hr, 'post', v_hr_post,
      'trace', jsonb_build_object('bin_s', v_bin, 'columns', jsonb_build_array('t', 'mean', 'min', 'max', 'n'),
                                  'bins', v_trace)),
    'traces', jsonb_build_object('columns', jsonb_build_array('t', 'value', 'support_s'),
      'hrv_rmssd_ms', v_hrv_trace, 'movement_g', v_motion_trace),
    'motion', jsonb_build_object(
      'pre', public.manual_event_motion_stats_v1(p_user, v_device, v_pre_a, v_start),
      'during', case when v_point then null else public.manual_event_motion_stats_v1(p_user, v_device, v_start, v_during_end) end,
      'post', case when v_running then null
                   else public.manual_event_motion_stats_v1(p_user, v_device, coalesce(v_end, v_during_end), v_post_b) end),
    'series', jsonb_build_object('pre', v_series_pre, 'during', v_series, 'post', v_series_post),
    'activity', jsonb_build_object('pre', v_act_pre, 'during', v_act, 'post', v_act_post, 'agreement', v_agreement),
    'wear', jsonb_build_object(
      -- Stored kinds carry the strap's code, e.g. 'WRIST_OFF(10)'; match the prefix as physiology SQL does.
      'events', (select coalesce(jsonb_agg(jsonb_build_object('ts', w.ts, 'kind', w.kind) order by w.ts), '[]'::jsonb)
                   from (select ev.ts, case when left(ev.kind, 9) = 'WRIST_OFF' then 'WRIST_OFF' else 'WRIST_ON' end as kind
                           from public.noop_events ev
                          where v_device is not null and ev.user_id = p_user and ev.device_id = v_device
                            and ev.ts >= v_pre_a and ev.ts < v_post_b
                            and (left(ev.kind, 9) = 'WRIST_OFF' or left(ev.kind, 8) = 'WRIST_ON')
                          order by ev.ts limit 50) w),
      'placement', (select p.placement from public.placement_intervals p
                     where p.owner = p_user and (p.device_id is null or p.device_id = v_device)
                       and p.effective_start <= to_timestamp(v_start)
                       and (p.effective_end is null or p.effective_end > to_timestamp(v_start))
                     order by (p.device_id is null), p.effective_start desc, p.revision desc limit 1)),
    'sleep', (select coalesce(jsonb_agg(jsonb_build_object('start', extract(epoch from n.start_at)::bigint,
                'end', extract(epoch from n.end_at)::bigint, 'is_nap', n.is_nap) order by n.start_at), '[]'::jsonb)
                from (select distinct on (s.start_at) s.start_at, s.end_at, s.is_nap from public.server_sleep_nights s
                       where s.user_id = p_user and s.start_at < to_timestamp(v_post_b) and s.end_at > to_timestamp(v_pre_a)
                       order by s.start_at, s.computed_at desc limit 5) n),
    'baselines', jsonb_build_object(
      'resting_hr_7d', case when v_rest_n > 0 then jsonb_build_object('value', round(v_rest::numeric, 1),
                         'buckets', v_rest_n, 'metric', 'resting_hr_bpm') end,
      'hrv_rmssd_7d', case when v_hrv_n > 0 then jsonb_build_object('value', round(v_hrv::numeric, 1),
                        'buckets', v_hrv_n, 'metric', 'hrv_rmssd_ms') end,
      'references', (select coalesce(jsonb_agg(jsonb_build_object('series_key', f.series_key, 'regime_key', f.regime_key,
                       'center', f.center, 'scale', f.scale, 'transform', f.transform, 'from_day', f.from_day,
                       'to_day', f.to_day, 'support_days', f.support_days, 'version', f.version)
                       order by f.series_key, f.regime_key), '[]'::jsonb)
                       from (select distinct on (r.series_key, r.regime_key) r.*
                               from public.physiology_context_frozen_references r
                              where v_device is not null and r.user_id = p_user and r.device_id = v_device
                                and r.to_day < v_day
                              order by r.series_key, r.regime_key, r.to_day desc, r.version desc) f),
      'episodes', (select coalesce(jsonb_agg(jsonb_build_object('series_key', x.series_key, 'regime_key', x.regime_key,
                     'state', x.state, 'direction', x.direction, 'start_day', x.start_day, 'last_day', x.last_day,
                     'finality', x.finality) order by x.series_key), '[]'::jsonb)
                     from (select distinct on (p.series_key, p.regime_key) p.*
                             from public.physiology_context_episodes p
                            where v_device is not null and p.user_id = p_user and p.device_id = v_device
                              and p.start_day <= v_day and p.last_day >= v_day and p.state <> 'usual_variation'
                            order by p.series_key, p.regime_key, (p.mode = 'retrospective') desc, p.as_of_day desc) x)),
    'comparisons', v_comparisons,
    'watchdog', (select coalesce(jsonb_agg(jsonb_build_object('start', extract(epoch from a.start_ts)::bigint,
                   'end', extract(epoch from a.end_ts)::bigint, 'channels', to_jsonb(a.channels),
                   'severity', a.severity, 'direction', a.direction, 'score', round(a.score::numeric, 3),
                   'status', a.status) order by a.start_ts), '[]'::jsonb)
                   from (select * from public.anomaly_candidates c
                          where c.user_id = p_user and (v_device is null or c.device_id = v_device)
                            and c.status <> 'retracted'
                            and c.start_ts < to_timestamp(v_post_b) and c.end_ts > to_timestamp(v_pre_a)
                          order by c.start_ts limit 20) a),
    'exposures', (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'label', x.label,
                    'start', x.occurred_start, 'end', x.occurred_end, 'offset_s', x.occurred_start - v_start,
                    'time_precision', x.time_precision) order by x.occurred_start), '[]'::jsonb)
                    from (select * from public.exposure_events x
                           where x.owner = p_user and x.confirmation = 'confirmed'
                             and x.occurred_start < coalesce(v_end, v_during_end) + 3600
                             and x.occurred_end > v_start - 6 * 3600
                           order by x.occurred_start limit 20) x),
    'concurrent_events', (select coalesce(jsonb_agg(jsonb_build_object('id', k.entity_id, 'label', k.entry -> 'label',
                            'start', k.entry -> 'startUnixSeconds', 'end', k.entry -> 'endUnixSeconds')
                            order by (k.entry ->> 'startUnixSeconds')::double precision), '[]'::jsonb)
                            from (select o.* from (select distinct on (r.entity_id) r.entity_id, r.body -> 'entry' as entry
                                    from public.manual_event_revisions r
                                   where r.user_id = p_user and r.entity_id <> p_entity
                                     and r.body -> 'entry' ->> 'kind' = 'event'
                                   order by r.entity_id, r.updated_at_ms desc, r.revision_id desc) o
                           where not coalesce((o.entry ->> 'archived')::boolean, false)
                             and (o.entry ->> 'startUnixSeconds')::double precision < coalesce(v_end, v_during_end)
                             and coalesce((o.entry ->> 'endUnixSeconds')::double precision, v_now) > v_start
                           order by (o.entry ->> 'startUnixSeconds')::double precision limit 20) k),
    'history', v_history,
    'projections', (select coalesce(jsonb_object_agg(p.target, jsonb_build_object('status', p.status,
                      'reason', p.reason, 'label_key', p.label_key)), '{}'::jsonb)
                      from public.manual_event_projections p where p.user_id = p_user and p.entity_id = p_entity),
    'quality', jsonb_build_object('data_through', v_through, 'missing', to_jsonb(v_missing),
      'hr_coverage_during', v_hr -> 'coverage', 'activity_coverage_during', v_act -> 'coverage'));
end $$;

-- Read-through cache: a stored context is reused while it is final, or younger than p_max_age_seconds and
-- built from the event's current revision; anything else is rebuilt and stored. Unknown ids are skipped.
create or replace function public.manual_event_contexts_v1(p_user uuid, p_ids uuid[], p_max_age_seconds integer default 300)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_out jsonb := '[]'::jsonb;
  v_ctx jsonb;
  v_row public.manual_event_contexts;
  v_rev uuid;
begin
  if p_user is null or p_ids is null or cardinality(p_ids) > 25 then
    raise exception 'invalid_manual_event_context_request' using errcode = '22023';
  end if;
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  for v_id in select distinct x from unnest(p_ids) x loop
    select c.revision_id into v_rev from public.manual_event_current_v1(p_user, v_id) c;
    if v_rev is null then continue; end if;
    select * into v_row from public.manual_event_contexts c where c.user_id = p_user and c.entity_id = v_id;
    if found and v_row.revision_id = v_rev
       and (v_row.final or v_row.computed_at > clock_timestamp() - make_interval(secs => greatest(0, p_max_age_seconds))) then
      v_out := v_out || jsonb_build_array(v_row.context);
      continue;
    end if;
    -- One event that cannot be built (bad stored data, an oversized document) never fails the others.
    begin
      v_ctx := public.manual_event_context_build_v1(p_user, v_id);
      if v_ctx is null then continue; end if;
      if octet_length(v_ctx::text) > 131072 then raise exception 'manual_event_context_too_large'; end if;
    exception when others then
      raise warning 'manual event context % not built: %', v_id, sqlerrm;
      continue;
    end;
    insert into public.manual_event_contexts as c (user_id, entity_id, revision_id, context_version, status, final,
      device_id, computed_at, context)
    values (p_user, v_id, v_rev, v_ctx ->> 'version', v_ctx ->> 'status', (v_ctx ->> 'final')::boolean,
      (v_ctx #>> '{device,id}')::uuid, clock_timestamp(), v_ctx)
    on conflict (user_id, entity_id) do update set revision_id = excluded.revision_id,
      context_version = excluded.context_version, status = excluded.status, final = excluded.final,
      device_id = excluded.device_id, computed_at = excluded.computed_at, context = excluded.context;
    v_out := v_out || jsonb_build_array(v_ctx);
  end loop;
  return jsonb_build_object('contexts', v_out);
end $$;

-- Background refresh (pg_cron): events revised in the last 14 days (manual_event_revisions_recent) whose
-- context is missing or from an older revision, plus stored contexts that are not final and older than
-- 10 minutes (manual_event_contexts_refresh). Ended and unarchived only, newest first, bounded. Each event is
-- built on its own (manual_event_contexts_v1), so one that fails never holds back the rest.
create index if not exists manual_event_revisions_recent on public.manual_event_revisions (updated_at_ms);

create or replace function public.refresh_manual_event_contexts_v1(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_done integer := 0;
  v_cutoff_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint - 14 * 86400 * 1000;
begin
  for r in
    with candidates as (
      select distinct x.user_id, x.entity_id from public.manual_event_revisions x
       where x.updated_at_ms >= v_cutoff_ms and x.body -> 'entry' ->> 'kind' = 'event'
      union
      select c.user_id, c.entity_id from public.manual_event_contexts c
       where not c.final and c.computed_at < clock_timestamp() - interval '10 minutes'
    )
    select k.user_id, k.entity_id, (cur.entry ->> 'endUnixSeconds')::double precision as ended
      from candidates k
      cross join lateral public.manual_event_current_v1(k.user_id, k.entity_id) cur
      left join public.manual_event_contexts c on c.user_id = k.user_id and c.entity_id = k.entity_id
     where cur.entry ->> 'kind' = 'event'
       and cur.entry ->> 'endUnixSeconds' is not null
       and not coalesce((cur.entry ->> 'archived')::boolean, false)
       and (c.entity_id is null or c.revision_id <> cur.revision_id
            or (not c.final and c.computed_at < clock_timestamp() - interval '10 minutes'))
     order by 3 desc
     limit greatest(1, least(p_limit, 500))
  loop
    perform public.manual_event_contexts_v1(r.user_id, array[r.entity_id], 0);
    v_done := v_done + 1;
  end loop;
  return v_done;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 6. Privileges and schedule
-- ---------------------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.manual_event_current_v1(uuid, uuid)',
    'public.manual_event_activity_kind_v1(uuid, jsonb)',
    'public.manual_event_device_v1(uuid, uuid, jsonb, bigint, bigint)',
    'public.project_manual_event_v1(uuid, uuid)',
    'public.manual_event_hr_stats_v1(uuid, uuid, bigint, bigint)',
    'public.manual_event_motion_stats_v1(uuid, uuid, bigint, bigint)',
    'public.manual_event_series_stats_v1(uuid, bigint, bigint)',
    'public.manual_event_activity_stats_v1(uuid, uuid, bigint, bigint)',
    'public.manual_event_context_build_v1(uuid, uuid)',
    'public.manual_event_contexts_v1(uuid, uuid[], integer)',
    'public.refresh_manual_event_contexts_v1(integer)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke all on function public.append_manual_event_revisions(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.append_manual_event_revisions(uuid, uuid, jsonb) to service_role;

-- Revisions already stored by part 1 get their projection now (a no-op on a fresh database).
do $$
declare r record;
begin
  for r in select distinct m.user_id, m.entity_id from public.manual_event_revisions m
            where m.body -> 'entry' ->> 'kind' = 'event' loop
    perform public.project_manual_event_v1(r.user_id, r.entity_id);
  end loop;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'nara-manual-event-context') then
    perform cron.unschedule('nara-manual-event-context');
  end if;
  perform cron.schedule('nara-manual-event-context', '*/10 * * * *',
    'select public.refresh_manual_event_contexts_v1(100)');
end $$;

comment on table public.manual_event_contexts is
  'One manual-event-context-1 document per logged event: pre/during/post heart rate, motion, canonical server series, activity classes with confidence, wear, sleep, Watchdog candidates, exposures, baselines and same-type history. Rebuilt while it can change; final 72 h after the post window. Written only by manual_event_contexts_v1.';
comment on table public.manual_event_projections is
  'Where each manual event was projected (activity_ground_truth) and why not when it was skipped or removed.';

commit;
