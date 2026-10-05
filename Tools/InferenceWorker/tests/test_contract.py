"""Contract tests: bounds, finiteness, timestamps, identity, label space,
withheld-reason enum, hashing and the independent reference RMSSD."""

from __future__ import annotations

import math

import pytest

from conftest import hrv_body, iso
from frwhoop_inference.contract import (
    ADAPTER_VERSION,
    CONTRACT_VERSION,
    METRICS,
    STATUSES,
    ContractError,
    ProviderResult,
    WithheldReason,
    canonical_sha256,
    parse_context,
    parse_hrv_input,
    parse_request,
    pooled_rmssd,
    reference_valid_pair_rmssd,
    utc_day,
)


#: A beat timestamp INSIDE ``_context()``'s interval (2026-10-01T22:00:00Z), so a
#: payload test exercises what it names instead of also tripping the
#: beat-versus-interval bounds check.
CONTEXT_BEAT_TS = 1_790_892_060


def _context(**overrides):
    base = {
        "user_id": "11111111-2222-3333-4444-555555555555",
        "device_id": "whoop5-abcdef",
        "interval_start_utc": "2026-10-01T22:00:00Z",
        "interval_end_utc": "2026-10-02T07:00:00Z",
        "iana_timezone": "Europe/London",
        "profile_version": "p1",
        "config_version": "c1",
        "corrections_version": "r0",
    }
    base.update(overrides)
    return base


# -- constants --------------------------------------------------------------


def test_metric_domain_is_the_four_declared_metrics():
    assert METRICS == ("hrv", "sleep_boundary", "sleep_stage", "respiration")


def test_withheld_reason_enum_matches_the_shared_plan():
    values = {r.value for r in WithheldReason}
    assert values >= {"blocked_input", "blocked_artifact", "blocked_license", "unverified",
                      "insufficient_coverage", "artifact_fraction", "provider_error", "timeout",
                      "not_ready"}
    # HRV-specific extension required by the adapter contract.
    assert "unresolved_adjacency" in values


def test_versions_are_declared():
    assert CONTRACT_VERSION
    assert ADAPTER_VERSION.startswith("frwhoop-inference.adapter/")


# -- context validation -----------------------------------------------------


def test_context_round_trips_and_normalises_timestamps():
    context = parse_context(_context(interval_start_utc="2026-10-01T22:00:00+00:00"))
    assert context.interval_start_utc == "2026-10-01T22:00:00Z"
    from datetime import datetime, timezone

    assert context.start_ts == int(datetime(2026, 10, 1, 22, tzinfo=timezone.utc).timestamp())
    assert context.live is False


@pytest.mark.parametrize("mutate,code", [
    ({"user_id": ""}, "invalid_context"),
    ({"device_id": None}, "invalid_context"),
    ({"user_id": "a b"}, "invalid_identity"),
    ({"iana_timezone": "Nowhere/Land"}, "invalid_timezone"),
    ({"interval_start_utc": "not-a-time"}, "invalid_timestamp"),
    ({"interval_start_utc": "2026-10-01T22:00:00"}, "invalid_timestamp"),
    ({"interval_end_utc": "2026-10-01T22:00:00Z"}, "invalid_timestamp"),
    ({"live": "yes"}, "invalid_context"),
    ({"profile_version": "x" * 200}, "invalid_context"),
])
def test_bad_context_is_rejected(mutate, code):
    with pytest.raises(ContractError) as excinfo:
        parse_context(_context(**mutate))
    assert excinfo.value.code == code
    assert excinfo.value.http_status == 400


def test_missing_context_field_is_rejected():
    payload = _context()
    del payload["config_version"]
    with pytest.raises(ContractError) as excinfo:
        parse_context(payload)
    assert excinfo.value.code == "invalid_context"
    assert excinfo.value.field == "context.config_version"


# -- input validation -------------------------------------------------------


def test_input_bounds_are_absolute_not_the_production_filter():
    """250 ms and 2500 ms are legal input that the provider filters; 1.0 ms and
    60 s are malformed payloads."""
    ts = CONTEXT_BEAT_TS
    for rr in (250.0, 2500.0):
        parsed = parse_hrv_input({"beats": [{"ts": ts, "rr_ms": rr}]}, parse_context(_context()))
        assert parsed.beats[0].rr_ms == rr
    for rr in (1.0, 60_000.0):
        with pytest.raises(ContractError) as excinfo:
            parse_hrv_input({"beats": [{"ts": ts, "rr_ms": rr}]}, parse_context(_context()))
        assert excinfo.value.code == "out_of_bounds_input"


