"""HRV ``neurokit2.shadow.v1`` tests: reconstruction, gating, labels, hard rules."""

from __future__ import annotations

import pandas as pd
import pytest

from conftest import hrv_body
from frwhoop_inference.contract import (
    Beat,
    Window,
    WithheldReason,
    parse_request,
    reference_valid_pair_rmssd,
)
from frwhoop_inference.providers import hrv as hrv_module
from frwhoop_inference.providers.hrv import (
    DEFAULT_TUNING,
    HrvNeurokitShadowProvider,
    HrvProductionProvider,
    reconstruct_end_times,
)


def _clean_beats(count: int = 60, seed: int = 7, epoch: int = 1_700_000_000,
                 with_order: bool = True) -> list[Beat]:
    """One beat per whole second, RR ~1000 +/- 25 ms (the research T1 shape)."""
    import numpy as np

    rng = np.random.default_rng(seed)
    rr = [float(v) for v in 1000.0 + rng.normal(0, 25.0, count)]
    beats: list[Beat] = []
    acc = 0.0
    for i, value in enumerate(rr):
        acc += value / 1000.0
        beats.append(Beat(ts=int(acc) + epoch, rr_ms=value,
                          seq=i if with_order else None, ord=i if with_order else None))
    return beats


# -- reconstruction ---------------------------------------------------------


def test_reconstruction_accumulates_rr_within_one_second():
    beats = [Beat(ts=1000, rr_ms=500.0, seq=0, ord=0),
             Beat(ts=1000, rr_ms=500.0, seq=1, ord=1),
             Beat(ts=1001, rr_ms=1000.0, seq=2, ord=0)]
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    assert clock.resolved is True
    assert clock.end_times[1] - clock.end_times[0] == pytest.approx(0.5)
    assert clock.end_times[2] - clock.end_times[1] == pytest.approx(1.0)


def test_reconstruction_requires_delivery_order():
    beats = [Beat(ts=1000 + i, rr_ms=1000.0) for i in range(10)]
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    assert clock.resolved is False
    assert clock.detail.startswith("missing_seq_ord")


def test_reconstruction_refuses_an_ambiguous_bucket_order():
    beats = [Beat(ts=1000, rr_ms=500.0, seq=1, ord=1),
             Beat(ts=1000, rr_ms=500.0, seq=1, ord=1)]
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    assert clock.resolved is False
    assert "ambiguous_bucket_order" in clock.detail


def test_reconstruction_refuses_a_store_span_that_cannot_hold_the_beats():
    beats = [Beat(ts=1000 + s, rr_ms=1000.0, seq=s * 2 + o, ord=o)
             for s in range(900) for o in range(2)]
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    assert clock.resolved is False
    assert clock.detail == "store_span_over_filled"
    assert clock.overfill_ms > DEFAULT_TUNING.store_overfill_allowance_ms


def test_reconstruction_marks_a_run_boundary():
    beats: list[Beat] = []
    acc = 0.0
    for i in range(60):
        acc += 1.0
        beats.append(Beat(ts=int(acc) + 1000, rr_ms=1000.0, seq=i, ord=i))
    hole = beats[-1].ts + 90
    for i in range(60):
        hole += 1
        beats.append(Beat(ts=hole, rr_ms=1000.0, seq=100 + i, ord=i))
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    assert clock.resolved is True
    assert clock.n_runs == 2
    delta = clock.end_times[60] - clock.end_times[59]
    assert delta > 1.9


# -- agreement --------------------------------------------------------------


def test_shadow_equals_production_on_a_clean_series():
    beats = _clean_beats()
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    request = parse_request(hrv_body(beats, window=window))
    production = HrvProductionProvider().infer(request)
    shadow = HrvNeurokitShadowProvider().infer(request)
    assert production.status == "ok"
    assert shadow.status == "ok"
    assert production.value == pytest.approx(31.156, abs=5e-4)
    assert shadow.value == pytest.approx(production.value, abs=1e-6)
    reference, pairs, excluded = reference_valid_pair_rmssd(
        [b.rr_ms for b in beats], [True] * len(beats))
    assert pairs == 59 and excluded == 0
    assert shadow.value == pytest.approx(reference, abs=1e-6)


