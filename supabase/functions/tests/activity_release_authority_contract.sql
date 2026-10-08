-- Activity expert release authority DB contract (20261008100000_activity_release_authority.sql). Runs inside the
-- isolated, fully migrated test database (activity_authority_sql_test.ts applies the whole chain, this migration
-- included). Every fixture change rolls back; no deployed credentials or data are touched.
--
-- Proves: expert rows carry the release they were produced under, never above their recorded mode (an old row
-- without an authority block reads as its mode; a block can only lower it; a stand-in or shadow-tier bundle is
-- shadow whatever the mode; a direct write cannot raise it); the joint candidate table's fenced publish (stale
-- token, expired lease, wrong revision: NULL and nothing written; the job stays claimed; nothing published), its
-- payload rules, its upsert, its retention, and that no client role can read or write it.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values ('d0000000-0000-4000-8000-000000000001');
insert into public.devices(id,user_id,source_kind) values
 ('d0000000-0000-4000-8000-000000000011','d0000000-0000-4000-8000-000000000001','noop_push');

create function pg_temp.ra_enqueue(p_day date, p_digit text) returns void language plpgsql as $$
declare fp text; lo bigint := extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint;
begin
  fp := public.activity_context_fingerprint(array[repeat(p_digit,64)],lo,lo+86399,'hart-activity-1',
    'hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context('d0000000-0000-4000-8000-000000000001',
    'd0000000-0000-4000-8000-000000000011',p_day,array[gen_random_uuid()],array[repeat(p_digit,64)],fp);
end $$;

