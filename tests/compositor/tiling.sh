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
# Step 1 (docs/specs/tiling.md TL1-TL15; only when the plugin advertises tiling-arrange; a second foot window):
#   state          `hyprctl grassfield-tiling` lists GF-REF with its work area and grid
#   arrange        arrange({layout:"left-right", windows:[first]}): the first window takes the left half, the next window
#                  in stacking order the right half; both are one tile group in the state reply
#   invalid        an arrange with an unknown layout changes nothing (generation and boxes kept)
#   margins        tilingMargins false places the arrangement again without margins, true with them
#   full-screen    full screen suspends the tile; leaving it puts the window back in its tile (TL12)
#   minimize       a move to special:minimized suspends it; back on its Desktop it returns to its free zone (TL14)
#   zone-taken     minimized again, its zone taken by the other window: back on its Desktop it is Free at its size
#                  from before (TL10)
#   locked         while the foreign locker fixture holds the session lock (tests/security/foreign_locker, released over
#                  its IPC, nothing typed), tile and arrange move nothing and leave the records unchanged (TL34, D4)
# Step 2 (docs/specs/tiling.md TL16-TL20; only with tiling-arrange: Hyprland's moves need the tiling listeners). Super is
# held with scripts/dev/keys.sh (Super+drag is Hyprland's move, bindings.lua), Alt likewise:
#   super-drag     Hyprland's move released at the free edge after the preview delay: that half, a tile record
#   super-out      Hyprland's move of that tiled window to the middle: its size from before, the grip kept under the
#                  pointer (the drag ended and begun again), Free
#   delay          released at the edge before the preview delay (Hyprland's move, then the titlebar drag): no tile
#   alt-drag       the titlebar drag released in the middle with Alt held (no delay): the half on the pointer's side
#   menu-bar-move  Hyprland's move released on the menu bar: Fill (the top clamp leaves the window to the tile)
#   edge           a double-click on the right resize border: the right side at the work area's edge, `sides` "right"
#   alt-corner     an Alt double-click on the bottom-right corner: Fill
#   chromium       Chromium (client chrome: its tab strip asks Hyprland's move) dragged to the free edge: that half, the
#                  preview captured while held; dragged out by its tab strip: its size from before (skipped without it)
#   unload         the plugin unloaded in the middle of Hyprland's move: Hyprland alive, the drag goes on as Hyprland's
#                  own; loaded again
# Step 3 (docs/specs/tiling.md TL22-TL26; only with tile-hover). The plugin's events are read on Hyprland's socket2 (socat);
# the shell's popover, when the shell runs, is closed with Esc after each case:
#   popover-verb   tile_popover(address) posts tile-hover "open" for the window, tileable, its light in the titlebar's band
#   hover          the pointer on that light: no "enter" before tiling.hoverDelay, "enter" after it; moving away posts
#                  "leave"
#   move-to        on another output when there is one: a tiled window takes the same place there (still tiled, that
#                  output's Desktop) and back; a Free window keeps its size and lands on that output (skipped with one
#                  output)
#   move-invalid   move_to an unknown output or the window's own: the `tiling` notice says "invalid", nothing moves
# The locked case above also calls move_to when the plugin has it (TL34): nothing moves.
# Gate C1 (integrator re-reviews of 439e1f2 and 20b62e3; always run, last): a window that UNMAPS while the plugin's titlebar
# drag holds it, the window object alive (its Desktop and layout space are gone: Window.cpp:750, :2639). A closed window is
# no test: Hyprland unmaps and frees it in one step and the titlebar's destructor drops the drag. The victim is
# tests/tools/xdgact, which on SIGUSR2 attaches a null buffer (what an app that closes to the tray does). Each case starts a
# drag past the threshold, unmaps the victim, and then:
#   moving-focused     the pointer moves on, then the release (the victim kept the focus: its unmap releases the held buttons)
#   moving-unfocused   the other window took the focus first (the unmap keeps the held button: the plugin's drag goes on)
#   still-focused      no motion after the unmap, then the release
#   still-unfocused    the focus moved first, no motion after the unmap, then the release
# Hyprland must answer after each, the plugin must log its guarded path ("closed or unmapped"), and coredumpctl must list no
# new Hyprland core dump. A/B against an older build (the integrator's proof that the cases reach the crash):
#   tests/compositor/tiling.sh --c1 --plugin /path/to/439e1f2/grassfield-compositor.so   (expected: FAIL, Hyprland gone)
#   tests/compositor/tiling.sh --c1                                                     (this tree's build: PASS)
# --c1 runs only the gate C1 cases; --plugin PATH unloads compositor/build/grassfield-compositor.so, loads PATH for the run
# and loads the tree's build again at the end (a different path is a different library even if the first stays mapped,
# FR23). Use a fresh nested session for each side of the A/B: a crash ends the session.
# Expected boxes come from the output's reserved area read right before each placement (the plugin reads it at placement,
# TL1: the shell's menu bar and Dock may claim their zones after the run starts). A failed check prints the plugin's
# [grassfield] WARN and ERR lines logged since the previous check. The plugin verbs are called directly (they return a
# no-op dispatcher), never through a Lua function that returns nothing.
# Usage (bare command, nested session of this tree running with the plugin loaded): tests/compositor/tiling.sh
# Logs and captures: .dev/tiling/run-<timestamp>/.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
c1_only=0 plugin_path=""
default_plugin=$root/compositor/build/grassfield-compositor.so
while [[ $# -gt 0 ]]; do
  case $1 in
    --c1) c1_only=1 ;;
    --plugin) plugin_path=${2:?--plugin needs a path}; shift ;;
    *) echo "usage: tests/compositor/tiling.sh [--c1] [--plugin PATH]" >&2; exit 2 ;;
  esac
  shift
