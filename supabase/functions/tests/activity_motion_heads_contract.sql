-- Inertia-1 motion heads DB contract (20261005170000_activity_motion_heads.sql). Runs inside the isolated,
-- fully migrated test database with the activity migrations (20261003120000_activity_context.sql,
-- 20261003130000_activity_context_days.sql, …) and 20261005170000_activity_motion_heads.sql applied. Every
-- fixture change rolls back; no deployed credentials or data are touched.
--
-- Run against a disposable cluster the way the other *.sql tests run:
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261005170000_activity_motion_heads.sql \
--        -f activity_motion_heads_contract.sql
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values
 ('b0000000-0000-4000-8000-000000000001'),
 ('b0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('b0000000-0000-4000-8000-000000000011','b0000000-0000-4000-8000-000000000001','noop_push'),
 ('b0000000-0000-4000-8000-000000000012','b0000000-0000-4000-8000-000000000002','noop_push');

create function pg_temp.mh_bundle(p_kind text default 'standin', p_tier text default 'shadow') returns jsonb
language sql as $$
  select jsonb_build_object(
    'encoder_id', case when p_kind='inertia1' then 'inertia-1/ar_transformer-small/30s@20hz'
                       else 'standin:inertia-arch-random-init/ar_transformer-tiny/seed0' end,
    'encoder_kind', p_kind, 'encoder_version', 'ar_transformer-tiny+cfg.610c1b2301a5',
    'checkpoint_sha256', case when p_kind='inertia1' then repeat('c',64) else null end,
    'heads_version', 'fixture-heads-tiny-art-seed0', 'bundle_sha256', repeat('a',64),
    'preprocessing_version', 'inertia-prep-1', 'evidence_tier_max', p_tier, 'window_s', 30, 'hop_s', 5,
    'bundle', jsonb_build_object('heads', jsonb_build_object(), 'ood', jsonb_build_object('method','knn','threshold',1.2)))
$$;
-- Columnar windows (mh-col-1), what the worker writes: per head top-class index + percent, OOD flag, deltas.
create function pg_temp.mh_col(p_n integer, p_value integer) returns jsonb language sql as $$
  select coalesce(jsonb_agg(p_value order by i), '[]'::jsonb) from generate_series(0, p_n - 1) as g(i)
$$;
create function pg_temp.mh_windows(p_day date, p_n integer) returns jsonb language sql as $$
  select jsonb_build_object(
    'format', 'mh-col-1', 'n', p_n, 'w', 30,
    's0', case when p_n > 0 then extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint end,
    'ds', coalesce((select jsonb_agg(case when i = 0 then 0 else 5 end order by i)
                    from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'x', coalesce((select jsonb_agg(case when i % 4 = 0 then 1 else 0 end order by i)
                   from generate_series(0, p_n - 1) as g(i)), '[]'::jsonb),
    'mi', pg_temp.mh_col(p_n, 20),
    'heads', jsonb_build_object(
      'posture', jsonb_build_object('i', pg_temp.mh_col(p_n, 1), 'p', pg_temp.mh_col(p_n, 60)),
      'locomotion', jsonb_build_object('i', pg_temp.mh_col(p_n, 0), 'p', pg_temp.mh_col(p_n, 80))))
$$;
create function pg_temp.mh_payload(p_day date, p_mode text default 'shadow', p_n integer default 8,
                                   p_bundle jsonb default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'day', p_day::text, 'mode', p_mode, 'schema', 'motion-heads-1',
    'bundle', coalesce(p_bundle, pg_temp.mh_bundle()),
    'summary', jsonb_build_object('n_windows', p_n, 'n_ood', (p_n + 3) / 4, 'n_dropped_nonfinite', 0,
                                  'n_chunks', 1, 'n_failed_chunks', 0, 'failure_kinds', '{}'::jsonb),
    'windows', pg_temp.mh_windows(p_day, p_n),
    'withheld_reason', case when p_mode = 'candidate' then 'encoder_kind_standin' end,
    'candidate_document', null)
$$;
create function pg_temp.mh_enqueue(p_user uuid, p_dev uuid, p_day date, p_digit text) returns void
language plpgsql as $$
declare fp text; lo bigint := extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat(p_digit,64)],lo,lo+86399,'hart-activity-1',
    'hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(p_user,p_dev,p_day,array[gen_random_uuid()],array[repeat(p_digit,64)],fp);
end $$;
create function pg_temp.mh_rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_motion_heads_day(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 1. Fenced publish stores the shadow row; the job stays claimed and nothing else is written.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-02';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  j record; rev bigint; r record; v1rev bigint;
begin
  perform pg_temp.mh_enqueue(u, dev, v_day, '1');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert j.day = v_day, 'test must have claimed its own job';
  rev := public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day));
  assert rev is not null and rev >= 1, 'a valid payload must return a result revision';
  select * into r from public.activity_motion_heads_days where user_id=u and device_id=dev and day=v_day;
  assert found, 'the shadow row must exist';
  assert r.bundle_id='fixture-heads-tiny-art-seed0' and r.mode='shadow' and r.encoder_kind='standin'
     and r.checkpoint_sha256 is null and r.bundle_sha256=repeat('a',64) and r.heads_schema='motion-heads-1'
     and r.evidence_tier_max='shadow' and r.preprocessing_version='inertia-prep-1', 'provenance must be denormalized';
  assert r.window_s=30 and r.hop_s=5 and r.n_windows=8 and r.n_ood=2 and r.n_dropped=0, 'counts must be mirrored';
  assert r.job_fingerprint=j.fingerprint and r.input_revision=j.input_revision
     and r.algorithm_version='hart-activity-1', 'row must record the job lineage';
  assert (r.windows->>'n')::integer=8 and jsonb_array_length(r.windows->'ds')=8 and r.windows->>'format'='mh-col-1'
     and r.candidate_document is null and r.withheld_reason is null,
    'columnar windows stored, no candidate in shadow mode';
  assert r.result_revision=rev and r.computed_at is not null and r.created_at is not null, 'revision and stamps';
  assert (select lease_token=j.lease_token and completed_revision=0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the shadow publish must not complete the job';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'the shadow publish never writes a day document';
  assert not exists(select 1 from public.activity_context_epochs where user_id=u and device_id=dev and day=v_day),
    'the shadow publish never writes epochs';
  assert not exists(select 1 from public.scoring_work_items where user_id=u and device_id=dev and day=v_day),
    'the shadow publish alone must not dirty scoring';
  -- The v1 publish in the same transaction still completes the job.
  v1rev := public.publish_activity_context_v2(j.lease_token, j.input_revision,
    jsonb_build_object('day',v_day::text,'epochs',jsonb_build_array(
      jsonb_build_object('s',lo,'e',lo+30,'m','stationary','p','sitting','ex','false','sl','awake',
        'ec','resting_candidate','w','on_wrist','c',0.9,'os',30,'vs',30))),100);
  assert v1rev is not null, 'the v1 publish must still succeed after the shadow publish';
  assert (select completed_revision=j.input_revision and lease_token is null from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'only the v1 publish completes the job';
  -- After completion the lease is gone, so the shadow RPC is fenced out.
  assert public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day)) is null,
    'a completed job fences the shadow publish';
  raise notice 'PASS 1 shadow row stored beside an unchanged v1 completion';
end;
$$;

-- 2. Fence: stale revision, unknown token and expired lease return NULL and write nothing; the fence comes
-- before validation.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-03';
  j record;
begin
  perform pg_temp.mh_enqueue(u, dev, v_day, '2');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert public.publish_activity_motion_heads_day(j.lease_token, j.input_revision+1, pg_temp.mh_payload(v_day)) is null,
    'stale revision must publish NULL';
  assert public.publish_activity_motion_heads_day(gen_random_uuid(), j.input_revision, pg_temp.mh_payload(v_day)) is null,
    'unknown token must publish NULL';
  update public.activity_context_jobs set lease_until=clock_timestamp()-interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  assert public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day)) is null,
    'expired lease must publish NULL';
  assert public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, '[]'::jsonb) is null,
    'fence must be evaluated before payload validation';
  assert not exists(select 1 from public.activity_motion_heads_days where user_id=u and device_id=dev and day=v_day),
    'a fenced-out publish must not write a row';
  raise notice 'PASS 2 fence';
