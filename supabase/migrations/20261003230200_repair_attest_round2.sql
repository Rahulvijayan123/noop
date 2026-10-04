-- Re-audit repair round 2 (audit-g2-durability P2s 1/3/4/5; round-1 files owned).
--
-- 1) OUTBOX DEAD-LETTER: physiology_archive_outbox had no attempts cap / terminal
--    disposition, so a persistently-failing row retried every ~30 s forever
--    (attempts/last_error already exist; dead_letter is new). The worker's claim
--    now excludes dead-lettered rows and releaseOutboxLease dead-letters at
--    max_attempts (16) with a bounded reason, mirroring projection debt.
--
-- 2) CLOSURE SILENT SKIP VISIBILITY: a device whose profile timezone is an INVALID
--    zone (or whose profiles row is MISSING) was silently dropped by the
--    pg_timezone_names join and never closed, with no surface. This migration adds
--    a bounded per-(user,device,reason) ledger day_closure_skips that the sweep
--    writes (invalid_zone / missing_profile), so the skip is operator-visible while
--    keeping the silent-skip enqueue semantics.
--
-- 3) CLOSURE DEAD-LETTERED DAYS: the sweep required `not j.dead_letter`, so a day
--    whose v2 job was dead-lettered at 8 never got even a pending marker (stuck
--    invisible). The sweep now marks such days `closure_state='closed'` with
--    `closure_reason='dead_lettered'` (day_completeness.closure_reason is new).
--
-- 4) VERIFICATION UN-QUARANTINE: no operator path cleared a stranded quarantine
--    (e.g. `commit rejected` classified deterministic during a transient
--    deployment misconfig). New service-role noop_unquarantine_manifest_verification
--    clears verification_failure_code/failed_at/attempts. OPERATOR RUNBOOK:
--      select id,user_id,verification_failure_code,verification_failed_at
--        from object_manifests where verification_failure_code is not null;
--      select public.noop_unquarantine_manifest_verification('<uuid>');  -- after the fix is verified
--    DOCUMENTED TRADEOFF (kept, considered): a permanently-corrupt object WITH a
--    recorded digest (plain `wire sha mismatch`, no receipt) is classified transient
--    and keeps bounded-retry once per process restart forever — a deliberate
--    decision because a torn upload cannot be distinguished from permanent
--    corruption by the digest check alone; it is NOT quarantined so an operator
--    can still repair/re-upload the object. The no-digest and receipt-authoritative
--    cases (which CAN never verify) are the ones quarantined.
--
-- Additive only. One transaction.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1) Outbox dead-letter (attempts/last_error already exist from 20260918020000).
alter table public.physiology_archive_outbox
  add column if not exists dead_letter boolean not null default false,
  add column if not exists dead_letter_reason text;

comment on column public.physiology_archive_outbox.dead_letter is
  'Terminal disposition: the row failed releaseOutboxLease max_attempts (16) consecutive times and must not be claimed again without operator review.';
comment on column public.physiology_archive_outbox.dead_letter_reason is
  'Bounded reason for the outbox dead-letter: archive_upload_exhausted (automatic at 16 attempts).';

-- 2) Closure skip ledger + day_completeness closure reason.
create table if not exists public.day_closure_skips (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  reason text not null check (reason in ('invalid_zone', 'missing_profile')),
  seen_at timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, reason)
);

alter table public.day_closure_skips enable row level security;
revoke all on table public.day_closure_skips from public, anon, authenticated;
grant all on table public.day_closure_skips to service_role;
drop policy if exists day_closure_skips_service on public.day_closure_skips;
create policy day_closure_skips_service on public.day_closure_skips
  for all to service_role using (true) with check (true);

comment on table public.day_closure_skips is
  'Bounded per-(user,device,reason) ledger of closure skips: invalid_zone (profile timezone not in pg_timezone_names) or missing_profile (no profiles row). One row per reason, seen_at refreshed; operator-visible surface for devices the closure sweep cannot close.';

alter table public.day_completeness
  add column if not exists closure_reason text;

alter table public.day_completeness drop constraint if exists day_completeness_closure_reason_check;
alter table public.day_completeness
  add constraint day_completeness_closure_reason_check
  check (closure_reason is null or closure_reason = any (array[
    'dead_lettered'::text,
    'invalid_zone'::text,
    'missing_profile'::text
  ]));

comment on column public.day_completeness.closure_reason is
  'Why closure settled without a live reconciliation pass: dead_lettered (the v2 job is dead-lettered at 8 failures) — the day is marked closed with this reason rather than stuck invisible.';

