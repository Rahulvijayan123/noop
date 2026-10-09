-- Regression for 20261009150200_anomaly_windows_read.sql. Run ONLY against an isolated, disposable full-schema
-- database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything runs in one transaction that
-- is rolled back:
--
--   PGAPPNAME=anomaly-windows-read psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/anomaly_windows_read.sql
--
-- (supabase/functions/tests/anomaly_windows_sql_test.ts runs it the same way inside the pipeline container.)
--
-- Checks: a withheld window carries its canonical reason (stored, or mapped from the legacy value for an older row);
-- a window every model is still learning on says learning; a window one model scored has no window reason; the
-- context mix comes from the minute rows over the window's full length (missing minutes are unknown) and is null
-- with basis none when no minute exists; the range is bounded; another owner's device is refused; only the service
-- role executes the function.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid() as u, gen_random_uuid() as d, gen_random_uuid() as v, gen_random_uuid() as dv \gset
select set_config('awr.u', :'u', true), set_config('awr.d', :'d', true), set_config('awr.dv', :'dv', true) \g /dev/null

do $$ begin
  assert current_setting('application_name') = 'anomaly-windows-read', 'disposable-database invocation required';
end $$;

insert into auth.users (id) values (:'u'), (:'v');
insert into public.devices (id, user_id, source_kind) values (:'d', :'u', 'noop_push'), (:'dv', :'v', 'noop_push');

insert into public.anomaly_window_scores (user_id, device_id, window_start, window_end, channel_group, model, score, p,
                                          context_kind, usable, withheld_reason, reason_code, reason_certainty)
values
  -- W1 withheld during the session (the service sent the canonical code)
  (:'u', :'d', '2026-10-07 21:00+00', '2026-10-07 21:30+00', 'all', 'none', null, null, 'rest', false, 'activity',
   'context_not_comparable/movement', 'inferred'),
  -- W2 withheld in recovery, written before the service sent codes
  (:'u', :'d', '2026-10-07 21:30+00', '2026-10-07 22:00+00', 'all', 'none', null, null, 'rest', false, 'recovery',
   null, null),
  -- W3 usable, both models still learning
  (:'u', :'d', '2026-10-07 22:00+00', '2026-10-07 22:30+00', 'all', 'timesfm-3.0', 1.2, 0.4, 'rest', true,
   'calibrating', 'learning', 'measured'),
  (:'u', :'d', '2026-10-07 22:00+00', '2026-10-07 22:30+00', 'all', 'units-x128', 0.8, 0.6, 'rest', true,
   'calibrating', 'learning', 'measured'),
  -- W4 usable, one model scored it
  (:'u', :'d', '2026-10-07 22:30+00', '2026-10-07 23:00+00', 'all', 'timesfm-3.0', 0.5, 0.7, 'rest', true, null,
   null, null),
  (:'u', :'d', '2026-10-07 22:30+00', '2026-10-07 23:00+00', 'all', 'units-x128', 0.9, 0.5, 'rest', true,
   'calibrating', 'learning', 'measured'),
  -- outside the range read below
  (:'u', :'d', '2026-10-07 23:00+00', '2026-10-07 23:30+00', 'all', 'none', null, null, 'sleep', false,
   'off_wrist', 'off_wrist', 'inferred');

-- W1's minutes: 15 in the session (walking), 5 in recovery (stationary), 10 never built.
insert into public.measurement_context_minutes (user_id, device_id, minute_start, local_day, utc_offset_s, tz_basis,
    quality_class, activity_class, activity_basis, sleep_basis, wear_state, wear_basis, session_phase, session_rule,
    context_version, revision)
select :'u', :'d', timestamptz '2026-10-07 21:00+00' + make_interval(mins => i), '2026-10-07', -25200, 'profile',
       'good', case when i < 15 then 'walking' else 'stationary' end, 'activity_epoch', 'outside_server_night',
       'on_wrist', 'hr_present', case when i < 15 then 'session' else 'recovery' end, 'exercise-session-1',
       (select min(id) from public.measurement_context_versions), nextval('public.measurement_context_minutes_revision_seq')
  from generate_series(0, 19) i;

do $$
declare u uuid := current_setting('awr.u')::uuid; d uuid := current_setting('awr.d')::uuid; r jsonb; w jsonb;
begin
  r := public.anomaly_windows_read_v1(u, d, '2026-10-07 21:00+00', '2026-10-07 23:00+00');
  assert jsonb_array_length(r) = 4, r::text;
  w := r -> 0;
  assert (w ->> 'start_ts')::timestamptz = '2026-10-07 21:00+00' and (w ->> 'end_ts')::timestamptz = '2026-10-07 21:30+00';
  assert not (w ->> 'usable')::boolean;
  assert w -> 'reason' = '{"code": "context_not_comparable", "subcode": "movement", "certainty": "inferred",
                           "legacy": "activity"}', (w -> 'reason')::text;
  assert w -> 'context' ->> 'kind' = 'rest' and w -> 'context' ->> 'mix_basis' = 'measurement_context_minutes';
  assert (w -> 'context' ->> 'minutes')::integer = 20;
  assert w -> 'context' -> 'mix' = '{"session": 0.500, "recovery": 0.167, "no_session": 0.000, "unknown": 0.333,
         "asleep": 0.000, "off_wrist": 0.000, "activity": {"walking": 0.500, "stationary": 0.167},
         "quality": {"good": 0.667}}', (w -> 'context' -> 'mix')::text;
  assert jsonb_array_length(w -> 'models') = 1 and w -> 'models' -> 0 ->> 'model' = 'none';

  w := r -> 1;
  assert w -> 'reason' = '{"code": "context_not_comparable", "subcode": "recovery", "certainty": "inferred",
                           "legacy": "recovery"}', 'an older row is mapped from its legacy value: ' || (w -> 'reason')::text;
  assert w -> 'context' -> 'mix' = 'null'::jsonb and w -> 'context' ->> 'mix_basis' = 'none';
  assert (w -> 'context' ->> 'minutes')::integer = 0;

  w := r -> 2;
  assert (w ->> 'usable')::boolean;
  assert w -> 'reason' = '{"code": "learning", "certainty": "measured", "legacy": "calibrating"}', (w -> 'reason')::text;
  assert jsonb_array_length(w -> 'models') = 2;
  assert w -> 'models' -> 0 ->> 'model' = 'timesfm-3.0' and (w -> 'models' -> 0 ->> 'p')::float8 = 0.4;

  w := r -> 3;
  assert w -> 'reason' = 'null'::jsonb, 'one model scored it: no window reason';
  assert w -> 'models' -> 0 -> 'reason' = 'null'::jsonb and w -> 'models' -> 1 -> 'reason' ->> 'code' = 'learning';

  assert public.anomaly_windows_read_v1(u, d, '2026-10-08 00:00+00', '2026-10-08 06:00+00') = '[]';
  begin
    perform public.anomaly_windows_read_v1(u, d, '2026-10-01', '2026-10-05');
    assert false, 'more than 3 days is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_range'; end;
  begin
    perform public.anomaly_windows_read_v1(u, current_setting('awr.dv')::uuid, '2026-10-07', '2026-10-08');
    assert false, 'another owner''s device is refused';
  exception when insufficient_privilege then assert sqlerrm = 'device_owner_mismatch'; end;
  assert not has_function_privilege('authenticated', 'public.anomaly_windows_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert not has_function_privilege('anon', 'public.anomaly_windows_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert has_function_privilege('service_role', 'public.anomaly_windows_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
end $$;

rollback;
select 'anomaly_windows_read: ok' as result;
