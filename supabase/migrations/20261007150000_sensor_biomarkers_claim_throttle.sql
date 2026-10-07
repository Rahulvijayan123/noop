-- Sensor biomarkers: recompute the current UTC day at most once an hour.
--
-- Every phone upload bumps the current day's job, and a day job recomputes the whole day so far
-- (up to ~10 worker-minutes for a full day of 100 Hz IMU). Once a day has published, its job is
-- only claimable again after an hour; past days and never-published days are unaffected, and the
-- day stays dirty, so the final upload of a day is still picked up.

begin;

create or replace function public.claim_sensor_biomarker_day(p_lease_seconds integer default 300)
returns setof public.sensor_biomarker_jobs language plpgsql security definer set search_path='' as $$
declare j public.sensor_biomarker_jobs;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from public.sensor_biomarker_jobs q
  where q.completed_revision < q.input_revision and not q.dead_letter and q.not_before <= clock_timestamp()
    and (q.lease_until is null or q.lease_until <= clock_timestamp())
    and not (q.day = (clock_timestamp() at time zone 'UTC')::date
             and q.completed_revision > 0
             and q.last_completed_at > clock_timestamp() - interval '1 hour')
  order by coalesce((select max(s.last_claimed_at) from public.sensor_biomarker_jobs s where s.user_id = q.user_id),
                    '-infinity'::timestamptz),
           (q.dirty_at < clock_timestamp() - interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp() - interval '1 hour' then q.dirty_at end,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update public.sensor_biomarker_jobs q set lease_token = gen_random_uuid(),
    lease_until = clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = clock_timestamp(), claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day
    and q.analysis_version = j.analysis_version
  returning q.*;
end $$;

revoke all on function public.claim_sensor_biomarker_day(integer) from public, anon, authenticated;
grant execute on function public.claim_sensor_biomarker_day(integer) to service_role;

commit;
