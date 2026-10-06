"""motion-heads-1 serve tests: protocol shapes, unavailable models, refusals, timeouts, omissions, caps."""

import json
import os

import numpy as np
import pytest

pytest.importorskip("scipy")

from activity_context.inertia.contract import make_info  # noqa: E402
from activity_context.inertia.registry import build_encoder  # noqa: E402
from activity_context.inertia.runtime import (build_runtime, handle_request, infer_seconds)  # noqa: E402
from activity_context.inertia.serve import handle_line  # noqa: E402

from ._helpers import (T0, Serve, constant_columns, request_for, seconds_from_columns, synth,  # noqa: E402
                       write_standin_bundle)

PING_KEYS = {"id", "op", "ok", "model_available", "model_status", "model_error", "encoder_id", "encoder_kind",
             "encoder_version", "heads_version", "bundle_sha256", "checkpoint_sha256", "preprocessing_version",
             "evidence_tier_max", "package_version"}
INFER_KEYS = {"id", "op", "ok", "schema", "encoder_id", "encoder_kind", "encoder_version", "checkpoint_sha256",
              "heads_version", "bundle_sha256", "preprocessing_version", "evidence_tier_max", "window_s", "hop_s",
              "bundle", "windows", "n_dropped_nonfinite", "duration_ms"}


@pytest.fixture(scope="module")
def bundle_dir(tmp_path_factory):
    out = str(tmp_path_factory.mktemp("bundles") / "handcrafted")
    write_standin_bundle(out, build_encoder("standin:handcrafted-stats-v1"))
    return out


@pytest.fixture(scope="module")
def rt(bundle_dir):
    r = build_runtime(bundle_dir, allow_standin_shadow=True)
    assert r.error is None, r.error
    return r


@pytest.fixture(scope="module")
def req():
    return request_for(synth(64, seed=1), hop_s=5)


@pytest.fixture()
def serve(bundle_dir):
    s = Serve("--bundle", bundle_dir, "--allow-standin-shadow")
    yield s
    s.close()


def _no_duration(resp):
    return {k: v for k, v in resp.items() if k != "duration_ms"}


def test_ping_and_infer_shapes_over_the_wire(serve, req):
    ping = serve.send({"id": "p", "op": "ping"})
    assert set(ping) == PING_KEYS and ping["ok"] and ping["model_available"]
    assert ping["model_status"] == "standin_shadow" and ping["encoder_kind"] == "standin"
    assert ping["evidence_tier_max"] == "shadow" and ping["preprocessing_version"] == "inertia-prep-1"
    resp = serve.send(req)
    assert set(resp) == INFER_KEYS and resp["ok"] and resp["schema"] == "motion-heads-1"
    assert resp["window_s"] == 30 and resp["hop_s"] == 5 and resp["n_dropped_nonfinite"] == 0
    assert resp["bundle_sha256"] == ping["bundle_sha256"] and resp["heads_version"] == ping["heads_version"]
    assert set(resp["bundle"]) == {"heads", "ood"}
    for h, blk in resp["bundle"]["heads"].items():
        assert set(blk) == {"class_order", "prior", "status", "tau", "merge_into", "covers"}
    assert [w["s"] - T0 for w in resp["windows"]] == [0, 5, 10, 15, 20, 25, 30]
    for w in resp["windows"]:
        assert isinstance(w["s"], int) and w["e"] - w["s"] == 30
        assert set(w) == {"s", "e", "posture", "locomotion", "arm_behavior", "transition", "movement_intensity",
                          "ood_score", "is_ood"}
        for h in ("posture", "locomotion", "arm_behavior"):
            assert abs(sum(w[h].values()) - 1.0) < 1e-5
            assert set(w[h]) == set(resp["bundle"]["heads"][h]["prior"])
        assert isinstance(w["is_ood"], bool)
    assert serve.send({"id": "s", "op": "shutdown"}) == {"id": "s", "op": "shutdown", "ok": True}
    serve.proc.wait(timeout=10)


