#!/usr/bin/env python3
"""A minimal FTP server that asks for a login, for tests/security/kio_passwd.sh (ADR-0035 D-12 b, step 9e): it lets KIO's real
ftp worker (kio_ftp in /usr/lib/kf6/kioworker) log in, which makes the worker ask org.kde.kpasswdserver6 for a name and a
password exactly as it does for a real server (KIO src/kioworkers/ftp/ftp.cpp ftpLogin: the cache first, then anonymous,
then the dialog, then cacheAuthentication when "keep" was chosen).

  ftp-login-server.py --port-file FILE --log FILE --user USER --password PASSWORD

Listens on 127.0.0.1 (a port of its own, written to --port-file). Anonymous logins are refused (530); USER and PASS must be
the given ones. After a login: SYST, FEAT, PWD and TYPE are answered, anything else 502. Logs "connect", "login ok <user>"
and "login refused <user>" (never a password). Standard library only; run it with python3 -I. Test data only.
"""
import argparse
import socketserver
import sys
import threading


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    args = ap.parse_args()
    log = open(args.log, "a", buffering=1, encoding="utf-8")
    lock = threading.Lock()

    def note(text):
        with lock:
            log.write(text + "\n")

    class Handler(socketserver.StreamRequestHandler):
        def reply(self, text):
            self.wfile.write((text + "\r\n").encode())
            self.wfile.flush()

        def handle(self):
            note("connect")
            self.reply("220 test server ready")
            user = None
            logged = False
            for raw in self.rfile:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                cmd, _, arg = line.partition(" ")
                cmd = cmd.upper()
                if cmd == "USER":
                    user = arg
                    self.reply("331 password please")
                elif cmd == "PASS":
                    if user == args.user and arg == args.password:
                        logged = True
                        note("login ok %s" % user)
                        self.reply("230 logged in")
                    else:
                        note("login refused %s" % user)
                        self.reply("530 login incorrect")
                elif cmd == "QUIT":
                    self.reply("221 bye")
                    return
                elif not logged:
                    self.reply("530 please log in")
                elif cmd == "SYST":
                    self.reply("215 UNIX Type: L8")
                elif cmd == "FEAT":
                    self.reply("211-Features:")
                    self.reply("211 End")
                elif cmd == "PWD":
                    self.reply('257 "/" is the current directory')
                elif cmd == "TYPE":
                    self.reply("200 type set")
                else:
                    self.reply("502 not implemented")

    class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = Server(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w") as f:
        f.write("%d\n" % server.server_address[1])
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
