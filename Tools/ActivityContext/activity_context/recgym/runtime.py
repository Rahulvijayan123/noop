"""RecGym runtime: load the checkpoint and the scaler once, then turn requests into ``exercise-windows-1`` responses.

``build_runtime`` never raises: no configured or present checkpoint is ``model_missing``, a size/sha256/state-dict
mismatch ``weights_mismatch``, anything else (an unreadable scaler) ``internal``; the process stays up, ``ping``
reports ``model_available: false`` and every ``infer`` fails with that kind (RECGYM.md §4). Nothing here imports the
HART model stack, Inertia or ElderNet.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from .. import __version__
from ..loaded import base_loaded, code_sha256, loaded_digest
from ..preprocess import (MAX_HEAD_SECONDS, MAX_RUN_SECONDS, MAX_TAIL_SECONDS, PreprocessError, decode_columns_b64,
                          validate_request_units)
from . import (CLASSES, ERROR_KINDS, HOP_S, MODEL_ID, MODEL_VERSION, NULL_INDEX, PREPROCESSING_VERSION, RATE_HZ,
               SCALER_VERSION, TRAINED_PLACEMENT, UPSTREAM_COMMIT, WINDOW_S, WIRE_SCHEMA)
from .preprocess import AXIS_MAPPING, PREPROCESSING, stack_windows, windows_from_seconds
from .weights import CHECKPOINT, WeightsError

MAX_OUTPUT_BYTES = 12 * 1024 * 1024          # below the worker's 16 MiB line cap
MAX_WINDOWS_PER_RESPONSE = 200_000
PROB_DECIMALS = 6


class RequestError(Exception):
    """An infer request failed; ``kind`` is one of ERROR_KINDS."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind if kind in ERROR_KINDS else "internal"
        self.message = message


@dataclass
class RecGymRuntime:
    model: Optional[Any]                          # model.RecGymModel (or a test double with .logits)
    scaler: Optional[Any]                         # scaler.RecGymScaler
    status: str                                   # recgym_loaded | recgym_unavailable
    error: Optional[WeightsError] = None
    max_output_bytes: int = MAX_OUTPUT_BYTES
    load_seconds: float = 0.0
    # sha256 of the checkpoint as read at load (None for an injected test model) and the torch threads: what ping
    # reports as ``loaded``.
    measured_weights_sha256: Optional[str] = None
    threads: Optional[int] = None
    max_batch: Optional[int] = None

    @property
    def available(self) -> bool:
        return self.error is None and self.model is not None and self.scaler is not None

    def loaded(self) -> Dict[str, str]:
        out = base_loaded(self.threads if self.available else None)
        if not self.available:
            return out
        if self.measured_weights_sha256:
            out["weights_sha256"] = self.measured_weights_sha256
        out["scaler_sha256"] = self.scaler.sha256
        out["scaler_version"] = self.scaler.version
        out["model_version"] = MODEL_VERSION
        out["preprocessing_version"] = PREPROCESSING_VERSION
        if self.max_batch is not None:
            out["max_batch"] = str(int(self.max_batch))
        return out


def build_runtime(weights_path: Optional[str] = None, *, threads: Optional[int] = 1, max_batch: int = 64,
                  model: Optional[Any] = None, scaler_path: Optional[str] = None) -> RecGymRuntime:
    """Resolve + verify + load once: the checkpoint (``weights_path`` / $RECGYM_WEIGHTS_PATH), then the committed
    scaler. ``model`` injects a pre-built model (tests)."""
    t0 = time.perf_counter()
    code_sha256()  # hashed once now, so a ping (under the request timeout) never pays for it
    try:
        from .scaler import load_scaler
        measured = None
        if model is None:
            from .model import load_model
            from .weights import resolve_measured
            path, measured = resolve_measured(weights_path)
            model = load_model(path, threads=threads, max_batch=max_batch)
        scaler = load_scaler(scaler_path)
        return RecGymRuntime(model=model, scaler=scaler, status="recgym_loaded",
                             load_seconds=time.perf_counter() - t0, measured_weights_sha256=measured,
                             threads=threads, max_batch=max_batch)
    except WeightsError as exc:
        err = exc
    except Exception as exc:  # noqa: BLE001 - never crash the lane on load
        err = WeightsError("internal", f"{type(exc).__name__}: {exc}")
    return RecGymRuntime(model=None, scaler=None, status="recgym_unavailable", error=err,
                         load_seconds=time.perf_counter() - t0)


# ---------------------------------------------------------------------------
# Requests (the HART-identical ``run`` object)
# ---------------------------------------------------------------------------

def _b64_list(value: Any, what: str, max_len: int) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise RequestError("malformed", f"{what} must be a list of base64 strings")
    if len(value) > max_len:
        raise RequestError("malformed", f"{what} exceeds {max_len} seconds")
    return value


