"""Unit tests for the session-aware transition evaluator (spec s12 / audit A03).

Covers the exact failures WS-07 documented:
  * F01 concatenated constant sessions must report ZERO transitions,
  * F02 undetected transitions must be counted as misses and censored at the
     session end (never scanned into a later session, never silently omitted),
  * F03 fabricated i*HOP_SECONDS timestamps replaced by real starts when
     present, with a clear fabricated flag on legacy artifacts,
  * F11 abstention never votes in the policy mirror,
  * WS-07-F12 (evaluator had no tests at all).
Also replays the committed Swift/Python shared fixture
(tests/fixtures/policy_replay_fixture.json) through the Python evaluator so the
transition offsets agree with what ActivityContextPolicy.buildEpochs emits.
"""

import json
import os

import numpy as np
import pytest

from activity_context.evaluate import (_transition_delay, smooth_predictions,
                                       evaluate)

FIXTURE = os.path.join(os.path.dirname(__file__), "..", "fixtures",
                       "policy_replay_fixture.json")

MOTION = ["stationary", "walking", "running", "other_movement"]


def _fixture():
    """Decode the shared replay fixture -> (truth, labels, starts, sessions).

    Sessions are reconstructed the same way train.py defines them: a new
    session whenever a window starts more than gapResetSeconds after the
    previous window's start (within the fixture the 2-s hop never triggers it,
    only the real inter-session pauses do).
    """
    with open(FIXTURE, encoding="utf-8") as f:
        fx = json.load(f)
    truth, labels, starts, sessions = [], [], [], []
    sess = 0
    prev_s = None
    gap = fx["config"]["gapResetSeconds"]
    for w in fx["windows"]:
        if prev_s is not None and w["s"] - prev_s > gap:
            sess += 1
        truth.append(w["truth"])
        labels.append(w["label"])
        starts.append(w["s"])
        sessions.append(sess)
        prev_s = w["s"]
    return (np.asarray(truth), labels, np.asarray(starts, dtype=float),
            np.asarray(sessions, dtype=np.int64))


# ---------------------------------------------------------------------------
# WS-07-F01: concatenated constant sessions are not transitions
# ---------------------------------------------------------------------------

def test_concatenated_constant_sessions_zero_transitions():
    # Three internally-constant sessions, perfect classifier: the old code
    # reported 2 "transitions" (one at each block boundary); none occurred
    # within a session, so the correct count is ZERO.
    y = np.array(["stationary"] * 10 + ["walking"] * 10 + ["stationary"] * 10)
    preds = list(y)
    sessions = np.array([0] * 10 + [1] * 10 + [2] * 10)
    starts = np.arange(30, dtype=float) * 2.0

    raw = _transition_delay(y, preds, sessions=sessions, starts=starts)
    assert raw["n_transitions"] == 0
    assert raw["n_detected"] == 0 and raw["n_misses"] == 0
    assert raw["n_censored"] == 0 and raw["delay_s"] is None

    policy = _transition_delay(y, preds, smooth_predictions(preds, sessions=sessions,
                                                            starts=starts),
                               sessions=sessions, starts=starts)
    assert policy["n_transitions"] == 0


def test_concatenated_constant_sessions_zero_without_sessions_still_flagged():
    # Even without explicit sessions (legacy caller) the metric keeps the old
    # single-session semantics but marks timestamps fabricated; the sessions
    # passed from evaluate() are what fix the block-boundary artifact.
    y = np.array(["stationary"] * 5 + ["walking"] * 5)
    preds = list(y)
    r = _transition_delay(y, preds)
    assert r["timestamps"] == "fabricated"
    assert r["n_transitions"] == 1  # one series, one real (single-session) change


# ---------------------------------------------------------------------------
# WS-07-F02: misses/censoring, no cross-session scanning
# ---------------------------------------------------------------------------

def test_undetected_transition_is_miss_and_censored():
    y = np.array(["stationary"] * 6 + ["running"] * 6)
    preds = ["stationary"] * 12          # target never predicted
    sessions = np.zeros(12, dtype=int)
    starts = np.arange(12, dtype=float) * 2.0
    r = _transition_delay(y, preds, sessions=sessions, starts=starts)
    assert r["n_transitions"] == 1
    assert r["n_detected"] == 0
    assert r["n_misses"] == 1 and r["n_censored"] == 1
    assert r["delay_s"] is None
    # Censoring horizon = end of the session's last window minus transition start.
    assert r["censoring_horizon_s"]["n"] == 1
    assert r["censoring_horizon_s"]["mean_s"] == pytest.approx(
        starts[-1] + 4.0 - starts[6], abs=1e-6)


