# Baseline and Watchdog v2 (`v2.clinical` / `watchdog-v3.0`)

Branch `feat/baseline-watchdog-rebuild-20261007`, cut from nara/main 3aa15d665. Audit and rebuild date: 2026-10-07.

Nara is a monitoring tool. It does not diagnose or prescribe. Every result in this document comes from synthetic data or from one person's short real history (§8), so none of it is clinical validation.

---

## 1. What was wrong (audit summary)

| # | Finding | Effect |
|---|---|---|
| 1 | `personalNativeOff` compared the latest live HR or HRV, during any activity, to the sleep-RHR, awake-rest and continuous long copies, and fired if any one was out. It also fired if any Layer 1 series had been out the day before. | The card read "Off" for most of the waking day once ~8 nights existed. Being "Off" then blocked the awake usuals from learning, which biased them low. |
| 2 | The bundled "UniTS" and "TimesFM" were a 25k- and a 12k-parameter on-device student. The UniTS student is a hand-coded physics prior plus at most ±1.75 bpm learned correction, with a ~3-minute moving average swapped in at rest. | The models contributed nothing to detection. The moving average absorbed sustained anomalies. |
| 3 | The Layer 1 band used a fixed k, or k from an in-sample 95th percentile. | Simulated off-rate was 8.5–10.5%/day per series against a nominal ~5%. |
| 4 | Layer 1 fitted a Theil–Sen slope with no significance test and moved the comparison center along it. | A noise slope counted as "usable" on pure noise (±4 bpm swing). A real ramp was absorbed. |
| 5 | The change detector folded \|e\| with k (0.5) below E\|Z\| (0.8), and was reset whenever the noise slope was "usable". | It never fired, so baselines silently drifted with physiology. |
| 6 | Safety used the single-sample minute HR max, had no duration or quality gate, and included wrist skin temperature and RMSSD bounds. It had no SpO₂ bound, safety edges had no cooldown, a "queued" notify could stick forever, the device id was a constant, and stored and live R-R were double-counted. | Noisy pages; others missed or silently dropped. |
| 7 | There were about 15 nightly-HRV baseline definitions across features: raw ms vs ln, SDNN pooled with RMSSD, look-ahead in Charge, ~0 floors, n = 1, and confounded days left in. | Features could disagree on the same screen. |

---

## 2. Layer 1 (daily baselines), `LongitudinalBaseline*.swift`

Estimators are shared with the server context engine (`PhysiologyContext.RobustStats`).

### Copies

All copies are built only from clean days strictly before T. A clean day is quality-OK with no logged confounder.

| Copy | Window | Estimator | Shown at | Use |
|---|---|---|---|---|
| This week | T−7 … T−1 (10 for HRV) | EWMA (span 7), Student-t learn weights vs the 60-day copy, small-sample MAD | 4 days | Short-term context |
| 60-day ("when well") | T−60 … T−8 | median, trim-consistent 1.4826·MAD × small-sample factor | 4; established 14 (21 for activity mix) | The comparison for daily z / p |
| 3-month | T−90 … T−8 | same | 14 | Longer context |
| Long-term | T−365 … T−8 | same | 28; mature at 56 | Historical context |
| Frozen anchor | First 28 clean days of the epoch, within 56 calendar days | median / MAD | — | Never moves; drift reference |

### Band and p-value

- **Center.** The robust median. It is never moved along a trend.
- **Scale.** s = 1.4826·MAD·b_n, floored per series:

  | Series | Floor |
  |---|---|
  | Sleep RHR | 2 bpm |
  | ln-HRV | 0.08 |
  | Respiration | 0.5 |
  | Temperature | 0.3 °C |
  | SpO₂ | 0.5 |

- **Effective n.** n_eff = n(1−φ)/(1+φ). φ is the Kendall-bias-corrected lag-1 autocorrelation on consecutive days, with a 0.3 fallback.
- **Predictive scale.** s_pred = √(s² + (1.2533·s/√n_eff)²), with df = n_eff − 1.
- **Band.** center ± t_df(0.975)·s_pred × the out-of-sample tail factor.
  - The tail factor is the realized 95th percentile of past |z| ÷ 1.96.
  - Past values enter only after 14 days, and never the days of a change episode.
  - The factor is ≥ 1, capped at 1.6, and shrunk toward 1 while there are fewer than 60 samples.
