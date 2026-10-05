"""HRV ``production.runs.v1`` tests.

Spec section 8 HRV row: clean beats; equal same-second intervals; ms/seconds
errors; dropped beat; rejected beat; duplicate burst; long gap; sparse night;
independent reference proves valid-pair RMSSD and withholding.
"""

from __future__ import annotations

import pytest

from conftest import ORACLE, hrv_body, iso
from frwhoop_inference.contract import (
    Beat,
    ContractError,
    HrvInput,
    Window,
    WithheldReason,
    parse_request,
    reference_valid_pair_rmssd,
)
from frwhoop_inference.providers.hrv import (
    DEFAULT_TUNING,
    HrvProductionProvider,
    HrvTuning,
    analyze_window,
    dedup_by_observation_identity,
)


# --------------------------------------------------------------------------
# Oracle agreement
# --------------------------------------------------------------------------


@pytest.mark.parametrize("name", sorted(ORACLE))
def test_fixture_matches_independent_oracle(fixtures, name):
    """Every research fixture must reproduce the published oracle exactly."""
    fixture = fixtures[name]
    expected_value, expected_pairs, expected_clean = ORACLE[name]
    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_clean == expected_clean, name
    assert outcome.valid_pairs == expected_pairs, name
    if expected_value is None:
        assert outcome.rmssd is None
        assert outcome.withheld_reason is not None
    else:
        assert outcome.rmssd is not None
        assert outcome.rmssd == pytest.approx(expected_value, abs=5e-4)
    if name == "T7_short_run":
        assert outcome.withheld_reason == WithheldReason.INSUFFICIENT_COVERAGE.value
        assert outcome.withheld_detail == "insufficient_clean_beats"


# --------------------------------------------------------------------------
# Independent reference (spec section 8: "independent reference proves
# valid-pair RMSSD and withholding")
# --------------------------------------------------------------------------


def test_clean_beats_match_reference_rmssd(fixtures):
    fixture = fixtures["T1_clean"]
    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    reference, pairs, excluded = reference_valid_pair_rmssd(
        fixture.rr_ms, [True] * len(fixture.rr_ms))
    assert pairs == 59 and excluded == 0
    assert outcome.rmssd == pytest.approx(reference, abs=1e-9)
    assert outcome.valid_pairs == pairs
    assert outcome.n_clean == 60


def test_rejected_beat_matches_reference_rmssd(fixtures):
    """The 380 ms ectopic beat is rejected, so the two pairs that touched it
    must not enter RMSSD (the mask is written out by hand here)."""
    fixture = fixtures["T2_ectopic"]
    ectopic_index = 30
    surviving = [v for i, v in enumerate(fixture.rr_ms) if i != ectopic_index]
    mask = [True] * len(surviving)
    mask[ectopic_index] = False          # pair (ectopic-1, ectopic+1) is a splice
    reference, pairs, excluded = reference_valid_pair_rmssd(surviving, mask)
    assert pairs == 58 and excluded == 1

    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_range_rejected == 0
    assert outcome.n_ectopic_rejected == 1
    assert outcome.n_clean == 60
    assert outcome.valid_pairs == pairs
    assert outcome.rmssd == pytest.approx(reference, abs=1e-9)
    assert outcome.rmssd == pytest.approx(30.956, abs=5e-4)


def test_out_of_range_beats_match_reference_rmssd(fixtures):
    """250 ms and 2500 ms are dropped by the range filter, not by Malik."""
    fixture = fixtures["T8_out_of_range"]
    dropped = {20, 21}
    surviving = [v for i, v in enumerate(fixture.rr_ms) if i not in dropped]
    mask = [True] * len(surviving)
    # Removing two ADJACENT beats breaks exactly one pair in the surviving
    # series: the pair that now spans both removals.
    mask[20] = False
    reference, pairs, excluded = reference_valid_pair_rmssd(surviving, mask)
    assert pairs == 38 and excluded == 1

    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_range_rejected == 2
    assert outcome.n_ectopic_rejected == 0
    assert outcome.n_clean == 40
    assert outcome.valid_pairs == pairs
    assert outcome.rmssd == pytest.approx(reference, abs=1e-9)
    assert outcome.rmssd == pytest.approx(38.429, abs=5e-4)


