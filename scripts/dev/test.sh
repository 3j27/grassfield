#!/usr/bin/env bash
# Offscreen unit tests (L0): QML TestCase files under tests/unit/, compositor unit tests if built.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
status=0
# Scratch dir for tests that write files (removed on exit).
export GRASSFIELD_TEST_TMP="$root/.dev/test-tmp.$$"
mkdir -p "$GRASSFIELD_TEST_TMP"
trap 'rm -rf "$GRASSFIELD_TEST_TMP"' EXIT
if compgen -G "tests/unit/tst_*.qml" >/dev/null; then
  unit_out=$(QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/unit 2>&1) || status=1
  echo "$unit_out"
  # A failing case fails the run even if the runner exited 0.
  if grep -qE '^FAIL' <<<"$unit_out"; then status=1; fi
fi
# Security module logic (lock state machine and controller, polkit dialog model, idle timings).
# `import qs.<dir>` resolves through a temporary import root holding a `qs` -> shell symlink.
if compgen -G "tests/security/tst_*.qml" >/dev/null; then
  qs_root=$(mktemp -d)
  ln -s "$root/shell" "$qs_root/qs"
  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -import "$qs_root" -input tests/security || status=1
  rm -rf "$qs_root"
fi
# Quickshell-level tests (real FileView/JsonAdapter, reloads): each tests/shell/<name>/shell.qml and
# tests/security/<name>/shell.qml prints PASS/FAIL. Run offscreen and detached from any compositor session.
for dir in tests/shell/*/ tests/security/*/; do
  [[ -f ${dir}shell.qml ]] || continue
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    timeout 60 qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; continue; }
  echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; status=1; }
  if grep -q "FAIL" <<<"$out"; then status=1; fi
done
if [[ -x compositor/build/grassfield-compositor-tests ]]; then
  compositor/build/grassfield-compositor-tests || status=1
fi
exit $status
