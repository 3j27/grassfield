#!/usr/bin/env bash
# M3 exit test (master-prompt §12 M3, §5.7 T1/T2, ADR-0008): global menus end to end in the nested session.
#
#   Phase A (plugin loaded, private bus, grassfield-menu-bridge):
#     - tests/fixtures/menu-demo (Qt, T1): focused -> the menu bar shows ITS menus (File, Edit, View); File > New and
#       View > Theme > Dark clicked with the (virtual) pointer run the app's own actions (action log);
#     - Chromium (T2, --ozone-platform=wayland, temporary profile): focused -> its menus; File > New window clicked
#       with the pointer opens a second browser window (counted with scripts/nestctl clients -j);
#     - Qt Linguist (qt6-tools, a third-party Qt app, started through scripts/dev/isolated.sh): its own menus; Help >
#       About Qt clicked with the pointer opens the dialog window, closed again with Escape (keys.sh);
#     - Grassfield Preview (a Grassfield app, T1 through Qt.labs.platform, started through scripts/dev/isolated.sh) on two
#       text files: its menus (File, Edit, View, Go, Tools); Go > Next File clicked with the pointer shows the second file
#       (window title), File > Close Window closes the window and the app exits; its log has no QML warning;
#     - a GTK4 app (nautilus when installed and linked to GTK 4, else foot): no DBusMenu -> T0 menus (File/Window).
#   Phase B (GRASSFIELD_NO_PLUGIN, nested-up --no-plugin): the bridge stays in standby, no registrar is owned, and a
#     Qt app keeps its in-window menu bar; Grassfield Preview exports nothing (T0 menus) and logs no error (no widget
#     menu fallback).
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
# Only this tree's live nested session (records verified by start time; scripts/dev/pidfile.sh).
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host global_menus
nested_sock() { dev_nested_target "$dev" && echo "$DEV_NESTED_SOCK"; }
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
# Grassfield Preview (T1 case): always rebuilt, so the run checks the checkout's menus.
"$root/apps/preview/build-direct.sh" >/dev/null || die "grassfield-preview build failed"

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
  local pid
  pid=$(dev_live_pid "$dev/shell.pid") || return 1
  timeout 5 qs ipc --pid "$pid" call menubar bridgeState "$output" 2>/dev/null
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
  local name=$1 home=$run/home sock
  shift
  sock=$(nested_sock) || return 1
  mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" "$home/.local/state"
  env -u QT_QPA_PLATFORMTHEME -u KDE_SESSION_VERSION -u KDE_FULL_SESSION -u GTK_MODULES \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" GRASSFIELD_CONFIG_HOME="$home/.config/grassfield" GRASSFIELD_STATE_HOME="$home/.local/state/grassfield" \
    WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$(private_bus)" \
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
windows_at_most() { [[ $(windows_of "$1") -le $2 ]]; }

title_is() { # <pid> <title>: the client's most recently focused window has that title
  [[ $("$root/scripts/nestctl" clients -j 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p)] | sort_by(.focusHistoryID) | .[0].title // ""') == "$2" ]]
}

exited() { # <pid>: gone, or a zombie not reaped yet (a background child of this script)
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null)
  [[ -z $stat || $stat == Z* ]]
}

# A Grassfield app in the nested session, through scripts/dev/isolated.sh (start_app adds the private bus and the nested
# socket): the repository's Grassfield.Ui and catalogs, English.
start_grassfield_app() { # <name> <binary> [args...]
  local name=$1
  shift
  start_app "$name" "$root/scripts/dev/isolated.sh" --name "gm-$name" -- \
    env QML_IMPORT_PATH="$root/ui" GRASSFIELD_TRANSLATIONS_DIR="$dev/translations" GRASSFIELD_LANG=en QT_FORCE_STDERR_LOGGING=1 "$@"
}

