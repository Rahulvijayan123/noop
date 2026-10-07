"""Temporal / online metrics tests (methodology 4, contracts task scope).

Hand-computed exact expected numbers for ``labels.temporal_metrics``, which
scores the DECODED label stream of one model+head (per-window units) with:

  * label acquisition delay (LAD): first window whose predicted == new truth,
    measured to that window's END: ``first_match_end - change_ts``.
  * transition delay (TD): each predicted label change (non-abstained to
    non-abstained) pairs with the nearest truth change of the same contiguous
    segment: ``pred_change_end - truth_change_ts``.
  * flip rate: predicted changes per hour between two non-unknown
    predictions, excluding changes whose boundary lies within ``guard_s``
    (2 s) of a truth change; plus median run length of identical non-unknown
    predictions (in windows).
  * time to stable correct state (TSCS, K=3): first window that predicts the
    new truth AND holds for 3 consecutive non-abstained windows.

All fixtures use 2 s windows tiling a 2 s hop grid, so a change at ts T with
an immediate correct prediction gives LAD = TD = 2 s (one hop).
"""

from __future__ import annotations

import pytest

from activity_context import labels as L


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def units(seq, session="sess"):
    """Build one-session EvalUnits from (start, end, truth, predicted) rows."""
    out = []
    for s, e, truth, pred in seq:
        window = L.WindowPrediction(start_ts=s, end_ts=e,
                                    label=pred if pred is not None else "unknown")
        out.append(L.EvalUnit(
            window=window, head="locomotion", truth=truth, predicted=pred,
            session=session, model="hart", label_duration_s=e - s,
            label=L.LabelRecord(
                start_ts=s, end_ts=e, locomotion=truth, session_id=session,
                sensor_quality=L.SensorQuality(expected_seconds=e - s,
                                               covered_seconds=e - s)),
        ))
    return out


# ---------------------------------------------------------------------------
# Constant truth -> None blocks
# ---------------------------------------------------------------------------

def test_constant_truth_returns_none_blocks():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "walking", "walking")])
    t = L.temporal_metrics(u)
    assert t["n_units"] == 3
    assert t["n_truth_changes"] == 0
    assert t["n_predicted_changes"] == 0
    # No truth changes: LAD / TD / TSCS blocks are None.
    assert t["label_acquisition_delay_s"] is None
    assert t["transition_delay_s"] is None
    assert t["time_to_stable_correct_s"] is None
    # Flip rate is still reported on the predicted stream.
    assert t["flip_rate"]["flips"] == 0
    assert t["flip_rate"]["flips_per_hour"] == 0.0
    assert t["flip_rate"]["median_run_length_windows"] == 3.0
    assert t["flip_rate"]["run_lengths_windows"] == [3]


def test_empty_stream_all_none():
    t = L.temporal_metrics([])
    assert t["n_units"] == 0
    assert t["n_truth_changes"] == 0
    assert t["label_acquisition_delay_s"] is None
    assert t["transition_delay_s"] is None
    assert t["time_to_stable_correct_s"] is None
    assert t["flip_rate"]["flips_per_hour"] is None
    assert t["flip_rate"]["median_run_length_windows"] is None


# ---------------------------------------------------------------------------
# Single change, immediate correct prediction: LAD = 2 s = one hop
# ---------------------------------------------------------------------------

