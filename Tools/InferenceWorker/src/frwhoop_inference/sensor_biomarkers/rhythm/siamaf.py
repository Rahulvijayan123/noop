"""SiamAF shadow adapter (optional; MIT; never user-facing).

Artifact: ``proposed/saved_models/final_model.pt`` (~10.9 MB) from the
chengstark/SiamAF repository at the pinned commit below. Source is MIT
(Copyright (c) 2024 Zhicheng Guo); the repository LICENSE file was verified.
Training data (Institution A bedside monitors) is private and not part of this
adapter; no dataset download is required for inference-only use.

Provenance (recorded 2026-10-06)
-------------------------------
* upstream repo:   https://github.com/chengstark/SiamAF
* pinned commit:   c05be9e37d2013d0817aafc5b2e72b2f7649e95e (repository HEAD,
                   verified with ``git rev-parse HEAD`` after clone)
* artifact:        proposed/saved_models/final_model.pt
* size:            10,915,597 bytes
* sha256:          a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be
* licence:         MIT
* saved as:        ``torch.save(model.state_dict(), ...)`` (main.py) of
                   ``nn.DataParallel(Res34SimSiam(512, 128, predictor=True))``
* state dict:      186 keys, EVERY key carries a verified leading ``module.``
                   prefix (verified 2026-10-06 with weights_only=True load)

Architecture (vendored in ``_siamaf_vendored.py``)
--------------------------------------------------
``Res34SimSiam(512, 128, single_source_mode=True)``: ResNet-34 1-D encoder
with a 3-layer projector (``encoder.fc``), a 2-layer predictor
(``predictor``, 512->128->512) and a ``classification_head`` Linear(384, 2)
that produces the AF/non-AF logits from the pooled features.

The actual ``forward(self, ECG, PPG)`` takes TWO positional arguments in every
mode, including ``single_source_mode=True`` where ``PPG`` is unused. The model
card example calls ``model(signal)`` with one argument, which fails on the
real network. This adapter wraps the pinned implementation and passes the
unused second argument explicitly; the learned network is never rewritten.

Checkpoint loading (verified)
-----------------------------
* ``torch.load(..., map_location="cpu", weights_only=True)`` on the verified
  bytes (sha256 checked BEFORE unpickling);
* the verified leading ``module.`` prefix is stripped (all-or-nothing; a mixed
  prefix is an error, no prefix is left untouched);
* ``model.load_state_dict(..., strict=True)`` -- no ``strict=False``;
* ``model.eval()`` + ``torch.inference_mode()`` on CPU.

Preprocessing (verified from the source repository)
---------------------------------------------------
``data_processing/make_whole_data.py`` ``load_sigs_resample`` is the published
PPG preparation: ``scipy.signal.resample(ppg, 2400)`` then per-segment
min-max to [0, 1]. The ECG bandpass in the same file is NOT a PPG
preprocessing instruction and is never applied. The released input contract is
``(batch, 1, 2400)`` for a 30-second segment. Native WHOOP PPG (24/25 Hz)
differs from the training domain (240 Hz); resampling provides tensor
compatibility only, so every score records ``domain_status`` =
``native_rate_mismatch`` and stays nonpublishable (WHOOP/ECG release gate).
Flat/missing/short/mixed-channel/unverified-clock input never becomes a
classification: it is withheld with a machine-readable reason.
"""

from __future__ import annotations

import os
from typing import Any

import numpy as np

from ._common import (artifact_root, is_flat, iter_windows, min_max01,
                      score_vector, sha256_file, verify_file_sha256)

UPSTREAM_REPO = "https://github.com/chengstark/SiamAF"
PINNED_COMMIT = "c05be9e37d2013d0817aafc5b2e72b2f7649e95e"
ARTIFACT_NAME = "final_model.pt"
ARTIFACT_SIZE = 10_915_597
ARTIFACT_SHA256 = "a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be"
LICENSE = "MIT"
#: Relative path under the artifact root (parent merges this into manifest.json).
ARTIFACT_RELPATH = f"siamaf/{PINNED_COMMIT[:10]}/{ARTIFACT_NAME}"

SEGMENT_SECONDS = 30.0
INPUT_SAMPLES = 2400
#: Classification logits: index 0 = non-AF, index 1 = AF (model card + dataset.py).
RHYTHM_CLASSES = ["non_af", "af"]
PROVIDER_REVISION = "siamaf/1.0.0"

#: Training-domain native rate (240 Hz = 7200 samples per 30 s, resampled to
#: 2400 in make_whole_data.py). Recorded so consumers can see the domain gap
#: to WHOOP's 24/25 Hz.
SOURCE_NATIVE_RATE_HZ = 240.0


