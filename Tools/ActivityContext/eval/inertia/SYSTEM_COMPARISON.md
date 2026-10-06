# System-level comparison of the activity decoder arms — STAND-IN, NOT INERTIA-1

Status (2026-10-05): **Phase 1 measured. Phase 2: the bundle-independent arms (A0s, A0, A1) are measured
through the Swift decoder replay; the stand-in Inertia arms (A2, A3, NAV) are PENDING** — P2's primary
stand-in bundle `shadow-primary-hc` had not been produced when the polling budget ran out (§5). The Inertia
pipeline is built, unit-tested and code-tested end to end on validation data; one command finishes it (§10).

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

## 5. Phase 2b — pending: A2 (+Inertia), A3 (HART + Inertia), NAV (naive average)

**Blocked on input, not on code.** P2's primary stand-in bundle `shadow-primary-hc`
(`standin:handcrafted-stats-v1` encoder, CV-selected heads) did not exist when my ~3 h polling budget ended:
P2's bundles were wiped and retrained at 17:51, the training processes died twice when the external research
volume dropped off the bus (17:05 and 18:20), and the machine ran at load average 85–115 on 16 cores
(other agents' builds and browsers), leaving P2's hc training process at ~3 % CPU. Only `shadow-ood-nf` (an
OOD-benchmark bundle trained without the held-out activities) existed; it was used for code tests on
validation data only and no number from it is reported.

What is ready (unit-tested and code-tested end to end on validation data, outputs discarded):

* **Dense, label-independent Inertia windows.** P2's saved `test_predictions` only cover the label-pure class
  windows (w30, ≥ 90 % purity; Capture-24 hop 30 s): replaying them would leak where the truth is pure and
  starve the decoder elsewhere. `replay_inertia.py` regenerates windows the way serve does — the bundle's own
  stand-in encoder + `HeadBundle.apply` through P1's `runtime` (`allow_standin_shadow`), hop 5 s, rounded
  like `runtime.infer_seconds` — Capture-24 through `inertia-prep-1` itself (P1's `windows_from_run` on the
  integer-second 100 Hz runs), WISDM through P2's dataset path (regrid + `resample_to_20hz`) without the
  purity filter. Attached per INERTIA1 §7 (first observed second in [e, e+2]; later window supersedes).
* **Arms from one stream.** One `nara-activity-replay-1` file per chunk carries HART windows, imu-feat-1
  windows and motion-head windows; the harness derives `inertia`, `hart+inertia` and `naive_average` with the
  test-only stand-in override (`allow_standin_evidence_for_testing`), candidate mode. Non-encoder inputs are
  identical across arms (sha256-checked per sequence).
* **Weights on VALIDATION only** (pre-registered objective: mean descriptive coverage@95 over the posture +
  locomotion classes, tie-break mean known-class NLL). Candidate defaults (INERTIA1 §7: locomotion .25,
  posture .25, arm .25, body budget .5, arm budget .5, ρ .5) are the primary pre-specified configuration;
  the sweep is secondary: stage 1 body weights (WISDM 6 points, Capture-24 3 points) at ρ = .5, stage 2 ρ ∈
  {.25, .75, ρ̂} for A3 at its best body weights. The arm weight is not swept: the arm chain is fed by the body
  posterior, never the reverse, so it cannot move the posture/locomotion objective. TEST is then decoded once
  per configuration.
* **ρ̂ measurement** (INERTIA1 §7 "residual log-LR correlation from replay"): pooled Pearson r of the
  mode-centred log-LR vectors of the HART channel and the Inertia locomotion channel over WISDM VAL windows,
  with the decoder's compat tables mirrored in Python (`replay_eval.rho_hat`, unit-tested). Smoke value with
  the OOD bundle: ~0.67 (not a result).
* Paired bootstraps A2 − A0 (both datasets), A3 − A1, NAV − A1, A1 − A0 (WISDM); Capture-24 event metrics
  (P2's `events.event_metrics`, ±5/±10/±30 s, masked unknown boundaries).

## 6. Caveats (read before using any number)

1. **Proxies, not the strap.** The decoder's priors were set on the WHOOP strap's own `dynAccel`; the public
   data reach it only through a proxy whose definition is undocumented on the strap side. Use the numbers to
   compare arms, not as product accuracy.
2. **No sleep evidence → recumbent is out of reach.** `bedRest` is entered only with sleep evidence (exit
   weights ×0.3 when sleep is unknown); most Capture-24 recumbent truth is diary sleep. Recumbent coverage is
   expected to be ~0 in every arm here.
3. **WISDM has no transitions** (each block is its own recording) and only 8 test subjects; **Capture-24
   boundaries are ±~25 s** (camera every 20–40 s; changes lie inside ≤ 28-s unannotated gaps), so ±5/±10 s
   event timing there measures label imprecision as much as the decoder.
4. Placement: WISDM and Capture-24 are dominant-wrist; WHOOP is usually worn on the non-dominant wrist.
5. HART on Capture-24 is impossible (no gyro). HART itself was trained on 82 % zero-gyro windows (§2), so
   A1/A3 use a HART that sees real gyro only at inference.
6. Everything Inertia is **STAND-IN, NOT INERTIA-1**; no Inertia-1 checkpoint exists.

## 7. What is measured, inferred, hypothesis, blocked

| claim | status |
|---|---|
| RESULTS.md reproduces bit-for-bit from `eval_data.npz` (15,363 / 10,205 / 0.664 / 0.660) | measured |
| production-faithful HART on WISDM test: coverage 0.547, macro-F1 0.701, accepted precision 0.86–0.94 | measured |
| 82 % / 83 % of HART train / eval windows have all-zero gyro (`train.py` searchsorted on unsorted timestamps) | measured |
| 1638's blocks are 49.8 Hz accel / 24.8 Hz gyro; train.py treated them as 20 Hz (2.5× slowed) | measured |
| HART model tests: 4/4 with the pretrained checkpoint; 2 fail/error with the fine-tuned one (fixture digest) | measured |
| dynAccel proxy choice on train subjects (magnitude-AC RMS, log10 error 0.18) | measured |
| WISDM: imu-feat-1 improves locomotion NLL/AURC/stationary coverage; HART improves AURC/posture/flips but worsens locomotion NLL; running fails the 95 % test gate | measured (8 subjects; CIs under-cover) |
| Capture-24: imu-feat-1 improves locomotion/posture calibration (NLL −0.16 / −0.10) and coarse accuracy (0.75 → 0.79) but lowers stationary coverage@95 (0.83 → 0.75); recumbent unreachable without sleep evidence | measured (50 participants) |
| production HART on WHOOP data behaves like the production-faithful WISDM run | inferred |
| WISDM walking reading as near-running is a proxy/prior-scale mismatch | inferred (proxy medians vs mode ranges) |
| stand-in heads add calibrated posture/locomotion evidence beyond HART (A3 − A1 > 0) | hypothesis — pending |
| candidate defaults are not overconfident relative to VAL-selected weights | hypothesis — pending |
| A2 / A3 / NAV numbers | **blocked**: `shadow-primary-hc` not yet produced |
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
   `stairs (C) → other_movement` (ablation only, minor). INERTIA1.md has no "Replay record format" section yet;
   the format lives in the header of `ActivityReplayHarness.swift`.
4. P2: `test_predictions` cover only label-pure class windows (and Capture-24 at hop 30 s), which is right for
   head evaluation but unusable for a system replay; dense windows are regenerated here (§5).
5. Environment: XCTest dumps the whole process environment on some failures (it contained an API key); my
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
  tables + `baseline_{wisdm,capture24}.json`), `scratch/phase2.sh`, `swiftbuild/` (release test bundle).

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
# Phase 2b, once P2's primary stand-in bundle exists (heads, rho-hat, VAL sweeps, TEST finals, tables):
<research>/inertia-replay/scratch/phase2.sh <research>/inertia-bundles/shadow-primary-hc
```

## Appendix A — WISDM tables (generated by `replay_report`)

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

## Appendix B — Capture-24 tables (generated by `replay_report`)

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
