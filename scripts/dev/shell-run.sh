#!/usr/bin/env bash
# (Re)start grassfield-shell inside the nested instance only. Never against the owner's session (R3).
#
# GRASSFIELD_PRIVATE_BUS=1 (--private-bus): run the shell on a private D-Bus session bus so that it can
# own org.freedesktop.Notifications without touching the owner's session. One dbus-daemon per nested
# session (session configuration, socket in /tmp as with dbus-run-session: libdbus caps socket paths at
# 99 bytes, too short for .dev/ in a worktree), started by the first shell start and reused by shell restarts, so
# applications on it keep their connection as on a real session bus; nested-down.sh stops it. The
# address is in .dev/bus.address for test clients (notify-send, busctl --address, test apps).
#
# Global menus (ADR-0008): with the private bus, grassfield-menu-bridge (.dev/build/grassfield-menu-bridge
# from bridges/menu-bridge/build-direct.sh, or GRASSFIELD_MENU_BRIDGE) is (re)started on that bus before
# the shell and before any test app: socket .dev/run/menu-bridge.sock, log .dev/menu-bridge.log. It owns
# com.canonical.AppMenu.Registrar only after the shell's hello reports the plugin's appmenu feature. It is
# NEVER started on the owner's session bus (no private bus: no bridge; the bridge refuses that bus too).
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# Same options as nested-up.sh (bare commands match the sandbox exclusion; env prefixes may not).
while [[ $# -gt 0 ]]; do
  case $1 in
    --private-bus) export GRASSFIELD_PRIVATE_BUS=1 ;;
    --lang) export GRASSFIELD_LANG=${2:?--lang needs a value}; shift ;;
    --desktop-dir) export GRASSFIELD_DESKTOP_DIR=${2:?--desktop-dir needs a path}; shift ;;
    --menu-bridge) export GRASSFIELD_MENU_BRIDGE=${2:?--menu-bridge needs a path}; shift ;;
    --desktop-screen) export GRASSFIELD_DESKTOP_SCREEN=${2:?--desktop-screen needs an output name}; shift ;;
    *) echo "shell-run: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sig && -n $sock ]] || { echo "shell-run: no nested instance (run: just nested-up)" >&2; exit 1; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] \
  || { echo "shell-run: refusing to target the main instance" >&2; exit 1; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "shell-run: refusing the main Wayland socket" >&2; exit 1; }

if [[ -s $dev/shell.pid ]] && kill -0 "$(<"$dev/shell.pid")" 2>/dev/null; then
  # The shell runs as a session leader (setsid): signal its whole group so that a private-bus
  # wrapper (dbus-run-session) does not leave an orphaned qs behind.
  kill -- "-$(<"$dev/shell.pid")" 2>/dev/null || kill "$(<"$dev/shell.pid")" 2>/dev/null || true
  sleep 0.5
fi

# Stops a process started here with setsid (its PID is its process group) and removes its pidfile.
stop_group() { # <pidfile>
  [[ -s $1 ]] || { rm -f "$1"; return 0; }
  local pid
  pid=$(<"$1")
  if kill -0 "$pid" 2>/dev/null; then
    local target=$pid
    [[ $(ps -o pgid= -p "$pid" | tr -d ' ') == "$pid" ]] && target=-$pid
    kill -- "$target" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -9 -- "$target" 2>/dev/null
  fi
  rm -f "$1"
}

