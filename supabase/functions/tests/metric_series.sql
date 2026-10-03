-- Proves the dense metric series: only the device the day's scores are read from may write it, a publish
-- replaces exactly the claimed window per metric (changing, adding and removing buckets, touching nothing
-- else), an unchanged publish writes nothing, bad payloads are rejected whole, and only the service role
-- can publish or read through the RPCs while an owner sees only their own rows. Needs a disposable local
-- database named physiology_queue_test with the scoring migrations, 20261001190000_baseline_device_selection.sql,
-- 20261001210000_metric_series.sql and 20261002120000_metric_series_per_metric_buckets.sql applied;
-- everything is rolled back.
\set ON_ERROR_STOP on
begin;
set local timezone = 'UTC';
do $$ begin
  assert current_database()='physiology_queue_test' and inet_server_addr()='127.0.0.1'::inet,
    'disposable local queue database required';
  assert not exists(select 1 from auth.users), 'refusing to run against a database that already holds users';
end $$;

create function pg_temp.job(p_user uuid,p_device uuid,p_day date) returns void language sql as $$
  insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version) values(p_user,p_device,p_day,'frwhoop-server-1')
$$;
create function pg_temp.snap(p_user uuid,p_device uuid,p_day date,p_status text,p_hr bigint) returns void language sql as $$
  insert into scoring_snapshots_v2(user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
  values(p_user,p_device,p_day,'frwhoop-server-1',1,'2026-10-01T00:00:00Z',
    jsonb_build_object('status',p_status,'coverage',jsonb_build_object('hr',jsonb_build_object('received',p_hr)),
      'daily','{"hrv_rmssd_ms":53.1,"resting_hr_bpm":47,"resp_rate_bpm":15,"sleep_total_min":420}'::jsonb,'sleep','[]'::jsonb))
$$;
create function pg_temp.pt(p_ts bigint,p_value numeric,p_n integer default 100,p_cov numeric default 0.5,
  p_motion numeric default null) returns jsonb language sql as $$
  select jsonb_build_array(p_ts,p_value,p_n,p_cov,p_motion)
$$;
create function pg_temp.payload(p_start bigint,p_end bigint,p_metrics jsonb,p_bucket integer default 300)
returns jsonb language sql as $$
  select jsonb_build_object('algorithm_version','frwhoop-series-1','bucket_seconds',p_bucket,
    'window',jsonb_build_object('start',p_start,'end',p_end),'metrics',p_metrics)
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no_error';
exception when others then
  return sqlstate;
end $$;

do $$
declare
  u1 uuid:='bb2b1000-0000-4000-8000-000000000001';
  u2 uuid:='bb2b1000-0000-4000-8000-000000000002';
  d_strap uuid:='bb2b1000-0000-4000-8000-000000000011';
  d_inst uuid:='bb2b1000-0000-4000-8000-000000000012';
  d2 uuid:='bb2b1000-0000-4000-8000-000000000021';
  the_day date:='2026-09-20';
  prev_day date:='2026-09-19';
  t0 bigint; t1 bigint; p0 bigint; p1 bigint;
  r jsonb; payload jsonb; before_rows bigint;
begin
  t0:=extract(epoch from the_day::timestamptz)::bigint; t1:=t0+86400;
  p0:=t0-86400; p1:=t0;
  insert into auth.users(id) values(u1),(u2);
  insert into profiles(id,timezone) values(u1,'UTC'),(u2,'UTC') on conflict(id) do nothing;
  insert into devices(id,user_id,source_kind,external_device_id) values
    (d_strap,u1,'noop_push','whoop-TEST0002'),(d_inst,u1,'noop_push','installation:aaaa:ble-9'),
    (d2,u2,'noop_push','whoop-TEST0003');
  perform pg_temp.job(u1,d_strap,the_day); perform pg_temp.job(u1,d_inst,the_day);
  perform pg_temp.job(u1,d_strap,prev_day); perform pg_temp.job(u1,d_inst,prev_day);
  perform pg_temp.job(u2,d2,the_day);
  perform pg_temp.snap(u1,d_strap,the_day,'available',80000); perform pg_temp.snap(u1,d_inst,the_day,'no_data',0);
  perform pg_temp.snap(u1,d_strap,prev_day,'available',80000); perform pg_temp.snap(u1,d_inst,prev_day,'no_data',0);
  perform pg_temp.snap(u2,d2,the_day,'available',80000);
  assert public.selected_scoring_device_v2(u1,the_day,'frwhoop-server-1')=d_strap,'fixture: the strap is not the selected device';

  -- A: the selected device's first publish writes every point, attributed to it.
  payload:=pg_temp.payload(t0,t1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60.5,120,0.5,0.25),pg_temp.pt(t0+300,62,140,0.75),pg_temp.pt(t0+600,58.2,90)),
    'resting_hr_bpm',jsonb_build_array(pg_temp.pt(t0,48.5,60,0.25,0),pg_temp.pt(t0+300,48,60)),
    'resp_rate_bpm',jsonb_build_array(pg_temp.pt(t0+300,15.5,400,0.75)),
    'steps',jsonb_build_array(pg_temp.pt(t0,0,300,1),pg_temp.pt(t0+300,0,300,1),pg_temp.pt(t0+600,120,300,1),pg_temp.pt(t0+900,95,300,1)),
    'calories_kcal',jsonb_build_array(pg_temp.pt(t0,5.75,300,1),pg_temp.pt(t0+300,5.8,300,1),pg_temp.pt(t0+600,9.1,300,1),pg_temp.pt(t0+900,8.2,300,1))));
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',payload);
  assert (r->>'applied')::boolean and (r->>'upserted')::int=14 and (r->>'deleted')::int=0,format('first publish: %s',r);
  assert (select count(*) from server_metric_series where user_id=u1)=14,'rows after the first publish';
  assert not exists(select 1 from server_metric_series where user_id=u1 and device_id<>d_strap),'rows not attributed to the selected device';
  assert (select (value,sample_count,coverage,motion,bucket_seconds,algorithm_version)::text from server_metric_series
    where user_id=u1 and metric='hrv_rmssd_ms' and bucket_start=to_timestamp(t0))='(60.5,120,0.5,0.25,300,frwhoop-series-1)',
    'point fields were not stored as sent';
  assert (select motion is null from server_metric_series where user_id=u1 and metric='hrv_rmssd_ms' and bucket_start=to_timestamp(t0+300)),
    'a null motion was not kept null';

  -- B: publishing the same thing again writes nothing.
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',payload);
  assert (r->>'applied')::boolean and (r->>'upserted')::int=0 and (r->>'deleted')::int=0,format('unchanged publish wrote: %s',r);

  -- C: change one bucket, add one, drop one: exactly those rows move, and nothing else does.
  payload:=pg_temp.payload(t0,t1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60.5,120,0.5,0.25),pg_temp.pt(t0+300,64.4,140,0.75),pg_temp.pt(t0+900,70,80))));
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',payload);
  assert (r->'metrics'->'hrv_rmssd_ms'->>'upserted')::int=2 and (r->'metrics'->'hrv_rmssd_ms'->>'deleted')::int=1,
    format('changed/added/dropped counts: %s',r);
  assert (select array_agg(extract(epoch from bucket_start)::bigint order by bucket_start) from server_metric_series
    where user_id=u1 and metric='hrv_rmssd_ms')=array[t0,t0+300,t0+900],'hrv buckets after the replacement';
  assert (select value from server_metric_series where user_id=u1 and metric='hrv_rmssd_ms' and bucket_start=to_timestamp(t0+300))=64.4,
    'a changed bucket kept its old value';
  assert (select count(*) from server_metric_series where user_id=u1 and metric<>'hrv_rmssd_ms')=11,
    'a metric absent from the payload was touched';

  -- D: a metric that is present but empty clears its window; the others stay.
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object('steps','[]'::jsonb)));
  assert (r->>'deleted')::int=4 and (r->>'upserted')::int=0,format('empty metric did not clear: %s',r);
  assert not exists(select 1 from server_metric_series where user_id=u1 and metric='steps'),'steps survived an empty replacement';
  assert (select count(*) from server_metric_series where user_id=u1)=10,'rows of other metrics changed';

  -- E: another day's rows are outside the window and survive.
  r:=public.publish_metric_series_v1(u1,d_strap,prev_day,'frwhoop-server-1',pg_temp.payload(p0,p1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(p0+3600,55)))));
  assert (r->>'applied')::boolean and (r->>'upserted')::int=1,format('previous day publish: %s',r);
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms','[]'::jsonb)));
  assert (r->>'deleted')::int=3,format('window replacement: %s',r);
  assert (select count(*) from server_metric_series where user_id=u1 and bucket_start<to_timestamp(t0))=1,
    'a publish for one day removed another day''s bucket';

  -- F: a device that is not the selected one writes nothing and changes nothing.
  select count(*) into before_rows from server_metric_series;
  r:=public.publish_metric_series_v1(u1,d_inst,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,99)),'calories_kcal','[]'::jsonb)));
  assert not (r->>'applied')::boolean and r->>'reason'='not_selected',format('duplicate device was applied: %s',r);
  assert (select count(*) from server_metric_series)=before_rows,'a non-selected device changed rows';

  -- G: an explicit source preference moves ownership, and the new owner replaces the window.
  insert into scoring_source_preferences_v2 values(u1,d_inst);
  r:=public.publish_metric_series_v1(u1,d_inst,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object(
    'calories_kcal',jsonb_build_array(pg_temp.pt(t0,5.75,300,1),pg_temp.pt(t0+300,5.9,300,1)))));
  assert (r->>'applied')::boolean and (r->'metrics'->'calories_kcal'->>'upserted')::int=2
    and (r->'metrics'->'calories_kcal'->>'deleted')::int=2,format('new owner replace: %s',r);
  assert (select array_agg(device_id order by bucket_start) from server_metric_series where user_id=u1 and metric='calories_kcal')
    =array[d_inst,d_inst],'replaced buckets were not re-attributed';
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object('calories_kcal','[]'::jsonb)));
  assert not (r->>'applied')::boolean,'the former owner still wrote after the preference moved';
  delete from scoring_source_preferences_v2 where user_id=u1;

  -- H: a repeated bucket timestamp inside one payload does not fail it.
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object(
    'resp_rate_bpm',jsonb_build_array(pg_temp.pt(t0+300,15.5),pg_temp.pt(t0+300,15.5),pg_temp.pt(t0+600,16)))));
  assert (select count(*) from server_metric_series where user_id=u1 and metric='resp_rate_bpm')=2,'duplicate timestamp payload';

  -- I: rejected payloads fail whole and leave the rows as they were.
  select count(*) into before_rows from server_metric_series;
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60),pg_temp.pt(t1,61))))::text))='22023',
    'a point past the window was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('heart_rate',jsonb_build_array(pg_temp.pt(t0,60))))::text))='22023',
    'an unknown metric was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60))),30)::text))='22023',
    'a bucket width of 30 s was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t0-1,jsonb_build_object('hrv_rmssd_ms','[]'::jsonb))::text))='22023','an inverted window was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms','{}'::jsonb))::text))='22023','non-array points were accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1','[]'::jsonb)$f$,u1,d_strap))='22023',
    'a non-object payload was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,5000))))::text))='23514',
    'an impossible HRV was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60,100,1.5))))::text))='23514',
    'a coverage above 1 was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms',jsonb_build_array(jsonb_build_array('x',60,1,1,0))))::text))='22P02',
    'a non-numeric timestamp was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d2,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms','[]'::jsonb))::text))='42501','another owner''s device was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-series-1',%L::jsonb)$f$,
    u1,d_strap,pg_temp.payload(t0,t1,jsonb_build_object('hrv_rmssd_ms','[]'::jsonb))::text))='22023',
    'the series version was accepted where the scoring version belongs';
  assert (select count(*) from server_metric_series)=before_rows,'a rejected payload left rows behind';

  -- J: reads return the buckets of the range, in order, per metric, and only the owner's.
  r:=public.publish_metric_series_v1(u2,d2,the_day,'frwhoop-server-1',pg_temp.payload(t0,t1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,41)))));
  assert (r->>'applied')::boolean,format('second owner publish: %s',r);
  r:=public.server_metric_series_read(u1,to_timestamp(t0),to_timestamp(t1));
  assert (r->>'from')::bigint=t0 and (r->>'to')::bigint=t1 and (r->>'bucket_seconds')::int=300,format('read envelope: %s',r);
  assert (select array_agg(k order by k) from jsonb_object_keys(r->'metrics') k)
    =array['calories_kcal','hrv_rmssd_ms','resp_rate_bpm','resting_hr_bpm','steps'],'read did not return every metric key';
  assert r->'metrics'->'resting_hr_bpm'=jsonb_build_array(jsonb_build_array(t0,48.5,60,0.25,0),jsonb_build_array(t0+300,48,60,0.5,null)),
    format('resting hr points: %s',r->'metrics'->'resting_hr_bpm');
  assert r->'metrics'->'steps'='[]'::jsonb,'an emptied metric did not read as empty';
  assert (r->'metrics'->'calories_kcal'->0->>1)::numeric=5.75,'calories first bucket';
  assert r->>'latest_computed_at' is not null,'no latest_computed_at on a populated range';
  assert (public.server_metric_series_read(u1,to_timestamp(t0+300),to_timestamp(t0+600),array['resting_hr_bpm'])
    ->'metrics')=jsonb_build_object('resting_hr_bpm',jsonb_build_array(jsonb_build_array(t0+300,48,60,0.5,null))),
    'range or metric filter';
  assert public.server_metric_series_read(u2,to_timestamp(t0),to_timestamp(t1),array['hrv_rmssd_ms'])->'metrics'->'hrv_rmssd_ms'
    =jsonb_build_array(jsonb_build_array(t0,41,100,0.5,null)),'second owner read';
  assert public.server_metric_series_read(u2,to_timestamp(t0+86400),to_timestamp(t0+90000))->'latest_computed_at'='null'::jsonb,
    'an empty range reported a computed_at';
  assert pg_temp.err(format($f$select public.server_metric_series_read(%L,to_timestamp(%s),to_timestamp(%s))$f$,u1,t0,t0+86400*4))='22023',
    'a four-day read was accepted';
  assert pg_temp.err(format($f$select public.server_metric_series_read(%L,to_timestamp(%s),to_timestamp(%s))$f$,u1,t0,t0))='22023',
    'an empty range was accepted';
  assert pg_temp.err(format($f$select public.server_metric_series_read(%L,to_timestamp(%s),to_timestamp(%s),array['heart_rate'])$f$,u1,t0,t1))='22023',
    'an unknown metric read was accepted';

  -- J2: a metric may have its own bucket width (needs 20261002120000_metric_series_per_metric_buckets.sql). The default applies to a metric the payload does not name, the
  -- read reports each metric's widest bucket plus the widest overall, and a malformed width rejects the payload.
  payload:=pg_temp.payload(t0,t1,jsonb_build_object(
    'hrv_rmssd_ms',jsonb_build_array(pg_temp.pt(t0,60.5)),
    'resp_rate_bpm',jsonb_build_array(pg_temp.pt(t0,15),pg_temp.pt(t0+60,15.5)),
    'steps',jsonb_build_array(pg_temp.pt(t0,3,60,1)),
    'calories_kcal','[]'::jsonb))
    || jsonb_build_object('metric_bucket_seconds',jsonb_build_object('resp_rate_bpm',60,'steps',60));
  r:=public.publish_metric_series_v1(u1,d_strap,the_day,'frwhoop-server-1',payload);
  assert (r->>'applied')::boolean,format('per-metric publish: %s',r);
  assert (select bucket_seconds from server_metric_series where user_id=u1 and metric='resp_rate_bpm' and bucket_start=to_timestamp(t0+60))=60,
    'a named metric did not take its own width';
  assert (select bucket_seconds from server_metric_series where user_id=u1 and metric='hrv_rmssd_ms')=300,
    'an unnamed metric did not take the default width';
  r:=public.server_metric_series_read(u1,to_timestamp(t0),to_timestamp(t1));
  assert (r->>'bucket_seconds')::int=300 and r->'metric_bucket_seconds'->>'steps'='60'
    and r->'metric_bucket_seconds'->>'resting_hr_bpm'='300',format('read widths: %s',r);
  assert not (r->'metric_bucket_seconds') ? 'calories_kcal','a metric with no rows reported a width';
  before_rows:=(select count(*) from server_metric_series);
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,(payload || '{"metric_bucket_seconds":{"steps":30}}'::jsonb)::text))='22023','a 30 s metric width was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,(payload || '{"metric_bucket_seconds":{"heart_rate":60}}'::jsonb)::text))='22023','an unknown metric width was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,(payload || '{"metric_bucket_seconds":{"steps":60.5}}'::jsonb)::text))='22023','a fractional metric width was accepted';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1',%L::jsonb)$f$,
    u1,d_strap,(payload || '{"metric_bucket_seconds":[]}'::jsonb)::text))='22023','a non-object width map was accepted';
  assert (select count(*) from server_metric_series)=before_rows,'a rejected width left rows behind';

  -- K: an owner sees only their rows; nobody else can publish or read through the RPCs.
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',u1)::text,true);
  perform set_config('request.jwt.claim.sub',u1::text,true);
  set local role authenticated;
  assert (select count(*) from server_metric_series)=(select count(*) from server_metric_series where user_id=u1)
    and (select count(*) from server_metric_series)>0,'an owner sees rows that are not theirs';
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1','{}'::jsonb)$f$,u1,d_strap))='42501',
    'authenticated can publish';
  assert pg_temp.err(format($f$select public.server_metric_series_read(%L,to_timestamp(%s),to_timestamp(%s))$f$,u1,t0,t1))='42501',
    'authenticated can read through the RPC';
  assert pg_temp.err($f$insert into server_metric_series(user_id,metric,bucket_start,value,device_id,algorithm_version)
    values('bb2b1000-0000-4000-8000-000000000001','steps',now(),1,'bb2b1000-0000-4000-8000-000000000011','x')$f$)='42501',
    'authenticated can write the table';
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',u2)::text,true);
  perform set_config('request.jwt.claim.sub',u2::text,true);
  assert (select count(*) from server_metric_series where user_id=u1)=0,'a second owner can see the first owner''s rows';
  reset role;
  set local role anon;
  assert pg_temp.err(format($f$select public.publish_metric_series_v1(%L,%L,'2026-09-20','frwhoop-server-1','{}'::jsonb)$f$,u1,d_strap))='42501',
    'anon can publish';
  assert pg_temp.err('select count(*) from server_metric_series')='42501','anon can read the table';
  reset role;
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  set local role service_role;
  r:=public.server_metric_series_read(u1,to_timestamp(t0),to_timestamp(t1),array['hrv_rmssd_ms']);
  assert jsonb_typeof(r->'metrics'->'hrv_rmssd_ms')='array','service role cannot read';
  reset role;

  -- L: deleting the owner removes their series.
  delete from auth.users where id=u2;
  assert not exists(select 1 from server_metric_series where user_id=u2),'series survived the owner';
