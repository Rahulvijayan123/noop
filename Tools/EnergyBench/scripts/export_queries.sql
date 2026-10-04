-- export_queries.sql — read-only templates for pulling ONE wearer's days into `energy-bench-day-v1` bundles.
--
-- Run them against the scoring database with psql variables (or substitute the literals), save each result
-- set as JSON OUTSIDE the repository, and hand the files to `assemble_day_bundles.py`. Nothing here writes.
--
--   :user_id     the wearer's auth uuid (one wearer per bundle set — never export other users' rows)
--   :device_id   the strap's device uuid
--   :day         local calendar day, e.g. '2026-10-02'
--   :day_start   epoch seconds of that day's LOCAL midnight  (= UTC midnight of :day − tz offset)
--
-- Every stream is delta-encoded as "dt a b …" items joined by commas, the first dt being 0 and `t0` the
-- absolute epoch of the first sample, which keeps a 24 h, 1 Hz day to a few hundred kilobytes.

-- 1. Heart rate: "dt bpm" ------------------------------------------------------------------------------
with s as (
  select ts, bpm, ts - lag(ts, 1, ts) over (order by ts) as dt
  from public.noop_hr_samples
  where user_id = :'user_id'::uuid and device_id = :'device_id'::uuid
    and ts >= :day_start and ts < :day_start + 86400
)
select :'day' as day, 'hr' as stream, min(ts) as t0, count(*) as n,
       string_agg(dt || ' ' || bpm, ',' order by ts) as v
from s;

-- 2. Step counter: "dt counter activityClass" (empty class = NULL) ------------------------------------------
with s as (
  select ts, counter, "activityClass" as ac, ts - lag(ts, 1, ts) over (order by ts) as dt
  from public.noop_step_samples
  where user_id = :'user_id'::uuid and device_id = :'device_id'::uuid
    and ts >= :day_start and ts < :day_start + 86400
)
select :'day' as day, 'steps' as stream, min(ts) as t0, count(*) as n,
       string_agg(dt || ' ' || counter || ' ' || coalesce(ac::text, ''), ',' order by ts) as v
from s;

-- 3. Gravity: "dt x y z dyn", all four ×10⁴ and rounded (empty dyn = NULL: WHOOP 4.0 / older firmware) -----
with s as (
  select ts, round(x * 10000)::int as x, round(y * 10000)::int as y, round(z * 10000)::int as z,
         round("dynAccel" * 10000)::int as dyn, ts - lag(ts, 1, ts) over (order by ts) as dt
  from public.noop_gravity_samples
  where user_id = :'user_id'::uuid and device_id = :'device_id'::uuid
    and ts >= :day_start and ts < :day_start + 86400
)
select :'day' as day, 'gravity' as stream, min(ts) as t0, count(*) as n,
       string_agg(dt || ' ' || x || ' ' || y || ' ' || z || ' ' || coalesce(dyn::text, ''), ',' order by ts) as v
from s;

-- 4. Scored nights — one meta file for the whole range (pass it to the assembler as --meta) ---------------
--    Add `and algorithm_version = …` for the version your deployment reads.
select 'sleep' as stream,
       json_agg(json_build_object(
         'start', extract(epoch from start_at)::bigint, 'end', extract(epoch from end_at)::bigint,
         'nap', is_nap, 'rhr', resting_hr_bpm, 'asleep_min', asleep_min,
         'period_day', period_day, 'device', device_id) order by start_at) as v
from public.server_sleep_nights
where user_id = :'user_id'::uuid and period_day between :'first_day'::date and :'last_day'::date + 1;

-- 5. Daily resting HR as the scoring pipeline stored it ---------------------------------------------------
select 'rhr' as stream,
       json_agg(json_build_object('day', day, 'rhr', resting_hr_bpm, 'device', source_device_id) order by day) as v
from public.server_daily_scores
where user_id = :'user_id'::uuid and day between :'first_day'::date and :'last_day'::date;
