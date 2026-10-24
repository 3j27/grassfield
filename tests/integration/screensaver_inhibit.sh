#!/usr/bin/env bash
# org.freedesktop.ScreenSaver idle inhibitors through grassfield-menu-bridge (GF-AUDIT-001 GF-016 residual,
# docs/specs/security.md "ScreenSaver inhibitors"): Inhibit/UnInhibit on a PRIVATE bus reach the shell as menu/1
# "screensaver" lines.
#
#   1  the bridge owns org.freedesktop.ScreenSaver; a shell that connects gets "inhibited": false
#   2  Inhibit -> a cookie, the shell gets inhibited true (count 1); a second client too (count 2); the legacy /ScreenSaver
#      path works as well
#   3  another client's cookie and an unknown cookie change nothing (UnInhibit answers, count stays)
#   4  UnInhibit by the owner -> count drops; the last one -> inhibited false
#   5  a client that leaves the bus without UnInhibit: its cookies are dropped -> inhibited false
#   6  Lock, SetActive, GetActive, SimulateUserActivity answer NotSupported; nothing else is served
#   7  more than 16 cookies from one client: LimitsExceeded
#   8  replay: a shell that connects later gets the current state; the bridge stopping drops the shell's connection
#      (the shell then counts as not inhibited)
#
# Needs no compositor: a private dbus-daemon (/tmp/dbus-* socket, never the owner's bus), the bridge, python3 + PyGObject,
# jq. Runs bare, outside the sandbox (Unix sockets). Usage: tests/integration/screensaver_inhibit.sh  Exit: 0 PASS,
# 1 FAIL, 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
fail=0
say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }
wait_until() { # <seconds> <command...>
  local limit=$(($1 * 10)) i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

for tool in dbus-daemon jq python3; do
  command -v "$tool" >/dev/null || die "$tool is needed"
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || die "PyGObject (gi, Gio) is needed"
bin=$dev/build/grassfield-menu-bridge
if [[ ! -x $bin || $root/bridges/menu-bridge/src/ScreenSaver.cpp -nt $bin || $root/bridges/menu-bridge/src/Bridge.cpp -nt $bin ]]; then
  "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-ss.XXXXXX") || die "no temp dir"
