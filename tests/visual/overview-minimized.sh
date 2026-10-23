#!/usr/bin/env bash
# Overview, minimized windows (REQ-OVW-O7, docs/specs/overview.md "Minimized windows"): a window minimized with
# `windows minimize` shows in a separate strip below the open windows and is restored by a click on its tile or by the
# keyboard (Down from the last row, Return). Reads the overview status hook (`overview status`: per output `minimized` with
# window-local rects and `minFocus`) and `nestctl activewindow`; the tiles are clicked where the hook says they are.
# Run as a BARE command with a relative path, on the reference machine only; the nested session it starts is torn down on exit.
#   tests/visual/overview-minimized.sh
# Exit status 1 when a check fails. A capture of the strip goes to .dev/visual/overview-minimized/.
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
status() { local i o; for i in 1 2 3 4 5; do o=$(vs_ipc overview status 2>/dev/null) && jq -e . <<<"$o" >/dev/null 2>&1 && { printf "%s\n" "$o"; return 0; }; sleep 0.3; done; printf '{"open":false,"screens":[]}\n'; }
minimized() { status | jq -c '[.screens[] | select(.name == "'"$VS_OUTPUT"'") | .minimized[]]'; }
active_title() { "$VS_ROOT/scripts/nestctl" activewindow -j | jq -r '.title // ""'; }
key() { local i; for i in 1 2 3 4 5; do "$VS_ROOT/scripts/dev/keys.sh" "$@" && return 0; sleep 0.4; done; return 1; }
closed() { [[ $(status | jq -r '.open') == false ]]; }
wait_for() { local n=$(( $1 * 10 )) i; shift; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.1; done; return 1; }
focus_title() { "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({window = 'title:^$1\$'})" >/dev/null 2>&1; sleep 0.5; }

out=$VS_STATE/overview-minimized
mkdir -p "$out"

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

# 1. No minimized window: no strip.
vs_ipc overview open >/dev/null
sleep 1.5
[[ $(minimized) == "[]" ]]; check "no minimized window: the strip is empty" $?
vs_ipc overview close >/dev/null
wait_for 5 closed
sleep 0.8

# 2. Two windows minimized: two tiles, below every open window's rectangle.
focus_title 'Terminal 1'
vs_ipc windows minimize >/dev/null
sleep 1.2
focus_title 'Terminal 2'
vs_ipc windows minimize >/dev/null
sleep 1.2
vs_ipc overview open >/dev/null
sleep 1.8
n=$(minimized | jq 'length')
[[ $n == 2 ]]; check "two minimized windows: two tiles in the strip (got $n)" $?
lowest_open=$(status | jq '[.screens[] | select(.name == "'"$VS_OUTPUT"'") | .windows[].rect | (.y + .h)] | max')
top_tile=$(minimized | jq '[.[].rect.y] | min')
[[ -n $lowest_open && -n $top_tile ]] && awk "BEGIN{exit !($top_tile > $lowest_open)}"; check "the strip is below the open windows (tiles from y=$top_tile, windows end at $lowest_open)" $?
shot=$(VS_SETTLE=1 vs_capture overview-minimized-strip)
cp "$shot" "$out/strip.png"

# 3. A click on a tile restores that window, focuses it and closes the overview.
title=$(minimized | jq -r '.[0].title')
read -r x y <<<"$(minimized | jq -r '.[0].rect | "\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"')"
vs_pointer abs 5 5 sleep 200 abs "$x" "$y" sleep 300 click sleep 300 >/dev/null
wait_for 5 closed; check "click on a tile: the overview closes" $?
sleep 1.5
[[ $(active_title) == "$title" ]]; check "click on a tile: '$title' is restored and active (active=$(active_title))" $?
vs_ipc overview open >/dev/null
sleep 1.5
n=$(minimized | jq 'length')
[[ $n == 1 ]]; check "the restored window left the strip (tiles now $n)" $?

# 4. Keyboard: Down from the last row enters the strip, Return restores.
key -k Down; sleep 0.4
for _ in 1 2 3; do
  [[ $(status | jq -r '.screens[] | select(.name == "'"$VS_OUTPUT"'") | .minFocus') == 0 ]] && break
  key -k Down; sleep 0.4
done
f=$(status | jq -r '.screens[] | select(.name == "'"$VS_OUTPUT"'") | .minFocus')
[[ $f == 0 ]]; check "Down from the windows reaches the first minimized tile (minFocus=$f)" $?
title=$(minimized | jq -r '.[0].title')
key -k Return
wait_for 5 closed; check "Return on a tile: the overview closes" $?
sleep 1.5
[[ $(active_title) == "$title" ]]; check "Return on a tile: '$title' is restored and active" $?

exit $fail
