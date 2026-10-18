#!/usr/bin/env bash
# Nested scenario (L1) for grassfield-files, F14 (registrar watcher, apps/globalmenu.h): the window's global menu
# appears when com.canonical.AppMenu.Registrar comes onto the bus, disappears when it goes (cleanly, and abruptly like
# a crash: SIGKILL) and comes back with the next owner.
#
# Safety: a private session bus started here (isolated HOME and XDG homes like scripts/dev/shell-run.sh, ADR-0011; the
# script refuses the owner's bus), the fake registrar fixture (tests/fixtures/fake-registrar, which itself refuses a bus
# that is not private) and the app through scripts/dev/isolated.sh (.dev/isolated/files-registrar). Only the process
# groups started here are signalled. Files are under .dev/files-registrar.
#
# Requires: scripts/dev/nested-up.sh running (bare command), .dev/build/grassfield-files, .dev/build/fake-registrar
# (tests/fixtures/build.sh fake-registrar), dbus-daemon.
# Usage: tests/apps/files_registrar.sh   Prints PASS/FAIL per step; exit 1 on any FAIL.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
bin=$dev/build/grassfield-files
registrar=$dev/build/fake-registrar
work=$dev/files-registrar
busdir=$work/.bus
iso_name=files-registrar
iso=$dev/isolated/$iso_name
log=$work/app.log

[[ -x $bin ]] || { echo "FAIL: $bin missing (run apps/files/build-direct.sh)"; exit 1; }
[[ -x $registrar ]] || { echo "FAIL: $registrar missing (run tests/fixtures/build.sh fake-registrar)"; exit 1; }
command -v dbus-daemon >/dev/null || { echo "FAIL: dbus-daemon not found"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "FAIL: no verified nested instance of this tree (run scripts/dev/nested-up.sh as a bare command)"; exit 1; }
sock=$DEV_NESTED_SOCK
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "FAIL: refusing the main Wayland socket"; exit 1; }

case $work in "$root"/.dev/files-registrar) ;; *) echo "FAIL: unsafe work path"; exit 1 ;; esac
case $iso in "$root"/.dev/isolated/files-registrar) ;; *) echo "FAIL: unsafe isolated path"; exit 1 ;; esac
rm -rf -- "$work" "$iso"
mkdir -p "$work/dir" "$busdir" "$iso"/{home,config,cache,state,data}
printf 'one\n' >"$work/dir/one.txt"

env -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY="$sock" GRASSFIELD_DEV=1 HOME="$iso/home" \
  XDG_CONFIG_HOME="$iso/config" XDG_CACHE_HOME="$iso/cache" XDG_STATE_HOME="$iso/state" XDG_DATA_HOME="$iso/data" \
  setsid dbus-daemon --session --nofork --print-address=1 >"$busdir/address" 2>"$busdir/log" </dev/null &
bus_pid=$!
app="" reg=""
cleanup() {
  local pid
  for pid in $reg $app $bus_pid; do
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
echo "files_registrar: private bus $bus (pid $bus_pid)"

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
wait_until() { local limit=$(( $1 * 10 )); shift; for _ in $(seq 1 "$limit"); do "$@" && return 0; sleep 0.1; done; return 1; }
count() { grep -ac -- "$1" "$2" 2>/dev/null || true; }
start_registrar() { # <log>
  env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_PRIVATE_BUS=1 WAYLAND_DISPLAY="$sock" setsid "$registrar" >"$1" 2>&1 </dev/null &
  reg=$!
}
registered() { [[ $(count "RegisterWindow id=" "$1") -ge 1 ]]; }
app_says() { [[ $(count "$1" "$log") -ge $2 ]]; }

# 1. Files started before any registrar: no global menu export.
env DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_FORCE_STDERR_LOGGING=1 \
  QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$sock" \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso_name" -- "$bin" "$work/dir" >"$log" 2>&1 </dev/null &
app=$!
sleep 3
kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
[[ $(count "registrar" "$log") == 0 ]] && pass "started without a registrar: nothing exported, no registrar message" || fail "unexpected registrar message before any registrar"

# 2. The registrar appears: the window registers its menu bar.
start_registrar "$work/registrar-1.log"
wait_until 10 grep -aq "owning" "$work/registrar-1.log" || { echo "FAIL: fake registrar did not start"; cat "$work/registrar-1.log"; exit 1; }
if wait_until 10 registered "$work/registrar-1.log"; then pass "registrar appeared: the window registered its menu ($(grep -a -m1 'RegisterWindow id=' "$work/registrar-1.log" | sed 's/^fake-registrar: //'))"; else fail "no RegisterWindow after the registrar appeared"; fi
app_says "global menu registrar available" 1 && pass "app log: registrar available" || fail "app log lacks 'registrar available'"

# 3. The registrar goes away abruptly (SIGKILL, like a crash): the app drops its menu bar.
kill -9 -- "-$reg" 2>/dev/null
wait "$reg" 2>/dev/null
reg=""
if wait_until 10 app_says "global menu registrar gone" 1; then pass "registrar killed (SIGKILL): the app noticed it vanished"; else fail "app did not notice the registrar vanishing"; fi
kill -0 "$app" 2>/dev/null && pass "app still running after the crash of the registrar" || fail "app died when the registrar vanished"

# 4. A new registrar: the menu comes back (a fresh menu bar registers again).
start_registrar "$work/registrar-2.log"
wait_until 10 grep -aq "owning" "$work/registrar-2.log" || { echo "FAIL: second fake registrar did not start"; exit 1; }
if wait_until 10 registered "$work/registrar-2.log"; then pass "new registrar: the window registered again"; else fail "no RegisterWindow at the new registrar"; fi
app_says "global menu registrar available" 2 && pass "app log: registrar available again" || fail "app log lacks the second 'registrar available'"

# 5. A clean exit of the registrar (SIGTERM) removes the menu as well.
kill -- "-$reg" 2>/dev/null
wait "$reg" 2>/dev/null
reg=""
if wait_until 10 app_says "global menu registrar gone" 2; then pass "registrar stopped cleanly: the app dropped its menu again"; else fail "app did not notice the clean exit"; fi

# 6. Third owner, then the app exits cleanly.
start_registrar "$work/registrar-3.log"
wait_until 10 registered "$work/registrar-3.log" && pass "third registrar: registered once more" || fail "no RegisterWindow at the third registrar"
errors=$(grep -cE "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log" || true)
[[ $errors == 0 ]] && pass "app log has no QML errors or warnings" || { fail "app log has $errors QML lines"; grep -E "qml:|\.qml:[0-9]+|TypeError|ReferenceError" "$log"; }

echo "files_registrar: $fails failure(s)"
exit $(( fails > 0 ))
