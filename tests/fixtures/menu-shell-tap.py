#!/usr/bin/env python3
"""Stands in for grassfield-shell on the menu/1 socket of a test bridge (tests/integration/launcher_entry.sh).

Connects to --socket, says hello (appmenu false: the bridge stays in standby and owns no bus name) and appends every
line the bridge sends to --out until it is terminated. It refuses the session's default bridge socket: only a test
bridge started by the test (private bus, own socket) is ever talked to.
"""
import argparse
import os
import socket
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    default = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"), "grassfield", "menu-bridge.sock")
    if not os.path.isabs(args.socket) or os.path.realpath(args.socket) == os.path.realpath(default):
        sys.exit("menu-shell-tap: refusing %r: only a test bridge's own socket" % args.socket)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.socket)
    s.sendall(b'{"type":"hello","v":"menu/1","appmenu":false}\n')
    buf = b""
    with open(args.out, "ab", buffering=0) as out:
        while True:
            data = s.recv(65536)
            if not data:
                return
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                out.write(line + b"\n")


if __name__ == "__main__":
    main()
