-- Regression for 20261009150000_watchdog_episodes.sql. Run ONLY against an isolated, disposable full-schema
-- database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything runs in one transaction that
-- is rolled back:
--
--   PGAPPNAME=watchdog-episodes psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/watchdog_episodes.sql
--
-- (supabase/functions/tests/watchdog_episodes_sql_test.ts runs it the same way inside the pipeline container.)
--
-- Checks:
--   1. Upsert: new episodes are accepted; the same payload again writes nothing (idempotent, updated_at kept); an
--      older client_updated_at is skipped as stale and leaves the row alone; a newer one replaces it; an equal
--      timestamp with different content is the later arrival and wins. Nested objects are kept as sent.
--   2. Caps and enums: more than 50 episodes, an episode over 16 KiB, a duplicate episode id, an unknown severity
--      or delivery, an unregistered quality reason and another owner's device are refused, and nothing is written.
--   3. The read: overlap with the range, unix seconds, the device's external id, one device or all, truncation.
--   4. RLS and privileges: each owner reads only their own rows, no client writes, anon reads nothing, no client
--      executes either function.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid() as ua, gen_random_uuid() as ub, gen_random_uuid() as da, gen_random_uuid() as da2,
       gen_random_uuid() as db, gen_random_uuid() as src \gset
select set_config('wde.ua', :'ua', true), set_config('wde.ub', :'ub', true), set_config('wde.da', :'da', true),
       set_config('wde.da2', :'da2', true), set_config('wde.db', :'db', true), set_config('wde.src', :'src', true)
  \g /dev/null

do $$ begin
  assert current_setting('application_name') = 'watchdog-episodes', 'disposable-database invocation required';
end $$;

insert into auth.users (id) values (:'ua'), (:'ub');
insert into public.devices (id, user_id, source_kind, external_device_id)
values (:'da', :'ua', 'noop_push', 'whoop-WDTEST0001'), (:'da2', :'ua', 'noop_push', 'whoop-WDTEST0002'),
       (:'db', :'ub', 'noop_push', 'whoop-WDTEST0003');

create temp table wde_ep (j jsonb);
insert into wde_ep values ('{
  "episode_id": "wd-1791438841", "opened_at": 1791438841, "last_at": 1791441000, "closed_at": null,
  "max_severity": "severe", "peak_severity": "active", "safety": false, "personal_off": true,
  "notify_delivery": "sent", "live_alerts": true, "off_minute_count": 56, "unavailable_minutes": 0,
  "headline": "Heart rate higher than your usual", "event_label": "abnormal_multi_direction",
  "activity_label": "exercise_session", "contributing": ["HR"],
  "signals": [{"name": "HR", "unit": "bpm", "observed": 108, "usual": 88, "reconstructed": null, "energy": 2.4,
               "trustPct": 90, "rangeHalf": 6.5}],
  "exercise": {"rule": "exercise-session-1", "phase": "recovery", "sessionStartUnix": 1791433200,
               "sessionLastMovementUnix": 1791438600, "restReference": 66, "restBasis": "sleep_resting_hr",
               "ceilingBpm": 185, "ceilingBasis": "age_formula", "sessionReference": "learning",
               "recoveryReference": "learning", "routine": null},
  "annotation": {"episodeId": "wd-1791438841", "deviceId": "my-whoop", "eventUnix": 1791438900,
                 "enteredUnix": 1791439500, "reporter": "wearer", "status": "entered", "exertion": "hard",
                 "sensor": "just_on", "note": null},
  "quality_reasons": [{"code": "context_not_comparable", "subcode": "recovery", "certainty": "inferred"}],
  "versions": {"watchdog": "v3.1", "baseline": "lb-context-1", "exercise_rule": "exercise-session-1",
               "reason_codes": "data-reason-1"},
  "client_updated_at": 1791441210}');

-- 1. Upsert --------------------------------------------------------------------------------------------------------
do $$
declare
  u uuid := current_setting('wde.ua')::uuid; d uuid := current_setting('wde.da')::uuid;
  s uuid := current_setting('wde.src')::uuid; e jsonb; e2 jsonb; r jsonb; w public.watchdog_episodes; t0 timestamptz;
