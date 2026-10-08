"""PPG quality + pulse shape families (NeuroKit2 0.2.13, pinned) + guarded perfusion.

Spec sections 6.4/6.5; CONTRACTS.md sections 2-4; docs/model-integration/sensor-families.md.

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

Run-aware computation (Spec 01 section 3, docs/model-integration/README.md)
---------------------------------------------------------------------------
* A run is a contiguous, configuration-compatible stretch of samples. Segments
  that share a ``run_id``, touch in time and carry the same ``config.identity``
  and clock are joined; nothing else is. A segment without ``run_id`` (an older
  worker) is its own run.
* Cleaning, pulse detection, morphology, quality windows and the AC/DC ratio run
  inside one run at a time, so no pulse, onset or window spans a gap, a
  configuration change or a run boundary.
* Results are aggregated with each run's real exposure: pulses and 30 s window
  values are pooled across runs, and eligible seconds are summed per run.
* Amplitudes are reported per configuration identity and never pooled across
  identities. When the transport could not identify the configuration
  (``config.identity == "unknown"``) they are reported per run and marked
  ``configuration_unidentified``; the gain-independent features (upstroke,
  width50, normalized area) are still pooled across those runs.
* The sample arrays of a request are copied once and kept read-only; nothing
  here writes into the caller's data.

This enables the existing MSPTDfast/NeuroKit quality, amplitude, upstroke and
width50 code on reconstructed waveforms. It does not establish calibrated
perfusion, vascular stiffness, SpO2 or dicrotic-notch accuracy.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any

import numpy as np

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
#: A sample count (about one second at the 24-25 Hz optical rates), not a rate.
FLAT_RUN_SAMPLES = 24

#: MSPTDfast v2 searches 6 s windows, and neurokit2 0.2.13 raises on a signal of
#: at most one window (verified), so a run must be strictly longer to be searched.
DETECTOR_WINDOW_SECONDS = 6.0

#: The identity the transport sends when it cannot identify the optical
#: configuration (gain, drive, channel). Amplitude is then reported per run.
UNKNOWN_CONFIGURATION = "unknown"

#: Bounds on the per-request listings a stage carries (the day document the lane
#: publishes is capped at 256 KiB).
MAX_LISTED_RUNS = 12
MAX_LISTED_CONFIGURATIONS = 8
MAX_IDENTITY_LENGTH = 256
MAX_RUN_ID_LENGTH = 128

#: Pulse measurements that carry ADC amplitude and so depend on gain and drive.
AMPLITUDE_KEYS = ("pulse_amplitude_median_au", "pulse_amplitude_iqr_au")

#: Pulse measurements that do not depend on gain or drive: shape times, the
#: amplitude-normalised area and the pulse counts.
GAIN_INDEPENDENT_KEYS = (
    "pulse_upstroke_median_ms", "pulse_upstroke_iqr_ms",
    "pulse_width50_median_ms", "pulse_width50_iqr_ms",
    "pulse_normalized_area_median", "pulse_normalized_area_iqr",
    "pulse_accepted_count", "pulse_rejected_count",
)


class PpgValidationError(ValueError):
    """The PPG input is malformed (shape, finiteness, rate, timestamps)."""


# ---------------------------------------------------------------------------
# Segments
# ---------------------------------------------------------------------------

def _whole_rate(rate_hz: float) -> int | None:
    rounded = int(round(rate_hz))
    return rounded if abs(rate_hz - rounded) < 1e-9 else None


def _segment_identity(config: dict[str, Any], where: str) -> tuple[str, bool, str]:
    """(identity, known, source) of one segment's optical configuration."""
    identity = config.get("identity")
    if identity is None:
        return _config_identity(config), False, "legacy_config_members"
    if not isinstance(identity, str) or not identity.strip() or len(identity) > MAX_IDENTITY_LENGTH:
        raise PpgValidationError(f"{where}.config.identity must be a non-empty string")
    known = config.get("known", False)
    if not isinstance(known, bool):
        raise PpgValidationError(f"{where}.config.known must be a boolean")
    # An unidentified configuration is never "known", whatever the flag says.
    return identity, known and identity != UNKNOWN_CONFIGURATION, "transport"


def _segment_run_id(seg: dict[str, Any], where: str) -> str | None:
    run_id = seg.get("run_id")
    if run_id is None:
        return None
    if not isinstance(run_id, str) or not run_id or len(run_id) > MAX_RUN_ID_LENGTH:
        raise PpgValidationError(f"{where}.run_id must be a non-empty string")
    return run_id


def _segment_clock(seg: dict[str, Any], per_second: int | None, rate_hz: float,
                   where: str) -> dict[str, Any] | None:
    clock = seg.get("clock")
    if clock is None:
        return None
    if not isinstance(clock, dict):
        raise PpgValidationError(f"{where}.clock must be an object")
    stated = clock.get("samples_per_second")
    if stated is not None and (isinstance(stated, bool) or not isinstance(stated, int)
                               or stated != per_second):
        raise PpgValidationError(
            f"{where}.clock.samples_per_second {stated!r} does not match "
            f"native_rate_hz {rate_hz:g}")
    verified = clock.get("packet_timing_verified")
    if verified is not None and not isinstance(verified, bool):
        raise PpgValidationError(f"{where}.clock.packet_timing_verified must be a boolean")
    return dict(clock)


