# ActivityContext — WISDM-19 watch HART adaptation: held-out results

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

### Transition delay (corrected 2026-10-05: within-session transitions only)

The table previously reported 47 "transitions" with mean delays of 155.3 s (raw) / 194.2 s
(policy). **Those numbers were invalid.** The original evaluator ignored session/block boundaries
and timestamps: it counted a label change at every WISDM block boundary (blocks are separated by
recording pauses) and then scanned into *later* sessions for the first matching prediction,
producing delays up to 6,288 s. Re-run with the repaired session-aware evaluator
(`activity_context/evaluate.py`, spec-18 audit) against the same held-out windows with real
per-window timestamps:

| variant | within-session transitions | detected | missed | censored |
|---|---|---|---|---|
| raw per-window | **0** | 0 | 0 | 0 |
| policy (causal vote, 2 consecutive, gap reset 4 s) | **0** | 0 | 0 | 0 |

**Zero within-session ground-truth transitions exist in the held-out WISDM watch blocks** — every
truth change happens across a block boundary (a recording gap), so the held-out WISDM data cannot
measure transition latency at all. For reference, with an explicitly stated block-local metric —
at every block boundary, the delay to the first accepted prediction matching the new block's
truth, searched only within that block — the held-out set (144 supported-truth blocks) gives
mean **6.9 s**, median 0 s (correct from the first window), p90 10 s, with 11 of 144 blocks never
locking on. Transition-delay evaluation on real within-session transitions requires continuous
labeled sessions (see docs/activity-physiology-audit/WHOOP_COLLECTION_PROTOCOL.md); concatenated
unrelated blocks must never be used to manufacture transitions.

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

| metric | HART | baseline (original 1.2–3.5 Hz band) | baseline (current imu-feat-2 band) |
|---|---|---|---|
| coverage | 0.664 | 0.857 | 0.815 |
| macro-F1 (supported) | 0.660 | 0.365 | 0.383 |
| accepted windows | 10,205 | 13,165 | 12,525 |

The baseline accepts far more windows (its one-hot scores always pass the
0.80/0.15 thresholds) but is much less accurate: HART trades coverage for
precision, and its accepted-prediction precision (0.78–1.00 per class) beats
the heuristic across the board. **2026-10-05 correction:** the original baseline
column was computed with the pre-imu-feat-2 cadence band (1.2–3.5 Hz); the
widened 0.8–3.5 Hz feature band changes the heuristic's own numbers (recomputed
on the same held-out windows with the current code: coverage 0.8153,
macro-F1 0.3829, 12,525 accepted — machine-readable:
`_audit/eval_rerun_baseline_real_timestamps.json` in the audit scratch). The
HART column is unchanged (bit-exact reproduction, see the audit report).

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
