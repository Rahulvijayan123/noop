-- physiology_archive_outbox: admit 'retry' as a legal status (G56 P2, contract C5).
--
-- ArchiveLane.swift releaseOutboxLease (Tools/CloudWorker/Sources/frwhoop-worker/ArchiveLane.swift:256)
-- releases a lost/empty-payload lease by writing status='retry' with a 30 s next_attempt_at backoff.
-- The original CHECK (20260918020000_physiology_publication.sql) allowed only
-- ('pending','uploading','uploaded','verified','failed'), so the release failed with a check-constraint
-- error: the row stayed 'uploading' with an unexpired lease and looped on the 300 s lease expiry,
-- re-uploading the object to B2 each cycle with no backoff and no failure accounting. The claim
-- predicate (ArchiveLane.swift:134) already lists 'retry'.
--
-- Additive only. Drop/re-add the one status CHECK with IF EXISTS guards; no data is reassigned.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.physiology_archive_outbox
  drop constraint if exists physiology_archive_outbox_status_check;

alter table public.physiology_archive_outbox
  add constraint physiology_archive_outbox_status_check
  check (status in ('pending', 'uploading', 'uploaded', 'verified', 'failed', 'retry'));

comment on column public.physiology_archive_outbox.status is
  'pending=due, uploading=lease held, uploaded/verified=archived, failed=terminal, retry=bounded backoff before next attempt.';

commit;
