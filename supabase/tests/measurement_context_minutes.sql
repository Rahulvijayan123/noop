-- Regression for 20261009130100_measurement_context_minutes.sql. Run ONLY against an isolated, disposable
-- full-schema database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything runs in one
-- transaction that is rolled back; the fixture is passed in from the repository root:
--
--   PGAPPNAME=measurement-context-minutes psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 \
--     -v fixture="$(cat contracts/reference/exercise-session-2.json)" -f supabase/tests/measurement_context_minutes.sql
--
-- (supabase/functions/tests/measurement_context_sql_test.ts runs it the same way inside the pipeline container.)
--
-- Checks:
--   1. internal.exercise_session_spans_v2 reproduces every case of contracts/reference/exercise-session-2.json
--      (start, end, recovery_end, pre_reference, confirmed, confirmed_at).
--   2. A synthetic day built from raw rows: a gym evening (still sets between walking minutes; a confirmed session,
--      recovery, rest reference from the still minutes before, context_not_comparable in_session / recovery), a
--      scored night (stages from a JSON-string column; asleep movement is never evidence), off-wrist by WRIST_OFF /
--      WRIST_ON events, a WRIST_OFF closed by sustained heart rate, a BLE link-down gap, a span with no IMU
--      (context_unknown), awaiting_upload after the newest upload, local time across the March DST change.
--   2b. Rule exercise-session-2 in the builder: a period with 4 strong minutes is stored `active` (subcode movement,
--      no recovery after it); an other_movement epoch stretch between two strong minutes is no evidence; a growing
--      period is `active` with 14 strong minutes and converges to a session with its recovery once more data is
--      rebuilt.
--   3. Idempotence: a rebuild writes nothing and keeps every revision; one new raw row re-writes only its minute.
--   4. Backfill rows carry the backfill version and never claim awaiting_upload.
--   5. pg_cron path: discover queues the changed local days, process builds them and clears the queue.
--   6. Privileges and RLS: two owners stay apart; anon reads nothing; no client executes the functions; no trigger
--      on noop_* tables and no scoring lock in the builder.
\set ON_ERROR_STOP on

begin;
create temp table mcm_fixture as select :'fixture'::jsonb as j;

-- 1. Rule exercise-session-2 parity -----------------------------------------------------------------------------
do $$
declare c jsonb; hr double precision[]; st boolean[]; wk boolean[]; got jsonb; t0 bigint; n integer := 0;
        n_unconfirmed integer := 0; n_inherited integer := 0;
begin
  assert current_setting('application_name') = 'measurement-context-minutes', 'disposable-database invocation required';
  for c in select jsonb_array_elements(j -> 'cases') from mcm_fixture loop
    hr := array(select case when jsonb_typeof(v) = 'null' then null else v::text::double precision end
                  from jsonb_array_elements(c -> 'hr') with ordinality t(v, o) order by o);
    st := array(select v::text::integer = 1 from jsonb_array_elements(c -> 'strong') with ordinality t(v, o) order by o);
    wk := array(select v::text::integer = 1 from jsonb_array_elements(c -> 'weak') with ordinality t(v, o) order by o);
    t0 := (c ->> 't0')::bigint;
    got := coalesce((select jsonb_agg(jsonb_build_object('start', t0 + s.a * 60, 'end', t0 + s.b * 60,
             'recovery_end', t0 + s.recovery_end * 60, 'pre_reference', round(s.pre_reference::numeric, 3),
             'confirmed', s.confirmed, 'confirmed_at', t0 + s.confirmed_at * 60)
             order by s.a)
             from internal.exercise_session_spans_v2(hr, st, wk, null, null, (c ->> 'rest_reference')::float8) s), '[]');
    assert got = c -> 'sessions', format('exercise-session-2 case %s: got %s, want %s', c ->> 'name', got, c -> 'sessions');
    n := n + 1;
    n_unconfirmed := n_unconfirmed + jsonb_array_length(jsonb_path_query_array(c -> 'sessions', '$[*] ? (@.confirmed == false)'));
    n_inherited := n_inherited + jsonb_array_length(jsonb_path_query_array(c -> 'sessions',
                                                                             '$[*] ? (@.confirmed_at == @.start)'));
  end loop;
  assert n = 13, format('expected the 13 fixture cases, ran %s', n);
  -- The fixture exercises both new paths: unconfirmed periods and inherited confirmation.
  assert n_unconfirmed >= 4 and n_inherited >= 2, format('unconfirmed %s, inherited %s', n_unconfirmed, n_inherited);
  assert (select j ->> 'rule' from mcm_fixture) = 'exercise-session-2';
end $$;

-- 2. A synthetic day ------------------------------------------------------------------------------------------
select gen_random_uuid() as ua, gen_random_uuid() as ub, gen_random_uuid() as da, gen_random_uuid() as da2,
       gen_random_uuid() as da3, gen_random_uuid() as db, gen_random_uuid() as src, gen_random_uuid() as bat \gset