app_log_issues() { # <log>: QML warnings and errors of an app (the dev portal registration line is environmental)
  grep -h -E "\.qml:[0-9]+|\.js:[0-9]+|TypeError|ReferenceError|Binding loop|No native Menu|Qt Labs Platform" "$1" || true
}

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

# Environmental lines of a nested dev session, matched as exact fixed strings (GF-035) so that no other warning of the
# same component is hidden: the polkit agent cannot register (another agent owns the session), and the lock
# announces that PAM is suppressed in dev sessions (shell/security/lock/Lock.qml, GRASSFIELD_DEV_ALLOW_PAM gate).
ENV_LINES=(
  "grassfield-polkit: not registered"
  "quickshell.service.polkit: failed to register listener" # Quickshell's own line for the same refusal (its text, not the category)
  "grassfield-lock: dev: PAM is suppressed on the lock (no real authentication; set GRASSFIELD_DEV_ALLOW_PAM=1 for the L2 failure-path test)"
)
shell_qml_issues() { # [log...] QML-level warnings and errors (default .dev/shell.log), minus ENV_LINES
  (($# > 0)) || set -- "$dev/shell.log"
  local pat=() e
  for e in "${ENV_LINES[@]}"; do pat+=(-e "$e"); done
  grep -h -E "WARN qml|ERROR|Binding loop|TypeError|ReferenceError" "$@" | grep -v -F "${pat[@]}" || true
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
say "[T1] tests/fixtures/menu-demo (Qt $(/usr/lib/qt6/bin/qtpaths --qt-version 2>/dev/null))"
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

# The shell (and, in development, the bridge) restarts while the app runs: the shell re-queries the plugin
# (hl.plugin.grassfield.appmenu) and the menus come back without a focus change.
cp "$dev/shell.log" "$run/shell-a-before-restart.log"
"$root/scripts/dev/shell-run.sh" --private-bus >"$run/shell-restart.log" 2>&1
wait_for 20 grep -q "shell connected" "$dev/menu-bridge.log"
check "after a shell restart the focused app's menus are back (plugin re-query)" wait_for 20 menus_are "$qt_addr" '.menus == ["File","Edit","View"]'

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
say "  bridge resources (ADR-0008 budget: <= 20 MB RSS): $(ps -o rss=,time= -p "$(cat "$dev/menu-bridge.pid")" | awk '{printf "RSS %d kB, CPU time %s", $1, $2}')"

# ---- Qt Linguist: a third-party Qt app (qt6-tools), master-prompt §12 ----
say ""
linguist=/usr/lib/qt6/bin/linguist
if [[ -x $linguist ]]; then
  say "[T1b] Qt Linguist (third-party Qt app, started through scripts/dev/isolated.sh)"
  start_app linguist "$root/scripts/dev/isolated.sh" --name gm-linguist -- "$linguist"
  li_pid=$last_pid
  check "Linguist window mapped" wait_for 30 has_window "$li_pid"
  li_addr=$(address_of "$li_pid")
  check "menu bar shows Linguist's own menus (File, Edit ... Help)" wait_for 20 menus_are "$li_addr" '(.menus | index("File")) != null and (.menus | index("Help")) != null and (.menus | length) >= 5'
  say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
  say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-linguist "$output")"
  click_title Help
  check "Linguist Help menu open with About Qt" wait_for 5 row_present '^About Qt$'
  say "  Help rows: $(state | jq -c '[.popup[].text]')"
  li_before=$(windows_of "$li_pid")
  click_row '^About Qt$'
  check "pointer click on Help > About Qt opened the dialog window ($li_before -> $((li_before + 1)))" wait_for 10 has_window "$li_pid" $((li_before + 1))
  say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-linguist-about "$output")"
  # The dialog has the keyboard focus: Escape closes it (nested only, through keys.sh); the process is stopped by cleanup_apps.
  "$root/scripts/dev/keys.sh" -k Escape
  check "About Qt dialog closed (back to $li_before window)" wait_for 10 windows_at_most "$li_pid" "$li_before"
  cleanup_apps
else
  say "[T1b] SKIP Qt Linguist: $linguist not installed (qt6-tools)"
fi

# ---- Grassfield Preview: a Grassfield app (T1 through Qt.labs.platform, master-prompt §12 M4) ----
say ""
say "[T1c] Grassfield Preview (started through scripts/dev/isolated.sh)"
samples=$run/preview-samples
mkdir -p "$samples"
printf 'first file\n' >"$samples/first.txt"
printf 'second file\n' >"$samples/second.txt"
start_grassfield_app preview "$dev/build/grassfield-preview" -- "$samples/first.txt" "$samples/second.txt"
pv_pid=$last_pid
check "Preview window mapped" wait_for 20 has_window "$pv_pid"
pv_addr=$(address_of "$pv_pid")
check "menu bar shows Preview's own menus (File, Edit, View, Go, Tools)" wait_for 20 menus_are "$pv_addr" '.menus == ["File","Edit","View","Go","Tools"]'
say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-preview "$output")"
click_title Go
check "Preview Go menu open with Next File" wait_for 5 row_present '^Next File$'
say "  Go rows: $(state | jq -c '[.popup[] | {text, enabled}]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-preview-go "$output")"
click_row '^Next File$'
check "pointer click on Go > Next File showed the second file (window title second.txt)" wait_for 5 title_is "$pv_pid" "second.txt"
click_title File
check "Preview File menu open with Close Window" wait_for 5 row_present '^Close Window$'
click_row '^Close Window$'
check "pointer click on File > Close Window closed the window and the app exited" wait_for 10 exited "$pv_pid"
issues=$(app_log_issues "$run/preview.out")
check "Preview log: no QML warning or error" test -z "$issues"
[[ -n $issues ]] && say "$issues"

