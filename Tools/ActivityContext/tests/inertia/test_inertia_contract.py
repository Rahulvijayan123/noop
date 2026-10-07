"""Encoder identity / input-contract / pinned-string tests (numpy only)."""

import subprocess
import sys

import numpy as np
import pytest

import activity_context.inertia as inertia
from activity_context.inertia import registry
from activity_context.inertia.contract import (EncoderInputError, InertiaUnavailable, InputContract,
                                               canonical_json_bytes, make_info, sha256_bytes, validate_batch)

from ._helpers import env

SHA = "ab" * 32


def _info(encoder_id="inertia-1/ar_transformer-small/30s@20hz", kind="inertia1", sha=SHA):
    return make_info(encoder_id=encoder_id, kind=kind, config={"x": 1}, embedding_dim=8, window_s=30,
                     extraction_point="test", checkpoint_sha256=sha)


def test_pinned_strings():
    assert inertia.PREPROCESSING_VERSION == "inertia-prep-1"
    assert inertia.WIRE_SCHEMA == "motion-heads-1"
    assert inertia.ENCODER_CONFIG_SCHEMA == "nara.inertia.encoder/1"
    assert inertia.HEADS_SCHEMA == "nara.inertia.heads/1"
    assert inertia.CALIBRATION_SCHEMA == "nara.inertia.calibration/1"
    assert inertia.OOD_SCHEMA == "nara.inertia.ood/1"
    assert inertia.SPLIT_SCHEMA == "nara-split-1"
    assert inertia.MAPPINGS_SCHEMA == "nara.inertia.mappings/1"
    assert inertia.UPSTREAM_COMMIT == "afcd725314c95f4afefce118821349df7d61e7e8"


def test_class_orders_match_contract_table():
    assert inertia.HEAD_CLASS_ORDERS["posture"] == ("recumbent", "seated_likely", "upright_stationary",
                                                    "postural_transition")
    assert inertia.HEAD_CLASS_ORDERS["transition"] == ("sit_to_stand_like", "stand_to_sit_like", "lying_down_like",
                                                       "getting_up_like", "walk_start", "walk_stop", "run_start",
                                                       "run_stop")
    assert len(inertia.HEAD_CLASS_ORDERS["locomotion"]) == 8 and len(inertia.HEAD_CLASS_ORDERS["arm_behavior"]) == 7
    assert all("unknown" not in v and "none" not in v for v in inertia.HEAD_CLASS_ORDERS.values())
    assert inertia.MULTILABEL_HEADS == ("transition",)


def test_id_kind_invariants():
    assert _info().kind == "inertia1"
    with pytest.raises(ValueError):
        _info(kind="standin")                                     # inertia-1/ id must be the inertia1 kind
    with pytest.raises(ValueError):
        _info(encoder_id="standin:x", kind="inertia1")
    with pytest.raises(ValueError):
        _info(encoder_id="my-encoder", kind="standin")            # stand-ins must start with standin:
    with pytest.raises(ValueError):
        _info(sha="not-a-sha")


def test_config_sha_is_canonical_and_checked():
    info = _info()
    assert info.config_sha256 == sha256_bytes(canonical_json_bytes({"x": 1}))
    import dataclasses
    with pytest.raises(ValueError):
        dataclasses.replace(info, config={"x": 2})


def test_production_eligibility_requires_pinned_checkpoint(monkeypatch):
    assert registry.PINNED_CHECKPOINTS == {}
    info = _info()
    assert not info.production_eligible and info.wire_kind == "standin"
    monkeypatch.setitem(registry.PINNED_CHECKPOINTS, SHA, {"encoder_id": "inertia-1/patchtst-small/30s@20hz"})
    assert not info.production_eligible                            # pinned for a different id
    monkeypatch.setitem(registry.PINNED_CHECKPOINTS, SHA, {"encoder_id": info.encoder_id})
    assert info.production_eligible and info.wire_kind == "inertia1"
    standin = _info(encoder_id="standin:x", kind="standin")
    assert not standin.production_eligible and standin.wire_kind == "standin"


def test_unavailable_kinds_closed():
    for kind in ("model_missing", "checkpoint_mismatch", "config_mismatch", "internal"):
        assert InertiaUnavailable(kind, "m").kind == kind
    with pytest.raises(ValueError):
        InertiaUnavailable("oops", "m")


def test_validate_batch():
    c = InputContract(window_s=10)
    ok = np.zeros((2, 3, 200), dtype=np.float32)
    assert validate_batch(ok, c) is ok
    for bad in (ok.astype(np.float64), np.zeros((2, 3, 600), np.float32), np.zeros((2, 6, 200), np.float32),
                [[0.0]], np.zeros((3, 200), np.float32)):
        with pytest.raises(EncoderInputError):
            validate_batch(bad, c)
    nan = ok.copy()
    nan[1, 2, 5] = np.nan
    with pytest.raises(EncoderInputError):
        validate_batch(nan, c)
    assert c.config_dict() == {"axes": ["ax", "ay", "az"], "units": "g", "gravity": "kept", "rate_hz": 20,
                               "normalization": "none"}


def test_package_init_is_import_free():
    code = ("import sys, activity_context.inertia; "
            "bad = [m for m in ('torch', 'scipy', 'numpy') if m in sys.modules]; print(bad); assert not bad")
    r = subprocess.run([sys.executable, "-c", code], env=env(), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
