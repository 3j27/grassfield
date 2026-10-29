#!/usr/bin/env bash
# An X11 override-redirect window (what an XWayland app's menu is) for the NESTED dev compositor only (tests/tools/x11menu).
# Usage (through the isolation helper, like every test client): scripts/dev/isolated.sh tests/tools/x11menu/x11menu.sh DISPLAY X Y W H
#   DISPLAY  the nested Hyprland's own X display (its children's $DISPLAY, read through its exec_cmd as
#            tests/compositor/click_focus.sh does); the caller's own DISPLAY (the owner's session) is refused.
# Builds the tool into .dev/tools/ on first use. Refuses unless this tree's verified nested compositor is live
# (dev_nested_target). Build only: tests/tools/x11menu/x11menu.sh --build
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
src=$root/tests/tools/x11menu
bin=$dev/tools/x11menu

if [[ ! -x $bin || $src/x11menu.c -nt $bin ]]; then
  mkdir -p "$dev/tools"
  # shellcheck disable=SC2046
  gcc -std=gnu11 -O1 -Wall -Wextra "$src/x11menu.c" $(pkg-config --cflags --libs x11) -o "$bin"
fi
[[ ${1:-} == --build ]] && exit 0

[[ $# -eq 5 ]] || { echo "usage: x11menu.sh DISPLAY X Y W H" >&2; exit 2; }
display=$1
shift
[[ $display =~ ^:[0-9]+$ ]] || { echo "x11menu: '$display' is not a local X display" >&2; exit 2; }
[[ $display != "${DISPLAY:-}" ]] || { echo "x11menu: refusing the caller's own X display $display (the owner's session)" >&2; exit 2; }
# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 1
DISPLAY=$display exec "$bin" "$@"
