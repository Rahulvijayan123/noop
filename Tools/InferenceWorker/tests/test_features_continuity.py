"""Tests for the worker-continuity sleep-feature modules.

Covers every check named for spec sections 4 (shared rules), 5 A1 (sleep
continuity), A2 (sleep architecture) and A8 (SleepECG shadow) that this worker
owns: all-wake, uninterrupted sleep, terminal wake, split sleep with a known
wake seam, unknown gap, nap, midnight crossing, user-edited partial epoch, the
continuity summary gate, YASA-stat fidelity, constant/alternating/stochastic
entropy behaviour, occupancy entropy distinctness, thin-data entropy, UNS and
gap transition exclusions, REM/deep latency from onset, deep front-loading,
REM late fraction, third coverage reporting, and the SleepECG comparison.

Every block must carry finite-or-absent numeric leaves, a status in the
contract's set, and machine-readable reasons; that invariant is asserted across
all fixtures.
"""

from __future__ import annotations

import json
import math
from typing import Any, Sequence

import numpy as np
import pytest

from frwhoop_inference.features import architecture, continuity, sleepecg_shadow
from frwhoop_inference.features.config import SleepFeaturesConfig
from frwhoop_inference.features.contract import (
    BeatIn,
    BreathIn,
    BreathRunIn,
    HistoryDayIn,
    HistoryMinuteIn,
    HrSampleIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
    TempSampleIn,
)
from frwhoop_inference.features.timeline import build_timeline

T = 1_700_000_000  # fixed unix epoch; all offsets below are relative to this

CFG = SleepFeaturesConfig()
STATUSES = {"available", "partial", "withheld", "not_applicable"}


def req(capabilities: dict | None = None) -> SleepFeaturesRequest:
    return SleepFeaturesRequest(
        context=SleepFeaturesContext(
            user_id="u", device_id="d", day="2026-10-19",
            iana_timezone="America/New_York", input_revision=1,
            interval_start=T, interval_end=T + 6 * 3600,
            history_revision_digest=None),
        nights=(), hr=(), temp=(), beats=(), breaths=(), breath_runs=(),
        history_days=(), capabilities=capabilities or {},
    )


def night(
    segments: Sequence[tuple[str, int, int]],
    *,
    start: int = T,
    end: int | None = None,
    is_nap: bool = False,
    user_edited: bool = False,
    night_id: str = "n1",
) -> NightIn:
    """Night from absolute (stage, start, end) segments in unix seconds."""
    if end is None:
        end = max(seg[2] for seg in segments)
    stages = tuple(StageSegmentIn(int(s), int(e), st) for st, s, e in segments)
    return NightIn(night_id=night_id, start=start, end=end, is_nap=is_nap,
                   user_edited=user_edited, stages=stages)


def epoch_run(stage: str, n: int, offset: int) -> tuple[str, int, int]:
    """A (stage, start, end) segment of ``n`` 30 s epochs at ``offset``."""
    return (stage, offset, offset + n * 30)


def build(segments, **kwargs):
    return build_timeline(night(segments, **kwargs))


def continuity_block(segments, **kwargs) -> dict:
    tl = build(segments, **kwargs)
    return continuity.compute_night(req(), tl, CFG)


def architecture_block(segments, **kwargs) -> dict:
    tl = build(segments, **kwargs)
    return architecture.compute_night(req(), tl, CFG)


# ---------------------------------------------------------------------------
# JSON-finite invariant (spec 4.1 / contract §2)
# ---------------------------------------------------------------------------


def _leaves(block: dict, path: str = "") -> list[tuple[str, Any]]:
    out: list[tuple[str, Any]] = []
    for key, value in block.items():
        here = f"{path}.{key}" if path else key
        if isinstance(value, dict):
            out.extend(_leaves(value, here))
        elif isinstance(value, (list, tuple)):
            for i, item in enumerate(value):
                if isinstance(item, dict):
                    out.extend(_leaves(item, f"{here}[{i}]"))
                elif item is not None:
                    out.append((f"{here}[{i}]", item))
        elif value is not None:
            out.append((here, value))
    return out


