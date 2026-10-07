"""Broker + MCP shim, LLM proxy, sandbox. No database, no model."""

from __future__ import annotations

import http.client
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from nara_metric_insight import sandbox
from nara_metric_insight.broker import Broker
from nara_metric_insight.literature import Literature
from nara_metric_insight.llm_proxy import LlmProxy
from nara_metric_insight.tools import JobTools, ToolError

SHIM = Path(__file__).resolve().parents[1] / "src" / "nara_metric_insight" / "mcp_shim.py"
ANCHOR = date(2026, 10, 6)


class FakeSources:
    """In-memory stand-in for sources.Sources (the PostgreSQL tests cover the real loaders)."""

    def __init__(self) -> None:
        self.loaded: list[str] = []
        self._scores = {ANCHOR - timedelta(days=i): {"day": ANCHOR - timedelta(days=i), "resting_hr_bpm": 50 - (i % 4),
                                                    "hrv_rmssd_ms": 70 + i, "source_device_id": "d"} for i in range(10)}

    def scores(self):
        return self._scores

    def context(self):
        return None, None

    def exposures(self):
        return []

    def memory(self):
        return [{"topic": "training", "content": "Marathon block", "importance": 4}]

    def previous_insight(self):
        return None


def job_tools() -> JobTools:
    return JobTools(user_id="11111111-1111-4111-8111-111111111111", metric="resting_hr", anchor=ANCHOR,
                    timezone_id="America/Los_Angeles", sources=FakeSources(), literature=Literature())


@pytest.fixture()
def short_dir():
    path = Path(tempfile.mkdtemp(prefix="mi-", dir="/tmp"))
    yield path
    shutil.rmtree(path, ignore_errors=True)


def test_tools_refuse_any_scope_argument():
    tools = job_tools()
    for args in ({"user_id": "22222222-2222-4222-8222-222222222222"}, {"day": "2026-10-01"}, {"days": 3},
                 {"days": True}):
        with pytest.raises(ToolError):
            tools.call("get_metric_series", args)
    with pytest.raises(ToolError):
        tools.call("get_everything", {})
    assert tools.call("get_metric_series", {"days": 7})["measured_nights"] == 7
    assert tools.calls == ["get_metric_series"]


