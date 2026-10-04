# Workstream 2: Native BLE acquisition, locked-phone/lifecycle recovery, durable upload/ACK chain

Agent: g2-native-ble
Worktree: /Volumes/External SSD/Nara Whoop App V2/nara-core-plumbing
Branch: audit/core-plumbing-20261003, baseline 56809066
Scope: Strand/BLE, Strand/Collect, Strand/Push, Packages/NoopPush, Packages/WhoopStore, Packages/WhoopProtocol,
      StrandiOS lifecycle/plist (project.yml), StrandTests cloud/journal/IMU subset
Verification basis: code evidence in this tree (file:line) + runnable tests run locally. No device/staging/deployment access.

---

## 0. Verdict map (per requirement/test in scope)

| Item | Verdict | One-line evidence |
|---|---|---|
| 4.2.1 persist-before-process-death / no network on BLE callback | PASS | Collector.ingest:333-349; CloudJournal.submit nonisolated buffer, commit ≤1 s coalesced |
| 4.2.2 owner/device/stream/sequence bound at acquisition | PASS | CloudJournalStore.append binds ownerId/sourceId/deviceId at commit; CloudJournalEntry carries them |
| 4.2.3 acceptance watermark only after crash-safe boundary; no jumping; sparse receipts | PASS | applyReceipt per batch + checksum + owner scope; cursor saved only after acked (CloudJournal.swift:597-625, 652-688; CloudTransportCoordinator.swift:427-467) |
| 4.2.4 strap trim/ACK separate from server acceptance; no destructive trim | PASS | Backfiller.finishChunk:597-988; ack only after insert+archive+raw+cursor; ackTrim:986 |
| 4.2.5 backend WAL/outbox until archive/manifest reconciliation | NOT VERIFIED (server-side; see blocked list) | phone keeps unacked batches + files indefinitely (CloudJournalStore.pruneAcknowledged:628-658) |
| 4.2.6 expired auth/connectivity/storage/partial rejection/restart | PASS (code) | blocked vs failed states; resealBlocked; reconcileTasksAtLaunch; isRetryable |
| 4.2.7 quarantine malformed records, bounded, non-blocking | PASS (code) | CloudBatchState.blocked keeps bytes; resealBlocked; resealMissingPayload |
| 4.2.8 crash-safe local vs remote durability documented | PASS (code) | journal WAL+FULL vs store WAL+NORMAL; receipts bind owner+digest |
| 4.3 background/locked phone | MIXED | restoration + URLSession hand-off exist; see Q4/Q5 |
| T08 | PASS (code-level; offline/device behavior NOT VERIFIED) | journal retries durably; no fabricated coverage |
| T09 | PASS (code-level, package tests green) | seal/upload/receipt/prune all idempotent, journal-backed |
| T10 | PASS (code-level; real device reboot NOT VERIFIED) | content-derived batch ids; ledger seed; receipt dedup |
| T13 | PASS (code-level) | IMU realtime-only by construction; no recovered-IMU claim |
| T14 | PARTIAL — code paths exist; physical cases NOT VERIFIED (device-only) | see Q4/Q5 |
| T23 (phone side) | MIXED / NOT VERIFIED | ownership at acquisition solid; no account-switch lifecycle; see defect D1 |
| G6 dedup keys | PASS with one narrow caveat | wire keys include (ts,rrMs,seq); caveat C1 |

---

## 1. Acquisition-time ownership (Q1)

Every journaled record is bound to the owner/device/stream at ACQUISITION, not upload.

