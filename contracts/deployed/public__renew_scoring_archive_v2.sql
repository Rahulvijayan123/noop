-- Deployed definition for public.renew_scoring_archive_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:32.226039
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='renew_scoring_archive_v2';"
CREATE OR REPLACE FUNCTION public.renew_scoring_archive_v2(p_token uuid, p_seconds integer DEFAULT 300)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_seconds<1 or p_seconds>3600 then raise exception 'invalid_lease'; end if;
  update scoring_archive_jobs_v2 set lease_until=clock_timestamp()+make_interval(secs=>p_seconds)
    where lease_token=p_token and lease_until>clock_timestamp() and completed_at is null;
  return found;
end $function$

