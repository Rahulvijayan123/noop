# System-level comparison of the activity decoder arms — STAND-IN, NOT INERTIA-1

Status (2026-10-05 20:45 PDT): **measured.** Phase 1 (HART reproduction, inputs) and Phase 2 (Swift decoder
replay of A0s / A0 / A1 / A2 / A3 / NAV on WISDM and Capture-24, plus a random-init negative control) are
complete with P2's primary stand-in bundle `shadow-primary-hc`. Headline (stand-in only): the heads help
locomotion when they are the only motion channel, add essentially nothing on top of HART, and their large
Capture-24 posture gain is sleep-like lying, not awake posture (§5).

No public Inertia-1 checkpoint exists (INERTIA1.md, header). Every "Inertia" arm below runs a **stand-in**
encoder bundle produced by agent P2 (`encoder_id` starting `standin:`); it says nothing about Inertia-1
itself. Arms are compared on public wrist data (WISDM-2019 watch, Capture-24) through **proxies** of the
WHOOP 1 Hz strap streams; the decoder's priors were set on the WHOOP strap's own `dynAccel`, so these
numbers support comparisons **between arms**, not absolute accuracy claims about the product.

Machine-readable twin: `SYSTEM_COMPARISON.json`. Code: `activity_context/inertia/replay_{data,export,inertia,
score,eval,report}.py`; tests `tests/inertia/test_replay_{export,score,eval}.py`. Scratch, caches and raw
replay outputs (outside git): `research/inertia-replay/`.

## 1. Arms

| arm | per-second inputs (identical in every arm) | encoder channel | Inertia channels |
|---|---|---|---|
| A0s | 1 Hz gravity + dynAccel proxy | — | — |
| A0 | A0s + imu-feat-1 windows (4 s / 2 s) | — | — |
| A1 | A0 | HART (production serve path) | — |
| A2 | A0 | — | stand-in motion heads (candidate mode) |
| A3 | A0 | HART | stand-in motion heads (candidate mode) |
| NAV | A0 | 0.5·HART + 0.5·stand-in locomotion folded onto the v1 labels (forbidden by spec §17; ablation only) | — |

The Swift harness (`ActivityReplayHarness.swift`, format `nara-activity-replay-1`) derives every arm from
ONE observation stream per sequence, so the non-encoder inputs are identical by construction (also checked:
sha256 of the shared fields per sequence across file variants). Its `streams` arm drops the imu-feat-1
windows as well as the encoder while its `inertia` arm keeps them, so the engineered baseline that A2 must be
compared with is **A0 = harness `hart` arm on a file with no encoder windows**; A0s is reported for
completeness.

## 2. Phase 1a — HART on HART's own held-out WISDM test subjects

Split: HART's seed-42 split (`activity-train/out/split_manifest.json`): test 1605, 1607, 1617, 1627, 1638,
1646, 1648, 1650. Model `hart-wisdm-v0`, `model.safetensors` sha256 `39dc12e0…3b2f`, loaded through the repo
adapter (`activity_context.model.HARTModel` + manifest; strict verify-on-load), probabilities rounded to 6 dp
and labelled with the manifest abstention exactly as `serve.classify_windows`, `feat` = imu-feat-1.

Preprocessing (production-faithful): each (subject, activity block) is its own recording (split at activity
change, gap > 1 s or non-increasing timestamps; never concatenated); each sensor's **native rate is detected
per block** (20.01 Hz for most; subject 1638: accel 49.8 Hz and gyro 24.8 Hz; 1638's H and O blocks have no
gyro at all and are excluded from every HART-dependent number), units m/s² → g and rad/s → deg/s, each
sensor resampled to 30 Hz with the repo polyphase resampler (`resample_poly_nd`: 20→30 = 3/2, 25→30 = 6/5,
50→30 = 3/5; samples taken as uniform at the nominal rate), gyro aligned onto the accel's 30 Hz grid, then
4 s / 2 s windows with serve's semantics (grid anchored at the recording start, 1 s FIR-transient margin at
both edges, window fully inside).

| run | windows | accepted | coverage | macro-F1 | accepted acc. | stationary P/R | walking P/R | running P/R | other P/R |
|---|---|---|---|---|---|---|---|---|---|
| eval/RESULTS.md re-run on `eval_data.npz` (bit-for-bit reproduction) | 15,363 | 10,205 | 0.664 | 0.660 | — | 0.860/0.441 | 0.890/0.392 | 0.997/0.714 | 0.782/0.604 |
| **production-faithful** (real gyro, per-block native rate, serve windows) | 12,493 | 6,829 | 0.547 | 0.701 | 0.874 | 0.859/0.566 | 0.907/0.529 | 0.936/0.922 | 0.869/0.374 |
| diagnostic: gyro zeroed (what HART was actually trained on, see below) | 12,665 | 9,202 | 0.727 | 0.733 | 0.841 | 0.915/0.469 | 0.888/0.483 | 0.995/0.918 | 0.796/0.678 |
| first attempt: linear timestamp re-grid before polyphase (rejected) | 12,354 | 6,446 | 0.522 | 0.668 | 0.839 | 0.844/0.404 | 0.872/0.539 | 0.926/0.922 | 0.813/0.398 |

By native rate (production-faithful): 20 Hz blocks coverage 0.561 / macro-F1 0.712 / accepted accuracy
0.896 (11,117 windows); the 50 Hz subject 1638 coverage 0.430 / 0.586 / 0.637 (1,376 windows). Per-subject
coverage 0.43–0.64.

Why the numbers differ from eval/RESULTS.md:

1. **HART was trained and evaluated on mostly-zero gyro.** `activity_context.train._finish_block` aligns gyro
   to accel with `np.searchsorted` over the gyro file's timestamps, but WISDM timestamps jump at activity
   changes, so the array is not sorted; unmatched samples are set to 0. Measured: **82 % of HART's training
   windows and 83 % of its `eval_data.npz` windows carry all-zero gyro** (160 of 198 blocks of the checked
   subjects fully zero). The production serve path always has real WHOOP gyro, so the production-faithful
   run (real gyro) is the honest operating condition: coverage drops 0.66 → 0.55 while accepted precision
   stays 0.86–0.94. Zeroing the gyro on the same corrected windows restores the 20 Hz subjects' coverage to
   0.77 (RESULTS.md per-subject 0.66–0.83), confirming the cause. *This is a bug in `train.py` (not owned
   here): the fix is to merge per block (or sort the gyro rows) before `searchsorted`; HART then needs
   retraining.*
2. **The 50 Hz blocks were treated as 20 Hz.** `train.py` assumes 20 Hz everywhere, so 1638's 3-minute
   blocks became 7.5-minute, 2.5×-slowed signals (3,996 of RESULTS.md's 15,363 windows). With the correct
   50→30 Hz resampling 1638 has 1,376 windows; its accuracy stays poor (0.64 accepted accuracy) because HART
   was trained on slowed versions of such blocks too.
3. **Serve windowing** drops the first and last window of every block (1 s transient margin): 87 instead of
   89 windows per 180 s block.
4. The rejected first attempt re-gridded each block linearly onto the exact nominal grid using the device
   timestamps; at drifting fractional offsets that is a low-pass (gain cos(πf/fs), 0.71 at 5 Hz on a 20 Hz
   stream) and moved inputs away from what HART was trained on (raw sample index), so it was dropped.

Typing/writing (F/Q) still read as `stationary` with high confidence (F: 595/695 windows), as documented in
RESULTS.md.

HART model tests (`tests/test_model.py`, hart-repro venv + pytest in a separate target dir):

* `ACTIVITY_HART_CHECKPOINT=…/activity-train/out` (the fine-tuned checkpoint): 2 passed, 1 failed, 1 error —
  `test_exactly_eight_new_head_tensors` fails and the `model` fixture errors with `checkpoint corrupt:
  model.safetensors sha256 mismatch (39dc12e0… != 88b8d179…)` because the fixture manifest
  `fixtures/manifest.hart.example.json` pins the **pretrained** digest. Not a model defect.
* `ACTIVITY_HART_CHECKPOINT=…/activity-python/checkpoint` (the pretrained checkpoint, sha256 `88b8d179…`):
  **4/4 pass**. The rest of the legacy suite passes (4 skips).

## 3. Phase 1b — inputs the decoder sees

Per-second strap-stream proxies from wrist accel only (computed on the 30 Hz HART-path stream; second `i`
covers `[t0+i, t0+i+1)` and its observation is stamped `t0+i+1`):

* gravity = mean accel over the second (g; the decoder uses its direction only);
* dynAccel proxy, **chosen on TRAIN subjects only** (12 WISDM train subjects' D/A/B blocks, 10 Capture-24
  train participants) as the candidate whose per-class medians are closest (log10 RMS) to the strap anchors
  in `ActivityContextEvidence.swift` (rest ≈ 7 mg, walking median ≈ 135 mg, running median ≈ 400 mg):

| candidate | rest | walking | running | log10 RMS error |
|---|---|---|---|---|
| **RMS of \|a\| − LP0.5Hz(\|a\|) (magnitude AC) — chosen** | 9 mg | 166 mg | 741 mg | 0.18 |
| mean of max(\|a\| − 1, 0) (ENMO) | 5 mg | 80 mg | 695 mg | 0.21 |
| \|a − LP(a)\| at one instant per second | 16 mg | 208 mg | 1276 mg | 0.37 |
| mean \|a − LP(a)\| | 20 mg | 246 mg | 1399 mg | 0.44 |
| RMS \|a − LP(a)\| | 24 mg | 274 mg | 1481 mg | 0.49 |

  Vector gravity removal leaks wrist rotation into the "linear" acceleration; the strap's own definition is
  not documented, so this is a proxy. WISDM's scripted walking reads 270 mg with the chosen proxy (2× the
  strap anchor): WISDM walking and jogging sit near the decoder's running range.
* no steps, no HR, no strapClass, sleep `unknown`, no workouts, wear `onWrist` on every second with valid
  data (no off-wrist detection).
