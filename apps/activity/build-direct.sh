#!/usr/bin/env bash
# Direct build of the activity monitor's sampler with g++ (see CMakeLists.txt; ADR-0038 step 1: no window yet).
# Usage: apps/activity/build-direct.sh --bench            (.dev/build/activity-sampler-bench)
#        apps/activity/build-direct.sh --tests            (.dev/build/activity-unit-tests)
#        apps/activity/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

cxxflags=(-std=c++17 -O2 -Wall -Wextra -fPIC)
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
sampler=("$here"/src/netdiag.cpp "$here"/src/procparse.cpp "$here"/src/sampler.cpp "$here"/src/textclean.cpp "$here"/src/units.cpp)

case ${1:-} in
  --tests)
    g++ "${cxxflags[@]}" -I"$here/src" "${sampler[@]}" "$root"/tests/unit/activity/tst_*.cpp \
      -lgtest -lgtest_main -pthread -o "$out/activity-unit-tests$suffix"
    echo "built $out/activity-unit-tests$suffix"
    ;;
  --bench)
    g++ "${cxxflags[@]}" -I"$here/src" "${sampler[@]}" "$here/src/bench.cpp" -pthread -o "$out/activity-sampler-bench$suffix"
    echo "built $out/activity-sampler-bench$suffix"
    ;;
  *)
    echo "usage: apps/activity/build-direct.sh --tests [--asan] | --bench [--asan]" >&2
    exit 2
    ;;
esac
