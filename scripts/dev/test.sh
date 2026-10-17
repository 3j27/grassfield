#!/usr/bin/env bash
# Offscreen unit tests (L0): QML TestCase files under tests/unit/, compositor unit tests if built.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
status=0
if compgen -G "tests/unit/tst_*.qml" >/dev/null; then
  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/unit || status=1
fi
# Security module logic (lock state machine and controller, polkit dialog model, idle timings).
# `import qs.<dir>` resolves through a temporary import root holding a `qs` -> shell symlink.
if compgen -G "tests/security/tst_*.qml" >/dev/null; then
  qs_root=$(mktemp -d)
  ln -s "$root/shell" "$qs_root/qs"
  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -import "$qs_root" -input tests/security || status=1
  rm -rf "$qs_root"
fi
# Quickshell-level tests (real FileView/JsonAdapter): each tests/shell/<name>/shell.qml prints PASS/FAIL.
# Run offscreen and detached from any compositor session.
for dir in tests/shell/*/; do
  [[ -f ${dir}shell.qml ]] || continue
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    timeout 60 qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; continue; }
  echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; status=1; }
done
if [[ -x compositor/build/grassfield-compositor-tests ]]; then
  compositor/build/grassfield-compositor-tests || status=1
fi
exit $status
