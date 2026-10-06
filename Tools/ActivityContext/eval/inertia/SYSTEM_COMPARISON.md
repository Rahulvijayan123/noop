# System-level comparison of the activity decoder arms — STAND-IN, NOT INERTIA-1

Status (2026-10-05 22:40 PDT): **measured on the final code and the sealed post-audit bundles.** Decoder
built from HEAD `227ff05c` (after the red-team audit fixes `1802a012` / `a424d207` and the nara/main merge
`0176a63e`); P2's bundles retrained from clean commit `a424d207` and sealed; every TEST decode ledgered
(`post_audit_rule_change`). Headline (stand-in only): with the posture and arm heads now inert, the stand-in
`shadow-primary-hc` speaks only through locomotion; it improves locomotion calibration when it is the only motion
channel (WISDM NLL −0.14, Capture-24 −0.04), adds ~1 % of locomotion NLL on top of HART, and the pre-audit
Capture-24 posture "gain" (sleep-like lying) is gone. ρ̂ = 0.634. What changed vs the pre-audit run: §6.

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

## 4. Phase 2 protocol (post-audit run)

**Decoder.** The Swift `ActivityContextDecoder` (hsmm-1.3 mode profiles, unchanged by the merge; S's
motion-head extension with the audit fixes) through S's env-gated XCTest
`ActivityReplayTests/testReplayFromEnvironment`, built in release with `-enable-testing` from the clean worktree
at **HEAD `227ff05c`** (tree clean before and after the build) into the private scratch path
`research/inertia-replay/swiftbuild`, then copied to `~/Library/Caches/nara-replay-R/release`:

| | post-audit (this run) | pre-audit run |
|---|---|---|
| source commit | `227ff05c` (audit fixes `1802a012`, `a424d207`; nara/main merge `0176a63e`; bundles sealed) | `32a2dc52` + uncommitted work |
| test-bundle executable sha256 | `b7e4cff1cd67d3363fad13eaeb380ef833390674b14cbc47db121ffda12ea30a` | `5b10b94c86d0…` |
| Swift sources fingerprint (sha256 of the sorted per-file sha256 list of `Sources/` + `Tests/`, 414 files) | `7dc0615b6587484a` | `69d973a59ef2576c` |
| harness self-tests (`ActivityReplayTests`, release bundle) | 6 pass, 1 skipped (the env-gated replay test) | — |

Decoder changes that reach these arms: the specialist gate needs the class's own q ≥ τ as strict argmax and its
opening stays inside the Inertia budget; the Inertia posture term is omitted on asleep / in-bed seconds (none
exist in this replay: no sleep stream); `hartRedundancy` default 0.65 (a floor; a bundle `fusion.rho_hart` can
only raise it — neither sealed bundle carries one); a head with a single evidence group or
`decoder_evidence: false` is inert; replay records get the wire validation.

**Data and truth.** `INERTIA_DATA_ROOT=research`, `WISDM_DIR` = the unpacked WISDM-2019 directory used before.
Ground truth now reads the repo crosswalk (`activity_context/inertia/label_mappings.json`, sha256
`19ae2db0…`). It differs from the agentC copy the recordings were built with only in `local_paths` /
verification metadata: the effective per-label truth (`replay_data.load_crosswalk`) is identical for all 18
WISDM and 207 Capture-24 source labels, so `recordings_*.npz` were reused unchanged (same 142 / 158 WISDM
blocks, 50 / 20 Capture-24 participants).

**Bundles (sealed, retrained from clean commit `a424d207`).**

| bundle | sha256 | encoder | heads carrying decoder evidence | locomotion statuses (served, after the seal) |
|---|---|---|---|---|
| `shadow-primary-hc` | `3fb1ae3e75c8…` | `standin:handcrafted-stats-v1` (72-d) | **locomotion only** (posture, arm: `decoder_evidence: false`) | stationary strong (τ .83), walking strong (τ .915; covers brisk walking), running / stairs / vehicle weak, cycling / other abstain |
| `shadow-primary-art` (negative control) | `1b8fadcc1521…` | random-init `ar_transformer-small` (512-d) | **none** (every head `decoder_evidence: false`) | — |

My VAL / TEST subjects equal the bundles' `val_subjects` / `test_subjects` exactly, with no overlap with
their `train_subjects` (both bundles, both datasets). P2 used the same VAL subjects for head calibration.

