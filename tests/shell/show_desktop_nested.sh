#!/usr/bin/env bash
# Nested scenario (L1) for Show Desktop (GF-106, review of the shell UX batch). Bare command, nested session only.
#
#   1 two foot windows A and B on Space 1: `windows showDesktop` parks both (special:desktop), the record is in
#     $XDG_STATE_HOME/grassfield/show-desktop.json;
#   2 the same call again: A and B are back on Space 1, the window that had the focus has it;
#   3 the reported bug: showDesktop on Space 1, switch to Space 2 (this ends it: A and B are back on Space 1, not on
#     Space 2);
#   4 (manual) crash recovery: with Show Desktop on, restart the shell (scripts/dev/shell-run.sh): the windows listed in
#     the record file come back to their Space within about two seconds;
#
# Only this tree's nested instance (scripts/dev/pidfile.sh); hyprctl is read-only; clients get the nested socket only.
# Expected: five PASS lines and "show_desktop: 0 failure(s)". Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "show_desktop: no verified nested instance (scripts/dev/nested-up.sh)"; exit 2; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "show_desktop: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "show_desktop: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
clients() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients; }
space_of() { clients | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .workspace.name'; }
active_pid() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j activewindow | jq -r '.pid'; }
show_desktop() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call windows showDesktop >/dev/null 2>&1; sleep 1; }
space() { "$root/scripts/nestctl" dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1; sleep 1; }
pids=()
open_foot() {
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.5
}
cleanup() { for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done; space 1; }
trap cleanup EXIT

space 1
open_foot
a=$(active_pid)
open_foot
b=$(active_pid)
[[ -n $a && -n $b && $a != "$b" ]] || { echo "show_desktop: could not open two windows"; exit 2; }
[[ $(space_of "$a") == 1 && $(space_of "$b") == 1 ]] || { echo "show_desktop: the windows are not on Space 1"; exit 2; }
state=${GRASSFIELD_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/grassfield}/show-desktop.json

show_desktop
[[ $(space_of "$a") == special:desktop && $(space_of "$b") == special:desktop ]] && pass "Show Desktop parks both windows" || fail "windows not parked: $(space_of "$a") $(space_of "$b")"
[[ -s $state ]] && grep -q '"workspace":1' "$state" && pass "the record is in the state dir" || fail "no record in $state"

show_desktop
[[ $(space_of "$a") == 1 && $(space_of "$b") == 1 ]] && pass "pressing it again brings both back to Space 1" || fail "not back: $(space_of "$a") $(space_of "$b")"
[[ $(active_pid) == "$b" ]] && pass "the focus is back on the window that had it" || fail "focus is $(active_pid), wanted $b"

show_desktop
space 2
[[ $(space_of "$a") == 1 && $(space_of "$b") == 1 ]] && pass "switching to Space 2 ends it: the windows are back on Space 1, not on Space 2" || fail "after the Space switch: $(space_of "$a") $(space_of "$b")"

echo "show_desktop: $fails failure(s)"
exit $((fails > 0))
