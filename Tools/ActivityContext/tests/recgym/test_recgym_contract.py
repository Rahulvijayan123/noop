"""The pinned contract: class order, vendored upstream files byte for byte, the architecture's state-dict shape,
the weights pins (no network, no checkpoint needed)."""

import hashlib
import os
import zipfile

import pytest

from activity_context.recgym import (CLASSES, HOP_S, MODEL_ID, MODEL_VERSION, NULL_INDEX, RATE_HZ, UPSTREAM_COMMIT,
                                     WINDOW_S, WINDOW_SAMPLES)

from ._helpers import PKG, golden

VENDOR = os.path.join(PKG, "activity_context", "recgym", "vendor")
DASHES = "# " + "-" * 112 + "\n"


def _upstream_body(name):
    with open(os.path.join(VENDOR, name), "rb") as f:
        text = f.read().decode("utf-8")
    head, sep, body = text.partition(DASHES)
    assert sep, f"{name} lost its header separator"
    return head, body.encode("utf-8")


@pytest.mark.parametrize("name, upstream_path, sha", [
    ("imu_transformer.py", "src/models/imu_transformer.py",
     "edd1801e5b7ace210859e75e039d1b106ff59f7bbe5740205f7024829e00278c"),
    ("recgym_data.py", "src/data/recgym.py", "a8c47737994f6bda6437376c93e8cf4f4743525f1a4acf34a567d8fe76f52ed7"),
])
def test_vendored_files_are_upstream_byte_for_byte_with_the_mit_notice(name, upstream_path, sha):
    head, body = _upstream_body(name)
    assert hashlib.sha256(body).hexdigest() == sha
    assert f"Upstream path: {upstream_path}" in head and UPSTREAM_COMMIT in head
    assert "MIT License" in head and "Copyright (c) 2025 MKorp7" in head


def test_class_order_is_upstreams_sorted_label_encoding():
    assert list(CLASSES) == sorted(CLASSES)
    assert CLASSES[NULL_INDEX] == "Null" and NULL_INDEX == 5
    assert golden()["classes"] == list(CLASSES)


def test_window_contract():
    assert (RATE_HZ, WINDOW_S, HOP_S, WINDOW_SAMPLES) == (20, 4, 2, 80)
    assert MODEL_ID == "recgym-cnn-transformer" and MODEL_VERSION == "recgym-cnn-transformer-e085ac0"


def test_the_vendored_architecture_has_the_checkpoints_keys_and_shapes():
    torch = pytest.importorskip("torch")
    from activity_context.recgym.model import build_model
    sd = build_model().state_dict()
    assert len(sd) == 47
    shapes = {k: tuple(v.shape) for k, v in sd.items()}
    assert shapes["conv.0.weight"] == (64, 6, 5)
    assert shapes["head.3.weight"] == (12, 64)
    assert shapes["pos_enc.pe"] == (1, 500, 64)
    assert shapes["transformer.layers.1.self_attn.in_proj_weight"] == (192, 64)
    assert sum(v.numel() for k, v in sd.items() if v.dtype == torch.float32) == 189_132   # incl. the 500x64 pe buffer


def test_weights_pins_and_verification(tmp_path, monkeypatch):
    from activity_context.recgym import weights as W
    monkeypatch.delenv(W.WEIGHTS_PATH_ENV, raising=False)
    assert W.CHECKPOINT.path == "models/wrist_-_imu_only_best.pt"
    assert W.ARCHIVE_URL.endswith(f"/{UPSTREAM_COMMIT}/models.zip")
    assert W.MODEL_ROOT_RELPATH == "recgym/e085ac0e/wrist_-_imu_only_best.pt"
    with pytest.raises(W.WeightsError) as e:
        W.resolve_measured(str(tmp_path / "missing.pt"))
    assert e.value.kind == "model_missing"
    bad = tmp_path / W.CHECKPOINT.name
    bad.write_bytes(b"x" * W.CHECKPOINT.size)
    with pytest.raises(W.WeightsError) as e:
        W.resolve_measured(str(tmp_path))
    assert e.value.kind == "weights_mismatch"
    bad.write_bytes(b"short")
    with pytest.raises(W.WeightsError) as e:
        W.verify_file(str(bad))
    assert e.value.kind == "weights_mismatch"
    with pytest.raises(W.WeightsError) as e:
        W.resolve_measured("")
    assert e.value.kind == "model_missing"


def test_extract_member_refuses_an_archive_that_is_not_the_pinned_one(tmp_path):
    from activity_context.recgym import weights as W
    z = tmp_path / "models.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr(W.CHECKPOINT.path, b"not the checkpoint")
    with pytest.raises(W.WeightsError) as e:
        W.extract_member(str(z), str(tmp_path / "out.pt"))
    assert e.value.kind == "weights_mismatch"
    assert not (tmp_path / "out.pt").exists()
