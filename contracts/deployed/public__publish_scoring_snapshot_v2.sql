-- Deployed definition for public.publish_scoring_snapshot_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:29.823940
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='publish_scoring_snapshot_v2';"
CREATE OR REPLACE FUNCTION public.publish_scoring_snapshot_v2(p_token uuid, p_revision bigint, p_payload jsonb, p_duration_ms bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j scoring_jobs_v2; rev bigint; payload jsonb; computed timestamptz; owner_id uuid; n jsonb;
begin
  select user_id into owner_id from scoring_jobs_v2 where lease_token=p_token;
  if not found then return null; end if;
  -- Linearize range invalidations/config changes with publication BEFORE taking the job lock.
  perform pg_advisory_xact_lock_shared(hashtextextended('scoring-inputs-v2:'||owner_id,0));
  select * into j from scoring_jobs_v2 where lease_token=p_token for update;
  if not found or j.lease_until<=clock_timestamp() or j.input_revision<>p_revision then return null; end if;
  if not exists(select 1 from scoring_algorithms_v2 where algorithm_version=j.algorithm_version and enabled) then return null; end if;
  if exists(select 1 from scoring_invalidations_v2 i where i.user_id=j.user_id and i.device_id=j.device_id
    and i.algorithm_version=j.algorithm_version and j.day between i.next_day and i.through_day) then return null; end if;
  if jsonb_typeof(p_payload->'sleep') is distinct from 'array'
    or jsonb_typeof(p_payload->'coverage') is distinct from 'object'
    or coalesce(jsonb_typeof(p_payload->'daily'),'missing') not in ('object','null')
    or not (p_payload ? 'daily' and p_payload ? 'dataThrough' and p_payload ? 'timezone')
    or coalesce(p_payload->>'status','') not in ('available','partial','no_data') then
    raise exception 'invalid_snapshot_contract';
  end if;
  perform 1 from pg_timezone_names where name=p_payload->>'timezone';
  if not found then raise exception 'invalid_snapshot_timezone'; end if;
  perform (p_payload->>'dataThrough')::timestamptz;
  for n in select value from jsonb_array_elements(p_payload->'sleep') loop
    if jsonb_typeof(n->'stages') is distinct from 'array'
      or n->>'id' is null or n->>'start_at' is null or n->>'end_at' is null
      or (n->>'end_at')::timestamptz <= (n->>'start_at')::timestamptz then
      raise exception 'invalid_snapshot_sleep';
    end if;
  end loop;
  computed:=clock_timestamp();
  -- Allocate the server revision before constructing the immutable payload.
  rev:=nextval(pg_get_serial_sequence('public.scoring_snapshots_v2','result_revision'));
  payload:=p_payload || jsonb_build_object('schemaVersion',2,'userId',j.user_id,
    'sourceDeviceId',j.device_id,'day',j.day,'algorithmVersion',j.algorithm_version,
    'inputRevision',p_revision,'resultRevision',rev,'computedAt',computed);
  insert into scoring_snapshots_v2 overriding system value
    values(rev,j.user_id,j.device_id,j.day,j.algorithm_version,p_revision,computed,payload);
  insert into scoring_archive_jobs_v2(result_revision,object_key)
    values(rev,'v3/derived/users/'||j.user_id||'/devices/'||j.device_id||'/days/'||j.day||'/'||
      j.algorithm_version||'/revisions/'||rev||'.json');
  update scoring_jobs_v2 set completed_revision=p_revision,lease_token=null,lease_until=null,
    consecutive_failures=0,dead_letter=false,last_error=null,last_completed_at=computed,
    last_duration_ms=greatest(0,p_duration_ms),success_count=success_count+1
  where user_id=j.user_id and device_id=j.device_id and day=j.day and algorithm_version=j.algorithm_version;
  perform refresh_scoring_legacy_v2(j.user_id,j.day,j.algorithm_version);
  return rev;
end $function$

