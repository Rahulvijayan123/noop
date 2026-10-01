-- Independent reviewer regression. Run only on disposable migrated PostgreSQL.
-- All synthetic source, manifest, queue and receipt state rolls back.
begin;
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id) values('a1811111-1111-4111-8111-111111111111');
insert into devices(id,user_id,source_kind) values
 ('a1822222-2222-4222-8222-222222222222','a1811111-1111-4111-8111-111111111111','noop_push');
insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,
 status,sha256_source,sha256,verified_at,indexed_at,source_id,auth_mode,durability_receipt)
values('a1833333-3333-4333-8333-333333333333','a1811111-1111-4111-8111-111111111111',
 'a1822222-2222-4222-8222-222222222222','ppgWaveformSample','synthetic-lifecycle-review/raw','binary',
 '2026-01-01 12:00Z','2026-01-01 12:01Z','verified','server_verified',repeat('a',64),now(),now(),
 'a1844444-4444-4444-8444-444444444444','installation',
 jsonb_build_object('state','verified_indexed','receiptId','a1855555-5555-4555-8555-555555555555',
 'ownerUserId','a1811111-1111-4111-8111-111111111111','deviceId','a1822222-2222-4222-8222-222222222222',
 'objectId','a1833333-3333-4333-8333-333333333333','objectKey','synthetic-lifecycle-review/raw'));
insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts)
select user_id,device_id,object_kind,extract(epoch from start_at)::bigint,id,object_key,
 extract(epoch from start_at)::bigint,extract(epoch from end_at)::bigint
from object_manifests where id='a1833333-3333-4333-8333-333333333333';
delete from scoring_work_items where user_id='a1811111-1111-4111-8111-111111111111';
do $$ begin
 begin
  perform noop_history_requeue_object('a1811111-1111-4111-8111-111111111111',
   'a1822222-2222-4222-8222-222222222222','a1833333-3333-4333-8333-333333333333',
   'a1855555-5555-4555-8555-555555555555');
  raise exception 'REVIEW FAILURE: missing installation source was accepted for replay';
 exception when insufficient_privilege then null; end;
 assert not exists(select 1 from scoring_work_items where user_id='a1811111-1111-4111-8111-111111111111'),
   'missing source created new historical queue authority';
end $$;
insert into noop_enrollment_codes(id,user_id,code_hash,expires_at) values
 ('a1866666-6666-4666-8666-666666666666','a1811111-1111-4111-8111-111111111111',repeat('b',64),now()+interval '1 day');
insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values
 ('a1844444-4444-4444-8444-444444444444','a1811111-1111-4111-8111-111111111111',
  'a1866666-6666-4666-8666-666666666666','ios','review');
do $$ declare replay jsonb; begin
 replay:=noop_history_requeue_object('a1811111-1111-4111-8111-111111111111',
  'a1822222-2222-4222-8222-222222222222','a1833333-3333-4333-8333-333333333333',
  'a1855555-5555-4555-8555-555555555555');
 assert (replay->>'queued_days')::integer>0,'active enrolled retained source failed positive replay';
end $$;
delete from scoring_work_items where user_id='a1811111-1111-4111-8111-111111111111';
update noop_app_installations set retired_at=clock_timestamp(),retirement_id=gen_random_uuid(),revoked_at=clock_timestamp()
 where source_id='a1844444-4444-4444-8444-444444444444';
do $$ begin
 begin
  perform noop_history_requeue_object('a1811111-1111-4111-8111-111111111111',
   'a1822222-2222-4222-8222-222222222222','a1833333-3333-4333-8333-333333333333',
   'a1855555-5555-4555-8555-555555555555');
  raise exception 'retired installation source was accepted for replay';
 exception when insufficient_privilege then null; end;
 assert not exists(select 1 from scoring_work_items where user_id='a1811111-1111-4111-8111-111111111111'),
  'retired source created new historical queue authority';
end $$;
-- A legacy recording need not have an installation row. Keep this compatibility
-- explicit; do not manufacture a new source for any real retained object.
update object_manifests set auth_mode='legacy_fleet',source_id='a1877777-7777-4777-8777-777777777777'
 where id='a1833333-3333-4333-8333-333333333333';
do $$ declare replay jsonb; begin
 replay:=noop_history_requeue_object('a1811111-1111-4111-8111-111111111111',
  'a1822222-2222-4222-8222-222222222222','a1833333-3333-4333-8333-333333333333',
  'a1855555-5555-4555-8555-555555555555');
 assert (replay->>'queued_days')::integer>0,'legacy non-installation source lost replay compatibility';
end $$;
rollback;
