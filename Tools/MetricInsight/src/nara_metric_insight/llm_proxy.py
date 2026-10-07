"""Per-job LLM proxy: Prime Agent talks to this, never to the provider.

* Prime holds only a random per-job token; the provider key lives in this process (read from a credential file)
  and is never written to the job's directory or environment.
* Fixed model, capped max_tokens, a request budget per job; streaming (SSE) passes through unchanged.
* Listens on loopback TCP (macOS sandbox) or a Unix socket that an in-sandbox forwarder exposes as loopback TCP
  (Linux: the sandbox has no network namespace route to the host).

Only POST .../chat/completions and GET .../models are served.
"""

from __future__ import annotations

import hmac
import http.client
import json
import os
import re
import socketserver
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

MAX_REQUEST = 4 * 1024 * 1024
UPSTREAM_TIMEOUT_S = 120
MAX_CONCURRENT = 4
_LENGTH = re.compile(r"\d{1,8}")
# The only request fields forwarded. Everything else (n, store, metadata, user, logprobs, provider-side tools,
# ...) is dropped: more choices would multiply the budget, storage would keep health data at the provider.
FORWARDED = frozenset({"messages", "tools", "tool_choice", "temperature", "top_p", "stop", "stream",
                       "stream_options", "max_tokens", "max_completion_tokens", "response_format",
                       "parallel_tool_calls", "seed", "presence_penalty", "frequency_penalty"})


class _Quiet:
    def handle_error(self, request, client_address) -> None:  # never print a traceback with request data
        pass


