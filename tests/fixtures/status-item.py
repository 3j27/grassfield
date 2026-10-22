#!/usr/bin/env python3
"""A test StatusNotifierItem with a DBusMenu, for the tray host tests (tests/shell/tray_host.sh).

Runs on the bus named by DBUS_SESSION_BUS_ADDRESS, which the tests set to a PRIVATE dbus-daemon: this script refuses to
start on anything else than a /tmp/dbus-* or a tests socket. It registers itself with the StatusNotifierWatcher when one
appears, serves the SNI properties and the dbusmenu interface and appends one line per method call to --log:

    activate x y | secondary x y | contextmenu x y | scroll delta orientation | event id type | abouttoshow id

Menu: 1 "Open", 2 separator, 3 "Mute" (checkbox, checked), 4 "More" (submenu with 5 "Sub A"), 6 "Disabled" (disabled).
"""
import argparse
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

SNI_XML = """
<node>
 <interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="WindowId" type="u" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="OverlayIconName" type="s" access="read"/>
  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionIconName" type="s" access="read"/>
  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionMovieName" type="s" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="ContextMenu"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
  <method name="Activate"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
  <method name="Scroll"><arg type="i" name="delta" direction="in"/><arg type="s" name="orientation" direction="in"/></method>
  <signal name="NewTitle"/><signal name="NewIcon"/><signal name="NewAttentionIcon"/><signal name="NewOverlayIcon"/>
  <signal name="NewToolTip"/><signal name="NewStatus"><arg type="s" name="status"/></signal>
 </interface>
</node>
"""

MENU_XML = """
<node>
 <interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout">
   <arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/>
   <arg type="as" name="propertyNames" direction="in"/>
   <arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/>
  </method>
  <method name="GetGroupProperties">
   <arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/>
   <arg type="a(ia{sv})" name="properties" direction="out"/>
  </method>
  <method name="GetProperty">
   <arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/><arg type="v" name="value" direction="out"/>
  </method>
  <method name="Event">
   <arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/>
   <arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/>
  </method>
  <method name="EventGroup">
   <arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/>
  </method>
  <method name="AboutToShow"><arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/></method>
  <method name="AboutToShowGroup">
   <arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/><arg type="ai" name="idErrors" direction="out"/>
  </method>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})" name="updatedProps"/><arg type="a(ias)" name="removedProps"/></signal>
  <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
  <signal name="ItemActivationRequested"><arg type="i" name="id"/><arg type="u" name="timestamp"/></signal>
 </interface>
</node>
"""

# id -> (properties, children ids)
MENU = {
    0: ({"children-display": GLib.Variant("s", "submenu")}, [1, 2, 3, 4, 6]),
    1: ({"label": GLib.Variant("s", "Open")}, []),
    2: ({"type": GLib.Variant("s", "separator")}, []),
    3: ({"label": GLib.Variant("s", "Mute"), "toggle-type": GLib.Variant("s", "checkmark"), "toggle-state": GLib.Variant("i", 1)}, []),
    4: ({"label": GLib.Variant("s", "More"), "children-display": GLib.Variant("s", "submenu")}, [5]),
    5: ({"label": GLib.Variant("s", "Sub A")}, []),
    6: ({"label": GLib.Variant("s", "Disabled"), "enabled": GLib.Variant("b", False)}, []),
}


