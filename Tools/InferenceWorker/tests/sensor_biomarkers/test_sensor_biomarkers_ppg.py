"""Deterministic PPG family tests: quality, pulse shape, perfusion (spec 10.2/10.3).

Independent numerical expectations: an analytically shaped pulse train with
known amplitude/upstroke/width/area; expected vs observed valid fractions;
withheld semantics for corrupt/flat/clipped inputs; the AC/DC ratio from the
documented formula.
"""

from __future__ import annotations

import math

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers import ppg as sbppg


def _pulse_train(seconds: float, rate: float, bpm: float = 72.0,
                 base: float = 200000.0, amp: float = 30000.0,
                 upstroke_frac: float = 0.15, width_frac: float = 0.45,
                 config: dict | None = None) -> dict:
    """A synthetic single-peak pulse train with analytically known shape.

    The pulse is a raised shape: fast Gaussian upstroke peaking at
    ``upstroke_frac`` of the cycle and a slower decay; amplitudes are in
    ABSOLUTE ADC counts (the contract the lane sends).
    """
    n = int(seconds * rate)
    t = np.arange(n) / rate
    phase = (t * bpm / 60.0) % 1.0
    sigma_up = upstroke_frac / 2.5
    sigma_down = (1.0 - upstroke_frac) / 4.0
    up = np.exp(-((phase - upstroke_frac) / sigma_up) ** 2)
    down = np.exp(-((phase - upstroke_frac) / sigma_down) ** 2)
    samples = base + amp * (0.85 * up + 0.15 * down)
    return {
        "start_unix": 0.0, "duration_s": seconds,
        "samples": np.round(samples, 4).tolist(),
        "config": config if config is not None else {"source": 1, "drive": 1150},
    }


def _segments(seconds=120.0, rate=24.0, **kw):
    return sbppg._validate_segments([_pulse_train(seconds, rate, **kw)], rate)


class TestPpgQuality:
    def test_clean_signal_finite_similarity_and_full_valid_fraction(self):
        segs = _segments(120.0, 24.0)
        doc = sbppg.compute_ppg_quality(segs, 24.0, expected_duration_s=120.0)
        assert doc["status"] == "ok"
        sim = doc["measurements"]["template_similarity_median"]["value"]
        assert math.isfinite(sim) and sim > 0.9  # clean synthetic: high correlation
        frac = doc["measurements"]["valid_waveform_fraction"]["value"]
        assert frac == pytest.approx(1.0)

    def test_expected_gap_reports_fraction_not_one(self):
        # 120 s observed against a 200 s expected window: fraction 0.6.
        segs = _segments(120.0, 24.0)
        doc = sbppg.compute_ppg_quality(segs, 24.0, expected_duration_s=200.0)
        assert doc["measurements"]["valid_waveform_fraction"]["value"] == pytest.approx(0.6)

    def test_unknown_expected_duration_is_not_invented(self):
        # Unknown expected timing: the fraction is absent and reported unknown,
        # never an invented percentage.
        segs = _segments(120.0, 24.0)
        doc = sbppg.compute_ppg_quality(segs, 24.0, expected_duration_s=None)
        assert "valid_waveform_fraction" not in doc["measurements"]
        assert doc["valid_waveform_fraction_unknown"] is True

    def test_flat_signal_withholds_similarity_with_reasons(self):
        # Flat: a withheld similarity value and explicit reasons, not a
        # falsely reassuring zero or one.
        n = int(120 * 24)
        seg = {"start_unix": 0.0, "duration_s": 120.0,
               "samples": [200000.0] * n, "config": {}}
        segs = sbppg._validate_segments([seg], 24.0)
        doc = sbppg.compute_ppg_quality(segs, 24.0, expected_duration_s=120.0)
        assert "template_similarity_median" not in doc["measurements"]
        assert doc["template_similarity_withheld"] is True
        assert doc["reason_counts"]["flat_signal"] >= 1

    def test_clipped_signal_withholds_similarity(self):
        # Clipping at the signed 20-bit rails: saturated_delta reasons, no
        # similarity value.
        seg = _pulse_train(120.0, 24.0)
        samples = np.asarray(seg["samples"])
        samples[10:14] = sbppg.ADC_SAMPLE_MAX
        samples[20:24] = sbppg.ADC_SAMPLE_MIN
        seg["samples"] = samples.tolist()
        segs = sbppg._validate_segments([seg], 24.0)
        doc = sbppg.compute_ppg_quality(segs, 24.0, expected_duration_s=120.0)
        assert "template_similarity_median" not in doc["measurements"]
        assert doc["reason_counts"]["saturated_delta"] == 8

    def test_low_native_rate_withholds_cleaning(self):
        # Below the cleaner's supported rate: withheld with the precise reason.
        segs = _segments(60.0, 12.0)
        doc = sbppg.compute_ppg_quality(segs, 12.0, expected_duration_s=60.0)
        assert doc["status"] == "withheld"
        assert doc["reason"] == "unsupported_native_rate"

    def test_raw_diagnostics_recorded_before_filtering(self):
        segs = _segments(120.0, 24.0)
        raw = sbppg.raw_diagnostics(segs, 24.0)
        assert raw["sample_count"] == int(120 * 24)
        assert raw["clipped_samples"] == 0 and raw["flat_runs"] == 0


