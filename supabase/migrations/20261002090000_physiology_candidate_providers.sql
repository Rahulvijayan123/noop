-- Candidate provider lane for the server-side physiology migration (spec 4/6/7).
-- Additive only: no existing table, trigger, function, default or published result is changed.
-- The lane ships dormant: every metric default is mode='off', so no candidate is computed,
-- no candidate row is written and the staleness trigger performs no work until an operator
-- selects a provider (spec 7: do not change live production defaults).
--
-- Three new gaps are closed here, reusing the existing canonical lane rather than replacing it:
--   1. public.physiology_candidate_results  - an interval-granular provider result that can carry
--      status/withheld reason/stages/coverage/diagnostics and an explicit publication mode.
--      physiology_model_results cannot: it is CHECK-forced to shadow and keyed by job_id.
--   2. public.physiology_provider_defaults / physiology_provider_overrides and
--      physiology_selected_provider() - the per-metric off/shadow/active tri-state with an
--      optional per-user override. physiology_feature_defaults has no mode. 'active' is gated on
--      a live signed promotion approval (see physiology_candidate_activation below).
--   3. public.physiology_backfill_jobs + claim/advance/finish - a bounded, resumable,
--      dry-run-capable backfill and rollback job with a lease, a cursor and progress jsonb.
--      Canonical recomputation is delegated to the existing enqueue_scoring_v2.
--
-- Candidate staleness is a THIRD, independent trigger family (physiology_candidate_debt). It
-- listens to the same stream inserts as invalidate_scoring_stream_v2 and scoring_dirty_projection
-- and never touches scoring_invalidations_v2, so a shadow run cannot drive canonical publication.
-- Its per-table time columns are mapped explicitly and verified at migration time, because a
-- wrong column name would make the trigger a silent no-op (noop_event_labels is start_ts/end_ts,
-- not ts). A row whose device_id is NULL (sessions.device_id is ON DELETE SET NULL;
-- noop_event_labels.device_id is nullable) is expanded to every device of its owner, matching
-- scoring_dirty_projection; when the owner has no device at all one NULL-device debt row is
-- recorded instead and physiology_candidate_debt_read reports it for every device.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- ---------------------------------------------------------------------------
-- 1. Candidate results (service-role only; RLS enabled with no client policy)
-- ---------------------------------------------------------------------------
create table if not exists public.physiology_candidate_results (
  candidate_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  metric text not null check (metric in ('hrv','sleep_boundary','sleep_stage','respiration')),
  period_day date not null,
  interval_start_at timestamptz not null,
  interval_end_at timestamptz not null,
  input_sha256 text not null,
  provider_id text not null,
  provider_version text not null,
  adapter_version text not null,
  preprocessing_version text not null,
  config_version text not null,
  dependency_versions jsonb not null default '{}'::jsonb,
  status text not null check (status in ('ok','withheld','error')),
  withheld_reason text,
  value numeric,
  unit text,
  stages jsonb,
  label_space text,
  coverage jsonb,
  diagnostics jsonb,
  runtime_ms integer,
  created_at timestamptz not null default now(),
  unique (user_id, device_id, metric, period_day, interval_start_at, input_sha256,
    provider_id, provider_version, config_version)
);
create index if not exists physiology_candidate_results_day_idx
  on public.physiology_candidate_results (user_id, device_id, metric, period_day, interval_start_at);
create index if not exists physiology_candidate_results_provider_idx
  on public.physiology_candidate_results (metric, provider_id, provider_version, period_day);

comment on table public.physiology_candidate_results is
  'Isolated provider candidates. A shadow or active result never replaces a canonical daily/session value.';
comment on column public.physiology_candidate_results.input_sha256 is
  'Hash of the validated input snapshot the provider consumed; part of the replay dedup key.';
comment on column public.physiology_candidate_results.withheld_reason is
  'Machine-readable reason from the sidecar contract; null only when status=''ok''.';

-- ---------------------------------------------------------------------------
-- 2. Per-metric provider selection (off / shadow / active)
-- ---------------------------------------------------------------------------
create table if not exists public.physiology_provider_defaults (
  metric text primary key check (metric in ('hrv','sleep_boundary','sleep_stage','respiration')),
  provider_id text not null,
  provider_version text not null,
  config_version text not null,
  mode text not null default 'off' check (mode in ('off','shadow','active')),
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists public.physiology_provider_overrides (
  user_id uuid not null references auth.users(id) on delete cascade,
  metric text not null check (metric in ('hrv','sleep_boundary','sleep_stage','respiration')),
  provider_id text not null,
  provider_version text not null,
  config_version text not null,
  mode text not null check (mode in ('off','shadow','active')),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, metric)
);

-- Seeded off, and never re-seeded over an operator change.
insert into public.physiology_provider_defaults(metric,provider_id,provider_version,config_version,mode)
values ('hrv','none','none','none','off'),
       ('sleep_boundary','none','none','none','off'),
       ('sleep_stage','none','none','none','off'),
       ('respiration','none','none','none','off')
