#!/usr/bin/env python3
"""A stand-in com.canonical.AppMenu.Registrar for tests/apps/files_registrar.sh. TEST HELPER ONLY.

It owns the registrar name on the session bus named by DBUS_SESSION_BUS_ADDRESS and logs every call on stdout. It refuses
anything but a private bus (unix:path=/tmp/dbus-*, as dbus-daemon --session creates it): owning the name on the owner's
bus would hide the menus of the owner's own Qt applications. (tests/fixtures/fake-registrar does the same, but refuses a
bus that already has other names, such as portals activated by the application under test.)
"""
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "com.canonical.AppMenu.Registrar"
PATH = "/com/canonical/AppMenu/Registrar"
XML = """<node><interface name="com.canonical.AppMenu.Registrar">
<method name="RegisterWindow"><arg type="u" name="windowId" direction="in"/><arg type="o" name="menuObjectPath" direction="in"/></method>
<method name="UnregisterWindow"><arg type="u" name="windowId" direction="in"/></method>
<method name="GetMenuForWindow"><arg type="u" name="windowId" direction="in"/><arg type="s" name="service" direction="out"/><arg type="o" name="menuObjectPath" direction="out"/></method>
</interface></node>"""

windows = {}


def say(line):
    print("stub-registrar: " + line, flush=True)


def on_call(conn, sender, path, iface, method, params, invocation):
    if method == "RegisterWindow":
        wid, menu = params.unpack()
        windows[wid] = (sender, menu)
        say("RegisterWindow id=%d service=%s path=%s" % (wid, sender, menu))
        invocation.return_value(None)
    elif method == "UnregisterWindow":
        (wid,) = params.unpack()
        windows.pop(wid, None)
        say("UnregisterWindow id=%d from %s" % (wid, sender))
        invocation.return_value(None)
    elif method == "GetMenuForWindow":
        (wid,) = params.unpack()
        if wid in windows:
            invocation.return_value(GLib.Variant("(so)", windows[wid]))
        else:
            invocation.return_dbus_error("com.canonical.AppMenu.Registrar.Error.NotFound", "no such window")
    else:
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)


def main():
    bus = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not bus.startswith("unix:path=/tmp/dbus-"):
        say("refusing: not a private test bus (%r)" % bus)
        return 2
    conn = Gio.DBusConnection.new_for_address_sync(
        bus, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object(PATH, node.interfaces[0], on_call, None, None)
    loop = GLib.MainLoop()
    Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE,
                                   lambda c, n: say("owning %s on private bus %s as %s" % (n, bus, c.get_unique_name())),
                                   lambda c, n: (say("could not own " + n), loop.quit()))
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
