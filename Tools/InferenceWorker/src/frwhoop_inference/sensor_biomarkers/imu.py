"""Movement + oscillation families: ENMO, low-movement bouts, gyro 3-7 Hz power.

Spec sections 6.1/6.2; CONTRACTS.md sections 2-4. Deterministic, pure numpy.

Design notes
------------
* ENMO per sample (mg): ``1000 * max(sqrt(x^2+y^2+z^2) - 1, 0)`` with accel in g.
* 5-second epochs are UTC-aligned and nonoverlapping (epoch start on a whole
  multiple of 5 s of unix time). Only COMPLETE epochs (full sample count at the
  native rate) classify state; partial epoch seconds are reported as usable
  partial time, never classified.
* Low-movement hysteresis (versioned engineering thresholds, NOT validated WHOOP
  sedentary cutoffs): enter < 30 mg, leave >= 50 mg, middle band retains the
  prior state; a run that STARTS in the middle band is ``unknown`` until a
  boundary is crossed.
* Gaps (missing epochs) end bouts as censored, create NO transition, and a new
  run never implies a transition. A bout touching an interval boundary is a
  continuation (recorded separately), not a new bout for the date change.
* Oscillation power: axis-wise Welch PSD (Hann window, constant detrend,
  2 s segments = nperseg 2*fs, 50% overlap) on complete UTC-aligned 4-second
  windows; the summed x/y/z PSD is integrated over 3-7 Hz with the boundary
  convention **half-open [3, 7)** on bin CENTER frequencies (a bin contributes
  iff 3 <= f_center < 7), documented here. Unit: (deg/s)^2.
* Dominant frequency is published only when the band power is nonzero, together
  with the spectral resolution (fs / nperseg); otherwise null. Never a forced
  peak in flat/noise-only data.
"""

from __future__ import annotations

import math
from typing import Any

import numpy as np

from . import PROVIDER_REVISIONS
from .contract import family_document, measurement

#: Versioned engineering thresholds (spec 6.1). NOT validated WHOOP sedentary
#: cutoffs and NOT clinical reference values; bump the version string when they move.
LOW_MOVEMENT_ENTER_MG = 30.0
LOW_MOVEMENT_LEAVE_MG = 50.0
MOVEMENT_THRESHOLD_VERSION = "low-movement-hysteresis/1.0.0"

ENMO_EPOCH_SECONDS = 5
OSCILLATION_WINDOW_SECONDS = 4
BAND_LOW_HZ = 3.0
BAND_HIGH_HZ = 7.0

#: Sanity bounds for verified accelerometer input in g: the WHOOP accelerometer
#: range is far below this; values outside are implausible unit scaling or ADC
#: rails, not measurements.
ACCEL_ABS_BOUND_G = 16.0
GYRO_ABS_BOUND_DPS = 4000.0

#: A stationary, worn strap reads ~1 g. If the median magnitude over the run is
#: outside this band the device's gravity offset is unresolved: ENMO stays
#: publishable but labelled uncalibrated, and the low-movement CLASSIFIED
#: summaries are withheld (spec 6.1: never fit a new calibration silently).
GRAVITY_NOMINAL_G = 1.0
GRAVITY_TOLERANCE_G = 0.3


class ImuValidationError(ValueError):
    """The IMU input is malformed (shapes, units, finiteness, timestamps)."""


def _as_array_3d(values: Any, name: str, bound: float, unit: str) -> np.ndarray:
    arr = np.asarray(values, dtype=float)
    if arr.ndim != 2 or arr.shape[1] != 3 or arr.shape[0] == 0:
        raise ImuValidationError(
            f"{name} must be a non-empty list of [x, y, z] triples in {unit}")
    if not np.all(np.isfinite(arr)):
        raise ImuValidationError(f"{name} contains non-finite samples")
    if np.any(np.abs(arr) > bound):
        raise ImuValidationError(
            f"{name} contains |values| > {bound} {unit}: implausible unit scaling or ADC rails")
    return arr


