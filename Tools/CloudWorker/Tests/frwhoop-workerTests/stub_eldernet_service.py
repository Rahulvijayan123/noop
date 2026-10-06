#!/usr/bin/env python3
"""Stub activity_context.eldernet.serve for frwhoop-workerTests (no torch, no model, no weights).

Line-delimited JSON over stdin/stdout in the gait-quality-1 shape (Tools/ActivityContext/ELDERNET.md §4).
Behaviour is fixed per process by argv, so the HART and Inertia stubs sharing the same RunRequest are never affected:

  --behaviour ok | model_missing | weights_mismatch | timeout | crash | malformed | schema | nan
              | out_of_range | metrics_on_non_gait | ok_then_crash   (first infer ok, every later one crashes)
              | output_too_large | internal   (a structured ok:false answer of that kind to every infer)
  --sleep N                       (seconds the timeout behaviour sleeps; default 30)
  --delay N                       (seconds every infer takes before it answers; default 0)
  --model-version V               (model_version reported by ping and infer; default eldernet-437a38b)
  --infer-model-version V         (model_version reported by infer only; default: --model-version)
  --weights-seed S                (seeds the made-up per-head sha256 digests; default "stub")
Every other argument (--weights-dir, --upstream-dir, --timeout …) is accepted and ignored.

ping also carries the newer serve's extra keys (`weights_digest`, `upstream_source` with non-string values), which
the worker must tolerate.

ping answers model_available:false (model_status eldernet_unavailable) for model_missing and weights_mismatch, true
otherwise. infer emits 10-s windows on a 5-s grid fully inside [start_ts, end_ts): every window starting on a
multiple of 30 s is pre-filtered, the one after it is non-gait, the rest are gait with metrics.
"""
import argparse
import hashlib
import json
import sys
import time

HEADS = ["gait_detection", "gait_speed", "gait_length", "cadence", "regularity", "step_count"]
COMMIT = "437a38bcc69f42717fe73c1f7dbea7e1f7a50d23"


def weights(seed):
    return {h: hashlib.sha256(("stub-eldernet-%s-%s" % (h, seed)).encode()).hexdigest() for h in HEADS}


def provenance(version, seed):
    return {"model_id": "eldernet", "model_version": version, "weights": weights(seed),
            "upstream_commit": COMMIT, "preprocessing_version": "eldernet-prep-1"}


def windows(start, end):
    out = []
    s = start
    while s + 10 <= end:
        if s % 30 == 0:
            w = {"s": s, "e": s + 10, "gait_prob": 0.0, "is_gait": False, "prefiltered": True}
        elif s % 30 == 5:
            w = {"s": s, "e": s + 10, "gait_prob": 0.12, "is_gait": False}
        else:
            w = {"s": s, "e": s + 10, "gait_prob": 0.94, "is_gait": True, "speed_mps": 1.21, "cadence_spm": 108.0,
                 "stride_m": 1.34, "regularity": 0.81, "steps": 18.0}
        out.append(w)
        s += 5
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--behaviour", default="ok")
    ap.add_argument("--sleep", type=float, default=30.0)
    ap.add_argument("--delay", type=float, default=0.0)
    ap.add_argument("--model-version", default="eldernet-437a38b")
    ap.add_argument("--infer-model-version", default=None)
    ap.add_argument("--weights-seed", default="stub")
    args, _ = ap.parse_known_args()
    infers = 0
    unavailable = args.behaviour in ("model_missing", "weights_mismatch")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        rid = req.get("id")
        op = req.get("op")
        if op == "ping":
            resp = {"id": rid, "op": "ping", "ok": True, "model_available": not unavailable,
                    "model_status": "eldernet_unavailable" if unavailable else "eldernet_loaded",
                    "model_error": ("weights_mismatch: gait_detection sha256 differs" if args.behaviour == "weights_mismatch"
                                    else "FileNotFoundError: no weights") if unavailable else None,
                    "package_version": "stub",
                    "upstream_source": {"commit": COMMIT, "verified": True, "files": 12}}
            resp.update(provenance(args.model_version, args.weights_seed))
            canonical = "eldernet-weights-1\n" + "".join("%s=%s\n" % (k, v) for k, v in sorted(resp["weights"].items()))
            resp["weights_digest"] = hashlib.sha256(canonical.encode()).hexdigest()
        elif op == "shutdown":
            sys.stdout.write(json.dumps({"id": rid, "ok": True}) + "\n")
            sys.stdout.flush()
            return
        elif op == "infer":
            infers += 1
            run = req.get("run") or {}
            b = args.behaviour
            if b == "ok_then_crash" and infers > 1:
                sys.exit(3)
            if b == "crash":
                sys.exit(3)
            if b == "timeout":
                time.sleep(args.sleep)
            if args.delay > 0:
                time.sleep(args.delay)
            if unavailable:
                resp = {"id": rid, "ok": False, "kind": b, "error": "no usable weights"}
            elif b in ("output_too_large", "internal"):
                resp = {"id": rid, "ok": False, "kind": b, "error": "stub " + b}
            else:
                resp = {"id": rid, "op": "infer", "ok": True, "schema": "gait-quality-1", "window_s": 10, "hop_s": 5,
                        "calibration": {"gait_prob": {"method": "temperature", "T": 1.0, "fit": "val"}},
                        "gait_threshold": 0.5,
                        "windows": windows(int(run.get("start_ts", 0)), int(run.get("end_ts", 0))),
                        "n_dropped_nonfinite": 0, "duration_ms": 1}
                resp.update(provenance(args.infer_model_version or args.model_version, args.weights_seed))
                gait = [w for w in resp["windows"] if w["is_gait"]]
                if b == "schema":
                    resp["schema"] = "gait-quality-0"
                if b == "malformed" and resp["windows"]:
                    resp["windows"][0]["mood"] = 1
                if b == "out_of_range" and gait:
                    gait[0]["cadence_spm"] = 210.0
                if b == "metrics_on_non_gait":
                    for w in resp["windows"]:
                        if not w["is_gait"] and not w.get("prefiltered"):
                            w["speed_mps"] = 0.4
                            break
                if b == "nan":
                    text = json.dumps(resp)
                    text = text.replace('"gait_prob": 0.94', '"gait_prob": NaN', 1)
                    sys.stdout.write(text + "\n")
                    sys.stdout.flush()
                    continue
        else:
            resp = {"id": rid, "ok": False, "kind": "malformed", "error": "unknown op"}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
