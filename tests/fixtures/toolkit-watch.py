#!/usr/bin/env python3
"""A GTK 3, GTK 4 or libadwaita process that reports, as JSON lines with a timestamp, the appearance it takes from its
settings (the portal's, on Wayland), for tests/integration/portal_settings.sh (ADR-0035 D-8): GTK's theme name (GTK 3 and 4),
the colour scheme (GTK 4), libadwaita's dark and high-contrast flags and its accent colour (the one of its own it picked). A line at start, then one per change.

    toolkit-watch.py 3|4|adw SECONDS
"""
import json
import sys
import time

import gi

KIND, SECONDS = sys.argv[1], float(sys.argv[2])
gi.require_version("Gtk", "3.0" if KIND == "3" else "4.0")
if KIND == "adw":
    gi.require_version("Adw", "1")
from gi.repository import GLib, Gtk  # noqa: E402


def emit(**fields):
    fields["at"] = round(time.time(), 3)
    print(json.dumps(fields), flush=True)


def main():
    if KIND == "adw":
        from gi.repository import Adw
        Adw.init()
        manager = Adw.StyleManager.get_default()

        def show(*_):
            emit(dark=manager.props.dark, hc=manager.props.high_contrast, accent=manager.get_accent_color().value_nick)
        manager.connect("notify::dark", show)
        manager.connect("notify::high-contrast", show)
        manager.connect("notify::accent-color", show)
    else:
        if KIND == "4":
            Gtk.init()
        settings = Gtk.Settings.get_default()

        def show(*_):
            fields = {"theme": settings.props.gtk_theme_name}
            if KIND == "4":
                fields["scheme"] = int(settings.props.gtk_interface_color_scheme)
            emit(**fields)
        settings.connect("notify::gtk-theme-name", show)
    show()
    loop = GLib.MainLoop()
    GLib.timeout_add(int(SECONDS * 1000), loop.quit)
    loop.run()


main()
