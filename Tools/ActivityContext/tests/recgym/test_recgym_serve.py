"""The serve protocol (``exercise-windows-1``) with a stand-in model: no checkpoint needed."""

import json

import numpy as np
import pytest

from activity_context.loaded import loaded_digest
from activity_context.recgym import CLASSES, MODEL_ID, MODEL_VERSION, WIRE_SCHEMA
from activity_context.recgym.runtime import build_runtime, handle_request
from activity_context.recgym.serve import encode_line, handle_line
from activity_context.recgym.weights import CHECKPOINT

from ._helpers import T0, FakeModel, Serve, imu_to_columns, request_for, synth_imu

PING_KEYS = {"id", "op", "ok", "model_available", "model_status", "model_error", "model_id", "model_version",
             "weights_sha256", "upstream_commit", "preprocessing_version", "scaler_version", "scaler_sha256", "classes",
             "null_class", "trained_placement", "axis_mapping", "window_s", "hop_s", "rate_hz", "package_version",
             "schema", "preprocessing", "loaded", "loaded_digest"}
INFER_KEYS = {"id", "op", "ok", "schema", "model_id", "model_version", "weights_sha256", "upstream_commit",
              "preprocessing_version", "scaler_version", "scaler_sha256", "classes", "null_class", "trained_placement",
              "axis_mapping", "window_s", "hop_s", "rate_hz", "windows", "n_dropped_nonfinite", "duration_ms"}


def _cols(n=40, kind="walk"):
    acc, gyr = synth_imu(n, kind=kind)
    return imu_to_columns(acc, gyr)


def test_ping_reports_identity_and_a_string_loaded_map():
    rt = build_runtime(model=FakeModel())
    resp = handle_request(rt, {"id": "p", "op": "ping"})
    assert set(resp) == PING_KEYS
    assert resp["model_available"] is True and resp["model_status"] == "recgym_loaded"
    assert resp["model_id"] == MODEL_ID and resp["model_version"] == MODEL_VERSION
    assert resp["weights_sha256"] == CHECKPOINT.sha256 and resp["classes"] == list(CLASSES)
    assert resp["trained_placement"] == "wrist" and resp["axis_mapping"] == "identity_unverified"
    loaded = resp["loaded"]
    assert all(isinstance(k, str) and isinstance(v, str) for k, v in loaded.items())
    assert loaded["scaler_sha256"] == resp["scaler_sha256"] and "weights_sha256" not in loaded  # test double
    assert resp["loaded_digest"] == loaded_digest(loaded)


def test_infer_returns_probabilities_per_window():
    rt = build_runtime(model=FakeModel())
    resp = handle_request(rt, request_for(_cols(40)))
    assert set(resp) == INFER_KEYS and resp["ok"] and resp["schema"] == WIRE_SCHEMA
    wins = resp["windows"]
    assert wins and all(set(w) == {"s", "e", "p", "input_sha256"} for w in wins)
    assert all(len(w["p"]) == 12 and abs(sum(w["p"]) - 1) < 1e-5 for w in wins)
    assert all(w["s"] % 2 == 0 and w["e"] == w["s"] + 4 for w in wins)
    assert resp["n_dropped_nonfinite"] == 0


def test_head_and_tail_seconds_feed_the_filters_but_never_become_windows():
    cols = _cols(46)
    rt = build_runtime(model=FakeModel())
    resp = handle_request(rt, request_for(cols, start_ts=T0 - 3, head=3, tail=3))
    body = (T0, T0 + 40)
    assert resp["windows"][0]["s"] == T0 and all(body[0] <= w["s"] and w["e"] <= body[1] for w in resp["windows"])


def test_a_nonfinite_window_is_dropped_and_counted():
    rt = build_runtime(model=FakeModel(nonfinite_first=True))
    resp = handle_request(rt, request_for(_cols(20)))
    assert resp["n_dropped_nonfinite"] == 1
    assert len(json.loads(encode_line(resp, 1 << 20))["windows"]) == len(resp["windows"])


@pytest.mark.parametrize("mutate, needle", [
    (lambda r: r["run"].update(sample_rate_hz=50), "100 Hz"),
    (lambda r: r["run"].update(units={"accel": "m/s^2", "gyro": "deg/s"}), "accel"),
    (lambda r: r["run"].update(channels_order=["gx", "gy", "gz", "ax", "ay", "az"]), "channels_order"),
    (lambda r: r["run"].update(end_ts=r["run"]["end_ts"] + 1), "columns_b64 count"),
    (lambda r: r["run"].update(start_ts="x"), "start_ts"),
    (lambda r: r.pop("run"), "run"),
    (lambda r: r["run"].update(head_b64=["AA=="] * 4), "head_b64"),
])
def test_malformed_requests_are_refused(mutate, needle):
    rt = build_runtime(model=FakeModel())
    req = request_for(_cols(10))
    mutate(req)
    out = json.loads(handle_line(rt, json.dumps(req))[0])
    assert out["ok"] is False and out["kind"] == "malformed" and needle in out["error"]


def test_an_unavailable_model_keeps_the_process_up_and_refuses_infer(tmp_path):
    rt = build_runtime(str(tmp_path / "missing.pt"))
    ping = handle_request(rt, {"id": "p", "op": "ping"})
    assert ping["model_available"] is False and ping["model_status"] == "recgym_unavailable"
    assert ping["model_error"].startswith("model_missing")
    assert set(ping["loaded"]) <= {"schema", "code_sha256", "env.OMP_NUM_THREADS", "env.OPENBLAS_NUM_THREADS",
                                   "env.MKL_NUM_THREADS"}
    out = json.loads(handle_line(rt, json.dumps(request_for(_cols(10))))[0])
    assert out["ok"] is False and out["kind"] == "model_missing"
    bad = tmp_path / CHECKPOINT.name
    bad.write_bytes(b"0" * CHECKPOINT.size)
    rt = build_runtime(str(tmp_path))
    assert rt.error.kind == "weights_mismatch"


def test_output_too_large_and_bad_lines():
    rt = build_runtime(model=FakeModel())
    resp = handle_request(rt, request_for(_cols(40)))
    assert json.loads(encode_line(resp, 100))["kind"] == "output_too_large"
    assert json.loads(handle_line(rt, "not json")[0])["kind"] == "malformed"
    assert json.loads(handle_line(rt, json.dumps({"id": "x", "op": "train"}))[0])["kind"] == "malformed"
    line, stop = handle_line(rt, json.dumps({"id": "s", "op": "shutdown"}))
    assert stop and json.loads(line)["ok"]


def test_live_process_without_a_checkpoint(tmp_path):
    s = Serve("--weights-path", str(tmp_path / "none.pt"))
    try:
        ping = s.send({"id": "p", "op": "ping"})
        assert ping["ok"] and ping["model_available"] is False
        out = s.send(request_for(_cols(10)))
        assert out["ok"] is False and out["kind"] == "model_missing"
    finally:
        s.close()
    assert s.proc.returncode == 0


def test_probabilities_follow_the_model_logits():
    from activity_context.recgym.model import softmax
    rt = build_runtime(model=FakeModel())
    cols = _cols(20)
    resp = handle_request(rt, request_for(cols))
    from activity_context.recgym.preprocess import stack_windows, windows_from_seconds
    wins = windows_from_seconds([(T0 + i, c) for i, c in enumerate(cols)], T0, T0 + 20)
    p = softmax(FakeModel().logits(rt.scaler.transform(stack_windows(wins))))
    assert np.allclose(np.array([w["p"] for w in resp["windows"]]), p, atol=5e-7)
