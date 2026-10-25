#!/usr/bin/env bash
# GF-015 / D-2: the login screen leads into Grassfield, Omarchy stays reachable, and a check reports when that stops
# being true. packaging/bin/grassfield-login and grassfield-login-check against a fixture root (no SDDM, no session).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/login.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
pk=$root/packaging

# A fixture root: the files Omarchy and Grassfield install.
fx=$tmp/root
mkdir -p "$fx/usr/share/wayland-sessions" "$fx/usr/local/share/wayland-sessions" "$fx/etc/sddm.conf.d" \
  "$fx/usr/share/grassfield/sddm/wayland-sessions" "$fx/usr/lib/grassfield" "$fx/usr/share/sddm/themes/omarchy" "$fx/usr/lib/sddm/sddm.conf.d"
cp "$pk/wayland-sessions/grassfield.desktop" "$fx/usr/share/wayland-sessions/"
cp "$pk/sddm/grassfield-login.desktop" "$fx/usr/share/grassfield/sddm/wayland-sessions/"
cp "$pk/bin/grassfield-login" "$fx/usr/lib/grassfield/"
cat >"$fx/usr/local/share/wayland-sessions/omarchy.desktop" <<'EOF'
[Desktop Entry]
Name=Omarchy (Hyprland uwsm)
Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop
Type=Application
EOF
# Omarchy's own SDDM files as they are on a stock install (theme heuristic, autologin).
cp /usr/share/sddm/themes/omarchy/Main.qml "$fx/usr/share/sddm/themes/omarchy/Main.qml" 2>/dev/null ||
  printf 'property int sessionIndex: { if (name.indexOf("uwsm") !== -1) return i }\n' >"$fx/usr/share/sddm/themes/omarchy/Main.qml"
printf '[Theme]\nCurrent=omarchy\n' >"$fx/etc/sddm.conf.d/99-omarchy-login.conf"
printf '[Autologin]\nUser=someone\nSession=omarchy.desktop\n' >"$fx/etc/sddm.conf.d/autologin.conf"
cp "$pk/sddm/grassfield.conf" "$fx/etc/sddm.conf.d/grassfield.conf"

login() { HOME=$tmp/home XDG_CONFIG_HOME=$tmp/home/.config GRASSFIELD_LOGIN_ROOT=$fx GRASSFIELD_LOGIN_DRY_RUN=1 sh "$pk/bin/grassfield-login" "$@"; }
mkdir -p "$tmp/home"

desc="default choice is Grassfield: the login starts the Grassfield session's Exec line"
out=$(login)
check test "$out" = "$(sed -n 's/^Exec=//p' "$pk/wayland-sessions/grassfield.desktop")"
desc="set omarchy: the next login starts Omarchy's own, unmodified session line"
login set omarchy >/dev/null
out=$(login)
check test "$out" = "uwsm start -g -1 -e -D Hyprland hyprland.desktop"
desc="get reports the choice; set grassfield switches back"
check test "$(login get)" = omarchy
login set grassfield >/dev/null
check test "$(login get)" = grassfield
desc="a garbage value in the choice file means Grassfield"
printf 'rm -rf /\n' >"$tmp/home/.config/grassfield/login-session"
check test "$(login get)" = grassfield
desc="set refuses an unknown session"
status=0; login set windows >/dev/null 2>&1 || status=$?
check test "$status" = 2
desc="Omarchy chosen but not installed: Grassfield starts (never a dead login)"
login set omarchy >/dev/null; rm "$fx/usr/local/share/wayland-sessions/omarchy.desktop"
out=$(login)
check test "$out" = "$(sed -n 's/^Exec=//p' "$pk/wayland-sessions/grassfield.desktop")"

desc="the SDDM drop-in sorts after Omarchy's autologin.conf and 99-omarchy-login.conf (later files win)"
check bash -c 'first=$(printf "%s\n" autologin.conf 99-omarchy-login.conf 10-theme.conf 10-wayland.conf grassfield.conf | LC_ALL=C sort | tail -n 1); [[ $first == grassfield.conf ]]'
desc="the drop-in lists the Grassfield login directory first, keeps Omarchy's, and sets the autologin session"
check bash -c 'grep -qx "SessionDir=/usr/share/grassfield/sddm/wayland-sessions,/usr/local/share/wayland-sessions,/usr/share/wayland-sessions" "$1" && grep -qx "Session=grassfield-login.desktop" "$1"' _ "$pk/sddm/grassfield.conf"
desc="the login entry's name contains uwsm (Omarchy's theme picks the first such session) and it runs the launcher"
check bash -c 'grep -q "^Name=.*uwsm" "$1" && grep -qx "Exec=/usr/lib/grassfield/grassfield-login" "$1"' _ "$pk/sddm/grassfield-login.desktop"

