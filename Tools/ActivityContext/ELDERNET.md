# ElderNet gait quality — implementation map and contract

Status: **real, public, fine-tuned weights; no training by Nara.** ElderNet (Brand et al., npj Digital
Medicine 2026, "Continuous Assessment of Daily-Living Gait Using Self-Supervised Learning of Wrist-Worn
Accelerometer Data") from `yonbrand/gait-quality` @ `437a38bcc69f42717fe73c1f7dbea7e1f7a50d23`: a ResNet-18
backbone self-supervised on UK Biobank wrist data, fine-tuned on Mobilise-D TVS, with separate heads for gait
detection, gait speed, stride length, cadence, stride regularity and step count. It runs beside HART as its own
expert; Inertia-1 (INERTIA1.md) stays dormant until its weights are public.

## Licence — read before enabling anything

> **ElderNet (code and weights) is University of Oxford software under the SSL-wearables Academic Use Licence**
> (upstream `LICENSE.md`; "Copyright © 2022, University of Oxford"). **Its use is limited to the licensee's own
> internal academic, non-commercial research**; clause 1.1(b) excludes using it "for or on behalf of any third
> party or to provide a service". **Running it as a service for other users — the worker lane on beta testers'
> data — may fall outside that licence.** Whether Nara's use qualifies is an **owner decision**; a service or
> commercial use needs a licence from Oxford University Innovation (enquiries@innovation.ox.ac.uk). The worker
> lane stays **off by default** (`FRWHOOP_ELDERNET_ENABLED` unset, §6) and is not to be switched on for other
> people's data until that is decided. (The owner accepted the licence for academic, non-commercial use on
> 2026-10-05; Nara is PolyForm Noncommercial.)

* **No Oxford code or weights are in this repository** (`NOTICE.md`). The operator fetches both from the pinned
  commit at install time, under the Oxford licence, every file sha256-pinned:
  `python -m activity_context.eldernet.weights fetch --dest <weights dir>` (the six heads) and
  `python -m activity_context.eldernet.upstream fetch --dest <source dir> [--from-git <clone>] [--with-examples]`
  (`LICENSE.md`, `models.py`, `gait_quality/__init__.py`, `detection.py`, `quality.py`, `pipelines/config.yaml`;
  GitHub raw at the commit, or `git archive` of a local clone; `--with-examples` adds the toy recording the golden
  and parity tests use). A full clone checked out at the commit works as is. Point `ELDERNET_WEIGHTS_DIR` /
  `--weights-dir` and `ELDERNET_UPSTREAM_DIR` / `--upstream-dir` at them (`… verify` checks a directory). Nothing
  downloads at serve time.
* `activity_context/eldernet/upstream.py` (Nara's adapter) reads each upstream file once, checks size and sha256,
  and compiles exactly those bytes into private module objects (never in `sys.modules`; their imports resolve only
  to the other verified upstream modules, anything else upstream-internal is refused). The serve executes only
  `models.py` (the architecture: `Resnet` feature extractor + `ElderNet`, built as upstream
  `gait_quality/weights.py::build_model` does); the offline `run` CLI also `gait_quality/detection.py` /
  `quality.py` (bout rules; pandas). One upstream function is not run: `models.weight_init` imports upstream
  `utils.py` (pingouin, seaborn, `matplotlib.use('TkAgg')`) and re-seeds the global RNGs, so the adapter replaces
  that name with a no-op in its private copy; the strict checkpoint load then overwrites every parameter and
  buffer. No upstream file is modified. Outputs are bit-identical to the previously vendored copy (VALIDATION.md §1).
* Commits up to `0b6d34f5` carried a vendored copy of upstream `models.py` and a re-expression of the bout rules;
  they are gone from the tree, not from git history (rewriting history is an owner decision).

This file is the contract between `activity_context/eldernet/` (Python), the worker and the decoder.

## 1. Model assumptions (upstream, verified by the audit)

Wrist-worn; units g, gravity kept (|a| ≈ 1 at rest); fine-tuned on older adults (systematic shift expected on
young healthy wearers — Nara validates before any metric is used as evidence); 30 Hz, 10 s windows
(3 × 300), fixed by the architecture; quality metrics are only meaningful on detected gait. The architecture
settings Nara passes to upstream's constructors (`QUALITY_HEADS`: `max_mu`, regressor layers, batch norm;
feature vector 128) equal upstream `pipelines/config.yaml` (sha256-pinned; checked by the tests) — `max_mu`
is a multiplier outside the checkpoint, so a wrong value would not be caught by the strict load.

## 2. Preprocessing `eldernet-prep-1` (WHOOP → model input)