@pytest.mark.parametrize("ts", [0, -5, 10 ** 12])
def test_bad_beat_timestamps_are_rejected(ts):
    with pytest.raises(ContractError) as excinfo:
        parse_hrv_input({"beats": [{"ts": ts, "rr_ms": 1000.0}]}, parse_context(_context()))
    assert excinfo.value.code == "invalid_timestamp"


def test_beat_identity_drives_dedup_not_the_value():
    from frwhoop_inference.contract import Beat

    a = Beat(ts=10, rr_ms=500.0, seq=1, ord=1)
    b = Beat(ts=10, rr_ms=500.0, seq=2, ord=2)
    c = Beat(ts=10, rr_ms=500.0, seq=1, ord=1)
    assert a.identity != b.identity
    assert a.identity == c.identity
    explicit = Beat(ts=10, rr_ms=500.0, observation_id="obs-1")
    assert explicit.identity == ("obs-1",)


def test_windows_must_lie_inside_the_context_interval():
    context = parse_context(_context())
    with pytest.raises(ContractError) as excinfo:
        parse_hrv_input({
            "beats": [{"ts": CONTEXT_BEAT_TS, "rr_ms": 1000.0}],
            "windows": [{"start_utc": "2020-01-01T00:00:00Z", "end_utc": "2020-01-01T01:00:00Z"}],
        }, context)
    assert excinfo.value.code == "out_of_bounds_input"


def _beat_rows(ts_values):
    return [{"ts": ts, "rr_ms": 1000.0, "seq": i, "ord": i} for i, ts in enumerate(ts_values)]


def test_beats_with_no_beat_inside_the_context_interval_are_rejected():
    """A payload for the wrong interval is a client bug, not an empty night.

    Before this check the mismatch surfaced as a 200 ``withheld`` with
    ``no_beats_in_window``, which a caller cannot tell apart from an interval that
    genuinely has no beats (review F6). The rule is set-level: it is the ABSENCE of
    any in-band beat that is refused, not an individual out-of-band beat.
    """
    from frwhoop_inference.contract import BEAT_INTERVAL_SLACK_S

    context = parse_context(_context())
    year = 365 * 24 * 3600
    for ts_values in ([CONTEXT_BEAT_TS - year], [CONTEXT_BEAT_TS + 10 * 24 * 3600],
                      # straddling the interval is still a mismatch: no beat is IN it
                      [CONTEXT_BEAT_TS - year, CONTEXT_BEAT_TS + year]):
        with pytest.raises(ContractError) as excinfo:
            parse_hrv_input({"beats": _beat_rows(ts_values)}, context)
        assert excinfo.value.code == "out_of_bounds_input"
        assert excinfo.value.http_status == 400
        assert excinfo.value.field == "input.beats"
        assert "no input.beats[].ts lies inside the context interval" in excinfo.value.message
    assert BEAT_INTERVAL_SLACK_S == 300


def test_beats_are_rejected_through_the_whole_request_path():
    """The same check fires for ``parse_request``, so the server answers 400 and
    never reaches a provider."""
    stale = CONTEXT_BEAT_TS - 365 * 24 * 3600
    with pytest.raises(ContractError) as excinfo:
        parse_request({"metric": "hrv", "context": _context(),
                       "input": {"beats": [{"ts": stale, "rr_ms": 1000.0}]}})
    assert excinfo.value.code == "out_of_bounds_input"
    assert excinfo.value.field == "input.beats"


