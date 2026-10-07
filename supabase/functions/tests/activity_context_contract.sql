-- Activity-context DB contract (contracts C5 + C10). Runs inside the isolated, fully migrated
-- test database with 20261003120000_activity_context.sql (sections 1-11),
-- 20261003130000_activity_context_days.sql (section 12, the ActivityContext v2 day documents),
-- 20261003140000_activity_context_stream_days.sql (section 13, stream days and the read surface) and
-- 20261004150000_activity_context_canonical_class.sql (section 14, the canonical class columns) and
-- 20261007120000_activity_context_current_lineage_and_versions.sql (section 15, the current-lineage view
-- and version-driven re-derivation) applied. Every fixture change rolls back; no deployed credentials or data are touched.
-- Statement timeout keeps a misbehaving assertion from hanging a disposable cluster.
--
-- Run against a disposable cluster the way the other *.sql tests run:
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261003120000_activity_context.sql \
--        -f ../../migrations/20261003130000_activity_context_days.sql \
--        -f ../../migrations/20261003140000_activity_context_stream_days.sql \
--        -f ../../migrations/20261004150000_activity_context_canonical_class.sql \
--        -f ../../migrations/20261007120000_activity_context_current_lineage_and_versions.sql \
--        -f activity_context_contract.sql
-- (the migrations must apply to a fully migrated Supabase-style schema first; the fixtures here
-- only need base_schema, production_persistence, scoring_service_state, physiology_revisions,
-- the devices_owner_identity unique constraint and these migrations).
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

-- 3b. Supersede accounting (P2-2): a fail against the CLAIMED (stale) revision after a
--     supersede is a CLEAN RELEASE (clear lease, reset failures, no backoff bump, no
--     dead-letter); a fail against the CURRENT revision counts exactly like fail_scoring_v2.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-20';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp1 text; fp2 text; j record; tok uuid; n integer; nb timestamptz;
begin
  fp1 := public.activity_context_fingerprint(array[repeat('i',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp2 := public.activity_context_fingerprint(array[repeat('j',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('i',64)],fp1);
  select * into j from public.claim_activity_context_v2(300);
  assert found and j.input_revision=1, 'supersede test must claim the fresh job at revision 1';
  tok := j.lease_token;
  -- A late object supersedes the job mid-inference: revision bumps while the lease is held.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('j',64)],fp2);
  assert (select input_revision=2 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'supersede must bump the revision';
  -- Worker releases with the CLAIMED (stale) revision 1 -> clean release, no failure counted.
  perform public.fail_activity_context_v2(tok, 1, 'superseded');
  select consecutive_failures, dead_letter, not_before, last_error, lease_token into n, j.dead_letter, nb, j.last_error, j.lease_token
    from public.activity_context_jobs where user_id=u and device_id=dev and day=v_day;
  assert n=0, 'stale-revision release must not count a failure';
  assert not j.dead_letter, 'stale-revision release must not dead-letter';
  assert nb<=clock_timestamp(), 'stale-revision release must not push the backoff';
  assert j.last_error is null, 'stale-revision release must not record an error';
  assert j.lease_token is null, 'stale-revision release must clear the lease';
  -- A real failure against the CURRENT revision counts, matching fail_scoring_v2.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  assert found and j.input_revision=2, 'superseded job must be claimable at revision 2';
  perform public.fail_activity_context_v2(tok, 2, 'model error');
  select consecutive_failures, last_error into n, j.last_error from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert n=1, 'matching-revision failure must count';
  assert j.last_error='model error', 'matching-revision failure must record the error';
  raise notice 'PASS 3b supersede clean release vs matching failure';
end;
$$;

-- 3c. Dead-letter durability (P2-3): a same-fingerprint enqueue must NOT resurrect a
--     dead-lettered job or cancel its backoff; only a changed fingerprint re-enqueues fresh.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-21';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp1 text; fp2 text; j record; tok uuid; i integer; n integer; dl boolean; nb timestamptz;
begin
  fp1 := public.activity_context_fingerprint(array[repeat('n',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp2 := public.activity_context_fingerprint(array[repeat('o',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('n',64)],fp1);
  -- Drive the job to dead-letter (8 consecutive failures).
  for i in 1..8 loop
    update public.activity_context_jobs set not_before=clock_timestamp()
      where user_id=u and device_id=dev and day=v_day;
    select * into j from public.claim_activity_context_v2(300);
    assert found, 'job must remain claimable before dead-letter';
    perform public.fail_activity_context_v2(j.lease_token, j.input_revision, 'boom');
  end loop;
  select dead_letter, consecutive_failures into dl, n from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert dl and n=8, 'job must be dead-lettered at 8 failures';
  -- Same-fingerprint enqueue (identical digests): dead_letter stays set, failures stay at 8,
  -- the backoff is not cancelled, and the job is NOT claimable again.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('n',64)],fp1);
  select dead_letter, consecutive_failures, not_before into dl, n, nb from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert dl, 'same-fingerprint enqueue must not resurrect a dead-lettered job';
  assert n=8, 'same-fingerprint enqueue must not reset consecutive_failures';
  assert nb>clock_timestamp(), 'same-fingerprint enqueue must not cancel the backoff';
  select * into j from public.claim_activity_context_v2(300);
  assert not found, 'dead-lettered job must stay unclaimable after a same-fingerprint enqueue';
  -- A changed fingerprint re-enqueues fresh: dead_letter cleared, failures reset, claimable.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('o',64)],fp2);
  select dead_letter, consecutive_failures into dl, n from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert not dl, 'changed-fingerprint enqueue must clear the dead-letter';
  assert n=0, 'changed-fingerprint enqueue must reset consecutive_failures';
  select * into j from public.claim_activity_context_v2(300);
  assert found, 'changed-fingerprint enqueue must make the job claimable again';
  raise notice 'PASS 3c dead-letter stickiness';
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
  -- Prior fingerprint-1 output is preserved: the table keeps history for causal replay, and current
  -- readers read the newest publish of the day through activity_context_epochs_current (section 15).
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
  -- Epoch ending after the day's UTC bounds (e > dayEnd) is rejected; e == dayEnd is the
  -- valid final 30-s epoch of the day and is covered by the boundary block at the end.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo+86300,'e',lo+86401,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
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

-- 6b. Midnight boundary (P1-1): the day's FINAL 30-s epoch [dayEnd-30, dayEnd) legitimately ends
--     at e == dayEnd (half-open [s,e), exactly where a model window covering 23:59:30..00:00:00
--     lands). e == dayEnd must publish; e == dayEnd+1 must still be rejected.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-09';
  lo bigint; fp text; j record; tok uuid; rev bigint; payload jsonb;
begin
  lo := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp := public.activity_context_fingerprint(array[repeat('h',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('h',64)],fp);
  -- e == dayEnd+1 still rejected.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo+86370,'e',lo+86401,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'post-day epoch accepted';
  exception when others then
    if sqlerrm like 'post-day epoch accepted%' then raise; end if;
  end;
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  -- e == dayEnd publishes the final epoch of the day.
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo+86370,'e',lo+86400,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  rev := public.publish_activity_context_v2(tok,j.input_revision,payload,100);
  assert rev is not null, 'final epoch e==dayEnd must publish';
  assert exists(select 1 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day and start_ts=lo+86370 and end_ts=lo+86400
      and fingerprint=fp), 'final epoch must be stored with end_ts == dayEnd';
  -- An epoch starting before the day is still rejected alongside e==dayEnd acceptance.
  update public.activity_context_jobs set input_revision=2, completed_revision=1,
    lease_token=null, lease_until=null, not_before=clock_timestamp()
    where user_id=u and device_id=dev and day=v_day;
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  payload := jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
    jsonb_build_object('s',lo-1,'e',lo+29,'m','walking','p','unknown','ex','false','sl','awake','ec','active','w','on_wrist','c',0.9,'os',30,'vs',30)));
  begin
    perform public.publish_activity_context_v2(tok,j.input_revision,payload,100);
    raise exception 'pre-day epoch accepted';
  exception when others then
    if sqlerrm like 'pre-day epoch accepted%' then raise; end if;
  end;
  raise notice 'PASS 6b midnight boundary';
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
  begin
    perform public.reconcile_activity_context();
    raise exception 'authenticated reconcile allowed';
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

-- 10. Merge + reconcile (P2-1): ready-flips that race under READ COMMITTED enqueue per-object
--     subsets; the conflict branch MERGES them so both objects land in one job, and the
--     reconcile RPC re-adds a missed enqueue idempotently without duplicating jobs or epochs.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-14';
  v_day2 date := '2026-10-15';
  lo bigint; lo2 bigint;
  ma uuid := 'a0000000-0000-4000-8000-000000000031';
  mb uuid := 'a0000000-0000-4000-8000-000000000032';
  mc uuid := 'a0000000-0000-4000-8000-000000000033';
  fp_a text; fp_b text; fp_c text;
  ids uuid[]; digests text[]; n integer; rev bigint; job_count integer;
begin
  -- Section 9 deleted the account; re-create the owner/device for this section.
  insert into auth.users(id) values (u);
  insert into public.devices(id,user_id,source_kind) values (dev,u,'noop_push');
  lo := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  lo2 := extract(epoch from (v_day2::timestamp at time zone 'UTC'))::bigint;
  fp_a := public.activity_context_fingerprint(array[repeat('k',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp_b := public.activity_context_fingerprint(array[repeat('l',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp_c := public.activity_context_fingerprint(array[repeat('m',64)],lo2,lo2+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  -- Two objects for the same day: object A flips ready first (trigger enqueues {A}).
  insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
    start_at,end_at,sha256,sha256_source,status,verified_at)
  values
    (ma,u,dev,'raw','rawImuSession','race-obj-a','2026-10-14T00:10:00Z'::timestamptz,'2026-10-14T01:10:00Z'::timestamptz,repeat('k',64),'server_verified','pending',null),
    (mb,u,dev,'raw','rawImuSession','race-obj-b','2026-10-14T01:10:00Z'::timestamptz,'2026-10-14T02:10:00Z'::timestamptz,repeat('l',64),'server_verified','pending',null),
    (mc,u,dev,'raw','rawImuSession','missed-obj-c','2026-10-15T00:10:00Z'::timestamptz,'2026-10-15T01:10:00Z'::timestamptz,repeat('m',64),'server_verified','pending',clock_timestamp());
  update public.object_manifests set status='ready' where id=ma;
  select input_object_ids into ids from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert cardinality(ids)=1 and ids[1]=ma, 'first ready flip must enqueue {A}';
  -- Object C becomes ready+verified; its ready flip enqueues {C} on day 2.
  update public.object_manifests set status='ready' where id=mc;
  -- B flips ready concurrently but its statement snapshot did not see A: it enqueues {B} as
  -- a per-object subset. The merge must keep A's contribution instead of last-writer-wins.
  perform public.enqueue_activity_context(u,dev,v_day,array[mb],array[repeat('l',64)],fp_b);
  select input_object_ids, input_revision into ids, rev from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day;
  assert cardinality(ids)=2 and ma = any(ids) and mb = any(ids),
    'concurrent per-object enqueues must aggregate BOTH objects into one job';
  assert rev=2, 'merged enqueue must bump the revision once';
  select count(*) into job_count from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day and algorithm_version='hart-activity-1';
  assert job_count=1, 'merged enqueues must not create duplicate jobs';
  -- Reconcile after a MISSED enqueue: object C is ready+verified but its enqueue never
  -- happened (job deleted, e.g. an enqueue crash between the ready flip and the RPC).
  delete from public.activity_context_jobs where user_id=u and device_id=dev and day=v_day2;
  assert not exists(select 1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day2), 'missed-enqueue setup must start clean';
  perform public.reconcile_activity_context('30 days');
  select input_object_ids, input_revision into ids, rev from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day2;
  assert cardinality(ids)=1 and ids[1]=mc, 'reconcile must re-add the missed object';
  assert rev=1, 'reconcile must create a fresh job for the missed object';
  -- Reconcile is idempotent: a second pass is a no-op (no revision bump, still one job).
  perform public.reconcile_activity_context('30 days');
  assert (select input_revision=1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day2), 'reconcile replay must not bump the revision';
  select count(*) into job_count from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day2;
  assert job_count=1, 'reconcile replay must not duplicate jobs';
  -- Reconcile never writes epochs.
  assert (select count(*)=0 from public.activity_context_epochs
    where user_id=u and device_id=dev and day=v_day2), 'reconcile must never write epochs';
  -- Reconcile on an already-current job stays a no-op even after a direct same-set enqueue.
  perform public.enqueue_activity_context(u,dev,v_day2,array[mc],array[repeat('m',64)],fp_c);
  perform public.reconcile_activity_context('30 days');
  assert (select input_revision=1 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day2), 'reconcile on an already-current job must stay a no-op';
  raise notice 'PASS 10 merge + reconcile';
end;
$$;

rollback;


-- 11. Publish stamps the versions the LANE resolved (payload) onto the job row and every
-- epoch row — a baseline child must never stamp rows as the HART version (audit P2 residual).
begin;
insert into auth.users(id) values ('a0000000-0000-4000-8000-000000000001');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push');
do $$
declare u uuid := 'a0000000-0000-4000-8000-000000000001';
        dev uuid := 'a0000000-0000-4000-8000-000000000011';
        v_day date := '2026-10-02';
        tok uuid; rev bigint; fp text := repeat('e',64);
        epoch_s bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
begin
  perform public.enqueue_activity_context(u,dev,v_day,
    array['d0000000-0000-4000-8000-0000000000d1'::uuid],array[repeat('d',64)],fp,'hart-activity-1','pre-1','v1');
  select lease_token into tok from public.claim_activity_context_v2(60);
  assert tok is not null, 'claim must succeed';
  perform public.publish_activity_context_v2(tok, 1,
    jsonb_build_object(
      'day', v_day,
      'model_version', 'baseline-v0',
      'preprocessing_version', '1.0.0',
      'epochs', jsonb_build_array(
        jsonb_build_object('s',epoch_s,'e',epoch_s+30,'m','stationary','p','unknown',
          'ex','unknown','sl','awake','ec','unknown','w','unknown',
          'c',0.9,'os',30,'vs',30))),
    10);
  assert (select model_version='baseline-v0' and preprocessing_version='1.0.0'
            from public.activity_context_jobs
           where user_id=u and device_id=dev and day=v_day),
    'publish must stamp the payload versions onto the job row';
  assert (select count(*)=1 from public.activity_context_epochs
            where user_id=u and device_id=dev and day=v_day and model_version='baseline-v0'
              and preprocessing_version='1.0.0'),
    'publish must stamp the payload versions onto the epoch rows';
  raise notice 'PASS 11 publish stamps resolved versions';
end;
$$;

rollback;


-- 12. ActivityContext v2 day documents (20261003130000_activity_context_days.sql): the fenced
-- publish stores one decoded document per (owner, device, UTC day, algorithm) next to the v1
-- epochs, never completes the job itself, and a rejected document cannot block the v1 publish.
begin;
set local statement_timeout = '120s';
insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push'),
 ('a0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000002','noop_push'),
 ('a0000000-0000-4000-8000-000000000013','a0000000-0000-4000-8000-000000000001','noop_push');

create function pg_temp.day_run(p_s bigint, p_e bigint, p_label text default 'sitting') returns jsonb
language sql as $$
  select jsonb_build_object('s',p_s,'e',p_e,
    'posture',jsonb_build_object('seated_likely',0.8,'unknown',0.2),
    'locomotion',jsonb_build_object('stationary',0.9,'walking',0.1),
    'arm_behavior',jsonb_build_object('desk_like',0.7),
    'intensity',0.02,'overall_confidence',0.81,'overall_uncertainty',0.3,
    'display_context',p_label,'sleep','awake','wear','on_wrist','n',((p_e-p_s)/5)::integer)
$$;
create function pg_temp.day_doc(p_day date, p_runs jsonb default null, p_events jsonb default null)
returns jsonb language sql as $$
  select jsonb_build_object(
    'schema_version',2,
    'versions',jsonb_build_object('schema',2,'ontology','v2.0','decoder','hsmm-1.1',
      'feature_schema','imu-feat-1','encoder','hart','encoder_version','hart-activity-v1'),
    'day_start',extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint,
    'day_end',extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 86400,
    'publish_interval_s',5,'generated_at',1790000000,
    'data_through',extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 3600,
    'observed_s',3600,'sleep_known_outside',false,'context_fp','abc123',
    'runs',coalesce(p_runs,jsonb_build_array(
      pg_temp.day_run(extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint,
                      extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 1800),
      jsonb_set(pg_temp.day_run(extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 1800,
                                extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 3600),
                '{display_context}','null'::jsonb))),
    'events',coalesce(p_events,jsonb_build_array(jsonb_build_object('kind','sit_to_stand_like','probability',0.7,
      'ts',extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint + 1800))),
    'latest',null,
    'summary',jsonb_build_object('label_s',jsonb_build_object('sitting',1800),'unclear_s',1800,'mean_confidence',0.81))
$$;
create function pg_temp.day_payload(p_day date, p_doc jsonb default null) returns jsonb language sql as $$
  select jsonb_build_object('day',p_day::text,'model_version','hart-activity-v1',
    'preprocessing_version','hart-activity-preprocess-v1','document',coalesce(p_doc,pg_temp.day_doc(p_day)))
$$;
-- The v1 publish that completes a job, as the worker issues it right after the day document.
create function pg_temp.complete_v1(p_tok uuid, p_rev bigint, p_day date) returns bigint
language sql as $$
  select public.publish_activity_context_v2(p_tok, p_rev,
    jsonb_build_object('day',p_day::text,'epochs','[]'::jsonb), 10)
$$;
-- True when the publish raised exactly the expected stable message.
create function pg_temp.rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_context_day(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 12.1 Fenced publish stores the document; the job stays claimed until the v1 publish completes it.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-20';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; rev bigint; v1rev bigint; r record;
begin
  fp := public.activity_context_fingerprint(array[repeat('1',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('1',64)],fp);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  rev := public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day));
  assert rev is not null and rev >= 1, 'a valid day document must return a result revision';
  select * into r from public.activity_context_days where user_id=u and device_id=dev and day=v_day;
  assert found, 'the day document row must exist';
  assert r.algorithm_version='hart-activity-1' and r.schema_version=2 and r.ontology_version='v2.0'
     and r.decoder_version='hsmm-1.1' and r.feature_schema='imu-feat-1', 'version stamps must be denormalized';
  assert r.encoder_id='hart' and r.encoder_version='hart-activity-v1', 'encoder identity must be denormalized';
  assert r.model_version='hart-activity-v1' and r.preprocessing_version='hart-activity-preprocess-v1',
    'lane-resolved versions must be stamped';
  assert r.job_fingerprint=fp and r.input_revision=j.input_revision, 'row must record the job lineage';
  assert r.run_count=2 and r.event_count=1 and r.unclear_s=1800 and r.observed_s=3600
     and r.data_through=lo+3600 and r.publish_interval_s=5 and r.context_fp='abc123',
    'scalar columns must mirror the document';
  assert abs(r.mean_confidence-0.81)<0.0001, 'mean confidence must be mirrored';
  assert r.document = pg_temp.day_doc(v_day), 'the document must be stored verbatim';
  assert r.result_revision=rev and r.computed_at is not null, 'result revision and computed_at must be stamped';
  -- The v2 write is not a completion: the lease is intact and scoring is not dirtied by it.
  assert (select lease_token=tok and completed_revision=0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the day publish must not complete the job or clear the lease';
  assert not exists(select 1 from public.scoring_work_items where user_id=u and device_id=dev and day=v_day),
    'the day publish alone must not dirty scoring';
  -- The v1 publish (same transaction, as the worker does) still completes the job as before.
  v1rev := public.publish_activity_context_v2(tok, j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
      jsonb_build_object('s',lo,'e',lo+30,'m','stationary','p','sitting','ex','false','sl','awake',
        'ec','resting_candidate','w','on_wrist','c',0.9,'os',30,'vs',30))),100);
  assert v1rev is not null, 'the v1 publish must still succeed after the day publish';
  assert (select completed_revision=j.input_revision and lease_token is null from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'only the v1 publish completes the job';
  assert exists(select 1 from public.scoring_work_items where user_id=u and device_id=dev and day=v_day),
    'the v1 publish must dirty the scoring day';
  assert (select count(*)=1 from public.activity_context_epochs where user_id=u and device_id=dev and day=v_day),
    'v1 epochs must be unaffected by the day document';
  assert (select document = pg_temp.day_doc(v_day) from public.activity_context_days
    where user_id=u and device_id=dev and day=v_day), 'the v1 publish must not touch the day document';
  raise notice 'PASS 12.1 day document stored, job completion left to v1';
end;
$$;

-- 12.2 Fence: stale revision, unknown token, expired lease return NULL and write nothing.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-21';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; rev bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat('2',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('2',64)],fp);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  assert j.day=v_day, 'test must have claimed its own job';
  assert public.publish_activity_context_day(tok, j.input_revision+1, pg_temp.day_payload(v_day)) is null,
    'stale revision must publish NULL';
  assert public.publish_activity_context_day(gen_random_uuid(), j.input_revision, pg_temp.day_payload(v_day)) is null,
    'unknown token must publish NULL';
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  assert public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day)) is null,
    'expired lease must publish NULL';
  -- A malformed payload with a dead lease is fenced out before validation: still NULL, no error.
  assert public.publish_activity_context_day(tok, j.input_revision, '[]'::jsonb) is null,
    'fence must be evaluated before payload validation';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'a fenced-out publish must not write a row';
  update public.activity_context_jobs set lease_until=clock_timestamp()+interval '10 minutes'
    where user_id=u and device_id=dev and day=v_day;
  rev := public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day));
  assert rev is not null, 'restored lease must publish';
  -- A superseded worker (revision bumped by a late object) cannot overwrite the newer lineage.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid(),gen_random_uuid()],
    array[repeat('2',64),repeat('3',64)],repeat('f',64));
  assert public.publish_activity_context_day(tok, j.input_revision,
    pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(), jsonb_build_array()))) is null,
    'a superseded revision must publish NULL';
  assert (select result_revision=rev and run_count=2 from public.activity_context_days
    where user_id=u and device_id=dev and day=v_day), 'a fenced-out publish must not modify the stored row';
  raise notice 'PASS 12.2 fence';
