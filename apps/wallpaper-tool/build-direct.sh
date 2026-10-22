#!/usr/bin/env bash
# Direct build of grassfield-wallpaper with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-wallpaper.
# Usage: apps/wallpaper-tool/build-direct.sh
#        apps/wallpaper-tool/build-direct.sh --tests            (the logic unit tests: .dev/build/wallpaper-unit-tests)
#        apps/wallpaper-tool/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
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

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" -DFIXTURE_DIR="\"$root/tests/unit/wallpaper-tool/fixtures\"" $(pkg-config --cflags Qt6Core Qt6Gui) \
    "$root/tests/unit/wallpaper-tool/tst_wallpaperlogic.cpp" "$root/tests/unit/wallpaper-tool/tst_commonsfetch.cpp" "$here/src/wallpaperlogic.cpp" "$here/src/commonsfetch.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui) -lgtest -lgtest_main -pthread \
    -o "$out/wallpaper-unit-tests$suffix"
  echo "built $out/wallpaper-unit-tests$suffix"
  exit 0
fi

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" $(pkg-config --cflags Qt6Core Qt6Gui) \
  "$here/src/main.cpp" "$here/src/wallpaperlogic.cpp" "$here/src/commonsfetch.cpp" \
  $(pkg-config --libs Qt6Core Qt6Gui) \
  -o "$out/grassfield-wallpaper$suffix"
echo "built $out/grassfield-wallpaper$suffix"