def test_immediate_correct_prediction_lad_one_hop():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "stationary"),
               (6, 8, "stationary", "stationary"),
               (8, 10, "stationary", "stationary")])
    t = L.temporal_metrics(u)
    assert t["n_truth_changes"] == 1
    # The truth change is at 4 (end of the last walking window); the first
    # window that predicts stationary is [4,6), ending at 6: LAD = 2 (one hop).
    assert t["label_acquisition_delay_s"]["per_change"] == [2.0]
    assert t["label_acquisition_delay_s"]["median_s"] == 2.0
    assert t["label_acquisition_delay_s"]["p90_s"] == 2.0
    assert t["label_acquisition_delay_s"]["n_acquired"] == 1
    assert t["label_acquisition_delay_s"]["n_censored"] == 0
    # Same convention for the predicted transition: TD = 6 - 4 = 2.
    assert t["transition_delay_s"]["per_change"] == [2.0]
    assert t["transition_delay_s"]["signed_bias_s"] == 2.0
    assert t["transition_delay_s"]["median_abs_s"] == 2.0
    assert t["transition_delay_s"]["p90_abs_s"] == 2.0
    # The one predicted change sits exactly on the truth change (boundary 4
    # within guard_s=2), so it is NOT a flip.
    assert t["flip_rate"]["flips"] == 0
    assert t["flip_rate"]["flips_per_hour"] == 0.0
    assert t["flip_rate"]["run_lengths_windows"] == [2, 3]
    assert t["flip_rate"]["median_run_length_windows"] == 2.5
    # TSCS: [4,6) [6,8) [8,10) hold stationary; stable_end = 10 -> 10 - 4 = 6.
    assert t["time_to_stable_correct_s"]["per_change"] == [6.0]
    assert t["time_to_stable_correct_s"]["median_s"] == 6.0
    assert t["time_to_stable_correct_s"]["p90_s"] == 6.0
    assert t["time_to_stable_correct_s"]["n_acquired"] == 1
    assert t["time_to_stable_correct_s"]["n_never"] == 0


# ---------------------------------------------------------------------------
# Delayed correct prediction (pinned)
# ---------------------------------------------------------------------------

def test_delayed_correct_prediction_pinned():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "walking"),
               (6, 8, "stationary", "walking"),
               (8, 10, "stationary", "stationary"),
               (10, 12, "stationary", "stationary"),
               (12, 14, "stationary", "stationary")])
    t = L.temporal_metrics(u)
    # First match [8,10) ends at 10: LAD = 10 - 4 = 6.
    assert t["label_acquisition_delay_s"]["per_change"] == [6.0]
    assert t["label_acquisition_delay_s"]["median_s"] == 6.0
    # Predicted change walking->stationary first shows at [8,10): TD = 10-4 = 6.
    assert t["transition_delay_s"]["per_change"] == [6.0]
    assert t["transition_delay_s"]["signed_bias_s"] == 6.0
    # The one predicted change (boundary 8) is outside the [2,6] guard -> flip.
    assert t["flip_rate"]["flips"] == 1
    assert t["flip_rate"]["flips_per_hour"] == pytest.approx(
        1.0 / (14.0 / 3600.0))
    assert t["flip_rate"]["run_lengths_windows"] == [4, 3]
    assert t["flip_rate"]["median_run_length_windows"] == 3.5
    # TSCS: [8,10) [10,12) [12,14) hold; stable_end = 14 -> 14 - 4 = 10.
    assert t["time_to_stable_correct_s"]["per_change"] == [10.0]
    assert t["time_to_stable_correct_s"]["median_s"] == 10.0
    assert t["time_to_stable_correct_s"]["p90_s"] == 10.0
    assert t["time_to_stable_correct_s"]["n_never"] == 0


# ---------------------------------------------------------------------------
# Flip counting with guard exclusion
# ---------------------------------------------------------------------------

