-- Deployed definition for public.noop_projection_coordinate
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:19.756013
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_projection_coordinate';"
CREATE OR REPLACE FUNCTION public.noop_projection_coordinate(p_stream text, p_row jsonb)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select case when p_stream in ('dailyMetric','journal') then ((p_row->>'day')::date-date '1970-01-01')::numeric*86400
    else extract(epoch from (p_row->>'start_at')::timestamptz) end
$function$

