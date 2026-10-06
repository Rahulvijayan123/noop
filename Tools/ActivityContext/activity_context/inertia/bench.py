"""Inertia performance measurement (spec §21.7).

    python -m activity_context.inertia.bench [--out eval/inertia/perf.json] [--quick]

Measures, for the vendored ART and PatchTST ``small`` presets at 30 s and 10 s windows (each in a fresh
subprocess so load time and peak RSS are per model): torch import time, model load time (sha256 +
torch.load + strict load), steady-state batch latency at batch 1 / 64 / 256, windows/s, CPU utilisation
((user+sys)/wall) at batch 256, a thread scan at batch 64, and peak RSS. Then the full serve-request latency
for a 1-hour run at hop 5 s (decode + inertia-prep-1 + embed + heads + OOD + JSON) for ART/PatchTST small
30 s and the handcrafted stand-in.

Weights are SEEDED RANDOM (``make_test_checkpoint``): latency and memory do not depend on weight values, so
these numbers stand in for the real checkpoint's. They are NOT Inertia-1 results of any kind.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List

import numpy as np

DEFAULT_OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "eval", "inertia", "perf.json"))
CONFIGS = [("ar_transformer", "small", 30), ("ar_transformer", "small", 10), ("patchtst", "small", 30),
           ("patchtst", "small", 10)]
NOTE = ("seeded random-init weights of the vendored architectures (latency/memory do not depend on weight "
        "values); NOT Inertia-1 results")


def _peak_rss_mb() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(r / (1024 * 1024) if sys.platform == "darwin" else r / 1024, 1)


def _cpu() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


def _batch(window_s: int, b: int, seed: int = 0) -> np.ndarray:
    x = np.random.default_rng(seed).normal(0, 0.3, size=(b, 3, window_s * 20)).astype(np.float32)
    x[:, 2] += 1.0
    return x


def _time(fn, reps: int) -> List[float]:
    fn()                                                   # warm-up
    out = []
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        out.append((time.perf_counter() - t0) * 1000.0)
    return out


def bench_one(method: str, preset: str, window_s: int, quick: bool) -> Dict[str, Any]:
    t0 = time.perf_counter()
    import torch
    torch_import_s = time.perf_counter() - t0
    from .adapter import Inertia1Encoder, make_test_checkpoint
    tmp = tempfile.mkdtemp(prefix="inertia-bench-")
    path = os.path.join(tmp, "bench.ckpt")
    cfg = make_test_checkpoint(path, method, preset, window_s, seed=0)
    loads = []
    for _ in range(2 if quick else 3):
        t = time.perf_counter()
        enc = Inertia1Encoder(path, cfg, threads=1)
        loads.append(time.perf_counter() - t)
    reps = {1: 5 if quick else 20, 64: 2 if quick else 5, 256: 1 if quick else 3}
    batches: Dict[str, Any] = {}
    for b, n in reps.items():
        x = _batch(window_s, b)
        c0, w0 = _cpu(), time.perf_counter()
        ms = _time(lambda: enc.embed(x), n)
        cpu_util = (_cpu() - c0) / (time.perf_counter() - w0)
        med = statistics.median(ms)
        batches[str(b)] = {"median_ms": round(med, 2), "min_ms": round(min(ms), 2), "reps": n,
                           "windows_per_s": round(b / med * 1000.0, 1), "cpu_util": round(cpu_util, 2)}
    scan: Dict[str, float] = {}
    x = _batch(window_s, 64)
    for th in sorted({1, 4, os.cpu_count() or 1}):
        torch.set_num_threads(th)
        scan[str(th)] = round(statistics.median(_time(lambda: enc.embed(x), 1 if quick else 3)), 2)
    torch.set_num_threads(1)
    return {"method": method, "preset": preset, "window_s": window_s, "embedding_dim": enc.info.embedding_dim,
            "params": int(sum(p.numel() for p in enc.module.parameters())),
            "checkpoint_bytes": os.path.getsize(path), "torch_import_s": round(torch_import_s, 3),
            "load_s_first": round(loads[0], 3), "load_s_median": round(statistics.median(loads), 3),
            "threads": 1, "batch": batches, "thread_scan_batch64_median_ms": scan, "peak_rss_mb": _peak_rss_mb()}


def _one_hour_request(seed: int = 0) -> Dict[str, Any]:
    from .make_golden import T0, synth_columns
    n = 3 + 3600 + 3
    segs = [("still", 900), ("seated", 1200), ("walk", 900), ("still", n - 3000)]
    cols = synth_columns(n, seed, segs)
    from ..preprocess import encode_columns_b64
    b64 = [encode_columns_b64(c) for c in cols]
    return {"id": "bench-1h", "op": "infer", "run": {
        "start_ts": T0, "end_ts": T0 + 3600, "sample_rate_hz": 100,
        "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
        "columns_b64": b64[3:3603], "head_b64": b64[:3], "tail_b64": b64[3603:], "hop_s": 5}}


def bench_serve(spec: str, quick: bool, max_batch: int = 64) -> Dict[str, Any]:
    """Full in-process request latency (same code path as the serve loop) for a 1 h run at hop 5 s."""
    from .bundle import encoder_block, write_bundle
    from .runtime import build_runtime
    from .serve import handle_line
    from .synthetic import synthetic_bundle_parts
    tmp = tempfile.mkdtemp(prefix="inertia-bench-serve-")
    if spec == "handcrafted":
        from .registry import build_encoder
        enc, ckpt, cfg = build_encoder("standin:handcrafted-stats-v1"), None, None
    else:
        from .adapter import Inertia1Encoder, make_test_checkpoint
        method, preset, w = spec.split(":")
        ckpt = os.path.join(tmp, "bench.ckpt")
        cfg = make_test_checkpoint(ckpt, method, preset, int(w), seed=0)
        enc = Inertia1Encoder(ckpt, cfg)
    ref = enc.embed(_batch(30, 48, seed=1)).astype(np.float64)
    bdir = os.path.join(tmp, "bundle")
    extra = {"encoder.json": json.dumps(cfg)} if cfg else {}
    write_bundle(bdir, **synthetic_bundle_parts(encoder=encoder_block(enc.info), reference=ref), extra_files=extra)
    t = time.perf_counter()
    rt = build_runtime(bdir, checkpoint=ckpt, allow_standin_shadow=True, max_batch=max_batch)
    load_s = time.perf_counter() - t
    assert rt.error is None, rt.error
    line = json.dumps(_one_hour_request())
    times, out = [], ""
    for _ in range(1 if quick else 3):
        t = time.perf_counter()
        out, _stop = handle_line(rt, line, timeout=0.0)
        times.append((time.perf_counter() - t) * 1000.0)
    resp = json.loads(out)
    assert resp["ok"], resp
    return {"encoder": rt.info.encoder_id, "runtime_load_s": round(load_s, 3), "windows": len(resp["windows"]),
            "request_bytes": len(line), "response_bytes": len(out), "median_ms": round(statistics.median(times), 1),
            "reps": len(times), "threads": 1, "max_batch": rt.max_batch, "peak_rss_mb": _peak_rss_mb()}


def _sub(args: List[str]) -> Dict[str, Any]:
    env = dict(os.environ)
    pkg = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
    env["PYTHONPATH"] = pkg + os.pathsep + env.get("PYTHONPATH", "")
    r = subprocess.run([sys.executable, "-m", "activity_context.inertia.bench", *args], capture_output=True,
                       text=True, env=env, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-2000:])
    return json.loads(r.stdout.strip().splitlines()[-1])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Inertia performance measurement (seeded random weights)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--quick", action="store_true", help="fewer repetitions")
    ap.add_argument("--one", default=None, help=argparse.SUPPRESS)      # method:preset:window (subprocess)
    ap.add_argument("--serve", default=None, help=argparse.SUPPRESS)    # serve spec (subprocess)
    args = ap.parse_args(argv)
    if args.one:
        m, p, w = args.one.split(":")
        print(json.dumps(bench_one(m, p, int(w), args.quick)))
        return 0
    if args.serve:
        spec, _, mb = args.serve.partition("@")
        print(json.dumps(bench_serve(spec, args.quick, int(mb or 64))))
        return 0
    import scipy
    import torch
    q = ["--quick"] if args.quick else []
    result = {
        "schema": "nara.inertia.perf/1", "note": NOTE, "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "machine": {"platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
                    "python": platform.python_version(), "torch": torch.__version__, "numpy": np.__version__,
                    "scipy": scipy.__version__},
        "encoders": [_sub(["--one", f"{m}:{p}:{w}", *q]) for m, p, w in CONFIGS],
        "serve_request_1h_hop5": [_sub(["--serve", s, *q]) for s in
                                  ("ar_transformer:small:30", "ar_transformer:small:30@256",
                                            "patchtst:small:30", "handcrafted")],
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
