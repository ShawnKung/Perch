#!/usr/bin/env python3
"""Exercise native WebKit downloads with isolated local HTTP fixtures."""
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

requests = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requests.append(self.path)
        if self.path == "/page":
            data = b"""<title>Downloads fixture</title>
                <a id="slow" href="/slow">slow</a>
                <a id="fast" href="/redirect">fast</a>
                <a id="unknown" href="/unknown">unknown</a>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", "download_fixture=allowed; HttpOnly; Path=/")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/fast")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/redirect-public":
            self.send_response(302)
            self.send_header("Location", os.environ.get(
                "PERCH_DOWNLOAD_CHECK_URL", f"http://localhost:{self.server.server_port}/public"))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path not in ("/slow", "/fast", "/unknown", "/public"):
            self.send_error(404)
            return
        if self.path != "/public" and "download_fixture=allowed" not in self.headers.get("Cookie", ""):
            self.send_error(401)
            return
        data = b"fast fixture" if self.path in ("/fast", "/public") else b"synthetic download\n" * 4096
        self.send_response(200)
        self.send_header("Content-Type", "text/html" if self.path == "/fast" else "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="fixture.bin"')
        if self.path != "/unknown":
            self.send_header("Content-Length", str(len(data)))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        try:
            for offset in range(0, len(data), 2048):
                self.wfile.write(data[offset:offset + 2048])
                self.wfile.flush()
                if self.path not in ("/fast", "/public"):
                    time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run(
            [sys.argv[1], "--download-self-test", f"http://127.0.0.1:{server.server_port}"],
            timeout=90,
        )
        if result.returncode:
            print("Download fixture requests:", requests, file=sys.stderr)
        sys.exit(result.returncode)
    finally:
        server.shutdown()
        server.server_close()
