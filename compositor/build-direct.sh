#!/usr/bin/env bash
# Interim build of grassfield-compositor without CMake/Ninja (not installed yet; see README.md).
# Writes the same outputs as the CMake build: build/grassfield-compositor.so and build/grassfield-compositor-tests.
# Usage: compositor/build-direct.sh [plugin|tests|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
what=${1:-all}

if [[ $what == plugin || $what == all ]]; then
  # Lua symbols are resolved at load time from Hyprland's own liblua (5.5): only Lua's headers are needed.
  g++ -std=c++23 -O2 -g -DNDEBUG -shared -fPIC -Wall -Wextra \
    src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/core/Protocol.cpp src/core/TitlebarLayout.cpp \
    $(pkg-config --cflags --libs hyprland pixman-1 libdrm) $(pkg-config --cflags lua) \
    -o build/grassfield-compositor.so
fi

if [[ $what == tests || $what == all ]]; then
  # Pure logic only (src/core): no Hyprland headers, no compositor needed.
  g++ -std=c++23 -O0 -g -Wall -Wextra -Isrc \
    tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp src/core/Protocol.cpp src/core/TitlebarLayout.cpp \
    $(pkg-config --cflags --libs gtest_main) \
    -o build/grassfield-compositor-tests
fi
