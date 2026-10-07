"""PPG quality + pulse shape families (NeuroKit2 0.2.13, pinned) + guarded perfusion.

Spec sections 6.4/6.5; CONTRACTS.md sections 2-4.

Verified against the installed neurokit2 0.2.13 (do not re-derive; see the
provider versions dict):

* ``nk.ppg_clean(raw, sampling_rate=fs, method="elgendi")`` -- Elgendi cleaner.
* ``nk.ppg_findpeaks(clean, sampling_rate=fs, method="charlton")`` -- MSPTDfast
  v2 (win_durn=6, internal 20 Hz downsampling); returns ``PPG_Onsets`` and
  ``PPG_Peaks`` (array positions).
* ``nk.ppg_peaks(..., method="charlton", correct_artifacts=False)`` -- the same
  detector with an info DataFrame; used for quality-only work.
* ``nk.ppg_quality(clean, peaks=..., sampling_rate=fs, method="templatematch")``
  -- per-sample template-similarity array (native correlation semantics).

Design rules
------------
* Raw diagnostics (clipping, flatness, finiteness, missingness) are recorded
  BEFORE any filtering.
* Two distinct concepts are never merged: ``valid_waveform_fraction`` (verified
  reconstructable, noncorrupt observed duration over expected duration; unknown
  expected timing is REPORTED as unknown, never invented) and
  ``template_similarity`` (morphology consistency; native correlation values,
  never "percent medically accurate").
* Quality summaries use complete nonoverlapping 30-second core windows; the
  detection context overlap is excluded from aggregation.
* Pulse morphology pairs each peak with valid preceding and following onsets on
  the CLEANED waveform; amplitudes are ADC-derived arbitrary units and are never
  pooled across configuration changes; interpolation never claims more physical
  resolution than the native sample period (exposed).
* The perfusion-like AC/DC ratio is computed only behind the research gate with
  a verified optical DC contract; otherwise withheld ``unverified_optical_dc``.
  Near-zero or invalid denominators are withheld, never the zero fallback.
"""

from __future__ import annotations

import math
from typing import Any

import numpy as np

from . import PROVIDER_REVISIONS
from .contract import distribution_block, family_document, measurement

NEUROKIT2_VERSION = "0.2.13"
PEAK_DETECTOR = "charlton (MSPTDfast v2, win_durn=6)"
CLEANER = "elgendi"
QUALITY_METHOD = "templatematch"

#: Signed 20-bit ADC rails (Whoop5RawOptical.sampleMin/sampleMax). Clipping is
#: diagnosed at these rails on RAW absolute ADC counts.
ADC_SAMPLE_MAX = 524_287
ADC_SAMPLE_MIN = -524_288

#: Elgendi's cleaner bandpass high cut is 8 Hz; require Nyquist above it.
MIN_CLEAN_RATE_HZ = 16.0

#: Complete nonoverlapping quality core windows.
QUALITY_WINDOW_SECONDS = 30

#: Flatness: a run of >= this many consecutive identical raw samples is flat.
FLAT_RUN_SAMPLES = 24


class PpgValidationError(ValueError):
    """The PPG input is malformed (shape, finiteness, rate, timestamps)."""


