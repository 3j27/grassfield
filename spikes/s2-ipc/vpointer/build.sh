#!/usr/bin/env bash
# S2 spike (throwaway): builds spikes/s2-ipc/out/vpointer (out/ is gitignored).
# Usage (nested only): WAYLAND_DISPLAY=<nested socket> spikes/s2-ipc/out/vpointer extent W H abs X Y click
set -euo pipefail
cd "$(dirname "$0")"
out=../out
mkdir -p "$out"
xml=wlr-virtual-pointer-unstable-v1.xml
wayland-scanner client-header "$xml" "$out/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$out/wlr-virtual-pointer-unstable-v1-protocol.c"
gcc -std=c11 -O1 -Wall -Wextra -I"$out" vpointer.c "$out/wlr-virtual-pointer-unstable-v1-protocol.c" \
  $(pkg-config --cflags --libs wayland-client) -o "$out/vpointer"
