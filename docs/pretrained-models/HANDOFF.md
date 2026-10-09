# Spec 03 handoff

Rewritten 2026-10-08 (evening) after the work the previous handoff listed was finished. Read this file, then
[STATUS.md](STATUS.md) for the evidence, then the spec (`/Volumes/Untitled/Downloads/spec-03-optional-pretrained-models.md`).

## Where things stand

- **Branch:** `feat/spec03-pretrained-models-20261007`, cut from `nara/main` at `dab2124f3`. Not pushed, merged
  or deployed. `git log -1` gives the tip.
- **Worktree:** `/Volumes/Untitled/Nara Whoop App V2/nara-spec03-pretrained-models`.
- **Spec 01 (read only):** `/Volumes/Untitled/Nara Whoop App V2/nara-spec01-model-integration`, branch
  `feat/spec01-model-integration-20261007`. The fragments were written against `783ac84da`; the final merge check used `654f93afc`. It is still moving.
- **Merge-check worktree (throwaway):** `_build-scratch/spec03-spec01-merge`, branch
  `check/spec03-on-spec01-20261008`. It is Spec 03 at `a94bf8701` merged with Spec 01 at `654f93afc`
  (merge commit `9f1000dc6`). It is local verification only. Delete it with
  `git worktree remove --force` and `git branch -D` when it is no longer needed. Never push it.

## 1. What was done

| Item | Status |
|---|---|
| wav2sleep 24 Hz test | **Fixed.** The cause was a reference-harness bug: the official `prepare()` shared cache staged the 25 Hz night first. References were regenerated as v3 with isolated caches, and the test now refuses unisolated references. 11/11 real-weight tests pass. No expected value was changed. |
| wav2sleep D1 padding | Option A (no padding) kept on evidence over B (normalise, then pad). Corrected figures: 395/960 at 24 Hz, 398/960 at 25 Hz. |
| ActiNet head-to-head against deployed `actukb` | **Done.** Script v2 builds the comparator through the serve child's own runtime; split digest `f96f41f6…` verified. No significant difference (STATUS §1). The c24 rerun with the same method: ACTINET_CLASSIFIER.md §10.1. |
| `ACTINET_CLASSIFIER.md` | Written |
| Spec 01 fragments | `integration/actinet_classifier.md` (new); `integration/wav2sleep.md` and `manifest-wav2sleep.json` re-checked against `783ac84da` |
| Spec 01 identity in own code | ActiNet `loaded` / `loaded_digest` (guarded import); wav2sleep `loaded_identity()` |
| Isolation tests | `test_actinet_classifier_isolation.py`, `test_wav2sleep_isolation.py` |
| Licence and audience | `integration/licence-corrections.md`; ELIGIBILITY corrected. The DB re-count was refused by permission policy. |
| Independent review | Done; findings and resolutions in §3 |

**Final test runs** (this Mac, load average 400–900 from unrelated Xcode and simulator jobs):

| Suite | Result |
|---|---|
| ActiNet classifier, with the converted artifact | 52 passed |
| `Tools/ActivityContext`, full, with the artifact | 686 passed, 44 skipped, 3 failed (the pre-existing inertia goldens, below) |
| `Tools/InferenceWorker`, full, no artifacts | 619 passed, 54 skipped, 1 failed: `test_full_night_fixture_reproduces_the_committed_response_within_budget`, a 0.75 s wall-clock budget, failed under load. Rerun alone it passed 3 of 3 (0.44–0.46 s). The module is untouched by this branch. |
| wav2sleep real weights (`reference-v3`) + artifact tests | 28 passed |
| Local merge with Spec 01 `654f93afc` (`check/spec03-on-spec01-20261008` @ `9f1000dc6`) | ActiNet + `test_loaded.py` 57 passed, 1 skipped (needs a HART checkpoint); wav2sleep provider/isolation/shape/vendored/artifacts + `test_manifest.py` + `test_identity.py` 99 passed (the golden-envelope test runs there); manifest fragment 24/24 in memory; `eval/merged_identity_check.json` regenerated on this tree |

