#!/usr/bin/env python3
"""The generated GTK themes (ui/tools/gen-gtk-themes.py, ADR-0035 D-8): one per accent of Accent.js, appearance and Increase
Contrast (36), each with its GTK 3 and GTK 4 stylesheet; every theme name the Settings portal backend can publish exists
(apps/portal-settings/src/PaletteTokens.hpp); each stylesheet imports GTK's built-in theme of its appearance and contrast from
the library's resources and copies none of it; no colour function (the owner's GTK 4.22 must read them as GTK 4.24 does); the colour pairs hold their
contrast (WCAG 2.x): selected and highlighted text 4.5:1, links 4.5:1 against the window, the focus ring and the thin marks
3:1, except the light yellow accent's thin marks (2.0:1, the shell's own yellow: pinned, not hidden).
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

low = []
for name in gen.accent_names(tokens):
    for dark in (False, True):
        p = gen.palette(tokens, name, dark)
        theme = gen.theme_name(name, dark)
        pairs = [("selection", gen.contrast(p["selection"], p["selectionText"]), 4.5),
                 ("highlight", gen.contrast(p["highlight"], p["highlightText"]), 4.5),
                 ("link", gen.contrast(p["link"], p["window"]), 4.5),
                 ("focus", gen.contrast(p["focus"], p["window"]), 3.0)]
        accent = gen.contrast(p["accent"], p["window"])
        pairs.append(("accent", accent, 2.0 if theme == "Grassfield-yellow" else 3.0))
        low += [f"{theme} {what} {ratio:.2f} < {need}" for what, ratio, need in pairs if ratio < need]
check(not low, f"colour pairs hold their contrast {low}")
yellow = gen.palette(tokens, "yellow", False)
check(gen.contrast(yellow["accent"], yellow["window"]) < 3.0 and yellow["focus"] == yellow["text"],
      "the light yellow accent: thin marks 2.0:1 (the shell's own yellow), its focus ring the text colour (Accent.js focusRing)")

sys.exit(1 if failures else 0)
