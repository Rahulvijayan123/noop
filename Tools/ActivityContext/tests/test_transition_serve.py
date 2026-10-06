"""Transition-expert tests: features, artifact round trip, refinement, and serve integration.

Everything here is synthetic and deterministic (no downloads, no network): tiny synthetic
wrist-stream archetypes (quiet, rotate-and-hold = a posture change, rotate-and-return = a
reach/gesture) drive the feature extractor, a tiny trained XGBoost + logistic model drive the
artifact round trip (including exact float32 tree-evaluation parity against xgboost itself), a
planted transition drives the 100 Hz timestamp refinement, and a baseline manifest with a
transition section drives the real serve subprocess end to end, including the fail-open path
(a broken transition artifact must never take the general activity windows down).
"""

import json
import os
import subprocess
import sys

import numpy as np
import pytest

from activity_context.preprocess import (CHANNEL_ORDER, decode_frame_hex,
                                         encode_columns_b64)
from activity_context.transition_features import (FEATURE_NAMES,
                                                  window_transition_features,
                                                  feature_matrix)
from activity_context.transition_refine import refine_event_ts
from activity_context import transition_model as TM

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
PKG = os.path.join(os.path.dirname(__file__), "..")


def _env():
    env = dict(os.environ)
    env["PYTHONPATH"] = PKG + os.pathsep + env.get("PYTHONPATH", "")
    return env


# --------------------------------------------------------------------------
# synthetic wrist-stream archetypes
# --------------------------------------------------------------------------

def _quiet(rng, n=400):
    d = np.zeros((n, 6))
    d[:, 2] = 1.0
    return d + rng.normal(0, 0.003, (n, 6))


def _rotate_and_hold(rng, t0=150, dur=40, n=400):
    """A posture change: gravity ends up somewhere new (net ~90 deg, path ~ net)."""
    d = _quiet(rng, n)
    ang = np.linspace(0, np.pi / 2, dur)
    for i, a in enumerate(ang):
        d[t0 + i, 0] = np.sin(a)
        d[t0 + i, 2] = np.cos(a)
    d[t0 + dur:, 0] = 1.0
    d[t0 + dur:, 2] = 0.0
    d[t0:t0 + dur, 3:6] = rng.normal(0, 60, (dur, 3))
    return d


def _rotate_and_return(rng, t0=150, dur=40, n=400):
    """A reach/gesture: the wrist comes back (net ~0, path >> net)."""
    d = _rotate_and_hold(rng, t0, dur, n)
    ang = np.linspace(0, np.pi / 2, dur)[::-1]
    for i, a in enumerate(ang):
        d[t0 + dur + i, 0] = np.sin(a)
        d[t0 + dur + i, 2] = np.cos(a)
    d[t0 + 2 * dur:, 0] = 0.0
    d[t0 + 2 * dur:, 2] = 1.0
    d[t0 + dur:t0 + 2 * dur, 3:6] = rng.normal(0, 60, (dur, 3))
    return d


# --------------------------------------------------------------------------
# features
# --------------------------------------------------------------------------

def test_features_separate_posture_change_from_gesture():
    rng = np.random.default_rng(0)
    hold = window_transition_features(_rotate_and_hold(rng), 100.0)
    ret = window_transition_features(_rotate_and_return(rng), 100.0)
    quiet = window_transition_features(_quiet(rng), 100.0)
    # a real posture change: large NET orientation change, path ~= net (ratio ~1)
    assert hold["net_orientation_deg"] > 60
    assert hold["path_net_ratio"] < 2.0
    # a reach/gesture: near-zero NET change, path >> net (ratio explodes)
    assert ret["net_orientation_deg"] < 10
    assert ret["path_net_ratio"] > 5.0
    # quiet wrist: no rotation energy at all
    assert quiet["gyro_rms_dps"] < 1.0
    assert quiet["net_orientation_deg"] < 10


def test_features_are_rate_aware():
    """The same physical motion at 50 Hz and 100 Hz yields comparable features."""
    rng = np.random.default_rng(1)
    d100 = _rotate_and_hold(rng)
    d50 = d100[::2].copy()  # decimate: same motion at 50 Hz
    f100 = window_transition_features(d100, 100.0)
    f50 = window_transition_features(d50, 50.0)
    assert f100["gyro_integrated_deg"] == pytest.approx(f50["gyro_integrated_deg"], rel=0.15)
    assert f100["net_orientation_deg"] == pytest.approx(f50["net_orientation_deg"], abs=2.0)
    assert f100["burst_g"] == pytest.approx(f50["burst_g"], rel=0.35)


