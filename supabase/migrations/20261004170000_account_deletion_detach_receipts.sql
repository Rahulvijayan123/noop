-- Account deletion could not finish for anyone who had uploaded data.
--
-- `begin_noop_account_deletion` retires the person's installations first, so nothing new is admitted while
-- their data is erased. The erase then deletes `object_manifests` and, last of all, the Auth user, whose
-- cascade removes `noop_ingest_tokens`. `noop_upload_receipts` points at both with ON DELETE SET NULL, and
-- that referential update ran the receipt's `noop_active_source` guard against the already-retired
-- installation. The guard raised `inactive_installation`, the whole DELETE rolled back, and the job stayed
-- blocked at `delete_supabase_rows` with the person's Auth user still in place. Every account that had a
-- receipt was affected, which is every account that had uploaded anything.
--
-- The guard exists to stop a retiring installation from making new durable writes. Detaching a receipt from
-- an object or token that is going away is not a write by the installation, and the guard already lets
-- already-accepted manifests be maintained for the same reason. So an UPDATE of a receipt now passes when
-- its only effect is to set `object_id` and/or `token_id` to NULL. Every other change to a receipt, setting
-- either column to a different value, and every INSERT still needs an active installation. Nothing else in
-- the function changes, and its owner, search_path, SECURITY DEFINER and EXECUTE privileges are unchanged.
--
-- Rollback: `create or replace` the function again without the first IF block (the earlier definition is the
-- one in 20260921110000_installation_retirement.sql). Receipts already detached stay detached.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '60s';

create or replace function public.noop_require_active_source() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='noop_upload_receipts' and tg_op='UPDATE' then
    if (to_jsonb(new) - 'object_id' - 'token_id') = (to_jsonb(old) - 'object_id' - 'token_id')
      and (new.object_id is null or new.object_id is not distinct from old.object_id)
      and (new.token_id is null or new.token_id is not distinct from old.token_id)
      then return new; end if;
  end if;
  if tg_table_name='object_manifests' and tg_op='UPDATE' then
    if old.status in ('ready','verified') and new.user_id=old.user_id
      and new.source_id is not distinct from old.source_id and new.device_id=old.device_id
      then return new; end if;
  end if;
  if new.source_id is not null and exists(select 1 from public.noop_app_installations where source_id=new.source_id) then
    perform 1 from public.noop_app_installations where source_id=new.source_id
      and user_id=new.user_id and revoked_at is null and retired_at is null for share;
    if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  end if;
  return new;
end $$;

commit;