class _UnixHTTPServer(_Quiet, socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class _TCPServer(_Quiet, ThreadingHTTPServer):
    daemon_threads = True


def clean_request(body: dict[str, Any], model: str, max_tokens: int) -> dict[str, Any]:
    out = {k: v for k, v in body.items() if k in FORWARDED}
    out["model"] = model
    if isinstance(out.get("tools"), list):
        out["tools"] = [t for t in out["tools"] if isinstance(t, dict) and t.get("type") == "function"]
        if not out["tools"]:
            out.pop("tools")
            out.pop("tool_choice", None)
    for key in ("max_tokens", "max_completion_tokens"):
        value = out.get(key)
        if key in out:
            out[key] = min(value, max_tokens) if isinstance(value, int) and not isinstance(value, bool) and value > 0 \
                else max_tokens
    if "max_tokens" not in out and "max_completion_tokens" not in out:
        out["max_tokens"] = max_tokens
    return out


class LlmProxy:
    def __init__(self, *, upstream: str, api_key: str, model: str, token: str, max_requests: int,
                 max_tokens: int, unix_path: str | None = None) -> None:
        parts = urlsplit(upstream)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError("upstream must be an http(s) URL")
        self.scheme, self.host = parts.scheme, parts.hostname
        self.port = parts.port or (443 if parts.scheme == "https" else 80)
        self.base_path = parts.path.rstrip("/")
        self.api_key, self.model, self.token = api_key, model, token
        self.max_requests, self.max_tokens = max_requests, max_tokens
        self.requests = 0
        self.completion_tokens = 0
        self.prompt_tokens = 0
        self.rejected = 0
        self._lock = threading.Lock()
        self._slots = threading.BoundedSemaphore(MAX_CONCURRENT)
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"  # streamed bodies end with the connection

            def address_string(self) -> str:
                return "local"

            def log_message(self, fmt: str, *args: Any) -> None:  # prompts carry health data: never logged
                pass

            def _json(self, status: int, body: Any) -> None:
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _authorized(self) -> bool:
                presented = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                return hmac.compare_digest(presented.encode(), proxy.token.encode())

            def do_GET(self) -> None:  # noqa: N802
                if not self._authorized():
                    return self._json(401, {"error": {"message": "unauthorized"}})
                if not self.path.rstrip("/").endswith("/models"):
                    return self._json(404, {"error": {"message": "not found"}})
                self._json(200, {"object": "list", "data": [{"id": proxy.model, "object": "model"}]})

            def do_POST(self) -> None:  # noqa: N802
                if not proxy._slots.acquire(blocking=False):
                    return self._json(503, {"error": {"message": "too many concurrent model calls"}})
                try:
                    self._post()
                finally:
                    proxy._slots.release()

            def _post(self) -> None:
                if not self._authorized():
                    return self._json(401, {"error": {"message": "unauthorized"}})
                if not self.path.split("?")[0].rstrip("/").endswith("/chat/completions"):
                    return self._json(404, {"error": {"message": "not found"}})
                raw = self.headers.get("Content-Length") or ""
                if not _LENGTH.fullmatch(raw) or not 0 < int(raw) <= MAX_REQUEST:
                    return self._json(413, {"error": {"message": "request too large or without a length"}})
                length = int(raw)
                with proxy._lock:
                    proxy.requests += 1
                    over = proxy.requests > proxy.max_requests
                    if over:
                        proxy.rejected += 1
                if over:
                    return self._json(429, {"error": {"message": "model call budget for this analysis is exhausted",
                                                      "type": "budget_exhausted"}})
                try:
                    body = json.loads(self.rfile.read(length))
                except ValueError:
                    return self._json(400, {"error": {"message": "invalid JSON"}})
                if not isinstance(body, dict):
                    return self._json(400, {"error": {"message": "invalid request"}})
                proxy._forward(self, json.dumps(clean_request(body, proxy.model, proxy.max_tokens)).encode())

        if unix_path:
            if os.path.exists(unix_path):
                os.unlink(unix_path)
            self.server: socketserver.BaseServer = _UnixHTTPServer(unix_path, Handler)
            os.chmod(unix_path, 0o600)
            self.address = unix_path
            self.listen_port = None
        else:
            self.server = _TCPServer(("127.0.0.1", 0), Handler)
            self.listen_port = self.server.server_address[1]
            self.address = f"127.0.0.1:{self.listen_port}"
        self.unix_path = unix_path
        self.thread = threading.Thread(target=self.server.serve_forever, name="llm-proxy", daemon=True)

    def _connection(self) -> http.client.HTTPConnection:
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, timeout=UPSTREAM_TIMEOUT_S,
                                               context=ssl.create_default_context())
        return http.client.HTTPConnection(self.host, self.port, timeout=UPSTREAM_TIMEOUT_S)

    def _forward(self, handler: BaseHTTPRequestHandler, body: bytes) -> None:
        connection = self._connection()
        try:
            connection.request("POST", f"{self.base_path}/chat/completions", body=body, headers={
                "Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json",
                "Accept": "text/event-stream, application/json"})
            response = connection.getresponse()
        except OSError:
            connection.close()
            handler.send_response(502)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error": {"message": "model provider unreachable"}}')
            return
        try:
            handler.send_response(response.status)
            handler.send_header("Content-Type", response.getheader("Content-Type") or "application/json")
            handler.send_header("Cache-Control", "no-cache")
            handler.end_headers()
            tail = b""
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                handler.wfile.write(chunk)
                handler.wfile.flush()
                tail = self._count_usage(tail + chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            connection.close()

    def _count_usage(self, data: bytes) -> bytes:
        """Tally `usage` from complete SSE lines; returns the unfinished remainder."""
        *lines, rest = data.split(b"\n")
        for line in lines:
            if b'"usage"' not in line:
                continue
            text = line.decode(errors="replace").removeprefix("data:").strip()
            try:
                usage = (json.loads(text) or {}).get("usage") or {}
            except ValueError:
                continue
            with self._lock:
                self.prompt_tokens += int(usage.get("prompt_tokens") or 0)
                self.completion_tokens += int(usage.get("completion_tokens") or 0)
        return rest[-65536:]

    def __enter__(self) -> "LlmProxy":
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        if self.unix_path:
            try:
                os.unlink(self.unix_path)
            except FileNotFoundError:
                pass
