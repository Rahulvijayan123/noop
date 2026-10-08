"""Persistent activity-context service — line-delimited JSON over stdin/stdout.

C10 serve protocol (FINAL):
  Request : {"id":"<uuid>","op":"infer","run":{...}} | ping | shutdown
  Response: {"id":..,"ok":true,"windows":[{s,e,label,probs,baseline,feat}],...}
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|timeout|internal|output_too_large"}

Additive since the ActivityContext decoder (all optional, old callers unaffected):
  * every window carries ``feat`` (imu-feat-2, see features.py): encoder-independent motion facts;
  * every window carries ``calibrated`` (A01) and the response carries ``calibrated`` /
    ``calibration_version`` derived from the manifest's calibration artifact (absent today -> false);
  * ``run.hop_s`` (or request ``hop_s``) may be 1 or 2 (default 2, the training hop). The window length is
    always 4 s, so a 1 s hop only changes how often the encoder is asked, never what it is asked.

Deterministic: single thread, eval mode, fixed seed, no dropout. Baseline path
runs with zero optional deps (numpy only); the HART path is loaded only when
the manifest says model_kind=hart and is reported "unavailable" (kind
model_missing) otherwise.

``ping`` also reports ``loaded`` (loaded.py): the sha256 of the manifest, checkpoint, config and transition
artifact this process actually loaded, of its own code, and its thread settings, with ``loaded_digest`` over them;
every infer response repeats ``loaded_digest``, so the worker can tell an answer from a process that loaded other
bytes. ``--threads`` (default ``$ACTIVITY_THREADS`` or 1) caps torch's intra-op threads; inter-op is always one.

Run:  python -m activity_context.serve --manifest manifest.json --checkpoint ./checkpoint
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import traceback
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from . import PREPROCESSING_VERSION, __version__
from .baseline import MOTION_LABELS, classify_window
from .features import FEATURE_SCHEMA, window_features
from .loaded import base_loaded, configure_torch_threads, file_sha256, loaded_digest
from .manifest import Manifest, load_manifest
from .model_names import FINE_SCHEMA
from .preprocess import (COLUMNS_BYTES_PER_SECOND, HOP_SAMPLES, MAX_HEAD_SECONDS,
                         MAX_RUN_SECONDS, MAX_TAIL_SECONDS, TARGET_HZ,
                         WINDOW_SECONDS, HOP_SECONDS, WHOOP_SAMPLE_COUNT,
                         decode_columns_b64, validate_request_units)

# Hard output bound: a single infer response must stay under this many bytes
# and this many windows (strict bounded payload, C10).
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_WINDOWS_PER_RESPONSE = 200_000
DEFAULT_TIMEOUT_SECONDS = 60.0

# Hops a caller may ask for, in seconds. 2 s is the training hop; 1 s doubles the encoder calls for a
# denser stream. Anything else is refused rather than silently rounded.
ALLOWED_HOP_SECONDS = (1.0, 2.0)

_ERROR_KINDS = ("malformed", "model_missing", "timeout", "internal", "output_too_large")


class _RequestTimeout(Exception):
    pass


def _alarm_timeout(seconds: float):
    if hasattr(signal, "setitimer"):
        signal.setitimer(signal.ITIMER_REAL, seconds)


@dataclass
class ServeContext:
    manifest: Manifest
    checkpoint_dir: str
    timeout: float
    model: Any = None
    model_status: str = "baseline"
    model_error: Optional[str] = None
    # Optional learned transition expert (spec: ONE additional evidence channel).
    # Absent manifest section -> transition_absent (channel simply not emitted).
    # Present but unloadable -> transition_unavailable: SOFT failure, the general
    # activity path is untouched, and every window still gets its label/probs/feat
    # (spec s21: a broken transition artifact must never take the lane down).
    transition: Any = None
    transition_status: str = "transition_absent"
    transition_error: Optional[str] = None
    transition_version: Optional[str] = None
    # Optional ElderNet gait expert (gait-quality-1, ELDERNET.md). OFF unless the operator opts in
    # (--gait-expert eldernet / ACTIVITY_GAIT_EXPERT=eldernet): the Oxford weights are academic-use only.
    # Disabled -> gait_absent and this process never imports torch for it; enabled but unloadable ->
    # gait_unavailable, a soft failure exactly like the transition expert.
    gait: Any = None
    gait_status: str = "gait_absent"
    gait_error: Optional[str] = None
    # What was actually loaded (loaded.py), measured at start-up; ``loaded_digest`` is its digest.
    loaded: Dict[str, str] = None  # type: ignore[assignment]
    loaded_digest: str = ""
    manifest_sha256: Optional[str] = None
    transition_sha256: Optional[str] = None
    threads: int = 1


GAIT_EXPERTS = ("eldernet",)


def build_context(manifest_path: Optional[str], checkpoint_dir: Optional[str],
                  timeout: float = DEFAULT_TIMEOUT_SECONDS,
                  gait_expert: Optional[str] = None, gait_runtime: Any = None,
                  threads: int = 1) -> ServeContext:
    # An explicitly requested manifest that is missing or unreadable is a
    # CONFIGURATION ERROR, never a silent baseline fallback: a misconfigured
    # model dir must fail loudly (model_missing) instead of publishing
    # heuristic windows stamped as the HART version.
    if manifest_path:
        if not os.path.isfile(manifest_path):
            from .manifest import ManifestError
            raise ManifestError(f"manifest not found: {manifest_path}")
        manifest = load_manifest(manifest_path)
    else:
        from .manifest import default_manifest
        manifest = default_manifest(model_version="baseline-v0", model_kind="baseline")
        manifest.model_kind = "baseline"
    ctx = ServeContext(manifest=manifest,
                       checkpoint_dir=checkpoint_dir or ".",
                       timeout=timeout, threads=max(1, int(threads)))
    ctx.manifest_sha256 = file_sha256(manifest_path) if manifest_path else None
    if manifest.model_kind == "hart":
        try:
            from .model import HARTModel
            if not checkpoint_dir or not os.path.isdir(checkpoint_dir):
                raise FileNotFoundError(checkpoint_dir or ".")
            configure_torch_threads(ctx.threads)
            ctx.model = HARTModel(manifest, checkpoint_dir)
            ctx.model_status = "hart_loaded"
        except Exception as exc:
            ctx.model_status = "hart_unavailable"
            ctx.model_error = f"{type(exc).__name__}: {exc}"
    _load_transition(ctx, manifest, checkpoint_dir)
    _load_gait(ctx, gait_expert, gait_runtime)
    if ctx.model is not None or ctx.gait is not None:
        # Loading sets torch to one thread; the configured cap is applied last so it is the one in force.
        configure_torch_threads(ctx.threads)
    ctx.loaded = loaded_identity(ctx)
    ctx.loaded_digest = loaded_digest(ctx.loaded)
    return ctx


def loaded_identity(ctx: ServeContext) -> Dict[str, str]:
    """The ``loaded`` map (loaded.py): only what this process actually holds, each digest measured from its bytes."""
    out = base_loaded(ctx.threads if (ctx.model is not None or ctx.gait is not None) else None)
    out["model_kind"] = "hart" if ctx.model is not None else "baseline"
    out["model_version"] = ctx.manifest.model_version
    out["preprocessing_version"] = ctx.manifest.preprocessing_version
    out["manifest_sha256"] = ctx.manifest_sha256 or "default"
    if ctx.model is not None:
        out["checkpoint_sha256"] = ctx.model.checkpoint_sha256
        if ctx.model.config_sha256:
            out["config_sha256"] = ctx.model.config_sha256
    if ctx.transition is not None and ctx.transition_sha256:
        out["transition_sha256"] = ctx.transition_sha256
        out["transition_version"] = str(ctx.transition_version)
    if ctx.gait is not None:
        digest = getattr(ctx.gait, "weights_digest", None)
        if digest:
            out["gait_weights_digest"] = digest
        from .eldernet import MODEL_VERSION as GAIT_MODEL_VERSION
        out["gait_model_version"] = GAIT_MODEL_VERSION
    return out


def _load_gait(ctx: ServeContext, expert: Optional[str], runtime: Any = None) -> None:
    """Attach the opt-in gait expert. ``runtime`` injects a pre-built ElderNetRuntime (tests)."""
    if runtime is None and not expert:
        return
    try:
        if runtime is None:
            if expert not in GAIT_EXPERTS:
                raise ValueError(f"unknown gait expert {expert!r} (expected one of {list(GAIT_EXPERTS)})")
            from .eldernet.runtime import build_runtime
            runtime = build_runtime()
        if not runtime.available:
            err = runtime.error
            raise RuntimeError(f"{err.kind}: {err.message}" if err is not None else "ElderNet runtime not loaded")
        ctx.gait = runtime
        ctx.gait_status = "gait_loaded"
    except Exception as exc:
        ctx.gait = None
        ctx.gait_status = "gait_unavailable"
        ctx.gait_error = f"{type(exc).__name__}: {exc}"


def _load_transition(ctx: ServeContext, manifest: Manifest, checkpoint_dir: Optional[str]) -> None:
    """Load the OPTIONAL transition expert; any failure is a soft status, never fatal.

    The artifact is looked up as ``transition.json.gz`` inside --checkpoint (the
    model dir), or an explicit ``artifact`` path in the manifest's transition
    section. A missing/unreadable/mismatched artifact leaves the general model
    untouched and every window without a ``transition`` field.
    """
    section = manifest.transition
    if not section:
        return  # absent == not configured == today's behavior
    try:
        from .transition_model import TransitionModel, TransitionModelError
        art = section.get("artifact") or os.path.join(checkpoint_dir or ".", "transition.json.gz")
        if not os.path.isfile(art):
            raise FileNotFoundError(art)
        ctx.transition_sha256 = file_sha256(art)
        ctx.transition = TransitionModel.load(art)
        ctx.transition_version = ctx.transition.model_version
        ctx.transition_status = "transition_loaded"
    except Exception as exc:
        ctx.transition = None
        ctx.transition_status = "transition_unavailable"
        ctx.transition_error = f"{type(exc).__name__}: {exc}"


def _bounded_b64_list(value: Any, what: str, max_seconds: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ValueError(f"{what} must be a list of base64 strings")
    if len(value) > max_seconds:
        raise ValueError(f"{what} exceeds {max_seconds} seconds")
    return value


def parse_hop_samples(value: Any) -> int:
    """Hop in 30 Hz samples from an optional ``hop_s`` request value (None -> the training hop)."""
    if value is None:
        return HOP_SAMPLES
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"hop_s must be 1 or 2, got {value!r}")
    if float(value) not in ALLOWED_HOP_SECONDS:
        raise ValueError(f"hop_s must be 1 or 2, got {value!r}")
    return int(round(float(value) * TARGET_HZ))


def decode_request_seconds(start_ts: int, end_ts: int, body: List[str], head: List[str],
                           tail: List[str]) -> List[tuple]:
    """(ts, int16 columns) for head (the seconds just before start_ts), body and tail, chronological."""
    seconds: List[tuple] = []
    for i, b in enumerate(head):
        seconds.append((start_ts - len(head) + i, decode_columns_b64(b)))
    for i, b in enumerate(body):
        seconds.append((start_ts + i, decode_columns_b64(b)))
    for i, b in enumerate(tail):
        seconds.append((end_ts + i, decode_columns_b64(b)))
    return seconds


def classify_windows(ctx: ServeContext, start_ts: int, end_ts: int,
                     body: List[str], head: List[str], tail: List[str],
                     hop_samples: int = HOP_SAMPLES, seconds: Optional[List[tuple]] = None,
                     ) -> List[Dict[str, Any]]:
    """Decode -> runs -> windows -> per-window labels (baseline or HART) + imu-feat-2 features."""
    from .preprocess import windows_from_run, decode_seconds, PreprocessError, Run

    if seconds is None:
        seconds = decode_request_seconds(start_ts, end_ts, body, head, tail)

    # (window, native-rate slice) pairs: the transition expert consumes the ORIGINAL
    # 100 Hz samples the resampler ate, so its features keep the transient peaks the
    # 4 s / 30 Hz windows smooth away (the expert is trained on native-rate windows).
    pairs: List[Tuple[Any, Optional[np.ndarray]]] = []
    for run in decode_seconds(seconds):
        hz = WHOOP_SAMPLE_COUNT  # 100 Hz runs, one second of samples per run second
        for w in windows_from_run(run, start_ts, end_ts, hop_samples=hop_samples):
            i0 = int(round((w.s - run.start_ts) * hz))
            i1 = int(round((w.e - run.start_ts) * hz))
            native = run.samples[i0:i1] if 0 <= i0 < i1 <= run.samples.shape[0] else None
            pairs.append((w, native))
    pairs.sort(key=lambda p: p[0].s)
    if len(pairs) > MAX_WINDOWS_PER_RESPONSE:
        raise ValueError("too many windows for one response")

    out: List[Dict[str, Any]] = []
    for w, native in pairs:
        base_features = None
        fine = None
        if ctx.model is not None:
            pred = ctx.model.predict_window(w.data)
            label, probs, baseline = pred.label, pred.probs, pred.baseline
            calibrated = pred.calibrated          # A01: from the manifest artifact
            fine = getattr(pred, "fine_probs", None)
        else:
            res = classify_window(w)
            label, probs, baseline = res.label, res.probs, True
            # A01: calibrated comes from the manifest's calibration artifact, never from
            # model_kind or the baseline flag (absent today -> False everywhere).
            calibrated = ctx.manifest.calibrated
            base_features = res.features
        row = {
            "s": round(w.s, 6),
            "e": round(w.e, 6),
            "label": label,
            "probs": {k: round(float(v), 6) for k, v in probs.items()},
            "baseline": baseline,
            "calibrated": calibrated,
            "feat": window_features(w, base_features),
        }
        if fine:
            row["fine"] = {k: round(float(v), 6) for k, v in fine.items()}
        transition_row = _transition_evidence(ctx, w, native)
        if transition_row is not None:
            row["transition"] = transition_row
        out.append(row)
    return out


def _transition_evidence(ctx: ServeContext, w: Any, native: Optional[np.ndarray]) -> Optional[Dict[str, Any]]:
    """Per-window learned transition evidence, or None when the expert is not usable.

    Fail-open by construction: an unavailable expert, a window without a native-rate
    slice, or ANY exception while computing it returns None and the window keeps its
    general fields only (spec s21). The 100 Hz timestamp refinement rides along only
    for non-none, non-abstaining predictions (spec s9).
    """
    if ctx.transition is None or native is None or native.shape[0] < 8:
        return None
    try:
        from .transition_features import window_transition_features
        from .transition_refine import refine_event_ts
        pred = ctx.transition.predict_window(native, float(WHOOP_SAMPLE_COUNT))
        row: Dict[str, Any] = {
            "probs": {k: round(float(v), 6) for k, v in pred.probs.items()},
            "label": pred.label,
            "confidence": round(float(pred.confidence), 6),
            "abstained": bool(pred.abstained),
        }
        if pred.label not in ("none", "unknown") and not pred.abstained:
            refined = refine_event_ts(native, float(WHOOP_SAMPLE_COUNT), float(w.s), pred.label)
            if refined is not None:
                row["ts"] = round(float(refined.ts), 3)
                row["ts_quality"] = round(float(refined.quality), 4)
        return row
    except Exception:
        return None


def gait_evidence(ctx: ServeContext, seconds: List[tuple], start_ts: int, end_ts: int) -> Optional[Dict[str, Any]]:
    """ElderNet ``gait-quality-1`` windows for the request's own seconds, or None when the expert is off.

    Fail-open like the transition expert: an exception yields ``gait_status: gait_failed`` and no windows,
    and the HART windows in the same response are untouched. ElderNet reads accelerometer only (30 Hz
    nearest-neighbour, 10 s windows, gravity kept), on the same decoded seconds HART just used.
    """
    if ctx.gait is None:
        return None
    from .eldernet import MODEL_VERSION, WIRE_SCHEMA, WINDOW_S
    from .eldernet.gait import wire_windows
    from .eldernet.runtime import score_request_seconds
    rt = ctx.gait
    try:
        windows, scores = score_request_seconds(rt, seconds, start_ts, end_ts, rt.default_hop_s)
        rows, dropped = wire_windows(windows, scores) if windows else ([], 0)
    except Exception as exc:
        return {"gait_status": "gait_failed", "gait_error": f"{type(exc).__name__}: {exc}"}
    return {
        "gait_status": "gait_loaded", "gait_schema": WIRE_SCHEMA, "gait_model_version": MODEL_VERSION,
        "gait_window_s": WINDOW_S, "gait_hop_s": rt.default_hop_s, "gait_threshold": rt.gait_threshold,
        "gait_windows": rows, "gait_dropped_nonfinite": dropped,
    }


def handle_ping(ctx: ServeContext) -> Dict[str, Any]:
    versions: Dict[str, Any] = {
        "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "numpy": np.__version__,
    }
    try:
        import torch  # noqa: F401
        versions["torch"] = torch.__version__
    except Exception:
        versions["torch"] = None
    out = {
        "ok": True,
        "model_status": ctx.model_status,
        "model_error": ctx.model_error,
        "model_version": ctx.manifest.model_version,
        "preprocessing_version": ctx.manifest.preprocessing_version,
        # A01: calibration status comes from the manifest artifact, not model_kind.
        "calibrated": ctx.manifest.calibrated,
        "calibration_version": ctx.manifest.calibration_version,
        "package_version": __version__,
        "versions": versions,
        "transition_status": ctx.transition_status,
        "transition_error": ctx.transition_error,
        "transition_version": ctx.transition_version,
        "fine_schema": FINE_SCHEMA if getattr(ctx.model, "fine_names", None) else None,
        "gait_status": ctx.gait_status,
        "gait_error": ctx.gait_error,
        "loaded": ctx.loaded,
        "loaded_digest": ctx.loaded_digest,
    }
    if ctx.gait is not None:
        from .eldernet import MODEL_VERSION as GAIT_MODEL_VERSION, WIRE_SCHEMA as GAIT_SCHEMA
        out["gait_schema"] = GAIT_SCHEMA
        out["gait_model_version"] = GAIT_MODEL_VERSION
    return out


def handle_infer(ctx: ServeContext, req: Dict[str, Any]) -> Dict[str, Any]:
    run = req.get("run")
    if not isinstance(run, dict):
        raise ValueError("infer requires an object 'run'")
    start_ts = run.get("start_ts")
    end_ts = run.get("end_ts")
    if not isinstance(start_ts, int) or not isinstance(end_ts, int) \
            or start_ts < 0 or end_ts <= start_ts:
        raise ValueError("run.start_ts/end_ts must be ints with start_ts < end_ts")
    if end_ts - start_ts > MAX_RUN_SECONDS:
        raise ValueError(f"run longer than {MAX_RUN_SECONDS} s")
    if run.get("sample_rate_hz") not in (None, 100):
        raise ValueError(f"only 100 Hz input is supported, got {run.get('sample_rate_hz')!r}")
    channels = run.get("channels_order")
    if channels is not None:
        if not isinstance(channels, list) or list(channels) != ["ax", "ay", "az", "gx", "gy", "gz"]:
            raise ValueError("channels_order must be [ax,ay,az,gx,gy,gz]")
    validate_request_units(run.get("units") or {"accel": "g", "gyro": "deg/s"})

    body = _bounded_b64_list(run.get("columns_b64"), "columns_b64", MAX_RUN_SECONDS)
    if not body:
        raise ValueError("run.columns_b64 must contain at least one second")
    if len(body) != end_ts - start_ts:
        raise ValueError(
            f"columns_b64 count {len(body)} != end_ts - start_ts ({end_ts - start_ts})")

    if ctx.model is None and ctx.manifest.model_kind == "hart":
        # configured for HART but not loadable -> model_missing (never silently baseline)
        raise _ModelMissing(ctx.model_error or "HART model unavailable")

    # Boundary filter state may ride inside `run` (this service's native shape) or at the
    # request's top level (the C10 contract's original wording). Both are accepted; the
    # inside-run shape wins when both are present. Only contiguous boundary seconds are
    # ever meaningful — a gap between the boundary and the run body is checked downstream.
    head = _bounded_b64_list(run.get("head_b64") if run.get("head_b64") is not None
                             else req.get("head_b64"), "head_b64", MAX_HEAD_SECONDS)
    tail = _bounded_b64_list(run.get("tail_b64") if run.get("tail_b64") is not None
                             else req.get("tail_b64"), "tail_b64", MAX_TAIL_SECONDS)

    hop_samples = parse_hop_samples(run.get("hop_s") if run.get("hop_s") is not None else req.get("hop_s"))

    t0 = time.monotonic()
    seconds = decode_request_seconds(start_ts, end_ts, body, head, tail)
    windows = classify_windows(ctx, start_ts, end_ts, body, head, tail, hop_samples=hop_samples,
                               seconds=seconds)
    gait = gait_evidence(ctx, seconds, start_ts, end_ts)

    resp: Dict[str, Any] = {
        "ok": True,
        "model_version": ctx.manifest.model_version,
        "preprocessing_version": ctx.manifest.preprocessing_version,
        "feature_schema": FEATURE_SCHEMA,
        "hop_s": hop_samples / TARGET_HZ,
        # A01: calibration status is derived from the manifest's calibration
        # artifact (absent today -> False), never from model_kind.
        "calibrated": ctx.manifest.calibrated,
        "calibration_version": ctx.manifest.calibration_version,
        "windows": windows,
        "manifest": ctx.manifest.to_dict(),
        "loaded_digest": ctx.loaded_digest,
        "duration_ms": int((time.monotonic() - t0) * 1000),
    }
    if ctx.transition is not None:
        # Versioned stamp for the additive transition field: callers gate on it
        # (the Swift reader pattern — unknown schema -> drop, never fail).
        resp["transition_schema"] = "transition-1"
        resp["transition_version"] = ctx.transition_version
    if any("fine" in w for w in windows):
        resp["fine_schema"] = FINE_SCHEMA
    if gait is not None:
        resp.update(gait)
    resp["duration_ms"] = int((time.monotonic() - t0) * 1000)
    raw = json.dumps(resp, separators=(",", ":"), default=_json_default)
    if len(raw.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise ValueError("response exceeds hard output size cap")
    return resp


class _ModelMissing(Exception):
    pass


def _json_default(o):
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return float(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    raise TypeError(f"not JSON serializable: {type(o)}")


def handle_request(ctx: ServeContext, req: Dict[str, Any]) -> Dict[str, Any]:
    req_id = req.get("id")
    op = req.get("op")
    if not isinstance(req_id, str) or not req_id:
        raise ValueError("request needs a string 'id'")
    if op == "ping":
        resp = handle_ping(ctx)
        resp["id"] = req_id
        resp["op"] = "ping"
        return resp
    if op == "infer":
        resp = handle_infer(ctx, req)
        resp["id"] = req_id
        resp["op"] = "infer"
        return resp
    if op == "shutdown":
        return {"id": req_id, "op": "shutdown", "ok": True}
    raise ValueError(f"unknown op {op!r} (expected ping|infer|shutdown)")


def _error(req_id: str, kind: str, message: str) -> Dict[str, Any]:
    if kind not in _ERROR_KINDS:
        kind = "internal"
    return {"id": req_id, "ok": False, "error": message, "kind": kind}


def serve_forever(ctx: ServeContext) -> int:
    if hasattr(signal, "SIGALRM"):

        def _on_alarm(signum, frame):
            raise _RequestTimeout("request timed out")

        signal.signal(signal.SIGALRM, _on_alarm)

    sys.stdout.reconfigure(line_buffering=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request must be a JSON object")
        except (json.JSONDecodeError, ValueError) as exc:
            sys.stdout.write(json.dumps(_error(None, "malformed",
                                               f"request line is not valid JSON: {exc}"))
                             + "\n")
            sys.stdout.flush()
            continue
        req_id = req.get("id")
        op = req.get("op")
        try:
            if op == "shutdown":
                resp = handle_request(ctx, req)
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()
                return 0
            _alarm_timeout(ctx.timeout)
            try:
                resp = handle_request(ctx, req)
            finally:
                _alarm_timeout(0.0)
            sys.stdout.write(json.dumps(resp, default=_json_default) + "\n")
            sys.stdout.flush()
        except _RequestTimeout:
            sys.stdout.write(json.dumps(_error(req_id, "timeout",
                                               f"request exceeded {ctx.timeout:.0f}s"))
                             + "\n")
            sys.stdout.flush()
        except _ModelMissing as exc:
            sys.stdout.write(json.dumps(_error(req_id, "model_missing", str(exc))) + "\n")
            sys.stdout.flush()
        except ValueError as exc:
            sys.stdout.write(json.dumps(_error(req_id, "malformed", str(exc))) + "\n")
            sys.stdout.flush()
        except Exception as exc:  # noqa: BLE001 - protocol boundary
            sys.stdout.write(json.dumps(_error(
                req_id, "internal", f"internal error: {exc}")) + "\n")
            sys.stdout.flush()
    return 0


def _env_threads() -> int:
    raw = os.environ.get("ACTIVITY_THREADS", "").strip()
    try:
        return max(1, int(raw)) if raw else 1
    except ValueError:
        return 1


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara activity-context serve process (C10)")
    ap.add_argument("--manifest", default=None, help="path to manifest.json")
    ap.add_argument("--checkpoint", default=None, help="dir containing model.safetensors")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
                    help="per-request timeout in seconds")
    ap.add_argument("--gait-expert", choices=GAIT_EXPERTS, default=os.environ.get("ACTIVITY_GAIT_EXPERT") or None,
                    help="opt-in gait expert (eldernet: Oxford academic-use weights via ELDERNET_WEIGHTS_DIR / "
                         "ELDERNET_UPSTREAM_DIR); default off. The worker never enables it: its ElderNet runs as "
                         "its own service (one route per model)")
    ap.add_argument("--threads", type=int, default=_env_threads(),
                    help="torch intra-op threads (default $ACTIVITY_THREADS or 1); inter-op is always 1")
    args = ap.parse_args(argv)
    try:
        ctx = build_context(args.manifest, args.checkpoint, args.timeout, gait_expert=args.gait_expert,
                            threads=args.threads)
    except Exception as exc:
        # Configuration error (e.g. an explicitly requested manifest that is
        # missing): exit with a single JSON diagnostic line so the parent
        # lane treats it as model_unavailable, never a silent baseline.
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}",
                          "kind": "model_missing"}), flush=True)
        return 3
    return serve_forever(ctx)


if __name__ == "__main__":
    sys.exit(main())
