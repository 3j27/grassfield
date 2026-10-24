#!/usr/bin/env python3
"""Read Hyprland's event socket (socket2) of the given instance for N seconds and print one JSON line per event:
{"t": ms since the start, "name": ..., "data": ...}. Read-only: it only listens. Used by tests/shell/show_desktop_record.sh to
record the event sequences tests/unit/tst_showdesktopreplay.qml replays. Run it only for the NESTED instance.

Usage: hypr-events.py SIGNATURE SECONDS [name,name,...]   (names: only those events; default: all)
"""
import json
import os
import socket
import sys
import time


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sig = sys.argv[1]
    seconds = float(sys.argv[2])
    only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 and sys.argv[3] else None
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "hypr", sig, ".socket2.sock")
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    s.settimeout(0.05)
    start = time.monotonic()
    buf = b""
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()
    while time.monotonic() - start < seconds:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        now = int((time.monotonic() - start) * 1000)
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode(errors="replace")
            name, _, data = text.partition(">>")
            if only is None or name in only:
                sys.stdout.write(json.dumps({"t": now, "name": name, "data": data}) + "\n")
                sys.stdout.flush()


main()
