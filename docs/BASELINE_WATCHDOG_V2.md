# Baseline and Watchdog v2 (`v2.clinical` / `watchdog-v3.1`)

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
- **Still.** Intensity known and ≤ 0.40. Unknown motion is never rest, and neither is an `in_vehicle` row (a seated
  ride, however still the wrist reads).
- **Steady state.**
  - The first interval of every still bout is dropped, and anything within 120 s of a posture change.
  - Anything within 10 min after walking, or 30 min after running, cycling or vigorous activity, is dropped.
- **Day values.**
  - HR is the sample-weighted mean of the qualifying intervals.
  - HRV is the pooled √(Σd²/Σn), with ≥ 120 pairs.
  - The within-day scale is a weighted MAD (≥ 3 intervals).
- **Coverage gates.** Posture ≥ 15 min; walking ≥ 10 min; sleep HR ≥ 120 min.

### How the strata fill

Each posture stratum fills from the person's own qualifying minutes: ≥ 15 minutes of steady-state, agreeing posture on a day, on enough days to establish the 60-day copy. The owner's first week was mostly seated, so only "seated" has filled so far; lying and standing fill as those postures accumulate. Until a stratum is established, the Watchdog uses the pooled awake-rest reference for that minute, never a sleep series.

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

### Expected values on the phone: the person's baselines, no model (`WatchdogExpectation.swift`)

The phone runs **no model**. The bundled "UniTS" (`UniTS_AD`, a ~25k-parameter Core ML student plus a hand-coded physics prior and short-term trailing centers) and "TimesFM" (`TimesFM3_Student`, a forecast student) are deleted, with their Core ML assets, loaders and ~40 physics-prior constants.

Each minute's expected value and spread is the person's own **established Layer 1 reference for that minute's context**:

| Minute | HR / RHR | HRV | Temp | Resp | SpO₂ |
|---|---|---|---|---|---|
| asleep | sleep HR | — | sleep temp | sleep resp | sleep mean |
| awake still (lying / sitting / standing) | posture stratum, else pooled awake rest | posture stratum, else pooled | — | — | awake-rest mean |
| walking | walking HR | — | — | — | — |
| vigorous, recovery (30 min / 10 min after walking), 2 min after a transition, unknown | — | — | — | — | — |

- Spread = √(between-day² + within-day²) of that reference; HRV is drawn as e^c with half-width e^c·sinh(s).
- "—" means nothing is drawn and nothing is scored. The **measured value always shows**.
- Until a context's baseline is established (60-day copy), that context has no expected line. This is by design: the baseline has to be learned before it can be used, and nothing stands in for it in the meantime.
- What is active from day one: the safety extremes (§4). Then, as baselines establish, the personal-deviation detector per context. On the VPS, TimesFM 3.0 and UniTS start flagging once their own per-user calibration has 96 windows per context (§5).

---

## 5. Server models on the VPS (`Tools/AnomalyService`, `frwhoop-anomaly.service`)

The models produce **candidates**, never notifications. A candidate reaches the phone through
`scores/anomaly-candidates` → `AnomalyCandidateRepository` → `WatchdogDetectors.server`, and then passes the same
five checks as every other candidate (§4). It must have ≥ 5 minutes in view and be ≤ 30 min fresh, otherwise it is
suppressed.

### Models (pinned; the host verifies sha256 at install)

| | TimesFM 3.0 | UniTS x128 |
|---|---|---|
| Code | google-research/timesfm `e51928e2` (Apache-2.0) | mims-harvard/UniTS `0e028148` (MIT) |
| Weights | HF `google/timesfm-3.0-pytorch` @ `43046b85`, `model.safetensors` sha256 `a7592b0a…7da` | release `ckpt`, `units_x128_pretrain_checkpoint.pth` sha256 `35d17336…474` |
| Weights license | **TimesFM Non-Commercial License v1.0**: owner accepted the production risk; the weights stay on the VPS | MIT |
| Size | 330.7 M params, 1.32 GB fp32 | 2.8 M params (+ ~10 k per-user prompt) |
| Use | zero-shot forecast | per-user prompt tuning through UniTS' imputation path |

**TimesFM recipe (lag 360).**
- Context: 1024 minutes of the 5 targets (HR, ln RMSSD, skin temp, resp, SpO₂), ending 6 h before the scored 30-minute window.
- Covariates (dyn, steps, asleep) are given through the window.
- Each minute's residual is z = (obs − q50) / ((q90 − q10) / 2.563), with per-channel σ floors.
- Why the lag: forecasting from the minutes right before the window absorbs a sustained shift within one window (AUROC 0.59–0.79 in the prototype); the 6 h lag keeps it visible (0.925).

