#!/usr/bin/env bash
# Scripted keyboard input for the NESTED dev compositor only (tests/tools/vkbd). Run it bare.
# Usage: vkbd.sh down Super_L tap Tab sleep 300 up Super_L
# Builds the tool into .dev/tools/ on first use. Refuses anything but this tree's verified nested socket
# (dev_nested_target: live recorded compositor running this tree's dev config, listed by Hyprland with that socket;
# never the owner's instance or WAYLAND_DISPLAY). Never type into a nested lock screen.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
src=$root/tests/tools/vkbd
bin=$dev/tools/vkbd

# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 1
sock=$DEV_NESTED_SOCK

if [[ ! -x $bin || $src/vkbd.c -nt $bin || $src/virtual-keyboard-unstable-v1.xml -nt $bin ]]; then
  mkdir -p "$dev/tools"
  wayland-scanner client-header "$src/virtual-keyboard-unstable-v1.xml" "$dev/tools/virtual-keyboard-unstable-v1-client-protocol.h"
  wayland-scanner private-code "$src/virtual-keyboard-unstable-v1.xml" "$dev/tools/virtual-keyboard-unstable-v1-protocol.c"
  # shellcheck disable=SC2046
  gcc -std=gnu11 -O1 -Wall -Wextra -I"$dev/tools" "$src/vkbd.c" "$dev/tools/virtual-keyboard-unstable-v1-protocol.c" \
    $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$bin"
fi

WAYLAND_DISPLAY=$sock exec "$bin" "$@"
