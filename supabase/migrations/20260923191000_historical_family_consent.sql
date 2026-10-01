-- Current permission is distinct from an immutable historical model parameter.
-- Config revisions also reset discovery when a future-effective withdrawal becomes current.
begin;

create function public.compute_historical_configuration(p_user uuid,p_device uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare c public.scoring_history_inputs_v3; zone text; current_day date;
begin
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user and is_active)
    or exists(select 1 from public.noop_account_retirements where user_id=p_user) then
    raise exception 'active owned device required' using errcode='42501';
  end if;
  zone:=public.scoring_timezone_at(p_user,now());
  current_day:=(now() at time zone zone)::date;
  select * into c from public.scoring_history_inputs_v3
    where user_id=p_user and device_id=p_device and kind='config' and entity='primary'
      and effective_day<=current_day
    order by effective_day desc,revision desc limit 1;
  return jsonb_build_object('revision',coalesce(c.revision,0),'deleted',coalesce(c.deleted,true),
    'payload',c.payload,'current_day',current_day,'timezone_id',zone);
end $$;
revoke all on function public.compute_historical_configuration(uuid,uuid) from public,anon,authenticated;
grant execute on function public.compute_historical_configuration(uuid,uuid) to service_role;

create or replace function internal.compute_family_candidate_authorized(a public.compute_family_approvals,c jsonb)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare current_configuration jsonb;
begin
  if a.family in ('illness','cycle') then
    current_configuration:=public.compute_historical_configuration((c->>'owner_id')::uuid,(c->>'device_id')::uuid);
    if current_configuration->'deleted' is distinct from 'false'::jsonb
      or current_configuration->'payload'->(case when a.family='illness' then 'journalContextEnabled' else 'cycleAwarenessEnabled' end) is distinct from 'true'::jsonb
      or (jsonb_typeof(c->'details'->'current_configuration_revision')='number'
        and c->'details'->>'current_configuration_revision' ~ '^[1-9][0-9]{0,18}$'
        and (length(c->'details'->>'current_configuration_revision')<19
          or c->'details'->>'current_configuration_revision'<='9223372036854775807')) is not true then
      return false;
    end if;
  end if;
  return coalesce(internal.compute_family_approval_valid(a)
    and c->>'algorithm_version'=a.algorithm_version and c->'feature_manifest'->>'family'=a.family
    and c->'feature_manifest'->>'implementation_sha256'=a.implementation_sha256
    and c->>'feature_manifest_hash'=a.feature_manifest_hash
    and (c->>'feature_manifest_canonical')::jsonb=c->'feature_manifest'
    and encode(sha256(convert_to(c->>'feature_manifest_canonical','UTF8')),'hex')=a.feature_manifest_hash
    and jsonb_typeof(c->'values')='object' and jsonb_typeof(c->'producer_generated')='array'
    and jsonb_typeof(c->'canonical_input_eligible')='array',false);
exception when data_exception or insufficient_privilege then return false;
end $$;

create or replace function public.server_scoring_read_contract(p_user uuid,p_day date,p_device uuid default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare base jsonb; sel public.compute_family_selections; a public.compute_family_approvals;
  policy public.compute_family_policy; candidate jsonb; source_payload jsonb; revision text;
  input_revision bigint; computed timestamptz; observed timestamptz; timezone text;
  values jsonb; availability jsonb; metric text; state text; why text; result jsonb;
  base_family record; legacy_calendar jsonb; current_configuration jsonb; consent_reason text;
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
    consent_reason:=null;
    if sel.family in ('illness','cycle') then
      current_configuration:=public.compute_historical_configuration(p_user,p_device);
      if current_configuration->'deleted' is distinct from 'false'::jsonb
        or current_configuration->'payload'->(case when sel.family='illness' then 'journalContextEnabled' else 'cycleAwarenessEnabled' end) is distinct from 'true'::jsonb then
        consent_reason:=case when sel.family='illness' then 'current_journal_consent_required' else 'current_cycle_consent_required' end;
      elsif candidate is not null and (jsonb_typeof(candidate->'details'->'current_configuration_revision')='number'
        and candidate->'details'->>'current_configuration_revision' ~ '^[1-9][0-9]{0,18}$'
        and (length(candidate->'details'->>'current_configuration_revision')<19
          or candidate->'details'->>'current_configuration_revision'<='9223372036854775807')) is not true then
        consent_reason:='historical_input_admission_required';
      end if;
    end if;
    if consent_reason is not null then state:='unqualified';why:=consent_reason;end if;
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
          'reason',case when consent_reason is not null then consent_reason when not(metric=any(a.approved_metrics)) then 'metric_not_approved'
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

create or replace function public.server_result_days_page(p_user uuid,p_device uuid,p_source uuid,
  p_after bigint default 0,p_limit integer default 8,p_scope_revision text default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare scope_revision text; after_revision bigint; page jsonb; last_revision bigint; more boolean;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is distinct from p_user then
    raise exception 'owner required' using errcode='42501'; end if;
  if not exists(select 1 from devices where id=p_device and user_id=p_user and is_active)
    or exists(select 1 from noop_account_retirements where user_id=p_user)
    or not (exists(select 1 from noop_app_installations where source_id=p_source and user_id=p_user and revoked_at is null and retired_at is null)
      or exists(select 1 from compute_account_sources where source_id=p_source and user_id=p_user and revoked_at is null))
    or exists(select 1 from noop_app_installations where source_id=p_source and (user_id<>p_user or revoked_at is not null or retired_at is not null))
    or exists(select 1 from compute_account_sources where source_id=p_source and (user_id<>p_user or revoked_at is not null)) then
    raise exception 'active owned source and device required' using errcode='42501'; end if;
  if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 32 then
    raise exception 'invalid result cursor' using errcode='22023'; end if;
  -- Selection/qualification changes invalidate discovery independently of publication.
  select md5(jsonb_build_array(
    public.compute_historical_configuration(p_user,p_device)-array['payload','current_day'],
    (select jsonb_agg(to_jsonb(s) order by feature) from physiology_source_selection s where user_id=p_user),
    (select jsonb_agg(to_jsonb(f) order by feature) from physiology_feature_defaults f),
    (select jsonb_agg(to_jsonb(q) order by algorithm_version,feature) from physiology_feature_qualifications q),
    (select jsonb_agg(to_jsonb(r) order by approval_id) from physiology_promotion_revocations r),
    (select jsonb_agg(to_jsonb(p) order by family) from compute_family_policy p),
    (select jsonb_agg(to_jsonb(z) order by effective_at) from scoring_timezone_history z where user_id=p_user))::text) into scope_revision;
  after_revision:=case when p_scope_revision=scope_revision then p_after else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('day',r.day,'change_revision',r.change_revision)
    order by r.change_revision),'[]'::jsonb),coalesce(max(r.change_revision),after_revision)
    into page,last_revision from (select day,change_revision from server_result_days
      where user_id=p_user and device_id=p_device and change_revision>after_revision
      order by change_revision limit p_limit) r;
  select exists(select 1 from server_result_days where user_id=p_user and device_id=p_device
    and change_revision>last_revision) into more;
  return jsonb_build_object('schema_version',1,'days',page,'next_cursor',last_revision,
    'has_more',more,'scope_revision',scope_revision,
    'timezone_id',public.scoring_timezone_at(p_user,now()));
end $$;

notify pgrst,'reload schema';
commit;
