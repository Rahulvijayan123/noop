# Readiness table — spec §10 per-candidate handoff

This is the spec §10 handoff table for every candidate in scope: the 8 entries of the model
manifest plus both HRV providers (10 rows; `neurokit2` appears twice by design — once as the model
entry, once as the shadow provider it backs). Every cell is filled from the findings evidence, and
`Skipped` / `NOT RUN` are written where nothing was run. No cell is inferred.

Legend: **Y** = yes, evidenced. **N** = no. **NOT RUN** = the work was not performed (never a
pass). **blocked** = cannot proceed on this branch.

Manifest source: `Tools/InferenceWorker/models/manifest.json` (8 entries, verified in the worktree).
Verdict sources: `findings/hrv-neurokit.md`, `findings/sleep-boundary-stager.md`,
`findings/conditional-models.md`, `findings/impl-inference-hrv.md`, `findings/impl-sleep-providers.md`,
`findings/impl-supabase.md`, `findings/validation-fixtures.md` and the three review ledgers.

---

## 1. Per-candidate handoff table

| Candidate | Metric | implemented | reference-inference-tested | real-input-eligible | shadow-evaluated | accuracy-verified | promotion-eligible | remaining-blocker |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `neurokit2` 0.2.13 (model entry) | hrv (shadow only) | Y — `neurokit2.shadow.v1` in `providers/hrv.py`; never publishable | Y — 16 shadow tests + oracles reproduced exactly; suite 137 passed | Y — `noop_rr_intervals` per-beat rows reach the server | N — NOT RUN (no metric has ever been switched on; ships `mode='off'`) | N — labelled `unverified_accuracy`; no independent reference data | N | accuracy unverified; whole-second store stamps make the naive path unusable (the END-time reconstruction is required); licence is clean (MIT) |
| `production.runs.v1` (authoritative HRV provider) | hrv | Y — port of `HRVAnalyzer` + `IntradaySeries` + `SleepStager` semantics | Y — all 10 published oracles reproduce exactly (value, pairs, clean beats); independent first-principles reference agrees to 1e-9 | Y — same RR rows | N — NOT RUN | N — arithmetic verified, physiological accuracy not measured | N | the shipped 3.0 s splice tolerance is reproduced, not fixed (finding B6); day aggregation omits `mainGroup`/`mainNightRefused` and the deep-stage branch; observation-identity dedup is NEW behaviour (shipped engine has none) |
| `hypnospy` 3b6c825d (vendored) | sleep_boundary | Y — `hypnospy.hr-boundary.v1`, vendored at the pinned commit + 6 documented patches + PROVENANCE | Y — adapter probe ran on synthetic fixtures: 16 rows, **10 ok / 6 withheld / 0 errors**, median onset error 180 s, 2-21 ms/call | Y — 1 Hz HR + 1 Hz gravity + `dynAccel` + sleep-state are all on the server | N — NOT RUN | N — `unverified_accuracy` | N | licence metadata unresolved (LICENSE MIT vs `setup.py` BSD vs GitHub NOASSERTION) — must be reconciled before promotion; DST fall-back final wake 8220 s early; flat/elevated nights can place the period in the daytime block; `require_hr_dip_bpm` default is `null` (report-only) |
| `sleepecg` 0.5.9 `wrn-gru-mesa` | sleep_stage | Y — `sleepecg.wrn-gru-mesa.v1`; zip + inner `classifier.keras` sha256-verified at load | Y — REAL pinned inference executed: synthetic nights produce `(1070, 36)` features → `(1070, 4)` softmax with row sums exactly 1.0, deterministic, 1.1-1.8 s/night; real R-peak detection on the shipped toy ECG works (478 beats / 300 s). The shipped toy ECG does **not** reach a staged output: `_nanpsd` raises (`nan_free_windows = 0`) | Y for the RR-only input contract (`noop_rr_intervals` → cumulative RR seconds); real-input readiness is marked **unverified** (1 s bucketed, mixed transports) | N — NOT RUN | N — `unverified_accuracy`; `raw_scores.calibrated = false` | N | low yield on real data (`_nanpsd`; accepted as low-yield by parent decision — no RRI repair, no patch); TensorFlow is not installable on the arm64 dev host (keras-direct loader used); three-class output must stay out of the four-stage fields |
| `wav2sleep` 278e3046 | sleep_stage (conditional) | N — recorded in the manifest only, NOT wired as a provider | N — NOT RUN (no adapter; no permitted reference fixture wired) | N — `blocked_input`: needs 1024 raw ECG/PPG samples per 30 s epoch; the product path has no waveform | N — NOT RUN | N | N | needs a qualified raw waveform; the only candidate source is the operator-issued 300 s research `ppgWaveformSample` object, uncalibrated and with no validated per-record timing. Rights are CLEAR (MIT code + MIT weights) and the checkpoint sha256 is verified |
| `no_eeg_sleep_staging` 97d4ef19 | sleep_stage (conditional) | N — manifest only, NOT wired | **Partial**: the probe ran real frozen inference on the model's own shipped held-out night (952 epochs; kappa(argmax) 0.4562, kappa(HMM) 0.428, HMM accuracy 0.6061; output `(952, 4)` probs in Wake/Light/Deep/REM order). No adapter was built | N — `blocked_input` at fleet level: the motion side needs ~50-65 Hz 3-axis acceleration and the product provides a 1 Hz gravity summary | N — NOT RUN | N | N | motion provenance: feeding a gravity summary as three axes is a forbidden conversion; the model is retrospective-only (per-night z-scores). Rights CLEAR (MIT) |
| `rr_estimation` e429f1cc | respiration (conditional) | N — manifest only, NOT wired | N — NOT RUN. No example input ships (raw signals are on Google Drive) and the input normalisation is absent from the source, so frozen inference was deliberately not executed. Facts were read from the HDF5 weight shapes (conv1d kernel `(3,4,32)` → 4 channels; `dense_9 (64,1)` → 1 linear BrPM) | N — `blocked_input`: needs raw PPG synchronised with 64 Hz 3-axis acceleration; the product has neither | N — NOT RUN | N | N | checkpoint pinned and sha256-verified, but there is no reference fixture and no compatible input; the metric therefore has **no wired provider at all** (`POST /v1/infer` for `respiration` returns 503 `provider_unavailable`) |
| `stepcount` d7bc0c6e | steps | N — never integrated | N — NOT RUN | N | N | N | N | `blocked_license`: Academic Use Licence 1.1(b) expressly forbids product integration, including shadow execution. Absolute block |
| `cnn_wrist_model_freeliving` 9ca77ea1 | calories | N — never integrated | N — NOT RUN | N | N | N | N | `blocked_license`: no licence file exists in the repository at all. Absolute block |