* imu-feat-1 windows: WISDM from the same windows HART sees (real gyro); Capture-24 accel-only with gyro set
  to 0 (`gyro_rms_dps` = 0). The decoder never reads `gyroRmsDps` or `jerkRms` (checked: only
  `ImuFeatureExtractor` defines them), so missing gyro changes nothing downstream except that HART cannot
  run on Capture-24.

Per-second truth (audited crosswalk `research/inertia-work/agentC/label_mappings.json`; identical for WISDM
and Capture-24 to the repo copy `activity_context/inertia/label_mappings.json`): per head a class-set mask,
`used_for_training` rows only ("strict"); MASK where unmappable (never `unknown`); Capture-24 seconds are
labelled only when all 100 samples carry one annotation. Locomotion is scored with `brisk_walking` folded into
`walking` (no dataset here resolves pace).

| data | split | recordings | seconds | labelled | posture truth | locomotion truth | arm truth |
|---|---|---|---|---|---|---|---|
| WISDM | test | 142 blocks / 8 subjects | 25,836 | 100 % | 11 % (D sit, E stand) | 84 % | 22 % (F/Q desk, G/R repetitive) |
| WISDM | val | 158 / 8 | 28,492 | 100 % | 11 % | 84 % | 23 % |
| Capture-24 | test | 50 participants | 4,571,220 | 65 % | 50 % (recumbent mostly = diary sleep) | 61 % | 14 % |
| Capture-24 | val | 20 | 1,883,881 | 67 % | 54 % | 65 % | 16 % |

Capture-24 event truth (P2's `transition_targets` rules: the change lies inside an unannotated gap ≤ 28 s;
not timing ground truth): test walk_start 202, walk_stop 237, sit_to_stand_like 152, stand_to_sit_like 183,
run_start 2.

## 4. Phase 2a — measured: the decoder replay of the bundle-independent arms

Decoder: the current Swift `ActivityContextDecoder` (hsmm-1.3 + S's motion-head extension, motion heads OFF in
these arms) through S's env-gated XCTest `ActivityReplayTests/testReplayFromEnvironment`, built once in release
with `-enable-testing` into a private scratch path (executable sha256 `5b10b94c86d0…`, Swift sources fingerprint
`69d973a59ef2576c` = sha256 of the sorted per-file sha256 list of `Sources/` + `Tests/` at build time). Release
output was checked bit-identical to a debug `swift test` run. Every sequence is decoded independently
(WISDM: one per (subject, activity block); Capture-24: one per participant, gaps reset the belief via
`gapResetS`). States are the published 5-s states; a state at `ts` is scored against the truth of second
`ts − t0 − 1`; MASK seconds are never scored.

Operating points are chosen on VALIDATION only (P2's `abstention.select_operating_point`: strong = smallest
tau with one-sided CP95 lower bound ≥ 0.95, n ≥ 60, recall ≥ 0.10, ≥ 3 subjects, stable above) and applied
once to TEST with P2's one-shot gate (`check_gate`: precision ≥ .95, CP95 lower ≥ .90, n ≥ 30, recall ≥ .05).
"coverage@95" below = TEST recall at the VAL-strong tau when that gate passes, else 0. The "descriptive"
coverage@95 is the best recall on the TEST curve itself with CP95 lower ≥ 0.95 (n ≥ 60) — reported for
comparison, never used to pick anything. CIs are paired subject-cluster bootstraps (P2's
`bootstrap.cluster_bootstrap`, 1000 resamples over subjects; the metric sums per-subject sufficient
statistics of both arms over the same resample). WISDM has only 8 test subjects: P2's bootstrap warns that
percentile CIs under-cover below 10 clusters.

### 4.1 WISDM test (8 subjects, 142 blocks, 5,156 published states; HART's own held-out split)

| arm | coarse 4-class acc | locomotion top-known acc | locomotion AURC | locomotion NLL | ECE | posture AURC | posture NLL | arm NLL | display flips/h |
|---|---|---|---|---|---|---|---|---|---|
| A0s streams only | 0.588 | 0.588 | 0.156 | 2.243 | 0.340 | 0.692 | 1.012 | 3.325 | 39.1 |
| A0 streams + imu-feat-1 | 0.633 | 0.633 | 0.132 | 1.990 | 0.302 | 0.679 | 1.005 | 2.797 | 39.2 |
| A1 + HART | **0.698** | 0.641 | **0.096** | 2.167 | 0.321 | **0.667** | **0.983** | **2.539** | **36.9** |

Operating points (VAL tau → TEST):

| head / class | A0s | A0 | A1 |
|---|---|---|---|
| locomotion stationary | strong τ .30 → P .9995, coverage@95 **0.644** | strong τ .30 → P .9991, **0.685** | strong τ .30 → P .9996, **0.649** |
| locomotion walking (set) | abstain | abstain | weak τ .96 → P .924 (CP .867), recall .319 |
| locomotion running | abstain | abstain | strong τ .64 → **P .860 (CP .824) — fails the test gate**, recall .962 → coverage@95 0 |
| locomotion stairs | abstain | abstain | abstain |
| posture seated / upright | abstain | abstain | abstain |
| arm desk_like | weak τ .30 → P .778 | strong τ .97 → P .991, **0.392** | strong τ .97 → P .991, **0.395** |
| arm repetitive_hand_motion | abstain | abstain | abstain |

Paired differences (B − A, point [95 % CI], ** = CI excludes 0):

| comparison | locomotion NLL | locomotion AURC | stationary coverage@95 | posture NLL | posture AURC | flips/h |
|---|---|---|---|---|---|---|
| A0 − A0s (imu-feat-1) | **−0.254 [−0.339, −0.165]** | **−0.025 [−0.053, −0.003]** | **+0.040 [0.014, 0.068]** | −0.008 [−0.021, 0.006] | −0.014 [−0.038, 0.003] | +0.14 [−1.97, 2.40] |
| A1 − A0 (HART) | **+0.177 [0.002, 0.353]** (worse) | **−0.033 [−0.067, −0.003]** | −0.035 [−0.094, 0.007] | **−0.021 [−0.052, −0.001]** | **−0.011 [−0.041, −0.000]** | −2.30 [−4.55, 0.00] |
| A1 − A0s | −0.077 [−0.260, 0.094] | **−0.058 [−0.113, −0.021]** | +0.005 [−0.048, 0.061] | **−0.029 [−0.063, −0.001]** | **−0.024 [−0.063, −0.002]** | **−2.15 [−3.83, −0.58]** |

What this says (measured, WISDM-scripted activities, proxies of the strap streams):

* imu-feat-1 helps the decoder everywhere it can be measured: better calibrated locomotion and +4 points of
  stationary coverage at ≥ 95 % precision.
* HART improves **ranking** (AURC) and the coarse class, steadies the display label and helps posture a
  little, but makes locomotion **worse calibrated** (NLL +0.18): it sharpens the decoder onto wrong classes.
  Running looks strong on validation and fails on test (precision 0.86). Walking never reaches strong in any
  arm. With these proxies WISDM's scripted walking reads near the decoder's running intensity range (§3), so
  much of the locomotion error is a proxy/prior-scale mismatch, not an encoder property.
* Neither arm can claim sitting vs standing at ≥ 95 % precision (the wrist cannot see body height; expected).

### 4.2 Capture-24 test (50 participants, free-living; no gyro → no HART)

914,242 published 5-s states over 1,270 decoded hours; locomotion truth on 557k states, posture on 454k,
arm on 129k; 776 event-truth intervals.

| arm | coarse 4-class acc | locomotion AURC | locomotion NLL | locomotion ECE | posture AURC | posture NLL | posture unknown mass | display flips/h |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 0.748 | 0.094 | 1.462 | 0.211 | 0.559 | 1.862 | 0.199 | 22.7 |
| A0 streams + imu-feat-1 (accel-only) | **0.793** | 0.096 | **1.308** | **0.168** | **0.528** | **1.761** | 0.172 | 23.1 |

Operating points (VAL tau → TEST): locomotion **stationary** is the only strong class — A0s τ .885 → precision
.955 (CP .955), coverage@95 **0.828**; A0 τ .965 → precision .958 (CP .957), coverage@95 **0.748**. Walking,
running, stairs, cycling, vehicle and other never reach strong (abstain on VAL; running has no VAL truth).
Posture: recumbent 0 everywhere (no sleep evidence — expected, §6.2); seated_likely is weak for A0 (τ .58 →
TEST precision .854, fails the gate; descriptive coverage@95 0.25), upright never. Arm head: nothing reaches
weak.

Paired A0 − A0s (50 participants): locomotion NLL **−0.155 [−0.187, −0.126]**, posture NLL **−0.100
[−0.109, −0.092]**, posture AURC **−0.032 [−0.038, −0.026]**, locomotion AURC −0.004 [−0.010, 0.002],
stationary recall at each arm's VAL-strong tau **−0.080 [−0.089, −0.072]** (the engineered windows make the
decoder less extreme about stillness, so VAL picks a higher tau), display flips **+0.41/h [0.08, 0.79]**.

Events (decoder's flagged events vs ≤ 28-s gap intervals, P2's matcher with masked unknown boundaries;
NOT timing ground truth): the decoder flags ~17–20 events per hour against 0.6 annotated changes per hour, so
precision is ≤ 1.2 % at every tolerance; recall A0s 7.1 / 12.6 / 29.1 % and A0 9.5 / 16.5 / 39.3 % at
±5 / ±10 / ±30 s; matched walk_start / walk_stop median |error| 4–5.5 s at ±10 s. Annotations mark only
coarse changes, so most flagged events are not refutable here.

## 5. Phase 2b — measured: stand-in Inertia arms (A2, A3, NAV) and a negative control

**Bundle.** `shadow-primary-hc` — P2's primary stand-in: `standin:handcrafted-stats-v1` (72 statistical /
spectral / cadence / orientation features of the 30-s 20-Hz accel window), CV-selected head architectures,
bundle sha256 `f61007169e3d…`, built 2026-10-05 20:11. **Negative control:** `shadow-primary-art` — the same
heads pipeline on a seeded random-init `ar_transformer-small` encoder (`standin:inertia-arch-random-init/…`,
512-d; bundle `02759f77b142…`), WISDM only, candidate defaults only.

