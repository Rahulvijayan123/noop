"""Shadow personalization tests (spec 15.3, contracts 7).

Covers: evidence gates (insufficient_evidence path), full determinism,
session-held-out discipline (the personalizer is fitted only on train
sessions), per-user grouping, and the generic-vs-personalized delta on
held-out sessions. All fixtures synthetic, deterministic, numpy-only.
"""

import json

import numpy as np

from activity_context import labels as L
from activity_context.personalize import (
    MIN_SESSIONS_PER_CLASS,
    MIN_WINDOWS_PER_CLASS,
    build_user_groups,
    evaluate_user,
    fit_personalizer,
    run_personalization,
)


# ---------------------------------------------------------------------------
# Synthetic fixture: separable imu-feat-1 features + a day doc
# ---------------------------------------------------------------------------

WALK_FEAT = {
    "accel_rms_g": 0.14, "gyro_rms_dps": 60.0, "jerk_rms_gps": 6.0,
    "cadence_hz": 1.9, "cadence_strength": 0.7, "orientation_change_deg": 6.0,
}
STILL_FEAT = {
    "accel_rms_g": 0.009, "gyro_rms_dps": 3.0, "jerk_rms_gps": 0.9,
    "cadence_hz": None, "cadence_strength": 0.1, "orientation_change_deg": 0.5,
}


def sq(expected):
    return {"expected_seconds": expected, "covered_seconds": expected,
            "sample_rate_hz": 100, "first_ts": None, "last_ts": None,
            "gaps": [], "coverage_ratio": 1.0, "evaluation_ready": True}


def wire(key, session, s, e, locomotion, user_id=None):
    return {
        "id": key, "label_key": f"guided:{session}:{s}", "source": "guided",
        "session_id": session, "start_ts": s, "end_ts": e,
        "locomotion": locomotion, "user_unsure": False,
        "sensor_quality": sq(e - s), "user_id": user_id,
    }


def scaled_feature_row(feat):
    """imu-feat-1 row as the hart-windows-1 doc stores it (scaled ints)."""
    out = []
    for key, scale in zip(L.FEATURE_KEYS, L.FEATURE_SCALE):
        v = feat.get(key)
        out.append(None if v is None else int(round(v * scale)))
    return out


def build_doc(sessions, *, stationary_pred="walking"):
    """Day doc for a list of sessions: each session = [(start, end, truth), ...].
    ``stationary_pred`` controls what the window encoder predicts for
    stationary-truth windows (generic head confusion)."""
    vocab = ["stationary", "walking", "running", "other_movement", "unknown"]
    s, e, l, b, p, f = [], [], [], [], [], []
    t0 = min(st for sess in sessions for (st, en, _t) in sess)
    for (st, en, truth) in [x for sess in sessions for x in sess]:
        # 4 s windows, 2 s hop, fully inside the label interval.
        for wstart in range(st, en - 4, 2):
            plabel = truth if truth == "walking" else stationary_pred
            s.append(wstart - t0)
            e.append(wstart + 4 - t0)
            l.append(vocab.index(plabel))
            b.append(0)
            row = [0] * len(vocab)
            row[vocab.index(plabel)] = 1000
            p.append(row)
            feat = WALK_FEAT if truth == "walking" else STILL_FEAT
            f.append(scaled_feature_row(feat))
    return {
        "format": "hart-windows-1", "t0": t0, "labels": vocab,
        "features": list(L.FEATURE_KEYS), "feature_scale": list(L.FEATURE_SCALE),
        "s": s, "e": e, "l": l, "p": p, "b": b, "f": f,
    }


def gated_fixture(user_id=None):
    """4 sessions: 3 fit sessions (walking + stationary, >= 30 windows each
    per class, >= 3 sessions) + 1 latest held-out session. Generic head
    confuses stationary for walking."""
    sessions = []
    labels = []
    t = 0
    for i in range(3):                      # fit sessions
        sessions.append([(t, t + 64, "walking"), (t + 68, t + 132, "stationary")])
        labels.append(wire(f"w{i}", f"s{i}", t, t + 64, "walking", user_id))
        labels.append(wire(f"st{i}", f"s{i}", t + 68, t + 132, "stationary", user_id))
        t += 1000
    # held-out session (latest by earliest start)
    sessions.append([(t, t + 30, "walking"), (t + 34, t + 60, "stationary")])
    labels.append(wire("w3", "s3", t, t + 30, "walking", user_id))
    labels.append(wire("st3", "s3", t + 34, t + 60, "stationary", user_id))
    return records_of(labels), build_doc(sessions)


def records_of(wires):
    return [L._label_from_wire(x) for x in wires]


# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

def test_insufficient_evidence_insufficient_sessions():
    """Fewer than 2 sessions -> refuse with a reason."""
    labels = records_of([
        wire("a", "s1", 0, 40, "walking"), wire("b", "s1", 44, 84, "stationary"),
    ])
    doc = build_doc([[(0, 40, "walking"), (44, 84, "stationary")]])
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    u = report["users"]["all"]
    assert u["status"] == "insufficient_evidence"
    assert "sessions" in u.get("reason", "")
    assert "personalized" not in u or u.get("personalized") is None


