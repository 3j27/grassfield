# Self-check of the private bus of tests/security/theme_icon_files.sh, part 5 (follow-up of 061f599): two connections,
# one owns a name and answers a method, the other calls it and listens for a signal. dbus-daemon drops every reply and
# signal its policy does not allow to be received (the Hello reply too), so a bus that cannot carry a StatusNotifierItem
# fails here, before the tray part can read as a pass or as a timeout. Prints "bus-check: reply=<ok|...> signal=<ok|...>",
# exits 0 only when both arrive.
# Run ONLY on the test's private bus: it refuses any address but a socket in the directory named by GF_PRIVATE_BUS_DIR,
# or a nonce-tcp bus on 127.0.0.1 whose nonce file lies in that directory (how the policy can be checked where Unix
# sockets cannot be created), and the test runs it under `env -i` with that address alone.
import os
import re
import sys
import threading

address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
bus_dir = os.environ.get("GF_PRIVATE_BUS_DIR", "").rstrip("/")
in_dir = bus_dir.startswith("/") and address.startswith("unix:path=" + bus_dir + "/")
nonce = (bus_dir.startswith("/") and re.match(r"nonce-tcp:host=127\.0\.0\.1,port=[0-9]+,", address) is not None
         and (",noncefile=" + bus_dir + "/") in address)
if not (in_dir or nonce):
    print("bus-check: refusing a bus outside the test's private directory: " + address, flush=True)
    sys.exit(3)
# A bus that drops the Hello reply blocks the connection itself: give up after 10 s.
threading.Timer(10, lambda: (print("bus-check: reply=timeout signal=timeout (no connection)", flush=True), os._exit(1))).start()

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
server = Gio.DBusConnection.new_for_address_sync(address, flags, None, None)
client = Gio.DBusConnection.new_for_address_sync(address, flags, None, None)
node = Gio.DBusNodeInfo.new_for_xml("<node><interface name='org.grassfield.BusCheck'><method name='Ping'>"
                                    "<arg type='s' direction='out'/></method><signal name='Changed'/></interface></node>")
server.register_object("/check", node.interfaces[0],
                       lambda conn, sender, path, iface, method, params, inv: inv.return_value(GLib.Variant("(s)", ("pong",))),
                       None, None)
server.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                 GLib.Variant("(su)", ("org.grassfield.BusCheck", 4)), None, Gio.DBusCallFlags.NONE, 3000, None)
signals = []
signal_loop = GLib.MainLoop()
client.signal_subscribe(None, "org.grassfield.BusCheck", "Changed", "/check", None, Gio.DBusSignalFlags.NONE,
                        lambda *args: (signals.append(1), signal_loop.quit()))
loop = GLib.MainLoop()
result = {"reply": "timeout"}


def answered(conn, res):
    try:
        result["reply"] = "ok" if conn.call_finish(res).unpack() == ("pong",) else "wrong"
    except GLib.Error as e:
        result["reply"] = "error " + e.message
    loop.quit()


client.call("org.grassfield.BusCheck", "/check", "org.grassfield.BusCheck", "Ping", None, None, Gio.DBusCallFlags.NONE,
            3000, None, answered)
GLib.timeout_add(4000, loop.quit)
loop.run()
server.emit_signal(None, "/check", "org.grassfield.BusCheck", "Changed", None)
GLib.timeout_add(3000, signal_loop.quit)
if not signals:
    signal_loop.run()
signal = "ok" if signals else "missing"
print("bus-check: reply=%s signal=%s" % (result["reply"], signal), flush=True)
os._exit(0 if result["reply"] == "ok" and signals else 1)