def test_never_scans_into_later_session():
    # Truth changes inside session 0; the target is only predicted in session 1.
    # The transition must be a miss censored at session 0's end — the old code
    # scanned across the boundary and reported a huge (fake) delay.
    y = np.array(["stationary"] * 4 + ["running"] * 4)
    preds = ["stationary"] * 4 + ["walking"] * 4
    sessions = np.array([0] * 5 + [1] * 3)
    starts = np.arange(8, dtype=float) * 2.0
    r = _transition_delay(y, preds, sessions=sessions, starts=starts)
    assert r["n_transitions"] == 1 and r["n_detected"] == 0
    assert r["n_misses"] == 1 and r["n_censored"] == 1
    assert r["delay_s"] is None
    # Session 0's last window is index 4; horizon = starts[4] + 4 - starts[4].
    assert r["censoring_horizon_s"]["mean_s"] == pytest.approx(4.0, abs=1e-6)


# ---------------------------------------------------------------------------
# WS-07-F03: real timestamps vs fabricated spacing
# ---------------------------------------------------------------------------

def test_detected_transition_uses_real_starts():
    y = np.array(["stationary"] * 5 + ["walking"] * 3)
    preds = ["stationary"] * 6 + ["walking"] * 2   # one window late
    sessions = np.zeros(8, dtype=int)
    # Irregular real spacing (a 3-s hop here) must drive the latency, not i*HOP.
    # Truth changes at window 5 (start 112); the first correct prediction is
    # window 6 (start 115) -> delay 3 s, not a fabricated 2 s.
    starts = np.array([100.0, 102.0, 104.0, 106.0, 109.0, 112.0, 115.0, 118.0])
    r = _transition_delay(y, preds, sessions=sessions, starts=starts)
    assert r["timestamps"] == "real"
    assert r["n_transitions"] == 1 and r["n_detected"] == 1
    assert r["delay_s"]["mean_s"] == pytest.approx(3.0, abs=1e-6)  # 115 - 112
    assert r["onset_error_s"]["mean_s"] == pytest.approx(3.0, abs=1e-6)


def test_legacy_fabricated_flag_without_starts():
    y = np.array(["stationary"] * 4 + ["walking"] * 4)
    preds = list(y)
    sessions = np.zeros(8, dtype=int)
    r = _transition_delay(y, preds, sessions=sessions)   # no starts
    assert r["timestamps"] == "fabricated"
    assert r["delay_s"]["mean_s"] == 0.0


# ---------------------------------------------------------------------------
# Signed onset error
# ---------------------------------------------------------------------------

def test_signed_onset_error_negative_when_early():
    # Classifier flips to walking two windows BEFORE the truth change.
    y = np.array(["stationary"] * 4 + ["walking"] * 6)
    preds = ["stationary"] * 2 + ["walking"] * 8
    sessions = np.zeros(10, dtype=int)
    starts = np.arange(10, dtype=float) * 2.0
    r = _transition_delay(y, preds, sessions=sessions, starts=starts)
    assert r["n_transitions"] == 1 and r["n_detected"] == 1
    assert r["delay_s"]["mean_s"] == 0.0          # match at the truth-change window
    assert r["onset_error_s"]["mean_s"] == pytest.approx(-4.0, abs=1e-6)


# ---------------------------------------------------------------------------
# Policy mirror (smooth_predictions)
# ---------------------------------------------------------------------------

def test_policy_mirror_hysteresis_lag():
    y = np.array(["stationary"] * 6 + ["walking"] * 6 + ["stationary"] * 6)
    preds = list(y)
    sessions = np.zeros(18, dtype=int)
    starts = np.arange(18, dtype=float) * 2.0
    sm = smooth_predictions(preds, sessions=sessions, starts=starts)
    r = _transition_delay(y, preds, sm, sessions=sessions, starts=starts)
    assert r["n_transitions"] == 2 and r["n_detected"] == 2
    # One 2-s hop of hysteresis lag on each flip.
    assert r["delay_s"]["mean_s"] == pytest.approx(2.0, abs=1e-6)
    assert r["onset_error_s"]["mean_s"] == pytest.approx(2.0, abs=1e-6)


def test_smooth_predictions_uses_real_starts_for_gap_reset():
    # A real 6-s start gap (no session change) must reset history: a single
    # disagreeing window after the gap flips immediately (cur reset), while the
    # same series WITHOUT the gap needs required_votes disagreeing windows.
    preds = ["walking"] * 4 + ["running"] + ["running"] * 4
    sessions = np.zeros(9, dtype=int)
    gapped = np.array([0.0, 2.0, 4.0, 6.0, 12.0, 14.0, 16.0, 18.0, 20.0])
    nongapped = np.arange(9, dtype=float) * 2.0
    sm_gap = smooth_predictions(preds, sessions=sessions, starts=gapped)
    sm_nogap = smooth_predictions(preds, sessions=sessions, starts=nongapped)
    assert sm_gap[4] == "running"          # history reset -> immediate flip
    assert sm_nogap[4] == "walking"        # needs a second disagreeing window


