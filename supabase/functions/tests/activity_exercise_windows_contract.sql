-- RecGym exercise windows DB contract (20261009160000_activity_exercise_windows.sql). Runs inside the isolated,
-- fully migrated test database (activity_authority_sql_test.ts: every migration in order, native PostgreSQL). Every
-- fixture change rolls back; no deployed credentials or data are touched.
--
--   psql -X -qAt -v ON_ERROR_STOP=1 -f activity_exercise_windows_contract.sql
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values
 ('d0000000-0000-4000-8000-000000000001'),
 ('d0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('d0000000-0000-4000-8000-000000000011','d0000000-0000-4000-8000-000000000001','noop_push'),
 ('d0000000-0000-4000-8000-000000000012','d0000000-0000-4000-8000-000000000002','noop_push');

create function pg_temp.ew_model() returns jsonb language sql as $$
  select jsonb_build_object('model_id', 'recgym-cnn-transformer', 'model_version', 'recgym-cnn-transformer-e085ac0',
    'weights_sha256', '7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9',
    'scaler_version', 'recgym-wrist-imu-scaler-1', 'preprocessing_version', 'recgym-prep-1',
    'classes', jsonb_build_array('Adductor', 'ArmCurl', 'BenchPress', 'LegCurl', 'LegPress', 'Null', 'Riding',
                                 'RopeSkipping', 'Running', 'Squat', 'StairClimber', 'Walking'),
    'window_s', 4, 'hop_s', 2)
$$;
create function pg_temp.ew_authority(p_rev bigint) returns jsonb language sql as $$
  select jsonb_build_object('policy', 'expert-authority-1', 'channel', 'exercise_recognition', 'route', 'standalone',
    'mode', 'shadow', 'release_mode', 'shadow', 'use', 'none', 'reason', 'shadow_only',
    'input_revision', p_rev::text, 'pinned_model_version', null, 'pinned_weights_digest', null, 'gait_prior', null)
$$;
-- Window k: BenchPress-heavy when k is odd, Null-heavy otherwise; fingerprint from the seed.
create function pg_temp.ew_probs(p_k integer) returns jsonb language sql as $$
  select case when p_k % 2 = 1
    then '[0.01,0.01,0.86,0.01,0.01,0.03,0.01,0.01,0.01,0.02,0.01,0.01]'::jsonb
    else '[0.004,0.001,0.002,0.003,0,0.98,0,0,0.002,0.003,0.002,0.003]'::jsonb end
$$;
create function pg_temp.ew_windows(p_lo bigint, p_n integer, p_seed text default 'a') returns jsonb
language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object('s', p_lo + 2 * k,
                                               'fp', encode(sha256(convert_to(p_seed || k::text, 'UTF8')), 'hex'),
                                               'p', pg_temp.ew_probs(k)) order by k), '[]'::jsonb)
    from generate_series(0, p_n - 1) as g(k)
$$;
create function pg_temp.ew_payload(p_day date, p_lo bigint, p_n integer, p_rev bigint, p_seed text default 'a')
returns jsonb language sql as $$
  select jsonb_build_object('day', p_day::text, 'schema', 'exercise-windows-1', 'model', pg_temp.ew_model(),
    'authority', pg_temp.ew_authority(p_rev),
    'spans', jsonb_build_array(jsonb_build_array(p_lo, p_lo + 2 * p_n + 2)),
    'windows', pg_temp.ew_windows(p_lo, p_n, p_seed))
$$;
create function pg_temp.ew_enqueue(p_user uuid, p_dev uuid, p_day date, p_digit text) returns void
language plpgsql as $$
declare fp text; lo bigint := extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat(p_digit,64)],lo,lo+86399,'hart-activity-1',
    'hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(p_user,p_dev,p_day,array[gen_random_uuid()],array[repeat(p_digit,64)],fp);
end $$;
create function pg_temp.ew_day_lo(p_day date) returns bigint language sql as $$
  select extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint
$$;
create function pg_temp.ew_rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_exercise_windows(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 1. Fenced publish stores one shadow row per window with its outputs, identity and lineage; the job stays claimed,
-- nothing else is written, and the v1 publish still completes the job.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-12';
  lo bigint := pg_temp.ew_day_lo('2026-11-12') + 3600;
  j record; rev bigint; r record; v1rev bigint;
begin
  perform pg_temp.ew_enqueue(u, dev, v_day, '1');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  rev := public.publish_activity_exercise_windows(j.lease_token, j.input_revision,
                                                  pg_temp.ew_payload(v_day, lo, 6, j.input_revision));
  assert rev is not null and rev >= 1, 'a valid payload must return a result revision';
  assert (select count(*) from public.activity_exercise_windows where user_id=u and device_id=dev) = 6, 'six rows';
  select * into r from public.activity_exercise_windows
   where user_id=u and device_id=dev and window_start=to_timestamp(lo + 2);
  assert r.model_id='recgym-cnn-transformer' and r.model_version='recgym-cnn-transformer-e085ac0'
     and r.weights_sha256='7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9'
     and r.scaler_version='recgym-wrist-imu-scaler-1' and r.preprocessing_version='recgym-prep-1'
     and r.window_s=4, 'model identity per window';
  assert r.top_class='BenchPress' and abs(r.top_p - 0.86) < 1e-6 and abs(r.p_null - 0.03) < 1e-6,
    'top class, its probability and P(Null)';
  assert (r.probs->>'BenchPress')::numeric = 0.86 and (r.probs->>'Null')::numeric = 0.03
     and (select count(*) from jsonb_object_keys(r.probs)) = 12, 'class -> probability for all twelve classes';
  assert r.input_sha256 = encode(sha256(convert_to('a1', 'UTF8')), 'hex'), 'input fingerprint stored';
  assert r.release_mode='shadow', 'shadow release';
  assert r.placement is null and r.placement_supported = false and r.placement_reason = 'placement_unknown',
    'undeclared placement stays NULL and is not supported';
  assert r.day=v_day and r.job_fingerprint=j.fingerprint and r.input_revision=j.input_revision
     and r.result_revision=rev and r.computed_at is not null, 'job lineage';
  assert (select top_class from public.activity_exercise_windows where user_id=u and window_start=to_timestamp(lo))
         = 'Null', 'a Null-heavy window';
  assert (select lease_token=j.lease_token and completed_revision=0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the shadow publish must not complete the job';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day)
     and not exists(select 1 from public.activity_context_epochs where user_id=u and device_id=dev and day=v_day)
     and not exists(select 1 from public.activity_encoder_windows where user_id=u and device_id=dev and day=v_day)
     and not exists(select 1 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day)
     and not exists(select 1 from public.scoring_work_items where user_id=u and device_id=dev and day=v_day),
    'the shadow publish writes nothing else and dirties no scoring';
  v1rev := public.publish_activity_context_v2(j.lease_token, j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
      jsonb_build_object('s',lo,'e',lo+30,'m','stationary','p','sitting','ex','false','sl','awake',
        'ec','resting_candidate','w','on_wrist','c',0.9,'os',30,'vs',30))),100);
  assert v1rev is not null, 'the v1 publish must still succeed after the shadow publish';
  assert public.publish_activity_exercise_windows(j.lease_token, j.input_revision,
    pg_temp.ew_payload(v_day, lo, 6, j.input_revision)) is null, 'a completed job fences the shadow publish';
  raise notice 'PASS 1 shadow windows stored beside an unchanged v1 completion';
end;
$$;

-- 2. Fence: stale revision, unknown token and expired lease return NULL and write nothing, before validation.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-13';
  lo bigint := pg_temp.ew_day_lo('2026-11-13');
  j record;