end;
$$;

-- 12.3 Payload contract: every malformed document is rejected with a stable message and writes nothing.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-22';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; rev bigint; doc jsonb; good_run jsonb; too_many jsonb;
begin
  fp := public.activity_context_fingerprint(array[repeat('4',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('4',64)],fp);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  rev := j.input_revision;
  doc := pg_temp.day_doc(v_day);
  good_run := pg_temp.day_run(lo, lo+30);

  -- Envelope.
  assert pg_temp.rejects(tok,rev,'[]'::jsonb,'invalid_activity_day_payload'), 'non-object payload';
  assert pg_temp.rejects(tok,rev,jsonb_build_object('day',v_day::text),'invalid_activity_day_payload'), 'missing document';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload('2026-10-23'),'invalid_activity_day_payload'), 'payload for another day';
  assert pg_temp.rejects(tok,rev,jsonb_set(pg_temp.day_payload(v_day),'{day}','"garbage"'),'invalid_activity_day_payload'), 'unparseable day';
  assert pg_temp.rejects(tok,rev,jsonb_set(pg_temp.day_payload(v_day),'{document}','[]'),'invalid_activity_day_payload'), 'document must be an object';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, doc || jsonb_build_object('snapshot', repeat('x', 17000000))),
    'invalid_activity_day_size'), 'oversized payload';

  -- Document header.
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{day_start}',to_jsonb(lo+1))),'invalid_activity_day_document'), 'day_start must match the job day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{day_end}',to_jsonb(lo+86399))),'invalid_activity_day_document'), 'day_end must match the job day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{schema_version}','1')),'invalid_activity_day_document'), 'schema 1 belongs to the v1 document';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{schema_version}','2.5')),'invalid_activity_day_document'), 'schema must be an integer';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{observed_s}','90000')),'invalid_activity_day_document'), 'observed_s beyond a day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{publish_interval_s}','0')),'invalid_activity_day_document'), 'publish interval below 1';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{runs}','{}')),'invalid_activity_day_document'), 'runs must be an array';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{events}','"x"')),'invalid_activity_day_document'), 'events must be an array';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{data_through}',to_jsonb(lo+90000))),'invalid_activity_day_document'), 'data_through beyond the day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{summary,label_s}','[]')),'invalid_activity_day_document'), 'summary.label_s must be an object';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, doc - 'summary'),'invalid_activity_day_document'), 'summary is required';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{summary,mean_confidence}','1.5')),'invalid_activity_day_document'), 'mean confidence above 1';

  -- Version stamps.
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{versions,ontology}','"bad value!"')),'invalid_activity_day_versions'), 'ontology must be an identifier';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{versions}', (doc->'versions') - 'decoder')),'invalid_activity_day_versions'), 'decoder version is required';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{versions,schema}','3')),'invalid_activity_day_versions'), 'versions.schema must agree with schema_version';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{versions,encoder}','"a b"')),'invalid_activity_day_versions'), 'encoder must be an identifier';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, jsonb_set(doc,'{context_fp}','"XYZ"')),'invalid_activity_day_versions'), 'context_fp must be hex';

  -- Runs and events.
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(pg_temp.day_run(lo, lo+86401)))),'invalid_activity_day_run'), 'run beyond the day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(pg_temp.day_run(lo-5, lo+30)))),'invalid_activity_day_run'), 'run before the day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(jsonb_set(good_run,'{e}',to_jsonb(lo))))),'invalid_activity_day_run'), 'run with e <= s';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(jsonb_set(good_run,'{posture}','[]')))),'invalid_activity_day_run'), 'head must be an object';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(jsonb_set(good_run,'{overall_confidence}','1.2')))),'invalid_activity_day_run'), 'confidence above 1';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(good_run - 'wear'))),'invalid_activity_day_run'), 'wear is required';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(jsonb_set(good_run,'{s}','"x"')))),'invalid_activity_day_run'), 'start must be a number';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(jsonb_set(good_run,'{display_context}',to_jsonb(repeat('d',65)))))),'invalid_activity_day_run'), 'display label too long';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, null, jsonb_build_array(jsonb_build_object('kind','walk_start','probability',0.5,'ts',lo-1)))),'invalid_activity_day_event'), 'event before the day';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, null, jsonb_build_array(jsonb_build_object('kind','walk_start','probability',2,'ts',lo+5)))),'invalid_activity_day_event'), 'event probability above 1';
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, null, jsonb_build_array(jsonb_build_object('probability',0.5,'ts',lo+5)))),'invalid_activity_day_event'), 'event kind is required';
  select jsonb_agg(good_run) into too_many from generate_series(1, 20001);
  assert pg_temp.rejects(tok,rev,pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, too_many)),'invalid_activity_day_count'), 'more runs than a day can hold';

  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'no rejected document may leave a row';
  -- The boundaries themselves are accepted: first and last second of the day, empty arrays,
  -- null optional fields, and no encoder identity at all (no encoder spoke).
  rev := public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day,
    (pg_temp.day_doc(v_day, jsonb_build_array(pg_temp.day_run(lo, lo+5), pg_temp.day_run(lo+86395, lo+86400)),
                     jsonb_build_array())
      || jsonb_build_object('data_through', null, 'context_fp', null, 'observed_s', 0))
      #- '{versions,encoder}' #- '{versions,encoder_version}'));
  assert rev is not null, 'boundary document must be accepted';
  assert (select run_count=2 and event_count=0 and data_through is null and context_fp is null
            and encoder_id is null and encoder_version is null and observed_s=0
          from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'optional fields must be stored as NULL';
  raise notice 'PASS 12.3 payload validation';
end;
$$;

-- 12.4 Republish replaces the row (one row per lineage); other days and devices are untouched.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-24';
  other date := '2026-10-25';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp1 text; fp2 text; j record; tok uuid; rev1 bigint; rev2 bigint; rev_other bigint; old_computed timestamptz;
begin
  fp1 := public.activity_context_fingerprint(array[repeat('5',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  fp2 := public.activity_context_fingerprint(array[repeat('6',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,other,array[gen_random_uuid()],array[repeat('5',64)],fp1);
  select * into j from public.claim_activity_context_v2(300);
  rev_other := public.publish_activity_context_day(j.lease_token, j.input_revision, pg_temp.day_payload(other));
  assert pg_temp.complete_v1(j.lease_token, j.input_revision, other) is not null, 'neighbour job must complete';
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('5',64)],fp1);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  assert j.day=v_day, 'test must have claimed its own job';
  rev1 := public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day));
  assert pg_temp.complete_v1(tok, j.input_revision, v_day) is not null, 'first revision must complete';
  select computed_at into old_computed from public.activity_context_days where user_id=u and device_id=dev and day=v_day;
  -- Late verified object: new fingerprint, revision 2, new document with a different shape.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid(),gen_random_uuid()],array[repeat('5',64),repeat('6',64)],fp2);
  select * into j from public.claim_activity_context_v2(300);
  assert j.day=v_day and j.input_revision=2, 'the bumped job must be claimable at revision 2';
  rev2 := public.publish_activity_context_day(j.lease_token, j.input_revision,
    pg_temp.day_payload(v_day, pg_temp.day_doc(v_day, jsonb_build_array(pg_temp.day_run(lo, lo+600, 'walking')), jsonb_build_array())));
  assert rev2 > rev1, 'a republish must stamp a newer result revision';
  assert (select count(*)=1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'a republish must replace the row, not add one';
  assert (select job_fingerprint=fp2 and input_revision=2 and run_count=1 and event_count=0
            and result_revision=rev2 and computed_at>=old_computed
            and document->'runs'->0->>'display_context'='walking'
          from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'the row must carry the newest lineage and document';
  assert (select result_revision=rev_other and job_fingerprint=fp1 from public.activity_context_days
    where user_id=u and device_id=dev and day=other), 'another day must be untouched';
  raise notice 'PASS 12.4 republish replaces, neighbours untouched';
end;
$$;

-- 12.5 Pairing with the v1 publish: a rejected day document cannot block v1 (the worker runs it under a
--      savepoint), and a day document written in a unit that later fails rolls back with it.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-26';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; tok uuid; v1rev bigint; rejected boolean := false;
begin
  fp := public.activity_context_fingerprint(array[repeat('8',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('8',64)],fp);
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  begin
    perform public.publish_activity_context_day(tok, j.input_revision, '{"day":"2026-10-26","document":{}}'::jsonb);
  exception when others then rejected := true;
  end;
  assert rejected, 'a malformed document must raise';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'a rejected document must leave no row';
  -- Lease and revision are intact after the rejection, so the v1 publish proceeds.
  v1rev := public.publish_activity_context_v2(tok, j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
      jsonb_build_object('s',lo,'e',lo+30,'m','stationary','p','sitting','ex','false','sl','awake',
        'ec','resting_candidate','w','on_wrist','c',0.9,'os',30,'vs',30))),100);
  assert v1rev is not null, 'a rejected day document must not block the v1 publish';
  -- Atomic pair: the day document written in a unit that then fails is rolled back with it.
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid(),gen_random_uuid()],array[repeat('8',64),repeat('9',64)],repeat('e',64));
  select * into j from public.claim_activity_context_v2(300); tok := j.lease_token;
  begin
    perform public.publish_activity_context_day(tok, j.input_revision, pg_temp.day_payload(v_day));
    assert exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
      'the day document is visible inside its own unit';
    raise exception 'simulated v1 publish failure';
  exception when others then
    if sqlerrm <> 'simulated v1 publish failure' then raise; end if;
  end;
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'a day document must roll back together with a failed unit';
  raise notice 'PASS 12.5 pairing with the v1 publish';
