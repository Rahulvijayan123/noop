"""Prime Agent as the reasoning backbone: one `prime-agent --mode rpc --no-session` process per job, in a fresh
run directory that is deleted afterwards, confined by sandbox.py, talking only to this job's LLM proxy and
tool broker.

Locked down through its own settings (agent dir settings.json): built-in and bundled skills off, no recursive
sub-agents, no packages, telemetry off, one MCP server (`nara`, the shim). The job's cwd and agent dir carry no
AGENTS.md / CLAUDE.md (Prime always loads those from the agent dir and the cwd's ancestors; config.check_work_root
refuses a work root with any above it). Memory: --no-session keeps no transcript; the agent dir (including any
harness writes) is deleted with the run; the only harness it starts with is the curated, user-free file.
"""

from __future__ import annotations

import asyncio
import itertools
import json
import os
import secrets
import shutil
import signal
import tempfile
from pathlib import Path
from typing import Any

from . import sandbox
from .broker import Broker
from .config import Config
from .llm_proxy import LlmProxy
from .prompts import GUIDANCE
from .tools import JobTools

SHIM = Path(__file__).resolve().parent / "mcp_shim.py"
LINUX_PROXY_PORT = 18080  # inside the sandbox's own network namespace
CONTEXT_FILES = ("AGENTS.md", "CLAUDE.md")


class AgentFailed(RuntimeError):
    pass