**UniTS recipe.**
- The official AD recipe reconstructs a per-window-normalised input and misses level shifts (AUROC ≈ 0.5).
- Instead: hide the targets in the last 384 minutes of a 1024-minute window, keep covariates visible, and score the last 30.
- The per-user prompt is trained once ≥ 24 h of usable minutes exist. It is re-trained when history has grown 3× (early life) or weekly, and a re-train restarts that model's calibration.
- VPS budget: 400 windows × 2 epochs.
- Residuals are robust-standardized by the user's own post-training median / MAD.

### Data path

1. **Trigger.** `enqueue_anomaly_jobs_v1` reads `scoring_jobs_v2` completions (raw data has landed). There is no trigger on `noop_*` and no use of the scoring-inputs advisory lock. It is throttled to 10 min per (owner, device), and `p_users` limits it to listed owners (staged rollout: the owner only).
2. **Lease.** Leased jobs with a revision fence. A keep-alive thread renews the lease and feeds the systemd watchdog for at most 25 min per job.
3. **Features** (`features.py`): per-minute HR, R-R → RMSSD (one transport, de-duplicated, fills and suspects dropped, Malik 20 %, ≥ 20 pairs in 5 min), skin temp (W4 anchor or centidegrees), resp (`server_metric_series`), SpO₂ (strap estimates), dyn, steps and sleep.
4. **Context.** From the server activity classifier's 30 s epochs (`activity_context_epochs`, latest revision, confidence ≥ 0.6), else from the sensors. Then the Layer 1 steady-state rule on bouts: 30 min after ≥ 3 active minutes, 10 min after a ≥ 2-minute walk, otherwise a 2-minute settle.
5. **Minute cache.** 7 days, dense grid; a job re-reads only the last 3 h.
6. **Windows.** 30 min, scored once when complete (5 min settle). A window is withheld for off-wrist, < 70 % HR coverage, or < 70 % still/asleep (activity or recovery). Bucket: sleep if ≥ 50 % asleep, else rest.
7. **Calibration** (`calibration.py`).
   - Each channel's directional window score gets an empirical p against the same user's own unflagged windows of the same bucket, with a conservative peaks-over-threshold tail: the 95 % upper bound of the exponential scale.
   - Channels are combined by Bonferroni over observed channels, which is valid under any dependence.
   - Nothing is flagged until a bucket has 96 reference windows.
8. **Reference growth (quarantined, no silent drift).** A window joins the reference only once ≥ 6 h old, unflagged, and with no window of either model flagged within 6 h. The slowly-building onset of an event that is flagged later never becomes "normal". The reference is a ring of the last 1,400 windows per bucket. Weeks-long drift is Layer 1's job (frozen anchor, drift and trend tests, §2), not the models'.
9. **Flag rules** (per model, α = 1e-3):
   - **window:** one 30-minute window with p < 1e-3;
   - **sustained:** the mean of the last 4 windows (2 h, same bucket, ≤ 1 gap) per channel, calibrated against contiguous rolling 4-window means of the same reference (reference rows carry their window start). Overlapping means carry ~n/4 independent values, so body p and tail bound use n_eff = n/4 with an 80 % bound; Bonferroni over channels; p < 1e-3. It catches 2-hour moderate shifts (fever ramp, HRV collapse) where no single window is extreme.
10. **Candidates.**
    - A run of consecutive flagged windows (either model, either rule) is one candidate, with a stable key across jobs and beyond the 18 h recent memory.
    - Severity is "strong" when both models flag and min p < 1e-4. `context.rules` and `context.evidence_from` record why and since when.
    - Publish is fenced, and candidates missing from a re-score are retracted.
    - Each window is scored once, when complete. A thin reference backfills ≤ 30 h once per scorer generation (UniTS prompt).

### Calibration under the null (40 references per cell, 5 channels; `tests/test_core.py` + simulation)

| Reference windows | Gaussian | t4 (heavy tails) | ρ = 0.6, t5 |
|---|---|---|---|
| 96 | 0.24 × 10⁻³ | 1.06 × 10⁻³ | 0.97 × 10⁻³ |
| 192 | 0.14 × 10⁻³ | 1.44 × 10⁻³ | 0.59 × 10⁻³ |
| 400 | 0.07 × 10⁻³ | 1.39 × 10⁻³ | 0.48 × 10⁻³ |
| 1400 | 0.04 × 10⁻³ | 1.90 × 10⁻³ | 0.83 × 10⁻³ |

