#!/usr/bin/env python3
"""A fake bluetoothd for tests/security/bluez_agent.sh (ADR-0035 D-11, step 10), on a private "system" bus of the test's own.

  fake-bluez.py --log FILE --commands FIFO [--attacker]

Without --attacker it owns org.bluez and serves, as BlueZ 5.87 does (src/agent.c, read as data):
- org.bluez.AgentManager1 at /org/bluez: RegisterAgent(o, s) (one agent per connection: AlreadyExists; a capability of
  the documented list, else InvalidArguments; the first agent becomes the default, later ones queue behind it),
  UnregisterAgent(o) (DoesNotExist unless the sender's own path; no Release follows: agent_disconnect clears the watch
  agent_destroy releases on, agent.c:174-188, 930-945; bluetoothd sends Release only as it stops, the `release` command),
  RequestDefaultAgent(o) (the last agent to ask is the default); an agent whose connection leaves the bus is forgotten.
- org.bluez.Device1 objects at /org/bluez/hci0/dev_<ID> (the `device` command): Alias, Name, Address, Icon, Paired,
  Bonded, Connected through org.freedesktop.DBus.Properties (GetAll, Get) and PropertiesChanged, InterfacesRemoved on "/"
  when one goes (the `remove` command, as bluetoothd's object manager); Pair() asks the caller's agent, else
  the default one (device.c pair_device), the way the next `pairmode` says; CancelPairing() is logged.
With --attacker it owns nothing and calls the agent named by `target` all the same (a caller that is not bluetoothd).
Both read commands from FIFO (one per line, shell-quoted) and write what happens to FILE, one line each, flushed:
  device ID [alias=TEXT] [aliashex=HEX] [name=TEXT] [icon=NAME]   creates or changes /org/bluez/hci0/dev_ID
  pin TAG DEV / passkey TAG DEV / authorize TAG DEV            RequestPinCode / RequestPasskey / RequestAuthorization
  confirm TAG DEV PASSKEY / service TAG DEV UUID               RequestConfirmation / AuthorizeService
  display-pin TAG DEV PIN                                      DisplayPinCode (BlueZ waits for its reply)
  display-passkey DEV PASSKEY ENTERED                          DisplayPasskey (no reply expected, as BlueZ sends it)
  cancel / release                                             Cancel / Release (no reply expected)
    (DEV: a device ID, or a whole object path when it starts with "/"); each call logs "TAG ok [value]" or
    "TAG error <D-Bus error name>"
  paired ID                                                    Paired and Bonded become true (PropertiesChanged)
  connected ID true|false                                      Connected changes (PropertiesChanged)
  remove ID                                                    the device object goes (InterfacesRemoved on "/")
  pairmode MODE [PASSKEY]                                      how the next Pair() goes: confirm, passkey, display-passkey
                                                               (then waits for `paired`), justworks
  target NAME|-                                                call the agent of connection NAME (always so with
                                                               --attacker); "-": the default agent again
  quit                                                         leaves the bus
Log lines: "#owned", "#ready <unique name>", "#register <sender> <path> <capability>", "#default <sender> <path>",
"#unregister <sender> <path>", "#release-sent <sender>" (the `release` command), "#agent-gone <sender>", "#pair <ID> <agent sender|no-agent>
<mode>", "#pair-done <ID> ok|<error>", "#cancelpairing <ID> <sender>".
Refuses any bus that is not under GF_TEST_BUS_DIR (the rule of the tests' fakes). Test data only. Run it with python3 -I.
"""
import argparse
import os
import shlex
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "org.bluez"
AGENT_IFACE = "org.bluez.Agent1"
AGENT_PATH = "/org/grassfield/prompter/BluetoothAgent"
CAPABILITIES = ("", "DisplayOnly", "DisplayYesNo", "KeyboardOnly", "NoInputNoOutput", "KeyboardDisplay")
REQUEST_TIMEOUT = 60000  # agent.c REQUEST_TIMEOUT
MANAGER_XML = """<node><interface name="org.bluez.AgentManager1">
<method name="RegisterAgent"><arg name="agent" type="o" direction="in"/><arg name="capability" type="s" direction="in"/></method>
<method name="UnregisterAgent"><arg name="agent" type="o" direction="in"/></method>
<method name="RequestDefaultAgent"><arg name="agent" type="o" direction="in"/></method>
</interface></node>"""
DEVICE_XML = """<node><interface name="org.bluez.Device1">
<method name="Pair"/>
<method name="CancelPairing"/>
<property name="Address" type="s" access="read"/>
<property name="Name" type="s" access="read"/>
<property name="Alias" type="s" access="read"/>
<property name="Icon" type="s" access="read"/>
<property name="Paired" type="b" access="read"/>
<property name="Bonded" type="b" access="read"/>
<property name="Connected" type="b" access="read"/>
</interface></node>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--commands", required=True)
    ap.add_argument("--attacker", action="store_true")
    args = ap.parse_args()

    address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
    root = os.environ.get("GF_TEST_BUS_DIR", "")
    if not root or not address.startswith("unix:path=" + root + "/"):
        sys.exit("fake-bluez: refused: not a private test bus under GF_TEST_BUS_DIR")

    log = open(args.log, "a", buffering=1, encoding="utf-8")
    bus = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    loop = GLib.MainLoop()
    agents = {}  # sender -> (path, capability)
    defaults = []  # senders, the default agent first
    devices = {}  # ID -> properties (Python values)
    pairing = {"mode": "confirm", "passkey": 123456, "pending": {}}  # pending: ID -> invocation of Pair()
    target = [None]

    def path_of(dev):
        return dev if dev.startswith("/") else "/org/bluez/hci0/dev_" + dev

    # --- AgentManager1 --------------------------------------------------------------------------------------------------
    def no_reply_call(dest, path, method, params):
        msg = Gio.DBusMessage.new_method_call(dest, path, AGENT_IFACE, method)
        if params is not None:
            msg.set_body(params)
        msg.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED)
        bus.send_message(msg, Gio.DBusSendMessageFlags.NONE)

    def forget(sender):
        agents.pop(sender, None)
        if sender in defaults:
            defaults.remove(sender)

    def manager_call(conn, sender, path, iface, method, params, invocation):
        if method == "RegisterAgent":
            agent_path, capability = params.unpack()
            if sender in agents:
                invocation.return_dbus_error("org.bluez.Error.AlreadyExists", "Already Exists")
                return
            if capability not in CAPABILITIES:
                invocation.return_dbus_error("org.bluez.Error.InvalidArguments", "Invalid arguments in method call")
                return
            agents[sender] = (agent_path, capability or "KeyboardDisplay")
            defaults.append(sender)
            log.write("#register %s %s %s\n" % (sender, agent_path, capability))
            invocation.return_value(None)
        elif method in ("UnregisterAgent", "RequestDefaultAgent"):
            agent_path = params.unpack()[0]
            if sender not in agents or agents[sender][0] != agent_path:
                invocation.return_dbus_error("org.bluez.Error.DoesNotExist", "Does Not Exist")
                return
            if method == "RequestDefaultAgent":
                defaults.remove(sender)
                defaults.insert(0, sender)
                log.write("#default %s %s\n" % (sender, agent_path))
            else:
                forget(sender)
                log.write("#unregister %s %s\n" % (sender, agent_path))
            invocation.return_value(None)

    # --- Device1 --------------------------------------------------------------------------------------------------------
    device_node = Gio.DBusNodeInfo.new_for_xml(DEVICE_XML)
    registered = {}

    def get_property(conn, sender, path, iface, prop):
        dev = path.rsplit("dev_", 1)[1]
        p = devices[dev]
        return GLib.Variant("b" if prop in ("Paired", "Bonded", "Connected") else "s", p[prop])

    def changed(dev, props):
        bus.emit_signal(None, path_of(dev), "org.freedesktop.DBus.Properties", "PropertiesChanged",
                        GLib.Variant("(sa{sv}as)", ("org.bluez.Device1", {k: GLib.Variant("b", v) for k, v in props.items()}, [])))

    def agent_for(sender):
        if target[0]:
            return target[0], AGENT_PATH
        if sender in agents:
            return sender, agents[sender][0]
        if defaults:
            return defaults[0], agents[defaults[0]][0]
        return None, None

    def device_call(conn, sender, path, iface, method, params, invocation):
        dev = path.rsplit("dev_", 1)[1]
        if method == "CancelPairing":
            log.write("#cancelpairing %s %s\n" % (dev, sender))
            inv = pairing["pending"].pop(dev, None)
            if inv is None:
                invocation.return_dbus_error("org.bluez.Error.DoesNotExist", "Does Not Exist")
                return
            inv.return_dbus_error("org.bluez.Error.AuthenticationCanceled", "Authentication Canceled")
            log.write("#pair-done %s org.bluez.Error.AuthenticationCanceled\n" % dev)
            invocation.return_value(None)
            return
        # Pair(): the caller's agent, else the default one (device.c:3391-3395, agent.c agent_get).
        dest, agent_path = agent_for(sender)
        mode = pairing["mode"]
        log.write("#pair %s %s %s\n" % (dev, dest or "no-agent", mode))
        if dest is None or mode == "justworks":
            devices[dev]["Paired"] = devices[dev]["Bonded"] = True
            changed(dev, {"Paired": True, "Bonded": True})
            log.write("#pair-done %s ok\n" % dev)
            invocation.return_value(None)
            return
        if mode == "display-passkey":
            pairing["pending"][dev] = invocation
            no_reply_call(dest, agent_path, "DisplayPasskey", GLib.Variant("(ouq)", (path, pairing["passkey"], 0)))
            return

        def done(c, result):
            try:
                c.call_finish(result)
                devices[dev]["Paired"] = devices[dev]["Bonded"] = True
                changed(dev, {"Paired": True, "Bonded": True})
                log.write("#pair-done %s ok\n" % dev)
                invocation.return_value(None)
            except GLib.Error as e:
                log.write("#pair-done %s %s\n" % (dev, Gio.DBusError.get_remote_error(e) or e.message))
                invocation.return_dbus_error("org.bluez.Error.AuthenticationFailed", "Authentication Failed")
        if mode == "passkey":
            bus.call(dest, agent_path, AGENT_IFACE, "RequestPasskey", GLib.Variant("(o)", (path,)), GLib.VariantType("(u)"),
                     Gio.DBusCallFlags.NO_AUTO_START, REQUEST_TIMEOUT, None, done)
        else:
            bus.call(dest, agent_path, AGENT_IFACE, "RequestConfirmation", GLib.Variant("(ou)", (path, pairing["passkey"])), None,
                     Gio.DBusCallFlags.NO_AUTO_START, REQUEST_TIMEOUT, None, done)

    if not args.attacker:
        node = Gio.DBusNodeInfo.new_for_xml(MANAGER_XML)
        bus.register_object("/org/bluez", node.interfaces[0], manager_call, None, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
        if reply.unpack()[0] != 1:
            sys.exit("fake-bluez: could not own " + NAME)
        log.write("#owned\n")

        def on_gone(conn, sender, path, iface, signal, params):
            name, old, new = params.unpack()
            if new == "" and name in agents:
                forget(name)
                log.write("#agent-gone %s\n" % name)
        bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", None,
                             Gio.DBusSignalFlags.NONE, on_gone)

    # --- calls to the agent ----------------------------------------------------------------------------------------------
    def call(tag, method, params, reply_type):
        dest, agent_path = agent_for(None)
        if dest is None:
            log.write("%s no-agent\n" % tag)
            return

        def done(conn, result):
            try:
                v = conn.call_finish(result).unpack()
                log.write("%s ok%s\n" % (tag, "" if not v else " " + str(v[0])))
            except GLib.Error as e:
                log.write("%s error %s\n" % (tag, Gio.DBusError.get_remote_error(e) or e.message))
        bus.call(dest, agent_path, AGENT_IFACE, method, params, reply_type, Gio.DBusCallFlags.NO_AUTO_START, REQUEST_TIMEOUT, None, done)

    def command(line):
        words = shlex.split(line)
        if not words:
            return
        op, rest = words[0], words[1:]
        if op == "device":
            dev = rest[0]
            opts = dict(w.split("=", 1) for w in rest[1:])
            addr = dev.replace("_", ":")
            p = devices.setdefault(dev, {"Address": addr, "Name": "", "Alias": addr.replace(":", "-"), "Icon": "",
                                         "Paired": False, "Bonded": False, "Connected": True})
            if "name" in opts:
                p["Name"] = opts["name"]
            if "alias" in opts:
                p["Alias"] = opts["alias"]
            if "aliashex" in opts:
                p["Alias"] = bytes.fromhex(opts["aliashex"]).decode()
            if "icon" in opts:
                p["Icon"] = opts["icon"]
            if dev not in registered and not args.attacker:
                registered[dev] = bus.register_object(path_of(dev), device_node.interfaces[0], device_call, get_property, None)
        elif op == "pin":
            call(rest[0], "RequestPinCode", GLib.Variant("(o)", (path_of(rest[1]),)), GLib.VariantType("(s)"))
        elif op == "passkey":
            call(rest[0], "RequestPasskey", GLib.Variant("(o)", (path_of(rest[1]),)), GLib.VariantType("(u)"))
        elif op == "authorize":
            call(rest[0], "RequestAuthorization", GLib.Variant("(o)", (path_of(rest[1]),)), None)
        elif op == "confirm":
            call(rest[0], "RequestConfirmation", GLib.Variant("(ou)", (path_of(rest[1]), int(rest[2]))), None)
        elif op == "service":
            call(rest[0], "AuthorizeService", GLib.Variant("(os)", (path_of(rest[1]), rest[2])), None)
        elif op == "display-pin":
            call(rest[0], "DisplayPinCode", GLib.Variant("(os)", (path_of(rest[1]), rest[2])), None)
        elif op == "display-passkey":
            dest, agent_path = agent_for(None)
            if dest:
                no_reply_call(dest, agent_path, "DisplayPasskey", GLib.Variant("(ouq)", (path_of(rest[0]), int(rest[1]), int(rest[2]))))
        elif op in ("cancel", "release"):
            dest, agent_path = agent_for(None)
            if dest:
                no_reply_call(dest, agent_path, "Cancel" if op == "cancel" else "Release", None)
                if op == "release":
                    # A stopping bluetoothd releases its agents and forgets them (btd_agent_cleanup).
                    forget(dest)
                    log.write("#release-sent %s\n" % dest)
        elif op == "paired":
            dev = rest[0]
            devices[dev]["Paired"] = devices[dev]["Bonded"] = True
            changed(dev, {"Paired": True, "Bonded": True})
            inv = pairing["pending"].pop(dev, None)
            if inv is not None:
                log.write("#pair-done %s ok\n" % dev)
                inv.return_value(None)
        elif op == "connected":
            dev = rest[0]
            devices[dev]["Connected"] = rest[1] == "true"
            changed(dev, {"Connected": devices[dev]["Connected"]})
        elif op == "remove":
            dev = rest[0]
            if dev in registered:
                bus.unregister_object(registered.pop(dev))
            devices.pop(dev, None)
            bus.emit_signal(None, "/", "org.freedesktop.DBus.ObjectManager", "InterfacesRemoved",
                            GLib.Variant("(oas)", (path_of(dev), ["org.freedesktop.DBus.Properties", "org.bluez.Device1"])))
        elif op == "pairmode":
            pairing["mode"] = rest[0]
            if len(rest) > 1:
                pairing["passkey"] = int(rest[1])
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
