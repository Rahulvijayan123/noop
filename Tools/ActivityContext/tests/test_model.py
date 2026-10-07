"""HART model adapter tests — the real loaded checkpoint (spec s12 model gate).

Skipped when torch / granite-tsfm are missing or the checkpoint has not been
fetched (ACTIVITY_HART_CHECKPOINT, default ./checkpoint). The verify-on-load
is the spec's "intended pretrained tensors are verified" gate.

Two kinds of checkpoint directory are supported:

* the PRETRAINED upstream checkpoint (fetch_artifacts.sh): no manifest of its
  own; the fixture manifest pins its digest (88b8d179...) and the 8 linear-head
  tensors are newly initialized;
* a FINE-TUNED artifact directory (activity-train --train output, e.g.
  hart-wisdm-v0 / hart-wisdm-v1): it carries its own manifest.json pinning the
  fine-tuned digest and the 18-letter class map; nothing is newly initialized.

The tests read the directory's own manifest.json when there is one, so they
exercise whichever checkpoint they are pointed at instead of failing the
digest pin of the other kind.
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

HEAD_KEY = "decoder_with_head.head.projection.weight"


def _manifest_path(checkpoint):
    own = os.path.join(checkpoint, "manifest.json")
    return own if os.path.isfile(own) else os.path.join(FIXTURES, "manifest.hart.example.json")


def _manifest(checkpoint=CHECKPOINT):
    from activity_context.manifest import load_manifest
    return load_manifest(_manifest_path(checkpoint))


def _is_fine_tuned(checkpoint=CHECKPOINT):
    from safetensors import safe_open
    with safe_open(os.path.join(checkpoint, "model.safetensors"), framework="pt") as f:
        return HEAD_KEY in set(f.keys())


@pytest.fixture(scope="module")
def model():
    return HARTModel(_manifest(), CHECKPOINT)


def test_verify_on_load_matches_the_checkpoint_kind():
    from safetensors.torch import load_file
    from activity_context.model import _file_sha256, _load_model_and_verify
    man = _manifest()
    fine = _is_fine_tuned()
    # a fine-tuned directory must carry its own manifest; the fixture pins the pretrained digest
    assert fine == (_manifest_path(CHECKPOINT) != os.path.join(FIXTURES, "manifest.hart.example.json"))
    mdl, _torch = _load_model_and_verify(CHECKPOINT, len(man.class_map), man.seed, manifest=man)
    assert _file_sha256(os.path.join(CHECKPOINT, "model.safetensors")) == \
        man.checkpoint["files"]["model.safetensors"]["sha256"]
    new = set(mdl.state_dict()) - set(load_file(os.path.join(CHECKPOINT, "model.safetensors")))
    assert new == (set() if fine else EXPECTED_NEW_HEAD_TENSORS)


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
    assert np.array_equal(p1.logits, p2.logits)
    assert p1.logits.shape == (len(model.manifest.class_map),)
    # ontology probabilities aggregate a softmax: they sum to ~1
    assert abs(sum(p1.probs.values()) - 1.0) < 1e-6


def test_prediction_calibrated_comes_from_manifest_artifact(model):
    """A01: Prediction.calibrated must come from the manifest's calibration artifact, never
    from model_kind ('hart'). The fixture manifest has no artifact -> False; with a
    calibration section present, the same model reports True."""
    import copy
    from activity_context.manifest import load_manifest

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

    assert model.predict_window(wins[0].data).calibrated is False   # no artifact in fixture

    man = load_manifest(os.path.join(FIXTURES, "manifest.hart.example.json"))
    man2 = copy.deepcopy(man)
    man2.calibration = {"version": "ts-v1", "method": "temperature_scaling"}
    model2 = HARTModel(man2, CHECKPOINT)
    p = model2.predict_window(wins[0].data)
    assert p.calibrated is True
    assert p.label in ("unknown", "stationary", "walking", "running", "other_movement")


def _copy_checkpoint(dst):
    os.makedirs(dst)
    for name in ("model.safetensors", "config.json"):
        shutil.copy2(os.path.join(CHECKPOINT, name), os.path.join(dst, name))
    return dst


def test_corrupt_checkpoint_refused(tmp_path):
    man = _manifest()
    cp = _copy_checkpoint(str(tmp_path / "cp"))
    HARTModel(man, cp).close()                  # the untouched copy loads: the pin is right
    p = os.path.join(cp, "model.safetensors")
    with open(p, "rb") as f:
        raw = bytearray(f.read())
    raw[len(raw) // 2] ^= 0x01                  # tamper with one byte of the weights
    with open(p, "wb") as f:
        f.write(bytes(raw))
    with pytest.raises(ModelError, match="corrupt"):
        HARTModel(man, cp)


def test_wrong_pin_refused(tmp_path):
    """The other kind's manifest pins another digest: refused before any tensor is used."""
    from activity_context.manifest import load_manifest
    man = load_manifest(_manifest_path(CHECKPOINT))
    man.checkpoint = json.loads(json.dumps(man.checkpoint))
    man.checkpoint["files"]["model.safetensors"]["sha256"] = "0" * 64
    with pytest.raises(ModelError, match="sha256 mismatch"):
        HARTModel(man, CHECKPOINT)


def test_missing_checkpoint_refused():
    with pytest.raises(ModelError):
        HARTModel(_manifest(), "/nonexistent/checkpoint")
