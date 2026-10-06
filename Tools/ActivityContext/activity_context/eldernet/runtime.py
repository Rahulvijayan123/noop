"""ElderNet runtime: load the six heads once, then turn requests into ``gait-quality-1`` responses.

``build_runtime`` never raises: a missing weights directory/file is ``model_missing``, a size/sha256/state-dict
mismatch ``weights_mismatch``, anything else ``internal``; the process stays up, ``ping`` reports
``model_available: false`` and every ``infer`` fails with that kind (ELDERNET.md §4). Nothing here imports the
HART model stack or the Inertia lane.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from .. import __version__
from ..preprocess import (MAX_HEAD_SECONDS, MAX_RUN_SECONDS, MAX_TAIL_SECONDS, PreprocessError,
                          decode_columns_b64, validate_request_units)
from . import (ALLOWED_HOP_S, DEFAULT_HOP_S, ERROR_KINDS, MODEL_ID, MODEL_VERSION, PREPROCESSING_VERSION,
               UPSTREAM_COMMIT, WINDOW_S, WIRE_SCHEMA)
from .gait import GaitCalibration, score_windows, wire_windows
from .preprocess import stack_windows, windows_from_seconds
from .weights import MANIFEST, WeightsError, wire_hashes

MAX_OUTPUT_BYTES = 12 * 1024 * 1024          # below the worker's 16 MiB line cap
MAX_WINDOWS_PER_RESPONSE = 200_000
PREPROCESSING = {"version": PREPROCESSING_VERSION, "resampler": "nearest (actipy.processing.resample)",
                 "calibration": False, "nonwear": False, "imputation": False, "edge_margin_s": 0,
                 "prefilter": "window variance <= 0.013^2 g^2 (upstream static ceiling, window-local)"}


class RequestError(Exception):
    """An infer request failed; ``kind`` is one of ERROR_KINDS."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind if kind in ERROR_KINDS else "internal"
        self.message = message


@dataclass
class ElderNetRuntime:
    heads: Optional[Any]                          # model.ElderNetHeads (or a test double)
    status: str                                   # eldernet_loaded | eldernet_unavailable
    error: Optional[WeightsError] = None
    calibration: Optional[GaitCalibration] = None
    default_hop_s: int = DEFAULT_HOP_S
    max_output_bytes: int = MAX_OUTPUT_BYTES
    load_seconds: float = 0.0

    @property
    def available(self) -> bool:
        return self.error is None and self.heads is not None

    @property
    def gait_threshold(self) -> float:
        return (self.calibration or GaitCalibration()).threshold


def load_calibration(path: Optional[str]) -> Optional[GaitCalibration]:
    if not path:
        return None
    with open(path, "r", encoding="utf-8") as f:
        return GaitCalibration.from_doc(json.load(f))


def build_runtime(weights_dir: Optional[str] = None, *, threads: Optional[int] = 1, max_batch: int = 64,
                  calibration: Optional[str] = None, default_hop_s: int = DEFAULT_HOP_S,
                  heads: Optional[Any] = None) -> ElderNetRuntime:
    """Resolve + verify + load once. ``heads`` injects pre-built heads (tests)."""
    t0 = time.perf_counter()
    try:
        cal = load_calibration(calibration)
        if heads is None:
            from .model import load_heads
            from .weights import resolve
            heads = load_heads(resolve(weights_dir), threads=threads, max_batch=max_batch)
        return ElderNetRuntime(heads=heads, status="eldernet_loaded", calibration=cal, default_hop_s=default_hop_s,
                               load_seconds=time.perf_counter() - t0)
    except WeightsError as exc:
        err = exc
    except Exception as exc:  # noqa: BLE001 - never crash the lane on load
        err = WeightsError("internal", f"{type(exc).__name__}: {exc}")
    return ElderNetRuntime(heads=None, status="eldernet_unavailable", error=err, default_hop_s=default_hop_s,
                           load_seconds=time.perf_counter() - t0)


# ---------------------------------------------------------------------------
# Requests (the HART-identical ``run`` object, + optional ``hop_s``)
# ---------------------------------------------------------------------------

