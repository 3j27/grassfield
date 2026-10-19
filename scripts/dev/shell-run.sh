#!/usr/bin/env bash
# (Re)start grassfield-shell inside the nested instance only. Never against the owner's session (R3).
#
# Private D-Bus session bus (the default; --session-bus or GRASSFIELD_PRIVATE_BUS=0 keeps the owner's session bus for
# the rare test that needs it): the shell owns org.freedesktop.Notifications without touching the owner's session, and
# anything the bus activates (a D-Bus activatable handler, gvfs, portals) runs isolated: the bus daemon starts with the
# XDG_* homes under .dev/apps-home and GRASSFIELD_DEV=1 (ADR-0011). One dbus-daemon per nested
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
    --session-bus) export GRASSFIELD_PRIVATE_BUS=0 ;;
    --visual-fixtures) export GRASSFIELD_VISUAL_FIXTURES=1 ;;  # test hooks and fixed values (shell/services/VisualFixtures.qml, dev only)
    --render-timing) export GRASSFIELD_RENDER_TIMING=1 ;;  # Qt scene graph frame timing in .dev/shell.log (QSG_RENDER_TIMING)
    --lang) export GRASSFIELD_LANG=${2:?--lang needs a value}; shift ;;
    --desktop-dir) export GRASSFIELD_DESKTOP_DIR=${2:?--desktop-dir needs a path}; shift ;;
    --menu-bridge) export GRASSFIELD_MENU_BRIDGE=${2:?--menu-bridge needs a path}; shift ;;
    --desktop-screen) export GRASSFIELD_DESKTOP_SCREEN=${2:?--desktop-screen needs an output name}; shift ;;
    --cursor-theme) export GRASSFIELD_CURSOR_THEME=${2:?--cursor-theme needs a theme name}; shift ;;
    *) echo "shell-run: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
# X11 clients started from a dev session (the shell, the private bus, apps) must never reach the owner's X server
# (their Xwayland :0): no DISPLAY is passed on. X11-only apps do not start in dev sessions.
unset DISPLAY
dev=$root/.dev
# shellcheck source=pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# A record written inside the sandbox's PID namespace names another process on the host (incident 2026-10-18).
dev_require_host shell-run
# shellcheck source=devenv.sh
. "$root/scripts/dev/devenv.sh"
apps_home=$dev/apps-home
# Only this tree's live nested compositor: after a nested crash its socket name can be reused by another worktree's
# session, and a shell started there would take a session lock only the owner's password releases.
dev_nested_target "$dev" || exit 1
sig=$DEV_NESTED_SIG
sock=$DEV_NESTED_SOCK

# The shell runs as a session leader (setsid): its whole group stops, so that no orphaned qs stays behind. Only a record
# that still matches its process is signalled (scripts/dev/pidfile.sh).
dev_stop "$dev/shell.pid" grassfield-shell >/dev/null || exit 1

