#!/usr/bin/env bash
# Nested scenario (L1): a display goes away while the shell runs (monitor unplugged, lid closed with an external display), the
# macOS model: its windows move to a remaining display, and the switcher, Show Desktop, popups and notifications keep working
# at once, without restarting the shell. Bare command, nested session only. A headless output GF-SD2 plays the display that
# goes away (nest output remove GF-SD2), twice: removed, added back, removed again. At the end GF-SD2 is removed and every
# window of the test (app ids gf-ud-*) is closed, also when the test fails.
#   1 a popup (Force Quit panel) is open on GF-SD2, Show Desktop is on with a window parked from each display, and the focus
#     is on GF-SD2; GF-SD2 is removed:
#       - every parked window comes back, none stays on special:desktop (bounded wait);
#       - the popup is on a live output (Popups.screenName re-resolved), not on the removed one;
#       - the switcher (next + release) works right away: the focus goes to the window of the other app;
#       - Show Desktop works on the remaining display (on and off), a new popup opens, and a notification is delivered
#         (the banner surface exists on the live output);
#       - the shell log has no "Cannot read property ... of null" from a screen that went away.
#   2 GF-SD2 is added back and the same is repeated.
# Expected: "display_unplug: 0 failure(s)" after PASS lines. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "display_unplug: no verified nested instance (scripts/dev/nested-up.sh)"; exit 2; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "display_unplug: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "display_unplug: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
[[ -n $bus ]] || { echo "display_unplug: no private bus address in .dev/bus.address"; exit 2; }
# The notification goes to the session's PRIVATE bus, never the owner's (as the nested files scenario does).
case $bus in
  unix:path=/tmp/dbus-*) ;;
  *) echo "display_unplug: refusing: '$bus' is not a private bus of the dev session"; exit 2 ;;
