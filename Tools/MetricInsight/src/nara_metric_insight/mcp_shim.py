"""Stdio MCP server that Prime Agent's kernel spawns inside the sandbox (stdlib only; copied into each job's run
directory and run with the kernel's Python). It holds no credentials and no data: every tools/list and
tools/call is forwarded over the job's Unix socket to the tool broker with the job's capability token.

    python mcp_shim.py --socket <run>/broker.sock --token <job token>
"""

from __future__ import annotations

import argparse
import http.client
import json
import socket
import sys
from typing import Any


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float) -> None:
        super().__init__("broker", timeout=timeout)
        self._path = path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def _broker(path: str, token: str, method: str, route: str, body: Any = None) -> tuple[int, Any]:
    connection = _UnixConnection(path, timeout=60)
    try:
        payload = None if body is None else json.dumps(body).encode()
        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        connection.request(method, route, body=payload, headers=headers)
        response = connection.getresponse()
        raw = response.read()
        return response.status, json.loads(raw or b"null")
    except (OSError, ValueError) as exc:
        return 503, {"error": f"tool broker unavailable ({type(exc).__name__})"}
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--token", required=True)
    opts = parser.parse_args()

    def reply(msg_id: Any, result: Any = None, error: dict | None = None) -> None:
        frame: dict[str, Any] = {"jsonrpc": "2.0", "id": msg_id}
        frame["error" if error else "result"] = error or result
        sys.stdout.write(json.dumps(frame) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, msg_id = message.get("method"), message.get("id")
        if msg_id is None:  # notifications
            continue
        if method == "initialize":
            reply(msg_id, {"protocolVersion": (message.get("params") or {}).get("protocolVersion", "2025-06-18"),
                           "capabilities": {"tools": {"listChanged": False}},
                           "serverInfo": {"name": "nara", "version": "1"}})
        elif method == "ping":
            reply(msg_id, {})
        elif method == "tools/list":
            status, body = _broker(opts.socket, opts.token, "GET", "/tools")
            if status == 200:
                reply(msg_id, {"tools": body.get("tools", [])})
            else:
                reply(msg_id, error={"code": -32603, "message": str((body or {}).get("error", status))})
        elif method == "tools/call":
            params = message.get("params") or {}
            name = str(params.get("name", ""))
            status, body = _broker(opts.socket, opts.token, "POST", f"/tools/{name}", params.get("arguments") or {})
            failed = status != 200
            structured = body if isinstance(body, dict) else {"result": body}
            reply(msg_id, {"content": [{"type": "text", "text": json.dumps(body)}],
                           "structuredContent": structured, "isError": failed})
        else:
            reply(msg_id, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
