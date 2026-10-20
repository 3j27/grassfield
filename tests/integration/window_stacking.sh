#!/usr/bin/env bash
# Stacking scenario (macOS model, config/hypr/grassfield/stacking.lua): a press on the visible part of a window that sits
# behind another one brings that window to the front, whole.
#
# Usage: tests/integration/window_stacking.sh
# NESTED only: needs scripts/dev/nested-up.sh. Pointer input goes through scripts/dev/pointer.sh, clients through
# scripts/dev/isolated.sh with the nested socket only, hyprctl is read-only (scripts/nestctl -j clients) and the pixel
# check uses grim on the nested output. Needs grassfield-compositor loaded (the windows are placed by dragging B's titlebar).
#
# Two foot windows with different background colours (A red, B blue), both floating:
#   1 B is dragged so that it overlaps A partly; B is then in front (pixel in the overlap is blue)
#   2 press on the visible part of A (outside the overlap): A is active, in front in the pixel check (red in the overlap)
#     and last in the stacking order of `nestctl -j clients`
#   3 press on the visible part of B: B in front again (blue in the overlap)
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log and captures: .dev/window-stacking/run-<timestamp>.*
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${WS_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK

for tool in jq foot grim xxd; do
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
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --title "$2" -W 800x500 \
    -o "colors-dark.background=$1" -o "colors-light.background=$1" -o colors-dark.alpha=1 -o colors-light.alpha=1 \
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
  WAYLAND_DISPLAY=$sock grim -g "$((mon_x + $1)),$((mon_y + $2)) 1x1" -t ppm - 2>>"$log" | tail -c 3 | xxd -p
}
shot() { WAYLAND_DISPLAY=$sock grim -o "$out" "$work/run-$stamp-$1.png" 2>>"$log"; say "  capture: $work/run-$stamp-$1.png"; }
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

# 1 Move B over the lower right part of A: drag from the middle of B's titlebar (14 px above its surface).
dx=$((aw * 6 / 10))
dy=$((ah * 4 / 10))
pointer abs $((bx + bw / 2)) $((by - 14)) sleep 50 down drag $((bx + bw / 2 + dx)) $((by - 14 + dy)) sleep 50 up sleep 500
read -r bx by bw bh _ _ < <(geom gf-stack-b)
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

if ((fail)); then say "window_stacking: FAIL (log $log)"; exit 1; fi
say "window_stacking: PASS (log $log)"