esac
owner_bus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}
[[ $bus != "$owner_bus" && $bus != "unix:path=${XDG_RUNTIME_DIR:-}/bus"* ]] || { echo "display_unplug: refusing the owner's session bus"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
nest() { "$root/scripts/nestctl" "$@"; }
space_of() { hq clients | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .workspace.name'; }
monitor_of() { hq clients | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .monitor'; }
active_pid() { hq activewindow | jq -r '.pid'; }
parked_count() { hq clients | jq '[.[] | select(.workspace.name == "special:desktop")] | length'; }
live_outputs() { hq monitors | jq -r '.[].name'; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call "$@" 2>/dev/null; }
warp() { "$root/scripts/dev/pointer.sh" output "$1" abs 200 200 >/dev/null 2>&1; sleep 0.6; }
focus_space() { nest dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null 2>&1; sleep 1; }
wait_for() { local n; for n in $(seq 1 30); do "$@" && return 0; sleep 0.2; done; return 1; }

pids=()
NEWPID=""
open_foot() { # <app id> <output>
  warp "$2"
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id "$1" >/dev/null 2>&1 </dev/null &
  pids+=($!)
  sleep 1.8
  NEWPID=$(active_pid)
}
close_test_windows() {
  local p pid
  for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null; done
  for pid in $(hq clients | jq -r '.[] | select(.class | startswith("gf-ud-")) | .pid'); do kill "$pid" 2>/dev/null; done
}
created=0
cleanup() {
  close_test_windows
  ((created)) && nest output remove GF-SD2 >/dev/null 2>&1
}
trap cleanup EXIT
close_test_windows
sleep 1

OUT=$(live_outputs | grep -vx 'GF-SD2' | head -n1)
[[ -n $OUT ]] || { echo "display_unplug: no output besides GF-SD2"; exit 2; }
echo "display_unplug: outputs: $(live_outputs | paste -sd' '); the display that goes away is GF-SD2, the one that stays is $OUT"

has_gone() { ! live_outputs | grep -qx GF-SD2; }
is_live() { local m; m=$(monitor_of "$1"); [[ -n $m && $m != null ]] && hq monitors | jq -e --argjson m "$m" 'any(.[]; .id == $m)' >/dev/null; }
none_parked() { [[ $(parked_count) == 0 ]]; }
popup_on_live() { local k; k=$(ipc menubar openKind); [[ $k == forcequit@* ]] && live_outputs | grep -qx "${k#forcequit@}"; }
focus_is_other() { [[ $(active_pid) == "$1" ]]; }
banner_on_live() { hq layers | jq -e --argjson live "$(live_outputs | jq -R . | jq -s .)" 'to_entries | any(.[]; (.key as $k | $live | index($k)) != null and (.value.levels | to_entries | any(.[]; .value | any(.[]; .namespace == "grassfield-banners"))))' >/dev/null; }

round() { # <label>
  local label=$1 log0 x y
  if ! live_outputs | grep -qx GF-SD2; then
    nest output create headless GF-SD2 >/dev/null 2>&1
    created=1
    sleep 2.5
  fi
  live_outputs | grep -qx GF-SD2 || { echo "display_unplug: could not create GF-SD2"; return 2; }
  # Y (other app) on the staying output, X on GF-SD2 with the focus; a window parked from each display
  open_foot gf-ud-main "$OUT"; y=$NEWPID
  open_foot gf-ud-other GF-SD2; x=$NEWPID
  [[ -n $x && $x != null && -n $y && $y != null ]] || { echo "display_unplug: could not open the windows"; return 2; }
  ipc windows showDesktop >/dev/null
  sleep 1.2
  [[ $(parked_count) == 2 ]] && pass "$label: both displays' windows are parked before the unplug" || fail "$label: $(parked_count) windows parked, wanted 2"
  ipc menubar panel forcequit GF-SD2 >/dev/null
  sleep 0.6
  [[ $(ipc menubar openKind) == forcequit@GF-SD2 ]] && pass "$label: the popup is on GF-SD2" || fail "$label: popup is '$(ipc menubar openKind)', wanted forcequit@GF-SD2"
  log0=$(wc -l <"$dev/shell.log")

  nest output remove GF-SD2 >/dev/null 2>&1
  wait_for has_gone && pass "$label: GF-SD2 is gone" || fail "$label: GF-SD2 is still listed"

  wait_for none_parked && pass "$label: every parked window came back, none on special:desktop" || fail "$label: $(parked_count) window(s) still on special:desktop"
  wait_for is_live "$x" && pass "$label: X (from the removed display) is on a live display" || fail "$label: X is on monitor id '$(monitor_of "$x")' (live ids: $(hq monitors | jq -r '[.[].id] | join(",")'))"
  wait_for is_live "$y" && pass "$label: Y is on a live display" || fail "$label: Y is on '$(monitor_of "$y")'"
  wait_for popup_on_live && pass "$label: the popup moved to a live output ($(ipc menubar openKind))" || fail "$label: popup is '$(ipc menubar openKind)'"
  ipc menubar close >/dev/null

  # the switcher right away: next + release moves the focus to the window of the other app
  local before hold
  before=$(active_pid)
  hold=$(date +%s)
  ipc switcher next "$hold" >/dev/null
  sleep 0.6
  ipc switcher release "$hold" >/dev/null
  focus_moved() { local now; now=$(active_pid); [[ $now != "$before" && -n $now && $now != null ]]; }
  wait_for focus_moved
  if focus_moved; then pass "$label: the switcher works after the removal (focus $before -> $(active_pid))"; else fail "$label: the switcher did nothing (focus stays $before)"; fi

  # Show Desktop on the remaining display, on and off
  ipc windows showDesktop >/dev/null
  sleep 1.2
  wait_for none_parked >/dev/null
  [[ $(parked_count) -ge 1 ]] && pass "$label: Show Desktop parks the windows on the remaining display" || fail "$label: Show Desktop parked nothing"
  ipc windows showDesktop >/dev/null
  wait_for none_parked && pass "$label: and brings them back" || fail "$label: $(parked_count) window(s) stay parked"

  # a popup and a notification on the remaining display
  ipc menubar panel forcequit '' >/dev/null
  sleep 0.6
  popup_on_live && pass "$label: a new popup opens on a live output ($(ipc menubar openKind))" || fail "$label: popup is '$(ipc menubar openKind)'"
  ipc menubar close >/dev/null
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send "gf display unplug" "after the removal" >/dev/null 2>&1
  wait_for banner_on_live && pass "$label: a notification banner is shown on a live output" || fail "$label: no banner surface on a live output"

  local bad
  bad=$(tail -n +"$((log0 + 1))" "$dev/shell.log" | grep -c "Cannot read property '\(name\|width\|height\)' of null")
  [[ $bad == 0 ]] && pass "$label: no null-screen error in the shell log" || fail "$label: $bad null-screen error(s) in the shell log"
  close_test_windows
  sleep 1
}

round "unplug 1" || exit 2
round "unplug 2 (added back)" || exit 2
echo "display_unplug: $fails failure(s)"
exit $((fails > 0))
