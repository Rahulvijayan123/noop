"""Shared builders for the ActiNet classifier tests (torch imported lazily, so the numpy-only tests skip cleanly)."""

import json
import os

import numpy as np
import pytest

from . import synth

PKG = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(PKG, "fixtures", "actinet_classifier")
CLASSES = ("w", "x", "y", "z")          # deliberately not upstream's names: the class order comes from the artifact


def fixture(name):
    return os.path.join(FIXTURES, name)


def load_json(name):
    with open(fixture(name), "r", encoding="utf-8") as f:
        return json.load(f)


def real_artifact_or_skip():
    d = os.environ.get("ACTINET_CLASSIFIER_DIR", "").strip()
    if not d or not os.path.isdir(d):
        pytest.skip("ACTINET_CLASSIFIER_DIR not set (the converted ActiNet artifact is never committed)")
    return d


def hmm_params(k=4, seed=11):
    from activity_context.actinet_classifier.hmm import HMMParams
    p = synth.hmm_cases(k, seed)
    return HMMParams(labels=np.arange(k), prior=p["prior"], emission=p["emission"], transition=p["transition"])


def hmm_doc(classes=CLASSES, seed=11):
    p = synth.hmm_cases(len(classes), seed)
    return {"schema": "nara.actinet.hmm/1", "classes": list(classes), "window_sec": 30,
            "hmm": {"labels": list(range(len(classes))), "prior": p["prior"].tolist(),
                    "emission": p["emission"].astype(np.float64).tolist(), "transition": p["transition"].tolist(),
                    "uniform_prior": True, "ignore_transition_gaps": False, "handle_sleep_transitions": False,
                    "dtypes": {"prior": "float64", "emission": "float32", "transition": "float64"}}}


class FakeClassifier:
    """Deterministic stand-in for the network: logits from per-axis means and spreads (no torch)."""

    def __init__(self, k=4, poison=None):
        self.k = k
        self.calls = 0
        self.rows = 0
        self.poison = poison            # a row index whose logits are NaN

    def logits(self, x):
        x = np.asarray(x, dtype=np.float64)
        self.calls += 1
        self.rows += x.shape[0]
        feats = np.concatenate([x.mean(axis=2), x.std(axis=2)], axis=1)          # [B, 6]
        w = np.linspace(-1.0, 1.0, 6 * self.k).reshape(6, self.k)
        out = (feats @ w * 10.0).astype(np.float32)
        if self.poison is not None and self.poison < out.shape[0]:
            out[self.poison] = np.nan
        return out


def fake_runtime(k=4, **kw):
    from activity_context.actinet_classifier.runtime import build_runtime
    clf = kw.pop("classifier", FakeClassifier(k))
    return build_runtime(classifier=clf, classes=CLASSES[:k] if k <= 4 else tuple(f"c{i}" for i in range(k)),
                         hmm=hmm_params(k), **kw)


def write_fake_artifact(directory, classes=CLASSES, seed=0):
    """A random-init network + synthetic HMM written like ``weights.convert`` writes; returns matching pins."""
    import torch
    from activity_context.actinet_classifier import weights
    from activity_context.actinet_classifier.model import ActiNetNetwork
    torch.manual_seed(seed)
    net = ActiNetNetwork(len(classes))
    os.makedirs(directory, exist_ok=True)
    wpath = os.path.join(directory, weights.WEIGHTS.filename)
    torch.save({k: v.detach().clone().contiguous() for k, v in net.state_dict().items()}, wpath)
    hpath = os.path.join(directory, weights.HMM.filename)
    with open(hpath, "wb") as f:
        f.write(weights.canonical_json(hmm_doc(classes)))
    return pins_for(directory)


def pins_for(directory):
    from activity_context.actinet_classifier import weights
    out = []
    for pf in weights.CONVERTED:
        p = os.path.join(directory, pf.filename)
        out.append(weights.PinnedFile(pf.role, pf.filename, weights.sha256_file(p), os.path.getsize(p)))
    return tuple(out)


def request(runs=None, rid="r1", **extra):
    return {"id": rid, "op": "infer", "runs": runs if runs is not None else synth.wire_runs(), **extra}