**Operating points** (unchanged code path, new rule in P2's `abstention.select_operating_point`): on VAL,
*strong* = smallest stable τ with one-sided CP95 lower bound ≥ 0.95 **and** a subject-cluster bootstrap 5 %
quantile of precision ≥ 0.95, ≥ 5 accepted subjects, recall ≥ 0.10, n ≥ 60; *weak* = precision ≥ 0.80 with
cluster q05 ≥ 0.70. Applied once to TEST with `check_gate` (precision ≥ .95, CP95 lower ≥ .90, n ≥ 30,
recall ≥ .05). "coverage@95" = TEST recall at the VAL-strong τ when the gate passes, else 0; "descriptive
coverage@95" = best recall on the TEST curve itself (CP95 ≥ .95, n ≥ 60), never used to select anything.
CIs: paired subject-cluster bootstrap (1000 resamples; WISDM has 8 test subjects, under-covers below 10).

**Weights** (VAL only; objective = mean descriptive coverage@95 over posture + locomotion classes, tie-break
mean known-class NLL). Primary pre-specified configuration = the INERTIA1 §7 candidate defaults: locomotion
.25, posture .25, arm .25, body budget .5, arm budget .5, **ρ .65** (pre-audit run: ρ .5). Secondary: stage 1
body weights (WISDM 6 points, Capture-24 3) at ρ .65; stage 2 ρ ∈ {.25, .5, .75, ρ̂} for A3 at its best body
weights.

**TEST is opened only through the ledgered `TestVault`** (`eval/inertia/replay_test_ledger.jsonl`), once per
declared experiment, each with `rerun_reason = post_audit_rule_change` and a detail naming the pre-audit
(unledgered) decode of the same split. Defaults and VAL-selected weights are both decoded inside that single
opening; the fixed arms come from the same-build baseline cache; the Capture-24 posture breakdown is computed
inside it from the in-memory tables (no second decode):

| ledger experiment | fingerprint | rerun reason |
|---|---|---|
| `replay-baseline/wisdm`, `replay-baseline/capture24` | xctest `b7e4cff1cd67…` | post_audit_rule_change |
| `replay-final/wisdm/shadow-primary-hc`, `replay-final/capture24/shadow-primary-hc` | bundle `3fb1ae3e75c8…` | post_audit_rule_change |
| `replay-final/wisdm/shadow-primary-art` | bundle `1b8fadcc1521…` | post_audit_rule_change |

All post-audit TEST numbers are therefore **not pristine**: this split was decoded before the audit.

**Inputs actually ingested** (the decoder's own `motion_heads` report, TEST):

| dataset | bundle | windows ingested | OOD | seconds with Inertia evidence | specialist openings | posture omitted (sleep) |
|---|---|---|---|---|---|---|
| WISDM (138 of 142 blocks; P2's loader yields no window for 4 blocks of 228–285 s, decoded without Inertia) | hc | 4,130 | 930 | 15,969 | 0 | 0 |
| Capture-24 (50 participants) | hc | 913,891 | 48,669 | 4,326,102 | 0 | 0 |
| WISDM | art | refused: `bundle_has_no_usable_head` | — | 0 | 0 | 0 |

**ρ̂** (residual log-LR correlation, HART vs Inertia locomotion, WISDM VAL, 8,824 windows, decoder compat
tables mirrored in Python): **0.634** (per subject 0.45–0.81). Pre-audit bundle: 0.609. The config default
0.65 is above both.

## 5. Results (post-audit, STAND-IN, NOT INERTIA-1)

### 5.1 Baseline arms — decode unchanged, operating points re-derived

Re-decoded with the new build. **Every decode metric of A0s, A0 and A1 is identical to the pre-audit run to
1e-12** (accuracy, NLL, Brier, ECE, unknown mass, coarse accuracy, flips, state counts, both datasets): the
merge and the audit fixes do not touch arms without motion heads. Only the VAL operating points moved,
because of the new clustered strong / weak rule:

| dataset | arm | class | pre-audit VAL → TEST | post-audit VAL → TEST |
|---|---|---|---|---|
| WISDM | A0s | desk_like | weak τ .30 (P .778) | weak τ .62 (P .785) |
| WISDM | A1 | running | strong τ .64 → P .860, gate fails | strong τ .66 → P .860, gate fails |
| WISDM | A1 | desk_like | strong τ .97 → coverage@95 **0.395** | strong τ .975 → P 1.000, coverage@95 **0.164** |
| Capture-24 | A0s | stationary | strong τ .885 → coverage@95 **0.828** | strong τ .965 → P .969, coverage@95 **0.730** |
| Capture-24 | A0 | stationary | strong τ .965 → coverage@95 **0.748** | **weak** τ .30 (P .927) → coverage@95 **0** |

Unchanged: WISDM stationary coverage@95 A0s 0.644 / A0 0.685 / A1 0.649; A0 desk_like 0.392; walking, stairs,
sitting, standing never strong. Paired A0 − A0s and A1 − A0 differences are as in the pre-audit run
(WISDM A0 − A0s locomotion NLL −0.254 [−0.339, −0.165]; A1 − A0 locomotion NLL +0.177 [0.002, 0.353], AURC
−0.033 [−0.067, −0.003], posture NLL −0.021 [−0.052, −0.001], flips −2.30 [−4.55, 0.00]; Capture-24 A0 − A0s
locomotion NLL −0.155 [−0.187, −0.126], posture NLL −0.100 [−0.109, −0.092], flips +0.41 [0.08, 0.79]).

### 5.2 VALIDATION sweep (`shadow-primary-hc`; selection only)

| dataset | arm | config (loc / post / ρ) | objective | known NLL |
|---|---|---|---|---|
| WISDM | A0 / A1 / NAV (baselines) | — | 0.1156 / 0.2643 / 0.2817 | 1.463 / 1.566 / 1.343 |
| WISDM | A2 | loc .10 (post .10 / .25 / .40) · loc .25 (post .10 / **.25 = defaults**) · **loc .40 / post .10 ← selected** | 0.1185 · **0.1215** · **0.1248** | 1.421 · 1.386 · 1.362 |
| WISDM | A3 | same grid at ρ .65 | 0.2643 · **0.2654** · 0.2655 | 1.563 · 1.556 · 1.552 |
| WISDM | A3 | loc .40 / post .10 at ρ .25 / .50 / .63 (ρ̂) / .75 | **0.2658 ← selected (ρ .25)** / 0.2655 / 0.2655 / 0.2654 | 1.548 / 1.550 / 1.552 / 1.555 |
| Capture-24 | A0s / A0 (baselines) | — | 0.0941 / 0.0842 | 1.712 / 1.622 |
| Capture-24 | A2 | .10/.40 · **.25/.25 (defaults)** · **.40/.10 ← selected** | 0.0851 · **0.0858** · **0.0866** | 1.612 · 1.605 · 1.602 |

The posture weight has **no effect at all** (rows with the same locomotion weight are identical to every
digit): the posture head is inert. Only the locomotion weight matters, and only slightly.

### 5.3 WISDM TEST (8 subjects)

| arm | weights (loc / post / ρ) | coarse acc | loco AURC | loco NLL | loco ECE | stationary cov@95 | posture acc | posture AURC | posture NLL | flips/h |
|---|---|---|---|---|---|---|---|---|---|---|
| A0 streams + imu-feat-1 | — | 0.633 | 0.132 | 1.990 | 0.302 | 0.685 | 0.406 | 0.679 | 1.005 | 39.2 |
| A1 + HART | — | 0.698 | 0.096 | 2.167 | 0.321 | 0.649 | 0.429 | 0.667 | 0.983 | 36.9 |
| **A2 + Inertia\*** | **.25 / .25 / .65 (defaults, primary)** | 0.670 | 0.110 | **1.852** | **0.264** | **0.706** | 0.408 | 0.676 | 1.002 | 38.8 |
| A2 + Inertia\* | .40 / .10 / .65 (VAL-selected) | 0.679 | 0.104 | **1.808** | **0.261** | **0.714** | 0.418 | 0.673 | 0.996 | 39.1 |
| **A3 + HART + Inertia\*** | **.25 / .25 / .65 (defaults, primary)** | 0.699 | 0.096 | 2.162 | 0.321 | 0.649 | 0.429 | 0.667 | 0.983 | 37.0 |
| A3 + HART + Inertia\* | .40 / .10 / .25 (VAL-selected) | 0.699 | 0.095 | 2.153 | 0.320 | 0.651 | 0.429 | 0.667 | 0.983 | 37.2 |
| NAV naive average\* (forbidden; ablation) | — | **0.723** | **0.074** | 1.970 | 0.285 | 0.686 | 0.430 | 0.666 | 0.983 | 39.6 |
| A2 control (random-init bundle, refused) | defaults | 0.633 | 0.132 | 1.990 | 0.302 | 0.685 | 0.406 | 0.679 | 1.005 | 39.2 |
| A3 control (random-init bundle, refused) | defaults | 0.698 | 0.096 | 2.167 | 0.321 | 0.649 | 0.429 | 0.667 | 0.983 | 36.9 |
| NAV control (0.5·HART + 0.5·random-init locomotion) | — | 0.725 | 0.083 | 1.973 | 0.296 | 0.683 | 0.430 | 0.666 | 0.982 | 37.5 |

Operating points: no Inertia arm adds a class at ≥ 95 % precision. A2's gated classes are A0's (stationary,
desk_like); A3's are A1's (stationary; running strong on VAL but TEST precision 0.860 → fails; walking weak
0.931 / 0.890 at defaults / selected; desk_like coverage@95 0.164). Sitting / standing abstain everywhere.

Paired differences, B − A, point [95 % CI]; ** = CI excludes 0:

| comparison | weights | loco NLL | loco AURC | stationary cov@95 | posture NLL | posture AURC | flips/h |
|---|---|---|---|---|---|---|---|
| **A2 − A0** | defaults | **−0.138 [−0.204, −0.074]** | **−0.022 [−0.037, −0.011]** | **+0.021 [0.009, 0.036]** | −0.003 [−0.009, 0.000] | −0.002 [−0.011, 0.000] | −0.43 [−1.44, 0.45] |
| A2 − A0 | VAL-selected | **−0.182 [−0.266, −0.099]** | **−0.027 [−0.044, −0.014]** | **+0.029 [0.012, 0.050]** | −0.008 [−0.026, 0.000] | −0.005 [−0.026, 0.001] | −0.14 [−2.38, 1.46] |
| **A3 − A1** | defaults | **−0.004 [−0.008, −0.001]** | −0.000 [−0.001, 0.000] | 0.000 | −0.000 [−0.000, 0.000] | −0.000 [−0.000, 0.000] | +0.14 [0.00, 0.43] |
| A3 − A1 | VAL-selected | **−0.013 [−0.027, −0.003]** | −0.001 [−0.002, 0.001] | +0.001 [0.000, 0.002] | −0.000 [−0.000, 0.000] | −0.000 [−0.001, 0.000] | +0.29 [−0.29, 0.98] |
| **NAV − A1** | — | **−0.196 [−0.330, −0.083]** | **−0.024 [−0.041, −0.011]** | **+0.036 [0.010, 0.067]** | +0.000 [−0.000, 0.001] | −0.001 [−0.006, 0.001] | **+2.73 [1.01, 4.51]** (worse) |
| A2(control) − A0 / A3(control) − A1 | defaults | 0 exactly | 0 | 0 | 0 | 0 | 0 |
| NAV(control) − A1 | — | **−0.194 [−0.305, −0.097]** | **−0.015 [−0.030, −0.004]** | **+0.034 [0.009, 0.064]** | −0.001 [−0.002, 0.000] | −0.001 [−0.005, 0.001] | +0.57 [−0.28, 1.32] |

### 5.4 Capture-24 TEST (50 participants; VAL selected loc .40 / post .10)

| arm | coarse acc | loco AURC | loco NLL | loco ECE | stationary cov@95 | posture acc | posture AURC | posture NLL | recumbent cov@95 | flips/h |
|---|---|---|---|---|---|---|---|---|---|---|
| A0s streams only | 0.748 | 0.094 | 1.462 | 0.211 | **0.730** | 0.268 | 0.559 | 1.862 | 0 | 22.7 |
| A0 streams + imu-feat-1 | 0.793 | 0.096 | 1.308 | 0.168 | 0 (weak on VAL) | 0.294 | 0.528 | 1.761 | 0 | 23.1 |
| **A2 + Inertia\*** defaults (.25 / .25) | **0.809** | **0.087** | **1.270** | **0.162** | 0 (weak on VAL) | 0.299 | 0.521 | 1.755 | 0 | **22.0** |
| A2 + Inertia\* VAL-selected (.40 / .10) | **0.812** | **0.083** | **1.265** | **0.161** | 0 (weak on VAL) | 0.299 | 0.520 | 1.754 | 0 | **21.7** |

A2 − A0, defaults: locomotion NLL **−0.038 [−0.047, −0.030]**, AURC **−0.007 [−0.009, −0.006]**, posture NLL
**−0.006 [−0.008, −0.005]**, posture AURC **−0.007 [−0.009, −0.004]**, flips **−1.15/h [−1.33, −0.97]**.
VAL-selected: locomotion NLL **−0.043 [−0.053, −0.034]**, AURC **−0.010 [−0.013, −0.008]**, posture NLL
**−0.008 [−0.010, −0.005]**, flips **−1.44/h [−1.69, −1.19]**. Stationary is weak on VAL for A0 and A2 alike
(TEST precision 0.927 / 0.931 at τ .30), so neither has stationary coverage@95; recumbent is never reached.
Events (±5 / ±10 / ±30 s recall; ≤ 28-s gap truth, not timing ground truth): A0 9.5 / 16.5 / 39.3 %, A2
8.1 / 14.8 / 37.2 % (defaults), 8.4 / 14.3 / 36.9 % (selected); A2 flags 22,908 / 22,152 events vs A0 25,537
(precision ≤ 1.3 % in every arm).

**Posture by truth group** (computed inside the ledgered decode; known-class argmax over recumbent / seated /
upright; paired subject bootstrap; A0 values reproduce the pre-audit breakdown exactly):

| truth group | states | A0 acc | A2 acc (defaults) | A2 − A0 defaults | A2 − A0 VAL-selected |
|---|---|---|---|---|---|
| recumbent, annotated sleeping | 215,684 | 0.003 | 0.003 | −0.000 [−0.000, 0.000] | −0.000 [−0.001, 0.000] |
| recumbent, awake | 54,307 | 0.007 | 0.007 | +0.000 [−0.000, 0.000] | +0.000 [0.000, 0.001] |
| seated_likely | 158,022 | 0.568 | 0.577 | **+0.008 [0.004, 0.013]** | **+0.010 [0.004, 0.015]** |
| upright_stationary | 26,284 | 0.693 | 0.715 | **+0.022 [0.014, 0.031]** | **+0.028 [0.019, 0.039]** |
| awake static (seated + upright) | 184,306 | 0.586 | 0.597 | **+0.010 [0.007, 0.014]** | **+0.012 [0.007, 0.017]** |

With the posture head inert, A2's small posture change comes only through the locomotion channel (the body
mode posterior shifts between stationary modes), and it is now slightly positive on the awake postures.

### 5.5 What the post-audit replay says (stand-in only, not Inertia-1)

1. **The stand-in's value is locomotion calibration when it is the only motion channel.** A2 − A0 locomotion
   NLL −0.14 / −0.18 (WISDM), −0.04 (Capture-24), AURC −0.01 to −0.03, +2–3 points of WISDM stationary
   coverage at ≥ 95 % precision, fewer display flips on Capture-24. No new class reaches 95 %.
2. **On top of HART it adds almost nothing** (A3 − A1 locomotion NLL −0.004 / −0.013, CIs now exclude 0 but the
   effect is ~1 % of NLL; AURC, coverage, posture ≈ 0).
3. **The pre-audit posture effects are gone.** The posture head is inert, so the Capture-24 posture "gain"
   (sleep-like lying) and the WISDM / awake-posture harm both disappear; what is left is a small locomotion-
   mediated improvement of awake postures (+0.010).
4. **NAV's advantage is mostly tempering HART, not Inertia information.** NAV built on the random-init encoder
   improves A1's locomotion NLL as much as NAV on the hc stand-in (−0.194 vs −0.196) and gains part of the AURC
   (−0.015 vs −0.024). Averaging HART with any calibrated near-prior distribution undoes much of HART's
   over-confidence (A1 − A0 NLL +0.18). The specified fusion (A3) does not do that, by design: it adds Inertia
   evidence, it does not discount HART.
5. **Inert heads are inert.** A bundle with no evidence-bearing head is refused by the decoder
   (`bundle_has_no_usable_head`) and A2 / A3 reproduce A0 / A1 bit for bit; a posture weight on an inert head
   changes nothing.
6. ρ (0.25–0.75) barely matters; the VAL-selected ρ .25 for A3 is within 0.0004 of the default's objective.

## 6. What changed vs the pre-audit run

| quantity | pre-audit (bundle `f61007169e3d`, xctest `5b10b94c86d0`, ρ default .5) | post-audit (bundle `3fb1ae3e75c8`, xctest `b7e4cff1cd67`, ρ default .65) | why |
|---|---|---|---|
| A0s / A0 / A1 decode metrics | — | identical to 1e-12 | decoder changes only touch motion heads |
| Capture-24 A0 stationary coverage@95 | 0.748 (strong) | 0 (weak) | clustered strong rule |
| Capture-24 A0s stationary coverage@95 | 0.828 | 0.730 | clustered strong rule (τ .885 → .965) |
| WISDM A1 desk_like coverage@95 | 0.395 | 0.164 | clustered strong rule (τ .97 → .975) |
| ρ̂ (WISDM VAL) | 0.609 | 0.634 | retrained bundle statuses (abstain / merge set) |
| heads carrying evidence (hc) | posture, locomotion, arm | locomotion only | one-group / decoder_evidence:false heads inert |
| WISDM A2 − A0 locomotion NLL (defaults) | −0.139 [−0.203, −0.075] | −0.138 [−0.204, −0.074] | unchanged |
| WISDM A2 − A0 posture NLL (defaults) | +0.095 [−0.011, 0.278] | −0.003 [−0.009, 0.000] | posture head inert |
| WISDM A2 posture accuracy (defaults) | 0.364 | 0.408 (A0 0.406) | posture head inert |
| WISDM A3 − A1 locomotion NLL (defaults) | −0.006 [−0.013, −0.000] | −0.004 [−0.008, −0.001] | ρ .5 → .65 (more HART discount); sealed statuses |
| WISDM A3 − A1 posture AURC (defaults) | +0.051 [0.000, 0.122] (worse) | −0.000 | posture head inert |
| WISDM NAV − A1 | NLL −0.196, AURC −0.024, flips +2.73 | identical to 3 decimals | NAV reads raw head probabilities, not statuses; consistent with a deterministic retrain of the locomotion head (OOD counts are also identical: 930 / 48,669) |
| Capture-24 A2 − A0 locomotion NLL / AURC | −0.042 / −0.022 | −0.038 / −0.007 | sealed locomotion statuses; no posture term moving stationary-mode mass |
| Capture-24 A2 − A0 posture NLL / AURC | −1.180 / −0.445 | −0.006 / −0.007 | posture head inert |
| Capture-24 A2 recumbent coverage@95 | 0.776 | 0 | posture head inert |
| Capture-24 awake static posture accuracy A2 − A0 | −0.034 [−0.052, −0.016] | +0.010 [0.007, 0.014] | posture head inert |
| Capture-24 A2 − A0 flips/h | +0.54 [0.18, 0.94] | −1.15 [−1.33, −0.97] | no posture term (specialist openings were 0 in both runs) |
| Capture-24 VAL-selected weights | defaults (.25 / .25) | .40 / .10 | posture weight now irrelevant |
| negative control | windows ingested, Δ ≤ 0.001 | bundle refused, Δ = 0 exactly | every art head inert |
| TEST access | unledgered | ledgered, `post_audit_rule_change` | integrity fixes |

## 7. Caveats (read before using any number)

1. **Proxies, not the strap.** The decoder's priors were set on the WHOOP strap's own `dynAccel`; the public
   data reach it only through a proxy. Compare arms; do not read absolute accuracy.
2. **No sleep evidence in any arm** (no sleep stream in public data): recumbent is unreachable for every arm.
   The posture-omitted-on-sleep rule never fires here; in the product it would.
3. **WISDM has no transitions** and only 8 test subjects (CIs under-cover); **Capture-24 boundaries are ±~25 s**.
4. Placement: WISDM and Capture-24 are dominant-wrist; WHOOP is usually worn on the non-dominant wrist.
5. HART on Capture-24 is impossible (no gyro). HART was trained on 82 % zero-gyro windows (§2).
6. Everything Inertia is **STAND-IN, NOT INERTIA-1**; no Inertia-1 checkpoint exists.
7. **Not pristine.** This TEST split was decoded before the audit; the post-audit decodes are ledgered with
   `post_audit_rule_change`. P2 used the same VAL subjects for head calibration.
8. With an inert posture head, the hc stand-in can only speak through locomotion; the posture rows measure
   that indirect effect, not a posture model.

## 8. What is measured, inferred, hypothesis, blocked

| claim | status |
|---|---|
| RESULTS.md reproduces bit-for-bit from `eval_data.npz` (15,363 / 10,205 / 0.664 / 0.660) | measured |
| production-faithful HART on WISDM test: coverage 0.547, macro-F1 0.701 | measured |
| 82 % / 83 % of HART train / eval windows have all-zero gyro (`train.py` searchsorted on unsorted timestamps) | measured |
| baseline arms' decode unchanged by the merge + audit fixes (metrics identical to 1e-12) | measured |
| clustered strong rule demotes Capture-24 A0 stationary to weak and lowers A0s / A1 coverage@95 | measured |
| stand-in alone improves locomotion calibration / ranking (A2 − A0) on both datasets | measured |
| stand-in adds ~1 % of locomotion NLL on top of HART (A3 − A1) and nothing else | measured (WISDM, 8 subjects) |
| inert heads / a bundle with no usable head leave the decode bit-identical | measured |
| NAV's calibration gain is mostly tempering HART (random-init NAV gets the same NLL gain) | measured (WISDM) |
| ρ̂ = 0.634; ρ ∈ [.25, .75] barely changes VAL or TEST | measured |
| production HART on WHOOP data behaves like the production-faithful WISDM run | inferred |
| a real Inertia-1 encoder would make posture or specialist classes evidence-bearing | hypothesis |
| any Inertia-1 number | **blocked**: no checkpoint |
| Capture-24 negative control | not run (the art bundle has no usable head: it would be A0 by construction) |

## 9. Issues found in other owners' areas

1. `activity_context/train.py::_finish_block` — gyro merge over unsorted timestamps (82 % / 83 % zero-gyro
   windows) and a 20 Hz assumption for every block (1638 is 49.8 / 24.8 Hz). `train.py` is unchanged at
   `227ff05c` (the `searchsorted` merge is still at line 121); HART still needs the fix and a retrain.
2. `tests/test_model.py` fixture pins the pretrained HART checkpoint digest.
3. Harness (S): `streams` drops imu-feat-1 windows (A0 = `hart` arm on an encoder-free file); the naive-average
   fold maps stairs → walking (HART's C10 maps stairs → other_movement). Ablation only.
4. Sweep tie-break: when every configuration ties (the art bundle), `max` keeps the first grid point
   (.10 / .10) rather than the defaults. Harmless here (identical decodes), worth a defaults-first tie-break.
5. Fixed by the audit commits (verified in this run): random-init stand-in bundles now load (`allow_offline`),
   subprocesses get an env allowlist, replay TEST decodes are ledgered, truth reads the repo crosswalk.

## 10. Files

* Code: `activity_context/inertia/replay_{data,export,inertia,score,eval,report}.py`. Changes in this run
  (`replay_eval.py` only): candidate-default ρ .65 (and stage 1 of the sweep at it); the Capture-24 posture
  breakdown (`posture_decomposition`) computed inside the ledgered TEST evaluator.
* Tests: `tests/inertia/test_replay_{export,score,eval}.py` (36 pass).
* Ledger: `eval/inertia/replay_test_ledger.jsonl` (written by the vault).
* Outside git, `research/inertia-replay/`: `runs/post_audit/{baseline,shadow-primary-hc,shadow-primary-art}/`
  (baseline / sweep / final JSONs, per-config progress, `SYSTEM_COMPARISON.tables.md`), `cache/heads/<bundle>/`
  (dense hop-5 s windows from the sealed bundles), `runs/baseline/` + `runs/shadow-primary-*` (pre-audit run,
  superseded), `swift_sources_at_build_227ff05c.sha256`, `logs/post_audit/`, `scratch/post_audit.sh`
  (`scratch/phase2.sh` is the outdated pre-audit driver).

## 11. Reproduction (post-audit)

```bash
cd Tools/ActivityContext
export PYTHONPATH=. INERTIA_DATA_ROOT=<research> WISDM_DIR=<unpacked wisdm-dataset>
export NARA_REPLAY_XCTEST=~/Library/Caches/nara-replay-R/release/StrandAnalyticsPackageTests.xctest
# decoder build from a clean worktree, then copy the .xctest + resource bundles to NARA_REPLAY_XCTEST's dir
(cd ../../Packages/StrandAnalytics && swift build --build-tests -c release -Xswiftc -enable-testing \
    --scratch-path <research>/inertia-replay/swiftbuild)
# dense stand-in windows (load_bundle serves the sealed statuses)
python -m activity_context.inertia.replay_inertia --bundle <bundles>/shadow-primary-hc --dataset wisdm --split val \
    --out <research>/inertia-replay/cache/heads/shadow-primary-hc/wisdm_val_hop5.npz   # … test, capture24 val/test
# baselines (ledgered TEST)
python -m activity_context.inertia.replay_eval baseline --dataset wisdm --out <out>/baseline \
    --rerun-reason post_audit_rule_change --rerun-detail "<what changed>"          # … --dataset capture24
# VAL sweeps (rho-extra = rho-hat), then one ledgered TEST decode per (dataset, bundle)
python -m activity_context.inertia.replay_eval sweep --bundle <bundles>/shadow-primary-hc --dataset wisdm \
    --out <out>/shadow-primary-hc --jobs 3 --rho-extra 0.63
python -m activity_context.inertia.replay_eval final --bundle <bundles>/shadow-primary-hc --dataset wisdm \
    --sweep <out>/shadow-primary-hc/sweep_wisdm.json --out <out>/shadow-primary-hc --n-boot 1000 \
    --rerun-reason post_audit_rule_change --rerun-detail "<what changed>"
python -m activity_context.inertia.replay_report --runs <out>/shadow-primary-hc --out <out>/shadow-primary-hc/SYSTEM_COMPARISON \
    --baseline <out>/baseline
# the full sequence (<= 8 workers): research/inertia-replay/scratch/post_audit.sh
```

## Appendix A — post-audit tables for `shadow-primary-hc` incl. the baseline arms (generated by `replay_report`)

<!-- generated by activity_context.inertia.replay_report; STAND-IN, NOT INERTIA-1 -->

† = subject-cluster bootstrap over fewer than 10 subjects (WISDM test has 8): the percentile CI under-covers; read it as descriptive. ** = the 95 % CI excludes 0.

### wisdm TEST — bundle-independent arms (A0s, A0, A1); xctest build b7e4cff1cd67

_Ledger: `replay-baseline/wisdm`, evaluation 1 on test split `6daf528d1eed`; rerun reason: post_audit_rule_change — decoder rebuilt from 227ff05c after the red-team audit fixes (1802a012, a424d207) and the nara/main merge (0176a63e): specialist gate inside the Inertia budget, posture omitted on asleep/in-bed seconds, hartRedundancy default 0.65, strict replay validation; the pre-audit replay (xctest 5b10b94c86d0, not ledgered) had already decoded this test split._

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
| running | A1 +HART | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
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
| desk_like | A0s streams only | 574 | weak | 0.620 | 0.785 | 0.755 | 0.807 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
| repetitive_hand_motion | A0s streams only | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A0 streams+imu-feat-1 | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| repetitive_hand_motion | A1 +HART | 574 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### paired bootstrap A0-A0s

A0 − A0s (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.008 [-0.021, 0.006]† |
| posture | AURC (binned) Δ | -0.014 [-0.038, 0.003]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.254 [-0.339, -0.165]† ** |
| locomotion | AURC (binned) Δ | -0.025 [-0.053, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.040 [0.014, 0.068]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.040 [0.014, 0.068]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.344, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.14 [-1.97, 2.40]† |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001]† ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353]† ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00]† |

#### paired bootstrap A1-A0s

A1 − A0s (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.029 [-0.063, -0.001]† ** |
| posture | AURC (binned) Δ | -0.024 [-0.063, -0.002]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.077 [-0.260, 0.094]† |
| locomotion | AURC (binned) Δ | -0.058 [-0.113, -0.021]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.005 [-0.048, 0.061]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.005 [-0.048, 0.061]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.337, 0.965]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.15 [-3.83, -0.58]† ** |

### capture24 TEST — bundle-independent arms (A0s, A0); xctest build b7e4cff1cd67

_Ledger: `replay-baseline/capture24`, evaluation 1 on test split `eb616899278f`; rerun reason: post_audit_rule_change — decoder rebuilt from 227ff05c after the red-team audit fixes (1802a012, a424d207) and the nara/main merge (0176a63e): specialist gate inside the Inertia budget, posture omitted on asleep/in-bed seconds, hartRedundancy default 0.65, strict replay validation; the pre-audit replay (xctest 5b10b94c86d0, not ledgered) had already decoded this test split._

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
| stationary | A0s streams only | 443,302 | strong | 0.965 | 0.969 | 0.968 | 0.730 | 0.730 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | weak | 0.300 | 0.927 | 0.926 | 0.899 | 0.000 | 0.783 | 0.960 |
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
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.730 [-0.755, -0.705] ** |
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
| A2 | 0.1 | 0.1 | 0.25 | 0.65 | 0.118 | 1.421 |
| A3 | 0.1 | 0.1 | 0.25 | 0.65 | 0.264 | 1.563 |
| A2 | 0.1 | 0.25 | 0.25 | 0.65 | 0.118 | 1.421 |
| A3 | 0.1 | 0.25 | 0.25 | 0.65 | 0.264 | 1.563 |
| A2 | 0.1 | 0.4 | 0.25 | 0.65 | 0.118 | 1.421 |
| A3 | 0.1 | 0.4 | 0.25 | 0.65 | 0.264 | 1.563 |
| A2 | 0.25 | 0.1 | 0.25 | 0.65 | 0.121 | 1.386 |
| A3 | 0.25 | 0.1 | 0.25 | 0.65 | 0.265 | 1.556 |
| A2 | 0.25 | 0.25 | 0.25 | 0.65 | 0.121 | 1.386 |
| A3 | 0.25 | 0.25 | 0.25 | 0.65 | 0.265 | 1.556 |
| A2 | 0.4 | 0.1 | 0.25 | 0.65 | 0.125 | 1.362 |
| A3 | 0.4 | 0.1 | 0.25 | 0.65 | 0.265 | 1.552 |
| A2 | 0.4 | 0.1 | 0.25 | 0.25 | 0.125 | 1.362 |
| A3 | 0.4 | 0.1 | 0.25 | 0.25 | 0.266 | 1.548 |
| A2 | 0.4 | 0.1 | 0.25 | 0.5 | 0.125 | 1.362 |
| A3 | 0.4 | 0.1 | 0.25 | 0.5 | 0.266 | 1.550 |
| A2 | 0.4 | 0.1 | 0.25 | 0.63 | 0.125 | 1.362 |
| A3 | 0.4 | 0.1 | 0.25 | 0.63 | 0.265 | 1.552 |
| A2 | 0.4 | 0.1 | 0.25 | 0.75 | 0.125 | 1.362 |
| A3 | 0.4 | 0.1 | 0.25 | 0.75 | 0.265 | 1.555 |

### wisdm TEST ledger

_Ledger: `replay-final/wisdm/shadow-primary-hc`, evaluation 1 on test split `6daf528d1eed`; rerun reason: post_audit_rule_change — sealed post-audit bundle retrained from clean commit a424d207 (seal 227ff05c; one-evidence-group / decoder_evidence:false heads inert) decoded with the 227ff05c decoder; the pre-audit replay (bundle built from 32a2dc52, xctest 5b10b94c86d0, not ledgered) had already decoded this test split._

### wisdm TEST — Inertia weights: defaults (A2: loc 0.25, post 0.25, arm 0.25, rho 0.65; A3: loc 0.25, post 0.25, arm 0.25, rho 0.65)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.670 | 38.8 | 7.0 | — | 4,130 | 930 |
| A3 +HART+Inertia* | 5,156 | 0.699 | 37.0 | 7.0 | — | 4,130 | 930 |
| NAV naive avg* | 5,156 | 0.723 | 39.6 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.670 | 0.110 | 1.852 | 0.576 | 0.264 | 0.033 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.641 | 0.096 | 2.162 | 0.670 | 0.321 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.671 | 0.074 | 1.970 | 0.598 | 0.285 | 0.078 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.706 | 0.706 | 0.706 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.686 | 0.686 | 0.686 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.931 | 0.879 | 0.355 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.950 | 0.881 | 0.841 | 0.684 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
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
| A2 +Inertia* | 574 | 0.408 | 0.676 | 1.002 | 0.718 | 0.284 | 0.126 | 0.059 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.122 | 0.056 |
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
| desk_like | A0s streams only | 574 | weak | 0.620 | 0.785 | 0.755 | 0.807 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.516 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
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
| posture | NLL (known) Δ | -0.003 [-0.009, 0.000]† |
| posture | AURC (binned) Δ | -0.002 [-0.011, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.138 [-0.204, -0.074]† ** |
| locomotion | AURC (binned) Δ | -0.022 [-0.037, -0.011]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.021 [0.009, 0.036]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.021 [0.009, 0.036]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -0.43 [-1.44, 0.45]† |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.000 [-0.000, 0.000]† |
| posture | AURC (binned) Δ | -0.000 [-0.000, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.004 [-0.008, -0.001]† ** |
| locomotion | AURC (binned) Δ | -0.000 [-0.001, 0.000]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.052]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.14 [0.00, 0.43]† |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [-0.000, 0.001]† |
| posture | AURC (binned) Δ | -0.001 [-0.006, 0.001]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.196 [-0.330, -0.083]† ** |
| locomotion | AURC (binned) Δ | -0.024 [-0.041, -0.011]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.036 [0.010, 0.067]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.036 [0.010, 0.067]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.332]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 2.73 [1.01, 4.51]† ** |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001]† ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353]† ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00]† |

