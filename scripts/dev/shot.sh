#!/usr/bin/env bash
# Capture the nested output with grim (wlr-screencopy on the nested compositor only).
# Usage: shot.sh <name> [output]  → .dev/shots/<name>.png
# Default output: GF-REF, the 1920x1080 headless reference output created by config/hypr/dev.lua.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
name=${1:?usage: shot.sh <name> [output]}
output=${2:-GF-REF}
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# Only this tree's live nested compositor (never the owner's output, never another worktree's session).
dev_nested_target "$dev" || exit 1
sock=$DEV_NESTED_SOCK

mkdir -p "$dev/shots"
out=$dev/shots/$name.png
WAYLAND_DISPLAY=$sock grim -o "$output" "$out"
echo "$out"
