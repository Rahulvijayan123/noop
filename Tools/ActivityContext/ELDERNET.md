# ElderNet gait quality — implementation map and contract

Status: **real, public, fine-tuned weights; no training by Nara.** ElderNet (Brand et al., npj Digital
Medicine 2026, "Continuous Assessment of Daily-Living Gait Using Self-Supervised Learning of Wrist-Worn
Accelerometer Data") from `yonbrand/gait-quality` @ `437a38bcc69f42717fe73c1f7dbea7e1f7a50d23`: a ResNet-18
backbone self-supervised on UK Biobank wrist data, fine-tuned on Mobilise-D TVS, with separate heads for gait
detection, gait speed, stride length, cadence, stride regularity and step count. It runs beside HART as its own
expert; Inertia-1 (INERTIA1.md) stays dormant until its weights are public.

Licence: the weights and model code carry the University of Oxford SSL-wearables **Academic Use Licence**
(non-commercial academic research; notice "Copyright © 2022, University of Oxford"). Nara is non-commercial
(PolyForm Noncommercial); the owner accepted this on 2026-10-05. Weights are fetched by sha256 from the pinned
upstream commit and never committed to Nara's git.

This file is the contract between `activity_context/eldernet/` (Python), the worker and the decoder.

## 1. Model assumptions (upstream, verified by the audit)

Wrist-worn; units g, gravity kept (|a| ≈ 1 at rest); fine-tuned on older adults (systematic shift expected on
young healthy wearers — Nara validates before any metric is used as evidence); 30 Hz, 10 s windows
(3 × 300), fixed by the architecture; quality metrics are only meaningful on detected gait.

## 2. Preprocessing `eldernet-prep-1` (WHOOP → model input)

1. Accelerometer only: first 300 i16 of each NPB1 second × 1/4096 → g, axes `ax, ay, az`, gravity kept.
2. Runs exactly as the HART path: duplicate second → error, clock reset → error, gap > 1 s → new run.
   **No imputation, no gap bridging, no "longest valid segment" selection, no edge-day dropping**: those
   upstream steps target multi-day files and would fabricate or discard motion here. Each contiguous run is
   processed on its own.
3. 100 → 30 Hz with the same resampler upstream uses. **Decided: reproduced exactly** — `actipy.processing.resample`
   is nearest-neighbour (no anti-alias filter); `preprocess.py` reproduces its index map bit-for-bit (numpy only, so
   the serve needs no pandas/actipy).
4. 10 s windows (300 samples) on a grid anchored at the request `start_ts`, fully inside the run. **Decided:** hop
   5 s served by default (`--hop-s` / request `hop_s` ∈ {1, 2, 5, 10}; 1 = upstream `window_overlap_sec` 9); edge
   margin 0 — the nearest-neighbour map has no transient, so a window reads exactly its own 10 s of samples.
5. Upstream auto-calibration / non-wear detection. **Decided: both off** (ping `preprocessing` says so). Non-wear
   needs >= 72 h upstream; gravity calibration needs the whole recording and is the one measured whole-day
   difference from upstream (0.1-0.6 % of windows flip is_gait on Capture-24 days it changes; VALIDATION.md §1).
   Wear is Nara's own evidence.

## 3. Gait detection made window-local

Upstream skips windows below a recording-relative Otsu variance threshold (capped at an absolute static
ceiling) before the classifier. That makes one window's answer depend on the rest of the request. Nara uses a
fixed, documented static pre-filter (the upstream absolute ceiling, mean per-axis variance <= 0.013² g²) so every
window's output depends only on that window — deterministic and chunking-independent. Measured on six whole
Capture-24 days: upstream's Otsu threshold was always above the ceiling, so the two pre-filters agreed on every
window.

## 4. Wire format `gait-quality-1` (`python -m activity_context.eldernet.serve`)

Same framing as `activity_context.serve` (`ping` / `infer` / `shutdown`, one JSON object per line, SIGALRM
timeout), same `run` request object. A separate process; never imported by the HART serve.

ping → `{"id","op":"ping","ok":true,"model_available":bool,"model_status":"eldernet_loaded"|"eldernet_unavailable",
"model_error","model_id":"eldernet","model_version","weights":{name: sha256},"upstream_commit",
"preprocessing_version","package_version"}`

infer response:

```json
{"id":"…","op":"infer","ok":true,"schema":"gait-quality-1","model_id":"eldernet","model_version":"eldernet-437a38b",
 "weights":{"gait_detection":"…","gait_speed":"…","gait_length":"…","cadence":"…","regularity":"…","step_count":"…"},
 "upstream_commit":"437a38bc…","preprocessing_version":"eldernet-prep-1","window_s":10,"hop_s":5,
 "calibration":{"gait_prob":{"method":"temperature","T":1.0,"fit":"val"}}|null,
 "gait_threshold":0.5,
 "windows":[{"s":1758000000,"e":1758000010,"gait_prob":0.97,"is_gait":true,
             "speed_mps":1.21,"cadence_spm":108.0,"stride_m":1.34,"regularity":0.81,"steps":18.0}],
 "n_dropped_nonfinite":0,"duration_ms":12}
```

* `gait_prob` — the detection head's probability for the window (calibrated when `calibration` is non-null;
  Nara-fitted calibration is VAL-only and versioned); `is_gait` = `gait_prob ≥ gait_threshold` after the static
  pre-filter (a pre-filtered window has `gait_prob` 0 and `is_gait` false and says so with `"prefiltered":true`).
