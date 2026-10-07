"""Ground-truth label evaluation harness tests (spec 15.3, contracts 7).

Covers the pure numpy layers of ``activity_context.labels``: defensive label
loading, ``hart-windows-1`` day-doc parsing, window/label joining, leakage-
free session-held-out splits, and every metric with hand-computable expected
values. All fixtures are synthetic and deterministic.
"""

import json
import os
import tempfile

import pytest

from activity_context import labels as L


# ---------------------------------------------------------------------------
# Helpers: synthetic labels + hart-windows-1 day docs
# ---------------------------------------------------------------------------

def sensor_quality(expected, covered=None, gaps=(), wire_ready=None):
    covered = expected if covered is None else covered
    ready = (covered == expected and not gaps)
    return {
        "expected_seconds": expected,
        "covered_seconds": covered,
        "sample_rate_hz": 100,
        "first_ts": None,
        "last_ts": None,
        "gaps": [{"start_ts": a, "end_ts": b} for a, b in gaps],
        "coverage_ratio": covered / expected,
        "evaluation_ready": ready if wire_ready is None else wire_ready,
    }


_MISSING = object()


def wire_label(label_key, source, session_id, s, e, locomotion=None,
               transition_kind=None, transition_ts=None, user_unsure=False,
               quality=_MISSING, user_id=None):
    """One wire label object (route wire form, spec 8.1). Pass ``quality=None``
    to omit sensor_quality entirely (missing coverage evidence)."""
    return {
        "id": f"uuid-{label_key}",
        "label_key": label_key,
        "source": source,
        "session_id": session_id,
        "start_ts": s,
        "end_ts": e,
        "locomotion": locomotion,
        "transition_kind": transition_kind,
        "transition_ts": transition_ts,
        "user_unsure": user_unsure,
        "sensor_quality": sensor_quality(e - s) if quality is _MISSING else quality,
        "user_id": user_id,
    }


def day_doc(t0, spans, pred_label_for):
    """Build a ``hart-windows-1`` object. ``spans`` is [(start, end, truth)],
    ``pred_label_for`` maps a truth to the window label to emit (defaults to
    identity). One-hot probabilities (per mille), baseline=0, no features."""
    s, e, l, b, p, f = [], [], [], [], [], []
    vocab = ["stationary", "walking", "running", "other_movement", "unknown"]
    for (st, en, truth) in spans:
        plabel = pred_label_for.get(truth, truth)
        s.append(st - t0)
        e.append(en - t0)
        l.append(vocab.index(plabel))
        b.append(0)
        row = [0] * len(vocab)
        row[vocab.index(plabel)] = 1000
        p.append(row)
        f.append(None)
    return {
        "format": "hart-windows-1", "t0": t0, "labels": vocab,
        "features": list(L.FEATURE_KEYS), "feature_scale": list(L.FEATURE_SCALE),
        "s": s, "e": e, "l": l, "p": p, "b": b, "f": f,
    }


def tiling_spans(start, end, truth, hop=4):
    """4 s windows that exactly tile [start, end) without straddling."""
    return [(t, t + 4, truth) for t in range(start, end, hop)]


# ---------------------------------------------------------------------------
# Golden end-to-end: 2 guided sessions (strong) + 1 weak stretch label
# ---------------------------------------------------------------------------

GOLDEN_LABELS = [
    # Session A: walking 40s, stationary 20s, running 20s
    wire_label("guided:sessA:100", "guided", "sessA", 100, 140, "walking"),
    wire_label("guided:sessA:140", "guided", "sessA", 140, 160, "stationary"),
    wire_label("guided:sessA:160", "guided", "sessA", 160, 180, "running"),
    # Session B: stationary 24s, walking 24s (gap so no boundary straddle)
    wire_label("guided:sessB:1000", "guided", "sessB", 1000, 1024, "stationary"),
    wire_label("guided:sessB:1032", "guided", "sessB", 1032, 1056, "walking"),
    # Weak: stretch feedback walking (must never mix into the default eval)
    wire_label("stretch:stretch-1:2000", "stretch_feedback", None, 2000, 2020,
               "walking"),
]


