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
- **Intraday series (hosted worker only).** The scoring snapshot's `daily.hrv_series` holds one RMSSD per **15-minute** slot of the local day (`{slot_s, points: [[slotStartUnix, rmssd, cleanBeats]], context: [...]}`), recomputed on every re-score. A slot needs ≥ 60 clean beats, coverage ≤ the over-count ceiling, and the spot-reading rejection limit. Daytime wrist RMSSD is artifact-prone, so this series is informational and never feeds Charge or baselines.
  - **Per-slot context (D6-14).** An additive `context` array has one entry per point, in the same order: `{slot_s, weak, reasons, moving_share, unknown_share, clean_coverage, post_activity}`.
    - The shares come from the same full-support join as `contexts.hrv_slots` (`ActivityContextJoin.hrvSlotContexts`, section 9f), over the day's published activity epochs.
    - `reasons` can hold these flags:
      - `movement`: walking + running + other movement is ≥ 0.25 of the slot.
      - `unknown_context`: the unknown share is ≥ 0.5.
      - `sparse_beats`: clean beats × mean NN is under one third of the slot.
      - `context_pending`: no published activity epoch overlaps the slot, or the slot runs past the newest published epoch and is mostly uncovered.
    - A slot with `movement`, `unknown_context` or `sparse_beats` is `weak`. `context_pending` alone never makes a slot weak: the activity lane has not described it yet, which is not evidence against the reading. The app also treats a point whose only reason is `context_pending` as not weak, which covers older worker builds.
    - Points are never dropped. The Today chart (`HrvSeriesChart`) draws a weak point hollow and faded, keeps it out of the line and the "Latest" value, and explains why in a caption. A pending point is drawn normally, with a quiet caption that activity context is not yet available. A snapshot without `context` renders as before.
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

## 9. Activity class and measurement context (what the wearer was doing)

**What it is.** One canonical, machine-readable label per moment (`ActivityClass`, taxonomy `act-class-4`) with a confidence, built on the ActivityContext decoder (`hsmm-1.9`, ontology `v2.0`). Code and downstream systems branch on this label. The on-screen wording ("Desk sitting", "Brisk walking") is a view for people. Decoded runs become stored intervals (`ctx-int-2`), and physiology joins to them by time. This is a behavioural context, not a medical measurement.

The same decoder runs in two places. The phone decodes each local day from its own streams (`ActivityContextCoordinator`). The worker decodes the day from the stored streams plus the activity service's window outputs and publishes the document to `public.activity_context_days` (`ActivityContextDays`).

### 9a. Sources, where they run, and who decides what

| Source | Where it runs | Status in the code | What it contributes |
|---|---|---|---|
| Strap streams: gravity, dynamic acceleration, step counter, heart rate, wrist-off / wrist-on events | Phone and worker decoder | Always on | Movement shape, gait cadence, forearm orientation, the exertion level, wear |
| Motion features (`imu-feat-2`, per window) | Activity service on the server, from raw IMU | On when raw IMU exists | Gyro RMS, jerk, cadence band. Dropped if the service's schema differs from the build's |
| HART | Activity service on the server | On when raw IMU exists | 100 Hz raw IMU resampled to 30 Hz, 4 s windows on a 2 s hop. Per-window activity probabilities; when the service sends them, a fine 18-activity distribution. The phone fetches the windows back and re-decodes the day |
| Inertia-1 motion heads | Worker only | Dormant. The decoder default is `motionHeads = nil`, and the phone never sets it. On the worker it runs only when `FRWHOOP_INERTIA_ENABLED` is on and a bundle is configured, in shadow or candidate mode, and writes to its own table (`activity_motion_heads_days`). Published day documents are byte-identical with or without it | Nothing in production output |
| ElderNet gait | Worker (shadow or candidate, env-gated); phone decoder | The phone uses ElderNet windows as decoder evidence only from days the server ran in a non-shadow mode, with the pinned model version and weights digest (`GaitWindowStore.evidenceConfig`). The worker's published documents never use it | Walk vs brisk-walk split and gait metrics, under a shared accelerometer budget |
| Transition expert | Activity service (optional `transition.json.gz` artifact) | Optional channel. Without the artifact the channel is absent and the decoder runs without it. Not deployed (status document) | Transition direction into the wrist direction memory, and the event `source` |
| Sleep detection and staging | Phone and worker (section 2) | Always on | Sleep epochs and each night's in-bed window |
| Personal profile | Phone decoder | On only after a profile is adopted (9e) | Adapted observation profiles |

WHOOP 5/MG records raw IMU one minute in every three by default ("Part-time", `ActivityImuCapture`). "Continuous" and "Off" are the other modes. Without raw IMU, HART and the motion features are absent and the decoder works from the strap streams alone.

**Who decides what.**

