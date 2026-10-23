#!/usr/bin/env bash
# ADR-0017 (owner decision 2026-10-23): the composer packaging/arch/icons-compose.py on small synthetic trees.
# Fake MacTahoe-like (src/ + links/, layout <context>/<size>), Pebble-like (<size>/<context>, with junk and a dangling
# link) and branding trees; every icon is a solid colour per layer: MacTahoe red, Pebble green, ours blue, the Breeze
# stand-in yellow. Proves: layer order; a Pebble folder name wins at EVERY size; store aliases (chains included) resolve to
# Pebble's bag; listed logo names and every link to them are gone from their layer (the name falls through); a listed
# file missing from the source fails the composer; no dangling or escaping links; index.theme; and that Qt and GTK 3/4
# resolve the names as the layers say. No display, no D-Bus.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/icons-compose.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
composer=$root/packaging/arch/icons-compose.py

# ---- fixtures
python3 -I - "$tmp" "$root" <<'PY'
import os, struct, sys, zlib
tmp, root = sys.argv[1], sys.argv[2]
R, G, B, Y = (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)
def svg(c):
    return '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" fill="#%02x%02x%02x"/></svg>\n' % c
def png(c):
    raw = b"".join(b"\x00" + bytes(c) * 16 for _ in range(16))
    def ch(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
def put(base, rel, c):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if rel.endswith(".png"):
        open(p, "wb").write(png(c))
    else:
        open(p, "w").write(svg(c))
def link(base, rel, target):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    os.symlink(target, p)
def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)

# MacTahoe-like (the composer expects the directories install.sh copies; most are empty here)
mt = tmp + "/mt"
for d in ("actions", "animations", "categories", "devices", "emotes", "emblems", "mimes", "preferences", "status/16", "status/22", "status/24", "status/32", "status/symbolic"):
    os.makedirs(mt + "/src/" + d)
write(mt + "/src/index.theme", """[Icon Theme]
Name=MacTahoe
Inherits=hicolor,breeze
Directories=places/16,places/24,places/scalable,places/symbolic,apps/16,apps/scalable

[places/16]
Size=16
Context=Places
Type=Fixed

[places/24]
Size=24
Context=Places
Type=Fixed

[places/scalable]
Size=32
Context=Places
MinSize=32
MaxSize=256
Type=Scalable

[places/symbolic]
Size=16
Context=Places
MinSize=16
MaxSize=512
Type=Scalable

[apps/16]
Size=16
Context=Applications
Type=Fixed

[apps/scalable]
Size=128
Context=Applications
MinSize=32
MaxSize=256
Type=Scalable
""")
S = mt + "/src/"
for d in ("16", "24", "scalable"):
    put(S, "places/%s/folder.svg" % d, R)
put(S, "places/16/user-home.svg", R); put(S, "places/scalable/user-home.svg", R)
put(S, "places/symbolic/folder-symbolic.svg", R)
for d in ("16", "scalable"):
    put(S, "places/%s/start-here.svg" % d, R)
put(S, "places/symbolic/start-here-symbolic.svg", R)
put(S, "mimes/24/start-here.svg", R)          # directory the upstream index.theme does not list
put(S, "places/16/folder-apple.svg", R)
put(S, "places/scalable/user-trash-dark.svg", R)  # upstream install.sh deletes it
put(S, "apps/16/softwarecenter.svg", R); put(S, "apps/scalable/softwarecenter.svg", R)
put(S, "apps/16/calendar.svg", R); put(S, "apps/scalable/calendar.svg", R)
# A glyph drawn by a path (the signature guard): the same relative path data at two positions, in both layers.
MARK = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="%s"/></svg>\n'
write(S + "/apps/scalable/glyph-mark.svg", MARK % "M10 10 l5 0 l0 5 z")
put(S, "apps/scalable/shared.svg", R); put(S, "apps/scalable/own-app.svg", R)
L = mt + "/links/"
link(L, "apps/scalable/gnome-software.svg", "softwarecenter.svg")
link(L, "apps/scalable/org.gnome.Software.svg", "gnome-software.svg")
link(L, "apps/scalable/mt-store-only.svg", "org.gnome.Software.svg")
link(L, "apps/16/gnome-software.svg", "softwarecenter.svg")
link(L, "apps/scalable/calendar-alias.svg", "calendar.svg")
for d in ("16", "scalable"):
    link(L, "places/%s/distributor-logo.svg" % d, "start-here.svg")
    link(L, "places/%s/inode-directory.svg" % d, "folder.svg")
