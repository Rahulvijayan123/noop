"""Deterministic IMU family tests: ENMO, bouts, oscillation power (spec 10.2).

Independent numerical expectations (NOT implementation constants): ENMO from
first-principles vector magnitudes; Welch band power from the analytic
single-sine PSD integral A^2/2 per axis; hysteresis/bout semantics from the
specified state machine.
"""

from __future__ import annotations

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers import imu as sbimu


def _stationary_run(start: float, seconds: float, rate: float = 100.0,
                    gravity_axis: int = 2) -> dict:
    n = int(seconds * rate)
    accel = np.zeros((n, 3))
    accel[:, gravity_axis] = 1.0
    gyro = np.zeros((n, 3))
    return {
        "start_unix": start, "duration_s": seconds,
        "accel_g": accel.tolist(), "gyro_dps": gyro.tolist(),
    }


def _mag_run(start: float, seconds: float, magnitude: float,
             rate: float = 100.0) -> dict:
    """A gravity-realistic run: |a| = magnitude along +x, so ENMO measures the
    above-1 g component. Low state: magnitude 1.0 (ENMO 0 mg); moving state:
    magnitude 1.1 (ENMO 100 mg, above the 50 mg leave threshold)."""
    n = int(seconds * rate)
    accel = np.zeros((n, 3))
    accel[:, 0] = magnitude  # |a| = magnitude along x
    return {
        "start_unix": start, "duration_s": seconds,
        "accel_g": accel.tolist(), "gyro_dps": np.zeros((n, 3)).tolist(),
    }


_LOW = 1.0    # stationary: ENMO 0 mg (< 30 enter threshold)
_MOVING = 1.1  # ENMO 100 mg (>= 50 leave threshold)


def _moving_run(start: float, seconds: float, rate: float = 100.0) -> dict:
    """Physically moving: |a| = 1.1 g + a 2 Hz 0.05 g wobble. Every 5 s epoch
    holds whole wobble periods, so its ENMO is still exactly 100 mg, but no
    1 s window is still (a still strap reads gravity alone)."""
    run = _mag_run(start, seconds, _MOVING, rate)
    t = np.arange(int(seconds * rate)) / rate
    accel = np.asarray(run["accel_g"])
    accel[:, 0] += 0.05 * np.sin(2 * np.pi * 2.0 * t)
    run["accel_g"] = accel.tolist()
    return run


def _grid(segments, rate=100.0):
    return sbimu.build_epoch_grid(segments, rate)


