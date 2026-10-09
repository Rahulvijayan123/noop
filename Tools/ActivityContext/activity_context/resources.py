"""Memory and thread use of one activity serve process (docs/model-integration/activity-authority.md, "Resources").

    python -m activity_context.resources [--hours 1] [--hop-s N] [--threads N] [--uncapped] [--label L]
        -- <serve argv after the interpreter, e.g. -m activity_context.serve --manifest m.json --checkpoint dir>

Starts the serve process the way the worker does (line-delimited JSON on stdin/stdout, the numerical-library thread
caps ``ActivityPythonService`` passes unless ``--uncapped``), pings it, sends ``--hours`` one-hour requests of a
deterministic synthetic walk (``eldernet.bench.synth_hour``), and prints one JSON object: resident memory after
load and after the requests (``ps``), the child's peak resident memory (``wait4`` ru_maxrss), its OS thread count
after the requests, request latency, and the ``loaded`` identity it reported. Nothing here reads a database or a
network; it is a local or staging probe, not something to run beside a loaded worker.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from typing import Dict, List, Optional

from .inertia.subproc import PYTHON_ENV_ALLOWLIST, safe_env

THREAD_ENV = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
              "NUMEXPR_NUM_THREADS")
# What a serve child may read from this process's environment (never the whole of it, inertia/subproc.py).
CHILD_ENV_ALLOWLIST = PYTHON_ENV_ALLOWLIST + ("ELDERNET_WEIGHTS_DIR", "ELDERNET_UPSTREAM_DIR", "RECGYM_WEIGHTS_PATH",
                                              "ACTIVITY_THREADS",
                                              "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE")


def child_env(threads: Optional[int]) -> Dict[str, str]:
    """The environment for the probed child: the allowlisted variables plus, unless ``threads`` is None, the
    numerical-library thread caps the worker gives every activity child (`ActivityPythonService` passes the same)."""
    caps = {key: str(threads) for key in THREAD_ENV} if threads is not None else {}
    caps["PYTHONUNBUFFERED"] = "1"
    allow = CHILD_ENV_ALLOWLIST if threads is None else tuple(k for k in CHILD_ENV_ALLOWLIST if k not in THREAD_ENV)
    return safe_env(caps, allow)


def rss_kib(pid: int) -> Optional[int]:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
    try:
        return int(out.stdout.strip())
    except ValueError:
        return None


def thread_count(pid: int) -> Optional[int]:
    task = f"/proc/{pid}/task"
    if os.path.isdir(task):
        return len(os.listdir(task))
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True)
    lines = [ln for ln in out.stdout.splitlines()[1:] if ln.strip()]
    return len(lines) or None


def _send(proc: subprocess.Popen, req: Dict) -> Dict:
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("serve process closed stdout")
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("id") == req["id"]:
            return obj


def measure(argv: List[str], *, hours: int = 1, hop_s: Optional[int] = None, threads: int = 1,
            uncapped: bool = False, cwd: Optional[str] = None) -> Dict:
    from .eldernet.bench import hour_request, synth_hour
    env = child_env(None if uncapped else threads)
    t0 = time.perf_counter()
    proc = subprocess.Popen([sys.executable] + argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env, cwd=cwd)
    try:
        ping = _send(proc, {"id": "ping", "op": "ping"})
        load_s = time.perf_counter() - t0
        after_load = rss_kib(proc.pid)
        latencies, ok = [], 0
        acc = synth_hour("walk")
        for h in range(hours):
            req = hour_request(acc, hop_s or 5, f"h{h}")
            if hop_s is None:
                req["run"].pop("hop_s", None)
            t = time.perf_counter()
            resp = _send(proc, req)
            latencies.append(round(time.perf_counter() - t, 3))
            ok += 1 if resp.get("ok") else 0
        after = rss_kib(proc.pid)
        threads_seen = thread_count(proc.pid)
        _send(proc, {"id": "bye", "op": "shutdown"})
    finally:
        proc.stdin.close()
    _, status, usage = os.wait4(proc.pid, 0)
    # ru_maxrss is bytes on macOS and KiB on Linux.
    peak = usage.ru_maxrss // 1024 if platform.system() == "Darwin" else usage.ru_maxrss
    return {"argv": argv, "platform": f"{platform.system()} {platform.machine()}", "python": platform.python_version(),
            "thread_caps": None if uncapped else threads, "model_available": ping.get("model_available",
                                                                                      ping.get("ok")),
            "model_status": ping.get("model_status"), "load_s": round(load_s, 2),
            "rss_after_load_kib": after_load, "rss_after_requests_kib": after, "peak_rss_kib": peak,
            "os_threads": threads_seen, "requests_ok": ok, "request_s": latencies,
            "loaded": ping.get("loaded"), "exit_status": status}


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--" not in argv:
        print("usage: python -m activity_context.resources [options] -- <serve argv>", file=sys.stderr)
        return 2
    split = argv.index("--")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--hours", type=int, default=1)
    ap.add_argument("--hop-s", type=int, default=None)
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--uncapped", action="store_true", help="do not pass the thread caps (what a child got before)")
    ap.add_argument("--label", default=None)
    args = ap.parse_args(argv[:split])
    out = measure(argv[split + 1:], hours=args.hours, hop_s=args.hop_s, threads=args.threads,
                  uncapped=args.uncapped)
    if args.label:
        out["label"] = args.label
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