link(L, "places/scalable/logo-chain.svg", "distributor-logo.svg")
# A name with two kinds of entries: its own drawing at 16 px, an alias of a logo drawing at scalable.
put(S, "apps/16/media-mixed.svg", R)
link(L, "apps/scalable/media-mixed.svg", "../../places/scalable/start-here.svg")
link(L, "places/24/inode-directory.svg", "folder.svg")   # Pebble has no 24 px directory
put(S, "apps/scalable/doubtful.svg", R)

# Pebble-like
pb = tmp + "/pb"
write(pb + "/Pebble/index.theme", """[Icon Theme]
Name=Pebble
Directories=16x16/places,16x16/devices,scalable/places,scalable/apps,scalable/devices,symbolic/places

[16x16/places]
Context=Places
Size=16
Type=Fixed

[16x16/devices]
Context=Devices
Size=16
Type=Fixed

[scalable/places]
Context=Places
Size=128
MinSize=8
MaxSize=512
Type=Scalable

[scalable/apps]
Context=Applications
Size=128
MinSize=8
MaxSize=512
Type=Scalable

[scalable/devices]
Context=Devices
Size=128
MinSize=8
MaxSize=512
Type=Scalable

[symbolic/places]
Context=Places
Size=16
MinSize=8
MaxSize=512
Type=Scalable
""")
P = pb + "/Pebble/"
put(P, "16x16/places/folder.png", G)
put(P, "scalable/places/folder.svg", G)
put(P, "scalable/places/folder-git.svg", G)
put(P, "scalable/places/user-home.svg", G)
put(P, "symbolic/places/folder-symbolic.svg", G)
put(P, "scalable/apps/softwarecenter.svg", G)
link(P, "scalable/apps/appstore.svg", "softwarecenter.svg")
link(P, "scalable/apps/software-center.svg", "appstore.svg")
link(P, "scalable/apps/org.gnome.Software.svg", "softwarecenter.svg")
put(P, "scalable/apps/pb-only.svg", G)
write(P + "/scalable/apps/pb-mark.svg", MARK % "M30 40  l5 0 l0 5 z")
put(P, "scalable/apps/shared.svg", G)
put(P, "scalable/apps/calendar.svg", G)
put(P, "scalable/apps/own-app.svg", G)
put(P, "scalable/apps/start-here.svg", G)
link(P, "scalable/apps/start-alias.svg", "start-here.svg")
put(P, "scalable/apps/doubtful.svg", G)
link(P, "scalable/apps/dangling.svg", "missing.svg")
link(P, "scalable/apps/shared-alias.svg", "shared.svg")   # its target name belongs to MacTahoe: dangling once dropped
put(P, "scalable/apps/.hidden.svg", G)
put(P, "scalable/apps/junk.svg~", G)
write(P + "scalable/apps/noextension", "x")
put(P, "scalable/devices/dev-shared.svg", G)
write(P + "icon-theme.cache", "cache")

# branding
br = tmp + "/branding"
os.makedirs(br + "/scalable/apps")
open(br + "/index.theme", "w").write(open(root + "/branding/icons/theme/index.theme").read())
put(br, "scalable/apps/own-app.svg", B)
put(br, "scalable/devices/dev-only.svg", B)
put(br, "scalable/devices/dev-shared.svg", B)