def build_epoch_grid(segments: list[dict[str, Any]], rate_hz: float) -> dict[str, Any]:
    """Merge time-ordered, non-overlapping IMU segments into a UTC-aligned sample grid.

    Returns ``{"t": sorted unix sample times (float), "accel": (n, 3),
    "gyro": (n, 3), "gaps": [(t_end_of_run, t_start_of_next_run)]}``.
    """
    if not segments:
        raise ImuValidationError("no IMU segments")
    t_all: list[np.ndarray] = []
    a_all: list[np.ndarray] = []
    g_all: list[np.ndarray] = []
    prev_end: float | None = None
    gaps: list[tuple[float, float]] = []
    for seg in segments:
        start = seg.get("start_unix")
        duration = seg.get("duration_s")
        accel = _as_array_3d(seg.get("accel_g"), "accel_g", ACCEL_ABS_BOUND_G, "g")
        gyro = _as_array_3d(seg.get("gyro_dps"), "gyro_dps", GYRO_ABS_BOUND_DPS, "deg/s")
        if not isinstance(start, (int, float)) or not isinstance(duration, (int, float)):
            raise ImuValidationError("segment start_unix/duration_s must be numbers")
        start = float(start)
        duration = float(duration)
        n = accel.shape[0]
        if gyro.shape[0] != n:
            raise ImuValidationError("accel_g and gyro_dps must carry the same sample count")
        expected = int(round(duration * rate_hz))
        if abs(n - expected) > max(1, int(0.02 * expected)):
            raise ImuValidationError(
                f"segment duration {duration}s at {rate_hz} Hz implies ~{expected} samples, got {n}")
        t = start + np.arange(n) / float(rate_hz)
        if prev_end is not None and t[0] <= prev_end:
            raise ImuValidationError("segments must be time-ordered and non-overlapping")
        if prev_end is not None and t[0] - prev_end > 1.5 / rate_hz:
            gaps.append((prev_end, t[0]))
        t_all.append(t)
        a_all.append(accel)
        g_all.append(gyro)
        prev_end = float(t[-1])
    return {
        "t": np.concatenate(t_all),
        "accel": np.vstack(a_all),
        "gyro": np.vstack(g_all),
        "gaps": gaps,
    }


def _complete_epoch_bounds(t: np.ndarray, rate_hz: float, epoch_seconds: int):
    """Yield (epoch_start, idx_slice) for every COMPLETE UTC-aligned epoch.

    An epoch is complete when it holds the full sample count (with a one-sample
    tolerance for the inclusive endpoint convention) between its boundaries.
    """
    step = float(epoch_seconds)
    first_epoch = math.floor(t[0] / step) * step
    last_t = float(t[-1])
    epoch = first_epoch
    while epoch <= last_t:
        lo = np.searchsorted(t, epoch - 1e-9, side="left")
        hi = np.searchsorted(t, epoch + step + 1e-9, side="left")
        # a sample exactly on the next epoch boundary belongs to the next epoch
        if hi - lo + 1 >= int(round(step * rate_hz)):
            yield epoch, (lo, hi)
        epoch += step


def enmo_epoch_values(t: np.ndarray, accel: np.ndarray, rate_hz: float) -> list[float]:
    """Mean ENMO (mg) per complete UTC-aligned 5-second epoch."""
    values: list[float] = []
    for _, (lo, hi) in _complete_epoch_bounds(t, rate_hz, ENMO_EPOCH_SECONDS):
        mag = np.linalg.norm(accel[lo:hi], axis=1)
        enmo_mg = 1000.0 * np.maximum(mag - 1.0, 0.0)
        values.append(float(enmo_mg.mean()))
    return values


def low_movement_state_sequence(epoch_values: list[float]) -> list[str]:
    """Hysteretic low/moving/unknown state per complete epoch.

    Enter < 30 mg, leave >= 50 mg; the middle band retains the previous KNOWN
    state. A sequence that starts in the middle band stays ``unknown`` until a
    boundary is crossed.
    """
    state = "unknown"
    states: list[str] = []
    for v in epoch_values:
        if v < LOW_MOVEMENT_ENTER_MG:
            state = "low"
        elif v >= LOW_MOVEMENT_LEAVE_MG:
            state = "moving"
        # else: middle band retains the prior state (possibly unknown)
        states.append(state)
    return states