class SiamAFAdapter:
    """Inference-only SiamAF shadow adapter (real weights, no training).

    The torch runtime and the vendored architecture are imported lazily on
    first use so a missing artifact can never break startup of the other
    sensor-biomarker families.
    """

    def __init__(self, checkpoint_path: str | None = None, *,
                 expected_sha256: str = ARTIFACT_SHA256):
        self.checkpoint_path = checkpoint_path or os.path.join(
            artifact_root(), ARTIFACT_RELPATH)
        self.expected_sha256 = expected_sha256
        self._model: Any | None = None
        self.loaded_sha256: str | None = None

    @property
    def artifact_present(self) -> bool:
        return os.path.isfile(self.checkpoint_path)

    def readiness(self) -> tuple[bool, str | None]:
        if not self.artifact_present:
            return False, "artifact_unavailable"
        try:
            actual = sha256_file(self.checkpoint_path)
        except OSError as exc:
            return False, f"artifact_unavailable: {exc}"
        if actual.lower() != self.expected_sha256.lower():
            return False, "artifact_mismatch"
        return True, None

    @staticmethod
    def _strip_prefix(state: dict) -> dict:
        """Strip a VERIFIED leading ``module.`` prefix (DataParallel save).

        All-or-nothing: every key must carry the prefix (then only the prefix
        is stripped) or none may (then the dict is returned untouched). A mixed
        prefix is an error because silently dropping some prefixes would load
        the wrong weights.
        """
        keys = list(state.keys())
        if not keys:
            raise ValueError("siamaf checkpoint state_dict is empty")
        prefixed = sum(1 for k in keys if k.startswith("module."))
        if prefixed == len(keys):
            return {k[7:]: v for k, v in state.items()}
        if prefixed:
            raise ValueError("siamaf checkpoint has a mixed module. prefix")
        return dict(state)

    def _load_model(self) -> Any:
        if self._model is not None:
            return self._model
        if not self.artifact_present:
            raise FileNotFoundError(f"siamaf artifact not found: {self.checkpoint_path}")
        # Verify the bytes BEFORE unpickling; only pinned trusted assets are loaded.
        self.loaded_sha256 = verify_file_sha256(self.checkpoint_path, self.expected_sha256)

        import torch  # local import: heavy optional runtime
        from ._siamaf_vendored import Res34SimSiam

        state = torch.load(self.checkpoint_path, map_location="cpu", weights_only=True)
        if not isinstance(state, dict):
            raise ValueError("siamaf checkpoint is not a state_dict")
        if not state:
            raise ValueError("siamaf checkpoint state_dict is empty")
        state = self._strip_prefix(state)

        model = Res34SimSiam(512, 128, single_source_mode=True)
        missing, unexpected = model.load_state_dict(state, strict=True)
        if missing or unexpected:
            raise ValueError(
                "siamaf strict load failed: "
                f"missing={missing[:5]!r} unexpected={unexpected[:5]!r}")
        model.eval()
        self._model = model
        return model

    def preprocess_window(self, samples: np.ndarray, native_rate_hz: float) -> np.ndarray:
        """The source PPG preparation (make_whole_data.py): FFT resample to
        2400 + per-segment min-max. Returns shape ``(1, 2400)`` float32."""
        if is_flat(samples):
            raise ValueError("flat_ppg_segment")
        native_per_window = int(round(SEGMENT_SECONDS * native_rate_hz))
        if samples.size != native_per_window:
            raise ValueError(
                f"window length {samples.size} != {native_per_window} "
                f"({SEGMENT_SECONDS:g}s at {native_rate_hz:g} Hz)")
        from scipy.signal import resample  # local import

        resampled = resample(samples, INPUT_SAMPLES)
        normalized = min_max01(resampled)
        return normalized.reshape(1, INPUT_SAMPLES).astype(np.float32)

    def _classify(self, window_ppg: np.ndarray) -> np.ndarray:
        """Thin wrapper: the pinned forward takes two arguments even in
        single-source mode; pass the unused second argument explicitly."""
        import torch

        model = self._load_model()
        x = torch.from_numpy(window_ppg.reshape(1, 1, INPUT_SAMPLES))  # (1, 1, 2400)
        with torch.inference_mode():
            _, _, class_pred = model(x, x)
        return class_pred.detach().cpu().numpy().astype(np.float64).reshape(-1)

    def infer(self, ppg: dict[str, Any]) -> dict[str, Any]:
        """Run the shadow inference over the PPG payload.

        Returns ``{"status", "reason", "windows", "rhythm"}`` where ``rhythm``
        is a score-vector measurement (None when no window ran).
        """
        native = float(ppg["native_rate_hz"])
        window_samples = int(round(SEGMENT_SECONDS * native))
        windows = list(iter_windows(ppg, window_seconds=SEGMENT_SECONDS,
                                    window_samples=window_samples))
        if not windows:
            return {"status": "error", "reason": "not_enough_valid_data",
                    "windows": 0, "rhythm": None}
        # Prepare every window BEFORE loading the model (flat/short/invalid
        # windows are never fed to the network; see deepbeat.py).
        prepared: list[np.ndarray] = []
        for window in windows:
            try:
                prepared.append(self.preprocess_window(window["samples"], native))
            except ValueError:
                return {"status": "error", "reason": "not_enough_valid_data",
                        "windows": 0, "rhythm": None}
        rows: list[list[float]] = []
        for x in prepared:
            logits = self._classify(x)
            rows.append([float(v) for v in logits])
        n = len(rows)
        method = (f"{PROVIDER_REVISION} shadow inference, source PPG resampling "
                  f"(scipy.signal.resample to {INPUT_SAMPLES} + min-max)")
        rhythm = score_vector(
            key="siamaf_rhythm_scores", scores=rows, classes=RHYTHM_CLASSES,
            count=n, method=method, native_rate_hz=native,
            segment_seconds=SEGMENT_SECONDS, samples_per_segment=INPUT_SAMPLES,
            preprocessing_status="verified_from_source", publishable=False,
            domain="ppg_waveform", domain_status="native_rate_mismatch",
            extra={"source_native_rate_hz": SOURCE_NATIVE_RATE_HZ})
        return {"status": "ok", "reason": None, "windows": n, "rhythm": rhythm}


__all__ = [
    "SiamAFAdapter", "UPSTREAM_REPO", "PINNED_COMMIT", "ARTIFACT_NAME",
    "ARTIFACT_SIZE", "ARTIFACT_SHA256", "ARTIFACT_RELPATH", "LICENSE",
    "SEGMENT_SECONDS", "INPUT_SAMPLES", "RHYTHM_CLASSES", "PROVIDER_REVISION",
    "SOURCE_NATIVE_RATE_HZ",
]
