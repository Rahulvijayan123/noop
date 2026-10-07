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


_ENV_ALLOW = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "PYTHONPATH", "VIRTUAL_ENV",
              "ACTIVITY_HART_CHECKPOINT")


def _env():
    """Explicit allowlist for the serve subprocess (never the full os.environ)."""
    env = {k: os.environ[k] for k in _ENV_ALLOW if k in os.environ}
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


def test_every_window_carries_encoder_independent_features(proc):
    resp = _roundtrip(proc, {"id": "f1", "op": "infer", "run": _golden_run()})
    assert resp["ok"] is True
    assert resp["feature_schema"] == "imu-feat-2"
    for w in resp["windows"]:
        assert set(w["feat"]) == {"accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_hz",
                                  "cadence_strength", "orientation_change_deg"}
        assert w["feat"]["accel_rms_g"] > 0.05
        # imu-feat-2 band is 0.8-3.5 Hz (effective upper edge 3.333 @30 Hz; WS-04-F05).
        assert 0.8 <= w["feat"]["cadence_hz"] <= 3.5
        assert w["feat"]["cadence_strength"] >= 0.3
        assert w["feat"]["jerk_rms_gps"] > 1.0  # per-second (g/s), not per-sample


def test_calibration_status_comes_from_the_manifest_not_model_kind(proc):
    # A01: the baseline manifest has no calibration artifact -> calibrated false everywhere,
    # even though the response is model_status=baseline. Never derived from model_kind.
    resp = _roundtrip(proc, {"id": "cal1", "op": "infer", "run": _golden_run()})
    assert resp["ok"] is True
    assert resp["calibrated"] is False
    assert resp["calibration_version"] is None
    for w in resp["windows"]:
        assert w["calibrated"] is False


def test_manifest_with_calibration_artifact_reports_calibrated(tmp_path):
    # A01: a manifest that DOES carry a versioned calibration section reports calibrated=True
    # with the artifact version, top-level and per window.
    import copy
    with open(os.path.join(FIXTURES, "manifest.baseline.json")) as f:
        m = json.load(f)
    m["calibration"] = {
        "version": "ts-v1",
        "method": "temperature_scaling",
        "fit_subjects": [1, 2, 3],
        "nll": 0.72,
        "brier": 0.11,
        "reliability": {"ece": 0.012},
        "thresholds": {"max_prob": 0.80, "margin": 0.15},
    }
    p = tmp_path / "manifest.calibrated.json"
    p.write_text(json.dumps(m))
    proc = _start_serve(str(p))
    try:
        resp = _roundtrip(proc, {"id": "cal2", "op": "infer", "run": _golden_run()})
        assert resp["ok"] is True
        assert resp["calibrated"] is True
        assert resp["calibration_version"] == "ts-v1"
        for w in resp["windows"]:
            assert w["calibrated"] is True
    finally:
        if proc.poll() is None:
            try:
                _roundtrip(proc, {"id": "t", "op": "shutdown"})
            except Exception:
                proc.kill()
            proc.wait(timeout=10)


def test_malformed_calibration_section_is_uncalibrated_not_an_error(tmp_path):
    # A01: absent or INVALID -> calibrated=false (conservative). A malformed section must not
    # hard-fail the manifest; it simply cannot claim calibration.
    import copy
    with open(os.path.join(FIXTURES, "manifest.baseline.json")) as f:
        m = json.load(f)
    m["calibration"] = {"nll": 0.72}          # missing version + method
    p = tmp_path / "manifest.badcal.json"
    p.write_text(json.dumps(m))
    proc = _start_serve(str(p))
    try:
        resp = _roundtrip(proc, {"id": "cal3", "op": "infer", "run": _golden_run()})
        assert resp["ok"] is True
        assert resp["calibrated"] is False
        assert resp["calibration_version"] is None
        for w in resp["windows"]:
            assert w["calibrated"] is False
    finally:
        if proc.poll() is None:
            try:
                _roundtrip(proc, {"id": "t", "op": "shutdown"})
            except Exception:
                proc.kill()
            proc.wait(timeout=10)


def test_ping_reports_calibration_status(proc):
    resp = _roundtrip(proc, {"id": "cal4", "op": "ping"})
    assert resp["ok"] is True
    assert resp["calibrated"] is False
    assert resp["calibration_version"] is None


def test_default_hop_is_the_training_hop(proc):
    resp = _roundtrip(proc, {"id": "h0", "op": "infer", "run": _golden_run()})
    assert resp["hop_s"] == 2.0
    assert len(resp["windows"]) == 5


def test_a_one_second_hop_doubles_the_window_rate_and_keeps_the_window_length(proc):
    run = _golden_run()
    run["hop_s"] = 1
    resp = _roundtrip(proc, {"id": "h1", "op": "infer", "run": run})
    assert resp["ok"] is True
    assert resp["hop_s"] == 1.0
    wins = resp["windows"]
    assert len(wins) == 9
    assert all(w["e"] - w["s"] == pytest.approx(4.0) for w in wins)
    starts = [w["s"] for w in wins]
    assert all(b - a == pytest.approx(1.0) for a, b in zip(starts, starts[1:]))
    # Every window the 2 s hop would have produced is among them, with the same label.
    base = _roundtrip(proc, {"id": "h2", "op": "infer", "run": _golden_run()})["windows"]
    by_start = {round(w["s"], 3): w for w in wins}
    for w in base:
        assert by_start[round(w["s"], 3)]["label"] == w["label"]


def test_hop_may_ride_at_the_request_root(proc):
    resp = _roundtrip(proc, {"id": "h3", "op": "infer", "run": _golden_run(), "hop_s": 1})
    assert resp["ok"] is True and resp["hop_s"] == 1.0


@pytest.mark.parametrize("bad", [0.5, 3, 0, -1, "1", True, [1]])
def test_other_hops_are_refused_not_rounded(proc, bad):
    run = _golden_run()
    run["hop_s"] = bad
    resp = _roundtrip(proc, {"id": "hb", "op": "infer", "run": run})
    assert resp["ok"] is False
    assert resp["kind"] == "malformed"


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


def test_infer_accepts_top_level_head_tail(proc):
    """The C10 contract's original wording put head/tail at the request root; the
    native shape is inside `run`. Both placements must work (the worker sends both)."""
    run = dict(_golden_run())
    head, tail = run.pop("head_b64"), run.pop("tail_b64")
    resp = _roundtrip(proc, {"id": "tl1", "op": "infer", "run": run,
                             "head_b64": head, "tail_b64": tail})
    assert resp["ok"] is True
    assert resp["windows"], "top-level head/tail must still classify windows"
    assert resp["id"] == "tl1"


def test_explicit_missing_manifest_hard_fails():
    """Audit P2 residual: an explicitly requested manifest that is missing must
    exit loudly (model_missing diagnostic line), never fall back to the
    baseline silently while the lane stamps HART versions."""
    import subprocess, sys, tempfile, os
    missing = os.path.join(tempfile.mkdtemp(), "manifest.json")
    proc = subprocess.run(
        [sys.executable, "-m", "activity_context.serve", "--manifest", missing],
        cwd=os.path.join(os.path.dirname(__file__), ".."), env=_env(),
        capture_output=True, text=True, timeout=30)
    assert proc.returncode != 0
    line = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
    assert '"kind": "model_missing"' in line or '"kind":"model_missing"' in line
