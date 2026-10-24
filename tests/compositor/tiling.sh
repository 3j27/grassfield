#!/usr/bin/env bash
# Window tiling (macOS 15+ model, docs/specs/compositor.md FR47-FR50) on GF-REF. The nested layout varies: WAYLAND-1 may
# touch GF-REF's left edge (a fresh session) or its right edge (after tests/compositor/overview_focus.sh), or neither. The
# layout is read first; the edge cases run on a FREE edge (right when free, else left) and the shared-edge case on
# whichever edge another output touches. A foot window is dragged by its titlebar (one pointer invocation per press and
# release):
#   free-edge      released at the free edge: that half of the free area (margins 8, below the menu bar)
#   preview        a capture while the button is still down at the edge shows the frame as the blurred material (D-8):
#                  a pattern window behind it loses its detail (measured), and the capture is kept for the eye
#   drag-out       a drag of the tiled window away from the edge: it gets its size from before back
#   top-corner     released at the top of the free edge: that top quarter
#   shared-edge    released at an edge another output touches: no tiling (the window just moves over); skipped when no
#                  output touches GF-REF
#   other-output   dragged by its titlebar until its middle is on that neighbouring output, then tile(address, "left"):
#                  the left half of THAT output (the plugin's own drag does not update Hyprland's window monitor, R13)
#   menu-bar       released on the menu bar: the free area is filled
#   ipc            hl.plugin.grassfield.tile(address, "left"), then "previous": the left half, then the size from before
#   options        with tilingEdges false a drag to the right edge does not tile
# Usage (bare command, nested session of this tree running with the plugin loaded): tests/compositor/tiling.sh
# Logs and captures: .dev/tiling/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=GF-REF
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK
bus=$(cat "$dev/bus.address" 2>/dev/null || true)

run=$dev/tiling/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
pointer() { timeout 30 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
fail=0
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; else say "FAIL: $name"; fail=1; fi
}

nestctl -j grassfield 2>/dev/null | jq -e '.features | index("window-tiling")' >/dev/null 2>&1 || { say "SKIP: the plugin does not advertise window-tiling (load this tree's plugin)"; exit 2; }

read -r mx my mw mh rtop rbottom < <(nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height) \(.reserved[1]) \(.reserved[3])"')
# Free area of any output: "x y w h" (reserved = [left, top, right, bottom]).
area_of() { nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | "\(.x + .reserved[0]) \(.y + .reserved[1]) \(.width - .reserved[0] - .reserved[2]) \(.height - .reserved[1] - .reserved[3])"'; }
# Another output that touches GF-REF's left (or right) edge over an overlapping span: its name, or "".
neighbour_on() { # left|right
  nestctl monitors -j | jq -r --arg o "$out" --arg side "$1" --argjson x "$mx" --argjson w "$mw" --argjson y "$my" --argjson h "$mh" \
    '[.[] | select(.name != $o and .y < ($y + $h) and (.y + .height) > $y
       and (if $side == "left" then (.x + .width) == $x else .x == ($x + $w) end)) | .name][0] // ""'
}

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
  foot -T tiling-foot -w 800x500 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
pids+=("$!")

