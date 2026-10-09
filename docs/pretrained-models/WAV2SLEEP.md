# wav2sleep, PPG-only: shadow sleep-stage adapter (Spec 03, candidate 2)

**Status:** the adapter is implemented, shadow-only, off by default and unregistered. It matches the official
code bit for bit on synthetic fixtures at 24 and 25 Hz (all 11 real-weight tests pass, 2026-10-08). "Bit for bit"
means against the official route with `max_length_hours` set to the run length. Against the official 10-h default
padding, agreement is only 395/960 (24 Hz) and 398/960 (25 Hz); that is deviation D1, §8.1. **Activation is deferred.** No anchored overnight PPG reaches the
server yet, and there is no sleep-stage evaluation set with a PPG waveform. Nothing here is evidence
that the model stages WHOOP sleep correctly.

| | |
| --- | --- |
| Provider | `wav2sleep.ppg-only.v1`, metric `sleep_stage`, mode `retrospective`, release mode `shadow` |
| Code | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/` (adapter), `.../wav2sleep_vendored/` (MIT model code) |
| Tests | `Tools/InferenceWorker/tests/test_wav2sleep_*.py` |
| Enable | `FRWHOOP_WAV2SLEEP_SHADOW_ENABLED=1` (exactly "1"); thread cap `FRWHOOP_WAV2SLEEP_THREADS` (default 1, max 4, never above Spec 01's `FRWHOOP_INFERENCE_MATH_THREADS`) |
| Registered | No. The one-line registration and the manifest update are fragments in [integration/wav2sleep.md](integration/wav2sleep.md) |
| Consumer | `sleep_stage_shadow_comparison`, proposed. It compares these epochs with the canonical stager's epochs for the same night. It never shows the result to users. |

## 1. Identity

Each of these is a separate fact, recorded as a separate field:

| Field | Value |
| --- | --- |
| Code repository / commit | `https://github.com/joncarter1/wav2sleep` @ `278e30463c8149c4e6899b8784da492fec695bd9` (2026-07-16) |
| Model code identical since | `8b2a7b1ca5caab4fe7efcf75faa0a125f5ea24c4` (2026-02-02); git blob ids of every vendored file are unchanged from then to 278e3046 |
| Weights repository / revision | `https://huggingface.co/joncarter/wav2sleep` @ `18fc32f095f10c1f7a91a56298e7598d02c58529` (2026-02-02T13:11:06Z) |
| `state_dict.pth` | 9,666,562 bytes, sha256 `ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc`; 177 float32 tensors, 2,391,172 parameters |
| `config.yaml` | 749 bytes, sha256 `b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509`, git blob `f5a5bcc1` |
| License | MIT (code `LICENSE`; model card `license: mit`) |
| Artifact paths | `<model root>/wav2sleep/278e3046/{state_dict.pth,config.yaml}`. These are the existing manifest paths. The directory name is a storage key only; identity is the sha256. |

**Correction to the manifest.** The manifest's `revision: 278e3046...` is the GitHub code commit, not a
Hugging Face revision: `.../resolve/278e3046.../state_dict.pth` returns 404. The pinned bytes come from
Hugging Face commit `18fc32f0`, and both size and sha256 match the pins exactly. Hugging Face HEAD
(`8b6e46ab`, a README-only change) serves the same bytes. The earlier upload (`b0d9856c`) is a
different checkpoint and is not used. How the code commit was matched to these weights is set out in
`wav2sleep_vendored/PROVENANCE.md` §1: config blob identity, upload timing, unchanged blobs, strict
load and bit-identical outputs.

Every response carries three digests: `input`, `artifact` and `preprocessing`. It also carries
`cache_key = sha256(input, artifact, preprocessing)`.

- `input` covers the window, the context identity, the run boundaries and configuration identities,
  and the raw int64 samples. Re-chunking the same samples does not change it; changing one sample
  does.