select set_config('mcm.ua', :'ua', true), set_config('mcm.ub', :'ub', true), set_config('mcm.da', :'da', true),
       set_config('mcm.da2', :'da2', true), set_config('mcm.da3', :'da3', true), set_config('mcm.db', :'db', true),
       set_config('mcm.src', :'src', true), set_config('mcm.bat', :'bat', true) \g /dev/null

insert into auth.users (id) values (:'ua'), (:'ub');
insert into public.profiles (id, timezone) values (:'ua', 'America/Los_Angeles'), (:'ub', 'America/New_York')
  on conflict (id) do update set timezone = excluded.timezone;
-- The sign-up trigger created both profiles in UTC; the history these people were scored in is Pacific / Eastern
-- from the start.
delete from public.scoring_timezone_history where user_id in (:'ua', :'ub');
insert into public.scoring_timezone_history (user_id, effective_at, timezone_id, provenance)
values (:'ua', '-infinity', 'America/Los_Angeles', 'initial_profile'), (:'ub', '-infinity', 'America/New_York', 'initial_profile');
insert into public.devices (id, user_id, source_kind) values (:'da', :'ua', 'noop_push'), (:'da2', :'ua', 'noop_push'),
  (:'da3', :'ua', 'noop_push'), (:'db', :'ub', 'noop_push');

-- Gym evening: T = 2026-09-15 01:00Z (18:00 PDT). k = minutes from T - 60 min.
--   k 0..59 rest (HR 72, dyn 0.01); k 60..119 sets: every 3rd minute walking (12 step samples, class walk) at
--   dyn 0.12 and HR 135, the others still (dyn 0.02) at HR 128; k 120..239 recovery 78 + 50 * 0.9^(k-120);
--   k 240..299 HR 74.
create temp table mcm_gym as
select k, (extract(epoch from timestamptz '2026-09-15 01:00:00+00')::bigint - 3600 + k * 60) as m,
       case when k < 60 then 72 when k < 120 and (k - 60) % 3 = 0 then 135 when k < 120 then 128
            when k < 240 then round(78 + 50 * power(0.9, k - 120))::integer else 74 end as bpm,
       case when k >= 60 and k < 120 and (k - 60) % 3 = 0 then 0.12 when k >= 60 and k < 120 then 0.02
            else 0.01 end as dyn,
       (k >= 60 and k < 120 and (k - 60) % 3 = 0) as walk
  from generate_series(0, 299) k;
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da', :'src', g.m + s, g.bpm, :'bat' from mcm_gym g cross join generate_series(0, 59) s;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da', :'src', g.m + s, 0, 0, 1, g.dyn, :'bat' from mcm_gym g cross join generate_series(0, 59) s;
insert into public.noop_step_samples (user_id, device_id, source_id, ts, counter, "activityClass", batch_id)
select :'ua', :'da', :'src', g.m + s, (g.k * 100 + s)::integer, 1, :'bat'
  from mcm_gym g cross join generate_series(0, 55, 5) s where g.walk;

-- Night 2026-09-15 06:00Z-08:00Z (23:00-01:00 PDT): strap sleep state asleep, HR 55, fidgeting at dyn 0.06 and one
-- minute (06:30) at 0.2 g. Scored night: light 06:00-07:00, wake 07:00-07:30, deep 07:30-08:00, stored as the worker
-- stores it (a JSON string).
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da', :'src', t, 55, :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-15 06:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-15 07:59:59+00')::bigint) t;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da', :'src', t, 0, 0, 1,
       case when t - t % 60 = extract(epoch from timestamptz '2026-09-15 06:30:00+00')::bigint then 0.2 else 0.06 end,
       :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-15 06:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-15 07:59:59+00')::bigint) t;
insert into public.noop_sleep_state_samples (user_id, device_id, source_id, ts, state, batch_id)
select :'ua', :'da', :'src', t, 2, :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-15 06:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-15 07:59:59+00')::bigint, 30) t;
insert into public.server_sleep_nights (id, user_id, device_id, period_day, start_at, end_at, is_nap, stages,
                                        algorithm_version)
values (gen_random_uuid(), :'ua', :'da', '2026-09-15', '2026-09-15 06:00:00+00', '2026-09-15 08:00:00+00', false,
        to_jsonb(format('[{"end":%s,"stage":"light","start":%s},{"end":%s,"stage":"wake","start":%s},'
                        '{"end":%s,"stage":"deep","start":%s}]',
                        extract(epoch from timestamptz '2026-09-15 07:00:00+00')::bigint,
                        extract(epoch from timestamptz '2026-09-15 06:00:00+00')::bigint,
                        extract(epoch from timestamptz '2026-09-15 07:30:00+00')::bigint,
                        extract(epoch from timestamptz '2026-09-15 07:00:00+00')::bigint,
                        extract(epoch from timestamptz '2026-09-15 08:00:00+00')::bigint,
                        extract(epoch from timestamptz '2026-09-15 07:30:00+00')::bigint)),
        'frwhoop-server-1');

