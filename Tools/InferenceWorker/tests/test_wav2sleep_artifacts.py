"""wav2sleep artifact identity and refusal: size + sha256 before load, strict key/shape match.

Uses temporary artifact roots. The real checkpoint is never needed here: refusals are proven
against the real pins (wrong/missing bytes) and against self-consistent custom pins built from a
seeded stand-in state dict (key and shape mismatches the size/sha check cannot see).
"""

import hashlib
import os

import pytest
import yaml

import wav2sleep_helpers as H
from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep.artifacts import (build_model, load_model,
                                                                 parse_config, verify_artifacts)
from frwhoop_inference.frwhoop_sleep.wav2sleep.contract import Withhold
from frwhoop_inference.frwhoop_sleep.wav2sleep.provider import Wav2SleepPpgProvider


def _write(root, rel, data: bytes):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)
    return path


def _pins_for(root, names=("state_dict.pth", "config.yaml")):
    pins = {}
    for name in names:
        rel = C.ARTIFACTS[name]["relpath"]
        data = open(os.path.join(root, rel), "rb").read()
        pins[name] = {"relpath": rel, "size_bytes": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()}
    return pins


def _stage_custom(root, state_dict, config=None):
    import io

    import torch

    buffer = io.BytesIO()
    torch.save(state_dict, buffer)
    _write(root, C.ARTIFACTS["state_dict.pth"]["relpath"], buffer.getvalue())
    _write(root, C.ARTIFACTS["config.yaml"]["relpath"],
           yaml.safe_dump(config or H.RELEASED_CONFIG).encode())
    return _pins_for(root)


def test_pins_are_the_manifest_values():
    assert C.ARTIFACTS["state_dict.pth"]["sha256"] == \
        "ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc"
    assert C.ARTIFACTS["state_dict.pth"]["size_bytes"] == 9_666_562
    assert C.ARTIFACTS["config.yaml"]["sha256"] == \
        "b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509"
    assert C.ARTIFACTS["config.yaml"]["size_bytes"] == 749
    for spec in C.ARTIFACTS.values():
        assert f"/resolve/{C.WEIGHTS_REVISION}/" in spec["url"], "URL must pin the HF revision"
    assert C.CODE_COMMIT != C.WEIGHTS_REVISION


def test_missing_artifact_is_refused(tmp_path):
    with pytest.raises(Withhold) as info:
        verify_artifacts(str(tmp_path))
    assert info.value.detail == "artifact_missing" and info.value.reason == "blocked_artifact"


def test_wrong_size_is_refused_before_any_hashing_or_parsing(tmp_path):
    _write(str(tmp_path), C.ARTIFACTS["state_dict.pth"]["relpath"], b"not a checkpoint")
    _write(str(tmp_path), C.ARTIFACTS["config.yaml"]["relpath"], b"x" * 749)
    with pytest.raises(Withhold) as info:
        verify_artifacts(str(tmp_path))
    assert info.value.detail == "artifact_size_mismatch"


def test_right_size_wrong_sha256_is_refused(tmp_path):
    _write(str(tmp_path), C.ARTIFACTS["state_dict.pth"]["relpath"], b"\0" * 9_666_562)
    with pytest.raises(Withhold) as info:
        verify_artifacts(str(tmp_path))
    assert info.value.detail == "artifact_sha256_mismatch" and info.value.reason == "blocked_artifact"


def test_custom_pins_load_a_consistent_stand_in(tmp_path):
    pins = _stage_custom(str(tmp_path), H.stand_in_model().model.state_dict())
    loaded = load_model(str(tmp_path), pins)
    assert loaded.inventory["tensors"] == C.STATE_DICT_KEYS
    assert loaded.inventory["parameters"] == C.STATE_DICT_PARAMETERS
    assert loaded.model.training is False
    assert not any(p.requires_grad for p in loaded.model.parameters())


def test_missing_key_is_refused(tmp_path):
    state = H.stand_in_model().model.state_dict()
    state.pop("classifier.weight")
    with pytest.raises(Withhold) as info:
        load_model(str(tmp_path), _stage_custom(str(tmp_path), state))
    assert info.value.detail == "state_dict_mismatch"
    assert "classifier.weight" in info.value.extra["missing"]