def classify_bouts(
    epoch_values: list[float],
    epoch_starts: list[float],
    gaps: list[tuple[float, float]],
    interval_start: float,
    interval_end: float,
) -> dict[str, Any]:
    """Bouts, transitions and censoring over the classified epoch sequence.

    Gap handling: a gap between two epochs ends the open bout (censored) and
    creates NO transition; a new run never implies a transition. A bout whose
    first epoch starts at/before the interval start, or whose close lands at/after
    the interval end, is a continuation across the day boundary, not a new bout
    created by the date change.
    """
    states = low_movement_state_sequence(epoch_values)
    epochs_low = [v for v, s in zip(epoch_values, states) if s == "low"]
    bout_seconds = 0.0
    bout_durations: list[float] = []
    censored = 0
    continuations = 0
    transitions = 0
    open_bout: float | None = None
    prev_state: str | None = None
    # A gap whose end coincides with this epoch's start separates runs.
    gap_end_times = {round(g_end, 6) for _, g_end in gaps}
    for i, (value, state) in enumerate(zip(epoch_values, states)):
        start = epoch_starts[i]
        end = start + ENMO_EPOCH_SECONDS
        if prev_state is not None and round(start, 6) in gap_end_times:
            # A gap precedes this epoch: close any open bout as censored, and
            # never count a transition across the gap.
            if open_bout is not None:
                bout_durations.append(open_bout)
                censored += 1
                open_bout = None
            prev_state = None
        if state == "low":
            if open_bout is None:
                open_bout = 0.0
                if start <= interval_start + 1e-9:
                    continuations += 1
            open_bout += ENMO_EPOCH_SECONDS
            bout_seconds += ENMO_EPOCH_SECONDS
        else:
            if open_bout is not None:
                bout_durations.append(open_bout)
                if end >= interval_end - 1e-9:
                    continuations += 1
                open_bout = None
            if prev_state == "low" and state == "moving":
                transitions += 1
        prev_state = state
    if open_bout is not None:
        bout_durations.append(open_bout)
        # A trailing bout that ends exactly at the interval end continues into
        # the next day (a continuation); one stopped short of it by the data
        # ending mid-interval is censored (its true duration is unknown).
        trailing_end = (epoch_starts[-1] + ENMO_EPOCH_SECONDS) if epoch_starts else 0.0
        if trailing_end >= interval_end - 1e-9:
            continuations += 1
        else:
            censored += 1
    classified_seconds = float(ENMO_EPOCH_SECONDS) * sum(
        1 for s in states if s != "unknown")
    low_fraction = bout_seconds / classified_seconds if classified_seconds > 0 else None
    observed_hours = classified_seconds / 3600.0
    return {
        "states": states,
        "low_seconds": bout_seconds,
        "low_fraction": low_fraction,
        "bout_durations": bout_durations,
        "bout_count": len(bout_durations),
        "censored_count": censored,
        "continuation_count": continuations,
        "transitions": transitions,
        "classified_seconds": classified_seconds,
        "observed_hours": observed_hours,
        "epochs_low_count": len(epochs_low),
    }


