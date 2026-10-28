#!/usr/bin/env bash
# Direct build of grassfield-secrets-handover with g++ (see CMakeLists.txt). Output: .dev/build/grassfield-secrets-handover.
# Usage: apps/secrets-handover/build-direct.sh
#        apps/secrets-handover/build-direct.sh --tests            (the logic unit tests: .dev/build/secrets-handover-unit-tests)
#        apps/secrets-handover/build-direct.sh --tests --asan     (the same with -fsanitize=address,undefined)
#        apps/secrets-handover/build-direct.sh --out DIR          (the helper into DIR instead of .dev/build)
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

if ((tests)); then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" $(pkg-config --cflags Qt6Core Qt6DBus) \
    "$root/tests/unit/secrets-handover/tst_logic.cpp" "$here/src/peer.cpp" \
    $(pkg-config --libs Qt6Core Qt6DBus) -lgtest -lgtest_main -pthread \
    -o "$out/secrets-handover-unit-tests$suffix"
  echo "built $out/secrets-handover-unit-tests$suffix"
  exit 0
fi

gen=$(mktemp -d)
trap 'rm -rf "$gen"' EXIT
"$moc" "$here/src/handover.h" -o "$gen/moc_handover.cpp"
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$root/ui/i18n" $(pkg-config --cflags Qt6Core Qt6DBus) \
  "$here/src/main.cpp" "$here/src/handover.cpp" "$here/src/peer.cpp" "$gen/moc_handover.cpp" \
  $(pkg-config --libs Qt6Core Qt6DBus) -o "$out/grassfield-secrets-handover$suffix"
echo "built $out/grassfield-secrets-handover$suffix"
