#!/usr/bin/env bash
# L1 nested scenario (ADR-0015, test plan items 1-3, 6): a Grassfield app that draws its own chrome (Settings: unified
# toolbar, lights in the corner of the sidebar, xdg-toplevel tag "settings") against a window that does not (foot).
#
# Usage: tests/compositor/client_chrome.sh [--no-plugin]
# NESTED only: needs scripts/dev/nested-up.sh (add --no-plugin there for the second form) and the Settings app built with
# apps/settings/build-direct.sh. Pointer input goes through scripts/dev/pointer.sh; hyprctl only through scripts/nestctl
# (read-only here: `clients -j`, `monitors -j`, `grassfield -j`; the window moves of step 3, the restore of step 5 and two
# focus dispatches), captures with grim. Clients start through scripts/dev/isolated.sh with the nested socket only.
#
# Assertions, and what each depends on (PLUGIN = the plugin work item of ADR-0015 / docs/specs/compositor.md, in this tree
# since P1-P7; SESSION = the session rules S1-S3 in config/hypr/grassfield/windows.lua; APP = true with the app side):
#   1  APP      the Settings window carries xdg tag "settings"; the foot window carries none
#   2  SESSION  the Settings window has the Hyprland tag grassfield-client-chrome (the rule on the xdg tag)
#   3  PLUGIN   no plugin strip above the Settings window, one above foot: measured on a capture (the row 16 px above
#               each surface, at 20-80 % of its width, against the strip's colour, ui/tokens/tokens.json
#               titlebar.background*). Both windows open centred, foot under Settings: for the capture foot goes to the
#               upper left and Settings to the lower right, apart (checked), then Settings goes back. The decoration
#               object itself stays attached to every window (hyprctl decorations lists it): P1 hides it
#   4  APP      the close light (25.75, 25.75 from the surface's top-left) closes the window, with and without the plugin
#   5  PLUGIN   the minimize light puts the window on special:minimized (the bridge: requestsMinimize -> minimize-request);
#               skipped with --no-plugin (the light is greyed there, ADR-0015 Q4)
#   6  SESSION  the zoom light gives fullscreen=1 (maximized); a second press restores the same box (same with --no-plugin)
#   7  APP      a press on empty toolbar space and a drag of 200,100 moves the window by about that delta (Qt's drag
#               threshold makes it lag by up to 10 px: tolerance 12), a drag from a light does not move it
#   8  APP      a double-click on empty toolbar space follows windows.titlebarDoubleClick (zoom: fullscreen=1)
#   9  PLUGIN   plugin unload and reload while the window is mapped: never two sets of lights, never a strip: run by hand,
#               see the end of this file (scripts/nestctl plugin unload|load are owner-approved nested commands)
#   10 PLUGIN   a drag on empty toolbar space of the zoomed window takes it out of the zoom at its floating size, under the
#               pointer at the same place in its toolbar row (P4: x within 3 px of the press's fraction, the row under the
#               pointer); with --no-plugin Hyprland's own move un-zooms it centred on the pointer (reported, not checked)
#   11 PLUGIN   the gfc/1 feature client-chrome is advertised (P2); with --no-plugin there is no feature list at all
# Option(Alt)+click on the zoom light (true full screen, REQ-ADR0002-6) cannot be injected by scripts/dev/pointer.sh (no
# modifier support): covered by tests/unit/tst_windowcontrols.qml (test_optionClickIsTrueFullScreen) and by hand.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/client-chrome/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${CC_OUTPUT:-GF-REF}
plugin=1
[[ ${1:-} == "--no-plugin" ]] && plugin=0

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "client_chrome: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "client_chrome: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
settings=$dev/build/grassfield-settings
[[ -x $settings ]] || { echo "client_chrome: build the app first: apps/settings/build-direct.sh" >&2; exit 2; }

work=$dev/client-chrome
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
ctl() { timeout 10 "$root/scripts/nestctl" "$@"; }

