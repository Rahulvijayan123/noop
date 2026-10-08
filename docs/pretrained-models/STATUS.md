# Spec 03 status: pretrained-model additions

Status as of 2026-10-08. Branch `feat/spec03-pretrained-models-20261007`, cut from `nara/main` at dab2124f3.

For a handoff to another model, start with [HANDOFF.md](HANDOFF.md).

Nothing is pushed, merged, deployed or registered. The two WIP commits on the branch (3651c3c08, 064e7538d) are checkpoints, and no independent reviewer has run on them yet. Spec 01's shared files are untouched: the branch only adds files and changes two of its own docs. Proposed changes to shared files are fragments under `docs/pretrained-models/integration/`.

## Summary

| Candidate | Decision | In the repo | Still blocking |
|---|---|---|---|
| ActiNet, Walmsley classifier (sleep / sedentary / light / MVPA) | Adapter built and tested. Shadow only. Activation deferred. | `Tools/ActivityContext/activity_context/actinet_classifier/`, 46 tests, golden fixtures | Owner licence decision. Consumer and shadow store. `ACTINET_CLASSIFIER.md` and the integration fragment are not written. The head-to-head compared the wrong bundle (see below). |
| wav2sleep, PPG only | Adapter built and tested. Off by default. Not registered. | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/` plus vendored model code, `WAV2SLEEP.md`, integration fragments | Spec 01 PPG transport deployed. Overnight contiguous PPG. WHOOP optical polarity. A PPG sleep-stage evaluation set. Droplet measurement. A consumer. |
| ActiTect / RBDisco | Deferred. Nothing built. | Eligibility evidence only | The WHOOP-to-training axis frame cannot be established. No complete raw nights. Licence: non-commercial, distribution forbidden. |
| Pulsewatch | Deferred. Nothing built. | Eligibility evidence only | The checkpoint sits behind a Google sign-in. WHOOP's 24 Hz native rate cannot carry the 0.5–20 Hz band. |
| Pulse-PPG, PaPaGei, AnyPPG, SIGMA-PPG | None found | Nothing on the Droplet or in the repo | None |

## 1. ActiNet, Walmsley classifier (motion)

**Target.** Upstream's default classifier, `ssl-ukb-c24-rw-30s-20260128` (actinet 0.7.2 `walmsley`). Its labels are sleep, sedentary, light and MVPA. The file is 40,902,237 bytes, sha256 `07dfd748…`, and its md5 matches upstream's pin.

The repo's existing `actinet/harnet30-c24-mw` encoder uses a different file, the Willetts 6-class backbone. The new adapter does not use it, and nothing in `inertia/` was changed.

**What the adapter does.**
- Pinned identity (`weights.py`). The fetch step checks the upstream joblib by size, sha256 and upstream's md5. The converted weights and the HMM file are checked by size and sha256 before anything is parsed. Nothing is unpickled at runtime. Converted weights and HMM parameters live outside git.
- Preprocessing (`preprocess.py`). Contiguous runs only. Gaps are never filled. Each 30 s epoch is linearly resized from 3000 to 900 samples, as upstream does. There is no lowpass filter.
- Temporal smoothing (`hmm.py`). A Viterbi pass inside each contiguous run. The raw label is restored after each gap.
- Output. Per epoch: the model's logits and softmax probabilities (the network returns them), the raw label, and the HMM label as separate fields. Release mode `shadow`. Consumer named `activity_intensity_shadow`. Probabilities and labels are never merged.

**Tests** (`Tools/ActivityContext/tests/actinet_classifier/`).
- Without the converted artifact: 43 pass, 3 skip.
- With `ACTINET_CLASSIFIER_DIR` set to the converted artifact: 46 pass. These include the upstream-parity tests.
- The golden fixtures contain no walmsley parameters. The HMM cases use synthetic matrices, and the e2e fixture holds model outputs on a synthetic request only (checked by the motion agent).

**Head-to-head (scratch run, not in git).** Held-out external subjects only: PAMAP2 subjects 101 and 104, and seven GOTOV subjects. Nine subjects in total, with 313 epochs common to both systems.

| Set | ActiNet HMM macro-F1 | ActiNet raw macro-F1 | Nara `movement_intensity` macro-F1 |
|---|---|---|---|
| PAMAP2 (n=125) | 0.734 | 0.777 | 0.790 |
| GOTOV (n=188) | 0.836 | 0.789 | 0.734 |
| Pooled (n=313) | 0.809 | 0.800 | 0.758 |

The bootstrap over subjects gives a 95% CI of [−0.011, 0.168] for ActiNet HMM minus Nara, with p = 0.061. That is not a significant difference. ActiNet is ahead on GOTOV and behind on PAMAP2.

**Important deviation.** The comparator is `shadow-ncsa-primary-actc24`, the Capture-24 bundle. I had asked for the deployed `shadow-ncsa-primary-actukb` bundle. The comparison therefore does not describe production. The c24 and `actukb` bundles share one split manifest (sha256 `f96f41f6…`), so the same subjects are held out for both.

**Resources** (this Mac, not the Droplet).
- ActiNet: model load 3.2 s, RSS after load 341 MB. One continuous hour (120 epochs): 0.58 CPU-s, RSS 699 MB. A duty-cycled day (480 bursts, 960 epochs): 4.4 CPU-s.
- Nara's c24 path, same comparison: about 9 recorded hours in total, 148.5 CPU-s, against 5.7 CPU-s for ActiNet.

**Not done.** `ACTINET_CLASSIFIER.md`. The integration fragment. A NOTICE correction fragment. A head-to-head against the deployed `actukb` bundle. An independent review.

## 2. wav2sleep, PPG only (physiology)

**Target.** `joncarter/wav2sleep`, MIT. The checkpoint `state_dict.pth` (9,666,562 bytes, sha256 `ea6fb441…`) and `config.yaml` (749 bytes, sha256 `b92f4e26…`) match the manifest's hashes. The bytes come from Hugging Face commit `18fc32f0…`.

The manifest's `revision` (`278e3046…`) is the GitHub code commit, not a Hugging Face revision. Its artifact URLs point at the moving `main` branch. Fix this in Spec 01's manifest, using the pins in `integration/manifest-wav2sleep.json`.

**What it does.**
- Input contract (`contract.py`). Pinned to Spec 01's PPG segment members, from `docs/model-integration/README.md` on Spec 01's branch (commits ff143411e and 0fd8b94d3):
  - `run_id`
  - `config.identity` and `config.known`
  - `clock.packet_timing_verified` and `clock.samples_per_second`
  - The native rate is 25 Hz for anchored v26, and 24 Hz is also accepted. It must match `clock.samples_per_second`.
  - Segments join only within one `run_id`, and only when contiguous. A violation is split and counted as `ppg_run_id_discontinuity`.
  - A respiration or RSA signal derived from PPG is refused by name.
- Preprocessing (`preprocessing.py`). Each contiguous run is one recording, with no zero padding (deviation D1). The signal is interpolated to the pinned 1024 samples per 30 s and z-scored over the run.
- Output. Per 30 s epoch: wake / light / deep / REM probabilities, logits, a mask and its reason, and native-sample provenance. The argmax label is a separate field.
- Artifact verification (`artifacts.py`). Size and sha256 before loading. Strict state-dict key and shape checks. The config is read with `safe_load` into an allowlisted builder.
- Off by default and not registered. `provider.py` and `registry.py` exist, but no provider is wired.

**Parity with the official code** (synthetic fixtures, official code at `278e3046`):

| Fixture | Epochs | Adapter vs official direct route |
|---|---|---|
| 8 h, 24 Hz | 960 | argmax 960/960, max probability diff 0 |
| 8 h, 25 Hz | 960 | argmax 960/960, max probability diff 0 |
| Gapped night, 24 Hz (two runs) | 499 + 399 | 898/898, max probability diff 0 |
| Gapped night, 25 Hz (two runs) | 499 + 399 | 898/898, max probability diff 0 |
| 10 h, 24 Hz | 1199 | 1199/1199, max probability diff 0 |
| 10 h, 25 Hz | 1199 | 1199/1199, max probability diff 0 |

Against the official `predict_on_folder` end-to-end path: 25 Hz agrees 960/960, but 24 Hz agrees only 899/960. See "Open problems".

**Polarity.** Flipping the sign of the PPG changes the predicted stage on 353 of 960 epochs. WHOOP's optical polarity relative to the PSG oximeter it was trained on is unknown. Polarity is therefore an activation gate. The adapter never changes polarity silently, and a test checks that.

**Resources** (the Mac, not the Droplet). Model load 0.05–0.09 s. A 10 h night with 1 thread: 0.8 CPU-s and about 0.8 s wall. With 2 threads: 0.9 CPU-s. Peak RSS about 1.3 GB, of which about 0.9 GB is forward-pass memory. The Droplet has 4 vCPU and 8 GB, and the inference sidecar is capped at 3 GiB and was using 835 MB.

**Tests.**
- `Tools/InferenceWorker`, full suite with no artifacts: 614 passed, 54 skipped.
- The real-weights file, with the staged artifacts and the regenerated official references: 10 passed, 1 failed (see "Open problems").
- `Tools/ActivityContext`, full suite: 677 passed, 47 skipped, 3 failed in `tests/inertia/test_inertia_golden.py`. The same three fail on `nara/main`, so they are not from this branch.

**Activation gates, none met:** the Spec 01 PPG transport is deployed; overnight contiguous PPG is captured; WHOOP polarity is characterised; a PPG sleep-stage evaluation set exists; the Droplet's CPU and memory are measured; the shadow comparison consumer is built.

## 3. ActiTect / RBDisco (deferred, nothing built)

Upstream is pinned at `a088d8e9…`. Its four model files match the published tree by size, sha256 and git blob.

The adapter is deferred for three reasons.
1. **The axis frame cannot be established.** The default model's selected features depend on which axis is which. 26 of its 69 features depend on the axis frame, and 18 of those also depend on sign. Nothing in the repo verifies the WHOOP strap's frame against the Axivity training frame.
2. **No complete raw nights exist.** Nara captures 60 s in every 180 s. Upstream's resampling fills gaps by nearest-neighbour interpolation. Admission would have to refuse any gapped night.
3. **Licence.** The code is PolyForm Noncommercial with distribution forbidden. The models are CC BY-NC-SA 4.0. Nothing can be committed. Any use would need the operator-fetch pattern used for ElderNet.

Descriptive motion summaries to expose first, since they need no new model:
- `daily.sleep_analytics_v1.movement` is on `nara/main`, but production does not run it yet (0 of 13,879 recent snapshots).
- The `sensor_biomarker_days` movement and oscillation families do run in production.

## 4. Pulsewatch (deferred, nothing built)

- The expected checkpoint is in a Google Drive folder. Every Drive link redirects to a Google sign-in, so no bytes were obtained.
- Its input is 30 s at 50 Hz with a 0.5–20 Hz PPG band, plus heart rate and accelerometer. WHOOP's native 24 Hz has a 12 Hz Nyquist limit. In a synthetic test, 41% of the band lies above it.
- After upsampling, the 12–20 Hz energy is 0–0.9% of the reference, and what remains is imaging. Upsampling cannot restore that band.
- No raw IMU object overlaps any PPG object in time (0 of 1,076). Pulsewatch's combined PAC/PVC output would need synchronized PPG, heart rate and accelerometer data, which WHOOP does not capture.

## 5. Pulse-PPG, PaPaGei, AnyPPG, SIGMA-PPG

None found. There is no file, package, unit or source reference on the Droplet or in the repo, so there is nothing to keep or retire.

## Tests: how to rerun

```bash
# wav2sleep, no artifacts
cd Tools/InferenceWorker && uv run --frozen pytest -o addopts="" -q