def _numeric_leaves(block: dict) -> list[tuple[str, Any]]:
    return [(p, v) for p, v in _leaves(block)
            if isinstance(v, (int, float)) and not isinstance(v, bool)]


@pytest.mark.parametrize("segments", [
    [epoch_run("wake", 120, T)],
    [epoch_run("light", 120, T)],
    [epoch_run("wake", 4, T), epoch_run("light", 20, T + 120),
     epoch_run("deep", 30, T + 720), epoch_run("wake", 4, T + 1620),
     epoch_run("rem", 20, T + 1740), epoch_run("light", 42, T + 2340)],
    [epoch_run("light", 20, T), epoch_run("deep", 20, T + 780)],  # interior gap
])
def test_all_numeric_leaves_finite(segments):
    tl = build(segments)
    for block in (continuity.compute_night(req(), tl, CFG),
                  architecture.compute_night(req(), tl, CFG)):
        for path, value in _numeric_leaves(block):
            assert isinstance(value, (int, float)), (path, value)
            assert math.isfinite(float(value)), f"non-finite leaf at {path}: {value}"
        assert block["status"] in STATUSES or block["status"] == "not_run"
        assert isinstance(block["reasons"], list)


# ---------------------------------------------------------------------------
# A1: sleep continuity and fragmentation
# ---------------------------------------------------------------------------


def test_all_wake_night_nulls_and_valid_zeros():
    block = continuity_block([epoch_run("wake", 120, T)])
    assert block["tib_min"] == 60.0
    assert block["tst_min"] == 0.0
    assert block["sleep_efficiency_pct"] == 0.0
    assert block["sol_min"] is None
    assert block["sol_5min_run_min"] is None
    assert block["spt_min"] is None
    assert block["waso_min"] is None
    assert block["terminal_wake_min"] is None
    assert block["sleep_maintenance_efficiency_pct"] is None
    # Zero events on a complete trace is a VALID 0.
    assert block["recurrent_awakenings"] == 0
    assert block["recurrent_awakenings_60s_plus"] == 0
    assert block["recurrent_awakening_index_per_h"] is None
    assert block["return_to_sleep_latency_median_min"] is None
    assert block["awakening_duration"]["count"] == 0
    assert block["awakening_duration"]["median_min"] is None
    assert block["sleep_bouts"]["count"] == 0
    assert block["longest_sleep_bout_min"] is None
    assert block["mean_sleep_bout_min"] is None
    # No sleep -> null onset/latency metrics.
    assert block["sfi_yasa_per_h"] is None
    assert block["status"] == "partial"
    assert "no_sleep" in block["reasons"]


def test_uninterrupted_sleep_valid_zero_events():
    block = continuity_block([epoch_run("light", 40, T), epoch_run("deep", 40, T + 1200)])
    assert block["tst_min"] == 40.0
    assert block["waso_min"] == 0.0
    assert block["terminal_wake_min"] == 0.0
    assert block["recurrent_awakenings"] == 0  # valid zero
    assert block["recurrent_awakenings_60s_plus"] == 0
    assert block["recurrent_awakening_index_per_h"] == 0.0
    assert block["awakening_duration"]["count"] == 0
    assert block["awakening_duration"]["median_min"] is None
    assert block["sol_min"] == 0.0
    assert block["sol_5min_run_min"] == 0.0
    assert block["sleep_bouts"]["count"] == 1
    assert block["longest_sleep_bout_min"] == 40.0
    assert block["mean_sleep_bout_min"] == 40.0
    assert block["sfi_yasa_per_h"] == 0.0
    assert block["status"] == "available"
    assert block["reasons"] == []


