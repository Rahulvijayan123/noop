-- Dormant family selection. No signing key, approval, selection or worker is installed here.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table public.compute_family_approvals (
  approval_id uuid primary key,
  family text not null references public.compute_family_policy,
  algorithm_version text not null,
  feature_manifest_hash text not null check(feature_manifest_hash ~ '^[a-f0-9]{64}$'),
  implementation_sha256 text not null check(implementation_sha256 ~ '^[a-f0-9]{64}$'),
  approved_metrics text[] not null check(cardinality(approved_metrics)>0),
  key_id text not null references internal.physiology_approval_keys,
  signed_payload text not null check(octet_length(signed_payload)<=32768),
  signature_hex text not null check(signature_hex ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now()
);
create table public.compute_family_revocations (
  approval_id uuid primary key references public.compute_family_approvals,
  reason text not null check(length(reason)>0),
  revoked_at timestamptz not null default now()
);
create table public.compute_family_selections (
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  family text not null references public.compute_family_policy,
  approval_id uuid not null references public.compute_family_approvals,
  updated_at timestamptz not null default now(),
  primary key(user_id,device_id,family)
);
alter table public.compute_family_approvals enable row level security;
alter table public.compute_family_revocations enable row level security;
alter table public.compute_family_selections enable row level security;
revoke all on public.compute_family_approvals,public.compute_family_revocations,public.compute_family_selections
  from public,anon,authenticated,service_role;
create trigger compute_family_approval_immutable before update or delete on public.compute_family_approvals
  for each row execute function internal.physiology_immutable_release();
create trigger compute_family_revocation_immutable before update or delete on public.compute_family_revocations
  for each row execute function internal.physiology_immutable_release();

create function internal.compute_family_approval_valid(a public.compute_family_approvals)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare p jsonb; k internal.physiology_approval_keys; metrics text[];
begin
  select * into k from internal.physiology_approval_keys where key_id=a.key_id and revoked_at is null;
  if not found then return false; end if;
  if encode(extensions.hmac(convert_to(a.signed_payload,'UTF8'),k.secret,'sha256'),'hex')
    is distinct from a.signature_hex then return false; end if;
  p:=a.signed_payload::jsonb;
  select f.metrics into metrics from public.compute_family_policy f where family=a.family;
  return coalesce(p->>'schema_version'='1' and p->>'purpose'='compute_family_promotion'
    and p->>'approval_id'=a.approval_id::text and p->>'key_id'=a.key_id and p->>'reviewer'=k.reviewer
    and p->>'decision'='approved' and p->>'family'=a.family and p->>'algorithm_version'=a.algorithm_version
    and p->>'feature_manifest_hash'=a.feature_manifest_hash and p->>'implementation_sha256'=a.implementation_sha256
    and p->'approved_metrics'=to_jsonb(a.approved_metrics) and a.approved_metrics<@metrics
    and cardinality(a.approved_metrics)=(select count(distinct m) from unnest(a.approved_metrics) m)
    and p->>'evaluation_sha256' ~ '^[a-f0-9]{64}$' and p->>'policy_sha256' ~ '^[a-f0-9]{64}$'
    and p->>'reference_artifact_sha256' ~ '^[a-f0-9]{64}$'
    and p->>'reference_kind'=case a.family
      when 'strain_energy' then case when a.approved_metrics<@array['avg_hr','max_hr']::text[]
        then 'source_observation_reference' else 'synchronized_hr_and_energy_reference' end
      when 'steps' then 'synchronized_step_count_reference'
      when 'workouts' then 'annotated_workout_and_hr_reference'
      when 'intraday_temperature' then 'calibrated_skin_temperature_reference'
      when 'spot_hrv' then 'synchronized_ecg_nn'
      when 'biofeedback' then 'paced_respiration_and_ecg_reference'
      when 'stress_events' then 'synchronized_autonomic_context_reference'
      when 'live_coaching' then 'prespecified_coaching_policy_reference'
      when 'live_workout' then 'synchronized_hr_and_energy_reference'
      when 'insights' then 'qualified_source_fact_reference'
      else 'qualified_'||a.family||'_reference' end
    and p->>'evaluation_partition' in ('test','external') and (p->>'participant_disjoint')::boolean
    and (p->>'functional_gates_passed')::boolean and (p->>'promotion_policy_passed')::boolean
    and (p->>'input_contract_verified')::boolean
    and (p->>'policy_frozen_at')::timestamptz<(p->>'evaluation_started_at')::timestamptz
    and (p->>'evaluation_started_at')::timestamptz<=(p->>'evaluation_finished_at')::timestamptz
    and (p->>'evaluation_finished_at')::timestamptz<=(p->>'approved_at')::timestamptz
    and (p->>'approved_at')::timestamptz<=now()
    and not exists(select 1 from public.compute_family_revocations where approval_id=a.approval_id),false);
exception when data_exception then return false;
end $$;
revoke all on function internal.compute_family_approval_valid(public.compute_family_approvals)
  from public,anon,authenticated,service_role;

-- One shared authorization predicate for day and session readers. A worker cannot create approval.
create function internal.compute_family_candidate_authorized(a public.compute_family_approvals,c jsonb)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  return coalesce(internal.compute_family_approval_valid(a)
    and c->>'algorithm_version'=a.algorithm_version and c->'feature_manifest'->>'family'=a.family
    and c->'feature_manifest'->>'implementation_sha256'=a.implementation_sha256
    and c->>'feature_manifest_hash'=a.feature_manifest_hash
    and (c->>'feature_manifest_canonical')::jsonb=c->'feature_manifest'
    and encode(sha256(convert_to(c->>'feature_manifest_canonical','UTF8')),'hex')=a.feature_manifest_hash
    and jsonb_typeof(c->'values')='object' and jsonb_typeof(c->'producer_generated')='array'
    and jsonb_typeof(c->'canonical_input_eligible')='array',false);
exception when data_exception then return false;
end $$;
revoke all on function internal.compute_family_candidate_authorized(public.compute_family_approvals,jsonb)
  from public,anon,authenticated,service_role;

alter function public.server_scoring_read_contract(uuid,date,uuid) rename to server_scoring_read_contract_before_families;
revoke all on function public.server_scoring_read_contract_before_families(uuid,date,uuid)
  from public,anon,authenticated,service_role;
create function public.server_scoring_read_contract(p_user uuid,p_day date,p_device uuid default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare base jsonb; sel public.compute_family_selections; a public.compute_family_approvals;
  policy public.compute_family_policy; candidate jsonb; source_payload jsonb; revision text;
  input_revision bigint; computed timestamptz; observed timestamptz; timezone text;
  values jsonb; availability jsonb; metric text; state text; why text; result jsonb;
  base_family record; legacy_calendar jsonb;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501'; end if;
  base:=public.server_scoring_read_contract_before_families(p_user,p_day,p_device);
  if p_device is null then return base; end if;
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user and is_active)
    or exists(select 1 from public.noop_account_retirements where user_id=p_user) then
    raise exception 'active owned device required' using errcode='42501'; end if;
  for base_family in select key,value from jsonb_each(base->'compute'->'families') loop
    if base_family.value->>'algorithm_version'='frwhoop-server-1'
      and base_family.value->>'owner_id'=p_user::text and base_family.value->>'device_id'=p_device::text
      and base_family.value->>'window'=p_day::text then
      select s.payload->'calendar' into legacy_calendar from public.server_physiology_results s
        where s.user_id=p_user and s.device_id=p_device and s.period_day=p_day and s.algorithm_version='frwhoop-server-1'
          and s.payload_hash=base_family.value->'details'->>'source_result_hash'
          and 'sha256:'||s.payload_hash=base_family.value->>'result_revision'
          and s.input_revision::text=base_family.value->>'input_revision'
          and s.payload->'calendar'->>'policy_version'='job-calendar-1'
          and exists(select 1 from pg_timezone_names z where z.name=s.payload->'calendar'->>'timezone_id');
      if legacy_calendar is not null then
        base:=jsonb_set(base,array['compute','families',base_family.key],base_family.value||jsonb_build_object(
          'timezone_id',legacy_calendar->>'timezone_id','details',(base_family.value->'details')||
          jsonb_build_object('publication_calendar',legacy_calendar)));
      end if;
    end if;
  end loop;
  for sel in select * from public.compute_family_selections where user_id=p_user and device_id=p_device loop
    select * into policy from public.compute_family_policy where family=sel.family;
    select * into a from public.compute_family_approvals where approval_id=sel.approval_id and family=sel.family;
    candidate:=null;source_payload:=null;revision:=null;input_revision:=null;computed:=null;observed:=null;timezone:=null;
    state:='unqualified';why:='producer_qualification_required';
    if a.approval_id is not null and internal.compute_family_approval_valid(a) then
      if a.algorithm_version='frwhoop-server-2-history' then
        select s.payload,'sha256:'||encode(sha256(convert_to(s.payload::text,'UTF8')),'hex'),s.input_revision,s.computed_at,
          (s.payload->>'dataThrough')::timestamptz,s.payload->>'timezone'
        into source_payload,revision,input_revision,computed,observed,timezone
        from public.scoring_snapshots_v2 s
        join public.scoring_history_checkpoints_v3 cp on cp.result_revision=s.result_revision
        join public.scoring_jobs_v2 j on j.user_id=s.user_id and j.device_id=s.device_id and j.day=s.day and j.algorithm_version=s.algorithm_version
        join public.scoring_history_heads_v3 h on h.user_id=s.user_id and h.device_id=s.device_id and h.algorithm_version=s.algorithm_version
        join public.scoring_algorithms_v2 av on av.algorithm_version=s.algorithm_version
        where s.user_id=p_user and s.device_id=p_device and s.day=p_day and s.algorithm_version=a.algorithm_version
          and j.input_revision=s.input_revision and j.completed_revision=s.input_revision and av.enabled
          and (h.dirty_from is null or s.day<h.dirty_from)
          and not exists(select 1 from public.scoring_invalidations_v2 i where i.user_id=p_user and i.device_id=p_device
            and i.algorithm_version=a.algorithm_version and p_day between i.next_day and i.through_day)
        order by s.result_revision desc limit 1;
      elsif a.algorithm_version='frwhoop-physiology-2' then
        select s.payload,'sha256:'||s.payload_hash,s.input_revision,s.computed_at,s.observed_through,
          case when jsonb_array_length(s.payload->'calendar_ownership'->'timezone_ids')=1
            then s.payload->'calendar_ownership'->'timezone_ids'->>0 end
        into source_payload,revision,input_revision,computed,observed,timezone
        from public.server_physiology_results s join public.physiology_work_items j
          on j.user_id=s.user_id and j.device_id=s.device_id and j.day=s.period_day
        where s.user_id=p_user and s.device_id=p_device and s.period_day=p_day and s.algorithm_version=a.algorithm_version
          and j.input_revision=s.input_revision and j.done_at is not null
        order by s.input_revision desc limit 1;
      end if;
      candidate:=source_payload->'family_candidates'->sel.family;
      why:=case when source_payload is null then 'selected_family_publication_pending' else 'family_manifest_or_input_unqualified' end;
      state:=case when source_payload is null then 'processing' else 'unqualified' end;
    end if;
    values:='{}';availability:='{}';
    foreach metric in array policy.metrics loop
      if candidate->>'owner_id'=p_user::text and candidate->>'device_id'=p_device::text and candidate->>'window'=p_day::text
        and internal.compute_family_candidate_authorized(a,candidate) and metric=any(a.approved_metrics)
        and candidate->'producer_generated' ? metric and candidate->'canonical_input_eligible' ? metric
        and timezone is not null and candidate->'values'->metric is not null and candidate->'values'->metric<>'null'::jsonb then
        values:=values||jsonb_build_object(metric,candidate->'values'->metric);
        availability:=availability||jsonb_build_object(metric,jsonb_build_object('status','available','reason',null));
      else
        values:=values||jsonb_build_object(metric,null);
        availability:=availability||jsonb_build_object(metric,jsonb_build_object('status','unqualified',
          'reason',case when not(metric=any(a.approved_metrics)) then 'metric_not_approved'
            else coalesce(candidate->'details'->'metric_availability'->metric->>'reason',why) end));
      end if;
    end loop;
    if exists(select 1 from jsonb_each(values) e where e.value<>'null'::jsonb) then state:='available';why:=null; end if;
    result:=(base->'compute'->'families'->sel.family)||jsonb_build_object(
      'status',state,'reason',why,'values',values,'owner','server','owner_id',p_user,'device_id',p_device,
      'window',p_day,'timezone_id',timezone,'input_revision',input_revision,'result_revision',revision,
      'algorithm_version',a.algorithm_version,'selected_algorithm_version',a.algorithm_version,
      'configuration_version',coalesce(candidate->>'configuration_version',source_payload->>'configuration_version'),
      'computed_at',computed,'observed_through',observed,'manifest_hash',a.implementation_sha256,
      'feature_manifest_hash',a.feature_manifest_hash,'canonical_qualification',
        case when state='available' then 'signed_reference_approval' end,
      'freshness',case when state='available' then 'current' else 'unavailable' end,'expires_at',null,
      'details',coalesce(candidate->'details','{}')||jsonb_build_object('metric_availability',availability,
        'source_result_hash',substring(revision from 8),'family_approval_id',a.approval_id));
    base:=jsonb_set(base,array['compute','families',sel.family],result);
  end loop;
  return base;
end $$;
revoke all on function public.server_scoring_read_contract(uuid,date,uuid) from public,anon;
grant execute on function public.server_scoring_read_contract(uuid,date,uuid) to authenticated,service_role;

-- History publication and independent family policy changes wake paginated native catch-up.
create trigger result_day_family_changed after insert on public.scoring_snapshots_v2
  for each row execute function public.touch_server_result_day();
create function internal.touch_compute_family_selection_days() returns trigger
language plpgsql security definer set search_path='' as $$
declare d record; row_data jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  if tg_table_name='compute_family_selections' then
    if tg_op='UPDATE' and (old.user_id is distinct from new.user_id or old.device_id is distinct from new.device_id
      or old.family is distinct from new.family) then raise exception 'selection_scope_is_immutable' using errcode='22023'; end if;
    if tg_op<>'DELETE' and not exists(select 1 from public.devices where id=new.device_id and user_id=new.user_id and is_active) then
      raise exception 'active owned device required' using errcode='42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended('result-days:'||(row_data->>'user_id')||':'||(row_data->>'device_id'),0));
    update public.server_result_days set change_revision=nextval('public.server_result_day_change_seq')
      where user_id=(row_data->>'user_id')::uuid and device_id=(row_data->>'device_id')::uuid;
    return null;
  end if;
  for d in select distinct s.user_id,s.device_id from public.compute_family_selections s
    join public.compute_family_approvals a on a.approval_id=s.approval_id
    where (tg_table_name='compute_family_selections' and s.user_id=(row_data->>'user_id')::uuid and s.device_id=(row_data->>'device_id')::uuid)
      or (tg_table_name='compute_family_revocations' and s.approval_id=(row_data->>'approval_id')::uuid)
      or (tg_table_name='physiology_approval_keys' and a.key_id=row_data->>'key_id') loop
    perform pg_advisory_xact_lock(hashtextextended('result-days:'||d.user_id::text||':'||d.device_id::text,0));
    update public.server_result_days set change_revision=nextval('public.server_result_day_change_seq')
      where user_id=d.user_id and device_id=d.device_id;
  end loop;
  return null;
end $$;
revoke all on function internal.touch_compute_family_selection_days() from public,anon,authenticated,service_role;
create trigger family_selection_days after insert or update or delete on public.compute_family_selections
  for each row execute function internal.touch_compute_family_selection_days();
create trigger family_revocation_days after insert on public.compute_family_revocations
  for each row execute function internal.touch_compute_family_selection_days();
create trigger family_signer_revocation_days after update on internal.physiology_approval_keys
  for each row execute function internal.touch_compute_family_selection_days();
notify pgrst,'reload schema';
commit;
