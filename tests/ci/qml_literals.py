#!/usr/bin/env python3
"""Tokens only: no literal design value in the QML (CLAUDE.md "tokens only, no hardcoded values"; ADR-0039 step 2, rule 6).

  python3 -I tests/ci/qml_literals.py             scan the tree, exit 1 on any literal outside the allowlist
  python3 -I tests/ci/qml_literals.py --selftest  the scanner on fixed samples

Scanned: every .qml file of ui/Grassfield/ (Tokens.qml, generated from ui/tokens/tokens.json, excepted), shell/ (shell/security/
included: it is read, never changed) and apps/. A literal is a number written where a token belongs:
  radius      `radius: 6`
  font        `font.pixelSize: 13`, `font.pointSize`, `font.letterSpacing`, `lineHeight`
  duration    an animation's `duration: 120`
  opacity     `opacity: 0.5` (0 and 1 are states, not values)
  geometry    margins, offsets, spacing, width, height and their implicit forms, padding, x, y, border.width
  colour      "#rrggbb", Qt.rgba/hsla/hsva/rgb of literal numbers, a named colour on color / border.color ("transparent" is
              not a colour)
Values from -1 to 1 are allowed for numbers (a hairline, a flag, an off state). `Timer.interval` is not counted: debounces, polls
and retries are logic, not design (ADR-0039 D7); a timing the user perceives belongs in a token by review, not by this scan.
Token arithmetic (`Tokens.spacingLg * 3`) is not a literal.

Exceptions: ALLOWED below (a file and how many colour literals it may hold, with the reason), or `literal-ok: <reason>` on the
line for a new, reviewed exception.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("ui/Grassfield", "shell", "apps")
SKIP = {"ui/Grassfield/Ui/Tokens.qml"}
MARK = re.compile(r"literal-ok:\s*\S.{8,}")
NUM = r"(-?[0-9]+(?:\.[0-9]+)?)"
END = r"\s*(?:$|;|//|\})"
PROPS = {
    "radius": r"radius",
    "font": r"font\.(?:pixelSize|pointSize|letterSpacing)|lineHeight",
    "duration": r"duration",
    "opacity": r"opacity",
    "geometry": r"(?:anchors\.)?(?:left|right|top|bottom)?[mM]argins?|(?:anchors\.)?(?:horizontalCenter|verticalCenter)Offset"
                r"|spacing|(?:implicit)?[wW]idth|(?:implicit)?[hH]eight|(?:left|right|top|bottom)?[pP]adding|[xy]|border\.width",
}
NUMBERS = {kind: re.compile(r"(?<![\w.])(?:" + prop + r")\s*:\s*" + NUM + END) for kind, prop in PROPS.items()}
COLOUR = re.compile(r"\"#[0-9A-Fa-f]{3,8}\""
                    r"|Qt\.(?:rgba|hsla|hsva|rgb)\(\s*-?[0-9.]+\s*,\s*-?[0-9.]+\s*,\s*-?[0-9.]+\s*(?:,\s*-?[0-9.]+\s*)?\)"
                    r"|(?<![\w.])(?:color|border\.color)\s*:\s*\"(?!transparent\")[a-z]+\"")

# Colour literals that stay, by file: {path: (how many, why)}. A file holding more fails, so a new literal there is caught too.
ALLOWED = {
    "ui/Grassfield/Ui/GrassfieldArtwork.qml": (8, "the default artwork's own painting (ADR-0040 ID-1 turns it into artwork tokens)"),
    "ui/Grassfield/Ui/Appearance.qml": (3, "the dev-only glyph markers of tests/visual (never drawn in production)"),
    "ui/Grassfield/Ui/TintedIcon.qml": (1, "black as the neutral default of a tint property the host sets"),
    "ui/Grassfield/Ui/IconEffect.qml": (1, "black as the neutral default of a tint property the host sets"),
    "ui/Grassfield/Ui/FolderPlate.qml": (1, "black when no mode tint is set (the plate's own fallback)"),
    "shell/desktop/WallpaperSlot.qml": (1, "black as the neutral default of a colour property the host sets"),
    "shell/saver/SaverSlides.qml": (1, "black as the fill of a prepared slide's empty border (a picture, not UI)"),
    "ui/Grassfield/Ui/WindowGlyph.qml": (1, "black as an ink whose alpha is a token (window.glyphOpacity)"),
    "ui/Grassfield/Ui/WindowLight.qml": (2, "black as an ink whose alpha is a token (window.pressedOpacity, window.lightBorderOpacity)"),
    "ui/Grassfield/Ui/Material.qml": (1, "black as the shadow cut-out mask (a mask, never drawn)"),
}


def code_of(line):
    """The line without a trailing // comment (a // inside a string is kept)."""
    out, quote = [], None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
            out.append(c)
        elif line.startswith("//", i):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def scan_text(text):
    """[(line number, kind, excerpt)] of the literals of one QML source (marked lines excepted)."""
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        if MARK.search(line):
            continue
        code = code_of(line)
        if not code.strip():
            continue
        for kind, rx in NUMBERS.items():
            for m in rx.finditer(code):
                value = float(m.group(1))
                if kind == "opacity" and value not in (0.0, 1.0) or kind != "opacity" and abs(value) > 1:
                    hits.append((number, kind, line.strip()[:120]))
        for _ in COLOUR.finditer(code):
            hits.append((number, "colour", line.strip()[:120]))
    return hits