on conflict (metric) do nothing;

comment on table public.physiology_provider_defaults is
  'Fleet default provider and mode per metric. Ships mode=off for every metric.';
comment on table public.physiology_provider_overrides is
  'Optional per-user provider and mode. Beats the fleet default for that metric.';

-- One metric maps onto one signed-promotion feature. sleep_boundary and sleep_stage share the
-- existing 'sleep' feature because that is the only sleep family the promotion table can express.
create or replace function public.physiology_candidate_feature(p_metric text)
returns text language sql immutable set search_path='' as $$
  select case p_metric
    when 'hrv' then 'hrv'
    when 'sleep_boundary' then 'sleep'
    when 'sleep_stage' then 'sleep'
    when 'respiration' then 'respiration'
  end
$$;

-- The promotion gate. 'active' is the only mode that can reach canonical publication, so an
-- active selection additionally requires a live signed promotion approval for the selected
-- provider version. The approval is matched on (feature, algorithm_version): the existing
-- physiology_promotion_approvals table is fleet-wide and has no user, provider_id or
-- config_version column, and its foreign key to physiology_feature_manifests binds the approved
-- algorithm_version to one manifest (checkpoint, preprocessing and quality-policy hashes).
-- Liveness is the repository's own check, internal.physiology_approval_valid(): signature over
-- the exact payload, manifest identity, payload gates, an unrevoked signing key and no
-- revocation row. A demoted metric is reported as mode='shadow' with a machine-readable reason,
-- so a worker never treats an unapproved provider as active.
create or replace function public.physiology_candidate_activation(p_user uuid, p_metric text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  o public.physiology_provider_overrides; d public.physiology_provider_defaults;
  a public.physiology_promotion_approvals; m public.physiology_feature_manifests;
  requested text; src text; pid text; pver text; cver text; v_feature text;
  approved boolean:=false; reason text:=null;
begin
  if p_metric is null or p_metric not in ('hrv','sleep_boundary','sleep_stage','respiration') then
    raise exception 'invalid_candidate_metric' using errcode='22023';
  end if;
  v_feature:=public.physiology_candidate_feature(p_metric);
  -- A per-user override beats the fleet default for that metric.
  if p_user is not null then
    select * into o from public.physiology_provider_overrides
      where user_id=p_user and metric=p_metric;
    if found then
      requested:=o.mode; src:='user_override';
      pid:=o.provider_id; pver:=o.provider_version; cver:=o.config_version;
    end if;
  end if;
  if requested is null then
    select * into d from public.physiology_provider_defaults where metric=p_metric;
    if found then
      requested:=d.mode; src:='default';
      pid:=d.provider_id; pver:=d.provider_version; cver:=d.config_version;
    else
      requested:='off'; src:='unset';
    end if;
  end if;
  if requested='active' then
    if to_regclass('public.physiology_promotion_approvals') is null
      or to_regclass('internal.physiology_approval_keys') is null
      or not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='internal' and p.proname='physiology_approval_valid') then
      -- Fail closed: without the signed-promotion machinery nothing may run as active.
      reason:='promotion_gate_unavailable';
    else
      -- Any live approval for this feature and provider version satisfies the gate. The set is
      -- tiny (one row per signed release) and bounded here for safety.
      for a in select * from public.physiology_promotion_approvals ap
        where ap.feature=v_feature and ap.algorithm_version=pver
        order by ap.created_at desc, ap.approval_id limit 32
      loop
        if internal.physiology_approval_valid(a) then approved:=true; exit; end if;
      end loop;
      if approved then
        select * into m from public.physiology_feature_manifests fm
          where fm.algorithm_version=a.algorithm_version and fm.feature=a.feature;
      else
        reason:='promotion_approval_required';
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'mode',case when requested='active' and not approved then 'shadow' else requested end,
    'requested_mode',requested,
    'source',case when requested='active' and not approved then src||'_demoted_unapproved' else src end,
    'demoted',(requested='active' and not approved),
    'provider_id',pid,'provider_version',pver,'config_version',cver,
    'feature',v_feature,
    'approval',jsonb_build_object('approved',approved,'reason',reason,
      'approval_id',case when approved then to_jsonb(a.approval_id) end,
      'preprocessing_version',case when approved then to_jsonb(m.preprocessing_version) end,
      'quality_policy_version',case when approved then to_jsonb(m.quality_policy_version) end));
end $$;

-- Selection as the worker sees it: the effective mode after the promotion gate.
create or replace function public.physiology_selected_provider(p_user uuid, p_metric text)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare act jsonb;
begin
  act:=public.physiology_candidate_activation(p_user,p_metric);
  return jsonb_build_object('provider_id',act->'provider_id','provider_version',act->'provider_version',
    'config_version',act->'config_version','mode',act->>'mode','source',act->>'source');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Candidate staleness: a third, independent trigger family