- `CloudJournal.Configuration(ownerId:sourceId:deviceId:)` is fixed when the runtime starts; the journal is single-owner by construction (CloudJournal.swift:139-146, 1182-1190; CloudCapture.swift:450-456).
- `CloudJournalStore.append` stamps `owner_id/source_id/device_id` into the row in the SAME transaction that makes it durable (CloudJournal.swift:513-594). `CloudJournalEntry` carries ownerId/deviceId/sourceId (CloudJournal.swift:164-169).
- Per-record `deviceId` overrides the config default at the capture seam (CloudJournal.swift:558 `r.deviceId ?? deviceId`); Collector and Backfiller pass the real strap id per call (Collector.swift:319, Backfiller.swift:875).
- The wire body cannot choose the owner: the batch is built with `sourceId` and the receiver resolves device ownership server-side (CloudUploadSession.swift:117-141; CloudPushIdentity.swift:1-15).
- The CloudHeartRateLedger is seeded from the journal tail on relaunch (CloudCapture.swift:509-513, 550-556), so dedup state does not outlive the journal.

Account switch (T23 phone side):
- `CloudPushRuntime.stop()` is NEVER called anywhere in Strand/StrandiOS (grep). `signOutCurrentOwner()` is defined (CloudPushIdentity.swift:78-84) but never called from UI.
- No A→B account-switch UI exists in this tree: the enrollment view only offers enroll when `.notEnrolled` and then shows an enrolled card with no re-enroll/sign-out action (CloudEnrollmentView.swift:139-165, 244-296).
- If a re-enroll to a different owner were forced at the store level, the journal would stay configured with the OLD owner while `CloudPushIdentityStore.current()` (used for the Authorization header, CloudUploadSession.swift:120-122) returns the NEW owner. Defense-in-depth: the durability-receipt owner check (`receipt.matches(batch, owner: AccountScope(projectURL, userID: rebuilt.ownerId))`, CloudTransportCoordinator.swift:446-449) would fail for any receipt bound to a different owner, so records would never be released under the wrong owner. But pending batches of A would still be transmitted with B's credentials (credential confusion). See defect D1.

Shared/default-user path: none. `CloudPushIdentityStore.current()` returns nil until an enrollment identity exists; `startIfEnabled` is then a no-op (CloudCapture.swift:547-562). Offline install allocates nothing (CloudCapture.swift:462-468).

## 2. Crash-safety of persistence vs BLE callback (Q2)

- Cloud journal: `submit` is `nonisolated`, non-throwing, non-blocking; it appends to a bounded in-memory staging buffer (8192 records / 8 MiB) and returns (CloudJournal.swift:1117-1137). A coalescing drain commits ≤ ~1 s later (drainSoon: 700 ms, drainLoop: 1 s; CloudJournal.swift:1203-1220).
- Commit is WAL + `synchronous=FULL` (CloudJournal.swift:400-403, 436-437): a committed record survives a process kill (WAL fsynced at commit).
- Records become durable AND transport-eligible in one transaction (`state = 0` is eligibility; CloudJournal.swift:409-413, 513-594).
- The BLE callback path never waits on network/heavy compute: `CloudCapture.record` runs before the 64-frame/30 s store buffer (Collector.swift:333-349), encode is cheap, and the heavy history decode runs on `Task.detached(priority: .utility)` (Backfiller.swift:641-646). No await on the receiver from the notification path.
- Local WhoopStore is WAL + `synchronous=NORMAL` (WhoopStore.swift:171-186): durable against process kill, only OS crash/power-loss can lose the last transaction — documented tradeoff.
- Pre-commit window is bounded and explicit: overflow is counted, the history cursor is held (`history_cursor_held`), and a gap is surfaced instead of silently dropped (CloudJournal.swift:1078-1086, 740-745; stats:686-720).
- Lifecycle flush: the scene delegate gives buffered standard-HR rows a persistence attempt on backgrounding/termination under a UIKit background task (HomeScreenQuickActions.swift:128-171; CloudUploadExecutionAssertion.swift:9-44).

## 3. Upload/ACK chain, durable-acceptance boundary (Q3)