done
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
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$DEV_NESTED_SIG/hyprland.log
log_lines() { grep -ac "" "$hyprlog" 2>/dev/null || echo 0; }
# The plugin logged a line matching PATTERN: Hyprland's in-memory log (`hyprctl rollinglog`) or its log file, polled for up to
# 3 s (the file is buffered: a line can reach it seconds late; integrator nested pass of 6355acb). Use a pattern that names the
# window (its address) so that an earlier case's line never matches. No pipe into grep -q (pipefail: SIGPIPE).
plugin_logged() { # pattern
  local _ log
  for _ in $(seq 1 15); do
    log=$(nestctl rollinglog 2>/dev/null)
    grep -aq -- "$1" <<<"$log" && return 0
    grep -aq -- "$1" "$hyprlog" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
log_mark=$(log_lines)
plugin_warnings() {
  local l
  tail -n +"$((log_mark + 1))" "$hyprlog" 2>/dev/null | grep -a '\[grassfield\]' | grep -aE 'WARN|ERR' | tail -n 5 | while IFS= read -r l; do say "  plugin: $l"; done
}
check() {
  local name=$1
  shift
  if "$@"; then say "PASS: $name"; else say "FAIL: $name"; plugin_warnings; fail=1; fi
  log_mark=$(log_lines)
}

swapped=0
restore_plugin() {
  ((swapped)) || return 0
  nestctl plugin unload "$plugin_path" >>"$log" 2>&1
  nestctl plugin load "$default_plugin" >>"$log" 2>&1
  swapped=0
}
if [[ -n $plugin_path ]]; then
  [[ -f $plugin_path ]] || { say "setup error: no plugin at $plugin_path"; exit 2; }
  nestctl plugin unload "$default_plugin" >>"$log" 2>&1
  nestctl plugin load "$plugin_path" >>"$log" 2>&1 || { say "setup error: could not load $plugin_path"; nestctl plugin load "$default_plugin" >>"$log" 2>&1; exit 2; }
  swapped=1
  trap restore_plugin EXIT
  say "plugin for this run: $plugin_path"
  sleep 1
fi
if ((c1_only)); then
  nestctl -j grassfield >/dev/null 2>&1 || say "note: no grassfield plugin answers: the C1 cases then exercise Hyprland alone"
else
  nestctl -j grassfield 2>/dev/null | jq -e '.features | index("window-tiling")' >/dev/null 2>&1 || { say "SKIP: the plugin does not advertise window-tiling (load this tree's plugin)"; exit 2; }
fi

# A settled session before the first case (at most 20 s): the shell's menu bar mapped on GF-REF, and GF-REF's reserved
# area and active Desktop unchanged for 1 s. Started right after nested-up, the run read the free area before the shell
# reserved its zones and found GF-REF on another Desktop than the window (integrator nested pass of 426a676). The Dock is
# not waited for: with two outputs it lives on the one whose edge the pointer last reached.
settle_state() { nestctl monitors -j | jq -r --arg o "$out" '.[] | select(.name == $o) | "reserved \(.reserved) desktop \(.activeWorkspace.id)"'; }
menubar_on_out() { nestctl layers -j 2>/dev/null | jq -e --arg o "$out" '[.[$o] | .. | objects | select(.namespace? == "grassfield-menubar")] | length > 0' >/dev/null 2>&1; }
prev="" same=0 bar=0
for _ in $(seq 1 80); do
  menubar_on_out && bar=1
  cur=$(settle_state)
  if [[ $cur == "$prev" ]]; then same=$((same + 1)); else same=0; prev=$cur; fi
  ((bar && same >= 4)) && break
  sleep 0.25
done
((bar)) && say "settled: the menu bar is mapped on $out, its reserved area and Desktop stable (${prev:-?})" ||
  say "note: no menu bar on $out after 20 s (no shell?): running without it"

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
locker_pid=""
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
foreign_ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG timeout 5 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }
cleanup() {
  if [[ -n $locker_pid ]] && kill -0 "$locker_pid" 2>/dev/null; then
    foreign_ipc unlock >/dev/null # never leave the nested session locked
    sleep 0.5
    kill "$locker_pid" 2>/dev/null
  fi
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  restore_plugin
}
trap cleanup EXIT

alive() { nestctl version -j >/dev/null 2>&1; }

