# Acceptance results (section 10, T01-T31)

Environment matrix (state each result's layer):
- **CODE**: macOS StrandTests (xcodegen + xcodebuild, scheme Strand, platform=macOS), Swift worker tests (`CPATH=/opt/homebrew/opt/libpq/include swift test`, Tools/CloudWorker), StrandAnalytics `swift test`, Deno suites (`EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all`, supabase/functions; NOTE repo pins deno 2.5.6, local runs used 2.9.7 — string-assert only, flagged).
- **DEVICE**: iPhone 16 (97672F64-...) via devicectl — pending post-repair build/install.
- **STAGING**: none exists; production is READ-ONLY (ssh + psql, no writes). T21/T24/T26 live checks are NOT VERIFIED with that as the blocked reason; capacity-workbook.md defines the executable staged run.
- **DEPLOYED**: read-only evidence in findings/root-deployment-baseline.md.

| Test | Requirement | Result | Evidence / blocked check |
| --- | --- | --- | --- |
| T01 | G1 | PASS (code): DayRolloverCoordinator re-keys at launch/resume/tz-change/significant-time-change + visible-app midnight timer; rollover independent of data/network (TodayDayRolloverTests). Device latency NOT VERIFIED (physical clock observation pending) | findings/g1-day-ui.md + findings/g1-day-ui-repair.md |
| T02 | G1 | PASS (code + device-adjacent): scenePhase .active recomputes Today before first meaningful render; syncHostedResults yesterday via Calendar. DEVICE EVIDENCE (2026-10-04 00:39, root run): the installed app created the 2026-10-04 dailyMetric row after local midnight on the physical iPhone with NO cloud dependency (DB copy off device shows the new-day row with nulls where the day is minutes old + accruing strain; 2026-10-03 fully populated). On-screen sub-second latency still NOT VERIFIED (needs observation at the boundary) | same + findings/root-deployment-baseline.md |
| T03 | G1 | PASS (code): persisted selection + clamp + explicit Today buttons (iOS top bar, macOS nav, Liquid header) | same |
| T04 | G1 | PASS (code): IntradaySeriesStore dayGeneration guard drops pre-midnight responses; ServerScoreRepository day-keyed materialization unchanged (IntradayStaleResponseTests) | same |
| T05 | G1/G2 | PASS (code): event-time attribution (SQL) unchanged-good; engine dayWindow bucketing zone-correct; exact-midnight pinned once (AnalyticsEngineDayBoundsTests +4) | same |
| T06 | G1/G6 | PASS (code): LocalDayWindows switch app+worker (dayWindow at worker call site +2 pinning tests); profiles.timezone written by phone + persisted by coach.ts + validated vs pg_timezone_names. End-to-end device/staging DST fixture NOT VERIFIED | same |
| T07 | G1/G2 | PASS (code): session bounds kept; wake-date sleep via Calendar; DST totals now zone-correct via T06 fix | same |
| T08 | G2 | PASS (code) / NV device live-outage | findings/g2-native-ble.md |
| T09 | G2/G6 | PASS (code+tests) | same |
| T10 | G2/G6 | PASS (code) / NV strap reboot; C1 narrow dedup key documented | same |
| T11 | G2 | PASS (code): projection-debt dead-letter at 16 with reason (migration 20260918040000 successor + claim excludes); deterministic manifest mismatches durably quarantined; verification quarantine tests green | same |
| T12 | G2 | PARTIAL / NV wipe-rebuild harness (needs Docker+private recording) | same |
| T13 | G2 | PASS | findings/g2-native-ble.md |
| T14 | G2 | NV device (exact sub-checks named in findings) | same |
| T15 | G3 | NV device (labelled wear/remove/rewear captures) | findings/g34-wear-placement.md |
| T16 | G3 | PASS (code: BT-loss != nonwear; no fabrication) / NV device | same |
| T17 | G3/G7 | PASS structure (distinct states) / NV device loose-contact | same |
| T18 | G3/G6 | PASS (fixtures 10/10, 92/92) | same |
| T19 | G4 | PASS (code): placement_intervals effective-dated; corrections close+revision; offline retains original effective time; five-minute mixed flags (app-side). Physical device change-mid-window NOT VERIFIED | same |
| T20 | G4 | PASS (code) | same |
| T21 | G5 | PASS (code) / NV live two-phone | findings/g5-auth-isolation.md |
| T22 | G5 | PASS (code): rest.ts C4 propagation; 3 formerly-red tests green (root re-run); new propagation regression (marker deferral on 401/403) found by root + fixed same day (installationLifecycle 409-guard; 14/14 green) | same |
| T23 | G5 | PASS (code): journal owner filters + seal/send guards + upload owner-mismatch refusal + receipt owner binding (3 regressions). End-to-end real A->B switch NOT VERIFIED (no switch UI by design; guards are the safety net) | same |
| T24 | G5 | PASS (code) / NV staging recovery | findings/g56-jobs-capacity.md |
| T25 | G5 | PASS w/ documented gaps (legacy claim path tombstone) | findings/g5-auth-isolation.md |
| T26 | G5 | NV staging; workbook prepared -> capacity.md | findings/g56-jobs-capacity.md |
| T27 | G6 | PASS (16/16 tests) | same |
| T28 | G6/G7 | PASS (code) / NV device delivery | same |
| T29 | G3/G7 | PASS (code, partial by design): bad/off-body data retained as evidence + excluded by existing gates; stale live values labelled; diagnostics surface now real (T30); RESIDUAL documented: contact-quality (STANDARD_HR_CONTACT) persisted but has no metric gate consumer yet (P2 follow-up, audit.md) | findings/g34-wear-placement.md + findings/repair-diag-repair.md |
| T30 | G2/G7 | PASS (code): server_pipeline_diagnostics v2 (day bounds/zone, coverage, largest gap, queue ages, durable-vs-verified archive, blockers) + real MonitorView owner-scoped surface (pipeline_diagnostics_test green) | same |
| T31 | G2/G5 | PASS (code): snapshots fenced (pre-existing); series fenced via 6-arg publish_metric_series_v1 (stale -> superseded, null rev -> 22023); ScoringLane passes claimed revision (SeriesFenceTests) | same |

[POST-REPAIR] cells are filled from the repair reports + root-run integration tests + independent audit results.

## Root-run suite results (authoritative, FINAL post-fix-rounds 2026-10-03)

- Deno full suite: baseline 234/14/12 -> intermediate 250/9 -> FINAL 258 passed / 9 failed / 141 steps / 14 ignored. The 9 failures are pre-existing environmental (Swift fixture export 'Tests/ServerFixtureNative' absent from this checkout; identical at pristine baseline 56809066 — root-verified). The 4 formerly-red contract tests fixed; the root-fixed propagation regression (installationLifecycle 409-guard) stays green. ZERO new failures across the entire audit+repair+re-audit cycle.
- Swift worker suite (FINAL): 247 executed / 6 skipped / 0 failures (root run; PKG_CONFIG_PATH=/opt/homebrew/opt/*/lib/pkgconfig required in this shell — brew pkg-config path, environmental).
- StrandAnalytics (FINAL): All tests passed (root run).
- macOS StrandTests full suite (ROOT FINAL run, post-round-3): 2499 executed / 2 skipped / 3 failures — all three verified pre-existing (SkinTempAbsoluteDisplay + SleepCarriedStamp Pacific caption pair; IntradayWordingAndCoach 90s-boundary, root-verified failing identically at pristine baseline 56809066). ZERO new failures across the entire cycle. (Test count 2473->2499: +26 tests added by the repair/re-audit rounds.)
- Deno version note: repo pins 2.5.6 (external npm package absent on this machine); all runs used 2.9.7 with --frozen --lock=deno.lock re-verified (no drift) — flagged as environment caveat.