class TestEnmo:
    def test_stationary_one_g_is_zero_enmo(self):
        # A stationary orientation test produces magnitude exactly 1 g: ENMO 0.
        grid = _grid([_stationary_run(0.0, 60.0)])
        values = sbimu.enmo_epoch_values(grid["t"], grid["accel"], 100.0)
        assert values and all(v == 0.0 for v in values)

    def test_analytic_above_one_g_magnitude(self):
        # |a| = 1.05 g constant -> per-sample ENMO = 50 mg in EVERY epoch.
        grid = _grid([_mag_run(0.0, 60.0, 1.05)])
        values = sbimu.enmo_epoch_values(grid["t"], grid["accel"], 100.0)
        assert values and all(abs(v - 50.0) < 1e-9 for v in values)

    def test_mg_scale(self):
        # |a| = 1.5 g -> 500 mg: the mg scale is 1000 * (|a| - 1).
        grid = _grid([_mag_run(0.0, 60.0, 1.5)])
        values = sbimu.enmo_epoch_values(grid["t"], grid["accel"], 100.0)
        assert values and all(abs(v - 500.0) < 1e-9 for v in values)

    def test_complete_and_partial_epoch_handling(self):
        # 12.5 s at 100 Hz: complete epochs at 0-5 and 5-10 s; 2.5 s partial
        # usable time is reported separately and NEVER classified.
        grid = _grid([_stationary_run(0.0, 12.5)])
        values = sbimu.enmo_epoch_values(grid["t"], grid["accel"], 100.0)
        assert len(values) == 2  # only complete UTC-aligned 5 s epochs
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 12.5)
        assert doc["status"] == "ok"
        assert doc["partial_epoch_seconds"] == pytest.approx(2.5, abs=0.05)

    def test_utc_epoch_alignment(self):
        # Epochs align to whole 5 s unix multiples: a run starting at t=2.5 s
        # yields its first COMPLETE epoch at t=5.0 s, not at 2.5 s.
        grid = _grid([_stationary_run(2.5, 12.5)])  # spans 2.5 -> 15.0 s
        starts = [e for e, _ in sbimu._complete_epoch_bounds(grid["t"], 100.0, 5)]
        assert starts == [5.0, 10.0]

    def test_unresolved_gravity_offset_withholds_classification(self):
        # Median gravity magnitude far from 1 g: ENMO distribution published
        # labelled uncalibrated, classified summaries withheld, never a silent
        # recalibration.
        grid = _grid([_mag_run(0.0, 60.0, 2.0)])  # |a| = 2 g: implausible offset
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 60.0)
        assert doc["status"] == "ok"
        assert doc["calibrated"] is False
        assert "enmo_median_mg" in doc["measurements"]
        assert "low_movement_fraction" not in doc["measurements"]
        assert doc["reason_counts"]["uncalibrated_gravity_offset"] == 1

    def test_still_strap_reading_a_tenth_g_off_is_uncalibrated(self):
        # Still at 1.1 g is an offset (a still strap reads gravity alone): it
        # would otherwise classify every still epoch as moving.
        doc = sbimu.compute_movement(_grid([_mag_run(0.0, 60.0, 1.1)]), 100.0, 0.0, 60.0)
        assert doc["calibrated"] is False
        assert doc["median_gravity_magnitude_g"] == pytest.approx(1.1)


