"""activity-infer — one-off offline inference CLI.

Reads IMU seconds from one of:

  --frames <golden.json>   a whoop5-raw-imu-frame golden fixture (hex 1244-byte
                           frames, decode per Whoop5RawImu.rawColumns)
  --json <run.json>        a serve-protocol "run" object (or a full request
                           with op=infer) — canonical production payload
  --b64 <columns.txt>      one base64 1200-byte NPB1 column per line (per
                           second, contiguous), with --start-ts/--end-ts

Runs the same pipeline as serve.py (decode -> 100->30 Hz -> 4 s windows,
2 s hop, transient crop) against the baseline heuristic or the HART model
per the manifest, and prints per-window labels + probabilities as JSON.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List, Optional

import numpy as np

from .manifest import load_manifest
from .preprocess import (CHANNEL_ORDER, decode_columns_b64, decode_frame_hex,
                         encode_columns_b64)
from .serve import ServeContext, build_context, classify_windows


def _run_from_golden(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or data.get("kind") != "whoop5-raw-imu-frame":
        raise ValueError(f"{path} is not a whoop5-raw-imu-frame golden fixture")
    frames = data.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ValueError(f"{path} has no frames")
    seconds = []
    for hx in frames:
        base_ts, cols = decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    body = [encode_columns_b64(c) for _, c in seconds]
    return {"start_ts": start, "end_ts": end, "sample_rate_hz": 100,
            "channels_order": list(CHANNEL_ORDER),
            "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": body, "head_b64": [], "tail_b64": []}


def _run_from_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict) and "run" in data:
        data = data["run"]
    if not isinstance(data, dict) or "columns_b64" not in data:
        raise ValueError(f"{path} must contain a serve-protocol run object")
    return data


def _run_from_b64(path: str, start_ts: int, end_ts: int) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    body = []
    for ln in lines:
        cols = decode_columns_b64(ln)
        body.append(encode_columns_b64(cols))
    if end_ts is None:
        end_ts = start_ts + len(body)
    if len(body) != end_ts - start_ts:
        raise ValueError(
            f"{len(body)} seconds in {path} != end_ts - start_ts ({end_ts - start_ts})")
    return {"start_ts": start_ts, "end_ts": end_ts, "sample_rate_hz": 100,
            "channels_order": list(CHANNEL_ORDER),
            "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": body, "head_b64": [], "tail_b64": []}


def run_infer(ctx: ServeContext, run: Dict[str, Any]) -> Dict[str, Any]:
    from .serve import handle_infer
    req = {"id": "offline-infer", "op": "infer", "run": run}
    return handle_infer(ctx, req)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara one-off offline activity inference")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--frames", metavar="JSON", help="golden whoop5-raw-imu-frame fixture")
    src.add_argument("--json", metavar="JSON", help="serve-protocol run payload")
    src.add_argument("--b64", metavar="TXT", help="per-second base64 columns, one per line")
    ap.add_argument("--start-ts", type=int, default=0)
    ap.add_argument("--end-ts", type=int, default=None)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--checkpoint", default=None)
    ap.add_argument("--out", default=None, help="write result JSON to a file")
    args = ap.parse_args(argv)

    if args.frames:
        run = _run_from_golden(args.frames)
    elif args.json:
        run = _run_from_json(args.json)
    else:
        run = _run_from_b64(args.b64, args.start_ts, args.end_ts)

    ctx = build_context(args.manifest, args.checkpoint)
    result = run_infer(ctx, run)
    text = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"wrote {len(result['windows'])} windows to {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
