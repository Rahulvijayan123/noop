-- Run after every migration (supabase/tests/e2e/pipeline_db.sh up) against a TEST database. All fixtures roll back.
--   psql "$PIPELINE_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/functions/tests/phenotype_signatures.sql
-- 20261009100000_phenotype_signatures.sql: observation periods append like any other entry and are ignored by
-- the context builder, the activity-label projection, the background refresh and PR #5's detection command;
-- events carry onsetUncertaintyMinutes unchanged; unknown kinds stay refused; signature reports in
-- event_detector_runs are invisible to clients.
BEGIN;
CREATE TEMP TABLE k(name text PRIMARY KEY, v text);
INSERT INTO k VALUES
  ('u1', '11111111-1111-4111-8111-111111111111'), ('u2', '22222222-2222-4222-8222-222222222222'),
  ('s1', '33333333-3333-4333-8333-333333333333'), ('s2', '44444444-4444-4444-8444-444444444444'),
  ('type', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('ev', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('obs', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'), ('obs2', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  ('S', '1791000000');
GRANT SELECT ON k TO service_role, authenticated, anon;
CREATE TEMP TABLE result(name text PRIMARY KEY, v jsonb);
GRANT SELECT, INSERT, UPDATE ON result TO service_role, authenticated;
CREATE FUNCTION pg_temp.k(text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT v FROM k WHERE name = $1 $$;
CREATE FUNCTION pg_temp.u(text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT v::uuid FROM k WHERE name = $1 $$;
CREATE FUNCTION pg_temp.s() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT v::bigint FROM k WHERE name = 'S' $$;
CREATE FUNCTION pg_temp.rev(p_rev text, p_ms bigint, p_entry jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('revision_id', upper(p_rev), 'updated_at_ms', p_ms, 'entry', p_entry) $$;
-- An observation exactly as the app encodes it (ManualEventEntry, kind .observation).
CREATE FUNCTION pg_temp.observation(p_id uuid, p_start bigint, p_end bigint, p_extra jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('id', upper(p_id::text), 'kind', 'observation', 'label', 'Observation', 'symbol', 'eye',
    'favorite', false, 'startUnixSeconds', p_start, 'endUnixSeconds', p_end, 'timeZoneIdentifier', 'America/Los_Angeles',
    'archived', false, 'deviceId', 'my-whoop', 'note', 'Watched the whole afternoon') || p_extra $$;

INSERT INTO auth.users(id) SELECT pg_temp.u('u1') UNION ALL SELECT pg_temp.u('u2');
INSERT INTO public.compute_account_sources(source_id, user_id) VALUES (pg_temp.u('s1'), pg_temp.u('u1')), (pg_temp.u('s2'), pg_temp.u('u2'));

-- The kind check is the named one; the generated part-1 check is gone.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.manual_event_revisions'::regclass
                  AND conname = 'manual_event_revisions_kind_check' AND convalidated) THEN
    RAISE EXCEPTION 'kind check missing'; END IF;
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.manual_event_revisions'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%preset%') <> 1 THEN RAISE EXCEPTION 'old kind check still present'; END IF;
END $$;

SET LOCAL ROLE service_role;
-- A type, an event of it with an onset uncertainty, and an observation period that covers the event.
INSERT INTO result VALUES ('append', public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000001', 1791000000000, jsonb_build_object('id', upper(pg_temp.k('type')),
    'kind', 'event_type', 'label', 'Absence', 'symbol', 'brain.head.profile', 'favorite', true,
    'timeZoneIdentifier', 'UTC', 'archived', false, 'activityKind', 'other')),
  pg_temp.rev('10000000-0000-4000-8000-000000000002', 1791001300000, jsonb_build_object('id', upper(pg_temp.k('ev')),
    'kind', 'event', 'label', 'Absence', 'symbol', 'brain.head.profile', 'typeId', upper(pg_temp.k('type')), 'favorite', false,
    'startUnixSeconds', pg_temp.s(), 'endUnixSeconds', pg_temp.s() + 60, 'timeZoneIdentifier', 'America/Los_Angeles',
    'archived', false, 'deviceId', 'my-whoop', 'activityKind', 'other', 'onsetUncertaintyMinutes', 15)),
  pg_temp.rev('10000000-0000-4000-8000-000000000003', 1791001300001,
    pg_temp.observation(pg_temp.u('obs'), pg_temp.s() - 3600, pg_temp.s() + 3600)),
  pg_temp.rev('10000000-0000-4000-8000-000000000004', 1791001300002,
    pg_temp.observation(pg_temp.u('obs2'), pg_temp.s() + 86400, pg_temp.s() + 86400 + 7200)))));
DO $$
DECLARE r jsonb := (SELECT v FROM result WHERE name = 'append');
BEGIN
  IF jsonb_array_length(r -> 'saved') <> 4 OR jsonb_array_length(r -> 'rejected') <> 0 THEN
    RAISE EXCEPTION 'observation append wrong: %', r; END IF;
  IF (SELECT (body #>> '{entry,onsetUncertaintyMinutes}')::int FROM public.manual_event_revisions
       WHERE entity_id = pg_temp.u('ev')) <> 15 THEN RAISE EXCEPTION 'onset uncertainty not stored'; END IF;
  -- The projection ignores observations: no projection row, no ground-truth label.
  IF EXISTS (SELECT 1 FROM public.manual_event_projections WHERE entity_id IN (pg_temp.u('obs'), pg_temp.u('obs2')))
     OR EXISTS (SELECT 1 FROM public.activity_ground_truth_labels WHERE label_key LIKE '%' || pg_temp.k('obs') || '%')
    THEN RAISE EXCEPTION 'observation was projected'; END IF;
  IF (SELECT status || ':' || reason FROM public.manual_event_projections WHERE entity_id = pg_temp.u('ev'))
     <> 'skipped:no_activity_kind' THEN RAISE EXCEPTION 'event projection status wrong'; END IF;
END $$;

-- Contexts: an observation has none; the event's context does not list the observation as a concurrent event.
INSERT INTO result VALUES ('ctx', public.manual_event_contexts_v1(pg_temp.u('u1'), array[pg_temp.u('obs'), pg_temp.u('ev')]));
DO $$
DECLARE r jsonb := (SELECT v FROM result WHERE name = 'ctx');
BEGIN
  IF jsonb_array_length(r -> 'contexts') <> 1 OR r #>> '{contexts,0,event,id}' <> pg_temp.k('ev') THEN
    RAISE EXCEPTION 'observation got a context: %', r; END IF;
  IF jsonb_array_length(r #> '{contexts,0,concurrent_events}') <> 0 THEN
    RAISE EXCEPTION 'observation listed as a concurrent event: %', r #> '{contexts,0,concurrent_events}'; END IF;
  IF (r #>> '{contexts,0,history,previous_count}')::int <> 0 THEN RAISE EXCEPTION 'observation counted in history'; END IF;
  IF public.refresh_manual_event_contexts_v1(100) < 0 THEN RAISE EXCEPTION 'refresh failed'; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_event_contexts WHERE entity_id IN (pg_temp.u('obs'), pg_temp.u('obs2'))) THEN
    RAISE EXCEPTION 'refresh built an observation context'; END IF;
END $$;

-- Archive and restore an observation: two more revisions, still no projection or context.
SELECT public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
  pg_temp.rev('10000000-0000-4000-8000-000000000005', 1791002000000,
    pg_temp.observation(pg_temp.u('obs2'), pg_temp.s() + 86400, pg_temp.s() + 86400 + 7200,
                        '{"archived":true,"archivedAt":1791002000}')),
  pg_temp.rev('10000000-0000-4000-8000-000000000006', 1791002000001,
    pg_temp.observation(pg_temp.u('obs2'), pg_temp.s() + 86400, pg_temp.s() + 86400 + 7200))));
DO $$ BEGIN
  IF (SELECT count(*) FROM public.manual_event_revisions WHERE entity_id = pg_temp.u('obs2')) <> 3 THEN
    RAISE EXCEPTION 'observation history wrong'; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_event_projections WHERE entity_id = pg_temp.u('obs2')) THEN
    RAISE EXCEPTION 'archived observation projected'; END IF;
  -- An unknown kind is still refused by the append backstop.
  BEGIN
    PERFORM public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), jsonb_build_array(
      pg_temp.rev('10000000-0000-4000-8000-000000000007', 1791002000002,
        pg_temp.observation(gen_random_uuid(), pg_temp.s(), pg_temp.s() + 60, '{"kind":"diagnosis"}'))));
    RAISE EXCEPTION 'unknown kind accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'invalid_manual_event' THEN RAISE; END IF;
  END;