class TestLowMovementHysteresis:
    def test_state_machine(self):
        # enter < 30, leave >= 50, middle retains prior; unknown until crossed
        values = [40.0, 40.0, 10.0, 40.0, 60.0, 40.0, 40.0, 10.0]
        states = sbimu.low_movement_state_sequence(values)
        assert states == ["unknown", "unknown", "low", "low", "moving",
                           "moving", "moving", "low"]

    def test_gap_creates_no_transition_and_censors_the_bout(self):
        # Two runs separated by a real gap: the open low bout is censored and
        # NO low->moving transition is counted across the gap.
        segs = [_mag_run(0.0, 10.0, _LOW), _moving_run(20.0, 10.0)]
        grid = _grid(segs)
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 30.0)
        assert doc["measurements"]["low_to_moving_transition_count"]["value"] == 0
        assert doc["low_movement_censored_bout_count"] == 1

    def test_bout_across_adjacent_segments_is_one_bout(self):
        # A bout spanning an object/segment boundary (no gap) stays ONE bout:
        # chunks must not fragment bouts.
        segs = [_mag_run(0.0, 10.0, _LOW), _mag_run(10.0, 10.0, _LOW)]
        grid = _grid(segs)
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 20.0)
        assert doc["measurements"]["low_movement_bout_count"]["value"] == 1
        assert doc["measurements"]["low_movement_bout_max_seconds"]["value"] == 20.0

    def test_day_boundary_is_a_continuation(self):
        # A bout whose first epoch starts at the interval start is a
        # continuation, not a new bout created by the date change.
        segs = [_mag_run(0.0, 10.0, _LOW), _moving_run(10.0, 10.0)]
        grid = _grid(segs)
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 20.0)
        assert doc["low_movement_continuation_count"] == 1
        # same run ending exactly at the interval end:
        segs2 = [_moving_run(0.0, 10.0), _mag_run(10.0, 10.0, _LOW)]
        grid2 = _grid(segs2)
        doc2 = sbimu.compute_movement(grid2, 100.0, 0.0, 20.0)
        assert doc2["low_movement_continuation_count"] == 1

    def test_gap_is_seen_when_the_next_run_starts_mid_epoch(self):
        # The second run starts at 22.5 s: its first complete epoch is 25 s, so
        # the gap end never coincides with an epoch start. It is still a gap.
        segs = [_mag_run(0.0, 10.0, _LOW), _moving_run(22.5, 12.5)]
        doc = sbimu.compute_movement(_grid(segs), 100.0, 0.0, 40.0)
        assert doc["measurements"]["low_to_moving_transition_count"]["value"] == 0
        assert doc["low_movement_censored_bout_count"] == 1

    def test_hysteresis_restarts_unknown_after_a_gap(self):
        # A run that starts in the 30-50 mg middle band after a gap is unknown,
        # not a continuation of the pre-gap low state.
        segs = [_mag_run(0.0, 10.0, _LOW), _mag_run(20.0, 10.0, 1.04)]
        doc = sbimu.compute_movement(_grid(segs), 100.0, 0.0, 30.0)
        assert doc["reason_counts"]["unknown_state_epochs"] == 2
        assert doc["measurements"]["low_movement_seconds"]["value"] == 10.0

    def test_epoch_series_is_emitted_for_the_day_lane(self):
        segs = [_mag_run(0.0, 10.0, _LOW), _moving_run(10.0, 10.0)]
        doc = sbimu.compute_movement(_grid(segs), 100.0, 0.0, 20.0)
        assert [s for s, _ in doc["enmo_epochs"]] == [0.0, 5.0, 10.0, 15.0]
        assert [v for _, v in doc["enmo_epochs"]] == pytest.approx([0.0, 0.0, 100.0, 100.0], abs=1e-3)

    def test_transition_counting(self):
        # low -> moving -> low -> moving = 2 transitions; 20 classified s.
        segs = [_mag_run(0.0, 10.0, _LOW), _moving_run(10.0, 10.0),
                _mag_run(20.0, 10.0, _LOW), _moving_run(30.0, 10.0)]
        grid = _grid(segs)
        doc = sbimu.compute_movement(grid, 100.0, 0.0, 40.0)
        assert doc["measurements"]["low_to_moving_transition_count"]["value"] == 2
        # 40 classified seconds = 1/90 h -> 2 transitions per 1/90 h = 180/h
        per_hour = doc["measurements"]["low_to_moving_transitions_per_observed_hour"]["value"]
        assert per_hour == pytest.approx(180.0, rel=0.01)