### wisdm TEST — Inertia weights: selected (A2: loc 0.4, post 0.1, arm 0.25, rho 0.65; A3: loc 0.4, post 0.1, arm 0.25, rho 0.25)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.679 | 39.1 | 7.0 | — | 4,130 | 930 |
| A3 +HART+Inertia* | 5,156 | 0.699 | 37.2 | 7.0 | — | 4,130 | 930 |
| NAV naive avg* | 5,156 | 0.723 | 39.6 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.679 | 0.104 | 1.808 | 0.564 | 0.261 | 0.033 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.643 | 0.095 | 2.153 | 0.667 | 0.320 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.671 | 0.074 | 1.970 | 0.598 | 0.285 | 0.078 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.714 | 0.714 | 0.714 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.651 | 0.651 | 0.651 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.686 | 0.686 | 0.686 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.890 | 0.835 | 0.398 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.950 | 0.881 | 0.841 | 0.684 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.640 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
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
| A2 +Inertia* | 574 | 0.418 | 0.673 | 0.996 | 0.712 | 0.272 | 0.124 | 0.057 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.122 | 0.056 |
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
| desk_like | A0s streams only | 574 | weak | 0.620 | 0.785 | 0.755 | 0.807 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.517 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
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
| posture | NLL (known) Δ | -0.008 [-0.026, 0.000]† |
| posture | AURC (binned) Δ | -0.005 [-0.026, 0.001]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.182 [-0.266, -0.099]† ** |
| locomotion | AURC (binned) Δ | -0.027 [-0.044, -0.014]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.029 [0.012, 0.050]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.029 [0.012, 0.050]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -0.14 [-2.38, 1.46]† |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.000 [-0.000, 0.000]† |
| posture | AURC (binned) Δ | -0.000 [-0.001, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.013 [-0.027, -0.003]† ** |
| locomotion | AURC (binned) Δ | -0.001 [-0.002, 0.001]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.001 [0.000, 0.002]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.001 [0.000, 0.002]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [-0.404, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.29 [-0.29, 0.98]† |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [-0.000, 0.001]† |
| posture | AURC (binned) Δ | -0.001 [-0.006, 0.001]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.196 [-0.330, -0.083]† ** |
| locomotion | AURC (binned) Δ | -0.024 [-0.041, -0.011]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.036 [0.010, 0.067]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.036 [0.010, 0.067]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.332]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 2.73 [1.01, 4.51]† ** |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001]† ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353]† ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00]† |

