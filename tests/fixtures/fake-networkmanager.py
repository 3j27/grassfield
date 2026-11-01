#!/usr/bin/env python3
"""A fake NetworkManager for tests/security/nm_agent.sh (ADR-0035 D-9, step 9c), on a private "system" bus of the test's own.

  fake-networkmanager.py --log FILE --commands FIFO [--attacker]

Without --attacker it owns org.freedesktop.NetworkManager and serves AgentManager (Register, RegisterWithCapabilities,
Unregister) at /org/freedesktop/NetworkManager/AgentManager, as NetworkManager 1.58 does (one agent per identifier); with
--attacker it owns nothing and calls the agent all the same (a caller that is not NetworkManager). Both read commands from
FIFO (one per line, shell-quoted) and write what happens to FILE, one line each, flushed:
  get TAG SETTING FLAGS [key=value...]   GetSecrets on the registered agent (--attacker: on the agent named by `target`),
                                         for a Wi-Fi connection built from: keymgmt= (default wpa-psk), ssid= (text) or
                                         ssidhex= (bytes), wepidx=, authalg=, eap= (comma-separated), identity=, type=
                                         (default 802-11-wireless), hints= (comma-separated); logs "TAG secrets <json>"
                                         (what NetworkManager keeps: only secret properties of the connection's settings,
                                         as 1.58's validate_secret_flags and libnm's for_each_secret keep them) and, when
                                         the reply held anything else, "TAG dropped <setting.key,...>"; or "TAG error <D-Bus
                                         error name>"
  cancel TAG                             CancelGetSecrets for TAG's connection path and setting; "TAG cancel ok|error <name>"
  save TAG / delete TAG                  SaveSecrets / DeleteSecrets of TAG's connection; "TAG save ok|error <name>"
  target NAME|-                          call the agent named NAME whether it registered or not (always so with --attacker);
                                         "-": the registered one again
  quit                                   leaves the bus
Log lines: "#owned" (the name acquired), "#register <sender> <identifier>", "#unregister <sender> ok|not-registered".
Refuses any bus that is not under GF_TEST_BUS_DIR (the rule of the tests' fakes). Test data only. Run it with python3 -I.
"""
import argparse
import json
import os
import shlex
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "org.freedesktop.NetworkManager"
AGENT_PATH = "/org/freedesktop/NetworkManager/SecretAgent"
AGENT_IFACE = "org.freedesktop.NetworkManager.SecretAgent"
MANAGER_XML = """<node><interface name="org.freedesktop.NetworkManager.AgentManager">
<method name="Register"><arg name="identifier" type="s" direction="in"/></method>
<method name="RegisterWithCapabilities"><arg name="identifier" type="s" direction="in"/><arg name="capabilities" type="u" direction="in"/></method>
<method name="Unregister"/>
</interface></node>"""


# NetworkManager 1.58's secret properties of the settings an agent may answer (libnm NM_SETTING_PARAM_SECRET); a reply's
# other properties, and settings the connection does not have, are dropped (nm-settings-connection.c validate_secret_flags).
SECRETS = {
    "802-11-wireless-security": {"psk", "wep-key0", "wep-key1", "wep-key2", "wep-key3", "leap-password"},
    "802-1x": {"password", "password-raw", "pin", "private-key-password", "phase2-private-key-password", "ca-cert-password",
               "phase2-ca-cert-password", "client-cert-password", "phase2-client-cert-password"},
}


def keep_secrets(reply, connection):
    """(kept, dropped): what NetworkManager keeps of an agent's reply, and the setting.key names it drops."""
    kept, dropped = {}, []
    for setting, props in reply.items():
        if setting not in connection:
            dropped += ["%s.%s" % (setting, k) for k in props]
            continue
        kept[setting] = {}
        for k, v in props.items():
            if k in SECRETS.get(setting, set()):
                kept[setting][k] = v
            else:
                dropped.append("%s.%s" % (setting, k))
    return kept, sorted(dropped)


