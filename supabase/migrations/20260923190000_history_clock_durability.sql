-- Keep unassignable clocks in raw storage. An absent calendar bound is not a
-- replacement timestamp and must never enqueue a fabricated measurement day.
begin;

create or replace function public.scoring_timestamp_v3(p_time text) returns timestamptz
language plpgsql stable set search_path=pg_catalog,public as $$
declare observed timestamptz;
begin
  observed:=case when p_time ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(p_time::double precision)
    else p_time::timestamptz end;
  if observed is null or not isfinite(observed) then return null; end if;
  -- The existing readers need timezone offset and UTC-1..UTC+3 context. Reject
  -- only PostgreSQL's representational edge, not an arbitrary historical date.
  perform (observed at time zone 'UTC')-interval '2 days';
  perform (observed at time zone 'UTC')+interval '4 days';
  return observed;
exception when datetime_field_overflow or numeric_value_out_of_range or invalid_datetime_format
  or invalid_text_representation then
  return null;
end $$;

create or replace function public.invalidate_scoring_history_stream_v3() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare source_sql text; query text; r record; v record;
begin
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) b from new_rows n';
  else source_sql:='select to_jsonb(o) b from old_rows o'; end if;
  query:='with observed as materialized (
    select (b->>''user_id'')::uuid u,(b->>''device_id'')::uuid dev,
      (public.scoring_timestamp_v3(b->>'||quote_literal(TG_ARGV[0])||') at time zone ''UTC'')::date first_day,
      (public.scoring_timestamp_v3(coalesce(b->>'||quote_literal(TG_ARGV[1])||',b->>'||quote_literal(TG_ARGV[0])||')) at time zone ''UTC'')::date last_day
    from ('||source_sql||') changed
  ), spans as (
    select u,dev,first_day,last_day from observed
      where first_day is not null and last_day is not null and first_day<=last_day
    union all select u,dev,first_day,first_day from observed
      where first_day is not null and (last_day is null or first_day>last_day)
    union all select u,dev,last_day,last_day from observed
      where last_day is not null and (first_day is null or first_day>last_day)
  ) select u,dev,first_day-1 lo,max(last_day)+3 hi
    from spans group by u,dev,first_day order by u,dev,first_day';
  for r in execute query loop
    if r.lo is null or r.hi is null or r.lo>r.hi then continue; end if;
    if not exists(select 1 from public.devices where id=r.dev and user_id=r.u) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||r.u,0));
    for v in select a.algorithm_version from public.scoring_history_algorithms_v3 a
      join public.scoring_algorithms_v2 b using(algorithm_version) where b.enabled loop
      -- One initial day fences publication immediately. A true long interval
      -- remains complete durable debt for the existing bounded expander; distinct
      -- scalar days never become one continuous interval across their gaps.
      perform public.enqueue_scoring_v2(r.u,r.dev,r.lo,v.algorithm_version,'historical_timezone_raw_correction');
      insert into public.scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
        values(r.u,r.dev,v.algorithm_version,r.lo,r.hi,'historical_timezone_raw_correction');
    end loop;
  end loop;
  return null;
end $$;

commit;