def _validate_segments(segments: list[Any], rate_hz: float) -> list[dict[str, Any]]:
    """Validate the request's PPG segments and copy their samples once, read-only.

    Besides the CONTRACTS.md section 4 shape checks this reads the run-aware
    members (docs/model-integration/README.md): ``run_id``, ``config.identity``
    / ``config.known`` and ``clock``. A malformed new member is a malformed
    request (the PPG families withhold ``blocked_input``); an absent one keeps
    the legacy meaning.
    """
    if not isinstance(segments, list) or not segments:
        raise PpgValidationError("ppg.segments must be a non-empty list")
    per_second = _whole_rate(rate_hz)
    parsed: list[dict[str, Any]] = []
    prev_end: float | None = None
    for index, seg in enumerate(segments):
        where = f"ppg.segments[{index}]"
        if not isinstance(seg, dict):
            raise PpgValidationError("each ppg segment must be an object")
        start = seg.get("start_unix")
        duration = seg.get("duration_s")
        samples = seg.get("samples")
        if not isinstance(start, (int, float)):
            raise PpgValidationError("segment start_unix must be a number")
        if not isinstance(duration, (int, float)) or duration <= 0:
            raise PpgValidationError("segment duration_s must be positive")
        # np.array copies, so later read-only views never alias the request's data.
        arr = np.array(samples, dtype=float)
        if arr.ndim != 1 or arr.size == 0:
            raise PpgValidationError("segment samples must be a non-empty 1-D list")
        if not np.all(np.isfinite(arr)):
            raise PpgValidationError("segment samples contain non-finite values")
        if arr.size != int(round(duration * rate_hz)):
            raise PpgValidationError(
                f"segment duration {duration}s at {rate_hz:g} Hz implies "
                f"{int(round(duration * rate_hz))} samples, got {arr.size}")
        arr.setflags(write=False)
        start = float(start)
        # Segments are half-open [start, start + duration): a segment may start
        # exactly at the previous segment's end (touching, sharing NO sample -
        # endpoint ownership: a sample belongs to exactly one segment), but any
        # earlier start is an overlap.
        if prev_end is not None and start < prev_end - 1e-9:
            raise PpgValidationError("ppg segments must be time-ordered, non-overlapping")
        prev_end = start + float(duration)
        count_per_second = seg.get("sample_count_per_second")
        if count_per_second is not None and (
                isinstance(count_per_second, bool) or not isinstance(count_per_second, int)
                or count_per_second != per_second):
            raise PpgValidationError(
                f"{where}.sample_count_per_second {count_per_second!r} does not match "
                f"native_rate_hz {rate_hz:g}")
        config = seg.get("config") if isinstance(seg.get("config"), dict) else {}
        identity, known, source = _segment_identity(config, where)
        parsed.append({
            "index": index,
            "start": start,
            "duration": float(duration),
            "samples": arr,
            "config": dict(config),
            "run_id": _segment_run_id(seg, where),
            "config_identity": identity,
            "config_known": known,
            "identity_source": source,
            "configuration_unidentified": source == "transport" and identity == UNKNOWN_CONFIGURATION,
            "clock": _segment_clock(seg, per_second, rate_hz, where),
        })
    return parsed


def _config_identity(config: dict[str, Any]) -> str:
    """Legacy identity of the optical measurement configuration (sorted members).

    Used only when a segment carries no ``config.identity``; amplitudes are
    never pooled across different identities.
    """
    parts = []
    for key in sorted(config.keys()):
        parts.append(f"{key}={config[key]!r}")
    return ";".join(parts) if parts else "unspecified"


def legacy_request(segments: list[dict[str, Any]]) -> bool:
    """True when no segment names a run: the request came from an older worker."""
    return not any(seg.get("run_id") is not None for seg in segments)


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

def _clock_summary(clock: dict[str, Any] | None) -> dict[str, Any] | None:
    """The interpreted clock members plus short provenance strings (bounded)."""
    if clock is None:
        return None
    out: dict[str, Any] = {"packet_timing_verified": clock.get("packet_timing_verified") is True}
    if isinstance(clock.get("samples_per_second"), int):
        out["samples_per_second"] = clock["samples_per_second"]
    for key in ("source", "grid", "endpoint"):
        if isinstance(clock.get(key), str):
            out[key] = clock[key][:64]
    phase = clock.get("phase_s")
    if isinstance(phase, (int, float)) and not isinstance(phase, bool) and math.isfinite(phase):
        out["phase_s"] = float(phase)
    return out


