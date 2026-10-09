-- Regression for 20261008020000_ingest_no_scoring_wait.sql. Run ONLY against an isolated, disposable
-- full-schema database (all migrations applied); it commits a synthetic owner and removes it at the end.
--
--   PGAPPNAME=ingest-no-scoring-wait psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 \
--     -v peer="$DISPOSABLE_CONNINFO" -f supabase/tests/ingest_no_scoring_wait.sql
--
-- `peer` is a libpq conninfo for the SAME database; a dblink session plays the scoring worker: it holds
-- the owner gate shared (session level, as ScoringLane.takeInputGate does) and the claimed job row
-- (FOR UPDATE, as claim_scoring_v2 does inside the pass transaction) while an upload lands.
-- Expected: the upload commits at once under a 2 s lock_timeout, the held day is left as a mark,
-- and after the "pass" publishes, the fold re-dirties that day (input_revision > completed_revision).
\set ON_ERROR_STOP on
create extension if not exists dblink;

select gen_random_uuid() as u, gen_random_uuid() as d, gen_random_uuid() as src, gen_random_uuid() as batch,
  'nsw-' || gen_random_uuid() as version \gset
select set_config('nsw.u', :'u', false), set_config('nsw.d', :'d', false),
  set_config('nsw.src', :'src', false), set_config('nsw.batch', :'batch', false),
  set_config('nsw.version', :'version', false);

-- Committed fixture (the peer session must see it).
begin;
do $$
declare u uuid:=current_setting('nsw.u')::uuid; d uuid:=current_setting('nsw.d')::uuid;
  v text:=current_setting('nsw.version');
begin
  assert current_setting('application_name')='ingest-no-scoring-wait', 'disposable-database invocation required';
  insert into auth.users(id) values(u);
  insert into public.profiles(id,timezone) values(u,'Europe/Berlin')
    on conflict(id) do update set timezone='Europe/Berlin';
  insert into public.devices(id,user_id,source_kind,external_device_id) values(d,u,'noop_push',d::text);
  insert into public.scoring_algorithms_v2(algorithm_version,enabled,active) values(v,true,false);
  -- The day a pass is scoring: revision 1, not yet completed.
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,reason)
    values(u,d,date '2026-10-01',v,'fixture');
end $$;
commit;

-- The "worker": gate shared for the whole pass, then the claim's row lock, transaction left open.
select dblink_connect('nsw_peer', :'peer');
select * from dblink('nsw_peer', format(
  'select pg_advisory_lock_shared(hashtextextended(%L,0))::text', 'scoring-inputs-v2:' || :'u')) as t(x text);
