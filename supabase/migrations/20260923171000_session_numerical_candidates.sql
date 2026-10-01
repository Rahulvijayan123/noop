begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- Mutable scheduling metadata is separate from the immutable request body and candidate revisions.
alter table public.compute_session_requests add column numerical_attempted_at timestamptz,
 add column numerical_retry_after timestamptz, add column numerical_last_error text;
revoke update,delete,truncate,references,trigger on public.compute_session_requests from public,anon,authenticated,service_role;
grant update(numerical_attempted_at,numerical_retry_after,numerical_last_error) on public.compute_session_requests to service_role;
create policy compute_request_worker_schedule on public.compute_session_requests for update to service_role
 using(true) with check(true);

-- Immutable server-generated candidates. No numerical worker or selection is enabled here.
create table public.compute_session_numerical_candidates (
 revision bigint generated always as identity primary key,
 request_id uuid not null references public.compute_session_requests on delete cascade,
 user_id uuid not null,
 device_id uuid not null,
 source_id uuid not null,
 input_day date not null,
 input_revision bigint not null check(input_revision>0),
 source_fingerprint text not null check(source_fingerprint ~ '^[a-f0-9]{32}$'),
 implementation_sha256 text not null check(implementation_sha256 ~ '^[a-f0-9]{64}$'),
 candidate jsonb not null,
 computed_at timestamptz not null default clock_timestamp(),
 foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade,
 unique(request_id,input_revision,source_fingerprint,implementation_sha256)
);
alter table public.compute_session_numerical_candidates enable row level security;
revoke all on public.compute_session_numerical_candidates from public,anon,authenticated,service_role;
grant select on public.compute_session_numerical_candidates to service_role;
create policy session_candidate_service on public.compute_session_numerical_candidates for select to service_role using(true);
create trigger session_candidate_immutable before update or delete on public.compute_session_numerical_candidates
 for each row execute function internal.physiology_immutable_release();

create function internal.compute_session_scope_active(r public.compute_session_requests)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.devices where id=r.device_id and user_id=r.user_id and is_active)
 and not exists(select 1 from public.noop_account_retirements where user_id=r.user_id)
 and not exists(select 1 from public.noop_wearable_aliases where user_id=r.user_id and provisional_device_id=r.device_id)
 and not exists(select 1 from public.noop_app_installations where user_id=r.user_id and source_id=r.source_id
   and (revoked_at is not null or retired_at is not null))
 and (exists(select 1 from public.noop_app_installations where user_id=r.user_id and source_id=r.source_id
     and revoked_at is null and retired_at is null)
   or exists(select 1 from public.compute_account_sources where user_id=r.user_id and source_id=r.source_id and revoked_at is null))
$$;
revoke all on function internal.compute_session_scope_active(public.compute_session_requests) from public,anon,authenticated,service_role;

