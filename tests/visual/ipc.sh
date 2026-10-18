#!/usr/bin/env bash
# Quickshell IPC against the NESTED grassfield-shell only: ipc.sh <target> <function> [args...]
# e.g. tests/visual/ipc.sh menubar open controlcenter GF-REF
# The instance is selected by the shell's PID (.dev/shell.pid, written by scripts/dev/shell-run.sh), never by path.
# Refuses the owner's Wayland socket and Hyprland instance (same guards as scripts/dev/pointer.sh).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# Only this tree's live nested compositor and shell (records verified by start time).
dev_nested_target "$dev" || exit 1
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
pid=$(dev_live_pid "$dev/shell.pid") || { echo "ipc: no running nested shell (.dev/shell.pid)" >&2; exit 1; }
[[ $# -ge 2 ]] || { echo "usage: ipc.sh <target> <function> [args...]" >&2; exit 2; }

WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig exec qs ipc --pid "$pid" call "$@"