-- Afternoon, no IMU at all: HR 14:30-15:00:09; WRIST_OFF 15:00:10, WRIST_ON 15:20:05; HR 15:20:05-15:44:59;
-- BLE link down 15:45:00-15:50:00 (no HR); HR 15:50-16:39:59 with beats (R-R) for 16:10-16:24; WRIST_OFF 16:40:00
-- and no WRIST_ON, HR again 16:50-16:59:59 (sustained HR closes the OFF).
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da', :'src', t, 66, :'bat'
  from (select generate_series(extract(epoch from timestamptz '2026-09-15 14:30:00+00')::bigint,
                               extract(epoch from timestamptz '2026-09-15 15:00:09+00')::bigint) t
        union all
        select generate_series(extract(epoch from timestamptz '2026-09-15 15:20:05+00')::bigint,
                               extract(epoch from timestamptz '2026-09-15 15:44:59+00')::bigint)
        union all
        select generate_series(extract(epoch from timestamptz '2026-09-15 15:50:00+00')::bigint,
                               extract(epoch from timestamptz '2026-09-15 16:39:59+00')::bigint)
        union all
        select generate_series(extract(epoch from timestamptz '2026-09-15 16:50:00+00')::bigint,
                               extract(epoch from timestamptz '2026-09-15 16:59:59+00')::bigint)) x;
insert into public.noop_rr_intervals (user_id, device_id, source_id, ts, "rrMs", seq, ord, "srcChannel", batch_id)
select :'ua', :'da', :'src', t, 900, 0, 0, 5, :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-15 16:10:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-15 16:24:59+00')::bigint) t;
insert into public.noop_events (user_id, device_id, source_id, ts, kind, "payloadJSON", batch_id) values
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 15:00:10+00')::bigint, 'WRIST_OFF(10)', '{}', :'bat'),
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 15:20:05+00')::bigint, 'WRIST_ON(9)', '{}', :'bat'),
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 15:45:00+00')::bigint, 'BLE_CONNECTION_DOWN', '{}', :'bat'),
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 15:50:00+00')::bigint, 'BLE_CONNECTION_UP', '{}', :'bat'),
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 16:40:00+00')::bigint, 'WRIST_OFF(10)', '{}', :'bat'),
  (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 14:31:00+00')::bigint, 'STANDARD_HR_CONTACT',
   '{"contact":"unsupported"}', :'bat');

create temp table mcm_built as
select internal.build_measurement_context_minutes(:'ua', :'da', '2026-09-15 00:00:00+00', '2026-09-15 17:10:00+00') as n;

create or replace function pg_temp.mcm(p_at timestamptz) returns public.measurement_context_minutes
language sql as $$
  select t from public.measurement_context_minutes t
   where t.user_id = current_setting('mcm.ua')::uuid and t.device_id = current_setting('mcm.da')::uuid
     and t.minute_start = p_at
$$;

