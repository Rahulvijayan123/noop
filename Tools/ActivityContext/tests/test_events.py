"""Event matching and metrics tests for the transition expert.

Tests cover the greedy one-to-one same-kind matcher (perfect, tau edges, duplicates, direction
confusion, FN+FP, one-to-one consumption), the per-tau metric report (hours normalization,
per-class P/R/F1, macro F1, timestamp errors, abstention), and the seeded sign-flip permutation
test (identical arrays -> large p; constant shift -> small p).
"""

import numpy as np
import pytest

from activity_context.events import match_events, metrics, paired_participant_diffs
from activity_context.transition_data import TransitionEvent

STS = "sit_to_stand"
STD = "stand_to_sit"
LIE = "lie_down"
GET = "get_up"


# ---------------------------------------------------------------------------
# match_events
# ---------------------------------------------------------------------------

def test_perfect_match():
    m = match_events([(1.0, STS), (5.0, STD)], [(1.0, STS), (5.0, STD)], 0.5)
    assert (m.tp, m.fn, m.fp, m.duplicates) == (2, 0, 0, 0)
    assert m.direction_confusions == []
    assert m.matched == [(1.0, 1.0, STS), (5.0, 5.0, STD)]


def test_tau_edge_is_inclusive():
    m = match_events([(1.0, STS)], [(1.5, STS)], 0.5)
    assert (m.tp, m.fn, m.fp) == (1, 0, 0)
    m2 = match_events([(1.0, STS)], [(1.51, STS)], 0.5)
    assert (m2.tp, m2.fn, m2.fp) == (0, 1, 1)


def test_duplicate_counts_as_fp():
    m = match_events([(1.0, STS)], [(1.0, STS), (1.2, STS)], 0.5)
    assert (m.tp, m.fn, m.fp, m.duplicates) == (1, 0, 1, 1)


def test_cross_kind_is_direction_confusion():
    m = match_events([(1.0, STS)], [(1.0, STD)], 0.5)
    assert (m.tp, m.fn, m.fp, m.duplicates) == (0, 1, 1, 0)
    assert m.direction_confusions == [(STS, STD)]


def test_fn_and_fp_when_events_are_far_apart():
    m = match_events([(1.0, STS)], [(10.0, STS)], 0.5)
    assert (m.tp, m.fn, m.fp) == (0, 1, 1)


def test_one_to_one_consumes_each_pred_once():
    m = match_events([(1.0, STS), (1.1, STS)], [(1.05, STS)], 0.5)
    assert (m.tp, m.fn, m.fp) == (1, 1, 0)
    assert m.matched == [(1.0, 1.05, STS)]


def test_earliest_unmatched_same_kind_is_consumed():
    gt = [(5.0, STS)]
    pred = [(4.6, STS), (4.8, STD), (5.2, STS)]     # both STS preds within tau=0.5
    m = match_events(gt, pred, 0.5)
    assert (m.tp, m.fn, m.fp, m.duplicates) == (1, 0, 2, 1)
    assert m.matched == [(5.0, 4.6, STS)]           # earliest same-kind pred wins


def test_accepts_event_objects_and_rejects_unknown_kinds():
    ev = TransitionEvent(kind=LIE, ts=1.0, onset_ts=1.0, offset_ts=1.0,
                         subject="s", dataset="d", placement="wrist", session_id="s-0")
    m = match_events([ev], [(1.0, LIE)], 0.5)
    assert m.tp == 1
    with pytest.raises(ValueError):
        match_events([(1.0, "bogus")], [], 0.5)
    with pytest.raises(ValueError):
        match_events([(1.0, "a")], [(1.0, "b")], 0.5, kinds=("a",))  # "b" pred unknown


def test_custom_kinds_are_honoured():
    m = match_events([(1.0, "a"), (3.0, "b")], [(1.1, "a"), (2.9, "b")], 0.5, kinds=("a", "b"))
    assert (m.tp, m.fn, m.fp) == (2, 0, 0)


# ---------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------

def test_metrics_perfect_structure_and_macro():
    res = metrics([(1.0, STS), (5.0, STD)], [(1.0, STS), (5.0, STD)],
                  taus=(0.5, 1.0), hours=1.0)
    assert set(res) == {0.5, 1.0}
    for tau in (0.5, 1.0):
        r = res[tau]
        assert r["tp"] == 2 and r["fn"] == 0 and r["fp"] == 0
        assert r["precision"] == 1.0 and r["recall"] == 1.0 and r["f1"] == 1.0
        assert r["fp_per_hour"] == 0.0 and r["missed_per_hour"] == 0.0
        assert r["duplicate_rate"] == 0.0
        assert r["abs_err_median"] == 0.0 and r["signed_err_median"] == 0.0
        assert r["direction_confusion_matrix"] == {}
        # macro F1 averages over the four kinds (0 for kinds with no support)
        assert r["per_class"][STS]["f1"] == 1.0
        assert r["per_class"][LIE]["f1"] == 0.0
        assert r["macro_f1"] == pytest.approx(0.5)
        assert r["abstention_rate"] is None


