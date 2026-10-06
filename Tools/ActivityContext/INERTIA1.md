# Inertia-1 motion heads — implementation map and contract

Status: **integration built against an explicit checkpoint path; real-model evaluation BLOCKED.**
No official pretrained Inertia-1 checkpoint is publicly downloadable (audited 2026-10-05: upstream
`yang-ai-lab/Inertia-1` @ `afcd725314c95f4afefce118821349df7d61e7e8` has no releases, tags, LFS or weight
files on any branch or fork; nothing on HuggingFace, Zenodo or Papers with Code; issue #1 "Model Weights
Availability" open and unanswered since 2026-08-03). Everything below runs against `INERTIA1_CKPT_PATH`;
stand-in encoders exercise the pipeline offline and are refused by every production path.

This file is the contract between the Python side (`activity_context/inertia/`), the worker
(`Tools/CloudWorker`) and the decoder (`Packages/StrandAnalytics`). Change it before changing either side.

## 1. Shape of the system

```
WHOOP 100 Hz raw IMU (NPB1 columns, i16, 1/4096 g)
   ├── HART path (unchanged): 100→30 Hz, accel+gyro, 4 s / 2 s hop → probs + imu-feat-1
   └── Inertia path (new, separate process): accel only → g → 10 Hz Butterworth (filtfilt) →
       resample_poly 1/5 → 20 Hz → 30 s windows (or 10 s, bundle-pinned) → frozen encoder →
       embedding → per-head standardise → linear|MLP head → calibration → supported-class probs
       + OOD score → motion-heads-1 windows
                                  │
        worker: shadow (stored, decoder untouched) │ candidate (second decode, stored, never published)
                                  ▼
        ActivityContext HSMM: Inertia enters as distinct, tempered channels (never averaged with HART)
```

Inertia is an additional expert. The HSMM keeps temporal reasoning, duration priors, unknown handling
and the final posterior. HART, the engineered features and the 1 Hz strap streams are untouched.

## 2. Versions and identifiers (pinned strings)

| name | value |
|---|---|
| preprocessing | `inertia-prep-1` |
| wire schema | `motion-heads-1` |
| encoder config schema | `nara.inertia.encoder/1` |
| head bundle schema | `nara.inertia.heads/1` |
| calibration schema | `nara.inertia.calibration/1` |
| OOD reference schema | `nara.inertia.ood/1` |
| split manifest schema | `nara-split-1` |
| label mapping schema | `nara.inertia.mappings/1` |
| upstream commit | `afcd725314c95f4afefce118821349df7d61e7e8` (MIT, "Copyright (c) 2026 The Inertia-1 Authors") |
| real encoder ids | `inertia-1/<method>-<preset>/<window>s@20hz`, e.g. `inertia-1/ar_transformer-small/30s@20hz` |
| stand-in encoder ids | must start with `standin:` (e.g. `standin:handcrafted-stats-v1`) |

`encoder_kind` is `inertia1` iff the id starts with `inertia-1/` and the checkpoint sha256 is in
`PINNED_CHECKPOINTS` (empty today). Everything else is `standin`.

## 3. Preprocessing `inertia-prep-1` (WHOOP → encoder input)

1. Accelerometer only: the first 300 i16 of each 600-i16 NPB1 second (`ax`, `ay`, `az`), × 1/4096 → g.
   Gravity kept. Axis order is the strap's raw frame; no remap, no normalisation, no clipping.
2. Runs exactly as the HART path: duplicate second → error, clock reset → error, gap > 1 s → new run.
   Never interpolate across a gap, never concatenate runs, reject nonfinite input.
3. Per run, float64: `scipy.signal.butter(4, 10, fs=100)` + `filtfilt` (scipy default padding), then
   `resample_poly(x, 1, 5)` (Kaiser β=5) → 20 Hz. Cast to float32 after resampling.
4. Windows of `window_s × 20` samples (600 for 30 s, 200 for 10 s) on a grid anchored at the request
   `start_ts` with `hop_s` (bundle default, request may choose from {1, 2, 5, 10, 15, 30} with
   hop ≤ window). A window must lie fully inside `[start_ts, end_ts]` and ≥ 1 s from either run edge
   (filter transients). Too-short runs produce no windows. Window times: `s` = start, `e` = `s + window_s`.
5. Tensor `[B, 3, T]` float32, channels `ax, ay, az`.

Public datasets go through the same steps from their own rate/units (`inertia/datasets/*`): units → g,
Butterworth 10 Hz + `resample_poly` (or `np.interp` for non-integer rates) → 20 Hz, gaps > 1 s split.
Any dataset-specific repair (e.g. PAMAP2 ≤ 50 ms dropout fill) is versioned in the loader, recorded per
window as `filled_fraction`, and never applies to WHOOP data.

## 4. Encoder

`Inertia1Encoder(ckpt_path or $INERTIA1_CKPT_PATH, encoder_config)` loads a **narrowly vendored** copy of
upstream `encode()` for `ar_transformer` / `patchtst` (`inertia/vendor/`, MIT headers with upstream path
and SHA), never `run.py` and never pytorch-lightning. Load sequence, any failure is a typed
`InertiaUnavailable(kind)`:

1. path missing → `model_missing`; sha256 (before `torch.load`) ≠ config → `checkpoint_mismatch`;
2. `torch.load(weights_only=True)`, strip the Lightning `state_dict` prefix, **strict** load (missing or
   unexpected keys → `config_mismatch`); ART `pos_encoder.pe` must equal the recomputed sinusoid table;
   PatchTST `W_pos.shape[0]` must equal `window_s·hz/patch_len`;
3. encoder config `data.window_sec/hz/axes` must equal the bundle's preprocessing; otherwise refuse;
4. `eval()`, `requires_grad_(False)`, `torch.inference_mode()`, fp32, CPU, `torch.set_num_threads(1)`
   by default: deterministic and far cheaper in CPU; 16 threads is only ~1.2× faster at batch 64 (perf.json).

Encoder config `encoder.json` (`nara.inertia.encoder/1`): `encoder_id`, `method`, `preset`,
`arch{patch_len, stride, d_model, n_layers, n_heads, d_ff, dropout, …family extras}`,
`data{window_sec, hz, axes, axis_reduce}`, `checkpoint{file, sha256, size, source, url}`,
`inertia_repo_commit`, `extraction_point`, `embedding_dim`, `input_contract{axes, units:"g",
gravity:"kept", rate_hz:20, normalization:"none"}`.

Stand-ins (offline/shadow only): `standin:handcrafted-stats-v1` (strong engineered baseline),
`standin:nara-imu-feat-1-accel` (what the decoder already sees), `standin:inertia-arch-random-init/<method>-<preset>/seed<k>`
(negative control; upstream architecture, seeded random weights — **not Inertia-1**).

## 5. Head bundle (`nara.inertia.heads/1`)

A directory; every file's sha256 is listed in `manifest.json.files` and verified on load.

```
manifest.json          bundle id, encoder{...}, preprocessing{...}, heads{...}, ood{...}, training{...},
                       evidence_tier_max, files{name: sha256}
heads.npz              std.mu [D], std.sigma [D]; per head h: linear h.W [K,D], h.b [K]
                       or mlp h.ln_g, h.ln_b [D], h.W1 [H,D], h.b1 [H], h.W2 [K,H], h.b2 [K]
calibration.json       per head: method temperature|temp_bias|vector, T, weight?, bias?, class_order,
                       support_mask, class_prior, fit{split:"val", val_split_sha256, ...}, selection{...}
ood_reference.npz/.json  method, k, reference arrays, thresholds, content sha256
label_mappings.json    the audited crosswalk used
split_manifest.json    the frozen subject splits used (nara-split-1 per dataset)
evaluation.json/.md    the evaluate-once report (test), stamped with the bundle hash
```

`manifest.json.heads.<head>`: `arch` (`linear`|`mlp`), `class_order` (full list below), `supported`
(bool per class), `prior` (calibration-set mean calibrated prob per supported class),
`status` (`strong`|`weak`|`abstain` per supported class), `tau` (strong/weak threshold per class),
`merge_into` (abstained class → partner), `support_counts`, `selection` evidence.

`movement_intensity`: a 1-output head, sigmoid output, target `clip(ln(MET)/ln(12), 0, 1)` (sleep 0.95 → 0,
1.5 → 0.16, 3 → 0.44, 6 → 0.72) from the MET attached to the source label (Capture-24 annotation METs,
PAMAP2 protocol METs); `interval80` (split-conformal half-width on val) in the manifest. One output only:
a separate `wrist_motion` target would be an analytic function of the window (the engineered intensity
already provides it) and is not trained.

`transition` is a **multi-label event head**: one sigmoid per event (a sit→walk change is both
`sit_to_stand_like` and `walk_start`). Each event is calibrated separately (temperature on val); there is
no trained `none` output and the wire dict carries only event keys (values need not sum to 1).

`covers` (per head): a supported class that absorbed an unsupported class through set targets (e.g.
`walking` trained on pace-unknown walking while `brisk_walking` is unsupported) lists it:
`covers: {"walking": ["walking", "brisk_walking"]}`. The decoder treats such a class as evidence for
every covered class (compat = element-wise max over the covered classes' compat rows); evaluation scores
it as correct for any covered truth.

Inference is numpy-only (no torch, sklearn or pandas): `z = (emb − mu)/sigma` → logits →
unsupported classes −inf → calibration → softmax → probabilities over supported classes only.

### Class orders (fixed; `unknown` is never a trained class — it is the abstention/OOD outcome)

| head (wire key) | class_order |
|---|---|
| `posture` | recumbent, seated_likely, upright_stationary, postural_transition |
| `locomotion` | stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other |
| `arm_behavior` | quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other |
| `transition` (multi-label) | sit_to_stand_like, stand_to_sit_like, lying_down_like, getting_up_like, walk_start, walk_stop, run_start, run_stop |

Missing target = MASK, never `unknown`. Class targets may be **sets** (the truth is one of several
classes; loss −log Σ p over the set; e.g. pace-unknown walking = {walking, brisk_walking}); a MASK is the
empty set. Posture targets are MASKed on locomotion windows (posture is only claimed for stationary /
transition windows). A class is supported only with ≥ 200 train windows from ≥ 5 train subjects and ≥ 2
val subjects; unsupported classes are −inf at inference and absent from the wire dict.

### Training data policy

Training uses CC BY 4.0 wrist/forearm data only: Capture-24 (wrist, 100 Hz, free-living), WISDM-2019 watch,
HHAR watches, PAMAP2 hand, MHEALTH right lower arm, Opportunity wrists/forearms. Non-wrist sets (HAPT
waist, HARTH / HAR70+ back+thigh) are pooled-ablation and transition-timing references only. CC BY-NC-SA
sets (WEAR, GOTOV) and sets with no stated licence (ExtraSensory, RealWorld, UT) are excluded from
training pending an explicit licensing decision. All signals are converted to g before preprocessing
(m/s² ÷ 9.80665, mg ÷ 1000). The audited crosswalk is `activity_context/inertia/label_mappings.json`.

### Bundle file keys (authority: `activity_context/inertia/bundle.py`)

* `heads.npz`: `std.mu`, `std.sigma`; `<head>.W`, `<head>.b` (linear) or `<head>.ln_g`, `<head>.ln_b`,
  `<head>.W1`, `<head>.b1`, `<head>.W2`, `<head>.b2` (mlp); K = full class order (movement_intensity K = 1).
* `calibration.json`: `schema`, `heads.<head>{method, class_order, support_mask, class_prior{supported: p},
  fit{split:"val", …}, T | bias[K] | weight[K]}`; `transition` uses `temperature_per_event` with `T[K]`;
  per-class vectors align with class_order, unsupported entries may be null.
* `ood_reference.json`: `schema, method, threshold, thresholds?, k (knn), head (energy), fit{split:"val"},
  content_sha256` (of the npz). `ood_reference.npz`: `mu, sigma` (+ `class_means[C,D], precision[D,D]` |
  `mean[D], precision` | `reference` float16 [N,D] L2-normalised); energy has no arrays.
* `manifest.json`: `schema, bundle_id, evidence_tier_max, encoder{encoder_id, embedding_dim,
  checkpoint_sha256, config_sha256}, preprocessing{version, window_s, hop_s, rate_hz, axes, units}, heads{…},
  ood{method, threshold, k?, head?}, training{…}, files{name: sha256}`; `supported` is a bool list aligned
  with class_order. Candidate/production bundles must also list `label_mappings.json` and `split_manifest.json`.
* `bundle_sha256` = sha256 of `name\0sha256\n` for each sorted `files` entry, then `manifest.json\0` + the
  manifest.json bytes. npz are written deterministically (sorted, stored, fixed timestamps).

## 6. Serve protocol (`python -m activity_context.inertia.serve`)

Separate persistent process; same line-delimited JSON framing as `activity_context.serve`
(`ping` / `infer` / `shutdown`, one JSON object per line, SIGALRM timeout per request).

```
python -m activity_context.inertia.serve --bundle <dir> [--encoder-config <encoder.json>]
    [--checkpoint <path>]   # default $INERTIA1_CKPT_PATH
    [--allow-standin-shadow] [--timeout 60]
```

ping → `{"id","op":"ping","ok":true,"model_available":bool,"model_status":"inertia_loaded"|"inertia_unavailable"|"standin_shadow",
"model_error":str|null,"encoder_id","encoder_kind","encoder_version","heads_version","bundle_sha256",
"checkpoint_sha256","preprocessing_version","evidence_tier_max","package_version"}`.
An unavailable model answers ping with `ok:true, model_available:false` and every infer with
`{"ok":false,"kind":"model_missing"}`; it never falls back to anything that claims to be Inertia.

infer request: identical `run` object to the HART service (`start_ts, end_ts, sample_rate_hz:100,
channels_order:[ax,ay,az,gx,gy,gz], units:{accel:"g",gyro:"deg/s"}, columns_b64, head_b64≤3, tail_b64≤3`)
plus optional `hop_s`. Gyro columns are decoded for validation and ignored.

infer response (`motion-heads-1`):

```json
{"id":"…","op":"infer","ok":true,"schema":"motion-heads-1",
 "encoder_id":"inertia-1/ar_transformer-small/30s@20hz","encoder_kind":"inertia1","encoder_version":"…",
 "checkpoint_sha256":"…","heads_version":"<bundle id>","bundle_sha256":"…","preprocessing_version":"inertia-prep-1",
 "evidence_tier_max":"shadow|candidate|production","window_s":30,"hop_s":5,
 "bundle":{"heads":{"posture":{"class_order":[…],"prior":{"recumbent":0.2,…},"status":{"recumbent":"strong",…},
                               "tau":{"recumbent":0.91,…},"merge_into":{"postural_transition":"upright_stationary"},"covers":{}},
                    "locomotion":{…},"arm_behavior":{…},"transition":{…}},
           "ood":{"method":"knn","threshold":1.23}},
 "windows":[{"s":1758000000,"e":1758000030,
             "posture":{"recumbent":0.01,"seated_likely":0.9,…},"locomotion":{…},"arm_behavior":{…},"transition":{…},
             "movement_intensity":0.12,"ood_score":0.8,"is_ood":false}],
 "n_dropped_nonfinite":0,"duration_ms":12}
```

Probabilities are calibrated and cover supported classes only (absent key ≠ 0 probability claim).
`posture`, `locomotion`, `arm_behavior` sum to 1 over their keys; `transition` values are independent
per-event probabilities. A head with no supported class is omitted from the window.
A window whose embedding or outputs are nonfinite is **omitted** and counted in `n_dropped_nonfinite`.
Errors: `{"id","ok":false,"error","kind"}`, kind ∈ `malformed | model_missing | checkpoint_mismatch |
config_mismatch | timeout | internal | output_too_large`. Response line ≤ 12 MiB (below the worker's
16 MiB line cap); a larger result is `output_too_large`.

## 7. Decoder (Swift) — distinct channels, off by default

* `ActivityObservation.motionHeads: MotionHeadsWindow?` (new, optional, default nil). Never touches
  `encoder` / `classProbs`. `ActivityContextTrackInput` gains optional Inertia windows + bundle info.
  Inertia never creates an observation second; a window attaches to the first observed second in
  `[e, e+2]` or is dropped and counted.
* `ActivityDecoderConfig.motionHeads: MotionHeadsEvidenceConfig?` — nil (default) = off; the decoder
  output, snapshot JSON and `cacheTag` are byte-identical to today. Shadow mode never feeds the decoder.
* Only `encoder_kind == "inertia1"` with tier ≥ `candidate` may be used as evidence; anything else is
  ignored and reported.
* Evidence: per head `r(y) = q(y)/π(y)`; abstained classes merged into `merge_into` first.
  Body compat `A[m,y]` = the decoder's own `profiles[m].posture/.locomotion` without `unknown`, ε=0.02
  floor, renormalised. Locomotion `L(m) = clip(Σ_y A[m,y]·r(y), 0.1, 10)`; posture `L` renormalised
  inside the stationary/transition set S so it moves mass only within S; `unknown` mode L = 1; added
  with `isEvidence: false` (never reduces the missing-sensor unknown bonus). Arm head enters the arm
  chain only: `arm[i] *= L_arm(i)^(armTemperature · w_arm · rel)`. Classes summed in fixed class order.
* Weights: per-window `rel = Σ_g q_g·γ_g` (γ strong 1, weak 0.5). Candidate defaults locomotion 0.25,
  posture 0.25, arm 0.25, transition 0 (log only), movement_intensity log only; body budget
  (locomotion+posture+transition) ≤ 0.5; arm ≤ 0.5; ceiling 0.8. Locomotion weight × (1 − ρ̂) when a
  fresh HART window is present (ρ̂ = residual log-LR correlation from replay; default 0.5 until measured).
* A window applies each second while its age < `hop_s` (hop-normalised). OOD, missing, timeout or
  malformed ⇒ every Inertia term omitted for that window (no unknown boost in v1).
* Specialist gate (stairs/cycling/vehicle/otherExercise) may be opened by Inertia only for a `strong`
  class with `q ≥ τ` on a non-OOD window, candidate mode only.
* Provenance: optional `ActivityStateVersions` field naming `inertia-1:<bundle12>:<cfgtag>` only when
  Inertia is active; snapshot restore rejects a mismatch.

## 8. Worker (shadow first)

Second `ActivityPythonService` instance (own process, timeout, restart cap) running
`activity_context.inertia.serve`. Off unless `FRWHOOP_INERTIA_ENABLED=1`.
`FRWHOOP_INERTIA_MODE=shadow|candidate` (default shadow), `FRWHOOP_INERTIA_BUNDLE_DIR`,
`FRWHOOP_INERTIA_CHECKPOINT` (→ `INERTIA1_CKPT_PATH`), `FRWHOOP_INERTIA_PYTHON`, `FRWHOOP_INERTIA_TIMEOUT_SECONDS`.
Inertia is never part of the readiness gate and its failures never fail a job: logged with kind,
counted, the HART path continues. Shadow output is stored in its own table, never in
`activity_context_epochs` / `activity_context_days`. Candidate mode additionally decodes the day a
second time with Inertia evidence and stores that comparison document beside the shadow output; the
published HART document is unchanged. Stage 3 (production evidence) needs a pinned official checkpoint,
a bundle with `evidence_tier_max = production`, and an explicit config change; rollback = disable.

## 9. Statistical integrity (enforced in code and tests)

Subject split before windowing (WISDM reuses HART's seed-42 split so the decoder comparison is
leak-free for both models); frozen split manifests with sha256; class weights from train only;
architecture/hyper-parameters chosen on val; calibration fit on val only; thresholds on val only; the
test split is opened once by `evaluate_heads` which hash-stamps the bundle and refuses silent reruns;
head input is the embedding only (no HR, HRV, RR, respiration, temperature, sleep, steps, workouts,
HART outputs or engineered features); posture promotion decided on wrist data only.

## Replay record format (`nara-activity-replay-1`)

Input of the Swift offline replay harness (`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/
ActivityReplayHarness.swift`, the format authority; run with `ACTIVITY_REPLAY_IN=<file>
ACTIVITY_REPLAY_OUT=<out.json> swift test --filter ActivityReplayTests/testReplayFromEnvironment` in
`Packages/StrandAnalytics`). JSON Lines, UTF-8, one object per line.

Line 1, the header:

```json
{"format": "nara-activity-replay-1",
 "arms": ["streams", "hart", "inertia", "hart+inertia", "naive_average"],
 "decoder": {"resting_hr": 60, "max_hr": 190},
 "motion_heads": {"bundle": <motion-heads-1 infer response without "windows": encoder_id … hop_s, "bundle": {heads, ood}>,
                  "config": {"locomotion": 0.25, "posture": 0.25, "arm": 0.25, "body_budget": 0.5,
                             "arm_budget": 0.5, "hart_redundancy": 0.5},
                  "allow_standin_evidence_for_testing": false}}
```

`arms` (default all five), `decoder` and `motion_heads.config` (default: the candidate defaults) are
optional. The Inertia arms need `motion_heads`; a stand-in bundle (or a tier below `candidate`) is refused
unless `allow_standin_evidence_for_testing` is true — the replay is the only place that flag may be set.

Every further line is one observation `{"seq": "<sequence id>", "obs": {...}}`. Sequences are decoded
independently in order of first appearance; inside a sequence `ts` must strictly increase (one line per
second that has data). `obs` mirrors `ActivityObservation`:

| key | type | meaning |
|---|---|---|
| `ts` | int (required) | unix second the observation closes |
| `dyn` | number\|null | strap dynAccel, g |
| `grav` | [x, y, z]\|null | gravity vector (any scale) |
| `steps` | int\|null | step-counter ticks gained this second |
| `strap_class` | int\|null | 0 still, 1 walk, 2 run |
| `hr` | int\|null | bpm |
| `imu` | object\|null | `imu-feat-1` window completed at or before `ts`: `s, e, accel_rms_g, gyro_rms_dps, jerk_rms, cadence_hz\|null, cadence_strength, orientation_change_deg\|null` |
| `encoder` | object\|null | HART/baseline window completed at or before `ts`: `id, version, s, e, probs{v1 label: p}, calibrated, abstained` |
| `motion_heads` | object\|null | a `motion-heads-1` window (§6 window object) attached to this second (first observed second in `[e, e+2]`; never a second of its own) |
| `wear` | `"onWrist"`\|`"offWrist"`\|`"unknown"` | default `"unknown"` |
| `sleep` | `"asleep"`\|`"awake"`\|`"unknown"` | default `"unknown"` |
| `in_bed` | bool | default false |
| `workout` / `workout_kind` | bool / `"unspecified"`\|`"running"`\|`"walking"`\|`"cycling"`\|`"other"` | defaults false / unspecified |

Arms: `streams` drops `encoder`, `imu` and `motion_heads`; `hart` drops `motion_heads`; `inertia` drops
`encoder` and decodes with the motion-heads config; `hart+inertia` keeps everything; `naive_average` (the
forbidden baseline, ablation only) replaces the encoder probabilities by 0.5·HART + 0.5·Inertia locomotion
folded onto the v1 labels (stationary → stationary; walking, brisk_walking, stairs → walking; running →
running; cycling, vehicle_motion, other → other_movement) from the latest non-OOD Inertia window younger
than one hop, and decodes with Inertia off.

Output (`nara-activity-replay-out-1`): `{"format", "arms": {arm: {seq: {"states": [...], "events": [...],
"observed_s", "refusal", "motion_heads"?}}}}`, one state per published 5-s tick: `ts, posture, locomotion,
arm_behavior` (full probabilities), `display` (label or null), `class` / `class_confidence` (canonical
`ActivityClass`), `unknown {posture, locomotion, arm_behavior}`, `overall_confidence`,
`overall_uncertainty`, `transition` (event or null). A refused arm has `refusal` set and no states.