- **Wear is a hard gate.** Wrist-off events give `off_wrist` at confidence 1, and going off the wrist resets the belief. Otherwise a second is `on_wrist` only when a valid pulse falls in the last 60 s (`wearPulseWindowS`, causal). Gravity, steps or IMU alone are not wear evidence, and a pulseless, implausibly still strap reads `unknown`.
- **The sleep stager owns `sleeping`.** A second is `sleeping` only on a sleep epoch of a detected night. Awake inside a night's in-bed window is `lying_down` ("Resting in bed"), never asleep. The posture head's lean never overrides either.
- **A posture claim needs posture evidence.** Elapsed stillness never decides sitting vs standing. Without evidence the state is `stationary`.
- **Heart rate is not posture evidence.** All three stationary modes (bed rest, seated, upright) expect one relative heart-rate level (`stationaryHrRel` 0.08), and all four postural-transition modes expect one level (`transitionHrRel` 0.20). Heart rate therefore separates stationary from exertion only. A personal profile never adapts it per posture.
- **Cycling is only claimed when something names it**: HART, or a cycling workout. It is never inferred from heart rate and stillness.

### 9b. Decoder (`hsmm-1.9`)

The decoder is a hidden semi-Markov model over 15 body modes: unknown, bed rest, seated, upright, walk, brisk walk, run, stairs, cycling, vehicle, other exercise, and four postural transitions (sit-to-stand, stand-to-sit, lying down, getting up). It runs a forward filter at 1 s resolution, so a state at time t uses evidence up to t only. Evidence is tempered (`evidenceTemperature` 0.35) because consecutive 1 s features overlap. A small arm-behaviour chain runs beside the body chain. A state is published every 5 s with three probability heads (posture, locomotion, arm behaviour) and never a forced class.

**The dwell prior governs duration only.** Each mode has an Erlang duration prior and an exit distribution. These set how long a mode tends to last, not which posture it is. The seated / upright / recumbent split is bounded by a decaying memory of real posture evidence, held per source with its own cap (`ActivityContextModel.PostureEvidence`):

| Posture evidence source | Cap toward seated / recumbent | Cap toward upright / not recumbent | Memory |
|---|---|---|---|
| Arm pattern (desk-like hands with a resting forearm) | ln 1.6 | ln 1.6 | 180 s |
| Held forearm orientation (seated vs upright) | ln 1.4 | ln 1.4 | 180 s |
| Direction of a shift (forearm axis at both ends) | ln 8 | ln 3 | 180 s |
| Learned heads: HART fine sit/stand rows, Inertia posture, personal-profile channels | ln 3 | ln 3 | 180 s |
| Held forearm orientation (recumbent) | ln 2.5 | ln 25 | 600 s |
| Direction of a lie-down or get-up | ln 3 | ln 12 | 600 s |
| Staged night (asleep, or awake in the in-bed window) | ln 200 | — | 600 s |

Totals are capped again:

- The seated-vs-upright total is capped at ln 8, or ln 12 with an adopted personal profile.
- The upright side of the wrist-only sources together (arm, orientation, direction) is capped at ln 1.6.
- With no posture evidence, the split may lean at most ln 1.25.
- Recumbent may hold at most 0.12 of seated + upright without recumbent evidence. With a personal lying row, the orientation cap becomes ln 6.

On its own, held orientation cannot produce a lying claim. Lying awake is claimed through the night source, the in-bed window or a lie-down's direction.

**Avoiding double counting.**

- Heart rate and the context gates never enter posture memory.
- Wrist cues never enter the learned memory.
- A logged workout is counted once, by the body chain and not by the arm-pattern channel.
- An in-process ElderNet channel stands down whenever the gait-quality channel is present.
- The posture-shift heuristic is discounted while the transition expert speaks.
- Inertia and ElderNet terms share one accelerometer budget.

**Gaps.** A data gap of 20–120 s flattens the belief toward the re-acquisition prior in proportion to its length. A gap of 120 s or more (`gapResetS`) resets it.

### 9c. Transitions, events and runs

**Direction.** A transition's direction comes from the forearm axis at both ends of the shift (`shiftDirection`):

- Standing up lowers the hand, so the arm ends hanging.
- Sitting down raises it.
- Lying down ends with the forearm flat or the hand above the elbow.
- Getting up starts there and leaves it.

The forearm sign is calibrated from gait: at least 40 s of walking agreeing on a mean of at least 0.30. It is reset after a 3600 s gap. Until it is known, the axis is read unsigned.

**Events.** Events are stored separately from states:

- **Postural event.** Opens when the summed mass of the four transition modes reaches 0.20. It names the leading direction. Its probability follows the excursion up to its peak, so it is stored at peak probability. Until a published state shows it, its kind may change, with up to 3 s to settle. The inverse direction opens a second event once the first one's mass has fallen to 0.6 of its peak.
- **Walk start and stop.** A walk starts at moving mass ≥ 0.6 and stops at ≤ 0.3.
- **Run start and stop.** A run starts at running mass ≥ 0.55 and stops at ≤ 0.25.
- **Stored fields.** Every event stores `ts` (the detection second), `probability`, `onsetTs` and `source`.
  - `onsetTs` is the first second of the current rise: transition mass ≥ 0.05, or moving or running mass ≥ 0.2. For a stop, it is the second after the mass last stood at 0.5. It is never more than 10 s before `ts` (`maxOnsetLeadS`) and never after it.
  - `source` is `hsmm`, or `transition_expert` if the expert spoke during the excursion.
