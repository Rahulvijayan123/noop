# Port Layer 1 + Watchdog from FRWHOOP_v2 into Nara-App

This file is the **only** brief a new Cursor agent needs. The prior FRWHOOP chat is not on the phone. Do not invent a second Watchdog. Copy the shipped engines, then wire them into **this** app’s IMU path and UI.

**Do not start scoring edits until you have copied the source files and the test suites are compiling.** Do not push to Rahul’s GitHub unless Chinmay asks.

---

## 0 · You do not paste this brief into chat

Cursor loads [AGENTS.md](../AGENTS.md) and `.cursor/rules/port-layer1-watchdog.mdc` from **this** repo automatically when Nara-App is the open workspace. Those files tell the agent to **read this document**. The wearer can send one word (`port`) or nothing beyond a normal ask.

Open the **Nara-App folder** in Cursor (not FRWHOOP_v2). If rules did not attach, the only message needed is:

`Read docs/PORT_LAYER1_WATCHDOG.md and follow it.`

Optional longer kickoff if you want it on the record:

```
Read docs/PORT_LAYER1_WATCHDOG.md first. Then read the source-of-truth contracts in the sibling checkout:

  /Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/baselines/README.md
  /Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/baselines/LAYER1.md
  /Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/baselines/WATCHDOG.md
  /Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/baselines/ADDONS.md
  /Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/baselines/PRIME_HANDOVER.md

Copy Layer 1 + Watchdog from that sibling into this Nara-App tree. Follow PORT_LAYER1_WATCHDOG.md exactly.

Locks: three engines never averaged (Charge EWMA ≠ Layer 1 ≠ Watchdog). No t0 from HR. Never name a drug. No on-device training. Wrist-off is unavailable, not recovered. Students stay labeled student. TimesFM 3.0 weights must not ship. Watchdog evaluate never writes Layer 1 7-day/60-day snapshots. Do not rewrite Charge / hosted scoring / 100 Hz IMU capture.

Work only on branch nara-baseline-watchdog. Do not commit or push unless I ask.
```

If the sibling path is missing, clone FRWHOOP_v2 and check out `nara-baseline-watchdog` (that branch has the Oct 4 engines). Published contracts are under `docs/baselines/`. The long daily log is on this machine at:

- `docs/FRWHOOP_WATCHDOG_04_OCT_2026.md` (this Nara-App checkout)
- `/Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2/docs/FRWHOOP_WATCHDOG_04_OCT_2026.md`
- `/Users/chinmaydudi/Desktop/FRWHOOP/local-04-oct-2026/` (log + this port brief)

G1–G9 that matter for the port are also restated in §8 of this file.

---

## 1 · What you are porting (and what you are not)

| Engine | Question it answers | Source of truth | Must stay |
|---|---|---|---|
| **Charge / Effort / Rest** | Hosted (or local) night score | Nara `Baselines.swift` EWMA, worker, `AppModel.cloudScoringIsAuthoritative` | Untouched. Nara Liquid hero ring labeled **“Baseline”** is **Charge**, not Layer 1. |
| **Layer 1** | What is usual over **days / nights**? | FRWHOOP `LongitudinalBaseline.swift` (`param_set = v1.review`) | Copied. Never averaged with Charge. |
| **Watchdog** | Last **~30 minutes** vs felt-ill / safety / painted range | FRWHOOP `Watchdog.swift` + UniTS / TimesFM **students** | Copied. Six per-vital graphs stay separate. |
| **F04 / F08 / F09** | Sidecars after `evaluate` / notify-sent | FRWHOOP add-on files + `ADDONS.md` | Copied as sidecars. Do not fold into `evaluate`. |

Nara already uses the word **Watchdog** for **heart-rate reserve** on Today and a **mock episode list**. Those are **not** the FRWHOOP engine. See §5. Name collisions are the #1 way this port will silently ship the wrong product.

---

## 2 · Repos, branches, machines

| Item | Value |
|---|---|
| Source (engines + contracts) | `/Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2` branch `nara-baseline-watchdog` |
| Destination (this app) | `/Users/chinmaydudi/Desktop/FRWHOOP/Nara-App` branch `nara-baseline-watchdog` |
| Remote for Nara | `nara` → `https://github.com/Rahulvijayan123/Nara-App` |
| Remote for FRWHOOP | `origin` on FRWHOOP_v2 — **do not** merge this port onto FRWHOOP `main` |
| Bundle / xcodegen | Nara already ran xcodegen once. After adding Swift files, regenerate the iOS project. |
| Secrets | `BundleIdSecrets` copied from FRWHOOP. `CloudPushSecrets` may still be the example — do not invent tokens. |