### capture24: VALIDATION sweep

| arm | w_loc | w_post | w_arm | rho | VAL objective (mean cov@95) | VAL NLL (tie-break) |
|---|---|---|---|---|---|---|
| A2 | 0.1 | 0.4 | 0.25 | 0.65 | 0.085 | 1.612 |
| A2 | 0.25 | 0.25 | 0.25 | 0.65 | 0.086 | 1.605 |
| A2 | 0.4 | 0.1 | 0.25 | 0.65 | 0.087 | 1.602 |

### capture24 TEST ledger

_Ledger: `replay-final/capture24/shadow-primary-hc`, evaluation 1 on test split `eb616899278f`; rerun reason: post_audit_rule_change — sealed post-audit bundle retrained from clean commit a424d207 (seal 227ff05c; one-evidence-group / decoder_evidence:false heads inert) decoded with the 227ff05c decoder; the pre-audit replay (bundle built from 32a2dc52, xctest 5b10b94c86d0, not ledgered) had already decoded this test split._

### capture24 TEST — Inertia weights: defaults (A2: loc 0.25, post 0.25, arm 0.25, rho 0.65)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 914,242 | 0.748 | 22.7 | 1269.7 | — | — | — |
| A0 streams+imu-feat-1 | 914,242 | 0.793 | 23.1 | 1269.7 | — | — | — |
| A2 +Inertia* | 914,242 | 0.809 | 22.0 | 1269.7 | — | 913,891 | 48,669 |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 557,066 | 0.748 | 0.094 | 1.462 | 0.447 | 0.211 | 0.031 | 0.000 |
| A0 streams+imu-feat-1 | 557,066 | 0.793 | 0.096 | 1.308 | 0.368 | 0.168 | 0.031 | 0.000 |
| A2 +Inertia* | 557,066 | 0.809 | 0.087 | 1.270 | 0.350 | 0.162 | 0.031 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 443,302 | strong | 0.965 | 0.969 | 0.968 | 0.730 | 0.730 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | weak | 0.300 | 0.927 | 0.926 | 0.899 | 0.000 | 0.783 | 0.960 |
| stationary | A2 +Inertia* | 443,302 | weak | 0.300 | 0.931 | 0.930 | 0.906 | 0.000 | 0.815 | 0.955 |
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
| A2 +Inertia* | 454,297 | 0.299 | 0.521 | 1.755 | 0.887 | 0.319 | 0.165 | 0.097 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | A0s streams only | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A0 streams+imu-feat-1 | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A2 +Inertia* | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0s streams only | 212,329 | abstain | 1.000 | — | — | — | 0.000 | 0.224 | 0.630 |
| seated_likely | A0 streams+imu-feat-1 | 212,329 | weak | 0.580 | 0.854 | 0.852 | 0.298 | 0.000 | 0.248 | 0.640 |
| seated_likely | A2 +Inertia* | 212,329 | weak | 0.580 | 0.855 | 0.853 | 0.305 | 0.000 | 0.257 | 0.635 |
| upright_stationary | A0s streams only | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 128,775 | 0.290 | 0.636 | 3.621 | 1.225 | 0.579 | 0.007 | 0.000 |
| A0 streams+imu-feat-1 | 128,775 | 0.291 | 0.637 | 3.588 | 1.223 | 0.579 | 0.007 | 0.000 |
| A2 +Inertia* | 128,775 | 0.292 | 0.637 | 3.574 | 1.223 | 0.579 | 0.007 | 0.000 |

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
| A2 +Inertia* | ±5 s | 63 | 22,845 | 713 | 0.003 | 0.081 | 0.005 |
| A2 +Inertia* | ±10 s | 115 | 22,793 | 661 | 0.005 | 0.148 | 0.010 |
| A2 +Inertia* | ±30 s | 289 | 22,619 | 487 | 0.013 | 0.372 | 0.024 |
| A2 +Inertia* | getting_up_like ±10 s | 0 | 35 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | lying_down_like ±10 s | 0 | 8 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_start ±10 s | 0 | 255 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_stop ±10 s | 0 | 237 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | sit_to_stand_like ±10 s | 12 | 2,714 | 140 | 0.004 | 0.079 | 0.008 (med 4.2 s, p90 8.4 s) |
| A2 +Inertia* | stand_to_sit_like ±10 s | 11 | 4,614 | 172 | 0.002 | 0.060 | 0.005 (med 7.5 s, p90 9.5 s) |
| A2 +Inertia* | walk_start ±10 s | 52 | 7,350 | 150 | 0.007 | 0.257 | 0.014 (med 5.0 s, p90 9.0 s) |
| A2 +Inertia* | walk_stop ±10 s | 40 | 7,580 | 197 | 0.005 | 0.169 | 0.010 (med 4.5 s, p90 8.5 s) |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 50 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.006 [-0.008, -0.005] ** |
| posture | AURC (binned) Δ | -0.007 [-0.009, -0.004] ** |
| posture | recumbent: descriptive coverage@95 Δ | 0.000 [-0.000, 0.000] |
| posture | recumbent: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.009 [0.000, 0.196] ** |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.038 [-0.047, -0.030] ** |
| locomotion | AURC (binned) Δ | -0.007 [-0.009, -0.006] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.032 [0.000, 0.766] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
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
| display | label flips per hour Δ | -1.15 [-1.33, -0.97] ** |

