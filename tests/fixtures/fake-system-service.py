#!/usr/bin/env python3
"""A fake NetworkManager, BlueZ or the General pane's services for the Settings D-Bus tests (tests/integration/settings_dbus.sh,
GF-049, ADR-0026).

    fake-system-service.py nm|bluez|general --log FILE --ready FILE [--fail 'Member=org.x.Error|message'] [--slow Member=SECONDS]

It owns org.freedesktop.NetworkManager (or org.bluez; or hostname1, timedate1, timesync1, locale1 and a systemd user manager) on
the bus named by DBUS_SYSTEM_BUS_ADDRESS, which the test sets to a
PRIVATE dbus-daemon. It REFUSES to start on anything else: GF_TEST_BUS=1 must be set, GF_TEST_BUS_DIR must name the test's
scratch directory, and every entry of the address must be a unix socket under that directory or loopback tcp (parsed, not
matched: percent-escapes, dots and lists do not get past it; never a real system bus). It serves a small, fixed world (see below), keeps the state its methods change (the radio, the
connection state, Powered, Connected) and appends one JSON line per call that reaches it to --log, so the test can say exactly
what the Settings app sent. With --fail, the named method answers with that D-Bus error instead; with --slow it answers after that many seconds.

The NetworkManager world: radio on; an Ethernet device and a Wi-Fi device wlan0 (connected, active AP 1); access points
"Home" (secured, strong, active), "Home" (secured, weak), "Cafe" (open), a saved Wi-Fi profile for "Home" and an Ethernet one.
The BlueZ world: adapter hci0 powered; paired Headphones (connected), paired Mouse, an unpaired device.
The General world (one process, five names): hostname1 (the reference machine, a laptop), timedate1 (Europe/Paris, NTP on, a fixed
time; ListTimezones), timesync1 (a server and the fallback list), locale1 (LANG=en_US.UTF-8), systemd1 (the user manager: one of
the user's own services under GF_TEST_BUS_DIR/units, one a package ships; Enable/DisableUnitFiles, Reload). The Set* methods of
hostname1 and timedate1 keep what they were given, so a read afterwards shows it.
"""
import argparse
import json
import os
import sys
import time
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

V = GLib.Variant
NM = "/org/freedesktop/NetworkManager"


def is_private_test_bus(addr, directory):
    """Every ';' entry is unix:path=<socket under directory> (percent-escapes decoded, dots resolved) or tcp on loopback."""
    if not addr or not directory:
        return False
    root = os.path.normpath(directory)
    entries = [e for e in addr.split(";") if e]
    if not entries:
        return False
    for entry in entries:
        transport, sep, rest = entry.partition(":")
        if not sep:
            return False
        kv = {}
        for pair in [p for p in rest.split(",") if p]:
            key, eq, value = pair.partition("=")
            if not eq or not key:
                return False
            kv[key] = urllib.parse.unquote(value)
        if transport == "unix":
            path = kv.get("path", "")
            if set(kv) - {"path", "guid"} or not path.startswith("/") or not os.path.normpath(path).startswith(root + "/"):
                return False
        elif transport == "tcp":
            if set(kv) - {"host", "port", "family", "guid"} or kv.get("host") not in ("127.0.0.1", "localhost", "::1"):
                return False
        else:
            return False
    return True


def refuse_unless_private_bus():
    addr = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
    if os.environ.get("GF_TEST_BUS") != "1" or not is_private_test_bus(addr, os.environ.get("GF_TEST_BUS_DIR", "")):
        sys.exit("fake-system-service: refusing to run on %r: only a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR, DBUS_SYSTEM_BUS_ADDRESS)" % addr)
    return addr


def xml(text):
    return Gio.DBusNodeInfo.new_for_xml("<node>%s</node>" % text).interfaces[0]


