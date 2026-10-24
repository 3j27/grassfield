#!/usr/bin/env bash
# Appmenu scenario and spike S5 (master-prompt §5.6 feature 3, §5.7 T1/T2, §12 M0 S5): does a client call
# org_kde_kwin_appmenu.set_address when grassfield-compositor advertises the global, under which conditions,
# and does the plugin turn it into gfc/1 `appmenu` events for the right window?
#
# Usage: tests/compositor/appmenu.sh [variant...]          (default: every qt-* variant and edge-cases)
#   qt-registrar       fake registrar on the bus before the app, QT_QPA_PLATFORMTHEME unset   (the T1 path)
#   edge-cases         tests/fixtures/appmenu-client: 15 invalid set_address requests, two objects on one
#                      surface, a surface that is never a window, version 2 manager release, exit with a live
#                      object (no D-Bus involved)
#   qt-no-registrar    no com.canonical.AppMenu.Registrar on the bus
#   qt-late-registrar  registrar started 3 s after the app
#   qt-gtk3            registrar, QT_QPA_PLATFORMTHEME=gtk3 (the owner's session value)
#   qt-portal          registrar, QT_QPA_PLATFORMTHEME=xdgdesktopportal
#   qt-kde             registrar, XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true
#   qt-no-global       registrar, but Qt told to ignore the global (QT_WAYLAND_DISABLED_INTERFACES): what an app
#                      sees when the registrar exists and the compositor has no appmenu support
#   chromium           registrar, chromium --ozone-platform=wayland, temporary profile under the run directory;
#                      File > New Window is clicked through DBusMenu
#   chromium-no-registrar  same without the registrar
#
# SAFETY (D-Bus): every variant runs on its OWN private session bus (dbus-run-session): the registrar fixture
# (tests/fixtures/fake-registrar) must never own com.canonical.AppMenu.Registrar on the owner's bus, where it
# would make the owner's Qt/KDE apps hide their menu bars; the fixture refuses a bus that already has
# well-known names. Clients get the NESTED Wayland socket only. hyprctl is used read-only against the nested
# instance; plugin events are read from its socket2 (socat, read-only subscription). The re-emit check calls
# hl.plugin.grassfield.appmenu through Quickshell's Hyprland.dispatch (the shell's channel, ADR-0007).
#
# Per variant (directory .dev/appmenu/run-<timestamp>/<variant>/): app stdout, WAYLAND_DEBUG lines about the
# appmenu protocol, registrar log, the plugin's appmenu events for the app's window, DBusMenu introspection
# and layout, the action log. For qt-registrar the app's own actions are triggered through DBusMenu
# (File > New, View > Theme > Dark) and must reach the action log, then File > Quit must close the window and
# the plugin must post the clear event.
# Exit: 0 PASS (qt-registrar complete when it ran; nested Hyprland alive), 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
self=$root/tests/compositor/appmenu.sh

