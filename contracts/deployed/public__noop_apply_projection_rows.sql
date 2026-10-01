-- Deployed definition for public.noop_apply_projection_rows
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:16.559839
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_apply_projection_rows';"
CREATE OR REPLACE FUNCTION public.noop_apply_projection_rows(p_stream text, p_rows jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare first_row jsonb; owner uuid; source uuid; device uuid; batch uuid; part record;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'invalid_projection'; end if;
  if jsonb_array_length(p_rows)=0 then return; end if;
  first_row:=p_rows->0;
  owner:=(first_row->>'user_id')::uuid; source:=(first_row->>'source_id')::uuid;
  device:=(first_row->>'device_id')::uuid; batch:=(first_row->>'batch_id')::uuid;
  if exists(select 1 from public.noop_projection_target(p_stream))
      and exists(select 1 from public.noop_app_installations where source_id=source) then
    for part in select jsonb_agg(value order by ord) as rows
      from jsonb_array_elements(p_rows) with ordinality as x(value,ord)
      group by (ord-1)/5000 order by (ord-1)/5000 loop
      perform public.noop_project_append_batch(owner,device,source,batch,p_stream,part.rows);
    end loop;
  else
    perform public.noop_apply_projection_rows_intake_legacy(p_stream,p_rows);
  end if;
end $function$

