-- Deployed definition for public.claim_scoring_v2
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:28.942071
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='claim_scoring_v2';"
CREATE OR REPLACE FUNCTION public.claim_scoring_v2(p_version text, p_lease_seconds integer DEFAULT 300)
 RETURNS SETOF scoring_jobs_v2
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if exists(select 1 from scoring_history_algorithms_v3 where algorithm_version=p_version) then return; end if;
  return query select * from internal.claim_scoring_v2(p_version,p_lease_seconds);
end $function$

