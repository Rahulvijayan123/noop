-- Add the source-scoped canonical account route without changing the legacy
-- (date,text) snapshot RPC or copying immutable publications into another store.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create function public.get_server_score_snapshot_v2(
  p_day date, p_source uuid, p_external_device_id text
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public as $$
declare
  owner uuid:=auth.uid();
  project constant text:='https://sgoyxzcagqyxexmsidtk.supabase.co';
  claims jsonb:=nullif(current_setting('request.jwt.claims',true),'')::jsonb;
  external text; scoped_external text; device uuid; matches integer;
  overlay jsonb; families jsonb;
  uuid_pattern constant text:='^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
begin
  if owner is null or auth.role() is distinct from 'authenticated' then
    raise exception 'ordinary_account_required' using errcode='42501';
  end if;
  if claims->>'iss' is distinct from project||'/auth/v1' then
    raise exception 'account_project_mismatch' using errcode='42501';
  end if;
  if p_day is null or p_day<'0001-01-01'::date or p_day>'9999-12-31'::date
    or p_source is null or p_source::text !~ uuid_pattern then
    raise exception 'invalid_day_or_source' using errcode='22023';
  end if;
  -- Match the existing Edge opaque-device validation and installation scoping.
  if p_external_device_id is null or p_external_device_id collate "C" !~ '^[ -~]{1,255}$'
    or (p_external_device_id !~* uuid_pattern and (
      position('@' in p_external_device_id)>0
      or regexp_replace(p_external_device_id,'[[:space:]-]','','g') ~ '^\+?[0-9]{7,}$')) then
    raise exception 'invalid_device_id' using errcode='22023';
  end if;
  external:=btrim(p_external_device_id);
  if external='' then raise exception 'invalid_device_id' using errcode='22023'; end if;

  if exists(select 1 from public.compute_account_sources where source_id=p_source and user_id<>owner)
    or exists(select 1 from public.noop_app_installations where source_id=p_source and user_id<>owner) then
    raise sqlstate 'PT403' using message='source_owner_mismatch';
  end if;
  if exists(select 1 from public.compute_account_sources where source_id=p_source and revoked_at is not null)
    or exists(select 1 from public.noop_app_installations where source_id=p_source and revoked_at is not null) then
    raise sqlstate 'PT401' using message='source_revoked';
  end if;
  if not exists(select 1 from public.compute_account_sources where source_id=p_source and user_id=owner)
    and not exists(select 1 from public.noop_app_installations where source_id=p_source and user_id=owner) then
    raise sqlstate 'PT401' using message='registered_source_required';
  end if;

  scoped_external:=case when external ~ '^whoop-[A-Z0-9-]{6,}$'
    and substring(external from 7) !~* uuid_pattern then external
    else 'installation:'||p_source::text||':'||external end;
  select count(*) into matches from public.devices
    where user_id=owner and source_kind='noop_push' and external_device_id=scoped_external;
  if matches>1 then raise sqlstate 'PT409' using message='ambiguous_device_identity'; end if;
  select id into device from public.devices
    where user_id=owner and source_kind='noop_push' and external_device_id=scoped_external;
  if device is not null then
    select coalesce((select canonical_device_id from public.noop_wearable_aliases
      where user_id=owner and provisional_device_id=device),device) into device;
    overlay:=public.server_scoring_for_device_day(owner,p_day,device);
  else
    overlay:=public.server_scoring_pending_contract(owner,p_day);
  end if;

  -- Share selection, revision withdrawal, eligibility, and manifest checks with
  -- the enrollment route. These are envelope annotations, not new result bytes.
  if jsonb_typeof(overlay->'compute')='object' then
    select coalesce(jsonb_object_agg(key,value||jsonb_build_object(
      'project',project,'source_id',p_source)),'{}'::jsonb)
      into families from jsonb_each(overlay#>'{compute,families}');
    overlay:=jsonb_set(overlay,'{compute}',(overlay->'compute')||jsonb_build_object(
      'project',project,'source_id',p_source,'families',families));
  end if;
  perform set_config('response.headers','[{"Cache-Control":"no-store"}]',true);
  return jsonb_build_object('server_scoring',overlay,'identity',jsonb_build_object(
    'userId',owner,'sourceId',p_source,'deviceId',device,
    'externalDeviceId',p_external_device_id,'project',project));
end $$;
revoke all on function public.get_server_score_snapshot_v2(date,uuid,text) from public,anon,service_role;
grant execute on function public.get_server_score_snapshot_v2(date,uuid,text) to authenticated;

notify pgrst,'reload schema';
commit;
