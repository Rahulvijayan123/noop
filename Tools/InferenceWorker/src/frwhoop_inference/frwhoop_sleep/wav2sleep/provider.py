"""wav2sleep PPG-only sleep-stage provider (``wav2sleep.ppg-only.v1``, metric ``sleep_stage``).

Shadow-only stage context. It never writes the canonical four-stage fields, never produces apnea
events, and is disabled by default (``FRWHOOP_WAV2SLEEP_SHADOW_ENABLED`` must be exactly "1").

The provider speaks the sleep-provider wire interface (``manifest() / readiness() /
infer(input=, context=, provider=)``, like ``sleepecg.wrn-gru-mesa.v1``) and is presented to the
sidecar registry through :class:`Wav2SleepRegistryShim` (a :class:`RegistryShim` subclass that
also reports :meth:`runtime_identity`). Registration is one line - see
docs/pretrained-models/integration/wav2sleep.md.

Output (status ``ok``)
----------------------
* ``result.stages``  - argmax LABEL runs over scored epochs (label type), each tagged with
  ``label_space`` and ``release_mode``;
* ``raw_scores``     - the per-epoch columns on the window's UTC 30-s grid: ``epoch_start_utc``,
  ``mask``/``mask_reason``, ``run_index``, then three type-separated blocks: ``probabilities``
  (softmax of the logits, uncalibrated), ``logits`` (exactly as the model returns them) and
  ``labels`` (argmax). Masked epochs are ``null`` in all three;
* ``diagnostics``    - native-sample provenance per run, gates, digests (input, artifact,
  preprocessing, cache key), timing and the declarations in :func:`declarations`.
"""

from __future__ import annotations

import os
import time
from importlib import metadata
from typing import Any, Mapping, Optional

import numpy as np

from ..timebase import json_safe
from . import constants as C
from . import digests as D
from .contract import ParsedNight, Withhold, parse_night
from .preprocessing import (EpochPlan, native_provenance, plan_run, preprocessing_parameters,
                            resample_run)

DEFAULT_MODEL_ROOT = "/opt/frwhoop-models"


def _version(dist: str) -> Optional[str]:
    try:
        return metadata.version(dist)
    except metadata.PackageNotFoundError:
        return None


def declarations() -> dict[str, Any]:
    """The Spec 03 adapter declarations, in one block."""
    return {
        "source_identity": {
            "code_repository": C.CODE_REPOSITORY,
            "code_commit": C.CODE_COMMIT,
            "code_commit_date": C.CODE_COMMIT_DATE,
            "code_content_identical_since": C.CODE_CONTENT_SINCE,
            "weights_repository": C.WEIGHTS_REPOSITORY,
            "weights_revision": C.WEIGHTS_REVISION,
            "weights_revision_date": C.WEIGHTS_REVISION_DATE,
            "license": {"code": C.CODE_LICENSE, "weights": C.WEIGHTS_LICENSE},
            "artifacts": {name: {k: v for k, v in spec.items()} for name, spec in C.ARTIFACTS.items()},
            "state_dict": {"tensors": C.STATE_DICT_KEYS, "parameters": C.STATE_DICT_PARAMETERS},
            "model_code_digest": D.model_code_digest(),
        },
        "sampling_contract": C.SAMPLING_CONTRACT,
        "transport": {
            "spec01_contract": "docs/model-integration/README.md 'PPG segments' (Spec 01 branch, "
                               "ff143411e + 0fd8b94d3)",
            "native_rate": "ppg.native_rate_hz in %s and equal to every clock.samples_per_second"
                           % list(C.SUPPORTED_NATIVE_RATES_HZ),
            "clock_interpreted": ["packet_timing_verified", "samples_per_second"],
            "clock_provenance_only": ["source", "grid", "endpoint"],
            "config": "identity present and identified (not 'unknown'), known=true, stable=true",
            "run_id": "joined only while contiguous with one config.identity; a violation is split "
                      "and counted as %s" % C.RUN_ID_DISCONTINUITY,
        },
        "required_channels": {"admitted": [C.MODEL_SIGNAL], "absent": list(C.NOT_ADMITTED_SIGNALS),
                              "route": "pinned predict_on_folder(signals=['PPG']): the absent "
                                       "modalities are not in the model input dict"},
        "polarity": C.POLARITY,
        "activation_gates": list(C.ACTIVATION_GATES),
        "preprocessing": preprocessing_parameters(),
        "classes": {"label_space": C.LABEL_SPACE, "order": list(C.CLASS_ORDER),
                    "meanings": dict(C.CLASS_MEANINGS), "output_types": dict(C.OUTPUT_TYPES)},
        "gates": dict(C.DEFAULT_CONFIG),
        "release_mode": C.RELEASE_MODE,
        "bounds": {"max_epochs": C.MAX_EPOCHS, "max_window_seconds": C.MAX_WINDOW_SECONDS,
                   "concurrent_forwards": 1, "thread_cap_env": C.THREADS_ENV,
                   "default_threads": C.DEFAULT_THREADS, "max_threads": C.MAX_THREADS,
                   "measured": dict(C.MEASURED_RESOURCES)},
        "consumer": dict(C.DOWNSTREAM_CONSUMER),
        "accuracy_status": C.ACCURACY_STATUS,
        "never": ["canonical sleep stages", "apnea or respiratory events",
                  "PPG-derived respiration supplied as ABD/THX", "training or calibration"],
    }