def test_shadow_matches_a_direct_neurokit2_call():
    import neurokit2 as nk

    beats = _clean_beats()
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    shadow = HrvNeurokitShadowProvider().infer(parse_request(hrv_body(beats, window=window)))
    clock = reconstruct_end_times(beats, DEFAULT_TUNING)
    direct = nk.hrv_time({"RRI": [b.rr_ms for b in beats], "RRI_Time": list(clock.end_times)},
                         sampling_rate=None)
    assert shadow.value == pytest.approx(float(direct["HRV_RMSSD"].iloc[0]), abs=1e-9)


def test_shadow_uses_reconstructed_end_times_not_the_store_stamps():
    from frwhoop_inference.providers.hrv import neurokit2_hrv_time

    beats = _clean_beats()
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    shadow = HrvNeurokitShadowProvider().infer(parse_request(hrv_body(beats, window=window)))
    naive = neurokit2_hrv_time([b.rr_ms for b in beats], [float(b.ts) for b in beats])
    assert naive["rmssd"] is not None
    assert abs(naive["rmssd"] - shadow.value) > 5.0
    assert naive["rmssd"] < shadow.value


def test_shadow_breaks_the_mask_at_a_real_gap(fixtures):
    fixture = fixtures["T5_gap_90s"]
    request = parse_request(hrv_body(fixture.beats(), window=fixture.window()))
    production = HrvProductionProvider().infer(request)
    shadow = HrvNeurokitShadowProvider().infer(request)
    assert production.value == pytest.approx(31.041, abs=5e-4)
    assert shadow.status == "ok"
    assert shadow.value == pytest.approx(production.value, abs=1e-3)


# -- withholding and labels -------------------------------------------------


def test_shadow_withholds_with_unresolved_adjacency_without_delivery_order():
    beats = _clean_beats(with_order=False)
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    outcome = HrvNeurokitShadowProvider().infer(parse_request(hrv_body(beats, window=window)))
    assert outcome.status == "withheld"
    assert outcome.withheld_reason == WithheldReason.UNRESOLVED_ADJACENCY.value
    assert outcome.diagnostics["withheld_detail"].startswith("missing_seq_ord")
    assert outcome.value is None


def test_shadow_withholds_with_unresolved_adjacency_on_an_over_filled_store_span():
    """A span whose beats bank more time than the store clock allows is refused by
    the reconstruction, not scored.

    The coverage must stay PLAUSIBLE for this to reach the reconstruction: when the
    window's coverage is itself implausible the production over-count gate fires
    first (see ``test_shadow_applies_the_same_over_count_gate_as_production``), so
    the payload here is one beat per second of 1050 ms - the beats over-fill the
    span by ~5 s while the coverage reads 1.06.
    """
    beats = [Beat(ts=1000 + s, rr_ms=1050.0, seq=s, ord=0) for s in range(100)]
    request = parse_request(hrv_body(beats, window=Window(start=999, end=1600)))
    outcome = HrvNeurokitShadowProvider().infer(request)
    assert outcome.status == "withheld"
    assert outcome.withheld_reason == WithheldReason.UNRESOLVED_ADJACENCY.value
    assert outcome.diagnostics["withheld_detail"] == "store_span_over_filled"
    window = outcome.diagnostics["windows"][0]
    assert window["coverage_verdict"] == "plausible"
    assert window["clock"]["overfill_ms"] > DEFAULT_TUNING.store_overfill_allowance_ms


# -- window membership and production gates (review F2/F3) -------------------


def _boundary_body():
    """A 600 s context whose beats include one landing exactly on the 300 s
    tumbling boundary, with the interval pinned to the window plan."""
    from conftest import iso
    from frwhoop_inference.providers.hrv import plan_windows

    start = 1_700_000_000
    end = start + 600
    windows = plan_windows(start, end, (), DEFAULT_TUNING)
    assert [(w.start, w.end, w.half_open) for w in windows] == [
        (start, start + 300, True), (start + 300, end, False)]
    boundary = start + 300
    beats = [Beat(ts=start + i, rr_ms=1000.0 + float(i % 5), seq=i, ord=i) for i in range(600)]
    assert beats[boundary - start].ts == boundary
    body = hrv_body(beats, aggregation="session",
                    context_overrides={"interval_start_utc": iso(start),
                                       "interval_end_utc": iso(end)})
    return beats, boundary, body


