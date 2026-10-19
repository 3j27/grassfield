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
  rename-field   colors.fieldFill at desktopIcon.renameFillOpacity over the wallpaper (the inline rename field)
  bar-light-tone / bar-dark-tone  the adaptive menu bar (shell/services/BarTone.qml): the opaque wallpaper itself, only for the
                 wallpaper colours the tone can be chosen for (light text up to menubar.toneDarkAbove, dark text from
                 menubar.toneLightBelow); the faint shadow is decoration and not counted
  desktop-label  the label shadow colour at its core alpha (desktopIcon.labelShadowOpacity) over the wallpaper: white text against the
                 shadow taken as fully opaque behind the glyph. That is the BEST case (19:1), a ceiling that only proves the token
                 colours still contrast; the rendered contrast of the labels over a white wallpaper (blurred shadow, 4.8:1) is
                 measured by tests/visual/contrast.sh --surfaces desktop, which is the evidence for that surface.
  lock           the lock screen: the shadow-colour scrim at lock.dimOpacity over the (blurred) wallpaper; the lock always uses the
                 dark palette and no material, so both appearances and every transparency give the same values
  lock-field     lock + the dark password field fill (shadow colour at lock.fieldFillOpacity)
  lock-avatar    lock + the light avatar disc (dark-palette fill at lock.avatarFillOpacity)
  lock-submit    lock-field + the return arrow disc (text colour at material.highlightOpacity, and x2 when hovered: worst of the two)
  lock-selection the opaque dark-palette accent band behind selected dots in the password field (Shift+arrows, Ctrl+A); the band
                 itself is checked against lock-field as a graphic (3:1)
                 The lock model is checked against LockView.qml and PasswordField.qml (test_lock_model_matches_the_qml); the text
                 shadow is decoration and not counted.
The role table is cross-checked against the QML (tests/visual/qml_scan.py, a structural scan: palette aliases, colors["textSecondary"],
opacity on any ancestor, one-line items, Qt.darker/lighter/alpha/tint/rgba, `opacity :`): a new secondary-text, danger-colour, derived
text-colour (alpha), computed-palette-key (dynamic) or text-opacity use without a role fails. Inside shell/security/ every palette
read counts (primary text and backdrop colours: the lock and the authorization dialog draw their own backdrops).
Tint alpha: material.tintAlphaMin at transparency 1, linear in between, clamped to material.tintAlphaClamp up to transparency
material.tintClampUntil (ui/Grassfield/Ui/Appearance.qml tintAlpha()); at the default 0.25 the tint is 0.85, unclamped.
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
LOCK_BACKDROPS = ("lock", "lock-field", "lock-avatar", "lock-submit", "lock-selection")
BAR_TONES = ("bar-light-tone", "bar-dark-tone")
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
        # palette "colors" follows the appearance; "darkColors" / "lightColors" are always the dark / light palette.
        fixed = {"darkColors": "dark", "lightColors": "light"}
        return hex_rgb(self.path("color.%s.%s" % (fixed.get(palette, appearance), name)))

    def number(self, ref):
        return float(ref) if isinstance(ref, (int, float)) else float(self.path(ref))

    def tint_alpha(self, t):
        """Mirror of Appearance.tintAlpha (checked against the QML source by test_tint_alpha_matches_appearance_qml)."""
        mn = self.path("material.tintAlphaMin")
        clamp = self.path("material.tintAlphaClamp")
        until = self.path("material.tintClampUntil")
        t = max(0.0, min(1.0, t))
        linear = 1 - t * (1 - mn)
        if t <= until:
            return max(linear, clamp)
        return clamp + (mn - clamp) * (t - until) / (1 - until)


