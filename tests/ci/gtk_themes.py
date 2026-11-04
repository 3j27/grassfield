#!/usr/bin/env python3
"""The generated GTK themes (ui/tools/gen-gtk-themes.py, ADR-0035 D-8): one per accent of Accent.js, appearance and Increase
Contrast (36), each with its GTK 3 and GTK 4 stylesheet; every theme name the Settings portal backend can publish exists
(apps/portal-settings/src/PaletteTokens.hpp); each stylesheet imports GTK's built-in theme of its appearance and contrast from
the library's resources and copies none of it; no colour function (the owner's GTK 4.22 must read them as GTK 4.24 does); the colour pairs hold their
contrast (WCAG 2.x): selected and highlighted text 4.5:1; links 4.5:1, the focus ring and the thin marks 3:1 against the
Grassfield window and GTK's own window and view backgrounds, except the light yellow accent's thin marks (1.86:1 on GTK's
window, 1.97:1 under high contrast since the warm neutrals of 2026-10-30, 2.0:1 on the shell's: the shell's own yellow,
pinned, not hidden) and, since the owner's choice B of 2026-10-30 (ADR-0040 step 1c: a light Green, as macOS's), the light
green accent's (2.32:1 and 2.46:1, pinned).
The rendering itself is tests/integration/gtk_themes.sh.
"""
import importlib.util
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gen_gtk_themes", ROOT / "ui" / "tools" / "gen-gtk-themes.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

failures = 0


def check(ok, desc):
    global failures
    print(("PASS: " if ok else "FAIL: ") + desc)
    if not ok:
        failures += 1


def specificity(selector):
    """(ids, classes + pseudo-classes, types) of a compound selector chain; :not(x) counts as x."""
    flat = re.sub(r":not\(([^)]*)\)", r"\1", selector)
    ids = len(re.findall(r"#[\w-]+", flat))
    classes = len(re.findall(r"\.[\w-]+|:[\w-]+|\[[^\]]*\]", flat))
    types = len(re.findall(r"(?:^|[\s>+~])([a-zA-Z][\w-]*)", flat))
    return (ids, classes, types)


def needed_specificity(version, selector):
    """What GTK's own stylesheets put against a light: GTK 3 Adwaita `button.titlebutton:not(.appmenu)` (0,2,1) and, in a default
    decoration, `.default-decoration.titlebar:not(headerbar) button.titlebutton` (0,3,2); GTK 4 Default `button.image-button`
    (0,1,1) and `windowcontrols button:hover > image` (0,1,3), `windowcontrols button > image` (0,0,3). A selector at or above
    the figure wins (a tie by order)."""
    if version == 3:
        return (0, 3, 2) if ".default-decoration" in selector else (0, 2, 1)
    return (0, 1, 3) if selector.rstrip().endswith("> image") else (0, 1, 1)


tokens = gen.load()
names = [name for name, _ in gen.themes(tokens)]
check(len(names) == 36 and len(set(names)) == 36, f"36 distinct themes [{len(names)}]")
header = (ROOT / "apps" / "portal-settings" / "src" / "PaletteTokens.hpp").read_text()
published = re.findall(r'\{"([a-z]+)", 0x', header)
expected = [f"Grassfield-{n}{hc}{dark}" for n in published for hc in ("", "-hc") for dark in ("", "-dark")]
check(sorted(expected) == sorted(names), f"every theme the portal backend publishes exists, and only those [{len(published)} accents]")

with tempfile.TemporaryDirectory() as out:
    gen.main(["gen-gtk-themes.py", out])
    files = sorted(str(p.relative_to(out)) for p in pathlib.Path(out).rglob("*") if p.is_file())
    check(len(files) == 108, f"index.theme, gtk-3.0/gtk.css and gtk-4.0/gtk.css in each theme [{len(files)} files]")
    bad_import, copied, functions = [], [], []
    for name in names:
        for version, path in (("3", "gtk-3.0/gtk.css"), ("4", "gtk-4.0/gtk.css")):
            text = (pathlib.Path(out) / name / path).read_text()
            imports = re.findall(r'@import url\("([^"]+)"\)', text)
            want = (gen.GTK3_IMPORT if version == "3" else gen.GTK4_IMPORT)[name.endswith("-dark"), "-hc" in name]
            if imports != [want] or not want.startswith("resource:///org/gtk/libgtk/theme/"):
                bad_import.append(f"{name} gtk{version}")
            if "#3584e4" in text.lower() or len(text) > 12000:
                copied.append(f"{name} gtk{version}")
            if re.search(r"\b(shade|mix|lighter|darker|alpha|color-mix|hsl|hwb)\(|\bfrom\s+#", text):
                functions.append(f"{name} gtk{version}")
    check(not bad_import, f"each stylesheet imports exactly GTK's own built-in theme for its appearance and contrast {bad_import}")
    hc = [n for n in names if "-hc" in n]
    check(all("HighContrast/" in (pathlib.Path(out) / n / "gtk-3.0/gtk.css").read_text() and
              "Default-hc" in (pathlib.Path(out) / n / "gtk-4.0/gtk.css").read_text() for n in hc) and len(hc) == 18,
          f"the -hc themes import GTK's high-contrast stylesheets [{len(hc)}]")
    check(not copied, f"no stylesheet carries GTK's accent or a copy of GTK's theme (small, own rules only) {copied}")
    check(not functions, f"no colour function in any stylesheet {functions}")
    # The warm grounds (ADR-0040, the owner's warm neutrals of 2026-10-30): every theme but -hc lays the appearance's window,
    # view and title bar colours and its text colour, from the tokens, in both GTK versions; -hc keeps GTK's own grounds.
    missing, hc_grounds = [], []
    for name in names:
        hc_theme, dark = "-hc" in name, name.endswith("-dark")
        p = gen.palette(tokens, name.split("-")[1], dark)
        for path in ("gtk-3.0/gtk.css", "gtk-4.0/gtk.css"):
            text = (pathlib.Path(out) / name / path).read_text()
            if hc_theme:
                if "Grounds:" in text:
                    hc_grounds.append(f"{name} {path}")
            elif not all(p[k] in text for k in ("groundWindow", "groundView", "groundTitlebar", "ink")):
                missing.append(f"{name} {path}")
    check(not missing, f"every theme but -hc lays the warm grounds and text from the tokens {missing}")
    check(not hc_grounds, f"the -hc themes keep GTK's high-contrast grounds {hc_grounds}")