def test_terminal_wake_counts_in_yasa_sfi_not_recurrent_index():
    block = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 40, T + 120),
        epoch_run("wake", 6, T + 1320),
    ])
    # Sleep ends at f = T+1320; the trailing wake is terminal, not internal.
    assert block["terminal_wake_min"] == 3.0
    assert block["waso_min"] == 0.0
    assert block["recurrent_awakenings"] == 0
    assert block["recurrent_awakening_index_per_h"] == 0.0
    assert block["sleep_bouts"]["count"] == 1
    # YASA 0.8.0 SFI counts the sleep->WAKE transition incl. the terminal one.
    assert block["sfi_yasa_per_h"] > 0.0
    assert block["status"] == "available"


def test_split_sleep_known_wake_seam():
    block = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 30, T + 120),
        epoch_run("wake", 4, T + 1020),   # 2.0 min internal wake (>= 60 s)
        epoch_run("deep", 30, T + 1140),
        epoch_run("wake", 1, T + 2040),   # 0.5 min internal wake (< 60 s)
        epoch_run("rem", 20, T + 2070),
        epoch_run("light", 10, T + 2670),
    ])
    tst = (30 + 30 + 20 + 10) * 30 / 60.0  # 45.0 min
    assert block["tst_min"] == 45.0
    assert block["recurrent_awakenings"] == 2
    assert block["recurrent_awakenings_60s_plus"] == 1
    assert block["recurrent_awakening_index_per_h"] == pytest.approx(2.0 / (45.0 / 60.0), abs=0.001)
    assert block["return_to_sleep_latency_median_min"] == 1.25
    assert block["awakening_duration"]["count"] == 2
    assert block["awakening_duration"]["median_min"] == 1.25
    assert block["awakening_duration"]["p90_min"] == pytest.approx(1.85, rel=1e-6)
    assert block["awakening_duration"]["max_min"] == 2.0
    assert block["sleep_bouts"]["count"] == 3


def test_awakening_60s_boundary():
    block = continuity_block([
        epoch_run("light", 10, T),
        epoch_run("wake", 2, T + 300),   # exactly 60 s -> counted in 60 s+
        epoch_run("light", 10, T + 360),
        epoch_run("wake", 1, T + 660),   # 30 s -> not in 60 s+
        epoch_run("light", 10, T + 690),
    ])
    assert block["recurrent_awakenings"] == 2
    assert block["recurrent_awakenings_60s_plus"] == 1


def test_sol_5min_requires_300s_run():
    block = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 6, T + 120),   # 3.0 min run < 300 s -> not qualifying
        epoch_run("wake", 2, T + 300),
        epoch_run("deep", 40, T + 360),   # 20.0 min run -> qualifies
    ])
    assert block["sol_min"] == 2.0
    assert block["sol_5min_run_min"] == 6.0  # T+360 - T
    assert block["recurrent_awakenings"] == 1  # the 2-epoch wake seam


def test_unknown_gap_makes_block_partial():
    block = continuity_block([
        epoch_run("light", 20, T),
        epoch_run("deep", 20, T + 780),   # 180 s uncovered hole between
    ])
    tl = build([epoch_run("light", 20, T), epoch_run("deep", 20, T + 780)])
    assert tl.known_fraction == pytest.approx(1200.0 / 1380.0, rel=1e-9)
    assert block["tst_min"] == pytest.approx((600 + 600) / 60.0, rel=1e-9)
    assert block["status"] == "partial"
    assert "unresolved_internal_gap" in block["reasons"]
    assert "low_timeline_coverage" in block["reasons"]


def test_nap_night_still_computed():
    block = continuity_block(
        [epoch_run("light", 30, T), epoch_run("deep", 30, T + 900)],
        is_nap=True,
    )
    assert block["tib_min"] == 30.0
    assert block["tst_min"] == 30.0
    assert block["sleep_bouts"]["count"] == 1
    assert block["status"] == "available"


