"""Persistent Inertia motion-heads service — line-delimited JSON over stdin/stdout (INERTIA1.md §6).

Same framing as ``activity_context.serve`` (one JSON object per line; ``ping`` / ``infer`` / ``shutdown``;
SIGALRM timeout per request) but a separate process: an Inertia failure can never touch the HART lane.

  Request : {"id":"<uuid>","op":"infer","run":{start_ts,end_ts,sample_rate_hz,channels_order,units,
             columns_b64,head_b64,tail_b64[,hop_s]}} | ping | shutdown
  Response: motion-heads-1 (see runtime.handle_infer) or
            {"id":..,"ok":false,"error":"...","kind":"malformed|model_missing|checkpoint_mismatch|
             config_mismatch|timeout|internal|output_too_large"}

The model is loaded once at start-up. A model that cannot be loaded keeps the process alive: ping answers
``model_available: false`` and every infer fails with the load failure's kind. Responses are compact JSON,
NaN refused, at most 12 MiB per line (larger -> output_too_large).

Run:  python -m activity_context.inertia.serve --bundle <dir> [--encoder-config encoder.json]
          [--checkpoint <path>|$INERTIA1_CKPT_PATH] [--allow-standin-shadow] [--timeout 60]
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
from typing import Any, Dict, Optional, Tuple

from .runtime import (DEFAULT_MAX_BATCH, InertiaRuntime, RequestError, build_runtime, handle_request)

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


def handle_line(rt: InertiaRuntime, line: str, timeout: float = 0.0) -> Tuple[str, bool]:
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


def serve_forever(rt: InertiaRuntime, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> int:
    if hasattr(signal, "SIGALRM"):
        def _on_alarm(signum, frame):
            raise _RequestTimeout("request timed out")
        signal.signal(signal.SIGALRM, _on_alarm)
    else:  # pragma: no cover - non-POSIX
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
    ap = argparse.ArgumentParser(description="Nara Inertia motion-heads serve process (motion-heads-1)")
    ap.add_argument("--bundle", required=True, help="head bundle directory (nara.inertia.heads/1)")
    ap.add_argument("--encoder-config", default=None, help="encoder.json (default: the bundle's, if listed)")
    ap.add_argument("--checkpoint", default=None, help="checkpoint path (default $INERTIA1_CKPT_PATH)")
    ap.add_argument("--allow-standin-shadow", action="store_true",
                    help="allow stand-in encoders/bundles (reported encoder_kind standin, tier shadow)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="per-request timeout (s)")
    ap.add_argument("--threads", type=int, default=1, help="torch CPU threads (default 1)")
    ap.add_argument("--max-batch", type=int, default=DEFAULT_MAX_BATCH, help="encoder batch size")
    args = ap.parse_args(argv)
    rt = build_runtime(args.bundle, encoder_config=args.encoder_config, checkpoint=args.checkpoint,
                       allow_standin_shadow=args.allow_standin_shadow, threads=args.threads,
                       max_batch=args.max_batch)
    if rt.error is not None:
        print(f"[inertia.serve] model unavailable: {rt.error}", file=sys.stderr, flush=True)
    return serve_forever(rt, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
