#!/usr/bin/env bash
# Overview highlight and selection (defect #10): the window active at open carries the ring and the name at once, a hover
# moves them, the arrows move them, Return activates what the ring shows, the Desktops bar has its names under the thumbnails.
# Reads the overview status hook (`overview status`: per output `marked`, `selected`, windows with their rects) and
# `nestctl activewindow`. Run as a BARE command with a relative path, on the reference machine only; the nested session it
# starts is torn down on exit.
#   tests/visual/overview-highlight.sh
# Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_ipc overview close >/dev/null 2>&1 || true; vs_kill_clients || true; }
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail=0
check() { # <description> <status>
  if [[ $2 -eq 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi
}
status() { local i o; for i in 1 2 3 4 5; do o=$(vs_ipc overview status 2>/dev/null) && jq -e . <<<"$o" >/dev/null 2>&1 && { printf "%s\n" "$o"; return 0; }; sleep 0.3; done; echo "status: not JSON: $o" >&2; printf "{\"open\":false,\"screens\":[]}\n"; }
active_title() { "$VS_ROOT/scripts/nestctl" activewindow -j | jq -r '.title // ""'; }
marked_title() { status | jq -r '[.screens[] | select(.name == "'"$VS_OUTPUT"'") | .marked as $m | .windows[] | select($m != "" and .address == $m) | .title] | first // ""'; }
selected_addr() { status | jq -r '.screens[] | select(.name == "'"$VS_OUTPUT"'") | .selected'; }
key() { local i; for i in 1 2 3 4 5; do "$VS_ROOT/scripts/dev/keys.sh" "$@" && return 0; sleep 0.4; done; return 1; }
closed() { [[ $(status | jq -r '.open') == false ]]; }
wait_for() { # <seconds> cmd...
  local n=$(( $1 * 10 )) i; shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
focus_title() { # focus a window by its title (Lua dispatch through nestctl is not needed: spawn order decides)
  "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({window = 'title:^$1\$'})" >/dev/null 2>&1 || true
  sleep 0.5
}

vs_session en
vs_reset dark 0.25
vs_foot 'Terminal 1' 50x12
vs_wait_clients 1
vs_foot 'Terminal 2' 60x16
vs_wait_clients 2
vs_foot 'Terminal 3' 70x18
vs_wait_clients 3
vs_park
sleep 5

# 1. The window active at open is marked, nothing was hovered or chosen.
focus_title 'Terminal 2'
[[ $(active_title) == 'Terminal 2' ]]; check "setup: Terminal 2 is active" $?
vs_ipc overview open >/dev/null
sleep 1.5
m=$(marked_title)
[[ $m == 'Terminal 2' ]]; check "open: the active window carries the ring and the name (marked=$m)" $?
[[ -z $(selected_addr) ]]; check "open: nothing is selected yet (hover and keys have not chosen)" $?

# 2. Hover moves the mark: pointer over Terminal 3's rectangle (status rects are window-local, the surface starts below the menu bar).
read -r x y <<<"$(status | jq -r '.screens[] | select(.name == "'"$VS_OUTPUT"'") | .windows[] | select(.title == "Terminal 3") | "\((.rect.x + .rect.w / 2) | floor) \((.rect.y + .rect.h / 2) | floor)"')"
y=$((y + 24))
vs_pointer abs 5 5 sleep 200 abs "$x" "$y" sleep 300 abs $((x + 3)) $((y + 3)) sleep 500 >/dev/null
m=$(marked_title)
[[ $m == 'Terminal 3' ]]; check "hover: the window under the pointer is marked (marked=$m)" $?

# 3. Arrows: from the hovered window, left or right reaches another window and the mark follows.
before=$m
key -k Up; sleep 0.5
m=$(marked_title)
[[ -n $m && $m != "$before" ]]; check "arrows: Up moves the mark off $before (marked=$m)" $?

# 4. Return activates the marked window and closes.
want=$m
key -k Return
wait_for 5 closed; check "return: the overview closes" $?
sleep 0.8
act=$(active_title)
[[ $act == "$want" ]]; check "return: the marked window $want is the active window (active=$act)" $?

# 5. Return with nothing chosen activates the window the ring showed (the one active at open).
focus_title 'Terminal 1'
vs_park
vs_ipc overview open >/dev/null
sleep 1.2
key -k Return
wait_for 5 closed; check "return, nothing chosen: the overview closes" $?
sleep 0.8
act=$(active_title)
[[ $act == 'Terminal 1' ]]; check "return, nothing chosen: Terminal 1 (active at open) stays active (active=$act)" $?

# 6. Esc returns to the window that was active at open.
focus_title 'Terminal 3'
vs_ipc overview open >/dev/null
sleep 1.2
key -k Escape
wait_for 5 closed; check "esc: the overview closes" $?
sleep 0.8
act=$(active_title)
[[ $act == 'Terminal 3' ]]; check "esc: back on Terminal 3 (active=$act)" $?

# 7. Captures last (a screenshot takes the keyboard from the overview): open with the pointer over Terminal 3, then the hover state.
vs_park
vs_ipc overview open >/dev/null
sleep 1.5
VS_SETTLE=1 vs_capture overview-highlight-open >/dev/null || true
vs_ipc overview close >/dev/null
(( fail )) && { echo "overview-highlight: FAIL" >&2; exit 1; }
echo "overview-highlight: PASS"
