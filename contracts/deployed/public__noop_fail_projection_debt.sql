-- Deployed definition for public.noop_fail_projection_debt
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:22.010395
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_fail_projection_debt';"
CREATE OR REPLACE FUNCTION public.noop_fail_projection_debt(p_object_id uuid, p_token uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  update public.noop_projection_debt set failures=least(failures+1,16),last_error='projection_replay_failed',
    not_before=clock_timestamp()+make_interval(secs=>least(3600,10*power(2,least(failures,8)))::integer),
    lease_token=null,lease_until=null
    where object_id=p_object_id and state='pending' and lease_token=p_token;
end $function$

