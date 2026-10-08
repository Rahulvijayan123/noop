# ActiNet Walmsley classifier: shadow activity-intensity adapter (Spec 03, candidate 1)

**Status (2026-10-08).** Built and tested. **Shadow only.** It is not registered with the worker and has no store,
route or app consumer. Activation is deferred on the owner's licence decision (§Licence) and on Spec 01 wiring
([integration/actinet_classifier.md](integration/actinet_classifier.md)). Against the deployed `actukb` bundle on
held-out external subjects there is **no statistically significant difference** (§10). Nothing here shows it is
more accurate on WHOOP data.

| | |
|---|---|
| Package | `Tools/ActivityContext/activity_context/actinet_classifier/` |
| Tests | `Tools/ActivityContext/tests/actinet_classifier/` (6 modules); fixtures `Tools/ActivityContext/fixtures/actinet_classifier/` |
| Process | `python -m activity_context.actinet_classifier.serve`, its own process |
| Wire schema | `actinet-classifier-1` |
| Release mode | `shadow`, fixed in code (`RELEASE_MODE`), on every ping and infer |
| Named consumer | `activity_intensity_shadow`: offline comparison only (integration fragment §5) |

The code cites this document by section: `weights.py` §1, `preprocess.py` §2, `model.py` §3, `hmm.py` §4,
`runtime.py` §5–6, `serve.py` §6, `__init__.py` §7.

## 1. Identity

ActiNet's default classifier: actinet 0.7.2 `__classifiers__["walmsley"]` (upstream's default `--classifier`).
This is the Walmsley 2020 intensity model, `ssl-ukb-c24-rw-30s-20260128`: the ssl-wearables harnet30 network
fine-tuned on all Capture-24 participants, plus a fitted HMM. It is **not** the Willetts 6-class file
`ssl-ukb-c24-mw-30s-20260128` that the Inertia encoder lane (`encoder_kind actinet`, `actc24`) uses.

