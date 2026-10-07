# Rhythm shadow adapters: provenance and verification record (W4)

Recorded 2026-10-06 from ACTUAL cloned/downloaded bytes. Both upstream trees
were cloned and the pinned commits verified with ``git rev-parse HEAD`` after
cloning; the staged artifacts were then downloaded from the pinned raw URLs by
``scripts/provision_deepbeat.py`` / ``scripts/provision_siamaf.py`` and their
sha256/size verified again (the downloaded bytes are identical to the cloned
ones).

## 1. DeepBeat

| Item | Value |
| --- | --- |
| upstream repo | https://github.com/AshleyLab/deepbeat |
| pinned commit | `f54004a80eaca99460d1e171c8ec203e182dacb9` (repository HEAD) |
| artifact | `deepbeat.h5` |
| size | 1,502,052 bytes (~1.5 MB) |
| sha256 | `6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3` |
| licence | GPL-3.0 (repository LICENSE; code and released weights). The training dataset is shared under a separate non-commercial data use agreement (Synapse syn21985690) and is NOT part of this adapter. |
| HDF5 metadata | keras_version 2.2.4, backend tensorflow; inputs `(None, 800, 1)` float32; outputs `qa_output` (3, softmax) and `rhythm_output` (2, sigmoid); training_config present (Adam, loss_weights [0.2, 5.0]). |
| layer inventory | standard Keras 2 layers only (InputLayer, Conv1D, MaxPooling1D, BatchNormalization, LeakyReLU, Dropout, Flatten, Dense) — no custom layers, so no `custom_objects` are required. |

### Load-path verdict: in-main-environment, Keras 3 + torch backend

`keras.saving.load_model(deepbeat.h5, compile=False)` loads in the project
environment (keras==3.15.1, KERAS_BACKEND=torch, torch==2.14.1) with no
TensorFlow runtime and no custom objects. Training is disabled: the model is
loaded with `compile=False` and every layer is set non-trainable.

Numeric parity with the original TF runtime was verified on this machine in a
small isolated venv (`/tmp/frwhoop-sensor-biomarkers/deepbeat-venv`,
`tensorflow==2.16.1` + numpy 1.26.4; this exact lock is what the venv
installed). The same 8 random `(800,1)` float32 segments produced:

| head | max abs diff (TF vs keras3+torch) | argmax agreement |
| --- | --- | --- |
| quality (3-class softmax) | 5.96e-08 | 8/8 |
| rhythm (2-class sigmoid) | 2.38e-07 | 8/8 |

That is agreement at float32 rounding level. No isolated legacy runtime is
needed for this artifact.

### Input/output contract (verified)

* input `(batch, 800, 1)` = 25 s at 32 Hz;
* quality classes poor=0, acceptable=1, excellent=2 (verified against
  `table_2.ipynb`: `excellent_qa_indx = np.where(predictions_QA == 2)[0]`);
* rhythm classes non-AF=0, AF=1 (verified against `utils.py`:
  `y_predictions = np.argmax(predictions_r, axis=1)` with labels [0, 1]);
* deterministic on CPU: repeated inference is bit-identical.

### Preprocessing provenance: UNRESOLVED

The upstream repository contains NO preprocessing code. `figure_1.ipynb` and
`table_2.ipynb` load already-processed `.npz` arrays (`np.load(...)['signal']`,
shape (N, 800)); the README points to a Synapse-hosted processed dataset. The
paper (Torres-Soto & Ashley 2020, doi:10.1038/s41746-020-00320-4) describes
bandpass + [0,1] normalisation + 128->32 Hz downsampling, but the exact filter
settings are not in the repository and were not established. Therefore:

* the adapter supports only an explicitly-marked tensor-compatibility
  experiment (FFT resample native 24/25 Hz -> 800 samples @32 Hz + min-max
  [0,1]; NO bandpass is invented or substituted);
