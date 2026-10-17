#!/usr/bin/env bash
# Interim build of grassfield-compositor without CMake/Ninja (not installed yet; see README.md).
# Writes the same outputs as the CMake build: build/grassfield-compositor.so, build/grassfield-compositor-tests
# and build/compile_commands.json (for clang-tidy, gate Q1).
# Usage: compositor/build-direct.sh [plugin|tests|compdb|all|tidy]   (default: all = plugin + tests + compdb)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
what=${1:-all}

core_srcs=(src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp src/core/Minimize.cpp)
plugin_srcs=(src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp "${core_srcs[@]}")
test_srcs=(tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp tests/MinimizeTest.cpp)

# Lua symbols are resolved at load time from Hyprland's own liblua (5.5): only Lua's headers are needed.
# shellcheck disable=SC2207
plugin_flags=(-std=c++23 -O2 -g -DNDEBUG -fPIC -Wall -Wextra $(pkg-config --cflags hyprland pixman-1 libdrm) $(pkg-config --cflags lua))
# shellcheck disable=SC2207
plugin_libs=($(pkg-config --libs hyprland pixman-1 libdrm))
# Pure logic only (src/core): no Hyprland headers, no compositor needed.
# shellcheck disable=SC2207
test_flags=(-std=c++23 -O0 -g -Wall -Wextra -Isrc $(pkg-config --cflags gtest_main))
# shellcheck disable=SC2207
test_libs=($(pkg-config --libs gtest_main))

if [[ $what == plugin || $what == all ]]; then
  g++ "${plugin_flags[@]}" -shared "${plugin_srcs[@]}" "${plugin_libs[@]}" -o build/grassfield-compositor.so
fi

if [[ $what == tests || $what == all ]]; then
  g++ "${test_flags[@]}" "${test_srcs[@]}" "${core_srcs[@]}" "${test_libs[@]}" -o build/grassfield-compositor-tests
fi

# One compile command per translation unit, with the exact flags used above.
if [[ $what == compdb || $what == all || $what == tidy ]]; then
  entry() { # <source> <flags...>   (arguments go through stdin: jq would parse "-std=..." as its own options)
    local src=$1
    shift
    printf '%s\n' g++ "$@" -c "$src" | jq -R . | jq -s --arg d "$PWD" --arg f "$PWD/$src" '{directory: $d, file: $f, arguments: .}'
  }
  {
    for src in src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp "${core_srcs[@]}"; do entry "$src" "${plugin_flags[@]}"; done
    for src in "${test_srcs[@]}"; do entry "$src" "${test_flags[@]}"; done
  } | jq -s . > build/compile_commands.json
fi

# Gate Q1: clang-tidy over the glue and the core (config: .clang-tidy; analyzer findings are errors).
if [[ $what == tidy ]]; then
  clang-tidy -p build --quiet src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp "${core_srcs[@]}" "${test_srcs[@]}"
fi