def test_long_gap_matches_reference_rmssd(fixtures):
    """A 90 s hole in the record breaks adjacency for the pair that spans it."""
    fixture = fixtures["T5_gap_90s"]
    gap_index = 60
    mask = [True] * len(fixture.rr_ms)
    mask[gap_index] = False
    reference, pairs, excluded = reference_valid_pair_rmssd(fixture.rr_ms, mask)
    assert pairs == 119 and excluded == 1

    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_runs == 2, "the wall-clock hole must split the series into runs"
    assert outcome.valid_pairs == pairs
    assert outcome.gap_pairs_excluded == excluded
    assert outcome.rmssd == pytest.approx(reference, abs=1e-9)
    assert outcome.rmssd == pytest.approx(31.041, abs=5e-4)


def test_withholding_when_no_adjacent_pair_exists():
    """30 clean intervals, none adjacent: the beat floor passes, the pair count
    is zero, and the result must be withheld with that exact detail.

    The 100 ms beats are removed by the RANGE filter, so they never reach Malik
    and the surviving 1000 ms beats are clean but separated.
    """
    beats = [Beat(ts=1000 + i, rr_ms=1000.0 if i % 2 == 0 else 100.0, seq=i, ord=i)
             for i in range(60)]
    outcome = analyze_window(Window(start=990, end=1100), beats, DEFAULT_TUNING)
    assert outcome.n_range_rejected == 30
    assert outcome.n_ectopic_rejected == 0
    assert outcome.n_clean == 30
    assert outcome.valid_pairs == 0
    assert outcome.rmssd is None
    assert outcome.withheld_reason == WithheldReason.INSUFFICIENT_COVERAGE.value
    assert outcome.withheld_detail == "no_adjacent_pair"


def test_withholding_when_every_beat_is_rejected():
    beats = [Beat(ts=1000 + i, rr_ms=350.0 if i % 2 == 0 else 1950.0, seq=i, ord=i)
             for i in range(40)]
    outcome = analyze_window(Window(start=990, end=1100), beats, DEFAULT_TUNING)
    assert outcome.n_clean == 0
    assert outcome.rmssd is None
    assert outcome.withheld_detail == "insufficient_clean_beats"


# --------------------------------------------------------------------------
# Dropped beats
# --------------------------------------------------------------------------


def test_dropped_beat_invisible_to_timestamps(fixtures):
    """A beat that vanished before storage leaves no wall-clock hole, so the
    surviving neighbours stay adjacent and the value is the clean-series value."""
    fixture = fixtures["T3_dropped_beat"]
    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_clean == 59
    assert outcome.valid_pairs == 58
    assert outcome.rmssd == pytest.approx(36.408, abs=5e-4)


def test_one_beat_dropout_is_spliced_by_the_shipped_splice_tolerance(fixtures):
    """Documents a shipped-engine property (findings B6): a single dropped beat
    leaves a 1.0 s excess, below the 3.0 s splice tolerance, so production
    splices across it. The provider reproduces that rather than silently
    "improving" it, and the 4-beat dropout (5 s) IS split."""
    one = fixtures["T9_drop_1beat"]
    outcome_one = analyze_window(one.window(), one.beats(), DEFAULT_TUNING)
    assert outcome_one.n_runs == 1
    assert outcome_one.rmssd == pytest.approx(33.254, abs=5e-4)
    # The independent truth for this fixture masks the dropped pair: 33.533.
    mask = [True] * len(one.rr_ms)
    mask[30] = False
    reference, _pairs, _excluded = reference_valid_pair_rmssd(one.rr_ms, mask)
    assert reference == pytest.approx(33.533, abs=5e-4)
    assert outcome_one.rmssd != pytest.approx(reference, abs=0.01)

    four = fixtures["T10_drop_4beat"]
    outcome_four = analyze_window(four.window(), four.beats(), DEFAULT_TUNING)
    assert outcome_four.n_runs == 2
    assert outcome_four.rmssd == pytest.approx(31.125, abs=5e-4)


# --------------------------------------------------------------------------
# Duplicates and same-second intervals
# --------------------------------------------------------------------------


