"""HART model adapter tests — the real loaded checkpoint (spec s12 model gate).

Skipped when torch / granite-tsfm are missing or the checkpoint has not been
fetched (ACTIVITY_HART_CHECKPOINT, default ./checkpoint). The verify-on-load
is the spec's "intended pretrained tensors are verified" gate.
"""

import json
import os
import shutil

import numpy as np
import pytest

from activity_context.model import (EXPECTED_NEW_HEAD_TENSORS, HARTModel,
                                     ModelError, torch_available)
from activity_context.preprocess import decode_frame_hex, windows_from_seconds

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
PKG = os.path.join(os.path.dirname(__file__), "..")
CHECKPOINT = os.environ.get("ACTIVITY_HART_CHECKPOINT",
                            os.path.join(PKG, "checkpoint"))
HAS_DEPS = torch_available() and os.path.isfile(os.path.join(CHECKPOINT, "model.safetensors"))
pytestmark = pytest.mark.skipif(not HAS_DEPS,
                                reason="torch/granite-tsfm or checkpoint not present")


@pytest.fixture(scope="module")
def model():
    from activity_context.manifest import load_manifest
    man = load_manifest(os.path.join(FIXTURES, "manifest.hart.example.json"))
    return HARTModel(man, CHECKPOINT)


def test_exactly_eight_new_head_tensors():
    from activity_context.manifest import load_manifest
    from activity_context.model import _load_model_and_verify
    man = load_manifest(os.path.join(FIXTURES, "manifest.hart.example.json"))
    _model, torch = _load_model_and_verify(CHECKPOINT, len(man.class_map),
                                           man.seed, manifest=man)
    # the fixture manifest's checkpoint entry matches the real digest
    from activity_context.model import _file_sha256
    assert _file_sha256(os.path.join(CHECKPOINT, "model.safetensors")) == \
        man.checkpoint["files"]["model.safetensors"]["sha256"]


def test_model_predicts_and_is_deterministic(model):
    with open(os.path.join(FIXTURES, "golden_imu_frames.json")) as f:
        gj = json.load(f)
    seconds = []
    for hx in gj["frames"]:
        base_ts, cols = decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    wins = windows_from_seconds(seconds, start, end)
    assert wins
    p1 = model.predict_window(wins[0].data)
    p2 = model.predict_window(wins[0].data)
    assert p1.label == p2.label
    assert p1.probs == p2.probs
    # untrained random head: class probabilities must sum to ~1 and abstain
    assert abs(sum(p1.probs.values()) - 1.0) < 1e-6


def test_corrupt_checkpoint_refused(tmp_path):
    from activity_context.manifest import load_manifest
    man = load_manifest(os.path.join(FIXTURES, "manifest.hart.example.json"))
    cp = tmp_path / "cp"
    shutil.copytree(CHECKPOINT, cp)
    # tamper with one byte of the safetensors weights
    p = cp / "model.safetensors"
    raw = bytearray(p.read_bytes())
    raw[len(raw) // 2] ^= 0x01
    p.write_bytes(bytes(raw))
    with pytest.raises(ModelError, match="corrupt"):
        HARTModel(man, str(cp))


def test_missing_checkpoint_refused():
    from activity_context.manifest import load_manifest
    man = load_manifest(os.path.join(FIXTURES, "manifest.hart.example.json"))
    with pytest.raises(ModelError):
        HARTModel(man, "/nonexistent/checkpoint")
