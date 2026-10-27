#!/usr/bin/env bash
# The Settings portal backend (ADR-0035 D-4, D-8, step 2b) with the real xdg-desktop-portal frontend.
# Static (always): the session's routing file lists only Settings (grassfield-settings, then gtk); the .portal file, the D-Bus
# service file and the unit name the same bus name and program; the unit is Type=dbus, restarts on failure, clears
# GTK_USE_PORTAL and QT_QPA_PLATFORMTHEME and is hardened; the shell's unit clears GTK_USE_PORTAL; env-grassfield, on scratch
# copies of its paths, puts the routing directory first in XDG_DATA_DIRS once (keeping the list, or the default), sets
# GTK_USE_PORTAL=1 and adds portals to GDK_DEBUG once (keeping its flags), and does nothing when the file is unreadable; the
# PKGBUILD builds and installs every piece.
# Runtime, on a private bus of the test's own (its own configuration and service directory, the frontend under env -i with a
# scratch HOME, XDG_CURRENT_DESKTOP=Hyprland and the package's routing directory first in XDG_DATA_DIRS; the backend started by
# D-Bus activation as a dev session reading a scratch grassfield.json; a stand-in for x-d-p-gtk; never the owner's bus):
#  1 ReadAll and ReadOne through the frontend: Grassfield's values win over gtk's (color-scheme, gtk-theme), gtk still
#    answers the keys Grassfield does not own (font-name), the accent colour is the token's, the namespace filter holds; the
#    frontend keeps the stock routing for every other interface; the backend stays within its memory budget (ADR-0035
#    decision 2b-11: 4 MB private, 20 MB resident with the shared libraries)
#  2 a change of grassfield.json reaches a client as SettingChanged, only for the keys that changed; when x-d-p-gtk signals
#    a dconf change of keys Grassfield owns, the client still ends with Grassfield's values (and gets gtk's own keys)
#  3 the backend killed: the frontend's next read starts it again by D-Bus activation and gets Grassfield's values, and the
#    new process signals the next change; killed again, a change made while it is down reaches the client as soon as it is
#    started again without any read (as systemd's Restart=on-failure starts it)
#  4 without the backend, the frontend answers from gtk alone, at once
#  5 the backend starts, owning its name, with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers
#  6 refused outside a Grassfield session, and as a dev run on a bus that is not a private test bus
#  7 on a headless Wayland compositor (Weston), with the variables env-grassfield sets: a GTK 3 app, a GTK 4 app and a
#    libadwaita app take their theme, colour scheme, contrast and accent from the portal, and follow a change of
#    grassfield.json (light, orange, Increase Contrast) within a second; a GTK 4 app without GDK_DEBUG=portals does not (why the session sets it). SKIP without weston or the GTK 3,
#    GTK 4 and libadwaita introspection data.
# Needs dbus-daemon, python3 with PyGObject, /usr/lib/xdg-desktop-portal, and g++ with the Qt 6 D-Bus headers (or
# GRASSFIELD_PORTAL_SETTINGS: a built backend); the runtime part SKIPs without them, and when libdbus cannot reach the bus.
# Scenario 7 also needs weston, GTK 3, GTK 4 and libadwaita with their introspection data, and SKIPs without them.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/portal-settings.XXXXXX")
bus_pid="" frontend_pid=""
stop_bus() {
  [[ -n $frontend_pid ]] && kill "$frontend_pid" 2>/dev/null && wait "$frontend_pid" 2>/dev/null
  frontend_pid=""
  # dbus-daemon leads its own process group (setsid): the services it activated are in it too.
  [[ -n $bus_pid ]] && kill -TERM -- "-$bus_pid" 2>/dev/null
  [[ -n $bus_pid ]] && wait "$bus_pid" 2>/dev/null
  bus_pid=""
}
stop_all() { stop_bus; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }
pk=$root/packaging
name=org.freedesktop.impl.portal.desktop.grassfield_settings
unit=$pk/systemd/grassfield-portal-settings.service

# --- static ------------------------------------------------------------------------------------------------------------
desc="the session's routing lists only Settings: Grassfield first, then gtk"
check test "$(grep -v '^#' "$pk/xdg/xdg-desktop-portal/hyprland-portals.conf" | grep -v '^$' | tr '\n' ' ')" = \
  "[preferred] org.freedesktop.impl.portal.Settings=grassfield-settings;gtk "
