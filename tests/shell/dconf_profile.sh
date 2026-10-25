#!/usr/bin/env bash
# ADR-0017 (spike I0.2 as a test): the Grassfield session dconf profile, in a scratch XDG_CONFIG_HOME and a scratch
# database compiled from packaging/dconf/grassfield.d. Every gsettings call runs under `env -i` with an explicit
# DCONF_PROFILE inside the scratch directory and a bus address that does not exist: the owner's dconf is never opened,
# nothing can be written (no D-Bus), and reads need none.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/dconf-profile.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
if ! command -v dconf >/dev/null || ! command -v gsettings >/dev/null || [[ ! -f /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml ]]; then
  echo "SKIP: dconf profile (dconf, gsettings or the org.gnome.desktop.interface schema missing)"
  exit 0
fi
mkdir -p "$tmp/xdg/dconf" "$tmp/home" "$tmp/userkf"
KEY=org.gnome.desktop.interface
dconf compile "$tmp/grassfield.db" "$root/packaging/dconf/grassfield.d"
# The packaged profile names /usr/share/grassfield/dconf/grassfield.db: the scratch copy names the scratch database.
sed "s|/usr/share/grassfield/dconf/grassfield.db|$tmp/grassfield.db|" "$root/packaging/dconf/profile" >"$tmp/profile"
printf '[org/gnome/desktop/interface]\nicon-theme='"'"'Yaru-blue'"'"'\ncolor-scheme='"'"'prefer-dark'"'"'\nmonospace-font-name='"'"'User Mono 9'"'"'\n' >"$tmp/userkf/00.conf"
dconf compile "$tmp/xdg/dconf/user" "$tmp/userkf"
g() { # PROFILE-or-unset, gsettings args...
  local p=$1; shift
  case $p in "$tmp"/* | /nonexistent/*) ;; "") ;; *) echo "refusing a profile outside the scratch dir: $p" >&2; return 99 ;; esac
  local pe=(); [[ -n $p ]] && pe=(DCONF_PROFILE="$p")
  env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" XDG_RUNTIME_DIR="$tmp" XDG_DATA_DIRS=/usr/share \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent "${pe[@]}" gsettings "$@" 2>/dev/null
}
desc="with the profile, icon-theme reads grassfield-icons although the user database says Yaru-blue"
check test "$(g "$tmp/profile" get $KEY icon-theme)" = "'grassfield-icons'"
desc="with the profile, icon-theme is not writable (locked)"
check test "$(g "$tmp/profile" writable $KEY icon-theme)" = false
desc="with the profile, setting icon-theme fails"
check bash -c '! "$@"' _ env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" XDG_RUNTIME_DIR="$tmp" \
  XDG_DATA_DIRS=/usr/share DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent DCONF_PROFILE="$tmp/profile" gsettings set $KEY icon-theme Adwaita
desc="with the profile, other keys still come from the user database and stay writable"
check test "$(g "$tmp/profile" get $KEY color-scheme)" = "'prefer-dark'" -a "$(g "$tmp/profile" writable $KEY color-scheme)" = true
desc="with the profile, the GTK font defaults are Inter 10, grayscale and slight"
check test "$(g "$tmp/profile" get $KEY font-name)" = "'Inter 10'" -a "$(g "$tmp/profile" get $KEY document-font-name)" = "'Inter 10'" \
  -a "$(g "$tmp/profile" get $KEY font-antialiasing)" = "'grayscale'" -a "$(g "$tmp/profile" get $KEY font-hinting)" = "'slight'"
desc="with the profile, the window buttons are close, minimize, zoom on the left (ADR-0002), a default the user can change"
check test "$(g "$tmp/profile" get org.gnome.desktop.wm.preferences button-layout)" = "'close,minimize,maximize:'" \
  -a "$(g "$tmp/profile" writable org.gnome.desktop.wm.preferences button-layout)" = true
desc="the dev environment (scripts/dev/devenv.sh) compiles the same defaults and exports a profile under .dev/dconf"
check bash -c 'grep -q "dconf compile \"\$_gf_dconf_tmp\" \"\$_gf_dev_root/packaging/dconf/grassfield.d\"" "$1" && grep -q "export DCONF_PROFILE=\$_gf_dconf/profile" "$1"' _ "$root/scripts/dev/devenv.sh"
desc="the font keys are defaults, not locks: still writable with the profile; monospace-font-name keeps the user value"
check test "$(g "$tmp/profile" writable $KEY font-name)" = true -a "$(g "$tmp/profile" writable $KEY font-hinting)" = true \
  -a "$(g "$tmp/profile" get $KEY monospace-font-name)" = "'User Mono 9'"
desc="without DCONF_PROFILE (the Omarchy session) the user's own icon-theme is read and writable"
check test "$(g "" get $KEY icon-theme)" = "'Yaru-blue'" -a "$(g "" writable $KEY icon-theme)" = true
# Recorded safety rule (spike I0): an unusable profile means dconf's null configuration (all defaults, user database
# ignored), so the env file must never export one that cannot be opened.
desc="a missing profile gives the null configuration (GTK defaults), hence the guard in env-grassfield"
check test "$(g /nonexistent/profile get $KEY color-scheme)" = "'default'"
desc="env-grassfield exports DCONF_PROFILE only behind a readability test of the profile and its database"
check bash -c 'grep -q "^if \[ -r /usr/share/grassfield/dconf/profile \] && \[ -r /usr/share/grassfield/dconf/grassfield.db \]; then" "$1" && grep -q "DCONF_PROFILE=/usr/share/grassfield/dconf/profile" "$1"' _ "$root/packaging/uwsm/env-grassfield"
desc="the icon database (00-icons.conf) holds only icon-theme, and only that key is locked (10-fonts.conf holds unlocked defaults)"
check bash -c '[ "$(grep -vc "^\[\|^$" "$1/00-icons.conf")" = 1 ] && [ "$(cat "$1/locks/icon-theme")" = /org/gnome/desktop/interface/icon-theme ]' _ "$root/packaging/dconf/grassfield.d"
desc="the packaged profile lists system-db:local between the user database and Grassfield's defaults (admin locks, GF-117)"
check test "$(grep -v '^#' "$root/packaging/dconf/profile" | tr '\n' ' ')" = "user-db:user system-db:local file-db:/usr/share/grassfield/dconf/grassfield.db "
exit "$fail"
