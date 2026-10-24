#!/usr/bin/env bash
# Nested scenario (L1): closing a full-attention surface gives the keyboard to the window that is frontmost NOW, not to the
# one remembered when the surface opened (macOS model; shell/platform/FocusReturn.*). Bare command, nested session only,
# the compositor plugin with Stages loaded (feature "stages-available"); without a session or the plugin it SKIPs.
#   1 control: the Notification Center opens and closes with nothing changed: the window that had the keyboard gets it back;
#   2 the Center is open, a Stages swap brings the strip stage of A forward (the plugin by IPC, as the shell's tile press
#     does), the Center closes: A (the swapped-in front window) has the keyboard, never B (now in the strip).
# Test windows have app ids gf-fr-*; they are closed and Stages is turned off at the end, also when the test fails.
# Expected: "focus_return_stages: 0 failure(s)" after PASS lines. Exit 0 PASS or SKIP, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP focus_return_stages: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "focus_return_stages: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "focus_return_stages: grassfield-shell is not running"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
nest() { "$root/scripts/nestctl" "$@"; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" 2>/dev/null; }
wait_for() { local n; for n in $(seq 1 40); do "$@" && return 0; sleep 0.2; done; return 1; }
active_class() { nest -j activewindow 2>/dev/null | jq -r '.class // ""'; }

nest -j grassfield 2>/dev/null | jq -e '.features | index("stages-available")' >/dev/null || {
  echo "SKIP focus_return_stages: the compositor plugin with Stages is not loaded"
  exit 0
}
OUT=$(nest -j monitors | jq -r '([.[] | select(.name == "GF-REF")][0] // [.[] | select(.disabled | not)][0]).name')
read -r mon_x mon_y <<<"$(nest -j monitors | jq -r --arg o "$OUT" '.[] | select(.name == $o) | "\(.x) \(.y)"')"
[[ -n $OUT && -n ${mon_x:-} ]] || { echo "focus_return_stages: no output"; exit 2; }
tiles=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '[range(0; 4) as $i | {x: ($x + 16), y: ($y + 100 + $i * 190), w: 188, h: 160}]')
on_json=$(jq -nc --arg o "$OUT" --argjson t "$tiles" '{op: "on", durationMs: 0, strips: [{monitor: $o, hidden: false, tiles: $t}]}')
events=$(mktemp)
fixlog=$(mktemp)
fixture_pid=""
strip_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '{x: $x, y: ($y + 60), w: 220, h: 860}')
# The strip surface the plugin needs (the shell's own appears with Settings windows.stages): the Stages test fixture.
start_fixture() {
  GF_STAGES_OUTPUT=$OUT GF_STAGES_STRIP=$strip_json GF_STAGES_TILES=$tiles WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    DBUS_SESSION_BUS_ADDRESS=$(head -n 1 "$dev/bus.address" 2>/dev/null) \
    setsid "$root/scripts/dev/isolated.sh" --name stages-fixture qs -p "$root/tests/compositor/stages-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  local i
  for i in $(seq 1 50); do
    grep -q "\[stages-fixture\] output .* found" "$fixlog" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5
}
stages() { nest dispatch "hl.plugin.grassfield.stages([[$1]])" >/dev/null 2>&1; }

socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT >"$events" 2>/dev/null </dev/null &
socat_pid=$!
pids=()
cleanup() {
  stages '{"op":"off","durationMs":0}'
  nest dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
  [[ $(ipc notifications status) == *"center=true"* ]] && ipc notifications toggleCenter >/dev/null
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  kill "$socat_pid" 2>/dev/null
  [[ -n $fixture_pid ]] && { kill "$fixture_pid" 2>/dev/null; pkill -P "$fixture_pid" 2>/dev/null; }
  rm -f "$events" "$fixlog"
}
trap cleanup EXIT

last_stages() { grep -a 'grassfield>>{"v":"gfc/1","type":"stages"' "$events" | tail -n 1 | sed 's/^grassfield>>//'; }
stage_of_class() { # <class> -> id of the stage holding that window
  local addr
  addr=$(nest -j clients | jq -r --arg c "$1" '[.[] | select(.class == $c)][0].address | sub("^0x"; "")')
  last_stages | jq -r --arg a "$addr" '[.monitors[0].stages[] | select(any(.windows[]; .address == $a)) | .id][0] // ""'
}
active_stage() { last_stages | jq -r '.monitors[0].active // ""'; }
center_is() { [[ $(ipc notifications status) == *"center=$1"* ]]; }
open_foot() { # <app id>
  "$root/scripts/dev/pointer.sh" output "$OUT" abs 700 500 >/dev/null 2>&1 # windows open on the focused output
  sleep 0.4
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  wait_for test "$(active_class)" = "$1"
  sleep 0.5
}

[[ $(ipc notifications status) == *"server="* ]] || { echo "SKIP focus_return_stages: notifications refused (not a dev session)"; exit 0; }
nest dispatch 'hl.plugin.grassfield.config("stagesEnabled", "true")' >/dev/null 2>&1
start_fixture
stages "$on_json"
sleep 0.5
open_foot gf-fr-a
open_foot gf-fr-b
sleep 0.8
[[ $(active_class) == gf-fr-b ]] || { fail "setup: b should have the keyboard, '$(active_class)' has it"; echo "focus_return_stages: $fails failure(s)"; exit 1; }

# 1 control: nothing changes while the Center is open
ipc notifications toggleCenter >/dev/null
wait_for center_is true || fail "1: the Center did not open"
sleep 0.5
ipc notifications toggleCenter >/dev/null
wait_for center_is false || fail "1: the Center did not close"
sleep 1.5
c=$(active_class)
[[ $c == gf-fr-b ]] && pass "1: nothing changed: b has the keyboard back" || fail "1: '$c' has the keyboard, wanted gf-fr-b"

# 2 a swap while the Center is open
sa=$(stage_of_class gf-fr-a)
sb=$(stage_of_class gf-fr-b)
[[ -n $sa && -n $sb && $sa != "$sb" && $(active_stage) == "$sb" ]] || { fail "2: setup: stage of a '$sa', of b '$sb', active '$(active_stage)'"; echo "focus_return_stages: $fails failure(s)"; exit 1; }
ipc notifications toggleCenter >/dev/null
wait_for center_is true || fail "2: the Center did not open"
sleep 0.5
stages "{\"op\":\"activate\",\"stage\":$sa}"
active_is_a() { [[ $(active_stage) == "$sa" ]]; }
wait_for active_is_a && pass "2: stage of a is the active one under the Center" || fail "2: the swap did not happen (active $(active_stage))"
sleep 1.2 # the swap animation
ipc notifications toggleCenter >/dev/null
wait_for center_is false || fail "2: the Center did not close"
sleep 2
c=$(active_class)
[[ $c == gf-fr-a ]] && pass "2: the swapped-in front window (a) has the keyboard after the Center closed" || fail "2: '$c' has the keyboard, wanted gf-fr-a (b is in the strip)"
[[ $(active_stage) == "$sa" ]] && pass "2: the swap was not undone (active stage still a's)" || fail "2: active stage is $(active_stage), wanted $sa"

echo "focus_return_stages: $fails failure(s)"
exit $((fails > 0))
