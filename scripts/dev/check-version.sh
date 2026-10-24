#!/usr/bin/env bash
# One version source (D-11, GF-013): the VERSION file at the repository root. Fails when a consumer has its own number:
#   - VERSION is one line, MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-suffix
#   - every CMakeLists.txt includes cmake/GrassfieldVersion.cmake (project version, GRASSFIELD_VERSION definition)
#   - no C++ source or build script carries a literal version of its own (kBridgeVersion, *_VERSION "x.y.z", ...)
#   - packaging/arch/PKGBUILD derives pkgver from VERSION (the evaluated pkgver equals VERSION without the hyphen)
#   - the split packages are one release: grassfield-compositor depends on exactly grassfield-desktop=$pkgver-$pkgrel (the
#     shell and the plugin speak one protocol, ADR-0007), and grassfield-desktop does not depend on the compositor (the
#     desktop runs without the plugin, gate C2)
#   - the shell's About reads VERSION (shell/services/SystemInfo.qml)
#   - CHANGELOG.md has a section for this version as its newest
# `scripts/dev/check-version.sh --selftest` runs the checks against temporary trees. Exit 0 ok, 1 inconsistent.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# The final depends of a package function, one entry per line, as makepkg sees it: the PKGBUILD sourced (its variables,
# its global depends), then the function's depends= / depends+= statements evaluated in order (bash prints each array
# assignment of a function on one line). Nothing else of the function runs.
pkg_final_depends() { # <PKGBUILD> <package name>
  (
    cd "$(dirname "$1")" || exit 1
    # shellcheck disable=SC1090
    source "./$(basename "$1")" >/dev/null 2>&1
    declare -F "package_$2" >/dev/null || exit 0
    while IFS= read -r line; do
      eval "$line"
    done < <(declare -f "package_$2" | sed -n 's/^[[:space:]]*\(depends+\{0,1\}=(.*)\);\{0,1\}$/\1/p')
    printf '%s\n' "${depends[@]}"
  )
}
# "<pkgver>-<pkgrel>" of a PKGBUILD.
pkg_full_version() { (cd "$(dirname "$1")" && source "./$(basename "$1")" >/dev/null 2>&1 && printf '%s-%s' "$pkgver" "$pkgrel"); }
# The version pin between the split packages, when the PKGBUILD defines the compositor package: prints the problems.
pkg_pin_problems() { # <PKGBUILD>
  local want
  grep -q '^package_grassfield-compositor() {' "$1" || return 0
  want="grassfield-desktop=$(pkg_full_version "$1")"
  pkg_final_depends "$1" grassfield-compositor | grep -qxF -- "$want" \
    || echo "PKGBUILD: grassfield-compositor must depend on \"grassfield-desktop=\$pkgver-\$pkgrel\" ($want) in its final depends (one release: the shell and the plugin speak one protocol)"
  if pkg_final_depends "$1" grassfield-desktop | grep -q '^grassfield-compositor'; then
    echo "PKGBUILD: grassfield-desktop must not depend on grassfield-compositor (the desktop runs without the plugin)"
  fi
}

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
    pin=$(pkg_pin_problems "$t/packaging/arch/PKGBUILD")
    [[ -z $pin ]] || { echo "$pin"; n=$((n + 1)); }
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
  rm -rf "$d/a/apps"
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland)\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a compositor package without the desktop pin was accepted"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland "grassfield-desktop=$pkgver-$pkgrel")\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null || { echo "FAIL: the exact pin was rejected"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland grassfield-compositor)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland "grassfield-desktop=$pkgver-$pkgrel")\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a desktop that needs the plugin was accepted"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland "grassfield-desktop=$pkgver-$pkgrel")\n  depends=(hyprland)\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a pin overridden by a later depends= was accepted"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland)\n  depends+=("grassfield-desktop=$pkgver-$pkgrel")\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null || { echo "FAIL: a pin added with depends+= was rejected"; fails=1; }
  printf '_v=$(tr -d "[:space:]" <../../VERSION)\npkgver=${_v//-/}\npkgrel=1\npackage_grassfield-desktop() {\n  depends=(hyprland)\n}\npackage_grassfield-compositor() {\n  depends=(hyprland "grassfield-desktop=$pkgver-2")\n}\n' >"$d/a/packaging/arch/PKGBUILD"
  check_tree "$d/a" >/dev/null && { echo "FAIL: a pin to another pkgrel was accepted"; fails=1; }
  ((fails == 0)) && echo "check-version selftest: PASS (11 cases)"
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
