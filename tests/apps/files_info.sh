#!/usr/bin/env bash
# Headless scenario for grassfield-files --info (the desktop's Get Info, macOS model): for a file, a folder and the
# desktop folder itself, the app opens only the Get Info window of that location, with the item's own name, and no QML
# error. Runs on QT_QPA_PLATFORM=offscreen with a private session bus and isolated homes (scripts/dev/isolated.sh,
# ADR-0011); only the process groups started here are signalled. Files are under .dev/files-info.
#
# Requires: .dev/build/grassfield-files (apps/files/build-direct.sh), dbus-daemon. KIO needs Unix sockets: run it as a
# bare command (outside the Claude Code sandbox); inside the sandbox it SKIPs.
# Usage: tests/apps/files_info.sh   Prints PASS/FAIL per step; exit 1 on any FAIL.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
work=$dev/files-info
busdir=$work/.bus
iso_name=files-info
iso=$dev/isolated/$iso_name

[[ -x $bin ]] || { echo "SKIP files_info: $bin missing (apps/files/build-direct.sh)"; exit 0; }
command -v dbus-daemon >/dev/null || { echo "SKIP files_info: dbus-daemon not found"; exit 0; }
case $work in "$root"/.dev/files-info) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-info) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac
rm -rf -- "$work" "$iso"
mkdir -p "$work/Desktop/Projects" "$busdir" "$iso"/{home,config,cache,state,data}
printf 'hello\n' >"$work/Desktop/Notes.txt"

env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 HOME="$iso/home" \
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
if grep -q "Operation not permitted" "$busdir/log" 2>/dev/null; then echo "SKIP files_info: the private bus cannot bind a Unix socket here (sandbox)"; exit 0; fi
bus=$(head -n 1 "$busdir/address" 2>/dev/null)
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "FAIL: refusing: the private bus did not start or has an unexpected address '$bus'"; exit 1 ;;
esac
[[ $bus != "$owner_bus" ]] || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# One app run per location: it logs "Get Info of <url> (<name>)" when the window is created.
info_of() { # path log
  env -u QT_QPA_PLATFORMTHEME -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 \
    GRASSFIELD_FILES_QML="$root/apps/files/qml" QML_IMPORT_PATH="$root/ui:$dev/build/qml" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
    setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" --info "$1" >"$2" 2>&1 </dev/null &
  app=$!
  for _ in $(seq 1 100); do
    grep -q "Get Info of\|no info for" "$2" 2>/dev/null && break
    kill -0 "$app" 2>/dev/null || break
    sleep 0.1
  done
  sleep 0.5
  if kill -0 "$app" 2>/dev/null; then
    kill -- "-$app" 2>/dev/null
    wait "$app" 2>/dev/null
  else
    wait "$app"
    echo "(the app exited by itself with status $?)" >>"$2"
  fi
  app=""
}

for case in "file:$work/Desktop/Notes.txt:Notes.txt" "folder:$work/Desktop/Projects:Projects" "desktop:$work/Desktop:Desktop"; do
  IFS=: read -r label path name <<<"$case"
  log=$work/$label.log
  info_of "$path" "$log"
  check "$label: the Get Info window opened" grep -q "Get Info of" "$log"
  check "$label: it shows \"$name\"" grep -q "Get Info of .*($name)" "$log"
  check "$label: no browser window (Get Info only)" test "$(grep -c 'cannot create a window' "$log")" = 0
  check "$label: no QML error" test "$(grep -cE 'TypeError|ReferenceError|is not a function|Cannot assign' "$log")" = 0
done
exit $fail
