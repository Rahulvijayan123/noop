-- Deployed definition for public.claim_scoring_archive_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:30.910540
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='claim_scoring_archive_v2';"
CREATE OR REPLACE FUNCTION public.claim_scoring_archive_v2(p_seconds integer DEFAULT 300)
 RETURNS TABLE(result_revision bigint, object_key text, lease_token uuid, payload_text text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rev bigint;
begin
  if p_seconds<1 or p_seconds>3600 then raise exception 'invalid_lease'; end if;
  select a.result_revision into rev from scoring_archive_jobs_v2 a
    where a.completed_at is null and not a.dead_letter and a.not_before<=clock_timestamp()
      and (a.lease_until is null or a.lease_until<=clock_timestamp())
    order by a.not_before,a.result_revision for update skip locked limit 1;
  if not found then return; end if;
  return query with claimed as (
    update scoring_archive_jobs_v2 a set lease_token=gen_random_uuid(),lease_until=clock_timestamp()+make_interval(secs=>p_seconds)
    where a.result_revision=rev returning a.*)
    select c.result_revision,c.object_key,c.lease_token,s.payload::text from claimed c
      join scoring_snapshots_v2 s on s.result_revision=c.result_revision;
end $function$

