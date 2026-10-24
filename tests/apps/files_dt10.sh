#!/usr/bin/env bash
# Nested scenario DT-10 (GF-AUDIT-001 SEC-12 / GF-070): Grassfield Files never runs an app launcher, a script or a
# program that is opened (Return, as a double-click does). A sandbox folder holds t.desktop (Type=Application, executable),
# u.desktop (the same, not executable), Invoice.pdf.desktop and run.sh (executable); each one's Exec or body would create a
# marker file. Pass 1 runs Files with GRASSFIELD_FILES_NO_LAUNCH=1: each open must be refused by the guard (log "open
# refused") before the test switch ("launch blocked" never logged for them). Pass 2 runs Files WITHOUT the switch: the
# marker must never appear (the original DT-10). Both passes open each item with type-to-select + Return.
#
# Safety as tests/apps/files_sandbox.sh: everything under .dev/files-dt10, the app through scripts/dev/isolated.sh, a
# private D-Bus session bus started here (refuses the owner's bus), the nested Wayland socket only. If the guard were broken,
# pass 2 would only run `touch` on the marker inside the sandbox.
# Requires: scripts/dev/nested-up.sh running, .dev/build/grassfield-files (apps/files/build-direct.sh), dbus-daemon.
# Usage: tests/apps/files_dt10.sh [output]   (default GF-REF)   Prints PASS/FAIL per check.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
output=${1:-GF-REF}
sandbox=$dev/files-dt10
folder=$sandbox/folder
marker=$sandbox/marker
busdir=$sandbox/.bus
iso_name=files-dt10
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh

[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not found"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }
case $folder in "$root"/.dev/files-dt10/*) ;; *) echo "FAIL: unsafe sandbox path"; exit 1 ;; esac
rm -rf -- "$sandbox" "$dev/isolated/$iso_name"
mkdir -p "$folder" "$busdir"

launcher() { # <file> <mode>
  printf '[Desktop Entry]\nType=Application\nName=Invoice\nExec=touch %s\n' "$marker" >"$folder/$1"
  chmod "$2" "$folder/$1"
}
launcher t.desktop 755
launcher u.desktop 644
launcher Invoice.pdf.desktop 644
printf '#!/bin/sh\ntouch %s\n' "$marker" >"$folder/run.sh"
chmod 755 "$folder/run.sh"

env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY="$sock" GRASSFIELD_DEV=1 HOME="$dev/isolated/$iso_name/home" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
app=""
cleanup() {
  local pid
  for pid in $app $bus_pid; do
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && kill -- "-$pid" 2>/dev/null
  done
  [[ -n $app ]] && wait "$app" 2>/dev/null
  wait "$bus_pid" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 50); do [[ -s $busdir/address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$busdir/address" 2>/dev/null)
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
case $bus in unix:path=/tmp/dbus-*) ;; *) echo "FAIL: the private bus did not start ('$bus', see $busdir/log)"; exit 1 ;; esac
[[ $bus != "$owner_bus" && $bus != "unix:path=${XDG_RUNTIME_DIR:-}/bus"* ]] || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# run_pass <log> <extra env...>: start Files on the folder, open each item, quit.
run_pass() {
  local log=$1
  shift
  "$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
  env DBUS_SESSION_BUS_ADDRESS="$bus" "$@" QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" \
    setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$folder" >"$log" 2>&1 </dev/null &
  app=$!
  sleep 3
  kill -0 "$app" 2>/dev/null || { fail "Files exited at start ($log)"; app=""; return; }
  "$pointer" output "$output" abs 1050 600 sleep 200 click >/dev/null
  local name
  for name in t.desktop u.desktop Invoice.pdf.desktop run.sh; do
    sleep 1.2 # the type-to-select buffer expires
    "$keys" "$name"
    sleep 0.4
    "$keys" -k Return
    sleep 1
  done
  "$keys" -M ctrl -k w -m ctrl
  for _ in $(seq 1 50); do kill -0 "$app" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$app" 2>/dev/null && kill -- "-$app" 2>/dev/null
  app=""
}

run_pass "$sandbox/pass1.log" GRASSFIELD_FILES_NO_LAUNCH=1
n=$(grep -c "grassfield-files: open refused" "$sandbox/pass1.log" || true)
[[ $n == 4 ]] && pass "pass 1: the guard refused all four items ($n 'open refused')" || fail "pass 1: $n 'open refused' lines, expected 4 ($sandbox/pass1.log)"
b=$(grep -c "launch blocked" "$sandbox/pass1.log" || true)
[[ $b == 0 ]] && pass "pass 1: nothing reached the launch path (no 'launch blocked')" || fail "pass 1: $b item(s) reached the launch path"

run_pass "$sandbox/pass2.log"
sleep 2
[[ ! -e $marker ]] && pass "pass 2 (DT-10): no launcher, script or program ran (marker absent)" || fail "pass 2 (DT-10): the marker exists: something was run"
n=$(grep -c "grassfield-files: open refused" "$sandbox/pass2.log" || true)
[[ $n == 4 ]] && pass "pass 2: four refusals logged" || fail "pass 2: $n refusals logged, expected 4"

echo "files_dt10: $fails failure(s)"
exit $(( fails > 0 ))
