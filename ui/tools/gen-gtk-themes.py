#!/usr/bin/env python3
"""Generate the Grassfield GTK themes from ui/tokens/tokens.json (stdlib only; ADR-0035 D-8, owner decision Q7).

36 themes: Grassfield-<accent>[-hc][-dark], one per accent of ui/Grassfield/Ui/Accent.js, appearance (-dark) and Increase
Contrast (-hc). Each is CSS only: GTK's own built-in stylesheet (GTK 3's Adwaita, or HighContrast with -hc; GTK 4's Default,
or Default-hc; imported from the GTK library's resources, never copied) followed by Grassfield's rules for the places where
that stylesheet draws its accent: selected rows and text, checked boxes, radios and switches, suggested buttons, progress
bars, sliders and level bars, focused fields, selected tabs, menu items under the pointer, and links. The Settings portal
backend names the theme of the current appearance, accent and contrast in org.gnome.desktop.interface gtk-theme
(apps/portal-settings/src/portalvalues.h); GTK 3 apps read it with GTK_USE_PORTAL=1, GTK 4 apps with GDK_DEBUG=portals.
Increase Contrast keeps the colours below (the shell's contrastBoost does not change the accent either): GTK's high-contrast
stylesheet draws the stronger borders and separators.

Colours (the same rules as the shell, Accent.js):
  accent      thin marks without text (sliders, progress, tab underline): the appearance's accent
  selection   fills that carry text or a mark (selected rows, checked boxes, switches, suggested buttons, menu items): the
              light accent and its text colour in the light appearance; color.selectionDark in the dark one (selectionPair)
  highlight   selected text in fields, labels and editors: the appearance's accent and its text colour (highlight,
              "automatic"; the `accent.highlight` setting is not followed: a theme per highlight would make 162 themes)
  focus       the accent where it holds control.focusRingMinContrast against the window, else the text colour (focusRing)
  link        blue in every accent, as macOS draws links (accentLight.blue / accentDark.blue)
Shades (borders, pressed and hovered fills) are computed here, so the CSS needs no colour function of either GTK version.

Usage: gen-gtk-themes.py OUTDIR     write OUTDIR/Grassfield-*/{index.theme,gtk-3.0/gtk.css,gtk-4.0/gtk.css}
       gen-gtk-themes.py --list     print the theme names
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKENS = ROOT / "ui" / "tokens" / "tokens.json"

# (dark, increase contrast) -> GTK's stylesheet
GTK3_IMPORT = {(False, False): "resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained.css",
               (True, False): "resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css",
               (False, True): "resource:///org/gtk/libgtk/theme/HighContrast/gtk-contained.css",
               (True, True): "resource:///org/gtk/libgtk/theme/HighContrast/gtk-contained-inverse.css"}
GTK4_IMPORT = {(False, False): "resource:///org/gtk/libgtk/theme/Default/Default-light.css",
               (True, False): "resource:///org/gtk/libgtk/theme/Default/Default-dark.css",
               (False, True): "resource:///org/gtk/libgtk/theme/Default/Default-hc.css",
               (True, True): "resource:///org/gtk/libgtk/theme/Default/Default-hc-dark.css"}


def load():
    return json.loads(TOKENS.read_text())


def value(leaf):
    return leaf["value"] if isinstance(leaf, dict) else leaf


def accent_names(tokens):
    light = tokens["color"]["accentLight"]
    return ["multicolor"] + [n for n in light if not n.endswith("Text")]


def rgb(hex_colour):
    h = hex_colour.lstrip("#")[-6:]
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def luminance(hex_colour):
    def f(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(c) for c in rgb(hex_colour))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def shade(hex_colour, factor):
    """GTK 3's shade(): lightness and saturation scaled by `factor` (clamped), as #RRGGBB."""
    import colorsys
    h, lightness, saturation = colorsys.rgb_to_hls(*rgb(hex_colour))
    r, g, b = colorsys.hls_to_rgb(h, min(1.0, lightness * factor), min(1.0, saturation * factor))
    return "#%02X%02X%02X" % tuple(round(c * 255) for c in (r, g, b))


def with_alpha(hex_colour, alpha):
    r, g, b = (round(c * 255) for c in rgb(hex_colour))
    return f"rgba({r}, {g}, {b}, {alpha})"


def palette(tokens, name, dark):
    """The colours of one theme, every one from the tokens."""
    color = tokens["color"]
    appearance = color["dark" if dark else "light"]
    if name == "multicolor":
        accent, accent_text = value(appearance["accent"]), value(appearance["accentText"])
        light_accent, light_text = value(color["light"]["accent"]), value(color["light"]["accentText"])
    else:
        group = color["accentDark" if dark else "accentLight"]
        accent, accent_text = value(group[name]), value(group[name + "Text"])
        light_accent, light_text = value(color["accentLight"][name]), value(color["accentLight"][name + "Text"])
    if dark:
        selection, selection_text = value(color["selectionDark"][name]), value(color["selectionDark"][name + "Text"])
    else:
        selection, selection_text = light_accent, light_text
    window = value(appearance["windowBackground"])
    text = value(appearance["text"])
    minimum = value(tokens["control"]["focusRingMinContrast"])
    focus = accent if contrast(accent, window) >= minimum else text
    link = value(color["accentDark" if dark else "accentLight"]["blue"])
    return {"accent": accent, "selection": selection, "selectionText": selection_text, "highlight": accent,
            "highlightText": accent_text, "focus": focus, "focusRing": with_alpha(focus, 0.5), "link": link,
            "linkVisited": shade(link, 0.85), "selectionBorder": shade(selection, 0.85),
            "selectionHover": shade(selection, 1.08), "selectionActive": shade(selection, 0.9), "window": window, "text": text}