def parse_infer_request(req: Dict[str, Any]) -> Tuple[int, int, List[str], List[str], List[str]]:
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
    return start, end, body, head, tail


def decode_request_seconds(start: int, end: int, body: List[str], head: List[str], tail: List[str]) -> List[tuple]:
    try:
        out = [(start - len(head) + i, decode_columns_b64(b)) for i, b in enumerate(head)]
        out += [(start + i, decode_columns_b64(b)) for i, b in enumerate(body)]
        out += [(end + i, decode_columns_b64(b)) for i, b in enumerate(tail)]
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    return out


def score_seconds(rt: RecGymRuntime, seconds: List[tuple], start: int, end: int):
    """Decoded seconds -> (windows, logits (N, 12) float64): the served path before wire rounding."""
    try:
        windows = windows_from_seconds(seconds, start, end)
    except PreprocessError as exc:
        raise RequestError("malformed", str(exc)) from exc
    if len(windows) > MAX_WINDOWS_PER_RESPONSE:
        raise RequestError("malformed", "too many windows for one response; request a shorter run")
    if not windows:
        return [], np.zeros((0, len(CLASSES)), np.float64)
    return windows, rt.model.logits(rt.scaler.transform(stack_windows(windows)))


def wire_windows(windows, logits: np.ndarray) -> Tuple[List[Dict[str, Any]], int]:
    """One object per window: ``s``, ``e``, ``p`` (12 class probabilities in ``CLASSES`` order, 6 decimals) and
    ``input_sha256``. A window with any nonfinite logit is omitted and counted."""
    from .model import softmax
    out: List[Dict[str, Any]] = []
    dropped = 0
    if len(windows) == 0:
        return out, 0
    finite = np.isfinite(logits).all(axis=1)
    probs = softmax(np.where(np.isfinite(logits), logits, 0.0))
    for w, ok, p in zip(windows, finite, probs):
        if not ok or not np.isfinite(p).all():
            dropped += 1
            continue
        out.append({"s": int(w.s), "e": int(w.e), "p": [round(float(v), PROB_DECIMALS) for v in p],
                    "input_sha256": w.input_sha256})
    return out, dropped


def infer_seconds(rt: RecGymRuntime, seconds: List[tuple], start: int, end: int) -> Tuple[List[Dict[str, Any]], int]:
    windows, logits = score_seconds(rt, seconds, start, end)
    return wire_windows(windows, logits)


def _identity() -> Dict[str, Any]:
    return {"model_id": MODEL_ID, "model_version": MODEL_VERSION, "weights_sha256": CHECKPOINT.sha256,
            "upstream_commit": UPSTREAM_COMMIT, "preprocessing_version": PREPROCESSING_VERSION,
            "scaler_version": SCALER_VERSION, "classes": list(CLASSES), "null_class": CLASSES[NULL_INDEX],
            "trained_placement": TRAINED_PLACEMENT, "axis_mapping": AXIS_MAPPING, "window_s": WINDOW_S,
            "hop_s": HOP_S, "rate_hz": RATE_HZ}


def handle_infer(rt: RecGymRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
    if not rt.available:
        err = rt.error or WeightsError("model_missing", "RecGym runtime not loaded")
        raise RequestError(err.kind, err.message)
    t0 = time.monotonic()
    start, end, body, head, tail = parse_infer_request(req)
    windows, dropped = infer_seconds(rt, decode_request_seconds(start, end, body, head, tail), start, end)
    return {"ok": True, "schema": WIRE_SCHEMA, **_identity(), "scaler_sha256": rt.scaler.sha256,
            "windows": windows, "n_dropped_nonfinite": dropped, "duration_ms": int((time.monotonic() - t0) * 1000)}


def handle_ping(rt: RecGymRuntime) -> Dict[str, Any]:
    loaded = rt.loaded()
    return {"ok": True, "model_available": rt.available, "model_status": rt.status,
            "model_error": f"{rt.error.kind}: {rt.error.message}" if rt.error is not None else None,
            **_identity(), "scaler_sha256": rt.scaler.sha256 if rt.scaler is not None else None,
            "package_version": __version__, "schema": WIRE_SCHEMA, "preprocessing": PREPROCESSING,
            "loaded": loaded, "loaded_digest": loaded_digest(loaded)}


def handle_request(rt: RecGymRuntime, req: Dict[str, Any]) -> Dict[str, Any]:
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


__all__ = ["MAX_OUTPUT_BYTES", "MAX_WINDOWS_PER_RESPONSE", "PROB_DECIMALS", "RequestError", "RecGymRuntime",
           "build_runtime", "parse_infer_request", "decode_request_seconds", "score_seconds", "wire_windows",
           "infer_seconds", "handle_infer", "handle_ping", "handle_request"]
