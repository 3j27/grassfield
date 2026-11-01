#!/usr/bin/env bash
# Direct build of grassfield-prompter and grassfield-askpass with g++ + pkg-config (same sources and flags as CMakeLists.txt).
# Output: .dev/build/grassfield-prompter and .dev/build/grassfield-askpass (or --out DIR)
# Usage: bridges/prompter/build-direct.sh [--out DIR]            the bridge and the askpass helper
#        bridges/prompter/build-direct.sh --tests [--asan]      the unit tests: .dev/build/prompter-unit-tests[-asan] (gtest;
#                                                                --asan: -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
tests=0
asan=0
while (($#)); do
  case $1 in
    --tests) tests=1 ;;
    --asan) asan=1 ;;
    --out) out=$2; shift ;;
    *) echo "usage: $0 [--out DIR] | --tests [--asan]" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++20 -O2 -g -Wall -Wextra -Wno-sfinae-incomplete -fPIC -DGCR_API_SUBJECT_TO_CHANGE -DQT_NO_KEYWORDS
  "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # VERSION: the one version source
logic=("$here/src/Text.cpp" "$here/src/Protocol.cpp" "$here/src/Requests.cpp" "$here/src/Peer.cpp" "$here/src/Identity.cpp"
  "$here/src/Filter.cpp" "$here/src/Prompt.cpp" "$here/src/Askpass.cpp")
pkgs=(Qt6Core gcr-4 gio-unix-2.0)

if ((tests)); then
  extra=()
  suffix=""
  if ((asan)); then
    extra=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    suffix="-asan"
  fi
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" "${extra[@]}" -I"$here/src" $(pkg-config --cflags "${pkgs[@]}") \
    "$root/tests/unit/prompter/tst_prompter.cpp" "${logic[@]}" \
    $(pkg-config --libs "${pkgs[@]}") -lgtest -pthread \
    -o "$out/prompter-unit-tests$suffix"
  echo "built $out/prompter-unit-tests$suffix"
  exit 0
fi

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$root/apps" $(pkg-config --cflags "${pkgs[@]}") \
  "$here/src/main.cpp" "$here/src/Bridge.cpp" "${logic[@]}" \
  $(pkg-config --libs "${pkgs[@]}") \
  -o "$out/grassfield-prompter"
echo "built $out/grassfield-prompter"
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" -I"$root/ui/i18n" $(pkg-config --cflags "${pkgs[@]}") \
  "$here/src/askpass.cpp" "$here/src/Askpass.cpp" "$here/src/Text.cpp" \
  $(pkg-config --libs "${pkgs[@]}") \
  -o "$out/grassfield-askpass"
echo "built $out/grassfield-askpass"
