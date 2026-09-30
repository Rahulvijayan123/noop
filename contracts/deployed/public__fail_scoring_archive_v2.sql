-- Deployed definition for public.fail_scoring_archive_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:32.888267
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fail_scoring_archive_v2';"
CREATE OR REPLACE FUNCTION public.fail_scoring_archive_v2(p_token uuid, p_error text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update scoring_archive_jobs_v2 set consecutive_failures=consecutive_failures+1,
    dead_letter=consecutive_failures+1>=12,
    not_before=clock_timestamp()+make_interval(secs=>least(3600,5*power(2,least(consecutive_failures,10)))::integer),
    last_error=left(p_error,2000),lease_token=null,lease_until=null
    where lease_token=p_token and lease_until>clock_timestamp() and completed_at is null;
  return found;
end $function$

