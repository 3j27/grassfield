#!/usr/bin/env bash
# ADR-0035 D-6, step 7a: packaging/session-bin/hyprland-share-picker and hyprland-preview-share-picker, the stand-ins for
# xdph's screen-sharing picker, against a fake shell (qs ipc and the one-time socket), a fake hyprctl and fake stock pickers,
# with a copy of xdph 1.4.1's parser reading what they print (spec system-dialogs.md A-SP1 to A-SP3; the checks are
# share_picker.d/check.py). No compositor, no shell, no bus; about a minute (two waits of 15 s and more are real).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/share-picker.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
unset GRASSFIELD_DEV GRASSFIELD_SESSION GRASSFIELD_SHELL_DIR QS_CONFIG_PATH QS_CONFIG_NAME QS_MANIFEST
python3 -I "$root/tests/shell/share_picker.d/check.py" "$root" "$tmp"