begin
  perform pg_temp.ew_enqueue(u, dev, v_day, '2');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert public.publish_activity_exercise_windows(j.lease_token, j.input_revision + 1,
    pg_temp.ew_payload(v_day, lo, 3, j.input_revision)) is null, 'stale revision publishes NULL';
  assert public.publish_activity_exercise_windows(gen_random_uuid(), j.input_revision,
    pg_temp.ew_payload(v_day, lo, 3, j.input_revision)) is null, 'unknown token publishes NULL';
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
   where user_id=u and device_id=dev and day=v_day;
  assert public.publish_activity_exercise_windows(j.lease_token, j.input_revision,
    pg_temp.ew_payload(v_day, lo, 3, j.input_revision)) is null, 'expired lease publishes NULL';
  assert public.publish_activity_exercise_windows(j.lease_token, j.input_revision, '[]'::jsonb) is null,
    'the fence comes before payload validation';
  assert not exists(select 1 from public.activity_exercise_windows where user_id=u and device_id=dev and day=v_day),
    'a fenced-out publish writes nothing';
  raise notice 'PASS 2 fence';
end;
$$;

-- 3. Placement per window from the strap's resolved timeline: undeclared -> NULL / placement_unknown, bicep ->
-- placement_unsupported, wrist -> supported; a device-scoped declaration wins over the owner's device-less one.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-14';
  lo bigint := pg_temp.ew_day_lo('2026-11-14');
  j record;
begin
  -- owner-level: wrist from lo+10; device: bicep from lo+20 to lo+40, wrist from lo+40
  insert into public.placement_intervals(owner, device_id, placement, effective_start, effective_end) values
    (u, null, 'wrist', to_timestamp(lo + 10), null),
    (u, dev, 'bicep', to_timestamp(lo + 20), to_timestamp(lo + 40)),
    (u, dev, 'wrist', to_timestamp(lo + 40), null);
  perform pg_temp.ew_enqueue(u, dev, v_day, '3');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  perform public.publish_activity_exercise_windows(j.lease_token, j.input_revision,
                                                   pg_temp.ew_payload(v_day, lo, 25, j.input_revision));
  assert (select placement is null and not placement_supported and placement_reason = 'placement_unknown'
            from public.activity_exercise_windows where user_id=u and window_start=to_timestamp(lo + 4)),
    'before any declaration: undeclared';
  assert (select placement = 'wrist' and placement_supported and placement_reason is null
            from public.activity_exercise_windows where user_id=u and window_start=to_timestamp(lo + 12)),
    'owner-level wrist where no device declaration applies';
  assert (select placement = 'bicep' and not placement_supported and placement_reason = 'placement_unsupported'
            from public.activity_exercise_windows where user_id=u and window_start=to_timestamp(lo + 30)),
    'the device-scoped bicep wins over the owner-level wrist';
  assert (select placement = 'wrist' and placement_supported
            from public.activity_exercise_windows where user_id=u and window_start=to_timestamp(lo + 40)),
    'a later device declaration takes over at its start';
  raise notice 'PASS 3 placement per window';
end;
$$;

-- 4. A span is replaced as a whole: windows it no longer has are removed, windows outside it are untouched, and an
-- identical window keeps its row version (result_revision).
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-15';
  lo bigint := pg_temp.ew_day_lo('2026-11-15') + 7200;
  j record; rev1 bigint; rev2 bigint; p jsonb;
