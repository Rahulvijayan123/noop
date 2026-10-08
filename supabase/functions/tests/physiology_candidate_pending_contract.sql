-- Persisted candidate scheduling DB contract (20261008110000_physiology_candidate_pending.sql).
-- Runs inside a disposable cluster with the candidate lane's prerequisite migrations (the list in
-- physiology_candidate_providers_test.ts), 20261002090000_physiology_candidate_providers.sql and
-- 20261008110000_physiology_candidate_pending.sql applied, on an empty pending table. Every fixture
-- change rolls back; no deployed credentials or data are touched.
--
-- Run against a disposable cluster the way the other *.sql tests run:
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261008110000_physiology_candidate_pending.sql \
--        -f physiology_candidate_pending_contract.sql
-- It prints one "ok <step>" line per step and raises on the first failed assertion.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then raise exception 'contract failed: %', p_what; end if;
end $$;
create function pg_temp.ok(p_step text) returns text language sql as $$ select 'ok ' || p_step $$;

-- Fixture: two owners, one device each, and the scoring jobs whose input_revision is the fence.
insert into auth.users(id) values
 ('c0000000-0000-4000-8000-000000000001'),
 ('c0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('c0000000-0000-4000-8000-000000000011','c0000000-0000-4000-8000-000000000001','noop_push'),
 ('c0000000-0000-4000-8000-000000000012','c0000000-0000-4000-8000-000000000002','noop_push');

create function pg_temp.ua() returns uuid language sql as $$ select 'c0000000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.ub() returns uuid language sql as $$ select 'c0000000-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.da() returns text language sql as $$ select 'c0000000-0000-4000-8000-000000000011' $$;
create function pg_temp.db() returns text language sql as $$ select 'c0000000-0000-4000-8000-000000000012' $$;

-- Set the day's scoring input revision (the record RPC's fence).
create function pg_temp.job(p_user uuid, p_dev text, p_day date, p_rev bigint) returns void language sql as $$
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision)
  values (p_user,p_dev::uuid,p_day,'frwhoop-server-1',p_rev)
  on conflict (user_id,device_id,day,algorithm_version) do update set input_revision=excluded.input_revision
$$;
create function pg_temp.entries(p_metrics text[], p_has_input boolean default true,
                                p_provider text default 'prov-a') returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object('metric',m,'provider_id',p_provider,
    'provider_version','1.0.0','config_version','c1','requested_mode','shadow',
    'has_input',p_has_input) order by o),'[]'::jsonb)
  from unnest(p_metrics) with ordinality as t(m,o)
$$;
create function pg_temp.all4() returns text[] language sql as $$
  select array['hrv','sleep_boundary','sleep_stage','respiration'] $$;
create function pg_temp.enqueue(p_user uuid, p_dev text, p_day date, p_rev bigint, p_entries jsonb)
returns integer language sql as $$
  select public.physiology_candidate_pending_enqueue(p_user,p_dev,p_day,p_rev,p_entries) $$;
create function pg_temp.claim(p_lease integer default 300) returns jsonb language sql as $$
  select public.physiology_candidate_pending_claim('contract-worker',p_lease) $$;
create function pg_temp.settle(p_item jsonb, p_outcome text, p_reason text,
                               p_count boolean default true, p_retry integer default null,
                               p_max integer default 4, p_token uuid default null,
                               p_rev bigint default null) returns jsonb language sql as $$
  select public.physiology_candidate_pending_settle((p_item->>'user_id')::uuid, p_item->>'device_id',
    (p_item->>'period_day')::date, p_item->>'metric',
    coalesce(p_rev,(p_item->>'input_revision')::bigint),
    coalesce(p_token,(p_item->>'lease_token')::uuid), p_outcome, p_reason, null, p_count, p_retry, p_max)
$$;
create function pg_temp.row_of(p_user uuid, p_day date, p_metric text)
returns public.physiology_candidate_pending language sql as $$
  select * from public.physiology_candidate_pending
   where user_id=p_user and period_day=p_day and metric=p_metric $$;
-- Drain everything due: settle each claim done, return the claim order as 'day:metric'.
create function pg_temp.drain_done(p_max integer default 100) returns text[] language plpgsql as $$
declare it jsonb; out_ text[]:='{}'; n integer:=0;
begin
  loop
    it:=pg_temp.claim(); exit when it is null; n:=n+1; exit when n>p_max;
    out_:=out_||((it->>'period_day')||':'||(it->>'metric'));
    perform pg_temp.check((pg_temp.settle(it,'done','recorded')->>'settled')::boolean,'drain settle');
  end loop;
  return out_;
