#!/usr/bin/env bash
# (Re)start grassfield-shell inside the nested instance only. Never against the owner's session (R3).
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sig && -n $sock ]] || { echo "shell-run: no nested instance (run: just nested-up)" >&2; exit 1; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] \
  || { echo "shell-run: refusing to target the main instance" >&2; exit 1; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "shell-run: refusing the main Wayland socket" >&2; exit 1; }

if [[ -s $dev/shell.pid ]] && kill -0 "$(<"$dev/shell.pid")" 2>/dev/null; then
  kill "$(<"$dev/shell.pid")" 2>/dev/null || true
  sleep 0.3
fi

env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
  GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
  QT_QPA_PLATFORM=wayland \
  setsid qs -p "$root/shell" --log-times --no-color >"$dev/shell.log" 2>&1 </dev/null &
printf '%s\n' "$!" > "$dev/shell.pid"
echo "shell-run: grassfield-shell pid $! (log .dev/shell.log)"