### capture24 TEST — Inertia weights: selected (A2: loc 0.4, post 0.1, arm 0.25, rho 0.65)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 914,242 | 0.748 | 22.7 | 1269.7 | — | — | — |
| A0 streams+imu-feat-1 | 914,242 | 0.793 | 23.1 | 1269.7 | — | — | — |
| A2 +Inertia* | 914,242 | 0.812 | 21.7 | 1269.7 | — | 913,891 | 48,669 |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 557,066 | 0.748 | 0.094 | 1.462 | 0.447 | 0.211 | 0.031 | 0.000 |
| A0 streams+imu-feat-1 | 557,066 | 0.793 | 0.096 | 1.308 | 0.368 | 0.168 | 0.031 | 0.000 |
| A2 +Inertia* | 557,066 | 0.812 | 0.083 | 1.265 | 0.346 | 0.161 | 0.031 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 443,302 | strong | 0.965 | 0.969 | 0.968 | 0.730 | 0.730 | 0.856 | 0.715 |
| stationary | A0 streams+imu-feat-1 | 443,302 | weak | 0.300 | 0.927 | 0.926 | 0.899 | 0.000 | 0.783 | 0.960 |
| stationary | A2 +Inertia* | 443,302 | weak | 0.300 | 0.932 | 0.932 | 0.908 | 0.000 | 0.822 | 0.955 |
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
| A2 +Inertia* | 454,297 | 0.299 | 0.520 | 1.754 | 0.886 | 0.318 | 0.163 | 0.095 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | A0s streams only | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A0 streams+imu-feat-1 | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| recumbent | A2 +Inertia* | 269,991 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| seated_likely | A0s streams only | 212,329 | abstain | 1.000 | — | — | — | 0.000 | 0.224 | 0.630 |
| seated_likely | A0 streams+imu-feat-1 | 212,329 | weak | 0.580 | 0.854 | 0.852 | 0.298 | 0.000 | 0.248 | 0.640 |
| seated_likely | A2 +Inertia* | 212,329 | weak | 0.580 | 0.855 | 0.853 | 0.306 | 0.000 | 0.261 | 0.630 |
| upright_stationary | A0s streams only | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A0 streams+imu-feat-1 | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| upright_stationary | A2 +Inertia* | 26,284 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |

