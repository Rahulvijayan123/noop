-- A retained JSON receipt alone cannot authorize projection. Match the existing
-- settlement predicate before assigning a turn or reserving projection capacity.
-- Legacy byte verification remains responsible for repairing stale receipt metadata.
-- No run, receipt, queue, settlement fence, or capacity limit is changed here.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

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
       and (d.lease_until is null or d.lease_until<=clock_timestamp())) and public.noop_current_object_receipt(o.user_id,o.id) is not null
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

create or replace function public.noop_recovery_claim(p_run uuid,p_process uuid,p_instance uuid,p_source_revision text,p_image_digest text,p_lane text)
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
      and (d.lease_until is null or d.lease_until<=clock_timestamp())) and public.noop_current_object_receipt(o.user_id,o.id) is not null
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

commit;
notify pgrst, 'reload schema';