end $$;

select pg_temp.check((select count(*)=0 from public.physiology_candidate_pending),
  'the contract needs an empty pending table');

-- 1. Security shape: service role only, RLS on, definer functions with a fixed search_path.
select pg_temp.check((select relrowsecurity from pg_class where oid='public.physiology_candidate_pending'::regclass),
  'RLS enabled');
select pg_temp.check(not has_table_privilege('anon','public.physiology_candidate_pending','select')
  and not has_table_privilege('authenticated','public.physiology_candidate_pending','select')
  and not has_table_privilege('authenticated','public.physiology_candidate_pending','insert'),
  'client roles have no table privilege');
select pg_temp.check((select bool_and(has_function_privilege('service_role',p.oid,'execute')
    and not has_function_privilege('anon',p.oid,'execute')
    and not has_function_privilege('authenticated',p.oid,'execute')
    and p.prosecdef and p.proconfig @> array['search_path=""'])
  from pg_proc p where p.pronamespace='public'::regnamespace
   and p.proname in ('physiology_candidate_pending_enqueue','physiology_candidate_pending_claim',
     'physiology_candidate_pending_settle','physiology_candidate_pending_stats',
     'physiology_candidate_current_revision')), 'definer + search_path + service-role-only execute');
select pg_temp.check((select count(*)=5 from pg_proc p where p.pronamespace='public'::regnamespace
   and p.proname in ('physiology_candidate_pending_enqueue','physiology_candidate_pending_claim',
     'physiology_candidate_pending_settle','physiology_candidate_pending_stats',
     'physiology_candidate_current_revision')), 'exactly one overload of each function');
-- The worker's presence probe resolves.
select pg_temp.check(to_regprocedure('public.physiology_candidate_pending_claim(text,integer)') is not null,
  'presence probe');
select pg_temp.ok('security');

-- 2. Enqueue: idempotent, stale revisions change nothing, no_input settles at once.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-01',1);
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-01',1,pg_temp.entries(pg_temp.all4()))=4,
  'first enqueue inserts four rows');
create temp table since0 as select metric, pending_since from public.physiology_candidate_pending;
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-01',1,pg_temp.entries(pg_temp.all4()))=0,
  'repeat enqueue changes nothing');
select pg_temp.check((select count(*)=4 from public.physiology_candidate_pending p join since0 s using (metric)
  where p.pending_since=s.pending_since and p.state='pending' and p.attempts=0 and p.input_revision=1),
  'repeat enqueue keeps rows and their place');
select pg_temp.check(public.physiology_candidate_current_revision(pg_temp.ua(),pg_temp.da(),'2026-09-01')=1,
  'current revision reads the scoring job');
select pg_temp.check(public.physiology_candidate_current_revision(pg_temp.ua(),pg_temp.da(),'2026-08-01') is null,
  'no job, no revision');
-- The day moved to revision 3: a pass computed at revision 2 must not re-arm anything.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-01',3);
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-01',2,pg_temp.entries(pg_temp.all4()))=0,
  'stale enqueue refused');
select pg_temp.check((select bool_and(input_revision=1) from public.physiology_candidate_pending), 'still revision 1');
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-01',3,pg_temp.entries(pg_temp.all4()))=4,
  'newer revision re-arms');
select pg_temp.check((select count(*)=4 from public.physiology_candidate_pending p join since0 s using (metric)
  where p.pending_since=s.pending_since and p.input_revision=3),
  'a re-armed pending row keeps its place in line');
-- A changed selection at the same revision re-arms; the same selection does not.
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-01',3,
  pg_temp.entries(array['hrv'],true,'prov-b'))=1, 'new provider triple re-arms one row');
select pg_temp.check((pg_temp.row_of(pg_temp.ua(),'2026-09-01','hrv')).provider_id='prov-b', 'triple updated');
-- has_input=false: withheld no_input at once, never claimable.
select pg_temp.job(pg_temp.ub(),pg_temp.db(),'2026-09-01',1);
select pg_temp.check(pg_temp.enqueue(pg_temp.ub(),pg_temp.db(),'2026-09-01',1,
  pg_temp.entries(array['respiration'],false))=1, 'no_input enqueue');