#### arm_behavior

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 128,775 | 0.290 | 0.636 | 3.621 | 1.225 | 0.579 | 0.007 | 0.000 |
| A0 streams+imu-feat-1 | 128,775 | 0.291 | 0.637 | 3.588 | 1.223 | 0.579 | 0.007 | 0.000 |
| A2 +Inertia* | 128,775 | 0.292 | 0.637 | 3.570 | 1.222 | 0.579 | 0.007 | 0.000 |

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
| A2 +Inertia* | ±5 s | 65 | 22,087 | 711 | 0.003 | 0.084 | 0.006 |
| A2 +Inertia* | ±10 s | 111 | 22,041 | 665 | 0.005 | 0.143 | 0.010 |
| A2 +Inertia* | ±30 s | 286 | 21,866 | 490 | 0.013 | 0.369 | 0.025 |
| A2 +Inertia* | getting_up_like ±10 s | 0 | 34 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | lying_down_like ±10 s | 0 | 3 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_start ±10 s | 0 | 221 | 2 | 0.000 | 0.000 | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | run_stop ±10 s | 0 | 207 | 0 | 0.000 | — | 0.000 (med — s, p90 — s) |
| A2 +Inertia* | sit_to_stand_like ±10 s | 14 | 2,728 | 138 | 0.005 | 0.092 | 0.010 (med 4.2 s, p90 8.9 s) |
| A2 +Inertia* | stand_to_sit_like ±10 s | 10 | 4,787 | 173 | 0.002 | 0.055 | 0.004 (med 7.5 s, p90 9.5 s) |
| A2 +Inertia* | walk_start ±10 s | 49 | 6,930 | 153 | 0.007 | 0.243 | 0.014 (med 4.5 s, p90 9.0 s) |
| A2 +Inertia* | walk_stop ±10 s | 38 | 7,131 | 199 | 0.005 | 0.160 | 0.010 (med 5.0 s, p90 8.5 s) |