def files(root):
    for base in ROOTS:
        for dirpath, _dirs, names in os.walk(root / base):
            for name in sorted(names):
                if name.endswith(".qml"):
                    rel = (Path(dirpath) / name).relative_to(root).as_posix()
                    if rel not in SKIP:
                        yield rel


def check(root):
    problems, scanned = [], 0
    for rel in files(root):
        scanned += 1
        hits = scan_text((root / rel).read_text(encoding="utf-8"))
        colours = [h for h in hits if h[1] == "colour"]
        allowed, _why = ALLOWED.get(rel, (0, ""))
        for number, kind, excerpt in hits:
            if kind != "colour":
                problems.append(f"{rel}:{number}: literal {kind}: {excerpt}")
        if len(colours) > allowed:
            for number, _kind, excerpt in colours:
                problems.append(f"{rel}:{number}: literal colour ({len(colours)} in the file, {allowed} allowed): {excerpt}")
    return problems, scanned


SAMPLES = {
    "radius": ("Rectangle { radius: 6 }", 1),
    "font size": ("Text { font.pixelSize: 13 }", 1),
    "animation duration": ("NumberAnimation { duration: 120 }", 1),
    "opacity": ("Item { opacity: 0.5 }", 1),
    "margins": ("Item { anchors.margins: 12 }", 1),
    "left margin": ("Item { anchors.leftMargin: 8 }", 1),
    "width": ("Item { width: 24; height: 24 }", 2),
    "x": ("Item { x: 24 }", 1),
    "border width": ("Rectangle { border.width: 2 }", 1),
    "hex colour": ('Rectangle { color: "#1B1B1F" }', 1),
    "rgba colour": ("Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }", 1),
    "named colour": ('Rectangle { color: "white" }', 1),
    "token": ("Rectangle { radius: Tokens.radiusControl; width: Tokens.spacingLg * 3 }", 0),
    "hairline and states": ('Rectangle { border.width: 1; opacity: 0; height: 1; x: 0; color: "transparent" }', 0),
    "timer": ("Timer { interval: 1500 }", 0),
    "computed rgba": ("Item { property color c: Qt.rgba(t.r, t.g, t.b, 0.5) }", 0),
    "comment": ("Item { // radius: 6 in the old design\n}", 0),
    "marked": ("Rectangle { radius: 7 // literal-ok: concentric with a 12 menu at a 5 inset, see the spec\n}", 0),
    "url with //": ('Image { source: "file:///x.png"; width: 40 }', 1),
}


def selftest():
    bad = 0
    for name, (src, want) in SAMPLES.items():
        got = len(scan_text(src))
        if got != want:
            print(f"selftest FAIL: {name}: want {want}, got {got}: {src!r}")
            bad += 1
    if bad:
        return 1
    print(f"qml_literals selftest: {len(SAMPLES)} cases ok")
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    problems, scanned = check(root)
    if scanned == 0:
        print("qml_literals: no QML file scanned")
        return 1
    if problems:
        print("qml_literals: a design value written as a literal; use a token (or `literal-ok: <reason>` after review):")
        print("\n".join(problems))
        return 1
    print(f"qml_literals: {scanned} QML files, no literal design value ({sum(n for n, _ in ALLOWED.values())} colour literals allowed in {len(ALLOWED)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
