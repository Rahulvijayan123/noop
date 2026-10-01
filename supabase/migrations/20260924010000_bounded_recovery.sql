-- Explicit finite recovery admission. Existing canary policy and RPCs are unchanged.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table public.noop_recovery_database_identity (
 singleton boolean primary key default true check(singleton), database_id uuid not null default gen_random_uuid(),
 project_ref text check(project_ref ~ '^[a-z0-9]{20}$')
);
insert into public.noop_recovery_database_identity(singleton) values(true);
-- project_ref is deliberately NULL until the reviewed deployment binds this database.
create table public.noop_recovery_runs (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 device_id uuid not null references public.devices(id) on delete cascade,
 project_ref text not null check(project_ref ~ '^[a-z0-9]{20}$'),
 source_revision text not null check(source_revision ~ '^[0-9a-f]{40}$'),
 policy_hash text not null check(policy_hash ~ '^[0-9a-f]{64}$'),
 intake_image text not null check(intake_image ~ '^sha256:[0-9a-f]{64}$'),
 scoring_image text not null check(scoring_image ~ '^sha256:[0-9a-f]{64}$'),
 intake_instance uuid not null, scoring_instance uuid not null, supervisor_token uuid not null,
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null,
 maximum_expires_at timestamptz not null, observed_at timestamptz,
 state text not null default 'active' check(state in ('active','stopped')),
 wire_limit bigint not null default 33554432 check(wire_limit between 1 and 33554432),
 decoded_limit bigint not null default 134217728 check(decoded_limit between 67108864 and 134217728),
 intake_container text not null check(intake_container ~ '^[0-9a-f]{64}$'),
 scoring_container text not null check(scoring_container ~ '^[0-9a-f]{64}$'),
 inventory_cursor uuid, inventory_complete boolean not null default false,
 check(expires_at>created_at and expires_at<=maximum_expires_at),
 check(maximum_expires_at>=expires_at and maximum_expires_at<=created_at+interval '72 hours'),
 check(intake_instance<>scoring_instance and intake_container<>scoring_container)
);
create unique index noop_recovery_one_active_scope on public.noop_recovery_runs(user_id,device_id) where state='active';
create table public.noop_recovery_attempts (
 token uuid primary key, run_id uuid not null references public.noop_recovery_runs(id) on delete cascade,
 process_id uuid not null, instance_id uuid not null, lane text not null check(lane in ('verification','projection','legacy','scoring')),
 object_id uuid, score_day date, queue_token uuid, started_at timestamptz not null default clock_timestamp(),
 lease_until timestamptz not null, released_at timestamptz, outcome text,
 wire_bytes bigint not null check(wire_bytes>=0), decoded_bytes bigint not null check(decoded_bytes>=0),
 download_slots integer not null check(download_slots between 0 and 1), historical boolean not null,
 check((lane='scoring')=(score_day is not null)), check((lane='scoring')=(object_id is null))
);
create unique index noop_recovery_lane_slot on public.noop_recovery_attempts(run_id,lane) where released_at is null;
create unique index noop_recovery_object_slot on public.noop_recovery_attempts(object_id) where released_at is null and object_id is not null;
create table public.noop_recovery_object_state (
 run_id uuid not null references public.noop_recovery_runs(id) on delete cascade,
 object_id uuid not null references public.object_manifests(id) on delete cascade,
 lane text not null check(lane in ('verification','projection','legacy')),
 failures integer not null default 0, next_attempt_at timestamptz not null default clock_timestamp(),
 reason text, quarantined boolean not null default false, completed_at timestamptz,
 primary key(object_id,lane)
);
create table public.noop_recovery_inventory (
 run_id uuid not null references public.noop_recovery_runs(id) on delete cascade,
 object_id uuid not null, created_at timestamptz not null, wire_bytes bigint, decoded_bytes bigint,
 primary key(run_id,object_id)
);
create table public.noop_recovery_events (
 id bigint generated always as identity primary key, run_id uuid not null references public.noop_recovery_runs(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(), kind text not null, detail jsonb not null
);
create table public.noop_recovery_polls (
 run_id uuid not null references public.noop_recovery_runs(id) on delete cascade, lane text not null,
 last_poll_at timestamptz not null, polls bigint not null default 0, completed bigint not null default 0,
 object_failures bigint not null default 0, primary key(run_id,lane)
);

create function public.noop_recovery_validate(p_run uuid,p_require_observer boolean default true)
returns public.noop_recovery_runs language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;
begin
 if auth.role() is distinct from 'service_role' and session_user<>'postgres' then
  raise exception 'recovery_role_denied' using errcode='42501'; end if;
 select * into strict r from public.noop_recovery_runs where id=p_run for update;
 perform public.noop_intake_canary_validate(r.user_id,r.device_id);
 if r.state<>'active' or r.expires_at<=clock_timestamp() or not exists(select 1 from public.noop_recovery_database_identity where project_ref=r.project_ref)
  then raise exception 'recovery_run_expired_or_target_mismatch' using errcode='42501'; end if;
 if p_require_observer and (r.observed_at is null or r.observed_at<clock_timestamp()-interval '20 seconds')
  then raise exception 'recovery_supervision_unavailable' using errcode='42501'; end if;
 if exists(select 1 from public.physiology_feature_defaults f left join public.physiology_source_selection s
  on s.feature=f.feature and s.user_id=r.user_id and s.device_id=r.device_id
  where coalesce(s.algorithm_version,f.algorithm_version)<>'frwhoop-server-1')
  then raise exception 'recovery_selection_mismatch' using errcode='42501'; end if;
 return r;
end $$;

create function public.recovery_target_identity(p_run uuid,p_user uuid,p_device uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;
begin
 r:=public.noop_recovery_validate(p_run,false);
 if r.user_id is distinct from p_user or r.device_id is distinct from p_device then raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
 if exists(select 1 from public.physiology_feature_defaults f left join public.physiology_source_selection s
  on s.feature=f.feature and s.user_id=p_user and s.device_id=p_device
  where coalesce(s.algorithm_version,f.algorithm_version)<>'frwhoop-server-1')
  then raise exception 'recovery_selection_mismatch' using errcode='42501'; end if;
 return (select jsonb_build_object('database_id',database_id,'project_ref',project_ref,'owner_id',r.user_id,
  'device_id',r.device_id,'algorithm_version','frwhoop-server-1','expires_at',r.expires_at,
  'maximum_expires_at',r.maximum_expires_at,'policy_hash',r.policy_hash)
  from public.noop_recovery_database_identity);
end $$;

-- Only the host supervisor receives the separate supervisor token. It must inspect
-- exact container IDs, images and cgroup limits before each successful observation.
create function public.noop_recovery_supervise(p_run uuid,p_supervisor uuid,p_policy_hash text,p_observation jsonb,
 p_renew_until timestamptz default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;
begin
 r:=public.noop_recovery_validate(p_run,false);
 if r.supervisor_token is distinct from p_supervisor or r.policy_hash is distinct from p_policy_hash or
  p_observation->>'intake_container' is distinct from r.intake_container or
  p_observation->>'scoring_container' is distinct from r.scoring_container or
  p_observation->>'intake_image' is distinct from r.intake_image or
  p_observation->>'scoring_image' is distinct from r.scoring_image or
  p_observation->>'source_revision' is distinct from r.source_revision or
  p_observation->>'resources_healthy' is distinct from 'true' or p_observation->>'captured_at' is null or
  (p_observation->>'captured_at')::timestamptz<clock_timestamp()-interval '15 seconds' or
  (p_observation->>'captured_at')::timestamptz>clock_timestamp()+interval '5 seconds'
 then raise exception 'recovery_supervisor_mismatch' using errcode='42501'; end if;
 if p_renew_until is not null and (p_renew_until<=r.expires_at or p_renew_until>r.maximum_expires_at or
  p_renew_until>clock_timestamp()+interval '10 minutes') then raise exception 'recovery_renewal_outside_approval'; end if;
 update public.noop_recovery_runs set observed_at=clock_timestamp(),expires_at=coalesce(p_renew_until,expires_at) where id=p_run;
 insert into public.noop_recovery_events(run_id,kind,detail) values(p_run,case when p_renew_until is null then 'observation' else 'renewal' end,
  jsonb_build_object('expires_at',coalesce(p_renew_until,r.expires_at),'observation',p_observation));
 return jsonb_build_object('expires_at',coalesce(p_renew_until,r.expires_at));
end $$;
-- Expired leases remain charged. Only a stopped exact instance can release them.
create function public.noop_recovery_confirm_stopped(p_run uuid,p_supervisor uuid,p_instance uuid,p_container text)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs; n integer;
begin
 if auth.role() is distinct from 'service_role' and session_user<>'postgres' then raise exception 'recovery_role_denied' using errcode='42501'; end if;
 select * into strict r from public.noop_recovery_runs where id=p_run for update;
 if r.supervisor_token is distinct from p_supervisor or not ((p_instance is not distinct from r.intake_instance and p_container is not distinct from r.intake_container) or
  (p_instance is not distinct from r.scoring_instance and p_container is not distinct from r.scoring_container)) then raise exception 'recovery_supervisor_mismatch' using errcode='42501'; end if;
 update public.noop_recovery_attempts set released_at=clock_timestamp(),outcome='supervised_process_stopped'
  where run_id=p_run and instance_id=p_instance and released_at is null;
 get diagnostics n=row_count;
 update public.noop_recovery_runs set state='stopped',observed_at=null where id=p_run;
 insert into public.noop_recovery_events(run_id,kind,detail) values(p_run,'stopped',jsonb_build_object('instance',p_instance,'container',p_container,'released',n));
 return n;
end $$;

create function public.noop_recovery_assert_attempt(p_run uuid,p_process uuid,p_token uuid)
returns public.noop_recovery_attempts language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts; r public.noop_recovery_runs;
begin
 r:=public.noop_recovery_validate(p_run);
 perform pg_advisory_xact_lock(hashtextextended('bounded-recovery-capacity-v1',0));
 select * into a from public.noop_recovery_attempts where run_id=p_run and process_id=p_process and token=p_token and released_at is null for update;
 if not found or a.lease_until<=clock_timestamp() then raise exception 'recovery_lease_lost' using errcode='42501'; end if;
 return a;
end $$;

-- A competing healthy scope with eligible work gets the next turn after the
-- previous scope completes. Intake and scoring alternate when both are eligible;
-- this prevents a 112MiB score from starving a >16MiB raw object, or continuous
-- raw arrivals from starving scoring. Empty/backoff/poison lanes get no turn.
-- Queue depth cannot buy extra service slots.
create function public.noop_recovery_has_turn(p_run uuid,p_lane text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
 with eligible as materialized (select r.id,l.lane,r.created_at from public.noop_recovery_runs r
  cross join (values ('scoring'),('verification'),('projection'),('legacy')) l(lane)
  where r.state='active' and r.expires_at>clock_timestamp()+interval '40 seconds'
   and r.observed_at>clock_timestamp()-interval '20 seconds'
   and exists(select 1 from public.devices d where d.id=r.device_id and d.user_id=r.user_id and d.is_active)
   and not exists(select 1 from public.noop_account_retirements q where q.user_id=r.user_id)
   and case when l.lane='scoring' then r.decoded_limit>=117440512 and exists(select 1 from public.scoring_work_items w where w.user_id=r.user_id and w.device_id=r.device_id
    and w.done_at is null and w.next_attempt_at<=clock_timestamp() and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
    and (w.failure_revision<>w.input_revision or w.consecutive_failures<8))
   else exists(select 1 from public.object_manifests o left join public.noop_recovery_object_state s on s.object_id=o.id and s.lane=l.lane
    where o.user_id=r.user_id and o.device_id=r.device_id and o.object_class='raw' and o.status not in ('deleted','deleting','expired')
     and coalesce(nullif(o.compressed_bytes,0),r.wire_limit) between 1 and r.wire_limit
     and coalesce(nullif(o.uncompressed_bytes,0),r.decoded_limit) between 1 and r.decoded_limit
     and not coalesce(s.quarantined,false) and coalesce(s.next_attempt_at,'-infinity')<=clock_timestamp()
     and not exists(select 1 from public.noop_recovery_attempts a where a.object_id=o.id and a.released_at is null)
     and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id and c.state='copying' and c.lease_until>clock_timestamp())
     and case l.lane when 'verification' then exists(select 1 from public.noop_object_verification_debt d where d.object_id=o.id
       and d.state in ('pending','retry','leased') and d.next_attempt_at<=clock_timestamp() and (d.state<>'leased' or d.lease_until<=clock_timestamp()))
      when 'projection' then exists(select 1 from public.noop_projection_debt d where d.object_id=o.id and d.state='pending' and d.not_before<=clock_timestamp()
       and (d.lease_until is null or d.lease_until<=clock_timestamp())) and o.durability_receipt->>'state'='verified_indexed'
      else o.sha256 is not null and not exists(select 1 from public.noop_object_verification_debt d where d.object_id=o.id)
       and (o.durability_receipt is null or o.indexed_at is null or o.status not in ('ready','verified') or o.sha256_source is distinct from 'server_verified'
        or o.verified_at is null or not exists(select 1 from public.noop_signal_windows w where w.object_id=o.id and w.user_id=o.user_id and w.device_id=o.device_id and w.object_key=o.object_key)) end)
   end
   and not exists(select 1 from public.physiology_feature_defaults f left join public.physiology_source_selection s
    on s.feature=f.feature and s.user_id=r.user_id and s.device_id=r.device_id
    where coalesce(s.algorithm_version,f.algorithm_version)<>'frwhoop-server-1')
   and exists(select 1 from public.noop_recovery_database_identity d where d.project_ref=r.project_ref)
 ), turns as (select e.*,coalesce((select max(a.started_at) from public.noop_recovery_attempts a
    where a.run_id=e.id and a.lane=e.lane),e.created_at) last_scope,
    coalesce((select max(a.started_at) from public.noop_recovery_attempts a where a.lane=e.lane),'-infinity') last_lane
  from eligible e), class_turn as (
   select coalesce(max(started_at) filter(where lane='scoring'),'-infinity') scoring,
     coalesce(max(started_at) filter(where lane<>'scoring'),'-infinity') intake from public.noop_recovery_attempts)
 select case
  -- A scope with only oversized debt must still enter its bounded inspection and
  -- record the blocking reason; it cannot reserve capacity or block another class.
  when not exists(select 1 from eligible where id=p_run and lane=p_lane) then null
  when p_lane='scoring' and exists(select 1 from eligible where lane<>'scoring')
   and (select scoring>intake from class_turn) then false
  when p_lane<>'scoring' and exists(select 1 from eligible where lane='scoring')
   and (select intake>scoring from class_turn) then false
  when p_lane<>'scoring' and p_lane is distinct from (select lane from turns
   where lane<>'scoring' and not exists(select 1 from public.noop_recovery_attempts a where a.lane=turns.lane and a.released_at is null)
   order by last_lane,lane limit 1) then false
  else p_run=(select id from turns where lane=p_lane order by last_scope,id limit 1) end
$$;

create function public.noop_recovery_claim(p_run uuid,p_process uuid,p_instance uuid,p_source_revision text,p_image_digest text,p_lane text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs; m public.object_manifests;
 used_wire bigint; used_decoded bigint; downloads integer; previous_history boolean; token uuid:=gen_random_uuid();
 wire bigint; decoded bigint; qtoken uuid:=gen_random_uuid();
begin
 r:=public.noop_recovery_validate(p_run);
 perform pg_advisory_xact_lock(hashtextextended('bounded-recovery-capacity-v1',0));
 if p_lane is null or p_lane not in ('verification','projection','legacy') or p_process is null or p_instance is distinct from r.intake_instance or
  p_source_revision is distinct from r.source_revision or p_image_digest is distinct from r.intake_image then raise exception 'recovery_worker_identity_mismatch' using errcode='42501'; end if;
 if p_lane='projection' then perform public.noop_seed_projection_debt_scoped(r.user_id,r.device_id,16); end if;
 if public.noop_recovery_has_turn(p_run,p_lane) is false then return null; end if;
 select coalesce(sum(wire_bytes),0),coalesce(sum(decoded_bytes),0),coalesce(sum(download_slots),0) into used_wire,used_decoded,downloads
  from public.noop_recovery_attempts where released_at is null;
 if downloads>=2 or exists(select 1 from public.noop_recovery_attempts where lane=p_lane and released_at is null)
  or r.expires_at<clock_timestamp()+interval '40 seconds' then return null; end if;
 select historical into previous_history from public.noop_recovery_attempts where run_id=p_run and lane=p_lane order by started_at desc limit 1;
 -- Unknown declarations reserve the entire lane maximum before any body read.
 for m in select o.* from public.object_manifests o
  left join public.noop_recovery_object_state s on s.object_id=o.id and s.lane=p_lane
  where o.user_id=r.user_id and o.device_id=r.device_id and o.object_class='raw' and o.status not in ('deleted','deleting','expired')
   and not coalesce(s.quarantined,false) and coalesce(s.next_attempt_at,'-infinity')<=clock_timestamp()
   and not exists(select 1 from public.noop_recovery_attempts a where a.object_id=o.id and a.released_at is null)
   and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id and c.state='copying' and c.lease_until>clock_timestamp())
   and case p_lane
    when 'verification' then exists(select 1 from public.noop_object_verification_debt d where d.object_id=o.id and d.state in ('pending','retry','leased')
      and d.next_attempt_at<=clock_timestamp() and (d.state<>'leased' or d.lease_until<=clock_timestamp()))
    when 'projection' then exists(select 1 from public.noop_projection_debt d where d.object_id=o.id and d.state='pending' and d.not_before<=clock_timestamp()
      and (d.lease_until is null or d.lease_until<=clock_timestamp())) and o.durability_receipt->>'state'='verified_indexed'
    else o.sha256 is not null and not exists(select 1 from public.noop_object_verification_debt d where d.object_id=o.id)
      and (o.durability_receipt is null or o.indexed_at is null or o.status not in ('ready','verified') or o.sha256_source is distinct from 'server_verified'
       or o.verified_at is null or not exists(select 1 from public.noop_signal_windows w where w.object_id=o.id and w.user_id=o.user_id and w.device_id=o.device_id and w.object_key=o.object_key)) end
  order by case when (o.end_at<=clock_timestamp()-interval '10 minutes') is distinct from previous_history then 0 else 1 end,
   o.created_at,o.id for update of o skip locked limit 64
 loop
  wire:=coalesce(nullif(m.compressed_bytes,0),r.wire_limit); decoded:=coalesce(nullif(m.uncompressed_bytes,0),r.decoded_limit);
  if wire>r.wire_limit or decoded>r.decoded_limit or wire<0 or decoded<0 then
   insert into public.noop_recovery_object_state(run_id,object_id,lane,reason,next_attempt_at) values(p_run,m.id,p_lane,'blocked_by_recovery_size_budget',clock_timestamp()+interval '5 minutes')
    on conflict(object_id,lane) do update set run_id=excluded.run_id,reason=excluded.reason,next_attempt_at=excluded.next_attempt_at;
   continue;
  end if;
  if wire+used_wire>r.wire_limit or decoded+used_decoded>r.decoded_limit then continue; end if;
  if p_lane='verification' then
   update public.noop_object_verification_debt set state='leased',lease_token=qtoken,lease_until=clock_timestamp()+interval '40 seconds',attempts=attempts+1
    where object_id=m.id;
  elsif p_lane='projection' then
   update public.noop_projection_debt set lease_token=qtoken,lease_until=clock_timestamp()+interval '40 seconds' where object_id=m.id;
  end if;
  insert into public.noop_recovery_attempts(token,run_id,process_id,instance_id,lane,object_id,queue_token,lease_until,wire_bytes,decoded_bytes,download_slots,historical)
   values(token,p_run,p_process,p_instance,p_lane,m.id,qtoken,clock_timestamp()+interval '40 seconds',wire,decoded,1,m.end_at<=clock_timestamp()-interval '10 minutes');
  return jsonb_build_object('recoveryToken',token,'token',qtoken,'leaseToken',qtoken,'objectId',m.id,'manifest',to_jsonb(m),
   'reservedWireBytes',wire,'reservedDecodedBytes',decoded);
 end loop;
 return null;
end $$;

-- A bounded inventory uses the run start cutoff; later arrivals are never mistaken
-- for completed starting debt. Original manifests are neither deleted nor rewritten.
create function public.noop_recovery_inventory_page(p_run uuid,p_limit integer default 256) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs; last_id uuid; n integer;
begin
 r:=public.noop_recovery_validate(p_run,false);
 if r.inventory_complete then return jsonb_build_object('complete',true,'inserted',0); end if;
 with page as (select id,created_at,compressed_bytes,uncompressed_bytes from public.object_manifests where user_id=r.user_id and device_id=r.device_id
  and object_class='raw' and created_at<=r.created_at and (r.inventory_cursor is null or id>r.inventory_cursor)
  order by id limit greatest(1,least(p_limit,1024))), ins as (
  insert into public.noop_recovery_inventory select p_run,id,created_at,compressed_bytes,uncompressed_bytes from page on conflict do nothing returning object_id)
 select count(*),max(object_id::text)::uuid into n,last_id from ins;
 update public.noop_recovery_runs set inventory_cursor=coalesce(last_id,inventory_cursor),inventory_complete=n<greatest(1,least(p_limit,1024)) where id=p_run;
 return jsonb_build_object('inserted',n,'complete',n<greatest(1,least(p_limit,1024)));
end $$;

create function public.noop_recovery_release(p_run uuid,p_process uuid,p_token uuid,p_success boolean,p_reason text,p_retryable boolean default true)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts;
begin
 a:=public.noop_recovery_assert_attempt(p_run,p_process,p_token);
 if a.object_id is not null then
  insert into public.noop_recovery_object_state(run_id,object_id,lane,failures,reason,quarantined,completed_at,next_attempt_at)
   values(p_run,a.object_id,a.lane,case when p_success then 0 else 1 end,case when p_success then null else left(p_reason,120) end,
    not p_success and not p_retryable,case when p_success then clock_timestamp() end,clock_timestamp()+interval '5 seconds')
   on conflict(object_id,lane) do update set run_id=excluded.run_id,failures=noop_recovery_object_state.failures+case when p_success then 0 else 1 end,
    reason=excluded.reason,quarantined=excluded.quarantined,completed_at=excluded.completed_at,
    next_attempt_at=clock_timestamp()+make_interval(secs=>least(300,5*power(2,least(noop_recovery_object_state.failures,6)))::integer);
 end if;
 update public.noop_recovery_attempts set released_at=clock_timestamp(),outcome=case when p_success then 'complete' else left(p_reason,120) end where token=p_token;
end $$;

-- Dispatch only existing durability operations, with the recovery fence held in
-- the SAME transaction as their mutation. This endpoint is never an arbitrary RPC proxy.
create function public.noop_recovery_intake_call(p_run uuid,p_process uuid,p_token uuid,p_operation text,p_args jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts; r public.noop_recovery_runs; result jsonb; success boolean;
begin
 a:=public.noop_recovery_assert_attempt(p_run,p_process,p_token);
 select * into strict r from public.noop_recovery_runs where id=p_run;
 if p_args ? 'p_object_id' and (p_args->>'p_object_id')::uuid is distinct from a.object_id or
  p_args ? 'p_object' and (p_args->>'p_object')::uuid is distinct from a.object_id or
  p_args ? 'p_user_id' and (p_args->>'p_user_id')::uuid is distinct from r.user_id then
  raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
 if p_operation='noop_reserve_copy_intent' and a.lane in ('legacy','verification') then
  result:=public.noop_reserve_copy_intent(r.user_id,a.object_id,case when a.lane='verification' then a.queue_token end);
 elsif p_operation='noop_current_object_receipt' then
  result:=public.noop_current_object_receipt(r.user_id,a.object_id);
 elsif p_operation='noop_abandon_copy_intent' then
  perform 1 from public.noop_object_copy_intents where id=(p_args->>'p_intent_id')::uuid and object_id=a.object_id;
  if not found then raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
  perform public.noop_abandon_copy_intent((p_args->>'p_intent_id')::uuid,(p_args->>'p_lease_token')::uuid,p_args->>'p_failure_code');
  result:='true';
 elsif p_operation='noop_intake_canary_commit_receipt' and a.lane in ('legacy','verification') then
  if (p_args->>'p_compressed_bytes')::bigint>a.wire_bytes or (p_args->>'p_uncompressed_bytes')::bigint>a.decoded_bytes then
   raise exception 'recovery_size_limit'; end if;
  result:=public.noop_intake_canary_commit_receipt(r.user_id,r.device_id,a.object_id,(p_args->>'p_intent')::uuid,
   (p_args->>'p_lease')::uuid,p_args->>'p_verified_key',p_args->>'p_wire_sha256',p_args->>'p_content_sha256',
   (p_args->>'p_compressed_bytes')::bigint,(p_args->>'p_uncompressed_bytes')::bigint,(p_args->>'p_verification_ms')::integer,nullif(p_args->'p_validation','null'));
  if a.lane='legacy' then perform public.noop_recovery_release(p_run,p_process,p_token,true,null); end if;
 elsif p_operation='noop_finish_object_verification' and a.lane='verification' then
  success:=public.noop_finish_object_verification(a.object_id,a.queue_token,p_args->>'p_failure_code',(p_args->>'p_failure_status')::integer,
   (p_args->>'p_retryable')::boolean,(p_args->>'p_verification_ms')::integer);
  if not success then raise exception 'recovery_queue_lease_lost' using errcode='42501'; end if;
  perform public.noop_recovery_release(p_run,p_process,p_token,public.noop_current_object_receipt(r.user_id,a.object_id) is not null,
   coalesce(p_args->>'p_failure_code','verification_failed'),coalesce((p_args->>'p_retryable')::boolean,true));
  result:=to_jsonb(success);
 elsif p_operation='noop_defer_object_verification' and a.lane='verification' then
  perform public.noop_defer_object_verification(a.object_id,a.queue_token);
  perform public.noop_recovery_release(p_run,p_process,p_token,false,'attempt_deferred'); result:='true';
 elsif p_operation='noop_intake_canary_commit_projection' and a.lane='projection' then
  result:=public.noop_intake_canary_commit_projection(r.user_id,r.device_id,a.object_id,p_args->>'p_body_sha256',p_args->'p_header',
   p_args->'p_rows',p_args->'p_keep_keys',a.queue_token);
  select state='complete' into success from public.noop_projection_debt where object_id=a.object_id;
  perform public.noop_recovery_release(p_run,p_process,p_token,coalesce(success,false),'projection_staged');
  result:=result||jsonb_build_object('recoveryProjectionComplete',coalesce(success,false));
 elsif p_operation='noop_fail_projection_debt' and a.lane='projection' then
  perform public.noop_fail_projection_debt(a.object_id,a.queue_token);
  perform public.noop_recovery_release(p_run,p_process,p_token,false,'projection_failed'); result:='true';
 elsif p_operation='legacy_failure' and a.lane='legacy' then
  perform public.noop_recovery_release(p_run,p_process,p_token,false,coalesce(p_args->>'reason','legacy_failed'),coalesce((p_args->>'retryable')::boolean,true)); result:='true';
 else raise exception 'recovery_operation_denied' using errcode='42501'; end if;
 return result;
end $$;

create function public.noop_recovery_poll(p_run uuid,p_lane text,p_completed integer,p_failures integer) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
 perform public.noop_recovery_validate(p_run);
 if p_lane not in ('verification','projection','legacy') or p_completed not between 0 and 1 or p_failures not between 0 and 1 then raise exception 'invalid_recovery_poll'; end if;
 insert into public.noop_recovery_polls(run_id,lane,last_poll_at,polls,completed,object_failures) values(p_run,p_lane,clock_timestamp(),1,p_completed,p_failures)
  on conflict(run_id,lane) do update set last_poll_at=excluded.last_poll_at,polls=noop_recovery_polls.polls+1,
   completed=noop_recovery_polls.completed+excluded.completed,object_failures=noop_recovery_polls.object_failures+excluded.object_failures;
end $$;

create function public.noop_recovery_status(p_run uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs; base jsonb; active jsonb; debt jsonb;
begin
 r:=public.noop_recovery_validate(p_run,false);
 base:=public.noop_intake_canary_status(r.user_id,r.device_id,r.source_revision,r.intake_instance);
 select jsonb_build_object('attempts',count(*),'downloads',coalesce(sum(download_slots),0),'wire_bytes',coalesce(sum(wire_bytes),0),
  'decoded_bytes',coalesce(sum(decoded_bytes),0),'uncertain',count(*) filter(where lease_until<=clock_timestamp()),
  'lanes',coalesce(jsonb_agg(lane),'[]')) into active from public.noop_recovery_attempts where released_at is null;
 select jsonb_build_object('paused_verification_at_least',least(count(*),1001),'paused_verification_truncated',count(*)>1000) into debt
  from(select 1 from public.noop_object_verification_debt d join public.object_manifests m on m.id=d.object_id where m.user_id=r.user_id
   and m.device_id=r.device_id and d.state='paused_terminal' limit 1001) x;
 return base||jsonb_build_object('admission_mode','bounded-recovery','recovery_contract',1,'run_id',r.id,'expires_at',r.expires_at,
  'policy_hash',r.policy_hash,'observed_at',r.observed_at,'active',active,'additional_debt',debt,
  'wire_limit',r.wire_limit,'decoded_limit',r.decoded_limit,'inventory_complete',r.inventory_complete,
  'inventory_count',(select count(*) from public.noop_recovery_inventory where run_id=p_run),
  'inventory_verified',(select count(distinct s.object_id) from public.noop_recovery_object_state s join public.noop_recovery_inventory i
   on i.run_id=s.run_id and i.object_id=s.object_id where s.run_id=p_run and s.completed_at is not null and s.lane in ('legacy','verification')),
  'inventory_projected',(select count(*) from public.noop_recovery_inventory i join public.noop_projection_debt d on d.object_id=i.object_id
    where i.run_id=p_run and d.state='complete'),
  'inventory_input_processed',(select count(*) from public.noop_recovery_inventory i join public.object_manifests m on m.id=i.object_id
    where i.run_id=p_run and m.durability_receipt->>'state'='verified_indexed' and m.indexed_at is not null and m.verified_at is not null
     and exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id and w.device_id=m.device_id and w.object_key=m.object_key)
     and (m.format not like 'ndjson%' or exists(select 1 from public.noop_projection_debt d where d.object_id=m.id and d.state='complete'))),
  'backfill_computed_readback','NOT_MEASURED',
  'history_completed',(select count(*) from public.noop_recovery_attempts where run_id=p_run and historical and outcome='complete'),
  'live_completed',(select count(*) from public.noop_recovery_attempts where run_id=p_run and not historical and outcome='complete'),
  'progress_semantics','stage_completions_not_backfill',
  'blocked',(select coalesce(jsonb_object_agg(reason,n),'{}') from(select coalesce(s.reason,'none') reason,count(*) n from public.noop_recovery_object_state s
    join public.object_manifests m on m.id=s.object_id where m.user_id=r.user_id and m.device_id=r.device_id and s.completed_at is null group by s.reason) x),
  'oldest_eligible_history_at',(select min(m.created_at) from public.object_manifests m where m.user_id=r.user_id and m.device_id=r.device_id
    and m.object_class='raw' and m.status not in ('deleted','deleting','expired') and m.end_at<clock_timestamp()-interval '10 minutes'
    and not exists(select 1 from public.noop_recovery_object_state s where s.object_id=m.id and (s.quarantined or s.next_attempt_at>clock_timestamp()))
    and (m.durability_receipt is null or m.indexed_at is null or m.sha256_source is distinct from 'server_verified' or m.verified_at is null
      or exists(select 1 from public.noop_projection_debt d where d.object_id=m.id and d.state in ('pending','staged'))
      or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id and w.device_id=m.device_id and w.object_key=m.object_key))),
  'lanes',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from public.noop_recovery_polls p where run_id=p_run));
end $$;

create function public.scoring_recovery_claim_one(p_recovery_run uuid,p_process uuid,p_instance uuid,p_source_revision text,p_image_digest text,
 p_lease_seconds integer,p_max_failures integer,p_user uuid,p_device uuid,p_day date) returns setof public.scoring_work_items
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs; w public.scoring_work_items; used bigint;
begin
 r:=public.noop_recovery_validate(p_recovery_run);
 perform pg_advisory_xact_lock(hashtextextended('bounded-recovery-capacity-v1',0));
 if p_instance is distinct from r.scoring_instance or p_source_revision is distinct from r.source_revision or p_image_digest is distinct from r.scoring_image or p_user is distinct from r.user_id or p_device is distinct from r.device_id
  or p_process is null or p_lease_seconds is distinct from 40 or p_max_failures is null then raise exception 'recovery_worker_identity_mismatch' using errcode='42501'; end if;
 if public.noop_recovery_has_turn(p_recovery_run,'scoring') is false then return; end if;
 select coalesce(sum(decoded_bytes),0) into used from public.noop_recovery_attempts where released_at is null;
 if used+117440512>r.decoded_limit or r.expires_at<clock_timestamp()+interval '40 seconds' or
  exists(select 1 from public.noop_recovery_attempts where lane='scoring' and released_at is null) then return; end if;
 select * into w from public.scoring_legacy_claim_one(40,p_max_failures,p_user,p_device,p_day);
 if w.lease_token is null then return; end if;
 insert into public.noop_recovery_attempts(token,run_id,process_id,instance_id,lane,score_day,queue_token,lease_until,wire_bytes,decoded_bytes,download_slots,historical)
  values(w.lease_token,r.id,p_process,p_instance,'scoring',w.day,w.lease_token,w.lease_expires_at,0,117440512,0,w.day<current_date);
 return next w;
end $$;

create function public.engine_publish_recovery_legacy_fenced(p_secret text,p_payload jsonb,p_user uuid,p_device uuid,p_recovery_run uuid,p_process uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts; r public.noop_recovery_runs;
begin
 a:=public.noop_recovery_assert_attempt(p_recovery_run,p_process,(p_payload->>'lease_token')::uuid);
 select * into strict r from public.noop_recovery_runs where id=p_recovery_run;
 if a.lane<>'scoring' or a.score_day is distinct from (p_payload->>'day')::date or p_user is distinct from r.user_id or p_device is distinct from r.device_id then raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
 return public.engine_publish_canary_legacy_fenced(p_secret,p_payload,p_user,p_device);
end $$;

create function public.scoring_recovery_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,p_lease_token uuid,p_run_id uuid,
 p_outcome text,p_duration_ms integer,p_error text,p_recovery_run uuid,p_process uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts; r public.noop_recovery_runs; done boolean;
begin
 a:=public.noop_recovery_assert_attempt(p_recovery_run,p_process,p_lease_token);
 select * into strict r from public.noop_recovery_runs where id=p_recovery_run;
 if a.lane<>'scoring' or a.score_day is distinct from p_day or p_user is distinct from r.user_id or p_device is distinct from r.device_id then raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
 done:=public.scoring_legacy_finish_work(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id,p_outcome,p_duration_ms,p_error);
 if not done then raise exception 'recovery_queue_lease_lost' using errcode='42501'; end if;
 perform public.noop_recovery_release(p_recovery_run,p_process,p_lease_token,p_outcome='done',coalesce(p_error,p_outcome));
 return done;
end $$;

create function public.scoring_recovery_renew_lease(p_user uuid,p_device uuid,p_day date,p_revision bigint,p_lease_token uuid,p_run_id uuid,
 p_lease_seconds integer,p_recovery_run uuid,p_process uuid) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts; r public.noop_recovery_runs;
begin
 a:=public.noop_recovery_assert_attempt(p_recovery_run,p_process,p_lease_token);
 select * into strict r from public.noop_recovery_runs where id=p_recovery_run;
 if a.lane<>'scoring' or a.score_day is distinct from p_day or p_user is distinct from r.user_id or p_device is distinct from r.device_id or p_lease_seconds is distinct from 40 then raise exception 'recovery_scope_mismatch' using errcode='42501'; end if;
 -- Never extend past the originally reserved finite attempt. A caller renews only
 -- its proof of ownership; process watchdog and the original40s bound still apply.
 return a.lease_until>clock_timestamp() and r.expires_at>a.lease_until;
end $$;

do $$ declare t text; f record; begin
 foreach t in array array['noop_recovery_database_identity','noop_recovery_runs','noop_recovery_attempts','noop_recovery_object_state','noop_recovery_inventory','noop_recovery_events','noop_recovery_polls'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
 for f in select oid::regprocedure signature from pg_proc where pronamespace='public'::regnamespace and
  (proname like 'noop_recovery_%' or proname in ('recovery_target_identity','scoring_recovery_claim_one','scoring_recovery_finish_work','scoring_recovery_renew_lease','engine_publish_recovery_legacy_fenced')) loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
revoke all on function public.noop_recovery_release(uuid,uuid,uuid,boolean,text,boolean) from service_role;
revoke all on function public.noop_recovery_validate(uuid,boolean),public.noop_recovery_assert_attempt(uuid,uuid,uuid) from service_role;
revoke all on function public.noop_recovery_has_turn(uuid,text) from service_role;
commit;