read -r mon_x mon_y mon_w mon_h < <(ctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "client_chrome: output $out not found" >&2; exit 2; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

fail=0
check() { # <label> <0 ok / 1 fail> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}
skip() { say "  $1: SKIP ($2)"; }

# Field of the client with class $1: jq expression $2.
client() { ctl clients -j | jq -r --arg c "$1" ".[] | select(.class == \$c) | $2" | head -1; }
# "<x> <y> <w> <h> <fullscreen>" of the client of class $1, x/y relative to the output.
geom() {
  ctl clients -j | jq -r --arg c "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.class == $c) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen)"' | head -1
}
mapped() { [[ -n $(client "$1" .address) ]]; }
# The plugin strip above a surface: 1 when the row 16 px above its top edge has the strip's colour (either appearance) at
# five points across the window (20 % to 80 % of its width; a shadow over the wallpaper is neither that colour nor
# uniform), 0 otherwise. <png> <x> <y> <w> (output px).
strip_above() {
  local i hexes=()
  for i in 20 35 50 65 80; do
    hexes+=("$(magick "$1" -format "%[hex:p{$(($2 + $4 * i / 100)),$(($3 - 16))}]" info: 2>/dev/null | cut -c1-6)")
  done
  python3 -I - "$(jq -r '.titlebar.backgroundDark.value' "$root/ui/tokens/tokens.json")" \
    "$(jq -r '.titlebar.backgroundLight.value' "$root/ui/tokens/tokens.json")" "${hexes[@]}" <<'PY'
import sys
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) if len(h) >= 6 else None
tokens = [rgb(t) for t in sys.argv[1:3]]
points = [rgb(h) for h in sys.argv[3:]]
def near(a, b):
    return a is not None and b is not None and max(abs(x - y) for x, y in zip(a, b)) <= 8
print(1 if points and all(any(near(p, t) for t in tokens) for p in points) else 0)
PY
}

launch_settings() {
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 50
  WAYLAND_DISPLAY=$sock GRASSFIELD_SETTINGS_QML="$root/apps/settings/qml" QML_IMPORT_PATH="$root/ui:$dev/build/qml" \
    setsid "$root/scripts/dev/isolated.sh" --name client-chrome -- "$settings" >>"$log" 2>&1 </dev/null &
  pids+=($!)
  for _ in $(seq 1 40); do mapped org.grassfield.Settings && return 0; sleep 0.25; done
  return 1
}

# Centre of a light, in output coordinates: surface top-left + (25.75, 25.75) + n * 23 on x.
light() { # <index 0..2> -> "x y"
  read -r x y _ < <(geom org.grassfield.Settings)
  awk -v x="$x" -v y="$y" -v n="$1" 'BEGIN { printf "%d %d\n", x + 25.75 + n * 23 + 0.5, y + 25.75 + 0.5 }'
}

say "client_chrome: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}, plugin=$plugin"
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name client-chrome -- foot >>"$log" 2>&1 </dev/null &
pids+=($!)
for _ in $(seq 1 40); do mapped foot && break; sleep 0.25; done
launch_settings || { say "client_chrome: setup error: Settings did not map"; exit 2; }
sleep 1

say "1-3 tags and the plugin strip"
tag=$(client org.grassfield.Settings .xdgTag)
foot_tag=$(client foot .xdgTag)
[[ $tag == settings && -z $foot_tag ]]
check "xdg tag" $? "settings window '$tag', foot '$foot_tag'"
htags=$(client org.grassfield.Settings '.tags | join(",")')
[[ $htags == *grassfield-client-chrome* ]]
check "hyprland tag (SESSION)" $? "tags '$htags'"
if ((plugin)); then
  # Both windows opened centred under the pointer, foot under Settings (integrator run 2026-10-24: foot's strip was hidden,
  # "above foot: 0"). Apart for the capture: foot upper left, Settings lower right, each strip row clear of the other window.
  read -r sx0 sy0 sw0 sh0 _ < <(geom org.grassfield.Settings)
  read -r _ _ fw0 fh0 _ < <(geom foot)
  s_addr=$(client org.grassfield.Settings .address)
  f_addr=$(client foot .address)
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + 40)), y = $((mon_y + 80)), window = 'address:$f_addr' })" >>"$log" 2>&1
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + mon_w - sw0 - 40)), y = $((mon_y + mon_h - sh0 - 40)), window = 'address:$s_addr' })" >>"$log" 2>&1
  sleep 0.8
  read -r gx gy gw gh _ < <(geom org.grassfield.Settings)
  read -r fx fy fw fh _ < <(geom foot)
  # Apart: the boxes, each with the 16 px row above it, share no pixel.
  apart=1
  if ((fx < gx + gw && gx < fx + fw && fy - 16 < gy + gh && gy - 16 < fy + fh)); then apart=0; fi
  ((apart))
  check "the two windows apart for the strip capture" $? "foot ${fw}x${fh} at ($fx,$fy), Settings ${gw}x${gh} at ($gx,$gy) (foot ${fw0}x${fh0} before)"
  WAYLAND_DISPLAY=$sock timeout 10 grim -o "$out" "$work/strip.png" 2>>"$log"
  s_strip=$(strip_above "$work/strip.png" "$gx" "$gy" "$gw")
  f_strip=$(strip_above "$work/strip.png" "$fx" "$fy" "$fw")
  [[ $s_strip == 0 && $f_strip == 1 ]]
  check "no strip on the app window, strip on foot (PLUGIN P1)" $? "strip colour above Settings: $s_strip (want 0), above foot: $f_strip (want 1); capture $work/strip.png"
  # Settings back where it opened: the drags of step 7 need room on every side.
  ctl dispatch "hl.dsp.window.move({ x = $((mon_x + sx0)), y = $((mon_y + sy0)), window = 'address:$s_addr' })" >>"$log" 2>&1
  sleep 0.6
  read -r gx gy _ _ _ < <(geom org.grassfield.Settings)
  ddx=$((gx - sx0)); ddy=$((gy - sy0))
  [[ ${ddx#-} -le 2 && ${ddy#-} -le 2 ]]
  check "Settings back at its place for step 7" $? "at ($gx,$gy), want ($sx0,$sy0) within 2 px"
else
  skip "strip" "no plugin loaded"
fi

say "7 drag on empty toolbar space, and from a light"
read -r x0 y0 w0 h0 fs0 < <(geom org.grassfield.Settings)
# Empty space: the toolbar over the detail pane, right of the title (the title is short and left aligned).
ex=$((x0 + w0 - 120))
ey=$((y0 + 26))
pointer abs "$ex" "$ey" sleep 50 down drag $((ex + 200)) $((ey + 100)) sleep 50 up sleep 500
read -r x1 y1 w1 h1 _ < <(geom org.grassfield.Settings)
dx=$((x1 - x0 - 200)); dy=$((y1 - y0 - 100))
[[ ${dx#-} -le 12 && ${dy#-} -le 12 && $w1 == "$w0" && $h1 == "$h0" ]]
check "drag moves the window" $? "moved by ($((x1 - x0)),$((y1 - y0))), want about (200,100)"
read -r lx ly < <(light 1)
pointer abs "$lx" "$ly" sleep 50 down drag $((lx + 200)) $((ly + 100)) sleep 50 up sleep 500
read -r x2 y2 _ _ _ < <(geom org.grassfield.Settings)
mapped org.grassfield.Settings || { say "  the minimize light drag minimized or closed the window"; fail=1; }
[[ $x2 == "$x1" && $y2 == "$y1" ]]
check "drag from a light does not move" $? "now ($x2,$y2), was ($x1,$y1)"
read -r x0 y0 w0 h0 fs0 < <(geom org.grassfield.Settings)

say "6 zoom light toggles maximized, same box back"
read -r zx zy < <(light 2)
pointer abs "$zx" "$zy" sleep 50 click sleep 700
read -r _ _ _ _ fs < <(geom org.grassfield.Settings)
[[ $fs == 1 ]]
check "zoom (SESSION: maximize exemption)" $? "fullscreen $fs, want 1"
read -r zx zy < <(light 2)
pointer abs "$zx" "$zy" sleep 50 click sleep 700
read -r x y w h fs < <(geom org.grassfield.Settings)
[[ $fs == 0 && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "second press restores" $? "now ${w}x${h} at ($x,$y) fullscreen $fs; want ${w0}x${h0} at ($x0,$y0)"

say "8 double-click on empty toolbar space (windows.titlebarDoubleClick = zoom by default)"
read -r x0 y0 w0 h0 _ < <(geom org.grassfield.Settings)
ex=$((x0 + w0 - 120))
ey=$((y0 + 26))
pointer abs "$ex" "$ey" sleep 50 click sleep 60 click sleep 700
read -r _ _ _ _ fs < <(geom org.grassfield.Settings)
[[ $fs == 1 ]]
check "double-click zooms (SESSION)" $? "fullscreen $fs, want 1"
# The zoomed window's own toolbar row: the point is computed again from its zoomed geometry.
read -r zx0 zy0 zw0 _ _ < <(geom org.grassfield.Settings)
ex=$((zx0 + zw0 - 120))
ey=$((zy0 + 26))
pointer abs "$ex" "$ey" sleep 50 click sleep 60 click sleep 700
read -r x y w h fs < <(geom org.grassfield.Settings)
[[ $fs == 0 && $w == "$w0" && $h == "$h0" ]]
check "double-click restores" $? "now ${w}x${h} fullscreen $fs"

say "10 drag of the zoomed window from its toolbar (P4)"
read -r x0 y0 w0 h0 fs0 < <(geom org.grassfield.Settings)
if [[ $fs0 == 1 ]]; then # a step above left it zoomed: back to its floating box first
  read -r zx zy < <(light 2)
  pointer abs "$zx" "$zy" sleep 50 click sleep 700
  read -r x0 y0 w0 h0 _ < <(geom org.grassfield.Settings)
fi
read -r zx zy < <(light 2)
pointer abs "$zx" "$zy" sleep 50 click sleep 700
read -r zxx zyy zw zh fs < <(geom org.grassfield.Settings)
if [[ $fs == 1 ]]; then
  # Empty toolbar space three quarters across the zoomed window, in the row (26 px below its top edge).
  px=$((zxx + zw * 3 / 4)) py=$((zyy + 26)) tx=$((mon_w / 2)) ty=$((mon_h / 2))
  pointer abs "$px" "$py" sleep 50 down drag "$tx" "$ty" sleep 50 up sleep 700
  read -r x y w h fs < <(geom org.grassfield.Settings)
  fx=$((tx - x - w0 * 3 / 4)) fy=$((ty - y - 26))
  if ((plugin)); then
    [[ $fs == 0 && $w == "$w0" && $h == "$h0" && ${fx#-} -le 3 && ${fy#-} -le 12 ]]
    check "zoomed drag: floating size, same place under the pointer (PLUGIN P4)" $? \
      "now ${w}x${h} at ($x,$y) fullscreen $fs; pointer ($tx,$ty): x error $fx (<= 3), row error $fy (<= 12: Qt's drag threshold)"
  else
    say "  zoomed drag without the plugin: ${w}x${h} at ($x,$y) fullscreen $fs; x error $fx, row error $fy (Hyprland's own move)"
  fi
else
  check "zoomed drag: the zoom light zoomed first" 1 "fullscreen $fs"
fi

say "11 the feature (P2)"
if ((plugin)); then
  feats=$(ctl -j grassfield 2>/dev/null | jq -r '.features | join(",")')
  [[ ,$feats, == *,client-chrome,* ]]
  check "client-chrome advertised (PLUGIN P2)" $? "features $feats"
else
  skip "feature" "no plugin loaded"
fi

say "5 minimize light"
if ((plugin)); then
  read -r mx my < <(light 1)
  pointer abs "$mx" "$my" sleep 50 click sleep 1200
  ws=$(client org.grassfield.Settings .workspace.name)
  [[ $ws == special:minimized ]]
  check "minimize (PLUGIN: bridge)" $? "workspace '$ws'"
  # Bring it back for the close test: the plugin's restore (what a click on its Dock tile asks for, without a tile to grow
  # from), then wait until it is on a regular workspace again.
  ma=$(client org.grassfield.Settings .address)
  [[ -n $ma ]] && ctl dispatch "hl.plugin.grassfield.restore(\"$ma\", 0, 0, 0, 0)" >>"$log" 2>&1
  for _ in $(seq 1 20); do
    [[ $(client org.grassfield.Settings .workspace.name) != special:minimized ]] && break
    sleep 0.25
  done
  ws=$(client org.grassfield.Settings .workspace.name)
  [[ -n $ws && $ws != special:minimized ]]
  check "restored for the close test" $? "workspace '$ws'"
  sleep 0.5
else
  skip "minimize" "no plugin: the light is greyed, ADR-0015 Q4"
fi

say "4 close light"
if ! mapped org.grassfield.Settings; then
  launch_settings || say "  setup: Settings did not map again"
  sleep 1
fi
read -r cx cy < <(light 0)
pointer abs "$cx" "$cy" sleep 50 click sleep 1000
mapped org.grassfield.Settings
[[ $? != 0 ]]
check "close" $? "window gone after the click"

if ! kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi
if ((fail == 0)); then say "client_chrome: PASS"; else say "client_chrome: FAIL"; fi
say "client_chrome: log $log"
# By hand, item 9: with Settings and foot mapped, `scripts/nestctl plugin unload <path>`: foot loses its strip, Settings keeps its
# lights and gets none from the plugin; `scripts/nestctl plugin load <path>`: foot's strip is back, Settings still has no strip.
exit "$fail"