end;
$$;

-- 12.6 Owner isolation and privileges.
insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
  decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
  publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
values
 ('a0000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000012','2026-10-27','hart-activity-1',2,'v2.0',
  'hsmm-1.1','imu-feat-1','m','p',repeat('a',64),1,5,0,0,0,0,0,'{}'::jsonb,1,clock_timestamp());
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
declare n bigint;
begin
  select count(*) into n from public.activity_context_days;
  assert n>0, 'an owner must see their own day documents';
  assert (select count(*)=0 from public.activity_context_days where user_id='a0000000-0000-4000-8000-000000000002'),
    'an owner must not see another owner''s day documents';
  begin
    insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
      decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
      publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
    values ('a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000011','2026-10-28','hart-activity-1',2,'v2.0',
      'hsmm-1.1','imu-feat-1','m','p',repeat('a',64),1,5,0,0,0,0,0,'{}'::jsonb,1,clock_timestamp());
    raise exception 'authenticated insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    update public.activity_context_days set run_count=99 where user_id='a0000000-0000-4000-8000-000000000001';
    raise exception 'authenticated update allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.activity_context_days where user_id='a0000000-0000-4000-8000-000000000001';
    raise exception 'authenticated delete allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.publish_activity_context_day(gen_random_uuid(), 1, '{}'::jsonb);
    raise exception 'authenticated day publish allowed';
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
    perform count(*) from public.activity_context_days;
    raise exception 'anon day read allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.publish_activity_context_day(gen_random_uuid(), 1, '{}'::jsonb);
    raise exception 'anon day publish allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role service_role;
do $$
begin
  assert (select count(*)>0 from public.activity_context_days), 'the service role must see the day documents';
  assert public.publish_activity_context_day(gen_random_uuid(), 1, '{}'::jsonb) is null,
    'the service role may call the fenced publish (unknown token fences out)';
  begin
    perform internal.activity_day_num_ok('1'::jsonb, 0, 2, true);
    raise exception 'service role reached an internal helper';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
do $$ begin raise notice 'PASS 12.6 owner isolation and privileges'; end $$;

-- 12.7 Device and account deletion cascade to day documents.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001';
  dev uuid := 'a0000000-0000-4000-8000-000000000011';
  devtmp uuid := 'a0000000-0000-4000-8000-000000000013';
  v_day date := '2026-10-29';
  n integer;
begin
  insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
    decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
    publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
  values (u,devtmp,v_day,'hart-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','m','p',repeat('a',64),1,5,0,0,0,0,0,'{}'::jsonb,1,clock_timestamp());
  delete from public.devices where id=devtmp;
  select count(*) into n from public.activity_context_days where user_id=u and device_id=devtmp;
  assert n=0, 'device deletion must cascade day documents';
  assert exists(select 1 from public.activity_context_days where user_id=u and device_id=dev),
    'other devices keep their day documents';
  delete from auth.users where id=u;
  select count(*) into n from public.activity_context_days where user_id=u;
  assert n=0, 'account deletion must cascade day documents';
  assert exists(select 1 from public.activity_context_days where user_id='a0000000-0000-4000-8000-000000000002'),
    'another account keeps its day documents';
  raise notice 'PASS 12.7 deletion cascade';
end;
$$;

rollback;

-- 13. Stream days (20261003140000_activity_context_stream_days.sql): one day document for every UTC day
-- that has stored measurements, driven by completed scoring work; the raw-IMU queue and the stream queue
-- never hand out each other's jobs; the read surface answers "what was the user doing at second T".
begin;
set local statement_timeout = '120s';
insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push'),
 ('a0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000002','noop_push'),
 ('a0000000-0000-4000-8000-000000000013','a0000000-0000-4000-8000-000000000001','noop_push');

create function pg_temp.s_lo(p_day date) returns bigint language sql as $$
  select extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint
$$;
create function pg_temp.s_run(p_s bigint, p_e bigint, p_label text, p_conf numeric default 0.8) returns jsonb
language sql as $$
  select jsonb_build_object('s',p_s,'e',p_e,
    'posture',jsonb_build_object('seated_likely',0.8,'unknown',0.2),
    'locomotion',jsonb_build_object('stationary',0.9,'walking',0.1),
    'arm_behavior',jsonb_build_object('desk_like',0.7),
    'intensity',0.02,'overall_confidence',p_conf,'overall_uncertainty',0.3,
    'display_context',p_label,'sleep','awake','wear','on_wrist','n',((p_e-p_s)/5)::integer)
$$;
-- A stream-day document: no encoder windows, so the encoder identity is JSON null.
create function pg_temp.s_doc(p_day date, p_runs jsonb, p_events jsonb default '[]'::jsonb) returns jsonb
language sql as $$
  select jsonb_build_object(
    'schema_version',2,
    'versions',jsonb_build_object('schema',2,'ontology','v2.0','decoder','hsmm-1.1',
      'feature_schema','imu-feat-1','encoder',null,'encoder_version',null),
    'day_start',pg_temp.s_lo(p_day),'day_end',pg_temp.s_lo(p_day) + 86400,
    'publish_interval_s',5,'generated_at',1790000000,'data_through',pg_temp.s_lo(p_day) + 3600,
    'observed_s',3600,'sleep_known_outside',false,'context_fp','abc123',
    'runs',p_runs,'events',p_events,'latest',null,
    'summary',jsonb_build_object('label_s',jsonb_build_object('sitting',100),'unclear_s',40,'mean_confidence',0.7))
$$;
create function pg_temp.s_payload(p_day date, p_doc jsonb) returns jsonb language sql as $$
  select jsonb_build_object('day',p_day::text,'model_version','streams-activity-1',
    'preprocessing_version','streams-v1','document',p_doc)
$$;
-- True when the statement raised exactly the expected stable message.
create function pg_temp.s_raises(p_sql text, p_msg text) returns boolean language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 13.1 Enqueue: completed scoring work becomes one job per owner / device / UTC day, replays are no-ops,
--      a changed scoring revision bumps exactly the days that depend on it, rebuilds are rate limited,
--      and the failure state of a dead-lettered day is only reset by a real change.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; u2 uuid := 'a0000000-0000-4000-8000-000000000002';
  d1 uuid := 'a0000000-0000-4000-8000-000000000011'; d2 uuid := 'a0000000-0000-4000-8000-000000000012';
  d0 date := (clock_timestamp() at time zone 'UTC')::date - 6;
  n integer; r record; dirty0 timestamptz; fp0 text;
