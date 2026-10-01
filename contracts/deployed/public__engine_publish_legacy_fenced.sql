-- Deployed definition for public.engine_publish_legacy_fenced
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:28.361326
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='engine_publish_legacy_fenced';"
CREATE OR REPLACE FUNCTION public.engine_publish_legacy_fenced(p_secret text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return internal.engine_publish_legacy_fenced(p_secret,p_payload);
exception when serialization_failure then
  raise exception 'stale scoring lease or input revision' using errcode='PT409';
end $function$

