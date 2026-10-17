#!/usr/bin/env bash
# Menu bridge vs. a hostile application (global menus review, MEDIUM): a huge GetLayout reply must not take the
# bridge down repeatedly, and an application that does must not be asked again.
#
#   B  1500 items of 20 kB labels (~30 MB reply, under the item cap): the menu is served, the peak RSS of the bridge
#      (VmHWM from /proc) stays below the unit's MemoryMax (256 MB).
#   A  40000 items (~40 MB reply, over the 2000 item cap): "oversized", exactly one GetLayout reaches the
#      application however often the window is opened again ("backoff"), same bridge process, bounded VmHWM.
#   C  the bridge is SIGKILLed by the application's first GetLayout (stand-in for the memory limit): the restarted
#      bridge refuses that application ("backoff", from the in-flight marker) and never sends a second GetLayout.
#
# Needs no compositor: a private dbus-daemon (/tmp/dbus-* socket, never the owner's bus), the bridge, tests/fixtures/huge-menu.
# Usage: tests/integration/menu_bridge_memory.sh      Exit: 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
max_kb=$((256 * 1024))
fail=0
say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }

command -v dbus-daemon >/dev/null || die "dbus-daemon is needed"
[[ -x $dev/build/grassfield-menu-bridge ]] || "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"
[[ -x $dev/build/huge-menu ]] || "$root/tests/fixtures/build.sh" huge-menu >/dev/null || die "huge-menu build failed"

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-mb.XXXXXX") || die "no temp dir"
chmod 700 "$work"
sock=$work/bridge.sock
((${#sock} < 100)) || die "socket path too long: $sock"
bus_pid="" bridge_pid=""

stop_all() {
  [[ -n $bridge_pid ]] && kill "$bridge_pid" 2>/dev/null
  [[ -n $bus_pid ]] && kill "$bus_pid" 2>/dev/null
  rm -rf "$work"
}
trap stop_all EXIT

setsid dbus-daemon --session --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
bus_pid=$!
for _ in $(seq 1 50); do [[ -s $work/bus.address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$work/bus.address")
case $bus in unix:path=/tmp/dbus-*) ;; *) die "unexpected bus address '$bus'" ;; esac
say "private bus $bus (dbus-daemon pid $bus_pid)"

start_bridge() {
  env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$sock" \
    setsid "$dev/build/grassfield-menu-bridge" >>"$work/bridge.log" 2>&1 </dev/null &
  bridge_pid=$!
  for _ in $(seq 1 50); do [[ -S $sock ]] && return 0; sleep 0.1; done
  return 1
}

hwm_kb() { awk '/^VmHWM:/ {print $2}' "/proc/$1/status" 2>/dev/null; }

fixture() { # <name> <args...>   (the app is the fixture; output in $work/<name>.out)
  local name=$1
  shift
  env DBUS_SESSION_BUS_ADDRESS="$bus" "$dev/build/huge-menu" --socket "$sock" "$@" >"$work/$name.out" 2>&1
}
getlayouts() { grep -c 'GetLayout #' "$work/$1.out"; }
replies() { grep -c "$2" "$work/$1.out"; }

start_bridge || die "bridge did not start ($work/bridge.log)"
first_pid=$bridge_pid
say "bridge pid $bridge_pid, idle VmHWM $(hwm_kb "$bridge_pid") kB"

say ""
say "[B] ~30 MB reply under the item cap"
fixture b --items 1500 --label-kb 20 --windows 1 --gap-ms 4000
sed 's/^/    /' "$work/b.out"
say "    VmHWM after: $(hwm_kb "$bridge_pid") kB (limit $max_kb kB)"
check "the menu was served" test "$(replies b 'reply menu')" -ge 1
check "bridge alive, same process" kill -0 "$first_pid"
check "peak RSS below MemoryMax" test "$(hwm_kb "$bridge_pid")" -lt "$max_kb"

say ""
say "[A] ~40 MB reply over the item cap, window opened 4 times"
fixture a --items 40000 --label-kb 1 --windows 4 --gap-ms 5000
sed 's/^/    /' "$work/a.out"
say "    VmHWM after: $(hwm_kb "$bridge_pid") kB (limit $max_kb kB)"
check "refused as oversized once" test "$(replies a 'oversized')" -eq 1
check "later opens answered with backoff, no new fetch" test "$(replies a 'backoff')" -eq 3
check "exactly one GetLayout reached the application" test "$(getlayouts a)" -eq 1
check "bridge alive, same process (no restart loop)" kill -0 "$first_pid"
check "peak RSS below MemoryMax" test "$(hwm_kb "$bridge_pid")" -lt "$max_kb"

say ""
say "[C] bridge killed during the first GetLayout, restarted"
(
  # A supervisor like systemd's Restart=on-failure.
  while kill -0 "$first_pid" 2>/dev/null; do sleep 0.1; done
  sleep 1
  start_bridge && echo "$bridge_pid" >"$work/second.pid"
) &
super=$!
fixture c --items 1500 --label-kb 20 --windows 3 --gap-ms 2500 --kill-pid "$first_pid" --service org.grassfield.HugeMenuC
wait "$super"
sed 's/^/    /' "$work/c.out"
second_pid=$(cat "$work/second.pid" 2>/dev/null)
bridge_pid=$second_pid
say "    restarted bridge pid ${second_pid:-none}"
check "the first bridge was killed and a second one runs" test -n "$second_pid" -a "$second_pid" != "$first_pid"
check "restarted bridge knows who killed its predecessor (log)" grep -q "a previous run died while reading" "$work/bridge.log"
check "the application is refused after the restart (backoff)" test "$(replies c 'backoff')" -ge 1
check "exactly one GetLayout in total (no crash loop)" test "$(getlayouts c)" -eq 1

say ""
if ((fail)); then say "RESULT: FAIL"; exit 1; fi
say "RESULT: PASS"