- Seal: a group is sealed when it reaches age (~2 s active, 10 s inactive; CloudCapture.swift:539-548) or size (2000 records / 1 MiB), written atomically to `<batchId>.ndjson.gz` (tmp + rename, CloudTransportCoordinator.swift:284-291), then `registerSeal` marks the file + job row + exact membership in ONE transaction (CloudJournal.swift:681-734).
- HTTP 200 alone is NOT acceptance. `handle(outcome:)` requires status 200 AND a parseable body, then `applyReceipt` validates: `ack.status == "accepted"`, the ack EXACTLY matches the rebuilt batch (id/stream/device/endCursor/recordCount), a durability receipt is present, and `receipt.matches(batch, owner:)` (owner user id, digest, sizes, object key; CloudTransportCoordinator.swift:416-467; PushDurabilityReceipt.swift:23-48). Only then `journal.applyReceipt` releases the batch's records (checksum match required; CloudJournal.swift:597-625).
- A transport-level "accepted" without a durability receipt keeps the file and retries (CloudTransportCoordinator.swift:438-442).
- The append cursor advances ONLY after a durable, checksum-matched receipt (CloudTransportCoordinator.swift:456-462; CloudJournal.swift:678-685 `saveAppendCursor` called only from the `.acknowledged` branch).
- Per-batch release: an out-of-order ack cannot release an earlier in-flight batch; the earlier hole stays (CloudJournal.swift:590-596 comment, applyReceipt one batch at a time). A failed batch is a durable job (`sealed_batch` state failed/blocked) that the transport keeps retrying independently of the cursor, so a failed record is never jumped.
- Prune: only ACKED entries are pruned, and only after `ackedRetentionSeconds` (7 days); unacknowledged records are never removed (CloudJournal.swift:628-658; comment at 628-630).
- Lost ACK / duplicate batch (T10): batch id is content-derived (`stableUuid(header: identity, lines: selectedLines)`, PushProtocol.swift:147), so re-sending the same bytes produces the same id; the receiver returns the stored acknowledgement (CloudUploadSession.swift:16-19; CloudTransportCoordinator.swift:352-362 comment). Duplicate receipts are `.duplicate` and harmless (CloudJournal.swift:611-613).
- Strap history ACK/trim is entirely separate from server acceptance: `finishChunk` acks the strap ONLY after decoded insert + (if raw enabled) raw enqueue + `strap_trim` cursor write succeed, and the ack is a link-layer `.withResponse` ack, never triggered by upload state (Backfiller.swift:862-988). There is NO destructive strap-trim operation to make tests pass: the trim advances only when the phone holds the data.
- Quarantine: non-retryable rejections mark the batch `blocked`, keep the bytes, stop retrying, and surface `lastError` (CloudTransportCoordinator.swift:516-526). A builder-side defect is repaired by `resealBlockedBatches` at launch (CloudTransportCoordinator.swift:148-158; CloudJournal.swift:477-495). A vanished payload file before ack triggers `resealMissingPayload` (CloudJournal.swift:497-512).

## 4. Background execution (Q4 / T14 code-verified parts)

- Declared iOS background modes: `bluetooth-central`, `location`, `fetch`, `processing` (project.yml:292-316).
- BLE restoration: `CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID` where `restoreID = "com.openwhoop.ble.central"` (BLEManager.swift:568, 1384-1394, 1600-1606). `willRestoreState` re-derives the decode family, re-adopts the source identity, forces re-subscription (`restoreNeedsResubscribe = true`), re-arms raw-IMU capture, and re-issues the clock request (BLEManager.swift:6515-6587).
- Acquisition starts without a foreground JS/bridge: the app delegate's `didFinishLaunching` calls `CloudPushRuntime.shared.startIfEnabled()` before any scene exists, and the runtime accepts records before the journal SQLite file opens (`enableStaging()`; CloudCapture.swift:478-486; HomeScreenQuickActions.swift:57-75). This is pure native Swift — no JS bridge anywhere in the tree.
- Background URLSession: one stable session, identifier `<bundleIdentifier>.cloud.upload` (CloudUploadSession.swift:57-59), `isDiscretionary = false` (CloudUploadSession.swift:87), `sessionSendsLaunchEvents = true` (CloudUploadSession.swift:88), file-backed immutable uploads (`uploadTask(with:fromFile:)`, CloudUploadSession.swift:150-160).
- Completion-handler hand-off: the only app delegate forwards `handleEventsForBackgroundURLSession` to `takeBackgroundCompletionHandler` (HomeScreenQuickActions.swift:76-91; CloudUploadSession.swift:207-225, 258-266).
- Relaunch reconciliation: `reconcileTasksAtLaunch` returns any `reserved` batch whose task is gone to the eligible pool (CloudTransportCoordinator.swift:300-314); `cleanUpAcknowledgedFiles` removes acked files that survived a crash (CloudTransportCoordinator.swift:316-327).
- In-process lane while the scene is inactive: uploads hold a UIKit background-task assertion until the receipt is applied (CloudUploadSessionExecutionAssertion; CloudTransportCoordinator.swift:349-361, 385-392).
- Eviction vs force-quit vs Settings-Bluetooth vs Control-Center: only the CODE-verifiable parts are above. Whether the OS actually relaunches for each specific user action (Settings Bluetooth off, Control Center toggle, force-quit before first unlock, eviction timing) is device-only evidence — see blocked list.

