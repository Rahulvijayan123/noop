# audit-g2-durability — G2 durability/attestation repairs (independent review)

- Auditor: `audit-g2-durability` (independent; did NOT author the repairs).
- Date: 2026-10-03. Branch: `audit/core-plumbing-20261003` (working tree, uncommitted repairs).
- Scope: spec §4 + T08–T13, T31; supabase/functions/_shared/{rest.ts,installationLifecycle.ts},
  the six 2026100320xxxx migrations + their deno tests,
  Tools/CloudWorker/Sources/frwhoop-worker/{DayScoring,ScoringLane,VerificationLane}.swift,
  Strand/Push/{CloudCapture,CloudTransportCoordinator,CloudPushSettings,CloudPushIdentity,CloudJournal,CloudUploadSession}.swift,
  StrandTests/CloudPushTests.swift.
- Method: read code + diffs, then ran the targeted suites. No code changes, no commits, no shared DB.

## Targeted test runs (this auditor)

| Suite | Command | Result |
| --- | --- | --- |
| deno outbox_retry | EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/outbox_retry_integration_test.ts | 1 passed (3 steps), 0 failed |
| deno metric_series_fence | (same harness) | 1 passed (5 steps), 0 failed |
| deno projection_debt_dead_letter | (same harness) | 1 passed (4 steps), 0 failed |
| deno day_attestation | (same harness) | 1 passed (5 steps), 0 failed |
| deno day_closure | (same harness) | 1 passed (5 steps), 0 failed |
| deno verification_quarantine | (same harness) | 1 passed (4 steps), 0 failed |
| deno retained_identity_deferral | (same harness) | 7 passed, 0 failed |
| deno placement_route (C4 consumer) | (same harness) | 1 passed (weak assertion — see F6) |
| worker swift | CPATH=/opt/homebrew/opt/libpq/include swift test --filter "SeriesFenceTests\|DayAttestationTests\|DayClosureTests\|VerificationLaneTests\|DayScoringAdapterTests" | 65 executed, 0 failures |
| macOS | xcodebuild test -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/CloudPushTests | 46 executed, 0 failures |

Full-suite runs were not repeated (root ran them authoritatively). The 65 worker tests = SeriesFence 8 + VerificationLane 16 + DayAttestation 7 + DayClosure 5 + DayScoringAdapter 29.

## Verdicts per challenge

### 1. rest.ts C4 propagation — PASS (2 notes)
- The set of responses that throw `RestAuthorityError` is UNCHANGED (the authority branch
  condition is untouched); only the attached `.code` changed, and the class carries both
  `.code` and `.receiverCode` (constructor parameter property), so every existing consumer
  that read `.receiverCode` still works. (rest.ts:11-16,70-84)
