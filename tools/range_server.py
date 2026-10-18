#!/usr/bin/env python3
"""
Controlled RFC 7233 HTTP Range Server for 1DM+ reverse-engineering verification.
Supports HEAD, standard GET, ranged GET (206 Partial Content), 416 (Range Not Satisfiable),
Content-Range validation, ETag generation, and dynamic payloads.
"""

import argparse
import hashlib
import os
import re
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

# In-memory test files
DYNAMIC_RESOURCES = {}

def get_or_generate_payload(size_bytes, seed=0x5A):
    if size_bytes in DYNAMIC_RESOURCES:
        return DYNAMIC_RESOURCES[size_bytes]
    # Deterministic generation
    ba = bytearray(size_bytes)
    for i in range(size_bytes):
        ba[i] = ((i * 31) + seed) & 0xFF
    data = bytes(ba)
    DYNAMIC_RESOURCES[size_bytes] = data
    return data

class HTTPRangeRequestHandler(BaseHTTPRequestHandler):
    server_version = "1DM_Range_Server/1.0"

    def do_HEAD(self):
        data, etag, mime = self._resolve_resource()
        if data is None:
            self.send_error(404, "Not Found")
            return
        total_size = len(data)
        self.send_response(200)
        self.send_header("Content-Length", str(total_size))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Content-Type", mime)
        self.end_headers()

    def do_GET(self):
        data, etag, mime = self._resolve_resource()
        if data is None:
            self.send_error(404, "Not Found")
            return

        total_size = len(data)
        range_header = self.headers.get("Range")

        # Fallback simulation endpoint: /fallback/... returns 200 regardless of Range
        if "/fallback" in self.path or not range_header:
            self.send_response(200)
            self.send_header("Content-Length", str(total_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", etag)
            self.send_header("Content-Type", mime)
            self.end_headers()
            self.wfile.write(data)
            return

        # Check If-Range validator if provided
        if_range = self.headers.get("If-Range")
        if if_range and if_range != etag:
            # Validator mismatch: return full 200
            self.send_response(200)
            self.send_header("Content-Length", str(total_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", etag)
            self.send_header("Content-Type", mime)
            self.end_headers()
            self.wfile.write(data)
            return

        # Empty file edge case
        if total_size == 0:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */0")
            self.send_header("Content-Length", "0")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", etag)
            self.end_headers()
            return

        match = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
        if not match:
            self.send_error(400, "Bad Range Header")
            return

        start_str, end_str = match.groups()
        if start_str and end_str:
            start = int(start_str)
            end = int(end_str)
        elif start_str and not end_str:
            start = int(start_str)
            end = total_size - 1
        elif not start_str and end_str:
            suffix = int(end_str)
            start = max(0, total_size - suffix)
            end = total_size - 1
        else:
            self.send_error(400, "Bad Range")
            return

        if start < 0 or start > end or end >= total_size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{total_size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        chunk = data[start:end + 1]
        chunk_len = len(chunk)

        self.send_response(206)
        self.send_header("Content-Range", f"bytes {start}-{end}/{total_size}")
        self.send_header("Content-Length", str(chunk_len))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Content-Type", mime)
        self.end_headers()
        self.wfile.write(chunk)

    def _resolve_resource(self):
        clean_path = self.path.split("?")[0].strip("/")
        if clean_path == "1kb":
            data = get_or_generate_payload(1024)
        elif clean_path == "100kb":
            data = get_or_generate_payload(100 * 1024)
        elif clean_path == "10mb":
            data = get_or_generate_payload(10 * 1024 * 1024)
        elif clean_path == "64mb":
            data = get_or_generate_payload(64 * 1024 * 1024)
        elif clean_path == "empty":
            data = b""
        elif clean_path.startswith("size/"):
            try:
                sz = int(clean_path.split("/")[1])
                data = get_or_generate_payload(sz)
            except Exception:
                return None, None, None
        else:
            return None, None, None

        etag = f'"{hashlib.sha256(data).hexdigest()[:16]}"'
        return data, etag, "application/octet-stream"

    def log_message(self, format, *args):
        # Quiet logger for tests
        pass

def run(port=8976):
    server = ThreadedHTTPServer(("127.0.0.1", port), HTTPRangeRequestHandler)
    print(f"HTTP Range Server listening on http://127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8976)
    args = parser.parse_args()
    run(args.port)