- `artifact` covers the weights and config sha256, measured from the loaded bytes, plus the vendored
  model code, measured from disk.
- `preprocessing` covers the preprocessing parameters, the active gates (including any override) and
  the preprocessing code measured from disk.

## 2. Sampling contracts

| | Native (WHOOP) | Model (pinned code) |
| --- | --- | --- |
| Signal | optical PPG, absolute ADC counts (anchor + cumulative deltas) | `PPG` |
| Rate | the declared native rate r, 25 (anchored v26) or 24 (legacy) samples/s; sample j at `start_unix + j/r`; the next second owns point r+1 | 1024 samples per 30-s epoch = 34.133 Hz (`settings.COLS_TO_SAMPLES_PER_EPOCH['PPG']`) |
| Grid | whole seconds | `k * 30/1024` s, k = 1..1024n, from the run's epoch origin; this is the pinned `process_waveform_dataframe` target index |
| Max length | the window is at most 10 h | 1200 epochs (`TRAINING_LENGTH_HOURS = 10`) |

Resampling is linear interpolation in time, which is the pinned `interpolate_index(method='index')`
path, followed by a float32 cast. It only makes the tensor the right shape. It adds no bandwidth and
is not accuracy evidence. Native resolution stays explicit: every epoch records its native-sample
provenance.

## 3. Required channels and refusals

- **PPG only.** ECG, ABD and THX are left out of the model input dict. This is the official
  `predict_on_folder(signals=['PPG'])` route. The official `-inf`-masked route gives the same result
  to within 3.6e-6 in the logits.
- If a request contains any ECG/ABD/THX/respiration member, it is refused with
  `channel_not_admitted`.
- **A respiration or RSA waveform derived from the same PPG is refused by name**
  (`derived_respiration_refused`). It is never a measured chest or abdominal effort signal.
  Tests: `test_ppg_derived_respiration_is_refused_as_measured_effort`,
  `test_declared_signal_list_with_a_derived_thx_is_refused`, `test_model_input_is_ppg_only`. The
  last one checks with a spy that every forward receives only the `PPG` key.

## 4. Input contract (the Spec 01 anchored transport)

The request `input` reuses the PPG section the worker builds for `sensor.biomarkers.v1`
(docs/sensor-biomarkers/CONTRACTS.md §4). It adds the Spec 01 segment members (`run_id`,
`config.identity`, `config.known`, `clock`; Spec 01 branch, docs/model-integration/README.md).

```json
{"window": {"start_utc": 1780902000, "end_utc": 1780930801},
 "input_revision": "sha256:<object digests>",
 "ppg": {"native_rate_hz": 25, "units": "adc_counts",
         "withheld_seconds": {"missing_ppg_anchor": 0},
         "segments": [{"start_unix": 1780902000, "duration_s": 300, "samples": [380412, "..."],
                       "sample_count_per_second": 25, "run_id": "r-1",
                       "config": {"stable": true, "identity": "srcA=2;drvA=40;led=green", "known": true},
                       "clock": {"packet_timing_verified": true, "samples_per_second": 25,
                                 "source": "...", "grid": "...", "endpoint": "..."}}]}}
```

Rules:

- The night is withheld on any transport-integrity failure. Gaps between valid runs are normal and
  become masked epochs.
- Segments are joined only when they share a `run_id` and are contiguous in time. Segments with
  different `run_id`s are never joined, even when they touch. A segment without a `run_id` is its own
  run.
- If no segment has a `run_id` (the legacy shape), the request is refused.

The member names are the ones Spec 01 pinned in docs/model-integration/README.md, "PPG segments"
(Spec 01 branch, commits ff143411e and 0fd8b94d3):

