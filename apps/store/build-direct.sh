#!/usr/bin/env bash
# Direct build of Grassfield Store's backend tests with g++ (CMake is not installed yet; see CMakeLists.txt). Step 1 has no
# app binary: the backend is read-only and has no window yet (ADR-0037, step 2 adds the app).
# Usage: apps/store/build-direct.sh --tests [--asan]   (.dev/build/store-unit-tests, or -asan with -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

if [[ ${1:-} != "--tests" ]]; then
  echo "usage: apps/store/build-direct.sh --tests [--asan]" >&2
  exit 2
fi
extra=()
suffix=""
if [[ ${2:-} == "--asan" ]]; then
  extra=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
# shellcheck disable=SC2046
g++ -std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "${extra[@]}" -I"$here/src" -I"$here/.." \
  "-DSTORE_FIXTURES=\"$root/tests/fixtures/store\"" $(pkg-config --cflags Qt6Core Qt6Network zlib) \
  "$here"/src/*.cpp "$root"/tests/unit/store/tst_*.cpp \
  $(pkg-config --libs Qt6Core Qt6Network zlib) -lgtest -lgtest_main -pthread -o "$out/store-unit-tests$suffix"
echo "built $out/store-unit-tests$suffix"
