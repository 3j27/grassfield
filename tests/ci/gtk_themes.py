#!/usr/bin/env python3
"""The generated GTK themes (ui/tools/gen-gtk-themes.py, ADR-0035 D-8): one per accent of Accent.js, appearance and Increase
Contrast (36), each with its GTK 3 and GTK 4 stylesheet; every theme name the Settings portal backend can publish exists
(apps/portal-settings/src/PaletteTokens.hpp); each stylesheet imports GTK's built-in theme of its appearance and contrast from
the library's resources and copies none of it; no colour function (the owner's GTK 4.22 must read them as GTK 4.24 does); the colour pairs hold their
contrast (WCAG 2.x): selected and highlighted text 4.5:1; links 4.5:1, the focus ring and the thin marks 3:1 against the
Grassfield window and GTK's own window and view backgrounds, except the light yellow accent's thin marks (1.86:1 on GTK's
window, 1.99:1 under high contrast, 2.0:1 on the shell's: the shell's own yellow, pinned, not hidden).
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

# The backgrounds the marks are drawn on: the Grassfield window (the shell's) and GTK's own window and view backgrounds under
# each stylesheet (theme_bg_color, theme_base_color of GTK 3.24.52 and GTK 4.24.1: the same in both versions).
GTK_BACKGROUNDS = {(False, False): ["#f6f5f4", "#ffffff"], (True, False): ["#353535", "#2d2d2d"],
                   (False, True): ["#fdfdfc", "#ffffff"], (True, True): ["#303030", "#2d2d2d"]}
low = []
worst = {}
for name in gen.accent_names(tokens):
    for hc in (False, True):
        for dark in (False, True):
            p = gen.palette(tokens, name, dark)
            theme = gen.theme_name(name, dark, hc)
            grounds = [p["window"]] + GTK_BACKGROUNDS[dark, hc]
            on = lambda colour: min(gen.contrast(colour, g) for g in grounds)  # noqa: E731
            pairs = [("selection", gen.contrast(p["selection"], p["selectionText"]), 4.5),
                     ("highlight", gen.contrast(p["highlight"], p["highlightText"]), 4.5),
                     ("link", on(p["link"]), 4.5),
                     ("focus", on(p["focus"]), 3.0),
                     ("accent", on(p["accent"]), 1.8 if name == "yellow" and not dark else 3.0)]
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
check(round(worst["Grassfield-yellow"], 2) == 1.86 and round(worst["Grassfield-yellow-hc"], 2) == 1.99,
      f"the light yellow thin marks: 1.86:1 at worst on GTK's window, 1.99:1 under high contrast (pinned) "
      f"[{worst['Grassfield-yellow']:.2f}, {worst['Grassfield-yellow-hc']:.2f}]")

sys.exit(1 if failures else 0)
