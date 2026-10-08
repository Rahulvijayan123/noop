"""Persistent ActiNet classifier service — line-delimited JSON over stdin/stdout (ACTINET_CLASSIFIER.md §6).

The framing is the same as ``activity_context.serve`` / ``inertia.serve`` / ``eldernet.serve``: one JSON object
per line; ops ``ping`` / ``infer`` / ``shutdown``; a SIGALRM timeout per request. It runs as its own process, so
an ActiNet failure can never touch the HART, Inertia or ElderNet lanes, and none of them imports this module.

  Request : {"id":"<uuid>","op":"infer","runs":[{start_ts,end_ts,sample_rate_hz,channels_order,units,columns_b64,
             head_b64,tail_b64}, ...]}  (or the single HART-identical "run") | ping | shutdown
  Response: actinet-classifier-1 (runtime.handle_infer) or
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|weights_mismatch|timeout|internal|
             output_too_large|too_many_epochs"}

The converted artifact (two pinned files the operator made offline; weights.py) is resolved, sha256-verified and
loaded once at start-up. Nothing is downloaded and nothing is unpickled.
- An artifact that cannot be loaded keeps the process alive: ping answers ``model_available: false``, and every
  infer fails with the load failure's kind.
- Release mode is always ``shadow``.
- Responses are compact JSON with NaN refused, at most 12 MiB per line; a larger one becomes ``output_too_large``.

Run:  python -m activity_context.actinet_classifier.serve [--artifact-dir <dir>|$ACTINET_CLASSIFIER_DIR]
          [--timeout 60] [--threads 1] [--max-batch 64] [--max-epochs 2880]
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
from typing import Any, Dict, Optional, Tuple

from .runtime import (DEFAULT_MAX_BATCH, MAX_EPOCHS_PER_REQUEST, ActiNetRuntime, RequestError, build_runtime,
                      handle_request)

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
                                         f"response exceeds {max_bytes} bytes; request fewer runs"))
    return line


def handle_line(rt: ActiNetRuntime, line: str, timeout: float = 0.0) -> Tuple[str, bool]:
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


def serve_forever(rt: ActiNetRuntime, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> int:
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
    ap = argparse.ArgumentParser(description="Nara ActiNet classifier serve process (actinet-classifier-1, shadow)")
    ap.add_argument("--artifact-dir", default=None, help="the converted, pinned files (default $ACTINET_CLASSIFIER_DIR)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="per-request timeout (s)")
    ap.add_argument("--threads", type=int, default=1, help="torch CPU threads (default 1)")
    ap.add_argument("--max-batch", type=int, default=DEFAULT_MAX_BATCH, help="inference batch rows (fixed; padded)")
    ap.add_argument("--max-epochs", type=int, default=MAX_EPOCHS_PER_REQUEST, help="epochs per request (refused above)")
    args = ap.parse_args(argv)
    rt = build_runtime(args.artifact_dir, threads=args.threads, max_batch=args.max_batch, max_epochs=args.max_epochs)
    if rt.error is not None:
        print(f"[actinet_classifier.serve] model unavailable: {rt.error.kind}: {rt.error.message}", file=sys.stderr,
              flush=True)
    return serve_forever(rt, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