def compute_movement(grid: dict[str, Any], rate_hz: float,
                     interval_start: float, interval_end: float) -> dict[str, Any]:
    """The movement family document (spec 6.1)."""
    t, accel = grid["t"], grid["accel"]
    observed_seconds = float(t[-1] - t[0]) + 1.0 / rate_hz
    mag = np.linalg.norm(accel, axis=1)
    median_mag = float(np.median(mag))
    calibrated = abs(median_mag - GRAVITY_NOMINAL_G) <= GRAVITY_TOLERANCE_G

    epoch_values = enmo_epoch_values(t, accel, rate_hz)
    epoch_starts = [e for e, _ in _complete_epoch_bounds(t, rate_hz, ENMO_EPOCH_SECONDS)]
    if not epoch_values:
        return family_document(
            family="movement", status="withheld", reason="insufficient_eligible_time",
            measurements={},
            observed_seconds=observed_seconds, eligible_seconds=0.0,
            reason_counts={"no_complete_5s_epochs": 1},
        )

    enmo_arr = np.asarray(epoch_values, dtype=float)
    enmo_median = float(np.median(enmo_arr))
    enmo_p95 = float(np.percentile(enmo_arr, 95))

    measurements: dict[str, Any] = {
        "enmo_median_mg": measurement(
            enmo_median, "mg", denominator="complete 5 s epochs", count=len(epoch_values),
            method="1000*max(|a|-1,0) mean per UTC-aligned 5 s epoch"),
        "enmo_p95_mg": measurement(
            enmo_p95, "mg", denominator="complete 5 s epochs", count=len(epoch_values),
            method="p95 over the same epoch distribution"),
    }
    if calibrated:
        bouts = classify_bouts(
            epoch_values, epoch_starts, grid["gaps"], interval_start, interval_end)
        classified = bouts["classified_seconds"]
        if classified > 0:
            measurements["low_movement_seconds"] = measurement(
                bouts["low_seconds"], "s", denominator="classified observed seconds",
                count=bouts["epochs_low_count"], method="hysteretic low state per epoch")
            measurements["low_movement_fraction"] = measurement(
                bouts["low_fraction"], "fraction",
                denominator="classified observed seconds",
                count=bouts["epochs_low_count"], method="low seconds / classified seconds")
            measurements["low_movement_bout_count"] = measurement(
                bouts["bout_count"], "count", count=bouts["bout_count"],
                method="maximal low-state runs across epochs")
            if bouts["bout_durations"]:
                measurements["low_movement_bout_median_seconds"] = measurement(
                    float(np.median(bouts["bout_durations"])), "s",
                    count=bouts["bout_count"], method="median bout duration")
                measurements["low_movement_bout_max_seconds"] = measurement(
                    float(np.max(bouts["bout_durations"])), "s",
                    count=bouts["bout_count"], method="maximum bout duration")
            measurements["low_to_moving_transition_count"] = measurement(
                bouts["transitions"], "count", count=bouts["transitions"],
                method="low->moving hysteresis crossings, none across gaps")
            if classified > 0:
                measurements["low_to_moving_transitions_per_observed_hour"] = measurement(
                    bouts["transitions"] / bouts["observed_hours"], "transitions/hour",
                    denominator="classified observed hours", count=bouts["transitions"],
                    method="transitions / classified observed hours")
                measurements["low_movement_bouts_per_observed_hour"] = measurement(
                    bouts["bout_count"] / bouts["observed_hours"], "bouts/hour",
                    denominator="classified observed hours", count=bouts["bout_count"],
                    method=("DESCRIPTIVE simple count per classified observed hour; "
                            "NOT a validated GGIR fragmentation score"))
        reason_counts = {
            "censored_bouts": bouts["censored_count"],
            "continuation_bouts": bouts["continuation_count"],
            "unknown_state_epochs": sum(
                1 for s in bouts["states"] if s == "unknown"),
        }
        extra = {
            "low_movement_censored_bout_count": bouts["censored_count"],
            "low_movement_continuation_count": bouts["continuation_count"],
            "threshold_version": MOVEMENT_THRESHOLD_VERSION,
            "partial_epoch_seconds": _partial_epoch_seconds(t, rate_hz),
            "calibrated": True,
        }
        return family_document(
            family="movement", status="ok",
            measurements=measurements,
            observed_seconds=observed_seconds,
            eligible_seconds=float(classified),
            reason_counts=reason_counts, extra=extra,
        )
    # Unresolved gravity offset: publish the ENMO distribution labelled
    # uncalibrated and withhold the classified summaries (never fit a new
    # calibration silently).
    return family_document(
        family="movement", status="ok",
        measurements=measurements,
        observed_seconds=observed_seconds, eligible_seconds=0.0,
        reason_counts={"uncalibrated_gravity_offset": 1},
        extra={"calibrated": False, "median_gravity_magnitude_g": median_mag,
               "threshold_version": MOVEMENT_THRESHOLD_VERSION,
               "partial_epoch_seconds": _partial_epoch_seconds(t, rate_hz)},
    )


def _partial_epoch_seconds(t: np.ndarray, rate_hz: float) -> float:
    """Seconds in incomplete edge epochs (reported as usable partial time)."""
    total = (float(t[-1] - t[0]) + 1.0 / rate_hz) if len(t) else 0.0
    complete = ENMO_EPOCH_SECONDS * sum(
        1 for _ in _complete_epoch_bounds(t, rate_hz, ENMO_EPOCH_SECONDS))
    return max(0.0, total - complete)


