#!/usr/bin/env bash
# Zoom is Fill (ADR-0036 D78, docs/specs/tiling.md TL35). Owner report on rc1-16: a maximized foot window sat glued under the
# menu bar and against the left edge of eDP-1 (1920x1080 at scale 1.25, reserved [0, 24, 0, 65]), in Hyprland's maximized
# mode at [1, 57] 1534x741. Grassfield's Zoom now fills the window as a tile, inside the work area with the margins of
# "Tiled windows have margins" (tiling.margin, 8), and a second Zoom brings back its box from before (macOS 15+).
#
# Usage (bare command, nested session of this tree running with the plugin loaded): tests/compositor/zoom_fill.sh [--no-scale]
# One foot window with the plugin's titlebar. Expected frames come from the output's reserved area read right before each
# zoom (TL1): every gap between the frame (the surface plus the titlebar band GF_TB_HEIGHT) and the work area's edge is the
# margin, up to g - 1 px wider where an edge of the work area is off the scale's grid (TL3: g 1 at scale 1, 4 at 1.25);
# without margins it is 0 to g - 1.
#   light          the zoom light: Fill (fullscreen 0), the gaps of the margin under the menu bar and at the edges, a tile
#                  record placed "fill" (captured); the light again: the box from before, no record
#   margins off    config tilingMargins false: the frame touches the work area's edges (captured), as macOS then; back; true
#   keys           Super+Alt+F (bindings.lua asks the plugin's window_size("maximized"), which zooms itself): Fill; again: back
#   maximized      the window in Hyprland's maximized mode by Hyprland's own dispatcher (an older binding, another client):
#                  Super+Alt+F takes it out into Fill (fullscreen 0, the margins); again: back to its box from before
#   verb           tile(address, "zoom") (feature zoom-fill: Window > Zoom, the light clicked under its popover): Fill; again:
#                  back
#   double-click   (with the shell) windows.titlebarDoubleClick removed from the dev settings file: the shell pushes its
#                  default, "fill" (the plugin logs "titlebar double-click -> fill"); a double-click on the bar fills, a second
#                  brings back the box
#   alt-zoom       Alt held (tests/tools/vkbd), a click on the zoom light: true full screen (fullscreen 2), not Fill; out again
#   scale 1.25     (skipped with --no-scale) a headless output GF-ZOOM made by scripts/nestctl with a monitor rule at scale 1.25
#                  (1920x1080: 1536x864 logical, the owner's eDP-1): the window moved there, the zoom light: the margins on
#                  the 4 px grid (captured), and back. Then move-to (review of fix/zoom-is-fill, MINOR): the window filled on
#                  GF-REF, move_to GF-ZOOM keeps it filled there, and Zoom brings back its size from before on GF-ZOOM, on
#                  GF-ZOOM's Desktop (it went back to GF-REF while its Desktop stayed GF-ZOOM's); the output removed
#   reload         (review, MINOR) the window filled, the plugin unloaded and loaded again (its tile records are gone): Zoom
#                  unfills it to the Center place's frame (no box from before is known), the next Zoom fills it, the one
#                  after brings back that frame
#   no-plugin      (last) the plugin unloaded through scripts/nestctl: Super+Alt+F is Hyprland's maximized mode (fullscreen 1),
#                  again: back (gate C2: bindings.lua's own dispatcher); the plugin loaded again and advertising zoom-fill
# A click on a zoom light that changed nothing within 2 s (it came while the bar still moved: the reviewer's first run lost
# one) is logged and made once more after the pointer rested on the light again; a second miss fails the check.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Logs and captures: .dev/zoom-fill/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
scale_case=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-scale) scale_case=0 ;;
    *) echo "usage: tests/compositor/zoom_fill.sh [--no-scale]" >&2; exit 2 ;;
  esac
  shift
done
dev=$root/.dev
out=GF-REF
plugin_so=$root/compositor/build/grassfield-compositor.so
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "zoom_fill: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "zoom_fill: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)

