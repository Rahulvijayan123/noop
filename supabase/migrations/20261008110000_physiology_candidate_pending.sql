-- Persisted, fair candidate scheduling (Spec 01 section 5; docs/model-integration/runtime-bounds.md).
-- Additive only: one new table, five new functions, and an additive replacement of
-- physiology_selected_provider that keeps every existing key and adds four. No existing table,
-- default, trigger or published result changes, and nothing here can write canonical physiology.
--
-- Why. The worker's candidate stage used to run the enabled metrics in a fixed order inside a
-- per-drain run budget (FRWHOOP_INFERENCE_BUDGET, default 2). A budget skip was only a counter, so
-- with more enabled metrics than the budget the last ones never ran for a day unless the day was
-- re-scored, and nothing showed it. Here every enabled metric of a scored day becomes one row at the
-- claim's input revision, and the worker claims the OLDEST due row first, across metrics and days:
--
--   * enqueue    a scored day's metrics at its input revision. A newer revision re-arms the row
--                (attempts reset, lease dropped) but keeps its place in line while it is still
--                pending, so a day that is re-scored every few minutes cannot push its own
--                unserved metrics to the back. A stale revision changes nothing.
--   * claim      the oldest due row, under a lease (token, owner, until). A row whose day has a
--                newer input revision is superseded inside the call and never handed out. An
--                expired lease (the holder died) counts as an attempt.
--   * settle     under the lease and the input revision: a lost lease (expired, or reset by a
--                newer revision) or a stale revision is refused and changes nothing. busy, timeout,
--                budget and deadline keep the row pending with that reason; only an attempt that
--                really ran is counted, and attempts are bounded: the last one settles as withheld.
--   * stats      queue depth, due/leased counts and the oldest pending age, for the heartbeat.
--   * physiology_candidate_current_revision  the same input-revision lookup the record RPC
--                (physiology_record_candidate_result) fences its write on.
--
-- The candidate RESULT is still written only by physiology_record_candidate_result with its own
-- input-revision fence; this table only decides what runs next and why something has not.
-- Service role only: RLS on with no policy, client roles revoked, every function security definer
-- with an empty search_path, the same shape as 20261002090000_physiology_candidate_providers.sql.
-- A worker built before this migration never calls these functions; a worker built after it probes
-- for physiology_candidate_pending_claim and schedules in memory while it is absent.
-- Not applied to production by this change.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- ---------------------------------------------------------------------------
-- 1. Pending candidate work, one row per (user, device, day, metric)
-- ---------------------------------------------------------------------------
create table if not exists public.physiology_candidate_pending (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null check (device_id<>''),
  period_day date not null,
  metric text not null check (metric in ('hrv','sleep_boundary','sleep_stage','respiration')),
  -- The scoring input revision this row is for; every settle is fenced on it.
  input_revision bigint not null check (input_revision>=1),
  -- The selection seen at enqueue (informational: the worker re-reads the selection before it runs).
  provider_id text not null check (provider_id<>''),
  provider_version text not null check (provider_version<>''),
  config_version text not null check (config_version<>''),
  requested_mode text not null check (requested_mode in ('shadow','active')),
  state text not null default 'pending' check (state in ('pending','done','withheld','superseded')),
  -- Attempts that really ran (busy, budget and deadline skips are not attempts).
  attempts integer not null default 0 check (attempts>=0),
  last_reason text check (last_reason is null or length(last_reason)<=200),
  -- The candidate row the run recorded, when it recorded one.
  candidate_id uuid,
  -- Fair order: when this row last became pending. Kept across revisions while still pending.
  pending_since timestamptz not null default clock_timestamp(),
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_token uuid,
  lease_owner text,
  lease_until timestamptz,
  claimed_at timestamptz,
  settled_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, period_day, metric),
  check ((lease_token is null)=(lease_until is null)),
  check (state='pending' or lease_token is null)
);
create index if not exists physiology_candidate_pending_order_idx
  on public.physiology_candidate_pending (pending_since, period_day) where state='pending';
create index if not exists physiology_candidate_pending_settled_idx
  on public.physiology_candidate_pending (settled_at) where state in ('withheld','superseded');

comment on table public.physiology_candidate_pending is
  'Candidate work per (user, device, day, metric) at a scoring input revision. state pending = '
  'waiting (last_reason says why: busy, budget, deadline, timeout, ...); done = ran and settled; '
  'withheld = will not run at this revision (no_input, demoted active, attempts_exhausted:<reason>); '
  'superseded = a newer revision, a switched-off selection or a deleted owner. Claimed oldest '
  'pending_since first. Service role only. Results live in physiology_candidate_results.';

