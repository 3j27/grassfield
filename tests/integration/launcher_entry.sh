#!/usr/bin/env bash
# Badges, progress and urgent set by applications (ADR-0018, docs/specs/menu-bridge.md "LauncherEntry"):
# com.canonical.Unity.LauncherEntry.Update signals on a PRIVATE bus reach the shell as menu/1 "launcher" lines.
#
# The shell is played by tests/fixtures/menu-shell-tap.py (hello, then every line the bridge sends is appended to a file);
# applications are tests/fixtures/launcher-entry.py processes that hold their bus connection until the test stops them.
#
#   1  count: shown count, clamped to 99999 (and 0 for a negative one)
#   2  count-visible false: forwarded as count 0, visible again brings the count back
#   3  progress: 0.5, clamped to 1; progress-visible false: forwarded as -1
#   4  urgent true, then false
#   5  flood: 300 updates back to back from one sender: at most 20 per second go out at once, the rest is coalesced into
#      the last state, which does arrive
#   6  sender disconnect: its apps are forgotten (a launcher line with count, progress and urgent all null)
#   7  replay: a shell that connects later gets the state of the apps that are still there (not of the departed ones)
#   8  invalid uri (and a signal of the wrong signature): nothing is forwarded, the bridge logs a penalty, the sender is
#      refused for a moment (a valid update right after it is dropped), then served again
#
# Needs no compositor: a private dbus-daemon (/tmp/dbus-* socket, never the owner's bus), the bridge, python3 + PyGObject,
# jq. Waits are on what the shell received; the time limits only bound a hang.
# Usage: tests/integration/launcher_entry.sh      Exit: 0 PASS, 1 FAIL, 2 environment error.
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
wait_until() { # <seconds> <command...>: polls the condition every 100 ms, bounded
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
if [[ ! -x $bin || $root/bridges/menu-bridge/src/Launcher.cpp -nt $bin || $root/bridges/menu-bridge/src/Bridge.cpp -nt $bin ]]; then
  "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-le.XXXXXX") || die "no temp dir"
