#!/usr/bin/env python3
"""A client of the portal frontend's org.freedesktop.portal.Settings, as GTK and libadwaita call it, for
tests/integration/portal_settings.sh (ADR-0035 D-8). Output is JSON on stdout (accent colours rounded to 4 places).

    portal-client.py read-all [NAMESPACE...]   ReadAll
    portal-client.py read-one NAMESPACE KEY    ReadOne (an error prints {"error": name})
    portal-client.py watch FILE SECONDS        SettingChanged signals, one JSON line each, appended to FILE
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


def main():
    conn = Gio.bus_get_sync(Gio.BusType.SESSION)
    command = sys.argv[1]
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