def test_midnight_crossing():
    # 2026-10-19 23:30 UTC -> 2026-10-20 02:30 UTC (crosses midnight). The
    # timeline is anchored in absolute unix seconds, so a midnight crossing is
    # just another night: full coverage keeps the block available.
    start = T + 7200
    end = T + 7200 + 3 * 3600
    n = night([("light", start, end)], start=start, end=end)
    tl = build_timeline(n)
    block = continuity.compute_night(req(), tl, CFG)
    assert block["tib_min"] == 180.0
    assert block["tst_min"] == 180.0
    assert block["status"] == "available"


def test_user_edited_partial_first_epoch_keeps_true_duration():
    # First epoch only 20 s covered (wake from T+10), then light/deep. The
    # partial epoch must keep its ACTUAL 20 s in the minute metrics, not be
    # padded to a full 30 s epoch.
    block = continuity_block(
        [epoch_run("wake", 1, T + 10), epoch_run("light", 59, T + 30),
         epoch_run("deep", 60, T + 1800)],
        user_edited=True,
    )
    tl = build([epoch_run("wake", 1, T + 10), epoch_run("light", 59, T + 30),
                epoch_run("deep", 60, T + 1800)], user_edited=True)
    assert tl.labels[0] == "wake"       # 20 s wake majority
    assert tl.fully_observed[0] is False
    # TST = exact intersection: light 1770 s + deep 1800 s = 3570 s = 59.5 min.
    assert block["tst_min"] == pytest.approx(59.5, abs=1e-9)
    assert block["tib_min"] == 60.0
    assert block["sol_min"] == 0.5      # first sleep epoch starts at T+30
    assert block["sleep_efficiency_pct"] == pytest.approx(99.17, abs=0.01)
    assert block["waso_min"] == 0.0     # the 10 s wake is before s, not in [s,f)
    assert block["status"] == "available"


def test_continuity_gate_unobserved_onset_edge():
    # First 3 epochs uncovered -> first label is UNS.
    block = continuity_block([
        epoch_run("light", 20, T + 90),
        epoch_run("deep", 40, T + 690),
    ])
    assert block["status"] == "partial"
    assert "unobserved_onset_edge" in block["reasons"]


def test_yasa_stats_verbatim_keys_and_finite():
    block = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 30, T + 720),
        epoch_run("wake", 4, T + 1620),
        epoch_run("rem", 20, T + 1740),
        epoch_run("light", 42, T + 2340),
    ])
    stats = block["yasa_stats"]
    for key in ("TIB", "SPT", "WASO", "TST", "SE", "SME", "SFI", "SOL", "SOL_5min",
                "Lat_REM", "WAKE", "LIGHT", "DEEP", "REM"):
        assert key in stats
    for value in stats.values():
        assert value is None or isinstance(value, (int, float))
        if value is not None:
            assert math.isfinite(float(value))
    # YASA's own numbers, kept verbatim.
    assert stats["TIB"] == 60.0
    assert stats["TST"] == 56.0
    assert stats["SPT"] == 58.0
    assert stats["Lat_REM"] == 29.0  # YASA Lat_REM is from recording start


def test_yasa_stats_no_sleep_nan_rendered_null():
    block = continuity_block([epoch_run("wake", 20, T)])
    stats = block["yasa_stats"]
    for value in stats.values():
        assert value is None or (isinstance(value, (int, float))
                                 and math.isfinite(float(value)))
    assert stats["SOL"] is None
    assert stats["SFI"] is None


def test_sfi_and_recurrent_index_are_distinct():
    # Terminal wake: YASA SFI counts it, the recurrent index must not.
    block = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 40, T + 120),
        epoch_run("wake", 6, T + 1320),
    ])
    assert block["sfi_yasa_per_h"] > 0.0
    assert block["recurrent_awakening_index_per_h"] == 0.0