- **Where events go.** Events are written at every probability, to the day document and to `activityContextTransition`, keyed by (`ts`, kind). The 0.40 threshold (`PositionChanges.minimumProbability`) only decides which changes are listed to the wearer and which count for settling. It is not a detection threshold.

**Runs.** Runs follow the per-state class (`ActivityClassifier.runKey`), without the display label's 10–30 s hysteresis:

- Hand-pattern wording is folded into one body state. Desk vs quiet sitting, restless on a seated or upright body, and brisk vs ordinary walking each stay in one run.
- A state joins a run when its heads are within 0.45 of the run's mean.
- A boundary that a compatible event explains (detected within one 5 s tick) moves back to the event's onset, never later than it was.
- A wear boundary moves to the off-wrist span's own second.
- A one- or two-tick wobble next to a run of the same key is folded in. A short run of a different class stays.

**Resume.** A resumed decode re-opens the last three raw runs and produces exactly the runs a decode from scratch would, at any offload cadence.

**Short stands.** A 5–15 s stand is kept as events whatever happens to the state. The causal interval build absorbs still-family fragments shorter than 30 s (`stillDwellS`) into the surrounding still row. It records them on that row (`absorbedClasses`, `absorbedSeconds`, `transitionCount`), so in the causal intervals a 10 s stand survives as events, not as its own row.

Replay results (measured, not code constants):

- FORTH 10 s stands, 15 bouts (INT-B): the standing state was shown 12 of 15 times, the sit-to-stand event was kept 10–11 of 15 times, and both events appeared in order 3 of 15 times.
- r1 replays:
  - A 5 s stand flags only the stand-up.
  - 10 s and 15 s stands flag both changes.
  - With HART naming standing, a 15 s stand reads `standing` at about 0.62.

### 9d. Classes, confidence and abstention

Only classes the sensors can tell apart with reasonable confidence are in the taxonomy. `ActivityClass.capabilities` states the evidence and the limit of every one, and a test fails if a class is added without that statement.

| Code | Established by | What it cannot tell apart |
|---|---|---|
| `off_wrist` | wrist-off events, loss of pulse contact (a hard gate, confidence 1) | a quiet strap on a table is never taken as on-wrist evidence |
| `sleeping` | a sleep epoch of a detected night and stillness | naps outside a detected session read as lying down; lying awake in bed is `lying_down` |
| `lying_down` | awake inside a detected night's in-bed window, a lie-down the forearm axis shows, or minutes of a held flat or raised quiet forearm | the held-orientation cue is weak and slow (a forearm flat on a lap looks the same), so a short daytime lie-down may read as stationary |
| `sitting`, `sitting_desk` | stationary wrist whose posture head leans seated (a sit-down whose direction the forearm shows, desk-like hands); `sitting_desk` adds desk-like hand activity; a vehicle ride is `sitting` with detail `in_vehicle` | the wrist cannot see body height: sitting vs standing is a likelihood, never a measurement |
| `standing` | stationary wrist whose posture head leans upright (a stand-up whose direction the forearm shows, an arm left hanging) | needs a committed upright lean, otherwise the state is `stationary` |
| `stationary` | awake, still, posture not resolved | deliberately unresolved between sitting and standing |
| `fidgeting` | bursty low-amplitude movement without gait ("Sitting, restless" / "Standing, restless") | tremor, restless legs and gesturing overlap |
| `light_activity` | whole-body movement without a sustained gait, or a posture-change signature | chores, pacing and rearranging are not told apart |
| `walking` | step-counter cadence 70–125/min with steady movement; stairs are reported as walking (detail `stairs`) | confident gait needs the step counter (WHOOP 5/MG) or raw IMU rhythm; WHOOP 4.0 relies on movement shape |
| `brisk_walking` | cadence 105–150/min, higher intensity, raised heart rate | overlaps ordinary walking near 105–125/min (the runner-up says so) |
| `running` | cadence 135–210/min with high intensity | treadmill vs outdoor and pace |
| `cycling` | only when the motion encoder or a cycling workout names it | never inferred from heart rate and stillness |
| `vigorous_activity` | sustained heart rate of about 45% of reserve or more with vigorous arm movement and no gait, or a logged workout | the activity itself is not named |
| `unknown` | conflicting or missing evidence; confidence 0 | carries no claim; the best guess is the runner-up |

**How a class and its confidence come out.** The class is the display rules' reading of the heads at that instant. The confidence is the mass of that specific class. `familyConfidence` is the mass of its family: walking + brisk + stairs for the walking classes, seated for `sitting` and `sitting_desk`. The runner-up is the best alternative outside the family, reported when its mass is at least 0.02. `evidenceQuality` is the decoder's overall confidence (coverage, channel agreement, warm-up).

**Posture caps** (`ActivityClassifier`, D9-08):