**Splits / leakage check.** My VAL and TEST subjects are exactly the bundles' `val_subjects` / `test_subjects`
(WISDM 8 / 8, Capture-24 20 / 50) and none is in their `train_subjects` (checked for both bundles and both
datasets). P2 used the same VAL subjects for head calibration and architecture choice; my weight and
operating-point selection reuses them. TEST was opened once per configuration.

**Inputs actually ingested by the decoder** (from its own `motion_heads` report):

| dataset (TEST) | bundle | windows ingested | of which OOD | seconds with Inertia evidence |
|---|---|---|---|---|
| WISDM (138 of 142 blocks; P2's WISDM loader yields no window for 4 blocks of 228–285 s, which are decoded without Inertia evidence) | hc | 4,130 (all) | 930 (22.5 %) | 15,969 |
| WISDM | art (control) | 4,130 (all) | 1,149 (27.8 %) | 14,876 |
| Capture-24 (50 participants) | hc | 913,891 (all) | 48,669 (5.3 %) | 4,326,102 |

**ρ̂** (INERTIA1 §7 residual log-LR correlation, HART vs Inertia locomotion, WISDM VAL, 8,824 windows):
**0.61** (per subject 0.43–0.79).

### 5.1 VALIDATION sweep (selection only; objective = mean descriptive coverage@95 over posture + locomotion classes, tie-break mean known-class NLL)

| dataset | arm | config (loc / post / ρ) | objective | known NLL |
|---|---|---|---|---|
| WISDM | A0 (baseline) | — | 0.1156 | 1.463 |
| WISDM | A1 (baseline) | — | 0.2643 | 1.566 |
| WISDM | NAV | — | 0.2817 | 1.343 |
| WISDM | A2 | .10/.10 · .10/.25 · .10/.40 · .25/.10 · **.25/.25 (defaults)** · .40/.10 | .1185 · .1186 · .1186 · .1215 · **.1215** · **.1248 ← selected** | 1.444 · 1.501 · 1.538 · 1.409 · 1.466 · 1.385 |
| WISDM | A3 | same grid, ρ .5 | .2643 · .2643 · .2643 · .2653 · **.2653** · .2654 | 1.582 · 1.639 · 1.676 · 1.577 · 1.633 · 1.575 |
| WISDM | A3 | .40/.10 with ρ .25 / .61 (ρ̂) / .75 | **.2655 ← selected (ρ .25)** / .2654 / .2653 | 1.575 / 1.576 / 1.577 |
| Capture-24 | A0s / A0 (baselines) | — | 0.0941 / 0.0842 | 1.712 / 1.622 |
| Capture-24 | A2 | .10/.40 · **.25/.25 (defaults) ← selected** · .40/.10 | .1728 · **.1748** · .1731 | 1.065 · 1.047 · 1.040 |

The VAL objective barely moves with the weights or ρ (A3: 0.2643–0.2655 over the whole grid); the larger
posture weights cost NLL. ρ is nearly irrelevant here because the arm channel only fires when HART speaks and
the locomotion weight is small.

### 5.2 WISDM TEST (8 subjects; percentile CIs under-cover below 10 clusters)

| arm | weights (loc/post/ρ) | coarse acc | loco AURC | loco NLL | loco ECE | stationary cov@95 | posture acc | posture AURC | posture NLL | flips/h |
|---|---|---|---|---|---|---|---|---|---|---|
| A0 streams + imu-feat-1 | — | 0.633 | 0.132 | 1.990 | 0.302 | 0.685 | 0.406 | 0.679 | 1.005 | 39.2 |
| A1 + HART | — | 0.698 | 0.096 | 2.167 | 0.321 | 0.649 | 0.429 | 0.667 | 0.983 | 36.9 |
| **A2 + Inertia\*** | **.25/.25/.5 (defaults, primary)** | 0.669 | 0.112 | **1.851** | **0.269** | **0.705** | 0.364 | 0.727 | 1.100 | 39.2 |
| A2 + Inertia\* | .40/.10/.5 (VAL-selected) | 0.677 | 0.107 | **1.809** | **0.265** | **0.712** | 0.416 | 0.681 | 0.999 | 38.9 |
| **A3 + HART + Inertia\*** | **.25/.25/.5 (defaults, primary)** | 0.699 | 0.096 | 2.161 | 0.321 | 0.649 | 0.387 | 0.720 | 1.082 | 37.5 |
| A3 + HART + Inertia\* | .40/.10/.25 (VAL-selected) | 0.700 | 0.095 | 2.154 | 0.320 | 0.650 | 0.429 | 0.677 | 0.986 | 37.2 |
| NAV naive average\* (forbidden; ablation) | — | **0.723** | **0.074** | 1.970 | 0.285 | 0.686 | 0.430 | 0.666 | 0.983 | 39.6 |
| A2 control: random-init encoder\* | .25/.25/.5 | 0.632 | 0.133 | 1.990 | 0.301 | 0.685 | 0.406 | 0.679 | 1.005 | 39.2 |
| A3 control: random-init encoder\* | .25/.25/.5 | 0.698 | 0.096 | 2.166 | 0.321 | 0.649 | 0.429 | 0.667 | 0.983 | 37.0 |

Operating points: no Inertia arm adds a class at ≥ 95 % precision. Stationary stays the only gated class
(table above); walking/running/stairs abstain in A2; in A3 walking is weak (TEST precision 0.932) and running
again looks strong on VAL (τ .60) but reaches only 0.860 precision on TEST and fails the gate, exactly like
A1; NAV walking is weak (precision 0.881, recall 0.684). Sitting/standing: abstain in every arm.
Arm head: desk_like 0.392–0.395 coverage@95 in every arm (unchanged).

Paired differences, B − A, point [95 % CI]; ** = CI excludes 0; (b) = bound within 0.001 of 0:

| comparison | weights | loco NLL | loco AURC | stationary cov@95 | posture NLL | posture AURC | flips/h |
|---|---|---|---|---|---|---|---|
| **A2 − A0** | defaults | **−0.139 [−0.203, −0.075]** | **−0.020 [−0.033, −0.010]** | **+0.020 [0.009, 0.033]** | +0.095 [−0.011, 0.278] | +0.048 [−0.005, 0.116] | +0.00 [−1.01, 1.01] |
| A2 − A0 | VAL-selected | **−0.181 [−0.261, −0.100]** | **−0.025 [−0.040, −0.013]** | **+0.027 [0.011, 0.045]** | −0.005 [−0.027, 0.015] | +0.003 [−0.022, 0.015] | −0.29 [−2.15, 1.18] |
| **A3 − A1** | defaults | −0.006 [−0.013, −0.000] (b) | −0.000 [−0.001, 0.000] | 0.000 | +0.099 [−0.006, 0.280] | +0.051 [0.000, 0.122] (b, worse) | +0.57 [−0.14, 1.43] |
| A3 − A1 | VAL-selected | −0.012 [−0.030, 0.001] | −0.001 [−0.002, 0.001] | +0.001 [0.000, 0.002] | +0.003 [−0.005, 0.016] | +0.009 [−0.004, 0.017] | +0.29 [−0.29, 0.98] |
| **NAV − A1** | — | **−0.196 [−0.330, −0.083]** | **−0.024 [−0.041, −0.011]** | **+0.036 [0.010, 0.067]** | +0.000 [−0.000, 0.001] | −0.001 [−0.006, 0.001] | **+2.73 [1.01, 4.51]** (worse) |
| A2(control) − A0 | defaults | +0.001 [−0.013, 0.014] | +0.001 [−0.002, 0.003] | 0.000 | −0.000 [−0.000, −0.000] | +0.000 [0.000, 0.000] | +0.00 [−0.43, 0.42] |
| A3(control) − A1 | defaults | −0.000 [−0.001, −0.000] | +0.000 [−0.000, 0.000] | 0.000 | −0.000 [−0.000, −0.000] | +0.000 [0.000, 0.000] | +0.14 [0.00, 0.43] |

### 5.3 Capture-24 TEST (50 participants; VAL selected the candidate defaults, so one decode serves both)

| arm | coarse acc | loco AURC | loco NLL | loco ECE | stationary cov@95 | posture acc | posture AURC | posture NLL | recumbent cov@95 | flips/h |
|---|---|---|---|---|---|---|---|---|---|---|
| A0s streams only | 0.748 | 0.094 | 1.462 | 0.211 | 0.828 | 0.268 | 0.559 | 1.862 | 0 | 22.7 |
| A0 streams + imu-feat-1 | 0.793 | 0.096 | 1.308 | 0.168 | 0.748 | 0.294 | 0.528 | 1.761 | 0 | 23.1 |
| **A2 + Inertia\*** (.25/.25) | **0.810** | **0.052** | **1.266** | **0.162** | **0.768** | **0.725** | **0.085** | **0.582** | **0.776** | 23.7 |

A2 − A0: locomotion NLL **−0.042 [−0.051, −0.034]**, locomotion AURC **−0.022 [−0.029, −0.017]**,
stationary coverage@95 **+0.020 [0.017, 0.022]**, posture NLL **−1.180 [−1.287, −1.079]**, posture AURC
**−0.445 [−0.493, −0.399]**, recumbent coverage@95 **+0.776 [0.740, 0.810]** (VAL strong τ .42 → TEST precision
0.951, CP95 0.950), seated_likely descriptive coverage@95 +0.004 [−0.065, 0.151] (seated is weak on VAL:
τ .30 → TEST precision 0.908, fails the gate), display flips **+0.54/h [0.18, 0.94]**. Walking, running,
stairs, cycling, vehicle, other, and every arm-behaviour class: still no strong operating point.
Events (±5 / ±10 / ±30 s recall; same caveats as §4.2): A0 9.5 / 16.5 / 39.3 %, A2 8.0 / 14.6 / 36.9 %;
A2 flags 22,863 events vs A0 25,537 (precision ≤ 1.3 % in both).

### 5.4 Where the Capture-24 posture gain comes from

Recumbent truth on Capture-24 is mostly the diary/camera **sleeping** annotation, and no arm here has sleep
evidence (A0 cannot enter `bedRest`). Splitting the posture states by source annotation (same TEST decode
re-run deterministically for the breakdown; known-class argmax over recumbent / seated / upright; paired
subject bootstrap):

| truth group | states | A0 accuracy | A2 accuracy | A2 − A0 [95 % CI] |
|---|---|---|---|---|
| recumbent, annotated **sleeping** | 215,684 | 0.003 | **0.925** | **+0.922 [0.902, 0.938]** |
| recumbent, awake (lying, not sleeping) | 54,307 | 0.007 | 0.223 | **+0.216 [0.144, 0.296]** |
| seated_likely | 158,022 | 0.568 | 0.525 | **−0.043 [−0.065, −0.023]** |
| upright_stationary | 26,284 | 0.693 | 0.716 | **+0.022 [0.012, 0.034]** |
| awake static postures (seated + upright) | 184,306 | 0.586 | 0.553 | **−0.034 [−0.052, −0.016]** |

So the headline posture gain is the head recognising sleep-like lying. In the product A0 gets that route from
WHOOP's own sleep evidence (`bedRest` → recumbent), so most of it would overlap with existing evidence. On the
awake postures — the ones the wrist finds hard — the stand-in is slightly harmful on Capture-24 and, at the
defaults, on WISDM (posture accuracy 0.406 → 0.364).

### 5.5 What Phase 2b says (stand-in only)

1. **Alone, the stand-in heads help locomotion** on both datasets (A2 − A0): better calibration (NLL −0.14 /
   −0.18 WISDM, −0.04 Capture-24), better ranking (AURC −0.02) and +2–3 points of stationary coverage at
   ≥ 95 % precision. They do not unlock any new class at 95 %.
2. **On top of HART they add essentially nothing** (A3 − A1: locomotion NLL −0.006 / −0.012, AURC ~0). At the
   candidate defaults they make posture slightly worse (AURC +0.051, CI lower bound +0.0003; accuracy 0.429 →
   0.387); the VAL-selected weights (posture 0.10) remove the harm and, with it, any effect.
3. **The forbidden naive average beats the specified fusion** on locomotion (NAV − A1 NLL −0.196, AURC −0.024,
   stationary +0.036) at a cost of +2.7 display flips/h. So the stand-in carries locomotion information beyond
   HART that the specified evidence path leaves unused (hypothesis: the decoder trusts HART's over-confident,
   miscalibrated outputs — A1 worsens locomotion NLL by +0.18 vs A0 — and the INERTIA1 budget/ρ discount keeps
   the Inertia correction small). Not a recommendation to ship NAV: spec §17 forbids it and it raises flips.
4. **Negative control is clean.** The random-init encoder's windows are all ingested (28 % OOD, evidence on
   14,876 s) yet every difference is ≤ 0.001 with CIs around 0: the hc gains are not an artefact of attaching
   windows, and uninformative-but-calibrated heads do no harm.
