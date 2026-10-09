-- Regression for 20261009170000_user_workouts.sql (workout mode). Run ONLY against an isolated, disposable full-schema
-- database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything runs in one transaction that
-- is rolled back:
--
--   PGAPPNAME=user-workouts psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/user_workouts.sql
--
-- (supabase/functions/tests/user_workouts_sql_test.ts runs it the same way inside the pipeline container.)
--
-- Checks:
--   1. Upsert: new workouts are accepted; the same payload again writes nothing (idempotent, updated_at kept); an
--      older client_updated_at is skipped as stale; a newer one (stop, change of type, delete) replaces it.
--   2. Refusals: an unknown type, an end before the start, more than 50 workouts, a duplicate client id and another
--      owner's device are refused, and nothing is written.
--   3. One workout at a time: an open workout followed by a later open one is closed at its start (auto_ended).
--   4. Every change re-queues the local days it touches for the measurement-context builder.
--   5. The read: overlap, the type's attributes, the device's external id, deleted rows only when asked.
--   6. internal.logged_workouts_v1: workout-mode rows plus the manual sessions they do not hold, typed through the
--      catalogue; a running workout up to now, never past 4 h.
--   7. The measurement-context builder: a logged strength workout with a still arm is `session` from its first minute
--      (basis logged, the type per minute); once deleted, the same minutes are no session.
--   8. RLS and privileges: each owner reads only their own rows, the catalogue is readable, no client writes, anon
--      reads nothing, no client executes either function.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid() as ua, gen_random_uuid() as ub, gen_random_uuid() as da, gen_random_uuid() as db,
       gen_random_uuid() as src, gen_random_uuid() as bat \gset
select set_config('uw.ua', :'ua', true), set_config('uw.ub', :'ub', true), set_config('uw.da', :'da', true),
       set_config('uw.db', :'db', true), set_config('uw.src', :'src', true) \g /dev/null

do $$ begin
  assert current_setting('application_name') = 'user-workouts', 'disposable-database invocation required';
end $$;

insert into auth.users (id) values (:'ua'), (:'ub');
insert into public.profiles (id, timezone) values (:'ua', 'America/Los_Angeles') on conflict (id) do update
  set timezone = excluded.timezone;
delete from public.scoring_timezone_history where user_id = :'ua';
insert into public.scoring_timezone_history (user_id, effective_at, timezone_id, provenance)
values (:'ua', '-infinity', 'America/Los_Angeles', 'initial_profile');
insert into public.devices (id, user_id, source_kind, external_device_id)
values (:'da', :'ua', 'noop_push', 'whoop-UWTEST0001'), (:'db', :'ub', 'noop_push', 'whoop-UWTEST0002');

-- 2026-09-25 03:00Z (20:00 PDT on the 24th): a 45-minute strength session; c1 is the phone's id for it. c2: an
-- indoor walk started at 05:00Z.
create temp table uw_w (k text primary key, j jsonb);
insert into uw_w values
  ('c1', '{"client_id": "00000000-0000-4000-8000-0000000000c1", "type": "strength", "started_at": 1790305200,
           "ended_at": 1790307900, "source": "manual", "deleted": false, "client_updated_at": 1790307900}'),
  ('c2', '{"client_id": "00000000-0000-4000-8000-0000000000c2", "type": "indoor_walk", "started_at": 1790312400,
           "ended_at": null, "source": "manual", "deleted": false, "client_updated_at": 1790312400}');

-- 1. Upsert -------------------------------------------------------------------------------------------------------
do $$
declare
  u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid;
  s uuid := current_setting('uw.src')::uuid; c1 jsonb := (select j from uw_w where k = 'c1');
  r jsonb; t public.user_workouts; at timestamptz;