- **Wrist-only cap: 0.75.** A `sitting`, `standing` or `fidgeting` claim carries at most `wristOnlyPostureConfidenceCap` (0.75).
- **Learned cap: 0.85, only with agreement.** The cap rises to `learnedPostureConfidenceCap` (0.85) only when the decoder's learned posture memory agrees with the posture claimed.
  - That memory holds HART's fine sit/stand rows, Inertia's posture head and an adopted profile's channels.
  - It agrees when it leans the same way by at least ln 2 (`learnedPostureAgreementLogOdds`). The state then carries `learned_posture`.
  - A learned source that disagrees, is undecided, or only spoke leaves the 0.75 cap.
  - The transition expert never counts as agreement. Wrist cues never set it.
  - HART reads the same IMU as the wrist cues, so the learned cap is softer and is never lifted.
- **Restless claims carry one posture.** "Sitting, restless" and "Standing, restless" carry the mass of the posture they name, under the same cap, not seated + upright.
- **Runs and stored intervals stay at the wrist cap.** A run keeps only the union of experts that spoke, not per-second agreement. So `classify(run:)`, the run's `class_confidence` and every stored interval's sitting or standing confidence stay ≤ 0.75.
- **Vehicle mass is not capped.** The vehicle mass is added to `sitting` uncapped, because the encoder names it.
- **No fitted calibration map exists.** The caps stand in for one.

**Abstention.** A still wearer whose posture is unresolved is `stationary`. Conflicting or missing evidence is `unknown` at confidence 0. Neither is a guess.

### 9e. Personal profile (`personal-profile-3`)

`ActivityPersonalProfileFitter` learns one wearer's observation profiles from their guided calibration runs.

**What it adapts.** Movement range, orientation-path range, arm-pattern and HART compatibility, and held forearm-orientation rows for the stationary modes. For walking modes it also adapts the relative heart-rate level. The adaptable modes are bed rest, seated, upright, walk and brisk walk.

**How it fits.**

- Each mode is shrunk toward the wearer's values with w = n/(n + 120 s).
- A mode needs at least 60 labelled seconds, and the fit needs at least 2 runs.
- It is validated leave-one-run-out on the published class: a hedged `stationary` second counts as a miss.

**Adoption guards.** A profile is adopted only when the held-out balanced accuracy gains at least 0.03, and all of these hold:

- no validated class loses more than 0.05 of its recall;
- the pooled wrong-claim share rises by at most 0.03;
- no validated class's own wrong-claim share rises by more than 0.05 (`maxClassWrongClaimRise`; a class needs 10 held-out seconds to be validated);
- transitions are found as often as before, within 0.05;
- a profile that adapts any stationary posture has all three of lying, sitting and standing validated (`validatesEveryStationaryPosture`). Otherwise its stationary adaptations are refused.

Modes are dropped by backward elimination until the guards hold.

**Refit.** The app's refit fingerprint carries the profile version but not the decoder version. Bumping `currentVersion` makes every adopted profile refit and re-validate once.

### 9f. Measurement context: intervals and joins

**Interval rows (`activityContextInterval`, `ctx-int-2`).** Runs become half-open `[startTs, endTs)` rows (`ActivityContextIntervalBuilder`).

Folding rules:

- **Merge.** Neighbours with the same class, sleep, wear and in-bed context merge across gaps of at most 10 s. A vehicle row never merges with a plain row of the same class.
- **Light-activity and unknown fragments.** A light-activity or on-wrist `unknown` fragment shorter than 10 s between two stretches of one situation is absorbed.
- **Still-family fragments.** Inside a still stretch, still-family fragments totalling under 30 s are absorbed.
- **Never absorbed.** Gait, cycling, vigorous, off-wrist and in-vehicle fragments are never absorbed, and neither is a fragment whose wear, sleep or in-bed context differs.
- **Splitting.** A stretch longer than 15 minutes (`maxIntervalS` 900) is cut into near-equal parts, so every row's statistics stay local.

Per-row physiology (NULL when it could not be measured, never zero):

| Field | Rule |
|---|---|
| `hrMean`, `hrMin`, `hrMax`, `hrSamples` | over the row |
| `hrSlope` | ≥ 30 samples over ≥ 90 s, clamped to ±30 bpm/min |
| `rmssd`, `rrBeats`, `rrDiffSqSumMs2`, `rrDiffCount` | row ≥ 60 s, ≥ 20 clean beats, on the wrist, not in a vehicle, mean motion intensity ≤ 0.40 (a motion gate, not a class list) |
| `respRateBpm`, `respBreaths` | same gate, ≥ 6 breaths |
| `stepTicks`, `cadenceSpm` | cadence needs ≥ 20 s of stepping |
| `inBed`, `uncertainty`, `experts`, `transitionCount`, `absorbedClasses`, `absorbedSeconds`, `precededByGapS`, `precedingClass` | context of the row |
| `detail`, `detailConfidence` | `in_vehicle`, `stairs` or `postural_transition` when it held most of the row |

**Settled statistics.** Seconds within 120 s (`settlingS`) after a movement row ends are settling seconds. So are the seconds after a change of position or the end of a walk is flagged at ≥ 0.40. `settledFrom` marks where settling ends. `hrMeanSettled` and `rmssdSettled` (with their components) are computed over `[settledFrom, end)` when at least 60 s remain. An in-vehicle row never gets a rest statistic: no RMSSD, no breathing, no settled heart rate.