### 1.0 Source per row

| Row | Primary evidence |
| --- | --- |
| `neurokit2` 0.2.13 | findings/hrv-neurokit.md §1-§4 (pin, `hrv_time` RR path, probes); findings/impl-inference-hrv.md §1a-§1b, §2b, §4; findings/review-inference-hrv.md §0 |
| `production.runs.v1` | findings/hrv-neurokit.md §5a-§5d (engine rules) and §6d (11 hard rules); findings/impl-inference-hrv.md §1a, §2a, §5 |
| `hypnospy` | findings/sleep-boundary-stager.md §1 (pin, licence, algorithm), §6 (blockers B1-B13); findings/impl-sleep-providers.md §2, §3.1, §4, §6 |
| `sleepecg` 0.5.9 | findings/sleep-boundary-stager.md §2.1-§2.7, §3.1-§3.3; findings/impl-sleep-providers.md §1, §3.2, §6 |
| `wav2sleep` | findings/conditional-models.md §0, §2, §7, §8.1 |
| `no_eeg_sleep_staging` | findings/conditional-models.md §0, §3 (incl. §3.4 probe numbers), §7, §8.3 |
| `rr_estimation` | findings/conditional-models.md §0, §4, §7, §8.2; findings/impl-inference-hrv.md §6 (503 for `respiration`) |
| `stepcount` | findings/conditional-models.md §0, §5, §8.4 |
| `cnn_wrist_model_freeliving` | findings/conditional-models.md §0, §6, §8.5 |
| `respiration` (no provider) | findings/impl-inference-hrv.md §6; `Tools/InferenceWorker/src/frwhoop_inference/providers/__init__.py` (`default_providers`) |

