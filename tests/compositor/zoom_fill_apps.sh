#!/usr/bin/env bash
# Zoom is Fill for the apps that draw their own chrome (ADR-0036 D78, ADR-0015 Q4 amended; opus review of fix/zoom-is-fill,
# MAJOR: Settings' own green light glued it in Hyprland's maximized mode at (1,25) 1918x1054 while Window > Zoom filled it,
# and the window never came back to its 740x690). Grassfield's Settings and Files, each in turn, through every way a user
# zooms them; each gives Fill (fullscreen 0, every gap to the work area tiling.margin, 8, up to the scale's grid - 1 wider;
# no titlebar band for client chrome) and the same way again brings back the box the window had:
#   own light      the app's own green light (its xdg maximize request, which the plugin owns while window-tiling is
#                  advertised: SUPPRESS_MAXIMIZE for Hyprland, gf::tiler::zoom for the plugin)
#   double-click   a double-click on empty toolbar space with windows.titlebarDoubleClick removed from the settings file the
#                  apps read (the default, fill), then set to zoom (both are the app's zoom request)
#   window menu    Window > Zoom of the menu bar (tests/visual/ipc.sh menubar open appwindow, then Down, Down, Return)
#   popover        the green light clicked under its open tiling popover (D64; tile_popover opens it)
#   no-plugin      (last) the plugin unloaded through scripts/nestctl: the app's own green light is Hyprland's maximized mode
#                  again (fullscreen 1) and back (gate C2: the unload cleared what the plugin set); the plugin loaded again
# Usage (bare command; nested session of this tree with the plugin and the shell, e.g. scripts/dev/nested-up.sh --private-bus
# --ref-scale 1.25; apps/settings/build-direct.sh and apps/files/build-direct.sh built): tests/compositor/zoom_fill_apps.sh
# The apps read the nested shell's settings file (.dev/config/grassfield.json, restored at exit). A press that changed nothing
# within 2 s is made once more (logged; the reviewer's first zoom_fill run lost one click). Exit: 0 PASS, 1 FAIL, 2 usage or
# environment error. Logs and captures: .dev/zoom-fill-apps/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=GF-REF
plugin_so=$root/compositor/build/grassfield-compositor.so
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "zoom_fill_apps: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "zoom_fill_apps: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for app in settings files; do
  [[ -x $dev/build/grassfield-$app ]] || { echo "zoom_fill_apps: build the app first: apps/$app/build-direct.sh" >&2; exit 2; }
done
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "zoom_fill_apps: grassfield-shell is not running" >&2; exit 2; }

run=$dev/zoom-fill-apps/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ipc() { timeout 10 "$root/tests/visual/ipc.sh" "$@" 2>>"$log"; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
shot() { "$root/scripts/dev/shot.sh" "$1" "$out" >>"$log" 2>&1 && cp "$dev/shots/$1.png" "$run/" 2>/dev/null && say "  capture $run/$1.png"; }
fail=0 passed=0 failed=0
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; passed=$((passed + 1)); else say "FAIL: $name"; fail=1; failed=$((failed + 1)); fi
}
has_feature() { nestctl -j grassfield 2>/dev/null | jq -e --arg f "$1" '.features | index($f)' >/dev/null 2>&1; }
has_feature zoom-fill || { say "SKIP: the plugin does not advertise zoom-fill (load this tree's plugin)"; exit 2; }

settings=$dev/config/grassfield.json
backup=$run/settings.backup
had_settings=0
[[ -f $settings ]] && { cp "$settings" "$backup"; had_settings=1; }
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
  has_feature window-tiling || nestctl plugin load "$plugin_so" >/dev/null 2>&1
}
trap cleanup EXIT
set_double_click() { # default|zoom: the settings file the apps and the shell read
  mkdir -p "$dev/config"
  local base=$root/config/defaults/grassfield.json
  ((had_settings)) && base=$backup
  if [[ $1 == default ]]; then
    jq 'del(.windows.titlebarDoubleClick)' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  else
    jq --arg v "$1" '.windows.titlebarDoubleClick = $v' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  fi
  sleep 1.5
}