def golden_doc():
    spans = (
        tiling_spans(100, 140, "walking")
        + tiling_spans(140, 160, "stationary")
        + tiling_spans(160, 180, "running")
        + tiling_spans(1000, 1024, "stationary")
        + tiling_spans(1032, 1056, "walking")
        + tiling_spans(2000, 2020, "walking")
    )
    # Session A perfect; session B: each class 3 correct / 3 wrong;
    # weak stretch perfect.
    pred = {
        # sessA all correct
        "walking": "walking", "stationary": "stationary", "running": "running",
    }
    doc = day_doc(100, spans, pred)
    # override session B predictions: first 3 windows of each class flipped
    return doc


def golden_doc_with_flips():
    """Session B: stationary [1000,1024) -> first 3 windows predict walking,
    last 3 stationary; walking [1032,1056) -> first 3 predict stationary,
    last 3 walking. Session A and the weak stretch stay perfect."""
    doc = golden_doc()
    # doc arrays are parallel; locate session B windows by their s values.
    t0 = doc["t0"]
    s = doc["s"]
    vocab = doc["labels"]
    for i in range(len(s)):
        st = t0 + s[i]
        if 1000 <= st < 1000 + 12:            # first half of B stationary
            doc["l"][i] = vocab.index("walking")
            row = [0] * len(vocab)
            row[vocab.index("walking")] = 1000
            doc["p"][i] = row
        elif 1012 <= st < 1024:               # second half of B stationary
            doc["l"][i] = vocab.index("stationary")
            row = [0] * len(vocab)
            row[vocab.index("stationary")] = 1000
            doc["p"][i] = row
        elif 1032 <= st < 1032 + 12:          # first half of B walking
            doc["l"][i] = vocab.index("stationary")
            row = [0] * len(vocab)
            row[vocab.index("stationary")] = 1000
            doc["p"][i] = row
        elif 1044 <= st < 1056:               # second half of B walking
            doc["l"][i] = vocab.index("walking")
            row = [0] * len(vocab)
            row[vocab.index("walking")] = 1000
            doc["p"][i] = row
    return doc


def golden_records():
    return [L._label_from_wire(x) for x in GOLDEN_LABELS]


def test_strength_and_session_properties():
    recs = golden_records()
    by_key = {r.label_key: r for r in recs}
    assert by_key["guided:sessA:100"].strength == "strong"
    assert by_key["guided:sessA:100"].session == "sessA"
    # weak stretch: session comes from the label_key prefix
    weak = by_key["stretch:stretch-1:2000"]
    assert weak.strength == "weak"
    assert weak.session == "stretch"
    # guided but unsure is weak too
    unsure = L._label_from_wire(wire_label("guided:s:s1", "guided", "s1", 1, 5,
                                           "walking", user_unsure=True))
    assert unsure.strength == "weak"
    assert not unsure.is_strong


def test_evaluation_ready_gaps_never_valid():
    recs = golden_records()
    good = [r for r in recs if r.source == "guided"][0]
    assert good.evaluation_ready

    # A gap poisons the label even if the wire claims evaluation_ready.
    gapy = L._label_from_wire(wire_label(
        "guided:s:1", "guided", "s", 100, 140, "walking",
        quality=sensor_quality(40, covered=40, gaps=[(120, 125)],
                               wire_ready=True)))
    assert not gapy.evaluation_ready
    assert gapy.sensor_quality.has_any_gap

    # Short coverage is never evaluation-ready.
    short = L._label_from_wire(wire_label(
        "guided:s:2", "guided", "s", 100, 140, "walking",
        quality=sensor_quality(40, covered=35)))
    assert not short.evaluation_ready

    # Missing sensor_quality is NOT evaluation-ready (documented).
    missing = L._label_from_wire(wire_label(
        "guided:s:3", "guided", "s", 100, 140, "walking", quality=None))
    assert not missing.evaluation_ready


