#!/usr/bin/env python3
"""gcr clients and name holders for tests/security/prompter_bridge.sh (ADR-0035 D-9), on a private test bus only.

  password [--title T] [--message M] [--description D] [--warning W] [--choice LABEL] [--new] [--close-when FILE]
      a real gcr-4 client (libgcr's GcrSystemPrompt, the sx-aes-1 exchange included) asks the system prompter for a
      password; prints "password=<what it received>" (and "choice=0|1") or "cancelled". --close-when: closes the prompt
      (StopPrompting) as soon as FILE exists, and prints "closed".
  confirm [--title T] ...          the same for a confirmation: prints "continue" or "cancel"
  many N                           N prompts at once from one process: prints "<i> password=..." or "<i> cancelled"
  forge --caller NAME              speaks gcr's protocol by hand (BeginPrompting, then PerformPrompt with the exchange) and
                                   puts "grassfield-caller": NAME among its own properties, as a caller that tries to pass
                                   for another one; prints "reply=<the prompter's answer>"
  begins N                         BeginPrompting N times on N callback paths from one connection, without performing;
                                   prints "begin <i> ok" or "begin <i> error <D-Bus error name>"
  badperform                       a PerformPrompt of the wrong shape; prints "error <D-Bus error name>: <message>"
  holder --log FILE [--flags N]    requests org.gnome.keyring.SystemPrompter (flags N, default 0: queued behind an owner),
                                   prints "reply=<RequestName's answer>", serves the prompter object and writes every call
                                   it receives to FILE; runs until killed (a stock prompter, or an attacker queued behind
                                   the bridge)
Refuses any bus that is not under GF_TEST_BUS_DIR (the rule of the tests' fakes). Run it with python3 -I.
"""
import argparse
import os
import sys

import gi

gi.require_version("Gcr", "4")
gi.require_version("Gio", "2.0")
from gi.repository import Gcr, Gio, GLib  # noqa: E402

NAME = "org.gnome.keyring.SystemPrompter"
PROMPTER_XML = """<node><interface name="org.gnome.keyring.internal.Prompter">
<method name="BeginPrompting"><arg type="o" direction="in"/></method>
<method name="PerformPrompt"><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="s" direction="in"/></method>
<method name="StopPrompting"><arg type="o" direction="in"/></method>
</interface></node>"""


def private_bus_only():
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    root = os.environ.get("GF_TEST_BUS_DIR", "")
    if not root or not address.startswith("unix:path=" + root + "/"):
        sys.exit("prompter-client: refused: not a private test bus under GF_TEST_BUS_DIR")


def open_prompt(args):
    prompt = Gcr.SystemPrompt.open_for_prompter(NAME, 5, None)
    if args.title:
        prompt.set_title(args.title)
    if args.message:
        prompt.set_message(args.message)
    if args.description:
        prompt.set_description(args.description)
    if args.warning:
        prompt.set_warning(args.warning)
    if args.choice:
        prompt.set_choice_label(args.choice)
    if args.new:
        prompt.set_password_new(True)
    return prompt


def ask(args, kind):
    loop = GLib.MainLoop()
    prompt = open_prompt(args)

    def done(source, result):
        try:
            if kind == "password":
                pw = source.password_finish(result)
                print("cancelled" if pw is None else "password=" + pw, flush=True)
                if pw is not None and args.choice:
                    print("choice=%d" % int(source.get_choice_chosen()), flush=True)
            else:
                reply = source.confirm_finish(result)
                print("continue" if reply == Gcr.PromptReply.CONTINUE else "cancel", flush=True)
        except GLib.Error as e:
            print("cancelled (%s)" % e.message, flush=True)
        loop.quit()

    if kind == "password":
        prompt.password_async(None, done)
    else:
        prompt.confirm_async(None, done)
    if args.close_when:
        def poll():
            if os.path.exists(args.close_when):
                Gcr.SystemPrompt.close_async(prompt, None, lambda s, r: None)
                print("closed", flush=True)
                return False
            return True
        GLib.timeout_add(50, poll)
    GLib.timeout_add_seconds(20, loop.quit)
    loop.run()


def many(n):
    loop = GLib.MainLoop()
    prompts = [Gcr.SystemPrompt.open_for_prompter(NAME, 5, None) for _ in range(n)]
    pending = [n]

    def done(source, result, i):
        try:
            pw = source.password_finish(result)
            print("%d %s" % (i, "cancelled" if pw is None else "password=" + pw), flush=True)
        except GLib.Error as e:
            print("%d cancelled (%s)" % (i, e.message), flush=True)
        pending[0] -= 1
        if pending[0] == 0:
            loop.quit()

    for i, p in enumerate(prompts):
        p.set_title("Request %d" % i)
        p.password_async(None, done, i)
    GLib.timeout_add_seconds(30, loop.quit)
    loop.run()