# "ox oy lw lh scale g ax ay aw ah" of the output: logical origin and size, scale, grid step (tiling.md TL3), work area.
output_facts() {
  nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o)
    | (.width / .scale + 0.5 | floor) as $lw | (.height / .scale + 0.5 | floor) as $lh
    | (.scale * 120 + 0.5 | floor) as $s
    | def gcd(a; b): if b == 0 then a else gcd(b; a % b) end;
      (120 / gcd($s; 120)) as $g
    | "\(.x) \(.y) \($lw) \($lh) \(.scale) \($g) \(.x + .reserved[0]) \(.y + .reserved[1]) \($lw - .reserved[0] - .reserved[2]) \($lh - .reserved[1] - .reserved[3])"'
}
class="" addr=""
geometry() { nestctl clients -j | jq -r --arg c "$class" '[.[] | select(.class == $c)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.fullscreen) \(.address)"'; }
settled_box() {
  local a b
  for _ in $(seq 1 15); do
    a=$(geometry) && sleep 0.2 && b=$(geometry)
    [[ -n $a && $a == "$b" ]] && return 0
  done
  return 0
}
# Fill: fullscreen 0 and every gap to the work area tiling.margin (8), up to g - 1 wider (no titlebar band: client chrome).
filled() { # label
  local x y w h fs _a ox oy lw lh sc g ax ay aw ah l t r b
  read -r x y w h fs _a < <(geometry)
  read -r ox oy lw lh sc g ax ay aw ah < <(output_facts)
  l=$((x - ax)) t=$((y - ay)) r=$((ax + aw - x - w)) b=$((ay + ah - y - h))
  say "  $1: ${w}x${h} at $x,$y fullscreen $fs; work area ${aw}x${ah} at $ax,$ay (scale $sc, grid $g); gaps $l $t $r $b (want 8..$((8 + g - 1)))"
  ((fs == 0 && l >= 8 && l < 8 + g && t >= 8 && t < 8 + g && r >= 8 && r < 8 + g && b >= 8 && b < 8 + g))
}
at_start() { # label
  local x y w h fs _a
  read -r x y w h fs _a < <(geometry)
  say "  $1: ${w}x${h} at $x,$y fullscreen $fs (want ${w0}x${h0} at $x0,$y0, fullscreen 0)"
  ((fs == 0 && x == x0 && y == y0 && w == w0 && h == h0))
}
fs_is() { local _x _y w h fs _a; read -r _x _y w h fs _a < <(geometry); say "  ${w}x${h} fullscreen $fs (want $1)"; [[ $fs == "$1" ]]; }
light_c=$(jq -r '.window.unifiedLightCentre.value' "$root/ui/tokens/tokens.json")
pitch=$(jq -r '.window | .lightDiameter.value + .lightGap.value' "$root/ui/tokens/tokens.json")
# The app's zoom light and an empty spot of its toolbar, relative to the output.
zoom_light() { local x y _r ox oy; read -r x y _r < <(geometry); read -r ox oy _r < <(output_facts); echo "$((x + light_c + 2 * pitch - ox)) $((y + light_c - oy))"; }
empty_spot() { # Settings: the detail pane's toolbar right of its title (client_chrome.sh); Files: its sidebar's toolbar right of the lights
  local x y w _r ox oy
  read -r x y w _r < <(geometry)
  read -r ox oy _r < <(output_facts)
  if [[ $class == org.grassfield.Settings ]]; then echo "$((x + w - 120 - ox)) $((y + 26 - oy))"; else echo "$((x + light_c + 2 * pitch + 40 - ox)) $((y + 22 - oy))"; fi
}
popup_open() { [[ $(ipc menubar openKind) == *@* ]]; }
close_popup() {
  local _try
  for _try in 1 2 3 4; do
    popup_open || return 0
    keys -k Escape
    sleep 0.5
  done
}
# A press sequence that should change the box; made once more when it changed nothing within 2 s (logged).
act() { # label command...
  local label=$1 before try
  shift
  settled_box
  before=$(geometry)
  for try in 1 2; do
    "$@"
    for _ in $(seq 1 20); do [[ $(geometry) != "$before" ]] && break; sleep 0.1; done
    [[ $(geometry) != "$before" ]] && break
    say "  $label: nothing changed within 2 s: once more ($try)"
    close_popup
    sleep 0.5
  done
  sleep 0.8
  close_popup
}
own_light() { local lx ly; read -r lx ly < <(zoom_light); pointer abs "$lx" "$ly" sleep 300 click sleep 100 abs $((lx + 300)) $((ly + 300)); }
double_click() { local ex ey; read -r ex ey < <(empty_spot); pointer abs "$ex" "$ey" sleep 300 click sleep 60 click sleep 100 abs $((ex + 200)) $((ey + 300)); }
window_menu() {
  nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.4
  ipc menubar open appwindow "$out" >/dev/null
  for _ in $(seq 1 20); do [[ $(ipc menubar openKind) == appwindow@* ]] && break; sleep 0.1; done
  keys -k Down
  keys -k Down
  keys -k Return
}
popover_light() {
  local lx ly
  nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr\")" >>"$log" 2>&1
  for _ in $(seq 1 30); do [[ $(ipc menubar openKind) == tiling@* ]] && break; sleep 0.1; done
  say "  popover: open kind '$(ipc menubar openKind)'"
  read -r lx ly < <(zoom_light)
  pointer abs "$lx" "$ly" sleep 100 down sleep 80 up sleep 200 abs $((lx + 300)) $((ly + 300))
}

