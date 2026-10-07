"""A stateless, scripted OpenAI-compatible /chat/completions endpoint (SSE) standing in for the model provider.

The next step is derived from each request's conversation, so retries and auxiliary calls cannot desync it:
  step 0  an `ipython` tool call whose code loads evidence through the `nara` MCP tools, probes the sandbox and
          isolation, and prints one EVIDENCE=<json> line;
  step 1  the final answer, composed from that printed evidence (so every number is grounded) — or, in the
          "retry" scenario, first a reply that breaks the wording rules, then a valid one after the host's retry
          prompt; in the "always_bad" scenario, never a valid one.
Every request body is kept for inspection.
"""

from __future__ import annotations

import json
import sys
import threading
import time
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from nara_metric_insight.prompts import bootstrap

TASK_MARKER = "Reply with ONLY this JSON object"
RETRY_MARKER = "did not pass the checks"
LOAD_CODE = bootstrap() + """
import json, os, urllib.request
lit = await mcp.call_tool('nara', 'search_literature', {'query': 'resting heart rate day to day variability'})
summary, quality = metric_summary, data_quality
probe = {}
try:
    other = await mcp.call_tool('nara', 'get_metric_series', {'user_id': '22222222-2222-4222-8222-222222222222'})
    probe['cross_user'] = 'refused' if 'unexpected argument' in json.dumps(other, default=str) else 'returned'
except Exception as exc:
    probe['cross_user'] = 'refused'
try:
    urllib.request.urlopen('https://example.com', timeout=3)
    probe['internet'] = 'reachable'
except Exception:
    probe['internet'] = 'blocked'
probe['secret_like_env'] = sorted(k for k in os.environ if any(w in k for w in ('KEY', 'SECRET', 'DB_URL', 'PASSWORD')))
try:
    import rlm
    rlm.harness.create_memory('probe', 'per-user fact that must not be stored', global_=True)
    probe['global_harness_write'] = 'allowed'
except Exception as exc:
    probe['global_harness_write'] = 'blocked:' + type(exc).__name__
try:
    state = json.load(open(os.path.join(os.environ['PRIME_AGENT_CODING_AGENT_DIR'], 'harness', 'harness_state.json')))
    probe['harness_ids_on_disk'] = sorted(i for kind in state['entries'].values() for i in kind)
except FileNotFoundError:
    probe['harness_ids_on_disk'] = []
probe['placeholders'] = [chat_history.get('available'), health_records.get('available')]
print('EVIDENCE=' + json.dumps({'summary': summary, 'quality': quality,
                                'lit': [r['id'] for r in (lit.get('results') or [])], 'probe': probe}, default=str))
"""


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def _evidence(messages: list[dict[str, Any]]) -> dict[str, Any]:
    for message in messages:
        text = _text(message.get("content"))
        if message.get("role") == "tool" and "EVIDENCE=" in text:
            return json.loads(text.split("EVIDENCE=", 1)[1].splitlines()[0])
    return {}


def _short(day: str) -> str:
    value = date.fromisoformat(day)
    return f"{value:%b} {value.day}"


def answer(evidence: dict[str, Any], *, bad: bool = False) -> str:
    summary, quality = evidence.get("summary") or {}, evidence.get("quality") or {}
    latest = summary.get("latest") or {}
    observed = [f"Your resting heart rate was {latest.get('value')} bpm on {_short(latest['day'])}."]
    previous = summary.get("previous")
    if previous and previous.get("change"):
        change = previous["change"]
        observed.append(f"That is {abs(change)} bpm {'lower' if change < 0 else 'higher'} than on "
                        f"{_short(previous['day'])}.")
    call = (summary.get("baseline") or {}).get("call") or {}
    if call.get("state") in ("in_range", "off"):  # the app's own call, with the band it shows
        where = "within" if call["state"] == "in_range" else call["side"]
        observed.append(f"That is {where} your usual range of {call['low']}-{call['high']} bpm.")
    interpretation = ["Night-to-night differences of a few bpm are common and can follow changes in routine."]
    if bad:
        interpretation = ["This drop suggests you are less stressed and fully recovered."]
    return json.dumps({
        "headline": f"Resting heart rate {latest.get('value')} bpm on {_short(latest['day'])}",
        "observed": observed, "interpretation": interpretation,
        "uncertainty": [f"{quality.get('missing_nights')} of the {quality.get('tracked_nights')} nights since "
                        "tracking began were not measured, so what is usual for you is still uncertain."],
        "citations": (evidence.get("lit") or [])[:1],
    })


class StubLLM:
    def __init__(self) -> None:
        self.scenario = "good"
        self.requests: list[dict[str, Any]] = []
        self.authorizations: list[str] = []
        self.decisions: list[str] = []
        self.lock = threading.Lock()
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args: Any) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                data = json.dumps({"object": "list", "data": [{"id": "fixture-model", "object": "model"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self) -> None:  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                with stub.lock:
                    stub.requests.append(body)
                    stub.authorizations.append(self.headers.get("Authorization") or "")
                    label, step = stub.choose(body)
                    stub.decisions.append(label)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for event in stub.events(body.get("model", "fixture-model"), step, f"call_{len(stub.requests)}"):
                    self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def choose(self, body: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        messages = body.get("messages") or []
        marker = next((i for i in range(len(messages) - 1, -1, -1) if messages[i].get("role") == "user"
                       and TASK_MARKER in _text(messages[i].get("content"))), None)
        if marker is None or not body.get("tools"):
            return "aux", {"final": "Nara"}
        last_user = next((m for m in reversed(messages) if m.get("role") == "user"), {})
        retrying = RETRY_MARKER in _text(last_user.get("content"))
        tool_results = sum(1 for m in messages[marker + 1:] if m.get("role") == "tool")
        if tool_results == 0:
            return "load", {"tool": "ipython", "code": LOAD_CODE}
        evidence = _evidence(messages)
        if not evidence:  # the load cell failed: surface the kernel's output in the test log
            tool = next((m for m in reversed(messages) if m.get("role") == "tool"), {})
            sys.stderr.write("STUB: no EVIDENCE line; last tool output:\n" + _text(tool.get("content"))[:3000] + "\n")
            return "no-evidence", {"final": "{}"}
        bad = self.scenario == "always_bad" or (self.scenario == "retry" and not retrying)
        return ("retry-answer" if retrying else "answer"), {"final": answer(evidence, bad=bad)}

    @staticmethod
    def events(model: str, step: dict[str, Any], call_id: str) -> list[dict[str, Any]]:
        def chunk(delta: dict[str, Any], finish: str | None) -> dict[str, Any]:
            return {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        usage = {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "choices": [],
                 "usage": {"prompt_tokens": 1000, "completion_tokens": 40, "total_tokens": 1040}}
        if "tool" in step:
            return [chunk({"role": "assistant", "content": None, "tool_calls": [
                        {"index": 0, "id": call_id, "type": "function",
                         "function": {"name": step["tool"], "arguments": ""}}]}, None),
                    chunk({"tool_calls": [{"index": 0, "function": {"arguments": json.dumps({"code": step["code"]})}}]}, None),
                    chunk({}, "tool_calls"), usage]
        return [chunk({"role": "assistant", "content": step["final"]}, None), chunk({}, "stop"), usage]

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
