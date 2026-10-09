-- Account sync health: is every signed-in account still syncing?
--
-- WHY
-- A signed-in account must keep syncing (the server's `syncPolicy`, supabase/functions/_shared/syncPolicy.ts);
-- the app enforces it. Nothing on the server could answer the matching question, which accounts have gone
-- quiet, without hand-written joins over auth.users, installations and receipts. These two read-only functions
-- answer it from what already exists: the newest accepted upload is the newest noop_upload_receipts row
-- (one per accepted inline batch or completed object, any installation), read through the existing
-- noop_upload_receipts_user_accepted_idx (user_id, accepted_at desc) with a LATERAL ... LIMIT 1 per account,
-- so no receipt scan.
--
-- WHAT CHANGES
--   account_sync_health_v1(hours, user)  service role only. One row per confirmed account (email confirmed,
--                                        not soft-deleted in Auth, not frozen for deletion in
--                                        noop_account_retirements), or just `user`. The coach status route
--                                        reads the caller's row; operators read the fleet.
--   my_sync_health_v1(hours)             a signed-in caller's own row (auth.uid()), always exactly one.
-- A live installation is one that is neither revoked nor retired, as provision_noop_installation counts them.
-- Stale means nothing was accepted in the last `hours` (1..720); an account that never uploaded is stale.
--
-- Privileges: both SECURITY DEFINER with an empty search_path (receipts and installations are service-only
-- under RLS), EXECUTE revoked from public, anon and authenticated (Supabase's default privileges grant EXECUTE
-- on new functions, so the revokes are load-bearing), then granted to service_role for the fleet function and
-- to authenticated for the caller's own. Neither writes anything.
--
-- Safe to re-run. Rollback: drop function public.my_sync_health_v1(integer);
-- drop function public.account_sync_health_v1(integer, uuid). Nothing depends on them in SQL.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.account_sync_health_v1(p_stale_after_hours integer default 24,
                                                         p_user_id uuid default null)
returns table (user_id uuid, live_installations integer, last_upload_at timestamptz, never_uploaded boolean,
               stale boolean, silent boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_cutoff timestamptz;
begin
  if p_stale_after_hours is null or p_stale_after_hours not between 1 and 720 then
    raise exception 'sync_stale_hours_invalid' using errcode = '22023';
  end if;
  v_cutoff := pg_catalog.now() - pg_catalog.make_interval(hours => p_stale_after_hours);
  return query
  select u.id, live.n, recent.accepted_at, recent.accepted_at is null, quiet.stale, live.n = 0 or quiet.stale
    from auth.users u
    cross join lateral (
      select count(*)::integer as n
        from public.noop_app_installations a
       where a.user_id = u.id and a.revoked_at is null and a.retired_at is null) live
    left join lateral (
      select r.accepted_at
        from public.noop_upload_receipts r
       where r.user_id = u.id
       order by r.accepted_at desc
       limit 1) recent on true
    cross join lateral (select recent.accepted_at is null or recent.accepted_at < v_cutoff as stale) quiet
   where u.email_confirmed_at is not null
     and u.deleted_at is null
     and (p_user_id is null or u.id = p_user_id)
     and not exists (select 1 from public.noop_account_retirements t where t.user_id = u.id)
   order by u.id;
end $$;

create or replace function public.my_sync_health_v1(p_stale_after_hours integer default 24)
returns table (last_upload_at timestamptz, stale boolean, live_installations integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_cutoff timestamptz;
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_stale_after_hours is null or p_stale_after_hours not between 1 and 720 then
    raise exception 'sync_stale_hours_invalid' using errcode = '22023';
  end if;
  v_cutoff := pg_catalog.now() - pg_catalog.make_interval(hours => p_stale_after_hours);
  -- Every read is keyed by auth.uid(); the function takes no owner, so no caller can name another account.
  return query
  select recent.accepted_at, recent.accepted_at is null or recent.accepted_at < v_cutoff, live.n
    from (select count(*)::integer as n
            from public.noop_app_installations a
           where a.user_id = v_user and a.revoked_at is null and a.retired_at is null) live
    left join lateral (
      select r.accepted_at
        from public.noop_upload_receipts r
       where r.user_id = v_user
       order by r.accepted_at desc
       limit 1) recent on true;
end $$;

revoke all on function public.account_sync_health_v1(integer, uuid) from public, anon, authenticated;
grant execute on function public.account_sync_health_v1(integer, uuid) to service_role;
revoke all on function public.my_sync_health_v1(integer) from public, anon;
grant execute on function public.my_sync_health_v1(integer) to authenticated;

comment on function public.account_sync_health_v1(integer, uuid) is
  'Sync health of every confirmed account (email confirmed, not deleted, not frozen for deletion), or of '
  'p_user_id only: live (not revoked, not retired) installations, the newest accepted upload '
  '(noop_upload_receipts.accepted_at), never_uploaded, stale (nothing accepted in p_stale_after_hours, 1..720; '
  'never uploaded is stale) and silent (no live installation, or stale). Service role only; read-only.';
comment on function public.my_sync_health_v1(integer) is
  'The calling account''s own sync health (auth.uid(); refused without one): the newest accepted upload, '
  'stale (nothing accepted in p_stale_after_hours, 1..720; never uploaded is stale) and its live '
  'installations. Always one row. Signed-in callers only; read-only.';

commit;
