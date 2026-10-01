-- Deployed definition for public.noop_register_push_device
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:26.200135
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_register_push_device';"
CREATE OR REPLACE FUNCTION public.noop_register_push_device(p_user_id uuid, p_device_id uuid, p_external_device_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_owner uuid; v_registered uuid; v_kind text; v_external text;
begin
  if p_user_id is null or p_device_id is null or nullif(p_external_device_id, '') is null then
    raise exception 'invalid_device_registration' using errcode = '22023';
  end if;
  select user_id,source_kind,external_device_id into v_owner,v_kind,v_external
    from public.devices where id=p_device_id for update;
  if found then
    if v_owner is distinct from p_user_id then
      raise exception 'device_owner_conflict' using errcode = '42501';
    end if;
    if v_kind is distinct from 'noop_push' or v_external is distinct from p_external_device_id then
      raise exception 'device_registration_conflict' using errcode = '23505';
    end if;
    update public.devices set last_seen_at=greatest(last_seen_at,now()) where id=p_device_id;
    return p_device_id;
  end if;
  insert into public.devices (id, user_id, source_kind, external_device_id, last_seen_at)
    values (p_device_id, p_user_id, 'noop_push', p_external_device_id, now())
    on conflict (user_id,source_kind,external_device_id) where external_device_id is not null
    do update set last_seen_at=greatest(public.devices.last_seen_at,excluded.last_seen_at)
    returning id into v_registered;
  return v_registered;
end;
$function$

