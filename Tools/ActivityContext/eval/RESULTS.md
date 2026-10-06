# ActivityContext — WISDM-19 watch HART adaptation: held-out results

> **2026-10-06:** the v0 numbers below were measured on training-path windows
> that had all-zero gyro for 83 % of windows and 2.5×-stretched 50 Hz subjects.
> See [hart-wisdm-v1](#hart-wisdm-v1-training-data-fix-and-re-evaluation-2026-10-06)
> at the end for the bug, the fix, the retrained model and a v0-vs-v1 comparison
> on correctly built windows. The v0 section is kept unchanged.

Aggregate metrics + counts only (no raw data, no weights in git). Full JSON
reports and the fine-tuned checkpoint live in scratch
(`nara-activity-research/scratch/activity-train/`), never in the repo.

- Model: `hart-wisdm-v0`, HART `TSPulseForClassification` @122b4a8, backbone
  frozen + trainable time/fft encodings + 18-letter head (WISDM letters A–S).
- Data: WISDM Smartphone and Smartwatch Activity and Biometrics Dataset
  (UCI 507, DOI 10.24432/C5HK59), WATCH streams only, CC BY 4.0.
  Archive sha256 `6e0147f181d8f5275918db65eeb9dc842a0185d37cb6b2f30cbf74ee6e205469`.
- Units: accel m/s² → g (÷9.80665), gyro rad/s → deg/s (×180/π); recorded in
  the manifest, never applied at inference (C10). 20 Hz → 30 Hz by anti-alias
  polyphase 3/2 upsampling (bandwidth preserved).
- Split: subjects shuffled with fixed seed 42 → disjoint train 35 / val 8 /
  test 8 subjects, 632 / 159 / 144 sessions. Windowing AFTER the split:
  120 samples @ 30 Hz, hop 60 (2 s), 4 s windows. Scaler fit on train subjects
  only (sha256 `75fccb4e34c0dead58503f2f4efaa1d8d8ac11cf115514a420a5bb27b42517f1`).
- Fine-tuned model.safetensors sha256 `39dc12e0de8353dd5bb08475bf9042c5594603b7e15ae1b65b581cdbb0b93b2f`.
- Training: 9 epochs run, early stop at epoch 9 on val macro-F1 (patience 2),
  best epoch 7 (val macro-F1 0.6334). frozen 123,679 / trainable 34,969 params,
  AdamW lr 1e-3, batch 128, seed 42.
- Abstention: max_prob ≥ 0.80 AND top-2 margin ≥ 0.15 (manifest thresholds).

## Held-out TEST subjects (8 subjects, 15,363 windows, 144 sessions)

| metric | value |
|---|---|
| accepted windows (post-abstention) | 10,205 |
| acceptance coverage | 0.664 |
| macro-F1 (supported classes) | 0.660 |
| prediction counts | unknown 5,158 · other_movement 6,607 · stationary 2,602 · running 605 · walking 391 |

### Per-class P/R/F1 (accepted predictions)

| class | count | precision | recall | F1 |
|---|---|---|---|---|
| stationary | 5,070 | 0.860 | 0.441 | 0.583 |
| walking | 889 | 0.890 | 0.392 | 0.544 |
| running | 845 | 0.997 | 0.714 | 0.832 |
| other_movement | 8,559 | 0.782 | 0.604 | 0.682 |
| unknown | — | — | — | — |

### Confusion matrix (rows = truth, cols = prediction)

| truth \ pred | stationary | walking | running | other_movement | unknown |
|---|---|---|---|---|---|
| stationary | 2,238 | 0 | 0 | 1,298 | 1,534 |
| walking | 0 | 348 | 0 | 125 | 416 |
| running | 0 | 0 | 603 | 16 | 226 |
| other_movement | 364 | 43 | 2 | 5,168 | 2,982 |

### Transition delay (s to first accepted correct prediction after a truth change; 47 transitions)

| variant | mean | median | p90 |
|---|---|---|---|
| raw per-window | 155.3 | 2.0 | 56.8 |
| policy (causal vote, 2 consecutive, gap reset 4 s) | 194.2 | 2.0 | 59.6 |

### Per-subject coverage (all 18 sessions each)

| subject | windows | accepted | coverage |
|---|---|---|---|
| 1605 | 1,635 | 1,352 | 0.827 |
| 1607 | 1,626 | 1,069 | 0.657 |
| 1617 | 1,654 | 1,251 | 0.756 |
| 1627 | 1,602 | 1,306 | 0.815 |
| 1638 | 3,996 | 1,550 | 0.388 |
| 1646 | 1,602 | 1,201 | 0.750 |
| 1648 | 1,602 | 1,210 | 0.755 |
| 1650 | 1,646 | 1,266 | 0.769 |

## Negative control: typing / writing (C10 disagreement cases, spec §12)

| letter | activity | windows | →stationary | →other | abstained | mean max-prob |
|---|---|---|---|---|---|---|
| F | typing | 845 | 713 (84%) | 5 | 127 (15%) | 0.909 |
| Q | writing | 845 | 482 (57%) | 107 | 256 (30%) | 0.853 |

Typing/writing are admitted as `stationary` with high confidence: the wrist is
mostly still, so a wrist-only model cannot distinguish them from rest. This is
the documented C10 disagreement — the abstention does NOT reject them, and the
stationary label must never be treated as physiologically restful evidence
(spec §8). Also observed: clapping (R) → stationary 332 / other_movement 251 /
unknown 262; folding (S) → other_movement 531 / stationary 106 / unknown 208 —
the model disagrees with the C10 stationary mapping for these two, a
documented disagreement to review before any posture/resting use.

## Baseline comparison (same held-out windows, conservative heuristic)

| metric | HART | baseline |
|---|---|---|
| coverage | 0.664 | 0.857 |
| macro-F1 (supported) | 0.660 | 0.365 |
| accepted windows | 10,205 | 13,165 |

The baseline accepts far more windows (its one-hot scores always pass the
0.80/0.15 thresholds) but is much less accurate: HART trades coverage for
precision, and its accepted-prediction precision (0.78–1.00 per class) beats
the heuristic across the board.

## Commands (run from `Tools/ActivityContext`, venv = scratch, NOT the repo)

```bash
# venv (scratch only): uv venv --python 3.10 .venv && uv pip install -e ".[dev,model]"
# fetch pinned HART checkpoint (digest-verified):
./fetch_artifacts.sh --checkpoint-dir ./checkpoint
# unpack WISDM (scratch): outer zip 6e0147f1... -> wisdm-dataset.zip 1cf32e8d... -> wisdm-dataset/

# train (subject-held-out 70/15/15, early stop on val macro-F1):
ACTIVITY_TRAIN_THREADS=8 .venv/bin/python -m activity_context.train \
    --wisdm <scratch>/wisdm-dataset --checkpoint ./checkpoint --train \
    --out <scratch>/activity-train/out --epochs 10 --batch-size 128 \
    --lr 1e-3 --seed 42 --test-fraction 0.15 --val-fraction 0.15

# evaluate held-out test subjects (HART):
.venv/bin/python -m activity_context.evaluate \
    --manifest <scratch>/activity-train/out/manifest.json \
    --data <scratch>/activity-train/out/eval_data.npz \
    --checkpoint <scratch>/activity-train/out

# serve smoke with the trained model (ping + golden infer):
.venv/bin/python -m activity_context.serve \
    --manifest <scratch>/activity-train/out/manifest.json \
    --checkpoint <scratch>/activity-train/out
# then send {"id":"p","op":"ping"} and the golden walk run JSON (see scratch/activity-train/serve_golden_walk.json)
```

## Release status

WISDM held-out macro-F1 0.66 and walking precision 0.89 are BELOW the spec §12
promotion targets (≥0.85 macro-F1, ≥0.90 walking/running precision on held-out
sessions). The feature stays in shadow mode; these are honest public-data
results, NOT WHOOP-session or real-device evidence. No weights are committed.

---

## hart-wisdm-v1: training-data fix and re-evaluation (2026-10-06)

Agent HF, branch `feat/hart-train-fix-20261006`. Aggregate metrics only; the
artifact, windows and full JSON reports live outside git in
`research/hart-v1/` (`eval_v0_v1.json`, `eval_v0_v1_summary.json`).

### What was wrong with v0's training data (`b578b166`)

| # | where | bug | effect |
|---|---|---|---|
| 1 | `train.py:121-125` `_finish_block` | `np.searchsorted` of each accel timestamp into the subject's WHOLE gyro timestamp array, which is not sorted (WISDM timestamps jump at each activity change); unmatched samples set to 0 | 82.3 % of train, 82.7 % of val and 82.9 % of eval windows had all-zero gyro. v0 learned a mostly accel-only model, and its scaler's gyro std (22–30 deg/s) was fitted on zeros. |
| 2 | `train.py:52` `WISDM_HZ = 20`, `:133` always `resample_poly_nd(…, 3, 2)` | every block assumed 20 Hz | subjects 1637–1640 (~49.7 Hz accel / ~24.8 Hz gyro, 70 recordings) were time-stretched 2.5×: test subject 1638 had 3,996 windows instead of ~1,390, and its walking cadence was 0.75 Hz instead of 1.75 Hz. 13 more recordings switch between 20 Hz and ~100 Hz mid-block (e.g. 1605-I, 1617-P). A few others have short 100 Hz bursts between 0.3 s gaps (e.g. 1608-J, 1650-A). |
| 3 | `train.py:96` blocks in file order | subject 1629's files hold the whole session twice | 18 duplicated val blocks (v0: 159 val sessions; 141 real) |
| 4 | `train.py:382` → `model.py:144/197` | torch seeded only after `from_pretrained` had drawn the new head | v0's head initialization, so the run, was not reproducible |
| 5 | `train.py:144` `window_block` | windows from sample 0 to the block end, with no FIR-transient margin | train/serve skew: serve drops windows within 1 s of a run edge |
| 6 | `evaluate.py:227` `_transition_delay` | the search for the first correct window does not stop at the next truth change | one unrecovered transition can count minutes of later recordings. A censored variant was added; on the fixed windows no transition is missed, so both agree. |
| 7 | `tests/test_model.py:31-82` | the fixture manifest pins the pretrained digest `88b8d179…` | errors on a fine-tuned checkpoint dir; the corrupt-checkpoint test passed for the wrong reason (digest pin, not tampering) |
| 8 | `train.py:570`, `:308` | `os.makedirs(out)` ran only with `--checkpoint`; the smoke generator advanced timestamps by `dur*step_ns` (0.6 s, not 12 s) | minor |

The same check of agent R's replay loader (`inertia/replay_data.py:387`, one
nominal rate per block from the median interval) shows the mixed 20/100 Hz
blocks are time-scaled there too: 371 of 12,493 test windows (1605-I,
1607-L, 1617-P) and 182 of 13,775 val windows. This is left as is, and
documented in the module, so existing replay outputs stay comparable.
`inertia/datasets/wisdm.py` (accel only) drops most mixed blocks because its
5 % rate check fails on them. It keeps 1628-E as "50 Hz" because that block's
mean rate is 50.6 Hz.