* `speed_mps` (0–2), `cadence_spm` (steps/min, 0–150 upstream range), `stride_m` (0–2), `regularity` (0–1),
  `steps` (per 10 s window) — present **only** on `is_gait` windows (absent ≠ 0); clipped to upstream ranges.
* Nonfinite outputs → the window is omitted and counted. Errors: `{"ok":false,"kind":…}`, kind ∈
  `malformed | model_missing | weights_mismatch | timeout | internal | output_too_large`.

## 5. Decoder (Swift) — a distinct channel, off by default

Code: `Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityContextGaitQuality.swift` (wire, model, config) and
`ActivityContextGaitQualityFusion.swift` (channel, reported block).

* **Wire decoding.** `GaitQualityResponse` is `Decodable`; its `init(from:)` refuses anything that is not exactly
  §4 with a `GaitQualityResponseError` (thrown as is): `ok:false` → `serviceError(kind)`; schema other than
  `gait-quality-1`; `model_id ≠ eldernet`; `model_version` not `[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}`; a `weights`
  key outside the six heads, a digest that is not 64 lower-case hex, or no `gait_detection`; `upstream_commit` not
  7–40 hex; `preprocessing_version ≠ eldernet-prep-1`; `window_s ≠ 10`; `hop_s ∉ {1, 2, 5, 10}`; `gait_threshold ∉
  (0, 1)`; `calibration` with an output other than `gait_prob`, without string `method` / `fit`, or a non-numeric
  parameter. Windows: known keys only (`s, e, gait_prob, is_gait, prefiltered, speed_mps, cadence_spm, stride_m,
  regularity, steps`); `s`, `e` integral with |x| < 9e15 (never `Int(x)`), `s ≥ 0`, `e − s = 10`, strictly
  increasing `s`; `gait_prob` finite in [0, 1]; `is_gait` a boolean that agrees with `gait_prob ≥ gait_threshold`
  within 1e-6 (rounding); a `prefiltered` window is `gait_prob 0, is_gait false`; metrics finite, in range (speed
  0–2 m/s, cadence 0–150 steps/min, stride 0–2 m, regularity 0–1, steps 0–50 per window) and only on gait
  windows (null = absent). `n_dropped_nonfinite` / `duration_ms` non-negative integers. Text that is not JSON (a
  NaN token) fails in `JSONDecoder` first; its counter kind is `nonfinite` / `malformed_json`
  (`GaitQualityResponseError.notJSON`). `GaitQualityWindow` and `GaitQualityModelInfo` decode through the same
  checks, so a snapshot, a stored config or a replay record can never carry what the wire would refuse.
* **Weights digest** (what a deployment pins): sha256 of `eldernet-weights-1\n` followed by `name=sha256\n` for
  each served head in name order (`GaitQualityModelInfo.weightsDigest`; Python:
  `hashlib.sha256(("eldernet-weights-1\n" + "".join(f"{k}={v}\n" for k, v in sorted(w.items()))).encode())`).
