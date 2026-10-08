"""Persistent ElderNet gait-quality service — line-delimited JSON over stdin/stdout (ELDERNET.md §4).

Same framing as ``activity_context.serve`` / ``activity_context.inertia.serve`` (one JSON object per line;
``ping`` / ``infer`` / ``shutdown``; SIGALRM timeout per request), but its own process: an ElderNet failure can
never touch the HART or Inertia lanes, and neither of them imports this module.

  Request : {"id":"<uuid>","op":"infer","run":{start_ts,end_ts,sample_rate_hz,channels_order,units,
             columns_b64,head_b64,tail_b64[,hop_s]}} | ping | shutdown
  Response: gait-quality-1 (runtime.handle_infer) or
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|weights_mismatch|timeout|internal|
             output_too_large"}

The six heads and the upstream architecture source (University of Oxford code the operator fetched; never in
Nara's repository) are resolved (sha256-verified, never downloaded) and loaded once at start-up. Weights or source
that cannot be loaded keep the process alive: ping answers ``model_available: false`` and every infer fails with
the load failure's kind. Responses are compact JSON, NaN refused, at most 12 MiB per line (larger ->
output_too_large).

Run:  python -m activity_context.eldernet.serve [--weights-dir <dir>|$ELDERNET_WEIGHTS_DIR]
          [--upstream-dir <dir>|$ELDERNET_UPSTREAM_DIR] [--timeout 60] [--threads 1] [--max-batch 64] [--hop-s 5]
          [--calibration <nara.eldernet.calibration/1 json>]
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
from typing import Any, Dict, Optional, Tuple

from . import ALLOWED_HOP_S, DEFAULT_HOP_S
from .runtime import ElderNetRuntime, RequestError, build_runtime, handle_request

DEFAULT_TIMEOUT_SECONDS = 60.0


class _RequestTimeout(Exception):
    pass


def _set_alarm(seconds: float) -> None:
    if hasattr(signal, "setitimer"):
        signal.setitimer(signal.ITIMER_REAL, seconds)


def error_response(req_id: Optional[str], kind: str, message: str) -> Dict[str, Any]:
    return {"id": req_id, "ok": False, "error": message, "kind": RequestError(kind, message).kind}


def encode_line(resp: Dict[str, Any], max_bytes: int) -> str:
    """Compact JSON line; a response over ``max_bytes`` becomes output_too_large."""
    try:
        line = json.dumps(resp, separators=(",", ":"), allow_nan=False)
    except ValueError as exc:
        return json.dumps(error_response(resp.get("id"), "internal", f"unserializable response: {exc}"))
    if len(line.encode("utf-8")) > max_bytes:
        return json.dumps(error_response(resp.get("id"), "output_too_large",
                                         f"response exceeds {max_bytes} bytes; request a shorter run"))
    return line


def handle_line(rt: ElderNetRuntime, line: str, timeout: float = 0.0) -> Tuple[str, bool]:
    """One request line -> (response line, is_shutdown). Never raises."""
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("request must be a JSON object")
    except ValueError as exc:
        return json.dumps(error_response(None, "malformed", f"request line is not valid JSON: {exc}")), False
    req_id = req.get("id") if isinstance(req.get("id"), str) else None
    try:
        if timeout > 0:
            _set_alarm(timeout)
        try:
            resp = handle_request(rt, req)
        finally:
            if timeout > 0:
                _set_alarm(0.0)
    except _RequestTimeout:
        return json.dumps(error_response(req_id, "timeout", f"request exceeded {timeout:g}s")), False
    except RequestError as exc:
        return json.dumps(error_response(req_id, exc.kind, exc.message)), False
    except Exception as exc:  # noqa: BLE001 - protocol boundary
        return json.dumps(error_response(req_id, "internal", f"internal error: {type(exc).__name__}: {exc}")), False
    return encode_line(resp, rt.max_output_bytes), req.get("op") == "shutdown"


def install_alarm_handler() -> bool:
    if not hasattr(signal, "SIGALRM"):        # pragma: no cover - non-POSIX
        return False

    def _on_alarm(signum, frame):
        raise _RequestTimeout("request timed out")
    signal.signal(signal.SIGALRM, _on_alarm)
    return True


def serve_forever(rt: ElderNetRuntime, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> int:
    if not install_alarm_handler():
        timeout = 0.0
    sys.stdout.reconfigure(line_buffering=True)
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        out, stop = handle_line(rt, raw, timeout)
        sys.stdout.write(out + "\n")
        sys.stdout.flush()
        if stop:
            return 0
    return 0


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara ElderNet gait-quality serve process (gait-quality-1)")
    ap.add_argument("--weights-dir", default=None, help="the six pinned heads (default $ELDERNET_WEIGHTS_DIR)")
    ap.add_argument("--upstream-dir", default=None,
                    help="the pinned upstream source checkout (default $ELDERNET_UPSTREAM_DIR)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="per-request timeout (s)")
    ap.add_argument("--threads", type=int, default=1, help="torch CPU threads (default 1)")
    ap.add_argument("--max-batch", type=int, default=64, help="inference batch size (fixed; padded)")
    ap.add_argument("--hop-s", type=int, default=DEFAULT_HOP_S, choices=list(ALLOWED_HOP_S),
                    help="default window hop when a request does not name one")
    ap.add_argument("--calibration", default=None,
                    help="VAL-fitted gait_prob temperature + threshold (nara.eldernet.calibration/1); default none")
    args = ap.parse_args(argv)
    from ..loaded import configure_torch_threads
    configure_torch_threads(args.threads)
    rt = build_runtime(args.weights_dir, threads=args.threads, max_batch=args.max_batch,
                       calibration=args.calibration, default_hop_s=args.hop_s, upstream_dir=args.upstream_dir)
    if rt.error is not None:
        print(f"[eldernet.serve] model unavailable: {rt.error.kind}: {rt.error.message}", file=sys.stderr, flush=True)
    return serve_forever(rt, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