begin
  select j into e from wde_ep;
  e2 := e || '{"episode_id": "wd-1791500000", "opened_at": 1791500000, "last_at": 1791500600,
               "closed_at": 1791500700, "max_severity": "candidate", "peak_severity": null, "notify_delivery": "",
               "annotation": null, "exercise": null, "quality_reasons": null}';
  r := public.watchdog_episodes_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(e, e2));
  assert r = '{"accepted": 2, "skipped_stale": 0}', r::text;
  select * into w from public.watchdog_episodes where user_id = u and device_id = d and episode_id = 'wd-1791438841';
  assert w.opened_at = to_timestamp(1791438841) and w.last_at = to_timestamp(1791441000) and w.closed_at is null;
  assert w.max_severity = 'severe' and w.peak_severity = 'active' and not w.safety and w.personal_off;
  assert w.notify_delivery = 'sent' and w.off_minute_count = 56 and w.local_device_id = 'my-whoop' and w.source_id = s;
  assert w.verdict -> 'signals' -> 0 -> 'reconstructed' = 'null'::jsonb, 'nested nulls are kept as sent';
  assert w.context -> 'exercise' = e -> 'exercise' and w.annotation = e -> 'annotation';
  assert w.context ->> 'activity_label' = 'exercise_session';
  assert w.context -> 'quality_reasons' = e -> 'quality_reasons';
  assert w.versions ->> 'exercise_rule' = 'exercise-session-1';
  assert w.client_updated_at = to_timestamp(1791441210);
  select * into w from public.watchdog_episodes where user_id = u and device_id = d and episode_id = 'wd-1791500000';
  assert w.annotation is null and w.peak_severity is null and not (w.context ? 'exercise') and w.context = '{"activity_label": "exercise_session"}';

  -- The same payload again: nothing written.
  select updated_at into t0 from public.watchdog_episodes where episode_id = 'wd-1791438841' and user_id = u;
  r := public.watchdog_episodes_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(e, e2));
  assert r = '{"accepted": 2, "skipped_stale": 0}', r::text;
  assert (select updated_at from public.watchdog_episodes where episode_id = 'wd-1791438841' and user_id = u) = t0,
    'an identical replay does not touch the row';

  -- An older copy is skipped and changes nothing.
  r := public.watchdog_episodes_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(
         e || '{"client_updated_at": 1791441000, "notify_delivery": "queued", "closed_at": null}'));
  assert r = '{"accepted": 0, "skipped_stale": 1}', r::text;
  assert (select notify_delivery from public.watchdog_episodes where episode_id = 'wd-1791438841' and user_id = u) = 'sent';

  -- A newer copy replaces it (closed, annotation skipped).
  r := public.watchdog_episodes_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(
         e || jsonb_build_object('client_updated_at', 1791441500, 'closed_at', 1791441400,
                                 'annotation', (e -> 'annotation') || '{"status": "skipped"}')));
  assert r = '{"accepted": 1, "skipped_stale": 0}', r::text;
  select * into w from public.watchdog_episodes where user_id = u and device_id = d and episode_id = 'wd-1791438841';
  assert w.closed_at = to_timestamp(1791441400) and w.annotation ->> 'status' = 'skipped';
  assert w.client_updated_at = to_timestamp(1791441500);

  -- Same timestamp, different content: the later arrival wins.
  r := public.watchdog_episodes_upsert_v1(u, d, s, 'my-whoop', jsonb_build_array(
         e || jsonb_build_object('client_updated_at', 1791441500, 'closed_at', 1791441400, 'safety', true,
                                 'annotation', (e -> 'annotation') || '{"status": "skipped"}')));
  assert r = '{"accepted": 1, "skipped_stale": 0}', r::text;
  assert (select safety from public.watchdog_episodes where episode_id = 'wd-1791438841' and user_id = u);
  assert (select count(*) from public.watchdog_episodes where user_id = u) = 2;
