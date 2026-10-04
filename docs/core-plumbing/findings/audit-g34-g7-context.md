# Independent audit — G3/G4/G7 context repairs (audit-g34-g7-context)

Auditor: `audit-g34-g7-context` (independent; authored no changes in scope).
Date: 2026-10-03. Tree: `nara-core-plumbing`, branch `audit/core-plumbing-20261003`.
Scope: spec §5 (G3), §6 (G4), §9 (G7) + acceptance T15–T20, T29.
Changed files under audit:
`supabase/migrations/20261003210000_placement_intervals.sql`,
`Strand/Data/Placement.swift`, `Strand/Data/PlacementStore.swift`,
`Strand/Screens/SettingsView.swift` (placement section), `Strand/Push/IntradaySeries.swift`,
`Tools/CloudWorker/Sources/frwhoop-worker/ActivityLane.swift` (wear wiring),
`supabase/functions/_shared/serverScores.ts` (placement + diagnostics routes),
`supabase/migrations/20261003220000_server_pipeline_diagnostics_extended.sql`,
`Strand/Screens/MonitorView.swift`.

Method: read the migrations/code, traced every wire path, and reproduced the one suspected
race. No code changes, no commits. Targeted tests all re-run by this auditor.

## Tests re-run (all PASS)

- `placement_intervals_sql_test.ts` — 1 test, 9 steps, ok (schema/half-open, RLS owner
  isolation, cross_user_caller, device_owner_mismatch, invalid inputs, correction + revision
  + no double-cover, same-start replace, future-dated cap + no overlap).
- `placement_route_test.ts` — ok (owner resolution, correction flow, device-scoped
  resolution, invalid 400, cross-owner 409/403, GET external-device-id contract).
- `pipeline_diagnostics_test.ts` — ok (schema_version 2 fields, owner/device mismatch
  reject, honest not_measured for empty owner).
- `reconcile_quarantine_test.ts` — 2 ok (quarantined rows skipped; not miscounted orphans).
- `ActivityLaneWearTests` (worker swift) — 5 ok.
- `PlacementTests` (macOS, xcodebuild) — 21 ok.

## Verdicts per challenge

### C1. Placement intervals (G4) — PARTIAL / P2

- Half-open semantics at every edge, sequentially: PASS. Correction closes the strictly
  containing interval at the declaration time (migration 20261003210000:88-94); same-start
  declaration replaces in place (:96-108); future-dated cap (:112-119) never overwrites a
  later interval; the SQL test pins no-double-cover and no-overlap for sequential calls.
- **F1 (P2, reproduced) — no concurrency guard: two concurrent declarations in the same
  scope produce OVERLAPPING open intervals.** `set_placement_interval` has no row lock and
  no exclusion constraint. Under READ COMMITTED, two parallel same-scope declarations at
  T1<T2 both miss each other (step-1 UPDATE sees no committed row; step-3 `min(start)` sees
  nothing) and both insert open intervals. Auditor reproduced with two concurrent RPC calls:
  result was `[T1,∞) wrist` + `[T2,∞) wrist`, overlap-pairs = 2 (sequential semantics would
  have closed [T1,∞) at T2). Violates the migration's own non-overlap invariant (spec §6
  corrections; the `no overlap` SQL test only covers sequential calls). Minimal repair: at
  the top of the RPC take `select ... for update` on the scope's candidate rows (or a
  `pg_advisory_xact_lock` keyed on owner+device scope) before reading/inserting; the phone
  serializes its own pushes, so the trigger is multi-device/multi-client sync.
- RLS + device-owner guards: PASS. `placement_select_own` policy limits reads; `authenticated`
  has no table write grant (RPC is the only write path); RPC guards `cross_user_caller`
  (:68) and `device_owner_mismatch` (:84). Edge route resolves owner from identity only
  (serverScores.ts) and maps the device owner-scoped via `findNoopDevice`
  (`_shared/devices.ts:28-46`, filters `user_id`); a device owned by another user → 409
  `device_registration_pending` (route test step 5) and the RPC independently raises
  `device_owner_mismatch` (SQL test). Double guard confirmed.
