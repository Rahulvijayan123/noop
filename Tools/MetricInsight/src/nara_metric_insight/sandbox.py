"""Confinement for one Prime Agent process tree (the Rust host, its Python kernel, and the kernel's MCP shim).

The whole tree is confined, not just the kernel: model-written code can ask the host to act for it
(rlm.host_request), so the host must not have a way out either. Inside the sandbox the only reachable endpoints
are the job's LLM proxy and the job's tool broker; the only writable path is the job's run directory; the
environment is exactly what prime.py builds (no secrets).

* macOS (development): sandbox-exec. Network: IP egress denied except loopback to the proxy port; DNS denied.
  Writes denied outside the run directory; reads of secret paths denied.
* Linux (production): bubblewrap with every namespace unshared (no network route at all, own PID namespace,
  dies with its parent), read-only binds of the system, the Prime binary and the kernel Python, and the run
  directory. A forwarder inside the namespace turns the proxy's Unix socket into the loopback port Prime calls.
* none: no confinement. Refused unless NARA_SANDBOX=none is set explicitly (local tests of the protocol only).

`self_test` (cli: `nara-metric-insight self-test`) proves the confinement on the host before the service starts.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

FORWARDER = Path(__file__).resolve().parent / "forwarder.py"


class SandboxUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class Plan:
    mode: str                      # macos | linux | none
    run_dir: str
    proxy_port: int                # the loopback port Prime's provider URL names
    proxy_unix: str | None         # linux: the proxy's socket the forwarder connects to
    readable: tuple[str, ...]      # linux: extra read-only binds (Prime binary dir, kernel Python prefixes)
    deny_read: tuple[str, ...]     # macos: secret paths


def resolve_mode(requested: str) -> str:
    if requested == "none":
        return "none"
    if requested in ("auto", "macos") and sys.platform == "darwin":
        if not Path("/usr/bin/sandbox-exec").exists():
            raise SandboxUnavailable("sandbox-exec not found")
        return "macos"
    if requested in ("auto", "linux") and sys.platform.startswith("linux"):
        if not shutil.which("bwrap"):
            raise SandboxUnavailable("bubblewrap (bwrap) not found: apt install bubblewrap")
        return "linux"
    raise SandboxUnavailable(f"no sandbox for {sys.platform} (requested {requested!r})")


def python_prefixes(python: str) -> tuple[str, ...]:
    """The directories a Python interpreter needs at run time (its venv and the base installation)."""
    out = subprocess.run([python, "-c", "import sys, json; print(json.dumps([sys.prefix, sys.base_prefix]))"],
                         capture_output=True, text=True, timeout=30, check=True, env={"PATH": "/usr/bin:/bin"})
    return tuple(dict.fromkeys(os.path.realpath(p) for p in json.loads(out.stdout)))


def _sbpl_path(path: str) -> str:
    resolved = os.path.realpath(path)
    if '"' in resolved or "\\" in resolved:
        raise SandboxUnavailable(f"unsupported character in sandbox path {resolved!r}")
    return resolved


def macos_profile(plan: Plan) -> str:
    run = _sbpl_path(plan.run_dir)
    profile = ['(version 1)', '(allow default)',
               '(deny network-outbound (remote ip "*:*"))',
               '(deny network-outbound (literal "/private/var/run/mDNSResponder"))',
               f'(allow network-outbound (remote ip "localhost:{int(plan.proxy_port)}"))',
               '(deny file-write* (subpath "/"))',
               f'(allow file-write* (subpath "/dev") (subpath "{run}"))']
    for path in plan.deny_read:
        if os.path.exists(path):
            profile.append(f'(deny file-read* (subpath "{_sbpl_path(path)}"))')
    return "".join(profile)


def linux_argv(plan: Plan, argv: list[str], env: dict[str, str], kernel_python: str) -> list[str]:
    run = os.path.realpath(plan.run_dir)
    out = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
           "--ro-bind", "/usr", "/usr"]
    for path in ("/bin", "/sbin", "/lib", "/lib64", "/etc/ld.so.cache", "/etc/localtime", "/etc/alternatives"):
        out += ["--ro-bind-try", path, path]
    for path in plan.readable:
        out += ["--ro-bind", path, path]
    out += ["--bind", run, run, "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", f"{run}/work"]
    for key, value in sorted(env.items()):
        out += ["--setenv", key, value]
    assert plan.proxy_unix
    return out + ["--", kernel_python, f"{run}/agent/forwarder.py", "--listen", f"127.0.0.1:{plan.proxy_port}",
                  "--unix", plan.proxy_unix, "--", *argv]


def wrap(plan: Plan, argv: list[str], env: dict[str, str], kernel_python: str) -> tuple[list[str], dict[str, str]]:
    if plan.mode == "macos":
        return ["/usr/bin/sandbox-exec", "-p", macos_profile(plan), *argv], env
    if plan.mode == "linux":
        shutil.copy(FORWARDER, Path(plan.run_dir) / "agent" / "forwarder.py")
        return linux_argv(plan, argv, env, kernel_python), {"PATH": "/usr/bin:/bin"}
    if plan.mode == "none":
        return argv, env
    raise SandboxUnavailable(plan.mode)


PROBE = r"""
import json, os, socket, sys, urllib.request
out = {}
try:
    urllib.request.urlopen("https://example.com", timeout=3); out["internet"] = "reachable"
except Exception as exc:
    out["internet"] = "blocked"
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2).close(); out["proxy_port"] = "reachable"
except Exception:
    out["proxy_port"] = "blocked"
denied = sys.argv[2]
try:
    os.listdir(denied) if os.path.isdir(denied) else open(denied, "rb").read(1); out["secret_read"] = "allowed"
except Exception:
    out["secret_read"] = "blocked"
try:
    open("/etc/nara-sandbox-write-probe", "w").write("x"); out["write_outside"] = "allowed"
except Exception:
    out["write_outside"] = "blocked"
out["env"] = sorted(os.environ)
print(json.dumps(out))
"""
