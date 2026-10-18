#!/usr/bin/env bash
# Keyboard input for the NESTED dev compositor only (wraps wtype). Never reaches the owner's session.
# Usage: keys.sh 'text to type'            keys.sh -k Escape            keys.sh -M ctrl -k F3 -m ctrl
# All arguments are passed to wtype; WAYLAND_DISPLAY is always forced to the nested socket.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# Only this tree's live nested compositor: a stale socket record may name another worktree's session or be reused.
dev_nested_target "$dev" || exit 1

WAYLAND_DISPLAY=$DEV_NESTED_SOCK exec wtype "$@"
