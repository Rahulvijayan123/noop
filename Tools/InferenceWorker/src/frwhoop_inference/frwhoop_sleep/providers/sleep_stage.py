"""Sleep-stage candidate provider: SleepECG ``wrn-gru-mesa``.

Provider id ``sleepecg.wrn-gru-mesa.v1``.  Metric ``sleep_stage``.  Retrospective.

Label space
-----------
Three classes, ``wake/rem/nrem``.  This provider never emits ``light`` or ``deep`` and never
writes the four-stage canonical fields; ``label_space`` travels with every result so a
consumer cannot mistake it for the display contract (spec section 5).

Adapter responsibilities (measured; see ``probes/sleepecg_probe_evidence.json``)

1. ``heartbeat_times`` are built from **cumulative RR seconds**, never from averaged heart
   rate and never by concatenating sparse RR batches across a gap >= 2 min (runs are staged
   separately and the gap epochs stay unscored).
2. The checkpoint is loaded from the bundled ``wrn-gru-mesa.zip`` with a sha256-verified
   artifact and standalone Keras, because ``sleepecg.load_classifier`` requires TensorFlow
   (``from tensorflow import keras``) which is not installable on the arm64 development host.
   The loader and backend actually used are recorded in the response.
3. ``_nanpsd`` raises ``ValueError`` instead of withholding when no analysis window is free of
   out-of-range RR intervals, so the adapter counts NaN-free windows first and withholds with
   a machine-readable reason.  A short record (fewer than one analysis window) is withheld too.
4. ``argmax == 0`` is SleepECG's ``UNDEFINED`` class and is never a stage: those epochs are
   returned as unscored.  Epochs whose feature row is entirely non-finite are unscored too.
5. Softmax scores are returned as ``raw_scores`` with ``calibrated: false`` and no calibration
   claim; accuracy stays ``unverified_accuracy`` (spec section 8).
"""

from __future__ import annotations

import hashlib
import os
import time
import zipfile
from typing import Any, Optional, Sequence
from zoneinfo import ZoneInfo

import numpy as np

from ..timebase import (
    GAP_MIN_SECONDS_DEFAULT,
    InputError,
    UTC,
    json_safe,
    local_datetime,
    complement_intervals,
    mask_to_intervals,
    parse_ts,
    parse_zone,
    sha256_payload,
)

PROVIDER_ID = "sleepecg.wrn-gru-mesa.v1"
METRIC = "sleep_stage"
ADAPTER_VERSION = "sleepecg.wrn-gru-mesa.v1/1.0.0"
PREPROCESSING_VERSION = "rr-cumsum-runs/1.0.0"
CONFIG_VERSION = "sleepecg-wrn-gru-mesa-defaults/1.0.0"
SLEEPECG_VERSION = "0.5.9"
CHECKPOINT = "wrn-gru-mesa"
CHECKPOINT_ZIP_SHA256 = "5622a858c855b0090e1fbcbdc35334ea459707c830eae1a26a4375e33091e869"
MODEL_KERAS_SHA256 = "0b392209aff8d72383de4d1fdb1e41e85ab060b65a3facb2835e262aa0f6ffd8"
STAGES_MODE = "wake-rem-nrem"
LABEL_SPACE = "wake/rem/nrem"
#: index -> label, for stages_mode 'wake-rem-nrem' (0 is UNDEFINED and never a stage)
CLASS_ORDER = ["undefined", "nrem", "rem", "wake"]
MODE = "retrospective"
ACCURACY_STATUS = "unverified_accuracy"
REQUIRED_SIGNALS = ["rr_intervals"]
EPOCH_SECONDS = 30

DEFAULT_CONFIG: dict[str, Any] = {
    "classifier_zip": None,          # None -> <sleepecg>/classifiers/wrn-gru-mesa.zip
    "classifier_zip_sha256": CHECKPOINT_ZIP_SHA256,
    "model_sha256": MODEL_KERAS_SHA256,
    "keras_backend": "torch",
    "loader_preference": "auto",     # 'auto' | 'keras_direct' | 'tensorflow'
    "epoch_seconds": EPOCH_SECONDS,
    "gap_min_seconds": GAP_MIN_SECONDS_DEFAULT,
    "min_run_seconds": 1800,
    "min_staged_epochs": 10,
    "max_ts_suspect_fraction": 0.1,
    "min_coverage_fraction": 0.5,
    "rri_min_seconds": 0.3,
    "rri_max_seconds": 2.0,
    "rri_resample_hz": 4.0,
    "max_nans": 0.5,
    "lookback_seconds": 120,
    "lookforward_seconds": 150,
    "max_rri_reject_fraction": 0.5,
}

