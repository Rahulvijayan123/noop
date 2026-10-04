# repair-ble — phone-side cloud consent, journal recovery, owner hardening

Agent: repair-ble (workstream g2-native-ble D1/D2, g5-auth-isolation T23-latent items, C1 doc)
Branch: audit/core-plumbing-20261003 (head 4c85df9a)
Date: 2026-10-03
Scope (owned files only): Strand/Push/CloudCapture.swift, CloudTransportCoordinator.swift,
CloudPushSettings.swift, CloudPushIdentity.swift, CloudJournal.swift, CloudUploadSession.swift,
StrandTests/CloudPushTests.swift.

## 1. D1 — disabling cloud must stop staging AND the upload cycle

Evidence before: `CloudPushSettings.setEnabled` only flipped a UserDefaults flag
(CloudPushSettings.swift:87-94); `CloudPushRuntime.stop()` was never called; the NDJSON
journal/transport cycle had no `isEnabled` gate (`CloudTransportCoordinator.cycle()`
CloudTransportCoordinator.swift:176-206, `CloudCapture.record*` gated only on `sharedIfRunning`).
So "Disable cloud" kept journaling and uploading new captures (privacy/consent mismatch).

Fix (three layers, all inside the owned files):

1. Master-switch lifecycle — `CloudPushSettings.setEnabled` now also drives the runtime:
   - `setEnabled(false)` fires `CloudPushRuntime.shared.stop()` (async Task): the runtime tears
     down, `CloudHeartRateLedger.shared.reset()`, `CloudJournal.shared.deactivate()` disables
     staging and flushes the staging buffer into the durable journal. Pending sealed batches and
     their payload files are untouched; nothing is deleted or uploaded while cloud is off.
   - `setEnabled(true)` fires `CloudPushRuntime.shared.startIfEnabled()` (idempotent), which
     re-activates the journal and restarts the coordinator. Retained work resumes on the next pass.
   - Both are no-ops when the runtime is already in the target state.

2. Zero-window defence on the capture path — `CloudCapture.record(frame:)`,
   `CloudCapture.recordStandardHR` and `CloudCapture.recordHistory` now guard on
   `CloudPushSettings.isEnabled` BEFORE the heart-rate ledger claims a second. A second claimed but
   never staged would otherwise be skipped as "already sent" after re-enable; the ledger is also
   reset by `stop()`, so there is no loss either way.
   `CloudPushRuntime.submit`/`submitDurably` also gate on `isEnabled`, closing the window between
   the flag flip and the `stop()` Task landing.

3. Zero-window defence on the transport — `CloudTransportCoordinator.cycle()` gates on a new
   injectable `cloudEnabled: () -> Bool` (defaults to `CloudPushSettings.isEnabled`) and returns
   before negotiating/sealing/sending/reserving anything. Injected so tests can drive the gate
   deterministically (production path unchanged).

Why stop() (not just gating) is the right pause: `stop()` resets the in-memory heart-rate ledger,
so seconds captured during the disable window (which `submit` drops) are NOT held as "already
sent"; on re-enable the ledger is re-seeded from the journal tail, so only actually-committed
seconds are skipped. A gate-only approach would leak ledger state and silently drop those seconds.

Regression tests:
- `testDisablingCloudStopsStagingAndReEnableResumesIt` — deactivate → submit is a no-op, retained
  record stays; activate → staging resumes, nothing deleted.
- `testDisabledCloudStopsTheUploadCycleAndReEnableResumesIt` — coordinator with a controllable
  `cloudEnabled`; disabled: a sealed batch stays `sealed` and its records retained across a full
  `start()` + cycle; re-enabled: the next cycle picks the batch back up (upload attempt to a
  dead endpoint fails as a retryable transport error; records are never deleted).

## 2. D2 — journal re-activation after a protected-data failure at launch

Evidence before: `journal.activate` was called exactly once (CloudCapture.swift:498); on
`protectedDataUnavailable` the catch called `CloudJournal.disableStaging()` and nothing ever
retried activation, so every live second captured after a locked launch was lost from the cloud
path for the whole process lifetime.

Fix: `CloudPushRuntime.start()` now, on the activation failure, schedules a cancellable
re-activation task (`scheduleJournalReactivation`) that:
- polls `CloudJournalPaths.isDataAvailable(at: directory)` every 2 s (the SAME signal `activate`
  itself uses — cheap file stats, no network);
- the moment the journal file becomes readable (first unlock since boot), re-calls
  `journal.activate(configuration:policy:)`, re-seeds the heart-rate ledger from the journal tail,
  and kicks the coordinator so staged records are sealed and sent;
- is cancelled by `stop()`, so a disabled or signed-out runtime never re-activates behind the
  user's back.

The journal itself needed no change: a failed `activate` leaves `store == nil`, so a later
`activate` retries the open. Staged records from before the failure (the earliest restored
notifications, buffered in the bounded staging queue) are committed in the same activation.

