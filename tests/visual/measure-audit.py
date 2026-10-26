"""Contrast measured on the visual-audit captures (boxes are for the 1920x1080 nested capture).

    python3 tests/visual/measure-audit.py light|dark      reads .dev/f1-audit/ (tests/visual/f1-audit.sh) or .dev/f1-audit-dark/
                                                          (tests/shell/audit_dark_nested.sh); run from the repository root.
"""
import importlib.util, os, sys
from collections import Counter

spec = importlib.util.spec_from_file_location("contrast", os.path.join(os.path.dirname(os.path.abspath(__file__)), "contrast.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

ap = sys.argv[1]
d = ".dev/f1-audit" if ap == "light" else ".dev/f1-audit-dark"


def region(png, box):
    w, h, buf = c.read_rgb(os.path.join(d, png))
    return c.crop(buf, w, h, box)


def text_ratio(png, box, label):
    px = region(png, box)
    bg = Counter(px).most_common(1)[0][0]
    ink = max(px, key=lambda p: abs(c.luminance(p) - c.luminance(bg)))
    print("%-52s bg %s ink %s  %.2f:1" % (label, bg, ink, c.ratio(c.luminance(ink), c.luminance(bg))))


def pair(png, box1, box2, label):
    a = Counter(region(png, box1)).most_common(1)[0][0]
    b = Counter(region(png, box2)).most_common(1)[0][0]
    print("%-52s %s vs %s  %.2f:1" % (label, a, b, c.ratio(c.luminance(a), c.luminance(b))))


text_ratio("settings.en.png", [645, 253, 55, 15], "Settings sidebar Search placeholder (textSecondary on 14 % fill)")
text_ratio("settings.en.png", [850, 271, 220, 30], "Settings row subtitle (windowSecondary on group)")
text_ratio("settings.en.png", [850, 316, 80, 16], "Settings group caption (windowSecondary on window)")
text_ratio("settings.en.png", [850, 410, 420, 30], "Settings footnote (windowSecondary on window)")
pair("settings.en.png", [1230, 252, 30, 4], [1232, 292, 30, 4], "Settings group fill vs window (light 3 %, macOS look)")
pair("controlcenter.en.png", [1660, 312, 80, 3], [1800, 312, 50, 3], "Quick Settings Display slider: fill vs track")
pair("controlcenter.en.png", [1670, 388, 60, 3], [1790, 388, 40, 3], "Quick Settings Sound slider: fill vs track")
pair("controlcenter.en.png", [1655, 312, 40, 3], [1625, 322, 20, 3], "Quick Settings track vs module")
text_ratio("files.en.png", [0, 0, 1, 1], "(files: placeholder/tab boxes below)")


def bbox(png, box, label, thresh=60):
    x0, y0, w, h = box
    px = region(png, box)
    bg = Counter(px).most_common(1)[0][0]
    xs, ys = [], []
    for i, p in enumerate(px):
        if sum(abs(p[k] - bg[k]) for k in range(3)) > thresh:
            xs.append(x0 + i % w)
            ys.append(y0 + i // w)
    if xs:
        print("%-52s x %d..%d (w %d) y %d..%d (h %d)" % (label, min(xs), max(xs), max(xs) - min(xs) + 1, min(ys), max(ys), max(ys) - min(ys) + 1))


text_ratio("files.en.png", [1250, 254, 50, 14], "Files toolbar search placeholder (textSecondary on 14 % fill)")
bbox("settings.en.png", [30, 2, 40, 20], "menu bar: app name left ink")
bbox("settings.en.png", [14, 2, 28, 20], "menu bar: system mark")
bbox("settings.en.png", [1672, 2, 28, 20], "menu bar: volume glyph")
bbox("settings.en.png", [1636, 2, 30, 20], "menu bar: Wi-Fi glyph")
bbox("search.en.png", [700, 150, 560, 120], "search panel: first rows ink (see sizes below)")


def bright(png, box, label, level=170):
    x0, y0, w, h = box
    px = region(png, box)
    xs, ys = [], []
    for i, p in enumerate(px):
        if min(p) >= level:
            xs.append(x0 + i % w)
            ys.append(y0 + i // w)
    if xs:
        print("%-52s x %d..%d (w %d) y %d..%d (h %d)" % (label, min(xs), max(xs), max(xs) - min(xs) + 1, min(ys), max(ys), max(ys) - min(ys) + 1))
    else:
        print(label, "nothing")


print("--- bright ink of the menu bar (white text on the dark wallpaper) ---")
bright("settings.en.png", [14, 1, 36, 22], "system mark")
bright("settings.en.png", [40, 1, 40, 22], "app name (left edge)")
bright("settings.en.png", [1672, 1, 28, 22], "volume glyph")
bright("settings.en.png", [1636, 1, 32, 22], "Wi-Fi glyph")
bright("settings.en.png", [1705, 1, 36, 22], "search glyph")
bright("settings.en.png", [1775, 1, 130, 22], "clock text")


def dark(png, box, label, level=110):
    x0, y0, w, h = box
    px = region(png, box)
    xs = [x0 + i % w for i, p in enumerate(px) if max(p) <= level]
    ys = [y0 + i // w for i, p in enumerate(px) if max(p) <= level]
    print("%-52s x %d..%d  y %d..%d" % (label, min(xs), max(xs), min(ys), max(ys)) if xs else label + " nothing")


print("--- Search (panel left edge 640): ink of the second row's text and the query ---")
dark("search.en.png", [695, 366, 160, 40], "row 2 title+subtitle ink")
dark("search.en.png", [690, 250, 100, 32], "query ink")
