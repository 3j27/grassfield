#!/usr/bin/env python3
"""A test MPRIS media player (org.mpris.MediaPlayer2.gftest) for the menu bar's Now Playing tests.

Runs on the bus named by DBUS_SESSION_BUS_ADDRESS, which the tests set to a PRIVATE dbus-daemon: it refuses to start on
anything else (GF_TEST_BUS=1 and no /run/user path). One line per method call is appended to --log (play, pause,
playpause, next, previous, stop). `--control FILE` is polled: a line "status Paused" or "title Some song" changes the
state and emits PropertiesChanged, then the file is removed.
"""
import argparse
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

ROOT_XML = """
<node><interface name="org.mpris.MediaPlayer2">
 <method name="Raise"/><method name="Quit"/>
 <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
 <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
 <property name="DesktopEntry" type="s" access="read"/>
 <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
</interface></node>
"""

PLAYER_XML = """
<node><interface name="org.mpris.MediaPlayer2.Player">
 <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/><method name="Stop"/><method name="Play"/>
 <method name="Seek"><arg type="x" name="Offset" direction="in"/></method>
 <method name="SetPosition"><arg type="o" name="TrackId" direction="in"/><arg type="x" name="Position" direction="in"/></method>
 <method name="OpenUri"><arg type="s" name="Uri" direction="in"/></method>
 <signal name="Seeked"><arg type="x" name="Position"/></signal>
 <property name="PlaybackStatus" type="s" access="read"/><property name="LoopStatus" type="s" access="readwrite"/>
 <property name="Rate" type="d" access="readwrite"/><property name="Shuffle" type="b" access="readwrite"/>
 <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
 <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
 <property name="MaximumRate" type="d" access="read"/><property name="CanGoNext" type="b" access="read"/>
 <property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
 <property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
 <property name="CanControl" type="b" access="read"/>
</interface></node>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="Test Song")
    ap.add_argument("--artist", default="Test Artist")
    ap.add_argument("--art", default="", help="absolute path of the artwork image")
    ap.add_argument("--status", default="Playing")
    ap.add_argument("--log", required=True)
    ap.add_argument("--control", help="polled file with 'status X' or 'title X' lines")
    args = ap.parse_args()

    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if not addr.startswith("unix:") or "/run/user/" in addr or os.environ.get("GF_TEST_BUS") != "1":
        sys.exit("mpris-player: refusing to run on %r: only a private test bus (GF_TEST_BUS=1)" % addr)

    state = {"status": args.status, "title": args.title}

    def log(line):
        with open(args.log, "a") as f:
            f.write(line + "\n")

    def metadata():
        md = {
            "mpris:trackid": GLib.Variant("o", "/org/gftest/track/1"),
            "mpris:length": GLib.Variant("x", 180000000),
            "xesam:title": GLib.Variant("s", state["title"]),
            "xesam:artist": GLib.Variant("as", [args.artist]),
        }
        if args.art:
            md["mpris:artUrl"] = GLib.Variant("s", "file://" + args.art)
        return md if state["title"] else {}

    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def root_props(name):
        return {
            "CanQuit": GLib.Variant("b", False), "CanRaise": GLib.Variant("b", False), "HasTrackList": GLib.Variant("b", False),
            "Identity": GLib.Variant("s", "Grassfield test player"), "DesktopEntry": GLib.Variant("s", ""),
            "SupportedUriSchemes": GLib.Variant("as", []), "SupportedMimeTypes": GLib.Variant("as", []),
        }.get(name)

    def player_props(name):
        return {
            "PlaybackStatus": GLib.Variant("s", state["status"]), "LoopStatus": GLib.Variant("s", "None"),
            "Rate": GLib.Variant("d", 1.0), "Shuffle": GLib.Variant("b", False), "Metadata": GLib.Variant("a{sv}", metadata()),
            "Volume": GLib.Variant("d", 1.0), "Position": GLib.Variant("x", 42000000), "MinimumRate": GLib.Variant("d", 1.0),
            "MaximumRate": GLib.Variant("d", 1.0), "CanGoNext": GLib.Variant("b", True), "CanGoPrevious": GLib.Variant("b", True),
            "CanPlay": GLib.Variant("b", True), "CanPause": GLib.Variant("b", True), "CanSeek": GLib.Variant("b", False),
            "CanControl": GLib.Variant("b", True),
        }.get(name)

    def changed(names):
        props = {n: player_props(n) for n in names}
        conn.emit_signal(None, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                         GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player", props, [])))

    def root_call(_c, _s, _p, _i, method, _params, invocation):
        log(method.lower())
        invocation.return_value(None)

    def player_call(_c, _s, _p, _i, method, params, invocation):
        log(method.lower())
        if method == "PlayPause":
            state["status"] = "Paused" if state["status"] == "Playing" else "Playing"
            changed(["PlaybackStatus"])
        elif method == "Play":
            state["status"] = "Playing"
            changed(["PlaybackStatus"])
        elif method == "Pause":
            state["status"] = "Paused"
            changed(["PlaybackStatus"])
        invocation.return_value(None)

    root_if = Gio.DBusNodeInfo.new_for_xml(ROOT_XML).interfaces[0]
    player_if = Gio.DBusNodeInfo.new_for_xml(PLAYER_XML).interfaces[0]
    conn.register_object("/org/mpris/MediaPlayer2", root_if, root_call, lambda c, s, p, i, n: root_props(n), None)
    conn.register_object("/org/mpris/MediaPlayer2", player_if, player_call, lambda c, s, p, i, n: player_props(n), None)
    Gio.bus_own_name_on_connection(conn, "org.mpris.MediaPlayer2.gftest", Gio.BusNameOwnerFlags.NONE, None, None)
    log("ready")

    def poll():
        if args.control and os.path.exists(args.control):
            with open(args.control) as f:
                lines = f.read().splitlines()
            os.unlink(args.control)
            for line in lines:
                key, _, value = line.partition(" ")
                if key == "status":
                    state["status"] = value
                    changed(["PlaybackStatus"])
                elif key == "title":
                    state["title"] = value
                    changed(["Metadata"])
        return True

    GLib.timeout_add(100, poll)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
