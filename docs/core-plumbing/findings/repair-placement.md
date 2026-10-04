# Repair workstream — placement (G4 manual baseline) + wear wiring (G3/G7)

Owner: `repair-placement` · Date: 2026-10-03 · Branch: `audit/core-plumbing-20261003`
Parent findings: `docs/core-plumbing/findings/g34-wear-placement.md` (items 1/2/3/5/6/7).

## Scope implemented

### 1. G4 placement model (findings item 1; spec §6) — DONE

- **Migration** `supabase/migrations/20261003210000_placement_intervals.sql` (new, range
  `20261003210000-20261003215999`, additive, one transaction, house style):
  - `public.placement_intervals(owner, device_id nullable, placement, effective_start,
    effective_end nullable, recorded_at, source, revision)` with CHECKs
    (`placement in ('wrist','bicep','other','unknown')`, `source in ('user','device')`,
    half-open `effective_end is null or effective_end > effective_start`), column comments.
  - RLS: owner-select policy `(select auth.uid()) = owner`; service-role all. Table grants:
    select for `authenticated`, all for `service_role`.
  - `set_placement_interval(p_owner, p_placement, p_effective_start, p_device=null,
    p_effective_end=null, p_source='user')` — SECURITY DEFINER, `set search_path = public`,
    guard `if auth.uid() is not null and auth.uid() is distinct from p_owner then raise
    exception 'cross_user_caller'`, device-ownership check (`device_owner_mismatch`), and the
    correction semantics:
      1. every interval strictly containing the declaration time is closed there (half-open);
      2. an interval starting exactly at the declaration time is replaced in place (revision
         bump) — the degenerate close;
      3. the new open interval is capped at the next interval's start, so a future-dated
         interval is never overwritten.
    History is never silently rewritten (rows are cut or superseded, never deleted); unannotated
    history stays UNKNOWN — nothing backfills.
- **Phone** `Strand/Data/Placement.swift` (new): `StrapPlacement`, `PlacementInterval`,
  `PlacementChange`, pure `PlacementIntervals` folding (mirrors the RPC), and
  `WearStateSpans` (half-open WRIST on/off reconstruction for eligibility flags).
- **Phone** `Strand/Data/PlacementStore.swift` (new): GRDB persistence in the SAME SQLite
  database as the app store (`store.registryWriter`, `DeviceRegistryStore` house pattern;
  tables `placementInterval` + `placementChange`, created idempotently). `setCurrent` folds the
  declaration locally and journals a replay row in one transaction — a change works fully
  offline and keeps its original effective time. `pendingChanges`/`markSynced`/`replaceIntervals`
  drive sync.
- **Settings** `Strand/Screens/SettingsView.swift` (placement section only): "Wear placement"
  row in the Device group → picker (Wrist/Bicep/Other/Unknown); picking saves effective-now
  (offline-safe) and best-effort uploads the journal.
- **Sync** (`PlacementCloudSync` in `PlacementStore.swift`): the SAME authenticated route
  pattern as `CoachAPI`/`ServerScoreRepository` — `Authorization: Bearer <installation
  uploadToken>` + `x-noop-fleet-token`, host derived from the push receiver URL. Pushes pending
  changes in recorded order; a failure leaves rows unsynced (retried, never dropped).
  **INTEGRATION POINT (parent):** the edge route does not exist yet — a `placement` route on
  the `scores` edge function (or a new function) must resolve the installation identity and call
  `set_placement_interval(p_owner=<resolved user>, p_placement, p_effective_start,
  p_device, p_source='user')`; `GET` returns `{ intervals: [...] }` for reconciliation. The
  wire contract is documented in `PlacementCloudSync` doc comments.

### 2. Five-minute window eligibility (findings item 6; spec G4 table) — DONE (app model)

`Strand/Push/IntradaySeries.swift` (app-side only; `IntradaySeriesStore.swift` untouched):
- `PlacementEligibility` (wrist/bicep/other/unknown) and `WearEligibility`
  (worn/off_body/unknown) — UNKNOWN is first-class.