5. **Defaults vs VAL-selected.** WISDM VAL preferred less posture weight (0.10) for both arms and ρ .25 for A3;
   Capture-24 VAL kept the defaults. The defaults are not over-confident for locomotion but over-weight posture
   on WISDM.
6. Nothing here measures Inertia-1.

## 6. Caveats (read before using any number)

1. **Proxies, not the strap.** The decoder's priors were set on the WHOOP strap's own `dynAccel`; the public
   data reach it only through a proxy whose definition is undocumented on the strap side. Use the numbers to
   compare arms, not as product accuracy.
2. **No sleep evidence in any arm.** `bedRest` is entered only with sleep evidence (exit weights ×0.3 when
   sleep is unknown), so A0s / A0 / A1 cannot reach recumbent; the stand-in posture head can, and most
   Capture-24 recumbent truth is annotated sleeping (§5.4). In the product WHOOP's sleep channel supplies that
   route, so A2 − A0 recumbent gains overstate what Inertia would add there.
3. **WISDM has no transitions** (each block is its own recording) and only 8 test subjects; **Capture-24
   boundaries are ±~25 s** (camera every 20–40 s; changes lie inside ≤ 28-s unannotated gaps), so ±5/±10 s
   event timing there measures label imprecision as much as the decoder.
4. Placement: WISDM and Capture-24 are dominant-wrist; WHOOP is usually worn on the non-dominant wrist.
5. HART on Capture-24 is impossible (no gyro). HART itself was trained on 82 % zero-gyro windows (§2), so
   A1/A3 use a HART that sees real gyro only at inference.
6. Everything Inertia is **STAND-IN, NOT INERTIA-1**; no Inertia-1 checkpoint exists.
7. P2 used the same VAL subjects for head calibration and architecture selection that I use for weights and
   operating points; TEST subjects are untouched by both, and no subject is shared with training.
8. The negative control ran on WISDM only (Capture-24 dense windows for a 512-d transformer: ~1.3 M windows,
   not cheap) and at the candidate defaults only.

## 7. What is measured, inferred, hypothesis, blocked

| claim | status |
|---|---|
| RESULTS.md reproduces bit-for-bit from `eval_data.npz` (15,363 / 10,205 / 0.664 / 0.660) | measured |
| production-faithful HART on WISDM test: coverage 0.547, macro-F1 0.701, accepted precision 0.86–0.94 | measured |
| 82 % / 83 % of HART train / eval windows have all-zero gyro (`train.py` searchsorted on unsorted timestamps) | measured |
| 1638's blocks are 49.8 Hz accel / 24.8 Hz gyro; train.py treated them as 20 Hz (2.5× slowed) | measured |
| HART model tests: 4/4 with the pretrained checkpoint; 2 fail/error with the fine-tuned one (fixture digest) | measured |
| dynAccel proxy choice on train subjects (magnitude-AC RMS, log10 error 0.18) | measured |
| WISDM: imu-feat-1 improves locomotion NLL/AURC/stationary coverage; HART improves AURC/posture/flips but worsens locomotion NLL; running fails the 95 % test gate in A1, A3 and NAV | measured (8 subjects; CIs under-cover) |
| Capture-24: imu-feat-1 improves locomotion/posture calibration (NLL −0.16 / −0.10) and coarse accuracy (0.75 → 0.79) but lowers stationary coverage@95 (0.83 → 0.75); recumbent unreachable without sleep evidence | measured (50 participants) |
| production HART on WHOOP data behaves like the production-faithful WISDM run | inferred |
| WISDM walking reading as near-running is a proxy/prior-scale mismatch | inferred (proxy medians vs mode ranges) |
| stand-in heads alone improve locomotion calibration/ranking/stationary coverage (A2 − A0), both datasets | measured |
| stand-in heads add ~nothing on top of HART (A3 − A1 locomotion NLL −0.006 / −0.012, AURC ~0) | measured (WISDM, 8 subjects) |
| at the candidate defaults the stand-in hurts awake posture (WISDM A3 − A1 posture AURC +0.051, bound +0.0003; Capture-24 seated −0.043) | measured |
| Capture-24 posture gain (acc 0.29 → 0.73, recumbent cov@95 0 → 0.78) is mostly sleeping-annotated lying | measured (§5.4) |
| that gain would largely overlap with WHOOP's sleep evidence in the product | inferred |
| random-init encoder heads change nothing (all Δ ≤ 0.001) | measured (WISDM, defaults) |
| NAV beats the specified fusion on locomotion because HART is over-confident and the Inertia budget/ρ discount keeps the correction small | hypothesis |
| ρ̂ = 0.61; ρ ∈ [.25, .75] barely changes VAL or TEST metrics | measured |
| any Inertia-1 number | **blocked**: no checkpoint |

## 8. Issues found in other owners' areas (not edited here)

1. `activity_context/train.py::_finish_block` — gyro merge `np.searchsorted` over the whole, unsorted gyro
   file: 82 % of training and 83 % of eval windows have zero gyro. Fix: merge per block (or sort) and retrain
   HART. Also `train.py` assumes 20 Hz for every block (1638 is 49.8/24.8 Hz).
2. `tests/test_model.py` + `fixtures/manifest.hart.example.json` pin the pretrained checkpoint digest, so
   `ACTIVITY_HART_CHECKPOINT=<fine-tuned dir>` fails two tests by design; worth a note or a second fixture.
3. Harness (S): the `streams` arm drops imu-feat-1 windows while `inertia` keeps them, so `inertia − streams`
   is not an Inertia effect; I use `hart` on an encoder-free file as A0. A built-in `engineered` arm would make
   this explicit. The naive-average fold maps `stairs → walking`, whereas HART's own C10 mapping is
   `stairs (C) → other_movement` (ablation only, minor).
4. P2: `test_predictions` cover only label-pure class windows (and Capture-24 at hop 30 s), which is right for
   head evaluation but unusable for a system replay; dense windows are regenerated here (§5).
