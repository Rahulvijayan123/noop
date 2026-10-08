-- Regression for 20261008100400_bump_user_revision_skip_deleted_owner.sql.
--
-- Deleting an auth.users row must cascade through every table that carries the bump_user_revision trigger
-- (sessions, sleep_details, daily_metrics, events, daily_physiology_series) and through the devices whose ON DELETE
-- SET NULL rewrites those rows, and leave nothing of the owner behind. Before the fix the trigger's
-- user_sync_state upsert violated user_sync_state_user_id_fkey inside the cascade and rolled the delete back.
-- The trigger must still bump the revision while the owner exists.
--
-- Everything runs in one transaction that is rolled back:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/account-deletion-revision-cascade.sql
\set ON_ERROR_STOP on
\echo CASE account-deletion-revision-cascade
begin;
set local statement_timeout = '30s';

insert into auth.users(id) values ('c0000000-0000-4000-8000-000000000001'), ('c0000000-0000-4000-8000-000000000002');
insert into public.devices(id, user_id, source_kind) values
  ('c0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-000000000001', 'noop_push'),
  ('c0000000-0000-4000-8000-0000000000d2', 'c0000000-0000-4000-8000-000000000002', 'noop_push');
insert into public.sessions(id, user_id, device_id, kind, source, start_at, end_at) values
  ('c0000000-0000-4000-8000-0000000000a1', 'c0000000-0000-4000-8000-000000000001',
   'c0000000-0000-4000-8000-0000000000d1', 'sleep', 'frwhoop', now() - interval '8 hours', now() - interval '1 hour'),
  ('c0000000-0000-4000-8000-0000000000a2', 'c0000000-0000-4000-8000-000000000001',
   'c0000000-0000-4000-8000-0000000000d1', 'workout', 'manual', now() - interval '30 minutes', now()),
  ('c0000000-0000-4000-8000-0000000000b1', 'c0000000-0000-4000-8000-000000000002',
   'c0000000-0000-4000-8000-0000000000d2', 'workout', 'manual', now() - interval '30 minutes', now());
insert into public.sleep_details(session_id, user_id)
  values ('c0000000-0000-4000-8000-0000000000a1', 'c0000000-0000-4000-8000-000000000001');
insert into public.daily_metrics(user_id, day, source_device_id)
  values ('c0000000-0000-4000-8000-000000000001', current_date, 'c0000000-0000-4000-8000-0000000000d1');
insert into public.events(user_id, event_type, occurred_at)
  values ('c0000000-0000-4000-8000-000000000001', 'fixture', now());
insert into public.daily_physiology_series(user_id, day, day_start_at, day_end_at)
  values ('c0000000-0000-4000-8000-000000000001', current_date,
          date_trunc('day', now()), date_trunc('day', now()) + interval '1 day');

do $check$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  other uuid := 'c0000000-0000-4000-8000-000000000002';
  rev_before bigint; rev_after bigint; fk record; n bigint; leftovers text[] := '{}';
begin
  -- 1. The trigger still bumps while the owner exists (insert, update and delete).
  select revision into rev_before from public.user_sync_state where user_id = u;
  assert rev_before >= 6, 'six trigger-bearing inserts bumped the revision, got ' || coalesce(rev_before::text, 'NULL');
  update public.daily_metrics set day = day where user_id = u;
  delete from public.sessions where id = 'c0000000-0000-4000-8000-0000000000a2';
  select revision into rev_after from public.user_sync_state where user_id = u;
  assert rev_after = rev_before + 2, 'an update and a delete with the owner present bump twice';
  assert (select last_session_at is not null from public.user_sync_state where user_id = u),
    'a sessions change still stamps last_session_at';

  -- 2. The account cascade completes.
  delete from auth.users where id = u;
  assert not exists (select 1 from auth.users where id = u), 'the owner is gone';

  -- 3. Nothing that references the owner is left, in any table with a foreign key to auth.users.
  for fk in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and cardinality(c.conkey) = 1
  loop
    execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col) into n using u;
    if n > 0 then leftovers := leftovers || (fk.tbl::text || '.' || fk.col || '=' || n); end if;
  end loop;
  assert cardinality(leftovers) = 0, 'rows left after the account cascade: ' || leftovers::text;
  assert not exists (select 1 from public.sleep_details where session_id = 'c0000000-0000-4000-8000-0000000000a1'),
    'the sleep details went with their session';

  -- 4. The other account is untouched, and its revision still moves.
  assert (select count(*) from public.sessions where user_id = other) = 1, 'the other owner keeps its session';
  select revision into rev_before from public.user_sync_state where user_id = other;
  delete from public.sessions where user_id = other;
  assert (select revision from public.user_sync_state where user_id = other) = rev_before + 1,
    'the other owner''s revision still bumps';
  delete from auth.users where id = other;
  assert not exists (select 1 from public.user_sync_state where user_id = other), 'a second cascade also completes';
end;
$check$;

\echo PASS account-deletion-revision-cascade
rollback;