The three `tests/inertia/test_inertia_golden.py` failures predate this branch: they also fail on `nara/main`
exported to a scratch folder. They show small numerical differences from committed golden outputs in this venv.
Re-confirmed on 2026-10-08: the same 3 fail on a `dab2124f3` export of `Tools/ActivityContext`, run in the same venv. Not investigated; not caused here.

## 2. Rules (unchanged)

- **Scope.** Do not implement Spec 01 or Spec 02. Do not deploy, push, merge or change production.
- **Shared files.** Spec 01 owns the shared files (manifest, `server.py`, `providers/__init__.py`,
  `registry_adapter.py`, `sensor_biomarkers/`, `pyproject.toml`, `uv.lock`, `materialize_model_root.py`, the Swift
  worker, `supabase/`, `Tools/ActivityContext/pyproject.toml`). Propose changes to them as fragments.
  `NOTICE.md`, `inertia/registry.py` and the vendored harnet30 file are also left alone; their corrections are
  proposed text.
- **Licensed material.** No training. Licensed weights and upstream code stay out of git.
- **Shadow only.** wav2sleep stays unregistered until all six gates are met.
- **Git.** No bare `git stash`. Commit trailer for the model making the commit.
- **Database.** Read-only and aggregate only. `set default_transaction_read_only = on` first. This session's
  permission policy refused even that; ask the owner before retrying.
- **Droplet.** `frwhoop-worker-2`; runbook `deploy/OPERATIONS.md`. Running candidate code there needs approval.

## 3. Independent review

A fresh reviewer with no prior context checked the branch at `03f323a7d`, read-only. It found **no blocker**. It
confirmed:

- no file Spec 01 owns is edited;
- no weights or Oxford code are committed (the only binary is a synthetic 48 KB resize fixture);
- the vendored wav2sleep code is identical to upstream below its header;
- the head-to-head figures, re-derived from the rows with the script's own functions and seed, match;
- the licence reading matches the text;
- the ActiNet gate, the ActiTect and Pulsewatch deferrals, and the HMM semantics are correct.

