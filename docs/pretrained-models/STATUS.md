# Spec 03 status: pretrained-model additions

Status as of 2026-10-08 (evening). Branch `feat/spec03-pretrained-models-20261007`, cut from `nara/main` at
`dab2124f3`. `git log -1` gives the final commit. For a handoff, start with [HANDOFF.md](HANDOFF.md).

**Nothing is pushed, merged, deployed or registered.** The branch adds files only. It edits no file that Spec 01
owns (`git diff --stat dab2124f3..HEAD`). Proposed changes to shared files are fragments under
[integration/](integration/).

## Summary

| Candidate | Decision | State |
|---|---|---|
| **ActiNet**, Walmsley classifier (sleep / sedentary / light / MVPA) | **Implemented, shadow only.** Activation deferred. | Adapter, contract ([ACTINET_CLASSIFIER.md](ACTINET_CLASSIFIER.md)), upstream parity on a synthetic request, head-to-head against the deployed `actukb` bundle (no significant difference), Spec 01 identity, integration fragment. Blocked on: the owner's licence decision, Spec 01 wiring and store, Droplet measurement. |
| **wav2sleep**, PPG only | **Deferred** (gates unmet). Dormant adapter kept, off and unregistered. | Parity with the official code at 24 and 25 Hz (all 11 real-weight tests pass). The 24 Hz failure was a reference-harness bug and is fixed. None of the six activation gates is met, and today's transport sends `packet_timing_verified: false` and `config.known: false`. |
| **ActiTect / RBDisco** | **Deferred.** Nothing built. | Axis frame unverified, no complete raw nights, non-commercial no-distribution licence ([ELIGIBILITY.md](ELIGIBILITY.md) §3). |
| **Pulsewatch** | **Deferred.** Nothing built. | Checkpoint behind a Google sign-in; the 0.5–20 Hz band is not reproducible from 24 Hz ([ELIGIBILITY.md](ELIGIBILITY.md) §4). |
| Pulse-PPG, PaPaGei, AnyPPG, SIGMA-PPG | None found | Nothing to keep or retire. |

## 1. ActiNet Walmsley classifier

Contract: [ACTINET_CLASSIFIER.md](ACTINET_CLASSIFIER.md). Highlights:

- **Identity.** actinet 0.7.2 `walmsley` (`ssl-ukb-c24-rw-30s-20260128`, sha256 `07dfd748…`, upstream md5
  matched). Converted weights `1a20251b…` and HMM `79cc17a6…`; deployment pin `5d4d749a…`. Class order
  `light, moderate-vigorous, sedentary, sleep`.
- **Preprocessing.** 100 Hz NPB1 → g; runs split at gaps over 1 s; full 30 s epochs only; linear resize
  3000 → 900; no filter, no calibration, no non-wear (D1–D3).
- **HMM.** Upstream semantics: **one Viterbi pass across all valid epochs of a request, not cut at gaps**, then
  the raw label restored after each gap. An earlier version of this file said "inside each contiguous run"; that
  was wrong. On 60 s / 180 s capture about half the epochs follow a gap, so the HMM label is mostly the raw label.
- **Upstream parity**, against actinet 0.7.2's own outputs on a synthetic six-run request: probabilities within
  1e-4, logits ~3e-5, raw and HMM labels exact, on both grids. Not shown on real WHOOP windows.
