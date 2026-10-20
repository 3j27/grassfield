#!/usr/bin/env bash
# Minimize effects scenario (Track B3, defect #6): Settings dock.minimizeEffect = genie | scale, Reduce Motion, and a
# plugin unload / reload in the middle of an animation.
#
# Usage: tests/compositor/genie.sh            the whole scenario (steps 1-6)
#        tests/compositor/genie.sh timing N   only N minimize + restore pairs per effect (genie, scale, fade) at normal
#                                             speed, no capture: the plugin's frame timing lines, then health
#        tests/compositor/genie.sh c2 [X Y]   gate C2, in a session started with nested-up.sh --no-plugin: SUPER+M parks
#                                             the window (shell fallback); with X Y (the Dock tile on the output) a click
#                                             there restores it
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded (features "minimize" and
# "minimize-effect") and grassfield-shell running. Settings change through the dev settings file
# (.dev/config/grassfield.json, the nested shell's GRASSFIELD_CONFIG_HOME; restored at exit), which the shell pushes to
# the plugin (hl.plugin.grassfield.config("minimizeEffect", genie|scale|fade)). Pointer input through
# scripts/dev/pointer.sh; hyprctl read-only through scripts/nestctl's instance, except the plugin unload / load of step 5,
# which goes through `just plugin-unload` / `just plugin-load` (scripts/nestctl, nested only).
#   1 genie: minimize foot window A with its minimize button, Shift held (slow motion, see SLOW_DELAYS); captures of the
#     output during the animation, each classified by tests/compositor/genie_shape.py against the output after the
#     minimize: at least one capture must show the genie (top of the footprint >= 1.6 x wider than its bottom);
#   2 genie restore: Shift-click on A's Dock tile; captures; at least one genie-shaped; A back at its geometry; then
#     5 minimize + restore pairs at normal speed without captures (the plugin logs their frame timing);
#   3 scale: the same with dock.minimizeEffect = scale: no genie-shaped capture, at least one rectangle;
#   4 Reduce Motion (accessibility.reduceMotion = true): minimize and restore fade in place (every footprint is a
#     rectangle at A's own box, no genie), move -> event <= 250 ms at normal speed;
#   5 unload mid-minimize, load, restore through the Dock, unload mid-restore, load: Hyprland alive, A minimized after
#     the first unload, A fully shown at its place after the second one, the plugin advertises its features again;
#   6 health: Hyprland alive, no core dump, no grassfield exception; the plugin's timing lines (frame interval and CPU
#     time per frame during each animation) are copied into the log.
# Captures: .dev/genie/run-<timestamp>/frames/*.png (and contact sheets). Exit: 0 PASS, 1 FAIL, 2 usage or environment.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${GENIE_OUTPUT:-GF-REF}
timing_only=0
c2=0
pairs=5
usage="usage: genie.sh [timing N | c2 [TILE_X TILE_Y]]"
case "${1:-}" in
  "") ;;
  timing) [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { echo "$usage" >&2; exit 2; }; timing_only=1 pairs=$2 ;;
  c2)
    c2=1
    c2_tile_x=${2:-} c2_tile_y=${3:-}
    [[ -z $c2_tile_x || ($c2_tile_x =~ ^[0-9]+$ && $c2_tile_y =~ ^[0-9]+$) ]] || { echo "$usage" >&2; exit 2; }
    ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "genie: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "genie: grassfield-shell is not running (scripts/dev/shell-run.sh)" >&2; exit 2; }
for tool in socat jq magick montage python3 grim gawk; do
  command -v "$tool" >/dev/null || { echo "genie: $tool is needed" >&2; exit 2; }
done

query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only queries only
features() { query grassfield | jq -r '.features | join(",")' 2>/dev/null; }
if ((c2)); then
  [[ -z $(features) ]] || { echo "genie c2: the plugin is loaded (start the session with scripts/dev/nested-up.sh --no-plugin)" >&2; exit 2; }
  grep -q "running in degraded mode" "$dev/shell.log" 2>/dev/null || { echo "genie c2: the shell is not in degraded mode yet" >&2; exit 2; }