5. P1 / P2 contract gap for random-init stand-ins: `runtime._resolve_encoder` hands the bundle's `encoder.json`
   to the registry as an Inertia encoder config, but for `standin:inertia-arch-random-init/…` bundles that file
   is P2's encoder card, so serve loads `shadow-primary-art` (and every random-init-arch bundle) as
   `inertia_unavailable: config_mismatch`. The registry builds the same encoder from its id alone (config sha256
   identical to the bundle's); `replay_inertia.load_runtime` does exactly that, only on this error, with
   `check_consistency` still enforced, and records `encoder_injected_via_registry` in the heads metadata. Fix
   belongs to P1 (use `encoder.json` only when it is an encoder-config schema) or P2 (write one).
6. Environment: XCTest dumps the whole process environment on some failures (it contained an API key); my
   runner never logs raw xctest output (`replay_eval._xctest_error_lines`). `/private/tmp/nara-replay-R` was
   deleted by another process mid-run; transient files now live in `~/Library/Caches/nara-replay-R`.

## 9. Files

* Code: `activity_context/inertia/replay_data.py` (datasets, rate detection, serve windows, HART runner,
  proxies, truth), `replay_export.py` (recordings, harness writer, arm map), `replay_inertia.py` (dense
  stand-in windows), `replay_score.py` (metric primitives, event truth), `replay_eval.py` (decode, tables,
  scoring with P2's metrics, bootstrap, ρ̂, sweep/final/baseline CLI), `replay_report.py` (tables).
* Tests: `tests/inertia/test_replay_export.py` (16), `test_replay_score.py` (12), `test_replay_eval.py` (6).
* Outside git, `research/inertia-replay/`: `hart_wisdm_{test,val}.{npz,json}` (per-window HART outputs:
  subject, block, s/e in the block's own time base, probs, label, feat), `hart_wisdm_summary.json`,
  `hart_results_md_rerun.json`, `proxy_choice.json`, `recordings_{wisdm,capture24}_{val,test}.npz` (per-second
  streams + truth + windows), `cache/` (per-subject HART / Capture-24 caches), `runs/baseline/` (decoded
  tables + `baseline_{wisdm,capture24}.json`), `runs/shadow-primary-hc/` (`rho_hat_wisdm_val.json`,
  `sweep_{wisdm,capture24}.json` + per-config progress, `final_{wisdm,capture24}.json`,
  `c24_posture_decomposition.json`, `SYSTEM_COMPARISON.tables.md`), `runs/shadow-primary-art/negative_control_wisdm.json`,
  `cache/heads/<bundle>/` (dense hop-5 s stand-in windows), `scratch/phase2.sh`, `scratch/negative_control.py`,
  `scratch/c24_posture_decomp.py`, `swiftbuild/` (release test bundle).

## 10. Reproduction

```bash
cd Tools/ActivityContext
# Phase 1a (HART venv: torch 2.8.0 / transformers 4.56.0 / granite-tsfm 0.3.3)
<hart-venv>/bin/python -m activity_context.inertia.replay_data wisdm-hart --jobs 8
# Phase 1b
<inertia-venv>/bin/python -m activity_context.inertia.replay_data capture24 --pids P102 ... P151 <val> <train>
# decoder build (private scratch path; then copied to ~/Library/Caches/nara-replay-R/release)
(cd ../../Packages/StrandAnalytics && swift build --build-tests -c release -Xswiftc -enable-testing \
    --scratch-path <research>/inertia-replay/swiftbuild)
# Phase 2a (bundle-independent arms)
python -m activity_context.inertia.replay_eval baseline --dataset wisdm     --out <research>/inertia-replay/runs/baseline
python -m activity_context.inertia.replay_eval baseline --dataset capture24 --out <research>/inertia-replay/runs/baseline
# Phase 2b (dense heads, rho-hat, VAL sweeps, one TEST decode per configuration, tables; <= 8 workers):
<research>/inertia-replay/scratch/phase2.sh <research>/inertia-bundles/shadow-primary-hc
# negative control and the Capture-24 posture breakdown
python <research>/inertia-replay/scratch/negative_control.py <research>/inertia-bundles/shadow-primary-art wisdm
python <research>/inertia-replay/scratch/c24_posture_decomp.py
```

## Appendix A — all TEST / VAL tables for `shadow-primary-hc` (generated by `replay_report`)

<!-- generated by activity_context.inertia.replay_report; STAND-IN, NOT INERTIA-1 -->

### wisdm TEST — bundle-independent arms (A0s, A0, A1); xctest build 5b10b94c86d0

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| stairs | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 574 | 0.404 | 0.692 | 1.012 | 0.730 | 0.285 | 0.163 | 0.103 |
| A0 streams+imu-feat-1 | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A1 +HART | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| seated_likely | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 1,148 | 0.411 | 0.569 | 3.325 | 1.058 | 0.490 | 0.008 | 0.000 |
| A0 streams+imu-feat-1 | 1,148 | 0.413 | 0.496 | 2.797 | 1.016 | 0.472 | 0.008 | 0.000 |
| A1 +HART | 1,148 | 0.415 | 0.493 | 2.539 | 0.997 | 0.470 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A0s streams only | 574 | weak | 0.300 | 0.778 | 0.748 | 0.822 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| repetitive_hand_motion | A0s streams only | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A1 +HART | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### paired bootstrap A0-A0s

A0 − A0s (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.008 [-0.021, 0.006] |
| posture | AURC (binned) Δ | -0.014 [-0.038, 0.003] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.254 [-0.339, -0.165] ** |
| locomotion | AURC (binned) Δ | -0.025 [-0.053, -0.003] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.040 [0.014, 0.068] ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.040 [0.014, 0.068] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.344, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.14 [-1.97, 2.40] |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001] ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353] ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003] ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972] ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00] |

#### paired bootstrap A1-A0s

A1 − A0s (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.029 [-0.063, -0.001] ** |
| posture | AURC (binned) Δ | -0.024 [-0.063, -0.002] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.077 [-0.260, 0.094] |
| locomotion | AURC (binned) Δ | -0.058 [-0.113, -0.021] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.005 [-0.048, 0.061] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.005 [-0.048, 0.061] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.337, 0.965] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972] ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | -2.15 [-3.83, -0.58] ** |

### capture24 TEST — bundle-independent arms (A0s, A0); xctest build 5b10b94c86d0

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 914,242 | 0.748 | 22.7 | 1269.7 | — | — | — |
| A0 streams+imu-feat-1 | 914,242 | 0.793 | 23.1 | 1269.7 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 557,066 | 0.748 | 0.094 | 1.462 | 0.447 | 0.211 | 0.031 | 0.000 |
| A0 streams+imu-feat-1 | 557,066 | 0.793 | 0.096 | 1.308 | 0.368 | 0.168 | 0.031 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 443,302 | strong | 0.885 | 0.955 | 0.955 | 0.828 | 0.828 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | strong | 0.965 | 0.958 | 0.957 | 0.748 | 0.748 | 0.783 | 0.960 |
| walking | A0s streams only | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0s streams only | 645 | — | — | — | — | — | — | 0.000 | — |
| running | A0 streams+imu-feat-1 | 645 | — | — | — | — | — | — | 0.000 | — |
| stairs | A0s streams only | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0s streams only | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0 streams+imu-feat-1 | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0s streams only | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0 streams+imu-feat-1 | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0s streams only | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0 streams+imu-feat-1 | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 454,297 | 0.268 | 0.559 | 1.862 | 0.918 | 0.342 | 0.199 | 0.135 |
| A0 streams+imu-feat-1 | 454,297 | 0.294 | 0.528 | 1.761 | 0.891 | 0.323 | 0.172 | 0.104 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | A0s streams only | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A0 streams+imu-feat-1 | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0s streams only | 212,329 | abstain | 1.000 | — | — | — | 0.000 | 0.224 | 0.630 |
| seated_likely | A0 streams+imu-feat-1 | 212,329 | weak | 0.580 | 0.854 | 0.852 | 0.298 | 0.000 | 0.248 | 0.640 |
| upright_stationary | A0s streams only | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 128,775 | 0.290 | 0.636 | 3.621 | 1.225 | 0.579 | 0.007 | 0.000 |
| A0 streams+imu-feat-1 | 128,775 | 0.291 | 0.637 | 3.588 | 1.223 | 0.579 | 0.007 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| quiet | A0s streams only | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| quiet | A0 streams+imu-feat-1 | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0s streams only | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0s streams only | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### transition events (Capture-24 truth = unannotated gaps <= 28 s; NOT timing ground truth)

| arm | tolerance / kind | TP | FP | FN | precision | recall | F1 |
|---|---|---|---|---|---|---|---|
| A0s streams only | ±5 s | 55 | 21,565 | 721 | 0.003 | 0.071 | 0.005 |
| A0s streams only | ±10 s | 98 | 21,522 | 678 | 0.005 | 0.126 | 0.009 |
| A0s streams only | ±30 s | 226 | 21,394 | 550 | 0.010 | 0.291 | 0.020 |
| A0s streams only | getting_up_like ±10 s | 0 | 9 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | run_start ±10 s | 0 | 950 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0s streams only | run_stop ±10 s | 0 | 876 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | sit_to_stand_like ±10 s | 10 | 1,852 | 142 | 0.005 | 0.066 | 0.010 (med 6.2 s, p90 8.6 s) |
| A0s streams only | stand_to_sit_like ±10 s | 5 | 3,381 | 178 | 0.001 | 0.027 | 0.003 (med 7.0 s, p90 8.3 s) |
| A0s streams only | walk_start ±10 s | 56 | 7,076 | 146 | 0.008 | 0.277 | 0.015 (med 4.0 s, p90 8.5 s) |
| A0s streams only | walk_stop ±10 s | 27 | 7,378 | 210 | 0.004 | 0.114 | 0.007 (med 5.5 s, p90 8.2 s) |
| A0 streams+imu-feat-1 | ±5 s | 74 | 25,463 | 702 | 0.003 | 0.095 | 0.006 |
| A0 streams+imu-feat-1 | ±10 s | 128 | 25,409 | 648 | 0.005 | 0.165 | 0.010 |
| A0 streams+imu-feat-1 | ±30 s | 305 | 25,232 | 471 | 0.012 | 0.393 | 0.023 |
| A0 streams+imu-feat-1 | getting_up_like ±10 s | 0 | 32 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_start ±10 s | 0 | 701 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_stop ±10 s | 0 | 635 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | sit_to_stand_like ±10 s | 13 | 2,605 | 139 | 0.005 | 0.086 | 0.009 (med 4.5 s, p90 8.3 s) |
| A0 streams+imu-feat-1 | stand_to_sit_like ±10 s | 12 | 4,402 | 171 | 0.003 | 0.066 | 0.005 (med 6.0 s, p90 9.5 s) |
| A0 streams+imu-feat-1 | walk_start ±10 s | 55 | 8,414 | 147 | 0.006 | 0.272 | 0.013 (med 4.0 s, p90 9.0 s) |
| A0 streams+imu-feat-1 | walk_stop ±10 s | 48 | 8,612 | 189 | 0.006 | 0.203 | 0.011 (med 5.2 s, p90 8.5 s) |

