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

- No frequency-domain HRV (HF, LF, LF/HF) in the shipped score. `HRVFreqDomain` exists but is not the nightly number.
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

Output of detection: one or more `SleepSession` spans `[start, end]`.

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
| `totalSleepMin` | asleep time (in-bed minus wake) |
| `efficiency` | asleep / in-bed. A bridged gap between fragments is counted as awake. |
| `deepMin`, `remMin`, `lightMin` | stage minutes |
| `disturbances` | wake bouts inside the night, plus one if fragments were bridged |

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

**What it is.** An HR-based energy estimate: revised Harris–Benedict resting metabolism plus Keytel 2005 active energy. Not calorimetry, not Apple or WHOOP cloud parity.

**Source.** `Calories` in `WorkoutDetector.swift`.

The value stored on the day (`activeKcalEst`) is **`restingKcal + activeKcal`**, the whole observed-day total. The field name is historical.

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
| Calories | `Calories` in `WorkoutDetector.swift` |
| Primary-session RHR shadow | `PrimarySessionRestingHR.swift` |
| Live wiring (which flags are on) | `Strand/Data/IntelligenceEngine.swift`, `Strand/BLE/PuffinExperiment.swift` |
