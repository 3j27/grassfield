#!/usr/bin/env python3
"""Generate the Grassfield GTK themes from ui/tokens/tokens.json (stdlib only; ADR-0035 D-8, owner decision Q7).

36 themes: Grassfield-<accent>[-hc][-dark], one per accent of ui/Grassfield/Ui/Accent.js, appearance (-dark) and Increase
Contrast (-hc). Each is CSS only: GTK's own built-in stylesheet (GTK 3's Adwaita, or HighContrast with -hc; GTK 4's Default,
or Default-hc; imported from the GTK library's resources, never copied) followed by Grassfield's rules for the places where
that stylesheet draws its accent: selected rows and text, checked boxes, radios and switches, suggested buttons, progress
bars, sliders and level bars, focused fields, selected tabs, menu items under the pointer, and links; then the warm grounds
(ADR-0040, not in -hc) and the title buttons of client-side header bars, drawn as the compositor plugin's traffic lights
(ADR-0015 amendment 2026-11-04; GTK 3 header bars and GTK 4 window controls, not libadwaita apps, which read no theme). The
Settings portal
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
  focus       the accent where it holds control.focusRingMinContrast against the window, else the text colour (focusRing),
              drawn at control.focusOutlineOpacity (opaque, as the shell's ring)
  link        blue in every accent, as macOS draws links (accentLight.blue / accentDark.blue)
  grounds     the warm neutrals of the owner's choice of 2026-10-30 (ADR-0040), not in the -hc themes (GTK's high-contrast
              grounds stay): the window ground is the appearance's groupFill, views, lists, menus and popovers its
              windowBackground, header bars the plugin's own title bar colour (titlebar.background*), text its text colour
Borders, pressed and hovered fills are the shell's overlays made opaque here (material.borderOpacity, material.hoverOpacity,
control.pressedOpacity over the appearance's materialBorder and hover colours), so the CSS needs no colour function of either GTK
version. The selected tab's indicator keeps GTK's own width (gtk.tabIndicatorWidth); visited links stay blue.

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


def mix(hex_colour, over, amount):
    """`over` laid on `hex_colour` at `amount` (0..1), as #RRGGBB: the shell's overlays (hover, pressed, border) made opaque."""
    return "#%02X%02X%02X" % tuple(round((a * (1 - amount) + b * amount) * 255) for a, b in zip(rgb(hex_colour), rgb(over)))


def with_alpha(hex_colour, alpha):
    r, g, b = (round(c * 255) for c in rgb(hex_colour))
    return f"rgba({r}, {g}, {b}, {alpha})"


def lights(tokens, dark):
    """The traffic lights of the compositor plugin's title bar (window.* tokens, compositor/src/core/Theme.hpp), for the title
    buttons of GTK client-side header bars: the three vivid colours, the grey of a window that is not active (the plugin's
    inactiveLight), the pressed colour (the light darkened by window.pressedOpacity, made opaque as the other overlays), the
    glyph (black at window.glyphOpacity, drawn only under the pointer) and the sizes in whole pixels (a gradient or icon is
    drawn on whole pixels: the 14-pt disc, the glyph at 0.55 of it, its stroke at 0.12, the hit slop around the disc)."""
    w = tokens["window"]
    diameter = value(w["lightDiameter"])
    colours = {"Close": value(w["closeColor"]), "Minimize": value(w["minimizeColor"]), "Zoom": value(w["zoomColor"]),
               "Inactive": value(w["inactiveLightDark" if dark else "inactiveLightLight"])}
    pressed = value(w["pressedOpacity"])
    out = {f"light{k}": v for k, v in colours.items()}
    out.update({f"light{k}Pressed": mix(v, "#000000", pressed) for k, v in colours.items()})
    out.update({"lightGlyph": with_alpha("#000000", value(w["glyphOpacity"])), "lightGlyphHc": with_alpha("#000000", 1.0),
                "lightDiameter": diameter, "lightGlyphSize": round(diameter * value(w["glyphRatio"])),
                "lightGlyphStroke": max(1, round(diameter * value(w["glyphStroke"]))), "lightSlop": round(value(w["lightHitSlop"])),
                "lightGap": value(w["lightGap"]), "lightInset": value(w["titlebarLightInset"])})
    return out


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
    # The shell's overlays: hover and pressed lay the appearance's hover colour on a fill, a border its material border colour.
    overlay, border = value(appearance["hover"]), value(appearance["materialBorder"])
    grounds = {"groundWindow": value(appearance["groupFill"]), "groundView": window, "ink": text,
               "groundTitlebar": value(tokens["titlebar"]["backgroundDark" if dark else "backgroundLight"])}
    return {**grounds, **lights(tokens, dark), "accent": accent, "selection": selection, "selectionText": selection_text, "highlight": accent,
            "highlightText": accent_text, "focus": focus,
            "focusRing": with_alpha(focus, value(tokens["control"]["focusOutlineOpacity"])), "link": link,
            "selectionBorder": mix(selection, border, value(tokens["material"]["borderOpacity"])),
            "selectionHover": mix(selection, overlay, value(tokens["material"]["hoverOpacity"])),
            "selectionActive": mix(selection, overlay, value(tokens["control"]["pressedOpacity"])),
            "tabIndicator": value(tokens["gtk"]["tabIndicatorWidth"]), "window": window, "text": text}


