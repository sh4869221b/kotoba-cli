#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import argparse
import json
import os
import sys
import time


STALL_HEALTH = False
STALL_COMPLETION = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            if STALL_HEALTH:
                time.sleep(60)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return
        if STALL_COMPLETION:
            time.sleep(60)
        length = int(self.headers.get("content-length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        prompt = payload.get("messages", [{}])[-1].get("content", "")
        text = prompt.split("Text:\n", 1)[-1]
        text = text.replace("`kotoba translate`", "`translated command`")
        body = json.dumps({"choices": [{"message": {"content": "JA:" + text}}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    global STALL_HEALTH, STALL_COMPLETION
    parser = argparse.ArgumentParser()
    parser.add_argument("positional_port", nargs="?", type=int)
    parser.add_argument("-m", "--model", default="")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--stall-health", action="store_true")
    parser.add_argument("--stall-completion", action="store_true")
    args = parser.parse_args()
    STALL_HEALTH = args.stall_health
    STALL_COMPLETION = args.stall_completion
    port = args.port or args.positional_port or 18080
    marker = os.environ.get("KOTOBA_FAKE_LLAMA_MARKER")
    if marker:
        with open(marker, "a", encoding="utf-8") as f:
            f.write(f"pid={os.getpid()} host={args.host} port={port} model={args.model}\n")
            f.flush()
    HTTPServer((args.host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
