begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- Operator inventory is deliberately independent of phone result discovery. It
-- enumerates retained identities, including holes, without treating a PUT or an
-- old verification receipt as current worker read access.
create function public.noop_history_inventory_page(p_user uuid,p_device uuid,
  p_after uuid default null,p_limit integer default 32,p_before timestamptz default now()) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare rows jsonb; last_id uuid; more boolean;
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  if p_limit is null or p_limit<1 or p_limit>64 or p_before is null or p_before>clock_timestamp() then
    raise exception 'invalid_history_limit' using errcode='22023'; end if;
  with page as materialized (
    select m.* from public.object_manifests m
    where m.user_id=p_user and m.device_id=p_device and m.object_class='raw'
      and m.created_at<=p_before and (p_after is null or m.id>p_after) order by m.id limit p_limit
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'object',to_jsonb(m),'projection_state',d.state,'projection_error',d.last_error,
    'raw_readability','NOT_MEASURED','affected_days',coalesce((
      select jsonb_agg(jsonb_build_object('day',a.day,'timezone',a.timezone_id,
        'queue_revision',q.input_revision,'queue_status',q.status,'queue_error',q.last_error,
        'oldest_debt_at',case when q.done_at is null then q.dirty_at end,
        'published_revision',r.input_revision,'payload_hash',r.payload_hash,
        'archive_state',case when o.status='verified' and o.verified_at is not null then 'settled'
          when o.id is not null then o.status else 'absent' end,
        'state',case
          when m.status in ('deleted','deleting','expired') then 'missing_source'
          when m.durability_receipt is null then 'local_or_verification_pending'
          when m.format like 'ndjson%' and d.state is distinct from 'complete' then 'projection_pending'
          when r.input_revision is not null and r.input_revision<q.input_revision then 'published_older_revision'
          when r.input_revision is not null then 'computed_publication_requires_qualification'
          when q.status='waiting' then 'insufficient_input'
          when q.status in ('failed','retry','exhausted') then 'computation_failed'
          when q.input_revision is not null then 'queued'
          else 'projected_not_queued' end) order by a.day,a.timezone_id)
      from public.scoring_affected_days(p_user,extract(epoch from m.start_at)::bigint,extract(epoch from m.end_at)::bigint) a
      left join public.scoring_work_items q on q.user_id=p_user and q.device_id=p_device and q.day=a.day
      left join lateral (select sr.input_revision,sr.payload_hash from public.server_physiology_results sr
        where sr.user_id=p_user and sr.device_id=p_device and sr.period_day=a.day
          and sr.algorithm_version='frwhoop-server-1' order by sr.input_revision desc limit 1) r on true
      left join public.physiology_archive_outbox o on o.user_id=p_user and o.device_id=p_device
        and o.period_day=a.day and o.algorithm_version='frwhoop-server-1' and o.input_revision=r.input_revision
    ),'[]'::jsonb)) order by m.id),'[]'::jsonb),max(m.id::text)::uuid into rows,last_id
    from page m left join public.noop_projection_debt d on d.object_id=m.id;
  more:=last_id is not null and exists(select 1 from public.object_manifests m where m.user_id=p_user
    and m.device_id=p_device and m.object_class='raw' and m.created_at<=p_before and m.id>last_id);
  return jsonb_build_object('schema_version',1,'user_id',p_user,'device_id',p_device,
    'algorithm_version','frwhoop-server-1','feature_selection',(select jsonb_object_agg(f.feature,
      coalesce(s.algorithm_version,f.algorithm_version)) from public.physiology_feature_defaults f
      left join public.physiology_source_selection s on s.feature=f.feature and s.user_id=p_user and s.device_id=p_device),
    'items',rows,'inventory_cutoff',p_before,'observed_at',clock_timestamp(),'next_cursor',case when more then last_id end,
    'scan_complete',not more,'local_inventory','NOT_MEASURED','phone_readback','NOT_MEASURED');
end $$;

-- Repair only missing queue authority for an exact retained, verified and already
-- projected object. Existing waiting/exhausted/running work and publications are
-- preserved. Repeating the request never advances an existing input revision.
create function public.noop_history_requeue_object(p_user uuid,p_device uuid,p_object uuid,p_receipt uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests; a record; n integer:=0;
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  if p_object is null or p_receipt is null then raise exception 'history_receipt_required' using errcode='22023'; end if;
  perform public.scoring_lock_device(p_user,p_device);
  select * into m from public.object_manifests where id=p_object and user_id=p_user and device_id=p_device for share;
  if not found or m.status not in ('ready','verified') or m.sha256_source is distinct from 'server_verified'
    or m.verified_at is null or m.indexed_at is null
    or m.durability_receipt->>'state' is distinct from 'verified_indexed'
    or m.durability_receipt->>'receiptId' is distinct from p_receipt::text
    or m.durability_receipt->>'ownerUserId' is distinct from p_user::text
    or m.durability_receipt->>'deviceId' is distinct from p_device::text
    or m.durability_receipt->>'objectId' is distinct from p_object::text
    or m.durability_receipt->>'objectKey' is distinct from m.object_key
    or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id
      and w.user_id=p_user and w.device_id=p_device and w.object_key=m.object_key)
    or (m.format like 'ndjson%' and not exists(select 1 from public.noop_projection_debt d
      where d.object_id=m.id and d.user_id=p_user and d.device_id=p_device and d.state='complete'))
    or (m.auth_mode='installation' and not exists(select 1 from public.noop_app_installations i
      where i.source_id=m.source_id and i.user_id=p_user and i.revoked_at is null and i.retired_at is null))
    or (m.source_id is not null and exists(select 1 from public.noop_app_installations i
      where i.source_id=m.source_id and (i.user_id<>p_user or i.revoked_at is not null or i.retired_at is not null))) then
    raise exception 'history_source_not_replayable' using errcode='42501';
  end if;
  for a in select * from public.scoring_affected_days(p_user,extract(epoch from m.start_at)::bigint,
      extract(epoch from m.end_at)::bigint) order by day,timezone_id loop
    if not exists(select 1 from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=a.day)
      and not exists(select 1 from public.server_physiology_results r where r.user_id=p_user and r.device_id=p_device
        and r.period_day=a.day and r.algorithm_version='frwhoop-server-1') then
      if (select count(*) from (select 1 from public.scoring_work_items q where q.user_id=p_user
        and q.device_id=p_device and q.done_at is null limit 1000) pending)>=1000 then
        raise exception 'history_recovery_capacity_deferred' using errcode='55P03';
      end if;
      perform public.scoring_enqueue_day(p_user,p_device,a.day,a.timezone_id,0);
      n:=n+1;
    end if;
  end loop;
  return jsonb_build_object('object_id',p_object,'receipt_id',p_receipt,'queued_days',n);
end $$;

revoke all on function public.noop_history_inventory_page(uuid,uuid,uuid,integer,timestamptz) from public,anon,authenticated;
revoke all on function public.noop_history_requeue_object(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.noop_history_inventory_page(uuid,uuid,uuid,integer,timestamptz) to service_role;
grant execute on function public.noop_history_requeue_object(uuid,uuid,uuid,uuid) to service_role;
commit;
