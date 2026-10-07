"""gait-quality-1 serve: protocol shapes, unavailable model, malformed requests, timeouts, caps, live process."""

import json

import numpy as np
import pytest

from activity_context.eldernet import DEFAULT_HOP_S, MODEL_VERSION, UPSTREAM_COMMIT
from activity_context.eldernet.runtime import build_runtime, handle_request
from activity_context.eldernet.serve import handle_line, install_alarm_handler

from ._helpers import T0, FakeHeads, Serve, g_to_columns, request_for, synth_g

PING_KEYS = {"id", "op", "ok", "model_available", "model_status", "model_error", "model_id", "model_version",
             "weights", "upstream_commit", "preprocessing_version", "package_version"}
INFER_KEYS = {"id", "op", "ok", "schema", "model_id", "model_version", "weights", "upstream_commit",
              "preprocessing_version", "window_s", "hop_s", "calibration", "gait_threshold", "windows",
              "n_dropped_nonfinite", "duration_ms"}


def _cols(n=60):
    acc = np.concatenate([synth_g(20, "still", 1), synth_g(n - 20, "walk", 2)])
    return g_to_columns(acc)


@pytest.fixture()
def rt():
    return build_runtime(heads=FakeHeads())


def test_ping_and_infer_shapes(rt):
    ping = handle_request(rt, {"id": "p", "op": "ping"})
    assert PING_KEYS <= set(ping) and ping["model_available"] and ping["model_status"] == "eldernet_loaded"
    assert ping["model_id"] == "eldernet" and ping["model_version"] == MODEL_VERSION
    assert ping["upstream_commit"] == UPSTREAM_COMMIT and ping["hop_s"] == DEFAULT_HOP_S
    resp = handle_request(rt, request_for(_cols()))
    assert set(resp) == INFER_KEYS and resp["ok"] and resp["schema"] == "gait-quality-1"
    assert resp["hop_s"] == DEFAULT_HOP_S and resp["window_s"] == 10 and resp["calibration"] is None
    assert resp["gait_threshold"] == 0.5 and resp["n_dropped_nonfinite"] == 0
    ss = [w["s"] for w in resp["windows"]]
    assert ss == list(range(T0, T0 + 51, DEFAULT_HOP_S))
    assert all(isinstance(s, int) for s in ss)
    assert resp["windows"][0]["prefiltered"] is True and resp["windows"][-1]["is_gait"] is True
    assert "speed_mps" in resp["windows"][-1] and "speed_mps" not in resp["windows"][0]


def test_request_hop_overrides_default(rt):
    resp = handle_request(rt, request_for(_cols(), hop_s=1))
    assert resp["hop_s"] == 1 and len(resp["windows"]) == 51


def test_unavailable_model_keeps_answering(monkeypatch):
    monkeypatch.delenv("ELDERNET_WEIGHTS_DIR", raising=False)
    rt = build_runtime(None)
    assert not rt.available and rt.error.kind == "model_missing"
    ping = handle_request(rt, {"id": "p", "op": "ping"})
    assert ping["ok"] and ping["model_available"] is False and ping["model_status"] == "eldernet_unavailable"
    assert ping["model_error"].startswith("model_missing")
    out = json.loads(handle_line(rt, json.dumps(request_for(_cols())))[0])
    assert out == {"id": "r1", "ok": False, "error": out["error"], "kind": "model_missing"}


def test_wrong_weights_are_weights_mismatch(tmp_path):
    for n in ("gait_detection", "gait_speed", "cadence", "gait_length", "regularity", "step_count"):
        (tmp_path / f"{n}_weights.pt").write_bytes(b"0" * 10)
    rt = build_runtime(str(tmp_path))
    assert rt.error.kind == "weights_mismatch"
    out = json.loads(handle_line(rt, json.dumps(request_for(_cols())))[0])
    assert out["kind"] == "weights_mismatch"


@pytest.mark.parametrize("line,frag", [
    ("not json", "valid JSON"), ("[1,2]", "valid JSON"), ('{"op":"ping"}', "string 'id'"),
    ('{"id":"x","op":"dance"}', "unknown op"), ('{"id":"x","op":"infer"}', "object 'run'"),
])
def test_malformed_lines(rt, line, frag):
    out = json.loads(handle_line(rt, line)[0])
    assert out["ok"] is False and out["kind"] == "malformed" and frag in out["error"]


@pytest.mark.parametrize("mutate,frag", [
    (lambda r: r["run"].update(end_ts=r["run"]["start_ts"]), "start_ts < end_ts"),
    (lambda r: r["run"].update(sample_rate_hz=50), "100 Hz"),
    (lambda r: r["run"].update(channels_order=["ax"]), "channels_order"),
    (lambda r: r["run"].update(units={"accel": "m/s^2", "gyro": "deg/s"}), "unit"),
    (lambda r: r["run"].update(hop_s=3), "hop_s"),
    (lambda r: r["run"].update(hop_s=True), "hop_s"),
    (lambda r: r["run"]["columns_b64"].pop(), "count"),
    (lambda r: r["run"]["columns_b64"].__setitem__(3, "!!notb64"), ""),
    (lambda r: r["run"].update(head_b64="x"), "head_b64"),
])
def test_malformed_requests(rt, mutate, frag):
    req = request_for(_cols(30))
    mutate(req)
    out = json.loads(handle_line(rt, json.dumps(req))[0])
    assert out["ok"] is False and out["kind"] == "malformed" and frag in out["error"]


def test_gap_inside_request_yields_no_window_across_it(rt):
    from activity_context.eldernet.runtime import infer_seconds
    secs = [(T0 + i, c) for i, c in enumerate(_cols(60)) if i not in (30, 31)]      # seconds 30-31 missing
    windows, _ = infer_seconds(rt, secs, T0, T0 + 60, 1)
    assert windows and all(w["e"] <= T0 + 30 or w["s"] >= T0 + 32 for w in windows)


def test_timeout_and_output_too_large():
    assert install_alarm_handler()
    slow = build_runtime(heads=FakeHeads(delay_s=0.5))
    out = json.loads(handle_line(slow, json.dumps(request_for(_cols())), timeout=0.1)[0])
    assert out["kind"] == "timeout" and out["id"] == "r1"
    small = build_runtime(heads=FakeHeads())
    small.max_output_bytes = 200
    out = json.loads(handle_line(small, json.dumps(request_for(_cols())))[0])
    assert out["kind"] == "output_too_large"


def test_nonfinite_model_output_counted(rt):
    bad = build_runtime(heads=FakeHeads(nonfinite_quality=True))
    resp = handle_request(bad, request_for(_cols(), hop_s=1))
    assert resp["n_dropped_nonfinite"] == 1 and len(resp["windows"]) == 50


def test_shutdown(rt):
    out, stop = handle_line(rt, '{"id":"s","op":"shutdown"}')
    assert stop and json.loads(out) == {"id": "s", "op": "shutdown", "ok": True}


def test_live_process_without_weights_reports_unavailable(tmp_path):
    s = Serve("--weights-dir", str(tmp_path / "none"))
    try:
        ping = s.send({"id": "p", "op": "ping"})
        assert ping["ok"] and ping["model_available"] is False and ping["model_error"].startswith("model_missing")
        out = s.send(request_for(_cols(20)))
        assert out["ok"] is False and out["kind"] == "model_missing"
        assert s.send_line("garbage")["kind"] == "malformed"
    finally:
        s.close()
