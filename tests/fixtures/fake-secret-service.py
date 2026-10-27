#!/usr/bin/env python3
"""Fake Secret Service peers for tests/integration/secrets_handover.sh (ADR-0035 D-12, step 2c).

    fake-secret-service.py kwallet|keychain|leftover|notifications --log FILE [--store FILE] [options]

kwallet        owns org.kde.secretservicecompat, as KWallet's ksecretd does: one collection (kdewallet) holding two items a
               libsecret client saved (Chromium's key, an example app) and one entry of KWallet's own API (server, user, type).
               --locked: the collection starts locked; Unlock answers with a prompt. --only-legacy: the legacy entry only.
keychain       owns org.freedesktop.secrets, as gnome-keyring does: a "login" collection with the alias "default", already
               holding the example app's item (same attributes, another value, so an overwrite shows). --locked as above.
               --no-default: no collection yet; CreateCollection answers with a prompt. CreateItem appends what it stored to
               --store (fake values only: this is a test world).
leftover       owns org.freedesktop.secrets and exports /MainApplication's org.qtproject.Qt.QCoreApplication.quit, as a
               ksecretd left over from an earlier session does; it exits on quit, or ignores it with --ignore-quit. It logs
               SIGTERM (method "SIGTERM") before it exits on it.
notifications  owns org.freedesktop.Notifications and logs Notify (application, summary, body).

--answer accept|dismiss decides every prompt (after --delay seconds). Every call is one JSON line in --log: role, method,
object path; never a secret value. It REFUSES to start on anything but a private test bus: GF_TEST_BUS=1, GF_TEST_BUS_DIR
naming the test's scratch directory, and DBUS_SESSION_BUS_ADDRESS made only of a unix socket under it or loopback TCP (the
guard of tests/fixtures/fake-system-service.py).
"""
import argparse
import json
import os
import signal
import sys
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

V = GLib.Variant
ROOT = "/org/freedesktop/secrets"


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


XML = """<node>
<interface name="org.freedesktop.Secret.Service">
  <method name="OpenSession"><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="v" direction="out"/><arg type="o" direction="out"/></method>
  <method name="SearchItems"><arg type="a{ss}" direction="in"/><arg type="ao" direction="out"/><arg type="ao" direction="out"/></method>
  <method name="Unlock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
  <method name="ReadAlias"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="CreateCollection"><arg type="a{sv}" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
  <property name="Collections" type="ao" access="read"/>
</interface>
<interface name="org.freedesktop.Secret.Collection">
  <method name="CreateItem"><arg type="a{sv}" direction="in"/><arg type="(oayays)" direction="in"/><arg type="b" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
  <property name="Items" type="ao" access="read"/>
  <property name="Locked" type="b" access="read"/>
  <property name="Label" type="s" access="read"/>
</interface>
<interface name="org.freedesktop.Secret.Item">
  <method name="GetSecret"><arg type="o" direction="in"/><arg type="(oayays)" direction="out"/></method>
  <property name="Attributes" type="a{ss}" access="read"/>
  <property name="Label" type="s" access="read"/>
  <property name="Locked" type="b" access="read"/>
</interface>
<interface name="org.freedesktop.Secret.Prompt">
  <method name="Prompt"><arg type="s" direction="in"/></method>
  <method name="Dismiss"/>
  <signal name="Completed"><arg type="b"/><arg type="v"/></signal>
</interface>
<interface name="org.freedesktop.Secret.Session">
  <method name="Close"/>
</interface>
<interface name="org.qtproject.Qt.QCoreApplication">
  <method name="quit"/>
</interface>
<interface name="org.freedesktop.Notifications">
  <method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
</interface>
</node>"""
NODE = Gio.DBusNodeInfo.new_for_xml(XML)


def iface(name):
    return NODE.lookup_interface(name)


