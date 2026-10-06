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

## Inertia-1 motion heads (optional, separate process)

`activity_context/inertia/` adds a second, independent lane: accel-only `inertia-prep-1`
preprocessing (100 → 20 Hz, 30 s / 10 s windows), a narrowly vendored Inertia-1 encoder (ART /
PatchTST, verify-on-load), numpy-only calibrated heads (posture, locomotion, arm behaviour, multi-label
transitions, movement intensity) with OOD scores, and its own serve process
(`python -m activity_context.inertia.serve`, wire schema `motion-heads-1`). It never runs inside the
HART serve process and its failures never touch it. **The contract is
[`INERTIA1.md`](INERTIA1.md)** — formats, versions, failure kinds, worker/decoder rules.

No official pretrained Inertia-1 checkpoint is publicly available, so nothing here claims Inertia-1
results: the encoder runs only against an explicit, sha256-pinned `--checkpoint` /
`$INERTIA1_CKPT_PATH`, and the stand-ins (`standin:*`) run only with `--allow-standin-shadow`.

```bash
uv pip install --python .venv/bin/python -e ".[dev,inertia]"      # + ".[inertia-train]" for training
.venv/bin/python -m pytest tests/inertia                           # skips cleanly without the extras
.venv/bin/python -m activity_context.inertia.make_golden --check   # golden fixtures (fixtures/inertia)
.venv/bin/python -m activity_context.inertia.bench                 # eval/inertia/perf.json
```

The offline training pipeline (`pipeline_cli windows | embed | train | evaluate | summary`) finds its data
through environment variables only (`INERTIA_DATA_ROOT`, or `INERTIA_CACHE_DIR` / `INERTIA_BUNDLES_DIR` /
`INERTIA_HAR_ROOT` / `WISDM_DIR`; see `activity_context/inertia/paths.py`). `train` refuses a dirty source
tree (anything uncommitted under `Tools/ActivityContext`) unless `--allow-dirty` (bundle capped at tier
`offline`); `evaluate` opens the test split once and seals
the gate into the bundle (`test_gate.json`); a re-evaluation needs `--rerun-reason <code> --rerun-detail
<text>`. Serve can pin a bundle with `--expect-bundle-sha256`.

## Licenses / attribution

- **HART** (EdgeIntelligenceLab/HART) — MIT, pinned commit
  `122b4a8b07758deedfcf3b1e87f03eed5ad55967`. The pretrained checkpoint is a
  repo artifact (no HF repo). Used under MIT; see upstream LICENSE.
- **WISDM Smartphone and Smartwatch Activity and Biometrics Dataset**
  (Weiss, G., 2019, UCI id 507, DOI 10.24432/C5HK59) — CC BY 4.0. Derived
  windows/metrics may be shared with attribution; the raw archive is not
  redistributed.
- **Inertia-1** (yang-ai-lab/Inertia-1) — MIT, pinned commit
  `afcd725314c95f4afefce118821349df7d61e7e8`; encoder code narrowly vendored under
  `activity_context/inertia/vendor/` (see NOTICE.md). No upstream weights are used or committed.
- **Inertia head datasets** (CAPTURE-24, HHAR, PAMAP2, MHEALTH, OPPORTUNITY, Daphnet; UCI HAPT / HARTH /
  HAR70+ as label-vocabulary references) — all CC BY 4.0; creators, DOIs and changes made are in NOTICE.md.
  No raw data is committed or redistributed.
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