def test_flips_count_with_guard_exclusion():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "stationary"),
               (6, 8, "stationary", "stationary"),
               (8, 10, "stationary", "walking"),
               (10, 12, "stationary", "walking"),
               (12, 14, "stationary", "stationary"),
               (14, 16, "stationary", "stationary")])
    t = L.temporal_metrics(u)
    # Predicted changes: boundary 4 (inside guard [2,6] -> excluded),
    # boundary 8 and boundary 12 (both outside -> flips).
    assert t["n_predicted_changes"] == 3
    assert t["flip_rate"]["flips"] == 2
    assert t["flip_rate"]["flips_per_hour"] == pytest.approx(
        2.0 / (16.0 / 3600.0))  # 450.0
    assert t["flip_rate"]["run_lengths_windows"] == [2, 2, 2, 2]
    assert t["flip_rate"]["median_run_length_windows"] == 2.0
    # LAD still 2 (first match [4,6) ends at 6).
    assert t["label_acquisition_delay_s"]["per_change"] == [2.0]
    # TD pairs every predicted change with the (single) truth change at 4:
    # [6-4, 10-4, 14-4] = [2, 6, 10]; signed bias = median = 6, |TD| p90 = 9.2.
    assert t["transition_delay_s"]["per_change"] == [2.0, 6.0, 10.0]
    assert t["transition_delay_s"]["signed_bias_s"] == 6.0
    assert t["transition_delay_s"]["median_abs_s"] == 6.0
    assert t["transition_delay_s"]["p90_abs_s"] == pytest.approx(9.2)
    # TSCS never reached: the [4,6) hold is broken by the [8,10) flip and the
    # [12,14) run cannot hold 3 windows.
    assert t["time_to_stable_correct_s"]["per_change"] == []
    assert t["time_to_stable_correct_s"]["median_s"] is None
    assert t["time_to_stable_correct_s"]["n_acquired"] == 0
    assert t["time_to_stable_correct_s"]["n_never"] == 1


# ---------------------------------------------------------------------------
# TSCS with K=3 and abstention semantics
# ---------------------------------------------------------------------------

def test_tscs_requires_k_consecutive_non_abstained_windows():
    """An abstained window breaks the hold; LAD matches on the first
    non-abstained window, and abstention is never a flip or a match."""
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "stationary"),
               (6, 8, "stationary", None),          # abstained: breaks the hold
               (8, 10, "stationary", "stationary"),
               (10, 12, "stationary", "stationary"),
               (12, 14, "stationary", "stationary")])
    t = L.temporal_metrics(u)
    # LAD uses the first non-abstained match: [4,6) ends at 6 -> 2.
    assert t["label_acquisition_delay_s"]["per_change"] == [2.0]
    # The [4,6) candidate cannot hold 3 (the [6,8) abstention breaks it); the
    # next candidate [8,10) holds [8,10)[10,12)[12,14) -> stable_end 14.
    assert t["time_to_stable_correct_s"]["per_change"] == [10.0]
    assert t["time_to_stable_correct_s"]["median_s"] == 10.0
    assert t["time_to_stable_correct_s"]["n_never"] == 0
    # Abstention is never a flip: the only predicted change is at the truth
    # boundary (guard-excluded), and the abstained window emits no change.
    assert t["n_predicted_changes"] == 1
    assert t["flip_rate"]["flips"] == 0
    # Runs break at the abstention: [walking x2, stationary x1, stationary x3].
    assert t["flip_rate"]["run_lengths_windows"] == [2, 1, 3]
    assert t["flip_rate"]["median_run_length_windows"] == 2.0


# ---------------------------------------------------------------------------
# Multiple changes: median/p90 over changes
# ---------------------------------------------------------------------------

def test_multiple_changes_median_and_p90():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "stationary"),
               (6, 8, "stationary", "stationary"),
               (8, 10, "stationary", "stationary"),
               (10, 12, "walking", "walking"),
               (12, 14, "walking", "walking"),
               (14, 16, "walking", "walking")])
    t = L.temporal_metrics(u)
    assert t["n_truth_changes"] == 2
    # Changes at 4 and 10, both acquired one hop later: LAD = [2, 2].
    assert t["label_acquisition_delay_s"]["per_change"] == [2.0, 2.0]
    assert t["label_acquisition_delay_s"]["median_s"] == 2.0
    assert t["label_acquisition_delay_s"]["p90_s"] == 2.0
    assert t["label_acquisition_delay_s"]["n_censored"] == 0
    # Both predicted changes are guard-excluded -> no flips.
    assert t["flip_rate"]["flips"] == 0
    assert t["flip_rate"]["run_lengths_windows"] == [2, 3, 3]
    assert t["flip_rate"]["median_run_length_windows"] == 3.0
    # TSCS: change at 4 -> stable_end 10 (6 s); change at 10 -> stable_end 16.
    assert t["time_to_stable_correct_s"]["per_change"] == [6.0, 6.0]
    assert t["time_to_stable_correct_s"]["median_s"] == 6.0
    assert t["time_to_stable_correct_s"]["p90_s"] == 6.0