do $$
declare r public.measurement_context_minutes; t0 timestamptz := '2026-09-15 01:00:00+00';
begin
  assert (select n from mcm_built) = 17 * 60 + 10, format('one row per completed minute, got %s', (select n from mcm_built));
  assert (select count(*) from public.measurement_context_minutes where user_id = current_setting('mcm.ua')::uuid)
         = 17 * 60 + 10;

  -- Gym: rest from the still minutes before (72), session from the first walking minute (k 60 = T) to the last
  -- (k 117), recovery until HR stays within pre (72) + 10 for 5 minutes (from k 143; the reference implementation
  -- gives the same spans for these minutes).
  r := pg_temp.mcm(t0 - interval '30 minutes');
  assert r.session_phase = 'none' and r.session_rule = 'exercise-session-2', 'rest before the gym';
  assert r.quality_class = 'fair' and r.reasons = '[{"code": "insufficient_coverage", "certainty": "measured"}]',
    format('still minute without beats: %s %s', r.quality_class, r.reasons);
  assert r.hr_n = 60 and r.hr_mean = 72 and r.dyn_n = 60 and abs(r.dyn_mean - 0.01) < 1e-6 and r.observed_s = 60;
  r := pg_temp.mcm(t0);
  assert r.session_phase = 'session' and r.session_start = t0 and r.session_basis = 'awake_still_median',
    format('first walking minute opens the session: %s %s %s', r.session_phase, r.session_start, r.session_basis);
  assert r.steps_n = 12 and r.step_walk_n = 12 and r.step_run_n = 0;
  assert r.quality_class = 'fair' and r.reasons = '[{"code": "hr_in_motion_unverified", "certainty": "inferred"}]';
  -- 20 walking minutes: confirmed (at the 15th); a session minute is not comparable with rest.
  assert r.missing_reasons = '[{"code": "context_unknown", "certainty": "unknown"},
                               {"code": "context_not_comparable", "subcode": "in_session", "certainty": "inferred"}]',
    r.missing_reasons::text;
  r := pg_temp.mcm(t0 + interval '1 minute');
  assert r.session_phase = 'session' and r.hr_mean = 128, 'a still set minute stays in the session';
  r := pg_temp.mcm(t0 + interval '57 minutes');
  assert r.session_phase = 'session', 'last walking minute';
  r := pg_temp.mcm(t0 + interval '58 minutes');
  assert r.session_phase = 'recovery' and r.session_start = t0, 'recovery starts after the last evidence minute';
  assert r.missing_reasons @> '[{"code": "context_not_comparable", "subcode": "recovery", "certainty": "inferred"}]',
    r.missing_reasons::text;
  r := pg_temp.mcm(t0 + interval '82 minutes');
  assert r.session_phase = 'recovery', 'still recovering at k 142';
  r := pg_temp.mcm(t0 + interval '83 minutes');
  assert r.session_phase = 'none' and r.session_start is null, format('recovered at k 143: %s', r.session_phase);
  assert r.local_day = '2026-09-14' and r.utc_offset_s = -25200 and r.tz_basis = 'timezone_history';
  assert r.activity_basis = 'none' and r.activity_class is null, 'no activity lineage: nothing copied';
  assert r.missing_reasons = '[{"code": "context_unknown", "certainty": "unknown"}]', r.missing_reasons::text;
  assert r.wear_state = 'on_wrist' and r.wear_basis = 'hr_present';
  assert r.sleep_state is null and r.sleep_basis = 'not_scored';
  -- Nothing declared for this owner (20261009150100 resolves placement): unknown stays unknown.
  assert r.placement is null and r.placement_basis = 'undeclared', format('%s %s', r.placement, r.placement_basis);

  -- Night: stages from the scored night, asleep movement is not evidence.
  r := pg_temp.mcm('2026-09-15 06:10:00+00');
  assert r.sleep_state = 'asleep' and r.sleep_basis = 'server_night_stages' and r.band_sleep_state = 2;
  assert r.session_phase = 'none';
  r := pg_temp.mcm('2026-09-15 06:30:00+00');
  assert abs(r.dyn_mean - 0.2) < 1e-6 and r.session_phase = 'none', 'a 0.2 g minute asleep never opens a session';
  r := pg_temp.mcm('2026-09-15 07:10:00+00');
  assert r.sleep_state = 'awake' and r.sleep_basis = 'server_night_stages', 'wake segment';
  r := pg_temp.mcm('2026-09-15 08:30:00+00');
  assert r.sleep_state is null and r.sleep_basis = 'not_scored' and r.hr_n = 0;

  -- Off-wrist by events.
  r := pg_temp.mcm('2026-09-15 15:00:00+00');
  assert r.wrist_event = 'off' and r.hr_n = 10 and r.wear_state = 'off_wrist' and r.wear_basis = 'wrist_event';
  assert r.quality_class = 'off_wrist' and r.quality_conf = 1
     and r.reasons = '[{"code": "off_wrist", "certainty": "confirmed"}]';
  r := pg_temp.mcm('2026-09-15 15:05:00+00');
  assert r.hr_n = 0 and r.wear_state = 'off_wrist' and r.quality_class = 'off_wrist';
  assert r.missing_reasons = '[{"code": "off_wrist", "certainty": "confirmed"}, {"code": "context_unknown", "certainty": "unknown"}]',
    r.missing_reasons::text;
  assert r.session_phase = 'none', 'an off-wrist minute is known not to be exercise evidence';
  assert r.contact_state = 'unsupported', 'contact carried forward from 14:31';
  r := pg_temp.mcm('2026-09-15 15:20:00+00');
  assert r.wrist_event = 'on' and r.wear_state = 'on_wrist' and r.wear_basis = 'wrist_event';

  -- BLE link down without HR.
  r := pg_temp.mcm('2026-09-15 15:46:00+00');
  assert r.ble_link_down_s = 60 and r.hr_n = 0;
  assert r.missing_reasons -> 0 = '{"code": "strap_link_down", "certainty": "confirmed"}', r.missing_reasons::text;
  r := pg_temp.mcm('2026-09-15 15:50:00+00');
  assert r.ble_link_down_s is null and r.hr_n = 60;

  -- No IMU: context unknown, session phase unknown; beats present -> good.
  r := pg_temp.mcm('2026-09-15 16:15:00+00');
  assert r.dyn_n = 0 and r.activity_basis = 'none' and r.session_phase is null and r.session_rule is null;
  assert r.missing_reasons = '[{"code": "context_unknown", "certainty": "unknown"}]';
  assert r.rr_n = 60 and r.quality_class = 'good' and r.quality_conf::numeric = 0.6 and r.reasons = '[]',
    format('%s %s %s', r.quality_class, r.quality_conf, r.reasons);
  r := pg_temp.mcm('2026-09-15 16:30:00+00');
  assert r.rr_n = 0 and r.quality_class = 'fair';

  -- WRIST_OFF with no WRIST_ON: off until heart rate is sustained for 5 minutes after it.
  r := pg_temp.mcm('2026-09-15 16:45:00+00');
  assert r.wear_state = 'off_wrist' and r.wear_basis = 'wrist_event';
  r := pg_temp.mcm('2026-09-15 16:52:00+00');
  assert r.wear_state = 'off_wrist', 'not yet 5 sustained minutes';
  r := pg_temp.mcm('2026-09-15 16:58:00+00');
  assert r.wear_state = 'on_wrist' and r.wear_basis = 'hr_present', format('%s %s', r.wear_state, r.wear_basis);

  -- After the newest upload: awaiting_upload (inferred), never a fabricated cause.
  r := pg_temp.mcm('2026-09-15 17:05:00+00');
  assert r.hr_n = 0 and r.missing_reasons -> 0 = '{"code": "awaiting_upload", "certainty": "inferred"}',
    r.missing_reasons::text;
  r := pg_temp.mcm('2026-09-15 13:30:00+00');
  assert r.hr_n = 0 and r.missing_reasons -> 0 = '{"code": "insufficient_coverage", "certainty": "measured"}',
    r.missing_reasons::text;

  assert (select count(distinct context_version) from public.measurement_context_minutes
           where user_id = current_setting('mcm.ua')::uuid) = 1;
  assert (select v.backfill from public.measurement_context_versions v
           where v.id = (select context_version from pg_temp.mcm(t0))) = false;