def test_load_labels_jsonl_and_json_defensive():
    recs = golden_records()
    with tempfile.TemporaryDirectory() as td:
        jsonl = os.path.join(td, "labels.jsonl")
        with open(jsonl, "w") as f:
            for r in recs:
                f.write(json.dumps({"label_key": r.label_key,
                                    "source": r.source,
                                    "session_id": r.session_id,
                                    "start_ts": r.start_ts,
                                    "end_ts": r.end_ts,
                                    "locomotion": r.locomotion,
                                    "user_unsure": r.user_unsure,
                                    "sensor_quality": sensor_quality(
                                        r.end_ts - r.start_ts)}) + "\n")
            f.write("{not json\n")                       # malformed line
            f.write(json.dumps({"label_key": "bad", "start_ts": 10,
                                "end_ts": 5, "source": "guided"}) + "\n")
        labels, report = L.load_labels(jsonl)
        assert report.total_lines == 8                    # 6 good + 2 bad
        assert report.parsed == 6
        assert report.skipped_malformed == 1
        assert report.skipped_invalid_interval == 1
        assert len(labels) == 6

        array = os.path.join(td, "labels.json")
        wires = [{"label_key": r.label_key, "source": r.source,
                  "session_id": r.session_id, "start_ts": r.start_ts,
                  "end_ts": r.end_ts, "locomotion": r.locomotion,
                  "user_unsure": r.user_unsure,
                  "sensor_quality": sensor_quality(r.end_ts - r.start_ts)}
                 for r in recs]
        with open(array, "w") as f:
            json.dump(wires, f)
        labels2, report2 = L.load_labels(array)
        assert report2.parsed == 6
        assert report2.total_lines == 6


def test_parse_day_doc_drops_bad_windows():
    doc = golden_doc()
    wins, report = L.parse_day_doc(doc, "day.json")
    assert report.format_ok
    n = len(wins)
    assert n == 37                        # 20 sessA + 12 sessB + 5 weak
    assert report.dropped == 0
    assert wins[0].start_ts == 100 and wins[0].end_ts == 104
    assert wins[0].label == "walking"
    assert abs(wins[0].probs_dict["walking"] - 1.0) < 1e-9
    assert not wins[0].baseline

    # Corrupt a couple of windows: bad label index, bad probability row.
    doc["l"][0] = 999
    doc["p"][1] = [0, 1001]               # out-of-range per mille
    doc["s"][2] = "nope"                  # unparseable start
    wins2, report2 = L.parse_day_doc(doc, "day.json")
    assert report2.dropped == 3
    assert len(wins2) == n - 3
    assert wins2[0].start_ts != 100

    # Not a hart-windows-1 doc at all.
    wins3, report3 = L.parse_day_doc({"format": "other"}, "x")
    assert wins3 == []
    assert not report3.format_ok