run=$dev/zoom-fill/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { local o=$1; shift; timeout 30 "$root/scripts/dev/pointer.sh" output "$o" "$@" >>"$log" 2>&1; }
shot() { "$root/scripts/dev/shot.sh" "$1" "$2" >>"$log" 2>&1 && cp "$dev/shots/$1.png" "$run/" 2>/dev/null && say "  capture $run/$1.png"; }
fail=0 passed=0 failed=0
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; passed=$((passed + 1)); else say "FAIL: $name"; fail=1; failed=$((failed + 1)); fi
}
plugin_logged() { # pattern (Hyprland's in-memory log, polled up to 3 s)
  local _ l
  for _ in $(seq 1 15); do
    l=$(nestctl rollinglog 2>/dev/null)
    grep -aq -- "$1" <<<"$l" && return 0
    sleep 0.2
  done
  return 1
}
has_feature() { nestctl -j grassfield 2>/dev/null | jq -e --arg f "$1" '.features | index($f)' >/dev/null 2>&1; }
# The chords go through tests/tools/vkbd (keysyms; the last one tapped with the others held), as tests/compositor/tiling.sh
# "fixed keys" does: wtype's modifiers never reach Hyprland's binds.
chord() {
  local args=() mods=() k last=$# i=0
  for k in "$@"; do
    i=$((i + 1))
    if ((i < last)); then args+=(down "$k" sleep 60); mods=("$k" "${mods[@]}"); else args+=(tap "$k" sleep 60); fi
  done
  for k in "${mods[@]}"; do args+=(up "$k"); done
  timeout 20 "$root/tests/tools/vkbd/vkbd.sh" "${args[@]}" >>"$log" 2>&1
}

has_feature window-tiling || { say "SKIP: the plugin does not advertise window-tiling (load this tree's plugin)"; exit 2; }
zoom_fill_follows() { nestctl -j grassfield 2>/dev/null | jq -e '.features as $f | ($f | index("window-tiling")) + 1 == ($f | index("zoom-fill"))' >/dev/null 2>&1; }
check "the plugin advertises zoom-fill right after window-tiling" zoom_fill_follows

pids=()
settings=$dev/config/grassfield.json
backup=$run/settings.backup
had_settings=0
[[ -f $settings ]] && { cp "$settings" "$backup"; had_settings=1; }
zoom_out=GF-ZOOM
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
  nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"true\")" >/dev/null 2>&1
  nestctl output remove "$zoom_out" >/dev/null 2>&1 || true
  has_feature window-tiling || nestctl plugin load "$plugin_so" >/dev/null 2>&1
}
trap cleanup EXIT
nestctl output remove "$zoom_out" >/dev/null 2>&1 || true # left by an interrupted run

# A settled session: the menu bar on GF-REF (with the shell) and its reserved area unchanged for 1 s.
settle_state() { nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | "reserved \(.reserved) desktop \(.activeWorkspace.id)"'; }
menubar_on() { nestctl layers -j 2>/dev/null | jq -e --arg o "$1" '[.[$o] | .. | objects | select(.namespace? == "grassfield-menubar")] | length > 0' >/dev/null 2>&1; }
settle() { # output: with the shell, its menu bar mapped there first (at most 10 s)
  local prev="" same=0 cur
  if [[ -n $shell_pid ]]; then
    for _ in $(seq 1 40); do menubar_on "$1" && break; sleep 0.25; done
  fi
  for _ in $(seq 1 60); do
    cur=$(settle_state "$1")
    if [[ -n $cur && $cur == "$prev" ]]; then same=$((same + 1)); else same=0; prev=$cur; fi
    ((same >= 4)) && break
    sleep 0.25
  done
  say "  $1 settled: ${prev:-?}"
}
settle "$out"

# "ox oy lw lh scale g ax ay aw ah" of an output: its logical origin and size, its scale, the grid step of TL3, its work area.
output_facts() {
  nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o)
    | (.width / .scale + 0.5 | floor) as $lw | (.height / .scale + 0.5 | floor) as $lh
    | (.scale * 120 + 0.5 | floor) as $s
    | def gcd(a; b): if b == 0 then a else gcd(b; a % b) end;
      (120 / gcd($s; 120)) as $g
    | "\(.x) \(.y) \($lw) \($lh) \(.scale) \($g) \(.x + .reserved[0]) \(.y + .reserved[1]) \($lw - .reserved[0] - .reserved[2]) \($lh - .reserved[1] - .reserved[3])"'
}
title=zoom-fill-foot
geometry() { nestctl clients -j | jq -r --arg t "$title" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.fullscreen) \(.address)"'; }
record_place() { nestctl grassfield-tiling 2>>"$log" | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].place // "none"'; }

