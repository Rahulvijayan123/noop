"""DeepBeat shadow adapter (disabled research; never user-facing).

Artifact: ``deepbeat.h5`` (~1.5 MB) from the AshleyLab/deepbeat repository at
the pinned commit below. The HDF5 model and the repository code are GPL-3.0;
the training dataset is shared under a separate non-commercial data use
agreement (Synapse ID syn21985690) and is NOT part of this adapter. No dataset
download is required for inference-only use of the released weights.

Provenance (recorded 2026-10-06)
-------------------------------
* upstream repo:   https://github.com/AshleyLab/deepbeat
* pinned commit:   f54004a80eaca99460d1e171c8ec203e182dacb9 (repository HEAD,
                   verified with ``git rev-parse HEAD`` after clone)
* artifact:        deepbeat.h5
* size:            1,502,052 bytes
* sha256:          6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3
* licence:         GPL-3.0 (code and released weights); dataset terms separate
* HDF5 metadata:   keras_version 2.2.4, backend tensorflow, training_config
                   present (Adam, loss_weights [0.2, 5.0])

Load path (verified)
--------------------
The current environment (keras==3.15.1 with the torch backend) loads this
legacy Keras 2 HDF5 directly via ``keras.saving.load_model(path,
compile=False)`` with NO custom_objects: every layer in the serialised config
(Conv1D, MaxPooling1D, BatchNormalization, LeakyReLU, Dropout, Flatten, Dense,
InputLayer) is a standard Keras layer. Numeric parity with the original
TensorFlow runtime was verified on this machine: a small isolated venv with
``tensorflow==2.16.1`` produced identical outputs (max abs diff 5.96e-08 on
the 3-class quality head and 2.38e-07 on the 2-class rhythm head over 8 random
segments; argmax identical for every row), i.e. agreement at float32 rounding
level. No TensorFlow runtime is required in this package.

Input/output contract (verified against the pinned model + original eval code)
------------------------------------------------------------------------------
* input:  (batch, 800, 1) float32, 25-second PPG segments at 32 Hz
* output 0 (qa_output): 3 classes, softmax; index order per the paper and the
  evaluation notebooks: poor=0, acceptable=1, excellent=2
* output 1 (rhythm_output): 2 classes, sigmoid; per utils.py and the paper:
  non-AF=0, AF=1 (``np.argmax(predictions_r, axis=1)`` in utils.py, labels
  [0, 1] in the confusion matrix)
* deterministic: repeated inference on the same CPU input is bit-identical
* training disabled: model is loaded with ``compile=False`` and used only for
  inference; dropout/BatchNorm stay in inference mode

Preprocessing status: UNRESOLVED
--------------------------------
The paper describes bandpass filtering, [0,1] normalisation and 128->32 Hz
downsampling, but the upstream repository contains NO preprocessing code: the
evaluation notebooks (figure_1.ipynb, table_2.ipynb) load already-processed
``.npz`` arrays and the README points at a Synapse-hosted processed dataset.
The exact original filter settings could not be traced in the repository, so
this adapter does NOT claim to reproduce the published pipeline and does NOT
invent cutoffs. It supports an explicitly-marked tensor-compatibility
experiment only: native 24/25 Hz WHOOP windows are FFT-resampled to 800
samples (32 Hz) and min-max normalised to [0,1]. Every score it produces is
flagged ``preprocessing_unverified`` and ``publishable=false``; the rhythm
results are withheld from any publishable path. Resampling to 32 Hz provides
tensor compatibility only, never sensor/domain equivalence. RR intervals,
artifact-corrected HRV intervals and beat-normalised waveforms are NEVER fed
to this model.
"""

from __future__ import annotations

import os
import time
from typing import Any

import numpy as np

from ._common import (artifact_root, cached_sha256, is_flat, iter_windows, min_max01,
                      score_vector, verify_file_sha256)

