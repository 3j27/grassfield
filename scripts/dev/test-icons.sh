#!/usr/bin/env bash
# Gate A2 for the icon appearance modes: tests/unit/tst_iconshader.qml needs a GPU scene graph (ShaderEffect does not run
# on the software renderer of the offscreen platform, where the test skips), so it runs as a Wayland client of this
# tree's NESTED session (scripts/dev/nested-up.sh first). Run it as a bare command. Prints the per-icon contrast lines
# ("A2 ...") and exits 0 when every rule holds.
#
#   scripts/dev/test-icons.sh
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "test-icons: no nested session of this tree (scripts/dev/nested-up.sh)" >&2; exit 1; }
out=$("$root/scripts/dev/isolated.sh" --name a2 env WAYLAND_DISPLAY="$DEV_NESTED_SOCK" QT_QPA_PLATFORM=wayland \
  /usr/lib/qt6/bin/qmltestrunner -import "$root/ui" -input "$root/tests/unit/tst_iconshader.qml" 2>&1) || { echo "$out"; exit 1; }
echo "$out" | grep -E "A2 |^PASS|^FAIL|^SKIP|Totals"
if grep -qE '^FAIL|SKIP' <<<"$out"; then exit 1; fi
