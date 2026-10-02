"""Serve protocol tests (C10) — drive the persistent process over stdin/stdout.

The baseline path must work with numpy only (no torch): these tests run the
real serve.py subprocess against the baseline manifest.
"""

import json
import os
import subprocess
import sys

import pytest

from activity_context.preprocess import (CHANNEL_ORDER, decode_frame_hex,
                                         encode_columns_b64)

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
PKG = os.path.join(os.path.dirname(__file__), "..")


def _env():
    env = dict(os.environ)
    env["PYTHONPATH"] = PKG + os.pathsep + env.get("PYTHONPATH", "")
    return env


def _start_serve(manifest=None):
    cmd = [sys.executable, "-m", "activity_context.serve"]
    if manifest:
        cmd += ["--manifest", manifest]
    return subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=_env(), text=True, bufsize=1)


def _roundtrip(proc, req):
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    assert line, "serve process closed stdout"
    return json.loads(line)


@pytest.fixture()
def proc():
    p = _start_serve(os.path.join(FIXTURES, "manifest.baseline.json"))
    yield p
    if p.poll() is None:
        try:
            _roundtrip(p, {"id": "t", "op": "shutdown"})
        except Exception:
            p.kill()
        p.wait(timeout=10)


def _golden_run():
    with open(os.path.join(FIXTURES, "golden_imu_frames.json")) as f:
        gj = json.load(f)
    seconds = []
    for hx in gj["frames"]:
        base_ts, cols = decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    body = [encode_columns_b64(c) for _, c in seconds]
    head = [encode_columns_b64(seconds[0][1])]
    tail = [encode_columns_b64(seconds[-1][1])]
    return {"start_ts": start, "end_ts": end, "sample_rate_hz": 100,
            "channels_order": list(CHANNEL_ORDER),
            "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": body, "head_b64": head, "tail_b64": tail}


def test_ping(proc):
    resp = _roundtrip(proc, {"id": "p1", "op": "ping"})
    assert resp["id"] == "p1"
    assert resp["ok"] is True
    assert resp["model_status"] == "baseline"
    assert resp["preprocessing_version"] == "1.0.0"
    assert resp["versions"]["numpy"]


def test_infer_happy_path_baseline(proc):
    run = _golden_run()
    resp = _roundtrip(proc, {"id": "i1", "op": "infer", "run": run})
    assert resp["ok"] is True
    assert resp["id"] == "i1"
    wins = resp["windows"]
    # head+tail recover all 5 windows [start, start+2, ..., start+8]
    assert len(wins) == 5
    for w in wins:
        assert w["label"] == "walking"
        assert w["baseline"] is True
        assert set(w["probs"]) == {"stationary", "walking", "running",
                                   "other_movement", "unknown"}
        assert w["e"] - w["s"] == pytest.approx(4.0)
    # windows contiguous, hop 2 s
    starts = [w["s"] for w in wins]
    assert all(b - a == pytest.approx(2.0) for a, b in zip(starts, starts[1:]))
    assert resp["model_version"] == "baseline-v0"
    assert resp["manifest"]["thresholds"] == {"max_prob": 0.8, "margin": 0.15}


def test_infer_malformed_b64_rejected(proc):
    run = _golden_run()
    run["columns_b64"][0] = "!!not-base64!!"
    resp = _roundtrip(proc, {"id": "m1", "op": "infer", "run": run})
    assert resp["ok"] is False
    assert resp["kind"] == "malformed"
    assert resp["id"] == "m1"


def test_infer_missing_columns_rejected(proc):
    run = _golden_run()
    del run["columns_b64"]
    resp = _roundtrip(proc, {"id": "m2", "op": "infer", "run": run})
    assert resp["kind"] == "malformed"


def test_infer_unknown_units_rejected(proc):
    run = _golden_run()
    run["units"] = {"accel": "m/s^2", "gyro": "rad/s"}
    resp = _roundtrip(proc, {"id": "m3", "op": "infer", "run": run})
    assert resp["kind"] == "malformed"


def test_infer_bounded_payload(proc):
    run = _golden_run()
    run["columns_b64"] = ["AAAA"] * 100          # wrong per-second size too
    resp = _roundtrip(proc, {"id": "m4", "op": "infer", "run": run})
    assert resp["kind"] == "malformed"


def test_infer_head_tail_bounds(proc):
    run = _golden_run()
    run["head_b64"] = ["AAAA"] * 4               # > MAX_HEAD_SECONDS=3
    resp = _roundtrip(proc, {"id": "m5", "op": "infer", "run": run})
    assert resp["kind"] == "malformed"


def test_unknown_op_rejected(proc):
    resp = _roundtrip(proc, {"id": "u1", "op": "explode"})
    assert resp["kind"] == "malformed"


def test_bad_json_line_returns_malformed(proc):
    proc.stdin.write("{oops\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    resp = json.loads(line)
    assert resp["ok"] is False and resp["kind"] == "malformed"


def test_shutdown(proc):
    resp = _roundtrip(proc, {"id": "s1", "op": "shutdown"})
    assert resp["ok"] is True
    proc.wait(timeout=10)
    assert proc.returncode == 0