#### paired bootstrap A2-A0

A2 − A0 (paired subject-cluster bootstrap, 1000 resamples, 50 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.008 [-0.010, -0.005] ** |
| posture | AURC (binned) Δ | -0.008 [-0.011, -0.004] ** |
| posture | recumbent: descriptive coverage@95 Δ | 0.000 [-0.000, 0.000] |
| posture | recumbent: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | seated_likely: descriptive coverage@95 Δ | 0.014 [0.001, 0.223] ** |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000] |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
| locomotion | NLL (known) Δ | -0.043 [-0.053, -0.034] ** |
| locomotion | AURC (binned) Δ | -0.010 [-0.013, -0.008] ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.039 [0.000, 0.777] |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000] |
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
| display | label flips per hour Δ | -1.44 [-1.69, -1.19] ** |

## Appendix B — post-audit negative control `shadow-primary-art` (WISDM; generated by `replay_report`)

Every head of this bundle is `decoder_evidence: false`; the decoder refuses it (`bundle_has_no_usable_head`), so the
rows labelled A2 / A3 reproduce A0 / A1 exactly; NAV averages HART with the random-init locomotion head.

### wisdm: VALIDATION sweep

| arm | w_loc | w_post | w_arm | rho | VAL objective (mean cov@95) | VAL NLL (tie-break) |
|---|---|---|---|---|---|---|
| A2 | 0.1 | 0.1 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.1 | 0.1 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.1 | 0.25 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.1 | 0.25 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.1 | 0.4 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.1 | 0.4 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.25 | 0.1 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.25 | 0.1 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.25 | 0.25 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.25 | 0.25 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.4 | 0.1 | 0.25 | 0.65 | 0.116 | 1.463 |
| A3 | 0.4 | 0.1 | 0.25 | 0.65 | 0.264 | 1.566 |
| A2 | 0.1 | 0.1 | 0.25 | 0.25 | 0.116 | 1.463 |
| A3 | 0.1 | 0.1 | 0.25 | 0.25 | 0.264 | 1.566 |
| A2 | 0.1 | 0.1 | 0.25 | 0.5 | 0.116 | 1.463 |
| A3 | 0.1 | 0.1 | 0.25 | 0.5 | 0.264 | 1.566 |
| A2 | 0.1 | 0.1 | 0.25 | 0.63 | 0.116 | 1.463 |
| A3 | 0.1 | 0.1 | 0.25 | 0.63 | 0.264 | 1.566 |
| A2 | 0.1 | 0.1 | 0.25 | 0.75 | 0.116 | 1.463 |
| A3 | 0.1 | 0.1 | 0.25 | 0.75 | 0.264 | 1.566 |

### wisdm TEST ledger

_Ledger: `replay-final/wisdm/shadow-primary-art`, evaluation 1 on test split `6daf528d1eed`; rerun reason: post_audit_rule_change — sealed post-audit bundle retrained from clean commit a424d207 (seal 227ff05c; one-evidence-group / decoder_evidence:false heads inert) decoded with the 227ff05c decoder; the pre-audit replay (bundle built from 32a2dc52, xctest 5b10b94c86d0, not ledgered) had already decoded this test split._

### wisdm TEST — Inertia weights: defaults (A2: loc 0.25, post 0.25, arm 0.25, rho 0.65; A3: loc 0.25, post 0.25, arm 0.25, rho 0.65)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.633 | 39.2 | 7.0 | — | 0 | 0 |
| A3 +HART+Inertia* | 5,156 | 0.698 | 36.9 | 7.0 | — | 0 | 0 |
| NAV naive avg* | 5,156 | 0.725 | 37.5 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.667 | 0.083 | 1.973 | 0.616 | 0.296 | 0.074 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.683 | 0.683 | 0.683 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.960 | 0.908 | 0.840 | 0.260 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.600 | 0.857 | 0.821 | 0.962 | 0.000 | 0.000 | — |
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
| A2 +Inertia* | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |
| NAV naive avg* | 574 | 0.430 | 0.666 | 0.982 | 0.701 | 0.259 | 0.111 | 0.045 |

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
| A2 +Inertia* | 1,148 | 0.413 | 0.496 | 2.797 | 1.016 | 0.472 | 0.008 | 0.000 |
| A3 +HART+Inertia* | 1,148 | 0.415 | 0.493 | 2.539 | 0.997 | 0.470 | 0.008 | 0.000 |
| NAV naive avg* | 1,148 | 0.415 | 0.493 | 2.546 | 0.997 | 0.470 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A0s streams only | 574 | weak | 0.620 | 0.785 | 0.755 | 0.807 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
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
| posture | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| locomotion | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.00 [0.00, 0.00]† |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| locomotion | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.00 [0.00, 0.00]† |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.001 [-0.002, 0.000]† |
| posture | AURC (binned) Δ | -0.001 [-0.005, 0.001]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.208]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.194 [-0.305, -0.097]† ** |
| locomotion | AURC (binned) Δ | -0.015 [-0.030, -0.004]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.034 [0.009, 0.064]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.034 [0.009, 0.064]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [-0.090, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.927, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.57 [-0.28, 1.32]† |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001]† ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353]† ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00]† |

