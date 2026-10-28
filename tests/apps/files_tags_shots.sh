#!/usr/bin/env bash
# Nested screenshots (L1) for grassfield-files F15 (gallery view) and F16 (colour tags): the icon view with tag dots and
# the sidebar's Tags section, the gallery view with its info panel, Get Info with the tag row (and its live caption after
# tagging from the window), and a tag search. English or French.
#
# Safety: every file lives under .dev/files-tags-shots (tags are set on those files only); the app runs through
# scripts/dev/isolated.sh with its own XDG homes, on a private session bus started here (isolated HOME, ADR-0011) and the
# nested Wayland socket only. Only the process groups started here are signalled.
#
# Requires: scripts/dev/nested-up.sh running (bare command), .dev/build/grassfield-files, dbus-daemon, magick, python3.
# Usage: tests/apps/files_tags_shots.sh [en|fr] [output]   (default en, GF-REF)   Shots: .dev/shots/files-tags-<lang>-*.png
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
lang=${1:-en}
output=${2:-GF-REF}
bin=$dev/build/grassfield-files
work=$dev/files-tags-shots
busdir=$work/.bus
iso_name=files-tags-shots
iso=$dev/isolated/$iso_name
log=$dev/files-tags-shots-$lang.log
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
case $work in "$root"/.dev/files-tags-shots) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-tags-shots) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac

rm -rf -- "$work" "$iso"
mkdir -p "$work/tree/Projects" "$busdir" "$iso"/{home,config,cache,state,data}
tree=$work/tree
printf 'meeting notes\n' >"$tree/Notes.txt"
printf 'budget\n' >"$tree/Budget.txt"
printf 'plain\n' >"$tree/Plain.txt"
printf 'locked\n' >"$tree/Locked.txt"
magick -size 800x500 gradient:'#3d7fe0-#e8c02a' "$tree/Sunset.png"
magick -size 800x500 gradient:'#3da35d-#9b5de5' "$tree/Meadow.png"
magick -size 800x500 gradient:'#e5484d-#f08a24' "$tree/Poppy.png"
printf 'deep\n' >"$tree/Projects/Deep.txt"
# Tags on these sandbox files only: colours, several colours on one file, a named tag.
python3 -I - "$tree" <<'EOF'
import os, sys
t = sys.argv[1]
def tag(name, value):
    os.setxattr(os.path.join(t, name), "user.xdg.tags", value.encode())
tag("Notes.txt", "Red,Work")
tag("Budget.txt", "Yellow,Green,Work")
tag("Sunset.png", "Blue,Orange")
tag("Poppy.png", "Red")
tag("Projects/Deep.txt", "Work")
tag("Locked.txt", "Purple")
EOF
chmod 0444 "$tree/Locked.txt"

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

shot() { "$root/scripts/dev/shot.sh" "files-tags-$lang-$1" "$output" >/dev/null && echo "shot: $dev/shots/files-tags-$lang-$1.png"; }
click() { "$pointer" output "$output" abs "$1" "$2" sleep 200 click >/dev/null; sleep "${3:-0.8}"; }

"$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 \
  QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" GRASSFIELD_LANG="$lang" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$tree" >"$log" 2>&1 </dev/null &
app=$!
sleep 5
kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
shot 1-icons

# Focus the window: click on empty space inside it.
click 1050 600
"$keys" -M ctrl -k 4 -m ctrl
sleep 2.5
shot 2-gallery
"$keys" -k Right
sleep 1
"$keys" -k Right
sleep 2
shot 3-gallery-next
"$keys" -M ctrl -k 1 -m ctrl
sleep 1.5
shot 4-icons-again
# Get Info of Plain.txt (no tags): the tag row, then a colour clicked in the window names the tag in the caption.
"$keys" Plain
sleep 0.6
"$keys" -M ctrl -k i -m ctrl
sleep 2
shot 5-info
click 1046 375
shot 6-info-tagged
"$keys" -k Escape
sleep 1
# A read-only file: the tag row is disabled and says why.
click 1050 650
"$keys" Locked
sleep 0.6
"$keys" -M ctrl -k i -m ctrl
sleep 2
shot 7-info-readonly
"$keys" -k Escape
sleep 1
# The sidebar's Red tag lists the tagged files of this folder and below (one row lower since Recents leads the sidebar).
click 552 449 2
shot 8-tag-search
echo "files_tags_shots: done (log $log)"
