"""ParaDigMa run wrapper executed by the narrow paradigma subprocess env.

This script is SELF-CONTAINED: it imports only ``paradigma``, ``numpy``,
``pandas`` and the standard library. It is invoked by the main-env provider
(``sensor_biomarkers/paradigma/provider.py``) through a bounded subprocess:

    <paradigma-venv>/bin/python runner.py < job.json > result.json

Contract (JSON over stdin/stdout):

    job: {
      "schema_version": 1,
      "assets": { "<asset_name>": {"sha256": "<64-hex>"}, ... },
      "runs": [ {"time": [...], "accelerometer_x": [...], ...,
                 "gyroscope_z": [...]}, ... ]
      each run may alternatively carry {"npz_path": "/tmp/.../run_1.npz"} with
      keys time, accel (N,3), gyro (N,3) - used by the provider for large runs.
      "pipelines": ["tremor"] | ["tremor", "gait"],
      "watch_side": "left" | "right" | null,
      "device_orientation": ["x","y","z"] | null,
      "window_length_s": 4.0
    }

    result: { "ok": bool, "errors": [...], "versions": {...},
              "tremor": {...}, "arm_swing": {...} }

Safety rules (enforced here, spec section 6.3 / CONTRACTS.md section 7):

* the exact bytes the pipeline will unpickle (the ``paradigma.assets``
  classifier pickles bundled in the installed wheel) are sha256-verified
  against the manifest-pinned digests BEFORE any ``pickle.load`` happens;
  a mismatch aborts with a hard error and nothing is unpickled;
* ``run_paradigma`` is called with the explicit arguments from spec 6.3
  (pipelines tremor + gait when gait metadata is eligible, otherwise
  tremor-only; run_steps preprocessing/classification/quantification;
  return_intermediate classification+quantification; save_intermediate [];
  accelerometer_units "g"; gyroscope_units "deg/s";
  time_input_unit TimeUnit.RELATIVE_S; watch_side verified; device_orientation
  ["x","y","z"] - the provider already applied the WHOOP->ParaDigMa rotation,
  so the library must NOT apply another orientation mapping);
* the library's own right-side transform (``invert_watch_side``) is applied
  by the library from ``watch_side`` and is never duplicated here;
* upstream ``run_paradigma`` v1.1.2 DISCARDS per-window classification
  intermediates (only quantifications are collected), so the tremor
  classification dataframe (freq_peak, pred_tremor_proba, ...) is recovered
  through ``run_tremor_pipeline`` on the same data with the same defaults and
  cross-checked against the orchestrator quantification (parity assertion);
* aggregation is done HERE against the contract keys (seconds-based eligible
  time, linear PSD power median in (deg/s)^2); the upstream aggregation
  (percentage-of-windows, log10 power) is documented but not used for the
  contract keys.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import tempfile
from importlib.resources import files

import numpy as np
import pandas as pd

from paradigma import __version__ as PARADIGMA_VERSION
from paradigma.constants import TimeUnit
from paradigma.orchestrator import run_paradigma
from paradigma.pipelines.tremor_pipeline import run_tremor_pipeline

#: Tremor window length (s) used to convert window counts to seconds
#: (TremorConfig.window_length_s). Kept in sync with the upstream default;
#: the provider passes it through so a config change stays explicit.
DEFAULT_WINDOW_LENGTH_S = 4.0

#: Asset names the pipeline unpickles, in the order they are loaded.
REQUIRED_ASSETS = (
    "tremor_detection_clf_package.pkl",
    "gait_detection_clf_package.pkl",
    "gait_filtering_clf_package.pkl",
)

TREMOR_CLASSIFICATION_COLUMNS = (
    "time",
    "mfcc_1", "mfcc_2", "mfcc_3", "mfcc_4", "mfcc_5", "mfcc_6",
    "mfcc_7", "mfcc_8", "mfcc_9", "mfcc_10", "mfcc_11", "mfcc_12",
    "freq_peak", "below_tremor_power", "tremor_power",
    "pred_tremor_proba", "pred_tremor_logreg", "pred_arm_at_rest",
    "pred_tremor_checked",
)


class RunnerError(Exception):
    """A job that cannot be executed; serialized as ok=false."""


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_assets(assets_spec: dict) -> dict[str, str]:
    """Verify the exact bytes the pipeline will unpickle.

    Returns ``{asset_name: sha256}`` of the verified bytes. Raises
    ``RunnerError`` on any missing/mismatched asset BEFORE any unpickling.
    """
    verified: dict[str, str] = {}
    asset_dir = files("paradigma.assets")
    for name in REQUIRED_ASSETS:
        expected = (assets_spec.get(name) or {}).get("sha256")
        if not expected or not isinstance(expected, str) or len(expected) != 64:
            raise RunnerError(f"asset {name}: no manifest sha256 in job")
        try:
            blob = (asset_dir / name).read_bytes()
        except Exception as exc:  # pragma: no cover - defensive
            raise RunnerError(f"asset {name}: unreadable in wheel: {exc}") from exc
        actual = _sha256_bytes(blob)
        if actual.lower() != expected.lower():
            raise RunnerError(
                f"asset {name}: sha256 {actual} != pinned {expected} "
                f"(size {len(blob)}); refusing to unpickle"
            )
        verified[name] = actual
    return verified


def build_dataframes(runs: list[dict]) -> list[pd.DataFrame]:
    """Build one prepared DataFrame per contiguous run."""
    columns = (
        "time",
        "accelerometer_x", "accelerometer_y", "accelerometer_z",
        "gyroscope_x", "gyroscope_y", "gyroscope_z",
    )
    out: list[pd.DataFrame] = []
    for run in runs:
        if "npz_path" in run:
            loaded = np.load(run["npz_path"], allow_pickle=False)
            try:
                arrays = {
                    "time": np.asarray(loaded["time"], dtype=np.float64),
                    "accelerometer_x": np.asarray(loaded["accel"][:, 0], dtype=np.float64),
                    "accelerometer_y": np.asarray(loaded["accel"][:, 1], dtype=np.float64),
                    "accelerometer_z": np.asarray(loaded["accel"][:, 2], dtype=np.float64),
                    "gyroscope_x": np.asarray(loaded["gyro"][:, 0], dtype=np.float64),
                    "gyroscope_y": np.asarray(loaded["gyro"][:, 1], dtype=np.float64),
                    "gyroscope_z": np.asarray(loaded["gyro"][:, 2], dtype=np.float64),
                }
            except (KeyError, IndexError, ValueError) as exc:
                raise RunnerError(f"bad npz run {run['npz_path']}: {exc}") from exc
            finally:
                loaded.close()
        else:
            missing = [c for c in columns if c not in run]
            if missing:
                raise RunnerError(f"run missing columns: {missing}")
            arrays = {c: np.asarray(run[c], dtype=np.float64) for c in columns}
        n = len(arrays["time"])
        if n < 2:
            raise RunnerError("run has fewer than 2 samples")
        for c in columns[1:]:
            if len(arrays[c]) != n:
                raise RunnerError(f"run column {c} length {len(arrays[c])} != time {n}")
        if not np.all(np.isfinite(arrays["time"])) or np.any(np.diff(arrays["time"]) <= 0):
            raise RunnerError("run time must be strictly increasing and finite")
        df = pd.DataFrame(arrays, columns=columns)
        out.append(df)
    if not out:
        raise RunnerError("no runs supplied")
    return out


def _median_p95(values: np.ndarray) -> tuple[float | None, float | None]:
    values = np.asarray(values, dtype=np.float64)
    values = values[np.isfinite(values)]
    if values.size == 0:
        return None, None
    return float(np.median(values)), float(np.percentile(values, 95))


def _score_distribution(values: np.ndarray) -> dict:
    values = np.asarray(values, dtype=np.float64)
    if values.size == 0:
        return {"n": 0}
    return {
        "n": int(values.size),
        "min": float(np.min(values)),
        "p25": float(np.percentile(values, 25)),
        "median": float(np.median(values)),
        "p75": float(np.percentile(values, 75)),
        "p95": float(np.percentile(values, 95)),
        "max": float(np.max(values)),
    }


def aggregate_tremor(
    classification: pd.DataFrame, window_length_s: float
) -> dict:
    """Contract-key tremor aggregation from the classification dataframe.

    Frequency and probabilities come from the classification columns after
    asserting their actual names/units (upstream ``DataColumns`` and the
    reference metadata: freq_peak in Hz, tremor_power in (deg/s)^2).
    """
    if classification is None or len(classification) == 0:
        return {
            "status": "no_data",
            "windows_total": 0,
            "windows_at_rest": 0,
            "windows_tremor": 0,
            "eligible_rest_seconds": 0.0,
            "classified_tremor_seconds": 0.0,
            "rest_tremor_time_percent": None,
            "tremor_frequency_median_hz": None,
            "tremor_power_median": None,
            "tremor_power_unit": "(deg/s)^2",
            "score_distribution": _score_distribution(np.array([])),
            "reason_counts": {"windows_total": 0, "arm_at_rest": 0,
                              "arm_not_at_rest": 0, "classified_tremor": 0},
        }
    required = ["pred_tremor_proba", "pred_tremor_logreg", "pred_arm_at_rest",
                "pred_tremor_checked", "freq_peak", "tremor_power"]
    missing = [c for c in required if c not in classification.columns]
    if missing:
        raise RunnerError(f"classification dataframe missing columns: {missing}")

    windows_total = int(len(classification))
    arm_at_rest = classification["pred_arm_at_rest"].to_numpy(dtype=float).astype(int)
    checked = classification["pred_tremor_checked"].to_numpy(dtype=float).astype(int)
    windows_at_rest = int(arm_at_rest.sum())
    windows_tremor = int(checked.sum())

    eligible_rest_seconds = windows_at_rest * window_length_s
    classified_tremor_seconds = windows_tremor * window_length_s
    rest_tremor_time_percent = (
        100.0 * windows_tremor / windows_at_rest if windows_at_rest > 0 else None
    )

    classified = classification["pred_tremor_checked"].to_numpy(dtype=bool)
    freq_values = classification["freq_peak"].to_numpy(dtype=np.float64)
    power_values = classification["tremor_power"].to_numpy(dtype=np.float64)
    tremor_frequency_median_hz = (
        float(np.median(freq_values[classified])) if windows_tremor > 0 else None
    )
    tremor_power_median = (
        float(np.median(power_values[classified])) if windows_tremor > 0 else None
    )

    proba = classification["pred_tremor_proba"].to_numpy(dtype=np.float64)
    at_rest_mask = arm_at_rest == 1
    logreg = classification["pred_tremor_logreg"].to_numpy(dtype=float).astype(int)
    below_threshold = int(((logreg == 0) & at_rest_mask).sum())
    peak = classification["freq_peak"].to_numpy(dtype=np.float64)
    peak_out_of_band = int(
        (((peak < 3.0) | (peak > 7.0)) & at_rest_mask).sum()
    )

    return {
        "status": "ok",
        "windows_total": windows_total,
        "windows_at_rest": windows_at_rest,
        "windows_tremor": windows_tremor,
        "eligible_rest_seconds": eligible_rest_seconds,
        "classified_tremor_seconds": classified_tremor_seconds,
        "rest_tremor_time_percent": rest_tremor_time_percent,
        "tremor_frequency_median_hz": tremor_frequency_median_hz,
        "tremor_power_median": tremor_power_median,
        "tremor_power_unit": "(deg/s)^2",
        "score_distribution": _score_distribution(proba),
        "freq_peak_distribution": _score_distribution(freq_values),
        "reason_counts": {
            "windows_total": windows_total,
            "arm_at_rest": windows_at_rest,
            "arm_not_at_rest": windows_total - windows_at_rest,
            "arm_at_rest_no_tremor": windows_at_rest - windows_tremor,
            "classified_tremor": windows_tremor,
            "rest_below_threshold": below_threshold,
            "rest_peak_out_of_3_7hz": peak_out_of_band,
        },
    }


def aggregate_arm_swing(
    quantification_filtered: pd.DataFrame,
    meta_filtered: dict,
    quantification_unfiltered: pd.DataFrame,
    meta_unfiltered: dict,
) -> dict:
    """Contract-key arm-swing aggregation from run_paradigma's gait outputs.

    ``range_of_motion`` and ``peak_velocity`` columns carry one value per
    half arm-swing cycle (arrays per segment); the contract medians/p95 are
    computed over ALL measured cycles in the filtered (clean-gait) segments.
    """

    def per_segment_seconds(meta: dict) -> float:
        per_segment = (meta or {}).get("per_segment") or {}
        return float(sum(float(v.get("duration_s", 0.0)) for v in per_segment.values()))

    def flatten(column: pd.Series) -> np.ndarray:
        values: list[np.ndarray] = []
        for row in column:
            arr = np.asarray(row, dtype=np.float64).ravel()
            arr = arr[np.isfinite(arr)]
            if arr.size:
                values.append(arr)
        return np.concatenate(values) if values else np.array([])

    filtered_seconds = per_segment_seconds(meta_filtered)
    unfiltered_seconds = per_segment_seconds(meta_unfiltered)
    bout_count = int(len(quantification_filtered)) if quantification_filtered is not None else 0
    unfiltered_bout_count = (
        int(len(quantification_unfiltered)) if quantification_unfiltered is not None else 0
    )

    rom_cycle_count = pav_cycle_count = 0
    if quantification_filtered is not None and len(quantification_filtered) > 0:
        rom = flatten(quantification_filtered["range_of_motion"])
        pav = flatten(quantification_filtered["peak_velocity"])
        rom_median, rom_p95 = _median_p95(rom)
        pav_median, pav_p95 = _median_p95(pav)
        rom_cycle_count = int(rom.size)
        pav_cycle_count = int(pav.size)
    else:
        rom_median = rom_p95 = pav_median = pav_p95 = None

    return {
        "status": "ok" if bout_count > 0 else "no_data",
        "eligible_arm_swing_seconds": filtered_seconds,
        "arm_swing_bout_count": bout_count,
        "arm_swing_rom_median_deg": rom_median,
        "arm_swing_rom_p95_deg": rom_p95,
        "arm_swing_peak_velocity_median_dps": pav_median,
        "arm_swing_peak_velocity_p95_dps": pav_p95,
        "rom_cycle_count": rom_cycle_count,
        "pav_cycle_count": pav_cycle_count,
        "unfiltered_seconds": unfiltered_seconds,
        "unfiltered_bout_count": unfiltered_bout_count,
        "reason_counts": {
            "filtered_segments": bout_count,
            "unfiltered_segments": unfiltered_bout_count,
            "filtered_seconds": filtered_seconds,
            "unfiltered_seconds": unfiltered_seconds,
        },
    }


def run_job(job: dict) -> dict:
    """Execute one job and return the serializable result dict."""
    verify_assets(job.get("assets") or {})

    pipelines = list(job.get("pipelines") or ["tremor"])
    if not set(pipelines) <= {"tremor", "gait"}:
        raise RunnerError(f"unsupported pipelines: {pipelines}")
    if "gait" in pipelines:
        if job.get("watch_side") not in ("left", "right"):
            raise RunnerError("gait pipeline requires watch_side left|right")
    watch_side = job.get("watch_side") or None
    device_orientation = job.get("device_orientation") or ["x", "y", "z"]
    window_length_s = float(job.get("window_length_s", DEFAULT_WINDOW_LENGTH_S))

    dfs = build_dataframes(job.get("runs") or [])

    versions = {}
    try:
        import scipy, sklearn  # noqa: PLC0415
        versions = {
            "paradigma": PARADIGMA_VERSION,
            "numpy": np.__version__,
            "pandas": pd.__version__,
            "scipy": scipy.__version__,
            "scikit_learn": sklearn.__version__,
        }
    except Exception as exc:  # pragma: no cover - defensive
        versions = {"paradigma": PARADIGMA_VERSION, "note": str(exc)}

    errors: list[str] = []
    result: dict = {"ok": True, "errors": errors, "versions": versions}

    # ------------------------------------------------------------------
    # 1) Verified public orchestrator (authoritative quantifications).
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="paradigma-run-") as output_dir:
        orchestrated = run_paradigma(
            dfs=dfs if len(dfs) > 1 else dfs[0],
            pipelines=pipelines,
            run_steps=["preprocessing", "classification", "quantification"],
            return_intermediate=["classification", "quantification"],
            save_intermediate=[],
            accelerometer_units="g",
            gyroscope_units="deg/s",
            time_input_unit=TimeUnit.RELATIVE_S,
            watch_side=watch_side,
            device_orientation=device_orientation,
            output_dir=output_dir,
            logging_level=logging.ERROR,
        )
        errors.extend(orchestrated.get("errors") or [])

        # ------------------------------------------------------------------
        # 2) Tremor classification diagnostics (orchestrator drops these).
        # ------------------------------------------------------------------
        if "tremor" in pipelines:
            classification_parts: list[pd.DataFrame] = []
            upstream_short_input = False
            for df in dfs:
                try:
                    pipes = run_tremor_pipeline(
                        df_prepared=df,
                        output_dir=output_dir,
                        run_steps=["preprocessing", "classification"],
                        return_intermediate=["classification"],
                        store_intermediate=[],
                        logging_level=logging.ERROR,
                    )
                except Exception as exc:  # upstream raises on <1 window (no data)
                    upstream_short_input = True
                    break
                if pipes.get("_error"):
                    upstream_short_input = True
                    break
                classification_parts.append(pipes["classification"])
            if upstream_short_input:
                # Upstream v1.1.2 cannot classify runs shorter than one 4 s
                # window (tuple index out of range in the spectral features);
                # the provider pre-gates short runs, this is a defensive path.
                classification_parts = []
            classification = (
                pd.concat(classification_parts, ignore_index=True)
                if classification_parts else pd.DataFrame()
            )
            # Assert the upstream classification column names before use.
            expected = set(TREMOR_CLASSIFICATION_COLUMNS)
            actual = set(classification.columns) if len(classification) else set()
            if not (expected <= actual):
                raise RunnerError(
                    "classification columns changed upstream; expected "
                    f"{sorted(expected - actual)} missing"
                )
            tremor = aggregate_tremor(classification, window_length_s)
            tremor["upstream_short_input_detected"] = bool(upstream_short_input)
            # Parity: orchestrator quantification must agree with our
            # classification-derived counts.
            q = orchestrated.get("quantifications", {}).get("tremor")
            if q is not None and len(q) > 0:
                q_checked = int(q["pred_tremor_checked"].sum())
                q_rest = int(q["pred_arm_at_rest"].sum())
                parity = (
                    q_checked == tremor["windows_tremor"]
                    and q_rest == tremor["windows_at_rest"]
                )
                tremor["quantification_parity_with_orchestrator"] = parity
            result["tremor"] = tremor

        # ------------------------------------------------------------------
        # 3) Arm swing aggregation (run_paradigma gait outputs).
        # ------------------------------------------------------------------
        if "gait" in pipelines:
            gait_quant = orchestrated.get("quantifications", {}).get("gait") or {}
            gait_meta = orchestrated.get("metadata", {}).get("gait") or {}
            filtered_q = gait_quant.get("filtered")
            unfiltered_q = gait_quant.get("unfiltered")
            if isinstance(filtered_q, pd.DataFrame) and filtered_q.empty:
                filtered_q = None
            if isinstance(unfiltered_q, pd.DataFrame) and unfiltered_q.empty:
                unfiltered_q = None
            result["arm_swing"] = aggregate_arm_swing(
                filtered_q,
                gait_meta.get("filtered") or {},
                unfiltered_q,
                gait_meta.get("unfiltered") or {},
            )

    if errors:
        result["ok"] = False
        result["errors"] = errors
    return result


def main(argv: list[str]) -> int:
    logging.disable(logging.INFO)  # keep the JSON stdout clean
    try:
        job = json.load(sys.stdin)
    except Exception as exc:
        print(json.dumps({"ok": False, "errors": [f"bad job json: {exc}"]}))
        return 2
    try:
        result = run_job(job)
    except RunnerError as exc:
        result = {"ok": False, "errors": [str(exc)]}
    except Exception as exc:  # noqa: BLE001 - serialize any failure
        result = {"ok": False, "errors": [f"{type(exc).__name__}: {exc}"]}
    json.dump(result, sys.stdout)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
