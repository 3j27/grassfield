#!/usr/bin/env bash
# Stop the nested shell, menu bridge, private bus and compositor started by nested-up.sh / shell-run.sh and
# remove their records.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
main=$(cat "$dev/main.instance" 2>/dev/null || true)

stop_pid() { # <pidfile> <name>
  [[ -s $1 ]] || return 0
  local pid
  pid=$(<"$1")
  if kill -0 "$pid" 2>/dev/null; then
    # Processes were started with setsid, so the PID is also the process group: stopping the group
    # also stops helpers (private dbus-run-session bus, activated portals, gio monitors).
    # Only signal a group this script's setsid created (group id == PID); otherwise just the PID.
    local target=$pid
    [[ $(ps -o pgid= -p "$pid" | tr -d ' ') == "$pid" ]] && target=-$pid
    kill -- "$target" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -9 -- "$target" 2>/dev/null
    echo "nested-down: stopped $2 (process group $pid)"
  fi
  rm -f "$1"
}

# Safety: never signal the owner's compositor even if the records were tampered with.
if [[ -s $dev/nested.pid ]]; then
  pid=$(<"$dev/nested.pid")
  owner_pid=$(hyprctl instances -j 2>/dev/null | jq -r --arg s "$main" '.[] | select(.instance == $s) | .pid')
  if [[ -n $owner_pid && $pid == "$owner_pid" ]]; then
    echo "nested-down: refusing: recorded PID is the owner's compositor" >&2
    exit 1
  fi
fi

stop_pid "$dev/shell.pid" grassfield-shell
# The menu bridge releases com.canonical.AppMenu.Registrar on SIGTERM, then the private bus goes (shell-run.sh).
stop_pid "$dev/menu-bridge.pid" grassfield-menu-bridge
stop_pid "$dev/bus.pid" "private D-Bus bus"
rm -f "$dev/bus.address" "$dev/run/menu-bridge.sock"
stop_pid "$dev/nested.pid" "nested Hyprland"
rm -f "$dev/nested.instance" "$dev/nested.wayland"