- Consumers audited: boundedRecovery.ts:9 (instanceof only — unchanged); intakeAdmission.ts:43
  (`receiverCode==='intake_admission_scope_mismatch'` now also matches a 401/403 carrying that
  exact receiver-controlled message — before it matched only 42501; low risk, receiver-controlled);
  pushDiagnostics.ts:43 / appendProjection.ts:41 (`scoring_input_gate_busy` now also matches a
  401/403 carrying that exact message — previously only 55P03; this makes the busy signal MORE
  consistent, not less); durability.ts:intakeError maps the propagated codes to PushProtocolError
  (intended fix; recoveryPoll catches PushProtocolError+403 as IntakeAdmissionError, converging to
  the same stop as before). installationLifecycle's marker-409 fix is correct and pinned:
  deferral now requires receiverCode AND `status===409`, and the generic 409/PT409 path sets
  `err.status=409` (rest.ts:94-95), so a 401/403 marker lookalike cannot defer
  (installationLifecycle.ts:138-152; retained_identity_deferral_test.ts, "exact SQL marker requires
  HTTP409" case, passed). root's fix verified sound.
- Regex leak check: `^[a-z0-9_]{3,64}$` admits only lowercased identifier-shaped strings; URLs,
  SQL fragments, "permission denied ..." multi-word messages cannot match. `permission denied*`
  is collapsed to the bounded canonical phrase. Edge functions log only generic labels, never the
  error text. No leak found.
- F6 (below): placement_route_test's `assertRejects(..., 'supabase_authority_rejected')` is a
  weak assertion (the string is the failure message, not a code check) — it only proves the RPC
  rejects, not which code propagates. My probe confirmed the code is `device_owner_mismatch`
  (RestAuthorityError, 403) under the new client, so the test comment overclaims.

### 2. Outbox 'retry' — PASS (1 P2 note)
- Constraint name: `physiology_archive_outbox_status_check` is Postgres's auto-name for the
  inline column CHECK in 20260918020000 (verified in source), and the fix's drop-if-exists +
  re-add matches the deployed shape; outbox_retry_integration_test applies 20260918020000 then the
  fix and drives the exact claim/release SQL — constraint admits 'retry'.
- Claim/lease semantics: claim = `status IN ('pending','retry','uploading') AND next_attempt_at<=now()
  AND lease expired ... ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED` (ArchiveLane.swift:131-147).
  Renewal, release and completion are all fenced on `lease_token AND lease_expires_at > now()`
  (ArchiveLane.swift:220-234,253-261,323-341). A lost/expired lease can be re-claimed, but the
  former holder cannot finish another's claim; the B2 object key is content-identical so a
  concurrent re-upload is byte-for-byte the same. No double-claim, no double-completion.
- Starvation: fixed 30 s backoff (ArchiveLane.swift:257) keeps a failing row out of the FIFO claim
  between attempts; higher-id rows still get their turn. No starvation.
- P2 note: the outbox has NO attempts cap and NO dead-letter — a permanently-poisoned row retries
  every 30 s forever (`attempts` grows unbounded, `last_error` refreshed). Projection debt
  (dead-letter at 16) and archive jobs (at 12) both have terminal dispositions; outbox does not.
  Bounded backoff, unbounded attempts. Not data loss; operator visibility via attempts/last_error.

### 3. Series revision fence — PASS
- The 6-arg `publish_metric_series_v1` reads `latest_rev` from `scoring_jobs_v2`
  (`order by input_revision desc limit 1`) AFTER taking the `metric_series:<user>:<day>` advisory
  xact lock, and refuses `claimed < latest` with `applied=false,reason=superseded` — no write
  (20261003202000 SQL). Soundness under concurrency: a newer pass can only publish series AFTER its
  own job row (with the newer revision) is committed, so any stale pass whose fence SELECT runs
  after that commit is refused; a stale pass that wins the race before the newer job commits is
  overwritten by the newer pass afterwards. Final state always converges to the newer revision.
  No lock is needed against the intake path because the ordering guarantee comes from the pipeline
  (job row committed before the pass that claims it runs).
- Superseded is counted in `seriesSuperseded`/`attestationSuperseded` — never success, never
  failure (ScoringLane.swift publishSeries/publishAttestation; classifySeriesOutcome
  .superseded branch). SeriesFenceTests + metric_series_fence_integration_test cover stale→
  superseded+nothing written, current→applied, null→22023, not_selected, 5-arg compat.
- Legacy 5-arg reachability: only the psql fixture (tests/metric_series.sql) and back-compat;
  grants remain service-role-only. Production writers: ScoringLane now uses the 6-arg form
  (seriesPublishSQL pinned by test), and no edge function calls publish_metric_series_v1 at all
  (grep verified). Edge worker path clean.

### 4. Projection debt dead-letter — PASS
- Counter is per-row (`failures` column), monotonic, capped at 16; `dead_letter=(failures+1>=16)`
  computed from the OLD value, so the 16th call dead-letters exactly once
  (20261003203000 noop_fail_projection_debt). Backoff capped at 3600 s.
- `noop_claim_projection_debt` excludes `not q.dead_letter` (same pattern as claim_scoring_v2).
  The only claim/fail path is the server RPC called by ProjectionLane.swift (lines 107, 246) —
  there is no edge-side projection-debt claim to keep in sync; verified no other caller exists.
- Operator re-activation path documented in the migration comment (inspect / dead-letter /
  reactivate: dead_letter=false, failures=0, not_before=now / purge after 90 d). Integration test
  covers failures 1..15 pending, 16th dead-lettered, claim never returns it, reactivation works.

### 5. Day attestation — PASS (1 low note)
- Write is idempotent + revision-fenced: ON CONFLICT (user_id,day) DO UPDATE with WHERE
  `newer revision OR (equal revision AND same device)`; older refused, equal-same-device =
  idempotent retry, equal-different-device refused, newer advances (20261003204000). Integration
  test covers all five cases. `status` column untouched → stays 'open' (no fabricated continuity);
  the real scoring status travels INSIDE the attestation payload (DayScorer.dayAttestation).
- not_measured fields are built by the pure worker helper and persisted as the full payload jsonb
  (DayScoring.swift dayAttestation; DayAttestationTests assert each key, incl. DST bounds 23 h).
- Worker publishes attestation ONLY after `publish_scoring_snapshot_v2` returns a revision > 0 and
  the snapshot transaction commits (ScoringLane.swift ~25430-25455), so projection completion is
  factual.
- Low note: a same-revision re-score by a DIFFERENT selected device is refused (attestation keeps
  the old device's record until a newer input revision lands). Acceptable design (device is part of
  the fence identity), not data corruption.

### 6. Zone closure scheduling — PASS (3 P2 notes)
- Per-user AT TIME ZONE is correct: local yesterday = `(clock_timestamp() at time zone tz)::date - 1`,
  local-midnight boundary = `(local_yesterday::timestamp at time zone tz)`, both standard Postgres
  and correct for half-hour zones (Kolkata) and DST transition days (pg_timezone_names rules).
  Enqueue + pending marker are one transaction; enqueue_scoring_v2 is ON CONFLICT-idempotent;
  re-enqueue blocked by `closure_state is not null`.
- Bounded backfill: only LOCAL-YESTERDAY is ever considered, never a backlog of older days, so a
  long downtime cannot enqueue many days at once. Worker hook throttled to one sweep per 60 s,
  batch <= 16 (ScoringLane.swift dayClosureSweepIntervalSeconds/dayClosureBatch; maybeSweepDayClosure
  called at the top of drain()). No new cron.
- P2 note A (zone mismatch at the scoring step): the closure enqueues the day from
  `profiles.timezone`, but the worker scores/attests it with `ScoringLane.resolveTimezone`
  (ScoringLane.swift:728-737) which prefers the legacy/physiology work item's timezone and falls
  back to UTC. A QUIET day (the exact case closure creates) has no work item, so a non-UTC user's
  closure attestation is written with UTC day bounds — the day DATE is right but the 24 h window in
  the attestation identity is wrong by the zone offset. Practical impact is low (a quiet day has no
  data → status no_data regardless), but the closure feature's zone-correct intent is only
  half-implemented. NOT VERIFIED on a real quiet non-UTC day (no live harness); code-traced.
- P2 note B (silent skip): a profile timezone that is NULL/empty coalesces to 'UTC' (fine), but an
  INVALID zone string is silently dropped by the `join pg_timezone_names` (20261003205000:132-138)
  — the device is excluded from every closure sweep with no error and no observability. The app
  now writes validated zones, but legacy/garbage rows would be silently never-closed. Also, an
  active device whose profiles row is missing is inner-join-excluded silently.
- P2 note C (dead-lettered days invisible to closure): the sweep requires `not j.dead_letter`
  (20261003205000:146), so a day whose v2 job was dead-lettered at 8 failures never gets even the
  `pending_reconciliation` marker — it stays stuck pending with no closure state at all (no operator
  surface beyond raw SQL). Honest but invisible; a documented operator reactivation path for
  scoring_jobs_v2 dead-letters would close this.

### 7. Verification quarantine — PASS (2 P2 notes)
- Deterministic-vs-transient classifier (VerificationLane.swift isDeterministicMismatch/quarantineCode):
  no-digest, commit-rejected/NULL/state, verified-key pattern/derivation, missing identity/key, and
  ALL receipt-authoritative mismatches are quarantined; plain wire/content sha mismatches,
  gunzip/zstd failures, byte-count mismatches and missing objects stay bounded-retry (never
  quarantined). A torn upload without a receipt stays transient (correct); a torn upload with a
  receipt is receipt-authoritative → quarantined (correct — the receipt can never agree with
  different bytes).
- RPC is idempotent: first code sticks (`verification_failed_at` coalesce), attempts capped at 16,
  different-code updates refused. Invalid codes rejected whole (22023). Integration test covers all.
- candidateSQL requires `verification_failure_code IS NULL` (VerificationLane.swift:119) and edge
  `workers.ts reconcileObjects` skips `verification_failure_code != null` (workers.ts:133) — the
  SAME predicate. Consistent (reconcile_quarantine_test + my read).
- P2 note A (no un-quarantine path): the quarantine is write-only — no operator RPC or documented
  procedure to clear `verification_failure_code` (unlike projection debt, which documents
  reactivation). A manifest quarantined during a transient misconfiguration (e.g. `commit rejected
  sqlstate=42501` while a grant was mid-migration) stays excluded from verification forever after
  the fix is applied; recovery needs raw SQL. Minor because the fence codifies 'deterministic',
  but 42501/23514 can be deployment-transient.
- P2 note B (uncovered deterministic case): a permanently-corrupt object WITH a recorded digest
  (`wire sha mismatch`, no receipt) is classified transient and keeps bounded-retry once per
  process restart forever — the exact unbounded re-verification the repair set out to stop, minus
  the specific no-digest live trace. Deliberate tradeoff (cannot distinguish torn upload from
  permanent corruption) and documented; noted so the boundary is explicit.

### 8. Phone-side D1/D2 — PASS (1 doc note)
- Mid-upload stop consistency: `handle(outcome:)` returns false when `!active` (Coordinator
  guard at the top), so a stop between HTTP 200 and receipt-apply leaves the batch sealed; it
  re-uploads idempotently on re-enable (content-derived batch id, receiver dedup). In-flight tasks
  are not force-cancelled by stop(); they run to completion and decrement `inFlight`, so the
  accounting does not wedge. Background OS tasks likewise complete; a receipt applied after
  re-enable is valid (same owner, dedup). Verified in code; no process-death scenario differs from
  the pre-existing crash-safe design.
- D2 retry: `scheduleJournalReactivation` polls `isDataAvailable` every 2 s, re-activates + re-seeds
  the ledger, kicks the coordinator, and is cancelled by `stop()` (CloudCapture.swift 648-698).
  Poll terminates on success or cancellation; no infinite task when disabled. Re-disable during the
  poll cancels it (stop() cancels _reactivationTask). `setEnabled(false)` also gates capture and
  submit (zero-window defence) and the coordinator cycle (cloudEnabled gate). Owner pointer is
  cleared before stop in signOut/forget so a racing startIfEnabled cannot re-adopt the old identity.
- Owner filters: pendingGroups/pendingEntries/registerSeal mark/rescheduleFailed/stats/sealedBatches/
  countBatches all owner-scoped; every remaining query keyed by batch_id is safe because batch_id
  is content-derived (unique per owner's content); the acked-record/acked-batch retention cleanup
  deletes only state=2/acked rows regardless of owner — safe (already durably received). The
  repair's claim that "acked-file cleanup reads through sealedBatches" is inaccurate (it is a
  direct DELETE at CloudJournal.swift ~51035/51553), but the deletion is owner-safe, so this is a
  doc note only.
- HTTP layer: uploadForeground/enqueueBackground refuse on owner mismatch (CloudUploadSession.swift
  UploadError.ownerMismatch, expectedOwnerId), coordinator quarantines (blocked, retained) on
  mismatch. Receipt bound to batch.ownerId (acquisition-time), not current identity. All 6 new
  CloudPushTests (D1x2, D2x1, T23x3) pass.

### 9. T09/T10 convergence — PASS
- Kill between receipt-apply and cursor-save: journal.applyReceipt sets acked/state=2 first, THEN
  saveAppendCursor runs; a kill between them leaves the cursor stale. The next batch's window then
  starts earlier, but the receiver dedups identical records (content-derived identity) and a later
  ack re-advances the cursor — no dropped beats, no inflated counts. Lost ACK: batch stays sealed,
  re-upload on restart, receiver returns the same receipt, applied idempotently.
- After the owner changes: handle()/sealedBatches are owner-scoped, so a batch under A is neither
  re-uploaded nor receipt-applied under B; when A returns, it re-uploads and converges. Verified by
  code and by the T23 tests.

## Material findings (file:line)

- P2  outbox retry: no attempts cap / no dead-letter — a poisoned physiology_archive_outbox row
     retries every 30 s forever. ArchiveLane.swift:131-147 (claim), 253-261 (release, fixed 30 s).
- P2  closure zone mismatch at scoring step: closure enqueues from profiles.timezone
     (20261003205000_day_closure_scheduling.sql:132) but ScoringLane.resolveTimezone
     (ScoringLane.swift:728-737) falls back to UTC when no work item exists — the exact quiet-day
     case. Attestation day bounds can be the wrong 24 h window for non-UTC users.
- P2  closure silent skip: invalid profile timezone (and missing profiles row) silently drops the
     device from every sweep (20261003205000_day_closure_scheduling.sql:132-138 join
     pg_timezone_names). No error, no observability.
- P2  closure dead-lettered days: `not j.dead_letter` (20261003205000_day_closure_scheduling.sql:146)
     means a dead-lettered v2 day never gets any closure marker (invisible, stays pending forever).
- P2  verification quarantine: no operator un-quarantine path; `commit rejected sqlstate=42501/23514`
     classified deterministic (VerificationLane.swift isDeterministicMismatch) can strand a manifest
     after a transient deployment misconfig; and plain recorded-digest byte mismatches stay
     unbounded-retry (documented tradeoff).
- P2  day attestation: same-revision different-device re-score refused (20261003204000 fence);
     attestation pins the old device until a newer revision. Low impact, by design.
- Note placement_route_test.ts:163 `assertRejects(...,'supabase_authority_rejected')` is a weak
     assertion (string is the failure message, not a code check); actual propagated code is
     `device_owner_mismatch` (probe-verified). Test overclaims, repair itself is fine.
- Note repair-ble comment overclaims: acked-file cleanup does not read through sealedBatches
     (CloudJournal.swift ~51035/51553 direct DELETE) — owner-safe, so documentation only.

## NOT VERIFIED

- Closure SQL on a real half-hour zone (Kolkata) and on a real DST transition day — the integration
  test uses Pacific/Kiritimati (UTC+14, no DST); the SQL is standard Postgres AT TIME ZONE and the
  worker mirror (DayClosureTests) pins a DST day, but the SQL's DST/half-hour behavior is not
  directly exercised.
- The closure zone-mismatch scenario (P2 note A) on a real quiet non-UTC day (no live harness).
- Physical-device D1/D2 behavior (real locked iPhone first-unlock timing) — device-only, per the
  repair report; code + journal-level tests only.
- Deployed shape: whether the production DB's constraint names / column shapes exactly match the
  migration set (the fix assumes the auto-named status CHECK and `profiles.timezone`); the
  ordered-apply smoke test proves the fresh-DB shape only.

---

# Re-audit round (2026-10-03, round-2 fixes)

Re-verified ONLY the fixes to audit-g2-durability findings in the current working tree.
All targeted tests re-run by this auditor (no full suites):

| Fix test | Result |
| --- | --- |
| outbox_dead_letter_integration_test.ts | 1 passed (4 steps), 0 failed |
| quiet_day_timezone_integration_test.ts | 1 passed (4 steps), 0 failed |
| day_closure_visibility_integration_test.ts | 1 passed (3 steps), 0 failed |
| verification_unquarantine_integration_test.ts | 1 passed (2 steps), 0 failed |
| placement_route_test.ts (tightened) | passed (1 test) |
| metric_series_fence_user_scope_test.ts (fence-scope, in my challenge 3 area) | passed |
| day_closure_retirement_test.ts (closure + retirements, in my challenge 6 area) | passed |
| day_closure_integration_test.ts (round-1 regression) | passed (5 steps) |
| worker swift DayAttestationTests (9) / DayClosureTests (5) / DayScoringAdapterTests (29) / SeriesFenceTests (8) / VerificationLaneTests (16) | 67 executed, 0 failures |

## Finding-by-finding verdict

### F1. Outbox no dead-letter (ArchiveLane.swift:253-261) — PASS
Fix: 20261003230200 adds `physiology_archive_outbox.dead_letter/dead_letter_reason`;
`releaseOutboxLease` now writes `status='failed'` + `dead_letter=true` +
`dead_letter_reason='archive_upload_exhausted'` when `attempts >= 16`, else `'retry'` with the
30 s backoff (ArchiveLane.swift:265-282); the claim predicate adds `AND NOT dead_letter`
(ArchiveLane.swift:136-139); an upload failure now releases the lease with that accounting instead
of holding it until 300 s lease expiry (ArchiveLane.swift:194-204). `attempts` is incremented at
claim time, so the 16th claim-and-fail is terminal — the same "dead-letter at 16" as projection
debt. The health query in main.swift:514 counts only pending/retry/uploading, so dead-lettered
(failed) rows stay out of the backlog metric. Integration test drives 1..15 retryable + 16th
terminal + claim excludes + release past cap stays terminal. Addressed.
Remaining (minor, non-blocking): no operator reactivation runbook documented for the outbox
(projection debt and verification quarantine have one; the outbox operator must reset via raw SQL
`dead_letter=false, dead_letter_reason=null, status='pending'`). The terminal disposition and
bounded reason (what the finding asked for) are present.

### F2. Closure zone mismatch — quiet days attested with UTC bounds (ScoringLane.swift:728-737) — PASS
Fix: `resolveTimezoneSQL` now falls back to the owner's `profiles.timezone` (validated against
`pg_timezone_names`, so a garbage zone still falls to UTC) between the work-item lookups and the
UTC fallback (ScoringLane.swift resolveTimezoneSQL). Pinned by DayAttestationTests
`testResolveTimezoneSQLFallsBackToProfileBeforeUTC` (profile subquery present, ordered before the
UTC fallback, validated) and `testAttestationNonUTCQuietDayBounds` (America/New_York quiet day =
23 h spring-forward, never 86400), plus quiet_day_timezone_integration_test which runs the EXACT
SQL against local PG: profile zone wins for a quiet day, invalid zone → UTC, work item still wins
over profile, and zone-correct 23 h bounds. Addressed.