def test_golden_e2e_session_b_metrics_exact():
    """Hold out the last session (B). Session A trains (perfect), session B
    tests with exactly 3 correct + 3 wrong per class. All numbers below are
    hand-computable."""
    recs = golden_records()
    wins, _ = L.parse_day_doc(golden_doc_with_flips(), "day.json")
    units, counts = L.assign_units(recs, wins, model="hart")
    # 40 units total, but the weak stretch is excluded by default.
    assert counts["labels_total"] == 6
    assert counts["labels_excluded_weak"] == 1
    assert counts["windows_total"] == 37
    assert counts["units"] == 32              # 20 sessA + 12 sessB
    assert all(u.session != "stretch" for u in units)

    split = L.split_by_session(recs, units, holdout_sessions=1)
    assert split.train_sessions == ("sessA",)
    assert split.test_sessions == ("sessB",)
    assert len(split.train_units) == 20
    assert len(split.test_units) == 12

    rep = L.evaluate_head(split.test_units)
    assert rep["n_units"] == 12
    assert rep["n_accepted"] == 12
    assert rep["n_abstained"] == 0
    assert rep["abstention_rate"] == 0.0
    assert rep["accepted_coverage"] == 1.0
    assert set(rep["classes"]) == {"stationary", "walking"}
    assert rep["per_class"]["stationary"] == {
        "tp": 3, "fp": 3, "fn": 3, "precision": 0.5, "recall": 0.5,
        "f1": 0.5, "support": 6}
    assert rep["per_class"]["walking"]["tp"] == 3
    assert rep["per_class"]["walking"]["f1"] == 0.5
    assert rep["macro_f1"] == 0.5
    assert rep["balanced_accuracy"] == 0.5
    assert rep["duration_weighted_accuracy"] == 0.5
    # Brier: 6 wrong (error 2 each) + 6 right (0) over 12 -> 1.0
    assert rep["brier"] == pytest.approx(1.0)
    # ECE-15: every confidence is 1.0 and accuracy is 0.5 -> 0.5
    assert rep["ece_15"] == pytest.approx(0.5)
    # Segment-F1: 4 pred runs (12 s each) vs 2 truth runs (24 s each),
    # 2 matched pairs each with IoU 1/2 -> 2*(1/2+1/2)/(48+48) = 1/48
    assert rep["segment"]["segment_f1"] == pytest.approx(1.0 / 48.0, abs=1e-5)
    assert rep["segment"]["n_truth_runs"] == 2
    assert rep["segment"]["n_pred_runs"] == 4
    assert rep["segment"]["n_matched_runs"] == 2

    # Train session is perfect.
    rep_train = L.evaluate_head(split.train_units)
    assert rep_train["macro_f1"] == 1.0
    assert rep_train["brier"] == 0.0
    assert rep_train["ece_15"] == 0.0
    assert rep_train["duration_weighted_accuracy"] == 1.0


def test_strong_weak_never_mixed_default():
    recs = golden_records()
    wins, _ = L.parse_day_doc(golden_doc(), "day.json")
    units_default, counts_default = L.assign_units(recs, wins, model="hart")
    assert counts_default["labels_excluded_weak"] == 1
    assert all(u.label.is_strong for u in units_default)

    # Combined view with --include-weak adds the weak stretch, clearly
    # separable by session.
    units_weak, counts_weak = L.assign_units(recs, wins, model="hart",
                                             include_weak=True)
    assert counts_weak["labels_excluded_weak"] == 0
    assert counts_weak["units"] == counts_default["units"] + 5
    assert any(u.session == "stretch" for u in units_weak)


def test_gap_labels_excluded_from_units():
    recs = golden_records()
    gapy = L._label_from_wire(wire_label(
        "guided:sessB:1000", "guided", "sessB", 1000, 1024, "stationary",
        quality=sensor_quality(24, covered=24, gaps=[(1010, 1015)],
                               wire_ready=True)))
    recs2 = [r if r.label_key != "guided:sessB:1000" else gapy for r in recs]
    wins, _ = L.parse_day_doc(golden_doc(), "day.json")
    units, counts = L.assign_units(recs2, wins, model="hart")
    assert counts["labels_excluded_degraded"] == 1
    # The 6 stationary-B windows fall to the next-best eligible label (none
    # overlaps them), so they are dropped too.
    assert not any(u.label.label_key == "guided:sessB:1000" for u in units)

    # --include-degraded restores them (counted as a warning).
    units_d, counts_d = L.assign_units(recs2, wins, model="hart",
                                       include_degraded=True)
    assert counts_d["labels_excluded_degraded"] == 0
    assert counts_d["labels_degraded_included"] == 1
    assert any(u.label.label_key == "guided:sessB:1000" for u in units_d)


