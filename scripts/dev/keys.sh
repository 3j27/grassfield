#!/usr/bin/env bash
# Keyboard input for the NESTED dev compositor only (wraps wtype). Never reaches the owner's session.
# Usage: keys.sh 'text to type'            keys.sh -k Escape            keys.sh -M ctrl -k F3 -m ctrl
# All arguments are passed to wtype; WAYLAND_DISPLAY is always forced to the nested socket.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sock ]] || { echo "keys: no nested instance (run: just nested-up)" >&2; exit 1; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "keys: refusing the main Wayland socket" >&2; exit 1; }
[[ $(cat "$dev/nested.instance") != "$main" ]] || { echo "keys: refusing the main instance" >&2; exit 1; }
[[ -S ${XDG_RUNTIME_DIR:?}/$sock ]] || { echo "keys: nested socket $sock is gone" >&2; exit 1; }

WAYLAND_DISPLAY=$sock exec wtype "$@"
