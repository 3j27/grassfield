#!/usr/bin/env bash
# grassfield-portal's Open and Save panels, Choose Application and permission alerts (ADR-0035 D-4, D-5, steps 4b, 5a and 5b;
# docs/specs/system-dialogs.md sections 1 and 2) with the real xdg-desktop-portal frontend.
# Static (always): the .portal file, the D-Bus service file and the unit name the same bus name and program and list
# FileChooser, Access and AppChooser; the unit is Type=dbus with no Restart (D-Bus activation starts it again), clears GTK_USE_PORTAL and
# QT_QPA_PLATFORMTHEME and is hardened; the PKGBUILD builds and installs every piece; the session's window rules give a panel's
# and an alert's xdg tags the client-chrome tag.
# Runtime, on a private bus of the test's own (the frontend under env -i with a scratch HOME, XDG_CURRENT_DESKTOP=Hyprland and
# the package's routing directory first in XDG_DATA_DIRS; the backend started by D-Bus activation as a dev session, offscreen,
# its panels answered by the dev hook GRASSFIELD_PORTAL_TEST_ANSWER; a stand-in for x-d-p-gtk; never the owner's bus):
#  1 SaveFile through the frontend: the panel (its default button) answers the suggested name in the suggested folder, the
#    choice and the filter, as the application's Response; OpenFile of a folder answers the shown folder; the backend was
#    started once, by D-Bus activation, and quits by itself once idle (the dev idle time, 5 s; 60 s in the session) (A-FC1)
#  2 Cancel: response 1
#  3 the panels' QML cannot load: the same call goes to x-d-p-gtk and its answer reaches the application (A-FC4)
#  4 the backend killed while a panel is open: the application gets response 2 within seconds, and the next call is answered
#    by a new process (A-FC6); the process stays within its memory budget while a panel is open (offscreen; A-FC3 is nested)
#  5 the backend starts and answers with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers (A-FC7)
#  6 refused outside a Grassfield session, and as a dev run on a bus that is not a private test bus
#  7 the camera through the frontend (the frontend's permission store on the scratch home): the alert allows (response 0,
#    "yes" kept) or does not (response 1, "no" kept); an AccessDialog with a choice answers the choice (A-AC1 without the
#    nested session)
#  8 Open With through the frontend (OpenFile with "ask" on a text file, two scratch applications for text/plain, one the default):
#    Choose Application answers the default (its last choice, selected), the frontend starts it with the document and counts
#    the choice in its permission store; Cancel starts nothing (A-OW1 through the real frontend)
#  9 Print through the frontend as GTK makes it, over a scratch CUPS scheduler (tests/integration/print-cups.sh, when a cupsd
#    the user can run is there): the print sheet over its default queue prints, the application gets GTK's settings with the
#    printer and one copy (GTK must not make them) and a token, and Print with the token sends the document there with the two
#    copies asked (A-PR1, A-PR2 without the nested session)
# Needs dbus-daemon, python3 with PyGObject, /usr/lib/xdg-desktop-portal (and for 9 a scratch CUPS: print-cups.sh), and the built backend (GRASSFIELD_PORTAL, or
# apps/portal/build-direct.sh with g++, Qt 6 and KDE Frameworks 6) with the Grassfield.I18n plugin (ui/i18n/build-direct.sh);
# the runtime part SKIPs without them, and when libdbus cannot reach the bus.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/portal-filechooser.XXXXXX")
# The private bus (start_bus, stop_bus, owned, start_service, wait_until), shared with portal_settings.sh.
. "$root/tests/integration/portal-bus.sh"
stop_all() { stop_bus; declare -F stop_cups >/dev/null && stop_cups; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
pk=$root/packaging
name=org.freedesktop.impl.portal.desktop.grassfield
unit=$pk/systemd/grassfield-portal.service

# --- static ------------------------------------------------------------------------------------------------------------
desc="the .portal file, the D-Bus service file and the unit name the same bus name and program; FileChooser, Access, AppChooser (D-5) and Print (D-7)"
check bash -c 'grep -qx "DBusName=$1" "$2" && grep -qx "Interfaces=org.freedesktop.impl.portal.FileChooser;org.freedesktop.impl.portal.Access;org.freedesktop.impl.portal.AppChooser;org.freedesktop.impl.portal.Print;" "$2" && grep -qx "Name=$1" "$3" &&
  grep -qx "Exec=/usr/lib/grassfield/grassfield-portal" "$3" && grep -qx "SystemdService=grassfield-portal.service" "$3" &&
  grep -qx "BusName=$1" "$4" && grep -qx "ExecStart=/usr/lib/grassfield/grassfield-portal" "$4"' _ "$name" \
  "$pk/xdg/xdg-desktop-portal/portals/grassfield.portal" "$pk/dbus/$name.service" "$unit"
desc="the session's routing sends FileChooser, Access, AppChooser and Print to grassfield, then gtk"
check bash -c 'grep -qx "org.freedesktop.impl.portal.FileChooser=grassfield;gtk" "$1" && grep -qx "org.freedesktop.impl.portal.Access=grassfield;gtk" "$1" &&
  grep -qx "org.freedesktop.impl.portal.AppChooser=grassfield;gtk" "$1" && grep -qx "org.freedesktop.impl.portal.Print=grassfield;gtk" "$1"' _ \
  "$pk/xdg/xdg-desktop-portal/hyprland-portals.conf"
desc="the unit: Type=dbus, no Restart (D-Bus activation), only in the Grassfield session, clears GTK_USE_PORTAL and QT_QPA_PLATFORMTHEME, hardened, every place the user may write writable (4b-12)"
check bash -c 'for l in Type=dbus ConditionEnvironment=GRASSFIELD_SESSION=1 "UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME" \
  NoNewPrivileges=yes ProtectSystem=full RestrictSUIDSGID=yes LockPersonality=yes; do
  grep -qx "$l" "$1" || { echo "missing: $l"; exit 1; }; done; ! grep -q "^Restart=" "$1" &&
  ! grep -q "^\(UMask\|ReadOnlyPaths\|ProtectHome\)=" "$1"' _ "$unit"
desc="the PKGBUILD builds and installs the backend, its unit, .portal and D-Bus service files, and depends on KWindowSystem"
check bash -c 'grep -q "cmake -S \"\$(_root)/apps/portal\"" "$1" && grep -q "cmake --install \"\$srcdir/portal-build\"" "$1" &&
  grep -qE "for unit in .* portal( .*)?; do" "$1" && grep -q "usr/share/grassfield/xdg/xdg-desktop-portal/portals/grassfield.portal" "$1" &&
  grep -q "usr/share/dbus-1/services/$2.service" "$1" && grep -q " kwindowsystem " "$1"' _ "$pk/arch/PKGBUILD" "$name"
desc="the session's window rules give a panel's and an alert's xdg tags (gfChromeRole) the client-chrome tag"
check bash -c 'for qml in "$1" "$2"; do role=$(sed -n "s/^ *property string gfChromeRole: \"\(.*\)\"$/\1/p" "$qml") && [[ -n $role ]] &&
  grep -qF "match = { xdg_tag = \"^$role\$\" }, tag = \"+grassfield-client-chrome\"" "$3" || exit 1; done' _ \
  "$root/apps/files/qml/FilePanel.qml" "$root/apps/files/qml/AccessAlert.qml" "$root/config/hypr/grassfield/windows.lua"

# --- runtime -----------------------------------------------------------------------------------------------------------
frontend=/usr/lib/xdg-desktop-portal
store=/usr/lib/xdg-permission-store
for tool in dbus-daemon python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: portal_filechooser needs $tool (runtime part)"; exit "$fail"; }
done
[[ -x $frontend ]] || { echo "SKIP: portal_filechooser needs xdg-desktop-portal ($frontend; runtime part)"; exit "$fail"; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { echo "SKIP: portal_filechooser needs PyGObject"; exit "$fail"; }
backend=${GRASSFIELD_PORTAL:-}
if [[ -z $backend ]]; then
  if [[ ! -d /usr/include/KF6/KIOCore ]] || ! command -v g++ >/dev/null; then
    echo "SKIP: portal_filechooser needs g++ and KDE Frameworks 6 to build the backend"; exit "$fail"
  fi
  "$root/apps/portal/build-direct.sh" >"$tmp/build.log" 2>&1 || { tail -n 20 "$tmp/build.log"; echo "FAIL: the backend builds"; exit 1; }
  backend=$root/.dev/build/grassfield-portal
fi
"$root/ui/i18n/build-direct.sh" >"$tmp/i18n.log" 2>&1 || { tail -n 20 "$tmp/i18n.log"; echo "FAIL: the Grassfield.I18n plugin builds"; exit 1; }
client=$root/tests/fixtures/portal-client.py
fakes=$root/tests/fixtures/fake-portal-backend.py

# One scenario: a fresh bus whose service directory starts the backend (answering its panels with `answer`, after a restart
# with `later`) and the gtk stand-in on demand, then the real frontend (unless frontend is "silent": the never-answering stand-in
# instead). Sets d.
scenario() { # scenario <name> <answer> [later] [qml dir] [frontend: real|silent] [extra environment of the backend]
  d=$tmp/$1
  mkdir -p "$d/services" "$d/home/Documents" "$d/home/My Documents" "$d/run" "$d/cfg" "$d/xdg" "$d/state" "$d/config"
  chmod 700 "$d/run"
  echo hello >"$d/home/Documents/a.txt"
  cp -r "$pk/xdg/." "$d/xdg/"
  printf '#!/bin/sh\nexport GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)"\nexec python3 -I %s gtk --log %s/gtk.log\n' \
    "$d" "$d" "$fakes" "$d" >"$d/gtk.sh"
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.gtk\nExec=%s/gtk.sh\n' "$d" >"$d/services/gtk.service"
  # The frontend's permission store (the permission alerts' answers), on the scratch home.
  printf '#!/bin/sh\nexec env -i PATH="$PATH" HOME=%s/home XDG_DATA_HOME=%s/home/.local/share DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)" %s\n' \
    "$d" "$d" "$d" "$store" >"$d/store.sh"
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.PermissionStore\nExec=%s/store.sh\n' "$d" >"$d/services/store.service"
  # The answer of this start: the first start's, then `later` (the restarted process of scenario 4).
  printf '#!/bin/sh\necho started >>%s/backend.starts\necho $$ >%s/backend.pid\nanswer=%s\n[ "$(wc -l <%s/backend.starts)" -gt 1 ] && answer=%s\nexec env -i PATH="$PATH" HOME=%s/home XDG_RUNTIME_DIR=%s/run DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)" GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s GRASSFIELD_DEV=1 GRASSFIELD_CONFIG_HOME=%s/config GRASSFIELD_STATE_HOME=%s/state QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 QML_IMPORT_PATH=%s/ui:%s/.dev/build/qml GRASSFIELD_FILES_QML=%s GRASSFIELD_PORTAL_TEST_ANSWER="$answer" GRASSFIELD_PORTAL_IDLE_MS=5000 %s %s >>%s/backend.log 2>&1\n' \
    "$d" "$d" "\"$2\"" "$d" "\"${3:-$2}\"" "$d" "$d" "$d" "$d" "$d" "$d" "$root" "$root" "${4:-$root/apps/files/qml}" "${6:-}" "$backend" "$d" >"$d/backend.sh"
  printf '[D-BUS Service]\nName=%s\nExec=%s/backend.sh\n' "$name" "$d" >"$d/services/grassfield.service"
  chmod 755 "$d"/*.sh
  start_bus "$d" || { echo "bus: $(head -n 1 "$d/bus.log")"; return 1; }
  if [[ ${5:-real} == silent ]]; then
    GF_TEST_BUS=1 GF_TEST_BUS_DIR=$d DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$fakes" silent-frontend >"$d/frontend.log" 2>&1 &
    frontend_pid=$!
  else
    env -i PATH="$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_DATA_HOME="$d/home/.local/share" XDG_RUNTIME_DIR="$d/run" \
      XDG_DATA_DIRS="$d/xdg:/usr/share" XDG_CURRENT_DESKTOP=Hyprland DBUS_SESSION_BUS_ADDRESS="$bus" "$frontend" -v -r >"$d/frontend.log" 2>&1 &
    frontend_pid=$!
  fi
  wait_until 10 owned org.freedesktop.portal.Desktop
}
choose() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" choose "$@"; }
impl() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" impl "$@"; }
camera() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" camera "$@"; }
access() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" access "$@"; }
permission() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" permission "$@"; }
openfile() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" open-file "$@"; }
value() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(eval(sys.argv[1], {}, {"d": d})))' "$1"; }
starts() { wc -l <"$d/backend.starts" 2>/dev/null || echo 0; }
# The backend's process is gone (or a zombie): backend.sh writes its pid before it execs the backend.
exited() { [[ ! -e /proc/$1 ]] || grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }

printdoc() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I "$client" print "$@"; }
# The scratch CUPS scheduler of scenario 9 (cups_ready, start_cups, stop_cups).
. "$root/tests/integration/print-cups.sh"

# Preflight: libdbus reaches a private bus.
mkdir -p "$tmp/pre/services"
if ! start_bus "$tmp/pre"; then desc="a private bus starts [$(head -n 1 "$tmp/pre/bus.log")]"; check false; exit 1; fi
if ! pre=$(DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c 'from gi.repository import Gio; Gio.bus_get_sync(Gio.BusType.SESSION)' 2>&1); then
  echo "SKIP: portal_filechooser: this environment gives no way to a private bus (${pre%%$'\n'*})"; exit "$fail"
fi
stop_bus

# 1 --------------------------------------------------------------------------------------------------------------------
scenario save accept || exit 1
got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.FileChooser \(.*config\)" "$d/frontend.log" | sort -u)
desc="1 the frontend routes FileChooser to the Grassfield backend [$got]"
check test "$got" = "Using grassfield.portal for org.freedesktop.impl.portal.FileChooser (interface specific config)"
out=$(choose SaveFile "{\"current_name\": \"new file.txt\", \"current_folder\": \"$d/home/My Documents\", \"filters\": [[\"Text\", [[0, \"*.txt\"]]], [\"Markdown\", [[0, \"*.md\"]]]], \"choices\": [[\"enc\", \"Encoding\", [[\"utf8\", \"UTF-8\"], [\"latin1\", \"Western\"]], \"latin1\"]]}" 20)
got=$(value '[d.get("response"), d.get("results", {}).get("uris"), d.get("results", {}).get("choices"), d.get("results", {}).get("current_filter")]' <<<"$out")
desc="1 SaveFile: the suggested name in the suggested folder (both with a space), the choice and the filter reach the application [$got]"
check test "$got" = "[0, [\"file://$d/home/My%20Documents/new%20file.txt\"], [[\"enc\", \"latin1\"]], [\"Text\", [[0, \"*.txt\"]]]]"
out=$(choose OpenFile "{\"directory\": true, \"accept_label\": \"_Choose\"}" 20)
got=$(value '[d.get("response"), d.get("results", {}).get("uris")]' <<<"$out")
desc="1 OpenFile of a folder: the panel opens where the application's last panel was left, and answers that folder [$got]"
check test "$got" = "[0, [\"file://$d/home/My%20Documents\"]]"
desc="1 the backend was started once, by D-Bus activation, and outlived its panels, each of which drew [$(starts) start(s), $(grep -c 'panel shown' "$d/backend.log") panel(s): $(grep -o 'panel shown in [0-9]* ms' "$d/backend.log" | tr '\n' ';')]"
check test "$(starts) $(grep -c 'panel shown' "$d/backend.log")" = "1 2"
names=$(python3 -I -c 'import json; print(json.dumps(["name %d.txt" % i for i in range(20)]))')
out=$(choose SaveFiles "{\"files\": $names, \"current_folder\": \"$d/home/My Documents\"}" 20)
got=$(value '[d.get("response"), len(d.get("results", {}).get("uris") or []), (d.get("results", {}).get("uris") or [""])[-1]]' <<<"$out")
desc="1 SaveFiles with 20 names (one probe job, more names than the job bound) is answered on a healthy folder [$got]"
check test "$got" = "[0, 20, \"file://$d/home/My%20Documents/name%2019.txt\"]"
pid=$(cat "$d/backend.pid")
desc="1 idle, the backend gives up its name by itself (5 s here)"
check wait_until 15 unowned "$name"
desc="1 ... and its process ends [pid $pid]"
check wait_until 5 exited "$pid"
desc="1 the panels kept the application's last folder (portal-filechooser.json)"
check grep -qF "\"folder\":\"file://$d/home/My%20Documents\"" "$d/state/portal-filechooser.json"
stop_bus

# 2 --------------------------------------------------------------------------------------------------------------------
scenario cancel cancel || exit 1
out=$(choose OpenFile "{\"multiple\": true}" 20)
desc="2 Cancel: response 1 [$out]"
check test "$(value 'd.get("response")' <<<"$out")" = 1
stop_bus

# 3 --------------------------------------------------------------------------------------------------------------------
mkdir -p "$tmp/no-qml"
scenario broken accept accept "$tmp/no-qml" || exit 1
out=$(choose OpenFile "{}" 20)
got=$(value '[d.get("response"), d.get("results", {}).get("uris"), d.get("results", {}).get("choices")]' <<<"$out")
desc="3 the panels' QML cannot load: x-d-p-gtk answers the same call, and its answer reaches the application [$got]"
check test "$got" = '[0, ["file:///from-gtk/OpenFile"], [["enc", "latin1"]]]'
desc="3 x-d-p-gtk got the frontend's own request handle [$(head -n 1 "$d/gtk.log" 2>/dev/null)]"
check grep -qE "^FileChooser.OpenFile /org/freedesktop/portal/desktop/request/" "$d/gtk.log"
stop_bus

# 4 --------------------------------------------------------------------------------------------------------------------
scenario crash "" accept || exit 1
choose OpenFile "{}" 30 >"$d/first.out" &
first=$!
wait_until 15 grep -q "panel shown" "$d/backend.log"
read -r rss anon < <(awk '/^VmRSS:/ { r = $2 } /^RssAnon:/ { a = $2 } END { print r, a }' "/proc/$(cat "$d/backend.pid")/status" 2>/dev/null)
desc="4 the backend's memory with a panel open is within its budget (80 MB private, decision 4b-9; resident with the shared libraries reported) [private ${anon:-?} kB, resident ${rss:-?} kB, offscreen]"
check bash -c '[[ -n $1 && $1 -le 81920 ]]' _ "$anon"
kill -KILL "$(cat "$d/backend.pid")" 2>/dev/null
started=$SECONDS
wait "$first"
desc="4 the backend killed while a panel is open: the application gets response 2 [$(cat "$d/first.out") after $((SECONDS - started)) s]"
check test "$(value 'd.get("response")' <"$d/first.out")" = 2
out=$(choose OpenFile "{\"directory\": true}" 20)
desc="4 the next call is answered by a new process started by D-Bus activation [$(starts) starts; $out]"
check test "$(starts) $(value 'd.get("response")' <<<"$out")" = "2 0"
stop_bus

# 5 --------------------------------------------------------------------------------------------------------------------
scenario startup accept accept "" silent "GTK_USE_PORTAL=1 QT_QPA_PLATFORMTHEME=gtk3" || exit 1
started=$SECONDS
start_service "$name" >/dev/null 2>&1
desc="5 with GTK_USE_PORTAL=1, QT_QPA_PLATFORMTHEME=gtk3 and a frontend that never answers, the backend owns its name"
check wait_until 10 owned "$name"
out=$(impl SaveFile "{\"current_name\": \"x.txt\", \"current_folder\": \"$d/home\"}" 20)
desc="5 ... and answers [$(value '[d.get("response"), d.get("results", {}).get("uris")]' <<<"$out") after $((SECONDS - started)) s]"
check test "$(value '[d.get("response"), d.get("results", {}).get("uris")]' <<<"$out")" = "[0, [\"file://$d/home/x.txt\"]]"
stop_bus

# 6 --------------------------------------------------------------------------------------------------------------------
out=$(env -i PATH="$PATH" QT_QPA_PLATFORM=offscreen "$backend" 2>&1)
desc="6 refused outside a Grassfield session [$out]"
check bash -c '[[ $1 == *"refused: not a Grassfield session"* ]]' _ "$out"
out=$(env -i PATH="$PATH" QT_QPA_PLATFORM=offscreen GRASSFIELD_DEV=1 GF_TEST_BUS=1 GF_TEST_BUS_DIR="$tmp" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$backend" 2>&1)
desc="6 a dev run refuses a bus that is not a private test bus [$out]"
check bash -c '[[ $1 == *"refused: a dev session runs it only on a private test bus"* ]]' _ "$out"

# 7 --------------------------------------------------------------------------------------------------------------------
# The permission alerts (D-5): the camera asked through the frontend, the alert's answer kept by the frontend in its
# permission store; a choice through the backend's interface.
if [[ -x $store ]]; then
  scenario camera accept || exit 1
  out=$(camera 20)
  got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.Access \(.*config\)" "$d/frontend.log" | sort -u)
  desc="7 the frontend routes Access to the Grassfield backend [$got]"
  check bash -c '[[ $1 == *"grassfield.portal for org.freedesktop.impl.portal.Access"* ]]' _ "$got"
  desc="7 the camera through the frontend: the alert allows, the application gets response 0 [$out]"
  check test "$(value 'd.get("response")' <<<"$out")" = "0"
  perm=$(permission devices camera)
  desc="7 ... and the frontend keeps \"yes\" in its permission store [$perm]"
  check test "$(value 'list(d.get("permissions", {}).values())' <<<"$perm")" = '[["yes"]]'
  out=$(access '{"icon": "find-location-symbolic", "choices": [["remember", "Remember", [], "true"]]}' 20)
  desc="7 AccessDialog with a choice: response 0 and the choice's value [$out]"
  check test "$(value '[d.get("response"), d.get("results", {}).get("choices")]' <<<"$out")" = '[0, [["remember", "true"]]]'
  stop_bus
  scenario camera-deny cancel || exit 1
  out=$(camera 20)
  desc="7 Don't Allow: the application gets response 1 [$out]"
  check test "$(value 'd.get("response")' <<<"$out")" = "1"
  perm=$(permission devices camera)
  desc="7 ... and the frontend keeps \"no\" [$perm]"
  check test "$(value 'list(d.get("permissions", {}).values())' <<<"$perm")" = '[["no"]]'
  stop_bus
else
  echo "SKIP: 7 needs xdg-permission-store ($store)"
fi

# 8 --------------------------------------------------------------------------------------------------------------------
# Open With (D-5, step 5b): an application opens a document through the frontend's OpenFile with "ask"; the frontend asks the
# AppChooser backend (its candidates for text/plain, its last choice the type's default application), Choose Application
# answers it, and the frontend starts that application with the document and counts the choice in its permission store.
openwith() { # openwith <scenario name>: two applications for text/plain (each writes the file it is given) and the default
  local dd=$tmp/$1 app
  mkdir -p "$dd/home/.local/share/applications" "$dd/cfg"
  for app in A B; do
    printf '#!/bin/sh\nprintf "%%s" "$1" >%s/opened-%s\n' "$dd" "$app" >"$dd/open-$app.sh"
    chmod 755 "$dd/open-$app.sh"
    printf '[Desktop Entry]\nType=Application\nName=Grassfield Test %s\nExec=%s/open-%s.sh %%f\nMimeType=text/plain;\n' "$app" "$dd" "$app" \
      >"$dd/home/.local/share/applications/org.example.GfOpen$app.desktop"
  done
  printf '[Default Applications]\ntext/plain=org.example.GfOpenB.desktop\n' >"$dd/cfg/mimeapps.list"
}
if [[ -x $store ]]; then
  openwith openwith
  scenario openwith accept || exit 1
  out=$(openfile "$d/home/Documents/a.txt" 30)
  got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.AppChooser \(.*config\)" "$d/frontend.log" | sort -u)
  desc="8 the frontend routes AppChooser to the Grassfield backend [$got]"
  check bash -c '[[ $1 == *"grassfield.portal for org.freedesktop.impl.portal.AppChooser"* ]]' _ "$got"
  desc="8 Choose Application answers (the type's default application, selected), the application gets response 0 [$out]"
  check test "$(value 'd.get("response")' <<<"$out")" = "0"
  wait_until 10 test -s "$d/opened-B"
  desc="8 ... the frontend starts the chosen application with the document [$(cat "$d/opened-B" 2>/dev/null)]"
  check test "$(cat "$d/opened-B" 2>/dev/null)" = "$d/home/Documents/a.txt"
  perm=$(permission desktop-used-apps text/plain)
  desc="8 ... and counts the choice in its permission store [$perm]"
  check test "$(value '[v[0] for v in d.get("permissions", {}).values()]' <<<"$perm")" = '["org.example.GfOpenB"]'
  # The same process then serves an Open panel: one panels root for both interfaces (made by the first of them).
  out=$(choose OpenFile "{\"directory\": true}" 20)
  desc="8 ... then an Open panel in the same process answers too [$out; starts $(starts)]"
  check test "$(value 'd.get("response")' <<<"$out") $(starts)" = "0 1"
  stop_bus
  openwith openwith-cancel
  scenario openwith-cancel cancel || exit 1
  out=$(openfile "$d/home/Documents/a.txt" 30)
  desc="8 Cancel: the application gets response 1, and no application starts [$out]"
  check bash -c '[[ $1 == 1 && ! -e $2/opened-A && ! -e $2/opened-B ]]' _ "$(value 'd.get("response")' <<<"$out")" "$d"
  stop_bus
else
  echo "SKIP: 8 needs xdg-permission-store ($store)"
fi

# 9 --------------------------------------------------------------------------------------------------------------------
# Print (D-7, step 6a): an application's Print… through the frontend as GTK makes it: PreparePrint shows the print sheet over the
# scratch scheduler's default queue, the sheet prints (its test answer), the application gets GTK's settings and a token, and
# Print with the token sends the document to that queue with the copies asked.
if cups_ready && start_cups "$tmp/cups"; then
  scenario print accept "" "" real "CUPS_SERVER=localhost:$cups_port" || exit 1
  printf '%%PDF-1.4\n%% a page\n%%%%EOF\n' >"$d/document.pdf"
  out=$(printdoc "$d/document.pdf" 30)
  got=$(grep -oE "Using [a-z-]+\.portal for org\.freedesktop\.impl\.portal\.Print \(.*config\)" "$d/frontend.log" | sort -u)
  desc="9 the frontend routes Print to the Grassfield backend [$got]"
  check bash -c '[[ $1 == *"grassfield.portal for org.freedesktop.impl.portal.Print"* ]]' _ "$got"
  desc="9 the print sheet prints on the default queue: response 0, GTK's settings with the printer and one copy for GTK to make, a token [$out]"
  check test "$(value '[d["prepare"].get("response"), d["prepare"]["results"]["settings"].get("printer"), d["prepare"]["results"]["settings"].get("n-copies"), d["prepare"]["results"].get("token", 0) > 0]' <<<"$out")" = '[0, "Office", "1", true]'
  desc="9 ... Print with the token: response 0 [$(value 'd.get("print")' <<<"$out")]"
  check test "$(value 'd.get("print", {}).get("response")' <<<"$out")" = "0"
  wait_until 15 bash -c 'CUPS_SERVER=localhost:$1 lpstat -W completed -o Office | grep -q Office' _ "$cups_port"
  job=$(CUPS_SERVER=localhost:$cups_port lpstat -W completed -o Office | awk 'NR == 1 {print $1}')
  copies=$(CUPS_SERVER=localhost:$cups_port ipptool -tv "ipp://localhost:$cups_port/jobs/${job##*-}" get-job-attributes.test 2>/dev/null |
    sed -n 's/^ *copies (integer) = //p')
  document=$(ls "$tmp/cups/spool"/d*-001 2>/dev/null | head -1)
  desc="9 ... the scheduler has the job ($job) with its two copies and the document the application made [copies $copies]"
  check bash -c '[[ -n $1 && $2 == 2 && -n $3 ]] && cmp -s "$3" "$4"' _ "$job" "$copies" "$document" "$d/document.pdf"
  stop_bus
  stop_cups
else
  echo "SKIP: 9 needs a cupsd the user can run (GF_TEST_CUPSD), lpadmin and python3"
fi

exit "$fail"