def theme_name(name, dark, hc=False):
    return f"Grassfield-{name}" + ("-hc" if hc else "") + ("-dark" if dark else "")


def header(name, dark, hc, gtk):
    return (f"/* GENERATED by ui/tools/gen-gtk-themes.py from ui/tokens/tokens.json (ADR-0035 D-8). Do not edit.\n"
            f"   {theme_name(name, dark, hc)} for GTK {gtk}: GTK's built-in stylesheet, then the Grassfield {name} accent and its\n"
            f"   selection colours where that stylesheet draws its own accent. */\n")


LIGHTS = (("close", "Close"), ("minimize", "Minimize"), ("maximize", "Zoom"))
# GTK's own metrics under the lights (GTK 3.24.52 Adwaita, GTK 4.24.1 Default): the spacing of the box that holds the title
# buttons (GtkHeaderBar's and GtkWindowControls', 6 px), the header bar's side padding (6 px; 4 px in a default decoration, the
# frame GTK 3 draws for a window without a header bar); the lights are laid on top of them.
GTK_BOX_SPACING = 6
GTK_BAR_PADDING = 6
GTK_DECORATION_PADDING = 4


def lights_css(version, hc, p):
    """The title buttons as traffic lights, the plugin's own (window.* tokens): the 14-pt disc at pitch 23 (gap 9), close red,
    minimize yellow, zoom green; grey while the window is not active (backdrop); coloured with its glyph (x, -, +) under the
    pointer; darker while pressed; the first disc where the plugin's titlebar draws its first (window.titlebarLightInset), the
    discs centred vertically in the bar (a header bar is taller than the plugin's 32 pt: macOS centres the lights in the bar).
    A hit slop (window.lightHitSlop) keeps the button wider than the disc. Increase Contrast adds a ring in the text colour and
    an opaque glyph. GTK's own icon is the x; the minus and the plus are drawn as bars (a gradient), GTK has no plus icon.
    GTK 4 (Default, not libadwaita) shows all three glyphs while the pointer is over the group, as the plugin does; GTK 3 never
    sets :hover on the box that holds the buttons (measured), so each button shows its own glyph and its own colour.
    Specificity: every rule names its light (.close, .minimize, .maximize) and GTK 4's `.image-button`, so it outranks GTK's
    `button.titlebutton:not(.appmenu)` (0,2,1), `.default-decoration.titlebar:not(headerbar) button.titlebutton` (0,3,2) and
    Default's `button.image-button` (0,1,1) and `windowcontrols button:hover > image` (0,1,3), which paints a disc of its own."""
    d, slop, gap, size, stroke = p["lightDiameter"], p["lightSlop"], p["lightGap"], p["lightGlyphSize"], p["lightGlyphStroke"]
    glyph = p["lightGlyphHc"] if hc else p["lightGlyph"]
    ring = f"inset 0 0 0 1px {p['ink']}" if hc else "none"
    spacing = gap - 2 * slop
    centre = value_of_inset(p) + d // 2  # first light's centre from the bar's left edge
    start = centre - d // 2 - slop
    bar = f"linear-gradient({glyph}, {glyph})"
    out = "\n/* Traffic lights (window.* tokens, as the compositor plugin's title bar draws them) */\n"
    colour = lambda k: p["light" + dict(LIGHTS)[k]]  # noqa: E731
    pressed = lambda k: p["light" + dict(LIGHTS)[k] + "Pressed"]  # noqa: E731
    if version == 3:
        pre = ("headerbar", ".default-decoration.titlebar")
        sel = lambda k, state="": ", ".join(f"{x} button.titlebutton.{k}{state}" for x in pre)  # noqa: E731
        img = lambda k, state="": ", ".join(f"{x} button.titlebutton.{k}{state} image" for x in pre)  # noqa: E731
        every = ", ".join(sel(k) for k, _ in LIGHTS)
        every_img = ", ".join(img(k) for k, _ in LIGHTS)
        out += f"""{every} {{
  min-width: {d}px; min-height: {d}px; padding: 0; margin: 0 {spacing - GTK_BOX_SPACING}px 0 0;
  border: {slop}px solid transparent; border-radius: 50%; background-clip: padding-box; background-image: none;
  box-shadow: {ring}; text-shadow: none; -gtk-icon-shadow: none; color: transparent;
}}
headerbar box.left {{ margin-left: {start - GTK_BAR_PADDING}px; }}
.default-decoration.titlebar box.left {{ margin-left: {start - GTK_DECORATION_PADDING}px; }}
{every_img} {{ margin: -1px; min-width: 0; min-height: 0; padding: 0; color: transparent; -gtk-icon-shadow: none;
  background-repeat: no-repeat; background-position: center; background-image: none; }}
"""
        for k, _ in LIGHTS:
            # In the order of their specificity: the colour, grey in the backdrop, the colour under the pointer (also in the
            # backdrop), the pressed colour.
            out += f"{sel(k)} {{ background-color: {colour(k)}; }}\n"
            out += f"{sel(k, ':backdrop')} {{ background-color: {p['lightInactive']}; }}\n"
            out += f"{sel(k, ':hover')}, {sel(k, ':hover:backdrop')} {{ background-color: {colour(k)}; }}\n"
            out += f"{sel(k, ':active')}, {sel(k, ':hover:active')}, {sel(k, ':hover:active:backdrop')} {{ background-color: {pressed(k)}; }}\n"
        hov = lambda k: f"{img(k, ':hover')}, {img(k, ':hover:backdrop')}"  # noqa: E731
        out += f"{hov('close')} {{ color: {glyph}; }}\n"
        out += f"{hov('minimize')}, {hov('maximize')} {{ color: transparent; background-size: {size}px {stroke}px; }}\n"
        out += f"{hov('minimize')} {{ background-image: {bar}; }}\n"
        out += f"{hov('maximize')} {{ background-image: {bar}, {bar}; background-size: {size}px {stroke}px, {stroke}px {size}px; }}\n"
        return out
    sel = lambda k, state="": f"windowcontrols > button.image-button.{k}{state}"  # noqa: E731
    grp = lambda k, state="": f"windowcontrols:hover > button.image-button.{k}{state}"  # noqa: E731
    every = ", ".join(sel(k) for k, _ in LIGHTS)
    every_img = ", ".join(sel(k) + " > image" for k, _ in LIGHTS)
    out += f"""windowcontrols {{ border-spacing: {spacing}px; }}
windowcontrols.start {{ margin-left: {start - GTK_BAR_PADDING}px; }}
{every} {{
  min-width: {d + 2 * slop}px; min-height: {d + 2 * slop}px; margin: 0; padding: 0; border: none; border-radius: 0;
  background: none; box-shadow: none; outline-offset: 0;
}}
{every_img} {{
  min-width: {d}px; min-height: {d}px; margin: 0; padding: 0; border: none; border-radius: 50%; -gtk-icon-size: {d}px;
  box-shadow: {ring}; color: transparent; background-repeat: no-repeat; background-position: center; background-image: none;
}}
"""
    for k, _ in LIGHTS:
        out += f"{sel(k)} > image {{ background-color: {colour(k)}; }}\n"
        out += f"{sel(k, ':backdrop')} > image {{ background-color: {p['lightInactive']}; }}\n"
        out += f"{sel(k, ':hover')} > image, {grp(k)} > image, {grp(k, ':backdrop')} > image {{ background-color: {colour(k)}; }}\n"
        out += f"{sel(k, ':hover:active')} > image, {grp(k, ':active')} > image, {grp(k, ':active:backdrop')} > image {{ background-color: {pressed(k)}; }}\n"
    hov = lambda k: f"{sel(k, ':hover')} > image, {grp(k)} > image, {grp(k, ':backdrop')} > image"  # noqa: E731
    out += f"{hov('close')} {{ color: {glyph}; }}\n"
    out += f"{hov('minimize')}, {hov('maximize')} {{ color: transparent; background-size: {size}px {stroke}px; }}\n"
    out += f"{hov('minimize')} {{ background-image: {bar}; }}\n"
    out += f"{hov('maximize')} {{ background-image: {bar}, {bar}; background-size: {size}px {stroke}px, {stroke}px {size}px; }}\n"
    return out


