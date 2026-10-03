-- Proves which device feeds server_daily_scores and that the projection carries skin temperature, SpO2 and
-- confidence. Needs a disposable local database named physiology_queue_test with the scoring migrations and
-- 20261001190000_baseline_device_selection.sql applied; everything is rolled back.
\set ON_ERROR_STOP on
begin;
do $$ begin
  assert current_database()='physiology_queue_test' and inet_server_addr()='127.0.0.1'::inet,
    'disposable local queue database required';
  assert not exists(select 1 from auth.users), 'refusing to run against a database that already holds users';
end $$;

create function pg_temp.job(p_user uuid,p_device uuid,p_day date) returns void language sql as $$
  insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version) values(p_user,p_device,p_day,'frwhoop-server-1')
$$;
create function pg_temp.snap(p_user uuid,p_device uuid,p_day date,p_revision bigint,p_status text,p_hr bigint,
  p_daily jsonb,p_sleep jsonb default '[]') returns void language sql as $$
  insert into scoring_snapshots_v2(user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
  values(p_user,p_device,p_day,'frwhoop-server-1',p_revision,'2026-10-01T00:00:00Z'::timestamptz+p_revision*interval '1 minute',
    jsonb_build_object('status',p_status,'coverage',jsonb_build_object('hr',jsonb_build_object('received',p_hr)),
      'daily',p_daily,'sleep',p_sleep))
$$;
create function pg_temp.pick(p_user uuid,p_day date) returns uuid language sql as $$
  select public.selected_scoring_device_v2(p_user,p_day,'frwhoop-server-1')
$$;

do $$
declare
  u1 uuid:='bb2a1000-0000-4000-8000-000000000001';
  u2 uuid:='bb2a1000-0000-4000-8000-000000000002';
  d_low uuid:='bb2a1000-0000-4000-8000-000000000011';
  d_inst uuid:='bb2a1000-0000-4000-8000-000000000012';
  d_serial uuid:='bb2a1000-0000-4000-8000-000000000013';
  d_inst2 uuid:='bb2a1000-0000-4000-8000-000000000014';
  d2_data uuid:='bb2a1000-0000-4000-8000-000000000022';
  d2_empty uuid:='bb2a1000-0000-4000-8000-000000000021';
  rich jsonb:=jsonb_build_object('hrv_rmssd_ms',53.1,'resting_hr_bpm',47,'resp_rate_bpm',15,'sleep_total_min',420,
    'sleep_in_bed_min',450,'skin_temp_c',34.75,'skin_temp_dev_c',-0.2,'spo2_pct',97.5,
    'confidence',jsonb_build_object('charge','high','effort','high','rest','high'));
  three jsonb:='{"hrv_rmssd_ms":60,"resting_hr_bpm":50,"sleep_total_min":400}';
  one jsonb:='{"resting_hr_bpm":52}';
  steps_only jsonb:='{"steps":4000}';
  night jsonb:='[{"id":"night-1","start_at":"2026-09-19T22:00:00Z","end_at":"2026-09-20T06:00:00Z","is_nap":false,
    "in_bed_min":480,"asleep_min":420,"awake_min":60,"light_min":200,"deep_min":100,"rem_min":120,"efficiency":0.875,
    "resting_hr_bpm":47,"hrv_rmssd_ms":53.1,"stages":[]}]';