launch=(qs -p "$root/shell" --log-times --no-color)
private=""
bus_env=()
bridge_sock=""
if [[ ${GRASSFIELD_PRIVATE_BUS:-} == 1 ]]; then
  command -v dbus-daemon >/dev/null || { echo "shell-run: dbus-daemon not found" >&2; exit 1; }
  mkdir -p "$dev/run"
  chmod 700 "$dev/run"
  # sockaddr_un.sun_path: 107 bytes for the bridge socket.
  ((${#dev} + 21 < 108)) || { echo "shell-run: $dev is too long for the bridge's Unix socket path" >&2; exit 1; }
  if ! { [[ -s $dev/bus.pid && -s $dev/bus.address ]] && kill -0 "$(<"$dev/bus.pid")" 2>/dev/null; }; then
    stop_group "$dev/bus.pid"
    rm -f "$dev/bus.address" "$dev/bus.address.new"
    # Same configuration as dbus-run-session (session bus, service activation, unix:tmpdir=/tmp); activated
    # services inherit the nested Wayland socket, never the owner's.
    env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_DEV=1 \
      setsid dbus-daemon --session --nofork --print-address=1 \
      >"$dev/bus.address.new" 2>"$dev/bus.log" </dev/null &
    printf '%s\n' "$!" >"$dev/bus.pid"
    for _ in $(seq 1 50); do [[ -s $dev/bus.address.new ]] && break; sleep 0.1; done
    [[ -s $dev/bus.address.new ]] || { echo "shell-run: the private bus did not start (see .dev/bus.log)" >&2; exit 1; }
    head -n 1 "$dev/bus.address.new" >"$dev/bus.address"
    rm -f "$dev/bus.address.new"
  fi
  bus=$(<"$dev/bus.address")
  case $bus in
    unix:path=/tmp/dbus-*) ;;
    *) echo "shell-run: refusing: unexpected private bus address $bus" >&2; exit 1 ;;
  esac
  bus_env=(DBUS_SESSION_BUS_ADDRESS="$bus")
  private=1

  # grassfield-menu-bridge on the private bus, (re)started with the shell.
  stop_group "$dev/menu-bridge.pid"
  bridge=${GRASSFIELD_MENU_BRIDGE:-$dev/build/grassfield-menu-bridge}
  if [[ -x $bridge ]]; then
    bridge_sock=$dev/run/menu-bridge.sock
    env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
      setsid "$bridge" >"$dev/menu-bridge.log" 2>&1 </dev/null &
    printf '%s\n' "$!" >"$dev/menu-bridge.pid"
    for _ in $(seq 1 30); do [[ -S $bridge_sock ]] && break; sleep 0.1; done
    [[ -S $bridge_sock ]] || { echo "shell-run: grassfield-menu-bridge did not start (see .dev/menu-bridge.log)" >&2; bridge_sock=""; }
  else
    echo "shell-run: no menu bridge ($bridge; build it with bridges/menu-bridge/build-direct.sh): T0 menus only" >&2
  fi
else
  # Without a private bus there is no bridge: a leftover one would serve the wrong shell.
  stop_group "$dev/menu-bridge.pid"
fi

# Grassfield Settings built by apps/settings/build-direct.sh (menu item "System Settings…" in dev).
settings_cmd=${GRASSFIELD_SETTINGS_CMD:-}
[[ -z $settings_cmd && -x $dev/build/grassfield-settings ]] && settings_cmd=$dev/build/grassfield-settings

# Grassfield Preview built by apps/preview/build-direct.sh (Space on a desktop icon opens Glance in dev).
preview_cmd=${GRASSFIELD_PREVIEW_CMD:-}
[[ -z $preview_cmd && -x $dev/build/grassfield-preview ]] && preview_cmd=$dev/build/grassfield-preview

# Apps started from the shell in dev (System Settings, Glance) run through the isolating helper: XDG_* under .dev/,
# GRASSFIELD_*_HOME shared with this shell (the command is split on spaces by the shell; .dev paths have none).
isolate=("$root/scripts/dev/isolated.sh" --name shell --config-home "$dev/config" --state-home "$dev/state" --)
[[ -n $settings_cmd ]] && settings_cmd="${isolate[*]} $settings_cmd"
[[ -n $preview_cmd ]] && preview_cmd="${isolate[*]} $preview_cmd"

# GRASSFIELD_RENDER_TIMING=1: opt-in Qt scene graph render timing (QSG_RENDER_TIMING) in the shell log.
timing=()
[[ ${GRASSFIELD_RENDER_TIMING:-} == 1 ]] && timing=(QSG_RENDER_TIMING=1)

# Grassfield.I18n (ui/i18n) and the compiled catalogs (scripts/dev/i18n-build.sh), rebuilt when stale.
"$root/ui/i18n/build-direct.sh" >&2
"$root/scripts/dev/i18n-build.sh" >&2

# Desktop icons: the folder is a sandbox in dev (never the owner's real desktop); an exported
# GRASSFIELD_DESKTOP_DIR wins.
desktop_dir=${GRASSFIELD_DESKTOP_DIR:-$dev/desktop-sandbox}

# Dev sessions never idle-lock (only the owner's password unlocks the nested lock screen): seed
# lock.idleMinutes: 0 ("never", shell/security/idle/IdleModel.js) in the DEV config when the key is absent.
# An existing value is kept. The shell's defaults and production code are untouched.
cfg=$dev/config/grassfield.json
mkdir -p "$dev/config"
if [[ ! -s $cfg ]]; then
  printf '{\n  "version": 1,\n  "lock": {\n    "idleMinutes": 0\n  }\n}\n' >"$cfg"
elif jq -e '.lock.idleMinutes == null' "$cfg" >/dev/null 2>&1; then
  jq '.lock.idleMinutes = 0' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
fi

env "${timing[@]}" "${bus_env[@]}" GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
  GRASSFIELD_DESKTOP_DIR="$desktop_dir" WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
  GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
  GRASSFIELD_PRIVATE_BUS="$private" GRASSFIELD_SETTINGS_CMD="$settings_cmd" GRASSFIELD_PREVIEW_CMD="$preview_cmd" \
  QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "${launch[@]}" >"$dev/shell.log" 2>&1 </dev/null &
printf '%s\n' "$!" > "$dev/shell.pid"
echo "shell-run: grassfield-shell pid $! (log .dev/shell.log${private:+, private bus: .dev/bus.address}${bridge_sock:+, menu bridge: .dev/menu-bridge.log})"
