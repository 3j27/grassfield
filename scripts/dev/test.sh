#!/usr/bin/env bash
# Offscreen tests (L0): QML TestCase files under tests/unit/, tests/shell, tests/security, gtest suites, compositor unit tests.
#
#   scripts/dev/test.sh [--layer data|logic|headless|nested|visual[,...]]
#
# The layer of every test is in tests/inventory.json (docs/testing/README.md). Without --layer the run is what it always
# was: data, logic and headless, plus the tests/shell scripts of the nested layer (they SKIP themselves without a nested
# session). `--layer nested` runs only those scripts; nested and visual tests that are bare commands (just visual,
# tests/compositor/*.sh, ...) are never started here, they are counted as "manual" in the summary.
# A per-layer summary of pass, fail, skip and manual is printed at the end, and the run fails when a layer it covered
# reported no result (tests/ci/inventory.py --results).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

layers_all=(data logic headless nested visual)
requested=()
explicit=0
while (($#)); do
  case $1 in
    --layer)
      [[ -n ${2:-} ]] || { echo "test.sh: --layer needs a value" >&2; exit 2; }
      IFS=, read -r -a more <<<"$2"
      requested+=("${more[@]}")
      explicit=1
      shift 2
      ;;
    --layer=*)
      IFS=, read -r -a more <<<"${1#--layer=}"
      requested+=("${more[@]}")
      explicit=1
      shift
      ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "test.sh: unknown argument $1 (try --help)" >&2
      exit 2
      ;;
  esac
done
((explicit)) || requested=(data logic headless nested)
declare -A selected=()
for l in "${requested[@]}"; do
  [[ " ${layers_all[*]} " == *" $l "* ]] || { echo "test.sh: unknown layer '$l' (${layers_all[*]})" >&2; exit 2; }
  selected[$l]=1
done
want() { [[ -n ${selected[$1]:-} ]]; }

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

# The inventory: layer and runner of every test, and the gate (static part) before anything runs.
python3 -I tests/ci/inventory.py || exit 1
declare -A inv_layer=() inv_runner=()
declare -A manual=()
while IFS=$'\t' read -r p l r; do
  inv_layer[$p]=$l
  inv_runner[$p]=$r
  [[ $r == bare ]] && manual[$l]=$((${manual[$l]:-0} + 1))
done < <(python3 -I tests/ci/inventory.py --map)

# One record per check: layer, id, pass|fail|skip (tests/ci/inventory.py --results reads it).
results="$GRASSFIELD_TEST_TMP/results.tsv"
: >"$results"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"; }
# The layer of a registered path; an unregistered path is a failure (the static gate reports it too).
layer_of() {
  if [[ -z ${inv_layer[$1]:-} ]]; then echo "FAIL: $1 is not in tests/inventory.json" >&2; return 1; fi
  echo "${inv_layer[$1]}"
}
# Ran with exit code $3 and output $4: record pass, fail or skip (a SKIP line and no PASS line means nothing was verified).
record_run() {
  local layer=$1 id=$2 rc=$3 out=${4:-}
  if ((rc != 0)); then record "$layer" "$id" fail
  elif [[ $out == *SKIP* && $out != *PASS* ]]; then record "$layer" "$id" skip
  else record "$layer" "$id" pass
  fi
}

# --- headless: QML TestCase files under tests/unit -------------------------------------------------------------
if want headless && compgen -G "tests/unit/tst_*.qml" >/dev/null; then
  rc=0
  unit_out=$(QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/unit 2>&1) || rc=1
  echo "$unit_out"
  # A failing case fails the run even if the runner exited 0.
  if grep -qE '^FAIL' <<<"$unit_out"; then rc=1; fi
  ((rc == 0)) || status=1
  record_run headless "tests/unit (qmltestrunner)" "$rc" "PASS"
fi
# Security module logic (lock state machine and controller, polkit dialog model, idle timings).
# `import qs.<dir>` resolves through a temporary import root holding a `qs` -> shell symlink.
if want headless && compgen -G "tests/security/tst_*.qml" >/dev/null; then
  qs_root=$(mktemp -d)
  ln -s "$root/shell" "$qs_root/qs"
  rc=0
  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -import "$qs_root" -input tests/security || rc=1
  rm -rf "$qs_root"
  ((rc == 0)) || status=1
  record_run headless "tests/security (qmltestrunner)" "$rc" "PASS"
fi
# Quickshell-level tests (real FileView/JsonAdapter, reloads): each tests/shell/<name>/shell.qml and
# tests/security/<name>/shell.qml prints PASS/FAIL. Run offscreen and detached from any compositor session.
# The i18n tests import the Grassfield.I18n plugin and read the compiled catalogs.
if want headless; then
  ui/i18n/build-direct.sh >/dev/null
  scripts/dev/i18n-build.sh >/dev/null
