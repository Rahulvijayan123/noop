"""Runs first inside the Linux sandbox (stdlib only, copied into the run directory): listens on the namespace's
loopback port that Prime's provider URL names, relays each connection to the LLM proxy's Unix socket (the only
way out of the network namespace), then execs Prime Agent. The relay child dies with the namespace.

    python forwarder.py --listen 127.0.0.1:PORT --unix /run/.../proxy.sock -- prime-agent ...
"""

from __future__ import annotations

import os
import socket
import sys
import threading


def _pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def _serve(listener: socket.socket, unix_path: str) -> None:
    while True:
        client, _ = listener.accept()
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect(unix_path)
        except OSError:
            client.close()
            continue
        threading.Thread(target=_pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=_pipe, args=(upstream, client), daemon=True).start()


def main(argv: list[str]) -> None:
    split = argv.index("--")
    opts, command = argv[:split], argv[split + 1:]
    host, port = opts[opts.index("--listen") + 1].rsplit(":", 1)
    unix_path = opts[opts.index("--unix") + 1]
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, int(port)))
    listener.listen(16)
    if os.fork() == 0:  # relay child; the namespace's init kills it when Prime exits
        _serve(listener, unix_path)
        os._exit(0)
    listener.close()
    os.execvp(command[0], command)


if __name__ == "__main__":
    main(sys.argv[1:])