def test_split_by_session_leakage_free():
    recs = golden_records()
    wins, _ = L.parse_day_doc(golden_doc(), "day.json")
    units, _ = L.assign_units(recs, wins, model="hart")

    split = L.split_by_session(recs, units, holdout_sessions=1)
    train_sess = set(split.train_sessions)
    test_sess = set(split.test_sessions)
    assert not (train_sess & test_sess)               # no session on both sides
    train_ids = {id(u.window) for u in split.train_units}
    test_ids = {id(u.window) for u in split.test_units}
    assert not (train_ids & test_ids)                 # no window on both sides
    for u in split.train_units:
        assert u.session in train_sess
    for u in split.test_units:
        assert u.session in test_sess

    # Alternate is deterministic and disjoint too.
    split2 = L.split_by_session(recs, units, mode="alternate")
    assert set(split2.train_sessions) & set(split2.test_sessions) == set()
    # Hold out both sessions -> everything tests.
    split3 = L.split_by_session(recs, units, holdout_sessions=2)
    assert len(split3.train_units) == 0
    assert len(split3.test_units) == len(units)

    # Chronological: sessions starting at/after the timestamp are test.
    split4 = L.split_by_session(recs, units, mode="chronological",
                                chronological_ts=1000)
    assert split4.test_sessions == ("sessB",)
    assert split4.train_sessions == ("sessA",)


def test_window_boundary_straddle_keeps_one_session():
    """A window straddling two labels of the same session is claimed once
    (split integrity); a window straddling labels of DIFFERENT sessions is
    impossible in practice, but the claim is still single-session."""
    recs = [
        L._label_from_wire(wire_label("guided:s:1", "guided", "sessX", 100, 106,
                                      "walking")),
        L._label_from_wire(wire_label("guided:s:2", "guided", "sessX", 106, 112,
                                      "stationary")),
    ]
    wins = [L.WindowPrediction(start_ts=104, end_ts=108, label="walking")]
    units, counts = L.assign_units(recs, wins, model="hart")
    # The straddling window is claimed by the label with the largest overlap
    # (both 2 s here; tie -> earlier start_ts = walking [100,106)).
    assert len(units) == 1
    assert units[0].truth == "walking"
    assert units[0].session == "sessX"


def test_transition_matching_exact():
    gt = [("sit_to_stand", 100), ("walk_start", 200), ("walk_stop", 300)]
    pred = [("sit_to_stand", 102), ("walk_start", 205), ("other", 350),
            ("other", 1000)]
    res = L.transition_matching(gt, pred, tau=5, monitored_seconds=3600)
    assert res["n_gt_events"] == 3
    assert res["n_pred_events"] == 4
    assert res["matched"] == 2
    assert res["unmatched_gt"] == 1
    assert res["unmatched_pred"] == 2
    assert res["median_abs_err_s"] == 3.5
    assert res["p90_abs_err_s"] == 4.7
    assert res["signed_bias_s"] == 3.5
    assert res["precision"] == pytest.approx(0.5)
    assert res["recall"] == pytest.approx(2 / 3)
    assert res["f1"] == pytest.approx(2 * 0.5 * (2 / 3) / (0.5 + 2 / 3))
    # 2 false events over 1 monitored hour.
    assert res["fp_per_hour"] == pytest.approx(2.0)

    # Stricter tolerance drops the tau=5 match.
    res2 = L.transition_matching(gt, pred, tau=2, monitored_seconds=3600)
    assert res2["matched"] == 1
    assert res2["unmatched_gt"] == 2
    assert res2["unmatched_pred"] == 3
    assert res2["fp_per_hour"] == pytest.approx(3.0)

    # Empty streams.
    res3 = L.transition_matching([], [], tau=5, monitored_seconds=0)
    assert res3["matched"] == 0
    assert res3["f1"] == 0.0
    assert res3["fp_per_hour"] is None