def test_sol_5min_is_ours_not_yasa_when_partial_epoch():
    # First epoch is only 20 s of light (majority light, not fully observed).
    # The spec's own SOL_5min uses fully-observed runs only (run starts at
    # epoch 1 -> 0.5 min) while YASA's SOL_5min counts the partial epoch as a
    # full epoch (run starts at epoch 0 -> 0.0 min). Both keys stay distinct.
    block = continuity_block(
        [epoch_run("light", 1, T + 10), epoch_run("deep", 60, T + 30)],
        user_edited=True,
    )
    assert block["sol_min"] == 0.0          # canonical s = first sleep epoch start
    assert block["sol_5min_run_min"] == 0.5
    assert block["yasa_stats"]["SOL_5min"] == 0.0
    assert block["sol_5min_run_min"] != block["yasa_stats"]["SOL_5min"]


# ---------------------------------------------------------------------------
# A2: sleep architecture dynamics
# ---------------------------------------------------------------------------


def test_constant_stage_zero_entropy():
    block = architecture_block([epoch_run("wake", 120, T)])
    assert block["eligible_pairs"] == 119
    assert block["entropy_rate_bits_per_transition"] == 0.0
    assert block["transition_counts"][0][0] == 119  # self transitions counted
    # No sleep on the night: latency/fraction metrics are null -> partial.
    assert block["status"] == "partial"
    assert "no_sleep" in block["reasons"]


def test_alternating_two_state_zero_entropy_rate():
    # W,L,W,L,... deterministic transitions -> zero entropy rate.
    segs = []
    for i in range(60):
        off = T + i * 60
        segs.append(epoch_run("wake", 1, off))
        segs.append(epoch_run("light", 1, off + 30))
    block = architecture_block(segs)
    assert block["eligible_pairs"] == 119
    assert block["entropy_rate_bits_per_transition"] == 0.0
    # The occupancy entropy is a DIFFERENT statistic (W=60, L=60 -> 1 bit).
    labels = []
    for _ in range(60):
        labels += ["wake", "light"]
    assert architecture.occupancy_entropy_bits(labels) == pytest.approx(1.0, abs=1e-9)
    assert architecture.occupancy_entropy_bits(labels) != block["entropy_rate_bits_per_transition"]


def test_stochastic_mixed_positive_entropy():
    # Deterministic but MIXED row transitions -> each row with >1 outgoing
    # probabilities contributes positive row entropy.
    seq = ["wake", "light", "wake", "deep", "light", "rem", "wake", "light",
           "deep", "light", "wake", "rem", "deep", "light", "wake", "deep",
           "rem", "light", "wake", "deep", "light", "rem", "wake", "light",
           "deep", "wake", "rem", "light", "deep", "light"] * 4  # 120 epochs
    segs = []
    off = T
    for label in seq:
        segs.append(epoch_run(label, 1, off))
        off += 30
    block = architecture_block(segs)
    assert block["eligible_pairs"] == 119
    assert block["entropy_rate_bits_per_transition"] > 0.0
    # And it must not be confused with occupancy entropy.
    occ = architecture.occupancy_entropy_bits(seq)
    assert occ > 0.0
    assert not math.isclose(occ, block["entropy_rate_bits_per_transition"], abs_tol=1e-9)


def test_thin_data_entropy_null():
    block = architecture_block([epoch_run("wake", 40, T), epoch_run("light", 20, T + 1200)])
    assert block["eligible_pairs"] == 59
    assert block["entropy_rate_bits_per_transition"] is None
    assert "thin_data" in block["reasons"]
    assert block["status"] == "partial"


def test_transition_exclusions_uns_and_gap():
    tl = build([epoch_run("light", 20, T), epoch_run("deep", 20, T + 780)])
    block = architecture.compute_night(req(), tl, CFG)
    # 20 light + 20 deep fully-observed epochs: 19+19 eligible pairs; the 7
    # pairs that straddle or lie inside the 180 s gap are gap-excluded (the
    # pair at the gap entry crosses into it, so it is a gap pair, not an UNS
    # pair).
    assert block["eligible_pairs"] == 38
    assert block["excluded_pairs_gap"] == 7
    assert block["excluded_pairs_uns"] == 0
    assert block["transition_counts"][1][1] == 19   # light self-transitions
    assert block["transition_counts"][2][2] == 19   # deep self-transitions


