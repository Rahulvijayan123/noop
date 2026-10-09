-- Regression for 20261009130200_measurement_context_quality_minutes.sql (POST scores/quality-minutes). Run ONLY
-- against an isolated, disposable full-schema database (e.g. supabase/tests/e2e/pipeline_db.sh); one transaction,
-- rolled back:
--
--   PGAPPNAME=measurement-context-quality psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 \
--     -f supabase/tests/measurement_context_quality_minutes.sql
--
-- Checks: the phone's evidence lands in the PHONE columns and re-derives quality and missing reasons (grades,
-- canonical reasons from legacy watchdog_quality codes, unknown codes kept raw, paused / lost gaps); a minute with
-- no row yet is built first; the same payload again changes nothing; a rebuild keeps the phone's columns; malformed
-- payloads, duplicates, spans over 3 days, future minutes and another owner's device are refused; no client can
-- execute it.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid() as ua, gen_random_uuid() as ub, gen_random_uuid() as da, gen_random_uuid() as db,
       gen_random_uuid() as src, gen_random_uuid() as bat \gset
select set_config('mcq.ua', :'ua', true), set_config('mcq.ub', :'ub', true), set_config('mcq.da', :'da', true),
       set_config('mcq.db', :'db', true) \g /dev/null
insert into auth.users (id) values (:'ua'), (:'ub');
delete from public.scoring_timezone_history where user_id in (:'ua', :'ub');
insert into public.scoring_timezone_history (user_id, effective_at, timezone_id, provenance)
values (:'ua', '-infinity', 'America/Los_Angeles', 'initial_profile'), (:'ub', '-infinity', 'UTC', 'initial_profile');
insert into public.devices (id, user_id, source_kind) values (:'da', :'ua', 'noop_push'), (:'db', :'ub', 'noop_push');

-- Still minutes with heart rate and no beats 12:00-12:30Z on 2026-09-16, nothing 12:30-12:40, then HR to 12:50.
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'ua', :'da', :'src', t, 64, :'bat'
  from (select generate_series(extract(epoch from timestamptz '2026-09-16 12:00:00+00')::bigint,
                               extract(epoch from timestamptz '2026-09-16 12:29:59+00')::bigint) t
        union all
        select generate_series(extract(epoch from timestamptz '2026-09-16 12:40:00+00')::bigint,
                               extract(epoch from timestamptz '2026-09-16 12:49:59+00')::bigint)) x;
insert into public.noop_gravity_samples (user_id, device_id, source_id, ts, x, y, z, "dynAccel", batch_id)
select :'ua', :'da', :'src', t, 0, 0, 1, 0.01, :'bat'
  from generate_series(extract(epoch from timestamptz '2026-09-16 12:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-09-16 12:49:59+00')::bigint) t;
-- Built up to 12:20 only: 12:20-12:50 has no rows yet.
select internal.build_measurement_context_minutes(:'ua', :'da', '2026-09-16 12:00:00+00', '2026-09-16 12:20:00+00')
  \g /dev/null

create or replace function pg_temp.mq(p_at timestamptz) returns public.measurement_context_minutes
language sql as $$
  select t from public.measurement_context_minutes t
   where t.user_id = current_setting('mcq.ua')::uuid and t.device_id = current_setting('mcq.da')::uuid
     and t.minute_start = p_at
$$;
create or replace function pg_temp.unix(p_at timestamptz) returns bigint language sql as $$
  select extract(epoch from p_at)::bigint $$;

do $$
declare u uuid := current_setting('mcq.ua')::uuid; d uuid := current_setting('mcq.da')::uuid; r public.measurement_context_minutes;
  out jsonb; payload jsonb; rev_before bigint; rev_after bigint;