# ---------------------------------------------------------------------------------------------------------------
# Inner part: runs inside dbus-run-session (private bus). Arguments: --inner <variant> <outdir>.
# ---------------------------------------------------------------------------------------------------------------
inner() {
  local v=$1 out=$2
  local sock sig
  . "$root/scripts/dev/pidfile.sh"
  # The outer part hands this tree's nested instance in WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE (for the clients),
  # so the "never the owner's instance" comparison must use the environment the outer part itself was started with
  # (GF_OUTER_SIG / GF_OUTER_WL), else dev_nested_target refuses the very instance it was given (GF-075).
  read -r sock sig < <(
    export HYPRLAND_INSTANCE_SIGNATURE=${GF_OUTER_SIG:-} WAYLAND_DISPLAY=${GF_OUTER_WL:-}
    dev_nested_target "$dev" && echo "$DEV_NESTED_SOCK $DEV_NESTED_SIG"
  )
  [[ -n ${sock:-} && -n ${sig:-} ]] || return 2
  if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} || $DBUS_SESSION_BUS_ADDRESS == "${GF_OUTER_BUS:-}" ]]; then
    echo "inner: not on a private bus; refusing" >&2
    return 2
  fi
  export GRASSFIELD_PRIVATE_BUS=1
  reg_pid="" app_pid="" # globals: the EXIT trap runs after inner() returns
  echo "$DBUS_SESSION_BUS_ADDRESS" >"$out/bus.address"

  start_registrar() {
    "$dev/build/fake-registrar" >"$out/registrar.log" 2>&1 &
    reg_pid=$!
    echo "$reg_pid" >>"$out/pids"
    for _ in $(seq 1 30); do grep -q owning "$out/registrar.log" 2>/dev/null && return 0; sleep 0.1; done
    echo "inner: registrar did not start" >&2
    return 1
  }
  stop_all() {
    [[ -n $app_pid ]] && kill "$app_pid" 2>/dev/null
    [[ -n $reg_pid ]] && kill "$reg_pid" 2>/dev/null
    wait 2>/dev/null
  }
  trap stop_all EXIT

  if [[ $v == edge-cases ]]; then
    WAYLAND_DISPLAY=$sock "$dev/build/appmenu-client" >"$out/app.out" 2>&1
    printf 'address=\nservice=\npath=\nclient-exit=%s\n' "$?" >"$out/result.env"
    return 0
  fi

  case $v in
    qt-no-registrar | qt-late-registrar | chromium-no-registrar) ;;
    *) start_registrar || return 1 ;;
  esac

  # Clean, explicit Qt environment: the owner's QT_QPA_PLATFORMTHEME and KDE variables are not inherited.
  # (The private bus has no service activation, so no portal can start; see private_bus_config.)
  local app_env=(env -u QT_QPA_PLATFORMTHEME -u KDE_SESSION_VERSION -u KDE_FULL_SESSION
    WAYLAND_DISPLAY="$sock" QT_QPA_PLATFORM=wayland WAYLAND_DEBUG=1)
  case $v in
    qt-gtk3) app_env+=(QT_QPA_PLATFORMTHEME=gtk3) ;;
    qt-portal) app_env+=(QT_QPA_PLATFORMTHEME=xdgdesktopportal) ;;
    qt-kde) app_env+=(XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true) ;;
    qt-no-global) app_env+=(QT_WAYLAND_DISABLED_INTERFACES=org_kde_kwin_appmenu_manager) ;;
  esac

  if [[ $v == chromium* ]]; then
    # The browser binary itself, not the /usr/bin launcher (which adds the owner's chromium-flags.conf).
    # Only the browser process talks to Wayland; its WAYLAND_DEBUG output is filtered after the run.
    WAYLAND_DISPLAY=$sock WAYLAND_DEBUG=1 setsid "$root/scripts/dev/isolated.sh" --name appmenu-chromium /usr/lib/chromium/chromium --ozone-platform=wayland --user-data-dir="$out/profile" \
      --no-first-run --no-default-browser-check --password-store=basic --disable-sync about:blank \
      >"$out/app.out" 2>"$out/wayland-debug.full" </dev/null &
    app_pid=$!
    echo "$app_pid" >>"$out/pids"
    sleep 12
  else
    "${app_env[@]}" "$dev/build/menu-demo" --log "$out/actions.log" >"$out/app.out" 2>"$out/wayland-debug.full" </dev/null &
    app_pid=$!
    echo "$app_pid" >>"$out/pids"
    if [[ $v == qt-late-registrar ]]; then
      sleep 3
      start_registrar || return 1
    fi
    for _ in $(seq 1 80); do grep -q 'menu-demo: platform=' "$out/app.out" 2>/dev/null && break; sleep 0.1; done
    sleep 1
  fi
  grep -a -E 'appmenu' "$out/wayland-debug.full" >"$out/wayland-debug.log" 2>/dev/null

  # The app's window and its appmenu registration (as the client sent it).
  local address set_line service="" path=""
  address=$(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients | jq -r --argjson p "$app_pid" '[.[] | select(.pid == $p)][0].address // ""')
  set_line=$(grep -a -o 'org_kde_kwin_appmenu#[0-9]*\.set_address("[^"]*", "[^"]*")' "$out/wayland-debug.log" | tail -n 1)
  if [[ -n $set_line ]]; then
    service=$(sed -E 's/.*set_address\("([^"]*)", "([^"]*)"\)/\1/' <<<"$set_line")
    path=$(sed -E 's/.*set_address\("([^"]*)", "([^"]*)"\)/\2/' <<<"$set_line")
  fi
  printf 'address=%s\nservice=%s\npath=%s\n' "${address#0x}" "$service" "$path" >"$out/result.env"

  if [[ -n $service && -n $path ]]; then
    timeout 5 gdbus introspect --session --dest "$service" --object-path "$path" >"$out/introspect.txt" 2>&1
    timeout 5 gdbus call --session --dest "$service" --object-path "$path" --method com.canonical.dbusmenu.GetLayout -- 'int32 0' 'int32 -1' '@as []' >"$out/layout.txt" 2>&1
  fi

  item() { # <Python regex matching a whole exported label (mnemonic "_")>: the DBusMenu id of the first match
    python3 -I - "$1" "$out/layout.txt" <<'PY'
import re, sys
pattern, layout = sys.argv[1], sys.argv[2]
for m in re.finditer(r"\((\d+), \{[^}]*?'label': <'([^']*)'>", open(layout).read()):
    if re.fullmatch(pattern, m.group(2)):
        print(m.group(1))
        break
PY
  }
  click() { # <id>
    timeout 5 gdbus call --session --dest "$service" --object-path "$path" --method com.canonical.dbusmenu.Event -- "int32 $1" clicked '<int32 0>' 'uint32 0' >>"$out/dbusmenu-calls.txt" 2>&1
  }

  if [[ $v == chromium && -n $service ]]; then
    # A real browser command through DBusMenu: File > New Window must open a second window.
    local nw_id
    nw_id=$(item '_?New _?[Ww]indow')
    echo "ids: new-window=$nw_id" >>"$out/dbusmenu-calls.txt"
    if [[ -n $nw_id ]]; then
      click "$nw_id"
      sleep 3
      echo "windows-after-new-window=$(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients | jq --argjson p "$app_pid" '[.[] | select(.pid == $p)] | length')" >>"$out/result.env"
    fi
  fi

  if [[ $v == qt-registrar && -n $service ]]; then
    local new_id dark_id quit_id theme_id
    new_id=$(item _New) theme_id=$(item _Theme) dark_id=$(item Dark) quit_id=$(item _Quit)
    echo "ids: new=$new_id theme=$theme_id dark=$dark_id quit=$quit_id" >>"$out/dbusmenu-calls.txt"
    [[ -n $theme_id ]] && timeout 5 gdbus call --session --dest "$service" --object-path "$path" --method com.canonical.dbusmenu.AboutToShow "int32 $theme_id" >>"$out/dbusmenu-calls.txt" 2>&1
    [[ -n $new_id ]] && click "$new_id"
    [[ -n $dark_id ]] && click "$dark_id"
    sleep 0.5
    # Re-emit through the shell's channel (one event expected for the valid address only).
    if command -v qs >/dev/null && [[ -n $address ]]; then
      WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig GF_APPMENU_ADDRESS=${address#0x} QT_QPA_PLATFORM=wayland \
        timeout 15 qs -p "$root/tests/compositor/appmenu-reemit" --no-color >"$out/reemit.log" 2>&1
    fi
    echo "quit-at=${EPOCHREALTIME/./}" >>"$out/result.env"
    [[ -n $quit_id ]] && click "$quit_id"
    for _ in $(seq 1 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$app_pid" 2>/dev/null && echo "app-still-running-after-quit=1" >>"$out/result.env"
  fi

  if [[ $v == chromium* ]]; then
    kill -- "-$app_pid" 2>/dev/null
    sleep 2
    kill -9 -- "-$app_pid" 2>/dev/null
    rm -f "$out/wayland-debug.full" # tens of MB of frame traffic; the appmenu lines are kept
  fi
  return 0
}

if [[ ${1:-} == --inner ]]; then
  inner "$2" "$3"
  exit $?
fi

# ---------------------------------------------------------------------------------------------------------------
# Outer part.
# ---------------------------------------------------------------------------------------------------------------
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh): a stale record
# may name another worktree's session.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "appmenu: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "appmenu: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat dbus-run-session gdbus jq python3; do
  command -v "$tool" >/dev/null || { echo "appmenu: $tool is needed" >&2; exit 2; }
