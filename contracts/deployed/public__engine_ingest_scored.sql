-- Deployed definition for public.engine_ingest_scored
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:33.670480
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='engine_ingest_scored';"
CREATE OR REPLACE FUNCTION public.engine_ingest_scored(p_secret text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  raise exception 'token-aware baseline publication required' using errcode='42501';
end $function$