end $$;

-- DST: 2026-03-08 02:00 PST -> 03:00 PDT happens at 10:00Z.
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da2')::uuid; sp record;
begin
  perform internal.build_measurement_context_minutes(u, d, '2026-03-08 09:00:00+00', '2026-03-08 11:00:00+00');
  assert (select (utc_offset_s, local_day) = (-28800, '2026-03-08'::date) from public.measurement_context_minutes
           where user_id = u and device_id = d and minute_start = '2026-03-08 09:59:00+00');
  assert (select (utc_offset_s, local_day) = (-25200, '2026-03-08'::date) from public.measurement_context_minutes
           where user_id = u and device_id = d and minute_start = '2026-03-08 10:00:00+00');
  select * into sp from internal.measurement_context_day_span(u, '2026-03-08');
  assert sp.hi - sp.lo = interval '23 hours', 'spring-forward day is 23 h';
  select * into sp from internal.measurement_context_day_span(u, '2026-11-01');
  assert sp.hi - sp.lo = interval '25 hours', 'fall-back day is 25 h';
end $$;

-- 2b. Rule exercise-session-2 in the builder (device da3, 2026-09-16 UTC) --------------------------------------
-- A: T2 = 05:00Z. k = minutes from T2 - 60 min. k 0..59 still at 70 bpm (the rest reference); k 60..84 at 100 bpm,
--    weak movement (0.06 g) every other minute and 4 strong minutes (0.12 g at k 62, 70, 76, 84): the session
--    conditions hold but only 4 strong minutes, so the period is `active`; k 85..99 still at 98 bpm (rule -1 called
--    this recovery); k 100..149 still at 70.
-- B: T3 = 09:00Z. k 0..59 still at 70; strong minutes k 60 and k 81 (0.12 g, 110 bpm) with 20 still minutes between
--    them at 110 bpm, each covered by confident awake on-wrist other_movement epochs; k 82..119 still at 70. Were
--    other_movement weak evidence (rule -1), k 60..81 would be one period meeting the session conditions.
-- C: T4 = 14:00Z. k 0..59 still at 70; first upload k 60..73: 14 strong minutes at 120 bpm (a period still growing:
--    `active`); second upload k 74..79 strong at 120, k 80..89 still at 90, k 90..119 still at 72: 20 strong minutes,
--    confirmed at k 74, recovery k 80..89.
create temp table mcm_es2 as
select 'A' as part, k, extract(epoch from timestamptz '2026-09-16 05:00:00+00')::bigint - 3600 + k * 60 as m,
       case when k < 60 then 70 when k < 85 then 100 when k < 100 then 98 else 70 end as bpm,
       case when k in (62, 70, 76, 84) then 0.12 when k between 60 and 84 and k % 2 = 0 then 0.06
            when k between 60 and 84 then 0.02 else 0.01 end as dyn
  from generate_series(0, 149) k
union all
select 'B', k, extract(epoch from timestamptz '2026-09-16 09:00:00+00')::bigint - 3600 + k * 60,
       case when k between 60 and 81 then 110 else 70 end,
       case when k in (60, 81) then 0.12 when k between 61 and 80 then 0.02 else 0.01 end
  from generate_series(0, 119) k
union all
select 'C', k, extract(epoch from timestamptz '2026-09-16 14:00:00+00')::bigint - 3600 + k * 60,
       case when k < 60 then 70 when k < 80 then 120 when k < 90 then 90 else 72 end,
       case when k between 60 and 79 then 0.12 else 0.01 end
  from generate_series(0, 119) k;
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da3', :'src', e.m + s, e.bpm, :'bat' from mcm_es2 e cross join generate_series(0, 59) s
 where e.part <> 'C' or e.k < 74;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da3', :'src', e.m + s, 0, 0, 1, e.dyn, :'bat' from mcm_es2 e cross join generate_series(0, 59) s
 where e.part <> 'C' or e.k < 74;