- **p_long.** The two-sided Student-t p of today.

### Change and drift

- **CUSUM** (PhysiologyContext design):
  - Two-sided, on daily predictive z.
  - k = 0.25, h = 10, clamp ±2, AR(1) long-run adjustment.
  - Capped at 1.25·h. A gap of more than 7 days resets it.
  - An alarm opens a change episode with an onset estimate (the start of the run).
  - The pre-change 60-day copy is held for 28 days.
- **Trend.** Theil–Sen slope with an autocorrelation-corrected Mann–Kendall test over 28 and 90 days. It is significant when p < 0.01, the Sen 95% CI excludes 0, and the fitted change is at least 0.5 scales. Trend is reported only; it never moves the center.
- **Drift vs anchor.** It is significant on any one of three tests:
  1. the 14-day median at p < 0.005, ≥ 0.75 scales, and corroborated by a same-direction trend or change episode;
  2. the 28-day median at p < 0.001 and ≥ 0.75 scales;
  3. two-stage: a same-direction episode alarmed after the anchor, then p < 0.05 on the level.
- **Re-anchoring.** The anchor is re-set only by an explicit event: a logged treatment start (after wash-in), the user's "set new reference", or a device-family epoch.

### Other changes

- The felt-ill snapshot expires 14 days after the last logged ill day.
- `replayDaily` scores a whole history in one pass.

---

## 3. Context-stratified series (`LongitudinalBaselineContext.swift`)

### New series

These are never averaged with each other or with the pooled series:
- `awakeSupineHR/HRVLn`, `awakeSeatedHR/HRVLn`, `awakeUprightHR/HRVLn`;
- `walkingHR` (steady walking, ≥ 3 min into a bout);
- `sleepHR` (all asleep minutes, with a within-night scale).

Pooled `awakeRestHR/HRVLn` now come from whole-day stored intervals instead of only the minutes the app was open (the live tape still fills days the interval table lacks).

### Source

The stored activity-context intervals: the existing HSMM decoder's class, posture, locomotion, sleep and wear channels, plus per-interval HR and RR-difference components.

### Rules

- **Worn.** Not `off_wrist`, and HR present on ≥ 50% of the interval's seconds. (`on_wrist` is the decoder's default, not evidence.)
- **Posture.** The class and the posture channel must agree, with confidence ≥ 0.6 and evidence quality ≥ 0.5. Anything less goes to the pooled series only.
- **Still.** Intensity known and ≤ 0.40. Unknown motion is never rest.
- **Steady state.**
  - The first interval of every still bout is dropped, and anything within 120 s of a posture change.
  - Anything within 10 min after walking, or 30 min after running, cycling or vigorous activity, is dropped.
- **Day values.**
  - HR is the sample-weighted mean of the qualifying intervals.
  - HRV is the pooled √(Σd²/Σn), with ≥ 120 pairs.
  - The within-day scale is a weighted MAD (≥ 3 intervals).
- **Coverage gates.** Posture ≥ 15 min; walking ≥ 10 min; sleep HR ≥ 120 min.

### Limitation

Wrist posture is the weakest inference. On capture24 the decoder's standing precision is 0.13. On the owner's 8 real days only "seated" days pass, so the lying and standing series will stay empty until the posture classifier improves. The strata are wired so they fill in as that happens, and the Watchdog falls back to the pooled awake-rest reference until a posture stratum is established.

---

## 4. Watchdog v2: candidates and verification

Code: `WatchdogVerification.swift` (contract) and `WatchdogVerifier.swift`.

### Per-minute quality (tri-state; missing = unknown)

**On body.**
- OFF on any of:
  - a WRIST_OFF with no later WRIST_ON (24 h lookback);
  - v18 optical baseline A = B = 0 with no HR;
  - charging.
- ON when HR is present ≥ 30 s, skin temperature is 28–42 °C (or v18 optics are present), and the wearer has recovered after any strap reset.

**Signal.**
- POOR on any of:
  - optical sentinel seconds > 25%;
  - beat coverage < 0.5 or > 1.3;
  - an R-R pileup;
  - saturation;
  - contact supported-not-detected.
