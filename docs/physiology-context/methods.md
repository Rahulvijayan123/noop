# Physiology context — methods

Estimators, provisional defaults, sources, assumptions, dependence, missingness and sensitivity results for the
physiology context layer (spec §20.3). Workstream notes under [`notes/`](notes/) hold the full per-system detail and
are cited by section; [`notes/research.md`](notes/research.md) holds the primary-source findings with their
verification status (read in full / abstract only / not verified).

Every number here is one of three kinds, and they are never mixed:

| Kind | Meaning |
| --- | --- |
| **Literature** | A finding from a cited primary source, applied with the stated caveat. It does not validate the number for Nara's inputs. |
| **Inherited** | An engineering default already used by an existing Nara engine (file named), reused so the layer agrees with the product. |
| **Engineering choice** | A new default chosen here, with its reason. Not validated. |

No default in this layer is a validated clinical cutoff. Every tunable is a field of `PhysiologyContext.Policy` and
enters `Policy.fingerprint`, so changing one changes every cache and reprocessing key.

- [1. Shared temporal method](#1-shared-temporal-method)
- [2. System A — validity and regime](#2-system-a--validity-and-regime)
- [3. System B — eligibility](#3-system-b--eligibility)
- [4. System C — sleep and rhythm](#4-system-c--sleep-and-rhythm)
- [5. System D — exertion response](#5-system-d--exertion-response)
- [6. System E — exposures](#6-system-e--exposures)
- [7. System F — references and change](#7-system-f--references-and-change)
- [8. System G — functional features](#8-system-g--functional-features)
- [9. Dependence between signals](#9-dependence-between-signals)
- [10. Missingness](#10-missingness)
- [11. Evaluation design (spec §14)](#11-evaluation-design-spec-14)
- [12. Sensitivity and evaluation results](#12-sensitivity-and-evaluation-results)
- [13. Storage method](#13-storage-method)
- [14. Findings, engineering choices and open hypotheses](#14-findings-engineering-choices-and-open-hypotheses)

## 1. Shared temporal method

- **Whole-interval join** (`PCIntervalAlgebra.swift`). Overlapping and revised activity records are resolved per
  second (revision, then availability time, then a stable id), so each second counts once. Label seconds + unknown
  seconds + uncovered seconds equal the interval length. Shares use the whole interval as denominator. "Mixed" =
  two labels ≥ 10 % each; "dominant" = ≥ 90 % of the whole interval (engineering choice, matching the 90 % floors
  of the existing `restingEligibility`). The preceding window (30 min) is separate from the measurement window;
  time since supported activity scans all earlier spans. This replaces, for the context layer only, the existing
  `ActivityContextJoin.context`, which divides by covered seconds and sums overlapping epochs twice (discovery §5).
- **Causal cutoff** (`Engine.causalView`). In `causal_live` mode every observation or record with sensor time at or
  after the cutoff, or availability after it, is removed before any system runs. Availability is the server's
  `ingested_at` (exposures: `received_at`; sleep sessions: the publishing snapshot time, else the session end). The
  document does not record how much was excluded: that count is itself information a live decision did not have.
- **Determinism.** The engine reads no clock. The input fingerprint (FNV-1a over the inputs actually used, plus
  finality for retrospective documents) and the policy fingerprint make retries idempotent.
- **HR-independent context.** Eligibility, bouts and functional features use only heart-rate independent evidence:
  v1 HART epochs when present, else strap gravity / dynamic acceleration and the step counter. The v2 decoder reads
  heart rate (`ActivityContextModel.swift:355-380`) and is display-only for heart-derived metrics.

## 2. System A — validity and regime

Full tables: [notes/signal.md §1–§5](notes/signal.md).

| Decision | Rule | Kind |
| --- | --- | --- |
| Observation identity | HR one value per second (conflicting duplicates rejected, never averaged); RR `(ts, rrMs, seq)` — equal values are distinct beats | Inherited (server keying, `StreamStore.swift`) |
| Breaks (never bridged) | > 60 s with no HR, RR or motion; RR channel change; clusters of conflicting HR seconds; clock reset (large backward jump within one delivery) | Engineering choice |
| HR validity | coverage < 0.10 invalid, < 0.50 degraded; flatline ≥ 300 s degraded, ≥ 900 s and ≥ 80 % invalid; out-of-band 30–220 bpm is a diagnostic, never an invalidation on value | Engineering choice (flatline kept conservative because smoothed integer bpm can hold a value in deep sleep) |
| HRV, short supports | ≥ 45 clean beats, ≥ 30 valid pairs, beat coverage ≥ 0.20 (degraded < 0.50) | Inherited (`IntradaySeries.Tuning`) |
| HRV, nightly | 300 s grid, a window qualifies at ≥ 20 clean beats; < 50 % qualified windows degraded | Inherited (`HRVAnalyzer.minBeats`) |
| HRV, artifacts | rejected (range + ectopic) > 0.35 invalid, > 0.20 degraded; over-count verdicts invalid | Inherited (`defaultSpotMaxRejectedFraction`); ≥ 80 % normal beats (Peltola 2012, literature) |
| HRV / RSA, motion | movement share > 0.30 invalid, > 0.10 degraded (`motion_contaminated`) — a signal-quality reason; IMU evidence untouched | Inherited (`DaytimeStress.activityMaskFraction`); PRV degrades with motion (Lam 2020 abstract, Schäfer & Vagedes 2013 abstract) |
| Respiratory rate | ≥ 30 beats, ≥ 6 breath intervals, run coverage < 0.33 invalid; always `rsa_only_estimate` | Inherited (IntradaySeries respiratory tuning); RSA weakest outside rest (Charlton 2016/2018, literature) |
| Skin temperature | in-band 28–42 °C as worn evidence; always `skin_not_core_temperature` | Inherited (`AnalyticsEngine`); distal ≠ core (Kräuchi, literature) |
| SpO2 | always `unverified` | Product rule (BACKEND.md "strap estimate (unverified)") |
| PPG waveform quality, core temperature | `unsupported` rows in the availability matrix | No qualified input exists |
| Regime key | FNV-1a of vendor, family, source kind, firmware, placement, method id, algorithm version, aggregation, window (session/day aggregates keyed by aggregation, not length), units | Engineering choice. Only identical keys pool; no cross-vendor / placement / method / window pooling (spec §7). Placement is `unknown` before the first record and never back-filled. |

**No gate reads the measurement value.** A physiological extreme is reported, not removed (V03).

## 3. System B — eligibility

Full tables: [notes/signal.md §6–§7](notes/signal.md).

- **Stable awake rest** ("stable awake low movement", never calm or recovered) starts from the existing
  `ActivityContextJoin.restingEligibility` policy (inherited): ≥ 90 % stationary over the whole support, ≥ 90 %
  qualified coverage, ≥ 300 s preceding still run, awake and worn evidence, plus recent locomotion < 600 s and a
  recent bout < 600 s as exclusions. Unknown awake or wear evidence gives `unknown`, never `eligible` (V02).
- **Sleep measurement**: inside a supported sleep episode and worn; staging never required.
- **Activity response**: locomotion ≥ 50 % of the support, or within 900 s after a bout (engineering choice).
- **Target dependence.** The only gate that reads the target's own signal is signal validity; it is declared in
  `targetDependentGates`. Awake evidence comes from the HR-confirmed sleep detector and wear from HR presence; both
  are declared in `dependsOn` (`sleep_detector_uses_heart_rate`, `wear_from_heart_rate_signal`). This is a
  selection-bias channel: a still person with low HR is more likely labelled asleep and so excluded from awake rest.
- **Selection accounting** (`SelectionSummary`): eligible / ineligible / unknown counts, the share of observed time
  that eligible supports represent, and the top exclusion reasons, per comparison and metric (spec §14 last bullet).

## 4. System C — sleep and rhythm

Full detail: [notes/sleep.md](notes/sleep.md).

- Episodes come from the scorer's published sessions (HR-confirmed detector). Main sleep vs nap uses the app's
  existing grouping (`SleepStageTotals.mainNightGroupIndices`, inherited); the scorer's `is_nap` is honoured only when
  true (it currently hardcodes false). Ownership = local day of the end (inherited).
- **Completeness (causal).** A session ending within 30 min of the cutoff is incomplete: its end is never used as an
  awakening (engineering choice from the detector's own windows: 15-min still window + 15-min merge).
- **Awake evidence** requires HR coverage over the support and that every owner day that could hold a covering
  session has been read, with a 90-min allowance for detector latency (engineering choice from `minSleepMin` 60 min).
  Quiet motion never establishes asleep, awake or worn.
- **Wake-relative timing**: real UTC seconds since the latest complete main sleep (else nap), with explicit zone,
  offset and local clock; correct across DST (23 h / 25 h days).
- **Sleep loss / timing change**: vs the median of 5–14 prior nights (circular for midpoints), regularity as the SD
  of prior midpoints. A whole-hour midpoint shift is flagged `timezone_history_unknown` (heuristic).
- **Rhythm**: an HR day/night contrast labelled a proxy; phase is always `unavailable` — HR-derived rhythm is not
  endogenous phase (DLMO is the gold standard; Klerman 2002 / Benloucif 2008 abstracts, literature).

## 5. System D — exertion response

Full detail: [notes/responses.md](notes/responses.md).

- **Detection never uses HR**: HART labels where confident, else strap stepping; logged (`manual`, `imported`)
  workouts. HR-detected workouts are never a source (selecting by the response). Pauses ≤ 60 s merge, never across a
  break or > 10 s without motion evidence; a bout needs ≥ 60 locomotion seconds (engineering choices).
- **Response**: pre-bout median HR over `[start − 180 s, start − 30 s)`; during-bout median and p95; signed rise.
  Respiratory response during movement and HRV during recovery are explicitly unavailable (RSA invalid in motion;
  no validated post-exercise HRV window in this layer).
- **Recovery** ("post-effort HR decline", not clinical HRR — protocol cutoffs 12/18/22 bpm do not apply; Cole 1999,
  literature): readings at +60/+120/+300/+600 s, median of ≥ 3 samples within ±15 s, no interpolation (inherited from
  `HeartRateRecovery`). Censoring at the first of `disconnect`, `no_follow_up`, `next_bout`, `continued_movement`,
  `cutoff_reached`; time-to-return only when observed. Every reading belongs to exactly one bout.
- **Matching** records activity kind, duration band, cadence band and preceding state; speed, grade, external load and
  ambient conditions are always listed as unavailable (spec §10; Nazaret 2023 shows workload/environment confounding,
  literature).

## 6. System E — exposures

Full detail: [notes/exposures.md](notes/exposures.md).

- Revisions are immutable; current state = latest revision available at the cutoff; a retraction is history.
- Occurrence (`occurred`, with precision exact / approximate / day-only) and availability (`received_at`) are
  separate. Recording status per category is `recorded` / `denied` / `candidate_only` / `unrecorded`; unrecorded is
  not "none". A software candidate is never confirmed.
- Event-aligned summaries (3 h and 24 h before/after medians per metric) carry `association_only`, concurrent
  events, behaviour change (locomotion before/after) and regime change as confounders; medication, supplement,
  caffeine and alcohol also carry `pharmacology_not_modelled`. Day-only events get `time_uncertain` and no hour-level
  alignment.
- Invalidation reach: local days covering the closed range `[min start − 24 h, max end + 72 h]` of the old and new
  revision (the −24 h covers an earlier day's concurrent-event listing; the end instant is included because a
  reference includes an event that ended exactly 72 h before a measurement). Mirrored in SQL.

## 7. System F — references and change

Full detail and tables: [notes/statistics.md](notes/statistics.md).

| Element | Method | Kind |
| --- | --- | --- |
| Unit | One value per (day, series, regime, mode); support counted in independent days | Spec §12.2 |
| Nightly series | Snapshot values that are sleep-eligible and valid/degraded; whole-session SDNN excluded (length-dependent) | Shaffer & Ginsberg 2017 (literature) |
| Stable-awake series | Median of eligible 5-min windows; ≥ 3 non-overlapping windows | Engineering choice |
| Transform | ln for RMSSD / SDNN; signed differences kept in original units | Plews 2012–2014, Buchheit 2014 (literature; practice convention) |
| Recent | 7 calendar days (≥ 3 values), median | Spec range 2–7; sensitivity below |
| Rolling | 28 days, median, `1.4826 · MAD · b_n` with small-sample factor, floored; ready at ≥ 14 days | Rousseeuw & Croux 1993 (literature) |
| Frozen | First 14 supported days within 42 days, registered once per (series, regime, version), never replaced, labelled historical not healthy | Engineering choice |
| Conditioned | Time-band strata shrunk toward the all-day reference with `w = n/(n+7)`; no population prior | Engineering choice (spec §12.2 partial pooling) |
| Scale floors | ln HRV 0.05; HR 1 bpm (integer resolution); resp 0.3 /min; skin 0.1 °C | Engineering choices (HR floor tested 0.5 / 1 / 2) |
| Center uncertainty | `1.2533 · scale / √n`, labelled approximate (understates under autocorrelation) | Asymptotic median SE |
| Robust z | Distance in robust-scale units, never a probability | Research note 1 |
| Detector | Two-sided CUSUM on daily robust z (never on rolling means), k = 0.25, h = 7, clamp ±2, input divided by the AR(1) long-run factor from φ̂ on days d−69…d−14 | Page 1954 / NIST (literature); parameters from the evaluation below |
| States | usual variation, transient deviation, recurring episode, persistent shift, insufficient evidence; frozen persistence keeps a fixed-reference deviation visible after the rolling view adapts | Spec §12.3 |

## 8. System G — functional features

Full detail: [notes/responses.md §G](notes/responses.md).

- Wear per minute from wear events, HR presence (declared heart-derived; used only as a denominator) and locomotion
  evidence. Day totals are comparable only at ≥ 70 % worn waking time on a complete day; per-worn-hour rates need
  ≥ 4 worn waking hours (engineering choices). Below that: `insufficient_wear_coverage`,
  `wear_missingness_may_be_informative` — missingness, never decline (V14).
- Features: bouts, durations, locomotion per worn hour, pauses, cadence (uncalibrated counter ticks; not gait speed
  or stride length), transitions, fragmentation, rest after activity.
- Registry `pc-features-1`: 11 general definitions (`technical_verification_only`) and 6 specialized ones (gait
  speed, stride length, tremor index, respiratory event index, autonomic index, symptom classifier) that always
  evaluate `unavailable` with the missing sensor, placement, label and reference assessment named. No coefficients.

## 9. Dependence between signals

`DayDocument.dependence` declares shared-input groups; the multi-signal summary counts groups, not series (V13).

| Group | Members | Why |
| --- | --- | --- |
| `beat_intervals` | HRV RMSSD/SDNN, respiratory rate | RSA respiration is computed from the same R-R intervals |
| `optical_pulse` | HR, resting HR, HRV, respiratory rate | All from the same optical pulse; a sensor artifact moves them together |
| `heart_rate` | HR, resting HR, sleep detector, v2 decoder | The sleep detector confirms sleep with HR; the decoder reads HR reserve |
| `sleep_detector` | sleep/wake, stages, HR, HRV, respiratory rate | Sleep labels read heart signals; not independent corroboration |
| `strap_motion` | eligibility stillness, bouts, functional features | One motion stream feeds all three |

## 10. Missingness

| Missing thing | Representation |
| --- | --- |
| Activity record | `uncoveredS` (never stationary) |
| Abstained classifier time | `unknownS` |
| Metric value | no `DailyValue` (never zero) |
| Wear / sleep evidence | `unknown` state with reasons |
| Journal / exposure entry | category `unrecorded` (never "none") |
| Follow-up after a bout | censoring reason; no time-to-recovery |
| Reference history | `insufficient` / `provisional` status with support counts |
| Inputs that do not exist (PPG waveform, core temperature, labels) | `unsupported` / `unavailable` rows with the missing evidence named |

Missingness was evaluated only as random in the synthetic harness; informative missingness (e.g. less wear when
unwell) is a known untested case (statistics §8).

## 11. Evaluation design (spec §14)

Defined before tuning (statistics §5): context classification, physiological prediction and disease validity are
separate questions; this layer only addresses arithmetic/integration and a descriptive change summary.

- General models: subject-held-out evaluation; personalization: forward-chronological only. No random splits of
  overlapping windows; purge and embargo at least one window plus the lookback at every boundary (Roberts 2017,
  Bergmeir 2018, research note 13).
- Everything fitted (references, φ̂, frozen selection) uses permitted earlier history only; availability cutoffs are
  tested, not just timestamps (V10 tests at engine, sleep, references, worker and replay level).
- Dependence-aware intervals: stationary / block bootstrap over days and weeks (Politis & Romano 1994, Künsch 1989).
- Coverage and abstention are reported with every result (selection summaries, availability matrix).
- No calibrated probability exists in the layer, so calibration and proper scoring rules do not apply yet; any future
  probability must be evaluated for calibration separately from discrimination.
- A final temporal test set must be reserved before any tuning on real data; repeated hypothesis search needs
  multiple-comparison control.
- Context-selection bias is tracked per day (`SelectionSummary`).

## 12. Sensitivity and evaluation results

**All results below are synthetic arithmetic checks or engineering measurements, not physiological accuracy.**

### 12.1 Change detection (AR(1) synthetic series; statistics §6; seed 20261005, 400 replicates per cell)

| Check | Default detector | Comparison |
| --- | --- | --- |
| False persistent episodes per series-week, φ = 0 / 0.3 / 0.5 | 0.030 / 0.030 / 0.022 | Classic CUSUM k = 0.5 h = 4: 0.175 at φ = 0.3; unadjusted k = 0.25 h = 7: 0.103 |
| Series with ≥ 1 false persistent episode in 90 days | 31–38 % | — |
| 2-SD step missed within 28 days, φ = 0 / 0.3 / 0.5 | 0 % / 5 % / 20 % | Persistence rule 3-of-5: 54 % / 48 % / 39 % |
| 2-SD step median delay | 5 / 7 / 8 days | — |
| 1-SD step missed | 26–62 % | — |
| 3-SD gradual drift, median z last 7 days | frozen ≈ −3.0, rolling ≈ −0.7 | Frozen deviation stays visible as the rolling view adapts (V11) |
| +8 SD single-day artifact | 91–92 % transient only; reference center moves ≤ 0.12 SD; alarm rate 6 % with vs 5–6 % without | Raw value preserved |
| CUSUM arithmetic vs research note 8 | ARL0 163 / 54.0 / 33.9 days | ≈ 170 / 54 / 35 expected |
| Small-sample MAD factor, mean of 1.4826·MAD at n = 3…28 | 0.993–1.001 | raw 0.669–0.972 |

Reading: about one in three series shows a false persistent episode within any 90 days at the chosen threshold. The
episode summary is descriptive and must not be used as an alert; alerting is out of scope (spec §12.3).

### 12.2 Eligibility policy sensitivity (synthetic waking day; signal §7)

| Stationary floor \ preceding stillness | 120 s | 300 s (default) | 600 s |
| --- | --- | --- | --- |
| 0.80 | 0.500 | 0.382 | 0.229 |
| **0.90 (default)** | 0.472 | **0.375** | 0.229 |
| 0.95 | 0.424 | 0.340 | 0.215 |

Eligible windows by fidget stratum: 38/48 (quiet), 13/48, 3/48 (restless). Stable-awake references describe the
quietest part of the day; the selection summary reports that bias. Defaults unchanged (no evidence for others).

### 12.3 Real nights (8 de-identified night exports; `PCRealReplayTests`, opt-in)

| Night | Envelopes | Valid | Degraded | Invalid | Sleep-eligible | Plain KB | Stored KB | Build ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-20 | 190 | 182 | 7 | 1 | 187 | 752 | 288 | 30 |
| 2026-09-22 | 49 | 47 | 2 | 0 | 47 | 202 | 93 | 6 |
| 2026-09-23 | 69 | 69 | 0 | 0 | 66 | 276 | 114 | 21 |
| 2026-09-30 | 212 | 207 | 4 | 1 | 210 | 855 | 369 | 38 |
| 2026-10-01 | 207 | 74 | 30 | 103 | 102 | 851 | 388 | 46 |
| 2026-10-02 | 213 | 100 | 9 | 104 | 98 | 874 | 411 | 37 |
| 2026-10-03 | 228 | 115 | 0 | 113 | 114 | 932 | 412 | 45 |
| 2026-10-04 | 119 | 118 | 1 | 0 | 118 | 475 | 218 | 16 |

The invalid windows on 10-01..10-03 are the R-R over-count gate: those exports carry ~1.8 R-R rows per second
(duplicate transport delivery), so the gate refuses the windows rather than reporting inflated HRV. Three nights have
no R-R at all and produce HR-only context. The replay checks invariants (round trip, determinism, whole-interval
reconciliation, causal stability at a mid-night cutoff, lossless stored form); it says nothing about accuracy.

## 13. Storage method

A fully observed synthetic day (`PCDocumentSizeTests`) has 2,309 envelopes and 10.4 MB of plain JSON. The stored form
(`PCStoredDocument.swift`) is a summary plus one interned table per metric, with pooled times relative to each row and
derived history numbers (with overrides when a derivation would not reproduce the value). Measured: summary 85 KB,
HR 302 KB, HRV 433 KB, resting HR 334 KB, respiratory rate 1.5 MB; an exposure-heavy day (200 events) 3.6 MB.
`join(split(doc)) == doc` is tested. Postgres stores the tables with lz4 TOAST compression where available.

## 14. Findings, engineering choices and open hypotheses

| Category | Items |
| --- | --- |
| **Evidence-supported findings** (literature, with caveats in research.md) | MAD normal consistency and small-sample bias; ln RMSSD as monitoring convention; SDNN length dependence; PRV degrades with motion and is condition-dependent; RSA respiration weakest outside rest; wrist skin ≠ core; CUSUM ARL under autocorrelation; free-living HRR ≠ protocol HRR; non-wear ambiguity of quiet accelerometry; HR-derived rhythm ≠ endogenous phase; purged/embargoed evaluation; block bootstrap; WISDM and HART are lab/scripted, not free-living disease cohorts; FDA DHT guidance separates verification from validation in the intended population. |
| **Engineering choices** (not validated) | Every threshold marked "engineering choice" above; the detector parameters (chosen on synthetic data); frozen selection rule; partial-pooling k; scale floors; wear coverage floors; bout segmentation; sleep completeness margins. |
| **Open hypotheses** (need real, labelled, held-out data) | Whether stable-awake 5-min HRV/HR is more comparable day to day than nightly values for this population; whether the CUSUM false rate holds on real series (real φ unknown); whether HR-confirmed sleep labels bias awake-rest selection materially; whether strap step cadence tracks gait changes; whether any of this relates to disease state. |