end $$;

do $$ begin
  assert not has_function_privilege('anon','public.publish_metric_series_v1(uuid,uuid,date,text,jsonb)','execute');
  assert not has_function_privilege('authenticated','public.publish_metric_series_v1(uuid,uuid,date,text,jsonb)','execute');
  assert has_function_privilege('service_role','public.publish_metric_series_v1(uuid,uuid,date,text,jsonb)','execute');
  assert not has_function_privilege('authenticated','public.server_metric_series_read(uuid,timestamptz,timestamptz,text[])','execute');
  assert has_function_privilege('service_role','public.server_metric_series_read(uuid,timestamptz,timestamptz,text[])','execute');
  assert (select prosecdef from pg_proc where oid='public.publish_metric_series_v1(uuid,uuid,date,text,jsonb)'::regprocedure),
    'publish is no longer security definer';
  assert (select relrowsecurity from pg_class where oid='public.server_metric_series'::regclass),'row level security is off';
  assert not has_table_privilege('authenticated','public.server_metric_series','insert'),'authenticated can insert';
  assert has_table_privilege('authenticated','public.server_metric_series','select'),'authenticated cannot select';
end $$;
rollback;
select '{"status":"PASS","fixture":"synthetic_metric_series","raw_rows_moved":false}'::jsonb;
