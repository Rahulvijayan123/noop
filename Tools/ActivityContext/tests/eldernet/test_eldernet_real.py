"""Real-weight checks (skip without $ELDERNET_WEIGHTS_DIR): upstream toy-example parity, determinism, batch and
chunking independence through the serve runtime."""

import csv
import gzip
import os

import numpy as np
import pytest

pytest.importorskip("torch")

from ._helpers import FIXTURES, T0, upstream_dir_or_skip, upstream_source_or_skip, weights_dir_or_skip  # noqa: E402

RTOL = ATOL = 1e-4                       # upstream tests/test_example_reproduction.py


@pytest.fixture(scope="module")
def heads():
    from activity_context.eldernet.model import load_heads
    from activity_context.eldernet.weights import resolve
    wd = weights_dir_or_skip()
    upstream_source_or_skip()
    return load_heads(resolve(wd))


def _csv(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def test_toy_example_matches_upstream_expected_outputs(heads):
    up = upstream_dir_or_skip()
    from activity_context.eldernet.run import analyse
    rows = _csv(os.path.join(up, "examples", "toy_wrist.csv.gz"))
    acc = np.array([[float(r["x"]), float(r["y"]), float(r["z"])] for r in rows])
    res = analyse(acc, 100.0, heads, start_time="2020-01-01 00:00:00")
    exp_w = _csv(os.path.join(up, "examples", "expected", "toy_wrist_windows.csv"))
    exp_b = _csv(os.path.join(up, "examples", "expected", "toy_wrist_bouts.csv"))
    assert len(res["windows"]) == len(exp_w) == 416 and len(res["bouts"]) == len(exp_b) == 6
    for got, want in zip(res["windows"], exp_w):
        assert (got["timestamp"], got["bout_id"], got["start_sample"]) == \
            (want["timestamp"], int(want["bout_id"]), int(want["start_sample"]))
        for col in ("gait_speed_m_s", "cadence_steps_min", "stride_length_m", "regularity_eldernet", "step_count",
                    "stride_length_indirect_m"):
            assert np.isclose(got[col], float(want[col]), rtol=RTOL, atol=ATOL), col
    for got, want in zip(res["bouts"], exp_b):
        assert (got["n_windows"], got["duration_sec"], got["start_time"]) == \
            (int(want["n_windows"]), int(want["duration_sec"]), want["start_time"])
    assert abs(res["summary"]["walking_time_min"] - 7.833333333333333) < 1e-9


def _golden_request():
    import json
    with open(os.path.join(FIXTURES, "golden_gait_quality_request.json")) as f:
        return json.load(f)


def test_chunking_independence_and_determinism(heads):
    from activity_context.eldernet.runtime import build_runtime, handle_request
    rt = build_runtime(heads=heads)
    req = _golden_request()
    run = req["run"]
    whole = handle_request(rt, req)["windows"]
    assert handle_request(rt, req)["windows"] == whole                     # determinism
    cut = 50
    a = {**req, "run": {**run, "end_ts": T0 + cut, "columns_b64": run["columns_b64"][:cut], "tail_b64": []}}
    b = {**req, "run": {**run, "start_ts": T0 + cut - 15, "columns_b64": run["columns_b64"][cut - 15:],
                        "head_b64": []}}
    parts = {w["s"]: w for w in handle_request(rt, a)["windows"] + handle_request(rt, b)["windows"]}
    ref = {w["s"]: w for w in whole}
    assert set(parts) == set(ref)
    assert all(parts[s] == ref[s] for s in ref)                           # bit-identical, no edge exclusion


def test_batch_position_independence(heads):
    from activity_context.eldernet.preprocess import stack_windows, windows_from_array
    rng = np.random.default_rng(0)
    acc = np.cumsum(rng.normal(0, 0.01, (100 * 200, 3)), axis=0) + [0, 0, 1.0]
    b = stack_windows(windows_from_array(acc, 100, hop_s=1))
    full = heads.detect(b)
    for start, n in [(0, 1), (3, 63), (64, 65), (100, 91)]:
        assert np.array_equal(heads.detect(b[start:start + n]), full[start:start + n])