insert into public.activity_context_epochs (user_id, device_id, day, start_ts, end_ts, motion_label, posture,
  exercise_session, sleep_state, exertion_context, wear_state, confidence, observed_s, valid_s, model_version,
  preprocessing_version, ontology_version, fingerprint, result_revision, computed_at)
select :'ua', :'da3', '2026-09-16', e.m + h, e.m + h + 30, 'other_movement', 'unknown', 'false', 'awake', 'unknown',
       'on_wrist', 0.9, 30, 30, 'hart-activity-v1', 'hart-activity-preprocess-v1', 'v1', repeat('a', 64), 1,
       clock_timestamp()
  from mcm_es2 e cross join (values (0), (30)) h(h)
 where e.part = 'B' and e.k between 61 and 80;

do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da3')::uuid;
        r public.measurement_context_minutes; t2 timestamptz := '2026-09-16 05:00:00+00';
        t3 timestamptz := '2026-09-16 09:00:00+00'; t4 timestamptz := '2026-09-16 14:00:00+00';
begin
  perform internal.build_measurement_context_minutes(u, d, '2026-09-16 04:00:00+00', '2026-09-16 10:30:00+00');

  -- A: a period meeting the session conditions with 4 strong minutes is `active`, not comparable (movement), and
  -- leaves no recovery behind.
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d and minute_start = t2;
  assert r.session_phase = 'active' and r.session_start = t2 and r.session_rule = 'exercise-session-2'
     and r.session_basis = 'awake_still_median', format('%s %s %s %s', r.session_phase, r.session_start,
                                                       r.session_rule, r.session_basis);
  assert r.missing_reasons = '[{"code": "context_unknown", "certainty": "unknown"},
                               {"code": "context_not_comparable", "subcode": "movement", "certainty": "inferred"}]',
    r.missing_reasons::text;
  assert (select count(*) from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start >= t2 and minute_start < t2 + interval '25 minutes' and session_phase = 'active'
           and missing_reasons @> '[{"code": "context_not_comparable", "subcode": "movement"}]') = 25,
    'k 60..84 are active';
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d
     and minute_start = t2 + interval '25 minutes';
  assert r.session_phase = 'none' and r.session_start is null and r.hr_mean = 98, format('no recovery after an '
    'active period: %s', r.session_phase);
  assert r.missing_reasons = '[{"code": "context_unknown", "certainty": "unknown"}]', r.missing_reasons::text;
  assert not exists (select 1 from public.measurement_context_minutes where user_id = u and device_id = d
                      and session_phase in ('session', 'recovery')), 'no session and no recovery rows';

  -- B: other_movement epochs are copied as the minute's activity but are not movement evidence: the two strong
  -- minutes 21 minutes apart form no period.
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d
     and minute_start = t3 + interval '5 minutes';
  assert r.activity_class = 'other_movement' and r.activity_basis = 'activity_epoch' and r.session_phase = 'none',
    format('%s %s %s', r.activity_class, r.activity_basis, r.session_phase);
  assert r.missing_reasons = '[]', r.missing_reasons::text;
  assert (select count(*) filter (where session_phase = 'none') from public.measurement_context_minutes
           where user_id = u and device_id = d and minute_start >= t3 and minute_start <= t3 + interval '21 minutes')
         = 22, 'an other_movement stretch is no evidence';

  -- C, first upload: a period still growing (14 strong minutes so far) is `active`, with no recovery after it.
  perform internal.build_measurement_context_minutes(u, d, '2026-09-16 13:00:00+00', '2026-09-16 15:00:00+00');
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d and minute_start = t4;
  assert r.session_phase = 'active' and r.session_start = t4, format('growing period: %s', r.session_phase);
  perform set_config('mcm.rev_t4', r.revision::text, true);
  assert (select count(*) from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start >= t4 and session_phase = 'active') = 14;
  assert (select session_phase from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start = t4 + interval '14 minutes') is null, 'nothing uploaded after k 73: phase unknown';
  assert not exists (select 1 from public.measurement_context_minutes where user_id = u and device_id = d
                      and session_phase in ('session', 'recovery'));
end $$;

-- C, second upload, then the same rebuild: the stored rows converge to the batch answer over the whole period.
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da3', :'src', e.m + s, e.bpm, :'bat' from mcm_es2 e cross join generate_series(0, 59) s
 where e.part = 'C' and e.k >= 74;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da3', :'src', e.m + s, 0, 0, 1, e.dyn, :'bat' from mcm_es2 e cross join generate_series(0, 59) s
 where e.part = 'C' and e.k >= 74;
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da3')::uuid;
        r public.measurement_context_minutes; t4 timestamptz := '2026-09-16 14:00:00+00';