#### paired bootstrap A0-A0s

A0 − A0s (paired subject-cluster bootstrap, 1000 resamples, 50 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.100 [-0.109, -0.092] ** |
| posture | AURC (binned) Δ | -0.032 [-0.038, -0.026] ** |
| posture | recumbent: descriptive coverage@95 Δ | 0.000 [0.000, 0.002] |
| posture | recumbent: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.024 [-0.058, 0.074] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.155 [-0.187, -0.126] ** |
| locomotion | AURC (binned) Δ | -0.004 [-0.010, 0.002] |
| locomotion | stationary: descriptive coverage@95 Δ | -0.073 [-0.815, 0.001] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.080 [-0.089, -0.072] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.213, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | cycling: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | cycling: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | other: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | other: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.41 [0.08, 0.79] ** |

### wisdm: VALIDATION sweep

| arm | w_loc | w_post | w_arm | rho | VAL objective (mean cov@95) | VAL NLL (tie-break) |
|---|---|---|---|---|---|---|
| A2 | 0.1 | 0.1 | 0.25 | 0.5 | 0.119 | 1.444 |
| A3 | 0.1 | 0.1 | 0.25 | 0.5 | 0.264 | 1.582 |
| A2 | 0.1 | 0.25 | 0.25 | 0.5 | 0.119 | 1.501 |
| A3 | 0.1 | 0.25 | 0.25 | 0.5 | 0.264 | 1.639 |
| A2 | 0.1 | 0.4 | 0.25 | 0.5 | 0.119 | 1.538 |
| A3 | 0.1 | 0.4 | 0.25 | 0.5 | 0.264 | 1.676 |
| A2 | 0.25 | 0.1 | 0.25 | 0.5 | 0.121 | 1.409 |
| A3 | 0.25 | 0.1 | 0.25 | 0.5 | 0.265 | 1.577 |
| A2 | 0.25 | 0.25 | 0.25 | 0.5 | 0.121 | 1.466 |
| A3 | 0.25 | 0.25 | 0.25 | 0.5 | 0.265 | 1.633 |
| A2 | 0.4 | 0.1 | 0.25 | 0.5 | 0.125 | 1.385 |
| A3 | 0.4 | 0.1 | 0.25 | 0.5 | 0.265 | 1.575 |
| A2 | 0.4 | 0.1 | 0.25 | 0.25 | 0.125 | 1.385 |
| A3 | 0.4 | 0.1 | 0.25 | 0.25 | 0.265 | 1.575 |
| A2 | 0.4 | 0.1 | 0.25 | 0.61 | 0.125 | 1.385 |
| A3 | 0.4 | 0.1 | 0.25 | 0.61 | 0.265 | 1.576 |
| A2 | 0.4 | 0.1 | 0.25 | 0.75 | 0.125 | 1.385 |
| A3 | 0.4 | 0.1 | 0.25 | 0.75 | 0.265 | 1.577 |

### wisdm TEST — Inertia weights: defaults (A2: loc 0.25, post 0.25, arm 0.25, rho 0.5; A3: loc 0.25, post 0.25, arm 0.25, rho 0.5)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.669 | 39.2 | 7.0 | — | 4,130 | 930 |
| A3 +HART+Inertia* | 5,156 | 0.699 | 37.5 | 7.0 | — | 4,130 | 930 |
| NAV naive avg* | 5,156 | 0.723 | 39.6 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.669 | 0.112 | 1.851 | 0.582 | 0.269 | 0.033 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.641 | 0.096 | 2.161 | 0.669 | 0.321 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.671 | 0.074 | 1.970 | 0.598 | 0.285 | 0.078 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.705 | 0.705 | 0.705 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.686 | 0.686 | 0.686 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.932 | 0.881 | 0.362 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.950 | 0.881 | 0.841 | 0.684 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.600 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| stairs | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 574 | 0.404 | 0.692 | 1.012 | 0.730 | 0.285 | 0.163 | 0.103 |
| A0 streams+imu-feat-1 | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A1 +HART | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |
| A2 +Inertia* | 574 | 0.364 | 0.727 | 1.100 | 0.770 | 0.336 | 0.128 | 0.059 |
| A3 +HART+Inertia* | 574 | 0.387 | 0.720 | 1.082 | 0.753 | 0.310 | 0.124 | 0.056 |
| NAV naive avg* | 574 | 0.430 | 0.666 | 0.983 | 0.702 | 0.259 | 0.110 | 0.045 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| seated_likely | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 1,148 | 0.411 | 0.569 | 3.325 | 1.058 | 0.490 | 0.008 | 0.000 |
| A0 streams+imu-feat-1 | 1,148 | 0.413 | 0.496 | 2.797 | 1.016 | 0.472 | 0.008 | 0.000 |
| A1 +HART | 1,148 | 0.415 | 0.493 | 2.539 | 0.997 | 0.470 | 0.008 | 0.000 |
| A2 +Inertia* | 1,148 | 0.413 | 0.496 | 2.793 | 1.016 | 0.472 | 0.008 | 0.000 |
| A3 +HART+Inertia* | 1,148 | 0.415 | 0.493 | 2.538 | 0.997 | 0.470 | 0.008 | 0.000 |
| NAV naive avg* | 1,148 | 0.415 | 0.493 | 2.544 | 0.997 | 0.469 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A0s streams only | 574 | weak | 0.300 | 0.778 | 0.748 | 0.822 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.516 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| desk_like | NAV naive avg* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| repetitive_hand_motion | A0s streams only | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A1 +HART | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A2 +Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A3 +HART+Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | NAV naive avg* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.095 [-0.011, 0.278] |
| posture | AURC (binned) Δ | 0.048 [-0.005, 0.116] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.139 [-0.203, -0.075] ** |
| locomotion | AURC (binned) Δ | -0.020 [-0.033, -0.010] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.020 [0.009, 0.033] ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.020 [0.009, 0.033] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.00 [-1.01, 1.01] |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.099 [-0.006, 0.280] |
| posture | AURC (binned) Δ | 0.051 [0.000, 0.122] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.208] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.006 [-0.013, -0.000] ** |
| locomotion | AURC (binned) Δ | -0.000 [-0.001, 0.000] |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.063] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.57 [-0.14, 1.43] |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [-0.000, 0.001] |
| posture | AURC (binned) Δ | -0.001 [-0.006, 0.001] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.196 [-0.330, -0.083] ** |
| locomotion | AURC (binned) Δ | -0.024 [-0.041, -0.011] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.036 [0.010, 0.067] ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.036 [0.010, 0.067] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.332] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 2.73 [1.01, 4.51] ** |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001] ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353] ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003] ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972] ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00] |

### wisdm TEST — Inertia weights: selected (A2: loc 0.4, post 0.1, arm 0.25, rho 0.5; A3: loc 0.4, post 0.1, arm 0.25, rho 0.25)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.677 | 38.9 | 7.0 | — | 4,130 | 930 |
| A3 +HART+Inertia* | 5,156 | 0.700 | 37.2 | 7.0 | — | 4,130 | 930 |
| NAV naive avg* | 5,156 | 0.723 | 39.6 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.677 | 0.107 | 1.809 | 0.569 | 0.265 | 0.033 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.643 | 0.095 | 2.154 | 0.667 | 0.320 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.671 | 0.074 | 1.970 | 0.598 | 0.285 | 0.078 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.712 | 0.712 | 0.712 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.650 | 0.650 | 0.650 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.686 | 0.686 | 0.686 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.871 | 0.815 | 0.401 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.950 | 0.881 | 0.841 | 0.684 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.600 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| stairs | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 574 | 0.404 | 0.692 | 1.012 | 0.730 | 0.285 | 0.163 | 0.103 |
| A0 streams+imu-feat-1 | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A1 +HART | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |
| A2 +Inertia* | 574 | 0.416 | 0.681 | 0.999 | 0.716 | 0.278 | 0.124 | 0.059 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.677 | 0.986 | 0.704 | 0.260 | 0.122 | 0.056 |
| NAV naive avg* | 574 | 0.430 | 0.666 | 0.983 | 0.702 | 0.259 | 0.110 | 0.045 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| seated_likely | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A1 +HART | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | NAV naive avg* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 1,148 | 0.411 | 0.569 | 3.325 | 1.058 | 0.490 | 0.008 | 0.000 |
| A0 streams+imu-feat-1 | 1,148 | 0.413 | 0.496 | 2.797 | 1.016 | 0.472 | 0.008 | 0.000 |
| A1 +HART | 1,148 | 0.415 | 0.493 | 2.539 | 0.997 | 0.470 | 0.008 | 0.000 |
| A2 +Inertia* | 1,148 | 0.413 | 0.496 | 2.790 | 1.016 | 0.472 | 0.008 | 0.000 |
| A3 +HART+Inertia* | 1,148 | 0.415 | 0.493 | 2.538 | 0.997 | 0.470 | 0.008 | 0.000 |
| NAV naive avg* | 1,148 | 0.415 | 0.493 | 2.544 | 0.997 | 0.469 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A0s streams only | 574 | weak | 0.300 | 0.778 | 0.748 | 0.822 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.516 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| desk_like | NAV naive avg* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| repetitive_hand_motion | A0s streams only | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A1 +HART | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A2 +Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A3 +HART+Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | NAV naive avg* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.005 [-0.027, 0.015] |
| posture | AURC (binned) Δ | 0.003 [-0.022, 0.015] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.181 [-0.261, -0.100] ** |
| locomotion | AURC (binned) Δ | -0.025 [-0.040, -0.013] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.027 [0.011, 0.045] ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.027 [0.011, 0.045] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | -0.29 [-2.15, 1.18] |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.003 [-0.005, 0.016] |
| posture | AURC (binned) Δ | 0.009 [-0.004, 0.017] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.208] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.012 [-0.030, 0.001] |
| locomotion | AURC (binned) Δ | -0.001 [-0.002, 0.001] |
| locomotion | stationary: descriptive coverage@95 Δ | 0.001 [0.000, 0.002] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.001 [0.000, 0.002] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [-0.424, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.29 [-0.29, 0.98] |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [-0.000, 0.001] |
| posture | AURC (binned) Δ | -0.001 [-0.006, 0.001] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.196 [-0.330, -0.083] ** |
| locomotion | AURC (binned) Δ | -0.024 [-0.041, -0.011] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.036 [0.010, 0.067] ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.036 [0.010, 0.067] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.332] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 2.73 [1.01, 4.51] ** |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001] ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353] ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003] ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972] ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00] |