def test_insufficient_evidence_class_gates():
    """3 sessions but one class appears only once -> that class fails."""
    labels = records_of([
        # walking in all 3 sessions, running only in session 0
        wire("w0", "s0", 0, 40, "walking"), wire("w1", "s1", 1000, 1040, "walking"),
        wire("w2", "s2", 2000, 2040, "walking"),
        wire("r0", "s0", 60, 90, "running"),
    ])
    doc = build_doc([
        [(0, 40, "walking"), (60, 90, "running")],
        [(1000, 1040, "walking")],
        [(2000, 2040, "walking")],
    ])
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    u = report["users"]["all"]
    assert u["status"] == "insufficient_evidence"
    assert "running" in u["failed_classes"]
    # walking may pass the gates but the run refuses as a whole (listed too
    # when it fails; the failing class is what matters).
    assert u["personalized"] is None


def test_gates_met_reported():
    labels, doc = gated_fixture()
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    u = report["users"]["all"]
    assert u["status"] == "fit"
    gates = u["gates"]
    for c in ("walking", "stationary"):
        g = gates[c]
        assert g["met"]
        assert g["n_fit_windows"] >= MIN_WINDOWS_PER_CLASS
        assert g["n_fit_sessions"] >= MIN_SESSIONS_PER_CLASS


# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

def test_determinism_two_runs_identical():
    labels, doc = gated_fixture()
    wins, _ = L.parse_day_doc(doc, "day.json")
    r1 = run_personalization(labels, wins)
    r2 = run_personalization(labels, wins)
    assert json.dumps(r1, sort_keys=True) == json.dumps(r2, sort_keys=True)


def test_fit_personalizer_deterministic():
    labels, doc = gated_fixture()
    wins, _ = L.parse_day_doc(doc, "day.json")
    units, _ = L.assign_units(labels, wins, model="hart")
    loc = [u for u in units if u.head == "locomotion"]
    split = L.split_by_session(labels, loc, holdout_sessions=1)
    p1 = fit_personalizer("all", split.train_units)
    p2 = fit_personalizer("all", split.train_units)
    assert np.array_equal(p1.weights, p2.weights)
    assert p1.temperature == p2.temperature
    assert p1.abstain_threshold == p2.abstain_threshold


# ---------------------------------------------------------------------------
# Session-held-out: the personalizer only ever saw train sessions
# ---------------------------------------------------------------------------

def test_session_held_out_fit_and_eval_disjoint():
    labels, doc = gated_fixture()
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    u = report["users"]["all"]
    train = set(u["split"]["train_sessions"])
    test = set(u["split"]["test_sessions"])
    assert train and test
    assert not (train & test)
    assert u["split"]["holdout_sessions"] == 1
    # The latest session is held out.
    assert test == {"s3"}


def test_personalized_beats_confused_generic_on_heldout():
    """Generic confuses stationary for walking; the probe separates them on
    the held-out session (features are separable)."""
    labels, doc = gated_fixture()
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    u = report["users"]["all"]
    assert u["status"] == "fit"
    # Generic: stationary F1 = 0 (all confused), walking F1 ~ 0.7 (its
    # precision is diluted by the 11 stationary FPs).
    assert u["generic"]["per_class"]["stationary"]["f1"] < 0.1
    assert u["generic"]["per_class"]["walking"]["f1"] > 0.5
    # Personalized: both classes high on the never-seen session.
    assert u["personalized"]["per_class"]["stationary"]["f1"] > 0.9
    assert u["personalized"]["per_class"]["walking"]["f1"] > 0.9
    assert u["delta_macro_f1"] > 0.3
    assert u["model"]["temperature"] > 0
    assert u["model"]["abstain_threshold"] >= 0.5


def test_user_grouping_by_user_id():
    labels, doc = gated_fixture(user_id="u1")
    wins, _ = L.parse_day_doc(doc, "day.json")
    report = run_personalization(labels, wins)
    assert set(report["users"].keys()) == {"u1"}

    # Without user_id everything is one subject.
    labels2, doc2 = gated_fixture(user_id=None)
    wins2, _ = L.parse_day_doc(doc2, "day.json")
    report2 = run_personalization(labels2, wins2)
    assert set(report2["users"].keys()) == {"all"}

    # Direct grouping check.
    groups = build_user_groups(labels)
    assert set(groups.keys()) == {"u1"}
    assert len(groups["u1"]) == len(labels)
    groups2 = build_user_groups(labels2)
    assert set(groups2.keys()) == {"all"}


def test_evaluate_user_refuses_when_not_enough_evidence():
    labels = records_of([
        wire("a", "s1", 0, 40, "walking"), wire("b", "s2", 1000, 1040, "walking"),
    ])
    doc = build_doc([[(0, 40, "walking")], [(1000, 1040, "walking")]])
    wins, _ = L.parse_day_doc(doc, "day.json")
    units, _ = L.assign_units(labels, wins, model="hart")
    loc = [u for u in units if u.head == "locomotion"]
    split = L.split_by_session(labels, loc, holdout_sessions=1)
    report = evaluate_user("all", split.train_units, split.test_units)
    assert report["status"] == "insufficient_evidence"
    assert "walking" in report["failed_classes"]
    assert report["personalized"] is None
