#!/usr/bin/env bash
# Regression scenario (FR8): the zoom toggle must always restore the floating geometry the window had before
# it was maximized, whatever happened on the maximized titlebar.
#
# Usage: tests/compositor/zoom_restore.sh
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded. Pointer input goes through
# scripts/dev/pointer.sh, the client gets the nested socket only, hyprctl is used read-only (`clients`,
# `monitors`) against the nested instance.
#
# One foot window, all titlebar targets computed from its geometry (button centers 58 px right of the
# surface's left edge for zoom, bar middle 14 px above the surface):
#   1 zoom button -> maximized; double-click on the maximized bar -> floating geometry back (bug before the
#     fix: the first click's release wrote the maximized box into the floating geometry);
#   2 zoom button; single click on the maximized bar; zoom button -> floating geometry back;
#   3 zoom button; drag the maximized bar from 25 % of its width -> un-zoomed under the pointer: floating size,
#     pointer at 25 % of the width and still on the titlebar (macOS);
#   4 plain drag of the floating window -> moved by exactly the pointer delta.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/zoom-restore/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${ZR_OUTPUT:-GF-REF}

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
  echo "zoom_restore: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "zoom_restore: refusing: recorded nested instance is the main session" >&2
  exit 2
fi

work=$dev/zoom-restore
mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only: clients, monitors

read -r mon_x mon_y mon_w mon_h < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "zoom_restore: output $out not found" >&2; exit 2; }

pid=""
cleanup() { [[ -n $pid ]] && kill "$pid" 2>/dev/null; }
trap cleanup EXIT

# "<x> <y> <w> <h> <fullscreen>" of our window, x/y relative to the output.
geom() {
  query clients | jq -r --argjson p "$pid" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen)"'
}

fail=0
check() { # <label> <condition result 0/1> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

say "zoom_restore: nested pid $hypr_pid, instance $sig, output $out ${mon_w}x${mon_h}"
pointer abs $((mon_w / 2)) $((mon_h - 150)) sleep 50 # windows open on the output under the pointer
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
pid=$!
sleep 1.5

read -r x0 y0 w0 h0 fs0 < <(geom)
[[ -n ${w0:-} && $fs0 == 0 ]] || { say "zoom_restore: setup error: window not found or not floating"; exit 2; }
say "  setup: floating ${w0}x${h0} at ($x0,$y0)"
zoom_x=$((x0 + 58))
bar_y=$((y0 - 14))

zoom_in() {
  pointer abs "$zoom_x" "$bar_y" sleep 50 click sleep 600
  read -r mx my mw mh mfs < <(geom)
  [[ ${mfs:-} == 1 ]] || { say "  zoom button did not maximize (fullscreen=${mfs:-?})"; fail=1; return 1; }
}
same_as_start() { # <label>
  local x y w h fs
  read -r x y w h fs < <(geom)
  [[ $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" && $fs == 0 ]]
  check "$1" $? "now ${w}x${h} at ($x,$y) fullscreen $fs; expected ${w0}x${h0} at ($x0,$y0)"
}

say "1 double-click on the maximized titlebar"
if zoom_in; then
  pointer abs $((mx + mw / 2)) $((my - 14)) sleep 50 click sleep 60 click sleep 600
  same_as_start "double-click restores"
fi

say "2 single click on the maximized titlebar, then the zoom button"
if zoom_in; then
  pointer abs $((mx + mw / 2)) $((my - 14)) sleep 50 click sleep 500
  pointer abs $((mx + 58)) $((my - 14)) sleep 50 click sleep 600
  same_as_start "click + zoom button restores"
fi

say "3 drag on the maximized titlebar un-zooms under the pointer"
if zoom_in; then
  px=$((mx + mw / 4))
  py=$((my - 14))
  tx=$((mon_w / 2))
  ty=$((mon_h / 2 - 100))
  pointer abs "$px" "$py" sleep 50 down drag "$tx" "$ty" sleep 50 up sleep 600
  read -r x y w h fs < <(geom)
  # Pointer at 25 % of the restored width (±2 px) and 14 px above the surface, i.e. on the titlebar (±2 px).
  fx=$((tx - x - w0 / 4))
  fy=$((y - ty - 14))
  [[ $fs == 0 && $w == "$w0" && $h == "$h0" && ${fx#-} -le 2 && ${fy#-} -le 2 ]]
  check "drag un-zooms" $? "now ${w}x${h} at ($x,$y) fullscreen $fs, pointer ($tx,$ty): x error $fx, y error $fy"
  read -r x0 y0 w0 h0 fs0 < <(geom) # new floating reference
  zoom_x=$((x0 + 58))
  bar_y=$((y0 - 14))
  say "4 zoom button restores the un-zoomed window's floating geometry"
  if zoom_in; then
    pointer abs $((mx + 58)) $((my - 14)) sleep 50 click sleep 600
    same_as_start "zoom toggle after the un-zoom drag"
  fi
fi

say "5 plain drag moves by exactly the pointer delta"
pointer abs $((x0 + w0 / 2)) "$bar_y" sleep 50 down drag $((x0 + w0 / 2 + 100)) $((bar_y + 150)) sleep 50 up sleep 500
read -r x y w h fs < <(geom)
[[ $x == $((x0 + 100)) && $y == $((y0 + 150)) && $w == "$w0" && $h == "$h0" ]]
check "drag" $? "now ${w}x${h} at ($x,$y); expected at ($((x0 + 100)),$((y0 + 150)))"

if ! kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi
if ((fail == 0)); then say "zoom_restore: PASS"; else say "zoom_restore: FAIL"; fi
say "zoom_restore: log $log"
exit "$fail"