# The backgrounds the marks are drawn on: the Grassfield window (the shell's) and GTK's own window and view backgrounds under
# each stylesheet (theme_bg_color, theme_base_color of GTK 3.24.52 and GTK 4.24.1: the same in both versions).
GTK_BACKGROUNDS = {(False, False): ["#f6f5f4", "#ffffff"], (True, False): ["#353535", "#2d2d2d"],
                   (False, True): ["#fdfdfc", "#ffffff"], (True, True): ["#303030", "#2d2d2d"]}
# The light accents whose thin marks stay under 3:1 in the light appearance, as the shell's own: the floor each must hold.
LIGHT_MARK_FLOOR = {"yellow": 1.8, "green": 2.3}
low = []
worst = {}
for name in gen.accent_names(tokens):
    for hc in (False, True):
        for dark in (False, True):
            p = gen.palette(tokens, name, dark)
            theme = gen.theme_name(name, dark, hc)
            grounds = [p["window"]] + ([] if hc else [p["groundWindow"], p["groundView"]]) + GTK_BACKGROUNDS[dark, hc]
            on = lambda colour: min(gen.contrast(colour, g) for g in grounds)  # noqa: E731
            pairs = [("selection", gen.contrast(p["selection"], p["selectionText"]), 4.5),
                     ("highlight", gen.contrast(p["highlight"], p["highlightText"]), 4.5),
                     ("link", on(p["link"]), 4.5),
                     ("focus", on(p["focus"]), 3.0),
                     ("accent", on(p["accent"]), LIGHT_MARK_FLOOR.get(name, 3.0) if not dark else 3.0)]
            low += [f"{theme} {what} {ratio:.2f} < {need}" for what, ratio, need in pairs if ratio < need]
            worst[theme] = on(p["accent"])
check(not low, f"colour pairs hold their contrast on the Grassfield window and GTK's backgrounds {low}")
# The ring is checked at its solid colour: it must be drawn so (control.focusOutlineOpacity, the shell's opaque ring).
rings = {gen.palette(tokens, n, d)["focusRing"] for n in gen.accent_names(tokens) for d in (False, True)}
check(gen.value(tokens["control"]["focusOutlineOpacity"]) == 1.0 and all(r.endswith(", 1.0)") for r in rings),
      f"the GTK 4 focus ring is drawn opaque, the colour its contrast is checked at [{sorted(rings)[:2]}...]")
yellow = gen.palette(tokens, "yellow", False)
check(gen.contrast(yellow["accent"], yellow["window"]) < 3.0 and yellow["focus"] == yellow["text"],
      "the light yellow accent: thin marks under 3:1 (the shell's own yellow), its focus ring the text colour (Accent.js focusRing)")
check(round(worst["Grassfield-yellow"], 2) == 1.86 and round(worst["Grassfield-yellow-hc"], 2) == 1.97,
      f"the light yellow thin marks: 1.86:1 at worst on GTK's window, 1.97:1 under high contrast (pinned) "
      f"[{worst['Grassfield-yellow']:.2f}, {worst['Grassfield-yellow-hc']:.2f}]")
green = gen.palette(tokens, "green", False)
check(gen.contrast(green["accent"], green["window"]) < 3.0 and green["focus"] == green["text"],
      "the light green accent (ADR-0040 step 1c): thin marks under 3:1 (the shell's own green), its focus ring the text colour")
check(round(worst["Grassfield-green"], 2) == 2.32 and round(worst["Grassfield-green-hc"], 2) == 2.46,
      f"the light green thin marks: 2.32:1 at worst on GTK's window, 2.46:1 under high contrast (pinned) "
      f"[{worst['Grassfield-green']:.2f}, {worst['Grassfield-green-hc']:.2f}]")

