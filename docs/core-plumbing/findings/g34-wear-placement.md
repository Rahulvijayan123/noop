# Workstream 4 findings — g34-wear-placement (Wear / contact / charging / placement / context propagation)

Audit date: 2026-10-03
Tree: `nara-core-plumbing`, branch `audit/core-plumbing-20261003`, HEAD `4c85df9a` (spec-doc commit atop baseline `56809066`).
Verification level: **code-verified** only (plus `swift test` on the pure packages). No device, staging, or deployment access.
Relevant spec sections: G3 (§5), G4 (§6), G7 (§9), acceptance T15–T20, T29 (§10).

Scope owned here: WHOOP wear/contact events (type-48 EVENT, packet 54 buffered events, standard-BLE contact),
BLE decode path, Collector/CloudCapture staging, `IntelligenceEngine` wear consumers, placement (G4),
HART/activity context gating (G7), raw-IMU capture + interval labels, and metric eligibility gates.

---

## 1. Answers to the scoped questions (file:line evidence)

### Q1. Which wear/contact states exist as PERSISTED, evidenced state (vs transient UI booleans)?

**PERSISTED, evidenced (phone local store and server typed tables):**

| Dimension | Persisted state | Evidence basis recorded? | Where |
|---|---|---|---|
| Wear events | `WRIST_ON(9)` / `WRIST_OFF(10)` event rows | kind string carries the firmware event enum + raw value; `event_timestamp` is the strap RTC unix (payload stripped of `event`/`event_timestamp`) | Decode: `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift:861-871` (live), `HistoricalStreams.swift:432-452` (history); local table `event(deviceId, ts, kind, payloadJSON)` PK `(deviceId,ts,kind)` `Packages/WhoopStore/Sources/WhoopStore/Database.swift:28-34`; insert `StreamStore.swift:286-296`; server `public.noop_events(user_id,device_id,ts,kind)` `supabase/migrations/20260907133100_noop_append_stream_projections.sql:35-45` |
| Contact quality (standard BLE 0x2A37) | `STANDARD_HR_CONTACT` event rows, tri-state `unsupported` / `supported_not_detected` / `supported_detected`; **transitions only** (session-opener recorded, then only changes) | enum rawValue stored in payload JSON; parse failures throw (never "no contact") | `Packages/WhoopStore/Sources/WhoopStore/StandardHRMapping.swift:16,18-31,49-58`; read `Reads.swift:84-97` |
| Charging | `battery.charging` boolean column (from ~8-min `BATTERY_LEVEL(3)` events, gauge authority) + `CHARGING_ON(7)`/`CHARGING_OFF(8)`/`BATTERY_PACK_CONNECTED(21)`/`REMOVED(22)` event rows | charging is `u8 bit0` from the strap gauge (Interpreter post-hook); events carry enum name | `WhoopStore/Database.swift:137-142` (charging column); `StreamStore.swift:297-305`; decode `Interpreter.swift:969-995`; server `noop_battery_samples.charging` `20260907133100:62-73` |
| Connection | `BLE_CONNECTION_UP(11)`/`BLE_CONNECTION_DOWN(12)` event rows (persisted like any EVENT) | event enum + RTC ts | same event pipeline (Q1 first row) |
| Battery/availability | `battery` rows; `devices.last_seen_at/last_synced_at/sync_state` | device-level only | `20260819190000_frwhoop_base_schema.sql:41-56` |

**TRANSIENT UI booleans (not persisted):** `LiveState.worn` (defaults **true**), `LiveState.charging`, `LiveState.connected` — `Strand/BLE/LiveState.swift:409-411,96-128`. `worn` is explicitly "Defaults true so wear-gated features work before the first event arrives". The Wear-state tile gates itself on a live link so offline it shows "Unknown" rather than false-green — `Strand/Screens/LiveView.swift:1192-1204`.