- **Native rate.** It is what the request declares. `ppg.native_rate_hz` must be in
  `SUPPORTED_NATIVE_RATES_HZ` = {24, 25}, and must equal every segment's `clock.samples_per_second`
  and `sample_count_per_second`. Anchored v26 segments use 25 Hz (the anchor plus 24 deltas, with
  the next record's anchor as the 26th point); 24 Hz is the earlier convention. Nothing downstream
  assumes either value.
- **Clock.** `clock.packet_timing_verified` must be `true`. `clock.source`, `grid` and `endpoint`
  are provenance only: they are carried into the output and never gated on. A segment without
  `clock` is the legacy shape.
- **Configuration.** `config.identity` is `"unknown"` with `config.known = false` when the transport
  cannot identify the configuration. That is withheld (`optical_config_unidentified`) because
  channel, LED and polarity matter to this model.
- **Runs.** A gap or an identity change inside one `run_id` splits the run there, never joins it,
  and is counted as `ppg_run_id_discontinuity` in the diagnostics.

The test `tests/test_wav2sleep_spec01_shape.py` feeds a segment shaped like Spec 01's golden
envelope (`tests/wav2sleep_spec01_segment_shape.json`, provenance inside).

Withheld reasons (`diagnostics.reason_detail` → wire `withheld_reason`):

| Detail | Wire | When |
| --- | --- | --- |
| `lane_disabled` | `not_ready` | flag not "1"; nothing is parsed |
| `artifact_missing` / `artifact_size_mismatch` / `artifact_sha256_mismatch` / `state_dict_mismatch` / `config_mismatch` | `blocked_artifact` | before or while loading (section 7) |
| `missing_ppg_anchor` | `blocked_input` | `units` is not `adc_counts`, or no segments arrived while the producer reports anchor-less seconds |
| `legacy_deltas_suspected` | `blocked_input` | every sample of a run fits i16 and the median is near zero (un-anchored deltas sent as samples) |
| `no_ppg_segments` | `blocked_input` | no PPG segments arrived |
| `missing_run_id` | `blocked_input` | no segment carries `run_id` (the legacy shape) |
| `unverified_sample_clock` | `unverified` | a segment lacks `clock`, or `clock.packet_timing_verified` is not `true` |
| `clock_rate_mismatch` | `blocked_input` | `clock.samples_per_second` differs from `ppg.native_rate_hz` |
| `optical_config_identity_missing` | `blocked_input` | `config.identity` is absent |
| `optical_config_unidentified` | `unverified` | `config.identity` is `"unknown"`, or `config.known` is not `true` |
| `optical_config_changed` | `blocked_input` | `config.stable` is not `true` |
| `overlapping_segments` / `unsorted_segments` | `blocked_input` | overlapping pieces, or pieces out of time order |
| (no refusal) | — | a gap or a `config.identity` change inside one `run_id` splits the run there and is counted as `ppg_run_id_discontinuity` in the diagnostics |
| `invalid_segment` / `unsupported_native_rate` | `blocked_input` | the sample count is not `duration_s × native_rate_hz`, or the declared rate is not in {24, 25} or differs from `sample_count_per_second` |
| `nonfinite_samples` / `non_integer_samples` / `saturated_samples` | `blocked_input` | NaN or inf, fractional counts, or values on or beyond the signed 20-bit rails or flagged saturated |
| `channel_not_admitted` / `derived_respiration_refused` | `blocked_input` | section 3 |
| `night_too_long` | `blocked_input` | the window is longer than 10 h; nothing is silently truncated |
| `invalid_window` / `too_many_segments` / `unknown_config` / `provider_id_mismatch` | `blocked_input` | |
| `no_stageable_run` / `insufficient_overnight_coverage` | `insufficient_coverage` | gates (section 6) |
| `nonfinite_model_output` | `provider_error` | every staged run returned non-finite logits |

## 5. Preprocessing (revision `wav2sleep-ppg-preprocessing/1.0.0`)

Each contiguous run is one official "recording":

1. Start at the run's first UTC 30-s boundary `t0`, using relative times `j/rate`, where `rate` is
   the run's declared native rate (24 or 25).
2. Stage `n = floor((t_last - t0)/30)` whole epochs. Epoch e uses the pinned grid points
   `(30e, 30(e+1)]`. Its last point is the next second's first native sample, so a run's final
   epoch is staged only when that sample belongs to the run.
3. Interpolate with `np.interp`. This is bitwise the vendored pinned `process_waveform_dataframe`
   with `max_length_hours = n*30/3600`.
4. Cast to float32.
5. Apply the pinned non-causal z-score `_zscore_normalize`: torch mean, unbiased std, 1e-6 floor.
6. Forward `{'PPG': x}`.

The z-score and the forward both run under the thread cap.

## 6. Classes, outputs and gates

**Class meanings** come from the pinned `settings.INTEGER_LABEL_MAPS[4]` and
`data/utils.convert_int_stage`. The order is `wake, light, deep, rem`:

- wake = W
- light = N1 + N2
- deep = N3 (legacy N4 is scored as N3)
- rem = REM

The label space is `wav2sleep/wake-light-deep-rem`. It is namespaced on purpose, so it cannot be
mistaken for the canonical four-stage display contract or merged with SleepECG's `wake/rem/nrem`.

**Outputs.** In an `ok` response:

- `raw_scores` holds columns on the window's UTC 30-s grid: `epoch_start_utc`, `mask`,
  `mask_reason`, `run_index`.
- Three blocks of different types sit beside those columns:
  - `probabilities`: `class_probabilities`, softmax of the logits, `calibrated: false`, 6 decimals
  - `logits`: the model's output exactly, 5 decimals
  - `labels`: `argmax_label`
- Masked epochs are `null` in all three blocks.
- `result.stages` holds the argmax label runs. Each run is tagged with `label_space` and
  `release_mode`.
- The registry shim's scalar `value` is the number of scored seconds. It is a coverage summary, as
  in the sibling SleepECG candidate, and never a sleep metric.
- The response contains no apnea or respiratory events, no canonical stage fields and no
  user-facing values.

Mask reasons:

| Reason | Meaning |
| --- | --- |
| `no_ppg` | gap |
| `run_edge_partial_epoch` | the epoch is only partly covered by its run |
| `run_too_short` | the run is shorter than `min_run_epochs` |
| `flat_signal` | the run's native std is below 0.001 (the pinned ingest's flat-PPG rule). Upstream applies it in EDF physical units; on integer ADC counts it fires only on a perfectly flat run. **There is effectively no signal-quality gate**, and one must be defined before activation (gate 3) |
| `nonfinite_model_output` | the model returned non-finite values for the run |

