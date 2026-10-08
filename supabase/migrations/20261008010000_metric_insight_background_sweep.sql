-- Background pre-generation of metric explanations.
--
-- A card opened cold used to wait for a model run (~20-30 s each, one at a time), and the app gives up on a
-- pending analysis after 90 s -- so several cards at once ended on "Explanation unavailable right now".
-- This makes the worker generate explanations ahead of time instead:
--   * `background` marks a job queued by the sweep rather than by a person opening a card. The claim hands out
--     every person-requested job before any background one, so a backlog of pre-generation never delays a card
--     someone is looking at. A person asking for a card that is still queued promotes it.
--   * `metric_insight_sweep_v1` queues, for each account with recent scores and each metric, the explanation
--     of the newest measured day when none exists for it yet. It deliberately does NOT re-queue on every input
--     change (a re-score, a new ElderNet result): such an explanation is regenerated the moment the card is
--     opened, and the previous one is shown meanwhile. That bounds model cost to about one run per account,
--     metric and new day. The daily bound of 8 runs and the dead-letter rule still apply.

alter table public.metric_insight_jobs add column if not exists background boolean not null default false;

create or replace function public.metric_insight_request_v1(p_user uuid, p_metric text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_anchor date;
  v_fp text;
  v_current public.metric_insights;
  v_has_current boolean;
  v_stale jsonb;
  j public.metric_insight_jobs;
  v_has_job boolean;
  v_capped boolean;
  v_today date := (pg_catalog.now() at time zone 'UTC')::date;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  if p_metric is null or p_metric not in ('resting_hr', 'hrv_rmssd', 'hrv_sdnn', 'skin_temp', 'resp_rate', 'spo2', 'heart_rate', 'steps', 'calories') then
    raise exception 'invalid_metric' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_user) then
    raise exception 'account_retired' using errcode = '42501';
  end if;

  select i.anchor_day, i.fingerprint into v_anchor, v_fp from internal.metric_insight_inputs(p_user, p_metric) i;
  select * into v_current from public.metric_insights m
   where m.user_id = p_user and m.metric = p_metric and m.superseded_at is null;
  v_has_current := found;
  if v_anchor is null then
    return jsonb_build_object('status', 'unavailable', 'metric', p_metric, 'reason', 'no_measured_data',
      'insight', null);
  end if;
  if v_has_current and v_current.input_fingerprint = v_fp then
    return jsonb_build_object('status', 'ready', 'metric', p_metric,
      'insight', internal.metric_insight_json(v_current, false));
  end if;
  v_stale := case when v_has_current then internal.metric_insight_json(v_current, true) end;

  select * into j from public.metric_insight_jobs q where q.user_id = p_user and q.metric = p_metric for update;
  v_has_job := found;
  -- At the daily bound nothing new is claimed; a run already in flight still finishes.
  v_capped := v_has_job and j.runs_day = v_today and j.runs_count >= 8
    and (j.lease_until is null or j.lease_until <= v_now);
  if v_has_job and j.fingerprint = v_fp then
    if j.dead_letter then
      return jsonb_build_object('status', 'unavailable', 'metric', p_metric, 'reason', 'analysis_failed',
        'insight', v_stale);
    end if;
    if j.completed_revision < j.input_revision and not v_capped then
      update public.metric_insight_jobs q set requested_at = v_now, background = false
       where q.user_id = p_user and q.metric = p_metric;
      return jsonb_build_object('status', 'pending', 'metric', p_metric, 'insight', v_stale,
        'retry_after_s', greatest(5, least(60, ceil(extract(epoch from (j.not_before - v_now)))::integer)));
    end if;
  end if;
  if v_capped then
    return jsonb_build_object('status', 'unavailable', 'metric', p_metric, 'reason', 'daily_limit',
      'insight', v_stale);
  end if;

  insert into public.metric_insight_jobs as q (user_id, metric, fingerprint, anchor_day)
  values (p_user, p_metric, v_fp, v_anchor)
  on conflict (user_id, metric) do update set
    input_revision = q.input_revision + 1,
    fingerprint = excluded.fingerprint,
    anchor_day = excluded.anchor_day,
    consecutive_failures = 0,
    dead_letter = false,
    not_before = v_now,
    dirty_at = v_now,
    requested_at = v_now,
    background = false;
  return jsonb_build_object('status', 'pending', 'metric', p_metric, 'insight', v_stale, 'retry_after_s', 10);
end $$;

create or replace function public.metric_insight_claim_v1(p_worker text, p_lease_seconds integer default 300)
returns table (user_id uuid, metric text, input_revision bigint, lease_token uuid, lease_until timestamptz,
  anchor_day date, fingerprint text, timezone_id text, analysis_version text, claim_count bigint)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  j public.metric_insight_jobs;
  v_today date := (pg_catalog.now() at time zone 'UTC')::date;
  v_anchor date;
  v_fp text;
