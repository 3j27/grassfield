#!/usr/bin/env python3
"""Loopback server that accepts connections and never answers (for the SIGTERM test of `fetch`).

  python3 -I slow_server.py PORT_FILE

Listens on 127.0.0.1 on a free port, writes the port to PORT_FILE, then holds every connection open for two minutes.
"""
import socket
import sys
import threading
import time


def hold(conn):
    time.sleep(120)
    conn.close()


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    with open(sys.argv[1], "w") as f:
        f.write(str(s.getsockname()[1]))
    while True:
        conn, _ = s.accept()
        threading.Thread(target=hold, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