* **Observation and track.** `ActivityObservation.gaitQuality: GaitQualityWindow?` (never `encoder` /
  `classProbs`, never `motionHeads`); `ActivityContextTrackInput.gaitQuality: GaitQualityTrackInput?` (model +
  windows). A window attaches to the first on-wrist observed second in `[e, e + 2]` (the later of two on one
  second) or is dropped and counted; ElderNet never creates a second. It applies each second while its age is
  below `hop_s`.
* **Config.** `ActivityDecoderConfig.gaitQuality: GaitQualityEvidenceConfig? = nil`. Fields: `mode`
  (`shadow` never feeds the decoder; `candidate`; `production` needs both pins), `model`, `gaitPrior` π ∈ [0.01,
  0.99] (the calibration set's gait prevalence; no default), `gaitWeight` 0.25, `briskWeight` 0, `briskRule`
  cadence|speed (100 steps/min or 1.34 m/s), `hartRedundancy` 0.65 and `inertiaRedundancy` 0.65 (the Inertia
  default, itself above the measured HART ρ̂ = 0.61; ElderNet's own overlap is not measured yet),
  `accelerometerBudget` 0.5 (Inertia's body budget), `expectedModelVersion`, `expectedWeightsDigest`. Weights and
  the budget ≤ 0.8. A refused config (`shadow_mode`, `model_version_mismatch`, `weights_digest_mismatch`,
  `production_needs_pins`, `invalid_config: …`) or a track whose windows come from another model
  (`model_mismatch`) or none (`no_gait_quality_input`) is decoded with the entry removed
  (`ActivityContextTrackBuilder.effectiveConfig`): output, snapshot and `cacheTag` byte-identical to today.
* **Gait term.** r(gait) = q/π, r(non-gait) = (1 − q)/(1 − π). Compat: gait = walk, briskWalk, stairs;
  non-gait = bedRest, seated, upright, vehicle, cycling; run, otherExercise, the four transitions and `unknown`
  get 1. Rows carry an ε = 0.02 floor; L(m) = clip(r_other + a·(r_own − r_other), 0.1, 10) with a = (1+ε)/(1+2ε),
  so q = π gives exactly 1. Added with `isEvidence: false`, tempered (× `evidenceTemperature`) like every
  channel. ElderNet cannot name stairs: that mode stays behind its specialist gate.
* **Redundancy and the shared budget.** Weight × (1 − ρ_HART) on seconds where HART's encoder channel speaks and
  × (1 − ρ_Inertia) where an Inertia locomotion term is active (both when both speak), capped at the budget. Per
  second and per mode the gait term (and then the brisk split) gets only the room left under `accelerometerBudget
  · ln 10` after Inertia's whole pull on that mode (locomotion, posture inside its set, any specialist gate it
  opened). So every accelerometer-derived term together stays ≤ T · max(B_acc, B_Inertia) · ln 10 per mode
  (tested); seconds where the budget cut a term are counted (`budget_limited_seconds`).
* **Walk vs brisk walk.** On a gait window carrying the rule's metric, p = sigmoid((cadence − 100)/6) (or
  ((speed − 1.34)/0.08)) gives ratios on walk and briskWalk only, renormalised inside that pair against the
  current belief (it never changes P(gait)). Default weight 0: the verdict is computed and counted
  (`brisk_favoured_seconds`, `walk_favoured_seconds`), never applied. (The strap's own step cadence already
  separates the two modes in the gait channel, so this term is largely redundant until validated.)
* **Reported block.** `ActivityGaitSummary` (`since`, `windows`, `gait_probability`, means of `speed_mps`,
  `cadence_spm`, `stride_m`, `regularity`, `steps` = Σ steps × hop/window, per-metric counts only when they differ
  from `windows`, `provenance`). A published state carries `gait` (the current walking stretch: consecutive
  ElderNet gait windows while P(walk + briskWalk + stairs) ≥ 0.5; it ends when the posterior leaves gait, ElderNet
  says non-gait, or no window is held) only while the channel is active. Runs carry the windows their states
  added (a stretch split across runs is never counted twice), intervals the gait of their runs, and
  `ActivityClassAggregate` the gait of its intervals; all optional and omitted when nil. Not evidence in v1, and
  not stored in the phone's `ActivityContextIntervalRow`.
* **Provenance.** `ActivityStateVersions.gaitQuality` (`gait_quality`) = `eldernet:<model_version>:<weights12>:
  <cfgtag>` only when the channel is accepted for the track; `cacheTag` gains `-eg<weights12><cfgtag>` (after
  Inertia's `-ih…`); snapshot restore with another stamp (or none) is `discarded("gait_quality_mismatch")`. The
  config tag covers mode, weights, rule, thresholds, π, both ρ, the budget, hop, window, threshold, model version
  and calibration. `GaitQualityTrackReport` on the track counts windows in / attached / dropped / ingested / gait
  / pre-filtered, evidence and budget-limited seconds, brisk verdicts and states that carried the block.

## 6. Worker (shadow first)

Code: `Tools/CloudWorker/Sources/frwhoop-worker/ActivityGaitQuality.swift`, hooks in `ActivityLane.swift`,
`main.swift`, `ActivityPythonService.swift` (ping objects, `eldernet_unavailable`).

| variable | meaning |
|---|---|
| `FRWHOOP_ELDERNET_ENABLED` | `1`/`true`/`yes`/`on` (any case) = on; `0`/`false`/`no`/`off` or unset = off; anything else keeps ElderNet off and is logged as a configuration error |
| `FRWHOOP_ELDERNET_MODE` | `shadow` (default) or `candidate` |
| `FRWHOOP_ELDERNET_WEIGHTS_DIR` | fetched weights, passed as `--weights-dir` (required when on) |
| `FRWHOOP_ELDERNET_MODEL_VERSION` | the pinned `model_version` (required in candidate mode; enforced in shadow mode when set) |
| `FRWHOOP_ELDERNET_WEIGHTS_SHA256` | the pinned weights digest (§5; 64 hex; required in candidate mode; enforced when set) |
| `FRWHOOP_ELDERNET_GAIT_PRIOR` | π for the candidate decode, in [0.01, 0.99] (required in candidate mode) |
| `FRWHOOP_ELDERNET_PYTHON` | interpreter (default: the activity python) |
| `FRWHOOP_ELDERNET_TIMEOUT_SECONDS` | worker-side request timeout, default 60, clamped to `FRWHOOP_ACTIVITY_LEASE_SECONDS / 3`; the child gets `--timeout` strictly below it |

* A third `ActivityPythonService` (`python -m activity_context.eldernet.serve --weights-dir <dir> --timeout <s>`,
  restart cap 4, 120 s cooldown, 16 MiB response lines, raw lines kept so a NaN line fails at once). Never in the
  readiness gate. At the start of each job: start, ping (`model_available`), and with pins set compare the ping's
  `model_version` and the digest of its `weights` map; then, per chunk and after HART (and Inertia): renew the
  lease (a lost lease ends the job as before HART), infer, decode strictly, check the pins on the response.
  Failures are absorbed, counted and logged once per kind; transport failures, `model_missing`,
  `weights_mismatch`, `timeout` and pin refusals (`pin_mismatch`) stop ElderNet for the job; a NaN line or invalid
  values cost one chunk. A chunk whose HART answer comes from the on-host cache is still sent to ElderNet. HART's
  v1 and v2 payloads are byte-identical with ElderNet on or off.
* **Shadow row** (`activity_gait_windows_days`, migration `20261006090000_activity_gait_windows.sql`, one row per
  owner, device, UTC day, `model_version`, mode): provenance (weights per head, their digest — recomputed and
  checked by the RPC — commit, preprocessing, hop, threshold), `windows` in `gait-windows-1` (`{"format", "n",
  "w": 10, "h": hop, "s0", "ds": [start deltas], "gp": [gait prob ‰], "g": [0|1], "pf": [0|1], "sp": [cm/s|-1],
  "cad": [steps/min|-1], "st": [cm|-1], "rg": [%|-1], "stp": [steps × 10|-1]}`, omitted above 512 KiB, refused
  above 1 MiB), `summary` (counts, failure kinds, mean gait probability, ElderNet's own `gait` metrics over its gait
  windows, `track_report`: the candidate decode's report or a dry-run attachment). Fenced RPC
  `publish_activity_gait_windows_day` under its own savepoint after the day document (and the Inertia row) and
  before the v1 publish; NULL is counted as `eldernet_shadow_fenced`.
* **Candidate** (pins and π set): the published v2 input plus the day's windows decoded a second time with the
  gait channel (`GaitQualityEvidenceConfig`, mode candidate, the pins), stored as `candidate_document` beside the
  shadow row, never in `activity_context_days` / `activity_context_epochs`; otherwise `withheld_reason`
  (`model_not_pinned`, `gait_prior_not_set`, the config's refusal, `context_days_disabled`).
* **Counters** (heartbeat, only with ElderNet on): `eldernet_jobs`, `_chunks`, `_windows`, `_failures`,
  `_unavailable`, `_pin_refused`, `_shadow_stored`, `_shadow_failures`, `_shadow_fenced`, `_candidate_documents`,
  `_candidate_withheld`, `_windows_attached`, `_windows_dropped`, `_rows_pruned`, `_prune_failures`.
* **Retention:** `prune_activity_gait_windows_days(30, 10000)` every 6 h while ElderNet is on.

## 7. Validation (weights frozen; Nara fits at most a calibration on VAL subjects)

Gait detection P/R/F1, calibration and risk-coverage vs walking labels on the frozen wrist test subjects
(WISDM, HHAR, PAMAP2, MHEALTH, Opportunity, Capture-24, GOTOV; OxWalk if obtainable); cadence and steps vs
annotated steps where available (OxWalk); speed ordinal checks (GOTOV slow < normal < fast); parity with
upstream `pipelines.general` on whole recordings; latency/RAM. Splits are the frozen subject splits in
`Tools/ActivityContext/splits/`.

## 8. Results and operating values (eval/eldernet/VALIDATION.md, VALIDATION.json)

* Parity: upstream toy example and three 3 h Capture-24 segments reproduce upstream bouts and metrics (detection
  agreement 1.000, quality within 3.6e-5).
* Served defaults: no calibration, `gait_threshold` 0.5 (upstream argmax). VAL fit (`eval/eldernet/calibration.json`,
  `--calibration`): T = 1.047 (free-living; ≈ upstream already calibrated), high-precision threshold 0.93.
* Detection (served defaults): Capture-24 TEST P 0.88 / R 0.52 (free-living, AUROC 0.967); GOTOV older adults P 0.97 /
  R 1.00; OxWalk P 0.98 / R 0.87. Steps per 10 s window on OxWalk: MAE 1.0 (bias −0.3). GOTOV speed / cadence
  ordered slow < normal < fast in 19 / 21 and 20 / 21 participants.
* Decoder π: **0.065** (Capture-24 VAL, gait share of labelled 10 s windows at hop 5; 0.125 if pre-filtered windows
  are excluded).
* Serve: ~650 MB RSS, ~1.9 ms per window per head on one thread; keep hop 5 and <= 1 h requests under the 60 s
  timeout.

## Replay record format (ElderNet extension of `nara-activity-replay-1`)

The offline replay harness (`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ActivityReplayHarness.swift`,
the format authority; INERTIA1.md "Replay record format" for the base format) carries ElderNet too:

* header `"gait_quality": {"model": <a gait-quality-1 infer response without "windows": model_id … gait_threshold>,
  "gait_prior": π, "config": {"gait", "brisk", "brisk_rule", "brisk_cadence_spm", "brisk_speed_mps",
  "hart_redundancy", "inertia_redundancy", "accelerometer_budget"}}` (`config` and each of its keys optional:
  candidate defaults). The model goes through the wire decoder's checks.
* observation key `"gait_quality"`: a §4 window object, attached like `motion_heads` (a second that has data,
  never one of its own); the structural checks on decode, then the model checks (window length, threshold
  agreement). A window in a file whose header has no `gait_quality.model` is refused.
* arms (default: all eight): `streams`, `hart`, `inertia`, `hart+inertia`, `naive_average` (all five drop
  `gait_quality` and decode exactly what they decoded before ElderNet existed), `eldernet` (drops `encoder` and
  `motion_heads`, gait config), `hart+eldernet` (drops `motion_heads`), `hart+eldernet+inertia` (everything, both
  configs). An ElderNet arm without a header model is `refusal: "no_gait_model"`.
* output: per sequence `"gait_quality"` (the track report) next to `"motion_heads"`; a state that carries the
  reported block has it under `"gait"`.
