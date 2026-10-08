# Current scoring algorithms

This is the on-device scoring the app actually runs today. The daily pass is `AnalyticsEngine.analyzeDay` in `noop/Packages/StrandAnalytics`. The same logic is mirrored in the Android Kotlin twins.

These scores are transparent, published-physiology approximations. They are not WHOOP’s proprietary models, not laboratory measurements, and not medical advice.

UI names vs code names:

| What you see | Code / stored field | Scale |
|---|---|---|
| Charge | `recovery` (`RecoveryScorer`) | 0–100 |
| Effort | `strain` (`StrainScorer`) | 0–100 |
| Rest | `restScore` / `sleep_performance` (`AnalyticsEngine.Rest`) | 0–100 |
| HRV | `avgHrv` | milliseconds (RMSSD) |
| Resting HR | `restingHr` | bpm, integer |
| Respiratory rate | `respRateBpm` | breaths/min |
| Steps | `steps` | count |
| Calories | `activeKcalEst` | kcal (resting + active total) |

Charge is documented at the end because it is the composite that consumes HRV, resting HR, respiration, and Rest. It is not a separate sensor algorithm.

---

## How a day is built

`IntelligenceEngine` reads the raw streams and calls `AnalyticsEngine.analyzeDay`. Sleep, HRV, resting HR, respiration, and Rest are computed from the **night window** (the span that covers the previous evening through the next morning). Effort, steps, calories, and workout detection use the **local calendar day** when the caller supplies `dayHr` / `daySteps` / `dayGravity`, so an afternoon workout is not cut off at noon.

Profile inputs used across scores (`UserProfile`): age, sex, weight (kg), height (cm), optional manual HRmax override, and `stepTicksPerStep` (default 1.0).

Personal baselines (`Baselines`) are a winsorized EWMA. A metric becomes usable after **4** valid nights (`minNightsSeed`), trusted after **14** (`minNightsTrust`), and stale after **14** nights without an update. Center half-life is 14 nights, spread half-life is 21. Robust sigma used in z-scores is `1.253 × spread`. During the first 8 nights the center adapts faster (half-life 3) and the hard-outlier gate is off, so a high first night cannot lock the baseline.

| Metric key | Valid range | Floor spread |
|---|---|---|
| `hrv` | 5–250 ms | 5 ms |
| `resting_hr` | 30–120 bpm | 2 bpm |
| `resp` | 4–40 breaths/min | 0.5 |
| `skin_temp` | 20–42 °C | 0.3 °C |
| `strain` | 0–100 | 5 |

---

## 1. HRV

**What it is.** Overnight RMSSD, the root-mean-square of successive differences between normal beat intervals. Task Force (1996).

**Source.** `HRVAnalyzer` (cleaning and the statistic) and `SleepStager.sessionAvgHRV` / `sessionHrvWindows` (the nightly windows). Daily rollup is `avgHRVDaily` in `AnalyticsEngine`.

### Input

- R-R intervals (`RRInterval`: timestamp in unix seconds, `rrMs`).
- Sleep-session bounds from sleep detection. HRV is only computed inside detected in-bed sessions.
- Optional user setting **deep-sleep window** (`UnitPrefs` / `deepHrvWindow`). Default is off.

### Cleaning (every window)

1. **Range filter.** Keep intervals in **300–2000 ms** (about 200–30 bpm).
2. **Malik ectopic rejection.** Drop a beat that deviates more than **20%** from the median of its neighbours in a 5-beat window (radius 2). This stands in for the server’s Kubios / Lipponen–Tarvainen classifier, which is not available on device.
3. **Gap-aware successive differences.** A difference is counted only when the two surviving beats were adjacent in the original series. Dropping a bad beat does not splice its neighbours into a fake delta.

A 5-minute window is kept only when it has at least **20** clean intervals (`minBeats`).

### Formula

```
RMSSD = sqrt( mean( (NN[i] − NN[i−1])² ) )
```

only over contiguous pairs. Also computed, but not the headline number: SDNN (sample SD, ddof = 1), mean NN, pNN50 (percent of successive |ΔNN| > 50 ms).

### Nightly output

- Windows are tumbling **5 minutes**, closed on the final window so a beat exactly at session end is not dropped.
- **Default (whole night):** duration-weighted mean of each session’s mean window-RMSSD. Longer sessions weigh more. Naps are included unless the main night was refused (below).
- **Deep-window setting:** unweighted mean of RMSSD from windows whose center falls in a **deep** stage. If no deep sleep was staged, the day is nil.
- **Over-count gate.** If the session’s R-R intervals sum to more beat-time than the wall clock they span, the session HRV is nil. An over-counted stream corrupts successive differences. A refused main night is not replaced by a nap.
- HR-only nights (no motion spine) are used for HRV only when the day has no motion-staged session.
- Stored as `DailyMetric.avgHrv` (ms). Also stored: `avgSdnn`, the mean of 5-minute SDNN segments over in-bed R-R (the SDNN index, not one whole-night SD).
- **Hosted worker input.** A WHOOP 5 strap writes each beat on two transports (historical 5 and standard 7), so the worker keeps ONE transport per UTC hour (the fullest strap channel, lowest id on a tie) before scoring. Without that the over-count gate above withholds the night. Redundant `spo2Ibi` rows and `tsSuspect` rows are not read.
- **Intraday series (hosted worker only).** The scoring snapshot's `daily.hrv_series` holds one RMSSD per **15-minute** slot of the local day (`{slot_s, points: [[slotStartUnix, rmssd, cleanBeats]]}`), recomputed on every re-score. A slot needs ≥ 60 clean beats, coverage ≤ the over-count ceiling, and the spot-reading rejection limit. Daytime wrist RMSSD is artifact-prone, so this series is informational and never feeds Charge or baselines.
- **Dense series (hosted worker only).** `server_metric_series` holds RMSSD per **5-minute** bucket (≥ 45 clean beats, quiet wrist) for the app's "Through the day" card, next to the 15-minute slots above; see the backend runbook.

### What it does not do

- No frequency-domain HRV (HF, LF, LF/HF) in the shipped score. `HRVFreqDomain` (method `lomb_scargle_psd_ms2_v2`, spec-02 §1) feeds only the Stress screen's descriptive optical-PRV band powers: Lomb–Scargle on each interval's true END time inside contiguous runs (a missing beat, wall-clock gap, re-stamped delivery or channel change splits the run; nothing is bridged), absolute one-sided PSD in ms²/Hz so band integrals are ms², 300 s windows with the existing band edges and span gates, and a span-weighted mean over full (≥ 250 s) windows only. It is not the nightly number.
- `HRVReadiness` (log-RMSSD tiers) is an opt-in Test Centre readout. It does not move Charge.

---

## 2. Sleep

Sleep is two steps: **detect** the in-bed session, then **stage** it. Detection is always `SleepStager` (V1 spine). Staging defaults to **`SleepStagerV2`**. V1 staging is the fallback when Experimental sleep staging is turned off (`PuffinExperiment.experimentalSleepV2Enabled`, default **on**).