# ---- GTK4 (no DBusMenu): T0 ----
say ""
# A client without DBusMenu. Never Nautilus or another D-Bus-activatable app: it could be activated outside the test's
# isolation (dev open policy, ADR-0011).
gtk_app=foot
gtk_cmd=(/usr/bin/foot)  # isolation-ok: start_app runs it with HOME and XDG_* in a private home
say "[T0] $gtk_app (no DBusMenu export)"
start_app "$gtk_app" "${gtk_cmd[@]}"
gtk_pid=$last_pid
check "$gtk_app window mapped" wait_for 20 has_window "$gtk_pid"
gtk_addr=$(address_of "$gtk_pid")
check "menu bar keeps T0 menus for $gtk_app (no bridge titles, Window present)" wait_for 10 menus_are "$gtk_addr" '.menus == [] and ([.bar[].kind] | index("window")) != null and ([.bar[].kind] | index("bridge")) == null'
say "  bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-t0-foot "$output")"

cleanup_apps
issues=$(shell_qml_issues "$run/shell-a-before-restart.log" "$dev/shell.log")
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
# A Grassfield app without the registrar: no global menu bar is created (apps/globalmenu.h), the toolbar stays, the bar
# shows T0 and the app logs nothing (no widget-menu fallback error).
mkdir -p "$run/preview-samples"
printf 'first file\n' >"$run/preview-samples/first.txt"
start_grassfield_app preview-noplugin "$dev/build/grassfield-preview" -- "$run/preview-samples/first.txt"
nb_pid=$last_pid
check "Preview window mapped" wait_for 20 has_window "$nb_pid"
nb_addr=$(address_of "$nb_pid")
check "menu bar shows T0 menus for Preview (no bridge titles, Window present)" wait_for 10 menus_are "$nb_addr" '.menus == [] and ([.bar[].kind] | index("window")) != null and ([.bar[].kind] | index("bridge")) == null'
say "  screenshot: $("$root/scripts/dev/shot.sh" global-menus-preview-no-plugin "$output")"
sleep 1
issues=$(app_log_issues "$run/preview-noplugin.out")
check "Preview log without the registrar: no error or QML warning" test -z "$issues"
[[ -n $issues ]] && say "$issues"
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