# ---------------------------------------------------------------------------
# A change never acquired is censored
# ---------------------------------------------------------------------------

def test_unacquired_change_is_censored():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "walking"),
               (6, 8, "stationary", "walking"),
               (8, 10, "walking", "walking"),
               (10, 12, "walking", "walking")])
    t = L.temporal_metrics(u)
    assert t["n_truth_changes"] == 2
    # Change at 4 -> stationary never predicted before the truth moves on:
    # censored. Change at 8 -> acquired immediately (LAD 2).
    assert t["label_acquisition_delay_s"]["per_change"] == [2.0]
    assert t["label_acquisition_delay_s"]["n_acquired"] == 1
    assert t["label_acquisition_delay_s"]["n_censored"] == 1
    # No predicted changes at all (the decoder never flips either).
    assert t["n_predicted_changes"] == 0
    assert t["transition_delay_s"]["per_change"] == []
    assert t["transition_delay_s"]["signed_bias_s"] is None
    assert t["transition_delay_s"]["median_abs_s"] is None
    assert t["transition_delay_s"]["p90_abs_s"] is None
    assert t["flip_rate"]["flips"] == 0
    assert t["flip_rate"]["run_lengths_windows"] == [6]
    assert t["flip_rate"]["median_run_length_windows"] == 6.0
    # Neither change ever reaches a stable correct state.
    assert t["time_to_stable_correct_s"]["per_change"] == []
    assert t["time_to_stable_correct_s"]["median_s"] is None
    assert t["time_to_stable_correct_s"]["n_acquired"] == 0
    assert t["time_to_stable_correct_s"]["n_never"] == 2


# ---------------------------------------------------------------------------
# evaluate_head carries the temporal block (additive wiring)
# ---------------------------------------------------------------------------

def test_evaluate_head_carries_temporal_block():
    u = units([(0, 2, "walking", "walking"),
               (2, 4, "walking", "walking"),
               (4, 6, "stationary", "stationary"),
               (6, 8, "stationary", "stationary"),
               (8, 10, "stationary", "stationary")])
    rep = L.evaluate_head(u)
    t = rep["temporal"]
    assert t["n_units"] == 5
    assert t["label_acquisition_delay_s"]["median_s"] == 2.0
    assert t["time_to_stable_correct_s"]["median_s"] == 6.0
    # The pooled report keys are untouched by the addition.
    assert rep["macro_f1"] == 1.0
    assert rep["n_accepted"] == 5


# ---------------------------------------------------------------------------
# Gaps between labels (e.g. the rest between two guided bouts)
# ---------------------------------------------------------------------------

def test_a_gap_between_bouts_is_not_a_truth_change():
    # Sitting bout, 60 s rest with no labelled windows, then a walking bout.
    u = units([(0, 2, "stationary", "stationary"),
               (2, 4, "stationary", "stationary"),
               (64, 66, "walking", "walking"),
               (66, 68, "walking", "walking")])
    t = L.temporal_metrics(u)
    assert t["n_truth_changes"] == 0, "the rest is not a moment the model could react to"
    assert t["label_acquisition_delay_s"] is None
    assert t["n_predicted_changes"] == 0
    assert t["flip_rate"]["run_lengths_windows"] == [2, 2]


def test_a_flip_in_another_segment_is_not_paired_with_a_far_truth_change():
    u = units([(0, 2, "stationary", "stationary"),
               (2, 4, "walking", "walking"),        # truth change at 2, acquired at 4
               (4, 6, "walking", "walking"),
               # an hour later, constant truth with one spurious flip
               (3600, 3602, "stationary", "stationary"),
               (3602, 3604, "stationary", "walking"),
               (3604, 3606, "stationary", "stationary")])
    t = L.temporal_metrics(u)
    assert t["n_truth_changes"] == 1
    assert t["transition_delay_s"]["per_change"] == [2.0], "the far flips get no transition delay"
    assert t["flip_rate"]["flips"] == 2