def test_shadow_window_membership_is_half_open_like_production():
    """F2: the shadow must select the SAME beat set as production.

    With inclusive bounds a beat on a 300 s tumbling boundary is counted by both
    adjacent windows in the shadow and by one window in production, so the two
    providers differ in something other than arithmetic.
    """
    beats, boundary, body = _boundary_body()
    request = parse_request(body)
    production = HrvProductionProvider().infer(request)
    shadow = HrvNeurokitShadowProvider().infer(request)
    assert production.status == "ok" and shadow.status == "ok"

    prod_windows = production.diagnostics["windows"]
    shadow_windows = shadow.diagnostics["windows"]
    assert len(prod_windows) == len(shadow_windows) == 2
    # production puts the boundary beat in the SECOND window only
    assert prod_windows[0]["half_open"] is True
    assert prod_windows[1]["half_open"] is False
    assert prod_windows[0]["n_input"] == 300
    assert prod_windows[1]["n_input"] == 300
    # ... and the shadow now agrees, so nothing is double-counted
    assert [w["n_input"] for w in shadow_windows] == [300, 300]
    assert sum(w["n_input"] for w in shadow_windows) == len(beats)
    # the beat set is identical, window for window
    assert [w["n_input"] for w in shadow_windows] == [w["n_input"] for w in prod_windows]
    assert shadow.value == pytest.approx(production.value, abs=1e-6)


def test_the_boundary_beat_is_genuinely_shared_by_both_spans():
    """Why the half-open rule matters: the boundary beat falls inside BOTH windows'
    spans, so an inclusive slice counts it twice and the shadow would score a
    different beat set from production."""
    from frwhoop_inference.providers.hrv import plan_windows

    beats, boundary, _body = _boundary_body()
    first = plan_windows(1_700_000_000, 1_700_000_600, (), DEFAULT_TUNING)[0]
    assert first.contains(boundary) is False
    inclusive = len([b for b in beats if first.start <= b.ts <= first.end])
    assert inclusive == 301, "the boundary beat is shared by both spans"
    assert len([b for b in beats if first.contains(b.ts)]) == 300


def test_shadow_applies_the_same_over_count_gate_as_production():
    """F3: a window production refuses as over-counted must not come back from the
    shadow as a number (and must carry the same reason)."""
    start = 1_700_000_000
    # Two beats in each of two seconds, all 1000 ms: the window's beats bank four
    # times the wall clock its own span allows, while the reconstructed clock still
    # resolves (the over-fill is exactly at the one-sided allowance), so only the
    # production gate can refuse it.
    beats = [Beat(ts=start, rr_ms=1000.0, seq=0, ord=0), Beat(ts=start, rr_ms=1000.0, seq=0, ord=1),
             Beat(ts=start + 1, rr_ms=1000.0, seq=1, ord=0),
             Beat(ts=start + 1, rr_ms=1000.0, seq=1, ord=1)]
    body = hrv_body(beats, window=Window(start=start, end=start + 600))
    request = parse_request(body)
    production = HrvProductionProvider().infer(request)
    shadow = HrvNeurokitShadowProvider().infer(request)
    assert production.status == "withheld"
    assert production.diagnostics["withheld_detail"] == "over_count_crossSecondOverCount"
    assert shadow.status == "withheld"
    assert shadow.value is None
    assert shadow.withheld_reason == production.withheld_reason == "artifact_fraction"
    assert shadow.diagnostics["withheld_detail"] == production.diagnostics["withheld_detail"]
    first = shadow.diagnostics["windows"][0]
    assert first["coverage_verdict"] == "crossSecondOverCount"
    assert first["rr_coverage"] == pytest.approx(4.0)
    assert reconstruct_end_times(beats, DEFAULT_TUNING).resolved is True


