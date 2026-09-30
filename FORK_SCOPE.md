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