def test_the_slack_band_accepts_one_beat_just_outside_the_interval():
    """The band is inclusive on both sides and is what keeps a client that rounds
    an edge, or that sends the enclosing read window, from being refused."""
    from frwhoop_inference.contract import BEAT_INTERVAL_SLACK_S

    context = parse_context(_context())
    for ts in (context.start_ts - BEAT_INTERVAL_SLACK_S, context.end_ts + BEAT_INTERVAL_SLACK_S):
        parsed = parse_hrv_input({"beats": _beat_rows([ts])}, context)
        assert parsed.beats[0].ts == ts
    for ts in (context.start_ts - BEAT_INTERVAL_SLACK_S - 1,
               context.end_ts + BEAT_INTERVAL_SLACK_S + 1):
        with pytest.raises(ContractError) as excinfo:
            parse_hrv_input({"beats": _beat_rows([ts])}, context)
        assert excinfo.value.code == "out_of_bounds_input"


def test_a_superset_beat_set_around_the_interval_is_accepted():
    """The shipped worker sends the beats of a WIDE read window (30 h before to
    54 h after local midnight, ``DayScoring.swift``) with the main sleep session as
    the interval, so the payload is deliberately a superset of the interval. Only
    beats outside every window are ignored; the request must be accepted."""
    context = parse_context(_context())
    hour = 3600
    beats = _beat_rows([context.start_ts - 30 * hour, context.start_ts - hour,
                        context.start_ts + 60, context.start_ts + 600,
                        context.end_ts + 54 * hour])
    parsed = parse_hrv_input({"beats": beats}, context)
    assert len(parsed.beats) == 5
    # ...and the same set with no in-band beat at all is refused
    with pytest.raises(ContractError) as excinfo:
        parse_hrv_input({"beats": _beat_rows([context.start_ts - 30 * hour,
                                              context.end_ts + 54 * hour])}, context)
    assert excinfo.value.code == "out_of_bounds_input"


def test_aggregation_window_requires_exactly_one_window():
    context = parse_context(_context())
    with pytest.raises(ContractError) as excinfo:
        parse_hrv_input({
            "beats": [{"ts": CONTEXT_BEAT_TS, "rr_ms": 1000.0}],
            "aggregation": "window",
            "windows": [{"start_utc": "2026-10-01T22:00:00Z", "end_utc": "2026-10-01T23:00:00Z"},
                        {"start_utc": "2026-10-01T23:00:00Z", "end_utc": "2026-10-02T00:00:00Z"}],
        }, context)
    assert excinfo.value.code == "invalid_input"


def test_default_aggregation_depends_on_windows():
    context = parse_context(_context())
    no_windows = parse_hrv_input({"beats": [{"ts": CONTEXT_BEAT_TS, "rr_ms": 1000.0}]}, context)
    assert no_windows.aggregation == "window"
    with_window = parse_hrv_input({
        "beats": [{"ts": CONTEXT_BEAT_TS, "rr_ms": 1000.0}],
        "windows": [{"start_utc": "2026-10-01T22:00:00Z", "end_utc": "2026-10-01T23:00:00Z"}],
    }, context)
    assert with_window.aggregation == "session"


# -- request validation -----------------------------------------------------


def test_request_hashes_input_canonically():
    beats = [{"ts": CONTEXT_BEAT_TS, "rr_ms": 1000.0}]
    first = parse_request({"metric": "hrv", "context": _context(), "input": {"beats": beats}})
    second = parse_request({"metric": "hrv", "context": _context(),
                            "input": {"beats": [{"rr_ms": 1000.0, "ts": CONTEXT_BEAT_TS}]}})
    assert first.input_sha256 == second.input_sha256
    assert canonical_sha256({"b": 1, "a": 2}) == canonical_sha256({"a": 2, "b": 1})
    assert any(ref["kind"] == "rr_intervals" for ref in first.input_refs)


def test_request_rejects_a_non_object_body():
    for body in ([], "x", 3, None):
        with pytest.raises(ContractError) as excinfo:
            parse_request(body)
        assert excinfo.value.code == "invalid_request"


def test_provider_block_is_validated():
    from frwhoop_inference.contract import Window

    beats = [{"ts": CONTEXT_BEAT_TS + i, "rr_ms": 1000.0} for i in range(3)]
    window = {"start_utc": "2026-10-01T22:00:00Z", "end_utc": "2026-10-01T23:00:00Z"}
    with pytest.raises(ContractError) as excinfo:
        parse_request({"metric": "hrv", "context": _context(),
                       "input": {"beats": beats, "windows": [window]},
                       "provider": {"provider_id": ""}})
    assert excinfo.value.code == "invalid_provider"
    with pytest.raises(ContractError) as excinfo:
        parse_request({"metric": "hrv", "context": _context(),
                       "input": {"beats": beats, "windows": [window]},
                       "provider": {"expected_versions": "nope"}})
    assert excinfo.value.code == "invalid_provider"


