#!/usr/bin/env bash
# One version source (D-11, GF-013): the VERSION file at the repository root. Fails when a consumer has its own number:
#   - VERSION is one line, MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-suffix
#   - every CMakeLists.txt includes cmake/GrassfieldVersion.cmake (project version, GRASSFIELD_VERSION definition)
#   - no C++ source or build script carries a literal version of its own (kBridgeVersion, *_VERSION "x.y.z", ...)
#   - packaging/arch/PKGBUILD derives pkgver from VERSION (the evaluated pkgver equals VERSION without the hyphen)
#   - the shell's About reads VERSION (shell/services/SystemInfo.qml)
#   - CHANGELOG.md has a section for this version as its newest
# `scripts/dev/check-version.sh --selftest` runs the checks against temporary trees. Exit 0 ok, 1 inconsistent.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

check_tree() { # <tree root>: prints problems, returns 1 when there are any
  local t=$1 v n=0 f
  [[ -f $t/VERSION ]] || { echo "VERSION: missing"; return 1; }
  if [[ $(grep -c '' "$t/VERSION") != 1 ]]; then echo "VERSION: must be exactly one line"; n=$((n + 1)); fi
  v=$(tr -d '[:space:]' <"$t/VERSION")
  if [[ ! $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then echo "VERSION: '$v' is not MAJOR.MINOR.PATCH[-suffix]"; n=$((n + 1)); fi
  while IFS= read -r f; do
    grep -q 'GrassfieldVersion.cmake' "$t/$f" || { echo "$f: does not include cmake/GrassfieldVersion.cmake"; n=$((n + 1)); }
    grep -q -E 'project\([^)]*VERSION [0-9]' "$t/$f" && { echo "$f: project() has a literal VERSION"; n=$((n + 1)); }
  done < <(cd "$t" && find . -name CMakeLists.txt -not -path './.dev/*' -not -path '*/build/*' -not -path './.claude/*' -not -path './spikes/*' | sed 's|^\./||' | sort)
  hits=$(cd "$t" && grep -rn -E '(VERSION|Version)(\[\])? *(=|") *"?[0-9]+\.[0-9]+\.[0-9]+' apps bridges compositor/src 2>/dev/null | grep -v '/build/' || true)
  if [[ -n $hits ]]; then echo "literal version in the sources:"; echo "$hits"; n=$((n + 1)); fi
  if [[ -f $t/packaging/arch/PKGBUILD ]]; then
    got=$(cd "$t/packaging/arch" && bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s" "$pkgver"')
    want=${v//-/}
    [[ $got == "$want" ]] || { echo "PKGBUILD: pkgver is '$got', VERSION says '$v' (expected '$want')"; n=$((n + 1)); }
  else
    echo "packaging/arch/PKGBUILD: missing"; n=$((n + 1))
  fi
  grep -q '\.\./VERSION' "$t/shell/services/SystemInfo.qml" 2>/dev/null || { echo "shell/services/SystemInfo.qml: does not read VERSION"; n=$((n + 1)); }
  first=$(grep -m1 '^## ' "$t/CHANGELOG.md" 2>/dev/null)
  [[ $first == "## $v"* ]] || { echo "CHANGELOG.md: the newest section is '${first:-none}', expected '## $v'"; n=$((n + 1)); }
  ((n == 0))
}

selftest() {
  local d fails=0
  d=$(mktemp -d)
  trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/a/packaging/arch" "$d/a/shell/services" "$d/a/x"
  printf '1.2.3-rc1\n' >"$d/a/VERSION"
  printf 'include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/GrassfieldVersion.cmake)\nproject(x VERSION ${GF_VERSION_NUMERIC})\n' >"$d/a/x/CMakeLists.txt"
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\n' >"$d/a/packaging/arch/PKGBUILD"
  printf '../VERSION\n' >"$d/a/shell/services/SystemInfo.qml"
  printf '# Changelog\n\n## 1.2.3-rc1 (x)\n' >"$d/a/CHANGELOG.md"
  check_tree "$d/a" >/dev/null || { echo "FAIL: a consistent tree was rejected"; fails=1; }
  printf 'project(x VERSION 0.1.0)\n' >"$d/a/x/CMakeLists.txt"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a literal project VERSION was accepted"; fails=1; }
  printf 'include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/GrassfieldVersion.cmake)\nproject(x VERSION ${GF_VERSION_NUMERIC})\n' >"$d/a/x/CMakeLists.txt"
  printf 'pkgver=0.4.0\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a stale pkgver was accepted"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\n' >"$d/a/packaging/arch/PKGBUILD"
  printf '# Changelog\n\n## 0.9.0\n' >"$d/a/CHANGELOG.md"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a changelog without this version was accepted"; fails=1; }
  mkdir -p "$d/a/apps/z"
  printf '#define GRASSFIELD_Z_VERSION "0.1.0"\n' >"$d/a/apps/z/main.cpp"
  printf '# Changelog\n\n## 1.2.3-rc1\n' >"$d/a/CHANGELOG.md"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a literal version in a source was accepted"; fails=1; }
  ((fails == 0)) && echo "check-version selftest: PASS (5 cases)"
  return "$fails"
}

if [[ ${1:-} == --selftest ]]; then selftest; exit $?; fi
if out=$(check_tree "$root"); then
  echo "version: ok ($(tr -d '[:space:]' <"$root/VERSION"))"
else
  echo "$out"
  echo "version: FAIL (the single source is the VERSION file)" >&2
  exit 1
fi