# The frame's gaps to the work area of OUTPUT within [lo, lo + g - 1] on every side, fullscreen 0.
gaps_ok() { # output lo label
  local o=$1 lo=$2 x y w h fs _a ox oy lw lh sc g ax ay aw ah left top right bottom hi
  read -r x y w h fs _a < <(geometry)
  read -r ox oy lw lh sc g ax ay aw ah < <(output_facts "$o")
  left=$((x - ax)) top=$((y - GF_TB_HEIGHT - ay)) right=$((ax + aw - x - w)) bottom=$((ay + ah - y - h))
  hi=$((lo + g - 1))
  say "  $3: foot ${w}x${h} at $x,$y fullscreen $fs; work area ${aw}x${ah} at $ax,$ay (scale $sc, grid $g); gaps left $left top $top right $right bottom $bottom (want $lo..$hi)"
  ((fs == 0 && left >= lo && left <= hi && top >= lo && top <= hi && right >= lo && right <= hi && bottom >= lo && bottom <= hi))
}
at_start() { # label
  local x y w h fs _a
  read -r x y w h fs _a < <(geometry)
  say "  $1: foot ${w}x${h} at $x,$y fullscreen $fs (want ${w0}x${h0} at $x0,$y0, fullscreen 0)"
  ((fs == 0 && x == x0 && y == y0 && w == w0 && h == h0))
}
fs_is() { local _x _y _w _h fs _a; read -r _x _y _w _h fs _a < <(geometry); say "  fullscreen $fs (want $1)"; [[ $fs == "$1" ]]; }
light() { # output: the middle of the zoom light of the foot, relative to OUTPUT
  local x y _w _h _fs _a ox oy _r
  read -r x y _w _h _fs _a < <(geometry)
  read -r ox oy _r < <(output_facts "$1")
  echo "$((x + GF_TB_ZOOM_X - ox)) $((y - GF_TB_MID - oy))"
}
# A shell popup on OUTPUT (the overlay mapped): the pointer resting on a zoom light opens the tiling popover (TL22), which
# would take the next click. Closed with Esc, as tests/compositor/tiling.sh close_shell_popup does.
popup_open() { nestctl layers -j 2>/dev/null | jq -e --arg o "$1" '[.[$o].levels // {} | .[][] | select(.namespace == "grassfield-overlay")] | length > 0' >/dev/null 2>&1; }
close_popup() { # output
  local _try
  for _try in 1 2 3 4; do
    popup_open "$1" || return 0
    say "  a shell popup is open on $1: Esc"
    "$root/scripts/dev/keys.sh" -k Escape >>"$log" 2>&1
    sleep 0.5
  done
}
# A click on the zoom light, then the pointer off it at once (a pointer resting there opens the popover after
# tiling.hoverDelay, which would take the next click). The bar must have stopped moving first (its box read twice the same,
# the move's animation over), and the pointer rests on the light before the press; a click that changed nothing within 2 s
# is made once more (logged).
settled_box() { # wait until the foot's box reads the same twice, 200 ms apart (at most 3 s)
  local a b
  for _ in $(seq 1 15); do
    a=$(geometry) && sleep 0.2 && b=$(geometry)
    [[ -n $a && $a == "$b" ]] && return 0
  done
  return 0
}
click_light() { # output
  local lx ly before try
  settled_box
  before=$(geometry)
  for try in 1 2; do
    read -r lx ly < <(light "$1")
    pointer "$1" abs "$lx" "$ly" sleep 300 click sleep 100 abs $((lx + 400)) $((ly + 300))
    for _ in $(seq 1 20); do [[ $(geometry) != "$before" ]] && break; sleep 0.1; done
    close_popup "$1"
    [[ $(geometry) != "$before" ]] && break
    say "  the click on the zoom light at $lx,$ly changed nothing: once more ($try)"
    sleep 0.5
  done
  sleep 0.6
}
place_start() { # output x y (relative to the output): the foot out of any zoom, at a known floating box there
  local ox oy _r fs
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >/dev/null 2>&1
  read -r _r _r _r _r fs _r < <(geometry)
  case ${fs:-0} in
    1) nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$addr\" })" >>"$log" 2>&1 ;;
    2) nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1 ;;
  esac
  sleep 0.5
  read -r ox oy _r < <(output_facts "$1")
  nestctl dispatch "hl.dsp.window.move({ x = $((ox + $2)), y = $((oy + $3)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
  close_popup "$1"
  read -r x0 y0 w0 h0 _fs _a < <(geometry)
  say "  start: foot ${w0}x${h0} at $x0,$y0 on $1"
}