-- ---------------------------------------------------------------------------
-- 2. The current input revision (the record RPC's own fence, as a read)
-- ---------------------------------------------------------------------------
-- Same three-step lookup as physiology_record_candidate_result: the device's job for the active
-- algorithm, then any device's for the active algorithm, then any job of the day. NULL when the
-- day has no scoring job at all.
create or replace function public.physiology_candidate_current_revision(p_user uuid, p_device text,
  p_day date)
returns bigint language plpgsql stable security definer set search_path='' as $$
declare v_current bigint;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
   where j.user_id=p_user and j.day=p_day and j.device_id::text=p_device
     and j.algorithm_version=(select algorithm_version from public.scoring_algorithms_v2 where active);
  if v_current is null then
    select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
     where j.user_id=p_user and j.day=p_day
       and j.algorithm_version=(select algorithm_version from public.scoring_algorithms_v2 where active);
  end if;
  if v_current is null then
    select max(j.input_revision) into v_current from public.scoring_jobs_v2 j
     where j.user_id=p_user and j.day=p_day;
  end if;
  return v_current;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Enqueue one scored day's enabled metrics
-- ---------------------------------------------------------------------------
-- p_entries: [{"metric","provider_id","provider_version","config_version","requested_mode",
-- "has_input"}]. has_input=false (the scoring pass built no payload for the metric) settles the
-- row at once as withheld 'no_input' for this revision: there is nothing to run. Returns the number
-- of rows inserted or re-armed; an unchanged row and a stale revision count 0. A malformed batch
-- raises before anything is written; a deleted owner or a foreign device returns 0.
create or replace function public.physiology_candidate_pending_enqueue(p_user uuid, p_device text,
  p_day date, p_input_revision bigint, p_entries jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare
  e jsonb; v_current bigint; v_changed integer:=0; v_rows integer;
  v_now timestamptz:=clock_timestamp(); v_has_input boolean;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  if p_user is null or p_device is null or p_device='' or p_day is null then
    raise exception 'invalid_candidate_pending_key' using errcode='22023';
  end if;
  if p_input_revision is null or p_input_revision<1 then
    raise exception 'invalid_candidate_input_revision' using errcode='22023';
  end if;
  if coalesce(jsonb_typeof(p_entries),'null')<>'array' or jsonb_array_length(p_entries)>8 then
    raise exception 'invalid_candidate_pending_entries' using errcode='22023';
  end if;
  for e in select value from jsonb_array_elements(p_entries) loop
    if jsonb_typeof(e)<>'object'
      or coalesce(e->>'metric','') not in ('hrv','sleep_boundary','sleep_stage','respiration')
      or coalesce(e->>'provider_id','')='' or coalesce(e->>'provider_version','')=''
      or coalesce(e->>'config_version','')=''
      or coalesce(e->>'requested_mode','') not in ('shadow','active')
      or coalesce(jsonb_typeof(e->'has_input'),'null')<>'boolean' then
      raise exception 'invalid_candidate_pending_entries' using errcode='22023';
    end if;
  end loop;

  -- Owner isolation and deletion, as the record RPC: nothing is queued for a deleted owner.
  if not exists(select 1 from auth.users u where u.id=p_user) then return 0; end if;
  if not exists(select 1 from public.devices d where d.user_id=p_user and d.id::text=p_device) then
    return 0;
  end if;
  -- A pass computed against an older generation must not re-arm the newer one.
  v_current:=public.physiology_candidate_current_revision(p_user,p_device,p_day);
  if v_current is not null and p_input_revision<v_current then return 0; end if;

  for e in select value from jsonb_array_elements(p_entries) loop
    v_has_input:=(e->>'has_input')::boolean;
    insert into public.physiology_candidate_pending as p (user_id,device_id,period_day,metric,
      input_revision,provider_id,provider_version,config_version,requested_mode,state,attempts,
      last_reason,pending_since,next_attempt_at,settled_at,created_at,updated_at)
    values (p_user,p_device,p_day,e->>'metric',p_input_revision,e->>'provider_id',
      e->>'provider_version',e->>'config_version',e->>'requested_mode',
      case when v_has_input then 'pending' else 'withheld' end,0,
      case when v_has_input then null else 'no_input' end,v_now,v_now,
      case when v_has_input then null else v_now end,v_now,v_now)
    on conflict (user_id,device_id,period_day,metric) do update set
      input_revision=excluded.input_revision,
      provider_id=excluded.provider_id, provider_version=excluded.provider_version,
      config_version=excluded.config_version, requested_mode=excluded.requested_mode,
      state=excluded.state, attempts=0, last_reason=excluded.last_reason, candidate_id=null,
      -- Fairness: a row that is still waiting keeps its place in line.
      pending_since=case when p.state='pending' and excluded.state='pending' then p.pending_since
                         else excluded.pending_since end,
      next_attempt_at=excluded.next_attempt_at,
      -- Dropping the lease is what refuses the previous revision's settle.
      lease_token=null, lease_owner=null, lease_until=null, claimed_at=null,
      settled_at=excluded.settled_at, updated_at=v_now
    where p.input_revision<excluded.input_revision
       or (p.input_revision=excluded.input_revision
           and (p.provider_id,p.provider_version,p.config_version,p.requested_mode)
               is distinct from (excluded.provider_id,excluded.provider_version,
                                 excluded.config_version,excluded.requested_mode));
    get diagnostics v_rows=row_count;
    v_changed:=v_changed+v_rows;
  end loop;
  return v_changed;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Claim the oldest due item under a lease
-- ---------------------------------------------------------------------------
-- Due: pending, next_attempt_at reached, no live lease. Order: pending_since, then day, then the
-- metric order, then owner, so every metric of a day is reached in turn whatever the run budget.
-- Returns one item as jsonb, or NULL when nothing is due.
create or replace function public.physiology_candidate_pending_claim(p_owner text,
  p_lease_seconds integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  r public.physiology_candidate_pending; v_current bigint; v_now timestamptz;
  v_prior_reason text; v_abandoned boolean; v_scanned integer:=0;
begin
  -- Cross-user by nature: no client JWT subject may claim.
  if auth.uid() is not null then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  if p_owner is null or p_owner='' or length(p_owner)>200 then
    raise exception 'invalid_lease_owner' using errcode='22023';
  end if;
  if p_lease_seconds is null or p_lease_seconds<1 or p_lease_seconds>3600 then
    raise exception 'invalid_lease' using errcode='22023';
  end if;
  loop
    v_now:=clock_timestamp();
    select * into r from public.physiology_candidate_pending p
     where p.state='pending' and p.next_attempt_at<=v_now
       and (p.lease_until is null or p.lease_until<=v_now)
     order by p.pending_since, p.period_day,
       array_position(array['hrv','sleep_boundary','sleep_stage','respiration'],p.metric),
       p.user_id, p.device_id
     limit 1
     for update skip locked;
    if not found then return null; end if;
    v_scanned:=v_scanned+1;
    v_current:=public.physiology_candidate_current_revision(r.user_id,r.device_id,r.period_day);
    if v_current is not null and r.input_revision<v_current then
      -- Computed now it could only be refused by the record RPC: retire it, never hand it out.
      update public.physiology_candidate_pending set state='superseded',
        last_reason='stale_input_revision', lease_token=null, lease_owner=null, lease_until=null,
        settled_at=v_now, updated_at=v_now
       where user_id=r.user_id and device_id=r.device_id and period_day=r.period_day
         and metric=r.metric;
      -- Bounded per call; the next claim continues.
      if v_scanned>=64 then return null; end if;
      continue;
    end if;
    v_prior_reason:=r.last_reason;
    -- A lease that expired unsettled means the holder died mid-run: that run counts, so a row
    -- that keeps killing its worker still reaches the attempt bound.
    v_abandoned:=r.lease_token is not null;
    update public.physiology_candidate_pending set lease_token=gen_random_uuid(),
      lease_owner=p_owner, lease_until=v_now+make_interval(secs=>p_lease_seconds),
      claimed_at=v_now, attempts=attempts+case when v_abandoned then 1 else 0 end,
      last_reason=case when v_abandoned then 'lease_expired' else last_reason end,
      updated_at=v_now
     where user_id=r.user_id and device_id=r.device_id and period_day=r.period_day
       and metric=r.metric
     returning * into r;
    return jsonb_build_object('user_id',r.user_id,'device_id',r.device_id,
      'period_day',r.period_day,'metric',r.metric,'input_revision',r.input_revision,
      'provider_id',r.provider_id,'provider_version',r.provider_version,
      'config_version',r.config_version,'requested_mode',r.requested_mode,
      'attempts',r.attempts,'last_reason',coalesce(r.last_reason,v_prior_reason),
      'pending_since',r.pending_since,'lease_token',r.lease_token,'lease_owner',r.lease_owner,
      'lease_until',r.lease_until);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Settle a claimed item under its lease and input revision
-- ---------------------------------------------------------------------------
-- p_outcome: done | withheld | superseded (final for this revision) | retry (stays pending until
-- now + p_retry_after_seconds). p_count_attempt is true only when a computation really ran.
-- A retry whose counted attempts reach p_max_attempts settles as withheld
-- 'attempts_exhausted:<reason>' (the server-side bound; the worker normally settles that itself).
-- Returns {"settled": true, "state", "attempts"} or {"settled": false, "refused": <why>} with
-- why in not_found | stale_input_revision | not_pending | lease_lost; a refusal changes nothing.
create or replace function public.physiology_candidate_pending_settle(p_user uuid, p_device text,
  p_day date, p_metric text, p_input_revision bigint, p_lease_token uuid, p_outcome text,
  p_reason text, p_candidate_id uuid, p_count_attempt boolean, p_retry_after_seconds integer,
  p_max_attempts integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  r public.physiology_candidate_pending; v_now timestamptz:=clock_timestamp();
  v_attempts integer; v_state text; v_reason text;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  if p_metric is null or p_metric not in ('hrv','sleep_boundary','sleep_stage','respiration') then
    raise exception 'invalid_candidate_metric' using errcode='22023';
  end if;
  if p_outcome is null or p_outcome not in ('done','withheld','superseded','retry') then
    raise exception 'invalid_candidate_pending_outcome' using errcode='22023';
  end if;
  if p_reason is null or p_reason='' or length(p_reason)>200 then
    raise exception 'invalid_candidate_pending_reason' using errcode='22023';
  end if;
  if p_lease_token is null then
    raise exception 'invalid_lease' using errcode='22023';
  end if;
  if p_max_attempts is null or p_max_attempts<1 or p_max_attempts>100 then
    raise exception 'invalid_candidate_pending_attempts' using errcode='22023';
  end if;
  if p_retry_after_seconds is not null and (p_retry_after_seconds<0 or p_retry_after_seconds>86400) then
    raise exception 'invalid_candidate_pending_retry_after' using errcode='22023';
  end if;

  select * into r from public.physiology_candidate_pending p
   where p.user_id=p_user and p.device_id=p_device and p.period_day=p_day and p.metric=p_metric
   for update;
  if not found then
    return jsonb_build_object('settled',false,'refused','not_found');
  end if;
  -- A newer revision re-armed the row: this work is stale whatever its outcome.
  if r.input_revision is distinct from p_input_revision then
    return jsonb_build_object('settled',false,'refused','stale_input_revision',
      'input_revision',r.input_revision);
  end if;
  if r.state<>'pending' then
    return jsonb_build_object('settled',false,'refused','not_pending','state',r.state);
  end if;
  if r.lease_token is null or r.lease_token is distinct from p_lease_token
    or r.lease_until<=v_now then
    return jsonb_build_object('settled',false,'refused','lease_lost');
  end if;

  v_attempts:=r.attempts+case when coalesce(p_count_attempt,false) then 1 else 0 end;
  v_state:=p_outcome; v_reason:=p_reason;
  if p_outcome='retry' then
    v_state:='pending';
    if coalesce(p_count_attempt,false) and v_attempts>=p_max_attempts then
      v_state:='withheld'; v_reason:=left('attempts_exhausted:'||p_reason,200);
    end if;
  end if;
  update public.physiology_candidate_pending set state=v_state, attempts=v_attempts,
    last_reason=v_reason,
    candidate_id=case when v_state in ('done','withheld') then p_candidate_id else candidate_id end,
    next_attempt_at=case when v_state='pending'
      then v_now+make_interval(secs=>coalesce(p_retry_after_seconds,0)) else next_attempt_at end,
    lease_token=null, lease_owner=null, lease_until=null,
    settled_at=case when v_state='pending' then null else v_now end, updated_at=v_now
   where user_id=r.user_id and device_id=r.device_id and period_day=r.period_day
     and metric=r.metric;
  return jsonb_build_object('settled',true,'state',v_state,'attempts',v_attempts,
    'reason',v_reason);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Queue stats for the worker heartbeat
-- ---------------------------------------------------------------------------
create or replace function public.physiology_candidate_pending_stats()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_now timestamptz:=clock_timestamp(); v jsonb;
begin
  if auth.uid() is not null then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  select jsonb_build_object(
    'pending',count(*),
    'due',count(*) filter (where p.next_attempt_at<=v_now
                             and (p.lease_until is null or p.lease_until<=v_now)),
    'leased',count(*) filter (where p.lease_until>v_now),
    'oldest_pending_age_s',coalesce(floor(extract(epoch from v_now-min(p.pending_since)))::bigint,0),
    'by_metric',coalesce((select jsonb_object_agg(m.metric,m.n) from (
        select q.metric, count(*) n from public.physiology_candidate_pending q
         where q.state='pending' group by q.metric) m),'{}'::jsonb),
    'by_reason',coalesce((select jsonb_object_agg(m.reason,m.n) from (
        select coalesce(q.last_reason,'new') reason, count(*) n
          from public.physiology_candidate_pending q
         where q.state='pending' group by 1) m),'{}'::jsonb))
    into v
    from public.physiology_candidate_pending p where p.state='pending';
  return v||jsonb_build_object(
    'withheld_24h',(select count(*) from public.physiology_candidate_pending q
                     where q.state='withheld' and q.settled_at>v_now-interval '24 hours'),
    'superseded_24h',(select count(*) from public.physiology_candidate_pending q
                       where q.state='superseded' and q.settled_at>v_now-interval '24 hours'),
    'at',v_now);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Selection read: requested and effective mode (additive keys only)
-- ---------------------------------------------------------------------------
-- Same signature, security, caller check and existing keys (provider_id, provider_version,
-- config_version, mode, source) as 20261002090000. Added: requested_mode (what the selection
-- asked for), demoted (an active request the promotion gate refused), effective_mode (what a
-- candidate of this selection is downstream: 'shadow' for every computed mode, because no
-- validated path publishes canonical physiology from a candidate yet) and mode_reason (why the
-- effective mode differs: the gate's reason, or active_promotion_deferred).
create or replace function public.physiology_selected_provider(p_user uuid, p_metric text)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare act jsonb; v_mode text; v_demoted boolean;
begin
  -- Explicit caller authorization (spec S14); the inner activation re-checks it too.
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode='22023';
  end if;
  act:=public.physiology_candidate_activation(p_user,p_metric);
  v_mode:=act->>'mode';
  v_demoted:=coalesce((act->>'demoted')::boolean,false);
  return jsonb_build_object('provider_id',act->'provider_id','provider_version',act->'provider_version',
    'config_version',act->'config_version','mode',v_mode,'source',act->>'source',
    'requested_mode',act->>'requested_mode','demoted',v_demoted,
    'effective_mode',case when v_mode='off' then 'off' else 'shadow' end,
    'mode_reason',case when v_demoted
                         then coalesce(act->'approval'->>'reason','promotion_approval_required')
                       when v_mode='active' then 'active_promotion_deferred' end);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Privileges: service role only
-- ---------------------------------------------------------------------------
alter table public.physiology_candidate_pending enable row level security;
revoke all on table public.physiology_candidate_pending from public, anon, authenticated;
grant all on table public.physiology_candidate_pending to service_role;

revoke all on function public.physiology_candidate_current_revision(uuid,text,date) from public,anon,authenticated;
grant execute on function public.physiology_candidate_current_revision(uuid,text,date) to service_role;
revoke all on function public.physiology_candidate_pending_enqueue(uuid,text,date,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.physiology_candidate_pending_enqueue(uuid,text,date,bigint,jsonb) to service_role;
revoke all on function public.physiology_candidate_pending_claim(text,integer) from public,anon,authenticated;
grant execute on function public.physiology_candidate_pending_claim(text,integer) to service_role;
revoke all on function public.physiology_candidate_pending_settle(uuid,text,date,text,bigint,uuid,text,text,uuid,boolean,integer,integer) from public,anon,authenticated;
grant execute on function public.physiology_candidate_pending_settle(uuid,text,date,text,bigint,uuid,text,text,uuid,boolean,integer,integer) to service_role;
revoke all on function public.physiology_candidate_pending_stats() from public,anon,authenticated;
grant execute on function public.physiology_candidate_pending_stats() to service_role;
-- Unchanged grant set, restated so this file is correct on its own.
revoke all on function public.physiology_selected_provider(uuid,text) from public,anon,authenticated;
grant execute on function public.physiology_selected_provider(uuid,text) to service_role;

comment on function public.physiology_candidate_pending_claim(text,integer) is
  'Lease the oldest due candidate item (pending_since, day, metric order). Items whose day has a '
  'newer scoring input revision are superseded here and never returned. NULL when nothing is due.';
comment on function public.physiology_candidate_pending_settle(uuid,text,date,text,bigint,uuid,text,text,uuid,boolean,integer,integer) is
  'Settle a claimed item. Refused (settled=false, nothing changed) for a lost lease or a stale '
  'input revision. retry keeps it pending with its reason; counted attempts are bounded.';
comment on function public.physiology_candidate_current_revision(uuid,text,date) is
  'The scoring input revision physiology_record_candidate_result fences candidate writes on.';

commit;