begin
  r := public.user_workouts_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(c1));
  assert r = '{"accepted": 1, "skipped_stale": 0, "closed": 0}', r::text;
  select * into t from public.user_workouts where user_id = u;
  assert t.workout_type = 'strength' and t.started_at = to_timestamp(1790305200)
     and t.ended_at = to_timestamp(1790307900) and t.source = 'manual' and t.deleted_at is null
     and t.local_device_id = 'my-whoop' and t.source_id = s and t.device_id = d
     and t.catalogue_version = 'workout-types-1', row_to_json(t)::text;
  at := t.updated_at;
  r := public.user_workouts_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(c1));
  assert r = '{"accepted": 1, "skipped_stale": 0, "closed": 0}', 'a replay is accepted ' || r::text;
  assert (select updated_at from public.user_workouts where user_id = u) = at, 'and writes nothing';
  r := public.user_workouts_upsert_v1(u, d, s, 'my-whoop',
         jsonb_build_array(c1 || '{"type": "yoga", "client_updated_at": 1790307000}'));
  assert r = '{"accepted": 0, "skipped_stale": 1, "closed": 0}', 'an older copy is skipped ' || r::text;
  assert (select workout_type from public.user_workouts where user_id = u) = 'strength';
  r := public.user_workouts_upsert_v1(u, d, s, 'my-whoop',
         jsonb_build_array(c1 || '{"type": "hiit", "client_updated_at": 1790308000}'));
  assert r ->> 'accepted' = '1' and (select workout_type from public.user_workouts where user_id = u) = 'hiit',
    'a newer copy (change of type) wins';
  r := public.user_workouts_upsert_v1(u, d, s, 'my-whoop',
         jsonb_build_array(c1 || '{"type": "strength", "client_updated_at": 1790308100}'));
  assert (select workout_type from public.user_workouts where user_id = u) = 'strength';
end $$;

-- 2. Refusals -----------------------------------------------------------------------------------------------------
do $$
declare
  u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid;
  dbb uuid := current_setting('uw.db')::uuid; s uuid := current_setting('uw.src')::uuid;
  c2 jsonb := (select j from uw_w where k = 'c2'); bad jsonb; code text;
begin
  foreach bad in array array[
      jsonb_build_array(c2 || '{"type": "gym"}'),
      jsonb_build_array(c2 || '{"ended_at": 1790312400}'),
      jsonb_build_array(c2 || '{"ended_at": 1790412400}'),
      jsonb_build_array(c2 || '{"source": "phone"}'),
      jsonb_build_array(c2 || '{"client_id": "c2"}'),
      jsonb_build_array(c2, c2),
      (select jsonb_agg(c2 || jsonb_build_object('client_id', gen_random_uuid())) from generate_series(1, 51)),
      '[]'::jsonb] loop
    begin
      perform public.user_workouts_upsert_v1(u, d, s, null, bad);
      assert false, 'refused: ' || left(bad::text, 120);
    exception when sqlstate '22023' then null;
    end;
  end loop;
  begin
    perform public.user_workouts_upsert_v1(u, dbb, s, null, jsonb_build_array(c2));
    assert false, 'another owner''s device';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.user_workouts) = 1, 'nothing was written';
end $$;

-- 3 and 4. One workout at a time; the builder's queue -------------------------------------------------------------
do $$
declare
  u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid;
  s uuid := current_setting('uw.src')::uuid; c2 jsonb := (select j from uw_w where k = 'c2'); r jsonb;
  t public.user_workouts;