desc="the .portal file, the D-Bus service file and the unit name the same bus name and program"
check bash -c 'grep -qx "DBusName=$1" "$2" && grep -qx "Interfaces=org.freedesktop.impl.portal.Settings;" "$2" && grep -qx "Name=$1" "$3" &&
  grep -qx "Exec=/usr/lib/grassfield/grassfield-portal-settings" "$3" && grep -qx "SystemdService=grassfield-portal-settings.service" "$3" &&
  grep -qx "BusName=$1" "$4" && grep -qx "ExecStart=/usr/lib/grassfield/grassfield-portal-settings" "$4"' _ "$name" \
  "$pk/xdg/xdg-desktop-portal/portals/grassfield-settings.portal" "$pk/dbus/$name.service" "$unit"
desc="the unit: Type=dbus, restarts after 1 s, only in the Grassfield session, clears GTK_USE_PORTAL and QT_QPA_PLATFORMTHEME, hardened"
check bash -c 'for l in Type=dbus Restart=on-failure RestartSec=1 ConditionEnvironment=GRASSFIELD_SESSION=1 \
  "UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME" NoNewPrivileges=yes ProtectSystem=strict ProtectHome=read-only \
  PrivateNetwork=yes RestrictAddressFamilies=AF_UNIX; do grep -qx "$l" "$1" || { echo "missing: $l"; exit 1; }; done' _ "$unit"
desc="the shell's unit clears GTK_USE_PORTAL (its start never waits on the portal, gate P5)"
check grep -qx "UnsetEnvironment=GTK_USE_PORTAL" "$pk/systemd/grassfield-shell.service"
desc="the PKGBUILD builds and installs the backend, its unit, routing, .portal and service files, and the generated themes"
check bash -c 'grep -q "cmake --install \"\$srcdir/portal-settings-build\"" "$1" && grep -q "for unit in .*portal-settings" "$1" &&
  grep -q "usr/share/grassfield/xdg/xdg-desktop-portal/hyprland-portals.conf" "$1" &&
  grep -q "usr/share/grassfield/xdg/xdg-desktop-portal/portals/grassfield-settings.portal" "$1" &&
  grep -q "usr/share/dbus-1/services/$2.service" "$1" && grep -q "gen-gtk-themes.py\" \"\$srcdir/gtk-themes\"" "$1" &&
  grep -q "\$pkgdir/usr/share/themes/" "$1" && grep -q "xdg-desktop-portal xdg-desktop-portal-gtk)" "$1"' _ "$pk/arch/PKGBUILD" "$name"

# The real env file, its paths rewritten to a scratch copy.
mkdir -p "$tmp/gf/xdg-desktop-portal"
sed "s|/usr/share/grassfield/xdg|$tmp/gf|g" "$pk/uwsm/env-grassfield" >"$tmp/env"
envof() { # envof [XDG_DATA_DIRS before] [twice] [GDK_DEBUG before]: "XDG_DATA_DIRS|GTK_USE_PORTAL|GDK_DEBUG" after sourcing
  env -i PATH="$PATH" ${1:+XDG_DATA_DIRS="$1"} ${3:+GDK_DEBUG="$3"} sh -c '. "$1"; [ "${2-}" = twice ] && . "$1"; printf "%s|%s|%s" "${XDG_DATA_DIRS-unset}" "${GTK_USE_PORTAL-unset}" "${GDK_DEBUG-unset}"' \
    _ "$tmp/env" "${2-}"
}
desc="env-grassfield: no routing file readable, nothing set"
check test "$(envof)" = "unset|unset|unset"
cp "$pk/xdg/xdg-desktop-portal/hyprland-portals.conf" "$tmp/gf/xdg-desktop-portal/"
desc="env-grassfield: the routing directory first, then the default data directories; GTK_USE_PORTAL=1, GDK_DEBUG=portals"
check test "$(envof)" = "$tmp/gf:/usr/local/share:/usr/share|1|portals"
desc="env-grassfield: an existing XDG_DATA_DIRS is kept after it, and sourced twice it appears once"
check test "$(envof /usr/share:/opt/share twice)" = "$tmp/gf:/usr/share:/opt/share|1|portals"
desc="env-grassfield: GDK_DEBUG keeps the flags it has, and gets portals once"
check test "$(envof "" twice "events" | cut -d'|' -f3)" = "events,portals"
# The shell's unit clears GTK_USE_PORTAL for the shell (gate P5); the apps it starts get it back (review of step 2b).
desc="env-grassfield records GRASSFIELD_APPS_GTK_USE_PORTAL=1 for the shell, and the shell's launch environment gives GTK_USE_PORTAL back"
check bash -c '[[ $(env -i PATH="$PATH" sh -c ". \"\$1\"; echo \"\${GRASSFIELD_APPS_GTK_USE_PORTAL-unset}\"" _ "$1") == 1 ]] &&
  ! grep -q GRASSFIELD_APPS_GTK_USE_PORTAL "$2" &&
  grep -qF "AppLaunch.portalEnvironment(Quickshell.env(\"GRASSFIELD_APPS_GTK_USE_PORTAL\"))" "$3" &&
  grep -qF "AppLaunch.mergeEnvironment(devSession ? AppLaunch.isolatedEnvironment(appsHome) : ({}), portalEnvironment)" "$3"' _ \
  "$tmp/env" "$pk/systemd/grassfield-shell.service" "$root/shell/services/Apps.qml"

