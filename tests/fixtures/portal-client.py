#!/usr/bin/env python3
"""A client of the portal frontend's org.freedesktop.portal.Settings, as GTK and libadwaita call it, for
tests/integration/portal_settings.sh (ADR-0035 D-8). Output is JSON on stdout (accent colours rounded to 4 places).

    portal-client.py read-all [NAMESPACE...]   ReadAll
    portal-client.py read-one NAMESPACE KEY    ReadOne (an error prints {"error": name})
    portal-client.py watch FILE SECONDS        SettingChanged signals, one JSON line each, appended to FILE
    portal-client.py choose METHOD OPTIONS SECONDS
                                               org.freedesktop.portal.FileChooser's OpenFile, SaveFile or SaveFiles as an
                                               application calls it (tests/integration/portal_filechooser.sh): OPTIONS a JSON
                                               object of the portal's options (current_folder and files as strings), then the
                                               request's Response signal: {"response": n, "results": {...}}, or {"timeout": true}
    portal-client.py impl METHOD OPTIONS SECONDS
                                               the same call made to grassfield-portal's backend interface directly
                                               (org.freedesktop.impl.portal.FileChooser), as the frontend makes it: its
                                               reply, {"response": n, "results": {...}}, or {"error": name}
"""
import json
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

DEST, PATH, IFACE = "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings"


def plain(value):
    if isinstance(value, float):
        return round(value, 4)
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    return value


# The FileChooser options of the portal's public interface, with their D-Bus types.
CHOOSER_TYPES = {"handle_token": "s", "accept_label": "s", "modal": "b", "multiple": "b", "directory": "b", "current_name": "s",
                 "current_folder": "ay", "current_file": "ay", "files": "aay", "filters": "a(sa(us))", "current_filter": "(sa(us))",
                 "choices": "a(ssa(ss)s)"}


def chooser_options(given):
    out = {}
    for key, value in given.items():
        t = CHOOSER_TYPES[key]
        if t == "ay":
            value = value.encode() + b"\0"
        elif t == "aay":
            value = [v.encode() + b"\0" for v in value]
        elif t == "a(sa(us))":
            value = [(n, [tuple(r) for r in rules]) for n, rules in value]
        elif t == "(sa(us))":
            value = (value[0], [tuple(r) for r in value[1]])
        elif t == "a(ssa(ss)s)":
            value = [(i, label, [tuple(o) for o in opts], init) for i, label, opts, init in value]
        out[key] = GLib.Variant(t, value)
    return out


def choose(conn, method, given, seconds):
    token = "gftest%d" % (GLib.get_monotonic_time() % 1000000)
    sender = conn.get_unique_name()[1:].replace(".", "_")
    request = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
    answer = {}
    loop = GLib.MainLoop()

    def response(_conn, _sender, _path, _iface, _signal, params):
        code, results = params.unpack()
        answer.update({"response": code, "results": plain(results)})
        loop.quit()

    # Subscribed before the call: the response can never come first.
    conn.signal_subscribe(DEST, "org.freedesktop.portal.Request", "Response", request, None, Gio.DBusSignalFlags.NONE, response)
    options = chooser_options(dict(given, handle_token=token))
    conn.call_sync(DEST, PATH, "org.freedesktop.portal.FileChooser", method,
                   GLib.Variant("(ssa{sv})", ("", "Test " + method, options)), None, Gio.DBusCallFlags.NONE, 10000, None)
    GLib.timeout_add(int(float(seconds) * 1000), lambda: (answer.setdefault("timeout", True), loop.quit()))
    loop.run()
    print(json.dumps(answer), flush=True)


def impl(conn, method, given, seconds):
    try:
        reply = conn.call_sync("org.freedesktop.impl.portal.desktop.grassfield", PATH, "org.freedesktop.impl.portal.FileChooser", method,
                               GLib.Variant("(osssa{sv})", ("/org/freedesktop/portal/desktop/request/1_1/impl", "org.example.App", "",
                                                            "Test " + method, chooser_options(given))),
                               GLib.VariantType("(ua{sv})"), Gio.DBusCallFlags.NONE, int(float(seconds) * 1000), None)
        code, results = reply.unpack()
        print(json.dumps({"response": code, "results": plain(results)}))
    except GLib.Error as error:
        print(json.dumps({"error": Gio.DBusError.get_remote_error(error) or error.message}))


def main():
    conn = Gio.bus_get_sync(Gio.BusType.SESSION)
    command = sys.argv[1]
    if command == "choose":
        choose(conn, sys.argv[2], json.loads(sys.argv[3]), sys.argv[4])
        return
    if command == "impl":
        impl(conn, sys.argv[2], json.loads(sys.argv[3]), sys.argv[4])
        return
    if command == "watch":
        out = open(sys.argv[2], "a")

        def changed(_conn, _sender, _path, _iface, _signal, params):
            ns, key, value = params.unpack()
            out.write(json.dumps({"ns": ns, "key": key, "value": plain(value)}) + "\n")
            out.flush()

        conn.signal_subscribe(DEST, IFACE, "SettingChanged", PATH, None, Gio.DBusSignalFlags.NONE, changed)
        loop = GLib.MainLoop()
        GLib.timeout_add(int(float(sys.argv[3]) * 1000), loop.quit)
        print(json.dumps({"watching": True}), flush=True)
        loop.run()
        return
    try:
        if command == "read-all":
            reply = conn.call_sync(DEST, PATH, IFACE, "ReadAll", GLib.Variant("(as)", (sys.argv[2:],)), None,
                                   Gio.DBusCallFlags.NONE, 10000, None)
        else:
            reply = conn.call_sync(DEST, PATH, IFACE, "ReadOne", GLib.Variant("(ss)", (sys.argv[2], sys.argv[3])), None,
                                   Gio.DBusCallFlags.NONE, 10000, None)
        print(json.dumps(plain(reply.unpack()[0])))
    except GLib.Error as error:
        print(json.dumps({"error": Gio.DBusError.get_remote_error(error) or error.message}))


main()