- Reconcile partial pull: PASS by code read — `replaceIntervals` only deletes the groups
  present in the pull (`PlacementStore.swift:293-297`); a device absent from the server
  pull keeps its local model. **F5 (P3) — but `reconcile()` has NO production caller**
  (`PlacementStore.swift:276`; only PlacementTests exercise it). The app only pushes
  (`SettingsView.save`); multi-device pull, server-side corrections coming back, and the
  future-dated-cap scenario (only reachable via pull) never happen today. Note: `recordedAt`
  is decoded from `effective_start` on the pull path (`decodeServerInterval`) — recorded_at
  is not carried on the wire (minor).
- User-level vs device-scoped coexistence: deliberate and pinned (route-test comment): the
  RPC's scope predicate means a user-level open interval and a device-scoped open interval
  legitimately coexist. Phone-side `activePlacement`/`flag` only consult the device scope,
  so a user-level declaration would be invisible to a device's flags — dormant (the app
  always declares device-scoped; `SettingsView` passes `model.repo.deviceId`). P3 note.
- **F6 (P3)** — same-start replace (migration step 2, :96-108) silently drops an explicitly
  passed `p_effective_end` (the UPDATE never sets effective_end). Unreachable through the
  current route (POST never sends effective_end), but the RPC signature accepts it.

### C2. Offline effective-time — PASS

`PlacementChange` keeps the original `effectiveStart`; `pushPending` replays
`change.effectiveStart` verbatim (PlacementStore.swift push loop); the RPC stores
`p_effective_start` (receive time only in `recorded_at`). A correction made offline for a
PAST window therefore closes the overlapping interval server-side at the PAST time, not at
sync time (step 1 predicate is time-based). Verified by code trace + route test correction
flow. Replay order is deterministic (recordedAt, then effectiveStart, then id).

### C3. Five-minute eligibility (app-side IntradaySeries) — PARTIAL / P2

- UNKNOWN when no interval/event covers: PASS. Legacy wire rows parse nil (rows 5..7
  optional, `IntradaySeries.swift` parser; test `testPointIgnoresLegacyRowsWithoutEligibility`).
  Mixed window → changing dimension `.unknown` (pinned by tests).
- **F2 (P2) — the flags are DEAD PAYLOAD.** `IntradayEligibility.flag` is called only from
  tests; no metric view, Today/Sleep/IntradaySeriesSection, or any consumer gates on
  `point.placement/wear/mixed` (grep across Strand/StrandiOS: zero). The server also never
  publishes rows 5..7: worker `IntradaySeries.swift` and the `/series` route emit no
  placement/wear/mixed fields. So T19/G4's "expose per-metric eligibility" is unmet end to
  end. Documented as a follow-up (audit.md row 18, rollout.md), but the challenge asked to
  confirm: it is still a gap.
- **F3 (P3) — partial-window unknown coverage is silently labeled.** `WearStateSpans.reconstruct`
  builds spans only from events inside the window; the flag labels the window by the distinct
  span states. A window whose first N seconds have no event (e.g., WRIST_ON at the window's
  last second) is labeled `.worn` with `mixed=false` — the un-evidenced sub-portion is not
  surfaced (pinned by `testEligibilityWearStates`). Boundary over-claim in 5-min buckets;
  spec says gaps are UNKNOWN.

### C4. HART wear wiring (ActivityLane) — PASS with P3 caveats

- Odd count (OFF without ON): open tail extends to `to` — the whole remainder of the day is
  off_wrist from a single direct WRIST_OFF assertion (pinned by
  `testWearIntervalsUnknownGapsAndOpenTail`). Event-backed, but no staleness/age expiry —
  same pattern the baseline audit already documented for the sleep stager; not introduced
  here. **F7 (P3)** — tie-order at equal timestamps is unspecified: Swift `sorted` is not
  contractually stable and `loadWearEvents`' SQL tie order is arbitrary, so an ON+OFF pair
  at the same second can flip the tail state depending on order (dedupe PK allows both rows).
- Out-of-order: sorted. Events outside the day: excluded by `[from,to)` filters (worker SQL
  `ts >= dayStart and ts < dayEnd`); cross-midnight intervals clipped to each day; day start
  before the first in-day event stays UNKNOWN (no span) — conservative, PASS.