# Traffic lights (ADR-0015 amendment 2026-11-04): every theme, -hc and dark included, styles the title buttons of GTK 3's header
# bars and GTK 4's window controls with the plugin's own window.* tokens: the three colours, the grey of an inactive window
# (backdrop) of its appearance, the pressed colours, the 14-pt disc, the glyph shown under the pointer on the group.
with tempfile.TemporaryDirectory() as out:
    gen.main(["gen-gtk-themes.py", out])
    w = tokens["window"]
    miss, shape, low_spec = [], [], []
    for name in names:
        dark = name.endswith("-dark")
        p = gen.palette(tokens, name.split("-")[1], dark)
        grey = gen.value(w["inactiveLightDark" if dark else "inactiveLightLight"]).upper()
        for path, version in (("gtk-3.0/gtk.css", 3), ("gtk-4.0/gtk.css", 4)):
            text = (pathlib.Path(out) / name / path).read_text()
            upper = text.upper()
            want = [gen.value(w[k]).upper() for k in ("closeColor", "minimizeColor", "zoomColor")] + [grey] + \
                   [p[f"light{k}Pressed"].upper() for k in ("Close", "Minimize", "Zoom")]
            if not all(c in upper for c in want):
                miss.append(f"{name} gtk{version}")
            block = text[text.index("/* Traffic lights"):text.index("@define-color theme_selected_bg_color")]
            if version == 3:
                needs = ["headerbar button.titlebutton.close", ".default-decoration.titlebar button.titlebutton.minimize",
                         "button.titlebutton.maximize:backdrop", "button.titlebutton.close:hover image",
                         "button.titlebutton.close:hover:active:backdrop"]
                # GTK 3 never sets :hover on the box that holds the buttons (measured in nested, Evince): no state may wait for it.
                if "box:hover" in text:
                    shape.append(f"{name} gtk3 hangs a state on box:hover")
            else:
                needs = ["windowcontrols > button.image-button.close", "windowcontrols > button.image-button.minimize > image",
                         "windowcontrols > button.image-button.maximize:backdrop > image", "windowcontrols:hover > button.image-button.close"]
            needs += [f"min-width: {gen.value(w['lightDiameter'])}px", "border-radius: 50%"]
            if not all(n in text for n in needs):
                shape.append(f"{name} gtk{version}")
            # Specificity: each rule outranks GTK's own that reaches the same node (read from GTK 3.24.52 Adwaita and GTK 4.24.1
            # Default): a tie is won by the later rule, ours come after the @import.
            if text.index("@import") > text.index("/* Traffic lights"):
                shape.append(f"{name} gtk{version} lights before the import")
            for sels, _body in re.findall(r"([^{}]+)\{([^}]*)\}", block):
                for sel in (s.strip() for s in sels.split(",")):
                    if "button" not in sel:
                        continue
                    want = needed_specificity(version, sel)
                    if specificity(sel) < want:
                        low_spec.append(f"{name} gtk{version} {sel} {specificity(sel)} < {want}")
    check(not miss, f"every theme draws its title buttons in the plugin's light colours, grey and pressed from the tokens {miss}")
    check(not shape, f"every theme styles close, minimize and maximize (GTK 3: header bar, .default-decoration, per-button states, "
                     f"never box:hover; GTK 4: windowcontrols > button.image-button) with backdrop, hover and pressed, a 14 px disc, "
                     f"after the import {shape[:3]}")
    check(not low_spec, f"every light rule outranks the GTK rule that reaches the same node (Default's .image-button, Adwaita's "
                        f"default-decoration rule) {low_spec[:3]}")
    hc_ring = [n for n in names if ("-hc" in n) != ("inset 0 0 0 1px" in (pathlib.Path(out) / n / "gtk-4.0/gtk.css").read_text())]
    check(not hc_ring, f"only the -hc themes ring a light in the text colour {hc_ring}")
# The glyph on a light holds 3:1 on each (window.glyphOpacity, the plugin's: black at 0.62 over the light).
glyph_low = []
for k in ("closeColor", "minimizeColor", "zoomColor"):
    light = gen.value(tokens["window"][k])
    under = gen.mix(light, "#000000", gen.value(tokens["window"]["glyphOpacity"]))
    if gen.contrast(light, under) < 3.0:
        glyph_low.append(f"{k} {gen.contrast(light, under):.2f}")
check(not glyph_low, f"the glyph holds 3:1 on each light {glyph_low}")

# The text on the warm grounds (window, views, header bars): 7:1 or more in both appearances, as the shell's text.
low_text = []
for dark in (False, True):
    p = gen.palette(tokens, "multicolor", dark)
    for ground in ("groundWindow", "groundView", "groundTitlebar"):
        ratio = gen.contrast(p["ink"], p[ground])
        if ratio < 7.0:
            low_text.append(f"{'dark' if dark else 'light'} {ground} {ratio:.2f}")
check(not low_text, f"the text holds 7:1 on every warm ground {low_text}")

sys.exit(1 if failures else 0)
