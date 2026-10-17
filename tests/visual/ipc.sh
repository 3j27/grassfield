#!/usr/bin/env bash
# Quickshell IPC against the NESTED grassfield-shell only: ipc.sh <target> <function> [args...]
# e.g. tests/visual/ipc.sh menubar open controlcenter GF-REF
# Refuses the owner's Wayland socket and Hyprland instance (same guards as scripts/dev/pointer.sh).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dev=$root/.dev
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ -n $sock && -n $sig ]] || { echo "ipc: no nested instance (run: just nested-up)" >&2; exit 1; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "ipc: refusing the main Wayland socket" >&2; exit 1; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || { echo "ipc: refusing the main instance" >&2; exit 1; }
[[ $# -ge 2 ]] || { echo "usage: ipc.sh <target> <function> [args...]" >&2; exit 2; }

WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig exec qs ipc -p "$root/shell" call "$@"