def unpack(v):
    """GVariant -> JSON-able (bytes as text)."""
    if isinstance(v, GLib.Variant):
        v = v.unpack()
    if isinstance(v, dict):
        return {k: unpack(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [unpack(x) for x in v]
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--commands", required=True)
    ap.add_argument("--attacker", action="store_true")
    args = ap.parse_args()

    address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
    root = os.environ.get("GF_TEST_BUS_DIR", "")
    if not root or not address.startswith("unix:path=" + root + "/"):
        sys.exit("fake-networkmanager: refused: not a private test bus under GF_TEST_BUS_DIR")

    log = open(args.log, "a", buffering=1, encoding="utf-8")
    bus = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    loop = GLib.MainLoop()
    agents = {}  # identifier -> sender
    requests = {}  # tag -> (path, setting)
    target = [None]

    def manager_call(conn, sender, path, iface, method, params, invocation):
        if method in ("Register", "RegisterWithCapabilities"):
            ident = params.unpack()[0]
            if ident in agents:
                invocation.return_dbus_error("org.freedesktop.NetworkManager.AgentManager.PermissionDenied",
                                             "An agent with this ID is already registered for this user.")
                return
            agents[ident] = sender
            log.write("#register %s %s\n" % (sender, ident))
            invocation.return_value(None)
        elif method == "Unregister":
            gone = [k for k, s in agents.items() if s == sender]
            for k in gone:
                del agents[k]
            log.write("#unregister %s %s\n" % (sender, "ok" if gone else "not-registered"))
            if gone:
                invocation.return_value(None)
            else:
                invocation.return_dbus_error("org.freedesktop.NetworkManager.AgentManager.NotRegistered", "Caller is not registered as an Agent")

    if not args.attacker:
        node = Gio.DBusNodeInfo.new_for_xml(MANAGER_XML)
        bus.register_object("/org/freedesktop/NetworkManager/AgentManager", node.interfaces[0], manager_call, None, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
        if reply.unpack()[0] != 1:
            sys.exit("fake-networkmanager: could not own " + NAME)
        log.write("#owned\n")

        def on_agent_gone(conn, sender, path, iface, signal, params):
            name, old, new = params.unpack()
            if new == "":
                for k in [k for k, s in agents.items() if s == name]:
                    del agents[k]
                    log.write("#agent-gone %s\n" % name)
        bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", None,
                             Gio.DBusSignalFlags.NONE, on_agent_gone)

    def agent():
        if args.attacker or target[0]:
            return target[0]
        return agents.get("org.grassfield.prompter")

    def connection(opts):
        settings = {"connection": {"id": GLib.Variant("s", "Test network"), "type": GLib.Variant("s", opts.get("type", "802-11-wireless")),
                                   "uuid": GLib.Variant("s", "0b4c3b1e-0000-4000-8000-000000000001")}}
        if opts.get("type", "802-11-wireless") == "802-11-wireless":
            ssid = bytes.fromhex(opts["ssidhex"]) if "ssidhex" in opts else opts.get("ssid", "Home").encode()
            settings["802-11-wireless"] = {"ssid": GLib.Variant("ay", ssid), "mode": GLib.Variant("s", "infrastructure")}
        sec = {"key-mgmt": GLib.Variant("s", opts.get("keymgmt", "wpa-psk"))}
        if "wepidx" in opts:
            sec["wep-tx-keyidx"] = GLib.Variant("u", int(opts["wepidx"]))
        if "authalg" in opts:
            sec["auth-alg"] = GLib.Variant("s", opts["authalg"])
        settings["802-11-wireless-security"] = sec
        if "eap" in opts:
            x = {"eap": GLib.Variant("as", opts["eap"].split(","))}
            if "identity" in opts:
                x["identity"] = GLib.Variant("s", opts["identity"])
            settings["802-1x"] = x
        return settings

    def call(tag, method, params, reply_type, what, timeout=120000, settings=None):
        name = agent()
        if not name:
            log.write("%s %s no-agent\n" % (tag, what))
            return

        def done(conn, result):
            try:
                v = conn.call_finish(result)
                if what == "secrets":
                    kept, dropped = keep_secrets(unpack(v)[0], settings or {})
                    log.write("%s secrets %s\n" % (tag, json.dumps(kept, sort_keys=True, ensure_ascii=False)))
                    if dropped:
                        log.write("%s dropped %s\n" % (tag, ",".join(dropped)))
                else:
                    log.write("%s %s ok\n" % (tag, what))
            except GLib.Error as e:
                log.write("%s %s\n" % (tag, ("error " if what == "secrets" else what + " error ") + (Gio.DBusError.get_remote_error(e) or e.message)))
        bus.call(name, AGENT_PATH, AGENT_IFACE, method, params, reply_type, Gio.DBusCallFlags.NO_AUTO_START, timeout, None, done)

    def command(line):
        words = shlex.split(line)
        if not words:
            return
        op, rest = words[0], words[1:]
        if op == "get":
            tag, setting, flags = rest[0], rest[1], int(rest[2], 0)
            opts = dict(w.split("=", 1) for w in rest[3:])
            path = "/org/freedesktop/NetworkManager/Settings/%d" % (len(requests) + 1)
            requests[tag] = (path, setting)
            hints = opts["hints"].split(",") if opts.get("hints") else []
            con = connection(opts)
            call(tag, "GetSecrets", GLib.Variant("(a{sa{sv}}osasu)", (con, path, setting, hints, flags)),
                 GLib.VariantType("(a{sa{sv}})"), "secrets", settings=con)
        elif op == "cancel":
            path, setting = requests[rest[0]]
            call(rest[0], "CancelGetSecrets", GLib.Variant("(os)", (path, setting)), None, "cancel", 1500)
        elif op in ("save", "delete"):
            path, _ = requests.get(rest[0], ("/org/freedesktop/NetworkManager/Settings/99", ""))
            call(rest[0], "SaveSecrets" if op == "save" else "DeleteSecrets", GLib.Variant("(a{sa{sv}}o)", (connection({}), path)),
                 None, op, 60000)
        elif op == "target":
            target[0] = None if rest[0] == "-" else rest[0]
        elif op == "quit":
            log.write("#bye\n")
            loop.quit()
            return
        log.write("#sent %s\n" % op)

    fd = os.open(args.commands, os.O_RDWR | os.O_NONBLOCK)
    buf = [b""]

    def readable(source, condition):
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            return True
        buf[0] += data
        while b"\n" in buf[0]:
            line, buf[0] = buf[0].split(b"\n", 1)
            try:
                command(line.decode())
            except Exception as e:  # a test command error is reported, never fatal
                log.write("#command-error %s\n" % e)
        return True

    GLib.io_add_watch(fd, GLib.IO_IN, readable)
    log.write("#ready %s\n" % bus.get_unique_name())
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