**Per-sample joins.** Per-sample streams are not copied. They join through the `*Ctx` SQL views:

- The views are `hrSampleCtx`, `rrIntervalCtx`, `ppgHrSampleCtx`, `spo2SampleCtx`, `skinTempSampleCtx`, `respSampleCtx`, `gravitySampleCtx` and `stepSampleCtx`, plus `spotHrvReadingCtx` for manual 60 s HRV readings.
- Each view adds `ctxStartTs`, `ctxEndTs`, `ctxClass`, `ctxConfidence`, `ctxRunnerUp`, `ctxEvidenceQuality`, `ctxPosture`, `ctxLocomotion`, `ctxArmBehavior`, `ctxSleep`, `ctxWear`, `ctxIntensity`, `ctxDeviceId`, `ctxDecoderVersion`, `ctxProvisional`, `ctxInBed`, `ctxUncertainty` and `ctxDetail`.
- The lookup is an as-of lookup on the interval of the day's owner (the ledger row).
- A sample in a gap still appears, with NULL context.
- `activityContextDayClass` totals seconds per class per day.
- Derived series join by their own bucket timestamp, through `ActivityContextLookup` or `activityContextInterval(deviceId:at:)`.

**Full-support joins (`ActivityContextJoin`, `join-2`).** These answer what the activity was over a measurement's whole support interval:

- Every second of `[start, end)` is counted once. Abstained, unobserved and uncovered seconds count as unknown, so the shares plus `unknownShare` equal 1.
- `low_coverage` fires at coverage ≤ 0.5. `unknown_motion` fires at an unknown share ≥ 0.5.
- `recent_activity_s` is measured from the interval start (join-2; join-1 measured from the end).
- Label changes across gaps of at most 10 s count as transitions.

**HRV windows (`HRVWindowBuilder`).** These are fixed 5-minute canonical windows. 2-minute and 1-minute windows exist as separate populations that are never mixed. Activity is metadata on a window. Eligibility for a resting awake baseline fails closed:

- no transition-event data at all, or not enough lookback, gives phase `unknown`;
- a transition inside the window;
- an unknown regime or wear (the regime needs 90% coverage);
- less than 300 s after locomotion or 600 s after exercise;
- more than 30% of beats rejected.

On the phone the windows use the corrected activity lookup (user corrections overlaid) and the previous day's tail. Today they feed only a diagnostic line.

**Server joins.** The worker attaches the C10 `daily.activity_context` document to the scoring snapshot. Its `contexts.hrv_slots` holds the full-support context of each 15-minute slot that published an HRV point. Each point of `daily.hrv_series` has a matching entry in `daily.hrv_series.context` (D6-14), described in section 1.

### 9g. Causal and retrospective context; provisional and final

**The decoder is causal.** Every stored causal row (`derivation = causal`) uses only evidence up to its own second.

**Finality.** A day's ledger (`activityContextDay`) is `final` when two things hold:

- it was decoded as a finished day, so time outside logged sleep reads as awake rather than unknown;
- it was written at least 12 h after the day ended (`sleepSettleS`).

Otherwise it is `provisional`. A provisional day is re-derived once it has been closed for 12 h, so it becomes final. `ctxProvisional` exposes the state on every joined sample.

**Retrospective pass (`ActivityContextRetrospective`, `ctx-retro-2`).** For a final day only, this pass re-reads the day's runs and may **remove** posture claims, never add them:

- **Smoothing is used only to demote.** A forward-backward smoother runs over each still segment. Its hidden state is recumbent, seated or upright. Each run's posture head is the emission, renormalised and floored at 0.02, at one evidence unit per minute, capped at 120 s per run. A posture persists with switch probability 1 − exp(−d/3600 s). Nothing carries across a boundary that a postural event of probability ≥ the position-change minimum explains, with its onset-to-detection span within 5 s. A causal posture row is demoted to `stationary` only when the smoothed mass of its own posture is below 0.5 and another posture leads. A demoted row then merges with matching neighbours in the ordinary interval build. Lying is never smoothed across into sitting or standing.
- **Stops.** A walk or run stop boundary moves back to the flagged stop onset, at most `ActivityTransitionEvent.maxOnsetLeadS` (10 s). It moves only into a row that makes no posture claim, and never leaves a gait row shorter than 10 s.
- **Unchanged.** Locomotion, arm, sleep, wear, in-bed and every event stay the decoder's. Short fragments are kept exactly as the causal build keeps them.
- **Guard.** `guarded` demotes any output row that would claim a posture for a second the causal build did not claim with that same posture. It also caps every row's confidence at the causal confidence for those seconds. A property test over random run sequences asserts that retrospective claim seconds are a subset of causal same-posture seconds, that confidence is at or below causal, and that there are no more rows than causal.
- **Measured effect.** On the D7 replays, wrong posture claims and fragmentation equal the causal build's. The only posture change is on PAMAP2 + HART, where 60 s of wrong standing were removed. The stop refinement costs 0.3–0.7 points of locomotion recall and gains 0.3–1.0 points of active precision. The first version, `ctx-retro-1`, extended postures into unresolved stretches, multiplied wrong claims about fivefold on Capture-24, and never shipped.