### F3. Invalid/NULL profile zone silently skipped — PASS
Fix: Phase A of `scoring_enqueue_due_day_closure` (20261003230200) writes a bounded
`day_closure_skips (user_id, device_id, reason)` ledger (`invalid_zone` / `missing_profile`, PK
per triple, seen_at refreshed) for devices whose profile zone is not in `pg_timezone_names` or
whose profiles row is missing; the sweep itself no longer crashes on those rows. day_closure_
visibility_integration_test drives an invalid-zone device, a missing-profile device and a valid
device through the real sweep: invalid_zone and missing_profile are surfaced in the ledger, the
valid owner is enqueued, and the sweep returns only the valid enqueue. The missing-profile and
invalid-zone rows are inner-join-excluded from phases B/C (no closure work) and surfaced in A.
Addressed.

### F4. Dead-lettered days invisible to closure — PASS
Fix: Phase B of the sweep marks a day whose v2 job is `dead_letter` as
`closure_state='closed'` + `closure_reason='dead_lettered'` (fresh OR already
pending_reconciliation rows both settle), so a terminal-but-recoverable day is no longer stuck
pending with no marker. day_closure_visibility_integration_test covers: dead-letter the job →
sweep returns 1 → closure closed/dead_lettered → later sweep quiet. Addressed.
Remaining (minor, non-blocking): `closure_reason='dead_lettered'` is a marker; an operator still
needs the scoring_jobs_v2 reactivation procedure (documented elsewhere in the house patterns,
not in this migration) to actually re-run the day.

