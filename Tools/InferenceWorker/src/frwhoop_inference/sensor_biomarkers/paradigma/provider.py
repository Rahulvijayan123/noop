"""ParaDigMa research provider: tremor + arm_swing families (spec section 6.3).

The provider runs the REAL upstream ParaDigMa package (pinned commit
4735d6d21b2a62b764a0bc7e0f677577e6ce1668, v1.1.2) in a NARROW OPTIONAL
subprocess environment (spec 6.3): the main inference env pins
scikit-learn 1.9.1 while the tremor pickle records 1.6.0 and the package
requires ``scikit-learn <1.6.1``, so a separate venv is used instead of
downgrading shared inference dependencies. The venv installs the same
numpy/scipy/pandas pins as the main env (verified 2026-10-06).

Flow:
    ``compute_family_documents`` is what ``sensor.biomarkers.v1`` (the route
    the worker calls) reaches through the optional-family seam
    (``sensor_biomarkers/optional.py``); ``ParadigmaProvider.infer`` serves the
    same families when a request names ``sensor.biomarkers.paradigma.v1``.
    Both run ``_run_families``: decode the IMU input, split it into contiguous
    eligible runs, apply the (currently unverified) WHOOP->ParaDigMa rotation
    when the arm-swing gates pass, and run ``paradigma/runner.py`` in the
    subprocess with a bounded lifetime. The runner verifies the exact bytes the
    pipeline will unpickle before calling ``run_paradigma``.

Gating (CONTRACTS.md reason vocabulary):
    * FRWHOOP_PARADIGMA_ENABLED != "1"          -> family_disabled (standalone: not registered)
    * missing/mismatched pinned artifacts       -> artifact_unavailable (standalone: not registered)
    * missing subprocess python                 -> runtime_unavailable (standalone: not registered)
    * native IMU rate < 50 Hz                   -> unsupported_native_rate
    * no IMU                                    -> artifact_unavailable (no_verified_imu_objects)
    * no eligible run / no windows              -> not_enough_valid_data
    * watch_side not left/right                 -> arm_swing only: unknown_wrist_placement
    * device_orientation not screen_up/down     -> arm_swing only: unknown_orientation
    * WHOOP axis convention unverified          -> arm_swing only: unknown_orientation
    * subprocess over its time budget           -> timeout
    * runner crash / upstream error             -> adapter_broken (aggregate route)

Tremor is coordinate-invariant (upstream coordinate_system.md) and is NOT
gated on wrist placement/orientation; a failed arm-swing gate never drops
tremor. Placement is taken from the request as sent and never guessed.
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import tempfile
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

import numpy as np

from ..contract import family_document  # W2-owned document builder
from ..optional import (
    BROKEN_EXCEPTION,
    STATE_ARTIFACT_UNAVAILABLE,
    STATE_DISABLED,
    STATE_READY,
    STATE_RUNTIME_UNAVAILABLE,
    broken_state,
    make_state,
    state_documents,
)
from .axes import (
    WHOOP5_AXIS_CONVENTION_VERIFIED,
    WHOOP5_AXIS_EVIDENCE,
    WHOOP5_TO_PARADIGMA,
    apply_rotation,
    rotation_can_enable_arm_swing,
)

# ---------------------------------------------------------------------------
# Configuration / environment
# ---------------------------------------------------------------------------

#: Upstream tree this adapter was validated against (resolved clone HEAD).
UPSTREAM_COMMIT = "4735d6d21b2a62b764a0bc7e0f677577e6ce1668"

#: Provider id under the sensor.biomarkers.v1 metric (CONTRACTS.md §4/§8).
PROVIDER_ID = "sensor.biomarkers.paradigma.v1"

#: Name of this adapter at the optional-family seam, and the families it serves.
ADAPTER_NAME = "paradigma"
FAMILIES = ("tremor", "arm_swing")

#: Minimum native IMU rate required by ParaDigMa's validated pipelines
#: (docs/guides/sensor_requirements.md: >= 50 Hz for tremor and gait).
MIN_NATIVE_RATE_HZ = 50.0

#: Default subprocess lifetime bound (seconds). Bounded lifetimes are a hard
#: requirement: the runner must never hang a request thread. Override with
#: FRWHOOP_PARADIGMA_TIMEOUT_S. Through the aggregate route the bound is also
#: capped by what is left of the request's optional-family budget.
DEFAULT_SUBPROCESS_TIMEOUT_S = 180.0

#: Default location of the narrow paradigma venv python when
#: FRWHOOP_PARADIGMA_PYTHON is unset.
DEFAULT_PARADIGMA_PYTHON = "/opt/frwhoop-paradigma/venv/bin/python"

#: Default artifact root (same convention as artifacts.DEFAULT_MODEL_ROOT);
#: override with FRWHOOP_MODEL_ROOT.
DEFAULT_MODEL_ROOT = "/opt/frwhoop-models"

#: Artifact entry id in models/manifest.json (parent merges the W3 entry).
MANIFEST_ENTRY_ID = "paradigma"

#: Assets required for every run, and which families they gate.
REQUIRED_ARTIFACTS = {
    "tremor_detection_clf_package.pkl": ("tremor",),
    "gait_detection_clf_package.pkl": ("arm_swing",),
    "gait_filtering_clf_package.pkl": ("arm_swing",),
}

ENABLE_FLAG = "FRWHOOP_PARADIGMA_ENABLED"
WATCH_SIDES = ("left", "right")
DEVICE_ORIENTATIONS = ("screen_up", "screen_down")


def _env_flag(name: str) -> bool:
    return os.environ.get(name) == "1"


def _manifest_path() -> str:
    from ...artifacts import default_manifest_path

    return os.environ.get("FRWHOOP_MANIFEST") or default_manifest_path()


def _model_root() -> str:
    return os.environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_MODEL_ROOT


def _venv_python() -> str:
    return os.environ.get("FRWHOOP_PARADIGMA_PYTHON") or DEFAULT_PARADIGMA_PYTHON


def _subprocess_timeout() -> float:
    try:
        return float(os.environ.get("FRWHOOP_PARADIGMA_TIMEOUT_S", DEFAULT_SUBPROCESS_TIMEOUT_S))
    except (TypeError, ValueError):
        return DEFAULT_SUBPROCESS_TIMEOUT_S


def _file_stat(path: str) -> tuple[int, int] | None:
    try:
        stat = os.stat(path)
    except OSError:
        return None
    return stat.st_size, stat.st_mtime_ns


#: The last verification, keyed by the manifest entry and the artifacts' size and
#: mtime: the bytes are re-hashed only when something on disk changed, so the
#: per-request and /v1/providers checks stay cheap.
_ARTIFACT_STATE_CACHE: dict[tuple, tuple[bool, str | None, dict[str, str], str | None]] = {}


def _artifact_check(detail_code: str | None = None):
    def wrap(ok: bool, reason: str | None, sha256s: dict[str, str]):
        return ok, reason, sha256s, detail_code
    return wrap


def _verify_artifacts() -> tuple[bool, str | None, dict[str, str], str | None]:
    """``(ok, reason, {asset_name: sha256}, detail_code)`` for the paradigma manifest entry."""
    from ...artifacts import load_manifest, verify_manifest

    manifest_path = _manifest_path()
    root = _model_root()
    try:
        manifest = load_manifest(manifest_path)
    except Exception as exc:  # manifest unusable -> fail closed
        return False, f"manifest unusable: {exc}", {}, "manifest_unusable"
    entry = next((e for e in manifest.get("entries", []) if e.get("id") == MANIFEST_ENTRY_ID), None)
    if entry is None:
        return (False, f"manifest has no {MANIFEST_ENTRY_ID} entry (parent merge pending)", {},
                "manifest_entry_missing")
    artifacts = entry.get("artifacts") or []
    key = (manifest_path, root, json.dumps(entry, sort_keys=True, default=str),
           tuple(_file_stat(os.path.join(root, str(a.get("path") or ""))) for a in artifacts))
    cached = _ARTIFACT_STATE_CACHE.get(key)
    if cached is not None:
        return cached
    # Only this entry's artifacts are hashed: the other manifest entries are not ours to verify.
    state = verify_manifest({"entries": [entry]}, root, manifest_path=manifest_path)
    checks = [c for c in state.checks if c.entry_id == MANIFEST_ENTRY_ID]
    if not checks:
        result = (False, f"manifest {MANIFEST_ENTRY_ID} entry declares no artifacts", {},
                  "manifest_entry_missing")
    elif any(c.failed for c in checks):
        failed = [c for c in checks if c.failed]
        detail = ", ".join(f"{c.artifact_name} ({c.status})" for c in failed)
        code = ("artifact_missing" if any(c.status == "missing" for c in failed)
                else "artifact_mismatch")
        result = (False, f"artifact_unavailable: {detail}", {}, code)
    else:
        sha256s = {c.artifact_name: c.expected_sha256 for c in checks
                   if c.status == "verified" and c.expected_sha256}
        missing = [a for a in REQUIRED_ARTIFACTS if a not in sha256s]
        if missing:
            result = (False, f"artifact_unavailable: manifest missing hashes for {missing}", {},
                      "artifact_missing")
        else:
            result = (True, None, sha256s, None)
    _ARTIFACT_STATE_CACHE.clear()
    _ARTIFACT_STATE_CACHE[key] = result
    return result


def artifact_state() -> tuple[bool, str | None, dict[str, str]]:
    """Verify the paradigma manifest entry against the artifact root.

    Returns ``(ok, reason, {asset_name: sha256})``. Only pinned trusted assets
    verified against the manifest are ever handed to the runner for
    unpickling (CONTRACTS.md §7).
    """
    ok, reason, sha256s, _ = _verify_artifacts()
    return ok, reason, dict(sha256s)


def adapter_state() -> dict[str, Any]:
    """Whether tremor/arm_swing can run here: flag, then artifacts, then runtime.

    Cheap and side-effect free (artifact hashes are cached by file size and
    mtime); ``/v1/providers`` reports it per family.
    """
    flags = {ENABLE_FLAG: _env_flag(ENABLE_FLAG)}
    arm_swing = {"axis_convention_verified": WHOOP5_AXIS_CONVENTION_VERIFIED,
                 "requires": ["watch_side", "device_orientation", "whoop5_axis_convention"]}
    families = {"arm_swing": arm_swing}
    if not flags[ENABLE_FLAG]:
        return make_state(ADAPTER_NAME, STATE_DISABLED, detail=f"{ENABLE_FLAG} is not exactly 1",
                          flags=flags, families=families)
    ok, reason, _, code = _verify_artifacts()
    if not ok:
        return make_state(ADAPTER_NAME, STATE_ARTIFACT_UNAVAILABLE, detail=reason,
                          detail_code=code, flags=flags, families=families)
    python = _venv_python()
    runtime = {"python": python, "upstream_commit": UPSTREAM_COMMIT}
    if not os.path.isfile(python):
        return make_state(ADAPTER_NAME, STATE_RUNTIME_UNAVAILABLE,
                          detail=f"paradigma subprocess python missing: {python}",
                          detail_code="paradigma_runtime_missing", flags=flags,
                          runtime=runtime, families=families)
    return make_state(ADAPTER_NAME, STATE_READY, flags=flags, runtime=runtime, families=families)


def provider_gate() -> tuple[bool, str | None]:
    """Fail-closed registration gate: env flag + verified artifacts + python."""
    state = adapter_state()
    if state["state"] == STATE_READY:
        return True, None
    return False, f"{state['reason']}: {state['detail']}"


def make_providers() -> list["ParadigmaProvider"]:
    """Register the provider only when it can actually run (fail-closed)."""
    ok, _ = provider_gate()
    if not ok:
        return []
    return [ParadigmaProvider()]


# ---------------------------------------------------------------------------
# Input decoding (defensive; W2 owns the shared sensor_biomarkers parser)
# ---------------------------------------------------------------------------

class _ImuError(Exception):
    def __init__(self, reason: str, family: str | None = None, detail: str | None = None):
        super().__init__(reason)
        self.reason = reason
        self.family = family
        self.detail = detail


def _finite(v: Any) -> float:
    out = float(v)
    if not math.isfinite(out):
        raise ValueError("non-finite")
    return out


def _decode_imu(raw: Mapping[str, Any]) -> tuple[dict, dict[str, dict]]:
    """Decode the contract IMU block into contiguous eligible runs.

    Returns ``(meta, runs)`` where ``meta`` carries sampling_rate_hz and
    units, and ``runs`` maps run_id -> {"npz_path" or arrays, "start_unix",
    "duration_s", "sample_count"}. Raises ``_ImuError`` with a precise
    CONTRACTS.md reason when the input cannot be used.
    """
    imu = raw.get("imu")
    if not isinstance(imu, Mapping) or not imu:
        raise _ImuError("artifact_unavailable", family="both", detail="no_verified_imu_objects")
    rate = imu.get("sampling_rate_hz")
    try:
        rate = float(rate)
    except (TypeError, ValueError):
        raise _ImuError("preprocessing_unverified", family="both") from None
    if rate < MIN_NATIVE_RATE_HZ:
        raise _ImuError("unsupported_native_rate", family="both")
    units = imu.get("units") or {}
    if units.get("accel") != "g" or units.get("gyro") != "deg/s":
        raise _ImuError("preprocessing_unverified", family="both")
    segments = imu.get("segments")
    if not isinstance(segments, list) or not segments:
        raise _ImuError("artifact_unavailable", family="both", detail="no_verified_imu_objects")

    parsed: list[dict] = []
    for index, seg in enumerate(segments):
        if not isinstance(seg, Mapping):
            raise _ImuError("not_enough_valid_data", family="both")
        try:
            start_unix = int(seg["start_unix"])
            duration_s = _finite(seg["duration_s"])
        except (KeyError, TypeError, ValueError):
            raise _ImuError("not_enough_valid_data", family="both") from None
        accel = np.asarray(seg.get("accel_g"), dtype=np.float64)
        gyro = np.asarray(seg.get("gyro_dps"), dtype=np.float64)
        if accel.ndim != 2 or accel.shape[1] != 3 or gyro.ndim != 2 or gyro.shape[1] != 3:
            raise _ImuError("not_enough_valid_data", family="both")
        if accel.shape[0] != gyro.shape[0] or accel.shape[0] < 2:
            raise _ImuError("not_enough_valid_data", family="both")
        if not (np.all(np.isfinite(accel)) and np.all(np.isfinite(gyro))):
            raise _ImuError("not_enough_valid_data", family="both")
        expected = int(round(duration_s * rate))
        if abs(accel.shape[0] - expected) > max(2, 0.01 * expected):
            raise _ImuError("preprocessing_unverified", family="both")
        parsed.append({
            "start_unix": start_unix,
            "duration_s": duration_s,
            "accel": accel,
            "gyro": gyro,
            "sample_count": accel.shape[0],
        })

    # Order + overlap checks (endpoint ownership: no duplicated samples).
    for i in range(1, len(parsed)):
        prev_end = parsed[i - 1]["start_unix"] + parsed[i - 1]["duration_s"]
        if parsed[i]["start_unix"] < prev_end:
            raise _ImuError("not_enough_valid_data", family="both")

    # Build contiguous runs (split at gaps; each run internally contiguous).
    runs: list[dict] = []
    current: dict | None = None
    for seg in parsed:
        contiguous = False
        if current is not None:
            prev_end = current["start_unix"] + current["duration_s"]
            contiguous = abs(seg["start_unix"] - prev_end) < 1e-6
        if not contiguous:
            if current is not None:
                runs.append(current)
            current = {"start_unix": seg["start_unix"], "duration_s": 0.0,
                       "accel_parts": [], "gyro_parts": [], "sample_count": 0}
        current["accel_parts"].append(seg["accel"])
        current["gyro_parts"].append(seg["gyro"])
        current["duration_s"] += seg["duration_s"]
        current["sample_count"] += seg["sample_count"]
    if current is not None:
        runs.append(current)

    meta = {"sampling_rate_hz": rate, "units": dict(units)}
    out_runs: dict[str, dict] = {}
    for i, run in enumerate(runs):
        accel = np.concatenate(run["accel_parts"], axis=0)
        gyro = np.concatenate(run["gyro_parts"], axis=0)
        n = accel.shape[0]
        time = np.arange(n) / rate
        out_runs[f"run_{i + 1}"] = {
            "time": time,
            "accel": accel,
            "gyro": gyro,
            "start_unix": run["start_unix"],
            "duration_s": run["duration_s"],
            "sample_count": n,
        }
    return meta, out_runs


def _placement(raw: Mapping[str, Any]) -> dict[str, str]:
    """Placement exactly as the request states it; anything else is ``unknown``, never guessed."""
    watch_side = raw.get("watch_side")
    orientation = raw.get("device_orientation")
    return {
        "watch_side": watch_side if watch_side in WATCH_SIDES else "unknown",
        "device_orientation": orientation if orientation in DEVICE_ORIENTATIONS else "unknown",
        "source": "request",
    }


# ---------------------------------------------------------------------------
# The one implementation of both families
# ---------------------------------------------------------------------------

@dataclass
class _Outcome:
    """What one ParaDigMa run produced: family documents, or why the run failed as a whole."""

    stages: list[dict] = field(default_factory=list)
    coverage: dict[str, dict] = field(default_factory=dict)
    diagnostics: dict[str, Any] = field(default_factory=dict)
    #: None, or "timeout" | "runner_error" | "artifact_unavailable" (nothing was produced).
    failure: str | None = None
    failure_detail: str | None = None


def _withheld_doc(family: str, reason: str, *, observed_seconds: float = 0.0,
                  eligible_seconds: float = 0.0, reason_counts: dict[str, int] | None = None,
                  extra: dict[str, Any] | None = None) -> dict:
    return family_document(family=family, status="withheld", reason=reason,
                           measurements={}, observed_seconds=observed_seconds,
                           eligible_seconds=eligible_seconds,
                           reason_counts=reason_counts, extra=extra)


def _run_families(raw: Mapping[str, Any], requested: Sequence[str], *,
                  timeout_s: float) -> _Outcome:
    """Decode, gate and run ParaDigMa for ``requested`` (tremor and/or arm_swing)."""
    placement = _placement(raw)
    watch_side = placement["watch_side"]
    device_orientation = placement["device_orientation"]

    # -- family-level gates (independent; a failed gate never drops others)
    gates: dict[str, dict] = {
        "tremor": {"ok": True, "reason": None},
        "arm_swing": {"ok": True, "reason": None},
    }
    if watch_side not in WATCH_SIDES:
        gates["arm_swing"] = {"ok": False, "reason": "unknown_wrist_placement"}
    if gates["arm_swing"]["ok"] and device_orientation not in DEVICE_ORIENTATIONS:
        gates["arm_swing"] = {"ok": False, "reason": "unknown_orientation"}
    if gates["arm_swing"]["ok"] and not rotation_can_enable_arm_swing():
        gates["arm_swing"] = {"ok": False, "reason": "unknown_orientation"}

    # -- IMU decode (both families depend on IMU)
    try:
        meta, runs = _decode_imu(raw)
    except _ImuError as exc:
        counts = {exc.detail: 1} if exc.detail else None
        return _Outcome(
            stages=[_withheld_doc(fam, exc.reason, reason_counts=counts,
                                  extra={"placement": placement}) for fam in requested],
            coverage={f: {"observed_seconds": 0.0, "eligible_seconds": 0.0} for f in requested},
            diagnostics={"reason_detail": exc.reason})

    observed_seconds = sum(r["duration_s"] for r in runs.values())
    provenance = {"imu_native_rate_hz": meta["sampling_rate_hz"], "runs": len(runs),
                  "observed_seconds": observed_seconds}
    common = {"placement": placement, "input_provenance": provenance}

    # -- short-run gate: upstream cannot classify a run shorter than one
    #    4 s tremor window; withhold rather than crash (not_enough_valid_data).
    window_length_s = 4.0
    longest_run_s = max(r["duration_s"] for r in runs.values())
    if longest_run_s < window_length_s:
        return _Outcome(
            stages=[_withheld_doc(fam, "not_enough_valid_data",
                                  observed_seconds=observed_seconds, eligible_seconds=0.0,
                                  extra=common) for fam in requested],
            coverage={f: {"observed_seconds": observed_seconds,
                          "eligible_seconds": 0.0} for f in requested},
            diagnostics={"reason_detail": "no run reaches one 4 s window"})

    # -- pipelines to run
    run_pipelines = ["tremor"] if "tremor" in requested else []
    gait_eligible = "arm_swing" in requested and gates["arm_swing"]["ok"]
    if gait_eligible:
        run_pipelines.append("gait")

    # Apply the WHOOP -> ParaDigMa rotation ONLY for the combined path
    # (the library applies its own right-side transform from watch_side).
    run_arrays: dict[str, dict] = {}
    for run_id, run in runs.items():
        accel = run["accel"]
        gyro = run["gyro"]
        if gait_eligible:
            accel = apply_rotation(accel, WHOOP5_TO_PARADIGMA)
            gyro = apply_rotation(gyro, WHOOP5_TO_PARADIGMA)
        run_arrays[run_id] = {
            "time": run["time"],
            "accel": accel,
            "gyro": gyro,
            "start_unix": run["start_unix"],
            "duration_s": run["duration_s"],
        }

    stages: list[dict] = []
    coverage: dict[str, dict] = {}
    diagnostics: dict[str, Any] = {
        "reason_detail": None,
        "upstream_commit": UPSTREAM_COMMIT,
        "native_rate_hz": meta["sampling_rate_hz"],
        "observed_seconds": observed_seconds,
        "runs": {k: {"start_unix": v["start_unix"], "duration_s": v["duration_s"],
                     "samples": v["sample_count"]} for k, v in runs.items()},
    }

    if not run_pipelines:
        # Only arm_swing was asked for and its gate failed: nothing to run.
        doc, cov, diag = _arm_swing_document(None, observed_seconds, gates["arm_swing"],
                                             watch_side, device_orientation, common)
        return _Outcome(stages=[doc], coverage={"arm_swing": cov},
                        diagnostics={**diagnostics, "arm_swing": diag})

    # -- bounded subprocess run
    ok, reason, sha256s = artifact_state()
    if not ok:
        return _Outcome(failure="artifact_unavailable", failure_detail=reason)
    try:
        runner_result = _run_subprocess(run_arrays, sha256s, run_pipelines, watch_side,
                                        gait_eligible, window_length_s, timeout_s=timeout_s)
    except subprocess.TimeoutExpired:
        return _Outcome(failure="timeout",
                        failure_detail=f"paradigma subprocess exceeded {timeout_s:.0f}s")
    except Exception as exc:  # runner crash -> the adapter is broken for this request
        return _Outcome(failure="runner_error", failure_detail=f"paradigma runner failed: {exc}")
    if not runner_result.get("ok"):
        return _Outcome(failure="runner_error",
                        failure_detail="; ".join(runner_result.get("errors") or []) or "runner not ok")

    diagnostics["runtime_versions"] = runner_result.get("versions") or {}
    if "tremor" in requested:
        doc, cov, diag = _tremor_document(runner_result.get("tremor") or {}, observed_seconds,
                                          watch_side, meta["sampling_rate_hz"], common)
        stages.append(doc)
        coverage["tremor"] = cov
        diagnostics["tremor"] = diag
    if "arm_swing" in requested:
        doc, cov, diag = _arm_swing_document(runner_result.get("arm_swing"), observed_seconds,
                                             gates["arm_swing"], watch_side, device_orientation,
                                             common)
        stages.append(doc)
        coverage["arm_swing"] = cov
        diagnostics["arm_swing"] = diag
    return _Outcome(stages=stages, coverage=coverage, diagnostics=diagnostics)


def compute_family_documents(input_payload: Mapping[str, Any], families: Sequence[str], *,
                             deadline_s: float | None = None) -> list[dict[str, Any]]:
    """tremor/arm_swing documents for ``sensor.biomarkers.v1`` (the optional-family seam).

    One document per requested family. A disabled flag, missing artifacts or a
    missing runtime come back as withheld documents with their own reason; a
    runner failure is ``adapter_broken``; a run over ``deadline_s`` is
    ``timeout`` (the subprocess is killed, the other families keep their
    results).
    """
    raw = input_payload if isinstance(input_payload, Mapping) else {}
    requested = [f for f in families if f in FAMILIES]
    if not requested:
        return []
    state = adapter_state()
    if state["state"] != STATE_READY:
        return state_documents(requested, state)
    timeout_s = _subprocess_timeout()
    if deadline_s is not None:
        timeout_s = max(0.0, min(timeout_s, deadline_s))
    outcome = _run_families(raw, requested, timeout_s=timeout_s)
    if outcome.failure == "timeout":
        return [_withheld_doc(fam, "timeout", reason_counts={"paradigma_subprocess_timeout": 1},
                              extra={"adapter": {"name": ADAPTER_NAME, "state": STATE_READY,
                                                 "detail": outcome.failure_detail}})
                for fam in requested]
    if outcome.failure == "artifact_unavailable":
        return state_documents(requested, make_state(
            ADAPTER_NAME, STATE_ARTIFACT_UNAVAILABLE, detail=outcome.failure_detail,
            detail_code="artifact_unavailable"))
    if outcome.failure is not None:
        return state_documents(requested, broken_state(
            ADAPTER_NAME, BROKEN_EXCEPTION, outcome.failure_detail or "paradigma runner failed"))
    return outcome.stages


# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

class ParadigmaProvider:
    """One sensor-biomarker research provider serving tremor + arm_swing."""

    provider_id = PROVIDER_ID
    metric = "sensor_biomarkers"
    mode = "research"
    label_space = "sensor_biomarkers.families/1"
    required_signals = ("imu",)
    eligibility_state = "research_eligible"
    eligibility_reason = (
        "real pinned ParaDigMa 1.1.2 pipeline with manifest-verified assets; "
        "portability to WHOOP remains unverified (research tier, spec section 2)"
    )

    # ------------------------------------------------------------------ API
    def versions(self, request=None) -> dict:
        return {
            "adapter": "frwhoop-inference.adapter/1.0.0",
            "provider": "paradigma/1.0.0",
            "provider_revision": "paradigma/1.0.0",
            "upstream_commit": UPSTREAM_COMMIT,
            "package": "paradigma==1.1.2",
        }

    def readiness(self) -> tuple[bool, str | None]:
        return provider_gate()

    def capability(self) -> dict:
        return {
            "provider_id": self.provider_id,
            "metric": self.metric,
            "mode": self.mode,
            "label_space": self.label_space,
            "publishable": False,
            "eligibility_state": self.eligibility_state,
            "eligibility_reason": self.eligibility_reason,
            "accuracy_label": "unverified_accuracy",
            "upstream_commit": UPSTREAM_COMMIT,
            "versions": self.versions(),
            "families": ["tremor", "arm_swing"],
            "minimum_native_rate_hz": MIN_NATIVE_RATE_HZ,
            "axis_convention_verified": WHOOP5_AXIS_CONVENTION_VERIFIED,
            "axis_evidence": WHOOP5_AXIS_EVIDENCE,
            "artifacts": list(REQUIRED_ARTIFACTS),
            "canonical_route": "sensor.biomarkers.v1",
        }

    def infer(self, request) -> Any:
        from ...contract import ProviderResult

        raw = request.input if isinstance(request.input, Mapping) else {}
        families = raw.get("families")
        families = list(families) if isinstance(families, list) else []
        requested = [f for f in families if f in FAMILIES]
        if not requested:
            return ProviderResult(
                status="ok", value=None, unit=None, stages=[], label_space=self.label_space,
                coverage={}, diagnostics={"note": "no paradigma family requested"},
                versions=self.versions(request), publishable=False,
            )
        outcome = _run_families(raw, requested, timeout_s=_subprocess_timeout())
        if outcome.failure == "artifact_unavailable":
            return self._not_ready_result(request, outcome.failure_detail)
        if outcome.failure is not None:
            return ProviderResult(
                status="withheld", value=None, unit=None,
                withheld_reason="timeout" if outcome.failure == "timeout" else "provider_error",
                diagnostics={"reason_detail": outcome.failure_detail},
                versions=self.versions(request), final_or_provisional="provisional",
                publishable=False,
            )
        return ProviderResult(
            status="ok", value=None, unit=None, stages=outcome.stages,
            label_space=self.label_space, coverage=outcome.coverage,
            diagnostics=outcome.diagnostics, versions=self.versions(request),
            publishable=False,
        )

    # ------------------------------------------------------------- internals
    def _not_ready_result(self, request, reason: str | None):
        from ...contract import ProviderResult

        return ProviderResult(
            status="withheld", value=None, unit=None,
            withheld_reason="not_ready",
            diagnostics={"reason_detail": reason},
            versions=self.versions(request), final_or_provisional="provisional",
            publishable=False,
        )


def _run_subprocess(runs: dict[str, dict], sha256s: dict[str, str],
                    pipelines: list[str], watch_side: str,
                    gait_eligible: bool, window_length_s: float, *,
                    timeout_s: float) -> dict:
    import frwhoop_inference  # package dir for runner.py location

    runner_path = os.path.join(os.path.dirname(frwhoop_inference.__file__),
                               "sensor_biomarkers", "paradigma", "runner.py")
    if not os.path.isfile(runner_path):
        raise RuntimeError(f"runner.py missing at {runner_path}")

    job: dict[str, Any] = {
        "schema_version": 1,
        "assets": {name: {"sha256": sha256s[name]} for name in REQUIRED_ARTIFACTS},
        "runs": [],
        "pipelines": pipelines,
        "watch_side": watch_side if gait_eligible else None,
        "device_orientation": ["x", "y", "z"],
        "window_length_s": float(window_length_s),
    }
    tmpdir = tempfile.mkdtemp(prefix="paradigma-provider-")
    try:
        for run_id, run in runs.items():
            npz_path = os.path.join(tmpdir, f"{run_id}.npz")
            np.savez(npz_path, time=run["time"], accel=run["accel"], gyro=run["gyro"])
            job["runs"].append({"npz_path": npz_path,
                                "start_unix": run["start_unix"],
                                "duration_s": run["duration_s"]})
        proc = subprocess.run(
            [_venv_python(), runner_path],
            input=json.dumps(job).encode("utf-8"),
            capture_output=True,
            timeout=timeout_s,
            cwd=tmpdir,
            check=False,
        )
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

    if proc.returncode != 0:
        detail = (proc.stderr or b"").decode("utf-8", "replace")[-2000:]
        raise RuntimeError(f"runner exit {proc.returncode}: {detail}")
    try:
        result = json.loads(proc.stdout.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"runner returned invalid JSON: {exc}") from exc
    if not isinstance(result, dict):
        raise RuntimeError("runner returned a non-object result")
    return result


# ---------------------------------------------------------------- family docs
def _measurement(value, *, unit, denominator, count, method) -> dict:
    return {
        "value": None if value is None else float(value),
        "unit": unit,
        "denominator": denominator,
        "count": int(count) if count is not None else None,
        "method": method,
    }


def _tremor_document(tremor: dict, observed_seconds: float, watch_side: str,
                     native_rate_hz: float, common: dict) -> tuple[dict, dict, dict]:
    windows_total = int(tremor.get("windows_total", 0))
    if windows_total == 0:
        doc = _withheld_doc("tremor", "not_enough_valid_data",
                            observed_seconds=observed_seconds, eligible_seconds=0.0,
                            extra=common)
        return doc, {"observed_seconds": observed_seconds, "eligible_seconds": 0.0}, {}

    windows_at_rest = int(tremor.get("windows_at_rest", 0))
    windows_tremor = int(tremor.get("windows_tremor", 0))
    eligible_rest_seconds = float(tremor.get("eligible_rest_seconds", 0.0))
    classified_seconds = float(tremor.get("classified_tremor_seconds", 0.0))
    percent = tremor.get("rest_tremor_time_percent")
    freq = tremor.get("tremor_frequency_median_hz")
    power = tremor.get("tremor_power_median")

    measurements = {
        "eligible_rest_seconds": _measurement(
            eligible_rest_seconds, unit="s",
            denominator="arm-at-rest 4 s windows", count=windows_at_rest,
            method="paradigma/1.1.2 pred_arm_at_rest (below_tremor_power <= 50)"),
        "classified_tremor_seconds": _measurement(
            classified_seconds, unit="s",
            denominator="arm-at-rest 4 s windows", count=windows_tremor,
            method="paradigma/1.1.2 pred_tremor_checked (threshold 0.02957 + 3-7 Hz peak gate)"),
        "rest_tremor_time_percent": _measurement(
            percent, unit="%",
            denominator="eligible arm-at-rest seconds", count=windows_at_rest,
            method="100 * classified_tremor_seconds / eligible_rest_seconds; "
                   "null when eligible duration is zero"),
        "tremor_frequency_median_hz": _measurement(
            freq, unit="Hz",
            denominator="classified tremor windows", count=windows_tremor,
            method="median of upstream freq_peak (PSD peak, 1-25 Hz search)"),
        "paradigma_tremor_power_median": _measurement(
            power, unit="(deg/s)^2",
            denominator="classified tremor windows", count=windows_tremor,
            method="median of upstream tremor_power (linear PSD, 1.25 Hz band "
                   "around 3-7 Hz peak); upstream aggregation logs it as log10(x+1)"),
    }
    reason_counts = _integer_counts(tremor.get("reason_counts"))
    doc = family_document(
        family="tremor", status="ok", measurements=measurements,
        observed_seconds=observed_seconds, eligible_seconds=eligible_rest_seconds,
        contact_state="unknown", reason_counts=reason_counts,
        extra={
            "window_length_s": 4.0,
            "native_rate_hz": native_rate_hz,
            "quantification_parity_with_orchestrator": tremor.get(
                "quantification_parity_with_orchestrator"),
            **common,
        },
    )
    diag = {
        "windows_total": windows_total,
        "windows_at_rest": windows_at_rest,
        "windows_tremor": windows_tremor,
        "score_distribution": tremor.get("score_distribution"),
        "freq_peak_distribution": tremor.get("freq_peak_distribution"),
        "reason_counts": reason_counts,
        "tremor_power_unit": tremor.get("tremor_power_unit"),
        "watch_side": watch_side,
    }
    return doc, {"observed_seconds": observed_seconds,
                 "eligible_seconds": eligible_rest_seconds}, diag


def _integer_counts(counts: Any) -> dict[str, int]:
    """Only whole counts belong in ``reason_counts`` (the lane and the contract read integers)."""
    out: dict[str, int] = {}
    for key, value in (counts or {}).items():
        if isinstance(value, bool):
            continue
        if isinstance(value, int) or (isinstance(value, float) and value.is_integer()):
            out[str(key)] = int(value)
    return out


def _arm_swing_document(arm_swing: dict | None, observed_seconds: float,
                        gate: dict, watch_side: str, device_orientation: str,
                        common: dict) -> tuple[dict, dict, dict]:
    if arm_swing is None or not gate.get("ok"):
        reason = gate.get("reason") or "unknown_orientation"
        doc = _withheld_doc("arm_swing", reason, observed_seconds=observed_seconds,
                            eligible_seconds=0.0, extra=common)
        diag = {"watch_side": watch_side, "device_orientation": device_orientation,
                "axis_convention_verified": WHOOP5_AXIS_CONVENTION_VERIFIED,
                "axis_evidence": WHOOP5_AXIS_EVIDENCE,
                "reason_detail": gate.get("reason")}
        return doc, {"observed_seconds": observed_seconds, "eligible_seconds": 0.0}, diag

    eligible_seconds = float(arm_swing.get("eligible_arm_swing_seconds", 0.0))
    bout_count = int(arm_swing.get("arm_swing_bout_count", 0))
    raw_counts = arm_swing.get("reason_counts") or {}
    # Segment seconds are exposure, not counts: they travel beside the counts.
    exposure = {key: float(raw_counts[key]) for key in ("filtered_seconds", "unfiltered_seconds")
                if isinstance(raw_counts.get(key), (int, float))}
    counts = _integer_counts({k: v for k, v in raw_counts.items() if k not in exposure})
    extra = {**common, "exposure": exposure}
    if bout_count == 0:
        doc = family_document(
            family="arm_swing", status="ok", measurements={
                "eligible_arm_swing_seconds": _measurement(
                    0.0, unit="s", denominator="filtered clean-gait segments",
                    count=0, method="paradigma/1.1.2 gait pipeline filtered quantification"),
                "arm_swing_bout_count": _measurement(
                    0, unit="count", denominator="filtered gait segments", count=0,
                    method="paradigma/1.1.2 filtered segments with measured arm swing"),
            },
            observed_seconds=observed_seconds, eligible_seconds=0.0,
            contact_state="unknown", reason_counts=counts, extra=extra,
        )
        return doc, {"observed_seconds": observed_seconds,
                     "eligible_seconds": 0.0}, {"status": "no_clean_gait"}

    measurements = {
        "eligible_arm_swing_seconds": _measurement(
            eligible_seconds, unit="s",
            denominator="filtered (clean-gait) arm swing segments", count=bout_count,
            method="paradigma/1.1.2 gait pipeline filtered segment durations"),
        "arm_swing_bout_count": _measurement(
            bout_count, unit="count",
            denominator="filtered gait segments", count=bout_count,
            method="paradigma/1.1.2 filtered segments with measured arm swing"),
        "arm_swing_rom_median_deg": _measurement(
            arm_swing.get("arm_swing_rom_median_deg"), unit="deg",
            denominator="half arm-swing cycles in filtered segments",
            count=arm_swing.get("rom_cycle_count"),
            method="median over upstream range_of_motion (filtered)"),
        "arm_swing_rom_p95_deg": _measurement(
            arm_swing.get("arm_swing_rom_p95_deg"), unit="deg",
            denominator="half arm-swing cycles in filtered segments",
            count=arm_swing.get("rom_cycle_count"),
            method="p95 over upstream range_of_motion (filtered)"),
        "arm_swing_peak_velocity_median_dps": _measurement(
            arm_swing.get("arm_swing_peak_velocity_median_dps"), unit="deg/s",
            denominator="half arm-swing cycles in filtered segments",
            count=arm_swing.get("pav_cycle_count"),
            method="median over upstream peak_velocity (filtered)"),
        "arm_swing_peak_velocity_p95_dps": _measurement(
            arm_swing.get("arm_swing_peak_velocity_p95_dps"), unit="deg/s",
            denominator="half arm-swing cycles in filtered segments",
            count=arm_swing.get("pav_cycle_count"),
            method="p95 over upstream peak_velocity (filtered)"),
    }
    doc = family_document(
        family="arm_swing", status="ok", measurements=measurements,
        observed_seconds=observed_seconds, eligible_seconds=eligible_seconds,
        contact_state="unknown", reason_counts=counts, extra=extra,
    )
    diag = {
        "unfiltered_seconds": arm_swing.get("unfiltered_seconds"),
        "unfiltered_bout_count": arm_swing.get("unfiltered_bout_count"),
        "watch_side": watch_side,
        "device_orientation": device_orientation,
        "axis_convention_verified": WHOOP5_AXIS_CONVENTION_VERIFIED,
    }
    return doc, {"observed_seconds": observed_seconds,
                 "eligible_seconds": eligible_seconds}, diag
