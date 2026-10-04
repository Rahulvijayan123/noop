# G1-G7 / T01-T31 evidence matrix (working copy, 2026-10-03)

Sources: docs/core-plumbing/findings/{g1-day-ui,g2-native-ble,g2-attestation,g34-wear-placement,g5-auth-isolation,g56-jobs-capacity}.md — all file:line evidence in those files. Verdicts: PASS=code-verified; FAIL=code-verified defect; NV=NOT VERIFIED (blocked check named); JNA=justified not applicable. Repair phase in flight on branch audit/core-plumbing-20261003; statuses below are PRE-REPAIR unless marked.

## G1 Today/day rollover/timezone (P0)

| Req/Test | Verdict | Evidence (file:line in findings) | Repair owner |
| --- | --- | --- | --- |
| T01 midnight rollover, no data dependency | FAIL | no boundary timer; rollover only on refreshSeq/offset change (g1: LiquidTodayView.swift:450, TodayView.swift:1758, AppModel.swift:724, TodayView.swift:1435/1583) | repair-dayui |
| T02 suspended-across-midnight first render | FAIL | resume renders cached day; recompute only after backfill/sync (g1: StrandiOSApp.swift:348-397, AppModel.swift:334) | repair-dayui |
| T03 past-day selection persists; return-to-Today | PARTIAL FAIL | selectedDayOffset @State not persisted (g1: TodayView.swift:625, LiquidTodayView.swift:128); no explicit Today action | repair-dayui |
| T04 stale prior-day response cannot block/reverse | PARTIAL | day-keyed materialization guarded (g1: ServerScoreRepository.swift:378,663-682, AppModel.swift:324); IntradaySeriesStore.live-key write unguarded (IntradaySeriesStore.swift:48, IntradaySeries.swift:237) | repair-dayui |
| T05 exact-midnight once; batch attribution by event time | PARTIAL | SQL event-time attribution correct (g1: 20260921104000:11, 20260918010000:490-504; g2-attest: 20260918010000:76-98, 20260923160000:23-31); shared engine fixed-86400 double-counts DST boundary hour | repair-daybucket |
| T06 DST/UTC/Kolkata/travel agreement | FAIL | fixed offset + 86400 blocks (g1: AnalyticsEngine.swift:194-199,502-504,553; IntelligenceEngine.swift:630-633); LocalDayWindows unused; app never writes profiles.timezone (Profile.swift:176-179, ProfileCloudSync.swift:5-20, base_schema:32) -> server-day != app-day | repair-daybucket |
| T07 sleep/workout across midnight | PARTIAL PASS | session bounds kept; wake-date sleep via Calendar (g1: SleepModel.swift:101-120,252-258); DST totals share T06 defect | repair-daybucket |
| T30 diagnostics parity | PARTIAL | diagnostics route exists; day bounds/revision gaps (g56) | repair-diag |
| Midnight-closure scheduling | FAIL | no per-user-zone closure; quiet days never settle (g2-attest) | repair-attest |
| UI timer/lifecycle observers | FAIL | absent (g1) | repair-dayui |

