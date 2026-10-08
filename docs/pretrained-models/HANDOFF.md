# Spec 03 handoff

Written 2026-10-08 so another model or session can continue Spec 03 without this conversation. Read this file, then [STATUS.md](STATUS.md) for the evidence, then the spec.

## Where things stand

- **Branch:** `feat/spec03-pretrained-models-20261007`, cut from `nara/main` at `dab2124f3`. This handoff is committed on top of `e85b12e36`; `git log -1` shows it. Not pushed, merged or deployed.
- **Worktree:** `/Volumes/Untitled/Nara Whoop App V2/nara-spec03-pretrained-models`. Work only here.
- **Spec:** `/Volumes/Untitled/Downloads/spec-03-optional-pretrained-models.md`. Read it in full. Specs 01 and 02 sit beside it. Do not implement either.
- **Spec 01 worktree (read only):** `/Volumes/Untitled/Nara Whoop App V2/nara-spec01-model-integration`, branch `feat/spec01-model-integration-20261007`, tip `0fd8b94d3`. Its contract text is in `docs/model-integration/README.md`.

## 1. How far the work got

| Item | Status | Where |
|---|---|---|
| Eligibility and artifact checks, all candidates | Done | `docs/pretrained-models/ELIGIBILITY.md`, `eligibility.json` |
| ActiNet Walmsley classifier, adapter | Built. 46 tests pass with the converted artifact. Shadow only. | `Tools/ActivityContext/activity_context/actinet_classifier/`, `tests/actinet_classifier/` |
| ActiNet head-to-head | Run against the Capture-24 bundle. The rerun against the deployed `actukb` bundle is not done. | `_build-scratch/spec03-motion/eval/head_to_head.json` |
| ActiNet resource measurements | Done on this Mac. Not on the Droplet. | `eval/measure_actinet.json`, `eval/measure_nara.json` |
| ActiNet contract doc and integration fragment | Not written | — |
| wav2sleep PPG-only adapter | Built. Off. Not registered. Matches the official code exactly on the direct route at 24 and 25 Hz. | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/`, `docs/pretrained-models/WAV2SLEEP.md` |
| wav2sleep 24 Hz test | Fails. The official `predict_on_folder` path disagrees with its own direct route. | `Tools/InferenceWorker/tests/test_wav2sleep_real_weights.py` |
| wav2sleep docs and integration fragments | Done, aligned to Spec 01's clock and rate members | `docs/pretrained-models/integration/` |
| ActiTect / RBDisco | Deferred. Nothing built. | `ELIGIBILITY.md` §3 |
| Pulsewatch | Deferred. Nothing built. | `ELIGIBILITY.md` §4 |
| Pulse-PPG, PaPaGei, AnyPPG, SIGMA-PPG | None found | `ELIGIBILITY.md` §5 |
| Rebase on Spec 01, wiring, full-path checks | Not started. Spec 01's PPG transport code is not on its branch yet. | — |
| Independent review | Not started | — |

**Test state at this commit** (run on the branch, 2026-10-08):

| Suite | Result |
|---|---|
| `Tools/InferenceWorker`, full, no artifacts | 614 passed, 54 skipped |
| wav2sleep real weights, with artifacts and `reference-v2` | 10 passed, 1 failed |
| ActiNet classifier, with `ACTINET_CLASSIFIER_DIR` | 46 passed |
| `Tools/ActivityContext`, full | 677 passed, 47 skipped, 3 failed |

The three ActivityContext failures are in `tests/inertia/test_inertia_golden.py`. The same three fail on `nara/main` exported to a scratch folder, so this branch did not cause them. They are not investigated. They show small numerical differences from committed golden outputs in this venv.

## 2. Rules for whoever continues

- **Scope.** Do not implement Spec 01 or Spec 02. Do not deploy, push, merge or change production. The owner decides those.
- **Spec 01 owns the shared files.** These include `Tools/InferenceWorker/models/manifest.json`, `src/frwhoop_inference/server.py`, `providers/__init__.py`, `frwhoop_sleep/registry_adapter.py`, `sensor_biomarkers/`, `pyproject.toml`, `uv.lock`, `scripts/materialize_model_root.py`, the Swift worker files, `supabase/`, and `Tools/ActivityContext/pyproject.toml`. Put proposed changes to them in `docs/pretrained-models/integration/` as fragments.
- **No training.** No fitting, calibration or fine-tuning to rescue a candidate. A clear deferral is the correct outcome when a gate fails.
- **Licensed material stays out of git.** ActiNet and ssl-wearables are under the Oxford Academic Use Licence. ActiTect's code is PolyForm Noncommercial with distribution forbidden, and its models are CC BY-NC-SA. Fetch these on the operator side, pin them by sha256, and keep converted files under `research/spec03-artifacts/`.
- **Shadow only.** Outputs carry `release_mode: shadow`. Never raise a mode downstream. Keep probabilities, labels and embeddings as separate output types.
- **Git.** Work in this worktree. Never use bare `git stash` or `git stash pop`, because the stash stack is shared with other sessions. WIP commits are fine as checkpoints. Commit messages end with the `Co-Authored-By` trailer for the model making the commit. Earlier commits carry Opus 5.5's trailer; the latest carries Haiku 5.5's.
- **Secrets.** Database credentials are in the project `.env` on the External SSD. Never copy values into files, commits or chat. Refer to accounts as "the owner" and "a beta tester". Keep account and device IDs out of committed files.
- **Database.** `PGOPTIONS` does not make a session read-only, because the Supabase pooler ignores it. Run `set default_transaction_read_only = on;` as the first statement, then check with `show default_transaction_read_only;`. Prefer aggregate queries.
- **Droplet.** The worker host is `frwhoop-worker-2`. Its address is in `deploy/OPERATIONS.md` (line 3), and that file is the runbook. A read-only SSH check in this session returned the hostname `frwhoop-worker-2`. So far only read-only inspection has been done there. Do not change anything on it.
- **Storage.** Research artifacts are on two volumes. The External SSD holds the inertia bundles, the ActiNet and ssl-wearables weights, and some datasets. The Untitled volume holds `har-datasets`, `research/spec03-artifacts/`, and scratch. The External SSD has unmounted before, so commit often.
- **Rate limits.** Sub-agents hit the daily token limit several times in this work. Keep each sub-task small and commit after each step.

## 3. Next steps, in order

### Step 1. Fix the wav2sleep 24 Hz test

- **Where:** `Tools/InferenceWorker/tests/test_wav2sleep_real_weights.py`, the `if name.startswith("parity_8h")` block in `test_forward_parity_with_the_official_code`. The failing assertion is around line 132.
- **What is known.** At 24 Hz, the official `predict_on_folder` agrees with the official direct route on 899 of 960 epochs. Its first mismatches are at epochs 72–76 and 225–227. At 25 Hz it agrees on all 960. The adapter's logits match the official direct route exactly at both rates. The cause inside the official `prepare()` path is not isolated.
- **Do.** Keep the adapter-versus-direct assertion. Record the `predict_on_folder` agreement as an observation for both rates, not as a 24 Hz assertion. The D1 figure in `WAV2SLEEP.md` §8 is already corrected to 398 of 960 at both rates.
- **Also open:** the D1 question. Compare two options against the official behaviour on the 8 h and gapped fixtures. Option A is no padding, which is the current choice. Option B is z-scoring the real samples and then zero-padding the normalised tensor to 10 h. Say which is the faithful contract. Nothing has answered this yet.
- **Done when:** the real-weights file passes with artifacts (11 tests), the 24 Hz divergence is recorded in `WAV2SLEEP.md`, and the InferenceWorker suite is still 614 passed.

### Step 2. Rerun the ActiNet head-to-head against the deployed `actukb` bundle

- **Subjects.** The c24 and `actukb` bundles share one split manifest (sha256 `f96f41f6…`), so the held-out subjects are the same: PAMAP2 subjects 101 and 104, and GOTOV 07, 18, 22, 26, 27, 32 and 36.
- **Script change.** `_build-scratch/spec03-motion/scripts/head_to_head.py` imports `C24_ID` (line 27) and builds the encoder with it (line 108). Change it to read the encoder ID from the bundle's `manifest.json` (`encoder.encoder_id`). For `actukb` that is `actinet/harnet30-ssl-ukb/30s@20hz`, which is `UKB_ID` in `activity_context/inertia/actinet.py`. Update the docstring, which describes the comparator as c24. Keep the sleep-into-sedentary merge the script already uses.
- **Inputs.**
  - Artifact directory: `research/spec03-artifacts/actinet/converted-walmsley-20260128`
  - Encoder: `/Volumes/External SSD/Nara Whoop App V2/research/actinet-artifacts/ssl-wearables-harnet30-ukb-v1.0.0.pt` (sha256 `28f8bcd7…`)
  - Bundle: `/Volumes/External SSD/Nara Whoop App V2/research/inertia-bundles/shadow-ncsa-primary-actukb`
  - HAR root: `/Volumes/Untitled/Nara Whoop App V2/research/har-datasets`
- **Run.** Use `venv-nara` with `python -I`, from the scratch folder. The usage line is `python -I head_to_head.py <artifact dir> <encoder .pt> <bundle dir> <har root> <out json>`. Write the result to `eval/head_to_head_actukb.json`. Keep the c24 result in `eval/head_to_head.json`.
- **Done when:** the `actukb` table, bootstrap confidence intervals and CPU totals are in `ACTINET_CLASSIFIER.md` next to the c24 numbers.

### Step 3. Write `Tools/ActivityContext/ACTINET_CLASSIFIER.md`

This is the adapter's contract. Cover:
- **Identity.** The Walmsley artifact, its upstream md5 and sha256, and the converted files pinned in `weights.py` (`actinet-walmsley-20260128-weights.pt` and `actinet-walmsley-20260128-hmm.json`).
- **Input.** WHOOP raw IMU as NPB1 `rawImuSession`: 100 Hz, 1/4096 g, runs split at gaps over 1 s, nothing filled. Epochs are 30 s. Each epoch is resized linearly from 3000 to 900 samples. There is no lowpass filter.
- **Output.** Per epoch: logits, softmax probabilities, the raw label and the HMM label. Class order, from the golden fixture and the artifact: `light`, `moderate-vigorous`, `sedentary`, `sleep`.
- **Wire.** Schema `actinet-classifier-1`. Serve options are `--artifact-dir`, `--threads`, `--max-batch`, `--max-epochs` and `--timeout`. Check `serve.py` for the defaults.
- **Release and consumer.** `release_mode` is `shadow`. The consumer is `activity_intensity_shadow`.
- **Licence.** As in §4.
- **Resources.** The Mac figures from `measure_actinet.json`, labelled as Mac figures.
- **Results.** The head-to-head for both bundles.
- **Deviations from upstream.** List each one with the test that covers it. Do not claim parity beyond what the tests show.
- **Open gates.** As in §4.

### Step 4. Write the ActiNet integration fragment

`docs/pretrained-models/integration/actinet_classifier.md` should propose, for Spec 01's files:
- A new `manifest.json` entry for the adapter. No ActiNet entry exists yet.
- A registry hook.
- The worker request path: the serve child, the request shape, and the cache key built from the input digest, artifact digest and preprocessing digest.
- The identity-block contents.
- Storage and consumer. Shadow results go to a shadow store, never to canonical activity outputs. Check Spec 01 §2 (activity authority) and the release-mode section of its README first. Do not reuse `activity_motion_heads_days` without Spec 01's agreement.
- The NOTICE and `registry.py` licence correction, as proposed text only.

**Done when:** the fragment has been checked against Spec 01's README.

### Step 5. Independent review

Give a fresh reviewer, with no prior context, the spec and the branch. Ask them to check:
- Each gate decision against the evidence files.
- The shadow-only rule.
- That no shared file was edited.
- That no licensed weights or upstream code are committed. Grep for `.pt`, `.joblib`, `.lzma` and upstream package files.
- That every number in the docs traces to a file.

Fix what they find, rerun the suites, and commit the review with its resolutions.

### Step 6. Wait for Spec 01, then rebase and wire

- Spec 01's branch tip (`0fd8b94d3`) is documentation only. Its shared identity hooks are in `63353ccd9`. Its PPG transport code has not landed.
- The golden request envelope named in its README is not on the branch yet. Replace `tests/wav2sleep_spec01_segment_shape.json` with that envelope when it exists.
- When the transport lands: rebase, wire the ActiNet shadow lane through Spec 01's registry and authority rules, and verify the full path. The path runs from request to serve to store to API or app. Shadow results must never reach canonical outputs or the app.
- wav2sleep stays unwired unless all six gates in `constants.ACTIVATION_GATES` are met.

### Step 7. Droplet measurements, with approval only

Both candidates need an on-host CPU and memory measurement. Read-only checks of the sidecar's loaded identity and resource use are fine now. Running candidate code on the host needs your approval.

## 4. Decisions for the owner

1. **Licence scope (urgent).** Production runs the ssl-wearables weights in the motion-heads lane (`actukb`, candidate mode) for the owner's account and one beta tester's account. ElderNet runs for one beta tester. `ELDERNET.md` says not to extend that lane to other people's data until this is decided. The audit reads clause 1.1(b) of the actinet licence as forbidding use "to provide a service". This is an audit reading, not legal advice. Before deciding, settle who is affected: `ELIGIBILITY.md` says the lane serves one beta tester in one place, and its table shows the owner's account too. Use aggregate database counts.
2. **Capture policy.** Continuous overnight motion for ActiTect, and overnight PPG with verified packet timing for wav2sleep. Battery cost is unmeasured.
3. **The unregistered wav2sleep code.** Keep it disabled or remove it. It was built before its gates were met. Spec 03 says to implement only candidates whose inputs and trained outputs are available.
4. **A PPG and PSG sleep-stage evaluation set.** None is local. NSRR and PhysioNet need registration or a data-use agreement. Not attempted.
5. **Pulsewatch.** Access to the author's Drive folder, or drop the candidate.
6. **ActiTect axis check.** Establishing the WHOOP strap's frame needs owner raw-IMU sessions from production (2026-10-05 to 10-08). Gravity during walking gives the forearm axis. The gyroscope's main rotation during arm swing gives the axis normal to the strap face. A same-time comparison checks the 100 Hz stream against the 1 Hz gravity stream. Do this only with your approval.

## 5. What would reopen the deferred candidates

- **ActiTect.** A verified axis mapping. Or, if you choose that route, an adapter that refuses with `axis_frame_unverified`. Also: complete raw nights under a capture policy, licence scope, wear placement (wrist side or dominance), and a named consumer. Upstream's `example.cwa` parity fixture is also not downloaded.
- **Pulsewatch.** An obtainable checkpoint, and a WHOOP input that can carry the 0.5–20 Hz band with synchronized PPG, heart rate and accelerometer. Native 24 Hz cannot do this, so it would need retraining, which is out of scope.
- **Pulse-PPG family.** No candidate exists.

## 6. Reference

**Key paths**

| What | Path |
|---|---|
| ActiNet package | `Tools/ActivityContext/activity_context/actinet_classifier/` |
| ActiNet tests | `Tools/ActivityContext/tests/actinet_classifier/` |
| ActiNet golden fixtures | `Tools/ActivityContext/fixtures/actinet_classifier/` |
| Converted Walmsley artifact | `research/spec03-artifacts/actinet/converted-walmsley-20260128/` |
| wav2sleep package | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/` |
| wav2sleep vendored model | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep_vendored/` (MIT; LICENSE, PROVENANCE.md, UPSTREAM_DIFF.json) |
| wav2sleep tests | `Tools/InferenceWorker/tests/test_wav2sleep_*.py` |
| Official wav2sleep source | `research/spec03-artifacts/wav2sleep/code-github/wav2sleep/src/` (code commit `278e3046`) |
| Staged wav2sleep model root | `_build-scratch/spec03-physio/model-root/` |
| Regenerated official references | `_build-scratch/spec03-physio/reference-v2/` |
| Reference script | `_build-scratch/spec03-physio/official_reference_v2.py` |
| Official reference venv | `_build-scratch/spec03-physio/ref-official-venv/` |
| ActiNet venv | `_build-scratch/spec03-motion/venv-nara/` (numpy 1.26.4, scipy 1.17.1, torch 2.8.0) |
| ActiNet scripts and results | `_build-scratch/spec03-motion/scripts/` and `_build-scratch/spec03-motion/eval/` |
| Deployed ActiNet bundle (`actukb`) | External SSD: `research/inertia-bundles/shadow-ncsa-primary-actukb/` |
| Capture-24 bundle (`actc24`) | External SSD: `research/inertia-bundles/shadow-ncsa-primary-actc24/` |
| ActiNet source weights | External SSD: `research/actinet-artifacts/` |
| HAR datasets | Untitled: `research/har-datasets/` (`pamap2/`, `gotov/`, and others) |
| Spec 01 contract text | `nara-spec01-model-integration/docs/model-integration/README.md` (branch tip `0fd8b94d3`) |

**Test commands.** Replace the placeholders with the absolute paths above.

```bash
# InferenceWorker, no artifacts (about 2 minutes)
cd Tools/InferenceWorker && uv run --frozen pytest -o addopts="" -q