### F5. Verification quarantine no un-quarantine path — PASS
Fix: `noop_unquarantine_manifest_verification(uuid)` (service-role, 20261003230200) clears
`verification_failure_code/verification_failed_at/verification_attempts=0` and raises
`object_not_found` (22023) on a missing id; the migration header documents the operator runbook
AND the recorded-digest unbounded-retry tradeoff (the latter was my P2 note B — now documented in
code, not just in my findings file). verification_unquarantine_integration_test proves
quarantine → excluded → unquarantine → re-selected by the candidateSQL predicate, and
object_not_found for a missing object. Addressed.
Remaining (low, operational): the worker's in-process negative cache still holds a quarantined
objectId until eviction (limit 512) or lane restart, so an operator who unquarantines without
restarting the lane may not see the object re-verified immediately. DB-level re-selection is
proven; the cache is documented as in-process. Not a code defect.

### F6. placement_route_test weak assertion — PASS
Fix: the assertion now checks the exact propagated code and status —
`error.code === 'device_owner_mismatch' && error.status === 403` (node assert predicate), and the
raw cross-owner HTTP layer asserts `status===403` + `message==='cross_user_caller'`
(placement_route_test.ts step 7). This matches the actual behavior I probe-verified in round 1.
Test passes.

## PG planner quirk (fixer's NOTE — verified)