def test_default_hop_comes_from_the_bundle(rt, req):
    r = dict(req, run={k: v for k, v in req["run"].items() if k != "hop_s"})
    assert handle_request(rt, r)["hop_s"] == rt.bundle.preprocessing["hop_s"]


def test_determinism_of_the_whole_response(rt, req):
    a, b = handle_request(rt, req), handle_request(rt, req)
    assert json.dumps(_no_duration(a), sort_keys=True) == json.dumps(_no_duration(b), sort_keys=True)


def test_model_missing_keeps_answering(tmp_path, req):
    s = Serve("--bundle", os.path.join(tmp_path, "no-bundle"))
    try:
        ping = s.send({"id": "p", "op": "ping"})
        assert set(ping) == PING_KEYS and ping["ok"] is True and ping["model_available"] is False
        assert ping["model_status"] == "inertia_unavailable" and ping["model_error"].startswith("model_missing")
        assert ping["encoder_kind"] is None
        resp = s.send(req)
        assert resp == {"id": "r1", "ok": False, "error": resp["error"], "kind": "model_missing"}
    finally:
        s.close()


def test_standin_refused_without_flag(bundle_dir, req):
    r = build_runtime(bundle_dir)
    assert r.status == "inertia_unavailable" and r.error.kind == "model_missing"
    line, _ = handle_line(r, json.dumps(req))
    assert json.loads(line)["kind"] == "model_missing"
    ping = json.loads(handle_line(r, json.dumps({"id": "p", "op": "ping"}))[0])
    assert ping["model_available"] is False and "allow-standin-shadow" in ping["model_error"]


def test_wrong_checkpoint_hash(tmp_path, req):
    pytest.importorskip("torch")
    from activity_context.inertia.adapter import Inertia1Encoder
    from activity_context.inertia.bundle import json_bytes
    from ._helpers import tiny_art
    ckpt, cfg = tiny_art(tmp_path)
    enc = Inertia1Encoder(ckpt, cfg)
    bdir = os.path.join(tmp_path, "art")
    write_standin_bundle(bdir, enc, extra_files={"encoder.json": json_bytes(cfg)})
    ok = build_runtime(bdir, checkpoint=ckpt, allow_standin_shadow=True)
    assert ok.error is None and handle_request(ok, req)["checkpoint_sha256"] == cfg["checkpoint"]["sha256"]
    other, _ = tiny_art(tmp_path, seed=1, name="other.ckpt")
    s = Serve("--bundle", bdir, "--checkpoint", other, "--allow-standin-shadow")
    try:
        ping = s.send({"id": "p", "op": "ping"})
        assert ping["model_available"] is False and ping["model_error"].startswith("checkpoint_mismatch")
        assert s.send(req)["kind"] == "checkpoint_mismatch"
    finally:
        s.close()
    # A bundle trained on another encoder is refused even when the checkpoint itself is valid.
    other_cfg = tiny_art(tmp_path, seed=1, name="other.ckpt")[1]
    mism = build_runtime(bdir, checkpoint=other, encoder_config=None, allow_standin_shadow=True,
                         encoder=Inertia1Encoder(other, other_cfg))
    assert mism.error.kind == "config_mismatch"


@pytest.mark.parametrize("mutate,needle", [
    (lambda r: r["run"].update(columns_b64=["!!!"] * len(r["run"]["columns_b64"])), "base64"),
    (lambda r: r["run"]["columns_b64"].pop(), "count"),
    (lambda r: r["run"].update(hop_s=3), "hop_s"),
    (lambda r: r["run"].update(hop_s=True), "hop_s"),
    (lambda r: r["run"].update(units={"accel": "m/s^2", "gyro": "deg/s"}), "unit"),
    (lambda r: r["run"].update(head_b64=r["run"]["columns_b64"][:4]), "head_b64"),
    (lambda r: r["run"].update(sample_rate_hz=50), "100 Hz"),
    (lambda r: r["run"].update(end_ts=r["run"]["start_ts"]), "start_ts"),
    (lambda r: r.pop("run"), "run"),
    (lambda r: r.update(op="explode"), "unknown op"),
    (lambda r: r.update(id=7), "id"),
])
def test_malformed_requests(rt, req, mutate, needle):
    bad = json.loads(json.dumps(req))
    mutate(bad)
    resp = json.loads(handle_line(rt, json.dumps(bad))[0])
    assert resp["ok"] is False and resp["kind"] == "malformed" and needle in resp["error"], resp