## G2 acquisition/durability/attestation (P0)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| 4.2.1 persist-before-death | PASS | g2-ble: Collector.swift:333-349; CloudJournal.swift:400-437,1116-1130 (WAL sync=FULL) | — |
| 4.2.2 acquisition-time owner/device/stream binding | PASS | g2-ble: CloudJournalStore.append:513-594; CloudCapture.swift:453-455 | — |
| 4.2.3 acceptance watermark crash-safety | PASS | g2-ble: CloudTransportCoordinator.swift:416-467 | — |
| 4.2.4 strap ACK/trim separate; no destructive trim | PASS | g2-ble: Backfiller.finishChunk:597-988 (ackTrim:986) | — |
| T08 offline outage durable pending work | PASS code / NV device | g2-ble (T08), blocked: live outage retry on device | — |
| T09 kill/restart around append/ACK/upload | PASS | g2-ble (journal-backed idempotent state machine) | — |
| T10 lost ACK/dup batch/reboot converge | PASS code / NV strap-reboot | g2-ble (content-derived batch id; per-(ts,rrMs,seq) keys; C1 narrow equal-(ts,rrMs) flush-boundary collapse documented) | — (C1 documented) |
| T11 corrupt/orphan reconcile+quarantine | PASS w/ gap | g2-attest (durability.ts:62-171 streaming SHA-256; reconcile); projection debt no dead-letter -> repair-attest | repair-attest |
| T12 wipe-derived+replay determinism | PARTIAL NV | replay paths exist+tested; no wipe/rebuild harness (real_recording_replay_sql_test needs Docker+private recording) | repair-attest (harness follow-up), NV documented |
| T13 realtime-only IMU vs banked HR | PASS | g2-ble (IMU realtime-only by construction; honest diskSeconds/pendingSeconds) | — |
| T14 locked-phone/eviction/force-quit/BT-settings | NV device | exact blocked checks named in g2-ble findings | device phase |
| 4.4 daily attestation record | FAIL | day_completeness zero code references (g2-attest; root-verified) | repair-attest |
| 4.5 zone-aware closure | FAIL | crons only; no per-zone work (g2-attest) | repair-attest |
| 4.6 archive integrity verification | PASS + GAP durable quarantine | g2-attest (durability.ts:62-171; noop_commit_object_receipt; verification lane re-hash; ArchiveLane sha+lease-fenced); reconcileObjects HEAD/size-only gap noted; live digest-mismatch lead on droplet: root-TRACED — no durable quarantine for deterministically-unverifiable manifests (in-process negative cache only, re-verified once per process forever) | repair-attest (follow-up assigned) |
| ACK vs verified archival separation | PASS | g2-attest (20260918040000:153-278; ArchiveLane.swift:180-236) | — |
| T31 older-revision publish fence | PASS snapshots / GAP series | publish_scoring_snapshot_v2 fenced (20260918010000:230-240); publish_metric_series_v1 NOT revision-fenced (root-verified: no input_revision param) | repair-attest |
| ProjectionLane hot-loop (prior audit P1-1) | FIXED (verified) | ProjectionLane.swift:203-214 failDebt routing (root-verified) | — |
| rest.ts error-code masking (3 red tests) | FAIL (root-verified regression at HEAD) | scalar/intake/object_verification tests red; root cause rest.ts:61-70 | repair-attest |

## G3 wear/contact/charging (P1; P0 if data corruption)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| Wear states persisted+evidenced | PARTIAL FAIL | WRIST_ON/OFF event rows persisted+uploaded (g34: Streams.swift:861-871, HistoricalStreams.swift:432-452; Database.swift:28-34; 20260907133100:35-45); no current-state+staleness model; LiveState.worn defaults true (root-verified LiveState.swift:409-411) | repair-placement (wear wiring) + documented |
| Contact quality consumers | FAIL (dead) | STANDARD_HR_CONTACT persisted+uploaded; standardHRContacts test-only; no gate uses contact (g34: StandardHRMapping.swift:16, Reads.swift:84-97) | documented; consumer gates follow-up |
| Charging independent of wear | PASS | g34 (battery.charging + CHARGING_ON/OFF rows independent) | — |
| T15/T16/T17 physical | NV device | exact blocked checks named (g34) | device phase |
| T18 deterministic replay of wear events | PASS | g34 (WristWearRecoveryTests 10/10; SleepStagerTests 92/92; half-open nonoverlap) | — |
| T29 bad data retained+excluded | PARTIAL | retained+excluded verified; stale live values labelled; contact consumer + diagnostics gaps | repair-diag + follow-up |
| Off-body fabrication discipline | PASS | no confirmed OFF_BODY from absence proxies (g34: SleepStager.swift:186-224 eligibility gates only; AnalyticsEngine.swift:1570-1652) | — |
| R22 wear_detect_bias override | DOCUMENTED | gated experimental (g34: Whoop5Config.swift:68, R22Disable.swift; DeviceConfigWriteGate.swift:100-106 refuses sigproc) | documented (N2) |