#: Pinned artifact metadata (recorded from the actual cloned bytes).
UPSTREAM_REPO = "https://github.com/AshleyLab/deepbeat"
PINNED_COMMIT = "f54004a80eaca99460d1e171c8ec203e182dacb9"
ARTIFACT_NAME = "deepbeat.h5"
ARTIFACT_SIZE = 1_502_052
ARTIFACT_SHA256 = "6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3"
LICENSE = "GPL-3.0"
#: Relative path under the artifact root (parent merges this into manifest.json).
ARTIFACT_RELPATH = f"deepbeat/{PINNED_COMMIT[:10]}/{ARTIFACT_NAME}"

SEGMENT_SECONDS = 25.0
INPUT_SAMPLES = 800
INPUT_RATE_HZ = 32.0
#: Quality class index order, verified against the pinned model + table_2.ipynb
#: (``excellent_qa_indx = np.where(predictions_QA == 2)[0]``).
QUALITY_CLASSES = ["poor", "acceptable", "excellent"]
#: Rhythm class index order, verified against utils.py (labels [0, 1]).
RHYTHM_CLASSES = ["non_af", "af"]
PROVIDER_REVISION = "deepbeat/1.0.0"

#: Keras must know its backend before the first import. The project environment
#: has no TensorFlow; the torch backend is the audited load path (parity above).
os.environ.setdefault("KERAS_BACKEND", "torch")