**Supported window and quality gates.** These are provisional. They were not tuned, because there is
no evaluation set.

| Gate | Default | Why |
| --- | --- | --- |
| `max_window_seconds` | 36,000 s (1200 epochs) | the official max sequence (`TRAINING_LENGTH_HOURS = 10`) |
| `min_run_epochs` | 240 (2 h contiguous) | about the sequence mixer's two-sided receptive field (2 blocks × ±62 epochs = 249) |
| `min_valid_epochs` | 480 (4 h scored) | an overnight comparison needs most of a night |
| `min_coverage_fraction` | 0.75 of the window's whole epochs | |
| `max_segments` | 2,400 | bounds parsing work |

A request may override a gate within bounds. The override is recorded and enters the cache key.
The official model constants cannot be overridden.

## 7. Artifact verification

The checks run in this order:

1. Both files must exist.
2. Size and sha256 must equal the pins. This is checked before any byte is parsed.
3. The config is read with `yaml.safe_load` and built through an allowlist of the four `_target_`
   classes. Hydra directives are refused. The config must be 4-class and non-causal, and PPG must map
   to its own encoder.
4. The weights are read with `torch.load(weights_only=True, map_location='cpu')`. The checkpoint must
   be a flat float32 mapping whose keys and shapes equal the model's `state_dict()` exactly. It is
   then loaded with `load_state_dict(strict=True)`.
