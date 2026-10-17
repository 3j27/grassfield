#!/usr/bin/env bash
# (Re)start grassfield-shell inside the nested instance only. Never against the owner's session (R3).
#
# GRASSFIELD_PRIVATE_BUS=1: run the shell on its own D-Bus session bus (dbus-run-session) so that it
# can own org.freedesktop.Notifications without touching the owner's session. The bus address is
# written to .dev/bus.address for test clients (notify-send, busctl --user).
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
  # The shell runs as a session leader (setsid): signal its whole group so that a private-bus
  # wrapper (dbus-run-session) does not leave an orphaned qs behind.
  kill -- "-$(<"$dev/shell.pid")" 2>/dev/null || kill "$(<"$dev/shell.pid")" 2>/dev/null || true
  sleep 0.5
fi

launch=(qs -p "$root/shell" --log-times --no-color)
private=""
rm -f "$dev/bus.address"
if [[ ${GRASSFIELD_PRIVATE_BUS:-} == 1 ]]; then
  command -v dbus-run-session >/dev/null || { echo "shell-run: dbus-run-session not found" >&2; exit 1; }
  launch=(dbus-run-session -- sh -c 'printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" > "$1/bus.address"; shift; exec "$@"' sh "$dev" "${launch[@]}")
  private=1
fi

# Grassfield Settings built by apps/settings/build-direct.sh (menu item "System Settings…" in dev).
settings_cmd=${GRASSFIELD_SETTINGS_CMD:-}
[[ -z $settings_cmd && -x $dev/build/grassfield-settings ]] && settings_cmd=$dev/build/grassfield-settings

# Grassfield Preview built by apps/preview/build-direct.sh (Space on a desktop icon opens Glance in dev).
preview_cmd=${GRASSFIELD_PREVIEW_CMD:-}
[[ -z $preview_cmd && -x $dev/build/grassfield-preview ]] && preview_cmd=$dev/build/grassfield-preview

# GRASSFIELD_RENDER_TIMING=1: opt-in Qt scene graph render timing (QSG_RENDER_TIMING) in the shell log.
timing=()
[[ ${GRASSFIELD_RENDER_TIMING:-} == 1 ]] && timing=(QSG_RENDER_TIMING=1)

# Grassfield.I18n (ui/i18n) and the compiled catalogs (scripts/dev/i18n-build.sh), rebuilt when stale.
"$root/ui/i18n/build-direct.sh" >&2
"$root/scripts/dev/i18n-build.sh" >&2

# Desktop icons: the folder is a sandbox in dev (never the owner's real desktop); an exported
# GRASSFIELD_DESKTOP_DIR wins.
desktop_dir=${GRASSFIELD_DESKTOP_DIR:-$dev/desktop-sandbox}

env "${timing[@]}" GRASSFIELD_DESKTOP_DIR="$desktop_dir" WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
  GRASSFIELD_STATE_HOME="$dev/state" GRASSFIELD_CONFIG_HOME="$dev/config" GRASSFIELD_DEV=1 \
  GRASSFIELD_PRIVATE_BUS="$private" GRASSFIELD_SETTINGS_CMD="$settings_cmd" GRASSFIELD_PREVIEW_CMD="$preview_cmd" \
  QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$root/ui:$dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" \
  setsid "${launch[@]}" >"$dev/shell.log" 2>&1 </dev/null &
printf '%s\n' "$!" > "$dev/shell.pid"
echo "shell-run: grassfield-shell pid $! (log .dev/shell.log${private:+, private bus: .dev/bus.address})"