begin
  insert into auth.users(id) values(u1),(u2);
  insert into profiles(id,timezone) values(u1,'UTC'),(u2,'UTC') on conflict(id) do nothing;
  insert into devices(id,user_id,source_kind,external_device_id) values
    (d_low,u1,'noop_push','installation:aaaa:ble-1'),
    (d_inst,u1,'noop_push','installation:bbbb:ble-1'),
    (d_serial,u1,'noop_push','whoop-TEST0001'),
    (d_inst2,u1,'noop_push','installation:cccc:ble-1'),
    (d2_empty,u2,'noop_push','installation:dddd:ble-1'),
    (d2_data,u2,'noop_push','installation:eeee:ble-1');

  -- A: an empty duplicate with the lowest id must not hide the device that holds the night.
  perform pg_temp.job(u1,d_low,'2026-09-20'); perform pg_temp.job(u1,d_inst,'2026-09-20'); perform pg_temp.job(u1,d_serial,'2026-09-20');
  perform pg_temp.snap(u1,d_low,'2026-09-20',1,'no_data',0,'{}');
  perform pg_temp.snap(u1,d_inst,'2026-09-20',1,'available',143827,rich,night);
  -- B: nothing scored anywhere: serial-scoped beats installation-scoped even with less heart-rate coverage.
  perform pg_temp.job(u1,d_low,'2026-09-21'); perform pg_temp.job(u1,d_inst,'2026-09-21'); perform pg_temp.job(u1,d_serial,'2026-09-21');
  perform pg_temp.snap(u1,d_low,'2026-09-21',1,'no_data',0,'{}');
  perform pg_temp.snap(u1,d_inst,'2026-09-21',1,'partial',227057,steps_only);
  perform pg_temp.snap(u1,d_serial,'2026-09-21',1,'partial',82022,steps_only);
  -- C: more scored metrics beat the serial-scoped identity.
  perform pg_temp.job(u1,d_inst,'2026-09-22'); perform pg_temp.job(u1,d_serial,'2026-09-22');
  perform pg_temp.snap(u1,d_inst,'2026-09-22',1,'available',100000,rich);
  perform pg_temp.snap(u1,d_serial,'2026-09-22',1,'available',100000,three);
  -- D: an available snapshot beats a partial one that has more metrics.
  perform pg_temp.job(u1,d_inst,'2026-09-23'); perform pg_temp.job(u1,d_serial,'2026-09-23');
  perform pg_temp.snap(u1,d_inst,'2026-09-23',1,'partial',200000,three);
  perform pg_temp.snap(u1,d_serial,'2026-09-23',1,'available',50000,one);
  -- E: any snapshot beats a job that has none yet.
  perform pg_temp.job(u1,d_low,'2026-09-24'); perform pg_temp.job(u1,d_inst,'2026-09-24');
  perform pg_temp.snap(u1,d_low,'2026-09-24',1,'no_data',0,'{}');
  -- F: no snapshots at all: serial-scoped, not merely the lowest id.
  perform pg_temp.job(u1,d_low,'2026-09-25'); perform pg_temp.job(u1,d_serial,'2026-09-25');
  -- G/H: heart-rate coverage, then lowest id, separate identical installation-scoped duplicates.
  perform pg_temp.job(u1,d_inst,'2026-09-26'); perform pg_temp.job(u1,d_inst2,'2026-09-26');
  perform pg_temp.snap(u1,d_inst,'2026-09-26',1,'available',1000,rich);
  perform pg_temp.snap(u1,d_inst2,'2026-09-26',1,'available',5000,rich);
  perform pg_temp.job(u1,d_inst,'2026-09-27'); perform pg_temp.job(u1,d_inst2,'2026-09-27');
  perform pg_temp.snap(u1,d_inst,'2026-09-27',1,'available',5000,rich);
  perform pg_temp.snap(u1,d_inst2,'2026-09-27',1,'available',5000,rich);
  -- I: only the latest snapshot of each device counts.
  perform pg_temp.job(u1,d_inst,'2026-09-28'); perform pg_temp.job(u1,d_serial,'2026-09-28');
  perform pg_temp.snap(u1,d_inst,'2026-09-28',1,'available',90000,rich);
  perform pg_temp.snap(u1,d_inst,'2026-09-28',2,'no_data',0,'{}');
  perform pg_temp.snap(u1,d_serial,'2026-09-28',1,'partial',10,steps_only);
  -- Another owner is ranked independently.
  perform pg_temp.job(u2,d2_empty,'2026-09-20'); perform pg_temp.job(u2,d2_data,'2026-09-20');
  perform pg_temp.snap(u2,d2_empty,'2026-09-20',1,'no_data',0,'{}');
  perform pg_temp.snap(u2,d2_data,'2026-09-20',1,'available',70000,rich);

  assert pg_temp.pick(u1,'2026-09-20')=d_inst,'A: empty lowest-id duplicate won';
  assert pg_temp.pick(u1,'2026-09-21')=d_serial,'B: serial-scoped identity did not win the tie';
  assert pg_temp.pick(u1,'2026-09-22')=d_inst,'C: richer snapshot did not win';
  assert pg_temp.pick(u1,'2026-09-23')=d_serial,'D: available did not beat partial';
  assert pg_temp.pick(u1,'2026-09-24')=d_low,'E: a snapshot did not beat a missing one';
  assert pg_temp.pick(u1,'2026-09-25')=d_serial,'F: unscored tie did not prefer the serial-scoped device';
  assert pg_temp.pick(u1,'2026-09-26')=d_inst2,'G: heart-rate coverage did not break the tie';
  assert pg_temp.pick(u1,'2026-09-27')=d_inst,'H: lowest id did not break the final tie';
  assert pg_temp.pick(u1,'2026-09-28')=d_serial,'I: an older snapshot outranked the latest one';
  assert pg_temp.pick(u2,'2026-09-20')=d2_data,'owner two: empty duplicate won';
  assert pg_temp.pick(u1,'2026-12-31') is null,'a day without jobs selected a device';

  insert into scoring_source_preferences_v2 values(u1,d_low);
  assert pg_temp.pick(u1,'2026-09-20')=d_low,'explicit source preference no longer overrides';
  delete from scoring_source_preferences_v2 where user_id=u1;
  assert pg_temp.pick(u1,'2026-09-20')=d_inst;

  -- Projection: values come from the selected snapshot and stale values never survive.
  insert into server_daily_scores(user_id,day,algorithm_version,source_device_id,hrv_rmssd_ms,skin_temp_c,spo2_pct,
    readiness_level,confidence) values(u1,'2026-09-20','frwhoop-server-1',d_low,1,99,88,'high','{"charge":"stale"}');
  insert into server_daily_scores(user_id,day,algorithm_version,source_device_id,skin_temp_c,skin_temp_dev_c,spo2_pct,
    readiness_level,confidence) values(u1,'2026-09-23','frwhoop-server-1',d_low,99,9,88,'high','{"charge":"stale"}');
  perform refresh_scoring_legacy_v2(u1,'2026-09-20','frwhoop-server-1');
  perform refresh_scoring_legacy_v2(u1,'2026-09-23','frwhoop-server-1');
  assert (select (source_device_id,hrv_rmssd_ms,resting_hr_bpm,resp_rate_bpm,sleep_total_min,skin_temp_c,skin_temp_dev_c,spo2_pct)::text
    from server_daily_scores where user_id=u1 and day='2026-09-20')=format('(%s,53.1,47,15,420,34.75,-0.2,97.5)',d_inst),
    'projection dropped or kept the wrong values';
  assert (select confidence from server_daily_scores where user_id=u1 and day='2026-09-20')=
    '{"charge":"high","effort":"high","rest":"high"}'::jsonb,'confidence not projected';
  assert (select readiness_level from server_daily_scores where user_id=u1 and day='2026-09-20') is null,
    'v2 projection stopped clearing readiness';
  assert (select (source_device_id,resting_hr_bpm,skin_temp_c,skin_temp_dev_c,spo2_pct,confidence,readiness_level)::text
    from server_daily_scores where user_id=u1 and day='2026-09-23')=format('(%s,52,,,,{},)',d_serial),
    'stale skin temperature, SpO2 or confidence survived a snapshot that lacks them';
  assert (select count(*) from server_sleep_nights where user_id=u1 and period_day='2026-09-20' and device_id=d_inst)=1,
    'sleep night not projected for the selected device';
  perform refresh_scoring_legacy_v2(u1,'2026-09-20','frwhoop-server-1');
  assert (select count(*) from server_sleep_nights where user_id=u1 and period_day='2026-09-20')=1,
    'sleep night duplicated on refresh';
