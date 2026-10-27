#!/usr/bin/env python3
"""A GTK window with every place a GTK theme draws its accent, in its selected or checked state, for
tests/integration/gtk_themes.sh (ADR-0035 D-8): a suggested button, a checked box, a selected radio, a switch on, a slider, a
progress bar, a level bar, a field with selected text and the focus, a list with a selected row, a selectable label with
selected text, a notebook, and a link. It prints READY once drawn and quits after argv[2] seconds.

    gtk-specimen.py 3|4 SECONDS
"""
import sys

import gi

VERSION = sys.argv[1]
SECONDS = float(sys.argv[2])
gi.require_version("Gtk", VERSION + ".0")
from gi.repository import GLib, Gtk  # noqa: E402

TITLE = "gtk-specimen"


def rows(box_add, select):
    listbox = Gtk.ListBox()
    for text in ("First row", "Selected row", "Third row"):
        label = Gtk.Label(label=text)
        listbox.append(label) if VERSION == "4" else listbox.add(label)
    select(listbox, listbox.get_row_at_index(1))
    box_add(listbox)


def build(window, add):
    button = Gtk.Button(label="Default action")
    button.get_style_context().add_class("suggested-action")
    add(button)
    check = Gtk.CheckButton(label="Checked")
    check.set_active(True)
    add(check)
    if VERSION == "4":
        radio = Gtk.CheckButton(label="Radio")
        Gtk.CheckButton(label="Other").set_group(radio)
    else:
        radio = Gtk.RadioButton(label="Radio")
    radio.set_active(True)
    add(radio)
    switch = Gtk.Switch()
    switch.set_active(True)
    switch.set_halign(Gtk.Align.START)
    add(switch)
    scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
    scale.set_value(60)
    scale.set_size_request(260, -1)
    add(scale)
    progress = Gtk.ProgressBar()
    progress.set_fraction(0.6)
    add(progress)
    level = Gtk.LevelBar()
    level.set_value(0.5)
    add(level)
    entry = Gtk.Entry()
    entry.set_text("Selected text in a field")
    add(entry)
    label = Gtk.Label(label="Selectable label text")
    label.set_selectable(True)
    add(label)
    rows(add, lambda listbox, row: listbox.select_row(row))
    notebook = Gtk.Notebook()
    for title in ("Tab one", "Tab two"):
        page = Gtk.Label(label=title)
        notebook.append_page(page, Gtk.Label(label=title))
    add(notebook)
    add(Gtk.LinkButton(uri="https://example.invalid/", label="A link"))
    return entry, label


def ready(entry, label):
    entry.grab_focus()
    entry.select_region(0, 8)
    label.select_region(0, 10)
    entry.grab_focus()
    print("READY", flush=True)
    return False


def main():
    if VERSION == "4":
        Gtk.init()
        window = Gtk.Window(title=TITLE)
        window.set_default_size(420, 720)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_start(16)
        box.set_margin_end(16)
        box.set_margin_top(16)
        box.set_margin_bottom(16)
        window.set_child(box)
        entry, label = build(window, box.append)
        loop = GLib.MainLoop()
        window.present()
        GLib.timeout_add(800, ready, entry, label)
        GLib.timeout_add(int(SECONDS * 1000), loop.quit)
        loop.run()
    else:
        window = Gtk.Window(title=TITLE)
        window.set_default_size(420, 720)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(16)
        window.add(box)
        entry, label = build(window, lambda w: box.pack_start(w, False, False, 0))
        window.show_all()
        GLib.timeout_add(800, ready, entry, label)
        GLib.timeout_add(int(SECONDS * 1000), Gtk.main_quit)
        Gtk.main()


main()
