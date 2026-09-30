-- The set-based projection referenced its typed row as a bare x, which resolves to a column before a
-- relation alias; noop_gravity_samples has a column x, so every gravitySample batch failed (42809). The
-- whole row is now only reached through qualified subquery columns (s.x, i.x). No other change.
begin;

create or replace function public.noop_project_append_batch(p_user uuid,p_device uuid,p_source uuid,p_batch uuid,
  p_stream text,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare target text; keys text[]; predicate text; work jsonb; accepted jsonb; doomed jsonb; clock_ts bigint[];
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
  if exists(select 1 from jsonb_array_elements(p_rows) r where jsonb_typeof(r)<>'object'
      or (r->>'user_id')::uuid is distinct from p_user or (r->>'device_id')::uuid is distinct from p_device
      or (r->>'source_id')::uuid is distinct from p_source or (r->>'batch_id')::uuid is distinct from p_batch) then
    raise exception 'append row identity mismatch' using errcode='42501';
  end if;
  if exists(select 1 from (select distinct k from jsonb_array_elements(p_rows) r cross join lateral jsonb_object_keys(r) k) s
      where not exists(select 1 from pg_catalog.pg_attribute a where a.attrelid=to_regclass('public.'||target)
        and a.attname=s.k and a.attnum>0 and not a.attisdropped)) then
    raise exception 'unknown append column' using errcode='22023';
  end if;
  -- Null typed keys never match the equality lookup and are rejected below, before any write.
  select string_agg(format('t.%1$I = (i.x).%1$I',k),' and ') into predicate from unnest(keys) k;
  -- One pass: typed row, identity, indexed prior lookup, and a verdict per row. Only supplied, typed
  -- measurement columns are compared, never receipt metadata/default timestamps.
  execute format($q$
    with i as materialized (
      select s.o,s.r,s.x,to_jsonb(s.x) typed from (select e.o,e.r,jsonb_populate_record(null::public.%1$I,e.r) x
        from jsonb_array_elements($1) with ordinality e(r,o) offset 0) s)
    select coalesce(jsonb_agg(jsonb_build_object('o',i.o,'r',i.r,'k',k.k,'ts',i.typed->'ts','pts',p.j->'ts','v',
      case when p.j is null then 'new' when d.diff is null then 'same'
        when $4='rrInterval' and d.diff<@array['srcChannel','ord']
          and (i.typed->>'srcChannel') is distinct from (p.j->>'srcChannel')
          and coalesce((i.typed->>'srcChannel')::integer,6) in (5,6,7)
          and coalesce((p.j->>'srcChannel')::integer,6) in (5,6,7) then
          case when g.rank>g.prior_rank then 'promote' when g.rank<g.prior_rank then 'stale' else 'conflict' end
        else 'conflict' end) order by i.o),'[]')
    from i
    cross join lateral (select jsonb_object_agg(c,i.typed->c) k from unnest($5::text[]) c) k
    left join lateral (select to_jsonb(t.*) j from public.%1$I t where t.user_id=$2 and t.device_id=$3 and %2$s limit 1) p on true
    cross join lateral (select case coalesce((i.typed->>'srcChannel')::integer,6) when 5 then 3 when 7 then 2 else 1 end rank,
      case coalesce((p.j->>'srcChannel')::integer,6) when 5 then 3 when 7 then 2 else 1 end prior_rank) g
    left join lateral (select array_agg(c) diff from jsonb_object_keys(i.r) c
      where p.j is not null and c<>all(array['source_id','batch_id','ingested_at']) and p.j->c is distinct from i.typed->c
        and not ($4='rrPacketProvenance' and c='rawHex'
          and public.noop_same_rr_payload(p.j->>'rawHex',i.typed->>'rawHex',i.typed->>'packetId'))) d on true
  $q$,target,predicate) into work using p_rows,p_user,p_device,p_stream,keys;
  if exists(select 1 from jsonb_array_elements(work) w cross join lateral jsonb_each(w->'k') e where e.value='null') then
    raise exception 'null measurement identity' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(work) w group by w->'k' having count(distinct w->'r')>1)
    or exists(select 1 from jsonb_array_elements(work) w join public.noop_projection_observations o
      on o.user_id=p_user and o.source_id=p_source and o.batch_id=p_batch and o.stream=p_stream
        and o.measurement_key=w->'k'
      where o.row_data is distinct from w->'r' and not (o.row_data-'device_id'=(w->'r')-'device_id'
        and exists(select 1 from public.noop_wearable_aliases a where a.user_id=p_user
          and a.provisional_device_id=(o.row_data->>'device_id')::uuid and a.canonical_device_id=p_device))) then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  -- Identical duplicates are one observation; the first occurrence keeps its position.
  select jsonb_agg(w order by (w->>'o')::bigint) into work from (select distinct on (w->'k') w
    from jsonb_array_elements(work) w order by w->'k',(w->>'o')::bigint) u;
  insert into public.noop_projection_observations(user_id,device_id,source_id,batch_id,stream,measurement_key,row_data)
    select p_user,p_device,p_source,p_batch,p_stream,w->'k',w->'r' from jsonb_array_elements(work) w
      order by (w->>'o')::bigint
    on conflict do nothing;
  insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key)
    select p_user,p_device,p_stream,w->'k' from jsonb_array_elements(work) w where w->>'v'='conflict'
    on conflict do nothing;
  if p_stream='rrPacketProvenance' then
    select array_agg(distinct t) into clock_ts from jsonb_array_elements(work) w
      cross join lateral unnest(array[(w->>'pts')::bigint,(w->>'ts')::bigint]) t
      where t is not null and exists(select 1 from public.noop_projection_conflicts c where c.user_id=p_user
        and c.device_id=p_device and c.stream=p_stream and c.measurement_key=w->'k');
    if clock_ts is not null then
      insert into public.noop_rr_clock_conflicts(user_id,device_id,ts)
        select p_user,p_device,t from unnest(clock_ts) t on conflict do nothing;
      delete from public.noop_rr_intervals where user_id=p_user and device_id=p_device and ts=any(clock_ts);
    end if;
  end if;
  if p_stream='rrInterval' then
    insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key,reason)
      select p_user,p_device,p_stream,w->'k','packet_clock_or_bytes_disagreement' from jsonb_array_elements(work) w
      where exists(select 1 from public.noop_rr_clock_conflicts c where c.user_id=p_user and c.device_id=p_device
        and c.ts=(w->>'ts')::bigint)
      on conflict do nothing;
  end if;
  select jsonb_agg(w) filter (where c.measurement_key is not null),
      jsonb_agg(w->'r' order by (w->>'o')::bigint) filter (where c.measurement_key is null and w->>'v' in ('new','promote'))
    into doomed,accepted
    from jsonb_array_elements(work) w left join public.noop_projection_conflicts c
      on c.user_id=p_user and c.device_id=p_device and c.stream=p_stream and c.measurement_key=w->'k';
  if doomed is not null then
    execute format('delete from public.%1$I t using (select jsonb_populate_record(null::public.%1$I,w->''r'') x
      from jsonb_array_elements($1) w) i where t.user_id=$2 and t.device_id=$3 and %2$s',target,predicate)
      using doomed,p_user,p_device;
  end if;
  if accepted is not null then
    perform public.noop_project_append_batch_core(p_user,p_device,p_source,p_batch,p_stream,accepted);
  end if;
  return jsonb_array_length(p_rows);
end $$;

notify pgrst, 'reload schema';
commit;