begin
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d1,d0,'frwhoop-server-1',2,2,clock_timestamp()),
         (u1,d1,d0+1,'frwhoop-server-1',1,1,clock_timestamp()),
         (u1,d1,d0+3,'frwhoop-server-1',1,0,null),
         (u2,d2,d0,'frwhoop-server-1',1,1,clock_timestamp()),
         (u1,d1,date '2019-12-31','frwhoop-server-1',1,1,clock_timestamp()),
         (u1,d1,date '1969-12-31','frwhoop-server-1',1,1,clock_timestamp());
  n := public.enqueue_activity_stream_days();
  assert n = 7, 'u1/d1 depends on d0-1..d0+2 (4 days), u2/d2 on d0-1..d0+1 (3 days); got ' || n;
  assert (select count(*) = 7 from public.activity_context_jobs where algorithm_version = 'streams-activity-1'),
    'one stream job per owner/device/UTC day';
  assert (select count(*) = 4 from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and algorithm_version = 'streams-activity-1'
            and day between d0 - 1 and d0 + 2), 'a UTC day depends on the scoring days either side of it';
  assert not exists(select 1 from public.activity_context_jobs
          where algorithm_version = 'streams-activity-1' and (day > d0 + 2 or day < d0 - 1)),
    'a scoring day that never completed, and epoch-era artifact days, must not create jobs';
  select * into r from public.activity_context_jobs
    where user_id = u1 and device_id = d1 and day = d0 and algorithm_version = 'streams-activity-1';
  assert r.input_revision = 1 and r.completed_revision = 0 and r.reason = 'streams' and not r.dead_letter
     and r.fingerprint ~ '^[0-9a-f]{64}$' and r.input_object_ids = '{}'::uuid[] and r.input_digests = '{}'::text[]
     and r.model_version = 'streams-activity-1' and r.preprocessing_version = 'streams-v1'
     and r.ontology_version = 'v2.0' and r.lease_token is null, 'a fresh stream job carries no input objects';

  -- Replay: nothing changed, nothing written.
  select dirty_at, fingerprint into dirty0, fp0 from public.activity_context_jobs
    where user_id = u1 and device_id = d1 and day = d0 and algorithm_version = 'streams-activity-1';
  n := public.enqueue_activity_stream_days();
  assert n = 0, 'an unchanged marker must be a no-op; got ' || n;
  assert (select dirty_at = dirty0 and fingerprint = fp0 and input_revision = 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = d0 and algorithm_version = 'streams-activity-1'),
    'a replay must not touch the job';

  -- A new scoring revision for d0 changes the three UTC days that depend on d0, and only those.
  update public.activity_context_jobs set completed_revision = input_revision, last_completed_at = clock_timestamp()
    where algorithm_version = 'streams-activity-1';
  update public.scoring_jobs_v2 set input_revision = 3, completed_revision = 3, last_completed_at = clock_timestamp()
    where user_id = u1 and device_id = d1 and day = d0 and algorithm_version = 'frwhoop-server-1';
  n := public.enqueue_activity_stream_days();
  assert n = 3, 'a new scoring revision must refresh the three dependent UTC days; got ' || n;
  assert (select count(*) = 3 from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and algorithm_version = 'streams-activity-1'
            and day between d0 - 1 and d0 + 1 and input_revision = 2 and completed_revision = 1 and fingerprint <> fp0),
    'dependent days must get a new fingerprint and revision';
  assert (select input_revision = 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = d0 + 2 and algorithm_version = 'streams-activity-1'),
    'a day that does not depend on d0 must be left alone';
  assert (select bool_and(not_before > clock_timestamp() + interval '9 minutes')
          from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and algorithm_version = 'streams-activity-1'
            and day between d0 - 1 and d0 + 1), 'a rebuild must wait the minimum interval after the last build';
  update public.activity_context_jobs set completed_revision = input_revision
    where algorithm_version = 'streams-activity-1' and not (user_id = u1 and device_id = d1 and day between d0 - 1 and d0 + 1);
  assert not exists(select 1 from public.claim_activity_stream_day(60)), 'held-back days must not be claimable yet';

  -- No minimum interval: a changed day is due at once.
  update public.activity_context_jobs set completed_revision = input_revision, last_completed_at = clock_timestamp()
    where algorithm_version = 'streams-activity-1';
  update public.scoring_jobs_v2 set input_revision = 4, completed_revision = 4, last_completed_at = clock_timestamp()
    where user_id = u1 and device_id = d1 and day = d0 and algorithm_version = 'frwhoop-server-1';
  n := public.enqueue_activity_stream_days(interval '36 hours', 25, interval '0');
  assert n = 3, 'got ' || n;
  assert (select count(*) = 3 from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and algorithm_version = 'streams-activity-1'
            and input_revision = 3 and not_before <= clock_timestamp()), 'with no minimum interval a changed day is due at once';

  -- Dead-letter stickiness: only a changed marker resets the failure state.
  update public.activity_context_jobs set dead_letter = true, consecutive_failures = 8, last_error = 'x'
    where user_id = u2 and device_id = d2 and day = d0 and algorithm_version = 'streams-activity-1';
  n := public.enqueue_activity_stream_days();
  assert n = 0, 'got ' || n;
  assert (select dead_letter and consecutive_failures = 8 from public.activity_context_jobs
          where user_id = u2 and device_id = d2 and day = d0 and algorithm_version = 'streams-activity-1'),
    'a replay must not resurrect a dead-lettered stream day';
  update public.scoring_jobs_v2 set input_revision = 2, completed_revision = 2, last_completed_at = clock_timestamp()
    where user_id = u2 and device_id = d2 and day = d0 and algorithm_version = 'frwhoop-server-1';
  n := public.enqueue_activity_stream_days();
  assert n = 3, 'got ' || n;
  assert (select not dead_letter and consecutive_failures = 0 and last_error is null
          from public.activity_context_jobs
          where user_id = u2 and device_id = d2 and day = d0 and algorithm_version = 'streams-activity-1'),
    'a changed marker must reset the failure state';

  -- Argument validation.
  assert pg_temp.s_raises('select public.enqueue_activity_stream_days(interval ''-1 hour'')', 'invalid_arguments'), 'negative lookback';
  assert pg_temp.s_raises('select public.enqueue_activity_stream_days(interval ''36 hours'', -1)', 'invalid_arguments'), 'negative limit';
  assert pg_temp.s_raises('select public.enqueue_activity_stream_days(interval ''36 hours'', 1001)', 'invalid_arguments'), 'oversized limit';
  assert pg_temp.s_raises('select public.enqueue_activity_stream_days(interval ''36 hours'', 25, interval ''2 days'')', 'invalid_arguments'), 'oversized interval';
  assert pg_temp.s_raises('select public.enqueue_activity_stream_days(null)', 'invalid_arguments'), 'null lookback';
  raise notice 'PASS 13.1 stream days are enqueued from completed scoring work';
end;
$$;

-- 13.1b Backfill is bounded and newest first; a scoring day ahead of the UTC date never creates a future job.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d3 uuid := 'a0000000-0000-4000-8000-000000000013';
  today date := (clock_timestamp() at time zone 'UTC')::date;
  d0 date := (clock_timestamp() at time zone 'UTC')::date - 30;
  n integer;
begin
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d3,d0,'frwhoop-server-1',1,1,clock_timestamp() - interval '40 days');
  n := public.enqueue_activity_stream_days(interval '36 hours', 0);
  assert n = 0, 'no recent work and a zero backfill limit must create nothing; got ' || n;
  n := public.enqueue_activity_stream_days(interval '36 hours', 1);
  assert n = 1 and exists(select 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d3 and day = d0 + 1 and algorithm_version = 'streams-activity-1'),
    'the backfill takes the newest missing day first; got ' || n;
  n := public.enqueue_activity_stream_days(interval '36 hours', 5);
  assert n = 2 and (select count(*) = 3 from public.activity_context_jobs
          where user_id = u1 and device_id = d3 and algorithm_version = 'streams-activity-1'),
    'the next call backfills only what is still missing; got ' || n;
  n := public.enqueue_activity_stream_days(interval '36 hours', 5);
  assert n = 0, 'a finished backfill is a no-op; got ' || n;

  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d3,today + 1,'frwhoop-server-1',1,1,clock_timestamp());
  perform public.enqueue_activity_stream_days();
  assert exists(select 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d3 and day = today and algorithm_version = 'streams-activity-1'),
    'the UTC day a scoring day ahead of UTC overlaps is built';
  assert not exists(select 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d3 and day > today and algorithm_version = 'streams-activity-1'),
    'a UTC day that has not started must not get a job';

  -- The days ahead of the UTC date stay candidates forever (they can never get a job); they must not
  -- use up the backfill limit and starve the older days that can.
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d3,d0 + 15,'frwhoop-server-1',1,1,clock_timestamp() - interval '40 days');
  n := public.enqueue_activity_stream_days(interval '36 hours', 1);
  assert n = 1 and exists(select 1 from public.activity_context_jobs
          where user_id = u1 and device_id = d3 and day = d0 + 16 and algorithm_version = 'streams-activity-1'),
    'days ahead of the UTC date must not consume the backfill limit; got ' || n;
  raise notice 'PASS 13.1b bounded backfill and no future days';
end;
$$;

-- 13.2 The two queues never hand out each other's jobs.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  d0 date := (clock_timestamp() at time zone 'UTC')::date - 6;
  lo bigint; fp text; j record;