done
query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only queries only
query grassfield | jq -e '.features | index("appmenu")' >/dev/null 2>&1 \
  || { echo "appmenu: the loaded plugin does not advertise \"appmenu\"" >&2; exit 2; }
if [[ ! -x $dev/build/menu-demo || ! -x $dev/build/fake-registrar || ! -x $dev/build/appmenu-client ]]; then
  "$root/tests/fixtures/build.sh" >/dev/null || { echo "appmenu: fixture build failed" >&2; exit 2; }
fi

variants=("$@")
((${#variants[@]} > 0)) || variants=(qt-registrar edge-cases qt-no-registrar qt-late-registrar qt-gtk3 qt-portal qt-kde qt-no-global)
for v in "${variants[@]}"; do
  case $v in qt-registrar | qt-no-registrar | qt-late-registrar | qt-gtk3 | qt-portal | qt-kde | qt-no-global | chromium | chromium-no-registrar | edge-cases) ;;
    *) echo "appmenu: unknown variant $v" >&2; exit 2 ;; esac
done
if [[ " ${variants[*]} " == *" chromium "* && ! -x /usr/lib/chromium/chromium ]]; then
  echo "appmenu: chromium is not installed" >&2
  exit 2
fi

run=$dev/appmenu/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
events=$run/events.log
summary=$run/summary.txt

# Private session bus without service activation (no <servicedir>): nothing from /usr/share/dbus-1/services
# (portals, ...) can be started on it, with whatever environment the bus would pass them.
private_bus_config=$run/private-bus.conf
cat >"$private_bus_config" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF

socat_pid=""
cleanup() {
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  # Leftover fixture processes of this run (each variant records its PIDs; a timed-out bus leaves orphans).
  local f p
  for f in "$run"/*/pids; do
    [[ -f $f ]] || continue
    while read -r p; do kill "$p" 2>/dev/null; done <"$f"
  done
  # Chromium helpers may leave the process group: find them by this run's unique profile path only.
  pgrep -f -- "$run/chromium/profile" >/dev/null 2>&1 && pkill -f -- "$run/chromium/profile"
  rm -f "$run"/*/wayland-debug.full
}
trap cleanup EXIT

stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$run/socat.err" </dev/null > >(stamp_events >"$events") &
socat_pid=$!
sleep 0.3

say() { printf '%s\n' "$*" | tee -a "$summary"; }
fail=0
say "appmenu run $run (nested $sig, plugin features: $(query grassfield | jq -c .features))"

for v in "${variants[@]}"; do
  out=$run/$v
  mkdir -p "$out"
  t0=${EPOCHREALTIME/./}
  GF_OUTER_BUS=${DBUS_SESSION_BUS_ADDRESS:-} GF_OUTER_SIG=${HYPRLAND_INSTANCE_SIGNATURE:-} GF_OUTER_WL=${WAYLAND_DISPLAY:-} \
    WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    timeout 90 dbus-run-session --config-file="$private_bus_config" -- "$self" --inner "$v" "$out" >"$out/inner.log" 2>&1
  rc=$?
  sleep 0.5
  t1=${EPOCHREALTIME/./}
  address="" service="" path="" quit_at=""
  # shellcheck disable=SC1091
  [[ -f $out/result.env ]] && { address=$(sed -n 's/^address=//p' "$out/result.env"); service=$(sed -n 's/^service=//p' "$out/result.env"); path=$(sed -n 's/^path=//p' "$out/result.env"); quit_at=$(sed -n 's/^quit-at=//p' "$out/result.env"); }
  awk -v a="$t0" -v b="$t1" '$1 >= a && $1 <= b' "$events" | grep -a '"type":"appmenu"' >"$out/events.log"
  binds=$(grep -a -c -- '-> org_kde_kwin_appmenu' "$out/wayland-debug.log" 2>/dev/null)
  bind_line=$(grep -a -o 'wl_registry#[0-9]*\.bind([0-9]*, "org_kde_kwin_appmenu_manager", [0-9]*' "$out/wayland-debug.log" 2>/dev/null | head -n 1)
  platform=$(grep -a -m1 'menu-demo: platform=' "$out/app.out" 2>/dev/null | sed 's/^menu-demo: //')
  reg_calls=$(grep -a -c 'RegisterWindow' "$out/registrar.log" 2>/dev/null)
  say ""
  say "[$v] inner exit $rc"
  [[ -n $platform ]] && say "  app: $platform"
  set_desc=none
  [[ -n $service ]] && set_desc="$service $path (last)"
  say "  bind: ${bind_line:-none}; appmenu requests seen: ${binds:-0}; set_address: $set_desc"
  say "  registrar RegisterWindow calls: ${reg_calls:-0} ($(grep -a -m1 RegisterWindow "$out/registrar.log" 2>/dev/null | sed 's/^fake-registrar: //'))"
  say "  window: ${address:-none}; plugin appmenu events in this variant: $(wc -l <"$out/events.log")"
  sed 's/^[0-9]* /    /' "$out/events.log" | tee -a "$summary"
  if [[ -n $service && -s $out/introspect.txt ]]; then
    say "  dbusmenu: $(grep -c 'interface com.canonical.dbusmenu' "$out/introspect.txt") com.canonical.dbusmenu interface(s) in introspection; layout labels: $(grep -o "'label': <'[^']*'>" "$out/layout.txt" | sed "s/'label': <'\\([^']*\\)'>/\\1/" | tr '\n' '|' | head -c 300)"
  fi
  nw=$(sed -n 's/^windows-after-new-window=//p' "$out/result.env" 2>/dev/null)
  [[ -n $nw ]] && say "  DBusMenu click on File > New window: the browser now has $nw window(s)"

  check() { if eval "$2"; then say "  PASS $1"; else say "  FAIL $1"; ok=0; fi; }
  if [[ $v == edge-cases ]]; then
    ok=1
    sed 's/^appmenu-client: /    /' "$out/app.out" | tee -a "$summary"
    check "no protocol error for invalid requests, two objects, v2 manager release" "grep -q '^client-exit=0' '$out/result.env' && grep -q 'appmenu-client: PASS' '$out/app.out'"
    check "manager bound at version 2" "grep -q 'bound version 2' '$out/app.out'"
    check "no appmenu event for a surface that is not a window" "[[ ! -s '$out/events.log' ]]"
    ((ok)) || fail=1
  fi

  if [[ $v == qt-registrar ]]; then
    ok=1
    check "client called set_address" '[[ -n $service && -n $path ]]'
    check "plugin event carries the window, service and path" "grep -a -q '\"address\":\"$address\",\"service\":\"$service\",\"path\":\"$path\"' '$out/events.log'"
    check "menus exported over com.canonical.dbusmenu" "grep -q 'interface com.canonical.dbusmenu' '$out/introspect.txt'"
    check "DBusMenu click ran File > New" "grep -q 'file.new' '$out/actions.log' 2>/dev/null"
    check "DBusMenu click ran View > Theme > Dark (submenu)" "grep -q 'view.theme.dark' '$out/actions.log' 2>/dev/null"
    if [[ -s $out/reemit.log ]]; then
      # Three calls (valid window, "0xnot-hex", "0x1"): exactly one event, for the window.
      check "re-emit: one event, for the valid window only" "[[ \$(grep -a -c 'rawEvent grassfield>>{\"v\":\"gfc/1\",\"type\":\"appmenu\"' '$out/reemit.log') -eq 1 ]] && grep -a -q '\"address\":\"$address\",\"service\":\"$service\",\"path\":\"$path\"' '$out/reemit.log'"
    fi
    check "File > Quit through DBusMenu closed the app" "! grep -q 'app-still-running-after-quit' '$out/result.env' && grep -q 'file.quit' '$out/actions.log'"
    check "clear event after the window closed" "awk -v q='${quit_at:-0}' '\$1 >= q' '$out/events.log' | grep -a -q '\"address\":\"$address\",\"service\":\"\",\"path\":\"\"'"
    ((ok)) || fail=1
  fi
done

say ""
if ! kill -0 "$hypr_pid" 2>/dev/null; then
  say "FAIL: nested Hyprland died"
  fail=1
fi
say "plugin log (appmenu lines of this run):"
grep -a 'appmenu' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log" | tail -n 12 | sed 's/^/    /' | tee -a "$summary"
if ((fail)); then
  say "RESULT: FAIL (summary $summary)"
  exit 1
fi
say "RESULT: PASS (summary $summary)"
exit 0
