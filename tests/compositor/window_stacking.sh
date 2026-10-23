#!/usr/bin/env bash
# Stacking scenario (macOS model, config/hypr/grassfield/stacking.lua): a press on the visible part of a window that sits
# behind another one brings that window to the front, whole.
#
# Usage: tests/compositor/window_stacking.sh
# NESTED only: needs scripts/dev/nested-up.sh. Pointer input goes through scripts/dev/pointer.sh, clients through
# scripts/dev/isolated.sh with the nested socket only, hyprctl is read-only (scripts/nestctl -j clients) and the pixel
# check uses grim on the nested output. The dispatcher calls go through scripts/nestctl.
#
# Two foot windows with different background colours (A red, B blue), both floating:
#   1 B is dragged so that it overlaps A partly; B is then in front (pixel in the overlap is blue)
#   2 press on the visible part of A (outside the overlap): A is active, in front in the pixel check (red in the overlap)
#     and last in the stacking order of `nestctl -j clients`
#   3 press on the visible part of B: B in front again (blue in the overlap)
#   4 A activated by the focus dispatcher (no press, like the switcher or the Dock): in front
#   5 B activated the same way: in front again
#   5a B zoomed (Grassfield Zoom = Hyprland maximized) with A raised in front of it: a press on the visible part of B
#      brings the zoomed B to the front (owner report 2026-10-23, zoomed Spotify stayed behind Chrome)
#   5b A activated by the focus dispatcher: in front of the zoomed B again; B stays zoomed
#   6 B full-screen, A activated: B keeps its full-screen state
#   7 A moved to workspace 2, activated: its Desktop is shown and A is active
# Without grassfield-compositor B is placed with the move dispatcher (scripts/dev/nested-up.sh --no-plugin).
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log and captures: .dev/window-stacking/run-<timestamp>.*
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${WS_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK

for tool in jq foot grim od; do
  command -v "$tool" >/dev/null || { echo "window_stacking: $tool not installed" >&2; exit 2; }
done

work=$dev/window-stacking
mkdir -p "$work"
stamp=$(date +%Y%m%d-%H%M%S)
log=$work/run-$stamp.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
clients() { timeout 5 "$root/scripts/nestctl" -j clients; }
monitors() { timeout 5 "$root/scripts/nestctl" -j monitors; }

read -r mon_x mon_y mon_w mon_h < <(monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "window_stacking: output $out not found" >&2; exit 2; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

start_foot() { # <colour> <title>; the pid is left in $started
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --title "$2" -w 800x500 \
    -o "colors-dark.background=$1" -o "colors-light.background=$1" -o colors-dark.alpha=1 -o colors-light.alpha=1 sleep 600 \
    >/dev/null 2>&1 </dev/null &
  started=$!
  pids+=("$started")
  sleep 1.5
}
geom() { # <title> -> "x y w h floating address" relative to the output
  clients | jq -r --arg t "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.title == $t) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.floating) \(.address)"'
}
order() { # stacking order, bottom first, as the titles of our two windows
  clients | jq -r '[.[] | select(.title == "gf-stack-a" or .title == "gf-stack-b") | .title] | join(" ")'
}
pixel() { # <x> <y> relative to the output -> rrggbb of what is drawn there
  WAYLAND_DISPLAY=$sock grim -g "$((mon_x + $1)),$((mon_y + $2)) 1x1" -t ppm - 2>>"$log" | tail -c 3 | od -An -tx1 | tr -d " \n"
}
shot() { "$root/scripts/dev/shot.sh" "window-stacking-$stamp-$1" "$out" >>"$log" 2>&1; say "  capture: $dev/shots/window-stacking-$stamp-$1.png"; }
active_title() { clients | jq -r '.[] | select(.focusHistoryID == 0) | .title'; }

fail=0
check() { # <label> <0|1> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

say "window_stacking: output $out ${mon_w}x${mon_h}"
pointer abs $((mon_w / 2)) $((mon_h - 150)) sleep 50 # windows open on the output under the pointer
start_foot ff0000 gf-stack-a
start_foot 0000ff gf-stack-b
read -r ax ay aw ah afloat _ < <(geom gf-stack-a)
read -r bx by bw bh bfloat _ < <(geom gf-stack-b)
[[ -n ${aw:-} && -n ${bw:-} && $afloat == true && $bfloat == true ]] || { say "setup error: windows missing or not floating (A: ${aw:-none}, B: ${bw:-none})"; exit 2; }
say "  setup: A ${aw}x${ah} at ($ax,$ay), B ${bw}x${bh} at ($bx,$by)"

# 1 Move B over the lower right part of A: drag from the middle of B's titlebar (GF_TB_MID above its surface).
dx=$((aw * 6 / 10))
dy=$((ah * 4 / 10))
pointer abs $((bx + bw / 2)) $((by - GF_TB_MID)) sleep 50 down drag $((bx + bw / 2 + dx)) $((by - GF_TB_MID + dy)) sleep 50 up sleep 500
dispatch() { timeout 5 "$root/scripts/nestctl" dispatch "$1" >>"$log" 2>&1; }
read -r nbx nby bw bh _ b_addr < <(geom gf-stack-b)
if [[ $nbx == "$bx" && $nby == "$by" ]]; then
  # No titlebar (grassfield-compositor not loaded): place B with the move dispatcher instead.
  say "  no titlebar drag possible (plugin not loaded?): moving B with the dispatcher"
  dispatch "hl.dsp.window.move({ x = $((mon_x + bx + dx)), y = $((mon_y + by + dy)), window = 'address:$b_addr' })"
  sleep 0.5
  read -r nbx nby bw bh _ _ < <(geom gf-stack-b)
fi
bx=$nbx by=$nby
say "1 B moved to ($bx,$by)"
# A point inside both windows: the middle of the overlap rectangle.
ox=$(((bx + ax + aw) / 2))
oy=$(((by + ay + ah) / 2))
colour=$(pixel "$ox" "$oy")
check "B in front after the move" "$([[ $colour == 0000ff ]] && echo 0 || echo 1)" "pixel ($ox,$oy) = $colour, order: $(order)"
shot before
calibrated=0
[[ $(order | awk '{print $NF}') == gf-stack-b ]] && calibrated=1

# 2 Press on the visible part of A: the top-left corner area, outside B.
pointer abs $((ax + 40)) $((ay + 40)) sleep 100 click sleep 600
colour=$(pixel "$ox" "$oy")
say "2 pressed A at ($((ax + 40)),$((ay + 40)))"
check "A active" "$([[ $(active_title) == gf-stack-a ]] && echo 0 || echo 1)" "active: $(active_title)"
check "A in front (pixel in the overlap)" "$([[ $colour == ff0000 ]] && echo 0 || echo 1)" "pixel ($ox,$oy) = $colour"
if ((calibrated)); then
  check "A last in the stacking order" "$([[ $(order | awk '{print $NF}') == gf-stack-a ]] && echo 0 || echo 1)" "order: $(order)"
else
  say "  stacking order check: SKIP (clients list is not in stacking order here: $(order)); the pixel check decides"
fi
shot after-a

# 3 Press on the visible part of B: the bottom-right corner area, outside A.
pointer abs $((bx + bw - 40)) $((by + bh - 40)) sleep 100 click sleep 600
colour=$(pixel "$ox" "$oy")
say "3 pressed B at ($((bx + bw - 40)),$((by + bh - 40)))"
check "B active" "$([[ $(active_title) == gf-stack-b ]] && echo 0 || echo 1)" "active: $(active_title)"
check "B in front again" "$([[ $colour == 0000ff ]] && echo 0 || echo 1)" "pixel ($ox,$oy) = $colour"
shot after-b

read -r _ _ _ _ _ a_addr < <(geom gf-stack-a)
read -r _ _ _ _ _ b_addr < <(geom gf-stack-b)

# 4 Keyboard-style activation (switcher, Dock, a program asking for focus): A is focused without a pointer press.
dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
sleep 0.6
colour=$(pixel "$ox" "$oy")
say "4 A activated through the focus dispatcher"
check "A active" "$([[ $(active_title) == gf-stack-a ]] && echo 0 || echo 1)" "active: $(active_title)"
check "A in front after activation" "$([[ $colour == ff0000 ]] && echo 0 || echo 1)" "pixel ($ox,$oy) = $colour, order: $(order)"
shot after-activate-a

# 5 B activated again the same way: in front.
dispatch "hl.dsp.focus({ window = 'address:$b_addr' })"
sleep 0.6
colour=$(pixel "$ox" "$oy")
say "5 B activated through the focus dispatcher"
check "B in front after activation" "$([[ $colour == 0000ff ]] && echo 0 || echo 1)" "pixel ($ox,$oy) = $colour, order: $(order)"

# 5a Zoomed windows stack like any other (macOS: a zoomed window is an ordinary window; owner report 2026-10-23,
# Spotify zoomed behind Chrome stayed behind when clicked). B zoomed (Grassfield Zoom = Hyprland maximized), A put in
# front of it, then a press on the part of B that A does not cover brings B to the front.
dispatch "hl.dsp.window.fullscreen({ mode = 'maximized', window = 'address:$b_addr' })"
sleep 0.8
fs_b=$(clients | jq -r --arg a "$b_addr" '.[] | select(.address == $a) | .fullscreen')
dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
sleep 0.4
dispatch "hl.dsp.window.alter_zorder({ mode = 'top', window = 'address:$a_addr' })"
sleep 0.6
acx=$((ax + aw / 2)) acy=$((ay + ah / 2))
colour=$(pixel "$acx" "$acy")
say "5a B zoomed (fullscreen $fs_b), A activated and raised: pixel at A's centre ($acx,$acy) = $colour"
check "A in front of the zoomed B after its activation" "$([[ $colour == ff0000 ]] && echo 0 || echo 1)" "pixel ($acx,$acy) = $colour, order: $(order)"
shot zoomed-a-front
# A point of B outside A: B is zoomed, so the area right of A (or left of it when A reaches the right edge).
if ((ax + aw + 60 < mon_w)); then px=$((ax + aw + 40)); else px=$((ax - 40)); fi
py=$acy
pointer abs "$px" "$py" sleep 100 click sleep 600
colour=$(pixel "$acx" "$acy")
say "5a pressed the zoomed B at ($px,$py)"
check "zoomed B active after a press on it" "$([[ $(active_title) == gf-stack-b ]] && echo 0 || echo 1)" "active: $(active_title)"
check "zoomed B in front after a press on it" "$([[ $colour == 0000ff ]] && echo 0 || echo 1)" "pixel ($acx,$acy) = $colour, order: $(order)"
shot zoomed-b-front
# 5b A activated by the focus dispatcher while B is zoomed: A comes in front of the zoomed window.
dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
sleep 0.6
colour=$(pixel "$acx" "$acy")
say "5b A activated through the focus dispatcher over the zoomed B"
check "A in front of the zoomed B after activation" "$([[ $colour == ff0000 ]] && echo 0 || echo 1)" "pixel ($acx,$acy) = $colour, order: $(order)"
fs_b2=$(clients | jq -r --arg a "$b_addr" '.[] | select(.address == $a) | .fullscreen')
check "B still zoomed after the raises" "$([[ $fs_b2 == "$fs_b" && $fs_b != 0 ]] && echo 0 || echo 1)" "fullscreen $fs_b -> $fs_b2"
dispatch "hl.dsp.window.fullscreen({ mode = 'maximized', window = 'address:$b_addr', action = 'unset' })"
sleep 0.6
dispatch "hl.dsp.focus({ window = 'address:$b_addr' })"
sleep 0.6
read -r bx by bw bh _ _ < <(geom gf-stack-b)
say "5c B un-zoomed back at ($bx,$by) ${bw}x${bh}"

# 6 Full-screen is left alone: B full-screen, A activated: B keeps its full-screen state and A is not drawn over it.
dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$b_addr' })"
sleep 0.8
fs_before=$(clients | jq -r --arg a "$b_addr" '.[] | select(.address == $a) | .fullscreen')
dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
sleep 0.8
fs_after=$(clients | jq -r --arg a "$b_addr" '.[] | select(.address == $a) | .fullscreen')
colour=$(pixel "$ox" "$oy")
say "6 B full-screen ($fs_before), A activated: B now $fs_after, pixel ($ox,$oy) = $colour"
check "full-screen state of B unchanged by the raise" "$([[ $fs_before == "$fs_after" && $fs_before != 0 ]] && echo 0 || echo 1)" "fullscreen $fs_before -> $fs_after"
shot fullscreen
dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$b_addr', action = 'unset' })"
sleep 0.5

# 7 Another Desktop (workspace): A moved to workspace 2 silently, then activated: the workspace switches, A is active.
dispatch "hl.dsp.window.move({ workspace = '2', follow = false, window = 'address:$a_addr' })"
sleep 0.5
dispatch "hl.dsp.focus({ window = 'address:$a_addr' })"
sleep 0.8
ws=$(clients | jq -r --arg a "$a_addr" '.[] | select(.address == $a) | .workspace.id')
say "7 A on workspace $ws, active: $(active_title)"
check "A active on its own Desktop" "$([[ $ws == 2 && $(active_title) == gf-stack-a ]] && echo 0 || echo 1)" "workspace $ws, active $(active_title)"
dispatch "hl.dsp.focus({ workspace = '1' })"

if ((fail)); then say "window_stacking: FAIL (log $log)"; exit 1; fi
say "window_stacking: PASS (log $log)"