-- ElderNet gait payload (the gait contract's shape), with an optional authority block in the summary.
create function pg_temp.ra_gait(p_day date, p_mode text, p_authority jsonb default null) returns jsonb
language sql as $$
  with w as (select jsonb_object_agg(h, repeat('a', 64)) as weights
             from unnest(array['gait_detection','gait_speed','gait_length','cadence','regularity','step_count']) as h)
  select jsonb_build_object(
    'day', p_day::text, 'mode', p_mode, 'schema', 'gait-quality-1',
    'model', jsonb_build_object('model_id', 'eldernet', 'model_version', 'eldernet-437a38b', 'weights', w.weights,
      'upstream_commit', '437a38bcc69f42717fe73c1f7dbea7e1f7a50d23', 'preprocessing_version', 'eldernet-prep-1',
      'window_s', 10, 'hop_s', 5, 'gait_threshold', 0.5),
    'weights_digest', (select encode(sha256(convert_to('eldernet-weights-1' || chr(10)
       || string_agg(key || '=' || (value #>> '{}') || chr(10), '' order by key collate "C"), 'UTF8')), 'hex')
       from jsonb_each(w.weights)),
    'summary', jsonb_build_object('n_windows', 0, 'n_gait', 0, 'n_prefiltered', 0, 'n_dropped_nonfinite', 0,
                                  'n_chunks', 1, 'n_failed_chunks', 0, 'failure_kinds', '{}'::jsonb)
               || case when p_authority is null then '{}'::jsonb else jsonb_build_object('authority', p_authority) end,
    'windows', null,
    'withheld_reason', case when p_mode = 'candidate' then 'model_not_pinned' end,
    'candidate_document', null)
  from w
$$;

-- Motion-heads payload (the motion contract's shape).
create function pg_temp.ra_motion(p_day date, p_mode text, p_kind text, p_tier text,
                                  p_authority jsonb default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'day', p_day::text, 'mode', p_mode, 'schema', 'motion-heads-1',
    'bundle', jsonb_build_object(
      'encoder_id', case when p_kind='inertia1' then 'inertia-1/ar_transformer-small/30s@20hz'
                         else 'standin:inertia-arch-random-init/ar_transformer-tiny/seed0' end,
      'encoder_kind', p_kind, 'encoder_version', 'ar_transformer-tiny+cfg.610c1b2301a5',
      'checkpoint_sha256', case when p_kind in ('inertia1','actinet') then repeat('c',64) else null end,
      'heads_version', 'fixture-heads-' || p_kind || '-' || p_tier, 'bundle_sha256', repeat('a',64),
      'preprocessing_version', 'inertia-prep-1', 'evidence_tier_max', p_tier, 'window_s', 30, 'hop_s', 5,
      'bundle', jsonb_build_object('heads', jsonb_build_object(), 'ood', jsonb_build_object('method','knn','threshold',1.2))),
    'summary', jsonb_build_object('n_windows', 0, 'n_ood', 0, 'n_dropped_nonfinite', 0,
                                  'n_chunks', 1, 'n_failed_chunks', 0, 'failure_kinds', '{}'::jsonb)
               || case when p_authority is null then '{}'::jsonb else jsonb_build_object('authority', p_authority) end,
    'windows', null,
    'withheld_reason', case when p_mode = 'candidate' then 'bundle_sha256_not_pinned' end,
    'candidate_document', null)
$$;

-- A joint candidate payload: two decisions, three arms, the joint document (or why it was withheld).
create function pg_temp.ra_candidate(p_day date, p_revision bigint, p_withheld text default null) returns jsonb
language sql as $$
  select jsonb_build_object(
    'day', p_day::text, 'schema', 'activity-candidate-1', 'policy', 'expert-authority-1',
    'selection_digest', repeat('d', 64), 'input_revision', p_revision,
    'decisions', jsonb_build_array(
      jsonb_build_object('channel', 'gait_quality', 'route', 'standalone', 'release_mode', 'candidate',
        'use', 'candidate', 'reason', null, 'identity', jsonb_build_object('weights_digest', repeat('e', 64)),
        'input_revision', p_revision, 'day', p_day::text, 'windows', 12),
      jsonb_build_object('channel', 'motion_heads', 'route', 'standalone', 'release_mode', 'shadow',
        'use', 'none', 'reason', 'encoder_kind_standin', 'identity', '{}'::jsonb,
        'input_revision', p_revision, 'day', p_day::text, 'windows', 8)),
    'arms', jsonb_build_object(
      'hart', jsonb_build_object('channels', '[]'::jsonb, 'stamps', '{}'::jsonb, 'document_sha256', repeat('1', 64),
        'summary', jsonb_build_object('segments', 3)),
      'hart+gait_quality', jsonb_build_object('channels', jsonb_build_array('gait_quality'),
        'stamps', jsonb_build_object('gait_quality', 'eldernet-437a38b'), 'document_sha256', repeat('2', 64),
        'summary', jsonb_build_object('segments', 3), 'comparison', jsonb_build_object('changed_s', 0)),
      'joint', jsonb_build_object('channels', jsonb_build_array('gait_quality'),
        'stamps', jsonb_build_object('gait_quality', 'eldernet-437a38b'), 'document_sha256', repeat('2', 64),
        'summary', jsonb_build_object('segments', 3), 'same_as', 'hart+gait_quality')),
    'joint_document', case when p_withheld is null then jsonb_build_object(
      'versions', jsonb_build_object('gait_quality', 'eldernet-437a38b'), 'runs', '[]'::jsonb) end,
    'withheld_reason', p_withheld)
$$;

create function pg_temp.ra_rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_candidate_day(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- 1. Expert rows: the release a row reads as.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-12-01';
  j record; r record;
  lowered jsonb := jsonb_build_object('policy', 'expert-authority-1', 'release_mode', 'shadow', 'use', 'none',
                                      'reason', 'model_not_pinned');
  claims jsonb := jsonb_build_object('policy', 'expert-authority-1', 'release_mode', 'production', 'use', 'canonical');
begin
  perform pg_temp.ra_enqueue(v_day, '1');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';

  -- An older worker's rows (no block): their recorded mode.
  perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.ra_gait(v_day, 'shadow'));
  perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, pg_temp.ra_gait(v_day, 'candidate'));
  select * into r from public.activity_gait_windows_days where user_id=u and day=v_day and mode='shadow';
  assert r.release_mode = 'shadow' and r.authority is null, 'old shadow row reads as shadow';
  select * into r from public.activity_gait_windows_days where user_id=u and day=v_day and mode='candidate';
  assert r.release_mode = 'candidate' and r.authority is null, 'old candidate row reads as its recorded mode';

  -- A block lowers the release and is copied out of the summary.
  perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision,
    pg_temp.ra_gait(v_day, 'candidate', lowered));
  select * into r from public.activity_gait_windows_days where user_id=u and day=v_day and mode='candidate';
  assert r.release_mode = 'shadow' and r.authority = lowered, 'a lowered block makes the candidate row shadow';
  -- A block can never raise a row above its mode.
  perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision,
    pg_temp.ra_gait(v_day, 'candidate', claims));
  select * into r from public.activity_gait_windows_days where user_id=u and day=v_day and mode='candidate';
  assert r.release_mode = 'candidate', 'a block claiming production stays at the row''s candidate mode';
  perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision,
    pg_temp.ra_gait(v_day, 'shadow', claims));
  select * into r from public.activity_gait_windows_days where user_id=u and day=v_day and mode='shadow';
  assert r.release_mode = 'shadow', 'a shadow row is shadow whatever its block says';
  -- A direct write is recomputed by the trigger, and the check refuses a release above the mode.
  update public.activity_gait_windows_days set release_mode = 'candidate' where user_id=u and day=v_day and mode='shadow';
  assert (select release_mode from public.activity_gait_windows_days where user_id=u and day=v_day and mode='shadow')
    = 'shadow', 'a direct write cannot raise the release';
  assert not exists(select 1 from public.activity_gait_windows_days where release_mode = 'production'),
    'no gait row is production';

  -- Motion heads: a stand-in, or a bundle evaluated only to the shadow tier, is shadow whatever the mode.
  perform public.publish_activity_motion_heads_day(j.lease_token, j.input_revision,
    pg_temp.ra_motion(v_day, 'candidate', 'standin', 'candidate'));
  perform public.publish_activity_motion_heads_day(j.lease_token, j.input_revision,
    pg_temp.ra_motion(v_day, 'candidate', 'inertia1', 'shadow'));
  perform public.publish_activity_motion_heads_day(j.lease_token, j.input_revision,
    pg_temp.ra_motion(v_day, 'candidate', 'inertia1', 'candidate'));
  perform public.publish_activity_motion_heads_day(j.lease_token, j.input_revision,
    pg_temp.ra_motion(v_day, 'candidate', 'actinet', 'production', lowered));
  assert (select release_mode from public.activity_motion_heads_days where user_id=u and day=v_day
          and bundle_id='fixture-heads-standin-candidate') = 'shadow', 'a stand-in is shadow';
  assert (select release_mode from public.activity_motion_heads_days where user_id=u and day=v_day
          and bundle_id='fixture-heads-inertia1-shadow') = 'shadow', 'a shadow-tier bundle is shadow';
  assert (select release_mode from public.activity_motion_heads_days where user_id=u and day=v_day
          and bundle_id='fixture-heads-inertia1-candidate') = 'candidate', 'a candidate-tier real encoder: candidate';
  assert (select release_mode = 'shadow' and authority = lowered from public.activity_motion_heads_days
          where user_id=u and day=v_day and bundle_id='fixture-heads-actinet-production'), 'a block lowers motion rows';
  assert not exists(select 1 from public.activity_motion_heads_days where release_mode = 'production'),
    'no motion row is production';
  raise notice 'PASS 1 expert release modes';
end;
$$;

-- 2. Joint candidate days: the fence, the payload rules, the upsert, and nothing else written.
do $$
declare
  u uuid := 'd0000000-0000-4000-8000-000000000001';
  dev uuid := 'd0000000-0000-4000-8000-000000000011';
  v_day date := '2026-12-02';
  j record; r record; rev bigint; rev2 bigint; p jsonb;
begin
  perform pg_temp.ra_enqueue(v_day, '2');
  select * into j from public.claim_activity_context_v2(300);
  assert j.day = v_day, 'test must have claimed its own job';
  p := pg_temp.ra_candidate(v_day, j.input_revision);

  assert public.publish_activity_candidate_day(gen_random_uuid(), j.input_revision, p) is null, 'unknown token: NULL';
  assert public.publish_activity_candidate_day(j.lease_token, j.input_revision + 1, p) is null, 'wrong revision: NULL';
  assert not exists(select 1 from public.activity_candidate_days where user_id=u and day=v_day),
    'a fenced call writes nothing';

  rev := public.publish_activity_candidate_day(j.lease_token, j.input_revision, p);
  assert rev is not null and rev >= 1, 'a valid payload returns a result revision';
  select * into r from public.activity_candidate_days where user_id=u and device_id=dev and day=v_day;
  assert r.candidate_schema = 'activity-candidate-1' and r.policy = 'expert-authority-1'
     and r.selection_digest = repeat('d', 64) and r.input_revision = j.input_revision
     and r.job_fingerprint = j.fingerprint and r.algorithm_version = 'hart-activity-1'
     and jsonb_array_length(r.decisions) = 2 and r.arms ? 'joint' and r.arms ? 'hart'
     and r.joint_document -> 'versions' ->> 'gait_quality' = 'eldernet-437a38b' and r.withheld_reason is null
     and r.result_revision = rev, 'the row records the selection, the arms and the joint document';
  assert (select lease_token = j.lease_token and completed_revision = 0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the candidate publish does not complete the job';
  assert not exists(select 1 from public.activity_context_days where user_id=u and day=v_day)
     and not exists(select 1 from public.activity_context_epochs where user_id=u and day=v_day)
     and not exists(select 1 from public.scoring_work_items where user_id=u and day=v_day),
    'the candidate publish never publishes and never dirties scoring';

  -- The same day again: one row, replaced, with a new revision; a withheld joint replaces a document.
  rev2 := public.publish_activity_candidate_day(j.lease_token, j.input_revision,
    pg_temp.ra_candidate(v_day, j.input_revision, 'joint_not_accepted'));
  assert rev2 > rev, 'a republish gets a newer revision';
  select * into r from public.activity_candidate_days where user_id=u and day=v_day;
  assert (select count(*) from public.activity_candidate_days where user_id=u and day=v_day) = 1
     and r.joint_document is null and r.withheld_reason = 'joint_not_accepted', 'upserted in place';

  -- Payload rules.
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision, p || '{"day":"2026-12-03"}', 'invalid_candidate_day_payload'),
    'another day is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision, p || '{"schema":"x"}', 'invalid_candidate_day_schema'),
    'an unknown schema is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision,
    p || jsonb_build_object('input_revision', j.input_revision + 1), 'invalid_candidate_day_payload'),
    'a payload decoded from another revision is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision, p || '{"selection_digest":"abc"}',
    'invalid_candidate_day_payload'), 'a malformed digest is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision,
    p || '{"decisions":[{"channel":"gait_quality","release_mode":"released","use":"none"}]}',
    'invalid_candidate_day_decisions'), 'an unknown release is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision,
    p || '{"arms":{"hart":{"channels":[],"document_sha256":"x","summary":{}}}}', 'invalid_candidate_day_arms'),
    'an arm without a document digest is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision, p || '{"withheld_reason":"both"}',
    'invalid_candidate_day_joint'), 'a joint document and a withheld reason together are refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision,
    p || '{"joint_document":{"versions":{},"runs":[]}}', 'invalid_candidate_day_joint'),
    'a joint document no expert shaped is refused';
  assert pg_temp.ra_rejects(j.lease_token, j.input_revision, p || '{"joint_document":null}',
    'invalid_candidate_day_joint'), 'neither a joint document nor a reason is refused';
  assert (select result_revision from public.activity_candidate_days where user_id=u and day=v_day) = rev2,
    'a rejected payload changes nothing';

  -- An expired lease is fenced too.
  update public.activity_context_jobs set lease_until = clock_timestamp() - interval '1 second'
    where user_id=u and device_id=dev and day=v_day;
  assert public.publish_activity_candidate_day(j.lease_token, j.input_revision, p) is null, 'expired lease: NULL';
  raise notice 'PASS 2 candidate publish fence and payload';