class Shim:
    def __init__(self, socket_path: str, token: str) -> None:
        self.proc = subprocess.Popen([sys.executable, str(SHIM), "--socket", socket_path, "--token", token],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.ids = 0

    def call(self, method: str, params: dict | None = None) -> dict:
        self.ids += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.ids, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def test_broker_and_shim_serve_only_the_bound_job(short_dir):
    tools = job_tools()
    with Broker(str(short_dir / "b.sock"), "job-token", tools):
        shim = Shim(str(short_dir / "b.sock"), "job-token")
        try:
            assert shim.call("initialize", {"protocolVersion": "2025-06-18"})["result"]["serverInfo"]["name"] == "nara"
            listed = shim.call("tools/list")["result"]["tools"]
            assert {t["name"] for t in listed} >= {"get_metric_summary", "get_metric_series", "search_literature"}
            assert all(t["inputSchema"]["additionalProperties"] is False for t in listed)
            summary = shim.call("tools/call", {"name": "get_metric_summary", "arguments": {}})["result"]
            assert summary["isError"] is False and summary["structuredContent"]["latest"]["value"] == 50
            other = shim.call("tools/call", {"name": "get_metric_series",
                                             "arguments": {"user_id": "22222222-2222-4222-8222-222222222222"}})["result"]
            assert other["isError"] is True and "unexpected argument" in other["structuredContent"]["error"]
            notes = shim.call("tools/call", {"name": "get_user_context", "arguments": {}})["result"]
            assert notes["structuredContent"]["items"][0]["note"] == "Marathon block"
        finally:
            shim.close()
        intruder = Shim(str(short_dir / "b.sock"), "guessed-token")
        try:
            assert "error" in intruder.call("tools/list")
            denied = intruder.call("tools/call", {"name": "get_metric_summary", "arguments": {}})["result"]
            assert denied["isError"] is True and denied["structuredContent"]["error"] == "unauthorized"
        finally:
            intruder.close()
    assert tools.calls == ["get_metric_summary", "get_user_context"]


class Upstream:
    """A fake provider: records what reached it, streams a tiny SSE completion with usage."""

    def __init__(self) -> None:
        self.seen: list[tuple[str, dict, str]] = []
        upstream = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                upstream.seen.append((self.path, body, self.headers.get("Authorization")))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for event in ({"choices": [{"delta": {"content": "ok"}}]},
                              {"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 3}}):
                    self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/inference/v1"


def post(port: int, token: str, body: dict) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("POST", "/v1/chat/completions", body=json.dumps(body),
                       headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    response = connection.getresponse()
    return response.status, response.read()


def test_llm_proxy_holds_the_key_pins_the_model_and_enforces_the_budget():
    upstream = Upstream()
    with LlmProxy(upstream=upstream.url, api_key="provider-secret", model="pinned-model", token="job-llm-token",
                  max_requests=2, max_tokens=256) as proxy:
        status, _ = post(proxy.listen_port, "wrong", {"model": "x", "messages": []})
        assert status == 401 and upstream.seen == []
        status, body = post(proxy.listen_port, "job-llm-token",
                            {"model": "attacker-choice", "max_tokens": 100000, "stream": True, "messages": []})
        assert status == 200 and b"[DONE]" in body
        path, forwarded, authorization = upstream.seen[0]
        assert path == "/inference/v1/chat/completions"
        assert forwarded["model"] == "pinned-model" and forwarded["max_tokens"] == 256
        assert authorization == "Bearer provider-secret"
        assert proxy.prompt_tokens == 11 and proxy.completion_tokens == 3
        assert post(proxy.listen_port, "job-llm-token", {"messages": []})[0] == 200
        assert post(proxy.listen_port, "job-llm-token", {"messages": []})[0] == 429  # third call: budget
    upstream.server.shutdown()


@pytest.mark.skipif(sys.platform != "darwin", reason="sandbox-exec is macOS")
def test_macos_sandbox_blocks_egress_secret_reads_and_writes(short_dir):
    run = short_dir / "run"
    for name in ("agent", "work", "home", "tmp"):
        (run / name).mkdir(parents=True)
    secret = short_dir / "secrets"
    secret.mkdir()
    (secret / "db_url").write_text("canary")
    allowed, other = socket.socket(), socket.socket()
    for listener in (allowed, other):
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
    probe = (
        "import json, os, socket, urllib.request, sys\n"
        "out = {}\n"
        "def reach(port):\n"
        "    try:\n"
        "        socket.create_connection(('127.0.0.1', port), timeout=2).close(); return True\n"
        "    except OSError:\n"
        "        return False\n"
        "out['proxy'] = reach(int(sys.argv[1])); out['other'] = reach(int(sys.argv[2]))\n"
        "try:\n"
        "    urllib.request.urlopen('https://example.com', timeout=3); out['internet'] = True\n"
        "except Exception:\n"
        "    out['internet'] = False\n"
        "try:\n"
        "    open(sys.argv[3]).read(); out['secret'] = True\n"
        "except Exception:\n"
        "    out['secret'] = False\n"
        "try:\n"
        "    open(sys.argv[4], 'w').write('x'); out['write_run'] = True\n"
        "except Exception:\n"
        "    out['write_run'] = False\n"
        "try:\n"
        "    open(sys.argv[5], 'w').write('x'); out['write_agent'] = True\n"
        "except Exception:\n"
        "    out['write_agent'] = False\n"
        "try:\n"
        "    open(os.path.expanduser('~/nara-sandbox-probe'), 'w'); out['write_home'] = True\n"
        "except Exception:\n"
        "    out['write_home'] = False\n"
        "print(json.dumps(out))\n")
    plan = sandbox.Plan(mode="macos", run_dir=str(run), proxy_port=allowed.getsockname()[1], proxy_unix=None,
                        readable=(), deny_read=(str(secret),))
    argv, env = sandbox.wrap(plan, [sys.executable, "-c", probe, str(allowed.getsockname()[1]),
                                    str(other.getsockname()[1]), str(secret / "db_url"), str(run / "tmp" / "ok"),
                                    str(run / "agent" / "settings.json")],
                             {"PATH": "/usr/bin:/bin", "HOME": "/Users/nobody-here"}, sys.executable)
    done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60)
    result = json.loads(done.stdout.strip().splitlines()[-1])
    assert result == {"proxy": True, "other": False, "internet": False, "secret": False, "write_run": True,
                      "write_agent": False, "write_home": False}
    allowed.close()
    other.close()


def test_linux_plan_unshares_everything_and_passes_no_secrets(tmp_path):
    run = tmp_path / "r-1"
    (run / "agent" / "harness").mkdir(parents=True)
    plan = sandbox.Plan(mode="linux", run_dir=str(run), proxy_port=18080, proxy_unix=str(run / "p.sock"),
                        readable=("/opt/prime/bin", "/opt/prime-venv"), deny_read=())
    env = {"PATH": "/usr/bin:/bin", "HOME": f"{run}/home", "PRIME_AGENT_KERNEL_PYTHON": "/opt/prime-venv/bin/python"}
    argv, outer_env = sandbox.wrap(plan, ["/opt/prime/bin/prime-agent", "--mode", "rpc"], env, "/opt/prime-venv/bin/python")
    assert argv[:5] == ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv"]
    assert "--share-net" not in argv
    assert ["--bind", str(run.resolve()), str(run.resolve())] == argv[argv.index("--bind"):argv.index("--bind") + 3]
    root = run.resolve()
    locked = [p for i, a in enumerate(argv) if a == "--ro-bind" for p in [argv[i + 1]]]
    assert {f"{root}/agent/settings.json", f"{root}/agent/models.json", f"{root}/agent/harness", f"{root}/work"} <= set(locked)
    assert argv.index("--bind") < min(i for i, a in enumerate(argv) if a == "--ro-bind" and argv[i + 1].startswith(str(root)))
    assert argv[argv.index("--") + 1:argv.index("--") + 3] == ["/opt/prime-venv/bin/python", f"{run.resolve()}/agent/forwarder.py"]
    assert argv[-3:] == ["/opt/prime/bin/prime-agent", "--mode", "rpc"]
    assert (run / "agent" / "forwarder.py").exists()
    assert outer_env == {"PATH": "/usr/bin:/bin"}
    set_env = {argv[i + 1]: argv[i + 2] for i, a in enumerate(argv) if a == "--setenv"}
    assert set_env == env


def test_literature_searches_are_capped_per_analysis():
    tools = job_tools()
    for _ in range(3):
        tools.call("search_literature", {"query": "resting heart rate sleep"})
    with pytest.raises(ToolError, match="at most 3"):
        tools.call("search_literature", {"query": "resting heart rate training load"})
    assert tools.retrieved and all(r["topic"] for r in tools.retrieved.values())
