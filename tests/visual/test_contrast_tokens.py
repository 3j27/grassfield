#!/usr/bin/env python3
"""Gate A2, exact token calculation (L0, deterministic, no compositor): the PRIMARY evidence of contrast.

  python3 -I tests/visual/test_contrast_tokens.py          unit tests + the table (also run by scripts/dev/test.sh)
  python3 -I tests/visual/test_contrast_tokens.py --table  only print the table

For every text role of tests/visual/contrast-roles.json the effective text colour (token colour x the item's opacity, composited over
the backdrop) is compared with the backdrop (WCAG 2.x relative luminance) for both appearances, transparency 0, 0.25, 0.4, 0.6
(material default 0.25; master-prompt 5.5: every value <= 0.6 must pass) and every worst-case flat wallpaper colour: black, white,
mid-grey, saturated red and blue and the extreme colours of the five contrast wallpapers (contrast.py: white, black, grey, the yellow/
green noise palette, the black/white checker). Blur makes the backdrop a local average, so flat colours bound it. Compositing is done in
sRGB, as Qt does. Backdrops:
  material       tint at alpha 1 - t * (1 - material.tintAlphaMin), then (worst case) with the fill overlay (a tile or field fill)
  accent         the solid accent colour
  apps           black dim (apps.backdropOpacity, apps.backdropOpacityOpaque at t = 0) over the wallpaper
  apps-field     apps + the Apps search field fill
  rename-field   colors.fieldFill at desktopIcon.renameFillOpacity over the wallpaper (the inline rename field)
  desktop-label  the label shadow colour at its core alpha (desktopIcon.labelShadowOpacity) over the wallpaper: text against the shadow,
                 conservatively taken as fully opaque behind the glyph
The role table is cross-checked against the QML: a new secondary-text, text-alpha, text-opacity or danger-colour use without a role fails.
"""
import importlib.util
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("contrast", os.path.join(HERE, "contrast.py"))
contrast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contrast)

TRANSPARENCIES = (0.0, 0.25, 0.4, 0.6)
APPEARANCES = ("dark", "light")
THRESHOLD = {"text": 4.5, "large": 3.0, "icon": 3.0}
# Flat worst-case backdrops: black, white, mid-grey, saturated red and blue, the noise palette (yellow/greens). The checker (black/white
# 2 px) and the plain wallpapers are covered by black, white and grey.
WALLPAPER_COLORS = [(0, 0, 0), (255, 255, 255), (128, 128, 128), (255, 0, 0), (0, 0, 255)] + list(contrast.NOISE_PALETTE)


def load_tokens():
    with open(os.path.join(ROOT, "ui", "tokens", "tokens.json")) as f:
        return json.load(f)


def load_roles():
    with open(os.path.join(HERE, "contrast-roles.json")) as f:
        return json.load(f)["roles"]


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def over(fg, alpha, bg):
    """fg at alpha composited over the opaque bg (sRGB channels 0-255, floats)."""
    return tuple(fg[i] * alpha + bg[i] * (1 - alpha) for i in range(3))


def lum(rgb):
    return contrast.luminance(rgb)


def wcag(a, b):
    return contrast.ratio(lum(a), lum(b))


class Tokens:
    def __init__(self, data):
        self.data = data

    def path(self, dotted):
        node = self.data
        for part in dotted.split("."):
            node = node[part]
        return node["value"]

    def color(self, palette, appearance, name):
        # palette "colors" follows the appearance; "darkColors" is always the dark palette.
        return hex_rgb(self.path("color.%s.%s" % ("dark" if palette == "darkColors" else appearance, name)))

    def number(self, ref):
        return float(ref) if isinstance(ref, (int, float)) else float(self.path(ref))

    def tint_alpha(self, t):
        return 1 - t * (1 - self.path("material.tintAlphaMin"))


def backdrops(tok, role, appearance, t, wallpaper):
    """Backdrop colours (opaque RGB) behind the text for one role/appearance/transparency/wallpaper colour."""
    kind = role["backdrop"]
    pal = "darkColors" if role["fg"].startswith("darkColors") else "colors"
    if kind == "material":
        base = over(tok.color(pal, appearance, "materialTint"), tok.tint_alpha(t), wallpaper)
        fill = tok.color(pal, appearance, "fill")
        # Without a fill, and with the fill overlay of a tile or field (materialFillOpacity), worst case of the two.
        return [base, over(fill, tok.path("material.fillOpacity"), base)]
    if kind == "accent":
        return [tok.color(pal, appearance, "accent")]
    if kind in ("apps", "apps-field"):
        dim = tok.path("apps.backdropOpacity") if t > 0 else tok.path("apps.backdropOpacityOpaque")
        base = over((0, 0, 0), dim, wallpaper)
        if kind == "apps-field":
            base = over(tok.color("darkColors", appearance, "shadow"), tok.path("apps.searchFillOpacity"), base)
        return [base]
    if kind == "rename-field":
        return [over(tok.color("colors", appearance, "fieldFill"), tok.path("desktopIcon.renameFillOpacity"), wallpaper)]
    if kind == "desktop-label":
        return [over(tok.color("darkColors", appearance, "shadow"), tok.path("desktopIcon.labelShadowOpacity"), wallpaper)]
    raise ValueError("unknown backdrop " + kind)


