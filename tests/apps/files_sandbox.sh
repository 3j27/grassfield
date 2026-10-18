#!/usr/bin/env bash
# Nested scenario (L1) for grassfield-files: copy/paste, rename, undo/redo, new folder, duplicate,
# move to Trash and Put Back, driven through the app with the nested keyboard and pointer only.
#
# Safety: every file the app touches lives under .dev/files-sandbox/scenario. The app runs through
# scripts/dev/isolated.sh (every XDG directory under .dev/isolated/files-sandbox, no DISPLAY), so its Trash is a
# sandbox Trash on the same filesystem (KIO's home trash = $XDG_DATA_HOME/Trash) and the owner's Trash, config and
# caches are never written. It talks to a private D-Bus session bus started here (never the owner's: KIO
# D-Bus-activates kiod6, kpasswdserver6 and kioexecd6, which would otherwise run with the owner's environment); the
# bus daemon itself has the same isolated XDG homes and the nested Wayland socket, so whatever it activates is
# isolated too. The script refuses to run when that bus would be the owner's. The owner's Trash is only counted
# (read only) before and after.
#
# Requires: scripts/dev/nested-up.sh running, .dev/build/grassfield-files (apps/files/build-direct.sh), dbus-daemon.
# Usage: tests/apps/files_sandbox.sh [output]   (default output GF-REF, 1920x1080)   Prints PASS/FAIL per step.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
output=${1:-GF-REF}
sandbox=$dev/files-sandbox
scenario=$sandbox/scenario
busdir=$sandbox/.bus
iso_name=files-sandbox
iso=$dev/isolated/$iso_name
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh
log=$dev/files-scenario.log

