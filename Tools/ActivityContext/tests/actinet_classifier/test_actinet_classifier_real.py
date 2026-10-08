"""End-to-end parity with upstream (real converted artifact; skipped unless ACTINET_CLASSIFIER_DIR is set).

``fixtures/actinet_classifier/golden_e2e.json`` holds upstream actinet 0.7.2's outputs for the synthetic six-run
request (``synth.E2E_SPEC``): logits (``sslmodel.predict``), softmax (scipy, as upstream's HMM fit uses), the raw
argmax and the HMM labels (``ActivityClassifier.predict``). The run is upstream's default path, actipy calibration
and non-wear included (both no-ops here: CalibOK 0, no non-wear). There are two layouts:
- ``file``: the whole request as one recording, one grid from the first sample (the adapter's ``request`` grid);
- ``per_run``: each run as its own recording, one HMM over the concatenation (the served ``run`` grid).
Upstream ran with batch 512 and NNPACK at its default; Nara runs padded batches of 64 with NNPACK off, so logits
agree to ~3e-5, not bit for bit.
"""

import json

import numpy as np
import pytest

from activity_context.actinet_classifier import preprocess as P
from activity_context.actinet_classifier import runtime, serve
from activity_context.actinet_classifier.weights import DEPLOYMENT_ARTIFACT_DIGEST, read_artifact

from . import synth
from ._helpers import load_json, real_artifact_or_skip, request

PROB_TOL = 1e-4
LOGIT_TOL = 2e-3


@pytest.fixture(scope="module")
def rt():
    d = real_artifact_or_skip()
    r = runtime.build_runtime(d)
    assert r.available, r.error
    return r


def _runs():
    seconds = []
    for r in synth.spec_runs():
        seconds += [(r["start_ts"] + i, c) for i, c in enumerate(synth.columns(r["counts"]))]
    return P.runs_from_seconds(seconds)


def test_real_artifact_is_the_pinned_walmsley_classifier(rt):
    _, classes, hmm_block, _ = read_artifact(real_artifact_or_skip())
    gold = load_json("golden_e2e.json")
    assert list(classes) == gold["classes"] == list(rt.classes)
    assert rt.artifact_digest == DEPLOYMENT_ARTIFACT_DIGEST
    assert hmm_block["uniform_prior"] is True and hmm_block["ignore_transition_gaps"] is False


def test_request_grid_matches_upstream_on_the_whole_recording(rt):
    gold = load_json("golden_e2e.json")
    assert gold["actipy_info"]["CalibOK"] == 0 and gold["actipy_info"]["NonwearTime(days)"] == 0.0
    f = gold["file"]
    res = runtime.classify_runs(rt, _runs(), float(synth.T0), float(synth.spec_runs()[-1]["end_ts"]), "request")
    up_valid = [s for s, v in zip(f["starts_s"], f["valid"]) if v]
    tail = {f["starts_s"][i] for i in f["wrap_padded_tail"]}
    assert tail == {1410}                                   # upstream wrap-pads the last 20 s (deviation D3)
    keep = [i for i, s in enumerate(up_valid) if s not in tail]
    mine = [int(res.epochs[i].s - synth.T0) for i in res.index]
    assert mine == [up_valid[i] for i in keep]
    np.testing.assert_allclose(res.logits, np.asarray(f["logits"])[keep], atol=LOGIT_TOL, rtol=0)
    np.testing.assert_allclose(res.probabilities, np.asarray(f["probabilities"])[keep], atol=PROB_TOL, rtol=0)
    assert res.raw.tolist() == np.asarray(f["raw"])[keep].tolist()
    assert res.label.tolist() == f["hmm_without_tail"]
    # here the extra wrap-padded epoch changes no earlier HMM label either
    assert res.label.tolist() == np.asarray(f["hmm"])[keep].tolist()


def test_served_run_grid_matches_upstream_per_run(rt):
    gold = load_json("golden_e2e.json")["per_run"]
    line, _ = serve.handle_line(rt, json.dumps(request()), timeout=120)
    r = json.loads(line)
    assert r["ok"] and r["release_mode"] == "shadow"
    valid = [i for i, e in enumerate(r["epochs"]) if e["valid"]]
    assert [r["epochs"][i]["s"] - synth.T0 for i in valid] == gold["starts_s"]
    probs = np.asarray([r["probabilities"]["values"][i] for i in valid])
    np.testing.assert_allclose(probs, np.asarray(gold["probabilities"]), atol=PROB_TOL, rtol=0)
    labels = [r["classes"].index(r["label"]["values"][i]) for i in valid]
    assert labels == gold["hmm"]
    raw = probs.argmax(axis=1).tolist()
    assert raw == gold["raw"]
