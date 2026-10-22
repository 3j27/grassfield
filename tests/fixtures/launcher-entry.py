#!/usr/bin/env python3
"""A test application that sets Dock badges, progress and urgent through com.canonical.Unity.LauncherEntry
(tests/integration/launcher_entry.sh, ADR-0018).

Runs on the bus named by DBUS_SESSION_BUS_ADDRESS, which the test sets to a PRIVATE dbus-daemon: it refuses to start on
anything else (GF_TEST_BUS=1 and no /run/user path). It runs the steps of --steps FILE, one per line, then touches
--done FILE and (with --hold) keeps its bus connection until it is terminated, so that "the sender leaves the bus" is
something the test decides.

    emit <GVariant text of (sa{sv})>        e.g.  emit ('application://a.desktop', {'count': <int64 5>})
    raw <type string> <GVariant text>       a signal of another signature (a malformed sender)
    flood <n> <app>                         n updates {'count': <int64 i>} for application://<app>.desktop, back to back
    sleep <ms>
"""
import argparse
import os
import signal
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

PATH = "/com/gftest/LauncherEntry"
IFACE = "com.canonical.Unity.LauncherEntry"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", required=True)
    ap.add_argument("--done", required=True)
    ap.add_argument("--hold", action="store_true")
    args = ap.parse_args()

    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not addr.startswith("unix:") or "/run/user/" in addr or os.environ.get("GF_TEST_BUS") != "1":
        sys.exit("launcher-entry: refusing to run on %r: only a private test bus (GF_TEST_BUS=1)" % addr)

    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def emit(variant):
        conn.emit_signal(None, PATH, IFACE, "Update", variant)

    with open(args.steps) as f:
        steps = [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]
    for step in steps:
        verb, _, rest = step.partition(" ")
        if verb == "emit":
            emit(GLib.Variant.parse(GLib.VariantType.new("(sa{sv})"), rest))
        elif verb == "raw":
            vtype, _, text = rest.partition(" ")
            emit(GLib.Variant.parse(GLib.VariantType.new(vtype), text))
        elif verb == "flood":
            n, _, app = rest.partition(" ")
            for i in range(int(n)):
                emit(GLib.Variant("(sa{sv})", ("application://%s.desktop" % app, {"count": GLib.Variant("x", i)})))
        elif verb == "sleep":
            conn.flush_sync(None)
            time.sleep(int(rest) / 1000.0)
        else:
            sys.exit("launcher-entry: unknown step %r" % step)
    conn.flush_sync(None)
    with open(args.done, "w") as f:
        f.write("done\n")
    if args.hold:
        signal.pause()


if __name__ == "__main__":
    main()
