#!/usr/bin/env bash
# M3 exit test (master-prompt §12 M3, §5.7 T1/T2, ADR-0008): global menus end to end in the nested session.
#
#   Phase A (plugin loaded, private bus, grassfield-menu-bridge):
#     - tests/fixtures/menu-demo (Qt, T1): focused -> the menu bar shows ITS menus (File, Edit, View); File > New and
#       View > Theme > Dark clicked with the (virtual) pointer run the app's own actions (action log);
#     - Chromium (T2, --ozone-platform=wayland, temporary profile): focused -> its menus; File > New window clicked
#       with the pointer opens a second browser window (counted with scripts/nestctl clients -j);
#     - a GTK4 app (nautilus when installed and linked to GTK 4, else foot): no DBusMenu -> T0 menus (File/Window).
#   Phase B (GRASSFIELD_NO_PLUGIN, nested-up --no-plugin): the bridge stays in standby, no registrar is owned, and a
#     Qt app keeps its in-window menu bar.
#   Screenshots: .dev/shots/global-menus-*.png (scripts/dev/shot.sh).
#
# Usage: tests/integration/global_menus.sh        (restarts the nested session of this checkout; run it outside the
#                                                  Claude Code sandbox: it starts the nested compositor)
# Exit: 0 PASS, 1 FAIL, 2 environment error. Summary: .dev/global-menus/run-<stamp>/summary.txt
#
# SAFETY (D-Bus, R3): the registrar, the bridge and every test app share the nested shell's PRIVATE bus
# (.dev/bus.address, checked to be a /tmp/dbus-* socket, never /run/user/<uid>/bus); apps get the nested Wayland
# socket only and a throwaway HOME/XDG tree under the run directory. hyprctl is used read-only through
# scripts/nestctl; input goes through scripts/dev/pointer.sh and keys.sh (nested only). Processes are stopped by
# their recorded process groups (no broad pkill).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
run=$dev/global-menus/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
summary=$run/summary.txt
output=GF-REF
fail=0

say() { printf '%s\n' "$*" | tee -a "$summary"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }

for tool in jq qs gdbus grim; do
  command -v "$tool" >/dev/null || die "$tool is needed"
done
[[ -x /usr/lib/chromium/chromium ]] || die "chromium is not installed (/usr/lib/chromium/chromium)"

# ---- builds ------------------------------------------------------------------------------------------------------
[[ -f $root/compositor/build/grassfield-compositor.so ]] || "$root/compositor/build-direct.sh" plugin || die "plugin build failed"
if [[ ! -x $dev/build/grassfield-menu-bridge ]]; then
  "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"
fi
if [[ ! -x $dev/build/menu-demo ]]; then
  "$root/tests/fixtures/build.sh" menu-demo >/dev/null || die "menu-demo build failed"
fi

# ---- helpers -----------------------------------------------------------------------------------------------------
app_pids=()
cleanup_apps() {
  local p
  for p in "${app_pids[@]}"; do kill -- "-$p" 2>/dev/null; done
  sleep 1
  for p in "${app_pids[@]}"; do kill -9 -- "-$p" 2>/dev/null; done
  # Chromium helpers can leave the process group: matched by this run's unique profile path only.
  pgrep -f -- "$run/home" >/dev/null 2>&1 && pkill -f -- "$run/home"
  app_pids=()
}
trap 'cleanup_apps; "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1' EXIT

private_bus() {
  local bus
  bus=$(cat "$dev/bus.address" 2>/dev/null) || return 1
  case $bus in unix:path=/tmp/dbus-*) printf '%s\n' "$bus" ;; *) return 1 ;; esac
}

bus_call() { # <dest> <path> <method> [args...]   (private bus only)
  local bus
  bus=$(private_bus) || { echo "no private bus"; return 1; }
  timeout 5 gdbus call --address "$bus" --dest "$1" --object-path "$2" --method "$3" "${@:4}"
}

registrar_owned() {
  bus_call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner com.canonical.AppMenu.Registrar | grep -q true
}

state() { # menu bar test hook (JSON)
  timeout 5 qs ipc --pid "$(cat "$dev/shell.pid")" call menubar bridgeState "$output" 2>/dev/null
}