- `IntradayEligibility` + pure `flag(windowStart:windowEnd:placementIntervals:wearEvents:)`:
  placement from placement intervals intersecting the window; wear from persisted WRIST
  events; `mixed` true when placement or wear changes within the window; a mixed window carries
  `.unknown` for the changing dimension (no guessed stable label).
- `IntradaySeriesPoint` gains ADDITIVE optional fields `placement`/`wear`/`mixed` parsed from
  wire rows 5..7; legacy 5-column rows parse with nil flags (existing readers ignore the new
  fields).

### 3. HART wear wiring (findings item 5) — DONE

`Tools/CloudWorker/Sources/frwhoop-worker/ActivityLane.swift`:
- New pure `wearIntervals(fromEvents:from:to:)` reconstructs half-open `WearInterval`s
  (on/off) from WRIST_ON/OFF rows — deterministic, duplicate/out-of-order safe, unknown where
  no event covers, pre-window events excluded, open tail extends to day end.
- New `loadWearEvents` reads `noop_events` WRIST rows for the day.
- `activityDocument(windows:...)` gained `wearIntervals: [WearInterval] = []` (default keeps
  `DayScoring.attachActivityContext` unchanged) and passes them into the shared
  `ActivityContextPolicy.buildEpochs` fold, so published epochs carry an EVIDENCED `wear_state`
  (unknown where no event covers). Quiet IMU is still never on-wrist evidence.
- Tests: `Tools/CloudWorker/Tests/frwhoop-workerTests/ActivityLaneWearTests.swift` (new).

### 3b. P2-2 concurrency fix (audit-g5g6-isolation) — DONE

The original `set_placement_interval` had no advisory lock: two concurrent same-owner declarations
(READ COMMITTED, fresh state) could both compute `next_start = NULL` and leave two overlapping OPEN
intervals — a per-concurrency violation of the G4 non-overlap contract that the single-session SQL
test could not see. Fix in `supabase/migrations/20261003231000_placement_concurrency_lock.sql`
(new, my P2 range `20261003231000-20261003231999`):
- `create or replace` of `set_placement_interval` with identical signature, guards
  (`cross_user_caller`, `device_owner_mismatch`, input validation), search_path and grants;
- `perform pg_advisory_xact_lock(hashtextextended('placement:' || p_owner::text || ':' ||
  coalesce(p_device::text, 'user'), 0))` taken FIRST, before the interval computation + writes
  (mirrors the `publish_metric_series_v1` advisory-lock pattern). The nil-sentinel `'user'` keeps
  user-level and device-scoped declarations on disjoint locks because their interval sets are
  disjoint. The xact lock serializes declarations so the later one sees the earlier one's
  committed rows.

### 3c. Re-audit round 2 (audit-g34-g7-context) — F2/F3/F4/F5/F6/F7

- **F2 (P2) — consumer surface.** `Strand/Screens/IntradaySeriesSection.swift` (added to
  ownership) now renders a one-line per-metric context annotation on the "Through the day" card:
  `IntradaySeriesContextBuilder.summarize` (in `IntradaySeries.swift`) aggregates the visible
  window's points (server-published flags win per point; otherwise local derivation) into honest
  lines — "Mixed placement in this window" / "Wrist" / "Bicep" / "Other", "Wear changed in this
  window" / "Worn" / "Off body" / "Wear varies" / "Wear unknown", plus contact. It shows only when
  there is something honest to say, per metric, never a guessed whole-window label. Worker-side
  rows 5..7 publishing stays a documented follow-up (worker files untouched).
- **F3 (P3) — partial-window coverage.** `IntradayEligibility` gained per-dimension
  `placementMixed`/`wearMixed` (with `mixed` = OR, kept for wire compat). `flag()` now labels a
  window mixed when evidence only PARTIALLY covers it (a leading/trailing gap inside the window is
  an UNKNOWN transition). The consumer's `summarize` reconstructs wear spans over the WHOLE range
  (an event before a bucket covers it until the next event), so sparse WRIST events do not
  fabricate "unknown", and a bucket with a span boundary inside it is `.mixed` not a guessed state.