def layout(node_id, depth):
    props, kids = MENU[node_id]
    children = []
    if depth != 0:
        children = [GLib.Variant("(ia{sv}av)", layout(k, depth - 1)) for k in kids]
    return (node_id, props, children)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", default="gf-test-item")
    ap.add_argument("--title", default="Test item")
    ap.add_argument("--icon", default="folder")
    ap.add_argument("--status", default="Active")
    ap.add_argument("--only-menu", action="store_true", help="ItemIsMenu: the primary click is the menu")
    ap.add_argument("--no-menu", action="store_true")
    ap.add_argument("--log", required=True)
    ap.add_argument("--ready", help="file created once the item registered")
    ap.add_argument("--set-status-file", help="the file named here, when it appears, holds the new status (polled)")
    args = ap.parse_args()

    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    # The owner's bus is unix:path=/run/user/UID/bus: a private dbus-daemon listens in the temp directory.
    if not addr.startswith("unix:") or "/run/user/" in addr or os.environ.get("GF_TEST_BUS") != "1":
        sys.exit("status-item: refusing to run on %r: only a private test bus (GF_TEST_BUS=1)" % addr)

    state = {"status": args.status}

    def log(line):
        with open(args.log, "a") as f:
            f.write(line + "\n")

    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    service = "org.kde.StatusNotifierItem-%d-1" % os.getpid()

    def sni_props(name):
        table = {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", args.id),
            "Title": GLib.Variant("s", args.title),
            "Status": GLib.Variant("s", state["status"]),
            "WindowId": GLib.Variant("u", 0),
            "IconName": GLib.Variant("s", args.icon),
            "IconPixmap": GLib.Variant("a(iiay)", []),
            "OverlayIconName": GLib.Variant("s", ""),
            "OverlayIconPixmap": GLib.Variant("a(iiay)", []),
            "AttentionIconName": GLib.Variant("s", args.icon),
            "AttentionIconPixmap": GLib.Variant("a(iiay)", []),
            "AttentionMovieName": GLib.Variant("s", ""),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], args.title, "tooltip of " + args.title)),
            "ItemIsMenu": GLib.Variant("b", args.only_menu),
            "Menu": GLib.Variant("o", "/NO_DBUSMENU" if args.no_menu else "/MenuBar"),
        }
        return table.get(name)

    def sni_call(_c, _sender, _path, _iface, method, params, invocation):
        if method == "Scroll":
            log("scroll %d %s" % tuple(params.unpack()))
        else:
            log("%s %d %d" % (method.lower(), *params.unpack()))
        invocation.return_value(None)

    def menu_props(name):
        return {
            "Version": GLib.Variant("u", 3),
            "TextDirection": GLib.Variant("s", "ltr"),
            "Status": GLib.Variant("s", "normal"),
            "IconThemePath": GLib.Variant("as", []),
        }.get(name)

    def menu_call(_c, _sender, _path, _iface, method, params, invocation):
        if method == "GetLayout":
            parent, depth, _names = params.unpack()
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (1, layout(parent, depth))))
        elif method == "GetGroupProperties":
            ids, _names = params.unpack()
            out = [(i, MENU[i][0]) for i in (ids or MENU) if i in MENU]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (out,)))
        elif method == "GetProperty":
            node_id, name = params.unpack()
            invocation.return_value(GLib.Variant("(v)", (MENU[node_id][0].get(name, GLib.Variant("s", "")),)))
        elif method == "Event":
            node_id, event, _data, _ts = params.unpack()
            log("event %d %s" % (node_id, event))
            invocation.return_value(None)
        elif method == "EventGroup":
            invocation.return_value(GLib.Variant("(ai)", ([],)))
        elif method == "AboutToShow":
            log("abouttoshow %d" % params.unpack()[0])
            invocation.return_value(GLib.Variant("(b)", (False,)))
        elif method == "AboutToShowGroup":
            invocation.return_value(GLib.Variant("(aiai)", ([], [])))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    sni = Gio.DBusNodeInfo.new_for_xml(SNI_XML).interfaces[0]
    menu = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
    conn.register_object("/StatusNotifierItem", sni, sni_call, lambda c, s, p, i, n: sni_props(n), None)
    if not args.no_menu:
        conn.register_object("/MenuBar", menu, menu_call, lambda c, s, p, i, n: menu_props(n), None)

    loop = GLib.MainLoop()
    registered = {"done": False}

    def register(*_):
        if registered["done"]:
            return
        registered["done"] = True
        conn.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                       "RegisterStatusNotifierItem", GLib.Variant("(s)", (service,)), None, Gio.DBusCallFlags.NONE, 5000, None)
        log("registered " + service)
        if args.ready:
            open(args.ready, "w").close()

    def unregister(*_):
        registered["done"] = False

    Gio.bus_own_name_on_connection(conn, service, Gio.BusNameOwnerFlags.NONE, None, None)
    Gio.bus_watch_name_on_connection(conn, "org.kde.StatusNotifierWatcher", Gio.BusNameWatcherFlags.NONE, register, unregister)

    def poll():
        if args.set_status_file and os.path.exists(args.set_status_file):
            with open(args.set_status_file) as f:
                new = f.read().strip()
            os.unlink(args.set_status_file)
            if new:
                state["status"] = new
                conn.emit_signal(None, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewStatus", GLib.Variant("(s)", (new,)))
        return True

    GLib.timeout_add(100, poll)
    loop.run()


if __name__ == "__main__":
    main()