begin
  assert current_setting('application_name') = 'measurement-context-quality', 'disposable-database invocation required';
  r := pg_temp.mq('2026-09-16 12:05:00+00');
  assert r.quality_class = 'fair' and r.v18_n is null, 'before the phone: no beats, fair';
  assert pg_temp.mq('2026-09-16 12:25:00+00') is null, 'not built yet';

  payload := jsonb_build_array(
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:05:00+00'), 'v18_n', 60, 'sentinel_n', 2,
                       'baseline_max', 31, 'record_gap', null, 'hr_grade', 'good', 'beats_grade', 'good', 'reasons', '[]'::jsonb),
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:06:00+00'), 'v18_n', 60, 'sentinel_n', 50,
                       'baseline_max', 140, 'hr_grade', 'poor', 'beats_grade', 'poor',
                       'reasons', '["motion_mode_optics", "beat_coverage_low", "a_future_code"]'::jsonb),
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:07:00+00'), 'v18_n', 60, 'sentinel_n', 0,
                       'baseline_max', 25, 'hr_grade', 'degraded', 'beats_grade', 'good',
                       'reasons', '["settling_after_wrist_on"]'::jsonb, 'some_new_field', 1),
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:32:00+00'), 'v18_n', 0, 'sentinel_n', 0,
                       'baseline_max', null, 'record_gap', 'paused', 'hr_grade', null, 'beats_grade', null,
                       'reasons', '["strap_not_recording"]'::jsonb),
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:35:00+00'), 'record_gap', 'lost',
                       'reasons', '["transport_gap"]'::jsonb),
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:45:00+00'), 'v18_n', 60, 'sentinel_n', 1,
                       'hr_grade', 'good'));
  out := public.measurement_context_quality_upsert_v1(u, d, 'phone-quality-1', payload);
  assert out = '{"accepted": 6, "changed": 6}', out::text;

  r := pg_temp.mq('2026-09-16 12:05:00+00');
  assert r.v18_n = 60 and r.sentinel_n = 2 and r.baseline_max = 31 and r.hr_grade = 'good'
     and r.phone_quality_version = 'phone-quality-1' and r.phone_reasons = '{}';
  assert r.quality_class = 'good' and r.quality_conf::numeric = 0.9 and r.reasons = '[]', format('%s %s', r.quality_class, r.reasons);
  r := pg_temp.mq('2026-09-16 12:06:00+00');
  assert r.quality_class = 'poor' and r.phone_reasons = '{motion_mode_optics,beat_coverage_low,a_future_code}';
  assert r.reasons = '[{"code": "motion_artifact", "certainty": "inferred"}, {"code": "insufficient_coverage", "certainty": "measured"}]',
    r.reasons::text;
  r := pg_temp.mq('2026-09-16 12:07:00+00');
  assert r.quality_class = 'fair' and r.reasons = '[{"code": "just_put_on", "certainty": "confirmed"}]', r.reasons::text;
  r := pg_temp.mq('2026-09-16 12:32:00+00');
  assert r.hr_n = 0 and r.record_gap = 'paused' and r.quality_class = 'off_wrist' and r.quality_conf::numeric = 0.8;
  assert r.missing_reasons -> 0 = '{"code": "strap_not_recording", "certainty": "confirmed"}', r.missing_reasons::text;
  r := pg_temp.mq('2026-09-16 12:35:00+00');
  assert r.hr_n = 0 and r.quality_class = 'unknown'
     and r.missing_reasons -> 0 = '{"code": "awaiting_upload", "certainty": "inferred"}', r.missing_reasons::text;
  assert r.reasons @> '[{"code": "awaiting_upload", "certainty": "inferred"}]';
  r := pg_temp.mq('2026-09-16 12:45:00+00');
  assert r.hr_n = 60 and r.quality_class = 'good', 'a minute with no row was built, then graded';

  -- Idempotent: the same payload changes nothing, revisions included.
  select max(revision) into rev_before from public.measurement_context_minutes where user_id = u;
  out := public.measurement_context_quality_upsert_v1(u, d, 'phone-quality-1', payload);
  assert out = '{"accepted": 6, "changed": 0}', out::text;
  select max(revision) into rev_after from public.measurement_context_minutes where user_id = u;
  assert rev_after = rev_before, 'no revision bump on a replay';
  -- A rebuild keeps the phone's columns and their effect.
  -- (the re-derivation after the upload rebuilt 12:05-12:46, so 12:00-12:46 is all built now)
  assert internal.build_measurement_context_minutes(u, d, '2026-09-16 12:00:00+00', '2026-09-16 12:46:00+00') = 0;
  assert (pg_temp.mq('2026-09-16 12:05:00+00')).quality_class = 'good';
  -- One minute changed: only it moves.
  out := public.measurement_context_quality_upsert_v1(u, d, 'phone-quality-1', jsonb_build_array(
    jsonb_build_object('minute_start', pg_temp.unix('2026-09-16 12:05:00+00'), 'v18_n', 60, 'sentinel_n', 30,
                       'baseline_max', 31, 'hr_grade', 'degraded', 'beats_grade', 'poor', 'reasons', '["optical_sentinel"]'::jsonb)));
  assert out = '{"accepted": 1, "changed": 1}', out::text;
  r := pg_temp.mq('2026-09-16 12:05:00+00');
  assert r.quality_class = 'fair' and r.reasons = '[{"code": "motion_artifact", "certainty": "inferred"}]' and r.revision > rev_after;
  assert (select count(*) from public.measurement_context_minutes where user_id = u and revision > rev_after) = 1;