select pg_temp.check((select state='withheld' and last_reason='no_input' and settled_at is not null
  from pg_temp.row_of(pg_temp.ub(),'2026-09-01','respiration')), 'no_input settles withheld');
-- Owner isolation: a foreign device or a missing owner queues nothing.
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.db(),'2026-09-01',1,pg_temp.entries(pg_temp.all4()))=0,
  'foreign device refused');
select pg_temp.check(pg_temp.enqueue('c0000000-0000-4000-8000-0000000000ff',pg_temp.da(),'2026-09-01',1,
  pg_temp.entries(pg_temp.all4()))=0, 'missing owner refused');
-- Malformed batches raise before anything is written.
do $$ declare bad jsonb; n integer; begin
  foreach bad in array array[
    '{"metric":"hrv"}'::jsonb,
    '[{"metric":"resting_hr","provider_id":"p","provider_version":"1","config_version":"c","requested_mode":"shadow","has_input":true}]',
    '[{"metric":"hrv","provider_id":"","provider_version":"1","config_version":"c","requested_mode":"shadow","has_input":true}]',
    '[{"metric":"hrv","provider_id":"p","provider_version":"1","config_version":"c","requested_mode":"off","has_input":true}]',
    '[{"metric":"hrv","provider_id":"p","provider_version":"1","config_version":"c","requested_mode":"shadow","has_input":"yes"}]']
  loop
    begin
      n:=public.physiology_candidate_pending_enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-02',1,bad);
      raise exception 'malformed batch accepted: %', bad;
    exception when sqlstate '22023' then null;
    end;
  end loop;
  begin
    n:=public.physiology_candidate_pending_enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-02',0,pg_temp.entries(pg_temp.all4()));
    raise exception 'revision 0 accepted';
  exception when sqlstate '22023' then null;
  end;
end $$;
select pg_temp.check((select count(*)=0 from public.physiology_candidate_pending where period_day='2026-09-02'),
  'malformed batches wrote nothing');
select pg_temp.ok('enqueue');

-- Start the ordering steps from an empty queue.
delete from public.physiology_candidate_pending;

-- 3. Fair claim order across four metrics, oldest first, under a budget of two per drain.
-- Day 09-03 is scored (revision 1); a drain with budget 2 runs two items and records the rest as
-- budget skips; the day is re-scored (revision 2) before the next drain. The two waiting metrics
-- must come first next time, ahead of the two that just ran.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-03',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-03',1,pg_temp.entries(pg_temp.all4()));
create temp table order_log(drain integer, item text);
do $$ declare it jsonb; d integer; k integer; rev bigint:=1; begin
  for d in 1..4 loop
    for k in 1..3 loop
      it:=pg_temp.claim(); exit when it is null;
      if k<=2 then
        insert into order_log values (d,it->>'metric');
        perform pg_temp.check((pg_temp.settle(it,'done','recorded')->>'settled')::boolean,'settle done');
      else
        -- The budget is spent: the claimed item waits with reason budget, no attempt counted.
        perform pg_temp.check((pg_temp.settle(it,'retry','budget',false,0)->>'state')='pending','budget keeps pending');
      end if;
    end loop;
    -- Re-scored between drains.
    rev:=rev+1;
    perform pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-03',rev);
    perform pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-03',rev,pg_temp.entries(pg_temp.all4()));
  end loop;
end $$;
select pg_temp.check((select array_agg(item order by drain, ctid) from order_log where drain=1)
  = array['hrv','sleep_boundary'], 'drain 1 runs the first two (ties broken by metric order)');
select pg_temp.check((select array_agg(item order by drain, ctid) from order_log where drain=2)
  = array['sleep_stage','respiration'], 'drain 2 runs the two that waited, not the two that just ran');
select pg_temp.check((select count(distinct item)=4 from order_log where drain<=2), 'all four ran in two drains');
select pg_temp.check((select array_agg(item order by drain, ctid) from order_log where drain=3)
  = array['hrv','sleep_boundary'], 'drain 3 rotates back');
