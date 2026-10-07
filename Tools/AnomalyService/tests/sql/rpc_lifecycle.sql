-- Exercises the anomaly RPCs against prod_stubs.sql + the migration (tests only). Raises on any failure.
\set ON_ERROR_STOP 1
insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
insert into public.devices values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'whoop'),
                                  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'whoop');
insert into public.scoring_jobs_v2 (user_id, device_id, day, algorithm_version, completed_revision, last_completed_at)
values ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', (now() at time zone 'UTC')::date,
        'frwhoop-server-1', 3, now() - interval '1 minute');
do $$
declare n integer; j public.anomaly_jobs; r bigint; c integer;
begin
  n := public.enqueue_anomaly_jobs_v1(10);
  if n <> 1 then raise exception 'enqueue expected 1 got %', n; end if;
  -- same completion again: no bump
  n := public.enqueue_anomaly_jobs_v1(10);
  if n <> 0 then raise exception 'idempotent enqueue expected 0 got %', n; end if;
  select * into j from public.claim_anomaly_job_v1(600);
  if j.lease_token is null then raise exception 'claim failed'; end if;
  if not public.renew_anomaly_job_v1(j.lease_token, 600) then raise exception 'renew failed'; end if;
  r := public.publish_anomaly_result_v1(j.lease_token, j.input_revision, jsonb_build_object(
    'scored_from', now() - interval '2 hours', 'scored_to', now(), 'worker', 'test', 'run_ms', 12,
    'candidates', jsonb_build_array(
      jsonb_build_object('candidate_key', 'joint:beat:1', 'start_ts', now() - interval '60 minutes', 'end_ts', now() - interval '30 minutes',
        'local_day', (now())::date, 'channels', jsonb_build_array('HR','HRV'), 'flagged_by', jsonb_build_array('timesfm-3.0','units-x128'),
        'model_p', jsonb_build_object('timesfm-3.0', 0.0001, 'units-x128', 0.0004), 'score', 4.2, 'severity', 'strong', 'direction', 1),
      jsonb_build_object('candidate_key', 'joint:thermal:1', 'start_ts', now() - interval '50 minutes', 'end_ts', now() - interval '20 minutes',
        'local_day', (now())::date, 'channels', jsonb_build_array('Temp'), 'flagged_by', jsonb_build_array('units-x128'),
        'model_p', jsonb_build_object('units-x128', 0.0008), 'score', 3.1, 'severity', 'candidate', 'direction', 1)),
    'window_scores', jsonb_build_array(jsonb_build_object('window_start', now() - interval '60 minutes', 'window_end', now() - interval '45 minutes',
        'channel_group', 'beat_stream', 'model', 'timesfm-3.0', 'score', 4.2, 'p', 0.0001, 'context_kind', 'awake_still', 'usable', true))));
  if r <> 2 then raise exception 'publish expected 2 got %', r; end if;
  select count(*) into c from public.anomaly_candidates where status = 'candidate';
  if c <> 2 then raise exception 'expected 2 candidates got %', c; end if;
  -- stale worker: same token after completion → null, nothing written
  r := public.publish_anomaly_result_v1(j.lease_token, j.input_revision, '{"scored_from":"2026-01-01","scored_to":"2026-01-02","candidates":[],"window_scores":[]}');
  if r is not null then raise exception 'fence failed: %', r; end if;
  -- new scoring completion → bump only after the throttle interval; force with 0 interval
  update public.scoring_jobs_v2 set last_completed_at = now() where user_id = '11111111-1111-1111-1111-111111111111';
  n := public.enqueue_anomaly_jobs_v1(10, interval '10 minutes');
  if n <> 0 then raise exception 'throttle expected 0 got %', n; end if;
  update public.anomaly_jobs set last_completed_at = now() - interval '11 minutes';
  n := public.enqueue_anomaly_jobs_v1(10, interval '10 minutes');
  if n <> 1 then raise exception 'bump expected 1 got %', n; end if;
  update public.anomaly_jobs set not_before = now();
  select * into j from public.claim_anomaly_job_v1(600);
  -- re-score keeps only the beat candidate → thermal retracted
  r := public.publish_anomaly_result_v1(j.lease_token, j.input_revision, jsonb_build_object(
    'scored_from', now() - interval '2 hours', 'scored_to', now(), 'worker', 'test', 'run_ms', 9,
    'candidates', jsonb_build_array(jsonb_build_object('candidate_key', 'joint:beat:1', 'start_ts', now() - interval '60 minutes',
        'end_ts', now() - interval '25 minutes', 'local_day', (now())::date, 'channels', jsonb_build_array('HR','HRV'),
        'flagged_by', jsonb_build_array('timesfm-3.0','units-x128'), 'model_p', '{}'::jsonb, 'score', 4.5, 'severity', 'strong', 'direction', 1)),
    'window_scores', '[]'::jsonb));
  select count(*) into c from public.anomaly_candidates where status = 'retracted' and candidate_key = 'joint:thermal:1';
  if c <> 1 then raise exception 'retraction failed'; end if;
  perform public.anomaly_service_heartbeat_v1('frwhoop-anomaly', '{"source_revision":"test","models":{"timesfm-3.0":"sha"},"counters":{"published":2}}');
  select count(*) into c from public.anomaly_service_heartbeats;
  if c <> 1 then raise exception 'heartbeat failed'; end if;
  perform public.fail_anomaly_job_v1(gen_random_uuid(), 1, 'noop');
end $$;
-- RLS: the other user sees nothing; the owner sees their rows.
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$ declare c integer; begin select count(*) into c from public.anomaly_candidates; if c <> 0 then raise exception 'rls leak %', c; end if; end $$;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$ declare c integer; begin select count(*) into c from public.anomaly_candidates; if c <> 2 then raise exception 'owner sees % rows', c; end if; end $$;
reset role;
select 'RPC-LIFECYCLE-OK';