`ActivityContextPersistence.retrospectiveIntervals` returns nothing unless the day is final.

**Storage and reading modes.** Retrospective rows go to a separate table, `activityContextIntervalRetrospective`, with the same columns. Each row is stamped `derivation = retrospective`. The ledger's `retrospectiveVersion` names the smoother. An unknown derivation code reads as retrospective, so it never reaches a causal consumer.

`activityContextIntervals(deviceId:from:to:reading:)` has three modes:

- `.causal` reads the live table only.
- `.retrospective` reads final days' smoothed rows only.
- `.historical` serves a final day that holds retrospective rows from those rows, and every other day causally.

The `*Ctx` views, `activityContextDayClass` and the default range read are causal.

**Causal consumers never read retrospective rows.** These are the physiology-context engine (`Engine.causalView` drops retrospective decoder records), the HRV windows, the baselines and Watchdog.

**A final day that returns to provisional.** `updateActivityContextDayStatus` deletes the day's retrospective rows and clears `retrospectiveVersion`. Writing retrospective rows for a provisional day throws.

**Who writes and reads them.** `ActivityContextCoordinator` runs the smoother when it derives a final day and writes the rows through `replaceActivityContext(..., retrospective:)`, stamping `retrospectiveVersion`; it passes `Candidate.retrospectiveVersion`, so a final day without the current smoother's rows is derived once more and then left alone. If the store refuses the smoothed rows, the causal rows are saved alone and the refusal is logged. The only `.historical` reader is the coach's activity look-back (`CoachTools`, up to 168 h). Every live or baseline consumer (stress detector, daytime stress and its baseline, HRV-window lookup, Watchdog, physiology context) reads `.causal`.

### 9h. Context-conditioned baselines (physiology context)