else
  [[ ,$(features), == *,minimize-effect,* ]] || { echo "genie: the loaded plugin does not advertise \"minimize-effect\"" >&2; exit 2; }
  grep -q "grassfield: compositor setting minimizeEffect" "$dev/shell.log" 2>/dev/null \
    || { echo "genie: the shell has not pushed minimizeEffect yet (see .dev/shell.log)" >&2; exit 2; }
fi

run=$dev/genie/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run/frames"
log=$run/run.log
events=$run/events.log
follow=$run/hyprland-follow.log
start_human=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }

# ---- settings (restored at exit) ----
settings=$dev/config/grassfield.json
backup=$run/settings.backup
had_settings=0
[[ -f $settings ]] && { cp "$settings" "$backup"; had_settings=1; }
set_settings() { # <effect> <reduceMotion true|false>: rewrite the dev settings file, wait for the shell's push
  mkdir -p "$dev/config"
  local base=$root/config/defaults/grassfield.json want=$1 n
  ((had_settings)) && base=$backup
  [[ $2 == true ]] && want=fade
  n=$(grep -c "compositor setting minimizeEffect = $want" "$dev/shell.log")
  jq --arg e "$1" --argjson r "$2" '.dock.minimizeEffect = $e | .accessibility.reduceMotion = $r' "$base" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  for _ in $(seq 1 30); do
    (($(grep -c "compositor setting minimizeEffect = $want" "$dev/shell.log") > n)) && break
    sleep 0.1
  done
  # The push already matched (no change: nothing logged) or arrived; give Hyprland the dispatch.
  sleep 0.5
}

pids=()
socat_pid=""
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  if ((had_settings)); then cp "$backup" "$settings"; else rm -f "$settings"; fi
}
trap cleanup EXIT

# Anchor devices (see minimize.sh): clients keep their wl_pointer while pointer.sh adds and removes its own.
"$root/scripts/dev/pointer.sh" output "$out" sleep 3600000 >>"$log" 2>&1 &
pids+=($!)
timeout 3600 stdbuf -oL "$root/scripts/nestctl" rollinglog -f >"$follow" 2>&1 &
pids+=($!)
stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!
sleep 0.3

read -r mon_x mon_y mon_w mon_h < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "genie: output $out not found" >&2; exit 2; }

fail=0
check() { if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi; }