1. Accelerometer only: first 300 i16 of each NPB1 second × 1/4096 → g, axes `ax, ay, az`, gravity kept.
2. Runs exactly as the HART path: duplicate second → error, clock reset → error, gap > 1 s → new run.
   **No imputation, no gap bridging, no "longest valid segment" selection, no edge-day dropping**: those
   upstream steps target multi-day files and would fabricate or discard motion here. Each contiguous run is
   processed on its own.
3. 100 → 30 Hz with the same resampler upstream uses. **Decided: reproduced exactly** — `actipy.processing.resample`
   is nearest-neighbour (no anti-alias filter); `preprocess.py` reproduces its index map bit-for-bit with Nara's own
   numpy code (no actipy code; the serve needs no pandas/actipy).
   **Caveat — aliasing.** Upstream *inference* is nearest-neighbour without anti-aliasing, but upstream
   *fine-tuning* resampled band-limited (`scipy.signal.resample` per 10 s window,
   `data_parsing/MOBILISE_D_parsing.py`). On Capture-24 the two disagree on is_gait for ~2.5 % of hop-5 windows
   (161 / 6,477 vs a polyphase anti-aliased resampler, three 3 h segments; gait windows 1,197 vs 1,200) with no
   accuracy loss on VAL (six VAL subjects; VALIDATION.md §1). WHOOP's content above 15 Hz is unmeasured: before
   any `candidate` use, compare nearest-neighbour vs anti-aliased on WHOOP walking (is_gait flip rate, cadence /
   speed shift).
4. 10 s windows (300 samples) on a grid anchored at the request `start_ts`, fully inside the run **and inside
   `[start_ts, end_ts]`** (`head_b64` / `tail_b64` seconds only extend the run, never add windows). **Decided:**
   hop 5 s served by default (`--hop-s` / request `hop_s` ∈ {1, 2, 5, 10}; 1 = upstream `window_overlap_sec` 9);
   edge margin 0 — the nearest-neighbour map has no transient, so a window reads exactly its own 10 s of samples.
   **Chunk boundaries:** the window that would straddle the end of one request and the start of the next (start
   `end_ts − 5` at hop 5) is never produced. The worker sends 1-hour chunks, so 1 of every 720 hop-5 windows is
   missing (719 per chunk) and the gait channel has no window for the 5 s after each chunk boundary (a window is
   held while its age is below `hop_s`, §5). Chunking otherwise changes nothing (every window is bit-identical
   whichever request it comes from).
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

Start: `python -m activity_context.eldernet.serve --weights-dir <dir> --upstream-dir <dir>` (or
`$ELDERNET_WEIGHTS_DIR` / `$ELDERNET_UPSTREAM_DIR`; the worker's child inherits the worker's environment). Both
are verified at start-up; a missing weights / source directory or file is `model_missing`, a size / sha256 /
state-dict mismatch of either is `weights_mismatch` (the message names the file), and the process stays up with
`model_available: false`.

ping → `{"id","op":"ping","ok":true,"model_available":bool,"model_status":"eldernet_loaded"|"eldernet_unavailable",
"model_error","model_id":"eldernet","model_version","weights":{name: sha256},"weights_digest","upstream_source":
{path: sha256},"upstream_commit","preprocessing_version","package_version",…}` — `weights_digest` is the §5
deployment digest of `weights` (pinned: `01b2f982a0a2664f455a529a8c483a10106a7ddcd89c326e3d15e24fa4cf4ca6`);
`upstream_source` the pinned sha256 of the upstream files the serve verifies (`LICENSE.md`, `models.py`). Both are
reported whether or not the model loaded. The infer response is unchanged.

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

* `python -m activity_context.eldernet.validate fit | test | prior | other-motion` — `fit`, `prior` and
  `other-motion` read VAL parts only; `test` opens TEST only inside the ledgered `TestVault`
  (`eval/eldernet/test_ledger.jsonl`); external sets go through `integrity_ext.evaluate_external_once`.
* **Spent experiments stay spent.** `integrity_ext.SPENT_EXPERIMENTS` (a reviewed constant) lists every experiment
  whose held-out payload has been opened: the frozen-split TEST `eldernet_frozen_detection_v1` (opened once at
  2026-10-06T18:12:48Z; its report and ledger line were lost in an SSD disconnect, so the ledger alone would allow
  a "first" run again) and the two external sets. For a listed experiment `test` / `evaluate_external_once` refuse
  before loading anything unless given an enumerated `--rerun-reason` (`inertia.integrity.RERUN_REASONS`:
  `artifact_lost_identical_rebuild`, `evaluator_bug_fix`, `post_audit_rule_change`, `provenance_rebuild`) and a
  `--rerun-detail`; the ledger line then written records the rerun and names the opening it repeats. The ledger is
  never edited; whether to re-run TEST (e.g. `artifact_lost_identical_rebuild` to regain a machine report) is the
  owner's decision.