chmod 700 "$work"
sock=$work/bridge.sock
log=$work/bridge.log
((${#sock} < 100)) || die "socket path too long: $sock"
bus_pid="" bridge_pid="" tap_pid=""
client_pids=()
stop_all() {
  local p
  for p in "${client_pids[@]}" "$tap_pid" "$bridge_pid" "$bus_pid"; do
    [[ -n $p ]] && kill "$p" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf "$work"
}
trap stop_all EXIT

setsid dbus-daemon --session --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
bus_pid=$!
wait_until 5 test -s "$work/bus.address"
bus=$(head -n 1 "$work/bus.address")
case $bus in unix:path=/tmp/dbus-*) ;; *) die "unexpected bus address '$bus'" ;; esac
say "private bus $bus (dbus-daemon pid $bus_pid)"

env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$sock" \
  setsid "$bin" >>"$log" 2>&1 </dev/null &
bridge_pid=$!
wait_until 10 test -S "$sock" || die "the bridge did not start ($log)"

shell_n=0
start_shell() {
  shell_n=$((shell_n + 1))
  shell_out=$work/shell$shell_n.out
  : >"$shell_out"
  python3 -I "$root/tests/fixtures/menu-shell-tap.py" --socket "$sock" --out "$shell_out" &
  tap_pid=$!
  wait_until 5 grep -q '"type":"status"' "$shell_out"
}
# The last screensaver line of the current shell satisfies the jq condition.
last_is() { jq -e -s "map(select(.type == \"screensaver\")) | last | ($1)" "$shell_out" >/dev/null 2>&1; }
await() { wait_until 5 last_is "$1"; }

client_n=0
start_client() { # <steps...>: a client holding its connection; pid in $client_pid, results in $client_out
  client_n=$((client_n + 1))
  printf '%s\n' "$@" >"$work/c$client_n.steps"
  client_out=$work/c$client_n.out
  : >"$client_out"
  env DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 python3 -I "$root/tests/fixtures/screensaver-client.py" \
    --steps "$work/c$client_n.steps" --out "$client_out" --done "$work/c$client_n.done" --hold >>"$work/clients.log" 2>&1 &
  client_pid=$!
  client_pids+=("$client_pid")
  wait_until 20 test -e "$work/c$client_n.done"
}

say ""
say "[1] ownership and first state"
start_shell || die "the shell stand-in did not connect"
check "the bridge owns org.freedesktop.ScreenSaver" grep -q "owning org.freedesktop.ScreenSaver" "$log"
check "a new shell gets inhibited false" await '.inhibited == false and .count == 0'

say ""
say "[2] Inhibit"
start_client "inhibit VLC playing video"
a_pid=$client_pid a_out=$client_out
check "Inhibit returns a cookie" grep -q '^cookie [1-9]' "$a_out"
check "the shell gets inhibited true, count 1" await '.inhibited == true and .count == 1'
start_client "inhibit Chromium video" "inhibit-legacy Steam game"
b_pid=$client_pid b_out=$client_out
check "a second client and the legacy path: count 3" await '.count == 3'
check "the bridge logs the applications" grep -q "from Chromium, Steam, VLC" "$log"

say ""
say "[3] other clients' and unknown cookies"
a_cookie=$(awk '/^cookie/ {print $2; exit}' "$a_out")
start_client "uninhibit-raw $a_cookie" "uninhibit-raw 7" "sleep 200"
check "UnInhibit of another client's cookie answers" test "$(grep -c '^ok' "$client_out")" -eq 2
sleep 0.5
check "... and changes nothing (count 3)" last_is '.count == 3'

say ""
say "[4] UnInhibit"
kill "$client_pid" 2>/dev/null
# A cookie is released over the connection that took it: this client takes one and releases it in its own steps.
start_client "inhibit Totem video" "sleep 300" "uninhibit 0"
check "UnInhibit by the owner answers" grep -qx ok "$client_out"
check "UnInhibit by the owner: back to count 3 (after 4)" await '.count == 3'
check "the count went through 4" jq -e -s 'any(.[]; .type == "screensaver" and .count == 4)' "$shell_out"
kill "$b_pid" 2>/dev/null
check "a client that leaves drops its two cookies (count 1)" await '.count == 1'

say ""
say "[5] a client that leaves the bus"
kill "$a_pid" 2>/dev/null
check "VLC left without UnInhibit: inhibited false" await '.inhibited == false and .count == 0'

say ""
say "[6] nothing else is served"
start_client "call Lock" "call SetActive" "call GetActive" "call SimulateUserActivity"
check "Lock, SetActive, GetActive, SimulateUserActivity: NotSupported (4)" test "$(grep -c 'NotSupported' "$client_out")" -eq 4

say ""
say "[7] limits"
steps=()
for i in $(seq 1 17); do steps+=("inhibit Flood f$i"); done
start_client "${steps[@]}"
flood_pid=$client_pid
check "16 cookies, then LimitsExceeded" bash -c "[[ \$(grep -c '^cookie' '$client_out') == 16 && \$(grep -c 'LimitsExceeded' '$client_out') == 1 ]]"

say ""
say "[8] replay and bridge exit"
kill "$tap_pid" 2>/dev/null
start_shell || die "the second shell stand-in did not connect"
check "a shell that connects later gets the current state (16)" await '.inhibited == true and .count == 16'
kill "$flood_pid" 2>/dev/null
check "and the release" await '.inhibited == false'
kill "$bridge_pid" 2>/dev/null
check "the bridge stopping closes the shell's connection" wait_until 5 bash -c "! kill -0 $tap_pid 2>/dev/null"
check "the bridge released the name on a clean stop" grep -q "stopped" "$log"

say ""
if ((fail)); then
  say "screensaver_inhibit: FAIL (bridge log, last lines):"
  tail -n 15 "$log" | sed 's/^/    /'
  exit 1
fi
say "screensaver_inhibit: PASS"
exit 0