## 5. Locked-phone / file protection (Q5 / T14)

- Cloud journal + payload files + object-lane progress DB: `completeUntilFirstUserAuthentication` set on the cloud directory and on each payload file (CloudJournal.swift:353-373; CloudTransportCoordinator.swift:283-291, 334-341). Readable after the first unlock since boot, encrypted at rest. The WAL/SHM sidecars inherit via directory attribute.
- `CloudJournalPaths.isDataAvailable` reports when the journal file is unreadable so persistence is reported as deferred rather than successful (CloudJournal.swift:379-387).
- Keychain credentials: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (CloudKeychain.swift:16-27).
- Reboot-before-first-unlock: `journal.activate` throws `protectedDataUnavailable` and `start()` catches by calling `CloudJournal.disableStaging()` (CloudCapture.swift:496-507). See defect D2: the promised "committed on the next activation attempt" retry does not exist in this tree.
- The local store has the same locked-phone failure but self-heals: `bootstrapStore` logs and the periodic backfill tick re-attempts on unlock (BLEManager.swift:1531-1565 area; see comment "the periodic tick ... re-attempts so it self-heals on unlock").

## 6. Duplicate/dedup (Q6 / G6)

- Wire identity keys (appendRegistry, PushProtocol.swift:43-76):
  - hrSample: (ts) — one bpm per second, receiver conflict rule; phone sends each second once via CloudHeartRateLedger (first sample wins; CloudCapture.swift:280-344, 346-398).
  - rrInterval: (ts, rrMs, seq) — seq is the beat identity within the second; equal beats in one batch are numbered 0,1,… so both survive (CloudCapture.swift:242-253 rows; StreamStore.swift:207-224).
  - rawImuSession: (ts) per second (PushProtocol.swift:323-324).
  - event: (ts, kind); battery/spo2/skinTemp/resp/gravity/stepSample/sleepStateSample: (ts) [+counter etc.].
- Dedup key = table + deviceId + key fields, hashed (keyFingerprint, PushProtocol.swift:304-309). Owner is implicit in the receiver's registry (device ownership server-side).
- Caveat C1 (G6): the LOCAL rrInterval key is (deviceId, ts, rrMs, seq). Within one batch, equal (ts, rrMs) beats get seq 0,1,2…; but a second split across two live flush boundaries restarts seq at 0 and `ON CONFLICT DO NOTHING` keeps the first row (StreamStore.swift:207-231 comment). Two DISTINCT beats with identical (ts, rrMs) delivered in different batches therefore collapse, and because the wire key mirrors (ts, rrMs, seq), the collapse propagates to the server. Extremely narrow (identical ms value in the same second across a flush boundary); the code documents it honestly. HR is safe by design (one bpm per second is the receiver contract).
- Sequence rollover / reinstall: the journal's dense `monotonic_seq` persists across relaunch and is phone-local (CloudJournal.swift:409-417, 518-526). The strap-side clock is re-correlated per connect (ClockCorrelation.swift:22-36). A reinstall mints a new sourceId and new per-strap deviceId (CloudPushIdentityStore.sourceId, deviceId(forPeripheralKey:)), so a fresh install is a fresh device on the server; old journal rows are gone with the container.