5. The model is put in `eval()` with `requires_grad_(False)`.

Nothing is trained, fine-tuned or calibrated.

Readiness:

- Disabled lane: ready. It never changes the process readiness flag.
- Enabled lane: ready only after the artifacts verify and load strictly (warm-loaded). Otherwise
  `blocked_artifact: <detail>`.

## 8. Deviations from the official code

Details and evidence are in `wav2sleep_vendored/PROVENANCE.md` §3.

| # | Deviation |
| --- | --- |
| D1 | No zero-padding to 10 h. The pinned grid ends at the run's last whole epoch. On the 8-h synthetic night, the official default padding agrees with the unpadded official run on only 395/960 epochs at 24 Hz and 398/960 at 25 Hz, because raw zeros next to a ~3.8e5-count DC dominate the z-score. (The v2 references reported 398 at both rates; the 24 Hz figure there was the 25 Hz night, see §9.) Why no padding rather than padding after normalisation: §8.1. |
| D2 | Each contiguous run is its own recording. The official `dropna()` + interpolation would bridge gaps. |
| D3 | `yaml.safe_load` + an allowlisted builder instead of `yaml.CLoader` + `hydra.instantiate`. The checkpoint gets an explicit key/shape check before the strict load. |
| D4 | `np.interp` instead of the pandas interpolate path. Bitwise equal (tested). |
| D5 | Logits and `softmax(logits)` are returned as well. The official API returns only argmax. |
| D6 | The z-score and forward run under a fixed thread cap (default 1). torch's float32 reductions round differently across thread counts, by one float32 ulp of the mean. |
| D7 | Absolute ADC counts are used as given, which is the official CSV/parquet path. The EDF [-1, 1] scaling would change probabilities by at most 1.2e-4 at 24 Hz and 1.7e-4 at 25 Hz, and no argmax. |
| D8 | ECG/ABD/THX are absent rather than `-inf`. Both routes are official, and they differ by at most 3.6e-6 in the logits. |

### 8.1 D1: which padding is the faithful contract

The official code offers two behaviours for a night shorter than 10 h:

- **Official default** (`max_length_hours=10`): pad raw values with zeros to 10 h, then z-score the padded
  vector. In training the PSG pleth came from EDF files scaled to [-1, 1] by the header range, so a zero there
  sits inside the signal's range. WHOOP gives absolute ADC counts with a ~3.8e5 DC level, and a raw zero is far
  outside it. Reproducing this is not faithful to what the model saw.
- **`max_length_hours` set to the run's length**: no padding; the z-score covers only real samples. This is a
  public parameter of the pinned API.

Two Nara options were compared on the synthetic fixtures (`_build-scratch/spec03-physio/d1_padding.py`,
`pof-isolation/d1_padding.json`):

- **A**: no padding (the adapter today, the second official behaviour).
- **B**: z-score the real samples, then zero-pad the *normalised* tensor to 1200 epochs.

The yardstick is consistency, not accuracy: truncate the 1199-epoch 10-h fixture to N epochs, and count how
often each option's argmax on epochs [0, N) equals the model's own argmax for the same epochs when it sees the
complete night (which needs no padding). "O" is the official default reproduced in the adapter's environment.

| Rate | Truncated to | A (no padding) | B (normalise, then pad) | O (raw-zero pad) |
| --- | --- | --- | --- | --- |
| 24 Hz | 4 h (480) | 326 | 305 | 256 |
| 24 Hz | 6 h (720) | 653 | 533 | 366 |
| 24 Hz | 8 h (960) | 651 | 607 | 333 |
| 24 Hz | 9 h (1080) | 844 | 781 | 368 |
| 25 Hz | 4 h (480) | 343 | 294 | 264 |
| 25 Hz | 6 h (720) | 695 | 510 | 413 |
| 25 Hz | 8 h (960) | 695 | 648 | 405 |
| 25 Hz | 9 h (1080) | 902 | 807 | 367 |

