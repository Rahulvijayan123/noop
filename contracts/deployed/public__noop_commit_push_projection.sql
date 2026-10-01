-- Deployed definition for public.noop_commit_push_projection
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:15.195814
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_commit_push_projection';"
CREATE OR REPLACE FUNCTION public.noop_commit_push_projection(p_object_id uuid, p_body_sha256 text, p_header jsonb, p_rows jsonb, p_keep_keys jsonb, p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare m public.object_manifests;
begin
  select * into m from public.object_manifests where id=p_object_id;
  if not found or public.noop_current_object_receipt(m.user_id,m.id) is null then
    raise exception 'projection_archive_mismatch';
  end if;
  if m.auth_mode='installation' then
    perform 1 from public.noop_app_installations where user_id=m.user_id and source_id=m.source_id
      and revoked_at is null and retired_at is null for share;
    if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  end if;
  return public.noop_commit_push_projection_intake_core(p_object_id,p_body_sha256,p_header,p_rows,p_keep_keys,p_token);
end $function$