Values are the rate of p < 1e-3 (nominal 1 × 10⁻³). The first implementation re-calibrated min-p on the reference, which gave 4–16 × nominal with 96 windows. It ranked −min p, a bounded statistic, so even a 6 SD window could not go below p ≈ 1/(n+1). It was replaced.

**Operating point under dependence.** Window scores are autocorrelated, so the choice was made on a grid: AR(1) window scores, φ 0 / 0.5 / 0.8, references 120–1400 windows, 5 channels, 10–12 references per cell. Power is per window at α = 1e-3.

| Rule / calibration | Null rate at 1e-3 (worst cell) | Power | Chosen |
|---|---|---|---|
| Window, i.i.d. p, 95 % tail bound | 4.1e-4 | +4 SD window: 0.25–0.36 | ✓ |
| Window, + lag-1 effective n | ≈ 0 | 0–0.04 (φ ≥ 0.5) | ✗ (in the replay, SpO₂ dips 6/9 → 0/9) |
| Window, 50 % tail bound | 1.3e-2 (n = 120, φ = 0.8) | 0.5–0.7 | ✗ (anti-conservative) |
| Sustained, i.i.d. | 1.7e-3 (n = 200, φ = 0.5) | +1.5 SD × 4: 0.005–0.066 | ✗ |
| Sustained, n_eff = n/4, 80 % bound | 9e-4 | 0.002–0.059 | ✓ |
| Sustained, lag-1 effective n | 0 | 0 | ✗ |

### Deploy (2026-10-08)

- Unit `frwhoop-anomaly` (user `frwhoop-anom`) on frwhoop-worker-2: CPUQuota 100 %, MemoryHigh 2.8 G / Max 3.3 G, OOMScoreAdjust 500.
- It is separate from `frwhoop-worker`, `frwhoop-worker-oura` and `frwhoop-inference`, none of which were touched. Host note: `/opt/DEPLOY-NOTE-anomaly-models.txt`.
- Migration `20261007180000_anomaly_service` was applied to production and recorded in `schema_migrations`.
- The `scores` function with the `/anomaly-candidates` route is **not deployed**: the deploy was not permitted from this session. Deployed v19 equals this branch minus the route.

---

## 6. Reliability (WatchdogService, notify policy, background)

Merged from the reliability branch (196 Watchdog tests, 664 WhoopStore tests):

- **Device binding.** A tick reads only the bound strap's streams. The device family comes from the registry, not the legacy label.
- **R-R de-duplication.**
  - One transport per window (pinned channel).
  - The live splice is used only after the stored range.
  - 333 / 500 ms fill beats are dropped when HR < 100.
  - Pile-ups are rejected.
  - Measured on real windows: RMSSD 111.9 → 73.5 ms, where the duplicate beats had inflated it.
- **Quality feed.** On-body, signal and motion are tri-state, with unknown kept as unknown (§4).
- **Notify policy.**
  - A queued notification older than 120 s is dropped, not delivered late.
  - A safety re-notification waits ≥ 3600 s.
  - Pushes are spaced by ≥ 600 s.
  - Escalation keys on the verified alert level, so a corroborated episode notifies once.
- **Background.** A cold start runs one tick. Ticks are single-flight, and heavy work is off the main actor.

---

## 7. Consistency across features (`BaselineStandard.swift`)

One standard for every place that compares a value with "your usual" (15 + 10 consistency tests on a 120-night tape with an SDNN night, confounded nights, a WHOOP 4.0 → 5.0 change and a missing week):

1. HRV is modelled on ln, and SDNN nights never enter or get scored against an RMSSD reference.
2. Causal folds: a day is judged only against days before it (no look-ahead).
3. Confounded days (illness, alcohol, travel…) are scored but never folded, with the same key as Layer 1.
4. No z under 4 usable days; "trusted" needs ≥ 14.
5. Scale floors come from `PhysiologyContext.ReferenceConfig`, so a flat history cannot produce a huge z.
6. Device eras: a confirmed family change and a manual Recalibrate open a new reference.
7. Robust windows are median / 1.4826·MAD over calendar days.

Charge (phone and server driver gating), Readiness, Illness, Cycle, Stress (daily and daytime), Today's insight and the Coach now use it. Measured on a realistic 90-night tape, phone Charge moved by a median |Δ| of 4.0 points (p90 9.1, max 12.5). Of that, ln vs ms alone accounts for a median of 0.8. The illness-night mean Charge went from 8.6 to 6.5.

**Not yet on the standard** (follow-ups):
- The worker's `DayScoring.loadBaselines` is still raw-ms HRV over the last 120 rows.
- WeeklyDigest and ComparisonEngine still use raw ms.
- The Kotlin/Android twins are not ported.

