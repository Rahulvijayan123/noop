-- GET scores/anomaly-candidates: the half-hour windows behind the candidates, with their context and reasons.
--
-- WHY
-- The route returned candidates only (audit A-watchdog D8 / R7). A window the anomaly service withheld (exercise,
-- recovery after it, off the wrist, too little heart rate, still learning) looked to the phone exactly like a window
-- that was scored and normal, so the Watchdog could not tell "the server judged this evening normal" from "the server
-- did not judge it". The service already stores one row per window and model (anomaly_window_scores) with its own
-- withheld value and, since 20261009140100, the canonical reason (contracts/reason-codes.json). The per-minute
-- measurement context (20261009130100) says what each minute of the window was.
--
-- WHAT CHANGES
--   public.anomaly_windows_read_v1(user, device, from, to)  service only. The device's windows starting in
--     [from, to) (at most 3 days), oldest first, as JSON:
--       {start_ts, end_ts, usable, reason, context: {kind, mix, mix_basis}, models: [{model, score, p, usable, reason}]}
--     reason: {code, certainty[, subcode], legacy} from the row's reason_code / reason_certainty, or mapped from its
--     withheld_reason (internal.anomaly_withheld_reason) for rows written before the service sent codes; the
--     window's reason is the withheld row's (model 'none'), else the one reason every model row shares (e.g.
--     learning), else null. context.kind is the service's bucket (rest / sleep). context.mix: shares of the window's
--     minutes (of its full length, so missing minutes count as unknown) from measurement_context_minutes:
--     session / recovery / active / no_session / unknown (rule exercise-session-2 phase; active = a period that met
--     the session conditions but is not confirmed; unknown = no motion evidence or no minute row), asleep,
--     off_wrist (incl. charging), the
--     activity classes copied there, and the quality classes; mix_basis measurement_context_minutes, or none (and
--     mix null) when no minute row exists yet.
-- Read only; nothing is written. Existing fields of the route are unchanged (the windows are an opt-in member).
--
-- Safe to re-run. Rollback: drop function public.anomaly_windows_read_v1(uuid, uuid, timestamptz, timestamptz).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.anomaly_windows_read_v1(p_user uuid, p_device uuid, p_from timestamptz,
                                                          p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '3 days' then
    raise exception 'invalid_range' using errcode = '22023';
  end if;
  if p_device is null or not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  with rows as (
    select s.window_start, s.window_end, s.model, s.channel_group, s.score, s.p, s.context_kind, s.usable,
           s.withheld_reason,
           coalesce(s.reason_code, m.code) as code, coalesce(s.reason_certainty, m.certainty) as certainty
      from public.anomaly_window_scores s
      left join lateral internal.anomaly_withheld_reason(s.withheld_reason) m on s.reason_code is null
     where s.user_id = p_user and s.device_id = p_device and s.window_start >= p_from and s.window_start < p_to
  ), reasons as (
    select r.*,
           case when r.code is null then null
                else jsonb_strip_nulls(jsonb_build_object(
                       'code', split_part(r.code, '/', 1), 'subcode', nullif(split_part(r.code, '/', 2), ''),
                       'certainty', r.certainty, 'legacy', r.withheld_reason)) end as reason
      from rows r
  ), windows as (
    select w.window_start, max(w.window_end) as window_end, bool_or(w.usable) as usable,
           max(w.context_kind) as kind,
           coalesce(
             (select x.reason from reasons x where x.window_start = w.window_start and x.model = 'none'
               order by x.channel_group limit 1),
             case when count(*) = count(w.reason) and count(distinct w.reason) = 1 then min(w.reason::text)::jsonb end)
             as reason,
           jsonb_agg(jsonb_build_object('model', w.model, 'channel_group', w.channel_group, 'score', w.score,
                                        'p', w.p, 'usable', w.usable, 'reason', w.reason)
                     order by w.model, w.channel_group) as models
      from reasons w
     group by w.window_start
  ), mix as (
    select w.window_start,
           greatest(1, extract(epoch from (w.window_end - w.window_start)) / 60) as span_min,
           count(mc.minute_start) as n,
           count(*) filter (where mc.session_phase = 'session') as session,
           count(*) filter (where mc.session_phase = 'recovery') as recovery,
           count(*) filter (where mc.session_phase = 'active') as active,
           count(*) filter (where mc.session_phase = 'none') as phase_none,
           count(*) filter (where mc.sleep_state = 'asleep') as asleep,
           count(*) filter (where mc.wear_state in ('off_wrist', 'charging')) as off_wrist,
           (select jsonb_object_agg(a.k, a.n) from (
              select coalesce(m2.activity_class, 'unknown') as k, count(*) as n
                from public.measurement_context_minutes m2
               where m2.user_id = p_user and m2.device_id = p_device
                 and m2.minute_start >= w.window_start and m2.minute_start < w.window_end
               group by 1) a) as activity,
           (select jsonb_object_agg(q.k, q.n) from (
              select m3.quality_class as k, count(*) as n
                from public.measurement_context_minutes m3
               where m3.user_id = p_user and m3.device_id = p_device
                 and m3.minute_start >= w.window_start and m3.minute_start < w.window_end
               group by 1) q) as quality
      from windows w
      left join public.measurement_context_minutes mc
        on mc.user_id = p_user and mc.device_id = p_device
       and mc.minute_start >= w.window_start and mc.minute_start < w.window_end
     group by w.window_start, w.window_end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'start_ts', w.window_start, 'end_ts', w.window_end, 'usable', w.usable, 'reason', w.reason,
           'context', jsonb_build_object(
             'kind', w.kind,
             'mix_basis', case when x.n > 0 then 'measurement_context_minutes' else 'none' end,
             'minutes', x.n,
             'mix', case when x.n = 0 then null else jsonb_build_object(
               'session', round((x.session / x.span_min)::numeric, 3),
               'recovery', round((x.recovery / x.span_min)::numeric, 3),
               'active', round((x.active / x.span_min)::numeric, 3),
               'no_session', round((x.phase_none / x.span_min)::numeric, 3),
               'unknown', round((greatest(0, x.span_min - x.session - x.recovery - x.active - x.phase_none)
                                 / x.span_min)::numeric, 3),
               'asleep', round((x.asleep / x.span_min)::numeric, 3),
               'off_wrist', round((x.off_wrist / x.span_min)::numeric, 3),
               'activity', (select jsonb_object_agg(k, round((v::numeric / x.span_min::numeric), 3))
                              from jsonb_each_text(coalesce(x.activity, '{}')) t(k, v)),
               'quality', (select jsonb_object_agg(k, round((v::numeric / x.span_min::numeric), 3))
                             from jsonb_each_text(coalesce(x.quality, '{}')) t(k, v))) end),
           'models', w.models) order by w.window_start), '[]'::jsonb)
    into v_out
    from windows w join mix x on x.window_start = w.window_start;
  return v_out;
end $$;
revoke all on function public.anomaly_windows_read_v1(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.anomaly_windows_read_v1(uuid, uuid, timestamptz, timestamptz) to service_role;

commit;
