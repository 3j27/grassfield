#!/usr/bin/env python3
"""Check a regenerated cursor theme: check_theme.py THEME_DIR OUTLINE FILL (#rrggbb each).

The hyprcursor manifest names the theme, the archives exist, the XCursor files exist, and the pixels of the arrow
are recoloured: the outline colour and the fill colour are both present, the packaged white and black are not.
Exit 0 and one line on success, 1 and the reasons otherwise.
"""
import os
import struct
import sys

theme, outline, fill = sys.argv[1:4]
problems = []


def rgb(h):
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)


manifest = os.path.join(theme, "manifest.hl")
if not os.path.isfile(manifest):
    problems.append("manifest.hl missing")
else:
    text = open(manifest).read()
    if "name = " + os.path.basename(theme) not in text:
        problems.append("manifest name differs from the folder")
for name in ("default", "pointer", "text"):
    if not os.path.isfile(os.path.join(theme, "hyprcursors", name + ".hlc")):
        problems.append("hyprcursors/" + name + ".hlc missing")
    if not os.path.exists(os.path.join(theme, "cursors", name)):
        problems.append("cursors/" + name + " missing")
if not os.path.isfile(os.path.join(theme, "index.theme")):
    problems.append("index.theme missing")

colors = {}
path = os.path.join(theme, "cursors", "default")
if os.path.isfile(path):
    d = open(path, "rb").read()
    magic, _hdr, _ver, n = struct.unpack("<4s3I", d[:16])
    if magic != b"Xcur":
        problems.append("cursors/default is not an XCursor file")
    for i in range(n):
        _typ, _sub, pos = struct.unpack("<3I", d[16 + 12 * i:28 + 12 * i])
        _, _t2, _nominal, _, w, h, _xh, _yh, _delay = struct.unpack("<9I", d[pos:pos + 36])
        px = d[pos + 36:pos + 36 + w * h * 4]
        for j in range(0, len(px), 4):
            b, g, r, a = px[j:j + 4]
            if a == 255:
                colors[(r, g, b)] = colors.get((r, g, b), 0) + 1


def near(c, want, tol=3):
    return all(abs(x - y) <= tol for x, y in zip(c, want))


def present(want):
    return any(near(c, rgb(want)) for c in colors)


if not colors:
    problems.append("no opaque pixel in cursors/default")
else:
    if not present(outline):
        problems.append("outline colour " + outline + " not in the pixels")
    if not present(fill):
        problems.append("fill colour " + fill + " not in the pixels")
    # The packaged colours must be gone (unless that is what was asked for).
    for packaged in ("#ffffff", "#000000"):
        if packaged not in (outline, fill) and present(packaged):
            problems.append("packaged colour " + packaged + " still in the pixels")

if problems:
    print("FAIL: " + "; ".join(problems))
    sys.exit(1)
print("OK: manifest, archives, XCursor files, outline %s and fill %s in the pixels (%d opaque colours)" % (outline, fill, len(colors)))