begin
  perform pg_temp.ew_enqueue(u, dev, v_day, '4');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  -- two chunks: [lo, lo+22) with 10 windows, [lo+100, lo+122) with 10 windows
  p := pg_temp.ew_payload(v_day, lo, 10, j.input_revision);
  p := jsonb_set(p, '{spans}', (p -> 'spans') || jsonb_build_array(jsonb_build_array(lo + 100, lo + 122)));
  p := jsonb_set(p, '{windows}', (p -> 'windows') || pg_temp.ew_windows(lo + 100, 10, 'b'));
  rev1 := public.publish_activity_exercise_windows(j.lease_token, j.input_revision, p);
  assert (select count(*) from public.activity_exercise_windows where user_id=u and day=v_day) = 20, 'twenty rows';
  -- the first chunk recomputed: three windows changed input, the last four are gone
  p := jsonb_build_object('day', v_day::text, 'schema', 'exercise-windows-1', 'model', pg_temp.ew_model(),
         'authority', pg_temp.ew_authority(j.input_revision), 'spans', jsonb_build_array(jsonb_build_array(lo, lo + 22)),
         'windows', (select jsonb_agg(case when (w ->> 's')::bigint < lo + 6
                                           then jsonb_set(w, '{fp}', to_jsonb(repeat('c', 64))) else w end)
                       from jsonb_array_elements(pg_temp.ew_windows(lo, 6)) x(w)));
  rev2 := public.publish_activity_exercise_windows(j.lease_token, j.input_revision, p);
  assert rev2 > rev1, 'a new result revision';
  assert (select count(*) from public.activity_exercise_windows
           where user_id=u and day=v_day and window_start < to_timestamp(lo + 100)) = 6, 'four windows removed';
  assert (select count(*) from public.activity_exercise_windows
           where user_id=u and day=v_day and window_start >= to_timestamp(lo + 100) and result_revision = rev1) = 10,
    'the other chunk is untouched';
  assert (select count(*) from public.activity_exercise_windows
           where user_id=u and day=v_day and window_start < to_timestamp(lo + 6) and result_revision = rev2
             and input_sha256 = repeat('c', 64)) = 3, 'changed windows are rewritten';
  assert (select count(*) from public.activity_exercise_windows
           where user_id=u and day=v_day and window_start >= to_timestamp(lo + 6)
             and window_start < to_timestamp(lo + 100) and result_revision = rev1) = 3,
    'identical windows keep their row version';
  raise notice 'PASS 4 span replacement and identical rows';
end;
$$;

-- 5. Payload contract: every malformed or over-claiming payload is refused with a stable message and writes nothing.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-16';
  lo bigint := pg_temp.ew_day_lo('2026-11-16') + 600;
  j record; tok uuid; rev bigint; p jsonb;
begin
  perform pg_temp.ew_enqueue(u, dev, v_day, '5');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  tok := j.lease_token; rev := j.input_revision; p := pg_temp.ew_payload(v_day, lo, 4, rev);
  assert pg_temp.ew_rejects(tok,rev,'[]'::jsonb,'invalid_exercise_windows_payload'), 'non-object';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{day}','"2026-11-17"'),'invalid_exercise_windows_payload'), 'day';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{schema}','"gait-quality-1"'),'invalid_exercise_windows_schema'),
    'schema';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{model,model_id}','"eldernet"'),'invalid_exercise_windows_model'),
    'model id';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{model,classes,0}','"Null"'),'invalid_exercise_windows_model'),
    'class order';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{model,window_s}','10'),'invalid_exercise_windows_model'), 'window';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{model,weights_sha256}','"abc"'),'invalid_exercise_windows_model'),
    'weights digest';
  assert pg_temp.ew_rejects(tok,rev,p - 'authority','invalid_exercise_windows_authority'), 'no authority block';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{authority,release_mode}','"candidate"'),
    'invalid_exercise_windows_authority'), 'a candidate release is refused';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{authority,mode}','"production"'),
    'invalid_exercise_windows_authority'), 'a production mode is refused';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{authority,use}','"canonical"'),
    'invalid_exercise_windows_authority'), 'canonical use is refused';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{authority,channel}','"gait_quality"'),
    'invalid_exercise_windows_authority'), 'another channel';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{spans}','[[1,2]]'),'invalid_exercise_windows_spans'),
    'a span outside the day';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{spans,0,1}',to_jsonb(lo)),'invalid_exercise_windows_spans'),
    'an empty span';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,s}',to_jsonb(lo + 1)),'invalid_exercise_windows_windows'),
    'an odd window start';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,s}',to_jsonb(lo + 40)),'invalid_exercise_windows_windows'),
    'a window outside every span';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,1,s}',to_jsonb(lo)),'invalid_exercise_windows_windows'),
    'a duplicate window';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,fp}','"xyz"'),'invalid_exercise_windows_windows'),
    'a bad fingerprint';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,p}','[0.5,0.5]'),'invalid_exercise_windows_windows'),
    'eleven-or-fewer probabilities';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,p,0}','1.5'),'invalid_exercise_windows_windows'),
    'a probability above one';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,p,5}','0.5'),'invalid_exercise_windows_windows'),
    'probabilities that do not sum to one';
  assert pg_temp.ew_rejects(tok,rev,jsonb_set(p,'{windows,0,p,5}','"0.98"'),'invalid_exercise_windows_windows'),
    'a probability that is not a number';
  assert not exists(select 1 from public.activity_exercise_windows where user_id=u and day=v_day),
    'a refused payload writes nothing';
  assert public.publish_activity_exercise_windows(tok, rev, p) is not null, 'the unmodified payload is accepted';
  raise notice 'PASS 5 payload contract';
