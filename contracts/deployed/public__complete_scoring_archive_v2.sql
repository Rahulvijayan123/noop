-- Deployed definition for public.complete_scoring_archive_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:31.498228
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='complete_scoring_archive_v2';"
CREATE OR REPLACE FUNCTION public.complete_scoring_archive_v2(p_token uuid, p_sha text, p_bytes bigint, p_bucket text, p_retention_days integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a scoring_archive_jobs_v2; s scoring_snapshots_v2;
begin
  select * into a from scoring_archive_jobs_v2 where lease_token=p_token for update;
  if not found or a.lease_until<=clock_timestamp() or a.completed_at is not null then return false; end if;
  if p_sha is null or p_bytes is null or p_bucket is null or p_retention_days is null
    or p_sha !~ '^[0-9a-f]{64}$' or p_bytes<=0 or p_retention_days<1 then raise exception 'invalid_archive_receipt'; end if;
  select * into s from scoring_snapshots_v2 where result_revision=a.result_revision;
  if p_bytes<>octet_length(convert_to(s.payload::text,'UTF8'))
    or p_sha<>encode(extensions.digest(convert_to(s.payload::text,'UTF8'),'sha256'),'hex') then
    raise exception 'archive_snapshot_mismatch';
  end if;
  insert into object_manifests(user_id,device_id,object_class,object_kind,provider,bucket,object_key,period_day,
    compressed_bytes,uncompressed_bytes,content_type,format,compression,sha256,sha256_source,algorithm_version,
    status,retention_class,expires_at,uploaded_at,verified_at)
  values(s.user_id,s.device_id,'derived','derived_scores','b2',p_bucket,a.object_key,s.day,
    p_bytes,p_bytes,'application/json','json_frwhoop_snapshot_v2','none',p_sha,'server_verified',s.algorithm_version,
    'ready','derived',clock_timestamp()+make_interval(days=>p_retention_days),clock_timestamp(),clock_timestamp())
  on conflict(object_key) do nothing;
  if not exists(select 1 from object_manifests where object_key=a.object_key and sha256=p_sha and compressed_bytes=p_bytes
    and user_id=s.user_id and device_id=s.device_id and bucket=p_bucket and status='ready'
    and format='json_frwhoop_snapshot_v2' and compression='none') then
    raise exception 'immutable_archive_conflict';
  end if;
  update scoring_archive_jobs_v2 set completed_at=clock_timestamp(),lease_token=null,lease_until=null,
    consecutive_failures=0,dead_letter=false,last_error=null,sha256=p_sha,byte_count=p_bytes
    where result_revision=a.result_revision;
  return true;
end $function$

