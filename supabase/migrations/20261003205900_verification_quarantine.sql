-- Verification lane: durable quarantine for deterministically-unverifiable
-- manifests (root trace 2026-10-03, 'Verify-lane digest-mismatch trace'; spec 4.6).
--
-- A wire-scope manifest with NO recorded digest (manifest sha256 AND wire_sha256
-- empty, no receipt) can never be verified: the commit RPC requires
-- lower(manifest.sha256) = p_wire_sha256, so the lane refuses early
-- (VerificationLane.swift:558). VerificationLane.rememberNegative is an
-- in-process cache (limit 512), so after every worker restart the same bad
-- manifest is re-downloaded + re-hashed + re-rejected once, forever. The same
-- applies to every other DETERMINISTIC mismatch (receipt-authoritative byte
-- mismatches, verified-key pattern failures, RPC refusals): retrying can never
-- succeed.
--
-- This migration records the quarantine durably on object_manifests:
--   * verification_failure_code  — bounded safe code (CHECK `^[a-z0-9_]{3,64}$`)
--   * verification_failed_at     — first quarantine timestamp (idempotent)
--   * verification_attempts      — capped counter (1..16) of deterministic attempts
-- and the worker's candidateSQL excludes any row with a failure code, so
-- restarts stop rescanning it. Transient mismatches (torn upload, gunzip/zstd
-- failure, missing object) stay bounded-retry/deferred as today and never get a
-- code. The in-process negative cache is kept for per-process efficiency.
--
-- Additive only. One transaction. No production row is deleted or reassigned.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.object_manifests
  add column if not exists verification_failure_code text,
  add column if not exists verification_failed_at timestamptz,
  add column if not exists verification_attempts integer not null default 0;

alter table public.object_manifests drop constraint if exists object_manifests_verification_failure_code_check;
alter table public.object_manifests
  add constraint object_manifests_verification_failure_code_check
  check (verification_failure_code is null or verification_failure_code ~ '^[a-z0-9_]{3,64}$');

create index if not exists object_manifests_verification_failure_idx
  on public.object_manifests (id) where verification_failure_code is not null;

comment on column public.object_manifests.verification_failure_code is
  'Deterministic verification quarantine code (bounded [a-z0-9_]{3,64}); non-null means the object can never verify and must not be re-selected for verification.';
comment on column public.object_manifests.verification_failed_at is
  'When the deterministic verification failure was first quarantined (idempotent; never reset by later attempts).';
comment on column public.object_manifests.verification_attempts is
  'Capped count (1..16) of deterministic verification attempts for this object.';

-- Service-role writer. Idempotent: the first code sticks, attempts are capped.
create function public.noop_quarantine_manifest_verification(p_object_id uuid, p_failure_code text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_object_id is null or p_failure_code is null or p_failure_code !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'invalid verification quarantine' using errcode = '22023';
  end if;
  update public.object_manifests
     set verification_failure_code = p_failure_code,
         verification_failed_at = coalesce(verification_failed_at, clock_timestamp()),
         verification_attempts = least(verification_attempts + 1, 16)
   where id = p_object_id
     and (verification_failure_code is null or verification_failure_code = p_failure_code);
end $$;

revoke all on function public.noop_quarantine_manifest_verification(uuid, text)
  from public, anon, authenticated;
grant execute on function public.noop_quarantine_manifest_verification(uuid, text)
  to service_role;

comment on function public.noop_quarantine_manifest_verification(uuid, text) is
  'Durably quarantines a deterministically-unverifiable manifest so the verification lane stops rescanning it after restart.';

notify pgrst, 'reload schema';
commit;