## 8. Results and operating values (eval/eldernet/VALIDATION.md, VALIDATION.json)

* Parity: upstream toy example and three 3 h Capture-24 segments reproduce upstream bouts and metrics (detection
  agreement 1.000, quality within 3.6e-5). Through the upstream adapter (§ Licence) every head is bit-identical to
  the previously vendored copy, and the 3 h segments re-run byte-identical.
* Served defaults: no calibration, `gait_threshold` 0.5 (upstream argmax). VAL fit (`eval/eldernet/calibration.json`,
  `--calibration`): T = 1.047 (free-living; ≈ upstream already calibrated), high-precision threshold 0.93.
* Detection (served defaults). **Frozen-split TEST: transcribed from non-persisted console output of the single
  TEST run by the agent; not machine-verifiable** (the run's report and ledger line were lost in an SSD
  disconnect); counts and hashes are consistent (test_sha256 `677165e7…`, calibration `cal:16191350862fb8de`):
  Capture-24 TEST P 0.88 / R 0.52 (free-living, AUROC 0.967). External sets (machine reports and ledger lines
  present): GOTOV older adults P 0.97 / R 1.00; OxWalk P 0.98 / R 0.87. Steps per 10 s window on OxWalk: MAE 1.0
  (bias −0.3). GOTOV speed / cadence ordered slow < normal < fast in 19 / 21 and 20 / 21 participants.
* Decoder π: **0.085 recommended** — the mean served `gait_prob` over all 376,755 Capture-24 VAL windows at hop 5
  (20 subjects; unlabelled and pre-filtered windows included; subject-bootstrap 95 % CI 0.076–0.095; per-subject
  0.056–0.130). That value makes the gait channel mean-neutral over the windows the decoder actually sees
  (E[q/π] = E[(1 − q)/(1 − π)] = 1). The labelled-window gait prevalence is 0.065 (0.125 if pre-filtered windows
  are excluded); with π = 0.065, E[q/π] = 1.31 — a standing pull toward gait, because the unlabelled (33 % of
  windows, mean q 0.096) and masked (7 %, mean q 0.227) windows the decoder also sees are left out. VAL only
  (`validate prior`; VALIDATION.json `decoder_prior`). Setting π is the decoder's / owner's call.
* Gait-row compat, VAL (`validate other-motion`; VALIDATION.json `val_other_motion`): running / jogging windows
  (WISDM jogging, MHEALTH jogging + running, PAMAP2 running: n 351, 11 subjects; Capture-24 VAL has none) get
  mean `gait_prob` 0.096, median 0.055, 3.4 % ≥ 0.5, and 68 % lie at or below π = 0.085 — ElderNet does not call
  running gait, so `run` in the gait row would be pushed down on most running seconds (keeping it neutral matches
  the data). Cycling (n 3,462: mean 0.061, median 0.032, 0.8 % ≥ 0.5) and vehicle (n 14,183: mean 0.091, median
  0.028, p90 0.27, 2.9 % ≥ 0.5) behave as non-gait.
* Deployment weights digest (§5 definition; ping `weights_digest`):
  **`01b2f982a0a2664f455a529a8c483a10106a7ddcd89c326e3d15e24fa4cf4ca6`** (`weights.DEPLOYMENT_WEIGHTS_DIGEST`,
  asserted in `tests/eldernet/test_eldernet_upstream.py`). Verified 2026-10-06 against the other two definitions:
  Swift `GaitQualityModelInfo.weightsCanonicalText` (same text, recomputed in Swift: same digest) and the SQL text
  `publish_activity_gait_windows_day` hashes (`'eldernet-weights-1' || chr(10) || string_agg(key || '=' || value ||
  chr(10) … order by key collate "C")`: the same bytes for these ASCII names). `FRWHOOP_ELDERNET_WEIGHTS_SHA256`
  pins it.
* Serve: ~650 MB RSS, ~1.7–1.9 ms per window per head on one thread with NNPACK disabled (as served; NNPACK on is
  71–74 ms, 39–44× slower, outputs within 7.6e-6 logits / 3.8e-5 steps/min); keep hop 5 and <= 1 h requests under
  the 60 s timeout. At 1-hour chunks one hop-5 window per chunk boundary is not produced (1 of 720; §2.4).

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
