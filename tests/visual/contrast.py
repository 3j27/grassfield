#!/usr/bin/env python3
"""WCAG contrast check on GF-REF screenshots (gate A2). Standard library + ImageMagick only.

  contrast.py gen DIR                      write the five worst-case wallpapers (1920x1080 PNG) into DIR
  contrast.py measure DIR [--regions F]    measure DIR/<wallpaper>__<appearance>__<transparency>/<surface>*.png
                                           against tests/visual/contrast-regions.json, print the table,
                                           write DIR/contrast.csv, exit 1 when a cell is below its threshold

Method: glyph mask (docs/testing/visual.md). Each surface is captured in four glyph modes (the shell's dev-only
`visual glyphs` IPC, which recolours every text/icon colour and nothing else):
  <surface>.png          normal (A)
  <surface>.hidden.png   glyphs transparent: the exact backdrop behind and around every glyph (B), shadows and
                         outlines of the label included
  <surface>.white.png    glyphs pure white (W)
  <surface>.black.png    glyphs pure black (K)
Per pixel and channel, with coverage alpha: W = alpha*255 + (1-alpha)*B and K = (1-alpha)*B, so W - K = alpha*255
recovers the coverage exactly, whatever the backdrop (objects that do not follow the glyph colour have W = K and
alpha 0). The coverage includes any opacity of the Text item itself (an item at opacity 0.85 never reaches alpha 1).
The glyph colour is the colour that is actually RENDERED, never a declared one. The item's own opacity o is the largest coverage
found in the box (a fully covered pixel shows the item at its opacity). For a glyph pixel (covered at least 0.85 o in every
channel) the colour a full-coverage pixel would have is e = B + o * (A - B) / alpha per channel: it includes the opacity (an item
at opacity 0.85 reads as the faded colour it shows) and uses nearly fully covered pixels only (0.85 o, relaxed for thin text), so
antialiased edges and sub-pixel colour fringes do not count. For each
glyph pixel the WCAG ratio of e against the local backdrop (mean linear luminance of B in the 5x5 window around the pixel: the
eye averages a high-frequency texture) is computed; the cell value is the 5th percentile of those ratios (the worst case, not
a median of extremes). A box without a glyph yields None ("NO GLYPH": box misplaced, surface not open) and FAILS the run; a
missing capture fails the run too.
Thresholds: kind "text" >= 4.5, kind "large" (large text) and "icon" >= 3.0.
"""
import argparse
import csv
import json
import os
import random
import struct
import subprocess
import sys
import zlib

W, H = 1920, 1080
THRESHOLD = {"text": 4.5, "large": 3.0, "icon": 3.0}
WALLPAPERS = ["white", "black", "gray", "noise", "checker"]
# Saturated yellow/green noise wallpaper: the four colours a pixel is drawn from (also the token calculation's bounds).
NOISE_PALETTE = [(255, 235, 0), (0, 200, 40), (200, 255, 0), (0, 150, 0)]
MODES = ("", ".hidden", ".white", ".black")  # file suffixes: A, B, W, K
GLYPH_ALPHA = (0.85, 0.7, 0.5)  # a glyph pixel is covered at least this fraction of the item's opacity in every channel
MIN_PIXELS = 4      # the strictest fraction that leaves this many pixels is used (thin text has few fully covered pixels)
MIN_COVERAGE = 0.2  # an item opacity (largest coverage in the box) below this is no glyph: absent or invisible
PERCENTILE = 0.05
LOCAL = 2  # local backdrop window radius: 5x5 pixels
HERE = os.path.dirname(os.path.abspath(__file__))


# ---- wallpapers ---------------------------------------------------------------------------------