@dataclass(frozen=True)
class PpgRun:
    """One contiguous, configuration-compatible run: joined segments, read-only samples."""

    key: str
    run_id: str | None
    configuration: str
    configuration_known: bool
    configuration_unidentified: bool
    identity_source: str
    start: float
    duration: float
    segment_indices: tuple[int, ...]
    samples: np.ndarray
    clock: dict[str, Any] | None
    config_stable: bool

    @property
    def clock_verified(self) -> bool | None:
        """``clock.packet_timing_verified`` of the run; None for a legacy run without a clock."""
        if self.clock is None:
            return None
        return self.clock.get("packet_timing_verified") is True

    def provenance(self) -> dict[str, Any]:
        """A compact, JSON-safe description of the run (no samples)."""
        out: dict[str, Any] = {
            "run": self.key,
            "start_unix": self.start,
            "duration_s": self.duration,
            "segments": len(self.segment_indices),
            "configuration": self.configuration,
            "configuration_known": self.configuration_known,
        }
        if self.configuration_unidentified:
            out["configuration_unidentified"] = True
        if self.clock is not None:
            out["clock_verified"] = self.clock_verified
        return out


def _join_key(seg: dict[str, Any]) -> tuple[str, str, str]:
    return (seg["config_identity"], seg["identity_source"],
            json.dumps(seg["clock"], sort_keys=True, default=str))


def _make_run(group: list[dict[str, Any]], used: dict[str, int],
              counts: dict[str, int]) -> PpgRun:
    first = group[0]
    base = first["run_id"] if first["run_id"] is not None else f"segment-{first['index']}"
    used[base] = used.get(base, 0) + 1
    if used[base] > 1:
        # A run_id that comes back after another run is a second run, never a continuation.
        counts["ppg_run_id_discontinuity"] = counts.get("ppg_run_id_discontinuity", 0) + 1
    samples = np.concatenate([seg["samples"] for seg in group])
    samples.setflags(write=False)
    return PpgRun(
        key=base if used[base] == 1 else f"{base}#{used[base]}",
        run_id=first["run_id"],
        configuration=first["config_identity"],
        configuration_known=first["config_known"],
        configuration_unidentified=first["configuration_unidentified"],
        identity_source=first["identity_source"],
        start=first["start"],
        duration=float(sum(seg["duration"] for seg in group)),
        segment_indices=tuple(seg["index"] for seg in group),
        samples=samples,
        clock=first["clock"],
        config_stable=all(seg["config"].get("stable") is True for seg in group),
    )


def build_ppg_runs(segments: list[dict[str, Any]]) -> tuple[list[PpgRun], dict[str, int]]:
    """Group validated segments into runs, in time order.

    Consecutive segments join only when they share a ``run_id``, touch in time
    (start == previous end) and carry the same configuration identity and clock.
    A shared ``run_id`` that breaks any of these is split, never joined, and
    counted as ``ppg_run_id_discontinuity``. A segment without ``run_id`` is a
    run of its own.
    """
    runs: list[PpgRun] = []
    counts: dict[str, int] = {}
    used: dict[str, int] = {}
    group: list[dict[str, Any]] = []
    for seg in segments:
        if group and seg["run_id"] is not None and seg["run_id"] == group[-1]["run_id"]:
            prev = group[-1]
            touching = abs(seg["start"] - (prev["start"] + prev["duration"])) <= 1e-6
            if touching and _join_key(seg) == _join_key(prev):
                group.append(seg)
                continue
        # A split shared run_id is counted once, when its second run is made.
        if group:
            runs.append(_make_run(group, used, counts))
        group = [seg]
    if group:
        runs.append(_make_run(group, used, counts))
    return runs, counts


def _detectable(run: PpgRun, rate_hz: float) -> bool:
    return run.samples.size > int(round(DETECTOR_WINDOW_SECONDS * rate_hz))


def _run_row(run: PpgRun, status: str, eligible_seconds: float, **extra: Any) -> dict[str, Any]:
    row = run.provenance()
    row["status"] = status
    row["eligible_seconds"] = float(eligible_seconds)
    row.update(extra)
    return row


def _bounded(rows: list[dict[str, Any]], weight: str, limit: int) -> list[dict[str, Any]]:
    """The ``limit`` rows with the most ``weight``, back in time order."""
    kept = sorted(rows, key=lambda r: (-float(r.get(weight) or 0.0), r["start_unix"]))[:limit]
    return sorted(kept, key=lambda r: r["start_unix"])


