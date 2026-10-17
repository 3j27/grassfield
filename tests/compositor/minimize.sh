#!/usr/bin/env bash
# Minimize / restore scenario (master-prompt §5.6 feature 2): real pointer on the titlebar's minimize button,
# restore through a click on the window's Dock tile, rapid repetition, windows closed mid-animation.
#
# Usage: tests/compositor/minimize.sh [repeats]          (default 20)
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded (feature "minimize") and
# grassfield-shell running (it answers the plugin's minimize-request with hl.plugin.grassfield.minimize and
# draws the Dock). Pointer input goes through scripts/dev/pointer.sh, clients get the nested socket only,
# hyprctl is used read-only (clients, activewindow, monitors, grassfield) against the nested instance, and the
# plugin's events are read from the nested socket2 (socat, read-only subscription).
#
# Steps (one foot window A on MZ_OUTPUT, default GF-REF):
#   1 minimize A with its minimize button: A ends on special:minimized, a `minimized` event is posted, the
#     Dock gains a tile; back-to-back screenshots of the whole layout during the animation (frames/, contact
#     sheets minimize-frames.png / restore-frames.png, count of frames showing the animation);
#   2 restore A with a click on its Dock tile: `restored` event, A back on its workspace at its geometry, focused;
#   3 repeat minimize + restore <repeats> times quickly; every 4th round the Dock tile is clicked while the
#     minimize animation is still running; A must end at its geometry;
#   4 a window closed during its minimize animation, another one closed during its restore animation;
#   5 nested Hyprland alive, no core dump of its PID, no grassfield exception in its log.
# The Dock tile position is computed like shell/dock/Dock.qml does (tokens from ui/Grassfield/Ui/Tokens.qml,
# one tile per pinned app with a desktop entry and per running unpinned app, a separator, the minimized
# tiles, the Trash), centered on the output. MZ_DOCK_APPS overrides the number of app tiles.
# The animation itself is reported (not asserted): time from the plugin's move of the window to its
# minimized/restored event (~300 ms when animated; ~0 when the rectangle the shell sent was rejected, e.g. the
# Dock of Quickshell.screens[0] laid out for an output size that changed since), plus captures requested
# 0-90 ms after the animation started and the number of them that differ from both the start and the end state.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/minimize/run-<timestamp>/run.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
repeats=${1:-20}
[[ $repeats =~ ^[0-9]+$ ]] || { echo "usage: minimize.sh [repeats]" >&2; exit 2; }
out=${MZ_OUTPUT:-GF-REF}

sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
shell_pid=$(cat "$dev/shell.pid" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "minimize: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "minimize: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "minimize: grassfield-shell is not running (scripts/dev/shell-run.sh)" >&2; exit 2; }
command -v socat >/dev/null || { echo "minimize: socat is needed to read the plugin's events" >&2; exit 2; }

query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only queries only
query grassfield | jq -e '.features | index("minimize")' >/dev/null 2>&1 \
  || { echo "minimize: the loaded plugin does not advertise \"minimize\"" >&2; exit 2; }