select dblink_exec('nsw_peer', 'begin isolation level repeatable read');
select * from dblink('nsw_peer', format(
  'select input_revision::text from public.scoring_jobs_v2 where user_id=%L and device_id=%L and day=%L
     and algorithm_version=%L for update', :'u', :'d', '2026-10-01', :'version')) as t(rev text);

-- The upload: must not wait for the pass.
begin;
set local lock_timeout = '2s';
do $$
declare u uuid:=current_setting('nsw.u')::uuid; d uuid:=current_setting('nsw.d')::uuid;
  src uuid:=current_setting('nsw.src')::uuid; batch uuid:=current_setting('nsw.batch')::uuid;
  v text:=current_setting('nsw.version'); started timestamptz:=clock_timestamp();
  noon bigint:=extract(epoch from timestamptz '2026-10-01 12:00:00+02')::bigint;
begin
  insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"tsSuspect",batch_id)
    select u,d,src,noon+i,1000,i,0,batch from generate_series(1,500) i;
  assert clock_timestamp()-started < interval '1.5 seconds', 'upload waited for the scoring pass';
  -- Held day: deferred to a mark, revision untouched.
  assert exists(select 1 from public.scoring_dirty_marks_v2 where user_id=u and device_id=d
    and day=date '2026-10-01' and algorithm_version=v), 'held day was not marked';
  assert (select input_revision from public.scoring_jobs_v2 where user_id=u and device_id=d
    and day=date '2026-10-01' and algorithm_version=v)=1, 'held day was bumped under the pass';
  -- Free days (+1, +2): enqueued directly, no mark.
  assert (select count(*) from public.scoring_jobs_v2 where user_id=u and device_id=d and algorithm_version=v
    and day in (date '2026-10-02', date '2026-10-03'))=2, 'free days were not enqueued';
  assert not exists(select 1 from public.scoring_dirty_marks_v2 where user_id=u and algorithm_version=v
    and day<>date '2026-10-01'), 'free day was marked';
end $$;
commit;

-- The pass publishes revision 1 (what publish_scoring_snapshot_v2 sets) and releases everything.
select dblink_exec('nsw_peer', format(
  'update public.scoring_jobs_v2 set completed_revision=1 where user_id=%L and device_id=%L and day=%L
     and algorithm_version=%L and input_revision=1', :'u', :'d', '2026-10-01', :'version'));
select dblink_exec('nsw_peer', 'commit');
select * from dblink('nsw_peer', format(
  'select pg_advisory_unlock_shared(hashtextextended(%L,0))::text', 'scoring-inputs-v2:' || :'u')) as t(x text);
select dblink_disconnect('nsw_peer');

-- The fold re-dirties the day the pass could not have seen.
begin;
do $$
declare u uuid:=current_setting('nsw.u')::uuid; d uuid:=current_setting('nsw.d')::uuid;
  v text:=current_setting('nsw.version'); j public.scoring_jobs_v2;
begin
  assert public.fold_scoring_dirty_marks_v2(100,u)>=1, 'fold applied nothing';
  select * into j from public.scoring_jobs_v2 where user_id=u and device_id=d and day=date '2026-10-01'
    and algorithm_version=v;
  assert j.completed_revision=1 and j.input_revision=2, 'racing upload left the day clean: '||to_jsonb(j)::text;
  assert not exists(select 1 from public.scoring_dirty_marks_v2 where user_id=u), 'mark not consumed';
end $$;
commit;

-- Timezone cache: identical to the catalog lookup it replaces, including unknown/null/abbreviation zones.
do $$
declare z text; t bigint; ref date;
begin
  foreach z in array array['UTC','Europe/Berlin','America/St_Johns','Asia/Kathmandu','Pacific/Chatham',
      'Pacific/Kiritimati','EST','PDT','','Not/AZone','europe/berlin'] loop
    foreach t in array array[0::bigint,1759312800,1774746000,1792800000] loop
      ref:=(to_timestamp(t) at time zone coalesce((select name from pg_timezone_names where name=z),'UTC'))::date;
      assert public.scoring_local_day_v2(t::text,z)=ref, format('zone %s ts %s differs', z, t);
    end loop;
  end loop;
  assert public.scoring_local_day_v2('0',null)=date '1970-01-01', 'null zone must be UTC';
  assert public.scoring_local_day_v2('9223372036854775807','UTC') is null, 'unrepresentable clock admitted';
end $$;

-- No ingest-side function waits on the scoring gate any more.
do $$ begin
  assert pg_get_functiondef('public.invalidate_scoring_stream_v2()'::regprocedure) not like '%advisory%',
    'stream trigger still takes an advisory lock';
  assert pg_get_functiondef('public.noop_commit_push_projection_intake_core(uuid,text,jsonb,jsonb,jsonb,uuid)'::regprocedure)
    not like '%''scoring-inputs-v2:''||%', 'projection settlement still takes the scoring gate';
end $$;

-- Cleanup of the synthetic owner (jobs, marks, samples cascade from the user).
begin;
delete from auth.users where id = :'u';
delete from public.scoring_algorithms_v2 where algorithm_version = :'version';
commit;