### The fix: `activity_context/wisdm.py` (`wisdm-watch-loader-2`)

Per (subject, activity) sensor stream, sorted by timestamp. Exact duplicate
rows are collapsed (64,904 accel rows, all from 1629); conflicting duplicates
are dropped (none). Recordings split at gaps > 1 s. Constant-rate segments:
the rolling-median nominal rate (20/25/50/100 Hz); a segment breaks at a rate
change or at an interval < 0.5 or > 2.5 periods. One missing sample is
repaired by linear interpolation of its neighbours (255 accel / 118 gyro);
nothing is ever set to zero. A least-squares clock is fitted per segment.
Each stream is resampled from its **measured** rate with the repo polyphase
design (`resample_poly_direct`, which equals `resample_poly_nd` to 1e-15).
`up/down` is the simplest fraction of 30/rate whose accumulated error over the
piece is ≤ 2 ms (max 1.997 ms). The gyro ratio is derived from the accel ratio
on the shared clock: WISDM's gyro instants equal the accel's at 20/100 Hz and
are every other accel instant at 50/25 Hz. The gyro is located on the accel
sample index through the timestamps; pieces split at sustained (≥ 2 s)
one-sample slips (1 in the archive). Transient gyro-timestamp excursions of
one accel sample (≤ 20.2 ms, watches 1638–1640) are tolerated and recorded.
The constant accel/gyro offset is ≤ 0.06 ms. Windows follow serve.py exactly.
Recordings without gyro are excluded and listed in `data_report.json`:
1637-C, 1638-H, 1638-O, 1640-C, 1640-E. The split universe is the 51
subjects with both files, and `--expect-split` asserted equality with v0's
`split_manifest.json`. That gives the same seed-42 train 35 / val 8 / test 8
subjects; sessions are 627 / 140 / 142.

