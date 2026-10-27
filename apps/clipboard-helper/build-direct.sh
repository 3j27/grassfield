#!/usr/bin/env bash
# Direct build of grassfield-clipboard-helper with g++ (see CMakeLists.txt). Output: .dev/build/grassfield-clipboard-helper.
# Usage: apps/clipboard-helper/build-direct.sh
#        apps/clipboard-helper/build-direct.sh --tests            (the logic unit tests: .dev/build/clipboard-helper-unit-tests)
#        apps/clipboard-helper/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
#        apps/clipboard-helper/build-direct.sh --fake-server      (the test compositor: .dev/build/fake-clipboard-server)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
gen=$out/clipboard-protocols
mkdir -p "$out" "$gen"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC)
cflags=(-O2 -fPIC)
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  cflags+=(-g -fsanitize=address,undefined)
  suffix="-asan"
fi

# Protocol code (wayland-scanner, from the wayland package): the vendored XML of ext-data-control-v1 and hyprland-lock-notify-v1.
# side: client | server
protocols() {
  local side=$1 xml name
  for xml in "$here/protocols/ext-data-control-v1.xml" "$here/protocols/hyprland-lock-notify-v1.xml"; do
    name=$(basename "$xml" .xml)
    wayland-scanner "$side-header" "$xml" "$gen/$name-$side-protocol.h"
    wayland-scanner private-code "$xml" "$gen/$name-protocol.c"
    gcc "${cflags[@]}" -c "$gen/$name-protocol.c" -o "$gen/$name-protocol$suffix.o"
  done
}

if [[ ${1:-} == "--fake-server" ]]; then
  protocols server
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$gen" "$root/tests/fixtures/fake-clipboard-server/server.cpp" \
    "$gen/ext-data-control-v1-protocol$suffix.o" "$gen/hyprland-lock-notify-v1-protocol$suffix.o" \
    $(pkg-config --cflags --libs wayland-server) -pthread -o "$out/fake-clipboard-server$suffix"
  echo "built $out/fake-clipboard-server$suffix"
  exit 0
fi

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" $(pkg-config --cflags Qt6Core Qt6Gui) \
    "$root/tests/unit/clipboard-helper/tst_cliplogic.cpp" "$root/tests/unit/clipboard-helper/tst_diskstore.cpp" \
    "$root/tests/unit/clipboard-helper/tst_thumbnail.cpp" \
    "$here/src/cliplogic.cpp" "$here/src/diskstore.cpp" "$here/src/thumbnail.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui) -lgtest -lgtest_main -pthread \
    -o "$out/clipboard-helper-unit-tests$suffix"
  echo "built $out/clipboard-helper-unit-tests$suffix"
  exit 0
fi

protocols client
# built beside and moved into place: a helper that is running (or a shell starting one) never meets a half-written file
tmpbin=$out/.grassfield-clipboard-helper$suffix.$$
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$gen" $(pkg-config --cflags Qt6Core Qt6Gui wayland-client) \
  "$here/src/main.cpp" "$here/src/helper.cpp" "$here/src/cliplogic.cpp" "$here/src/diskstore.cpp" "$here/src/thumbnail.cpp" \
  "$here/src/wlclient.cpp" "$gen/ext-data-control-v1-protocol$suffix.o" "$gen/hyprland-lock-notify-v1-protocol$suffix.o" \
  $(pkg-config --libs Qt6Core Qt6Gui wayland-client) \
  -o "$tmpbin"
mv -f "$tmpbin" "$out/grassfield-clipboard-helper$suffix"
echo "built $out/grassfield-clipboard-helper$suffix"