def test_equal_same_second_intervals_are_kept_distinct():
    """Two genuine 500 ms beats in one second must NOT be deduplicated
    (spec section 5), while an exact retransmission of one observation must be."""
    beats: list[Beat] = []
    ts = 1000
    for i in range(30):
        beats.append(Beat(ts=ts, rr_ms=1000.0, seq=i, ord=i))
        ts += 1
    beats.append(Beat(ts=ts, rr_ms=500.0, seq=30, ord=30))
    beats.append(Beat(ts=ts, rr_ms=500.0, seq=31, ord=31))
    ts += 1
    for i in range(30):
        beats.append(Beat(ts=ts, rr_ms=1000.0, seq=100 + i, ord=100 + i))
        ts += 1

    deduped = dedup_by_observation_identity(beats)
    assert deduped.n_input == 62
    assert deduped.n_duplicates_dropped == 0
    assert deduped.n_kept == 62

    # Same values, same second, identical delivery identity: this IS a duplicate.
    collapsed_input = list(beats)
    collapsed_input[30] = Beat(ts=beats[30].ts, rr_ms=500.0, seq=30, ord=30)
    collapsed_input[31] = Beat(ts=beats[30].ts, rr_ms=500.0, seq=30, ord=30)
    collapsed = dedup_by_observation_identity(collapsed_input)
    assert collapsed.n_duplicates_dropped == 1
    assert collapsed.n_kept == 61


def test_duplicate_burst_dedup_keeps_the_clean_value(fixtures):
    """An exact retransmission burst must not change the reported RMSSD."""
    fixture = fixtures["T1_clean"]
    clean_beats = fixture.beats()
    burst = [clean_beats[20], clean_beats[20], clean_beats[21]]
    with_duplicates = clean_beats[:20] + burst + clean_beats[21:]

    deduped = dedup_by_observation_identity(with_duplicates)
    assert deduped.n_duplicates_dropped == 2

    window = fixture.window()
    clean_outcome = analyze_window(window, clean_beats, DEFAULT_TUNING)
    burst_outcome = analyze_window(window, deduped.beats, DEFAULT_TUNING)
    assert burst_outcome.rmssd == pytest.approx(clean_outcome.rmssd, abs=1e-9)
    assert burst_outcome.rmssd == pytest.approx(31.156, abs=5e-4)
    assert burst_outcome.n_clean == 60


def test_duplicate_burst_fixture_matches_oracle(fixtures):
    """The T4 burst fixture (three 1000 ms intervals across separate seconds)
    reproduces the published oracle: nothing is deduplicated because the rows
    are distinct observations, and the burst deltas enter RMSSD."""
    fixture = fixtures["T4_duplicate_burst"]
    outcome = analyze_window(fixture.window(), fixture.beats(), DEFAULT_TUNING)
    assert outcome.n_clean == 63
    assert outcome.valid_pairs == 62
    assert outcome.rmssd == pytest.approx(25.037, abs=5e-4)


# --------------------------------------------------------------------------
# Units
# --------------------------------------------------------------------------


def test_seconds_instead_of_milliseconds_is_rejected(fixtures):
    """A payload that expresses intervals in seconds is a unit error, not a
    filtering question: it must be refused at validation."""
    fixture = fixtures["T1_clean"]
    rows = [{"ts": fixture.ts[i], "rr_ms": fixture.rr_ms[i] / 1000.0} for i in range(len(fixture.rr_ms))]
    with pytest.raises(ContractError) as excinfo:
        parse_request(hrv_body([], window=fixture.window(), beat_rows=rows))
    assert excinfo.value.code == "out_of_bounds_input"
    assert excinfo.value.http_status == 400

    # Milliseconds are accepted, and the value is the oracle value.
    request = parse_request(hrv_body(fixture.beats(), window=fixture.window()))
    assert isinstance(request.input, HrvInput)
    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"
    assert outcome.value == pytest.approx(31.156, abs=5e-4)
    assert outcome.unit == "ms"


def test_out_of_order_beats_are_rejected(fixtures):
    fixture = fixtures["T1_clean"]
    rows = [{"ts": fixture.ts[i], "rr_ms": fixture.rr_ms[i]} for i in range(10)]
    rows[5], rows[6] = rows[6], rows[5]
    with pytest.raises(ContractError) as excinfo:
        parse_request(hrv_body([], window=fixture.window(), beat_rows=rows))
    assert excinfo.value.code == "unsorted_input"


def test_non_finite_interval_is_rejected():
    with pytest.raises(ContractError) as excinfo:
        parse_request(hrv_body([], window=Window(start=1000, end=1100),
                               beat_rows=[{"ts": 1000, "rr_ms": float("nan")}]))
    assert excinfo.value.code == "non_finite_input"


# --------------------------------------------------------------------------
# Coverage, windows and aggregation
# --------------------------------------------------------------------------


