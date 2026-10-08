"""The walking-day port (gait.py) against the app's own readings.

tests/data/gait_expected.json is recorded from the app's code (GaitWindowColumns + WalkingDayReading) by
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/GaitServerMirrorTests for the invented days in
tests/data/gait_cases.json (scripts/make_gait_cases.py).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from nara_metric_insight import gait

DATA = Path(__file__).parent / "data"
CASES = json.loads((DATA / "gait_cases.json").read_text())["cases"]
RECORDED = json.loads((DATA / "gait_expected.json").read_text())["expected"]


def _result(r: gait.Reading) -> dict:
    return {"walking_seconds": r.walking_seconds, "brisk_seconds": r.brisk_seconds, "steps": r.steps,
            "cadence_spm": r.cadence_spm, "speed_mps": r.speed_mps, "stride_m": r.stride_m,
            "regularity": r.regularity, "assessed_windows": r.assessed_windows,
            "cadence_band_seconds": r.cadence_band_seconds, "hourly_seconds": r.hourly_seconds,
            "typical_speed_mps": r.typical_speed_mps,
            "bouts": [{"start": b.start, "end": b.end, "cadence_spm": b.cadence_spm, "speed_mps": b.speed_mps,
                       "steps": b.steps} for b in r.bouts]}


def _same(actual, expected, path: str) -> None:
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and set(actual) == set(expected), path
        for key in expected:
            _same(actual[key], expected[key], f"{path}.{key}")
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(actual) == len(expected), path
        for i, (a, e) in enumerate(zip(actual, expected)):
            _same(a, e, f"{path}[{i}]")
    elif expected is None:
        assert actual is None, f"{path}: {actual!r}"
    else:
        assert abs(actual - expected) <= 1e-9 * max(1.0, abs(actual), abs(expected)), f"{path}: {actual} vs {expected}"


def test_the_cases_cover_walks_pauses_seams_and_empty_days():
    assert set(RECORDED) == {c["name"] for c in CASES}, "the cases changed: re-record with the Swift test"
    walks = RECORDED["walks_pauses_and_still"]
    assert len(walks["bouts"]) >= 3 and walks["walking_seconds"] > sum(b["end"] - b["start"] for b in walks["bouts"])
    assert RECORDED["no_walking_but_assessed"]["walking_seconds"] == 0
    assert RECORDED["no_walking_but_assessed"]["assessed_windows"] > 0
    assert RECORDED["nothing_stored"]["assessed_windows"] == 0 and RECORDED["nothing_stored"]["steps"] is None


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_the_port_reproduces_the_app(case):
    days = [gait.columns(d) for d in case["days"]]
    assert all(d is not None for d in days)
    _same(_result(gait.reading(days, case["from"], case["to"])), RECORDED[case["name"]], case["name"])


def test_malformed_columns_are_refused():
    good = CASES[0]["days"][0]
    assert gait.columns(dict(good, format="gait-windows-2")) is None
    assert gait.columns(dict(good, ds=good["ds"][:-1])) is None
    assert gait.columns(dict(good, h=0)) is None
    assert gait.columns("not a dict") is None