def theme_name(name, dark, hc=False):
    return f"Grassfield-{name}" + ("-hc" if hc else "") + ("-dark" if dark else "")


def header(name, dark, hc, gtk):
    return (f"/* GENERATED by ui/tools/gen-gtk-themes.py from ui/tokens/tokens.json (ADR-0035 D-8). Do not edit.\n"
            f"   {theme_name(name, dark, hc)} for GTK {gtk}: GTK's built-in stylesheet, then the Grassfield {name} accent and its\n"
            f"   selection colours where that stylesheet draws its own accent. */\n")


def gtk3_css(name, dark, hc, p):
    a, s, st, f, link = p["accent"], p["selection"], p["selectionText"], p["focus"], p["link"]
    hl, hlt, sb = p["highlight"], p["highlightText"], p["selectionBorder"]
    return header(name, dark, hc, 3) + f"""@import url("{GTK3_IMPORT[dark, hc]}");

@define-color theme_selected_bg_color {s};
@define-color theme_selected_fg_color {st};
@define-color theme_unfocused_selected_bg_color {s};
@define-color theme_unfocused_selected_fg_color {st};

/* Selected rows and cells */
*:selected, *:selected:focus, *:selected:backdrop, .view:selected, .view:selected:focus, .view:selected:backdrop,
iconview:selected, treeview.view:selected, row:selected, row:selected:backdrop, flowboxchild:selected,
calendar:selected {{
  background-color: {s};
  color: {st};
}}

/* Selected text */
.view text:selected, textview text:selected, selection, selection:focus, selection:backdrop, .view text selection,
textview text selection, entry selection, label selection, spinbutton selection {{
  background-color: {hl};
  color: {hlt};
}}

/* Default and suggested actions */
button.suggested-action, button.suggested-action:backdrop, button.suggested-action:checked {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
  text-shadow: none;
  -gtk-icon-shadow: none;
}}
button.suggested-action:hover {{ background-color: {p["selectionHover"]}; background-image: none; }}
button.suggested-action:active, button.suggested-action:checked:hover {{ background-color: {p["selectionActive"]}; background-image: none; }}

/* Checked boxes, radios and switches */
check:checked, check:indeterminate, radio:checked, radio:indeterminate,
check:checked:hover, check:indeterminate:hover, radio:checked:hover, radio:indeterminate:hover,
check:checked:active, check:indeterminate:active, radio:checked:active, radio:indeterminate:active,
check:checked:backdrop, check:indeterminate:backdrop, radio:checked:backdrop, radio:indeterminate:backdrop {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
}}
switch:checked, switch:checked:hover, switch:checked:backdrop {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
}}
switch:checked slider, switch:checked:hover slider, switch:checked:backdrop slider {{ border-color: {sb}; }}

/* Progress bars, sliders and level bars */
progressbar progress, progressbar progress:backdrop, scale highlight, scale highlight:backdrop, scale fill,
levelbar block.filled, entry progress {{
  background-color: {a};
  background-image: none;
  border-color: {a};
}}

/* Focused fields */
entry:focus, spinbutton:not(.vertical):focus, spinbutton.vertical entry:focus, combobox entry:focus {{
  border-color: {f};
  box-shadow: inset 0 0 0 1px {f};
}}

/* Selected tabs */
notebook > header.top > tabs > tab:checked {{ box-shadow: inset 0 -3px {a}; }}
notebook > header.bottom > tabs > tab:checked {{ box-shadow: inset 0 3px {a}; }}
notebook > header.left > tabs > tab:checked {{ box-shadow: inset -3px 0 {a}; }}
notebook > header.right > tabs > tab:checked {{ box-shadow: inset 3px 0 {a}; }}

/* Menu items under the pointer */
menu menuitem:hover, .menu menuitem:hover, .context-menu menuitem:hover {{
  color: {st};
  background-color: {s};
}}

/* Links: blue, as macOS draws them in every accent (link buttons colour their label) */
*:link, button:link, button:link > label, *:link:hover, button:hover:link, button:link > label:hover, *:link:active,
button:active:link, button:link > label:active, *:link:backdrop, button:backdrop:link, button:link > label:backdrop {{
  color: {link};
}}
*:link:visited, button:visited, button:visited > label, button:link > label:visited, button:visited > label:visited {{
  color: {p["linkVisited"]};
}}
"""