begin
  lo := pg_temp.s_lo(d0);
  fp := public.activity_context_fingerprint(array[repeat('a',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  update public.activity_context_jobs set completed_revision = input_revision, lease_token = null, lease_until = null
    where algorithm_version = 'streams-activity-1' and day <> d0;
  perform public.enqueue_activity_context(u1,d1,d0 + 10,array[gen_random_uuid()],array[repeat('a',64)],fp);
  select * into j from public.claim_activity_context_v2(60);
  assert j.algorithm_version = 'hart-activity-1', 'the raw-IMU claim must hand out the raw-IMU job, got ' || coalesce(j.algorithm_version, 'nothing');
  assert not exists(select 1 from public.claim_activity_context_v2(60)),
    'the raw-IMU claim must never hand out a stream day while one is due';
  select * into j from public.claim_activity_stream_day(60);
  assert j.algorithm_version = 'streams-activity-1' and j.lease_token is not null and j.claim_count = 1,
    'the stream claim must hand out a stream day with a lease';
  perform public.enqueue_activity_context(u1,d1,d0 + 11,array[gen_random_uuid()],array[repeat('b',64)],
    public.activity_context_fingerprint(array[repeat('b',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1'));
  update public.activity_context_jobs set completed_revision = input_revision, lease_token = null, lease_until = null
    where algorithm_version = 'streams-activity-1';
  assert not exists(select 1 from public.claim_activity_stream_day(60)),
    'the stream claim must never hand out a raw-IMU job';
  assert exists(select 1 from public.claim_activity_context_v2(60)), 'the raw-IMU job is still claimable';
  assert pg_temp.s_raises('select public.claim_activity_stream_day(0)', 'invalid_lease'), 'lease bounds are enforced';
  raise notice 'PASS 13.2 queue separation';
end;
$$;

-- 13.3 Completion: the document and the completion are one unit; no document also completes; the fence holds;
--      a rejected document completes nothing; only stream days can be completed this way.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := (clock_timestamp() at time zone 'UTC')::date - 2;
  lo bigint := pg_temp.s_lo((clock_timestamp() at time zone 'UTC')::date - 2);
  j record; rev bigint; r record; runs jsonb; imu record;
begin
  delete from public.activity_context_jobs;
  delete from public.activity_context_days;
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d1,v_day,'frwhoop-server-1',1,1,clock_timestamp()) on conflict do nothing;
  perform public.enqueue_activity_stream_days();
  delete from public.activity_context_jobs where day <> v_day;
  runs := jsonb_build_array(pg_temp.s_run(lo+100, lo+200, 'sitting'), pg_temp.s_run(lo+200, lo+260, 'walking', 0.64));

  select * into j from public.claim_activity_stream_day(300);
  rev := public.complete_activity_stream_day(j.lease_token, j.input_revision,
    pg_temp.s_payload(v_day, pg_temp.s_doc(v_day, runs)), 7);
  assert rev is not null and rev >= 1, 'a stored document returns its result revision';
  select * into r from public.activity_context_days where user_id = u1 and device_id = d1 and day = v_day;
  assert found and r.algorithm_version = 'streams-activity-1' and r.model_version = 'streams-activity-1'
     and r.preprocessing_version = 'streams-v1' and r.encoder_id is null and r.encoder_version is null
     and r.job_fingerprint = j.fingerprint and r.input_revision = j.input_revision and r.run_count = 2
     and r.result_revision = rev, 'the document is stored under the stream lineage with a null encoder';
  assert (select completed_revision = j.input_revision and lease_token is null and lease_until is null
            and success_count = 1 and last_duration_ms = 7 and consecutive_failures = 0 and last_completed_at is not null
          from public.activity_context_jobs where user_id = u1 and device_id = d1 and day = v_day),
    'the completion happens in the same call as the document';
  assert not exists(select 1 from public.scoring_work_items where user_id = u1 and device_id = d1 and day = v_day),
    'a stream day must never dirty scoring';
  assert (select count(*) = 0 from public.activity_context_epochs where user_id = u1 and device_id = d1),
    'stream days write no v1 epochs';

  -- No measurements: completes without a document, and leaves an earlier document alone.
  update public.activity_context_jobs set input_revision = input_revision + 1, dirty_at = clock_timestamp(),
    not_before = clock_timestamp() where user_id = u1 and device_id = d1 and day = v_day;
  select * into j from public.claim_activity_stream_day(300);
  assert public.complete_activity_stream_day(j.lease_token, j.input_revision, null, 1) = 0,
    'completing with no document returns 0';
  assert (select completed_revision = j.input_revision and lease_token is null from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = v_day), 'the empty day is completed';
  assert (select result_revision = rev and run_count = 2 from public.activity_context_days
          where user_id = u1 and device_id = d1 and day = v_day), 'an earlier document is left alone';
  update public.activity_context_jobs set input_revision = input_revision + 1, not_before = clock_timestamp()
    where user_id = u1 and device_id = d1 and day = v_day;
  select * into j from public.claim_activity_stream_day(300);
  assert public.complete_activity_stream_day(j.lease_token, j.input_revision, 'null'::jsonb, 1) = 0,
    'a JSON null payload also means no document';

  -- Fence: a revision that moved on, an unknown token and an expired lease write nothing.
  update public.activity_context_jobs set input_revision = input_revision + 1, not_before = clock_timestamp()
    where user_id = u1 and device_id = d1 and day = v_day;
  select * into j from public.claim_activity_stream_day(300);
  update public.activity_context_jobs set input_revision = input_revision + 1
    where user_id = u1 and device_id = d1 and day = v_day;
  assert public.complete_activity_stream_day(j.lease_token, j.input_revision,
    pg_temp.s_payload(v_day, pg_temp.s_doc(v_day, runs)), 1) is null, 'a moved revision is fenced';
  assert public.complete_activity_stream_day(j.lease_token, j.input_revision, null, 1) is null,
    'a moved revision is fenced for a day without a document too';
  assert public.complete_activity_stream_day(gen_random_uuid(), 1, null, 1) is null, 'an unknown token is fenced';
  assert (select completed_revision < input_revision and lease_token = j.lease_token from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = v_day), 'a fenced call must not complete or release the job';
  assert (select result_revision = rev from public.activity_context_days
          where user_id = u1 and device_id = d1 and day = v_day), 'a fenced call must not write the document';
  update public.activity_context_jobs set lease_until = clock_timestamp() - interval '1 second'
    where user_id = u1 and device_id = d1 and day = v_day;
  assert public.complete_activity_stream_day(j.lease_token, j.input_revision + 1, null, 1) is null, 'an expired lease is fenced';

  -- A rejected document raises, completes nothing and writes nothing.
  update public.activity_context_jobs set not_before = clock_timestamp(), lease_token = null, lease_until = null
    where user_id = u1 and device_id = d1 and day = v_day;
  select * into j from public.claim_activity_stream_day(300);
  assert pg_temp.s_raises(format('select public.complete_activity_stream_day(%L, %s, %L::jsonb, 1)',
      j.lease_token, j.input_revision,
      pg_temp.s_payload(v_day, pg_temp.s_doc(v_day, jsonb_build_array(pg_temp.s_run(lo+100, lo+86401, 'sitting'))))::text),
    'invalid_activity_day_run'), 'a run past the day end is rejected with the stable message';
  assert (select completed_revision < input_revision and lease_token = j.lease_token from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = v_day), 'a rejected document completes nothing';
  assert (select result_revision = rev from public.activity_context_days
          where user_id = u1 and device_id = d1 and day = v_day), 'a rejected document writes nothing';

  -- Only stream days complete this way.
  perform public.enqueue_activity_context(u1,d1,v_day - 20,array[gen_random_uuid()],array[repeat('c',64)],
    public.activity_context_fingerprint(array[repeat('c',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1'));
  select * into imu from public.claim_activity_context_v2(60);
  assert pg_temp.s_raises(format('select public.complete_activity_stream_day(%L, %s, null, 1)', imu.lease_token, imu.input_revision),
    'not_a_stream_day_job'), 'a raw-IMU job cannot be completed as a stream day';
  raise notice 'PASS 13.3 completion, empty days, fence and rejection';
end;
$$;

-- 13.4 The read surface: runs, transitions, the at-timestamp lookup and the measurement join.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  u2 uuid := 'a0000000-0000-4000-8000-000000000002'; d2 uuid := 'a0000000-0000-4000-8000-000000000012';
  v_day date := (clock_timestamp() at time zone 'UTC')::date - 2;
  lo bigint := pg_temp.s_lo((clock_timestamp() at time zone 'UTC')::date - 2);
  runs jsonb; evs jsonb; r record; src uuid := gen_random_uuid(); got text[];
begin
  delete from public.activity_context_jobs;
  delete from public.activity_context_days;
  runs := jsonb_build_array(
    pg_temp.s_run(lo+100, lo+200, 'sitting', 0.82),
    pg_temp.s_run(lo+200, lo+260, 'walking', 0.64),
    jsonb_set(pg_temp.s_run(lo+260, lo+300, 'x', 0.31), '{display_context}', 'null'::jsonb));
  evs := jsonb_build_array(jsonb_build_object('kind','sit_to_stand_like','probability',0.7,'ts',lo+200));
  insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
    decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
    publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
  values (u1,d1,v_day,'streams-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','streams-activity-1','streams-v1',repeat('a',64),1,
          5,3600,3,1,40,0.7,pg_temp.s_doc(v_day, runs, evs),1,clock_timestamp()),
         (u2,d2,v_day,'streams-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','streams-activity-1','streams-v1',repeat('b',64),1,
          5,3600,1,0,0,0.7,pg_temp.s_doc(v_day, jsonb_build_array(pg_temp.s_run(lo+100, lo+200, 'lying'))),2,clock_timestamp());

  assert (select count(*) = 3 from public.activity_context_runs where user_id = u1 and device_id = d1 and day = v_day),
    'one row per run';
  select * into r from public.activity_context_runs where user_id = u1 and device_id = d1 and start_ts = lo + 100;
  assert r.end_ts = lo + 200 and r.duration_s = 100 and r.display_context = 'sitting'
     and abs(r.confidence - 0.82) < 0.001 and abs(r.uncertainty - 0.3) < 0.001 and abs(r.intensity - 0.02) < 0.001
     and r.sleep_state = 'awake' and r.wear_state = 'on_wrist' and r.states = 20
     and r.algorithm_version = 'streams-activity-1' and r.source_rank = 2 and r.day = v_day
     and r.start_at = to_timestamp(lo + 100) and r.end_at = to_timestamp(lo + 200)
     and r.posture ? 'seated_likely' and (r.locomotion ->> 'stationary')::numeric = 0.9 and r.arm_behavior ? 'desk_like'
     and r.model_version = 'streams-activity-1' and r.decoder_version = 'hsmm-1.1' and r.ontology_version = 'v2.0'
     and r.result_revision = 1 and r.computed_at is not null, 'the run row carries exact times, confidence and head probabilities';
  assert (select display_context is null and abs(confidence - 0.31) < 0.001 from public.activity_context_runs
          where user_id = u1 and device_id = d1 and start_ts = lo + 260), 'an unclear run keeps a NULL label and its confidence';
  select * into r from public.activity_context_transitions where user_id = u1 and device_id = d1;
  assert r.ts = lo + 200 and r.at = to_timestamp(lo + 200) and r.kind = 'sit_to_stand_like'
     and abs(r.probability - 0.7) < 0.001 and r.source_rank = 2 and r.day = v_day, 'the transition row carries the exact time and probability';
  assert (select count(*) = 1 from public.activity_context_transitions where user_id = u1 and device_id = d1), 'one row per event';

  -- The at-timestamp lookup is half-open [start, end).
  assert (select display_context from public.activity_context_at(u1, d1, lo + 150)) = 'sitting', 'inside the first run';
  assert (select display_context from public.activity_context_at(u1, d1, lo + 100)) = 'sitting', 'a run includes its first second';
  assert (select display_context from public.activity_context_at(u1, d1, lo + 200)) = 'walking', 'a run excludes its end second';
  assert (select count(*) = 0 from public.activity_context_at(u1, d1, lo + 99)), 'before the first run';
  assert (select count(*) = 0 from public.activity_context_at(u1, d1, lo + 300)), 'after the last run';
  assert (select count(*) = 0 from public.activity_context_at(u1, d1, lo + 86400 + 150)), 'a day without a document';
  assert (select count(*) = 0 from public.activity_context_at(u1, d2, lo + 150)), 'another owner''s device is never matched';

  -- A raw-IMU document for the same day answers first.
  insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
    decoder_version,feature_schema,encoder_id,encoder_version,model_version,preprocessing_version,job_fingerprint,
    input_revision,publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
  values (u1,d1,v_day,'hart-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','hart','hart-activity-v1','hart-activity-v1',
          'hart-activity-preprocess-v1',repeat('c',64),1,5,3600,1,0,0,0.9,
          pg_temp.s_doc(v_day, jsonb_build_array(pg_temp.s_run(lo+150, lo+250, 'standing', 0.9))),3,clock_timestamp());
  select array_agg(display_context order by source_rank) into got
    from public.activity_context_runs where user_id = u1 and device_id = d1 and start_ts <= lo + 160 and lo + 160 < end_ts;
  assert got = array['standing','sitting'], 'both sources cover the second, the raw-IMU document first: ' || got::text;
  assert (select array_agg(display_context) from public.activity_context_at(u1, d1, lo + 160)) = array['standing','sitting'],
    'the lookup lists the raw-IMU document first';

  -- Labelling stored measurements by joining on their exact timestamp.
  insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
  values (u1,d1,src,lo + 120,62,src), (u1,d1,src,lo + 210,95,src), (u1,d1,src,lo + 400,70,src);
  select array_agg(coalesce(x.display_context, '-') order by x.ts) into got from (
    select h.ts, ctx.display_context
      from public.noop_hr_samples h
      left join public.activity_context_runs ctx
        on ctx.user_id = h.user_id and ctx.device_id = h.device_id
       and ctx.day = (to_timestamp(h.ts) at time zone 'UTC')::date
       and ctx.algorithm_version = 'streams-activity-1' and h.ts >= ctx.start_ts and h.ts < ctx.end_ts
     where h.user_id = u1 and h.device_id = d1) x;
  assert got = array['sitting','walking','-'], 'each stored measurement lands in exactly one run, or none: ' || got::text;
  assert (select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.activity_context_runs'::regclass),
    'the runs view must run with the caller''s rights';
  assert (select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.activity_context_transitions'::regclass),
    'the transitions view must run with the caller''s rights';
  raise notice 'PASS 13.4 read surface';
end;
$$;

-- 13.5 Owner isolation and privileges.
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
declare
  u2 uuid := 'a0000000-0000-4000-8000-000000000002'; d2 uuid := 'a0000000-0000-4000-8000-000000000012';
  lo bigint := extract(epoch from (((clock_timestamp() at time zone 'UTC')::date - 2)::timestamp at time zone 'UTC'))::bigint;
begin
  assert (select count(*) > 0 from public.activity_context_runs), 'an owner sees their own runs';
  assert (select count(*) = 0 from public.activity_context_runs where user_id = u2), 'an owner must not see another owner''s runs';
  assert (select count(*) > 0 from public.activity_context_transitions), 'an owner sees their own transitions';
  assert (select count(*) = 0 from public.activity_context_transitions where user_id = u2), 'nor their transitions';
  assert (select count(*) > 0 from public.activity_context_at('a0000000-0000-4000-8000-000000000001',
            'a0000000-0000-4000-8000-000000000011', lo + 150)), 'an owner can ask what they were doing';
  assert (select count(*) = 0 from public.activity_context_at(u2, d2, lo + 150)),
    'the lookup must not leak another owner''s context';
  begin perform public.enqueue_activity_stream_days(); raise exception 'authenticated enqueue allowed';
  exception when insufficient_privilege then null; end;
  begin perform public.claim_activity_stream_day(60); raise exception 'authenticated stream claim allowed';
  exception when insufficient_privilege then null; end;
  begin perform public.complete_activity_stream_day(gen_random_uuid(), 1, null, 1); raise exception 'authenticated completion allowed';
  exception when insufficient_privilege then null; end;
  begin perform public.claim_activity_context_v2(60); raise exception 'authenticated raw-IMU claim allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
do $$
begin
  begin perform count(*) from public.activity_context_runs; raise exception 'anon runs read allowed';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from public.activity_context_transitions; raise exception 'anon transitions read allowed';
  exception when insufficient_privilege then null; end;
  begin perform * from public.activity_context_at(gen_random_uuid(), gen_random_uuid(), 1); raise exception 'anon lookup allowed';
  exception when insufficient_privilege then null; end;
  begin perform public.enqueue_activity_stream_days(); raise exception 'anon enqueue allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role service_role;
do $$
begin
  assert (select count(*) >= 2 from (select distinct user_id from public.activity_context_runs) x),
    'the service role reads every owner''s runs';
  perform public.enqueue_activity_stream_days();
  assert not exists(select 1 from public.claim_activity_stream_day(60) c where c.algorithm_version <> 'streams-activity-1'),
    'the service role may use the stream queue functions';
end;
$$;
reset role;
do $$ begin raise notice 'PASS 13.5 owner isolation and privileges'; end $$;

-- 13.6 Device and account deletion cascade to stream jobs and documents.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d3 uuid := 'a0000000-0000-4000-8000-000000000013';
  v_day date := (clock_timestamp() at time zone 'UTC')::date - 4;
begin
  insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,fingerprint,input_revision)
  values (u1,d3,v_day,'streams-activity-1',repeat('a',64),1);
  insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
    decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
    publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
  values (u1,d3,v_day,'streams-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','m','p',repeat('a',64),1,5,0,0,0,0,0,'{}'::jsonb,9,clock_timestamp());
  delete from public.devices where id = d3;
  assert not exists(select 1 from public.activity_context_jobs where device_id = d3), 'device deletion cascades stream jobs';
  assert not exists(select 1 from public.activity_context_days where device_id = d3), 'device deletion cascades stream documents';
  delete from auth.users where id = u1;
  assert not exists(select 1 from public.activity_context_jobs where user_id = u1), 'account deletion cascades stream jobs';
  assert not exists(select 1 from public.activity_context_days where user_id = u1), 'account deletion cascades documents';
  assert exists(select 1 from public.activity_context_days where user_id = 'a0000000-0000-4000-8000-000000000002'),
    'another account keeps its documents';
  raise notice 'PASS 13.6 deletion cascade';
end;
$$;

rollback;

-- 14. The canonical class on the read surface (20261004150000_activity_context_canonical_class.sql):
-- a run may carry the app's activity class and its confidence; a document without them stays valid and
-- reads as NULL; a malformed value is rejected when the document is published instead of failing every
-- read of the views; the lookup and the measurement join return the class.
begin;
set local statement_timeout = '120s';
insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push'),
 ('a0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000002','noop_push');

create function pg_temp.c_lo(p_day date) returns bigint language sql as $$
  select extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint
$$;
-- A run with the head probabilities the decoder writes, plus the canonical class keys when given.
create function pg_temp.c_run(p_s bigint, p_e bigint, p_label text, p_class jsonb default null,
                              p_class_conf jsonb default null) returns jsonb
language sql as $$
  select jsonb_build_object('s',p_s,'e',p_e,
    'posture',jsonb_build_object('seated_likely',0.8,'unknown',0.2),
    'locomotion',jsonb_build_object('stationary',0.9,'walking',0.1),
    'arm_behavior',jsonb_build_object('desk_like',0.7),
    'intensity',0.02,'overall_confidence',0.8,'overall_uncertainty',0.3,
    'display_context',p_label,'sleep','awake','wear','on_wrist','n',((p_e-p_s)/5)::integer)
    || case when p_class is null then '{}'::jsonb else jsonb_build_object('activity_class',p_class) end
    || case when p_class_conf is null then '{}'::jsonb else jsonb_build_object('class_confidence',p_class_conf) end
$$;
create function pg_temp.c_doc(p_day date, p_runs jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'schema_version',2,
    'versions',jsonb_build_object('schema',2,'ontology','v2.0','decoder','hsmm-1.2',
      'feature_schema','imu-feat-1','encoder',null,'encoder_version',null),
    'day_start',pg_temp.c_lo(p_day),'day_end',pg_temp.c_lo(p_day) + 86400,
    'publish_interval_s',5,'generated_at',1790000000,'data_through',pg_temp.c_lo(p_day) + 3600,
    'observed_s',3600,'sleep_known_outside',false,'context_fp','abc123',
    'runs',p_runs,'events','[]'::jsonb,'latest',null,
    'summary',jsonb_build_object('label_s',jsonb_build_object('sitting',100),'unclear_s',40,'mean_confidence',0.7))
$$;
create function pg_temp.c_payload(p_day date, p_doc jsonb) returns jsonb language sql as $$
  select jsonb_build_object('day',p_day::text,'model_version','streams-activity-1',
    'preprocessing_version','streams-v1','document',p_doc)
$$;
create function pg_temp.c_raises(p_sql text, p_msg text) returns boolean language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 14.1 Validation: optional, strict when present.
do $$
declare
  lo bigint := pg_temp.c_lo('2026-10-20');
  base jsonb := pg_temp.c_run(pg_temp.c_lo('2026-10-20') + 100, pg_temp.c_lo('2026-10-20') + 200, 'sitting');
  hi bigint := pg_temp.c_lo('2026-10-20') + 86400;
begin
  assert internal.activity_day_run_valid(base, lo, hi), 'a run from before the class existed stays valid';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting_desk"', '0.74'), lo, hi),
    'a run with a class and its confidence is valid';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"unknown"', '0'), lo, hi),
    'confidence 0 is valid';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"off_wrist"', '1'), lo, hi),
    'confidence 1 is valid';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', 'null', 'null'), lo, hi),
    'JSON nulls read as absent';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', to_jsonb('a' || repeat('b', 31)), '0.5'), lo, hi),
    'a class code of 32 characters is the longest accepted';
  assert internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"a_future_class_2"', '0.5'), lo, hi),
    'a class a later taxonomy adds needs no migration';

  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '5', '0.5'), lo, hi), 'the class must be a string';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '["walking"]', '0.5'), lo, hi), 'not an array';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '""', '0.5'), lo, hi), 'not empty';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"Walking"', '0.5'), lo, hi), 'lower case only';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting desk"', '0.5'), lo, hi), 'no spaces';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting-desk"', '0.5'), lo, hi), 'no hyphens';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"2fast"', '0.5'), lo, hi), 'starts with a letter';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', to_jsonb('a' || repeat('b', 32)), '0.5'), lo, hi),
    'a class code of 33 characters is too long';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"walking"', '"0.5"'), lo, hi), 'confidence must be a number';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"walking"', '1.01'), lo, hi), 'confidence above 1';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"walking"', '-0.01'), lo, hi), 'confidence below 0';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"walking"', 'true'), lo, hi), 'confidence is not a boolean';
  -- Every earlier rule still holds.
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, lo + 100, 'sitting', '"walking"', '0.5'), lo, hi), 'an empty run';
  assert not internal.activity_day_run_valid(pg_temp.c_run(lo + 100, hi + 5, 'sitting', '"walking"', '0.5'), lo, hi), 'a run past the day';
  assert not internal.activity_day_run_valid(base - 'wear', lo, hi), 'wear is still required';
  assert not internal.activity_day_run_valid(jsonb_set(base, '{overall_confidence}', '1.2'), lo, hi), 'run confidence is still bounded';
  -- The helper stays out of reach of client roles, as before.
  assert not has_function_privilege('anon', 'internal.activity_day_run_valid(jsonb,bigint,bigint)', 'execute'), 'anon cannot call the validator';
  assert not has_function_privilege('authenticated', 'internal.activity_day_run_valid(jsonb,bigint,bigint)', 'execute'), 'authenticated cannot call it';
  assert not has_function_privilege('service_role', 'internal.activity_day_run_valid(jsonb,bigint,bigint)', 'execute'), 'nor the service role';
  raise notice 'PASS 14.1 class validation';