begin
  delete from internal.measurement_context_work where user_id = u;
  r := public.user_workouts_upsert_v1(u, d, s, null, jsonb_build_array(c2));
  assert r = '{"accepted": 1, "skipped_stale": 0, "closed": 0}', r::text;
  -- A second phone (or a lost stop) starts another workout 30 minutes later: the first is closed at that start.
  r := public.user_workouts_upsert_v1(u, d, s, null, jsonb_build_array(
         c2 || '{"client_id": "00000000-0000-4000-8000-0000000000c3", "type": "outdoor_run", "started_at": 1790314200,
                 "client_updated_at": 1790314200}'));
  assert r = '{"accepted": 1, "skipped_stale": 0, "closed": 1}', r::text;
  select * into t from public.user_workouts where user_id = u and client_id = '00000000-0000-4000-8000-0000000000c2';
  assert t.ended_at = to_timestamp(1790314200) and t.source = 'auto_ended'
     and t.client_updated_at = to_timestamp(1790312400), row_to_json(t)::text;
  assert (select count(*) from public.user_workouts where user_id = u and ended_at is null) = 1, 'one open workout';
  -- The local days the changes touch (2026-09-24 PDT) are queued for the builder.
  assert exists (select 1 from internal.measurement_context_work
                  where user_id = u and device_id = d and day = '2026-09-24' and queued_at is not null),
    (select string_agg(day::text, ',') from internal.measurement_context_work where user_id = u);
  -- The phone's own stop (newer clock) wins over the server's close, and a delete keeps the row as deleted.
  r := public.user_workouts_upsert_v1(u, d, s, null, jsonb_build_array(
         c2 || '{"ended_at": 1790313000, "client_updated_at": 1790313000}',
         c2 || '{"client_id": "00000000-0000-4000-8000-0000000000c3", "type": "outdoor_run", "started_at": 1790314200,
                 "ended_at": 1790316000, "deleted": true, "client_updated_at": 1790316100}'));
  assert r ->> 'accepted' = '2', r::text;
  select * into t from public.user_workouts where user_id = u and client_id = '00000000-0000-4000-8000-0000000000c2';
  assert t.ended_at = to_timestamp(1790313000) and t.source = 'manual', row_to_json(t)::text;
  assert (select deleted_at from public.user_workouts where client_id = '00000000-0000-4000-8000-0000000000c3')
         = to_timestamp(1790316100);
end $$;

-- 5. Read ---------------------------------------------------------------------------------------------------------
do $$
declare u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid; r jsonb; w jsonb;
begin
  r := public.user_workouts_read_v1(u, d, to_timestamp(1790300000), to_timestamp(1790320000));
  assert r ->> 'truncated' = 'false' and r ->> 'catalogue_version' = 'workout-types-1', r::text;
  assert jsonb_array_length(r -> 'workouts') = 2, 'the deleted one is left out ' || r::text;
  w := r -> 'workouts' -> 0;
  assert w ->> 'client_id' = '00000000-0000-4000-8000-0000000000c1' and w ->> 'device_id' = 'whoop-UWTEST0001'
     and (w ->> 'started_at')::bigint = 1790305200 and (w ->> 'ended_at')::bigint = 1790307900
     and w ->> 'type' = 'strength' and w -> 'attributes' ->> 'effort' = 'resistance'
     and w -> 'attributes' ->> 'gait_expected' = 'false' and w ->> 'deleted' = 'false', w::text;
  w := r -> 'workouts' -> 1;
  assert w -> 'attributes' ->> 'environment' = 'indoor' and w -> 'attributes' ->> 'locomotion' = 'walking'
     and w -> 'attributes' ->> 'gait_expected' = 'true', w::text;
  r := public.user_workouts_read_v1(u, null, to_timestamp(1790300000), to_timestamp(1790320000), 500, true);
  assert jsonb_array_length(r -> 'workouts') = 3, 'deleted ones when asked';
  r := public.user_workouts_read_v1(u, null, to_timestamp(1790300000), to_timestamp(1790320000), 1);
  assert jsonb_array_length(r -> 'workouts') = 1 and r ->> 'truncated' = 'true';
  assert jsonb_array_length(public.user_workouts_read_v1(u, d, to_timestamp(1790200000), to_timestamp(1790300000))
                            -> 'workouts') = 0, 'no overlap';
end $$;

-- 6. internal.logged_workouts_v1 ----------------------------------------------------------------------------------
-- A manual session at the same start as c1 (the live tracker's row from the structured push) is not listed twice; a
-- manual session elsewhere is listed, typed from its sport; an open workout counts up to now, never past 4 h.
insert into public.sessions (user_id, device_id, kind, source, start_at, end_at, summary)
values (:'ua', :'da', 'manual_workout', 'manual', to_timestamp(1790305230), to_timestamp(1790307900),
        '{"sport": "Strength"}'),
       (:'ua', :'da', 'manual_workout', 'manual', to_timestamp(1790290000), to_timestamp(1790292000),
        '{"sport": "Tennis"}'),
       (:'ua', :'da', 'workout', 'whoop', to_timestamp(1790280000), to_timestamp(1790282000), '{"sport": "Running"}');
do $$
declare u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid; got text;
        s uuid := current_setting('uw.src')::uuid;
begin
  select string_agg(format('%s/%s/%s/%s', extract(epoch from start_at)::bigint, extract(epoch from end_at)::bigint,
                           coalesce(workout_type, '-'), basis), ' ' order by start_at)
    into got from internal.logged_workouts_v1(u, d, to_timestamp(1790200000), to_timestamp(1790320000));
  assert got = '1790290000/1790292000/sports/manual_session 1790305200/1790307900/strength/user_workout '
               '1790312400/1790313000/indoor_walk/user_workout', got;
  perform public.user_workouts_upsert_v1(u, d, s, null, jsonb_build_array(jsonb_build_object(
    'client_id', '00000000-0000-4000-8000-0000000000c4', 'type', 'yoga',
    'started_at', extract(epoch from clock_timestamp())::bigint - 5 * 3600, 'ended_at', null,
    'client_updated_at', extract(epoch from clock_timestamp())::bigint - 5 * 3600)));
  assert (select end_at - start_at from internal.logged_workouts_v1(u, d, clock_timestamp() - interval '6 hours',
                                                                     clock_timestamp())) = interval '4 hours',
    'a forgotten workout counts for 4 hours';
  delete from public.user_workouts where client_id = '00000000-0000-4000-8000-0000000000c4';
end $$;

-- 7. The measurement-context builder ------------------------------------------------------------------------------
-- c1 (03:00-03:45Z) with a still arm (dyn 0.01, no steps) at 100 bpm, 02:00-04:30Z of data at 70 bpm otherwise.
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da', :'src', t, case when t >= 1790305200 and t < 1790307900 then 100 else 70 end, :'bat'
  from generate_series(1790301600, 1790310600 - 1) t;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da', :'src', t, 0, 0, 1, 0.01, :'bat' from generate_series(1790301600, 1790310600 - 1) t;
do $$
declare u uuid := current_setting('uw.ua')::uuid; d uuid := current_setting('uw.da')::uuid;
        s uuid := current_setting('uw.src')::uuid; r public.measurement_context_minutes;
begin
  perform internal.build_measurement_context_minutes(u, d, to_timestamp(1790301600), to_timestamp(1790310600));
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d
     and minute_start = to_timestamp(1790305200);
  assert r.session_phase = 'session' and r.session_basis = 'logged' and r.session_start = to_timestamp(1790305200)
     and r.workout_type = 'strength' and r.workout_basis = 'user_workout' and r.session_rule = 'exercise-session-2',
    row_to_json(r)::text;
  assert r.missing_reasons @> '[{"code": "context_not_comparable", "subcode": "in_session"}]', r.missing_reasons::text;
  assert (select count(*) from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start >= to_timestamp(1790305200) and minute_start < to_timestamp(1790307900)
           and session_phase = 'session' and session_basis = 'logged' and workout_type = 'strength') = 45,
    'every logged minute, from the first';
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d
     and minute_start = to_timestamp(1790304000);
  assert r.workout_type is null and r.workout_basis is null and r.session_phase = 'none', row_to_json(r)::text;
  -- Deleted: the same still minutes are no session. (The manual session at that start is the same workout, still
  -- logged by the structured push: it is a logged workout of its own sport's type.)
  perform public.user_workouts_upsert_v1(u, d, s, null, jsonb_build_array(
    (select j from uw_w where k = 'c1') || '{"deleted": true, "client_updated_at": 1790309000}'));
  delete from public.sessions where user_id = u and start_at = to_timestamp(1790305230);
  perform internal.build_measurement_context_minutes(u, d, to_timestamp(1790301600), to_timestamp(1790310600));
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d
     and minute_start = to_timestamp(1790305200);
  assert r.session_phase = 'none' and r.workout_type is null and r.session_basis is null, row_to_json(r)::text;
end $$;

-- 8. RLS and privileges -------------------------------------------------------------------------------------------
do $$ begin
  assert not has_function_privilege('authenticated', 'public.user_workouts_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('anon', 'public.user_workouts_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('authenticated',
    'public.user_workouts_read_v1(uuid,uuid,timestamptz,timestamptz,integer,boolean)', 'execute');
  assert has_function_privilege('service_role', 'public.user_workouts_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('service_role', 'internal.logged_workouts_v1(uuid,uuid,timestamptz,timestamptz)',
                                    'execute');
end $$;
select public.user_workouts_upsert_v1(:'ub', :'db', :'src', null, jsonb_build_array(
  (select j from uw_w where k = 'c1') || '{"client_id": "00000000-0000-4000-8000-0000000000b1"}')) \g /dev/null
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ua', 'role', 'authenticated')::text, true) \g /dev/null
do $$
begin
  assert (select count(*) from public.user_workouts) = 3, 'A sees its own workouts';
  assert (select count(*) from public.user_workouts where user_id = current_setting('uw.ub')::uuid) = 0;
  assert (select count(*) from public.workout_types) = 20, 'the catalogue is readable';
  begin
    insert into public.user_workouts (user_id, client_id, device_id, workout_type, started_at, client_updated_at)
    values (current_setting('uw.ua')::uuid, gen_random_uuid(), current_setting('uw.da')::uuid, 'yoga', now(), now());
    assert false, 'a client cannot write directly';
  exception when insufficient_privilege then null; end;
  begin
    perform public.user_workouts_upsert_v1(current_setting('uw.ua')::uuid, current_setting('uw.da')::uuid, null, null,
                                           '[]'::jsonb);
    assert false, 'a client cannot call the upsert';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', json_build_object('sub', :'ub', 'role', 'authenticated')::text, true) \g /dev/null
do $$ begin
  assert (select count(*) from public.user_workouts) = 1, 'B sees exactly its one workout';
end $$;
reset role;
set local role anon;
do $$ begin
  begin
    perform count(*) from public.user_workouts;
    assert false, 'anon reads nothing';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

rollback;
select 'user_workouts: ok' as result;