def value_of_inset(p):
    return p["lightInset"]


def gtk3_grounds(p):
    """The warm grounds of GTK 3's Adwaita (not in the -hc themes): window, views and lists, menus and popovers, header bars."""
    gw, gv, gt, ink = p["groundWindow"], p["groundView"], p["groundTitlebar"], p["ink"]
    return f"""
/* Grounds: the warm neutrals (ADR-0040, the owner's choice of 2026-10-30) */
@define-color theme_bg_color {gw};
@define-color theme_base_color {gv};
@define-color theme_fg_color {ink};
@define-color theme_text_color {ink};
.background, window.background {{ color: {ink}; background-color: {gw}; }}
.background:backdrop, window.background:backdrop {{ background-color: {gw}; }}
.view, iconview, .view text, iconview text, textview text, treeview.view, list {{ color: {ink}; background-color: {gv}; }}
.view:backdrop, iconview:backdrop, .view text:backdrop, iconview text:backdrop, textview text:backdrop, treeview.view:backdrop,
list:backdrop {{ background-color: {gv}; }}
popover.background, menu, .menu, .context-menu {{ background-color: {gv}; }}
popover.background:backdrop, menu:backdrop, .menu:backdrop, .context-menu:backdrop {{ background-color: {gv}; }}
headerbar, .titlebar:not(headerbar), headerbar:backdrop, .titlebar:not(headerbar):backdrop {{
  background-color: {gt};
  background-image: none;
}}
"""


