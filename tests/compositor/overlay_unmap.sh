#!/usr/bin/env bash
# The shell's overlay unmaps soon after its popup closes (diagnostic and regression check; investigation "overlay stuck
# mapped 15-25 s", 2026-10-31). Opens a popup on GF-REF, closes it, and polls every 100 ms until no grassfield-overlay layer is
# mapped; PASS when each unmap took at most max-ms (default 3000; the keyboard hold is 120 ms).
# Usage (bare command, nested session of this tree running): tests/compositor/overlay_unmap.sh [cycles] [kind] [max-ms]
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cycles=${1:-10} kind=${2:-system} max=${3:-3000}
out=GF-REF fail=0
mapped() { timeout 10 "$root/scripts/nestctl" layers 2>/dev/null | grep -q grassfield-overlay; }
ipc() { timeout 5 "$root/tests/visual/ipc.sh" "$@" 2>/dev/null; }
now() { date +%s%3N; }
for i in $(seq 1 "$cycles"); do
  ipc menubar open "$kind" "$out" >/dev/null
  sleep "0.$((RANDOM % 5 + 1))"
  ipc menubar close >/dev/null
  t0=$(now)
  while mapped; do
    sleep 0.1
    (($(now) - t0 > 45000)) && break
  done
  ms=$(($(now) - t0))
  k=$(ipc menubar openKind)
  printf '%s cycle %d: unmapped after %d ms (openKind "%s", load %s)\n' "$(date +%T.%3N)" "$i" "$ms" "$k" "$(cut -d' ' -f1 /proc/loadavg)"
  ((ms > max)) && fail=1
done
if ((fail)); then
  echo "FAIL: an overlay stayed mapped more than $max ms after its popup closed"
  exit 1
fi
echo "PASS"