end;
$$;

-- 14.2 A malformed class is rejected when the document is published, and the stable message is the
--      one every other malformed run produces; a good one is stored verbatim.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := (clock_timestamp() at time zone 'UTC')::date - 2;
  lo bigint := pg_temp.c_lo((clock_timestamp() at time zone 'UTC')::date - 2);
  j record; rev bigint;
begin
  delete from public.activity_context_jobs;
  delete from public.activity_context_days;
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u1,d1,v_day,'frwhoop-server-1',1,1,clock_timestamp()) on conflict do nothing;
  perform public.enqueue_activity_stream_days();
  delete from public.activity_context_jobs where day <> v_day;
  select * into j from public.claim_activity_stream_day(300);
  assert j.day = v_day, 'the test claimed its own job';

  assert pg_temp.c_raises(format('select public.complete_activity_stream_day(%L, %s, %L::jsonb, 1)', j.lease_token, j.input_revision,
      pg_temp.c_payload(v_day, pg_temp.c_doc(v_day, jsonb_build_array(
        pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"Sitting At Desk"', '0.5'))))::text),
    'invalid_activity_day_run'), 'a class that is not a snake_case code rejects the document';
  assert pg_temp.c_raises(format('select public.complete_activity_stream_day(%L, %s, %L::jsonb, 1)', j.lease_token, j.input_revision,
      pg_temp.c_payload(v_day, pg_temp.c_doc(v_day, jsonb_build_array(
        pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting_desk"', '"high"'))))::text),
    'invalid_activity_day_run'), 'a class confidence that is not a number rejects the document';
  assert not exists(select 1 from public.activity_context_days where user_id = u1 and device_id = d1 and day = v_day),
    'a rejected document leaves no row';
  assert (select completed_revision < input_revision and lease_token = j.lease_token from public.activity_context_jobs
          where user_id = u1 and device_id = d1 and day = v_day), 'a rejected document completes nothing';

  rev := public.complete_activity_stream_day(j.lease_token, j.input_revision,
    pg_temp.c_payload(v_day, pg_temp.c_doc(v_day, jsonb_build_array(
      pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting_desk"', '0.74')))), 5);
  assert rev is not null and rev >= 1, 'a valid classified document is stored';
  assert (select document -> 'runs' -> 0 ->> 'activity_class' = 'sitting_desk'
            and (document -> 'runs' -> 0 ->> 'class_confidence')::numeric = 0.74
          from public.activity_context_days where user_id = u1 and device_id = d1 and day = v_day),
    'the class travels inside the stored document untouched';
  raise notice 'PASS 14.2 publish-time validation';
end;
$$;

-- 14.3 The read surface: new columns come last, old documents read NULL, the lookup and the measurement
--      join return the class.
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := (clock_timestamp() at time zone 'UTC')::date - 3;
  lo bigint := pg_temp.c_lo((clock_timestamp() at time zone 'UTC')::date - 3);
  src uuid := gen_random_uuid(); got text[]; r record; cols text[];
begin
  delete from public.activity_context_jobs;
  delete from public.activity_context_days;
  -- A document from before the class existed (no keys) next to a classified one on another day.
  insert into public.activity_context_days(user_id,device_id,day,algorithm_version,schema_version,ontology_version,
    decoder_version,feature_schema,model_version,preprocessing_version,job_fingerprint,input_revision,
    publish_interval_s,observed_s,run_count,event_count,unclear_s,mean_confidence,document,result_revision,computed_at)
  values (u1,d1,v_day,'streams-activity-1',2,'v2.0','hsmm-1.2','imu-feat-1','streams-activity-1','streams-v1',repeat('a',64),1,
          5,3600,3,0,0,0.8,
          pg_temp.c_doc(v_day, jsonb_build_array(
            pg_temp.c_run(lo + 100, lo + 200, 'sitting', '"sitting_desk"', '0.74'),
            pg_temp.c_run(lo + 200, lo + 260, 'walking', '"walking"', '0.61'),
            pg_temp.c_run(lo + 260, lo + 300, 'x'))),
          1,clock_timestamp()),
         (u1,d1,v_day - 1,'streams-activity-1',2,'v2.0','hsmm-1.1','imu-feat-1','streams-activity-1','streams-v1',repeat('b',64),1,
          5,3600,1,0,0,0.8,
          pg_temp.c_doc(v_day - 1, jsonb_build_array(pg_temp.c_run(pg_temp.c_lo(v_day - 1) + 100, pg_temp.c_lo(v_day - 1) + 200, 'sitting'))),
          2,clock_timestamp()),
         ('a0000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000012',v_day,'streams-activity-1',2,'v2.0','hsmm-1.2',
          'imu-feat-1','streams-activity-1','streams-v1',repeat('c',64),1,5,3600,1,0,0,0.8,
          pg_temp.c_doc(v_day, jsonb_build_array(pg_temp.c_run(lo + 100, lo + 200, 'running', '"running"', '0.9'))),
          3,clock_timestamp());

  -- Append-only: the columns that existed before keep their names and positions.
  select array_agg(column_name::text order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'activity_context_runs';
  assert cols[1:25] = array['user_id','device_id','day','algorithm_version','start_ts','end_ts','start_at','end_at',
    'duration_s','display_context','confidence','uncertainty','intensity','sleep_state','wear_state','states','posture',
    'locomotion','arm_behavior','model_version','decoder_version','ontology_version','feature_schema','encoder_id',
    'encoder_version'], 'the original columns keep their positions: ' || cols[1:25]::text;
  assert cols[26:] = array['result_revision','computed_at','source_rank','activity_class','class_confidence'],
    'the class columns come last: ' || cols[26:]::text;
  assert (select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.activity_context_runs'::regclass),
    'the runs view still runs with the caller''s rights';

  select array_agg(coalesce(activity_class, '-') || ':' || coalesce(class_confidence::text, '-') order by start_ts) into got
    from public.activity_context_runs where user_id = u1 and device_id = d1 and day = v_day;
  assert got = array['sitting_desk:0.74', 'walking:0.61', '-:-'], 'classified runs return the class, the bare one NULL: ' || got::text;
  assert (select count(*) = 1 and bool_and(activity_class is null and class_confidence is null)
            from public.activity_context_runs where user_id = u1 and device_id = d1 and day = v_day - 1),
    'a document from before the class existed reads NULL, not an error';
  assert (select array_agg(display_context order by start_ts) = array['sitting', 'walking', 'x']
            and min(confidence) > 0.79 and max(confidence) < 0.81 and min(duration_s) = 40
            from public.activity_context_runs where user_id = u1 and device_id = d1 and day = v_day),
    'the earlier columns are unaffected';

  -- The lookup returns the class next to everything it returned before.
  select * into r from public.activity_context_at(u1, d1, lo + 150);
  assert r.display_context = 'sitting' and r.activity_class = 'sitting_desk' and abs(r.class_confidence - 0.74) < 0.001
     and r.algorithm_version = 'streams-activity-1' and r.start_ts = lo + 100 and r.end_ts = lo + 200
     and abs(r.confidence - 0.8) < 0.001, 'the lookup carries the class and its confidence';
  assert (select activity_class from public.activity_context_at(u1, d1, lo + 200)) = 'walking', 'half-open: the next run starts at its first second';
  assert (select activity_class is null from public.activity_context_at(u1, d1, lo + 280)), 'an unclassified run answers NULL';
  assert (select count(*) = 0 from public.activity_context_at(u1, d1, lo + 300)), 'after the last run there is no answer';
  assert has_function_privilege('authenticated', 'public.activity_context_at(uuid,uuid,bigint)', 'execute'), 'signed-in users can ask';
  assert has_function_privilege('service_role', 'public.activity_context_at(uuid,uuid,bigint)', 'execute'), 'the service role can ask';
  assert not has_function_privilege('anon', 'public.activity_context_at(uuid,uuid,bigint)', 'execute'), 'anonymous callers cannot';
  assert has_table_privilege('authenticated', 'public.activity_context_runs', 'select')
     and not has_table_privilege('anon', 'public.activity_context_runs', 'select'), 'the view keeps its grants';

  -- Labelling stored measurements with the class, by exact second.
  insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
  values (u1,d1,src,lo + 120,62,src), (u1,d1,src,lo + 210,95,src), (u1,d1,src,lo + 280,70,src), (u1,d1,src,lo + 500,66,src);
  select array_agg(x.label order by x.ts) into got from (
    select h.ts, coalesce(ctx.activity_class, '-') || '@' || coalesce(ctx.class_confidence::text, '-') as label
      from public.noop_hr_samples h
      left join public.activity_context_runs ctx
        on ctx.user_id = h.user_id and ctx.device_id = h.device_id
       and ctx.day = (to_timestamp(h.ts) at time zone 'UTC')::date
       and ctx.algorithm_version = 'streams-activity-1' and h.ts >= ctx.start_ts and h.ts < ctx.end_ts
     where h.user_id = u1 and h.device_id = d1) x;
  assert got = array['sitting_desk@0.74', 'walking@0.61', '-@-', '-@-'],
    'each measurement is labelled with the class of the run covering its second: ' || got::text;
  -- Time per class for the day: what a scoring model or the chatbot asks.
  select array_agg(x.c || '=' || x.s order by x.c) into got from (
    select coalesce(activity_class, 'none') as c, sum(duration_s) as s
      from public.activity_context_runs where user_id = u1 and device_id = d1 and day = v_day group by 1) x;
  assert got = array['none=40', 'sitting_desk=100', 'walking=60'], 'seconds per class: ' || got::text;
  raise notice 'PASS 14.3 read surface carries the class';
end;
$$;

-- 14.4 Owner isolation of the new columns.
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
declare
  u1 uuid := 'a0000000-0000-4000-8000-000000000001'; d1 uuid := 'a0000000-0000-4000-8000-000000000011';
  u2 uuid := 'a0000000-0000-4000-8000-000000000002'; d2 uuid := 'a0000000-0000-4000-8000-000000000012';
  lo bigint := pg_temp.c_lo((clock_timestamp() at time zone 'UTC')::date - 3);
begin
  assert (select count(*) > 0 from public.activity_context_runs where activity_class is not null), 'an owner reads their own classes';
  assert (select count(*) = 0 from public.activity_context_runs where user_id = u2 or activity_class = 'running'),
    'never another owner''s, although one exists';
  assert (select activity_class from public.activity_context_at(u1, d1, lo + 150)) = 'sitting_desk', 'an owner can ask what they were doing';
  assert (select count(*) = 0 from public.activity_context_at(u2, d2, lo + 150)), 'the lookup must not leak another owner''s class';
end;
$$;
reset role;
do $$ begin raise notice 'PASS 14.4 owner isolation of the class columns'; end $$;

rollback;

-- 15. Current lineage and version-driven re-derivation (20261007120000). History stays in
-- activity_context_epochs; activity_context_epochs_current is the newest publish of each UTC day; the
-- worker's registered versions and the day's settled state are folded into both day fingerprints; a bounded
-- sweep re-derives the days whose fingerprint is not today's; an older build never takes the registry back.
begin;
set local statement_timeout = '120s';
insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('a0000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001','noop_push'),
 ('a0000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000002','noop_push');

create function pg_temp.v_lo(p_day date) returns bigint language sql as $$
  select extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint
$$;
create function pg_temp.v_ep(p_s bigint, p_m text) returns jsonb language sql as $$
  select jsonb_build_object('s',p_s,'e',p_s+30,'m',p_m,'p','unknown','ex','false','sl','awake','ec','active',
    'w','on_wrist','c',0.9,'os',30,'vs',30)
$$;
-- A day document row as publish_activity_context_day stores it (only the columns the sweep reads matter).
create function pg_temp.v_day_row(p_user uuid, p_device uuid, p_day date, p_alg text, p_decoder text) returns void
language sql as $$
  insert into public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version,
    ontology_version, decoder_version, feature_schema, model_version, preprocessing_version, job_fingerprint,
    input_revision, publish_interval_s, observed_s, run_count, event_count, unclear_s, mean_confidence,
    document, result_revision, computed_at)
  values (p_user, p_device, p_day, p_alg, 2, 'v2.0', p_decoder, 'imu-feat-2', 'm', 'p', repeat('e', 64),
    1, 5, 0, 0, 0, 0, 0.5, '{}'::jsonb, nextval('public.activity_context_days_result_revision_seq'),
    clock_timestamp())
$$;
create function pg_temp.v_raises(p_sql text, p_msg text) returns boolean language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 15.1 The current view holds only the newest publish of each UTC day; history is kept.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001'; dev uuid := 'a0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-05'; lo bigint := pg_temp.v_lo('2026-10-05'); lo2 bigint := pg_temp.v_lo('2026-10-06');
  fpa text := repeat('1',64); fpb text := repeat('2',64); fpc text := repeat('3',64);
  j public.activity_context_jobs; rev_b bigint; rev_c bigint;
begin
  assert to_regclass('public.activity_context_epochs_day_revision') is not null, 'per-day revision index';
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('a',64)],fpa);
  select * into j from public.claim_activity_context_v2(300);
  perform public.publish_activity_context_v2(j.lease_token,j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(pg_temp.v_ep(lo,'walking'),
      pg_temp.v_ep(lo+30,'walking'), pg_temp.v_ep(lo+43200,'running'))),10);
  -- A later lineage of the same day that covers less (an object retracted, a shorter decode).
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('b',64)],fpb);
  select * into j from public.claim_activity_context_v2(300);
  rev_b := public.publish_activity_context_v2(j.lease_token,j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(pg_temp.v_ep(lo,'stationary'))),10);
  perform public.enqueue_activity_context(u,dev,v_day+1,array[gen_random_uuid()],array[repeat('c',64)],fpc);
  select * into j from public.claim_activity_context_v2(300);
  rev_c := public.publish_activity_context_v2(j.lease_token,j.input_revision,
    jsonb_build_object('day',(v_day+1)::text,'epochs',jsonb_build_array(pg_temp.v_ep(lo2,'walking'))),10);
  assert rev_c > rev_b, 'publishes draw one global sequence';

  assert (select count(*) = 5 from public.activity_context_epochs where user_id=u and device_id=dev),
    'every lineage stays in the table (causal replay reads history)';
  assert (select count(*) = 1 and bool_and(fingerprint = fpb and result_revision = rev_b and motion_label = 'stationary')
          from public.activity_context_epochs_current where user_id=u and device_id=dev and day=v_day),
    'the current view holds only the newest publish of the day';
  assert not exists(select 1 from public.activity_context_epochs_current
                     where user_id=u and device_id=dev and day=v_day and start_ts = lo + 43200),
    'a slot only a superseded lineage covered is not current';
  assert (select count(*) = 1 and bool_and(fingerprint = fpc)
          from public.activity_context_epochs_current where user_id=u and device_id=dev and day=v_day+1),
    'a later UTC day with a higher revision never hides an earlier day';
  -- A local day west of UTC stitches both UTC days' current publishes, one row per slot.
  assert (select count(*) = 2 and count(distinct start_ts) = 2 from public.activity_context_epochs_current
          where user_id=u and device_id=dev and start_ts >= lo and start_ts < lo2 + 25200),
    'a local window spanning two UTC days reads both days';
  raise notice 'PASS 15.1 current lineage per UTC day';
end;
$$;

-- 15.2 Registered versions are folded into both day fingerprints; with none registered an unsettled day's
--      fingerprint is the historical one.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001'; dev uuid := 'a0000000-0000-4000-8000-000000000011';
  d0 date := (clock_timestamp() at time zone 'UTC')::date - 3; lo bigint := pg_temp.v_lo(d0);
  unsettled timestamptz := ((d0 + 1)::timestamp at time zone 'UTC') + interval '1 hour';
  dg text[] := array[repeat('d',64)]; fp_lit text; fp_stream0 text; fp_stream1 text; n integer;
begin
  delete from public.activity_context_lane_versions;
  fp_lit := public.activity_context_fingerprint(dg,lo,lo+86399,'hart-activity-1','hart-activity-v1',
    'hart-activity-preprocess-v1','v1');
  assert internal.activity_hart_day_fingerprint(dg, d0, unsettled) = fp_lit,
    'no registered versions, day not settled: the trigger''s historical fingerprint';
  assert internal.activity_hart_day_fingerprint(dg, d0) = public.activity_context_fingerprint(dg,lo,lo+86399,
    'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1;settled'),
    'a settled day''s fingerprint says so';
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u,dev,d0,'frwhoop-server-1',2,2,clock_timestamp());
  n := public.enqueue_activity_stream_days(interval '36 hours', 0, interval '0');
  assert n = 3, 'got ' || n;
  select fingerprint into fp_stream0 from public.activity_context_jobs
   where user_id=u and device_id=dev and day=d0 and algorithm_version='streams-activity-1';
  assert fp_stream0 = encode(extensions.digest(convert_to('activity-streams-v1' || E'\n' || u::text || E'\n' ||
      dev::text || E'\n' || d0::text || E'\n' || (d0::text || ':2') || E'\nsettled', 'UTF8'), 'sha256'), 'hex'),
    'no registered versions: the historical stream-day fingerprint, marked settled';
  assert internal.activity_stream_day_fingerprint(u, dev, d0, d0::text || ':2', unsettled) =
    encode(extensions.digest(convert_to('activity-streams-v1' || E'\n' || u::text || E'\n' ||
      dev::text || E'\n' || d0::text || E'\n' || (d0::text || ':2'), 'UTF8'), 'sha256'), 'hex'),
    'an unsettled stream day keeps the historical fingerprint';

  -- The worker registers what it runs (limit 0: register only).
  assert public.reconcile_activity_context_versions('hart-activity-1', jsonb_build_object(
    'tag','d=hsmm-1.7;o=v2.0;f=imu-feat-2;m=hart-x;p=pre-y','decoder','hsmm-1.7','ontology','v2.0',
    'feature_schema','imu-feat-2','model','hart-x','preprocessing','pre-y'), 0) = 0;
  assert public.reconcile_activity_context_versions('streams-activity-1', jsonb_build_object(
    'tag','d=hsmm-1.7;o=v2.0;f=imu-feat-2','decoder','hsmm-1.7','ontology','v2.0','feature_schema','imu-feat-2'), 0) = 0;
  assert internal.activity_hart_day_fingerprint(dg, d0) = public.activity_context_fingerprint(dg,lo,lo+86399,
    'hart-activity-1','hart-x','pre-y','v1;d=hsmm-1.7;o=v2.0;f=imu-feat-2;m=hart-x;p=pre-y;settled'),
    'the HART fingerprint carries the worker''s model, preprocessing and full tag, not the trigger literals';
  update public.activity_context_jobs set completed_revision = input_revision where algorithm_version='streams-activity-1';
  n := public.enqueue_activity_stream_days(interval '36 hours', 0, interval '0');
  assert n = 3, 'a new decoder version re-fingerprints the live stream days; got ' || n;
  select fingerprint into fp_stream1 from public.activity_context_jobs
   where user_id=u and device_id=dev and day=d0 and algorithm_version='streams-activity-1';
  assert fp_stream1 <> fp_stream0, 'the stream-day fingerprint carries the registered tag';
  -- Registering the same versions again is a no-op for the fingerprints.
  perform public.reconcile_activity_context_versions('streams-activity-1', jsonb_build_object(
    'tag','d=hsmm-1.7;o=v2.0;f=imu-feat-2','decoder','hsmm-1.7','ontology','v2.0','feature_schema','imu-feat-2'), 0);
  update public.activity_context_jobs set completed_revision = input_revision where algorithm_version='streams-activity-1';
  n := public.enqueue_activity_stream_days(interval '36 hours', 0, interval '0');
  assert n = 0, 'same versions, same fingerprints; got ' || n;
  raise notice 'PASS 15.2 versions are part of the day fingerprints';
end;
$$;

-- 15.3 The bounded sweep re-derives the days whose fingerprint is not the registered versions' one (any part of
--      the tag: here the HART model): newest first, at most p_limit, never a pending, leased or dead-lettered
--      job, and only while the lane's queue is nearly idle.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001'; dev uuid := 'a0000000-0000-4000-8000-000000000011';
  base date := '2026-08-01'; i integer; n integer; ids uuid[]; dg text[]; r record;
  hart jsonb := jsonb_build_object('tag','d=hsmm-1.7;o=v2.0;f=imu-feat-2;m=hart-x;p=pre-y','decoder','hsmm-1.7',
    'ontology','v2.0','feature_schema','imu-feat-2','model','hart-x','preprocessing','pre-y');
  streams jsonb := jsonb_build_object('tag','d=hsmm-1.7;o=v2.0;f=imu-feat-2','decoder','hsmm-1.7',
    'ontology','v2.0','feature_schema','imu-feat-2');
begin
  delete from public.activity_context_jobs where user_id = u;
  delete from public.activity_context_lane_versions;
  -- Seven completed raw-IMU days fingerprinted by an earlier build (another HART model, same decoder: the
  -- documents' decoder_version is the current one), one dead-lettered; then day 5 is decoded by this build.
  insert into public.activity_context_lane_versions(algorithm_version, versions, versions_tag)
  values ('hart-activity-1', hart || '{"model":"hart-old","tag":"d=hsmm-1.7;o=v2.0;f=imu-feat-2;m=hart-old;p=pre-y"}',
          'd=hsmm-1.7;o=v2.0;f=imu-feat-2;m=hart-old;p=pre-y');
  for i in 0..6 loop
    ids := array[gen_random_uuid()]; dg := array[repeat(chr(97 + i), 64)];
    insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,input_object_ids,input_digests,
      fingerprint,input_revision,completed_revision,dead_letter)
    values (u,dev,base+i,'hart-activity-1',ids,dg,internal.activity_hart_day_fingerprint(dg, base+i),1,1,i = 6);
    perform pg_temp.v_day_row(u,dev,base+i,'hart-activity-1','hsmm-1.7');
  end loop;
  assert public.reconcile_activity_context_versions('hart-activity-1', hart, 0) = 0, 'register only';
  update public.activity_context_jobs set fingerprint = internal.activity_hart_day_fingerprint(input_digests, day)
   where user_id = u and day = base + 5 and algorithm_version = 'hart-activity-1';
  n := public.reconcile_activity_context_versions('hart-activity-1', hart, 2);
  assert n = 2, 'at most p_limit days per call; got ' || n;
  assert (select array_agg(day order by day) = array[base+3, base+4] from public.activity_context_jobs
          where user_id=u and algorithm_version='hart-activity-1' and input_revision = 2),
    'newest stale days first (day 5 is current, day 6 is dead-lettered)';
  select * into r from public.activity_context_jobs where user_id=u and day=base+4 and algorithm_version='hart-activity-1';
  assert r.fingerprint = internal.activity_hart_day_fingerprint(r.input_digests, r.day) and r.completed_revision = 1
     and r.reason = 'input', 'the bump goes through the normal enqueue path with the version-folded fingerprint';
  n := public.reconcile_activity_context_versions('hart-activity-1', hart, 2);
  assert n = 0, 'a lane with p_limit pending jobs is left to drain first; got ' || n;
  update public.activity_context_jobs set completed_revision = input_revision where user_id = u;
  n := public.reconcile_activity_context_versions('hart-activity-1', hart, 2);
  assert n = 2, 'the next stale days once the queue drained; got ' || n;
  assert (select array_agg(day order by day) = array[base+1, base+2] from public.activity_context_jobs
          where user_id=u and algorithm_version='hart-activity-1' and input_revision = 2 and completed_revision = 1);
  -- A job already carrying the version-folded fingerprint is not bumped again (its document may simply have
  -- failed to republish): no loop.
  update public.activity_context_jobs set completed_revision = input_revision where user_id = u;
  n := public.reconcile_activity_context_versions('hart-activity-1', hart, 10);
  assert n = 1, 'only day 0 is left; got ' || n;
  update public.activity_context_jobs set completed_revision = input_revision where user_id = u;
  assert public.reconcile_activity_context_versions('hart-activity-1', hart, 10) = 0, 'converged';
  assert (select dead_letter and input_revision = 1 from public.activity_context_jobs
          where user_id=u and day=base+6 and algorithm_version='hart-activity-1'), 'a dead letter is never resurrected';
  assert (select input_revision = 1 from public.activity_context_jobs
          where user_id=u and day=base+5 and algorithm_version='hart-activity-1'), 'a current day is left alone';

  -- Stream days: the same sweep, bumping the job directly with reason 'versions'.
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision,last_completed_at)
  values (u,dev,base,'frwhoop-server-1',1,1,clock_timestamp());
  insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,fingerprint,input_revision,completed_revision)
  values (u,dev,base,'streams-activity-1',
          internal.activity_stream_day_fingerprint(u,dev,base,internal.activity_stream_day_marker(u,dev,base)),4,4);
  perform pg_temp.v_day_row(u,dev,base,'streams-activity-1','hsmm-1.3');
  -- Day base+1 was built a moment ago: it is re-queued with the enqueue's rebuild spacing.
  insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,fingerprint,input_revision,
    completed_revision,last_completed_at)
  values (u,dev,base+1,'streams-activity-1',repeat('0',64),2,2,clock_timestamp());
  perform pg_temp.v_day_row(u,dev,base+1,'streams-activity-1','hsmm-1.3');
  n := public.reconcile_activity_context_versions('streams-activity-1', streams, 4);
  assert n = 2, 'got ' || n;
  assert (select not_before > clock_timestamp() + interval '9 minutes' from public.activity_context_jobs
           where user_id=u and day=base+1 and algorithm_version='streams-activity-1'),
    'a day built minutes ago waits out the rebuild spacing';
  assert (select input_revision = 5 and completed_revision = 4 and reason = 'versions'
             and fingerprint = internal.activity_stream_day_fingerprint(u,dev,base,internal.activity_stream_day_marker(u,dev,base))
          from public.activity_context_jobs where user_id=u and day=base and algorithm_version='streams-activity-1'),
    'a stale stream day gets the version-folded fingerprint and a new revision';
  assert (select count(*) = 1 from public.claim_activity_stream_day(60)), 'and is claimable at once';

  assert pg_temp.v_raises($q$select public.reconcile_activity_context_versions('other', '{}'::jsonb, 1)$q$,
    'invalid_arguments'), 'unknown lane';
  assert pg_temp.v_raises($q$select public.reconcile_activity_context_versions('streams-activity-1',
    '{"tag":"bad tag","decoder":"d","ontology":"o","feature_schema":"f"}'::jsonb, 1)$q$, 'invalid_arguments'),
    'a tag must be a plain identifier';
  assert pg_temp.v_raises($q$select public.reconcile_activity_context_versions('streams-activity-1',
    '{"tag":"t","decoder":"d","ontology":"o"}'::jsonb, 1)$q$, 'invalid_arguments'), 'every version is named';
  raise notice 'PASS 15.3 bounded re-derivation on a version change';
end;
$$;

-- 15.5 A day decoded before it settled is queued again once it has (audit D1-02): the worker decodes a
--      settled day's waking hours as awake, an unsettled one's as unknown.
do $$
declare
  u uuid := 'a0000000-0000-4000-8000-000000000001'; dev uuid := 'a0000000-0000-4000-8000-000000000011';
  d1 date := (clock_timestamp() at time zone 'UTC')::date - 2;
  d_end timestamptz := (d1 + 1)::timestamp at time zone 'UTC';
  m uuid := 'a0000000-0000-4000-8000-000000000051'; j public.activity_context_jobs; fp_early text;
begin
  assert not internal.activity_day_settled(d1, d_end + interval '12 hours'),
    'the database settles a little after the worker (clock-skew margin)';
  assert internal.activity_day_settled(d1, d_end + interval '12 hours 10 minutes');
  insert into public.object_manifests(id,user_id,device_id,object_class,object_kind,object_key,
    start_at,end_at,sha256,sha256_source,status,verified_at)
  values (m,u,dev,'raw','rawImuSession','settle-obj-1',d_end - interval '2 hours',d_end - interval '1 hour',
          repeat('9',64),'server_verified','ready',clock_timestamp());
  select * into j from public.activity_context_jobs where user_id=u and device_id=dev and day=d1
    and algorithm_version='hart-activity-1';
  assert j.fingerprint = internal.activity_hart_day_fingerprint(j.input_digests, d1),
    'an object of a settled day enqueues the settled fingerprint';
  -- As the job was when the day was decoded an hour after it ended.
  fp_early := internal.activity_hart_day_fingerprint(j.input_digests, d1, d_end + interval '1 hour');
  assert fp_early <> j.fingerprint;
  update public.activity_context_jobs set fingerprint = fp_early, completed_revision = input_revision
   where user_id=u and device_id=dev and day=d1 and algorithm_version='hart-activity-1';
  perform public.reconcile_activity_context(interval '7 days');
  select * into j from public.activity_context_jobs where user_id=u and device_id=dev and day=d1
    and algorithm_version='hart-activity-1';
  assert j.input_revision = j.completed_revision + 1 and j.fingerprint <> fp_early,
    'the reconcile re-queues the day once it has settled';
  update public.activity_context_jobs set completed_revision = input_revision
   where user_id=u and device_id=dev and day=d1 and algorithm_version='hart-activity-1';
  perform public.reconcile_activity_context(interval '7 days');
  assert (select completed_revision = input_revision from public.activity_context_jobs
           where user_id=u and device_id=dev and day=d1 and algorithm_version='hart-activity-1'),
    'and only once';
  raise notice 'PASS 15.5 settled days are decoded again';
end;
$$;

-- 15.6 Rolling deploys: an older build (lower ordinal) never takes the registration back, and sweeps nothing.
do $$
declare n integer;
  newer jsonb := '{"tag":"d=hsmm-1.8;o=v2.0;f=imu-feat-2","decoder":"hsmm-1.8","ontology":"v2.0","feature_schema":"imu-feat-2","ordinal":"3"}';
  older jsonb := '{"tag":"d=hsmm-1.7;o=v2.0;f=imu-feat-2","decoder":"hsmm-1.7","ontology":"v2.0","feature_schema":"imu-feat-2","ordinal":"2"}';
begin
  delete from public.activity_context_lane_versions where algorithm_version = 'streams-activity-1';
  perform public.reconcile_activity_context_versions('streams-activity-1', newer, 0);
  n := public.reconcile_activity_context_versions('streams-activity-1', older, 10);
  assert n = 0, 'got ' || n;
  assert (select versions_tag = 'd=hsmm-1.8;o=v2.0;f=imu-feat-2' from public.activity_context_lane_versions
           where algorithm_version = 'streams-activity-1'), 'the newer registration stays';
  perform public.reconcile_activity_context_versions('streams-activity-1',
    newer || '{"tag":"d=hsmm-1.8;o=v2.0;f=imu-feat-2;m=x"}', 0);
  assert (select versions_tag = 'd=hsmm-1.8;o=v2.0;f=imu-feat-2;m=x' from public.activity_context_lane_versions
           where algorithm_version = 'streams-activity-1'), 'the same ordinal may register a new tag';
  assert pg_temp.v_raises($q$select public.reconcile_activity_context_versions('streams-activity-1',
    '{"tag":"t","decoder":"d","ontology":"o","feature_schema":"f","ordinal":"x"}'::jsonb, 0)$q$, 'invalid_arguments'),
    'an ordinal is a decimal string';
  raise notice 'PASS 15.6 an older build never takes the registry back';
end;
$$;

-- 15.4 Privileges: owners read their own current epochs; only the service role registers versions.
set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
begin
  assert (select count(*) = 0 from public.activity_context_epochs_current), 'never another owner''s epochs';
  assert pg_temp.v_raises('select count(*) from public.activity_context_lane_versions',
    'permission denied for table activity_context_lane_versions'), 'the registry is the worker''s';
  assert pg_temp.v_raises($q$select public.reconcile_activity_context_versions('streams-activity-1', '{}'::jsonb, 0)$q$,
    'permission denied for function reconcile_activity_context_versions'), 'only the worker re-derives';
end;
$$;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000001',true);
do $$
begin
  assert (select count(*) > 0 from public.activity_context_epochs_current), 'an owner reads their own current epochs';
end;
$$;
reset role;
do $$ begin raise notice 'PASS 15.4 privileges'; end $$;

rollback;