On the 8-h and gapped fixtures themselves, B agrees with A on 739/960 and 770/960 epochs (24 / 25 Hz) on the
8-h night, and on 154–284 of the gapped runs' epochs.

**Decision: keep A.** It is an official behaviour, it never feeds the model values the pinned code would not
produce from the same samples, and it is the most consistent option at every length and both rates. B
invents a padding convention that neither the code nor the training data defines.

**Caveat that matters for any activation.** Even A agrees with the complete-night output on only ~68–72 % of
epochs at 8 h. The non-causal z-score and the sequence mixer make every epoch's output depend on how much of
the night the model sees. A night split by a gap is staged as two shorter recordings and will differ from the
same night seen whole. This is synthetic-signal evidence only; it is one more reason the evaluation-set gate
must be met before any comparison is trusted.

## 9. Parity with the official code

Setup:

- **Reference.** The pinned code was imported from the clone with `-I -B`, appended to `sys.path`
  and never run from the download directory. It ran in a scratch venv installed with hashes from
  the official `uv.lock` (torch 2.10.0, numpy 2.3.5, pandas 2.3.3, hydra-core 1.3.2, numba 0.63.1)
  and again with torch 2.14.1.
- **Path.** Each run went `process_waveform_dataframe` → parquet → `ParquetDataset(...)[0]` →
  `load_model(folder)` → forward.
- **Adapter.** The sidecar env (`uv sync --frozen`).
- **Fixtures.** Deterministic SYNTHETIC PPG-like signals at 24 and 25 Hz, shaped like Spec 01 segments
  (`tests/wav2sleep_fixtures.py`).

| Fixture | Epochs | resampled | z-scored | max abs prob diff | max abs logit diff | argmax agreement |
| --- | --- | --- | --- | --- | --- | --- |
| 8 h, one run | 960 | bit-identical | bit-identical | 0 | 0 | 960/960 |
| gapped night, run 0 | 499 | bit-identical | bit-identical | 0 | 0 | 499/499 |
| gapped night, run 1 | 399 | bit-identical | bit-identical | 0 | 0 | 399/399 |
| 10 h, one run | 1199 | bit-identical | bit-identical | 0 | 0 | 1199/1199 |

Further results:

- Official `predict_on_folder(signals=['PPG'], max_length_hours=8)` run end to end matches the
  adapter's argmax on 960/960 epochs at 24 Hz and at 25 Hz, each night with its own `prepare()` cache.
- **The earlier 24 Hz failure (899/960) was a harness bug, now fixed.** The pinned `prepare()` returns one
  shared cache folder and `load_dataset` stages every night in it, in unsorted `glob` order. The v2
  references ran the 25 Hz night first, so the 24 Hz call staged both nights and its first prediction was
  the 25 Hz night (899/960 is exactly the cross-rate agreement of the two direct routes). Run alone, each
  rate agrees 960/960. Evidence: `_build-scratch/spec03-physio/pof-isolation/report.json`;
  `wav2sleep_vendored/PROVENANCE.md` §6. References are now `reference-v3`
  (`official_reference_v3.py`), and the test refuses a reference whose `predict_on_folder` dataset held
  more than one night. No expected value was changed.
- The official `-inf` route stays within 3.6e-6 of the absent route in the logits.
- Threads 1 vs 2 with real weights: 0 difference on this fixture.

**Diagnostics** (not gates):

- Flipping the PPG sign changes 353/960 argmax epochs at 24 Hz and 316/960 at 25 Hz (max probability
  change 0.97 / 0.99). The checkpoint is polarity-sensitive, and the polarity of WHOOP's raw optical channel relative to PSG oximeter
  pleth is unverified.
- The EDF-style [-1, 1] scaling changes probabilities by at most 1.2e-4 (24 Hz) / 1.7e-4 (25 Hz), no argmax.