# wav2sleep real weights
cd Tools/InferenceWorker && FRWHOOP_WAV2SLEEP_MODEL_ROOT="<scratch>/spec03-physio/model-root" \
  FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE="<scratch>/spec03-physio/reference-v2" \
  uv run --frozen pytest -o addopts="" -q tests/test_wav2sleep_real_weights.py

# ActiNet classifier, with the converted artifact
cd Tools/ActivityContext && ACTINET_CLASSIFIER_DIR="<research>/spec03-artifacts/actinet/converted-walmsley-20260128" \
  "<scratch>/spec03-motion/venv-nara/bin/python" -m pytest -o addopts="" tests/actinet_classifier -q
```

`pyproject.toml` sets `addopts = "-q"`, so pass `-o addopts=""` to see the summary line.

**Known issues outside this branch's scope**
- The three ActivityContext golden failures (see §1).
- `docs/BACKEND.md` lines 777–779 say candidate decodes run only for `inertia1`. The code and migration `20261007100000` also accept `actinet`.
- The worker logs a `40001` serialization failure in `scoring_legacy_claim_one` about every 15 seconds (2026-10-08).
- `ELIGIBILITY.md` is inconsistent about the `actukb` audience (see §4, item 1).
- Zsh expands unquoted globs. Quote patterns such as `'*.py'`.