| windows | train | val | test | all-zero gyro |
|---|---|---|---|---|
| v0 loader | 59,113 | 18,888 | 15,363 | 82–83 % |
| v1 loader | 53,998 | 12,096 | 12,270 | 0 |

Tests: `tests/test_wisdm.py` (21) builds synthetic WISDM files with backwards
timestamp jumps between activities, a gyro file in another order, a 50/25 Hz
block, a 20→100 Hz switch, a block without gyro, a > 1 s gap, a 300 ms
dropout, one dropped sample and duplicate rows. It shows v0's merge
zero-fills whole activities on them, and that every 30 Hz output sample of
the new loader matches the analytic signal at its own timestamp, gyro
included. `tests/test_evaluate_metrics.py` (9) covers calibration,
temperature and the censored delay. `tests/test_model.py` now reads the
checkpoint dir's own manifest.

### Training (same recipe as v0)

Pretrained HART @122b4a8 (`88b8d179…`). Backbone frozen; time/fft encodings
and the 18-letter head trainable (frozen 123,679 / trainable 34,969 params).
AdamW lr 1e-3, batch 128, seed 42, at most 10 epochs, early stop on
subject-held-out val macro-F1 with patience 2. Scaler fit on train-subject
windows only (sha256 `f5b13d1f…`). CPU only, 6 threads on a shared machine.
The run is deterministic: a first attempt, killed after epoch 1, logged
identical losses, and a 2×30-batch probe gave identical weights.

