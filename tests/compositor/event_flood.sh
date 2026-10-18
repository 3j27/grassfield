#!/usr/bin/env bash
# Event flood (R11): a hostile client must not be able to flood Hyprland's socket2 through grassfield-compositor.
# Hyprland disconnects a socket2 subscriber whose event queue overflows ("Socket2 fd N overflowed event queue,
# removing"); for Quickshell that means no Hyprland event at all until the shell restarts.
#
# Usage: tests/compositor/event_flood.sh [requests...]      (default: 200 25000)
# Needs the nested instance with the plugin (feature "appmenu") and grassfield-shell (scripts/dev/nested-up.sh).
#
#   1 appmenu spam, once per count: tests/fixtures/appmenu-client --spam N maps a window and sends N valid
#     set_address requests on one appmenu object in one burst (alternating paths, the last one /MenuBar/final).
#     200 is the review case (socket2 overflow); 25000 the log flood case.
#   2 Lua flood: ONE dispatch (scripts/nestctl, nested only) runs hl.plugin.grassfield.hello() and
#     hl.plugin.grassfield.appmenu(<window>) 1000 times each.
#   3 shell: after each flood a new foot window must become the window grassfield-shell's menu bar shows
#     (qs ipc call menubar bridgeState): the shell still receives Hyprland events.
#
# Checks: plugin events per window and per flood within the coalescing bounds (at most one per window per 100 ms,
# docs/specs/compositor.md FR24), the final registration posted, the socket2 subscriber of this script (socat) still
# connected, no "overflowed event queue" line in the nested log, no event socket error in the shell log, a bounded
# number of plugin log lines, nested Hyprland alive.
# Exit: 0 PASS, 1 FAIL, 2 environment error. Log: .dev/event-flood/run-<stamp>/summary.txt (+ events.log).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
counts=("$@")
((${#counts[@]} > 0)) || counts=(200 25000)
for n in "${counts[@]}"; do
  [[ $n =~ ^[0-9]+$ ]] && ((n >= 2)) || { echo "usage: event_flood.sh [requests >= 2 ...]" >&2; exit 2; }
done

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh): a stale record
# may name another worktree's session.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "event_flood: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "event_flood: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "event_flood: grassfield-shell is not running" >&2; exit 2; }
for tool in socat jq qs foot; do
  command -v "$tool" >/dev/null || { echo "event_flood: $tool is needed" >&2; exit 2; }
done
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
nestctl -j grassfield | jq -e '.features | index("appmenu")' >/dev/null 2>&1 \
  || { echo "event_flood: the loaded plugin does not advertise \"appmenu\"" >&2; exit 2; }
if [[ ! -x $dev/build/appmenu-client ]] || ! grep -q -- '--spam' "$dev/build/appmenu-client"; then
  "$root/tests/fixtures/build.sh" appmenu-client >/dev/null || { echo "event_flood: fixture build failed" >&2; exit 2; }
fi

run=$dev/event-flood/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
summary=$run/summary.txt
events=$run/events.log
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
shelllog=$dev/shell.log
fail=0

say() { printf '%s\n' "$*" | tee -a "$summary"; }
check() { # <description> <0|1 status> [detail]
  if [[ $2 == 0 ]]; then say "  PASS $1${3:+ ($3)}"; else say "  FAIL $1${3:+ ($3)}"; fail=1; fi
}
lines() { [[ -r $1 ]] && wc -l <"$1" || echo 0; }
since() { tail -n +"$(($2 + 1))" "$1" 2>/dev/null; } # <file> <line count at start>: lines added since

pids=()
socat_pid=""
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
}
trap cleanup EXIT

# Read-only socket2 subscription, every line stamped (microseconds).
stamp() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$run/socat.err" </dev/null > >(stamp >"$events") &
socat_pid=$!
sleep 0.3

hyprlog0=$(lines "$hyprlog")
shelllog0=$(lines "$shelllog")
start_human=$(date '+%Y-%m-%d %H:%M:%S')

client_address() { # <pid> -> hex address (no 0x) of its mapped window
  nestctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p and .mapped)][0].address // "" | ltrimstr("0x")'
}
wait_address() { # <pid> <tries of 0.1 s>
  local a="" i
  for ((i = 0; i < $2; i++)); do
    a=$(client_address "$1")
    [[ -n $a ]] && break
    sleep 0.1
  done
  printf '%s\n' "$a"
}
appmenu_events() { # <from µs> <to µs> <address>: the plugin's appmenu events for that window in the interval
  awk -v a="$1" -v b="$2" '$1 >= a && $1 <= b' "$events" | grep -a "\"type\":\"appmenu\",\"address\":\"$3\""
}
shell_window() { # -> "<address> <app id>" of the window grassfield-shell's menu bar shows
  timeout 5 qs ipc --pid "$shell_pid" call menubar bridgeState "" 2>/dev/null | jq -r '"\(.window // "") \(.windowAppId // "")"' 2>/dev/null
}
# The shell still receives Hyprland events: a new window becomes the menu bar's window. Each foot gets its own app id:
# window addresses are reused, and the app id only resolves through the shell's Hyprland toplevel list (socket2).
probes=0
shell_sees_new_window() { # <label>
  local f addr shown="" i app
  probes=$((probes + 1))
  app=gf-event-flood-$probes
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name event-flood foot --app-id "$app" --title "event-flood $1" >/dev/null 2>&1 </dev/null &
  f=$!
  pids+=("$f")
  addr=$(wait_address "$f" 50)
  for ((i = 0; i < 25; i++)); do
    shown=$(shell_window)
    [[ -n $addr && $shown == "$addr $app" ]] && break
    sleep 0.2
  done
  [[ -n $addr && $shown == "$addr $app" ]]
  check "shell sees the window opened after $1" $? "foot ${addr:-none} $app, menu bar window ${shown:-none}"
  kill "$f" 2>/dev/null
  sleep 0.5
}