### wisdm TEST — Inertia weights: selected (A2: loc 0.1, post 0.1, arm 0.25, rho 0.65; A3: loc 0.1, post 0.1, arm 0.25, rho 0.65)

| arm | published states | coarse 4-class acc | display flips/h | hours | refusals | Inertia windows ingested | of which OOD |
|---|---|---|---|---|---|---|---|
| A0s streams only | 5,156 | 0.588 | 39.1 | 7.0 | — | — | — |
| A0 streams+imu-feat-1 | 5,156 | 0.633 | 39.2 | 7.0 | — | — | — |
| A1 +HART | 5,156 | 0.698 | 36.9 | 7.0 | — | — | — |
| A2 +Inertia* | 5,156 | 0.633 | 39.2 | 7.0 | — | 0 | 0 |
| A3 +HART+Inertia* | 5,156 | 0.698 | 36.9 | 7.0 | — | 0 | 0 |
| NAV naive avg* | 5,156 | 0.725 | 37.5 | 7.0 | — | — | — |

#### locomotion

| arm | states | top-known acc | AURC | NLL (known) | Brier | ECE-15 | unknown mass | share unknown>=.5 |
|---|---|---|---|---|---|---|---|---|
| A0s streams only | 4,309 | 0.588 | 0.156 | 2.243 | 0.716 | 0.340 | 0.034 | 0.000 |
| A0 streams+imu-feat-1 | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A1 +HART | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| A2 +Inertia* | 4,309 | 0.633 | 0.132 | 1.990 | 0.643 | 0.302 | 0.034 | 0.000 |
| A3 +HART+Inertia* | 4,309 | 0.641 | 0.096 | 2.167 | 0.671 | 0.321 | 0.079 | 0.000 |
| NAV naive avg* | 4,309 | 0.667 | 0.083 | 1.973 | 0.616 | 0.296 | 0.074 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| stationary | A0s streams only | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.644 | 0.644 | 0.644 | 0.385 |
| stationary | A0 streams+imu-feat-1 | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A1 +HART | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | A2 +Inertia* | 3,431 | strong | 0.300 | 0.999 | 0.997 | 0.685 | 0.685 | 0.685 | 0.385 |
| stationary | A3 +HART+Inertia* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.649 | 0.649 | 0.649 | 0.375 |
| stationary | NAV naive avg* | 3,431 | strong | 0.300 | 1.000 | 0.998 | 0.683 | 0.683 | 0.683 | 0.375 |
| walking | A0s streams only | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A0 streams+imu-feat-1 | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A1 +HART | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | A2 +Inertia* | 304 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| walking | A3 +HART+Inertia* | 304 | weak | 0.960 | 0.924 | 0.867 | 0.319 | 0.000 | 0.000 | — |
| walking | NAV naive avg* | 304 | weak | 0.960 | 0.908 | 0.840 | 0.260 | 0.000 | 0.000 | — |
| running | A0s streams only | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A0 streams+imu-feat-1 | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A1 +HART | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | A2 +Inertia* | 287 | abstain | 1.000 | — | — | — | 0.000 | 0.000 | — |
| running | A3 +HART+Inertia* | 287 | strong | 0.660 | 0.860 | 0.824 | 0.962 | 0.000 | 0.000 | — |
| running | NAV naive avg* | 287 | strong | 0.600 | 0.857 | 0.821 | 0.962 | 0.000 | 0.000 | — |
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
| A2 +Inertia* | 574 | 0.406 | 0.679 | 1.005 | 0.722 | 0.288 | 0.135 | 0.070 |
| A3 +HART+Inertia* | 574 | 0.429 | 0.667 | 0.983 | 0.701 | 0.261 | 0.123 | 0.057 |
| NAV naive avg* | 574 | 0.430 | 0.666 | 0.982 | 0.701 | 0.259 | 0.111 | 0.045 |

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
| A2 +Inertia* | 1,148 | 0.413 | 0.496 | 2.797 | 1.016 | 0.472 | 0.008 | 0.000 |
| A3 +HART+Inertia* | 1,148 | 0.415 | 0.493 | 2.539 | 0.997 | 0.470 | 0.008 | 0.000 |
| NAV naive avg* | 1,148 | 0.415 | 0.493 | 2.546 | 0.997 | 0.470 | 0.008 | 0.000 |

| class | arm | truth states | VAL status | VAL tau | TEST precision @VAL tau | CP95 lower | TEST recall @VAL tau | coverage@95 (VAL-strong tau, TEST gate passed) | descriptive coverage@95 (TEST curve) | tau |
|---|---|---|---|---|---|---|---|---|---|---|
| desk_like | A0s streams only | 574 | weak | 0.620 | 0.785 | 0.755 | 0.807 | 0.000 | 0.000 | — |
| desk_like | A0 streams+imu-feat-1 | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A1 +HART | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
| desk_like | A2 +Inertia* | 574 | strong | 0.970 | 0.991 | 0.973 | 0.392 | 0.392 | 0.512 | 0.965 |
| desk_like | A3 +HART+Inertia* | 574 | strong | 0.975 | 1.000 | 0.969 | 0.164 | 0.164 | 0.601 | 0.960 |
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
| posture | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| locomotion | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.00 [0.00, 0.00]† |

#### paired bootstrap A3-A1

A3 − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| posture | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.000 [0.000, 0.000]† |
| locomotion | AURC (binned) Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.00 [0.00, 0.00]† |

#### paired bootstrap NAV-A1

NAV − A1 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.001 [-0.002, 0.000]† |
| posture | AURC (binned) Δ | -0.001 [-0.005, 0.001]† |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.208]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | -0.194 [-0.305, -0.097]† ** |
| locomotion | AURC (binned) Δ | -0.015 [-0.030, -0.004]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | 0.034 [0.009, 0.064]† ** |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | 0.034 [0.009, 0.064]† ** |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [-0.090, 0.000]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [-0.927, 0.000]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | 0.57 [-0.28, 1.32]† |

#### paired bootstrap A1-A0

A1 − A0 (paired subject-cluster bootstrap, 1000 resamples, 8 subjects; point [95% CI]; ** = CI excludes 0)

| head | metric | B − A |
|---|---|---|
| posture | NLL (known) Δ | -0.021 [-0.052, -0.001]† ** |
| posture | AURC (binned) Δ | -0.011 [-0.041, -0.000]† ** |
| posture | seated_likely: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| posture | seated_likely: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| posture | upright_stationary: descriptive coverage@95 Δ | 0.000 [0.000, 0.230]† |
| posture | upright_stationary: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | NLL (known) Δ | 0.177 [0.002, 0.353]† ** |
| locomotion | AURC (binned) Δ | -0.033 [-0.067, -0.003]† ** |
| locomotion | stationary: descriptive coverage@95 Δ | -0.035 [-0.094, 0.007]† |
| locomotion | stationary: recall at VAL-strong tau Δ (precision not gated) | -0.035 [-0.094, 0.007]† |
| locomotion | walking: descriptive coverage@95 Δ | 0.000 [0.000, 0.425]† |
| locomotion | walking: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| locomotion | running: descriptive coverage@95 Δ | 0.000 [0.000, 0.972]† |
| locomotion | running: recall at VAL-strong tau Δ (precision not gated) | 0.962 [0.948, 0.972]† ** |
| locomotion | stairs: descriptive coverage@95 Δ | 0.000 [0.000, 0.000]† |
| locomotion | stairs: recall at VAL-strong tau Δ (precision not gated) | 0.000 [0.000, 0.000]† |
| display | label flips per hour Δ | -2.30 [-4.55, 0.00]† |

### capture24: TEST — not run

## Appendix C — pre-audit run (superseded)

The pre-audit tables (bundle `f61007169e3d`, xctest `5b10b94c86d0`, ρ default 0.5, unledgered) are in this file's version at commit `1802a012` and in `research/inertia-replay/runs/{baseline,shadow-primary-hc,shadow-primary-art}/`; §6 lists every number that changed.
