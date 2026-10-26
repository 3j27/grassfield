#!/usr/bin/env bash
# Nested pass (L1) for the Applications location of grassfield-files with fixture desktop entries whose Icon= is an absolute
# path: a valid PNG, a valid SVG, an SVG that names a FIFO, a PDF named .png, an oversized PNG and a slow SVG (one marker on a
# path of 3000 vertices). The grid must show every app (the refused or slow icons as the generic one) without freezing, Get
# Info of an app must open, and quitting while the slow icon may still be decoding must be a clean exit (status 0, no signal).
#
# Safety: everything lives under .dev/files-apps-shots (fixture XDG_DATA_HOME with its own applications folder, nothing
# installed); the app runs through scripts/dev/isolated.sh with its own XDG homes on a private session bus (ADR-0011) and
# the nested Wayland socket only; GRASSFIELD_FILES_NO_LAUNCH=1 so no application is ever started. Only the process groups
# started here are signalled.
#
# Requires: scripts/dev/nested-up.sh running (bare command), .dev/build/grassfield-files, dbus-daemon, magick, python3.
# Usage: tests/apps/files_applications_shots.sh [en|fr] [output]   Shots: .dev/shots/files-apps-<lang>-*.png
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
lang=${1:-en}
output=${2:-GF-REF}
bin=$dev/build/grassfield-files
work=$dev/files-apps-shots
busdir=$work/.bus
iso_name=files-apps-shots
iso=$dev/isolated/$iso_name
log=$dev/files-apps-shots-$lang.log
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh

[[ $lang == en || $lang == fr ]] || { echo "FAIL: language must be en or fr"; exit 1; }
[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
command -v dbus-daemon >/dev/null && command -v magick >/dev/null || { echo "FAIL: dbus-daemon and magick are needed"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }
case $work in "$root"/.dev/files-apps-shots) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-apps-shots) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac

rm -rf -- "$work" "$iso"
mkdir -p "$busdir" "$iso"/{home,config,cache,state,data/applications}
apps=$iso/data/applications
mkdir -p "$iso/data/icons-fixture"
icons=$iso/data/icons-fixture # under the app's XDG data home: an allowed icon root (the isolated HOME is not this tree)

magick -size 96x96 gradient:'#3d7fe0-#e8c02a' "$icons/good.png"
magick -size 4000x4000 xc:'#3da35d' "$icons/huge.png"
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0/Kids[]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' >"$icons/pdf.png"
cat >"$icons/good.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" fill="#e5484d"/></svg>
EOF
mkfifo "$icons/icon.fifo"
cat >"$icons/fifo.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64"><image width="64" height="64" xlink:href="$icons/icon.fifo"/></svg>
EOF
python3 -I - "$icons/slow.svg" <<'EOF'
import sys
n = 3000
pts = " ".join("L%d %d" % ((i * 37) % 64, (i * 91) % 64) for i in range(1, n))
open(sys.argv[1], "w").write(
    '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><defs>'
    '<marker id="m" markerWidth="5" markerHeight="5"><rect width="1" height="1"/></marker></defs>'
    '<path d="M0 0 %s" marker-mid="url(#m)" fill="none" stroke="#000"/></svg>' % pts)
EOF
entry() { # name file icon
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$1" "$3" >"$apps/$2.desktop"
}
entry "Alpha PNG" alpha "$icons/good.png"
entry "Bravo SVG" bravo "$icons/good.svg"
entry "Charlie FIFO" charlie "$icons/fifo.svg"
entry "Delta PDF" delta "$icons/pdf.png"
entry "Echo Huge" echo "$icons/huge.png"
entry "Foxtrot Slow" foxtrot "$icons/slow.svg"
entry "Golf Theme" golf "text-editor"

env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY="$sock" GRASSFIELD_DEV=1 HOME="$iso/home" \
  XDG_CONFIG_HOME="$iso/config" XDG_CACHE_HOME="$iso/cache" XDG_STATE_HOME="$iso/state" XDG_DATA_HOME="$iso/data" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
app=""
cleanup() {
  local pid
  for pid in $app $bus_pid; do
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && kill -- "-$pid" 2>/dev/null
  done
  wait 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 50); do [[ -s $busdir/address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$busdir/address" 2>/dev/null)
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "FAIL: refusing: the private bus did not start or has an unexpected address '$bus'"; exit 1 ;;
esac
[[ $bus != "$owner_bus" ]] || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }

shot() { "$root/scripts/dev/shot.sh" "files-apps-$lang-$1" "$output" >/dev/null && echo "shot: $dev/shots/files-apps-$lang-$1.png"; }

"$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 \
  QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" GRASSFIELD_LANG="$lang" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "grassfield-apps:/" >"$log" 2>&1 </dev/null &
app=$!
sleep 6
kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
shot 1-grid
# Get Info of the first app (Return would start it: NO_LAUNCH is set, but Get Info is what is looked at).
"$keys" -M ctrl -k i -m ctrl
sleep 2
shot 2-info
"$keys" -k Escape
sleep 1
# Quit while the slow icon may still be decoding: a clean exit, not a crash.
"$keys" -M ctrl -k w -m ctrl
for _ in $(seq 1 100); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$app" 2>/dev/null; then
  echo "FAIL: Files did not quit"
  ps -o pid,stat,wchan:20,nlwp,cmd --ppid "$app" 2>/dev/null | cut -c1-160
  ps -L -o tid,stat,wchan:24,comm -p "$app" 2>/dev/null | head -30
  exit 1
fi
wait "$app"
rc=$?
if ((rc == 0)); then
  echo "PASS: quit status 0"
else
  echo "FAIL: quit status $rc (a signal is 128+n)"
  exit 1
fi
grep -E "SIGSEGV|Segmentation|core dumped" "$log" && { echo "FAIL: crash in the log"; exit 1; }
echo "files_applications_shots: done (log $log)"
