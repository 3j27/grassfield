# Wayland drag source for tests/visual/dock-drops.sh: a window whose whole area starts a DnD offering text/uri-list (bytes, no portal).
# Usage: python3 -I dragsrc.py SECONDS PATH... ; exits by itself after SECONDS. Logs drag events to stderr.
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gtk, Gdk, GLib

secs = int(sys.argv[1])
paths = sys.argv[2:]
uris = "".join(GLib.filename_to_uri(p, None) + "\r\n" for p in paths)
loop = GLib.MainLoop()


def log(*a):
    print("dragsrc:", *a, file=sys.stderr, flush=True)


win = Gtk.Window(title="gfdragsrc")
win.set_default_size(300, 200)
label = Gtk.Label(label="DRAG ME\n" + "\n".join(paths))
win.set_child(label)
src = Gtk.DragSource()
src.set_actions(Gdk.DragAction.COPY | Gdk.DragAction.MOVE)


def prepare(s, x, y):
    log("prepare", x, y)
    return Gdk.ContentProvider.new_for_bytes("text/uri-list", GLib.Bytes.new(uris.encode()))


def begin(s, drag):
    log("begin")
    drag.connect("drop-performed", lambda d: log("drop-performed"))
    drag.connect("dnd-finished", lambda d: log("dnd-finished action=%s" % d.get_selected_action()))
    drag.connect("cancel", lambda d, reason: log("gdk-cancel reason=%s" % reason))


def end(s, drag, delete):
    log("end delete=%s action=%s" % (delete, drag.get_selected_action()))


def cancel(s, drag, reason):
    log("cancel reason=%s" % reason)
    return False


src.connect("prepare", prepare)
src.connect("drag-begin", begin)
src.connect("drag-end", end)
src.connect("drag-cancel", cancel)
label.add_controller(src)
win.connect("close-request", lambda w: (loop.quit(), False)[1])
win.present()
GLib.timeout_add_seconds(secs, loop.quit)
log("ready", uris.strip())
loop.run()
log("exit")
