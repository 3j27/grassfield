#!/usr/bin/env bash
# L1 nested scenario (ADR-0015, test plan items 1-3, 6): a Grassfield app that draws its own chrome (Settings: unified
# toolbar, lights in the corner of the sidebar, xdg-toplevel tag "settings") against a window that does not (foot).
#
# Usage: tests/compositor/client_chrome.sh [--no-plugin]
# NESTED only: needs scripts/dev/nested-up.sh (add --no-plugin there for the second form) and the Settings app built with
# apps/settings/build-direct.sh. Pointer input goes through scripts/dev/pointer.sh; hyprctl only through scripts/nestctl
# (read-only here: `clients -j`, `decorations`, `monitors -j`). Clients start through scripts/dev/isolated.sh with the nested
# socket only.
#
# Assertions, and what each depends on (PLUGIN = the plugin work item of ADR-0015 / docs/specs/compositor.md must have
# landed; SESSION = the session rules S1-S3 in config/hypr/grassfield/windows.lua (in this tree); APP = true with the app side).
# Only 3, 5 and 9 still wait for the plugin (P1, P5):
#   1  APP      the Settings window carries xdg tag "settings"; the foot window carries none
#   2  SESSION  the Settings window has the Hyprland tag grassfield-client-chrome (the rule on the xdg tag)
#   3  PLUGIN   the Settings window has no grassfield-titlebar decoration; foot keeps its strip
#   4  APP      the close light (25.75, 25.75 from the surface's top-left) closes the window, with and without the plugin
#   5  PLUGIN   the minimize light puts the window on special:minimized (the bridge: requestsMinimize -> minimize-request);
#               skipped with --no-plugin (the light is greyed there, ADR-0015 Q4)
#   6  SESSION  the zoom light gives fullscreen=1 (maximized); a second press restores the same box (same with --no-plugin)
#   7  APP      a press on empty toolbar space and a drag of 200,100 moves the window by about that delta (Qt's drag
#               threshold makes it lag by up to 10 px: tolerance 12), a drag from a light does not move it
#   8  APP      a double-click on empty toolbar space follows windows.titlebarDoubleClick (zoom: fullscreen=1)
#   9  PLUGIN   plugin unload and reload while the window is mapped: never two sets of lights, never a strip: run by hand,
#               see the end of this file (scripts/nestctl plugin unload|load are owner-approved nested commands)
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
  sa=$(client org.grassfield.Settings .address)
  fa=$(client foot .address)
  ctl decorations "address:$sa" 2>&1 | grep -q grassfield-titlebar
  s_strip=$?
  ctl decorations "address:$fa" 2>&1 | grep -q grassfield-titlebar
  f_strip=$?
  [[ $s_strip != 0 && $f_strip == 0 ]]
  check "no strip on the app window, strip on foot (PLUGIN)" $? "app strip exit $s_strip (want 1), foot strip exit $f_strip (want 0)"
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
pointer abs "$ex" "$ey" sleep 50 click sleep 60 click sleep 700
read -r x y w h fs < <(geom org.grassfield.Settings)
[[ $fs == 0 && $w == "$w0" && $h == "$h0" ]]
check "double-click restores" $? "now ${w}x${h} fullscreen $fs"

say "5 minimize light"
if ((plugin)); then
  read -r mx my < <(light 1)
  pointer abs "$mx" "$my" sleep 50 click sleep 1200
  ws=$(client org.grassfield.Settings .workspace.name)
  [[ $ws == special:minimized ]]
  check "minimize (PLUGIN: bridge)" $? "workspace '$ws'"
  # Bring it back for the close test: the Dock is not running here, so the plugin's own restore is not exercised.
  mapped org.grassfield.Settings && ctl dispatch 'hl.dsp.focus({window="class:org.grassfield.Settings"})' >>"$log" 2>&1
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