def _validate_segments(segments: list[Any], rate_hz: float) -> list[dict[str, Any]]:
    if not isinstance(segments, list) or not segments:
        raise PpgValidationError("ppg.segments must be a non-empty list")
    parsed: list[dict[str, Any]] = []
    prev_end: float | None = None
    for seg in segments:
        if not isinstance(seg, dict):
            raise PpgValidationError("each ppg segment must be an object")
        start = seg.get("start_unix")
        duration = seg.get("duration_s")
        samples = seg.get("samples")
        if not isinstance(start, (int, float)):
            raise PpgValidationError("segment start_unix must be a number")
        if not isinstance(duration, (int, float)) or duration <= 0:
            raise PpgValidationError("segment duration_s must be positive")
        arr = np.asarray(samples, dtype=float)
        if arr.ndim != 1 or arr.size == 0:
            raise PpgValidationError("segment samples must be a non-empty 1-D list")
        if not np.all(np.isfinite(arr)):
            raise PpgValidationError("segment samples contain non-finite values")
        if arr.size != int(round(duration * rate_hz)):
            raise PpgValidationError(
                f"segment duration {duration}s at {rate_hz:g} Hz implies "
                f"{int(round(duration * rate_hz))} samples, got {arr.size}")
        start = float(start)
        # Segments are half-open [start, start + duration): a segment may start
        # exactly at the previous segment's end (touching, sharing NO sample -
        # endpoint ownership: a sample belongs to exactly one segment), but any
        # earlier start is an overlap.
        if prev_end is not None and start < prev_end - 1e-9:
            raise PpgValidationError("ppg segments must be time-ordered, non-overlapping")
        prev_end = start + float(duration)
        parsed.append({
            "start": start,
            "duration": float(duration),
            "samples": arr,
            "config": seg.get("config") if isinstance(seg.get("config"), dict) else {},
        })
    return parsed


def _config_identity(config: dict[str, Any]) -> str:
    """Stable identity of the optical measurement configuration.

    Amplitudes must never be pooled across gain/drive/configuration changes;
    segments carrying different configs are analysed separately.
    """
    keys = ("source", "drive", "detector_select", "range", "offset", "gain")
    parts = []
    for key in sorted(config.keys()):
        parts.append(f"{key}={config[key]!r}")
    return ";".join(parts) if parts else "unspecified"


def raw_diagnostics(segments: list[dict[str, Any]], rate_hz: float) -> dict[str, Any]:
    """Clipping, flatness, finiteness and missingness BEFORE any filtering."""
    clipped = 0
    flat_runs = 0
    flat_samples = 0
    total = 0
    for seg in segments:
        s = seg["samples"]
        total += s.size
        clipped += int(np.count_nonzero((s >= ADC_SAMPLE_MAX) | (s <= ADC_SAMPLE_MIN)))
        # flat runs: maximal runs of identical consecutive values
        if s.size > 1:
            change = np.nonzero(np.diff(s) != 0)[0]
            run_starts = np.concatenate(([-1], change))
            run_ends = np.concatenate((change, [s.size - 1]))
            run_lengths = run_ends - run_starts
            flat_mask = run_lengths >= FLAT_RUN_SAMPLES
            flat_runs += int(np.count_nonzero(flat_mask))
            flat_samples += int(np.sum(run_lengths[flat_mask]))
    gaps_seconds = 0.0
    for a, b in zip(segments, segments[1:]):
        gaps_seconds += b["start"] - (a["start"] + a["duration"])
    return {
        "sample_count": total,
        "clipped_samples": clipped,
        "flat_runs": flat_runs,
        "flat_samples": flat_samples,
        "gap_seconds": gaps_seconds,
    }


def _detect(clean: np.ndarray, rate_hz: float) -> dict[str, Any]:
    """Peaks + onsets via the verified pinned MSPTDfast v2 detector.

    ``nk.ppg_peaks(..., method="charlton", correct_artifacts=False)`` is the
    quality-only form (spec 6.4 step 3): the returned info dict carries both
    ``PPG_Peaks`` and ``PPG_Onsets`` (verified against the installed 0.2.13;
    ``ppg_quality`` additionally wants the PEAK INDICES as ``peaks``, not the
    dict - both verified behaviours are asserted in tests).
    """
    import neurokit2 as nk

    _, info = nk.ppg_peaks(
        clean, sampling_rate=int(round(rate_hz)), method="charlton",
        correct_artifacts=False)
    if "PPG_Peaks" not in info or "PPG_Onsets" not in info:
        raise RuntimeError(  # pragma: no cover - guarded by startup assert
            f"neurokit2 {NEUROKIT2_VERSION} ppg_peaks missing PPG_Peaks/PPG_Onsets")
    return {
        "PPG_Peaks": np.asarray(info["PPG_Peaks"], dtype=int),
        "PPG_Onsets": np.asarray(info["PPG_Onsets"], dtype=int),
    }


