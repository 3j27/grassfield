#!/usr/bin/env bash
# Recent Items of the Grassfield menu (macOS Apple menu > Recent Items, docs/specs/menubar.md requirement 3) on GF-REF:
#   recorded     an application launched from the Dock is in the state file ($VS_DEV/state/recent-items.json)
#   capture      the Grassfield menu with Recent Items open ($VS_SHOTS/recent-items-*.png, checked by eye)
#   clear        Clear Menu (chosen with the keyboard) empties the applications in the state file
# Usage (bare command): tests/visual/recent-items.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
state=$VS_DEV/state/recent-items.json
apps_in_state() { jq -r '[.apps[].id] | join(",")' "$state" 2>/dev/null; }
keys() { "$VS_ROOT/scripts/dev/keys.sh" "$@" >/dev/null; }

vs_session >/dev/null
vs_reset >/dev/null
# A foot the Dock launched in an earlier run is not one of the clients vs_reset closes: a click would only activate it.
for _ in 1 2 3; do "$VS_ROOT/scripts/nestctl" dispatch 'hl.dsp.window.close({ window = "class:foot" })' >/dev/null 2>&1; done
vs_sleep 1
foot=$(vs_ipc dock tiles | jq -r 'index("foot")')
vs_ipc dock click "$foot" >/dev/null
vs_wait_clients 1 >/dev/null || true
vs_sleep 1.5
check "recorded: foot launched from the Dock is a recent application (state '$(apps_in_state)')" test "$(apps_in_state | cut -d, -f1)" = foot

for appearance in dark light; do
  vs_ipc controlcenter appearance "$appearance" >/dev/null
  vs_ipc menubar open system "$VS_OUTPUT" >/dev/null
  vs_sleep 0.6
  # About, Settings..., Recent Items: the third row.
  keys -k Down -k Down -k Down -k Right
  vs_sleep 0.8
  VS_NOPARK=1 vs_capture "recent-items-$appearance"
  vs_ipc menubar close >/dev/null
  vs_sleep 0.4
done

vs_ipc menubar open system "$VS_OUTPUT" >/dev/null
vs_sleep 0.6
keys -k Down -k Down -k Down -k Right
vs_sleep 0.6
keys -k End -k Return
vs_sleep 1
check "clear: Clear Menu empties the recent applications (state '$(apps_in_state)')" test -z "$(apps_in_state)"
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
