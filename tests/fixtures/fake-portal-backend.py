#!/usr/bin/env python3
"""A stand-in for xdg-desktop-portal-gtk's Settings backend, or a portal frontend that never answers, for
tests/integration/portal_settings.sh (ADR-0035 D-8).

    fake-portal-backend.py gtk            owns org.freedesktop.impl.portal.desktop.gtk: Settings with x-d-p-gtk's kind of
                                          keys (color-scheme 2, contrast 0, gtk-theme Adwaita-dark, font-name) and its
                                          namespace filter, each call logged to --log
    fake-portal-backend.py silent-frontend owns org.freedesktop.portal.Desktop and never answers a call

It refuses any bus but a private test bus (GF_TEST_BUS=1, the address under GF_TEST_BUS_DIR), as the other fakes do.
"""
import argparse
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

import importlib.util  # noqa: E402

# The private-bus guard of the Secret Service fakes, one rule for every fake.
_spec = importlib.util.spec_from_file_location("fake_secret_service", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-secret-service.py"))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

XML = """<node><interface name="org.freedesktop.impl.portal.Settings">
<method name="ReadAll"><arg type="as" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<method name="Read"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<signal name="SettingChanged"><arg type="s"/><arg type="s"/><arg type="v"/></signal>
<property name="version" type="u" access="read"/></interface></node>"""
V = GLib.Variant
VALUES = {"org.freedesktop.appearance": {"color-scheme": V("u", 2), "contrast": V("u", 0)},
          "org.gnome.desktop.interface": {"gtk-theme": V("s", "Adwaita-dark"), "font-name": V("s", "Inter 10")}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("role", choices=["gtk", "silent-frontend"])
    ap.add_argument("--log", default=os.devnull)
    args = ap.parse_args()
    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if os.environ.get("GF_TEST_BUS") != "1" or not guard.is_private_test_bus(addr, os.environ.get("GF_TEST_BUS_DIR", "")):
        sys.exit("fake-portal-backend: refusing to run on %r: only a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR)" % addr)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    loop = GLib.MainLoop()
    conn.connect("closed", lambda *_: loop.quit())
    if args.role == "gtk":
        def call(conn, sender, path, iface, method, params, inv):
            with open(args.log, "a") as f:
                f.write(method + "\n")
            if method == "ReadAll":
                # The namespace filter, as x-d-p-gtk applies it: all, an exact namespace, or a trailing glob.
                patterns = params.unpack()[0]
                match = (lambda ns: not patterns or any(p in ("", ns) or (p.endswith("*") and ns.startswith(p[:-1])) for p in patterns))
                return inv.return_value(V("(a{sa{sv}})", ({ns: keys for ns, keys in VALUES.items() if match(ns)},)))
            ns, key = params.unpack()
            if key in VALUES.get(ns, {}):
                return inv.return_value(V("(v)", (VALUES[ns][key],)))
            inv.return_dbus_error("org.freedesktop.portal.Error.NotFound", "not found")
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        conn.register_object("/org/freedesktop/portal/desktop", node.interfaces[0], call, lambda *_: V("u", 1), None)
        name = "org.freedesktop.impl.portal.desktop.gtk"
    else:
        # Owns the frontend's name and lets every call time out.
        conn.add_filter(lambda c, message, incoming: None if incoming and message.get_destination() == c.get_unique_name() else message)
        name = "org.freedesktop.portal.Desktop"
    Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, None, lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
