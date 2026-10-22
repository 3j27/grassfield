#!/usr/bin/env bash
# The Dock against the macOS model (docs/specs/dock.md "macOS parity checklist"), on GF-REF with two foot windows.
#   active-click     a click on the tile of the app that is already active leaves the active window as it is
#   menu captures    the Dock menu of an app with two windows ($VS_SHOTS/dmo-menu-*.png; macOS lists the app's windows
#                    at the top of the menu: checked by eye)
#   other output     the Dock on the second output ($VS_SHOTS/dmo-wayland1.png)
# Usage (bare command): tests/visual/dock-macos.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
active() { "$VS_ROOT/scripts/nestctl" activewindow -j | jq -r '.title // ""'; }
tile_index() { vs_ipc dock tiles | jq -r --arg k "$1" 'index($k)'; }

vs_session >/dev/null
vs_reset >/dev/null
vs_foot dmo-one 70x16 >/dev/null
vs_wait_clients 1 >/dev/null || true
vs_sleep 1
vs_foot dmo-two 70x16 >/dev/null
vs_wait_clients 2 >/dev/null || true
vs_sleep 1.5
foot=$(tile_index foot)
echo "tiles: $(vs_ipc dock tiles), foot at $foot, active '$(active)'"

# active-click
before=$(active)
vs_ipc dock click "$foot" >/dev/null
vs_sleep 1
after=$(active)
check "active-click: a click on the active app's tile keeps '$before' active (now '$after')" test "$after" = "$before"

# menu captures, dark then light
for appearance in dark light; do
  vs_ipc controlcenter appearance "$appearance" >/dev/null
  vs_sleep 0.5
  vs_ipc dock menu "$foot" "$VS_OUTPUT" >/dev/null
  vs_sleep 0.8
  VS_NOPARK=1 vs_capture "dmo-menu-$appearance"
  vs_ipc menubar close >/dev/null
  vs_sleep 0.4
done

# window list: choosing the second row (the older window) brings that window to the front
vs_ipc controlcenter appearance dark >/dev/null
vs_ipc dock click "$foot" >/dev/null
vs_sleep 0.5
recent=$(active)
vs_ipc dock menu "$foot" "$VS_OUTPUT" >/dev/null
vs_sleep 0.8
"$VS_ROOT/scripts/dev/keys.sh" -k Down -k Down -k Return >/dev/null
vs_sleep 1
after=$(active)
check "window list: the second row ('$recent' was active) activates the other window (now '$after')" test "$after" != "$recent" -a -n "$after"

# a minimized window is marked in the list and choosing it restores it
vs_ipc windows minimize >/dev/null
vs_sleep 1
vs_ipc dock menu "$foot" "$VS_OUTPUT" >/dev/null
vs_sleep 0.8
VS_NOPARK=1 vs_capture "dmo-menu-minimized"
minimized_title=$after
"$VS_ROOT/scripts/dev/keys.sh" -k Down -k Down -k Return >/dev/null
vs_sleep 1.2
check "window list: choosing the minimized window ('$minimized_title') restores and focuses it (active now '$(active)')" test "$(active)" = "$minimized_title"

# Option (Alt) variants follow the key while the menu is open: Hide -> Hide Others, Quit -> Force Quit (check by eye)
vs_ipc dock menu "$foot" "$VS_OUTPUT" >/dev/null
vs_sleep 0.8
"$VS_ROOT/scripts/dev/keys.sh" -P Alt_L -s 2500 -p Alt_L >/dev/null &
alt_pid=$!
vs_sleep 1
VS_NOPARK=1 vs_capture "dmo-menu-alt"
wait "$alt_pid"
vs_sleep 0.5
VS_NOPARK=1 vs_capture "dmo-menu-alt-released"
vs_ipc menubar close >/dev/null
vs_sleep 0.4

# the second output's Dock (macOS shows one Dock, on the display where the pointer last reached the bottom edge)
"$VS_ROOT/scripts/dev/shot.sh" dmo-wayland1 WAYLAND-1 >/dev/null && cp "$VS_DEV/shots/dmo-wayland1.png" "$VS_SHOTS/dmo-wayland1.png" \
  && echo "$VS_SHOTS/dmo-wayland1.png"

check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