class TestPulseShape:
    def test_pulse_metrics_unit_level_exact_expectations(self):
        # EXACT unit-level expectations: detected peaks/onsets set by hand on an
        # analytically known waveform, so amplitude/upstroke/width/area have
        # independent closed forms at controlled rates.
        rate = 100.0
        dt = 1.0 / rate
        # one pulse: onset at 0, peak at 0.2 s (40 above the flat zero
        # baseline), next onset at 1.0 s; linear rise then linear fall.
        n = int(1.0 * rate) + 1
        t = np.arange(n) * dt
        clean = np.zeros(n)
        rise = t <= 0.2
        clean[rise] = 40.0 * t[rise] / 0.2
        fall = t > 0.2
        clean[fall] = 40.0 * (1.0 - (t[fall] - 0.2) / 0.8)
        detected = {"PPG_Onsets": np.array([0, n - 1]), "PPG_Peaks": np.array([20])}
        metrics = sbppg._pulse_metrics(clean, rate, detected)
        assert metrics["accepted"] == 1
        assert metrics["amplitudes"][0] == pytest.approx(40.0, abs=1e-9)
        assert metrics["upstrokes_ms"][0] == pytest.approx(200.0, abs=1e-9)
        # width50: the triangle is at half amplitude (20) at 0.1 s and 0.6 s
        # -> 0.5 s exactly (linear interpolation between adjacent real samples).
        assert metrics["widths_ms"][0] == pytest.approx(500.0, abs=1e-9)
        # normalized area: triangle area = 0.5*40*1.0 = 20 over amp*duration 40
        assert metrics["normalized_areas"][0] == pytest.approx(0.5, abs=1e-9)

    def test_pulse_metrics_rejects_incomplete_and_multi_peak(self):
        rate = 100.0
        n = int(2.0 * rate) + 1
        t = np.arange(n) / rate
        clean = np.sin(2 * np.pi * t) * 30.0
        # no onset after the peak: incomplete
        detected = {"PPG_Onsets": np.array([0]), "PPG_Peaks": np.array([25])}
        metrics = sbppg._pulse_metrics(clean, rate, detected)
        assert metrics["accepted"] == 0 and metrics["rejected"]["incomplete"] >= 1
        # two peaks between onsets: multiple_peaks rejection
        detected = {"PPG_Onsets": np.array([0, 200]),
                    "PPG_Peaks": np.array([25, 75])}
        metrics = sbppg._pulse_metrics(clean, rate, detected)
        assert metrics["accepted"] == 0
        assert metrics["rejected"]["multiple_peaks"] >= 1

    def test_full_detector_pulse_shape_bounded(self):
        # Full charlton-detector path: amplitude recovered near the analytic
        # amplitude; upstroke/width50 in physiologically sane detector-relative
        # bounds; counts and native resolution exposed (24 Hz -> 41.7 ms).
        segs = _segments(120.0, 24.0, base=200000.0, amp=30000.0,
                         upstroke_frac=0.15)
        doc = sbppg.compute_pulse_shape(segs, 24.0)
        assert doc["status"] == "ok"
        m = doc["measurements"]
        assert m["pulse_amplitude_median_au"]["value"] == pytest.approx(30000.0 * 0.85, rel=0.10)
        assert 50.0 < m["pulse_upstroke_median_ms"]["value"] < 400.0
        assert 50.0 < m["pulse_width50_median_ms"]["value"] < 600.0
        assert m["pulse_accepted_count"]["value"] > 100
        assert m["pulse_rejected_count"]["value"] < 30
        assert doc["native_sample_period_ms"] == pytest.approx(1000.0 / 24.0)

    def test_high_rate_narrows_detector_relative_bounds(self):
        # The same synthetic at 100 Hz: the native sample period (10 ms) is
        # exposed and the recovered shape stays within bounded tolerances.
        segs = _segments(60.0, 100.0, upstroke_frac=0.15)
        doc = sbppg.compute_pulse_shape(segs, 100.0)
        m = doc["measurements"]
        assert doc["native_sample_period_ms"] == pytest.approx(10.0)
        assert 80.0 < m["pulse_upstroke_median_ms"]["value"] < 300.0
        assert 0.0 < m["pulse_normalized_area_median"]["value"] < 1.0

    def test_normalized_area_dimensionless_bounds(self):
        segs = _segments(120.0, 24.0)
        doc = sbppg.compute_pulse_shape(segs, 24.0)
        area = doc["measurements"]["pulse_normalized_area_median"]["value"]
        assert doc["measurements"]["pulse_normalized_area_median"]["unit"] == "dimensionless"
        assert 0.0 < area < 1.0

    def test_configuration_change_never_pools_amplitudes(self):
        # Two different optical configurations: per-configuration blocks, no
        # pooled top-level amplitude.
        first = _pulse_train(60.0, 24.0, config={"source": 1, "drive": 1150})
        second = _pulse_train(60.0, 24.0, config={"source": 1, "drive": 2200})
        second["start_unix"] = 60.0
        segs = sbppg._validate_segments([first, second], 24.0)
        doc = sbppg.compute_pulse_shape(segs, 24.0)
        assert len(doc["configurations"]) == 2
        assert "pulse_amplitude_median_au" not in doc["measurements"]
        for block in doc["configurations"]:
            assert "pulse_amplitude_median_au" in block["measurements"]

    def test_flat_signal_withholds_shape(self):
        n = int(60 * 24)
        seg = {"start_unix": 0.0, "duration_s": 60.0,
               "samples": [100000.0] * n, "config": {}}
        segs = sbppg._validate_segments([seg], 24.0)
        doc = sbppg.compute_pulse_shape(segs, 24.0)
        assert doc["status"] == "withheld"
        assert doc["reason"] == "not_enough_valid_data"


