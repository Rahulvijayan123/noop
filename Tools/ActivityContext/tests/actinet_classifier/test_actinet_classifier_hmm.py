"""Upstream temporal processing: Viterbi + gap restore against goldens from actinet 0.7.2's own ``HMM.predict``."""

import numpy as np
import pytest

from activity_context.actinet_classifier.hmm import HMMParams, after_gap, params_from_doc, smooth, viterbi

from ._helpers import hmm_doc, hmm_params, load_json


def _params(c):
    return HMMParams(labels=np.arange(c["k"]), prior=np.asarray(c["prior"]),
                     emission=np.asarray(c["emission"], np.float32), transition=np.asarray(c["transition"]),
                     uniform_prior=c["uniform_prior"], ignore_transition_gaps=c["ignore_transition_gaps"])


def test_matches_upstream_hmm_predict_exactly():
    doc = load_json("golden_hmm.json")
    # the golden was made where a float32 scalar plus a Python float is float64 (numpy 1.x), as hmm.py assumes
    assert doc["float32_scalar_plus_float"] == "float64"
    assert len(doc["cases"]) >= 17
    for i, c in enumerate(doc["cases"]):
        y, gaps = smooth(np.asarray(c["obs"]), np.asarray(c["t_s"], np.int64) * 1000, _params(c), 30_000)
        assert y.tolist() == c["expected"], f"case {i} (k={c['k']}, n={len(c['obs'])})"
        assert gaps.shape == (len(c["obs"]),)


def test_gap_restore_only_after_a_time_gap():
    p = hmm_params(4)
    obs = np.array([0, 0, 3, 0, 0, 3, 0, 0])
    t = np.array([0, 30, 60, 90, 120, 600, 630, 660]) * 1000
    y, gaps = smooth(obs, t, p, 30_000)
    assert gaps.tolist() == [False, False, False, False, False, True, False, False]
    assert y[5] == obs[5]                                  # restored raw observation after the gap
    assert y.tolist() == viterbi(obs, p).tolist()[:5] + [obs[5]] + viterbi(obs, p).tolist()[6:]
    assert after_gap(np.array([0]), 30).tolist() == [False]


def test_ignore_transition_gaps_flag_skips_the_restore():
    p = hmm_params(4)
    q = HMMParams(labels=p.labels, prior=p.prior, emission=p.emission, transition=p.transition,
                  ignore_transition_gaps=True)
    obs = np.array([1, 1, 2, 1, 1])
    t = np.array([0, 300, 600, 900, 1200]) * 1000
    y, gaps = smooth(obs, t, q, 30_000)
    assert not gaps.any() and y.tolist() == viterbi(obs, q).tolist()


def test_empty_single_and_refusals():
    p = hmm_params(4)
    y, gaps = smooth(np.zeros(0, np.int64), np.zeros(0, np.int64), p, 30_000)
    assert y.shape == (0,) and gaps.shape == (0,)
    assert smooth(np.array([2]), np.array([0]), p, 30_000)[0].tolist() == [2]
    with pytest.raises(ValueError):
        viterbi(np.array([0, 7]), p)                       # not an HMM label
    with pytest.raises(ValueError):
        smooth(np.array([0, 1]), np.array([30, 30]), p, 30)
    with pytest.raises(ValueError):
        HMMParams(labels=np.arange(2), prior=np.ones(2), emission=np.eye(3, dtype=np.float32), transition=np.eye(2))
    with pytest.raises(ValueError):
        HMMParams(labels=np.arange(2), prior=np.ones(2), emission=np.eye(2, dtype=np.float32),
                  transition=-np.eye(2))


def test_params_from_the_converted_document():
    doc = hmm_doc()
    p = params_from_doc(doc["hmm"], tuple(doc["classes"]))
    assert p.emission.dtype == np.float32 and p.transition.dtype == np.float64 and p.n_states == 4
    with pytest.raises(ValueError):
        params_from_doc(doc["hmm"], ("a", "b", "c"))