class DeepBeatAdapter:
    """Inference-only DeepBeat shadow adapter (real weights, no training).

    ``_model`` is loaded lazily on first use so a missing artifact or a broken
    keras import can never break startup of the other sensor-biomarker
    families.
    """

    def __init__(self, checkpoint_path: str | None = None, *,
                 expected_sha256: str = ARTIFACT_SHA256):
        root = artifact_root()
        self.checkpoint_path = checkpoint_path or os.path.join(root, ARTIFACT_RELPATH)
        self.expected_sha256 = expected_sha256
        self._model: Any | None = None
        self.load_error: str | None = None

    # -- readiness -----------------------------------------------------------
    @property
    def artifact_present(self) -> bool:
        return os.path.isfile(self.checkpoint_path)

    def readiness(self) -> tuple[bool, str | None]:
        if not self.artifact_present:
            return False, "artifact_unavailable"
        try:
            actual = cached_sha256(self.checkpoint_path)
        except OSError as exc:
            return False, f"artifact_unavailable: {exc}"
        if actual.lower() != self.expected_sha256.lower():
            return False, "artifact_mismatch"
        return True, None

    # -- model load -----------------------------------------------------------
    def _load_model(self) -> Any:
        if self._model is not None:
            return self._model
        if not self.artifact_present:
            raise FileNotFoundError(f"deepbeat artifact not found: {self.checkpoint_path}")
        actual = verify_file_sha256(self.checkpoint_path, self.expected_sha256)
        import keras  # local import: heavy optional runtime

        model = keras.saving.load_model(self.checkpoint_path, compile=False)
        # Training disabled: the loaded graph is used for inference only.
        for layer in model.layers:
            layer.trainable = False
        self._model = model
        self.loaded_sha256 = actual
        return model

    # -- compatibility preprocessing ------------------------------------------
    def preprocess_window(self, samples: np.ndarray, native_rate_hz: float) -> np.ndarray:
        """Tensor-compatibility preprocessing (explicitly NOT the published pipeline).

        Native 25-second window -> 800 samples at 32 Hz (FFT resample) ->
        min-max [0,1]. No bandpass is applied (the published filter settings
        are unresolved; a substitute filter would be mislabelled as the
        published pipeline). Callers must treat the result as unverified.
        """
        if is_flat(samples):
            raise ValueError("flat_ppg_segment")
        native_per_window = int(round(SEGMENT_SECONDS * native_rate_hz))
        if samples.size != native_per_window:
            raise ValueError(
                f"window length {samples.size} != {native_per_window} "
                f"({SEGMENT_SECONDS:g}s at {native_rate_hz:g} Hz)")
        from scipy.signal import resample  # local import: optional dependency

        resampled = resample(samples, INPUT_SAMPLES)
        normalized = min_max01(resampled)
        return normalized.reshape(INPUT_SAMPLES, 1).astype(np.float32)

    # -- inference ------------------------------------------------------------
    def infer(self, ppg: dict[str, Any], *, deadline: float | None = None) -> dict[str, Any]:
        """Run the compatibility experiment over the PPG payload's runs.

        Returns ``{"status", "reason", "windows", "quality", "rhythm"}`` where
        ``quality``/``rhythm`` are score-vector measurement dicts (None when no
        window ran). ``status`` is ``"preprocessing_unverified"`` whenever any
        window ran (it always does for this adapter) and ``"error"`` with a
        machine-readable reason otherwise. ``deadline`` (``time.monotonic()``)
        bounds the inference loop; past it nothing partial is returned.
        """
        native = float(ppg["native_rate_hz"])
        windows = list(iter_windows(ppg, window_seconds=SEGMENT_SECONDS,
                                    window_samples=int(round(SEGMENT_SECONDS * native))))
        if not windows:
            return {"status": "error", "reason": "not_enough_valid_data",
                    "windows": 0, "quality": None, "rhythm": None}
        # Prepare every window BEFORE loading the model: a flat, short or
        # otherwise invalid window must never be fed to the network, and an
        # all-invalid payload must never even load the weights (fail-closed:
        # missing/poor/flat input never becomes a normal classification).
        prepared: list[np.ndarray] = []
        for window in windows:
            try:
                prepared.append(self.preprocess_window(window["samples"], native))
            except ValueError:
                return {"status": "error", "reason": "not_enough_valid_data",
                        "windows": 0, "quality": None, "rhythm": None}
        model = self._load_model()
        qa_rows: list[list[float]] = []
        rhythm_rows: list[list[float]] = []
        for x in prepared:
            if deadline is not None and time.monotonic() > deadline:
                return {"status": "error", "reason": "timeout",
                        "windows": 0, "quality": None, "rhythm": None}
            batch = x[None, ...]  # (1, 800, 1)
            qa, rhythm = model.predict(batch, verbose=0)
            qa_rows.append([float(v) for v in qa[0]])
            rhythm_rows.append([float(v) for v in rhythm[0]])
        n = len(qa_rows)
        method = (f"{PROVIDER_REVISION} shadow inference, compatibility preprocessing "
                  f"(FFT resample {native:g}->{INPUT_RATE_HZ:g} Hz + min-max; no bandpass; "
                  f"not the published pipeline)")
        provenance = [{"run": w["run"], "start_unix": w["start_unix"]} for w in windows]
        quality = score_vector(
            key="deepbeat_quality_scores", scores=qa_rows, classes=QUALITY_CLASSES,
            count=n, method=method, native_rate_hz=native,
            segment_seconds=SEGMENT_SECONDS, samples_per_segment=INPUT_SAMPLES,
            preprocessing_status="preprocessing_unverified", publishable=False,
            domain="ppg_waveform", domain_status="tensor_compatibility_resample",
            model_input_rate_hz=INPUT_RATE_HZ, windows=provenance)
        rhythm = score_vector(
            key="deepbeat_rhythm_scores", scores=rhythm_rows, classes=RHYTHM_CLASSES,
            count=n, method=method, native_rate_hz=native,
            segment_seconds=SEGMENT_SECONDS, samples_per_segment=INPUT_SAMPLES,
            preprocessing_status="preprocessing_unverified", publishable=False,
            domain="ppg_waveform", domain_status="tensor_compatibility_resample",
            model_input_rate_hz=INPUT_RATE_HZ, windows=provenance)
        return {"status": "preprocessing_unverified", "reason": "preprocessing_unverified",
                "windows": n, "quality": quality, "rhythm": rhythm}


__all__ = [
    "DeepBeatAdapter", "UPSTREAM_REPO", "PINNED_COMMIT", "ARTIFACT_NAME",
    "ARTIFACT_SIZE", "ARTIFACT_SHA256", "ARTIFACT_RELPATH", "LICENSE",
    "SEGMENT_SECONDS", "INPUT_SAMPLES", "INPUT_RATE_HZ", "QUALITY_CLASSES",
    "RHYTHM_CLASSES", "PROVIDER_REVISION",
]
