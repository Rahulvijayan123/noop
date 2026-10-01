-- Archive-only continuation uses the same durable global capacity ledger. No existing run is renewed.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

alter table public.noop_recovery_attempts add column archive_outbox_id bigint references public.physiology_archive_outbox(id);
alter table public.noop_recovery_attempts drop constraint noop_recovery_attempts_lane_check;
alter table public.noop_recovery_attempts drop constraint noop_recovery_attempts_check;
alter table public.noop_recovery_attempts drop constraint noop_recovery_attempts_check1;
alter table public.noop_recovery_attempts add constraint noop_recovery_attempts_lane_check check(lane in('verification','projection','legacy','scoring','archive'));
alter table public.noop_recovery_attempts add constraint noop_recovery_attempts_check check((lane in('scoring','archive'))=(score_day is not null));
alter table public.noop_recovery_attempts add constraint noop_recovery_attempts_check1 check((lane in('scoring','archive'))=(object_id is null));
alter table public.noop_recovery_attempts add constraint noop_recovery_attempts_archive_check check((lane='archive')=(archive_outbox_id is not null));
create unique index noop_recovery_archive_slot on public.noop_recovery_attempts(archive_outbox_id)where released_at is null and archive_outbox_id is not null;

create table public.noop_recovery_archive_workers(
 run_id uuid primary key references public.noop_recovery_runs(id),
 instance_id uuid not null unique,process_id uuid not null,
 source_revision text not null check(source_revision~'^[0-9a-f]{40}$'),
 image_digest text not null check(image_digest~'^sha256:[0-9a-f]{64}$'),
 container_id text not null unique check(container_id~'^[0-9a-f]{64}$'),
 bound_at timestamptz not null default clock_timestamp(),observed_at timestamptz,last_poll_at timestamptz,
 state text not null default 'active'check(state in('active','stopped'))
);
alter table public.noop_recovery_archive_workers enable row level security;
revoke all on public.noop_recovery_archive_workers from public,anon,authenticated,service_role;

