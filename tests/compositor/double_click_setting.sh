#!/usr/bin/env bash
# Scenario (FR8, FR16): the titlebar double-click honors Settings windows.titlebarDoubleClick, which
# grassfield-shell pushes to the plugin (hl.plugin.grassfield.config) after the handshake and on change.
#
# Usage: tests/compositor/double_click_setting.sh
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded (feature "config") and
# grassfield-shell running. The setting is changed by rewriting the dev settings file
# (.dev/config/grassfield.json, GRASSFIELD_CONFIG_HOME of the nested shell); the original file (or its
# absence) is restored at exit. Pointer input through scripts/dev/pointer.sh, hyprctl read-only.
#   minimize -> a double-click on the bar hides the window on special:minimized (minimize-request path);
#   none     -> a double-click changes nothing (no zoom, no minimize);
#   zoom     -> a double-click zooms, a second one restores the geometry. Zoom is Fill (ADR-0036 D78): with the plugin's
#               zoom-fill the window fills the usable area (larger on both axes, fullscreen 0); without it Hyprland's
#               maximized mode (fullscreen 1);
#   fill     -> (plugin with "tiling-arrange", docs/specs/tiling.md TL32) a double-click tiles the window over the usable
#               area: larger on both axes, not full screen, on the same Desktop; a second one restores the geometry (D78);
#   default  -> the key removed from the settings file: the default is fill (D78), the double-click fills, a second
#               one restores the geometry.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/double-click/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${DC_OUTPUT:-GF-REF}

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
# Only this tree's live nested compositor (records verified by start time; scripts/dev/pidfile.sh): a stale record
# may name another worktree's session.
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "double_click_setting: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "double_click_setting: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "double_click_setting: grassfield-shell is not running" >&2; exit 2; }
query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only
query grassfield | jq -e '.features | index("config")' >/dev/null 2>&1 \
  || { echo "double_click_setting: the loaded plugin does not advertise \"config\"" >&2; exit 2; }

work=$dev/double-click
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

settings=$dev/config/grassfield.json
backup=$work/settings.backup
had_settings=0
[[ -f $settings ]] && { cp "$settings" "$backup"; had_settings=1; }
pid=""
cleanup() {
  [[ -n $pid ]] && kill "$pid" 2>/dev/null
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
}
trap cleanup EXIT
set_setting() { # <zoom|minimize|none|fill|default>: rewrite the dev settings file, give the shell time to push it
  mkdir -p "$dev/config"
  local base=$root/config/defaults/grassfield.json
  ((had_settings)) && base=$backup
  if [[ $1 == default ]]; then
    jq 'del(.windows.titlebarDoubleClick)' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  else
    jq --arg v "$1" '.windows.titlebarDoubleClick = $v' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  fi
  sleep 1
}

read -r mon_x mon_y < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y)"')
[[ -n ${mon_x:-} ]] || { echo "double_click_setting: output $out not found" >&2; exit 2; }
geom() {
  query clients | jq -r --argjson p "$pid" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen) \(.workspace.name)"'
}

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

say "double_click_setting: nested pid $hypr_pid, output $out"
pointer abs 960 360 sleep 50
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
pid=$!
sleep 1.5
read -r x0 y0 w0 h0 fs0 ws0 < <(geom)
[[ -n ${w0:-} ]] || { say "double_click_setting: setup error: window not found"; exit 2; }
bar_x=$((x0 + w0 / 2))
bar_y=$((y0 - GF_TB_MID))
double_click() { pointer abs "$1" "$2" sleep 50 click sleep 60 click sleep 800; }

say "minimize"
set_setting minimize
double_click "$bar_x" "$bar_y"
read -r x y w h fs ws < <(geom)
[[ $ws == special:minimized ]]
check "double-click minimizes" $? "workspace $ws, fullscreen $fs"
# The minimized window is replaced by a fresh one (restoring through the Dock is minimize.sh's job).
if [[ $ws == special:minimized ]]; then
  pointer abs 960 360 sleep 50
  kill "$pid" 2>/dev/null
  sleep 0.5
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
  pid=$!
  sleep 1.5
  read -r x0 y0 w0 h0 fs0 ws0 < <(geom)
  bar_x=$((x0 + w0 / 2))
  bar_y=$((y0 - GF_TB_MID))
fi

say "none"
set_setting none
double_click "$bar_x" "$bar_y"
read -r x y w h fs ws < <(geom)
[[ $fs == 0 && $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "double-click does nothing" $? "${w}x${h} at ($x,$y) fullscreen $fs on $ws"

say "zoom"
set_setting zoom
double_click "$bar_x" "$bar_y"
read -r mx my mw mh fs ws < <(geom)
if query grassfield | jq -e '.features | index("zoom-fill")' >/dev/null 2>&1; then
  [[ $fs == 0 && $ws == "$ws0" ]] && ((mw > w0 && mh > h0))
  check "double-click zooms: Zoom is Fill (ADR-0036 D78)" $? "${mw}x${mh} at ($mx,$my) fullscreen $fs on $ws (was ${w0}x${h0})"
else
  [[ $fs == 1 ]]
  check "double-click maximizes (no zoom-fill: Hyprland's maximized mode)" $? "${mw}x${mh} fullscreen $fs"
fi
double_click $((mx + mw / 2)) $((my - GF_TB_MID))
read -r x y w h fs ws < <(geom)
[[ $fs == 0 && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "double-click restores" $? "${w}x${h} at ($x,$y) fullscreen $fs"

if query grassfield | jq -e '.features | index("tiling-arrange")' >/dev/null 2>&1; then
  for setting in fill default; do
    say "$setting"
    set_setting "$setting"
    double_click "$bar_x" "$bar_y"
    read -r mx my mw mh fs ws < <(geom)
    [[ $fs == 0 && $ws == "$ws0" ]] && ((mw > w0 && mh > h0))
    check "double-click fills ($setting)" $? "${mw}x${mh} at ($mx,$my) fullscreen $fs on $ws (was ${w0}x${h0})"
    double_click $((mx + mw / 2)) $((my - GF_TB_MID))
    read -r x y w h fs ws < <(geom)
    [[ $fs == 0 && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
    check "a second double-click restores ($setting, ADR-0036 D78)" $? "${w}x${h} at ($x,$y) fullscreen $fs"
  done
else
  say "fill: SKIP (the plugin does not advertise tiling-arrange; the shell sends zoom instead)"
fi

kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $? "pid $hypr_pid"
if ((fail == 0)); then say "double_click_setting: PASS"; else say "double_click_setting: FAIL"; fi
say "double_click_setting: log $log"
exit "$fail"