wait_for() { # <seconds> <command...>
  local deadline=$((SECONDS + $1))
  shift
  while ((SECONDS < deadline)); do
    "$@" && return 0
    sleep 0.3
  done
  return 1
}

start_app() { # <name> <command...>
  local name=$1 home=$run/home
  shift
  mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" "$home/.local/state"
  env -u QT_QPA_PLATFORMTHEME -u KDE_SESSION_VERSION -u KDE_FULL_SESSION -u GTK_MODULES \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" WAYLAND_DISPLAY="$(cat "$dev/nested.wayland")" DBUS_SESSION_BUS_ADDRESS="$(private_bus)" \
    QT_QPA_PLATFORM=wayland GDK_BACKEND=wayland \
    setsid "$@" >"$run/$name.out" 2>&1 </dev/null &
  app_pids+=("$!")
  last_pid=$!
}

windows_of() { # <pid> -> number of mapped windows of that client
  "$root/scripts/nestctl" clients -j 2>/dev/null | jq --argjson p "$1" '[.[] | select(.pid == $p and .mapped)] | length'
}

address_of() { # <pid> -> hex address (no 0x) of its most recently focused window
  "$root/scripts/nestctl" clients -j 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p)] | sort_by(.focusHistoryID) | .[0].address // "" | ltrimstr("0x")'
}

has_window() { [[ $(windows_of "$1") -ge ${2:-1} ]]; }

menus_are() { # <address> <jq expression over .menus, true when as wanted>
  local s
  s=$(state) || return 1
  jq -e --arg w "$1" ".window == \$w and ($2)" <<<"$s" >/dev/null
}

center_of_title() { # <title> -> "x y" of that bridge title in the bar
  state | jq -r --arg t "$1" '.bar[] | select(.kind == "bridge" and .title == $t) | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"' | head -n 1
}

row_of() { # <regex> -> "x y w h" of the first popup row whose text matches
  state | jq -r --arg r "$1" '[.popup[] | select(.text | test($r))][0] // empty | "\(.x) \(.y) \(.w) \(.h)"'
}

row_present() { [[ -n $(row_of "$1") ]]; }

point() { "$root/scripts/dev/pointer.sh" output "$output" "$@" >/dev/null; }

click_title() { # <title>
  local xy
  xy=$(center_of_title "$1")
  [[ -n $xy ]] || return 1
  # shellcheck disable=SC2086
  point abs $xy sleep 150 click sleep 200
}

click_row() { # <regex>
  local x y w h
  read -r x y w h <<<"$(row_of "$1")"
  [[ -n ${x:-} ]] || return 1
  point abs $((x + w / 3)) $((y + h / 2)) sleep 150 click sleep 200
}

log_has() { grep -q -- "$2" "$1" 2>/dev/null; }

shell_qml_issues() { # QML-level warnings and errors in the shell log (the polkit agent line is environmental)
  grep -E "WARN qml|ERROR|Binding loop|TypeError|ReferenceError" "$dev/shell.log" | grep -v -E "grassfield-polkit: not registered|quickshell.service.polkit" || true
}

start_session() { # [nested-up options]
  "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1
  "$root/scripts/dev/nested-up.sh" --private-bus "$@" >"$run/nested-up-$phase.log" 2>&1 || return 1
  wait_for 15 test -S "$dev/run/menu-bridge.sock" || return 1
  wait_for 20 grep -q "shell connected" "$dev/menu-bridge.log" || return 1
  # The pointer on the reference output: new windows open there, under its menu bar.
  point abs 960 600 sleep 200
}

say "global menus (M3 exit test) run $run"

# ======================================================================================================== Phase A
phase=a
say ""
say "[phase A] plugin loaded, private bus, menu bridge"
start_session || die "nested session did not start (see $run/nested-up-a.log, .dev/menu-bridge.log)"
bus=$(private_bus) || die "no private bus address"
[[ $bus != *"/run/user/"* ]] || die "refusing: the bus is under /run/user"
say "  private bus: $bus"
check "registrar owned by the bridge on the private bus after the shell's hello (appmenu)" wait_for 15 registrar_owned
say "  bridge status: $(bus_call org.grassfield.MenuBridge1 /org/grassfield/MenuBridge1 org.grassfield.MenuBridge1.Status)"
say "  bridge version: $(bus_call org.grassfield.MenuBridge1 /org/grassfield/MenuBridge1 org.grassfield.MenuBridge1.Version)"