**Verdict Q1:** ON_BODY/OFF_BODY are persisted **as events** (evidence-backed, RTC timestamped) and upload to `noop_events`; there is **no persisted enum column** and **no UNKNOWN** in the phone's wear state (the only tri-state is standard-BLE contact). Connection events persist but nothing reads them back.

### Q2. Interval reconstruction: half-open intervals, duplicates/out-of-order, dropped transitions, restart/gaps, staleness?

- **Off-wrist intervals ARE reconstructed** as half-open `[start, end)` by `AnalyticsEngine.offWristIntervals(events:windowEnd:hr:)` — `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift:25-48`. It sorts by `ts` (out-of-order safe), coalesces repeated OFFs/ONs, refuses an ON that is not `> offStart` (no negative/zero-length intervals), and closes an open tail at `windowEnd`, shortened to `WristWearRecovery.firstSustainedHR(...)` when sustained valid HR resumes (`WristWearRecovery.swift`). Used by phone (`Strand/Data/IntelligenceEngine.swift:1362-1369`) and worker (`Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift:293-295`).
- **Dedupe** at the source: local event PK `(deviceId,ts,kind)` with `ON CONFLICT DO NOTHING` — `StreamStore.swift:288-290`; server `noop_events` PK `(user_id,device_id,ts,kind)`.
- **Gaps/restart:** a wear gap is NOT reconciled to UNKNOWN anywhere on the phone. The only gap/staleness handling is (a) the live UI gating on a live link (Q1), and (b) the sleep stager's `offWristHRGapMin = 20` min / `maxOffWristSleepFraction = 0.5` fractional filter / `hrDenseSpacingS = 600` density guard — `SleepStager.swift:199-224`. The interval ends at the next ON or at `windowEnd`; a stale OFF tail simply extends to window end. **No general persisted "current wear state with last-evidence timestamp and staleness" exists.**
- Code-verified: `swift test --filter WristWearRecovery` → 10/10 pass (duplicates can't manufacture coverage, invalid readings reset confirmation, out-of-order tolerated); `SleepStagerTests` → 92/92 pass.

**Verdict Q2:** interval reconstruction exists **for the sleep backstop only**; it is deterministic and duplicate/out-of-order safe. There is no general wear-interval model, no staleness exposure (stale OFF after an unobserved interval never degrades to UNKNOWN), and nothing persists the reconstructed intervals — they are recomputed per scoring pass.

### Q3. Off-body inference discipline + wear-detection override commands (N2)

- **HR-gap → off-wrist proxy:** the sleep stager treats "a long CONTIGUOUS gap in the HR samples" as "a strong off-wrist proxy" (`SleepStager.swift:188-194`), unioned with explicit WRIST events in `offWristFraction` (`SleepStager.swift:1250-1281`). It is **only** used to drop a candidate sleep run past the 50% fractional threshold, gated by `hrDenseSpacingS` (a sparse-HR stream never asserts off-wrist from gaps — `SleepStager.swift:215-224`), and it is never persisted as a confirmed off-body assertion. This is the pattern the spec flags; as used it is an eligibility gate, not a stored claim.
- **HR-presence → worn** for skin temp: `wornNightlySkinTempC`/`skinTempFunnel` keep a skin-temp sample only when valid HR sits at the same second (WHOOP, tolerance 0) or within ±5 s (Oura `defaultOuraWornToleranceSec = 5`) — `AnalyticsEngine.swift:1570-1652`, threaded per-owner at `IntelligenceEngine.swift:1334,3174-3176`. Again a gate, never a persisted OFF_BODY.
- **No confirmed-OFF_BODY is derived anywhere and stored** from absent HR / stationary IMU / connection loss / battery. HART epochs default wear to `.unknown` ("quiet IMU is never on-wrist evidence") — `ActivityContextPolicy.swift:19,179-182,208-214`.
- **Overrides:** `sigproc_wear_detect` is in the unconditionally-refused device-config keys — `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceConfigWriteGate.swift:100-106`. `wear_detect_bias` **is** one of the sixteen R22 feature-flag keys the experimental deep-data sequence may write — `Whoop5Config.swift:58-74` — gated behind `PuffinExperiment.deepDataEnabled` (Settings → Experimental, default off; `BLEManager.swift:3571-3601`) and the key-aware `FeatureFlagWriteGate` (`R22Disable.swift:45-148`). `SELECT_WRIST(123)` is written only by the user-initiated ECG wrist-selection (`BLEManager.swift:4521-4533`). `GET_BODY_LOCATION_AND_STATUS(84)` is a **read-only diagnostic** that never changes wear detection/sleep/scoring (`BodyLocationProbe.swift:8-10`).
- Stale `worn=false` handling on source switch is real and handled in UI (`LiveView.swift:825,1108-1118`).

**Verdict Q3:** PASS for the invariant "no confirmed OFF_BODY is fabricated or stored from indirect signals" (the two proxies are eligibility gates only). WARN: `wear_detect_bias` write exists (experimental, gated) — flag as the one remaining "wear-detection override from earlier sensor work" per N2, and document it.

### Q4. Charging vs wear independence

- Charging is a **separate fact** in its own columns/events (Q1). `battery.charging` is the gauge's bit, and CHARGING_ON/OFF edges are separate EVENT rows; the WHOOP charge-while-worn case is representable (charging true + WRIST_ON event + HR present). Nothing conflates charging with wear. `lowPowerThrottleActive` reads `charging` for capture throttling (`LiveState.swift:119-127`) and the LiveView renders "Charging" under Battery separately from the Wear tile (`LiveView.swift:1183-1191`). BatteryEstimator treats `charging == nil` as unknown and only a confirmed `true` suppresses the low-battery alert (`Packages/StrandAnalytics/Sources/StrandAnalytics/BatteryEstimator.swift:265,345`).

**Verdict Q4:** PASS — charging is independently captured and stored; charge-while-worn does not produce fake physiology because no consumer reads charging as wear.

### Q5. Placement (G4) — does any placement model exist?

**No.** `grep placement|wrist|bicep` across Strand/, Packages/, supabase/, Tools/ finds:
- No placement setting/table/migration/effective-dating. `profiles` (server) has `preferences jsonb` with no placement — `20260819190000_frwhoop_base_schema.sql:23-39`; the phone `Profile`/`CloudProfile` has no placement — `Strand/Data/Profile.swift`, `ProfileCloudSync.swift:5-12`. `devices` has `calibration jsonb` / `sync_state jsonb` — no placement (`20260819190000:41-56`).
- The only "wrist" concepts: `StepsEstimateEngine.swift:15` mentions wrist-vs-hip as the reason `k` is personal (no placement input), `BodyLocationProbe` (read-only WHOOP4 decode, 5/MG NOT decoded, unknown/gap values fall through raw — `BodyLocationProbe.swift:70-84,109-122`), `ecgSelectWrist` (ECG probe), and `wear_detect_bias` (R22 flag).
- Command-84 fields are explicitly NOT placement certainty: "5/MG: … NOT decoded", unknown locations fall through to raw labels (`BodyLocationProbe.swift:69-84,109-122`).

**Where the minimal manual baseline should live (recommendation):** the natural fit is `profiles.preferences` (jsonb, per-user, already synced through the coach/profile route) or a new `placement_intervals` table (per owner/device, `placement in ('wrist','bicep','other','unknown')`, `effective_start/effective_end` UTC, `recorded_at`, `source='user'|'device'`, `revision`), mirroring the spec's effective-dating requirements. The `devices` table's `calibration jsonb` is also viable per-device. Consumers that need placement: steps (wrist-optimized caveat — `StepsEstimateEngine` calibration should record which placement each calibration day assumes), optical HR/RR provenance (contact/motion already carried; placement would be a provenance tag), skin temp site (site-change must not be treated as a physiological baseline shift — see `SleepStager`/skin-temp baselines), five-minute windows (flag mixed placement/state).

**Verdict Q5:** G4 FAIL (feature absent). The spec's required minimum (manual, effective-dated, synced, UNKNOWN for unannotated history, no backfill) does not exist. T19 fails; T20 passes only because command-84 can never produce certainty in code.

### Q6. HART/activity context (G7): gating, unknown handling, provenance

- Epoch grid carries `wear_state` (`on_wrist|off_wrist|unknown`) — `supabase/migrations/20261003120000_activity_context.sql:84` — but **no production caller supplies `wearIntervals`**: `ActivityLane.activityDocument(...)` builds epochs with default-empty `wearIntervals` (`Tools/CloudWorker/Sources/frwhoop-worker/ActivityLane.swift:877-902`), and the shared policy defaults wear to `.unknown` (`ActivityContextPolicy.swift:19,179-182`). So every published epoch is `wear_state='unknown'` today, even where WRIST events exist. This is spec-honest ("missing IMU → UNKNOWN not stationary") but it means **wear context is NOT propagated into HART epochs** — a real wiring gap (the lane could pass `WearInterval`s derived from `noop_events` WRIST rows).
- Unknown is first-class: abstention below 0.80 max-prob / 0.15 margin / label `unknown` (`ActivityContextPolicy.swift:27-64`); gaps reset hysteresis (`gapResetSeconds=4`, lines 33, 89-100); sleep/exercise tri-state never invents `false` (`ActivityContextPolicy.swift:203-230`).
- Label provenance separated: epochs carry `model_version`/`preprocessing_version`/`ontology_version`/`fingerprint`/`result_revision` (`20261003120000:88-93`), and the lane stamps only the versions the child actually reported (`ActivityLane.swift:780-787`, `ActivityContextPolicy` doc). Shadow vs promoted: the lane is **off by default** (`FRWHOOP_ACTIVITY_ENABLED=1`; `main.swift:105-107,218-224`), and held-out results are below promotion targets — "The feature stays in shadow mode" (`Tools/ActivityContext/eval/RESULTS.md:131-132`). No physiology depends on it (scoring attaches activity only as a `daily` key — `DayScoring.swift:571-627`).
- Raw-IMU interval labels: local user-confirmed overlays carry `provenance = "user_confirmed"`, exported with `start_ms/end_ms/label/provenance`, and never overwrite predicted labels — `Strand/Collect/RawDataSessionStore.swift:146-160,248-253,325-357`; UI in `Strand/Screens/RawDataCollectorView.swift:211-223,318-346`.

**Verdict Q6:** PASS on unknown/discipline/provenance; GAP: wear state is never fed into the activity fold (all epochs unknown), and placement (Q5) is absent from HART applicability.

### Q7. Eligibility gates — which metric paths check wear/contact before producing values?

| Path | Gate | Evidence |
|---|---|---|
| Nightly HRV (avgHrv) | Only from beats inside a detected sleep session; session acceptance has the off-wrist fractional filter (HR-gap ∪ WRIST intervals ≥50% drops the run; sparse-HR nights disable the gap proxy); plus `sessionHrvOverCounted` refuses over-counted nights | `SleepStager.swift:186-224,1250-1281,2949-2995`; `AnalyzeEngine` wiring `IntelligenceEngine.swift:1362-1369,1518-1551` |
| Five-minute HRV windows | Clean-beat floor (`HRVAnalyzer.minBeats`), ectopic+gap-aware cleaning, over-count gate; **no wear/contact/placement per window** | `SleepStager.swift:3005-3061`; worker `DayScoring.swift:204-233` |
| Respiratory rate | From RR within accepted sleep session + intraday `respMin*` gates; **no contact gate** | `IntradaySeries.swift:80-96`; `SleepStager` resp breath-track |
| Resting HR | Quiet-window definition within sleep session; intraday buckets require near-still motion (`restingMaxAmbulatoryShare=0.10`) | `IntradaySeries.swift:99-102` |
| Skin temp | Sample kept only when valid HR co-occurs (worn gate) AND inside a detected sleep window AND in ADC band | `AnalyticsEngine.swift:1585-1670` |
| SpO₂ | Nightly mean only from in-band readings inside a sleep session | `DayScoring.swift:163-166` |
| Intraday HRV/RR | "only reported for buckets whose wrist was quiet" — implemented via **motion share** (`maxAmbulatoryShare`), not contact/wear events | `IntradaySeries.swift:20-27,97-98,254-365` |
| Steps | Wrist-optimized calibrated estimate; per-day motion floor; no placement flag | `StepsEstimateEngine.swift:15,244-248` |
| HART | Off by default; epochs wear=unknown; no physiology consumes labels | Q6 |
| Watchdog/baseline | No in-repo "watchdog" consumer beyond BLE backfill timers (`Backfiller.swift:990`, `StuckStrapDetector`) and the worker heartbeat; no adapter/contract found for a physiological low-value-alert consumer | grep `watchdog` |

**Verdict Q7:** known off-body/poor-contact does **not** wrongly produce physiology where it matters most (sleep-stage HRV/RR/resting/skin-temp are inside accepted sessions; the off-wrist filter drops the session; intraday HRV/RR require quiet motion). But **contact events are never read by any metric** (`standardHRContacts` is test-only), and five-minute windows carry `motion` but no wear/contact/placement flag (G4 five-minute requirement not met).

### Q8. T17/T18/T19/T20 boundaries (code-verifiable vs device-only)

- **Code-verifiable (fixtures, PASSED here):** off-wrist interval reconstruction (duplicates/out-of-order/coalescing — `WristWearRecoveryTests` 10/10), sleep off-wrist fractional filter (`SleepStagerTests` 92/92), contact persistence + parse (`StandardHRMappingTests` 9/9), activity policy wear enrichment/unknown (`ActivityContextPolicyTests` 24/24, `ActivityContextJoinTests` 18/18), charging/contact/wear as separate persisted facts (Q1/Q4), command-84 can't produce placement certainty (Q5).
- **Device-only (NOT VERIFIED, needs real iPhone+WHOOP):** T15 physical wear/remove/rewear transition latency and cold-start recovery; T16 worn strap with BT off/out-of-range is not falsely declared nonwear (the app's `worn` defaults true and the tile goes "Unknown" offline — code supports it, but the physical case needs a device capture); T17 loose contact / charging-while-worn / stale-transition real captures; T18 duplicate/delayed wear events from a real strap replay; T20 malformed command-84 responses on a real strap (only WHOOP4 path is decoded; 5/MG field mapping is explicitly unconfirmed). T19 (placement) is code-FAIL — no placement model to test.

---

## 2. Requirement verdicts

| ID | Verdict | Summary |
|---|---|---|
| G3 | PARTIAL / FAIL (P1 parts) | Wear/contact/charging ARE persisted + uploaded (Q1); intervals exist for sleep only (Q2); no confirmed-OFF_BODY fabrication (Q3, PASS); but **no general persisted wear state with evidence-age/staleness**, no UNKNOWN reconciliation across gaps, no contact consumer, `ingest_gaps` "off_wrist/charging" kinds have **no writer**, and the `sessions.off_wrist_min` / `scorability.offWristDurationMin` columns are **declared but never written** (`20260826090000_sleep_probability_coverage.sql:9,20` vs zero writers in tree). |
| G4 | FAIL | No placement model of any kind (Q5). T19 fails; T20 code-PASS (command-84 read-only, never certainty). |
| G7 | PARTIAL | Envelope exists in part (activity epoch provenance, unknown-first HART); wear not propagated into HART epochs (all unknown); no diagnostics surface exposing wear/placement uncertainty/queue age in one owner-scoped view; no in-repo watchdog/baseline consumer adapter. |
| T15 | NOT VERIFIED | Physical wear/remove/rewear capture + latency + cold-start recovery. |
| T16 | PARTIAL (code) / NOT VERIFIED (device) | `worn` defaults true; tile shows "Unknown" without a live link (`LiveView.swift:1192-1204`); physical BT-off test needs a device. |
| T17 | PARTIAL | Charging/contact/wear distinct + no fabricated physiology (code); loose-contact and stale-transition device captures NOT VERIFIED. |
| T18 | PASS (fixtures) | Deterministic duplicate/out-of-order replay: `WristWearRecoveryTests` 10/10, `SleepStagerTests` 92/92; no negative/overlapping intervals (`AnalyticsEngine.swift:25-48`). Device replay NOT VERIFIED. |
| T19 | FAIL | No placement model; no effective-dating; no mixed-window flagging. |
| T20 | PASS (code) | Command-84 is read-only, WHOOP4-only decode, unknown/gap → raw label, never placement certainty (`BodyLocationProbe.swift:8-10,69-84,109-122`). Malformed-response handling on a real strap NOT VERIFIED. |
| T29 | PARTIAL | Known bad/off-body data retained as evidence (`noop_events`/event table, RLS-visible) and excluded by sleep/HRV gates; missing HART → unknown not rest (`ActivityContextPolicy`); stale live values labelled ("Unknown"/"Connect to read wear state", `LiveView.swift:1199-1204`); **missing**: a general contact/wear consumer and a diagnostics surface. |

---

## 3. Top findings (severity, evidence, repair)

1. **[P1] No placement model (G4).** No setting/table/migration in this tree. Repair: add minimal manual, effective-dated, synced placement (recommend `profiles.preferences` jsonb or a new `placement_intervals` table per owner/device), keep `unknown` for unannotated history, no backfill, wire the step-calibration caveat and five-minute eligibility flagging. `20260819190000_frwhoop_base_schema.sql:23-39`; `Profile.swift`; `StepsEstimateEngine.swift:15`; `IntradaySeries.swift:178-190`.
2. **[P1] Wear state is persisted only as event rows; no durable current-state + staleness model (G3).** `LiveState.worn` is a transient default-true boolean (`LiveState.swift:409-411`); nothing reconciles a stale OFF/ON across an unobserved interval to UNKNOWN; no evidence age exposed. Repair: a small read-side interval/state derivation (extend `offWristIntervals` pattern into a reusable wear-state view with last-evidence ts), or persist derived intervals; expose staleness in the diagnostics surface.
3. **[P1] `sessions.off_wrist_min` / `scorability.offWristDurationMin` and `ingest_gaps` "off_wrist"/"wrist_off"/"charging" kinds are dead schema.** Columns declared (`20260826090000:9,20`) with zero writers; `ingest_gaps` kind/resolution constraints exist (`20260830213940:17-24`) but no code writes gaps in this tree. Either write them (worker/sleep scoring already computes off-wrist fractions — `SleepStager.swift:1250-1281`) or remove/advertise as unsupported.
4. **[P2] Contact stream has no consumer.** `STANDARD_HR_CONTACT` events persist and upload but `standardHRContacts` is test-only (`WhoopStore/Reads.swift:84-97`). Repair: gate per-session HRV/RR quality on contact where available, and/or expose contact in the intraday series eligibility.
5. **[P2] HART epochs always `wear_state='unknown'`.** The shared policy supports `WearInterval` enrichment (`ActivityContextPolicy.swift:200-214`) but the lane passes none (`ActivityLane.swift:877-902`). Repair: derive `WearInterval`s from `noop_events` WRIST rows and pass them into `buildEpochs` (server + phone fold stay identical).
6. **[P2] Five-minute windows lack wear/contact/placement flags (G4).** `server_metric_series` points carry `[ts, value, samples, coverage, motion]` only (`IntradaySeries.swift:178-190`). Repair: extend the payload with per-bucket wear/contact/placement eligibility (or a `flags` column), and expose per-metric eligibility.
7. **[P3] `wear_detect_bias` write exists** in the R22 experimental sequence (`Whoop5Config.swift:68`, `R22Disable.swift`). Not used for wear assertions, but per N2 it should be documented as the one wear-affecting strap write. `sigproc_wear_detect` is correctly refused (`DeviceConfigWriteGate.swift:100-106`).
8. **[P3] No single owner-scoped diagnostics surface** exposing day bounds, stream status, wear/placement uncertainty, queue age, gaps (G7). Worker heartbeat exists (`main.swift:528-563` queue-age), and the `scores` snapshot carries `activity_context`, but no combined view. Repair: extend existing ingest verification/diagnostics with a wear/placement/staleness line.

## 4. Files that need changes (recommended owners)

- Placement (G4): `supabase/migrations/<new>` + `supabase/functions/_shared/coach.ts` profile save/load (or a small settings RPC) + `Strand/Data/Profile.swift`/`SettingsView` + `StrandAnalytics` (StepsEstimateEngine calibration placement tag; five-minute eligibility flag).
- Wear state/staleness (G3): read-side interval/state derivation near `AnalyticsEngine.offWristIntervals` (`Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift:25-48`) + `Strand/Data/IntelligenceEngine.swift` + diagnostics surface.
- Dead schema: either `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift` (write `off_wrist_min`/scorability) or a migration to drop/advertise; gap writer in `Strand/Push`/worker if `ingest_gaps` is to be real.
- HART wear enrichment: `Tools/CloudWorker/Sources/frwhoop-worker/ActivityLane.swift` (build `WearInterval`s from `noop_events`) + shared `ActivityContextPolicy` call sites (server and any phone-side fold).
- Contact consumption: `Packages/StrandAnalytics` (HRV/RR quality gates) + `Tools/CloudWorker/Sources/frwhoop-worker/IntradaySeries.swift`.

## 5. NOT VERIFIED / blocked checks

- **Device-verified (blocked: no physical iPhone+WHOOP):** T15, T16 (BT-off physical), T17 loose-contact/charge-while-worn/stale transitions, T18 real-strap replay, T20 malformed command-84 on real hardware (5/MG body-location field mapping is explicitly unconfirmed — `BodyLocationProbe.swift:83`).
- **Staging-verified (blocked: no staging env):** SQL/deno fixture suite (`supabase/functions/tests`, README at `supabase/functions/tests/README.md`; needs local PostgreSQL 18.3 + PostgREST + Deno 2.5.6 and the evidence-dir fixture chain), wear-dependency triggers (`20260918060000_physiology_wear_dependencies.sql`), `activity_context_contract.sql`, multi-user isolation.
- **Deployed-verified (blocked: no deployed access):** production `noop_events` contents, migration application order, and the worker's live wear/activity behavior.
- **No in-repo baseline/watchdog physiological-low-value consumer found** — G7's watchdog item is NOT VERIFIED / needs a specified external contract if it exists outside this repo.

## 6. Verification commands run (this audit)

- `git rev-parse HEAD` → `4c85df9a`; branch `audit/core-plumbing-20261003`; working tree clean except this findings file.
- `swift test --filter WristWearRecovery` (Packages/StrandAnalytics) → 10/10 pass.
- `swift test --filter SleepStagerTests` → 92/92 pass.
- `swift test --filter ActivityContextPolicyTests` → 24/24 pass.
- `swift test --filter ActivityContextJoinTests` → 18/18 pass.
- `swift test --filter StandardHRMappingTests` (Packages/WhoopStore) → 9/9 pass.
