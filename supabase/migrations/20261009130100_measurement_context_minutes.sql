-- Measurement context per minute: one row per (user, device, UTC minute) that says what was measured, how good
-- it was, what the person was doing, where in their day it fell, and why anything is missing.
--
-- WHY
-- The facts a reading needs to be interpreted were scattered (raw rows carry no quality; activity lives in 30 s
-- epochs that cover 7-12 h a day and in day documents; sleep in scored nights; wear in events; time zone in
-- history) and nothing said why a minute had no data. Watchdog and the anomaly service each re-derived parts of it,
-- differently. This table is the one per-minute record (audit C-metadata R8), built on the server from stored rows
-- only, with directly observed facts kept apart from inferred estimates, each inferred group carrying its basis.
--
-- COLUMNS (public.measurement_context_minutes)
--   key       user_id, device_id (the strap the raw rows are stored under), minute_start (UTC, minute aligned).
--   local     local_day, utc_offset_s, tz_basis: the zone in effect at that minute (scoring_timezone_history,
--             else profiles.timezone, else UTC), so DST days have 23 / 25 local hours.
--   OBSERVED  counts and summaries of the rows that exist (never estimated): hr_n/mean/min/max (noop_hr_samples),
--             rr_n / rr_suspect_n (noop_rr_intervals, tsSuspect <> 0), dyn_n/mean/p90 (noop_gravity_samples
--             dynAccel, g), steps_n / step_walk_n / step_run_n (noop_step_samples and the strap's own step class
--             1 walk / 2 run), skin_temp_n / skin_temp_mean (deg C, WHOOP 5/MG centidegree rows only; a WHOOP 4 raw
--             ADC row is counted but not converted), band_sleep_state (the strap's own modal sleep state),
--             wrist_event (WRIST_ON / WRIST_OFF inside the minute), contact_state (STANDARD_HR_CONTACT carried
--             forward), ble_link_down_s (seconds inside BLE_CONNECTION_DOWN..UP), reset_event, saturation_event,
--             charging (CHARGING_ON/OFF edge held 24 h, or a battery row with its charging bit within 60 min; NULL
--             when nothing says), observed_s (seconds with HR or motion), max_ingested_at (availability).
--   PHONE     v18_n, sentinel_n, baseline_max, record_gap, hr_grade, beats_grade, phone_reasons,
--             phone_quality_version: optical evidence only the phone has (v18 aux records). Written only by
--             POST scores/quality-minutes (20261009130200); NULL until the phone sends them.
--   DERIVED   quality_class good | fair | poor | off_wrist | unknown, quality_conf (ordinal, uncalibrated), reasons
--             [{code, certainty}] in canonical codes (public.reason_codes), rule mcq-1
--             (internal.measurement_context_quality_v1).
--   COPIED    inferred context, never re-estimated here, each with its basis:
--             activity_class / activity_conf / posture / exertion / activity_ref from the CURRENT epoch lineage
--             (activity_context_epochs_current, basis activity_epoch), else the day document's runs
--             (activity_context_runs, basis activity_run), else NULL (basis none, reason context_unknown);
--             sleep_state asleep | awake | in_bed inside a scored night (server_sleep_nights frwhoop-server-1,
--             basis server_night_stages / server_night), NULL outside one (basis outside_server_night when the day
--             was scored, not_scored otherwise); wear_state on_wrist | off_wrist | charging (basis charging,
--             wrist_event, activity_epoch, activity_run, hr_present or unknown); placement NULL with
--             placement_basis not_resolved (placement resolution is owned by the placement work and lands later).
--   SESSION   rule exercise-session-1 (docs/context-watchdog/EXERCISE_SESSION.md) over the OBSERVED evidence:
--             session_phase none | session | recovery (NULL when the minute has no motion evidence at all and is
--             not inside a session), session_start, session_rule, session_basis (the rest reference used:
--             sleep_resting_hr, awake_still_median or default_70).
--   COMPLETE  missing_reasons [{code, certainty}]: why a minute has no heart rate (charging, off_wrist,
--             strap_not_recording, strap_link_down, awaiting_upload, sensor_dropout, insufficient_coverage) and
--             context_unknown when activity or session phase is unknown. Unknown stays unknown: no value is
--             fabricated to fill a gap.
--   VERSION   context_version -> measurement_context_versions (builder, rule ids, reason-codes version, backfill
--             flag), revision (a sequence value, bumped only when the row's content changes), computed_at.
--
-- WRITE PATHS (all service-only, none takes the scoring lock, no trigger on any noop_* table)
--   internal.build_measurement_context_minutes(user, device, from, to)  rebuilds the minutes of [from, to) (at
--     most 3 days, completed minutes only) from stored rows, reading 6 h before and 4 h after for sessions;
--     idempotent, writes only rows whose content changed. One builder per (user, device) at a time (advisory
--     transaction lock on 'measurement-context:<user>:<device>').
--   internal.measurement_context_tick_v1()  pg_cron every 5 minutes: queues local days whose scoring inputs,
--     scoring results or activity documents changed in the last 2 days (scoring_jobs_v2 / activity_context_days,
--     read only) on internal.measurement_context_work, then builds at most 12 queued days (FOR UPDATE SKIP LOCKED,
--     40 s budget, failing days back off).
--   internal.backfill_measurement_context_minutes(user, device, from_day, to_day)  up to 31 local days from
--     stored data only, rows tagged with the backfill version row.
-- READ PATH
--   public.measurement_context_minutes_read_v1(user, device, from, to)  for GET scores/context-minutes (at most
--     1440 rows), reasons expanded with their effect and family.
--
-- Privileges: the table is owner-select under RLS (authenticated) and service_role; the versions table and the
-- work table are service-only; every function is SECURITY DEFINER with an empty search_path and EXECUTE revoked
-- from clients (public.* read function granted to service_role only).
--
-- Safe to re-run. Rollback: select cron.unschedule('frwhoop-measurement-context'); drop the functions below; drop
-- table internal.measurement_context_work, public.measurement_context_minutes,
-- public.measurement_context_versions; drop sequence public.measurement_context_minutes_revision_seq.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- 1. Versions --------------------------------------------------------------------------------------------------
create table if not exists public.measurement_context_versions (
  id                   smallint generated always as identity primary key,
  builder_version      text not null check (builder_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  rule_ids             text[] not null,
  reason_codes_version text not null,
  backfill             boolean not null default false,
  notes                text,
  created_at           timestamptz not null default clock_timestamp(),
  unique (builder_version, rule_ids, reason_codes_version, backfill)
);
comment on table public.measurement_context_versions is
  'Recipes that produced measurement_context_minutes rows: builder version, rule ids (exercise-session-1, mcq-1), '
  'reason-codes version and whether the rows were written by a backfill from stored data only.';
alter table public.measurement_context_versions enable row level security;
revoke all on public.measurement_context_versions from public, anon, authenticated;
grant all on public.measurement_context_versions to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'measurement_context_versions'
                    and policyname = 'measurement_context_versions_service') then
    create policy measurement_context_versions_service on public.measurement_context_versions for all to service_role
      using (true) with check (true);
  end if;
end $$;

insert into public.measurement_context_versions (builder_version, rule_ids, reason_codes_version, backfill, notes)
values ('mcm-1', array['exercise-session-1', 'mcq-1'], 'data-reason-1', false,
        'Live builder (pg_cron, quality-minutes route).'),
       ('mcm-1', array['exercise-session-1', 'mcq-1'], 'data-reason-1', true,
        'Backfill from stored rows only: no phone evidence unless it was already stored; awaiting_upload is never '
        'asserted.')
on conflict (builder_version, rule_ids, reason_codes_version, backfill) do nothing;

-- 2. Minutes ---------------------------------------------------------------------------------------------------
create sequence if not exists public.measurement_context_minutes_revision_seq;

create table if not exists public.measurement_context_minutes (
  user_id          uuid not null references auth.users(id) on delete cascade,
  device_id        uuid not null,
  minute_start     timestamptz not null check (extract(second from minute_start) = 0),
  -- local time
  local_day        date not null,
  utc_offset_s     integer not null check (utc_offset_s between -64800 and 64800),
  tz_basis         text not null check (tz_basis in ('timezone_history', 'profile', 'default_utc')),
  -- OBSERVED
  hr_n             smallint not null default 0 check (hr_n >= 0),
  hr_mean          real,
  hr_min           smallint,
  hr_max           smallint,
  rr_n             smallint not null default 0 check (rr_n >= 0),
  rr_suspect_n     smallint not null default 0 check (rr_suspect_n >= 0),
  dyn_n            smallint not null default 0 check (dyn_n >= 0),
  dyn_mean         real,
  dyn_p90          real,
  steps_n          smallint not null default 0 check (steps_n >= 0),
  step_walk_n      smallint not null default 0 check (step_walk_n >= 0),
  step_run_n       smallint not null default 0 check (step_run_n >= 0),
  skin_temp_n      smallint not null default 0 check (skin_temp_n >= 0),
  skin_temp_mean   real,
  band_sleep_state smallint,
  wrist_event      text check (wrist_event in ('on', 'off', 'on_off')),
  contact_state    text check (contact_state in ('unsupported', 'detected', 'not_detected')),
  ble_link_down_s  smallint check (ble_link_down_s between 1 and 60),
  reset_event      boolean not null default false,
  saturation_event boolean not null default false,
  charging         boolean,
  max_ingested_at  timestamptz,
  -- PHONE-OBSERVED (POST scores/quality-minutes only)
  v18_n            smallint check (v18_n between 0 and 120),
  sentinel_n       smallint check (sentinel_n between 0 and 120),
  baseline_max     integer check (baseline_max between 0 and 65535),
  record_gap       text check (record_gap in ('paused', 'lost')),
  hr_grade         text check (hr_grade in ('good', 'degraded', 'poor', 'unknown')),
  beats_grade      text check (beats_grade in ('good', 'degraded', 'poor', 'unknown')),
  phone_reasons    text[],
  phone_quality_version text check (phone_quality_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  -- DERIVED
  quality_class    text not null check (quality_class in ('good', 'fair', 'poor', 'off_wrist', 'unknown')),
  quality_conf     real check (quality_conf between 0 and 1),
  reasons          jsonb not null default '[]' check (jsonb_typeof(reasons) = 'array'),
  -- COPIED (inferred)
  activity_class   text,
  activity_conf    real,
  posture          text,
  exertion         text,
  activity_basis   text not null check (activity_basis in ('activity_epoch', 'activity_run', 'none')),
  activity_ref     bigint,
  sleep_state      text check (sleep_state in ('asleep', 'awake', 'in_bed')),
  sleep_basis      text not null check (sleep_basis in ('server_night_stages', 'server_night',
                                                        'outside_server_night', 'not_scored')),
  wear_state       text check (wear_state in ('on_wrist', 'off_wrist', 'charging')),
  wear_basis       text not null check (wear_basis in ('charging', 'wrist_event', 'activity_epoch', 'activity_run',
                                                      'hr_present', 'unknown')),
  placement        text,
  placement_basis  text not null default 'not_resolved',
  -- exercise session (rule exercise-session-1)
  session_phase    text check (session_phase in ('none', 'session', 'recovery')),
  session_start    timestamptz,
  session_rule     text,
  session_basis    text check (session_basis in ('sleep_resting_hr', 'awake_still_median', 'default_70')),
  -- completeness
  observed_s       smallint not null default 0 check (observed_s between 0 and 60),
  missing_reasons  jsonb not null default '[]' check (jsonb_typeof(missing_reasons) = 'array'),
  -- versions
  context_version  smallint not null references public.measurement_context_versions(id),
  revision         bigint not null,
  computed_at      timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, minute_start),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
comment on table public.measurement_context_minutes is
  'Per-minute measurement context (20261009130100): observed acquisition facts, phone optical evidence, derived '
  'quality with canonical reasons, copied activity / sleep / wear / placement with their basis, rule '
  'exercise-session-1 phase, local time and missing-data reasons. revision bumps only on a content change.';

create index if not exists measurement_context_minutes_revision
  on public.measurement_context_minutes (user_id, device_id, revision);

alter table public.measurement_context_minutes enable row level security;
revoke all on public.measurement_context_minutes from public, anon, authenticated;
grant select on public.measurement_context_minutes to authenticated;
grant all on public.measurement_context_minutes to service_role;
grant usage, select on sequence public.measurement_context_minutes_revision_seq to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'measurement_context_minutes'
                    and policyname = 'measurement_context_minutes_select_own') then
    create policy measurement_context_minutes_select_own on public.measurement_context_minutes for select
      to authenticated using ((select auth.uid()) = user_id);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'measurement_context_minutes'
                    and policyname = 'measurement_context_minutes_service') then
    create policy measurement_context_minutes_service on public.measurement_context_minutes for all to service_role
      using (true) with check (true);
  end if;
end $$;

-- 3. Rule exercise-session-1 -----------------------------------------------------------------------------------
-- Over a contiguous minute grid, ported from contracts/reference/exercise_session_1.py and pinned to
-- contracts/reference/exercise-session-1.json (supabase/tests/measurement_context_minutes.sql). Arrays hold one
-- element per minute, oldest first: hr is the minute's mean bpm or NULL; strong / weak are the minute's HR-free
-- evidence with asleep and off-wrist minutes already removed by the caller. Batch mode: each period is judged as it
-- stands in the grid (the builder re-runs as data arrives, so an ongoing session appears once it is 12 minutes long).
--
-- The rest reference of a period is resolved at its first evidence minute `a`: p_fixed_rest when given (the
-- fixture), else p_night_rest[a] + 10 (median nightly resting HR of the recent nights before that local day), else
-- the median HR of the p_still minutes in the 2 h before `a`, else 70 bpm.
--
-- One row per session, as 0-based minute indices like the reference: a / b = first / last evidence minute,
-- recovery_end = the first minute that is no longer recovery (exclusive).
create or replace function internal.exercise_session_spans_v1(
  p_hr double precision[], p_strong boolean[], p_weak boolean[],
  p_still boolean[] default null, p_night_rest double precision[] default null,
  p_fixed_rest double precision default null)
returns table (a integer, b integer, recovery_end integer, pre_reference double precision,
               rest_reference double precision, rest_basis text)
language plpgsql immutable set search_path = '' as $$
declare
  c_merge_gap constant integer := 10;
  c_anchor constant integer := 20;
  c_span constant integer := 10;
  c_min_evidence constant integer := 3;
  c_min_strong constant integer := 2;
  c_load_delta constant double precision := 25;
  c_min_load constant integer := 8;
  c_min_duration constant integer := 12;
  c_return_delta constant double precision := 10;
  c_return_run constant integer := 5;
  c_cap_lo constant integer := 30;
  c_cap_hi constant integer := 120;
  c_pre_far constant integer := 45;
  c_pre_near constant integer := 10;
  c_rest_window constant integer := 120;
  c_default_rest constant double precision := 70;
  n integer := coalesce(array_length(p_hr, 1), 0);
  ev boolean[];
  next_strong integer[];
  cs integer[];
  last_strong integer;
  pa integer[] := '{}';
  pb integer[] := '{}';
  fa integer[] := '{}';
  fb integer[] := '{}';
  fr double precision[] := '{}';
  fbasis text[] := '{}';
  busy boolean[];
  i integer; j integer; k integer; s integer; va integer; vb integer; lim integer; e integer; run integer;
  n_strong integer; load integer; dense boolean; r double precision; rb text; pre double precision;
  prev_pre double precision;
begin
  if n = 0 then return; end if;
  if coalesce(array_length(p_strong, 1), 0) <> n or coalesce(array_length(p_weak, 1), 0) <> n
     or (p_still is not null and coalesce(array_length(p_still, 1), 0) <> n)
     or (p_night_rest is not null and coalesce(array_length(p_night_rest, 1), 0) <> n) then
    raise exception 'exercise_session_input_length';
  end if;

  -- Counted evidence: strong minutes, and weak minutes with a strong one within c_anchor minutes either side.
  next_strong := array_fill(null::integer, array[n]);
  j := null;
  for i in reverse n..1 loop
    if coalesce(p_strong[i], false) then j := i; end if;
    next_strong[i] := j;
  end loop;
  ev := array_fill(false, array[n]);
  last_strong := null;
  for i in 1..n loop
    if coalesce(p_strong[i], false) then
      last_strong := i;
      ev[i] := true;
    elsif coalesce(p_weak[i], false) then
      ev[i] := (last_strong is not null and i - last_strong <= c_anchor)
            or (next_strong[i] is not null and next_strong[i] - i <= c_anchor);
    end if;
  end loop;
  -- cs[i] = counted evidence minutes among 1..i-1.
  cs := array_fill(0, array[n + 1]);
  for i in 1..n loop
    cs[i + 1] := cs[i] + case when ev[i] then 1 else 0 end;
  end loop;

  -- Active periods: evidence minutes merged while the gap is at most c_merge_gap minutes.
  for i in 1..n loop
    if ev[i] then
      k := coalesce(array_length(pb, 1), 0);
      if k > 0 and i - pb[k] <= c_merge_gap then
        pb[k] := i;
      else
        pa := pa || i;
        pb := pb || i;
      end if;
    end if;
  end loop;

  -- Sessions: dense, at least c_min_strong strong minutes, load against the period's rest reference, duration.
  for k in 1..coalesce(array_length(pa, 1), 0) loop
    va := pa[k]; vb := pb[k];
    if p_fixed_rest is not null then
      r := p_fixed_rest; rb := 'fixed';
    elsif p_night_rest is not null and p_night_rest[va] is not null then
      r := p_night_rest[va] + 10; rb := 'sleep_resting_hr';
    else
      r := null;
      if p_still is not null then
        select percentile_cont(0.5) within group (order by p_hr[x]) into r
          from generate_series(greatest(1, va - c_rest_window), va - 1) x
         where coalesce(p_still[x], false) and p_hr[x] is not null;
      end if;
      if r is not null then rb := 'awake_still_median'; else r := c_default_rest; rb := 'default_70'; end if;
    end if;
    dense := false;
    for s in va..vb loop
      if cs[least(s + c_span - 1, vb) + 1] - cs[s] >= c_min_evidence then dense := true; exit; end if;
    end loop;
    n_strong := 0; load := 0;
    for i in va..vb loop
      if coalesce(p_strong[i], false) then n_strong := n_strong + 1; end if;
      if p_hr[i] is not null and p_hr[i] >= r + c_load_delta then load := load + 1; end if;
    end loop;
    if dense and n_strong >= c_min_strong and load >= c_min_load and vb - va + 1 >= c_min_duration then
      fa := fa || va; fb := fb || vb; fr := fr || r; fbasis := fbasis || rb;
    end if;
  end loop;

  -- Recovery: from the last evidence minute until heart rate is back within pre + c_return_delta for
  -- c_return_run minutes, the cap (duration clamped to [30, 120] minutes) or the next session.
  busy := array_fill(false, array[n]);
  prev_pre := null;
  for k in 1..coalesce(array_length(fa, 1), 0) loop
    va := fa[k]; vb := fb[k]; r := fr[k];
    select percentile_cont(0.5) within group (order by p_hr[x]) into pre
      from generate_series(greatest(1, va - c_pre_far), greatest(1, va - c_pre_near) - 1) x
     where p_hr[x] is not null and not busy[x];
    pre := coalesce(pre, prev_pre, r);
    prev_pre := pre;
    lim := least(n + 1, vb + 1 + least(greatest(vb - va + 1, c_cap_lo), c_cap_hi));
    if k < array_length(fa, 1) then lim := least(lim, fa[k + 1]); end if;
    e := lim;
    run := 0;
    for i in vb + 1 .. lim - 1 loop
      if p_hr[i] is not null and p_hr[i] <= pre + c_return_delta then
        run := run + 1;
        if run = c_return_run then e := i - c_return_run + 1; exit; end if;
      else
        run := 0;
      end if;
    end loop;
    for i in va .. e - 1 loop busy[i] := true; end loop;
    a := va - 1; b := vb - 1; recovery_end := e - 1;
    pre_reference := pre; rest_reference := r; rest_basis := fbasis[k];
    return next;
  end loop;
end $$;
revoke all on function internal.exercise_session_spans_v1(double precision[], boolean[], boolean[], boolean[],
  double precision[], double precision) from public, anon, authenticated, service_role;

-- 4. Quality rule mcq-1 ----------------------------------------------------------------------------------------
-- One minute's HR-level quality from its own columns (first match wins). The phone's grades and legacy reasons
-- (contracts/reason-codes.json legacy.watchdog_quality) refine it when present; without them the server cannot
-- see optics, so a still minute is good only when beat timing is present (R-R count at least half the bpm).
--   charging                              -> off_wrist 1.0  charging (confirmed)
--   wear off_wrist from a wrist event     -> off_wrist 1.0  off_wrist (confirmed)
--   phone record_gap paused               -> off_wrist 0.8  strap_not_recording (confirmed)
--   no HR, wear off_wrist (inferred)      -> off_wrist 0.6  off_wrist (inferred)
--   < 30 s of HR                          -> unknown        strap_reset (confirmed, if a reset event), insufficient_coverage
--                                                           (measured), awaiting_upload (inferred, phone record_gap lost)
--   saturation event                      -> poor 0.9       optical_saturation (confirmed)
--   phone hr_grade poor                   -> poor 0.8
--   moving (dyn >= 0.05 g or walk/run steps on >= half the step samples)
--                                         -> fair 0.6       hr_in_motion_unverified (inferred): never good in motion
--   phone hr_grade degraded / good        -> fair 0.7 / good 0.9
--   R-R count >= 0.5 x mean bpm           -> good 0.6
--   otherwise                             -> fair 0.5       insufficient_coverage (measured: beat timing sparse)
-- The phone's mapped reasons follow the server's, one entry per code (the first wins).
create or replace function internal.measurement_context_quality_v1(
  p_hr_n integer, p_hr_mean real, p_rr_n integer, p_dyn_mean real, p_steps_n integer, p_step_moving_n integer,
  p_wear_state text, p_wear_basis text, p_reset boolean, p_saturation boolean,
  p_record_gap text, p_hr_grade text, p_phone_reasons text[],
  out quality_class text, out quality_conf real, out reasons jsonb)
language plpgsql stable set search_path = '' as $$
declare
  v_moving boolean := coalesce(p_dyn_mean >= 0.05, false)
    or (coalesce(p_steps_n, 0) > 0 and 2 * coalesce(p_step_moving_n, 0) >= p_steps_n);
  v_hr_n integer := coalesce(p_hr_n, 0);
  v_server jsonb := '[]';
  v_phone jsonb;
begin
  select coalesce(jsonb_agg(c order by o), '[]') into v_phone
    from (select internal.canonical_reason('watchdog_quality', x) as c, o
            from unnest(coalesce(p_phone_reasons, '{}')) with ordinality u(x, o)) m
   where c is not null;
  if p_wear_state = 'charging' then
    quality_class := 'off_wrist'; quality_conf := 1.0;
    v_server := '[{"code": "charging", "certainty": "confirmed"}]';
  elsif p_wear_state = 'off_wrist' and p_wear_basis = 'wrist_event' then
    quality_class := 'off_wrist'; quality_conf := 1.0;
    v_server := '[{"code": "off_wrist", "certainty": "confirmed"}]';
  elsif p_record_gap = 'paused' then
    quality_class := 'off_wrist'; quality_conf := 0.8;
    v_server := '[{"code": "strap_not_recording", "certainty": "confirmed"}]';
  elsif v_hr_n = 0 and p_wear_state = 'off_wrist' then
    quality_class := 'off_wrist'; quality_conf := 0.6;
    v_server := '[{"code": "off_wrist", "certainty": "inferred"}]';
  elsif v_hr_n < 30 then
    quality_class := 'unknown'; quality_conf := null;
    v_server := case when coalesce(p_reset, false)
                     then '[{"code": "strap_reset", "certainty": "confirmed"}]'::jsonb else '[]'::jsonb end
             || '[{"code": "insufficient_coverage", "certainty": "measured"}]'::jsonb
             || case when p_record_gap = 'lost'
                     then '[{"code": "records_missing", "certainty": "measured"}]'::jsonb else '[]'::jsonb end;
  elsif coalesce(p_saturation, false) then
    quality_class := 'poor'; quality_conf := 0.9;
    v_server := '[{"code": "optical_saturation", "certainty": "confirmed"}]';
  elsif p_hr_grade = 'poor' then
    quality_class := 'poor'; quality_conf := 0.8;
  elsif v_moving then
    quality_class := 'fair'; quality_conf := 0.6;
    v_server := '[{"code": "hr_in_motion_unverified", "certainty": "inferred"}]';
  elsif p_hr_grade = 'degraded' then
    quality_class := 'fair'; quality_conf := 0.7;
  elsif p_hr_grade = 'good' then
    quality_class := 'good'; quality_conf := 0.9;
  elsif p_hr_mean is not null and coalesce(p_rr_n, 0) >= 0.5 * p_hr_mean then
    quality_class := 'good'; quality_conf := 0.6;
  else
    quality_class := 'fair'; quality_conf := 0.5;
    v_server := '[{"code": "insufficient_coverage", "certainty": "measured"}]';
  end if;
  select coalesce(jsonb_agg(r order by o), '[]') into reasons
    from (select distinct on (r ->> 'code') r, o
            from jsonb_array_elements(v_server || v_phone) with ordinality x(r, o)
           order by r ->> 'code', o) d;
end $$;
revoke all on function internal.measurement_context_quality_v1(integer, real, integer, real, integer, integer, text,
  text, boolean, boolean, text, text, text[]) from public, anon, authenticated, service_role;

-- 5. Builder ---------------------------------------------------------------------------------------------------
create or replace function internal.measurement_context_version_id(p_backfill boolean)
returns smallint language sql stable security definer set search_path = '' as $$
  select v.id from public.measurement_context_versions v
   where v.builder_version = 'mcm-1' and v.rule_ids = array['exercise-session-1', 'mcq-1']
     and v.reason_codes_version = 'data-reason-1' and v.backfill = coalesce(p_backfill, false)
$$;
revoke all on function internal.measurement_context_version_id(boolean) from public, anon, authenticated, service_role;

-- Stage segments of a scored night ([{start, end, stage}], stored as a jsonb array or as a JSON string), keeping
-- only well-formed segments; NULL when there are none.
create or replace function internal.measurement_context_stage_segments(p_stages jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_stages;
begin
  if v is null then return null; end if;
  if jsonb_typeof(v) = 'string' then
    begin
      v := (v #>> '{}')::jsonb;
    exception when others then
      return null;
    end;
  end if;
  if jsonb_typeof(v) is distinct from 'array' then return null; end if;
  return (select jsonb_agg(jsonb_build_object('s', (s ->> 'start')::numeric::bigint, 'e', (s ->> 'end')::numeric::bigint,
                                              'stage', lower(btrim(s ->> 'stage'))) order by o)
            from jsonb_array_elements(v) with ordinality t(s, o)
           where jsonb_typeof(s) = 'object' and jsonb_typeof(s -> 'start') = 'number'
             and jsonb_typeof(s -> 'end') = 'number' and jsonb_typeof(s -> 'stage') = 'string'
             and (s ->> 'end')::numeric > (s ->> 'start')::numeric);
end $$;
revoke all on function internal.measurement_context_stage_segments(jsonb) from public, anon, authenticated, service_role;

create or replace function internal.build_measurement_context_minutes_v1(
  p_user uuid, p_device uuid, p_from timestamptz, p_to timestamptz, p_backfill boolean)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_now bigint := (floor(extract(epoch from clock_timestamp()) / 60) * 60)::bigint;
  v_from bigint;
  v_to bigint;
  v_lo bigint;
  v_hi bigint;
  v_day_lo date;
  v_day_hi date;
  v_version smallint;
  v_through bigint;
  v_contact text;
  v_profile_tz text;
  v_hr double precision[];
  v_strong boolean[];
  v_weak boolean[];
  v_still boolean[];
  v_night double precision[];
  v_changed integer;
  v_skip text[] := array['context_version', 'revision', 'computed_at', 'v18_n', 'sentinel_n', 'baseline_max',
                         'record_gap', 'hr_grade', 'beats_grade', 'phone_reasons', 'phone_quality_version'];
  v_span record;
begin
  if p_user is null or p_device is null or p_from is null or p_to is null
     or not isfinite(p_from) or not isfinite(p_to) then
    raise exception 'measurement_context_invalid_span';
  end if;
  if not exists (select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'measurement_context_device_owner';
  end if;
  v_from := (floor(extract(epoch from p_from) / 60) * 60)::bigint;
  v_to := least((ceil(extract(epoch from p_to) / 60) * 60)::bigint, v_now);
  if v_to <= v_from then return 0; end if;
  if v_to - v_from > 3 * 86400 then raise exception 'measurement_context_span_too_long'; end if;
  -- Session evidence reaches 6 h back (the 2 h rest window and pre-session reference of a period that started
  -- before the span) and 4 h ahead (a period that ends after the span decides the phase of its minutes inside it).
  v_lo := v_from - 6 * 3600;
  v_hi := least(v_to + 4 * 3600, v_now);
  v_day_lo := (to_timestamp(v_lo) at time zone 'UTC')::date - 1;
  v_day_hi := (to_timestamp(v_hi) at time zone 'UTC')::date + 1;
  perform pg_advisory_xact_lock(hashtextextended('measurement-context:' || p_user::text || ':' || p_device::text, 0));
  v_version := internal.measurement_context_version_id(p_backfill);
  if v_version is null then raise exception 'measurement_context_version_missing'; end if;

  -- Scratch tables live for the transaction (a cron run builds several days in one).
  if to_regclass('pg_temp.mc_grid') is null then
    create temp table mc_grid (
      m bigint primary key,
      hr_n integer, hr_mean double precision, hr_min integer, hr_max integer,
      rr_n integer, rr_suspect_n integer,
      dyn_n integer, dyn_mean double precision, dyn_p90 double precision,
      steps_n integer, step_walk_n integer, step_run_n integer,
      skin_temp_n integer, skin_raw_mean double precision,
      band_sleep_state integer, band_asleep boolean,
      observed_s integer, max_ingested_at timestamptz,
      wrist_event text, wrist_last_ts bigint, wrist_last_off boolean, wrist_closed boolean,
      contact_state text, ble_link_down_s integer, reset_event boolean, saturation_event boolean, charging boolean,
      tz_raw text, tz text, tz_basis text, local_day date, utc_offset_s integer,
      ep_class text, ep_conf real, ep_posture text, ep_exertion text, ep_ref bigint, ep_wear text,
      ep_strong boolean, ep_weak boolean,
      run_class text, run_conf real, run_ref bigint, run_wear text,
      sleep_state text, sleep_basis text, wear_state text, wear_basis text,
      strong boolean, weak boolean, still boolean, night_rest double precision,
      session_phase text, session_start bigint, session_basis text
    ) on commit drop;
    create temp table mc_events (ts bigint, kind text) on commit drop;
    create temp table mc_contact (m bigint primary key, c text) on commit drop;
    create temp table mc_battery (ts bigint, charging boolean) on commit drop;
    create temp table mc_new (like public.measurement_context_minutes) on commit drop;
  end if;
  truncate pg_temp.mc_grid, pg_temp.mc_events, pg_temp.mc_contact, pg_temp.mc_battery, pg_temp.mc_new;

  -- OBSERVED: per-minute aggregates by primary-key range.
  insert into pg_temp.mc_grid (m, hr_n, hr_mean, hr_min, hr_max, rr_n, rr_suspect_n, dyn_n, dyn_mean, dyn_p90,
                               steps_n, step_walk_n, step_run_n, skin_temp_n, skin_raw_mean, band_sleep_state,
                               band_asleep, observed_s, max_ingested_at, reset_event, saturation_event)
  select g.m, coalesce(h.n, 0), h.mean, h.lo, h.hi, coalesce(r.n, 0), coalesce(r.suspect, 0),
         coalesce(gr.n, 0), gr.mean, gr.p90, coalesce(st.n, 0), coalesce(st.walk, 0), coalesce(st.run, 0),
         coalesce(sk.n, 0), sk.mean, sl.state, sl.asleep, coalesce(o.n, 0),
         nullif(greatest(coalesce(h.ing, '-infinity'), coalesce(r.ing, '-infinity'), coalesce(gr.ing, '-infinity'),
                         coalesce(st.ing, '-infinity'), coalesce(sk.ing, '-infinity'), coalesce(sl.ing, '-infinity')),
                '-infinity'::timestamptz),
         false, false
    from generate_series(v_lo, v_hi - 60, 60) g(m)
    left join (select ts - ts % 60 as m, count(*)::integer as n, avg(bpm)::float8 as mean, min(bpm) as lo,
                      max(bpm) as hi, max(ingested_at) as ing
                 from public.noop_hr_samples
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) h on h.m = g.m
    left join (select ts - ts % 60 as m, count(*)::integer as n,
                      count(*) filter (where coalesce("tsSuspect", 0) <> 0)::integer as suspect, max(ingested_at) as ing
                 from public.noop_rr_intervals
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) r on r.m = g.m
    left join (select ts - ts % 60 as m, count("dynAccel")::integer as n, avg("dynAccel")::float8 as mean,
                      percentile_cont(0.9) within group (order by "dynAccel") as p90, max(ingested_at) as ing
                 from public.noop_gravity_samples
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) gr on gr.m = g.m
    left join (select ts - ts % 60 as m, count(*)::integer as n,
                      count(*) filter (where coalesce("activityClass", activity_class) = 1)::integer as walk,
                      count(*) filter (where coalesce("activityClass", activity_class) = 2)::integer as run,
                      max(ingested_at) as ing
                 from public.noop_step_samples
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) st on st.m = g.m
    left join (select ts - ts % 60 as m, count(*)::integer as n, avg(raw)::float8 as mean, max(ingested_at) as ing
                 from public.noop_skin_temp_samples
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) sk on sk.m = g.m
    left join (select ts - ts % 60 as m, mode() within group (order by state) as state,
                      avg((state = 2)::integer) >= 0.5 as asleep, max(ingested_at) as ing
                 from public.noop_sleep_state_samples
                where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi group by 1) sl on sl.m = g.m
    left join (select u.ts - u.ts % 60 as m, count(*)::integer as n
                 from (select ts from public.noop_hr_samples
                        where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi
                       union
                       select ts from public.noop_gravity_samples
                        where user_id = p_user and device_id = p_device and ts >= v_lo and ts < v_hi) u
                group by 1) o on o.m = g.m;

  -- OBSERVED: strap events. Wrist, link, charging, reset and saturation events are rare; they are read 24 h back
  -- (an open WRIST_OFF or charging edge still holds). Contact is a state uploaded on every change and more.
  insert into pg_temp.mc_events (ts, kind)
  select e.ts, e.kind from public.noop_events e
   where e.user_id = p_user and e.device_id = p_device and e.ts >= v_lo - 86400 and e.ts < v_hi
     and e.kind <> 'STANDARD_HR_CONTACT'
     and (e.kind like 'WRIST\_O%' or e.kind like 'BLE\_CONNECTION\_UP%' or e.kind like 'BLE\_CONNECTION\_DOWN%'
          or e.kind like 'CHARGING\_O%' or e.kind like 'BOOT%' or e.kind like 'RTC\_LOST%'
          or e.kind like 'BLE\_SYSTEM\_RESET%' or e.kind like 'CH1\_SATURATION%' or e.kind like 'CH2\_SATURATION%'
          or e.kind like 'ACCELEROMETER\_SATURATION%' or e.kind like 'ACCEL\_SATURATION%' or e.kind like 'AFE\_RESET%');

  update pg_temp.mc_grid g set wrist_event = x.e
    from (select ts - ts % 60 as m,
                 case when bool_or(kind like 'WRIST\_OFF%') and bool_or(kind like 'WRIST\_ON%') then 'on_off'
                      when bool_or(kind like 'WRIST\_OFF%') then 'off' else 'on' end as e
            from pg_temp.mc_events where kind like 'WRIST\_O%' and ts >= v_lo group by 1) x
   where g.m = x.m;
  -- Wear by event: the latest wrist event before the minute ends. A WRIST_OFF is closed by a later WRIST_ON, or by
  -- sustained heart rate (5 minutes with >= 30 s of HR each, all after the OFF): a missed WRIST_ON must not leave
  -- days of worn data marked off-wrist.
  update pg_temp.mc_grid g set wrist_last_ts = x.ts, wrist_last_off = x.off
    from (select g2.m, w.ts, w.off from pg_temp.mc_grid g2
           cross join lateral (select e.ts, e.kind like 'WRIST\_OFF%' as off from pg_temp.mc_events e
                                where e.kind like 'WRIST\_O%' and e.ts < g2.m + 60
                                order by e.ts desc limit 1) w) x
   where g.m = x.m;
  update pg_temp.mc_grid g set wrist_closed = x.closed
    from (select y.m, bool_or(y.sustained and y.m - 240 > y.wrist_last_ts)
                        over (partition by y.wrist_last_ts order by y.m) as closed
            from (select m, wrist_last_ts,
                         count(*) filter (where hr_n >= 30) over (order by m rows between 4 preceding and current row) = 5
                           as sustained
                    from pg_temp.mc_grid) y) x
   where g.m = x.m and g.wrist_last_off;
  -- Link down: each BLE_CONNECTION_DOWN until the next link event (open at the end: until the span's end).
  update pg_temp.mc_grid g set ble_link_down_s = x.sec
    from (select g2.m, least(60, sum(greatest(0, least(sp.e, g2.m + 60) - greatest(sp.s, g2.m))))::integer as sec
            from pg_temp.mc_grid g2
            join (select ts as s, coalesce(lead(ts) over (order by ts), v_hi) as e, kind like 'BLE\_CONNECTION\_DOWN%' as down
                    from pg_temp.mc_events where kind like 'BLE\_CONNECTION\_%') sp
              on sp.down and sp.s < g2.m + 60 and sp.e > g2.m
           group by g2.m) x
   where g.m = x.m and x.sec > 0;
  update pg_temp.mc_grid g set reset_event = true
    from (select distinct ts - ts % 60 as m from pg_temp.mc_events
           where ts >= v_lo and (kind like 'BOOT%' or kind like 'RTC\_LOST%' or kind like 'BLE\_SYSTEM\_RESET%')) x
   where g.m = x.m;
  update pg_temp.mc_grid g set saturation_event = true
    from (select distinct ts - ts % 60 as m from pg_temp.mc_events
           where ts >= v_lo and (kind like '%SATURATION%' or kind like 'AFE\_RESET%')) x
   where g.m = x.m;
  -- Charging: the newest of a CHARGING_ON/OFF edge in the last 24 h and a battery row with its charging bit in
  -- the last 60 min, as of the minute's end. NULL when nothing says.
  insert into pg_temp.mc_battery (ts, charging)
  select b.ts, b.charging from public.noop_battery_samples b
   where b.user_id = p_user and b.device_id = p_device and b.ts >= v_lo - 3600 and b.ts < v_hi
     and b.charging is not null;
  update pg_temp.mc_grid g set charging = x.c
    from (select g2.m,
                 (select u.c from (select e.ts, e.kind like 'CHARGING\_ON%' as c, 1 as pri from pg_temp.mc_events e
                                    where e.kind like 'CHARGING\_O%' and e.ts < g2.m + 60 and e.ts >= g2.m + 60 - 86400
                                   union all
                                   select bt.ts, bt.charging, 2 from pg_temp.mc_battery bt
                                    where bt.ts < g2.m + 60 and bt.ts >= g2.m + 60 - 3600) u
                   order by u.ts desc, u.pri limit 1) as c
            from pg_temp.mc_grid g2) x
   where g.m = x.m and x.c is not null;
  -- Contact (standard HR service): the latest state at or before the minute, carried from up to 24 h before.
  insert into pg_temp.mc_contact (m, c)
  select distinct on (e.ts - e.ts % 60) e.ts - e.ts % 60,
         substring(e."payloadJSON" from '"contact"\s*:\s*"([a-z_]+)"')
    from public.noop_events e
   where e.user_id = p_user and e.device_id = p_device and e.kind = 'STANDARD_HR_CONTACT'
     and e.ts >= v_lo and e.ts < v_hi
   order by e.ts - e.ts % 60, e.ts desc;
  select substring(e."payloadJSON" from '"contact"\s*:\s*"([a-z_]+)"') into v_contact
    from public.noop_events e
   where e.user_id = p_user and e.device_id = p_device and e.kind = 'STANDARD_HR_CONTACT'
     and e.ts >= v_lo - 86400 and e.ts < v_lo
   order by e.ts desc limit 1;
  update pg_temp.mc_grid g
     set contact_state = case x.c when 'unsupported' then 'unsupported' when 'supported_detected' then 'detected'
                                  when 'supported_not_detected' then 'not_detected' end
    from (select k.m, coalesce(max(k.c) over (partition by k.grp), v_contact) as c
            from (select g2.m, mc.c, count(mc.c) over (order by g2.m) as grp
                    from pg_temp.mc_grid g2 left join pg_temp.mc_contact mc on mc.m = g2.m) k) x
   where g.m = x.m;

  -- Local time: the zone in effect at the minute (history, else profile, else UTC), DST-correct.
  select p.timezone into v_profile_tz from public.profiles p where p.id = p_user;
  update pg_temp.mc_grid g
     set tz_raw = coalesce(x.tz, v_profile_tz),
         tz_basis = case when x.tz is not null then 'timezone_history'
                         when v_profile_tz is not null then 'profile' else 'default_utc' end
    from (select g2.m, (select h.timezone_id from public.scoring_timezone_history h
                         where h.user_id = p_user and h.effective_at <= to_timestamp(g2.m)
                         order by h.effective_at desc limit 1) as tz
            from pg_temp.mc_grid g2) x
   where g.m = x.m;
  update pg_temp.mc_grid g set tz = z.zone,
         tz_basis = case when z.zone = 'UTC' and g.tz_raw is distinct from 'UTC' then 'default_utc' else g.tz_basis end
    from (select d.tz_raw, internal.scoring_zone_checked_v2(d.tz_raw) as zone
            from (select distinct tz_raw from pg_temp.mc_grid) d) z
   where g.tz_raw is not distinct from z.tz_raw;
  update pg_temp.mc_grid g
     set local_day = (to_timestamp(g.m) at time zone g.tz)::date,
         utc_offset_s = extract(epoch from (to_timestamp(g.m) at time zone g.tz)
                                         - (to_timestamp(g.m) at time zone 'UTC'))::integer
   where true;  -- (an explicit WHERE: PostgREST sessions load safeupdate, which refuses a bare UPDATE)

  -- COPIED: activity from the current epoch lineage (each 30 s epoch lands in the minute(s) it overlaps; the
  -- epoch covering most of the minute, then the most confident, is copied) ...
  update pg_temp.mc_grid g
     set ep_class = x.motion_label, ep_conf = x.confidence, ep_posture = x.posture, ep_exertion = x.exertion_context,
         ep_ref = x.result_revision, ep_wear = x.wear_state
    from (select distinct on (mm.m) mm.m, e.motion_label, e.confidence, e.posture, e.exertion_context,
                 e.result_revision, e.wear_state
            from public.activity_context_epochs_current e
           cross join lateral (select distinct v.m from (values (e.start_ts - e.start_ts % 60),
                                                                ((e.end_ts - 1) - (e.end_ts - 1) % 60)) v(m)) mm
           where e.user_id = p_user and e.device_id = p_device and e.day between v_day_lo and v_day_hi
             and e.start_ts < v_hi and e.end_ts > v_lo
           order by mm.m, least(e.end_ts, mm.m + 60) - greatest(e.start_ts, mm.m) desc, e.confidence desc) x
   where g.m = x.m;
  -- ... and its movement evidence for rule exercise-session-1: a confident (>= 0.6) epoch of the minute that is
  -- walking / running, exertion active or inside a logged exercise is strong; other_movement is weak. An asleep or
  -- off-wrist epoch is never evidence.
  update pg_temp.mc_grid g set ep_strong = x.strong, ep_weak = x.weak
    from (select mm.m,
                 bool_or(e.motion_label in ('walking', 'running') or e.exertion_context = 'active'
                         or e.exercise_session = 'true') as strong,
                 bool_or(e.motion_label = 'other_movement') as weak
            from public.activity_context_epochs_current e
           cross join lateral (select distinct v.m from (values (e.start_ts - e.start_ts % 60),
                                                                ((e.end_ts - 1) - (e.end_ts - 1) % 60)) v(m)) mm
           where e.user_id = p_user and e.device_id = p_device and e.day between v_day_lo and v_day_hi
             and e.start_ts < v_hi and e.end_ts > v_lo
             and e.confidence >= 0.6 and e.wear_state <> 'off_wrist' and e.sleep_state <> 'asleep'
           group by mm.m) x
   where g.m = x.m;
  -- ... else the day document's runs (the run holding the minute's midpoint; raw-IMU documents first).
  update pg_temp.mc_grid g
     set run_class = x.cls, run_conf = x.conf, run_ref = x.result_revision, run_wear = x.wear_state
    from (select distinct on (mm) mm as m, coalesce(r.activity_class, r.display_context) as cls,
                 coalesce(r.class_confidence, r.confidence) as conf, r.result_revision, r.wear_state
            from public.activity_context_runs r
           cross join lateral generate_series(greatest(v_lo, ((r.start_ts - 30 + 59) / 60) * 60),
                                              least(v_hi - 60, ((r.end_ts - 31) / 60) * 60), 60) mm
           where r.user_id = p_user and r.device_id = p_device and r.day between v_day_lo and v_day_hi
             and r.start_ts < v_hi and r.end_ts > v_lo
           order by mm, r.source_rank, r.algorithm_version) x
   where g.m = x.m and g.ep_class is null;

  -- COPIED: sleep from the scored nights (frwhoop-server-1) holding the minute's midpoint.
  update pg_temp.mc_grid g set sleep_state = x.st, sleep_basis = x.basis
    from (select distinct on (g2.m) g2.m,
                 case when seg.stage is null then 'in_bed'
                      when seg.stage in ('wake', 'awake') then 'awake'
                      when seg.stage in ('light', 'deep', 'rem', 'asleep', 'core') then 'asleep'
                      else 'in_bed' end as st,
                 case when nt.segs is null then 'server_night' else 'server_night_stages' end as basis
            from pg_temp.mc_grid g2
            join (select n.start_at, n.end_at, internal.measurement_context_stage_segments(n.stages) as segs
                    from public.server_sleep_nights n
                   where n.user_id = p_user and n.device_id = p_device and n.algorithm_version = 'frwhoop-server-1'
                     and n.start_at < to_timestamp(v_hi) and n.start_at > to_timestamp(v_lo) - interval '2 days'
                     and n.end_at > to_timestamp(v_lo)) nt
              on to_timestamp(g2.m + 30) >= nt.start_at and to_timestamp(g2.m + 30) < nt.end_at
            left join lateral (select sg ->> 'stage' as stage from jsonb_array_elements(nt.segs) sg
                                where (sg ->> 's')::bigint <= g2.m + 30 and g2.m + 30 < (sg ->> 'e')::bigint
                                limit 1) seg on true
           order by g2.m, nt.start_at desc) x
   where g.m = x.m;
  update pg_temp.mc_grid g
     set sleep_basis = case when exists (select 1 from public.scoring_jobs_v2 j
                                          where j.user_id = p_user and j.device_id = p_device and j.day = g.local_day
                                            and j.algorithm_version = 'frwhoop-server-1' and j.completed_revision >= 1)
                            then 'outside_server_night' else 'not_scored' end
   where g.sleep_basis is null;

  -- COPIED: wear. Hardware evidence first (charging, wrist events), then the classifiers, then HR presence.
  update pg_temp.mc_grid g
     set wear_state = case
           when g.charging then 'charging'
           when g.wrist_last_off and not coalesce(g.wrist_closed, false) then 'off_wrist'
           when g.wrist_last_off is not null then 'on_wrist'
           when g.ep_wear in ('on_wrist', 'off_wrist') then g.ep_wear
           when g.run_wear in ('on_wrist', 'off_wrist') then g.run_wear
           when g.hr_n >= 30 then 'on_wrist' end,
         wear_basis = case
           when g.charging then 'charging'
           when g.wrist_last_off and not coalesce(g.wrist_closed, false) then 'wrist_event'
           when g.wrist_last_off = false then 'wrist_event'
           when g.wrist_last_off then 'hr_present'
           when g.ep_wear in ('on_wrist', 'off_wrist') then 'activity_epoch'
           when g.run_wear in ('on_wrist', 'off_wrist') then 'activity_run'
           when g.hr_n >= 30 then 'hr_present' else 'unknown' end
   where true;

  -- SESSION: HR-free evidence per minute (never asleep or off the wrist), the still minutes for the 2 h rest
  -- fallback, and the nightly resting HR of the 14 nights before each local day (within 60 days).
  update pg_temp.mc_grid g
     set strong = x.ok and ((g.steps_n > 0 and 2 * (g.step_walk_n + g.step_run_n) >= g.steps_n)
                            or coalesce(g.dyn_mean >= 0.10, false) or coalesce(g.ep_strong, false)),
         weak = x.ok and (coalesce(g.dyn_mean >= 0.05, false) or coalesce(g.ep_weak, false)),
         still = x.ok and g.hr_n >= 30 and g.dyn_n > 0 and g.dyn_mean < 0.05 and g.step_walk_n + g.step_run_n = 0
                 and not coalesce(g.ep_strong or g.ep_weak, false)
    from (select m, not (coalesce(wear_state in ('off_wrist', 'charging'), false) or coalesce(sleep_state = 'asleep', false)
                        or coalesce(band_asleep, false)) as ok
            from pg_temp.mc_grid) x
   where g.m = x.m;
  update pg_temp.mc_grid g set night_rest = r.v
    from (select d.local_day,
                 (select percentile_cont(0.5) within group (order by y.r)
                    from (select s.resting_hr_bpm::float8 as r from public.server_daily_scores s
                           where s.user_id = p_user and s.algorithm_version = 'frwhoop-server-1'
                             and s.resting_hr_bpm between 30 and 120
                             and s.day < d.local_day and s.day > d.local_day - 60
                           order by s.day desc limit 14) y) as v
            from (select distinct local_day from pg_temp.mc_grid) d) r
   where g.local_day = r.local_day;
  select array_agg(case when hr_n > 0 then hr_mean end order by m), array_agg(strong order by m),
         array_agg(weak order by m), array_agg(still order by m), array_agg(night_rest order by m)
    into v_hr, v_strong, v_weak, v_still, v_night
    from pg_temp.mc_grid;
  for v_span in select * from internal.exercise_session_spans_v1(v_hr, v_strong, v_weak, v_still, v_night) loop
    update pg_temp.mc_grid
       set session_phase = 'recovery', session_start = v_lo + v_span.a * 60, session_basis = v_span.rest_basis
     where m >= v_lo + (v_span.b + 1) * 60 and m < v_lo + v_span.recovery_end * 60 and session_phase is null;
    update pg_temp.mc_grid
       set session_phase = 'session', session_start = v_lo + v_span.a * 60, session_basis = v_span.rest_basis
     where m >= v_lo + v_span.a * 60 and m <= v_lo + v_span.b * 60;
  end loop;
  -- Outside sessions: 'none' where motion (or a known off-wrist / asleep state) could have shown movement, else
  -- unknown (NULL).
  update pg_temp.mc_grid g set session_phase = 'none'
   where g.session_phase is null
     and (g.dyn_n > 0 or g.steps_n > 0 or g.ep_class is not null
          or g.wear_state in ('off_wrist', 'charging') or g.sleep_state = 'asleep' or coalesce(g.band_asleep, false));

  -- Rows of the span, with the phone's columns carried from the stored rows.
  v_through := (select max(h.ts) from public.noop_hr_samples h where h.user_id = p_user and h.device_id = p_device);
  insert into pg_temp.mc_new (user_id, device_id, minute_start, local_day, utc_offset_s, tz_basis,
    hr_n, hr_mean, hr_min, hr_max, rr_n, rr_suspect_n, dyn_n, dyn_mean, dyn_p90, steps_n, step_walk_n, step_run_n,
    skin_temp_n, skin_temp_mean, band_sleep_state, wrist_event, contact_state, ble_link_down_s, reset_event,
    saturation_event, charging, max_ingested_at,
    v18_n, sentinel_n, baseline_max, record_gap, hr_grade, beats_grade, phone_reasons, phone_quality_version,
    quality_class, quality_conf, reasons,
    activity_class, activity_conf, posture, exertion, activity_basis, activity_ref,
    sleep_state, sleep_basis, wear_state, wear_basis, placement, placement_basis,
    session_phase, session_start, session_rule, session_basis, observed_s, missing_reasons,
    context_version, revision, computed_at)
  select p_user, p_device, to_timestamp(g.m), g.local_day, g.utc_offset_s, g.tz_basis,
         g.hr_n, g.hr_mean::real, g.hr_min, g.hr_max, g.rr_n, g.rr_suspect_n, g.dyn_n, g.dyn_mean::real,
         g.dyn_p90::real, g.steps_n, g.step_walk_n, g.step_run_n, g.skin_temp_n,
         case when g.skin_raw_mean between 2500 and 4500 then (g.skin_raw_mean / 100.0)::real end,
         g.band_sleep_state, g.wrist_event, g.contact_state, g.ble_link_down_s, g.reset_event, g.saturation_event,
         g.charging, g.max_ingested_at,
         o.v18_n, o.sentinel_n, o.baseline_max, o.record_gap, o.hr_grade, o.beats_grade, o.phone_reasons,
         o.phone_quality_version,
         q.quality_class, q.quality_conf, q.reasons,
         coalesce(g.ep_class, g.run_class), case when g.ep_class is not null then g.ep_conf else g.run_conf end,
         case when g.ep_class is not null then g.ep_posture end, case when g.ep_class is not null then g.ep_exertion end,
         case when g.ep_class is not null then 'activity_epoch' when g.run_class is not null then 'activity_run'
              else 'none' end,
         case when g.ep_class is not null then g.ep_ref else g.run_ref end,
         g.sleep_state, g.sleep_basis, g.wear_state, g.wear_basis, null, 'not_resolved',
         g.session_phase, case when g.session_start is not null then to_timestamp(g.session_start) end,
         case when g.session_phase is not null then 'exercise-session-1' end, g.session_basis,
         least(60, g.observed_s),
         case when g.hr_n > 0 then '[]'::jsonb else jsonb_build_array(case
             when g.wear_state = 'charging' then '{"code": "charging", "certainty": "confirmed"}'::jsonb
             when g.wear_state = 'off_wrist' then jsonb_build_object('code', 'off_wrist', 'certainty',
                    case when g.wear_basis = 'wrist_event' then 'confirmed' else 'inferred' end)
             when o.record_gap = 'paused' then '{"code": "strap_not_recording", "certainty": "confirmed"}'::jsonb
             when g.ble_link_down_s > 0 then '{"code": "strap_link_down", "certainty": "confirmed"}'::jsonb
             when o.record_gap = 'lost' then '{"code": "records_missing", "certainty": "measured"}'::jsonb
             when not p_backfill and (v_through is null or g.m > v_through)
               then '{"code": "awaiting_upload", "certainty": "inferred"}'::jsonb
             when g.wear_state = 'on_wrist' then '{"code": "sensor_dropout", "certainty": "inferred"}'::jsonb
             else '{"code": "insufficient_coverage", "certainty": "measured"}'::jsonb end) end
         || case when g.ep_class is null and g.run_class is null or g.session_phase is null
                 then '[{"code": "context_unknown", "certainty": "unknown"}]'::jsonb else '[]'::jsonb end,
         v_version, 0, clock_timestamp()
    from pg_temp.mc_grid g
    left join public.measurement_context_minutes o
      on o.user_id = p_user and o.device_id = p_device and o.minute_start = to_timestamp(g.m)
   cross join lateral internal.measurement_context_quality_v1(g.hr_n, g.hr_mean::real, g.rr_n, g.dyn_mean::real,
       g.steps_n, g.step_walk_n + g.step_run_n, g.wear_state, g.wear_basis, g.reset_event, g.saturation_event,
       o.record_gap, o.hr_grade, o.phone_reasons) q
   where g.m >= v_from and g.m < v_to;

  -- Write only what changed (the phone's columns are never written here).
  insert into public.measurement_context_minutes as t (user_id, device_id, minute_start, local_day, utc_offset_s,
    tz_basis, hr_n, hr_mean, hr_min, hr_max, rr_n, rr_suspect_n, dyn_n, dyn_mean, dyn_p90, steps_n, step_walk_n,
    step_run_n, skin_temp_n, skin_temp_mean, band_sleep_state, wrist_event, contact_state, ble_link_down_s,
    reset_event, saturation_event, charging, max_ingested_at, quality_class, quality_conf, reasons,
    activity_class, activity_conf, posture, exertion, activity_basis, activity_ref, sleep_state, sleep_basis,
    wear_state, wear_basis, placement, placement_basis, session_phase, session_start, session_rule, session_basis,
    observed_s, missing_reasons, context_version, revision, computed_at)
  select n.user_id, n.device_id, n.minute_start, n.local_day, n.utc_offset_s, n.tz_basis, n.hr_n, n.hr_mean,
         n.hr_min, n.hr_max, n.rr_n, n.rr_suspect_n, n.dyn_n, n.dyn_mean, n.dyn_p90, n.steps_n, n.step_walk_n,
         n.step_run_n, n.skin_temp_n, n.skin_temp_mean, n.band_sleep_state, n.wrist_event, n.contact_state,
         n.ble_link_down_s, n.reset_event, n.saturation_event, n.charging, n.max_ingested_at, n.quality_class,
         n.quality_conf, n.reasons, n.activity_class, n.activity_conf, n.posture, n.exertion, n.activity_basis,
         n.activity_ref, n.sleep_state, n.sleep_basis, n.wear_state, n.wear_basis, n.placement, n.placement_basis,
         n.session_phase, n.session_start, n.session_rule, n.session_basis, n.observed_s, n.missing_reasons,
         n.context_version, nextval('public.measurement_context_minutes_revision_seq'), clock_timestamp()
    from pg_temp.mc_new n
    left join public.measurement_context_minutes o
      on o.user_id = n.user_id and o.device_id = n.device_id and o.minute_start = n.minute_start
   where o.user_id is null or (to_jsonb(o) - v_skip) is distinct from (to_jsonb(n) - v_skip)
  on conflict (user_id, device_id, minute_start) do update set
    local_day = excluded.local_day, utc_offset_s = excluded.utc_offset_s, tz_basis = excluded.tz_basis,
    hr_n = excluded.hr_n, hr_mean = excluded.hr_mean, hr_min = excluded.hr_min, hr_max = excluded.hr_max,
    rr_n = excluded.rr_n, rr_suspect_n = excluded.rr_suspect_n, dyn_n = excluded.dyn_n,
    dyn_mean = excluded.dyn_mean, dyn_p90 = excluded.dyn_p90, steps_n = excluded.steps_n,
    step_walk_n = excluded.step_walk_n, step_run_n = excluded.step_run_n, skin_temp_n = excluded.skin_temp_n,
    skin_temp_mean = excluded.skin_temp_mean, band_sleep_state = excluded.band_sleep_state,
    wrist_event = excluded.wrist_event, contact_state = excluded.contact_state,
    ble_link_down_s = excluded.ble_link_down_s, reset_event = excluded.reset_event,
    saturation_event = excluded.saturation_event, charging = excluded.charging,
    max_ingested_at = excluded.max_ingested_at, quality_class = excluded.quality_class,
    quality_conf = excluded.quality_conf, reasons = excluded.reasons, activity_class = excluded.activity_class,
    activity_conf = excluded.activity_conf, posture = excluded.posture, exertion = excluded.exertion,
    activity_basis = excluded.activity_basis, activity_ref = excluded.activity_ref,
    sleep_state = excluded.sleep_state, sleep_basis = excluded.sleep_basis, wear_state = excluded.wear_state,
    wear_basis = excluded.wear_basis, placement = excluded.placement, placement_basis = excluded.placement_basis,
    session_phase = excluded.session_phase, session_start = excluded.session_start,
    session_rule = excluded.session_rule, session_basis = excluded.session_basis,
    observed_s = excluded.observed_s, missing_reasons = excluded.missing_reasons,
    context_version = excluded.context_version, revision = excluded.revision, computed_at = excluded.computed_at;
  get diagnostics v_changed = row_count;
  return v_changed;
end $$;
revoke all on function internal.build_measurement_context_minutes_v1(uuid, uuid, timestamptz, timestamptz, boolean)
  from public, anon, authenticated, service_role;

create or replace function internal.build_measurement_context_minutes(p_user uuid, p_device uuid, p_from timestamptz,
                                                                      p_to timestamptz)
returns integer language sql security definer set search_path = '' as $$
  select internal.build_measurement_context_minutes_v1(p_user, p_device, p_from, p_to, false)
$$;
revoke all on function internal.build_measurement_context_minutes(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

-- The zone in effect for a person at an instant, as the builder resolves it: scoring_timezone_history, else
-- profiles.timezone, else UTC (an unknown zone name is UTC).
create or replace function internal.measurement_context_zone_at(p_user uuid, p_at timestamptz)
returns text language sql stable security definer set search_path = '' as $$
  select internal.scoring_zone_checked_v2(coalesce(
    (select h.timezone_id from public.scoring_timezone_history h
      where h.user_id = p_user and h.effective_at <= p_at order by h.effective_at desc limit 1),
    (select p.timezone from public.profiles p where p.id = p_user)))
$$;
revoke all on function internal.measurement_context_zone_at(uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- Local day [00:00, 24:00) of `p_day` in the zone in effect at that day's UTC midnight.
create or replace function internal.measurement_context_day_span(p_user uuid, p_day date,
  out lo timestamptz, out hi timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare z text := internal.measurement_context_zone_at(p_user, p_day::timestamp at time zone 'UTC');
begin
  lo := p_day::timestamp at time zone z;
  hi := (p_day + 1)::timestamp at time zone z;
end $$;
revoke all on function internal.measurement_context_day_span(uuid, date) from public, anon, authenticated, service_role;

-- Backfill from stored rows only (rows tagged with the backfill version row): at most 31 local days per call,
-- oldest first. Returns the number of rows written.
create or replace function internal.backfill_measurement_context_minutes(p_user uuid, p_device uuid, p_from_day date,
                                                                         p_to_day date)
returns integer language plpgsql security definer set search_path = '' as $$
declare d date; sp record; n integer := 0;
begin
  if p_from_day is null or p_to_day is null or p_to_day < p_from_day or p_to_day - p_from_day > 30 then
    raise exception 'measurement_context_backfill_range';
  end if;
  for d in select generate_series(p_from_day, p_to_day, interval '1 day')::date loop
    select * into sp from internal.measurement_context_day_span(p_user, d);
    n := n + internal.build_measurement_context_minutes_v1(p_user, p_device, sp.lo, sp.hi, true);
  end loop;
  return n;
end $$;
revoke all on function internal.backfill_measurement_context_minutes(uuid, uuid, date, date)
  from public, anon, authenticated, service_role;

-- 6. Scheduling ------------------------------------------------------------------------------------------------
create table if not exists internal.measurement_context_work (
  user_id          uuid not null,
  device_id        uuid not null,
  day              date not null,
  scoring_revision bigint not null default 0,
  scored_revision  bigint not null default 0,
  activity_seen_at timestamptz,
  queued_at        timestamptz,
  built_at         timestamptz,
  attempts         integer not null default 0,
  last_error       text,
  primary key (user_id, device_id, day),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists measurement_context_work_queued on internal.measurement_context_work (queued_at)
  where queued_at is not null;
revoke all on internal.measurement_context_work from public, anon, authenticated, service_role;

-- Queue the local days whose inputs changed in the last p_since: a scoring job whose input revision (an upload) or
-- completed revision (new nights / daily scores) moved, or an activity document published for an overlapping UTC
-- day. Reads scoring_jobs_v2 and activity_context_days without locking them.
create or replace function internal.measurement_context_discover_v1(p_since interval default interval '2 days')
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer := 0; k integer;
begin
  insert into internal.measurement_context_work as w (user_id, device_id, day, scoring_revision, scored_revision,
                                                      queued_at)
  select j.user_id, j.device_id, j.day, j.input_revision, j.completed_revision, clock_timestamp()
    from public.scoring_jobs_v2 j
   where j.algorithm_version = 'frwhoop-server-1'
     and greatest(j.dirty_at, j.last_completed_at) > clock_timestamp() - p_since
  on conflict (user_id, device_id, day) do update
    set scoring_revision = greatest(w.scoring_revision, excluded.scoring_revision),
        scored_revision = greatest(w.scored_revision, excluded.scored_revision),
        queued_at = coalesce(w.queued_at, excluded.queued_at)
  where excluded.scoring_revision > w.scoring_revision or excluded.scored_revision > w.scored_revision;
  get diagnostics k = row_count; n := n + k;

  insert into internal.measurement_context_work as w (user_id, device_id, day, activity_seen_at, queued_at)
  select a.user_id, a.device_id, ld.day, max(a.computed_at), clock_timestamp()
    from public.activity_context_days a
   cross join lateral (select distinct (to_timestamp(t) at time zone
                                         internal.measurement_context_zone_at(a.user_id, to_timestamp(t)))::date as day
                         from unnest(array[extract(epoch from a.day::timestamp)::bigint,
                                           extract(epoch from (a.day + 1)::timestamp)::bigint - 1]) t) ld
   where a.computed_at > clock_timestamp() - p_since
   group by a.user_id, a.device_id, ld.day
  on conflict (user_id, device_id, day) do update
    set activity_seen_at = excluded.activity_seen_at, queued_at = coalesce(w.queued_at, excluded.queued_at)
  where w.activity_seen_at is null or excluded.activity_seen_at > w.activity_seen_at;
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;
revoke all on function internal.measurement_context_discover_v1(interval) from public, anon, authenticated, service_role;

-- Build queued days, oldest queue time first, at most p_max_days within p_budget. Each day rebuilds its local
-- [00:00 - 3 h, 24:00) span (the 3 h re-judge sessions that crossed midnight). A failing day backs off
-- exponentially (1 h .. 1 day) with its error kept; other days are unaffected.
create or replace function internal.measurement_context_process_v1(p_max_days integer default 12,
                                                                   p_budget interval default interval '40 seconds')
returns integer language plpgsql security definer set search_path = '' as $$
declare w record; sp record; started timestamptz := clock_timestamp(); n integer := 0;
begin
  for w in select * from internal.measurement_context_work
            where queued_at is not null and queued_at <= clock_timestamp()
            order by queued_at limit greatest(1, least(p_max_days, 100))
            for update skip locked loop
    exit when clock_timestamp() - started > p_budget;
    begin
      select * into sp from internal.measurement_context_day_span(w.user_id, w.day);
      perform internal.build_measurement_context_minutes_v1(w.user_id, w.device_id, sp.lo - interval '3 hours',
                                                            sp.hi, false);
      update internal.measurement_context_work
         set queued_at = null, built_at = clock_timestamp(), attempts = 0, last_error = null
       where user_id = w.user_id and device_id = w.device_id and day = w.day;
      n := n + 1;
    exception when others then
      update internal.measurement_context_work
         set attempts = attempts + 1, last_error = left(sqlerrm, 500),
             queued_at = clock_timestamp() + least(interval '1 hour' * power(2, least(attempts, 5)), interval '1 day')
       where user_id = w.user_id and device_id = w.device_id and day = w.day;
    end;
  end loop;
  return n;
end $$;
revoke all on function internal.measurement_context_process_v1(integer, interval)
  from public, anon, authenticated, service_role;

create or replace function internal.measurement_context_tick_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q integer; b integer;
begin
  q := internal.measurement_context_discover_v1();
  b := internal.measurement_context_process_v1();
  return jsonb_build_object('queued', q, 'built', b);
end $$;
revoke all on function internal.measurement_context_tick_v1() from public, anon, authenticated, service_role;

-- Guarded so a database without pg_cron still applies the migration.
do $$
begin
  if to_regclass('cron.job') is null then
    raise warning 'measurement_context_minutes: pg_cron absent; schedule internal.measurement_context_tick_v1 externally';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'frwhoop-measurement-context') then
    perform cron.unschedule('frwhoop-measurement-context');
  end if;
  perform cron.schedule('frwhoop-measurement-context', '*/5 * * * *', 'select internal.measurement_context_tick_v1()');
end $$;

-- 7. Read ------------------------------------------------------------------------------------------------------
-- GET scores/context-minutes: the owner's rows in [p_from, p_to) (at most 1440 minutes), one device or every device
-- of the owner (p_device NULL), oldest first, at most 1440 rows (truncated says more exist). Reasons come back with
-- their effect and family from public.reason_codes; versions lists every context_version the rows reference.
create or replace function public.measurement_context_minutes_read_v1(p_user uuid, p_device uuid, p_from timestamptz,
                                                                     p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rows jsonb; v_versions jsonb; v_count integer;
begin
  if p_user is null or p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '1440 minutes' then
    raise exception 'measurement_context_invalid_range';
  end if;
  if p_device is not null and not exists (select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'measurement_context_device_owner';
  end if;
  with picked as (
    select t.* from public.measurement_context_minutes t
     where t.user_id = p_user and (p_device is null or t.device_id = p_device)
       and t.minute_start >= p_from and t.minute_start < p_to
     order by t.minute_start, t.device_id
     limit 1441)
  select count(*), coalesce(jsonb_agg(
           (to_jsonb(t) - array['user_id', 'minute_start', 'session_start', 'reasons', 'missing_reasons', 'rn'])
           || jsonb_build_object(
                'minute_start', extract(epoch from t.minute_start)::bigint,
                'session_start', extract(epoch from t.session_start)::bigint,
                'reasons', (select coalesce(jsonb_agg(x.r || jsonb_strip_nulls(jsonb_build_object(
                                     'effect', rc.effect, 'family', rc.family)) order by x.o), '[]')
                              from jsonb_array_elements(t.reasons) with ordinality x(r, o)
                              left join public.reason_codes rc on rc.code = x.r ->> 'code'),
                'missing_reasons', (select coalesce(jsonb_agg(x.r || jsonb_strip_nulls(jsonb_build_object(
                                     'effect', rc.effect, 'family', rc.family)) order by x.o), '[]')
                                      from jsonb_array_elements(t.missing_reasons) with ordinality x(r, o)
                                      left join public.reason_codes rc on rc.code = x.r ->> 'code'))
           order by t.minute_start, t.device_id) filter (where t.rn <= 1440), '[]')
    into v_count, v_rows
    from (select p.*, row_number() over (order by p.minute_start, p.device_id) as rn from picked p) t;
  select coalesce(jsonb_object_agg(v.id::text, jsonb_build_object('builder_version', v.builder_version,
           'rule_ids', to_jsonb(v.rule_ids), 'reason_codes_version', v.reason_codes_version, 'backfill', v.backfill)),
           '{}')
    into v_versions
    from public.measurement_context_versions v
   where v.id in (select (r ->> 'context_version')::smallint from jsonb_array_elements(v_rows) r);
  return jsonb_build_object('rows', v_rows, 'versions', v_versions, 'truncated', v_count > 1440);
end $$;
revoke all on function public.measurement_context_minutes_read_v1(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.measurement_context_minutes_read_v1(uuid, uuid, timestamptz, timestamptz)
  to service_role;

commit;