Stages are approximations. EEG-free 4-class agreement tops out around 65–73% (Walch 2019). Deep minutes are the least reliable output. A 44-subject leave-one-subject-out check is why V2 is the default (kappa about 0.35 vs 0.03 for V1, deep recall about 55% vs 1%).

### Detection input

- Gravity (`GravitySample` x/y/z). Fewer than 2 samples → no session.
- Heart rate, used to confirm a still stretch is actually sleep.
- Optional: off-wrist intervals, the strap’s own band sleep-state, local timezone offset, a personal overnight HR baseline.

### Detection rules (Stage 0)

1. A sample is **still** when the gravity change is ≤ **0.01 g**.
2. A **15-minute** rolling window is “sleep” when ≥ **70%** of samples are still.
3. A gap longer than **20 minutes** breaks a run. Runs shorter than **15 minutes** are absorbed.
4. A session must be longer than **60 minutes**. A single run longer than **16 hours** is dropped (clock artefact), not truncated.
5. **HR confirmation.** Mean HR in the run must be ≤ day-median (or the personal overnight baseline) × **1.05**.
6. **Daytime guard** (local 11:00–20:00). A still stretch in that band must last ≥ **90 minutes** and its lowest 5-minute HR must be ≤ baseline × **0.95**. A continuation within **90 minutes** of an overnight chain is treated as the night’s tail, not a nap.
7. **Morning stillness.** A daytime block starting within **180 minutes** of overnight wake must dip to ≤ baseline × **0.90**, unless ≥ **60%** of its epochs are the strap’s own “asleep” band state.

Output of detection: one or more `SleepSession` spans `[start, end]`. A span is the **in-bed window**: it opens when the wrist goes still, which can be well before sleep. When sleep began is a staging output (below).

The **main night** is the learned-timing best block (habitual midsleep when known). Fragments separated by a short wake are bridged and scored as one night. Naps stay as their own sessions and are not folded into the night totals.

### Staging input (both recipes)

30-second epochs over `[start, end]`.

- Heart rate (per-second mean)
- Gravity / jerk
- R-R intervals (RSA respiration regularity in V2; RMSSD and raw-resp RRV in V1)
- V2 does **not** read the raw respiration ADC. V1 does, when the strap has one (WHOOP 4). WHOOP 5/MG has no resp ADC.

### V2 staging (default)

Per-night z-scores of HR, HR variability, and movement, plus:

- **Deep gate.** Deep is only eligible in the night’s lowest ~**25%** of 11-minute HR-flatness. Flatter HR supports deep.
- **Cycle prior.** Deep is boosted early (`1.2 × max(0, 1 − clock/0.55)`). REM rises with time-of-night and is penalized for the first **60 minutes** after a sustained sleep onset (5 minutes of non-wake).
- **Motion.** Jerk thresholds are relative to that night’s own median jerk, not a fixed g. A still wrist with a high HR is not called awake (the high-HR half of the awake vote is clamped off).
- **RSA regularity.** Regular breathing adds to deep and subtracts from REM (weight **0.6**).
- **Viterbi / HMM.** Sticky transitions. Wake goes to light, not straight into deep or REM. Base rates: light 50%, REM 22%, deep 15%, awake 10%.
- **Settled onset.** Sleep cannot begin before the wrist settles: the first **15 minutes** (30 epochs) in which at most **one** epoch moved. Everything before the first sleep epoch at or after that point is wake, and the REM guard above is measured from there. Lying awake in bed is still and low-HR, so the per-epoch terms read it as light sleep; what gives it away is a wrist that keeps shifting every few minutes. Against PSG (sleep-accel, n = 31): onset bias −11.1 → +0.4 min, MAE 11.1 → 5.6 min, pre-onset wake recall 28.8 → 80.0 %, kappa 0.371 → 0.399, no subject more than 15 min late. Only the start of the night moves. A night with no settled 15 minutes is left as staged.

Labels: `wake`, `light`, `deep`, `rem`.

### V1 staging (off by default)

Percentile bands inside the night, then a 5-epoch median smooth, then physiology rules (no REM in the first **15 minutes**; late deep is rewritten to light only if early deep already exists).

| Rule | Condition |
|---|---|
| Wake | movement fraction ≥ 0.15 and (high HR or, on a dense night, high HR variance) |
| Deep | still (movement ≤ 0.10), low HR (≤ 25th percentile), high RMSSD when measurable, respiration does not contradict depth |
| REM | still, activated cardiac, irregular respiration |
| Light | everything else |

### Sleep outputs stored on the day

From the main-night group only:

| Field | Meaning |
|---|---|
| `totalSleepMin` | asleep time (in-bed minus wake, lying awake before sleep included in wake) |
| `efficiency` | asleep / in-bed. A bridged gap between fragments is counted as awake. |
| `deepMin`, `remMin`, `lightMin` | stage minutes |
| `disturbances` | wake bouts inside the night, plus one if fragments were bridged |

The Sleep page shows **In bed** (the window start), **Asleep** (the first sleep epoch of the staged night) and **Woke**. A night with no staged timeline (an imported total) shows the window start as Asleep, as before.

`hrOnly` is true when the night had heart rate but no usable motion. Those nights can describe duration and stages. Their resting HR and HRV are left nil unless they are the only sessions that day.

---

## 3. Strain (Effort)

**What it is.** Cardiovascular load for the local calendar day, on a 0–100 log scale. The old WHOOP-like axis was 0–21; only the output scale changed. The curve is the same. `StrainScorer.effortValue(fromWhoopStrain:)` maps 0–21 imports onto 0–100.

**Source.** `StrainScorer.strain`. Default method is **Edwards**. Banister is opt-in (`noopBanisterEffort`, default off).

### Input

- The day’s heart-rate samples (`HRSample`: timestamp, bpm).
- **HRmax.** Manual override if set, otherwise Tanaka (2001): `208 − 0.7 × age`. If age is missing, `220 − 30`.
- **Resting HR.** That night’s resting HR if it exists, otherwise **60**.
- Sex, only for Banister.

### Gates

A score is returned once either:

- there are ≥ **600** HR samples (about 10 minutes at 1 Hz), or
- the series spans ≥ **600 seconds** and has ≥ **20** samples (sparse WHOOP 5/MG, which reports HR about every 30 s).

If HRmax ≤ resting HR, the score is nil.

### Edwards (default)

1. Heart-rate reserve: `HRR = HRmax − RHR`.
2. `%HRR = (HR − RHR) / HRR × 100`, clamped 0–100.
3. Each sample gets an Edwards zone weight (Edwards 1993) and is multiplied by the minutes until the next sample. A gap is capped at **2 minutes** so a dropout cannot invent hours of load.

| %HRR | Weight |
|---|---|
| ≥ 90 | 5 |
| ≥ 80 | 4 |
| ≥ 70 | 3 |
| ≥ 60 | 2 |
| ≥ 50 | 1 |
| < 50 | 0 |

Below 50% HRR, Edwards scores **zero**. A quiet day and a lot of light activity look the same.

4. Log map:

```
Effort = 100 × ln(TRIMP + 1) / ln(7201)
```