def test_coverage_and_pairs_are_reported_separately(fixtures):
    """Spec section 5: valid pairs and time coverage are separate figures, and
    the beat floor alone does not prove adequate coverage."""
    fixture = fixtures["T1_clean"]
    window = fixture.window()
    outcome = analyze_window(window, fixture.beats(), DEFAULT_TUNING)
    assert outcome.valid_pairs == 59
    assert outcome.n_clean == 60
    assert outcome.clean_beat_ms == pytest.approx(sum(fixture.rr_ms), abs=1e-6)
    assert 0.0 < outcome.coverage < 1.0
    assert outcome.rr_coverage == pytest.approx(1.0, abs=0.05)
    assert outcome.coverage_verdict in ("plausible", "underCovered")


def test_window_floor_of_twenty_clean_intervals():
    """19 clean intervals is below the shipped floor of 20 (HRVAnalyzer:33)."""
    beats = [Beat(ts=1000 + i, rr_ms=1000.0, seq=i, ord=i) for i in range(19)]
    outcome = analyze_window(Window(start=990, end=1100), beats, DEFAULT_TUNING)
    assert outcome.n_clean == 19
    assert outcome.rmssd is None
    assert outcome.withheld_detail == "insufficient_clean_beats"

    beats.append(Beat(ts=1000 + 19, rr_ms=1000.0, seq=19, ord=19))
    outcome = analyze_window(Window(start=990, end=1100), beats, DEFAULT_TUNING)
    assert outcome.n_clean == 20
    assert outcome.rmssd is not None
    assert outcome.valid_pairs == 19


def test_sparse_night_reports_coverage_separately_from_the_beat_floor():
    """An eight-hour night with beats in only two windows.

    With the shipped nightly thresholds (no coverage floor) the beat floor passes
    and a value is produced, but the coverage figure shows that most of the night
    contributed nothing - which is exactly why the two are reported separately.
    A pre-declared stricter coverage gate withholds instead.
    """
    start = 1_700_000_000
    end = start + 8 * 3600
    beats: list[Beat] = []
    for window_index in (0, 40):
        base = start + window_index * 300
        for i in range(60):
            beats.append(Beat(ts=base + i, rr_ms=1000.0,
                              seq=window_index * 1000 + i, ord=i))
    body = hrv_body(
        beats, aggregation="session",
        context_overrides={"interval_start_utc": iso(start), "interval_end_utc": iso(end)},
    )
    request = parse_request(body)
    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"
    assert outcome.coverage["usable_windows"] == 2
    assert outcome.coverage["total_windows"] == 96
    assert outcome.coverage["session_coverage"] < 0.01
    assert outcome.coverage["session_span_ms"] == 8 * 3600 * 1000
    assert outcome.coverage["valid_pairs"] > 0
    assert outcome.diagnostics["n_clean"] == 120

    strict = HrvProductionProvider(tuning=HrvTuning(min_coverage=0.5))
    strict_outcome = strict.infer(request)
    assert strict_outcome.status == "withheld"
    assert strict_outcome.withheld_reason == WithheldReason.INSUFFICIENT_COVERAGE.value
    assert strict_outcome.diagnostics["withheld_detail"] == "low_coverage"


def test_tumbling_windows_do_not_double_count_a_boundary_beat():
    """Back-to-back windows must be half-open on the upper bound, or a beat
    landing exactly on a boundary is scored in two windows at once."""
    from frwhoop_inference.providers.hrv import plan_windows

    start = 1_700_000_000
    end = start + 600
    windows = plan_windows(start, end, (), DEFAULT_TUNING)
    assert len(windows) == 2
    assert windows[0].half_open is True
    assert windows[1].half_open is False
    assert windows[1].end == end

    boundary = start + 300
    beats = [Beat(ts=start + i, rr_ms=1000.0, seq=i, ord=i) for i in range(600)]
    counted = [w for w in windows if w.contains(boundary)]
    assert len(counted) == 1
    total = sum(analyze_window(w, beats, DEFAULT_TUNING).n_input for w in windows)
    assert total == 600


