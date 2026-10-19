#!/usr/bin/env python3
"""Measures the contrast of a plain symbol against its folder (gate A2, icons >= 3:1) on the captures of
tests/visual/folder-glyphs.sh. Standard library + ImageMagick only.

  folder_glyph_contrast.py DIR [LANG]

For each appearance and mode DIR holds fg-symbol-<appearance>-<mode>.<lang>.png (the symbol) and fg-nothing-<same>.<lang>.png
(the same folders without it). Method: the folder without the symbol gives the plate (mean colour under the symbol box);
the pixels that differ from it are the symbol; its colour is the median of the 25 % of those pixels that differ most
(the antialiased edge is not the colour); the WCAG ratio of that colour against the plate is the cell. Exit 1 when a
cell is below 3.0 or has no symbol. The fixtures: the twelve folders of folder-glyphs.sh, in the icon view of the
reference window (cell pitch 118 x 112, 64 px icons, symbol centre 0.62 of the icon height).
"""
import os
import subprocess
import sys

NAMES = ["01 Theme", "02 Accent", "03 Red", "04 Orange", "05 Yellow", "06 Green", "07 Blue", "08 Purple", "09 Gray",
         "10 White", "11 Black", "12 Lemon"]
X0, PITCH_X = 751, 118          # centre of the first icon, pitch
Y0, PITCH_Y = 331, 112          # centre of the first icon row, pitch
SIZE = 64
GLYPH_CENTER_Y = 0.62
GLYPH_SCALE = 0.34
MIN = 3.0


def pixels(path, x, y, w, h):
    raw = subprocess.run(["magick", path, "-crop", f"{w}x{h}+{x}+{y}", "+repage", "-depth", "8", "rgb:-"],
                         check=True, capture_output=True).stdout
    return [tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)]


def lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = (lin(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


SYS_SCALE = 0.72   # iconMode.sysGlyphScale: in an icon mode the folder (no plate of its own) shrinks onto the system plate


def box(index, mode="default"):
    col, row = index % 6, index // 6
    cx = X0 + col * PITCH_X
    top = Y0 - SIZE // 2 + row * PITCH_Y
    k = 1.0 if mode == "default" else SYS_SCALE
    half = int(SIZE * GLYPH_SCALE * k * 0.5)
    return cx - half, int(top + SIZE * (0.5 + (GLYPH_CENTER_Y - 0.5) * k)) - half, 2 * half, 2 * half


# The desktop (fgd-* captures of folder-glyphs-desktop.sh, which leaves only the twelve folders there): icons flow down the right
# edge, one column of 8 after the other towards the left, sorted by name (01..08, then 09..12).
DESK_X = (1848, 1736)   # icon centres of the right and the next column
DESK_Y0, DESK_PITCH = 80, 112


def desk_box(index, mode="default"):
    slot = index
    cx = DESK_X[slot // 8]
    cy = DESK_Y0 + (slot % 8) * DESK_PITCH
    k = 1.0 if mode == "default" else SYS_SCALE
    half = int(SIZE * GLYPH_SCALE * k * 0.5)
    return cx - half, int(cy - SIZE / 2 + SIZE * (0.5 + (GLYPH_CENTER_Y - 0.5) * k)) - half, 2 * half, 2 * half


def measure(symbol, plain, mode="default", boxes=None):
    boxes = boxes or box
    results = []
    for i, name in enumerate(NAMES):
        x, y, w, h = boxes(i, mode)
        a = pixels(symbol, x, y, w, h)
        b = pixels(plain, x, y, w, h)
        plate = tuple(sum(p[k] for p in b) / len(b) for k in range(3))
        diffs = sorted(((sum(abs(p[k] - q[k]) for k in range(3)), p) for p, q in zip(a, b)), reverse=True)
        strong = [p for d, p in diffs[:max(1, len(diffs) // 4)] if d > 24]
        if not strong:
            results.append((name, None, plate, None))
            continue
        strong.sort(key=lambda p: lum(p))
        glyph = strong[len(strong) // 2]
        results.append((name, ratio(glyph, plate), plate, glyph))
    return results


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = sys.argv[1]
    lang = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else "en"
    if "--desktop" in sys.argv:
        return main_desktop(d, lang)
    failed = False
    for appearance in ("dark", "light"):
        for mode in ("default", "dark", "clear", "tinted"):
            sym = os.path.join(d, f"fg-symbol-{appearance}-{mode}.{lang}.png")
            non = os.path.join(d, f"fg-nothing-{appearance}-{mode}.{lang}.png")
            if not (os.path.exists(sym) and os.path.exists(non)):
                continue
            print(f"== {appearance} / {mode}")
            for name, r, plate, glyph in measure(sym, non, mode):
                plate_s = "#%02x%02x%02x" % tuple(int(round(v)) for v in plate)
                if r is None:
                    print(f"  {name:10s} NO SYMBOL (plate {plate_s})")
                    failed = True
                    continue
                glyph_s = "#%02x%02x%02x" % glyph
                flag = "ok" if r >= MIN else "FAIL"
                if r < MIN:
                    failed = True
                print(f"  {name:10s} {r:5.2f}:1  symbol {glyph_s} on plate {plate_s}  {flag}")
    return 1 if failed else 0


def main_desktop(d, lang):
    failed = False
    cells = 0
    for appearance in ("dark", "light"):
        for mode in ("default", "dark", "clear", "tinted"):
            for wall in ("artwork", "black", "white"):
                sym = os.path.join(d, f"fgd-symbol-{appearance}-{mode}-{wall}.{lang}.png")
                non = os.path.join(d, f"fgd-nothing-{appearance}-{mode}-{wall}.{lang}.png")
                if not (os.path.exists(sym) and os.path.exists(non)):
                    continue
                print(f"== desktop {appearance} / {mode} / {wall}")
                for name, r, plate, glyph in measure(sym, non, mode, desk_box):
                    cells += 1
                    plate_s = "#%02x%02x%02x" % tuple(int(round(v)) for v in plate)
                    if r is None:
                        print(f"  {name:10s} NO SYMBOL (plate {plate_s})")
                        failed = True
                        continue
                    flag = "ok" if r >= MIN else "FAIL"
                    failed = failed or r < MIN
                    print(f"  {name:10s} {r:5.2f}:1  symbol #%02x%02x%02x on plate {plate_s}  {flag}" % glyph)
    print(f"{cells} cells")
    return 1 if failed or cells == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