end;
$$;

-- 3. Payload contract: every malformed payload is rejected with a stable message and writes nothing.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-04';
  j record; tok uuid; rev bigint; p jsonb; doc jsonb;
begin
  perform pg_temp.mh_enqueue(u, dev, v_day, '3');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  tok := j.lease_token; rev := j.input_revision; p := pg_temp.mh_payload(v_day);
  -- Envelope.
  assert pg_temp.mh_rejects(tok,rev,'[]'::jsonb,'invalid_motion_heads_payload'), 'non-object payload';
  assert pg_temp.mh_rejects(tok,rev,pg_temp.mh_payload('2026-11-05'),'invalid_motion_heads_payload'), 'another day';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{day}','"garbage"'),'invalid_motion_heads_payload'), 'unparseable day';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{schema}','"motion-heads-2"'),'invalid_motion_heads_schema'), 'schema';
  assert pg_temp.mh_rejects(tok,rev,p - 'schema','invalid_motion_heads_schema'), 'missing schema';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{mode}','"production"'),'invalid_motion_heads_payload'), 'mode';
  assert pg_temp.mh_rejects(tok,rev,p || jsonb_build_object('pad', repeat('x', 17000000)),'invalid_motion_heads_size'),
    'oversized payload';
  -- Bundle provenance.
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,bundle_sha256}','"abc"'),'invalid_motion_heads_bundle'), 'sha';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,encoder_kind}','"inertia2"'),'invalid_motion_heads_bundle'), 'kind';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,encoder_kind}','"inertia1"'),'invalid_motion_heads_bundle'),
    'an inertia1 claim needs its checkpoint digest';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,checkpoint_sha256}','"xyz"'),'invalid_motion_heads_bundle'), 'checkpoint';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,evidence_tier_max}','"gold"'),'invalid_motion_heads_bundle'), 'tier';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,hop_s}','7'),'invalid_motion_heads_bundle'), 'hop';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,hop_s}','"5"'),'invalid_motion_heads_bundle'), 'hop type';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(jsonb_set(p,'{bundle,window_s}','10'),'{bundle,hop_s}','15'),
    'invalid_motion_heads_bundle'), 'hop longer than the window';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{bundle,heads_version}','"bad id with spaces"'),'invalid_motion_heads_bundle'), 'bundle id';
  -- Summary and windows.
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{summary,n_ood}','9'),'invalid_motion_heads_summary'), 'n_ood > n_windows';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{summary,n_windows}','-1'),'invalid_motion_heads_summary'), 'negative count';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{summary,n_windows}','7'),'invalid_motion_heads_windows'), 'count mismatch';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows}','{}'),'invalid_motion_heads_windows'), 'windows format';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows}','[]'),'invalid_motion_heads_windows'),
    'the old per-window array form is refused';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,format}','"mh-col-2"'),'invalid_motion_heads_windows'), 'format';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,ds}','[0,5]'),'invalid_motion_heads_windows'), 'short column';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,heads,posture,p}','[1]'),'invalid_motion_heads_windows'),
    'short head column';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,heads,gait}',
    jsonb_build_object('i', pg_temp.mh_col(8, 0), 'p', pg_temp.mh_col(8, 0))),'invalid_motion_heads_windows'), 'unknown head';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,w}','10'),'invalid_motion_heads_windows'),
    'the window length must be the bundle''s';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{windows,mi}',
    to_jsonb(repeat('x', 1100000))),'invalid_motion_heads_windows'), 'windows over 1 MiB';
  -- Candidate rules.
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{withheld_reason}','"x"'),'invalid_motion_heads_candidate'),
    'a shadow row never carries a withheld reason';
  doc := jsonb_build_object('versions', jsonb_build_object('motion_heads','inertia-1:aaaaaaaaaaaa:01234567'),
                            'runs', '[]'::jsonb);
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(p,'{candidate_document}',doc),'invalid_motion_heads_candidate'),
    'a shadow row never carries a candidate document';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(pg_temp.mh_payload(v_day,'candidate'),'{withheld_reason}','null'),
    'invalid_motion_heads_candidate'), 'a candidate row carries a document or a withheld reason';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(pg_temp.mh_payload(v_day,'candidate'),'{candidate_document}',doc),
    'invalid_motion_heads_candidate'), 'not both';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(jsonb_set(pg_temp.mh_payload(v_day,'candidate'),'{withheld_reason}','null'),
    '{candidate_document}', jsonb_build_object('versions','{}'::jsonb,'runs','[]'::jsonb)),
    'invalid_motion_heads_candidate'), 'a comparison document must name the Inertia evidence';
  -- Only a real Inertia-1 candidate bundle may carry a comparison: never a stand-in, never a shadow-tier bundle.
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(jsonb_set(pg_temp.mh_payload(v_day,'candidate'),'{withheld_reason}','null'),
    '{candidate_document}', doc), 'invalid_motion_heads_candidate'), 'a stand-in comparison document';
  assert pg_temp.mh_rejects(tok,rev,jsonb_set(jsonb_set(pg_temp.mh_payload(v_day,'candidate',8,
    pg_temp.mh_bundle('inertia1','shadow')),'{withheld_reason}','null'), '{candidate_document}', doc),
    'invalid_motion_heads_candidate'), 'a shadow-tier comparison document';
  assert not exists(select 1 from public.activity_motion_heads_days where user_id=u and device_id=dev and day=v_day),
    'no rejected payload may write a row';
  -- The live lease still accepts a good payload afterwards (each rejection rolled back only itself).
  assert public.publish_activity_motion_heads_day(tok, rev, p) is not null, 'a valid payload still publishes';
  raise notice 'PASS 3 payload contract';
