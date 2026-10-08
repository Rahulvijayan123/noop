"""Shared helpers for the wav2sleep adapter tests.

``stand_in_model`` builds the vendored architecture from the released config with SEEDED RANDOM
weights. It exists only so the structural tests (schema, masks, gaps, determinism, bounds) run
without the 9.7 MB checkpoint, which is never committed. Its outputs mean nothing; every claim
about the real model is made by test_wav2sleep_real_weights.py against the pinned artifact.
"""

from __future__ import annotations

import os
import time
from typing import Any, Optional

import pytest

#: The released config.yaml (Hugging Face 18fc32f0, sha256 b92f4e26...), as parsed by
#: yaml.safe_load. test_wav2sleep_real_weights.py asserts equality with the real file.
RELEASED_CONFIG: dict[str, Any] = {
    "_target_": "wav2sleep.models.wav2sleep.Wav2Sleep",
    "epoch_mixer": {"_target_": "wav2sleep.models.wav2sleep.MultiModalAttentionEmbedder",
                    "activation": "gelu", "dim_ff": 512, "dropout": 0.1, "feature_dim": 128,
                    "layers": 2, "nhead": 8},
    "num_classes": 4,
    "sequence_mixer": {"_target_": "wav2sleep.models.wav2sleep.SequenceCNN", "activation": "gelu",
                       "causal": False, "dropout": 0.1, "feature_dim": 128, "kernel_size": 5,
                       "norm": "layer", "num_dilations": 5, "num_layers": 2},
    "signal_encoders": {"_target_": "wav2sleep.models.wav2sleep.SignalEncoders",
                        "activation": "gelu", "causal": False, "chunk_causal": False,
                        "feature_dim": 128, "initial_channels": 16, "max_channels": 128,
                        "norm": "instance", "output_norm": False,
                        "signal_map": {"ABD": "ABD", "ECG": "ECG", "PPG": "PPG", "THX": "THX"},
                        "use_residual": True},
}

REAL_ROOT_ENV = "FRWHOOP_WAV2SLEEP_MODEL_ROOT"
REFERENCE_ENV = "FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE"


def real_model_root() -> Optional[str]:
    root = os.environ.get(REAL_ROOT_ENV)
    return root if root and os.path.isdir(root) else None


def requires_real_weights():
    return pytest.mark.skipif(real_model_root() is None,
                              reason=f"set {REAL_ROOT_ENV} to a model root holding the pinned "
                                     "wav2sleep/278e3046/{state_dict.pth,config.yaml}")


def stand_in_model(seed: int = 0):
    """Vendored architecture, released config, seeded random weights (structural tests only)."""
    import torch

    from frwhoop_inference.frwhoop_sleep.wav2sleep.artifacts import (LoadedModel,
                                                                     VerifiedArtifact,
                                                                     build_model)

    torch.manual_seed(seed)
    model = build_model(RELEASED_CONFIG)
    model.eval()
    model.requires_grad_(False)
    fake = {name: VerifiedArtifact(name=name, path=f"<stand-in:{name}>", size_bytes=0,
                                   sha256=f"stand-in-seed-{seed}-{name}")
            for name in ("state_dict.pth", "config.yaml")}
    return LoadedModel(model=model, artifacts=fake,
                       inventory={"stand_in": True, "seed": seed}, load_seconds=0.0,
                       loaded_at_unix=time.time(), config=RELEASED_CONFIG)


class ForwardSpy:
    """Wraps a model and records the keys/shapes of every input dict it receives."""

    def __init__(self, model):
        self.model = model
        self.calls: list[dict[str, tuple]] = []

    def __call__(self, x):
        self.calls.append({k: tuple(v.shape) for k, v in x.items()})
        return self.model(x)

    def __getattr__(self, name):
        return getattr(self.model, name)