- **F4 (P2) — contact consumer.** `standardHRContacts` (`WhoopStore.Reads.swift:84`) is
  production-readable (public async store method over the persisted event table). Exposed in the
  same context surface via a new `ContactEligibility` (good/poor/unsupported/unknown) mapped from
  `StandardHRContact` raw values; the line shows only when a transition covers the window. WHOOP
  has no STANDARD_HR_CONTACT stream, so the line is omitted there (honest). NO metric formula is
  re-gated (exposure only, per spec).
- **F5 (P3) — reconcile caller.** `PlacementCloudSync.reconcile()` now has production callers at
  the natural cadence: `SettingsView.loadCurrentPlacement()` (Settings appear) and
  `PlacementEditorView.save()` (after pushPending). Best-effort and non-blocking; `reconcile()`
  self-skips while local changes are unsynced. An AppModel-level foreground hook remains a
  follow-up (AppModel is not in this workstream's ownership).
- **F6 (P3) — same-start replace drops p_effective_end.** The RPC DOES take `p_effective_end`.
  New migration `20261003231500_placement_same_start_effective_end.sql` recreates
  `set_placement_interval` so a same-start replacement honors an explicit end (capped at the next
  interval's start), and a no-end re-declaration keeps the existing end. New test
  `placement_effective_end_test.ts`.
- **F7 (P3) — equal-ts tie order.** `WearStateSpans.reconstruct` (Strand) and
  `ActivityLane.wearIntervals` (worker) now sort WRIST_OFF before WRIST_ON at equal timestamps
  (deterministic, matches `AnalyticsEngine.offWristIntervals`); `loadWearEvents` SQL tie order is
  `ts, kind`. Test added.

### 4. Dead schema (findings item 3) — DOCUMENTED, no schema change

`sessions.off_wrist_min` / `scorability.offWristDurationMin` / `ingest_gaps` off-wrist kinds
have zero writers in this tree (verified in the audit). Recommendation:
- `repair-attest`'s attestation work is the natural home for `sessions.off_wrist_min` /
  `scorability.offWristDurationMin`: the worker's scoring pass already computes off-wrist
  fractions (`SleepStager` fractional filter); populating these columns from the accepted
  session's WRIST intervals would give the columns a real writer and is consistent with the
  attestation envelope.
- `ingest_gaps` "off_wrist"/"wrist_off"/"charging" kinds: propose DROPPING (or formally
  advertising as unsupported) unless the ingestion-verification surface (owner: repair-diag or
  the parent) intends a real gap writer; no code in this tree writes them.
No schema change made here (out of scope / coordinated with repair-attest).

### 5. R22 `wear_detect_bias` override (findings item 7) — DOCUMENTED, no code change

`wear_detect_bias` is one of the sixteen R22 feature-flag keys the experimental deep-data
sequence may write, gated behind `PuffinExperiment.deepDataEnabled`
(`Packages/WhoopProtocol/.../Whoop5Config.swift:58-74`, `R22Disable.swift`), default OFF.
Per spec [N2]: a forced-worn mode invalidates wear assertions unless explicitly accounted for.
Recommendation: treat any session produced while the experimental deep-data sequence is enabled
(and `wear_detect_bias` may have been written) as carrying an unqualified wear context — the
placement/wear eligibility flags must then stay UNKNOWN, and the `wear_detect_bias` write should
be surfaced on the diagnostics surface before wear assertions are trusted. No code change in
this workstream; `sigproc_wear_detect` remains unconditionally refused
(`DeviceConfigWriteGate.swift:100-106`).

## Contract decisions applied

- C1: new migrations only, in range `20261003210000-20261003215999`; one transaction; RLS
  owner-scoped; security definer with `set search_path = public`; column comments; additive.
  No `supabase db push`; local-PG harness only (`EDGE_TEST_ARTIFACTS=/tmp/net`).
- C2: half-open `[start, end)` everywhere (placements and wear spans); local calendar day
  authority untouched (this workstream adds no day logic).
- C3: placement rows are owner-scoped at write; the RPC guards `cross_user_caller`; the phone
  journal never retags rows to another owner.
- C4: `cross_user_caller` / `device_owner_mismatch` propagate as server codes.
- C5: N/A (no outbox changes here).
- C8: only owned files touched; no commits; working tree left dirty.

## Tests run

- `deno test --allow-all tests/placement_intervals_sql_test.ts`
  (`EDGE_TEST_ARTIFACTS=/tmp/net`) → **1 test, 9 steps, all pass**: schema/half-open contract,
  RLS owner isolation, cross_user_caller, device-ownership validation, invalid inputs, first
  declaration open-ended, correction closes + revision bump + no double-cover, same-start
  replace, future-dated cap + no overlap.
- `deno test --allow-all tests/placement_concurrent_intervals_test.ts` (NEW; applies all
  three migrations) → **1 test, 5 steps, all pass**: (1) lock present in the recreated RPC with
  the nil-sentinel key and unchanged guards; (2) two concurrent same-owner declarations (real
  parallel psql sessions via `Promise.all`) fold to exactly two non-overlapping intervals with
  one open tail; (3) a 5-way concurrent burst keeps the contiguous `[T1,T2),…,[T5,∞)` chain with
  zero overlap; (4) a held-lock session blocks a second declaration until the first commits
  (wall-time proof, the lock truly serializes); (5) user-level NULL-device declarations serialize
  on their own lock.
- `deno test --allow-all tests/placement_effective_end_test.ts` (NEW, F6) → **1 test, 4 steps,
  all pass**: same-start replace preserves an explicit end; caps it at the next interval; a
  no-end re-declaration keeps the existing end; sequential semantics + no-overlap still hold with
  all three migrations.
- Round-2 macOS: `PlacementTests` → **32 tests, 0 failures** (added context-surface, F3, F7
  tests). Full `StrandTests` suite → **2496 tests, 2 skipped, 3 failures, all PRE-EXISTING**:
  `IntradayWordingAndCoachTests` (90 s age boundary, verified failing at HEAD) +
  `SkinTempAbsoluteDisplayTests` + `SleepCarriedStampTests` (documented Pacific caption). The
  `TestBundleRobustnessTests` ambient-state failure seen in one run did not reproduce on rerun.
  Full worker suite (incl. F7 tie-break change) → **247 tests, 6 skipped, 0 failures**.
- `Tools/CloudWorker`: `swift test` (CPATH/PKG_CONFIG_PATH/LIBRARY_PATH for libpq) →
  **239 tests, 6 skipped, 2 failures** — both failures are `repair-attest`'s in-flight
  `DayAttestationTests`/`DayClosureTests` (pre-existing parallel-worker state, unrelated to this
  change: day-bounds/attestation, no ActivityLane reference). My `ActivityLaneWearTests`
  (5 tests) pass.
- `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination platform=macOS
  -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests/PlacementTests` → **21 tests, 0
  failures**. (The shared tree was briefly blocked by sibling in-flight edits to
  `MonitorView.swift`/`Profile.swift`; my files compiled cleanly throughout, and the standalone
  check package `swift test` (8/8) verified the same placement logic before the app target
  compiled.)
- Full macOS `StrandTests` suite → **2473 tests, 2 skipped, 3 failures, all PRE-EXISTING**:
  `SkinTempAbsoluteDisplayTests` + `SleepCarriedStampTests` (documented Pacific-time caption
  failures) and `IntradayWordingAndCoachTests/testMinuteBucketsAreDescribedAsMinuteBuckets`
  (90-second age boundary: `now` = latest-end + 90 and `age` returns "1 min ago" at exactly 90 s —
  verified failing at clean HEAD `4c85df9a` in a detached worktree; unrelated to this change).

## Gaps / NOT VERIFIED

- **Edge route for placement sync does not exist** (supabase/functions not in my ownership).
  The client (`PlacementCloudSync`) follows the standard authenticated route pattern and is
  unit-tested with a URLProtocol stub; the parent must wire a `placement` route to
  `set_placement_interval` for end-to-end sync. Offline behavior is complete without it.
- The server does not yet PUBLISH per-bucket placement/wear flags in `server_metric_series`
  (the worker-side `IntradaySeries.swift` is not in this workstream's ownership); the app model
  and local-derivation helper are in place, and the wire fields are additive when a future pass
  publishes them.
- Migration verified on local Postgres 18.3 + PostgREST 16.2 only; not applied to any shared
  database (per contract).
- Physical-device acceptance (T15–T20) is out of scope (no hardware); command-84 never
  produces placement certainty (unchanged).