def test_unscored_epochs_not_crossed_and_uns_excluded():
    # A single 30 s unscored hole (not a >60 s gap): the hole epochs are UNS.
    tl = build([epoch_run("light", 20, T), epoch_run("deep", 20, T + 630)])
    block = architecture.compute_night(req(), tl, CFG)
    # Unresolved gap needs >60 s, so a 30 s hole is not a gap; its pair is UNS.
    assert block["excluded_pairs_uns"] > 0
    assert block["excluded_pairs_gap"] == 0
    assert block["eligible_pairs"] == 38


def test_null_row_for_unobserved_stage():
    block = architecture_block([epoch_run("wake", 30, T), epoch_run("light", 90, T + 900)])
    probs = block["transition_probabilities"]
    assert probs[2] == [None, None, None, None]  # deep unobserved -> null row
    assert probs[3] == [None, None, None, None]  # rem unobserved -> null row
    assert probs[0] is not None and all(v is not None for v in probs[0])
    assert sum(block["row_weights"]) == pytest.approx(1.0, rel=1e-9)


def test_bout_stats_per_stage():
    block = architecture_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 30, T + 720),
        epoch_run("wake", 4, T + 1620),
        epoch_run("rem", 20, T + 1740),
        epoch_run("light", 42, T + 2340),
    ])
    assert block["bouts"]["wake"]["count"] == 2
    assert block["bouts"]["wake"]["total_min"] == 4.0
    assert block["bouts"]["light"]["count"] == 2
    assert block["bouts"]["light"]["total_min"] == 31.0
    assert block["bouts"]["light"]["median_min"] == 15.5
    assert block["bouts"]["deep"]["count"] == 1
    assert block["bouts"]["deep"]["max_min"] == 15.0
    assert block["bouts"]["rem"]["count"] == 1
    assert block["bouts"]["rem"]["total_min"] == 10.0


def test_rem_latency_from_onset_not_recording_start():
    block = architecture_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 20, T + 720),
        epoch_run("rem", 10, T + 1320),
        epoch_run("light", 30, T + 1620),
    ])
    # s = T+120; first REM at T+1320 -> 20 min from onset.
    assert block["rem_latency_from_onset_min"] == 20.0
    # YASA Lat_REM = 1320/60 = 22 min from recording start -> must differ.
    cblock = continuity_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 20, T + 720),
        epoch_run("rem", 10, T + 1320),
        epoch_run("light", 30, T + 1620),
    ])
    assert cblock["yasa_stats"]["Lat_REM"] == 22.0
    assert block["rem_latency_from_onset_min"] != cblock["yasa_stats"]["Lat_REM"]


def test_deep_latency_from_onset():
    block = architecture_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 20, T + 720),
        epoch_run("light", 20, T + 1320),
    ])
    assert block["deep_latency_from_onset_min"] == 10.0  # (720-120)/60


def test_deep_front_load_fraction():
    # [s,f) = [T+120, T+2820) -> 2700 s; third = 900 s.
    # First third [T+120, T+1020): deep runs [T+720, T+1020) -> 300 s of deep.
    # Total deep = 600 s (20 epochs). Fraction = 300/600 = 0.5.
    block = architecture_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 20, T + 720),
        epoch_run("rem", 20, T + 1320),
        epoch_run("light", 30, T + 1920),
    ])
    assert block["deep_front_load_fraction"] == pytest.approx(0.5, rel=1e-6)
    assert block["sleep_period_third_known_fraction"] == [1.0, 1.0, 1.0]