# the list
write(tmp + "/list.txt", """# fixture list
mactahoe:src/places/16/start-here.svg
mactahoe:src/places/scalable/start-here.svg
mactahoe:src/mimes/24/start-here.svg   # a kind column is optional
mactahoe:src/places/16/folder-apple.svg finder-face
mactahoe:src/apps/scalable/doubtful.svg doubt
""")
write(tmp + "/list-missing.txt", "mactahoe:src/places/16/start-here.svg\nmactahoe:src/places/16/no-such-icon.svg\n")
write(tmp + "/list-pebble.txt", "pebble:Pebble/scalable/apps/start-here.svg\n")

# the fixture themes the grassfield-icons theme inherits (Breeze stand-in: yellow)
fx = tmp + "/fx/icons"
def theme(name, inherits, icons):
    d = fx + "/" + name
    os.makedirs(d + "/16x16/apps", exist_ok=True)
    idx = ["[Icon Theme]", "Name=" + name] + (["Inherits=" + inherits] if inherits else []) + \
          ["Directories=16x16/apps", "", "[16x16/apps]", "Size=16", "Type=Fixed", "Context=Applications"]
    open(d + "/index.theme", "w").write("\n".join(idx) + "\n")
    for n, c in icons.items():
        put(d, "16x16/apps/" + n + ".png", c)
theme("hicolor", None, {})
theme("Adwaita", "hicolor", {})
theme("breeze", "hicolor", {"br-only": Y, "folder": Y, "distributor-logo": Y, "calendar": Y})
PY

run() { python3 -I "$composer" --mactahoe "$tmp/mt" --pebble "$tmp/pb" --branding "$tmp/branding" --list "$1" --out "$2"; }
out=$tmp/fx/icons/grassfield-icons
log=$(run "$tmp/list.txt" "$out" 2>&1) && rc=0 || rc=$?
desc="composer succeeds on the fixtures (exit $rc)"
check test "$rc" = 0
echo "$log" | sed 's/^/    /'

has() { [[ -e $out/$1 ]]; }
lnk() { [[ -L $out/$1 ]]; }
res() { [[ $(readlink -f "$out/$1") == "$(readlink -f "$out")/$2" ]]; }

