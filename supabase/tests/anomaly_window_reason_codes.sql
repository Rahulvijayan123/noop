-- Regression for 20261009140100_anomaly_window_reason_codes.sql. Run ONLY against an isolated, disposable
-- full-schema database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh); it commits a synthetic
-- owner and removes it at the end.
--
--   PGAPPNAME=anomaly-window-reason-codes psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 \
--     -f supabase/tests/anomaly_window_reason_codes.sql
--
-- Checks: (1) the SQL mapping equals contracts/reason-codes.json legacy.anomaly_withheld (the expected rows below
-- are that table); (2) publish stores the reason the service sends; (3) a payload without reason fields (a service
-- released before the change) gets the mapped code; (4) a scored window row has none; (5) the check constraints
-- refuse a malformed code or certainty; (6) the migration re-applies cleanly (run it twice; see the deploy notes).
\set ON_ERROR_STOP on

select gen_random_uuid() as u, gen_random_uuid() as d, gen_random_uuid() as tok \gset
select set_config('awrc.u', :'u', false), set_config('awrc.d', :'d', false), set_config('awrc.tok', :'tok', false);

begin;
do $$
declare u uuid := current_setting('awrc.u')::uuid; d uuid := current_setting('awrc.d')::uuid;
  tok uuid := current_setting('awrc.tok')::uuid; r bigint; c integer; rec record;
begin
  assert current_setting('application_name') = 'anomaly-window-reason-codes', 'disposable-database invocation required';

  -- (1) mapping = contracts/reason-codes.json legacy.anomaly_withheld
  for rec in select * from (values
      ('off_wrist', 'off_wrist', 'inferred'), ('low_hr_coverage', 'insufficient_coverage', 'measured'),
      ('activity', 'context_not_comparable/movement', 'inferred'),
      ('recovery', 'context_not_comparable/recovery', 'inferred'),
      ('context_unknown', 'context_unknown', 'unknown'), ('calibrating', 'learning', 'measured')) e(reason, code, cert)
  loop
    assert (select (m.code, m.certainty) = (rec.code, rec.cert) from internal.anomaly_withheld_reason(rec.reason) m),
      format('mapping for %s', rec.reason);
  end loop;
  assert (select m.code is null from internal.anomaly_withheld_reason('no_such_reason') m), 'unknown reason maps to null';

  insert into auth.users(id) values (u);
  insert into public.devices(id, user_id, source_kind) values (d, u, 'whoop');
  insert into public.anomaly_jobs(user_id, device_id, input_revision, lease_token, lease_until)
  values (u, d, 1, tok, clock_timestamp() + interval '10 minutes');

  r := public.publish_anomaly_result_v1(tok, 1, jsonb_build_object(
    'scored_from', '2026-10-08T06:00:00Z', 'scored_to', '2026-10-08T08:00:00Z', 'worker', 'sql-test', 'run_ms', 1,
    'candidates', '[]'::jsonb,
    'window_scores', jsonb_build_array(
      -- (2) the new service sends the canonical reason
      jsonb_build_object('window_start', '2026-10-08T06:30:00Z', 'window_end', '2026-10-08T07:00:00Z',
        'channel_group', 'all', 'model', 'none', 'context_kind', 'rest', 'usable', false,
        'withheld_reason', 'recovery', 'reason_code', 'context_not_comparable/recovery', 'reason_certainty', 'inferred'),
      -- (3) an old service sends withheld_reason only
      jsonb_build_object('window_start', '2026-10-08T06:00:00Z', 'window_end', '2026-10-08T06:30:00Z',
        'channel_group', 'all', 'model', 'none', 'context_kind', 'rest', 'usable', false, 'withheld_reason', 'activity'),
      jsonb_build_object('window_start', '2026-10-08T07:00:00Z', 'window_end', '2026-10-08T07:30:00Z',
        'channel_group', 'all', 'model', 'timesfm-3.0', 'score', 1.2, 'p', 0.4, 'context_kind', 'rest',
        'usable', true, 'withheld_reason', 'calibrating'),
      -- (4) a scored window
      jsonb_build_object('window_start', '2026-10-08T07:30:00Z', 'window_end', '2026-10-08T08:00:00Z',
        'channel_group', 'all', 'model', 'timesfm-3.0', 'score', 0.3, 'p', 0.6, 'context_kind', 'rest',
        'usable', true))));
  assert r = 0, format('publish returned %s', r);

  select count(*) into c from public.anomaly_window_scores where user_id = u;
  assert c = 4, format('expected 4 window rows, got %s', c);
  assert (select (reason_code, reason_certainty) = ('context_not_comparable/recovery', 'inferred')
            from public.anomaly_window_scores where user_id = u and window_start = '2026-10-08T06:30:00Z'), 'sent code';
  assert (select (reason_code, reason_certainty, withheld_reason) = ('context_not_comparable/movement', 'inferred', 'activity')
            from public.anomaly_window_scores where user_id = u and window_start = '2026-10-08T06:00:00Z'), 'mapped code';
  assert (select (reason_code, reason_certainty) = ('learning', 'measured')
            from public.anomaly_window_scores where user_id = u and window_start = '2026-10-08T07:00:00Z'), 'calibrating';
  assert (select reason_code is null and reason_certainty is null
            from public.anomaly_window_scores where user_id = u and window_start = '2026-10-08T07:30:00Z'), 'scored';
  assert (select completed_revision = 1 and lease_token is null from public.anomaly_jobs where user_id = u), 'job done';

  -- (5) constraints
  begin
    update public.anomaly_window_scores set reason_code = 'Context Not Comparable' where user_id = u;
    raise exception 'malformed reason_code accepted';
  exception when check_violation then null;
  end;
  begin
    update public.anomaly_window_scores set reason_certainty = 'probably' where user_id = u;
    raise exception 'unknown certainty accepted';
  exception when check_violation then null;
  end;
end $$;
commit;

-- Cleanup (cascades to devices, anomaly_jobs and anomaly_window_scores).
delete from auth.users where id = :'u';
select 'anomaly_window_reason_codes: ok' as result;