client() { # <pid> -> "<address> <x> <y> <w> <h> <workspace name>" (x/y relative to the output)
  query clients | jq -r --argjson p "$1" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.address) \(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.workspace.name)"'
}
event_count() { # <type> <hex>
  local n
  n=$(grep -c "grassfield>>{\"v\":\"gfc/1\",\"type\":\"$1\",\"address\":\"$2\"}" "$events" 2>/dev/null)
  echo "${n:-0}"
}
wait_event() { # <type> <hex> <count before> [timeout ms]
  local deadline=$(($(date +%s%3N) + ${4:-4000}))
  while (($(date +%s%3N) < deadline)); do
    (($(event_count "$1" "$2") > $3)) && return 0
    sleep 0.02
  done
  return 1
}
move_count() { grep -cE "$1" "$events" 2>/dev/null; }
# ms from the latest move matching <regex> to the latest <type> event of A.
event_ms() {
  local t0 t1
  t0=$(grep -E "$1" "$events" | tail -n 1 | cut -d' ' -f1)
  t1=$(grep "grassfield>>{\"v\":\"gfc/1\",\"type\":\"$2\",\"address\":\"$hex\"}" "$events" | tail -n 1 | cut -d' ' -f1)
  [[ -n $t0 && -n $t1 ]] && echo $(((t1 - t0) / 1000)) || echo -1
}
# Captures of the output requested <delays> ms after the move matching <regex> (each grim adds its own start-up).
frames_after_move() { # <regex> <count before> <prefix> <delays...>
  local regex=$1 before=$2 prefix=$3 d deadline=$(($(date +%s%3N) + 4000)) shots=()
  shift 3
  while (($(move_count "$regex") <= before)); do
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.005
  done
  for d in "$@"; do
    (sleep "$((d / 1000)).$(printf '%03d' $((d % 1000)))" && WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/frames/$prefix-$d.ppm" 2>>"$log") &
    shots+=($!)
  done
  wait "${shots[@]}"
}
# Classifies every capture of <prefix> against <reference.ppm>; prints "<genie> <rect> <none> <other>" and logs each.
classify() { # <prefix> <reference.ppm> <limit y>
  local f j g=0 r=0 n=0 o=0
  for f in "$run/frames/$1"-*.ppm; do
    [[ -f $f ]] || continue
    j=$(python3 -I "$root/tests/compositor/genie_shape.py" "$f" "$2" "$x0" "$((y0 - 28))" "$w0" "$((h0 + 28))" "$3")
    echo "    $(basename "$f"): $j" >>"$log"
    printf '%s\n' "$j" >"${f%.ppm}.json"
    case $(jq -r '.class' <<<"$j") in
      genie) g=$((g + 1)) ;;
      rect) r=$((r + 1)) ;;
      none) n=$((n + 1)) ;;
      *) o=$((o + 1)) ;;
    esac
  done
  echo "$g $r $n $o"
}
# Every footprint of <prefix> lies at A's own box and spans its width (a fade in place: no movement, no shrink, no
# genie). The top row is not compared: a translucent titlebar over the dark sky differs too little from it.
in_place() { # <prefix>
  local f c top bottom left right
  for f in "$run/frames/$1"-*.json; do
    [[ -f $f ]] || continue
    c=$(jq -r '.class' "$f")
    [[ $c == none ]] && continue
    [[ $c == genie ]] && return 1
    read -r top bottom left right < <(jq -r '"\(.top) \(.bottom) \(.left) \(.right)"' "$f")
    ((top < y0 - 28 - 45 || bottom > y0 + h0 + 45 || bottom < y0 + h0 - 20 || left < x0 - 45 || right > x0 + w0 + 45 || right - left < w0 * 9 / 10)) && return 1
  done
  return 0
}
sheet() { # <prefix>
  local files
  mapfile -t files < <(ls "$run/frames/$1"-*.ppm 2>/dev/null | awk -F- '{print $NF" "$0}' | sort -n | cut -d' ' -f2-)
  ((${#files[@]} > 0)) && montage "${files[@]}" -tile "${#files[@]}x" -geometry 640x360+4+4 "$run/$1-sheet.png" 2>>"$log"
  for f in "${files[@]}"; do magick "$f" "${f%.ppm}.png" 2>>"$log"; done
}
# Centre of the Dock tile the shell sent with A's latest minimize (plugin log line, see minimize.sh) -> "x y tileTop".
follow_lines() { grep -ac "" "$follow" 2>/dev/null || echo 0; }
dock_tile() { # <since line>
  local line deadline=$(($(date +%s%3N) + 3000)) rx ry rw rh
  while :; do
    line=$(tail -n +"$(($1 + 1))" "$follow" 2>/dev/null | grep -a "\[grassfield\] minimize $hex: toward the Dock rectangle " | tail -n 1)
    [[ -n $line ]] && break
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
  read -r rx ry rw rh < <(sed -n 's/.*toward the Dock rectangle \(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p' <<<"$line")
  [[ -n ${rh:-} ]] || return 1
  echo "$((rx + rw / 2 - mon_x)) $((ry + rh / 2 - mon_y)) $((ry - mon_y))"
}


# Captures need frames: on a loaded GPU a capture (grim's screencopy) can hold the nested compositor's frames for
# hundreds of ms, longer than a whole animation. Captured animations therefore run in slow motion (Shift held when the
# animation starts: kSlowMotionFactor 10, a 5 s genie, a 3 s scale, a 1 s fade); the timing rounds run at normal speed
# without any capture.
SLOW_DELAYS=(400 1300 2200 3100 4000) # ms after the plugin's move of A
hold_shift() { # <ms>: Shift down for that long (virtual keyboard of the nested session), in the background
  "$root/scripts/dev/keys.sh" -M shift -s "$1" -m shift >>"$log" 2>&1 &
  sleep 0.2
}

# One minimize through the titlebar button; with <slow> 1, in slow motion with captures. Sets tx ty limit (the Dock
# tile) and writes <prefix>-after.ppm (the output once A is minimized).
minimize_round() { # <prefix> <slow 0|1>
  local n moves f0 bpid=""
  pointer abs "$min_x" "$bar_y" sleep 300 # hover first
  n=$(event_count minimized "$hex")
  moves=$(move_count "$to_minimized")
  f0=$(follow_lines)
  (($2)) && hold_shift 1500
  pointer abs "$min_x" "$bar_y" sleep 40 click
  if (($2)); then
    frames_after_move "$to_minimized" "$moves" "$1" "${SLOW_DELAYS[@]}" &
    bpid=$!
  fi
  wait_event minimized "$hex" "$n" 9000
  check "$1: minimized event" $? "count $(event_count minimized "$hex"), move -> event $(event_ms "$to_minimized" minimized) ms"
  [[ -n $bpid ]] && wait "$bpid"
  sleep 0.4
  (($2)) && WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/$1-after.ppm" 2>>"$log"
  read -r tx ty tile_top < <(dock_tile "$f0")
  [[ -n ${tile_top:-} ]] || { check "$1: the shell's Dock rectangle" 1 "no plugin log line"; return 1; }
  limit=$((tile_top - 16))
  read -r _ _ _ _ _ ws < <(client "$a_pid")
  [[ $ws == special:minimized ]]
  check "$1: A on special:minimized" $? "workspace $ws"
}
# One restore through A's Dock tile; with <slow> 1, in slow motion with captures (classified against the output after
# the minimize: the pointer leaves the Dock right after the click, so that its tooltip goes away).
restore_round() { # <prefix> <slow 0|1>
  local n moves bpid=""
  pointer abs "$tx" "$ty" sleep 400 # hover first (magnification, tooltip)
  n=$(event_count restored "$hex")
  moves=$(move_count "$to_workspace")
  (($2)) && hold_shift 1500
  pointer abs "$tx" "$ty" sleep 40 click
  if (($2)); then
    frames_after_move "$to_workspace" "$moves" "$1" "${SLOW_DELAYS[@]}" &
    bpid=$!
    pointer abs $((x0 + w0 / 2)) $((y0 + h0 / 2)) sleep 20
  fi
  wait_event restored "$hex" "$n" 9000
  check "$1: restored event" $? "count $(event_count restored "$hex"), move -> event $(event_ms "$to_workspace" restored) ms"
  [[ -n $bpid ]] && wait "$bpid"
  sleep 0.4
  read -r _ x y w h ws < <(client "$a_pid")
  [[ $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
  check "$1: A back at its geometry" $? "${w}x${h} at ($x,$y) on $ws"
  pointer abs $((x0 + w0 / 2)) $((y0 + h0 / 2)) sleep 50 # off the Dock before the next round
}
# <n> minimize + restore pairs at normal speed, no capture: the plugin logs each animation's frame timing.
timing_rounds() { # <label> <n>
  local i
  for ((i = 1; i <= $2; i++)); do
    minimize_round "$1-min$i" 0 >/dev/null || return 1
    restore_round "$1-restore$i" 0 >/dev/null
  done
  say "  $1: $2 minimize + restore pairs at normal speed: move -> minimized $(event_ms "$to_minimized" minimized) ms, move -> restored $(event_ms "$to_workspace" restored) ms (last pair)"
}

say "genie: nested pid $hypr_pid, output $out ${mon_w}x${mon_h}, features $(features)"
((c2)) || set_settings genie false
pointer abs $((mon_w / 2)) $((mon_h / 3)) sleep 50
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot >/dev/null 2>&1 </dev/null &
a_pid=$!
pids+=("$a_pid")
sleep 1.5
read -r addr x0 y0 w0 h0 ws0 < <(client "$a_pid")
[[ -n ${addr:-} ]] || { say "genie: setup error: window A not found"; exit 2; }
hex=${addr#0x}
min_x=$((x0 + 38))
bar_y=$((y0 - 14))
to_minimized="^[0-9]+ movewindowv2>>$hex,-?[0-9]+,special:minimized\$"
to_workspace="^[0-9]+ movewindowv2>>$hex,[0-9]+,$ws0\$"
say "  setup: A $addr ${w0}x${h0} at ($x0,$y0) on workspace $ws0"
WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/with-window.ppm" 2>>"$log"

if ((c2)); then
  # C2: no plugin. SUPER+M (the shell's `windows minimize`) parks A on special:minimized at once (the shell's fallback,
  # no animation); a click on its Dock tile (TILE_X TILE_Y on the output: the tile the plugin run logged for the same
  # layout) moves it back. Nothing of the plugin is involved.
  say "C2: minimize without the plugin (shell fallback)"
  moves=$(move_count "$to_minimized")
  timeout 20 "$root/tests/tools/vkbd/vkbd.sh" down Super_L tap m up Super_L >>"$log" 2>&1
  for _ in $(seq 1 60); do (($(move_count "$to_minimized") > moves)) && break; sleep 0.05; done
  sleep 0.3
  read -r _ _ _ _ _ ws < <(client "$a_pid")
  [[ $ws == special:minimized ]]
  check "C2: SUPER+M parks A on special:minimized" $? "workspace $ws"
  n=$(grep -c "grassfield>>" "$events")
  [[ $n == 0 ]]
  check "C2: no grassfield event" $? "$n"
  if [[ -n ${c2_tile_x:-} ]]; then
    pointer abs "$c2_tile_x" "$c2_tile_y" sleep 400
    pointer abs "$c2_tile_x" "$c2_tile_y" sleep 40 click
    sleep 1
    read -r _ x y w h ws < <(client "$a_pid")
    [[ $ws == "$ws0" && $x == "$x0" && $y == "$y0" && $w == "$w0" && $h == "$h0" ]]
    check "C2: a click on the Dock tile restores A" $? "${w}x${h} at ($x,$y) on $ws"
  else
    say "  C2 restore: NOT VERIFIED (no tile position given)"
  fi
  kill -0 "$hypr_pid" 2>/dev/null
  check "C2: nested Hyprland alive" $? "pid $hypr_pid"
  if ((fail == 0)); then say "genie c2: PASS"; else say "genie c2: FAIL"; fi
  say "genie c2: run $run"
  exit "$fail"
fi

if ((timing_only)); then
  say "timing: $pairs minimize + restore pairs per effect at normal speed, no capture"
  set_settings genie false
  timing_rounds genie "$pairs"
  set_settings scale false
  timing_rounds scale "$pairs"
  set_settings genie true
  timing_rounds fade "$pairs"
  set_settings genie false
else

# 1-2 genie
say "1 genie minimize (slow motion, captures)"
minimize_round genie-min 1 || exit 1
read -r g r n o < <(classify genie-min "$run/genie-min-after.ppm" "$limit")
((g >= 1))
check "genie: captures show the genie" $? "genie $g, rect $r, none $n, other $o of ${#SLOW_DELAYS[@]}"
sheet genie-min
say "2 genie restore (slow motion, captures)"
restore_round genie-restore 1
read -r g r n o < <(classify genie-restore "$run/genie-min-after.ppm" "$limit")
((g >= 1))
check "genie restore: captures show the genie" $? "genie $g, rect $r, none $n, other $o"
sheet genie-restore
timing_rounds genie 5

# 3 scale
say "3 scale"
set_settings scale false
minimize_round scale-min 1 || exit 1
read -r g r n o < <(classify scale-min "$run/scale-min-after.ppm" "$limit")
((g == 0 && r >= 1))
check "scale: uniform shrink, no genie" $? "genie $g, rect $r, none $n, other $o"
sheet scale-min
restore_round scale-restore 1
read -r g r n o < <(classify scale-restore "$run/scale-min-after.ppm" "$limit")
((g == 0 && r >= 1))
check "scale restore: uniform growth, no genie" $? "genie $g, rect $r, none $n, other $o"
sheet scale-restore
timing_rounds scale 3

# 4 Reduce Motion
say "4 Reduce Motion"
set_settings genie true
minimize_round fade-min 1 || exit 1
read -r g r n o < <(classify fade-min "$run/fade-min-after.ppm" "$limit")
in_place fade-min && ((g == 0 && r + o >= 1))
check "Reduce Motion: the window fades in place" $? "genie $g, rect $r, none $n, other $o"
sheet fade-min
restore_round fade-restore 1
read -r g r n o < <(classify fade-restore "$run/fade-min-after.ppm" "$limit")
in_place fade-restore && ((g == 0 && r + o >= 1))
check "Reduce Motion restore: the window fades in place" $? "genie $g, rect $r, none $n, other $o"
sheet fade-restore
timing_rounds fade 3
ms_min=$(event_ms "$to_minimized" minimized)
ms_res=$(event_ms "$to_workspace" restored)
((ms_min >= 0 && ms_min <= 250 && ms_res >= 0 && ms_res <= 250))
check "Reduce Motion: quick" $? "move -> minimized $ms_min ms, move -> restored $ms_res ms (fade 100 ms)"
set_settings genie false

# 5 unload / load mid-animation (slow motion: the unload lands inside the animation)
say "5 plugin unload and load mid-animation"
plugin_unload() { (cd "$root" && timeout 20 just plugin-unload) >>"$log" 2>&1; }
plugin_load() { (cd "$root" && timeout 20 just plugin-load) >>"$log" 2>&1; }
wait_features() { # the plugin advertises minimize-effect again
  local deadline=$(($(date +%s%3N) + 5000))
  while (($(date +%s%3N) < deadline)); do
    [[ ,$(features), == *,minimize-effect,* ]] && return 0
    sleep 0.1
  done
  return 1
}
n=$(grep -c "compositor plugin present" "$dev/shell.log")
pointer abs "$min_x" "$bar_y" sleep 300
hold_shift 1500
pointer abs "$min_x" "$bar_y" sleep 40 click
sleep 1
plugin_unload
sleep 0.5
read -r _ _ _ _ _ ws < <(client "$a_pid")
kill -0 "$hypr_pid" 2>/dev/null && [[ $ws == special:minimized ]]
check "unload mid-minimize" $? "Hyprland alive, A on $ws"
plugin_load
wait_features
check "load again: minimize-effect advertised" $? "features $(features)"
for _ in $(seq 1 50); do (($(grep -c "compositor plugin present" "$dev/shell.log") > n)) && break; sleep 0.1; done
sleep 0.5
pointer abs "$tx" "$ty" sleep 400
hold_shift 1500
pointer abs "$tx" "$ty" sleep 40 click
sleep 1
plugin_unload
sleep 0.5
read -r _ x y w h ws < <(client "$a_pid")
kill -0 "$hypr_pid" 2>/dev/null && [[ $ws == "$ws0" && $x == "$x0" && $y == "$y0" ]]
check "unload mid-restore" $? "Hyprland alive, A on $ws at ($x,$y)"
pointer abs $((x0 + w0 / 2)) $((y0 + h0 / 2)) sleep 300
WAYLAND_DISPLAY=$sock grim -t ppm -o "$out" "$run/after-unload-restore.ppm" 2>>"$log"
magick "$run/after-unload-restore.ppm" "$run/after-unload-restore.png" 2>>"$log"
j=$(python3 -I "$root/tests/compositor/genie_shape.py" "$run/after-unload-restore.ppm" "$run/genie-min-after.ppm" "$x0" "$((y0 - 28))" "$w0" "$((h0 + 28))" "$limit")
read -r rows left right bottom < <(jq -r '"\(.rows) \(.left // -1) \(.right // -1) \(.bottom // -1)"' <<<"$j")
# A, fully opaque at its place, differs from the output without it over its whole box.
((rows >= h0 && left <= x0 + 5 && right >= x0 + w0 - 5 && bottom >= y0 + h0 - 5))
check "A fully shown at its place after the unload mid-restore" $? "footprint vs the output without A: $j"
plugin_load
wait_features
check "load again" $? "features $(features)"

fi

# 6 health
say "6 health"
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $? "pid $hypr_pid"
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
[[ ${dumps:-0} == 0 ]]
check "no core dump of the nested Hyprland" $? "${dumps:-0} dump(s) for pid $hypr_pid since $start_human"
exceptions=$(grep -ac '\[grassfield\].*exception' "$follow")
[[ $exceptions == 0 ]]
check "no grassfield exception" $? "$exceptions in the followed log"
say "  plugin timing lines (frame interval and CPU time per frame on $out during each animation):"
grep -a "\[grassfield\] minimize $hex: .* in [0-9]* ms," "$follow" | sed 's/^.*\[grassfield\] /    /' | tee -a "$log"
grep -a "\[grassfield\] genie:" "$follow" | sed 's/^.*\[grassfield\] /    /' | tee -a "$log"
# Per effect, animations at normal speed only (slow motion lasts >= 1 s): a frame interval over 25 ms (1.5 x the 60 Hz
# period of the headless output) is a dropped frame.
say "  summary at normal speed (frame interval > 25 ms = dropped frame):"
grep -a "\[grassfield\] minimize $hex: .* in [0-9]* ms," "$follow" | sed 's/^.*\[grassfield\] //' | gawk '
  {
    effect = $3; ms = $6 + 0
    if (ms >= 1000) next
    match($0, /([0-9]+) frames/, f); match($0, /interval avg ([0-9.]+) max ([0-9.]+)/, iv)
    match($0, /cpu avg ([0-9.]+) max ([0-9.]+)/, cpu); match($0, /draw max ([0-9]+) us/, dr)
    n[effect]++; frames[effect] += f[1]; sumavg[effect] += iv[1]
    if (iv[2] > maxiv[effect]) maxiv[effect] = iv[2]
    if (iv[2] > 25) dropped[effect]++
    sumcpu[effect] += cpu[1]; if (cpu[2] > maxcpu[effect]) maxcpu[effect] = cpu[2]
    if (dr[1] > maxdraw[effect]) maxdraw[effect] = dr[1]
  }
  END {
    for (e in n)
      printf "    %s: %d animations, %d frames, frame interval mean %.1f ms, worst %.1f ms, %d animation(s) with a frame over 25 ms; frame cpu mean %.2f ms, worst %.2f ms; genie draw worst %d us\n",
        e, n[e], frames[e], sumavg[e] / n[e], maxiv[e], dropped[e], sumcpu[e] / n[e], maxcpu[e], maxdraw[e]
  }' | tee -a "$log"

if ((fail == 0)); then say "genie: PASS"; else say "genie: FAIL"; fi
say "genie: run $run"
exit "$fail"
