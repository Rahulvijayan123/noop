# Tools/ActivityContext — Nara offline activity-context pipeline

Pure-offline Python package for the Nara activity lane (spec-14 §6–§8, C7/C10):

- **decode** WHOOP 5/MG 1244-byte raw-IMU frames and NPB1 `rawImuSession`
  columns (600 i16 axis-major per second) → float tensors in canonical units
  (g, deg/s), gravity preserved.
- **resample** 100 → 30 Hz with a numpy-only anti-alias polyphase FIR (ratio
  3/10; reproduces `scipy.signal.resample_poly(x, 3, 10)` to ~1e-16 — same
  algorithm HART's `data_preprocessing/Resampling.py` uses, no scipy dep).
- **window** 4 s (120 @ 30 Hz) with a 2 s hop, cropping filter transients;
  gaps/clock resets split runs and never manufacture windows.
- **classify** per window with either the conservative heuristic **baseline**
  (spec §7, numpy-only) or the **HART** adapter (`TSPulseForClassification`,
  optional torch/granite-tsfm import) with strict verify-on-load.
- **serve** a persistent process speaking the C10 line-delimited-JSON protocol
  (`ping` / `infer` / `shutdown`), plus `infer` / `train` / `evaluate` CLIs.

## Layout

```
pyproject.toml          pinned deps; [model] extra for torch/granite-tsfm
fetch_artifacts.sh      fetch + sha256-verify the pinned HART checkpoint
activity_context/
  preprocess.py         decode, polyphase resampler, runs, windows
  baseline.py           conservative heuristic classifier (operational baseline)
  model.py              HART adapter (lazy import), verify-on-load, freeze policy
  manifest.py           model manifest load/validate
  serve.py              persistent C10 protocol process
  infer.py / train.py / evaluate.py   CLI entry points
  fetch_artifacts.py    pinned URLs + digests for checkpoint / WISDM archive
tests/                  golden, serve-protocol, fault, manifest, model tests
fixtures/               small committed golden fixtures + manifest examples
```

## Quick start

```bash
cd Tools/ActivityContext
uv venv --python 3.10 .venv
uv pip install --python .venv/bin/python -e ".[dev]"          # numpy + pytest only
# optional HART path:
uv pip install --python .venv/bin/python -e ".[model]"        # torch 2.8.0 CPU, transformers 4.56.0, granite-tsfm 0.3.3
./fetch_artifacts.sh --checkpoint-dir ./checkpoint            # pinned HART checkpoint (digest-verified)
```

`fetch_artifacts.sh` also downloads the WISDM-19 archive for training:
`./fetch_artifacts.sh --checkpoint-dir ./checkpoint --wisdm /tmp/wisdm.zip`.

## Tests

```bash
.venv/bin/python -m pytest tests          # 54 tests; HART model tests auto-skip
                                          # unless checkpoint/ is present or
                                          # ACTIVITY_HART_CHECKPOINT is set
ACTIVITY_HART_CHECKPOINT=/path/to/checkpoint .venv/bin/python -m pytest tests
```

Covered gates (spec §12): golden 1244-byte decode → expected first-sample
values; 1.8 Hz gait survives resample / 25 Hz attenuated / gravity preserved;
serve protocol happy path + malformed + bounded-payload rejection; NaN /
wrong-length / duplicate / clock-reset rejection (never a valid stationary
window); gaps never produce windows; manifest validation; real-loaded-model
determinism and corrupt-checkpoint refusal.

## Serve protocol (C10, FINAL)

Run:

```bash
.venv/bin/python -m activity_context.serve \
    --manifest manifest.json --checkpoint ./checkpoint [--timeout 60]
```

Line-delimited JSON over stdin, one response per request on stdout.

**Request**
```json
{"id":"<uuid>","op":"infer","run":{
  "start_ts":1758000000,"end_ts":1758000012,"sample_rate_hz":100,
  "channels_order":["ax","ay","az","gx","gy","gz"],
  "units":{"accel":"g","gyro":"deg/s"},
  "columns_b64":["<per-second 1200-byte i16 LE axis-major, index i = second start_ts+i>"],
  "head_b64":["<up to 3 extra seconds BEFORE start for overlap/filter state>"],
  "tail_b64":["<up to 3 extra seconds AFTER end>"]}}
```

**Response (ok)**
```json
{"id":"<uuid>","ok":true,"model_version":"...","preprocessing_version":"1.0.0",
 "windows":[{"s":1758000000.0,"e":1758000004.0,"label":"walking",
   "probs":{"walking":0.91,...},"baseline":false}],
 "manifest":{...},"duration_ms":1}
```

**Response (error)** `{"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|timeout|internal|output_too_large"}`

- Windows are 4 s (120 @ 30 Hz) with a 2 s hop, fully inside `[start_ts, end_ts]`.
- Supply ≥ 1 s of `head_b64`/`tail_b64` so the first/last windows are not
  transient-cropped (a job boundary is not a motion gap; C10).
- `baseline:true` windows come from the heuristic; their probs are NOT
  calibrated probabilities (spec §7). `label:"unknown"` means abstention
  (thresholds `max_prob` 0.80 / margin 0.15 from the manifest).
- `op:"ping"` returns versions + model status; `op:"shutdown"` exits.
- Deterministic: single thread, eval mode, no masking, fixed seed.

## Training / evaluation (later agent runs these)

```bash
# WISDM-19 watch adaptation (raw/ dir must contain raw/watch/accel+gyro):
unzip /tmp/wisdm.zip -d /tmp/wisdm && unzip /tmp/wisdm/wisdm-dataset.zip -d /tmp/wisdm
.venv/bin/python -m activity_context.train \
    --wisdm /tmp/wisdm/wisdm-dataset \
    --checkpoint ./checkpoint --train \
    --out /tmp/nara-activity-model --epochs 50 --seed 0
# CI smoke (tiny synthetic WISDM-format data, no download):
.venv/bin/python -m activity_context.train --smoke --train --checkpoint ./checkpoint --out /tmp/smoke
# Evaluate held-out subjects:
.venv/bin/python -m activity_context.evaluate \
    --manifest /tmp/smoke/manifest.json --data /tmp/smoke/eval_data.npz \
    --checkpoint /tmp/smoke
```

`evaluate` reports per-class P/R/F1 + macro-F1 over the supported coarse
classes, confusion matrix, acceptance coverage (0.80 / 0.15 abstention),
raw AND policy-smoothed transition delay (causal vote, 2 consecutive
disagreeing windows, 4 s gap reset — the Swift `ActivityPolicyConfig`
constants), plus per-subject (held-out test) and per-WISDM-letter breakdowns
(the C10 disagreement cases F typing / Q writing / R clapping / S folding are
reported per letter for the spec §12 negative-control inspection).

`train` does a SUBJECT-HELD-OUT 3-way split BEFORE windowing (spec §7;
upstream's windowed `random_split` is not used): subjects are shuffled with a
fixed seed into disjoint train (~70%) / val (~15%) / test (~15%) groups, so
sessions never straddle splits and the early-stop val set is subject-held-out.
It fits the StandardScaler on train windows only, converts WISDM units to the
canonical contract (m/s² → g, rad/s → deg/s, recorded in the manifest),
applies the C10 letter→ontology label map, and writes `manifest.json` (with
embedded `split` subject manifest + `data` training-data identifiers),
`split_manifest.json`, `train/val/eval_data.npz` and (with `--train`) the
fine-tuned `model.safetensors` + `config.json`.

`--train` fine-tunes the classification head with the backbone frozen and the
time/fft input encodings + head trainable (upstream finetune.py:121-130),
with **early stopping on subject-held-out val macro-F1** (patience 2, bounded
by `--epochs`) and restores the best epoch before saving. Training uses
`ACTIVITY_TRAIN_THREADS` (default 4) CPU threads; inference/serve stay
single-threaded and deterministic.

## Artifact policy

- **No weights in git.** The checkpoint (856,744 B) and the WISDM archive
  (310 MB) are download-time artifacts fetched by `fetch_artifacts.sh` with
  pinned sha256 digests; the model manifest pins the same digests.
- The fine-tuned model is written to the training output dir, never committed.
- Fixtures committed here are small synthetic/golden tensors only.
- `checkpoint/`, `.venv/`, `__pycache__/`, `*.part` are gitignored (see
  `.gitignore` in this directory).

## Licenses / attribution

- **HART** (EdgeIntelligenceLab/HART) — MIT, pinned commit
  `122b4a8b07758deedfcf3b1e87f03eed5ad55967`. The pretrained checkpoint is a
  repo artifact (no HF repo). Used under MIT; see upstream LICENSE.
- **WISDM Smartphone and Smartwatch Activity and Biometrics Dataset**
  (Weiss, G., 2019, UCI id 507, DOI 10.24432/C5HK59) — CC BY 4.0. Derived
  windows/metrics may be shared with attribution; the raw archive is not
  redistributed.
- The package's own code is part of NOOP, licensed under the repo's PolyForm
  Noncommercial 1.0.0 (see repo LICENSE). granite-tsfm / torch / transformers
  keep their own licenses (Apache-2.0 / BSD-style) and are runtime-only deps.

## Notes / known limits

- The serve input is canonical WHOOP units (g, deg/s) only; anything else is
  rejected (`malformed`) rather than silently converted — unit conversion is
  recorded in the model manifest, never applied at inference.
- The baseline classifier is deliberately conservative and NOT calibrated;
  it is the end-to-end wiring + comparison point. The HART head is random
  until `--train` runs on real WISDM data, so pre-training predictions
  abstain (honest `unknown`).
- Temporal voting/hysteresis lives on the Swift side (ActivityContextPolicy);
  Python is a pure per-window classifier.

## Ground-truth label evaluation (spec 10/13)

The harness compares the HART / heuristic / ActivityContext heads against
guided calibration labels on **leakage-free session-held-out splits**.

### Inputs

- **Ground-truth labels** (`--labels`): a `.jsonl` file (one wire
  `activity_ground_truth_labels` object per line, snake_case fields per
  spec 8.1) or a `.json` array. Malformed lines and degenerate intervals
  are skipped and counted in the load report.
- **Window docs** (`--windows`, repeatable): `hart-windows-1` day documents
  (`ActivityEncoderWindowStore` / `ActivityEncoderWindows.swift`). Windows
  flagged `b=1` (heuristic baseline) are evaluated as a separate
  **baseline** model; the rest as **hart**. Both score the SAME labeled
  windows.
- **ActivityContext day docs** (`--context-days`, optional): a JSON array
  of `activity_context_days` documents (`runs` with per-head probability
  dicts). Reported as a third **activity_context** model.

### Semantics

- **Strong vs weak never mixed.** Default evaluation uses guided, confident
  labels only. `--include-weak` adds stretch-feedback / imported / unsure
  labels to a clearly-labelled combined view, with strong and weak counted
  separately.
- **Gaps never make a label valid.** A label whose `sensor_quality` has ANY
  gap or `covered_seconds < expected_seconds` is `evaluation_ready=False`
  and excluded by default (`--include-degraded` includes it with a warning
  count). Missing `sensor_quality` is also not evaluation-ready.
- **Window/label join**: a 4 s window joins a label when >= 50% of the
  window lies inside the label interval and the label sets that head; each
  window is claimed by at most one label (split integrity).
- **Abstention is a decision, not a class**: `unknown` window labels abstain
  every head; per-class P/R/F1, Brier and ECE-15 are scored on accepted
  windows, with abstention rate and accepted coverage reported alongside.
- **Splits** are by SESSION (guided `session_id`, or label_key prefix for
  weak), never by window: sessions ordered by earliest label start, with
  the last `--holdout-sessions` (default 1) held out, `--split alternate`,
  or `--split chronological --chronological-ts <unix>` (sessions starting at
  or after the timestamp are test).

### Metrics (spec 10.3)

Per model × head × split: per-class P/R/F1, macro-F1, balanced accuracy,
confusion matrix, abstention rate, accepted coverage, duration-weighted
accuracy, segment-F1 (Ward et al. run matching), Brier + ECE-15 (per head,
accepted windows), per-session macro-F1 with pooled vs session-macro both
reported, and a transitions block (F1@τ for τ ∈ {2,5,10}, median/p90 timing
error, signed bias, false events/hour over monitored duration).

### CLI

```bash
.venv/bin/python -m activity_context.evaluate_labels \
    --labels labels.jsonl \
    --windows day1.json --windows day2.json \
    [--context-days ctx_days.json] \
    --out-dir out [--report report.md] [--json] \
    [--holdout-sessions 1] [--split holdout|alternate|chronological] \
    [--chronological-ts <unix>] [--tau 5] \
    [--include-weak] [--include-degraded]
```

Writes `out/report.md` (human) and, with `--json`, `out/report.json`
(machine).

### Shadow personalization (spec 11, NO production wiring)

```bash
.venv/bin/python -m activity_context.personalize \
    --labels labels.jsonl --windows day1.json --out out
```

Pure numpy, deterministic (seed 42). Per user (grouped by `user_id` when
present, else one subject): session-held-out split; evidence gates (>= 30
windows AND >= 3 distinct sessions per class in the fit split, else
`insufficient_evidence` with the failed classes listed); then a closed-form
ridge one-vs-rest logistic probe on `imu-feat-1` features + temperature
calibration + abstention-threshold tuning. Reports generic-vs-personalized
per-class F1 delta on the held-out sessions. Nothing here touches serve.py
or the Swift side.
