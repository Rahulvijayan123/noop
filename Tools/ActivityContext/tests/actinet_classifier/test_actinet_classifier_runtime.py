"""Runtime + serve: output-type separation, shadow release, cache identity, request rules, bounds, determinism."""

import copy
import json

import numpy as np
import pytest

from activity_context.actinet_classifier import CONSUMER, RELEASE_MODE, WIRE_SCHEMA, runtime, serve
from activity_context.actinet_classifier.runtime import RequestError, build_runtime, cache_key, handle_request
from activity_context.actinet_classifier.weights import WeightsError

from . import synth
from ._helpers import CLASSES, FakeClassifier, fake_runtime, request


def _infer(rt, req):
    line, stop = serve.handle_line(rt, json.dumps(req), timeout=0)
    return json.loads(line), stop


def test_response_separates_output_types_and_stays_shadow():
    rt = fake_runtime()
    r, _ = _infer(rt, request())
    assert r["ok"] and r["schema"] == WIRE_SCHEMA and r["release_mode"] == RELEASE_MODE == "shadow"
    assert r["consumer"] == CONSUMER and r["classes"] == list(CLASSES) and r["grid"] == "run"
    n = len(r["epochs"])
    probs, label = r["probabilities"], r["label"]
    assert probs["output_type"] == "class_probabilities" and probs["calibrated"] is False
    assert label["output_type"] == "hmm_label" and set(label) == {"output_type", "method", "values", "after_gap"}
    assert set(probs) == {"output_type", "classes", "calibrated", "values"} and probs["classes"] == list(CLASSES)
    assert len(probs["values"]) == len(label["values"]) == len(label["after_gap"]) == n
    for ep, p, lab, gap in zip(r["epochs"], probs["values"], label["values"], label["after_gap"]):
        assert ep["e"] - ep["s"] == 30
        if ep["valid"]:
            assert ep["reason"] is None and len(p) == 4 and abs(sum(p) - 1) < 1e-5 and lab in CLASSES
            assert isinstance(gap, bool)
        else:
            assert ep["reason"] in ("partial_window", "no_data", "nonfinite_output") and p is None and lab is None
    assert r["counts"] == {"epochs": n, "valid": sum(e["valid"] for e in r["epochs"]),
                           "invalid": {"partial_window": 2}}
    assert [e["s"] - synth.T0 for e in r["epochs"] if e["valid"]][:4] == [0, 30, 180, 210]


def test_one_hmm_pass_spans_the_request_and_restores_after_gaps():
    r, _ = _infer(fake_runtime(), request())
    valid = [(e["s"], g) for e, g in zip(r["epochs"], r["label"]["after_gap"]) if e["valid"]]
    gaps = [g for _, g in valid]
    starts = [s for s, _ in valid]
    assert gaps[0] is False
    assert gaps[1:] == [b - a != 30 for a, b in zip(starts, starts[1:])]


def test_cache_identity_covers_input_artifact_and_preprocessing():
    rt = fake_runtime()
    a, _ = _infer(rt, request())
    b, _ = _infer(rt, request(rid="other"))
    assert a["cache_key"] == b["cache_key"] == cache_key(a["input_digest"], a["artifact"]["digest"],
                                                         a["preprocessing_digest"])
    runs = synth.wire_runs()
    cols = synth.columns(synth.spec_runs()[0]["counts"])
    cols[3] = cols[3].copy()
    cols[3][0] += 1                                          # one sample, one count
    runs[0]["columns_b64"][3] = synth.b64(cols[3])
    c, _ = _infer(rt, request(runs))
    assert c["input_digest"] != a["input_digest"] and c["cache_key"] != a["cache_key"]
    other_batch = fake_runtime(max_batch=32)
    d, _ = _infer(other_batch, request())
    assert d["input_digest"] == a["input_digest"] and d["preprocessing_digest"] != a["preprocessing_digest"]
    from activity_context.actinet_classifier.weights import CONVERTED, PinnedFile
    pins = (CONVERTED[0], PinnedFile("hmm", CONVERTED[1].filename, "cd" * 32, 10))
    e, _ = _infer(fake_runtime(pins=pins), request())
    assert e["artifact"]["digest"] != a["artifact"]["digest"] and e["cache_key"] != a["cache_key"]


def test_context_seconds_are_validated_but_unused():
    rt = fake_runtime()
    base, _ = _infer(rt, request())
    runs = synth.wire_runs()
    extra = synth.columns(synth.counts(3, "run", 9))
    runs[2]["head_b64"] = [synth.b64(c) for c in extra]
    runs[2]["tail_b64"] = [synth.b64(c) for c in extra[:2]]
    ctx, _ = _infer(rt, request(runs))
    assert ctx["epochs"] == base["epochs"] and ctx["probabilities"] == base["probabilities"]
    assert ctx["input_digest"] == base["input_digest"]
    runs[2]["head_b64"] = ["!!notbase64!!"]
    bad, _ = _infer(rt, request(runs))
    assert not bad["ok"] and bad["kind"] == "malformed"


def test_adjacent_runs_join_like_one_recording():
    rt = fake_runtime()
    one = synth.wire_runs(((0, 120, "walk", 3),))
    split = copy.deepcopy(one)
    a = dict(split[0], end_ts=split[0]["start_ts"] + 50, columns_b64=split[0]["columns_b64"][:50])
    b = dict(split[0], start_ts=split[0]["start_ts"] + 50, columns_b64=split[0]["columns_b64"][50:])
    r1, _ = _infer(rt, request(one))
    r2, _ = _infer(rt, request([a, b]))
    assert r1["epochs"] == r2["epochs"] and r1["probabilities"] == r2["probabilities"]
    assert r1["label"] == r2["label"]


