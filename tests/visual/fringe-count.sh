#!/usr/bin/env bash
# Colour fringes of text: how many pixels of a region have an RGB channel spread (max - min) above a threshold. Grayscale text
# on a gray background has none; RGB subpixel text has orange/blue edges. The count of the visual audit 2026-10-25 section 2.
#   tests/visual/fringe-count.sh IMAGE.png X Y W H [THRESHOLD=40]   -> "<count>/<pixels>"
# The region must lie inside the image (exit 2 otherwise). The PPM header is read by fields and exactly W*H*3 raster bytes are
# taken: a pixel whose first byte is a blank (32, 32, 32 is gray) is not part of the header.
set -euo pipefail
img=${1:?image} x=${2:?x} y=${3:?y} w=${4:?w} h=${5:?h} thr=${6:-40}
[[ -s $img ]] || { echo "fringe-count: missing or empty $img" >&2; exit 2; }
magick "$img" -alpha off -crop "${w}x${h}+${x}+${y}" +repage -depth 8 ppm:- | python3 -I -c '
import sys
data = sys.stdin.buffer.read()
want_w, want_h, thr = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
pos = 0
def token():
    global pos
    while pos < len(data) and (data[pos] in b" \t\r\n" or data[pos] == 0x23):
        if data[pos] == 0x23:                       # a comment runs to the end of the line
            while pos < len(data) and data[pos] != 0x0A:
                pos += 1
        else:
            pos += 1
    start = pos
    while pos < len(data) and data[pos] not in b" \t\r\n":
        pos += 1
    return data[start:pos]
if token() != b"P6":
    sys.exit("fringe-count: not a binary PPM")
w, h, maxval = int(token()), int(token()), int(token())
pos += 1                                            # exactly one whitespace byte, then the raster
pix = data[pos:pos + w * h * 3]
if maxval != 255 or len(pix) != w * h * 3:
    sys.exit("fringe-count: unexpected PPM (maxval %d, %d raster bytes for %dx%d)" % (maxval, len(pix), w, h))
if (w, h) != (want_w, want_h):
    sys.exit("fringe-count: the region %dx%d is not inside the image (got %dx%d)" % (want_w, want_h, w, h))
n = sum(1 for i in range(0, w * h * 3, 3) if max(pix[i:i + 3]) - min(pix[i:i + 3]) > thr)
print("%d/%d" % (n, w * h))
' "$w" "$h" "$thr"
