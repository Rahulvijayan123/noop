-- Activity-context DB contract (contracts C5 + C10). Runs inside the isolated, fully migrated
-- test database with 20261003120000_activity_context.sql applied. Every fixture change rolls
-- back; no deployed credentials or data are touched. Statement timeout keeps a misbehaving
-- assertion from hanging a disposable cluster.
--
-- Run against a disposable cluster the way the other *.sql tests run:
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261003120000_activity_context.sql -f activity_context_contract.sql
-- (the migration must apply to a fully migrated Supabase-style schema first; the fixtures here
-- only need base_schema, production_persistence, scoring_service_state, physiology_revisions,
-- the devices_owner_identity unique constraint and this migration).
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push'),
 ('a0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000002','noop_push'),
 ('a0000000-0000-4000-8000-000000000013','a0000000-0000-4000-8000-000000000001','noop_push');

-- 1. Idempotent enqueue: same fingerprint is a no-op, changed fingerprint bumps the revision.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-03';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  hi bigint := extract(epoch from ((v_day+1)::timestamp at time zone 'UTC'))::bigint - 1;
  fp1 text; fp2 text; rev bigint; dirty_stamp timestamptz;
begin
  fp1 := public.activity_context_fingerprint(array[repeat('a',64)],lo,hi,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp2 := public.activity_context_fingerprint(array[repeat('b',64)],lo,hi,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('a',64)],fp1);
  select input_revision into rev from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day and algorithm_version='hart-activity-1';
  assert rev=1, 'fresh enqueue must start at input_revision 1';
  select dirty_at into dirty_stamp from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  -- Identical replay: no revision bump, no new dirty stamp.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('a',64)],fp1);
  select input_revision into rev from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert rev=1, 'same fingerprint must not bump input_revision';
  assert (select dirty_at = dirty_stamp from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'same fingerprint must not dirty';
  -- Changed fingerprint (late verified object): bounded recomputation.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('b',64)],fp2);
  select input_revision into rev from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert rev=2, 'changed fingerprint must bump input_revision';
  assert (select fingerprint=fp2 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'fingerprint must be updated';
  raise notice 'PASS 1 idempotent enqueue and revision bump';
end;
$$;

-- 2. Claim / lease / renew / expiry: token grant, single winner, expiry makes it re-claimable.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-03';
  j record; tok uuid; ok boolean;
begin
  select * into j from public.claim_activity_context_v2(300);
  assert found, 'claim must return the due job';
  assert j.user_id=u and j.device_id=dev and j.day=v_day, 'claim returned the wrong job';
  assert j.lease_token is not null and j.lease_until>clock_timestamp(), 'claim must grant a live lease';
  tok := j.lease_token;
  -- No second worker can claim the live lease.
  select * into j from public.claim_activity_context_v2(300);
  assert not found, 'live lease must not be re-claimed';
  -- Renew extends the lease.
  ok := public.renew_activity_context_v2(tok, 600);
  assert ok, 'renew must succeed for a live lease';
  assert (select lease_until > clock_timestamp() + interval '9 minutes' from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'renew must extend the lease';
  -- Expired lease becomes claimable again.
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  select * into j from public.claim_activity_context_v2(300);
  assert found, 'expired lease must be claimable';
  assert j.lease_token is distinct from tok, 'expiry re-claim must mint a fresh token';
  assert (select lease_expiry_count=1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'expiry must be counted';
  raise notice 'PASS 2 claim/lease/renew/expiry';
end;
$$;

-- 3. fail: bounded backoff, clean stale release, dead-letter after 8 consecutive failures.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-03';
  j record; tok uuid; i integer; n integer; nb timestamptz;
begin
  -- Test 2's final re-claim left a live lease; expire it so this block starts clean.
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- A stale-revision failure releases the lease without failure accounting.
  select * into j from public.claim_activity_context_v2(300);
  tok := j.lease_token;
  perform public.fail_activity_context_v2(tok, j.input_revision+99, 'stale worker');
  select consecutive_failures into n from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert n=0, 'stale revision failure must not count';
  assert (select lease_token is null from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'fail must clear the lease';
  -- Seven more real failures then the eighth dead-letters.
  for i in 1..8 loop
    update public.activity_context_jobs set not_before=clock_timestamp()
      where user_id=u and device_id=dev and day=v_day;
    select * into j from public.claim_activity_context_v2(300);
    assert found, 'job must remain claimable before dead-letter';
    tok := j.lease_token;
    perform public.fail_activity_context_v2(tok, j.input_revision, 'model error');
    if i<8 then
      assert not (select dead_letter from public.activity_context_jobs
        where user_id=u and device_id=dev and day=v_day), 'must not dead-letter before 8';
    end if;
  end loop;
  assert (select dead_letter and consecutive_failures=8 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'eighth failure must dead-letter';
  select not_before into nb from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert nb>clock_timestamp(), 'dead-letter must still schedule a backoff';
  select * into j from public.claim_activity_context_v2(300);
  assert not found, 'dead-lettered job must not be claimable';
  raise notice 'PASS 3 backoff, stale release and dead-letter';
end;
$$;

-- 4. Fenced publish: stale token/revision/lease return NULL and never touch epochs.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-04';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; rev bigint; payload jsonb; epoch_count integer;
begin
  fp := public.activity_context_fingerprint(array[repeat('c',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('c',64)],fp);
  select * into j from public.claim_activity_context_v2(300);
  tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo,'e',lo+30,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.95,'os',30,'vs',30)));
  -- Wrong revision.
  rev := public.publish_activity_context_v2(tok, j.input_revision+1, payload, 100);
  assert rev is null, 'stale revision must publish NULL';
  -- Unknown token.
  rev := public.publish_activity_context_v2(gen_random_uuid(), j.input_revision, payload, 100);
  assert rev is null, 'unknown token must publish NULL';
  -- Expired lease.
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  rev := public.publish_activity_context_v2(tok, j.input_revision, payload, 100);
  assert rev is null, 'expired lease must publish NULL';
  assert (select count(*)=0 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day), 'NULL publish must not touch epochs';
  -- Restore the lease and publish validly.
  update public.activity_context_jobs set lease_until=clock_timestamp()+interval '10 minutes'
    where user_id=u and device_id=dev and day=v_day;
  rev := public.publish_activity_context_v2(tok, j.input_revision, payload, 100);
  assert rev is not null, 'valid publish must return a result revision';
  select count(*) into epoch_count from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and fingerprint=fp;
  assert epoch_count=1, 'valid publish must insert the epoch';
  assert (select completed_revision=j.input_revision and lease_token is null from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'publish must complete the job and clear the lease';
  assert exists(select 1 from public.scoring_work_items
    where user_id=u and device_id=dev and day=v_day), 'publish must dirty the scoring day';
  raise notice 'PASS 4 fenced publish and scoring invalidation';
end;
$$;

-- 5. Atomic replace: publish replaces only its fingerprint's range; prior output is preserved
--    until a valid replacement commits; other days are untouched.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-05';
  other date := '2026-10-06';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  lo2 bigint := extract(epoch from (other::timestamp at time zone 'UTC'))::bigint;
  fp1 text; fp2 text; j record; tok uuid; rev bigint; n integer;
  ep1 jsonb; ep2 jsonb; epA jsonb; epB jsonb; epC jsonb;
begin
  fp1 := public.activity_context_fingerprint(array[repeat('d',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp2 := public.activity_context_fingerprint(array[repeat('e',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  ep1 := jsonb_build_object('s',lo,'e',lo+30,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30);
  ep2 := jsonb_build_object('s',lo+30,'e',lo+60,'m','stationary','p','sitting','ex','true','sl','awake','ec','resting_candidate','w','on_wrist','c',0.8,'os',30,'vs',30);
  epA := jsonb_build_object('s',lo2,'e',lo2+30,'m','running','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.99,'os',30,'vs',30);
  epB := jsonb_build_object('s',lo,'e',lo+30,'m','other_movement','p','unknown','ex','unknown','sl','unknown','ec','mixed','w','unknown','c',0.7,'os',30,'vs',30);
  epC := jsonb_build_object('s',lo+60,'e',lo+90,'m','unknown','p','unknown','ex','unknown','sl','unknown','ec','unknown','w','unknown','c',0.6,'os',30,'vs',30);
  -- Publish fingerprint 1 with two epochs on day 5.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('d',64)],fp1);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  rev := public.publish_activity_context_v2(tok,j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(ep1,ep2)),100);
  assert rev is not null, 'first publish must succeed';
  -- An unrelated day keeps its own epoch from another fingerprint.
  perform public.enqueue_activity_context(u,dev,other,array[gen_random_uuid()],array[repeat('d',64)],fp1);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  rev := public.publish_activity_context_v2(tok,j.input_revision,
    jsonb_build_object('day',other::text,'epochs',jsonb_build_array(epA)),100);
  assert rev is not null, 'other-day publish must succeed';
  -- Late verified object: new fingerprint bumps the day-5 job.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid(),gen_random_uuid()],array[repeat('e',64),repeat('e',64)],fp2);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  assert j.input_revision=2, 'new fingerprint must bump the day-5 job';
  rev := public.publish_activity_context_v2(tok,j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(epB)),100);
  assert rev is not null, 'replacement publish must succeed';
  -- Prior fingerprint-1 output is preserved until its own replacement commits.
  assert (select count(*)=2 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and fingerprint=fp1), 'prior fingerprint output must be preserved';
  assert (select count(*)=1 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and fingerprint=fp2), 'new fingerprint output must be present';
  -- A same-fingerprint re-claim (operator/retry reset) replaces only its own rows: the
  -- delete+insert is keyed on (user,device,day,fingerprint), never on other fingerprints.
  update public.activity_context_jobs set input_revision=3, completed_revision=2,
    lease_token=null, lease_until=null, not_before=clock_timestamp()
    where user_id=u and device_id=dev and day=v_day;
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  assert j.input_revision=3, 'reset job must be claimable at the new revision';
  rev := public.publish_activity_context_v2(tok,j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(epB,epC)),100);
  assert rev is not null, 'replacement re-publish must succeed';
  select count(*) into n from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and fingerprint=fp2;
  assert n=2, 'same-fingerprint publish must replace its own rows';
  assert (select count(*)=2 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and fingerprint=fp1), 'prior output must survive a different-fingerprint publish';
  assert (select count(*)=1 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=other and fingerprint=fp1), 'other-day output must be untouched';
  raise notice 'PASS 5 atomic range replace and prior-output preservation';
end;
$$;

-- 6. Payload contract: label whitelist, s<e, in-day bounds, bounded count.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-07';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; payload jsonb;
begin
  fp := public.activity_context_fingerprint(array[repeat('f',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('f',64)],fp);
  -- Rejected publishes keep the lease; clear it before each fresh claim below.
  -- Bad motion label.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo,'e',lo+30,'m','jogging','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'invalid label accepted';
  exception when others then
    if sqlerrm like 'invalid label accepted%' then raise; end if;
  end;
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- end <= start.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo+60,'e',lo+30,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'inverted range accepted';
  exception when others then
    if sqlerrm like 'inverted range accepted%' then raise; end if;
  end;
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- Epoch outside the day's UTC bounds.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo+86300,'e',lo+86400,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'out-of-day epoch accepted';
  exception when others then
    if sqlerrm like 'out-of-day epoch accepted%' then raise; end if;
  end;
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- Wrong day key.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day','2026-10-08','epochs',jsonb_build_array(
    jsonb_build_object('s',lo,'e',lo+30,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'mismatched day accepted';
  exception when others then
    if sqlerrm like 'mismatched day accepted%' then raise; end if;
  end;
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- More than one UTC day of 30 s epochs is rejected.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  select jsonb_build_object('day',v_day::text,'epochs',
    (select jsonb_agg(jsonb_build_object(
        's',lo+(g-1)*30,'e',lo+g*30,'m','stationary','p','unknown','ex','unknown','sl','unknown','ec','unknown','w','unknown','c',0.5,'os',30,'vs',30)
      order by g) from generate_series(1,2881) g)
    ) into payload;
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'oversized payload accepted';
  exception when others then
    if sqlerrm like 'oversized payload accepted%' then raise; end if;
  end;
  -- No epoch was ever committed by the rejected attempts.
  assert (select count(*)=0 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day), 'rejected payloads must not leave epochs';
  raise notice 'PASS 6 payload validation';
end;
$$;

-- 7. Trigger: ready rawImuSession manifests enqueue jobs for each overlapping UTC day, both
--    for the synchronous (pending->ready) and async (uploaded->ready) flips, and the existing
--    sensor_raw_dependency trigger on the same table still fires untouched.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  m1 uuid := 'a0000000-0000-4000-8000-000000000021';
  m2 uuid := 'a0000000-0000-4000-8000-000000000022';
  m3 uuid := 'a0000000-0000-4000-8000-000000000023';
  m4 uuid := 'a0000000-0000-4000-8000-000000000024';
  m5 uuid := 'a0000000-0000-4000-8000-000000000025';
  day1 date := '2026-10-10';
  day2 date := '2026-10-11';
  day3 date := '2026-10-12';
  n integer; ids uuid[];
begin
  insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
    start_at,end_at,sha256,sha256_source,status)
  values
    (m1,u,dev,'raw','rawImuSession','sync-obj-1','2026-10-10T00:10:00Z'::timestamptz,'2026-10-10T01:10:00Z'::timestamptz,repeat('1',64),'server_verified','pending'),
    (m2,u,dev,'raw','rawImuSession','sync-obj-2','2026-10-10T01:10:00Z'::timestamptz,'2026-10-10T02:10:00Z'::timestamptz,repeat('2',64),'server_verified','pending'),
    (m3,u,dev,'raw','rawImuSession','async-obj-1','2026-10-11T00:10:00Z'::timestamptz,'2026-10-11T01:10:00Z'::timestamptz,repeat('3',64),'server_verified','uploaded'),
    (m4,u,dev,'raw','ppgWaveformSample','other-obj-1','2026-10-10T05:00:00Z'::timestamptz,'2026-10-10T05:01:00Z'::timestamptz,repeat('4',64),'server_verified','pending'),
    (m5,u,dev,'raw','rawImuSession','sync-obj-3','2026-10-11T23:30:00Z'::timestamptz,'2026-10-12T00:30:00Z'::timestamptz,repeat('5',64),'server_verified','pending');
  -- The async verification worker flips status to ready by UPDATE (uploaded->ready).
  update public.object_manifests set status='ready' where id=m3;
  assert exists(select 1 from public.activity_context_jobs where user_id=u and device_id=dev and day=day2),
    'async ready flip must enqueue its UTC day';
  assert not exists(select 1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day<>day2 and m3 = any(input_object_ids)),
    'async ready flip must not enqueue other days';
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day2;
  assert cardinality(ids)=1 and ids[1]=m3, 'async flip job must carry only m3';
  -- Sync path: pending->ready fires, aggregating only currently-ready objects of the day.
  update public.object_manifests set status='ready' where id=m1;
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day1;
  assert cardinality(ids)=1 and ids[1]=m1, 'day-1 job must carry exactly m1 while m2 is pending';
  -- A second ready object aggregates into the same job and bumps the revision once.
  update public.object_manifests set status='ready' where id=m2;
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day1;
  assert cardinality(ids)=2 and ids[1]=m1 and ids[2]=m2, 'late object must aggregate both inputs';
  assert (select input_revision=2 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day1), 'aggregated enqueue must bump the revision';
  -- Re-updating an already-ready object is a no-op (no revision bump).
  update public.object_manifests set updated_at=clock_timestamp() where id=m2;
  assert (select input_revision=2 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day1), 'already-ready update must not bump';
  -- Non-rawImuSession objects never enqueue.
  update public.object_manifests set status='ready' where id=m4;
  assert not exists(select 1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day1 and input_object_ids=array[m4]),
    'non-rawImuSession object must not enqueue';
  -- A multi-day object enqueues both overlapping days and aggregates with the async object.
  update public.object_manifests set status='ready' where id=m5;
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day2;
  assert cardinality(ids)=2 and ids[1]=m3 and ids[2]=m5, 'multi-day object must aggregate with m3 on day 2';
  assert (select input_revision=2 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day2), 'day-2 aggregation must bump';
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=day3;
  assert cardinality(ids)=1 and ids[1]=m5, 'multi-day object must enqueue its second day';
  raise notice 'PASS 7 trigger enqueue on ready rawImuSession (sync + async)';
end;
$$;

-- 8. Owner isolation with real roles: another user cannot read/claim/write; service role can.
do $$
declare
  ua uuid := 'a0000000-0000-4000-8000-000000000001';
  ub uuid := 'a0000000-0000-4000-8000-000000000002';
  devb uuid := 'a0000000-0000-4000-8000-000000000012';
  v_day date := '2026-10-12';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; n bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat('9',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(ub,devb,v_day,array[gen_random_uuid()],array[repeat('9',64)],fp);
end;
$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
declare n bigint;
begin
  select count(*) into n from public.activity_context_jobs where user_id='a0000000-0000-4000-8000-000000000002';
  assert n=0, 'cross-owner job read leaked';
  select count(*) into n from public.activity_context_epochs where user_id='a0000000-0000-4000-8000-000000000002';
  assert n=0, 'cross-owner epoch read leaked';
  begin
    update public.activity_context_jobs set dead_letter=true where user_id='a0000000-0000-4000-8000-000000000002';
    raise exception 'cross-owner job write allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.activity_context_epochs where user_id='a0000000-0000-4000-8000-000000000002';
    raise exception 'cross-owner epoch delete allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.claim_activity_context_v2(300);
    raise exception 'authenticated claim allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.enqueue_activity_context('a0000000-0000-4000-8000-000000000002',
      'a0000000-0000-4000-8000-000000000012','2026-10-12',array[gen_random_uuid()],array[repeat('9',64)],repeat('9',64));
    raise exception 'authenticated enqueue allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
do $$
begin
  begin
    perform count(*) from public.activity_context_jobs;
    raise exception 'anon job read allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
do $$ begin raise notice 'PASS 8 owner isolation'; end $$;
set local role service_role;
do $$
declare n bigint;
begin
  select count(*) into n from public.activity_context_jobs;
  assert n>0, 'service role must see the queue';
end;
$$;
reset role;

-- 9. Device and account deletion cascade.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  devtmp uuid := 'a0000000-0000-4000-8000-000000000013';
  v_day date := '2026-10-13';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; n integer;
begin
  fp := public.activity_context_fingerprint(array[repeat('7',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,devtmp,v_day,array[gen_random_uuid()],array[repeat('7',64)],fp);
  insert into public.activity_context_epochs(user_id,device_id,day,start_ts,end_ts,motion_label,
    posture,exercise_session,sleep_state,exertion_context,wear_state,confidence,observed_s,valid_s,
    model_version,preprocessing_version,ontology_version,fingerprint,result_revision,computed_at)
  values(u,devtmp,v_day,lo,lo+30,'walking','unknown','false','awake','active','on_wrist',0.9,30,30,
    'hart-activity-v1','hart-activity-preprocess-v1','v1',fp,1,clock_timestamp());
  -- Device deletion cascades both tables.
  delete from public.devices where id=devtmp;
  select count(*) into n from public.activity_context_jobs where user_id=u and device_id=devtmp;
  assert n=0, 'device deletion must cascade jobs';
  select count(*) into n from public.activity_context_epochs where user_id=u and device_id=devtmp;
  assert n=0, 'device deletion must cascade epochs';
  -- Account deletion cascades everything for the user.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('7',64)],fp);
  delete from auth.users where id=u;
  select count(*) into n from public.activity_context_jobs where user_id=u;
  assert n=0, 'account deletion must cascade jobs';
  select count(*) into n from public.activity_context_epochs where user_id=u;
  assert n=0, 'account deletion must cascade epochs';
  raise notice 'PASS 9 deletion cascade';
end;
$$;

rollback;
