#!/usr/bin/env bash
# Direct build of grassfield-stack-helper with g++ (see CMakeLists.txt). Output: .dev/build/grassfield-stack-helper.
# Usage: apps/stack-helper/build-direct.sh
#        apps/stack-helper/build-direct.sh --tests            (the logic unit tests: .dev/build/stack-helper-unit-tests)
#        apps/stack-helper/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC)
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
files=$root/apps/files/src

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" -I"$files" $(pkg-config --cflags Qt6Core) \
    "$root/tests/unit/stack-helper/tst_stacklogic.cpp" "$root/tests/unit/stack-helper/tst_helper.cpp" "$here/src/helper.cpp" "$here/src/stacklogic.cpp" "$files/filelogic.cpp" \
    $(pkg-config --libs Qt6Core) -lgtest -lgtest_main -pthread \
    -o "$out/stack-helper-unit-tests$suffix"
  echo "built $out/stack-helper-unit-tests$suffix"
  exit 0
fi

# built beside and moved into place: a helper that is running (or a shell starting one) never meets a half-written file
tmpbin=$out/.grassfield-stack-helper$suffix.$$
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$files" $(pkg-config --cflags Qt6Core) \
  "$here/src/main.cpp" "$here/src/helper.cpp" "$here/src/stacklogic.cpp" "$files/filelogic.cpp" \
  $(pkg-config --libs Qt6Core) \
  -o "$tmpbin"
mv -f "$tmpbin" "$out/grassfield-stack-helper$suffix"
echo "built $out/grassfield-stack-helper$suffix"