def test_rem_late_fraction():
    # [s,f) = [T+120, T+2700) -> 2580 s; third = 860 s.
    # Final third [T+1840, T+2700): rem = [T+1320, T+1920) -> 80 s of rem.
    # Total rem = 600 s. Fraction = 80/600 = 0.1333.
    block = architecture_block([
        epoch_run("wake", 4, T),
        epoch_run("light", 20, T + 120),
        epoch_run("deep", 20, T + 720),
        epoch_run("rem", 20, T + 1320),
        epoch_run("light", 26, T + 1920),
    ])
    # Module rounds the fraction to 4 decimals.
    assert block["rem_late_fraction"] == pytest.approx(80.0 / 600.0, abs=1e-4)


def test_thirds_known_coverage_reported():
    # The 180 s hole sits in the FIRST third of [s,f), so only that third's
    # known fraction drops below 1 (unknown time stays in the axis and its
    # coverage is reported).
    block = architecture_block([
        epoch_run("light", 20, T),          # [T, T+600)
        epoch_run("deep", 20, T + 780),     # hole [T+600, T+780)
        epoch_run("rem", 20, T + 1380),
        epoch_run("light", 20, T + 1980),
    ])
    thirds = block["sleep_period_third_known_fraction"]
    assert len(thirds) == 3
    assert all(v is not None for v in thirds)
    assert thirds[0] < 1.0
    assert thirds[1] == 1.0
    assert thirds[2] == 1.0


def test_no_rem_and_no_deep_reasons():
    block = architecture_block([epoch_run("wake", 4, T), epoch_run("light", 116, T + 120)])
    assert block["rem_latency_from_onset_min"] is None
    assert block["deep_latency_from_onset_min"] is None
    assert "no_rem" in block["reasons"]
    assert "no_deep" in block["reasons"]


# ---------------------------------------------------------------------------
# A8: SleepECG shadow comparison
# ---------------------------------------------------------------------------


def test_compare_perfect_agreement():
    v2 = ["wake", "light", "deep", "rem"] * 20
    sc = ["wake", "nrem", "nrem", "rem"] * 20
    report = sleepecg_shadow.compare(v2, sc)
    assert report["epochs_compared"] == 80
    assert report["agreement_pct"] == 100.0
    assert report["disagreement_near_onset_offset_pct"] == 0.0
    assert report["agreement_by_label"]["wake"] == 100.0
    assert report["agreement_by_label"]["nrem"] == 100.0
    assert report["agreement_by_label"]["rem"] == 100.0
    assert report["status"] == "available"


def test_compare_common_label_space_light_deep_map_to_nrem():
    # V2 light/deep -> NREM; wake/rem unchanged.
    v2 = ["wake", "light", "deep", "rem"]
    sc = ["wake", "nrem", "nrem", "rem"]
    report = sleepecg_shadow.compare(v2, sc)
    assert report["agreement_pct"] == 100.0
    v2_dist = report["v2_distribution"]
    assert v2_dist["wake"] == pytest.approx(0.25, abs=1e-6)
    assert v2_dist["nrem"] == pytest.approx(0.5, abs=1e-6)
    assert v2_dist["rem"] == pytest.approx(0.25, abs=1e-6)


def test_compare_disagreements_and_near_onset_offset():
    v2 = ["light"] * 60          # all NREM
    sc = ["nrem"] * 10 + ["rem"] * 5 + ["nrem"] * 40 + ["rem"] * 5
    report = sleepecg_shadow.compare(v2, sc)
    assert report["epochs_compared"] == 60
    assert report["agreement_pct"] == pytest.approx(100.0 * 50 / 60, abs=0.01)
    assert report["disagreement_near_onset_offset_pct"] == pytest.approx(
        100.0 * 10 / 10, rel=1e-6)  # both disagreement blocks are within 30 epochs
    assert report["agreement_by_label"]["nrem"] == pytest.approx(100.0 * 50 / 60, abs=0.01)
    # Disagreement does not claim a winner: both distributions are reported.
    assert report["sleepecg_distribution"]["rem"] == pytest.approx(10.0 / 60.0, abs=1e-4)