def gtk4_css(name, dark, hc, p):
    a, s, st, link = p["accent"], p["selection"], p["selectionText"], p["link"]
    hl, hlt, sb, ring = p["highlight"], p["highlightText"], p["selectionBorder"], p["focusRing"]
    return header(name, dark, hc, 4) + f"""@import url("{GTK4_IMPORT[dark, hc]}");

@define-color theme_selected_bg_color {s};
@define-color theme_selected_fg_color {st};
@define-color theme_unfocused_selected_bg_color {s};
@define-color theme_unfocused_selected_fg_color {st};

/* Selected rows and cells */
*:selected, row:selected, .view:selected, .view:selected:focus, textview > text:selected, iconview:selected,
gridview > child:selected, listview > row:selected, columnview > listview > row:selected, flowbox > flowboxchild:selected,
calendar > grid > label.day-number:selected {{
  background-color: {s};
  color: {st};
}}
calendar > grid > label.day-number:checked {{ background-color: {with_alpha(s, 0.3)}; }}

/* Selected text */
selection, text > selection, text > selection:focus-within, label > selection, label > selection:focus-within,
entry > text > selection:focus-within, textview > text > selection:focus-within, editablelabel > stack > text > selection:focus-within,
spinbutton:not(.vertical) > text > selection:focus-within, spinbutton.vertical > text > text > selection:focus-within {{
  background-color: {hl};
  color: {hlt};
}}

/* Default and suggested actions */
button.suggested-action, button.suggested-action:checked {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
  box-shadow: none;
}}
button.suggested-action:hover {{ background-color: {p["selectionHover"]}; background-image: none; }}
button.suggested-action:active, button.suggested-action:checked:hover {{ background-color: {p["selectionActive"]}; background-image: none; }}
button.suggested-action.flat, button.suggested-action.flat:disabled {{ color: {a}; }}

/* Checked boxes, radios and switches */
check:checked, check:indeterminate, radio:checked, radio:indeterminate,
check:checked:hover, check:indeterminate:hover, radio:checked:hover, radio:indeterminate:hover,
check:checked:active, check:indeterminate:active, radio:checked:active, radio:indeterminate:active {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
}}
switch:checked, switch:checked:hover {{
  color: {st};
  background-color: {s};
  background-image: none;
  border-color: {sb};
}}
switch:checked > slider, row:selected switch > slider, row:selected switch > slider:checked {{ border-color: {sb}; }}

/* Progress bars, sliders and level bars */
progressbar > trough > progress, scale > trough > highlight, scale > trough > fill, levelbar > trough > block.filled,
entry > progress > trough > progress {{
  background-color: {a};
  background-image: none;
  border-color: {a};
}}

/* Focus: one rule for every focus outline (specific enough to come after GTK's per-widget rules) */
*:focus:focus-visible:not(:backdrop):not(:disabled), *:focus-within:not(:backdrop):not(:disabled):not(window) {{ outline-color: {ring}; }}
entry:focus-within, spinbutton:focus-within:not(.vertical), spinbutton.vertical > text:focus-within {{ outline-color: {ring}; }}

/* Selected tabs */
notebook > header.top > tabs > tab:checked {{ box-shadow: inset 0 -4px {a}; }}
notebook > header.bottom > tabs > tab:checked {{ box-shadow: inset 0 4px {a}; }}
notebook > header.left > tabs > tab:checked {{ box-shadow: inset -4px 0 {a}; }}
notebook > header.right > tabs > tab:checked {{ box-shadow: inset 4px 0 {a}; }}

/* Links: blue, as macOS draws them in every accent */
link, button.link, link:hover, button.link:hover, link:active, button.link:active {{ color: {link}; }}
link:visited, button.link:visited {{ color: {p["linkVisited"]}; }}
"""


def index_theme(name, dark, hc):
    title = theme_name(name, dark, hc)
    base = "high-contrast theme" if hc else "theme"
    return (f"[Desktop Entry]\nType=X-GNOME-Metatheme\nName={title}\n"
            f"Comment=Grassfield {name} accent over GTK's built-in {base} (generated)\nEncoding=UTF-8\n\n"
            f"[X-GNOME-Metatheme]\nGtkTheme={title}\n")


def themes(tokens):
    """(theme name, {relative path: text}) for every theme."""
    out = []
    for name in accent_names(tokens):
        for hc in (False, True):
            for dark in (False, True):
                p = palette(tokens, name, dark)
                out.append((theme_name(name, dark, hc), {
                    "index.theme": index_theme(name, dark, hc),
                    "gtk-3.0/gtk.css": gtk3_css(name, dark, hc, p),
                    "gtk-4.0/gtk.css": gtk4_css(name, dark, hc, p),
                }))
    return out


def main(argv):
    tokens = load()
    if argv[1:] == ["--list"]:
        print("\n".join(name for name, _ in themes(tokens)))
        return 0
    if len(argv) != 2 or argv[1].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    out = pathlib.Path(argv[1])
    for name, files in themes(tokens):
        for rel, text in files.items():
            path = out / name / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    print(f"gen-gtk-themes: {len(themes(tokens))} themes in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