def test_unexpected_key_is_refused(tmp_path):
    import torch

    state = H.stand_in_model().model.state_dict()
    state["head.extra"] = torch.zeros(3)
    with pytest.raises(Withhold) as info:
        load_model(str(tmp_path), _stage_custom(str(tmp_path), state))
    assert info.value.extra["unexpected"] == ["head.extra"]


def test_shape_mismatch_is_refused(tmp_path):
    import torch

    state = H.stand_in_model().model.state_dict()
    state["classifier.weight"] = torch.zeros(5, 128)
    with pytest.raises(Withhold) as info:
        load_model(str(tmp_path), _stage_custom(str(tmp_path), state))
    assert info.value.detail == "state_dict_mismatch"
    assert "classifier.weight" in info.value.extra["shape_mismatch"]


def test_a_pickled_object_is_never_executed(tmp_path):
    """weights_only=True refuses arbitrary pickles even when the pins match the bytes."""
    import pickle

    marker = tmp_path / "pwned"

    class Boom:
        def __reduce__(self):
            return (os.system, (f"touch '{marker}'",))

    _write(str(tmp_path), C.ARTIFACTS["state_dict.pth"]["relpath"], pickle.dumps({"x": Boom()}))
    _write(str(tmp_path), C.ARTIFACTS["config.yaml"]["relpath"],
           yaml.safe_dump(H.RELEASED_CONFIG).encode())
    with pytest.raises(Exception):
        load_model(str(tmp_path), _pins_for(str(tmp_path)))
    assert not marker.exists(), "the pickle payload ran"


@pytest.mark.parametrize("mutate, needle", [
    (lambda c: c.update({"_target_": "os.system"}), "root _target_"),
    (lambda c: c["epoch_mixer"].update({"_target_": "builtins.eval"}), "not allowlisted"),
    (lambda c: c.update({"_partial_": True}), "hydra directive"),
    (lambda c: c.update({"num_classes": 5}), "num_classes"),
    (lambda c: c["signal_encoders"].update({"causal": True}), "non-causal"),
])
def test_config_outside_the_released_contract_is_refused(tmp_path, mutate, needle):
    import copy

    config = copy.deepcopy(H.RELEASED_CONFIG)
    mutate(config)
    path = _write(str(tmp_path), "config.yaml", yaml.safe_dump(config).encode())
    with pytest.raises(Withhold) as info:
        build_model(parse_config(path))
    assert info.value.detail == "config_mismatch" and needle in info.value.message


def test_yaml_tags_are_not_constructed(tmp_path):
    path = _write(str(tmp_path), "config.yaml", b"!!python/object/apply:os.system ['echo pwned']\n")
    with pytest.raises(yaml.YAMLError):
        parse_config(path)


def test_readiness_disabled_is_ready_and_enabled_without_artifacts_is_not(tmp_path):
    disabled = Wav2SleepPpgProvider(model_root=str(tmp_path), enabled=False)
    report = disabled.readiness()
    assert report["ready"] is True and report["enabled"] is False
    enabled = Wav2SleepPpgProvider(model_root=str(tmp_path), enabled=True)
    report = enabled.readiness()
    assert report["ready"] is False
    assert report["reason"].startswith("blocked_artifact: artifact_missing")


def test_enabled_lane_with_wrong_bytes_withholds_blocked_artifact(tmp_path):
    import wav2sleep_fixtures as F

    _write(str(tmp_path), C.ARTIFACTS["state_dict.pth"]["relpath"], b"\0" * 9_666_562)
    _write(str(tmp_path), C.ARTIFACTS["config.yaml"]["relpath"], b"\0" * 749)
    fixture = F.night([(0, 5 * 3600)])
    response = Wav2SleepPpgProvider(model_root=str(tmp_path), enabled=True).infer(
        input=F.payload(fixture), context=F.context(fixture))
    assert response["status"] == "withheld"
    assert response["withheld_reason"] == "blocked_artifact"
    assert response["diagnostics"]["reason_detail"] == "artifact_sha256_mismatch"
    assert response["raw_scores"] is None and response["result"] is None
