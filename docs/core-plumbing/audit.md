# Core plumbing audit (G1-G7)

Date: 2026-10-03. Branch: `audit/core-plumbing-20261003` (base `56809066`, integration/phone-20261003).
Requirements source: [spec.md](spec.md). Full investigation evidence: [findings/](findings/) (one file per workstream + `matrix.md` + `root-deployment-baseline.md`). This document is the audited summary; every verdict below traces to file:line evidence in those files.

## 1. Source baseline and active architecture

- **Authorized checkout**: git worktree `/Volumes/External SSD/Nara Whoop App V2/nara-core-plumbing`, branch `audit/core-plumbing-20261003` from `56809066` — the merge of the 12-commit `feature/activity-context-hart` lane (unpushed HART/activity work, `bae99408`) into the latest noop WIP snapshot (`2dbcca0d`/`c3e30be1`), plus 2 integration commits. The unpushed work is preserved: the `nara-activity` checkout keeps its 11 dirty files untouched; `Whoop-Nara` (separate remote) untouched.
- **Active architecture** (verified from code, not docs): SwiftUI app (Strand/, shared iOS+macOS) -> local SQLite (Packages/WhoopStore) -> journal/outbox upload (Strand/Push, gzip NDJSON or B2 object lane) -> Supabase edge functions (supabase/functions/push|scores|coach|account-deletion|reconcile|ingest-verify|retention-sweep) -> VPS worker (Tools/CloudWorker, frwhoop-worker, DigitalOcean droplet, 5 lanes: scoring/archive/verify/projection[off]/activity[off]) -> published snapshots/series -> app reads back. Same `StrandAnalytics` package links app and worker (parity).
- **Deployment** (read-only ssh evidence, findings/root-deployment-baseline.md): droplet `frwhoop-worker-2` (4 vCPU/8 GB), service active, binary built 2026-10-03 08:02 UTC. **Deployed worker source == `c3e30be1`** (proven by CloudWorker source fingerprint; 11 files — no activity lane). `FRWHOOP_SOURCE_REVISION` env is mislabeled (`a7ea5426`, not in the authorized clone) — do not read deployed revision from it or from heartbeat `source_revision`.
- **Device access**: physical iPhone 16 (paired, devicectl) + Apple Watch Series 10. WHOOP strap physical presence assumed via the phone install; strap-dependent checks marked device-NV until confirmed.

## 2. Requirement verdicts (pre-repair -> post-repair status)

See [findings/matrix.md](findings/matrix.md) for the full G1-G7/T01-T31 table with file:line evidence. Summary of code-verified FAILs found and their repair status (updated as repairs land):