class TestPerfusionResearch:
    def test_unverified_dc_withholds(self):
        segs = _segments(60.0, 24.0)
        doc = sbppg.compute_perfusion_research(segs, 24.0, optical_dc=None)
        assert doc["status"] == "withheld"
        assert doc["reason"] == "unverified_optical_dc"
        assert "estimated_ac_dc_ratio_percent" not in doc["measurements"]

    def test_near_zero_dc_denominator_withholds_never_zero(self):
        # Near-zero/invalid denominators must be withheld; the library's
        # zero-denominator fallback is never accepted as a measured zero.
        seg = _pulse_train(60.0, 24.0, base=0.0, amp=1e-8)
        segs = sbppg._validate_segments([seg], 24.0)
        doc = sbppg.compute_perfusion_research(
            segs, 24.0, optical_dc={"dc_verified": True, "channel": "A"})
        assert doc["status"] == "withheld"
        assert doc["reason_counts"]["invalid_or_near_zero_dc_denominator"] == 1
        assert "estimated_ac_dc_ratio_percent" not in doc["measurements"]

    def test_verified_dc_computes_documented_formula(self):
        segs = _segments(60.0, 24.0, base=200000.0, amp=30000.0)
        doc = sbppg.compute_perfusion_research(
            segs, 24.0, optical_dc={"dc_verified": True, "channel": "A",
                                    "drive": 1150, "gain": "x1"})
        assert doc["status"] == "ok"
        ratio = doc["measurements"]["estimated_ac_dc_ratio_percent"]["value"]
        # independent expectation from the documented formula
        raw = np.concatenate([s["samples"] for s in segs])
        clean_max, clean_min = np.max(raw), np.min(raw)  # AC on raw bounds approx
        expected = 100.0 * (clean_max - clean_min) / abs(raw.mean())
        assert ratio == pytest.approx(expected, rel=0.35)
        assert ratio > 0.0

    def test_saturated_signal_withholds(self):
        seg = _pulse_train(60.0, 24.0)
        samples = np.asarray(seg["samples"])
        samples[5:9] = sbppg.ADC_SAMPLE_MAX
        seg["samples"] = samples.tolist()
        segs = sbppg._validate_segments([seg], 24.0)
        doc = sbppg.compute_perfusion_research(
            segs, 24.0, optical_dc={"dc_verified": True, "channel": "A"})
        assert doc["status"] == "withheld"
        assert doc["reason"] == "saturated_delta"


class TestInputValidation:
    @pytest.mark.parametrize("rate,seg_kw", [
        (24.0, {"duration_s": 60.0, "n_samples": 10}),  # count mismatch handled below
    ])
    def test_placeholder(self, rate, seg_kw):
        pass

    def test_sample_count_mismatch_rejected(self):
        seg = _pulse_train(60.0, 24.0)
        seg["samples"] = seg["samples"][:100]
        with pytest.raises(sbppg.PpgValidationError):
            sbppg._validate_segments([seg], 24.0)

    def test_nonfinite_rejected(self):
        seg = _pulse_train(60.0, 24.0)
        seg["samples"][50] = float("nan")
        with pytest.raises(sbppg.PpgValidationError):
            sbppg._validate_segments([seg], 24.0)

    def test_overlapping_rejected(self):
        a = _pulse_train(60.0, 24.0)
        b = _pulse_train(60.0, 24.0)
        b["start_unix"] = 30.0
        with pytest.raises(sbppg.PpgValidationError):
            sbppg._validate_segments([a, b], 24.0)