run=$dev/minimize/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
start_human=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
shot() { WAYLAND_DISPLAY=$sock grim -l 0 -o "$out" "$run/$1.png" 2>>"$log"; }
# Captures of the whole layout (every output: the Dock tile the shell targets may be on another output),
# uncompressed, requested 0, 30, 60 and 90 ms after the plugin moved the window (its movewindowv2 event
# starts the 300 ms animation). Each runs in its own grim, whose start-up and screencopy round trip add
# ~100-200 ms before the frame is taken. File names carry the request delay.
frames_after_move() { # <movewindowv2 regex> <matches before> <prefix>
  local d deadline=$(($(date +%s%3N) + 3000)) shots=()
  mkdir -p "$run/frames"
  while (($(grep -cE "$1" "$events" 2>/dev/null) <= $2)); do
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.005
  done
  for d in 000 030 060 090; do
    (sleep "0.$d" && WAYLAND_DISPLAY=$sock grim -t ppm "$run/frames/$3-$d.ppm" 2>>"$log") &
    shots+=($!)
  done
  wait "${shots[@]}"
}
# Frames that differ from both the state before and the state after (> 1 % of the pixels): the
# animation was on screen. Prints "<intermediate> of <total>".
intermediate_frames() { # <prefix> <before.ppm> <after.ppm>
  local f n=0 total=0 a b small
  command -v magick >/dev/null || { echo "NOT VERIFIED (ImageMagick missing)"; return; }
  small=$run/frames/small-$1
  mkdir -p "$small"
  magick "$2" -scale 25% "$small/before.ppm"
  magick "$3" -scale 25% "$small/after.ppm"
  # Share of differing pixels: the normalized value in parentheses (the absolute count may use exponents).
  share() { magick compare -metric AE -fuzz 0.5% "$1" "$2" null: 2>&1 | sed -n 's/.*(\([0-9.e+-]*\)).*/\1/p'; }
  for f in "$run/frames/$1"*.ppm; do
    [[ -f $f ]] || continue
    total=$((total + 1))
    magick "$f" -scale 25% "$small/frame.ppm"
    a=$(share "$small/frame.ppm" "$small/before.ppm")
    b=$(share "$small/frame.ppm" "$small/after.ppm")
    awk -v a="${a:-0}" -v b="${b:-0}" 'BEGIN { exit !(a > 0.01 && b > 0.01) }' && n=$((n + 1))
  done
  echo "$n of $total"
}
contact_sheet() { # <prefix> <out.png>: frames in capture order
  command -v montage >/dev/null || return 0
  local files
  mapfile -t files < <(ls "$run/frames/$1"*.ppm 2>/dev/null | awk -F- '{print $NF" "$0}' | sort -n | cut -d' ' -f2-)
  ((${#files[@]} > 0)) && montage "${files[@]}" -tile 4x -geometry 840x270+4+4 "$2" 2>>"$log"
}

pids=()
socat_pid=""
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
}
trap cleanup EXIT

# Every event line gets the time it was read (microseconds since the epoch) as its first field.
stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!

read -r mon_x mon_y mon_w mon_h < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "minimize: output $out not found" >&2; exit 2; }

# ---- Dock geometry (shell/dock/Dock.qml) ----
token() { sed -n "s/.*readonly property int $1: \([0-9]*\).*/\1/p" "$root/ui/Grassfield/Ui/Tokens.qml" | head -n 1; }
icon=$(token dockIconSize)
spacing=$(token dockSpacing)
padding=$(token dockPadding)
sep_w=$((2 * spacing + $(token dockSeparatorWidth)))
shelf_h=$((icon + 2 * padding + $(token dockIndicatorSize) + spacing))
tile_y=$((mon_h - $(token dockBottomMargin) - shelf_h + padding + icon / 2))
if [[ -n ${MZ_DOCK_APPS:-} ]]; then
  apps=$MZ_DOCK_APPS
else
  config=$dev/config/grassfield.json
  [[ -f $config ]] || config=$root/config/defaults/grassfield.json
  apps=0
  pinned=" "
  while read -r id; do
    for d in "${XDG_DATA_HOME:-$HOME/.local/share}" /usr/local/share /usr/share; do
      if [[ -f $d/applications/$id.desktop ]]; then apps=$((apps + 1)); pinned+="${id,,} "; break; fi
    done
  done < <(jq -r '.dock.pinned[]' "$config")
  # Plus one tile per running app that is not pinned (window class = Wayland app id), e.g. a crash dialog.
  while read -r class; do
    [[ -n $class && $pinned != *" ${class,,} "* ]] && apps=$((apps + 1))
  done < <(query clients | jq -r '[.[] | select(.mapped) | .class] | unique[]')
fi
# Center of minimized tile <index> (0-based) when <count> windows are minimized.
tile_x() { # <index> <count>
  local n=$((apps + $2 + 1)) # icon-sized tiles: apps, minimized windows, Trash (plus one separator)
  local total=$((n * icon + sep_w + n * spacing))
  echo $(((mon_w - total) / 2 + apps * (icon + spacing) + sep_w + spacing + $1 * (icon + spacing) + icon / 2))
}

# ---- Window helpers ----
open_foot() { # -> PID
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
  echo $!
}
client() { # <pid> -> "<address> <x> <y> <w> <h> <workspace name>" (x/y relative to the output)
  query clients | jq -r --argjson p "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.address) \(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.workspace.name)"'
}
event_count() { # <type> <address without 0x>
  local n
  n=$(grep -c "grassfield>>{\"v\":\"gfc/1\",\"type\":\"$1\",\"address\":\"$2\"}" "$events" 2>/dev/null)
  echo "${n:-0}"
}
wait_event() { # <type> <address> <count before> [timeout ms] -> 0 when the count grew
  local deadline=$(($(date +%s%3N) + ${4:-3000}))
  while (($(date +%s%3N) < deadline)); do
    (($(event_count "$1" "$2") > $3)) && return 0
    sleep 0.02
  done
  return 1
}

# Time from the plugin's move of A to its end-of-animation event: ~300 ms when animated, ~0 when the
# rectangle the shell sent was rejected (no Dock, or a tile outside the current monitor layout).
animation_ms() { # <movewindowv2 regex> <event type>
  local t0 t1 ms
  t0=$(grep -E "$1" "$events" | tail -n 1 | cut -d' ' -f1)
  t1=$(grep "grassfield>>{\"v\":\"gfc/1\",\"type\":\"$2\",\"address\":\"$hex\"}" "$events" | tail -n 1 | cut -d' ' -f1)
  if [[ -z $t0 || -z $t1 ]]; then
    echo "unknown"
    return
  fi
  ms=$(((t1 - t0) / 1000))
  if ((ms >= 250)); then echo "$ms ms, animated"; else echo "$ms ms, NOT animated (Dock rectangle rejected?)"; fi
}

fail=0
check() { # <label> <0 = ok> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

say "minimize: nested pid $hypr_pid, output $out ${mon_w}x${mon_h}, Dock: $apps app tiles, icon $icon, tile row y=$tile_y; repeats $repeats"
pointer abs $((mon_w / 2)) $((mon_h / 3)) sleep 50 # windows open on the output under the pointer
a_pid=$(open_foot)
pids+=("$a_pid")
sleep 1.5
read -r addr x0 y0 w0 h0 ws0 < <(client "$a_pid")
[[ -n ${addr:-} ]] || { say "minimize: setup error: window A not found"; exit 2; }
hex=${addr#0x}
min_x=$((x0 + 38)) # minimize button center: 38 px right of the surface's left edge, bar middle 14 px above it
bar_y=$((y0 - 14))
say "  setup: A $addr ${w0}x${h0} at ($x0,$y0) on workspace $ws0"

# 1 minimize with the titlebar button
say "1 minimize with the titlebar button"
shot before-minimize
pointer abs "$min_x" "$bar_y" sleep 300 # hover first: the button's look must not count as an animation frame
WAYLAND_DISPLAY=$sock grim -t ppm "$run/before-all.ppm" 2>>"$log"
n=$(event_count minimized "$hex")
to_minimized="^[0-9]+ movewindowv2>>$hex,-?[0-9]+,special:minimized\$"
moves=$(grep -cE "$to_minimized" "$events")
pointer abs "$min_x" "$bar_y" sleep 40 click
frames_after_move "$to_minimized" "$moves" min &
bpid=$!
wait_event minimized "$hex" "$n" 3000
check "minimized event" $? "count $(event_count minimized "$hex")"
wait "$bpid"
read -r _ x y w h ws < <(client "$a_pid")
[[ $ws == special:minimized ]]
check "A hidden on special:minimized" $? "workspace $ws"
sleep 0.3
shot after-minimize
WAYLAND_DISPLAY=$sock grim -t ppm "$run/after-all.ppm" 2>>"$log"
tx=$(tile_x 0 1)
# The Dock tile: the Trash moved exactly one slot to the right of where it was (same image at the new
# slot), and the slot left of it, where the tile is computed, now holds something else than the Trash.
if command -v magick >/dev/null; then
  crop() { echo "${icon}x${icon}+$(($1 - icon / 2))+$((tile_y - icon / 2))"; }
  ae() { magick compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 | cut -d' ' -f1 | cut -d. -f1; }
  trash_moved=$(ae "$run/before-minimize.png[$(crop "$(tile_x 0 0)")]" "$run/after-minimize.png[$(crop "$(tile_x 1 1)")]")
  tile_vs_trash=$(ae "$run/after-minimize.png[$(crop "$tx")]" "$run/after-minimize.png[$(crop "$(tile_x 1 1)")]")
  [[ $trash_moved =~ ^[0-9]+$ && $tile_vs_trash =~ ^[0-9]+$ ]] && ((trash_moved < icon * icon / 20 && tile_vs_trash > icon * icon / 10))
  check "Dock tile appeared at ($tx,$tile_y)" $? "Trash one slot right: $trash_moved px differ; tile vs Trash: $tile_vs_trash of $((icon * icon)) px differ"
else
  say "  Dock tile appeared: NOT VERIFIED (ImageMagick missing)"
fi
say "  minimize animation: $(animation_ms "$to_minimized" minimized) (move to special:minimized -> minimized event)"
contact_sheet min "$run/minimize-frames.png"
say "  minimize animation on screen: $(intermediate_frames min "$run/before-all.ppm" "$run/after-all.ppm") frames (sheet: $run/minimize-frames.png)"

# 2 restore with a click on the Dock tile
say "2 restore with a click on the Dock tile"
n=$(event_count restored "$hex")
pointer abs "$tx" "$tile_y" sleep 300 # hover first (Dock magnification settles)
WAYLAND_DISPLAY=$sock grim -t ppm "$run/before-restore-all.ppm" 2>>"$log"
to_workspace="^[0-9]+ movewindowv2>>$hex,[0-9]+,$ws0\$"
moves=$(grep -cE "$to_workspace" "$events")
pointer abs "$tx" "$tile_y" sleep 40 click
frames_after_move "$to_workspace" "$moves" restore &
bpid=$!
wait_event restored "$hex" "$n" 3000
check "restored event" $? "count $(event_count restored "$hex")"
wait "$bpid"
sleep 0.3
read -r _ x y w h ws < <(client "$a_pid")
[[ $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "A back at its geometry" $? "now ${w}x${h} at ($x,$y) on $ws; expected ${w0}x${h0} at ($x0,$y0) on $ws0"
active=$(query activewindow | jq -r '.address')
[[ $active == "$addr" ]]
check "A focused" $? "active window $active"
WAYLAND_DISPLAY=$sock grim -t ppm "$run/after-restore-all.ppm" 2>>"$log"
say "  restore animation: $(animation_ms "$to_workspace" restored) (move back -> restored event)"
contact_sheet restore "$run/restore-frames.png"
say "  restore animation on screen: $(intermediate_frames restore "$run/before-restore-all.ppm" "$run/after-restore-all.ppm") frames (sheet: $run/restore-frames.png)"

# 3 rapid repetition
say "3 minimize + restore x$repeats"
bad=0
for ((i = 1; i <= repeats; i++)); do
  nm=$(event_count minimized "$hex")
  nr=$(event_count restored "$hex")
  pointer abs "$min_x" "$bar_y" sleep 30 click
  if ((i % 4 == 0)); then
    sleep 0.12 # mid-animation: the restore interrupts the minimize animation
  else
    wait_event minimized "$hex" "$nm" 3000 || { say "  round $i: no minimized event"; bad=$((bad + 1)); }
  fi
  pointer abs "$tx" "$tile_y" sleep 30 click
  if ! wait_event restored "$hex" "$nr" 3000; then
    say "  round $i: no restored event"
    bad=$((bad + 1))
  fi
  sleep 0.15
done
sleep 0.5
read -r _ x y w h ws < <(client "$a_pid")
[[ $bad == 0 && $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "rapid repetition" $? "$bad missing events; A ${w}x${h} at ($x,$y) on $ws"
kill -0 "$hypr_pid" 2>/dev/null
check "Hyprland alive after the repetition" $? "pid $hypr_pid"

# 4 windows closed mid-animation
say "4 close during the minimize and the restore animations"
b_pid=$(open_foot)
sleep 1.5
read -r b_addr bx by _ _ _ < <(client "$b_pid")
if [[ -n ${b_addr:-} ]]; then
  pointer abs $((bx + 38)) $((by - 14)) sleep 30 click
  sleep 0.1
  kill "$b_pid" 2>/dev/null
  shot closed-during-minimize
  sleep 0.8
  [[ -z $(client "$b_pid") ]] && kill -0 "$hypr_pid" 2>/dev/null
  check "B closed mid-minimize" $? "B gone, Hyprland alive"
else
  check "B closed mid-minimize" 1 "window B not found"
fi
c_pid=$(open_foot)
pids+=("$c_pid")
sleep 1.5
read -r c_addr cx cy _ _ _ < <(client "$c_pid")
if [[ -n ${c_addr:-} ]]; then
  n=$(event_count minimized "${c_addr#0x}")
  pointer abs $((cx + 38)) $((cy - 14)) sleep 30 click
  wait_event minimized "${c_addr#0x}" "$n" 3000
  sleep 0.3
  pointer abs "$(tile_x 0 1)" "$tile_y" sleep 30 click
  sleep 0.1
  kill "$c_pid" 2>/dev/null
  shot closed-during-restore
  sleep 0.8
  [[ -z $(client "$c_pid") ]] && kill -0 "$hypr_pid" 2>/dev/null
  check "C closed mid-restore" $? "C gone, Hyprland alive"
else
  check "C closed mid-restore" 1 "window C not found"
fi
read -r _ x y w h ws < <(client "$a_pid")
[[ $ws == "$ws0" ]]
check "A unaffected" $? "A on $ws at ($x,$y)"

# 5 health
say "5 health"
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $? "pid $hypr_pid"
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
[[ ${dumps:-0} == 0 ]]
check "no core dump of the nested Hyprland" $? "${dumps:-0} dump(s) for pid $hypr_pid since $start_human"
if [[ -r $hyprlog ]]; then
  exceptions=$(grep -ac '\[grassfield\].*exception' "$hyprlog")
  [[ $exceptions == 0 ]]
  check "no grassfield exception in the nested log" $? "$exceptions (Hyprland buffers its log: recent lines may be missing)"
fi
say "  events: $(grep -c 'type":"minimized' "$events") minimized, $(grep -c 'type":"restored' "$events") restored, $(grep -c 'type":"minimize-request' "$events") minimize-request"

if ((fail == 0)); then say "minimize: PASS"; else say "minimize: FAIL"; fi
say "minimize: log $log"
exit "$fail"