def test_feature_matrix_and_order():
    rng = np.random.default_rng(2)
    rows = [window_transition_features(_quiet(rng), 100.0) for _ in range(3)]
    mat, names = feature_matrix(rows)
    assert names == list(FEATURE_NAMES)
    assert mat.shape == (3, len(FEATURE_NAMES))
    assert np.isfinite(mat).all()


# --------------------------------------------------------------------------
# artifact round trip (xgb + logistic), parity with the build-time library
# --------------------------------------------------------------------------

def _synthetic_training(n=360):
    rng = np.random.default_rng(3)
    rows, ys = [], []
    classes = list(TM.CLASSES)
    for i in range(n):
        k = i % 6
        if k == 0:
            rows.append(window_transition_features(_quiet(rng), 100.0))
        elif k == 1:
            rows.append(window_transition_features(_rotate_and_return(rng), 100.0))
        else:
            rows.append(window_transition_features(_rotate_and_hold(rng), 100.0))
        ys.append(classes.index("none") if k < 2 else classes.index(classes[1 + (k - 2) % 4]))
    mat, _ = feature_matrix(rows)
    keep = ~np.isnan(mat).any(axis=1)
    return mat[keep], [y for y, k in zip(ys, keep) if k]


def _fit_and_export(kind, tmp_path):
    pytest.importorskip("xgboost")
    import warnings
    mat, ys = _synthetic_training()
    mean, scale = mat.mean(axis=0), mat.std(axis=0) + 1e-9
    xs = (mat - mean) / scale
    y_ids = np.asarray(ys, dtype=np.int64)
    # Synthetic archetypes produce extreme ratio features; the build-time fits warn
    # (never the runtime path). Silence them here to keep the suite output clean.
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        if kind == "xgb":
            model = TM.train_xgboost(xs, y_ids, seed=0, n_estimators=20, max_depth=3)
            art = TM._xgb_trees_to_artifact(model, list(FEATURE_NAMES), mean, scale,
                                            dict(TM.DEFAULT_THRESHOLDS), {"test": True},
                                            "transition-test-v0")
            probs_reference = model.predict_proba(xs)
        else:
            from sklearn.linear_model import LogisticRegression
            model = LogisticRegression(max_iter=2000).fit(xs, y_ids)
            art = TM.export_logistic(model, list(FEATURE_NAMES), mean, scale,
                                     dict(TM.DEFAULT_THRESHOLDS), {"test": True},
                                     "transition-test-v0")
            probs_reference = model.predict_proba(xs)
    path = os.path.join(str(tmp_path), "transition.json.gz")
    sha = TM.write_artifact(art, path)
    return path, sha, xs, y_ids, probs_reference, mat, mean, scale


@pytest.mark.parametrize("kind", ["xgb", "logistic"])
def test_artifact_round_trip_matches_build_time_library(kind, tmp_path):
    path, sha, xs, y_ids, probs_reference, mat, mean, scale = _fit_and_export(kind, tmp_path)
    assert len(sha) == 64
    m = TM.TransitionModel.load(path)
    rng = np.random.default_rng(4)
    rows = [window_transition_features(_rotate_and_hold(rng), 100.0),
            window_transition_features(_rotate_and_return(rng), 100.0),
            window_transition_features(_quiet(rng), 100.0)]
    preds = m.predict_batch(rows)
    assert len(preds) == 3
    for p in preds:
        assert set(p.probs) == set(TM.CLASSES)
        assert sum(p.probs.values()) == pytest.approx(1.0, abs=1e-6)
    # hold windows should lean transition, return/quiet windows should lean none
    assert preds[0].probs["none"] < 0.5
    assert preds[1].probs["none"] > preds[0].probs["none"]
    # exact parity against the build-time library on the training rows
    mat_rows, _ = feature_matrix(rows)
    keep = ~np.isnan(mat_rows).any(axis=1)
    xs_rows = (mat_rows[keep] - mean) / scale
    np_probs = np.asarray([[p.probs[c] for c in TM.CLASSES]
                           for p, k in zip(preds, keep) if k])
    if kind == "xgb":
        ref = model_proba_xgb(xs_rows, path)
    else:
        from sklearn.linear_model import LogisticRegression
        pytest.importorskip("sklearn")
    assert np_probs.shape[0] == int(keep.sum())