`7201` is chosen so 24 hours in zone 5 (TRIMP 7200) maps to exactly 100. Rounded to 2 decimal places.

### Banister (opt-in)

Banister 1991, per minute: `0.64 × x × e^(b·x)` where `x` is fractional HRR.

- Men: `b = 1.92`
- Women: `b = 1.67`
- Other / nonbinary: the Edwards path ignores sex; Banister uses the male coefficient unless sex starts with `f` (`logMapDenominator` checks that prefix).

A sedentary floor of **10% HRR** is subtracted per sample so sitting does not accumulate Effort. The log denominator is that method’s own 24-hour ceiling minus a full day of that floor, so 100 still means a theoretical maximum day.

### Display rule

Today’s ring shows `max(live recompute, stored daily row)` so Effort never visibly drops when the live stream is sparser than the stored day.

---

## 4. Rest

**What it is.** The 0–100 sleep-quality score. In code, `AnalyticsEngine.Rest`. It is also the “Rest quality” input to Charge (divided by 100).

**Source.** `AnalyticsEngine.Rest.composite`, called from `analyzeDay` after the main night is totaled.

### Input

| Input | Where it comes from |
|---|---|
| Total sleep time | main-night asleep seconds |
| In-bed time | sum of fragment spans, plus any bridged awake gap |
| Efficiency | asleep / in-bed |
| Restorative seconds | deep + REM |
| Deep seconds | deep only, for the adequacy factor |
| Sleep need (hours) | personalized need, below |
| Consistency | `VitalityEngine.sleepConsistency` over the trailing nightly durations |

Nil when asleep time is 0.

### Sub-scores (each clamped to 0–1)

| Piece | Weight | Definition |
|---|---|---|
| Duration | 0.50 | asleep seconds / need seconds, capped at 1 |
| Efficiency | 0.20 | asleep / in-bed |
| Restorative | 0.20 | `(deep+REM) / asleep / 0.50`, then × a deep-adequacy factor |
| Consistency | 0.10 | regularity in 0–1; missing → **0.5** |

**Deep adequacy.** Full restorative credit once deep is ≥ **13%** of asleep time. As deep goes to 0 the restorative term is scaled down toward **0.5** (it loses at most half of the 0.20 weight, about 10 points). If deep minutes are unknown, the factor is 1.

```
Rest = 100 × (0.50·duration + 0.20·efficiency + 0.20·restorative + 0.10·consistency)
```

rounded to 2 decimal places.

### Sleep need

- Default **8.0 hours** until there are **7** nights with a real duration.
- After that: the **75th percentile** of nightly hours (the less-restricted nights), not the mean.
- Floored at the age target: **9 h** under 18, **8 h** otherwise. A short sleeper’s need does not drift down toward their deficit.
- Capped at **9.5 h**.

### Consistency

Over nights with hours > 0, at least 3 nights:

```
consistency = clamp(1 − CV, 0, 1)
CV = population SD / mean
```

The live engine passes the last **28** nights. This is a duration-regularity proxy, not a full sleep-timing regularity index.

---

## 5. Respiratory rate

**What it is.** One breaths-per-minute number for the night, stored as `respRateBpm`.

**Source.** `AnalyticsEngine` chooses the source. Plausible band for anything that is published: **8–25** breaths/min (`SleepStager.respPlausibleRangeBpm`).

### Path A — device-measured rate (preferred when present)

Used for a strap that reports its own rate. Today that is the Oura ring’s `0x6A` breath samples, stored in milli-bpm and converted by `OuraRespScale.breathsPerMin`.

- Take samples whose timestamps fall inside a matched sleep session.
- They must span at least **1 hour** (`vendorRespMinSpanS = 3600`).
- Night value = **median** of those rates.
- Drop the night if the median is outside 8–25.

WHOOP nights pass no vendor rows, so they never take this path.

### Path B — RSA from R-R (WHOOP, and any night without a vendor rate)

`SleepStager.respRateFromRR`. This recovers the breathing modulation of beat-to-beat timing. It tracks a chest-band rate; it is not one.

Pipeline, per sleep session:

1. Keep in-bed R-R in 300–2000 ms.
2. Refuse the session if the stored intervals are not real beat-to-beat measurements (banked records, such as Oura IBI, where the sum of intervals is right but the individual values are not). Shuffling those values returns the same fake ~13.3 bpm.
3. Rebuild beat times by summing R-R. If the wall clock jumps ahead of the beats by more than **3 seconds**, that window is a splice and is skipped.
4. Resample the tachogram at **4 Hz**, subtract an **8-second** moving mean.
5. In each **5-minute** window, pick peaks at least **2.5 s** apart, keep breath intervals of **2.5–10 s** (24–6 bpm), rate = `60 / median(interval)`.
6. Session rate = median of those windows, then clamped to 8–25. NaN if fewer than 30 clean beats.

Night value = **median** of the finite per-session rates. Nil if none survive.

**Intraday respiratory rate (hosted worker only).** The nightly kernel above throws away every 300 s window that holds a splice, which on a daytime stream (runs of a minute or two between dropouts) is nearly all of them. The worker's one-minute series uses `SleepStager.respBreathTrack` instead: the same 4 Hz tachogram, 8 s detrend and 2.5–10 s breath band, but run per continuous run of beats (≥ 20 s of beat time, peaks within 4 s of a run's ends ignored, a beat > 30% from the median of its seven neighbours replaced by that median). The breaths of the trailing 2 minutes are pooled and the rate is `60 / median(interval)`, clamped to 8–25. A point needs ≥ 30 beats and ≥ 6 breaths in the window, ≥ 10 beats and ≥ 2 breaths in the current minute, ≥ 33% of the window inside usable runs, a still wrist (same ambulatory-share gate as HRV) and the same beat-accuracy gate as the nightly path. The nightly stored value is unchanged.

### Path C — raw respiration waveform (staging only, not the stored nightly rate)

`SleepStager.respRateAndRRV` peak-detects the 1 Hz resp ADC (WHOOP 4). Detrend, peaks ≥ 2 s apart, intervals 1.5–12 s, rate = `60 / median(interval)`, RRV = SD of intervals. V1 staging uses the RRV. V2 does not read this channel. The number stored on the day is Path A or Path B, not this one.

---

## 6. Steps

**What it is.** An estimate of daily steps from the strap’s cumulative motion counter, not a validated pedometer and not cloud parity.

**Source.** `StepsCounter.stepsInWindow`, scaled in `AnalyticsEngine`.

### Input

- `StepSample`: timestamp, cumulative `counter` (u16, `step_motion_counter`), optional `activityClass`.
- Counted over the **local calendar day**, not the night window.
- User calibration `stepTicksPerStep` (default **1.0**). Values below **0.5** are raised to 0.5 so a bad setting can at most double the total.

### Rules