| epoch | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| train loss | 1.591 | 1.066 | 0.993 | 0.954 | 0.930 | 0.909 | 0.897 | 0.882 | 0.871 | 0.860 |
| val macro-F1 | 0.670 | 0.701 | 0.737 | 0.744 | 0.751 | 0.751 | 0.758 | 0.760 | 0.764 | **0.767** |
| seconds | 206 | 146 | 159 | 161 | 164 | 176 | 276 | 258 | 404 | 454 |

Early stopping never triggered: the 10-epoch cap ended training (v0's
recipe), with val macro-F1 still rising by about 0.003 per epoch. Best epoch
is 10. The run took 40 min wall time.
`model.safetensors` sha256 `2414949634e5649b86cf2ec098f0f144507d0573e63b40e1017f19c796c9fdda`
(657,184 B).

### Held-out TEST subjects, evaluated once (1605, 1607, 1617, 1627, 1638, 1646, 1648, 1650)

The same v0 artifact (`39dc12e0…`) and v1 artifact, under the manifest
abstention (max_prob ≥ 0.80, margin ≥ 0.15).

- **(i) RESULTS.md protocol:** the training-path windows, now built
  correctly (v1 `eval_data.npz`, 12,270 windows).
- **(ii) production-faithful protocol:** agent R's per-block stream, serve
  windowing, `HARTModel` and the manifest (12,493 windows; 172 windows without
  gyro skipped). The driver reproduces R's v0 outputs exactly: label
  agreement 1.0 and a max probability difference of 0.

| | (i) v0 | (i) v1 | (ii) v0 | (ii) v1 |
|---|---|---|---|---|
| coverage | 0.557 | **0.713** | 0.547 | **0.709** |
| accepted precision | 0.877 | **0.905** | 0.874 | **0.895** |
| macro-F1 (4 supported) | 0.708 | **0.796** | 0.701 | **0.777** |
| accepted windows | 6,832 | 8,753 | 6,829 | 8,852 |

For reference, v0's original report on its own zero-gyro windows was coverage
0.664 and macro-F1 0.660 (above). On correct windows v0 scores 0.557 and
0.708.

Per-class precision / recall / F1 over accepted predictions:

| class (count i / ii) | (i) v0 | (i) v1 | (ii) v0 | (ii) v1 |
|---|---|---|---|---|
| stationary (4,159 / 4,171) | 0.855 / 0.587 / 0.696 | 0.929 / 0.554 / 0.694 | 0.859 / 0.566 / 0.682 | 0.919 / 0.530 / 0.672 |
| walking (675 / 739) | 0.891 / 0.547 / 0.678 | 0.866 / 0.692 / 0.769 | 0.907 / 0.529 / 0.668 | 0.845 / 0.636 / 0.726 |
| running (693 / 695) | 0.936 / 0.924 / 0.930 | 0.997 / 0.921 / 0.957 | 0.936 / 0.922 / 0.929 | 0.998 / 0.911 / 0.953 |
| other_movement (6,743 / 6,888) | 0.883 / 0.377 / 0.529 | 0.886 / 0.669 / 0.762 | 0.869 / 0.374 / 0.523 | 0.877 / 0.669 / 0.759 |

