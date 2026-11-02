#!/usr/bin/env python3
"""Peers of org.kde.kpasswdserver6 for tests/security/kio_passwd.sh (ADR-0035 D-12 b, step 9e), on a private bus of the test's.

  kpasswd-peer.py kiod|listener|stranger --log FILE [--commands FIFO]

kiod      a stand-in for kiod6, as D-Bus activation starts it: owns org.kde.kpasswdserver6 without queueing (Qt's
          registerService defaults, kiod_main.cpp:112; "#owned" or "#not-owned") and answers every check and query with the
          user "kiod-standin" in a result it BROADCASTS, as kpasswdserver does (kpasswdserver.cpp:330, 852); logs each call
listener  any other client of the bus: a plain match rule on both result signals of org.kde.kpasswdserver6, as every KIO
          client's own; logs "signal <member> <requestId> user=<user> password=<set|empty>" for each one it receives
stranger  a client that is not KIO's (a Python program), commands from FIFO, one per line:
            query URL [USER]   queryAuthInfoAsync, keepPassword set; logs "query <id>", then "result query <id> modified=<0|1>
                               user=<u> password=<p>" when its result comes
            check URL [USER]   checkAuthInfoAsync; likewise
            add URL USER PASS  addAuthInfo (keepPassword), a blocking call: "add replied <ms>" when its reply came
            many N URL         N queries of URL at once, windows 1..N
            big                an AuthInfo whose URL is over the bridge's bound: "big error <name>"
            legacy             KIO's LEGACY addAuthInfo(ay, x): "legacy error <name>"
            quit               leaves the bus
Refuses any bus that is not under GF_TEST_BUS_DIR (the rule of the tests' fakes). Test data only. Run it with python3 -I.
"""
import argparse
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "org.kde.kpasswdserver6"
PATH = "/modules/kpasswdserver"
IFACE = "org.kde.KPasswdServer"
AUTHINFO = "(ysssssssssbbbba{s(siv)})"
XML = """<node><interface name="org.kde.KPasswdServer">
<signal name="checkAuthInfoAsyncResult"><arg type="x"/><arg type="x"/><arg type="%(a)s"/></signal>
<signal name="queryAuthInfoAsyncResult"><arg type="x"/><arg type="x"/><arg type="%(a)s"/></signal>
<method name="checkAuthInfoAsync"><arg direction="out" type="x"/><arg direction="in" type="%(a)s"/><arg direction="in" type="x"/><arg direction="in" type="x"/></method>
<method name="queryAuthInfoAsync"><arg direction="out" type="x"/><arg direction="in" type="%(a)s"/><arg direction="in" type="s"/><arg direction="in" type="x"/><arg direction="in" type="x"/><arg direction="in" type="x"/></method>
<method name="addAuthInfo"><arg direction="in" type="%(a)s"/><arg direction="in" type="x"/></method>
<method name="removeAuthInfo"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="s"/></method>
</interface></node>""" % {"a": AUTHINFO}


def private_bus(address, directory):
    if not address or not directory:
        return False
    root = os.path.realpath(directory)
    for entry in address.split(";"):
        if not entry.startswith("unix:path="):
            return False
        path = entry[len("unix:path="):].split(",")[0]
        if not os.path.realpath(path).startswith(root + "/"):
            return False
    return True