end;
$$;

-- 4. Upsert per (day, bundle, mode): a republish replaces the row; shadow and candidate rows coexist; a
-- candidate comparison is stored verbatim.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-06';
  j record; r1 bigint; r2 bigint; r3 bigint; doc jsonb; cand jsonb;
begin
  perform pg_temp.mh_enqueue(u, dev, v_day, '4');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  r1 := public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day, 'shadow', 8));
  r2 := public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day, 'shadow', 4));
  assert r2 > r1, 'a republish gets a newer revision';
  assert (select count(*)=1 and min(n_windows)=4 from public.activity_motion_heads_days
    where user_id=u and device_id=dev and day=v_day and mode='shadow'), 'the republish replaced the row';
  doc := jsonb_build_object('schema_version',2,'versions',
    jsonb_build_object('motion_heads','inertia-1:aaaaaaaaaaaa:01234567','decoder','hsmm-1.3'),'runs','[]'::jsonb);
  cand := jsonb_set(jsonb_set(pg_temp.mh_payload(v_day, 'candidate', 4, pg_temp.mh_bundle('inertia1','candidate')),
    '{withheld_reason}','null'), '{candidate_document}', doc);
  r3 := public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, cand);
  assert r3 is not null, 'a candidate comparison publishes';
  assert (select count(*)=2 from public.activity_motion_heads_days where user_id=u and device_id=dev and day=v_day),
    'shadow and candidate rows coexist';
  assert (select candidate_document=doc and withheld_reason is null and encoder_kind='inertia1'
          and checkpoint_sha256=repeat('c',64) from public.activity_motion_heads_days
    where user_id=u and device_id=dev and day=v_day and mode='candidate'), 'the comparison is stored verbatim';
  assert not exists(select 1 from public.activity_context_days where user_id=u and device_id=dev and day=v_day),
    'the comparison never reaches activity_context_days';
  -- The table refuses a stand-in comparison even when something bypasses the RPC.
  begin
    update public.activity_motion_heads_days set encoder_kind='standin', checkpoint_sha256=null,
      encoder_id='standin:handcrafted-stats-v1'
      where user_id=u and device_id=dev and day=v_day and mode='candidate';
    assert false, 'a stand-in row with a comparison document must violate the CHECK';
  exception when check_violation then null;
  end;
  begin
    update public.activity_motion_heads_days set evidence_tier_max='shadow'
      where user_id=u and device_id=dev and day=v_day and mode='candidate';
    assert false, 'a shadow-tier row with a comparison document must violate the CHECK';
  exception when check_violation then null;
  end;
  raise notice 'PASS 4 upsert, coexisting modes, verbatim comparison, inertia1-only comparison';
