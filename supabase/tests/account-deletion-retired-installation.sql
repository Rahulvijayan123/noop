-- Regression for 20261004170000_account_deletion_detach_receipts.sql.
--
-- Account deletion retires the person's installations and then erases their rows. Erasing an object or a
-- token must be able to detach the upload receipts that point at it even though the installation is already
-- retired, while a retired installation must still be unable to write: any other change to a receipt,
-- re-pointing it at a different object, and any new receipt stay rejected with `inactive_installation`.
--
-- Everything runs in one transaction that is rolled back, so it is safe against a live database:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/account-deletion-retired-installation.sql
\set ON_ERROR_STOP on
\echo CASE retired-installation-erase
begin;
set local statement_timeout = '30s';

insert into auth.users(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
insert into public.devices(id, user_id, source_kind, external_device_id)
  values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'noop',
          'installation:11111111-1111-4111-8111-111111111111:fixture-whoop');
insert into public.noop_app_installations(source_id, user_id, platform, app_version, provisioning_method)
  values ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'ios', 'fixture', 'supabase_auth');
insert into public.noop_ingest_tokens(id, user_id, token_hash, token_kind, source_id, provisioning_method)
  values ('22222222-2222-4222-8222-222222222222', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', repeat('c', 64),
          'installation', '11111111-1111-4111-8111-111111111111', 'supabase_auth');
insert into public.object_manifests(id, user_id, device_id, source_id, object_kind, object_key, status)
  values ('33333333-3333-4333-8333-333333333333', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd', '11111111-1111-4111-8111-111111111111',
          'rawImuSession', 'deletion-fixture/one', 'pending'),
         ('44444444-4444-4444-8444-444444444444', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd', '11111111-1111-4111-8111-111111111111',
          'rawImuSession', 'deletion-fixture/two', 'pending');
insert into public.noop_upload_receipts(id, user_id, source_id, device_id, token_id, auth_mode, lane, stream,
                                        batch_id, object_id, body_sha256, accepted_status, accepted_rows)
  values ('55555555-5555-4555-8555-555555555555', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          '11111111-1111-4111-8111-111111111111', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          '22222222-2222-4222-8222-222222222222', 'installation', 'object', 'fixture',
          '66666666-6666-4666-8666-666666666666', '33333333-3333-4333-8333-333333333333',
          repeat('a', 64), 'accepted', 1);

select set_config('request.jwt.claim.role', 'service_role', true);
select public.begin_noop_account_deletion('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

do $check$
declare
  st text;
  msg text;
  r public.noop_upload_receipts;
begin
  begin
    update public.noop_upload_receipts set accepted_rows = 2 where id = '55555555-5555-4555-8555-555555555555';
    st := 'NONE';
  exception when others then st := sqlstate; msg := sqlerrm;
  end;
  assert st = '42501' and msg = 'inactive_installation',
    'changing another receipt column must stay blocked, got ' || coalesce(st, '?') || ' ' || coalesce(msg, '');

  st := null; msg := null;
  begin
    update public.noop_upload_receipts set object_id = '44444444-4444-4444-8444-444444444444'
     where id = '55555555-5555-4555-8555-555555555555';
    st := 'NONE';
  exception when others then st := sqlstate; msg := sqlerrm;
  end;
  assert st = '42501' and msg = 'inactive_installation',
    're-pointing a receipt at another object must stay blocked, got ' || coalesce(st, '?') || ' ' || coalesce(msg, '');

  st := null; msg := null;
  begin
    insert into public.noop_upload_receipts(id, user_id, source_id, device_id, auth_mode, lane, stream,
                                            batch_id, body_sha256, accepted_status)
      values ('77777777-7777-4777-8777-777777777777', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              '11111111-1111-4111-8111-111111111111', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              'installation', 'object', 'fixture', '88888888-8888-4888-8888-888888888888',
              repeat('b', 64), 'accepted');
    st := 'NONE';
  exception when others then st := sqlstate; msg := sqlerrm;
  end;
  assert st = '42501' and msg = 'inactive_installation',
    'a new receipt for a retired installation must stay blocked, got ' || coalesce(st, '?') || ' ' || coalesce(msg, '');

  delete from public.object_manifests where id = '33333333-3333-4333-8333-333333333333';
  select * into r from public.noop_upload_receipts where id = '55555555-5555-4555-8555-555555555555';
  assert r.id is not null and r.object_id is null and r.accepted_rows = 1 and r.token_id is not null,
    'erasing an object must detach its receipt and change nothing else';

  delete from public.noop_ingest_tokens where id = '22222222-2222-4222-8222-222222222222';
  select * into r from public.noop_upload_receipts where id = '55555555-5555-4555-8555-555555555555';
  assert r.id is not null and r.token_id is null and r.accepted_rows = 1,
    'erasing a token must detach its receipt and change nothing else';

  delete from public.object_manifests where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  delete from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  assert not exists (select 1 from public.noop_upload_receipts where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'erasing the Auth user must remove the receipts';
  assert not exists (select 1 from public.noop_app_installations where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'erasing the Auth user must remove the installations';
end $check$;
rollback;

select 'account-deletion-retired-installation: ok' as result;