[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not found"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }

# Fresh sandbox and isolated homes (paths are checked to stay inside .dev).
case $scenario in "$root"/.dev/files-sandbox/*) ;; *) echo "FAIL: unsafe sandbox path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-sandbox) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac
rm -rf -- "$scenario" "$busdir" "$iso" "$sandbox/.scenario-env"
mkdir -p "$scenario/src" "$scenario/dest" "$busdir" "$iso"/{home,config,cache,state,data}
printf 'alpha\n' >"$scenario/src/alpha.txt"
printf 'beta\n' >"$scenario/src/beta.txt"
trash=$iso/data/Trash

# Private session bus (same configuration as dbus-run-session and scripts/dev/shell-run.sh: socket in /tmp, as libdbus
# caps socket paths at 99 bytes). Activated services inherit this environment: isolated homes, nested Wayland socket,
# GRASSFIELD_DEV=1, no DISPLAY and no owner bus address.
env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY="$sock" GRASSFIELD_DEV=1 HOME="$iso/home" \
  XDG_CONFIG_HOME="$iso/config" XDG_CACHE_HOME="$iso/cache" XDG_STATE_HOME="$iso/state" XDG_DATA_HOME="$iso/data" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
app=""
# Stops what this script started: the app's and the bus's process groups (both started with setsid, so each PID is
# its group: KIO workers and bus-activated services go with them).
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
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "FAIL: refusing: the private bus did not start or has an unexpected address '$bus' (see $busdir/log)"; exit 1 ;;
esac
[[ $bus != "$owner_bus" && $bus != "unix:path=${XDG_RUNTIME_DIR:-}/bus"* ]] \
  || { echo "FAIL: refusing to run on the owner's session bus"; exit 1; }
kill -0 "$bus_pid" 2>/dev/null || { echo "FAIL: the private bus exited (see $busdir/log)"; exit 1; }
echo "files_sandbox: private bus $bus (pid $bus_pid)"

owner_trash=$HOME/.local/share/Trash/files
owner_before=$( [[ -d $owner_trash ]] && find "$owner_trash" -mindepth 1 -maxdepth 1 | wc -l || echo 0)

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
# wait_until <seconds> <command...>: poll every 100 ms.
wait_until() {
  local limit=$(( $1 * 10 )); shift
  for _ in $(seq 1 "$limit"); do "$@" && return 0; sleep 0.1; done
  return 1
}
check() { # check <description> <seconds> <command...>
  local what=$1; shift
  if wait_until "$@"; then pass "$what"; else fail "$what"; fi
}
type_keys() { "$keys" "$@"; sleep 0.4; }
ctrl() { "$keys" -M ctrl "$@" -m ctrl; sleep 0.6; }
ctrl_shift() { "$keys" -M ctrl -M shift "$@" -m shift -m ctrl; sleep 0.6; }
shot() { "$root/scripts/dev/shot.sh" "files-scenario-$1" "$output" >/dev/null; }

# The window opens on the output under the pointer.
# Clicking the empty desktop focuses that monitor, so the window opens there (centred).
"$pointer" output "$output" abs 960 540 sleep 100 click >/dev/null
# isolated.sh sets the XDG and GRASSFIELD homes (under .dev/isolated/files-sandbox), GRASSFIELD_DEV=1 and drops DISPLAY.
env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 \
  QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$scenario/src" >"$log" 2>&1 </dev/null &
app=$!
sleep 3
kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
# Focus the window: click on empty space inside it (below the two icons).
"$pointer" output "$output" abs 1050 600 sleep 200 click >/dev/null
sleep 0.5

# 1. Copy alpha.txt (type-to-select, Ctrl+C), go up (Ctrl+Up), open dest (type-to-select, Return), paste.
type_keys alpha
ctrl -k c
ctrl -k Up
type_keys dest
type_keys -k Return
sleep 0.8
ctrl -k v
check "paste copies alpha.txt into dest" 5 test -f "$scenario/dest/alpha.txt"
check "source alpha.txt is kept" 1 test -f "$scenario/src/alpha.txt"
shot 1-pasted

# 2. Rename the pasted file (selected after the paste) with F2: the base name is preselected.
type_keys -k F2
type_keys gamma
type_keys -k Return
check "F2 renames alpha.txt to gamma.txt" 5 test -f "$scenario/dest/gamma.txt"
check "alpha.txt is gone from dest" 1 test ! -e "$scenario/dest/alpha.txt"

# 3. New folder (Ctrl+Shift+N) starts an inline rename; name it, then undo and redo the rename.
ctrl_shift -k n
# The inline editor opens once the listing shows the new folder.
wait_until 5 test -d "$scenario/dest/untitled folder" || fail "Ctrl+Shift+N did not create 'untitled folder'"
sleep 1
type_keys Projects
type_keys -k Return
check "Ctrl+Shift+N creates a folder renamed to Projects" 5 test -d "$scenario/dest/Projects"
shot 2-folder
ctrl -k z
check "Ctrl+Z undoes the rename (untitled folder is back)" 5 test -d "$scenario/dest/untitled folder"
ctrl_shift -k z
check "Ctrl+Shift+Z redoes it (Projects again)" 5 test -d "$scenario/dest/Projects"

# 4. Duplicate gamma.txt (Ctrl+D) -> "gamma copy.txt".
type_keys gamma
ctrl -k d
check "Ctrl+D duplicates gamma.txt as 'gamma copy.txt'" 5 test -f "$scenario/dest/gamma copy.txt"

# 5. Move gamma.txt to the sandbox Trash (Ctrl+Backspace).
"$keys" -k Escape; sleep 0.3
sleep 1.1   # let the type-to-select buffer expire
type_keys gamma.
ctrl -k BackSpace
check "Ctrl+Backspace moves gamma.txt out of dest" 5 test ! -e "$scenario/dest/gamma.txt"
check "gamma.txt is in the sandbox Trash" 3 test -f "$trash/files/gamma.txt"
check "the Trash has its .trashinfo" 1 test -f "$trash/info/gamma.txt.trashinfo"

# 6. Open trash:/ with Go to Folder (Ctrl+Shift+G), select it, Put Back (Ctrl+Backspace in the Trash).
ctrl_shift -k g
type_keys "trash:/"
type_keys -k Return
sleep 1
shot 3-trash
type_keys gamma
ctrl -k BackSpace
check "Put Back restores dest/gamma.txt" 5 test -f "$scenario/dest/gamma.txt"
check "the sandbox Trash is empty again" 3 bash -c "[[ -z \$(ls -A '$trash/files') ]]"

# 7. Back to dest (Ctrl+[) and check the listing still matches the filesystem.
ctrl -k bracketleft
sleep 0.8
shot 4-final
actual=$(cd "$scenario/dest" && ls -A | LC_ALL=C sort | paste -sd, -)
actual_src=$(cd "$scenario/src" && ls -A | LC_ALL=C sort | paste -sd, -)
[[ $actual_src == "alpha.txt,beta.txt" ]] && pass "src unchanged ($actual_src)" || fail "src changed: $actual_src"
expected="Projects,gamma copy.txt,gamma.txt"
[[ $actual == "$expected" ]] && pass "dest is exactly: $actual" || fail "dest is '$actual', expected '$expected'"

# 8. Close the window (Ctrl+W on the last tab quits the app).
ctrl -k w
if wait_until 5 bash -c "! kill -0 $app 2>/dev/null"; then pass "Ctrl+W closes the last window and quits"; else fail "app still running after Ctrl+W"; fi

owner_after=$( [[ -d $owner_trash ]] && find "$owner_trash" -mindepth 1 -maxdepth 1 | wc -l || echo 0)
[[ $owner_before == "$owner_after" ]] && pass "owner Trash untouched ($owner_after entries)" || fail "owner Trash changed: $owner_before -> $owner_after"
launches=$(grep -c "launch blocked" "$log" || true)
[[ $launches == 0 ]] && pass "no application launch was attempted" || fail "$launches application launch(es) attempted (blocked by GRASSFIELD_FILES_NO_LAUNCH)"
errors=$(grep -E "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log" | grep -vcE "qml: grassfield: global menu (created|destroyed)" || true)
[[ $errors == 0 ]] && pass "app log has no QML errors or warnings" || { fail "app log has $errors QML lines"; grep -E "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log"; }

echo "files_sandbox: $fails failure(s)"
exit $(( fails > 0 ))