## 7. T13 — realtime-only vs banked; disabled/unsupported streams

- IMU/PPG are realtime-only by construction on the WHOOP 5/MG path: `recordGroundTruthImu` only appends frames received on the live link into `ImuSessionFileStore` (Collector.swift:408-417; ImuSessionFileStore.append:136-165). There is no banked-history IMU recovery path and no place that claims a recovered IMU gap when only HR arrived. The upload source pages `rawImuSession` strictly after the durable cursor and refuses to advance at or past a second whose flush failed (ImuObjectSource.swift:63-80, 300-323, 410-445).
- The IMU store's coverage is durability-honest: `diskSeconds` vs `pendingSeconds` are reported separately (ImuSessionFileStore.swift:171-199).
- HR history is the recoverable path: the Backfiller offloads the strap's banked history and journaling happens only after local insert (Backfiller.swift:870-875).
- Disabled/unsupported streams are truthful: WHOOP 4 raw-IMU is refused with `.unsupportedDeviceFamily` and never re-armed (BLEManager.swift:2266-2284); live capability sets are explicit and exclude calibrated SpO₂ (WhoopLiveCapabilities.swift:24-42); a cloud that is off allocates nothing (CloudCapture.swift:462-468).
- Caveat C2 (T13/T08): the phone does not persist a per-day, versioned "realtime-only gap vs recovered banked" attestation record in this tree (no DayCompleteness record found on the phone side; CloudJournalStats only tracks pending/overflow/held cursor, CloudJournal.swift:244-257). What exists is honest-but-silent: gaps are held cursors and staging-overflow counters, surfaced in stats/UI, not a durable per-day completeness row.

## 8. T09 — kill/restart around append/ACK/upload

State machine survives restart because every step is journal-backed:
- Append: staging→commit is re-entrant; a relaunch continues the dense sequence (CloudJournal.swift:518-526).
- Seal: file written atomically; re-seal after crash lands on the same batch id; membership+job one transaction (CloudTransportCoordinator.swift:236-283).
- In-flight batch: a `reserved` batch whose task vanished is re-queued at launch (CloudTransportCoordinator.swift:300-314).
- Receipts: applied per batch with checksum; duplicate receipts harmless; unacked work never pruned (CloudJournal.swift:597-658).
- Upload: content-derived batch id makes a re-upload idempotent (PushProtocol.swift:147; CloudUploadSession.swift:16-19).
- Prune: only acked, only after 7 days (CloudJournal.swift:652-658).

## Defects / gaps found (code-verified)

D1 — Disabling cloud does not stop the NDJSON upload path.
Evidence: `CloudPushSettings.setEnabled(false)` only flips a UserDefaults flag (CloudPushSettings.swift:87-94). `CloudPushRuntime.stop()` is never called (grep over Strand/ + StrandiOS/). The NDJSON journal/transport cycle has NO `CloudPushSettings.isEnabled` gate: `CloudTransportCoordinator.cycle()` checks `identity()` but not the master switch (CloudTransportCoordinator.swift:176-206), and `CloudCapture.record` gates only on `sharedIfRunning` (coordinator != nil) (CloudCapture.swift:41, 75, 133). Only the object (IMU) lane checks the switch per pass (CloudCapture.swift:664-666). So once cloud is enabled, turning it off continues to journal and upload new captures. The enrollment UI presents "Disable cloud" as stopping uploads (CloudEnrollmentView.swift:286-296). Severity: medium (privacy/consent mismatch, not data loss).