def test_abstention_and_coverage():
    recs = golden_records()
    wins, _ = L.parse_day_doc(golden_doc(), "day.json")
    # Force the first 4 sessA windows to abstain (label 'unknown').
    for w in wins:
        if w.start_ts < 116:
            object.__setattr__(w, "label", "unknown")
            object.__setattr__(w, "probs", (("unknown", 1.0),))
    units, _ = L.assign_units(recs, wins, model="hart")
    split = L.split_by_session(recs, units, holdout_sessions=1)
    rep = L.evaluate_head(split.train_units)
    assert rep["n_abstained"] == 4
    assert rep["n_accepted"] == 16
    assert rep["abstention_rate"] == pytest.approx(4 / 20)
    assert rep["accepted_coverage"] == pytest.approx(16 / 20)
    # Accepted-only metrics are unaffected by the abstained windows.
    assert rep["macro_f1"] == 1.0
    assert rep["brier"] == 0.0
    assert rep["ece_15"] == 0.0
    # Predicted transitions ignore abstained windows: no event before the
    # first accepted window (the abstained [100,116) windows emit nothing),
    # and the only events are the truth-consistent walking->stationary and
    # stationary->running boundary changes at 140 and 160.
    pred_events = L.predicted_transitions(split.train_units)
    assert pred_events == [("walking->stationary", 140),
                           ("stationary->running", 160)]


def test_per_session_distribution():
    """Two sessions with different macro-F1; both pooled and session-macro
    are reported, and the per-session table carries per-session macro-F1."""
    recs = golden_records()
    wins, _ = L.parse_day_doc(golden_doc(), "day.json")
    units, _ = L.assign_units(recs, wins, model="hart")
    split = L.split_by_session(recs, units, holdout_sessions=1)
    ps = L.per_session_macro_f1(split.train_units)
    assert ps["n_sessions"] == 1
    assert ps["per_session"]["sessA"]["macro_f1"] == 1.0
    assert ps["per_session"]["sessA"]["n_units"] == 20
    assert ps["pooled_macro_f1"] == 1.0
    assert ps["session_macro_f1_mean"] == 1.0

    # A synthetic 2-session set with distinct macro-F1s.
    recs2 = [
        L._label_from_wire(wire_label("guided:s1:0", "guided", "s1", 0, 8,
                                      "walking")),
        L._label_from_wire(wire_label("guided:s2:100", "guided", "s2", 100, 108,
                                      "walking")),
    ]
    wins2 = [
        L.WindowPrediction(start_ts=0, end_ts=4, label="walking"),
        L.WindowPrediction(start_ts=4, end_ts=8, label="walking"),
        L.WindowPrediction(start_ts=100, end_ts=104, label="stationary"),
        L.WindowPrediction(start_ts=104, end_ts=108, label="stationary"),
    ]
    units2, _ = L.assign_units(recs2, wins2, model="hart")
    ps2 = L.per_session_macro_f1(units2)
    assert ps2["per_session"]["s1"]["macro_f1"] == 1.0
    assert ps2["per_session"]["s2"]["macro_f1"] == 0.0
    assert ps2["session_macro_f1_mean"] == 0.5
    assert ps2["session_macro_f1_median"] == 0.5
    assert ps2["session_macro_f1_iqr"] == 0.5
    assert ps2["session_macro_f1_min"] == 0.0
    assert ps2["session_macro_f1_max"] == 1.0
    # Pooled: walking F1 = 2/3 (2 right, 2 FN), stationary F1 = 0
    # (2 FP, no support) -> pooled macro = 1/3; session-macro mean = 1/2.
    assert ps2["pooled_macro_f1"] == pytest.approx(1 / 3, abs=1e-4)
    assert ps2["divergence"] == pytest.approx(1 / 6, abs=1e-4)


