#!/usr/bin/env python3
"""Stub activity_context.recgym.serve for frwhoop-workerTests (no torch, no model, no checkpoint).

Line-delimited JSON over stdin/stdout in the exercise-windows-1 shape (Tools/ActivityContext/RECGYM.md §4).
Behaviour is fixed per process by argv, so the HART stub sharing the same RunRequest is never affected:

  --behaviour ok | model_missing | weights_mismatch | timeout | crash | schema | classes | nan | bad_probs
              | ok_then_crash (first infer ok, every later one crashes) | internal (structured ok:false)
  --sleep N                (seconds the timeout behaviour sleeps; default 30)
  --model-version V        (model_version in ping and infer; default recgym-cnn-transformer-e085ac0)
  --weights-sha S          (the checkpoint sha256 ping's `loaded` measured and infer reports; default the real pin)
  --no-loaded              (ping reports no measured `loaded` identity)
Every other argument (--weights-path, --timeout, --threads …) is accepted and ignored.

infer emits 4-s windows on the absolute even-second grid fully inside [start_ts + 2, end_ts - 1): window k is
BenchPress-heavy when its start is a multiple of 8, Null-heavy otherwise.
"""
import argparse
import hashlib
import json
import sys
import time

CLASSES = ["Adductor", "ArmCurl", "BenchPress", "LegCurl", "LegPress", "Null", "Riding", "RopeSkipping", "Running",
           "Squat", "StairClimber", "Walking"]
PIN = "7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9"


def loaded_digest(loaded):
    text = "activity-loaded-1\n" + "".join("%s=%s\n" % (k, loaded[k]) for k in sorted(loaded))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def identity(version, sha):
    return {"model_id": "recgym-cnn-transformer", "model_version": version, "weights_sha256": sha,
            "upstream_commit": "e085ac0e116aa5997d5f593ac1d0dd0c801859b1", "preprocessing_version": "recgym-prep-1",
            "scaler_version": "recgym-wrist-imu-scaler-1", "scaler_sha256": "b" * 64, "classes": CLASSES,
            "null_class": "Null", "trained_placement": "wrist", "axis_mapping": "identity_unverified",
            "window_s": 4, "hop_s": 2, "rate_hz": 20}


def windows(start, end):
    out = []
    s = start + 2
    s += s % 2
    while s + 4 <= end - 1:
        if s % 8 == 0:
            p = [0.01, 0.01, 0.86, 0.01, 0.01, 0.03, 0.01, 0.01, 0.01, 0.02, 0.01, 0.01]
        else:
            p = [0.004, 0.001, 0.002, 0.003, 0.0, 0.98, 0.0, 0.0, 0.002, 0.003, 0.002, 0.003]
        out.append({"s": s, "e": s + 4, "p": p,
                    "input_sha256": hashlib.sha256(("stub-%d" % s).encode()).hexdigest()})
        s += 2
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--behaviour", default="ok")
    ap.add_argument("--sleep", type=float, default=30.0)
    ap.add_argument("--model-version", default="recgym-cnn-transformer-e085ac0")
    ap.add_argument("--weights-sha", default=PIN)
    ap.add_argument("--no-loaded", action="store_true")
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
                    "model_status": "recgym_unavailable" if unavailable else "recgym_loaded",
                    "model_error": (args.behaviour + ": stub") if unavailable else None,
                    "package_version": "stub", "schema": "exercise-windows-1",
                    "preprocessing": {"version": "recgym-prep-1", "head_margin_s": 2}}
            resp.update(identity(args.model_version, PIN))
            if not args.no_loaded and not unavailable:
                loaded = {"schema": "activity-loaded-1", "code_sha256": hashlib.sha256(b"stub-recgym").hexdigest(),
                          "threads": "1", "weights_sha256": args.weights_sha, "scaler_sha256": "b" * 64,
                          "model_version": args.model_version}
                resp["loaded"] = loaded
                resp["loaded_digest"] = loaded_digest(loaded)
        elif op == "shutdown":
            sys.stdout.write(json.dumps({"id": rid, "ok": True}) + "\n")
            sys.stdout.flush()
            return
        elif op == "infer":
            infers += 1
            run = req.get("run") or {}
            b = args.behaviour
            if b == "crash" or (b == "ok_then_crash" and infers > 1):
                sys.exit(3)
            if b == "timeout":
                time.sleep(args.sleep)
            if unavailable or b == "internal":
                resp = {"id": rid, "ok": False, "kind": "internal" if b == "internal" else b, "error": "stub " + b}
            else:
                resp = {"id": rid, "op": "infer", "ok": True, "schema": "exercise-windows-1",
                        "windows": windows(int(run.get("start_ts", 0)), int(run.get("end_ts", 0))),
                        "n_dropped_nonfinite": 0, "duration_ms": 1}
                resp.update(identity(args.model_version, args.weights_sha))
                if b == "schema":
                    resp["schema"] = "exercise-windows-0"
                if b == "classes":
                    resp["classes"] = list(reversed(CLASSES))
                if b == "bad_probs" and resp["windows"]:
                    resp["windows"][0]["p"][0] = 0.5
                if b == "nan" and resp["windows"]:
                    text = json.dumps(resp).replace('"p": [0.01,', '"p": [NaN,', 1)
                    sys.stdout.write(text + "\n")
                    sys.stdout.flush()
                    continue
        else:
            resp = {"id": rid, "ok": False, "kind": "malformed", "error": "unknown op"}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
