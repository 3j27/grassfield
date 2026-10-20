#!/usr/bin/env python3
"""Shape of a minimize animation frame (tests/compositor/genie.sh).

Usage: genie_shape.py FRAME.ppm REFERENCE.ppm X Y W H LIMIT_Y

FRAME is a capture taken during the animation, REFERENCE the same output without the window (after the minimize).
X Y W H is the window's box on that output (titlebar included), LIMIT_Y the first row not analysed (the top of the
Dock: the minimized tile appears there). The pixels that differ from REFERENCE inside the window's box widened by 40 px
form the animation's footprint. Its width near the top and near the bottom of the footprint classifies the frame:

  genie  the top is at least 1.6 times wider than the bottom (the window narrows toward the Dock)
  rect   top and bottom widths within 25 % of each other (a uniform scale, or a fade in place)
  none   no footprint (fewer than 12 rows differ)
  other  anything else

Prints one JSON object: class, footprint top/bottom rows and left/right extents, widths, ratio.
"""

import json
import sys

DIFF_THRESHOLD = 24  # sum of |dR|+|dG|+|dB| for a pixel to count (lossless captures of a static wallpaper)
MIN_ROW_PIXELS = 4  # a row belongs to the footprint with at least this many differing pixels
MIN_ROWS = 12
MAX_GAP = 3
MARGIN = 40


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            while data[pos : pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b"P6" or int(fields[3]) != 255:
        raise ValueError(f"{path}: not an 8-bit P6 image")
    width, height = int(fields[1]), int(fields[2])
    pixels = data[pos + 1 : pos + 1 + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError(f"{path}: truncated")
    return width, height, pixels


def row_extent(frame, ref, width, y, x0, x1):
    left = right = None
    count = 0
    base = y * width * 3
    for x in range(x0, x1):
        i = base + x * 3
        d = abs(frame[i] - ref[i]) + abs(frame[i + 1] - ref[i + 1]) + abs(frame[i + 2] - ref[i + 2])
        if d > DIFF_THRESHOLD:
            count += 1
            if left is None:
                left = x
            right = x
    return count, left, right


def median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else 0


def main(argv):
    if len(argv) != 8:
        print(__doc__, file=sys.stderr)
        return 2
    fw, fh, frame = read_ppm(argv[1])
    rw, rh, ref = read_ppm(argv[2])
    if (fw, fh) != (rw, rh):
        print(json.dumps({"class": "error", "reason": "size mismatch"}))
        return 1
    x, y, w, h, limit = (int(float(v)) for v in argv[3:8])
    x0, x1 = max(0, x - MARGIN), min(fw, x + w + MARGIN)
    y0, y1 = max(0, y - MARGIN), min(fh, limit)

    found = []
    for row in range(y0, y1):
        count, left, right = row_extent(frame, ref, fw, row, x0, x1)
        if count >= MIN_ROW_PIXELS:
            found.append((row, left, right))
    # The footprint is the tallest run of rows (gaps up to MAX_GAP rows): stray differences elsewhere (the Dock's
    # magnification or tooltip under the pointer) are left out.
    runs, current = [], []
    for r in found:
        if current and r[0] - current[-1][0] > MAX_GAP + 1:
            runs.append(current)
            current = []
        current.append(r)
    if current:
        runs.append(current)
    rows = max(runs, key=len) if runs else []
    out = {"rows": len(rows)}
    if len(rows) < MIN_ROWS:
        out["class"] = "none"
        print(json.dumps(out))
        return 0

    top, bottom = rows[0][0], rows[-1][0]
    span = bottom - top + 1
    # Widths over a band of rows at 10-20 % and 80-90 % of the footprint's height (robust to a ragged edge).
    def band(lo, hi):
        return [r[2] - r[1] + 1 for r in rows if top + lo * span <= r[0] <= top + hi * span]

    w_top, w_bottom = median(band(0.10, 0.20)), median(band(0.80, 0.90))
    ratio = w_top / w_bottom if w_bottom > 0 else 0.0
    if ratio >= 1.6:
        kind = "genie"
    elif 0.8 <= ratio <= 1.25:
        kind = "rect"
    else:
        kind = "other"
    out.update(
        {
            "class": kind,
            "top": top,
            "bottom": bottom,
            "left": min(r[1] for r in rows),
            "right": max(r[2] for r in rows),
            "widthTop": w_top,
            "widthBottom": w_bottom,
            "ratio": round(ratio, 2),
        }
    )
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