Confusion matrices. Rows are truth; columns are predictions in the order
stationary / walking / running / other / unknown.

| truth | (i) v0 | (i) v1 | (ii) v0 | (ii) v1 |
|---|---|---|---|---|
| stationary | 2440 / 0 / 1 / 329 / 1389 | 2305 / 0 / 0 / 558 / 1296 | 2361 / 0 / 0 / 372 / 1438 | 2209 / 0 / 0 / 573 / 1389 |
| walking | 18 / 369 / 0 / 5 / 283 | 14 / 467 / 1 / 17 / 176 | 17 / 391 / 0 / 12 / 319 | 19 / 470 / 1 / 67 / 182 |
| running | 4 / 0 / 640 / 2 / 47 | 0 / 0 / 638 / 7 / 48 | 5 / 0 / 641 / 4 / 45 | 0 / 0 / 633 / 7 / 55 |
| other_movement | 391 / 45 / 43 / 2545 / 3719 | 162 / 72 / 1 / 4511 / 1997 | 367 / 40 / 44 / 2575 / 3862 | 177 / 86 / 0 / 4610 / 2015 |

Transition delay (47 truth changes, all recovered; censored and uncensored
agree), in seconds as mean / median / p90:

| | (i) v0 | (i) v1 | (ii) v0 | (ii) v1 |
|---|---|---|---|---|
| raw per-window | 10.3 / 2.0 / 27.2 | 17.7 / 2.0 / 39.2 | 14.7 / 2.0 / 34.4 | 18.9 / 2.0 / 39.2 |
| policy (2 votes, 4 s reset) | 14.9 / 2.0 / 32.8 | 20.9 / 2.0 / 63.6 | 19.9 / 2.0 / 60.4 | 23.5 / 2.0 / 78.0 |

These transitions are joins between separate WISDM recordings, ordered by
activity letter, so this metric is weak here. v1's longer mean delay comes
from a few blocks it is slow to accept. The median is unchanged.

Per-subject coverage, protocol (i), v0 → v1: 1605 0.651 → 0.839 · 1607
0.443 → 0.628 · 1617 0.561 → 0.789 · 1627 0.624 → 0.835 · **1638 0.434 →
0.313** · 1646 0.550 → 0.793 · 1648 0.515 → 0.623 · 1650 0.663 → 0.845.

By native rate, protocol (ii), as coverage / accepted precision / macro-F1:

| watch group | v0 | v1 |
|---|---|---|
| 20 Hz watches (11,117 windows) | 0.561 / 0.896 / 0.712 | 0.759 / 0.912 / 0.807 |
| ~50 Hz watches (1638, 1,376 windows) | 0.430 / 0.637 / 0.586 | 0.305 / 0.559 / 0.447 |

v1 improves every 20 Hz-watch subject but is worse on the one ~50 Hz test
subject, and both models are poor there. VAL-only diagnostics on 1637/1639
(the other ~50 Hz watches) give accepted accuracy of 0.54 for v1 and 0.51 for
v0:

- Band-limiting those streams to 10 Hz barely helps (0.54 → 0.55).
- Rotating accel and gyro 90° about z raises v1 to 0.68.

During walking, the 20 Hz watches carry gravity on ±x and the ~50 Hz watches
on −y. These four subjects used a watch with a different sensor frame, and
only 1640 is in the training split. This is a device-domain shift, not a
loader bug: R's independent stream code shows the same drop. With real gyro,
v1 depends more on the sensor frame than v0 did. Files:
`research/hart-v1/diag_50hz_val.json` and
`diag_rotation_val_1637_1639.json`.

Validation split, protocol (ii): v0 0.615 / 0.800 / 0.671 → v1 0.732 /
0.863 / 0.763 (coverage / precision / macro-F1).

Negative control (protocol i, windows → stationary / unknown / other):

| letter | v0 | v1 |
|---|---|---|
| F typing (696) | 594 / 100 / 2 | 523 / 168 / 5 |
| Q writing (696) | 457 / 210 / 29 | 458 / 147 / 91 |
| R clapping (688) | 359 / 234 / 95 | 430 / 188 / 70 |
| S folding (696) | 383 / 270 / 42 (+1 running) | 292 / 298 / 106 |

Typing and writing are still admitted as `stationary` with high confidence.
The C10 disagreement stands for v1, as it does for v0.