desc="layer order: ours beats MacTahoe and Pebble (own-app)"
check bash -ec '[ -f "$1/scalable/apps/own-app.svg" ] && [ ! -e "$1/base/apps/scalable/own-app.svg" ] && [ ! -e "$1/extra/scalable/apps/own-app.svg" ]' _ "$out"
desc="layer order: MacTahoe beats Pebble (shared) and Pebble fills the rest (pb-only)"
check bash -ec '[ -f "$1/base/apps/scalable/shared.svg" ] && [ ! -e "$1/extra/scalable/apps/shared.svg" ] && [ -f "$1/extra/scalable/apps/pb-only.svg" ]' _ "$out"
desc="layer order: our device glyph is used only where no other layer has the name"
check bash -ec '[ -f "$1/scalable/devices/dev-only.svg" ] && [ ! -e "$1/scalable/devices/dev-shared.svg" ] && [ -f "$1/extra/scalable/devices/dev-shared.svg" ]' _ "$out"
desc="Pebble folders: every size of folder and user-home is gone from MacTahoe, present in Pebble"
check bash -ec 'cd "$1"; for n in folder user-home; do ls base/places/*/$n.* 2>/dev/null && exit 1; done; [ -f extra/16x16/places/folder.png ] && [ -f extra/scalable/places/folder.svg ] && [ -f extra/scalable/places/folder-git.svg ] && [ -f extra/scalable/places/user-home.svg ]; exit 0' _ "$out"
desc="symbolic folder glyphs stay MacTahoe's"
check bash -ec '[ -f "$1/base/places/symbolic/folder-symbolic.svg" ] && [ ! -e "$1/extra/symbolic/places/folder-symbolic.svg" ]' _ "$out"
desc="a MacTahoe alias of a folder drawing (inode-directory) is re-pointed to Pebble's folder: same size directory when Pebble has one (16: png), else its scalable drawing (24, scalable); relative links"
check bash -ec 'cd "$1"; [ ! -e base/places/16/inode-directory.svg ] && [ -L base/places/16/inode-directory.png ] && [ "$(readlink -f base/places/16/inode-directory.png)" = "$(readlink -f extra/16x16/places/folder.png)" ] && [ "$(readlink -f base/places/24/inode-directory.svg)" = "$(readlink -f extra/scalable/places/folder.svg)" ] && [ "$(readlink -f base/places/scalable/inode-directory.svg)" = "$(readlink -f extra/scalable/places/folder.svg)" ] && [ "$(readlink base/places/24/inode-directory.svg)" = ../../../extra/scalable/places/folder.svg ]' _ "$out"
desc="a Pebble alias whose target name MacTahoe provides (shared-alias -> shared) is re-pointed to MacTahoe's drawing, not lost"
check bash -ec 'cd "$1"; [ -L extra/scalable/apps/shared-alias.svg ] && [ "$(readlink -f extra/scalable/apps/shared-alias.svg)" = "$(readlink -f base/apps/scalable/shared.svg)" ] && [ "$(readlink extra/scalable/apps/shared-alias.svg)" = ../../../base/apps/scalable/shared.svg ]' _ "$out"
desc="kind doubt: the MacTahoe drawing is dropped and Pebble serves the name"
check bash -ec 'cd "$1"; [ ! -e base/apps/scalable/doubtful.svg ] && [ -f extra/scalable/apps/doubtful.svg ]' _ "$out"
desc="store: MacTahoe's bag (every size) and its aliases are gone"
check bash -ec 'cd "$1/base/apps"; ls */softwarecenter.* */gnome-software.* */org.gnome.Software.* */mt-store-only.* 2>/dev/null && exit 1; exit 0' _ "$out"
desc="store: Pebble's aliases, a chained MacTahoe alias and the Pebble chain (software-center) resolve to Pebble's bag"
check bash -ec 'cd "$1/extra/scalable/apps"; b=$(readlink -f softwarecenter.svg); for n in appstore software-center org.gnome.Software gnome-software mt-store-only; do [ "$(readlink -f $n.svg)" = "$b" ] || { echo "$n"; exit 1; }; done' _ "$out"
desc="MacTahoe-only names stay MacTahoe's, with their links merged from links/ (calendar, calendar-alias)"
check bash -ec 'cd "$1/base/apps"; [ -f scalable/calendar.svg ] && [ -f 16/calendar.svg ] && [ "$(readlink -f scalable/calendar-alias.svg)" = "$(readlink -f scalable/calendar.svg)" ]' _ "$out"
desc="logo names: every size and directory and every link to them (chains too) are gone from MacTahoe, symbolic is another name"
check bash -ec 'cd "$1/base"; ls */*/start-here.* */*/distributor-logo.* */*/logo-chain.* */*/folder-apple.* 2>/dev/null && exit 1; [ -f places/symbolic/start-here-symbolic.svg ]' _ "$out"
desc="an alias of a logo drawing loses only that entry: the name keeps its other drawing (media-mixed at 16 px stays, its scalable alias is gone)"
check bash -ec '[ -f "$1/base/apps/16/media-mixed.svg" ] && [ ! -e "$1/base/apps/scalable/media-mixed.svg" ]' _ "$out"
desc="a dropped logo name falls through to the next layer (Pebble start-here)"
check test -f "$out/extra/scalable/apps/start-here.svg"
desc="upstream behaviour kept: user-trash-dark is not installed; files in directories the index.theme does not list are ignored"
check bash -ec '[ ! -e "$1/base/places/scalable/user-trash-dark.svg" ] && [ ! -e "$1/base/mimes" ]' _ "$out"
desc="Pebble junk (hidden files, backup files, no extension, cache) is not installed; the upstream dangling link is gone"
check bash -ec 'cd "$1"; ! find . -name icon-theme.cache -o -name "*~" -o -name ".*.svg" -o -name noextension -o -name dangling.svg | grep -q .' _ "$out"
desc="no dangling link, no absolute link, no link escaping the theme"
check bash -ec 'cd "$1"; real=$(readlink -f .); n=0; while IFS= read -r l; do t=$(readlink -f "$l") || exit 1; [ -f "$t" ] || { echo "dangling $l"; exit 1; }; case $t in "$real"/*) ;; *) echo "escape $l"; exit 1;; esac; case $(readlink "$l") in /*) exit 1;; esac; n=$((n+1)); done < <(find . -type l); [ "$n" -gt 0 ]' _ "$out"
idx=$out/index.theme
desc="index.theme: Name, Hidden=true, Inherits=breeze,Adwaita,hicolor, a Directories key"
check bash -ec 'grep -qx "Name=Grassfield" "$1" && grep -qx "Hidden=true" "$1" && grep -qx "Inherits=breeze,Adwaita,hicolor" "$1" && grep -q "^Directories=scalable/apps," "$1"' _ "$idx"
desc="index.theme: no forbidden word (Mac, macOS, OSX, Apple, Tahoe)"
check bash -ec '! grep -qiE "mac|osx|apple|tahoe" "$1"' _ "$idx"
desc="index.theme: one section per listed directory and per directory on disk, with the upstream keys"
check python3 -I - "$out" <<'PY'
import os, sys
out = sys.argv[1]
text = open(out + "/index.theme").read()
dirs = [l.split("=", 1)[1] for l in text.splitlines() if l.startswith("Directories=")][0].split(",")
secs = {}
cur = None
for l in text.splitlines():
    if l.startswith("[") and l != "[Icon Theme]":
        cur = l[1:-1]; secs[cur] = {}
    elif cur and "=" in l:
        k, v = l.split("=", 1); secs[cur][k] = v
