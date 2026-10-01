-- Preserve append semantics while indexing non-null measurement identity lookups.
begin;

create or replace function public.noop_project_append_batch(p_user uuid,p_device uuid,p_source uuid,p_batch uuid,
  p_stream text,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare target text; keys text[]; r jsonb; typed jsonb; identity jsonb; prior jsonb;
  predicate text; accepted jsonb:='[]'; old_observation jsonb; conflicted boolean;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select table_name,key_columns into target,keys from public.noop_projection_target(p_stream);
  if target is null or jsonb_typeof(p_rows) is distinct from 'array'
      or jsonb_array_length(p_rows) not between 1 and 5000 or p_batch is null then
    raise exception 'invalid append batch' using errcode='22023';
  end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found or not exists(select 1 from public.devices where user_id=p_user and id=p_device) then
    raise exception 'owned device and active installation required' using errcode='42501';
  end if;
  if exists(select 1 from public.noop_wearable_aliases where user_id=p_user and provisional_device_id=p_device) then
    raise exception 'device_identity_reconciled_retry' using errcode='PT409';
  end if;
  -- Shared input lock before the projection mutex; a scorer's snapshot never sees half a merge.
  if not pg_try_advisory_xact_lock_shared(hashtextextended('physiology-input:'||p_user||':'||p_device,230919)) then
    raise exception 'scoring_input_gate_busy' using errcode='55P03';
  end if;
  perform public.scoring_lock_device(p_user,p_device);
  -- Every typed key is rejected if null before predicate use; equality enables indexed lookup.
  select string_agg(format('t.%I = x.%I',k,k),' and ') into predicate from unnest(keys) k;
  for r in select value from jsonb_array_elements(p_rows) loop
    if (r->>'user_id')::uuid is distinct from p_user or (r->>'device_id')::uuid is distinct from p_device
      or (r->>'source_id')::uuid is distinct from p_source or (r->>'batch_id')::uuid is distinct from p_batch then
      raise exception 'append row identity mismatch' using errcode='42501';
    end if;
    if exists(select 1 from jsonb_object_keys(r) k where not exists(select 1 from pg_catalog.pg_attribute a
      where a.attrelid=to_regclass('public.'||target) and a.attname=k and a.attnum>0 and not a.attisdropped)) then
      raise exception 'unknown append column' using errcode='22023';
    end if;
    execute format('select to_jsonb(x.*) from jsonb_populate_record(null::public.%I,$1) x',target) into typed using r;
    select jsonb_object_agg(k,typed->k) into identity from unnest(keys) k;
    if exists(select 1 from jsonb_each(identity) e where e.value='null') then
      raise exception 'null measurement identity' using errcode='22023';
    end if;
    select row_data into old_observation from public.noop_projection_observations
      where user_id=p_user and source_id=p_source and batch_id=p_batch and stream=p_stream and measurement_key=identity;
    if found and old_observation is distinct from r and not (
      old_observation-'device_id'=r-'device_id' and exists(select 1 from public.noop_wearable_aliases
        where user_id=p_user and provisional_device_id=(old_observation->>'device_id')::uuid
          and canonical_device_id=p_device)) then
      raise exception 'batch_id_conflict' using errcode='23505';
    end if;
    insert into public.noop_projection_observations(user_id,device_id,source_id,batch_id,stream,measurement_key,row_data)
      values(p_user,p_device,p_source,p_batch,p_stream,identity,r) on conflict do nothing;
    execute format('select to_jsonb(t.*) from public.%I t,jsonb_populate_record(null::public.%I,$1) x
      where t.user_id=$2 and t.device_id=$3 and %s',target,target,predicate) into prior using r,p_user,p_device;
    -- Compare only the supplied, typed measurement columns, never receipt metadata/default timestamps.
    conflicted := prior is not null and exists(select 1 from jsonb_object_keys(r) k
      where k<>all(array['source_id','batch_id','ingested_at']) and prior->k is distinct from typed->k
        and not (p_stream='rrPacketProvenance' and k='rawHex'
          and public.noop_same_rr_payload(prior->>'rawHex',typed->>'rawHex',typed->>'packetId')));
    if conflicted then
      insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key)
        values(p_user,p_device,p_stream,identity) on conflict do nothing;
    end if;
    if p_stream='rrPacketProvenance' and exists(select 1 from public.noop_projection_conflicts
      where user_id=p_user and device_id=p_device and stream=p_stream and measurement_key=identity) then
      insert into public.noop_rr_clock_conflicts(user_id,device_id,ts)
        select p_user,p_device,t from unnest(array[(prior->>'ts')::bigint,(typed->>'ts')::bigint]) t
        where t is not null on conflict do nothing;
      delete from public.noop_rr_intervals where user_id=p_user and device_id=p_device
        and ts in ((prior->>'ts')::bigint,(typed->>'ts')::bigint);
    end if;
    if p_stream='rrInterval' and exists(select 1 from public.noop_rr_clock_conflicts
      where user_id=p_user and device_id=p_device and ts=(typed->>'ts')::bigint) then
      insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key,reason)
        values(p_user,p_device,p_stream,identity,'packet_clock_or_bytes_disagreement') on conflict do nothing;
    end if;
    if exists(select 1 from public.noop_projection_conflicts where user_id=p_user and device_id=p_device
      and stream=p_stream and measurement_key=identity) then
      execute format('delete from public.%I t using jsonb_populate_record(null::public.%I,$1) x
        where t.user_id=$2 and t.device_id=$3 and %s',target,target,predicate) using r,p_user,p_device;
    elsif prior is null then
      accepted:=accepted||jsonb_build_array(r);
    end if;
  end loop;
  if jsonb_array_length(accepted)>0 then
    perform public.noop_project_append_batch_core(p_user,p_device,p_source,p_batch,p_stream,accepted);
  end if;
  return jsonb_array_length(p_rows);
end $$;

notify pgrst, 'reload schema';
commit;