END $$;

-- PR #5 is unaffected: the detection command finds the type, and manual_events_current keeps the kind.
INSERT INTO result VALUES ('setting', public.event_detection_command(pg_temp.u('u1'), pg_temp.u('s1'),
  jsonb_build_object('action', 'setting', 'requestId', '90000000-0000-4000-8000-000000000001',
                     'typeId', pg_temp.k('type'), 'enabled', true)));
DO $$ BEGIN
  IF (SELECT v ->> 'saved' FROM result WHERE name = 'setting') <> '90000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'detection setting failed'; END IF;
  IF (SELECT entry ->> 'kind' FROM public.manual_events_current WHERE entity_id = pg_temp.u('obs')) <> 'observation' THEN
    RAISE EXCEPTION 'manual_events_current lost the kind'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.event_detector_settings WHERE user_id = pg_temp.u('u1')
                  AND type_id = pg_temp.u('type') AND enabled) THEN RAISE EXCEPTION 'setting not stored'; END IF;
END $$;
-- A signature report as the engine stores it, and one of another owner.
INSERT INTO public.event_detector_settings(user_id, type_id, enabled) VALUES (pg_temp.u('u2'), pg_temp.u('type'), true);
INSERT INTO public.event_detector_runs(user_id, type_id, id, snapshot, report) VALUES
  (pg_temp.u('u1'), pg_temp.u('type'), gen_random_uuid(), 'snap-1',
   jsonb_build_object('version', 'signature-report-1', 'type_id', pg_temp.k('type'), 'status', 'emerging')),
  (pg_temp.u('u2'), pg_temp.u('type'), gen_random_uuid(), 'snap-2',
   jsonb_build_object('version', 'signature-report-1', 'type_id', pg_temp.k('type'), 'status', 'established'));