end $$;

-- 2. Caps, enums and ownership --------------------------------------------------------------------------------------
do $$
declare
  u uuid := current_setting('wde.ua')::uuid; d uuid := current_setting('wde.da')::uuid;
  db uuid := current_setting('wde.db')::uuid; s uuid := current_setting('wde.src')::uuid; e jsonb; big jsonb;
  n bigint := (select count(*) from public.watchdog_episodes);
begin
  select j || '{"episode_id": "wd-cap"}' into e from wde_ep;
  e := e - 'annotation';
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null,
      (select jsonb_agg(e || jsonb_build_object('episode_id', 'wd-cap-' || i)) from generate_series(1, 51) i));
    assert false, '51 episodes are refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_episodes'; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, '[]');
    assert false, 'an empty batch is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_episodes'; end;
  big := e || jsonb_build_object('headline', repeat('x', 16400));
  assert octet_length(big::text) > 16384;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, jsonb_build_array(big));
    assert false, 'an episode over 16 KiB is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_episode'; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, jsonb_build_array(e, e));
    assert false, 'a duplicate id is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'duplicate_episode_id'; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, jsonb_build_array(e || '{"max_severity": "loud"}'));
    assert false, 'an unknown severity is refused';
  exception when check_violation then null; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, jsonb_build_array(e || '{"notify_delivery": "maybe"}'));
    assert false, 'an unknown delivery is refused';
  exception when check_violation then null; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null, jsonb_build_array(e || '{"last_at": 1791438000}'));
    assert false, 'last_at before opened_at is refused';
  exception when check_violation then null; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, d, s, null,
      jsonb_build_array(e || '{"quality_reasons": [{"code": "gym", "certainty": "inferred"}]}'));
    assert false, 'an unregistered reason code is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_quality_reasons'; end;
  begin
    perform public.watchdog_episodes_upsert_v1(u, db, s, null, jsonb_build_array(e));
    assert false, 'another owner''s device is refused';
  exception when insufficient_privilege then assert sqlerrm = 'device_owner_mismatch'; end;
  assert (select count(*) from public.watchdog_episodes) = n, 'a refused batch writes nothing';
  -- A batch of exactly 50 at the size limit is fine.
  assert (public.watchdog_episodes_upsert_v1(u, current_setting('wde.da2')::uuid, s, null,
           (select jsonb_agg(e || jsonb_build_object('episode_id', 'wd-50-' || i, 'opened_at', 1791438841 + i * 60,
                                                     'last_at', 1791438841 + i * 60))
              from generate_series(1, 50) i)) ->> 'accepted')::integer = 50;
end $$;

-- 3. The read -------------------------------------------------------------------------------------------------------
do $$
declare
  u uuid := current_setting('wde.ua')::uuid; d uuid := current_setting('wde.da')::uuid; r jsonb; ep jsonb;
