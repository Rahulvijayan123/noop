"""Confinement for one Prime Agent process tree (the Rust host, its Python kernel, and the kernel's MCP shim).

The whole tree is confined, not just the kernel: model-written code can ask the host to act for it
(rlm.host_request), so the host must not have a way out either. Inside the sandbox the only reachable endpoints
are the job's LLM proxy and the job's tool broker; the only writable path is the job's run directory; the
environment is exactly what prime.py builds (no secrets).

* macOS (development only; NARA_SANDBOX=macos must be set explicitly): sandbox-exec. Network: IP egress denied
  except loopback to the proxy port; DNS denied. Reads denied for other jobs' run directories, the developer's
  home (except the interpreter's own paths) and secret paths. Writes denied outside the run directory and to the
  job's settings, provider config, auth file, curated harness and cwd. Known gaps, all absent on Linux: other
  same-uid processes' launch environments are readable (KERN_PROCARGS2), and Unix-domain sockets are not filtered
  (sandbox-exec's unix-socket and IP filters interfere with each other intermittently), so a local database
  socket without a password would be reachable. Never run it with real users' data.
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
    readable: tuple[str, ...]      # read-only paths the tree needs (Prime binary dir, kernel Python prefixes)
    deny_read: tuple[str, ...]     # macos: secret paths


def resolve_mode(requested: str) -> str:
    if requested == "none":
        return "none"
    if sys.platform == "darwin":
        if requested != "macos":  # never chosen implicitly: it is development-only (see the module docstring)
            raise SandboxUnavailable("the macOS sandbox is for development only; set NARA_SANDBOX=macos to use it")
        if not Path("/usr/bin/sandbox-exec").exists():
            raise SandboxUnavailable("sandbox-exec not found")
        return "macos"
    if requested in ("auto", "linux") and sys.platform.startswith("linux"):
        if not shutil.which("bwrap"):
            raise SandboxUnavailable("bubblewrap (bwrap) not found: apt install bubblewrap")
        return "linux"
    raise SandboxUnavailable(f"no sandbox for {sys.platform} (requested {requested!r})")


def python_prefixes(python: str) -> tuple[str, ...]:
    """The directories a Python interpreter needs at run time: its venv, the base installation, and every hop of
    the symlink chain in between (uv venvs point at a versioned link such as cpython-3.11-... -> cpython-3.11.15-...),
    both as linked and as resolved."""
    out = subprocess.run([python, "-c", "import sys, json; print(json.dumps([sys.prefix, sys.base_prefix]))"],
                         capture_output=True, text=True, timeout=30, check=True, env={"PATH": "/usr/bin:/bin"})
    prefix, base = json.loads(out.stdout)
    paths = [prefix, base]
    hop = os.path.abspath(python)
    for _ in range(16):
        paths.append(os.path.dirname(hop))
        if not os.path.islink(hop):
            break
        target = os.readlink(hop)
        hop = target if os.path.isabs(target) else os.path.normpath(os.path.join(os.path.dirname(hop), target))
    venv_cfg = Path(prefix) / "pyvenv.cfg"
    if venv_cfg.exists():
        for line in venv_cfg.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "home" and value.strip():
                paths += [value.strip(), os.path.dirname(value.strip())]
    return tuple(dict.fromkeys([os.path.abspath(p) for p in paths] + [os.path.realpath(p) for p in paths]))


def _sbpl_path(path: str, *, resolve: bool = True) -> str:
    resolved = os.path.realpath(path) if resolve else os.path.abspath(path)
    if '"' in resolved or "\\" in resolved:
        raise SandboxUnavailable(f"unsupported character in sandbox path {resolved!r}")
    return resolved


def _both(path: str) -> list[str]:
    """A path as given and as resolved: a symlink in it (a uv python link) must be readable itself."""
    return list(dict.fromkeys([_sbpl_path(path, resolve=False), _sbpl_path(path)]))


def macos_profile(plan: Plan) -> str:
    run = _sbpl_path(plan.run_dir)
    work_root = _sbpl_path(os.path.dirname(run))
    home = _sbpl_path(os.path.expanduser("~"))
    profile = ['(version 1)', '(allow default)',
               '(deny network-outbound (remote ip "*:*"))',
               '(deny network-outbound (literal "/private/var/run/mDNSResponder"))',
               f'(allow network-outbound (remote ip "localhost:{int(plan.proxy_port)}"))',
               # Reads: not other jobs' run directories, not the developer's home (except what the tree needs).
               f'(deny file-read* (subpath "{work_root}") (subpath "{home}"))',
               f'(allow file-read* (subpath "{run}")'
               + "".join(f' (subpath "{q}")' for p in plan.readable for q in _both(p)) + ')',
               '(deny file-write* (subpath "/"))',
               f'(allow file-write* (subpath "/dev") (subpath "{run}"))',
               # Read-only to the whole tree: the job's settings, provider config and curated harness, and the cwd
               # (project settings there would override them). Prime keeps its own MCP/runtime state elsewhere in
               # the agent dir, so that stays writable, as do HOME and TMPDIR.
               f'(deny file-write* (literal "{run}/agent/settings.json") (literal "{run}/agent/models.json")'
               f' (literal "{run}/agent/auth.json") (subpath "{run}/agent/harness") (subpath "{run}/work"))']
    for path in plan.deny_read:
        if os.path.exists(path):
            profile.append(f'(deny file-read* (subpath "{_sbpl_path(path)}"))')
    return "".join(profile)


def linux_argv(plan: Plan, argv: list[str], env: dict[str, str], kernel_python: str) -> list[str]:
    run = os.path.realpath(plan.run_dir)
    out = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv", "--cap-drop", "ALL",
           "--ro-bind", "/usr", "/usr"]
    for path in ("/bin", "/sbin", "/lib", "/lib64", "/etc/ld.so.cache", "/etc/localtime", "/etc/alternatives"):
        out += ["--ro-bind-try", path, path]
    for path in plan.readable:
        out += ["--ro-bind", path, path]
    out += ["--bind", run, run]
    for path in (f"{run}/agent/settings.json", f"{run}/agent/models.json", f"{run}/agent/auth.json",
                 f"{run}/agent/harness", f"{run}/work"):
        out += ["--ro-bind", path, path]
    out += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", f"{run}/work"]
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