launch() { # settings|files
  pointer abs 700 450 sleep 50 # windows open on the output under the pointer
  if [[ $1 == settings ]]; then
    WAYLAND_DISPLAY=$sock GRASSFIELD_SETTINGS_QML="$root/apps/settings/qml" QML_IMPORT_PATH="$root/ui:$dev/build/qml" \
      setsid "$root/scripts/dev/isolated.sh" --name zoom-fill-apps --config-home "$dev/config" -- "$dev/build/grassfield-settings" >>"$log" 2>&1 </dev/null &
  else
    mkdir -p "$dev/zoom-fill-apps/folder"
    WAYLAND_DISPLAY=$sock GRASSFIELD_FILES_QML="$root/apps/files/qml" QML_IMPORT_PATH="$root/ui:$dev/build/qml" \
      setsid "$root/scripts/dev/isolated.sh" --name zoom-fill-apps --config-home "$dev/config" -- "$dev/build/grassfield-files" "$dev/zoom-fill-apps/folder" >>"$log" 2>&1 </dev/null &
  fi
  pids+=("$!")
  for _ in $(seq 1 60); do [[ -n $(geometry) ]] && break; sleep 0.25; done
  sleep 1.5
}

# A settled session first (a run right after nested-up zoomed Settings before the Dock reserved its zone:
# Fill takes the work area of that moment, TL1): the menu bar mapped and the reserved area unchanged for 1 s (at most 15 s).
settle_state() { nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "reserved \(.reserved) desktop \(.activeWorkspace.id)"'; }
menubar_on() { nestctl layers -j 2>/dev/null | jq -e --arg o "$out" '[.[$o] | .. | objects | select(.namespace? == "grassfield-menubar")] | length > 0' >/dev/null 2>&1; }
for _ in $(seq 1 40); do menubar_on && break; sleep 0.25; done
prev="" same=0
for _ in $(seq 1 60); do
  cur=$(settle_state)
  if [[ -n $cur && $cur == "$prev" ]]; then same=$((same + 1)); else same=0; prev=$cur; fi
  ((same >= 4)) && break
  sleep 0.25
done
say "zoom_fill_apps: nested pid $hypr_pid, instance $sig, output $out: $(output_facts) (${prev:-not settled})"
for app in settings files; do
  class=org.grassfield.${app^}
  say "$app"
  launch "$app"
  read -r x0 y0 w0 h0 fs0 addr < <(geometry)
  if [[ -z ${addr:-} ]]; then
    check "$app: the window mapped" false
    continue
  fi
  tags=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .tags | join(",")')
  check "$app: client chrome (tags $tags)" test "${tags#*grassfield-client-chrome}" != "$tags"
  say "  $app: ${w0}x${h0} at $x0,$y0 fullscreen $fs0"
  set_double_click default
  read -r x0 y0 w0 h0 fs0 addr < <(geometry)
  for way in own_light double_click double_click_zoom window_menu popover_light; do
    fn=$way
    if [[ $way == double_click_zoom ]]; then set_double_click zoom; fn=double_click; fi
    act "$app $way" "$fn"
    check "$app: $way fills the window (Fill, the margins)" filled "$app $way"
    [[ $way == own_light && $app == settings ]] && shot zoom-fill-apps-settings-own-light
    [[ $way == own_light && $app == files ]] && shot zoom-fill-apps-files-own-light
    act "$app $way back" "$fn"
    check "$app: $way again brings back its box" at_start "$app $way back"
  done
  set_double_click default
done

say "no-plugin"
class=org.grassfield.Settings
read -r x0 y0 w0 h0 fs0 addr < <(geometry)
if nestctl plugin unload "$plugin_so" >>"$log" 2>&1; then
  sleep 1.5
  check "no-plugin: the plugin is gone" bash -c '! "$1/scripts/nestctl" -j grassfield 2>/dev/null | jq -e ".features" >/dev/null 2>&1' _ "$root"
  act "no-plugin own light" own_light
  check "no-plugin: Settings' own green light is Hyprland's maximized mode again (gate C2)" fs_is 1
  shot zoom-fill-apps-no-plugin
  act "no-plugin own light back" own_light
  check "no-plugin: its own light again: its box back" at_start "no-plugin back"
  nestctl plugin load "$plugin_so" >>"$log" 2>&1
  sleep 2
  check "no-plugin: the plugin loaded again advertises zoom-fill" has_feature zoom-fill
  act "reloaded own light" own_light
  check "reloaded: Settings' own green light fills again (the plugin owns its request again)" filled "reloaded"
  act "reloaded own light back" own_light
  check "reloaded: and back" at_start "reloaded back"
else
  check "no-plugin: scripts/nestctl unloaded the plugin" false
fi

kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" test $? -eq 0
say "zoom_fill_apps: $passed passed, $failed failed"
if ((fail == 0)); then say "zoom_fill_apps: PASS"; else say "zoom_fill_apps: FAIL"; fi
say "zoom_fill_apps: log $log"
exit "$fail"
