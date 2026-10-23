"""Probe for tests/shell/icon_theme.sh: GTK 3 or 4 icon lookup, without a display.

usage: [GF_ICON_SIZE=<px, default 16>] python3 -I icon_probe_gtk.py <3|4> <icons-dir> <theme> name...
Prints "<name>=<theme directory the file came from>/<icon file>" or "<name>=-".
"""
import os
import sys

version, icons_dir, theme = sys.argv[1:4]
import gi  # noqa: E402

gi.require_version("Gtk", version + ".0")
from gi.repository import Gtk  # noqa: E402

size = int(os.environ.get("GF_ICON_SIZE", "16"))
icon_theme = Gtk.IconTheme.new()
icon_theme.set_search_path([icons_dir])
if version == "3":
    icon_theme.set_custom_theme(theme)
else:
    icon_theme.set_theme_name(theme)
for name in sys.argv[4:]:
    if version == "3":
        info = icon_theme.lookup_icon(name, size, 0)
        path = info.get_filename() if info else None
    else:
        # GTK 4 returns a "missing icon" paintable that needs a display: ask has_icon first.
        paintable = icon_theme.lookup_icon(name, None, size, 1, Gtk.TextDirection.NONE, 0) if icon_theme.has_icon(name) else None
        file = paintable.get_file() if paintable else None
        path = file.get_path() if file else None
    print("%s=%s" % (name, os.path.relpath(path, icons_dir) if path else "-"))