Real-input eligibility per row: findings/validation-fixtures.md §2.4 (per-metric table) and
findings/sleep-boundary-stager.md §2.6 (RR-only contract for SleepECG).
Manifest values (status, `wired`, `required_for_readiness`, digests):
`Tools/InferenceWorker/models/manifest.json` (8 entries, read in the worktree).

### 1.1 Row-by-row notes

* **`neurokit2` vs `production.runs.v1`.** Both are HRV providers on the `hrv` metric
  (`Tools/InferenceWorker/src/frwhoop_inference/providers/hrv.py`: `PRODUCTION_PROVIDER_ID =
  "production.runs.v1"`, `SHADOW_PROVIDER_ID = "neurokit2.shadow.v1"`).
  `production.runs.v1` is the authoritative one; `neurokit2.shadow.v1` is gated comparison only and
  is enforced non-publishable in code (`publishable: false`, `accuracy_label:
  "unverified_accuracy"`, `final_or_provisional: "provisional"`; verified live by the independent
  reviewer — findings/review-inference-hrv.md §0).
* **`hypnospy` and `sleepecg` are wired but shadow-only.** Their manifest status is
  `shadow_eligible`; `sleepecg`'s two artifacts are `required_for_readiness=true` (a wired model
  artifact gates readiness) while the vendored `hypnospy` has no artifact.
* **`respiration` has no provider.** `default_providers()` registers exactly four providers
  (`Tools/InferenceWorker/src/frwhoop_inference/providers/__init__.py`):
  `production.runs.v1`, `neurokit2.shadow.v1`, `hypnospy.hr-boundary.v1`,
  `sleepecg.wrn-gru-mesa.v1`. The `respiration` metric is registered in the Supabase selection
  domain but returns 503 `provider_unavailable` from the sidecar.
* **Nothing is `active`.** `active` additionally requires a live signed promotion approval; without
  one, `physiology_selected_provider()` demotes `active` to `shadow` and
  `physiology_record_candidate_result()` refuses the write outright (returns NULL). Verified by the
  Deno suite and independently reproduced by the reviewer with a forged-signature approval.
* **Shadow evaluation has not happened for any metric.** All four metrics ship `mode='off'`
  (section 2), so no candidate value has ever been computed against production data. That is the
  honest state, not a gap in this table.

---

## 2. Per-metric selection state (as shipped)

Source: the seed block of `supabase/migrations/20261002090000_physiology_candidate_providers.sql`
(`on conflict (metric) do nothing`, so a repair re-run can never reset an operator decision) and
findings/impl-supabase.md §3.1.

| Metric | provider_id | provider_version | config_version | mode | Effective state |
| --- | --- | --- | --- | --- | --- |
| `hrv` | `none` | `none` | `none` | `off` | candidate lane dormant |
| `sleep_boundary` | `none` | `none` | `none` | `off` | candidate lane dormant |
| `sleep_stage` | `none` | `none` | `none` | `off` | candidate lane dormant |
| `respiration` | `none` | `none` | `none` | `off` | candidate lane dormant (and no provider is wired) |

Because `mode='off'` for every metric, the staleness trigger family is dormant and a real stream
insert creates **zero** debt rows (verified functionally by the Deno suite: 20 steps green, and by
the reviewer's independent reproduction) (findings/impl-supabase.md §5.7;
findings/review-supabase.md R2-1, R2-9).

Per-user overrides (`physiology_provider_overrides`) exist but are empty; a per-user `active`
override is gated identically to a fleet default and demotes when unapproved
(findings/impl-supabase.md §4a).

---

## 3. Verification and review status (context for the table)