Regression test: `testJournalReactivationSucceedsOnceProtectedDataIsAvailable` — an unreadable
(chmod 000) journal file makes `activate` throw `protectedDataUnavailable`; after the file becomes
readable, `activate` succeeds and capture commits. (Skips when running with privileges that ignore
file permissions.)

Note: live seconds captured DURING the locked window are still not persisted (the journal file is
unreadable; there is no place to write them). The D2 contract — "live seconds AFTER a locked
launch still reach the cloud" — is what this fixes. The local WhoopStore self-heals independently.

## 3. T23 — acquisition-time owner scoping on the seal/send paths (g5 latent items)

Evidence before (g5-auth-isolation.md Q2): `pendingGroups`/`pendingEntries`/`sealedBatches` had no
owner predicate; the upload token was resolved at send time from `CloudPushIdentityStore.current()`
with no owner comparison; `sealReady` stamped the batch with the current identity's sourceId while
the candidate owner came from the stale journal config. Latent (no UI switch today), but one future
account-switch button away from uploading A's pending rows under B's token.

Fix (minimal, no multi-file redesign):

(a) Owner filters in the store, all keyed to the journal's CONFIGURED owner:
- `pendingGroups` / `pendingEntries` now take `ownerId` and filter `journal_record.owner_id`.
- `sealedBatches` takes `ownerId` and filters `sealed_batch.owner_id` — this also scopes launch
  reconciliation, blocked-batch re-seal and acked-file cleanup, which all read through it.
- `registerSeal`'s membership-mark UPDATE adds `owner_id` (seq is global across owners, but the
  predicate keeps it exact).
- `rescheduleFailed` and `stats`/`countBatches` are owner-scoped, so another owner's retained rows
  are not made due by this runtime and do not show as this owner's "pending uploads".
- All journal actor facades pass `configuration.ownerId`; with no configuration they return empty.

(b) Coordinator identity guards (the acquisition-time-vs-current check):
- `sealReady(identity:)`: skip a candidate whose `ownerId != identity.ownerId` (leave the group
  pending — it stays quarantined under its own owner) and record a `lastError` diagnostic.
- `sendEligible(identity:)`: before either upload lane, require `batch.ownerId == identity.ownerId`;
  on mismatch, `markFailed(..., blocked: true)` — quarantine retains the records AND the payload
  file under the original owner (contract C3), with a clear `last_error` style message. Never sent.
- Background lane: `enqueueBackground` returns -1 on owner mismatch (the token is resolved at send
  time; refusal must not create a task); the coordinator quarantines it the same way.

(c) Token-resolution rule at the HTTP layer (second line of defence):
- `uploadForeground(batchId:fileURL:expectedOwnerId:)` refuses with a new
  `UploadError.ownerMismatch` when the current identity's owner differs from the batch's
  acquisition-time owner.
- `enqueueBackground` applies the same rule (returns -1).
- `rebuildBatch` now binds the durability receipt to `batch.ownerId` (the acquisition-time owner)
  instead of the current identity, so a receipt can never be validated against a different owner.

Regression tests:
- `testJournalSealAndBatchViewsAreScopedToTheConfiguredOwner` — switch owners on the same store:
  A's pending records are not sealable (or visible) under B; B's records carry B; A's records
  survive for A's return.
- `testCrossOwnerBatchIsQuarantinedNotUploadedUnderADifferentOwner` — a sealed batch owned by A is
  `blocked` (not uploaded) when the runtime runs under B; records and payload file retained.
- `testUploadSessionRefusesToSendAnotherOwnersBatch` — the HTTP layer throws `ownerMismatch`.

## 4. C1 (documented only — StreamStore.swift is NOT owned by this agent)

Finding (g2-native-ble.md caveat C1): the local rrInterval key is `(deviceId, ts, rrMs, seq)` and
`seq` restarts at 0 per batch (StreamStore.swift:207-231, `seqByTsRr` dict is batch-local), so two
DISTINCT beats with identical `(ts, rrMs)` delivered in different live flush boundaries collapse:
the second batch writes `seq 0` and `ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING` keeps the
first row. Because the wire RR identity mirrors `(ts, rrMs, seq)`, the collapse propagates to the
server.

Recommended fix (requires ownership transfer — this file lives in Packages/WhoopStore, NOT in this
agent's ownership list):

- Make the equal-beat counter DETERMINISTIC ACROSS BATCHES instead of batch-local. Concretely,
  persist a per-`(deviceId, ts)` (or per-`(deviceId, ts, transport)`) occurrence counter that
  survives flush boundaries, and number equal `(ts, rrMs)` beats from it. The key stays
  `(deviceId, ts, rrMs, seq)`; a re-synced identical row still reproduces the same `(ts, rrMs, seq)`
  so the current idempotency is preserved.
  - The natural home is the `rrInterval` table itself: keep `seq` as the stored per-`(deviceId, ts,
    rrMs)` occurrence number, and on a batch that re-delivers a beat whose `(deviceId, ts, rrMs)`
    row already exists, advance the STORED row's `seq` (or store a separate monotonic
    `ord`-style counter per `(deviceId, ts)`) instead of `DO NOTHING`.
  - `ord` (the per-`ts` emission order, `ordByTs`) has the same batch-local restart caveat and
    should move to the same persisted counter (it is already excluded from the key, so it can be
    promoted in place).
