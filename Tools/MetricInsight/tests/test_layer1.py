"""The Layer 1 port (layer1.py) against the app's own results.

tests/data/layer1_expected.json is recorded from the app's code (LongitudinalBaseline.evaluate + vitalVerdict) by
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LayerOneServerMirrorTests for the invented tapes in
tests/data/layer1_cases.json (scripts/make_layer1_cases.py). That Swift test fails when Layer 1 changes; this one fails
until the port follows.
"""

from __future__ import annotations

import json
import math
from datetime import date, timedelta
from pathlib import Path

import pytest

from nara_metric_insight import layer1

DATA = Path(__file__).parent / "data"
CASES = json.loads((DATA / "layer1_cases.json").read_text())["cases"]
RECORDED = json.loads((DATA / "layer1_expected.json").read_text())


def _result(case: dict) -> dict:
    spec = layer1.SERIES[case["series"]]
    observations = {date.fromisoformat(day): layer1.observation(value, spec) for day, value in case["nights"]}
    ev = layer1.evaluate(observations, date.fromisoformat(case["as_of"]), case["series"])
    verdict = layer1.verdict(ev)

    def copy(c: layer1.Copy | None) -> dict | None:
        return None if c is None else {"center": c.center, "spread": c.spread, "center_display": c.center_display,
                                       "lo": c.band_lo_display, "hi": c.band_hi_display, "n": c.n, "held": c.held}

    return {"today": ev.today, "show7": ev.show7, "show_long": ev.show_long, "established_long": ev.established_long,
            "stale": ev.stale, "n7": ev.n7, "n_long": ev.n_long, "n_learn": ev.n_learn, "trust7": ev.trust7,
            "trust_long": ev.trust_long, "k_used": ev.k_used, "z7": ev.z7, "z_long": ev.z_long,
            "slope_usable": ev.slope_usable, "regime_shift": ev.regime_shift, "p_change": ev.p_change,
            "expected_long": ev.expected_long, "copy7": copy(ev.copy7), "copy_long": copy(ev.copy_long),
            "verdict": {"state": verdict.state, "value": verdict.value, "lo": verdict.band_lo, "hi": verdict.band_hi,
                        "from_week": verdict.from_week}}


def _same(actual, expected, path: str) -> None:
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and set(actual) == set(expected), path
        for key in expected:
            _same(actual[key], expected[key], f"{path}.{key}")
    elif expected is None or isinstance(expected, (bool, str)):
        assert actual == expected and type(actual) is type(expected), f"{path}: {actual!r} vs {expected!r}"
    else:
        assert isinstance(actual, (int, float)) and not isinstance(actual, bool), f"{path}: {actual!r}"
        assert abs(actual - expected) <= 1e-9 * max(1.0, abs(actual), abs(expected)), f"{path}: {actual} vs {expected}"


def test_the_recording_is_of_this_param_set_and_these_cases():
    assert RECORDED["param_set"] == layer1.PARAM_SET
    assert set(RECORDED["expected"]) == {c["name"] for c in CASES}, "the cases changed: re-record with the Swift test"


def test_the_cases_reach_every_verdict_and_the_slow_paths():
    expected = RECORDED["expected"].values()
    assert {e["verdict"]["state"] for e in expected} == {layer1.IN_RANGE, layer1.OFF, layer1.LEARNING,
                                                       layer1.NO_READING}
    assert any(e["slope_usable"] for e in expected) and any(not e["slope_usable"] for e in expected)
    assert any(e["regime_shift"] and e["copy_long"]["held"] for e in expected)
    assert any(e["verdict"]["from_week"] for e in expected) and any(
        e["verdict"]["state"] in (layer1.IN_RANGE, layer1.OFF) and not e["verdict"]["from_week"] for e in expected)
    assert any(e["copy_long"] and e["k_used"] != layer1.SERIES[c["series"]].k_band
               for c, e in ((c, RECORDED["expected"][c["name"]]) for c in CASES))


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_the_port_reproduces_the_app(case):
    _same(_result(case), RECORDED["expected"][case["name"]], case["name"])


def test_hosted_values_are_read_as_the_phone_reads_them():
    rows = {date(2026, 10, 1): {"resting_hr_bpm": 52.5}, date(2026, 10, 2): {"resting_hr_bpm": 52.49},
            date(2026, 10, 3): {"resting_hr_bpm": None}, date(2026, 10, 4): {"resting_hr_bpm": float("nan")},
            date(2026, 10, 5): {"resting_hr_bpm": True}, date(2026, 10, 6): {"resting_hr_bpm": 25},
            date(2026, 10, 7): {}}
    obs = layer1.native_values(rows, "sleep_rhr")
    # Resting HR is an integer on the phone (Int(value.rounded()): half away from zero).
    assert obs[date(2026, 10, 1)] == layer1.Observation(53.0, layer1.OK)
    assert obs[date(2026, 10, 2)] == layer1.Observation(52.0, layer1.OK)
    # No value, a value that is not a finite number, or a boolean: a missing night, never zero.
    for day in (3, 4, 5, 7):
        assert obs[date(2026, 10, day)] == layer1.Observation(None, layer1.MISSING)
    # Outside the plausible range: kept as low quality, never trained on.
    assert obs[date(2026, 10, 6)] == layer1.Observation(25.0, layer1.LOW_QUALITY)
    hrv = layer1.native_values({date(2026, 10, 1): {"hrv_rmssd_ms": 61.37}}, "sleep_hrv_ln")
    assert hrv[date(2026, 10, 1)] == layer1.Observation(61.37, layer1.OK)  # HRV is not rounded


def test_nights_after_the_scored_night_change_nothing():
    case = next(c for c in CASES if c["name"] == "rhr_mid_tape")
    spec = layer1.SERIES["sleep_rhr"]
    observations = {date.fromisoformat(d): layer1.observation(v, spec) for d, v in case["nights"]}
    as_of = date.fromisoformat(case["as_of"])
    cut = {d: o for d, o in observations.items() if d <= as_of}
    assert layer1.evaluate(observations, as_of, "sleep_rhr") == layer1.evaluate(cut, as_of, "sleep_rhr")
    later = max(observations) + timedelta(days=30)
    assert layer1.evaluate({}, later, "sleep_rhr").copy_long is None
    assert math.isclose(layer1.SERIES["sleep_hrv_ln"].alpha, 2 / 11)


def test_a_jobs_history_evaluates_each_series_and_night_once():
    rows = {date(2026, 10, 6) - timedelta(days=i): {"resting_hr_bpm": 50 + i % 3} for i in range(40)}
    history = layer1.History(rows)
    first = layer1.evaluate_rows(history, date(2026, 10, 6), "sleep_rhr")
    assert layer1.evaluate_rows(history, date(2026, 10, 6), "sleep_rhr") is first
    assert set(history.evaluations) == {("sleep_rhr", date(2026, 10, 6))}
    assert first == layer1.evaluate_rows(dict(rows), date(2026, 10, 6), "sleep_rhr")  # a plain dict: no memo