| # | Defect (root-verified) | Spec | Repair owner | Status |
| --- | --- | --- | --- | --- |
| 1 | No day-boundary timer; Today rolls only on data refresh; resume renders stale day | G1/T01/T02 | repair-dayui | REPAIRED (root-verified diff; 11 new tests pass; T01/T02/T03/T04 code paths covered) |
| 2 | Day selection not persisted; no return-to-Today action | G1/T03 | repair-dayui | REPAIRED (persisted offset + clamp + explicit Today buttons; #860 fresh-launch note in decision log) |
| 3 | IntradaySeriesStore live-key write has no generation guard | G1/T04 | repair-dayui | REPAIRED (dayGeneration + dayKeyDidChange; stale write dropped; IntradayStaleResponseTests) |
| 4 | Fixed 86400+offset bucketing; LocalDayWindows unused | G1/T05/T06 | repair-daybucket | REPAIRED (analyzeDay dayWindow param + IntelligenceEngine per-day zone-correct keys/bounds; non-DST byte-identity pinned; DST fixes pinned; StrandAnalytics 2167/0. Worker call-site dayWindow follow-up assigned to repair-attest) |
| 5 | App never writes profiles.timezone | G1/T06 | repair-daybucket | REPAIRED app-side (Profile.timezone persisted/synced, phone is authority, 4 tests). Server persistence gap (coach.ts ignores the field) assigned to repair-diag scope-add 3 |
| 6 | Cloud-off does not stop uploads (consent) | G2 | repair-ble | REPAIRED (setEnabled drives runtime stop/start; journal retained; 2 regressions) |
| 7 | Journal never re-activates after locked launch | G2 | repair-ble | REPAIRED (availability-polling retry task, cancelled on stop; 1 regression) |
| 8 | Journal seal/send lack owner filters | G5/T23 latent | repair-ble | REPAIRED (owner filters + quarantine on mismatch; upload refuses wrong-owner token; receipt bound to batch owner; 3 regressions) |
| 9 | rest.ts masks receiver rejection codes; 3 integration tests red at HEAD | G5/T22 | repair-attest | REPAIRED (root re-ran the 3 formerly-red tests: pass; worker suite exit 0) |
| 10 | physiology_archive_outbox 'retry' violates CHECK | G2 | repair-attest | REPAIRED (migration 20261003201000; claim/release/backoff proven by new integration test) |
| 11 | publish_metric_series_v1 lacks input-revision fence | G2/T31 | repair-attest | REPAIRED (fenced 6-arg form; ScoringLane passes claimed revision; superseded classification) |
| 12 | Projection debt retries forever | G2/T11 | repair-attest | REPAIRED (dead_letter at 16 with reason; operator path documented) |
| 13 | day_completeness attestation dead | G2 4.4 | repair-attest | REPAIRED (publish_day_attestation_v1 fenced; honest not_measured fields; status stays open) |
| 14 | No per-user-zone midnight closure | G2 4.5 | repair-attest | REPAIRED (closure_state + scoring_enqueue_due_day_closure via AT TIME ZONE; throttled worker hook) |
| 15 | Deterministically-unverifiable manifests re-verified once per process forever | G2 4.6 | repair-attest | REPAIRED (durable quarantine columns + RPC; candidateSQL excludes; edge-side workers.ts predicate assigned to repair-diag) |
| 16 | No placement model | G4 | repair-placement | REPAIRED (placement_intervals + RLS + set_placement_interval RPC w/ cross-user guards; PlacementStore offline-first + corrections/revision; Settings UI; 21 tests + 9-step SQL test pass; edge route wired by repair-diag scope-add) |
| 17 | HART fold passes no wear intervals | G3/G7 | repair-placement | REPAIRED (loadWearEvents from noop_events WRIST rows -> wearIntervals into the shared fold; 5 worker tests pass) |
| 18 | Five-minute windows carry no eligibility | G4/G7 | repair-placement | REPAIRED app-side (additive placement/wear/mixed fields, legacy rows parse nil; local derivation ready). Worker-side series flags + server_metric_series exposure = documented follow-up (rollout.md) |
| 19 | Diagnostics surface incomplete; MonitorView placeholder | G7 | repair-diag | REPAIRED (server_pipeline_diagnostics v2: day bounds/zone, streams, coverage, largest gap, v2 queue ages/revs, durable-vs-verified archive, blockers; MonitorView real owner-scoped surface; worker.env.example knobs; capacity harness fail-open + workbook) |

Verified-good (no change): durable acquisition chain (persist-before-death, WAL sync=FULL, acquisition-time owner binding, crash-safe watermarks, no destructive trim), strap ACK separation, archive byte verification (streaming SHA-256, receipt+index atomic), late-data event-time day attribution, snapshot revision fencing, RLS coverage (339/339 definer fns), fail-closed identity, signed URL ownership, steps counter handling, HealthKit arbitration, off-body fabrication discipline, wear event interval determinism, ProjectionLane hot-loop (fixed pre-baseline).

## 3. Unresolved / NOT VERIFIED (blocked checks, by layer)

- **Device**: T01 rollover latency on physical phone; T02 suspended-across-midnight first render; T14 locked-phone/eviction/force-quit/Settings-vs-Control-Center BT; T15-T17 wear/contact physical captures (labelled wear/remove/rewear, loose contact, BT loss); T28 device-level HK delivery.
- **Staging**: T21 live two-phone outage; T24 recovery observability under load; T26 tier report (no staging env exists; capacity-workbook prepared by repair-diag; production is read-only).
- **Deployed**: migration order/grants vs applied schema; realtime schema presence; B2 behavior; the deployed worker still runs `c3e30be1` (activity lane + all repairs absent until rollout); verify-lane bad manifest 6ad53e16 persists until the quarantine migration + worker redeploy.

## 4. Decision log (root decisions)

1. Today rolls at LOCAL CALENDAR MIDNIGHT (spec hierarchy wins over the prior 04:00 logical-day display); sleep stays wake-date-keyed (spec explicitly allows); helpers kept, behavior documented + rollback noted in rollout.md.
2. Timezone authority = phone local IANA zone, synced into profiles.timezone (no fixed reporting zone exists in the product; travel policy = sync-on-change, effective-dated day segments already handled by scoring_day_segments).
3. LocalDayWindows is the canonical day-bounds primitive for app+worker (one package change fixes both; deployed worker rebuild required before server results change — rollout.md).
4. Placement: manual effective-dated `placement_intervals` table (user source only); auto-inference explicitly out of scope; unannotated history stays UNKNOWN.
5. Deterministic digest mismatches get durable quarantine; transient ones stay bounded-retry.
6. Outbox gains 'retry' as a legal status with next_attempt_at backoff (rather than writing 'failed' for retryable releases).
7. rest.ts propagates safe receiver error codes (charset-guarded), fallback unchanged.


## Cross-owner integrations landed after the six repair reports

- Worker `DayScoring.swift` analyzeDay call site passes `dayWindow: LocalDayWindows(timeZone: tz).window(ofDayKey: claim.day)` (repair-attest follow-up; +2 pinning tests; worker suite 245/6/0) — app/worker DST parity restored.
- `coach.ts` persists + echoes `timezone` (validated against pg_timezone_names; null-tolerant echo; phone is authority) (repair-diag scope-add 3; coach_timezone_test).
- `serverScores.ts` gained POST/GET `/scores/placement` (owner resolved from installation identity; set_placement_interval with RPC guards; 400/409 validation) (repair-diag scope-add 2; placement_route_test).
- `workers.ts` reconcileObjects skips quarantined manifests (same predicate as VerificationLane.candidateSQL) (repair-diag scope-add 1; reconcile_quarantine_test).
- App `PlacementCloudSync` (POST/GET <scores-host>/placement, Bearer + fleet header) ↔ server route contract matches (repair-placement + repair-diag).


## Root integration findings (2026-10-03, authoritative runs)

- **Full deno suite** (`EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/`): pre-repair baseline 234 passed / 14 failed / 12 ignored; post-repair 250 passed / 9 failed / 14 ignored. The 4 formerly-red contract tests (intake/scalar/object_verification integration, capacity evidence) are FIXED. One NEW failure introduced by the rest.ts C4 propagation was found by the root and fixed the same day: `installationLifecycle.ts` deferral now requires the marker's own HTTP 409 (a 401/403 marker lookalike previously deferred with 202 after the propagation change; pinned by retained_identity_deferral_test.ts:104 — 14/14 green after the fix; full suite re-run confirms).
- The 9 remaining deno failures are PRE-EXISTING and ENVIRONMENTAL, identical at the pristine baseline 56809066 (root-verified in a detached worktree): android_imu, auxiliary_identity, intake_deadline, object_representation, production_append_compatibility, raw_auth_history_review, swift_auxiliary, swift_identity_replay, swift_imf1 — they require Swift-exported fixtures (e.g. `/tmp/net/aux14-swift/payload.npb1`, 'CloudImuPushSourceTest export') whose exporter (`Tests/ServerFixtureNative`, documented in supabase/functions/tests/README.md) is NOT present in this checkout lineage. Blocked check named: the fixture export step is absent from the authorized tree; NOT VERIFIED, not a code regression.
- **IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets** verified PRE-EXISTING at the pristine baseline (root run at detached 56809066: fails identically; deterministic 90s age-boundary bug). repair-diag's attribution of it to repair-placement's IntradaySeries.swift changes was WRONG — settled by the baseline run.
- TestBundleRobustnessTests failure: machine-environmental (stale `testcentre.active.battery` UserDefaults on this dev Mac), pre-existing.
- **StrandAnalytics** full suite (root run): All tests passed (matches repair-daybucket's 2167/0 report).
- **Swift worker** full suite (root run, after dayWindow follow-up): 245 executed / 6 skipped / 0 failures.


## Device pass (physical iPhone 16, 2026-10-03)

- Build: NOOPiOS Debug (generic/iOS) with the user's gitignored Config secrets — BUILD SUCCEEDED. Installed over the existing com.rahulvijayan.noop install (data preserved; history intact through 2026-09-29).
- App launched on device (process running). Local DB copy shows the Today row for 2026-10-03 populated with today's live values (recovery 21.16 / strain 17.66 / HRV 53.7 / RHR 53 / resp 14.1) — the repaired local-day plumbing functions with real data on the physical device.
- Placement tables (placementInterval/placementChange) are created idempotently on first use — not yet present (the PlacementStore opens on first access; expected).
- UI-level observation (screenshots) is not possible over devicectl; UI wiring is code-verified (tests). Overnight check planned: after local midnight, the dailyMetric table must show a 2026-10-04 row on first app activity (T02-adjacent device evidence; verifiable via DB copy without user action; the INSTALLED build contains the full G1 rollover machinery — the round-3 zone-journal change does not affect rollover).
- Round-3 note: the final round-3 app build SUCCEEDED (xcodebuild) but the device became UNAVAILABLE (disconnected) before the reinstall — the installed on-device build predates round 3 (which only changed Profile zone-journal/IntelligenceEngine internals). Final-build device install + relaunch remains a named pending device check on reconnection.
- NOT VERIFIED on device (named): T01 sub-second rollover latency (needs on-screen observation at midnight); T14 locked-phone/eviction/force-quit/BT-settings matrices; T15-T17 labelled wear/remove/rewear + loose-contact captures (need the strap worn and user labelling); T02 exact resume-before-network ordering (needs instrumented observation); UI pass for the new Today buttons + Settings placement row + Monitor diagnostics screen.


## Independent audit phase (2026-10-03/04)

### audit-g5-g6-isolation (reported)

- 8 challenge areas PASS (migration RLS/definer/grants; placement routes owner-resolution + uniform 409 no-enumeration; diagnostics replacement auth-identical; coach timezone DB-trigger authority; phone owner guards incl. ledger re-seed; capacity honesty; realtime absence; FK-cascade deletion coverage).
- 3 material P2 findings (all source-traced by the auditor, fixes assigned to the file owners, re-audit to follow):
  - P2-1: metric-series fence is per-device while the series table is per-user — a mid-day selected-device switch A->B->A can let a stale pass overwrite a newer series. Fix: user/day-scoped max-revision fence (repair-attest).
  - P2-2: set_placement_interval has no advisory lock — two concurrent fresh-state declarations can leave two overlapping OPEN intervals. Fix: pg_advisory_xact_lock (repair-placement).
  - P2-3: account-deletion freeze does not cover the closure sweep / v2 claim — queued closure work can resurrect a frozen owner's day rows during the deletion window. Fix: retirement filter in the closure sweep (repair-attest).
- NOT VERIFIED by auditor: concurrency fixtures for P2-1/P2-2 races; automated account-deletion test covering new tables (FK-cascade coverage is from SQL reading); deployed migration order/realtime/B2 (deployment-phase).


### audit-g1-day (reported)

- Main wiring PASS: all rollover triggers wired (launch/active/timezone/significant-time/timer; timer cancelled in background, resume recompute covers the miss; no stale-day path in widgets/complications/watch); sleep wake-date keying unchanged; T04 core guard correct; single-zone bucketing parity app=worker=SQL verified; timezone contract traced end-to-end (phone authority, UTC fallback converges); #860 clamp date-line safe.
- Material P2 findings (assigned for fix + re-audit):
  - F1: DayRolloverCoordinator midnight-timer sub-µs early-wake truncation can re-arm to the NEXT boundary without recomputing (stale Liquid Today ~24h in a data-quiet foreground; timer path untested); same-date zone change does not bump dayRolloverSeq; macOS fall-back-DST timer fires ~1h late (no significantTimeChange on macOS). -> repair-dayui.
  - F2: a SECOND 04:00 logical-day twin survives in VitalSignsSummary.BodyVitalSigns.logicalDayKey(rolloverHour:4) (vitals tile Today label + sleep headline carry/stamp) — those surfaces treat yesterday as today between 00:00-04:00, contradicting the midnight policy. -> repair-dayui (added ownership).
  - F3: IntelligenceEngine.localDayRun uses TimeZone.current for ALL historical days (worker uses claim zone; SQL has effective-dated policy) — app/SQL historical bounds diverge after travel (pre-existing; T06 travel). -> repair-daybucket.
  - F4: America/Los_Angeles spring/fall fixtures not pinned (tests use New_York; zone-change-mid-window absent). -> repair-daybucket.
  - F5: coach.ts timezone persistence not round-trip tested against the real DB trigger (in-memory stub only; no PUT-read-back / invalid-zone-400 test). -> repair-diag.
  - F6: minor IntradaySeriesStore residuals (inFlight live-key held across midnight blocks refresh <=30s; loadCached cold-launch-after-midnight writes yesterday's cached window with no generation check). -> repair-dayui.
- NOT VERIFIED by auditor: device <=1s rollover latency; LA/zone-change app-SQL cross-parity (needs staged PG); coach.ts trigger round-trip; T02 first-render after real multi-day suspension.


### audit-g34-g7-context (reported)

- PASS: placement sequential half-open semantics (correction close/same-start replace/future cap/no double-cover/RLS/RPC double-guard/edge 409; reconcile byDevice leaves absent devices alone); offline effective-time fidelity (journal replays original effectiveStart; past-window corrections close server-side at past time); HART wear wiring traced end-to-end (WRIST events -> wearIntervals -> epochs -> C10 'w' -> activity_context_epochs.wear_state -> attachActivityContext; empty=unknown; odd-count OFF tail extends to day end per inherited pattern); diagnostics v2 honesty (not_measured; no owner/device UUID leak by code-read; day bounds never empty for enrolled owners — profiles trigger seeds -infinity history row); no new off-body fabrication; T20 manual-only placement confirmed (no command-84 parsing anywhere).
- Material findings:
  - F1 P2 (REPRODUCED by this auditor, independently of audit-g5-g6-isolation P2-2): set_placement_interval concurrency can leave 2 overlapping open intervals — already in the repair-placement fix round.
  - F2 P2: the five-minute eligibility flags are dead payload — no view consumes point.placement/wear/mixed, and the server never publishes rows 5..7 (worker series + /series route emit none). T19/G4 exposure unmet on the consumer side. -> repair-placement (consumer surface) + worker-side documented follow-up.
  - F4 P2 (confirmed still open, pre-existing): STANDARD_HR_CONTACT persisted but zero production consumers. -> fold contact into the same eligibility consumer surface (formula re-gating stays a documented follow-up per spec's no-formula-rewrite rule).
  - F3/F5/F6/F7 P3: partial-window coverage over-claim (label at window end); PlacementCloudSync.reconcile has no production caller; same-start replace drops p_effective_end; epoch tie-order at equal ts unspecified. -> minor fixes where small, documented otherwise.
  - Minor: pipeline_diagnostics_test does not itself assert the no-owner-identity property (the pre-existing server_pipeline_sql_test does) — assertion add assigned to repair-diag's round.
- NOT VERIFIED: MonitorView UI behavior (compile-only; named blocked check); PlacementCloudSync.reconcile network path; physical T15-T20 (no hardware session).


### audit-g2-durability (reported)

- All 9 challenges PASS at the contract level (targeted tests all green: 7 deno files, 65 worker swift tests, 46 macOS CloudPushTests). Notably verified: rest.ts C4 propagation sound across all consumers (the root's installationLifecycle 409-guard pinned; regex cannot leak URLs/SQL); outbox claim/renew/release FIFO + token/lease fenced; series fence converges under concurrency; projection debt monotonic cap; day attestation idempotent + revision-fenced with honest not_measured persisted; closure AT TIME ZONE correct for half-hour zones; quarantine classifier sound with identical worker/edge predicates; phone D1/D2 mid-stop idempotency; T09/T10 kill/lost-ACK convergence.
- Material P2 findings (fixes assigned):
  - ArchiveLane.swift:253-261: the archive outbox has no attempts cap/dead-letter — a persistently failing archive upload retries every 30s forever. -> repair-attest (cap + dead-letter, mirroring the projection-debt pattern).
  - ScoringLane.swift:728-737: quiet days (no work item) resolve timezone to UTC — closure enqueues use profiles.timezone but the attestation day bounds become UTC for non-UTC quiet days. -> repair-attest.
  - 20261003205000:132-138: invalid/NULL profile timezone rows are silently dropped by the pg_timezone_names join — device never closed, no error surfaced. -> repair-attest (bounded error/skip accounting).
  - 20261003205000:146: dead-lettered v2 days never get a closure marker — stuck invisible. -> repair-attest (closure marker for dead-lettered days or explicit exclusion with visibility).
  - VerificationLane: no operator un-quarantine path; 42501/23514 commit-rejects classified deterministic can strand after a transient deployment misconfig; plain recorded-digest byte mismatch stays unbounded-retry (documented tradeoff). -> repair-attest (un-quarantine RPC; document the rest).
  - placement_route_test.ts:163 weak assertion (checks failure message text, not the propagated code) — probe confirmed the code IS device_owner_mismatch; test-weakness only. -> repair-diag.
- NOT VERIFIED by auditor: closure SQL on real Kolkata/DST-day data (mirror pinned; SQL standard); quiet-day zone mismatch on real data (code-traced); device locked-phone D1/D2 timing; deployed DB shape.


## Re-audit round results

### audit-g2-durability (re-audit COMPLETE — all findings PASS)
- F1 outbox dead-letter PASS (claim excludes; 16th terminal with reason; upload-failure releases lease; integration test proves 1..15 retryable / 16th terminal). Minor: no operator reactivation runbook for the outbox (raw SQL only) — accepted documentation residual.
- F2 quiet-day zone PASS (profile-zone-before-UTC resolution pinned by 2 worker tests + 4-step deno test).
- F3 silent skip PASS (day_closure_skips ledger surfaced for invalid/missing; valid owners unaffected).
- F4 dead-lettered-day closure marker PASS (closed + closure_reason='dead_lettered').
- F5 un-quarantine RPC PASS (clears + re-selected by candidateSQL; object_not_found). Low residual: worker in-process negative cache holds the id until eviction/restart — DB re-selection proven; lane restart documented for immediate pickup.
- F6 placement_route assertion PASS (exact code + status).
- PG planner quirk construction CONFIRMED PROTECTED (CASE guarantees a valid zone on every derived row; behavioural proof: sweep completes with an invalid zone present).
- New-issue scan: none. Remaining risks accepted non-blocking (documentation: outbox reactivation runbook, closure_reason references the scoring_jobs_v2 reactivation procedure rather than restating it).

### audit-g1-day (re-audit — F1/F2/F4/F5/F6 PASS; F3 FAIL: new P1 regression)
- F1 PASS (timer-loop recompute pinned; zone-context signal tested; low documented residual: macOS fall-back DST fires ~1h late on a continuously-active Mac — day still rolls).
- F2 PASS (no production 04:00 default remains).
- F4 PASS (LA DST + mid-run zone-change fixtures pinned).
- F5 PASS (real-trigger coach timezone round-trip).
- F6 PASS (inFlight release + generation-checked loadCached; the IntradaySeriesTests edit justified — fixture was dated a prior day that F6b correctly refuses).
- F3 FAIL -> NEW P1: the zone journal is seeded-always and only appended from the CLOUD-GATED ProfileCloudSync.reconcile; a non-cloud user who travels gets every day (incl. today) bucketed in the stale launch zone — worse than the pre-fix live-zone behavior. FIX DISPATCHED to repair-daybucket (round 3: init-time append + un-gated zone-change observer + regression tests). FINAL F3 verdict (audit-g1-day re-verification): PASS — P1 closed (launch-append + un-gated dayKeyDidChange observer + offset==0 always-current-zone invariant; ZoneHistoryDayRunTests 7/7). Residual (documented, low): mid-session travel appends the journal at the next dayKeyDidChange event (sub-second); TODAY stays correct via the live-zone invariant regardless.


### audit-g34-g7-context (re-audit COMPLETE — all findings PASS)
- F1 PASS (advisory lock; the auditor's ORIGINAL race repro re-run against the 3-migration chain: 0 overlap pairs, was 2; lock owner-scoped, no deadlock, no cross-owner DoS; sequential semantics unchanged).
- F2 PASS in app scope: the 'Through the day' card renders per-metric context lines (server flags win per point; local fallback: placement from intervals, wear from WRIST spans, contact from standardHRContacts); T19/G4 per-metric exposure MET in-scope. Remaining documented risk: worker rows 5..7 + server /series publishing still absent — local fallback is what runs today.
- F3 PASS (partial coverage -> dimension unknown + mixed; pinned). F4 PASS (contact production-read; WHOOP honestly omits; no re-gating). F5 PASS (Settings-appear + post-pushPending reconcile callers; AppModel-level hook documented follow-up). F6 PASS (semantics-preserving; capped; pinned). F7 PASS (OFF-before-ON both folds + SQL ts,kind asc; worker tie-break not directly test-pinned — minor).
- New-issue scan: none. NOT VERIFIED unchanged: MonitorView UI tests, reconcile network-path unit test, physical T15-T20, shared-DB migration application.


### audit-g5-g6-isolation (re-audit COMPLETE — all findings PASS)
- P2-1 PASS (user/day fence across all devices; the exact A->B->A stale-pass scenario pinned). New low residual documented: the user/day max can suppress the SELECTED device's legitimate series write while a non-selected device's revision is higher (snapshot unaffected, self-corrects; deliberate latest-wins trade-off; follow-up if series must track the selected device).
- P2-2 PASS (owner-scoped advisory lock; held-lock serialization + 5-way burst + user-level lock proven; guards/grants unchanged; cross-scope disjointness verified).
- P2-3 PASS (retirement filter in ALL closure phases; claim-path residual ACCEPTED as a bounded window — new-enqueue sources closed during freeze, reads blocked, cascade self-cleaning, pre-existing behavior; follow-up recommended for a retirement filter in claim_scoring_v2).
- Round-2 items all PASS (outbox dead-letter, closure visibility ledger with no authenticated exposure, un-quarantine RPC, quiet-day zone resolution). No new issue in the grants/definer/search_path challenge list.
- Still NOT VERIFIED: automated account-deletion test covering the new tables (SQL-reading only); P2-1 residual starvation untested.
