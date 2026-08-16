#!/usr/bin/env python3
"""Serve one fixture directory while delaying selected responses."""

from __future__ import annotations

import argparse
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


class DelayedStaticHandler(SimpleHTTPRequestHandler):
    delay_seconds = 0.0
    delay_suffix = ""

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if self.delay_suffix and path.endswith(self.delay_suffix):
            time.sleep(self.delay_seconds)
        super().do_GET()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--delay-seconds", required=True, type=float)
    parser.add_argument("--delay-suffix", required=True)
    args = parser.parse_args()

    handler = partial(DelayedStaticHandler, directory=args.directory)
    DelayedStaticHandler.delay_seconds = args.delay_seconds
    DelayedStaticHandler.delay_suffix = args.delay_suffix
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