def check_work_root(work_root: str) -> None:
    """Prime loads AGENTS.md / CLAUDE.md from every ancestor of its cwd: none may exist above the work root."""
    root = Path(work_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    for directory in (root, *root.parents):
        for name in CONTEXT_FILES:
            if (directory / name).exists():
                raise RuntimeError(f"{directory / name} would be loaded into every analysis; use another work root")


class PrimeAgentRpc:
    """JSONL over stdio: {"id","type",...} commands in; {"type":"response","id",...} replies and agent events out."""

    def __init__(self, proc: asyncio.subprocess.Process) -> None:
        self.proc = proc
        self.events: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._ids = itertools.count(1)
        self._reader = asyncio.create_task(self._read())
        self.turns = 0

    @classmethod
    async def start(cls, argv: list[str], *, env: dict[str, str], cwd: Path, stderr: Path) -> "PrimeAgentRpc":
        with stderr.open("wb") as err:
            proc = await asyncio.create_subprocess_exec(
                *argv, cwd=cwd, env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=err, limit=64 * 2**20, start_new_session=True)
        return cls(proc)

    async def _read(self) -> None:
        assert self.proc.stdout
        async for line in self.proc.stdout:
            if not line.strip():
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            future = self._pending.pop(frame.get("id"), None) if frame.get("type") == "response" else None
            if future is not None and not future.done():
                future.set_result(frame)
            else:
                self.events.put_nowait(frame)
        for future in self._pending.values():
            if not future.done():
                future.set_exception(AgentFailed("prime-agent exited"))
        self.events.put_nowait({"type": "_eof"})

    async def request(self, kind: str, timeout: float = 30, **fields: Any) -> dict[str, Any]:
        rid = f"r{next(self._ids)}"
        future = asyncio.get_running_loop().create_future()
        self._pending[rid] = future
        assert self.proc.stdin
        self.proc.stdin.write((json.dumps({"id": rid, "type": kind, **fields}) + "\n").encode())
        await self.proc.stdin.drain()
        response = await asyncio.wait_for(future, timeout)
        if not response.get("success"):
            raise AgentFailed(f"{kind} refused")
        return response.get("data") or {}

    async def run(self, message: str, *, timeout: float, max_turns: int) -> str:
        """One prompt to agent_end. Prime has no turn cap or wall clock of its own: both are enforced here."""
        while not self.events.empty():
            self.events.get_nowait()
        await self.request("prompt", message=message)
        try:
            end = await asyncio.wait_for(self._until_agent_end(max_turns), timeout)
        except asyncio.TimeoutError:
            try:
                await self.request("abort", timeout=5)
                await asyncio.wait_for(self._until_agent_end(None), 10)
            except (asyncio.TimeoutError, AgentFailed):
                pass
            raise
        last = next((m for m in reversed(end.get("messages") or []) if m.get("role") == "assistant"), {})
        if last.get("stopReason") in ("error", "aborted"):
            raise AgentFailed(f"agent stopped: {last.get('stopReason')}")
        return (await self.request("get_last_assistant_text")).get("text") or ""

    async def _until_agent_end(self, max_turns: int | None) -> dict[str, Any]:
        turns = 0
        while True:
            event = await self.events.get()
            kind = event.get("type")
            if kind == "agent_end":
                return event
            if kind == "_eof":
                raise AgentFailed("prime-agent exited mid-run")
            if kind == "turn_end":
                turns += 1
                self.turns += 1
                if max_turns is not None and turns == max_turns:
                    await self.request("abort")

    async def close(self) -> None:
        if self.proc.stdin and not self.proc.stdin.is_closing():
            self.proc.stdin.close()
        try:
            await asyncio.wait_for(self.proc.wait(), 10)
        except asyncio.TimeoutError:
            pass
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        await self.proc.wait()
        self._reader.cancel()


class PrimeSession:
    """Everything one analysis runs in; `async with` tears all of it down, run directory included."""

    def __init__(self, cfg: Config, tools: JobTools, *, mode: str, readable: tuple[str, ...] = ()) -> None:
        self.cfg, self.tools, self.mode, self.readable = cfg, tools, mode, readable
        self.run_dir: Path | None = None
        self.broker: Broker | None = None
        self.proxy: LlmProxy | None = None
        self.rpc: PrimeAgentRpc | None = None

    async def __aenter__(self) -> "PrimeSession":
        try:
            await self._start()
        except BaseException:
            await self.__aexit__(None, None, None)
            raise
        return self

    async def _start(self) -> None:
        cfg = self.cfg
        run = Path(tempfile.mkdtemp(prefix="r-", dir=cfg.work_root))
        os.chmod(run, 0o700)
        self.run_dir = run
        agent, work, home, tmp = (run / name for name in ("agent", "work", "home", "tmp"))
        for directory in (agent, work, home, tmp):
            directory.mkdir()
        if len(str(run / "b.sock").encode()) > 100:
            raise RuntimeError("work root path too long for a Unix socket; use a shorter NARA_WORK_ROOT")
        tool_token, llm_token = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        self.broker = Broker(str(run / "b.sock"), tool_token, self.tools).__enter__()
        if self.mode == "linux":
            self.proxy = LlmProxy(upstream=cfg.llm_base_url, api_key=cfg.llm_api_key, model=cfg.llm_model,
                                  token=llm_token, max_requests=cfg.max_llm_requests,
                                  max_tokens=cfg.max_completion_tokens, unix_path=str(run / "p.sock")).__enter__()
            port = LINUX_PROXY_PORT
        else:
            self.proxy = LlmProxy(upstream=cfg.llm_base_url, api_key=cfg.llm_api_key, model=cfg.llm_model,
                                  token=llm_token, max_requests=cfg.max_llm_requests,
                                  max_tokens=cfg.max_completion_tokens).__enter__()
            port = int(self.proxy.listen_port or 0)

        shutil.copy(SHIM, agent / "mcp_shim.py")
        (agent / "models.json").write_text(json.dumps({"providers": {"nara-llm": {
            "api": "openai-completions", "baseUrl": f"http://127.0.0.1:{port}/v1", "apiKey": llm_token,
            "models": [{"id": cfg.llm_model, "name": "Nara metric insight", "api": "openai-completions",
                        "reasoning": False, "contextWindow": 131072, "maxTokens": cfg.max_completion_tokens}]}}}))
        (agent / "settings.json").write_text(json.dumps({
            "enableBuiltinSkills": False, "bundledSkills": {"websearch": False}, "rlmMaxDepth": 0, "packages": [],
            "telemetry": {"enabled": False},
            # No host-side model calls the model's code can start: compaction and harness refinement.
            "compaction": {"agentCallable": False}, "autoRefine": {"enabled": False},
            "mcpServers": {"nara": {"type": "stdio", "command": cfg.kernel_python,
                                    "args": [str(agent / "mcp_shim.py"), "--socket", str(run / "b.sock"),
                                             "--token", tool_token]}}}))
        # The global Continual Harness: only the curated, user-free file, and read-only inside the sandbox.
        (agent / "harness").mkdir()
        if cfg.curated_harness:
            shutil.copy(cfg.curated_harness, agent / "harness" / "harness_state.json")
        env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(tmp), "LANG": "C.UTF-8",
               "PRIME_AGENT_CODING_AGENT_DIR": str(agent), "PRIME_AGENT_DAEMON_SOCKET": str(run / "d.sock"),
               "PRIME_AGENT_KERNEL_PYTHON": cfg.kernel_python, "DO_NOT_TRACK": "1", "PRIME_AGENT_TELEMETRY": "0"}
        argv = [cfg.prime_bin, "--mode", "rpc", "--no-session", "--offline", "--provider", "nara-llm",
                "--model", cfg.llm_model, "--append-system-prompt", GUIDANCE]
        plan = sandbox.Plan(mode=self.mode, run_dir=str(run), proxy_port=port,
                            proxy_unix=str(run / "p.sock") if self.mode == "linux" else None,
                            readable=self.readable,
                            deny_read=tuple(cfg.sandbox_deny_read) + tuple(cfg.secret_paths))
        argv, env = sandbox.wrap(plan, argv, env, cfg.kernel_python)
        self.rpc = await PrimeAgentRpc.start(argv, env=env, cwd=work, stderr=run / "stderr.log")

    async def ask(self, message: str, *, timeout: float | None = None) -> str:
        assert self.rpc is not None
        return await self.rpc.run(message, timeout=timeout or self.cfg.turn_timeout_s, max_turns=self.cfg.max_turns)

    def stats(self) -> dict[str, Any]:
        return {"llm_requests": self.proxy.requests if self.proxy else 0,
                "prompt_tokens": self.proxy.prompt_tokens if self.proxy else 0,
                "completion_tokens": self.proxy.completion_tokens if self.proxy else 0,
                "tool_calls": self.broker.calls if self.broker else 0,
                "tool_errors": self.broker.errors if self.broker else 0,
                "turns": self.rpc.turns if self.rpc else 0}

    def stderr_tail(self, limit: int = 2000) -> str:
        if not self.run_dir:
            return ""
        try:
            return (self.run_dir / "stderr.log").read_text(errors="replace")[-limit:]
        except OSError:
            return ""

    async def __aexit__(self, *exc: object) -> None:
        if self.rpc is not None:
            await self.rpc.close()
            self.rpc = None
        if self.proxy is not None:
            self.proxy.__exit__(None, None, None)
        if self.broker is not None:
            self.broker.__exit__(None, None, None)
        if self.run_dir is not None:  # nothing about this person outlives the job on disk
            shutil.rmtree(self.run_dir, ignore_errors=True)