### Calibration of the raw softmax

The Swift adapter treats HART's raw softmax as calibrated. These are its
window probabilities aggregated to the 4 supported classes, with top-label
ECE over 15 bins.

| | (i) v0 | (i) v1 | (ii) v0 | (ii) v1 |
|---|---|---|---|---|
| TEST NLL | 0.570 | 0.430 | 0.595 | 0.450 |
| TEST Brier | 0.349 | 0.261 | 0.357 | 0.271 |
| TEST ECE | 0.061 | 0.047 | 0.061 | 0.050 |
| TEST top-1 accuracy / mean confidence | 0.739 / 0.791 | 0.816 / 0.859 | 0.736 / 0.786 | 0.808 / 0.856 |
| VAL ECE (raw → VAL-fit T) | 0.112 → 0.043 | 0.079 → 0.023 | 0.111 → 0.055 | 0.078 → 0.013 |
| VAL-fit temperature T | 1.89 | 1.56 | 1.96 | 1.57 |
| TEST with T: NLL / Brier / ECE | 0.553 / 0.327 / **0.116** | 0.426 / 0.254 / 0.035 | 0.575 / 0.338 / **0.128** | 0.441 / 0.264 / 0.035 |
| TEST with T at 0.80/0.15: coverage / precision / macro-F1 | 0.250 / 0.960 / 0.396 | 0.538 / 0.940 / 0.661 | 0.218 / 0.950 / 0.355 | 0.523 / 0.934 / 0.639 |

Both models are overconfident: mean confidence exceeds accuracy by about
0.05, and on VAL by 0.08–0.11 ECE. A temperature fitted on VAL (T ≈ 1.56)
improves v1's TEST NLL, Brier and ECE (0.047 → 0.035). For v0 it
over-corrects on TEST (ECE 0.061 → 0.116), because v0's VAL miscalibration
did not transfer.

Temperature scaling is NOT a drop-in change. The 0.80 / 0.15 abstention
thresholds were set on raw probabilities: applying T cuts v1's coverage from
0.71 to 0.54, with precision 0.94. Calibrating HART needs a threshold choice
made on VAL at the same time. This is reported only; serve is unchanged.

### Replay outputs for the system comparison

`research/inertia-replay/hart_v1_wisdm_{val,test}.{npz,json}` hold v1's
protocol (ii) per-window outputs. They have exactly the keys, dtypes, block
list, window grid (`block_id`, `s`, `e`) and imu-feat-1 features of R's
`hart_wisdm_{val,test}.*`, so a later comparison can swap HART v0 for v1.
Only `label` and `probs` differ, with 65 % and 67 % label agreement with v0.

### Status

v1 is a new, opt-in artifact. Nothing that production loads by default
changed: fetch_artifacts pins, the default manifest and worker configuration
are untouched. On correct windows v1 beats v0 under both protocols, by
+0.09 / +0.08 macro-F1 and +0.16 coverage at higher accepted precision. It is
still below the spec §12 promotion targets: macro-F1 0.80 / 0.78 against
≥ 0.85, and walking precision 0.87 / 0.85 against ≥ 0.90. It is also worse
than v0 on the ~50 Hz watch subject. These are public-data results, not
WHOOP-session evidence.

### Commands (from `Tools/ActivityContext`, venv `research/hart-venv`)

```bash
ACTIVITY_TRAIN_THREADS=6 python -m activity_context.train \
    --wisdm <wisdm-dataset> --checkpoint <pretrained 88b8d179 dir> --train \
    --out research/hart-v1 --epochs 10 --batch-size 128 --lr 1e-3 --seed 42 \
    --test-fraction 0.15 --val-fraction 0.15 --patience 2 \
    --expect-split <activity-train/out/split_manifest.json> --jobs 4
OMP_NUM_THREADS=1 python -m activity_context.hart_wisdm_eval \
    --model v0=<v0 dir>/manifest.json,<v0 dir> --model v1=research/hart-v1/manifest.json,research/hart-v1 \
    --eval-data research/hart-v1/eval_data.npz --val-data research/hart-v1/val_data.npz \
    --wisdm <wisdm-dataset> --replay-out research/inertia-replay --replay-prefix v1=hart_v1_wisdm \
    --reference v0=research/inertia-replay/hart_wisdm_test.npz \
    --out research/hart-v1/eval_v0_v1.json --jobs 7
```
