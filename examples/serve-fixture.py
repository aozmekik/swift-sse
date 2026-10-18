#!/usr/bin/env python3
"""Serve a recorded or synthetic event stream over HTTP, for trying the examples locally.

    python3 examples/serve-fixture.py examples/fixtures/openai-chat.sse --port 18765

Every request (any method, any path) gets 200 OK with Content-Type text/event-stream. The file is
sent one block at a time (blocks end at a blank line) with a short pause between them, then the
connection is closed. If the request carries Last-Event-ID and a block has that `id:`, streaming
resumes after that block. With --max-blocks the server closes the connection early, which makes
reconnection visible:

    python3 examples/serve-fixture.py examples/fixtures/ticks.sse --port 18767 --max-blocks 2
    swift run sse-tail http://127.0.0.1:18767/ --max-events 3

Standard library only. This is a development aid, not a production server.
"""

import argparse
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def split_blocks(data: bytes) -> list[bytes]:
    """Split a stream into blocks that each end with their blank line."""
    parts = re.split(rb"(\r\n\r\n|\n\n|\r\r)", data)
    blocks = [parts[i] + parts[i + 1] for i in range(0, len(parts) - 1, 2)]
    if parts[-1]:
        blocks.append(parts[-1])
    return blocks


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("fixture", help="path to a .sse file")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--delay", type=float, default=0.02, help="seconds between blocks")
    parser.add_argument("--requests", type=int, default=0, help="exit after N requests (0: never)")
    parser.add_argument(
        "--max-blocks", type=int, default=0, help="close after N blocks per request (0: all)"
    )
    args = parser.parse_args()

    with open(args.fixture, "rb") as file:
        blocks = split_blocks(file.read())
    served = 0
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def handle_stream(self) -> None:
            nonlocal served
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            last_id = self.headers.get("Last-Event-ID")
            start = 0
            if last_id is not None:
                marker = re.compile(rb"^id: ?" + re.escape(last_id.encode()) + rb"\r?$", re.M)
                for index, block in enumerate(blocks):
                    if marker.search(block):
                        start = index + 1
            print(
                f"{self.command} {self.path} Last-Event-ID={last_id!r} -> block {start}",
                file=sys.stderr,
                flush=True,
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                end = start + args.max_blocks if args.max_blocks else len(blocks)
                for block in blocks[start:end]:
                    self.wfile.write(block)
                    self.wfile.flush()
                    time.sleep(args.delay)
            except (BrokenPipeError, ConnectionResetError):
                print("client disconnected", file=sys.stderr, flush=True)
            with lock:
                served += 1
                done = args.requests and served >= args.requests
            if done:
                threading.Thread(target=server.shutdown, daemon=True).start()

        do_GET = handle_stream
        do_POST = handle_stream

        def log_message(self, format: str, *log_args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"listening on http://127.0.0.1:{args.port}/", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