- Empty = unknown, never off-body: PASS (`[]` → policy `.unknown`; quiet IMU never on-wrist).
- Wire trace to the published document: VERIFIED. `wearIntervals` → shared
  `ActivityContextPolicy.buildEpochs` (`ActivityContextPolicy.swift:76+`, `bestAnnotation`
  picks max-overlap, nil → unknown) → `ActivityEpoch.wear` → C10 JSON key `"w"`
  (`ActivityContextTypes.swift` CodingKeys) → `publish_activity_context_v2` stores
  `wear_state` from `e->>'w'` (`20261003120000_activity_context.sql`, CHECK
  on_wrist/off_wrist/unknown) → `DayScoring.attachActivityContext` reads it back into the
  snapshot `daily.activity_context`. Default `wearIntervals: []` keeps
  `DayScoring.attachActivityContext` behavior unchanged (DayScoring untouched by placement).

### C5. Diagnostics v2 — PASS; MonitorView NOT VERIFIED

- Fields honest: PASS. `not_measured`/`not_observed` used throughout; empty enrolled owner
  returns all-not_measured (pinned). No `hrt`-style fabrication.
- Owner-scoping / no identity leak: PASS by code read. RPC is `security invoker` +
  service_role-only, re-checks owner/installation/device; payload carries no owner/device
  UUIDs (correlation_id is sha256; streams/queue/projection/archive/work select no
  user/device columns). The pre-existing `server_pipeline_sql_test.ts` asserts the payload
  contains neither owner userId nor deviceId (still in the suite). NOTE: the NEW
  `pipeline_diagnostics_test.ts` does not itself assert the no-leak property (minor test gap;
  covered by the pre-existing test).
- Day bounds/zone: `scoring_day_segments` is ALWAYS non-empty for an enrolled owner (the
  profiles trigger seeds a `-infinity` timezone-history row — verified by test). The
  `zone_source` fallback mislabel (migration :92-95 labels a feature-derived zone as
  `scoring_day_segments`) is therefore UNREACHABLE in production — checked and disproved,
  not a finding.
- `largest_gap` for empty streams: sane (`status=not_measured`, reason `no signal windows`).
  Gap measured only BETWEEN windows, not from day start — documented, acceptable.
- **NV1 — MonitorView is compile-only.** No StrandTests reference MonitorView/
  PipelineDiagnostics; blocked check: a UI test rendering schema_version 2 payloads
  (day-bounds card incl. empty segments, stream not_observed, blockers list, loading/error
  states, refresh) does not exist. Also note `surface()` defaults a missing zonePolicy to
  `"local_calendar_midnight"` rather than `not_measured` (minor honesty nit, untested).

### C6. G3 residuals — PASS/confirmed

- Contact-quality consumer gap: **CONFIRMED STILL OPEN (P2, pre-existing, documented).**
  `STANDARD_HR_CONTACT` is persisted (`StandardHRMapping.swift:16`) and readable
  (`Reads.swift:84`), but `standardHRContacts` has no production caller (only
  StandardHRMappingTests). No gate uses contact quality anywhere.
- Off-body fabrication: PASS — no NEW path. The only off_body producers in the new code are
  direct WRIST_OFF events (`IntradaySeries.swift:147`, ActivityLane fold); the open tail is
  event-backed. No HR-gap/IMU/connection/battery proxy was added.
- R22 override: PASS — the placement/wear work adds no command probing; grep of the changed
  files finds only the pre-existing `/sleep-overrides` route. `wear_detect_bias` remains
  gated experimental documentation (unchanged).

### C7. T20 (placeholder/status-byte non-certainty) — PASS

No device-status/command-84 parsing anywhere in the changed files (grep: none). Placement is
manual-only (Settings picker → PlacementStore → RPC). App never auto-derives placement from
device bytes.

## Findings summary