-- 3) Rewritten closure sweep: skip ledger + dead-lettered-day closing + existing
--    pending-day enqueue, all bounded and idempotent, retirement filter retained.
create or replace function public.scoring_enqueue_due_day_closure(
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

  -- Phase A: visibility for devices that can never be closed (invalid zone /
  -- missing profile). One bounded ledger row per (user, device, reason); the
  -- enqueue stays a silent skip, but the skip is now operator-visible.
  for r in
    select z.user_id, z.device_id,
           case when z.missing then 'missing_profile' else 'invalid_zone' end as reason
      from (
        select d.user_id, d.id as device_id,
               (p.id is null) as missing,
               coalesce(nullif(btrim(p.timezone), ''), 'UTC') as tz
          from public.devices d
          left join public.profiles p on p.id = d.user_id
         where d.is_active
           and not exists (select 1 from public.noop_account_retirements ret
                            where ret.user_id = d.user_id)
      ) z
      left join pg_timezone_names t on t.name = z.tz
     where z.missing or t.name is null
     order by z.user_id, z.device_id
     limit p_limit
  loop
    insert into public.day_closure_skips (user_id, device_id, reason, seen_at)
      values (r.user_id, r.device_id, r.reason, clock_timestamp())
      on conflict (user_id, device_id, reason) do update set seen_at = clock_timestamp();
  end loop;

  -- Phase B: dead-lettered v2 days -> closed-with-reason (not stuck invisible).
  -- The derived table carries an always-VALID tz (invalid profile zones become
  -- 'UTC' by construction) plus a `valid` flag; `where z.valid` excludes invalid
  -- zones (surfaced in Phase A) and the `at time zone z.tz` math can therefore
  -- never see an unrecognized zone.
  for r in
    select z.user_id, z.device_id,
           ((clock_timestamp() at time zone z.tz)::date - 1) as day,
           z.tz
      from (
        select d.user_id, d.id as device_id,
               (exists (select 1 from pg_timezone_names n
                         where n.name = coalesce(nullif(btrim(p.timezone), ''), 'UTC'))) as valid,
               case when exists (select 1 from pg_timezone_names n
                                  where n.name = coalesce(nullif(btrim(p.timezone), ''), 'UTC'))
                    then coalesce(nullif(btrim(p.timezone), ''), 'UTC')
                    else 'UTC' end as tz
          from public.devices d
          join public.profiles p on p.id = d.user_id
         where d.is_active
      ) z
     where z.valid
       and clock_timestamp() >=
             (((clock_timestamp() at time zone z.tz)::date - 1)::timestamp at time zone z.tz)
             + make_interval(secs => p_settle_seconds)
       and not exists (select 1 from public.noop_account_retirements ret
                        where ret.user_id = z.user_id)
       and exists (select 1 from public.scoring_jobs_v2 j
                    where j.user_id = z.user_id and j.device_id = z.device_id
                      and j.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                      and j.algorithm_version = p_version
                      and j.dead_letter)
       -- Not already closed: fresh days AND days enqueued-but-pending are both
       -- settled to closed/dead_lettered once their job is terminal.
       and not exists (select 1 from public.day_completeness c
                        where c.user_id = z.user_id
                          and c.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                          and c.closure_state = 'closed')
     order by z.user_id, z.device_id
     limit p_limit
  loop
    insert into public.day_completeness (user_id, day, closure_state, closure_reason, updated_at)
      values (r.user_id, r.day, 'closed', 'dead_lettered', clock_timestamp())
      on conflict (user_id, day) do update
        set closure_state = 'closed', closure_reason = 'dead_lettered', updated_at = clock_timestamp()
        -- Fresh days and days already enqueued-but-pending both settle to
        -- closed/dead_lettered once their job is terminal.
        where public.day_completeness.closure_state is null
           or public.day_completeness.closure_state = 'pending_reconciliation';
    n := n + 1;
  end loop;

  -- Phase C: pending (not dead-lettered, not closure-marked) days -> enqueue +
  -- pending marker, atomically (round 1). A frozen owner gets NO closure work.
  -- Same always-valid tz + `valid` flag as Phase B.
  for r in
    select z.user_id, z.device_id,
           ((clock_timestamp() at time zone z.tz)::date - 1) as day,
           z.tz
      from (
        select d.user_id, d.id as device_id,
               (exists (select 1 from pg_timezone_names n
                         where n.name = coalesce(nullif(btrim(p.timezone), ''), 'UTC'))) as valid,
               case when exists (select 1 from pg_timezone_names n
                                  where n.name = coalesce(nullif(btrim(p.timezone), ''), 'UTC'))
                    then coalesce(nullif(btrim(p.timezone), ''), 'UTC')
                    else 'UTC' end as tz
          from public.devices d
          join public.profiles p on p.id = d.user_id
         where d.is_active
      ) z
     where z.valid
       and clock_timestamp() >=
             (((clock_timestamp() at time zone z.tz)::date - 1)::timestamp at time zone z.tz)
             + make_interval(secs => p_settle_seconds)
       and not exists (select 1 from public.noop_account_retirements ret
                        where ret.user_id = z.user_id)
       and exists (select 1 from public.scoring_jobs_v2 j
                    where j.user_id = z.user_id and j.device_id = z.device_id
                      and j.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                      and j.algorithm_version = p_version
                      and j.completed_revision < j.input_revision and not j.dead_letter)
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

-- 4) Verification un-quarantine (operator path).
create or replace function public.noop_unquarantine_manifest_verification(p_object_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_object_id is null then
    raise exception 'invalid verification unquarantine' using errcode = '22023';
  end if;
  update public.object_manifests
     set verification_failure_code = null,
         verification_failed_at = null,
         verification_attempts = 0
   where id = p_object_id;
  if not found then
    raise exception 'object_not_found' using errcode = '22023';
  end if;
end $$;

revoke all on function public.noop_unquarantine_manifest_verification(uuid)
  from public, anon, authenticated;
grant execute on function public.noop_unquarantine_manifest_verification(uuid)
  to service_role;

comment on function public.noop_unquarantine_manifest_verification(uuid) is
  'Operator un-quarantine for the verification lane: clears verification_failure_code/failed_at/attempts so the object is re-selected by the candidate scan. Use only after the transient condition (e.g. a mid-migration grant) is verified fixed. See the migration header for the runbook and the recorded-digest tradeoff.';

notify pgrst, 'reload schema';
commit;
