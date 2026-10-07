"""One HART serve response carries every expert's evidence: coarse + fine HART probs and opt-in ElderNet gait."""

import numpy as np
import pytest

from activity_context import serve
from activity_context.eldernet.runtime import build_runtime
from activity_context.model import HARTModel
from activity_context.model_names import FINE_SCHEMA, WISDM_ACTIVITY_NAMES

from .eldernet._helpers import T0, FakeHeads, g_to_columns, request_for, synth_g


def _walk_after_rest(n=60):
    return g_to_columns(np.concatenate([synth_g(20, "still", 1), synth_g(n - 20, "walk", 2)]))


def _ctx(**kw):
    return serve.build_context(None, None, **kw)


def test_gait_expert_is_off_by_default():
    ctx = _ctx()
    assert ctx.gait is None and ctx.gait_status == "gait_absent"
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest()))
    assert resp["ok"] and resp["windows"]
    assert not any(k.startswith("gait") for k in resp)
    assert serve.handle_ping(ctx)["gait_status"] == "gait_absent"


def test_cohosted_gait_windows_ride_beside_hart_windows():
    ctx = _ctx(gait_runtime=build_runtime(heads=FakeHeads()))
    assert ctx.gait_status == "gait_loaded"
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest()))
    assert resp["gait_schema"] == "gait-quality-1" and resp["gait_window_s"] == 10
    assert resp["gait_hop_s"] == 5 and resp["gait_threshold"] == 0.5
    gw = resp["gait_windows"]
    assert [w["s"] for w in gw] == list(range(T0, T0 + 51, 5))
    assert gw[0]["prefiltered"] is True and gw[0]["gait_prob"] == 0.0
    assert gw[-1]["is_gait"] is True and "cadence_spm" in gw[-1]
    # HART windows are unchanged by the gait expert being present.
    plain = serve.handle_infer(_ctx(), request_for(_walk_after_rest()))
    assert resp["windows"] == plain["windows"]


def test_unloadable_gait_expert_is_a_soft_failure(monkeypatch):
    monkeypatch.delenv("ELDERNET_WEIGHTS_DIR", raising=False)
    ctx = _ctx(gait_expert="eldernet")
    assert ctx.gait is None and ctx.gait_status == "gait_unavailable" and ctx.gait_error
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest()))
    assert resp["ok"] and resp["windows"] and "gait_windows" not in resp


def test_gait_inference_error_never_drops_hart_windows():
    class Broken(FakeHeads):
        def detect(self, batch):
            raise RuntimeError("boom")

    ctx = _ctx(gait_runtime=build_runtime(heads=Broken()))
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest()))
    assert resp["ok"] and resp["windows"]
    assert resp["gait_status"] == "gait_failed" and "gait_windows" not in resp


def test_unknown_gait_expert_name_is_unavailable():
    ctx = _ctx(gait_expert="nope")
    assert ctx.gait_status == "gait_unavailable" and "unknown gait expert" in ctx.gait_error


def _stub_hart(letters):
    m = HARTModel.__new__(HARTModel)
    m.class_ids = list(letters)
    m.fine_names = [WISDM_ACTIVITY_NAMES[c] for c in letters]
    return m


def test_fine_probs_keep_every_wisdm_activity():
    letters = list(WISDM_ACTIVITY_NAMES)
    m = _stub_hart(letters)
    logits = np.zeros(len(letters))
    logits[letters.index("C")] = 3.0                       # stairs: invisible in the coarse head
    fine = m._fine_probs(logits)
    assert set(fine) == set(WISDM_ACTIVITY_NAMES.values()) and len(fine) == 18
    assert abs(sum(fine.values()) - 1.0) < 1e-9
    assert max(fine, key=fine.get) == "stairs"


def test_fine_probs_absent_for_non_wisdm_heads():
    m = HARTModel.__new__(HARTModel)
    m.fine_names = None
    assert m._fine_probs(np.zeros(5)) is None


def test_fine_schema_is_stamped_only_when_windows_carry_fine(monkeypatch):
    ctx = _ctx()

    class Pred:
        label, probs, baseline, calibrated = "stationary", {"stationary": 1.0}, False, False
        fine_probs = {"sitting": 0.7, "standing": 0.3}

    class Model:
        fine_names = ["sitting", "standing"]

        def predict_window(self, data):
            return Pred()

    ctx.model = Model()
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest(30)))
    assert resp["fine_schema"] == FINE_SCHEMA
    assert all(w["fine"] == {"sitting": 0.7, "standing": 0.3} for w in resp["windows"])
    assert serve.handle_ping(ctx)["fine_schema"] == FINE_SCHEMA
    assert "fine_schema" not in serve.handle_infer(_ctx(), request_for(_walk_after_rest(30)))


def test_real_eldernet_cohosted_smoke():
    """Real pinned weights when the operator has them (never committed): gait detected on walking, not rest."""
    import os
    wd, ud = os.environ.get("ELDERNET_WEIGHTS_DIR"), os.environ.get("ELDERNET_UPSTREAM_DIR")
    if not (wd and ud and os.path.isdir(wd) and os.path.isfile(os.path.join(ud, "models.py"))):
        pytest.skip("real ElderNet weights / upstream source not configured")
    ctx = _ctx(gait_expert="eldernet")
    assert ctx.gait_status == "gait_loaded", ctx.gait_error
    resp = serve.handle_infer(ctx, request_for(_walk_after_rest(60)))
    gw = resp["gait_windows"]
    assert gw[0]["prefiltered"] is True
    assert all(0.0 <= w["gait_prob"] <= 1.0 for w in gw)
