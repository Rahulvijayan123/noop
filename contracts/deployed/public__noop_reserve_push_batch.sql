-- Deployed definition for public.noop_reserve_push_batch
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:24.854038
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_reserve_push_batch';"
CREATE OR REPLACE FUNCTION public.noop_reserve_push_batch(p_user_id uuid, p_batch_id uuid, p_device_id uuid, p_body_sha256 text, p_entry jsonb)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_hash text; v_device uuid; v_created timestamptz;
begin
  if not exists (select 1 from public.devices where id = p_device_id and user_id = p_user_id) then
    raise exception 'device_owner_conflict' using errcode = '42501';
  end if;
  insert into public.noop_push_reservations(user_id, batch_id, device_id, body_sha256)
    values (p_user_id, p_batch_id, p_device_id, p_body_sha256)
    on conflict (user_id, batch_id) do nothing;
  select body_sha256, device_id, created_at into v_hash, v_device, v_created from public.noop_push_reservations
    where user_id = p_user_id and batch_id = p_batch_id for update;
  if v_hash is distinct from p_body_sha256 or v_device is distinct from p_device_id
     or exists (select 1 from public.noop_push_wal where user_id = p_user_id
                and batch_id = p_batch_id and body_sha256 <> p_body_sha256)
     or exists (select 1 from public.noop_push_acks where user_id = p_user_id
                and batch_id = p_batch_id and body_sha256 <> p_body_sha256) then
    raise exception 'batch_id_conflict' using errcode = '23505';
  end if;
  insert into public.noop_push_wal
    (user_id, batch_id, stream, device_id, source_id, record_count, body_sha256, received_at)
    values (p_user_id, p_batch_id, p_entry->>'stream', p_entry->>'deviceId',
            (p_entry->>'sourceId')::uuid, (p_entry->>'recordCount')::integer,
            p_body_sha256, now()) on conflict (user_id, batch_id) do nothing;
  return v_created;
end;
$function$

