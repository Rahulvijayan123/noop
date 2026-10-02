"""Sleep-boundary candidate provider: HypnosPy HR boundary algorithm.

Provider id ``hypnospy.hr-boundary.v1``.  Metric ``sleep_boundary``.  Retrospective.

Interval conventions
----------------------
``result.intervals`` carries the boundary kinds. Two conventions a consumer must know:

* ``sleep_onset`` and ``final_wake`` **both span the whole sleep period**; read
  ``sleep_onset.start_utc`` for the onset and ``final_wake.end_utc`` for the final wake.
* the sleep period is bounded by the first and last accepted sleep piece **inside the selected
  in-bed interval**, so scored-awake time between them is reported as ``waso`` (a fragmented
  night reports real WASO). ``nap`` means a sleep episode inside the analysis block but
  **outside** the selected in-bed window - typically a daytime sleep found by a
  re-parameterised search window; ``in_bed`` is always reported separately and is never
  counted as asleep.

Scope
-----
Boundaries only.  This provider never writes, and never returns, anything shaped like the
four-stage canonical display (``stagesJSON`` / ``StageSegment`` / ``SleepStageTotals.Minutes``):
``result.intervals`` carries the boundary kinds, and nothing else.

Adapter responsibilities (each one neutralises a measured upstream defect; see
``hypnospy_vendored/PROVENANCE.md`` section 4)

1. Compute the FRWHOOP analysis day from the **wake** timestamp in the user's IANA zone, and
   hand the vendored algorithm exactly one analysis-day block (D4).
2. Resample the HR stream onto a fixed epoch grid and set the epoch length explicitly; the
   algorithm is never allowed to infer a frequency (D3).
3. Gap-mask **before** the call: every invalid epoch (missing sample, dropout >= 2 min, or
   heart rate outside physiological bounds) is filled with a high sentinel so the upstream
   ``NaN -> SLEEP`` rule cannot turn a wear gap into sleep (D1, D6).
4. Gap-mask **after** the call: accepted intervals are cut at every gap, the gap fraction per
   interval is reported, and pieces shorter than ``min_interval_seconds`` are dropped.
5. Always pass an explicit search window (D5), and report the threshold and whether it was
   inherited from a neighbouring day (D2).
6. Report the heart-rate dip relative to the daytime reference and an optional
   ``require_hr_dip_bpm`` gate, because the upstream threshold is relative (D7).
"""

from __future__ import annotations

import time
from datetime import timedelta
from typing import Any, Optional, Sequence
from zoneinfo import ZoneInfo

import numpy as np

from ..hypnospy_vendored import SleepBoudaryDetector, Wearable
from ..timebase import (
    GAP_MIN_SECONDS_DEFAULT,
    InputError,
    UTC,
    merge_intervals,
    analysis_block,
    block_hours,
    detect_gaps,
    epoch_gap_mask,
    finite_or_none,
    json_safe,
    local_datetime,
    mask_to_intervals,
    parse_ts,
    parse_zone,
    resample_to_grid,
    sha256_payload,
    split_interval_at_gaps,
)

PROVIDER_ID = "hypnospy.hr-boundary.v1"
METRIC = "sleep_boundary"
ADAPTER_VERSION = "hypnospy.hr-boundary.v1/1.0.0"
PREPROCESSING_VERSION = "hr-fixed-grid-gapmask/1.0.0"
CONFIG_VERSION = "hypnospy-hr-defaults/1.0.0"
VENDORED_COMMIT = "3b6c825d1568158cbf0058de50495e5308117d17"
LICENSE_NOTE = ("MIT per the repository LICENSE file; setup.py declares BSD - unresolved, "
                "promotion requires reconciliation")
REQUIRED_SIGNALS = ["hr"]
LABEL_SPACE = "in_bed/sleep_onset/final_wake/nap/waso"
MODE = "retrospective"
ACCURACY_STATUS = "unverified_accuracy"
TIME_COL = "hyp_time_col"
HR_COL = "hr"
OUTPUT_COL = "hyp_sleep_period"

DEFAULT_PARAMS: dict[str, Any] = {
    "search_window_local_hours": [20, 12],
    "quantile": 0.4,
    "volatility_threshold": 5.0,
    "rolling_win_minutes": 5,
    "min_window_minutes": 40,
    "volatility_window_minutes": 10,
    "merge_gap_minutes": 240,
    "only_largest_sleep_period": False,
}