fi
for dir in tests/shell/*/ tests/security/*/; do
  [[ -f ${dir}shell.qml ]] || continue
  layer=$(layer_of "${dir}shell.qml") || { status=1; continue; }
  want "$layer" || continue
  # Private runtime/cache dirs: works inside the Claude Code sandbox (no writes to /run/user or ~/.cache).
  mkdir -p -m 700 "$GRASSFIELD_TEST_TMP/runtime" "$GRASSFIELD_TEST_TMP/cache"
  # A test that loads the real notification singleton carries a `dev-session` marker file: it runs as a dev session
  # (GRASSFIELD_DEV=1: no D-Bus server on the owner's bus) with its state and config under the scratch dir.
  dev_env=()
  [[ -f ${dir}dev-session ]] && dev_env=(-u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$GRASSFIELD_TEST_TMP/state" GRASSFIELD_CONFIG_HOME="$GRASSFIELD_TEST_TMP/config")
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE "${dev_env[@]}" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" GRASSFIELD_LANG=en \
    XDG_RUNTIME_DIR="$GRASSFIELD_TEST_TMP/runtime" XDG_CACHE_HOME="$GRASSFIELD_TEST_TMP/cache" \
    timeout 60 qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; record "$layer" "${dir}shell.qml" fail; continue; }
  echo "$out" | grep -E "PASS|FAIL|SKIP" || { echo "$out"; status=1; }
  collect_skips "$out"
  if grep -q "FAIL" <<<"$out"; then status=1; record "$layer" "${dir}shell.qml" fail; continue; fi
  if grep -q "PASS" <<<"$out"; then record "$layer" "${dir}shell.qml" pass; elif grep -q SKIP <<<"$out"; then record "$layer" "${dir}shell.qml" skip; else status=1; record "$layer" "${dir}shell.qml" fail; fi
done
# The CMake build of ui/i18n (packaging/arch/PKGBUILD) installs a loadable plugin: i18n_live runs against it.
if want headless; then
  if command -v cmake >/dev/null && command -v ninja >/dev/null; then
    if scripts/dev/i18n-cmake-check.sh; then record headless scripts/dev/i18n-cmake-check.sh pass
    else echo "FAIL: scripts/dev/i18n-cmake-check.sh"; status=1; record headless scripts/dev/i18n-cmake-check.sh fail; fi
  else
    skip "i18n CMake check (cmake/ninja not installed)"
    record headless scripts/dev/i18n-cmake-check.sh skip
  fi
fi
# Plain shell tests: tests/shell/*.sh print PASS/FAIL and exit non-zero on failure. tests/security/*.sh run here only when
# registered with the test.sh runner (the nested security scenarios are bare commands; helpers are not registered).
for script in tests/shell/*.sh tests/security/*.sh; do
  [[ -f $script ]] || continue
  [[ $script == tests/security/* && ${inv_runner[$script]:-} != test.sh ]] && continue
  layer=$(layer_of "$script") || { status=1; continue; }
  want "$layer" || continue
  script_out=$(bash "$script" 2>&1) && script_rc=0 || script_rc=$?
  [[ -n $script_out ]] && echo "$script_out"
  collect_skips "$script_out"
  ((script_rc == 0)) || { echo "FAIL: $script"; status=1; }
  record_run "$layer" "$script" "$script_rc" "$script_out"
done
# gtest suites: logic. One step per binary, built here (the sources are listed in tests/inventory.json).
# gtest_suite LABEL GTEST_HEADER_NEEDED_NOTE BUILD_CMD BINARY...: builds, runs every binary, records one result.
gtest_suite() {
  local label=$1 build=$2
  shift 2
  want logic || return 0
  if [[ ! -f /usr/include/gtest/gtest.h ]]; then
    skip "$label (gtest not installed)"
    record logic "$label" skip
    return 0
  fi
  local rc=0
  if eval "$build" >/dev/null; then
    local bin
    for bin in "$@"; do
      eval "$bin" || rc=1
    done
  else
    echo "FAIL: building $label"
    rc=1
  fi
  ((rc == 0)) || status=1
  record logic "$label" "$([[ $rc == 0 ]] && echo pass || echo fail)"
}
# Grassfield Files pure logic (sort keys, sizes, dates, path segments, names).
gtest_suite tests/unit/files "apps/files/build-direct.sh --tests" ".dev/build/files-unit-tests --gtest_brief=1"
# Grassfield Preview pure logic (URL validation, size caps, file-type routing).
gtest_suite tests/unit/preview "apps/preview/build-direct.sh --tests" ".dev/build/preview-unit-tests --gtest_brief=1"
# grassfield-wallpaper (ADR-0016) logic: untrusted pictures (huge, corrupt, EXIF, FIFO, fit modes), listing, cache: built
# here, then again with ASan and UBSan.
gtest_suite tests/unit/wallpaper-tool "apps/wallpaper-tool/build-direct.sh --tests >/dev/null && apps/wallpaper-tool/build-direct.sh --tests --asan" \
  "QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests --gtest_brief=1" "QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests-asan --gtest_brief=1"
# grassfield-settings dev guard and the wallpaper helper door (exact tool path, exact argument vectors).
gtest_suite tests/unit/settings "apps/settings/build-direct.sh --tests >/dev/null && apps/settings/build-direct.sh --tests --asan" \
  ".dev/build/settings-unit-tests --gtest_brief=1" ".dev/build/settings-unit-tests-asan --gtest_brief=1"
# grassfield-menu-bridge logic (menu/1 validation, DBusMenu layout mapping, mnemonics, guards). The peer-to-peer D-Bus
# case skips itself inside the sandbox (no Unix sockets).
# Built twice: plain, then with ASan and UBSan.
gtest_suite tests/unit/menu-bridge "bridges/menu-bridge/build-direct.sh --tests >/dev/null && bridges/menu-bridge/build-direct.sh --tests --asan" \
  ".dev/build/menu-bridge-unit-tests --gtest_brief=1" ".dev/build/menu-bridge-unit-tests-asan --gtest_brief=1"
# Isolation: no test or dev script may start an app (grassfield-settings/files/preview, foot, ...) without
# scripts/dev/isolated.sh (nothing may be written to the owner's home), and the checker itself is tested.
if want logic; then
  rc=0
  python3 -I tests/tools/check-isolation.py --selftest || rc=1
  python3 -I tests/tools/check-isolation.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/tools/check-isolation.py "$rc" PASS
  # Visual suite tooling: contrast pixel reading and glyph-mask measurement on synthetic images.
  rc=0
  python3 -I tests/visual/test_contrast.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/visual/test_contrast.py "$rc" PASS
  # Gate A2, exact token calculation (primary evidence): every text role over the worst-case wallpapers, both appearances, transparency 0..0.6.
  rc=0
  python3 -I tests/visual/test_contrast_tokens.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/visual/test_contrast_tokens.py "$rc" PASS
  # The inventory gate on temporary fixtures.
  rc=0
  python3 -I tests/ci/inventory.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/inventory.py "$rc" PASS
  if [[ -x compositor/build/grassfield-compositor-tests ]]; then
    rc=0
    compositor/build/grassfield-compositor-tests || rc=1
    ((rc == 0)) || status=1
    record_run logic "compositor/tests (grassfield-compositor-tests)" "$rc" PASS
  else
    record logic "compositor/tests (grassfield-compositor-tests)" skip
  fi
fi
if ((${#skips[@]})); then
  echo "summary: ${#skips[@]} check(s) SKIPPED (nothing was verified by them):"
  printf '  %s\n' "${skips[@]}"
else
  echo "summary: no check skipped"
fi

# Per-layer summary. "manual" = registered bare commands of the layer (nested session, captures), never run here.
echo "layer      pass  fail  skip  manual"
gate_layers=()
for l in "${layers_all[@]}"; do
  want "$l" || continue
  read -r p f s < <(awk -F'\t' -v l="$l" '$1 == l { c[$3]++ } END { print c["pass"] + 0, c["fail"] + 0, c["skip"] + 0 }' "$results")
  printf '%-10s %4d  %4d  %4d  %6d\n' "$l" "$p" "$f" "$s" "${manual[$l]:-0}"
  # A layer is gated only when this script can run something of it.
  runnable=0
  for k in "${!inv_runner[@]}"; do [[ ${inv_layer[$k]} == "$l" && ${inv_runner[$k]} == test.sh ]] && runnable=1; done
  # The default run only opportunistically runs the nested layer's tests/shell scripts (they SKIP without a session): not gated.
  if ((!explicit)) && [[ $l == nested ]]; then runnable=0; fi
  if ((runnable)); then gate_layers+=("$l"); else echo "note: layer $l is not gated in this run (${manual[$l]:-0} manual entries: docs/testing/README.md)"; fi
done
if ((${#gate_layers[@]})); then
  gate_csv=$(IFS=,; echo "${gate_layers[*]}")
  python3 -I tests/ci/inventory.py --results "$results" --layers "$gate_csv" || status=1
fi
exit $status