_MODEL_CACHE: dict[str, Any] = {}


def _read_rr(payload) -> list[tuple[int, float, int, int, int]]:
    """Accept [[ts, rr_ms, seq, ord, ts_suspect], ...] or a list of dicts."""
    rr = payload.get("rr", payload.get("rr_intervals"))
    if rr is None:
        raise InputError("missing_rr", "input.rr is required")
    if not isinstance(rr, (list, tuple)):
        raise InputError("invalid_rr", "input.rr must be a list")
    rows: list[tuple[int, float, int, int, int]] = []
    for item in rr:
        if isinstance(item, dict):
            ts_raw = item.get("ts", item.get("ts_utc"))
            ms_raw = item.get("rr_ms", item.get("rrMs"))
            seq = int(item.get("seq", 0) or 0)
            order = int(item.get("ord", item.get("order", 0)) or 0)
            suspect = int(item.get("ts_suspect", item.get("tsSuspect", 0)) or 0)
        elif isinstance(item, (list, tuple)) and len(item) >= 2:
            ts_raw, ms_raw = item[0], item[1]
            seq = int(item[2]) if len(item) > 2 else 0
            order = int(item[3]) if len(item) > 3 else 0
            suspect = int(item[4]) if len(item) > 4 else 0
        else:
            raise InputError("invalid_rr", "each rr row must be [ts, rr_ms, seq, ord, ts_suspect] or a dict")
        ts = parse_ts(ts_raw, "rr.ts")
        try:
            ms = float(ms_raw)
        except (TypeError, ValueError):
            raise InputError("invalid_rr", "rr.rr_ms must be numeric: %r" % (ms_raw,))
        if not np.isfinite(ms):
            raise InputError("invalid_rr", "rr.rr_ms must be finite")
        rows.append((ts, ms, seq, order, suspect))
    rows.sort(key=lambda r: (r[0], r[2], r[3]))
    return rows


def _split_runs(rows: Sequence[tuple[int, float, int, int, int]], gap_min_seconds: int):
    """Split the ordered RR rows into contiguous runs at a gap >= ``gap_min_seconds``."""
    runs: list[list[tuple[int, float, int, int, int]]] = []
    current: list[tuple[int, float, int, int, int]] = []
    prev_ts: Optional[int] = None
    for row in rows:
        if prev_ts is not None and row[0] - prev_ts >= gap_min_seconds:
            if current:
                runs.append(current)
            current = []
        current.append(row)
        prev_ts = row[0]
    if current:
        runs.append(current)
    return runs


