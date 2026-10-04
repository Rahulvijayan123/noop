#!/usr/bin/env python3
"""A throwaway SMTP server for the local Auth stack: it accepts mail and writes each message to a JSON file.

The Auth service sends its confirmation and recovery codes through the SMTP settings it is configured with.
Pointing those at this sink lets the end-to-end test read the real code out of the real email that GoTrue
rendered from the real template, with nothing delivered anywhere.

    smtp_sink.py <port> <directory>

Plain SMTP only (no STARTTLS, no AUTH), bound to all interfaces so a container can reach it through the
host gateway. Never run it anywhere but a developer machine.
"""
import asyncio
import json
import os
import sys
import time
from email import message_from_bytes, policy

MAX_MESSAGE = 1 << 20


def parse(raw: bytes, recipients, sender):
    message = message_from_bytes(raw, policy=policy.default)
    text, html = "", ""
    for part in message.walk():
        kind = part.get_content_type()
        if kind == "text/plain" and not text:
            text = part.get_content()
        elif kind == "text/html" and not html:
            html = part.get_content()
    return {
        "receivedAt": time.time(),
        "from": sender,
        "to": recipients,
        "subject": str(message.get("Subject", "")),
        "text": text,
        "html": html,
    }


class Counter:
    value = 0


async def session(reader, writer, directory):
    async def reply(line):
        writer.write((line + "\r\n").encode())
        await writer.drain()

    recipients, sender = [], ""
    await reply("220 nara-smtp-sink ESMTP ready")
    try:
        while True:
            raw = await reader.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            command = line.upper()
            if command.startswith("EHLO"):
                writer.write(b"250-nara-smtp-sink\r\n250 SIZE 1048576\r\n")
                await writer.drain()
            elif command.startswith("HELO"):
                await reply("250 nara-smtp-sink")
            elif command.startswith("MAIL FROM:"):
                sender = line[10:].strip().strip("<>").split(">")[0]
                recipients = []
                await reply("250 OK")
            elif command.startswith("RCPT TO:"):
                recipients.append(line[8:].strip().strip("<>").split(">")[0].lower())
                await reply("250 OK")
            elif command == "DATA":
                await reply("354 End data with <CR><LF>.<CR><LF>")
                body = bytearray()
                while True:
                    chunk = await reader.readline()
                    if not chunk:
                        return
                    if chunk == b".\r\n":
                        break
                    if chunk.startswith(b".."):
                        chunk = chunk[1:]
                    body += chunk
                    if len(body) > MAX_MESSAGE:
                        await reply("552 message too large")
                        return
                Counter.value += 1
                record = parse(bytes(body), recipients, sender)
                name = f"{int(time.time() * 1000):013d}-{Counter.value:04d}.json"
                tmp = os.path.join(directory, name + ".tmp")
                with open(tmp, "w") as handle:
                    json.dump(record, handle)
                os.replace(tmp, os.path.join(directory, name))
                await reply("250 OK queued")
            elif command == "RSET":
                recipients, sender = [], ""
                await reply("250 OK")
            elif command == "NOOP":
                await reply("250 OK")
            elif command == "QUIT":
                await reply("221 bye")
                return
            else:
                await reply("502 command not implemented")
    finally:
        writer.close()


async def main(port, directory):
    os.makedirs(directory, exist_ok=True)
    server = await asyncio.start_server(lambda r, w: session(r, w, directory), "0.0.0.0", port)
    print(f"smtp sink listening on {port}, writing to {directory}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    asyncio.run(main(int(sys.argv[1]), sys.argv[2]))