-- Across days: an older day's waiting item beats a newer day's fresh one.
delete from public.physiology_candidate_pending;
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-04',1);
select pg_temp.job(pg_temp.ub(),pg_temp.db(),'2026-09-05',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-04',1,pg_temp.entries(array['respiration']));
select pg_temp.enqueue(pg_temp.ub(),pg_temp.db(),'2026-09-05',1,pg_temp.entries(array['hrv','sleep_stage']));
select pg_temp.check(pg_temp.drain_done()=array['2026-09-04:respiration','2026-09-05:hrv','2026-09-05:sleep_stage'],
  'oldest first across owners, days and metrics');
select pg_temp.ok('fair order');

-- 4. Leases: a live lease is not handed out twice; a lost lease cannot settle.
delete from public.physiology_candidate_pending;
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-06',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-06',1,pg_temp.entries(array['hrv']));
create temp table held as select pg_temp.claim() as it;
select pg_temp.check((select it is not null and (it->>'attempts')::int=0 and it->>'lease_owner'='contract-worker'
  and (it->>'input_revision')::bigint=1 from held), 'claim returns the item under a lease');
select pg_temp.check(pg_temp.claim() is null, 'a leased item is not claimed again');
select pg_temp.check((pg_temp.settle(it,'done','recorded',true,null,4,gen_random_uuid())->>'refused')='lease_lost',
  'a wrong token cannot settle') from held;
select pg_temp.check((pg_temp.row_of(pg_temp.ua(),'2026-09-06','hrv')).state='pending', 'wrong token changed nothing');
-- The lease expires (the holder stalled): its settle is refused and the item is claimable again,
-- with the abandoned run counted.
update public.physiology_candidate_pending set lease_until=clock_timestamp()-interval '1 second'
 where period_day='2026-09-06';
select pg_temp.check((pg_temp.settle(it,'done','recorded')->>'refused')='lease_lost', 'expired lease cannot settle')
  from held;
select pg_temp.check((pg_temp.row_of(pg_temp.ua(),'2026-09-06','hrv')).state='pending', 'expired settle changed nothing');
create temp table held2 as select pg_temp.claim() as it;
select pg_temp.check((select (it->>'attempts')::int=1 and it->>'last_reason'='lease_expired'
  and it->>'lease_token'<>(select it->>'lease_token' from held) from held2), 'reclaim counts the abandoned run');
select pg_temp.check((pg_temp.settle(it,'done','recorded')->>'refused')='lease_lost', 'old holder still refused')
  from held;
select pg_temp.check((pg_temp.settle(it,'done','recorded')->>'settled')::boolean, 'new holder settles') from held2;
select pg_temp.check((pg_temp.settle(it,'done','recorded')->>'refused')='not_pending', 'settled once only') from held2;
select pg_temp.ok('leases');

-- 5. Stale revisions: a run at an old revision cannot settle or overwrite the newer one.
delete from public.physiology_candidate_pending;
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-07',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-07',1,pg_temp.entries(array['sleep_stage']));
create temp table old_run as select pg_temp.claim() as it;
-- New data while the old run computes: the day is re-scored at revision 2 and re-enqueued.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-07',2);
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-07',2,pg_temp.entries(array['sleep_stage']))=1,
  're-armed at revision 2');
select pg_temp.check((pg_temp.settle(it,'done','recorded')->>'refused')='stale_input_revision', 'stale done refused')
  from old_run;
select pg_temp.check((pg_temp.settle(it,'withheld','provider_error')->>'refused')='stale_input_revision',
  'stale withheld refused') from old_run;
select pg_temp.check((pg_temp.settle(it,'retry','timeout',true,0,1)->>'refused')='stale_input_revision',
  'stale retry refused') from old_run;
select pg_temp.check((select state='pending' and input_revision=2 and attempts=0 and lease_token is null
  and last_reason is null from pg_temp.row_of(pg_temp.ua(),'2026-09-07','sleep_stage')),
  'the newer revision is untouched');
-- The same with the revision passed explicitly: the old token at the new revision is a lost lease.
select pg_temp.check((pg_temp.settle(it,'done','recorded',true,null,4,null,2)->>'refused')='lease_lost',
  'old token at the new revision refused') from old_run;
-- The day moves on without a re-enqueue (scoring has not finished yet): claim supersedes the row.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-07',3);
select pg_temp.check(pg_temp.claim() is null, 'a stale row is never handed out');
select pg_temp.check((select state='superseded' and last_reason='stale_input_revision'
  from pg_temp.row_of(pg_temp.ua(),'2026-09-07','sleep_stage')), 'and is superseded inside the claim');
