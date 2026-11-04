#!/usr/bin/env python3
"""A GTK window with a client-side header bar and the session's title buttons, for the traffic-light checks of the generated
GTK themes (ui/tools/gen-gtk-themes.py; tests/integration/gtk_themes.sh, tests/compositor/gtk_lights.sh): GTK 3's
GtkHeaderBar or GTK 4's, close, minimize and maximize on the left (the session's `close,minimize,maximize:`). It quits after
argv[2] seconds, 0 to stay.

    gtk-headerbar.py 3|4 SECONDS [APP-ID]
"""
import sys

import gi

VERSION = sys.argv[1]
SECONDS = float(sys.argv[2])
APP_ID = sys.argv[3] if len(sys.argv) > 3 else "gtk-headerbar"
gi.require_version("Gtk", VERSION + ".0")
from gi.repository import GLib, Gtk  # noqa: E402

LAYOUT = "close,minimize,maximize:"
TITLE = "gtk-headerbar"


def main():
    GLib.set_prgname(APP_ID)
    loop = GLib.MainLoop()
    window = Gtk.Window(title=TITLE)
    window.set_default_size(420, 220)
    bar = Gtk.HeaderBar()
    bar.set_decoration_layout(LAYOUT)
    if VERSION == "4":
        Gtk.init()
        window.set_titlebar(bar)
        window.set_child(Gtk.Label(label="Header bar with title buttons"))
        window.connect("close-request", lambda *_: loop.quit())
        window.present()
    else:
        bar.set_show_close_button(True)
        bar.set_title(TITLE)
        window.set_titlebar(bar)
        window.add(Gtk.Label(label="Header bar with title buttons"))
        window.connect("destroy", lambda *_: loop.quit())
        window.show_all()
    print("READY", flush=True)
    if SECONDS > 0:
        GLib.timeout_add(int(SECONDS * 1000), loop.quit)
    loop.run()


main()