export GRASSFIELD_LOGIN_SDDM_START=
chk() { GRASSFIELD_LOGIN_ROOT=$fx sh "$pk/bin/grassfield-login-check" "$@"; }
mkdir -p "$tmp/fakebin"; printf '#!/bin/sh\n' >"$tmp/fakebin/uwsm"; chmod +x "$tmp/fakebin/uwsm"
desc="login-check on a good install: no warning, exit 0 even with --strict"
out=$(PATH="$tmp/fakebin:$PATH" chk --strict); status=$?
check bash -c '! grep -q "^WARN" <<<"$1" && grep -q "a boot (autologin) starts Grassfield" <<<"$1" && grep -q "first listed session named" <<<"$1"' _ "$out"
desc="login-check warns when the SDDM daemon started before the drop-in (reboot once), not when it started after"
touch -d '2026-01-02 00:00:00' "$fx/etc/sddm.conf.d/grassfield.conf"
st=$(date -d '2026-01-01 00:00:00' +%s)
out=$(GRASSFIELD_LOGIN_SDDM_START=$st PATH="$tmp/fakebin:$PATH" chk)
check bash -c 'grep -q "^WARN: SDDM has been running since before the drop-in.*restart the computer once" <<<"$1"' _ "$out"
out=$(GRASSFIELD_LOGIN_SDDM_START=$((st + 200000)) PATH="$tmp/fakebin:$PATH" chk)
check bash -c '! grep -q "since before the drop-in" <<<"$1"' _ "$out"
out=$(GRASSFIELD_LOGIN_SDDM_START= PATH="$tmp/fakebin:$PATH" chk)
check bash -c '! grep -q "since before the drop-in" <<<"$1"' _ "$out"
desc="login-check warns when another SDDM file takes over SessionDir or the autologin session"
printf '[Wayland]\nSessionDir=/usr/share/wayland-sessions\n' >"$fx/etc/sddm.conf.d/zz-other.conf"
out=$(PATH="$tmp/fakebin:$PATH" chk)
check bash -c 'grep -q "^WARN: another SDDM file overrides SessionDir" <<<"$1"' _ "$out"
status=0; PATH="$tmp/fakebin:$PATH" chk --strict >/dev/null || status=$?
check test "$status" = 1
rm "$fx/etc/sddm.conf.d/zz-other.conf"
printf '[Autologin]\nSession=omarchy.desktop\n' >"$fx/etc/sddm.conf.d/zz-autologin.conf"
out=$(PATH="$tmp/fakebin:$PATH" chk)
check bash -c 'grep -q "^WARN: autologin starts .omarchy.desktop" <<<"$1"' _ "$out"
rm "$fx/etc/sddm.conf.d/zz-autologin.conf"
desc="login-check warns when the greeter theme changed in a way it does not know"
printf 'import QtQuick 2.0\nRectangle {}\n' >"$fx/usr/share/sddm/themes/omarchy/Main.qml"
out=$(PATH="$tmp/fakebin:$PATH" chk)
check bash -c 'grep -q "^WARN: theme .omarchy. selects sessions" <<<"$1"' _ "$out"
desc="login-check warns when the drop-in is missing (login starts Omarchy)"
rm "$fx/etc/sddm.conf.d/grassfield.conf"
out=$(PATH="$tmp/fakebin:$PATH" chk)
check bash -c 'grep -q "^WARN: /etc/sddm.conf.d/grassfield.conf is missing" <<<"$1"' _ "$out"

if [[ -r /usr/share/sddm/themes/omarchy/Main.qml ]]; then
  desc="the installed Omarchy theme still uses the heuristic Grassfield relies on (indexOf uwsm)"
  check grep -q 'indexOf("uwsm")' /usr/share/sddm/themes/omarchy/Main.qml
else
  echo "SKIP: the Omarchy SDDM theme is not installed here"
fi

exit $fail
