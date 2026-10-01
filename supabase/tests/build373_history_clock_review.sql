-- Independent regression. Run only in an isolated, disposable full-schema DB:
-- PGAPPNAME=build373-history-clock-review psql -X -v ON_ERROR_STOP=1 -f this.sql
-- Add -v prepare_restart=true once, restart that disposable server, then run
-- with -v resume_restart=true. The persisted fixture is synthetic and scoped.
\if :{?prepare_restart}
\else
\set prepare_restart false
\endif
\if :{?resume_restart}
\else
\set resume_restart false
\endif

begin;
do $$
declare
  u uuid := gen_random_uuid(); d uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid(); d2 uuid := gen_random_uuid();
  src uuid := gen_random_uuid(); batch uuid := gen_random_uuid();
  version text := 'build373-clock-review-' || gen_random_uuid();
  before_jobs jsonb; before_debt jsonb; invalid_clock text;
begin
  assert current_setting('application_name')='build373-history-clock-review', 'disposable-review invocation required';
  insert into auth.users(id) values(u),(u2);
  insert into public.profiles(id,timezone) values(u,'UTC'),(u2,'UTC') on conflict(id) do update set timezone='UTC';
  insert into public.devices(id,user_id,source_kind,external_device_id)
    values(d,u,'noop_push',d::text),(d2,u2,'noop_push',d2::text);
  insert into public.scoring_algorithms_v2(algorithm_version,enabled,active) values(version,true,false);
  insert into public.scoring_history_algorithms_v3(algorithm_version,state_schema_version) values(version,1);

  -- First assertion is actual durable ingest, not a source-string/helper check.
  -- On the original135 schema this fails with timestamp out of range.
  insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"tsSuspect",batch_id)
    values(u,d,src,9223372036854775807,1000,1,1,batch),
          (u,d,src,-9223372036854775808,1000,2,1,batch);
  assert (select count(*)=2 from public.noop_rr_intervals where user_id=u), 'invalid originals lost';
  assert not exists(select 1 from public.scoring_jobs_v2 where user_id=u), 'invalid-only day was fabricated';
  assert not exists(select 1 from public.scoring_invalidations_v2 where user_id=u), 'invalid-only debt was fabricated';
  foreach invalid_clock in array array['9223372036854775807','-9223372036854775808','Infinity','-Infinity','NaN','garbage','294276-12-31 23:59:59+00'] loop
    assert public.scoring_timestamp_v3(invalid_clock) is null, 'unsafe clock admitted: ' || invalid_clock;
  end loop;
  assert public.scoring_timestamp_v3('1900-01-01T00:00:00Z') is not null, 'arbitrary old-date cutoff';
  assert public.scoring_timestamp_v3('2200-01-01T00:00:00Z') is not null, 'arbitrary future-date cutoff';

  -- Disjoint valid scalar days in the same statement are separate bounded spans.
  insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"tsSuspect",batch_id)
    values(u,d,src,extract(epoch from timestamptz '2020-01-10 12:00:00+00')::bigint,1000,3,0,batch),
          (u,d,src,extract(epoch from timestamptz '2026-09-17 12:00:00+00')::bigint,1000,4,0,batch),
          (u,d,src,9223372036854775807,1000,5,1,batch),
          (u2,d2,src,extract(epoch from timestamptz '2024-04-05 12:00:00+00')::bigint,1000,6,0,batch);
  assert (select count(*)=2 from public.scoring_invalidations_v2 where user_id=u and algorithm_version=version), 'separate scalar days were lost or joined';
  assert not exists(select 1 from public.scoring_invalidations_v2 where user_id in(u,u2) and algorithm_version=version and through_day-next_day<>4), 'fabricated interior calendar debt';
  assert (select count(*)=1 from public.scoring_invalidations_v2 where user_id=u2 and device_id=d2 and algorithm_version=version and next_day='2024-04-04' and through_day='2024-04-08'), 'second owner span changed';
  assert not exists(select 1 from public.scoring_invalidations_v2 where (user_id=u and device_id<>d) or (user_id=u2 and device_id<>d2)), 'cross-identity invalidation';
  select jsonb_agg(to_jsonb(j) order by day,algorithm_version) into before_jobs from public.scoring_jobs_v2 j where user_id=u;
  select jsonb_agg(to_jsonb(i) order by id) into before_debt from public.scoring_invalidations_v2 i where user_id=u;
  insert into public.noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,"tsSuspect",batch_id)
    values(u,d,src,extract(epoch from timestamptz '2026-09-17 12:00:00+00')::bigint,1000,4,0,batch) on conflict do nothing;
  update public.noop_rr_intervals set ingested_at=clock_timestamp(),batch_id=gen_random_uuid(),source_id=gen_random_uuid() where user_id=u;
  assert (select jsonb_agg(to_jsonb(j) order by day,algorithm_version) from public.scoring_jobs_v2 j where user_id=u)=before_jobs, 'duplicate/metadata changed job revision';
  assert (select jsonb_agg(to_jsonb(i) order by id) from public.scoring_invalidations_v2 i where user_id=u)=before_debt, 'duplicate/metadata changed debt';

  -- Removing the usable clock still withdraws its former usable historical day.
  update public.noop_rr_intervals set ts=9223372036854775807,"tsSuspect"=1 where user_id=u and seq=4;
  assert (select count(*)=2 from public.scoring_invalidations_v2 where user_id=u and algorithm_version=version and next_day='2026-09-16' and through_day='2026-09-20'), 'old valid day not invalidated after clock correction';
  assert (select count(*)=5 from public.noop_rr_intervals where user_id=u), 'correction deleted originals';
  assert not exists(select 1 from public.scoring_invalidations_v2 where user_id in(u,u2) and (not isfinite(next_day) or not isfinite(through_day) or next_day is null or through_day is null)), 'nonfinite calendar debt';