Clone layout Chinmay uses:

```
/Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2   ← copy FROM
/Users/chinmaydudi/Desktop/FRWHOOP/Nara-App     ← copy INTO (Cursor workspace)
```

---

## 3 · File copy list (do this as a tree copy, then wire)

Copy **byte-for-byte** first. Then fix compile errors from Nara package / UI differences. Do not “simplify” scoring while copying.

### 3.1 StrandAnalytics (engine)

From `FRWHOOP_v2/Packages/StrandAnalytics/Sources/StrandAnalytics/` into the same package in Nara (create files that do not exist; merge only if Nara already has an older twin — Nara’s `Baselines.swift` is Charge; **keep both**).

**Layer 1**

- `LongitudinalBaseline.swift`
- `LongitudinalBaselineReview.swift`
- `LongitudinalBaselineTrial.swift`
- `LongitudinalImuBaseline.swift`
- Any `LBDayTape` / day-log types that live in those files

**Watchdog core**

- `Watchdog.swift`
- `WatchdogV2.swift`
- `WatchdogConfig.swift`
- `WatchdogWindow.swift`
- `WatchdogActivity.swift`
- `WatchdogActivityFeatures.swift`
- `WatchdogPhaseUsual.swift`
- `WatchdogLiveTail.swift`
- `WatchdogLiveTape.swift`
- `WatchdogPhysiology.swift`          ← sidecar pages; do not merge graphs
- `WatchdogDirection.swift`
- `WatchdogEventLabeler.swift`
- `WatchdogEventRecovery.swift`
- `WatchdogEventGeometry.swift`
- `WatchdogEventMemory.swift`
- `WatchdogEpisodeAnnotation.swift`
- `WatchdogEpisodeLedger.swift`
- `WatchdogClinicianExport.swift`
- `UniTSRuntime.swift`
- TimesFM student runtime files that `Watchdog.swift` / Package resources import (copy every `TimesFM*` / `UniTS*` Swift file the compiler asks for)

**Charge (do not overwrite Nara)**

- Nara already has Charge `Baselines.swift`. FRWHOOP also has Charge `Baselines.swift`. **Diff before overwrite.** If they diverged, keep **Nara’s** Charge file and only add Layer 1 types that do not collide.

**Resources (students only)**

