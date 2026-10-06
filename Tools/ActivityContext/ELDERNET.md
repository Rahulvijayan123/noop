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
3. 100 → 30 Hz with the same resampler upstream uses (reproduced exactly or called directly; the audit records
   which and its parity against `pipelines.general`).
4. 10 s windows (300 samples) on a grid anchored at the request `start_ts`, hop per upstream (`window_overlap_sec`),
   fully inside the run and clear of resampler edge transients.
5. Upstream auto-calibration / non-wear detection: applied only if valid on a single run (decided by the audit;
   default off, recorded in the manifest). Wear is Nara's own evidence.

## 3. Gait detection made window-local

Upstream skips windows below a recording-relative Otsu variance threshold (capped at an absolute static
ceiling) before the classifier. That makes one window's answer depend on the rest of the request. Nara uses a
fixed, documented static pre-filter (the upstream absolute ceiling) so every window's output depends only on
that window — deterministic and chunking-independent — and the audit measures the difference against
upstream on whole recordings.

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

`ActivityObservation` gains an optional ElderNet window (never `encoder` / `classProbs`, never the Inertia
slot). `ActivityDecoderConfig.gaitQuality: GaitQualityEvidenceConfig? = nil`; nil ⇒ output, snapshot and
`cacheTag` byte-identical to today.

* Gait evidence: `gait_prob` → likelihood ratio `q/π` (π = gait prevalence on the calibration set) through a
  fixed compat over body modes (gait = walk, briskWalk, stairs; non-gait = bedRest, seated, upright, vehicle,
  cycling; run, otherExercise and the four transition modes neutral; unknown 1), tempered, with
  `isEvidence:false`, and discounted for redundancy with HART and Inertia locomotion (same accelerometer).
* Brisk walking: walk vs briskWalk may be split by a validated cadence or speed rule only when the validation
  supports it (default weight 0 = logged only).
* Speed, cadence, stride length, regularity, steps: **reported**, not evidence in v1 — the published state and
  intervals carry a `gait` block (ElderNet metrics over the current walking stretch, with provenance) only when
  the decoder's posterior is gait and ElderNet detected gait.
* Missing / failed / malformed windows ⇒ channel omitted. Provenance stamped only when the channel is used.

## 6. Worker (shadow first)

A third isolated `ActivityPythonService` running `activity_context.eldernet.serve`; off unless
`FRWHOOP_ELDERNET_ENABLED=1`; never in the readiness gate; failures counted and absorbed; HART payloads
unchanged. Shadow: compact per-window gait windows stored in their own table; candidate: a second decode with the
gait channel, stored beside the shadow row, never published.

## 7. Validation (weights frozen; Nara fits at most a calibration on VAL subjects)

Gait detection P/R/F1, calibration and risk-coverage vs walking labels on the frozen wrist test subjects
(WISDM, HHAR, PAMAP2, MHEALTH, Opportunity, Capture-24, GOTOV; OxWalk if obtainable); cadence and steps vs
annotated steps where available (OxWalk); speed ordinal checks (GOTOV slow < normal < fast); parity with
upstream `pipelines.general` on whole recordings; latency/RAM. Splits are the frozen subject splits in
`Tools/ActivityContext/splits/`.
