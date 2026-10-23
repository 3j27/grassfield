#!/usr/bin/env python3
"""Loopback stand-in for commons.wikimedia.org, for the helper's unit tests and the nested visual test. Never a real host.

  python3 -I server.py --dir DIR [--port N]

Prints "PORT <n>" on stdout once it listens (127.0.0.1 only). It answers the three requests of `grassfield-wallpaper fetch
commons` from fixture files in DIR:
  expandtemplates {{Potd/DATE}}         -> expand-file-DATE.json, else expand-file.json
  expandtemplates {{Potd/DATE (LANG)}}  -> expand-caption-LANG.json (404 when absent)
  query imageinfo                       -> imageinfo.json
  GET /thumb/<name>                     -> DIR/<name>, Content-Type from its suffix
In every JSON fixture "@BASE@" is replaced by this server's origin. DIR/mode changes the behaviour at run time (it is read for
every request): "fail" answers 500 to everything; "evil-redirect" answers the thumbnail with a 302 to another host;
"big-json" answers the API with 300 KiB; "html-picture" serves the thumbnail as text/html. Every request is appended to
DIR/requests.log as "PATH | ua=... | referer=... | cookie=...".
"""
import argparse
import http.server
import os
import sys
import urllib.parse

TYPES = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp", ".gif": "image/gif"}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fixture"
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def mode(self):
        try:
            with open(os.path.join(self.server.dir, "mode")) as f:
                return f.read().strip()
        except OSError:
            return ""

    def send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def fixture(self, name):
        path = os.path.join(self.server.dir, name)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                return f.read()
        return None

    def json(self, name):
        raw = self.fixture(name)
        if raw is None:
            self.send(404, "text/plain", b"missing fixture")
            return
        self.send(200, "application/json; charset=utf-8", raw.replace(b"@BASE@", self.server.origin.encode()))

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        with open(os.path.join(self.server.dir, "requests.log"), "a") as log:
            log.write("%s | ua=%s | referer=%s | cookie=%s\n" % (self.path, self.headers.get("User-Agent", ""), self.headers.get("Referer", ""), self.headers.get("Cookie", "")))
        mode = self.mode()
        if mode == "fail":
            self.send(500, "text/plain", b"fixture failure")
            return
        if url.path == "/w/api.php":
            if mode == "big-json":
                self.send(200, "application/json", b'{"pad":"' + b"x" * (300 * 1024) + b'"}')
                return
            action = query.get("action", [""])[0]
            if action == "expandtemplates":
                text = query.get("text", [""])[0]
                if not (text.startswith("{{Potd/") and text.endswith("}}")):
                    self.send(400, "text/plain", b"bad text")
                    return
                inner = text[len("{{Potd/"):-2]
                if " (" in inner:
                    lang = inner.split(" (", 1)[1].rstrip(")")
                    self.json("expand-caption-%s.json" % lang)
                else:
                    name = "expand-file-%s.json" % inner
                    self.json(name if os.path.isfile(os.path.join(self.server.dir, name)) else "expand-file.json")
            elif action == "query":
                self.json("imageinfo.json")
            else:
                self.send(400, "text/plain", b"bad action")
            return
        if url.path == "/planetary/apod":
            # Stand-in for api.nasa.gov (NASA APOD): apod-DATE.json, else apod.json; "@BASE@" is this origin.
            date = query.get("date", [""])[0]
            name = "apod-%s.json" % date
            self.json(name if os.path.isfile(os.path.join(self.server.dir, name)) else "apod.json")
            return
        if url.path.startswith("/apod/image/"):
            name = os.path.basename(url.path)
            if mode == "apod-path-redirect":
                # A redirect to another page of the same (allowed) host: the path rule must refuse it before any request there.
                self.send(302, "text/plain", b"", {"Location": "/thumb/picture.jpg"})
                return
            raw = self.fixture(name)
            if raw is None:
                self.send(404, "text/plain", b"missing picture")
                return
            self.send(200, TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream"), raw)
            return
        if url.path.startswith("/thumb/"):
            name = os.path.basename(url.path)
            if mode == "evil-redirect":
                self.send(302, "text/plain", b"", {"Location": "http://example.invalid/steal.jpg"})
                return
            raw = self.fixture(name)
            if raw is None:
                self.send(404, "text/plain", b"missing picture")
                return
            ctype = "text/html" if mode == "html-picture" else TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")
            self.send(200, ctype, raw)
            return
        self.send(404, "text/plain", b"not found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.dir = os.path.abspath(args.dir)
    server.origin = "http://127.0.0.1:%d" % server.server_address[1]
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