| # | Sev | Location | Finding |
| --- | --- | --- | --- |
| F1 | P2 | 20261003210000_placement_intervals.sql:88-119 | Concurrent same-scope declarations can create overlapping open intervals (no lock/exclusion); REPRODUCED (2 overlapping rows). Violates §6 non-overlap invariant. Fix: FOR UPDATE / advisory lock in the RPC. |
| F2 | P2 | IntradaySeries.swift:111-151; worker IntradaySeries.swift; /series route | Five-minute eligibility flags are dead payload — no consumer gates on them and the server never publishes rows 5..7. §6 "expose per-metric eligibility" unmet (documented follow-up). |
| F3 | P3 | IntradaySeries.swift:138-151 | Partial-window unknown coverage silently labeled by the only state present (e.g., WRIST_ON at window end → whole window `.worn`); un-evidenced sub-portion not surfaced. |
| F4 | P2 | WhoopStore Reads.swift:84 / StandardHRMapping.swift:16 | Contact-quality consumer gap still open (pre-existing, documented): STANDARD_HR_CONTACT persisted but never consumed. |
| F5 | P3 | PlacementStore.swift:276-306 | `reconcile()` (server pull + byDevice replace) has no production caller; multi-device pull and server-side corrections never reach the phone today. |
| F6 | P3 | 20261003210000_placement_intervals.sql:96-108 | Same-start replace silently drops an explicit `p_effective_end` (unreachable via current route). |
| F7 | P3 | Placement.swift:181-186 / ActivityLane.swift:569-575 | Tie-order at equal WRIST event timestamps is unspecified (non-stable Swift sort, arbitrary SQL tie order); an ON+OFF pair at the same second can flip the tail state. |

## NOT VERIFIED (blocked checks)

- NV1: MonitorView UI — no StrandTests for MonitorView/PipelineDiagnostics rendering
  (compile-only; blocked check named above).
- NV2: `PlacementCloudSync.reconcile()` network path — no test and no production caller;
  byDevice semantics verified by code read only.
- Physical/device acceptance T15-T20 (wear captures, command-84 malformed responses) —
  no hardware; out of scope for this audit.
- Production/staging: migrations not applied to any shared DB (local-PG harness only);
  worker redeploy required before ActivityLane/attestation changes reach the droplet.

## Verdict per challenge (compact)

1. Placement intervals: PARTIAL/P2 — sequential semantics PASS, RLS+device guards PASS,
   reconcile partial-pull PASS by code read; F1 concurrency race (P2, reproduced),
   F5/F6 (P3).
2. Offline effective-time: PASS (original effective_start preserved; past-window corrections
   close server-side at the past time).
3. Five-minute eligibility: PARTIAL/P2 — UNKNOWN/mixed/legacy-nil semantics PASS; F2 dead
   payload (P2), F3 boundary over-claim (P3).
4. HART wear wiring: PASS with F7 (P3 tie-order); wear_state wire trace verified end to end;
   odd-count open tail is event-backed (documented pattern).
5. Diagnostics v2: PASS (honest fields, owner-scoping, no identity leak); MonitorView
   NOT VERIFIED (NV1).
6. G3 residuals: contact consumer gap still open (F4, P2); no new off-body fabrication; no
   new command probing (PASS).
7. T20: PASS — no device-status parsing in new code.

## Re-audit round (2026-10-03, fixes in the CURRENT working tree)

Re-verified each finding's fix by reading the current code/migrations, re-running my own
reproduction, and running the targeted tests. All targeted tests pass.

### F1 (P2) — set_placement_interval concurrency — PASS

- Fix: `supabase/migrations/20261003231000_placement_concurrency_lock.sql` —
  `perform pg_advisory_xact_lock(hashtextextended('placement:'||p_owner||':'||coalesce(p_device,'user'),0))`
  taken after guards, before any interval computation/write. User-level (NULL device) and
  device-scoped scopes lock disjoint keys; the key embeds the caller's own owner (guarded by
  cross_user_caller), so a caller cannot lock another owner's scope; single lock per
  transaction → no deadlock cycle. `20261003231500` recreates the same function with the lock
  retained.
- Test: `placement_concurrent_intervals_test.ts` (5 steps) — lock present on recreated RPC;
  2-way concurrent same-owner pair → exactly one open, earlier closed at later start, 0
  overlap; 5-way burst → contiguous chain [T1,T2),…,[Tn,∞), no overlap; held-lock
  serialization proof (blocked call ≥ ~1 s); user-level NULL-device pair also serialized.
  PASS (ran: 2 passed / 9 steps / 0 failed).
