"""The port equals upstream: logits on upstream-produced goldens to 1e-5 (needs the real checkpoint:
RECGYM_WEIGHTS_PATH; skipped otherwise)."""

import numpy as np
import pytest

from activity_context.recgym import CLASSES

from ._helpers import golden, weights_path_or_skip

TOL = 1e-5


@pytest.fixture(scope="module")
def model():
    path = weights_path_or_skip()
    from activity_context.recgym.model import load_model
    from activity_context.recgym.weights import resolve_measured
    p, _ = resolve_measured(path)
    return load_model(p, threads=1)


def test_port_logits_equal_upstream_on_real_recgym_windows(model):
    from activity_context.recgym.scaler import load_scaler
    g = golden()
    raw = np.stack([np.asarray(r["raw"], np.float64) for r in g["real"]])
    want = np.stack([np.asarray(r["upstream_logits"], np.float64) for r in g["real"]])
    got = model.logits(load_scaler().transform(raw))
    assert np.max(np.abs(got - want)) <= TOL
    assert [CLASSES[i] for i in got.argmax(1)] == [CLASSES[i] for i in want.argmax(1)]


def test_port_logits_equal_upstream_on_synthetic_inputs(model):
    g = golden()
    x = np.stack([np.asarray(s["scaled_float32"], np.float32) for s in g["synthetic"]])
    want = np.stack([np.asarray(s["upstream_logits"], np.float64) for s in g["synthetic"]])
    assert np.max(np.abs(model.logits(x) - want)) <= TOL


def test_logits_do_not_depend_on_batch_composition(model):
    from activity_context.recgym.scaler import load_scaler
    g = golden()
    raw = np.stack([np.asarray(r["raw"], np.float64) for r in g["real"]])
    scaled = load_scaler().transform(raw)
    together = model.logits(scaled)
    alone = np.concatenate([model.logits(scaled[i:i + 1]) for i in range(len(scaled))])
    assert np.array_equal(together, alone)
    big = np.concatenate([scaled[[0] * 64], scaled])       # 76 windows: the second batch is padded
    assert np.array_equal(model.logits(big)[64:76], together)


def test_the_runtime_loads_the_pinned_checkpoint_and_reports_what_it_loaded():
    path = weights_path_or_skip()
    from activity_context.recgym.runtime import build_runtime, handle_request
    from activity_context.recgym.weights import CHECKPOINT
    rt = build_runtime(path)
    assert rt.available, rt.error
    ping = handle_request(rt, {"id": "p", "op": "ping"})
    assert ping["model_available"] is True
    assert ping["loaded"]["weights_sha256"] == CHECKPOINT.sha256
    assert all(isinstance(v, str) for v in ping["loaded"].values())