DO $$ BEGIN
  IF (SELECT report ->> 'status' FROM public.event_detector_runs
       WHERE user_id = pg_temp.u('u1') AND type_id = pg_temp.u('type') AND report ->> 'version' = 'signature-report-1'
       ORDER BY created_at DESC, id DESC LIMIT 1) <> 'emerging' THEN RAISE EXCEPTION 'owner report not readable by the service'; END IF;
END $$;
RESET ROLE;

-- Clients: the runs table stays closed (the route reads it with the service role), the log stays owner-scoped.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.k('u1'), true);
DO $$ BEGIN
  BEGIN PERFORM count(*) FROM public.event_detector_runs; RAISE EXCEPTION 'client can read signature runs';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.append_manual_event_revisions(pg_temp.u('u1'), pg_temp.u('s1'), '[]'); RAISE EXCEPTION 'client can append';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  IF (SELECT count(*) FROM public.manual_event_revisions WHERE body #>> '{entry,kind}' = 'observation') <> 4 THEN
    RAISE EXCEPTION 'owner cannot read own observations'; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', pg_temp.k('u2'), true);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.manual_event_revisions) THEN RAISE EXCEPTION 'other owner sees observations'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN PERFORM count(*) FROM public.event_detector_runs; RAISE EXCEPTION 'anonymous can read signature runs';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- The table backstop refuses an unknown kind even from the owner role.
DO $$ BEGIN
  BEGIN
    INSERT INTO public.manual_event_revisions(user_id, source_id, revision_id, entity_id, updated_at_ms, body)
    VALUES (pg_temp.u('u1'), pg_temp.u('s1'), '10000000-0000-4000-8000-000000000008', pg_temp.u('obs'), 1791003000000,
      pg_temp.rev('10000000-0000-4000-8000-000000000008', 1791003000000,
        pg_temp.observation(pg_temp.u('obs'), pg_temp.s(), pg_temp.s() + 60, '{"kind":"diagnosis"}')));
    RAISE EXCEPTION 'table accepted an unknown kind';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
SELECT 'phenotype_signatures.sql: all checks passed' AS result;
ROLLBACK;
