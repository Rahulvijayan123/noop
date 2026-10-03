"""Persistent activity-context service — line-delimited JSON over stdin/stdout.

C10 serve protocol (FINAL):
  Request : {"id":"<uuid>","op":"infer","run":{...}} | ping | shutdown
  Response: {"id":..,"ok":true,"windows":[{s,e,label,probs,baseline}],...}
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|timeout|internal|output_too_large"}

Deterministic: single thread, eval mode, fixed seed, no dropout. Baseline path
runs with zero optional deps (numpy only); the HART path is loaded only when
the manifest says model_kind=hart and is reported "unavailable" (kind
model_missing) otherwise.

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
from typing import Any, Dict, List, Optional

import numpy as np

from . import PREPROCESSING_VERSION, __version__
from .baseline import MOTION_LABELS, classify_window
from .manifest import Manifest, load_manifest
from .preprocess import (COLUMNS_BYTES_PER_SECOND, MAX_HEAD_SECONDS,
                         MAX_RUN_SECONDS, MAX_TAIL_SECONDS, TARGET_HZ,
                         WINDOW_SECONDS, HOP_SECONDS, decode_columns_b64,
                         validate_request_units)

# Hard output bound: a single infer response must stay under this many bytes
# and this many windows (strict bounded payload, C10).
MAX_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_WINDOWS_PER_RESPONSE = 200_000
DEFAULT_TIMEOUT_SECONDS = 60.0

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


def build_context(manifest_path: Optional[str], checkpoint_dir: Optional[str],
                  timeout: float = DEFAULT_TIMEOUT_SECONDS) -> ServeContext:
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
                       timeout=timeout)
    if manifest.model_kind == "hart":
        try:
            from .model import HARTModel
            if not checkpoint_dir or not os.path.isdir(checkpoint_dir):
                raise FileNotFoundError(checkpoint_dir or ".")
            ctx.model = HARTModel(manifest, checkpoint_dir)
            ctx.model_status = "hart_loaded"
        except Exception as exc:
            ctx.model_status = "hart_unavailable"
            ctx.model_error = f"{type(exc).__name__}: {exc}"
    return ctx


def _bounded_b64_list(value: Any, what: str, max_seconds: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ValueError(f"{what} must be a list of base64 strings")
    if len(value) > max_seconds:
        raise ValueError(f"{what} exceeds {max_seconds} seconds")
    return value


def classify_windows(ctx: ServeContext, start_ts: int, end_ts: int,
                     body: List[str], head: List[str], tail: List[str],
                     ) -> List[Dict[str, Any]]:
    """Decode -> runs -> windows -> per-window labels (baseline or HART)."""
    from .preprocess import windows_from_run, decode_seconds, PreprocessError, Run

    seconds: List[tuple] = []
    # head: the len(head) seconds immediately before start_ts, chronological.
    for i, b in enumerate(head):
        seconds.append((start_ts - len(head) + i, decode_columns_b64(b)))
    for i, b in enumerate(body):
        seconds.append((start_ts + i, decode_columns_b64(b)))
    for i, b in enumerate(tail):
        seconds.append((end_ts + i, decode_columns_b64(b)))

    windows: List[Any] = []
    for run in decode_seconds(seconds):
        windows.extend(windows_from_run(run, start_ts, end_ts))
    windows.sort(key=lambda w: w.s)
    if len(windows) > MAX_WINDOWS_PER_RESPONSE:
        raise ValueError("too many windows for one response")

    out: List[Dict[str, Any]] = []
    for w in windows:
        if ctx.model is not None:
            pred = ctx.model.predict_window(w.data)
            label, probs, baseline = pred.label, pred.probs, pred.baseline
        else:
            res = classify_window(w)
            label, probs, baseline = res.label, res.probs, True
        out.append({
            "s": round(w.s, 6),
            "e": round(w.e, 6),
            "label": label,
            "probs": {k: round(float(v), 6) for k, v in probs.items()},
            "baseline": baseline,
        })
    return out


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
    return {
        "ok": True,
        "model_status": ctx.model_status,
        "model_error": ctx.model_error,
        "model_version": ctx.manifest.model_version,
        "preprocessing_version": ctx.manifest.preprocessing_version,
        "package_version": __version__,
        "versions": versions,
    }


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

    t0 = time.monotonic()
    windows = classify_windows(ctx, start_ts, end_ts, body, head, tail)

    resp: Dict[str, Any] = {
        "ok": True,
        "model_version": ctx.manifest.model_version,
        "preprocessing_version": ctx.manifest.preprocessing_version,
        "windows": windows,
        "manifest": ctx.manifest.to_dict(),
        "duration_ms": int((time.monotonic() - t0) * 1000),
    }
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


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara activity-context serve process (C10)")
    ap.add_argument("--manifest", default=None, help="path to manifest.json")
    ap.add_argument("--checkpoint", default=None, help="dir containing model.safetensors")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
                    help="per-request timeout in seconds")
    args = ap.parse_args(argv)
    try:
        ctx = build_context(args.manifest, args.checkpoint, args.timeout)
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