end $$;

-- Refusals.
do $$
declare u uuid := current_setting('mcq.ua')::uuid; d uuid := current_setting('mcq.da')::uuid; bad jsonb; m bigint;
  now_m bigint := extract(epoch from now())::bigint - extract(epoch from now())::bigint % 60;
begin
  m := pg_temp.unix('2026-09-16 12:05:00+00');
  foreach bad in array array[
    '[]'::jsonb, '{}'::jsonb, '[1]'::jsonb,
    jsonb_build_array(jsonb_build_object('minute_start', m + 30)),
    jsonb_build_array(jsonb_build_object('minute_start', m::text)),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'v18_n', 121)),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'v18_n', 10, 'sentinel_n', 11)),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'v18_n', 1.5)),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'record_gap', 'gone')),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'hr_grade', 'fair')),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'reasons', '["Bad-Code"]'::jsonb)),
    jsonb_build_array(jsonb_build_object('minute_start', m, 'reasons', '"motion_mode_optics"'::jsonb)),
    jsonb_build_array(jsonb_build_object('minute_start', m), jsonb_build_object('minute_start', m)),
    jsonb_build_array(jsonb_build_object('minute_start', m), jsonb_build_object('minute_start', m + 3 * 86400)),
    jsonb_build_array(jsonb_build_object('minute_start', now_m + 3600))] loop
    begin
      perform public.measurement_context_quality_upsert_v1(u, d, 'phone-quality-1', bad);
      assert false, format('accepted %s', bad);
    exception when raise_exception then
      assert sqlerrm = 'invalid_quality_minutes', format('%s: %s', bad, sqlerrm);
    end;
  end loop;
  begin
    perform public.measurement_context_quality_upsert_v1(u, d, 'bad version!', jsonb_build_array(jsonb_build_object('minute_start', m)));
    assert false, 'bad version accepted';
  exception when raise_exception then
    assert sqlerrm = 'invalid_quality_minutes';
  end;
  begin
    perform public.measurement_context_quality_upsert_v1(u, current_setting('mcq.db')::uuid, 'phone-quality-1',
      jsonb_build_array(jsonb_build_object('minute_start', m)));
    assert false, 'another owner''s device accepted';
  exception when raise_exception then
    assert sqlerrm = 'measurement_context_device_owner';
  end;
  assert not has_function_privilege('authenticated', 'public.measurement_context_quality_upsert_v1(uuid,uuid,text,jsonb)', 'execute');
  assert not has_function_privilege('anon', 'public.measurement_context_quality_upsert_v1(uuid,uuid,text,jsonb)', 'execute');
  assert has_function_privilege('service_role', 'public.measurement_context_quality_upsert_v1(uuid,uuid,text,jsonb)', 'execute');
  assert (select count(*) from public.measurement_context_minutes where user_id = current_setting('mcq.ub')::uuid) = 0;
end $$;

rollback;
select 'measurement_context_quality_minutes: ok' as result;
