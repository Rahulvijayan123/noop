"""nara-metric-insight run | once | self-test"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from . import sandbox
from .config import Config, ConfigError
from .worker import Worker


def self_test(cfg: Config) -> int:
    """Prove the sandbox on this host: no internet, no reads of secrets, no writes outside the run directory,
    and an environment without secrets. Run before the service starts (ExecStartPre)."""
    mode = sandbox.resolve_mode(cfg.sandbox)
    if mode == "none":
        print(json.dumps({"ok": False, "reason": "sandbox disabled"}))
        return 1
    Path(cfg.work_root).mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="r-", dir=cfg.work_root))
    secret = Path(tempfile.mkdtemp(prefix="nara-selftest-secret-"))
    (secret / "db_url").write_text("canary")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    try:
        for name in ("agent", "work", "home", "tmp"):
            (run / name).mkdir()
        readable = sandbox.python_prefixes(cfg.kernel_python)
        # The real secrets and the worker's own state must be unreachable too, not just a planted canary.
        targets = [str(secret), *cfg.secret_paths]
        if os.environ.get("CREDENTIALS_DIRECTORY"):
            targets.append(os.environ["CREDENTIALS_DIRECTORY"])
        plan = sandbox.Plan(mode=mode, run_dir=str(run), proxy_port=port,
                            proxy_unix=str(run / "p.sock") if mode == "linux" else None, readable=readable,
                            deny_read=(*targets, *cfg.sandbox_deny_read))
        probes = [str(secret), *(t for t in targets[1:] if os.path.exists(t))]
        if mode == "linux":  # the worker's own state dir is not bound into the sandbox at all
            state_canary = Path(cfg.work_root).parent / ".selftest-canary"
            state_canary.write_text("canary")
            probes.append(str(state_canary))
        inner_env = {"PATH": "/usr/bin:/bin", "HOME": str(run / "home"), "TMPDIR": str(run / "tmp"), "LANG": "C.UTF-8"}
        results = []
        for target in probes:
            argv, outer_env = sandbox.wrap(plan, [cfg.kernel_python, "-c", sandbox.PROBE, str(port), target],
                                           dict(inner_env), cfg.kernel_python)
            done = subprocess.run(argv, env=outer_env, cwd=run / "work", capture_output=True, text=True, timeout=60)
            try:
                results.append(json.loads(done.stdout.strip().splitlines()[-1]))
            except (ValueError, IndexError):
                print(json.dumps({"ok": False, "reason": "probe failed", "stderr": done.stderr[-500:]}))
                return 1
        result = dict(results[0], secret_read="allowed" if any(r["secret_read"] == "allowed" for r in results)
                      else "blocked")
        allowed_env = {"PATH", "HOME", "TMPDIR", "LANG", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"}
        checks = {"internet_blocked": result["internet"] == "blocked",
                  "secret_read_blocked": result["secret_read"] == "blocked",
                  "write_outside_blocked": result["write_outside"] == "blocked",
                  "env_clean": set(result["env"]) <= allowed_env}
        print(json.dumps({"ok": all(checks.values()), "mode": mode, "checks": checks}))
        return 0 if all(checks.values()) else 1
    finally:
        listener.close()
        shutil.rmtree(run, ignore_errors=True)
        shutil.rmtree(secret, ignore_errors=True)
        (Path(cfg.work_root).parent / ".selftest-canary").unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="nara-metric-insight")
    parser.add_argument("command", choices=("run", "once", "self-test"), nargs="?", default="run")
    opts = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    if opts.command == "self-test":
        return self_test(cfg)
    worker = Worker(cfg)
    if opts.command == "once":
        outcome = worker.once()
        print(json.dumps({"outcome": outcome}))
        return 0
    worker.run_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
