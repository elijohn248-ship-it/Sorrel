#!/usr/bin/env python3
"""Local fixture server for the Birch Chromium edition tests (from the wave-1
CEF prototype).

Serves fixtures/pages, dynamic storage/download/ad-test responses and the
CI-generated media files on 127.0.0.1 only: one plain HTTP port and one HTTPS
port with a deliberately untrusted, self-signed certificate. Every request is
logged as a JSON line (scheme, host, path) so tests can prove which requests
reached it.
"""
import argparse
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
PAGES = os.path.join(HERE, "pages")
GIF = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04"
       b"\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
MEDIA_TYPES = {".mp4": "video/mp4", ".m4a": "audio/mp4", ".webm": "video/webm",
               ".weba": "audio/webm", ".ogg": "audio/ogg"}
LOCK = threading.Lock()
ARGS = None


def log_request(scheme, host, path):
    with LOCK:
        with open(ARGS.log, "a", encoding="utf-8") as f:
            f.write(json.dumps({"scheme": scheme, "host": host, "path": path}) + "\n")


class Handler(BaseHTTPRequestHandler):
    scheme = "http"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep CI output short
        pass

    def send(self, status, body, ctype="text/html; charset=utf-8", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle(self):
        try:
            super().handle()
        except (ConnectionError, TimeoutError):
            pass  # the browser closed the connection; nothing to report

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlsplit(self.path)
        path, query = url.path, parse_qs(url.query)
        host = (self.headers.get("Host") or "").split(":")[0]
        log_request(self.scheme, host, path)
        q = lambda k: "".join(c for c in query.get(k, [""])[0] if c.isalnum())[:40]

        if path == "/storage":
            role, nonce = q("role"), q("nonce")
            body = (f"<!doctype html><title>storage {role}</title>"
                    f"<script src='/cacheable.js?role={role}&nonce={nonce}'></script>"
                    f"<script>localStorage.setItem('birch{role}','{nonce}');</script>"
                    f"<p>storage fixture</p>").encode()
            return self.send(200, body, headers={
                "Set-Cookie": f"birch{role}_{nonce}=1; Max-Age=3600; Path=/; SameSite=Lax",
                "Cache-Control": "no-store"})
        if path == "/cacheable.js":
            return self.send(200, f"window.__birch_cache='{q('role')}';".encode(),
                             "text/javascript", {"Cache-Control": "public, max-age=3600"})
        if path.startswith("/download/"):
            name = "".join(c for c in path[len("/download/"):] if c.isalnum() or c in ".-_")
            return self.send(200, b"BIRCH-DOWNLOAD-TEST\n" * 64, "application/octet-stream",
                             {"Content-Disposition": f'attachment; filename="{name}"'})
        if path == "/tls/secret.html":
            return self.send(200, b"<!doctype html><p>BADCERT-CONTENT</p>")
        if path in ("/pagead/js/adsbygoogle.js", "/beacon.js"):
            return self.send(200, b"/* fixture script */", "text/javascript")
        if path == "/collect":
            return self.send(200, GIF, "image/gif")
        if path.startswith("/media/"):
            return self.media(os.path.basename(path))
        name = os.path.basename(path) or "page1.html"
        file = os.path.join(PAGES, name)
        if path == "/" + name and os.path.isfile(file):
            with open(file, "rb") as f:
                return self.send(200, f.read(), headers={"Cache-Control": "no-store"})
        return self.send(404, b"not found", "text/plain")

    def media(self, name):
        file = os.path.join(ARGS.media, name)
        if not ARGS.media or not os.path.isfile(file):
            return self.send(404, b"no media", "text/plain")
        with open(file, "rb") as f:
            data = f.read()
        ctype = MEDIA_TYPES.get(os.path.splitext(name)[1], "application/octet-stream")
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start_s, _, end_s = rng[6:].partition("-")
            start = int(start_s or 0)
            end = min(int(end_s) if end_s else len(data) - 1, len(data) - 1)
            part = data[start:end + 1]
            return self.send(206, part, ctype, {
                "Content-Range": f"bytes {start}-{end}/{len(data)}", "Accept-Ranges": "bytes"})
        return self.send(200, data, ctype, {"Accept-Ranges": "bytes"})


class TlsHandler(Handler):
    scheme = "https"


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--http-port", type=int, required=True)
    p.add_argument("--https-port", type=int, required=True)
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--media", default="")
    p.add_argument("--log", required=True)
    ARGS = p.parse_args()
    http = ThreadingHTTPServer(("127.0.0.1", ARGS.http_port), Handler)
    https = ThreadingHTTPServer(("127.0.0.1", ARGS.https_port), TlsHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(ARGS.cert, ARGS.key)
    https.socket = ctx.wrap_socket(https.socket, server_side=True)
    threading.Thread(target=https.serve_forever, daemon=True).start()
    print("fixtures: ready", flush=True)
    http.serve_forever()


if __name__ == "__main__":
    main()