def backdrops(tok, role, appearance, t, wallpaper):
    """Backdrop colours (opaque RGB) behind the text for one role/appearance/transparency/wallpaper colour."""
    kind = role["backdrop"]
    pal = "darkColors" if role["fg"].startswith("darkColors") else "colors"
    if kind in BAR_TONES:
        # The adaptive menu bar (BarTone): the wallpaper under the bare bar, for the wallpapers the tone can be chosen for. Light text
        # is shown up to menubar.toneDarkAbove and dark text from menubar.toneLightBelow (the hysteresis band shows either).
        l = lum(wallpaper)
        if kind == "bar-light-tone":
            return [wallpaper] if l <= tok.path("menubar.toneDarkAbove") else []
        return [wallpaper] if l >= tok.path("menubar.toneLightBelow") else []
    if kind == "material":
        base = over(tok.color(pal, appearance, "materialTint"), tok.tint_alpha(t), wallpaper)
        fill = tok.color(pal, appearance, "fill")
        # Without a fill, and with the fill overlay of a tile or field (materialFillOpacity), worst case of the two.
        return [base, over(fill, tok.path("material.fillOpacity"), base)]
    if kind == "accent":
        return [tok.color(pal, appearance, "accent")]
    if kind == "rename-field":
        return [over(tok.color("colors", appearance, "fieldFill"), tok.path("desktopIcon.renameFillOpacity"), wallpaper)]
    if kind == "desktop-label":
        return [over(tok.color("darkColors", appearance, "shadow"), tok.path("desktopIcon.labelShadowOpacity"), wallpaper)]
    if kind == "lock-selection":
        # Opaque band: whatever lies under it (field, scrim, wallpaper) is hidden.
        return [tok.color("darkColors", appearance, "accent")]
    if kind in LOCK_BACKDROPS:
        shadow = tok.color("darkColors", appearance, "shadow")
        base = over(shadow, tok.path("lock.dimOpacity"), wallpaper)
        if kind == "lock":
            return [base]
        if kind == "lock-avatar":
            return [over(tok.color("darkColors", appearance, "fill"), tok.path("lock.avatarFillOpacity"), base)]
        field = over(shadow, tok.path("lock.fieldFillOpacity"), base)
        if kind == "lock-field":
            return [field]
        text = tok.color("darkColors", appearance, "text")
        hl = tok.path("material.highlightOpacity")
        return [over(text, hl, field), over(text, 2 * hl, field)]
    raise ValueError("unknown backdrop " + kind)


def role_ratio(tok, role, appearance, t, wallpaper):
    """Worst ratio of one role over the backdrop variants for one combination."""
    pal, name = role["fg"].split(".")
    fg = tok.color(pal, appearance, name)
    alpha = 1.0
    for o in role.get("opacity", []):
        alpha *= tok.number(o)
    worst = None  # None: the role has no backdrop for this wallpaper (an adaptive bar tone is never chosen for it)
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
                    if r is not None and (best is None or r < best[0]):
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

_scan_spec = importlib.util.spec_from_file_location("qml_scan", os.path.join(HERE, "qml_scan.py"))
qml_scan = importlib.util.module_from_spec(_scan_spec)
_scan_spec.loader.exec_module(qml_scan)


def scan_qml():
    """{(relative file, class): count} of the contrast-relevant uses in shell/ and ui/Grassfield/ (see qml_scan.py)."""
    return qml_scan.scan_tree(ROOT)


def cross_check(scan, declared):
    """Problems of a scan against the declared sites: uses without a role (or with another count) and stale declarations."""
    missing = sorted("%s [%s]: QML has %d, roles declare %d" % (k[0], k[1], scan[k], declared.get(k, 0))
                     for k in scan if scan[k] != declared.get(k, 0))
    stale = sorted("%s [%s]: roles declare %d, QML has none" % (k[0], k[1], declared[k]) for k in declared if k not in scan)
    return missing + stale