The physiology-context engine (`PhysiologyContext`, run by the worker's context lane) compares each day's values with references. All references are causal: the day's own and later values are dropped (`Engine.strictlyEarlier`).

**References (`pc-reference-4`).**

- **Daily value.** A stable-awake daily value needs at least 3 independent 5-minute windows.
- **Views.** The recent view uses 7 days (minimum 3). The rolling view uses 28 days (minimum 7, ready at 14). The frozen view is the first 14 supported days of the regime.
- **Strata.** Strata are shrunk toward the all-day parent with child weight n/(n + 7):
  - time bands starting at 0, 6, 12 and 18 h;
  - heart-rate-free gravity strata, `.posture_recumbent_likely` and `.posture_upright_likely`;
  - context strata, `.ctx_seated`, `.ctx_recumbent_awake` and `.ctx_upright_stationary`.
- **Fallback.** A stratum without enough support falls back to the parent.

**Context strata gates** (`PostureEvidence.withContext`, `pc-posture-2`). A window keys a context stratum only when all of these hold:

- a decoder run claims sitting, sitting at a desk, standing or lying down;
- the claim's confidence is ≥ 0.8 (`contextMinConfidence`);
- the decoder is `hsmm-1.9` or newer, compared numerically (hsmm-1.8 rows could claim sit/stand at 0.8–0.9 without learned agreement);
- the seconds are not in a vehicle (`context_in_vehicle_not_used`);
- the second is outside the heart-rate-confirmed in-bed window;
- one posture covers ≥ 90% of the support;
- the forearm gravity reading does not contradict it (lying vs upright).

Each stratum needs ≥ 3 windows on the day. `unknown` windows stay in the parent.

**What this means today.** The worker reads a run's confidence from its `class_confidence`, which `classify(run:)` computes at the wrist-only cap. A stored sitting or standing run is therefore at most 0.75, below 0.8. So `.ctx_seated` and `.ctx_upright_stationary` currently always abstain with reason `context_confidence_below_floor`, and the parent reference is used.

The one exception is a `sitting` run whose vehicle mass lifts it past 0.8. That mass is not capped, and `withContext` does not exclude in-vehicle runs. `.ctx_recumbent_awake` is not capped either, but its seconds inside the in-bed window are excluded, so it keys only on strong daytime recumbent evidence.

Even with an agreeing learned source, the stored run confidence would stay at 0.75 until runs carry per-second agreement.

**Predecessor regime after a strap change.** A device's references may borrow a previous device's history.

The predecessor is compatible only when all of these hold:

- same vendor and source kind;
- same hardware family, positively identified on both rows (unknown is incompatible);
- no known firmware difference (unknown firmware adds `predecessor_firmware_unknown`);
- optical valid share within 0.25, comparing the new device's recent median with the median of the predecessor's own last 14 days of data, all before the scored day. If either is unknown, the borrow proceeds with the reason `predecessor_signal_quality_unknown`;
- the same regime key per series.

How the fallback applies:

- **When.** The rolling view borrows only while own support is under 14 days. A stratum's parent borrows only while it is under 7.
- **Predecessor history.** The predecessor needs at least 7 days of the series in its last 28, and its newest value no more than 56 days old.
- **Statistics.** Center = w·own + (1 − w)·predecessor, with w = n/(n + 7). The predecessor scale is inflated ×1.5, and an offset of 0.5 × the inflated scale is added to the center's uncertainty.
- **Status and reasons.** Status is always `provisional`. Reasons are `predecessor_regime` plus `predecessor_regime_only` or `pooled_toward_predecessor`. `predecessorScope` names the old device.
- **Scope.** It never feeds the recent or frozen views, episodes, or the device's own history.

Without a compatible predecessor there is no fallback, and the comparison carries reasons such as `predecessor_regime_incompatible`, `predecessor_family_differs`, `predecessor_family_unknown`, `predecessor_regime_insufficient` or `predecessor_regime_stale`.

The worker identifies the hardware family per device row from its label. A bare "WHOOP" label is unknown, so the fallback abstains for such rows. Firmware is never known, so every borrowed reference says `predecessor_firmware_unknown`.

**Eligibility and join.**

- `pc-eligibility-4` counts a decoder transition event over its onset-to-detection span `[onsetTs, ts]`, not at the detection second only.
- `pc-join-3` annotates a composition with an event when that span overlaps the support.
- The worker keeps a day's events by `ts` within `[dayStart, dayEnd)`, whatever their onset (`ActivityContextDays.clippedToDay`).

**Charge.** The Charge re-score uses a causal as-of baseline (`Baselines+AsOf.swift`). Night D is z-scored against a fold of nights strictly before D, and the fold restarts at a recalibration epoch or a regime change, so later nights cannot change a stored score.

### 9i. Versions and provenance

| Constant | Value | File |
|---|---|---|
| `ActivityClassVersions.taxonomy` | `act-class-4` | `ActivityContextClass.swift` |
| `ActivityClassVersions.interval` | `ctx-int-2` | `ActivityContextClass.swift` |
| `ActivityContextVersions.decoder` | `hsmm-1.9` | `ActivityContextOntology.swift` |
| `ActivityContextVersions.ontology` / `.featureSchema` / `.schema` | `v2.0` / `imu-feat-2` / 2 | `ActivityContextOntology.swift` |
| `ActivityContextRetrospective.version` | `ctx-retro-2` | `ActivityContextRetrospective.swift` |
| `ActivityContextJoin.version` | `join-2` | `ActivityContextJoin.swift` |
| `ActivityPersonalProfile.currentVersion` | `personal-profile-3` | `ActivityPersonalProfile.swift` |
| PC eligibility / join / reference / posture | `pc-eligibility-4` / `pc-join-3` / `pc-reference-4` / `pc-posture-2` | `PhysiologyContext/PCEligibility.swift`, `PCIntervalAlgebra.swift`, `PCReferences.swift`, `PCPostureTransitions.swift` |
| PC contract / engine / validity / change / sleep / exposure / exertion / functional / motion / wire | `pc-contract-1` / `pc-engine-1` / `pc-validity-2` / `pc-change-2` / `pc-sleep-2` / `pc-exposure-1` / `pc-exertion-1` / `pc-functional-2` / `pc-motion-1` / `pc-wire-1` | `PhysiologyContext/*` |
| Worker lane tag | `d=hsmm-1.9;o=v2.0;f=imu-feat-2;s=2;t=act-class-4;n=ctx-int-2;i=5;c=…;l=…` (+ `m=`/`p=` for the raw-IMU lane), `versionsOrdinal` 2 | `Tools/CloudWorker/.../ActivityContextDays.swift` |
| WhoopStore migrations | `v48-activity-context`, `v49-rr-diff-components`, `v51-activity-context-provenance` (adds the ledger provenance and finality columns, `derivation`, `retrospectiveVersion` and `activityContextIntervalRetrospective`) | `Packages/WhoopStore/.../Database.swift` |
| Supabase migrations | `20261008100000_activity_context_current_lineage_and_versions`, `20261008100100_activity_context_epochs_day_revision_rows_index`, `20261008100200_activity_context_transitions_onset_source`, `20261008100400_bump_user_revision_skip_deleted_owner` | `supabase/migrations/` |

**What a bump triggers.**

- **Phone.** The ledger records the taxonomy, decoder, ontology, interval version, feature schema and config tag. A day whose ledger does not match the build is derived again (materializer rule 1).
- **Worker.** The worker registers its lane tag with `versionsOrdinal`, and a new tag re-fingerprints the recent days. The registry refuses a lower ordinal, so an older build cannot take the registration back.
- **Personal profile.** A version bump refits and re-validates the profile once.
- **Physiology context.** A PC version change changes the policy fingerprint, so a re-run day stores a new revision. Nothing re-enqueues PC days on a policy change.

**Historical rows keep their versions.** Stored days, documents and PC revisions keep the versions that produced them until they are re-derived. The tools' Python HSMM port is still `hsmm-1.6`.

### 9j. Remaining sensor limits

- A wrist cannot reliably separate sitting from standing in free living. The learned cap's own justification cites a HART fine sit/stand AUC of about 0.68 in free living, and wrist-only standing claims were right about 7% of the time on Capture-24 (code comments, `ActivityContextModel.swift`, `ActivityContextClass.swift`). The system says `stationary` when it cannot tell.
- Lying awake vs sitting is weak in the daytime. Held forearm orientation alone is capped below a lying claim, so a short daytime lie-down may read as `stationary`.
- Raw IMU is recorded one minute in three by default. HART, the motion features, the learned posture rows and any transition expert are absent the other two minutes.
- Heart-rate circularity is guarded but not removed: heart rate has one level across postures, and the context strata refuse decoders older than `hsmm-1.9`, in-vehicle seconds and in-bed seconds. The in-bed window itself comes from the heart-rate-confirmed sleep detector.
- Every threshold and prior above is an engineering default set on lab and free-living replays. None is fitted on labelled strap data, and no calibration map exists.
- The transition expert is not deployed. Inertia is dormant, and ElderNet reaches the phone's decode only from non-shadow server days.

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
| Activity class taxonomy, caps + classifier | `ActivityContextClass.swift` |
| Activity decoder, body modes, posture-evidence caps, events | `ActivityContextDecoder.swift`, `ActivityContextModel.swift`, `ActivityContextOntology.swift` (versions, event fields) |
| Day decode, wear rule, runs + boundary alignment | `ActivityContextTrack.swift` |
| Event display / settling threshold | `PositionChanges` in `DayStretchLayout.swift` |
| Personal profile | `ActivityPersonalProfile.swift`, `Strand/Data/Repository+ActivityContext.swift` (decoder config) |
| Raw IMU capture mode | `Strand/Collect/ActivityImuCapture.swift` |
| Activity intervals + per-interval physiology | `ActivityContextInterval.swift`, `ActivityContextInterval+Store.swift` (finality, retrospective rows), `ActivityContextAggregate.swift` |
| Retrospective smoothing | `ActivityContextRetrospective.swift` |
| Full-support joins | `ActivityContextJoin.swift` |
| HRV windows | `HRVWindow.swift` |
| When a day is written | `ActivityContextMaterialization.swift`, `Strand/Data/ActivityContextCoordinator.swift`, `Strand/Data/Repository+ActivityContextStore.swift` |
| Stored context (tables, views, reading modes) | `Packages/WhoopStore/Sources/WhoopStore/ActivityContextStore.swift`, `ActivityContextViews.swift`, migrations `v48-activity-context`, `v51-activity-context-provenance` in `Database.swift` |
| Physiology context (references, strata, predecessor regime, eligibility, join) | `Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/*` (`PCReferences.swift`, `PCPostureTransitions.swift`, `PCEligibility.swift`, `PCIntervalAlgebra.swift`, `PCEngine.swift`, `PCContract.swift`) |
| Charge as-of baseline | `Baselines+AsOf.swift` |
| Worker activity decode, lane tag, day event filter | `Tools/CloudWorker/Sources/frwhoop-worker/ActivityContextDays.swift`, `ActivityLane.swift` (C10 document, `contexts.hrv_slots`) |
| Worker Inertia / ElderNet (shadow first) | `Tools/CloudWorker/Sources/frwhoop-worker/ActivityMotionHeads.swift`, `ActivityGaitQuality.swift`; phone side `Strand/Data/GaitWindowStore.swift` |
| Worker physiology-context inputs (decoder runs, predecessor history, hardware family) | `Tools/CloudWorker/Sources/frwhoop-worker/ContextInputs.swift`, `ContextSQL.swift` |
| Intraday HRV slots + per-slot context | `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift` (`hrvSlotReadings`, `hrvSlotContext`) |
| Today HRV chart de-emphasis | `Strand/Screens/HrvSeriesChart.swift`, `HrvSlotQuality` in `Strand/Push/ServerScoreRepository.swift` |
| Server activity-context migrations | `supabase/migrations/20261008100000_…`, `20261008100100_…`, `20261008100200_…`, `20261008100400_…` |
| Stand reminder | `StandReminderEngine.swift`, `Strand/Data/InactivityPrefs.swift` |
| Sleep analytics (document, groups, gates) | `SleepAnalyticsV1.swift` (contract), `SleepAnalyticsNormalization.swift`, `SleepAnalyticsContinuity.swift`, `SleepAnalyticsStageDynamics.swift`, `SleepAnalyticsMovement.swift`, `SleepAnalyticsThermal.swift`, `SleepAnalyticsPrv.swift`, `SleepAnalyticsComputation.swift` |
| Sleep analytics worker attach | `Tools/CloudWorker/Sources/frwhoop-worker/SleepAnalyticsAttach.swift`, `DayScoring.swift` |
| Sleep analytics app decode + section | `Strand/Push/ServerScoreRepository.swift` (`HostedDayResult.sleepAnalytics`), `Strand/Screens/SleepAnalyticsSection.swift` |
| Coach access to the context | `Strand/Coach/CoachActivityContext.swift` (`get_activity_context`) |