def write_png(path, rows, w=W, h=H):
    """rows: iterable of h bytes objects of w*3 bytes (RGB8)."""
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
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
    palette = [bytes(c) for c in NOISE_PALETTE]
    write_png(os.path.join(outdir, "noise.png"),
              (b"".join(palette[rnd.randrange(4)] for _ in range(W)) for _ in range(H)))
    # High-frequency checker: 2x2 black/white cells.
    even = (b"\xff\xff\xff" * 2 + b"\x00\x00\x00" * 2) * (W // 4)
    odd = (b"\x00\x00\x00" * 2 + b"\xff\xff\xff" * 2) * (W // 4)
    write_png(os.path.join(outdir, "checker.png"),
              ((even if (y // 2) % 2 == 0 else odd) for y in range(H)))
    print("wallpapers written to", outdir)


# ---- pixels -------------------------------------------------------------------------------------

def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def ratio(l1, l2):
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def read_rgb(png):
    """(width, height, raw RGB8 bytes) of a PNG: raw bytes from ImageMagick, exactly 3 per pixel, no text parsing."""
    dims = subprocess.run(["magick", "identify", "-format", "%w %h", png + "[0]"],
                          capture_output=True, text=True, check=True).stdout.split()
    w, h = int(dims[0]), int(dims[1])
    data = subprocess.run(["magick", png, "-alpha", "off", "-depth", "8", "rgb:-"],
                          capture_output=True, check=True).stdout
    if len(data) != w * h * 3:
        raise RuntimeError(f"{png}: {len(data)} bytes, expected {w * h * 3}")
    return w, h, data


def crop(buf, width, height, box):
    """Pixels (r, g, b tuples, row-major) of box [x, y, w, h] in a raw RGB8 buffer of width x height."""
    x, y, w, h = box
    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height:
        raise ValueError(f"box {box} outside the {width}x{height} image")
    out = []
    for row in range(y, y + h):
        base = (row * width + x) * 3
        seg = buf[base:base + w * 3]
        out.extend(zip(seg[0::3], seg[1::3], seg[2::3]))
    return out


# ---- glyph mask measurement -----------------------------------------------------------------------

def coverage(w, k):
    """Glyph coverage alpha of one pixel from the white (w) and black (k) captures. The glyph colours are the
    markers (255,255,254) and (0,0,1): W - K = alpha * (255, 255, 253) per channel, whatever the backdrop."""
    return min(1.0, max(0.0, sum((w[i] - k[i]) / d for i, d in enumerate((255.0, 255.0, 253.0))) / 3))


def local_luminance(ctx, x, y):
    """Mean linear luminance of the backdrop in the 5x5 window around box pixel (x, y); ctx = (pixels, w, h, ox, oy)
    is the hidden capture around the box (pixels row-major, w x h, the box starting at (ox, oy)). The window is
    clipped to the capture."""
    px, cw, ch, ox, oy = ctx
    cx, cy = ox + x, oy + y
    total = n = 0
    for yy in range(max(0, cy - LOCAL), min(ch, cy + LOCAL + 1)):
        for xx in range(max(0, cx - LOCAL), min(cw, cx + LOCAL + 1)):
            total += luminance(px[yy * cw + xx])
            n += 1
    return total / n


def glyph_ratios(a_px, b_px, w_px, k_px, bw, bh, ctx=None):
    """WCAG ratio of the RENDERED glyph colour against the local backdrop (5x5 mean of the hidden capture) for every glyph
    pixel of a box of bw x bh pixels. ctx: wider hidden capture, default the box itself. Empty when the box holds no glyph.

    Per channel i the coverage is a_i = (W_i - K_i) / d_i. The item's own opacity o is the largest coverage found in the box (a
    fully covered pixel shows the item at its opacity): measured from the pixels, never read from a declaration. A glyph pixel is
    one covered at least 0.85 o in every channel (0.7 or 0.5 o when thin text has fewer than MIN_PIXELS such pixels): the text
    renderer's gamma makes a half covered edge pixel unreliable, a nearly covered one exact. Its rendered full-coverage colour is
    e_i = B_i + o * (A_i - B_i) / a_i, including the opacity."""
    ctx = ctx or (b_px, bw, bh, 0, 0)
    dens = (255.0, 255.0, 253.0)
    cov = [tuple(min(1.0, max(0.0, (w[i] - k[i]) / dens[i])) for i in range(3)) for w, k in zip(w_px, k_px)]
    o = max((max(c) for c in cov), default=0.0)
    if o < MIN_COVERAGE:
        return []
    for frac in GLYPH_ALPHA:
        pick = [i for i, c in enumerate(cov) if min(c) >= frac * o]
        if len(pick) >= MIN_PIXELS or frac == GLYPH_ALPHA[-1]:
            break
    out = []
    for idx in pick:
        a, b, c = a_px[idx], b_px[idx], cov[idx]
        e = tuple(min(255.0, max(0.0, b[i] + o * (a[i] - b[i]) / c[i])) for i in range(3))
        out.append(ratio(luminance(e), local_luminance(ctx, idx % bw, idx // bw)))
    return out


def percentile(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(p * len(s)))]


def score(a_px, b_px, w_px, k_px, bw, bh, ctx=None):
    """Worst-case contrast of the glyphs in a box (5th percentile of the per-pixel ratios), None without glyph pixels."""
    ratios = glyph_ratios(a_px, b_px, w_px, k_px, bw, bh, ctx)
    return percentile(ratios, PERCENTILE) if ratios else None


def measure_surface(root_dir, surface, regions):
    """{region name: score or None} for one surface directory; None when the surface was not captured at all."""
    bufs = []
    for suffix in MODES:
        path = os.path.join(root_dir, surface + suffix + ".png")
        if not os.path.exists(path):
            return None
        bufs.append(read_rgb(path))
    if len({(w, h) for w, h, _ in bufs}) != 1:
        raise RuntimeError(f"{root_dir}/{surface}: captures differ in size")
    width, height, _ = bufs[0]
    out = {}
    for reg in regions:
        if reg.get("image"):
            out[reg["name"]] = "skip"
            continue
        x, y, bw, bh = reg["box"]
        px = [crop(b[2], width, height, reg["box"]) for b in bufs]
        wx, wy = max(0, x - LOCAL), max(0, y - LOCAL)
        wx2, wy2 = min(width, x + bw + LOCAL), min(height, y + bh + LOCAL)
        wide = crop(bufs[1][2], width, height, (wx, wy, wx2 - wx, wy2 - wy))
        out[reg["name"]] = score(*px, bw, bh, (wide, wx2 - wx, wy2 - wy, x - wx, y - wy))
    return out


def measure(root, regions_file, only=None):
    with open(regions_file) as f:
        spec = json.load(f)
    if only:
        spec["surfaces"] = {k: v for k, v in spec["surfaces"].items() if k in only}
    combos = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and "__" in d)
    order = [f"{wp}__{ap}__{tr}" for wp in WALLPAPERS for ap in ("light", "dark") for tr in ("0.25", "0.6")]
    combos = [c for c in order if c in combos] + [c for c in combos if c not in order]
    if not combos:
        sys.exit("contrast: no <wallpaper>__<appearance>__<transparency> directories in " + root)
    short = lambda c: "%s.%s.%s" % (c.split("__")[0][:2], c.split("__")[1][0], c.split("__")[2].replace("0.", ""))
    results = {}  # (surface, region, combo) -> value
    missing = []  # (surface, combo): a capture mode is absent (the surface was never captured): FAIL
    for surface, regions in spec["surfaces"].items():
        for c in combos:
            res = measure_surface(os.path.join(root, c), surface, regions)
            if res is None:
                missing.append((surface, c))
            else:
                for name, v in res.items():
                    results[(surface, name, c)] = v
    rows, fails, nomask, skipped = [], [], [], 0
    for surface, regions in spec["surfaces"].items():
        for reg in regions:
            thr = THRESHOLD[reg["kind"]]
            vals = []
            for c in combos:
                v = results.get((surface, reg["name"], c))
                vals.append(v)
                if v == "skip":
                    skipped += 1
                elif v is None and (surface, reg["name"], c) in results:
                    nomask.append((surface, reg["name"], c))
                elif isinstance(v, float) and v < thr:
                    fails.append((surface, reg["name"], c, v, thr))
            rows.append((surface, reg["name"], reg["kind"], thr, vals))

    def cell(v, thr):
        if v is None:
            return "%5s" % "-"
        if v == "skip":
            return "%5s" % "skip"
        return "%4.1f%s" % (v, "*" if v < thr else " ")

    present_of = lambda vals: [v for v in vals if isinstance(v, float)]
    head = "%-34s %-5s %4s " % ("surface/region", "kind", "min") + " ".join("%5s" % short(c) for c in combos)
    print(head)
    print("-" * len(head))
    for surface, name, kind, thr, vals in rows:
        present = present_of(vals)
        lo = min(present) if present else float("nan")
        cells = " ".join(cell(v, thr) for v in vals)
        print("%-34s %-5s %4.1f %s" % ((surface + "/" + name)[:34], kind, lo, cells))
    with open(os.path.join(root, "contrast.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["surface", "region", "kind", "threshold"] + combos)
        for surface, name, kind, thr, vals in rows:
            wr.writerow([surface, name, kind, thr] +
                        [("%.2f" % v) if isinstance(v, float) else ("" if v is None else v) for v in vals])
    total = sum(1 for r in rows for v in r[4] if isinstance(v, float))
    print("\n'*' = below threshold (text 4.5, large/icon 3.0); '-' = no capture; 'skip' = image icon (not colour-driven)."
          " Columns: wallpaper(2 letters).appearance(l/d).transparency(25/6).")
    print("cells: %d, FAIL: %d, PASS: %d, no glyph found (FAIL): %d, missing captures (FAIL): %d, skipped (image icons): %d"
          % (total, len(fails), total - len(fails), len(nomask), len(missing), skipped))
    by_region = {}
    for s, n, c, v, t in fails:
        by_region.setdefault((s, n), []).append((c, v))
    print("FAIL by region (failing cells, minimum):")
    for (s, n), items in sorted(by_region.items(), key=lambda kv: -len(kv[1])):
        print("  %-40s %2d cells, min %.2f" % (s + "/" + n, len(items), min(v for _, v in items)))
    for s, n, c in nomask:
        print("NO GLYPH %s/%s in %s" % (s, n, c))
    for s, c in missing:
        print("MISSING CAPTURE %s in %s" % (s, c))
    return 1 if fails or nomask or missing else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("dir")
    m = sub.add_parser("measure")
    m.add_argument("dir")
    m.add_argument("--regions", default=os.path.join(HERE, "contrast-regions.json"))
    m.add_argument("--surfaces", default="", help="comma list: measure only these surfaces")
    a = ap.parse_args()
    if a.cmd == "gen":
        gen(a.dir)
        return 0
    return measure(a.dir, a.regions, [x for x in a.surfaces.split(",") if x] or None)


if __name__ == "__main__":
    sys.exit(main())
