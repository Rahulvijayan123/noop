"""Golden end-to-end fixture: WHOOP NPB1 -> inertia-prep-1 -> tiny random-init ART stand-in -> heads ->
calibrated probs + OOD -> the exact motion-heads-1 response the Swift decoder test reads."""

import json
import os

import pytest

pytest.importorskip("torch")
pytest.importorskip("scipy")

from activity_context.inertia.make_golden import ENCODER_ID, check, compare_json  # noqa: E402
from activity_context.inertia.runtime import build_runtime, handle_request  # noqa: E402

from ._helpers import INERTIA_FIXTURES, Serve  # noqa: E402

REQ = os.path.join(INERTIA_FIXTURES, "golden_motion_heads_request.json")
RESP = os.path.join(INERTIA_FIXTURES, "golden_motion_heads_response.json")
BUNDLE = os.path.join(INERTIA_FIXTURES, "bundle_tiny")
CKPT = os.path.join(INERTIA_FIXTURES, "encoder_tiny.ckpt")


def _load(p):
    with open(p) as f:
        return json.load(f)


def _strip(resp):
    return {k: v for k, v in resp.items() if k != "duration_ms"}


def test_golden_response_shape_is_stable_for_swift():
    g = _load(RESP)
    assert g["ok"] is True and g["schema"] == "motion-heads-1" and g["op"] == "infer"
    assert g["encoder_id"] == ENCODER_ID and g["encoder_kind"] == "standin" and g["evidence_tier_max"] == "shadow"
    assert g["window_s"] == 30 and g["hop_s"] == 5 and g["n_dropped_nonfinite"] == 0 and g["duration_ms"] == 0
    assert len(g["windows"]) == 15 and set(g["bundle"]["heads"]) == {"posture", "locomotion", "arm_behavior",
                                                                      "transition"}
    assert g["bundle"]["heads"]["locomotion"]["covers"] == {"walking": ["walking", "brisk_walking"]}
    assert "none" not in g["bundle"]["heads"]["transition"]["class_order"]


def test_committed_artifacts_reproduce_the_golden_response_in_process():
    rt = build_runtime(BUNDLE, checkpoint=CKPT, allow_standin_shadow=True)
    assert rt.error is None, rt.error
    assert compare_json(_strip(_load(RESP)), _strip(handle_request(rt, _load(REQ)))) == []


def test_serve_subprocess_reproduces_the_golden_response():
    s = Serve("--bundle", BUNDLE, "--checkpoint", CKPT, "--allow-standin-shadow")
    try:
        assert compare_json(_strip(_load(RESP)), _strip(s.send(_load(REQ)))) == []
    finally:
        s.close()


def test_golden_requires_the_standin_flag():
    rt = build_runtime(BUNDLE, checkpoint=CKPT)
    assert rt.error is not None and rt.error.kind == "model_missing"


def test_regeneration_matches_committed_fixtures():
    assert check() == []
