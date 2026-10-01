-- A live upload re-dirties its own day and the two after it (a night window reaches past midnight),
-- and every enqueue restarts dirty_at. While a strap streams, the hour-old escape therefore never
-- fires and `day desc` gives every turn to a day that has not begun yet, so today never scores.
create function internal.scoring_owner_today_v2(p_user uuid) returns date
language plpgsql set search_path=public as $$
declare zone text;
begin
  select p.timezone into zone from profiles p where p.id=p_user;
  return (clock_timestamp() at time zone coalesce(zone,'UTC'))::date;
exception when invalid_parameter_value then
  return (clock_timestamp() at time zone 'UTC')::date;
end $$;
revoke all on function internal.scoring_owner_today_v2(uuid) from public,anon,authenticated,service_role;

create or replace function internal.claim_scoring_v2(p_version text, p_lease_seconds integer default 300)
returns setof public.scoring_jobs_v2 language plpgsql security definer set search_path = public as $$
declare j scoring_jobs_v2;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  -- A single runnable claim. Oldest-served users get a turn; their current days run first.
  with owners as materialized (
    select o.user_id, internal.scoring_owner_today_v2(o.user_id) as today
    from (select distinct s.user_id from scoring_jobs_v2 s where s.algorithm_version=p_version
            and s.completed_revision<s.input_revision and not s.dead_letter) o)
  select q.* into j from scoring_jobs_v2 q join owners o on o.user_id=q.user_id
  where q.algorithm_version=p_version and q.completed_revision<q.input_revision
    and not q.dead_letter and q.not_before<=clock_timestamp()
    and (q.lease_until is null or q.lease_until<=clock_timestamp())
    and exists(select 1 from scoring_algorithms_v2 a where a.algorithm_version=p_version and a.enabled)
    and not exists(select 1 from scoring_invalidations_v2 i where i.user_id=q.user_id and i.device_id=q.device_id
      and i.algorithm_version=q.algorithm_version and q.day between i.next_day and i.through_day)
  order by coalesce((select max(s.last_claimed_at) from scoring_jobs_v2 s where s.user_id=q.user_id),
                    '-infinity'::timestamptz),
           -- A day waiting over an hour takes precedence over continuous current-day updates.
           (q.dirty_at < clock_timestamp()-interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp()-interval '1 hour' then q.dirty_at end,
           -- A day that has not begun for its owner never outranks today.
           q.day > o.today,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update scoring_jobs_v2 q set lease_token=gen_random_uuid(),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),
    last_claimed_at=clock_timestamp(), claim_count=q.claim_count+1,
    lease_expiry_count=q.lease_expiry_count+case when q.lease_token is null then 0 else 1 end
  where q.user_id=j.user_id and q.device_id=j.device_id and q.day=j.day and q.algorithm_version=j.algorithm_version
  returning q.*;
end $$;
