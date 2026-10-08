-- Activity expert release authority (docs/model-integration/activity-authority.md).
--
-- 1. The two expert tables (ElderNet gait windows, Inertia / ActiNet motion heads) gain the release a row was
--    produced under (`release_mode`) and the producer's authority block (`authority`: the shared policy's inputs
--    and its decision for the row). The worker writes the block inside the row's `summary` (`summary.authority`),
--    which the existing publish functions already store verbatim, and a trigger copies it here: the publish
--    functions are not replaced, an older worker keeps working (its rows carry no block), and a newer worker
--    against a database without this migration simply keeps the block in `summary`.
--    `release_mode` is never above the row's own `mode` (shadow / candidate), so no row here can ever read as
--    production. A row without a block (written before this migration or by an older worker) reads as its
--    recorded mode; the shared policy then lowers it further (no pins: shadow).
-- 2. `activity_candidate_days`: the joint candidate decode of a day (HART plus every expert channel the policy
--    admits for candidate decodes) and its ablations, written through its own fenced RPC only while some expert
--    runs in candidate mode. Never published, never read by scoring or the app: service role only.
--
-- Additive and idempotent: new nullable columns, a trigger, a new table, one new fenced publish function and a
-- retention function. Nothing here changes the activity job queue, the published activity documents, their
-- publish functions or any existing read. Rollback = leave the worker without candidate experts; the columns and
-- the table can stay.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Release columns ------------------------------------------------------------------------------------------

alter table public.activity_gait_windows_days
  add column if not exists release_mode text,
  add column if not exists authority jsonb;
alter table public.activity_gait_windows_days
  drop constraint if exists activity_gait_windows_days_release_mode_check,
  add constraint activity_gait_windows_days_release_mode_check
    check (release_mode is null or release_mode = 'shadow' or release_mode = mode),
  drop constraint if exists activity_gait_windows_days_authority_check,
  add constraint activity_gait_windows_days_authority_check
    check (authority is null or jsonb_typeof(authority) = 'object');

alter table public.activity_motion_heads_days
  add column if not exists release_mode text,
  add column if not exists authority jsonb;
alter table public.activity_motion_heads_days
  drop constraint if exists activity_motion_heads_days_release_mode_check,
  add constraint activity_motion_heads_days_release_mode_check
    check (release_mode is null or release_mode = 'shadow' or release_mode = mode),
  drop constraint if exists activity_motion_heads_days_authority_check,
  add constraint activity_motion_heads_days_authority_check
    check (authority is null or jsonb_typeof(authority) = 'object');

-- The release of a row: its mode, lowered (never raised) by the producer's block. A block whose release is
-- missing or unknown lowers to shadow.
create or replace function internal.activity_expert_release(p_mode text, p_authority jsonb)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_mode is distinct from 'candidate' then 'shadow'
    when p_authority is null then 'candidate'
    when p_authority ->> 'release_mode' in ('candidate', 'production') then 'candidate'
    else 'shadow'
  end
$$;
revoke all on function internal.activity_expert_release(text, jsonb) from public, anon, authenticated, service_role;

create or replace function internal.activity_gait_windows_authority()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.authority := case when jsonb_typeof(new.summary -> 'authority') = 'object' then new.summary -> 'authority' end;
  new.release_mode := internal.activity_expert_release(new.mode, new.authority);
  return new;
end $$;
revoke all on function internal.activity_gait_windows_authority() from public, anon, authenticated, service_role;

-- Motion heads: a stand-in encoder or a bundle evaluated only to the shadow tier is shadow whatever the mode
-- (the same lowering as ActivityExpertSelection.motionRelease).
create or replace function internal.activity_motion_heads_authority()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.authority := case when jsonb_typeof(new.summary -> 'authority') = 'object' then new.summary -> 'authority' end;
  new.release_mode := case
    when new.encoder_kind not in ('inertia1', 'actinet') or new.evidence_tier_max = 'shadow' then 'shadow'
    else internal.activity_expert_release(new.mode, new.authority)
  end;
  return new;
end $$;
revoke all on function internal.activity_motion_heads_authority() from public, anon, authenticated, service_role;

drop trigger if exists activity_gait_windows_days_authority on public.activity_gait_windows_days;
create trigger activity_gait_windows_days_authority
  before insert or update on public.activity_gait_windows_days
  for each row execute function internal.activity_gait_windows_authority();
drop trigger if exists activity_motion_heads_days_authority on public.activity_motion_heads_days;
create trigger activity_motion_heads_days_authority
  before insert or update on public.activity_motion_heads_days
  for each row execute function internal.activity_motion_heads_authority();

-- 2. Joint candidate days -------------------------------------------------------------------------------------

