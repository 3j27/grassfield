#!/usr/bin/env bash
# Direct build of grassfield-portal-settings with g++ (see CMakeLists.txt). Output: .dev/build/grassfield-portal-settings.
# Usage: apps/portal-settings/build-direct.sh
#        apps/portal-settings/build-direct.sh --tests            (the unit tests: .dev/build/portal-settings-unit-tests)
#        apps/portal-settings/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
#        apps/portal-settings/build-direct.sh --out DIR          (the backend into DIR instead of .dev/build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
tests=0
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC)
suffix=""
while (($#)); do
  case $1 in
    --tests) tests=1 ;;
    --asan) cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer); suffix="-asan" ;;
    --out) out=$2; shift ;;
    *) echo "usage: $0 [--tests] [--asan] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$out"
moc=$(pkg-config --variable=libexecdir Qt6Core)/moc
[[ -x $moc ]] || moc=/usr/lib/qt6/moc
gen=$(mktemp -d)
trap 'rm -rf "$gen"' EXIT
"$moc" "$here/src/settingsbackend.h" -o "$gen/moc_settingsbackend.cpp"

if ((tests)); then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" -I"$root/apps" $(pkg-config --cflags Qt6Core Qt6DBus) \
    "$root/tests/unit/portal-settings/tst_portalvalues.cpp" "$here/src/settingsbackend.cpp" "$gen/moc_settingsbackend.cpp" \
    $(pkg-config --libs Qt6Core Qt6DBus) -lgtest -lgtest_main -pthread \
    -o "$out/portal-settings-unit-tests$suffix"
  echo "built $out/portal-settings-unit-tests$suffix"
  exit 0
fi

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$root/apps" $(pkg-config --cflags Qt6Core Qt6DBus) \
  "$here/src/main.cpp" "$here/src/settingsbackend.cpp" "$gen/moc_settingsbackend.cpp" \
  $(pkg-config --libs Qt6Core Qt6DBus) -o "$out/grassfield-portal-settings$suffix"
echo "built $out/grassfield-portal-settings$suffix"
