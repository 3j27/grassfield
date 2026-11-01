#!/usr/bin/env bash
# Diagnostic: every 200 ms, prints the open popup kind and whether Hyprland maps a grassfield-overlay layer on the nested
# session, only when one of them changed. Usage (bare, nested running): tests/compositor/overlay_watch.sh [seconds]
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
secs=${1:-600}
last=""
end=$(($(date +%s) + secs))
while (($(date +%s) < end)); do
  k=$(timeout 3 "$root/tests/visual/ipc.sh" menubar openKind 2>/dev/null)
  if timeout 5 "$root/scripts/nestctl" layers 2>/dev/null | grep -q grassfield-overlay; then m=MAPPED; else m=unmapped; fi
  cur="$m kind=[$k]"
  if [[ $cur != "$last" ]]; then
    printf '%s %s\n' "$(date +%T.%3N)" "$cur"
    last=$cur
  fi
  sleep 0.2
done