1. Sort by time. Need at least 2 samples.
2. Increment = `(current − previous) mod 65536`.
3. A **bout block** is an increment of **6 to 20** ticks across **at most 2 seconds** (see below). It counts as is, whatever its activity class and whatever the rate.
4. Any other increment is rejected when it is &lt; 1 or ≥ **512**, when the elapsed time is not positive, or when the rate is above **4 ticks/second** (unless the gap is long enough that the 512 cap binds first).
5. If **any** sample in the window has an activity class, only **walk (1)** and **run (2)** increments count. Still (0) and unknown are dropped, and so is a bout block on a record that carries no class at all. A fully unclassed legacy window counts every plausible increment (old counter-only behavior).

Every rule looks only at one sample and the one before it. That is what lets the per-minute step series (`IntradaySeries.stepPoints`) add up to the day total however the day is cut into windows.

```
steps = round(ticks / stepTicksPerStep)
```

Nil when the result is 0.

### Bout blocks

A WHOOP 5/MG behaves as if it holds back the first steps of a walking bout, then credits about six of them in a single record (+6 or +7, rarely a few more) and publishes the rest of the bout at 1 to 4 ticks per second. The label on that record tracks its size: a block of exactly six is always **still**, and the label turns **walk** once the count passes six.

So neither earlier gate could keep a six. The class gate drops it, and the 4 ticks/second ceiling drops every block. Because the loss is one block per bout, it is additive rather than proportional: it grows with the number of short walks, and a single `stepTicksPerStep` multiplier cannot recover it. A 1,000-step continuous walk contains about one block, so calibrating by walking would not have exposed it either.

Evidence (one WHOOP 5/MG, 30 Sep to 3 Oct 2026, 1 Hz records):

- 898 increments of 6 or more ticks within one second. 587 were exactly 6 (all labelled still), 293 were 7 (256 walk, 37 still), 18 were 8 or more (all walk). None exceeded 15, and there were no jumps of 16 to 511 ticks within three seconds.
- A live walking test with stops of a few seconds between bouts produced six bursts. Each opened with a 6 or 7 tick block: 39 of the 81 ticks. The old gates kept the other 42.
- On 2 Oct the old rule gave 2,962 steps where an Apple Watch showed 4.8k. The blocks it dropped that day were 2,045 ticks.

The 6 to 20 range and the 2 second spacing are read off that data, not specified by the firmware. A counter reset drops the counter, so its u16 difference is far above 20 and is never mistaken for a block. Bouts shorter than six steps may not be credited at all (the test did not settle it), which no counting rule can recover.

WHOOP 4.0 does not emit `StepSample`, so its step total stays nil unless another source filled the stream.

---

## 7. Resting heart rate

**What it is.** The night’s resting HR in bpm, stored as `restingHr`. It is the RHR term in Charge and the HRR anchor for Effort and calories.

**Source.** `SleepStager.sessionRestingHR`, then the primary-session pick in `AnalyticsEngine`.

### Shipped definition

1. Prefer motion-staged sessions. Use an HR-only night only when nothing else exists.
2. **Primary session** = the **longest** session. Ties keep the first. A short nap cannot replace the main night. A device-provided resting HR on that same session wins if one was imported.
3. Inside that session, split HR into **5-minute** bins (the last bin is closed so the endpoint sample counts).
4. A bin may win only if it has ≥ **5** samples and its mean is ≥ **25 bpm**.
5. Resting HR = the **lowest** qualifying bin mean, rounded to an integer.
6. If no bin qualifies, fall back to the lowest of all bin means, then the mean of every sample in the session.

So the shipped number is a **five-minute floor** of the main night, not the average heart rate of the night.

### Shadow mean (not scored)

`PrimarySessionRestingHR` is the arithmetic mean of valid samples (30–220 bpm, at least 30 samples) in that same longest session. It is stored for comparison as `rhr_primary_session`. It does not feed Charge, Effort, or the baseline.

---

## 8. Calories

**What it is.** The day's energy expenditure: 24 hours of resting metabolism plus active energy read from a per-minute MET timeline that fuses several independent signals. Not calorimetry, not Apple or WHOOP cloud parity.

**Source.** `MetabolicEstimator.estimate` in `Packages/StrandAnalytics/Sources/StrandAnalytics/Energy/`, chosen by `AnalyticsEngine.analyzeDay(energyModel:)` (default `.fusion`). The previous HR-only estimator is `Calories` in `WorkoutDetector.swift` (`.legacyHR`), kept for A/B comparison and rollback and described at the end of this section. **The Android twins still run only the legacy estimator**, so Android and iOS / hosted-worker calorie totals differ until that port is done.

The value stored on the day (`activeKcalEst`) is **`restingKcal + activeKcal`**, the whole-day total. The field name is historical. `DayResult.energy` carries the same figures with the per-minute MET and confidence, the workout subset, coverage and the evidence mix.

### Resting and active energy are kept apart

- **Resting** = RMR / 1440 for every elapsed minute of the day, whether or not the strap was worn. Metabolism does not stop when a sensor does. RMR is the wearer's measured value (Settings, accepted in 800–5000 kcal/day) when set, otherwise the revised Harris–Benedict equation below (`RmrSource` records which). A day still in progress counts resting energy up to now (`energyAsOf`) and projects the rest in `projectedTotalKcal`.
- **Active** = `max(0, MET − 1) × 3.5 × kg / 200` kcal per minute, summed only over minutes with evidence. A minute with no usable heart rate or motion, or an off-wrist minute, contributes no active energy: a gap is never filled with "sedentary" nor extrapolated from its neighbours, and the uncovered minutes are reported (`gapMinutes`, `restingGapKcal`). Sleep is RMR-level (1 MET). A sleep interval is somebody's claim about a time span, so a minute whose heart rate is 25 bpm above the sleeper's own resting level is not treated as sleep.
- **Workouts are labels on the same timeline**, not a second source: `workoutKcal` is the part of `activeKcal` that falls inside workout windows and is never added again.

### The per-minute estimate

For every minute the estimator builds an **activity belief** and then weighs independent **evidence families**, each expressed as a MET with a one-sigma in METs:

1. **Activity belief.** From the existing activity classifier's epochs when the day has them (the classifier is read, never retrained or reimplemented here); otherwise from the step counter's cadence and class; otherwise from gravity-removed motion magnitude. Each source carries its own confidence. The belief is a probability over stationary / walking / running / other movement / unknown.
2. **Motion family.** WristMET and the wrist CNN when raw IMU exists for the minute (below), step cadence (walking and running equations of height and cadence), and, only when no model speaks, a motion-magnitude proxy. Estimators that read the same wrist acceleration share error, so their combined variance is inflated by `1 + 0.5 (k − 1)` rather than treated as independent, and the family is never vaguer than its best member. Cadence and wrist motion cannot see grade, stairs, carrying or a hand on a rail: when heart rate stays well above the motion estimate for a sustained period in a context where movement should support it, the motion family's sigma is widened (upward only, up to 2.5×, ramping over 1–3 METs of excess and 4–12 minutes of elevation).
3. **GPS family.** ACSM walking / running equations from ground speed and grade, when the day has a route.
4. **Cardiac family: continuous, not a gate.** `MET = 1.2 + (METmax − 1.2) · x^1.4`, where `x` is the share of heart-rate reserve above the wearer's **quiet-awake baseline** (a low percentile of the day's own quiet awake minutes, clamped to resting + 3…25 bpm), after a per-activity allowance for non-metabolic elevation. `METmax` comes from the Uth ratio, clamped 8–16. Heart-rate slope leads the reading (40 % of the slope, ±8 bpm), recovery from a recent peak widens the sigma, and the sigma is tight at baseline (0.25 MET) and widens to the light-intensity scatter over the first 12 % of reserve, so a minute at baseline reads as rest while a stroll is not erased. Sustained elevation (8+ minutes) narrows it; elevation with no movement behind it is narrowed less (0.92 vs 0.8 of sigma).
5. **Activity-aware routing.** Each family's sigma is multiplied by an activity-dependent factor, blended over the activity belief (`EvidenceRouter`). WristMET gets its tightest sigma for stationary and walking minutes, 1.25× for running, and 1.8× for other movement (cycling, lifting and similar, where the arms say little about the legs' work); the wrist CNN's factors are 1.0 / 1.0 / 1.2 / 1.6. Heart rate gets the tightest sigma in running (0.85×) and other movement (0.9×), a wider one when the person is still or walking (1.1×), and a per-activity allowance for non-metabolic elevation (8 bpm when stationary, 3 walking, 2 running). The result then updates an **activity-conditional prior**, a Gaussian mixture built from Compendium of Physical Activities values: stationary 1.25 ± 0.20 METs, walking 3.4 ± 0.9, running 9.8 ± 1.8, other movement a wide 2.3 / 5.0 mixture. Every activity keeps a heavy-tail component (stationary: 14 % at 4.0 ± 2.2) so strong, sustained physiological evidence can overrule a still wrist instead of a gate deciding for it. Inside a detected workout the prior is blended at 0.6 with that workout class's Compendium value. Elevated heart rate without supporting movement is therefore reduced, never zeroed and never credited as full exercise.

### Motion models (WristMET, wrist CNN)

Both need raw wrist IMU, which no stored day contains, so they run offline in `Tools/EnergyModels` (numpy only) and hand Swift one record per minute (`energy-motion-evidence-v1`, `MotionEvidence.swift`). **A day without raw IMU has no motion-model evidence; its estimate runs on heart rate, the step counter, gravity motion and the activity context, and its confidence says so.** WHOOP 4.0 and older straps are heart-rate only.

- **WristMET** (Wei et al., Sci Rep 2025) is the primary motion estimator. The authors publish no trained weights, so it was retrained from their public code (MIT) and data (Zenodo 14858226, CC BY 4.0). It did not reproduce the paper's accuracy: leave-one-participant-out 60 s RMSE is 0.76 MET (paper 0.28), 0.32 on sedentary windows and 1.31 on non-sedentary ones. Its 26 training participants are aged 25–64 with BMI 30.5–46.2, so a younger or leaner wearer is out of its cohort and `demog_ood` widens the sigma. The sigma used is the classifier-probability-weighted blend of 0.32 and 1.31, widened by the signal and demographic out-of-distribution scores. The accelerometer axis mapping is assumed to be the identity and is recorded in the evidence file's provenance.
- **Wrist CNN** (Nawaratne et al., J Sports Sci 2021) is supporting evidence: its labels are a waist-ActiGraph proxy, not calorimetry (0.74 MET RMSE against those labels on the public sample), its weights have no licence and are fetched at a pinned commit and never committed, and by default it only runs on minutes WristMET calls non-sedentary (its regression head reads about 1.4 MET on motionless input).
- The two run independently; neither sees the other's output. Disagreement lowers confidence instead of being averaged away.

### Temporal consistency

The per-minute estimates go through a Kalman filter with a Rauch–Tung–Striebel smoother: random-walk process noise of 0.10 MET/min while the belief is steady, up to 2.5 MET across an activity transition (scaled by the size of the belief change), outlier innovations beyond 3 sigma down-weighted, and a hard slew limit of 4 METs/min. Metabolic cost therefore moves with the physiology of oxygen-uptake kinetics rather than jumping minute to minute.

### Confidence

Each minute has a confidence in 0.05–1: the product of components raised to weights (agreement between estimators by a Cochran-Q test, activity-belief confidence, heart-rate and IMU quality including missingness, distance of each model's input from its training distribution, physiological plausibility, and the posterior's precision). The weights sum to more than the normalizer on purpose, so one poor component pulls the product down. The day's confidence is the active-energy-weighted mean of the minutes' confidences, discounted by coverage; it describes the active estimate, since resting energy is the equation or the measurement.

### Verifying it

`Tools/EnergyBench` replays exported days through the legacy estimator and this one and checks, from independently defined bouts, that sustained moderate activity below the old heart-rate gate is now credited and that light days are not over-counted (PAL ≤ 1.55). It has no ground truth; it checks plausibility and parity with the app, not accuracy.

**Known limits.** No separate thermic-effect-of-food or NEAT term; the equation RMR can be off by hundreds of kcal for an individual, which is why a measured value is accepted; days with no detected sleep price the night at quiet-awake (about +160 kcal) because nothing says the wearer was asleep; the heart-rate curve is population-level without individual calibration.

### Legacy HR-only estimator (`energyModel: .legacyHR`)

An HR-based energy estimate: revised Harris–Benedict resting metabolism plus Keytel 2005 active energy, resting energy counted only over the time the strap observed.

### Profile defaults when a field is missing

Weight 70 kg, height 170 cm, age 30. Sex selects coefficients: male, female, or the midpoint for nonbinary / anything else.

### Resting rate

Revised Harris–Benedict BMR (kcal/day), divided by 86400 to get kcal/second.

```
BMR = α + β·weightKg + γ·heightM − δ·age
```

| | α | β (per kg) | γ (per metre) | δ (per year) |
|---|---|---|---|---|
| Male | 88.362 | 13.397 | 479.9 | 5.677 |
| Female | 447.593 | 9.247 | 309.8 | 4.330 |
| Nonbinary | midpoint | midpoint | midpoint | midpoint |

### Active rate

Keytel 2005, kJ/min, converted to kcal/s by dividing by **251.04** (60 × 4.184). HR is capped at HRmax.

When resting HR is known, VO₂max is estimated with Uth 2004, `15.3 × HRmax / RHR`, and the fitness-adjusted Keytel equation is used. Without a resting HR, the fitness-blind equation is used.

**Day gate** (whole-day total): active energy is added only when HR ≥ resting + **50%** of HRR. Below that, only BMR is counted. The 50% gate exists because applying the exercise equation to ordinary walking HR over a whole day over-counted by about 1000 kcal.

**Workout-bout gate:** a detected or manual workout uses **30%** HRR instead, and each sample is weighted by the gap to the next sample, capped at the detector’s merge gap (150 s).

### Day integration

- Resting energy is integrated over the time the HR stream actually covers. A gap may carry BMR for at most **60 seconds**. The whole day is capped at 86400 s.
- Active energy above the BMR rate is added only on samples at or above the 50% HRR gate, and only for the inferred sample cadence (median positive gap, also capped at 60 s). A dropout does not get credited as exercise.
- HRmax and resting HR are the same values Effort uses (Tanaka or override, and that night’s resting HR or 60).
- Nil when the calendar day has no HR samples.