ondisk = {os.path.relpath(d, out) for d, _, fs in os.walk(out) if any(f != "index.theme" for f in fs) or d == out + "/scalable/apps"}
ondisk.discard(".")
assert set(dirs) == set(secs) == ondisk, (sorted(set(dirs) ^ ondisk), sorted(set(secs) ^ set(dirs)))
assert secs["extra/scalable/places"] == {"Context": "Places", "Size": "128", "MinSize": "8", "MaxSize": "512", "Type": "Scalable"}
assert secs["base/apps/scalable"]["MinSize"] == "32" and secs["base/apps/16"]["Type"] == "Fixed"
assert secs["scalable/apps"]["Context"] == "Applications"
PY
desc="deterministic: a second composition is identical"
run "$tmp/list.txt" "$tmp/again" >/dev/null 2>&1
check bash -ec 'diff -r --no-dereference "$1" "$2" >/dev/null' _ "$out" "$tmp/again"

desc="a listed file missing from the source fails the composer (pin drift)"
check bash -ec '! python3 -I "$1" --mactahoe "$2/mt" --pebble "$2/pb" --branding "$2/branding" --list "$2/list-missing.txt" --out "$2/never" >/dev/null 2>&1 && [ ! -e "$2/never" ]' _ "$composer" "$tmp"
desc="signature guard: a path whose signature is in the fingerprints file fails the composer and names the file, wherever the glyph sits"
printf 'l5 0 l0 5 z' | sha256sum | cut -d' ' -f1 >"$tmp/sigs.txt"
check bash -ec 'out=$(python3 -I "$1" --mactahoe "$2/mt" --pebble "$2/pb" --branding "$2/branding" --list "$2/list.txt" --signatures "$2/sigs.txt" --out "$2/sigfail" 2>&1) && exit 1; grep -qE "Apple-logo glyph .* (base/apps/scalable/glyph-mark|extra/scalable/apps/pb-mark)\.svg" <<<"$out"' _ "$composer" "$tmp"
desc="signature guard: the default fingerprints file (packaging/arch/icons-apple-signatures.txt) holds SHA-256 lines only and the fixtures pass it"
check bash -ec '[ "$(grep -v "^#" "$1" | grep -cvE "^[0-9a-f]{64}$")" = 0 ] && [ "$(grep -cE "^[0-9a-f]{64}$" "$1")" -ge 1 ] && [ -f "$2/index.theme" ]' _ "$root/packaging/arch/icons-apple-signatures.txt" "$out"
desc="a pebble: entry drops that name from Pebble with its aliases (start-here, start-alias go on to Breeze)"
run "$tmp/list-pebble.txt" "$tmp/peb2" >/dev/null 2>&1
check bash -ec '[ ! -e "$1/extra/scalable/apps/start-here.svg" ] && [ ! -e "$1/extra/scalable/apps/start-alias.svg" ] && [ -f "$1/base/places/16/start-here.svg" ]' _ "$tmp/peb2"