end;
$$;

-- 4b. Retention: rows computed more than p_keep_days ago go, newer rows stay, batches are bounded, and
-- nonsense arguments are refused.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-11-07';
  j record; n integer; total integer;
begin
  perform pg_temp.mh_enqueue(u, dev, v_day, '5');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  assert public.publish_activity_motion_heads_day(j.lease_token, j.input_revision, pg_temp.mh_payload(v_day)) is not null,
    'a row to prune';
  select count(*) into total from public.activity_motion_heads_days;
  n := public.prune_activity_motion_heads_days(30, 10000);
  assert (select count(*) from public.activity_motion_heads_days) = total - n, 'the count deleted is returned';
  assert exists(select 1 from public.activity_motion_heads_days where user_id=u and device_id=dev and day=v_day),
    'a fresh row is kept';
  update public.activity_motion_heads_days set computed_at = clock_timestamp() - interval '31 days'
    where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07');
  assert (select count(*) from public.activity_motion_heads_days
          where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07')) = 3, 'three aged rows';
  n := public.prune_activity_motion_heads_days(30, 2);
  assert n = 2, 'at most p_max_rows per call';
  n := public.prune_activity_motion_heads_days(30, 10000);
  assert n >= 1, 'the rest go on the next call';
  assert not exists(select 1 from public.activity_motion_heads_days
                    where user_id=u and device_id=dev and day in ('2026-11-06', '2026-11-07')), 'aged rows are gone';
  assert exists(select 1 from public.activity_motion_heads_days where user_id=u and device_id=dev and day='2026-11-04'),
    'rows inside the window stay';
  begin
    perform public.prune_activity_motion_heads_days(0, 10);
    assert false, 'keep_days 0 must be refused';
  exception when others then assert sqlerrm = 'invalid_motion_heads_retention', sqlerrm;
  end;
  begin
    perform public.prune_activity_motion_heads_days(30, 0);
    assert false, 'max_rows 0 must be refused';
  exception when others then assert sqlerrm = 'invalid_motion_heads_retention', sqlerrm;
  end;
  assert not has_function_privilege('anon', 'public.prune_activity_motion_heads_days(integer,integer)', 'execute'),
    'anon cannot prune';
  assert not has_function_privilege('authenticated', 'public.prune_activity_motion_heads_days(integer,integer)', 'execute'),
    'authenticated cannot prune';
  assert has_function_privilege('service_role', 'public.prune_activity_motion_heads_days(integer,integer)', 'execute'),
    'the worker role can prune';
  raise notice 'PASS 4b retention';
end;
$$;

-- 5. Privileges: only the service role writes; owners read their own rows; clients cannot call the RPC.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  other uuid := 'b0000000-0000-4000-8000-000000000002';
  n integer;
begin
  assert not has_function_privilege('anon', 'public.publish_activity_motion_heads_day(uuid,bigint,jsonb)', 'execute'),
    'anon cannot publish';
  assert not has_function_privilege('authenticated', 'public.publish_activity_motion_heads_day(uuid,bigint,jsonb)', 'execute'),
    'authenticated cannot publish';
  assert has_function_privilege('service_role', 'public.publish_activity_motion_heads_day(uuid,bigint,jsonb)', 'execute'),
    'the worker role can publish';
  assert not has_table_privilege('authenticated', 'public.activity_motion_heads_days', 'insert'), 'no client insert';
  assert not has_table_privilege('authenticated', 'public.activity_motion_heads_days', 'update'), 'no client update';
  assert not has_table_privilege('anon', 'public.activity_motion_heads_days', 'select'), 'no anonymous read';
  assert has_table_privilege('authenticated', 'public.activity_motion_heads_days', 'select'), 'owner read path';
  assert (select relrowsecurity from pg_class where oid = 'public.activity_motion_heads_days'::regclass), 'RLS on';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_motion_heads_days;
  assert n >= 1, 'the owner sees their rows';
  select count(*) into n from public.activity_motion_heads_days where user_id <> u;
  assert n = 0, 'and only theirs';
  reset role;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', other::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.activity_motion_heads_days;
  assert n = 0, 'another user sees nothing';
  reset role;
  raise notice 'PASS 5 privileges';
end;
$$;

rollback;