- Independent reproduction (my original race script, run against the CURRENT 3-migration
  chain): `wrist|00:00|01:00` + `wrist|01:00|infinity`, overlap-pairs = 0 (was 2 pre-fix).
  PASS.
- New-issue scan: lock is owner-scoped, short-lived (RPC is a few statements), no other
  function shares the key — no cross-owner DoS, no deadlock cycle, no behavior change for
  sequential calls (original placement_intervals_sql_test + placement_route_test still pass).

### F6 (P3) — same-start replace drops p_effective_end — PASS

- Fix: `20261003231500_placement_same_start_effective_end.sql` — `next_start` computed once
  before the same-start branch (verified semantics-preserving: step 1/2 never mutate
  `effective_start`, so the value is identical to the old placement); same-start UPDATE now
  honors `p_effective_end` capped at `next_start`; a same-start re-declaration WITHOUT an end
  keeps the existing end (does not silently widen/shrink).
- Test: `placement_effective_end_test.ts` (4 steps) — explicit end preserved; capped at next
  interval when late; existing end kept when no end; sequential semantics + non-overlap hold
  with all three migrations. PASS (ran: 2 passed / 9 steps / 0 failed, incl. this file).

### F2 (P2) — dead eligibility payload — PASS (app-side consumer) with documented remaining risk

- Fix: `Strand/Screens/IntradaySeriesSection.swift` — the 'Through the day' card now renders
  a per-metric context annotation line (`eligibilityLine`) via the new
  `IntradaySeriesContextBuilder.summarize` (`Strand/Push/IntradaySeries.swift`):
  server-published `point.placement/wear/mixed` win per point; otherwise placement is derived
  locally via `IntradayEligibility.flag` (F3-aware) and wear from RANGE-wide WRIST spans
  (`wearState(at:to:spans:)` — leading-gap/trailing-transition inside a bucket → mixed).
  `IntradayEligibility` gained per-dimension `placementMixed`/`wearMixed` (and `mixed` kept
  for wire/reader compatibility); `ContactEligibility` added.
- Evidence load: `loadEligibilityEvidence(dayOffset)` in `.task(id: dayOffset)` reads local
  placement intervals, WRIST events (limit 5000) and `standardHRContacts` (limit 2000) for
  the visible range, best-effort/non-blocking; failure leaves the line absent (never a
  guessed state).
- Tests: 9 new context tests (empty; wear unknown; worn+wrist; mixed placement; wear varies;
  wear changed; contact good/poor/unsupported/none; server flags win; server mixed flags
  conservative). PlacementTests 32/32 PASS (ran).
- Verdict: the app-side T19/G4 "expose per-metric eligibility" requirement is now MET in
  scope (per-metric honest annotation, mixed windows say mixed, UNKNOWN stays unlabeled).
  REMAINING RISK (documented follow-up, unchanged): worker-side `IntradaySeries` rows 5..7
  and server `/series` publishing are still NOT produced — server-published flags never
  arrive today, so the local fallback is what runs; a future server-side consumer still has
  no flags. Not a regression; flagged as residual.

### F3 (P3) — partial-window unknown coverage silently labeled — PASS

- Fix in `IntradayEligibility.flag`: placement now checks `coverageComplete(...)` (spans must
  tile `[from,to)` with no gap; empty covers nothing; overlapping/contiguous merge); wear
  checks `spans.first?.start == windowStartSec` (reconstruct spans are contiguous from the
  first event, so the only possible gap is leading). Any un-evidenced sub-portion → the
  dimension is `.unknown` with `*Mixed = true`. The context builder's `wearState` also treats
  a leading gap/trailing transition inside a bucket as mixed.
- Tests: `testEligibilityPlacementPartialCoverageIsMixed` (leading AND trailing partial
  coverage → unknown + placementMixed), updated `testEligibilityWearStates` (event exactly at
  window start → worn/offBody no-mixed; event at start+299 → unknown + wearMixed).
  PASS (32/32).

### F4 (P2) — contact-quality consumer gap — PASS (display surface, no re-gating)