def role_ratio(tok, role, appearance, t, wallpaper):
    """Worst ratio of one role over the backdrop variants for one combination."""
    pal, name = role["fg"].split(".")
    fg = tok.color(pal, appearance, name)
    alpha = 1.0
    for o in role.get("opacity", []):
        alpha *= tok.number(o)
    worst = None
    for bg in backdrops(tok, role, appearance, t, wallpaper):
        r = wcag(over(fg, alpha, bg), bg)
        worst = r if worst is None else min(worst, r)
    return worst


def role_table(tok, roles):
    """{role id: {(appearance, t): (min ratio, wallpaper colour)}}"""
    table = {}
    for role in roles:
        cells = {}
        for ap in APPEARANCES:
            for t in TRANSPARENCIES:
                best = None
                for wp in WALLPAPER_COLORS:
                    r = role_ratio(tok, role, ap, t, wp)
                    if best is None or r < best[0]:
                        best = (r, wp)
                cells[(ap, t)] = best
        table[role["id"]] = cells
    return table


def print_table(tok, roles, table):
    head = "%-40s %5s | %s | %s" % ("role (min over 9 wallpaper colours)", "need",
                                    " ".join("d.%-4s" % t for t in TRANSPARENCIES), " ".join("l.%-4s" % t for t in TRANSPARENCIES))
    print(head)
    print("-" * len(head))
    for role in roles:
        thr = THRESHOLD[role["kind"]]
        cells = table[role["id"]]
        cols = []
        for ap in APPEARANCES:
            cols.append(" ".join("%5.2f%s" % (cells[(ap, t)][0], "*" if cells[(ap, t)][0] < thr else " ") for t in TRANSPARENCIES))
        lo = min(c[0] for c in cells.values())
        tag = "  exempt: " + role["exempt"][:48] if role.get("exempt") else ""
        print("%-40s %5.1f | %s | %s  min %.2f%s" % (role["id"][:40], thr, cols[0], cols[1], lo, tag))
    print("columns: d = dark, l = light appearance; transparency %s; '*' = below the threshold." % ", ".join(str(t) for t in TRANSPARENCIES))


# ---- QML cross-check ------------------------------------------------------------------------------------

SCAN_DIRS = ("shell", "ui/Grassfield")
TEXT_BLOCK = re.compile(r"\s*(?:Text|TextInput|TextEdit|TextField|Label)\s*\{")
SECONDARY = re.compile(r"[cC]olors\.textSecondary")
ALPHA = re.compile(r"withAlpha\(\s*Appearance\.(?:dark)?[cC]olors\.(?:text|accentText)\b")
DANGER = re.compile(r"[cC]olors\.danger")


def scan_qml():
    """{(relative file, class): count} of secondary-text, text-alpha, text-opacity and danger uses in the QML."""
    found = {}

    def add(key):
        found[key] = found.get(key, 0) + 1

    for sub in SCAN_DIRS:
        for d, _, files in os.walk(os.path.join(ROOT, sub)):
            for name in sorted(files):
                if not name.endswith(".qml") or name == "Tokens.qml":
                    continue
                path = os.path.join(d, name)
                rel = os.path.relpath(path, ROOT)
                with open(path, encoding="utf-8") as f:
                    lines = f.read().split("\n")
                for line in lines:
                    if line.lstrip().startswith("//"):
                        continue
                    for _ in SECONDARY.finditer(line):
                        add((rel, "secondary"))
                    for _ in ALPHA.finditer(line):
                        add((rel, "alpha"))
                    for _ in DANGER.finditer(line):
                        add((rel, "danger"))
                for i, line in enumerate(lines):
                    if not TEXT_BLOCK.match(line):
                        continue
                    ind = len(line) - len(line.lstrip())
                    for j in range(i + 1, len(lines)):
                        lj = lines[j]
                        if lj.strip() and len(lj) - len(lj.lstrip()) <= ind:
                            break
                        if len(lj) - len(lj.lstrip()) != ind + 4:
                            continue
                        s = lj.strip()
                        if s.startswith("opacity:"):
                            add((rel, "opacity"))
    return found


def declared_sites(roles):
    out = {}
    for role in roles:
        for s in role["sites"]:
            key = (s["file"], s["class"])
            out[key] = out.get(key, 0) + s["count"]
    return out


