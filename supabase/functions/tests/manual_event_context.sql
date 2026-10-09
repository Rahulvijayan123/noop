-- Run after 20261008090000_manual_events.sql and 20261008100000_manual_event_context.sql against a TEST
-- database (supabase/tests/e2e/pipeline_db.sh). All fixtures roll back.
--   psql "$PIPELINE_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/functions/tests/manual_event_context.sql
-- A 20-minute walk at S with per-second heart rate, wrist motion, canonical series, the classifier's runs,
-- a frozen baseline, a baseline episode, a Watchdog candidate and a caffeine exposure an hour before it.
BEGIN;
CREATE TEMP TABLE k(name text PRIMARY KEY, v text);
INSERT INTO k VALUES
  ('u1', '11111111-1111-4111-8111-111111111111'), ('u2', '22222222-2222-4222-8222-222222222222'),
  ('s1', '33333333-3333-4333-8333-333333333333'), ('s2', '44444444-4444-4444-8444-444444444444'),
  ('d1', '55555555-5555-4555-8555-555555555555'), ('d2', '66666666-6666-4666-8666-666666666666'),
  ('type', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('walk', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('walk2', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'), ('point', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  ('dflt', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'), ('other', 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
  ('moved', '99999999-9999-4999-8999-999999999999'),
  ('S', '1791000000');
GRANT SELECT ON k TO service_role, authenticated, anon;
CREATE TEMP TABLE result(name text PRIMARY KEY, v jsonb);
GRANT SELECT, INSERT, UPDATE ON result TO service_role, authenticated;

CREATE FUNCTION pg_temp.k(text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT v FROM k WHERE name = $1 $$;
CREATE FUNCTION pg_temp.u(text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT v::uuid FROM k WHERE name = $1 $$;
CREATE FUNCTION pg_temp.s() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT v::bigint FROM k WHERE name = 'S' $$;
-- A revision exactly as the app encodes it: uppercase UUIDs, camelCase entry keys.
CREATE FUNCTION pg_temp.rev(p_rev text, p_ms bigint, p_entry jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('revision_id', upper(p_rev), 'updated_at_ms', p_ms, 'entry', p_entry) $$;
CREATE FUNCTION pg_temp.event(p_id uuid, p_type uuid, p_label text, p_start bigint, p_end bigint,
  p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('id', upper(p_id::text), 'kind', 'event', 'label', p_label, 'symbol', 'figure.walk',
    'typeId', upper(p_type::text), 'favorite', false, 'startUnixSeconds', p_start, 'timeZoneIdentifier', 'America/Los_Angeles',
    'archived', false, 'deviceId', 'my-whoop')
    || CASE WHEN p_end IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('endUnixSeconds', p_end) END || p_extra $$;

INSERT INTO auth.users(id) SELECT pg_temp.u('u1') UNION ALL SELECT pg_temp.u('u2');
INSERT INTO public.compute_account_sources(source_id, user_id) VALUES (pg_temp.u('s1'), pg_temp.u('u1')), (pg_temp.u('s2'), pg_temp.u('u2'));
INSERT INTO public.devices(id, user_id, source_kind, external_device_id) VALUES
  (pg_temp.u('d1'), pg_temp.u('u1'), 'noop_push', 'installation:' || pg_temp.k('s1') || ':my-whoop'),
  (pg_temp.u('d2'), pg_temp.u('u2'), 'noop_push', 'installation:' || pg_temp.k('s2') || ':my-whoop');

-- Heart rate: 60 bpm before, 110 during, 80 after (one sample a second, the strap's cadence).
INSERT INTO public.noop_hr_samples(user_id, device_id, source_id, ts, bpm, batch_id)
SELECT pg_temp.u('u1'), pg_temp.u('d1'), pg_temp.u('s1'), t,
       CASE WHEN t < pg_temp.s() THEN 60 WHEN t < pg_temp.s() + 1200 THEN 110 ELSE 80 END, gen_random_uuid()
  FROM generate_series(pg_temp.s() - 1800, pg_temp.s() + 1200 + 1799) t;
INSERT INTO public.noop_gravity_samples(user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
SELECT pg_temp.u('u1'), pg_temp.u('d1'), pg_temp.u('s1'), t, 0, 0, 1,
       CASE WHEN t >= pg_temp.s() AND t < pg_temp.s() + 1200 THEN 0.3 ELSE 0.02 END, gen_random_uuid()
  FROM generate_series(pg_temp.s() - 1800, pg_temp.s() + 2999, 10) t;
-- The strap's wrist events carry their code, as stored by the push projection.
INSERT INTO public.noop_events(user_id, device_id, source_id, ts, kind, "payloadJSON", batch_id) VALUES
  (pg_temp.u('u1'), pg_temp.u('d1'), pg_temp.u('s1'), pg_temp.s() + 1500, 'WRIST_OFF(10)', '{}', gen_random_uuid()),
  (pg_temp.u('u1'), pg_temp.u('d1'), pg_temp.u('s1'), pg_temp.s() + 1600, 'WRIST_ON(9)', '{}', gen_random_uuid());
-- Canonical series: resting HR 55 and HRV 50 over the previous week; HRV 30 and 100 steps a minute during the walk.
INSERT INTO public.server_metric_series(user_id, metric, bucket_start, bucket_seconds, value, sample_count, coverage, motion, device_id, algorithm_version)
SELECT pg_temp.u('u1'), m, to_timestamp(pg_temp.s() - d * 86400), 300, v, 300, 0.9, 0.1, pg_temp.u('d1'), 'test'
  FROM generate_series(1, 6) d, (VALUES ('resting_hr_bpm', 55.0), ('hrv_rmssd_ms', 50.0)) x(m, v);
INSERT INTO public.server_metric_series(user_id, metric, bucket_start, bucket_seconds, value, sample_count, coverage, motion, device_id, algorithm_version)
VALUES (pg_temp.u('u1'), 'hrv_rmssd_ms', to_timestamp(pg_temp.s()), 300, 30, 200, 0.7, 0.8, pg_temp.u('d1'), 'test');
INSERT INTO public.server_metric_series(user_id, metric, bucket_start, bucket_seconds, value, sample_count, coverage, motion, device_id, algorithm_version)
SELECT pg_temp.u('u1'), 'steps', to_timestamp(pg_temp.s() + i * 60), 60, 100, 60, 1, 1, pg_temp.u('d1'), 'test'
  FROM generate_series(0, 19) i;
-- The classifier: sitting before, walking for 1000 s of the 1200 s walk, then standing.
INSERT INTO public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version, ontology_version,
  decoder_version, feature_schema, model_version, preprocessing_version, job_fingerprint, input_revision,
  publish_interval_s, observed_s, run_count, event_count, unclear_s, mean_confidence, document, result_revision, computed_at)
VALUES (pg_temp.u('u1'), pg_temp.u('d1'), (to_timestamp(pg_temp.s()) AT TIME ZONE 'UTC')::date, 'hart-activity-1', 2, 'o1',
  'd1', 'f1', 'hart-test', 'p1', repeat('a', 64), 1, 60, 4800, 3, 0, 0, 0.8,
  jsonb_build_object('runs', jsonb_build_array(
    jsonb_build_object('s', pg_temp.s() - 1800, 'e', pg_temp.s(), 'activity_class', 'sitting', 'class_confidence', 0.8, 'sleep', 'awake', 'wear', 'on_wrist'),
    jsonb_build_object('s', pg_temp.s(), 'e', pg_temp.s() + 1000, 'activity_class', 'walking', 'class_confidence', 0.9, 'sleep', 'awake', 'wear', 'on_wrist'),
    jsonb_build_object('s', pg_temp.s() + 1000, 'e', pg_temp.s() + 3000, 'activity_class', 'standing', 'class_confidence', 0.6, 'sleep', 'awake', 'wear', 'on_wrist'))),
  1, now());
INSERT INTO public.physiology_context_frozen_references(user_id, device_id, reference_id, series_key, regime_key, version,
  from_day, to_day, support_days, center, scale, transform, selection_rule, created_for_day, policy_fingerprint, context_revision, payload)
VALUES (pg_temp.u('u1'), pg_temp.u('d1'), 'ref-1', 'heart_rate.sleep_night', 'all', 1, '2026-09-01', '2026-09-28', 20, 52, 3.1,
  'identity', 'test', '2026-09-29', 'fp', 1, '{}');
INSERT INTO public.physiology_context_episodes(user_id, device_id, mode, episode_id, series_key, regime_key, state, direction,
  start_day, last_day, ongoing, duration_days, finality, as_of_day, context_revision, payload)
VALUES (pg_temp.u('u1'), pg_temp.u('d1'), 'retrospective', 'ep-1', 'hrv_rmssd.sleep_night', 'all', 'transient_deviation', -1,
  '2026-10-01', '2026-10-03', false, 2, 'final', '2026-10-04', 1, '{}');
INSERT INTO public.anomaly_candidates(user_id, device_id, candidate_key, start_ts, end_ts, local_day, channels, score, severity, direction)
VALUES (pg_temp.u('u1'), pg_temp.u('d1'), 'cand-1', to_timestamp(pg_temp.s() + 300), to_timestamp(pg_temp.s() + 900),
  '2026-10-02', array['hr'], 4.2, 'candidate', 1);
SELECT public.record_exposure_event_v1(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_object('event_id', 'coffee-1',
  'revision', 1, 'kind', 'caffeine', 'label', 'Coffee', 'occurred', jsonb_build_object('start', pg_temp.s() - 3600, 'end', pg_temp.s() - 3540),
  'time_precision', 'exact', 'recorded_at', pg_temp.s() - 3500, 'source', 'user_entered', 'confirmation', 'confirmed'));

-- ---------------------------------------------------------------------------------------------------------
SET LOCAL ROLE service_role;
-- A custom walking type and a walk logged with it; the reply is per item.
INSERT INTO result VALUES ('append1', public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000001', 1791000000000, jsonb_build_object('id', upper(pg_temp.k('type')),
    'kind', 'event_type', 'label', 'Morning walk', 'symbol', 'figure.walk', 'favorite', true,
    'timeZoneIdentifier', 'UTC', 'archived', false, 'activityKind', 'walking')),
  pg_temp.rev('10000000-0000-4000-8000-000000000002', 1791001300000,
    pg_temp.event(pg_temp.u('walk'), pg_temp.u('type'), 'Morning walk', pg_temp.s(), pg_temp.s() + 1200,
                  '{"activityKind":"walking","note":"Around the block"}')))));
DO $$ BEGIN
  IF jsonb_array_length((SELECT v FROM result WHERE name = 'append1') -> 'saved') <> 2
     OR jsonb_array_length((SELECT v FROM result WHERE name = 'append1') -> 'rejected') <> 0 THEN
    RAISE EXCEPTION 'append did not save both: %', (SELECT v FROM result WHERE name = 'append1'); END IF;
END $$;

-- The same revision UUID with different content is refused on its own; the rest of the batch is saved.
INSERT INTO result VALUES ('append2', public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000002', 1791001300000,
    pg_temp.event(pg_temp.u('walk'), pg_temp.u('type'), 'Changed label', pg_temp.s(), pg_temp.s() + 1200)),
  pg_temp.rev('10000000-0000-4000-8000-000000000003', 1791090000000,
    pg_temp.event(pg_temp.u('walk2'), pg_temp.u('type'), 'Morning walk', pg_temp.s() + 86400, pg_temp.s() + 86400 + 900,
                  '{"activityKind":"walking"}')),
  pg_temp.rev('10000000-0000-4000-8000-000000000004', 1791090000001,
    pg_temp.event(pg_temp.u('point'), pg_temp.u('other'), 'Headache', pg_temp.s() + 600, pg_temp.s() + 600)),
  -- The default Walking type's events inherit its kind through the fixed catalog UUID.
  pg_temp.rev('10000000-0000-4000-8000-000000000005', 1791090000002,
    pg_temp.event(pg_temp.u('dflt'), '00000000-0000-4000-8000-000000000002'::uuid, 'Walking', pg_temp.s() + 7200, pg_temp.s() + 7800)),
  -- An identical retry is saved again without a second row.
  pg_temp.rev('10000000-0000-4000-8000-000000000001', 1791000000000, jsonb_build_object('id', upper(pg_temp.k('type')),
    'kind', 'event_type', 'label', 'Morning walk', 'symbol', 'figure.walk', 'favorite', true,
    'timeZoneIdentifier', 'UTC', 'archived', false, 'activityKind', 'walking')))));
DO $$
DECLARE r jsonb := (SELECT v FROM result WHERE name = 'append2');
BEGIN
  IF jsonb_array_length(r -> 'saved') <> 4 OR jsonb_array_length(r -> 'rejected') <> 1
     OR lower(r #>> '{rejected,0,revision_id}') <> '10000000-0000-4000-8000-000000000002'
     OR r #>> '{rejected,0,reason}' <> 'revision_conflict' THEN RAISE EXCEPTION 'per-item results wrong: %', r; END IF;
  IF (SELECT count(*) FROM public.manual_event_revisions) <> 5 THEN RAISE EXCEPTION 'retry duplicated a row'; END IF;
  IF (SELECT body -> 'entry' ->> 'label' FROM public.manual_event_revisions
       WHERE revision_id = '10000000-0000-4000-8000-000000000002') <> 'Morning walk' THEN RAISE EXCEPTION 'conflict overwrote'; END IF;
  BEGIN
    PERFORM public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s2'), '[]');
    RAISE EXCEPTION 'source theft accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;

-- Projection into the activity ground truth: the walk (own kind) and the default-catalog walk (inherited kind).
DO $$
DECLARE g public.activity_ground_truth_labels;
BEGIN
  SELECT * INTO g FROM public.activity_ground_truth_labels WHERE label_key = 'manual_event:' || pg_temp.k('walk');
  IF NOT FOUND THEN RAISE EXCEPTION 'walk not projected'; END IF;
  IF g.source <> 'manual_event' OR g.locomotion <> 'walking' OR g.owner <> pg_temp.u('u1') OR g.device_id <> pg_temp.u('d1')
     OR g.start_ts <> pg_temp.s() OR g.end_ts <> pg_temp.s() + 1200 OR g.note <> 'Around the block' OR g.user_unsure
     OR g.tz_offset_s <> -25200 OR g.cue_context #>> '{manual_event,label}' <> 'Morning walk' THEN
    RAISE EXCEPTION 'projected label wrong: %', to_jsonb(g); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.activity_ground_truth_labels WHERE label_key = 'manual_event:' || pg_temp.k('dflt')
                  AND locomotion = 'walking') THEN RAISE EXCEPTION 'default catalog kind not inherited'; END IF;
  IF (SELECT status || ':' || reason FROM public.manual_event_projections WHERE entity_id = pg_temp.u('point'))
     <> 'skipped:no_activity_kind' THEN RAISE EXCEPTION 'point event projection status wrong'; END IF;
END $$;

-- Context of the walk: every signal aligned to its start and end.
INSERT INTO result VALUES ('ctx', public.manual_event_contexts_v1(pg_temp.u('u1'), array[pg_temp.u('walk')]) #> '{contexts,0}');
DO $$
DECLARE c jsonb := (SELECT v FROM result WHERE name = 'ctx');
BEGIN
  IF c ->> 'status' <> 'ready' OR NOT (c ->> 'final')::boolean THEN RAISE EXCEPTION 'status wrong: % %', c ->> 'status', c -> 'quality'; END IF;
  IF c #>> '{device,id}' <> pg_temp.k('d1') OR c #>> '{device,resolution}' <> 'entry' THEN RAISE EXCEPTION 'device wrong: %', c -> 'device'; END IF;
  IF (c #>> '{heart_rate,pre,mean}')::numeric <> 60 OR (c #>> '{heart_rate,during,mean}')::numeric <> 110
     OR (c #>> '{heart_rate,post,mean}')::numeric <> 80 OR (c #>> '{heart_rate,during,n}')::int <> 1200
     OR (c #>> '{heart_rate,during,coverage}')::numeric <> 1 THEN RAISE EXCEPTION 'heart rate wrong: %', c -> 'heart_rate'; END IF;
  IF jsonb_array_length(c #> '{heart_rate,trace,bins}') NOT BETWEEN 40 AND 241 THEN RAISE EXCEPTION 'trace wrong'; END IF;
  IF (c #>> '{motion,during,dyn_accel_mean}')::numeric <> 0.3 THEN RAISE EXCEPTION 'motion wrong: %', c -> 'motion'; END IF;
  IF (c #>> '{series,during,steps,value}')::numeric <> 2000 OR (c #>> '{series,during,hrv_rmssd_ms,value}')::numeric <> 30
     THEN RAISE EXCEPTION 'series wrong: %', c #> '{series,during}'; END IF;
  IF c #>> '{activity,during,classes,0,class}' <> 'walking' OR (c #>> '{activity,during,classes,0,seconds}')::int <> 1000
     OR (c #>> '{activity,during,classes,0,confidence}')::numeric <> 0.9
     OR c #>> '{activity,agreement,status}' <> 'agrees' OR (c #>> '{activity,agreement,matched_share}')::numeric <> 0.833
     OR c #>> '{activity,pre,classes,0,class}' <> 'sitting' THEN RAISE EXCEPTION 'activity wrong: %', c -> 'activity'; END IF;
  IF (c #>> '{baselines,resting_hr_7d,value}')::numeric <> 55 OR (c #>> '{baselines,hrv_rmssd_7d,value}')::numeric <> 50
     OR jsonb_array_length(c #> '{baselines,references}') <> 1 OR c #>> '{baselines,episodes,0,state}' <> 'transient_deviation'
     THEN RAISE EXCEPTION 'baselines wrong: %', c -> 'baselines'; END IF;
  IF (c #>> '{comparisons,hr_during_minus_pre_bpm}')::numeric <> 50 OR (c #>> '{comparisons,hr_during_minus_resting_7d_bpm}')::numeric <> 55
     OR (c #>> '{comparisons,hrv_during_minus_7d_ms}')::numeric <> -20 OR (c #>> '{comparisons,hr_post_minus_pre_bpm}')::numeric <> 20
     THEN RAISE EXCEPTION 'comparisons wrong: %', c -> 'comparisons'; END IF;
  IF c #> '{wear,events}' <> jsonb_build_array(jsonb_build_object('ts', pg_temp.s() + 1500, 'kind', 'WRIST_OFF'),
       jsonb_build_object('ts', pg_temp.s() + 1600, 'kind', 'WRIST_ON')) THEN RAISE EXCEPTION 'wear events wrong: %', c -> 'wear'; END IF;
  IF jsonb_array_length(c -> 'watchdog') <> 1 OR c #>> '{exposures,0,kind}' <> 'caffeine'
     OR (c #>> '{exposures,0,offset_s}')::int <> -3600 THEN RAISE EXCEPTION 'watchdog/exposures wrong'; END IF;
  IF c #>> '{projections,activity_ground_truth,status}' <> 'projected' OR (c #>> '{history,previous_count}')::int <> 0
     OR c #>> '{event,local_day}' <> '2026-10-02' OR jsonb_array_length(c -> 'concurrent_events') <> 1
     THEN RAISE EXCEPTION 'event/history/projection wrong: % % %', c -> 'event', c -> 'history', c -> 'concurrent_events'; END IF;
  -- A fresh context is served from the cache.
  IF (public.manual_event_contexts_v1(pg_temp.u('u1'), array[pg_temp.u('walk')]) #>> '{contexts,0,computed_at}') <> c ->> 'computed_at'
     THEN RAISE EXCEPTION 'cache not used'; END IF;
END $$;

-- A favorite toggle on the type, or an identical retry, leaves the projected label untouched.
INSERT INTO result VALUES ('gt_rev', (SELECT to_jsonb(revision) FROM public.activity_ground_truth_labels
  WHERE label_key = 'manual_event:' || pg_temp.k('walk')));
SELECT public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000010', 1791090000100, jsonb_build_object('id', upper(pg_temp.k('type')),
    'kind', 'event_type', 'label', 'Morning walk', 'symbol', 'figure.walk', 'favorite', false,
    'timeZoneIdentifier', 'UTC', 'archived', false, 'activityKind', 'walking')),
  pg_temp.rev('10000000-0000-4000-8000-000000000002', 1791001300000,
    pg_temp.event(pg_temp.u('walk'), pg_temp.u('type'), 'Morning walk', pg_temp.s(), pg_temp.s() + 1200,
                  '{"activityKind":"walking","note":"Around the block"}'))));
DO $$ BEGIN
  IF (SELECT to_jsonb(revision) FROM public.activity_ground_truth_labels WHERE label_key = 'manual_event:' || pg_temp.k('walk'))
     <> (SELECT v FROM result WHERE name = 'gt_rev') THEN RAISE EXCEPTION 'unchanged event re-wrote its label'; END IF;
END $$;
-- An event logged as this type and then moved to another no longer counts in this type's history.
SELECT public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000011', 1791090000200,
    pg_temp.event(pg_temp.u('moved'), pg_temp.u('type'), 'Morning walk', pg_temp.s() - 86400, pg_temp.s() - 86400 + 600)),
  pg_temp.rev('10000000-0000-4000-8000-000000000012', 1791090000300,
    pg_temp.event(pg_temp.u('moved'), pg_temp.u('other'), 'Headache', pg_temp.s() - 86400, pg_temp.s() - 86400 + 600))));

-- The second walk has no data: history carries the first walk's heart rate; there is nothing to measure.
INSERT INTO result VALUES ('ctx2', public.manual_event_contexts_v1(pg_temp.u('u1'), array[pg_temp.u('walk2'), pg_temp.u('point'), gen_random_uuid()]));
DO $$
DECLARE r jsonb := (SELECT v FROM result WHERE name = 'ctx2'); c jsonb; p jsonb;
BEGIN
  IF jsonb_array_length(r -> 'contexts') <> 2 THEN RAISE EXCEPTION 'unknown id not skipped: %', r; END IF;
  SELECT x INTO c FROM jsonb_array_elements(r -> 'contexts') x WHERE x #>> '{event,id}' = pg_temp.k('walk2');
  SELECT x INTO p FROM jsonb_array_elements(r -> 'contexts') x WHERE x #>> '{event,id}' = pg_temp.k('point');
  IF c ->> 'status' <> 'insufficient_data' OR (c #>> '{history,previous_count}')::int <> 1
     OR (c #>> '{history,typical_hr_during_mean}')::numeric <> 110 OR c #>> '{device,resolution}' <> 'entry'
     THEN RAISE EXCEPTION 'second walk wrong: % %', c ->> 'status', c -> 'history'; END IF;
  IF NOT (p #>> '{event,point}')::boolean OR p #> '{heart_rate,during}' <> 'null'::jsonb
     OR p #>> '{activity,agreement,status}' <> 'not_applicable' OR (p #>> '{heart_rate,pre,mean}')::numeric <> 76.7
     OR (p #>> '{heart_rate,pre,n}')::int <> 1800
     THEN RAISE EXCEPTION 'point event wrong: %', p; END IF;
END $$;

-- Archiving the walk removes its projected label; its history stays.
INSERT INTO result VALUES ('archive', public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000006', 1791100000000,
    pg_temp.event(pg_temp.u('walk'), pg_temp.u('type'), 'Morning walk', pg_temp.s(), pg_temp.s() + 1200,
                  '{"activityKind":"walking","note":"Around the block","archived":true,"archivedAt":1791100000}')))));
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.activity_ground_truth_labels WHERE label_key = 'manual_event:' || pg_temp.k('walk'))
    THEN RAISE EXCEPTION 'archived walk still a label'; END IF;
  IF (SELECT status || ':' || reason FROM public.manual_event_projections WHERE entity_id = pg_temp.u('walk')) <> 'removed:archived'
    THEN RAISE EXCEPTION 'removal not recorded'; END IF;
  IF (SELECT count(*) FROM public.manual_event_revisions WHERE entity_id = pg_temp.u('walk')) <> 2 THEN RAISE EXCEPTION 'history lost'; END IF;
  -- The cached context is rebuilt for the new revision.
  IF NOT (public.manual_event_contexts_v1(pg_temp.u('u1'), array[pg_temp.u('walk')]) #>> '{contexts,0,event,archived}')::boolean
    THEN RAISE EXCEPTION 'stale context served after a new revision'; END IF;
END $$;

-- Changing the default Walking type's kind re-projects the events that inherit it.
SELECT public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000007', 1791100000001, jsonb_build_object('id', '00000000-0000-4000-8000-000000000002',
    'kind', 'event_type', 'label', 'Walking', 'symbol', 'figure.walk', 'favorite', true, 'timeZoneIdentifier', 'UTC',
    'archived', false, 'activityKind', 'other'))));
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.activity_ground_truth_labels WHERE label_key = 'manual_event:' || pg_temp.k('dflt'))
    THEN RAISE EXCEPTION 'type change did not re-project its events'; END IF;
  IF public.refresh_manual_event_contexts_v1(10) < 0 THEN RAISE EXCEPTION 'refresh failed'; END IF;
  BEGIN DELETE FROM public.manual_event_contexts; RAISE EXCEPTION 'service can delete contexts';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
-- The second account's own walk, for the isolation and deletion checks below.
SELECT public.append_manual_event_revisions(pg_temp.u('u2'), pg_temp.u('s2'), jsonb_build_array(
  pg_temp.rev('20000000-0000-4000-8000-000000000001', 1791000000000,
    pg_temp.event(pg_temp.u('walk'), pg_temp.u('type'), 'Walk', pg_temp.s(), pg_temp.s() + 600, '{"activityKind":"walking"}'))));
SELECT public.manual_event_contexts_v1(pg_temp.u('u2'), array[pg_temp.u('walk')]);
RESET ROLE;

-- Clients: their own rows only, and no direct access to the builders.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.k('u1'), true);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.manual_event_contexts) < 4 OR EXISTS (SELECT 1 FROM public.manual_event_contexts
       WHERE user_id = pg_temp.u('u2')) THEN RAISE EXCEPTION 'context RLS wrong'; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_event_projections WHERE user_id = pg_temp.u('u2')) THEN RAISE EXCEPTION 'projection RLS wrong'; END IF;
  BEGIN PERFORM public.manual_event_contexts_v1(pg_temp.u('u2'), array[pg_temp.u('walk')]); RAISE EXCEPTION 'client can build contexts';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.project_manual_event_v1(pg_temp.u('u1'), pg_temp.u('walk')); RAISE EXCEPTION 'client can project';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN UPDATE public.manual_event_contexts SET final = false; RAISE EXCEPTION 'client can update contexts';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN PERFORM count(*) FROM public.manual_event_contexts; RAISE EXCEPTION 'anonymous can read contexts';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- Account deletion removes the auth user; the foreign keys take every manual-event row of that account.
DELETE FROM auth.users WHERE id = '22222222-2222-4222-8222-222222222222';
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.manual_event_revisions WHERE user_id = pg_temp.u('u2'))
     OR EXISTS (SELECT 1 FROM public.manual_event_contexts WHERE user_id = pg_temp.u('u2'))
     OR EXISTS (SELECT 1 FROM public.manual_event_projections WHERE user_id = pg_temp.u('u2'))
     OR EXISTS (SELECT 1 FROM public.activity_ground_truth_labels WHERE owner = pg_temp.u('u2'))
    THEN RAISE EXCEPTION 'account deletion left manual-event rows'; END IF;
  IF (SELECT count(*) FROM public.manual_event_revisions WHERE user_id = pg_temp.u('u1')) <> 10 THEN RAISE EXCEPTION 'other account touched'; END IF;
END $$;
SELECT 'manual_event_context.sql: all checks passed' AS result;
ROLLBACK;
