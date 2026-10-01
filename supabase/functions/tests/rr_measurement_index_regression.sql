begin;
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id) values ('b1411111-1111-4111-8111-111111111111'); insert into public.devices(id,user_id,source_kind,external_device_id) values ('b1433333-3333-4333-8333-333333333333','b1411111-1111-4111-8111-111111111111','noop','installation:b1422222-2222-4222-8222-222222222222:fixture'),('b1444444-4444-4444-8444-444444444444','b1411111-1111-4111-8111-111111111111','noop','whoop-ABCDEF123'); insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at) values ('b1422222-2222-4222-8222-222222222222','b1411111-1111-4111-8111-111111111111',repeat('d',64),now()+interval '1 day'); insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values ('b1422222-2222-4222-8222-222222222222','b1411111-1111-4111-8111-111111111111','b1422222-2222-4222-8222-222222222222','ios','independent-fixture');
with b(first,last,batch) as (values (1,2,md5('rrInterval-batch-0')::uuid),(3,3,md5('rrInterval-batch-1')::uuid)) insert into public.noop_rr_intervals("user_id","device_id","source_id","ts","batch_id","ingested_at","rrMs","seq","ord","srcChannel","tsSuspect") select 'b1411111-1111-4111-8111-111111111111'::uuid,'b1433333-3333-4333-8333-333333333333'::uuid,'b1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,800+i%20,i%3,i%3,5,0 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('rrPacketProvenance-batch-0')::uuid),(3,3,md5('rrPacketProvenance-batch-1')::uuid)) insert into public.noop_rr_packet_provenance("user_id","device_id","source_id","ts","batch_id","ingested_at","packetId","sensorTs","recordIndex","rawHex","srcChannel","schemaVersion","decoderVersion","clockVersion","timestampPrecisionSeconds","clockOffsetSeconds","declaredCount") select 'b1411111-1111-4111-8111-111111111111'::uuid,'b1433333-3333-4333-8333-333333333333'::uuid,'b1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,md5(i::text)||md5('packet'||i::text),(1789889755::bigint+(i-1)::bigint*170351/3),i,repeat('a1',124),5,1,'whoop5-v18-original-words-v1','sensor-second-unmapped',1,0,2 from b cross join lateral generate_series(b.first,b.last) g(i);
do $$ declare u uuid:='b1411111-1111-4111-8111-111111111111';s uuid:='b1422222-2222-4222-8222-222222222222';d uuid:='b1433333-3333-4333-8333-333333333333';b uuid:='b1455555-5555-4555-8555-555555555555';b2 uuid:='b1466666-6666-4666-8666-666666666666';r jsonb;bad jsonb;n bigint;cases int:=0;k text;before_obs bigint;begin
 select to_jsonb(t)||jsonb_build_object('batch_id',b) into r from noop_rr_packet_provenance t where user_id=u order by "recordIndex" limit 1;
 foreach k in array array['sensorTs','recordIndex'] loop
  begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r||jsonb_build_object(k,null)));raise exception 'NULL accepted';exception when sqlstate '22023' then cases:=cases+1;end;
  begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r-k));raise exception 'missing accepted';exception when sqlstate '22023' then cases:=cases+1;end;
 end loop;
 assert not exists(select 1 from noop_projection_observations where user_id=u),'null guards wrote';
 assert noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r))=1,'retained';cases:=cases+1;
 assert noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r))=1,'replay';
 assert (select count(*) from noop_projection_observations where user_id=u)=1,'replay observations';
 assert (select count(*) from noop_rr_packet_provenance where user_id=u)=3,'replay rows';cases:=cases+1;
 begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r||'{"clockOffsetSeconds":99}'));raise exception 'batch mutation accepted';exception when unique_violation then cases:=cases+1;end;
 -- Fresh packet and each component of measurement identity remain independent.
 foreach k in array array['sensorTs','recordIndex'] loop
  bad:=r||jsonb_build_object(k,(r->>k)::bigint+1000000,'packetId',md5(k)||md5(k),'batch_id',md5(k)::uuid);
  if k='sensorTs' then bad:=bad||jsonb_build_object('ts',(bad->>'sensorTs')::bigint);end if;
  assert noop_project_append_batch(u,d,s,(bad->>'batch_id')::uuid,'rrPacketProvenance',jsonb_build_array(bad))=1,'component independent';cases:=cases+1;
 end loop;
 assert (select count(*) from noop_rr_packet_provenance where user_id=u)=5,'fresh count';
 -- Same identity, different packet bytes/clock still quarantines and deletes typed packet.
 bad:=r||jsonb_build_object('batch_id',b2,'clockOffsetSeconds',99);
 assert noop_project_append_batch(u,d,s,b2,'rrPacketProvenance',jsonb_build_array(bad))=1,'conflict';
 assert (select count(*) from noop_projection_conflicts where user_id=u)=1,'missing conflict';
 assert (select count(*) from noop_rr_packet_provenance where user_id=u)=4,'conflict row remains';
 assert exists(select 1 from noop_rr_clock_conflicts where user_id=u and ts=(r->>'ts')::bigint),'missing clock quarantine';
 assert not exists(select 1 from noop_rr_intervals where user_id=u and ts=(r->>'ts')::bigint),'RR intervals survived clock quarantine';cases:=cases+1;
 perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r));
 assert (select count(*) from noop_rr_packet_provenance where user_id=u)=4,'resurrection';cases:=cases+1;
 -- Existing duplicate measurement rows remain permissible: index must not change constraints.
 select to_jsonb(t) into r from noop_rr_packet_provenance t where user_id=u order by "recordIndex" desc limit 1;
 bad:=r||jsonb_build_object('packetId',repeat('f',64));
 insert into noop_rr_packet_provenance select * from jsonb_populate_record(null::noop_rr_packet_provenance,bad);
 assert (select count(*) from noop_rr_packet_provenance where user_id=u and "sensorTs"=(r->>'sensorTs')::bigint and "recordIndex"=(r->>'recordIndex')::bigint)=2,'duplicate blocked';cases:=cases+1;
 bad:=r||jsonb_build_object('batch_id',md5('duplicate-conflict')::uuid,'clockOffsetSeconds',88);
 perform noop_project_append_batch(u,d,s,(bad->>'batch_id')::uuid,'rrPacketProvenance',jsonb_build_array(bad));
 assert not exists(select 1 from noop_rr_packet_provenance where user_id=u and "sensorTs"=(r->>'sensorTs')::bigint and "recordIndex"=(r->>'recordIndex')::bigint),'duplicate conflict not removed';cases:=cases+1;
 -- Guard failures and partial batch exceptions remain atomic.
 before_obs:=(select count(*) from noop_projection_observations where user_id=u);
 bad:=r||jsonb_build_object('batch_id',md5('partial')::uuid);
 begin perform noop_project_append_batch(u,d,s,(bad->>'batch_id')::uuid,'rrPacketProvenance',jsonb_build_array(bad,bad||'{"recordIndex":null}'));raise exception 'partial accepted';exception when sqlstate '22023' then cases:=cases+1;end;
 assert (select count(*) from noop_projection_observations where user_id=u)=before_obs,'partial observation committed';
 foreach k in array array['user_id','device_id','source_id','batch_id'] loop
  begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r||jsonb_build_object('batch_id',b,k,'b1499999-9999-4999-8999-999999999999')));raise exception 'wrong identity accepted';exception when insufficient_privilege then cases:=cases+1;end;
 end loop;
 perform set_config('request.jwt.claim.role','authenticated',true);
 begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r));raise exception 'auth accepted';exception when insufficient_privilege then cases:=cases+1;end;
 perform set_config('request.jwt.claim.role','service_role',true);
 update noop_app_installations set revoked_at=now() where source_id=s;
 begin perform noop_project_append_batch(u,d,s,b,'rrPacketProvenance',jsonb_build_array(r));raise exception 'revoked accepted';exception when insufficient_privilege then cases:=cases+1;end;
 raise notice 'RR_SEMANTICS_PASS cases=%',cases;
end $$;
select jsonb_build_object('typed',(select jsonb_agg(to_jsonb(t)-'ingested_at' order by "packetId") from noop_rr_packet_provenance t where user_id='b1411111-1111-4111-8111-111111111111'),'observations',(select jsonb_agg(to_jsonb(t)-'received_at' order by batch_id,measurement_key::text) from noop_projection_observations t where user_id='b1411111-1111-4111-8111-111111111111'),'conflicts',(select jsonb_agg(to_jsonb(t)-'detected_at' order by stream,measurement_key::text) from noop_projection_conflicts t where user_id='b1411111-1111-4111-8111-111111111111'),'clock',(select jsonb_agg(to_jsonb(t) order by ts) from noop_rr_clock_conflicts t where user_id='b1411111-1111-4111-8111-111111111111'));
rollback;