say "event flood run $run (nested $sig, plugin $(nestctl -j grassfield | jq -c .features), Hyprland $(nestctl -j version | jq -r .tag))"

# ---- 1 appmenu spam -------------------------------------------------------------------------------------------------
for n in "${counts[@]}"; do
  say ""
  say "[appmenu spam: $n set_address requests on one object of a mapped window]"
  out=$run/spam-$n.out
  WAYLAND_DISPLAY=$sock "$dev/build/appmenu-client" --spam "$n" --hold 1500 >"$out" 2>&1 </dev/null &
  app=$!
  pids+=("$app")
  for _ in $(seq 1 50); do grep -q 'ok window mapped' "$out" 2>/dev/null && break; sleep 0.1; done
  # The window has no registration before the burst (its focus event carries empty strings): every event with a
  # registration from here on comes from the burst.
  tm=${EPOCHREALTIME/./}
  addr=$(wait_address "$app" 20)
  for _ in $(seq 1 100); do grep -q 'set_address requests sent' "$out" 2>/dev/null && break; sleep 0.1; done
  t0=${EPOCHREALTIME/./}
  wait "$app"
  rc=$?
  sleep 0.4 # trailing posts are due 100 ms after the last one
  t1=${EPOCHREALTIME/./}
  sed 's/^appmenu-client: /    /' "$out" | tee -a "$summary"
  [[ $rc == 0 ]] && grep -q 'appmenu-client: PASS' "$out"
  check "client kept its connection" $? "exit $rc"
  sel=$(appmenu_events "$tm" "$t1" "$addr" | grep -a -v '"service":""')
  registered=$(grep -a -c . <<<"$sel")
  [[ -z $sel ]] && registered=0
  last_path=$(tail -n 1 <<<"$sel" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')
  say "  window $addr: $registered appmenu event(s) with a registration for $n requests:"
  sed 's/^[0-9]* /    /' <<<"$sel" | head -n 8 | tee -a "$summary"
  # The burst plus the 1.5 s hold: at most one post per 100 ms for this window (leading + trailing, ~2 expected).
  [[ -n $addr && $registered -ge 1 && $registered -le 20 ]]
  check "coalesced: $registered event(s) for $n requests (bound 20)" $?
  [[ $last_path == /MenuBar/final ]]
  check "the final registration was posted" $? "last path ${last_path:-none}"
  clears=$(appmenu_events "$t0" "$t1" "$addr" | grep -a -c '"service":"","path":""')
  [[ $clears -ge 1 ]]
  check "clear event after the client left" $? "$clears"
  kill -0 "$socat_pid" 2>/dev/null
  check "socket2 subscriber still connected" $?
  shell_sees_new_window "the $n-request spam"
done

# ---- 2 Lua flood ----------------------------------------------------------------------------------------------------
say ""
say "[Lua flood: one dispatch with 1000 hello() and 1000 appmenu(<window>) calls]"
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name event-flood foot --title "event-flood target" >/dev/null 2>&1 </dev/null &
target=$!
pids+=("$target")
taddr=$(wait_address "$target" 50)
sleep 0.5
t0=${EPOCHREALTIME/./}
reply=$(nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.hello and p.appmenu then for i = 1, 1000 do p.hello(); p.appmenu(\"0x$taddr\") end end end" 2>&1)
sleep 0.5
t1=${EPOCHREALTIME/./}
say "  dispatch reply: $(head -c 120 <<<"$reply")"
caps=$(awk -v a="$t0" -v b="$t1" '$1 >= a && $1 <= b' "$events" | grep -a -c '"type":"capabilities"')
menus=$(appmenu_events "$t0" "$t1" "$taddr" | grep -a -c .)
[[ -n $taddr && $caps -ge 1 && $caps -le 6 ]]
check "capabilities coalesced: $caps event(s) for 1000 hello() (bound 6)" $?
[[ $menus -ge 1 && $menus -le 6 ]]
check "appmenu re-emits coalesced: $menus event(s) for 1000 appmenu() (bound 6)" $?
kill -0 "$socat_pid" 2>/dev/null
check "socket2 subscriber still connected" $?
kill "$target" 2>/dev/null
sleep 0.3
shell_sees_new_window "the Lua flood"

# ---- 3 health -------------------------------------------------------------------------------------------------------
say ""
say "[health]"
sleep 1 # Hyprland buffers its log
overflow=$(since "$hyprlog" "$hyprlog0" | grep -a -c 'overflowed event queue')
[[ $overflow == 0 ]]
check "no socket2 overflow in the nested log" $? "$overflow line(s)"
since "$hyprlog" "$hyprlog0" | grep -a 'overflowed event queue' | head -n 3 | sed 's/^/    /' | tee -a "$summary"
sockerr=$(since "$shelllog" "$shelllog0" | grep -a -c -i 'event socket error')
[[ $sockerr == 0 ]]
check "no Hyprland event socket error in the shell log" $? "$sockerr line(s)"
total_requests=0
for n in "${counts[@]}"; do total_requests=$((total_requests + n)); done
plugin_lines=$(since "$hyprlog" "$hyprlog0" | grep -a -c '\[grassfield\] appmenu')
[[ $plugin_lines -le 60 ]]
check "plugin appmenu log lines bounded: $plugin_lines for $total_requests requests + 2000 Lua calls (bound 60)" $?
since "$hyprlog" "$hyprlog0" | grep -a '\[grassfield\]' | tail -n 12 | sed 's/^/    /' | tee -a "$summary"
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $? "pid $hypr_pid"
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
[[ ${dumps:-0} == 0 ]]
check "no core dump of the nested Hyprland" $? "${dumps:-0}"

say ""
if ((fail)); then say "RESULT: FAIL (summary $summary)"; exit 1; fi
say "RESULT: PASS (summary $summary)"
exit 0
