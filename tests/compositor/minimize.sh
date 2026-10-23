#!/usr/bin/env bash
# Minimize / restore scenario (master-prompt §5.6 feature 2): real pointer on the titlebar's minimize button,
# restore through a click on the window's Dock tile, rapid repetition, windows closed mid-animation.
#
# Usage: tests/compositor/minimize.sh [repeats] [stages]  (default 20; `stages`: the same run with Stages on)
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
#   2 restore A with a click on its Dock tile: `restored` event, A back on its display, on the Desktop that display shows,
#     at its geometry, focused (owner decision D-1, the macOS model: never on the display of the Dock that was clicked);
#   2b two displays (D-1, audit GF-001): the Dock moved to another output (the pointer rests on its bottom edge), A
#     minimized, A's display switched to another Desktop, a click on A's tile on the other output: A comes back on its
#     own display, on the Desktop it shows now, at its geometry, focused; then A, its Desktop and the Dock go back;
#   3 repeat minimize + restore <repeats> times quickly; every 4th round the Dock tile is clicked while the
#     minimize animation is still running; A must end at its geometry;
#   4 a window closed during its minimize animation, another one closed during its restore animation;
#   5 nested Hyprland alive, no core dump of its PID, no grassfield exception in its log.
# With `stages` (R13 review of 46b3e9b): the Stages flag on, the strip stand-in tests/compositor/stages-fixture mapped
# on MZ_OUTPUT and op "on" sent (verbs through scripts/nestctl); a second foot window O (same app as A, so the Dock layout
# is unchanged) opens first and is moved into a strip stage of its own, so that A is the only window of the active stage.
# Step 1 then also checks the keyboard after the minimize: O's stage comes forward and O gets the typed keys (keys through
# scripts/dev/keys.sh), A gets nothing. Stages is turned off and the fixture ended at the end of the run.
# The Dock tile is the one the shell itself computed: the shell sends its rectangle with every minimize
# (hl.plugin.grassfield.minimize(address, x, y, w, h)) and the plugin logs it ("minimize <hex>: toward the Dock
# rectangle x,y wxh"); the test follows Hyprland's log (`scripts/nestctl rollinglog -f`, read-only) and clicks the
# centre of that rectangle. Nothing about the Dock layout (pinned apps, recents, separators, sizes) is computed
# here, so Dock changes cannot make the click miss; without that line the test fails and clicks nothing.
# The animation itself is reported (not asserted): time from the plugin's move of the window to its
# minimized/restored event (~300 ms when animated; ~0 when the rectangle the shell sent was rejected, e.g. the
# Dock of Quickshell.screens[0] laid out for an output size that changed since), plus captures requested
# 0-90 ms after the animation started and the number of them that differ from both the start and the end state.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Log: .dev/minimize/run-<timestamp>/run.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
repeats=20
stages_mode=0
for arg in "$@"; do
  case $arg in
    stages) stages_mode=1 ;;
    *) [[ $arg =~ ^[0-9]+$ ]] || { echo "usage: minimize.sh [repeats] [stages]" >&2; exit 2; }; repeats=$arg ;;
  esac
done
out=${MZ_OUTPUT:-GF-REF}

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
if ((stages_mode)); then
  query grassfield | jq -e '.features | index("stages-available")' >/dev/null 2>&1 \
    || { echo "minimize: the loaded plugin does not advertise \"stages-available\"" >&2; exit 2; }
  command -v qs >/dev/null || { echo "minimize: qs is needed for the Stages strip stand-in" >&2; exit 2; }