# --- runtime -----------------------------------------------------------------------------------------------------------
frontend=/usr/lib/xdg-desktop-portal
for tool in dbus-daemon python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: portal_settings needs $tool (runtime part)"; exit "$fail"; }
done
[[ -x $frontend ]] || { echo "SKIP: portal_settings needs xdg-desktop-portal ($frontend; runtime part)"; exit "$fail"; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { echo "SKIP: portal_settings needs PyGObject"; exit "$fail"; }
backend=${GRASSFIELD_PORTAL_SETTINGS:-}
if [[ -z $backend ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6DBus 2>/dev/null || { echo "SKIP: portal_settings needs g++ and the Qt 6 D-Bus headers"; exit "$fail"; }
  "$root/apps/portal-settings/build-direct.sh" --out "$tmp/bin" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: the backend builds"; exit 1; }
  backend=$tmp/bin/grassfield-portal-settings
fi
client=$root/tests/fixtures/portal-client.py
fakes=$root/tests/fixtures/fake-portal-backend.py

bus_conf() { # bus_conf <dir> <listen address> <auth mechanism>
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>$2</listen>" "  <auth>$3</auth>"
  [[ $3 == ANONYMOUS ]] && printf '%s\n' '  <allow_anonymous/>'
  printf '%s\n' "  <servicedir>$1/services</servicedir>" '  <policy context="default">' \
    '    <allow send_destination="*" eavesdrop="true"/>' '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' \
    '</busconfig>'
}
start_bus() { # start_bus <dir>: sets bus and bus_pid
  bus_conf "$1" "unix:path=$1/bus.sock" EXTERNAL >"$1/bus.conf"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  if wait_until 3 test -s "$1/bus.address"; then bus=$(head -n 1 "$1/bus.address"); return 0; fi
  kill "$bus_pid" 2>/dev/null; wait "$bus_pid" 2>/dev/null; bus_pid=""
  bus_conf "$1" "tcp:host=127.0.0.1,port=0" ANONYMOUS >"$1/bus.conf"
  : >"$1/bus.address"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$1/bus.address" || return 1
  bus=$(head -n 1 "$1/bus.address")
}
has() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
import sys
from gi.repository import Gio, GLib
c = Gio.bus_get_sync(Gio.BusType.SESSION)
print(c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                  GLib.Variant("(s)", (sys.argv[1],)), None, Gio.DBusCallFlags.NONE, 3000, None).unpack()[0])' "$1" 2>/dev/null; }
owned() { [[ $(has "$1") == True ]]; }
unowned() { ! owned "$1"; }
call() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" "$@"; }
start_service() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
import sys
from gi.repository import Gio, GLib
Gio.bus_get_sync(Gio.BusType.SESSION).call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "StartServiceByName", GLib.Variant("(su)", (sys.argv[1], 0)), None, Gio.DBusCallFlags.NONE, 5000, None)' "$1"; }
settings() { # settings <dir> <json>: grassfield.json, replaced atomically as the Settings app writes it
  printf '%s\n' "$2" >"$1/config/grassfield.json.new" && mv -f "$1/config/grassfield.json.new" "$1/config/grassfield.json"
}
# One scenario: a fresh bus whose service directory starts the Grassfield backend (when GRASSFIELD is yes) and the gtk
# stand-in on demand, then the real frontend. Sets d.
scenario() { # scenario <name> <yes|no>
  d=$tmp/$1
  mkdir -p "$d/services" "$d/config" "$d/home" "$d/run" "$d/cfg" "$d/xdg"
  chmod 700 "$d/run"
  cp -r "$pk/xdg/." "$d/xdg/"
  printf '#!/bin/sh\necho $$ >%s/gtk.pid\nexport GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)"\nexec python3 -I %s gtk --log %s/gtk.log\n' \
    "$d" "$d" "$d" "$fakes" "$d" >"$d/gtk.sh"
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.gtk\nExec=%s/gtk.sh\n' "$d" >"$d/services/gtk.service"
  if [[ $2 == yes ]]; then
    printf '#!/bin/sh\necho started >>%s/backend.starts\necho $$ >%s/backend.pid\nexec env -i PATH="$PATH" HOME=%s/home DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)" GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s GRASSFIELD_DEV=1 GRASSFIELD_CONFIG_HOME=%s/config GRASSFIELD_PORTAL_SETTINGS_CLOCK=12:00 %s\n' \
      "$d" "$d" "$d" "$d" "$d" "$d" "$backend" >"$d/backend.sh"
    printf '[D-BUS Service]\nName=%s\nExec=%s/backend.sh\n' "$name" "$d" >"$d/services/grassfield.service"
  fi
  chmod 755 "$d"/*.sh
  settings "$d" '{"appearance": "dark"}'
  start_bus "$d" || { echo "bus: $(head -n 1 "$d/bus.log")"; return 1; }
  env -i PATH="$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_DATA_HOME="$d/home/.local/share" XDG_RUNTIME_DIR="$d/run" \
    XDG_DATA_DIRS="$d/xdg:/usr/share" XDG_CURRENT_DESKTOP=Hyprland DBUS_SESSION_BUS_ADDRESS="$bus" "$frontend" -v -r >"$d/frontend.log" 2>&1 &
  frontend_pid=$!
  wait_until 10 owned org.freedesktop.portal.Desktop
}
# The backend this scenario started (its PID from backend.sh), killed; never any other process of that name.
kill_backend() { kill -KILL "$(cat "$d/backend.pid")" 2>/dev/null; wait_until 5 unowned "$name"; }
value() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(eval(sys.argv[1], {}, {"d": d})))' "$1"; }

# Preflight: libdbus reaches a private bus.
mkdir -p "$tmp/pre/services"
if ! start_bus "$tmp/pre"; then desc="a private bus starts [$(head -n 1 "$tmp/pre/bus.log")]"; check false; exit 1; fi
if ! pre=$(DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c 'from gi.repository import Gio; Gio.bus_get_sync(Gio.BusType.SESSION)' 2>&1); then
  echo "SKIP: portal_settings: this environment gives no way to a private bus (${pre%%$'\n'*})"; exit "$fail"
fi
stop_bus

# 1 --------------------------------------------------------------------------------------------------------------------
scenario values yes || exit 1
all=$(call read-all)
got=$(value '[d["org.freedesktop.appearance"]["color-scheme"], d["org.gnome.desktop.interface"]["gtk-theme"], d["org.gnome.desktop.interface"]["font-name"]]' <<<"$all")
desc="1 ReadAll through the frontend: Grassfield's color-scheme and gtk-theme win over gtk's, gtk answers font-name [$got]"
check test "$got" = '[1, "Grassfield-multicolor-dark", "Inter 10"]'
got=$(value '[d["org.freedesktop.appearance"][k] for k in ("accent-color", "contrast", "reduced-motion")]' <<<"$all")
desc="1 the accent colour is the token's (multicolor, dark: #4FB36B), with contrast and reduced-motion 0 [$got]"
check test "$got" = '[[0.3098, 0.702, 0.4196], 0, 0]'
desc="1 the backend was started by D-Bus activation at the frontend's first read"
check test "$(wc -l <"$d/backend.starts" 2>/dev/null)" = 1
got="$(call read-one org.freedesktop.appearance color-scheme) $(call read-all 'org.gnome.*' | value 'sorted(d)')"
desc="1 ReadOne and the namespace filter [$got]"
check test "$got" = '1 ["org.gnome.desktop.interface"]'
got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.[A-Za-z]+ \((default )?config\)" "$d/frontend.log" | sort -u | tr '\n' ';')
desc="1 the session's file routes Settings only: every other interface keeps the stock routing (FileChooser, Screenshot) [$got]"
check bash -c '[[ $1 == *"Using grassfield-settings.portal for org.freedesktop.impl.portal.Settings (config)"* &&
  $1 == *"org.freedesktop.impl.portal.FileChooser (default config)"* && $1 == *"org.freedesktop.impl.portal.Screenshot (default config)"* &&
  $(grep -o "[A-Za-z]* (config)" <<<"$1" | sort -u | tr "\n" " ") == "Settings (config) " ]]' _ "$got"
read -r rss anon < <(awk '/^VmRSS:/ { r = $2 } /^RssAnon:/ { a = $2 } END { print r, a }' "/proc/$(cat "$d/backend.pid")/status" 2>/dev/null)
desc="1 the backend's memory is within its budget (private <= 4 MB, resident <= 20 MB) [private ${anon:-?} kB, resident ${rss:-?} kB]"
check bash -c '[[ -n $1 && -n $2 && $1 -le 4096 && $2 -le 20480 ]]' _ "$anon" "$rss"

# 2 --------------------------------------------------------------------------------------------------------------------
: >"$d/signals"
DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" watch "$d/signals" 30 >"$d/watch.out" 2>&1 &
watcher=$!
wait_until 5 test -s "$d/watch.out"
settings "$d" '{"appearance": "light", "accent": {"color": "orange"}}'
wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-orange"' "$d/signals"
sleep 0.5
keys=$(python3 -I -c 'import json,sys; print(" ".join(sorted("%s/%s" % (j["ns"].split(".")[-1], j["key"]) for j in map(json.loads, open(sys.argv[1])))))' "$d/signals")
desc="2 a change of grassfield.json reaches the client as SettingChanged, for the keys that changed only [$keys]"
check test "$keys" = "appearance/accent-color appearance/color-scheme interface/color-scheme interface/gtk-theme"
desc="2 the frontend then answers the new values [$(call read-one org.gnome.desktop.interface gtk-theme)]"
check test "$(call read-one org.gnome.desktop.interface gtk-theme)" = '"Grassfield-orange"'
# x-d-p-gtk signals a dconf change (a theme tool): the frontend passes it on, and the backend answers with its own values.
: >"$d/signals"
kill -USR1 "$(cat "$d/gtk.pid")"
wait_until 5 grep -q '"font-name"' "$d/signals"
sleep 0.5
got=$(python3 -I -c '
import json, sys
last = {}
for j in map(json.loads, open(sys.argv[1])):
    last[j["key"] if j["ns"].endswith("interface") or j["key"] != "color-scheme" else "appearance-color-scheme"] = j["value"]
print(json.dumps([last.get("gtk-theme"), last.get("appearance-color-scheme"), last.get("font-name")]))' "$d/signals")
desc="2 after x-d-p-gtk signals gtk-theme, color-scheme and font-name, the client ends with Grassfield's two and gtk's font [$got]"
check test "$got" = '["Grassfield-orange", 2, "Cantarell 11"]'

# 3 --------------------------------------------------------------------------------------------------------------------
kill_backend
got="$(call read-one org.gnome.desktop.interface gtk-theme) $(wc -l <"$d/backend.starts")"
desc="3 the backend killed: the frontend's next read starts it again and answers Grassfield's values [$got]"
check test "$got" = '"Grassfield-orange" 2'
: >"$d/signals"
settings "$d" '{"appearance": "light", "accent": {"color": "purple"}}'
desc="3 ... and the new process signals the next change to the client"
check wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-purple"' "$d/signals"
kill_backend
: >"$d/signals"
settings "$d" '{"appearance": "light", "accent": {"color": "red"}}'
sleep 0.3
start_service "$name"
desc="3 killed again, a change made while it is down reaches the client once it starts, with no read [$(wc -l <"$d/backend.starts") starts]"
check wait_until 5 grep -q '"gtk-theme", "value": "Grassfield-red"' "$d/signals"
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
stop_bus

# 4 --------------------------------------------------------------------------------------------------------------------
scenario absent no || exit 1
start=$(date +%s%N)
theme=$(call read-one org.gnome.desktop.interface gtk-theme)
ms=$((($(date +%s%N) - start) / 1000000))
desc="4 without the backend the frontend answers from gtk alone, at once [$theme, $ms ms]"
check bash -c '[[ $1 == "\"Adwaita-dark\"" && $2 -lt 3000 ]]' _ "$theme" "$ms"
stop_bus

# 5 --------------------------------------------------------------------------------------------------------------------
d=$tmp/silent
mkdir -p "$d/services" "$d/config" "$d/home"
start_bus "$d" || exit 1
setsid env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" DBUS_SESSION_BUS_ADDRESS="$bus" python3 -I "$fakes" silent-frontend >"$d/fake.log" 2>&1 &
wait_until 5 owned org.freedesktop.portal.Desktop
env -i PATH="$PATH" HOME="$d/home" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" GRASSFIELD_DEV=1 \
  GRASSFIELD_CONFIG_HOME="$d/config" GTK_USE_PORTAL=1 QT_QPA_PLATFORMTHEME=gtk3 timeout 20 "$backend" >"$d/backend.log" 2>&1 &
direct=$!
started=$(date +%s%N)
wait_until 5 owned "$name"
ms=$((($(date +%s%N) - started) / 1000000))
desc="5 with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers, the backend owns its name at once [$ms ms]"
check test "$ms" -lt 3000
kill "$direct" 2>/dev/null; wait "$direct" 2>/dev/null
stop_bus

# 6 --------------------------------------------------------------------------------------------------------------------
out=$(env -i PATH="$PATH" HOME="$tmp" "$backend" 2>&1); rc=$?
desc="6 refused outside a Grassfield session (exit 2) [$rc: $out]"
check bash -c '[[ $1 == 2 && $2 == *"refused: not a Grassfield session"* ]]' _ "$rc" "$out"
for bad in "unix:path=/run/user/$(id -u)/bus" "unix:path=$tmp/x/../../run/user/$(id -u)/bus"; do
  out=$(env -i PATH="$PATH" HOME="$tmp" GRASSFIELD_DEV=1 GF_TEST_BUS=1 GF_TEST_BUS_DIR="$tmp/x" DBUS_SESSION_BUS_ADDRESS="$bad" \
    timeout 5 "$backend" 2>&1); rc=$?
  desc="6 a dev run on $bad (not under the test's directory) is refused (exit 2) [$rc: $out]"
  check bash -c '[[ $1 == 2 && $2 == *"refused: a dev session runs it only on a private test bus"* ]]' _ "$rc" "$out"
done

# 7 --------------------------------------------------------------------------------------------------------------------
typelib() { python3 -I -c 'import gi, importlib, sys; gi.require_version(sys.argv[1], sys.argv[2]); importlib.import_module("gi.repository." + sys.argv[1])' "$@" 2>/dev/null; }
if ! command -v weston >/dev/null || ! typelib Gtk 3.0 || ! typelib Gtk 4.0 || ! typelib Adw 1; then
  echo "SKIP: portal_settings: scenario 7 needs weston and the GTK 3, GTK 4 and libadwaita introspection data"
  exit "$fail"
fi
scenario live yes || exit 1
mkdir -p "$d/share/themes"
python3 -I "$root/ui/tools/gen-gtk-themes.py" "$d/share/themes" >/dev/null
env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" weston --backend=headless --socket=wl-portal-test --no-config \
  >"$d/weston.log" 2>&1 &
weston_pid=$!
wait_until 5 test -S "$d/run/wl-portal-test"
# What the session sets, from the real env-grassfield (the static part's scratch copy, routing file present).
IFS='|' read -r _ gtk_use_portal gdk_debug <<<"$(envof)"
toolkit() { # toolkit <3|4|adw> <log> [GDK_DEBUG]: a watcher on the Weston display, the test's bus and the generated themes
  env -i PATH="$PATH" HOME="$d/home" XDG_RUNTIME_DIR="$d/run" WAYLAND_DISPLAY=wl-portal-test GDK_BACKEND=wayland NO_AT_BRIDGE=1 \
    DBUS_SESSION_BUS_ADDRESS="$bus" XDG_DATA_DIRS="$d/share:/usr/share" GTK_USE_PORTAL="$gtk_use_portal" ${3:+GDK_DEBUG="$3"} \
    python3 -I "$root/tests/fixtures/toolkit-watch.py" "$1" 15 >"$2" 2>"$2.err" &
}
toolkit 3 "$d/gtk3" "$gdk_debug"
toolkit 4 "$d/gtk4" "$gdk_debug"
toolkit adw "$d/adw" "$gdk_debug"
toolkit 4 "$d/gtk4-plain"
wait_until 10 bash -c 'for f in gtk3 gtk4 adw gtk4-plain; do [[ -s $1/$f ]] || exit 1; done' _ "$d"
sleep 1
changed_at=$(date +%s.%N)
settings "$d" '{"appearance": "light", "accent": {"color": "orange"}, "accessibility": {"increaseContrast": true}}'
wait_until 5 bash -c 'grep -q orange-hc "$1/gtk3" && grep -q orange-hc "$1/gtk4" && grep -q "\"dark\": false, \"hc\": true, \"accent\": \"orange\"" "$1/adw"' _ "$d"
sleep 0.5
# "<first state> -> <last state> <seconds from the change to the last state>" (-1 when nothing changed)
states() { python3 -I -c '
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
keys = [k for k in lines[0] if k != "at"]
state = lambda l: ",".join(str(l[k]) for k in keys)
print(state(lines[0]), "->", state(lines[-1]), "%.2f" % (lines[-1]["at"] - float(sys.argv[2]) if len(lines) > 1 else -1))' "$1" "$changed_at" 2>&1; }
prompt() { awk -v t="${1##* }" 'BEGIN { exit !(t >= 0 && t < 1) }'; }
got=$(states "$d/gtk3")
desc="7 a GTK 3 app (GTK_USE_PORTAL=$gtk_use_portal) takes the Grassfield theme from the portal and follows the change [$got]"
check bash -c '[[ $1 == "Grassfield-multicolor-dark -> Grassfield-orange-hc "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/gtk4")
desc="7 a GTK 4 app (GDK_DEBUG=$gdk_debug) takes the theme and the colour scheme, and follows the change [$got]"
check bash -c '[[ $1 == "Grassfield-multicolor-dark,2 -> Grassfield-orange-hc,3 "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/adw")
desc="7 a libadwaita app goes from dark with green (multicolor's nearest) to light, high contrast, orange [$got]"
check bash -c '[[ $1 == "True,False,green -> False,True,orange "* ]]' _ "$got"
desc="7 ... within a second of the change"; check prompt "$got"
got=$(states "$d/gtk4-plain")
desc="7 control: a GTK 4 app without GDK_DEBUG=portals does not take the theme from the portal [$got]"
check bash -c '[[ $1 != *Grassfield-* ]]' _ "$got"
# A restart of the backend (every value announced again, decision 2b-9) leaves each app as it was.
before=$(for f in gtk3 gtk4 adw; do states "$d/$f" | awk '{ print $3 }'; done | tr '\n' ' ')
lines=$(wc -l "$d/gtk3" "$d/gtk4" "$d/adw" | awk 'NR <= 3 { print $1 }' | tr '\n' ' ')
starts=$(wc -l <"$d/backend.starts")
kill_backend
start_service "$name"
sleep 1
desc="7 the backend was killed and started again [starts $starts -> $(wc -l <"$d/backend.starts"), owned $(has "$name")]"
check bash -c '[[ $2 -eq $(($1 + 1)) && $3 == True ]]' _ "$starts" "$(wc -l <"$d/backend.starts")" "$(has "$name")"
after=$(for f in gtk3 gtk4 adw; do states "$d/$f" | awk '{ print $3 }'; done | tr '\n' ' ')
desc="7 a restart of the backend (every value announced again) leaves the apps as they were [$after; lines GTK 3, GTK 4, libadwaita: $lines-> $(wc -l "$d/gtk3" "$d/gtk4" "$d/adw" | awk 'NR <= 3 { print $1 }' | tr '\n' ' ')]"
check test "$before" = "$after"
kill "$weston_pid" 2>/dev/null; wait "$weston_pid" 2>/dev/null
stop_bus

exit "$fail"
