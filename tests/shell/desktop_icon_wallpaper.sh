#!/usr/bin/env bash
# Desktop icons are drawn over the bare wallpaper, not over a window material: their icon appearance effect must be
# styled for the wallpaper (dark palette, strong glass) whatever the window appearance (A2, docs/specs/ui.md "Icon shader").
# Offline source check; the rendering is measured by tests/unit/tst_iconshader.qml (scripts/dev/test-icons.sh).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
f=$root/shell/desktop/DesktopIcon.qml
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
n=$(grep -c 'overWallpaper: true' "$f")
[[ $n -ge 2 ]]; check "DesktopIcon passes overWallpaper to TintedIcon and FolderIcon ($n)" $?
n=$(grep -c 'darkAppearance: true' "$f")
[[ $n -ge 2 ]]; check "DesktopIcon passes darkAppearance: true to both ($n)" $?
exit $fails