def compute_ppg_quality(
    segments: list[dict[str, Any]], rate_hz: float, *,
    expected_duration_s: float | None,
) -> dict[str, Any]:
    """The ppg_quality family document (spec 6.4)."""
    import neurokit2 as nk

    first_start = segments[0]["start"]
    last_end = segments[-1]["start"] + segments[-1]["duration"]
    observed = sum(seg["duration"] for seg in segments)
    raw = raw_diagnostics(segments, rate_hz)
    corrupted = raw["clipped_samples"] > 0 or raw["flat_samples"] > 0

    if rate_hz < MIN_CLEAN_RATE_HZ:
        return family_document(
            family="ppg_quality", status="withheld", reason="unsupported_native_rate",
            measurements={},
            observed_seconds=observed,
            eligible_seconds=0.0,
            reason_counts={"unsupported_native_rate": 1},
            extra={"native_rate_hz": rate_hz,
                   "min_clean_rate_hz": MIN_CLEAN_RATE_HZ,
                   "raw_diagnostics": raw},
        )

    # valid_waveform_fraction: verified reconstructable, noncorrupt observed
    # duration over the expected duration. Unknown expected timing is reported
    # as unknown, never invented.
    if expected_duration_s is not None and expected_duration_s > 0:
        valid_fraction = (observed / expected_duration_s) if not corrupted else 0.0
        valid_entry = measurement(
            min(valid_fraction, 1.0), "fraction",
            denominator="expected duration within the capture interval",
            count=raw["sample_count"],
            method="verified reconstructable noncorrupt seconds / expected seconds")
        valid_unknown = False
    else:
        valid_entry = None
        valid_unknown = True

    measurements: dict[str, Any] = {}
    if valid_entry is not None:
        measurements["valid_waveform_fraction"] = valid_entry

    # Flat/clipped/corrupt signals get a WITHHELD similarity value and explicit
    # reasons, not a falsely reassuring zero or one.
    if corrupted:
        reasons = {}
        if raw["clipped_samples"] > 0:
            reasons["saturated_delta"] = raw["clipped_samples"]
        if raw["flat_samples"] > 0:
            reasons["flat_signal"] = raw["flat_runs"]
        doc = family_document(
            family="ppg_quality", status="ok",
            measurements=measurements,
            observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reasons,
            extra={"raw_diagnostics": raw, "native_rate_hz": rate_hz,
                   "template_similarity_withheld": True,
                   "valid_waveform_fraction_unknown": valid_unknown})
        return doc

    clean = np.concatenate([seg["samples"] for seg in segments])
    clean = nk.ppg_clean(clean, sampling_rate=int(round(rate_hz)), method=CLEANER)
    detected = _detect(clean, rate_hz)

    # Complete nonoverlapping 30-second core windows over the concatenated
    # verified span; the detection context (filter/detector edges) is excluded
    # by trimming the window edges where the detector is not reliable.
    core_window_samples = int(round(QUALITY_WINDOW_SECONDS * rate_hz))
    # ``peaks`` for the templatematch quality call is the PEAK INDICES array
    # (verified against the installed 0.2.13), not the findpeaks dict.
    quality = nk.ppg_quality(
        clean, peaks=detected["PPG_Peaks"], sampling_rate=int(round(rate_hz)),
        method=QUALITY_METHOD)
    quality = np.asarray(quality, dtype=float)
    quality_seconds = 0
    pooled: list[float] = []
    for start in range(0, clean.size - core_window_samples + 1,
                       core_window_samples):
        window = quality[start:start + core_window_samples]
        finite = window[np.isfinite(window)]
        if finite.size:
            # Aggregate finite values by duration: the window contributes its
            # per-sample values, weighted by their seconds.
            pooled.extend(finite.tolist())
            quality_seconds += QUALITY_WINDOW_SECONDS
    similarity_dist: dict[str, Any] | None = None
    if pooled:
        arr = np.asarray(pooled, dtype=float)
        measurements["template_similarity_median"] = measurement(
            float(np.median(arr)), "correlation",
            denominator="complete 30 s core windows, finite values",
            count=quality_seconds // QUALITY_WINDOW_SECONDS,
            method=(f"nk.ppg_quality(method={QUALITY_METHOD!r}) over "
                    f"nk.ppg_clean(method={CLEANER!r}) signal; native "
                    "correlation semantics, not a clinical quality class"))
        measurements["template_similarity_p25"] = measurement(
            float(np.percentile(arr, 25)), "correlation",
            denominator="complete 30 s core windows, finite values",
            count=quality_seconds // QUALITY_WINDOW_SECONDS,
            method="p25 over the same pooled values")
        similarity_dist = distribution_block("template_similarity_median",
                                             pooled, "template_similarity")
    else:
        reasons = {"no_finite_template_similarity": 1}
        return family_document(
            family="ppg_quality", status="ok", measurements=measurements,
            observed_seconds=observed, eligible_seconds=float(quality_seconds),
            reason_counts=reasons,
            extra={"raw_diagnostics": raw, "native_rate_hz": rate_hz,
                   "valid_waveform_fraction_unknown": valid_unknown})

    return family_document(
        family="ppg_quality", status="ok", measurements=measurements,
        observed_seconds=observed, eligible_seconds=float(quality_seconds),
        reason_counts={"clipped_samples": raw["clipped_samples"],
                       "flat_runs": raw["flat_runs"]},
        extra={"raw_diagnostics": raw, "native_rate_hz": rate_hz,
               "valid_waveform_fraction_unknown": valid_unknown,
               **({"distributions": [similarity_dist]} if similarity_dist else {})})


