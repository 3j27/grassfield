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

# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# Only this tree's live nested compositor: a stale socket record may name another worktree's session or be reused.
dev_nested_target "$dev" || exit 1
sock=$DEV_NESTED_SOCK

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