def test_bad_json_lines(rt):
    for line in ("{not json", "[1, 2]", "42"):
        resp = json.loads(handle_line(rt, line)[0])
        assert resp == {"id": None, "ok": False, "error": resp["error"], "kind": "malformed"}


def test_hop_longer_than_window_refused(tmp_path, req):
    bdir = os.path.join(tmp_path, "w10")
    write_standin_bundle(bdir, build_encoder("standin:handcrafted-stats-v1", window_s=10), window_s=10, hop_s=5)
    r = build_runtime(bdir, allow_standin_shadow=True)
    bad = json.loads(json.dumps(req))
    bad["run"]["hop_s"] = 15
    assert json.loads(handle_line(r, json.dumps(bad))[0])["kind"] == "malformed"
    bad["run"]["hop_s"] = 10
    resp = handle_request(r, bad)
    assert resp["window_s"] == 10 and all(w["e"] - w["s"] == 10 for w in resp["windows"])


def test_timeout_then_still_serving(bundle_dir):
    s = Serve("--bundle", bundle_dir, "--allow-standin-shadow", "--timeout", "0.001")
    try:
        resp = s.send(request_for(constant_columns(1800), hop_s=1))
        assert resp["ok"] is False and resp["kind"] == "timeout"
        assert s.send({"id": "p", "op": "ping"})["ok"] is True
    finally:
        s.close()


class _NaNEncoder:
    """Wraps a real encoder; poisons chosen rows of the embedding."""

    def __init__(self, inner, rows):
        self.inner, self.rows = inner, set(rows)
        self._info = inner.info

    @property
    def info(self):
        return self._info

    def embed(self, batch):
        e = self.inner.embed(batch).copy()
        for r in self.rows:
            if r < e.shape[0]:
                e[r, 0] = np.nan
        return e


def test_nan_embedding_window_dropped_and_counted(bundle_dir, req):
    inner = build_encoder("standin:handcrafted-stats-v1")
    r = build_runtime(bundle_dir, allow_standin_shadow=True, encoder=_NaNEncoder(inner, [1, 4]))
    resp = handle_request(r, req)
    assert resp["ok"] and resp["n_dropped_nonfinite"] == 2
    assert [w["s"] - T0 for w in resp["windows"]] == [0, 10, 15, 25, 30]


def test_output_too_large(rt, req):
    small = build_runtime(rt.bundle.path, allow_standin_shadow=True)
    small.max_output_bytes = 2000
    resp = json.loads(handle_line(small, json.dumps(req))[0])
    assert resp == {"id": "r1", "ok": False, "error": resp["error"], "kind": "output_too_large"}


def test_gaps_produce_no_windows_across_them(rt):
    cols = synth(120, seed=2)
    secs = seconds_from_columns(cols[:50], T0) + seconds_from_columns(cols[50:], T0 + 55)
    windows, dropped = infer_seconds(rt, secs, T0, T0 + 125, 5)
    assert windows and dropped == 0
    for w in windows:
        assert w["e"] <= T0 + 49 or w["s"] >= T0 + 56, (w["s"], w["e"])


def test_encoder_bundle_mismatch_is_config_mismatch(bundle_dir):
    wrong = build_encoder("standin:nara-imu-feat-1-accel")
    r = build_runtime(bundle_dir, allow_standin_shadow=True, encoder=wrong)
    assert r.error.kind == "config_mismatch"
    info = make_info(encoder_id="standin:handcrafted-stats-v1", kind="standin", config={"other": 1},
                     embedding_dim=72, window_s=30, extraction_point="x")
    fake = type("E", (), {"info": info, "embed": lambda self, b: np.zeros((b.shape[0], 72), np.float32)})()
    err = build_runtime(bundle_dir, allow_standin_shadow=True, encoder=fake).error   # same id, other config
    assert err.kind == "config_mismatch" and "config_sha256" in err.message
