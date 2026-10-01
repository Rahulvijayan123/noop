-- Only disposable migrated databases. Every source, queue and receipt fixture rolls back.
begin;
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id) values('a1611111-1111-4111-8111-111111111111'),('b1611111-1111-4111-8111-111111111111');
insert into devices(id,user_id,source_kind) values
 ('a1622222-2222-4222-8222-222222222222','a1611111-1111-4111-8111-111111111111','noop_push'),
 ('b1622222-2222-4222-8222-222222222222','b1611111-1111-4111-8111-111111111111','noop_push');
insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,
 status,sha256_source,sha256,verified_at,indexed_at,created_at,durability_receipt)
select ('a1633333-3333-4333-8333-'||lpad(i::text,12,'0'))::uuid,
 'a1611111-1111-4111-8111-111111111111','a1622222-2222-4222-8222-222222222222',
 'ppgWaveformSample','synthetic-recovery/raw/'||i,'binary',
 '2026-01-01 12:00Z'::timestamptz+i*interval '1 day','2026-01-01 12:01Z'::timestamptz+i*interval '1 day',
 'verified','server_verified',repeat('a',64),now(),now(),now()-interval '1 day',
 jsonb_build_object('state','verified_indexed','receiptId','a1644444-4444-4444-8444-444444444444',
   'ownerUserId','a1611111-1111-4111-8111-111111111111','deviceId','a1622222-2222-4222-8222-222222222222',
   'objectId','a1633333-3333-4333-8333-'||lpad(i::text,12,'0'),'objectKey','synthetic-recovery/raw/'||i)
from generate_series(1,3) i;
insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts)
select user_id,device_id,object_kind,extract(epoch from start_at)::bigint,id,object_key,
 extract(epoch from start_at)::bigint,extract(epoch from end_at)::bigint
from object_manifests where user_id='a1611111-1111-4111-8111-111111111111';
-- Simulate only these synthetic retained objects having lost queue authority.
delete from scoring_work_items where user_id='a1611111-1111-4111-8111-111111111111';
do $$ declare p jsonb; replay jsonb; n integer; revisions jsonb; begin
 p:=noop_history_inventory_page('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222',null,2,now());
 assert jsonb_array_length(p->'items')=2 and not (p->>'scan_complete')::boolean,'bounded first page';
 assert p#>>'{items,0,raw_readability}'='NOT_MEASURED','a receipt must not imply current B2 access';
 assert p#>>'{items,0,affected_days,0,state}'='projected_not_queued','lost queue state not identified';
 assert p#>>'{items,0,affected_days,0,archive_state}'='absent','raw receipt must not imply derived archive';
 p:=noop_history_inventory_page('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222',(p->>'next_cursor')::uuid,2,now());
 assert jsonb_array_length(p->'items')=1 and (p->>'scan_complete')::boolean,'resume did not finish exactly once';
 p:=noop_history_inventory_page('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222',null,2,now()-interval '2 days');
 assert jsonb_array_length(p->'items')=0,'inventory cutoff not respected';
 replay:=noop_history_requeue_object('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222','a1633333-3333-4333-8333-000000000001',
   'a1644444-4444-4444-8444-444444444444');
 n:=(replay->>'queued_days')::integer;
 assert n>0,'exact retained original day not requeued';
 select jsonb_agg(to_jsonb(q) order by day) into revisions from scoring_work_items q
 where user_id='a1611111-1111-4111-8111-111111111111';
 replay:=noop_history_requeue_object('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222','a1633333-3333-4333-8333-000000000001',
   'a1644444-4444-4444-8444-444444444444');
 assert (replay->>'queued_days')::integer=0,'duplicate replay advanced input revision';
 assert revisions=(select jsonb_agg(to_jsonb(q) order by day) from scoring_work_items q
   where user_id='a1611111-1111-4111-8111-111111111111'),'duplicate replay mutated existing debt';
 assert not exists(select 1 from scoring_work_items where user_id='b1611111-1111-4111-8111-111111111111'),
   'cross-owner queue touched';
 begin
  perform noop_history_inventory_page('a1611111-1111-4111-8111-111111111111',
   'b1622222-2222-4222-8222-222222222222',null,2,now());
  raise exception 'cross-owner inventory accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_history_requeue_object('b1611111-1111-4111-8111-111111111111',
   'b1622222-2222-4222-8222-222222222222','a1633333-3333-4333-8333-000000000001',
   'a1644444-4444-4444-8444-444444444444');
  raise exception 'cross-owner replay accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_history_requeue_object('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222','a1633333-3333-4333-8333-000000000001',
   'b1644444-4444-4444-8444-444444444444');
  raise exception 'substituted receipt accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_history_requeue_object('a1611111-1111-4111-8111-111111111111',
   'a1622222-2222-4222-8222-222222222222','a1633333-3333-4333-8333-000000000001',null);
  raise exception 'missing receipt accepted';
 exception when invalid_parameter_value then null; end;
end $$;
-- A historical client digest and a settled NDJSON archive without completed projection cannot be replayed.
update object_manifests set sha256_source='client_claimed' where id='a1633333-3333-4333-8333-000000000002';
update object_manifests set format='ndjson' where id='a1633333-3333-4333-8333-000000000003';
do $$ begin
 for i in 2..3 loop
  begin
   perform noop_history_requeue_object('a1611111-1111-4111-8111-111111111111',
    'a1622222-2222-4222-8222-222222222222',('a1633333-3333-4333-8333-'||lpad(i::text,12,'0'))::uuid,
    'a1644444-4444-4444-8444-444444444444');
   raise exception 'unverified or unprojected source accepted';
  exception when insufficient_privilege then null; end;
 end loop;
end $$;
rollback;