def test_session_aggregation_is_a_plain_mean_over_windows():
    start = 1_700_000_000
    windows = [Window(start=start + i * 300, end=start + (i + 1) * 300 - 1, session_id="night")
               for i in range(3)]
    beats: list[Beat] = []
    for index, window in enumerate(windows):
        # Different RR variability per window -> window RMSSDs of 10, 40 and 90 ms,
        # whose plain mean (46.67) differs from their median (40).
        amplitude = (5.0, 20.0, 45.0)[index]
        for i in range(60):
            rr = 1000.0 + (amplitude if i % 2 == 0 else -amplitude)
            beats.append(Beat(ts=window.start + i, rr_ms=rr, seq=index * 1000 + i, ord=i))
    request = parse_request(hrv_body(
        beats, windows=windows, aggregation="session",
        context_overrides={"interval_start_utc": iso(start),
                           "interval_end_utc": iso(start + 3 * 300)},
    ))
    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"

    per_window = [analyze_window(w, beats, DEFAULT_TUNING).rmssd for w in windows]
    assert all(v is not None for v in per_window)
    plain_mean = sum(per_window) / len(per_window)
    median = sorted(per_window)[1]
    assert outcome.value == pytest.approx(plain_mean, abs=1e-9)
    assert outcome.value != pytest.approx(median, abs=1e-6), "aggregation must not be a median"
    assert outcome.diagnostics["aggregation"] == "session"
    assert len(outcome.diagnostics["sessions"]) == 1


def test_day_aggregation_is_duration_weighted_across_sessions():
    start = 1_700_000_000
    night = [Window(start=start + i * 300, end=start + (i + 1) * 300 - 1, session_id="night")
             for i in range(2)]
    nap = [Window(start=start + 4000, end=start + 4000 + 299, session_id="nap")]
    windows = night + nap
    beats: list[Beat] = []
    for index, window in enumerate(windows):
        for i in range(60):
            rr = 1000.0 + (8.0 * index if i % 2 == 0 else -8.0 * index)
            beats.append(Beat(ts=window.start + i, rr_ms=rr, seq=index * 1000 + i, ord=i))
    request = parse_request(hrv_body(
        beats, windows=windows, aggregation="day",
        context_overrides={"interval_start_utc": iso(start),
                           "interval_end_utc": iso(start + 5000)},
    ))
    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "ok"
    night_values = [analyze_window(w, beats, DEFAULT_TUNING).rmssd for w in night]
    nap_value = analyze_window(nap[0], beats, DEFAULT_TUNING).rmssd
    night_mean = sum(night_values) / len(night_values)
    night_duration = float(max(w.end for w in night) - min(w.start for w in night))
    nap_duration = float(nap[0].end - nap[0].start)
    expected = (night_mean * night_duration + nap_value * nap_duration) / (night_duration + nap_duration)
    assert outcome.value == pytest.approx(expected, abs=1e-9)
    plain_mean = (night_mean + nap_value) / 2.0
    assert outcome.value != pytest.approx(plain_mean, abs=1e-6)
    assert len(outcome.diagnostics["sessions"]) == 2


def test_session_over_count_gate_withholds():
    """A session that banks twice the beat-time its wall clock allows is refused
    outright (SleepStager.sessionHrvOverCounted), with a machine-readable reason."""
    start = 1_700_000_000
    beats: list[Beat] = []
    for second in range(900):
        for order in range(2):
            beats.append(Beat(ts=start + second, rr_ms=1000.0, seq=second * 2 + order,
                              ord=order))
    request = parse_request(hrv_body(
        beats, windows=[Window(start=start, end=start + 900, session_id="night")],
        aggregation="session",
        context_overrides={"interval_start_utc": iso(start),
                           "interval_end_utc": iso(start + 900)},
    ))
    outcome = HrvProductionProvider().infer(request)
    assert outcome.status == "withheld"
    assert outcome.withheld_reason == WithheldReason.ARTIFACT_FRACTION.value
    assert "over_count" in outcome.diagnostics["withheld_detail"]


def test_over_count_gate_is_skipped_on_windows_too_short_to_judge():
    """Whole-second timestamps under-report a short span, so a short window can
    look over-covered on clean data. The gate must only judge a window whose span
    is long enough for its own coverage figure to mean anything."""
    short_beats = [Beat(ts=1000 + i, rr_ms=1300.0, seq=i, ord=i) for i in range(30)]
    short_outcome = analyze_window(Window(start=1000, end=1029), short_beats, DEFAULT_TUNING)
    assert short_outcome.rr_coverage > 1.10        # the flooring bias is real
    assert short_outcome.window_ms < DEFAULT_TUNING.over_count_min_span_s * 1000
    assert short_outcome.rmssd is not None
    assert short_outcome.withheld_reason is None

    long_beats = [Beat(ts=1000 + i, rr_ms=1300.0, seq=i, ord=i) for i in range(400)]
    long_outcome = analyze_window(Window(start=1000, end=1399), long_beats, DEFAULT_TUNING)
    assert long_outcome.window_ms >= DEFAULT_TUNING.over_count_min_span_s * 1000
    assert long_outcome.rmssd is None
    assert long_outcome.withheld_reason == WithheldReason.ARTIFACT_FRACTION.value
    assert "over_count" in long_outcome.withheld_detail


