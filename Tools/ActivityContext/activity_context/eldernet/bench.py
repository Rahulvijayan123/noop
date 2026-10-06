"""Latency / RAM of the ElderNet serve process for 1-hour WHOOP requests (ELDERNET.md §7).

    python -m activity_context.eldernet.bench [--weights-dir DIR] [--npy hour.npy ...] [--out perf.json]

Spawns ``python -m activity_context.eldernet.serve`` (1 torch thread, batch 64), waits for ``ping``, sends
1-hour NPB1 requests at hop 5 (served default) and hop 1 (upstream stride), and reports wall latency per
request, the serve's ``duration_ms``, window / gait-window counts, response bytes and the child's peak RSS
(``wait4`` ru_maxrss). Inputs: a deterministic synthetic worst case (60 min of 1.8 Hz arm-swing gait, every
window classified and quality-scored), a synthetic rest hour (every window pre-filtered) and any
``--npy`` [360000, 3] g arrays at 100 Hz (e.g. a public Capture-24 hour).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Dict, List, Optional, Sequence

import numpy as np

from ..preprocess import encode_columns_b64

T0 = 1758000000


def synth_hour(kind: str, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = np.arange(360000) / 100.0
    x = np.zeros((t.size, 3))
    x[:, 2] = 1.0
    if kind == "walk":
        x[:, 0] += 0.35 * np.sin(2 * np.pi * 0.9 * t)
        x[:, 1] += 0.15 * np.sin(2 * np.pi * 1.8 * t + 0.4)
        x[:, 2] += 0.25 * np.sin(2 * np.pi * 1.8 * t) ** 3
        x += rng.normal(0, 0.02, x.shape)
    else:
        x += rng.normal(0, 0.002, x.shape)
    return x


def hour_request(acc: np.ndarray, hop_s: int, req_id: str) -> Dict:
    q = np.clip(np.rint(np.asarray(acc)[:360000] * 4096.0), -32768, 32767).astype(np.int16)
    n = q.shape[0] // 100
    blk = q[:n * 100].reshape(n, 100, 3).transpose(0, 2, 1).reshape(n, 300)
    cols = np.concatenate([blk, np.zeros((n, 300), np.int16)], axis=1)
    return {"id": req_id, "op": "infer", "run": {"start_ts": T0, "end_ts": T0 + n, "sample_rate_hz": 100,
            "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": [encode_columns_b64(c) for c in cols], "hop_s": hop_s}}


def bench(weights_dir: Optional[str], inputs: Dict[str, np.ndarray], hops: Sequence[int] = (5, 1),
          repeats: int = 2) -> Dict:
    pkg = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    from ..inertia.subproc import PYTHON_ENV_ALLOWLIST, safe_env
    env = safe_env({"PYTHONPATH": pkg, "OMP_NUM_THREADS": "1"}, PYTHON_ENV_ALLOWLIST)
    args = [sys.executable, "-m", "activity_context.eldernet.serve", "--timeout", "600"]
    if weights_dir:
        args += ["--weights-dir", weights_dir]
    t0 = time.perf_counter()
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                            text=True, bufsize=1)

    def send(req):
        proc.stdin.write(json.dumps(req, separators=(",", ":")) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        return line, json.loads(line)
    _, ping = send({"id": "p", "op": "ping"})
    out: Dict = {"load_to_ping_s": round(time.perf_counter() - t0, 3), "model_available": ping["model_available"],
                 "runs": []}
    if not ping["model_available"]:
        raise SystemExit(f"weights unavailable: {ping['model_error']}")
    for name, acc in inputs.items():
        for hop in hops:
            req = hour_request(acc, hop, f"{name}-h{hop}")
            req_bytes = len(json.dumps(req, separators=(",", ":")))
            lat: List[float] = []
            for _ in range(repeats):
                t1 = time.perf_counter()
                line, resp = send(req)
                lat.append(time.perf_counter() - t1)
            if not resp.get("ok"):
                raise SystemExit(f"{name} hop {hop}: {resp}")
            w = resp["windows"]
            out["runs"].append({"input": name, "hop_s": hop, "n_windows": len(w),
                                "n_gait": sum(1 for x in w if x["is_gait"]),
                                "n_prefiltered": sum(1 for x in w if x.get("prefiltered")),
                                "wall_s": [round(v, 3) for v in lat], "serve_duration_ms": resp["duration_ms"],
                                "request_bytes": req_bytes, "response_bytes": len(line)})
    send({"id": "bye", "op": "shutdown"})
    _, status, ru = os.wait4(proc.pid, 0)
    for s in (proc.stdin, proc.stdout, proc.stderr):
        s.close()
    scale = 1 if sys.platform == "darwin" else 1024          # ru_maxrss: bytes on macOS, KiB on Linux
    out["serve_peak_rss_mb"] = round(ru.ru_maxrss * scale / 2 ** 20, 1)
    out["platform"] = {"python": sys.version.split()[0], "machine": os.uname().machine,
                       "torch_threads": 1, "max_batch": 64, "cpu_count": os.cpu_count(),
                       "load_avg_1m_at_end": round(os.getloadavg()[0], 1)}
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet serve latency / RAM for 1-hour WHOOP requests")
    ap.add_argument("--weights-dir", default=None)
    ap.add_argument("--npy", nargs="*", default=[], help="[>=360000, 3] g arrays at 100 Hz (public data)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--repeats", type=int, default=2)
    args = ap.parse_args(argv)
    inputs = {"synthetic_walk_hour": synth_hour("walk"), "synthetic_rest_hour": synth_hour("rest")}
    for p in args.npy:
        inputs[os.path.basename(p)[:-4]] = np.load(p)[:360000]
    res = bench(args.weights_dir, inputs, repeats=args.repeats)
    text = json.dumps(res, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
