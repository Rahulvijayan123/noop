-- Deployed definition for public.noop_push_save_ack
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:25.576345
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_push_save_ack';"
CREATE OR REPLACE FUNCTION public.noop_push_save_ack(p_user_id uuid, p_batch_id uuid, p_body_sha256 text, p_ack jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_hash text; v_receipt jsonb;
begin
  select body_sha256 into v_hash from public.noop_push_reservations
    where user_id=p_user_id and batch_id=p_batch_id for update;
  if not found or v_hash is distinct from p_body_sha256 then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  select durability_receipt into v_receipt from public.object_manifests
    where id=p_batch_id and user_id=p_user_id and status='ready' and indexed_at is not null;
  if v_receipt is null or p_ack->'durabilityReceipt' is distinct from v_receipt
     or not exists (select 1 from public.noop_signal_windows where object_id=p_batch_id
                    and user_id=p_user_id and object_key=v_receipt->>'objectKey') then
    raise exception 'archive_not_ready' using errcode='23514';
  end if;
  insert into public.noop_push_acks(user_id,batch_id,body_sha256,ack)
    values(p_user_id,p_batch_id,p_body_sha256,p_ack)
    on conflict(user_id,batch_id) do update set ack=excluded.ack,saved_at=now()
    where public.noop_push_acks.body_sha256=excluded.body_sha256;
  if not found then raise exception 'batch_id_conflict' using errcode='23505'; end if;
end;
$function$