- Fix: `loadEligibilityEvidence` now calls `store.standardHRContacts(deviceId:from:to:limit:)`
  — the previously test-only reader is production-readable. `ContactEligibility` maps the
  persisted tri-state (`supported_detected`→good, `supported_not_detected`→poor,
  `unsupported`→unsupported); `contactLine` shows the LAST transition at-or-before the
  window end (state model, `.unknown` filtered). WHOOP straps carry no STANDARD_HR_CONTACT
  stream → contact line honestly omitted (no fabrication).
- No formula/consumer re-gating introduced (display annotation only — no metric eligibility
  gate changed). No new fabrication path.
- Minor residual (note, not a FAIL): the contact line is a last-state model with no
  age/staleness exposure; a transition hours old still labels the window. Display-only, low
  materiality, consistent with the pre-existing sleep-stager pattern.

### F5 (P3) — reconcile() no production caller — PASS

- Fix: two production callers in `SettingsView.swift` — (1) `loadCurrentPlacement` calls
  `reconcilePlacement(placementStore)` at the Settings-appear cadence (:71-80), and (2) the
  placement editor's `save` calls `sync.reconcile()` right after `pushPending()` (:1338).
  Both best-effort and guarded by `CloudPushSettings.isEnabled` + identity; `reconcile()`
  self-skips while any local change is unsynced (offline declaration never overwritten).
- Remaining risk (documented follow-up): no AppModel-level (launch/foreground) hook yet, so
  multi-device server corrections reach the phone only when Settings appears or the editor
  saves; and the byDevice network pull path still has no dedicated unit test (the existing
  reconcile test exercises `replaceIntervals` directly). Not a regression.

### F7 (P3) — tie-order at equal timestamps — PASS

- Fix: deterministic tie-break in BOTH folds — `WearStateSpans.reconstruct`
  (`Strand/Data/Placement.swift`) and `ActivityLane.wearIntervals`
  (`ActivityLane.swift`): at equal ts, `WRIST_OFF` sorts before `WRIST_ON` (secondary
  comparator key, since Swift's sort is not contractually stable); the worker's
  `loadWearEvents` SQL adds `order by ts asc, kind asc` (`WRIST_OFF...` < `WRIST_ON...`
  lexicographically). Both folds agree, and match `AnalyticsEngine.offWristIntervals`
  (OFF opens, ON closes, zero-length skipped) → "on from then".
- Test: `testWearReconstructionTieBreakOffBeforeOnAtEqualTs` (passes the ON-first input
  order and pins the deterministic result). PASS.
- Minor test gap: the worker-side tie-break is code-verified but not directly test-pinned
  (ActivityLaneWearTests unchanged at 5 tests; the SQL tie order is DB-bound). Not a
  regression; noted.

### New-issue scan across my audited area

None found. The advisory lock is owner-scoped and short-lived; the F6 `next_start`
reordering is semantics-preserving (step 1/2 never mutate effective_start); the new context
consumer is display-only (no metric re-gating, no new fabrication path — `.unknown`
filtered, WHOOP contact line omitted, mixed windows labelled mixed); the F5 reconcile callers
are best-effort and self-skipping.

### Final re-audit verdicts

| Finding | Verdict | Notes |
| --- | --- | --- |
| F1 concurrency race | PASS | advisory xact lock; reproduction now 0 overlap; 5-step concurrent test |
| F2 dead eligibility payload | PASS (app scope) | 'Through the day' per-metric context line, local fallback; server rows 5..7 + /series publishing still a DOCUMENTED follow-up |
| F3 partial-coverage labeling | PASS | flag() + wearState() mark partial coverage mixed/unknown; pinned |
| F4 contact consumer | PASS | standardHRContacts production-read; honest good/poor/unsupported; WHOOP omits; no re-gating |
| F5 reconcile caller | PASS | Settings-appear + post-push; AppModel-level hook still follow-up |
| F6 same-start p_effective_end | PASS | honored + capped; 4-step test |
| F7 tie-order | PASS | OFF-before-ON in both folds + SQL; phone-side pinned; worker-side not directly pinned |

NOT VERIFIED (unchanged from round 1): MonitorView UI tests (NV1, no new tests added);
`PlacementCloudSync.reconcile()` network-path unit test (NV2 — now production-called, still
no dedicated test); physical T15-T20; migrations not applied to a shared DB.
