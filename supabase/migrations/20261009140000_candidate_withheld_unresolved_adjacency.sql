-- Candidate provider lane: accept the sidecar's `unresolved_adjacency` withheld reason.
--
-- The sidecar's WithheldReason enum (Tools/InferenceWorker/src/frwhoop_inference/contract.py) has ten
-- members: the nine of the shared plan plus the HRV adapter's `unresolved_adjacency` (a burst boundary
-- that observation identity cannot resolve is withheld rather than spliced). The worker's
-- CandidateWithheldReason and this function's whitelist only knew the nine, so the worker coerced the
-- verdict to `provider_error` (a fault of ours) before the write, and a direct write of the real reason
-- would have raised invalid_candidate_reason. The worker now carries it through
-- (Tools/CloudWorker/Sources/frwhoop-worker/InferenceClient.swift), and this replaces the function with
-- the same body and the whitelist extended by that one value.
--
-- Additive and re-runnable: CREATE OR REPLACE with the signature, return type, owner and grants unchanged
-- (the grant/revoke pair is restated so a re-run leaves the same privileges). Rows already stored as
-- `provider_error` stay as they are: the raw provider reason was not kept for verdicts the worker coerced
-- (it kept `provider_reason_raw` in diagnostics only for unknown strings), so they are not rewritten.
--
-- Body: 20261002090000_physiology_candidate_providers.sql lines 402-616, identical except `v_reasons`.
-- Rollback: re-create the function from that migration.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

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
    'insufficient_coverage','artifact_fraction','provider_error','timeout','not_ready',
    'unresolved_adjacency'];
begin
  -- Explicit caller authorization (spec S14). Service-role calls carry no JWT subject and are
  -- unaffected; a present subject must match the owner being written, so a future grant to a client
  -- role could not record a candidate for another user.
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
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

revoke all on function public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer) from public,anon,authenticated;
grant execute on function public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer) to service_role;

comment on column public.physiology_candidate_results.withheld_reason is
  'Machine-readable reason from the sidecar contract (blocked_input, blocked_artifact, blocked_license, '
  'unverified, insufficient_coverage, artifact_fraction, provider_error, timeout, not_ready, '
  'unresolved_adjacency); null only when status=''ok''.';

commit;