def test_compare_excludes_uns_epochs():
    v2 = ["wake", "uns", "light", "deep", "rem", "uns"]
    sc = ["wake", "nrem", "nrem", "nrem", "rem", "wake"]
    report = sleepecg_shadow.compare(v2, sc)
    assert report["epochs_compared"] == 4  # uns epochs excluded
    assert report["agreement_pct"] == 100.0


def test_compare_length_mismatch():
    v2 = ["wake", "light", "deep"]
    sc = ["wake", "nrem"]
    report = sleepecg_shadow.compare(v2, sc)
    assert "length_mismatch" in report["reasons"]
    assert report["epochs_compared"] == 2
    assert report["agreement_pct"] == 100.0


def test_compare_no_common_valid_epochs():
    v2 = ["uns"] * 10
    sc = ["wake"] * 10
    report = sleepecg_shadow.compare(v2, sc)
    assert report["epochs_compared"] == 0
    assert report["agreement_pct"] is None
    assert report["status"] == "partial"
    assert "no_common_valid_epochs" in report["reasons"]


def test_compute_not_run_without_candidate_result():
    report = sleepecg_shadow.compute(req(), CFG)
    assert report["status"] == "not_run"
    assert report["reason"] == "candidate_lane_result_not_provided"
    assert "candidate_lane_result_not_provided" in report["reasons"]
    assert report["epochs_compared"] is None
    assert report["agreement_pct"] is None
    assert report["weights_revision"] is None


def test_compute_with_sleepecg_block_runs_compare():
    v2 = ["wake", "light", "deep", "rem"] * 20
    sc = ["wake", "nrem", "nrem", "rem"] * 20
    caps = {"sleepecg_shadow": {
        "ready": True,
        "reason": None,
        "weights_revision": "wrn-gru-mesa-1",
        "report": {"v2_labels": v2, "sleepecg_labels": sc},
    }}
    report = sleepecg_shadow.compute(req(caps), CFG)
    assert report["status"] == "available"
    assert report["epochs_compared"] == 80
    assert report["agreement_pct"] == 100.0
    assert report["weights_revision"] == "wrn-gru-mesa-1"


def test_compute_block_without_report_is_not_run():
    caps = {"sleepecg_shadow": {"ready": False, "reason": "lane_not_configured"}}
    report = sleepecg_shadow.compute(req(caps), CFG)
    assert report["status"] == "not_run"
    assert report["reason"] == "candidate_lane_result_not_provided"


def test_sol_5min_null_without_persistent_run_is_partial():
    # A 3-minute nap has sleep but no uninterrupted >= 300 s run: the
    # persistent-sleep latency is null with a reason, so the block is partial.
    block = continuity_block([epoch_run("light", 6, T)], end=T + 180)
    assert block["sol_min"] == 0.0
    assert block["sol_5min_run_min"] is None
    assert block["status"] == "partial"
    assert "no_persistent_sleep_run" in block["reasons"]


def test_entropy_threshold_boundary_100_pairs():
    # cfg.entropy_min_pairs == 100: 100 eligible pairs compute an entropy,
    # 99 do not.
    segs = [epoch_run("wake", 50, T), epoch_run("light", 51, T + 1500)]  # 101 epochs
    block = architecture_block(segs)
    assert block["eligible_pairs"] == 100
    assert block["entropy_rate_bits_per_transition"] is not None
    assert "thin_data" not in block["reasons"]

    segs = [epoch_run("wake", 49, T), epoch_run("light", 51, T + 1470)]  # 100 epochs
    block = architecture_block(segs)
    assert block["eligible_pairs"] == 99
    assert block["entropy_rate_bits_per_transition"] is None
    assert "thin_data" in block["reasons"]
