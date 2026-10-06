"""Golden WHOOP-format fixture (fixtures/eldernet): the request decodes to exactly the response's windows, the
static pre-filter flags reproduce without weights, and with the real weights the runtime reproduces the response."""

import json
import os

import numpy as np
import pytest

from activity_context.eldernet import QUALITY_HEADS, WIRE_SCHEMA
from activity_context.eldernet.gait import prefilter_mask
from activity_context.eldernet.make_golden import REQUEST_NAME, RESPONSE_NAME, _close
from activity_context.eldernet.preprocess import stack_windows, windows_from_seconds
from activity_context.eldernet.runtime import decode_request_seconds, parse_infer_request
from activity_context.eldernet.weights import wire_hashes

from ._helpers import FIXTURES, upstream_dir_or_skip, weights_dir_or_skip

METRIC_KEYS = {v[0] for v in QUALITY_HEADS.values()}
RANGES = {v[0]: v[1] for v in QUALITY_HEADS.values()}


def _load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture(scope="module")
def golden():
    return _load(REQUEST_NAME), _load(RESPONSE_NAME)


def test_response_follows_the_wire_contract(golden):
    _, resp = golden
    assert resp["ok"] and resp["schema"] == WIRE_SCHEMA and resp["duration_ms"] == 0
    assert resp["weights"] == wire_hashes() and resp["calibration"] is None and resp["gait_threshold"] == 0.5
    kinds = set()
    for w in resp["windows"]:
        assert w["e"] - w["s"] == 10 and 0.0 <= w["gait_prob"] <= 1.0
        assert w["is_gait"] == (w["gait_prob"] >= 0.5 and not w.get("prefiltered", False))
        if w["is_gait"]:
            assert METRIC_KEYS <= set(w)
            assert all(0.0 <= w[k] <= RANGES[k] for k in METRIC_KEYS)
        else:
            assert not METRIC_KEYS & set(w)
        if w.get("prefiltered"):
            assert w["gait_prob"] == 0.0 and w["is_gait"] is False
        kinds.add("prefiltered" if w.get("prefiltered") else ("gait" if w["is_gait"] else "not_gait"))
    assert kinds == {"prefiltered", "gait", "not_gait"}


def test_request_decodes_to_the_response_windows_and_prefilter_flags(golden):
    req, resp = golden
    start, end, body, head, tail, hop = parse_infer_request(req, 5)
    windows = windows_from_seconds(decode_request_seconds(start, end, body, head, tail), start, end, hop)
    assert [w.s for w in windows] == [w["s"] for w in resp["windows"]]
    pre = prefilter_mask(stack_windows(windows))
    assert pre.tolist() == [bool(w.get("prefiltered", False)) for w in resp["windows"]]


def test_runtime_reproduces_the_golden_response(golden):
    pytest.importorskip("torch")
    from activity_context.eldernet.runtime import build_runtime, handle_request
    req, resp = golden
    rt = build_runtime(weights_dir_or_skip())
    assert rt.available, rt.error
    got = handle_request(rt, req)
    got["duration_ms"] = 0
    assert _close(got, resp, 1e-6)


def test_make_golden_check_passes():
    pytest.importorskip("torch")
    up, wd = upstream_dir_or_skip(), weights_dir_or_skip()
    from activity_context.eldernet.make_golden import main
    assert main(["--check", "--upstream-dir", up, "--weights-dir", wd, "--out", FIXTURES]) == 0


def test_request_is_whoop_format(golden):
    req, _ = golden
    from activity_context.preprocess import decode_columns_b64
    cols = [decode_columns_b64(b) for b in req["run"]["columns_b64"]]
    assert all(c.dtype == np.int16 and c.shape == (600,) for c in cols)
    assert all(not c[300:].any() for c in cols)                         # gyro zero
    mag = np.linalg.norm(np.stack([c[:300].reshape(3, 100) for c in cols]).transpose(0, 2, 1).reshape(-1, 3)
                         / 4096.0, axis=1)
    assert 0.9 < np.median(mag) < 1.1                                   # in g, gravity kept