pointer "$out" abs 960 540 sleep 50 # windows open on the output under the pointer
env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name zoom-fill \
  foot -T "$title" -w 800x500 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
pids+=("$!")
for _ in $(seq 1 100); do [[ -n $(geometry) ]] && break; sleep 0.2; done
sleep 1
read -r _x _y _w _h _fs addr < <(geometry)
[[ -n ${addr:-} ]] || { say "setup error: no foot window"; exit 2; }
say "zoom_fill: nested pid $hypr_pid, instance $sig, foot $addr"
place_start "$out" 300 200

say "light"
click_light "$out"
check "light: the zoom light fills the window inside the margins (8 px under the menu bar and at the edges)" gaps_ok "$out" 8 light
check "light: its tile record is placed fill" test "$(record_place "$addr")" = fill
shot zoom-fill-margins "$out"
click_light "$out"
check "light: the zoom light again brings back its box from before" at_start light
check "light: no tile record left" test "$(record_place "$addr")" = none

say "margins off"
nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"false\")" >>"$log" 2>&1
sleep 0.5
click_light "$out"
check "margins off: the frame touches the work area's edges (as macOS without margins)" gaps_ok "$out" 0 "margins off"
shot zoom-fill-no-margins "$out"
click_light "$out"
check "margins off: back to its box" at_start "margins off"
nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"true\")" >>"$log" 2>&1
sleep 0.5

say "keys"
place_start "$out" 300 200
nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
sleep 0.4
chord Super_L Alt_L f
sleep 1
check "keys: Super+Alt+F fills the window with the margins" gaps_ok "$out" 8 keys
chord Super_L Alt_L f
sleep 1
check "keys: Super+Alt+F again brings back its box" at_start keys

say "maximized"
place_start "$out" 300 200
nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:$addr\" })" >>"$log" 2>&1
sleep 1
check "maximized: Hyprland's own dispatcher still maximizes (fullscreen 1)" fs_is 1
nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
sleep 0.3
chord Super_L Alt_L f
sleep 1.2
check "maximized: Super+Alt+F takes it out of the maximized mode into Fill" gaps_ok "$out" 8 maximized
check "maximized: the plugin logged the step" plugin_logged "zoom ${addr#0x}: unzoom-to-fill"
chord Super_L Alt_L f
sleep 1
check "maximized: Super+Alt+F again: the box from before the maximized mode" at_start maximized

say "verb"
place_start "$out" 300 200
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"zoom\")" >>"$log" 2>&1
sleep 1
check "verb: tile(address, \"zoom\") fills" gaps_ok "$out" 8 verb
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"zoom\")" >>"$log" 2>&1
sleep 1
check "verb: again: back" at_start verb

