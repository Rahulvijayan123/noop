-- Deployed definition for public.noop_commit_push_projection_intake_core
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:15.824138
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_commit_push_projection_intake_core';"
CREATE OR REPLACE FUNCTION public.noop_commit_push_projection_intake_core(p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
<<settlement>>
declare m public.object_manifests; d public.noop_projection_debt; r public.noop_push_reservations;
  ack jsonb; rows_to_apply jsonb:=p_rows; keys_to_keep jsonb:=p_keep_keys; w jsonb; part_count integer;
  stream text:=p_header->>'stream'; generation text; source text; window_identity jsonb; g record;
  generation_at timestamptz; window_start numeric; window_end numeric; later_windows nummultirange;
begin
  select * into m from public.object_manifests where id=p_object_id;
  if not found or m.status not in ('ready','verified') or m.format not like 'ndjson%'
    or m.durability_receipt->>'state' is distinct from 'verified_indexed'
    or m.durability_receipt->>'contentSha256' is distinct from p_body_sha256
    or m.batch_id::text is distinct from p_header->>'batchId' or m.source_id::text is distinct from p_header->>'sourceId'
    or m.object_kind is distinct from stream or m.sample_count is distinct from (p_header->>'recordCount')::bigint
    or not exists(select 1 from public.devices where id=m.device_id and user_id=m.user_id)
    or not exists(select 1 from public.noop_signal_windows where object_id=m.id and object_key=m.object_key) then
    raise exception 'projection_archive_mismatch';
  end if;
  -- Same ordering as receipt publication's scoring trigger; serializes source-window settlement.
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||m.user_id,0));
  select * into r from public.noop_push_reservations where user_id=m.user_id and batch_id=m.batch_id for update;
  if not found or r.body_sha256<>p_body_sha256 or r.device_id<>m.device_id then raise exception 'batch_id_conflict'; end if;
  insert into public.noop_projection_debt(object_id,user_id,device_id,created_at)
    values(m.id,m.user_id,m.device_id,m.created_at) on conflict do nothing;
  select * into d from public.noop_projection_debt where object_id=m.id for update;
  if d.state in ('complete','staged') then
    select a.ack into ack from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id;
    if ack is not null then
      delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
      return ack;
    end if;
  end if;
  if p_token is not null and (d.lease_token is distinct from p_token or d.lease_until<=clock_timestamp()) then
    raise exception 'projection_lease_lost';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_typeof(p_keep_keys) is distinct from 'array'
    or exists(select 1 from jsonb_array_elements(p_rows) x where x->>'user_id' is distinct from m.user_id::text
      or coalesce(x->>'device_id',x->>'source_device_id') is distinct from m.device_id::text) then raise exception 'projection_owner_mismatch'; end if;
  if p_header->>'delivery'='replace_window' then
    w:=p_header->'window'; generation:=w->>'replacementId'; source:=p_header->>'sourceId';
    window_identity:=w-'part';
    if generation is null or coalesce((w->>'part')::integer,0)<1 or coalesce((w->>'parts')::integer,0)<1
      or (w->>'part')::integer>(w->>'parts')::integer or (w->>'parts')::integer>128
      or coalesce(w->>'selector','') not in ('day','startTs') or w->>'startInclusive' is null
      or w->>'endExclusive' is null then raise exception 'invalid_window'; end if;
    if (stream in ('dailyMetric','journal') and w->>'selector'<>'day')
      or (stream in ('sleepSession','workout') and w->>'selector'<>'startTs')
      or stream not in ('dailyMetric','journal','sleepSession','workout') then raise exception 'invalid_window'; end if;
    window_start:=case when w->>'selector'='day' then ((w->>'startInclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'startInclusive')::numeric end;
    window_end:=case when w->>'selector'='day' then ((w->>'endExclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'endExclusive')::numeric end;
    if window_end<=window_start or exists(select 1 from jsonb_array_elements(p_rows) x
      where public.noop_projection_coordinate(stream,x) is null
        or not(public.noop_projection_coordinate(stream,x)<@numrange(window_start,window_end,'[)'))) then
      raise exception 'projection_outside_window';
    end if;
    for g in select object_id,header from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation loop
      if ((g.header->'window')-'part') is distinct from window_identity then raise exception 'replacement_window_conflict'; end if;
      if g.object_id<>m.id and g.header->'window'->>'part'=w->>'part' then raise exception 'replacement_part_conflict'; end if;
    end loop;
    update public.noop_projection_debt set header=p_header,mapped_rows=p_rows,keep_keys=p_keep_keys where object_id=m.id;
    select count(*) into part_count from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
    if part_count=(w->>'parts')::integer then
      if (select sum(pg_column_size(mapped_rows)) from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
          and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation)>33554432 then
        raise exception 'replacement_projection_too_large';
      end if;
      select coalesce(jsonb_agg(x.row order by (q.header->'window'->>'part')::integer,x.ord),'[]') into rows_to_apply
        from public.noop_projection_debt q cross join lateral jsonb_array_elements(q.mapped_rows) with ordinality x(row,ord)
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(jsonb_agg(x.key),'[]') into keys_to_keep from public.noop_projection_debt q,
        lateral jsonb_array_elements(q.keep_keys) x(key) where q.user_id=m.user_id and q.device_id=m.device_id
          and q.header->>'stream'=stream and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select min(b.created_at) into generation_at from public.noop_projection_debt q
        join public.noop_push_reservations b on b.user_id=q.user_id and b.batch_id=q.object_id
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=settlement.stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(range_agg(numrange(c.window_start,c.window_end,'[)')),'{}'::nummultirange) into later_windows
        from public.noop_projection_replacements c where c.user_id=m.user_id and c.device_id=m.device_id and c.stream=settlement.stream
          and (c.accepted_at,c.replacement_id)>(generation_at,generation)
          and c.window_start<settlement.window_end and c.window_end>settlement.window_start;
      select coalesce(jsonb_agg(x),'[]') into rows_to_apply from jsonb_array_elements(rows_to_apply) x
        where not(public.noop_projection_coordinate(stream,x)<@later_windows);
      perform public.noop_apply_projection_rows(stream,rows_to_apply);
      if stream='dailyMetric' then
        delete from public.daily_metrics where user_id=m.user_id and source_device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? day::text)
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream='journal' then
        delete from public.noop_journal_entries where user_id=m.user_id and device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? (day::text||'|'||question))
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream in ('sleepSession','workout') then
        delete from public.sessions where user_id=m.user_id and device_id=m.device_id
          and kind=any(case when stream='sleepSession' then array['sleep'] else array['workout','manual_workout'] end)
          and start_at>=to_timestamp((w->>'startInclusive')::double precision)
          and start_at<to_timestamp((w->>'endExclusive')::double precision) and not(keys_to_keep ? external_id)
          and not(extract(epoch from start_at)<@later_windows);
      else raise exception 'unsupported_projection'; end if;
      insert into public.noop_projection_replacements(user_id,device_id,source_id,stream,replacement_id,accepted_at,window_start,window_end)
        values(m.user_id,m.device_id,source::uuid,stream,generation,generation_at,window_start,window_end) on conflict do nothing;
      update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),mapped_rows=null,keep_keys=null,
        lease_token=null,lease_until=null where user_id=m.user_id and device_id=m.device_id and header->>'stream'=stream
          and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
      delete from public.noop_push_staging_parts where user_id=m.user_id and replacement_id=generation
        and scope=m.user_id::text||'|'||source||'|'||(p_header->>'deviceId')||'|'||stream;
    else
      update public.noop_projection_debt set state='staged',lease_token=null,lease_until=null where object_id=m.id;
    end if;
  elsif p_header->>'delivery'='append' then
    perform public.noop_apply_projection_rows(stream,p_rows);
    update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),lease_token=null,lease_until=null,
      failures=0,last_error=null where object_id=m.id;
  else raise exception 'unsupported_delivery'; end if;
  ack:=jsonb_build_object('protocolVersion',p_header->>'protocolVersion','batchId',p_header->>'batchId',
    'stream',stream,'deviceId',p_header->>'deviceId','endCursor',p_header->'endCursor',
    'acceptedRows',(p_header->>'recordCount')::integer,'status','accepted','durabilityReceipt',m.durability_receipt);
  perform public.noop_push_save_ack(m.user_id,m.batch_id,p_body_sha256,ack);
  delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
  return ack;
end $function$