- **Outputs.** Logits (the network's output), `softmax(logits)` labelled as derived and uncalibrated, and the HMM
  label, with `contiguous_epochs` and `viterbi_spans_gaps` so a consumer can tell which labels had real smoothing.
- **Shadow.** `release_mode: shadow` is a constant, and no setting raises it. An isolation test over every
  git-tracked build and deploy file fails if any production path names the classifier.

**Head-to-head against the deployed bundle** `shadow-ncsa-primary-actukb` (`eval/head_to_head_actukb.json`):

- **Script.** v2 builds the comparator the way the serve child does, with the encoder taken from the bundle
  manifest and the checkpoint sha256 checked.
- **Subjects.** Taken from the frozen splits, with digest `f96f41f6…` checked against the bundle. This digest is
  the canonical combined digest; the `split_manifest.json` file itself hashes to `860ea0be…`, the same in both
  bundles.
- **Held-out sets.** PAMAP2 101 and 104; GOTOV 07, 18, 22, 26, 27, 32 and 36.

| Set | n | ActiNet HMM macro-F1 | ActiNet raw | `actukb` `movement_intensity` (cut at 1.5 / 3 MET) |
|---|---|---|---|---|
| PAMAP2 | 125 | 0.734 | 0.777 | 0.796 |
| GOTOV | 188 | 0.836 | 0.789 | 0.751 |
| Pooled | 313 | 0.809 | 0.800 | 0.776 |

- **Significance.** Subject-bootstrap CI of the pooled difference [−0.075, 0.147], P(≤ 0) = 0.27. Exact
  subject sign-flip p = 0.23. McNemar p = 0.19. **Not significant; no improvement claimed.**
- **OOD sensitivity.** If `actukb` abstained on its out-of-distribution epochs (17.6 %), the two would be level:
  0.806 vs 0.798.
- **Error pattern.** ActiNet over-calls sedentary: sedentary precision 0.705, and 35 of 97 light epochs called
  sedentary.
- **Capture-24 comparator.** Against `actc24`, the v2 rerun reproduces v1 exactly: 0.809 vs 0.758, CI
  [−0.011, 0.168], subject sign-flip p = 0.090 ([ACTINET_CLASSIFIER.md](ACTINET_CLASSIFIER.md) §10.1). Not
  deployed.
- **Reference choice.** PAMAP2's protocol METs count sitting and standing as light. With sitting and lying as
  sedentary, ActiNet leads on PAMAP2 too (0.900 vs 0.813).

**Resources (this Mac only).**

- ActiNet: load 3.2 s; 341 MB after load; 0.58 CPU-s per continuous hour; 4.4 CPU-s per duty-cycled day; peak
  1.2 GB on a 24 h request.
- **Do not compare the head-to-head's CPU figures as model cost.** It measured 7.5 CPU-ms per epoch for ActiNet
  and 155 for `actukb`, but the deployed Inertia encoder runs with NNPACK on (about 30× on this Mac). Spec 01 has
  disabled it on its branch; that is not deployed.
- **The Droplet is not measured.**

**Spec 01.**

- **Identity.** `ping` and `infer` report Spec 01's `activity-loaded-1` identity when `activity_context/loaded.py`
  exists (guarded import).
- **Local merge check.** On a local merge with Spec 01 `783ac84da` (clean; no shared file touched by both),
  55 tests pass, and with the real artifact the `loaded_digest` equals Spec 01's `loaded_digest()`
  (`eval/merged_identity_check.json`).
- **What Spec 01 must add:** [integration/actinet_classifier.md](integration/actinet_classifier.md).
- **Full-path verification so far:** input → preprocessing → inference → shadow response. Persistence and
  inspection cannot be verified: no store exists on either branch.

## 2. wav2sleep (PPG only)

Contract: [WAV2SLEEP.md](WAV2SLEEP.md). Fragments: [integration/wav2sleep.md](integration/wav2sleep.md).

**The fixed 24 Hz test.** The adapter was never wrong. The pinned `prepare()` caches every night in one shared
folder, and `load_dataset` stages them all in unsorted `glob` order. The v2 reference ran the 25 Hz night first,
so the 24 Hz `predict_on_folder` call returned the 25 Hz night: 899/960, which is exactly the cross-rate
agreement.

- **Isolation check.** Each rate run alone agrees 960/960 (`pof-isolation/report.json`).
- **New references.** `official_reference_v3.py` isolates each call; the new references are `reference-v3`.
  The test refuses a reference made without isolation.
- **Unchanged.** No expected value was changed.
- **Result.** 11/11 real-weight tests pass at 24 and 25 Hz: logits, probabilities and z-scores bit-identical;
  argmax 960/960, 499 + 399 and 1199/1199.

**D1 padding.** The official default pads raw zeros to 10 h and agrees with the unpadded run on only 395/960
epochs at 24 Hz and 398/960 at 25 Hz. The v2 figure of 398 at both rates was contaminated at 24 Hz.

- **Options compared:** A, no padding (current), against B, normalise and then zero-pad.
- **Yardstick:** agreement with the complete-night output on the same epochs.
- **Result:** A wins at every length and both rates; at 8 h, 651 vs 607 (24 Hz) and 695 vs 648 (25 Hz). **A is
  kept.**
- **Caveat:** even A agrees only ~70 % at 8 h, so outputs depend on how much of the night the model sees.

**Diagnostics.**

- Polarity flip: 353/960 at 24 Hz and 316/960 at 25 Hz.
- EDF [-1, 1] scaling: ≤ 1.2e-4 / 1.7e-4.

**Spec 01 re-check.**

- The manifest fragment now carries `source` and passes all 24 of Spec 01's manifest tests in memory.
- `loaded_identity()` implemented for Spec 01's hook; the old `identity.py` hunk is withdrawn.
- The provider pickles.
- The real golden worker envelope is withheld `unverified_sample_clock`, as it must be: the worker always sends
  `packet_timing_verified: false` and `config.known: false`.
- Spec 01 open gap: its `loaded_identity()` hook runs in the HTTP parent, not in the worker process that loads
  models.

**Dormant code** ([WAV2SLEEP.md](WAV2SLEEP.md) §12): unreachable (unregistered, unreferenced; tested), no new
dependencies, fails closed. Recommendation: keep it on this branch and do not merge it until the owner decides on
capture policy and an evaluation set; otherwise delete it. **Not activated.**

## 3. Licence and audience

- **Licence.** actinet, ssl-wearables and ElderNet are all under the University of Oxford Academic Use Licence,
  not CC BY-NC 4.0:
  - 1.1(a) internal academic non-commercial research only;
  - 1.1(b) no use for or on behalf of a third party, or to provide a service;
  - 1.2 redistribution only on its terms.
- **Repository statements.** `NOTICE.md:347`, `inertia/registry.py:37` and the vendored `ssl_wearables_resnet.py`
  header are wrong, and `ATTRIBUTION.md` has no actinet entry. Proposed text:
  [integration/licence-corrections.md](integration/licence-corrections.md) (not applied).
- **Audience.** `ELIGIBILITY.md` contradicted itself. The worker has **no per-account gate** for the `actukb`
  or ElderNet lanes, so while enabled they process every account whose raw IMU arrives. At 05:44 UTC rows existed
  for the owner and one beta tester in both lanes.
- **Not re-counted.** A fresh read-only aggregate query this afternoon was refused by the session's permission
  policy.
- **Existing use is not permission.** Production use does not establish licence permission. The decision is the
  owner's.

## 4. Tests (2026-10-08, this Mac, load average 400–900 from unrelated jobs)

| Suite | Result |
|---|---|
| ActiNet classifier, with the converted artifact | see HANDOFF.md §1 (final run) |
| ActiNet classifier, without the artifact | 47 passed, 3 skipped |
| wav2sleep real weights (`reference-v3`) | 11 passed |
| wav2sleep provider + isolation + identity | 19 passed |
| `Tools/InferenceWorker`, full, no artifacts | 613 passed, 54 skipped, **1 failed**: `test_features_integration.py::test_full_night_fixture_reproduces_the_committed_response_within_budget`, a wall-clock budget (1.10 s vs 0.75 s at load ~900); the module is untouched by this branch. Final rerun in HANDOFF.md §1. |
| `Tools/ActivityContext`, full | see HANDOFF.md §1 |
| Local merge with Spec 01 `783ac84da` | ActiNet + `test_loaded.py` 55 passed, 1 skipped (needs a HART checkpoint); wav2sleep provider/isolation/shape/vendored + `test_manifest.py` 69 passed, 1 skipped; golden envelope 7 passed |

## 5. Decisions for the owner

1. **Licence scope (most urgent).** Are the live `actukb` and ElderNet lanes on beta testers' data "internal
   academic research"? If not: restrict them to the owner, license them from Oxford University Innovation, or
   switch them off. Also: apply the NOTICE/registry corrections, and decide the fate of the committed vendored
   harnet30 source.
2. **Capture policy.** Continuous overnight IMU (ActiTect, and meaningful ActiNet HMM) and overnight PPG with
   verified packet timing (wav2sleep). Battery cost unmeasured.
3. **The dormant wav2sleep adapter.** Keep it unmerged, or delete it.
4. **Droplet measurements** for both adapters (needs approval).
5. **A PPG + PSG evaluation set** (NSRR or PhysioNet registration or a data-use agreement).
6. **Pulsewatch.** Access to the Drive folder, or drop it.
7. **ActiTect axis check.** Uses the owner's raw IMU in production; needs approval.
8. **Product use for ActiNet intensity.** Without one, it stays a research comparison.

## 6. Other findings (outside this spec)

- The deployed Inertia encoder runs with NNPACK on: about 30× CPU on this Mac. Fixed on Spec 01's branch, not
  deployed.
- `docs/BACKEND.md:777-779` says candidate decodes run only for `inertia1`; the code and migration
  `20261007100000` also accept `actinet`.
- The worker logs a `40001` serialization failure in `scoring_legacy_claim_one` about every 15 s
  (journal, 2026-10-08 morning).
- The documented read-only database connection is not read-only via `PGOPTIONS`. Set
  `default_transaction_read_only` first.
- Spec 01 README links `provisioning.md`, `runtime-bounds.md` and `ppg-transport.md`, which do not exist on its
  branch.

## Files on this branch

- `Tools/ActivityContext/activity_context/actinet_classifier/` (7 modules), `tests/actinet_classifier/` (6 test
  modules + helpers), `fixtures/actinet_classifier/` (synthetic goldens).
- `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/` and `wav2sleep_vendored/` (MIT),
  `tests/test_wav2sleep_*.py` plus fixtures and helpers.
- `docs/pretrained-models/`: this file, `HANDOFF.md`, `ELIGIBILITY.md`, `eligibility.json`, `WAV2SLEEP.md`,
  `ACTINET_CLASSIFIER.md`, and `integration/` (`actinet_classifier.md`, `wav2sleep.md`, `manifest-wav2sleep.json`,
  `licence-corrections.md`).

Outside git: weights, converted artifacts and official references under `research/spec03-artifacts/` and
`_build-scratch/spec03-*`; evaluation scripts and results under `_build-scratch/spec03-motion/{scripts,eval}` and
`_build-scratch/spec03-physio/`.
