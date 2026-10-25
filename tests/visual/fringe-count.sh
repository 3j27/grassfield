#!/usr/bin/env bash
# Colour fringes of text: how many pixels of a region have an RGB channel spread (max - min) above a threshold. Grayscale text
# on a gray background has none; RGB subpixel text has orange/blue edges. The count of the visual audit 2026-10-25 section 2.
#   tests/visual/fringe-count.sh IMAGE.png X Y W H [THRESHOLD=40]   -> "<count>/<pixels>"
set -euo pipefail
img=${1:?image} x=${2:?x} y=${3:?y} w=${4:?w} h=${5:?h} thr=${6:-40}
[[ -s $img ]] || { echo "fringe-count: missing or empty $img" >&2; exit 2; }
magick "$img" -alpha off -crop "${w}x${h}+${x}+${y}" +repage -depth 8 ppm:- | python3 -I -c '
import sys
data = sys.stdin.buffer.read()
parts = data.split(None, 4)           # P6 W H MAXVAL then one whitespace byte, then the pixels
w, h = int(parts[1]), int(parts[2])
pix = parts[4] if len(parts) > 4 else b""
thr = int(sys.argv[1])
n = sum(1 for i in range(0, w * h * 3, 3) if max(pix[i:i + 3]) - min(pix[i:i + 3]) > thr)
print("%d/%d" % (n, w * h))
' "$thr"