# ---- Qt: the colour at the centre of the icon, at 16 px and at large sizes
probe=$tmp/icon_probe
if command -v g++ >/dev/null && [[ -f /usr/include/qt6/QtGui/QIcon ]]; then
  g++ -std=c++20 -fPIC -o "$probe" "$root/tests/shell/icon_probe.cpp" -I/usr/include/qt6 -I/usr/include/qt6/QtGui -I/usr/include/qt6/QtCore -lQt6Gui -lQt6Core
  qt() { env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" QT_QPA_PLATFORM=offscreen XDG_DATA_DIRS="$tmp/fx" QT_QPA_SYSTEM_ICON_THEME=grassfield-icons "$probe" "$@"; }
  q=$(qt folder at24:folder at128:folder at256:folder user-home at128:user-home folder-git inode-directory at24:inode-directory at128:inode-directory shared-alias doubtful \
        calendar at128:calendar pb-only br-only own-app gnome-software org.gnome.Software mt-store-only software-center appstore \
        at128:gnome-software start-here distributor-logo logo-chain shared dev-only dev-shared folder-symbolic)
  echo "$q" | tr '\n' ' ' | sed 's/^/    Qt: /; s/$/\n/'
  qc() { grep -qx "$1=$2" <<<"$q"; }
  red=#ff0000 green=#00ff00 blue=#0000ff yellow=#ffff00
  desc="Qt: folder is Pebble's at 16, 24, 128 and 256 px (no MacTahoe leftover at any size); user-home too"
  check bash -ec 'for s in "folder=$2" "folder@24=$2" "folder@128=$2" "folder@256=$2" "user-home=$2" "user-home@128=$2" "folder-git=$2"; do grep -qx "$s" <<<"$1" || { echo "$s"; exit 1; }; done' _ "$q" "$green"
  desc="Qt: the folder alias inode-directory is Pebble's folder (16, 24, 128 px)"
  check bash -ec 'grep -qx "inode-directory=$2" <<<"$1" && grep -qx "inode-directory@24=$2" <<<"$1" && grep -qx "inode-directory@128=$2" <<<"$1"' _ "$q" "$green"
  desc="Qt: a Pebble alias of a MacTahoe name is MacTahoe's drawing; a doubtful MacTahoe drawing is Pebble's"
  check bash -c 'grep -qx "shared-alias=$2" <<<"$1" && grep -qx "doubtful=$3" <<<"$1"' _ "$q" "$red" "$green"
  desc="Qt: MacTahoe-only name -> MacTahoe, Pebble-only -> Pebble, Breeze-only -> Breeze, ours first"
  check bash -ec 'for s in "calendar=$2" "calendar@128=$2" "pb-only=$3" "br-only=$5" "own-app=$4" "shared=$2" "dev-only=$4" "dev-shared=$3" "folder-symbolic=$2"; do grep -qx "$s" <<<"$1" || { echo "$s"; exit 1; }; done' _ "$q" "$red" "$green" "$blue" "$yellow"
  desc="Qt: store names (Pebble chain, MacTahoe chain, bag itself) -> Pebble's bag at every size"
  check bash -ec 'for s in gnome-software org.gnome.Software mt-store-only software-center appstore gnome-software@128; do grep -qx "$s=$2" <<<"$1" || { echo "$s"; exit 1; }; done' _ "$q" "$green"
  desc="Qt: dropped logo names fall through (start-here -> Pebble, distributor-logo and logo-chain -> Breeze or nothing, never MacTahoe)"
  check bash -ec 'grep -qx "start-here=$2" <<<"$1" && grep -qx "distributor-logo=$3" <<<"$1" && ! grep -qx "logo-chain=$4" <<<"$1"' _ "$q" "$green" "$yellow" "$red"
else
  echo "SKIP: Qt icon resolution (g++ or Qt headers missing)"
fi

# ---- GTK 3 and 4 (PyGObject, no display): the file each name resolves to
if python3 -c 'import gi; gi.require_version("Gtk","3.0")' 2>/dev/null && python3 -c 'import gi; gi.require_version("Gtk","4.0")' 2>/dev/null; then
  for v in 3 4; do
    gtk() { env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" GSETTINGS_BACKEND=memory GF_ICON_SIZE="$1" python3 -I "$root/tests/shell/icon_probe_gtk.py" "$v" "$tmp/fx/icons" grassfield-icons "${@:2}" 2>/dev/null; }
    names="folder user-home inode-directory shared-alias doubtful calendar pb-only br-only own-app gnome-software org.gnome.Software mt-store-only software-center start-here distributor-logo shared dev-only dev-shared"
    g16=$(gtk 16 $names)
    g128=$(gtk 128 $names)
    echo "    GTK$v 16: $(tr '\n' ' ' <<<"$g16")"
    echo "    GTK$v 128: $(tr '\n' ' ' <<<"$g128")"
    desc="GTK$v: folder and user-home come from Pebble, inode-directory is an alias of Pebble's folder at 16 px and at 128 px, never from MacTahoe"
    check bash -ec 'for g in "$1" "$2"; do for n in folder user-home; do grep -qE "^$n=grassfield-icons/extra/" <<<"$g" || { echo "$n"; exit 1; }; done; grep -qE "^inode-directory=grassfield-icons/base/places/" <<<"$g" || exit 1; done; grep -qx "folder=grassfield-icons/extra/16x16/places/folder.png" <<<"$1" && grep -qx "folder=grassfield-icons/extra/scalable/places/folder.svg" <<<"$2"' _ "$g16" "$g128"
    desc="GTK$v: MacTahoe-only -> base, Pebble-only -> extra, Breeze-only -> breeze, ours -> scalable/, shared -> base"
    check bash -ec 'for g in "$1" "$2"; do grep -qE "^calendar=grassfield-icons/base/apps/" <<<"$g" && grep -qE "^pb-only=grassfield-icons/extra/" <<<"$g" && grep -qE "^br-only=breeze/" <<<"$g" && grep -qE "^own-app=grassfield-icons/scalable/apps/" <<<"$g" && grep -qE "^shared=grassfield-icons/base/" <<<"$g" && grep -qE "^dev-only=grassfield-icons/scalable/devices/" <<<"$g" && grep -qE "^dev-shared=grassfield-icons/extra/" <<<"$g" || exit 1; done' _ "$g16" "$g128"
    desc="GTK$v: every store name resolves to Pebble's bag (extra/), at 16 px and at 128 px"
    check bash -ec 'for g in "$1" "$2"; do for n in gnome-software org.gnome.Software mt-store-only software-center; do grep -qE "^$n=grassfield-icons/extra/scalable/apps/" <<<"$g" || { echo "$n"; exit 1; }; done; done' _ "$g16" "$g128"
    desc="GTK$v: a dropped logo name falls through (start-here -> Pebble, distributor-logo -> Breeze)"
    check bash -ec 'for g in "$1" "$2"; do grep -qE "^start-here=grassfield-icons/extra/" <<<"$g" && grep -qE "^distributor-logo=breeze/" <<<"$g" || exit 1; done' _ "$g16" "$g128"
  done
else
  echo "SKIP: GTK icon resolution (PyGObject with Gtk 3 and 4 missing)"
fi
exit "$fail"