-- One row per (owner, device, UTC day): the newest job's selection (its policy version, the digest of its
-- decisions, every decision), the stored arms (HART alone, HART + each admitted expert, joint) with their
-- final-output summaries and comparisons against HART alone, and the joint ActivityContextDayDocument or why it
-- was withheld. A few hundred KB per day; `prune_activity_candidate_days` deletes rows older than 30 days.
create table if not exists public.activity_candidate_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  candidate_schema text not null check (candidate_schema = 'activity-candidate-1'),
  policy text not null check (policy ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  selection_digest text not null check (selection_digest ~ '^[0-9a-f]{64}$'),
  algorithm_version text not null check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  decisions jsonb not null check (jsonb_typeof(decisions) = 'array'),
  arms jsonb not null check (jsonb_typeof(arms) = 'object'),
  -- Never published, never copied into activity_context_days.
  joint_document jsonb check (joint_document is null or jsonb_typeof(joint_document) = 'object'),
  withheld_reason text check (withheld_reason is null or length(withheld_reason) between 1 and 240),
  result_revision bigint not null,
  created_at timestamptz not null default clock_timestamp(),
  computed_at timestamptz not null,
  primary key (user_id, device_id, day),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  constraint activity_candidate_days_joint_or_withheld check ((joint_document is null) <> (withheld_reason is null)),
  -- A joint document always names an expert that shaped it (`is not distinct from`: a missing stamp is false).
  constraint activity_candidate_days_joint_stamped check (joint_document is null
    or jsonb_typeof(joint_document -> 'versions' -> 'gait_quality') is not distinct from 'string'
    or jsonb_typeof(joint_document -> 'versions' -> 'motion_heads') is not distinct from 'string')
);
create sequence if not exists public.activity_candidate_days_result_revision_seq;
grant usage, select on sequence public.activity_candidate_days_result_revision_seq to service_role;

-- Worker-written and worker-read only: no owner read, so no app or route can ever show a candidate as a result.
alter table public.activity_candidate_days enable row level security;
revoke all on public.activity_candidate_days from public, anon, authenticated;
grant all on public.activity_candidate_days to service_role;
drop policy if exists activity_candidate_days_service on public.activity_candidate_days;
create policy activity_candidate_days_service on public.activity_candidate_days
  for all to service_role using (true) with check (true);