fi
# The shell must have finished the gfc/1 handshake, otherwise its first minimize takes the fallback path
# (special workspace) and no "minimized" event is posted.
for _ in $(seq 1 50); do
  grep -q "grassfield: compositor plugin present" "$dev/shell.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "grassfield: compositor plugin present" "$dev/shell.log" 2>/dev/null \
  || { echo "minimize: the shell has not seen the plugin's capabilities (see .dev/shell.log)" >&2; exit 2; }

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
fixture_pid=""
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; } # nested only: verbs of the plugin (Stages mode), dispatches of step 2b
cleanup() {
  if ((stages_mode)); then
    nestctl dispatch 'hl.plugin.grassfield.stages([[{"op":"off","durationMs":0}]])' >/dev/null 2>&1
    nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
    [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  fi
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
}
trap cleanup EXIT

# Anchor devices for the whole run: a virtual pointer and a virtual keyboard that only wait. The seat then keeps both
# capabilities while pointer.sh and keys.sh add and remove their own devices, so clients keep their wl_pointer and
# wl_keyboard (otherwise each new device makes them bind again; on a loaded host a click then lands at the stale enter
# position (-1,-1), e.g. beside the Dock tile, and the first typed key is lost). A real session keeps its devices too.
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 &
pids+=($!)
"$root/scripts/dev/keys.sh" -s 3600000 >>"$log" 2>&1 &
pids+=($!)
# Hyprland's log as it is written (read-only hyprctl request; the log file itself is written late): the plugin's line
# with the Dock rectangle the shell sent for each minimize.
follow=$run/hyprland-follow.log
# Line-buffered (stdbuf): hyprctl's stdout into a file is block-buffered and a line could reach it seconds late.
timeout 3600 stdbuf -oL "$root/scripts/nestctl" rollinglog -f >"$follow" 2>&1 &
pids+=($!)
sleep 0.3

# Every event line gets the time it was read (microseconds since the epoch) as its first field.
stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!

read -r mon_x mon_y mon_w mon_h < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "minimize: output $out not found" >&2; exit 2; }

# ---- Stages mode: the flag, the strip stand-in, op on, and window O (opened first, moved into a strip stage later) ----
st_last() { grep -a 'grassfield>>{"v":"gfc/1","type":"stages"' "$events" | tail -n 1 | sed 's/^[0-9]* grassfield>>//'; }
o_pid="" o_addr="" cap_o=""
if ((stages_mode)); then
  strip_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '{x: $x, y: ($y + 60), w: 220, h: 860}')
  tiles_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '[range(0; 4) as $i | {x: ($x + 16), y: ($y + 100 + $i * 190), w: 188, h: 160}]')
  fixlog=$run/stages-fixture.log
  GF_STAGES_OUTPUT=$out GF_STAGES_STRIP=$strip_json GF_STAGES_TILES=$tiles_json WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    setsid "$root/scripts/dev/isolated.sh" --name stages-fixture qs -p "$root/tests/compositor/stages-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  for _ in $(seq 1 50); do grep -q "\[stages-fixture\] output $out found" "$fixlog" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
  grep -q "\[stages-fixture\] output $out found" "$fixlog" || { echo "minimize: the Stages strip stand-in did not start ($fixlog)" >&2; exit 2; }
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "true")' >/dev/null 2>&1
  nestctl dispatch "hl.plugin.grassfield.stages([[$(jq -nc --arg o "$out" --argjson t "$tiles_json" '{op: "on", durationMs: 0, strips: [{monitor: $o, tiles: $t}]}')]])" >/dev/null 2>&1
  sleep 0.5
  [[ $(st_last | jq -r '.on') == true ]] || { echo "minimize: Stages did not turn on: $(st_last)" >&2; exit 2; }
  # O: a foot that writes every typed byte to cap_o (raw tty), opened where A will open (both centred under the pointer).
  cap_o=$run/capture-o.cap
  : >"$cap_o"
  pointer abs $((mon_w / 2)) $((mon_h / 3)) sleep 50
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$cap_o" >/dev/null 2>&1 </dev/null &
  o_pid=$!
  pids+=("$o_pid")
  sleep 1.5
  o_addr=$(query clients | jq -r --argjson p "$o_pid" '[.[] | select(.pid == $p)][0].address // ""')
  [[ -n $o_addr ]] || { echo "minimize: setup error: window O not found" >&2; exit 2; }
fi

# ---- Dock tile: the rectangle the shell sent with the minimize (logged by the plugin) ----
# Centre of the Dock tile the shell computed for window <hex> at its latest minimize, as "<output> <x> <y>" (x, y relative
# to that output); only lines after line <since> of the follow log count (a closed window's address can be reused); waits
# up to 3 s for the plugin's line; nothing when it never came (the caller then clicks nothing).
follow_lines() { grep -ac "" "$follow" 2>/dev/null || echo 0; }
dock_tile() { # <hex address, no 0x> <since>
  local line rect deadline=$(($(date +%s%3N) + 3000))
  while :; do
    line=$(tail -n +"$(($2 + 1))" "$follow" 2>/dev/null | grep -a "\[grassfield\] minimize $1: toward the Dock rectangle " | tail -n 1)
    [[ -n $line ]] && break
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
  rect=$(sed -n 's/.*toward the Dock rectangle \(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p' <<<"$line")
  [[ -n $rect ]] || return 1
  read -r rx ry rw rh <<<"$rect"
  query monitors | jq -r --argjson x $((rx + rw / 2)) --argjson y $((ry + rh / 2)) \
    '[.[] | select($x >= .x and $x < .x + .width and $y >= .y and $y < .y + .height) | "\(.name) \($x - .x) \($y - .y)"][0] // empty'
}
# Pitch of the Dock's tiles (its layout tokens, ui/Grassfield/Ui/Tokens.qml): the Trash sits one pitch right of the
# minimized tile, and the minimize inserts one tile (the centred Dock grows by one pitch, the Trash moves half a pitch).
token() { sed -n "s/.*readonly property int $1: \([0-9]*\).*/\1/p" "$root/ui/Grassfield/Ui/Tokens.qml" | head -n 1; }
icon=$(token dockIconSize)
pitch=$((icon + $(token dockSpacing)))