---

## 9. Activity class (what the wearer was doing)

**What it is.** One canonical, machine-readable label per moment (`ActivityClass`, taxonomy `act-class-2`) with a confidence, built on the ActivityContext decoder (`hsmm-1.3`, ontology `v2.0`). It is the label code and downstream systems branch on. The on-screen wording ("Desk sitting", "Brisk walking") stays a view for people. This is a behavioural context, not a medical measurement.

### Input

The decoder reads what the strap actually sends: gravity and dynamic acceleration, the cumulative step counter, heart rate (scaled by the profile's HRmax), the detected nights (each night's in-bed window and its staged sleep epochs, so lying awake in bed is awake and in bed, never asleep), logged workouts, and wrist-on / wrist-off events. When raw IMU covers the time, the HART motion encoder adds gait rhythm and a named activity. A WHOOP 5/MG records it on its own (one minute in every three by default, or continuously), the server runs HART over it (100 Hz resampled to 30 Hz, 4 s windows) and the phone fetches the windows back for its decoder, so they reach a stretch a few minutes after the strap's own streams do and the day is re-decoded when they arrive. HART tells stationary, walking, running and other movement apart; it does not tell sitting from standing or lying. Every five seconds it publishes three independent probability heads (posture, locomotion, arm behaviour) and never forces a class.

### Classes

Only classes the sensors can tell apart with reasonable confidence are in the taxonomy. `ActivityClass.capabilities` states the evidence and the limit of every one, and a test fails if a class is added without that statement.