def gtk3_css(name, dark, hc, p):
    a, s, st, f, link = p["accent"], p["selection"], p["selectionText"], p["focus"], p["link"]
    hl, hlt, sb, w = p["highlight"], p["highlightText"], p["selectionBorder"], p["tabIndicator"]
    return header(name, dark, hc, 3) + f"""@import url("{GTK3_IMPORT[dark, hc]}");
{"" if hc else gtk3_grounds(p)}{lights_css(3, hc, p)}
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
notebook > header.top > tabs > tab:checked {{ box-shadow: inset 0 -{w}px {a}; }}
notebook > header.bottom > tabs > tab:checked {{ box-shadow: inset 0 {w}px {a}; }}
notebook > header.left > tabs > tab:checked {{ box-shadow: inset -{w}px 0 {a}; }}
notebook > header.right > tabs > tab:checked {{ box-shadow: inset {w}px 0 {a}; }}

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
  color: {link};
}}
"""


def gtk4_grounds(p):
    """The warm grounds of GTK 4's Default (not in the -hc themes): window, views and lists, popovers, header bars."""
    gw, gv, gt, ink = p["groundWindow"], p["groundView"], p["groundTitlebar"], p["ink"]
    return f"""
/* Grounds: the warm neutrals (ADR-0040, the owner's choice of 2026-10-30) */
@define-color window_bg_color {gw};
@define-color window_fg_color {ink};
@define-color view_bg_color {gv};
@define-color view_fg_color {ink};
@define-color headerbar_bg_color {gt};
@define-color popover_bg_color {gv};
window.background, .background {{ color: {ink}; background-color: {gw}; }}
.view, textview > text, iconview, listview, columnview, gridview, list, treeview.view {{ color: {ink}; background-color: {gv}; }}
popover > contents, popover > arrow, popover.menu > contents {{ background-color: {gv}; }}
headerbar, headerbar:backdrop {{ background-color: {gt}; background-image: none; }}
"""


def gtk4_css(name, dark, hc, p):
    a, s, st, link = p["accent"], p["selection"], p["selectionText"], p["link"]
    hl, hlt, sb, ring, w = p["highlight"], p["highlightText"], p["selectionBorder"], p["focusRing"], p["tabIndicator"]
    return header(name, dark, hc, 4) + f"""@import url("{GTK4_IMPORT[dark, hc]}");
{"" if hc else gtk4_grounds(p)}{lights_css(4, hc, p)}
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
calendar > grid > label.day-number:checked {{ background-color: {s}; color: {st}; }}

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
notebook > header.top > tabs > tab:checked {{ box-shadow: inset 0 -{w}px {a}; }}
notebook > header.bottom > tabs > tab:checked {{ box-shadow: inset 0 {w}px {a}; }}
notebook > header.left > tabs > tab:checked {{ box-shadow: inset -{w}px 0 {a}; }}
notebook > header.right > tabs > tab:checked {{ box-shadow: inset {w}px 0 {a}; }}

/* Links: blue, as macOS draws them in every accent */
link, button.link, link:hover, button.link:hover, link:active, button.link:active {{ color: {link}; }}
link:visited, button.link:visited {{ color: {link}; }}
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