class Wav2SleepPpgProvider:
    """wav2sleep PPG-only shadow stager."""

    provider_id = C.PROVIDER_ID
    metric = C.METRIC
    mode = C.MODE
    label_space = C.LABEL_SPACE
    required_signals = C.REQUIRED_SIGNALS

    def __init__(self, *, model_root: Optional[str] = None, enabled: Optional[bool] = None,
                 threads: Optional[int] = None):
        self._model_root = model_root
        self._enabled = enabled
        self._threads = threads

    # -- configuration ----------------------------------------------------------------------
    def model_root(self) -> str:
        return self._model_root or os.environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_MODEL_ROOT

    def enabled(self) -> bool:
        if self._enabled is not None:
            return bool(self._enabled)
        return os.environ.get(C.ENABLE_FLAG) == "1"

    def threads(self) -> int:
        from .runtime import thread_cap

        return thread_cap(self._threads)

    def versions(self) -> dict[str, Any]:
        return {
            "adapter": C.ADAPTER_VERSION,
            "preprocessing": C.PREPROCESSING_REVISION,
            "config": C.CONFIG_VERSION,
            "dependency": "torch==%s;numpy==%s" % (_version("torch"), _version("numpy")),
            "model": "wav2sleep@%s" % C.ARTIFACTS["state_dict.pth"]["sha256"][:12],
            "code_commit": C.CODE_COMMIT,
            "weights_revision": C.WEIGHTS_REVISION,
        }

    # -- server surface -----------------------------------------------------------------------
    def manifest(self) -> dict[str, Any]:
        return {
            "metric": C.METRIC,
            "provider_id": C.PROVIDER_ID,
            "versions": self.versions(),
            "required_signals": list(C.REQUIRED_SIGNALS),
            "label_space": C.LABEL_SPACE,
            "retrospective_or_causal": C.MODE,
            "release_mode": C.RELEASE_MODE,
            "accuracy_status": C.ACCURACY_STATUS,
            "eligibility": {
                "state": "blocked_input",
                "reason": "no anchored, contiguous overnight PPG reaches the server yet",
                "promotion_blocked_by": list(C.ACTIVATION_GATES),
            },
            "enabled": self.enabled(),
            "enable_flag": C.ENABLE_FLAG,
            "license": {"spdx": "MIT", "note": "wav2sleep code and released weights, (c) 2026 Jonathan Carter"},
            "artifacts": {name: {"sha256": spec["sha256"], "bytes": spec["size_bytes"],
                                 "relpath": spec["relpath"]} for name, spec in C.ARTIFACTS.items()},
            "declarations": declarations(),
        }

    def readiness(self) -> dict[str, Any]:
        """Disabled lane: READY (it must never flip the process flag). Enabled lane: the artifacts
        must verify and strictly load (warm); otherwise not ready with the precise reason."""
        if not self.enabled():
            return {"ready": True, "version": C.ADAPTER_VERSION, "reason": None, "enabled": False,
                    "detail": f"lane disabled ({C.ENABLE_FLAG} != '1'); requests are withheld not_ready"}
        from .runtime import get_model

        try:
            loaded = get_model(self.model_root())
        except Withhold as exc:
            return {"ready": False, "version": C.ADAPTER_VERSION, "enabled": True,
                    "reason": f"{exc.reason}: {exc.detail}: {exc.message}"}
        except Exception as exc:  # noqa: BLE001 - an adapter defect is a readiness fault
            return {"ready": False, "version": C.ADAPTER_VERSION, "enabled": True,
                    "reason": f"provider_error: {type(exc).__name__}: {exc}"}
        return {"ready": True, "version": C.ADAPTER_VERSION, "reason": None, "enabled": True,
                "provenance": {name: a.sha256 for name, a in loaded.artifacts.items()},
                "load_seconds": loaded.load_seconds}

    def runtime_identity(self) -> dict[str, Any]:
        """What this process has loaded, measured from bytes (fragment for the identity block)."""
        from .runtime import cached_models

        root = os.path.realpath(self.model_root())
        loaded = cached_models().get(root)
        block: dict[str, Any] = {
            "provider_id": C.PROVIDER_ID,
            "adapter_version": C.ADAPTER_VERSION,
            "release_mode": C.RELEASE_MODE,
            "enabled": self.enabled(),
            "model_root_resolved": root,
            "loaded": loaded is not None,
            "code_commit": C.CODE_COMMIT,
            "weights_revision": C.WEIGHTS_REVISION,
            "model_code_digest": D.model_code_digest(),
            "preprocessing_digest_default_gates": D.preprocessing_digest(C.DEFAULT_CONFIG),
            "threads": self.threads(),
        }
        if loaded is not None:
            block["artifacts"] = {name: a.to_wire() for name, a in loaded.artifacts.items()}
            block["artifact_digest"] = loaded.artifact_digest
            block["loaded_at_unix"] = round(loaded.loaded_at_unix, 3)
            block["load_seconds"] = loaded.load_seconds
        else:
            block["artifacts"] = None
            block["artifact_digest"] = None
        return block

    def loaded_identity(self) -> dict[str, str]:
        """Spec 01's ``loaded_identity()`` hook (identity.py): a flat string map of what this process loaded.
        Artifact digests appear only once the model is loaded here; nothing is taken from configuration."""
        block = self.runtime_identity()
        out = {key: str(block[key]) for key in ("provider_id", "adapter_version", "release_mode", "enabled",
                                                "loaded", "code_commit", "weights_revision", "model_code_digest",
                                                "preprocessing_digest_default_gates", "threads")}
        if block["artifacts"]:
            for name, artifact in sorted(block["artifacts"].items()):
                out[f"{name}.sha256"] = str(artifact["sha256"])
            out["artifact_digest"] = str(block["artifact_digest"])
        return out

    def register(self, registry: dict) -> dict:
        """Dict registries in this package are keyed by metric; two providers share
        ``sleep_stage``, so this one registers under its provider id."""
        registry[C.PROVIDER_ID] = self
        return registry

    # -- inference ------------------------------------------------------------------------------
    def infer(self, *, input: Optional[Mapping[str, Any]], context: Optional[Mapping[str, Any]],
              provider: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
        started = time.perf_counter()
        context = dict(context or {})
        try:
            requested = (provider or {}).get("provider_id")
            if requested and requested != C.PROVIDER_ID:
                raise Withhold("provider_id_mismatch",
                               f"requested {requested!r}, this provider is {C.PROVIDER_ID!r}")
            if not self.enabled():
                raise Withhold("lane_disabled",
                               f"{C.PROVIDER_ID} is disabled ({C.ENABLE_FLAG} must be exactly '1')")
            outcome = self.stage(input, context)
        except Withhold as exc:
            return self._withheld(exc, context, started)
        except Exception as exc:  # noqa: BLE001 - a defect is reported, never raised
            import traceback

            return self._error(exc, traceback.format_exc().strip().splitlines()[-3:], started)
        return self._render_ok(outcome, context, started)

    def stage(self, payload: Optional[Mapping[str, Any]], context: Mapping[str, Any]) -> dict[str, Any]:
        """Full-precision staging (no rounding). Raises :class:`Withhold`. Used by ``infer``."""
        timing: dict[str, float] = {}
        t_parse = time.perf_counter()
        night = parse_night(payload, context)
        timing["parse_s"] = time.perf_counter() - t_parse
        config = night.config

        grid_start = -(-night.window_start // C.EPOCH_SECONDS) * C.EPOCH_SECONDS
        grid_end = (night.window_end // C.EPOCH_SECONDS) * C.EPOCH_SECONDS
        n_grid = (grid_end - grid_start) // C.EPOCH_SECONDS
        if n_grid <= 0:
            raise Withhold("invalid_window", "the window holds no whole 30-s epoch")
        epoch_start = grid_start + C.EPOCH_SECONDS * np.arange(n_grid, dtype=np.int64)
        mask_reason: list[Optional[str]] = ["no_ppg"] * n_grid
        run_of_epoch: list[Optional[int]] = [None] * n_grid

        # Any second covered by an admitted run but not by a complete epoch is a run edge.
        for run in night.runs:
            lo = max(0, (run.start - grid_start) // C.EPOCH_SECONDS)
            hi = min(n_grid, -(-(run.end - grid_start) // C.EPOCH_SECONDS))
            for e in range(int(lo), int(hi)):
                mask_reason[e] = "run_edge_partial_epoch"
                run_of_epoch[e] = run.index

        plans: list[EpochPlan] = []
        run_rows: list[dict[str, Any]] = []
        for run in night.runs:
            plan = plan_run(run)
            row = native_provenance(run, plan)
            first = (plan.t0 - grid_start) // C.EPOCH_SECONDS
            indices = [int(first + e) for e in range(plan.n_epochs) if 0 <= first + e < n_grid]
            if len(indices) != plan.n_epochs:
                raise ValueError("a run epoch falls outside the window grid")  # clipped by construction
            used = run.samples[plan.native_offset:plan.native_offset + plan.native_used]
            if plan.n_epochs == 0:
                row["staged"] = False
                row["skip_reason"] = "run_edge_partial_epoch"
            elif plan.n_epochs < int(config["min_run_epochs"]):
                row["staged"] = False
                row["skip_reason"] = "run_too_short"
                for i in indices:
                    mask_reason[i] = "run_too_short"
            elif float(np.std(used)) < C.MIN_SIGNAL_STD:
                row["staged"] = False
                row["skip_reason"] = "flat_signal"
                for i in indices:
                    mask_reason[i] = "flat_signal"
            else:
                row["staged"] = True
                plans.append(plan)
            row["grid_epoch_index_first"] = indices[0] if indices else None
            run_rows.append(row)

        expected = sum(p.n_epochs for p in plans)
        if not plans:
            raise Withhold("no_stageable_run",
                           f"no run reaches min_run_epochs={config['min_run_epochs']} "
                           f"({int(config['min_run_epochs']) * C.EPOCH_SECONDS // 60} min) of "
                           "contiguous, configuration-compatible PPG",
                           runs=json_safe(run_rows))
        self._coverage_gate(expected, n_grid, config, run_rows)

        from .runtime import get_model, run_ppg, softmax

        t_load = time.perf_counter()
        loaded = get_model(self.model_root())
        timing["model_ready_s"] = time.perf_counter() - t_load
        threads = self.threads()

        logits = np.full((n_grid, len(C.CLASS_ORDER)), np.nan)
        probs = np.full((n_grid, len(C.CLASS_ORDER)), np.nan)
        timing["resample_s"] = timing["zscore_and_forward_s"] = 0.0
        for plan in plans:
            run = night.runs[plan.run_index]
            t = time.perf_counter()
            signal = resample_run(run, plan)
            timing["resample_s"] += time.perf_counter() - t
            t = time.perf_counter()
            run_logits, stats = run_ppg(loaded, signal, threads=threads)
            timing["zscore_and_forward_s"] += time.perf_counter() - t
            run_rows[plan.run_index]["zscore"] = {"mean_adc": stats["mean"], "std_adc": stats["std"]}
            first = (plan.t0 - grid_start) // C.EPOCH_SECONDS
            rows = slice(int(first), int(first + plan.n_epochs))
            if not np.all(np.isfinite(run_logits)):
                for i in range(rows.start, rows.stop):
                    mask_reason[i] = "nonfinite_model_output"
                run_rows[plan.run_index]["staged"] = False
                run_rows[plan.run_index]["skip_reason"] = "nonfinite_model_output"
                continue
            logits[rows] = run_logits
            probs[rows] = softmax(run_logits)
            for i in range(rows.start, rows.stop):
                mask_reason[i] = None
                run_of_epoch[i] = plan.run_index

        mask = np.array([reason is None for reason in mask_reason], dtype=bool)
        if not mask.any():
            raise Withhold("nonfinite_model_output", "the model returned non-finite logits for every run",
                           runs=json_safe(run_rows))
        self._coverage_gate(int(mask.sum()), n_grid, config, run_rows)
        labels = [C.CLASS_ORDER[int(i)] if m else None
                  for i, m in zip(np.argmax(np.nan_to_num(logits, nan=-np.inf), axis=1), mask)]

        input_sha = D.input_digest(night, context)
        artifact_sha = loaded.artifact_digest
        preprocessing_sha = D.preprocessing_digest(config)
        return {
            "night": night,
            "n_grid": n_grid,
            "epoch_start": epoch_start,
            "mask": mask,
            "mask_reason": mask_reason,
            "run_of_epoch": run_of_epoch,
            "logits": logits,
            "probabilities": probs,
            "labels": labels,
            "runs": run_rows,
            "threads": threads,
            "timing": timing,
            "artifacts": {name: a.to_wire() for name, a in loaded.artifacts.items()},
            "digests": {"input": input_sha, "artifact": artifact_sha,
                        "preprocessing": preprocessing_sha,
                        "cache_key": D.cache_key(input_sha, artifact_sha, preprocessing_sha)},
        }

    @staticmethod
    def _coverage_gate(scored: int, n_grid: int, config: Mapping[str, Any], runs: list) -> None:
        fraction = scored / float(n_grid)
        if scored < int(config["min_valid_epochs"]) or fraction < float(config["min_coverage_fraction"]):
            raise Withhold("insufficient_overnight_coverage",
                           f"{scored} scored epochs ({fraction:.3f} of {n_grid}); the gates are "
                           f">= {config['min_valid_epochs']} epochs and >= "
                           f"{config['min_coverage_fraction']} of the window",
                           scored_epochs=scored, window_epochs=n_grid,
                           coverage_fraction=round(fraction, 5), runs=json_safe(runs))

    # -- rendering ------------------------------------------------------------------------------
    @staticmethod
    def _label_runs(outcome: dict[str, Any]) -> list[dict[str, Any]]:
        stages: list[dict[str, Any]] = []
        for i, label in enumerate(outcome["labels"]):
            if label is None:
                continue
            start = int(outcome["epoch_start"][i])
            run_index = outcome["run_of_epoch"][i]
            if (stages and stages[-1]["label"] == label and stages[-1]["end_utc"] == start
                    and stages[-1]["run_index"] == run_index):
                stages[-1]["end_utc"] = start + C.EPOCH_SECONDS
                stages[-1]["epochs"] += 1
            else:
                stages.append({"start_utc": start, "end_utc": start + C.EPOCH_SECONDS,
                               "label": label, "stage": label, "epochs": 1,
                               "run_index": run_index, "label_space": C.LABEL_SPACE,
                               "release_mode": C.RELEASE_MODE})
        for stage in stages:
            stage["seconds"] = stage["epochs"] * C.EPOCH_SECONDS
        return stages

    @staticmethod
    def _masked_intervals(outcome: dict[str, Any]) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for i, reason in enumerate(outcome["mask_reason"]):
            if reason is None:
                continue
            start = int(outcome["epoch_start"][i])
            if out and out[-1]["reason"] == reason and out[-1]["end_utc"] == start:
                out[-1]["end_utc"] = start + C.EPOCH_SECONDS
            else:
                out.append({"start_utc": start, "end_utc": start + C.EPOCH_SECONDS, "reason": reason})
        for entry in out:
            entry["seconds"] = entry["end_utc"] - entry["start_utc"]
        return out

    def _render_ok(self, outcome: dict[str, Any], context: Mapping[str, Any], started: float) -> dict[str, Any]:
        night: ParsedNight = outcome["night"]
        mask = outcome["mask"]
        scored = int(mask.sum())

        def rows(matrix: np.ndarray, digits: int) -> list:
            return [[round(float(v), digits) for v in matrix[i]] if mask[i] else None
                    for i in range(outcome["n_grid"])]

        raw_scores = {
            "schema": "wav2sleep.ppg-only.epochs/1",
            "release_mode": C.RELEASE_MODE,
            "label_space": C.LABEL_SPACE,
            "class_order": list(C.CLASS_ORDER),
            "epoch_seconds": C.EPOCH_SECONDS,
            "first_epoch_start_utc": int(outcome["epoch_start"][0]),
            "epoch_start_utc": [int(t) for t in outcome["epoch_start"]],
            "mask": [bool(m) for m in mask],
            "mask_reason": list(outcome["mask_reason"]),
            "run_index": list(outcome["run_of_epoch"]),
            "probabilities": {"output_type": "class_probabilities", "transform": "softmax(logits)",
                              "calibrated": False, "precision_decimals": 6,
                              "values": rows(outcome["probabilities"], 6)},
            "logits": {"output_type": "logits", "precision_decimals": 5,
                       "values": rows(outcome["logits"], 5)},
            "labels": {"output_type": "argmax_label", "values": list(outcome["labels"])},
            "native_sample_provenance": {
                "native_rate_hz": night.native_rate_hz,
                "native_rate_source": "ppg.native_rate_hz == clock.samples_per_second (declared)",
                "native_samples_per_epoch_used": C.native_samples_per_epoch(night.native_rate_hz) + 1,
                "span": "[epoch_start, epoch_end] inclusive: the %d native samples of the epoch "
                        "plus the next second's first sample, which the pinned grid point at the "
                        "epoch end lands on" % C.native_samples_per_epoch(night.native_rate_hz),
                "model_samples_per_epoch": C.MODEL_SAMPLES_PER_EPOCH,
                "polarity": C.POLARITY,
                "runs": "diagnostics.runs",
            },
            "note": "uncalibrated model output on WHOOP PPG; not a validated probability, not a "
                    "canonical stage and not an apnea/respiratory event",
        }
        n_grid = outcome["n_grid"]
        coverage = {
            "window_seconds": int(night.window_end - night.window_start),
            "window_epochs": int(n_grid),
            "scored_epochs": scored,
            "masked_epochs": int(n_grid - scored),
            "scored_seconds": scored * C.EPOCH_SECONDS,
            "coverage_fraction": round(scored / float(n_grid), 5),
            "runs": len(night.runs),
            "runs_staged": sum(1 for r in outcome["runs"] if r.get("staged")),
            "native_samples_admitted": night.native_samples_total,
            "native_rate_hz": night.native_rate_hz,
            C.RUN_ID_DISCONTINUITY: night.run_id_discontinuities,
            "mask_reason_counts": {reason: outcome["mask_reason"].count(reason)
                                   for reason in sorted({r for r in outcome["mask_reason"] if r})},
        }
        timing = {k: round(v, 4) for k, v in outcome["timing"].items()}
        diagnostics = {
            "release_mode": C.RELEASE_MODE,
            "accuracy_status": C.ACCURACY_STATUS,
            "label_space": C.LABEL_SPACE,
            "class_order": list(C.CLASS_ORDER),
            "class_meanings": dict(C.CLASS_MEANINGS),
            "gates": dict(night.config),
            "gate_overrides": dict(night.config_overrides),
            "runs": outcome["runs"],
            "segments": night.segments_total,
            "segments_outside_window": night.segments_outside_window,
            "native_rate_hz": night.native_rate_hz,
            C.RUN_ID_DISCONTINUITY: night.run_id_discontinuities,
            "run_id_discontinuity_details": night.run_id_discontinuity_details,
            "polarity": C.POLARITY,
            "input_revision": night.input_revision,
            "producer_withheld_seconds": night.producer_withheld_seconds,
            "digests": outcome["digests"],
            "artifacts": outcome["artifacts"],
            "threads": outcome["threads"],
            "timing_s": timing,
            "modalities": {"model_input": [C.MODEL_SIGNAL], "absent": list(C.NOT_ADMITTED_SIGNALS)},
            "consumer": dict(C.DOWNSTREAM_CONSUMER),
            "notes": [
                "shadow stage context only: never the canonical stager, never apnea events",
                "probabilities are uncalibrated softmax outputs; resampling the declared %d Hz "
                "native rate to 34.13 Hz is tensor compatibility only and adds no bandwidth"
                % night.native_rate_hz,
                "the PPG reaches the model with the polarity it arrived with; the checkpoint is "
                "polarity-sensitive and WHOOP's optical polarity is unverified",
                "each run is staged as its own recording; gaps and run edges are masked, never "
                "bridged",
            ],
        }
        return {
            "status": "ok",
            "metric": C.METRIC,
            "provider_id": C.PROVIDER_ID,
            "versions": self.versions(),
            "release_mode": C.RELEASE_MODE,
            "input": {"sha256": outcome["digests"]["input"],
                      "refs": {"context": {"user_id": context.get("user_id"),
                                           "device_id": context.get("device_id"),
                                           "iana_timezone": context.get("iana_timezone")},
                               "window": [night.window_start, night.window_end],
                               "segments": night.segments_total, "runs": len(night.runs)}},
            "result": {"stages": self._label_runs(outcome), "label_space": C.LABEL_SPACE,
                       "unscored": self._masked_intervals(outcome),
                       "release_mode": C.RELEASE_MODE},
            "interval": {"start_utc": night.window_start, "end_utc": night.window_end,
                         "iana_timezone": context.get("iana_timezone")},
            "final_or_provisional": "final",
            "coverage": coverage,
            "raw_scores": raw_scores,
            "diagnostics": json_safe(diagnostics),
            "runtime_ms": int((time.perf_counter() - started) * 1000),
        }

    def _withheld(self, exc: Withhold, context: Mapping[str, Any], started: float) -> dict[str, Any]:
        return {
            "status": "withheld",
            "metric": C.METRIC,
            "provider_id": C.PROVIDER_ID,
            "versions": self.versions(),
            "release_mode": C.RELEASE_MODE,
            "input": {"sha256": None, "refs": {}},
            "result": None,
            "interval": None,
            "final_or_provisional": "provisional",
            "coverage": {},
            "raw_scores": None,
            "diagnostics": json_safe({"reason_detail": exc.detail, "message": exc.message,
                                      "release_mode": C.RELEASE_MODE, **exc.extra}),
            "runtime_ms": int((time.perf_counter() - started) * 1000),
            "withheld_reason": exc.reason,
        }

    def _error(self, exc: Exception, tail: list, started: float) -> dict[str, Any]:
        return {
            "status": "error",
            "metric": C.METRIC,
            "provider_id": C.PROVIDER_ID,
            "versions": self.versions(),
            "release_mode": C.RELEASE_MODE,
            "input": {"sha256": None, "refs": {}},
            "result": None,
            "interval": None,
            "final_or_provisional": "provisional",
            "coverage": {},
            "raw_scores": None,
            "diagnostics": {"reason_detail": "provider_error",
                            "message": f"{type(exc).__name__}: {exc}", "traceback_tail": tail},
            "runtime_ms": int((time.perf_counter() - started) * 1000),
            "error": "provider_error",
        }


PROVIDER = Wav2SleepPpgProvider()


def make_providers() -> list:
    """The registry-protocol presentation (one line to register: see the integration doc)."""
    from .registry import Wav2SleepRegistryShim

    return [Wav2SleepRegistryShim(PROVIDER)]
