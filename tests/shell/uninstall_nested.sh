#!/usr/bin/env bash
# Deleting apps from the Apps panel in the NESTED session (ADR-0044 D6): the icons jiggle, removable apps show the delete badge,
# its click asks "Delete “App”?" and nothing is removed (the alert is cancelled, Delete is never pressed here). Run it bare with a
# nested session up (scripts/dev/nested-up.sh, --ref-scale 1.25 for the captures); skipped without one. The Store's answer is given
# through the dev-only IPC hook instead of asked, so no pacman, no Store and no package is involved. Captures in .dev/shots/.
# Exit 0 when every check passes.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP uninstall_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"
  exit 0
fi
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
ipc() { "$root/tests/visual/ipc.sh" "$@"; }
key() { "$root/scripts/dev/keys.sh" "$@" >/dev/null; sleep 0.25; }
st() { ipc apps status | jq -r "$1"; }

ipc apps close >/dev/null; ipc overview close >/dev/null; ipc search close >/dev/null; sleep 0.5
ipc apps open >/dev/null; sleep 1.5
[[ $(st .open) == true ]]; check "the panel is open" $?
mapfile -t ids < <(ipc apps status | jq -r '.visible[:6][]')
((${#ids[@]} >= 4)); check "at least four apps are listed (${ids[*]})" $?

# The Store's answer: the first two removable, the third part of Omarchy, the fourth part of Grassfield.
json=$(jq -cn --arg a "${ids[0]}" --arg b "${ids[1]}" --arg c "${ids[2]}" --arg d "${ids[3]}" \
  '{version: 1, entries: {($a + ".desktop"): {app: $a, name: $a, block: ""}, ($b + ".desktop"): {app: $b, name: $b, block: ""},
    ($c + ".desktop"): {app: $c, name: $c, block: "omarchy"}, ($d + ".desktop"): {app: $d, name: $d, block: "grassfield"}}}')
[[ $(ipc apps removable "$json") == 4 ]]; check "the answer is read (4 entries)" $?
[[ $(st .editing) == false ]]; check "the icons are still before the hold" $?
ipc apps edit >/dev/null; sleep 1
[[ $(st .editing) == true ]]; check "the icons jiggle after the hold" $?
"$root/scripts/dev/shot.sh" uninstall-jiggle >/dev/null && echo "shot .dev/shots/uninstall-jiggle.png"

# The badge's click, for a removable app and for one that is not.
[[ $(ipc apps ask "${ids[2]}") == "not removable" ]]; check "an Omarchy app asks nothing" $?
[[ $(ipc apps ask "${ids[3]}") == "not removable" ]]; check "a Grassfield app asks nothing" $?
[[ $(st '.pendingDelete') == "" ]]; check "no alert for them" $?
[[ $(ipc apps ask "${ids[0]}") == asked ]]; check "a removable app asks" $?
sleep 1
[[ $(st .pendingDelete) == "${ids[0]}" ]]; check "the alert is about that app" $?
"$root/scripts/dev/shot.sh" uninstall-alert >/dev/null && echo "shot .dev/shots/uninstall-alert.png"
# Esc cancels the alert and nothing is removed, a second Esc ends the jiggle, a third closes the panel.
key -k Escape; sleep 0.5
[[ $(st .pendingDelete) == "" ]]; check "Esc cancels the alert" $?
[[ $(st .open) == true ]]; check "the panel stays" $?
ipc apps close >/dev/null; sleep 0.5
[[ $(st .editing) == false ]]; check "closing the panel ends the jiggle" $?
exit $fails