-- Processing consent is current authority, not a historical numerical parameter.
-- A retained historical request cannot revive journal sharing after withdrawal.
create function public.compute_session_journal_consent(p_user uuid,p_device uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare c scoring_history_inputs_v3;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 select * into c from scoring_history_inputs_v3 where user_id=p_user and device_id=p_device
   and kind='config' and entity='primary'
   and effective_day<=(now() at time zone public.scoring_timezone_at(p_user,now()))::date
   order by effective_day desc,revision desc limit 1;
 return jsonb_build_object('revision',coalesce(c.revision,0),'allowed',
   coalesce(not c.deleted and c.payload->'journalContextEnabled'='true'::jsonb,false));
end $$;
revoke all on function public.compute_session_journal_consent(uuid,uuid) from public,anon,authenticated;
grant execute on function public.compute_session_journal_consent(uuid,uuid) to service_role;

-- A live decision expires relative to its observation window end, not the workout's start.
-- The previous five-minute-from-start rule made the existing ten-minute effort kernel unreachable.
create or replace function public.submit_compute_session_request(p_user uuid,p_device uuid,p_source uuid,p_request jsonb)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public as $$
declare prior compute_session_requests; request_id uuid; family text; first_at timestamptz; last_at timestamptz; expiry timestamptz;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'service required' using errcode='42501'; end if;
 if not exists(select 1 from devices where id=p_device and user_id=p_user and is_active)
   or exists(select 1 from noop_account_retirements where user_id=p_user)
   or exists(select 1 from noop_app_installations where user_id=p_user and source_id=p_source and (revoked_at is not null or retired_at is not null))
   or not (exists(select 1 from noop_app_installations where user_id=p_user and source_id=p_source and revoked_at is null and retired_at is null)
     or exists(select 1 from compute_account_sources where user_id=p_user and source_id=p_source and revoked_at is null)) then
   raise exception 'owned source/device required' using errcode='42501'; end if;
 request_id:=(p_request->>'id')::uuid;family:=p_request->>'family';
 first_at:=(p_request->>'event_start')::timestamptz;last_at:=(p_request->>'event_end')::timestamptz;expiry:=(p_request->>'expires_at')::timestamptz;
 if request_id is null or not exists(select 1 from pg_timezone_names where name=p_request->>'timezone_id')
   or first_at is null or last_at<first_at or last_at-first_at>(case when family='insights' then interval '90 days' else interval '6 hours' end) then
   raise exception 'invalid request identity/timezone/window' using errcode='22023'; end if;
 if family in ('live_coaching','stress_events','live_workout') and (expiry is null
   or expiry>coalesce(last_at,first_at)+interval '5 minutes' or expiry<=coalesce(last_at,first_at)) then
   raise exception 'bounded expiry required' using errcode='22023'; end if;
 insert into compute_session_requests(id,user_id,device_id,source_id,family,session_id,event_start,event_end,
   timezone_id,input_revision,algorithm_version,configuration_version,consent,expires_at,request)
 values(request_id,p_user,p_device,p_source,family,(p_request->>'session_id')::uuid,first_at,last_at,p_request->>'timezone_id',
   (p_request->>'input_revision')::bigint,p_request->>'algorithm_version',p_request->>'configuration_version',
   (p_request->>'consent')::boolean,expiry,p_request) on conflict(id) do nothing;
 select * into prior from compute_session_requests where id=request_id;
 if prior.user_id<>p_user or prior.device_id<>p_device or prior.source_id<>p_source or prior.request<>p_request then
   raise sqlstate 'PT409' using message='request_identity_conflict'; end if;
 return jsonb_build_object('request_id',request_id,'state','processing','result',null);
end $$;

-- Includes source/lifecycle, context and selected-result changes as well as scalar revisions.
-- This is a consistency token, not a claim that the observations are scientifically qualified.
create function public.compute_session_source_fingerprint(p_request uuid)
returns text language plpgsql stable security definer set search_path=pg_catalog,public set timezone='UTC' as $$
declare r compute_session_requests; lo date; hi date;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 select * into r from compute_session_requests where id=p_request;
 if r.id is null or r.event_end is null or not internal.compute_session_scope_active(r) then return null; end if;
 lo:=(r.event_start at time zone r.timezone_id)::date;
 hi:=((r.event_end-interval '1 microsecond') at time zone r.timezone_id)::date;
 if hi-lo>90 then return null; end if;
 return md5(jsonb_build_object('request',r.request,'profile',(select to_jsonb(p) from profiles p where p.id=r.user_id),
   'current_journal_consent',case when r.family='insights' then public.compute_session_journal_consent(r.user_id,r.device_id) end,
   'source',(select jsonb_build_array(s.source_id,s.user_id,s.first_enrolled_at,s.revoked_at,s.retired_at)
     from noop_app_installations s where s.user_id=r.user_id and s.source_id=r.source_id),
   'lease',(select jsonb_build_array(l.source_id,l.generation) from noop_collection_leases l where l.user_id=r.user_id and l.device_id=r.device_id),
   'inputs',(select jsonb_agg(jsonb_build_array(day,input_revision) order by day)
     from physiology_work_items where user_id=r.user_id and device_id=r.device_id and day between lo-1 and hi),
   'journal',(select jsonb_agg(to_jsonb(j) order by day,question) from noop_journal_entries j
     where j.user_id=r.user_id and j.device_id=r.device_id and j.source_id=r.source_id and j.day between lo and hi),
   'paces',(select jsonb_agg(to_jsonb(e) order by ts,kind,batch_id) from noop_events e
     where e.user_id=r.user_id and e.device_id=r.device_id and e.source_id=r.source_id and e.kind='breath_pace'
       and e.ts>=extract(epoch from r.event_start) and e.ts<extract(epoch from r.event_end)),
   'context',(select jsonb_agg(to_jsonb(c) order by revision) from scoring_history_inputs_v3 c
     where c.user_id=r.user_id and c.device_id=r.device_id and c.effective_day<=hi),
   'selected',(select jsonb_agg(to_jsonb(s) order by family) from compute_family_selections s
     where s.user_id=r.user_id and s.device_id=r.device_id),
   'selected_revocations',(select jsonb_agg(to_jsonb(v) order by v.approval_id) from compute_family_revocations v
     join compute_family_selections s using(approval_id) where s.user_id=r.user_id and s.device_id=r.device_id),
   'publications',(select jsonb_agg(jsonb_build_array(period_day,algorithm_version,input_revision,payload_hash)
     order by period_day,algorithm_version,input_revision) from server_physiology_results
     where user_id=r.user_id and device_id=r.device_id and period_day between lo and hi),
   'history',(select jsonb_agg(jsonb_build_array(day,algorithm_version,result_revision) order by day,algorithm_version,result_revision)
     from scoring_snapshots_v2 where user_id=r.user_id and device_id=r.device_id and day between lo and hi)
 )::text);
end $$;
revoke all on function public.compute_session_source_fingerprint(uuid) from public,anon,authenticated;
grant execute on function public.compute_session_source_fingerprint(uuid) to service_role;

create function public.publish_compute_session_candidate(p_request uuid,p_day date,p_revision bigint,p_fingerprint text,p_candidate jsonb)
returns bigint language plpgsql security definer set search_path=pg_catalog,public as $$
declare r compute_session_requests; q physiology_work_items; result bigint; impl text;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 select * into r from compute_session_requests where id=p_request for update;
 if r.id is null or not internal.compute_session_scope_active(r) then return null; end if;
 select * into q from physiology_work_items where user_id=r.user_id and device_id=r.device_id
   and day=p_day for update;
 if q.input_revision is distinct from p_revision or p_fingerprint is distinct from compute_session_source_fingerprint(p_request)
   or p_day is distinct from ((r.event_end-interval '1 microsecond') at time zone r.timezone_id)::date then return null; end if;
 impl:=p_candidate->'feature_manifest'->>'implementation_sha256';
 if p_candidate->>'owner' is distinct from 'server'
   or p_candidate->>'owner_id' is distinct from r.user_id::text or p_candidate->>'device_id' is distinct from r.device_id::text
   or p_candidate->>'source_id' is distinct from r.source_id::text or p_candidate->>'request_id' is distinct from r.id::text
   or p_candidate->>'decision_id' is distinct from r.id::text
   or p_candidate->>'window' is distinct from r.session_id::text or p_candidate->>'family' is distinct from r.family
   or (p_candidate->'details'->>'event_start')::numeric is distinct from extract(epoch from r.event_start)
   or (p_candidate->'details'->>'event_end')::numeric is distinct from extract(epoch from r.event_end)
   or (p_candidate->>'expires_at')::timestamptz is distinct from r.expires_at
   or p_candidate->>'timezone_id' is distinct from r.timezone_id or (p_candidate->>'input_revision')::bigint is distinct from p_revision
   or p_candidate->>'algorithm_version' is distinct from 'frwhoop-session-1'
   or p_candidate->>'configuration_version' is distinct from 'receipt-bound-session-1'
   or p_candidate->>'publication_status' is distinct from 'shadow' or p_candidate->'canonical_qualification' is distinct from 'null'::jsonb
   or jsonb_typeof(p_candidate->'producer_generated') is distinct from 'array'
   or (p_candidate->>'feature_manifest_canonical')::jsonb is distinct from p_candidate->'feature_manifest'
   or encode(sha256(convert_to(p_candidate->>'feature_manifest_canonical','UTF8')),'hex') is distinct from p_candidate->>'feature_manifest_hash'
   or octet_length(p_candidate::text)>262144 then raise exception 'session candidate contract' using errcode='22023'; end if;
 insert into compute_session_numerical_candidates(request_id,user_id,device_id,source_id,input_day,input_revision,
   source_fingerprint,implementation_sha256,candidate) values(r.id,r.user_id,r.device_id,r.source_id,p_day,p_revision,p_fingerprint,impl,p_candidate)
 on conflict(request_id,input_revision,source_fingerprint,implementation_sha256) do nothing returning revision into result;
 if result is null then
   select revision into result from compute_session_numerical_candidates where request_id=r.id and input_revision=p_revision
     and source_fingerprint=p_fingerprint and implementation_sha256=impl and candidate=p_candidate;
   if result is null then raise exception 'session_candidate_identity_conflict' using errcode='PT409'; end if;
 end if;
 return result;
end $$;
revoke all on function public.publish_compute_session_candidate(uuid,date,bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.publish_compute_session_candidate(uuid,date,bigint,text,jsonb) to service_role;

alter function public.read_compute_session_result(uuid,uuid,uuid,uuid) rename to read_compute_session_result_before_numerical;
revoke all on function public.read_compute_session_result_before_numerical(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
create function public.read_compute_session_result(p_user uuid,p_device uuid,p_source uuid,p_request uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public set timezone='UTC' as $$
declare r compute_session_requests; base jsonb; c compute_session_numerical_candidates; a compute_family_approvals;
 result jsonb; vals jsonb:='{}'; metric text; policy compute_family_policy; reason text; state text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'service required' using errcode='42501'; end if;
 select * into r from compute_session_requests where id=p_request and user_id=p_user and device_id=p_device and source_id=p_source;
 if r.id is null then raise sqlstate 'PT404' using message='request_not_found'; end if;
 if not internal.compute_session_scope_active(r) then raise exception 'source_scope_revoked' using errcode='42501'; end if;
 base:=read_compute_session_result_before_numerical(p_user,p_device,p_source,p_request);
 select * into c from compute_session_numerical_candidates where request_id=r.id order by revision desc limit 1;
 if c.revision is null then
   if r.numerical_last_error is not null then return base||jsonb_build_object('state','processing',
     'reason',r.numerical_last_error,'retry_after',r.numerical_retry_after); end if;
   return base;
 end if;
 select * into policy from compute_family_policy where family=r.family;
 select q.* into a from compute_family_approvals q join compute_family_selections s using(approval_id)
   where s.user_id=p_user and s.device_id=p_device and s.family=r.family and q.family=r.family;
 state:='unqualified'; reason:=coalesce(c.candidate->'details'->>'reason','producer_qualification_required');
 if not r.consent then reason:='consent_required';state:='unavailable';
 elsif r.family='insights' and public.compute_session_journal_consent(p_user,p_device)->'allowed' is distinct from 'true'::jsonb
   then reason:='journal_context_consent_required';state:='unavailable';
 elsif r.expires_at<=now() then reason:='decision_expired';state:='unavailable';
 elsif c.source_fingerprint is distinct from compute_session_source_fingerprint(r.id) then reason:='session_input_changed';state:='processing';
 elsif not exists(select 1 from physiology_work_items where user_id=p_user and device_id=p_device and day=c.input_day
   and input_revision=c.input_revision) then reason:='session_input_changed';state:='processing';
 elsif a.approval_id is not null and internal.compute_family_candidate_authorized(a,c.candidate) then reason:=null;
 end if;
 foreach metric in array policy.metrics loop
   if reason is null and metric=any(a.approved_metrics) and c.candidate->'producer_generated' ? metric
     and c.candidate->'canonical_input_eligible' ? metric then vals:=vals||jsonb_build_object(metric,c.candidate->'values'->metric);
   else vals:=vals||jsonb_build_object(metric,null); end if;
 end loop;
 if exists(select 1 from jsonb_each(vals) v where v.value<>'null'::jsonb) then state:='available';
 elsif reason is null then reason:=coalesce(c.candidate->'details'->>'reason','qualified_input_required'); end if;
 -- Function-local UTC makes timestamptz JSON and its hash independent of the
 -- caller's connection timezone; request civil-day semantics still use r.timezone_id.
 result:=(c.candidate-'details')||jsonb_build_object('values',vals,'status',state,'reason',reason,
   'result_revision','sha256:'||encode(sha256(convert_to(to_jsonb(c)::text,'UTF8')),'hex'),
   'computed_at',c.computed_at,'observed_through',r.event_end,'manifest_hash',a.implementation_sha256,
   'selected_algorithm_version',a.algorithm_version,'canonical_qualification',case when state='available' then 'signed_reference_approval' end,
   'freshness',case when r.expires_at<=now() then 'expired' when state='available' then 'current' else 'unavailable' end,
   'details',jsonb_build_object('request_id',r.id,'requested_input_revision',r.input_revision,'producer_revision',c.revision,
     'event_start',extract(epoch from r.event_start),'event_end',extract(epoch from r.event_end),
     'input_receipts',c.candidate->'details'->'input_receipts','context_revisions',c.candidate->'details'->'context_revisions',
     'reason',reason,'family_approval_id',a.approval_id));
 return jsonb_build_object('request_id',r.id,'state',state,'result',result);
end $$;
revoke all on function public.read_compute_session_result(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.read_compute_session_result(uuid,uuid,uuid,uuid) to service_role;
commit;