def _nan_free_windows(heartbeat_times: np.ndarray, config: dict) -> dict:
    """Replicate the analysis-window NaN accounting that ``_nanpsd`` consumes.

    ``sleepecg/feature_extraction.py:170`` raises a shape-mismatch ValueError when the
    NaN-free row selection is empty, so the adapter has to know the count before it calls in.
    """
    from numpy.lib.stride_tricks import sliding_window_view
    from scipy.interpolate import interp1d

    hb = np.asarray(heartbeat_times, dtype=float)
    lookback = int(config["lookback_seconds"])
    lookforward = int(config["lookforward_seconds"])
    fs = float(config["rri_resample_hz"])
    epoch_seconds = int(config["epoch_seconds"])
    out: dict[str, Any] = {"n_beats": int(hb.size)}
    if hb.size < 2:
        out.update({"windows": 0, "nan_free_windows": 0, "epochs": 0, "rri_nan_fraction": 1.0})
        return out
    rri = np.diff(hb)
    rejected = (rri < float(config["rri_min_seconds"])) | (rri > float(config["rri_max_seconds"]))
    rri = np.where(rejected, np.nan, rri)
    rri_times = hb[1:]
    num_stages = int(hb[-1] // epoch_seconds)
    out["epochs"] = int(num_stages)
    out["rri_nan_fraction"] = round(float(np.mean(~np.isfinite(rri))), 5)
    out["n_rri_rejected"] = int(rejected.sum())
    if num_stages <= 0:
        out.update({"windows": 0, "nan_free_windows": 0})
        return out
    stage_times = np.arange(num_stages) * epoch_seconds
    interp_times = np.arange(stage_times[0] - lookback, stage_times[-1] + lookforward, 1.0 / fs)
    interp = interp1d(rri_times, rri, bounds_error=False)(interp_times)
    window_size = int((lookback + lookforward) * fs)
    if interp.size < window_size:
        out.update({"windows": 0, "nan_free_windows": 0})
        return out
    windows = sliding_window_view(interp, window_size)[:: int(fs * epoch_seconds)]
    nan_fraction = np.mean(np.isnan(windows), axis=1)
    out.update({
        "windows": int(windows.shape[0]),
        "nan_free_windows": int((nan_fraction == 0).sum()),
        "windows_below_max_nans": int((nan_fraction <= float(config["max_nans"])).sum()),
        "min_nan_fraction": round(float(nan_fraction.min()), 5),
    })
    return out


def _load_classifier(config: dict) -> tuple[Any, dict]:
    """Load the bundled classifier without the TensorFlow-only ``load_classifier`` path."""
    import sleepecg

    zip_path = config["classifier_zip"] or os.path.join(
        os.path.dirname(sleepecg.__file__), "classifiers", "%s.zip" % CHECKPOINT)
    provenance: dict[str, Any] = {"checkpoint": CHECKPOINT, "zip_path": zip_path}
    if not os.path.exists(zip_path):
        raise InputError("checkpoint_missing", "classifier archive not found: %s" % zip_path)
    with open(zip_path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    provenance["zip_sha256"] = digest
    if config["classifier_zip_sha256"] and digest != config["classifier_zip_sha256"]:
        raise InputError("artifact_mismatch", "classifier archive sha256 %s != pinned %s"
                         % (digest, config["classifier_zip_sha256"]))
    cached = _MODEL_CACHE.get(digest)
    if cached is not None:
        provenance.update(cached["provenance"])
        # The inner-model pin must be enforced on the CACHED path too: otherwise a caller who
        # pins a different model_sha256 gets the previously loaded model silently (the check
        # below would never run).
        cached_model_sha = cached["provenance"].get("model_sha256")
        if config["model_sha256"] and cached_model_sha and cached_model_sha != config["model_sha256"]:
            raise InputError("artifact_mismatch", "classifier.keras sha256 %s != pinned %s"
                             % (cached_model_sha, config["model_sha256"]))
        return cached["model"], provenance

    loader_preference = config["loader_preference"]
    use_tensorflow = loader_preference == "tensorflow" or (
        loader_preference == "auto" and _tensorflow_available())
    if use_tensorflow:
        classifier = sleepecg.load_classifier(CHECKPOINT, "SleepECG")
        provenance.update({"loader": "sleepecg.load_classifier", "backend": "tensorflow"})
        _MODEL_CACHE[digest] = {"model": classifier, "provenance": provenance}
        return classifier, provenance

    if loader_preference == "tensorflow":
        raise InputError("dependency_missing", "loader_preference=tensorflow but tensorflow is absent")
    backend = os.environ.get("KERAS_BACKEND") or config["keras_backend"]
    os.environ["KERAS_BACKEND"] = backend
    import keras
    import yaml

    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        if "info.yml" not in names or "classifier.keras" not in names:
            raise InputError("artifact_mismatch", "unexpected archive members: %s" % names)
        import tempfile

        tmpdir = tempfile.mkdtemp(prefix="frwhoop-sleepecg-")
        archive.extractall(tmpdir)
    model_path = os.path.join(tmpdir, "classifier.keras")
    with open(model_path, "rb") as handle:
        model_digest = hashlib.sha256(handle.read()).hexdigest()
    provenance["model_sha256"] = model_digest
    if config["model_sha256"] and model_digest != config["model_sha256"]:
        raise InputError("artifact_mismatch", "classifier.keras sha256 %s != pinned %s"
                         % (model_digest, config["model_sha256"]))
    with open(os.path.join(tmpdir, "info.yml")) as handle:
        info = yaml.safe_load(handle)
    model = keras.models.load_model(model_path)
    classifier = {
        "model": model,
        "stages_mode": info["stages_mode"],
        "feature_extraction_params": info["feature_extraction_params"],
        "mask_value": info.get("mask_value"),
        "model_type": info["model_type"],
    }
    provenance.update({
        "loader": "keras_direct",
        "backend": keras.backend.backend(),
        "keras_version": keras.__version__,
        "classifier_info": info,
        "sleepecg_version": sleepecg.__version__,
    })
    _MODEL_CACHE[digest] = {"model": classifier, "provenance": provenance}
    return classifier, provenance


def _tensorflow_available() -> bool:
    import importlib.util

    return importlib.util.find_spec("tensorflow") is not None


class SleepStageProvider:
    """SleepECG ``wrn-gru-mesa`` three-class sleep-stage candidate provider."""

    provider_id = PROVIDER_ID
    metric = METRIC
    mode = MODE
    required_signals = REQUIRED_SIGNALS
    label_space = LABEL_SPACE

    def __init__(self, *, config: Optional[dict] = None):
        self.config_defaults = dict(DEFAULT_CONFIG)
        if config:
            unknown = sorted(set(config) - set(DEFAULT_CONFIG))
            if unknown:
                raise InputError("unknown_config", "unknown config key(s): %s" % ", ".join(unknown))
            self.config_defaults.update(config)

    # -- server surface --------------------------------------------------------
    def manifest(self) -> dict:
        return {
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": {
                "adapter": ADAPTER_VERSION,
                "preprocessing": PREPROCESSING_VERSION,
                "dependency": "sleepecg==%s;keras>=3" % SLEEPECG_VERSION,
                "config": CONFIG_VERSION,
                "model": "%s@%s" % (CHECKPOINT, CHECKPOINT_ZIP_SHA256[:12]),
            },
            "required_signals": list(REQUIRED_SIGNALS),
            "label_space": LABEL_SPACE,
            "stages_mode": STAGES_MODE,
            "retrospective_or_causal": MODE,
            "accuracy_status": ACCURACY_STATUS,
            "eligibility": {
                "state": "shadow_eligible",
                "reason": None,
                "promotion_blocked_by": ["unverified_accuracy", "no_finite_feature_window_on_real_data"],
            },
            "license": {"spdx": "BSD-3-Clause", "note": "SleepECG source headers, (c) SleepECG developers"},
            "artifacts": {
                "wrn-gru-mesa.zip": {"sha256": CHECKPOINT_ZIP_SHA256, "bytes": 59765},
                "classifier.keras": {"sha256": MODEL_KERAS_SHA256, "bytes": 113583},
            },
            "defaults": {"config": self.config_defaults},
        }

    def readiness(self) -> dict:
        # _load_classifier pins KERAS_BACKEND before importing keras: importing keras without a
        # backend selected raises ModuleNotFoundError('tensorflow') on this host.
        try:
            _, provenance = _load_classifier(self.config_defaults)
        except InputError as exc:
            return {"ready": False, "version": ADAPTER_VERSION,
                    "reason": "%s: %s" % (exc.code, exc)}
        except Exception as exc:
            return {"ready": False, "version": ADAPTER_VERSION,
                    "reason": "dependency_missing: %s: %s" % (type(exc).__name__, exc)}
        return {"ready": True, "version": ADAPTER_VERSION, "reason": None,
                "provenance": {k: provenance[k] for k in
                               ("loader", "backend", "zip_sha256", "model_sha256")
                               if k in provenance}}

    def register(self, registry: dict) -> dict:
        registry[METRIC] = self
        return registry

    # -- inference -------------------------------------------------------------
    def infer(self, *, input: dict, context: dict, provider: Optional[dict] = None) -> dict:
        started = time.time()
        provider = provider or {}
        input = input or {}
        context = context or {}
        try:
            expected_id = provider.get("provider_id")
            if expected_id and expected_id != PROVIDER_ID:
                return self._error("provider_id_mismatch", "requested %r, this provider is %r"
                                   % (expected_id, PROVIDER_ID), started)
            config = dict(self.config_defaults)
            if input.get("config"):
                unknown = sorted(set(input["config"]) - set(DEFAULT_CONFIG))
                if unknown:
                    raise InputError("unknown_config", "unknown config key(s): %s" % ", ".join(unknown))
                config.update(input["config"])
            return self._infer(input, context, config, started)
        except InputError as exc:
            return self._error(exc.code, str(exc), started, status="error")
        except Exception as exc:
            import traceback
            return self._error("provider_error", "%s: %s" % (type(exc).__name__, exc), started,
                               status="error",
                               traceback=traceback.format_exc().strip().splitlines()[-3:])

    def _error(self, detail: str, message: str, started: float, *, status: str = "error",
               traceback: Optional[list] = None) -> dict:
        return {
            "status": status,
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": {"adapter": ADAPTER_VERSION, "preprocessing": PREPROCESSING_VERSION,
                         "dependency": "sleepecg==%s" % SLEEPECG_VERSION, "config": CONFIG_VERSION,
                         "model": "%s@%s" % (CHECKPOINT, CHECKPOINT_ZIP_SHA256[:12])},
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

    def _withheld(self, reason: str, detail: str, *, versions, context, interval, input_sha,
                  diagnostics, coverage, started) -> dict:
        return {
            "status": "withheld",
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": versions,
            "input": {"sha256": input_sha, "refs": {"context": context}},
            "result": None,
            "interval": interval,
            "final_or_provisional": "provisional",
            "coverage": coverage,
            "raw_scores": None,
            "diagnostics": json_safe(dict(diagnostics, reason_detail=detail)),
            "runtime_ms": int((time.time() - started) * 1000),
            "withheld_reason": reason,
        }

    def _infer(self, payload: dict, context: dict, config: dict, started: float) -> dict:
        zone = parse_zone(context.get("iana_timezone"))
        rows = _read_rr(payload)
        if not rows:
            raise InputError("missing_rr", "input.rr is empty")

        window = payload.get("window") or {}
        window_start = parse_ts(window.get("start_utc", context.get("interval_start_utc")),
                                "window.start_utc")
        window_end = parse_ts(window.get("end_utc", context.get("interval_end_utc")),
                              "window.end_utc")
        if window_end <= window_start:
            raise InputError("invalid_interval", "window.end_utc must be after window.start_utc")

        rows = [r for r in rows if window_start <= r[0] < window_end]
        if not rows:
            raise InputError("no_rr_in_window", "no RR rows fall inside the requested window")

        gap_min_seconds = int(config["gap_min_seconds"])
        runs = _split_runs(rows, gap_min_seconds)
        run_info = []
        staged_runs = []
        for run in runs:
            span = run[-1][0] - run[0][0]
            suspect_fraction = float(np.mean([r[4] for r in run])) if run else 0.0
            entry = {"rows": len(run), "start_utc": int(run[0][0]), "end_utc": int(run[-1][0]),
                     "seconds": int(span), "ts_suspect_fraction": round(suspect_fraction, 4)}
            if span < int(config["min_run_seconds"]):
                entry["skipped"] = "run_shorter_than_min_run_seconds"
            elif suspect_fraction > float(config["max_ts_suspect_fraction"]):
                entry["skipped"] = "ts_suspect_fraction_too_high"
            else:
                staged_runs.append(run)
            run_info.append(entry)

        input_sha = sha256_payload({
            "provider_id": PROVIDER_ID, "adapter": ADAPTER_VERSION,
            "preprocessing": PREPROCESSING_VERSION, "config": CONFIG_VERSION,
            "config_values": config, "user_id": context.get("user_id"),
            "device_id": context.get("device_id"), "iana_timezone": context.get("iana_timezone"),
            "window": [window_start, window_end], "rr": rows,
            "age": payload.get("age"), "gender": payload.get("gender"),
        })
        interval = {"start_utc": window_start, "end_utc": window_end,
                    "analysis_day": local_datetime(window_end, zone).date().isoformat(),
                    "iana_timezone": context.get("iana_timezone")}
        versions = {
            "adapter": ADAPTER_VERSION,
            "preprocessing": PREPROCESSING_VERSION,
            "dependency": "sleepecg==%s;keras>=3" % SLEEPECG_VERSION,
            "config": CONFIG_VERSION,
            "model": "%s@%s" % (CHECKPOINT, CHECKPOINT_ZIP_SHA256[:12]),
        }
        coverage: dict[str, Any] = {
            "window_seconds": int(window_end - window_start),
            "rr_rows_in_window": len(rows),
            "runs": len(runs),
            "runs_staged": len(staged_runs),
        }
        diag: dict[str, Any] = {
            "analysis_day": interval["analysis_day"],
            "iana_timezone": context.get("iana_timezone"),
            "config": config,
            "runs": run_info,
            "gap_min_seconds": gap_min_seconds,
            "accuracy_status": ACCURACY_STATUS,
            "label_space": LABEL_SPACE,
            "stages_mode": STAGES_MODE,
            "class_order": CLASS_ORDER,
            "notes": [
                "three-class wake/rem/nrem only; never the four-stage display fields",
                "softmax scores are uncalibrated and are returned as raw_scores only",
                "unscored epochs are retained as missing and are never forced into a class",
            ],
        }

        if not staged_runs:
            return self._withheld("insufficient_coverage", "insufficient_consecutive_beats",
                                  versions=versions, context={"window": interval},
                                  interval=interval, input_sha=input_sha, diagnostics=diag,
                                  coverage=coverage, started=started)

        classifier, provenance = _load_classifier(config)
        diag["loader_provenance"] = {k: v for k, v in provenance.items() if k != "classifier_info"}
        diag["classifier_info"] = provenance.get("classifier_info")

        params = classifier["feature_extraction_params"]
        mask_value = classifier["mask_value"]
        model = classifier["model"]
        epoch_seconds = int(config["epoch_seconds"])
        min_epochs = int(config["min_staged_epochs"])

        staged: list[dict] = []
        unscored: list[dict] = []
        attempted: list[tuple[int, int]] = []
        precheck_summary = []
        for index, run in enumerate(staged_runs):
            entry = self._stage_run(run, index, window_start, zone, config, params, mask_value,
                                    model, epoch_seconds, min_epochs,
                                    age=payload.get("age"), gender=payload.get("gender"))
            precheck_summary.append(entry["precheck"])
            diag["run_%d" % index] = entry["diagnostics"]
            staged.extend(entry["epochs"])
            unscored.extend(entry["unscored"])
            attempted.extend(entry["attempted"])

        # Epochs that no run reached (a wear gap, a short run, or a run excluded for suspect
        # timestamps) stay MISSING: they are reported as unscored, never forced into a class.
        for start, end in complement_intervals(attempted, window_start, window_end):
            unscored.append({"start_utc": int(start), "end_utc": int(end),
                             "reason": "no_rr", "seconds": int(end - start)})

        diag["precheck"] = precheck_summary
        staged.sort(key=lambda e: e["start_utc"])
        unscored.sort(key=lambda e: e["start_utc"])
        if not staged:
            detail = ("no_finite_feature_window"
                      if all(p.get("nan_free_windows", 0) == 0 for p in precheck_summary)
                      else "no_staged_epochs")
            return self._withheld("insufficient_coverage", detail, versions=versions,
                                  context={"window": interval}, interval=interval,
                                  input_sha=input_sha, diagnostics=diag, coverage=coverage,
                                  started=started)

        coverage.update({
            "staged_epochs": len(staged),
            "unscored_epochs": len(unscored),
            "staged_seconds": len(staged) * epoch_seconds,
            "coverage_fraction": round(len(staged) * epoch_seconds
                                       / float(window_end - window_start), 5),
        })
        per_class = {name: 0 for name in CLASS_ORDER}
        for epoch in staged:
            per_class[epoch["label"]] += 1
        diag["per_class_epoch_counts"] = per_class
        diag["epoch_seconds"] = epoch_seconds

        if coverage["coverage_fraction"] < float(config["min_coverage_fraction"]):
            return self._withheld("insufficient_coverage", "low_staged_coverage", versions=versions,
                                  context={"window": interval}, interval=interval,
                                  input_sha=input_sha, diagnostics=diag, coverage=coverage,
                                  started=started)

        merged = self._merge_epochs(staged, epoch_seconds)
        scores = [epoch["_scores"] for epoch in staged]
        for epoch in staged:
            epoch.pop("_scores", None)
        raw_scores = {
            "per_epoch": [[round(float(x), 6) for x in row] for row in scores],
            "epoch_seconds": epoch_seconds,
            "first_epoch_start_utc": staged[0]["start_utc"],
            "class_order": CLASS_ORDER,
            "calibrated": False,
            "note": "uncalibrated softmax output; not a validated probability",
        }
        diag["probability_rowsum_min"] = round(float(min(sum(r) for r in scores)), 6)
        diag["probability_rowsum_max"] = round(float(max(sum(r) for r in scores)), 6)
        diag["mean_class_score"] = [round(float(np.mean([r[i] for r in scores])), 5) for i in range(4)]
        diag["mean_max_score"] = round(float(np.mean([max(r) for r in scores])), 5)
        diag["argmax_undefined_epochs"] = sum(1 for epoch in unscored
                                              if epoch.get("reason") == "undefined_class")

        return {
            "status": "ok",
            "metric": METRIC,
            "provider_id": PROVIDER_ID,
            "versions": versions,
            "input": {"sha256": input_sha,
                      "refs": {"context": {"user_id": context.get("user_id"),
                                           "device_id": context.get("device_id"),
                                           "interval_start_utc": window_start,
                                           "interval_end_utc": window_end,
                                           "iana_timezone": context.get("iana_timezone")},
                               "rr_rows": len(rows)}},
            "result": {
                "stages": merged,
                "label_space": LABEL_SPACE,
                "unscored": unscored,
                "value": None,
                "unit": None,
            },
            "interval": interval,
            "final_or_provisional": "final",
            "coverage": coverage,
            "raw_scores": raw_scores,
            "diagnostics": json_safe(diag),
            "runtime_ms": int((time.time() - started) * 1000),
        }

    # -- per-run staging -------------------------------------------------------
    def _stage_run(self, run, index: int, window_start: int, zone: ZoneInfo, config: dict,
                   params: dict, mask_value, model, epoch_seconds: int, min_epochs: int,
                   age=None, gender=None) -> dict:
        from sleepecg.io.sleep_readers import SleepRecord, SubjectData
        from sleepecg import extract_features

        rr_seconds = np.array([r[1] / 1000.0 for r in run], dtype=float)
        cumulative = np.cumsum(rr_seconds)
        # The first row's timestamp is the END of its RR interval, so the record starts one
        # interval earlier; the epoch grid is then aligned to the UTC 30 s grid.
        run_start_utc = float(run[0][0]) - rr_seconds[0]
        record_start_utc = int(run_start_utc // epoch_seconds) * epoch_seconds
        offset = run_start_utc - record_start_utc
        heartbeat_times = cumulative + offset

        diagnostics: dict[str, Any] = {
            "run_index": index,
            "n_rr": len(run),
            "record_start_utc": record_start_utc,
            "record_start_local": local_datetime(record_start_utc, zone).isoformat(),
            "first_rr_utc": int(run[0][0]),
            "last_rr_utc": int(run[-1][0]),
            "heartbeat_times_last_s": round(float(heartbeat_times[-1]), 3),
            "offset_within_epoch_s": round(float(offset), 3),
        }
        precheck = _nan_free_windows(heartbeat_times, config)
        diagnostics["precheck"] = precheck

        scored = np.isfinite(np.diff(heartbeat_times))
        reject_fraction = float(np.mean(~scored)) if scored.size else 1.0
        diagnostics["rri_reject_fraction"] = round(float(precheck.get("rri_nan_fraction", 1.0)), 5)
        if precheck.get("epochs", 0) < min_epochs:
            return {"precheck": precheck, "diagnostics": dict(diagnostics, skipped="too_few_epochs"),
                    "epochs": [], "unscored": [], "attempted": []}
        if precheck.get("nan_free_windows", 0) == 0:
            return {"precheck": precheck,
                    "diagnostics": dict(diagnostics, skipped="no_finite_feature_window"),
                    "epochs": [], "unscored": [], "attempted": []}
        if float(precheck.get("rri_nan_fraction", 1.0)) > float(config["max_rri_reject_fraction"]):
            return {"precheck": precheck,
                    "diagnostics": dict(diagnostics, skipped="rr_artifact_fraction"),
                    "epochs": [], "unscored": [], "attempted": []}

        # SleepECG takes only a time of day for the recording start, so the local time of the
        # record start is used; the date and zone travel in the response provenance.
        start_time = local_datetime(record_start_utc, zone).time()

        record = SleepRecord(
            heartbeat_times=heartbeat_times,
            recording_start_time=start_time,
            subject_data=SubjectData(age=age, gender=gender),
        )
        epochs_out: list[dict] = []
        unscored: list[dict] = []
        try:
            features, _stages, feature_ids = extract_features(records=[record], **params)
            matrix = features[0]
            matrix = np.asarray(matrix, dtype=float)
            finite_rows = np.isfinite(matrix).any(axis=1)
            masked = matrix.copy()
            masked[~np.isfinite(masked)] = mask_value
            probabilities = np.asarray(model.predict(masked[np.newaxis, ...], verbose=0)[0])
            labels = probabilities.argmax(-1)
        except Exception as exc:
            import traceback
            diagnostics["error"] = "%s: %s" % (type(exc).__name__, exc)
            diagnostics["traceback_tail"] = traceback.format_exc().strip().splitlines()[-3:]
            return {"precheck": precheck, "diagnostics": dict(diagnostics, skipped="provider_error"),
                    "epochs": [], "unscored": [], "attempted": []}

        n_epochs = int(min(len(labels), precheck.get("epochs", len(labels))))
        for i in range(n_epochs):
            start = record_start_utc + i * epoch_seconds
            end = start + epoch_seconds
            if not finite_rows[i]:
                unscored.append({"start_utc": start, "end_utc": end,
                                 "reason": "no_features", "seconds": epoch_seconds})
                continue
            if int(labels[i]) == 0:
                unscored.append({"start_utc": start, "end_utc": end,
                                 "reason": "undefined_class", "seconds": epoch_seconds})
                continue
            epochs_out.append({
                "start_utc": start,
                "end_utc": end,
                "label": CLASS_ORDER[int(labels[i])],
                "run_index": index,
                "_scores": [float(x) for x in probabilities[i]],
            })
        diagnostics["staged_epochs"] = len(epochs_out)
        diagnostics["unscored_epochs"] = len(unscored)
        diagnostics["feature_matrix_shape"] = [int(x) for x in np.shape(matrix)]
        diagnostics["n_feature_ids"] = len(feature_ids)
        diagnostics["feature_ids"] = list(feature_ids)
        diagnostics["masked_column_count"] = int(sum(
            1 for c in range(np.shape(matrix)[1]) if np.any(~np.isfinite(matrix[:, c]))))
        diagnostics["all_nan_columns"] = [feature_ids[c] for c in range(np.shape(matrix)[1])
                                          if np.all(~np.isfinite(matrix[:, c]))]
        diagnostics["epoch_seconds"] = epoch_seconds
        attempted = [(record_start_utc + i * epoch_seconds, record_start_utc + (i + 1) * epoch_seconds)
                     for i in range(n_epochs)]
        return {"precheck": precheck, "diagnostics": diagnostics, "epochs": epochs_out,
                "unscored": unscored, "attempted": attempted}

    # -- output shaping --------------------------------------------------------
    @staticmethod
    def _merge_epochs(epochs: list[dict], epoch_seconds: int) -> list[dict]:
        """Merge contiguous same-label epochs into runs (StageSegment-like shape)."""
        merged: list[dict] = []
        for epoch in epochs:
            if merged and merged[-1]["label"] == epoch["label"] \
                    and merged[-1]["end_utc"] == epoch["start_utc"]:
                merged[-1]["end_utc"] = epoch["end_utc"]
                merged[-1]["epochs"] += 1
            else:
                merged.append({"start_utc": epoch["start_utc"], "end_utc": epoch["end_utc"],
                               "label": epoch["label"], "epochs": 1,
                               "seconds": epoch_seconds})
        for entry in merged:
            entry["seconds"] = entry["epochs"] * epoch_seconds
        return merged


PROVIDER = SleepStageProvider()
PROVIDERS = (PROVIDER,)


def register(registry: dict) -> dict:
    return PROVIDER.register(registry)


def infer(*, input: dict, context: dict, provider: Optional[dict] = None) -> dict:
    return PROVIDER.infer(input=input, context=context, provider=provider)