end;
$$;

-- 6. Retention by window time, its bounds and its privileges.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  n integer;
begin
  update public.activity_exercise_windows set window_start = window_start - interval '400 days'
   where user_id = u and day = '2026-11-12';
  n := public.prune_activity_exercise_windows(30, 100000);
  assert n >= 6, 'aged windows are deleted';
  assert not exists(select 1 from public.activity_exercise_windows where user_id=u and day='2026-11-12'),
    'aged windows are gone';
  begin
    perform public.prune_activity_exercise_windows(0, 10);
    assert false, 'keep_days 0 must be refused';
  exception when others then assert sqlerrm = 'invalid_exercise_windows_retention', sqlerrm;
  end;
  assert not has_function_privilege('anon', 'public.prune_activity_exercise_windows(integer,integer)', 'execute'),
    'anon cannot prune';
  assert not has_function_privilege('authenticated', 'public.prune_activity_exercise_windows(integer,integer)',
    'execute'), 'authenticated cannot prune';
  assert has_function_privilege('service_role', 'public.prune_activity_exercise_windows(integer,integer)', 'execute'),
    'the worker role can prune';
  raise notice 'PASS 6 retention';
end;
$$;

-- 7. Privileges: only the service role writes (through the RPC); owners read their own rows; nothing above shadow
-- can be stored even by the service role.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  other uuid := 'd0000000-0000-4000-8000-000000000002';
  n integer;
begin
  assert not has_function_privilege('anon', 'public.publish_activity_exercise_windows(uuid,bigint,jsonb)', 'execute'),
    'anon cannot publish';
  assert not has_function_privilege('authenticated', 'public.publish_activity_exercise_windows(uuid,bigint,jsonb)',
    'execute'), 'authenticated cannot publish';
  assert has_function_privilege('service_role', 'public.publish_activity_exercise_windows(uuid,bigint,jsonb)',
    'execute'), 'the worker role can publish';
  assert not has_table_privilege('authenticated', 'public.activity_exercise_windows', 'insert'), 'no client insert';
  assert not has_table_privilege('authenticated', 'public.activity_exercise_windows', 'update'), 'no client update';
  assert not has_table_privilege('authenticated', 'public.activity_exercise_windows', 'delete'), 'no client delete';
  assert not has_table_privilege('anon', 'public.activity_exercise_windows', 'select'), 'no anonymous read';
  assert has_table_privilege('authenticated', 'public.activity_exercise_windows', 'select'), 'owner read path';
  assert (select relrowsecurity from pg_class where oid = 'public.activity_exercise_windows'::regclass), 'RLS on';
  begin
    update public.activity_exercise_windows set release_mode = 'candidate' where user_id = u;
    assert false, 'a release above shadow must be refused';
  exception when check_violation then null;
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_exercise_windows;
  assert n >= 1, 'the owner sees their rows';
  select count(*) into n from public.activity_exercise_windows where user_id <> u;
  assert n = 0, 'and only theirs';
  reset role;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', other::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_exercise_windows;
  assert n = 0, 'another user sees nothing';
  reset role;
  raise notice 'PASS 7 privileges';
end;
$$;

rollback;
