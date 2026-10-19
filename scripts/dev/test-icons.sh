#!/usr/bin/env bash
# Gate A2 for the icon appearance modes: tests/unit/tst_iconshader.qml needs a GPU scene graph (ShaderEffect does not run
# on the software renderer of the offscreen platform, where the test skips), so it runs as a Wayland client of this
# tree's NESTED session (scripts/dev/nested-up.sh first). Run it as a bare command. Prints the per-icon contrast lines
# ("A2 ...") and exits 0 when every rule holds.
#
# A renderer can stall when the GPU is shared with other nested sessions (a swap that never completes): every attempt
# runs under a watchdog (GRASSFIELD_ICONS_TIMEOUT seconds, default 540, then SIGKILL after 10 s) and a stalled attempt
# is retried (GRASSFIELD_ICONS_ATTEMPTS, default 3). A real failure (exit 1 with a FAIL line) is never retried.
#
#   scripts/dev/test-icons.sh
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "test-icons: no nested session of this tree (scripts/dev/nested-up.sh)" >&2; exit 1; }
limit=${GRASSFIELD_ICONS_TIMEOUT:-540}
attempts=${GRASSFIELD_ICONS_ATTEMPTS:-3}
for ((try = 1; try <= attempts; try++)); do
  out=$(timeout -k 10 "$limit" "$root/scripts/dev/isolated.sh" --name a2 env WAYLAND_DISPLAY="$DEV_NESTED_SOCK" QT_QPA_PLATFORM=wayland \
    /usr/lib/qt6/bin/qmltestrunner -import "$root/ui" -input "$root/tests/unit/tst_iconshader.qml" 2>&1)
  status=$?
  if [[ $status == 124 || $status == 137 ]]; then
    echo "test-icons: attempt $try stalled after ${limit}s (GPU contention?), retrying" >&2
    continue
  fi
  echo "$out" | grep -E "A2 |^PASS|^FAIL|^SKIP|Totals"
  if [[ $status != 0 ]] || grep -qE '^FAIL|SKIP' <<<"$out"; then
    # The failure list of the one test (not the per-icon lines) follows the FAIL line.
    echo "$out" | sed -n '/failures:/,/Loc:/p' | head -80
    exit 1
  fi
  exit 0
done
echo "test-icons: every attempt stalled" >&2
exit 2
