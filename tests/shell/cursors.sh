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

# Every name Hyprland itself can ask for (CursorShapes.hpp of the installed headers; "invalid" is not a shape) plus
# the names toolkits and X11 clients use that Hyprland falls back to.
shapes_h=/usr/include/hyprland/src/helpers/CursorShapes.hpp
if [[ -f $shapes_h ]]; then
  required+=" $(grep -o '"[A-Za-z_-]*"' "$shapes_h" | tr -d '"' | grep -vx invalid | tr '\n' ' ')"
else
  echo "NOTE: $shapes_h not found: Hyprland's own shape list not checked"
fi
required+=" all-resize X_cursor move size_all"

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

# libhyprcursor (the library Hyprland uses) against the XCursor files: same hotspot for every name at every size.
desc="hyprcursor and XCursor agree on every hotspot at every size, and hyprcursor lacks no name (probe)"
if command -v gcc >/dev/null && pkg-config --exists cairo hyprcursor 2>/dev/null; then
  probe=$tmp/cursors_probe
  # shellcheck disable=SC2046
  gcc -o "$probe" "$root/tests/shell/cursors_probe.c" $(pkg-config --cflags cairo hyprcursor) -lhyprcursor
  mkdir -p "$tmp/data"
  ln -s "$tmp/icons" "$tmp/data/icons"
  # shellcheck disable=SC2086
  XDG_DATA_DIRS=$tmp/data XDG_DATA_HOME=$tmp/none "$probe" grassfield-cursors "24 32 48 64 96" $required > "$tmp/probe.out" || true
  check python3 -I - "$theme" "$tmp/probe.out" <<'PY'
import os, struct, sys
theme, probe = sys.argv[1:3]
ok = True
def xcursor_hotspots(name):
    d = open(os.path.join(theme, "cursors", name), "rb").read()
    n = struct.unpack("<I", d[12:16])[0]
    out = {}
    for i in range(n):
        pos = struct.unpack("<3I", d[16 + 12 * i:28 + 12 * i])[2]
        _, _, nominal, _, w, h, xh, yh, delay = struct.unpack("<9I", d[pos:pos + 36])
        out.setdefault(nominal, (xh, yh))
    return out
seen = 0
for line in open(probe):
    f = line.split()
    seen += 1
    if f[2] == "MISSING":
        print("  hyprcursor: " + f[0] + " " + f[1] + " MISSING"); ok = False; continue
    want = xcursor_hotspots(f[0])[int(f[1])]
    got = (int(f[2]), int(f[3]))
    if want != got:
        print(f"  {f[0]} at {f[1]}: xcursor {want}, hyprcursor {got}"); ok = False
if seen == 0:
    print("  probe produced no output"); ok = False
sys.exit(0 if ok else 1)
PY
else
  echo "SKIP: hotspot agreement (gcc, cairo or hyprcursor development files missing)"
fi

# Argument validation and paths with spaces.
desc="build.sh refuses theme names that are not letters, digits, - and _ (.., ., a/b, a b, empty, a.b)"
bad=0
for n in .. . a/b "a b" "" a.b; do
  "$root/branding/cursors/build.sh" --out "$tmp/names" --name "$n" >/dev/null 2>&1 && bad=1
done
check test "$bad" = 0 -a ! -e "$tmp/names"
desc="build.sh works when --out contains a space"
check bash -c '"$0" --out "$1" --name spaced --sizes 32 >/dev/null' "$root/branding/cursors/build.sh" "$tmp/out with space"
desc="the build in a directory with a space is complete (hyprcursor + XCursor)"
check test -f "$tmp/out with space/spaced/manifest.hl" -a -f "$tmp/out with space/spaced/cursors/default" -a -f "$tmp/out with space/spaced/hyprcursors/default.hlc"

exit "$fail"
