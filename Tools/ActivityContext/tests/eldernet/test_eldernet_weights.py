"""Pinned weights: manifest, resolution, refusal of missing / wrong-sha / wrong-size files and wrong state dicts."""

import hashlib
import os

import pytest

from activity_context.eldernet import HEAD_NAMES, UPSTREAM_COMMIT
from activity_context.eldernet.weights import MANIFEST, WeightFile, WeightsError, resolve, verify_file, wire_hashes

from ._helpers import weights_dir_or_skip


def _fake_manifest(tmp_path, names=HEAD_NAMES):
    man = {}
    for i, n in enumerate(names):
        data = f"weights-{n}-{i}".encode()
        (tmp_path / f"{n}_weights.pt").write_bytes(data)
        man[n] = WeightFile(n, f"weights/{n}_weights.pt", hashlib.sha256(data).hexdigest(), len(data))
    return man


def test_manifest_is_complete_and_pinned():
    assert tuple(MANIFEST) == HEAD_NAMES
    for wf in MANIFEST.values():
        assert len(wf.sha256) == 64 and wf.size > 40_000_000
        assert wf.url.startswith(f"https://raw.githubusercontent.com/yonbrand/gait-quality/{UPSTREAM_COMMIT}/weights/")
    assert wire_hashes() == {n: MANIFEST[n].sha256 for n in HEAD_NAMES}


def test_resolve_requires_a_directory(monkeypatch):
    monkeypatch.delenv("ELDERNET_WEIGHTS_DIR", raising=False)
    with pytest.raises(WeightsError) as e:
        resolve(None)
    assert e.value.kind == "model_missing"
    with pytest.raises(WeightsError) as e:
        resolve("/nonexistent/eldernet-weights")
    assert e.value.kind == "model_missing"


def test_resolve_flat_and_nested_layouts(tmp_path):
    man = _fake_manifest(tmp_path)
    paths = resolve(str(tmp_path), manifest=man)
    assert set(paths) == set(HEAD_NAMES)
    nested = tmp_path / "nested"
    (nested / "weights").mkdir(parents=True)
    for n in HEAD_NAMES:
        os.replace(paths[n], nested / "weights" / f"{n}_weights.pt")
    assert set(resolve(str(nested), manifest=man)) == set(HEAD_NAMES)


def test_missing_file_wrong_sha_wrong_size(tmp_path):
    man = _fake_manifest(tmp_path)
    os.remove(tmp_path / "cadence_weights.pt")
    with pytest.raises(WeightsError) as e:
        resolve(str(tmp_path), manifest=man)
    assert e.value.kind == "model_missing" and "cadence" in e.value.message
    (tmp_path / "cadence_weights.pt").write_bytes(b"weights-cadence-X")          # same size, other bytes
    with pytest.raises(WeightsError) as e:
        resolve(str(tmp_path), manifest=man)
    assert e.value.kind == "weights_mismatch" and "sha256" in e.value.message
    (tmp_path / "cadence_weights.pt").write_bytes(b"short")
    with pytest.raises(WeightsError) as e:
        verify_file(str(tmp_path / "cadence_weights.pt"), man["cadence"])
    assert e.value.kind == "weights_mismatch" and "bytes" in e.value.message


@pytest.fixture(scope="module")
def cadence_state(tmp_path_factory):
    torch = pytest.importorskip("torch")
    from activity_context.eldernet.model import build_head
    torch.manual_seed(0)
    sd = build_head("cadence").state_dict()
    return {k: v.clone() for k, v in sd.items()}


def test_strict_load_accepts_exact_and_known_unused_keys(cadence_state):
    torch = pytest.importorskip("torch")
    from activity_context.eldernet.model import build_head, load_strict
    sd = dict(cadence_state, **{"regressor.var.weight": torch.zeros(1, 64), "regressor.var.bias": torch.zeros(1)})
    m = load_strict(build_head("cadence"), sd, "cadence")
    assert not m.training
    assert torch.equal(m.state_dict()["fc.linear1.weight"], cadence_state["fc.linear1.weight"])


@pytest.mark.parametrize("damage", ["missing", "extra", "shape", "other_head"])
def test_strict_load_refuses_a_wrong_state_dict(cadence_state, damage):
    torch = pytest.importorskip("torch")
    from activity_context.eldernet.model import build_head, load_strict
    sd = dict(cadence_state)
    if damage == "missing":
        sd.pop("regressor.bn_layers.0.running_mean")
    elif damage == "extra":
        sd["classifier.linear1.weight"] = torch.zeros(2, 128)
    elif damage == "shape":
        sd["fc.linear3.weight"] = torch.zeros(50, 256)          # the old 50-d gait-detection checkpoint
    target = "gait_speed" if damage == "other_head" else "cadence"   # speed has no hidden regressor layer
    with pytest.raises(WeightsError) as e:
        load_strict(build_head(target), sd, target)
    assert e.value.kind == "weights_mismatch"


def test_non_state_dict_file_is_a_mismatch(tmp_path):
    torch = pytest.importorskip("torch")
    from activity_context.eldernet.model import read_state_dict
    p = tmp_path / "x.pt"
    p.write_bytes(b"not a checkpoint")
    with pytest.raises(WeightsError) as e:
        read_state_dict(str(p), "gait_speed")
    assert e.value.kind == "weights_mismatch"
    torch.save([torch.zeros(1)], str(p))
    with pytest.raises(WeightsError) as e:
        read_state_dict(str(p), "gait_speed")
    assert e.value.kind == "weights_mismatch"


def test_real_weights_verify_and_load_strictly():
    pytest.importorskip("torch")
    from activity_context.eldernet.model import load_heads
    paths = resolve(weights_dir_or_skip())
    heads = load_heads(paths)
    assert set(heads.models) == set(HEAD_NAMES)
