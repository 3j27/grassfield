#!/usr/bin/env bash
# Nested smoke set (GF-094, audit ARCH-24): the fastest checks that prove a running nested session is a working Grassfield
# session, in about 20 seconds. It STARTS NOTHING: it uses the nested session of this tree that is already up (just nested-up,
# or the one a visual run left), opens no window and leaves every surface closed; without a session it SKIPs (exit 0), so
# `just test` can carry it (the nested layer's tests/shell scripts skip themselves). Input is the dev IPC only
# (tests/visual/ipc.sh refuses anything but this tree's verified nested shell) and read-only nestctl queries.
#
#   1. compositor   the nested compositor lists an output and its windows (nestctl monitors, clients)
#   2. shell        the shell answers IPC and the session is unlocked (never types anywhere near a lock)
#   3. capabilities the compositor plugin handshake settled (`capabilities status`: ready present or ready degraded)
#   4. quick settings  `controlcenter state` is valid JSON with the expected keys; the menu bar opens and closes a menu
#   5. search       opens, takes a query, closes (`search status`)
#   6. apps         opens and closes (`apps status`), and Search and Apps exclude each other
#   7. notifications the server is up; the Notification Center opens and closes
#   8. log          the shell log holds no QML TypeError, ReferenceError or binding loop
# A dev hook that answers "refused" (a session without GRASSFIELD_DEV) SKIPs its check. Exit 1 on any FAIL.
#
# Run (bare command, a nested session up):  tests/shell/smoke_nested.sh        or  just smoke-nested
# Expected: eight "PASS smoke ..." lines (or SKIP) and "smoke_nested: 0 failure(s)"; exit 0.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP smoke_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"
  exit 0
fi
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS smoke $1"; else echo "FAIL smoke $1"; fails=1; fi; }
skip() { echo "SKIP smoke $1"; }
ipc() { "$root/tests/visual/ipc.sh" "$@" 2>/dev/null; }
# until SECONDS COMMAND...: poll (0.2 s) for a command to succeed.
until_ok() { local n=$(( $1 * 5 )) i; shift; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.2; done; return 1; }
st() { ipc "$1" status | jq -r "$2" 2>/dev/null; }
is() { [[ $(st "$1" "$2") == "$3" ]]; } # is TARGET FILTER VALUE
kind_is() { [[ $(ipc menubar openKind | tr -d '"') == "$1" ]]; }
notif_has() { [[ $(ipc notifications status) == *"$1"* ]]; }

# 1. compositor
out=$("$root/scripts/nestctl" monitors -j 2>/dev/null | jq -r '.[0].name // empty')
[[ -n $out ]]; check "compositor: lists an output ($out)" $?
"$root/scripts/nestctl" clients -j 2>/dev/null | jq -e 'type == "array"' >/dev/null; check "compositor: lists its windows" $?

# 2. shell
lock=$(ipc lock status)
[[ $lock == unlocked ]]; check "shell: answers IPC, session '$lock' (unlocked expected)" $?
if [[ $lock != unlocked ]]; then
  echo "smoke_nested: the session is not unlocked: nothing else is checked (a locked nested session ends with nested-down)"
  echo "smoke_nested: $fails failure(s)"
  exit 1
fi

# 3. capabilities
cap=$(ipc capabilities status)
[[ $cap == "ready present"* || $cap == "ready degraded" ]]; check "capabilities: settled ('$cap')" $?

# 4. quick settings state, a menu
cc=$(ipc controlcenter state)
if [[ $cc == refused ]]; then
  skip "quick settings: controlcenter state refused (not a dev session)"
else
  jq -e 'has("appearance") and has("dark") and has("transparency") and has("dnd") and has("nightShift")' <<<"$cc" >/dev/null 2>&1; check "quick settings: controlcenter state has its keys" $?
  ipc menubar open system "$out" >/dev/null
  until_ok 5 kind_is "system@$out"; check "menu bar: the System menu opens on $out" $?
  ipc menubar close >/dev/null
  until_ok 5 kind_is ""; check "menu bar: and closes" $?
fi

# 5. search
if [[ $(ipc search status) == refused ]]; then
  skip "search: refused (not a dev session)"
else
  ipc search open "" >/dev/null
  until_ok 5 is search .open true; check "search: opens" $?
  ipc search query smoke >/dev/null
  until_ok 5 is search .query smoke; check "search: takes a query" $?
  ipc search close >/dev/null
  until_ok 5 is search .open false; check "search: closes" $?
fi

# 6. apps, mutual exclusion with Search
if [[ $(ipc apps status) == refused ]]; then
  skip "apps: refused (not a dev session)"
else
  ipc apps open >/dev/null
  until_ok 5 is apps .open true; check "apps: opens" $?
  ipc search open "" >/dev/null
  until_ok 5 is apps .open false; check "apps: Search opening closes it" $?
  ipc search close >/dev/null
  until_ok 5 is search .open false
fi

# 7. notifications
ns=$(ipc notifications status)
if [[ $ns == refused ]]; then
  skip "notifications: refused (not a dev session)"
else
  [[ $ns == *"server=active"* ]]; check "notifications: the server is up ($ns)" $?
  ipc notifications toggleCenter >/dev/null
  until_ok 5 notif_has "center=true"; check "notifications: the Center opens" $?
  ipc notifications toggleCenter >/dev/null
  until_ok 5 notif_has "center=false"; check "notifications: and closes" $?
fi

# 8. log
n=$(grep -cE 'TypeError|ReferenceError|Binding loop' "$dev/shell.log" 2>/dev/null || true)
[[ ${n:-0} == 0 ]]; check "log: no QML TypeError, ReferenceError or binding loop in .dev/shell.log (${n:-0})" $?

echo "smoke_nested: $fails failure(s)"
exit $(( fails > 0 ))
