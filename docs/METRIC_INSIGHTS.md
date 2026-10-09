# Key metric drill-downs and their explanations

Every key metric opens the same screen (`KeyMetricDetailView`, styled by `KeyMetricStyle` after the owner-approved
HRV concept): the period's value and how it compares, one interactive chart of dots over a shaded range, the data
and method behind it, and an explanation written server-side by Prime Agent (`Tools/MetricInsight`). The screen and
chart are drawn from the app's own data and work without the explanation; the explanation is fetched with `POST
/scores/insights {"metric": <id>}` and is optional.

## The screen

* **Periods.** 7 / 30 / 90 nights or days and a year (the #943 unlock rule applies). HRV (both sides) and stable
  awake heart rate also have **24 hours**: the server's 5-minute window estimates (physiology context layer), with
  All / Sleep / Stable awake chips and an estimated activity lane. A night metric's 24 hours run noon to noon around
  the night; a day metric's are the local day. Only windows that passed the quality checks are drawn.
* **Shaded range.** The metrics with a usual in the table below get the person's **usual range**: each day's
  Layer 1 band from `LongitudinalBaseline.vitalVerdict`, the same call as the Monitor list, the Home ring and the
  server's explanations (`BaselineStore.usualVerdicts`). The others (SDNN, blood oxygen, stable awake heart rate,
  calories) get a **recent range**: the middle 80% of the previous 30 measured periods, never called "usual". In the
  24-hour view only the stable awake chip has a reference (a dashed line at the usual stable-awake median); single
  windows have no usual range. Neither range is a safety range, and the screen says so.
* **Value.** The median of the shown period's readings; the selected reading (the latest on arrival) says where it
  sits against the range in words, never by colour alone.
* **Ask Sana.** The explanation card's button opens a new Sana chat: a question in the person's voice, what the
  screen showed as hidden context (`CoachHandoff.screenContext`, kept for every turn of that chat), and a memory that
  they want to understand this metric (`docs/COACH_MEMORY.md`, "Screen handoff"). The memory feeds later chats and
  these explanations (the worker reads `coach_memory_items`).

## The metrics (one id everywhere: app, edge function, database, worker)

| id | screen title | period | value the screen shows (app) | the server's value | the person's usual | measured or estimated |
| --- | --- | --- | --- | --- | --- | --- |
| `resting_hr` | Resting heart rate | night | `DailyMetric.restingHr` (or the imported `rhr` series) | `server_daily_scores.resting_hr_bpm` | the app's Baseline (Layer 1 `sleep_rhr`) | measured |
| `hrv_rmssd` | HRV, RMSSD side of the HRV switch | night | `DailyMetric.avgHrv` (or imported `hrv`) | `hrv_rmssd_ms` | Layer 1 `sleep_hrv_ln` | measured |
| `hrv_sdnn` | HRV, SDNN side of the HRV switch | night | `DailyMetric.avgSdnn` | `hrv_sdnn_ms` (5-minute SDNN index) | recent nights (the app has no SDNN usual) | measured |
| `skin_temp` | Wrist temperature | night | `DailyMetric.skinTempC` (absolute) | `skin_temp_c`, with `skin_temp_dev_c` as context | Layer 1 `sleep_temp` | measured (skin, not core) |
| `resp_rate` | Respiratory rate | night | `DailyMetric.respRateBpm` | `resp_rate_bpm` | Layer 1 `sleep_resp` | estimated (from heartbeat timing) |
| `spo2` | Blood oxygen | night | `spo2Pct`, else the strap's candidate | snapshot `daily.spo2_candidate_pct` | recent nights | estimated, unverified |
| `heart_rate` | Stable awake heart rate | day | context history daily value `heart_rate.stable_awake_5min` | the context document's daily value of that series | the context layer's personal reference | measured |
| `steps` | Steps | day | the Steps page's own source (`resolvedSteps`) | snapshot `daily.steps`, ElderNet gait detail | Layer 1 `waking_steps` | estimated (step counter) |
| `calories` | Calories | day | `energy_kcal` (imported) else `DailyMetric.activeKcalEst` (a whole-day total) | snapshot `daily.energy` | recent days | estimated |

* **Period.** A *night* is keyed by the day it ends. A *day* metric is explained for the latest complete local day
  (never today, which is still running); its screen shows that day as the current value.
* **HRV** is one screen with an RMSSD / SDNN switch. Each side has its own value, chart and explanation (two ids).
* **Recent nights / days** (no usual in the app): the explanation compares with the person's last 30 measured
  periods (median, range, rank) and never says "within / outside your usual range".
* **Estimated** signals are labelled on the screen and in every explanation sentence that states them.
* **Missing is missing**: a period without a measurement is a gap, never zero. Zero steps on a worn day is a real 0.

## The explanation payload

Unchanged shape (`headline`, `observed`, `interpretation`, `uncertainty`, `citations`, `related`, `basis`,
`data_through`), plus `period: "night" | "day"` so the card can say "nights" or "days".