def oscillation_power_window_values(t: np.ndarray, gyro: np.ndarray,
                                    rate_hz: float) -> list[float]:
    """Integrated summed-axis PSD over 3-7 Hz per complete 4-second window.

    Axis-wise Welch PSD with a Hann window, constant detrending, 2-second
    segments (nperseg = 2 * fs) and 50% overlap. Boundary convention: a bin
    contributes iff its CENTER frequency satisfies 3 <= f < 7 (half-open),
    documented here and asserted in tests.
    """
    from scipy.signal import welch

    values: list[float] = []
    nperseg = int(round(2.0 * rate_hz))
    for _, (lo, hi) in _complete_epoch_bounds(t, rate_hz, OSCILLATION_WINDOW_SECONDS):
        seg = gyro[lo:hi]
        power = 0.0
        for axis in range(3):
            freqs, psd = welch(
                seg[:, axis], fs=rate_hz, window="hann", detrend="constant",
                nperseg=nperseg, noverlap=nperseg // 2)
            band = (freqs >= BAND_LOW_HZ) & (freqs < BAND_HIGH_HZ)
            power += float(np.trapezoid(psd[band], freqs[band])) if band.any() else 0.0
        values.append(power)
    return values


def compute_oscillation(grid: dict[str, Any], rate_hz: float) -> dict[str, Any]:
    """The oscillation family document (spec 6.2)."""
    from scipy.signal import welch

    t, gyro = grid["t"], grid["gyro"]
    observed_seconds = float(t[-1] - t[0]) + 1.0 / rate_hz
    values = oscillation_power_window_values(t, gyro, rate_hz)
    if not values:
        return family_document(
            family="oscillation", status="withheld", reason="insufficient_eligible_time",
            measurements={}, observed_seconds=observed_seconds, eligible_seconds=0.0,
            reason_counts={"no_complete_4s_windows": 1})
    arr = np.asarray(values, dtype=float)
    nperseg = int(round(2.0 * rate_hz))
    spectral_resolution_hz = rate_hz / nperseg
    measurements = {
        "wrist_oscillation_power_3_7hz_median": measurement(
            float(np.median(arr)), "(deg/s)^2", denominator="complete 4 s windows",
            count=len(values), method=("Welch PSD (Hann, constant detrend, 2 s segments, "
                                        "50% overlap), summed x/y/z integrated over 3-7 Hz "
                                        "(half-open [3,7) on bin centers)")),
        "wrist_oscillation_power_3_7hz_p95": measurement(
            float(np.percentile(arr, 95)), "(deg/s)^2", denominator="complete 4 s windows",
            count=len(values), method="p95 over the same window distribution"),
    }
    # Dominant frequency only with nonzero measurable band power, plus the
    # spectral resolution; otherwise null (never force a peak into flat data).
    dominant = _dominant_band_frequency(t, gyro, rate_hz)
    if dominant is not None:
        measurements["wrist_oscillation_dominant_frequency_hz"] = measurement(
            dominant, "Hz", denominator="complete 4 s windows", count=len(values),
            method=("median per-window in-band argmax; null when band power is zero; "
                    f"spectral resolution {spectral_resolution_hz:g} Hz"))
    extra = {
        "spectral_resolution_hz": spectral_resolution_hz,
        "band_hz": [BAND_LOW_HZ, BAND_HIGH_HZ],
        "band_boundary_convention": "half-open [3,7) on bin center frequencies",
        "distinct_from": ("mean gyroscope magnitude (existing app metric) and "
                          "ParaDigMa tremor power (research, upstream band)"),
    }
    return family_document(
        family="oscillation", status="ok", measurements=measurements,
        observed_seconds=observed_seconds,
        eligible_seconds=OSCILLATION_WINDOW_SECONDS * len(values),
        extra=extra)


def _dominant_band_frequency(t: np.ndarray, gyro: np.ndarray, rate_hz: float) -> float | None:
    """Median dominant in-band frequency across windows with nonzero band power."""
    from scipy.signal import welch

    nperseg = int(round(2.0 * rate_hz))
    dominants: list[float] = []
    for _, (lo, hi) in _complete_epoch_bounds(t, rate_hz, OSCILLATION_WINDOW_SECONDS):
        seg = gyro[lo:hi]
        summed = None
        for axis in range(3):
            freqs, psd = welch(seg[:, axis], fs=rate_hz, window="hann",
                               detrend="constant", nperseg=nperseg, noverlap=nperseg // 2)
            band = (freqs >= BAND_LOW_HZ) & (freqs < BAND_HIGH_HZ)
            summed = psd[band] if summed is None else summed + psd[band]
        if summed is not None and float(np.sum(summed)) > 0.0:
            dominants.append(float(freqs[band][int(np.argmax(summed))]))
    if not dominants:
        return None
    return float(np.median(dominants))


def make_providers() -> list[Any]:
    """Movement + oscillation are computed inside the main sensor provider
    (sensor.biomarkers.v1); this module exports the compute functions only."""
    return []
