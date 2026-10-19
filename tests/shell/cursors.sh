#!/usr/bin/env bash
# Build test for branding/cursors (ADR-0014): every required name exists in the hyprcursor and the XCursor theme,
# hotspots lie inside the images, aliases resolve, the custom path honours the colours and sizes.
# Builds only under a temporary directory; never touches ~/.local/share/icons or ~/.icons.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/cursors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

for tool in hyprcursor-util rsvg-convert python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: cursors build test ($tool not installed)"; exit 0; }
done

# CSS names required by the brief plus the legacy aliases (names only; see branding/cursors/cursors.tsv).
required="default pointer text vertical-text wait progress help crosshair cell copy alias context-menu grab grabbing
no-drop not-allowed all-scroll col-resize row-resize n-resize ne-resize e-resize se-resize s-resize sw-resize w-resize
nw-resize ew-resize ns-resize nesw-resize nwse-resize zoom-in zoom-out
left_ptr arrow hand1 hand2 xterm watch left_ptr_watch fleur sb_h_double_arrow sb_v_double_arrow crossed_circle question_arrow"

# Default theme into a throwaway icons dir, custom theme under a temporary XDG_DATA_HOME.
export XDG_DATA_HOME=$tmp/xdg
mkdir -p "$XDG_DATA_HOME/icons"
"$root/branding/cursors/build.sh" --out "$tmp/icons" >/dev/null
"$root/branding/cursors/build.sh" --out "$XDG_DATA_HOME/icons" --name grassfield-cursors-custom \
  --fill '#ff0000' --outline '#00ff00' --sizes '32 48' >/dev/null
theme=$tmp/icons/grassfield-cursors
custom=$XDG_DATA_HOME/icons/grassfield-cursors-custom

desc="theme layout (index.theme, manifest.hl, hyprcursors/, cursors/)"
check test -f "$theme/index.theme" -a -f "$theme/manifest.hl" -a -d "$theme/hyprcursors" -a -d "$theme/cursors"

missing=""
for n in $required; do [[ -e $theme/cursors/$n ]] || missing+=" xcursor:$n"; done
desc="all required names resolve in the XCursor theme (missing:${missing:- none})"
check test -z "$missing"

desc="hyprcursor theme: every required name is a cursor or an override in an .hlc archive"
check python3 -I - "$theme" $required <<'PY'
import re, sys, zipfile, os
theme, required = sys.argv[1], set(sys.argv[2:])
names = set()
for f in os.listdir(os.path.join(theme, "hyprcursors")):
    z = zipfile.ZipFile(os.path.join(theme, "hyprcursors", f))
    meta = z.read("meta.hl").decode()
    names.add(f[:-4])
    names.update(re.findall(r"^define_override\s*=\s*(\S+)", meta, re.M))
    for svg in re.findall(r"^define_size\s*=\s*\d+,\s*(\S+?)\s*(?:,|$)", meta, re.M):
        if svg not in z.namelist():
            sys.exit(f.replace(".hlc", "") + ": " + svg + " missing in archive")
    for key in ("hotspot_x", "hotspot_y"):
        m = re.search(key + r"\s*=\s*([0-9.]+)", meta)
        if not m or not 0.0 <= float(m.group(1)) < 1.0:
            sys.exit(f + ": " + key + " outside 0..1")
missing = sorted(required - names)
sys.exit("missing: " + " ".join(missing) if missing else 0)
PY

desc="hotspots inside the images, sizes, animation frames, colours, aliases (python)"
check python3 -I - "$theme" "$custom" "$root/branding/cursors/cursors.tsv" <<'PY'
import os, re, struct, sys
theme, custom, table = sys.argv[1:4]
ok = True
def bad(msg):
    global ok
    ok = False
    print("  " + msg)

def read(path):
    d = open(path, "rb").read()
    magic, hdr, ver, n = struct.unpack("<4s3I", d[:16])
    if magic != b"Xcur":
        raise SystemExit(path + ": bad magic")
    imgs = []
    for i in range(n):
        typ, sub, pos = struct.unpack("<3I", d[16 + 12 * i:28 + 12 * i])
        _, t2, nominal, _, w, h, xh, yh, delay = struct.unpack("<9I", d[pos:pos + 36])
        px = d[pos + 36:pos + 36 + w * h * 4]
        imgs.append((nominal, w, h, xh, yh, delay, px))
    return imgs

rows = [l.split() for l in open(table) if l.strip() and not l.startswith("#")]
for source, hx, hy, frames, names in rows:
    names = names.split(",")
    frames = int(frames)
    imgs = read(os.path.join(theme, "cursors", names[0]))
    sizes = sorted({i[0] for i in imgs})
    if sizes != [24, 32, 48, 64, 96]:
        bad(f"{names[0]}: sizes {sizes}")
    if len(imgs) != frames * 5:
        bad(f"{names[0]}: {len(imgs)} images, expected {frames * 5}")
    for nominal, w, h, xh, yh, delay, px in imgs:
        if (w, h) != (nominal, nominal) or not (0 <= xh < w and 0 <= yh < h):
            bad(f"{names[0]}: hotspot ({xh},{yh}) outside {w}x{h}")
        if frames > 1 and delay <= 0:
            bad(f"{names[0]}: animated frame without delay")
        if not any(px[3::4]):
            bad(f"{names[0]}: empty image")
    for alias in names[1:]:
        p = os.path.join(theme, "cursors", alias)
        if not os.path.islink(p) or not os.path.exists(p) or os.path.realpath(p) != os.path.realpath(os.path.join(theme, "cursors", names[0])):
            bad(f"alias {alias} does not resolve to {names[0]}")

# Custom theme: only the requested sizes, and the requested colours reach the pixels (BGRA premultiplied).
imgs = read(os.path.join(custom, "cursors", "default"))
if sorted({i[0] for i in imgs}) != [32, 48]:
    bad("custom sizes differ from --sizes")
px = imgs[0][6]
pixels = {tuple(px[i:i + 4]) for i in range(0, len(px), 4)}
if not any(r > 200 and g < 40 and b < 40 and a == 255 for b, g, r, a in pixels):
    bad("custom fill #ff0000 not found")
if not any(g > 200 and r < 40 and b < 40 and a == 255 for b, g, r, a in pixels):
    bad("custom outline #00ff00 not found")
if not os.path.isfile(os.path.join(custom, "manifest.hl")) or "grassfield-cursors-custom" not in open(os.path.join(custom, "index.theme")).read():
    bad("custom theme metadata")
sys.exit(0 if ok else 1)
PY

exit "$fail"
