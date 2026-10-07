#!/usr/bin/env python3
"""Stub activity_context.serve for frwhoop-workerTests (no torch, no model).

Line-delimited JSON over stdin/stdout, mirroring the C10 serve protocol shape
(CONTRACTS.md). The real serve.py lives in Tools/ActivityContext; this stub
pins the worker's side of the protocol (request shape, response shape, id
echo, restart/timeout behavior).

Ops:
  ping     -> {"id":..., "ok":true, "model_status":"loaded",
               "model_version":"stub-model","preprocessing_version":"stub-preprocess",
               "calibrated":false}
  infer    -> {"id":..., "ok":true, "model_version":"stub-model",
               "preprocessing_version":"stub-preprocess",
               "feature_schema":"imu-feat-2",
               "windows":[one 4 s stationary window at run.start_ts, with "feat"],
               "echo":{...run fields echoed back...}}
  shutdown -> respond ok then exit(0)

Test knobs (fields on any request):
  "die": true        -> exit(2) without a response (crash/restart test)
  "sleep_seconds": N -> sleep N before responding (timeout test)
  "respond_ok": false-> {"ok":false,"kind":"model_missing","error":"..."}
  "win_calibrated": true -> window carries "calibrated":true (default false: the stub
                            has no model, so its windows are never calibrated)
  "legacy_no_feat": true     -> an older serve.py: no "feat", no "feature_schema"
  "feature_schema": "x"      -> stamp "x" instead of imu-feat-2 (layout mismatch test)
  "feat_nulls": true         -> cadence_hz and orientation_change_deg are JSON null
  "transition": "plain"      -> per-window "transition" evidence + transition_schema/version
  "transition": "null"       -> "transition" key present but JSON null (fail-open nil)
  "transition": "bad"        -> malformed "transition" object (fail-open nil, window intact)
  "experts": true            -> per-window HART "fine" + fine_schema, and two ElderNet gait_windows
                                (one gait with quality, one prefiltered, one malformed dropped) + gait_*
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
                # A01: the stub has no model, so it is never calibrated.
                "calibrated": False,
                "transition_version": "stub-transition",
            }
        elif op == "infer":
            run = req.get("run") or {}
            if req.get("respond_ok") is False:
                resp = {"id": rid, "ok": False, "kind": "model_missing",
                        "error": "stub model missing"}
            else:
                start_ts = run.get("start_ts")
                legacy = bool(req.get("legacy_no_feat"))
                knob = req.get("transition")
                windows = []
                if start_ts is not None:
                    window = {
                        "s": float(start_ts),
                        "e": float(start_ts) + 4.0,
                        "label": "stationary",
                        "probs": {"stationary": 0.9, "walking": 0.05,
                                  "running": 0.03, "other_movement": 0.02,
                                  "unknown": 0.0},
                        "baseline": False,
                        "calibrated": bool(req.get("win_calibrated", False)),
                    }
                    if not legacy:
                        nulls = bool(req.get("feat_nulls"))
                        window["feat"] = {
                            "accel_rms_g": 0.012,
                            "gyro_rms_dps": 3.5,
                            "jerk_rms_gps": 0.04,
                            "cadence_hz": None if nulls else 1.8,
                            "cadence_strength": 0.31,
                            "orientation_change_deg": None if nulls else 2.5,
                        }
                    # Optional transition-expert evidence (an older serve.py sends none).
                    if knob == "plain":
                        window["transition"] = {
                            "probs": {"none": 0.22, "sit_to_stand": 0.61,
                                      "stand_to_sit": 0.09, "lie_down": 0.05,
                                      "get_up": 0.03},
                            "label": "sit_to_stand",
                            "confidence": 0.61,
                            "abstained": False,
                            "ts": float(start_ts) + 1.77,
                        }
                    elif knob == "null":
                        window["transition"] = None
                    elif knob == "bad":
                        window["transition"] = {"probs": "not-an-object"}
                    if req.get("experts"):
                        window["fine"] = {"sitting": 0.7, "typing": 0.2, "standing": 0.1}
                    windows.append(window)
                resp = {
                    "id": rid,
                    "ok": True,
                    "model_version": "stub-model",
                    "preprocessing_version": "stub-preprocess",
                    "windows": windows,
                    "transition_schema": "transition-1" if knob else None,
                    "transition_version": "stub-transition" if knob else None,
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
                if not legacy:
                    resp["feature_schema"] = req.get("feature_schema") or "imu-feat-2"
                if req.get("experts") and start_ts is not None:
                    s0 = float(start_ts)
                    resp["fine_schema"] = "wisdm-act-1"
                    resp["gait_status"] = "gait_loaded"
                    resp["gait_schema"] = "gait-quality-1"
                    resp["gait_model_version"] = "stub-eldernet"
                    resp["gait_windows"] = [
                        {"s": s0, "e": s0 + 10.0, "gait_prob": 0.93, "is_gait": True,
                         "speed_mps": 1.21, "cadence_spm": 108.5, "stride_m": 1.3,
                         "regularity": 0.81, "steps": 18.0},
                        {"s": s0 + 5.0, "e": s0 + 15.0, "gait_prob": 0.0, "is_gait": False,
                         "prefiltered": True},
                        {"s": s0 + 10.0, "e": s0 + 10.0, "gait_prob": 0.5, "is_gait": False},
                    ]
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