def test_brier_ece_perfect_probs_zero():
    """Perfect one-hot probabilities with all-correct predictions -> Brier 0,
    ECE-15 0."""
    recs = [
        L._label_from_wire(wire_label("guided:s:1", "guided", "s", 0, 12,
                                      "walking")),
        L._label_from_wire(wire_label("guided:s:2", "guided", "s", 12, 24,
                                      "stationary")),
    ]
    wins = [
        L.WindowPrediction(start_ts=0, end_ts=4, label="walking",
                           probs=(("walking", 1.0),)),
        L.WindowPrediction(start_ts=4, end_ts=8, label="walking",
                           probs=(("walking", 1.0),)),
        L.WindowPrediction(start_ts=8, end_ts=12, label="walking",
                           probs=(("walking", 1.0),)),
        L.WindowPrediction(start_ts=12, end_ts=16, label="stationary",
                           probs=(("stationary", 1.0),)),
        L.WindowPrediction(start_ts=16, end_ts=20, label="stationary",
                           probs=(("stationary", 1.0),)),
        L.WindowPrediction(start_ts=20, end_ts=24, label="stationary",
                           probs=(("stationary", 1.0),)),
    ]
    units, _ = L.assign_units(recs, wins, model="hart")
    assert L.brier_per_head(units) == 0.0
    assert L.ece_15_per_head(units) == 0.0


def test_head_mapping_unknown_abstains():
    """'unknown' window label abstains every head; unmapped labels too."""
    recs = [
        L._label_from_wire(wire_label("guided:s:1", "guided", "s", 0, 4,
                                      "walking")),
    ]
    wins = [
        L.WindowPrediction(start_ts=0, end_ts=4, label="unknown"),
        L.WindowPrediction(start_ts=0, end_ts=4, label="teleporting"),
    ]
    units, _ = L.assign_units(recs, wins, model="hart")
    assert len(units) == 2
    assert units[0].predicted is None
    assert units[1].predicted is None
    assert L.HART_LABEL_TO_HEADS["walking"] == {"locomotion": "walking"}
    assert L.HART_LABEL_TO_HEADS["unknown"] is None


def _unit(s, e, session, truth="walking", predicted="walking"):
    label = L.LabelRecord(start_ts=s, end_ts=e, locomotion=truth, session_id=session,
                          sensor_quality=L.SensorQuality(expected_seconds=e - s,
                                                         covered_seconds=e - s))
    return L.EvalUnit(window=L.WindowPrediction(start_ts=s, end_ts=e, label=predicted or "unknown"),
                      head="locomotion", truth=truth, predicted=predicted, session=session,
                      model="hart", label_duration_s=e - s, label=label)


def test_each_stretch_feedback_label_is_its_own_session():
    # The phone's real key shape: stretch_feedback:<kind>:<stretchStart>:<labelStart>.
    a = L._label_from_wire(wire_label("stretch_feedback:activity_context:5000:5000",
                                      "stretch_feedback", None, 5000, 5100, "walking"))
    b = L._label_from_wire(wire_label("stretch_feedback:activity_context:9000:9000",
                                      "stretch_feedback", None, 9000, 9100, "walking"))
    assert a.session == "stretch:activity_context:5000"
    assert b.session == "stretch:activity_context:9000"


def test_split_drops_windows_sharing_raw_seconds_across_sides():
    # 4 s windows on a 2 s hop: the last window of A and the first of B overlap.
    units = [_unit(0, 4, "A"), _unit(2, 6, "A"), _unit(4, 8, "B"), _unit(6, 10, "B")]
    split = L.split_by_session([], units, holdout_sessions=1)
    assert split.report["overlap_dropped_units"] == 2
    assert [(u.window.start_ts, u.window.end_ts) for u in split.train_units] == [(0, 4)]
    assert [(u.window.start_ts, u.window.end_ts) for u in split.test_units] == [(6, 10)]


def test_split_keeps_everything_when_sides_do_not_touch():
    units = [_unit(0, 4, "A"), _unit(100, 104, "B")]
    split = L.split_by_session([], units, holdout_sessions=1)
    assert split.report["overlap_dropped_units"] == 0
    assert len(split.train_units) == 1 and len(split.test_units) == 1


def test_brier_and_ece_score_a_prediction_outside_the_truth_classes_as_wrong():
    units = [_unit(0, 4, "A", truth="walking", predicted="cycling")]
    assert L.brier_per_head(units) == 1.0
    assert L.ece_15_per_head(units) == 0.0
