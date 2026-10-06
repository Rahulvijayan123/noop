#!/usr/bin/env python3
"""Stub activity_context.inertia.serve for frwhoop-workerTests (no torch, no model).

Line-delimited JSON over stdin/stdout in the motion-heads-1 shape (Tools/ActivityContext/INERTIA1.md §6).
Behaviour is fixed per process by argv, so the HART stub sharing the same RunRequest is never affected:

  --behaviour ok | model_missing | timeout | crash | malformed | schema | nan | bad_sum
              | ok_then_crash    (first infer ok, every later one crashes)
  --kind inertia1 | standin       (encoder_kind reported; default standin)
  --tier shadow | candidate | production   (evidence_tier_max; default shadow)
  --sleep N                       (seconds the timeout behaviour sleeps; default 30)

ping answers model_available:false (model_status inertia_unavailable) for model_missing, true otherwise.
infer emits 30-s windows on a 5-s grid fully inside [start_ts, end_ts).
"""
import argparse
import json
import sys
import time

POSTURE = ["recumbent", "seated_likely", "upright_stationary", "postural_transition"]
LOCO = ["stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion", "other"]
ARM = ["quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing", "exercise_motion", "other"]
EVENTS = ["sit_to_stand_like", "stand_to_sit_like", "lying_down_like", "getting_up_like",
          "walk_start", "walk_stop", "run_start", "run_stop"]


def spec(classes, categorical=True):
    n = len(classes)
    prior = {c: round(1.0 / n, 6) for c in classes} if categorical else {c: 0.05 for c in classes}
    if categorical:
        # Make the rounded prior sum to exactly 1.
        prior[classes[0]] = round(1.0 - sum(prior[c] for c in classes[1:]), 6)
    return {"class_order": classes, "prior": prior, "status": {c: "strong" for c in classes},
            "tau": {c: 0.8 for c in classes}, "merge_into": {}, "covers": {}}


def provenance(kind, tier):
    real = kind == "inertia1"
    return {
        "encoder_id": "inertia-1/ar_transformer-small/30s@20hz" if real else "standin:handcrafted-stats-v1",
        "encoder_kind": kind,
        "encoder_version": "stub-1",
        "checkpoint_sha256": "cd" * 32 if real else None,
        "heads_version": "stub-bundle-1",
        "bundle_sha256": "ab" * 32,
        "preprocessing_version": "inertia-prep-1",
        "evidence_tier_max": tier,
    }


def peaked(classes, top, p):
    rest = round((1.0 - p) / (len(classes) - 1), 6)
    out = {c: rest for c in classes}
    out[top] = round(1.0 - rest * (len(classes) - 1), 6)
    return out


def windows(start, end):
    out = []
    s = start
    while s + 30 <= end:
        k = (s // 5) % 3
        out.append({
            "s": s, "e": s + 30,
            "posture": peaked(POSTURE, POSTURE[k], 0.7),
            "locomotion": peaked(LOCO, ["stationary", "walking", "running"][k], 0.8),
            "arm_behavior": peaked(ARM, ARM[k], 0.6),
            "transition": {e: 0.05 for e in EVENTS},
            "movement_intensity": 0.25,
            "ood_score": 0.5,
            "is_ood": s % 60 == 0,
        })
        s += 5
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--behaviour", default="ok")
    ap.add_argument("--kind", default="standin")
    ap.add_argument("--tier", default="shadow")
    ap.add_argument("--sleep", type=float, default=30.0)
    args, _ = ap.parse_known_args()
    infers = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        rid = req.get("id")
        op = req.get("op")
        if op == "ping":
            available = args.behaviour != "model_missing"
            resp = {"id": rid, "op": "ping", "ok": True, "model_available": available,
                    "model_status": "standin_shadow" if available else "inertia_unavailable",
                    "model_error": None if available else "FileNotFoundError: no checkpoint",
                    "package_version": "stub"}
            resp.update(provenance(args.kind, args.tier))
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
            if b == "model_missing":
                resp = {"id": rid, "ok": False, "kind": "model_missing", "error": "no checkpoint"}
            else:
                resp = {"id": rid, "op": "infer", "ok": True, "schema": "motion-heads-1",
                        "window_s": 30, "hop_s": 5,
                        "bundle": {"heads": {"posture": spec(POSTURE), "locomotion": spec(LOCO),
                                             "arm_behavior": spec(ARM), "transition": spec(EVENTS, False)},
                                   "ood": {"method": "knn", "threshold": 1.25}},
                        "windows": windows(int(run.get("start_ts", 0)), int(run.get("end_ts", 0))),
                        "n_dropped_nonfinite": 0, "duration_ms": 1}
                resp.update(provenance(args.kind, args.tier))
                if b == "schema":
                    resp["schema"] = "motion-heads-0"
                if b == "malformed" and resp["windows"]:
                    resp["windows"][0]["posture"]["kneeling"] = 0.0
                if b == "bad_sum" and resp["windows"]:
                    resp["windows"][0]["locomotion"]["stationary"] = 0.95
                if b == "nan":
                    text = json.dumps(resp)
                    text = text.replace('"movement_intensity": 0.25', '"movement_intensity": NaN', 1)
                    sys.stdout.write(text + "\n")
                    sys.stdout.flush()
                    continue
        else:
            resp = {"id": rid, "ok": False, "kind": "malformed", "error": "unknown op"}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
