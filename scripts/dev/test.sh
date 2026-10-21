#!/usr/bin/env bash
# Offscreen unit tests (L0): QML TestCase files under tests/unit/, compositor unit tests if built.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
status=0
# Skipped checks are reported on their own (a SKIP line is never a pass): every line with "SKIP" printed by a test or
# by this script is collected here and repeated in the summary at the end.
skips=()
collect_skips() { local line; while IFS= read -r line; do [[ $line == *SKIP* ]] && skips+=("$line"); done <<<"$1"; return 0; }
skip() { echo "SKIP: $1"; skips+=("SKIP: $1"); }
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
# The i18n tests import the Grassfield.I18n plugin and read the compiled catalogs.
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null
for dir in tests/shell/*/ tests/security/*/; do
  [[ -f ${dir}shell.qml ]] || continue
  # Private runtime/cache dirs: works inside the Claude Code sandbox (no writes to /run/user or ~/.cache).
  mkdir -p -m 700 "$GRASSFIELD_TEST_TMP/runtime" "$GRASSFIELD_TEST_TMP/cache"
  # A test that loads the real notification singleton carries a `dev-session` marker file: it runs as a dev session
  # (GRASSFIELD_DEV=1: no D-Bus server on the owner's bus) with its state and config under the scratch dir.
  dev_env=()
  [[ -f ${dir}dev-session ]] && dev_env=(-u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$GRASSFIELD_TEST_TMP/state" GRASSFIELD_CONFIG_HOME="$GRASSFIELD_TEST_TMP/config")
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE "${dev_env[@]}" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" GRASSFIELD_LANG=en \
    XDG_RUNTIME_DIR="$GRASSFIELD_TEST_TMP/runtime" XDG_CACHE_HOME="$GRASSFIELD_TEST_TMP/cache" \
    timeout 60 qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; continue; }
  echo "$out" | grep -E "PASS|FAIL|SKIP" || { echo "$out"; status=1; }
  collect_skips "$out"
  if grep -q "FAIL" <<<"$out"; then status=1; fi
done
# The CMake build of ui/i18n (packaging/arch/PKGBUILD) installs a loadable plugin: i18n_live runs against it.
if command -v cmake >/dev/null && command -v ninja >/dev/null; then
  scripts/dev/i18n-cmake-check.sh || { echo "FAIL: scripts/dev/i18n-cmake-check.sh"; status=1; }
else
  skip "i18n CMake check (cmake/ninja not installed)"
fi
# Plain shell tests: tests/shell/*.sh print PASS/FAIL and exit non-zero on failure.
for script in tests/shell/*.sh; do
  [[ -f $script ]] || continue
  script_out=$(bash "$script" 2>&1) && script_rc=0 || script_rc=$?
  [[ -n $script_out ]] && echo "$script_out"
  collect_skips "$script_out"
  ((script_rc == 0)) || { echo "FAIL: $script"; status=1; }
done
# Grassfield Files pure logic (sort keys, sizes, dates, path segments, names): gtest, built here.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/files/build-direct.sh --tests >/dev/null; then
    .dev/build/files-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/files"; status=1
  fi
else
  skip "tests/unit/files (gtest not installed)"
fi
# Grassfield Preview pure logic (URL validation, size caps, file-type routing): gtest, built here.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/preview/build-direct.sh --tests >/dev/null; then
    .dev/build/preview-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/preview"; status=1
  fi
else
  skip "tests/unit/preview (gtest not installed)"
fi
# grassfield-wallpaper (ADR-0016) logic: untrusted pictures (huge, corrupt, EXIF, FIFO, fit modes), listing, cache: gtest,
# built here, then again with ASan and UBSan.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/wallpaper-tool/build-direct.sh --tests >/dev/null && apps/wallpaper-tool/build-direct.sh --tests --asan >/dev/null; then
    QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests --gtest_brief=1 || status=1
    QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests-asan --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/wallpaper-tool"; status=1
  fi
else
  skip "tests/unit/wallpaper-tool (gtest not installed)"
fi
# grassfield-settings dev guard and the wallpaper helper door (exact tool path, exact argument vectors): gtest, built here.
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if apps/settings/build-direct.sh --tests >/dev/null; then
    .dev/build/settings-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/settings"; status=1
  fi
else
  skip "tests/unit/settings (gtest not installed)"
fi
# grassfield-menu-bridge logic (menu/1 validation, DBusMenu layout mapping, mnemonics, guards): gtest, built here.
# The peer-to-peer D-Bus case skips itself inside the sandbox (no Unix sockets).
if [[ -f /usr/include/gtest/gtest.h ]]; then
  if bridges/menu-bridge/build-direct.sh --tests >/dev/null; then
    .dev/build/menu-bridge-unit-tests --gtest_brief=1 || status=1
  else
    echo "FAIL: building tests/unit/menu-bridge"; status=1
  fi
else
  skip "tests/unit/menu-bridge (gtest not installed)"
fi
# Isolation: no test or dev script may start an app (grassfield-settings/files/preview, foot, ...) without
# scripts/dev/isolated.sh (nothing may be written to the owner's home), and the checker itself is tested.
python3 -I tests/tools/check-isolation.py --selftest || status=1
python3 -I tests/tools/check-isolation.py || status=1
# Visual suite tooling: contrast pixel reading and glyph-mask measurement on synthetic images.
python3 -I tests/visual/test_contrast.py || status=1
# Gate A2, exact token calculation (primary evidence): every text role over the worst-case wallpapers, both appearances, transparency 0..0.6.
python3 -I tests/visual/test_contrast_tokens.py || status=1
if [[ -x compositor/build/grassfield-compositor-tests ]]; then
  compositor/build/grassfield-compositor-tests || status=1
fi
if ((${#skips[@]})); then
  echo "summary: ${#skips[@]} check(s) SKIPPED (nothing was verified by them):"
  printf '  %s\n' "${skips[@]}"
else
  echo "summary: no check skipped"
fi
exit $status