To reproduce, see the scripts in `_build-scratch/spec03-physio/` (not committed):

1. `make_fixtures.py`: fixtures to npz.
2. `official_reference_v3.py`: run in the official-lock venv, output `reference-v3/`.
3. `test_wav2sleep_real_weights.py`, run with `FRWHOOP_WAV2SLEEP_MODEL_ROOT` and
   `FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE` set, and `-s` to print the numbers.

## 10. Resources (one 10-h PPG-only night, 1199 epochs)

Measurements:

- Fresh process per configuration.
- Apple M4 Max (arm64), torch 2.14.1.
- The machine had a load average of about 20 from other jobs.
- **Not measured on the Droplet.**

| | threads = 1 | threads = 2 |
| --- | --- | --- |
| Model load (verify + build + strict load) | 0.05–0.09 s | 0.05 s |
| `infer` wall time (parse → JSON-ready response) | 0.74–0.93 s | 0.49–0.69 s |
| `infer` CPU time | 0.78–0.83 s | 0.83–0.98 s |
| Peak RSS, whole process (Python + torch + model + parsed 7 MB request) | 1,284–1,287 MB | 1,285–1,302 MB |
| Of which forward activations | ~0.89–0.90 GB (the official code measured the same: 0.886 GB at torch 2.10) | ~0.89 GB |

Other measured sizes:

- Request JSON for 10 h: 6.96 MB. The worst case with signed 20-bit values is under 7.0 MB, which
  fits under the sidecar's 8 MiB `MAX_BODY_BYTES`.
- Response JSON: about 160 KB.

**Implications for the 4 vCPU / 8 GB Droplet** (estimates, not measurements):

- **CPU.** Expect about 1 CPU-second per night at 1 thread. A shared x86 vCPU may be 2–4× slower
  for these convolutions, so plan for roughly 2–4 s per night, which is comfortably inside the 20-s
  request budget. A thousand nights a day would be on the order of one CPU-hour. Capping at
  1 thread keeps it to a single vCPU.
- **Memory.** The binding constraint is about 0.9 GB of transient activations per forward on top of
  the sidecar's resident set. The adapter allows one forward per process (semaphore) and enforces
  `max_epochs = 1200`, so the peak is bounded at about 1.3 GB for the sidecar process. It must not
  coincide with other heavy model loads in the same process. Run it in the Spec 01 bounded worker
  process with a memory limit of about 1.6 GB.
- **Spec 01's bounds supersede the snapshot below.** Spec 01's unit sets `MemoryHigh=2G` for the whole sidecar
  (`deploy/frwhoop-inference.service:37` on its branch), with one shared infer worker
  (`FRWHOOP_INFERENCE_MAX_ACTIVE` 1).
  - The table above measured a whole-process peak of about 1.29 GB per fresh process, including a parsed 7 MB JSON
    request.
  - A warm in-process re-measurement on 2026-10-08 (no JSON parsing; `_build-scratch/spec03-physio/warm_rss_20261008.json`)
    peaked at 686 MB after calls 1 and 2 and at 924 MB after call 3. Peak memory is not flat across calls.
  - The independent review reported a second warm call above 1.3 GB, which was not recorded in a file and is not
    reproduced here.
  - Either way, one wav2sleep forward can take most of a 2 GB unit. Registration (Phase B) needs either a
    dedicated lane or measured headroom under 2 GB on the Droplet.
  - The adapter's thread cap now also obeys Spec 01's `FRWHOOP_INFERENCE_MATH_THREADS`: the lower of the two wins.
- **Fit against the Droplet snapshot (pre-Spec 01).** The eligibility agent recorded the Droplet in
  [ELIGIBILITY.md](ELIGIBILITY.md): the sidecar unit has `MemoryMax` 3 GiB, uses 835 MB and has
  `CPUQuota` 150%. In process, one forward would take the sidecar to roughly 1.8–1.9 GB, which is
  inside that limit. That leaves about 1.1 GB for any other heavy provider running at the same
  moment. A cap of 1 thread fits the 1.5-vCPU quota. These figures are inferred from that snapshot,
  not measured with wav2sleep running.