DEFAULT_CONFIG: dict[str, Any] = {
    "hr_grid_seconds": 60,
    "gap_min_seconds": GAP_MIN_SECONDS_DEFAULT,
    "gap_fill_bpm": 250.0,
    "hr_min_bpm": 20.0,
    "hr_max_bpm": 250.0,
    "min_coverage_fraction": 0.5,
    "max_gap_fraction_in_interval": 0.5,
    "min_interval_seconds": 1200,
    "daytime_band_local_hours": [11, 20],
    "min_nap_seconds": 1200,
    "require_hr_dip_bpm": None,
    "min_daytime_reference_samples": 60,
    "flat_night_dip_bpm": 3.0,
}



def _merged(defaults: dict, overrides: Optional[dict], field: str) -> dict:
    out = dict(defaults)
    if overrides:
        unknown = sorted(set(overrides) - set(defaults))
        if unknown:
            raise InputError(
                "unknown_%s" % field,
                "unknown %s key(s): %s" % (field, ", ".join(unknown)),
            )
        out.update(overrides)
    return out


def _read_samples(hr_payload) -> list[tuple[int, Optional[float]]]:
    """Accept [[ts, bpm], ...] or [{"ts": ..., "bpm": ...}, ...]."""
    if hr_payload is None:
        raise InputError("missing_hr", "input.hr is required")
    if not isinstance(hr_payload, (list, tuple)):
        raise InputError("invalid_hr", "input.hr must be a list")
    samples: list[tuple[int, Optional[float]]] = []
    for item in hr_payload:
        if isinstance(item, dict):
            ts_raw = item.get("ts", item.get("ts_utc"))
            bpm_raw = item.get("bpm", item.get("hr"))
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            ts_raw, bpm_raw = item
        else:
            raise InputError("invalid_hr", "each hr sample must be [ts, bpm] or {ts, bpm}: %r" % (item,))
        ts = parse_ts(ts_raw, "hr.ts")
        if bpm_raw is None:
            samples.append((ts, None))
        else:
            try:
                bpm = float(bpm_raw)
            except (TypeError, ValueError):
                raise InputError("invalid_hr", "hr.bpm must be numeric or null: %r" % (bpm_raw,))
            samples.append((ts, bpm if np.isfinite(bpm) else None))
    samples.sort(key=lambda s: s[0])
    return samples


def _versions(config: dict, params: dict) -> dict:
    import pandas as pd

    return {
        "adapter": ADAPTER_VERSION,
        "preprocessing": PREPROCESSING_VERSION,
        "dependency": "hypnospy@%s;pandas==%s;numpy==%s" % (
            VENDORED_COMMIT[:12], pd.__version__, np.__version__),
        "config": CONFIG_VERSION,
        "model": None,
    }


def _diagnostic_bounds(config: dict) -> tuple[float, float]:
    lo = float(config["hr_min_bpm"])
    hi = float(config["hr_max_bpm"])
    if not (0 < lo < hi <= 400):
        raise InputError("invalid_config", "hr_min_bpm/hr_max_bpm are out of range")
    return lo, hi


def _resolve_window(params: dict) -> tuple[int, int]:
    window = params["search_window_local_hours"]
    if not isinstance(window, (list, tuple)) or len(window) != 2:
        raise InputError("invalid_search_window", "search_window_local_hours must be [start_hour, end_hour]")
    return int(window[0]), int(window[1])


def _daytime_reference(
    samples: Sequence[tuple[int, Optional[float]]],
    wake_day,
    zone: ZoneInfo,
    band: Sequence[int],
    min_samples: int,
) -> dict:
    """Median HR over the local daytime band on the day before the wake day.

    This is the region upstream masks to NaN, so it is available as an independent
    "awake" reference for the relative-threshold diagnostics.
    """
    from datetime import datetime, timedelta

    band_start = datetime(wake_day.year, wake_day.month, wake_day.day, int(band[0]), tzinfo=zone) - timedelta(days=1)
    band_end = datetime(wake_day.year, wake_day.month, wake_day.day, int(band[1]), tzinfo=zone) - timedelta(days=1)
    lo, hi = int(band_start.timestamp()), int(band_end.timestamp())
    values = [v for ts, v in samples if lo <= ts < hi and v is not None]
    if len(values) < min_samples:
        return {"samples": len(values), "median_bpm": None, "window_utc": [lo, hi]}
    return {"samples": len(values), "median_bpm": round(float(np.median(values)), 3), "window_utc": [lo, hi]}