| Code | Established by | What it cannot tell apart |
|---|---|---|
| `off_wrist` | wrist-off events, loss of pulse contact (a hard gate, confidence 1) | a quiet strap on a table is never taken as on-wrist evidence |
| `sleeping` | a sleep epoch of a detected night (the sleep stager's call) and stillness; the posture head's lean does not override it | naps outside a detected session read as `lying_down`; lying awake in bed is `lying_down`, not `sleeping` |
| `lying_down` | awake inside a detected night's in-bed window ("Resting in bed"), or recumbent posture reached through a lying-down movement signature | no absolute wrist-orientation cue is used, so a quiet daytime lie-down is not seen |
| `sitting`, `sitting_desk` | stationary wrist whose posture head leans seated; `sitting_desk` adds desk-like hand activity | the wrist cannot see body height: sitting vs standing is a likelihood, never a measurement |
| `standing` | stationary wrist whose posture head leans upright | needs a committed upright lean, otherwise the state is `stationary` |
| `stationary` | awake, on the wrist, no movement | deliberately unresolved between sitting and standing |
| `fidgeting` | bursty low-amplitude movement without gait | tremor, restless legs and gesturing overlap |
| `light_activity` | whole-body movement without a sustained gait, or a posture-change signature | chores, pacing and rearranging are not told apart |
| `walking` | step cadence about 70-125/min with steady movement; stairs are reported as walking | confident gait needs the step counter (WHOOP 5/MG) or raw IMU rhythm; WHOOP 4.0 relies on movement shape |
| `brisk_walking` | cadence about 105-150/min, higher intensity, raised heart rate | overlaps ordinary walking near 105-125/min (the runner-up says so) |
| `running` | cadence about 135-210/min with high intensity | treadmill vs outdoor and pace |
| `cycling` | only when the motion encoder or a cycling workout names it | never inferred from heart rate and stillness: pedalling leaves almost no wrist or step signature |
| `vigorous_activity` | sustained heart rate of about 45% of reserve or more with vigorous arm movement and no gait, or a logged workout | the activity itself (rowing, lifting, HIIT, a ball sport) is not named |
| `unknown` | conflicting or missing evidence; confidence 0 | carries no claim, the best guess is the runner-up |

### How a class and its confidence come out

The class is the display rules' reading of the three heads at that instant, without the label's 10-30 s hysteresis (a stored class must not lag the evidence it describes). The confidence is the belief mass of the body state the class names: seated for `sitting` and `sitting_desk` alike, the walking family for `walking` and `brisk_walking`, recumbent for `sleeping` and `lying_down`. The runner-up is the best alternative outside that family. `evidenceQuality` is the decoder's own overall confidence (sensor coverage, channel agreement, warm-up), so a confident class over thin evidence is visible as such.

### Persisted intervals (`activityContextInterval`)

Decoded runs become timestamp-aligned intervals: one row says "from `startTs` to `endTs` (half-open) the wearer was `activityClass`, with this confidence". Neighbouring runs of the same class, sleep and wear state (gap of at most 10 s) merge, a non-movement fragment shorter than 10 s between two stretches of one situation is absorbed (a movement fragment is never folded away), and a stretch longer than 15 minutes is cut into near-equal parts so every row's statistics stay local.

Beside the label each interval stores the measurements that have no per-timestamp row to join against: mean, min, max and slope of heart rate (slope needs 30 samples over 90 s), RMSSD with the clean beat count (at least 20 beats and 60 s, never during gait or exercise because motion corrupts beat timing), respiratory rate from RSA with its breath count (still wearer only, at least 6 breaths), step ticks and cadence (at least 20 s of stepping), motion intensity, and the head tops, sleep and wear state. A value that could not be measured is NULL, not zero.

Everything that is recorded per sample (heart rate, R-R, SpO2, skin temperature, respiration, gravity, steps) is **not copied**. It joins to its interval through the `*Ctx` SQL views (`hrSampleCtx`, `rrIntervalCtx`, `spo2SampleCtx`, `skinTempSampleCtx`, `respSampleCtx`, `gravitySampleCtx`, `stepSampleCtx`, `ppgHrSampleCtx`), which add `ctxClass`, `ctxConfidence`, `ctxRunnerUp`, `ctxEvidenceQuality`, `ctxPosture`, `ctxLocomotion`, `ctxArmBehavior`, `ctxSleep`, `ctxWear`, `ctxIntensity`, `ctxStartTs`, `ctxEndTs` by an as-of lookup on the interval table's primary key. A sample in a gap (strap off, stretch not decoded yet) still appears with NULL context. `activityContextDayClass` totals seconds per class per day. A derived time series (the per-minute energy estimate, intraday HRV or respiratory-rate buckets) is not copied or stored per interval either: it joins by its own bucket timestamp, in memory with `ActivityContextLookup` or from the store with `activityContextInterval(deviceId:at:)`.

The tables are derived and regenerable. A day is written once it is closed and is re-checked while it is recent; the ledger row (`activityContextDay`) records the taxonomy, decoder and interval versions so a version bump re-derives stored days.

---

## 10. Stand reminder

**What it is.** A reminder to stand up, decided over a rolling window rather than a single elapsed-time counter (`StandReminderEngine`).

**Rule.** Look at the previous 50 minutes (the existing "minutes before the first nudge" setting, 15-120 in steps of 5) ending at the newest second the strap has reported. Add up every second of meaningful standing or movement inside it. If the total reaches 60 seconds, there is no reminder, however it was spread; otherwise the wearer is eligible.

| Last 50 minutes | Reminder |
|---|---|
| 2 minutes of walking | no |
| 70 s of standing or moving | no |
| six 12-second walks to the kettle (72 s in total, never in one block) | no |
| 20 s of movement | still eligible |
| 50 minutes seated | yes |

**What counts.** The canonical class of each stretch, plus the step counter. Movement: `standing`, `light_activity`, `walking`, `brisk_walking`, `running`, `cycling`, `vigorous_activity`, and any stretch where steps were counted even if the heads read seated (carrying a laptop across the room barely moves the wrist). A bout must last 10 s to count and moving seconds no further than 5 s apart are one bout, so a gesture cannot add up to a minute by itself, and a class needs a belief of at least 0.25. Sedentary: `sitting`, `sitting_desk`, `stationary`, `fidgeting`. Neither: `lying_down` (a couch nap is not buzzed awake), `unknown`, asleep and off-wrist, which are also removed from the window's coverage so "just put it on" is not "sedentary for 50 minutes".

**Other gates.** At least 85% of the window observed awake and on the wrist, at least 80% positively sedentary, a 30 s hold-off after movement ends, the existing re-nudge spacing, active and quiet hours, the notification master switch and "only when worn". Data older than 20 minutes is not acted on.

**When it runs.** History reaches the phone in offloads, so the rule is evaluated after each completed backfill and the window ends at the newest data, not at the clock. A reminder can therefore arrive up to one offload after the window was already sedentary: about 15 minutes at the default cadence, about a minute with the 5.0/MG "fresh data" cadence in cloud mode, and 45 to 60 minutes while the strap is low on battery or Low refresh is on. The decision and the reason ("Stand reminder: remind (50-min window: 12 s standing or moving, 98% observed, 91% seated)") go to the strap log. The legacy gravity-only `SedentaryDetector` is kept and tested, but the app no longer sends reminders through it.

**What it cannot see.** A wrist cannot tell sitting from standing still, so someone who stands motionless is credited only when the posture head leans clearly upright. The engine errs toward staying quiet whenever it is unsure (unknown, lying down, thin coverage), because a reminder that arrives while the wearer has been up and about is the failure people stop trusting.

---

## Charge (uses several of the above)

**What it is.** The 0–100 recovery score (`RecoveryScorer`). Approximate, HRV-dominant, normalized to your own baseline. Not WHOOP’s recovery model.

**Required or it returns nil:** tonight’s HRV, tonight’s resting HR, and a usable HRV baseline (≥ 4 nights). Cold start can display the population mean **58** as a placeholder; that placeholder is not a computed score.

### Weights

Missing optional terms are dropped and the remaining weights are renormalized.

| Term | Weight | Direction |
|---|---|---|
| HRV vs baseline | 0.55 | higher HRV → higher Charge |
| Resting HR vs baseline | 0.20 | lower RHR → higher Charge |
| Rest quality | 0.15 | Rest score / 100, centered at 0.85 with scale 0.12 |
| Respiration vs baseline | 0.05 | lower rate → higher Charge |
| Skin-temp deviation | 0.05 | any drift, hot or cold, lowers Charge (`−\|dev\| / 1°C`) |

Two more optional terms (0.05 each) exist in the scorer — overnight RHR slope, and yesterday’s Effort vs its baseline — and only apply when the caller supplies them. The daily pass as wired today passes HRV, RHR, resp, Rest, and skin temp.

### Score

Each term is a robust z-score, `(value − mean) / (1.253 × spread)`, with the sign flipped for “lower is better” metrics. Weighted average z goes through:

```
Charge = 100 / (1 + exp(−1.6 × (z − (−0.20))))
```

clamped to 0–100. At z = 0 this is about **58**.

Bands: red &lt; 34, yellow &lt; 67, green otherwise.

A low-HRV + low-RHR pattern is detected as a possible parasympathetic-saturation case and logged. It does **not** change the number.

---


## 11. Sleep analytics (descriptive night detail)

Additive descriptive document (`daily.sleep_analytics_v1` in the v2 hosted snapshot) over the day's
resolved MAIN-NIGHT group — the same fragments the sleep aggregates use (`DayResult.mainNightBlocks`),
never a re-picked longest session. Spec: `docs/sleep-analytics/spec.md` (the implementation
authority). **Estimates and observations only**: a stage-derived number is the existing stager's
estimate, "observed" means observed in the supported input/label record — never an independently
observed PSG state. No clinical SOL, abnormality or risk is computed. Canonical sleep detection,
staging, Rest/Charge, canonical RMSSD and recovery are UNCHANGED.

### Versions

`schema_version` 1, `algorithm_version` `nara-sleep-analytics-2`, `config_version` `v2` (spec-02: the
thermal bins are built once so the post-wake slope exists; pNN50, stage-associated movement and the
30-minute morning response were added; `-1` documents still decode)
(versioned engineering gates in `SleepAnalyticsConfig`; fingerprint = SHA-256 over fragment
ids/bounds/sources/edit lineage + stage source version + config gates + input revision).

### Normalization (one pass; every group derives from it)

Half-open `[start, end)` intervals, elapsed UTC seconds, clipped to each effective fragment.
Invalid spans discarded and counted; exact duplicates collapsed; same-label overlaps unioned;
**conflicting overlaps become `unknown` over the conflict** (a partially-conflicted native epoch is
unknown as a whole — never absorbed by the epoch majority). Labels map through the shared
vocabulary; nothing unmapped is invented (no N1/N2 from light, no light/deep from NREM). Native
30-second epochs carry an input-support mask: an epoch is label-supported with ≥15 distinct
seconds of valid HR-or-gravity evidence (≥50% for a clipped final epoch), and explicit off-wrist
intervals override support; unsupported native epochs are `unknown`. Timed external hypnograms keep
their real resolution with `sensor_support_unknown`; totals-only imports carry minutes and
manufacture no timeline. Inter-fragment gaps stay `inferred_inter_fragment_awake` — never sensor
coverage, bouts or transitions. No transition or bout joins across fragment boundaries even when
timestamps touch. The epoch transition matrix is reconstructed only where the native grid
alignment is established (`epochAlignmentEstablished`); a misaligned (edited) start withholds it.

### Groups

| Group | What it reports | Primary gates |
|---|---|---|
| `continuity` | Observed asleep/WASO (strictly inside the sleep period), the canonical inferred gap-awake contribution (reported separately) + the combined estimate (explicitly partial), onset delay from the window start (boundary estimate when the prefix is unobserved), REM/deep latency FROM SLEEP ONSET (YASA's recording-start convention documented; null `onset_not_observed`/`no_observed_rem`), longest observed sleep bout with censoring flags, complete awakenings vs censored wake stretches, all sleep→wake transitions incl. terminal wake | Complete stage: ≥95% label-supported; native also ≥95% input-supported. Primary per-hour rate also needs ≥30 min observed asleep; counts always exist below gates |
| `stage_dynamics` | Per-label union seconds (totals-only fragments join as partial label summaries), per-label bouts (complete vs censored; median + nearest-rank p90 of complete bouts), the 4×4 native epoch transition matrix (rows origin/cols destination `[wake, light, deep, rem]`, self-transitions included, NULL probability rows for absent origins, eligible pairs, stage changes) | Quantiles need ≥3 complete bouts; matrix only for native, aligned sources; coarse sources expose real-resolution bout changes instead |
| `movement` | Wrist movement from 1 Hz gravity adjacencies (same fragment, valid samples, consecutive seconds, not off-wrist): moving seconds/percentage, movement bouts, immobility bouts (complete vs censored), longest/median/p90 immobility. `stage_movement`: each classified adjacency joined to the normalized stage label at its second (unknown stays unknown; a bout counts toward the label of its first moving second), with `stage_movement_note = stages_may_depend_on_motion` | Primary rate: ≥80% eligible coverage + ≥30 observed minutes. Threshold = the shared stager stillness threshold (0.01 g). A device-specific movement proxy — never sleep/PLMI/posture, and NOT kRA/kAR/SFI |
| `thermal` | Qualified UTC-minute bins are built ONCE over `[min(first fragment start, onset−60 min, end−30 min), end+30 min)`; the nightly minute-median temperature (median/IQR/p95−p05) uses only the in-fragment subset, the pre-onset OLS slope `[onset−60 min, onset)` and the post-wake slope `[end, end+30 min)` their own subsets, against elapsed unix time (mean-centred OLS; DST-immune), with equilibration exclusion after a verified re-wear event | ≥30 valid minutes + ≥80% eligible-minute coverage for the summary; slopes need ≥45/60 and ≥20/30 valid minutes, no missing run > 5 min; pre-onset needs an OBSERVED onset. Approximate wrist temperature — no core temperature/DLMO/circadian phase |
| `prv_diagnostics` | Poincaré SD1/SD2 (direct pair space, ddof=1) per UTC-aligned 300-second window entirely inside one fragment; nightly values are the MEDIANS of eligible windows; ratio = ratio of the two summaries (null on zero SD2). pNN50 (`pnn50GapAware_original_adjacency_v1`) on exactly the SD1/SD2 pair set: per window and pooled nightly 100·ΣNN50/Σpairs, with the pair denominator | ≥200 valid adjacent pairs, ≥90% union interval-duration coverage (from beat-duration spans, not summed RR), ≤5% rejection over original deduped observations, resolved (ts, seq, ord) timing. PRV from an optical source — never ECG-equivalent; SD1 is usually redundant with RMSSD |

`morning_response` (`morning-response-1`): one-minute HR (median of plausible seconds, ≥ 30 s),
skin-temperature (the thermal group's own minute bins) and movement (moving 1 s gravity steps, ≥ 30
adjacencies, no off-wrist) curves over `[end − 30 min, end + 30 min)` around the EFFECTIVE window end,
each with its own coverage, before/after medians and a change that needs ≥ 20 valid minutes per side.
A response around a detected boundary — not awakening physiology.

### Missing data

Every metric is `value`/`unit`/`status`/`reason`: `available`/`partial`/`unavailable`/`disabled`
with the closed reason vocabulary (spec §8). JSON null is explicit and never a fabricated zero;
NaN/Infinity never reach the wire (finite-by-sanitization). Counts can be zero with qualifying
observed exposure. An unavailable group carries its own reason and never blocks the others or the
canonical score (the worker attaches the document in a bounded do/catch; a failure withholds only
this document). Per-group quality carries fragment span, observed/unknown seconds, input- and
label-supported fractions, inferred gap seconds, source resolution and stream counts
(received/valid/duplicate/rejected).

### Freshness and app readback

The worker records the claim's `input_revision` and the deterministic fingerprint; the outer hosted
`inputRevision`/`resultRevision` own freshness. The app decodes `daily.sleep_analytics_v1`
non-fatally (absent/unsupported version → old behavior preserved; rides the raw snapshot disk
cache, per-owner isolated) and renders the Sleep details section only when the document's
fragments still match the current main-night group (staleness guard; a stale pre-edit document is
withheld and the existing invalidated hosted refresh is requested).

## Where the code lives

| Algorithm | File |
|---|---|
| Day assembly | `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift` |
| HRV cleaning + RMSSD | `HRVAnalyzer.swift` |
| Sleep detection + V1 staging + session RHR/HRV + RSA | `SleepStager.swift` |
| Sleep staging V2 (default) | `SleepStagerV2.swift` |
| Rest composite | `AnalyticsEngine.Rest` in `AnalyticsEngine.swift` |
| Sleep need / consistency inputs | `AnalyticsEngine.Rest.personalizedNeedHours`, `VitalityEngine.sleepConsistency` |
| Effort | `StrainScorer.swift` |
| Charge | `RecoveryScorer.swift` |
| Baselines | `Baselines.swift` |
| Steps | `StepsCounter.swift` |
| Calories (default) | `Packages/StrandAnalytics/Sources/StrandAnalytics/Energy/` (`MetabolicEstimator.swift`, `EnergyFusion.swift`, `MetabolicPriors.swift`, `EnergyConfig.swift`) |
| Calories (legacy HR-only) | `Calories` in `WorkoutDetector.swift` |
| Motion-model evidence (WristMET, wrist CNN) | `Tools/EnergyModels`, decoded by `Energy/MotionEvidence.swift` |
| Calorie evaluation harness | `Tools/EnergyBench` |
| Primary-session RHR shadow | `PrimarySessionRestingHR.swift` |
| Live wiring (which flags are on) | `Strand/Data/IntelligenceEngine.swift`, `Strand/BLE/PuffinExperiment.swift` |
| Activity class taxonomy + classifier | `ActivityContextClass.swift` |
| Activity intervals + per-interval physiology | `ActivityContextInterval.swift`, `ActivityContextInterval+Store.swift`, `ActivityContextAggregate.swift` |
| When a day is written | `ActivityContextMaterialization.swift`, `Strand/Data/ActivityContextCoordinator.swift`, `Strand/Data/Repository+ActivityContextStore.swift` |
| Stored context (tables, views) | `Packages/WhoopStore/Sources/WhoopStore/ActivityContextStore.swift`, `ActivityContextViews.swift`, migration `v48-activity-context` |
| Stand reminder | `StandReminderEngine.swift`, `Strand/Data/InactivityPrefs.swift` |
| Sleep analytics (document, groups, gates) | `SleepAnalyticsV1.swift` (contract), `SleepAnalyticsNormalization.swift`, `SleepAnalyticsContinuity.swift`, `SleepAnalyticsStageDynamics.swift`, `SleepAnalyticsMovement.swift`, `SleepAnalyticsThermal.swift`, `SleepAnalyticsPrv.swift`, `SleepAnalyticsComputation.swift` |
| Sleep analytics worker attach | `Tools/CloudWorker/Sources/frwhoop-worker/SleepAnalyticsAttach.swift`, `DayScoring.swift` |
| Sleep analytics app decode + section | `Strand/Push/ServerScoreRepository.swift` (`HostedDayResult.sleepAnalytics`), `Strand/Screens/SleepAnalyticsSection.swift` |
| Coach access to the context | `Strand/Coach/CoachActivityContext.swift` (`get_activity_context`) |