def _b64_list(value: Any, what: str, max_len: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RequestError("malformed", f"{what} must be a list of base64 strings")
    if len(value) > max_len:
        raise RequestError("malformed", f"{what} exceeds {max_len} seconds")
    return value


def parse_infer_request(req: Dict[str, Any], default_hop_s: int
                        ) -> Tuple[int, int, List[str], List[str], List[str], int]:
    run = req.get("run")
    if not isinstance(run, dict):
        raise RequestError("malformed", "infer requires an object 'run'")
    start, end = run.get("start_ts"), run.get("end_ts")
    if (not isinstance(start, int) or not isinstance(end, int) or isinstance(start, bool)
            or isinstance(end, bool) or start < 0 or end <= start):
        raise RequestError("malformed", "run.start_ts/end_ts must be ints with start_ts < end_ts")
    if end - start > MAX_RUN_SECONDS:
        raise RequestError("malformed", f"run longer than {MAX_RUN_SECONDS} s")
    if run.get("sample_rate_hz") not in (None, 100):
        raise RequestError("malformed", f"only 100 Hz input is supported, got {run.get('sample_rate_hz')!r}")
    ch = run.get("channels_order")
    if ch is not None and ch != ["ax", "ay", "az", "gx", "gy", "gz"]:
        raise RequestError("malformed", "channels_order must be [ax,ay,az,gx,gy,gz]")
    try:
        validate_request_units(run.get("units") or {"accel": "g", "gyro": "deg/s"})
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    body = _b64_list(run.get("columns_b64"), "columns_b64", MAX_RUN_SECONDS)
    if len(body) != end - start:
        raise RequestError("malformed", f"columns_b64 count {len(body)} != end_ts - start_ts ({end - start})")
    pick = lambda k: run.get(k) if run.get(k) is not None else req.get(k)  # noqa: E731
    head = _b64_list(pick("head_b64"), "head_b64", MAX_HEAD_SECONDS)
    tail = _b64_list(pick("tail_b64"), "tail_b64", MAX_TAIL_SECONDS)
    hop = pick("hop_s")
    if hop is None:
        hop = default_hop_s
    if isinstance(hop, bool) or not isinstance(hop, (int, float)) or float(hop) not in ALLOWED_HOP_S:
        raise RequestError("malformed", f"hop_s must be one of {list(ALLOWED_HOP_S)}, got {hop!r}")
    return start, end, body, head, tail, int(hop)


def decode_request_seconds(start: int, end: int, body: List[str], head: List[str], tail: List[str]) -> List[tuple]:
    try:
        out = [(start - len(head) + i, decode_columns_b64(b)) for i, b in enumerate(head)]
        out += [(start + i, decode_columns_b64(b)) for i, b in enumerate(body)]
        out += [(end + i, decode_columns_b64(b)) for i, b in enumerate(tail)]
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    return out


def infer_seconds(rt: ElderNetRuntime, seconds: List[tuple], start: int, end: int, hop_s: int
                  ) -> Tuple[List[Dict[str, Any]], int]:
    """Decoded seconds -> wire windows and the count of nonfinite windows omitted."""
    try:
        windows = windows_from_seconds(seconds, start, end, hop_s)
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    if len(windows) > MAX_WINDOWS_PER_RESPONSE:
        raise RequestError("malformed", "too many windows for one response; request a shorter run or a larger hop")
    if not windows:
        return [], 0
    scores = score_windows(rt.heads, stack_windows(windows), rt.calibration)
    return wire_windows(windows, scores)


def handle_infer(rt: ElderNetRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    if not rt.available:
        err = rt.error or WeightsError("model_missing", "ElderNet runtime not loaded")
        raise RequestError(err.kind, err.message)
    t0 = time.monotonic()
    start, end, body, head, tail, hop_s = parse_infer_request(req, rt.default_hop_s)
    windows, dropped = infer_seconds(rt, decode_request_seconds(start, end, body, head, tail), start, end, hop_s)
    return {
        "ok": True, "schema": WIRE_SCHEMA, "model_id": MODEL_ID, "model_version": MODEL_VERSION,
        "weights": wire_hashes(MANIFEST), "upstream_commit": UPSTREAM_COMMIT,
        "preprocessing_version": PREPROCESSING_VERSION, "window_s": WINDOW_S, "hop_s": hop_s,
        "calibration": rt.calibration.wire() if rt.calibration is not None else None,
        "gait_threshold": rt.gait_threshold, "windows": windows, "n_dropped_nonfinite": dropped,
        "duration_ms": int((time.monotonic() - t0) * 1000),
    }


def handle_ping(rt: ElderNetRuntime) -> Dict[str, Any]:
    return {
        "ok": True, "model_available": rt.available, "model_status": rt.status,
        "model_error": f"{rt.error.kind}: {rt.error.message}" if rt.error is not None else None,
        "model_id": MODEL_ID, "model_version": MODEL_VERSION, "weights": wire_hashes(MANIFEST),
        "upstream_commit": UPSTREAM_COMMIT, "preprocessing_version": PREPROCESSING_VERSION,
        "package_version": __version__, "schema": WIRE_SCHEMA, "window_s": WINDOW_S,
        "hop_s": rt.default_hop_s, "gait_threshold": rt.gait_threshold,
        "calibration": rt.calibration.wire() if rt.calibration is not None else None,
        "preprocessing": PREPROCESSING,
    }


def handle_request(rt: ElderNetRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    """Dispatch one request object. Raises RequestError for every protocol-level failure."""
    req_id = req.get("id")
    if not isinstance(req_id, str) or not req_id:
        raise RequestError("malformed", "request needs a string 'id'")
    op = req.get("op")
    if op == "ping":
        resp = handle_ping(rt)
    elif op == "infer":
        resp = handle_infer(rt, req)
    elif op == "shutdown":
        resp = {"ok": True}
    else:
        raise RequestError("malformed", f"unknown op {op!r} (expected ping|infer|shutdown)")
    return {"id": req_id, "op": op, **resp}


__all__ = ["MAX_OUTPUT_BYTES", "MAX_WINDOWS_PER_RESPONSE", "PREPROCESSING", "RequestError", "ElderNetRuntime",
           "load_calibration", "build_runtime", "parse_infer_request", "decode_request_seconds", "infer_seconds",
           "handle_infer", "handle_ping", "handle_request"]
