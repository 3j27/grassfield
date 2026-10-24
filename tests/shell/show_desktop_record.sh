#!/usr/bin/env bash
# Records, in the NESTED instance, the Hyprland event sequences of an app activating a parked window in both orders, as fixtures for
# tests/unit/tst_showdesktopreplay.qml, and checks that Hyprland still posts the two orders the flow is written for (this is the
# nested test that notices Hyprland changing them). Bare command, nested session only (scripts/dev/nested-up.sh first).
# Usage: tests/shell/show_desktop_record.sh [--write]   (--write: replace tests/unit/fixtures/showdesktop/*.json, which is how they
# were made and what to do when this test fails after a Hyprland update; without it the recordings go to a temporary directory)
#
#   dispatcher.json: windows A, B (gf-sd-main) and C (gf-sd-other) on one Space, C focused, Show Desktop on, then the focus dispatcher
#                    (hl.dsp.focus) on the parked A;
#   xdgact.json:     the same plus a window X (tests/tools/xdgact) that, while parked, activates itself with an xdg_activation_v1
#                    token (SIGUSR1): a real client request.
# Each file: {scenario, focusBefore, window, windows: [{address, workspace, x, y, class}], events: [{t, name, data}]} where t is
# ms since the trigger and the events are those between the trigger and 3 s later (including what the running shell caused). The
# window title of "activewindow" and "openwindow" events is dropped (a terminal's title carries the user, the host and the working directory: no
# personal data goes into a fixture); the window list has class and address only.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sdrec.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if [[ ${1:-} == --write ]]; then out=$root/tests/unit/fixtures/showdesktop; else out=$tmp; fi
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP show_desktop_record: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "record: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "record: grassfield-shell is not running"; exit 2; }
mkdir -p "$out"

hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
nest() { "$root/scripts/nestctl" "$@"; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" >/dev/null 2>&1; }
pids=()
cleanup() {
  local p pid
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-sd-")) | .pid'); do kill "$pid" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
open_foot() {
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.8
}
open_xdgact() {
  setsid "$root/scripts/dev/isolated.sh" "$root/tests/tools/xdgact/xdgact.sh" gf-sd-act >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.8
}
addr_of() { hq clients | jq -r --arg c "$1" '[.[] | select(.class == $c)][0].address'; }
record() { # <scenario> <trigger: dispatcher|xdgact>
  local scenario=$1 trigger=$2 window target
  "$root/scripts/dev/pointer.sh" output GF-REF abs 200 200 >/dev/null 2>&1
  sleep 0.6
  # X first: Hyprland gives the focus to the last window parked, and the activation of the focused window is a no-op
  [[ $trigger == xdgact ]] && open_xdgact
  open_foot gf-sd-main
  open_foot gf-sd-main
  open_foot gf-sd-other
  nest dispatch "hl.dsp.focus({ window = \"address:$(addr_of gf-sd-other)\" })" >/dev/null 2>&1
  sleep 0.8
  local focus_before windows
  focus_before=$(hq activewindow | jq -r '.address')
  windows=$(hq clients | jq -c '[.[] | select(.class | startswith("gf-sd-")) | {address, workspace: .workspace.id, x: .at[0], y: .at[1], class}]')
  ipc windows showDesktop
  sleep 1.5
  if [[ $trigger == xdgact && $(hq activewindow | jq -r '.class') == gf-sd-act ]]; then echo "record: the window that activates itself is the focused one: nothing to record"; exit 2; fi
  python3 -I "$root/tests/tools/hypr-events.py" "$sig" 3 "activewindow,activewindowv2,activespecial,activespecialv2,workspace,workspacev2,focusedmon,focusedmonv2,openwindow,closewindow,movewindowv2,urgent" >"$tmp/events.jsonl" &
  local lp=$!
  sleep 0.5
  if [[ $trigger == dispatcher ]]; then
    window=$(addr_of gf-sd-main)
    nest dispatch "hl.dsp.focus({ window = \"address:$window\" })" >/dev/null 2>&1
  else
    window=$(hq clients | jq -r '[.[] | select(.class == "gf-sd-act")][0].address')
    kill -USR1 "$(hq clients | jq -r '[.[] | select(.class == "gf-sd-act")][0].pid')"
  fi
  wait "$lp"
  # t is relative to the first event after the trigger
  jq -s --arg scenario "$scenario" --arg fb "$focus_before" --arg w "$window" --argjson windows "$windows" '
    (map(select(.ready | not))) as $ev
    | ($ev | if length > 0 then .[0].t else 0 end) as $t0
    | {scenario: $scenario, focusBefore: $fb, window: $w, windows: $windows, events: ($ev | map({t: (.t - $t0), name: .name, data: (if .name == "activewindow" then ((.data | split(",")[0]) + ",") elif .name == "openwindow" then ((.data | split(",")[0:3] | join(",")) + ",") else .data end)}))}' \
    "$tmp/events.jsonl" >"$out/$scenario.json"
  echo "record: $scenario: $(jq '.events | length' "$out/$scenario.json") events"
  jq -r '.events[] | "  \(.t)ms \(.name) \(.data)"' "$out/$scenario.json"
  # clean up for the next one
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-sd-")) | .pid'); do kill "$pid" 2>/dev/null; done
  sleep 1.5
}

fails=0
# order <file> <first event> <second event>: the first event name comes before the second in the recording
order() {
  local a b
  a=$(jq -r --arg n "$2" '[.events[].name] | index($n) // 9999' "$out/$1.json")
  b=$(jq -r --arg n "$3" '[.events[].name] | index($n) // 9999' "$out/$1.json")
  if ((a < b)); then echo "PASS: $1: $2 comes before $3"; else echo "FAIL: $1: $2 does not come before $3 (Hyprland changed the order the Show Desktop flow assumes)"; fails=$((fails + 1)); fi
}
record dispatcher dispatcher
record xdgact xdgact
order dispatcher activespecial activewindowv2
order xdgact activewindowv2 activespecial
[[ $out == "$tmp" ]] || echo "record: wrote $out"
echo "show_desktop_record: $fails failure(s)"
exit $((fails > 0))
