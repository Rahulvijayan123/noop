-- Account deletion: the revision trigger no longer breaks the auth.users cascade.
--
-- public.bump_user_revision() (20260824180000_production_persistence.sql) runs AFTER INSERT/UPDATE/DELETE on
-- daily_metrics, sessions, events, sleep_details (20260824180000) and daily_physiology_series (20260827100000,
-- insert/update only) and upserts public.user_sync_state for the row's owner. Deleting an auth.users row cascades
-- to those tables; by then the owner row is already gone, so the upsert's own foreign key
-- (user_sync_state.user_id -> auth.users) fails and the whole delete is rolled back:
--
--   ERROR: 23503: insert or update on table "user_sync_state" violates foreign key constraint
--          "user_sync_state_user_id_fkey"
--   DETAIL: Key (user_id)=(...) is not present in table "users".
--   CONTEXT: ... PL/pgSQL function bump_user_revision() line 9 at SQL statement
--
-- Reproduced on a scratch database built from every migration (a user with one sessions row, or one daily_metrics
-- row, cannot be deleted). The cascade also reaches the trigger as an UPDATE: sessions.device_id and
-- daily_metrics.source_device_id are ON DELETE SET NULL, so the devices the account cascade removes rewrite those
-- rows. GoTrue's admin delete (`DELETE /auth/v1/admin/users/{id}`, what the account-deletion service's last step
-- calls) is a plain `delete from auth.users`, so it fails whenever any of the owner's trigger-bearing rows are
-- still there. The deletion service deletes those tables by REST first, so its normal path does not hit this; a
-- row written between that step and the auth delete (a queued scoring job, a late sync), a direct delete from the
-- dashboard or SQL, and test teardowns do.
--
-- Fix: when the owner no longer exists, there is no sync state to bump (and nothing will read it: the account and
-- its user_sync_state row are going away in the same statement), so the trigger returns without writing. Any
-- operation is covered, not just DELETE, because of the SET NULL updates above; an INSERT for a missing owner
-- fails on the inserted row's own foreign key regardless. One primary-key probe per row. The rest of the
-- function body is unchanged byte for byte, and CREATE OR REPLACE keeps the owner (postgres, which can read
-- auth.users), SECURITY DEFINER, the search_path and the existing triggers.
--
-- Rollback: re-create the function from 20260824180000_production_persistence.sql (the block starting
-- `create or replace function public.bump_user_revision()`).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.bump_user_revision()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare uid uuid;
begin
  uid := coalesce(new.user_id, old.user_id);
  if tg_table_name = 'profiles' then
    uid := coalesce(new.id, old.id);
  end if;
  if uid is null then return coalesce(new, old); end if;
  -- The owner is being deleted (the auth.users cascade): nothing to bump, and the upsert would violate
  -- user_sync_state's foreign key and abort the account deletion.
  if not exists (select 1 from auth.users u where u.id = uid) then return coalesce(new, old); end if;
  insert into public.user_sync_state (user_id, revision, updated_at)
  values (uid, 1, now())
  on conflict (user_id) do update
    set revision = public.user_sync_state.revision + 1,
        updated_at = now(),
        last_metrics_at = case when tg_table_name = 'daily_metrics' then now() else public.user_sync_state.last_metrics_at end,
        last_sleep_at = case when tg_table_name in ('sleep_details', 'sleep_nights') then now() else public.user_sync_state.last_sleep_at end,
        last_session_at = case when tg_table_name = 'sessions' then now() else public.user_sync_state.last_session_at end;
  return coalesce(new, old);
end;
$$;

commit;
