-- Zone-aware midnight closure (G2-attestation item 3 / spec 4.5).
--
-- A quiet day (no new samples, phone offline) never gets any boundary processing:
-- it stays `pending` (completed_revision < input_revision) forever, because day
-- dirtiness is event-driven only. This migration adds bounded, per-user, idempotent
-- day-closure work driven by the worker's existing poll loop (no new cron):
--
--  * `scoring_enqueue_due_day_closure(p_limit, p_version, p_settle_seconds)` scans
--    each user's active devices once, computes YESTERDAY in that user's LOCAL IANA
--    zone from profiles.timezone (the app's phone-local zone authority, contract
--    C2), and — once yesterday's local midnight plus a settle window has passed —
--    enqueues a v2 scoring job for that day when it is still pending and not
--    already closure-processed. The enqueue and the pending marker are ONE
--    transaction, so a crash can never double-enqueue (idempotent).
--
--  * `day_completeness.closure_state` records the boundary lifecycle on the day
--    attestation from task 5: the sweep sets 'pending_reconciliation'; the next
--    successful publish of that day's snapshot (publish_day_attestation_v1)
--    advances it to 'closed'. A day that stays broken stays 'pending_reconciliation'
--    forever — honest, visible to operators.
--
-- Boundary math is done with Postgres `AT TIME ZONE` (pg_timezone_names DST rules),
-- the same calendar-correct arithmetic as scoring_day_segments; the worker's Swift
-- unit tests pin the mirror helper (DayScorer.closureDue) and the statement shape.
--
-- Additive only. One transaction. No production data is rewritten or deleted.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.day_completeness
  add column if not exists closure_state text;

alter table public.day_completeness drop constraint if exists day_completeness_closure_state_check;
alter table public.day_completeness
  add constraint day_completeness_closure_state_check
  check (closure_state is null or closure_state = any (array[
    'pending_reconciliation'::text,
    'closed'::text
  ]));

create index if not exists day_completeness_closure_idx
  on public.day_completeness (user_id, day) where closure_state is not null;

comment on column public.day_completeness.closure_state is
  'Midnight-closure lifecycle on the day attestation: null=not due, pending_reconciliation=the closure sweep enqueued the day at its local boundary, closed=a v2 snapshot published for the day after the boundary.';

-- Advance a pending closure to closed inside the attestation write from task 5.
create or replace function public.publish_day_attestation_v1(
  p_user uuid, p_device uuid, p_day date, p_input_revision bigint,
  p_timezone text, p_attestation jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  applied boolean;
begin
  if p_user is null or p_device is null or p_day is null or p_input_revision is null or p_input_revision <= 0
     or coalesce(p_timezone, '') = '' or jsonb_typeof(p_attestation) is distinct from 'object' then
    raise exception 'day attestation: invalid arguments' using errcode = '22023';
  end if;
  if not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'day attestation: device does not belong to the user' using errcode = '42501';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'day attestation: invalid timezone' using errcode = '22023';
  end if;

  insert into public.day_completeness
    (user_id, day, timezone_name, device_id, input_revision, attestation, attestation_version, updated_at)
  values (p_user, p_day, p_timezone, p_device, p_input_revision, p_attestation,
          'nara-day-completeness-v1', clock_timestamp())
  on conflict (user_id, day) do update
    set timezone_name = excluded.timezone_name,
        device_id = excluded.device_id,
        input_revision = excluded.input_revision,
        attestation = excluded.attestation,
        attestation_version = excluded.attestation_version,
        -- A publish that lands while this day's closure is pending reconciliation
        -- IS the reconciliation: mark it closed.
        closure_state = case when public.day_completeness.closure_state = 'pending_reconciliation'
                             then 'closed' else public.day_completeness.closure_state end,
        updated_at = clock_timestamp()
    -- Fence: only a strictly newer revision advances the record; an equal
    -- revision is accepted ONLY from the same device (idempotent retry of the
    -- same pass). An older revision, or a different device at the same
    -- revision, cannot overwrite the day's attestation.
    where public.day_completeness.input_revision < excluded.input_revision
       or (public.day_completeness.input_revision = excluded.input_revision
           and public.day_completeness.device_id = excluded.device_id);
  get diagnostics applied = row_count;

  if applied then
    return jsonb_build_object('applied', true, 'input_revision', p_input_revision);
  end if;
  return jsonb_build_object('applied', false, 'reason', 'superseded',
    'claimed_input_revision', p_input_revision);
end $$;

-- Bounded, idempotent, per-user closure sweep. Returns how many days were enqueued.
-- One transaction: the enqueue and the pending marker commit or fail together.
create function public.scoring_enqueue_due_day_closure(
  p_limit integer default 16, p_version text default 'frwhoop-server-1',
  p_settle_seconds integer default 600)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  n integer := 0;
  r record;
begin
  if p_limit is null or p_limit < 1 or p_limit > 256 then
    raise exception 'invalid day-closure limit' using errcode = '22023';
  end if;
  if p_settle_seconds is null or p_settle_seconds < 0 or p_settle_seconds > 86400 then
    raise exception 'invalid day-closure settle window' using errcode = '22023';
  end if;
  if not exists (select 1 from public.scoring_algorithms_v2 a where a.algorithm_version = p_version and a.enabled) then
    raise exception 'day closure: scoring algorithm not enabled' using errcode = '22023';
  end if;

  for r in
    select z.user_id, z.device_id,
           ((clock_timestamp() at time zone z.tz)::date - 1) as day,
           z.tz
      from (
        select d.user_id, d.id as device_id,
               coalesce(nullif(btrim(p.timezone), ''), 'UTC') as tz
          from public.devices d
          join public.profiles p on p.id = d.user_id
         where d.is_active
      ) z
      join pg_timezone_names t on t.name = z.tz
     where clock_timestamp() >=
             (((clock_timestamp() at time zone z.tz)::date - 1)::timestamp at time zone z.tz)
             + make_interval(secs => p_settle_seconds)
       -- The day's local boundary has passed; it must still be pending v2 work.
       and exists (select 1 from public.scoring_jobs_v2 j
                    where j.user_id = z.user_id and j.device_id = z.device_id
                      and j.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                      and j.algorithm_version = p_version
                      and j.completed_revision < j.input_revision and not j.dead_letter)
       -- Idempotency: never re-enqueue a day already marked pending or closed.
       and not exists (select 1 from public.day_completeness c
                        where c.user_id = z.user_id
                          and c.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                          and c.closure_state is not null)
     order by z.user_id, z.device_id
     limit p_limit
  loop
    perform public.enqueue_scoring_v2(r.user_id, r.device_id, r.day, p_version, 'day_closure');
    insert into public.day_completeness (user_id, day, closure_state, updated_at)
      values (r.user_id, r.day, 'pending_reconciliation', clock_timestamp())
      on conflict (user_id, day) do update
        set closure_state = 'pending_reconciliation', updated_at = clock_timestamp()
        where public.day_completeness.closure_state is null;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.scoring_enqueue_due_day_closure(integer, text, integer)
  from public, anon, authenticated;
grant execute on function public.scoring_enqueue_due_day_closure(integer, text, integer)
  to service_role;

comment on function public.scoring_enqueue_due_day_closure(integer, text, integer) is
  'Bounded per-user midnight-closure sweep: enqueues pending v2 days whose local midnight plus a settle window has passed, marks day_completeness.closure_state=pending_reconciliation atomically, and never touches days already pending/closed.';

notify pgrst, 'reload schema';
commit;
