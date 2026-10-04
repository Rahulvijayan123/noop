"""Manifest load/validate tests."""

import copy
import json
import os

import pytest

from activity_context.manifest import (ManifestError, load_manifest,
                                       scaler_sha256, validate_manifest)

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")


def _baseline():
    with open(os.path.join(FIXTURES, "manifest.baseline.json")) as f:
        return json.load(f)


def _hart():
    with open(os.path.join(FIXTURES, "manifest.hart.example.json")) as f:
        return json.load(f)


def test_baseline_manifest_loads():
    m = validate_manifest(_baseline())
    assert m.model_kind == "baseline"
    assert m.class_map == ["stationary", "walking", "running",
                           "other_movement", "unknown"]


def test_hart_manifest_loads_with_scaler():
    m = validate_manifest(_hart())
    assert m.model_kind == "hart"
    assert len(m.class_map) == 3
    sc = m.scaler
    assert sc["sha256"] == scaler_sha256(sc["mean"], sc["scale"])


def test_missing_required_key_rejected():
    d = _baseline()
    del d["model_version"]
    with pytest.raises(ManifestError, match="model_version"):
        validate_manifest(d)


def test_bad_schema_version_rejected():
    d = _baseline()
    d["schema_version"] = 99
    with pytest.raises(ManifestError, match="schema_version"):
        validate_manifest(d)


def test_bad_thresholds_rejected():
    d = _baseline()
    d["thresholds"] = {"max_prob": 0.5, "margin": 0.9}   # margin > max_prob
    with pytest.raises(ManifestError, match="max_prob"):
        validate_manifest(d)


def test_bad_units_rejected():
    d = _baseline()
    d["units"]["input_accel"] = "m/s^2"
    with pytest.raises(ManifestError, match="canonical"):
        validate_manifest(d)


def test_bad_window_rejected():
    d = _baseline()
    d["window"] = {"samples": 256, "hop": 128, "hz": 30}
    with pytest.raises(ManifestError, match="window"):
        validate_manifest(d)


def test_bad_class_map_rejected():
    d = _baseline()
    d["class_map"] = ["stationary", "stationary"]
    with pytest.raises(ManifestError, match="duplicate"):
        validate_manifest(d)


def test_hart_requires_checkpoint_and_scaler():
    d = _hart()
    del d["checkpoint"]["files"]
    with pytest.raises(ManifestError, match="checkpoint.files"):
        validate_manifest(d)
    d2 = _hart()
    d2["scaler"] = {}
    with pytest.raises(ManifestError, match="scaler"):
        validate_manifest(d2)


def test_scaler_sha256_deterministic():
    a = scaler_sha256([0.1, 0.2, 0.3, 0.4, 0.5, 0.6], [1.0] * 6)
    b = scaler_sha256([0.1, 0.2, 0.3, 0.4, 0.5, 0.6], [1.0] * 6)
    assert a == b
    c = scaler_sha256([0.2, 0.2, 0.3, 0.4, 0.5, 0.6], [1.0] * 6)
    assert a != c


def test_load_manifest_file(tmp_path):
    p = tmp_path / "manifest.json"
    p.write_text(json.dumps(_baseline()))
    m = load_manifest(str(p))
    assert m.model_kind == "baseline"
    with pytest.raises(ManifestError, match="not found"):
        load_manifest(str(tmp_path / "nope.json"))
    (tmp_path / "bad.json").write_text("{not json")
    with pytest.raises(ManifestError, match="JSON"):
        load_manifest(str(tmp_path / "bad.json"))