end $$;
rollback;

\if :prepare_restart
begin;
create schema build373_clock_review;
create table build373_clock_review.checkpoint(debt_id bigint primary key,next_day date not null,through_day date not null,raw_id uuid not null,phase integer not null);
do $$
declare
  u uuid := '37319000-0000-4000-8000-000000000001';
  d uuid := '37319000-0000-4000-8000-000000000002';
  raw_id uuid := '37319000-0000-4000-8000-000000000003';
  version text := 'build373-clock-review-restart';
  debt public.scoring_invalidations_v2%rowtype;
begin
  assert not exists(select 1 from public.scoring_invalidations_v2), 'restart fixture requires empty disposable debt queue';
  insert into auth.users(id) values(u);
  insert into public.profiles(id,timezone) values(u,'UTC') on conflict(id) do update set timezone='UTC';
  insert into public.devices(id,user_id,source_kind,external_device_id) values(d,u,'noop_push',d::text);
  insert into public.scoring_algorithms_v2(algorithm_version,enabled,active) values(version,true,false);
  insert into public.scoring_history_algorithms_v3(algorithm_version,state_schema_version) values(version,1);
  insert into public.sessions(id,user_id,device_id,kind,start_at,end_at)
    values(raw_id,u,d,'workout','2026-07-01 00:00:00+00','2026-09-01 00:00:00+00');
  select * into strict debt from public.scoring_invalidations_v2 where user_id=u and algorithm_version=version and reason='historical_timezone_raw_correction';
  assert debt.next_day='2026-06-30' and debt.through_day='2026-09-04', 'true interval debt was truncated';
  assert (select count(*)=1 from public.scoring_jobs_v2 where user_id=u and algorithm_version=version), 'history span expanded synchronously';
  assert public.expand_scoring_invalidations_v2(3)=3, 'bounded first expansion failed';
  insert into build373_clock_review.checkpoint
    select id,next_day,through_day,raw_id,1 from public.scoring_invalidations_v2 where id=debt.id;
  assert (select through_day=debt.through_day from build373_clock_review.checkpoint), 'expander shortened end boundary';
end $$;
commit;
\endif

\if :resume_restart
begin;
do $$
declare before_row build373_clock_review.checkpoint%rowtype; after_day date; revisions jsonb;
begin
  select * into strict before_row from build373_clock_review.checkpoint;
  assert before_row.phase=1, 'restart phase already consumed';
  assert exists(select 1 from public.scoring_invalidations_v2 where id=before_row.debt_id and next_day=before_row.next_day and through_day=before_row.through_day), 'cursor did not survive restart';
  assert exists(select 1 from public.sessions where id=before_row.raw_id and start_at='2026-07-01 00:00:00+00' and end_at='2026-09-01 00:00:00+00'), 'raw interval did not survive restart';
  select jsonb_agg(to_jsonb(j) order by algorithm_version,day) into revisions from public.scoring_jobs_v2 j where user_id='37319000-0000-4000-8000-000000000001';
  insert into public.sessions select * from public.sessions where id=before_row.raw_id on conflict do nothing;
  assert (select jsonb_agg(to_jsonb(j) order by algorithm_version,day) from public.scoring_jobs_v2 j where user_id='37319000-0000-4000-8000-000000000001')=revisions, 'duplicate after restart changed revisions';
  assert public.expand_scoring_invalidations_v2(3)=3, 'bounded resumed expansion failed';
  select next_day into after_day from public.scoring_invalidations_v2 where id=before_row.debt_id;
  assert after_day>before_row.next_day and after_day<=before_row.next_day+3, 'resume lost progress or exceeded bound';
  assert exists(select 1 from public.scoring_invalidations_v2 where id=before_row.debt_id and through_day=before_row.through_day), 'resume truncated interval';
  update build373_clock_review.checkpoint set next_day=after_day,phase=2;
end $$;
commit;
\endif

select 'PASS build373 independent historical clock review' as result;
