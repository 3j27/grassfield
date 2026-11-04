#!/usr/bin/env bash
# Nested pass (L1) for Move to Trash on an application in Files' Applications location (ADR-0045 D6): three fixture entries,
# the Store's answer given by the dev-only GRASSFIELD_FILES_REMOVABLE_JSON (Alpha and Bravo removable, Charlie part of Omarchy),
# the item menu of Alpha with "Move to Trash" enabled and of Charlie with it dimmed. Files shows no alert of its own: the Store's
# is the confirmation (tests/apps/uninstall_store_shots.sh). Nothing is installed or removed: no Store runs, no pacman,
# GRASSFIELD_FILES_NO_LAUNCH=1.
#
# Safety: as tests/apps/files_applications_shots.sh (a fixture XDG_DATA_HOME under .dev/files-uninstall-shots, the app through
# scripts/dev/isolated.sh on a private session bus and the nested Wayland socket only).
# Requires: scripts/dev/nested-up.sh running (bare command), .dev/build/grassfield-files, dbus-daemon.
# Usage: tests/apps/files_uninstall_shots.sh [en|fr] [output]   Shots: .dev/shots/files-uninstall-<lang>-*.png (1-grid, 2-menu-removable, 3-menu-omarchy)
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
lang=${1:-en}
output=${2:-GF-REF}
bin=$dev/build/grassfield-files
work=$dev/files-uninstall-shots
busdir=$work/.bus
iso_name=files-uninstall-shots
iso=$dev/isolated/$iso_name
log=$dev/files-uninstall-shots-$lang.log
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh
# Where Alpha is on the 1920x1080 reference output at scale 1.25 (Charlie is CHARLIE_DX to its right), from the first capture; pointer.sh takes logical pixels (the capture divided by 1.25).
alpha_x=${ALPHA_X:-794}
alpha_y=${ALPHA_Y:-272}

[[ $lang == en || $lang == fr ]] || { echo "FAIL: language must be en or fr"; exit 1; }
[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon is needed"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }
case $work in "$root"/.dev/files-uninstall-shots) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-uninstall-shots) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac

rm -rf -- "$work" "$iso"
mkdir -p "$busdir" "$iso"/{home,config,cache,state,data/applications}
apps=$iso/data/applications
entry() { # name file icon
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$1" "$3" >"$apps/$2.desktop"
}
entry "Alpha" alpha "text-editor"
entry "Bravo" bravo "text-editor"
entry "Charlie" charlie "text-editor"
removable='{"version":1,"entries":{"alpha.desktop":{"app":"alpha","name":"Alpha","block":""},"bravo.desktop":{"app":"bravo","name":"Bravo","block":""},"charlie.desktop":{"app":"charlie","name":"Charlie","block":"omarchy"}}}'

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

shot() { "$root/scripts/dev/shot.sh" "files-uninstall-$lang-$1" "$output" >/dev/null && echo "shot: $dev/shots/files-uninstall-$lang-$1.png"; }

"$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 GRASSFIELD_FILES_REMOVABLE_JSON="$removable" \
  QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" GRASSFIELD_LANG="$lang" \
  GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "grassfield-apps:/" >"$log" 2>&1 </dev/null &
app=$!
sleep 12
kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
shot 1-grid
if ((alpha_x == 0)); then echo "files_uninstall_shots: set ALPHA_X and ALPHA_Y from the first capture"; exit 0; fi
# Alpha's item menu (right click): Move to Trash enabled.
"$pointer" output "$output" abs "$alpha_x" "$alpha_y" sleep 100 click sleep 300 rclick >/dev/null
sleep 1
shot 2-menu-removable
"$keys" -k Escape
sleep 0.5
# Charlie, part of Omarchy: the same menu with Move to Trash dimmed.
"$pointer" output "$output" abs "$((alpha_x + ${CHARLIE_DX:-355}))" "$alpha_y" sleep 100 click sleep 300 rclick >/dev/null
sleep 1
shot 3-menu-omarchy
"$keys" -k Escape
sleep 0.5
"$keys" -M ctrl -k w -m ctrl
for _ in $(seq 1 100); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
echo "files_uninstall_shots: done (log $log)"
