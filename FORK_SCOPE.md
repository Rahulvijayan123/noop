# Fork scope: hosted compute pipeline

This fork (`Rahulvijayan123/noop`, branch `cloud-worker`) intentionally changes
the upstream NOOP product scope. Upstream NOOP is **offline-only**: no server,
no account, no cloud dependency (see upstream `AGENTS.md` and `docs/SCOPE.md`).
Upstream forbids submitting this work there — do not upstream these changes.

## What changed here

- **Hosted compute pipeline.** An authenticated collector (phone) pushes
  immutable, compressed raw-input batches to a user-owned Supabase project
  (edge function `push`, private object storage, Postgres work queues). A
  self-hosted Linux Swift worker (`Tools/CloudWorker`) drains the work queues:
  object verification, raw-stream projection, and day scoring with the exact
  `StrandAnalytics` math the app uses. Results publish back to Supabase
  projections the phone reads (owner-scoped RLS).
- **Worker.** `Tools/CloudWorker` is a Linux-first SwiftPM executable. It adds
  no analytics of its own; it calls `AnalyticsEngine.analyzeDay` unchanged, so
  hosted scores are numerically identical to the app's local scores on the same
  inputs (the parity contract is the same `StrandAnalyticsTests` suite, which
  passes unchanged on Linux).
- **Deployment assets.** `deploy/` contains the systemd unit, environment
  template (names only — no secrets), and runbook for the DigitalOcean Droplet
  runtime. Server-local state is rebuildable; Supabase Postgres and private
  object storage hold the authoritative copies.

## What is preserved

- Every BLE safety contract, protocol safety rule, and build instruction from
  upstream. The pairing/decoding/collection pipeline is untouched.
- Upstream's offline mode keeps working; the cloud path is additive and
  authenticated, and never weakens the local-only guarantees.

## Licensing

The upstream license is PolyForm Noncommercial 1.0.0 and expressly does not
grant commercial use. This fork inherits that license. Verify permitted code
provenance and obtain appropriate rights before any commercial deployment.

## Cloud mode on the phone (iOS/macOS app)

The hosted pipeline has two ends. The worker end is described above. The phone end is
`Strand/Push/`, and it is **opt-in and off by default**:

- **Nothing is uploaded until the user enables it.** `CloudPushSettings.isEnabled` is false unless the
  user turns it on (or the build is cut with `NOOP_FINAL_HOSTED_COMPUTE = YES`). An unconfigured build
  has no receiver at all, so the toggle cannot even be enabled. An install that never opts in behaves
  exactly like offline NOOP, and the BLE pairing/decoding/collection path is unchanged.
- **Enrollment is per installation.** `CloudEnrollment` redeems a one-time enrollment code against the
  `push` function, which binds the code's owner to a per-install `noop_…` installation token (stored in
  the Keychain, `AfterFirstUnlockThisDeviceOnly`). The phone never sees a Supabase service key, a B2
  key, or the enrollment pepper.
- **Capture is durable before it is useful.** Every notification is journaled at the notification
  boundary (`Strand/Collect/Collector.swift`) into an ordered, owner-scoped SQLite journal
  (`Strand/Push/CloudJournal.swift`) — including standard `0x2A37` HR/RR/contact, which never passes
  through the proprietary raw outbox. A record becomes durable *and* transport-eligible in one
  transaction; the journal is bounded in memory, and an overflow is counted and holds the history
  cursor instead of being dropped silently. Unacknowledged entries are never pruned.
- **Upload is receipt-driven.** `CloudTransportCoordinator` seals a bounded batch into an immutable
  gzip file, registers it as a durable job, uploads it on the prompt lane while the app runs or on one
  stable background `URLSession` when it does not, and deletes the file only after the receiver returns
  a checksum-matching durability receipt. A batch's records are released per batch, so an out-of-order
  acknowledgement cannot release (or delete) an earlier batch. Retries use bounded exponential backoff
  with full jitter.
- **Cloud mode has no local scoring fallback.** When it is enabled, the local analysis triggers in
  `Strand/App/AppModel.swift` are skipped and replaced with an upload pass, so the phone collects,
  transports and presents while the server computes. Raw measured live HR from BLE is still shown
  directly, because it is a measurement and not a derived score.
- **The upload lane is configured at build time.** `Config/CloudPush.xcconfig` is tracked and
  `#include?`s the gitignored `Config/CloudPushSecrets.xcconfig` (template:
  `CloudPushSecrets.example.xcconfig`), which carries the receiver endpoint, the fleet credential and
  the anon key. The fleet credential is an ingest credential, not a session: it is extractable from the
  app binary, and the server still requires the per-installation bearer before it accepts an owner's
  data.

### Not implemented on the phone (deliberately)

- Replace-window streams (`dailyMetric`, `journal`, `sleepSession`, `workout`) are not authored by the
  phone: the server owns those projections. The sealing path refuses them rather than mis-sending them
  as appends, and the receiver's half-open window rule (`start <= coordinate < endExclusive`) is
  encoded and tested in `CloudBatchBuilder` for when that path is built.
- The binary/object lane (`rawBatch`, PPG, IMU) is not wired. The archive path remains a local
  diagnostic facility.
- AccessorySetupKit setup/migration is not wired: the app still constructs its `CBCentralManager`
  directly and relies on the existing targeted reconnect and state restoration.