# ---- T1: the Qt reference app ----
say ""
say "[T1] tests/fixtures/menu-demo (Qt $(qtpaths6 --qt-version 2>/dev/null))"
start_app menu-demo "$dev/build/menu-demo" --log "$run/menu-demo-actions.log"
qt_pid=$last_pid
check "menu-demo window mapped" wait_for 15 has_window "$qt_pid"
wait_for 10 grep -q "menu-demo: platform=" "$run/menu-demo.out"
say "  app: $(grep -m1 'menu-demo: platform=' "$run/menu-demo.out" | sed 's/^menu-demo: //')"
qt_addr=$(address_of "$qt_pid")
check "menu bar shows menu-demo's own menus (File, Edit, View)" wait_for 15 menus_are "$qt_addr" '.menus == ["File","Edit","View"]'
say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-qt "$output")"
check "the in-window menu bar moved to the global menu (platformMenuBar=1 menuBarVisible=0)" grep -q "platformMenuBar=1 menuBarVisible=0" "$run/menu-demo.out"

click_title File
check "File menu open with the app's items" wait_for 5 row_present '^New$'
say "  File rows: $(state | jq -c '[.popup[].text]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-qt-file "$output")"
click_row '^New$'
check "pointer click on File > New ran the app's action (action log file.new)" wait_for 5 log_has "$run/menu-demo-actions.log" "file.new"

click_title View
wait_for 5 row_present '^Theme$'
read -r tx ty tw th <<<"$(row_of '^Theme$')"
if [[ -n ${tx:-} ]]; then
  point abs $((tx + tw / 2)) $((ty + th / 2)) sleep 400
  check "View > Theme submenu opened (about-to-show, nested rows)" wait_for 5 row_present '^Dark$'
  read -r dx dy dw dh <<<"$(row_of '^Dark$')"
  # Enter the submenu along the Theme row, then down to Dark (never crossing another row of the parent menu).
  [[ -n ${dx:-} ]] && point abs $((dx + 8)) $((ty + th / 2)) sleep 150 abs $((dx + dw / 3)) $((dy + dh / 2)) sleep 200 click sleep 200
  check "pointer click on View > Theme > Dark ran the app's action (view.theme.dark=on)" wait_for 5 log_has "$run/menu-demo-actions.log" "view.theme.dark=on"
  # The radio state comes back from the app: reopen and look at the check mark.
  click_title View
  wait_for 5 row_present '^Theme$' && point abs $((tx + tw / 2)) $((ty + th / 2)) sleep 500
  say "  screenshot (Theme submenu after Dark): $("$root/scripts/dev/shot.sh" global-menus-qt-radio "$output")"
  "$root/scripts/dev/keys.sh" -k Escape
  "$root/scripts/dev/keys.sh" -k Escape
else
  say "  FAIL View menu has no Theme row"
  fail=1
fi
say "  action log: $(tr '\n' ' ' <"$run/menu-demo-actions.log" 2>/dev/null)"

# ---- T2: Chromium ----
say ""
say "[T2] Chromium $(/usr/lib/chromium/chromium --version 2>/dev/null | head -n 1)"
start_app chromium /usr/lib/chromium/chromium --ozone-platform=wayland --user-data-dir="$run/home/chromium-profile" \
  --no-first-run --no-default-browser-check --password-store=basic --disable-sync about:blank
cr_pid=$last_pid
check "Chromium window mapped" wait_for 30 has_window "$cr_pid"
cr_addr=$(address_of "$cr_pid")
check "menu bar shows Chromium's own menus (File ... Help)" wait_for 20 menus_are "$cr_addr" '(.menus | index("File")) != null and (.menus | length) >= 3'
say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-chromium "$output")"
click_title File
check "Chromium File menu open" wait_for 5 row_present '^New [Ww]indow$'
say "  File rows: $(state | jq -c '[.popup[].text]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-chromium-file "$output")"
before=$(windows_of "$cr_pid")
click_row '^New [Ww]indow$'
check "pointer click on File > New window opened a window ($before -> 2)" wait_for 10 has_window "$cr_pid" 2
say "  Chromium windows now: $(windows_of "$cr_pid")"