begin
  perform internal.build_measurement_context_minutes(u, d, '2026-09-16 13:00:00+00', '2026-09-16 15:00:00+00');
  select * into r from public.measurement_context_minutes where user_id = u and device_id = d and minute_start = t4;
  assert r.session_phase = 'session' and r.session_start = t4
     and r.missing_reasons @> '[{"code": "context_not_comparable", "subcode": "in_session"}]',
    format('confirmed at the 15th strong minute: %s %s', r.session_phase, r.missing_reasons);
  assert r.revision > current_setting('mcm.rev_t4')::bigint, 'the rewritten row carries a new revision';
  assert (select count(*) from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start >= t4 and minute_start < t4 + interval '20 minutes' and session_phase = 'session') = 20;
  assert (select array_agg(distinct session_phase) from public.measurement_context_minutes
           where user_id = u and device_id = d and minute_start >= t4 + interval '20 minutes'
             and minute_start < t4 + interval '30 minutes') = array['recovery'], 'recovery k 80..89';
  assert (select session_phase from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start = t4 + interval '30 minutes') = 'none', 'back within pre-session + 10 at k 90';
  assert not exists (select 1 from public.measurement_context_minutes where user_id = u and device_id = d
                      and minute_start >= t4 and session_phase = 'active'), 'no active minute is left behind';
end $$;

-- 3. Idempotence ----------------------------------------------------------------------------------------------
create temp table mcm_revs as
select minute_start, revision, computed_at from public.measurement_context_minutes
 where user_id = :'ua' and device_id = :'da';
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da')::uuid; n integer;
begin
  n := internal.build_measurement_context_minutes(u, d, '2026-09-15 00:00:00+00', '2026-09-15 17:10:00+00');
  assert n = 0, format('a rebuild over unchanged rows writes nothing, wrote %s', n);
  assert not exists (select 1 from public.measurement_context_minutes t join mcm_revs o using (minute_start)
                      where t.user_id = u and t.device_id = d and (t.revision, t.computed_at) <> (o.revision, o.computed_at));
end $$;
insert into public.noop_rr_intervals (user_id, device_id, source_id, ts, "rrMs", seq, ord, "srcChannel", batch_id)
values (:'ua', :'da', :'src', extract(epoch from timestamptz '2026-09-15 16:30:30+00')::bigint, 910, 0, 0, 5, :'bat');
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da')::uuid; n integer;
begin
  n := internal.build_measurement_context_minutes(u, d, '2026-09-15 00:00:00+00', '2026-09-15 17:10:00+00');
  assert n = 1, format('one new beat re-writes one minute, wrote %s', n);
  assert (select array_agg(t.minute_start) from public.measurement_context_minutes t join mcm_revs o using (minute_start)
           where t.user_id = u and t.device_id = d and t.revision <> o.revision) = array['2026-09-15 16:30:00+00'::timestamptz];
  assert (select rr_n from public.measurement_context_minutes where user_id = u and device_id = d
           and minute_start = '2026-09-15 16:30:00+00') = 1;
  assert (select t.revision > o.revision from public.measurement_context_minutes t join mcm_revs o using (minute_start)
           where t.user_id = u and t.device_id = d and t.minute_start = '2026-09-15 16:30:00+00');
end $$;

-- 4. Backfill ---------------------------------------------------------------------------------------------------
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da2', :'src', t, 70, :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-20 18:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-20 18:09:59+00')::bigint) t;
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da2')::uuid; n integer;
begin
  n := internal.backfill_measurement_context_minutes(u, d, '2026-09-20', '2026-09-20');
  assert n = 1440, format('one local day = 1440 rows, got %s', n);
  assert (select bool_and(v.backfill) from public.measurement_context_minutes t
            join public.measurement_context_versions v on v.id = t.context_version
           where t.user_id = u and t.device_id = d and t.local_day = '2026-09-20');
  assert not exists (select 1 from public.measurement_context_minutes t
                      where t.user_id = u and t.device_id = d and t.local_day = '2026-09-20'
                        and t.missing_reasons @> '[{"code": "awaiting_upload"}]'), 'backfill never asserts awaiting_upload';
  assert (select missing_reasons -> 0 ->> 'code' from public.measurement_context_minutes
           where user_id = u and device_id = d and minute_start = '2026-09-20 20:00:00+00') = 'insufficient_coverage';
  begin
    perform internal.backfill_measurement_context_minutes(u, d, '2026-08-01', '2026-09-20');
    assert false, 'more than 31 days is refused';
  exception when raise_exception then
    assert sqlerrm = 'measurement_context_backfill_range';
  end;
  begin
    perform internal.build_measurement_context_minutes(u, current_setting('mcm.db')::uuid, now() - interval '1 hour', now());
    assert false, 'another owner''s device is refused';
  exception when raise_exception then
    assert sqlerrm = 'measurement_context_device_owner';
  end;
end $$;