begin
  r := public.watchdog_episodes_read_v1(u, d, to_timestamp(1791438000), to_timestamp(1791440000));
  assert (r ->> 'truncated')::boolean = false and jsonb_array_length(r -> 'episodes') = 1, r::text;
  ep := r -> 'episodes' -> 0;
  assert ep ->> 'episode_id' = 'wd-1791438841' and ep ->> 'device_id' = 'whoop-WDTEST0001';
  assert (ep ->> 'opened_at')::bigint = 1791438841 and (ep ->> 'closed_at')::bigint = 1791441400;
  assert (ep ->> 'client_updated_at')::bigint = 1791441500 and ep ->> 'local_device_id' = 'my-whoop';
  assert ep -> 'annotation' ->> 'exertion' = 'hard' and ep -> 'exercise' ->> 'phase' = 'recovery';
  assert ep -> 'signals' -> 0 ->> 'name' = 'HR' and ep -> 'contributing' = '["HR"]';
  assert ep -> 'quality_reasons' -> 0 ->> 'subcode' = 'recovery';
  assert not ep ? 'user_id';
  -- An episode still open counts until its last tick; one that ended before the range does not.
  r := public.watchdog_episodes_read_v1(u, d, to_timestamp(1791441450), to_timestamp(1791600000));
  assert jsonb_array_length(r -> 'episodes') = 1 and r -> 'episodes' -> 0 ->> 'episode_id' = 'wd-1791500000', r::text;
  -- Every device of the owner, truncated at the limit.
  r := public.watchdog_episodes_read_v1(u, null, to_timestamp(1791400000), to_timestamp(1791600000), 10);
  assert jsonb_array_length(r -> 'episodes') = 10 and (r ->> 'truncated')::boolean, r::text;
  r := public.watchdog_episodes_read_v1(u, null, to_timestamp(1791400000), to_timestamp(1791600000));
  assert jsonb_array_length(r -> 'episodes') = 52 and not (r ->> 'truncated')::boolean;
  assert (r -> 'episodes' -> 0 ->> 'opened_at')::bigint <= (r -> 'episodes' -> 51 ->> 'opened_at')::bigint;
  begin
    perform public.watchdog_episodes_read_v1(u, current_setting('wde.db')::uuid, to_timestamp(0), to_timestamp(1));
    assert false, 'another owner''s device is refused';
  exception when insufficient_privilege then assert sqlerrm = 'device_owner_mismatch'; end;
  begin
    perform public.watchdog_episodes_read_v1(u, d, to_timestamp(10), to_timestamp(10));
    assert false, 'an empty range is refused';
  exception when invalid_parameter_value then assert sqlerrm = 'invalid_range'; end;
end $$;

-- 4. RLS and privileges ---------------------------------------------------------------------------------------------
insert into public.watchdog_episodes (user_id, device_id, episode_id, opened_at, last_at, max_severity,
                                      client_updated_at)
values (:'ub', :'db', 'wd-b', to_timestamp(1791438841), to_timestamp(1791438900), 'active', now());

do $$ begin
  assert not has_table_privilege('anon', 'public.watchdog_episodes', 'select');
  assert not has_table_privilege('authenticated', 'public.watchdog_episodes', 'insert');
  assert not has_table_privilege('authenticated', 'public.watchdog_episodes', 'update');
  assert not has_table_privilege('authenticated', 'public.watchdog_episodes', 'delete');
  assert has_table_privilege('authenticated', 'public.watchdog_episodes', 'select');
  assert not has_function_privilege('authenticated', 'public.watchdog_episodes_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('anon', 'public.watchdog_episodes_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('authenticated',
    'public.watchdog_episodes_read_v1(uuid,uuid,timestamptz,timestamptz,integer)', 'execute');
  assert has_function_privilege('service_role', 'public.watchdog_episodes_upsert_v1(uuid,uuid,uuid,text,jsonb)', 'execute');
  assert has_function_privilege('service_role',
    'public.watchdog_episodes_read_v1(uuid,uuid,timestamptz,timestamptz,integer)', 'execute');
end $$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ua', 'role', 'authenticated')::text, true) \g /dev/null
do $$
begin
  assert (select count(*) from public.watchdog_episodes) = 52, 'A sees its own 52 episodes';
  assert (select count(*) from public.watchdog_episodes where user_id = current_setting('wde.ub')::uuid) = 0,
    'A sees none of B''s';
  begin
    insert into public.watchdog_episodes (user_id, device_id, episode_id, opened_at, last_at, max_severity,
                                          client_updated_at)
    values (current_setting('wde.ua')::uuid, current_setting('wde.da')::uuid, 'wd-direct', now(), now(), 'active', now());
    assert false, 'a client cannot write directly';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', json_build_object('sub', :'ub', 'role', 'authenticated')::text, true) \g /dev/null
do $$ begin
  assert (select count(*) from public.watchdog_episodes) = 1, 'B sees exactly its one episode';
end $$;
reset role;
set local role anon;
do $$ begin
  begin
    perform count(*) from public.watchdog_episodes;
    assert false, 'anon reads nothing';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

rollback;
select 'watchdog_episodes: ok' as result;
