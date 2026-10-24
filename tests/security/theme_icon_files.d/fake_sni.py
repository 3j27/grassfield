# A StatusNotifierItem for tests/security/theme_icon_files.sh, part 5 (review of 423766f): argv is <number> <title>
# <IconName> <IconThemePath>. It registers with the watcher once one appears on the bus and quits after 40 s.
# Run ONLY on the private bus the test starts: it refuses any bus address outside the directory named by
# GF_PRIVATE_BUS_DIR, and the test runs it under `env -i` with that address alone.
import os
import sys

address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
bus_dir = os.environ.get("GF_PRIVATE_BUS_DIR", "")
if not bus_dir.startswith("/") or not address.startswith("unix:path=" + bus_dir.rstrip("/") + "/"):
    print("fake-sni: refusing a bus outside the test's private directory: " + address, flush=True)
    sys.exit(3)

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

number, title, icon_name, theme_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
service = "org.kde.StatusNotifierItem-%d-%s" % (os.getpid(), number)
XML = """<node><interface name='org.kde.StatusNotifierItem'>
<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>
<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>
<property name='IconName' type='s' access='read'/><property name='IconThemePath' type='s' access='read'/>
<property name='IconPixmap' type='a(iiay)' access='read'/><property name='OverlayIconName' type='s' access='read'/>
<property name='AttentionIconName' type='s' access='read'/><property name='ItemIsMenu' type='b' access='read'/>
<property name='Menu' type='o' access='read'/>
<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
</interface></node>"""
props = {"Category": GLib.Variant("s", "ApplicationStatus"), "Id": GLib.Variant("s", "probe-" + number),
         "Title": GLib.Variant("s", title), "Status": GLib.Variant("s", "Active"), "IconName": GLib.Variant("s", icon_name),
         "IconThemePath": GLib.Variant("s", theme_path), "IconPixmap": GLib.Variant("a(iiay)", []),
         "OverlayIconName": GLib.Variant("s", ""), "AttentionIconName": GLib.Variant("s", ""),
         "ItemIsMenu": GLib.Variant("b", False), "Menu": GLib.Variant("o", "/NO_DBUSMENU")}
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
node = Gio.DBusNodeInfo.new_for_xml(XML)


def get_prop(conn, sender, path, iface, name):
    return props.get(name)


def call(conn, sender, path, iface, method, params, invocation):
    invocation.return_value(None)


def appeared(conn, name, owner):
    try:
        conn.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                       "RegisterStatusNotifierItem", GLib.Variant("(s)", (service,)), None, 0, 2000, None)
        print("fake-sni: registered " + title, flush=True)
    except GLib.Error as e:
        print("fake-sni: register failed: " + str(e), flush=True)


bus.register_object("/StatusNotifierItem", node.interfaces[0], call, get_prop, None)
Gio.bus_own_name_on_connection(bus, service, Gio.BusNameOwnerFlags.NONE, None, None)
Gio.bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameWatcherFlags.NONE, appeared, None)
loop = GLib.MainLoop()
GLib.timeout_add_seconds(40, loop.quit)
loop.run()
