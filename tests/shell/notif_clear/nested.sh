#!/usr/bin/env bash
# Nested-session helper for the Notifications clear model (NOT run by scripts/dev/test.sh: needs `scripts/dev/nested-up.sh`
# with the private bus). Run it bare. Notifications go to the nested shell's PRIVATE bus only (.dev/bus.address): this script
# refuses to run without it and never touches the owner's session bus.
#   nested.sh send APP N [SUMMARY]   N notifications from APP (summaries "SUMMARY 1".."SUMMARY N", default the app name)
#   nested.sh status                 notifications status (history/banners/center) and the history file size
#   nested.sh open | close           toggle the Notifications column (tests/visual/ipc.sh)
#   nested.sh clear                  test hook: remove every entry (needs nested-up.sh --visual-fixtures, refused otherwise)
#   nested.sh history                the summaries in notifications.json, newest first
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
[[ -s $dev/bus.address ]] || { echo "nested: no private bus (.dev/bus.address): scripts/dev/nested-up.sh --private-bus" >&2; exit 1; }
bus=$(<"$dev/bus.address")
case $bus in
unix:path=/tmp/dbus-*) ;;
*) echo "nested: refusing: unexpected bus address $bus" >&2; exit 1 ;;
esac
ipc=$root/tests/visual/ipc.sh

case ${1:-} in
send)
  app=${2:?app} n=${3:?count} summary=${4:-$app}
  for i in $(seq 1 "$n"); do
    gdbus call --address "$bus" --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.Notify "$app" 0 "" "$summary $i" "Body of $summary $i" '[]' '{}' 4000 >/dev/null
  done
  ;;
status)
  "$ipc" notifications status
  ls -l "$dev/state/notifications.json" 2>/dev/null || true
  ;;
open | close)
  "$ipc" notifications toggleCenter
  ;;
clear)
  "$ipc" notifications clearAll
  ;;
history)
  jq -r '.notifications[] | "\(.appName): \(.summary)"' "$dev/state/notifications.json"
  ;;
*)
  echo "usage: nested.sh send APP N [SUMMARY] | status | open | close | clear | history" >&2
  exit 2
  ;;
esac