# -- response model ---------------------------------------------------------


def test_provider_result_enforces_the_status_contract():
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=None)
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=float("inf"))
    with pytest.raises(ValueError):
        ProviderResult(status="withheld", value=1.0, withheld_reason="timeout")
    with pytest.raises(ValueError):
        ProviderResult(status="withheld", withheld_reason="not_a_reason")
    with pytest.raises(ValueError):
        ProviderResult(status="nonsense")
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=1.0, final_or_provisional="maybe")
    ok = ProviderResult(status="ok", value=1.0, final_or_provisional="final")
    assert ok.value == 1.0
    assert ok.status in STATUSES


# -- reference RMSSD --------------------------------------------------------


def test_reference_rmssd_uses_only_adjacent_pairs():
    rr = [1000.0, 1010.0, 900.0, 1005.0]
    mask = [False, True, False, True]
    value, pairs, excluded = reference_valid_pair_rmssd(rr, mask)
    # Adjacent pairs are (1000, 1010) and (900, 1005); the pair across the
    # removed beat is excluded, so it never contributes.
    assert pairs == 2 and excluded == 1
    expected = math.sqrt(((1010.0 - 1000.0) ** 2 + (1005.0 - 900.0) ** 2) / 2)
    assert value == pytest.approx(expected)
    assert value == pytest.approx(74.5821694508815, abs=1e-9)


def test_reference_rmssd_withholds_without_a_pair():
    value, pairs, excluded = reference_valid_pair_rmssd([1000.0, 1010.0, 990.0],
                                                        [False, False, False])
    assert value is None and pairs == 0 and excluded == 2
    assert reference_valid_pair_rmssd([1000.0], [False])[0] is None


def test_reference_rmssd_rejects_a_length_mismatch():
    with pytest.raises(ValueError):
        reference_valid_pair_rmssd([1.0, 2.0], [True])


def test_pooled_rmssd_combines_sums_and_counts():
    assert pooled_rmssd(100.0, 4) == pytest.approx(5.0)
    assert pooled_rmssd(0.0, 0) is None
    # Pooling is not averaging segment RMSSDs.
    assert pooled_rmssd(100.0 + 900.0, 1 + 1) == pytest.approx(math.sqrt(500.0))
    assert pooled_rmssd(100.0 + 900.0, 2) != pytest.approx((10.0 + 30.0) / 2)


# -- timezone helper --------------------------------------------------------


def test_utc_day_uses_the_iana_zone():
    ts = 1_759_356_000          # 2025-10-01T22:00:00Z
    assert utc_day(ts, "UTC") == "2025-10-01"
    assert utc_day(ts, "Asia/Tokyo") == "2025-10-02"
    assert utc_day(ts, "America/Los_Angeles") == "2025-10-01"


# --- structured (stages) results: landed by the parent after W-D's contract gap ------

def test_provider_result_ok_with_stages_requires_label_space():
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=None, unit=None,
                       stages=[{"stage": "rem", "start_s": 0, "end_s": 30}],
                       label_space=None)

def test_provider_result_ok_with_stages_and_label_space_is_valid():
    r = ProviderResult(status="ok", value=None, unit=None,
                       stages=[{"stage": "rem", "start_s": 0, "end_s": 30}],
                       label_space="wake/rem/nrem")
    assert r.value is None and r.stages[0]["stage"] == "rem"

def test_provider_result_ok_with_non_list_stages_is_rejected():
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=None, unit=None,
                       stages={"stage": "rem"}, label_space="wake/rem/nrem")

def test_provider_result_withheld_must_not_carry_stages():
    with pytest.raises(ValueError):
        ProviderResult(status="withheld", value=None, unit=None,
                       withheld_reason="blocked_input",
                       stages=[{"stage": "rem"}], label_space="wake/rem/nrem")

def test_provider_result_ok_value_or_stages_required():
    with pytest.raises(ValueError):
        ProviderResult(status="ok", value=None, unit=None)