# ---- gate C1: a window that unmaps (alive) during the plugin's titlebar drag (see the header) ----
dumps() { coredumpctl --no-legend --no-pager list 2>/dev/null | grep -ci hyprland || true; }
xdg_addr="" xdg_pid=""
open_xdg() { # app id: an xdgact window on GF-REF; its address in xdg_addr, its pid in xdg_pid
  setsid "$root/scripts/dev/isolated.sh" "$root/tests/tools/xdgact/xdgact.sh" "$1" >>"$run/xdgact.out" 2>&1 </dev/null &
  pids+=("$!")
  xdg_addr="" xdg_pid=""
  for _ in $(seq 1 50); do
    read -r xdg_addr xdg_pid < <(nestctl clients -j | jq -r --arg c "$1" '[.[] | select(.class == $c)][0] | select(. != null) | "\(.address) \(.pid)"')
    [[ -n $xdg_addr ]] && break
    sleep 0.2
  done
  [[ -n $xdg_addr ]] && nestctl dispatch "hl.dsp.window.move({ x = $((mx + 400)), y = $((my + 300)), window = 'address:$xdg_addr' })" >>"$log" 2>&1
  sleep 0.8
}
grip_of() { # address: the middle of its titlebar relative to GF-REF, "px py"
  nestctl clients -j | jq -r --arg a "$1" --argjson mx "$mx" --argjson my "$my" --argjson mid "$GF_TB_MID" \
    '.[] | select(.address == $a) | "\((.at[0] + .size[0] / 2 - $mx) | floor) \((.at[1] - $mid - $my) | floor)"'
}
c1_other=""
run_c1() { # name focused|unfocused moving|still
  local name=$1 focus=$2 motion=$3 px py p
  open_xdg "gf-c1-$name"
  if [[ -z $xdg_addr ]] || ! read -r px py < <(grip_of "$xdg_addr"); then
    check "C1 $name: the victim window opened" false
    return
  fi
  if [[ $motion == moving ]]; then
    pointer abs "$px" "$py" down sleep 150 drag $((px + 40)) "$py" sleep 2200 drag $((px + 120)) $((py + 30)) sleep 150 drag $((px + 160)) $((py + 40)) sleep 300 up &
  else
    pointer abs "$px" "$py" down sleep 150 drag $((px + 40)) "$py" sleep 2200 up &
  fi
  p=$!
  sleep 0.8
  if [[ $focus == unfocused ]]; then
    nestctl dispatch "hl.dsp.focus({ window = 'address:$c1_other' })" >>"$log" 2>&1
    sleep 0.3
  fi
  kill -USR2 "$xdg_pid" 2>/dev/null
  wait "$p"
  sleep 0.8
  check "C1 $name: the dragged window unmapped (alive) during the drag ($focus, $motion): Hyprland alive" alive
  check "C1 $name: the plugin reached its guarded path (\"${xdg_addr#0x} closed or unmapped\") and moved nothing" plugin_logged "${xdg_addr#0x} closed or unmapped"
  kill "$xdg_pid" 2>/dev/null
  sleep 0.3
}
c1_cases() {
  "$root/tests/tools/xdgact/xdgact.sh" --build >>"$log" 2>&1 || { check "C1: tests/tools/xdgact builds" false; return; }
  local dumps0 dumps1
  dumps0=$(dumps)
  open_xdg gf-c1-other
  c1_other=$xdg_addr
  run_c1 moving-focused focused moving
  run_c1 moving-unfocused unfocused moving
  run_c1 still-focused focused still
  run_c1 still-unfocused unfocused still
  if command -v coredumpctl >/dev/null 2>&1; then
    dumps1=$(dumps)
    check "C1: no new Hyprland core dump (coredumpctl: $dumps0 before, $dumps1 after)" test "$dumps1" -le "$dumps0"
  else
    say "SKIP: coredumpctl is not available: the core dump check is left to the integrator"
  fi
}
if ((c1_only)); then
  c1_cases
  check "Hyprland alive" alive
  exit $fail
fi
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
m=8 tb=$GF_TB_HEIGHT
# The free area of GF-REF now and the boxes derived from it; called right before each placement.
area_now() {
  read -r ax ay aw ah < <(area_of "$out")
  halfw=$(((aw - 3 * m) / 2)) halfh=$(((ah - 3 * m) / 2))
  ry=$((ay + m + tb)) fullh=$((ah - 2 * m - tb))
  rx=$((ax + 2 * m + halfw))
  case ${side:-} in
    right) tx=$rx ;;
    left) tx=$((ax + m)) ;;
  esac
}
area_now
say "GF-REF ${mw}x${mh} at $mx,$my, free area ${aw}x${ah} at $ax,$ay, titlebar $tb"