-- A late stale enqueue cannot resurrect it either.
select pg_temp.check(pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-07',2,pg_temp.entries(array['sleep_stage']))=0,
  'stale enqueue after supersede refused');
select pg_temp.ok('stale revision');

-- 6. Attempts are bounded; busy, budget and deadline are not attempts.
delete from public.physiology_candidate_pending;
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-08',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-08',1,pg_temp.entries(array['respiration']));
do $$ declare it jsonb; r jsonb; reason text; begin
  -- Non-attempts first: the row stays pending with each reason, attempts stay 0.
  foreach reason in array array['budget','deadline','busy'] loop
    it:=pg_temp.claim();
    perform pg_temp.check(it is not null, 'claimable for '||reason);
    r:=pg_temp.settle(it,'retry',reason,false,0,3);
    perform pg_temp.check(r->>'state'='pending' and (r->>'attempts')::int=0, reason||' is not an attempt');
    perform pg_temp.check((pg_temp.row_of(pg_temp.ua(),'2026-09-08','respiration')).last_reason=reason,
      reason||' is visible as the reason');
  end loop;
  -- A busy retry with Retry-After is not due until then.
  it:=pg_temp.claim();
  r:=pg_temp.settle(it,'retry','busy',false,30,3);
  perform pg_temp.check(pg_temp.claim() is null, 'busy retry waits for Retry-After');
  update public.physiology_candidate_pending set next_attempt_at=clock_timestamp() where period_day='2026-09-08';
  -- Real attempts: two timeouts stay pending, the third (max 3) settles withheld.
  it:=pg_temp.claim(); r:=pg_temp.settle(it,'retry','timeout',true,0,3);
  perform pg_temp.check(r->>'state'='pending' and (r->>'attempts')::int=1, 'attempt 1 pending');
  it:=pg_temp.claim(); r:=pg_temp.settle(it,'retry','timeout',true,0,3);
  perform pg_temp.check(r->>'state'='pending' and (r->>'attempts')::int=2, 'attempt 2 pending');
  it:=pg_temp.claim(); r:=pg_temp.settle(it,'retry','timeout',true,0,3);
  perform pg_temp.check(r->>'state'='withheld' and (r->>'attempts')::int=3
    and r->>'reason'='attempts_exhausted:timeout', 'attempt 3 is terminal withheld');
  perform pg_temp.check(pg_temp.claim() is null, 'a terminal row is never claimed again');
end $$;
-- The worker's own terminal settle carries the attempt and the recorded candidate.
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-09',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-09',1,pg_temp.entries(array['hrv']));
select pg_temp.check((public.physiology_candidate_pending_settle(pg_temp.ua(),pg_temp.da(),'2026-09-09','hrv',1,
    (it->>'lease_token')::uuid,'withheld','attempts_exhausted:timeout','c0000000-0000-4000-8000-0000000000aa',
    true,null,4)->>'state')='withheld', 'worker terminal settle')
  from (select pg_temp.claim() as it) c;
select pg_temp.check((select attempts=1 and candidate_id='c0000000-0000-4000-8000-0000000000aa'
  from pg_temp.row_of(pg_temp.ua(),'2026-09-09','hrv')), 'terminal settle stores attempt and candidate');
-- Invalid settles raise.
do $$ begin
  begin
    perform public.physiology_candidate_pending_settle(pg_temp.ua(),pg_temp.da(),'2026-09-09','hrv',1,
      gen_random_uuid(),'completed','x',null,false,null,4);
    raise exception 'unknown outcome accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.physiology_candidate_pending_settle(pg_temp.ua(),pg_temp.da(),'2026-09-09','hrv',1,
      gen_random_uuid(),'retry','busy',null,false,-1,4);
    raise exception 'negative retry_after accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.physiology_candidate_pending_claim('w',0);
    raise exception 'lease 0 accepted';
  exception when sqlstate '22023' then null;
  end;
end $$;
select pg_temp.ok('attempts');

-- 7. Stats: counts and the oldest pending age.
delete from public.physiology_candidate_pending;
select pg_temp.check((select (s->>'pending')::int=0 and (s->>'oldest_pending_age_s')::int=0
  and s->'by_metric'='{}'::jsonb from (select public.physiology_candidate_pending_stats() s) x), 'empty stats');
