-- Deployed definition for public.server_scoring_for_day
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:34.269977
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='server_scoring_for_day';"
CREATE OR REPLACE FUNCTION public.server_scoring_for_day(p_user uuid, p_day date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select public.server_scoring_read_contract(p_user,p_day,null)
$function$