The fixer reported an eager `at time zone` evaluation against join-filtered rows. The phases B/C
construction in 20261003230200 computes `tz` as `CASE WHEN <zone in pg_timezone_names> THEN
<profile zone> ELSE 'UTC' END` — so `z.tz` is a VALID zone by construction on every row of the
derived table, and the outer `where z.valid` only selects real-zone rows. Even if the planner
evaluates `at time zone z.tz` on rows where `valid=false`, the value is the literal 'UTC'
(bounded by the CASE's else branch), so the expression can never see an unrecognized zone. The
CASE has a non-constant condition (an EXISTS subquery), so the planner cannot constant-fold it
into the raw `p.timezone`. The day_closure_visibility_integration_test exercises the real sweep
with an invalid zone ('Not/AZone') present and completes without error (the round-1 sweep would
have raised "time zone ... not recognized"), which is the direct behavioural proof. CONFIRMED
PROTECTED.

## New-issue scan in my challenge areas (no new findings)

- Outbox: the upload-failure release path is `try?` and rethrows the original error — a release
  failure still converges via lease expiry (bounded). No regression.
- Closure: Phase A/B/C all carry the `noop_account_retirements` exclusion (frozen owners get no
  closure work and no skip ledger) — verified consistent with the round-1 design; the retirement
  exclusion is pinned by day_closure_retirement_test. The round-2 sweep kept the `not_before`
  idempotency and only-yesterday scope; no unbounded enqueue introduced.
- Series fence: 20261003230100 widens the fence to the user/day max input_revision across ALL
  devices (the series write target is user/day-keyed), under the same advisory lock — strictly
  stronger than round 1, and the A->B->A device-switch hole it closes is in my challenge-3 area.
  metric_series_fence_user_scope_test passes.
- Verification candidateSQL + edge workers.ts predicate remain the same exclusion; unquarantine
  re-selects through the same predicate (test-proven).
- Day attestation fence (20261003204000) unchanged in round 2; attestation tests still pass.

## Remaining risks (accepted / non-blocking, no FAILs)

1. Outbox operator reactivation runbook not documented (raw SQL only) — see F1.
2. Verification unquarantine requires a lane restart or cache eviction to take effect in-process —
   see F5.
3. Closure `closure_reason='dead_lettered'` marks, but the scoring_jobs_v2 operator reactivation
   procedure is referenced, not restated, in the migration — see F4.