# --------------------------------------------------------------------------
# Tuning
# --------------------------------------------------------------------------


def test_thresholds_are_configurable_and_default_to_the_shipped_values():
    assert DEFAULT_TUNING.rr_min_ms == 300.0
    assert DEFAULT_TUNING.rr_max_ms == 2000.0
    assert DEFAULT_TUNING.min_clean_beats == 20
    assert DEFAULT_TUNING.malik_threshold == 0.20
    assert DEFAULT_TUNING.malik_radius == 2
    assert DEFAULT_TUNING.splice_tolerance_s == 3.0
    assert DEFAULT_TUNING.window_sec == 300
    assert DEFAULT_TUNING.coverage_ceiling == 1.10

    beats = [Beat(ts=1000 + i, rr_ms=1000.0, seq=i, ord=i) for i in range(12)]
    window = Window(start=990, end=1100)
    assert analyze_window(window, beats, DEFAULT_TUNING).rmssd is None
    relaxed = HrvTuning(min_clean_beats=5)
    assert analyze_window(window, beats, relaxed).rmssd is not None

    # The range filter is the knob, not the validator: a 250 ms beat is legal
    # input and is removed by the filter.
    with_out_of_range = [
        Beat(ts=1000 + i,
             rr_ms=(250.0 if i == 5 else (1020.0 if i % 2 == 0 else 980.0)),
             seq=i, ord=i)
        for i in range(30)]
    window = Window(start=990, end=1040)
    default_outcome = analyze_window(window, with_out_of_range, DEFAULT_TUNING)
    assert default_outcome.n_range_rejected == 1
    assert default_outcome.n_ectopic_rejected == 0

    # Widening the range moves the same beat into Malik's care: the surviving
    # series - and therefore the value - is unchanged, which is the invariant
    # that makes the two filters composable.
    wide = HrvTuning(rr_min_ms=100.0)
    wide_outcome = analyze_window(window, with_out_of_range, wide)
    assert wide_outcome.n_range_rejected == 0
    assert wide_outcome.n_ectopic_rejected == 1
    assert wide_outcome.rmssd == pytest.approx(default_outcome.rmssd, abs=1e-9)

    # Relaxing Malik as well keeps the beat, and the value must change.
    permissive = HrvTuning(rr_min_ms=100.0, malik_threshold=1.0)
    permissive_outcome = analyze_window(window, with_out_of_range, permissive)
    assert permissive_outcome.n_clean == 30
    assert permissive_outcome.rmssd != pytest.approx(default_outcome.rmssd, abs=1e-6)


# --------------------------------------------------------------------------
# Provider surface
# --------------------------------------------------------------------------


def test_production_provider_is_the_default_and_publishable():
    from frwhoop_inference.providers import ProviderRegistry, default_providers

    registry = ProviderRegistry(default_providers())
    provider = registry.default_for_metric("hrv")
    assert provider is not None
    assert provider.provider_id == "production.runs.v1"
    assert provider.capability()["publishable"] is True
    ready, reason = provider.readiness()
    assert ready is True and reason is None
    assert provider.versions().get("model") is None
    assert provider.versions()["dependency"].startswith("numpy==")


def test_expected_versions_mismatch_is_rejected(fixtures):
    """A caller that pins a provider revision must be told when it differs."""
    from frwhoop_inference.providers import ProviderRegistry, default_providers
    from frwhoop_inference.server import _check_expected_versions

    fixture = fixtures["T1_clean"]
    body = hrv_body(fixture.beats(), window=fixture.window(),
                    provider_id="production.runs.v1")
    body["provider"]["expected_versions"] = {"preprocessing": "not-this-one"}
    request = parse_request(body)
    provider = ProviderRegistry(default_providers()).get("production.runs.v1")
    with pytest.raises(ContractError) as excinfo:
        _check_expected_versions(provider, request)
    assert excinfo.value.code == "provider_version_mismatch"
    assert excinfo.value.http_status == 400

    body["provider"]["expected_versions"] = {"preprocessing": "hrv.preprocess.production.runs.v1"}
    _check_expected_versions(provider, parse_request(body))