# wav2sleep, with the staged artifacts and references (outside git)
FRWHOOP_WAV2SLEEP_MODEL_ROOT="<scratch>/model-root" FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE="<scratch>/reference-v2" \
  uv run --frozen pytest -o addopts="" -q tests/test_wav2sleep_real_weights.py

# ActiNet classifier, with the converted walmsley artifact
cd Tools/ActivityContext && ACTINET_CLASSIFIER_DIR="<research>/spec03-artifacts/actinet/converted-walmsley-20260128" \
  python -m pytest -o addopts="" tests/actinet_classifier -q
```

Use the scratch venv with numpy 1.26.4, scipy 1.17.1 and torch 2.8.0 for ActiNet. Its path is under `_build-scratch/spec03-motion/`.

## Open problems

1. **One wav2sleep test fails.** `test_forward_parity_with_the_official_code[parity_8h_24hz]` asserts that the adapter's argmax matches the official `predict_on_folder` output. At 24 Hz, the official pipeline disagrees with its own direct route on 61 of 960 epochs (first mismatches at epochs 72–76 and 225–227). At 25 Hz it agrees on all 960.
   - The adapter matches the official direct route exactly at both rates.
   - So the failure is in the official pipeline's 24 Hz handling, not in the adapter. I have not isolated the cause.
   - Proposed fix: compare against the direct route, and record the 24 Hz `predict_on_folder` divergence as an observation. I have not changed the test.
2. **The ActiNet head-to-head used the wrong bundle** (see above). It needs to be rerun against `actukb`.
3. **The ActiNet documentation and integration fragment are missing.**
4. **The read-only database connection documented in memory is not read-only.** The Supabase session pooler ignores `PGOPTIONS`. `show default_transaction_read_only` returned `off`. Set `default_transaction_read_only = on` as the first statement of each session. The memory note has been corrected.

## Decisions needed from you

1. **Licence scope (most urgent).** ActiNet and ssl-wearables are under the Oxford Academic Use Licence, not CC BY-NC 4.0. Clause 1.1(b) of the actinet licence, as the audit reads it, forbids use "to provide a service". Production already runs the ssl-wearables weights in the motion-heads lane (`actukb`, candidate mode) for the owner's account and one beta tester's account. ElderNet also runs in candidate mode for one beta tester. `ELDERNET.md` says that lane should not be switched on for other people's data until this is decided. `NOTICE.md` and `registry.py` need correcting. This is an audit reading, not legal advice.
2. **Capture policy.** ActiTect needs continuous overnight motion capture. wav2sleep needs overnight PPG with verified packet timing. Both are your decision.
3. **The unregistered wav2sleep adapter.** Keep it as disabled shadow code until its gates pass, or remove it?
4. **A PPG sleep-stage evaluation set.** None is local. NSRR and PhysioNet need registration or a data-use agreement, which has not been attempted.
5. **Pulsewatch.** Access to the author's Drive folder, if you want that candidate reconsidered.

## Other findings

- `docs/BACKEND.md` (around lines 777–779) says candidate decodes run only for `inertia1`. The code and migration `20261007100000` also accept `actinet`.
- Production's worker logs a `40001` serialization failure in `scoring_legacy_claim_one` about every 15 s (2026-10-08). That is outside this spec.
- Read-only audits of the Droplet and the database found nothing that was changed. All database queries returned aggregate counts only.

## Next steps

1. Fix the wav2sleep 24 Hz assertion, as proposed above.
2. ActiNet: write `ACTINET_CLASSIFIER.md` and the integration fragment, then rerun the head-to-head against `actukb` on the same subjects.
3. Run an independent review of the branch.
4. After Spec 01's transport lands: rebase, wire the admitted adapters, and verify each complete path. Nothing is deployed or merged until you say so.

## Files on this branch

- `Tools/ActivityContext/activity_context/actinet_classifier/`: `weights.py`, `preprocess.py`, `hmm.py`, `model.py`, `runtime.py`, `serve.py`, `__init__.py`
- `Tools/ActivityContext/tests/actinet_classifier/`: 5 test modules plus `conftest.py`, `synth.py` and `_helpers.py`
- `Tools/ActivityContext/fixtures/actinet_classifier/`: golden HMM, resize and e2e fixtures (synthetic inputs)
- `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/` and `wav2sleep_vendored/` (MIT code, with LICENSE, PROVENANCE.md and UPSTREAM_DIFF.json)
- `Tools/InferenceWorker/tests/test_wav2sleep_*.py`, `wav2sleep_fixtures.py`, `wav2sleep_helpers.py` and `wav2sleep_spec01_segment_shape.json`. The shape file is copied from the Spec 01 contract text. Spec 01's golden envelope was not on its branch.
- `docs/pretrained-models/`: `ELIGIBILITY.md`, `eligibility.json`, `WAV2SLEEP.md`, `STATUS.md` (this file), and `integration/` (`wav2sleep.md`, `manifest-wav2sleep.json`)

Large artifacts (model weights, the HAR datasets, the converted ActiNet weights and the official references) are outside git under `research/spec03-artifacts/` and `_build-scratch/spec03-*`.
