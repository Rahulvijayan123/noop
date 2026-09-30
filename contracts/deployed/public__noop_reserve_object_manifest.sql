-- Deployed definition for public.noop_reserve_object_manifest
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:24.227397
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_reserve_object_manifest';"
CREATE OR REPLACE FUNCTION public.noop_reserve_object_manifest(p_manifest jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p public.object_manifests; v public.object_manifests;
  b public.noop_object_batch_identities;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  p:=jsonb_populate_record(null::public.object_manifests,p_manifest);
  if p.batch_id is null or p.user_id is null then raise exception 'invalid_object_manifest' using errcode='22023'; end if;
  if not exists(select 1 from public.devices where id=p.device_id and user_id=p.user_id) then
    raise exception 'device_owner_conflict' using errcode='42501';
  end if;
  -- The primary key serializes first admission across Edge isolates, including conflicting
  -- digests, sources and canonical devices. The existing inner RPC retains lifecycle fences.
  insert into public.noop_object_batch_identities(user_id,batch_id,first_object_id,logical_identity,auth_mode)
    values(p.user_id,p.batch_id,p.id,public.noop_object_logical_identity(p),coalesce(p.auth_mode,'legacy_fleet'))
    on conflict(user_id,batch_id) do nothing;
  select * into b from public.noop_object_batch_identities
    where user_id=p.user_id and batch_id=p.batch_id for update;
  if p.id<>b.first_object_id and (b.logical_identity is distinct from public.noop_object_logical_identity(p)
      or b.auth_mode is distinct from coalesce(p.auth_mode,'legacy_fleet')) then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  v:=jsonb_populate_record(null::public.object_manifests,public.noop_reserve_object_manifest_representation_core(p_manifest));
  -- Only the original object can complete legacy nullable metadata, through the original
  -- exact-object checks. A new representation cannot supply missing old provenance.
  if p.id=b.first_object_id then
    update public.noop_object_batch_identities set logical_identity=public.noop_object_logical_identity(v),
      auth_mode=coalesce(v.auth_mode,'legacy_fleet') where user_id=p.user_id and batch_id=p.batch_id;
  end if;
  return to_jsonb(v);
end $function$