### capture24: VALIDATION sweep

| arm | w_loc | w_post | w_arm | rho | VAL objective (mean cov@95) | VAL NLL (tie-break) |
|---|---|---|---|---|---|---|
| A2 | 0.1 | 0.4 | 0.25 | 0.5 | 0.173 | 1.065 |
| A2 | 0.25 | 0.25 | 0.25 | 0.5 | 0.175 | 1.047 |
| A2 | 0.4 | 0.1 | 0.25 | 0.5 | 0.173 | 1.040 |

### capture24 TEST — Inertia weights: defaults (A2: loc 0.25, post 0.25, arm 0.25, rho 0.5)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 914,242 | 0.748 | 22.7 | 1269.7 | — | — | — |
| A0 streams+imu-feat-1 | 914,242 | 0.793 | 23.1 | 1269.7 | — | — | — |
| A2 +Inertia* | 914,242 | 0.810 | 23.7 | 1269.7 | — | 913,891 | 48,669 |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 557,066 | 0.748 | 0.094 | 1.462 | 0.447 | 0.211 | 0.031 | 0.000 |
| A0 streams+imu-feat-1 | 557,066 | 0.793 | 0.096 | 1.308 | 0.368 | 0.168 | 0.031 | 0.000 |
| A2 +Inertia* | 557,066 | 0.810 | 0.052 | 1.266 | 0.348 | 0.162 | 0.031 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 443,302 | strong | 0.885 | 0.955 | 0.955 | 0.828 | 0.828 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | strong | 0.965 | 0.958 | 0.957 | 0.748 | 0.748 | 0.783 | 0.960 |
| stationary | A2 +Inertia* | 443,302 | strong | 0.965 | 0.959 | 0.959 | 0.768 | 0.768 | 0.818 | 0.955 |
| walking | A0s streams only | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0s streams only | 645 | — | — | — | — | — | — | 0.000 | — |
| running | A0 streams+imu-feat-1 | 645 | — | — | — | — | — | — | 0.000 | — |
| running | A2 +Inertia* | 645 | — | — | — | — | — | — | 0.000 | — |
| stairs | A0s streams only | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A2 +Inertia* | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0s streams only | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0 streams+imu-feat-1 | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A2 +Inertia* | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0s streams only | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0 streams+imu-feat-1 | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A2 +Inertia* | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0s streams only | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0 streams+imu-feat-1 | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A2 +Inertia* | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 454,297 | 0.268 | 0.559 | 1.862 | 0.918 | 0.342 | 0.199 | 0.135 |
| A0 streams+imu-feat-1 | 454,297 | 0.294 | 0.528 | 1.761 | 0.891 | 0.323 | 0.172 | 0.104 |
| A2 +Inertia* | 454,297 | 0.725 | 0.085 | 0.582 | 0.323 | 0.084 | 0.186 | 0.096 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | A0s streams only | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A0 streams+imu-feat-1 | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A2 +Inertia* | 269,991 | strong | 0.420 | 0.951 | 0.950 | 0.776 | 0.776 | 0.776 | 0.415 |
| seated_likely | A0s streams only | 212,329 | abstain | 1.000 | — | — | — | 0.000 | 0.224 | 0.630 |
| seated_likely | A0 streams+imu-feat-1 | 212,329 | weak | 0.580 | 0.854 | 0.852 | 0.298 | 0.000 | 0.248 | 0.640 |
| seated_likely | A2 +Inertia* | 212,329 | weak | 0.300 | 0.908 | 0.906 | 0.456 | 0.000 | 0.252 | 0.635 |
| upright_stationary | A0s streams only | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 128,775 | 0.290 | 0.636 | 3.621 | 1.225 | 0.579 | 0.007 | 0.000 |
| A0 streams+imu-feat-1 | 128,775 | 0.291 | 0.637 | 3.588 | 1.223 | 0.579 | 0.007 | 0.000 |
| A2 +Inertia* | 128,775 | 0.292 | 0.641 | 3.563 | 1.222 | 0.579 | 0.007 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| quiet | A0s streams only | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| quiet | A0 streams+imu-feat-1 | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| quiet | A2 +Inertia* | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0s streams only | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A2 +Inertia* | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0s streams only | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A2 +Inertia* | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### transition events (Capture-24 truth = unannotated gaps <= 28 s; NOT timing ground truth)

| arm | tolerance / kind | TP | FP | FN | precision | recall | F1 |
|---|---|---|---|---|---|---|---|
| A0s streams only | ±5 s | 55 | 21,565 | 721 | 0.003 | 0.071 | 0.005 |
| A0s streams only | ±10 s | 98 | 21,522 | 678 | 0.005 | 0.126 | 0.009 |
| A0s streams only | ±30 s | 226 | 21,394 | 550 | 0.010 | 0.291 | 0.020 |
| A0s streams only | getting_up_like ±10 s | 0 | 9 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | run_start ±10 s | 0 | 950 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0s streams only | run_stop ±10 s | 0 | 876 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | sit_to_stand_like ±10 s | 10 | 1,852 | 142 | 0.005 | 0.066 | 0.010 (med 6.2 s, p90 8.6 s) |
| A0s streams only | stand_to_sit_like ±10 s | 5 | 3,381 | 178 | 0.001 | 0.027 | 0.003 (med 7.0 s, p90 8.3 s) |
| A0s streams only | walk_start ±10 s | 56 | 7,076 | 146 | 0.008 | 0.277 | 0.015 (med 4.0 s, p90 8.5 s) |
| A0s streams only | walk_stop ±10 s | 27 | 7,378 | 210 | 0.004 | 0.114 | 0.007 (med 5.5 s, p90 8.2 s) |
| A0 streams+imu-feat-1 | ±5 s | 74 | 25,463 | 702 | 0.003 | 0.095 | 0.006 |
| A0 streams+imu-feat-1 | ±10 s | 128 | 25,409 | 648 | 0.005 | 0.165 | 0.010 |
| A0 streams+imu-feat-1 | ±30 s | 305 | 25,232 | 471 | 0.012 | 0.393 | 0.023 |
| A0 streams+imu-feat-1 | getting_up_like ±10 s | 0 | 32 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_start ±10 s | 0 | 701 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_stop ±10 s | 0 | 635 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | sit_to_stand_like ±10 s | 13 | 2,605 | 139 | 0.005 | 0.086 | 0.009 (med 4.5 s, p90 8.3 s) |
| A0 streams+imu-feat-1 | stand_to_sit_like ±10 s | 12 | 4,402 | 171 | 0.003 | 0.066 | 0.005 (med 6.0 s, p90 9.5 s) |
| A0 streams+imu-feat-1 | walk_start ±10 s | 55 | 8,414 | 147 | 0.006 | 0.272 | 0.013 (med 4.0 s, p90 9.0 s) |
| A0 streams+imu-feat-1 | walk_stop ±10 s | 48 | 8,612 | 189 | 0.006 | 0.203 | 0.011 (med 5.2 s, p90 8.5 s) |
| A2 +Inertia* | ±5 s | 62 | 22,801 | 714 | 0.003 | 0.080 | 0.005 |
| A2 +Inertia* | ±10 s | 113 | 22,750 | 663 | 0.005 | 0.146 | 0.010 |
| A2 +Inertia* | ±30 s | 286 | 22,577 | 490 | 0.013 | 0.369 | 0.024 |
| A2 +Inertia* | getting_up_like ±10 s | 0 | 1,245 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_start ±10 s | 0 | 250 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_stop ±10 s | 0 | 229 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | sit_to_stand_like ±10 s | 11 | 2,262 | 141 | 0.005 | 0.072 | 0.009 (med 4.5 s, p90 8.5 s) |
| A2 +Inertia* | stand_to_sit_like ±10 s | 11 | 4,136 | 172 | 0.003 | 0.060 | 0.005 (med 7.5 s, p90 9.5 s) |
| A2 +Inertia* | walk_start ±10 s | 52 | 7,188 | 150 | 0.007 | 0.257 | 0.014 (med 4.8 s, p90 8.9 s) |
| A2 +Inertia* | walk_stop ±10 s | 39 | 7,432 | 198 | 0.005 | 0.165 | 0.010 (med 4.5 s, p90 8.5 s) |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 50 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -1.180 [-1.287, -1.079] ** |
| posture | AURC (binned) Δ | -0.445 [-0.493, -0.399] ** |
| posture | recumbent: descriptive coverage@95 Δ | 0.776 [0.722, 0.808] ** |
| posture | recumbent: recall at VAL-strong tau Δ (precision not gated) | 0.776 [0.740, 0.810] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.004 [-0.065, 0.151] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.042 [-0.051, -0.034] ** |
| locomotion | AURC (binned) Δ | -0.022 [-0.029, -0.017] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.035 [0.000, 0.773] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.020 [0.017, 0.022] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | cycling: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | cycling: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | other: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | other: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.54 [0.18, 0.94] ** |