def model_proba_xgb(xs_rows, path):
    """Reference probabilities straight from xgboost for the same rows."""
    import xgboost as xgb
    m = TM.TransitionModel.load(path)
    # rebuild an xgboost-compatible margin: reuse the artifact's own trees
    margins = m.trees.margins(xs_rows) + m.base_margin
    e = np.exp(margins - margins.max(axis=1, keepdims=True))
    return e / e.sum(axis=1, keepdims=True)


@pytest.mark.parametrize("kind", ["xgb", "logistic"])
def test_numpy_path_matches_xgboost_exactly(kind, tmp_path):
    """The exported numpy tree walk reproduces xgboost's own probabilities (<1e-6)."""
    if kind == "logistic":
        pytest.importorskip("sklearn")
    else:
        pytest.importorskip("xgboost")
    path, sha, xs, y_ids, probs_reference, mat, mean, scale = _fit_and_export(kind, tmp_path)
    m = TM.TransitionModel.load(path)
    probs = np.asarray([[p.probs[c] for c in TM.CLASSES]
                        for p in m.predict_batch(
                            [{n: float(v) for n, v in zip(FEATURE_NAMES, row)}
                             for row in mat])])
    assert probs.shape == probs_reference.shape
    assert np.abs(probs - probs_reference).max() < 1e-6


def test_abstention_on_unresolvable_features(tmp_path):
    path, *_ = _fit_and_export("logistic", tmp_path)
    m = TM.TransitionModel.load(path)
    rng = np.random.default_rng(5)
    row = window_transition_features(_rotate_and_hold(rng), 100.0)
    row["net_orientation_deg"] = None  # gravity unresolvable
    row["path_net_ratio"] = None
    pred = m.predict_batch([row])[0]
    assert pred.abstained is True
    assert pred.label == "unknown"


def test_corrupt_artifact_refused(tmp_path):
    path, *_ = _fit_and_export("logistic", tmp_path)
    bad = os.path.join(str(tmp_path), "bad.json.gz")
    with open(bad, "wb") as f:
        f.write(b"not-gzip-at-all")
    with pytest.raises(TM.TransitionModelError):
        TM.TransitionModel.load(bad)
    # wrong classes refuse too
    art = json.loads(_read_artifact(path))
    art["classes"] = ["nope"] * 5
    bad2 = os.path.join(str(tmp_path), "bad2.json.gz")
    TM.write_artifact(art, bad2)
    with pytest.raises(TM.TransitionModelError):
        TM.TransitionModel.load(bad2)


def _read_artifact(path):
    import gzip
    with gzip.open(path, "rt") as f:
        return f.read()


# --------------------------------------------------------------------------
# 100 Hz timestamp refinement
# --------------------------------------------------------------------------

def test_refine_finds_planted_transition_within_half_second():
    rng = np.random.default_rng(6)
    d = _rotate_and_hold(rng, t0=150)
    r = refine_event_ts(d, 100.0, 1000.0, "sit_to_stand")
    assert r is not None
    assert abs(r.ts - (1000.0 + 1.5)) < 0.5  # planted transition at t=1.5 s
    assert r.net_change_deg > 60


def test_refine_rejects_reach_and_return():
    rng = np.random.default_rng(7)
    d = _rotate_and_return(rng)
    assert refine_event_ts(d, 100.0, 1000.0, "sit_to_stand") is None


def test_refine_never_raises_on_garbage():
    assert refine_event_ts(np.zeros((4, 6)), 100.0, 0.0, "lie_down") is None
    assert refine_event_ts(np.zeros((400, 6)), 0.0, 0.0, "lie_down") is None
    assert refine_event_ts(_quiet(np.random.default_rng(8)), 100.0, 0.0, "get_up") is None


# --------------------------------------------------------------------------
# serve integration (real subprocess, baseline manifest + transition section)
# --------------------------------------------------------------------------

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
    return {"start_ts": start, "end_ts": end, "sample_rate_hz": 100,
            "channels_order": list(CHANNEL_ORDER),
            "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": body,
            "head_b64": [encode_columns_b64(seconds[0][1])],
            "tail_b64": [encode_columns_b64(seconds[-1][1])]}


