#!/usr/bin/env bash
# Apps panel keyboard and exclusivity in the NESTED session (docs/specs/apps.md A1, A6, A8, mutual close). Run it bare
# with a nested session up (scripts/dev/nested-up.sh); skipped without one. Launches nothing: every Return here must
# NOT launch (a launch would close the panel, which the checks detect). Input only through scripts/dev/keys.sh.
# Exit 0 when every check passes.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP apps_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"
  exit 0
fi
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
ipc() { "$root/tests/visual/ipc.sh" "$@"; }
key() { "$root/scripts/dev/keys.sh" "$@" >/dev/null; sleep 0.25; }
st() { ipc apps status | jq -r "$1"; }

ipc apps close >/dev/null; ipc overview close >/dev/null; ipc search close >/dev/null; sleep 0.5

# A1: open, visible ids published.
ipc apps open >/dev/null; sleep 1
[[ $(st .open) == true ]]; check "A1 open" $?
[[ $(st '.visible | length') -gt 0 ]]; check "A1 visible ids published after opening" $?

# Utilities chip, Down, Right x6, Up, Up -> the field with an invisible selection: Return must not launch.
key -k Tab; key -k Right; key -k Right; key -k Right; key -k Return
[[ $(st .category) == utilities ]]; check "A8 Utilities chip selected" $?
key -k Down
for _ in 1 2 3 4 5 6; do key -k Right; done
key -k Up; key -k Up
[[ $(st .zone) == search ]]; check "A8 back in the field" $?
[[ $(st .selected) == -1 ]]; check "A6 selection dropped when the grid is left" $?
key -k Return; sleep 0.5
[[ $(st .open) == true ]]; check "A6 Return with an invisible selection does not launch" $?
# Tab from the grid: lands on the chips, where Return selects a chip.
key -k Down; key -k Tab; key -k Return; sleep 0.5
[[ $(st .open) == true ]]; check "A8 Tab from the grid then Return does not launch" $?

# IPC visible cleared on close.
ipc apps close >/dev/null; sleep 0.5
[[ $(st '.visible | length') == 0 ]]; check "A1 visible cleared on close" $?

# Mutual close: Overview closes Apps and the reverse, Search likewise.
ipc apps open >/dev/null; sleep 0.5
ipc overview open >/dev/null; sleep 1.5
[[ $(st .open) == false ]]; check "Overview open closes Apps" $?
ipc overview close >/dev/null; sleep 1.5
ipc overview open >/dev/null; sleep 1.5
ipc apps open >/dev/null; sleep 1.5
[[ $(st .open) == true && $(ipc overview status | jq -r .open) == false ]]; check "Apps open closes Overview" $?
ipc search open "" >/dev/null; sleep 0.5
[[ $(st .open) == false ]]; check "Search open closes Apps" $?
ipc search close >/dev/null
# Esc reaches Apps after the switches (the keyboard belongs to the top surface).
ipc apps open >/dev/null; sleep 0.5
key -k Escape; sleep 0.5
[[ $(st .open) == false ]]; check "Esc closes Apps after the switches" $?
ipc apps close >/dev/null
exit $fails