# ---- GTK4 (no DBusMenu): T0 ----
say ""
gtk_app=foot
gtk_cmd=(/usr/bin/foot)
if [[ -x /usr/bin/nautilus ]] && ldd /usr/bin/nautilus 2>/dev/null | grep -q 'libgtk-4'; then
  gtk_app=nautilus
  gtk_cmd=(/usr/bin/nautilus --new-window)
fi
say "[T0] $gtk_app (no DBusMenu export)"
start_app "$gtk_app" "${gtk_cmd[@]}"
gtk_pid=$last_pid
check "$gtk_app window mapped" wait_for 20 has_window "$gtk_pid"
gtk_addr=$(address_of "$gtk_pid")
check "menu bar keeps T0 menus for $gtk_app (no bridge titles, Window present)" wait_for 10 menus_are "$gtk_addr" '.menus == [] and ([.bar[].kind] | index("window")) != null and ([.bar[].kind] | index("bridge")) == null'
say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-gtk4 "$output")"

cleanup_apps
issues=$(shell_qml_issues)
check "shell log: no QML warnings or errors in phase A" test -z "$issues"
[[ -n $issues ]] && say "$issues"
cp "$dev/menu-bridge.log" "$run/menu-bridge-a.log"
cp "$dev/shell.log" "$run/shell-a.log"

# ======================================================================================================== Phase B
phase=b
say ""
say "[phase B] GRASSFIELD_NO_PLUGIN (nested-up --no-plugin): no appmenu feature"
start_session --no-plugin || die "nested session (no plugin) did not start"
sleep 3 # past the capabilities timeout (1.5 s): the shell has told the bridge appmenu=false
if registrar_owned; then
  say "  FAIL registrar owned without the plugin"
  fail=1
else
  say "  PASS registrar not owned (NameHasOwner false)"
fi
say "  bridge status: $(bus_call org.grassfield.MenuBridge1 /org/grassfield/MenuBridge1 org.grassfield.MenuBridge1.Status)"
start_app menu-demo-noplugin "$dev/build/menu-demo" --log "$run/menu-demo-noplugin-actions.log"
np_pid=$last_pid
check "menu-demo window mapped" wait_for 15 has_window "$np_pid"
wait_for 10 grep -q "menu-demo: platform=" "$run/menu-demo-noplugin.out"
say "  app: $(grep -m1 'menu-demo: platform=' "$run/menu-demo-noplugin.out" | sed 's/^menu-demo: //')"
check "Qt app keeps its in-window menu bar (platformMenuBar=0 menuBarVisible=1)" grep -q "platformMenuBar=0 menuBarVisible=1" "$run/menu-demo-noplugin.out"
np_addr=$(address_of "$np_pid")
check "menu bar shows T0 menus only" wait_for 10 menus_are "$np_addr" '.menus == [] and ([.bar[].kind] | index("bridge")) == null'
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-no-plugin "$output")"
cleanup_apps
issues=$(shell_qml_issues)
check "shell log: no QML warnings or errors in phase B" test -z "$issues"
[[ -n $issues ]] && say "$issues"
cp "$dev/menu-bridge.log" "$run/menu-bridge-b.log"

# ======================================================================================================== Cleanup
say ""
bridge_pid=$(cat "$dev/menu-bridge.pid" 2>/dev/null)
bus_pid=$(cat "$dev/bus.pid" 2>/dev/null)
"$root/scripts/dev/nested-down.sh" >"$run/nested-down.log" 2>&1
trap - EXIT
gone() { [[ -z $1 ]] || ! kill -0 "$1" 2>/dev/null; }
# pgrep in this shell (a `bash -c "pgrep ..."` would match its own command line).
none_matching() { [[ -z $(pgrep -f -- "$1" | grep -v -x -e "$$" -e "$BASHPID") ]]; }
check "no menu bridge left after nested-down (pid ${bridge_pid:-none})" gone "$bridge_pid"
check "no private dbus-daemon left after nested-down (pid ${bus_pid:-none})" gone "$bus_pid"
check "no process of this run left" none_matching "$run/"
check "no grassfield-menu-bridge of this checkout running" none_matching "$dev/build/grassfield-menu-bridge"
say ""
if ((fail)); then
  say "RESULT: FAIL (summary $summary)"
  exit 1
fi
say "RESULT: PASS (summary $summary)"
exit 0