-- 5. pg_cron path -----------------------------------------------------------------------------------------------
do $$
declare u uuid := current_setting('mcm.ua')::uuid; q integer; b integer;
begin
  assert exists (select 1 from cron.job where jobname = 'frwhoop-measurement-context' and schedule = '*/5 * * * *'
                   and command = 'select internal.measurement_context_tick_v1()');
  q := internal.measurement_context_discover_v1();
  assert q >= 2, format('the uploads queued their local days (%s)', q);
  assert exists (select 1 from internal.measurement_context_work where user_id = u and day = '2026-09-15'
                   and queued_at is not null);
  assert internal.measurement_context_discover_v1() = 0, 'nothing new: nothing re-queued';
  b := internal.measurement_context_process_v1(100, interval '5 minutes');
  assert b >= 2, format('built %s days', b);
  assert not exists (select 1 from internal.measurement_context_work where user_id = u and queued_at is not null),
    'queue drained';
  assert exists (select 1 from public.measurement_context_minutes where user_id = u
                   and device_id = current_setting('mcm.da')::uuid and local_day = '2026-09-14'
                   and minute_start = '2026-09-14 07:00:00+00'), 'the whole local day was built';
end $$;

-- 6. Privileges and RLS -----------------------------------------------------------------------------------------
select internal.build_measurement_context_minutes(:'ub', :'db', '2026-09-15 00:00:00+00', '2026-09-15 00:10:00+00') \g /dev/null
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'internal' and (p.proname like '%measurement_context%' or p.proname = 'exercise_session_spans_v2'))
               or (n.nspname = 'public' and p.proname like 'measurement_context%') loop
    assert not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute'),
      format('%s is executable by a client', f);
  end loop;
  assert has_function_privilege('service_role', 'public.measurement_context_minutes_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert not has_table_privilege('anon', 'public.measurement_context_minutes', 'select');
  assert not has_table_privilege('authenticated', 'public.measurement_context_minutes', 'insert');
  assert not has_table_privilege('authenticated', 'public.measurement_context_versions', 'select');
  -- Built without a trigger on any noop_* table and without the scoring gate.
  -- (The placement trigger on placement_intervals re-queues built days after a declaration, 20261009150100; no
  -- noop_* table carries a measurement-context trigger.)
  assert not exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                       join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
                      where not t.tgisinternal and p.prosrc like '%measurement_context%'
                        and n.nspname = 'public' and c.relname like 'noop\_%');
  assert not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'internal' and p.proname like '%measurement_context%'
                        and p.prosrc like '%scoring-inputs%');
end $$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ua', 'role', 'authenticated')::text, true) \g /dev/null
do $$
begin
  assert (select count(*) from public.measurement_context_minutes where user_id = current_setting('mcm.ub')::uuid) = 0,
    'A sees none of B''s minutes';
  assert (select count(*) from public.measurement_context_minutes) > 0, 'A sees its own';
  assert (select count(*) from public.measurement_context_minutes where user_id <> current_setting('mcm.ua')::uuid) = 0;
end $$;
select set_config('request.jwt.claims', json_build_object('sub', :'ub', 'role', 'authenticated')::text, true) \g /dev/null
do $$
begin
  assert (select count(*) from public.measurement_context_minutes) = 10, 'B sees exactly its 10 minutes';
end $$;
reset role;

-- The read function (service route): reasons expanded, owner and device checked, at most 1440 rows.
do $$
declare u uuid := current_setting('mcm.ua')::uuid; d uuid := current_setting('mcm.da')::uuid; r jsonb;
begin
  r := public.measurement_context_minutes_read_v1(u, d, '2026-09-15 15:00:00+00', '2026-09-15 15:10:00+00');
  assert jsonb_array_length(r -> 'rows') = 10 and (r ->> 'truncated')::boolean = false;
  assert r -> 'rows' -> 5 -> 'reasons' = '[{"code": "off_wrist", "family": "wear", "effect": "excluded", "certainty": "confirmed"}]',
    (r -> 'rows' -> 5 -> 'reasons')::text;
  assert (r -> 'rows' -> 0 ->> 'minute_start')::bigint = extract(epoch from timestamptz '2026-09-15 15:00:00+00')::bigint;
  assert not (r -> 'rows' -> 0) ? 'user_id';
  assert r -> 'versions' ? ((r -> 'rows' -> 0 ->> 'context_version'));
  r := public.measurement_context_minutes_read_v1(u, null, '2026-09-15 00:00:00+00', '2026-09-16 00:00:00+00');
  assert jsonb_array_length(r -> 'rows') = 1440;
  begin
    perform public.measurement_context_minutes_read_v1(u, d, '2026-09-15 00:00:00+00', '2026-09-16 00:01:00+00');
    assert false, 'more than 1440 minutes is refused';
  exception when raise_exception then
    assert sqlerrm = 'measurement_context_invalid_range';
  end;
  begin
    perform public.measurement_context_minutes_read_v1(u, current_setting('mcm.db')::uuid, '2026-09-15 00:00:00+00',
                                                       '2026-09-15 01:00:00+00');
    assert false, 'another owner''s device is refused';
  exception when raise_exception then
    assert sqlerrm = 'measurement_context_device_owner';
  end;
end $$;

rollback;
select 'measurement_context_minutes: ok' as result;