def _runs_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Per-run exposure: totals plus a bounded listing (largest eligible exposure first)."""
    listed = _bounded(rows, "eligible_seconds", MAX_LISTED_RUNS)
    return {
        "count": len(rows),
        "observed_seconds": float(sum(r["duration_s"] for r in rows)),
        "eligible_seconds": float(sum(r["eligible_seconds"] for r in rows)),
        "listed": listed,
        "listed_truncated": len(rows) - len(listed),
    }


def _add(counts: dict[str, int], key: str, value: int = 1) -> None:
    if value:
        counts[key] = counts.get(key, 0) + int(value)


# ---------------------------------------------------------------------------
# Raw diagnostics
# ---------------------------------------------------------------------------

def _corruption(samples: np.ndarray) -> dict[str, int]:
    """Clipped samples and flat runs in one sample array (raw, before filtering)."""
    clipped = int(np.count_nonzero((samples >= ADC_SAMPLE_MAX) | (samples <= ADC_SAMPLE_MIN)))
    flat_runs = 0
    flat_samples = 0
    if samples.size > 1:
        change = np.nonzero(np.diff(samples) != 0)[0]
        run_starts = np.concatenate(([-1], change))
        run_ends = np.concatenate((change, [samples.size - 1]))
        run_lengths = run_ends - run_starts
        flat_mask = run_lengths >= FLAT_RUN_SAMPLES
        flat_runs = int(np.count_nonzero(flat_mask))
        flat_samples = int(np.sum(run_lengths[flat_mask]))
    return {"clipped_samples": clipped, "flat_runs": flat_runs, "flat_samples": flat_samples}


def _is_corrupt(corruption: dict[str, int]) -> bool:
    return corruption["clipped_samples"] > 0 or corruption["flat_samples"] > 0


def raw_diagnostics(segments: list[dict[str, Any]], rate_hz: float) -> dict[str, Any]:
    """Clipping, flatness, finiteness and missingness BEFORE any filtering."""
    clipped = 0
    flat_runs = 0
    flat_samples = 0
    total = 0
    for seg in segments:
        found = _corruption(seg["samples"])
        total += seg["samples"].size
        clipped += found["clipped_samples"]
        flat_runs += found["flat_runs"]
        flat_samples += found["flat_samples"]
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


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

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


def _analyse_run(run: PpgRun, rate_hz: float, *, with_quality: bool) -> dict[str, Any] | None:
    """Clean one run and search it for pulses; None when no pulse structure is found.

    MSPTDfast raises ValueError on a stretch with no pulse-like structure (a
    noise-only run, verified on 0.2.13), and the template-match quality needs
    at least two peaks. Both are properties of that run's data, so they withhold
    the run, never the request.
    """
    import neurokit2 as nk

    fs = int(round(rate_hz))
    clean = nk.ppg_clean(run.samples, sampling_rate=fs, method=CLEANER)
    try:
        detected = _detect(clean, rate_hz)
    except ValueError:
        return None
    quality = None
    if with_quality:
        if detected["PPG_Peaks"].size < 2:
            return None
        try:
            quality = np.asarray(nk.ppg_quality(
                clean, peaks=detected["PPG_Peaks"], sampling_rate=fs,
                method=QUALITY_METHOD), dtype=float)
        except ValueError:
            return None
    return {"clean": clean, "detected": detected, "quality": quality}


# ---------------------------------------------------------------------------
# ppg_quality
# ---------------------------------------------------------------------------

def compute_ppg_quality(
    segments: list[dict[str, Any]], rate_hz: float, *,
    expected_duration_s: float | None,
) -> dict[str, Any]:
    """The ppg_quality family document (spec 6.4), computed run by run."""
    observed = sum(seg["duration"] for seg in segments)
    raw = raw_diagnostics(segments, rate_hz)

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

    runs, run_counts = build_ppg_runs(segments)
    corruption = {run.key: _corruption(run.samples) for run in runs}
    corrupt = {key for key, found in corruption.items() if _is_corrupt(found)}
    # An older worker's request keeps its request-wide gate: one clipped or flat
    # stretch withholds similarity for the whole request, exactly as before.
    request_scope = legacy_request(segments)
    usable_seconds = 0.0 if (request_scope and corrupt) else float(
        sum(run.duration for run in runs if run.key not in corrupt))

    # valid_waveform_fraction: verified reconstructable, noncorrupt observed
    # duration over the expected duration. Unknown expected timing is reported
    # as unknown, never invented.
    measurements: dict[str, Any] = {}
    if expected_duration_s is not None and expected_duration_s > 0:
        measurements["valid_waveform_fraction"] = measurement(
            min(usable_seconds / expected_duration_s, 1.0), "fraction",
            denominator="expected duration within the capture interval",
            count=raw["sample_count"],
            method="verified reconstructable noncorrupt seconds / expected seconds")
        valid_unknown = False
    else:
        valid_unknown = True

    reasons: dict[str, int] = dict(run_counts)
    for run in runs:
        if run.key in corrupt:
            _add(reasons, "saturated_delta", corruption[run.key]["clipped_samples"])
            _add(reasons, "flat_signal", corruption[run.key]["flat_runs"])

    # Flat/clipped/corrupt signals get a WITHHELD similarity value and explicit
    # reasons, not a falsely reassuring zero or one.
    if (request_scope and corrupt) or len(corrupt) == len(runs):
        rows = [_run_row(run, "corrupt" if run.key in corrupt else "withheld_with_request", 0.0)
                for run in runs]
        return family_document(
            family="ppg_quality", status="ok",
            measurements=measurements,
            observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reasons,
            extra={"raw_diagnostics": raw, "native_rate_hz": rate_hz,
                   "template_similarity_withheld": True,
                   "valid_waveform_fraction_unknown": valid_unknown,
                   "computation": "per_run",
                   "runs": _runs_summary(rows)})

    # Complete nonoverlapping 30-second core windows inside each run: a window
    # never spans a run boundary, and each run contributes its own seconds.
    window = int(round(QUALITY_WINDOW_SECONDS * rate_hz))
    pooled: list[float] = []
    windows_total = 0
    rows = []
    for run in runs:
        if run.key in corrupt:
            rows.append(_run_row(run, "corrupt", 0.0))
            continue
        if not _detectable(run, rate_hz):
            _add(reasons, "ppg_run_shorter_than_detector_window")
            rows.append(_run_row(run, "shorter_than_detector_window", 0.0))
            continue
        analysed = _analyse_run(run, rate_hz, with_quality=True)
        if analysed is None:
            _add(reasons, "ppg_run_no_pulses_detected")
            rows.append(_run_row(run, "no_pulses_detected", 0.0))
            continue
        quality = analysed["quality"]
        run_windows = 0
        for start in range(0, quality.size - window + 1, window):
            finite = quality[start:start + window]
            finite = finite[np.isfinite(finite)]
            if finite.size:
                # Each window contributes its per-sample values, so a run weighs
                # in proportion to its eligible seconds.
                pooled.extend(finite.tolist())
                run_windows += 1
        windows_total += run_windows
        if run_windows == 0:
            _add(reasons, "ppg_run_no_complete_quality_window")
        rows.append(_run_row(run, "used" if run_windows else "no_complete_window",
                             float(run_windows * QUALITY_WINDOW_SECONDS),
                             quality_windows=run_windows))
    rows.sort(key=lambda r: r["start_unix"])
    quality_seconds = float(windows_total * QUALITY_WINDOW_SECONDS)
    extra: dict[str, Any] = {
        "raw_diagnostics": raw, "native_rate_hz": rate_hz,
        "valid_waveform_fraction_unknown": valid_unknown,
        "computation": "per_run",
        "runs": _runs_summary(rows),
    }
    if not pooled:
        _add(reasons, "no_finite_template_similarity")
        return family_document(
            family="ppg_quality", status="ok", measurements=measurements,
            observed_seconds=observed, eligible_seconds=quality_seconds,
            reason_counts=reasons, extra=extra)

    arr = np.asarray(pooled, dtype=float)
    measurements["template_similarity_median"] = measurement(
        float(np.median(arr)), "correlation",
        denominator="complete 30 s core windows within runs, finite values",
        count=windows_total,
        method=(f"nk.ppg_quality(method={QUALITY_METHOD!r}) over "
                f"nk.ppg_clean(method={CLEANER!r}) signal, run by run; native "
                "correlation semantics, not a clinical quality class"))
    measurements["template_similarity_p25"] = measurement(
        float(np.percentile(arr, 25)), "correlation",
        denominator="complete 30 s core windows within runs, finite values",
        count=windows_total,
        method="p25 over the same pooled values")
    similarity = distribution_block("template_similarity_median", pooled, "template_similarity")
    if similarity is not None:
        extra["distributions"] = [similarity]
    return family_document(
        family="ppg_quality", status="ok", measurements=measurements,
        observed_seconds=observed, eligible_seconds=quality_seconds,
        reason_counts={"clipped_samples": raw["clipped_samples"],
                       "flat_runs": raw["flat_runs"], **reasons},
        extra=extra)


# ---------------------------------------------------------------------------
# pulse_shape
# ---------------------------------------------------------------------------

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


def _pool_metrics(per_run: list[dict[str, Any]]) -> dict[str, Any]:
    """Pool pulse metrics over runs: every accepted pulse counts once (real exposure)."""
    pooled: dict[str, Any] = {
        "accepted": 0, "rejected": {"multiple_peaks": 0, "incomplete": 0, "non_positive": 0},
        "amplitudes": [], "upstrokes_ms": [], "widths_ms": [], "normalized_areas": [],
        "durations_s": [],
    }
    for metrics in per_run:
        pooled["accepted"] += metrics["accepted"]
        for kind, count in metrics["rejected"].items():
            pooled["rejected"][kind] = pooled["rejected"].get(kind, 0) + count
        for key in ("amplitudes", "upstrokes_ms", "widths_ms", "normalized_areas", "durations_s"):
            pooled[key].extend(metrics[key])
    return pooled


def _summarize_pulses(metrics: dict[str, Any], *, keys: tuple[str, ...] | None = None,
                      provenance: dict[str, Any] | None = None) -> dict[str, Any]:
    """Median + IQR + counts for one set of accepted pulses.

    ``keys`` restricts the entries (the gain-independent subset for runs whose
    configuration is unidentified); ``provenance`` is merged into every entry.
    """
    def med(values): return float(np.median(values)) if values else None
    def iqr(values):
        return float(np.percentile(values, 75) - np.percentile(values, 25)) if values else None
    rejected_total = sum(metrics["rejected"].values())
    entries = {
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
            float(rejected_total), "count", count=rejected_total,
            method="multiple-peak/incomplete/non-positive pulses"),
    }
    if keys is not None:
        entries = {key: entry for key, entry in entries.items() if key in keys}
    if provenance:
        for entry in entries.values():
            entry.update(provenance)
    return entries


def _pulse_distributions(metrics: dict[str, Any], *, configuration: str | None,
                         amplitude: bool) -> list[dict[str, Any]]:
    blocks = [
        distribution_block("pulse_amplitude_median_au", metrics["amplitudes"],
                           "pulse_amplitude_au", configuration=configuration)
        if amplitude else None,
        distribution_block("pulse_upstroke_median_ms", metrics["upstrokes_ms"], "pulse_time_ms"),
        distribution_block("pulse_width50_median_ms", metrics["widths_ms"], "pulse_time_ms"),
        distribution_block("pulse_normalized_area_median", metrics["normalized_areas"], "pulse_area"),
    ]
    return [block for block in blocks if block is not None]


def _configuration_block(identity: str, members: list[tuple[PpgRun, dict[str, Any]]]
                         ) -> dict[str, Any]:
    """All pulses of one identified configuration, pooled across its runs."""
    pooled = _pool_metrics([metrics for _, metrics in members])
    first = members[0][0]
    return {
        "configuration": identity,
        "configuration_known": first.configuration_known,
        "identity_source": first.identity_source,
        "runs": len(members),
        "segments": sum(len(run.segment_indices) for run, _ in members),
        "observed_seconds": float(sum(run.duration for run, _ in members)),
        "accepted": pooled["accepted"],
        "rejected": pooled["rejected"],
        "eligible_seconds": float(sum(pooled["durations_s"])),
        "measurements": _summarize_pulses(
            pooled, provenance={"configuration": identity,
                                "configuration_known": first.configuration_known}),
        "distributions": _pulse_distributions(pooled, configuration=identity, amplitude=True),
    }


def _unidentified_block(members: list[tuple[PpgRun, dict[str, Any]]]) -> dict[str, Any]:
    """Runs whose configuration the transport did not identify.

    Their gain-independent features are pooled with exposure weights; their
    amplitudes are never pooled (see ``_run_amplitudes``).
    """
    pooled = _pool_metrics([metrics for _, metrics in members])
    return {
        "configuration": UNKNOWN_CONFIGURATION,
        "configuration_known": False,
        "configuration_unidentified": True,
        "identity_source": "transport",
        "runs": len(members),
        "segments": sum(len(run.segment_indices) for run, _ in members),
        "observed_seconds": float(sum(run.duration for run, _ in members)),
        "accepted": pooled["accepted"],
        "rejected": pooled["rejected"],
        "eligible_seconds": float(sum(pooled["durations_s"])),
        "amplitude_scope": "per_run",
        "measurements": _summarize_pulses(
            pooled, keys=GAIN_INDEPENDENT_KEYS,
            provenance={"configuration_known": False,
                        "configuration_scope": "pooled_across_unidentified_runs"}),
        "distributions": _pulse_distributions(pooled, configuration=None, amplitude=False),
    }


def _run_amplitudes(members: list[tuple[PpgRun, dict[str, Any]]]) -> dict[str, Any]:
    """Pulse amplitude of each unidentified-configuration run, one entry per run (bounded)."""
    rows = []
    for run, metrics in members:
        amps = metrics["amplitudes"]
        rows.append({
            "run": run.key,
            "start_unix": run.start,
            "duration_s": run.duration,
            "accepted": metrics["accepted"],
            "pulse_amplitude_median_au": float(np.median(amps)) if amps else None,
            "pulse_amplitude_iqr_au": (
                float(np.percentile(amps, 75) - np.percentile(amps, 25)) if amps else None),
        })
    listed = _bounded(rows, "accepted", MAX_LISTED_RUNS)
    return {
        "configuration": UNKNOWN_CONFIGURATION,
        "configuration_unidentified": True,
        "unit": "arbitrary ADC units",
        "method": ("median and IQR of each run's accepted pulse amplitudes (peak height above "
                   "the onset-to-onset baseline, cleaned waveform); one entry per run and never "
                   "pooled across runs, because the transport did not identify gain, drive or "
                   "channel"),
        "runs": len(rows),
        "listed": listed,
        "listed_truncated": len(rows) - len(listed),
    }


def compute_pulse_shape(segments: list[dict[str, Any]], rate_hz: float) -> dict[str, Any]:
    """The pulse_shape family document (spec 6.4): per run, then per configuration."""
    observed = sum(seg["duration"] for seg in segments)
    if rate_hz < MIN_CLEAN_RATE_HZ:
        return family_document(
            family="pulse_shape", status="withheld", reason="unsupported_native_rate",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"unsupported_native_rate": 1},
            extra={"native_rate_hz": rate_hz, "native_sample_period_ms": 1000.0 / rate_hz})

    raw = raw_diagnostics(segments, rate_hz)
    runs, run_counts = build_ppg_runs(segments)
    corruption = {run.key: _corruption(run.samples) for run in runs}
    corrupt = {key for key, found in corruption.items() if _is_corrupt(found)}
    common = {"native_rate_hz": rate_hz, "native_sample_period_ms": 1000.0 / rate_hz,
              "computation": "per_run"}

    # Flat/clipped/corrupt signals have no valid pulses: withheld with explicit
    # reasons, never filter-transient pseudo-pulses (spec 6.4). An older
    # worker's request keeps the request-wide gate it always had.
    if legacy_request(segments) and corrupt:
        reasons: dict[str, int] = {}
        _add(reasons, "saturated_delta", raw["clipped_samples"])
        _add(reasons, "flat_signal", raw["flat_runs"])
        return family_document(
            family="pulse_shape", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reasons, extra={"raw_diagnostics": raw, **common})

    reasons = dict(run_counts)
    rows: list[dict[str, Any]] = []
    analysed_runs: list[tuple[PpgRun, dict[str, Any]]] = []
    for run in runs:
        if run.key in corrupt:
            _add(reasons, "saturated_delta", corruption[run.key]["clipped_samples"])
            _add(reasons, "flat_signal", corruption[run.key]["flat_runs"])
            rows.append(_run_row(run, "corrupt", 0.0))
            continue
        if not _detectable(run, rate_hz):
            _add(reasons, "ppg_run_shorter_than_detector_window")
            rows.append(_run_row(run, "shorter_than_detector_window", 0.0))
            continue
        analysed = _analyse_run(run, rate_hz, with_quality=False)
        if analysed is None:
            _add(reasons, "ppg_run_no_pulses_detected")
            rows.append(_run_row(run, "no_pulses_detected", 0.0))
            continue
        metrics = _pulse_metrics(analysed["clean"], rate_hz, analysed["detected"])
        analysed_runs.append((run, metrics))
        rows.append(_run_row(run, "used", float(sum(metrics["durations_s"])),
                             accepted=metrics["accepted"]))
    rows.sort(key=lambda r: r["start_unix"])

    by_identity: dict[str, list[tuple[PpgRun, dict[str, Any]]]] = {}
    unidentified: list[tuple[PpgRun, dict[str, Any]]] = []
    for run, metrics in analysed_runs:
        if run.configuration_unidentified:
            unidentified.append((run, metrics))
        else:
            by_identity.setdefault(run.configuration, []).append((run, metrics))
    configurations = [_configuration_block(identity, members)
                      for identity, members in by_identity.items()]
    if unidentified:
        configurations.append(_unidentified_block(unidentified))
    accepted_total = sum(metrics["accepted"] for _, metrics in analysed_runs)
    rejected_totals = _pool_metrics([metrics for _, metrics in analysed_runs])["rejected"]
    reason_counts = {f"rejected_{kind}": count for kind, count in rejected_totals.items()}
    reason_counts.update(reasons)
    extra: dict[str, Any] = {"pooled_across_configurations": False, **common,
                             "runs": _runs_summary(rows)}
    if unidentified:
        # Real v26 data never identifies gain, drive or channel, so this is the
        # path it takes: amplitude per run, gain-independent features pooled.
        extra["amplitude_scope"] = "per_run"
        extra["amplitude_scope_reason"] = "configuration_unidentified"
        extra["run_amplitudes"] = _run_amplitudes(unidentified)
    if len(configurations) > MAX_LISTED_CONFIGURATIONS:
        configurations = sorted(configurations, key=lambda c: -c["accepted"])
        extra["configurations_truncated"] = len(configurations) - MAX_LISTED_CONFIGURATIONS
        _add(reason_counts, "pulse_configuration_blocks_truncated",
             extra["configurations_truncated"])
        configurations = configurations[:MAX_LISTED_CONFIGURATIONS]
    extra["configurations"] = configurations

    if accepted_total == 0:
        return family_document(
            family="pulse_shape", status="withheld", reason="not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reason_counts, extra=extra)

    # Amplitudes are never pooled across configurations. With exactly one
    # configuration block the top-level keys carry it directly (an unidentified
    # block carries no amplitude); with more, the blocks are the result and the
    # top level stays empty.
    measurements: dict[str, Any] = {}
    if len(configurations) == 1 and not extra.get("configurations_truncated"):
        measurements = {key: dict(entry) for key, entry in configurations[0]["measurements"].items()}
        if configurations[0]["distributions"]:
            extra["distributions"] = list(configurations[0]["distributions"])
    # eligible_seconds: seconds covered by ACCEPTED pulses (the summed pulse
    # durations), never the pulse COUNT (a duration is rendered as a duration).
    eligible_seconds = float(sum(sum(metrics["durations_s"]) for _, metrics in analysed_runs))
    return family_document(
        family="pulse_shape", status="ok", measurements=measurements,
        observed_seconds=observed, eligible_seconds=eligible_seconds,
        reason_counts=reason_counts, extra=extra)


# ---------------------------------------------------------------------------
# perfusion_research
# ---------------------------------------------------------------------------

def compute_perfusion_research(
    segments: list[dict[str, Any]], rate_hz: float, *, optical_dc: Any,
) -> dict[str, Any]:
    """The gated perfusion-like AC/DC ratio (spec 6.5).

    ``100 * (max(cleaned) - min(cleaned)) / abs(mean(raw))`` per run, computed
    ONLY behind the research gate with a verified optical DC contract (stable
    channel/drive/gain/offset, appropriate dark correction, valid raw anchor,
    unsaturated signal), then averaged per configuration identity weighted by
    run duration. It is amplitude-bearing, so it is never pooled across
    identities and never computed for an unidentified configuration. Near-zero
    or invalid denominators are withheld; the library's zero-denominator
    fallback is never accepted as a measured zero.
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

    runs, run_counts = build_ppg_runs(segments)
    unidentified = sum(1 for run in runs if run.configuration_unidentified)
    if unidentified:
        return family_document(
            family="perfusion_research", status="withheld",
            reason="unverified_optical_dc", measurements={},
            observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"configuration_unidentified": unidentified})

    def saturated(samples: np.ndarray) -> bool:
        return bool(np.any(np.abs(samples) >= ADC_SAMPLE_MAX) or np.any(samples <= ADC_SAMPLE_MIN))

    if legacy_request(segments) and any(saturated(run.samples) for run in runs):
        return family_document(
            family="perfusion_research", status="withheld", reason="saturated_delta",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts={"saturated_signal": 1})

    import neurokit2 as nk

    reasons: dict[str, int] = dict(run_counts)
    by_identity: dict[str, list[tuple[PpgRun, float]]] = {}
    for run in runs:
        raw = run.samples
        if saturated(raw):
            _add(reasons, "saturated_signal")
            continue
        dc = abs(float(np.mean(raw)))
        if not math.isfinite(dc) or dc < 1e-9:
            _add(reasons, "invalid_or_near_zero_dc_denominator")
            continue
        # A flat AC signal (no pulsatile component) is not a measured zero
        # ratio: the gate requires an unsaturated signal WITH a pulsatile component.
        ac_span = float(np.max(raw) - np.min(raw))
        if not math.isfinite(ac_span) or ac_span <= 0.0:
            _add(reasons, "flat_ac_signal")
            continue
        if not _detectable(run, rate_hz):
            _add(reasons, "ppg_run_shorter_than_detector_window")
            continue
        clean = nk.ppg_clean(raw, sampling_rate=int(round(rate_hz)), method=CLEANER)
        ratio = 100.0 * float(np.max(clean) - np.min(clean)) / dc
        if not math.isfinite(ratio):
            _add(reasons, "non_finite_ratio")
            continue
        by_identity.setdefault(run.configuration, []).append((run, ratio))

    if not by_identity:
        all_saturated = reasons.get("saturated_signal", 0) == len(runs)
        return family_document(
            family="perfusion_research", status="withheld",
            reason="saturated_delta" if all_saturated else "not_enough_valid_data",
            measurements={}, observed_seconds=observed, eligible_seconds=0.0,
            reason_counts=reasons)

    blocks = []
    for identity, members in by_identity.items():
        seconds = float(sum(run.duration for run, _ in members))
        value = float(sum(run.duration * ratio for run, ratio in members) / seconds)
        blocks.append({
            "configuration": identity,
            "configuration_known": members[0][0].configuration_known,
            "runs": len(members),
            "eligible_seconds": seconds,
            "measurements": {"estimated_ac_dc_ratio_percent": measurement(
                value, "percent", count=int(sum(run.samples.size for run, _ in members)),
                method="100*(max(cleaned)-min(cleaned))/abs(mean(raw)) per run, duration-"
                       "weighted mean over the configuration's runs; estimated AC/DC "
                       "ratio, NOT a circulation measure",
                native_resolution="ADC-derived arbitrary units",
                configuration=identity,
                configuration_known=members[0][0].configuration_known)},
        })
    measurements = dict(blocks[0]["measurements"]) if len(blocks) == 1 else {}
    return family_document(
        family="perfusion_research", status="ok",
        measurements=measurements,
        observed_seconds=observed,
        eligible_seconds=float(sum(block["eligible_seconds"] for block in blocks)),
        reason_counts=reasons,
        extra={"optical_dc": {
            "channel": optical_dc.get("channel"),
            "drive": optical_dc.get("drive"),
            "gain": optical_dc.get("gain"),
            "method_revision": optical_dc.get("method_revision"),
        }, "configurations": blocks, "pooled_across_configurations": False,
            "computation": "per_run"})


def make_providers() -> list[Any]:
    """PPG families are computed inside the main sensor provider
    (sensor.biomarkers.v1); this module exports the compute functions only."""
    return []