def test_smooth_predictions_abstention_never_votes():
    preds = ["walking", "walking", "unknown", "walking", "walking", "running"]
    sm = smooth_predictions(preds)
    # The abstaining window carries the current label but does NOT vote.
    assert sm[:3] == ["walking", "walking", "walking"]
    # The single disagreeing 'running' window (after abstentions that did not
    # vote) is not enough to flip.
    assert sm[-1] == "walking"


# ---------------------------------------------------------------------------
# Shared Swift/Python replay fixture (spec A04)
# ---------------------------------------------------------------------------

def test_fixture_exists_and_is_valid():
    assert os.path.isfile(FIXTURE)
    with open(FIXTURE, encoding="utf-8") as f:
        fx = json.load(f)
    assert fx["meta"]["n_windows"] == len(fx["windows"])
    assert len(fx["expect"]["transitions"]) == 2


def test_fixture_replay_transition_offsets_match_swift_expectations():
    truth, labels, starts, sessions = _fixture()
    r = _transition_delay(truth, labels, sessions=sessions, starts=starts)
    assert r["timestamps"] == "real"
    assert r["n_transitions"] == 2 and r["n_detected"] == 2
    assert r["n_misses"] == 0 and r["n_censored"] == 0
    # Perfect classifier: zero latency, zero onset error.
    assert r["delay_s"]["mean_s"] == 0.0
    assert r["onset_error_s"]["mean_s"] == 0.0

    # Policy mirror: hysteresis adds one 2-s hop per flip; the detected
    # transition offsets must equal the Swift ActivityContextPolicy offsets.
    sm = smooth_predictions(labels, sessions=sessions, starts=starts)
    rp = _transition_delay(truth, labels, sm, sessions=sessions, starts=starts)
    assert rp["n_transitions"] == 2 and rp["n_detected"] == 2
    assert rp["delay_s"]["mean_s"] == pytest.approx(2.0, abs=1e-6)

    # Reconstruct the mirror's flip offsets (first disagreeing window) from the
    # smoothed series and compare with the fixture's expected transitions.
    with open(FIXTURE, encoding="utf-8") as f:
        fx = json.load(f)
    expected = sorted((t["from"], t["to"], t["offset"]) for t in
                      fx["expect"]["transitions"])
    flips = []
    for i in range(1, len(sm)):
        if sm[i] != sm[i - 1] and sessions[i] == sessions[i - 1]:
            # Within one session, a smoothed-label change is a hysteresis flip.
            # The smoothed series shows the OLD label on the first disagreeing
            # window, so the flip offset is that window's start (starts[i-1]).
            flips.append((sm[i - 1], sm[i], int(starts[i - 1])))
    assert flips == expected


# ---------------------------------------------------------------------------
# WS-07-F12: evaluate() report shape
# ---------------------------------------------------------------------------

def test_evaluate_report_has_session_aware_transition_keys():
    y = np.array(["stationary"] * 5 + ["walking"] * 5)
    preds = list(y)
    sessions = np.array([0] * 5 + [1] * 5)
    starts = np.arange(10, dtype=float) * 2.0

    def predictor(_w):
        return "walking", {"walking": 0.95, "stationary": 0.05}

    report = evaluate(np.zeros((10, 120, 6)), y, predictor,
                      {"max_prob": 0.8, "margin": 0.15},
                      sessions=sessions, starts=starts)
    for key in ("transition_delay_s", "transition_delay_policy_s"):
        d = report[key]
        assert set(d) >= {"n_transitions", "n_detected", "n_misses",
                          "n_censored", "delay_s", "onset_error_s",
                          "censoring_horizon_s", "timestamps"}
        # Session boundary is not a transition: zero here.
        assert d["n_transitions"] == 0


def test_evaluate_legacy_without_timestamps_is_fabricated():
    y = np.array(["stationary"] * 4 + ["walking"] * 4)
    sessions = np.zeros(8, dtype=int)

    def predictor(_w):
        return "walking", {"walking": 0.95, "stationary": 0.05}

    report = evaluate(np.zeros((8, 120, 6)), y, predictor,
                      {"max_prob": 0.8, "margin": 0.15}, sessions=sessions)
    assert report["transition_delay_s"]["timestamps"] == "fabricated"