def authinfo(url, user="", password="", keep=False, extra=None):
    return GLib.Variant(AUTHINFO, (1, url, user, password, "", "", "", "", "", "", False, False, keep, False, extra or {}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("role", choices=["kiod", "listener", "stranger"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--commands")
    args = ap.parse_args()
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not private_bus(address, os.environ.get("GF_TEST_BUS_DIR", "")):
        sys.stderr.write("kpasswd-peer: refusing a bus that is not a private test bus\n")
        return 3
    log = open(args.log, "a", buffering=1, encoding="utf-8")
    bus = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    loop = GLib.MainLoop()

    if args.role == "kiod":
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        counter = [100]

        def on_call(conn, sender, path, iface, method, params, inv):
            log.write("call %s\n" % method)
            if method in ("checkAuthInfoAsync", "queryAuthInfoAsync"):
                rid = counter[0]
                counter[0] += 1
                inv.return_value(GLib.Variant("(x)", (rid,)))
                info = params.unpack()[0]
                result = (1, info[1], "kiod-standin", "standin-pass", "", "", "", "", "", "", False, False, False, True, {})
                member = "checkAuthInfoAsyncResult" if method == "checkAuthInfoAsync" else "queryAuthInfoAsyncResult"
                conn.emit_signal(None, PATH, IFACE, member, GLib.Variant("(xx%s)" % AUTHINFO, (rid, 1, result)))
            else:
                inv.return_value(None)

        bus.register_object(PATH, node.interfaces[0], on_call, None, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
        log.write("#owned\n" if reply.unpack()[0] in (1, 4) else "#not-owned\n")
        loop.run()
        return 0

    def on_signal(conn, sender, path, iface, member, params):
        rid, seq, info = params.unpack()
        if args.role == "listener":
            log.write("signal %s %d user=%s password=%s\n" % (member, rid, info[2] or "-", "set" if info[3] else "empty"))
        else:
            kind = "check" if member.startswith("check") else "query"
            log.write("result %s %d modified=%d user=%s password=%s\n" % (kind, rid, 1 if info[13] else 0, info[2] or "-", info[3] or "-"))

    for member in ("checkAuthInfoAsyncResult", "queryAuthInfoAsyncResult"):
        bus.signal_subscribe(NAME, IFACE, member, PATH, None, Gio.DBusSignalFlags.NONE, on_signal)
    log.write("#ready %s\n" % bus.get_unique_name())
    if args.role == "listener":
        loop.run()
        return 0

    def call(method, params, out, cb):
        bus.call(NAME, PATH, IFACE, method, params, GLib.VariantType(out) if out else None, Gio.DBusCallFlags.NO_AUTO_START, 10000,
                 None, cb)

    def on_id(kind):
        def done(conn, res):
            try:
                rid = conn.call_finish(res).unpack()[0]
                log.write("%s %d\n" % (kind, rid))
            except GLib.Error as e:
                log.write("%s error %s\n" % (kind, Gio.DBusError.get_remote_error(e) or e.message))
        return done

    def command(words):
        op = words[0]
        if op == "query":
            call("queryAuthInfoAsync", GLib.Variant("(%ssxxx)" % AUTHINFO, (authinfo(words[1], words[2] if len(words) > 2 else "", keep=True), "", 0, 0, 0)),
                 "(x)", on_id("query"))
        elif op == "check":
            call("checkAuthInfoAsync", GLib.Variant("(%sxx)" % AUTHINFO, (authinfo(words[1], words[2] if len(words) > 2 else ""), 0, 0)), "(x)", on_id("check"))
        elif op == "many":
            for i in range(int(words[1])):
                call("queryAuthInfoAsync", GLib.Variant("(%ssxxx)" % AUTHINFO, (authinfo(words[2], keep=True), "", i + 1, 0, 0)), "(x)", on_id("query"))
        elif op == "add":
            start = time.monotonic()
            try:
                bus.call_sync(NAME, PATH, IFACE, "addAuthInfo", GLib.Variant("(%sx)" % AUTHINFO, (authinfo(words[1], words[2], words[3], keep=True), 0)),
                              None, Gio.DBusCallFlags.NO_AUTO_START, 20000, None)
                log.write("add replied %d\n" % int((time.monotonic() - start) * 1000))
            except GLib.Error as e:
                log.write("add error %s\n" % (Gio.DBusError.get_remote_error(e) or e.message))
        elif op == "big":
            call("checkAuthInfoAsync", GLib.Variant("(%sxx)" % AUTHINFO, (authinfo("sftp://example.org/" + "a" * 5000), 0, 0)), "(x)", on_id("big"))
        elif op == "legacy":
            call("addAuthInfo", GLib.Variant("(ayx)", (b"\x00" * 8, 0)), None, on_id("legacy"))
        elif op == "quit":
            log.write("#bye\n")
            bus.close_sync(None)
            loop.quit()

    fd = os.open(args.commands, os.O_RDWR | os.O_NONBLOCK)
    buf = [b""]

    def on_input(source, condition):
        try:
            buf[0] += os.read(fd, 65536)
        except BlockingIOError:
            return True
        while b"\n" in buf[0]:
            line, buf[0] = buf[0].split(b"\n", 1)
            words = line.decode().split()
            if words:
                command(words)
        return True

    GLib.io_add_watch(fd, GLib.IO_IN, on_input)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