def test_metrics_hours_normalization():
    gt = [(1.0, STS)]
    pred = [(10.0, STS)]
    r2 = metrics(gt, pred, taus=(1.0,), hours=2.0)[1.0]
    r4 = metrics(gt, pred, taus=(1.0,), hours=4.0)[1.0]
    assert r2["fp_per_hour"] == pytest.approx(2.0 * r4["fp_per_hour"])
    assert r2["missed_per_hour"] == pytest.approx(2.0 * r4["missed_per_hour"])
    assert r2["fp_per_hour"] == pytest.approx(0.5)


def test_metrics_hours_estimated_from_event_span():
    r = metrics([(0.0, STS)], [(3600.0, STS)], taus=(1.0,))[1.0]
    assert r["fp_per_hour"] == pytest.approx(1.0)
    assert r["missed_per_hour"] == pytest.approx(1.0)


def test_metrics_timestamp_errors():
    gt = [(1.0, STS), (10.0, STS), (20.0, STD)]
    pred = [(1.2, STS), (9.8, STS), (20.3, STD)]
    r = metrics(gt, pred, taus=(2.0,), hours=1.0)[2.0]
    abs_err = [0.2, 0.2, 0.3]
    signed_err = [0.2, -0.2, 0.3]
    assert r["tp"] == 3 and r["fn"] == 0 and r["fp"] == 0
    assert r["abs_err_median"] == pytest.approx(float(np.median(abs_err)))
    assert r["abs_err_p90"] == pytest.approx(float(np.percentile(abs_err, 90)))
    assert r["signed_err_median"] == pytest.approx(float(np.median(signed_err)))


def test_metrics_direction_confusion_matrix_and_per_class():
    r = metrics([(1.0, STS)], [(1.0, STD)], taus=(1.0,), hours=1.0)[1.0]
    assert r["direction_confusion_matrix"] == {(STS, STD): 1}
    assert r["per_class"][STS]["fn"] == 1 and r["per_class"][STS]["tp"] == 0
    assert r["per_class"][STD]["fp"] == 1 and r["per_class"][STD]["tp"] == 0
    assert r["per_class"][STD]["recall"] == 0.0


def test_metrics_duplicate_rate():
    r = metrics([(1.0, STS)], [(1.0, STS), (1.2, STS)], taus=(1.0,), hours=1.0)[1.0]
    assert r["duplicate_rate"] == pytest.approx(1.0)
    r2 = metrics([], [(1.0, STS)], taus=(1.0,), hours=1.0)[1.0]
    assert r2["duplicate_rate"] == 0.0


def test_metrics_abstention_counts():
    r = metrics([(1.0, STS)], [(1.0, STS)], taus=(1.0,), hours=1.0,
                abstain_counts={"n_windows": 100, "n_abstained": 40})[1.0]
    assert r["abstention_rate"] == pytest.approx(0.4)
    r2 = metrics([(1.0, STS)], [(1.0, STS)], taus=(1.0,),
                 abstain_counts={"n_windows": 200, "n_none_label": 50})[1.0]
    assert r2["abstention_rate"] == pytest.approx(0.25)


def test_metrics_empty_inputs():
    r = metrics([], [], taus=(1.0,), hours=1.0)[1.0]
    assert (r["tp"], r["fp"], r["fn"]) == (0, 0, 0)
    assert r["precision"] == 0.0 and r["recall"] == 0.0 and r["f1"] == 0.0
    assert r["abs_err_median"] is None and r["abs_err_p90"] is None
    assert r["macro_f1"] == 0.0


# ---------------------------------------------------------------------------
# paired_participant_diffs
# ---------------------------------------------------------------------------

def test_permutation_identical_arrays_give_large_p():
    a = np.array([0.50, 0.60, 0.70, 0.55, 0.65, 0.75, 0.50, 0.60])
    diff, p = paired_participant_diffs(a, a, seed=0)
    assert diff == 0.0
    assert p >= 0.9


def test_permutation_constant_shift_gives_small_p():
    a = np.array([0.50, 0.60, 0.70, 0.55, 0.65, 0.75, 0.50, 0.60])
    b = a - 0.3
    diff, p = paired_participant_diffs(a, b, seed=0)
    assert diff == pytest.approx(0.3)
    assert p < 0.05


def test_permutation_is_reproducible_for_fixed_seed():
    a = np.array([0.50, 0.60, 0.70, 0.55, 0.65, 0.75])
    b = np.array([0.40, 0.70, 0.60, 0.60, 0.70, 0.70])
    r1 = paired_participant_diffs(a, b, seed=7)
    r2 = paired_participant_diffs(a, b, seed=7)
    assert r1 == r2
    r3 = paired_participant_diffs(a, b, seed=8)
    assert r1[1] >= 0.0 and r1[1] <= 1.0 and r3[1] >= 0.0 and r3[1] <= 1.0
