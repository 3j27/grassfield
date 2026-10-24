# A local HTTPS server for tests/security/theme_icon_files.sh, part 6 (media art over https, offline): argv is <cert>
# <key> <request log> <FIFO an SVG names>. It listens on 127.0.0.1 only (an ephemeral port, printed first), with a plain
# HTTP twin on another port (so that a redirect to http would succeed if it were followed), logs each request as a JSON
# line (scheme, path, Cookie, Authorization, User-Agent) and quits after 300 s. Routes:
#   /ok.png /a.png /b.png /c.png /locked.png  a PNG          /svgref.svg  an SVG naming the FIFO (absolute href)
#   /html            text/html, not an image                  /redir-http  302 to http://127.0.0.1:<twin>/ok.png
#   /redir-file      302 to file:///etc/hostname               /redir/<n>   n more 302s, then /ok.png
#   /cookie          302 to /ok.png with Set-Cookie             /big-length  6 MiB announced and sent
#   /big-chunked     6 MiB without a length (chunked)           /slow        nothing for 8 s, then a PNG
import base64
import http.server
import json
import socketserver
import ssl
import sys
import threading
import time

cert, key, log_path, fifo = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
SVG = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="32">'
       '<rect width="64" height="32" fill="red"/><image xlink:href="%s" width="8" height="8"/></svg>' % fifo).encode()
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="image/png", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location, headers=()):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()

    def do_GET(self):
        with lock, open(log_path, "a") as f:
            f.write(json.dumps({"scheme": self.server.scheme, "path": self.path, "cookie": self.headers.get("Cookie"), "auth": self.headers.get("Authorization"),
                                "agent": self.headers.get("User-Agent")}) + "\n")
        p = self.path
        if p in ("/ok.png", "/a.png", "/b.png", "/c.png", "/locked.png"):
            self.send(200, PNG)
        elif p == "/svgref.svg":
            self.send(200, SVG, "image/svg+xml")
        elif p == "/html":
            self.send(200, b"<!DOCTYPE html><html><body>not an image</body></html>", "text/html")
        elif p == "/redir-http":
            self.redirect("http://127.0.0.1:%d/ok.png" % plain.server_address[1])
        elif p == "/redir-file":
            self.redirect("file:///etc/hostname")
        elif p.startswith("/redir/"):
            n = int(p.split("/")[2])
            self.redirect("/redir/%d" % (n - 1) if n > 1 else "/ok.png")
        elif p == "/cookie":
            self.redirect("/ok.png", [("Set-Cookie", "session=secret; Path=/")])
        elif p == "/big-length":
            self.send(200, PNG + b"\0" * (6 * 1024 * 1024))
        elif p == "/big-chunked":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            chunk = b"\0" * 65536
            try:
                for _ in range(96):
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.write(b"0\r\n\r\n")
            except OSError:
                pass
        elif p == "/slow":
            time.sleep(8)
            try:
                self.send(200, PNG)
            except OSError:
                pass
        else:
            self.send(404, b"", "text/plain")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


plain = Server(("127.0.0.1", 0), Handler)
plain.scheme = "http"
server = Server(("127.0.0.1", 0), Handler)
server.scheme = "https"
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
print(server.server_address[1], flush=True)
threading.Thread(target=plain.serve_forever, daemon=True).start()
threading.Timer(300, server.shutdown).start()
server.serve_forever()
