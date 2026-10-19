#!/usr/bin/env bash
# Gate A2 for the icon appearance modes: tests/unit/tst_iconshader.qml needs a GPU scene graph (ShaderEffect does not run
# on the software renderer of the offscreen platform, where the test skips), so it runs as a Wayland client of this
# tree's NESTED session (scripts/dev/nested-up.sh first). Run it as a bare command. Prints the per-icon contrast lines
# ("A2 ...") and exits 0 when every rule holds.
#
# A renderer can stall when the GPU is shared with other nested sessions (a swap that never completes). Every test function
# (a size, the desktop, the folder model, the missing-shader fallback) runs in a process of its own under a watchdog
# (GRASSFIELD_ICONS_TIMEOUT seconds, default 240, then SIGKILL after 10 s) and a stalled attempt is retried
# (GRASSFIELD_ICONS_ATTEMPTS, default 4): a stall costs one case, not the whole run. A real failure (a FAIL line) is never retried.
#
#   scripts/dev/test-icons.sh
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "test-icons: no nested session of this tree (scripts/dev/nested-up.sh)" >&2; exit 1; }
limit=${GRASSFIELD_ICONS_TIMEOUT:-240}
attempts=${GRASSFIELD_ICONS_ATTEMPTS:-4}
cases=("$@")
[[ ${#cases[@]} -gt 0 ]] || cases=(test_a2_size48 test_a2_size32 test_a2_size24 test_a2_size16 test_a2_desktop test_a2_transparent48 test_a2_transparent24 test_a2_transparent16 test_folderModelMatchesTheShader test_blackFolderKeepsItsPlateOnBlack test_missingShaderDrawsThePlainIcon)
overall=0
for fn in "${cases[@]}"; do
  done_case=0
  for ((try = 1; try <= attempts; try++)); do
    out=$(timeout -k 10 "$limit" "$root/scripts/dev/isolated.sh" --name a2 env WAYLAND_DISPLAY="$DEV_NESTED_SOCK" QT_QPA_PLATFORM=wayland \
      /usr/lib/qt6/bin/qmltestrunner -import "$root/ui" -input "$root/tests/unit/tst_iconshader.qml" "IconShaderA2::$fn" 2>&1)
    status=$?
    # A stall: killed by the watchdog, or no result at all (the runner died before reporting).
    if [[ $status == 124 || $status == 137 ]] || ! grep -q 'Totals' <<<"$out"; then
      echo "test-icons: $fn attempt $try stalled (exit $status, limit ${limit}s), retrying" >&2
      continue
    fi
    echo "$out" | grep -E "A2 |^PASS|^FAIL|^SKIP|Totals"
    if [[ $status != 0 ]] || grep -qE '^FAIL|^SKIP' <<<"$out"; then
      echo "$out" | sed -n '/failures:/,/Loc:/p' | head -80
      echo "test-icons: $fn FAILED"
      overall=1
    else
      echo "test-icons: $fn passed (attempt $try)"
    fi
    done_case=1
    break
  done
  if [[ $done_case == 0 ]]; then
    echo "test-icons: $fn: every attempt stalled" >&2
    overall=2
  fi
done
exit "$overall"