| Deliverable | Test evidence | Independent review verdict |
| --- | --- | --- |
| `Tools/InferenceWorker` (HRV providers, contract, server, manifest) | `uv run pytest` → **137 passed** in 3.48 s (contract 31, hrv_production 35, hrv_shadow 16, manifest 14, server 41) | PASS WITH DEFECTS — no P0/P1; 1 P2 (readiness could not go false for a missing artifact) + 6 P3. Reproduced 137 passed in 3.72 s |
| Sleep providers (`frwhoop_sleep/**`, vendored HypnosPy + SleepECG adapter) | staged suite 51 → 56 passed after the registry shim; landed into the package; the combined suite briefly went RED (22 failures, global readiness) and the per-provider readiness fix round resolved it — final: **209 → 221 → 230 passed, 0 failed** (parent-verified; parent-notes.md "W-D ROUND 2/3" and "REVIEW LEDGER 4/5"). This row was corrected after the final audit flagged it as stale | PASS WITH DEFECTS — review-sleep-providers: 0 P0/P1, 3 P2 (all fixed + re-verified in the repair round; see review-sleep-providers.md) + 9 P3 (6 fixed, 2 documented not-actioned, 1 wire convention) |
| Supabase migration + Deno suite | `deno test --frozen` → **1 passed (20 steps), 0 failed**, exit 0; `deno check` exit 0 | REQUEST CHANGES → all round-1 P2s FIXED and independently reproduced; final **0 P0 / 0 P1 / 0 P2, 2 P3 open by decision** |
| Swift worker client + deploy files | `swift test` → **172 / 1 skip / 0 fail** (baseline 98/1/0), then **180 / 1 skip / 0 fail** after the repair round; `bash -n provision.sh` OK | REQUEST CHANGES (P1=1, P2=5) → **PASS** on all repairs (200/1/0 reproduced exactly); 3 P3 open (F1 stale citations — since fixed in a final small round; F2 no live-DB RPC binding test; F3 timeout equality — since set to 25000) |
| Real-input capability report | NOT PRODUCED — no real capture corpus exists locally | NOT RUN |

Sources for the counts above: findings/impl-inference-hrv.md §1;
findings/impl-sleep-providers.md §5, §10; findings/impl-supabase.md §2.1;
findings/impl-swift-client.md §2; findings/review-inference-hrv.md §1;
findings/review-supabase.md §0, §R2-1; findings/review-swift-client.md §1;
findings/review-swift-client-r2.md §1.

The combined InferenceWorker suite state after the sleep providers landed is **not verified by
this document**: the per-provider readiness round was still running per the parent review ledger
(parent-notes.md "REVIEW LEDGER (continued 4)"). The landed tree is present in the worktree
(`Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/**`).
The per-file counts above are the ones the workers and reviewers actually measured.

---

## 4. Blocked work, stated plainly

Sources for the block reasons below: findings/conditional-models.md §0, §8;
findings/sleep-boundary-stager.md §2.6; findings/impl-sleep-providers.md §6;
findings/impl-inference-hrv.md §6; findings/review-swift-client-r2.md §3 (F2);
findings/deployment-do.md §e.

| Blocked item | State | Reason |
| --- | --- | --- |
| `wav2sleep` adapter | Skipped | `blocked_input` — no qualified raw waveform on the product path |
| `no_eeg_sleep_staging` adapter | Skipped | `blocked_input` — motion features cannot be reproduced from a 1 Hz gravity summary |
| `rr_estimation` adapter | Skipped | `blocked_input` — no raw PPG, no 64 Hz 3-axis acceleration, no reference fixture |
| `stepcount` | Skipped | `blocked_license` — Academic Use Licence forbids product use |
| `cnn_wrist_model_freeliving` | Skipped | `blocked_license` — no licence file exists |
| Accuracy verification for any candidate | NOT RUN | No independent reference data (PSG/ECG) is available; spec §8 requires `unverified_accuracy` and unchanged production selection |
| Shadow evaluation of any metric | NOT RUN | All metrics ship `mode='off'`; enabling shadow is an operator action (see `rollout.md`) |
| Live-DB binding of the worker→RPC path | NOT RUN | No database was started for the worker review; the R1/R2 proofs are code-level (review F2) |
| Droplet-side verification (port free, firewall, disk) | NOT RUN | No host access (discovery report §6) |
