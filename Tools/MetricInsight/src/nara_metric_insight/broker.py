"""The tool broker: the only path from model-written code to the owner's data.

An HTTP server on a per-job Unix socket inside the job's run directory (the sandbox exposes that socket and
nothing else). A request must carry the job's capability token; the token is bound to one JobTools, so the
model can never choose whose data it reads — tools take no user, device or date arguments at all.

    GET  /tools          the tool list (name, description, inputSchema)
    POST /tools/<name>   JSON arguments -> JSON result; 400 bad call, 401 bad token, 404 unknown, 429 budget
"""

from __future__ import annotations

import hmac
import json
import os
import re
import socketserver
import threading
from http.server import BaseHTTPRequestHandler
from typing import Any

from .tools import JobTools, ToolError, tool_list

MAX_BODY = 16 * 1024
MAX_RESULT = 512 * 1024
MAX_CONCURRENT = 4
_LENGTH = re.compile(r"\d{1,7}")


class _UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def handle_error(self, request, client_address) -> None:  # never print a traceback with request data
        pass


class Broker:
    def __init__(self, socket_path: str, token: str, tools: JobTools, *, max_calls: int = 80) -> None:
        self.socket_path = socket_path
        self.token = token
        self.tools = tools
        self.max_calls = max_calls
        self.calls = 0
        self.errors = 0
        self._lock = threading.Lock()
        self._slots = threading.BoundedSemaphore(MAX_CONCURRENT)
        broker = self

        class Handler(BaseHTTPRequestHandler):
            def address_string(self) -> str:  # AF_UNIX peers have no address
                return "unix"

            def log_message(self, fmt: str, *args: Any) -> None:  # never log arguments or results
                pass

            def _reply(self, status: int, body: Any) -> None:
                data = json.dumps(body, default=str).encode()
                if len(data) > MAX_RESULT:
                    status, data = 413, json.dumps({"error": "result too large; ask for fewer days"}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _authorized(self) -> bool:
                presented = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                return hmac.compare_digest(presented.encode(), broker.token.encode())

            def do_GET(self) -> None:  # noqa: N802
                if not self._authorized():
                    return self._reply(401, {"error": "unauthorized"})
                if self.path != "/tools":
                    return self._reply(404, {"error": "not found"})
                self._reply(200, {"tools": tool_list()})

            def do_POST(self) -> None:  # noqa: N802
                if not broker._slots.acquire(blocking=False):
                    return self._reply(503, {"error": "too many concurrent tool calls"})
                try:
                    self._post()
                finally:
                    broker._slots.release()

            def _post(self) -> None:
                with broker._lock:  # every attempt counts, malformed ones included
                    broker.calls += 1
                    over = broker.calls > broker.max_calls
                if over:
                    return self._reply(429, {"error": "tool call budget for this analysis is exhausted"})
                if not self._authorized():
                    return self._reply(401, {"error": "unauthorized"})
                if not self.path.startswith("/tools/"):
                    return self._reply(404, {"error": "not found"})
                raw = self.headers.get("Content-Length") or "0"
                if not _LENGTH.fullmatch(raw):
                    return self._reply(400, {"error": "bad Content-Length"})
                length = int(raw)
                if length > MAX_BODY:
                    return self._reply(413, {"error": "arguments too large"})
                try:
                    args = json.loads(self.rfile.read(length) or b"{}")
                    if not isinstance(args, dict):
                        raise ToolError("arguments must be a JSON object")
                    result = broker.tools.call(self.path.removeprefix("/tools/"), args)
                except (ToolError, json.JSONDecodeError) as exc:
                    with broker._lock:
                        broker.errors += 1
                    return self._reply(400, {"error": str(exc)[:300]})
                except Exception:  # noqa: BLE001 - a data error must not leak details into the model
                    with broker._lock:
                        broker.errors += 1
                    return self._reply(500, {"error": "tool failed"})
                self._reply(200, result)

        if os.path.exists(socket_path):
            os.unlink(socket_path)
        self.server = _UnixHTTPServer(socket_path, Handler)
        os.chmod(socket_path, 0o600)
        self.thread = threading.Thread(target=self.server.serve_forever, name="tool-broker", daemon=True)

    def __enter__(self) -> "Broker":
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
