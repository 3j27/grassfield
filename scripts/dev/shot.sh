#!/usr/bin/env bash
# Capture the nested output with grim (wlr-screencopy on the nested compositor only).
# Usage: shot.sh <name> [output]  → .dev/shots/<name>.png
# Default output: GF-REF, the 1920x1080 headless reference output created by config/hypr/dev.lua.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
name=${1:?usage: shot.sh <name> [output]}
output=${2:-GF-REF}
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
[[ -n $sock && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "shot: no nested instance" >&2; exit 1; }

mkdir -p "$dev/shots"
out=$dev/shots/$name.png
WAYLAND_DISPLAY=$sock grim -o "$output" "$out"
echo "$out"