# drag WHERE_X WHERE_Y [hold-capture-name hold-place] (layout coordinates): press on the titlebar's middle, glide to the
# point, release there. pointer.sh takes coordinates relative to GF-REF. With a capture name, the capture is taken once the
# plugin logged that the preview of HOLD-PLACE shows for this window (it waits for the preview delay since tiling step 2,
# TL17; integrator nested pass of 412b42e: a capture taken at a fixed 1.6 s could precede it), one frame later.
drag() {
  local tx=$(($1 - mx)) ty=$(($2 - my)) shot=${3:-} place=${4:-} x y w h _a
  read -r x y w h _a < <(geometry)
  local px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  if [[ -n $shot ]]; then
    pointer abs "$px" "$py" down sleep 150 drag $(((px + tx) / 2)) $(((py + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep 2500 up &
    local p=$!
    if ! plugin_logged "tiling preview ${addr#0x}: $place on "; then
      say "  no \"tiling preview ${addr#0x}: $place\" line within 3 s: the capture is taken anyway"
    fi
    sleep 0.3
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

left_n=$(neighbour_on left) right_n=$(neighbour_on right)
say "layout: left edge ${left_n:-free}, right edge ${right_n:-free}"
# The edge the tiling cases use (free), and the one the shared-edge case uses (another output there).
if [[ -z $right_n ]]; then
  side=right edge_x=$((mx + mw - 1))
elif [[ -z $left_n ]]; then
  side=left edge_x=$mx
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
area_now
drag "$edge_x" $((my + mh / 2)) "tiling-preview-$side" "$side"
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
area_now
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
area_now
drag $((mx + mw / 2)) $((my + 2)) tiling-preview-fill fill
check "menu-bar: released on the menu bar, the free area is filled" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
drag $((mx + mw / 2)) $((my + mh / 2))
check "drag-out after fill: ${w0}x${h0} again" size_is "$w0" "$h0"

area_now
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
sleep 0.8
check "ipc: tile(address, \"left\") places the left half" is_box $((ax + m)) "$ry" "$halfw" "$fullh"
nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
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
  on_neighbour() {
    local mon want
    mon=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')
    want=$(nestctl monitors -j | jq -r --arg o "$neighbour" '.[] | select(.name == $o) | .id')
    say "  monitor of the window: ${mon:-?} (want $neighbour, id ${want:-?})"
    [[ -n $mon && $mon == "$want" ]]
  }
  check "other-output: the window dropped on $neighbour belongs to its Desktop (as after Hyprland's own move)" on_neighbour
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
  sleep 0.8
  check "other-output: tile(address, \"left\") after a drag onto $neighbour places its left half there" is_box $((nx + m)) $((ny + m + tb)) $(((nw - 3 * m) / 2)) $((nh - 2 * m - tb))
  nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
  sleep 0.8
  nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
  sleep 0.8
else
  say "SKIP: other-output (no neighbouring output)"
fi

nestctl dispatch "hl.plugin.grassfield.config(\"tilingEdges\", \"false\")" >>"$log" 2>&1
drag "$edge_x" $((my + mh / 2))
check "options: with tilingEdges false the $side edge does not tile" size_is "$w0" "$h0"
nestctl dispatch "hl.plugin.grassfield.config(\"tilingEdges\", \"true\")" >>"$log" 2>&1

if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-arrange")' >/dev/null 2>&1; then
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  state_has_output() {
    tiling_state | jq -e --arg o "$out" '.type == "tiling" and ([.outputs[] | select(.name == $o and .grid >= 1 and .area.w > 0)] | length == 1)' >/dev/null
  }
  check "state: hyprctl grassfield-tiling lists $out with its work area and grid" state_has_output

  env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" setsid "$root/scripts/dev/isolated.sh" --name tiling \
    foot -T tiling-foot2 -w 700x450 sh -c 'exec sleep 100000' >>"$run/foot.out" 2>&1 </dev/null &
  pids+=("$!")
  geometry_of() { nestctl clients -j | jq -r --arg t "$1" '[.[] | select(.title == $t)][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
  for _ in $(seq 1 100); do [[ -n $(geometry_of tiling-foot2) ]] && break; sleep 0.2; done
  sleep 1
  read -r _ _ _ _ addr2 < <(geometry_of tiling-foot2)
  if [[ -z ${addr2:-} ]]; then
    check "step 1: the second foot window opened" false
  else
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 500)), y = $((my + 300)), window = 'address:$addr2' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1 # on top: the next in stacking order is foot2
    sleep 0.8
    read -r _ _ w2 h2 _ < <(geometry_of tiling-foot2)
    box_of() { # title x y w h (surface), 1 px slack
      local x y w h _a
      read -r x y w h _a < <(geometry_of "$1")
      say "  $1 ${w}x${h} at $x,$y (want ${4}x${5} at $2,$3)"
      (( x - $2 <= 1 && $2 - x <= 1 && y - $3 <= 1 && $3 - y <= 1 && w - $4 <= 1 && $4 - w <= 1 && h - $5 <= 1 && $5 - h <= 1 ))
    }
    record_is() { # address state ("none": no record)
      local got
      got=$(tiling_state | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].state // "none"')
      say "  record of $1: $got (want $2)"
      [[ $got == "$2" ]]
    }
    arrange() { nestctl dispatch "hl.plugin.grassfield.arrange('$1')" >>"$log" 2>&1; sleep 0.8; }
    tile_ipc() { nestctl dispatch "hl.plugin.grassfield.tile(\"$1\", \"$2\")" >>"$log" 2>&1; sleep 0.8; }
    to_ws() { nestctl dispatch "hl.dsp.window.move({ workspace = \"$2\", follow = false, window = \"address:$1\" })" >>"$log" 2>&1; sleep 0.8; }
    area_now
    arrange "{\"layout\":\"left-right\",\"windows\":[\"$addr\"]}"
    check "arrange: left-right from the first window, which takes the left half" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"
    check "arrange: the next window in stacking order fills the right half" box_of tiling-foot2 "$rx" "$ry" "$halfw" "$fullh"
    one_group() {
      tiling_state | jq -e --arg a "${addr#0x}" --arg b "${addr2#0x}" \
        '[.outputs[].windows[] | select(.address == $a or .address == $b)] | length == 2 and (map(.group) | unique | length == 1) and .[0].group > 0 and all(.layout == "left-right")' >/dev/null
    }
    check "arrange: both windows are one tile group in the state reply" one_group

    gen0=$(tiling_state | jq -r '.gen')
    arrange "{\"layout\":\"no-such-layout\",\"windows\":[\"$addr\"]}"
    gen1=$(tiling_state | jq -r '.gen')
    check "invalid: an unknown layout changes nothing (generation $gen0 -> $gen1)" test "$gen0" = "$gen1"
    check "invalid: the window keeps its tile" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"

    area_now
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"false\")" >>"$log" 2>&1
    sleep 0.8
    check "margins off: the arrangement is placed again without margins" box_of tiling-foot "$ax" $((ay + tb)) $((aw / 2)) $((ah - tb))
    nestctl dispatch "hl.plugin.grassfield.config(\"tilingMargins\", \"true\")" >>"$log" 2>&1
    sleep 0.8
    check "margins on: placed again with margins" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"

    nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
    sleep 0.8
    check "full-screen: the tile is suspended" record_is "$addr" suspended
    nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$addr\" })" >>"$log" 2>&1
    sleep 1
    check "full-screen: leaving it puts the window back in its tile" box_of tiling-foot $((ax + m)) "$ry" "$halfw" "$fullh"
    check "full-screen: tiled again" record_is "$addr" tiled

    ws2=$(nestctl clients -j | jq -r --arg a "$addr2" '.[] | select(.address == $a) | .workspace.name')
    to_ws "$addr2" special:minimized
    check "minimize: the tile is suspended" record_is "$addr2" suspended
    to_ws "$addr2" "$ws2"
    check "minimize: back on its Desktop, in its free zone" box_of tiling-foot2 "$rx" "$ry" "$halfw" "$fullh"
    check "minimize: tiled again" record_is "$addr2" tiled

    to_ws "$addr2" special:minimized
    tile_ipc "$addr" right
    to_ws "$addr2" "$ws2"
    size2() { local _x _y w h _a; read -r _x _y w h _a < <(geometry_of tiling-foot2); say "  tiling-foot2 ${w}x${h} (want ${w2}x${h2})"; (( w == w2 && h == h2 )); }
    check "zone-taken: its zone taken meanwhile, it comes back at its size from before" size2
    check "zone-taken: it is Free" record_is "$addr2" none
    tile_ipc "$addr" previous

    WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$DEV_NESTED_SIG GRASSFIELD_FOREIGN_LOCKER=1 DBUS_SESSION_BUS_ADDRESS="${bus:-disabled:}" \
      setsid "$root/scripts/dev/isolated.sh" --name tiling-locker "$root/tests/security/foreign_locker/run.sh" --no-color >>"$run/locker.log" 2>&1 </dev/null &
    locker_pid=$!
    locked=""
    for _ in $(seq 1 60); do
      locked=$(foreign_ipc status)
      [[ $locked == "locked secure" ]] && break
      sleep 0.1
    done
    if [[ $locked == "locked secure" ]]; then
      read -r lx ly lw lh _ < <(geometry_of tiling-foot)
      gen_l0=$(tiling_state | jq -r '.gen')
      tile_ipc "$addr" left
      arrange "{\"layout\":\"quarters\",\"windows\":[\"$addr\"]}"
      # move_to (tiling step 3): refused before the output is even looked up.
      lock_other=$(nestctl monitors -j | jq -r --arg o "$out" '[.[] | select(.name != $o)][0].name // "NO-SUCH-OUTPUT"')
      nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$lock_other\")" >>"$log" 2>&1
      sleep 0.8
      gen_l1=$(tiling_state | jq -r '.gen')
      check "locked: tile, arrange and move_to move nothing while the session is locked" box_of tiling-foot "$lx" "$ly" "$lw" "$lh"
      check "locked: the records are unchanged (generation $gen_l0 -> $gen_l1)" test "$gen_l0" = "$gen_l1"
    else
      check "locked: the foreign locker holds the session lock (${locked:-no answer})" false
    fi
    foreign_ipc unlock >/dev/null
    for _ in $(seq 1 30); do kill -0 "$locker_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$locker_pid" 2>/dev/null && kill "$locker_pid" 2>/dev/null
    locker_pid=""
    sleep 0.5
  fi
else
  say "SKIP: step 1 cases (the plugin does not advertise tiling-arrange)"
fi

# ---- step 2: drags (see the header) ----
if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tiling-arrange")' >/dev/null 2>&1; then
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  record_field() { # address field ("none": no record)
    tiling_state | jq -r --arg a "${1#0x}" --arg f "$2" '[.outputs[].windows[] | select(.address == $a)][0][$f] // "none"'
  }
  record_is() { local got; got=$(record_field "$1" state); say "  record of $1: $got (want $2)"; [[ $got == "$2" ]]; }
  sides_are() { local got; got=$(record_field "$1" sides); say "  sides of $1: $got (want $2)"; [[ $got == "$2" ]]; }
  keys() { "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
  # A pointer gesture with a modifier held through it (keys.sh in the background): <wtype modifier> <hold ms> <pointer args>
  with_mod() {
    local mod=$1 ms=$2 k
    shift 2
    keys -M "$mod" -s "$ms" -m "$mod" &
    k=$!
    sleep 0.3
    pointer "$@"
    wait "$k" 2>/dev/null
    sleep 0.8
  }
  # Super+drag (Hyprland's move) from the window's middle to TO_X TO_Y (layout coordinates), held HOLD ms there.
  super_drag() { # to_x to_y hold_ms
    local x y w h _a fx fy tx=$(($1 - mx)) ty=$(($2 - my))
    read -r x y w h _a < <(geometry)
    fx=$((x + w / 2 - mx)) fy=$((y + h / 2 - my))
    with_mod logo $(($3 + 1800)) abs "$fx" "$fy" sleep 100 down sleep 150 drag $(((fx + tx) / 2)) $(((fy + ty) / 2)) sleep 150 drag "$tx" "$ty" sleep "$3" up
  }
  # The foot window Free at its size from before, at (300, 200) on GF-REF, focused.
  free_foot() {
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    sleep 0.8
  }
  delay=$(jq -r '.tiling.previewDelay.value' "$root/ui/tokens/tokens.json")
  say "step 2: preview delay $delay ms (token tiling.previewDelay)"

  free_foot
  area_now
  super_drag "$edge_x" $((my + mh / 2)) $((delay + 400))
  check "super-drag: Hyprland's move released at the free $side edge after the delay tiles the $side half" is_box "$tx" "$ry" "$halfw" "$fullh"
  check "super-drag: the window has a tile record" record_is "$addr" tiled

  super_drag $((mx + mw / 2)) $((my + mh / 2)) 300
  check "super-out: Hyprland's move takes the tiled window out at its size from before (${w0}x${h0})" size_is "$w0" "$h0"
  grip_kept() {
    local x y w h _a px=$((mx + mw / 2)) py=$((my + mh / 2))
    read -r x y w h _a < <(geometry)
    say "  pointer at $px,$py; window ${w}x${h} at $x,$y"
    (( px - x - w / 2 <= 12 && x + w / 2 - px <= 12 && py > y && py < y + h ))
  }
  check "super-out: the grip stays under the pointer (the window's middle, as pressed on the tile)" grip_kept
  check "super-out: the window is Free" record_is "$addr" none

  free_foot
  super_drag "$edge_x" $((my + mh / 2)) 40
  check "delay: Hyprland's move released at the edge before the delay does not tile (${w0}x${h0} kept)" size_is "$w0" "$h0"
  # Back at (300, 200) first: Hyprland's move above left the window's middle on the edge, and a titlebar drag pressed there
  # rests on the place from the press (integrator nested pass of 412b42e).
  free_foot
  read -r x y w h _a < <(geometry)
  px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my))
  pointer abs "$px" "$py" down sleep 150 drag $(((px + edge_x - mx) / 2)) $(((py + mh / 2) / 2)) sleep 150 drag $((edge_x - mx)) $((mh / 2)) sleep 40 up
  sleep 0.8
  check "delay: the titlebar drag released at the edge before the delay does not tile either" size_is "$w0" "$h0"

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  px=$((x + w / 2 - mx)) py=$((y - GF_TB_MID - my)) qx=$((ax - mx + aw * 2 / 5)) qy=$((ay - my + ah / 2))
  with_mod alt 2600 abs "$px" "$py" sleep 100 down sleep 150 drag $(((px + qx) / 2)) $(((py + qy) / 2)) sleep 150 drag "$qx" "$qy" sleep 100 up
  check "alt-drag: released in the middle with Alt held, at once, the left half (the pointer left of the middle)" is_box $((ax + m)) "$ry" "$halfw" "$fullh"

  free_foot
  area_now
  super_drag $((mx + mw / 2)) $((my + 2)) $((delay + 400))
  check "menu-bar-move: Hyprland's move released on the menu bar fills the free area (not the top clamp's box)" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  bx=$((x + w + 3 - mx)) by=$((y + h / 2 - my)) # 3 px right of the surface: Hyprland's border grab (resize_on_border)
  pointer abs $((bx + 40)) "$by" sleep 150 abs "$bx" "$by" sleep 200 click sleep 120 click
  sleep 0.8
  check "edge: a double-click on the right border extends the right side to the work area's edge" is_box "$x" "$y" $((ax + aw - m - x)) "$h"
  check "edge: the window is tiled with its right side extended (sides \"right\")" sides_are "$addr" right

  free_foot
  area_now
  read -r x y w h _a < <(geometry)
  cx=$((x + w + 3 - mx)) cy=$((y + h + 3 - my))
  with_mod alt 2600 abs $((cx + 40)) $((cy + 40)) sleep 150 abs "$cx" "$cy" sleep 200 click sleep 120 click
  check "alt-corner: an Alt double-click on the bottom-right corner fills the work area" is_box $((ax + m)) "$ry" $((aw - 2 * m)) "$fullh"
  free_foot

  if command -v chromium >/dev/null; then
    dead_proxy=127.0.0.1:9
    rm -rf "$run/chromium-profile"
    http_proxy=http://$dead_proxy https_proxy=http://$dead_proxy all_proxy=http://$dead_proxy no_proxy='' \
      env -u DISPLAY WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="$bus" GDK_BACKEND=wayland setsid "$root/scripts/dev/isolated.sh" --name tiling-chromium -- \
      chromium --user-data-dir="$run/chromium-profile" --no-first-run --no-default-browser-check --password-store=basic --disable-background-networking \
      --disable-component-update --disable-sync --proxy-server="$dead_proxy" --ozone-platform=wayland --window-size=1000,640 about:blank \
      >>"$run/chromium.out" 2>&1 </dev/null &
    pids+=("$!")
    chrome() { nestctl clients -j | jq -r '[.[] | select(.class == "chromium")][0] | select(. != null) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.address)"'; }
    for _ in $(seq 1 80); do [[ -n $(chrome) ]] && break; sleep 0.25; done
    read -r _ _ _ _ caddr < <(chrome)
    if [[ -n ${caddr:-} ]]; then
      sleep 2
      nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 250)), window = 'address:$caddr' })" >>"$log" 2>&1
      sleep 0.8
      read -r cx0 cy0 cw0 ch0 _ < <(chrome)
      chrome_box() { # x y w h (client chrome: no titlebar band), 1 px slack
        local x y w h _a
        read -r x y w h _a < <(chrome)
        say "  chromium ${w}x${h} at $x,$y (want ${3}x${4} at $1,$2)"
        (( x - $1 <= 1 && $1 - x <= 1 && y - $2 <= 1 && $2 - y <= 1 && w - $3 <= 1 && $3 - w <= 1 && h - $4 <= 1 && $4 - h <= 1 ))
      }
      gx=$((cx0 + cw0 * 3 / 4 - mx)) gy=$((cy0 + 18 - my)) # empty tab strip
      pointer abs "$gx" $((gy + 3)) sleep 120 abs "$gx" "$gy" sleep 200 click sleep 700 # focus first
      area_now
      pointer abs "$gx" "$gy" sleep 200 down sleep 150 drag $(((gx + edge_x - mx) / 2)) "$gy" sleep 150 drag $((edge_x - mx)) $((mh / 2)) sleep 1800 up &
      p=$!
      sleep 1.4
      "$root/scripts/dev/shot.sh" tiling-chromium-preview "$out" >>"$log" 2>&1 && cp "$dev/shots/tiling-chromium-preview.png" "$run/" 2>/dev/null
      wait "$p"
      sleep 0.8
      check "chromium: dragged by its tab strip (Hyprland's move) to the free $side edge, the $side half" chrome_box "$tx" $((ay + m)) "$halfw" $((ah - 2 * m))
      read -r tcx tcy tcw _ _ < <(chrome)
      gx=$((tcx + tcw * 3 / 4 - mx)) gy=$((tcy + 18 - my))
      pointer abs "$gx" "$gy" sleep 200 down sleep 150 drag $((gx - 200)) $((gy + 150)) sleep 150 drag $((mw / 2)) $((mh / 2)) sleep 300 up
      sleep 0.8
      chrome_size() { local _x _y w h _a; read -r _x _y w h _a < <(chrome); say "  chromium ${w}x${h} (want ${cw0}x${ch0})"; (( w == cw0 && h == ch0 )); }
      check "chromium: dragged out by its tab strip, its size from before (the restarted move keeps the app's grab)" chrome_size
    else
      check "chromium: mapped" false
    fi
    pkill -f -- "--user-data-dir=$run/chromium-profile" 2>/dev/null
  else
    say "SKIP: chromium (not installed): the client-chrome drag case is NOT VERIFIED here"
  fi

  current_plugin=${plugin_path:-$default_plugin}
  free_foot
  read -r x y w h _a < <(geometry)
  fx=$((x + w / 2 - mx)) fy=$((y + h / 2 - my))
  keys -M logo -s 5200 -m logo &
  k=$!
  sleep 0.3
  pointer abs "$fx" "$fy" sleep 100 down sleep 150 drag $((fx + 100)) "$fy" sleep 2600 drag $((fx + 220)) "$fy" sleep 300 up &
  p=$!
  sleep 1.6
  nestctl plugin unload "$current_plugin" >>"$log" 2>&1
  wait "$p"
  wait "$k" 2>/dev/null
  sleep 0.8
  check "unload: Hyprland alive after the plugin unloaded in the middle of Hyprland's move" alive
  moved_on() { local x1 _y _w _h _a; read -r x1 _y _w _h _a < <(geometry); say "  x $x -> ${x1:-?} (want about +220)"; [[ -n ${x1:-} ]] && (( x1 - x >= 150 )); }
  check "unload: the drag went on as Hyprland's own" moved_on
  nestctl plugin load "$current_plugin" >>"$log" 2>&1
  sleep 1.5
  check "unload: loaded again, the plugin advertises window-tiling" bash -c "timeout 10 '$root/scripts/nestctl' -j grassfield 2>/dev/null | jq -e '.features | index(\"window-tiling\")' >/dev/null"