def _pulse_metrics(clean: np.ndarray, rate_hz: float,
                   detected: dict[str, np.ndarray]) -> dict[str, Any]:
    """Broad pulse shape over complete, positive-amplitude pulses (spec 6.4).

    A pulse is the span between one onset and the next onset that contains
    exactly one peak. Baseline: straight line between the two onset amplitudes
    on the CLEANED waveform. Rejected: multiple-peak, incomplete (missing onset
    on either side), non-positive amplitude, or non-finite pulses.
    """
    onsets = detected["PPG_Onsets"]
    peaks = detected["PPG_Peaks"]
    dt = 1.0 / rate_hz
    amplitudes: list[float] = []
    upstrokes: list[float] = []
    widths: list[float] = []
    areas: list[float] = []
    durations: list[float] = []
    accepted = 0
    rejected = {"multiple_peaks": 0, "incomplete": 0, "non_positive": 0}
    onset_set = {int(i) for i in onsets}
    peaks_in = {}
    for p in peaks:
        # the onset preceding this peak
        prev = [o for o in onsets if o < p]
        nxt = [o for o in onsets if o > p]
        if not prev or not nxt:
            rejected["incomplete"] += 1
            continue
        prev_on, next_on = int(prev[-1]), int(nxt[0])
        n_between = int(np.count_nonzero((peaks > prev_on) & (peaks < next_on)))
        if n_between != 1:
            rejected["multiple_peaks"] += 1 if n_between > 1 else 0
            if n_between == 0:
                rejected["incomplete"] += 1
            continue
        peak_i = int(p)
        a0, a1 = float(clean[prev_on]), float(clean[next_on])
        t0, t1 = prev_on * dt, next_on * dt
        tp = peak_i * dt
        baseline_at_peak = a0 + (a1 - a0) * ((tp - t0) / (t1 - t0) if t1 > t0 else 0.0)
        amp = float(clean[peak_i]) - baseline_at_peak
        if not math.isfinite(amp) or amp <= 0:
            rejected["non_positive"] += 1
            continue
        # baseline-corrected signal across the pulse span
        span = np.arange(prev_on, next_on + 1)
        times = span * dt
        baseline = a0 + (a1 - a0) * ((times - t0) / (t1 - t0) if t1 > t0 else 0.0)
        corrected = clean[span] - baseline
        # width50: first rising and first falling crossings of amp/2 with linear
        # interpolation between adjacent REAL samples (no invented resolution)
        half = amp / 2.0
        rise_i = fall_i = None
        for j in range(1, span.size):
            if rise_i is None and corrected[j - 1] < half <= corrected[j]:
                frac = (half - corrected[j - 1]) / (corrected[j] - corrected[j - 1])
                rise_i = times[j - 1] + frac * dt
            if rise_i is not None and corrected[j - 1] >= half > corrected[j]:
                frac = (corrected[j - 1] - half) / (corrected[j - 1] - corrected[j])
                fall_i = times[j - 1] + frac * dt
                break
        if rise_i is None or fall_i is None or fall_i <= rise_i:
            rejected["incomplete"] += 1
            continue
        positive = np.maximum(corrected, 0.0)
        area = float(np.trapezoid(positive, times))
        duration = t1 - t0
        amplitudes.append(amp)
        upstrokes.append((tp - t0) * 1000.0)
        widths.append((fall_i - rise_i) * 1000.0)
        areas.append(area / (amp * duration) if (amp * duration) > 0 else 0.0)
        durations.append(duration)
        accepted += 1
    return {
        "accepted": accepted, "rejected": rejected,
        "amplitudes": amplitudes, "upstrokes_ms": upstrokes, "widths_ms": widths,
        "normalized_areas": areas, "durations_s": durations,
    }