D2 — No journal re-activation after a protected-data failure at launch.
Evidence: `journal.activate` is called exactly once (CloudCapture.swift:498). On `protectedDataUnavailable` (locked before first unlock) `start()` catches and calls `CloudJournal.disableStaging()` (CloudCapture.swift:496-507), and the comment promises "staged records stay staged and are committed on the next activation attempt" — but no retry of `activate` exists (grep). `CloudPushRuntime.start` is idempotent via `alreadyRunning` (CloudCapture.swift:441-445), so subsequent `startIfEnabled` calls return early. Live records captured in that process lifetime are dropped from the cloud journal (submit() is a no-op when staging is off). The local store self-heals via the periodic backfill tick; the cloud journal does not. Severity: low-to-medium (rare: BLE relaunch before first unlock since boot; strap-banked history is still recoverable later via backfill; only live-only seconds are lost from cloud).

## Blocked checks (need device/staging/deployment)

1. T14 eviction vs force-quit vs Settings-Bluetooth vs Control-Center: whether iOS delivers each wake/relaunch on real hardware. Code paths exist (restoration id, URLSession hand-off), delivery is OS-dependent. Device-only.
2. T14 locked-phone BLE collection end-to-end (screen locked, notifications arriving, journal committing in background). Code is written for it; physical capture required.
3. T08 offline-phone + storage-outage retry end-to-end (journal backoff → relaunch reschedule → retry completes). Code-verified; live retry requires device + a staged receiver.
4. T10 device reboot / strap sequence reset with a real strap (dedup convergence). Code-verified; strap behavior device-only.
5. 4.2.5 backend WAL/outbox until archive/manifest reconciliation, and `noop_upload_receipts` confirmation semantics. Server-side; needs staging DB + edge function evidence.
6. Migration ordering lead (20260918040000_projection_debt vs 20260921060000_intake_durability) — both files exist in this tree; application-order failure needs a staged Postgres apply. See supabase/functions/tests/README.md for the local gate (needs Deno 2.5.6 + PostgreSQL 18.3 + PostgREST, not present in this worktree).
7. Deployed revision identity (FRWHOOP_SOURCE_REVISION / NOOPSourceRevision) vs actual deployed binary. Deployment evidence.

## Tests run (this tree, macOS)

- Packages/NoopPush: `swift test` — 194 tests, 0 failures.
- Packages/WhoopStore: `swift test` — 631 tests, 0 failures.
- Packages/WhoopProtocol: `swift test` — 816 tests, 1 skipped, 0 failures.
- StrandTests subset via `xcodegen generate` + `xcodebuild test -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/nara-dd-mac-g2 -only-testing:StrandTests/CloudPushTests -only-testing:StrandTests/JournalLogicTests -only-testing:StrandTests/ImuObjectLaneTests -only-testing:StrandTests/BackfillContinuationTests` — 97 tests, 0 failures.
- StrandTests full suite (300 files) not run; the known two caption tests fail on Pacific-time Macs (pre-existing, outside this scope).

## Files that need changes (recommended next actions)

1. Strand/Push/CloudCapture.swift (+ CloudTransportCoordinator.swift): honor `CloudPushSettings.isEnabled` in the NDJSON journal/transport path (D1). Simplest: gate `CloudCapture.record*` on the switch too, or call `CloudPushRuntime.shared.stop()` (→ `CloudJournal.shared.deactivate()`, which exists at CloudJournal.swift:1182-1190) when the switch flips.
2. Strand/Push/CloudCapture.swift: add a re-activation retry for the journal (D2) — e.g. re-attempt `journal.activate` from the object-lane loop or a scene-active hook when `CloudJournalPaths.isDataAvailable` becomes true (mirror the local store's self-heal tick).
3. (Optional, G6) StreamStore.swift rrInterval key: decide whether equal-(ts,rrMs) beats across flush boundaries must survive; if so, make seq assignment deterministic across batches (e.g. include ord/count in the key or a per-(ts) counter persisted across flushes) and mirror on the wire.
4. (Optional, T13) Persist a per-day realtime-gap attestation if the spec's 4.4 DayCompleteness record is adopted phone-side.