A strap swap (4.0 ↔ 5.0) now resets Charge baselines, as rule 6 requires. People who alternate straps would sit in Calibrating; this needs an owner decision.

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

The owner's own WHOOP 5/MG phone history: 7.5 days, 2,143 five-minute ticks, 3.4 ms per tick.
- 0 notifications and 0 candidates.
- Every Layer 1 reference was still learning: only 11 server nights exist (since 2026-09-20). So this checks quiet behaviour and quality gating, not detection power.
- Minute quality marginals:
  - on body 89.0 %, off 0.2 %, unknown 10.8 %;
  - signal good 43.4 %, degraded 12.8 %, poor 17.9 %, unknown 25.9 %;
  - motion still 10.7 %, moving 1.7 %, artifact 0.7 %, unknown 86.9 % (dynAccel exists only in the last 24 h of that export).

### Server models: TimesFM 3.0 + UniTS x128 (real models, `Tools/AnomalyService/tools/replay.py`)

**Method.** The replay drives the service's own `score_frame`, with both real models, the per-user calibration and candidate formation, tick by tick (every 30 min). Each run starts from an empty state, so warm-up and UniTS prompt-tuning happen as on the VPS (production budget 400 × 2).
- The synthetic data are the model prototype's generator: 3 users × 24 days (14 history + 10 test), with walking, exercise, recovery, sleep, off-wrist and injected artifacts.
- The test days carry 4 event types × 3 per user.
- An event counts as detected if a candidate overlaps it (end slack 1 h).
- A candidate in the history period, or not overlapping any event in the test period, is false.

**Final configuration** (release `fcd7cad23`):

| Event (9 each) | Detected | TimesFM flagged | UniTS flagged | Both | Median delay (range) |
|---|---|---|---|---|---|
| Resting tachycardia (+25 bpm, 60 min) | 8/9 | 7 | 5 | 4 | 61 min (47–84) |
| SpO₂ desaturation cluster (sleep, 90 min) | 8/9 | 3 | 6 | 1 | 69 min (61–98) |
| Fever-like (6 h ramp + 2 h plateau) | 9/9 | 7 | 7 | 5 | 285 min (126–313) |
| HRV collapse overnight (4 h) | 8/9 | 8 | 3 | 3 | 68 min (52–144) |
| **All** | **33/36** | 25 | 21 | 13 | |

- **False candidates:** 1 in 30 test user-days and 1 in 39 history user-days (0.03 per user-day, about 1 per month). Neither was "strong". A candidate is not an alert: the phone's five checks decide, and a single-group candidate with only server corroboration is held (§4).
- **Model contribution:**
  - TimesFM alone would catch 25/36; it is stronger on HRV collapse (8 vs 3).
  - UniTS alone would catch 21/36; it is stronger on SpO₂ (6 vs 3).
  - The union catches 33/36: 12 events were flagged only by TimesFM, 8 only by UniTS, 13 by both.
- **Delay:** includes the 30-min window, the 5-min settle and the 30-min replay tick. On the VPS the trigger is ~10 min after each scoring completion.
- **The 3 misses** came closest at p ≈ 1–2 × 10⁻³ (one tachycardia, one HRV collapse, one SpO₂ cluster).
- **UniTS budget:** 1000 × 3 (prototype) was not better than 400 × 2 (10/36 vs 16/36 in the same intermediate configuration), so the VPS uses 400 × 2.

**How the configuration was reached.** Each step was found by this replay, not by the unit tests:

| Configuration | Detected | False (69 user-days) |
|---|---|---|
| 1. Re-score at watermark, reference grows only while thin | 29/36 | 1 |
| 2. Score once, unaligned watermark (bug: most windows never scored) | 0/36 | 0 |
| 3. Score once, reference grows with every unflagged window ≥ 1 h old | 17/36 | 0 |
| 4. + quarantine, sustained rule, lag-1 n_eff on everything | 16/36 | 0 |
| 5. **+ operating point from the dependence grid (§5)** | **33/36** | **2** |

What each step showed:
- Step 1 froze the reference on early history; a long-lived user would never adapt.
- Step 2 was a real bug, found and fixed.
- Step 3: the onsets of slow events became "normal" (silent drift), and fever fell to 1/9.
- Step 4: over-conservative; SpO₂ fell to 0/9.

**Real data (owner, read-only export of 18 days, HR on 8 of them).**
- Windows: 147 usable (TimesFM) and 148 (UniTS); withheld 130 for activity, 94 for low HR coverage, 24 for unknown context, 17 off-wrist.
- Both models are still **calibrating**: no bucket reached 96 quarantined reference windows in 8 days, so there are 0 candidates. The models need about 1–2 weeks of a person's nights and about 2–3 weeks of awake rest before they can flag anything.
- Held-out check on the reference collected (first 60 % as reference, last 40 % scored, no injected events): 0 of 109 windows at p < 0.05 (min 0.10), and 0 of 58 sustained 2 h spans at p < 1e-3 (min 2.5e-3).