| # | Finding | Resolution |
|---|---|---|
| 1 | wav2sleep code exists although its candidate is deferred | **Owner decision.** The status stays "deferred"; the code is dormant, unregistered and tested unreachable. Recommendation: do not merge it until the capture-policy and evaluation-set decisions (WAV2SLEEP.md §12). |
| 2 | ActiNet differed from its eligibility notes: the HMM spans gaps, probabilities are not an upstream output, and the epoch before a gap carried no flag | ELIGIBILITY and its JSON now record what was built and why. The wire adds `logits` (the network's real output), labels the probabilities as `softmax(logits)` with a `derivation`, and adds `label.contiguous_epochs` and `label.viterbi_spans_gaps`. Tests updated. |
| 3 | §10.1 cited before the c24 rerun existed | The rerun finished; §10.1 written (it reproduces v1 exactly). |
| 4 | Fragment cache key did not fit Spec 01's single-run `inferenceKey` | The fragment specifies a multi-run overload, `activity-infer-multi-1`. |
| 5 | Fragment SQL not in Spec 01's table pattern | Rewritten on the motion-heads pattern (`user_id`, composite FK to `devices`, `job_fingerprint`, `result_revision`, fenced publish, retention), with one stated departure: no `authenticated` select. |
| 6 | Isolation tests too narrow | Both now scan **git-tracked** files under all build and deploy roots (manifest, scripts, `Config`, `contracts`, `project.yml`, extensionless files), case-insensitively, with relative-import tokens. They fail rather than skip under `CI`. The wav2sleep test also asserts the manifest entry stays `wired: false` / `blocked_input`. Self-tests prove the scans catch wiring. |
| 7 | wav2sleep memory sized against the old 3 GiB limit; threads could exceed Spec 01's cap | WAV2SLEEP.md §10 sizes against Spec 01's `MemoryHigh=2G`, with a new warm measurement (`warm_rss_20261008.json`). The reviewer's 1.33 GB figure was not reproduced (686–924 MB in process) and is not cited as fact. `thread_cap` now never exceeds `FRWHOOP_INFERENCE_MATH_THREADS` (tested). |
| 8 | "Bit-identical" needed the D1 qualifier | Added to the WAV2SLEEP.md header and the manifest fragment's `status_reason`. |
| 9 | `flat_signal` is effectively no quality gate on ADC counts | Documented as such, and named as part of activation gate 3. |
| nits | The class-order "assert" was not one; `REASONS` lacked `nonfinite_output`; no stdin cap; inter-op threads; `provider.py` missing from the preprocessing digest; a gap between hashing and loading in wav2sleep | All fixed and tested: the runtime refuses any other class order under the real pins; `REASONS` completed; 192 MiB request cap; `configure_torch_threads` when Spec 01 is present; `provider.py` added to the digest; `load_model` parses the exact bytes it hashed. |
| nits | `max_epochs` counts invalid epochs; PAMAP2's reference counts sitting as light; 24 Hz still admitted; stale WAV2SLEEP §2, §4 and §9 | Documented (§2 and §10 verdict of the ActiNet doc). 24 Hz is kept as the legacy convention Spec 01 still names. WAV2SLEEP sections corrected. |
| nit | `merged_identity_check.json` predates HEAD | Regenerated on the final commit (§1). |


## 4. Next steps

1. **Owner decisions** (STATUS §5). The licence scope is the most urgent: the live lanes have no per-account
   gate.
2. **When Spec 01 is ready to take it:** apply `integration/actinet_classifier.md` (stage, table, channel,
   heartbeat, tests) in Spec 01's branch, then verify persistence and inspection. Check that the shadow row never
   changes the canonical decode's `document_sha256`.
3. **Droplet measurement** of the ActiNet child (with approval): RSS and CPU per duty-cycled day.
4. **wav2sleep:** nothing until the gates move. If the owner rules out overnight PPG capture or an evaluation
   set, delete the adapter (WAV2SLEEP.md §12).

## 5. Reference

| What | Path |
|---|---|
| ActiNet package / tests / fixtures | `Tools/ActivityContext/activity_context/actinet_classifier/`, `tests/actinet_classifier/`, `fixtures/actinet_classifier/` |
| Converted Walmsley artifact | `/Volumes/Untitled/Nara Whoop App V2/research/spec03-artifacts/actinet/converted-walmsley-20260128/` |
| ActiNet venv | `_build-scratch/spec03-motion/venv-nara/` |
| Head-to-head script / results | `_build-scratch/spec03-motion/scripts/head_to_head.py` (v2; v1 kept as `head_to_head_c24_v1.py`); `eval/head_to_head_actukb.json`, `eval/head_to_head_c24_v2.json`, `eval/head_to_head.json` (v1) |
| Bundles | External SSD `research/inertia-bundles/shadow-ncsa-primary-{actukb,actc24}`; encoders `research/actinet-artifacts/` |
| wav2sleep package / vendored / tests | `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/wav2sleep/`, `wav2sleep_vendored/`, `tests/test_wav2sleep_*.py` |
| wav2sleep model root / references | `_build-scratch/spec03-physio/model-root/`, `reference-v3/` (v2 is superseded) |
| Reference scripts | `_build-scratch/spec03-physio/official_reference_v3.py`, `pof_isolation.py`, `d1_padding.py`; results `pof-isolation/` |
| Official venv | `_build-scratch/spec03-physio/ref-official-venv/` |

All `_build-scratch` paths are under `/Volumes/Untitled/Nara Whoop App V2/`.

```bash
# ActiNet, with the artifact
cd Tools/ActivityContext && ACTINET_CLASSIFIER_DIR=<converted dir> <venv-nara>/bin/python -m pytest -o addopts="" -q tests/actinet_classifier
# wav2sleep, real weights
cd Tools/InferenceWorker && FRWHOOP_WAV2SLEEP_MODEL_ROOT=<scratch>/spec03-physio/model-root \
  FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE=<scratch>/spec03-physio/reference-v3 uv run --frozen pytest -o addopts="" -q tests/test_wav2sleep_real_weights.py
# Head-to-head (from _build-scratch/spec03-motion)
venv-nara/bin/python -I scripts/head_to_head.py <converted dir> <encoder .pt> <bundle dir> <har root> <out json>
```