class ContrastTokens(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tok = Tokens(load_tokens())
        cls.roles = load_roles()
        cls.table = role_table(cls.tok, cls.roles)

    def test_calculation_sanity(self):
        # Hand-checked: black on white 21, mid-grey (118) on white 4.54, the same colour on itself 1, 50 % black over white is grey 127.5.
        self.assertAlmostEqual(wcag((0, 0, 0), (255, 255, 255)), 21.0, places=6)
        self.assertAlmostEqual(wcag((118, 118, 118), (255, 255, 255)), 4.54, delta=0.01)
        self.assertAlmostEqual(wcag((7, 7, 7), (7, 7, 7)), 1.0, places=9)
        self.assertEqual(over((0, 0, 0), 0.5, (255, 255, 255)), (127.5, 127.5, 127.5))
        # text colour x opacity over the backdrop: 85 % white over mid-grey is lighter grey but never reaches white.
        self.assertLess(wcag(over((255, 255, 255), 0.85, (128, 128, 128)), (128, 128, 128)), wcag((255, 255, 255), (128, 128, 128)))

    def test_opacity_is_part_of_the_colour(self):
        # The old banner body (opacity 0.85 on text) failed on the white wallpaper; the same role at opacity 1 must be better.
        full = {"fg": "colors.text", "backdrop": "material", "kind": "text"}
        faded = dict(full, opacity=[0.85])
        for ap in APPEARANCES:
            self.assertLess(role_ratio(self.tok, faded, ap, 0.6, (255, 255, 255)), role_ratio(self.tok, full, ap, 0.6, (255, 255, 255)))

    def test_tint_alpha_matches_appearance_qml(self):
        # Appearance.tintAlpha(t) = 1 - clamp01(t) * (1 - tintAlphaMin) (ui/Grassfield/Ui/Appearance.qml): same formula here.
        with open(os.path.join(ROOT, "ui", "Grassfield", "Ui", "Appearance.qml")) as f:
            qml = f.read()
        self.assertIn("return 1 - clamp01(t) * (1 - Tokens.materialTintAlphaMin);", qml)

    def test_every_role_meets_its_threshold(self):
        bad = []
        for role in self.roles:
            if role.get("exempt"):
                continue
            thr = THRESHOLD[role["kind"]]
            for (ap, t), (r, wp) in self.table[role["id"]].items():
                if r < thr:
                    bad.append("%s: %s t=%s over %s: %.2f < %.1f" % (role["id"], ap, t, wp, r, thr))
        self.assertEqual(bad, [], "\n" + "\n".join(bad))

    def test_exempt_roles_state_a_reason(self):
        for role in self.roles:
            if "exempt" in role:
                self.assertGreater(len(role["exempt"]), 20, role["id"])

    def test_role_table_matches_the_qml(self):
        scan = scan_qml()
        declared = declared_sites(self.roles)
        missing = sorted("%s [%s]: QML has %d, roles declare %d" % (k[0], k[1], scan[k], declared.get(k, 0))
                         for k in scan if scan[k] != declared.get(k, 0))
        stale = sorted("%s [%s]: roles declare %d, QML has none" % (k[0], k[1], declared[k]) for k in declared if k not in scan)
        self.assertEqual(missing + stale, [],
                         "\nadd or update the role in tests/visual/contrast-roles.json:\n" + "\n".join(missing + stale))

    def test_role_ids_unique_and_fields_valid(self):
        ids = [r["id"] for r in self.roles]
        self.assertEqual(len(ids), len(set(ids)))
        for r in self.roles:
            self.assertIn(r["kind"], THRESHOLD)
            self.assertIn(r["backdrop"], ("material", "accent", "apps", "apps-field", "rename-field", "desktop-label"))
            self.assertRegex(r["fg"], r"^(colors|darkColors)\.\w+$")

    def test_desktop_label_survives_white_and_black(self):
        # White label text over its shadow core on pure white and on black (and so over the checker, which is both).
        label = next(r for r in self.roles if r["id"].startswith("desktop label ("))
        for wp in ((255, 255, 255), (0, 0, 0)):
            for ap in APPEARANCES:
                self.assertGreaterEqual(role_ratio(self.tok, label, ap, 0.25, wp), 4.5)

    def test_selection_highlight_text_both_appearances(self):
        accent = next(r for r in self.roles if r["id"] == "accent text on accent")
        for ap in APPEARANCES:
            self.assertGreaterEqual(role_ratio(self.tok, accent, ap, 0.25, (255, 255, 255)), 4.5)


if __name__ == "__main__":
    _tok = Tokens(load_tokens())
    _roles = load_roles()
    print_table(_tok, _roles, role_table(_tok, _roles))
    if "--table" in sys.argv:
        sys.exit(0)
    unittest.main(verbosity=1, argv=[sys.argv[0]])
