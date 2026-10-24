#!/usr/bin/env bash
# Gate Q3: line coverage of the C++ logic by its unit tests, with gcc's gcov (gcovr and lcov are not installed; the
# summary is scripts/gates/coverage_report.py). Two components:
#   compositor  src/core/*.cpp, the pure logic of the plugin (tests/*.cpp of compositor/, gtest)
#   menu-bridge bridges/menu-bridge/src/*.cpp that tests/unit/menu-bridge links (gtest)
# The plugin's Hyprland glue (compositor/src/*.cpp) and the bridge's Bridge/main/LauncherWatcher need a running
# compositor or session: they are listed as "not measured", never counted as covered.
#
#   scripts/gates/coverage.sh [compositor|menu-bridge|all]      env COVERAGE_MIN (default 70): the Q3 threshold, in %
#
# Builds instrumented copies with the projects' own build-direct.sh through a g++ wrapper that adds --coverage -O0
# (nothing in the projects is edited). The compositor is built in a copy under .dev/coverage/ so that
# compositor/build/ keeps its normal test binary; the bridge's unit-test binary in .dev/build/ is replaced by an
# instrumented one until the next `just test` (which always rebuilds it).
# Exit: 0 every measured component reached COVERAGE_MIN and its tests passed; 1 not; 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
what=${1:-all}
min=${COVERAGE_MIN:-70}
[[ $what == compositor || $what == menu-bridge || $what == all ]] || { echo "usage: coverage.sh [compositor|menu-bridge|all]" >&2; exit 2; }
for tool in gcov g++ python3 jq; do command -v "$tool" >/dev/null || { echo "coverage: $tool is needed" >&2; exit 2; }; done
cov=$root/.dev/coverage
real_gxx=$(command -v g++)
mkdir -p "$cov/shim"
printf '#!/bin/sh\nexec %s "$@" --coverage -O0 -fprofile-update=atomic\n' "$real_gxx" >"$cov/shim/g++"
chmod +x "$cov/shim/g++"
report() { python3 -I "$root/scripts/gates/coverage_report.py" --min "$min" "$@"; }
status=0

if [[ $what == compositor || $what == all ]]; then
  rm -rf "$cov/compositor"
  mkdir -p "$cov/compositor"
  cp -r "$root/compositor/src" "$root/compositor/tests" "$root/compositor/build-direct.sh" "$cov/compositor/"
  cp "$root/VERSION" "$cov/VERSION" # build-direct.sh reads ../VERSION
  if PATH=$cov/shim:$PATH "$cov/compositor/build-direct.sh" tests >"$cov/compositor/build.log" 2>&1; then
    "$cov/compositor/build/grassfield-compositor-tests" --gtest_brief=1 >"$cov/compositor/tests.log" 2>&1 || { echo "coverage: compositor unit tests FAILED ($cov/compositor/tests.log)" >&2; status=1; }
    tail -n 3 "$cov/compositor/tests.log"
    report --label "compositor src/core" --obj-dir "$cov/compositor/build" --source-dir "$cov/compositor/src/core" --per-file || status=1
    glue=$(ls "$root"/compositor/src/*.cpp | wc -l)
    glue_lines=$(cat "$root"/compositor/src/*.cpp | wc -l)
    echo "coverage compositor glue: not measured ($glue files, $glue_lines source lines: they need a running Hyprland; nested tests exercise them)"
  else
    echo "coverage: the instrumented compositor tests did not build ($cov/compositor/build.log)" >&2
    status=2
  fi
fi

if [[ $what == menu-bridge || $what == all ]]; then
  rm -rf "$cov/menu-bridge"
  mkdir -p "$cov/menu-bridge"
  rm -f "$root"/.dev/build/menu-bridge-unit-tests-*.gc*
  if PATH=$cov/shim:$PATH "$root/bridges/menu-bridge/build-direct.sh" --tests >"$cov/menu-bridge/build.log" 2>&1; then
    "$root/.dev/build/menu-bridge-unit-tests" --gtest_brief=1 >"$cov/menu-bridge/tests.log" 2>&1 || { echo "coverage: menu-bridge unit tests FAILED ($cov/menu-bridge/tests.log)" >&2; status=1; }
    tail -n 3 "$cov/menu-bridge/tests.log"
    grep -a -c SKIPPED "$cov/menu-bridge/tests.log" | sed 's/^/coverage menu-bridge: skipped cases (the D-Bus ones need a real session bus, not the sandbox): /'
    mv "$root"/.dev/build/menu-bridge-unit-tests-*.gc* "$cov/menu-bridge/" 2>/dev/null || true
    report --label "menu-bridge" --obj-dir "$cov/menu-bridge" --source-dir "$root/bridges/menu-bridge/src" --per-file || status=1
    echo "coverage menu-bridge: Bridge.cpp, main.cpp and LauncherWatcher.cpp are not linked into the unit tests (not measured)"
  else
    echo "coverage: the instrumented menu-bridge tests did not build ($cov/menu-bridge/build.log)" >&2
    status=2
  fi
fi
((status == 0)) && echo "coverage: PASS (every measured component >= ${min} %)" || echo "coverage: FAIL (see above; threshold ${min} %)"
exit "$status"