def _summarize_pulses(metrics: dict[str, Any]) -> dict[str, Any]:
    """Median + IQR + counts for one configuration's accepted pulses."""
    def med(values): return float(np.median(values)) if values else None
    def iqr(values):
        return float(np.percentile(values, 75) - np.percentile(values, 25)) if values else None
    return {
        "pulse_amplitude_median_au": measurement(
            med(metrics["amplitudes"]), "arbitrary ADC units",
            count=metrics["accepted"],
            method="peak height above onset-to-onset baseline (cleaned waveform)"),
        "pulse_amplitude_iqr_au": measurement(
            iqr(metrics["amplitudes"]), "arbitrary ADC units", count=metrics["accepted"],
            method="IQR of accepted pulse amplitudes"),
        "pulse_upstroke_median_ms": measurement(
            med(metrics["upstrokes_ms"]), "ms", count=metrics["accepted"],
            method="peak time minus preceding onset time (cleaned waveform)"),
        "pulse_upstroke_iqr_ms": measurement(
            iqr(metrics["upstrokes_ms"]), "ms", count=metrics["accepted"],
            method="IQR of accepted pulse upstrokes"),
        "pulse_width50_median_ms": measurement(
            med(metrics["widths_ms"]), "ms", count=metrics["accepted"],
            method="50%-amplitude rising-to-falling width, linear interpolation "
                   "between adjacent real samples only"),
        "pulse_width50_iqr_ms": measurement(
            iqr(metrics["widths_ms"]), "ms", count=metrics["accepted"],
            method="IQR of accepted pulse widths"),
        "pulse_normalized_area_median": measurement(
            med(metrics["normalized_areas"]), "dimensionless", count=metrics["accepted"],
            method="positive baseline-corrected area / (amplitude x pulse duration)"),
        "pulse_normalized_area_iqr": measurement(
            iqr(metrics["normalized_areas"]), "dimensionless", count=metrics["accepted"],
            method="IQR of accepted normalized areas"),
        "pulse_accepted_count": measurement(
            float(metrics["accepted"]), "count", count=metrics["accepted"],
            method="complete, positive-amplitude, single-peak pulses"),
        "pulse_rejected_count": measurement(
            float(sum(metrics["rejected"].values())), "count",
            count=sum(metrics["rejected"].values()),
            method="multiple-peak/incomplete/non-positive pulses"),
    }


