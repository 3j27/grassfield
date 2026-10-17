#!/usr/bin/env bash
# Offscreen unit tests (L0): QML TestCase files under tests/unit/, compositor unit tests if built.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
status=0
# Offscreen tests must not load the desktop's platform theme (QT_QPA_PLATFORMTHEME=gtk3 calls gtk_init, which
# needs a display and fails inside the Claude Code sandbox).
unset QT_QPA_PLATFORMTHEME
# Scratch dir for tests that write files (removed on exit).
export GRASSFIELD_TEST_TMP="$root/.dev/test-tmp.$$"
mkdir -p "$GRASSFIELD_TEST_TMP"
trap 'rm -rf "$GRASSFIELD_TEST_TMP"' EXIT
if compgen -G "tests/unit/tst_*.qml" >/dev/null; then
  unit_out=$(QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/unit 2>&1) || status=1
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
  # Private runtime/cache dirs: works inside the Claude Code sandbox (no writes to /run/user or ~/.cache).
  mkdir -p -m 700 "$GRASSFIELD_TEST_TMP/runtime" "$GRASSFIELD_TEST_TMP/cache"
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    XDG_RUNTIME_DIR="$GRASSFIELD_TEST_TMP/runtime" XDG_CACHE_HOME="$GRASSFIELD_TEST_TMP/cache" \
    timeout 60 qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; continue; }
  echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; status=1; }
  if grep -q "FAIL" <<<"$out"; then status=1; fi
done
# Plain shell tests: tests/shell/*.sh print PASS/FAIL and exit non-zero on failure.
for script in tests/shell/*.sh; do
  [[ -f $script ]] || continue
  bash "$script" || { echo "FAIL: $script"; status=1; }
done
# Grassfield Files pure logic (sort keys, sizes, dates, path segments, names): gtest, built here.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/files/build-direct.sh --tests >/dev/null; then
    .dev/build/files-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/files"; status=1
  fi
else
  echo "SKIP: tests/unit/files (gtest not installed)"
fi
# Grassfield Preview pure logic (URL validation, size caps, file-type routing): gtest, built here.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/preview/build-direct.sh --tests >/dev/null; then
    .dev/build/preview-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/preview"; status=1
  fi
else
  echo "SKIP: tests/unit/preview (gtest not installed)"
fi
if [[ -x compositor/build/grassfield-compositor-tests ]]; then
  compositor/build/grassfield-compositor-tests || status=1
fi
exit $status