begin
  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception 'invalid_lease' using errcode = '22023';
  end if;
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:@/-]{1,128}$' then
    raise exception 'invalid_worker' using errcode = '22023';
  end if;
  select q.* into j from public.metric_insight_jobs q
   where q.completed_revision < q.input_revision and not q.dead_letter
     and q.not_before <= pg_catalog.clock_timestamp()
     and q.requested_at > pg_catalog.clock_timestamp() - interval '6 hours'
     and (q.lease_until is null or q.lease_until <= pg_catalog.clock_timestamp())
     and (q.runs_day is distinct from v_today or q.runs_count < 8)
     and not exists (select 1 from public.noop_account_retirements x where x.user_id = q.user_id)
   order by q.background, q.dirty_at, q.user_id, q.metric
   for update of q skip locked limit 1;
  if not found then
    return;
  end if;
  select i.anchor_day, i.fingerprint into v_anchor, v_fp from internal.metric_insight_inputs(j.user_id, j.metric) i;
  return query
  update public.metric_insight_jobs q set
    lease_token = gen_random_uuid(),
    lease_until = pg_catalog.clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = pg_catalog.clock_timestamp(),
    claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end,
    runs_count = case when q.runs_day = v_today then q.runs_count + 1 else 1 end,
    runs_day = v_today,
    last_worker = p_worker,
    fingerprint = coalesce(v_fp, q.fingerprint),
    anchor_day = v_anchor,
    lease_fingerprint = coalesce(v_fp, q.fingerprint),
    lease_anchor_day = v_anchor
  where q.user_id = j.user_id and q.metric = j.metric
  returning q.user_id, q.metric, q.input_revision, q.lease_token, q.lease_until, q.lease_anchor_day, q.lease_fingerprint,
    internal.physiology_context_zone(q.user_id), internal.metric_insight_version(), q.claim_count;
end $$;

-- Queues the background explanations that are missing. Returns how many it queued (at most p_limit).
create or replace function public.metric_insight_sweep_v1(p_limit integer default 60)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r record;
  j public.metric_insight_jobs;
  v_has_job boolean;
  v_anchor date;
  v_fp text;
  v_have_anchor date;
  v_queued integer := 0;
  v_today date := (pg_catalog.now() at time zone 'UTC')::date;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  for r in
    select u.user_id, m.metric
      from (select distinct s.user_id from public.server_daily_scores s
             where s.algorithm_version = 'frwhoop-server-1' and s.day >= v_today - 3
               and not exists (select 1 from public.noop_account_retirements x where x.user_id = s.user_id)) u
     cross join (values ('resting_hr'), ('hrv_rmssd'), ('hrv_sdnn'), ('skin_temp'), ('resp_rate'), ('spo2'),
                        ('heart_rate'), ('steps'), ('calories')) m(metric)
     order by u.user_id, m.metric
  loop
    exit when v_queued >= p_limit;
    select * into j from public.metric_insight_jobs q where q.user_id = r.user_id and q.metric = r.metric for update;
    v_has_job := found;
    -- Already queued or running, or out of runs for today.
    if v_has_job and ((j.completed_revision < j.input_revision and not j.dead_letter)
        or (j.runs_day = v_today and j.runs_count >= 8)) then
      continue;
    end if;
    select i.anchor_day, i.fingerprint into v_anchor, v_fp from internal.metric_insight_inputs(r.user_id, r.metric) i;
    if v_anchor is null then
      continue;  -- nothing measured to explain
    end if;
    select m.anchor_day into v_have_anchor from public.metric_insights m
     where m.user_id = r.user_id and m.metric = r.metric and m.superseded_at is null;
    if found and v_have_anchor >= v_anchor then
      continue;  -- the newest measured day already has its explanation
    end if;
    if v_has_job and j.dead_letter and j.fingerprint = v_fp then
      continue;  -- failed three times on exactly these inputs: wait for new data, not for the clock
    end if;
    insert into public.metric_insight_jobs as q (user_id, metric, fingerprint, anchor_day, background)
    values (r.user_id, r.metric, v_fp, v_anchor, true)
    on conflict (user_id, metric) do update set
      input_revision = q.input_revision + 1,
      fingerprint = excluded.fingerprint,
      anchor_day = excluded.anchor_day,
      consecutive_failures = 0,
      dead_letter = false,
      not_before = v_now,
      dirty_at = v_now,
      requested_at = v_now,
      background = true;
    v_queued := v_queued + 1;
  end loop;
  return v_queued;
end $$;

revoke all on function public.metric_insight_sweep_v1(integer) from public, anon, authenticated;
grant execute on function public.metric_insight_sweep_v1(integer) to service_role;