-- Fenced publication of one day's joint candidate. Same fence as publish_activity_gait_windows_day: the lease must
-- be alive and the revision current, otherwise NULL and nothing is written. It does NOT complete the job, clear
-- the lease or dirty scoring: the worker calls it in the same transaction, after the expert rows and before the
-- v1 publish, under a savepoint, so a rejection here can never block any publish. A malformed payload raises a
-- stable message and writes nothing.
-- Payload (written by Tools/CloudWorker ActivityCandidateDays.payload):
--   {"day": "YYYY-MM-DD", "schema": "activity-candidate-1", "policy": "expert-authority-1",
--    "selection_digest": sha256, "input_revision": n, "decisions": [{channel, route, release_mode, use, reason,
--    identity, input_revision, day, windows}], "arms": {name: {channels, stamps, document_sha256, summary,
--    comparison?, gait_quality?, motion_heads?, same_as?}}, "joint_document": {...}|null, "withheld_reason": text|null}
create or replace function public.publish_activity_candidate_day(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; d jsonb; a record; jd jsonb; withheld text; rev bigint;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_candidate_day_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_candidate_day_payload';
  end if;
  if octet_length(p_payload::text) > 16 * 1024 * 1024 then
    raise exception 'invalid_candidate_day_size';
  end if;
  if p_payload ->> 'schema' is distinct from 'activity-candidate-1' then
    raise exception 'invalid_candidate_day_schema';
  end if;
  if jsonb_typeof(p_payload -> 'policy') is distinct from 'string'
    or (p_payload ->> 'policy') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or jsonb_typeof(p_payload -> 'selection_digest') is distinct from 'string'
    or (p_payload ->> 'selection_digest') !~ '^[0-9a-f]{64}$'
    or not internal.activity_day_num_ok(p_payload -> 'input_revision', 1, 9223372036854775807, true) then
    raise exception 'invalid_candidate_day_payload';
  end if;
  -- The arms were decoded from this job's input: the payload names the revision the fence admitted.
  if (p_payload ->> 'input_revision')::bigint <> j.input_revision then
    raise exception 'invalid_candidate_day_payload';
  end if;

  if jsonb_typeof(p_payload -> 'decisions') is distinct from 'array'
    or jsonb_array_length(p_payload -> 'decisions') > 64 then
    raise exception 'invalid_candidate_day_decisions';
  end if;
  for d in select value from jsonb_array_elements(p_payload -> 'decisions') loop
    if jsonb_typeof(d) is distinct from 'object'
      or (d ->> 'channel') is null or (d ->> 'channel') not in ('gait_quality', 'motion_heads', 'embedded_gait')
      or (d ->> 'release_mode') is null or (d ->> 'release_mode') not in ('shadow', 'candidate', 'production')
      or (d ->> 'use') is null or (d ->> 'use') not in ('none', 'candidate', 'canonical') then
      raise exception 'invalid_candidate_day_decisions';
    end if;
  end loop;

  if jsonb_typeof(p_payload -> 'arms') is distinct from 'object' then raise exception 'invalid_candidate_day_arms'; end if;
  for a in select key, value from jsonb_each(p_payload -> 'arms') loop
    if a.key !~ '^[a-z][a-z_+]{0,95}$'
      or jsonb_typeof(a.value) is distinct from 'object'
      or jsonb_typeof(a.value -> 'channels') is distinct from 'array'
      or jsonb_typeof(a.value -> 'document_sha256') is distinct from 'string'
      or (a.value ->> 'document_sha256') !~ '^[0-9a-f]{64}$'
      or jsonb_typeof(a.value -> 'summary') is distinct from 'object' then
      raise exception 'invalid_candidate_day_arms';
    end if;
  end loop;

  withheld := case when jsonb_typeof(p_payload -> 'withheld_reason') = 'string' then p_payload ->> 'withheld_reason' end;
  if coalesce(jsonb_typeof(p_payload -> 'withheld_reason'), 'null') not in ('string', 'null')
    or (withheld is not null and length(withheld) not between 1 and 240) then
    raise exception 'invalid_candidate_day_joint';
  end if;
  jd := p_payload -> 'joint_document';
  if coalesce(jsonb_typeof(jd), 'null') not in ('object', 'null') then raise exception 'invalid_candidate_day_joint'; end if;
  if jsonb_typeof(jd) is distinct from 'object' then jd := null; end if;
  -- Exactly one of the joint document or its withheld reason; a joint document names an expert that shaped it.
  if (jd is null) = (withheld is null) then raise exception 'invalid_candidate_day_joint'; end if;
  if jd is not null and (jsonb_typeof(jd -> 'versions') is distinct from 'object'
      or jsonb_typeof(jd -> 'runs') is distinct from 'array'
      or (jsonb_typeof(jd -> 'versions' -> 'gait_quality') is distinct from 'string'
          and jsonb_typeof(jd -> 'versions' -> 'motion_heads') is distinct from 'string')) then
    raise exception 'invalid_candidate_day_joint';
  end if;

  rev := nextval('public.activity_candidate_days_result_revision_seq');
  insert into public.activity_candidate_days(user_id, device_id, day, candidate_schema, policy, selection_digest,
    algorithm_version, job_fingerprint, input_revision, decisions, arms, joint_document, withheld_reason,
    result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, 'activity-candidate-1', p_payload ->> 'policy',
    p_payload ->> 'selection_digest', j.algorithm_version, j.fingerprint, j.input_revision, p_payload -> 'decisions',
    p_payload -> 'arms', jd, withheld, rev, clock_timestamp())
  on conflict (user_id, device_id, day) do update set
    candidate_schema = excluded.candidate_schema, policy = excluded.policy,
    selection_digest = excluded.selection_digest, algorithm_version = excluded.algorithm_version,
    job_fingerprint = excluded.job_fingerprint, input_revision = excluded.input_revision,
    decisions = excluded.decisions, arms = excluded.arms, joint_document = excluded.joint_document,
    withheld_reason = excluded.withheld_reason, result_revision = excluded.result_revision,
    computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_candidate_day(uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.publish_activity_candidate_day(uuid, bigint, jsonb) to service_role;

-- Retention, the same shape as prune_activity_gait_windows_days. The worker calls it every few hours while some
-- expert runs in candidate mode (ActivityLane.pruneCandidateDaysIfDue).
create or replace function public.prune_activity_candidate_days(p_keep_days integer default 30,
                                                                p_max_rows integer default 10000)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_keep_days is null or p_keep_days < 1 or p_keep_days > 3650
    or p_max_rows is null or p_max_rows < 1 or p_max_rows > 1000000 then
    raise exception 'invalid_candidate_day_retention';
  end if;
  with doomed as (
    select ctid from public.activity_candidate_days
    where computed_at < clock_timestamp() - make_interval(days => p_keep_days)
    order by computed_at
    limit p_max_rows
  )
  delete from public.activity_candidate_days d using doomed where d.ctid = doomed.ctid;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.prune_activity_candidate_days(integer, integer) from public, anon, authenticated;
grant execute on function public.prune_activity_candidate_days(integer, integer) to service_role;

commit;
