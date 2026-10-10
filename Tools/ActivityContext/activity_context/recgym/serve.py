"""Persistent RecGym exercise service — line-delimited JSON over stdin/stdout (RECGYM.md §4).

Same framing as ``activity_context.eldernet.serve`` (one JSON object per line; ``ping`` / ``infer`` / ``shutdown``;
SIGALRM timeout per request), but its own process: a RecGym failure can never touch the HART, Inertia or ElderNet
children, and none of them imports this module.

  Request : {"id":"<uuid>","op":"infer","run":{start_ts,end_ts,sample_rate_hz,channels_order,units,
             columns_b64,head_b64,tail_b64}} | ping | shutdown
  Response: exercise-windows-1 (runtime.handle_infer) or
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|weights_mismatch|timeout|internal|
             output_too_large"}

The checkpoint is resolved (sha256-verified, never downloaded) and loaded once at start-up together with the
committed scaler. A checkpoint that cannot be loaded keeps the process alive: ping answers ``model_available:
false`` and every infer fails with the load failure's kind. Responses are compact JSON, NaN refused, at most 12 MiB
per line (larger -> output_too_large).

Run:  python -m activity_context.recgym.serve [--weights-path <file|dir>|$RECGYM_WEIGHTS_PATH] [--timeout 60]
          [--threads 1] [--max-batch 64]
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
from typing import Any, Dict, Optional, Tuple

from .runtime import RecGymRuntime, RequestError, build_runtime, handle_request

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


def handle_line(rt: RecGymRuntime, line: str, timeout: float = 0.0) -> Tuple[str, bool]:
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


def serve_forever(rt: RecGymRuntime, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> int:
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
    ap = argparse.ArgumentParser(description="Nara RecGym exercise serve process (exercise-windows-1)")
    ap.add_argument("--weights-path", default=None,
                    help="the pinned checkpoint, or a directory holding it (default $RECGYM_WEIGHTS_PATH)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="per-request timeout (s)")
    ap.add_argument("--threads", type=int, default=1, help="torch CPU threads (default 1)")
    ap.add_argument("--max-batch", type=int, default=64, help="inference batch size (fixed; padded)")
    args = ap.parse_args(argv)
    from ..loaded import configure_torch_threads
    configure_torch_threads(args.threads)
    rt = build_runtime(args.weights_path, threads=args.threads, max_batch=args.max_batch)
    if rt.error is not None:
        print(f"[recgym.serve] model unavailable: {rt.error.kind}: {rt.error.message}", file=sys.stderr, flush=True)
    return serve_forever(rt, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