end $$;

-- Backfill: rows attributed to empty duplicates are re-attributed from the immutable snapshots.
delete from server_daily_scores;
delete from server_sleep_nights;
insert into server_daily_scores(user_id,day,algorithm_version,source_device_id)
  select u,d::date,'frwhoop-server-1',x
  from (values ('bb2a1000-0000-4000-8000-000000000001'::uuid,'bb2a1000-0000-4000-8000-000000000011'::uuid),
               ('bb2a1000-0000-4000-8000-000000000002'::uuid,'bb2a1000-0000-4000-8000-000000000021'::uuid)) o(u,x)
  cross join generate_series('2026-09-20'::date,'2026-09-28'::date,interval '1 day') d
  where not (u='bb2a1000-0000-4000-8000-000000000002'::uuid and d::date>'2026-09-20');
do $$
declare
  u1 uuid:='bb2a1000-0000-4000-8000-000000000001';
  u2 uuid:='bb2a1000-0000-4000-8000-000000000002';
  refreshed integer; before_rows jsonb; after_rows jsonb;
begin
  refreshed:=public.reproject_scoring_legacy_v2(u1);
  assert refreshed=8,format('expected 8 owner-days with snapshots, refreshed %s',refreshed);
  assert (select source_device_id from server_daily_scores where user_id=u2 and day='2026-09-20')=
    'bb2a1000-0000-4000-8000-000000000021'::uuid,'reprojecting one owner touched another';
  assert (select source_device_id from server_daily_scores where user_id=u1 and day='2026-09-20')=
    'bb2a1000-0000-4000-8000-000000000012'::uuid,'backfill did not re-attribute day A';
  assert (select skin_temp_c from server_daily_scores where user_id=u1 and day='2026-09-20')=34.75,'backfill lost skin temperature';
  assert (select source_device_id from server_daily_scores where user_id=u1 and day='2026-09-21')=
    'bb2a1000-0000-4000-8000-000000000013'::uuid;
  assert (select source_device_id from server_daily_scores where user_id=u1 and day='2026-09-25')=
    'bb2a1000-0000-4000-8000-000000000011'::uuid,'a day with no snapshots must keep the existing row';
  assert (select array_agg(day order by day) from server_daily_scores where user_id=u1 and skin_temp_c is not null)=
    array['2026-09-20','2026-09-22','2026-09-26','2026-09-27']::date[],
    'skin temperature should be present on exactly the days whose selected snapshot has it';
  select jsonb_agg(to_jsonb(t)-'updated_at'-'created_at' order by day) into before_rows
    from server_daily_scores t where user_id=u1;
  refreshed:=public.reproject_scoring_legacy_v2();
  assert refreshed=9,format('expected 9 owner-days with snapshots across owners, refreshed %s',refreshed);
  assert (select source_device_id from server_daily_scores where user_id=u2 and day='2026-09-20')=
    'bb2a1000-0000-4000-8000-000000000022'::uuid,'backfill did not re-attribute the second owner';
  select jsonb_agg(to_jsonb(t)-'updated_at'-'created_at' order by day) into after_rows
    from server_daily_scores t where user_id=u1;
  assert before_rows=after_rows,'a second backfill run changed owner one rows';
  assert (select count(*) from server_daily_scores where user_id=u1)=9 and
    (select count(*) from server_sleep_nights where user_id=u1)=1,'second run changed row counts';
