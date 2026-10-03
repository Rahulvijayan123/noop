#!/usr/bin/env python3
"""Stub activity_context.serve for frwhoop-workerTests (no torch, no model).

Line-delimited JSON over stdin/stdout, mirroring the C10 serve protocol shape
(CONTRACTS.md). The real serve.py lives in Tools/ActivityContext; this stub
pins the worker's side of the protocol (request shape, response shape, id
echo, restart/timeout behavior).

Ops:
  ping     -> {"id":..., "ok":true, "model_status":"loaded",
               "model_version":"stub-model","preprocessing_version":"stub-preprocess"}
  infer    -> {"id":..., "ok":true, "model_version":"stub-model",
               "preprocessing_version":"stub-preprocess",
               "windows":[one 4 s stationary window at run.start_ts],
               "echo":{...run fields echoed back...}}
  shutdown -> respond ok then exit(0)

Test knobs (fields on any request):
  "die": true        -> exit(2) without a response (crash/restart test)
  "sleep_seconds": N -> sleep N before responding (timeout test)
  "respond_ok": false-> {"ok":false,"kind":"model_missing","error":"..."}
"""
import json
import sys
import time


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError as exc:
            sys.stderr.write("stub: bad json %s\n" % exc)
            continue
        rid = req.get("id")
        op = req.get("op")

        if req.get("die"):
            sys.stderr.write("stub: dying on request %s\n" % rid)
            sys.exit(2)

        sleep_seconds = req.get("sleep_seconds")
        if sleep_seconds:
            time.sleep(float(sleep_seconds))

        if op == "ping":
            resp = {
                "id": rid,
                "ok": True,
                "model_status": "loaded",
                "model_version": "stub-model",
                "preprocessing_version": "stub-preprocess",
            }
        elif op == "infer":
            run = req.get("run") or {}
            if req.get("respond_ok") is False:
                resp = {"id": rid, "ok": False, "kind": "model_missing",
                        "error": "stub model missing"}
            else:
                start_ts = run.get("start_ts")
                windows = []
                if start_ts is not None:
                    windows.append({
                        "s": float(start_ts),
                        "e": float(start_ts) + 4.0,
                        "label": "stationary",
                        "probs": {"stationary": 0.9, "walking": 0.05,
                                  "running": 0.03, "other_movement": 0.02,
                                  "unknown": 0.0},
                        "baseline": False,
                    })
                resp = {
                    "id": rid,
                    "ok": True,
                    "model_version": "stub-model",
                    "preprocessing_version": "stub-preprocess",
                    "windows": windows,
                    "echo": {
                        "start_ts": start_ts,
                        "end_ts": run.get("end_ts"),
                        "sample_rate_hz": run.get("sample_rate_hz"),
                        "channels_order": run.get("channels_order"),
                        "units": run.get("units"),
                        "n_columns": len(run.get("columns_b64") or []),
                        "n_head": len(req.get("head_b64") or []),
                        "n_tail": len(req.get("tail_b64") or []),
                        # The real serve.py reads head/tail from INSIDE run;
                        # the C10 contract puts them top-level. The worker
                        # sends both; echo both so a test can pin the shape.
                        "n_head_run": len(run.get("head_b64") or []),
                        "n_tail_run": len(run.get("tail_b64") or []),
                    },
                }
        elif op == "shutdown":
            sys.stdout.write(json.dumps({"id": rid, "ok": True}) + "\n")
            sys.stdout.flush()
            return
        else:
            resp = {"id": rid, "ok": False, "kind": "malformed",
                    "error": "unknown op %s" % op}

        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