- GOOD when beat coverage is 0.9–1.1, with v18 sentinel-free seconds when present.

**Motion.**
- Uses dynAccel, falling back to the window occupancy when dynAccel is absent.
- ≥ 0.05 g is moving.
- Moving plus bad optics is an artifact.

### Per-minute context

The kinds are asleep / awake-still (with the decoder's posture when the stored interval supports it) / walking / active / unknown. An abstaining classifier with measured stillness counts as still; unmeasured motion never does.

### Detectors

| Candidate | Rule |
|---|---|
| Safety extreme | Minute-mean HR > 120 for ≥ 10 consecutive awake-still minutes; HR < 40 awake or < 30 asleep for ≥ 10 min; median SpO₂ ≤ 88% over ≥ 5 min of readings while still or asleep; waveform respiration < 6 or > 30 for ≥ 10 min (never respiration derived from beats). Wrist skin temperature and RMSSD are no longer safety bounds. |
| Personal deviation | Context-matched Layer 1 reference: asleep → `sleepHR`; awake-still → the posture stratum, else pooled awake-rest; walking → `walkingHR`; otherwise abstain. Five-minute wall-clock blocks of one context. Scale = √(predictive between-day² + within-day²). A candidate when the last 3 consecutive blocks are all ≥ 2.5 scales in the same direction; p is Stouffer's with block ρ = 0.5. |
| Server model | TimesFM 3.0 / UniTS windows (§5) that are fresh (≤ 30 min) and have ≥ 5 minutes inside the live 30-minute view. |

### The five checks

1. **Baseline.** The reference matches the context and is established and not stale.
2. **Activity.** Movement, exercise, recovery (30 min), walking (10 min), or a posture or sleep transition fails the check.
3. **Sensor quality.** Off-body, or > 20% poor signal or artifact, fails. It passes at ≥ 80% on-body and signal OK. Temperature also needs a known wrist placement.
4. **Significance.** Safety passes on its sustained absolute bound. A personal deviation needs p < 10⁻³. A model candidate needs both models and ≥ 15 min.
5. **Independence.** HR, RHR, HRV and beat-derived respiration are one source group. A non-safety alert needs ≥ 2 groups, or a server-model corroboration.

**Decision.** Any fail → suppress. Any unknown → hold (shown, not sent). All pass → alert.

### What the card shows

| Severity | Meaning |
|---|---|
| severe | Verified alert |
| candidate | Sustained and significant, but unverified |
| note | Other held candidate |
| withinLimits | Nothing open, or everything explained |

A logged confounder day caps non-safety alerts at candidate. Escalation pushes key on the verified level (3 safety, 2 multi-source, 1 single source + model).

---

## 5. Server models on the VPS (`Tools/AnomalyService`, `frwhoop-anomaly.service`)

Filled in from the model prototype and the deploy, see §8:

- the pinned TimesFM 3.0 and UniTS revisions, sha256 and licenses;
- the data trigger: `scoring_jobs_v2` completions → `enqueue_anomaly_jobs_v1`, throttled to 10 min per owner;
- minute features read from `noop_*`, `activity_context_runs` and `server_metric_series`;
- per-model calibrated p from the owner's own history;
- `anomaly_candidates` and `anomaly_window_scores`;
- the `scores/anomaly-candidates` route;
- the phone's `AnomalyCandidateRepository`.

---

## 6. Reliability (WatchdogService, notify policy, background)

Filled in from the reliability branch:
- device binding;
- device family;
- R-R de-duplication (one transport, live splice only after the stored range, 333 / 500 ms fills, pileups);
- the quality feed;
- the stale "queued" notify;
- safety spacing;
- background cold start;
- single-flight ticks.

---

## 7. Consistency across features

Filled in from the consistency branch (`BaselineStandard.swift`):
- ln HRV;
- causal folds;
- confounder exclusion;
- n ≥ 4;
- shared floors;
- device eras;
- calendar windows;
- Charge, Readiness, Illness, Cycle, Stress, Today and Coach.

---

## 8. Measured results

### Layer 1 null calibration

Synthetic AR(1) nightly series, 6 seeds × 420 days per row (`LongitudinalBaselineV2CalibrationTests`).

| Series | φ | Daily off (nominal 5%) | 2-of-3 | False episodes per series-year | False drift | False trend 28 / 90 |
|---|---|---|---|---|---|---|
| sleep RHR | 0.0 / 0.3 / 0.5 | 4.4 / 4.3 / 4.3% | 1.2–1.8% | 0.84 / 1.18 / 1.35 | 0–0.4% | ≤ 0.8 / ≤ 2.1% |
| sleep ln-HRV | 0.0 / 0.3 / 0.5 | 4.5 / 4.7 / 4.8% | 1.4–2.2% | 0.68 / 1.35 / 1.52 | ≤ 0.4% | ≤ 0.8 / ≤ 2.1% |
| sleep temp | 0.0 / 0.3 / 0.5 | 3.4 / 2.8 / 3.1% | ≤ 1.5% | 0.84–1.01 | 0% | ≤ 0.8 / ≤ 2.1% |
| sleep resp | 0.0 / 0.3 / 0.5 | 3.8 / 3.5 / 3.4% | ≤ 1.5% | 0.68–1.01 | 0% | ≤ 0.8 / ≤ 2.1% |

For comparison, v1 on the same kind of series: 8.5–10.5% daily off-rate, and the change detector never fired.

### Layer 1 steps and ramps (φ = 0.3)

| Shift | Episode detected | Median alarm delay | Visible 60 days later |
|---|---|---|---|
| 2 SD step | 7–8 of 8 | 8–9 days | 8 of 8 |
| 1.5 SD step | 6–7 of 8 | 9–10 days | 6 of 8 |
| 1 SD step | 4–5 of 8 | 24–25 days | 3 of 8 |

Ramps of 0.25 SD/week and 0.5 SD/week were reported in 6 of 6 runs. Trend became significant after a median of 45 and 30 days; drift after a median of 50 and 32 days.

### Watchdog scenarios

Synthetic, the real pipeline, one tick per minute (`WatchdogV2ScenarioTests`).

| Scenario | Notifications | False | Detected | Delay |
|---|---|---|---|---|
| Quiet sitting 8 h | 0 | 0 | — | — |
| Walking bouts | 0 | 0 | — | — |
| Exercise + recovery | 0 | 0 | — | — |
| Sleep 8 h | 0 | 0 | — | — |
| Motion artifacts | 0 | 0 | — | — |
| Off wrist | 0 | 0 | — | — |
| Short HR spike (4 min at 135) | 0 | 0 | — | — |
| Resting HR +27 bpm, no model | 0 (held 110 min) | 0 | n/a by design | — |
| Resting HR +27 bpm + both models | 1 | 0 | 1/1 | 14 min |
| Model window during exercise | 0 | 0 | — | — |
| Resting HR 132 | 1 | 0 | 1/1 | 10 min |
| Awake HR 36 | 1 | 0 | 1/1 | 10 min |
| SpO₂ 86% asleep | 1 | 0 | 1/1 | 5 min |

### Real data

The owner's own WHOOP 5/MG phone history: 7.5 days, 2,143 five-minute ticks, 3.8 ms per tick.
- 0 notifications and 0 candidates.
- Every Layer 1 reference was still learning: 4 of 11 server nights fell inside the gapped 60-day window. So this checks quiet behaviour and quality gating, not detection power.
- Minute quality: on body for 92% of minutes; signal good 40%, degraded 11%, poor 17%, unknown 31%. Motion was unknown for most of the history because dynAccel exists only in the last 24 h of the export.

Model results on real data and the TimesFM / UniTS contribution analysis: see §5 once deployed.

---

## 9. Limitations

- **No clinical validation.** Every result is synthetic or from one person over ≤ 34 days. Thresholds are engineering choices with literature anchors (Apple HR notifications 10 min; SpO₂ 88% oxygen threshold; Plews ln-RMSSD; PhysiologyContext CUSUM), not validated operating points.
- **Wrist posture is weak.** The lying and standing strata will mostly be empty.
- **WHOOP SpO₂** is a strap estimate during sleep, with ±3–4% error.
- **Personal deviations** alone (beat stream only) never alert without a second sensing path or the server models. If the VPS is down, only safety extremes can notify.
- **TimesFM 3.0 weights** are under the TimesFM Non-Commercial License v1.0. The owner accepted the production-use risk; the weights must stay on the private VPS.