end $$;

-- One day that cannot be projected is skipped, not fatal.
do $$
declare refreshed integer;
begin
  perform pg_temp.job('bb2a1000-0000-4000-8000-000000000001','bb2a1000-0000-4000-8000-000000000012','2026-09-29');
  perform pg_temp.snap('bb2a1000-0000-4000-8000-000000000001','bb2a1000-0000-4000-8000-000000000012','2026-09-29',1,
    'available',10,'{"hrv_rmssd_ms":"not-a-number"}');
  refreshed:=public.reproject_scoring_legacy_v2('bb2a1000-0000-4000-8000-000000000001');
  assert refreshed=8,format('bad day was not skipped cleanly (refreshed %s)',refreshed);
  assert not exists(select 1 from server_daily_scores
    where user_id='bb2a1000-0000-4000-8000-000000000001' and day='2026-09-29'),'bad day produced a row';
  assert (select count(*) from server_daily_scores where user_id='bb2a1000-0000-4000-8000-000000000001')=9,
    'bad day disturbed the other days';
end $$;

do $$ begin
  assert not has_function_privilege('anon','public.reproject_scoring_legacy_v2(uuid,text)','execute');
  assert not has_function_privilege('authenticated','public.reproject_scoring_legacy_v2(uuid,text)','execute');
  assert has_function_privilege('service_role','public.reproject_scoring_legacy_v2(uuid,text)','execute');
  assert not has_function_privilege('authenticated','public.selected_scoring_device_v2(uuid,date,text)','execute');
  assert (select (provolatile,prosecdef)::text from pg_proc
    where oid='public.selected_scoring_device_v2(uuid,date,text)'::regprocedure)='(s,f)','selector volatility or definer changed';
  assert (select prosecdef from pg_proc where oid='public.refresh_scoring_legacy_v2(uuid,date,text)'::regprocedure),
    'projection is no longer security definer';
end $$;
rollback;
select '{"status":"PASS","fixture":"synthetic_baseline_device_selection","raw_rows_moved":false}'::jsonb;