class TestOscillationPower:
    def test_sine_band_allocation_2hz_vs_5hz(self):
        # A 2 Hz sine lies OUTSIDE the 3-7 Hz band: near-zero power. The same
        # amplitude at 5 Hz lands inside: analytic single-axis power A^2/2.
        rate = 100.0
        n = int(120 * rate)
        t = np.arange(n) / rate
        for freq, expected in ((2.0, 0.0), (5.0, 50.0 ** 2 / 2.0)):
            gyro = np.zeros((n, 3))
            gyro[:, 1] = 50.0 * np.sin(2 * np.pi * freq * t)
            seg = {"start_unix": 0.0, "duration_s": 120.0,
                   "accel_g": np.zeros((n, 3)).tolist(), "gyro_dps": gyro.tolist()}
            grid = _grid([seg])
            values = sbimu.oscillation_power_window_values(grid["t"], grid["gyro"], rate)
            median = float(np.median(values))
            assert median == pytest.approx(expected, rel=0.05), (freq, median)

    def test_amplitude_squared_scaling(self):
        # Doubling the sine amplitude quadruples the band power (A^2 scaling).
        rate = 100.0
        n = int(120 * rate)
        t = np.arange(n) / rate
        powers = []
        for amp in (25.0, 50.0):
            gyro = np.zeros((n, 3))
            gyro[:, 1] = amp * np.sin(2 * np.pi * 5.0 * t)
            seg = {"start_unix": 0.0, "duration_s": 120.0,
                   "accel_g": np.zeros((n, 3)).tolist(), "gyro_dps": gyro.tolist()}
            grid = _grid([seg])
            values = sbimu.oscillation_power_window_values(grid["t"], grid["gyro"], rate)
            powers.append(float(np.median(values)))
        assert powers[1] == pytest.approx(4.0 * powers[0], rel=0.05)

    def test_independent_reference_integration(self):
        # Independent numerical reference: exact integral of the one-sided
        # analytic PSD over the band vs the Welch estimate (documented 5%
        # tolerance for Hann leakage/overlap effects at 0.5 Hz resolution).
        rate = 100.0
        n = int(120 * rate)
        t = np.arange(n) / rate
        amp = 80.0
        gyro = np.zeros((n, 3))
        gyro[:, 2] = amp * np.sin(2 * np.pi * 4.0 * t)  # 4 Hz, inside band
        seg = {"start_unix": 0.0, "duration_s": 120.0,
               "accel_g": np.zeros((n, 3)).tolist(), "gyro_dps": gyro.tolist()}
        grid = _grid([seg])
        values = sbimu.oscillation_power_window_values(grid["t"], grid["gyro"], rate)
        assert float(np.median(values)) == pytest.approx(amp ** 2 / 2.0, rel=0.05)

    def test_dominant_frequency_and_resolution(self):
        rate = 100.0
        n = int(120 * rate)
        t = np.arange(n) / rate
        gyro = np.zeros((n, 3))
        gyro[:, 0] = 60.0 * np.sin(2 * np.pi * 5.0 * t)
        seg = {"start_unix": 0.0, "duration_s": 120.0,
               "accel_g": np.zeros((n, 3)).tolist(), "gyro_dps": gyro.tolist()}
        grid = _grid([seg])
        doc = sbimu.compute_oscillation(grid, rate)
        assert doc["measurements"]["wrist_oscillation_dominant_frequency_hz"]["value"] == 5.0
        assert doc["spectral_resolution_hz"] == pytest.approx(0.5)

    def test_flat_gyro_dominant_frequency_is_null(self):
        # Flat/noise-only data must never force a peak: dominant is null when
        # the band power is zero, and the family still publishes band power.
        grid = _grid([_stationary_run(0.0, 60.0)])
        doc = sbimu.compute_oscillation(grid, 100.0)
        assert doc["measurements"]["wrist_oscillation_power_3_7hz_median"]["value"] == pytest.approx(0.0, abs=1e-12)
        assert "wrist_oscillation_dominant_frequency_hz" not in doc["measurements"]


class TestInputValidation:
    @pytest.mark.parametrize("bad", [
        [{"start_unix": 0, "duration_s": 10, "accel_g": [[0, 0, 17.0]], "gyro_dps": [[0, 0, 0]]}],  # >16 g rail
        [{"start_unix": 0, "duration_s": 10, "accel_g": [[0, 0, float("nan")]], "gyro_dps": [[0, 0, 0]]}],
        [{"start_unix": 0, "duration_s": 10, "accel_g": [[0, 0]], "gyro_dps": [[0, 0, 0]]}],  # not triples
        [{"start_unix": 0, "duration_s": 10, "accel_g": [], "gyro_dps": []}],
    ])
    def test_malformed_imu_is_rejected(self, bad):
        with pytest.raises(sbimu.ImuValidationError):
            _grid(bad)

    def test_overlapping_segments_rejected(self):
        segs = [_mag_run(0.0, 10.0, 1.0), _mag_run(5.0, 10.0, 1.0)]
        with pytest.raises(sbimu.ImuValidationError):
            _grid(segs)

    def test_no_segments_rejected(self):
        with pytest.raises(sbimu.ImuValidationError):
            _grid([])