class Service:
    def __init__(self, conn, log_path, fail, slow):
        self.conn = conn
        self.slow = slow  # {member: seconds}
        self.log_path = log_path
        self.fail = fail  # {member: (error name, message)}
        self.props = {}  # (path, iface) -> {name: GLib.Variant}
        self.setters = {}

    def log(self, **entry):
        with open(self.log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def register(self, path, iface_xml, methods=None, props=None, writable=()):
        info = xml(iface_xml)
        iface = info.name
        self.props[(path, iface)] = dict(props or {})
        methods = methods or {}

        def call(conn, sender, obj_path, interface, member, params, invocation):
            self.log(path=obj_path, iface=interface, member=member, args=params.print_(True))
            if member in self.slow:
                time.sleep(self.slow[member])
            if member in self.fail:
                invocation.return_dbus_error(*self.fail[member])
                return
            handler = methods.get(member)
            if handler is None:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", member)
                return
            try:
                invocation.return_value(handler(params))
            except GLib.Error as exc:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", exc.message)

        def get(conn, sender, obj_path, interface, name):
            return self.props[(path, iface)].get(name)

        def set_(conn, sender, obj_path, interface, name, value):
            self.log(path=obj_path, iface=interface, member="Set", args="%s %s" % (name, value.print_(True)))
            if "Set" in self.fail:
                return False
            self.props[(path, iface)][name] = value
            return True

        self.conn.register_object(path, info, call, get, set_ if writable else None)


def nm_world(svc):
    wifi_dev = NM + "/Devices/2"
    aps = {
        NM + "/AccessPoint/1": (b"Home", 71, 1, 0, 0x188),
        NM + "/AccessPoint/2": (b"Home", 40, 1, 0, 0x188),
        NM + "/AccessPoint/3": (b"Cafe", 55, 0, 0, 0),
    }

    def prop(path, iface, name):
        return svc.props[(path, iface)][name]

    def setprop(path, iface, name, value):
        svc.props[(path, iface)][name] = value

    svc.register(NM, '<interface name="org.freedesktop.NetworkManager">'
                     '<property name="WirelessEnabled" type="b" access="readwrite"/>'
                     '<method name="GetDevices"><arg direction="out" type="ao"/></method>'
                     '<method name="ActivateConnection"><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="out" type="o"/></method>'
                     '<method name="AddAndActivateConnection"><arg direction="in" type="a{sa{sv}}"/><arg direction="in" type="o"/><arg direction="in" type="o"/>'
                     '<arg direction="out" type="o"/><arg direction="out" type="o"/></method></interface>',
                 methods={
                     "GetDevices": lambda p: V("(ao)", ([NM + "/Devices/1", wifi_dev],)),
                     "ActivateConnection": lambda p: (setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 100)), V("(o)", (NM + "/ActiveConnection/1",)))[1],
                     "AddAndActivateConnection": lambda p: (setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 100)),
                                                            V("(oo)", (NM + "/Settings/9", NM + "/ActiveConnection/2")))[1],
                 },
                 props={"WirelessEnabled": V("b", True)}, writable=("WirelessEnabled",))
    device_xml = ('<interface name="org.freedesktop.NetworkManager.Device"><property name="DeviceType" type="u" access="read"/>'
                  '<property name="Interface" type="s" access="read"/><property name="State" type="u" access="read"/>'
                  '<method name="Disconnect"/></interface>')
    svc.register(NM + "/Devices/1", device_xml, methods={"Disconnect": lambda p: None},
                 props={"DeviceType": V("u", 1), "Interface": V("s", "eth0"), "State": V("u", 100)})
    svc.register(wifi_dev, device_xml,
                 methods={"Disconnect": lambda p: (setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 30)),
                                                   setprop(wifi_dev, "org.freedesktop.NetworkManager.Device.Wireless", "ActiveAccessPoint", V("o", "/")), None)[2]},
                 props={"DeviceType": V("u", 2), "Interface": V("s", "wlan0"), "State": V("u", 100)})
    svc.register(wifi_dev, '<interface name="org.freedesktop.NetworkManager.Device.Wireless">'
                           '<property name="ActiveAccessPoint" type="o" access="read"/>'
                           '<method name="GetAllAccessPoints"><arg direction="out" type="ao"/></method>'
                           '<method name="RequestScan"><arg direction="in" type="a{sv}"/></method></interface>',
                 methods={"GetAllAccessPoints": lambda p: V("(ao)", (sorted(aps),)), "RequestScan": lambda p: None},
                 props={"ActiveAccessPoint": V("o", NM + "/AccessPoint/1")})
    for path, (ssid, strength, flags, wpa, rsn) in aps.items():
        svc.register(path, '<interface name="org.freedesktop.NetworkManager.AccessPoint"><property name="Ssid" type="ay" access="read"/>'
                           '<property name="Strength" type="y" access="read"/><property name="Flags" type="u" access="read"/>'
                           '<property name="WpaFlags" type="u" access="read"/><property name="RsnFlags" type="u" access="read"/></interface>',
                     props={"Ssid": V("ay", ssid), "Strength": V("y", strength), "Flags": V("u", flags), "WpaFlags": V("u", wpa), "RsnFlags": V("u", rsn)})
    svc.register(NM + "/Settings", '<interface name="org.freedesktop.NetworkManager.Settings"><method name="ListConnections"><arg direction="out" type="ao"/></method></interface>',
                 methods={"ListConnections": lambda p: V("(ao)", ([NM + "/Settings/1", NM + "/Settings/2"],))})
    conn_xml = '<interface name="org.freedesktop.NetworkManager.Settings.Connection"><method name="GetSettings"><arg direction="out" type="a{sa{sv}}"/></method></interface>'
    svc.register(NM + "/Settings/1", conn_xml, methods={"GetSettings": lambda p: V("(a{sa{sv}})", ({
        "connection": {"type": V("s", "802-11-wireless"), "uuid": V("s", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"), "id": V("s", "Maison")},
        "802-11-wireless": {"ssid": V("ay", b"Home")}},))})
    svc.register(NM + "/Settings/2", conn_xml, methods={"GetSettings": lambda p: V("(a{sa{sv}})", ({
        "connection": {"type": V("s", "802-3-ethernet"), "uuid": V("s", "11111111-2222-3333-4444-555555555555"), "id": V("s", "Wired")}},))})
    return "org.freedesktop.NetworkManager"


def bluez_world(svc):
    adapter = "/org/bluez/hci0"
    devices = {
        adapter + "/dev_AA_BB_CC_DD_EE_FF": ("AA:BB:CC:DD:EE:FF", "Headphones", "WH-1000", True, True),
        adapter + "/dev_11_22_33_44_55_66": ("11:22:33:44:55:66", None, "Mouse", True, False),
        adapter + "/dev_66_66_66_66_66_66": ("66:66:66:66:66:66", None, "Seen only", False, False),
    }

    def device_props(address, alias, name, paired, connected):
        p = {"Address": V("s", address), "Name": V("s", name), "Paired": V("b", paired), "Connected": V("b", connected), "Adapter": V("o", adapter)}
        if alias:
            p["Alias"] = V("s", alias)
        return p

    adapter_xml = '<interface name="org.bluez.Adapter1"><property name="Address" type="s" access="read"/><property name="Powered" type="b" access="readwrite"/></interface>'
    svc.register(adapter, adapter_xml, props={"Address": V("s", "00:11:22:33:44:55"), "Powered": V("b", True)}, writable=("Powered",))
    dev_xml = ('<interface name="org.bluez.Device1"><property name="Address" type="s" access="read"/><property name="Alias" type="s" access="read"/>'
               '<property name="Name" type="s" access="read"/><property name="Paired" type="b" access="read"/><property name="Connected" type="b" access="read"/>'
               '<property name="Adapter" type="o" access="read"/><method name="Connect"/><method name="Disconnect"/></interface>')
    for path, spec in devices.items():
        props = device_props(*spec)

        def make(path=path):
            def setc(value):
                svc.props[(path, "org.bluez.Device1")]["Connected"] = V("b", value)

            return {"Connect": lambda p: setc(True), "Disconnect": lambda p: setc(False)}

        svc.register(path, dev_xml, methods=make(), props=props)

    def managed(_):
        objects = {adapter: {"org.bluez.Adapter1": dict(svc.props[(adapter, "org.bluez.Adapter1")])}}
        for path in devices:
            objects[path] = {"org.bluez.Device1": dict(svc.props[(path, "org.bluez.Device1")])}
        return V("(a{oa{sa{sv}}})", (objects,))

    svc.register("/", '<interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg direction="out" type="a{oa{sa{sv}}}"/></method></interface>',
                 methods={"GetManagedObjects": managed})
    return "org.bluez"


def general_world(svc):
    directory = os.environ["GF_TEST_BUS_DIR"]
    host, time_, sync, locale, systemd = ("/org/freedesktop/hostname1", "/org/freedesktop/timedate1", "/org/freedesktop/timesync1",
                                          "/org/freedesktop/locale1", "/org/freedesktop/systemd1")

    def setp(path, iface, name, value):
        svc.props[(path, iface)][name] = value

    hi = "org.freedesktop.hostname1"
    svc.register(host, '<interface name="org.freedesktop.hostname1">'
                       '<property name="PrettyHostname" type="s" access="read"/><property name="StaticHostname" type="s" access="read"/>'
                       '<property name="Hostname" type="s" access="read"/><property name="Chassis" type="s" access="read"/>'
                       '<property name="HardwareVendor" type="s" access="read"/><property name="HardwareModel" type="s" access="read"/>'
                       '<method name="SetPrettyHostname"><arg direction="in" type="s"/><arg direction="in" type="b"/></method>'
                       '<method name="SetStaticHostname"><arg direction="in" type="s"/><arg direction="in" type="b"/></method></interface>',
                 methods={"SetPrettyHostname": lambda p: setp(host, hi, "PrettyHostname", V("s", p[0])),
                          "SetStaticHostname": lambda p: setp(host, hi, "StaticHostname", V("s", p[0]))},
                 props={"PrettyHostname": V("s", "Grassfield Reference"), "StaticHostname": V("s", "grassfield-reference"),
                        "Hostname": V("s", "grassfield-reference"), "Chassis": V("s", "laptop"), "HardwareVendor": V("s", "Grassfield"),
                        "HardwareModel": V("s", "Reference Laptop 14")})
    ti = "org.freedesktop.timedate1"
    svc.register(time_, '<interface name="org.freedesktop.timedate1">'
                        '<property name="Timezone" type="s" access="read"/><property name="NTP" type="b" access="read"/>'
                        '<property name="CanNTP" type="b" access="read"/><property name="NTPSynchronized" type="b" access="read"/>'
                        '<property name="LocalRTC" type="b" access="read"/><property name="TimeUSec" type="t" access="read"/>'
                        '<method name="SetNTP"><arg direction="in" type="b"/><arg direction="in" type="b"/></method>'
                        '<method name="SetTimezone"><arg direction="in" type="s"/><arg direction="in" type="b"/></method>'
                        '<method name="SetTime"><arg direction="in" type="x"/><arg direction="in" type="b"/><arg direction="in" type="b"/></method>'
                        '<method name="ListTimezones"><arg direction="out" type="as"/></method></interface>',
                 methods={"SetNTP": lambda p: setp(time_, ti, "NTP", V("b", p[0])),
                          "SetTimezone": lambda p: setp(time_, ti, "Timezone", V("s", p[0])),
                          "SetTime": lambda p: setp(time_, ti, "TimeUSec", V("t", p[0])),
                          "ListTimezones": lambda p: V("(as)", (["Europe/Paris", "Europe/Zurich", "America/New_York", "UTC", "../etc/passwd"],))},
                 props={"Timezone": V("s", "Europe/Paris"), "NTP": V("b", True), "CanNTP": V("b", True), "NTPSynchronized": V("b", True),
                        "LocalRTC": V("b", False), "TimeUSec": V("t", 1792832460000000)})
    svc.register(sync, '<interface name="org.freedesktop.timesync1.Manager">'
                       '<property name="ServerName" type="s" access="read"/><property name="LinkNTPServers" type="as" access="read"/>'
                       '<property name="SystemNTPServers" type="as" access="read"/><property name="FallbackNTPServers" type="as" access="read"/></interface>',
                 props={"ServerName": V("s", "2.arch.pool.ntp.org"), "LinkNTPServers": V("as", []), "SystemNTPServers": V("as", []),
                        "FallbackNTPServers": V("as", ["0.arch.pool.ntp.org", "1.arch.pool.ntp.org", "2.arch.pool.ntp.org"])})
    svc.register(locale, '<interface name="org.freedesktop.locale1"><property name="Locale" type="as" access="read"/></interface>',
                 props={"Locale": V("as", ["LANG=en_US.UTF-8"])})
    units = {directory + "/units/sync.service": "enabled", directory + "/units/backup.service": "disabled",
             "/usr/lib/systemd/user/shipped.service": "enabled"}

    def enable(names, on):
        for path in list(units):
            if path.rsplit("/", 1)[-1] in names:
                units[path] = "enabled" if on else "disabled"

    svc.register(systemd, '<interface name="org.freedesktop.systemd1.Manager">'
                          '<method name="ListUnitFilesByPatterns"><arg direction="in" type="as"/><arg direction="in" type="as"/><arg direction="out" type="a(ss)"/></method>'
                          '<method name="EnableUnitFiles"><arg direction="in" type="as"/><arg direction="in" type="b"/><arg direction="in" type="b"/>'
                          '<arg direction="out" type="b"/><arg direction="out" type="a(sss)"/></method>'
                          '<method name="DisableUnitFiles"><arg direction="in" type="as"/><arg direction="in" type="b"/><arg direction="out" type="a(sss)"/></method>'
                          '<method name="Reload"/></interface>',
                 methods={"ListUnitFilesByPatterns": lambda p: V("(a(ss))", (sorted(units.items()),)),
                          "EnableUnitFiles": lambda p: (enable(p[0], True), V("(ba(sss))", (False, [])))[1],
                          "DisableUnitFiles": lambda p: (enable(p[0], False), V("(a(sss))", ([],)))[1],
                          "Reload": lambda p: None})
    return ["org.freedesktop.hostname1", "org.freedesktop.timedate1", "org.freedesktop.timesync1", "org.freedesktop.locale1",
            "org.freedesktop.systemd1"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service", choices=["nm", "bluez", "general"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--fail", action="append", default=[])
    ap.add_argument("--slow", action="append", default=[])
    args = ap.parse_args()
    addr = refuse_unless_private_bus()
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    fail = {}
    for spec in args.fail:
        member, _, rest = spec.partition("=")
        name, _, message = rest.partition("|")
        fail[member] = (name, message)
    slow = {spec.partition("=")[0]: float(spec.partition("=")[2]) for spec in args.slow}
    svc = Service(conn, args.log, fail, slow)
    worlds = {"nm": nm_world, "bluez": bluez_world, "general": general_world}
    names = worlds[args.service](svc)
    names = names if isinstance(names, list) else [names]
    owned = set()

    def acquired(c, n):
        owned.add(n)
        if len(owned) == len(names):
            with open(args.ready, "w") as f:
                f.write("ready\n")

    for name in names:
        Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.NONE, acquired, None)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