chmod 700 "$work"
sock=$work/bridge.sock
log=$work/bridge.log
((${#sock} < 100)) || die "socket path too long: $sock"
bus_pid=""
bridge_pid=""
tap_pid=""
apps_pids=()

stop_all() {
  local p
  for p in "${apps_pids[@]}" "$tap_pid" "$bridge_pid" "$bus_pid"; do
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
start_shell() { # a new "shell": lines the bridge sends go to $work/shell<N>.out (path in $shell_out)
  shell_n=$((shell_n + 1))
  shell_out=$work/shell$shell_n.out
  : >"$shell_out"
  python3 -I "$root/tests/fixtures/menu-shell-tap.py" --socket "$sock" --out "$shell_out" &
  tap_pid=$!
  wait_until 5 grep -q '"type":"status"' "$shell_out"
}
start_shell || die "the shell stand-in did not connect"

app_n=0
start_app() { # <steps...>: a test application; its pid is in $app_pid. Returns when its steps ran.
  app_n=$((app_n + 1))
  printf '%s\n' "$@" >"$work/app$app_n.steps"
  rm -f "$work/app$app_n.done"
  env DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 python3 -I "$root/tests/fixtures/launcher-entry.py" \
    --steps "$work/app$app_n.steps" --done "$work/app$app_n.done" --hold >>"$work/apps.log" 2>&1 &
  app_pid=$!
  apps_pids+=("$app_pid")
  wait_until 20 test -e "$work/app$app_n.done"
}

# A launcher line of <app> whose fields satisfy the jq expression (waits for it).
seen() { # <app> <jq condition on the line>
  jq -e -s --arg app "$1" "any(.[]; .type == \"launcher\" and .app == \$app and ($2))" "${3:-$shell_out}" >/dev/null 2>&1
}
await() { wait_until 5 seen "$@"; }
lines_of() { jq -c --arg app "$1" 'select(.type == "launcher" and .app == $app)' "$shell_out" 2>/dev/null | wc -l; }

say ""
say "[1] count"
start_app "emit ('application://countapp.desktop', {'count': <int64 5>, 'count-visible': <true>})" \
  "emit ('application://bigapp.desktop', {'count': <int64 123456789>})" \
  "emit ('application://negapp.desktop', {'count': <int64 -3>})"
check "count 5 reaches the shell, nothing else set" await countapp '.count == 5 and .progress == null and .urgent == null'
check "a huge count is clamped to 99999" await bigapp '.count == 99999'
check "a negative count is 0" await negapp '.count == 0'

say ""
say "[2] count-visible"
start_app "emit ('application://hideapp.desktop', {'count': <int64 7>})" \
  "sleep 150" \
  "emit ('application://hideapp.desktop', {'count-visible': <false>})" \
  "sleep 150" \
  "emit ('application://hideapp.desktop', {'count-visible': <true>})"
check "count 7" await hideapp '.count == 7'
check "count-visible false is count 0" await hideapp '.count == 0'
hide_sequence() { [[ $(jq -c 'select(.app == "hideapp") | .count' "$shell_out" | tr '\n' ' ') == "7 0 7 " ]]; }
check "count-visible true brings the count back (7, 0, 7)" wait_until 5 hide_sequence

say ""
say "[3] progress"
start_app "emit ('application://progapp.desktop', {'progress': <0.5>, 'progress-visible': <true>})" \
  "emit ('application://overapp.desktop', {'progress': <7.0>})" \
  "emit ('application://nanapp.desktop', {'progress': <1.5>})" \
  "emit ('application://barapp.desktop', {'progress': <0.25>})" \
  "sleep 150" \
  "emit ('application://barapp.desktop', {'progress-visible': <false>})"
check "progress 0.5" await progapp '.progress == 0.5 and .count == null'
check "progress above 1 is clamped to 1" await overapp '.progress == 1'
check "progress 1.5 is clamped (no NaN here, finite check is a unit test)" await nanapp '.progress == 1'
check "progress-visible false is progress -1" await barapp '.progress == -1'

say ""
say "[4] urgent"
start_app "emit ('application://urgapp.desktop', {'urgent': <true>})" \
  "sleep 150" \
  "emit ('application://urgapp.desktop', {'urgent': <false>})"
check "urgent true" await urgapp '.urgent == true and .count == null'
check "urgent false" await urgapp '.urgent == false'

say ""
say "[5] flood: 300 updates from one sender"
start_app "flood 300 floodapp"
check "the last state arrives (coalesced)" await floodapp '.count == 299'
n=$(lines_of floodapp)
say "    $n lines reached the shell for 300 updates"
check "at most 25 lines for 300 updates (20 per second plus the coalesced last one)" test "$n" -le 25
check "the shell saw fewer than were sent" test "$n" -lt 300
check "the bridge is alive" kill -0 "$bridge_pid"

say ""
say "[6] sender disconnect"
start_app "emit ('application://goneappa.desktop', {'count': <int64 3>})" \
  "emit ('application://goneappb.desktop', {'progress': <0.5>, 'urgent': <true>})"
gone_pid=$app_pid
both_arrived() { await goneappa '.count == 3' && await goneappb '.urgent == true'; }
check "both apps arrived" both_arrived
kill "$gone_pid" 2>/dev/null
check "goneappa is forgotten (all values null)" await goneappa '.count == null and .progress == null and .urgent == null'
check "goneappb is forgotten (all values null)" await goneappb '.count == null and .progress == null and .urgent == null'
check "an app of a sender that is still there is not forgotten" test "$(jq -c 'select(.app == "countapp" and .count == null and .progress == null and .urgent == null)' "$shell_out" | wc -l)" -eq 0

say ""
say "[7] replay to a shell that connects later"
start_app "emit ('application://replayapp.desktop', {'count': <int64 4>, 'urgent': <true>})"
await replayapp '.count == 4 and .urgent == true'
kill "$tap_pid" 2>/dev/null
wait "$tap_pid" 2>/dev/null
sleep 0.3
start_shell || die "the second shell stand-in did not connect"
check "the new shell gets the state of replayapp" await replayapp '.count == 4 and .urgent == true'
check "the new shell gets the state of countapp (its sender is still there)" await countapp '.count == 5'
check "the new shell gets nothing of the departed goneappa" test "$(lines_of goneappa)" -eq 0

say ""
say "[8] malformed input"
before=$(grep -c 'malformed LauncherEntry update' "$log")
start_app "emit ('application://bad/slash.desktop', {'count': <int64 5>})" \
  "sleep 700" \
  "emit ('application://dropped.desktop', {'count': <int64 1>})"
bad_pid=$app_pid
penalised() { (($(grep -c 'malformed LauncherEntry update' "$log") > before)); }
check "the bridge logged a penalty for the sender" wait_until 5 penalised
sleep 1
check "the invalid uri was not forwarded" test "$(lines_of 'bad/slash')" -eq 0
check "a valid update right after it is dropped (the sender is refused for a moment)" test "$(lines_of dropped)" -eq 0
kill "$bad_pid" 2>/dev/null
recovered=0
for i in $(seq 1 40); do
  rm -f "$work/rec.done"
  printf '%s\n' "emit ('application://recovered.desktop', {'count': <int64 2>})" >"$work/rec.steps"
  env DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 python3 -I "$root/tests/fixtures/launcher-entry.py" --steps "$work/rec.steps" --done "$work/rec.done" >>"$work/apps.log" 2>&1
  if wait_until 2 seen recovered '.count == 2'; then recovered=1; break; fi
  sleep 0.3
done
check "after the back-off the sender is served again" test "$recovered" -eq 1
start_app "raw (s) ('application://wrongsig.desktop',)"
sleep 1
check "a signal of the wrong signature is not forwarded" test "$(lines_of wrongsig)" -eq 0
check "the bridge survived all of it" kill -0 "$bridge_pid"

say ""
if ((fail)); then
  say "launcher_entry: FAIL (bridge log: $log, kept until exit; last lines below)"
  tail -n 15 "$log" | sed 's/^/    /'
  exit 1
fi
say "launcher_entry: PASS"
exit 0