CALLBACK_XML = """<node><interface name="org.gnome.keyring.internal.Prompter.Callback">
<method name="PromptReady"><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="s" direction="in"/></method>
<method name="PromptDone"/>
</interface></node>"""


def forge(caller):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    loop = GLib.MainLoop()
    path = "/org/gnome/keyring/Prompt/forged"
    exchange = Gcr.SecretExchange.new(None)

    def prompter(method, params, reply_type=None):
        bus.call(NAME, "/org/gnome/keyring/Prompter", "org.gnome.keyring.internal.Prompter", method, params, reply_type,
                 Gio.DBusCallFlags.NONE, 5000, None, None)

    def callback(conn, sender, obj, iface, method, params, invocation):
        invocation.return_value(None)
        if method == "PromptDone":
            loop.quit()
            return
        reply, _props, sent = params.unpack()
        exchange.receive(sent)
        if reply == "":
            props = {"title": GLib.Variant("s", "Forged"), "grassfield-caller": GLib.Variant("s", caller)}
            prompter("PerformPrompt", GLib.Variant("(osa{sv}s)", (path, "password", props, exchange.send(None, 0))))
        else:
            print("reply=" + reply, flush=True)
            prompter("StopPrompting", GLib.Variant("(o)", (path,)))
            loop.quit()

    node = Gio.DBusNodeInfo.new_for_xml(CALLBACK_XML)
    bus.register_object(path, node.interfaces[0], callback, None, None)
    prompter("BeginPrompting", GLib.Variant("(o)", (path,)))
    GLib.timeout_add_seconds(20, loop.quit)
    loop.run()


def prompter_sync(bus, method, params):
    return bus.call_sync(NAME, "/org/gnome/keyring/Prompter", "org.gnome.keyring.internal.Prompter", method, params, None,
                         Gio.DBusCallFlags.NONE, 5000, None)


def begins(n):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    for i in range(n):
        try:
            prompter_sync(bus, "BeginPrompting", GLib.Variant("(o)", ("/org/gnome/keyring/Prompt/held%d" % i,)))
            print("begin %d ok" % i, flush=True)
        except GLib.Error as e:
            print("begin %d error %s" % (i, Gio.DBusError.get_remote_error(e)), flush=True)


def badperform():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    try:
        prompter_sync(bus, "PerformPrompt", GLib.Variant("(s)", ("not gcr's shape",)))
        print("no error", flush=True)
    except GLib.Error as e:
        name = Gio.DBusError.get_remote_error(e)
        text = e.message
        prefix = "GDBus.Error:%s: " % name
        print("error %s: %s" % (name, text[len(prefix):] if text.startswith(prefix) else text), flush=True)


def holder(log_path, flags):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    log = open(log_path, "a", buffering=1)

    def call(conn, sender, path, iface, method, params, invocation):
        log.write("%s %s\n" % (method, sender))
        invocation.return_dbus_error("org.example.Fake", "a holder never prompts")

    node = Gio.DBusNodeInfo.new_for_xml(PROMPTER_XML)
    bus.register_object("/org/gnome/keyring/Prompter", node.interfaces[0], call, None, None)
    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                          GLib.Variant("(su)", (NAME, flags)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
    print("reply=%d" % reply.unpack()[0], flush=True)
    GLib.MainLoop().run()


def main():
    private_bus_only()
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["password", "confirm", "many", "forge", "begins", "badperform", "holder"])
    ap.add_argument("count", nargs="?", type=int, default=0)
    ap.add_argument("--title")
    ap.add_argument("--message")
    ap.add_argument("--description")
    ap.add_argument("--warning")
    ap.add_argument("--choice")
    ap.add_argument("--new", action="store_true")
    ap.add_argument("--close-when")
    ap.add_argument("--log")
    ap.add_argument("--flags", type=int, default=0)
    ap.add_argument("--caller")
    args = ap.parse_args()
    if args.mode in ("password", "confirm"):
        ask(args, args.mode)
    elif args.mode == "many":
        many(args.count)
    elif args.mode == "forge":
        forge(args.caller)
    elif args.mode == "begins":
        begins(args.count)
    elif args.mode == "badperform":
        badperform()
    else:
        holder(args.log, args.flags)


if __name__ == "__main__":
    main()