- `Packages/StrandAnalytics/Sources/StrandAnalytics/Resources/UniTS_AD.mlpackage`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/Resources/TimesFM3_Student.mlpackage`
- Mirror in `Strand/Resources/Watchdog/` if the app target copies them (FRWHOOP does).

`Package.swift` must `.copy` both mlpackages the way FRWHOOP does. Labels in UI and `forecastSource`: `units-ad-coreml-v3`, `timesfm3-student-v3`. Word **official** is forbidden on students. Do not add TimesFM 3.0 weights.

### 3.2 Tests (gate)

Copy the FRWHOOP test files that pin the contract. After the port they must be green on Nara’s StrandAnalytics package:

- `WatchdogV40CloseoutTests.swift`
- `WatchdogStatisticsContractTests.swift`
- `WatchdogPhysiologyAlertTests.swift`
- `WatchdogAddonSidecarTests.swift`
- `WatchdogPrimeHandoverLiveTests.swift`
- `WatchdogPrimeHandoverLayer1Tests.swift`
- `WatchdogPrimeHandoverAddonTests.swift`
- `WatchdogPreHandoffSweepTests.swift` (G1 / G6 / G9)
- `WatchdogBaselineGapProbeTests.swift`
- `LongitudinalBaseline*.swift` tests, especially `LongitudinalBaselineBiometricLogicTests`
- `UniTS*` paint / companion / temp tests if present

Older `WatchdogPrimeGauntlet*` / V23–V39 files are history. Bring them if they compile cheaply; **V40 + physiology + Layer 1 biometric + addons** are the merge gate.

### 3.3 App shell (FRWHOOP → Nara)

From `FRWHOOP_v2/Strand/`:

| Copy | Role |
|---|---|
| `Data/BaselineStore.swift` | Layer 1 store + Watchdog sidecar apply. **Rename in your head:** this is not Charge. |
| `Watchdog/WatchdogService.swift` | 30s tick, window load, `evaluate`, notify |
| `Watchdog/WatchdogNotifier.swift` | Local pages |
| `Watchdog/WatchdogBackgroundScheduler.swift` | iOS background; xcodegen must include it (FRWHOOP NOOPiOS missed this once) |
| `Screens/WatchdogView.swift` | Live six-vital UI (`WatchdogPlaceholderView`) |
| `Screens/WatchdogEpisodeNoteSheet.swift` | F08-ish notes; `@escaping` on the closure |
| `Screens/BaselineMonitorView.swift` | Layer 1 calendar / chips / TRUST |
| `Screens/TreatmentMarkingView.swift` | Logged treatment start only |

Wire into Nara `AppModel` the same way FRWHOOP does: `let baseline = BaselineStore()` and `let watchdog = WatchdogService()` then `watchdog.start(on: model)` at launch. **Do not** replace Nara’s Charge repository / cloud score path.

### 3.4 Strings

Port Watchdog / Layer 1 keys from `FRWHOOP_v2/Strand/Resources/Localizable.xcstrings` into Nara’s catalog. Do not reuse Nara’s hero strings “Baseline” / “Watchdog” for Layer 1 / live Off — those hero strings already mean Charge and HR-reserve.

---

## 4 · IMU: what Nara added, what Watchdog actually eats

### 4.1 Two IMU lanes in Nara (keep both)

Nara-App is the IMU-correct fork. There are **two** motion pipelines. Mixing them is a bug.

**Lane A — 100 Hz raw (WHOOP 5 / MG) — Nara-only, leave it**

- Decoder / writer: `Whoop5RawImu` and cloud object lane `rawImuSession`
- Disk: `Strand/Collect/ImuSessionFileStore.swift`
- Layout: Application Support `OpenWhoop/RawImuSessions/`
- Format: magic `NOOPIMU2`, 100 Hz, 6 int16 axes, 30 s zlib blocks, 30 min files
- UI: `RawDataCollectorView` and related Collect screens
- Durability: a record is HANDLED only after flush; pending tail ~10 s; evict on 5 min cadence during capture
- **Watchdog `evaluate` must not ingest 100 Hz tensors.** UniTS / activity classes are **per civil minute**.

**Lane B — 1 Hz gravity + `dynAccel` — this is what Watchdog already uses**

- SQLite table `gravitySample` (`WhoopStore` / `StreamStore`)
- Columns: `deviceId, ts, x, y, z, dynAccel`
- `dynAccel` = strap’s own gravity-removed motion magnitude for that second (migration v31)
- Read API: `store.gravitySamples(deviceId:from:to:limit:)`
- FRWHOOP `WatchdogService.loadWindow` already maps:

```swift
let gravity = try await store.gravitySamples(...)
let imu = gravity.map {
    WatchdogIMUSample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dynAccel)
}
```

`WatchdogIMUSample` is **1 Hz-shaped**: `ts, x, y, z, dynAccel?`. Activity embed aggregates those into **minutes**.

### 4.2 Device family (do not ignore WHOOP 5)

In `WatchdogActivityRuntime.embed`:

```swift
let samplesPerMin = family == .whoop5 ? 2.0 : 60.0
```

WHOOP 5 gravity ticks are **sparse** vs 4. Pass `family: .whoop5` (or MG equivalent if Nara’s `DeviceFamily` has it) when the bound strap is 5/MG. If you leave the default `.whoop4`, chair-still and step-sparsity will be wrong on the new hardware.

### 4.3 Chair-still (G9) — why 100 Hz does not “fix sensitivity” by being fed raw

Watchdog still / rest is **not** “any IMU tick = moving.”

Pinned in `WatchdogConfig`:

- `chairStillOccupancy = 0.32`
- `chairStillDynMean = 0.22`

`WatchdogActivity.pick` treats low occupancy **and** low `dynMean` as still (seated / desk), even if the 100 Hz file is “busy” with tremor. `WatchdogLiveTail` uses the same occupancy door for rest vs effort.

**Allowed IMU improvement (after copy compiles):** if `gravitySample` is empty or `dynAccel` is nil on a 5/MG while `ImuSessionFileStore` has coverage for the same window, **downsample** 100 Hz → 1 Hz gravity vector + a dyn-accel magnitude and **fill Lane B**. Do not change `chairStill*` constants without Chinmay. Do not classify rest from raw 100 Hz energy.

Suggested downsample (implement only if gravity is actually empty on device):

1. Read the overlapping 30 s blocks from `ImuSessionFileStore` for `[now-window, now]`.
2. Per UTC second: mean of accel axes → gravity-ish unit vector; RMS of high-passed magnitude → `dynAccel`.
3. Emit `WatchdogIMUSample` at 1 Hz. Dedup by `ts` with SQLite gravity (SQLite wins if both exist).
4. Keep writing 100 Hz files unchanged for capture / cloud.

### 4.4 Layer 1 IMU series

Layer 1 has its own series `wakingImuEnergy` from unique-minute `LBDayTape`. `WatchdogService` calls `model.baseline.ingestImu` **only** when `Watchdog.shouldTrainUsual`. Same window twice must not double-count (`LongitudinalImuBaseline`). Coverage floor: **≥ 60 unique minutes**. Do not train Layer 1 IMU from 100 Hz session files directly.

### 4.5 Occupancy vs class

Activity is **not** a single 0–1 scalar. Embed uses IMU + step `@63` class + in-tree `WorkoutTypeClassifier`. `effortOccupancy` maps class → effort (`still/stand → 0`, `walk → 0.32`, …). Artifact widens σ; it does not inflate joint J.

---

## 5 · Nara UI layout (Oct 2026) — where things go

### 5.1 iOS chrome (`StrandiOS/App/RootTabView.swift`)

Native `TabView`, five tags (do not renumber):

| Tag | Tab | Root |
|---|---|---|
| 0 | Today | `LiquidTodayView()` if `noop.liquidTodayEnabled` (default **ON**), else classic `TodayView()` |
| 1 | Monitor | `MonitorView()` — **mock** `MonitorSnapshot` until you wire real data |
| 2 | Events | `EventsView()` |
| 3 | Sleep | `SleepView()` |
| 4 | Sana | `CoachChatView()` if `noop.coachEnabled` |

More destinations (Settings, Devices, Health, …) live as sheets / `NavigationLink` values, not extra tabs. Today swipe changes **days**, not tabs. Re-tap tab pops that tab’s `NavigationPath`. Gear on Today opens **Settings sheet**.

macOS still uses sidebar `RootView` — if you add Layer 1 / Watchdog there, use the same `TabRoute` destinations.

### 5.2 Liquid Today hero (name collision — read twice)

`Strand/Liquid/LiquidTodayView.swift` hero row, left to right:

1. **“Baseline”** → `chargeDisplay` → **Charge** (hosted/local night score). `detailRoute: .metric(HeroRingMetric.charge)` → Health Charge.
2. **“Watchdog”** → `watchdogLoad` → **`HeroRings.heartLoad`** (HR reserve 0…100 from 5-min HR buckets). Status Calm / Active / Elevated. `detailRoute: .watchdog`.
3. **“Recovery”** → sleep performance. `detailRoute: .metric(HeroRingMetric.rest)`.

`TabRoute.watchdog` already exists and presents `WatchdogView()` in `Strand/Screens/MonitorView.swift`. That `WatchdogView` is a **30-day mock episode list**, not FRWHOOP live graphs.

**Port rules for Today**

- Do **not** point the left ring at Layer 1. Wearers already learned it as Charge.
- Do **not** feed Charge EWMA into Watchdog Off.
- After port, `TabRoute.watchdog` must present FRWHOOP `WatchdogPlaceholderView` (the live six-vital screen in `Strand/Screens/WatchdogView.swift`). Rename the **mock** `WatchdogView` / `WatchdogEpisode` in `MonitorView.swift` (e.g. `LegacyMonitorWatchdogView`) so Swift does not collide.
- The middle hero may **deep-link** to the live Watchdog screen. Optional later: replace `watchdogLoad` HR-reserve with a **status-only** pill (In range / Off / Unavailable) from `BaselineStore` Watchdog snapshot. If you keep HR-reserve as the ring fill, **relabel** it (Effort / Heart load) so “Watchdog” is not two products. Ask Chinmay before renaming shipped hero copy; default is: **route stays `.watchdog` → live engine**, ring fill can stay HR-reserve until he approves copy.
- Guide sheets (`.charge` / `.effort` / `.rest`) must not claim the middle ring is the FRWHOOP engine until copy is updated.

### 5.3 Where Layer 1 lives

FRWHOOP put Layer 1 on `BaselineMonitorView` (chips, 7-day / 60-day, TRUST, calendar, treatment). Nara has **no** NavItem for that.

**Required placement**

1. Add a destination (new `TabRoute` case, e.g. `.layer1` / `.usuals`) that hosts `BaselineMonitorView`.
2. Entry points that do not steal Charge:
   - Settings (gear sheet) row: “Day & night usuals” / “Layer 1”
   - Monitor tab: replace or sit **above** the mock baseline cards with real `BaselineMonitorView` content **or** a link into it
   - Optional: Liquid Today **secondary** row (not the Charge ring)
3. Context pills + vital chips stay visible while a series is building (`preferReadySeries` on swipe, not on explicit tap). See PRIME_HANDOVER display table.
4. Treatment UI (`TreatmentMarkingView`) from Settings or the Layer 1 toolbar. Card never names a drug.

**Forbidden placement**

- Do not replace Health `VitalSignsSummary` / `MetricExplorer` Charge usuals with Layer 1.
- Do not show Layer 1 7-day and Charge EWMA on the same sparkline.
- Do not hide all Layer 1 plots because one vital is still learning.

### 5.4 Watchdog screen (copied UI contract)

From FRWHOOP `WatchdogView.swift` (Oct 4):

- **Green corridor only** for the painted in-range band (no yellow-in-range).
- History: **all** `PointMark`s, colored by in/out **at that minute’s own band**.
- Row Off = `outsideBand` only (not personal-off alone, not “model hot”).
- G7: always show a **Range** label; In range / Off still require **14 present civil minutes** and TRUST ≥ 35.
- G1: `presentMinutes` may borrow `lastBandKey` for **display** when the current channel’s present set is empty — never for Off math as if data existed.
- G6: `evaluate` applies `maskStale` **then** `combine(window: modelWin, display: win)` so temp does not flicker when TRUST wobbles.
- Wrist-off / missing: **Unavailable**, not a recovered line.
- Students labeled student on any forecast chrome.
- Embed Watchdog **inside** Layer 1 only if you copy FRWHOOP’s stacked `BaselineMonitorView`; on Nara, prefer **push from Today Watchdog ring + Monitor**, Layer 1 on its own route, so Charge / usuals / live stay three surfaces.

Fit Nara chrome: `ScreenScaffold`, `StrandPalette`, Liquid corner radii (~26 hero, ~18 cards), `NoopPanelSurface`. Do not import FRWHOOP-only macOS sidebar assumptions into `RootTabView`.

### 5.5 Notifications

`WatchdogNotifier` local notifications. `allowNotify &= (safety || physiologyOff)` and `liveAlerts == false` (backfill) cannot page. Personal-off **alone** does not page. See §7.

Do not send Watchdog pages through the hosted push worker. Cloud push is Charge / raw ingest.

### 5.6 i18n / design tokens

Use Nara `String(localized:)` and `Localizable.xcstrings`. New keys for Layer 1 / live Watchdog. Do not retcon hero “Baseline” to mean Layer 1.

---

## 6 · Scoring contracts you must not “improve”

Read `LAYER1.md` and `WATCHDOG.md` in the sibling repo. Short form:

### Layer 1

- Two copies, never mixed: **7-day** finite EWMA on last 7 **completed** days; **60-day** median+MAD on T−60…T−8. Tonight is scored, not trained.
- Show: week at **4** nights; long at **14** (21 for steps / active / IMU).
- TRUST / HOW OFF: week HOW OFF hidden if TRUST < 35. Long card does not show HOW OFF.
- 18 series. Sleep RHR ≠ awake-rest HR ≠ steps.
- Minute floors: HR/HRV ≥ 8 unique minutes; SpO₂ ≥ 4; nadir ≥ 3 unique fresh sleep percents; IMU ≥ 60.
- HRV math on ln(RMSSD); cards show ms.
- Confounders only from **daily log**. Scheduled taken does not confound. Felt ill freezes when-well for Watchdog personal-off; it does **not** open a new long epoch. Only a **logged treatment start** freezes/restarts long.
- `Watchdog.evaluate` is never called from Layer 1 scoring.
- F08 notes do not set `confoundsUsual`.

### Watchdog

- Window ~ last 30 minutes. Sample identity = **measurement civil minute**.
- `present_mask` 1 = measured.
- Dual J: tanh joint for **labels**; clip-sum `severityJoint` (RHR out, `|r|` cap 1) for Off.
- `liveOff = severity ≥ candidate OR safety OR personal-off`.
- Personal-off = native HR/HRV vs felt-ill freeze or **shown 60-day**, never week, never UniTS hat.
- Safety = still-rest extrema.
- `fused()` returns recon only.
- `forecastSource` is `student | hold | inject | official`. Wearer Early shadow unless `official | inject`. You will ship **student**.
- TimesFM **cannot** severe-notify.
- Paint ranges (`paintRanges` / `liveAdaptiveScale` / `companionScale`) are **display-only** and never narrower than residual σ.
- G8: personal **skin** temp setpoint (not core). `tempScale = 1.0°C`. `liveTempHat` if student span < 0.15.
- Multivariate tensors are always fed; many hats are overwritten; **do not** merge the six Watchdogs into one usual.

### Physiology sidecar (already shipped in FRWHOOP)

`WatchdogPhysiology.swift` reads each vital’s in/out label and pages only when:

- `safety == true`, **or**
- ≥ `minVitals` (3) vitals outside **and** ≥ `minExtreme` (2) of those at `tActive`

Personal-off does not page. One or two vitals slightly outside do not page. Graphs stay independent.

In `Watchdog.evaluate`, `allowNotify = notify && liveAlerts && (safety || physiologyOff)`.

### Add-ons

F04 / F08 / F09 are sidecars after evaluate / notify-sent. See `ADDONS.md`. Do not put them inside UniTS.

---

## 7 · Hosted Nara backend vs on-device engines

Nara scores Charge on a **VPS worker** after `POST /functions/v1/push`. UI may treat cloud as authoritative (`cloudScoringIsAuthoritative`).

| Data | Hosted? | Watchdog / Layer 1 |
|---|---|---|
| Raw BLE → SQLite | Device | Window reads SQLite (HR, RR, temp, SpO₂, resp, gravity, steps, sleep sessions) |
| 100 Hz IMU files | Optional cloud object `rawImuSession` | Downsample locally if needed; do not score on the worker |
| Charge | Worker | Never average |
| Layer 1 snapshots | **On device only** | `BaselineStore` |
| Watchdog tick | **On device only** | `WatchdogService` every `WatchdogConfig.tickSeconds` |
| Severe page | Local notification | Not the ingest token path |

Do not reintroduce a Node API. Do not send UniTS windows to Supabase.

---

## 8 · Phone / Oct 4 display pins (G1–G9) — not in RAHUL_HANDOFF

These were worn on Chinmay’s phone after leftover 1–12. Implement as already written in FRWHOOP sources; do not re-derive.

| Id | Rule |
|---|---|
| G1 | `presentMinutes` / last-band borrow is **display** when a channel’s present set is empty (else empty→max). Off still needs real present minutes. |
| G2–G4 | Documented, not patched (quality / freshness / WHOOP 5 empty resp+SpO₂). Do not invent a breathing decoder to fill graphs. |
| G5 | Personal-off uses **shown long** (60-day), not week. |
| G6 | Stale-mask then combine(window: model, display: win) — stops temp flicker. |
| G7 | Range chrome always; In/Off lock = **14 civil minutes that channel** + TRUST ≥ 35 (floor 35; TRUST 65–73 looping does not hide ranges). |
| G8 | Skin setpoint, `tempScale` 1.0°C, `liveTempHat` if student span < 0.15. |
| G9 | Chair-still doors 0.32 / 0.22 — desk IMU must not stamp effort. |

14-minute lock: unique **measurement civil minutes** on that vital, not 20 s ticks, not “hour of sitting.”

WHOOP 5 empty respiratory / SpO₂: product/decoder gap. Watchdog shows unavailable. Do not synthesize.

---

## 9 · AppModel / service wiring checklist

1. `AppModel` owns `BaselineStore` + `WatchdogService` (FRWHOOP pattern).
2. `watchdog.start(on:)` binds `deviceId`, live HR / RR publishers, 30s loop.
3. On `deviceId` change: clear live rings, reload carry + sidecars.
4. `liveAlerts = !model.live.backfilling`.
5. Window from WhoopStore: HR, RR/HRV, skin temp, SpO₂, resp, steps, **gravity→IMU**, sleep sessions.
6. `UniTSPrompt.from(evaluations:)` using Layer 1 prompt evaluations already on `BaselineStore`.
7. `Watchdog.liveDayLog(today:yesterday:sleepOpen:)`.
8. After `evaluate`: persist carry; `shouldTrainUsual` → `ingestImu` + `ingestWatchdogTape`; always `applyWatchdog` + live sidecars; notify only if `shouldNotify`.
9. `WatchdogBackgroundScheduler` registered in the **iOS** target (xcodegen project.yml / NOOPiOS). Missing this compiled on Mac and failed on phone once.
10. Active `deviceId` only.

---

## 10 · Implementation order (do not skip)

1. Copy StrandAnalytics sources + mlpackages + Package.swift resources. Compile package.
2. Copy tests. Run:
   - `WatchdogV40CloseoutTests`
   - `WatchdogPhysiologyAlertTests`
   - `WatchdogStatisticsContractTests`
   - `LongitudinalBaselineBiometricLogicTests`
   - `WatchdogAddonSidecarTests`
   - Prime handover live / layer1 / addon
3. Copy `BaselineStore` + Watchdog service/notifier/scheduler. Wire `AppModel`. Compile app.
4. Rename Nara mock `WatchdogView` types. Point `TabRoute.watchdog` at FRWHOOP live view.
5. Add Layer 1 route + Settings / Monitor entry. Inject `BaselineStore` as `EnvironmentObject` on those stacks (and Today if the hero reads Watchdog status).
6. Confirm Charge `TodayView` / `LiquidTodayView` / Health still use Charge `Baselines`, not Layer 1.
7. IMU: pass `.whoop5` family; keep 100 Hz store; gravity map as FRWHOOP; optional 1 Hz downsample only if gravity empty.
8. xcodegen; iOS build; background scheduler linked.
9. Manual: Liquid Today → middle ring → live Watchdog; Settings → Layer 1 chips; Charge ring still Charge; Collect IMU still writes 100 Hz files.
10. Stop. Do not retune `tActive`, chair-still, or Charge. Commit only if Chinmay asks.

---

## 11 · Definition of done

- [ ] Nara package tests above are green.
- [ ] Charge numbers on Liquid Today / Health unchanged for the same night.
- [ ] Layer 1 week vs long never averaged; chips visible while building.
- [ ] Six Watchdog graphs independent; physiology sidecar only pages extreme / safety.
- [ ] 100 Hz capture + cloud object lane still compile and write.
- [ ] Gravity / `dynAccel` still feed occupancy; WHOOP 5 family used.
- [ ] No TimesFM 3.0; students labeled student.
- [ ] Mock Monitor episode list is renamed or removed from `.watchdog`.
- [ ] No commit/push to `Rahulvijayan123/Nara-App` unless asked.

---

## 12 · If something is missing

| Need | Where |
|---|---|
| Product locks | Sibling `docs/baselines/PRIME_HANDOVER.md` |
| Leftover 1–12 scoring | Sibling `WATCHDOG.md` / `LAYER1.md` |
| F04/F08/F09 | Sibling `ADDONS.md` |
| Nara tabs / cloud | This repo `docs/ARCHITECTURE.md`, `docs/BACKEND.md`, `docs/IOS.md` |
| Nara Charge math | This repo `docs/CURRENT_ALGORITHMS.md` — **not** Layer 1 |
| 100 Hz store | `Strand/Collect/ImuSessionFileStore.swift` |

If the sibling branch is behind Oct 4, the files that must exist on FRWHOOP `nara-baseline-watchdog` include `WatchdogPhysiology.swift`, `paintRanges` in `UniTSRuntime.swift`, and G9 constants in `WatchdogConfig.swift`.