-- Include archive in the existing non-scoring lane/scope rotation; it cannot repeatedly leapfrog eligible intake.
create or replace function public.noop_recovery_has_turn(p_run uuid,p_lane text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
 with eligible as materialized (select r.id,l.lane,r.created_at from public.noop_recovery_runs r
  cross join (values ('scoring'),('verification'),('projection'),('legacy'),('archive')) l(lane)
  where r.state='active' and r.expires_at>clock_timestamp()+interval '40 seconds'
   and r.observed_at>clock_timestamp()-interval '20 seconds'
   and exists(select 1 from public.devices d where d.id=r.device_id and d.user_id=r.user_id and d.is_active)
   and not exists(select 1 from public.noop_account_retirements q where q.user_id=r.user_id)
   and case when l.lane='scoring' then r.decoded_limit>=117440512 and exists(select 1 from public.scoring_work_items w where w.user_id=r.user_id and w.device_id=r.device_id
    and w.done_at is null and w.next_attempt_at<=clock_timestamp() and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
    and (w.failure_revision<>w.input_revision or w.consecutive_failures<8))
   when l.lane='archive' then exists(select 1 from public.noop_recovery_archive_workers aw where aw.run_id=r.id and aw.state='active'
    and aw.observed_at between clock_timestamp()-interval '20 seconds'and clock_timestamp()+interval '5 seconds')and exists(
    select 1 from public.physiology_archive_outbox ao join public.server_physiology_results ar using(user_id,device_id,period_day,algorithm_version,input_revision)
    where ao.user_id=r.user_id and ao.device_id=r.device_id and ao.algorithm_version='frwhoop-server-1'and ao.status<>'verified'and ao.next_attempt_at<=clock_timestamp()
     and(ao.lease_expires_at is null or ao.lease_expires_at<=clock_timestamp())and octet_length(ar.payload::text)<=2097152
     and not exists(select 1 from public.noop_recovery_attempts aa where aa.archive_outbox_id=ao.id and aa.released_at is null))
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

create function public.noop_recovery_archive_bind(p_run uuid,p_supervisor uuid,p_instance uuid,p_process uuid,p_source_revision text,p_image_digest text,p_container text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;w public.noop_recovery_archive_workers;
begin
 r:=public.noop_recovery_validate(p_run,false);
 if p_supervisor is distinct from r.supervisor_token or p_instance is null or p_process is null or
  p_instance in(r.intake_instance,r.scoring_instance)or p_container in(r.intake_container,r.scoring_container)or
  p_source_revision is null or p_source_revision!~'^[0-9a-f]{40}$'or p_image_digest is null or p_image_digest!~'^sha256:[0-9a-f]{64}$'or
  p_container is null or p_container!~'^[0-9a-f]{64}$'or r.maximum_expires_at<>r.created_at+interval '600 seconds'or r.expires_at<>r.maximum_expires_at
 then raise exception 'recovery_archive_binding_denied'using errcode='42501';end if;
 select * into w from public.noop_recovery_archive_workers where run_id=p_run for update;
 if found then
  if w.state<>'active'or w.instance_id is distinct from p_instance or w.process_id is distinct from p_process or w.source_revision is distinct from p_source_revision or w.image_digest is distinct from p_image_digest or w.container_id is distinct from p_container
   then raise exception 'recovery_archive_binding_immutable'using errcode='42501';end if;
  return true;
 end if;
 insert into public.noop_recovery_archive_workers(run_id,instance_id,process_id,source_revision,image_digest,container_id)
  values(p_run,p_instance,p_process,p_source_revision,p_image_digest,p_container);
 return true;
end $$;

create function public.noop_recovery_archive_supervise(p_run uuid,p_supervisor uuid,p_instance uuid,p_process uuid,p_source_revision text,p_image_digest text,p_container text,p_observation jsonb)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;w public.noop_recovery_archive_workers;
begin
 r:=public.noop_recovery_validate(p_run,false);
 select * into strict w from public.noop_recovery_archive_workers where run_id=p_run for update;
 if p_supervisor is distinct from r.supervisor_token or w.state<>'active'or w.instance_id is distinct from p_instance or w.process_id is distinct from p_process or
  w.source_revision is distinct from p_source_revision or w.image_digest is distinct from p_image_digest or w.container_id is distinct from p_container or
  p_observation->>'resources_healthy'is distinct from 'true'or p_observation->>'captured_at'is null or
  (p_observation->>'captured_at')::timestamptz not between clock_timestamp()-interval '15 seconds'and clock_timestamp()+interval '5 seconds'
 then raise exception 'recovery_archive_supervision_denied'using errcode='42501';end if;
 update public.noop_recovery_archive_workers set observed_at=clock_timestamp()where run_id=p_run;
 return true;
end $$;

create function public.noop_recovery_archive_validate(p_run uuid,p_process uuid)
returns public.noop_recovery_archive_workers language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;w public.noop_recovery_archive_workers;
begin
 r:=public.noop_recovery_validate(p_run);
 select * into strict w from public.noop_recovery_archive_workers where run_id=p_run for update;
 if w.state<>'active'or w.process_id is distinct from p_process or w.observed_at is null or
  w.observed_at not between clock_timestamp()-interval '20 seconds'and clock_timestamp()+interval '5 seconds'or
  r.maximum_expires_at<>r.created_at+interval '600 seconds'or r.expires_at<>r.maximum_expires_at
 then raise exception 'recovery_archive_authority_unavailable'using errcode='42501';end if;
 return w;
end $$;

create function public.noop_recovery_archive_claim(p_run uuid,p_process uuid,p_instance uuid,p_source_revision text,p_image_digest text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;w public.noop_recovery_archive_workers;o public.physiology_archive_outbox;s public.server_physiology_results;
 used_wire bigint;used_decoded bigint;slots bigint;n bigint;token uuid:=gen_random_uuid();queue_token uuid:=gen_random_uuid();expires timestamptz;
begin
 w:=public.noop_recovery_archive_validate(p_run,p_process);
 select * into strict r from public.noop_recovery_runs where id=p_run;
 if w.instance_id is distinct from p_instance or w.source_revision is distinct from p_source_revision or w.image_digest is distinct from p_image_digest
 then raise exception 'recovery_archive_worker_mismatch'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('bounded-recovery-capacity-v1',0));
 update public.noop_recovery_archive_workers set last_poll_at=clock_timestamp()where run_id=p_run;
 if public.noop_recovery_has_turn(p_run,'archive')is false then return null;end if;
 select coalesce(sum(wire_bytes),0),coalesce(sum(decoded_bytes),0),coalesce(sum(download_slots),0),count(*)into used_wire,used_decoded,slots,n from public.noop_recovery_attempts where released_at is null;
 if n>=4 or slots>=2 or used_wire+2097152>r.wire_limit or used_decoded+8388608>r.decoded_limit or r.expires_at<=clock_timestamp()+interval '40 seconds'or
  exists(select 1 from public.noop_recovery_attempts where lane='archive'and released_at is null)then return null;end if;
 select a.* into o from public.physiology_archive_outbox a join public.server_physiology_results x using(user_id,device_id,period_day,algorithm_version,input_revision)
  where a.user_id=r.user_id and a.device_id=r.device_id and a.algorithm_version='frwhoop-server-1'and a.status<>'verified'and a.next_attempt_at<=clock_timestamp()
   and(a.lease_expires_at is null or a.lease_expires_at<=clock_timestamp())and octet_length(x.payload::text)<=2097152
   and not exists(select 1 from public.noop_recovery_attempts t where t.archive_outbox_id=a.id and t.released_at is null)
  order by a.next_attempt_at,a.id for update of a skip locked limit 1;
 if not found then return null;end if;
 select * into strict s from public.server_physiology_results where user_id=o.user_id and device_id=o.device_id and period_day=o.period_day and algorithm_version=o.algorithm_version and input_revision=o.input_revision;
 if s.payload->>'user_id'is distinct from o.user_id::text or s.payload->>'device_id'is distinct from o.device_id::text or s.payload->>'day'is distinct from o.period_day::text or s.payload->>'algorithm_version'is distinct from o.algorithm_version or s.payload->>'input_revision'is distinct from o.input_revision::text or s.payload_hash<>encode(sha256(convert_to(s.payload::text,'UTF8')),'hex')or o.object_key not like '%/'||s.payload_hash||'.json.zst'
 then raise exception 'recovery_archive_immutable_identity_mismatch'using errcode='42501';end if;
 expires:=clock_timestamp()+interval '40 seconds';
 update public.physiology_archive_outbox set status='uploading',lease_token=queue_token,lease_expires_at=expires,attempts=attempts+1 where id=o.id;
 insert into public.noop_recovery_attempts(token,run_id,process_id,instance_id,lane,score_day,queue_token,lease_until,wire_bytes,decoded_bytes,download_slots,historical,archive_outbox_id)
  values(token,p_run,p_process,p_instance,'archive',o.period_day,queue_token,expires,2097152,8388608,1,o.period_day<current_date,o.id);
 return jsonb_build_object('token',token,'outbox_id',o.id,'lease_token',queue_token,'object_key',o.object_key,'input_revision',o.input_revision,'period_day',o.period_day,'payload_text',s.payload::text,'payload_hash',s.payload_hash,'wire_limit',2097152,'decoded_limit',8388608,'lease_until',expires);
end $$;

create function public.noop_recovery_archive_assert(p_run uuid,p_process uuid,p_token uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare w public.noop_recovery_archive_workers;a public.noop_recovery_attempts;r public.noop_recovery_runs;
begin
 w:=public.noop_recovery_archive_validate(p_run,p_process);a:=public.noop_recovery_assert_attempt(p_run,p_process,p_token);
 select * into strict r from public.noop_recovery_runs where id=p_run;
 if a.lane<>'archive'or a.instance_id is distinct from w.instance_id or a.wire_bytes<>2097152 or a.decoded_bytes<>8388608 or a.download_slots<>1 or
  not exists(select 1 from public.physiology_archive_outbox o join public.server_physiology_results s using(user_id,device_id,period_day,algorithm_version,input_revision)
   where o.id=a.archive_outbox_id and o.user_id=r.user_id and o.device_id=r.device_id and o.period_day=a.score_day and o.algorithm_version='frwhoop-server-1'and o.status='uploading'
   and o.lease_token=a.queue_token and o.lease_expires_at=a.lease_until and o.lease_expires_at>clock_timestamp()and octet_length(s.payload::text)<=2097152
   and s.payload->>'user_id'=o.user_id::text and s.payload->>'device_id'=o.device_id::text and s.payload->>'day'=o.period_day::text and s.payload->>'algorithm_version'=o.algorithm_version and s.payload->>'input_revision'=o.input_revision::text and s.payload_hash=encode(sha256(convert_to(s.payload::text,'UTF8')),'hex')and o.object_key like '%/'||s.payload_hash||'.json.zst')
 then raise exception 'recovery_archive_lease_or_scope_lost'using errcode='42501';end if;
 return true;
end $$;

create function public.noop_recovery_archive_finish(p_run uuid,p_process uuid,p_token uuid,p_compressed_sha256 text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.noop_recovery_attempts;o public.physiology_archive_outbox;
begin
 perform public.noop_recovery_archive_assert(p_run,p_process,p_token);
 select * into strict a from public.noop_recovery_attempts where token=p_token;
 select * into strict o from public.physiology_archive_outbox where id=a.archive_outbox_id for update;
 if p_compressed_sha256 is null or p_compressed_sha256!~'^[0-9a-f]{64}$'or not exists(select 1 from public.object_manifests m
  where m.object_key=o.object_key and m.user_id=o.user_id and m.device_id=o.device_id and m.period_day=o.period_day and m.algorithm_version=o.algorithm_version
   and m.object_class='derived'and m.object_kind='derived_scores'and m.provider='b2'and m.status='ready'and m.sha256_source='server_verified'and m.sha256=p_compressed_sha256
   and m.compressed_bytes between 1 and a.wire_bytes and m.format='json_zstd_frwhoop_derived_v2'and m.compression='zstd'and m.verified_at>=a.started_at)
 then raise exception 'recovery_archive_verified_manifest_required'using errcode='42501';end if;
 update public.physiology_archive_outbox set status='verified',content_sha256=p_compressed_sha256,last_error=null,uploaded_at=clock_timestamp(),verified_at=clock_timestamp(),
  next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(attempts,7)))::int),lease_token=null,lease_expires_at=null where id=o.id;
 update public.noop_recovery_attempts set released_at=clock_timestamp(),outcome='complete'where token=p_token;
 return true;
end $$;

create function public.noop_recovery_archive_confirm_stopped(p_run uuid,p_supervisor uuid,p_instance uuid,p_container text)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;w public.noop_recovery_archive_workers;n integer;
begin
 if auth.role()is distinct from 'service_role'and session_user<>'postgres'then raise exception 'recovery_role_denied'using errcode='42501';end if;
 select * into strict r from public.noop_recovery_runs where id=p_run for update;
 select * into strict w from public.noop_recovery_archive_workers where run_id=p_run for update;
 if p_supervisor is distinct from r.supervisor_token or p_instance is distinct from w.instance_id or p_container is distinct from w.container_id
 then raise exception 'recovery_archive_stop_identity_mismatch'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('bounded-recovery-capacity-v1',0));
 update public.physiology_archive_outbox o set status='failed',last_error='supervised_archive_process_stopped',next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(o.attempts,7)))::int),lease_token=null,lease_expires_at=null
  from public.noop_recovery_attempts a where a.run_id=p_run and a.instance_id=p_instance and a.lane='archive'and a.released_at is null and o.id=a.archive_outbox_id and o.lease_token=a.queue_token;
 update public.noop_recovery_attempts set released_at=clock_timestamp(),outcome='supervised_archive_process_stopped'where run_id=p_run and instance_id=p_instance and lane='archive'and released_at is null;
 get diagnostics n=row_count;
 update public.noop_recovery_archive_workers set state='stopped',observed_at=null where run_id=p_run;
 return n;
end $$;

create function public.noop_recovery_archive_status(p_run uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.noop_recovery_runs;
begin
 r:=public.noop_recovery_validate(p_run,false);
 return jsonb_build_object('worker',(select to_jsonb(w)from public.noop_recovery_archive_workers w where run_id=p_run),
  'pending',(select count(*)from public.physiology_archive_outbox where user_id=r.user_id and device_id=r.device_id and algorithm_version='frwhoop-server-1'and status<>'verified'),
  'completed',(select count(*)from public.noop_recovery_attempts where run_id=p_run and lane='archive'and outcome='complete'),
  'captured_at',clock_timestamp());
end $$;

do $$declare f record;begin
 for f in select oid::regprocedure signature from pg_proc where pronamespace='public'::regnamespace and proname like 'noop_recovery_archive_%'loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
revoke all on function public.noop_recovery_archive_validate(uuid,uuid)from service_role;
notify pgrst,'reload schema';
commit;