end;
$$;

-- 3. Retention.
do $$
declare n integer;
begin
  update public.activity_candidate_days set computed_at = clock_timestamp() - interval '40 days'
    where user_id = 'd0000000-0000-4000-8000-000000000001';
  n := public.prune_activity_candidate_days(30, 10000);
  assert n >= 1, 'old rows are pruned';
  assert not exists(select 1 from public.activity_candidate_days where user_id='d0000000-0000-4000-8000-000000000001'),
    'nothing old is left';
  begin
    perform public.prune_activity_candidate_days(0, 10);
    assert false, 'an invalid retention must raise';
  exception when others then
    assert sqlerrm = 'invalid_candidate_day_retention', 'stable retention error';
  end;
  raise notice 'PASS 3 retention';
end;
$$;

-- 4. Privileges: service role only; no client role reads the candidate table or calls its functions.
do $$
begin
  assert (select relrowsecurity from pg_class where oid = 'public.activity_candidate_days'::regclass), 'RLS on';
  assert not has_table_privilege('authenticated', 'public.activity_candidate_days', 'select'), 'no owner read';
  assert not has_table_privilege('anon', 'public.activity_candidate_days', 'select'), 'no anon read';
  assert has_table_privilege('service_role', 'public.activity_candidate_days', 'select'), 'service role reads';
  assert not has_function_privilege('authenticated', 'public.publish_activity_candidate_day(uuid,bigint,jsonb)', 'execute'),
    'no client publish';
  assert not has_function_privilege('anon', 'public.prune_activity_candidate_days(integer,integer)', 'execute'),
    'no client prune';
  assert has_function_privilege('service_role', 'public.publish_activity_candidate_day(uuid,bigint,jsonb)', 'execute'),
    'the worker publishes';
  assert not has_function_privilege('authenticated', 'internal.activity_expert_release(text,jsonb)', 'execute'),
    'the internal helper is not client-callable';
  raise notice 'PASS 4 privileges';
end;
$$;

rollback;