-- ---------------------------------------------------------------------------
create table if not exists public.physiology_candidate_debt (
  user_id uuid not null references auth.users(id) on delete cascade,
  -- A device-less change whose owner has no device is recorded once as device_id=''. A sentinel is
  -- used instead of NULL because device_id is part of the primary key and PostgreSQL cannot drop
  -- NOT NULL on a key column. Real device ids are UUID strings, so '' cannot collide with one.
  device_id text not null,
  day date not null,
  invalidated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, day)
);
-- The primary key dedups the any-device row ('') exactly like a real device row.

comment on table public.physiology_candidate_debt is
  'Newest input change per user/device/day for the candidate lane. The worker skips a candidate '
  'write whose claim is older than invalidated_at. Never drives canonical publication. A '
  'device_id='''' row is debt for every device of that owner.';

create or replace function public.physiology_candidate_dirty() returns trigger
language plpgsql security definer set search_path='' as $$
declare r record; d date; query text; source_sql text; ts_field text:=TG_ARGV[0]; span_end date;
begin
  -- Dormant lane: with every metric off this trigger returns immediately and costs one scan.
  if not exists(select 1 from public.physiology_provider_defaults where mode<>'off'
      union all select 1 from public.physiology_provider_overrides where mode<>'off') then
    return null;
  end if;
  -- Transport metadata alone is replay, exactly as in invalidate_scoring_stream_v2.
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] as b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) as b from new_rows n';
  else source_sql:='select to_jsonb(o) as b from old_rows o'; end if;
  query:='select distinct (b->>''user_id'')::uuid as u,(b->>''device_id'')::uuid as dev,
    public.scoring_local_day_v2(b->>'||quote_literal(ts_field)||',p.timezone) as day,
    public.scoring_local_day_v2(coalesce(b->>'||quote_literal(coalesce(TG_ARGV[1],ts_field))||',b->>'||quote_literal(ts_field)||'),p.timezone) as through_day
    from ('||source_sql||') changed join public.profiles p on p.id=(b->>''user_id'')::uuid order by u,dev,day';
  for r in execute query loop
    if r.u is null or r.day is null then continue; end if;
    if r.dev is not null and not exists(select 1 from public.devices where id=r.dev and user_id=r.u) then
      continue;
    end if;
    -- The candidate reader shares the canonical "+2 wake days" reach; the span is capped so one
    -- pathological backfill cannot expand into unbounded debt rows.
    span_end:=least(coalesce(r.through_day,r.day)+2,r.day+10);
    for d in select generate_series(r.day,span_end,interval '1 day')::date loop
      if r.dev is not null then
        insert into public.physiology_candidate_debt(user_id,device_id,day,invalidated_at)
          values(r.u,r.dev::text,d,clock_timestamp())
          on conflict (user_id,device_id,day) do update set invalidated_at=excluded.invalidated_at;
      elsif exists(select 1 from public.devices dv where dv.user_id=r.u) then
        -- A device-less row applies to every device of the owner, matching scoring_dirty_projection.
        insert into public.physiology_candidate_debt(user_id,device_id,day,invalidated_at)
        select r.u, dv.id::text, d, clock_timestamp()
          from public.devices dv where dv.user_id=r.u
        on conflict (user_id,device_id,day) do update set invalidated_at=excluded.invalidated_at;
      else
        -- No device to fan out to: one any-device row (''), read as debt for every device.
        insert into public.physiology_candidate_debt(user_id,device_id,day,invalidated_at)
          values(r.u,'',d,clock_timestamp())
          on conflict (user_id,device_id,day) do update set invalidated_at=excluded.invalidated_at;
      end if;
    end loop;
  end loop;
  return null;
end $$;

do $$
declare t text; ts_col text; end_col text; missing text;
begin
  if to_regprocedure('public.scoring_local_day_v2(text,text)') is null then
    raise notice 'physiology_candidate_providers: scoring_local_day_v2 absent; candidate staleness triggers not attached';
    return;
  end if;
  -- Table-driven mapping of the ACTUAL start/end time column of each covered stream. Ten
  -- epoch-second scalar streams carry ts; noop_event_labels and noop_signal_windows carry
  -- start_ts/end_ts; sessions carries start_at/end_at. The mapping is verified below, because a
  -- wrong name would silently drop staleness debt instead of failing.
  for t, ts_col, end_col in
    select * from (values
      ('noop_hr_samples','ts','ts'),
      ('noop_rr_intervals','ts','ts'),
      ('noop_resp_samples','ts','ts'),
      ('noop_gravity_samples','ts','ts'),
      ('noop_events','ts','ts'),
      ('noop_step_samples','ts','ts'),
      ('noop_skin_temp_samples','ts','ts'),
      ('noop_spo2_samples','ts','ts'),
      ('noop_sleep_state_samples','ts','ts'),
      ('noop_ppg_hr_samples','ts','ts'),
      ('noop_event_labels','start_ts','end_ts'),
      ('noop_signal_windows','start_ts','end_ts'),
      ('sessions','start_at','end_at')
    ) mapped(table_name,start_column,end_column)
  loop
    if to_regclass('public.'||t) is null then continue; end if;
    select string_agg(v.c,',' order by v.c) into missing
      from (values (ts_col),(end_col)) v(c)
     where not exists(select 1 from pg_attribute a
        where a.attrelid=to_regclass('public.'||t) and a.attname=v.c
          and a.attnum>0 and not a.attisdropped);
    if missing is not null then
      raise exception 'physiology_candidate_trigger_column_missing' using errcode='22023',
        detail=format('%s lacks %s',t,missing);
    end if;
    execute format('drop trigger if exists physiology_candidate_insert on public.%I',t);
    execute format('drop trigger if exists physiology_candidate_update on public.%I',t);
    execute format('drop trigger if exists physiology_candidate_delete on public.%I',t);
    execute format('create trigger physiology_candidate_insert after insert on public.%I referencing new table as new_rows for each statement execute function public.physiology_candidate_dirty(%L,%L)',t,ts_col,end_col);
    execute format('create trigger physiology_candidate_update after update on public.%I referencing old table as old_rows new table as new_rows for each statement execute function public.physiology_candidate_dirty(%L,%L)',t,ts_col,end_col);
    execute format('create trigger physiology_candidate_delete after delete on public.%I referencing old table as old_rows for each statement execute function public.physiology_candidate_dirty(%L,%L)',t,ts_col,end_col);
  end loop;
end $$;

create or replace function public.physiology_candidate_debt_read(p_user uuid, p_device text, p_day date)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(
    (select jsonb_build_object('debt',true,'invalidated_at',max(d.invalidated_at))
       from public.physiology_candidate_debt d
      where d.user_id=p_user and d.day=p_day
        -- '' is the any-device row; a NULL device_id is also honoured so the read stays correct
        -- if the column is ever made nullable.
        and (d.device_id='' or d.device_id is null or d.device_id=p_device)
      having count(*)>0),
    jsonb_build_object('debt',false,'invalidated_at',null))
$$;

-- ---------------------------------------------------------------------------
-- 4. Candidate write RPC
-- ---------------------------------------------------------------------------
-- Epoch-or-timestamp text to timestamptz, NULL when it is neither. Used only by the stage
-- element bounds below, so an unparseable epoch becomes a named rejection, not a cast error.
create or replace function public.physiology_candidate_stage_at(p_value text)
returns timestamptz language plpgsql immutable set search_path='' as $$
begin
  if p_value is null or p_value='' then return null; end if;
  if p_value ~ '^-?[0-9]+(\.[0-9]+)?$' then return to_timestamp(p_value::double precision); end if;
  begin
    return p_value::timestamptz;
  exception when others then return null;
  end;
end $$;

create or replace function public.physiology_record_candidate_result(
  p_user uuid,
  p_device text,
  p_metric text,
  p_period_day date,
  p_interval_start_at timestamptz,
  p_interval_end_at timestamptz,
  p_input_sha256 text,
  p_input_revision bigint,
  p_provider_id text,
  p_provider_version text,
  p_adapter_version text,
  p_preprocessing_version text,
  p_config_version text,
  p_status text,
  p_dependency_versions jsonb default '{}'::jsonb,
  p_withheld_reason text default null,
  p_value numeric default null,
  p_unit text default null,
  p_stages jsonb default null,
  p_label_space text default null,
  p_coverage jsonb default null,
  p_diagnostics jsonb default null,
  p_runtime_ms integer default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare
  act jsonb; v_current bigint; v_id uuid;
  v_reasons text[]:=array['blocked_input','blocked_artifact','blocked_license','unverified',
    'insufficient_coverage','artifact_fraction','provider_error','timeout','not_ready'];
begin
  -- Shape. A malformed candidate is a caller defect and raises; a failed guard returns null.
  if p_metric is null or p_metric not in ('hrv','sleep_boundary','sleep_stage','respiration') then
    raise exception 'invalid_candidate_metric' using errcode='22023';
  end if;
  if p_status is null or p_status not in ('ok','withheld','error') then
    raise exception 'invalid_candidate_status' using errcode='22023';
  end if;
  if p_user is null or p_device is null or p_device='' or p_period_day is null
    or p_interval_start_at is null or p_interval_end_at is null
    or p_interval_end_at<=p_interval_start_at then
    raise exception 'invalid_candidate_interval' using errcode='22023';
  end if;
  if p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'invalid_candidate_input_hash' using errcode='22023';
  end if;
  if p_input_revision is null or p_input_revision<1 then
    raise exception 'invalid_candidate_input_revision' using errcode='22023';
  end if;
  if p_provider_id is null or p_provider_id='' or p_provider_version is null or p_provider_version=''
    or p_adapter_version is null or p_adapter_version='' or p_preprocessing_version is null
    or p_preprocessing_version='' or p_config_version is null or p_config_version='' then
    raise exception 'invalid_candidate_provider' using errcode='22023';
  end if;
  if coalesce(jsonb_typeof(p_dependency_versions),'null')<>'object' then
    raise exception 'invalid_candidate_dependencies' using errcode='22023';
  end if;
  if p_coverage is not null and jsonb_typeof(p_coverage)<>'object' then
    raise exception 'invalid_candidate_coverage' using errcode='22023';
  end if;
  if p_diagnostics is not null and jsonb_typeof(p_diagnostics)<>'object' then
    raise exception 'invalid_candidate_diagnostics' using errcode='22023';
  end if;
  if p_stages is not null and jsonb_typeof(p_stages)<>'array' then
    raise exception 'invalid_candidate_stages' using errcode='22023';
  end if;
  if p_runtime_ms is not null and p_runtime_ms<0 then
    raise exception 'invalid_candidate_runtime' using errcode='22023';
  end if;
  if p_status='ok' then
    -- Numeric values are null when unavailable; a stage result carries stages instead.
    if p_value is null and p_stages is null then
      raise exception 'invalid_candidate_result' using errcode='22023';
    end if;
    if p_withheld_reason is not null then
      raise exception 'invalid_candidate_result' using errcode='22023';
    end if;
    if p_value is not null and p_unit is null then
      raise exception 'invalid_candidate_unit' using errcode='22023';
    end if;
    if p_stages is not null and p_label_space is null then
      raise exception 'invalid_candidate_label_space' using errcode='22023';
    end if;
  else
    if p_withheld_reason is null then
      raise exception 'invalid_candidate_reason' using errcode='22023';
    end if;
    if p_status='withheld' and not (p_withheld_reason=any(v_reasons)) then
      raise exception 'invalid_candidate_reason' using errcode='22023';
    end if;
    if p_value is not null or p_stages is not null then
      raise exception 'invalid_candidate_result' using errcode='22023';
    end if;
  end if;
  -- Finiteness and metric bounds. numeric admits NaN and Infinity, so compare as text.
  if p_value is not null then
    if p_value::text in ('NaN','Infinity','-Infinity') then
      raise exception 'invalid_candidate_value' using errcode='22023';
    end if;
    if (p_metric='hrv' and p_value not between 0 and 1000)
      or (p_metric='respiration' and p_value not between 4 and 40)
      or (p_metric in ('sleep_boundary','sleep_stage') and p_value not between -1000000000 and 1000000000) then
      raise exception 'candidate_value_out_of_bounds' using errcode='22023';
    end if;
  end if;
  -- Stage element bounds. Additive and cheap: element shape, label membership and non-negative
  -- durations are always checked; epoch bounds are checked whenever the element carries
  -- start_at/end_at (a payload that omits epochs is accepted, because the sidecar's stage element
  -- shape is not fixed by the plan). Overlap is checked in start order.
  if p_stages is not null then
    if exists(select 1 from jsonb_array_elements(p_stages) e where jsonb_typeof(e)<>'object') then
      raise exception 'invalid_candidate_stages' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_stages) e
        where (e ? 'stage') and coalesce(e->>'stage','')='') then
      raise exception 'invalid_candidate_stages' using errcode='22023';
    end if;
    if p_label_space is not null and exists(select 1 from jsonb_array_elements(p_stages) e
        where (e ? 'stage') and coalesce(e->>'stage','')<>''
          and strpos(p_label_space,coalesce(e->>'stage',''))=0) then
      raise exception 'invalid_candidate_stage_label' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_stages) e
        where coalesce(e->>'minutes',e->>'duration_seconds',e->>'duration_min') is not null
          and coalesce(e->>'minutes',e->>'duration_seconds',e->>'duration_min')
            !~ '^-?[0-9]+(\.[0-9]+)?$') then
      raise exception 'invalid_candidate_stage_duration' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_stages) e
        where case when coalesce(e->>'minutes',e->>'duration_seconds',e->>'duration_min')
              ~ '^-?[0-9]+(\.[0-9]+)?$'
            then coalesce(e->>'minutes',e->>'duration_seconds',e->>'duration_min')::numeric<0
            else false end) then
      raise exception 'invalid_candidate_stage_duration' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_stages) e
        where (e ? 'start_at' or e ? 'end_at')
          and (public.physiology_candidate_stage_at(e->>'start_at') is null
            or public.physiology_candidate_stage_at(e->>'end_at') is null)) then
      raise exception 'invalid_candidate_stage_epoch' using errcode='22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_stages) e
        where (e ? 'start_at' and e ? 'end_at')
          and (public.physiology_candidate_stage_at(e->>'start_at')
                 >= public.physiology_candidate_stage_at(e->>'end_at')
            or public.physiology_candidate_stage_at(e->>'start_at') < p_interval_start_at
            or public.physiology_candidate_stage_at(e->>'end_at') > p_interval_end_at)) then
      raise exception 'invalid_candidate_stage_interval' using errcode='22023';
    end if;
    if exists(
        with ordered as (
          select public.physiology_candidate_stage_at(e->>'start_at') as s,
                 lag(public.physiology_candidate_stage_at(e->>'end_at'))
                   over (order by public.physiology_candidate_stage_at(e->>'start_at')) as prev_end
            from jsonb_array_elements(p_stages) e
           where e ? 'start_at' and e ? 'end_at')
        select 1 from ordered where prev_end is not null and s < prev_end) then
      raise exception 'invalid_candidate_stage_overlap' using errcode='22023';
    end if;
  end if;

  -- Selection. Only shadow or active writes a candidate, and the generation must still be selected.
  -- The requested mode is used here, not the demoted effective mode: a caller that still claims
  -- active for an unapproved provider is refused outright rather than silently downgraded.
  act:=public.physiology_candidate_activation(p_user,p_metric);
  if coalesce(act->>'requested_mode','off') not in ('shadow','active') then return null; end if;
  if act->>'provider_id' is distinct from p_provider_id
    or act->>'provider_version' is distinct from p_provider_version
    or act->>'config_version' is distinct from p_config_version then return null; end if;
  -- Promotion gate: an active write additionally requires a live signed promotion approval.
  -- The reason is readable through physiology_candidate_activation().
  if act->>'requested_mode'='active'
    and coalesce((act->'approval'->>'approved')::boolean,false) is not true then
    return null;
  end if;

  -- Owner isolation and deletion. A deleted user has no candidates and accepts no new ones.
  if not exists(select 1 from auth.users u where u.id=p_user) then return null; end if;
  if not exists(select 1 from public.devices d where d.user_id=p_user and d.id::text=p_device) then
    return null;
  end if;

  -- Current-input-revision guard: a claim computed against an older generation is refused.
  select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
   where j.user_id=p_user and j.day=p_period_day and j.device_id::text=p_device
     and j.algorithm_version=(select algorithm_version from public.scoring_algorithms_v2 where active);
  if v_current is null then
    select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
     where j.user_id=p_user and j.day=p_period_day
       and j.algorithm_version=(select algorithm_version from public.scoring_algorithms_v2 where active);
  end if;
  if v_current is null then
    select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
     where j.user_id=p_user and j.day=p_period_day;
  end if;
  if v_current is not null and p_input_revision<v_current then return null; end if;

  insert into public.physiology_candidate_results(user_id,device_id,metric,period_day,interval_start_at,
    interval_end_at,input_sha256,provider_id,provider_version,adapter_version,preprocessing_version,
    config_version,dependency_versions,status,withheld_reason,value,unit,stages,label_space,coverage,
    diagnostics,runtime_ms)
  values(p_user,p_device,p_metric,p_period_day,p_interval_start_at,p_interval_end_at,p_input_sha256,
    p_provider_id,p_provider_version,p_adapter_version,p_preprocessing_version,p_config_version,
    p_dependency_versions,p_status,p_withheld_reason,p_value,p_unit,p_stages,p_label_space,p_coverage,
    p_diagnostics,p_runtime_ms)
  on conflict (user_id,device_id,metric,period_day,interval_start_at,input_sha256,provider_id,
    provider_version,config_version) do nothing
  returning candidate_id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Bounded, resumable backfill / rollback jobs
-- ---------------------------------------------------------------------------
create table if not exists public.physiology_backfill_jobs (
  job_id uuid primary key default gen_random_uuid(),
  mode text not null check (mode in ('dry_run','apply','rollback')),
  metric text not null check (metric in ('hrv','sleep_boundary','sleep_stage','respiration')),
  from_provider_id text,
  from_provider_version text,
  to_provider_id text not null,
  to_provider_version text not null,
  scope_user uuid references auth.users(id) on delete cascade,
  scope_device text,
  scope_from_day date not null,
  scope_through_day date not null,
  max_users integer not null default 1 check (max_users between 1 and 1000),
  state text not null default 'pending'
    check (state in ('pending','running','paused','complete','failed','cancelled')),
  cursor_user uuid,
  cursor_day date,
  processed_days bigint not null default 0,
  failed_days bigint not null default 0,
  lease_token uuid,
  lease_owner text,
  lease_until timestamptz,
  lease_seconds integer not null default 300,
  attempts integer not null default 0,
  last_error text,
  progress jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (scope_through_day>=scope_from_day),
  check (lease_seconds between 1 and 3600),
  check ((lease_token is null)=(lease_until is null))
);
-- Already-created installations of this table gain the granted lease length additively.
alter table public.physiology_backfill_jobs
  add column if not exists lease_seconds integer not null default 300;
create index if not exists physiology_backfill_jobs_runnable_idx
  on public.physiology_backfill_jobs (state, created_at) where state in ('pending','running');

comment on table public.physiology_backfill_jobs is
  'Operator-driven bounded backfill/rollback. dry_run writes nothing; apply/rollback only enqueue '
  'the existing canonical recompute and fence in-flight candidate writes. max_users bounds the '
  'distinct users one advance call may process; lease_seconds is the lease length granted by claim.';

create or replace function public.physiology_backfill_claim(p_lease_seconds integer default 300,
  p_lease_owner text default null)
returns setof public.physiology_backfill_jobs language plpgsql security definer set search_path='' as $$
begin
  if p_lease_seconds<1 or p_lease_seconds>3600 then
    raise exception 'invalid_lease' using errcode='22023';
  end if;
  return query
  with candidate as (
    select b.job_id from public.physiology_backfill_jobs b
     where b.state in ('pending','running')
       and (b.lease_until is null or b.lease_until<=clock_timestamp())
       -- Never hand out a job whose per-call user bound is not enforceable.
       and b.max_users between 1 and 1000
     order by b.created_at, b.job_id
     for update skip locked limit 1
  )
  update public.physiology_backfill_jobs b set state='running', lease_token=gen_random_uuid(),
    lease_owner=coalesce(p_lease_owner,b.lease_owner),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),
    lease_seconds=p_lease_seconds,
    attempts=b.attempts+1, updated_at=clock_timestamp()
  from candidate c where b.job_id=c.job_id returning b.*;
end $$;

create or replace function public.physiology_backfill_advance(p_job uuid, p_token uuid,
  p_max_days integer default 1, p_error text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  j public.physiology_backfill_jobs; r record; dev record; v_ver text;
  n integer:=0; scanned integer:=0; enq integer:=0; rows integer:=0;
  users_seen integer:=0; prev_user uuid;
  last_user uuid; last_day date; exhausted boolean:=false; capped boolean:=false; total_days bigint;
begin
  if p_max_days is null or p_max_days<1 or p_max_days>400 then
    raise exception 'invalid_backfill_bound' using errcode='22023';
  end if;
  select * into j from public.physiology_backfill_jobs where job_id=p_job for update;
  if not found then raise exception 'unknown_backfill_job' using errcode='22023'; end if;
  if j.lease_token is null or j.lease_token is distinct from p_token
    or j.lease_until is null or j.lease_until<=clock_timestamp() then
    raise exception 'backfill_lease_lost' using errcode='55006';
  end if;
  if j.state<>'running' then raise exception 'backfill_not_running' using errcode='55000'; end if;
  select algorithm_version into v_ver from public.scoring_algorithms_v2 where active;
  last_user:=j.cursor_user;
  last_day:=j.cursor_day;
  -- Bounded: at most p_max_days distinct (user, day) pairs AND at most max_users distinct users
  -- per call, resumed after the cursor.
  for r in
    select distinct s.user_id, s.day
      from public.scoring_jobs_v2 s
     where s.day between j.scope_from_day and j.scope_through_day
       and (j.scope_user is null or s.user_id=j.scope_user)
       and (j.scope_device is null or s.device_id::text=j.scope_device)
       and (last_user is null or s.user_id>last_user
         or (s.user_id=last_user and s.day>coalesce(last_day,j.scope_from_day-1)))
     order by s.user_id, s.day
     limit p_max_days
  loop
    if prev_user is null or r.user_id is distinct from prev_user then
      if users_seen>=j.max_users then capped:=true; exit; end if;
      users_seen:=users_seen+1;
      prev_user:=r.user_id;
    end if;
    scanned:=scanned+1;
    if j.mode<>'dry_run' then
      for dev in
        select s.device_id, s.algorithm_version from public.scoring_jobs_v2 s
         where s.user_id=r.user_id and s.day=r.day
           and (j.scope_device is null or s.device_id::text=j.scope_device)
         order by s.device_id
         limit 64
      loop
        perform public.enqueue_scoring_v2(r.user_id,dev.device_id,r.day,
          coalesce(v_ver,dev.algorithm_version),'physiology_backfill');
        enq:=enq+1;
      end loop;
      rows:=rows+1;
      if j.mode='rollback' then
        -- Fence in-flight candidate writes for the restored days before the canonical recompute lands.
        insert into public.physiology_candidate_debt(user_id,device_id,day,invalidated_at)
        select c.user_id, c.device_id, c.period_day, clock_timestamp()
          from public.physiology_candidate_results c
         where c.user_id=r.user_id and c.period_day=r.day
        on conflict (user_id,device_id,day) do update set invalidated_at=excluded.invalidated_at;
      end if;
    end if;
    last_user:=r.user_id;
    last_day:=r.day;
    n:=n+1;
  end loop;
  exhausted:=(n<p_max_days) and not capped;
  total_days:=j.processed_days+case when j.mode='dry_run' then 0 else rows end;
  update public.physiology_backfill_jobs set
    cursor_user=last_user,
    cursor_day=last_day,
    processed_days=total_days,
    state=case when exhausted then 'complete' else 'running' end,
    lease_token=case when exhausted then null else lease_token end,
    -- Renew with the lease length the claim actually granted, not a fixed constant.
    lease_until=case when exhausted then null
      else clock_timestamp()+make_interval(secs=>j.lease_seconds) end,
    last_error=coalesce(left(p_error,2000),last_error),
    progress=j.progress||jsonb_build_object('mode',j.mode,'dryRun',j.mode='dry_run',
      'scannedDays',coalesce((j.progress->>'scannedDays')::integer,0)+scanned,
      'enqueued',enq,'processedDays',total_days,'usersSeen',users_seen,
      'lastUser',last_user,'lastDay',last_day,'done',exhausted),
    updated_at=clock_timestamp()
  where job_id=p_job;
  return jsonb_build_object('jobId',p_job,'mode',j.mode,
    'state',case when exhausted then 'complete' else 'running' end,
    'scanned',scanned,'enqueued',enq,'cursorUser',last_user,'cursorDay',last_day,'done',exhausted);
end $$;

create or replace function public.physiology_backfill_finish(p_job uuid, p_token uuid, p_state text,
  p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_state is null or p_state not in ('complete','failed','cancelled','paused') then
    raise exception 'invalid_backfill_state' using errcode='22023';
  end if;
  update public.physiology_backfill_jobs set state=p_state, lease_token=null, lease_until=null,
    last_error=left(p_error,2000), updated_at=clock_timestamp()
  where job_id=p_job and lease_token=p_token and lease_until>clock_timestamp();
  return found;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Privileges. RLS is enabled with no policy at all: deny by default for every client role,
-- and the service role reaches the lane with its bypass attribute (same shape as coach_messages).
-- ---------------------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['physiology_candidate_results','physiology_provider_defaults',
    'physiology_provider_overrides','physiology_candidate_debt','physiology_backfill_jobs'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from public, anon, authenticated',t);
    execute format('grant all on table public.%I to service_role',t);
  end loop;
end $$;

revoke all on function public.physiology_selected_provider(uuid,text) from public,anon,authenticated;
grant execute on function public.physiology_selected_provider(uuid,text) to service_role;
revoke all on function public.physiology_candidate_feature(text) from public,anon,authenticated;
grant execute on function public.physiology_candidate_feature(text) to service_role;
revoke all on function public.physiology_candidate_activation(uuid,text) from public,anon,authenticated;
grant execute on function public.physiology_candidate_activation(uuid,text) to service_role;
revoke all on function public.physiology_candidate_stage_at(text) from public,anon,authenticated;
grant execute on function public.physiology_candidate_stage_at(text) to service_role;
revoke all on function public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer) from public,anon,authenticated;
grant execute on function public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer) to service_role;
revoke all on function public.physiology_candidate_debt_read(uuid,text,date) from public,anon,authenticated;
grant execute on function public.physiology_candidate_debt_read(uuid,text,date) to service_role;
revoke all on function public.physiology_candidate_dirty() from public,anon,authenticated;
grant execute on function public.physiology_candidate_dirty() to service_role;
revoke all on function public.physiology_backfill_claim(integer,text) from public,anon,authenticated;
grant execute on function public.physiology_backfill_claim(integer,text) to service_role;
revoke all on function public.physiology_backfill_advance(uuid,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.physiology_backfill_advance(uuid,uuid,integer,text) to service_role;
revoke all on function public.physiology_backfill_finish(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.physiology_backfill_finish(uuid,uuid,text,text) to service_role;

comment on function public.physiology_record_candidate_result is
  'Validated, revision-fenced, idempotent candidate write. Returns the new candidate_id, or null '
  'when the metric is off, the selected generation moved, the claim is stale, the owner is unknown '
  'or deleted, the same candidate was already recorded, or an active write lacks a live signed '
  'promotion approval.';
comment on function public.physiology_selected_provider(uuid,text) is
  'Effective provider and mode for one metric: per-user override beats the fleet default; '
  'an unconfigured metric resolves to mode=off; an active selection without a live signed '
  'promotion approval is demoted to shadow with the demotion named in source.';
comment on function public.physiology_candidate_activation(uuid,text) is
  'Selection plus the promotion gate decision: requested_mode, effective mode, demoted flag, '
  'feature, and an approval object carrying approved/reason/approval_id. Read this to explain a '
  'null candidate write.';
comment on function public.physiology_candidate_feature(text) is
  'Metric to signed-promotion feature map: hrv->hrv, sleep_boundary->sleep, sleep_stage->sleep, '
  'respiration->respiration.';
comment on function public.physiology_candidate_debt_read(uuid,text,date) is
  'Staleness debt for one user/device/day. An any-device row (device_id='''') counts as debt for '
  'every device of that owner. Returns {debt, invalidated_at}.';

notify pgrst,'reload schema';
commit;