else
  say "SKIP: step 2 cases (the plugin does not advertise tiling-arrange)"
fi

# ---- step 3: the zoom light's popover and move_to (see the header) ----
if nestctl -j grassfield 2>/dev/null | jq -e '.features | index("tile-hover")' >/dev/null 2>&1; then
  events=$run/events.log
  socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$DEV_NESTED_SIG/.socket2.sock" STDOUT >"$events" 2>>"$log" </dev/null &
  pids+=("$!")
  sleep 0.3
  tiling_state() { nestctl grassfield-tiling 2>>"$log"; }
  record_is() { # address state ("none": no record)
    local got
    got=$(tiling_state | jq -r --arg a "${1#0x}" '[.outputs[].windows[] | select(.address == $a)][0].state // "none"')
    say "  record of $1: $got (want $2)"
    [[ $got == "$2" ]]
  }
  keys() { "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
  close_popover() { keys -k Escape; sleep 0.5; }
  move_to() { nestctl dispatch "hl.plugin.grassfield.move_to(\"$addr\", \"$1\")" >>"$log" 2>&1; sleep 0.8; }
  free_foot() {
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"previous\")" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.window.move({ x = $((mx + 300)), y = $((my + 200)), window = 'address:$addr' })" >>"$log" 2>&1
    nestctl dispatch "hl.dsp.focus({ window = 'address:$addr' })" >>"$log" 2>&1
    sleep 0.8
  }
  ev_mark=0
  mark_events() { ev_mark=$(grep -ac "" "$events" 2>/dev/null || echo 0); }
  # The gfc/1 events (JSON, one per line) posted since mark_events that match the jq filter FILTER.
  events_since() { tail -n +"$((ev_mark + 1))" "$events" 2>/dev/null | sed -n 's/^grassfield>>//p' | jq -cR "fromjson? | select($1)" 2>/dev/null; }
  # The latest such event, waited for up to 3 s.
  event_came() { # filter
    local _ line
    for _ in $(seq 1 30); do
      line=$(events_since "$1" | tail -n 1)
      [[ -n $line ]] && { last_event=$line; return 0; }
      sleep 0.1
    done
    return 1
  }
  hover_filter() { echo ".type == \"tile-hover\" and .address == \"${addr#0x}\" and .state == \"$1\""; }
  hover_delay=$(jq -r '.tiling.hoverDelay.value' "$root/ui/tokens/tokens.json")
  say "step 3: hover delay $hover_delay ms (token tiling.hoverDelay)"

  free_foot
  mark_events
  nestctl dispatch "hl.plugin.grassfield.tile_popover(\"$addr\")" >>"$log" 2>&1
  last_event=""
  check "popover-verb: tile_popover posts tile-hover open for the window" event_came "$(hover_filter open)"
  open_event=$last_event
  say "  event: $open_event"
  light_on_bar() {
    local x y w h _a lx ly lw lh
    read -r x y w h _a < <(geometry)
    read -r lx ly lw lh < <(jq -r '"\(.x) \(.y) \(.w) \(.h)"' <<<"$open_event" 2>/dev/null)
    say "  light ${lw:-?}x${lh:-?} at ${lx:-?},${ly:-?}; surface at $x,$y, titlebar $tb"
    [[ -n ${lh:-} ]] && awk -v lx="$lx" -v ly="$ly" -v lw="$lw" -v lh="$lh" -v x="$x" -v y="$y" -v tb="$tb" \
      'BEGIN { cy = ly + lh / 2; exit !(lw > 0 && lh > 0 && lx >= x && lx + lw <= x + 120 && cy > y - tb && cy < y) }'
  }
  check "popover-verb: the light is the zoom light, at the left of the window's titlebar" light_on_bar
  check "popover-verb: the window can be tiled (tileable)" bash -c "jq -e '.tileable == true' <<<'$open_event' >/dev/null 2>&1"
  close_popover

  if [[ -n $open_event ]]; then
    read -r lcx lcy < <(jq -r '"\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"' <<<"$open_event")
    pointer abs $((lcx - mx + 200)) $((lcy - my + 150)) sleep 200
    mark_events
    pointer abs $((lcx - mx)) $((lcy - my)) sleep 300
    no_early_enter() { [[ -z $(events_since "$(hover_filter enter)") ]]; }
    check "hover: no enter before tiling.hoverDelay" no_early_enter
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 500) / 1000 }')"
    check "hover: the pointer resting on the zoom light posts tile-hover enter" event_came "$(hover_filter enter)"
    check "hover: the enter carries the same light" bash -c "jq -e --argjson o '$open_event' '.x == \$o.x and .y == \$o.y' <<<'${last_event:-null}' >/dev/null 2>&1"
    pointer abs $((lcx - mx + 300)) $((lcy - my + 200)) sleep 300
    check "hover: leaving the light posts tile-hover leave" event_came "$(hover_filter leave)"
    sleep "$(awk -v d="$hover_delay" 'BEGIN { print (d + 300) / 1000 }')" # the shell's popover closes by itself
    close_popover
  else
    check "hover: needs the light from the open event" false
  fi

  other=$(nestctl monitors -j | jq -r --arg o "$out" '[.[] | select(.name != $o)][0].name // ""')
  if [[ -n $other ]]; then
    free_foot
    area_now
    nestctl dispatch "hl.plugin.grassfield.tile(\"$addr\", \"left\")" >>"$log" 2>&1
    sleep 0.8
    move_to "$other"
    read -r oax oay oaw oah < <(area_of "$other")
    check "move-to: the tiled window takes the left half of $other" is_box $((oax + m)) $((oay + m + tb)) $(((oaw - 3 * m) / 2)) $((oah - 2 * m - tb))
    check "move-to: still tiled" record_is "$addr" tiled
    on_desktop_of() { # output
      local ws want
      ws=$(nestctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')
      want=$(nestctl monitors -j | jq -r --arg o "$1" '.[] | select(.name == $o) | .activeWorkspace.id')
      say "  Desktop $ws (want $want, $1's)"
      [[ -n $ws && $ws == "$want" ]]
    }
    check "move-to: it is on $other's Desktop" on_desktop_of "$other"
    area_now
    move_to "$out"
    check "move-to: back on $out, its left half" is_box $((ax + m)) "$ry" "$halfw" "$fullh"
    free_foot
    read -r _ _ fw fh _ < <(geometry)
    move_to "$other"
    free_on_other() {
      local x y w h _a
      read -r x y w h _a < <(geometry)
      say "  ${w}x${h} at $x,$y (want ${fw}x${fh}, at most ${oaw}x${oah}, its middle on $other at $oax,$oay)"
      (( x + w / 2 >= oax && x + w / 2 < oax + oaw && y + h / 2 >= oay && y + h / 2 < oay + oah )) &&
        (( (w == fw || w <= oaw) && (h == fh || h <= oah) ))
    }
    check "move-to: a Free window keeps its size and lands on $other" free_on_other
    check "move-to: still Free" record_is "$addr" none
    move_to "$out"
  else
    say "SKIP: move-to (one output: the Move to <display> rows are not shown either)"
  fi

  free_foot
  read -r bx by bw bh _ < <(geometry)
  mark_events
  move_to "NO-SUCH-OUTPUT"
  check "move-invalid: an unknown output is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
  mark_events
  move_to "$out"
  check "move-invalid: the window's own output is refused (reason invalid)" event_came '.type == "tiling" and .reason == "invalid"'
  check "move-invalid: nothing moved" is_box "$bx" "$by" "$bw" "$bh"
else
  say "SKIP: step 3 cases (the plugin does not advertise tile-hover)"
fi

c1_cases

check "Hyprland alive" alive
exit $fail