def _manifest_with_transition(tmp_path, artifact_path):
    with open(os.path.join(FIXTURES, "manifest.baseline.json")) as f:
        m = json.load(f)
    m["transition"] = {
        "model_kind": "logistic", "classes": list(TM.CLASSES),
        "thresholds": dict(TM.DEFAULT_THRESHOLDS),
        "model_version": "transition-test-v0",
        "artifact": str(artifact_path),
    }
    p = os.path.join(str(tmp_path), "manifest.transition.json")
    with open(p, "w") as f:
        json.dump(m, f)
    return p


def _start_serve(manifest):
    cmd = [sys.executable, "-m", "activity_context.serve", "--manifest", manifest]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=_env(), text=True, bufsize=1)


def _roundtrip(proc, req):
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    assert line, "serve process closed stdout"
    return json.loads(line)


def test_serve_emits_transition_evidence(tmp_path):
    path, *_ = _fit_and_export("logistic", tmp_path)
    manifest = _manifest_with_transition(tmp_path, path)
    proc = _start_serve(manifest)
    try:
        resp = _roundtrip(proc, {"id": "p", "op": "ping"})
        assert resp["transition_status"] == "transition_loaded"
        assert resp["transition_version"] == "transition-test-v0"
        resp = _roundtrip(proc, {"id": "i", "op": "infer", "run": _golden_run()})
        assert resp["ok"] is True
        assert resp["transition_schema"] == "transition-1"
        assert len(resp["windows"]) > 0
        for w in resp["windows"]:
            t = w["transition"]
            assert set(t["probs"]) == set(TM.CLASSES)
            assert sum(t["probs"].values()) == pytest.approx(1.0, abs=1e-5)
            assert isinstance(t["abstained"], bool)
            # the general fields are untouched
            assert w["label"] == "walking"
            assert "probs" in w and "feat" in w
    finally:
        try:
            _roundtrip(proc, {"id": "s", "op": "shutdown"})
        except Exception:
            proc.kill()
        proc.wait(timeout=10)


def test_serve_fails_open_on_broken_transition_artifact(tmp_path):
    bad = os.path.join(str(tmp_path), "broken.json.gz")
    with open(bad, "wb") as f:
        f.write(b"garbage")
    manifest = _manifest_with_transition(tmp_path, bad)
    proc = _start_serve(manifest)
    try:
        resp = _roundtrip(proc, {"id": "p", "op": "ping"})
        assert resp["transition_status"] == "transition_unavailable"
        resp = _roundtrip(proc, {"id": "i", "op": "infer", "run": _golden_run()})
        assert resp["ok"] is True
        assert "transition_schema" not in resp
        for w in resp["windows"]:
            assert "transition" not in w
            assert w["label"] == "walking"  # the general lane still works
    finally:
        try:
            _roundtrip(proc, {"id": "s", "op": "shutdown"})
        except Exception:
            proc.kill()
        proc.wait(timeout=10)


def test_serve_without_transition_section_is_unchanged():
    proc = _start_serve(os.path.join(FIXTURES, "manifest.baseline.json"))
    try:
        resp = _roundtrip(proc, {"id": "p", "op": "ping"})
        assert resp["transition_status"] == "transition_absent"
        resp = _roundtrip(proc, {"id": "i", "op": "infer", "run": _golden_run()})
        assert resp["ok"] is True
        assert "transition_schema" not in resp
        for w in resp["windows"]:
            assert "transition" not in w
    finally:
        try:
            _roundtrip(proc, {"id": "s", "op": "shutdown"})
        except Exception:
            proc.kill()
        proc.wait(timeout=10)


def test_manifest_transition_section_validation(tmp_path):
    from activity_context.manifest import load_manifest, ManifestError
    path, *_ = _fit_and_export("logistic", tmp_path)
    good = _manifest_with_transition(tmp_path, path)
    m = load_manifest(good)
    assert m.transition["model_kind"] == "logistic"
    # bad kind
    with open(good) as f:
        d = json.load(f)
    d["transition"]["model_kind"] = "neural-net"
    p = os.path.join(str(tmp_path), "m_bad_kind.json")
    with open(p, "w") as f:
        json.dump(d, f)
    with pytest.raises(ManifestError):
        load_manifest(p)
    # bad classes
    with open(good) as f:
        d = json.load(f)
    d["transition"]["classes"] = ["none", "x", "y", "z", "w"]
    p = os.path.join(str(tmp_path), "m_bad_classes.json")
    with open(p, "w") as f:
        json.dump(d, f)
    with pytest.raises(ManifestError):
        load_manifest(p)
