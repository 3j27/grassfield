#!/usr/bin/env bash
# Guard: a popup menu is destroyed by Popups.close() the moment an item is chosen (shell/overlay/Overlay.qml loads it from a
# Component), which kills any Process it owns. DockMenu.qml must hand the work started by an item (Open at Login, Show in
# Files) to Apps (a singleton) or to execDetached; the only Process it may own is the read-only autostart check that runs
# while the menu is open. Nested check with the real menu: docs/specs/dock.md (Open at Login writes the file, Show in Files
# reaches the open policy).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
f=$root/shell/overlay/DockMenu.qml
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
n=$(grep -c '^ *Process {' "$f")
[[ $n -eq 1 ]] && ok "DockMenu owns one Process" || bad "DockMenu owns $n Process objects (expected only autostartCheck)"
grep -q 'id: autostartCheck' "$f" && ok "the owned Process is the read-only check" || bad "autostartCheck missing"
grep -q 'Apps.writeAutostart' "$f" && grep -q 'Apps.removeAutostart' "$f" && grep -q 'Apps.revealExecutable' "$f" && ok "item work goes through Apps" || bad "item work does not go through Apps"
grep -q 'function writeAutostart' "$root/shell/services/Apps.qml" && grep -q 'execDetached' "$root/shell/services/Apps.qml" && ok "Apps writes the autostart file detached" || bad "Apps.writeAutostart missing"
exit $fail