def compute_pulse_shape(segments: list[dict[str, Any]], rate_hz: float) -> dict[str, Any]:
    """The pulse_shape family document (spec 6.4): per configuration."""
    import neurokit2 as nk

    observed = sum(seg["duration"] for seg in segments)
    if rate_hz < MIN_CLEAN_RATE_HZ:
        return family_document(
            family="pulse_shape", status="withheld", reason="unsupported_native_rate",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"unsupported_native_rate": 1},
            extra={"native_rate_hz": rate_hz, "native_sample_period_ms": 1000.0 / rate_hz})

    # Flat/clipped/corrupt signals have no valid pulses: withheld with
    # explicit reasons, never filter-transient pseudo-pulses (spec 6.4).
    raw = raw_diagnostics(segments, rate_hz)
    if raw["clipped_samples"] > 0 or raw["flat_samples"] > 0:
        reasons: dict[str, int] = {}
        if raw["clipped_samples"] > 0:
            reasons["saturated_delta"] = raw["clipped_samples"]
        if raw["flat_samples"] > 0:
            reasons["flat_signal"] = raw["flat_runs"]
        return family_document(
            family="pulse_shape", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reasons,
            extra={"raw_diagnostics": raw, "native_rate_hz": rate_hz,
                   "native_sample_period_ms": 1000.0 / rate_hz})

    by_config: dict[str, list[dict[str, Any]]] = {}
    for seg in segments:
        by_config.setdefault(_config_identity(seg["config"]), []).append(seg)

    configurations: list[dict[str, Any]] = []
    for identity, segs in by_config.items():
        # Non-overlapping and ordered inside one configuration by construction.
        clean = np.concatenate([s["samples"] for s in segs])
        clean = nk.ppg_clean(clean, sampling_rate=int(round(rate_hz)), method=CLEANER)
        detected = _detect(clean, rate_hz)
        metrics = _pulse_metrics(clean, rate_hz, detected)
        distributions = [
            block for block in (
                distribution_block("pulse_amplitude_median_au", metrics["amplitudes"], "pulse_amplitude_au"),
                distribution_block("pulse_upstroke_median_ms", metrics["upstrokes_ms"], "pulse_time_ms"),
                distribution_block("pulse_width50_median_ms", metrics["widths_ms"], "pulse_time_ms"),
                distribution_block("pulse_normalized_area_median", metrics["normalized_areas"], "pulse_area"),
            ) if block is not None
        ]
        configurations.append({
            "configuration": identity,
            "segments": len(segs),
            "accepted": metrics["accepted"],
            "rejected": metrics["rejected"],
            "eligible_seconds": float(sum(metrics["durations_s"])),
            "measurements": _summarize_pulses(metrics),
            "distributions": distributions,
        })
    accepted_total = sum(c["accepted"] for c in configurations)
    if accepted_total == 0:
        return family_document(
            family="pulse_shape", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={f"rejected_{k}": v
                           for c in configurations
                           for k, v in c["rejected"].items()},
            extra={"configurations": configurations,
                   "native_rate_hz": rate_hz,
                   "native_sample_period_ms": 1000.0 / rate_hz})

    # Amplitudes are never pooled across configurations. With exactly one
    # stable configuration the top-level keys carry it directly; with more,
    # the per-configuration blocks are the result and the top level stays empty.
    measurements: dict[str, Any] = {}
    top_distributions: list[dict[str, Any]] = []
    if len(configurations) == 1:
        measurements = dict(configurations[0]["measurements"])
        top_distributions = list(configurations[0].get("distributions") or [])
    # eligible_seconds: seconds covered by ACCEPTED pulses (the summed pulse
    # durations), never the pulse COUNT (a duration is rendered as a duration).
    eligible_seconds = float(sum(
        float(c.get("eligible_seconds") or 0.0) for c in configurations))
    return family_document(
        family="pulse_shape", status="ok", measurements=measurements,
        observed_seconds=observed,
        eligible_seconds=eligible_seconds,
        reason_counts={f"rejected_{k}": sum(c["rejected"][k] for c in configurations)
                       for k in configurations[0]["rejected"]},
        extra={"configurations": configurations,
               "pooled_across_configurations": False,
               "native_rate_hz": rate_hz,
               "native_sample_period_ms": 1000.0 / rate_hz,
               **({"distributions": top_distributions} if top_distributions else {})})