# One sample per form the scanner must catch (each makes the cross-check FAIL when no role declares it), and the forms it must not flag.
SELFTEST_SAMPLES = {
    "palette alias": 'Item {\n  readonly property var pal: Appearance.colors\n  Text { color: pal.textSecondary }\n}\n',
    "palette alias in a ternary": 'Item {\n  readonly property var pal: Appearance.dark ? Tokens.colorDark : Tokens.colorLight\n'
                                  '  Text { color: pal.danger }\n}\n',
    "bracket access": 'Text { color: Appearance.colors["textSecondary"] }\n',
    "bracket access, single quotes on an alias": "Item {\n  property var c: Appearance.darkColors\n  Text { color: c['danger'] }\n}\n",
    "opacity on a parent": 'Item {\n  opacity: 0.6\n  Column {\n    Text { text: "x" }\n  }\n}\n',
    "opacity on a grandparent, computed": 'Item {\n  opacity: shown ? 1 : 0.4\n  Row {\n    Item {\n      Text { text: "x" }\n    }\n  }\n}\n',
    "one-line Text with opacity": 'Item {\n  Text { text: "x"; opacity: 0.5 }\n}\n',
    "one-line Text, opacity first": 'Item { Text{opacity:0.5;text:"x"} }\n',
    "Qt.darker": 'Text { color: Qt.darker(Appearance.colors.text, 1.4) }\n',
    "Qt.lighter of an alias": 'Item {\n  property var pal: Appearance.colors\n  Text { color: Qt.lighter(pal.text) }\n}\n',
    "Qt.alpha": 'Text { color: Qt.alpha(Appearance.colors.accentText, 0.7) }\n',
    "opacity with a space before the colon": 'Text {\n  text: "x"\n  opacity : 0.5\n}\n',
    "computed palette key": 'Item {\n  property string key: "text"\n  Text { color: Appearance.colors[key] }\n}\n',
    "withAlpha on a multi-line call": 'Text {\n  color: Appearance.withAlpha(\n    Appearance.colors.text, 0.5)\n}\n',
}
# Forms only classified inside shell/security/ (every palette read there counts: primary and backdrop). Each must FAIL the
# cross-check when undeclared there, and none may be flagged outside shell/security/.
SECURITY_SAMPLES = {
    "primary text through root.colors": 'Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
                                        '  Text { color: root.colors.text }\n}\n',
    "primary text through a bare alias": 'Item {\n  property var colors: Tokens.colorDark\n  Text { color: colors.text }\n}\n',
    "primary text with brackets": "Text { color: Tokens.colorDark['text'] }\n",
    "scrim through root.colors": 'Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
                                 '  Rectangle { color: root.colors.shadow; opacity: 0.6 }\n}\n',
    "field fill through withAlpha": 'Item {\n  readonly property var colors: Appearance.darkColors\n'
                                    '  Rectangle { color: Appearance.withAlpha(colors.shadow, 0.45) }\n}\n',
    "surface colour from Tokens": 'Rectangle { color: Tokens.colorDark.shadow }\n',
}
SELFTEST_CLEAN = {
    "opacity 1": 'Item {\n  opacity: 1\n  Text { text: "x"; opacity: 1.0 }\n}\n',
    "commented use": '// Appearance.colors.textSecondary\nItem {\n  /* Text { opacity: 0.5 } */\n}\n',
    "string mentioning the token": 'Item { property string s: "Appearance.colors.textSecondary" }\n',
    "opacity on an item without text": 'Item {\n  opacity: 0.5\n  Rectangle { color: "red" }\n}\n',
    "primary text": 'Text { color: Appearance.colors.text }\n',
}


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
        for line in ("const x = clamp01(t);",
                     "const linear = 1 - x * (1 - Tokens.materialTintAlphaMin);",
                     "return Math.max(linear, Tokens.materialTintAlphaClamp);",
                     "return Tokens.materialTintAlphaClamp + (Tokens.materialTintAlphaMin - Tokens.materialTintAlphaClamp) * (x - until) / (1 - until);"):
            self.assertIn(line, qml)
        self.assertIn("const until = Tokens.materialTintClampUntil;", qml)

    def test_frosted_default_and_clamp(self):
        # The material reads as frosted at the default (tint <= 0.85) and the clamp only acts at high transparency.
        self.assertLessEqual(self.tok.tint_alpha(0.25), 0.85 + 1e-9)
        self.assertAlmostEqual(self.tok.tint_alpha(0.25), 1 - 0.25 * (1 - self.tok.path("material.tintAlphaMin")), places=9)
        self.assertEqual(self.tok.tint_alpha(0.0), 1.0)
        self.assertAlmostEqual(self.tok.tint_alpha(1.0), self.tok.path("material.tintAlphaMin"), places=9)
        self.assertGreaterEqual(self.tok.tint_alpha(0.6), self.tok.path("material.tintAlphaClamp") - 1e-9)
        for lo, hi in ((0.0, 0.25), (0.25, 0.4), (0.4, 0.6), (0.6, 1.0)):
            self.assertGreaterEqual(self.tok.tint_alpha(lo), self.tok.tint_alpha(hi))

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
        problems = cross_check(scan_qml(), declared_sites(self.roles))
        self.assertEqual(problems, [], "\nadd or update the role in tests/visual/contrast-roles.json:\n" + "\n".join(problems))

    def test_cross_check_selftest_each_form_fails(self):
        # Every form of a contrast-relevant use the scanner must see makes the cross-check FAIL when no role declares it.
        comps = frozenset({"Button"})
        for name, src in SELFTEST_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/Sample.qml", comps)
            self.assertNotEqual(cross_check(scan, {}), [], "form not detected: " + name)

    def test_cross_check_selftest_declared_passes_and_clean_forms_do_not_trip(self):
        for name, src in SELFTEST_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/Sample.qml", frozenset())
            self.assertEqual(cross_check(scan, dict(scan)), [], name)
        for name, src in SELFTEST_CLEAN.items():
            self.assertEqual(qml_scan.scan_source(src, "shell/Sample.qml", frozenset()), {}, "false positive: " + name)

    def test_cross_check_selftest_security_reads(self):
        # Inside shell/security/ every palette read (primary text, scrim, fill, ...) must be declared; outside it they are not
        # classified (primary text on material is the default "text on material" role).
        for name, src in SECURITY_SAMPLES.items():
            scan = qml_scan.scan_source(src, "shell/security/lock/Sample.qml", frozenset())
            self.assertNotEqual(cross_check(scan, {}), [], "security form not detected: " + name)
            self.assertEqual(cross_check(scan, dict(scan)), [], name)
            self.assertEqual(qml_scan.scan_source(src, "shell/overlay/Sample.qml", frozenset()), {}, "outside shell/security: " + name)
        # A derived text colour stays one `alpha` site (not also primary); textSecondary stays `secondary`.
        src = ('Item {\n  id: root\n  readonly property var colors: Appearance.darkColors\n'
               '  Rectangle { border.color: Appearance.withAlpha(root.colors.text, 0.7) }\n  Text { color: root.colors.textSecondary }\n}\n')
        self.assertEqual(qml_scan.scan_source(src, "shell/security/Sample.qml", frozenset()),
                         {("shell/security/Sample.qml", "alpha"): 1, ("shell/security/Sample.qml", "secondary"): 1})

    def test_lock_roles_are_asserted(self):
        # The lock screen is inside gate A2: its roles exist, none is exempt, and each meets its threshold over every wallpaper colour.
        lock = [r for r in self.roles if r["id"].startswith("lock ")]
        self.assertGreaterEqual(len(lock), 6)
        for role in lock:
            self.assertNotIn("exempt", role, role["id"])
            self.assertIn(role["backdrop"], LOCK_BACKDROPS, role["id"])
            lo = min(r for r, _ in self.table[role["id"]].values())
            self.assertGreaterEqual(lo, THRESHOLD[role["kind"]], role["id"])
        self.assertEqual({r["backdrop"] for r in lock}, set(LOCK_BACKDROPS))
        # The lock does not follow the appearance or the transparency: every column of a lock role is the same.
        for role in lock:
            values = {round(r, 9) for r, _ in self.table[role["id"]].values()}
            self.assertEqual(len(values), 1, role["id"])

    def test_lock_model_matches_the_qml(self):
        # The lock backdrops above mirror these lines; a change in the QML must change the model (and this test) too.
        with open(os.path.join(ROOT, "shell", "security", "lock", "LockView.qml")) as f:
            view = f.read()
        with open(os.path.join(ROOT, "shell", "security", "PasswordField.qml")) as f:
            field = f.read()
        for line in ("readonly property var colors: Appearance.darkColors",
                     "color: root.colors.shadow\n        opacity: Tokens.lockDimOpacity",
                     "color: Appearance.withAlpha(root.colors.fill, Tokens.lockAvatarFillOpacity)",
                     "textColor: root.colors.text",
                     "placeholderColor: root.colors.textSecondary",
                     "fillColor: Appearance.withAlpha(root.colors.shadow, Tokens.lockFieldFillOpacity)",
                     "focusColor: Appearance.withAlpha(root.colors.text, Tokens.lockFocusRingOpacity)",
                     "selectionColor: root.colors.accent\n",
                     "selectedTextColor: root.colors.accentText\n"):
            self.assertIn(line, view)
        for line in ("color: Appearance.withAlpha(root.textColor, submitMouse.containsMouse ? Tokens.materialHighlightOpacity * 2"
                     " : Tokens.materialHighlightOpacity)",
                     "color: root.textColor\n        selectionColor: root.selectionColor\n        selectedTextColor: root.selectedTextColor\n",
                     "property color selectionColor: Appearance.colors.accent\n",
                     "property color selectedTextColor: Appearance.colors.accentText\n",
                     "color: root.placeholderColor",
                     "color: root.fillColor",
                     "border.color: root.focusColor"):
            self.assertIn(line, field)
        # Every text item on the scrim and the disc uses the primary text colour: date, clock, initials, name, error, notice.
        self.assertEqual(view.count("color: root.colors.text\n"), 6)
        # The error and notice lines (the two AlertMessage items) carry no layer or effect: a failed effect would hide
        # "Authentication service unavailable" / "Crash recovery unavailable" (R12 review of 0513f6e).
        alerts = [i for i in range(len(view)) if view.startswith("Accessible.role: Accessible.AlertMessage", i)]
        self.assertEqual(len(alerts), 2)
        for at in alerts:
            block = view[view.rfind("Text {", 0, at):at]
            self.assertNotIn("layer.", block)

    def test_lock_password_selection(self):
        # R12 review #3 residual: a selection in the lock's password field drew white dots on the focus ring colour (white at
        # lock.focusRingOpacity), 1.7-2.1:1. As on macOS and in every other field of the shell, the selection is now the accent
        # band with accent-text dots: readable (4.5:1) and the band visible against the field (3:1) over every wallpaper colour.
        dots = next(r for r in self.roles if r["id"] == "lock password selection (dots on the accent band)")
        band = next(r for r in self.roles if r["id"] == "lock password selection band against the field")
        old = {"fg": "darkColors.text", "backdrop": "lock-field", "kind": "text"}
        for wp in WALLPAPER_COLORS:
            self.assertGreaterEqual(role_ratio(self.tok, dots, "dark", 0.25, wp), 4.5, wp)
            self.assertGreaterEqual(role_ratio(self.tok, band, "dark", 0.25, wp), 3.0, wp)
            # Negative control: the old rendering (white dots on the white focus-ring band over the field) stays below 3:1.
            field = backdrops(self.tok, old, "dark", 0.25, wp)[0]
            ring = over(self.tok.color("darkColors", "dark", "text"), self.tok.path("lock.focusRingOpacity"), field)
            self.assertLess(wcag(self.tok.color("darkColors", "dark", "text"), ring), 3.0, wp)

    def test_cross_check_selftest_component_instance_with_opacity(self):
        # An instance of a component that contains text, given an opacity, is a text item with that opacity.
        src = 'Item {\n  Button { opacity: 0.5 }\n}\n'
        self.assertNotEqual(cross_check(qml_scan.scan_source(src, "shell/Sample.qml", frozenset({"Button"})), {}), [])
        self.assertEqual(qml_scan.scan_source(src, "shell/Sample.qml", frozenset()), {})

    def test_role_ids_unique_and_fields_valid(self):
        ids = [r["id"] for r in self.roles]
        self.assertEqual(len(ids), len(set(ids)))
        for r in self.roles:
            self.assertIn(r["kind"], THRESHOLD)
            self.assertIn(r["backdrop"], ("material", "accent", "rename-field", "desktop-label") + BAR_TONES + LOCK_BACKDROPS)
            for site in r["sites"]:
                self.assertIn(site["class"], ("secondary", "danger", "alpha", "dynamic", "opacity", "opacity-dynamic", "primary",
                                              "backdrop"))
            self.assertRegex(r["fg"], r"^(colors|darkColors|lightColors)\.\w+$")

    def test_desktop_label_survives_white_and_black(self):
        # White label text over its shadow core on pure white and on black (and so over the checker, which is both).
        # Ceiling only (shadow core taken as opaque): the rendered contrast is measured by contrast.sh --surfaces desktop.
        label = next(r for r in self.roles if r["id"].startswith("desktop label ("))
        for wp in ((255, 255, 255), (0, 0, 0)):
            for ap in APPEARANCES:
                self.assertGreaterEqual(role_ratio(self.tok, label, ap, 0.25, wp), 4.5)

    def test_menu_bar_tone_roles_are_asserted(self):
        # The adaptive bar is inside gate A2: white text over every wallpaper colour that picks it, black text over every one that picks
        # the dark foreground; neither is exempt, and every wallpaper colour is covered by at least one tone.
        light = next(r for r in self.roles if r["backdrop"] == "bar-light-tone")
        dark = next(r for r in self.roles if r["backdrop"] == "bar-dark-tone")
        for role in (light, dark):
            self.assertNotIn("exempt", role)
            self.assertGreaterEqual(min(r for r, _ in self.table[role["id"]].values()), THRESHOLD[role["kind"]], role["id"])
        self.assertLess(self.tok.path("menubar.toneLightBelow"), self.tok.path("menubar.toneDarkAbove"))
        for wp in WALLPAPER_COLORS:
            covered = [role_ratio(self.tok, r, "dark", 0.25, wp) for r in (light, dark)]
            self.assertTrue(any(c is not None for c in covered), "no tone for wallpaper %s" % (wp,))
        # Glyphs (icons) are held to the same ratio by the text roles; the thresholds follow from the pure foregrounds.
        self.assertEqual(self.tok.color("darkColors", "dark", "barText"), (255, 255, 255))
        self.assertEqual(self.tok.color("lightColors", "dark", "barText"), (0, 0, 0))

    def test_selection_highlight_text_both_appearances(self):
        accent = next(r for r in self.roles if r["id"] == "accent text on accent")
        for ap in APPEARANCES:
            self.assertGreaterEqual(role_ratio(self.tok, accent, ap, 0.25, (255, 255, 255)), 4.5)

    def test_files_tag_dots_are_identifiable(self):
        # Graphics need 3:1 (WCAG 1.4.11). A tag dot is identifiable when its fill or its edge (the colour darkened by
        # files.tagDotOutlineDarker, as Qt.darker does: HSV value divided by the factor) reaches 3:1 against the opaque
        # Files window colour (TagDots.qml). Yellow, orange and green fills alone fail in the light appearance.
        import colorsys
        factor = self.tok.path("files.tagDotOutlineDarker")
        for ap in APPEARANCES:
            window = self.tok.color("colors", ap, "materialTint")
            for name in ("Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"):
                fill = hex_rgb(self.tok.path("files.tag" + name))
                h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in fill))
                edge = tuple(c * 255 for c in colorsys.hsv_to_rgb(h, s, v / factor))
                best = max(wcag(fill, window), wcag(edge, window))
                self.assertGreaterEqual(best, 3.0, "%s dot in the %s appearance: %.2f:1" % (name, ap, best))
                if ap == "light":
                    self.assertGreaterEqual(wcag(edge, window), 3.0, "%s edge on the light window" % name)

    def test_swatch_mark_on_every_tag_colour(self):
        mark = hex_rgb(self.tok.path("menu.swatchMark"))
        for name in ("Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"):
            self.assertGreaterEqual(wcag(mark, hex_rgb(self.tok.path("files.tag" + name))), 3.0, name)


if __name__ == "__main__":
    _tok = Tokens(load_tokens())
    _roles = load_roles()
    print_table(_tok, _roles, role_table(_tok, _roles))
    if "--table" in sys.argv:
        sys.exit(0)
    unittest.main(verbosity=1, argv=[sys.argv[0]])