## 11. Head-to-head and gate status

| Comparison | Result |
| --- | --- |
| wav2sleep PPG-only vs canonical stager vs SleepECG on a WHOOP sleep-stage reference | **No evaluation set; activation deferred.** sleep-accel has HR only, and no WHOOP night has a PPG waveform with reference stages. No accuracy is claimed. |

Spec 03 admission gate for wav2sleep:

| Gate | Status |
| --- | --- |
| Spec 01 PPG transport fixed (anchor, clock provenance, config identity, run identity, saturation) | **Not met.** The segment members are agreed on the Spec 01 branch, but no anchor reaches the server yet. |
| Contiguous overnight waveform with verified clock and quality | **Not met.** There is no overnight raw-optical capture, and the default capture policy is out of scope. |
| CPU budget | **Measured locally only** (section 10). The Droplet is unmeasured. |
| An actual sleep-stage evaluation set | **Not met.** |

The remaining activation gates, in order:

1. The Spec 01 transport lands and is deployed (anchored samples, `run_id`, `config.identity` and
   `config.known`, verified `clock`).
2. Contiguous overnight PPG is captured. Today's capture policy does not produce it.
3. The WHOOP optical polarity and wrist-vs-finger PPG domain are characterised.
4. An evaluation set with reference stages for WHOOP nights is assembled. Promotion would be judged
   on the final four-class output, abstention, coverage and runtime on that set.
5. CPU and memory are measured on the Droplet inside the Spec 01 bounded worker process.
6. The consumer is built: the shadow comparison store and job, plus the registration, identity and
   manifest fragments.

Until then the adapter stays registered-off (or unregistered), shadow-only and non-publishable.

## 12. Keep or remove the dormant adapter (recommendation; the owner decides)

The adapter was written before its candidate's gates were met, which Spec 03 did not ask for. Assessment on
2026-10-08:

**Is the dormant code safe?**

- **Unreachable in production.** Nothing registers it: `server.py`, `providers/__init__.py` and
  `registry_adapter.py` do not mention wav2sleep (checked with `git grep`). Even with
  `FRWHOOP_WAV2SLEEP_SHADOW_ENABLED=1` set, no route calls it. Registration is a separate edit to Spec 01's
  files (`integration/wav2sleep.md`).
- **No new dependencies.** It uses the sidecar's existing torch, numpy and PyYAML; `pyproject.toml` and
  `uv.lock` are unchanged.
- **Fails closed.** A disabled lane parses nothing and reports `not_ready`. An enabled lane refuses
  unverified artifacts, legacy un-anchored deltas, unverified clocks, unknown optical configuration and
  derived respiration (§4).
- **What the code does not do.** `ACTIVATION_GATES` is reported in every response as `promotion_blocked_by`,
  but nothing checks it. The gates are enforced by the lane staying unregistered, not by code.
- **Size.** About 400 KB of source (adapter plus vendored MIT model code), and about 2 minutes of extra test
  time with artifacts (none without).

**Is it useful?** Yes, if the owner expects to meet the gates. The bit-exact parity harness, the artifact
pins and the corrected manifest fragment took most of the effort and would have to be redone. The D1 and
`predict_on_folder` findings (§8.1, §9) are also recorded here.

**Recommendation:** keep it dormant and unregistered on this branch. Do not merge it to `main` until the
owner has decided on the capture policy and an evaluation set (gates 2 and 4). If either is ruled out, delete
`frwhoop_sleep/wav2sleep/`, `frwhoop_sleep/wav2sleep_vendored/` and `tests/test_wav2sleep_*` together, and
keep this document as the record.