class World:
    def __init__(self, conn, args, loop):
        self.conn, self.args, self.loop = conn, args, loop
        self.collections = {}  # path -> {"label", "locked", "items": [path]}
        self.items = {}  # path -> {"collection", "label", "attributes", "value", "type"}
        self.aliases = {}
        self.sessions = set()
        self.counter = 0
        self.registered = set()

    def log(self, method, path):
        with open(self.args.log, "a") as f:
            f.write(json.dumps({"role": self.args.role, "method": method, "path": path}) + "\n")

    def fresh(self, kind):
        self.counter += 1
        return "%s/%s/%d" % (ROOT, kind, self.counter)

    def export(self, path, *interfaces):
        for name in interfaces:
            if (path, name) not in self.registered:
                self.conn.register_object(path, iface(name), self.call, self.get, None)
                self.registered.add((path, name))

    def add_collection(self, path, label, locked, alias=None):
        self.collections[path] = {"label": label, "locked": locked, "items": []}
        if alias:
            self.aliases[alias] = path
        self.export(path, "org.freedesktop.Secret.Collection")

    def add_item(self, collection, label, attributes, value):
        path = "%s/%d" % (collection, len(self.collections[collection]["items"]) + 1)
        self.items[path] = {"collection": collection, "label": label, "attributes": dict(attributes), "value": value, "type": "text/plain"}
        self.collections[collection]["items"].append(path)
        self.export(path, "org.freedesktop.Secret.Item")
        return path

    def prompt(self, on_accept):
        path = self.fresh("prompt")
        self.export(path, "org.freedesktop.Secret.Prompt")
        self.prompts = getattr(self, "prompts", {})
        self.prompts[path] = on_accept
        return path

    def complete(self, path):
        accept = self.args.answer == "accept"
        result = self.prompts[path]() if accept else V("s", "")
        self.conn.emit_signal(None, path, "org.freedesktop.Secret.Prompt", "Completed", V("(bv)", (not accept, result)))
        return False

    # --- dispatch -----------------------------------------------------------------------------------------------------
    def get(self, conn, sender, path, interface, prop):
        if interface == "org.freedesktop.Secret.Service" and prop == "Collections":
            return V("ao", list(self.collections))
        if interface == "org.freedesktop.Secret.Collection":
            c = self.collections[path]
            return {"Items": V("ao", c["items"]), "Locked": V("b", c["locked"]), "Label": V("s", c["label"])}[prop]
        if interface == "org.freedesktop.Secret.Item":
            i = self.items[path]
            locked = self.collections[i["collection"]]["locked"]
            return {"Attributes": V("a{ss}", i["attributes"]), "Label": V("s", i["label"]), "Locked": V("b", locked)}[prop]
        return None

    def call(self, conn, sender, path, interface, method, params, invocation):
        self.log(method, path)
        args = params.unpack()
        role = self.args.role
        if interface == "org.qtproject.Qt.QCoreApplication" and method == "quit":
            invocation.return_value(None)
            if not self.args.ignore_quit:
                GLib.timeout_add(100, self.loop.quit)
            return
        if interface == "org.freedesktop.Notifications":
            with open(self.args.log, "a") as f:
                f.write(json.dumps({"role": role, "notify": {"app": args[0], "icon": args[2], "summary": args[3], "body": args[4]}}) + "\n")
            invocation.return_value(V("(u)", (1,)))
            return
        if interface == "org.freedesktop.Secret.Service":
            if method == "OpenSession":
                if args[0] != "plain":
                    return invocation.return_dbus_error("org.freedesktop.DBus.Error.NotSupported", "plain only")
                s = self.fresh("session")
                self.sessions.add(s)
                self.export(s, "org.freedesktop.Secret.Session")
                return invocation.return_value(V("(vo)", (V("s", ""), s)))
            if method == "SearchItems":
                wanted = args[0]
                found = [p for p, i in self.items.items() if all(i["attributes"].get(k) == v for k, v in wanted.items())]
                unlocked = [p for p in found if not self.collections[self.items[p]["collection"]]["locked"]]
                locked = [p for p in found if p not in unlocked]
                return invocation.return_value(V("(aoao)", (unlocked, locked)))
            if method == "Unlock":
                targets = [p for p in args[0] if p in self.collections and self.collections[p]["locked"]]
                if not targets:
                    return invocation.return_value(V("(aoo)", (list(args[0]), "/")))

                def accept():
                    for p in targets:
                        self.collections[p]["locked"] = False
                    return V("ao", targets)

                return invocation.return_value(V("(aoo)", ([], self.prompt(accept))))
            if method == "ReadAlias":
                return invocation.return_value(V("(o)", (self.aliases.get(args[0], "/"),)))
            if method == "CreateCollection":
                path = ROOT + "/collection/login"

                def accept():
                    self.add_collection(path, "Login", False, alias=args[1] or None)
                    return V("o", path)

                return invocation.return_value(V("(oo)", ("/", self.prompt(accept))))
        if interface == "org.freedesktop.Secret.Collection" and method == "CreateItem":
            props, secret, replace = args
            c = self.collections[path]
            if c["locked"]:
                return invocation.return_dbus_error("org.freedesktop.Secret.Error.IsLocked", "locked")
            if secret[0] not in self.sessions:
                return invocation.return_dbus_error("org.freedesktop.Secret.Error.NoSession", "unknown session")
            value = bytes(secret[2]).decode()
            attributes = props.get("org.freedesktop.Secret.Item.Attributes", {})
            item = self.add_item(path, props.get("org.freedesktop.Secret.Item.Label", ""), attributes, value)
            with open(self.args.store, "a") as f:
                f.write(json.dumps({"label": self.items[item]["label"], "attributes": attributes, "value": value, "replace": replace}) + "\n")
            return invocation.return_value(V("(oo)", (item, "/")))
        if interface == "org.freedesktop.Secret.Item" and method == "GetSecret":
            i = self.items[path]
            if self.collections[i["collection"]]["locked"]:
                return invocation.return_dbus_error("org.freedesktop.Secret.Error.IsLocked", "locked")
            if args[0] not in self.sessions:
                return invocation.return_dbus_error("org.freedesktop.Secret.Error.NoSession", "unknown session")
            return invocation.return_value(V("((oayays))", ((args[0], b"", i["value"].encode(), i["type"]),)))
        if interface == "org.freedesktop.Secret.Prompt":
            if method == "Prompt":
                invocation.return_value(None)
                GLib.timeout_add(int(self.args.delay * 1000), self.complete, path)
                return
            invocation.return_value(None)
            return
        if interface == "org.freedesktop.Secret.Session" and method == "Close":
            self.sessions.discard(path)
            return invocation.return_value(None)
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("role", choices=["kwallet", "keychain", "leftover", "notifications"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--store", default=os.devnull)
    ap.add_argument("--locked", action="store_true")
    ap.add_argument("--only-legacy", action="store_true")
    ap.add_argument("--no-default", action="store_true")
    ap.add_argument("--ignore-quit", action="store_true")
    ap.add_argument("--answer", choices=["accept", "dismiss"], default="accept")
    ap.add_argument("--delay", type=float, default=0.2)
    args = ap.parse_args()
    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if os.environ.get("GF_TEST_BUS") != "1" or not is_private_test_bus(addr, os.environ.get("GF_TEST_BUS_DIR", "")):
        sys.exit("fake-secret-service: refusing to run on %r: only a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR)" % addr)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    loop = GLib.MainLoop()
    conn.connect("closed", lambda *_: loop.quit())  # the test's bus went away: never outlive it
    world = World(conn, args, loop)
    name = {"kwallet": "org.kde.secretservicecompat", "keychain": "org.freedesktop.secrets", "leftover": "org.freedesktop.secrets",
            "notifications": "org.freedesktop.Notifications"}[args.role]
    if args.role in ("kwallet", "keychain"):
        world.export(ROOT, "org.freedesktop.Secret.Service")
    if args.role == "kwallet":
        c = ROOT + "/collection/kdewallet"
        world.add_collection(c, "kdewallet", args.locked, alias="default")
        if not args.only_legacy:
            world.add_item(c, "Chromium Safe Storage", {"xdg:schema": "chrome_libsecret_os_crypt_password_v2", "application": "chromium"},
                           "kwallet-chromium-key")
            world.add_item(c, "Example App", {"xdg:schema": "org.example.App", "account": "me"}, "kwallet-example")
        world.add_item(c, "Passwords/smb-share", {"server": "Passwords", "user": "smb-share", "type": "plaintext"}, "kwallet-legacy")
    if args.role == "keychain" and not args.no_default:
        c = ROOT + "/collection/login"
        world.add_collection(c, "Login", args.locked, alias="default")
        world.add_item(c, "Example App", {"xdg:schema": "org.example.App", "account": "me"}, "keychain-example")
    if args.role == "leftover":
        world.export("/MainApplication", "org.qtproject.Qt.QCoreApplication")
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, lambda: (world.log("SIGTERM", "-"), loop.quit(), False)[-1])
    if args.role == "notifications":
        world.export("/org/freedesktop/Notifications", "org.freedesktop.Notifications")
    Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, None, lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