launch=(qs -p "$root/shell" --log-times --no-color)
private=""
bus_env=()
bridge_sock=""
if [[ ${GRASSFIELD_PRIVATE_BUS:-1} == 1 ]]; then
  command -v dbus-daemon >/dev/null || { echo "shell-run: dbus-daemon not found" >&2; exit 1; }
  mkdir -p "$dev/run"
  chmod 700 "$dev/run"
  # sockaddr_un.sun_path: 107 bytes for the bridge socket.
  ((${#dev} + 21 < 108)) || { echo "shell-run: $dev is too long for the bridge's Unix socket path" >&2; exit 1; }
  if ! { [[ -s $dev/bus.address ]] && dev_live_pid "$dev/bus.pid" >/dev/null; }; then
    dev_stop "$dev/bus.pid" "private D-Bus bus" >/dev/null || exit 1
    rm -f "$dev/bus.address" "$dev/bus.address.new"
    # Same configuration as dbus-run-session (session bus, service activation, unix:tmpdir=/tmp); activated
    # services inherit the nested Wayland socket, never the owner's.
    # The isolated homes make every activated service isolated too (ADR-0011).
    mkdir -p "$apps_home"/{config,cache,state,data,home}
    env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_DEV=1 HOME="$apps_home/home" \
      XDG_CONFIG_HOME="$apps_home/config" XDG_CACHE_HOME="$apps_home/cache" XDG_STATE_HOME="$apps_home/state" \
      XDG_DATA_HOME="$apps_home/data" \
      setsid dbus-daemon --session --nofork --print-address=1 \
      >"$dev/bus.address.new" 2>"$dev/bus.log" </dev/null &
    dev_record_pid "$dev/bus.pid" "$!"
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
  dev_stop "$dev/menu-bridge.pid" grassfield-menu-bridge >/dev/null || exit 1
  bridge=${GRASSFIELD_MENU_BRIDGE:-$dev/build/grassfield-menu-bridge}
  if [[ -x $bridge ]]; then
    bridge_sock=$dev/run/menu-bridge.sock
    env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
      setsid "$bridge" >"$dev/menu-bridge.log" 2>&1 </dev/null &
    dev_record_pid "$dev/menu-bridge.pid" "$!"
    for _ in $(seq 1 30); do [[ -S $bridge_sock ]] && break; sleep 0.1; done
    [[ -S $bridge_sock ]] || { echo "shell-run: grassfield-menu-bridge did not start (see .dev/menu-bridge.log)" >&2; bridge_sock=""; }
  else
    echo "shell-run: no menu bridge ($bridge; build it with bridges/menu-bridge/build-direct.sh): T0 menus only" >&2
  fi
else
  # Without a private bus there is no bridge: a leftover one would serve the wrong shell.
  dev_stop "$dev/menu-bridge.pid" grassfield-menu-bridge >/dev/null || exit 1
fi

# Grassfield Settings built by apps/settings/build-direct.sh (menu item "System Settings…" in dev).
settings_cmd=${GRASSFIELD_SETTINGS_CMD:-}
[[ -z $settings_cmd && -x $dev/build/grassfield-settings ]] && settings_cmd=$dev/build/grassfield-settings

# Grassfield Preview built by apps/preview/build-direct.sh (Space on a desktop icon opens Glance in dev).
preview_cmd=${GRASSFIELD_PREVIEW_CMD:-}
[[ -z $preview_cmd && -x $dev/build/grassfield-preview ]] && preview_cmd=$dev/build/grassfield-preview

# Grassfield Files built by apps/files/build-direct.sh (the dev open policy opens folders in it, scripts/dev/open-policy.sh).
files_cmd=${GRASSFIELD_FILES_CMD:-}
[[ -z $files_cmd && -x $dev/build/grassfield-files ]] && files_cmd=$dev/build/grassfield-files

# Apps started from the shell in dev (System Settings, Glance) run through the isolating helper: XDG_* under .dev/,
# GRASSFIELD_*_HOME shared with this shell (the command is split on spaces by the shell; .dev paths have none).
isolate=("$root/scripts/dev/isolated.sh" --name shell --config-home "$dev/config" --state-home "$dev/state" --)
[[ -n $settings_cmd ]] && settings_cmd="${isolate[*]} $settings_cmd"
[[ -n $preview_cmd ]] && preview_cmd="${isolate[*]} $preview_cmd"
[[ -n $files_cmd ]] && files_cmd="${isolate[*]} $files_cmd"
# Dev open policy: the shell never asks GIO or xdg-open to start an app (ADR-0011). One refusal line per refused open.
open_policy=$root/scripts/dev/open-policy.sh
open_log=$dev/open-policy.log
# Optional plocate database for the Search file provider (a test database of a sandbox folder, never the owner's files):
# .dev/plocate.db when present (updatedb --database-root DIR --output .dev/plocate.db --require-visibility no).
plocate_db=""
[[ -s $dev/plocate.db ]] && plocate_db=$dev/plocate.db

# --render-timing (GRASSFIELD_RENDER_TIMING=1): opt-in Qt scene graph render timing (QSG_RENDER_TIMING) in the shell log.
# Only this start of the shell has it: a start without the option is quiet again.
timing=()
[[ ${GRASSFIELD_RENDER_TIMING:-} == 1 ]] && timing=(QSG_RENDER_TIMING=1)

# Grassfield.I18n (ui/i18n) and the compiled catalogs (scripts/dev/i18n-build.sh), rebuilt when stale.
"$root/ui/i18n/build-direct.sh" >&2
"$root/scripts/dev/i18n-build.sh" >&2

# The isolated trash of the dev session (shell/services/Trash.qml watches it; ADR-0011): the shell's "Move to Trash"
# and the Dock's Trash drop put files here, never in the owner's ~/.local/share/Trash.
mkdir -p "$dev/apps-home/data/Trash/files" "$dev/apps-home/data/Trash/info" "$dev/apps-home/home"

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
# The dev Dock pins only foot (when dock.pinned is absent): a mis-click or a test's coordinate click on a pinned tile
# then starts a terminal, never a browser or a file manager on the owner's profile/home (incidents 2026-10-17/18).
if jq -e '.dock.pinned == null' "$cfg" >/dev/null 2>&1; then
  jq '.dock.pinned = ["foot"]' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
fi

# The open shims (gio, xdg-open, gtk-launch -> open-policy.sh) come first on the shell's PATH: QProcess resolves a program
# on the PATH of its parent, so code that runs `gio open` in a Process (shell/desktop/DesktopFiles.qml) gets the policy too.
env "${timing[@]}" "${bus_env[@]}" PATH="$root/scripts/dev/open-shims:$PATH" GRASSFIELD_MENU_BRIDGE_SOCKET="$bridge_sock" \
  GRASSFIELD_DESKTOP_DIR="$desktop_dir" WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
  GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
  GRASSFIELD_PRIVATE_BUS="$private" GRASSFIELD_SETTINGS_CMD="$settings_cmd" GRASSFIELD_PREVIEW_CMD="$preview_cmd" \
  GRASSFIELD_FILES_CMD="$files_cmd" GRASSFIELD_OPEN_POLICY="$open_policy" GRASSFIELD_OPEN_LOG="$open_log" \
  GRASSFIELD_SEARCH_PLOCATE_DB="$plocate_db" GRASSFIELD_CURSORS_BUILD="$root/branding/cursors/build.sh" \
  GRASSFIELD_CURSORS_ICONS="$dev/share/icons" \
  QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "${launch[@]}" >"$dev/shell.log" 2>&1 </dev/null &
shell_pid=$!
dev_record_pid "$dev/shell.pid" "$shell_pid"
echo "shell-run: grassfield-shell pid $shell_pid (log .dev/shell.log${private:+, private bus: .dev/bus.address}${bridge_sock:+, menu bridge: .dev/menu-bridge.log})"