say "double-click"
place_start "$out" 300 200
if [[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null && has_feature tiling-arrange; then
  mkdir -p "$dev/config"
  base=$root/config/defaults/grassfield.json
  ((had_settings)) && base=$backup
  jq 'del(.windows.titlebarDoubleClick)' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  sleep 1.5
  read -r x y _w _h _fs _a < <(geometry)
  read -r ox oy _r < <(output_facts "$out")
  bx=$((x + w0 / 2 - ox)) by=$((y - GF_TB_MID - oy))
  pointer "$out" abs "$bx" "$by" sleep 100 click sleep 60 click sleep 1000
  check "double-click: the default action fills the window" gaps_ok "$out" 8 "double-click"
  check "double-click: the shell pushed the default, fill" plugin_logged "titlebar double-click -> fill"
  read -r x y w _h _fs _a < <(geometry)
  pointer "$out" abs $((x + w / 2 - ox)) $((y - GF_TB_MID - oy)) sleep 100 click sleep 60 click sleep 1000
  check "double-click: a second double-click brings back its box" at_start "double-click"
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
  sleep 1
else
  say "SKIP: double-click default (no shell running or no tiling-arrange: the shell pushes the setting)"
fi

say "alt-zoom"
place_start "$out" 300 200
read -r lx ly < <(light "$out")
pointer "$out" abs "$lx" "$ly" sleep 100
timeout 20 "$root/tests/tools/vkbd/vkbd.sh" down Alt_L sleep 1500 up Alt_L >>"$log" 2>&1 &
keys=$!
sleep 0.5
pointer "$out" click sleep 300 abs 960 700
wait "$keys" 2>/dev/null
sleep 0.8
check "alt-zoom: Alt+zoom light enters true full screen (fullscreen 2), not Fill" fs_is 2
nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
sleep 1
check "alt-zoom: out of full screen, back to its box" at_start "alt-zoom"
close_popup "$out"

if ((scale_case)); then
  say "scale 1.25"
  if nestctl output create headless "$zoom_out" >>"$log" 2>&1; then
    sleep 0.8
    nestctl dispatch "hl.monitor({ output = \"$zoom_out\", mode = \"1920x1080@60\", position = \"auto-right\", scale = 1.25 })" >>"$log" 2>&1
    sleep 1.5
    read -r zox zoy zlw zlh zsc zg _r < <(output_facts "$zoom_out")
    say "  $zoom_out at $zox,$zoy, ${zlw}x${zlh} logical, scale $zsc, grid $zg"
    if [[ ${zsc:-} == 1.25 ]]; then
      settle "$zoom_out"
      place_start "$zoom_out" 200 150
      click_light "$zoom_out"
      check "scale 1.25: the zoom light fills with the margins on the 4 px grid" gaps_ok "$zoom_out" 8 "scale 1.25"
      shot zoom-fill-scale125 "$zoom_out"
      click_light "$zoom_out"
      check "scale 1.25: back to its box" at_start "scale 1.25"
      nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"false\")" >>"$log" 2>&1
      sleep 0.5
      click_light "$zoom_out"
      check "scale 1.25, margins off: the frame touches the work area (within the grid)" gaps_ok "$zoom_out" 0 "scale 1.25 margins off"
      shot zoom-fill-scale125-no-margins "$zoom_out"
      click_light "$zoom_out"
      nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"true\")" >>"$log" 2>&1
      sleep 0.5
      say "move-to"
      place_start "$out" 300 200
      mw0=$w0 mh0=$h0
      click_light "$out"
      check "move-to: filled on $out first" gaps_ok "$out" 8 "move-to fill"
      nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$zoom_out\")" >>"$log" 2>&1
      sleep 1.2
      check "move-to: move_to keeps it filled, on $zoom_out" gaps_ok "$zoom_out" 8 "move-to there"
      click_light "$zoom_out"
      zws=$(nestctl monitors -j | jq -r --arg o "$zoom_out" '.[] | select(.name == $o) | .activeWorkspace.id')
      on_zoom_out() {
        local x y w h fs _a wid zox zoy zlw zlh _r
        read -r x y w h fs _a < <(geometry)
        read -r zox zoy zlw zlh _r < <(output_facts "$zoom_out")
        wid=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')
        say "  move-to: foot ${w}x${h} at $x,$y fullscreen $fs on Desktop $wid; want ${mw0}x${mh0} inside $zoom_out (${zlw}x${zlh} at $zox,$zoy) on its Desktop $zws"
        ((fs == 0 && w == mw0 && h == mh0 && x >= zox && y >= zoy && x + w <= zox + zlw && y + h <= zoy + zlh)) && [[ $wid == "$zws" ]]
      }
      check "move-to: Zoom brings back its size from before on $zoom_out and its Desktop (review MINOR)" on_zoom_out
    else
      check "scale 1.25: the monitor rule set the scale" false
    fi
    # Back on GF-REF with its Desktop (Hyprland's move dispatcher moves the box, not the Desktop: the window would stay on
    # GF-ZOOM's Desktop, hidden once that output goes).
    nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$out\")" >>"$log" 2>&1
    sleep 1
    place_start "$out" 300 200
    nestctl output remove "$zoom_out" >>"$log" 2>&1
    sleep 1
  else
    say "SKIP: scale 1.25 (nestctl output create headless failed)"
  fi
fi

say "reload"
place_start "$out" 300 200
click_light "$out"
check "reload: filled before the reload" gaps_ok "$out" 8 "reload fill"
if nestctl plugin unload "$plugin_so" >>"$log" 2>&1 && sleep 1 && nestctl plugin load "$plugin_so" >>"$log" 2>&1; then
  sleep 2
  check "reload: the plugin is back with zoom-fill" has_feature zoom-fill
  check "reload: still at the Fill frame (nothing moved it)" gaps_ok "$out" 8 "after the reload"
  click_light "$out"
  unfilled() {
    local x y w h fs _a ox oy lw lh sc g ax ay aw ah
    read -r x y w h fs _a < <(geometry)
    read -r ox oy lw lh sc g ax ay aw ah < <(output_facts "$out")
    say "  reload: foot ${w}x${h} at $x,$y fullscreen $fs; work area ${aw}x${ah} at $ax,$ay (Center: at most 0.9 of it, centred)"
    ((fs == 0 && w > aw / 2 && w < aw - 16 && w <= aw * 9 / 10 + 1 && x - ax >= 8 && ax + aw - x - w >= 8))
  }
  check "reload: Zoom of the filled window whose record the reload forgot unfills it (review MINOR)" unfilled
  check "reload: the plugin logged the step" plugin_logged "zoom ${addr#0x}: unfill"
  read -r ux uy uw uh _ _ < <(geometry)
  click_light "$out"
  check "reload: the next Zoom fills it again" gaps_ok "$out" 8 "reload refill"
  click_light "$out"
  back_to_unfill() { local x y w h fs _a; read -r x y w h fs _a < <(geometry); say "  reload: ${w}x${h} at $x,$y (want ${uw}x${uh} at $ux,$uy)"; ((fs == 0 && x == ux && y == uy && w == uw && h == uh)); }
  check "reload: and the one after brings back that frame" back_to_unfill
else
  check "reload: scripts/nestctl unloaded and loaded the plugin" false
fi

say "no-plugin"
place_start "$out" 300 200
nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
if nestctl plugin unload "$plugin_so" >>"$log" 2>&1; then
  sleep 1.5
  check "no-plugin: the plugin is gone" bash -c '! "$1/scripts/nestctl" -j grassfield 2>/dev/null | jq -e ".features" >/dev/null 2>&1' _ "$root"
  read -r x0 y0 w0 h0 _fs _a < <(geometry) # without the plugin's titlebar the surface keeps its box
  chord Super_L Alt_L f
  sleep 1
  check "no-plugin: Super+Alt+F is Hyprland's maximized mode, as before (gate C2)" fs_is 1
  chord Super_L Alt_L f
  sleep 1
  check "no-plugin: again: out of it, its box back" at_start "no-plugin"
  nestctl plugin load "$plugin_so" >>"$log" 2>&1
  sleep 1.5
  check "no-plugin: the plugin loaded again advertises zoom-fill" has_feature zoom-fill
else
  check "no-plugin: scripts/nestctl unloaded the plugin" false
fi

kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" test $? -eq 0
say "zoom_fill: $passed passed, $failed failed"
if ((fail == 0)); then say "zoom_fill: PASS"; else say "zoom_fill: FAIL"; fi
say "zoom_fill: log $log"
exit "$fail"