**On the VPS** (frwhoop-worker-2, 4 vCPU 2.0 GHz, unit limits CPUQuota 100 %, 2 threads):
- Self-test with the real models: TimesFM 6.05 s per window, UniTS 0.36 s per window, peak RSS 2.34 GB. Both separate a planted +20 bpm shift (TimesFM HR score 2.0–3.6 vs ≤ 0.37; UniTS 2.4–3.2 vs ≤ 0.05).
- The first job on the owner's strap ran the UniTS prompt-tune (400 windows × 2 epochs, 480 s, loss 0.57 → 0.50) and published per-window scores; it is calibrating.
- Capacity at one core: steady state is ≈ 6–9 s of CPU per active user-hour (about one usable window per hour at 6 s, plus weekly UniTS training of ~8 min amortised to ~3 s/h), so one core sustains a few hundred users. Onboarding is the bottleneck: a 30 h backfill plus the first prompt-tunes take ≈ 10–20 min per new user. Beyond that, add cores or a cheaper TimesFM path (bf16, shorter context).

---

## 9a. What is deployed, and what ships with the app

**Live now (2026-10-08):**
- VPS `frwhoop-anomaly`: TimesFM 3.0 + UniTS, owner account only (`FRWHOOP_ANOMALY_USERS`).
- Production migration `20261007180000_anomaly_service`.
- `scores` v21 with `/anomaly-candidates`. v20 was the metric-insights session's deploy; v21 adds only this route.

These are additive. The installed phone does not read the new route yet, so nothing changes for it.

**Ships together with the phone build that carries this branch:**
- Layer 1 `v2.clinical`, and a Watchdog that runs no on-device model.
- The MetricInsight server's Layer 1 port (`Tools/MetricInsight/src/nara_metric_insight/layer1.py`, pinned bit-exact to the app by `LayerOneServerMirrorTests` / `test_layer1.py`). Deploying it earlier would make the server's explanations disagree with a phone still on v1.

## 9. Limitations

- **No clinical validation.** Every result is synthetic or from one person over ≤ 34 days. Thresholds are engineering choices with literature anchors (Apple HR notifications 10 min; SpO₂ 88 % oxygen threshold; Plews ln-RMSSD; PhysiologyContext CUSUM), not validated operating points. The synthetic events (3 users, 36 events) are the prototype's generator: read detection rates as relative, not as field sensitivity.
- **Model warm-up is long.** The server models need 96 quarantined reference windows per context (about 1–2 weeks of sleep, 2–3 weeks of awake rest). Until then they abstain ("calibrating") and only the on-device detectors run.
- **Baselines take time.** Nothing on the phone stands in for a model or a baseline. Each context's expected line appears once that baseline is established, and the server models need 1–2 weeks of nights and 2–3 weeks of awake rest. Until then only the safety extremes and the established contexts are active.
- **Posture strata fill with use.** Each posture needs its own qualifying minutes on enough days; the owner's first week (mostly seated) filled "seated" first.
- **WHOOP SpO₂** is a strap estimate during sleep, with ±3–4 % error.
- **Personal deviations** alone (beat stream only) never alert without a second sensing path or the server models. If the VPS is down, only safety extremes can notify.
- **The phone cannot read server candidates yet.** The `scores` route `/anomaly-candidates` is built and tested (30 route tests) but was not deployed: the deploy was blocked by this session's permissions. Deployed v19 equals this branch minus that route, so deploying it rolls nothing back:
  `supabase functions deploy scores --project-ref sgoyxzcagqyxexmsidtk --use-api` from this worktree.
- **Staged rollout:** the VPS service runs for the owner's account only (`FRWHOOP_ANOMALY_USERS`). It connects as the same database role as the worker (no least-privilege role yet).
- **TimesFM 3.0 weights** are under the TimesFM Non-Commercial License v1.0. The owner accepted the production-use risk; the weights must stay on the private VPS.
- **Not yet on the baseline standard:**
  - the worker's `DayScoring.loadBaselines` (raw-ms HRV, last 120 rows);
  - WeeklyDigest and ComparisonEngine;
  - the Kotlin/Android twins.
- **App tests:** StrandTests run 3084 tests, with 3 failing tests in files this branch does not touch (activity calibration ×2, a Coach wording test). They fail on main too; main's test target did not compile before three small fixes on this branch.
