-- POST scores/quality-minutes: the phone's per-minute optical evidence into measurement_context_minutes.
--
-- WHY
-- Only the phone sees the strap's v18 aux records (optical amplitude sentinel, optical baselines, record-index
-- continuity); the server never receives them (audit B-quality). Without them the server cannot tell motion-mode
-- optics from good contact, or a strap that paused recording from data lost in transport. The phone grades each
-- minute itself (Watchdog quality) and sends the evidence and grades; the server stores them in the PHONE columns of
-- measurement_context_minutes (20261009130100) and re-derives that minute's quality and missing reasons with the
-- same builder and rule (mcq-1) every other row uses.
--
-- WHAT CHANGES
--   public.measurement_context_quality_upsert_v1(user, device, version, minutes)  service only (the scores route,
--     owner and device from the credential). minutes: a JSON array of at most 1440 objects
--     {minute_start (unix, minute aligned), v18_n, sentinel_n, baseline_max, record_gap, hr_grade, beats_grade,
--     reasons}; see docs/context-watchdog/MEASUREMENT_CONTEXT.md. Validates again (the route already did), builds
--     any completed minute that has no row yet, writes the phone columns where they differ (revision bump), then
--     rebuilds those minutes so quality_class / reasons / missing_reasons follow. Idempotent: the same payload
--     again changes nothing. Returns {accepted, changed}: minutes stored (a minute not yet complete is not), and
--     minutes whose phone columns changed. Unknown legacy reason codes are kept in phone_reasons as sent and are
--     left out of the canonical reasons.
--
-- Safe to re-run. Rollback: drop function public.measurement_context_quality_upsert_v1(uuid, uuid, text, jsonb).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.measurement_context_quality_upsert_v1(p_user uuid, p_device uuid, p_version text,
                                                                        p_minutes jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_now bigint := extract(epoch from clock_timestamp())::bigint;
  v_bad integer;
  v_lo bigint;
  v_hi bigint;
  v_changed bigint[];
  v_accepted integer;
begin
  if p_user is null or p_device is null then raise exception 'invalid_quality_minutes'; end if;
  if p_version is null or p_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then
    raise exception 'invalid_quality_minutes';
  end if;
  if jsonb_typeof(p_minutes) is distinct from 'array' or jsonb_array_length(p_minutes) not between 1 and 1440 then
    raise exception 'invalid_quality_minutes';
  end if;
  if not exists (select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'measurement_context_device_owner';
  end if;

  -- Every element well formed; NULL (or absent) optional fields are allowed, unknown keys are ignored.
  select count(*) into v_bad
    from jsonb_array_elements(p_minutes) e
   where not (
     jsonb_typeof(e) = 'object'
     and jsonb_typeof(e -> 'minute_start') = 'number'
     and (e ->> 'minute_start')::numeric % 60 = 0
     and (e ->> 'minute_start')::numeric between 1577836800 and v_now + 120
     and coalesce(jsonb_typeof(e -> 'v18_n'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'sentinel_n'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'baseline_max'), 'null') in ('null', 'number')
     and (jsonb_typeof(e -> 'v18_n') is distinct from 'number'
          or ((e ->> 'v18_n')::numeric % 1 = 0 and (e ->> 'v18_n')::numeric between 0 and 120))
     and (jsonb_typeof(e -> 'sentinel_n') is distinct from 'number'
          or ((e ->> 'sentinel_n')::numeric % 1 = 0 and (e ->> 'sentinel_n')::numeric between 0 and 120))
     and (jsonb_typeof(e -> 'baseline_max') is distinct from 'number'
          or ((e ->> 'baseline_max')::numeric % 1 = 0 and (e ->> 'baseline_max')::numeric between 0 and 65535))
     and (jsonb_typeof(e -> 'v18_n') is distinct from 'number' or jsonb_typeof(e -> 'sentinel_n') is distinct from 'number'
          or (e ->> 'sentinel_n')::numeric <= (e ->> 'v18_n')::numeric)
     and (coalesce(jsonb_typeof(e -> 'record_gap'), 'null') = 'null'
          or (jsonb_typeof(e -> 'record_gap') = 'string' and e ->> 'record_gap' in ('paused', 'lost')))
     and (coalesce(jsonb_typeof(e -> 'hr_grade'), 'null') = 'null'
          or (jsonb_typeof(e -> 'hr_grade') = 'string' and e ->> 'hr_grade' in ('good', 'degraded', 'poor', 'unknown')))
     and (coalesce(jsonb_typeof(e -> 'beats_grade'), 'null') = 'null'
          or (jsonb_typeof(e -> 'beats_grade') = 'string'
              and e ->> 'beats_grade' in ('good', 'degraded', 'poor', 'unknown')))
     and (coalesce(jsonb_typeof(e -> 'reasons'), 'null') = 'null'
          or (jsonb_typeof(e -> 'reasons') = 'array' and jsonb_array_length(e -> 'reasons') <= 32
              and not exists (select 1 from jsonb_array_elements(e -> 'reasons') x
                               where jsonb_typeof(x) is distinct from 'string'
                                  or x #>> '{}' !~ '^[a-z][a-z0-9_]{0,63}$'))));
  if v_bad > 0 then raise exception 'invalid_quality_minutes'; end if;

  if to_regclass('pg_temp.mcq_in') is null then
    create temp table mcq_in (
      m bigint primary key, v18_n smallint, sentinel_n smallint, baseline_max integer, record_gap text,
      hr_grade text, beats_grade text, reasons text[]
    ) on commit drop;
  end if;
  truncate pg_temp.mcq_in;
  begin
    insert into pg_temp.mcq_in (m, v18_n, sentinel_n, baseline_max, record_gap, hr_grade, beats_grade, reasons)
    select (e ->> 'minute_start')::numeric::bigint, (e ->> 'v18_n')::numeric::smallint,
           (e ->> 'sentinel_n')::numeric::smallint, (e ->> 'baseline_max')::numeric::integer,
           e ->> 'record_gap', e ->> 'hr_grade', e ->> 'beats_grade',
           case when jsonb_typeof(e -> 'reasons') = 'array'
                then array(select x #>> '{}' from jsonb_array_elements(e -> 'reasons') with ordinality r(x, o) order by o)
           end
      from jsonb_array_elements(p_minutes) e;
  exception when unique_violation then
    raise exception 'invalid_quality_minutes';  -- the same minute twice
  end;
  select min(m), max(m) into v_lo, v_hi from pg_temp.mcq_in;
  if v_hi - v_lo >= 3 * 86400 then raise exception 'invalid_quality_minutes'; end if;

  perform pg_advisory_xact_lock(hashtextextended('measurement-context:' || p_user::text || ':' || p_device::text, 0));
  -- Rows for every completed minute of the payload (the builder creates the ones not built yet).
  select min(i.m), max(i.m) into v_lo, v_hi
    from pg_temp.mcq_in i
   where not exists (select 1 from public.measurement_context_minutes t
                      where t.user_id = p_user and t.device_id = p_device and t.minute_start = to_timestamp(i.m));
  if v_lo is not null then
    perform internal.build_measurement_context_minutes(p_user, p_device, to_timestamp(v_lo), to_timestamp(v_hi + 60));
  end if;

  with changed as (
    update public.measurement_context_minutes t
       set v18_n = i.v18_n, sentinel_n = i.sentinel_n, baseline_max = i.baseline_max, record_gap = i.record_gap,
           hr_grade = i.hr_grade, beats_grade = i.beats_grade, phone_reasons = i.reasons,
           phone_quality_version = p_version,
           revision = nextval('public.measurement_context_minutes_revision_seq'), computed_at = clock_timestamp()
      from pg_temp.mcq_in i
     where t.user_id = p_user and t.device_id = p_device and t.minute_start = to_timestamp(i.m)
       and (t.v18_n, t.sentinel_n, t.baseline_max, t.record_gap, t.hr_grade, t.beats_grade, t.phone_reasons,
            t.phone_quality_version)
           is distinct from (i.v18_n, i.sentinel_n, i.baseline_max, i.record_gap, i.hr_grade, i.beats_grade, i.reasons,
                             p_version)
    returning i.m)
  select coalesce(array_agg(m), '{}') into v_changed from changed;
  -- Quality and missing reasons follow the new evidence (same builder, rule mcq-1).
  if cardinality(v_changed) > 0 then
    perform internal.build_measurement_context_minutes(p_user, p_device,
      to_timestamp((select min(x) from unnest(v_changed) x)), to_timestamp((select max(x) from unnest(v_changed) x) + 60));
  end if;
  select count(*) into v_accepted
    from pg_temp.mcq_in i
    join public.measurement_context_minutes t
      on t.user_id = p_user and t.device_id = p_device and t.minute_start = to_timestamp(i.m);
  return jsonb_build_object('accepted', v_accepted, 'changed', cardinality(v_changed));
end $$;
revoke all on function public.measurement_context_quality_upsert_v1(uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.measurement_context_quality_upsert_v1(uuid, uuid, text, jsonb) to service_role;

commit;