| Item | Value |
|---|---|
| Upstream | `https://github.com/OxWearables/actinet` 0.7.2, commit `58d134b8be0965b5611aa589bc07a926de68f575` (tag v0.7.2) |
| Network | ssl-wearables v1.0.0 `hubconf.harnet30` (`is_eva=True`), 4 classes |
| Source file | `ssl-ukb-c24-rw-30s-20260128.joblib.lzma`: 40,902,237 B, sha256 `07dfd7482350dc30f0d69a4d59216caf0835bcca2d71d8e10a1243c8f7697fba`, md5 `a829041ba84b18084b4b2897fb1b36a6` (= upstream's own pin). URL `https://wearables-files.ndph.ox.ac.uk/files/models/actinet/ssl-ukb-c24-rw-30s-20260128.joblib.lzma` |
| Converted weights | `actinet-walmsley-20260128-weights.pt`: 44,077,763 B, sha256 `1a20251b3239a86867fc4233d6b2e2ba9371a69e26ca94576c6fc3e43c964dee`; plain `{name: tensor}`, loaded with `torch.load(weights_only=True)` |
| Converted HMM and labels | `actinet-walmsley-20260128-hmm.json` (`nara.actinet.hmm/1`): 1,489 B, sha256 `79cc17a6b288d72d5de11d0482b0a02b9f0ba7f76dde3cd657db8ff894824cb5` |
| Deployment pin | `artifact_digest` = `5d4d749a61d1b848d6930a66ee4c1d6aac9b236aeb6d2a3aeb9a8eb15864c941` (`weights.DEPLOYMENT_ARTIFACT_DIGEST`): sha256 over `actinet-classifier-artifact-1` and `role=sha256` for source, weights and hmm |
| Conversion environment | actinet 0.7.2, actipy 3.8.0, torch 2.8.0, joblib 1.2.*, numpy 1.24.*, Python 3.10. Byte-reproducible: run twice with identical output |

- **Operator steps** (offline, never at serve time): `python -m activity_context.actinet_classifier.weights fetch`,
  then `convert`, then `verify`. `fetch` checks size, sha256 and md5. `convert` checks the source before
  unpickling it, once, in the offline environment.
- **Load.** The serve process never unpickles. Every file is checked for size and then sha256 before any byte is
  parsed. A missing file is `model_missing`; any mismatch is `weights_mismatch`.
- **Not in git.** No weights or HMM parameters are committed (§Licence). The golden fixtures hold no Walmsley
  parameters: the HMM cases use synthetic matrices, and the e2e fixture holds upstream outputs for a synthetic
  request only.

**Class order** comes only from the HMM file. When the real pins are in use, `build_runtime` refuses
(`weights_mismatch`) any order other than `CLASS_ORDER`. That order is `light, moderate-vigorous, sedentary,
sleep`. The golden fixture (`golden_e2e.json` `classes`) and the head-to-head
script check the same order.

## 2. Input contract and preprocessing (`actinet-prep-1`)

**Native input.** WHOOP raw IMU as NPB1 `rawImuSession` seconds:

- Each second is int16[600]: 100 accelerometer samples per axis, then gyroscope.
- Accelerometer only: x, y, z at 1/4096 g per LSB, ±8 g, gravity kept, raw strap frame. The gyroscope is decoded,
  so a malformed second is refused, then ignored.
- Sample k of a run sits at `start_ts + k/100`. Per-sample hardware timing inside a second is not observable in
  NPB1.
- Runs are split by the shared HART decoder (`activity_context.preprocess._asof_split`):
  - a gap over 1 s starts a new run;
  - a duplicate second or a clock reset is refused.
- Nothing is filled across a gap.

**Sampling contract.**

| | Native | Model |
|---|---|---|
| Rate | 100 Hz | 30 Hz |
| Epoch | 30 s = 3000 samples | 900 samples |
| Tensor | — | `float32 [B, 3, 900]`, g, gravity kept, no normalisation |

**Steps.** Upstream's default path is `actinet.read` → actipy 3.8.0 `process` → `predict_from_frame`.

| Upstream step | Upstream behaviour | This revision |
|---|---|---|
| read | CSV x/y/z as float32 g | NPB1 i16 × 1/4096 g, exact in float32 |
| lowpass | none in the code path (`lowpass_hz=None`; the methods page's 20 Hz filter is not applied) | none |
| calibrate_gravity | van Hees fit over the whole recording when ≥ 50 stationary windows span every cube face | **not applied (D1)** |
| detect_nonwear | > 90 min stationary set to NaN | **not applied (D2)** |
| resample | nearest neighbour onto the native grid (an identity on uniform input) | identity; runs are uniform by construction |
| segment | 30 s bins from the first sample; 1500 < n < 3000 wrap-padded | 30 s bins from each run's first sample (`run` grid, served) or from the request start (`request` grid, offline parity). **Only fully covered bins are valid**; a partial bin is invalid with `partial_window` (D3) |
| resize | `interp1d(kind='linear')`, 3000 → 900 per window | the same arithmetic, own code, float64 |

Each valid epoch is a pure function of its own 3000 samples. Chunking a request differently does not change model
inputs (`test_model_inputs_do_not_depend_on_chunking`). An epoch never spans two runs
(`test_no_epoch_crosses_a_gap`).

**Supported windows and quality gates.**

- Valid: a 30 s span fully covered by one contiguous run.
- Invalid: everything else, reported with a reason (`partial_window`, `no_data`, `nonfinite_output`) and with no
  probabilities and no label.
- Limits: `sample_rate_hz` must be 100 and `channels_order` must be `[ax, ay, az, gx, gy, gz]`. A request holds
  at most 2,880 epochs, 4,000 runs and 86,400 s, in time order with no overlap. A request over a limit is
  refused, never truncated.
- The epoch limit counts invalid (partial) epochs too. A day of many sub-30 s runs could be refused as
  `too_many_epochs` while holding fewer than 2,880 valid epochs; the worker then splits the request at a gap.

**Not applied**, and why: calibration and non-wear detection need whole recordings or more than 90 minutes of
stillness. Neither can be computed from 60 s bursts, and imputing them would invent data. Upstream's daily
imputation and summaries are not run. Imputed time is never treated as observed.

## 3. Network

- harnet30 feature extractor, reused unchanged from the Inertia encoder lane's vendored copy
  (`inertia/vendor/ssl_wearables_resnet.py`), followed by Nara's head `Linear(1024, 512) → ReLU → Linear(512, 4)`.
  The head's module names match the checkpoint keys, and the state dict loads strictly: 135 keys with identical
  order, shapes and dtypes.
- CPU, fp32, `eval()`, `torch.inference_mode`, thread cap (default 1), NNPACK disabled.
- Every batch is zero-padded to `max_batch` rows (default 64), so an epoch's logits do not depend on the other
  epochs in its request (`test_network_is_deterministic_and_batch_independent`).
- Probabilities are `softmax(logits)` in float64, the transform upstream applies before fitting the HMM emission.
  They are **uncalibrated**: the released network has no calibration, and Nara fits none.

## 4. Temporal processing (`actinet-hmm-1`)

Upstream `ActivityClassifier.predict` → `hmm.HMM.predict`, re-implemented in numpy from its documented behaviour
(no upstream code copied):

1. One observation per valid epoch: the argmax class.
2. **One Viterbi pass over all valid epochs of the request, in time order, as if consecutive.** The prior is
   uniform (`uniform_prior=True` in the artifact). Dtypes follow upstream under numpy 1.24, so tie-breaking matches
   bit for bit (`test_matches_upstream_hmm_predict_exactly`).
3. **Gap restore:** an epoch that does not start exactly 30 s after the previous valid epoch gets its raw label
   back (`after_gap: true`).
4. `removeSpuriousSleep` is a no-op in upstream's default path and is not applied.

The Viterbi pass is **not** cut at gaps (an earlier STATUS.md line said it ran "inside each contiguous run"; that
was wrong). Epochs before a gap are therefore smoothed with evidence from after it, exactly as upstream does with a
gapped recording. Under Nara's default part-time capture (60 s in every 180 s), each burst holds one or two epochs,
and about half of all epochs follow a gap: 479 of 960 on a synthetic duty-cycled day. For those the HMM label is
the raw label. Treat the HMM output as meaningful only on continuous runs.

The wire says which labels those are:

- `label.contiguous_epochs[i]` is the length of the chain of valid epochs, exactly 30 s apart, that epoch `i`
  belongs to.
- `label.viterbi_spans_gaps` is true whenever the request has any gap.

A label in a short chain, including the epoch *before* a gap, leans on evidence from across the gap. A consumer
should weight or filter by `contiguous_epochs`. Test: `test_one_hmm_pass_spans_the_request_and_restores_after_gaps`.

## 5. Outputs

One response per request, with blocks of different types aligned by epoch index:

| Block | Content |
|---|---|
| `epochs[]` | `s`, `e` (UTC seconds), `valid`, `reason` |
| `logits` | `output_type: logits`: the network's output (upstream can return it, `sslmodel.predict(output_logits=True)`), 4 floats (6 dp) or `null` |
| `probabilities` | `output_type: class_probabilities`, `calibrated: false`, `derivation`: softmax of the logits in float64. Upstream's `predict()` returns labels only and uses this softmax to fit its HMM emission. 4 floats (6 dp) or `null` |
| `label` | `output_type: hmm_label`, `method: actinet-hmm-1`, `values[i]` = class name or `null`, `after_gap[i]`, `contiguous_epochs[i]`, `viterbi_spans_gaps` |
| `counts` | `epochs`, `valid`, `invalid` by reason |
| identity | `model_id`, `model_version`, `upstream`, `artifact.digest` and per-file sha256, `preprocessing_version`, `temporal_version`, `preprocessing_digest`, `input_digest`, `cache_key`, and `loaded_digest` once Spec 01 is merged |

- Logits, probabilities and labels are separate fields. The probabilities are a transform of the logits, not a
  separate model output; they are labelled so (Spec 03: keep probabilities only where the model returns them).
  The raw argmax is derivable from the logits and is not sent separately.
- **Cache identity** is `cache_key = sha256("actinet-classifier-cache-1\n" + input_digest + artifact_digest +
  preprocessing_digest)`.
  - `input_digest` covers each run's `start_ts,end_ts` and every body second's timestamp and 1,200 column bytes.
    Head and tail context are excluded because they cannot change the output.
  - `preprocessing_digest` covers the full preprocessing descriptor, including grid and batch rows.
  - Test: `test_cache_identity_covers_input_artifact_and_preprocessing`.
- **What the outputs mean.** Intensity context for a 30 s epoch, independent of heart rate. The `sleep` class is a
  motion-based label. **It is never sleep staging** and must not feed in-bed or asleep detection or any sleep
  metric.

## 6. Wire and process

`serve.py`: one JSON object per line on stdin and stdout, with ops `ping`, `infer` and `shutdown`.

- **Options:** `--artifact-dir` (or `$ACTINET_CLASSIFIER_DIR`), `--timeout` (default 60 s, SIGALRM),
  `--threads` (1), `--max-batch` (64), `--max-epochs` (2880).
- **Response cap:** 12 MiB per line; anything larger becomes `output_too_large`. NaN is refused.
- **Request cap:** a line over 192 MiB is refused as `malformed` before parsing
  (`test_oversized_request_line_is_refused_before_parsing`).
- **Threads:** when Spec 01's `loaded.py` exists, `serve` calls its `configure_torch_threads(--threads)`, which also
  fixes torch's inter-op pool at 1.
- **Errors:** `{"ok": false, "kind": malformed | model_missing | weights_mismatch | timeout | internal |
  output_too_large | too_many_epochs}`.
- **Load failure:** the process stays up. `ping` answers `model_available: false`, and every `infer` fails with the
  load failure's kind (`test_unavailable_runtime_keeps_answering`).
- **Independence:** no other lane imports this package, and this package imports neither the HART stack, the
  Inertia runtime nor ElderNet. A crash or timeout here cannot affect them.
- **Spec 01 identity:** when `activity_context/loaded.py` exists (Spec 01 merged), `ping` returns
  `loaded` (`activity-loaded-1`, all strings) and `loaded_digest`, and every `infer` repeats `loaded_digest`.
  - Keys: `schema`, `code_sha256`, `threads`, `env.*` (from `base_loaded`), and, once loaded, `weights_sha256`,
    `hmm_sha256`, `artifact_digest`, `preprocessing_digest`, `model_version`, `release_mode`, `grid`, `max_batch`.
  - Before that merge, both fields are absent.
  - Test: `test_loaded_identity_follows_spec01_when_present`; checked with the real artifact on a local merge
    (§11).

## 7. Release mode, consumer, fallback

- **Release mode.** `shadow` everywhere, a constant. No setting can raise it, and the wire carries it on every
  response (`test_every_output_is_shadow_and_names_its_consumer`).
- **Consumer.** `activity_intensity_shadow`: an offline comparison against `actukb` `movement_intensity` and
  reference labels, with no API, no app rendering and no canonical metric (integration fragment §5).
- **Fallback.** None needed. Production behaviour does not depend on this adapter. If the child is absent, off,
  unavailable or failing, nothing is stored, and HART, the motion heads, ElderNet and every canonical output are
  unchanged.
- **Isolation guard.** `test_no_production_path_references_the_shadow_classifier` fails if the worker, sidecar,
  backend, app packages and targets, deploy files, or another ActivityContext lane names the classifier. Wiring it
  must update that test in the same change.

## 8. Deviations from upstream, and the tests that cover them

| # | Deviation | Why | Test |
|---|---|---|---|
| D1 | No gravity calibration | Needs whole-recording stationary windows; not computable from bursts. Upstream also skips it unless ≥ 50 stationary windows span every face. | `test_request_grid_matches_upstream_on_the_whole_recording` (upstream reported `CalibOK 0`: a no-op there too) |
| D2 | No non-wear detection | Needs > 90 min of stillness | same test (upstream non-wear time 0) |
| D3 | A partially covered 30 s bin is invalid instead of wrap-padded | Padding invents data | `test_partial_tail_is_invalid_where_upstream_wrap_pads_it`; the e2e golden drops upstream's one wrap-padded tail epoch |
| D4 | Fixed padded batches of 64 with NNPACK off (upstream: batch 512, NNPACK at default) | Batch-independent outputs; CPU cost | logits within 2e-3 (observed ~3e-5), probabilities within 1e-4, labels exact: `test_served_run_grid_matches_upstream_per_run` |
| D5 | Served `run` grid: each run binned from its own first sample | A run is a recording; the request start is arbitrary | `test_served_run_grid_matches_upstream_per_run` (upstream with each run as its own file, one HMM over the concatenation); `test_window_alignment_of_the_two_grids` |
| D6 | Resize in float64, own code | Upstream's precision whenever any bin is invalid | `test_resize_is_bit_identical_to_upstream_golden`, `test_resize_matches_scipy_interp1d` |

**Parity claimed:** upstream's own outputs on a **synthetic** six-run request, on both grids (raw and HMM labels
exact, probabilities within 1e-4), and upstream HMM `predict` reproduced bit for bit. **Not claimed:** parity on real
WHOOP windows, for which no upstream output exists, or upstream behaviour when calibration or non-wear would have
acted.

## 9. Resources (this Mac only)

Apple M4 Max, 1 thread, `_build-scratch/spec03-motion/eval/measure_actinet.json`, measured 2026-10-07 (machine
load not recorded):

| Case | Epochs | CPU s | Wall s | RSS |
|---|---|---|---|---|
| Model load | — | — | 3.2 | 341 MB after load |
| One continuous hour | 120 | 0.58 | 0.95 | 699 MB |
| Duty-cycled day (480 bursts) | 960 | 4.44 | 8.07 | 1,008 MB |
| Largest request (24 h continuous) | 2,880 | 11.98 | 18.27 | 1,227 MB (peak) |
| NNPACK on, for comparison | 120 | 15.73 | — | — |

- Request JSON for a duty-cycled day is 46 MB, and the response 107 KB.
- The 2026-10-08 head-to-head (§10, load average ~700 from other jobs) measured 7.5 CPU-ms per epoch, against
  155 CPU-ms per epoch for the deployed `actukb` path in the same process. **The two figures are not comparable as
  model cost.** The deployed Inertia encoder runs with NNPACK at its default: 14.7 CPU-s against 0.48 for 119
  windows with it off (`measure_nara.json`). Spec 01 has since disabled NNPACK in that encoder on its branch; it is
  not deployed.
- **Droplet not measured.** It needs the owner's approval.

## 10. Head-to-head on held-out external data

**Setup.** `_build-scratch/spec03-motion/scripts/head_to_head.py` (v2, 2026-10-08); results in `eval/`.

- **Comparator.** v2 builds the comparator with the serve child's own `inertia.runtime.build_runtime`. The encoder
  id, preprocessing and digests come from the bundle manifest, and the checkpoint must match the bundle's
  `encoder.checkpoint_sha256`. v1 hard-coded the c24 encoder (kept as `head_to_head_c24_v1.py`).
- **Subjects.** Read from the frozen splits; their combined digest must equal the bundle's `split_manifest_sha256`
  (`f96f41f6205c5c44ed08d1196f0083622a68156968ff379bde3598ae83db1dbc`, the same for `actukb` and `actc24`; verified).
  The test subjects are PAMAP2 subject101 and subject104, and GOTOV 07, 18, 22, 26, 27, 32 and 36. Both datasets are
  outside Capture-24, so they are external for ActiNet and held out for the Nara heads.
- **Reference.** PAMAP2 protocol METs; GOTOV COSMED-measured METs (≥ 90 % of the epoch measured).
  Sedentary < 1.5 MET, light 1.5–3, MVPA ≥ 3.
- **Labels compared.**
  - ActiNet: `sleep` merged into sedentary (awake-only protocols).
  - Nara `movement_intensity`: a regression head, cut at ln 1.5/ln 12 and ln 3/ln 12. That cut is a rule made for
    this comparison, not a trained classifier.
- **Same epochs** for both: ActiNet's `run`-grid epochs that the Nara path can also score (≥ 1 s from a run edge).

**Deployed bundle `shadow-ncsa-primary-actukb`** (bundle_sha256 `aba9a811…`, encoder
`actinet/harnet30-ssl-ukb/30s@20hz`, checkpoint `28f8bcd7…`; `eval/head_to_head_actukb.json`):

| Set | n | ActiNet HMM macro-F1 / acc | ActiNet raw macro-F1 / acc | `actukb` macro-F1 / acc | Agreement (κ) |
|---|---|---|---|---|---|
| PAMAP2 | 125 | 0.734 / 0.784 | 0.777 / 0.832 | **0.796 / 0.840** | 0.784 (0.651) |
| GOTOV | 188 | **0.836 / 0.846** | 0.789 / 0.809 | 0.751 / 0.750 | 0.830 (0.741) |
| Pooled | 313 | **0.809 / 0.821** | 0.800 / 0.818 | 0.776 / 0.786 | 0.812 (0.717) |

Per class, pooled (precision / recall):

| Class (support) | ActiNet HMM | `actukb` |
|---|---|---|
| sedentary (90) | 0.705 / 0.956 | 0.755 / 0.789 |
| light (97) | 0.769 / 0.619 | 0.657 / 0.670 |
| MVPA (126) | 0.982 / 0.881 | 0.917 / 0.873 |

Confusion (rows truth sedentary/light/MVPA, columns predicted):

- ActiNet HMM: `[[86,4,0],[35,60,2],[1,14,111]]`
- `actukb`: `[[71,19,0],[22,65,10],[1,15,110]]`

ActiNet calls 35 of 97 light epochs sedentary; `actukb` spreads its errors across both neighbours.

**Uncertainty and significance** (pooled, 9 subjects):

- Subject-cluster bootstrap (2,000 draws), macro-F1:
  - ActiNet HMM [0.695, 0.897]; `actukb` [0.655, 0.829].
  - **Difference [−0.075, 0.147]**, P(difference ≤ 0) = 0.27.
- Exact subject sign-flip test on per-subject accuracy: mean difference +0.067, **p = 0.23** (512 permutations).
  ActiNet is better for 6 subjects, worse for 2 (PAMAP2 subject104 −0.23, GOTOV26 −0.08), and equal for 1.
- Epoch-level McNemar: 35 epochs only ActiNet right, 24 only `actukb` right, p = 0.19. It assumes independent
  epochs, which these are not.
- Within GOTOV, the epoch-level McNemar is p = 0.002 but the subject-level sign flip is p = 0.125. The epoch test
  overstates the evidence.

**Coverage and abstention.**

- ActiNet scored 1,057 of 1,115 epochs. All 58 invalid ones were partial windows at run edges (D3): time coverage
  0.963 on PAMAP2 and 0.995 on GOTOV.
- The `actukb` path scored 96.9 % of ActiNet's reference epochs. It skips epochs within 1 s of a run edge.
- `actukb` flags 17.6 % of the common epochs as out-of-distribution: 24 % on PAMAP2, 13 % on GOTOV. Nothing in the
  production decode acts on OOD for this head, so the main table counts them. If `actukb` abstained on OOD epochs
  (n = 258), pooled macro-F1 would be **0.806 (ActiNet) and 0.798 (`actukb`)**, essentially level.
- ActiNet predicted `sleep` on 4 awake GOTOV epochs. The HMM changed the raw label on 23 of 313.
- PAMAP2 sensitivity (lying and sitting counted as sedentary regardless of protocol MET): ActiNet 0.900,
  `actukb` 0.813 macro-F1. The PAMAP2 result depends on how the reference treats those postures.

**Earlier Capture-24 comparator.** v1 against `shadow-ncsa-primary-actc24`, the same 313 epochs,
`eval/head_to_head.json`:

| Set | ActiNet HMM | `actc24` |
|---|---|---|
| PAMAP2 | 0.734 | 0.790 |
| GOTOV | 0.836 | 0.734 |
| Pooled | 0.809 | 0.758 |

Difference CI [−0.011, 0.168], P = 0.061.

### 10.1 `actc24` rerun with v2

`eval/head_to_head_c24_v2.json`. Encoder `actinet/harnet30-c24-mw/30s@20hz`, checkpoint `46732ff2…`, same split
digest. v2 reproduces v1 exactly: pooled 0.809 vs 0.758, CI [−0.011, 0.168], P = 0.061. It adds:

| Set | ActiNet HMM | `actc24` | κ | `actc24` OOD | Subject sign-flip p | Epoch McNemar p |
|---|---|---|---|---|---|---|
| PAMAP2 | 0.734 | 0.790 | 0.700 | 11.2 % | 0.50 | 0.54 |
| GOTOV | 0.836 | 0.734 | 0.682 | 4.3 % | 0.078 | 0.0007 |
| Pooled | 0.809 | 0.758 | 0.697 | 7.0 % | 0.090 | 0.033 |

Against `actc24`, the epoch-level McNemar test is nominally significant pooled, but it treats clustered epochs as
independent. The subject-level tests are not significant (p = 0.090, and P = 0.061 by bootstrap).

`actc24` is not deployed. It is also in-sample for Capture-24, which matters only for Capture-24 evaluation, not
here.

**Verdict.** On these 9 external subjects, ActiNet's 4-class output is **not shown to be better or worse** than the
deployed `actukb` intensity head cut into the same three classes. The direction depends on the dataset (better on
GOTOV's measured METs, worse on PAMAP2's protocol METs), and the subject-level tests are far from significant.
Nine subjects cannot settle a difference of this size.

The direction on PAMAP2 also depends on the reference. Its protocol METs put sitting and standing (1.8 MET) in
*light*, against the usual sedentary-behaviour definition, which counts sitting and lying as sedentary. Under that
posture-based reference ActiNet scores 0.900 against `actukb`'s 0.813.

There is no WHOOP intensity reference at all. **No improvement is claimed.**

## 11. Spec 01 integration

What Spec 01 must add (worker stage, new shadow table, authority channel `activity_intensity` with `use: none`,
heartbeat line, tests) is in [integration/actinet_classifier.md](integration/actinet_classifier.md). Spec 03 changes
none of Spec 01's files.

Checked on a local merge of Spec 01 `783ac84da` into this branch (worktree `_build-scratch/spec03-spec01-merge`,
branch `check/spec03-on-spec01-20261008`, not pushed):

- the ActiNet tests and Spec 01's `test_loaded.py` pass: 55 passed, 1 skipped (the skip needs a HART checkpoint);
- with the real artifact, `ping` and `infer` carry an all-string `loaded` map whose digest equals Spec 01's
  `loaded_digest()`, with `weights_sha256 1a20251b…`, `hmm_sha256 79cc17a6…` and `artifact_digest 5d4d749a…`, and
  every block is `shadow` (`eval/merged_identity_check.json`).

The verified path is **input → preprocessing → inference → shadow response**. Persistence and inspection cannot
be verified yet: no store exists on either branch.

## 12. Open gates

1. **Licence (owner).** See §Licence.
2. **Spec 01 wiring and store** (integration fragment).
3. **Droplet CPU and memory**, which needs approval.
4. **A WHOOP intensity reference.** None exists; 12 guided labels and 40 stretch verdicts carry no intensity.
5. **Continuous capture** for the HMM to add anything (§4).
6. **A product use** that `movement_intensity` cannot serve. Until one is named, the adapter stays a research
   comparison.

## Licence

actinet and ssl-wearables are **University of Oxford software under its Academic Use Licence** ("Copyright © 2022,
University of Oxford"; actinet `LICENSE.md` sha256 `9a4f1846…`), not CC BY-NC 4.0 as `NOTICE.md:347` and
`inertia/registry.py:37` say.

- Use is limited to the licensee's own internal academic, non-commercial research (1.1(a)).
- Use for or on behalf of a third party, or to provide a service, is excluded (1.1(b)).
- Redistribution only on the licence's own terms (1.2).

This package adds no Oxford code. It reuses the already-vendored harnet30 extractor; the head, preprocessing and
HMM are Nara's own. No weights or HMM parameters are committed. Running the classifier on beta testers' data would
likely be a service under 1.1(b). The same question already applies to the live `actukb` and ElderNet lanes, which
have no per-account gate. Use-by-use reading, the audience facts and proposed NOTICE/registry text:
[integration/licence-corrections.md](integration/licence-corrections.md). This is an engineering reading, not legal
advice. The decision is the owner's.
