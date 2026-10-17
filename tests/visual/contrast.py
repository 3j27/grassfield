#!/usr/bin/env python3
"""WCAG contrast check on GF-REF screenshots (gate A2). Standard library + ImageMagick only.

  contrast.py gen DIR                      write the five worst-case wallpapers (1920x1080 PNG) into DIR
  contrast.py measure DIR [--regions F]    measure DIR/<wallpaper>__<appearance>__<transparency>/<surface>.png
                                           against tests/visual/contrast-regions.json, print the table,
                                           write DIR/contrast.csv, exit 1 when a cell is below its threshold

Method (per region box of a known text item or icon, see contrast-regions.json):
  background luminance = median luminance of the box (text covers a minority of the pixels);
  foreground luminance = mean luminance of the 2% of pixels farthest from the median, on the side (lighter or
  darker) with the largest deviation, i.e. the fully covered glyph pixels (antialiased edge pixels excluded);
  contrast = (L1 + 0.05) / (L2 + 0.05) with WCAG relative luminance.
Thresholds: kind "text" >= 4.5, kind "large" (large text) and "icon" >= 3.0.
"""
import argparse
import csv
import json
import os
import random
import re
import struct
import subprocess
import sys
import zlib

W, H = 1920, 1080
THRESHOLD = {"text": 4.5, "large": 3.0, "icon": 3.0}
WALLPAPERS = ["white", "black", "gray", "noise", "checker"]
HERE = os.path.dirname(os.path.abspath(__file__))


# ---- wallpapers ---------------------------------------------------------------------------------

def write_png(path, rows):
    """rows: iterable of H bytes objects of W*3 bytes (RGB8)."""
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def gen(outdir):
    os.makedirs(outdir, exist_ok=True)
    solid = lambda rgb: (bytes(rgb) * W for _ in range(H))
    write_png(os.path.join(outdir, "white.png"), solid((255, 255, 255)))
    write_png(os.path.join(outdir, "black.png"), solid((0, 0, 0)))
    write_png(os.path.join(outdir, "gray.png"), solid((128, 128, 128)))
    # Saturated yellow/green noise: per-pixel random pick between a saturated yellow and a saturated green.
    rnd = random.Random(20261017)
    palette = [bytes((255, 235, 0)), bytes((0, 200, 40)), bytes((200, 255, 0)), bytes((0, 150, 0))]
    write_png(os.path.join(outdir, "noise.png"),
              (b"".join(palette[rnd.randrange(4)] for _ in range(W)) for _ in range(H)))
    # High-frequency checker: 2x2 black/white cells.
    even = (b"\xff\xff\xff" * 2 + b"\x00\x00\x00" * 2) * (W // 4)
    odd = (b"\x00\x00\x00" * 2 + b"\xff\xff\xff" * 2) * (W // 4)
    write_png(os.path.join(outdir, "checker.png"),
              ((even if (y // 2) % 2 == 0 else odd) for y in range(H)))
    print("wallpapers written to", outdir)


# ---- measurement --------------------------------------------------------------------------------

def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


PIX = re.compile(r"\((\d+),\s*(\d+),\s*(\d+)")


def region_pixels(png, box):
    x, y, w, h = box
    out = subprocess.run(
        ["magick", png, "-alpha", "off", "-crop", f"{w}x{h}+{x}+{y}", "+repage", "-depth", "8", "txt:-"],
        capture_output=True, text=True, check=True).stdout
    pixels = [tuple(int(v) for v in m.groups()) for m in PIX.finditer(out)]
    if not pixels:
        raise RuntimeError(f"empty region {box} in {png}")
    return pixels


def ratio(l1, l2):
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def measure_region(png, box):
    lums = sorted(luminance(p) for p in region_pixels(png, box))
    n = len(lums)
    med = lums[n // 2]
    k = max(3, n // 50)
    lighter = lums[-1] - med >= med - lums[0]
    fg = sum(lums[-k:] if lighter else lums[:k]) / k
    return ratio(fg, med)


def measure(root, regions_file):
    with open(regions_file) as f:
        spec = json.load(f)
    combos = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and "__" in d)
    order = [f"{wp}__{ap}__{tr}" for wp in WALLPAPERS for ap in ("light", "dark") for tr in ("0.25", "0.6")]
    combos = [c for c in order if c in combos] + [c for c in combos if c not in order]
    if not combos:
        sys.exit("contrast: no <wallpaper>__<appearance>__<transparency> directories in " + root)
    short = lambda c: "%s.%s.%s" % (c.split("__")[0][:2], c.split("__")[1][0], c.split("__")[2].replace("0.", ""))
    rows, fails = [], []
    for surface, regions in spec["surfaces"].items():
        for reg in regions:
            thr = THRESHOLD[reg["kind"]]
            vals = []
            for c in combos:
                png = os.path.join(root, c, surface + ".png")
                if not os.path.exists(png):
                    vals.append(None)
                    continue
                v = measure_region(png, reg["box"])
                vals.append(v)
                if v < thr:
                    fails.append((surface, reg["name"], c, v, thr))
            rows.append((surface, reg["name"], reg["kind"], thr, vals))
    # Table.
    head = "%-34s %-5s %4s " % ("surface/region", "kind", "min") + " ".join("%5s" % short(c) for c in combos)
    print(head)
    print("-" * len(head))
    for surface, name, kind, thr, vals in rows:
        present = [v for v in vals if v is not None]
        lo = min(present) if present else float("nan")
        cells = " ".join(("%5s" % "-") if v is None else ("%4.1f%s" % (v, "*" if v < thr else " ")) for v in vals)
        print("%-34s %-5s %4.1f %s" % ((surface + "/" + name)[:34], kind, lo, cells))
    with open(os.path.join(root, "contrast.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["surface", "region", "kind", "threshold"] + combos)
        for surface, name, kind, thr, vals in rows:
            wr.writerow([surface, name, kind, thr] + ["" if v is None else "%.2f" % v for v in vals])
    total = sum(1 for r in rows for v in r[4] if v is not None)
    print("\n'*' = below threshold (text 4.5, large/icon 3.0). Columns: wallpaper(2 letters).appearance(l/d).transparency(25/6).")
    print("cells: %d, FAIL: %d, PASS: %d" % (total, len(fails), total - len(fails)))
    by_combo = {}
    for s, n, c, v, t in fails:
        by_combo.setdefault(c, []).append("%s/%s %.2f<%.1f" % (s, n, v, t))
    for c, items in by_combo.items():
        print("FAIL %s: %s" % (c, "; ".join(items)))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("dir")
    m = sub.add_parser("measure")
    m.add_argument("dir")
    m.add_argument("--regions", default=os.path.join(HERE, "contrast-regions.json"))
    a = ap.parse_args()
    if a.cmd == "gen":
        gen(a.dir)
        return 0
    return measure(a.dir, a.regions)


if __name__ == "__main__":
    sys.exit(main())
