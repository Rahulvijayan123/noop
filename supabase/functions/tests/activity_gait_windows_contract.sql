-- ElderNet gait windows DB contract (20261006090000_activity_gait_windows.sql). Runs inside the isolated, fully
-- migrated test database with the activity migrations (20261003120000_activity_context.sql,
-- 20261003130000_activity_context_days.sql, …) and 20261006090000_activity_gait_windows.sql applied. Every fixture
-- change rolls back; no deployed credentials or data are touched.
--
-- Run against a disposable cluster the way the other *.sql tests run:
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261006090000_activity_gait_windows.sql \
--        -f activity_gait_windows_contract.sql
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values
 ('c0000000-0000-4000-8000-000000000001'),
 ('c0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('c0000000-0000-4000-8000-000000000011','c0000000-0000-4000-8000-000000000001','noop_push'),
 ('c0000000-0000-4000-8000-000000000012','c0000000-0000-4000-8000-000000000002','noop_push');

-- The served weights (made up) and their combined digest, computed exactly as the worker and the decoder do.
create function pg_temp.gw_weights(p_seed text default 'a') returns jsonb language sql as $$
  select jsonb_object_agg(h, repeat(p_seed, 64))
  from unnest(array['gait_detection','gait_speed','gait_length','cadence','regularity','step_count']) as h
$$;
create function pg_temp.gw_digest(p_weights jsonb) returns text language sql as $$
  select encode(sha256(convert_to('eldernet-weights-1' || chr(10)
    || string_agg(key || '=' || (value #>> '{}') || chr(10), '' order by key collate "C"), 'UTF8')), 'hex')
  from jsonb_each(p_weights)
$$;
create function pg_temp.gw_model(p_version text default 'eldernet-437a38b', p_seed text default 'a',
                                 p_hop integer default 5) returns jsonb language sql as $$
  select jsonb_build_object('model_id', 'eldernet', 'model_version', p_version, 'weights', pg_temp.gw_weights(p_seed),
    'upstream_commit', '437a38bcc69f42717fe73c1f7dbea7e1f7a50d23', 'preprocessing_version', 'eldernet-prep-1',
    'window_s', 10, 'hop_s', p_hop,
    'calibration', jsonb_build_object('gait_prob', jsonb_build_object('method', 'temperature', 'T', 1.0, 'fit', 'val')),
    'gait_threshold', 0.5)
$$;
create function pg_temp.gw_col(p_n integer, p_value integer) returns jsonb language sql as $$
  select coalesce(jsonb_agg(p_value order by i), '[]'::jsonb) from generate_series(0, p_n - 1) as g(i)
$$;
-- Columnar windows (gait-windows-1), what the worker writes: every third window gait with metrics.
create function pg_temp.gw_windows(p_day date, p_n integer, p_hop integer default 5) returns jsonb language sql as $$
  select jsonb_build_object(
    'format', 'gait-windows-1', 'n', p_n, 'w', 10, 'h', p_hop,
    's0', case when p_n > 0 then extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint end,
    'ds', coalesce((select jsonb_agg(case when i = 0 then 0 else p_hop end order by i)
                    from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'gp', coalesce((select jsonb_agg(case when i % 3 = 0 then 950 else 100 end order by i)
                    from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'g', coalesce((select jsonb_agg(case when i % 3 = 0 then 1 else 0 end order by i)
                   from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'pf', pg_temp.gw_col(p_n, 0),
    'sp', coalesce((select jsonb_agg(case when i % 3 = 0 then 121 else -1 end order by i)
                    from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'cad', pg_temp.gw_col(p_n, -1), 'st', pg_temp.gw_col(p_n, -1), 'rg', pg_temp.gw_col(p_n, -1),
    'stp', pg_temp.gw_col(p_n, -1))
$$;
create function pg_temp.gw_payload(p_day date, p_mode text default 'shadow', p_n integer default 9,
                                   p_model jsonb default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'day', p_day::text, 'mode', p_mode, 'schema', 'gait-quality-1',
    'model', coalesce(p_model, pg_temp.gw_model()),
    'weights_digest', pg_temp.gw_digest((coalesce(p_model, pg_temp.gw_model())) -> 'weights'),
    'summary', jsonb_build_object('n_windows', p_n, 'n_gait', (p_n + 2) / 3, 'n_prefiltered', 0,
                                  'n_dropped_nonfinite', 0, 'n_chunks', 1, 'n_failed_chunks', 0,
                                  'failure_kinds', '{}'::jsonb),
    'windows', pg_temp.gw_windows(p_day, p_n),
    'withheld_reason', case when p_mode = 'candidate' then 'model_not_pinned' end,
    'candidate_document', null)
$$;
create function pg_temp.gw_enqueue(p_user uuid, p_dev uuid, p_day date, p_digit text) returns void
language plpgsql as $$
declare fp text; lo bigint := extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat(p_digit,64)],lo,lo+86399,'hart-activity-1',
    'hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(p_user,p_dev,p_day,array[gen_random_uuid()],array[repeat(p_digit,64)],fp);
end $$;
create function pg_temp.gw_rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_gait_windows_day(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 0. The SQL digest is the worker's / decoder's digest (same canonical text): pinned against a value computed
-- with hashlib for the synthetic fixture's weights in Packages/StrandAnalytics (ca315e4d…).
do $$
declare w jsonb;
begin
  select jsonb_object_agg(h, encode(sha256(convert_to('synthetic-eldernet-' || h, 'UTF8')), 'hex')) into w
  from unnest(array['gait_detection','gait_speed','gait_length','cadence','regularity','step_count']) as h;
  assert pg_temp.gw_digest(w) = 'ca315e4db4a253a6a23f38c3c2dfb8590a253d22e65642e46d242dad89aa593a',
    'the weights digest must match the decoder''s';
  raise notice 'PASS 0 weights digest';
end;
$$;

-- 1. Fenced publish stores the shadow row; the job stays claimed and nothing else is written.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  dev uuid := 'c0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-02';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  j record; rev bigint; r record; v1rev bigint;
begin
  perform pg_temp.gw_enqueue(u, dev, v_day, '1');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  rev := public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day));
  assert rev is not null and rev >= 1, 'a valid payload must return a result revision';
  select * into r from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day;
  assert found, 'the shadow row must exist';
  assert r.model_version='eldernet-437a38b' and r.mode='shadow' and r.model_id='eldernet'
     and r.weights_digest=pg_temp.gw_digest(pg_temp.gw_weights()) and r.weights=pg_temp.gw_weights()
     and r.upstream_commit='437a38bcc69f42717fe73c1f7dbea7e1f7a50d23' and r.gait_schema='gait-quality-1'
     and r.preprocessing_version='eldernet-prep-1', 'provenance must be denormalized';
  assert r.window_s=10 and r.hop_s=5 and r.gait_threshold=0.5 and r.n_windows=9 and r.n_gait=3
     and r.n_prefiltered=0 and r.n_dropped=0, 'counts must be mirrored';
  assert r.job_fingerprint=j.fingerprint and r.input_revision=j.input_revision
     and r.algorithm_version='hart-activity-1', 'row must record the job lineage';
  assert (r.windows->>'n')::integer=9 and jsonb_array_length(r.windows->'gp')=9 and r.windows->>'format'='gait-windows-1'
     and r.candidate_document is null and r.withheld_reason is null,
    'columnar windows stored, no candidate in shadow mode';
  assert r.result_revision=rev and r.computed_at is not null and r.created_at is not null, 'revision and stamps';
  assert (select lease_token=j.lease_token and completed_revision=0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the shadow publish must not complete the job';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'the shadow publish never writes a day document';
  assert not exists(select 1 from public.activity_context_epochs where user_id=u and device_id=dev and day=v_day),
    'the shadow publish never writes epochs';
  assert not exists(select 1 from public.activity_encoder_windows where user_id=u and device_id=dev and day=v_day),
    'the shadow publish never writes HART windows';
  assert not exists(select 1 from public.scoring_work_items where user_id=u and device_id=dev and day=v_day),
    'the shadow publish alone must not dirty scoring';
  v1rev := public.publish_activity_context_v2(j.lease_token, j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
      jsonb_build_object('s',lo,'e',lo+30,'m','stationary','p','sitting','ex','false','sl','awake',
        'ec','resting_candidate','w','on_wrist','c',0.9,'os',30,'vs',30))),100);
  assert v1rev is not null, 'the v1 publish must still succeed after the shadow publish';
  assert (select completed_revision=j.input_revision and lease_token is null from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'only the v1 publish completes the job';
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day)) is null,
    'a completed job fences the shadow publish';
  raise notice 'PASS 1 shadow row stored beside an unchanged v1 completion';
end;
$$;

-- 2. Fence: stale revision, unknown token and expired lease return NULL and write nothing; the fence comes before
-- validation.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  dev uuid := 'c0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-03';
  j record;
begin
  perform pg_temp.gw_enqueue(u, dev, v_day, '2');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision+1, pg_temp.gw_payload(v_day)) is null,
    'stale revision must publish NULL';
  assert public.publish_activity_gait_windows_day(gen_random_uuid(), j.input_revision, pg_temp.gw_payload(v_day)) is null,
    'unknown token must publish NULL';
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day)) is null,
    'expired lease must publish NULL';
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, '[]'::jsonb) is null,
    'fence must be evaluated before payload validation';
  assert not exists(select 1 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'a fenced-out publish must not write a row';
  raise notice 'PASS 2 fence';
end;
$$;

-- 3. Payload contract: every malformed payload is rejected with a stable message and writes nothing.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  dev uuid := 'c0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-04';
  j record; tok uuid; rev bigint; p jsonb; doc jsonb; m jsonb;
begin
  perform pg_temp.gw_enqueue(u, dev, v_day, '3');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  tok := j.lease_token; rev := j.input_revision; p := pg_temp.gw_payload(v_day);
  -- Envelope.
  assert pg_temp.gw_rejects(tok,rev,'[]'::jsonb,'invalid_gait_windows_payload'), 'non-object payload';
  assert pg_temp.gw_rejects(tok,rev,pg_temp.gw_payload('2026-11-05'),'invalid_gait_windows_payload'), 'another day';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{day}','"garbage"'),'invalid_gait_windows_payload'), 'unparseable day';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{schema}','"gait-quality-2"'),'invalid_gait_windows_schema'), 'schema';
  assert pg_temp.gw_rejects(tok,rev,p - 'schema','invalid_gait_windows_schema'), 'missing schema';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{mode}','"production"'),'invalid_gait_windows_payload'), 'mode';
  assert pg_temp.gw_rejects(tok,rev,p || jsonb_build_object('pad', repeat('x', 17000000)),'invalid_gait_windows_size'),
    'oversized payload';
  -- Model provenance.
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,model_id}','"hart"'),'invalid_gait_windows_model'), 'model id';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,model_version}','"bad version"'),'invalid_gait_windows_model'),
    'model version';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,upstream_commit}','"xyz"'),'invalid_gait_windows_model'), 'commit';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,window_s}','30'),'invalid_gait_windows_model'), 'window';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,hop_s}','7'),'invalid_gait_windows_model'), 'hop';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,hop_s}','"5"'),'invalid_gait_windows_model'), 'hop type';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,gait_threshold}','1'),'invalid_gait_windows_model'), 'threshold';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,gait_threshold}','0'),'invalid_gait_windows_model'), 'threshold 0';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,calibration}','[]'),'invalid_gait_windows_model'), 'calibration';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,weights,gait_mood}', to_jsonb(repeat('a',64))),
    'invalid_gait_windows_model'), 'unknown head';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model,weights,cadence}','"abc"'),'invalid_gait_windows_model'), 'head sha';
  assert pg_temp.gw_rejects(tok,rev,p #- '{model,weights,gait_detection}','invalid_gait_windows_model'),
    'the detection head is required';
  -- The combined digest is recomputed: a payload naming other weights than it carries is refused.
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{weights_digest}', to_jsonb(repeat('0',64))),'invalid_gait_windows_model'),
    'digest mismatch';
  m := jsonb_set(pg_temp.gw_model(), '{weights,step_count}', to_jsonb(repeat('b',64)));
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{model}', m),'invalid_gait_windows_model'),
    'weights changed under an unchanged digest';
  -- Summary and windows.
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{summary,n_gait}','10'),'invalid_gait_windows_summary'), 'n_gait > n';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(jsonb_set(p,'{summary,n_gait}','5'),'{summary,n_prefiltered}','5'),
    'invalid_gait_windows_summary'), 'gait + prefiltered > n';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{summary,n_windows}','-1'),'invalid_gait_windows_summary'), 'negative';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{summary,n_windows}','8'),'invalid_gait_windows_windows'), 'count mismatch';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows}','{}'),'invalid_gait_windows_windows'), 'windows format';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows}','[]'),'invalid_gait_windows_windows'), 'array form';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows,format}','"mh-col-1"'),'invalid_gait_windows_windows'),
    'another table''s format';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows,gp}','[0,5]'),'invalid_gait_windows_windows'), 'short column';
  assert pg_temp.gw_rejects(tok,rev,p #- '{windows,stp}','invalid_gait_windows_windows'), 'missing column';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows,h}','10'),'invalid_gait_windows_windows'),
    'the hop must be the model''s';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows,w}','30'),'invalid_gait_windows_windows'), 'window length';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{windows,cad}', to_jsonb(repeat('x', 1100000))),
    'invalid_gait_windows_windows'), 'windows over 1 MiB';
  -- Candidate rules.
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{withheld_reason}','"x"'),'invalid_gait_windows_candidate'),
    'a shadow row never carries a withheld reason';
  doc := jsonb_build_object('versions', jsonb_build_object('gait_quality','eldernet:eldernet-437a38b:aaaaaaaaaaaa:01234567'),
                            'runs', '[]'::jsonb);
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(p,'{candidate_document}',doc),'invalid_gait_windows_candidate'),
    'a shadow row never carries a candidate document';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(pg_temp.gw_payload(v_day,'candidate'),'{withheld_reason}','null'),
    'invalid_gait_windows_candidate'), 'a candidate row carries a document or a withheld reason';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(pg_temp.gw_payload(v_day,'candidate'),'{candidate_document}',doc),
    'invalid_gait_windows_candidate'), 'not both';
  assert pg_temp.gw_rejects(tok,rev,jsonb_set(jsonb_set(pg_temp.gw_payload(v_day,'candidate'),'{withheld_reason}','null'),
    '{candidate_document}', jsonb_build_object('versions','{}'::jsonb,'runs','[]'::jsonb)),
    'invalid_gait_windows_candidate'), 'a comparison document must name the gait evidence';
  assert not exists(select 1 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'no rejected payload may write a row';
  -- The live lease still accepts a good payload afterwards (each rejection rolled back only itself), and a payload
  -- without windows (over the worker's cap) is a row too.
  assert public.publish_activity_gait_windows_day(tok, rev, p) is not null, 'a valid payload still publishes';
  assert public.publish_activity_gait_windows_day(tok, rev, jsonb_set(p, '{windows}', 'null')) is not null,
    'windows may be omitted';
  assert (select windows is null from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'the republish without windows replaced the row';
  raise notice 'PASS 3 payload contract';
end;
$$;

-- 4. Upsert per (day, model version, mode): a republish replaces the row; shadow and candidate rows coexist; a
-- candidate comparison is stored verbatim; another model version is another row.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  dev uuid := 'c0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-06';
  j record; r1 bigint; r2 bigint; r3 bigint; doc jsonb; cand jsonb;
begin
  perform pg_temp.gw_enqueue(u, dev, v_day, '4');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  r1 := public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day, 'shadow', 9));
  r2 := public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day, 'shadow', 6));
  assert r2 > r1, 'a republish gets a newer revision';
  assert (select count(*)=1 and min(n_windows)=6 from public.activity_gait_windows_days
    where user_id=u and device_id=dev and day=v_day and mode='shadow'), 'the republish replaced the row';
  doc := jsonb_build_object('schema_version',2,'versions',
    jsonb_build_object('gait_quality','eldernet:eldernet-437a38b:aaaaaaaaaaaa:01234567','decoder','hsmm-1.3'),
    'runs','[]'::jsonb);
  cand := jsonb_set(jsonb_set(pg_temp.gw_payload(v_day, 'candidate', 6), '{withheld_reason}','null'),
    '{candidate_document}', doc);
  r3 := public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, cand);
  assert r3 is not null, 'a candidate comparison publishes';
  assert (select count(*)=2 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'shadow and candidate rows coexist';
  assert (select candidate_document=doc and withheld_reason is null from public.activity_gait_windows_days
    where user_id=u and device_id=dev and day=v_day and mode='candidate'), 'the comparison is stored verbatim';
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision,
    pg_temp.gw_payload(v_day, 'shadow', 6, pg_temp.gw_model('eldernet-next', 'c'))) is not null, 'another model version';
  assert (select count(*)=3 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'another model version is its own row';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'the comparison never reaches activity_context_days';
  -- The table refuses an unstamped comparison or one on a shadow row, even when something bypasses the RPC.
  begin
    update public.activity_gait_windows_days set candidate_document = '{"versions": {}, "runs": []}'::jsonb
      where user_id=u and device_id=dev and day=v_day and mode='candidate';
    assert false, 'an unstamped comparison document must violate the CHECK';
  exception when check_violation then null;
  end;
  begin
    update public.activity_gait_windows_days set candidate_document = doc, withheld_reason = null
      where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
    assert false, 'a shadow row with a comparison document must violate the CHECK';
  exception when check_violation then null;
  end;
  -- The windows CHECK has no NULL hole: a `format` that is missing, JSON null or another value is refused even
  -- when something bypasses the RPC (`->> 'format'` is NULL then, and a NULL check would pass).
  assert (select windows ->> 'format' = 'gait-windows-1' from public.activity_gait_windows_days
    where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b'),
    'the stored shadow row carries columnar windows';
  begin
    update public.activity_gait_windows_days set windows = windows - 'format'
      where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
    assert false, 'windows without a format key must violate the CHECK';
  exception when check_violation then null;
  end;
  begin
    update public.activity_gait_windows_days set windows = jsonb_set(windows, '{format}', 'null'::jsonb)
      where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
    assert false, 'windows with a null format must violate the CHECK';
  exception when check_violation then null;
  end;
  begin
    update public.activity_gait_windows_days set windows = jsonb_set(windows, '{format}', '"mh-col-1"'::jsonb)
      where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
    assert false, 'windows in another format must violate the CHECK';
  exception when check_violation then null;
  end;
  begin
    update public.activity_gait_windows_days set windows = '{}'::jsonb
      where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
    assert false, 'an empty windows object must violate the CHECK';
  exception when check_violation then null;
  end;
  update public.activity_gait_windows_days set windows = null
    where user_id=u and device_id=dev and day=v_day and mode='shadow' and model_version='eldernet-437a38b';
  assert found, 'omitted windows (null) stay allowed';
  raise notice 'PASS 4 upsert, coexisting modes and versions, verbatim comparison, windows format CHECK';
end;
$$;

-- 4b. Retention: rows computed more than p_keep_days ago go, newer rows stay, batches are bounded, and nonsense
-- arguments are refused.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  dev uuid := 'c0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-07';
  j record; n integer; total integer;
begin
  perform pg_temp.gw_enqueue(u, dev, v_day, '5');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.gw_payload(v_day)) is not null,
    'a row to prune';
  select count(*) into total from public.activity_gait_windows_days;
  n := public.prune_activity_gait_windows_days(30, 10000);
  assert (select count(*) from public.activity_gait_windows_days) = total - n, 'the count deleted is returned';
  assert exists(select 1 from public.activity_gait_windows_days where user_id=u and device_id=dev and day=v_day),
    'a fresh row is kept';
  update public.activity_gait_windows_days set computed_at = clock_timestamp() - interval '31 days'
    where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07');
  assert (select count(*) from public.activity_gait_windows_days
          where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07')) = 4, 'four aged rows';
  n := public.prune_activity_gait_windows_days(30, 2);
  assert n = 2, 'at most p_max_rows per call';
  n := public.prune_activity_gait_windows_days(30, 10000);
  assert n >= 2, 'the rest go on the next call';
  assert not exists(select 1 from public.activity_gait_windows_days
                    where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07')), 'aged rows are gone';
  assert exists(select 1 from public.activity_gait_windows_days where user_id=u and device_id=dev and day='2026-11-04'),
    'rows inside the window stay';
  begin
    perform public.prune_activity_gait_windows_days(0, 10);
    assert false, 'keep_days 0 must be refused';
  exception when others then assert sqlerrm = 'invalid_gait_windows_retention', sqlerrm;
  end;
  begin
    perform public.prune_activity_gait_windows_days(30, 0);
    assert false, 'max_rows 0 must be refused';
  exception when others then assert sqlerrm = 'invalid_gait_windows_retention', sqlerrm;
  end;
  assert not has_function_privilege('anon', 'public.prune_activity_gait_windows_days(integer,integer)', 'execute'),
    'anon cannot prune';
  assert not has_function_privilege('authenticated', 'public.prune_activity_gait_windows_days(integer,integer)', 'execute'),
    'authenticated cannot prune';
  assert has_function_privilege('service_role', 'public.prune_activity_gait_windows_days(integer,integer)', 'execute'),
    'the worker role can prune';
  raise notice 'PASS 4b retention';
end;
$$;

-- 5. Privileges: only the service role writes; owners read their own rows; clients cannot call the RPC.
do $$
declare
  u uuid := 'c0000000-0000-4000-8000-000000000001';
  other uuid := 'c0000000-0000-4000-8000-000000000002';
  n integer;
begin
  assert not has_function_privilege('anon', 'public.publish_activity_gait_windows_day(uuid,bigint,jsonb)', 'execute'),
    'anon cannot publish';
  assert not has_function_privilege('authenticated', 'public.publish_activity_gait_windows_day(uuid,bigint,jsonb)', 'execute'),
    'authenticated cannot publish';
  assert has_function_privilege('service_role', 'public.publish_activity_gait_windows_day(uuid,bigint,jsonb)', 'execute'),
    'the worker role can publish';
  assert not has_table_privilege('authenticated', 'public.activity_gait_windows_days', 'insert'), 'no client insert';
  assert not has_table_privilege('authenticated', 'public.activity_gait_windows_days', 'update'), 'no client update';
  assert not has_table_privilege('authenticated', 'public.activity_gait_windows_days', 'delete'), 'no client delete';
  assert not has_table_privilege('anon', 'public.activity_gait_windows_days', 'select'), 'no anonymous read';
  assert has_table_privilege('authenticated', 'public.activity_gait_windows_days', 'select'), 'owner read path';
  assert (select relrowsecurity from pg_class where oid = 'public.activity_gait_windows_days'::regclass), 'RLS on';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_gait_windows_days;
  assert n >= 1, 'the owner sees their rows';
  select count(*) into n from public.activity_gait_windows_days where user_id <> u;
  assert n = 0, 'and only theirs';
  reset role;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', other::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_gait_windows_days;
  assert n = 0, 'another user sees nothing';
  reset role;
  raise notice 'PASS 5 privileges';
end;
$$;

rollback;