def test_shadow_applies_the_same_coverage_floor_as_production():
    """F3: with a coverage floor configured (production's default is 0.0), the
    shadow withholds exactly where production does instead of returning a number
    for a window production refuses."""
    from frwhoop_inference.providers.hrv import HrvTuning

    start = 1_700_000_000
    beats = [Beat(ts=start + i, rr_ms=1000.0 + float(i % 5), seq=i, ord=i) for i in range(60)]
    body = hrv_body(beats, window=Window(start=start, end=start + 300))
    request = parse_request(body)
    strict = HrvTuning(min_coverage=0.9)

    strict_production = HrvProductionProvider(tuning=strict).infer(request)
    strict_shadow = HrvNeurokitShadowProvider(tuning=strict).infer(request)
    assert strict_production.status == "withheld"
    assert strict_production.diagnostics["withheld_detail"] == "low_coverage"
    assert strict_shadow.status == "withheld"
    assert strict_shadow.value is None
    assert strict_shadow.diagnostics["withheld_detail"] == "low_coverage"
    assert strict_shadow.withheld_reason == strict_production.withheld_reason
    assert strict_shadow.diagnostics["windows"][0]["coverage"] == pytest.approx(0.2004, abs=5e-4)

    # with the shipped tuning (no coverage floor) both providers still score it,
    # so the gate - not the payload - is what changed
    loose_production = HrvProductionProvider().infer(request)
    loose_shadow = HrvNeurokitShadowProvider().infer(request)
    assert loose_production.status == "ok" and loose_shadow.status == "ok"
    assert loose_shadow.value == pytest.approx(loose_production.value, abs=1e-6)


def test_shadow_respects_the_beat_floor():
    beats = _clean_beats(count=12)
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    outcome = HrvNeurokitShadowProvider().infer(parse_request(hrv_body(beats, window=window)))
    assert outcome.status == "withheld"
    assert outcome.withheld_reason == WithheldReason.INSUFFICIENT_COVERAGE.value
    assert outcome.diagnostics["withheld_detail"] == "insufficient_clean_beats"


def test_shadow_is_never_publishable():
    beats = _clean_beats()
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    request = parse_request(hrv_body(beats, window=window, provider_id="neurokit2.shadow.v1"))
    outcome = HrvNeurokitShadowProvider().infer(request)
    assert outcome.status == "ok"
    assert outcome.publishable is False
    assert outcome.final_or_provisional == "provisional"
    assert outcome.diagnostics["accuracy_label"] == "unverified_accuracy"
    capability = HrvNeurokitShadowProvider().capability()
    assert capability["publishable"] is False
    assert capability["accuracy_label"] == "unverified_accuracy"
    assert capability["eligibility"]["state"] == "unverified"


def test_shadow_provider_readiness_reports_the_pinned_version():
    provider = HrvNeurokitShadowProvider()
    ready, reason = provider.readiness()
    assert ready is True, reason
    assert provider.versions()["dependency"] == "neurokit2==0.2.13"
    assert provider.versions()["model"] is None


# -- hard rules on the call -------------------------------------------------


def test_neurokit2_is_called_with_a_dict_and_never_a_bare_list(monkeypatch):
    captured: dict = {}

    class StubNeuroKit:
        __version__ = "0.2.13"

        @staticmethod
        def hrv_time(peaks, sampling_rate=None):
            captured["peaks"] = peaks
            captured["sampling_rate"] = sampling_rate
            return pd.DataFrame({"HRV_RMSSD": [12.5], "HRV_MeanNN": [1000.0],
                                 "HRV_SDNN": [10.0], "HRV_pNN50": [1.0]})

    monkeypatch.setattr(hrv_module, "_neurokit2_module", lambda: StubNeuroKit)
    out = hrv_module.neurokit2_hrv_time([1000.0, 1010.0], [10.0, 11.01])
    assert isinstance(captured["peaks"], dict)
    assert set(captured["peaks"]) == {"RRI", "RRI_Time"}
    assert captured["peaks"]["RRI"] == [1000.0, 1010.0]
    assert captured["peaks"]["RRI_Time"] == [10.0, 11.01]
    assert captured["sampling_rate"] is None
    assert out["rmssd"] == pytest.approx(12.5)


def test_neurokit2_non_finite_output_is_withheld(monkeypatch):
    class StubNeuroKit:
        __version__ = "0.2.13"

        @staticmethod
        def hrv_time(peaks, sampling_rate=None):
            return pd.DataFrame({"HRV_RMSSD": [float("nan")], "HRV_MeanNN": [1000.0]})

    monkeypatch.setattr(hrv_module, "_neurokit2_module", lambda: StubNeuroKit)
    beats = _clean_beats()
    window = Window(start=beats[0].ts - 5, end=beats[-1].ts + 5)
    outcome = HrvNeurokitShadowProvider().infer(parse_request(hrv_body(beats, window=window)))
    assert outcome.status == "withheld"
    assert outcome.diagnostics["withheld_detail"] == "neurokit2_non_finite"