def test_request_rules():
    rt = fake_runtime()
    runs = synth.wire_runs()
    cases = {
        "no runs": {"id": "x", "op": "infer"},
        "overlap": request([runs[1], runs[0]]),
        "count": request([dict(runs[0], end_ts=runs[0]["end_ts"] + 1)]),
        "rate": request([dict(runs[0], sample_rate_hz=50)]),
        "units": request([dict(runs[0], units={"accel": "m/s^2", "gyro": "deg/s"})]),
        "channels": request([dict(runs[0], channels_order=["ax", "ay", "az"])]),
        "bool ts": request([dict(runs[0], start_ts=True)]),
    }
    for name, req in cases.items():
        r, _ = _infer(rt, req)
        assert not r["ok"] and r["kind"] == "malformed", name
    r, _ = _infer(rt, {"id": "x", "op": "infer", "run": runs[2]})       # the HART-identical single run
    assert r["ok"] and r["counts"]["valid"] == 11
    r, _ = _infer(rt, {"id": "x", "op": "train"})
    assert r["kind"] == "malformed"
    line, _ = serve.handle_line(rt, "{not json")
    assert json.loads(line)["kind"] == "malformed"


def test_bounds_refuse_rather_than_truncate():
    r, _ = _infer(fake_runtime(max_epochs=10), request())
    assert not r["ok"] and r["kind"] == "too_many_epochs"
    rt = fake_runtime()
    rt.max_output_bytes = 2000
    r, _ = _infer(rt, request())
    assert not r["ok"] and r["kind"] == "output_too_large"
    ping, _ = _infer(fake_runtime(), {"id": "p", "op": "ping"})
    assert ping["bounds"] == {"threads": 1, "max_batch": 64, "max_epochs": 2880, "max_runs": 4000,
                              "max_output_bytes": 12 * 1024 * 1024}


def test_nonfinite_network_output_is_an_invalid_epoch_not_a_label():
    rt = fake_runtime(classifier=FakeClassifier(4, poison=1))
    r, _ = _infer(rt, request())
    bad = [e for e in r["epochs"] if e["reason"] == "nonfinite_output"]
    assert len(bad) == 1 and r["counts"]["invalid"]["nonfinite_output"] == 1
    i = r["epochs"].index(bad[0])
    assert r["probabilities"]["values"][i] is None and r["label"]["values"][i] is None


def test_unavailable_runtime_keeps_answering(tmp_path, monkeypatch):
    monkeypatch.delenv("ACTINET_CLASSIFIER_DIR", raising=False)
    rt = build_runtime(None)
    assert not rt.available and rt.error.kind == "model_missing" and rt.status == "actinet_unavailable"
    ping, _ = _infer(rt, {"id": "p", "op": "ping"})
    assert ping["ok"] and ping["model_available"] is False and ping["release_mode"] == "shadow"
    r, _ = _infer(rt, request())
    assert not r["ok"] and r["kind"] == "model_missing"
    rt = build_runtime(str(tmp_path))
    assert rt.error.kind == "model_missing"
    with pytest.raises(RequestError):
        handle_request(rt, request())
    bye, stop = _infer(rt, {"id": "s", "op": "shutdown"})
    assert bye["ok"] and stop


def test_injected_parts_are_required_together():
    rt = build_runtime(classifier=FakeClassifier(4))
    assert not rt.available and isinstance(rt.error, WeightsError)


def test_network_is_deterministic_and_batch_independent():
    torch = pytest.importorskip("torch")
    from activity_context.actinet_classifier.model import ActiNetClassifier, ActiNetNetwork
    torch.manual_seed(0)
    net = ActiNetNetwork(4).eval()
    clf = ActiNetClassifier(net, 4, threads=1, max_batch=4)
    assert torch.get_num_threads() == 1
    x = (np.stack([synth.counts(30, k, i)[:900] for i, k in enumerate(synth.KINDS)], 0) / 4096.0).astype(np.float32)
    x = np.ascontiguousarray(np.transpose(x, (0, 2, 1)))
    full = clf.logits(x)
    assert full.shape == (6, 4) and full.dtype == np.float32
    np.testing.assert_array_equal(clf.logits(x), full)                 # repeatable
    for i in range(6):
        np.testing.assert_array_equal(clf.logits(x[i:i + 1])[0], full[i])   # alone == in a batch
    np.testing.assert_array_equal(clf.logits(x[::-1])[::-1], full)      # order-free
    with pytest.raises(ValueError):
        clf.logits(x.astype(np.float64))
    with pytest.raises(ValueError):
        clf.logits(np.full_like(x, np.nan))
    assert clf.logits(np.zeros((0, 3, 900), np.float32)).shape == (0, 4)


def test_softmax_is_float64_and_row_normalised():
    from activity_context.actinet_classifier.model import softmax
    p = softmax(np.array([[1000.0, 0.0, -1000.0, 1.0], [0.1, 0.2, 0.3, 0.4]], np.float32))
    assert p.dtype == np.float64 and np.allclose(p.sum(axis=1), 1.0) and np.isfinite(p).all()


def test_wire_classes_follow_the_runtime_not_a_constant():
    rt = runtime.build_runtime(classifier=FakeClassifier(4), classes=("q", "r", "s", "t"),
                               hmm=fake_runtime().hmm)
    r, _ = _infer(rt, request())
    assert r["classes"] == ["q", "r", "s", "t"] and set(v for v in r["label"]["values"] if v) <= {"q", "r", "s", "t"}
