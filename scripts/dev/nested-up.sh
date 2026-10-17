#!/usr/bin/env bash
# Start the nested Grassfield dev compositor (master-prompt Appendix C2, §7.1 L1).
# All state lives in .dev/. The owner's main instance is recorded so scripts/nestctl can refuse it.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# Options (preferred over env prefixes: a bare `scripts/dev/nested-up.sh …` command matches the
# Claude Code sandbox exclusion, an `VAR=… scripts/dev/nested-up.sh` prefix may not).
while [[ $# -gt 0 ]]; do
  case $1 in
    --private-bus) export GRASSFIELD_PRIVATE_BUS=1 ;;
    --no-plugin) export GRASSFIELD_NO_PLUGIN=1 ;;
    --lang) export GRASSFIELD_LANG=${2:?--lang needs a value}; shift ;;
    --desktop-dir) export GRASSFIELD_DESKTOP_DIR=${2:?--desktop-dir needs a path}; shift ;;
    -h|--help) echo "usage: nested-up.sh [--private-bus] [--no-plugin] [--lang LL] [--desktop-dir PATH]"; exit 0 ;;
    *) echo "nested-up: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
mkdir -p "$dev/state" "$dev/config" "$dev/shots"

if [[ -s $dev/nested.pid ]] && kill -0 "$(<"$dev/nested.pid")" 2>/dev/null; then
  echo "nested-up: already running (pid $(<"$dev/nested.pid"), instance $(<"$dev/nested.instance"))"
  exit 0
fi

[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n ${WAYLAND_DISPLAY:-} ]] \
  || { echo "nested-up: must run inside a Hyprland session (HYPRLAND_INSTANCE_SIGNATURE/WAYLAND_DISPLAY unset)" >&2; exit 1; }

# 1. Record the owner's main instance.
printf '%s\n' "$HYPRLAND_INSTANCE_SIGNATURE" > "$dev/main.instance"

# Plugin to load at startup (C2: GRASSFIELD_NO_PLUGIN=1 starts without it).
plugin=${GRASSFIELD_PLUGIN:-$root/compositor/build/grassfield-compositor.so}
[[ -f $plugin && -z ${GRASSFIELD_NO_PLUGIN:-} ]] || plugin=""

# 2. Start Hyprland nested. Its children inherit the nested WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE.
env -u HYPRLAND_INSTANCE_SIGNATURE -u HYPRLAND_CMD \
  GRASSFIELD_CONFIG_DIR="$root/config/hypr" \
  GRASSFIELD_SHELL_DIR="$root/shell" \
  GRASSFIELD_STATE_HOME="$dev/state" \
  GRASSFIELD_CONFIG_HOME="$dev/config" \
  GRASSFIELD_DEV=1 \
  GRASSFIELD_PLUGIN="$plugin" \
  setsid Hyprland --config "$root/config/hypr/dev.lua" >"$dev/hyprland.log" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" > "$dev/nested.pid"

# 3. Wait for the new instance (matched by PID) and record its signature and Wayland socket.
sig="" sock=""
for _ in $(seq 1 100); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "nested-up: Hyprland exited early; see .dev/hyprland.log" >&2
    tail -n 20 "$dev/hyprland.log" >&2 || true
    rm -f "$dev/nested.pid"
    exit 1
  fi
  line=$(hyprctl instances -j | jq -r --argjson p "$pid" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
  if [[ -n $line ]]; then
    read -r sig sock <<<"$line"
    break
  fi
  sleep 0.1
done
[[ -n $sig ]] || { echo "nested-up: timed out waiting for the nested instance" >&2; exit 1; }
if [[ $sig == "$(<"$dev/main.instance")" ]]; then
  echo "nested-up: refusing: new instance equals the main instance" >&2
  exit 1
fi
printf '%s\n' "$sig" > "$dev/nested.instance"
printf '%s\n' "$sock" > "$dev/nested.wayland"
echo "nested-up: pid $pid, instance $sig, socket $sock, plugin ${plugin:-none}"

# 4. Start grassfield-shell against the nested instance, if it exists yet.
if [[ -f $root/shell/shell.qml ]]; then
  "$root/scripts/dev/shell-run.sh"
fi