- Mirror on the wire unchanged (PushProtocol key is already `(ts, rrMs, seq)`); the capture seam
  (CloudCapture.swift) carries the decoded `seq` through unchanged, so once the store emits a
  distinct seq, the cloud sees it too.
- Ownership transfer needed: `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift` (and its
  tests) must be assigned to the g2-native-ble or g6 owner; this repair agent owns only Strand/Push.
- Severity: extremely narrow (identical ms value in the same second across a flush boundary) and
  honestly documented in code; not blocking.

## 5. Task 5 — latent sign-out path wiring (no new UI)

`CloudPushIdentityStore.signOutCurrentOwner()` and `forget(ownerId:)` had zero callers and never
stopped the runtime; a signed-out install would keep staging NEW records into the old owner's
journal (cycle() has no identity and returns early, but staging is not identity-gated) — new
A-labelled data the old owner never consented to.

Fix (no UI invented): both now stop the runtime (same path D1 uses). The owner pointer is cleared
BEFORE the stop so a racing `startIfEnabled()` (scene activation or a settings flip) cannot re-adopt
the old identity. The journal and the signed-out owner's credential are retained for re-enrollment;
`startIfEnabled()` is a no-op until an enrollment identity exists again.

## 6. Tests run (this tree, macOS)

- `xcodegen generate && xcodebuild test -scheme Strand -destination 'platform=macOS'
  -derivedDataPath /tmp/nara-dd-mac-ble -only-testing:StrandTests/CloudPushTests`
  → 46 tests, 0 failures (40 pre-existing + 6 new: 2×D1, 1×D2, 3×T23).
- Full `-only-testing:StrandTests` suite → 2448 tests, 2 skipped, 9 failures:
  - SkinTempAbsoluteDisplayTests + SleepCarriedStampTests: the known pre-existing Pacific-time
    caption failures (documented in the task contract).
  - IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets and
    TestBundleRobustnessTests.testActiveDomainsIncludesUniversalOnlyWhenAModeIsOn: reproduced at
    the baseline commit 4c85df9a in a separate git worktree (pre-existing, outside this scope).
  - DetectedWorkoutReconciliationTests.testOptInCandidatePublishesTwelveMinutesAndOnlyLogsTenFifteenMinuteShadows:
    failed in the full run but passes in isolation at baseline AND in the current tree — transient
    (concurrent sibling edits were landing in this shared worktree during the run). Not related to
    any file this agent touched (none of the failing tests reference Strand/Push cloud types).
- None of the failing tests touch any file changed by this agent.

## 7. Files changed (working tree; nothing committed)

- Strand/Push/CloudPushSettings.swift — master switch drives runtime stop/start (D1).
- Strand/Push/CloudCapture.swift — isEnabled gates on capture+submit; D2 re-activation task;
  ledger re-seed helper.
- Strand/Push/CloudTransportCoordinator.swift — cycle isEnabled gate; seal/send owner guards +
  quarantine; receipt owner from batch; background-lane mismatch handling.
- Strand/Push/CloudJournal.swift — owner filters on pendingGroups/pendingEntries/sealedBatches/
  registerSeal mark/rescheduleFailed/stats (+ actor facades).
- Strand/Push/CloudUploadSession.swift — uploadForeground/enqueueBackground owner-match refusal
  + ownerMismatch error.
- Strand/Push/CloudPushIdentity.swift — signOutCurrentOwner/forget stop the runtime.
- StrandTests/CloudPushTests.swift — 6 regression tests (D1×2, D2×1, T23×3).

## 8. Contract decisions applied

- C3 (owner identity): sealed batches of a different owner are quarantined (blocked, retained
  under the original owner), never reassigned or uploaded under a different owner's token.
- C1/C6 test commands honoured (no supabase work in this task; no migrations needed).
- C8: no files outside the ownership list were modified (a one-line temporary compile fix to
  sibling in-flight files was applied and superseded by the siblings' own identical fixes; nothing
  from this agent remains in those files).

## 9. Remaining gaps / NOT VERIFIED

- D2 end-to-end on a real locked iPhone (first-unlock timing, background BLE relaunch while locked)
  — device-only; code + journal-level test verified.
- D1 full-cycle behaviour on a configured build (receiver present) — tests use an injected
  `cloudEnabled`/dead endpoint because the test build is unconfigured; the production path is
  covered by code review + the same gate logic.
- T23 end-to-end A→B account switch on a real install (no switch UI exists by design; the guard is
  the safety net) — code-verified only.
- C1 rrInterval cross-flush collapse: recommended fix documented; implementation requires ownership
  transfer to a Packages/WhoopStore owner (StreamStore.swift).
- No device/staging/deployment access; nothing here claims physical-device verification.