* every DeepBeat score is `preprocessing_unverified` and `publishable=false`,
  carried in `raw_scores` research logs only;
* the family document is `withheld` with reason `preprocessing_unverified`;
* RR intervals, artifact-corrected HRV intervals and beat-normalised synthetic
  waveforms are never fed to this model.

## 2. SiamAF

| Item | Value |
| --- | --- |
| upstream repo | https://github.com/chengstark/SiamAF |
| pinned commit | `c05be9e37d2013d0817aafc5b2e72b2f7649e95e` (repository HEAD) |
| artifact | `proposed/saved_models/final_model.pt` |
| size | 10,915,597 bytes (~10.9 MB) |
| sha256 | `a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be` |
| licence | MIT (repository LICENSE, Copyright (c) 2024 Zhicheng Guo) |
| checkpoint type | `torch.save(model.state_dict())` of `nn.DataParallel(Res34SimSiam(512, 128, predictor=True))`; 186 keys, every key carries the verified leading `module.` prefix |

### Loading (verified)

`torch.load(..., map_location='cpu', weights_only=True)` on the sha256-verified
bytes; the verified leading `module.` prefix is stripped (all-or-nothing; a
mixed prefix is an error); `load_state_dict(strict=True)` has no missing and no
unexpected keys; `eval()` + `torch.inference_mode()`. No `strict=False` is used
anywhere.

### Two-argument forward (verified)

`Res34SimSiam.forward(self, ECG, PPG)` takes TWO positional arguments in every
mode. In `single_source_mode=True` the second argument is unused. The model
card example calls `model(signal)` with one argument, which fails on the real
network; the adapter wrapper passes the unused second argument explicitly and
never rewrites the learned network. Classification logits are the THIRD return
value (`classification_head`, 384-d pooled features -> 2 logits).

### Preprocessing (verified from source)

`data_processing/make_whole_data.py` `load_sigs_resample` is the published PPG
preparation: `scipy.signal.resample(ppg, 2400)` then per-segment min-max to
[0, 1]. The ECG bandpass in the same file is NOT a PPG preprocessing
instruction and is never applied. Input contract `(batch, 1, 2400)` = 30 s.
WHOOP's native 24/25 Hz differs from the training domain (240 Hz), so every
score records `domain_status=native_rate_mismatch` and stays nonpublishable
(WHOOP/ECG release gate). The upstream `sample_ppg.npy` fixture (2400,) was
executed through the adapter (finite logits).

## 3. Gates and fail-closed rules

* flags `FRWHOOP_DEEPBEAT_SHADOW_ENABLED` / `FRWHOOP_SIAMAF_SHADOW_ENABLED`
  enable each adapter; exactly `"1"` enables (off by default);
* artifacts must be present under the artifact root (`FRWHOOP_MODEL_ROOT` or
  `/opt/frwhoop-models`) and match the pinned sha256 BEFORE any model loads;
  missing/mismatched artifacts -> `not_ready` / `artifact_unavailable` with no
  effect on any other provider;
* flat, missing, short, mixed-channel and unverified-clock inputs are withheld
  with machine-readable reasons and can never become a normal classification;
* no AF notification, episode count, burden, medication advice or health-score
  contribution is ever produced;
* the runtime imports are lazy: importing the `rhythm` package never imports
  keras or torch.

## 4. Remaining gates (not cleared by this adapter)

* DeepBeat published preprocessing (filter design, exact normalisation) is
  unresolved upstream; the compatibility scores are nonpublishable.
* WHOOP native-rate domain mismatch for BOTH models (24/25 Hz vs 32 Hz
  DeepBeat, vs 240 Hz SiamAF training domain): tensor compatibility only.
* No ECG-labelled WHOOP recordings exist for sensitivity/specificity/FA-per-day
  evaluation; the WHOOP/ECG release gate stays closed.
* No independent accuracy reference; accuracy is `unverified_accuracy`.
