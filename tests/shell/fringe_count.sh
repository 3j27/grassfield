#!/usr/bin/env bash
# tests/visual/fringe-count.sh reads the PPM that ImageMagick prints by its header fields and takes exactly the raster: gray
# pixels whose bytes are blanks (32), newlines (10), carriage returns (13) or '#' (35) must neither shift the raster nor end up in
# the header (the first version split the stream on whitespace and ate them).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/fringe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
if ! command -v magick >/dev/null; then
  echo "SKIP: fringe-count needs ImageMagick"
  exit 0
fi
python3 -I - "$tmp" <<'PY'
import sys
d = sys.argv[1]
def ppm(path, w, h, pixels):
    open(path, "wb").write(b"P6\n%d %d\n255\n" % (w, h) + b"".join(bytes(p) for p in pixels))
# first pixel (32,32,32): the byte after the header is a blank. Fringes: red and green (2 of 6).
ppm(d + "/a.ppm", 3, 2, [(32, 32, 32), (255, 0, 0), (10, 10, 10), (13, 13, 13), (35, 35, 35), (0, 200, 0)])
# all gray, awkward bytes: no fringe
ppm(d + "/b.ppm", 2, 2, [(32, 32, 32), (10, 10, 10), (13, 13, 13), (35, 35, 35)])
# a fringe pixel exactly at the threshold (40) and one above (41): only the second counts
ppm(d + "/c.ppm", 2, 1, [(100, 100, 140), (100, 100, 141)])
PY
for n in a b c; do magick "$tmp/$n.ppm" "$tmp/$n.png"; done
count() { "$root/tests/visual/fringe-count.sh" "$@"; }
desc="a gray pixel of blank bytes first does not shift the raster: 2 fringes of 6"
check test "$(count "$tmp/a.png" 0 0 3 2)" = "2/6"
desc="a region inside the image counts only its pixels (the second column: 1 fringe of 2)"
check test "$(count "$tmp/a.png" 1 0 1 2)" = "1/2"
desc="gray pixels of whitespace and '#' bytes: no fringe"
check test "$(count "$tmp/b.png" 0 0 2 2)" = "0/4"
desc="the threshold is a spread above 40: 40 is not a fringe, 41 is"
check test "$(count "$tmp/c.png" 0 0 2 1)" = "1/2"
desc="a lower threshold counts both"
check test "$(count "$tmp/c.png" 0 0 2 1 30)" = "2/2"
desc="a region that is not inside the image is an error, not a smaller count"
check bash -c '! "$1"/tests/visual/fringe-count.sh "$2" 2 1 5 5 >/dev/null 2>&1' _ "$root" "$tmp/a.png"
desc="a missing image is an error"
check bash -c '! "$1"/tests/visual/fringe-count.sh "$2/none.png" 0 0 1 1 >/dev/null 2>&1' _ "$root" "$tmp"
exit $fail
