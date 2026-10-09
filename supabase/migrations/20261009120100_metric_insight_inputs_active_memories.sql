-- Metric insights read only the coach memories Sana itself still uses.
--
-- WHY
-- internal.metric_insight_inputs (20261008000000_metric_insights.sql) fingerprints the owner's 12 most important
-- coach_memory_items rows without `retired_at is null`, and the insight worker (Tools/MetricInsight sources.py)
-- reads the same rows. A memory the curator retired, a consolidation merged away or the cap evicted therefore kept
-- reaching the key-metric explanations for up to 30 days, and its retirement re-queued nothing. Every other reader
-- (the chat manifest, GET memories, the curator) ignores retired rows.
--
-- WHAT CHANGES
-- The function is re-created with its body unchanged except for `and x.retired_at is null` in the memory input
-- (copied from 20261008000000_metric_insights.sql, its only definition). The worker's read gets the same filter.
-- An owner with a retired row among their top 12 gets a new fingerprint, so their cached insight is served stale
-- once and redone; nobody else's fingerprint moves.
--
-- Safe to re-run (create or replace). Rollback: re-apply the function from 20261008000000_metric_insights.sql.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';

-- The metric's latest measured day (a day whose value is NULL is not measured, never zero) and the inputs
-- fingerprint (sha256, hex). Nothing is returned when the metric has never been measured.
create or replace function internal.metric_insight_inputs(p_user uuid, p_metric text)
returns table (anchor_day date, fingerprint text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_anchor date;
  v_device uuid;
  v_zone text;
  v_today date;
  v_doc jsonb;
  v_previous jsonb;
  v_lo bigint;
  v_hi bigint;
  v_version text := (select a.algorithm_version from public.scoring_algorithms_v2 a where a.active limit 1);
begin
  v_zone := internal.physiology_context_zone(p_user);
  v_today := (pg_catalog.clock_timestamp() at time zone v_zone)::date;
  if p_metric in ('resting_hr', 'hrv_rmssd', 'hrv_sdnn', 'skin_temp', 'resp_rate') then
    -- A night (keyed by the day it ends): the latest one whose value is measured.
    select s.day into v_anchor
      from public.server_daily_scores s
     where s.user_id = p_user and s.algorithm_version = 'frwhoop-server-1'
       and (case p_metric when 'resting_hr' then s.resting_hr_bpm when 'hrv_rmssd' then s.hrv_rmssd_ms
              when 'hrv_sdnn' then s.hrv_sdnn_ms when 'skin_temp' then s.skin_temp_c
              when 'resp_rate' then s.resp_rate_bpm end) is not null
     order by s.day desc
     limit 1;
  elsif p_metric = 'spo2' then
    -- A night of the strap's SpO2 estimate (a hosted snapshot value): the latest of the last 120 days.
    select max(v.day) into v_anchor from internal.metric_insight_day_values(p_user, v_today - 6, v_today) v
     where v.spo2_candidate_pct is not null;
    if v_anchor is null then
      select max(v.day) into v_anchor from internal.metric_insight_day_values(p_user, v_today - 119, v_today - 7) v
       where v.spo2_candidate_pct is not null;
    end if;
  elsif p_metric in ('steps', 'calories') then
    -- A day: the latest COMPLETE local day with a value (today is still running), within 120 days.
    select max(v.day) into v_anchor from internal.metric_insight_day_values(p_user, v_today - 7, v_today - 1) v
     where (case p_metric when 'steps' then v.steps else v.total_kcal end) is not null;
    if v_anchor is null then
      select max(v.day) into v_anchor from internal.metric_insight_day_values(p_user, v_today - 120, v_today - 8) v
       where (case p_metric when 'steps' then v.steps else v.total_kcal end) is not null;
    end if;
  elsif p_metric = 'heart_rate' then
    -- Calm awake heart rate: the context layer's daily value of a complete local day, within 120 days.
    select max(d.day) into v_anchor from public.physiology_context_days d
     where d.user_id = p_user and d.superseded_by is null and d.day between v_today - 120 and v_today - 1
       and internal.metric_insight_daily_value(d.document, 'heart_rate.stable_awake_5min') is not null;
  end if;
  if v_anchor is null then
    return;
  end if;
  -- The scoring device of the analysed day (its context documents, snapshots and gait): the day's own score row,
  -- else the latest one before it (the worker resolves it the same way).
  select s.source_device_id into v_device
    from public.server_daily_scores s
   where s.user_id = p_user and s.algorithm_version = 'frwhoop-server-1' and s.day <= v_anchor
     and s.source_device_id is not null
   order by s.day desc
   limit 1;
  v_lo := extract(epoch from ((v_anchor - 14)::timestamp at time zone v_zone))::bigint;
  v_hi := extract(epoch from ((v_anchor + 1)::timestamp at time zone v_zone))::bigint;
  -- The whole selected document: the worker reads many of its sections (comparisons, episodes, availability,
  -- sleep, exertion, bouts, daily values, exposure categories), and a republish of any of them is new input.
  -- And the day before: the movement that came before the anchor night (a night is scored on the day it ends).
  if v_device is not null then
    v_doc := internal.metric_insight_context_document(p_user, v_device, v_anchor);
    v_previous := internal.metric_insight_context_document(p_user, v_device, v_anchor - 1);
  end if;
  return query select v_anchor, encode(pg_catalog.sha256(convert_to(
    internal.metric_insight_version() || E'\n' || p_user::text || E'\n' || p_metric
    || E'\nanchor:' || to_char(v_anchor, 'YYYY-MM-DD') || E'\nzone:' || v_zone
    || E'\nscores:' || coalesce((
         select string_agg((to_jsonb(s) - array['provenance', 'computed_at', 'created_at', 'updated_at'])::text,
                           E'\n' order by s.day)
           from public.server_daily_scores s
          where s.user_id = p_user and s.algorithm_version = 'frwhoop-server-1'
            and s.day between v_anchor - 89 and v_anchor), '')
    -- The usual and its call (the app's Baseline) replay every earlier night: their night vitals are input too.
    || E'\nhistory:' || coalesce((
         select md5(string_agg((s.day, s.resting_hr_bpm, s.hrv_rmssd_ms, s.skin_temp_c, s.resp_rate_bpm,
                                s.spo2_pct)::text, E'\n' order by s.day))
           from public.server_daily_scores s
          where s.user_id = p_user and s.algorithm_version = 'frwhoop-server-1' and s.day < v_anchor - 89), '')
    -- Hosted day values (steps, energy, the SpO2 estimate), 400 days for the steps usual's replay: each day's
    -- snapshot revisions (a rescored day is new input) without reading the payloads.
    || E'\nday_values:' || case when p_metric in ('spo2', 'steps', 'calories', 'heart_rate') then coalesce((
         select string_agg(n.day::text || ':' || n.device_id::text || ':' || n.revision::text, ','
                           order by n.day, n.device_id)
           from (select x.day, x.device_id, max(x.result_revision) as revision from public.scoring_snapshots_v2 x
                  where x.user_id = p_user and x.algorithm_version = v_version
                    and x.day between v_anchor - 399 and v_anchor
                  group by x.day, x.device_id) n), '') else '-' end
    -- Calm awake heart rate over the window: the context documents' revisions.
    || E'\ncalm_hr:' || case when p_metric in ('heart_rate', 'steps', 'calories') then coalesce((
         select string_agg(d.day::text || ':' || d.mode || ':' || d.context_revision::text, ',' order by d.day, d.mode)
           from public.physiology_context_days d
          where d.user_id = p_user and d.device_id = v_device and d.superseded_by is null
            and d.day between v_anchor - 119 and v_anchor), '') else '-' end
    -- ElderNet gait of the day and the month before (UTC rows; the local day spans two).
    || E'\ngait:' || case when p_metric = 'steps' then coalesce((
         select string_agg(g.day::text || ':' || g.model_version || ':' || g.mode || ':' || g.result_revision::text,
                           ',' order by g.day, g.model_version, g.mode)
           from public.activity_gait_windows_days g
          where g.user_id = p_user and g.device_id = v_device and g.day between v_anchor - 30 and v_anchor + 1), '')
         else '-' end
    || E'\ncontext:' || coalesce(md5(v_doc::text), '-') || ':' || coalesce(md5(v_previous::text), '-')
    -- The hosted day snapshots of the night's two days (HRV slots, their activity composition, sleep sessions):
    -- the latest result of the active algorithm, as get_server_score_snapshot_v2 serves it.
    || E'\nsnapshots:' || coalesce((
         select string_agg(x.day::text || ':' || md5(x.payload::text), ',' order by x.day)
           from (select distinct on (n.day) n.day, n.payload from public.scoring_snapshots_v2 n
                  where n.user_id = p_user and n.device_id = v_device and n.day between v_anchor - 1 and v_anchor
                    and n.algorithm_version = (select a.algorithm_version from public.scoring_algorithms_v2 a
                                                where a.active)
                  order by n.day, n.result_revision desc) x), '')
    -- The decoded activity documents around the night (activity_context_runs reads them; UTC days).
    || E'\nactivity:' || coalesce((
         select string_agg(c.day::text || ':' || c.algorithm_version || ':' || md5(c.document::text), ','
                           order by c.day, c.algorithm_version)
           from public.activity_context_days c
          where c.user_id = p_user and c.device_id = v_device and c.day between v_anchor - 2 and v_anchor + 1), '')
    || E'\nexposures:' || coalesce((
         select string_agg(e.event_id || ':' || e.revision::text, ',' order by e.event_id collate "C")
           from public.exposure_events e
          where e.owner = p_user and e.occurred_start < v_hi and e.occurred_end > v_lo), '')
    -- The coach memory the worker may read: the owner's 12 most important ACTIVE rows (a retired or merged row is
    -- never shown to the worker, so it is no input either).
    || E'\nmemory:' || coalesce((
         select string_agg(m.id::text || ':' || m.importance::text || ':' || md5(m.topic || E'\n' || m.content), ','
                           order by m.id)
           from (select x.id, x.importance, x.topic, x.content from public.coach_memory_items x
                  where x.user_id = p_user and x.retired_at is null
                  order by x.importance desc, x.created_at desc, x.id limit 12) m), ''),
    'UTF8')), 'hex');
end $$;

revoke all on function internal.metric_insight_inputs(uuid, text) from public, anon, authenticated, service_role;

commit;
