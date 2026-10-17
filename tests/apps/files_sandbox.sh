#!/usr/bin/env bash
# Nested scenario (L1) for grassfield-files: copy/paste, rename, undo/redo, new folder, duplicate,
# move to Trash and Put Back, driven through the app with the nested keyboard and pointer only.
#
# Safety: every file the app touches lives under .dev/files-sandbox/scenario. The app runs with all
# XDG directories inside .dev/files-sandbox/.scenario-env, so its Trash is a sandbox Trash on the same
# filesystem (KIO's home trash = $XDG_DATA_HOME/Trash) and the owner's Trash, config and caches are
# never written. The owner's Trash is only counted (read only) before and after.
#
# Requires: scripts/dev/nested-up.sh running, .dev/build/grassfield-files (apps/files/build-direct.sh).
# Usage: tests/apps/files_sandbox.sh [output]   (default output GF-REF, 1920x1080)   Prints PASS/FAIL per step.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
output=${1:-GF-REF}
sandbox=$dev/files-sandbox
scenario=$sandbox/scenario
envdir=$sandbox/.scenario-env
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh
log=$dev/files-scenario.log

[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
[[ -s $dev/nested.wayland ]] || { echo "FAIL: no nested instance (run scripts/dev/nested-up.sh)"; exit 1; }
sock=$(<"$dev/nested.wayland")

# Fresh sandbox (paths are checked to stay inside .dev/files-sandbox).
case $scenario in "$root"/.dev/files-sandbox/*) ;; *) echo "FAIL: unsafe sandbox path"; exit 1 ;; esac
rm -rf -- "$scenario" "$envdir"
mkdir -p "$scenario/src" "$scenario/dest" "$envdir"/{config,data,cache,state,grassfield}
printf 'alpha\n' >"$scenario/src/alpha.txt"
printf 'beta\n' >"$scenario/src/beta.txt"
trash=$envdir/data/Trash

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
env XDG_CONFIG_HOME="$envdir/config" XDG_DATA_HOME="$envdir/data" XDG_CACHE_HOME="$envdir/cache" \
  XDG_STATE_HOME="$envdir/state" GRASSFIELD_CONFIG_HOME="$envdir/grassfield" GRASSFIELD_STATE_HOME="$envdir/state" \
  GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" \
  setsid "$bin" "$scenario/src" >"$log" 2>&1 </dev/null &
app=$!
trap 'kill "$app" 2>/dev/null; wait "$app" 2>/dev/null' EXIT
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
errors=$(grep -cE "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log" || true)
[[ $errors == 0 ]] && pass "app log has no QML errors or warnings" || { fail "app log has $errors QML lines"; grep -E "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log"; }

echo "files_sandbox: $fails failure(s)"
exit $(( fails > 0 ))