select pg_temp.job(pg_temp.ua(),pg_temp.da(),'2026-09-10',1);
select pg_temp.job(pg_temp.ub(),pg_temp.db(),'2026-09-10',1);
select pg_temp.enqueue(pg_temp.ua(),pg_temp.da(),'2026-09-10',1,pg_temp.entries(pg_temp.all4()));
select pg_temp.enqueue(pg_temp.ub(),pg_temp.db(),'2026-09-10',1,pg_temp.entries(array['hrv']));
select pg_temp.enqueue(pg_temp.ub(),pg_temp.db(),'2026-09-10',1,pg_temp.entries(array['respiration'],false));
update public.physiology_candidate_pending set pending_since=clock_timestamp()-interval '2 hours'
 where user_id=pg_temp.ua() and metric='sleep_stage';
-- One leased, one waiting on busy with a Retry-After.
select pg_temp.claim();                                                    -- leases A sleep_stage (oldest)
select pg_temp.settle(pg_temp.claim(),'retry','busy',false,600);            -- A hrv waits 10 min
create temp table st as select public.physiology_candidate_pending_stats() s;
select pg_temp.check((select (s->>'pending')::int=5 from st), 'pending counts every waiting row');
select pg_temp.check((select (s->>'leased')::int=1 from st), 'leased');
select pg_temp.check((select (s->>'due')::int=3 from st), 'due excludes leased and not-yet-due');
select pg_temp.check((select (s->>'oldest_pending_age_s')::int between 7200 and 7300 from st), 'oldest age');
select pg_temp.check((select s->'by_metric'='{"hrv":2,"sleep_boundary":1,"sleep_stage":1,"respiration":1}'::jsonb
  from st), 'by metric');
select pg_temp.check((select (s->'by_reason'->>'busy')::int=1 and (s->'by_reason'->>'new')::int=4 from st), 'by reason');
select pg_temp.check((select (s->>'withheld_24h')::int=1 and (s->>'superseded_24h')::int=0 from st), 'withheld 24h');
select pg_temp.ok('stats');

-- 8. Caller isolation: a client JWT subject cannot use the queue.
do $$ begin
  perform set_config('request.jwt.claim.sub','c0000000-0000-4000-8000-000000000001',true);
  begin
    perform public.physiology_candidate_pending_claim('w',60);
    raise exception 'claim with a client subject accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.physiology_candidate_pending_stats();
    raise exception 'stats with a client subject accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.physiology_candidate_pending_enqueue(pg_temp.ub(),pg_temp.db(),'2026-09-11',1,pg_temp.entries(array['hrv']));
    raise exception 'cross-user enqueue accepted';
  exception when sqlstate '22023' then null;
  end;
  perform set_config('request.jwt.claim.sub','',true);
end $$;
select pg_temp.ok('caller isolation');

-- 9. Selection read: requested and effective mode, additive to the existing keys.
select pg_temp.check((select s->>'mode'='off' and s->>'effective_mode'='off' and s->>'requested_mode'='off'
  and (s->>'demoted')::boolean=false and s->'mode_reason'='null'::jsonb and s ? 'source' and s ? 'provider_id'
  from (select public.physiology_selected_provider(pg_temp.ua(),'hrv') s) x), 'off selection');
update public.physiology_provider_defaults set mode='shadow', provider_id='prov-a', provider_version='1.0.0',
  config_version='c1' where metric='hrv';
select pg_temp.check((select s->>'mode'='shadow' and s->>'effective_mode'='shadow' and s->>'requested_mode'='shadow'
  and s->'mode_reason'='null'::jsonb and s->>'source'='default'
  from (select public.physiology_selected_provider(pg_temp.ua(),'hrv') s) x), 'shadow selection');
update public.physiology_provider_defaults set mode='active' where metric='hrv';
select pg_temp.check((select s->>'mode'='shadow' and s->>'effective_mode'='shadow' and s->>'requested_mode'='active'
  and (s->>'demoted')::boolean and s->>'mode_reason' in ('promotion_approval_required','promotion_gate_unavailable')
  and s->>'source'='default_demoted_unapproved'
  from (select public.physiology_selected_provider(pg_temp.ua(),'hrv') s) x), 'unapproved active is demoted, visibly');
select pg_temp.ok('selection modes');

rollback;