### capture24 TEST — Inertia weights: selected (A2: loc 0.25, post 0.25, arm 0.25, rho 0.5)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 914,242 | 0.748 | 22.7 | 1269.7 | — | — | — |
| A0 streams+imu-feat-1 | 914,242 | 0.793 | 23.1 | 1269.7 | — | — | — |
| A2 +Inertia* | 914,242 | 0.810 | 23.7 | 1269.7 | — | 913,891 | 48,669 |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 557,066 | 0.748 | 0.094 | 1.462 | 0.447 | 0.211 | 0.031 | 0.000 |
| A0 streams+imu-feat-1 | 557,066 | 0.793 | 0.096 | 1.308 | 0.368 | 0.168 | 0.031 | 0.000 |
| A2 +Inertia* | 557,066 | 0.810 | 0.052 | 1.266 | 0.348 | 0.162 | 0.031 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 443,302 | strong | 0.885 | 0.955 | 0.955 | 0.828 | 0.828 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | strong | 0.965 | 0.958 | 0.957 | 0.748 | 0.748 | 0.783 | 0.960 |
| stationary | A2 +Inertia* | 443,302 | strong | 0.965 | 0.959 | 0.959 | 0.768 | 0.768 | 0.818 | 0.955 |
| walking | A0s streams only | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 56,773 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0s streams only | 645 | — | — | — | — | — | — | 0.000 | — |
| running | A0 streams+imu-feat-1 | 645 | — | — | — | — | — | — | 0.000 | — |
| running | A2 +Inertia* | 645 | — | — | — | — | — | — | 0.000 | — |
| stairs | A0s streams only | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A0 streams+imu-feat-1 | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A2 +Inertia* | 63 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0s streams only | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A0 streams+imu-feat-1 | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| cycling | A2 +Inertia* | 4,700 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0s streams only | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A0 streams+imu-feat-1 | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| vehicle_motion | A2 +Inertia* | 21,394 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0s streams only | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A0 streams+imu-feat-1 | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| other | A2 +Inertia* | 33,149 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 454,297 | 0.268 | 0.559 | 1.862 | 0.918 | 0.342 | 0.199 | 0.135 |
| A0 streams+imu-feat-1 | 454,297 | 0.294 | 0.528 | 1.761 | 0.891 | 0.323 | 0.172 | 0.104 |
| A2 +Inertia* | 454,297 | 0.725 | 0.085 | 0.582 | 0.323 | 0.084 | 0.186 | 0.096 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | A0s streams only | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A0 streams+imu-feat-1 | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A2 +Inertia* | 269,991 | strong | 0.420 | 0.951 | 0.950 | 0.776 | 0.776 | 0.776 | 0.415 |
| seated_likely | A0s streams only | 212,329 | abstain | 1.000 | — | — | — | 0.000 | 0.224 | 0.630 |
| seated_likely | A0 streams+imu-feat-1 | 212,329 | weak | 0.580 | 0.854 | 0.852 | 0.298 | 0.000 | 0.248 | 0.640 |
| seated_likely | A2 +Inertia* | 212,329 | weak | 0.300 | 0.908 | 0.906 | 0.456 | 0.000 | 0.252 | 0.635 |
| upright_stationary | A0s streams only | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 128,775 | 0.290 | 0.636 | 3.621 | 1.225 | 0.579 | 0.007 | 0.000 |
| A0 streams+imu-feat-1 | 128,775 | 0.291 | 0.637 | 3.588 | 1.223 | 0.579 | 0.007 | 0.000 |
| A2 +Inertia* | 128,775 | 0.292 | 0.641 | 3.563 | 1.222 | 0.579 | 0.007 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| quiet | A0s streams only | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| quiet | A0 streams+imu-feat-1 | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| quiet | A2 +Inertia* | 43,680 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0s streams only | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| desk_like | A2 +Inertia* | 82,714 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0s streams only | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A2 +Inertia* | 2,381 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### transition events (Capture-24 truth = unannotated gaps <= 28 s; NOT timing ground truth)

| arm | tolerance / kind | TP | FP | FN | precision | recall | F1 |
|---|---|---|---|---|---|---|---|
| A0s streams only | ±5 s | 55 | 21,565 | 721 | 0.003 | 0.071 | 0.005 |
| A0s streams only | ±10 s | 98 | 21,522 | 678 | 0.005 | 0.126 | 0.009 |
| A0s streams only | ±30 s | 226 | 21,394 | 550 | 0.010 | 0.291 | 0.020 |
| A0s streams only | getting_up_like ±10 s | 0 | 9 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | run_start ±10 s | 0 | 950 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0s streams only | run_stop ±10 s | 0 | 876 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0s streams only | sit_to_stand_like ±10 s | 10 | 1,852 | 142 | 0.005 | 0.066 | 0.010 (med 6.2 s, p90 8.6 s) |
| A0s streams only | stand_to_sit_like ±10 s | 5 | 3,381 | 178 | 0.001 | 0.027 | 0.003 (med 7.0 s, p90 8.3 s) |
| A0s streams only | walk_start ±10 s | 56 | 7,076 | 146 | 0.008 | 0.277 | 0.015 (med 4.0 s, p90 8.5 s) |
| A0s streams only | walk_stop ±10 s | 27 | 7,378 | 210 | 0.004 | 0.114 | 0.007 (med 5.5 s, p90 8.2 s) |
| A0 streams+imu-feat-1 | ±5 s | 74 | 25,463 | 702 | 0.003 | 0.095 | 0.006 |
| A0 streams+imu-feat-1 | ±10 s | 128 | 25,409 | 648 | 0.005 | 0.165 | 0.010 |
| A0 streams+imu-feat-1 | ±30 s | 305 | 25,232 | 471 | 0.012 | 0.393 | 0.023 |
| A0 streams+imu-feat-1 | getting_up_like ±10 s | 0 | 32 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_start ±10 s | 0 | 701 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | run_stop ±10 s | 0 | 635 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A0 streams+imu-feat-1 | sit_to_stand_like ±10 s | 13 | 2,605 | 139 | 0.005 | 0.086 | 0.009 (med 4.5 s, p90 8.3 s) |
| A0 streams+imu-feat-1 | stand_to_sit_like ±10 s | 12 | 4,402 | 171 | 0.003 | 0.066 | 0.005 (med 6.0 s, p90 9.5 s) |
| A0 streams+imu-feat-1 | walk_start ±10 s | 55 | 8,414 | 147 | 0.006 | 0.272 | 0.013 (med 4.0 s, p90 9.0 s) |
| A0 streams+imu-feat-1 | walk_stop ±10 s | 48 | 8,612 | 189 | 0.006 | 0.203 | 0.011 (med 5.2 s, p90 8.5 s) |
| A2 +Inertia* | ±5 s | 62 | 22,801 | 714 | 0.003 | 0.080 | 0.005 |
| A2 +Inertia* | ±10 s | 113 | 22,750 | 663 | 0.005 | 0.146 | 0.010 |
| A2 +Inertia* | ±30 s | 286 | 22,577 | 490 | 0.013 | 0.369 | 0.024 |
| A2 +Inertia* | getting_up_like ±10 s | 0 | 1,245 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_start ±10 s | 0 | 250 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_stop ±10 s | 0 | 229 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | sit_to_stand_like ±10 s | 11 | 2,262 | 141 | 0.005 | 0.072 | 0.009 (med 4.5 s, p90 8.5 s) |
| A2 +Inertia* | stand_to_sit_like ±10 s | 11 | 4,136 | 172 | 0.003 | 0.060 | 0.005 (med 7.5 s, p90 9.5 s) |
| A2 +Inertia* | walk_start ±10 s | 52 | 7,188 | 150 | 0.007 | 0.257 | 0.014 (med 4.8 s, p90 8.9 s) |
| A2 +Inertia* | walk_stop ±10 s | 39 | 7,432 | 198 | 0.005 | 0.165 | 0.010 (med 4.5 s, p90 8.5 s) |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 50 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -1.180 [-1.287, -1.079] ** |
| posture | AURC (binned) Δ | -0.445 [-0.493, -0.399] ** |
| posture | recumbent: descriptive coverage@95 Δ | 0.776 [0.722, 0.808] ** |
| posture | recumbent: recall at VAL-strong tau Δ (precision not gated) | 0.776 [0.740, 0.810] ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.004 [-0.065, 0.151] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.042 [-0.051, -0.034] ** |
| locomotion | AURC (binned) Δ | -0.022 [-0.029, -0.017] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.035 [0.000, 0.773] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.020 [0.017, 0.022] ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | cycling: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | cycling: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | vehicle_motion: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | other: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | other: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.54 [0.18, 0.94] ** |

## Appendix B — negative control tables

### wisdm TEST — negative control: `shadow-primary-art` (random-init encoder), candidate defaults (rows labelled A2 / A3 are the control arms)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A2 +Inertia* | 5,156 | 0.632 | 39.2 | 7.0 | — | 4,130 | 1,149 |
| A3 +HART+Inertia* | 5,156 | 0.698 | 37.0 | 7.0 | — | 4,130 | 1,149 |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A2 +Inertia* | 4,309 | 0.632 | 0.133 | 1.990 | 0.644 | 0.301 | 0.034 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.641 | 0.096 | 2.166 | 0.671 | 0.321 | 0.080 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.923 | 0.865 | 0.316 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.640 | 0.863 | 0.827 | 0.962 | 0.000 | 0.000 | — |
| stairs | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| stairs | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### posture

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A2 +Inertia* | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| seated_likely | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A3 +HART+Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A2 +Inertia* | 1,148 | 0.413 | 0.496 | 2.795 | 1.016 | 0.472 | 0.008 | 0.000 |
| A3 +HART+Inertia* | 1,148 | 0.415 | 0.493 | 2.538 | 0.997 | 0.470 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.395 | 0.395 | 0.601 | 0.960 |
| repetitive_hand_motion | A2 +Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A3 +HART+Inertia* | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### paired bootstrap A2-A0 (control)

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.000 [-0.000, -0.000] ** |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | 0.001 [-0.013, 0.014] |
| locomotion | AURC (binned) Δ | 0.001 [-0.002, 0.003] |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.00 [-0.43, 0.42] |

#### paired bootstrap A3-A1 (control)

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.000 [-0.000, -0.000] ** |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.000 [-0.001, -0.000] ** |
| locomotion | AURC (binned) Δ | 0.000 [-0.000, 0.000] |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.896] |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| display | label flips per hour Δ | 0.14 [0.00, 0.43] |
