-- G7 diagnostics: extend server_pipeline_diagnostics with day bounds/zone, stream
-- status + coverage + largest gap, scoring_jobs_v2 queue age, projection revision,
-- durable-acceptance vs verified-archival, and explicit blockers.
--
-- Replace-only (same signature as 20260921101000), additive fields only, schema_version 2.
-- The route and auth remain exactly as before: service_role RPC, owner/installation
-- enforced inside the function, no new auth paths.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.server_pipeline_diagnostics(p_user uuid,p_source uuid,p_device uuid,p_day date)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare
  selected jsonb; selected_features jsonb; publications jsonb; workers jsonb;
  receipts integer; objects integer; projection_pending integer; projection_failed integer;
  projection_oldest timestamptz; truncated boolean;
  work jsonb; claimed boolean; computed boolean; selected_ready boolean;
  segments jsonb; zone text; zone_source text;
  streams jsonb; coverage jsonb; largest_gap jsonb; gap_stream text; gap_seconds bigint;
  v2_pending integer; v2_dead integer; v2_suppressed integer; v2_eligible integer;
  v2_input bigint; v2_completed bigint; v2_oldest_dirty timestamptz; v2_oldest_eligible timestamptz; v2_next timestamptz;
  v2_dirty_age bigint; v2_eligible_age bigint;
  v2_status text;
  durable_published integer; archive_verified integer; archive_oldest_age numeric;
  archive_statuses jsonb; archive_jobs jsonb;
  req_revision bigint; pub_revision bigint; projection_behind boolean; projection_status text;
  worker_ok boolean := false; worker_stale boolean := false;
  blockers jsonb := '[]'::jsonb; blocker record;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user)
    or not exists(select 1 from public.noop_app_installations
      where user_id=p_user and source_id=p_source and revoked_at is null) then
    raise exception 'owned installation and device required' using errcode='42501';
  end if;
  selected := public.server_scoring_for_device_day(p_user,p_day,p_device);
  select jsonb_object_agg(key,value-array['device_id','day_intervals','context_intervals','timezone_ids'])
    into selected_features from jsonb_each(selected->'features');
  select count(*) into receipts from (select 1 from public.noop_upload_receipts r
    where r.user_id=p_user and r.source_id=p_source and r.device_id=p_device
      and exists(select 1 from public.scoring_day_segments(p_user,p_day) s
        where extract(epoch from r.accepted_at)>=s.start_ts and extract(epoch from r.accepted_at)<s.end_ts)
    limit 1001) bounded;
  with bounded as (
    select m.id from public.object_manifests m where m.user_id=p_user and m.device_id=p_device
      and m.source_id=p_source and m.object_class='raw' and m.period_day=p_day and m.format like 'ndjson%'
      and m.status not in ('deleted','deleting','expired') order by m.created_at,m.id limit 1001
  ) select count(*),count(*) filter(where d.state is distinct from 'complete'),
      count(*) filter(where d.state is distinct from 'complete' and d.failures>0),
      min(d.created_at) filter(where d.state is distinct from 'complete')
    into objects,projection_pending,projection_failed,projection_oldest
    from bounded m left join public.noop_projection_debt d on d.object_id=m.id;
  truncated := receipts>=1001 or objects>=1001;
  select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) into work from (
    select 'frwhoop-physiology-2'::text algorithm_version,input_revision,status,
      claimed_at,lease_expires_at,consecutive_failures,next_attempt_at,dirty_at
      from public.physiology_work_items where user_id=p_user and device_id=p_device and day=p_day
    union all
    select 'frwhoop-server-1',input_revision,status,claimed_at,lease_expires_at,
      consecutive_failures,next_attempt_at,dirty_at
      from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day
  ) q;
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into publications from (
    select distinct on(algorithm_version) algorithm_version,input_revision,computed_at,manifest_hash
    from public.server_physiology_results where user_id=p_user and device_id=p_device and period_day=p_day
    order by algorithm_version,input_revision desc limit 32
  ) r;
  select coalesce(jsonb_agg(to_jsonb(w)),'[]'::jsonb) into workers from (
    select distinct on(h.algorithm_version) h.algorithm_version,h.worker_instance_id,h.process_instance_id,
      h.source_revision,h.started_at,h.last_poll_at,h.last_score_at,
      case when h.last_poll_at is null then 'never_polled'
        when h.last_poll_at<now()-interval '2 minutes' then 'stale' else 'polling' end status
    from public.physiology_worker_heartbeats h where h.algorithm_version in (
      select value->>'algorithm_version' from jsonb_each(selected->'features'))
    order by h.algorithm_version,h.started_at desc limit 32
  ) w;
  claimed := exists(select 1 from jsonb_array_elements(work) q where q->>'status'='running');
  computed := jsonb_array_length(publications)>0;
  selected_ready := exists(select 1 from jsonb_each(selected->'features') f where f.value->>'status' in ('available','stale'));
  -- Worker liveness used for the blockers list.
  select coalesce(bool_or(w->>'status'='polling'),false),
         coalesce(bool_or(w->>'status'='stale' or w->>'status'='never_polled'),false)
    into worker_ok,worker_stale from jsonb_array_elements(workers) w;

  -- Day bounds + zone policy: the canonical scoring_day_segments primitive (half-open [start,end)).
  select coalesce(jsonb_agg(jsonb_build_object('start_ts',s.start_ts,'end_ts',s.end_ts,'timezone_id',s.timezone_id)
      order by s.start_ts),'[]'::jsonb), min(s.timezone_id) into segments,zone
    from public.scoring_day_segments(p_user,p_day) s;
  zone := coalesce(zone,(selected->'features'->'sleep'->>'timezone_id'),
    (selected->'features'->'hrv'->>'timezone_id'));
  zone_source := case when zone is not null then 'scoring_day_segments' else 'not_measured' end;
  zone := coalesce(zone,'not_measured');

  -- Streams: per-stream signal-window summary + the published snapshot coverage + largest gap.
  with bounded as (
    select w.stream,w.start_ts,w.end_ts,w.received_records,w.expected_records,
      w.coverage as cov,
      max(w.end_ts) over (partition by w.stream order by w.start_ts
        rows between unbounded preceding and 1 preceding) as prev_end
    from public.noop_signal_windows w
    where w.user_id=p_user and w.device_id=p_device
      and exists(select 1 from public.scoring_day_segments(p_user,p_day) s
        where w.start_ts<s.end_ts and w.end_ts>s.start_ts)
  ), gaps as (
    select stream,greatest(0,b.start_ts-b.prev_end) as gap from bounded b where b.prev_end is not null
  ) select coalesce(jsonb_object_agg(g.stream,
        jsonb_build_object('windows',g.windows,'received_records',g.received,
          'expected_records',g.expected,'mean_coverage',round(g.mean::numeric,4),'last_valid_ts',g.last_valid)
        order by g.stream),'{}'::jsonb)
    into streams from (
      select stream,count(*) windows,sum(received_records) received,
        sum(coalesce(expected_records,0)) expected,avg(cov) mean,max(end_ts) last_valid
      from bounded group by stream
    ) g;
  with gaps as (
    select stream,max(greatest(0,b.start_ts-b.prev_end)) as gap from (
      select w.stream,w.start_ts,
        max(w.end_ts) over (partition by w.stream order by w.start_ts
          rows between unbounded preceding and 1 preceding) as prev_end
      from public.noop_signal_windows w
      where w.user_id=p_user and w.device_id=p_device
        and exists(select 1 from public.scoring_day_segments(p_user,p_day) s
          where w.start_ts<s.end_ts and w.end_ts>s.start_ts)
    ) b where b.prev_end is not null group by stream
  ) select coalesce(jsonb_object_agg(stream,gap),'{}'::jsonb) into largest_gap from gaps;
  select key,(value->>0)::bigint into gap_stream,gap_seconds
    from jsonb_each(coalesce(largest_gap,'{}'::jsonb))
    order by (value->>0)::bigint desc limit 1;
  -- The published snapshot's own coverage object (what scoring actually saw), latest per algorithm.
  select coalesce(jsonb_object_agg(algorithm_version,payload->'coverage' order by algorithm_version),'{}'::jsonb)
    into coverage from (
      select distinct on(algorithm_version) algorithm_version,payload
      from public.server_physiology_results
      where user_id=p_user and device_id=p_device and period_day=p_day
      order by algorithm_version,input_revision desc) r;

  -- scoring_jobs_v2 queue age (mirrors the worker heartbeat's eligible gate, per owner/device/day).
  select count(*) filter(where not j.dead_letter and j.completed_revision<j.input_revision),
         count(*) filter(where j.dead_letter),
         count(*) filter(where not j.dead_letter and j.completed_revision<j.input_revision
           and exists(select 1 from public.scoring_invalidations_v2 i
             where i.user_id=j.user_id and i.device_id=j.device_id
               and j.day between i.next_day and i.through_day)),
         count(*) filter(where not j.dead_letter and j.completed_revision<j.input_revision
           and j.not_before<=now() and (j.lease_until is null or j.lease_until<=now())
           and exists(select 1 from public.scoring_algorithms_v2 a
             where a.algorithm_version=j.algorithm_version and a.enabled)
           and not exists(select 1 from public.scoring_invalidations_v2 i
             where i.user_id=j.user_id and i.device_id=j.device_id
               and j.day between i.next_day and i.through_day)),
         max(j.input_revision),max(j.completed_revision),
         min(j.dirty_at) filter(where not j.dead_letter and j.completed_revision<j.input_revision),
         min(j.not_before) filter(where not j.dead_letter and j.completed_revision<j.input_revision
           and j.not_before<=now() and (j.lease_until is null or j.lease_until<=now())),
         min(j.not_before) filter(where not j.dead_letter and j.completed_revision<j.input_revision)
    into v2_pending,v2_dead,v2_suppressed,v2_eligible,v2_input,v2_completed,
      v2_oldest_dirty,v2_oldest_eligible,v2_next
    from public.scoring_jobs_v2 j
    where j.user_id=p_user and j.device_id=p_device and j.day=p_day;
  v2_dirty_age := case when v2_oldest_dirty is null then null
    else greatest(0,extract(epoch from (now()-v2_oldest_dirty)))::bigint end;
  v2_eligible_age := case when v2_oldest_eligible is null then null
    else greatest(0,extract(epoch from (now()-v2_oldest_eligible)))::bigint end;
  v2_status := case when v2_dead>0 then 'dead_lettered'
    when v2_pending>0 then 'pending' when v2_input is not null then 'complete' else 'none' end;

  -- Durable acceptance (published server results) vs verified archival (outbox verified).
  select count(*) into durable_published from public.server_physiology_results
    where user_id=p_user and device_id=p_device and period_day=p_day;
  select count(*) filter(where o.status='verified'),
         min(extract(epoch from (now()-o.uploaded_at))) filter(where o.status='verified')
    into archive_verified,archive_oldest_age from public.physiology_archive_outbox o
    where o.user_id=p_user and o.device_id=p_device and o.period_day=p_day;
  archive_oldest_age := case when archive_verified>0 then greatest(0,round(archive_oldest_age))::bigint end;
  select coalesce(jsonb_object_agg(o.status,o.n order by o.status),'{}'::jsonb) into archive_statuses from (
    select status,count(*) n from public.physiology_archive_outbox
    where user_id=p_user and device_id=p_device and period_day=p_day group by status) o;
  select coalesce(jsonb_agg(jsonb_build_object('result_revision',s.result_revision,'algorithm_version',s.algorithm_version,
      'queued',j.result_revision is not null,'dead_letter',coalesce(j.dead_letter,false),
      'completed_at',j.completed_at,'created_at',j.created_at) order by s.result_revision desc),'[]'::jsonb)
    into archive_jobs from public.scoring_snapshots_v2 s
    left join public.scoring_archive_jobs_v2 j on j.result_revision=s.result_revision
    where s.user_id=p_user and s.device_id=p_device and s.day=p_day limit 32;

  -- Projection revision: latest published input_revision vs required (v2 or legacy).
  select max(r.input_revision) into pub_revision from public.server_physiology_results r
    where r.user_id=p_user and r.device_id=p_device and r.period_day=p_day;
  select max(j.input_revision) into req_revision from public.scoring_jobs_v2 j
    where j.user_id=p_user and j.device_id=p_device and j.day=p_day;
  if req_revision is null then
    select max(input_revision) into req_revision from public.physiology_work_items
    where user_id=p_user and device_id=p_device and day=p_day;
  end if;
  projection_behind := req_revision is not null and (pub_revision is null or pub_revision<req_revision);
  projection_status := case when pub_revision is null then 'not_observed'
    when projection_behind then 'behind' else 'current' end;

  -- Explicit blockers, all from measured facts above.
  if not worker_ok and (worker_stale or jsonb_array_length(workers)=0) then
    blockers := blockers || jsonb_build_object('code','worker_unavailable',
      'detail',case when jsonb_array_length(workers)=0 then 'no worker heartbeat for selected algorithms'
        else 'selected worker heartbeat stale' end);
  end if;
  if projection_pending>0 then
    blockers := blockers || jsonb_build_object('code','projection_pending','detail',projection_pending);
  end if;
  if projection_failed>0 then
    blockers := blockers || jsonb_build_object('code','projection_retrying','detail',projection_failed);
  end if;
  if v2_dead>0 then
    blockers := blockers || jsonb_build_object('code','v2_job_dead_lettered','detail',v2_dead);
  end if;
  if v2_pending>0 then
    blockers := blockers || jsonb_build_object('code','v2_job_pending','detail',v2_pending);
  end if;
  if exists(select 1 from jsonb_array_elements(work) q where q->>'status' in ('pending','running','retrying')) then
    blockers := blockers || jsonb_build_object('code','legacy_work_pending');
  end if;
  if (archive_statuses->>'failed')::int>0 or (archive_statuses->>'retry')::int>0 then
    blockers := blockers || jsonb_build_object('code','archive_failed',
      'detail',coalesce((archive_statuses->>'failed')::int,0)+coalesce((archive_statuses->>'retry')::int,0));
  end if;
  if durable_published>0 and archive_verified<durable_published then
    blockers := blockers || jsonb_build_object('code','archive_pending',
      'detail',durable_published-coalesce(archive_verified,0));
  end if;

  return jsonb_build_object('schema_version',2,
    'correlation_id',encode(sha256(convert_to(p_user::text||':'||p_source::text||':'||p_device::text||':'||p_day::text,'UTF8')),'hex'),
    'scope','enrolled_owner_source_device_day','read_rpc','server_scoring_for_device_day',
    'observation_is_atomic',true,'counts_truncated',truncated,'day',p_day,
    'day_bounds',jsonb_build_object('segments',segments,'zone',zone,'zone_source',zone_source,
      'bounds_half_open',true,'zone_policy','local_calendar_midnight'),
    'receipt_window','accepted_on_requested_calendar_day','result_window','measurement_calendar_day',
    'streams',jsonb_build_object(
      'status',case when (select count(*) from jsonb_each(streams))>0 then 'observed' else 'not_observed' end,
      'signal_windows',streams,
      'coverage',coverage,
      'largest_gap',jsonb_build_object('status',case when gap_stream is not null then 'measured' else 'not_measured' end,
        'stream',gap_stream,'seconds',gap_seconds,'reason',case when gap_stream is null then 'no signal windows' end)),
    'stages',jsonb_build_object(
      'acquired',jsonb_build_object('status','not_measured','reason','requires_device_capture_evidence'),
      'durable',jsonb_build_object('status','not_measured','reason','requires_phone_commit_evidence'),
      'accepted',jsonb_build_object('status',case when receipts>0 then 'observed' else 'not_observed' end,'receipts',receipts),
      'projected',jsonb_build_object('status',case when truncated then 'incomplete_diagnostics'
        when projection_failed>0 then 'retrying' when projection_pending>0 then 'pending'
        when objects>0 then 'complete' else 'not_observed' end,
        'pending_objects',projection_pending,'retrying_objects',projection_failed,'oldest_pending_at',projection_oldest),
      'queued',jsonb_build_object('status',case when jsonb_array_length(work)>0 then 'observed' else 'not_observed' end),
      'claimed',jsonb_build_object('status',case when claimed then 'running' else 'not_running' end),
      'computed',jsonb_build_object('status',case when computed then 'published_evidence' else 'not_observed' end),
      'published',jsonb_build_object('status',case when computed then 'observed' else 'not_observed' end),
      'selected',jsonb_build_object('status',case when selected_ready then 'available' else 'unavailable' end),
      'decoded',jsonb_build_object('status','not_measured','reason','requires_client_decoder_evidence'),
      'displayed',jsonb_build_object('status','not_measured','reason','requires_client_presentation_evidence')),
    'queue',jsonb_build_object('scoring_v2',jsonb_build_object(
      'status',v2_status,'pending',v2_pending,'dead_lettered',v2_dead,
      'invalidation_suppressed',v2_suppressed,'eligible',v2_eligible,
      'input_revision',v2_input,'completed_revision',v2_completed,
      'oldest_dirty_age_seconds',v2_dirty_age,'oldest_eligible_age_seconds',v2_eligible_age,
      'next_attempt_at',v2_next)),
    'projection',jsonb_build_object('status',projection_status,
      'published_revision',pub_revision,'required_revision',req_revision,'behind',projection_behind),
    'archive',jsonb_build_object('durable_published',durable_published,'verified',archive_verified,
      'oldest_verified_age_seconds',archive_oldest_age,'statuses',archive_statuses,'jobs_v2',archive_jobs),
    'blockers',blockers,
    'work',work,'publications',publications,'selected_features',selected_features,'selected_workers',workers,
    'capabilities',jsonb_build_object(
      'hrv_timing',jsonb_build_object('status','observed_unqualified','reason','continuity_unverified'),
      'calibrated_spo2',jsonb_build_object('status','unsupported','reason','calibrated_source_unavailable')),
    'complete_scope','server_metadata_only');
end $$;
revoke all on function public.server_pipeline_diagnostics(uuid,uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.server_pipeline_diagnostics(uuid,uuid,uuid,date) to service_role;
comment on function public.server_pipeline_diagnostics(uuid,uuid,uuid,date) is
  'Owner-scoped G7 diagnostics (schema_version 2): day bounds/zone, stream coverage + largest gap, v2 queue age, projection revision, durable-vs-verified archive, explicit blockers. Metadata only; no health payloads.';
commit;
