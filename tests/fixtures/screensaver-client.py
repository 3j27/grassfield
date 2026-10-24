#!/usr/bin/env python3
"""A test application that takes org.freedesktop.ScreenSaver idle inhibitors (tests/integration/screensaver_inhibit.sh,
GF-016).

Runs on the bus named by DBUS_SESSION_BUS_ADDRESS, which the test sets to a PRIVATE dbus-daemon: it refuses to start on
anything else (GF_TEST_BUS=1 and no /run/user path). It runs the steps of --steps FILE, one per line, appends one result
line per call to --out, then touches --done and (with --hold) keeps its bus connection until it is terminated.

    inhibit <app> <reason>        Inhibit(s, s) on /org/freedesktop/ScreenSaver; result "cookie <n>" or "error <name>"
    inhibit-legacy <app> <reason> the same on /ScreenSaver
    inhibit-noreply <app> <reason> Inhibit with NO_REPLY_EXPECTED, not waiting (with no --hold: leave at once)
    inhibit-async <app> <reason>  Inhibit expecting a reply that is never read (with no --hold: leave at once)
    uninhibit <index>             UnInhibit(u) with the cookie of the <index>-th successful inhibit (0-based)
    uninhibit-raw <n>             UnInhibit(u) with the number n (another client's cookie, an unknown one)
    call <method>                 a method without arguments (Lock, GetActive, SetActive...): "ok" or "error <name>"
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

NAME = "org.freedesktop.ScreenSaver"
IFACE = "org.freedesktop.ScreenSaver"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--done", required=True)
    ap.add_argument("--hold", action="store_true")
    args = ap.parse_args()

    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not addr.startswith("unix:") or "/run/user/" in addr or os.environ.get("GF_TEST_BUS") != "1":
        sys.exit("screensaver-client: refusing to run on %r: only a private test bus (GF_TEST_BUS=1)" % addr)

    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    cookies = []
    out = open(args.out, "a", buffering=1)

    def call(path, method, params, reply_type):
        try:
            v = conn.call_sync(NAME, path, IFACE, method, params, GLib.VariantType.new(reply_type) if reply_type else None,
                               Gio.DBusCallFlags.NONE, 3000, None)
            return ("ok", v)
        except GLib.Error as e:
            return ("error", Gio.DBusError.get_remote_error(e) or e.message)

    with open(args.steps) as f:
        steps = [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]
    for step in steps:
        verb, _, rest = step.partition(" ")
        if verb == "inhibit-noreply":
            # Sent without waiting for (or wanting) the reply: with no --hold the client leaves at once, usually before
            # the bridge has handled the call (the race of the 4b8592d review).
            app, _, reason = rest.partition(" ")
            msg = Gio.DBusMessage.new_method_call(NAME, "/ScreenSaver", IFACE, "Inhibit")
            msg.set_body(GLib.Variant("(ss)", (app, reason)))
            msg.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED)
            conn.send_message(msg, Gio.DBusSendMessageFlags.NONE)
            out.write("sent\n")
        elif verb == "inhibit-async":
            # Sent expecting a reply, but the client leaves without reading it.
            app, _, reason = rest.partition(" ")
            msg = Gio.DBusMessage.new_method_call(NAME, "/org/freedesktop/ScreenSaver", IFACE, "Inhibit")
            msg.set_body(GLib.Variant("(ss)", (app, reason)))
            conn.send_message(msg, Gio.DBusSendMessageFlags.NONE)
            out.write("sent\n")
        elif verb in ("inhibit", "inhibit-legacy"):
            app, _, reason = rest.partition(" ")
            path = "/org/freedesktop/ScreenSaver" if verb == "inhibit" else "/ScreenSaver"
            kind, v = call(path, "Inhibit", GLib.Variant("(ss)", (app, reason)), "(u)")
            if kind == "ok":
                cookies.append(v.unpack()[0])
                out.write("cookie %d\n" % v.unpack()[0])
            else:
                out.write("error %s\n" % v)
        elif verb in ("uninhibit", "uninhibit-raw"):
            n = cookies[int(rest)] if verb == "uninhibit" else int(rest)
            kind, v = call("/org/freedesktop/ScreenSaver", "UnInhibit", GLib.Variant("(u)", (n,)), "()")
            out.write("ok\n" if kind == "ok" else "error %s\n" % v)
        elif verb == "call":
            kind, v = call("/org/freedesktop/ScreenSaver", rest, None, None)
            out.write("ok\n" if kind == "ok" else "error %s\n" % v)
        elif verb == "sleep":
            conn.flush_sync(None)
            time.sleep(int(rest) / 1000.0)
        else:
            sys.exit("screensaver-client: unknown step %r" % step)
    conn.flush_sync(None)
    with open(args.done, "w") as f:
        f.write("done\n")
    if args.hold:
        signal.pause()


if __name__ == "__main__":
    main()
