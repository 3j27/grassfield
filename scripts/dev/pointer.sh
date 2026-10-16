#!/usr/bin/env bash
# Scripted pointer input for the NESTED dev compositor only (tests/tools/vpointer).
# Usage: pointer.sh output GF-REF abs 960 1050 sleep 300 click
#        pointer.sh outputs
# Builds the tool into .dev/tools/ on first use. Refuses to run against the owner's Wayland socket.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
src=$root/tests/tools/vpointer
bin=$dev/tools/vpointer

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ -n $sock ]] || { echo "pointer: no nested instance (run: just nested-up)" >&2; exit 1; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "pointer: refusing the main Wayland socket" >&2; exit 1; }
[[ $(cat "$dev/nested.instance") != "$main" ]] || { echo "pointer: refusing the main instance" >&2; exit 1; }

if [[ ! -x $bin || $src/vpointer.c -nt $bin ]]; then
  mkdir -p "$dev/tools"
  wayland-scanner client-header "$src/wlr-virtual-pointer-unstable-v1.xml" "$dev/tools/wlr-virtual-pointer-unstable-v1-client-protocol.h"
  wayland-scanner private-code "$src/wlr-virtual-pointer-unstable-v1.xml" "$dev/tools/wlr-virtual-pointer-unstable-v1-protocol.c"
  xdg=/usr/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml
  wayland-scanner client-header "$xdg" "$dev/tools/xdg-output-unstable-v1-client-protocol.h"
  wayland-scanner private-code "$xdg" "$dev/tools/xdg-output-unstable-v1-protocol.c"
  cflags=$(pkg-config --cflags --libs wayland-client)
  # shellcheck disable=SC2086
  gcc -std=c11 -O1 -Wall -Wextra -I"$dev/tools" "$src/vpointer.c" \
    "$dev/tools/wlr-virtual-pointer-unstable-v1-protocol.c" "$dev/tools/xdg-output-unstable-v1-protocol.c" \
    $cflags -o "$bin"
fi

WAYLAND_DISPLAY=$sock exec "$bin" "$@"