## G4 placement (P1)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| Placement model exists | FAIL | none anywhere (g34) | repair-placement |
| Effective-dated history, offline, corrections | FAIL | n/a (no model) | repair-placement |
| T19 mid-window change/flag mixed | FAIL | n/a | repair-placement |
| T20 placeholder bytes no certainty | PASS | g34 (command-84 read-only; WHOOP4-only decode) | — |
| HART/activity wear_state | FAIL (always unknown) | g34: ActivityLane.swift:877-902 passes no wearIntervals (root-verified); ActivityContextPolicy.swift:19,208-214 | repair-placement |
| Five-minute eligibility flags | FAIL | series points carry [ts,value,samples,coverage,motion] only (g34: IntradaySeries.swift:178-190) | repair-placement |
| Dead schema off_wrist_min/offWristDurationMin | FAIL (dead) | zero writers (root-verified: grep empty) | documented; repair-attest attestation may populate |
| Steps wrist-optimization caveat | PASS documented | g34: StepsEstimateEngine.swift:15 caveat exists; no invented correction factor | — |

## G5 multi-user isolation + capacity (P0 isolation)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| Identity model fail-closed | PASS | g5 (tokens.ts:171-266; serverScores.ts:330-345; legacy fleet off by default; no dev fallback) | — |
| T21 two-user same-timestamp isolation | PASS code / NV live-2-phone | g5 (13 auth unit suites + 3 integration green pre-rest.ts-red) | — |
| T22 forged/nested/mixed-owner | PASS w/ caveat | g5 (20260918040000:191; 20260923180000:49); caveat: 3 red tests from rest.ts masking (root cause shared with g2-attest) | repair-attest |
| T23 account-switch queue isolation | LATENT FAIL | journal/object-lane one shared SQLite; sealer/sender no owner filter (g5: CloudJournal.swift:632-649,673-683,902-927; CloudUploadSession.swift:118,182); no exploitable switch path today (signOut zero callers; server refuses rebind) | repair-ble |
| T24 backfill starvation | PASS code / NV staging | g56 (20261002123000:24-35 oldest-first + cooldowns; per-owner input gate; dead-letter at 8) | capacity-workbook |
| T25 deletion/reassignment | PASS w/ gaps | g5 (B2-before-Auth; tombstone+revocation; intake/verify/projection closed); gaps: legacy claim path no tombstone check (documented) | documented |
| RLS coverage | PASS | g5 (339/339 definer fns search_path; all account tables RLS) | — |
| Signed URLs | PASS | g5 (15-min TTL; owner+source+authMode+byte-count) | — |
| Realtime authorization | PASS code / NV deployed | g5 (RLS on realtime.messages 20260824220000:442-448; platform-managed schema) | rollout verification |
| T26 staged capacity report | NV staging | g56 (harness targets JVM worker; infra files missing) | repair-diag (workbook + harness repair) |
| Deployed migration order/grants | NV deployed | g5 | rollout verification |

## G6 timing/counters/source integrity (P0 where ownership/counts wrong)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| T27 steps resets/wraps/midnight | PASS | g56 (u16 wrap-aware, maxStepDelta+rate guard, own-day totals; StepsCounterTests 16/16) | — |
| T28 HK arbitration/provenance | PASS code / NV device | g56 (HealthKitBridge.swift:367-461 anchors; notNoopAuthored:1416-1426; separate import source) | device phase |
| RR dedup key collapse (C1) | DOCUMENTED narrow | g2-ble (StreamStore.swift:207-231 equal-(ts,rrMs) across flush-boundary seq restart) | documented; WhoopStore owner follow-up |
| Corrected-time invalidation | PASS | event-time mapping + revisions (g2-attest 20260918010000:76-98) | — |

## G7 context/quality/visibility (P1)

| Req/Test | Verdict | Evidence | Repair owner |
| --- | --- | --- | --- |
| Diagnostics surface | PARTIAL | g56 (server_pipeline_diagnostics exists; gaps in coverage/queue-age/revision/day-bounds; MonitorView placeholder:228) | repair-diag |
| HART labels optional context | PASS (shadow) | g34/g56 (unknown-first; shadow-only, off by default) | — |
| Eligibility to consumers | PARTIAL | see G3/G4 rows | follow-ups documented |

## Cross-cutting

- Deployed revision identity: proven = c3e30be1 CloudWorker sources; FRWHOOP_SOURCE_REVISION env mislabeled (a7ea5426); deployed lacks activity lane (root baseline).
- Deployed health: scoring/archive healthy; verify-lane digest-mismatch lead (object 6ad53e16, no expected wire digest recorded) — to trace in rollout; 10 pending jobs; projection debt 16k stale rows (lane off in prod).
- Deno pinned 2.5.6 vs local 2.9.7 (g5 note) — record in acceptance environment matrix.