geometry() { nestctl clients -j | jq -r '[.[] | select(.title == "tiling-foot")][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
for _ in $(seq 1 100); do [[ -n $(geometry) ]] && break; sleep 0.2; done
sleep 1
read -r x0 y0 w0 h0 addr < <(geometry)
[[ -n ${addr:-} ]] || { say "setup error: no foot window"; exit 2; }
# The window may open on the other output: put it on GF-REF.
nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
sleep 0.8
read -r x0 y0 w0 h0 addr < <(geometry)
say "foot ${w0}x${h0} at $x0,$y0 ($addr)"

# Free area and the expected boxes (core/Tiling.cpp: margin 8 around and between, titlebar above each surface), read
# once the session settled: right after nested-up the menu bar may not reserve its strip yet.
read -r ax ay aw ah < <(area_of "$out")
m=8 tb=$GF_TB_HEIGHT
halfw=$(((aw - 3 * m) / 2)) halfh=$(((ah - 3 * m) / 2))
say "GF-REF ${mw}x${mh} at $mx,$my, free area ${aw}x${ah} at $ax,$ay, titlebar $tb"

# drag WHERE_X WHERE_Y [hold-capture-name] (layout coordinates): press on the titlebar's middle, glide to the point,
# release there. pointer.sh takes coordinates relative to GF-REF.
drag() {
  local tx=$(($1 - mx)) ty=$(($2 - my)) shot=${3:-} x y w h _a
  read -r x y w h _a < <(geometry)
  local px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  if [[ -n $shot ]]; then
    pointer abs "$px" "$py" down sleep 150 drag $(((px + tx) / 2)) $(((py + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep 2500 up &
    local p=$!
    sleep 1.6
    "$root/scripts/dev/shot.sh" "$shot" "$out" >>"$log" 2>&1 && cp "$dev/shots/$shot.png" "$run/" 2>/dev/null
    wait "$p"
  else
    pointer abs "$px" "$py" down sleep 150 drag $(((px + tx) / 2)) $(((py + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep 400 up
  fi
  sleep 0.8
}
is_box() { # x y w h (surface), 1 px slack
  local x y w h _a
  read -r x y w h _a < <(geometry)
  say "  foot ${w}x${h} at $x,$y (want ${3}x${4} at $1,$2)"
  (( x - $1 <= 1 && $1 - x <= 1 && y - $2 <= 1 && $2 - y <= 1 && w - $3 <= 1 && $3 - w <= 1 && h - $4 <= 1 && $4 - h <= 1 ))
}
size_is() { local _x _y w h _a; read -r _x _y w h _a < <(geometry); say "  foot ${w}x${h} (want ${1}x${2})"; (( w == $1 && h == $2 )); }

ry=$((ay + m + tb)) fullh=$((ah - 2 * m - tb))
left_n=$(neighbour_on left) right_n=$(neighbour_on right)
say "layout: left edge ${left_n:-free}, right edge ${right_n:-free}"
# The edge the tiling cases use (free), and the one the shared-edge case uses (another output there).
if [[ -z $right_n ]]; then
  side=right edge_x=$((mx + mw - 1)) tx=$((ax + 2 * m + halfw))
elif [[ -z $left_n ]]; then
  side=left edge_x=$mx tx=$((ax + m))
else
  say "SKIP: both edges of $out are shared ($left_n, $right_n): no free edge to tile at"
  exit 2
fi
shared_side="" shared_x="" neighbour=""
if [[ -n $left_n ]]; then shared_side=left shared_x=$mx neighbour=$left_n; fi
if [[ -n $right_n ]]; then shared_side=right shared_x=$((mx + mw - 1)) neighbour=$right_n; fi
# x of a box of width W (output px from GF-REF's left) on the free side: the right-side value, mirrored for the left side.
sidex() { if [[ $side == right ]]; then echo "$1"; else echo $((mw - $1 - $2)); fi; }
# preview (owner decision D-8): the frame is the blurred material, not alpha only. A pattern window (black text on white)
# lies behind the right half; the detail of a crop of it (grey standard deviation) seen through the preview must fall
# far below what an alpha-only pane leaves (a pane at the tint's opacity keeps about 1 - alpha = 55 % of it; Hyprland's
# blur keeps almost none). The crop (output px) is inside the preview, beside the dragged window (which hangs over the
# edge from the pointer), over the pattern; both are mirrored when the free edge is the left one.
env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
  foot -T tiling-pattern -w 760x600 -o colors-dark.background=ffffff -o colors-light.background=ffffff \
  -o colors-dark.foreground=000000 -o colors-light.foreground=000000 -o colors-dark.alpha=1 -o colors-light.alpha=1 \
  sh -c 'i=0; while [ $i -lt 60 ]; do echo "MWMW#### |||| ==== MWMW#### |||| ==== MWMW#### ||||"; i=$((i + 1)); done; printf "\033[?25l"; exec sleep 100000' \
  >>"$run/foot.out" 2>&1 </dev/null &
pattern_pid=$!
pids+=("$pattern_pid")
pattern_addr=""
for _ in $(seq 1 50); do
  pattern_addr=$(nestctl clients -j | jq -r '[.[] | select(.title == "tiling-pattern")][0].address // ""')
  [[ -n $pattern_addr ]] && break
  sleep 0.2
done
crop_x=$(sidex 1150 300)
detail() { magick "$1" -crop "300x200+$crop_x+330" +repage -colorspace Gray -format '%[fx:int(standard_deviation*2550)/10]' info: 2>>"$log"; }
if [[ -n $pattern_addr ]]; then
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + $(sidex 1100 760))), y = $((my + 300)), window = 'address:$pattern_addr' })" >>"$log" 2>&1
  nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
  sleep 1
  "$root/scripts/dev/shot.sh" tiling-pattern-baseline "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-pattern-baseline.png" "$run/" 2>/dev/null
fi
drag "$edge_x" $((my + mh / 2)) "tiling-preview-$side"
if [[ -n $pattern_addr ]]; then
  d0=$(detail "$run/tiling-pattern-baseline.png")
  d1=$(detail "$run/tiling-preview-$side.png")
  check "preview: the windows behind the frame are blurred (detail ${d1:-?} under it, ${d0:-?} without it; under 30 %)" \
    awk -v a="${d1:-999}" -v b="${d0:-0}" 'BEGIN { exit !(b >= 20 && a < 0.3 * b) }'
else
  check "preview: the pattern window opened" false
fi
kill "$pattern_pid" 2>/dev/null
sleep 0.5
check "free-edge: released at the free $side edge, the window fills the $side half" is_box "$tx" "$ry" "$halfw" "$fullh"
drag $((mx + mw / 2)) $((my + mh / 2))
check "drag-out: dragged away from the tile, the window gets ${w0}x${h0} back" size_is "$w0" "$h0"
drag "$edge_x" $((my + 40))
check "top-corner: released at the top of the $side edge, the top-$side quarter" is_box "$tx" "$ry" "$halfw" $((halfh - tb))
drag $((mx + mw / 2)) $((my + mh / 2))
if [[ -n $shared_side ]]; then
  drag "$shared_x" $((my + mh / 2))
  read -r cx cy cw ch _ < <(geometry)
  say "  $shared_side edge shared with $neighbour: ${cw}x${ch} at $cx,$cy"
  check "shared-edge: the $shared_side edge touches $neighbour, no tiling (size kept)" test "$cw" -eq "$w0" -a "$ch" -eq "$h0"
  drag $((mx + mw / 2)) $((my + mh / 2))
else
  say "SKIP: shared-edge (no output touches $out)"
fi
drag $((mx + mw / 2)) $((my + 2)) tiling-preview-fill
check "menu-bar: released on the menu bar, the free area is filled" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
drag $((mx + mw / 2)) $((my + mh / 2))
check "drag-out after fill: ${w0}x${h0} again" size_is "$w0" "$h0"

nestctl dispatch "(function() hl.plugin.grassfield.tile(\"$addr\", \"left\") end)()" >>"$log" 2>&1
sleep 0.8
check "ipc: tile(address, \"left\") places the left half" is_box $((ax + m)) "$ry" "$halfw" "$fullh"
nestctl dispatch "(function() hl.plugin.grassfield.tile(\"$addr\", \"previous\") end)()" >>"$log" 2>&1
sleep 0.8
check "ipc: tile(address, \"previous\") gives ${w0}x${h0} back" size_is "$w0" "$h0"

# other-output: press near the titlebar's far end and drag to the shared edge, so that the window's middle is on the
# neighbouring output; the IPC tile must use that output (R13 finding 1).
# The nested WAYLAND-1 output is a window in the owner's session and can be resized at any time: the neighbour is checked
# again right before, and the step is skipped when the window's middle does not land on it.
neighbour=""
[[ -n $shared_side ]] && neighbour=$(neighbour_on "$shared_side")
nbox=$([[ -n $neighbour ]] && nestctl monitors -j | jq -r --arg o "$neighbour" '.[] | select(.name == $o) | "\(.x) \(.width)"')
if [[ -n $neighbour ]]; then
  read -r x y w h _a < <(geometry)
  if [[ $shared_side == left ]]; then
    pointer abs $((x + w - 40 - mx)) $((y - GF_TB_MID - my)) down sleep 150 drag 400 $((y - GF_TB_MID - my)) sleep 150 drag 2 $((y - GF_TB_MID - my)) sleep 400 up
  else
    pointer abs $((x + 40 - mx)) $((y - GF_TB_MID - my)) down sleep 150 drag $((mw - 400)) $((y - GF_TB_MID - my)) sleep 150 drag $((mw - 2)) $((y - GF_TB_MID - my)) sleep 400 up
  fi
  sleep 0.8
  read -r x y w h _a < <(geometry)
  read -r nbx nbw <<<"$nbox"
  say "  dragged over to $neighbour (${nbw} wide at x $nbx): ${w}x${h} at $x,$y (middle x $((x + w / 2)))"
  read -r nx ny nw nh < <(area_of "$neighbour")
fi
if [[ -n $neighbour ]] && (( x + w / 2 < nbx || x + w / 2 >= nbx + nbw )); then
  say "SKIP: other-output (the window's middle is not on $neighbour: the nested output changed size)"
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
elif [[ -n $neighbour ]]; then
  nestctl dispatch "(function() hl.plugin.grassfield.tile(\"$addr\", \"left\") end)()" >>"$log" 2>&1
  sleep 0.8
  check "other-output: tile(address, \"left\") after a drag onto $neighbour places its left half there" is_box $((nx + m)) $((ny + m + tb)) $(((nw - 3 * m) / 2)) $((nh - 2 * m - tb))
  nestctl dispatch "(function() hl.plugin.grassfield.tile(\"$addr\", \"previous\") end)()" >>"$log" 2>&1
  sleep 0.8
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
else
  say "SKIP: other-output (no neighbouring output)"
fi

nestctl dispatch "(function() hl.plugin.grassfield.config(\"tilingEdges\", \"false\") end)()" >>"$log" 2>&1
drag "$edge_x" $((my + mh / 2))
check "options: with tilingEdges false the $side edge does not tile" size_is "$w0" "$h0"
nestctl dispatch "(function() hl.plugin.grassfield.config(\"tilingEdges\", \"true\") end)()" >>"$log" 2>&1

alive() { nestctl version -j >/dev/null 2>&1; }
check "Hyprland alive" alive
exit $fail