# ---- Window helpers ----
open_foot() { # -> PID
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
  echo $!
}
client() { # <pid> -> "<address> <x> <y> <w> <h> <workspace name>" (x/y relative to the output)
  query clients | jq -r --argjson p "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.address) \(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.workspace.name)"'
}
client_monitor() { # <pid> -> the name of the display the window is on
  local id
  id=$(query clients | jq -r --argjson p "$1" '[.[] | select(.pid == $p)][0].monitor // empty')
  [[ -n $id ]] && query monitors | jq -r --argjson id "$id" '.[] | select(.id == $id) | .name'
}
shown_ws() { query monitors | jq -r --arg n "$1" '.[] | select(.name == $n) | .activeWorkspace.name'; } # <display> -> its Desktop
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

say "minimize: nested pid $hypr_pid, output $out ${mon_w}x${mon_h}, Dock tiles from the shell's rectangles (icon $icon, pitch $pitch); repeats $repeats"
pointer abs $((mon_w / 2)) $((mon_h / 3)) sleep 50 # windows open on the output under the pointer
a_pid=$(open_foot)
pids+=("$a_pid")
sleep 1.5
read -r addr x0 y0 w0 h0 ws0 < <(client "$a_pid")
[[ -n ${addr:-} ]] || { say "minimize: setup error: window A not found"; exit 2; }
hex=${addr#0x}
min_x=$((x0 + GF_TB_MIN_X)) # minimize button center, right of the surface's left edge; bar middle above the surface
bar_y=$((y0 - GF_TB_MID))
mon0=$(client_monitor "$a_pid")
say "  setup: A $addr ${w0}x${h0} at ($x0,$y0) on workspace $ws0 of ${mon0:-?}"
[[ $mon0 == "$out" ]] || { say "minimize: setup error: A opened on ${mon0:-?}, not on $out"; exit 2; }
if ((stages_mode)); then
  # A joined O's stage (same app): O moves into a strip stage of its own, A stays alone in the active stage.
  nestctl dispatch "hl.plugin.grassfield.stages([[{\"op\":\"move\",\"address\":\"$o_addr\",\"stage\":\"new\"}]])" >/dev/null 2>&1
  sleep 0.5
  a_alone=$(st_last | jq -r --arg a "$hex" '.monitors[0] as $m | [$m.stages[] | select(.id == $m.active)][0].windows | map(.address) == [$a]')
  o_strip=$(st_last | jq -r --arg o "${o_addr#0x}" '[.monitors[0].stages[] | select(.slot >= 0) | .windows[].address] | index($o) != null')
  say "  stages: on; O $o_addr in a strip stage: $o_strip; A alone in the active stage: $a_alone"
  [[ $a_alone == true && $o_strip == true ]] || { say "minimize: setup error: Stages did not group A and O as expected: $(st_last)"; exit 2; }
  nestctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1
  sleep 0.3
fi

# 1 minimize with the titlebar button
say "1 minimize with the titlebar button"
shot before-minimize
pointer abs "$min_x" "$bar_y" sleep 300 # hover first: the button's look must not count as an animation frame
WAYLAND_DISPLAY=$sock grim -t ppm "$run/before-all.ppm" 2>>"$log"
n=$(event_count minimized "$hex")
to_minimized="^[0-9]+ movewindowv2>>$hex,-?[0-9]+,special:minimized\$"
moves=$(grep -cE "$to_minimized" "$events")
f0=$(follow_lines)
pointer abs "$min_x" "$bar_y" sleep 40 click
frames_after_move "$to_minimized" "$moves" min &
bpid=$!
wait_event minimized "$hex" "$n" 3000
check "minimized event" $? "count $(event_count minimized "$hex")"
wait "$bpid"
read -r _ x y w h ws < <(client "$a_pid")
[[ $ws == special:minimized ]]
check "A hidden on special:minimized" $? "workspace $ws"
if ((stages_mode)); then
  # A was the only window of the active stage: O's stage comes forward and O takes the keyboard (never A).
  sleep 0.3
  aw=$(query activewindow | jq -r '.address // ""')
  o0=$(stat -c %s "$cap_o")
  timeout 10 "$root/scripts/dev/keys.sh" mz >>"$log" 2>&1
  sleep 0.4
  o_new=$(tail -c +"$((o0 + 1))" "$cap_o" | head -c 40)
  o_active=$(st_last | jq -r --arg o "${o_addr#0x}" '.monitors[0] as $m | [$m.stages[] | select(.id == $m.active)][0].windows | map(.address) | index($o) != null')
  [[ $aw == "$o_addr" && $o_new == *mz* && $o_active == true ]]
  check "Stages: keyboard after minimizing the only window of the active stage" $? "active window $aw (O $o_addr), O got '$o_new', O's stage active: $o_active"
fi
sleep 0.3
shot after-minimize
WAYLAND_DISPLAY=$sock grim -t ppm "$run/after-all.ppm" 2>>"$log"
read -r dock_out tx tile_y <<<"$(dock_tile "$hex" "$f0")"
[[ -n ${tile_y:-} ]]
check "the shell's Dock rectangle for A (plugin log line)" $? "tile centre ${tx:-?},${tile_y:-?} on ${dock_out:-?} (follow log $follow)"
[[ -n ${tile_y:-} ]] || { say "minimize: no Dock rectangle for A: no tile is clicked"; say "minimize: FAIL"; exit 1; }
dock_pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$dock_out" "$@" >>"$log" 2>&1; }
# The Dock tile: the Trash moved half a pitch to the right (the centred Dock grew by one tile; same image at the new
# slot), and the tile the shell named, left of it, holds something else than the Trash.
if command -v magick >/dev/null && [[ $dock_out == "$out" ]]; then
  crop() { echo "${icon}x${icon}+$(($1 - icon / 2))+$((tile_y - icon / 2))"; }
  ae() { magick compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 | cut -d' ' -f1 | cut -d. -f1; }
  trash_moved=$(ae "$run/before-minimize.png[$(crop $((tx + pitch / 2)))]" "$run/after-minimize.png[$(crop $((tx + pitch)))]")
  tile_vs_trash=$(ae "$run/after-minimize.png[$(crop "$tx")]" "$run/after-minimize.png[$(crop $((tx + pitch)))]")
  [[ $trash_moved =~ ^[0-9]+$ && $tile_vs_trash =~ ^[0-9]+$ ]] && ((trash_moved < icon * icon / 20 && tile_vs_trash > icon * icon / 10))
  check "Dock tile appeared at ($tx,$tile_y)" $? "Trash half a pitch right: $trash_moved px differ; tile vs Trash: $tile_vs_trash of $((icon * icon)) px differ"
elif ! command -v magick >/dev/null; then
  say "  Dock tile appeared: NOT VERIFIED (ImageMagick 7, the magick command, is not installed)"
else
  say "  Dock tile appeared: NOT VERIFIED (the Dock is on $dock_out; the captures before and after cover $out only)"
fi
say "  minimize animation: $(animation_ms "$to_minimized" minimized) (move to special:minimized -> minimized event)"
contact_sheet min "$run/minimize-frames.png"
say "  minimize animation on screen: $(intermediate_frames min "$run/before-all.ppm" "$run/after-all.ppm") frames (sheet: $run/minimize-frames.png)"

# 2 restore with a click on the Dock tile
say "2 restore with a click on the Dock tile"
n=$(event_count restored "$hex")
dock_pointer abs "$tx" "$tile_y" sleep 300 # hover first (Dock magnification settles)
WAYLAND_DISPLAY=$sock grim -t ppm "$run/before-restore-all.ppm" 2>>"$log"
# D-1: A's own display and the Desktop it shows now (here the Desktop A was on), whichever display has the Dock.
expect_ws=$(shown_ws "$mon0")
to_workspace="^[0-9]+ movewindowv2>>$hex,[0-9]+,${expect_ws:-$ws0}\$"
moves=$(grep -cE "$to_workspace" "$events")
dock_pointer abs "$tx" "$tile_y" sleep 40 click
frames_after_move "$to_workspace" "$moves" restore &
bpid=$!
wait_event restored "$hex" "$n" 3000
check "restored event" $? "count $(event_count restored "$hex")"
wait "$bpid"
sleep 0.3
read -r _ x y w h ws < <(client "$a_pid")
mon=$(client_monitor "$a_pid")
[[ $mon == "$mon0" && $ws == "$expect_ws" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
check "A back on its display, its Desktop, at its geometry (D-1; Dock on $dock_out)" $? \
  "now ${w}x${h} at ($x,$y) on $ws of ${mon:-?}; expected ${w0}x${h0} at ($x0,$y0) on $expect_ws of $mon0"
active=$(query activewindow | jq -r '.address')
[[ $active == "$addr" ]]
check "A focused" $? "active window $active"
WAYLAND_DISPLAY=$sock grim -t ppm "$run/after-restore-all.ppm" 2>>"$log"
say "  restore animation: $(animation_ms "$to_workspace" restored) (move back -> restored event)"
contact_sheet restore "$run/restore-frames.png"
say "  restore animation on screen: $(intermediate_frames restore "$run/before-restore-all.ppm" "$run/after-restore-all.ppm") frames (sheet: $run/restore-frames.png)"

# 2b two displays (D-1): the Dock on another output than A's, A's display on another Desktop when the tile is clicked
say "2b two displays: the Dock on the other display, A's display on another Desktop (D-1)"
second=$(query monitors | jq -r --arg o "$out" '[.[] | select(.name != $o and (.disabled | not))][0].name // ""')
# Brings the Dock to <display> (macOS: it moves to the display whose bottom edge the pointer rests on; the dwell is
# Tokens.dockRevealDwell, as in tests/visual/dock-geometry.sh "onedock"), then lifts the pointer off the edge.
dock_to() { # <display>
  local dw dh
  read -r dw dh < <(query monitors | jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.width) \(.height)"')
  [[ -n ${dh:-} ]] || return 1
  timeout 20 "$root/scripts/dev/pointer.sh" output "$1" abs $((dw / 2)) $((dh / 2)) sleep 500 >>"$log" 2>&1
  timeout 20 "$root/scripts/dev/pointer.sh" output "$1" abs $((dw / 2)) $((dh - 1)) sleep 1200 >>"$log" 2>&1
  timeout 20 "$root/scripts/dev/pointer.sh" output "$1" abs $((dw / 2)) $((dh / 2)) sleep 600 >>"$log" 2>&1
}
if [[ -z $second ]]; then
  check "2b: a second display" 1 "only $out is enabled: the D-1 two-display case needs one (the nested session has WAYLAND-1)"
else
  dock_to "$second"
  n=$(event_count minimized "$hex")
  f2=$(follow_lines)
  pointer abs "$min_x" "$bar_y" sleep 300 # back on A's display: its titlebar press focuses that display
  pointer abs "$min_x" "$bar_y" sleep 40 click
  wait_event minimized "$hex" "$n" 5000
  check "2b: minimized event" $? "count $(event_count minimized "$hex")"
  read -r d2_out d2_x d2_y <<<"$(dock_tile "$hex" "$f2")"
  [[ ${d2_out:-} == "$second" ]]
  check "2b: the shell's Dock rectangle for A is on $second" $? "tile centre ${d2_x:-?},${d2_y:-?} on ${d2_out:-?}"
  # Another Desktop on A's display (created there: A's display is the focused one after the press): the first free id.
  used=$(query workspaces | jq -r '[.[].name] | join(" ")')
  alt_ws=""
  for cand in 7 8 9 10 11 12 13 14 15 16; do [[ " $used " == *" $cand "* ]] || { alt_ws=$cand; break; }; done
  nestctl dispatch "hl.dsp.focus({ workspace = \"$alt_ws\" })" >>"$log" 2>&1
  sleep 0.5
  shown_now=$(shown_ws "$mon0")
  [[ -n $alt_ws && $shown_now == "$alt_ws" ]]
  check "2b: $mon0 shows another Desktop" $? "$mon0 shows ${shown_now:-?} (asked: ${alt_ws:-none free})"
  if [[ -n ${d2_y:-} ]]; then
    n=$(event_count restored "$hex")
    timeout 20 "$root/scripts/dev/pointer.sh" output "$d2_out" abs "$d2_x" "$d2_y" sleep 300 >>"$log" 2>&1
    timeout 20 "$root/scripts/dev/pointer.sh" output "$d2_out" abs "$d2_x" "$d2_y" sleep 40 click >>"$log" 2>&1
    wait_event restored "$hex" "$n" 5000
    check "2b: restored event" $? "count $(event_count restored "$hex")"
    sleep 0.3
    read -r _ x y w h ws < <(client "$a_pid")
    mon=$(client_monitor "$a_pid")
    [[ $mon == "$mon0" && $ws == "$shown_now" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
    check "2b: A back on its display, on the Desktop it shows, at its geometry (Dock on $d2_out)" $? \
      "now ${w}x${h} at ($x,$y) on $ws of ${mon:-?}; expected ${w0}x${h0} at ($x0,$y0) on $shown_now of $mon0"
    active=$(query activewindow | jq -r '.address')
    [[ $active == "$addr" ]]
    check "2b: A focused" $? "active window $active"
  else
    check "2b: restore from the other display" 1 "no Dock rectangle for A: no tile is clicked"
  fi
  # Back to the state of step 1 for the next steps: A on its Desktop, that Desktop shown, the Dock where it was.
  nestctl dispatch "hl.dsp.window.move({ workspace = \"$ws0\", follow = false, window = \"address:$addr\" })" >>"$log" 2>&1
  nestctl dispatch "hl.dsp.focus({ workspace = \"$ws0\" })" >>"$log" 2>&1
  sleep 0.4
  [[ $dock_out != "$second" ]] && dock_to "$dock_out"
  nestctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >>"$log" 2>&1
  sleep 0.4
  read -r _ x y w h ws < <(client "$a_pid")
  say "  2b: back for step 3: A ${w}x${h} at ($x,$y) on $ws of $(client_monitor "$a_pid"); the Dock on $dock_out"
fi

# 3 rapid repetition
say "3 minimize + restore x$repeats"
# How long one round waits for each event. The shell answers the plugin's minimize-request before anything moves, and on
# a loaded host that answer alone has taken seconds; the rounds test that every minimize and restore completes, not its
# latency (frame timing is measured in step 1). MZ_ROUND_MS overrides it.
round_ms=${MZ_ROUND_MS:-10000}
bad=0
for ((i = 1; i <= repeats; i++)); do
  nm=$(event_count minimized "$hex")
  nr=$(event_count restored "$hex")
  moves=$(grep -cE "$to_minimized" "$events")
  pointer abs "$min_x" "$bar_y" sleep 30 click
  if ((i % 4 == 0)); then
    # Mid-animation: the restore interrupts the minimize. The tile exists, and the animation starts, only once the
    # shell has answered the plugin's minimize-request (1.85 s measured on a loaded host): wait for A's move to
    # special:minimized on the event socket (unbuffered, unlike Hyprland's log), then click 0.12 s into the animation.
    deadline=$(($(date +%s%3N) + round_ms))
    while (($(grep -cE "$to_minimized" "$events") <= moves)) && (($(date +%s%3N) < deadline)); do sleep 0.02; done
    (($(grep -cE "$to_minimized" "$events") > moves)) || { say "  round $i: A never moved to special:minimized"; bad=$((bad + 1)); }
    sleep 0.12
  else
    wait_event minimized "$hex" "$nm" "$round_ms" || { say "  round $i: no minimized event"; bad=$((bad + 1)); }
  fi
  dock_pointer abs "$tx" "$tile_y" sleep 30 click
  if ! wait_event restored "$hex" "$nr" "$round_ms"; then
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
  pointer abs $((bx + GF_TB_MIN_X)) $((by - GF_TB_MID)) sleep 30 click
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
  f0=$(follow_lines)
  pointer abs $((cx + GF_TB_MIN_X)) $((cy - GF_TB_MID)) sleep 30 click
  wait_event minimized "${c_addr#0x}" "$n" 3000
  sleep 0.3
  # C's own rectangle; after the rapid repetition the plugin's request log budget (FR24: 20 lines, then one per second)
  # may have held its line back: C then has the tile A had in step 1 (the only minimized window, the same Dock).
  read -r c_out c_tx c_ty <<<"$(dock_tile "${c_addr#0x}" "$f0")"
  [[ -n ${c_ty:-} ]] || { c_out=$dock_out c_tx=$tx c_ty=$tile_y; say "  C: no Dock rectangle line (log budget): A's tile of step 1 is used"; }
  timeout 20 "$root/scripts/dev/pointer.sh" output "$c_out" abs "$c_tx" "$c_ty" sleep 30 click >>"$log" 2>&1
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