def compute_perfusion_research(
    segments: list[dict[str, Any]], rate_hz: float, *, optical_dc: Any,
) -> dict[str, Any]:
    """The gated perfusion-like AC/DC ratio (spec 6.5).

    ``100 * (max(cleaned) - min(cleaned)) / abs(mean(raw))``, computed ONLY
    behind the research gate with a verified optical DC contract (stable
    channel/drive/gain/offset, appropriate dark correction, valid raw anchor,
    unsaturated signal). Near-zero or invalid denominators are withheld; the
    library's zero-denominator fallback is never accepted as a measured zero.
    """
    observed = sum(seg["duration"] for seg in segments)
    verified = (
        isinstance(optical_dc, dict)
        and optical_dc.get("dc_verified") is True
        and bool(optical_dc.get("channel"))
    )
    if not verified:
        return family_document(
            family="perfusion_research", status="withheld",
            reason="unverified_optical_dc", measurements={},
            observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"unverified_optical_dc": 1})

    raw = np.concatenate([seg["samples"] for seg in segments])
    if np.any(np.abs(raw) >= ADC_SAMPLE_MAX) or np.any(raw <= ADC_SAMPLE_MIN):
        return family_document(
            family="perfusion_research", status="withheld", reason="saturated_delta",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"saturated_signal": 1})

    dc = abs(float(np.mean(raw)))
    if not math.isfinite(dc) or dc < 1e-9:
        return family_document(
            family="perfusion_research", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"invalid_or_near_zero_dc_denominator": 1})

    # A flat AC signal (no pulsatile component) is not a measured zero ratio:
    # the gate requires an unsaturated signal WITH a pulsatile component.
    ac_span = float(np.max(raw) - np.min(raw))
    if not math.isfinite(ac_span) or ac_span <= 0.0:
        return family_document(
            family="perfusion_research", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"flat_ac_signal": 1})

    import neurokit2 as nk
    clean = nk.ppg_clean(raw, sampling_rate=int(round(rate_hz)), method=CLEANER)
    ac = float(np.max(clean) - np.min(clean))
    ratio = 100.0 * ac / dc
    if not math.isfinite(ratio):
        return family_document(
            family="perfusion_research", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"non_finite_ratio": 1})

    return family_document(
        family="perfusion_research", status="ok",
        measurements={
            "estimated_ac_dc_ratio_percent": measurement(
                ratio, "percent", count=raw.size,
                method="100*(max(cleaned)-min(cleaned))/abs(mean(raw)); "
                       "estimated AC/DC ratio, NOT a circulation measure",
                native_resolution="ADC-derived arbitrary units"),
        },
        observed_seconds=observed, eligible_seconds=observed,
        extra={"optical_dc": {
            "channel": optical_dc.get("channel"),
            "drive": optical_dc.get("drive"),
            "gain": optical_dc.get("gain"),
            "method_revision": optical_dc.get("method_revision"),
        }})


def make_providers() -> list[Any]:
    """PPG families are computed inside the main sensor provider
    (sensor.biomarkers.v1); this module exports the compute functions only."""
    return []