def _interval_dict(start: int, end: int, kind: str, **extra) -> dict:
    out = {"start_utc": int(start), "end_utc": int(end), "kind": kind}
    out.update(extra)
    return out


def _withheld(reason: str, detail: str, *, versions, context, interval, input_sha, diagnostics,
              runtime_ms: int, coverage: Optional[dict] = None) -> dict:
    return {
        "status": "withheld",
        "metric": METRIC,
        "provider_id": PROVIDER_ID,
        "versions": versions,
        "input": {"sha256": input_sha, "refs": {"context": context}},
        "result": None,
        "interval": interval,
        "final_or_provisional": "provisional",
        "coverage": coverage or {},
        "raw_scores": None,
        "diagnostics": dict(diagnostics, reason_detail=detail),
        "runtime_ms": int(runtime_ms),
        "withheld_reason": reason,
    }


class SleepBoundaryProvider:
    """HypnosPy HR sleep-boundary candidate provider."""

    provider_id = PROVIDER_ID
    metric = METRIC
    mode = MODE
    required_signals = REQUIRED_SIGNALS
    label_space = LABEL_SPACE

    def __init__(self, *, params: Optional[dict] = None, config: Optional[dict] = None):
        self.params_defaults = _merged(DEFAULT_PARAMS, params, "params")
        self.config_defaults = _merged(DEFAULT_CONFIG, config, "config")

    # -- server surface --------------------------------------------------------
    def manifest(self) -> dict:
        return {
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": {
                "adapter": ADAPTER_VERSION,
                "preprocessing": PREPROCESSING_VERSION,
                "dependency": "hypnospy@%s" % VENDORED_COMMIT,
                "config": CONFIG_VERSION,
                "model": None,
            },
            "required_signals": list(REQUIRED_SIGNALS),
            "label_space": LABEL_SPACE,
            "retrospective_or_causal": MODE,
            "accuracy_status": ACCURACY_STATUS,
            "eligibility": {
                "state": "shadow_eligible",
                "reason": None,
                "promotion_blocked_by": ["license_reconciliation", "unverified_accuracy"],
            },
            "license": {"spdx": "MIT", "note": LICENSE_NOTE, "file": "hypnospy_vendored/LICENSE"},
            "vendored_commit": VENDORED_COMMIT,
            "defaults": {"params": self.params_defaults, "config": self.config_defaults},
        }

    def readiness(self) -> dict:
        try:
            import pandas as pd  # noqa: F401
            from ..hypnospy_vendored import SleepBoudaryDetector  # noqa: F401
        except Exception as exc:  # pragma: no cover - exercised by the readiness test
            return {"ready": False, "version": ADAPTER_VERSION,
                    "reason": "dependency_missing: %s: %s" % (type(exc).__name__, exc)}
        return {"ready": True, "version": ADAPTER_VERSION, "reason": None}

    def register(self, registry: dict) -> dict:
        """Register this provider in a ``{metric: provider}`` registry."""
        registry[METRIC] = self
        return registry

    # -- inference -------------------------------------------------------------
    def infer(self, *, input: dict, context: dict, provider: Optional[dict] = None) -> dict:
        started = time.time()
        provider = provider or {}
        context = context or {}
        input = input or {}

        try:
            expected_id = provider.get("provider_id")
            if expected_id and expected_id != PROVIDER_ID:
                return self._error("provider_id_mismatch", "requested %r, this provider is %r"
                                   % (expected_id, PROVIDER_ID), started)
            params = _merged(self.params_defaults, input.get("params"), "params")
            config = _merged(self.config_defaults, input.get("config"), "config")
            return self._infer(input, context, params, config, started)
        except InputError as exc:
            return self._error(exc.code, str(exc), started, status="error")
        except Exception as exc:  # never crash the worker
            import traceback
            return self._error("provider_error", "%s: %s" % (type(exc).__name__, exc), started,
                               status="error", traceback=traceback.format_exc().strip().splitlines()[-3:])

    def _error(self, detail: str, message: str, started: float, *, status: str = "error",
               traceback: Optional[list] = None) -> dict:
        return {
            "status": status,
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": {"adapter": ADAPTER_VERSION, "preprocessing": PREPROCESSING_VERSION,
                         "dependency": "hypnospy@%s" % VENDORED_COMMIT, "config": CONFIG_VERSION,
                         "model": None},
            "input": {"sha256": None, "refs": {}},
            "result": None,
            "interval": None,
            "final_or_provisional": "provisional",
            "coverage": {},
            "raw_scores": None,
            "diagnostics": {"reason_detail": detail, "message": message,
                            **({"traceback_tail": traceback} if traceback else {})},
            "runtime_ms": int((time.time() - started) * 1000),
            **({"withheld_reason": "blocked_input"} if status == "withheld" else {"error": detail}),
        }

    def _infer(self, payload: dict, context: dict, params: dict, config: dict, started: float) -> dict:
        import pandas as pd

        zone = parse_zone(context.get("iana_timezone"))
        samples = _read_samples(payload.get("hr"))
        if not samples:
            raise InputError("missing_hr", "input.hr is empty")

        interval_start = parse_ts(context.get("interval_start_utc"), "interval_start_utc")
        interval_end = parse_ts(context.get("interval_end_utc"), "interval_end_utc")
        # E2E seam: an explicit input.window overrides the context interval as the in-bed
        # interval for this call (the worker knows the accepted session bounds; the context
        # interval is the coarser day/recompute range). Absent -> context wins.
        window_block = payload.get("window") or {}
        in_bed_source = "context.interval"
        if isinstance(window_block, dict) and window_block:
            if window_block.get("start_utc") is not None:
                interval_start = parse_ts(window_block["start_utc"], "window.start_utc")
            if window_block.get("end_utc") is not None:
                interval_end = parse_ts(window_block["end_utc"], "window.end_utc")
            in_bed_source = "input.window"
        elif window_block:
            raise InputError("invalid_interval_window", "input.window must be an object with "
                                                       "start_utc/end_utc")
        if interval_end <= interval_start:
            raise InputError("invalid_interval", "interval_end_utc must be after interval_start_utc")

        wake_ts = parse_ts(payload["wake_ts_utc"], "wake_ts_utc") if payload.get("wake_ts_utc") else interval_end
        wake_day = local_datetime(wake_ts, zone).date()
        declared_day = payload.get("analysis_day")
        if declared_day and str(declared_day) != wake_day.isoformat():
            raise InputError("analysis_day_mismatch",
                             "analysis_day %r disagrees with the wake date %s of wake_ts_utc"
                             % (declared_day, wake_day.isoformat()))

        start_hour, end_hour = _resolve_window(params)
        block_start, block_end = analysis_block(wake_day, zone, start_hour, end_hour)
        grid_seconds = int(config["hr_grid_seconds"])
        gap_min_seconds = int(config["gap_min_seconds"])
        hr_lo, hr_hi = _diagnostic_bounds(config)

        input_sha = sha256_payload({
            "provider_id": PROVIDER_ID, "adapter": ADAPTER_VERSION,
            "preprocessing": PREPROCESSING_VERSION, "config": CONFIG_VERSION,
            "config_values": config, "params": params,
            "user_id": context.get("user_id"), "device_id": context.get("device_id"),
            "iana_timezone": context.get("iana_timezone"),
            "interval": [interval_start, interval_end], "wake_ts_utc": wake_ts,
            "hr": samples,
        })
        interval = {"start_utc": interval_start, "end_utc": interval_end,
                    "analysis_day": wake_day.isoformat(), "iana_timezone": context.get("iana_timezone")}
        versions = _versions(config, params)
        base_diag: dict[str, Any] = {
            "analysis_day": wake_day.isoformat(),
            "iana_timezone": context.get("iana_timezone"),
            "wake_ts_utc": wake_ts,
            "search_window_local_hours": [start_hour, end_hour],
            "analysis_block_utc": [block_start, block_end],
            "analysis_block_hours": block_hours(block_start, block_end),
            "in_bed_source": in_bed_source,
            "params": params,
            "config": config,
            "accuracy_status": ACCURACY_STATUS,
            "license_note": LICENSE_NOTE,
            "vendored_commit": VENDORED_COMMIT,
        }

        wake_local = local_datetime(wake_ts, zone)
        if not (block_start <= wake_ts < block_end):
            return _withheld("blocked_input", "wake_outside_search_window", versions=versions,
                             context={"analysis_day": wake_day.isoformat(),
                                      "search_window_local_hours": [start_hour, end_hour],
                                      "wake_local": wake_local.isoformat()},
                             interval=interval, input_sha=input_sha,
                             diagnostics=dict(base_diag, message="the wake timestamp is outside the "
                                              "configured local search window; re-parameterise "
                                              "search_window_local_hours for this user"),
                             runtime_ms=int((time.time() - started) * 1000))

        if payload.get("user_edit"):
            return _withheld("blocked_input", "user_edit_present", versions=versions,
                             context={"user_edit": payload.get("user_edit")},
                             interval=interval, input_sha=input_sha,
                             diagnostics=dict(base_diag, user_edit=payload.get("user_edit"),
                                              message="user-corrected bounds outrank any candidate"),
                             runtime_ms=int((time.time() - started) * 1000))

        # ---- resample + gap mask (before the vendored call) --------------------
        block_samples = [(ts, v) for ts, v in samples if block_start <= ts < block_end]
        epoch_times, values, grid_diag = resample_to_grid(block_samples, block_start, block_end, grid_seconds)
        in_bounds = np.isfinite(values) & (values >= hr_lo) & (values <= hr_hi)
        # Gap policy is owned by the adapter, not by HypnosPy. Two sources are combined:
        #  * absence in the input stream (a sample-to-sample jump >= gap_min_seconds), and
        #  * unoccupied / out-of-bounds epochs on the fixed grid (a null-valued row, or a
        #    run of physiologically impossible values, is a dropout too).
        sample_gaps = detect_gaps([ts for ts, _ in samples], gap_min_seconds)
        grid_gaps = [g for g in mask_to_intervals(epoch_times, ~in_bounds, grid_seconds)
                     if (g[1] - g[0]) >= gap_min_seconds]
        gaps = merge_intervals(list(sample_gaps) + grid_gaps)
        gap_mask = epoch_gap_mask(epoch_times, gaps)
        valid_mask = in_bounds & ~gap_mask
        out_of_bounds = int((np.isfinite(values) & ((values < hr_lo) | (values > hr_hi))).sum())

        coverage = {
            "epochs": int(len(epoch_times)),
            "valid_epochs": int(valid_mask.sum()),
            "occupancy_fraction": grid_diag["occupancy_fraction"],
            "hr_coverage_fraction": round(float(valid_mask.mean()), 5),
            "gap_count": len(gaps),
            "gap_seconds_total": int(sum(hi - lo for lo, hi in gaps)),
            "gap_seconds_in_block": int(gap_mask.sum()) * grid_seconds,
            "grid_seconds": grid_seconds,
        }
        diag = dict(base_diag, **grid_diag, **{
            "gap_count": len(gaps),
            "sample_gap_count": len(sample_gaps),
            "grid_gap_count": len(grid_gaps),
            "gaps_utc": [[int(a), int(b)] for a, b in gaps],
            "sentinel_epochs": int((~valid_mask).sum()),
            "sentinel_bpm": float(config["gap_fill_bpm"]),
            "out_of_bounds_epochs": out_of_bounds,
            "hr_min_bpm": hr_lo,
            "hr_max_bpm": hr_hi,
        })

        if valid_mask.sum() == 0:
            return _withheld("insufficient_coverage", "no_usable_hr", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))
        if float(valid_mask.mean()) < float(config["min_coverage_fraction"]):
            return _withheld("insufficient_coverage", "low_hr_coverage", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        # the threshold is recomputed here for diagnostics only; the vendored code computes
        # its own (identical) quantile over the same in-window samples
        threshold = float(np.quantile(values[valid_mask], float(params["quantile"])))
        diag["per_day_threshold_bpm"] = round(threshold, 4)
        diag["threshold_recomputed_outside_algorithm"] = True
        diag["threshold_inherited_from_neighbour_day"] = False  # exactly one block is passed

        frame = pd.DataFrame({
            TIME_COL: pd.to_datetime(epoch_times, unit="s", utc=True).tz_convert(zone),
            HR_COL: np.where(valid_mask, values, float(config["gap_fill_bpm"])),
        })
        wearable = Wearable(frame, TIME_COL, HR_COL,
                            pid=str(context.get("user_id") or "unknown"),
                            freq_in_secs=grid_seconds)
        wearable.set_frequency_in_secs(grid_seconds)
        wearable.change_start_hour_for_experiment_day(start_hour)

        algorithm_error = None
        raw_sleep_epochs = 0
        try:
            detector = SleepBoudaryDetector(wearable)
            detector.detect_sleep_boundaries(
                strategy="hr",
                output_col=OUTPUT_COL,
                hr_quantile=float(params["quantile"]),
                hr_volarity_threshold=float(params["volatility_threshold"]),
                hr_rolling_win_in_minutes=int(params["rolling_win_minutes"]),
                hr_sleep_search_window=(start_hour, end_hour),
                hr_min_window_length_in_minutes=int(params["min_window_minutes"]),
                hr_volatility_window_in_minutes=int(params["volatility_window_minutes"]),
                hr_merge_blocks_gap_time_in_min=int(params["merge_gap_minutes"]),
                hr_sleep_only_in_sleep_search_window=True,
                hr_only_largest_sleep_period=bool(params["only_largest_sleep_period"]),
            )
        except Exception as exc:
            import traceback
            algorithm_error = {
                "error": "%s: %s" % (type(exc).__name__, exc),
                "traceback_tail": traceback.format_exc().strip().splitlines()[-3:],
            }

        if algorithm_error is not None:
            return _withheld("provider_error", "algorithm_error", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=dict(diag, algorithm_error=algorithm_error),
                             coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        result_frame = wearable.data.copy()
        result_frame["__ts"] = result_frame[TIME_COL]
        result_frame = result_frame.sort_values("__ts").reset_index(drop=True)
        raw_mask = result_frame[OUTPUT_COL].astype(bool).to_numpy()
        raw_sleep_epochs = int(raw_mask.sum())
        # gap mask AFTER the call: a sentinel epoch can never be sleep
        sleep_mask = raw_mask & valid_mask

        diag["raw_algorithm"] = {
            "sleep_epochs_before_gap_mask": raw_sleep_epochs,
            "sleep_epochs_after_gap_mask": int(sleep_mask.sum()),
            "epochs": int(len(sleep_mask)),
            "sentinel_epochs_forced_awake": int((raw_mask & ~valid_mask).sum()),
        }

        pieces = mask_to_intervals(epoch_times, sleep_mask, grid_seconds)
        if not pieces:
            return _withheld("insufficient_coverage", "no_sleep_period_detected", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        min_piece = int(config["min_interval_seconds"])
        accepted: list[tuple[int, int]] = []
        piece_diag = []
        worst_gap_fraction = 0.0
        for start, end in pieces:
            kept, gap_fraction = split_interval_at_gaps(start, end, gaps, min_piece)
            worst_gap_fraction = max(worst_gap_fraction, gap_fraction)
            piece_diag.append({
                "start_utc": int(start), "end_utc": int(end), "seconds": int(end - start),
                "gap_fraction": gap_fraction,
                "kept": [[int(a), int(b)] for a, b in kept],
                "dropped_below_min_piece_seconds": min_piece if not kept else None,
            })
            accepted.extend(kept)

        diag["sleep_pieces"] = piece_diag
        diag["gap_fraction_inside_intervals"] = round(worst_gap_fraction, 5)
        diag["max_gap_fraction_in_interval"] = float(config["max_gap_fraction_in_interval"])

        if not accepted:
            return _withheld("artifact_fraction", "unresolved_gap", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        # ---- select the sleep period (review F2) ------------------------------
        # The night's sleep period is bounded by the FIRST and the LAST accepted sleep piece
        # that lies inside the selected in-bed interval. Scored-awake epochs between them are
        # wake-after-sleep-onset, so a fragmented night reports real WASO instead of collapsing
        # to the longest gap-free piece (which made WASO structurally 0).
        # A merged candidate cut by WEAR GAPS still spans the gaps; those epochs are unscored.
        candidate_periods = mask_to_intervals(epoch_times, raw_mask, grid_seconds)
        diag["algorithm_candidate_periods"] = len(candidate_periods)
        accepted.sort()
        sel_lo, sel_hi = int(interval_start), int(interval_end)
        inside = [(a, b) for a, b in accepted if b > sel_lo and a < sel_hi]
        outside = [(a, b) for a, b in accepted if not (b > sel_lo and a < sel_hi)]
        if inside:
            onset = max(min(a for a, _ in inside), sel_lo)
            wake = min(max(b for _, b in inside), sel_hi)
            if len(inside) == 1:
                diag["sleep_span_source"] = "in_bed_single_piece"
            elif len(candidate_periods) == 1:
                diag["sleep_span_source"] = "single_candidate_spanning_gaps"
            else:
                diag["sleep_span_source"] = "in_bed_span"
            diag["sleep_pieces_inside_in_bed"] = [[int(a), int(b)] for a, b in inside]
        else:
            by_length = sorted(accepted, key=lambda p: (p[1] - p[0]), reverse=True)
            onset, wake = by_length[0]
            outside = by_length[1:]
            diag["sleep_span_source"] = "longest_piece_outside_in_bed"

        span_gap_seconds = 0
        for lo, hi in gaps:
            span_gap_seconds += max(0, min(hi, wake) - max(lo, onset))
        span_gap_fraction = span_gap_seconds / float(wake - onset) if wake > onset else 0.0
        diag["gap_fraction_in_selected_span"] = round(span_gap_fraction, 5)
        diag["worst_gap_fraction_per_piece"] = round(worst_gap_fraction, 5)
        if span_gap_fraction > float(config["max_gap_fraction_in_interval"]):
            return _withheld("artifact_fraction", "unresolved_gap", versions=versions,
                             context={"analysis_block_utc": [block_start, block_end]},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        # ---- assemble the semantic boundary result ----------------------------
        in_bed_start, in_bed_end = interval_start, interval_end
        if not (in_bed_start <= onset < in_bed_end):
            in_bed_start = min(in_bed_start, onset)
            in_bed_end = max(in_bed_end, wake)

        onset_idx = int(np.searchsorted(epoch_times, onset))
        wake_idx = int(np.searchsorted(epoch_times, wake))
        # WASO counts only SCORED awake epochs: a missing (unscored) epoch is not wake.
        awake_inside = (~sleep_mask[onset_idx:wake_idx]) & valid_mask[onset_idx:wake_idx]
        awake_times = epoch_times[onset_idx:wake_idx]
        waso_pieces = mask_to_intervals(awake_times, awake_inside, grid_seconds) if len(awake_times) else []
        waso_pieces = [(max(a, onset), min(b, wake)) for a, b in waso_pieces if b > a]
        waso_pieces = [(a, b) for a, b in waso_pieces if (b - a) >= min_piece]

        band_start_hour, band_end_hour = config["daytime_band_local_hours"]
        naps = []
        fragments = []
        # Pieces OUTSIDE the selected in-bed interval are separate sleep episodes: a daytime one
        # is a nap, anything else is reported as a fragment. Pieces inside the in-bed interval
        # are part of the sleep period above, and their awake time is WASO.
        for start, end in outside:
            local_start = local_datetime(start, zone)
            in_band = band_start_hour <= local_start.hour < band_end_hour
            entry = {"start_utc": int(start), "end_utc": int(end), "seconds": int(end - start),
                     "local_start": local_start.isoformat(), "inside_daytime_band": bool(in_band)}
            if in_band and (end - start) >= int(config["min_nap_seconds"]):
                naps.append(entry)
            else:
                fragments.append(entry)

        intervals_out = [
            _interval_dict(in_bed_start, in_bed_end, "in_bed",
                           note="reported separately from asleep; never counted as sleep"),
            _interval_dict(onset, wake, "sleep_onset"),
            _interval_dict(onset, wake, "final_wake"),
        ]
        intervals_out += [_interval_dict(e["start_utc"], e["end_utc"], "nap",
                                         seconds=e["seconds"], local_start=e["local_start"])
                          for e in naps]
        intervals_out += [_interval_dict(a, b, "waso", seconds=int(b - a)) for a, b in waso_pieces]

        unscored = []
        for lo, hi in gaps:
            seg_start = max(lo, block_start)
            seg_end = min(hi, block_end)
            if seg_end > seg_start:
                unscored.append({"start_utc": int(seg_start), "end_utc": int(seg_end),
                                 "reason": "no_usable_hr", "seconds": int(seg_end - seg_start)})
        sentinel_times = epoch_times[~valid_mask]
        if len(sentinel_times):
            sentinel_intervals = mask_to_intervals(sentinel_times, np.ones(len(sentinel_times), bool),
                                                   grid_seconds)
            for a, b in sentinel_intervals:
                if not any(u["start_utc"] <= a and b <= u["end_utc"] for u in unscored):
                    unscored.append({"start_utc": int(a), "end_utc": int(b),
                                     "reason": "no_usable_hr", "seconds": int(b - a)})

        # ---- diagnostics: dip, flat night, optional gate ----------------------
        reference = _daytime_reference(samples, wake_day, zone,
                                       config["daytime_band_local_hours"],
                                       int(config["min_daytime_reference_samples"]))
        sleep_values = values[sleep_mask]
        sleep_median = float(np.median(sleep_values)) if sleep_values.size else None
        dip = None
        if reference["median_bpm"] is not None and sleep_median is not None:
            dip = round(reference["median_bpm"] - sleep_median, 3)
        # The gate uses the in-bed window, not the detected period: the upstream threshold is
        # relative, so a night whose heart rate never drops below the daytime reference can
        # place its "sleep" period anywhere in the block.
        in_bed_lo = max(int(interval_start), int(block_start))
        in_bed_hi = min(int(interval_end), int(block_end))
        in_bed_sel = (epoch_times >= in_bed_lo) & (epoch_times < in_bed_hi) & valid_mask
        in_bed_values = values[in_bed_sel]
        in_bed_median = float(np.median(in_bed_values)) if in_bed_values.size else None
        in_bed_dip = None
        if reference["median_bpm"] is not None and in_bed_median is not None:
            in_bed_dip = round(reference["median_bpm"] - in_bed_median, 3)
        flat_night = in_bed_dip is not None and in_bed_dip < float(config["flat_night_dip_bpm"])
        diag["in_bed_median_bpm"] = None if in_bed_median is None else round(in_bed_median, 3)
        diag["in_bed_dip_bpm"] = in_bed_dip
        diag["in_bed_window_utc"] = [in_bed_lo, in_bed_hi]
        diag["daytime_reference"] = reference
        diag["sleep_median_bpm"] = None if sleep_median is None else round(sleep_median, 3)
        diag["hr_dip_bpm"] = dip
        diag["flat_night"] = bool(flat_night)
        diag["require_hr_dip_bpm"] = config["require_hr_dip_bpm"]
        diag["sleep_onset_utc"] = int(onset)
        diag["final_wake_utc"] = int(wake)
        diag["sleep_period_seconds"] = int(wake - onset)
        diag["naps"] = naps
        diag["sleep_fragments_outside_main_period"] = fragments
        diag["unscored"] = unscored
        diag["waso_seconds"] = int(sum(b - a for a, b in waso_pieces))
        diag["notes"] = [
            "boundaries only; this provider never writes the four-stage canonical fields",
            "unverified_accuracy: no independent reference was used (spec section 8)",
            "in_bed is reported separately from asleep",
        ]

        required_dip = config["require_hr_dip_bpm"]
        if required_dip is not None and (in_bed_dip is None or in_bed_dip < float(required_dip)):
            return _withheld("insufficient_coverage", "no_hr_dip", versions=versions,
                             context={"required_hr_dip_bpm": float(required_dip),
                                      "in_bed_dip_bpm": in_bed_dip, "hr_dip_bpm": dip},
                             interval=interval, input_sha=input_sha,
                             diagnostics=diag, coverage=coverage,
                             runtime_ms=int((time.time() - started) * 1000))

        return {
            "status": "ok",
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": versions,
            "input": {"sha256": input_sha,
                      "refs": {"context": {"user_id": context.get("user_id"),
                                           "device_id": context.get("device_id"),
                                           "interval_start_utc": interval_start,
                                           "interval_end_utc": interval_end,
                                           "iana_timezone": context.get("iana_timezone")},
                               "hr_samples": len(samples),
                               "hr_samples_in_block": grid_diag["samples_in_block"]}},
            "result": {
                "label_space": LABEL_SPACE,
                "intervals": intervals_out,
                "unscored": unscored,
                "value": None,
                "unit": None,
            },
            "interval": interval,
            "final_or_provisional": "final",
            "coverage": coverage,
            "raw_scores": None,
            "diagnostics": json_safe(diag),
            "runtime_ms": int((time.time() - started) * 1000),
        }


PROVIDER = SleepBoundaryProvider()
PROVIDERS = (PROVIDER,)


def register(registry: dict) -> dict:
    return PROVIDER.register(registry)


def infer(*, input: dict, context: dict, provider: Optional[dict] = None) -> dict:
    return PROVIDER.infer(input=input, context=context, provider=provider)
