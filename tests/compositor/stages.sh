#!/usr/bin/env bash
# Stages scenario (docs/specs/stages.md, ADR-0013): grassfield-compositor keeps the windows of inactive stages mapped and
# live, draws them into the shell's strip tiles, blocks their input and swaps a stage into the centre, without resizing,
# moving or configuring any client.
#
# Usage: tests/compositor/stages.sh [check] [--plugin PATH]  functional scenario (default; PATH: the build loaded, see below)
#        tests/compositor/stages.sh perf [seconds]       CPU of the nested Hyprland, 3 stages x 3 foot windows, each phase
#                                                        `seconds` long (default 30), plus the special-workspace
#                                                        alternative (windows parked, not rendered)
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded (feature "stages-available"). Every foot
# goes through scripts/dev/isolated.sh with the nested socket; pointer and keys through scripts/dev/pointer.sh and
# scripts/dev/keys.sh; the verbs (hl.plugin.grassfield.config / stages / minimize / restore) and plugin unload / load go
# through scripts/nestctl. The shell's strip is stood in for by tests/compositor/stages-fixture (a transparent Top-layer
# surface, namespace grassfield-stages, over the tiles; it logs presses, and the script maps them to stages as the shell
# would).
#
# check: 9 foot windows on OUTPUT (GF-REF), three apps (app ids gf-stage-a, gf-stage-b, gf-stage-c), opened in the order
# a1 b1 c1 a2 b2 c2 a3 b3 c3: a1 prints the time every 200 ms (ticker), b3 is larger (1000x760) and reports mouse buttons
# and typed bytes (capture B), c3 reports typed bytes (capture C). Windows open centred, so a point inside b3 and outside
# the 700x500 windows (the "ring point") is covered by b3 only. Checks: flag, refusals, grouping, sizes unchanged,
# thumbnails drawn in their tiles, live thumbnail, strip windows take no input at their real places, tile press reaches
# the strip surface, swap (animated, then input and keys to the new stage), move / merge / new stage, a new window, a
# closed window, focus by dispatch, hidden strip, minimize / restore, full screen, overlap, strip surface gone, invalid
# payloads and a flood, unload during Stages and reload, health. Input on strip windows (R13 review of 46b3e9b): a click
# without pointer motion after a swap (5b) and after a new window opened (7b) never reaches the strip window that was
# Hyprland's pointer focus; a swap made while an Exclusive layer holds the keyboard is kept when the layer closes (8b,
# second fixture instance with GF_STAGES_ROLE=exclusive); minimizing the only window of the active stage gives the
# keyboard to the next stage's front window, never to the minimized window (12b); Hyprland's window cycling stays within
# the active stage (12c). R13 counter-review of 17208af: after a swap under an Exclusive layer Hyprland's active window is
# never the strip window and a window dispatcher (close) never reaches it (8c); a menu of the active stage's window keeps
# its keys, and closes when its window goes to the strip without losing a key (8d, a third fixture instance with
# GF_STAGES_ROLE=popup); a request for a strip window on another Desktop still brings its stage forward, a Desktop switch
# back keeps the active stage (8e). R13 counter-review #3 of e9ebc7f (the plugin may focus nothing while an Exclusive layer
# holds the keyboard): no window focus and no focused-monitor change under the layer (8c, the pointer on the other output
# first when there are two); a swap under the layer with a special workspace open keeps every key at the layer and the
# special workspace open (8f); a stage of a Desktop not shown activated under the layer switches nothing and focuses
# nothing (8g); a polkit-like dialog (GF_STAGES_ROLE=polkit: full-output Overlay, Exclusive, password field) keeps every
# key, and the activated stage gets the keyboard when it ends (8h). R13 counter-review #4 of 0.6.3-stages (Hyprland's
# refocus at the cursor reports CLICK): after a swap under an Exclusive layer the swapped-in front window gets the keys with
# the pointer over an unrelated tiled window, the stage's back window or empty desktop, the stage's window now in front gets
# them when the remembered one closed under the layer, a real click beside the layer or just after it wins, and the Stages
# event names the front window and app while Hyprland has no active window (8i); a focus-matched window rule is rechecked
# when the plugin clears the active window (8c). A keyboard device that appears while an Exclusive layer holds the keyboard
# after a swap (a keyboard plugged in, a Bluetooth keyboard reconnecting, an on-screen keyboard) changes nothing: the layer
# gets every key of the new device and of the next one, no window gets one, and after the layer the swapped-in front window
# gets every key (8j; integrator decision 2026-10-24: stages.sh 8c, 8f, 8g, 8h, 8i(e) lost every key in the three runs
# whose nested session had no keyboard device of its own, see "keyboard devices" at the start of the run).
# Screenshots (grim -o OUTPUT): .dev/stages/run-<timestamp>/. Exit: 0 PASS, 1 FAIL, 2 usage or environment error. Never hangs:
# every wait is bounded, a FAIL while the nested Hyprland does not answer stops the run, and the run is bounded (check 15
# min, perf its seconds + 15 min).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# --plugin PATH: the build loaded in the nested session for this run (default compositor/build/grassfield-compositor.so),
# e.g. a pre-fix build loaded through scripts/nestctl plugin load to show that the checks discriminate; step 15 unloads
# and loads that same file.
plugin=$root/compositor/build/grassfield-compositor.so
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --plugin) plugin=${2:?--plugin needs a path}; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
mode=${args[0]:-check}
perf_secs=${args[1]:-30}
usage="usage: stages.sh [check|perf [seconds]] [--plugin PATH]"
case $mode in
  check) ;;
  perf) [[ $perf_secs =~ ^[1-9][0-9]*$ ]] || { echo "$usage" >&2; exit 2; } ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
[[ -f $plugin ]] || { echo "stages: no plugin build at $plugin" >&2; exit 2; }

out=GF-REF
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
  echo "stages: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "stages: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat jq grim magick foot qs; do
  command -v "$tool" >/dev/null || { echo "stages: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
features() { nestctl -j grassfield 2>/dev/null | jq -c '.features'; }
has_feature() { nestctl -j grassfield 2>/dev/null | jq -e --arg f "$1" '.features | index($f)' >/dev/null; }
has_feature stages-available || { echo "stages: the loaded plugin does not advertise \"stages-available\"" >&2; exit 2; }

run=$dev/stages/run-$(date +%Y%m%d-%H%M%S)-$mode
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
fixlog=$run/fixture.log
start_human=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
# The fixture instances (Quickshell) talk to the nested session's private bus, never the owner's session bus (without
# one, D-Bus is disabled for them).
fixture_bus=disabled:
[[ -s $dev/bus.address ]] && fixture_bus=$(head -n 1 "$dev/bus.address")

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
# Each keys.sh / pointer.sh run adds a virtual device; clients bind their new wl_keyboard / wl_pointer when the seat
# capability comes back, so the first event can be lost on a loaded host: a short wait after the device appears.
keys() { timeout 10 "$root/scripts/dev/keys.sh" -s 150 "$@" >>"$log" 2>&1; }
shot() { WAYLAND_DISPLAY=$sock timeout 10 grim -l 0 -o "$out" "$run/$1.png" 2>>"$log"; }
# Fail fast, never hang (2026-10-23: a compositor that stopped answering left this script waiting for 30 minutes): every
# wait is bounded, a process is stopped within 5 s, a number handed to jq is checked first, a FAIL while the nested
# Hyprland does not answer ends the run at once, and the whole run is bounded (check: 15 min, perf: its seconds + 15 min).
alive() { nestctl -j version >/dev/null 2>&1; }
reap() { # <pid>: TERM, at most 5 s, then KILL; never waits longer
  local p=$1 i
  [[ -n $p ]] || return 0
  kill "$p" 2>/dev/null
  for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  return 0
}
num() { [[ ${1:-} =~ ^-?[0-9]+$ ]] && echo "$1" || echo -1; } # an integer for jq --argjson, -1 when there is none
bound=$((15 * 60))
[[ $mode == perf ]] && bound=$((perf_secs + 15 * 60))
( sleep "$bound" && kill -TERM $$ 2>/dev/null ) &
watchdog=$!
trap 'echo "stages: FAIL: over the time bound ($bound s): stopped" >&2; exit 1' TERM

pids=()
socat_pid=""
fixture_pid=""
exclusive_pid=""
plugin_unloaded=0
cleanup() {
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  [[ -n $exclusive_pid ]] && kill "$exclusive_pid" 2>/dev/null
  [[ -n ${popup_pid:-} ]] && kill "$popup_pid" 2>/dev/null
  [[ -n ${polkit_pid:-} ]] && kill "$polkit_pid" 2>/dev/null
  [[ -n ${ondemand_pid:-} ]] && kill "$ondemand_pid" 2>/dev/null
  nestctl dispatch 'hl.plugin.grassfield.stages([[{"op":"off","durationMs":0}]])' >/dev/null 2>&1
  nestctl dispatch 'hl.plugin.grassfield.config("stagesEnabled", "false")' >/dev/null 2>&1
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  [[ -n ${watchdog:-} ]] && { pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; } # its sleep too
  if ((plugin_unloaded)); then
    nestctl plugin load "$plugin" >/dev/null 2>&1 # never leave the nested session without the plugin
  fi
}
trap cleanup EXIT

stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!

st_events() { grep -a 'grassfield>>{"v":"gfc/1","type":"stages"' "$events" 2>/dev/null; }
st_count() { st_events | grep -c -- "$1"; }
last_st() { st_events | tail -n 1 | sed 's/^[0-9]* grassfield>>//'; }
# Waits until more than <before> stages events match <regex> (at most <ms>).
wait_st() { # <regex> <before> <ms>
  local deadline=$(($(date +%s%3N) + $3))
  while (($(st_count "$1") <= $2)); do
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.02
  done
}
stages() { nestctl dispatch "hl.plugin.grassfield.stages([[$1]])" >>"$log" 2>&1; }
config() { nestctl dispatch "hl.plugin.grassfield.config(\"$1\", \"$2\")" >>"$log" 2>&1; }

read -r mon_x mon_y mon_w mon_h < <(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "stages: output $out not found" >&2; exit 2; }
# With two outputs, 8c moves the pointer to the other one first (Hyprland focuses that monitor): the focused monitor must not
# change while an Exclusive layer holds the keyboard.
other_out=$(nestctl -j monitors | jq -r --arg o "$out" '[.[] | select(.name != $o and (.disabled | not))][0].name // ""')

# Strip geometry (layout coordinates): the strip surface on the left edge, four tiles in it.
strip_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '{x: $x, y: ($y + 60), w: 220, h: 860}')
tiles_json=$(jq -nc --argjson x "$mon_x" --argjson y "$mon_y" '[range(0; 4) as $i | {x: ($x + 16), y: ($y + 100 + $i * 190), w: 188, h: 160}]')
on_json() { # <durationMs> [hidden]
  jq -nc --arg o "$out" --argjson d "$1" --argjson h "${2:-false}" --argjson t "$tiles_json" '{op: "on", durationMs: $d, strips: [{monitor: $o, hidden: $h, tiles: $t}]}'
}
tile() { jq -r --argjson i "$1" '.[$i] | "\(.x) \(.y) \(.w) \(.h)"' <<<"$tiles_json"; }

start_fixture() {
  : >"$fixlog"
  GF_STAGES_OUTPUT=$out GF_STAGES_STRIP=$strip_json GF_STAGES_TILES=$tiles_json WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name stages-fixture qs -p "$root/tests/compositor/stages-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
  fixture_pid=$!
  local i
  for i in $(seq 1 50); do
    grep -q "\[stages-fixture\] output .* found" "$fixlog" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5
  grep -q "\[stages-fixture\] output $out found" "$fixlog"
}
stop_fixture() {
  [[ -n $fixture_pid ]] || return 0
  reap "$fixture_pid"
  fixture_pid=""
}
# A second fixture instance: an Overlay surface with Exclusive keyboard interactivity (what the overview chrome or Search
# is to Hyprland); it logs every key it receives. Killing it unmaps the surface.
exlog=$run/exclusive.log
start_exclusive() {
  : >"$exlog"
  GF_STAGES_ROLE=exclusive GF_STAGES_OUTPUT=$out WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name stages-exclusive qs -p "$root/tests/compositor/stages-fixture" --no-color >"$exlog" 2>&1 </dev/null &
  exclusive_pid=$!
  local i
  for i in $(seq 1 50); do
    grep -q "\[stages-fixture\] exclusive surface shown" "$exlog" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5
  grep -q "\[stages-fixture\] exclusive surface shown" "$exlog"
}
stop_exclusive() {
  [[ -n $exclusive_pid ]] || return 0
  reap "$exclusive_pid"
  exclusive_pid=""
}
# A fourth fixture instance (role polkit): what the shell's authentication dialog is to Hyprland (a full-output Overlay
# surface with Exclusive keyboard interactivity and a password field); it logs every key its field gets; Escape releases it
# as the dialog ends (keyboard None, unmapped 400 ms later).
pklog=$run/polkit.log
polkit_pid=""
start_polkit() {
  : >"$pklog"
  GF_STAGES_ROLE=polkit GF_STAGES_OUTPUT=$out WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name stages-polkit qs -p "$root/tests/compositor/stages-fixture" --no-color >"$pklog" 2>&1 </dev/null &
  polkit_pid=$!
  local i
  for i in $(seq 1 50); do
    grep -q "\[stages-fixture\] polkit dialog shown" "$pklog" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5
  grep -q "\[stages-fixture\] polkit dialog shown" "$pklog"
}
stop_polkit() {
  [[ -n $polkit_pid ]] || return 0
  reap "$polkit_pid"
  polkit_pid=""
}
# A fifth fixture instance (role ondemand): a Top-layer surface with OnDemand keyboard interactivity (a clickable banner);
# it logs every key it receives.
odlog=$run/ondemand.log
ondemand_pid=""
start_ondemand() {
  : >"$odlog"
  GF_STAGES_ROLE=ondemand GF_STAGES_OUTPUT=$out WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name stages-ondemand qs -p "$root/tests/compositor/stages-fixture" --no-color >"$odlog" 2>&1 </dev/null &
  ondemand_pid=$!
  wait_log "$odlog" "ondemand surface shown" 50
}
stop_ondemand() {
  [[ -n $ondemand_pid ]] || return 0
  reap "$ondemand_pid"
  ondemand_pid=""
}
# A third fixture instance: an app window whose click opens a menu (an xdg_popup with a grab); it logs the menu opening and
# closing and every key the window and the menu receive.
popuplog=$run/popup.log
popup_pid=""
start_popup_app() {
  : >"$popuplog"
  GF_STAGES_ROLE=popup GF_STAGES_OUTPUT=$out WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig DBUS_SESSION_BUS_ADDRESS=$fixture_bus \
    setsid "$root/scripts/dev/isolated.sh" --name stages-popup qs -p "$root/tests/compositor/stages-fixture" --no-color >"$popuplog" 2>&1 </dev/null &
  popup_pid=$!
  wait_log "$popuplog" "popup app shown" 50
}
stop_popup_app() {
  [[ -n $popup_pid ]] || return 0
  reap "$popup_pid"
  popup_pid=""
}
# Waits until a fixture log has a "[stages-fixture] <text>" line (Quickshell writes its log lines with a delay).
wait_log() { # <log> <text> <tries of 50 ms>
  local i
  for i in $(seq 1 "$3"); do
    grep -q "\[stages-fixture\] $2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}
client_mapped() { nestctl -j clients 2>/dev/null | jq -e --arg a "$1" 'any(.[]; .address == $a and .mapped)' >/dev/null; }
focused_monitor() { nestctl -j monitors 2>/dev/null | jq -r '[.[] | select(.focused)][0].name // ""'; }
special_of() { nestctl -j monitors 2>/dev/null | jq -r --arg o "$out" '.[] | select(.name == $o) | .specialWorkspace.name // ""'; }
shown_ws() { nestctl -j monitors 2>/dev/null | jq -r --arg o "$out" '.[] | select(.name == $o) | .activeWorkspace.id'; }
event_lines() { sleep 0.2; grep -ac "" "$events"; } # socat writes with a short delay
events_since() { tail -n +"$(($1 + 1))" "$events"; } # <line count before>
# How many key lines of a fixture log name one of <characters> (each test types its own letters into a freshly started
# fixture); polls 1 s for Quickshell's late log lines.
layer_got() { # <log> <prefix> <characters>
  local n=0 i
  for i in $(seq 1 20); do
    n=$(grep -cE "\[stages-fixture\] $2 [$3]\$" "$1" 2>/dev/null)
    ((n >= ${#3})) && break
    sleep 0.05
  done
  echo "${n:-0}"
}
active_window() { nestctl -j activewindow 2>/dev/null | jq -r '.address // ""'; }
cap_since() { tail -c +"$(($2 + 1))" "$1" | cat -v | head -c 120; } # <capture> <size before>: bytes typed since

foot_bg() { # <app id> [foot args...] -> pid
  local app=$1
  shift
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name stages foot --app-id="$app" "$@" >/dev/null 2>&1 </dev/null &
  echo $!
}
# A foot that reports mouse buttons (xterm 1000 + 1006 SGR) and every byte typed into <capture> (raw tty).
foot_capture() { # <app id> <capture> [foot args...] -> pid
  local app=$1 cap=$2
  shift 2
  : >"$cap"
  foot_bg "$app" "$@" -e sh -c 'stty raw -echo; printf "\033[?1000h\033[?1006h"; exec cat -v >"$0"' "$cap"
}
address_of() { # <pid> -> address (0x...) of its mapped window, waits up to 5 s
  local a="" i
  for i in $(seq 1 50); do
    a=$(nestctl -j clients 2>/dev/null | jq -r --argjson p "$1" '[.[] | select(.pid == $p and .mapped)][0].address // ""')
    [[ -n $a ]] && break
    sleep 0.1
  done
  echo "$a"
}
clients_of() { # <addresses (space separated)> -> compact at/size per window, sorted
  nestctl -j clients | jq -c --arg list "$1" '[.[] | select(.address as $a | ($list | split(" ") | index($a))) | {address, at, size}] | sort_by(.address)'
}
hexof() { echo "${1#0x}"; }
# Stage ids from the last event: the active one, the one in tile <slot>, the one holding window <address>.
active_id() { last_st | jq -r '.monitors[0].active // 0'; }
slot_id() { last_st | jq -r --argjson s "$1" '[.monitors[0].stages[] | select(.slot == $s) | .id][0] // 0'; }
stage_of() { last_st | jq -r --arg a "$(hexof "$1")" '[.monitors[0].stages[] | select(.windows | map(.address) | index($a)) | .id][0] // 0'; }
in_active() { last_st | jq -e --arg a "$(hexof "$1")" '.monitors[0] as $m | [$m.stages[] | select(.id == $m.active) | .windows[].address] | index($a)' >/dev/null; }
stage_count() { last_st | jq -r '.monitors[0].stages | length'; }

# Mean colour of a w x h crop centred on (x, y) (output-local pixels) of <png>: "r g b" (0..255).
mean_rgb() { # <png> <x> <y> <w> <h>
  magick "$1" -crop "${4}x${5}+$(($2 - $4 / 2))+$(($3 - $5 / 2))" +repage -resize 1x1\! -depth 8 txt:- 2>/dev/null \
    | sed -n 's/.*(\([0-9.]*\),\([0-9.]*\),\([0-9.]*\).*/\1 \2 \3/p' | awk '{printf "%d %d %d\n", $1, $2, $3}'
}
# Share of pixels of a crop that are terminal grey (foot's dark background, scaled down: dark neutral).
grey_share() { # <png> <tile index>: percent of terminal-grey pixels in the tile
  local x y w h
  read -r x y w h < <(tile "$2")
  # txt lines are "x,y: (r,g,b)  #hex  srgb(...)": the first parenthesized triple is the colour.
  magick "$1" -crop "${w}x${h}+$((x - mon_x))+$((y - mon_y))" +repage -depth 8 txt:- 2>/dev/null \
    | sed -n 's/^[^(]*(\([0-9]*\),\([0-9]*\),\([0-9]*\).*/\1 \2 \3/p' | awk '
    { r = $1; g = $2; b = $3; m = r; if (g > m) m = g; if (b > m) m = b; n = r; if (g < n) n = g; if (b < n) n = b; t++; if (m < 70 && m - n < 10) k++ }
    END { printf "%d\n", t ? 100 * k / t : 0 }'
}
crop_diff() { # <a.png> <b.png> <tile index>
  local x y w h
  read -r x y w h < <(tile "$3")
  local geom="${w}x${h}+$((x - mon_x))+$((y - mon_y))"
  magick compare -metric AE -fuzz 3% <(magick "$1" -crop "$geom" +repage png:-) <(magick "$2" -crop "$geom" +repage png:-) null: 2>&1 | sed -n 's/^\([0-9.e+]*\).*/\1/p'
}
cpu_ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

fail=0 passed=0 total=0
check() { # <label> <status> [detail]
  total=$((total + 1))
  if [[ $2 == 0 ]]; then
    passed=$((passed + 1))
    say "  PASS $1${3:+ ($3)}"
  else
    say "  FAIL $1${3:+ ($3)}"
    fail=1
    if ! alive; then
      say "  FAIL the nested Hyprland does not answer (hung or gone): the run stops here ($passed/$total)"
      exit 1
    fi
  fi
}

say "stages $mode: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), output $out ${mon_w}x${mon_h} at $mon_x,$mon_y"
say "plugin features: $(features)"
# Keyboard devices of the nested session that are not this run's virtual keyboards (the backend keyboard aquamarine gets
# from the parent seat; none when the parent seat had no keyboard at start). Without one, every key of this run comes from
# a keyboard device that appears for its burst and goes (2026-10-24: the three runs that lost keys in 8c to 8i(e) had none).
own_kbds=$(nestctl -j devices 2>/dev/null | jq -r '[.keyboards[]? | select(.name | test("virtual") | not)] | length')
say "keyboard devices: ${own_kbds:-?} of the session's own (besides the virtual keyboards of this run)"

# New windows open on the output under the pointer, centred.
pointer abs $((mon_w / 2)) $((mon_h - 160)) sleep 50

# ---- windows: 3 apps x 3 ----
open_windows() { # sets addr_a1..addr_c3, cap_b, cap_c, pids
  local p
  cap_b=$run/capture-b.cap
  cap_c=$run/capture-c.cap
  # Order a2 b1 c1 a3 b2 c2 a1 b3 c3: the ticker (a1) is the front window of app a, so its thumbnail is fully visible.
  p=$(foot_bg gf-stage-a); pids+=("$p"); sleep 0.35; addr_a2=$(address_of "$p")
  p=$(foot_bg gf-stage-b); pids+=("$p"); sleep 0.35; addr_b1=$(address_of "$p")
  p=$(foot_bg gf-stage-c); pids+=("$p"); sleep 0.35; addr_c1=$(address_of "$p")
  p=$(foot_bg gf-stage-a); pids+=("$p"); sleep 0.35; addr_a3=$(address_of "$p")
  p=$(foot_bg gf-stage-b); pids+=("$p"); sleep 0.35; addr_b2=$(address_of "$p")
  p=$(foot_bg gf-stage-c); pids+=("$p"); sleep 0.35; addr_c2=$(address_of "$p")
  if [[ $mode == perf ]]; then
    p=$(foot_bg gf-stage-a -e sh -c 'while sleep 0.1; do [ -e "$0" ] && date +%T.%N; done' "$run/ticker.flag")
  else
    p=$(foot_bg gf-stage-a -e sh -c 'while sleep 0.2; do date +%T.%N; done')
  fi
  pids+=("$p"); sleep 0.35; addr_a1=$(address_of "$p")
  p=$(foot_capture gf-stage-b "$cap_b" --window-size-pixels=1000x760); pids+=("$p"); sleep 0.35; addr_b3=$(address_of "$p")
  p=$(foot_capture gf-stage-c "$cap_c"); pids+=("$p"); sleep 0.35; addr_c3=$(address_of "$p")
  all="$addr_a1 $addr_b1 $addr_c1 $addr_a2 $addr_b2 $addr_c2 $addr_a3 $addr_b3 $addr_c3"
  for a in $all; do [[ -n $a ]] || return 1; done
  [[ $(wc -w <<<"$all") -eq 9 ]]
}
open_windows || { say "setup error: windows did not map ($all)"; exit 2; }
sleep 1
say "setup: a $addr_a1 $addr_a2 $addr_a3 (a1 ticker) | b $addr_b1 $addr_b2 $addr_b3 (b3 capture, 1000x760) | c $addr_c1 $addr_c2 $addr_c3 (c3 capture)"

if [[ $mode == perf ]]; then
  # ---- perf: Hyprland CPU in each phase ----
  hz=$(getconf CLK_TCK)
  measure() { # <label>
    local h0 s0 h1 s1 t0 t1
    h0=$(cpu_ticks "$hypr_pid"); s0=$(cpu_ticks "${shell_pid:-0}"); t0=$(date +%s%N)
    sleep "$perf_secs"
    h1=$(cpu_ticks "$hypr_pid"); s1=$(cpu_ticks "${shell_pid:-0}"); t1=$(date +%s%N)
    awk -v l="$1" -v h=$((h1 - h0)) -v s=$((s1 - s0)) -v dt=$((t1 - t0)) -v hz="$hz" -v rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$hypr_pid/status")" \
      'BEGIN { sec = dt / 1e9; printf "| %s | %.1f %% | %.1f %% | %.0f MB |\n", l, 100 * h / hz / sec, 100 * s / hz / sec, rss / 1024 }' | tee -a "$log"
  }
  flag=$run/ticker.flag
  say "perf: 9 foot windows (3 apps x 3) on $out, ${perf_secs} s per phase, CPU = % of one core from /proc/<pid>/stat; ticker = a1, 10 lines/s"
  say "| Phase | nested Hyprland | grassfield-shell | Hyprland RSS |"
  measure "Stages off, idle"
  touch "$flag"; measure "Stages off, ticker shown"; rm -f "$flag"
  config stagesEnabled true
  start_fixture || say "perf: fixture did not start (see $fixlog)"
  stages "$(on_json 350)"; sleep 1
  measure "Stages on (2 strip stages = 6 windows drawn live in tiles), idle"
  touch "$flag"; measure "Stages on, ticker in a strip tile (live thumbnail)"; rm -f "$flag"
  stages "{\"op\":\"activate\",\"stage\":$(stage_of "$addr_a1")}"; sleep 1
  touch "$flag"; measure "Stages on, ticker in the active stage"; rm -f "$flag"
  (
    end=$(($(date +%s) + perf_secs))
    while (($(date +%s) < end)); do
      stages "{\"op\":\"activate\",\"stage\":$(slot_id 0)}"
      sleep 1
    done
  ) &
  swapper=$!
  measure "Stages on, a swap every second (350 ms animations)"
  wait "$swapper"
  stages '{"op":"off","durationMs":0}'; sleep 0.5
  stop_fixture
  config stagesEnabled false
  # The alternative: the 6 windows of two apps parked on a special workspace (not rendered, no frame callbacks).
  for a in $addr_a1 $addr_a2 $addr_a3 $addr_b1 $addr_b2 $addr_b3; do
    nestctl dispatch "hl.dsp.window.move({ workspace = \"special:gf-park\", follow = false, window = \"address:$a\" })" >>"$log" 2>&1
  done
  sleep 1
  measure "special workspace alternative: 6 windows parked, idle"
  touch "$flag"; measure "special workspace alternative: ticker parked (not rendered: frozen)"; rm -f "$flag"
  kill -0 "$hypr_pid" 2>/dev/null || { say "perf: FAIL nested Hyprland is gone"; exit 1; }
  say "perf: stages events posted: $(st_events | wc -l)"
  say "perf: done (log $log)"
  exit 0
fi

# ---- check ----
before_clients=$(clients_of "$all")
shot before

# 1. the feature flag: off by default; a request is refused; only true|false accepted.
! has_feature stages
check "flag off by default: stages-available advertised, stages not" $? "$(features)"
d0=$(st_count '"reason":"disabled"')
stages "$(on_json 0)"
sleep 0.4
(($(st_count '"reason":"disabled"') > d0))
check "op on with the flag off: refused (disabled)" $? "$(last_st | cut -c1-120)"
config stagesEnabled yes
sleep 0.3
! has_feature stages
check "config stagesEnabled=yes rejected (true|false only)" $? "$(features)"
config stagesEnabled true
sleep 0.3
has_feature stages
check "config stagesEnabled=true: stages advertised" $? "$(features)"

# 2. op on: refused without the strip surface; with it, one stage per app, the front app's stage active.
n0=$(st_count '"reason":"no-strip"')
stages "$(on_json 0)"
sleep 0.4
(($(st_count '"reason":"no-strip"') > n0))
check "op on without the shell's strip surface: refused (no-strip)" $? "$(last_st | cut -c1-120)"
start_fixture
check "strip fixture mapped on $out" $? "$fixlog"
o0=$(st_count '"on":true')
stages "$(on_json 0)"
wait_st '"on":true' "$o0" 2000
check "op on with the strip: on" $? "$(last_st | cut -c1-160)"
sleep 0.5
st_on=$(last_st)
printf '%s\n' "$st_on" >"$run/on.json"
[[ $(stage_count) == 3 ]] && in_active "$addr_c3" && in_active "$addr_c1" && [[ $(slot_id 0) == "$(stage_of "$addr_b3")" && $(slot_id 1) == "$(stage_of "$addr_a1")" ]]
check "grouped by app: 3 stages, c active (front window), b in tile 0, a in tile 1" $? "$run/on.json"
during_clients=$(clients_of "$all")
[[ $during_clients == "$before_clients" ]]
check "client sizes and positions unchanged with Stages on" $? "$during_clients"

# 3. thumbnails: terminal grey in tiles 0 and 1, none in tile 2; live: the ticker's tile changes, the idle one does not.
shot on
g0=$(grey_share "$run/on.png" 0); g1=$(grey_share "$run/on.png" 1); g2=$(grey_share "$run/on.png" 2)
gb0=$(grey_share "$run/before.png" 0); gb1=$(grey_share "$run/before.png" 1)
((g0 >= 25 && g1 >= 25 && g2 <= 2 && gb0 <= 2 && gb1 <= 2))
check "thumbnails drawn in their tiles" $? "terminal grey: tile0 $g0 %, tile1 $g1 %, tile2 $g2 % (before: $gb0 %, $gb1 %)"
sleep 0.6
shot on-later
dt1=$(crop_diff "$run/on.png" "$run/on-later.png" 1)
dt0=$(crop_diff "$run/on.png" "$run/on-later.png" 0)
awk -v t="${dt1:-0}" -v i="${dt0:-1}" 'BEGIN { exit !(t > 5 && i == 0) }'
check "live thumbnails: the ticker's tile (a) changes, the idle tile (b) does not" $? "tile1 $dt1 px, tile0 $dt0 px"

# 4. input: strip windows take nothing at their real places; keys go to the active stage; a tile press reaches the strip.
read -r bx by bw bh < <(jq -r '.[] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' <<<"$(clients_of "$addr_b3")")
ring_x=$((bx + 40 - mon_x)) ring_y=$((by + bh / 2 - mon_y)) # inside b3 (1000 wide), outside the centred 700-wide windows
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
# Keys first: the ring point may lie on the desktop (it is on Quickshell's first screen, GF-REF or WAYLAND-1 depending on
# the output order), and a press on the desktop gives it the keyboard (desktop focus policy, ADR-0012).
keys k1
sleep 0.4
pointer abs "$ring_x" "$ring_y" sleep 150 click sleep 200
capb_new=$(tail -c +"$((capb0 + 1))" "$cap_b" | cat -v | head -c 120)
capc_new=$(tail -c +"$((capc0 + 1))" "$cap_c" | cat -v | head -c 120)
[[ -z $capb_new && $capc_new == *k1* ]]
check "strip window b3 takes no click at its real place; keys go to the active stage (c3)" $? "ring point $ring_x,$ring_y: b3 got '$capb_new', c3 got '$capc_new'"
read -r tx ty tw th < <(tile 0)
p0=$(grep -c "\[stages-fixture\] press" "$fixlog")
# Two motions: each pointer.sh run adds a pointer device, the client binds a new wl_pointer after the first motion and gets
# its enter at a stale position (-1,-1); the second motion gives it the real one (Quickshell drops a press outside items).
pointer abs $((tx + tw / 2 - mon_x)) $((ty + th / 2 - mon_y)) sleep 150 abs $((tx + tw / 2 - mon_x + 1)) $((ty + th / 2 - mon_y)) sleep 100 click sleep 200
for _ in $(seq 1 40); do # Quickshell writes its log lines with a delay
  (($(grep -c "\[stages-fixture\] press" "$fixlog") > p0)) && break
  sleep 0.05
done
press=$(grep "\[stages-fixture\] press" "$fixlog" | tail -n 1 | sed 's/.*press //')
(($(grep -c "\[stages-fixture\] press" "$fixlog") > p0))
check "a press on a thumbnail reaches the strip surface (the shell)" $? "press at $press"

# 5. swap: the pressed tile's stage comes forward (what the shell sends), animated; then b3 takes input and keys.
stages "$(on_json 900)" # slower swaps, so that a frame mid-animation can be captured
sleep 0.3
read -r px py <<<"$press"
px=$(num "${px:-}") py=$(num "${py:-}") # no press logged: -1 -1, no tile
hit=$(jq -r --argjson x "$px" --argjson y "$py" '[to_entries[] | select($x >= .value.x and $x < .value.x + .value.w and $y >= .value.y and $y < .value.y + .value.h) | .key][0] // -1' <<<"$tiles_json")
target=$(slot_id "$hit")
old_active=$(active_id)
a0=$(st_count '"active":'"$target"',')
stages "{\"op\":\"activate\",\"stage\":$target}"
sleep 0.35
shot swap-mid
wait_st '"active":'"$target"',' "$a0" 2000
swap_ok=$?
sleep 0.9
shot swapped
[[ $swap_ok == 0 && $hit == 0 && $(slot_id 0) == "$old_active" ]] && in_active "$addr_b3"
check "activate the pressed tile's stage: b becomes active, c goes to tile 0" $? "tile $hit -> stage $target; active $(active_id), tile0 $(slot_id 0)"
m1=$(magick compare -metric AE -fuzz 3% "$run/swap-mid.png" "$run/on-later.png" null: 2>&1 | sed -n 's/^\([0-9.e+]*\).*/\1/p')
m2=$(magick compare -metric AE -fuzz 3% "$run/swap-mid.png" "$run/swapped.png" null: 2>&1 | sed -n 's/^\([0-9.e+]*\).*/\1/p')
awk -v a="${m1:-0}" -v b="${m2:-0}" 'BEGIN { exit !(a > 20000 && b > 20000) }'
check "the swap is animated: a frame mid-swap differs from before and after" $? "$m1 / $m2 px"
[[ $(clients_of "$all") == "$before_clients" ]]
check "client sizes and positions unchanged after the swap" $?
capb0=$(stat -c %s "$cap_b")
pointer abs "$ring_x" "$ring_y" sleep 150 click sleep 200
keys k2
sleep 0.4
capb_new=$(tail -c +"$((capb0 + 1))" "$cap_b" | cat -v | head -c 120)
[[ $capb_new == *"[<0;"*M* && $capb_new == *k2* ]]
check "after the swap b3 takes the click at its real place and the keys" $? "b3 got '$capb_new'"

# 5b. a click without pointer motion after a swap reaches the window now under the cursor, never the strip window that was
# Hyprland's pointer focus (R13 review of 46b3e9b: it went to the hidden b3).
cx=$((mon_w / 2)) cy=$((mon_h / 2)) # inside b3 (front of the active stage b) and inside c3 (strip, front of stage c)
pointer abs "$cx" "$cy" sleep 200
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
sc=$(stage_of "$addr_c3")
a0=$(st_count '"active":'"$sc"',')
stages "{\"op\":\"activate\",\"stage\":$sc}"
wait_st '"active":'"$sc"',' "$a0" 2000
sw_rc=$?
sleep 1.2 # the 900 ms swap
pointer sleep 150 click sleep 300 # buttons only: no motion since the swap
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
[[ $sw_rc == 0 && -z $capb_new && $capc_new == *"[<0;"*M* ]]
check "5b click without motion after a swap: the window now under the cursor (c3) gets it, the strip window (b3) nothing" $? \
  "b3 got '$capb_new', c3 got '$capc_new'"

# 6. model operations (what the shell sends for drag and drop and grouping).
stages "$(on_json 0)"
sleep 0.3
stages "{\"op\":\"move\",\"address\":\"$addr_a2\",\"stage\":$(active_id)}"
sleep 0.4
in_active "$addr_a2"
check "move: a thumbnail dragged onto the stage (a2) joins the active stage" $? "stage of a2 $(stage_of "$addr_a2"), active $(active_id)"
n_before=$(stage_count)
stages "{\"op\":\"merge\",\"stage\":$(stage_of "$addr_a1")}"
sleep 0.4
in_active "$addr_a1" && in_active "$addr_a3" && (($(stage_count) == n_before - 1))
check "merge: the strip stage of a joins the active stage (grouped)" $? "stages $n_before -> $(stage_count)"
stages "{\"op\":\"move\",\"address\":\"$addr_a1\",\"stage\":\"new\"}"
sleep 0.4
[[ $(slot_id 0) == "$(stage_of "$addr_a1")" ]] && ! in_active "$addr_a1"
check "move to a new stage: a1 dragged off the stage becomes a strip stage of its own (tile 0)" $? "a1 in $(stage_of "$addr_a1"), tile0 $(slot_id 0)"
u0=$(st_count '"reason":"unknown"')
stages '{"op":"activate","stage":999999}'
sleep 0.3
(($(st_count '"reason":"unknown"') > u0))
check "activate an unknown stage: refused (unknown), nothing changes" $? "$(last_st | cut -c1-100)"

# 7. a new window opens a new active stage; closing it brings the previous stage back. b3 is focused first (its stage
# comes forward), so that the keyboard has a known place to come back to.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_b3\" })" >>"$log" 2>&1
sleep 0.4
prev_active=$(active_id)
pointer abs "$ring_x" "$ring_y" sleep 200 # resting on b3 (the ring point is b3's only), outside where d opens
cap_d=$run/capture-d.cap
p=$(foot_capture gf-stage-d "$cap_d"); pids+=("$p"); pid_d=$p
addr_d=$(address_of "$p")
sleep 0.8
in_active "$addr_d" && [[ $(slot_id 0) == "$prev_active" ]]
check "a new window of another app opens a new active stage; the previous one leads the strip" $? "d $addr_d, active $(active_id), tile0 $(slot_id 0)"
# 7b. a click without motion after the new window opened: b3 (strip now) gets nothing.
capb0=$(stat -c %s "$cap_b")
pointer sleep 150 click sleep 300
capb_new=$(cap_since "$cap_b" "$capb0")
[[ -n $addr_d && -z $capb_new ]]
check "7b click without motion after a new window opened: the strip window under the cursor (b3) gets nothing" $? \
  "b3 got '$capb_new'; d (not under the cursor) got '$(cat -v "$cap_d" | head -c 40)'"
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_d\" })" >>"$log" 2>&1 # the click may have reached the desktop
sleep 0.3
kill "$pid_d" 2>/dev/null
sleep 1
[[ $(active_id) == "$prev_active" ]]
check "closing it: the most recent strip stage becomes active again" $? "active $(active_id) (expected $prev_active)"
capb0=$(stat -c %s "$cap_b")
keys k3
sleep 0.4
capb_new=$(tail -c +"$((capb0 + 1))" "$cap_b" | cat -v | head -c 60)
[[ $capb_new == *k3* ]]
check "after the close the keyboard is back on the active stage's front window (b3)" $? "b3 got '$capb_new'"

# 8. focusing a strip window by dispatch (Dock, key binding, activation) brings its stage forward.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c2\" })" >>"$log" 2>&1
sleep 0.8
in_active "$addr_c2"
check "focus a strip window by dispatch: its stage (c) becomes active" $? "active $(active_id), stage of c2 $(stage_of "$addr_c2")"

# 8b. a swap made while an Exclusive layer holds the keyboard is kept when the layer closes, and the keyboard goes to the
# new stage's front window (R13 review of 46b3e9b: Hyprland restored its last window, a strip window by then, and that
# focus undid the swap). c3 holds the keyboard first, so the window Hyprland restores is a capture window.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1
sleep 0.4
start_exclusive
ex_rc=$?
keys x8
sleep 0.4
for _ in $(seq 1 40); do # Quickshell writes its log lines with a delay
  grep -q "\[stages-fixture\] key" "$exlog" && break
  sleep 0.05
done
ex_keys=$(grep -c "\[stages-fixture\] key" "$exlog")
sb=$(stage_of "$addr_b3")
a0=$(st_count '"active":'"$sb"',')
stages "{\"op\":\"activate\",\"stage\":$sb}"
wait_st '"active":'"$sb"',' "$a0" 2000
sw_rc=$?
sleep 0.6
stop_exclusive
sleep 1
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
keys k8
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
((ex_rc == 0 && sw_rc == 0 && ex_keys >= 1)) && [[ $(active_id) == "$sb" && $capb_new == *k8* && -z $capc_new ]]
check "8b swap while an Exclusive layer holds the keyboard: kept when the layer closes, the keys go to the new stage (b3)" $? \
  "layer got $ex_keys key line(s) while open; active $(active_id) (expected $sb); b3 got '$capb_new', c3 got '$capc_new'"

# 8c. window actions after a swap under an Exclusive layer never reach the strip window (R13 counter-review of 17208af:
# Hyprland's active window stayed on the outgoing window, hidden in the strip, and hl.dsp.window.close() closed it), and the
# plugin focuses nothing while the layer holds the keyboard (R13 counter-review #3 of e9ebc7f). Two disposable capture
# windows of new apps: g (newest, active, holds the keyboard) and f (tile 0). Under the layer, f's stage is activated:
# Hyprland's active window is not g (there is none: f takes the focus when the layer is gone), no activewindowv2 names g
# or f while the layer is up, the focused monitor does not change (with two outputs the pointer first goes to the other
# output, which Hyprland then focuses), the layer keeps the keys and the window dispatcher hl.dsp.window.close() closes no
# window; when the layer closes, f gets the keys and g nothing. R13 counter-review #4 of 0.6.3-stages (minor): clearing
# Hyprland's active window must recheck what Hyprland rechecks on a focus change; a window rule matching on focus (opacity
# 0.5 while focused, a test rule for these two apps only) leaves g when the plugin clears it.
nestctl dispatch 'hl.window_rule({ name = "gf-test-stages-focus", match = { class = "^gf-stage-[fg]$", focus = true }, opacity = "0.5" })' >>"$log" 2>&1
opacity_of() { nestctl getprop "address:$1" opacity 2>/dev/null | head -n 1; }
cap_f=$run/capture-f.cap cap_g=$run/capture-g.cap
p=$(foot_capture gf-stage-f "$cap_f"); pids+=("$p"); pid_f=$p
addr_f=$(address_of "$p")
sleep 0.6
p=$(foot_capture gf-stage-g "$cap_g"); pids+=("$p"); pid_g=$p
addr_g=$(address_of "$p")
sleep 0.8
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_g\" })" >>"$log" 2>&1
sleep 0.4
start_exclusive
ex_rc=$?
keys x9
sleep 0.4
if [[ -n $other_out ]]; then # the focused monitor becomes the other output (a pointer motion; the layer keeps the keyboard)
  timeout 20 "$root/scripts/dev/pointer.sh" output "$other_out" abs 40 40 sleep 100 >>"$log" 2>&1
  sleep 0.3
fi
mon0=$(focused_monitor)
sf=$(stage_of "$addr_f")
op_g0=$(opacity_of "$addr_g")
ev0=$(event_lines)
a0=$(st_count '"active":'"$sf"',')
stages "{\"op\":\"activate\",\"stage\":$sf}"
wait_st '"active":'"$sf"',' "$a0" 2000
sw_rc=$?
sleep 0.6
op_g1=$(opacity_of "$addr_g")
aw_swap=$(active_window)
mon1=$(focused_monitor)
g_strip=$(in_active "$addr_g" && echo no || echo yes)
capf0=$(stat -c %s "$cap_f"); capg0=$(stat -c %s "$cap_g")
keys uc
sleep 0.4
nestctl dispatch 'hl.dsp.window.close()' >>"$log" 2>&1
sleep 1
f_left=$(client_mapped "$addr_f" && echo yes || echo no)
g_left=$(client_mapped "$addr_g" && echo yes || echo no)
ex1=$(layer_got "$exlog" key uc)
capf_mid=$(cap_since "$cap_f" "$capf0"); capg_mid=$(cap_since "$cap_g" "$capg0")
focus_ev=$(events_since "$ev0" | grep -acE " activewindowv2>>($(hexof "$addr_g")|$(hexof "$addr_f"))$")
mon_ev=$(events_since "$ev0" | grep -ac ' focusedmon>>') # Hyprland's focused monitor changed (even for a moment)
stop_exclusive
sleep 1
capf1=$(stat -c %s "$cap_f")
keys k9
sleep 0.4
capf_new=$(cap_since "$cap_f" "$capf1"); capg_new=$(cap_since "$cap_g" "$capg0")
((ex_rc == 0 && sw_rc == 0 && ex1 >= 1 && focus_ev == 0 && mon_ev == 0)) && [[ $aw_swap != "$addr_g" && $g_strip == yes && $mon1 == "$mon0" && -z $capf_mid && -z $capg_mid ]]
check "8c swap under an Exclusive layer: Hyprland's active window is never the strip window (g), no window focus while the layer is up, the focused monitor stays, the layer keeps the keys" $? \
  "active window '$aw_swap' (f $addr_f, g $addr_g); g in the strip: $g_strip; activewindowv2 naming f or g under the layer: $focus_ev; focused monitor $mon0 -> $mon1, focusedmon events: $mon_ev; layer got $ex1 of the 2 keys; f got '$capf_mid', g got '$capg_mid'"
[[ $g_left == yes && $f_left == yes && $capf_new == *k9* && -z $capg_new ]] && in_active "$addr_f"
check "8c hl.dsp.window.close() under the layer closes no window (the strip window g survives); after the layer the new stage's front window (f) gets the keys" $? \
  "f mapped after close: $f_left, g mapped: $g_left; f got '$capf_new', g got '$capg_new'"
[[ $op_g0 == 0.5 && $op_g1 == 1 ]]
check "8c a window rule matching on focus is rechecked when the plugin clears the strip window g from Hyprland's active window" $? \
  "g's opacity (rule: 0.5 while focused) $op_g0 while active -> $op_g1 after the swap under the layer"
kill "$pid_g" "$pid_f" 2>/dev/null
sleep 0.8
pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 100 # back on $out

# 8f. an Exclusive layer, a special workspace and a swap (R13 counter-review #3 of e9ebc7f, reproduced: the plugin's focus
# closed the special workspace and the next keys went to the swap's window instead of the layer). A capture window s on a
# special workspace holds the keyboard (b active, c3 in the strip), the layer takes the keyboard, c's stage is activated:
# the layer gets the keys, no window gets one, the special workspace stays open and no window focus happens while the layer
# is up. After the layer, Hyprland's restore (s) keeps the keyboard and the special workspace stays open (nothing is closed
# after the fact); closing the special workspace then gives the keyboard to the activated stage's front window (c3), never
# to the strip window (b3).
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_b3\" })" >>"$log" 2>&1
sleep 0.5
cap_s=$run/capture-s.cap
p=$(foot_capture gf-stage-s "$cap_s"); pids+=("$p"); pid_s=$p
addr_s=$(address_of "$p")
sleep 0.5
nestctl dispatch "hl.dsp.window.move({ workspace = \"special:gf-st\", follow = false, window = \"address:$addr_s\" })" >>"$log" 2>&1
sleep 0.4
nestctl dispatch 'hl.dsp.workspace.toggle_special("gf-st")' >>"$log" 2>&1
sleep 0.6
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_s\" })" >>"$log" 2>&1
sleep 0.4
sp0=$(special_of)
sc=$(stage_of "$addr_c3")
start_exclusive
ex_rc=$?
keys x1
sleep 0.4
mon0=$(focused_monitor)
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c"); caps0=$(stat -c %s "$cap_s")
ev0=$(event_lines)
a0=$(st_count '"active":'"$sc"',')
stages "{\"op\":\"activate\",\"stage\":$sc}"
wait_st '"active":'"$sc"',' "$a0" 2000
sw_rc=$?
sleep 0.6
keys vq
sleep 0.4
ex1=$(layer_got "$exlog" key vq)
sp1=$(special_of); mon1=$(focused_monitor)
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0"); caps_new=$(cap_since "$cap_s" "$caps0")
focus_ev=$(events_since "$ev0" | grep -acE ' (activewindowv2>>[0-9a-f]+|focusedmon>>.*)$')
((ex_rc == 0 && sw_rc == 0 && ex1 >= 1 && focus_ev == 0)) && [[ $sp0 == special:gf-st && $sp1 == special:gf-st && $mon1 == "$mon0" && -z $capb_new && -z $capc_new && -z $caps_new ]] \
  && in_active "$addr_c3"
check "8f Exclusive layer + special workspace + activate: the layer keeps every key, the special workspace stays open, no window focus" $? \
  "special $sp0 -> $sp1; layer got $ex1 of the 2 keys; window or monitor focus events under the layer: $focus_ev; focused monitor $mon0 -> $mon1; b3 got '$capb_new', c3 got '$capc_new', s got '$caps_new'"
stop_exclusive
sleep 1
sp2=$(special_of)
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c"); caps0=$(stat -c %s "$cap_s")
keys k6
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0"); caps_new=$(cap_since "$cap_s" "$caps0")
[[ $sp2 == special:gf-st && $caps_new == *k6* && -z $capc_new && -z $capb_new ]]
check "8f after the layer: the special workspace stays open and its window (Hyprland's restore) gets the keys" $? \
  "special $sp2; s got '$caps_new', c3 got '$capc_new', b3 got '$capb_new'"
nestctl dispatch 'hl.dsp.workspace.toggle_special("gf-st")' >>"$log" 2>&1
sleep 1
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
keys k7
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
[[ -z $(special_of) && $capc_new == *k7* && -z $capb_new ]] && in_active "$addr_c3"
check "8f the special workspace closed: the activated stage's front window (c3) gets the keys, the strip window (b3) nothing" $? \
  "special '$(special_of)'; c3 got '$capc_new', b3 got '$capb_new'"
kill "$pid_s" 2>/dev/null
sleep 0.6

# 8g. a stage of a Desktop that is not shown, activated under an Exclusive layer (R13 counter-review #3 of e9ebc7f: the
# keyboard went to that window for a moment while Hyprland switched Desktops under the layer). b3 holds the keyboard (b
# active, c3 in the strip), the layer takes it, Desktop 9 is shown under the layer, then c's stage is activated: the
# Desktop shown stays 9, no Desktop switch and no window focus happen while the layer is up, the focused monitor stays,
# the layer gets the keys and no window one. After the layer, back on the Desktop, c3 (its active stage's front window)
# gets the keys and b3 nothing.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_b3\" })" >>"$log" 2>&1
sleep 0.5
ws_g=$(shown_ws)
sc=$(stage_of "$addr_c3") # read while the Desktop is shown (the event describes the shown Desktop)
start_exclusive
ex_rc=$?
keys x2
sleep 0.4
nestctl dispatch 'hl.dsp.focus({ workspace = "9" })' >>"$log" 2>&1
sleep 0.8
ws9=$(shown_ws)
mon0=$(focused_monitor)
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
ev0=$(event_lines)
stages "{\"op\":\"activate\",\"stage\":$sc}"
sleep 1
keys wr
sleep 0.4
ex1=$(layer_got "$exlog" key wr)
ws1=$(shown_ws); mon1=$(focused_monitor)
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
moves=$(events_since "$ev0" | grep -acE ' (workspace|workspacev2|focusedmon|focusedmonv2)>>| activewindowv2>>[0-9a-f]+$')
((ex_rc == 0 && ex1 >= 1 && moves == 0)) && [[ $ws9 == 9 && $ws1 == 9 && $mon1 == "$mon0" && -z $capb_new && -z $capc_new ]]
check "8g a stage of a Desktop not shown activated under an Exclusive layer: no Desktop switch, no window focus, the layer keeps every key" $? \
  "Desktop $ws_g -> $ws9 -> $ws1; focus or Desktop events under the layer: $moves; focused monitor $mon0 -> $mon1; layer got $ex1 of the 2 keys; b3 got '$capb_new', c3 got '$capc_new'"
stop_exclusive
sleep 0.8
nestctl dispatch "hl.dsp.focus({ workspace = \"$ws_g\" })" >>"$log" 2>&1
sleep 1
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
keys k5
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
[[ $(shown_ws) == "$ws_g" && $capc_new == *k5* && -z $capb_new ]] && in_active "$addr_c3"
check "8g after the layer, back on the Desktop: the activated stage's front window (c3) gets the keys, b3 nothing" $? \
  "Desktop $(shown_ws); c3 got '$capc_new', b3 got '$capb_new'; active stage $(active_id), stage of c3 $(stage_of "$addr_c3")"

# 8h. a polkit-like dialog (stages-fixture role polkit: a full-output Overlay surface with Exclusive keyboard interactivity
# and a password field, as shell/security/polkit/AuthAgent.qml) is up while a stage is activated: every key goes to its
# field, none to a window, Hyprland's active window is never the strip window; when the dialog ends as the real one does
# (keyboard interactivity None, then unmapped), the activated stage's front window gets the keys.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_b3\" })" >>"$log" 2>&1
sleep 0.5
sc=$(stage_of "$addr_c3")
start_polkit
pk_rc=$?
keys pw
sleep 0.4
mon0=$(focused_monitor)
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
ev0=$(event_lines)
a0=$(st_count '"active":'"$sc"',')
stages "{\"op\":\"activate\",\"stage\":$sc}"
wait_st '"active":'"$sc"',' "$a0" 2000
sw_rc=$?
sleep 0.6
aw=$(active_window)
keys secret
sleep 0.4
pk1=$(layer_got "$pklog" "polkit key" secrt)
mon1=$(focused_monitor)
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
focus_ev=$(events_since "$ev0" | grep -acE ' (activewindowv2>>[0-9a-f]+|focusedmon>>.*)$')
((pk_rc == 0 && sw_rc == 0 && pk1 >= 5 && focus_ev == 0)) && [[ $aw != "$addr_b3" && $mon1 == "$mon0" && -z $capb_new && -z $capc_new ]]
check "8h polkit-like dialog: a stage activated under it, every key goes to its password field, none to a window; the active window is never the strip window" $? \
  "field got $pk1 of the 6 keys; active window '$aw' (b3 $addr_b3); window or monitor focus events under the dialog: $focus_ev; focused monitor $mon0 -> $mon1; b3 got '$capb_new', c3 got '$capc_new'"
keys -k Escape
wait_log "$pklog" "polkit hidden" 40
sleep 0.8
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
keys k4
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
grep -q "\[stages-fixture\] polkit released" "$pklog" && [[ $capc_new == *k4* && -z $capb_new ]] && in_active "$addr_c3"
check "8h the dialog ends (keyboard None, then unmapped): the activated stage's front window (c3) gets the keys, b3 nothing" $? \
  "c3 got '$capc_new', b3 got '$capb_new'"
stop_polkit
sleep 0.6

# 8i. Hyprland's refocus at the cursor when the layer goes away is not a click (R13 counter-review #4 of 0.6.3-stages:
# Hyprland reports it as CLICK and the plugin counted it as the user's choice, so the window under the pointer took the
# keyboard from the swap's front window). After a swap under an Exclusive layer the swapped-in front window gets the keys
# with the pointer over (a) an unrelated tiled window u, (b) the swapped-in stage's back window h1 (a stage of h1, 1200x900,
# and h2, 600x400 in front), (c) empty desktop; (d) when that front window closes under the layer, the window now in front
# of its stage gets them (macOS: the frontmost app's key window); (e) a real click wins: on another window beside the layer
# while it is up, or just after the layer went away. While the layer holds the keyboard after the swap Hyprland has no
# active window and the Stages event names the front window and its app (what the menu bar keeps showing).
cap_u=$run/capture-u.cap cap_h1=$run/capture-h1.cap cap_h2=$run/capture-h2.cap
p=$(foot_capture gf-stage-u "$cap_u"); pids+=("$p"); pid_u=$p
addr_u=$(address_of "$p")
sleep 0.6
nestctl dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$addr_u\" })" >>"$log" 2>&1 # tiled: Stages leaves it alone
sleep 0.6
p=$(foot_capture gf-stage-h "$cap_h1" --window-size-pixels=1200x900); pids+=("$p"); pid_h1=$p
addr_h1=$(address_of "$p")
sleep 0.6
p=$(foot_capture gf-stage-h "$cap_h2" --window-size-pixels=600x400); pids+=("$p"); pid_h2=$p
addr_h2=$(address_of "$p")
sleep 0.8
u_tiled=$(nestctl -j clients | jq -r --arg a "$addr_u" '.[] | select(.address == $a) | .floating | not')
say "8i: u $addr_u (tiled: $u_tiled), h1 $addr_h1 (back), h2 $addr_h2 (front)"
# Points (on $out): on u only (right of every floating window, below the layer), on h1 only (inside h1, outside h2; the
# other stages' windows there are in the strip, which Hyprland's hit test skips), empty desktop once u is closed.
u_x=$((mon_w - 100)) u_y=$((mon_h / 2))
h1_x=$((mon_w / 2 + 450)) h1_y=$((mon_h / 2))
caps_reset() { capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c"); capu0=$(stat -c %s "$cap_u"); caph10=$(stat -c %s "$cap_h1"); caph20=$(stat -c %s "$cap_h2"); }
caps_read() { capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0"); capu_new=$(cap_since "$cap_u" "$capu0"); caph1_new=$(cap_since "$cap_h1" "$caph10"); caph2_new=$(cap_since "$cap_h2" "$caph20"); }
swap_under_layer() { # <stage id>: activated while the Exclusive layer is up
  local a0
  a0=$(st_count '"active":'"$1"',')
  stages "{\"op\":\"activate\",\"stage\":$1}"
  wait_st '"active":'"$1"',' "$a0" 2000
}

# (a) the pointer on the unrelated tiled window u.
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1
sleep 0.5
sb=$(stage_of "$addr_b3")
start_exclusive
ex_rc=$?
pointer abs "$u_x" "$u_y" sleep 150
swap_under_layer "$sb"
sw_rc=$?
sleep 0.6
aw_a=$(active_window)
front_a=$(last_st | jq -r '.monitors[0].front.address // ""'); app_a=$(last_st | jq -r '.monitors[0].front.app // ""')
stop_exclusive
sleep 1
caps_reset
keys ia
sleep 0.4
caps_read
((ex_rc == 0 && sw_rc == 0)) && [[ $u_tiled == true && $capb_new == *ia* && -z $capu_new && -z $capc_new ]]
check "8i(a) pointer on an unrelated tiled window when the layer closes: the swapped-in front window (b3) gets the keys, the window under the pointer (u) nothing" $? \
  "b3 got '$capb_new', u got '$capu_new', c3 got '$capc_new'"
[[ -z $aw_a && $front_a == "$(hexof "$addr_b3")" && $app_a == gf-stage-b ]]
check "8i(a) under the layer after the swap: no active window in Hyprland, the Stages event names the front window and app (b3, gf-stage-b)" $? \
  "active window '$aw_a'; event front '$front_a' app '$app_a' (b3 $addr_b3)"

# (b) the pointer on the swapped-in stage's back window h1 (b3, Hyprland's active window, goes to the strip; h's stage is
# activated).
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_b3\" })" >>"$log" 2>&1
sleep 0.5
sh=$(stage_of "$addr_h2")
start_exclusive
ex_rc=$?
pointer abs "$h1_x" "$h1_y" sleep 150
swap_under_layer "$sh"
sw_rc=$?
sleep 0.6
stop_exclusive
sleep 1
caps_reset
keys ib
sleep 0.4
caps_read
aw_b=$(active_window)
((ex_rc == 0 && sw_rc == 0)) && [[ $caph2_new == *ib* && -z $caph1_new && -z $capb_new && $aw_b == "$addr_h2" ]] && in_active "$addr_h2"
check "8i(b) pointer on the swapped-in stage's back window when the layer closes: its front window (h2) gets the keys, the back window (h1) nothing" $? \
  "h2 got '$caph2_new', h1 got '$caph1_new', b3 got '$capb_new'; active window $aw_b (h2 $addr_h2)"

# (e1) a real click beside the layer while it is up, on u: when the layer goes away, u keeps the keyboard (the click came
# after the swap and wins over it).
sc=$(stage_of "$addr_c3")
start_exclusive
ex_rc=$?
swap_under_layer "$sc"
sw_rc=$?
sleep 0.6
pointer abs "$u_x" "$u_y" sleep 150 abs $((u_x + 1)) "$u_y" sleep 100 click sleep 200
ex_still=$( [[ -n $exclusive_pid ]] && kill -0 "$exclusive_pid" 2>/dev/null && echo yes || echo no)
stop_exclusive
sleep 1
caps_reset
keys ic
sleep 0.4
caps_read
((ex_rc == 0 && sw_rc == 0)) && [[ $ex_still == yes && $capu_new == *ic* && -z $capc_new && -z $caph2_new ]]
check "8i(e) a click on another window (u) beside the layer while it is up wins: u gets the keys after the layer, not the swapped-in front window (c3)" $? \
  "layer up at the click: $ex_still; u got '$capu_new', c3 got '$capc_new', h2 got '$caph2_new'"

# (e2) a click just after the layer went away: the swapped-in front window (h2) took the keyboard (the pointer still on
# u), and the click on u then gives it to u.
start_exclusive
ex_rc=$?
swap_under_layer "$sh"
sw_rc=$?
sleep 0.6
stop_exclusive
sleep 0.4
aw_e=$(active_window)
pointer abs $((u_x - 1)) "$u_y" sleep 100 click sleep 300
caps_reset
keys id
sleep 0.4
caps_read
((ex_rc == 0 && sw_rc == 0)) && [[ $aw_e == "$addr_h2" && $capu_new == *id* && -z $caph2_new ]]
check "8i(e) a click on u just after the layer: before it the swapped-in front window (h2) is active, the click gives u the keys" $? \
  "active window after the layer $aw_e (h2 $addr_h2); u got '$capu_new', h2 got '$caph2_new'"

# (c) empty desktop under the pointer (u closed).
kill "$pid_u" 2>/dev/null
sleep 0.8
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_h2\" })" >>"$log" 2>&1
sleep 0.5
start_exclusive
ex_rc=$?
pointer abs "$u_x" "$u_y" sleep 150
swap_under_layer "$sc"
sw_rc=$?
sleep 0.6
stop_exclusive
sleep 1
caps_reset
keys ie
sleep 0.4
caps_read
((ex_rc == 0 && sw_rc == 0)) && [[ $capc_new == *ie* && -z $caph2_new ]]
check "8i(c) pointer on empty desktop when the layer closes: the swapped-in front window (c3) gets the keys" $? \
  "c3 got '$capc_new', h2 got '$caph2_new'"

# (d) the remembered front window closes while the layer is up (the pointer on empty desktop): the window now in front of
# that stage (h1) gets the keys, nothing is left without the keyboard.
start_exclusive
ex_rc=$?
swap_under_layer "$sh"
sw_rc=$?
sleep 0.6
kill "$pid_h2" 2>/dev/null
sleep 0.8
h2_gone=$(client_mapped "$addr_h2" && echo no || echo yes)
stop_exclusive
sleep 1
caps_reset
keys if
sleep 0.4
caps_read
aw_d=$(active_window)
((ex_rc == 0 && sw_rc == 0)) && [[ $h2_gone == yes && $caph1_new == *if* && $aw_d == "$addr_h1" && -z $capc_new ]]
check "8i(d) the remembered front window closed under the layer: its stage's window now in front (h1) gets the keys" $? \
  "h2 closed: $h2_gone; h1 got '$caph1_new', c3 got '$capc_new'; active window $aw_d (h1 $addr_h1)"
kill "$pid_h1" 2>/dev/null
sleep 0.8
pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 100

# 8j. a keyboard device appears while an Exclusive layer holds the keyboard after a swap (integrator decision 2026-10-24,
# macOS: a modal system prompt always gets the keyboard; wlr-layer-shell: an Exclusive Top or Overlay surface gets every
# key). c3 holds the keyboard, the layer takes it, b's stage is activated (c3 goes to the strip). Then a new keyboard
# device (tests/tools/vkbd) appears and types j k, and while it is still there another one (keys.sh) types l m: the layer
# gets the four keys, no window one. Then a Top-layer surface that takes the keyboard on demand (a clickable banner, the
# fixture's role ondemand) maps while the layer is still up: Hyprland 0.56.2 gives it the keyboard when it maps (its log:
# "Set keyboard focus" to the banner), and with the keyboard moved back only when a key arrived the client lost that key
# (9169ad4: "layer got 1 of the 2 keys" in 3 runs of 3). The layer gets both keys (o p), the banner none. When the layer
# is gone the swapped-in front window (b3) gets every key, c3 nothing.
vkbd() { timeout 20 "$root/tests/tools/vkbd/vkbd.sh" "$@" >>"$log" 2>&1; }
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1
sleep 0.5
sb=$(stage_of "$addr_b3")
start_exclusive
ex_rc=$?
keys x3
sleep 0.4
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
a0=$(st_count '"active":'"$sb"',')
stages "{\"op\":\"activate\",\"stage\":$sb}"
wait_st '"active":'"$sb"',' "$a0" 2000
sw_rc=$?
sleep 0.6
vkbd sleep 400 tap j tap k sleep 2600 &
vkbd_pid=$!
sleep 1.4
keys lm
sleep 0.4
ex1=$(layer_got "$exlog" key jklm)
capb_mid=$(cap_since "$cap_b" "$capb0"); capc_mid=$(cap_since "$cap_c" "$capc0")
wait "$vkbd_pid" 2>/dev/null
((ex_rc == 0 && sw_rc == 0 && ex1 >= 4)) && [[ -z $capb_mid && -z $capc_mid ]]
check "8j a keyboard device appears under the Exclusive layer after a swap: the layer gets every key of it and of the next one, no window one" $? \
  "layer got $ex1 of the 4 keys (j k from the new device, l m from the next); b3 got '$capb_mid', c3 got '$capc_mid'"
start_ondemand
od_rc=$?
keys op
sleep 0.4
ex2=$(layer_got "$exlog" key op)
od_keys=$(grep -c "\[stages-fixture\] ondemand key" "$odlog")
((od_rc == 0 && ex2 >= 2 && od_keys == 0))
check "8j a surface that takes the keyboard on demand maps over the Exclusive layer: the layer keeps every key, the banner none" $? \
  "banner shown: $((od_rc == 0)); layer got $ex2 of the 2 keys; banner got $od_keys"
stop_ondemand
sleep 0.4
stop_exclusive
sleep 1
capb0=$(stat -c %s "$cap_b"); capc0=$(stat -c %s "$cap_c")
keys n8
sleep 0.4
capb_new=$(cap_since "$cap_b" "$capb0"); capc_new=$(cap_since "$cap_c" "$capc0")
[[ $capb_new == *n8* && -z $capc_new ]] && in_active "$addr_b3"
check "8j after the layer: the swapped-in front window (b3) gets every key, c3 nothing" $? "b3 got '$capb_new', c3 got '$capc_new'"

# 8d. a menu (xdg_popup with a grab) of the active stage's window keeps its keys; when that window goes to the strip its
# menu closes at once, as a click outside it would, and every key goes to the new stage (R13 counter-review of 17208af:
# Hyprland 0.56.2 keeps the keyboard on the toplevel during a popup grab and refused the new window the keyboard; the
# first key cleared the focus, the app closed its menu, 1-2 keys were lost).
start_popup_app
pp_rc=$?
addr_p=$(address_of "$popup_pid")
sleep 1.2 # Quickshell's first frames (a click before them can be missed)
read -r ppx ppy ppw pph < <(jq -r '.[] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' <<<"$(clients_of "$addr_p")")
open_menu() { # clicks inside the window, outside where its menu opens, until one more "menu open" line (at most 3 tries)
  local before i
  before=$(grep -c "\[stages-fixture\] menu open" "$popuplog")
  for i in 1 2 3; do # two motions: see the press on a thumbnail (4.)
    pointer abs $((ppx + ppw - 60 - mon_x)) $((ppy + pph - 60 - mon_y)) sleep 200 abs $((ppx + ppw - 59 - mon_x)) $((ppy + pph - 60 - mon_y)) sleep 100 click sleep 300
    for _ in $(seq 1 20); do
      (($(grep -c "\[stages-fixture\] menu open" "$popuplog") > before)) && return 0
      sleep 0.05
    done
  done
  return 1
}
open_menu
keys p1
sleep 0.4
wait_log "$popuplog" "menu key" 40
menu_keys=$(grep -c "\[stages-fixture\] menu key" "$popuplog")
app_keys=$(grep -c "\[stages-fixture\] app key" "$popuplog")
# The nested session's keyboard device goes away after each keys.sh run and Qt then closes the menu (a real keyboard
# stays): the menu is opened again for the swap.
sleep 0.4
reopen_rc=0
if grep -q "\[stages-fixture\] menu closed" "$popuplog"; then
  open_menu
  reopen_rc=$?
fi
pl0=$(grep -c "" "$popuplog")
sb=$(stage_of "$addr_b3")
a0=$(st_count '"active":'"$sb"',')
stages "{\"op\":\"activate\",\"stage\":$sb}"
wait_st '"active":'"$sb"',' "$a0" 2000
sw_rc=$?
wait_log "$popuplog" "menu closed" 40
sleep 0.2
closed_before_keys=$(tail -n +"$((pl0 + 1))" "$popuplog" | grep -c "\[stages-fixture\] menu closed")
pl1=$(grep -c "" "$popuplog")
capb0=$(stat -c %s "$cap_b")
keys q2
sleep 0.6
capb_new=$(cap_since "$cap_b" "$capb0")
p_keys=$(tail -n +"$((pl1 + 1))" "$popuplog" | grep -c "\[stages-fixture\] \(menu\|app\) key")
# Qt can drop the first key after a new virtual keyboard (its keyboard capability comes back with it): one menu key line
# shows that the keys reach the menu.
((pp_rc == 0 && menu_keys >= 1 && app_keys == 0))
check "8d a menu of the active stage's window gets its keys" $? "app $addr_p: $menu_keys menu key line(s), $app_keys app key line(s)"
((sw_rc == 0 && reopen_rc == 0 && closed_before_keys >= 1 && p_keys == 0)) && [[ $capb_new == *q2* ]] && ! in_active "$addr_p"
check "8d its window goes to the strip: the menu closes before any key, every key goes to the new stage (b3), none to the strip window" $? \
  "menu reopened for the swap: rc $reopen_rc; closed before the keys: $closed_before_keys; b3 got '$capb_new'; app and menu key lines after the swap: $p_keys"
stop_popup_app
sleep 0.8

# 8e. focus reasons: a request for a strip window on a Desktop that is not shown (Hyprland switches to that Desktop and
# focuses the window with reason WORKSPACE_CHANGE) still brings its stage forward; a plain Desktop switch back restores the
# Desktop's last window and keeps the active stage (R13 counter-review of 17208af: Hyprland's own picks counted as user
# choices). a1 then c3 are focused, so a1 is the previous window in Hyprland's focus history.
ws_8e=$(last_st | jq -r '.monitors[0].workspace')
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_a1\" })" >>"$log" 2>&1
sleep 0.5
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1
sleep 0.5
nestctl dispatch 'hl.dsp.focus({ workspace = "9" })' >>"$log" 2>&1
sleep 0.6
nestctl dispatch 'hl.dsp.focus({ last = true })' >>"$log" 2>&1
sleep 0.8
ws_back=$(nestctl -j activeworkspace | jq -r '.id')
aw_last=$(active_window)
[[ $ws_back == "$ws_8e" && $aw_last == "$addr_a1" ]] && in_active "$addr_a1"
check "8e focus { last } of a strip window on another Desktop (WORKSPACE_CHANGE): its stage comes forward" $? \
  "Desktop $ws_back (expected $ws_8e), active window $aw_last (a1 $addr_a1), active stage $(active_id), stage of a1 $(stage_of "$addr_a1")"
act_8e=$(active_id)
nestctl dispatch 'hl.dsp.focus({ workspace = "9" })' >>"$log" 2>&1
sleep 0.6
nestctl dispatch "hl.dsp.focus({ workspace = \"$ws_8e\" })" >>"$log" 2>&1
sleep 0.8
[[ $(active_id) == "$act_8e" && $(active_window) == "$addr_a1" ]]
check "8e a Desktop switch away and back keeps the active stage and its window" $? "active stage $(active_id) (was $act_8e), active window $(active_window)"

# 9. hidden strip: thumbnails slide out of the monitor; shown again.
stages "$(on_json 0 true)"
sleep 0.5
shot hidden
h0=$(grey_share "$run/hidden.png" 0); h1=$(grey_share "$run/hidden.png" 1)
stages "$(on_json 0 false)"
sleep 0.5
shot shown
s0=$(grey_share "$run/shown.png" 0)
((h0 <= 2 && h1 <= 2 && s0 >= 25)) && [[ $(last_st | jq -r '.monitors[0].hidden') == false ]]
check "hidden strip: no thumbnail in the tiles; shown again: thumbnails back" $? "hidden tile0 $h0 % tile1 $h1 %, shown tile0 $s0 %"

# 9b. a workspace switch: the other workspace shows no stage; back, the same stages with their thumbnails in the tiles
# (the windows of a workspace that is not shown keep how they are drawn).
ws_now=$(last_st | jq -r '.monitors[0].workspace')
ids_before=$(last_st | jq -c '[.monitors[0].stages[].id]')
nestctl dispatch 'hl.dsp.focus({ workspace = "9" })' >>"$log" 2>&1
sleep 0.8
other_ws=$(last_st | jq -r '.monitors[0].workspace'); other_n=$(stage_count)
nestctl dispatch "hl.dsp.focus({ workspace = \"$ws_now\" })" >>"$log" 2>&1
sleep 0.8
shot workspace-back
wb0=$(grey_share "$run/workspace-back.png" 0)
ids_after=$(last_st | jq -c '[.monitors[0].stages[].id]')
[[ $other_ws == 9 && $other_n == 0 && $ids_after == "$ids_before" ]] && ((wb0 >= 25))
check "workspace switch: no stage on workspace 9; back on $ws_now the same stages, thumbnails in the tiles" $? \
  "workspace 9: $other_n stage(s); back: $ids_after (before $ids_before), tile0 grey $wb0 %"

# 10. minimize / restore (the plugin's verbs, no Dock rectangle): the window leaves Stages, then rejoins the active stage.
front=$(last_st | jq -r '.monitors[0] as $m | [$m.stages[] | select(.id == $m.active)][0].windows[-1].address')
nestctl dispatch "hl.plugin.grassfield.minimize(\"0x$front\", 0, 0, 0, 0)" >>"$log" 2>&1
sleep 0.8
gone=$(last_st | jq -r --arg a "$front" '[.monitors[0].stages[].windows[].address] | index($a) == null')
ws_min=$(nestctl -j clients | jq -r --arg a "0x$front" '.[] | select(.address == $a) | .workspace.name')
nestctl dispatch "hl.plugin.grassfield.restore(\"0x$front\", 0, 0, 0, 0)" >>"$log" 2>&1
sleep 0.8
[[ $gone == true && $ws_min == special:minimized ]] && in_active "0x$front"
check "minimize: the window leaves its stage (special:minimized); restore: it is back in the active stage" $? "0x$front: gone $gone ($ws_min), active after restore $(in_active "0x$front" && echo yes || echo no)"

# 11. full screen on the active stage: the strip is hidden while it is shown.
nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:0x$front\" })" >>"$log" 2>&1
sleep 0.8
shot fullscreen
f0=$(grey_share "$run/fullscreen.png" 0)
nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:0x$front\" })" >>"$log" 2>&1
sleep 0.8
shot fullscreen-off
f1=$(grey_share "$run/fullscreen-off.png" 0)
fs_after=$(nestctl -j clients | jq -r --arg a "0x$front" '.[] | select(.address == $a) | .fullscreen')
((f1 >= 25)) && [[ $fs_after == 0 || $fs_after == false ]]
check "full screen: the strip comes back after leaving full screen" $? "tile0 grey while full screen $f0 % (Hyprland draws only the full-screen window), after $f1 %"

# 12. overlap: an active window dragged by its titlebar over the strip band is reported (the shell then hides the strip),
# and dragged back.
stages "{\"op\":\"activate\",\"stage\":$(stage_of "$addr_b3")}"
sleep 0.6
read -r bx by bw bh < <(jq -r '.[] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' <<<"$(clients_of "$addr_b3")")
gx=$((bx + bw / 2 - mon_x)) gy=$((by - GF_TB_MID - mon_y)) # on b3's titlebar (GF_TB_HEIGHT above its surface), clear of the 700x500 windows
pointer abs "$gx" "$gy" sleep 150 down drag $((gx - 420)) "$gy" sleep 100 up
sleep 1
ov1=$(last_st | jq -r '.monitors[0].overlap')
moved=$(jq -r '.[0].at[0]' <<<"$(clients_of "$addr_b3")")
pointer abs $((gx - 420)) "$gy" sleep 150 down drag "$gx" "$gy" sleep 100 up
sleep 1
ov2=$(last_st | jq -r '.monitors[0].overlap')
back=$(jq -r '.[0].at[0]' <<<"$(clients_of "$addr_b3")")
[[ $ov1 == true && $ov2 == false && $back == "$bx" ]]
check "overlap: an active window dragged over the strip band is reported, and its end too" $? "overlap $ov1 -> $ov2 (b3 x $bx -> $moved -> $back)"
before_clients=$(clients_of "$all") # the reference for the rest of the run (positions after the drags)

# 12b. minimizing the only window of the active stage: the most recent strip stage comes forward and its front window takes
# the keyboard; no key reaches the minimized window (R13 review of 46b3e9b: the keys went to it on special:minimized).
cap_e=$run/capture-e.cap
p=$(foot_capture gf-stage-e "$cap_e"); pids+=("$p"); pid_e=$p
addr_e=$(address_of "$p")
sleep 0.8
# A key first: the nested session has no keyboard device between keys.sh runs, so Hyprland's seat focus can lag behind its
# focus surface (each new virtual keyboard gets the focus surface); with a real keyboard both always agree.
keys e0
sleep 0.3
next=$(slot_id 0)
next_front=$(last_st | jq -r --argjson s "$(num "$next")" '[.monitors[0].stages[] | select(.id == $s)][0].windows[-1].address // ""')
e_alone=$(last_st | jq -r --arg a "$(hexof "$addr_e")" '.monitors[0] as $m | [$m.stages[] | select(.id == $m.active)][0].windows | map(.address) == [$a]')
nestctl dispatch "hl.plugin.grassfield.minimize(\"$addr_e\", 0, 0, 0, 0)" >>"$log" 2>&1
sleep 0.8
ws_e=$(nestctl -j clients | jq -r --arg a "$addr_e" '.[] | select(.address == $a) | .workspace.name')
aw=$(active_window)
cape0=$(stat -c %s "$cap_e"); capb0=$(stat -c %s "$cap_b")
keys m2
sleep 0.4
cape_new=$(cap_since "$cap_e" "$cape0"); capb_new=$(cap_since "$cap_b" "$capb0")
[[ -n $addr_e && $e_alone == true && $ws_e == special:minimized && $aw == "0x$next_front" && $(active_id) == "$next" && -z $cape_new ]] \
  && { [[ $next_front != "$(hexof "$addr_b3")" ]] || [[ $capb_new == *m2* ]]; }
check "12b minimize the only window of the active stage: the next stage's front window gets the keys, the minimized one nothing" $? \
  "e alone in its stage: $e_alone, e on $ws_e; active window $aw (expected 0x$next_front), active stage $(active_id) (expected $next); e got '$cape_new', b3 got '$capb_new'"
kill "$pid_e" 2>/dev/null
sleep 0.5

# 12c. Hyprland's window cycling (ALT+TAB runs cycle_next, a window cycler, until the Grassfield app switcher exists)
# stays within the active stage: it never reaches a strip window (input-blocked: Hyprland's cycle skips it) and never
# changes the stages (docs/specs/stages.md ST10: app activation, not window cycling, brings a stage forward).
ids0=$(last_st | jq -c '[.monitors[0].stages[].id]')
act0=$(active_id)
cyc_bad=0 visited=""
for _ in 1 2 3 4; do
  nestctl dispatch 'hl.dsp.window.cycle_next()' >>"$log" 2>&1
  sleep 0.4
  aw=$(active_window)
  visited+="$aw "
  in_active "$aw" || cyc_bad=$((cyc_bad + 1))
done
distinct=$(tr ' ' '\n' <<<"$visited" | sort -u | grep -c .)
((cyc_bad == 0 && distinct >= 2)) && [[ $(active_id) == "$act0" && $(last_st | jq -c '[.monitors[0].stages[].id]') == "$ids0" ]]
check "12c cycle_next stays within the active stage (never a strip window, stages unchanged)" $? \
  "visited $visited($distinct distinct, $cyc_bad outside the active stage); active $(active_id) (was $act0)"

# 13. failsafe: the strip surface going away shows every window normally at once; then Stages resumes.
i0=$(st_count '"reason":"interrupted"')
stop_fixture
wait_st '"reason":"interrupted"' "$i0" 2000
fs_rc=$?
sleep 0.6
shot strip-gone
sg0=$(grey_share "$run/strip-gone.png" 0)
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1 # b3 below c3 now: the ring point is still b3's only
sleep 0.3
capb0=$(stat -c %s "$cap_b")
pointer abs "$ring_x" "$ring_y" sleep 150 click sleep 200
capb_new=$(tail -c +"$((capb0 + 1))" "$cap_b" | cat -v | head -c 60)
((fs_rc == 0 && sg0 <= 2)) && [[ $capb_new == *"[<0;"*M* ]]
check "strip surface gone: interrupted, no thumbnail, every window takes input at its place" $? "tile0 $sg0 %, b3 got '$capb_new'"
start_fixture >/dev/null
o_back=$(st_count '"on":true')
stages "$(on_json 0)"
wait_st '"on":true' "$o_back" 2000 # a fresh event, newer than the request: the latest one alone could be an old one
back_rc=$?
sleep 0.6
((back_rc == 0 && $(stage_count) >= 2)) && [[ $(last_st | jq -r '.on') == true ]]
check "op on again after the strip came back: Stages resumes with its stages" $? "$(stage_count) stages"

# 14. invalid payloads and a flood.
v0=$(st_count '"reason":"invalid"')
for bad in '{"op":"dance"}' '{"op":"on","durationMs":350}' '{"op":"activate","stage":0}' 'not json' '{"op":"move","address":"0xzz","stage":1}'; do
  stages "$bad"
done
nestctl dispatch 'hl.plugin.grassfield.stages(42)' >>"$log" 2>&1
sleep 0.5
(($(st_count '"reason":"invalid"') > v0)) && [[ $(last_st | jq -r '.on') == true ]]
check "invalid payloads refused (invalid), Stages unchanged" $? "$(last_st | cut -c1-100)"
f0=$(st_events | wc -l)
aw0=$(grep -ac "activewindowv2>>" "$events")
flood_log0=$(grep -ac "" "$hyprlog")
s_a=$(stage_of "$addr_a1"); s_c=$(stage_of "$addr_c1")
nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.stages then for i = 1, 500 do p.stages([[{\"op\":\"activate\",\"stage\":$s_a}]]); p.stages([[{\"op\":\"activate\",\"stage\":$s_c}]]) end end end" >>"$log" 2>&1
sleep 1.2
flood=$(($(st_events | wc -l) - f0))
focus_events=$(($(grep -ac "activewindowv2>>" "$events") - aw0))
kill -0 "$socat_pid" 2>/dev/null && kill -0 "$hypr_pid" 2>/dev/null && ((flood <= 10 && focus_events <= 10)) && [[ $(clients_of "$all") == "$before_clients" ]]
check "flood of 1000 stages calls in one dispatch: coalesced (stages events and Hyprland's own focus events), sizes unchanged" $? \
  "$flood stages event(s), $focus_events activewindowv2 event(s)"

# 15. unload during Stages, then load again.
shot before-unload
w0=$(st_count '"reason":"unavailable"')
plugin_unloaded=1
nestctl plugin unload "$plugin" >>"$log" 2>&1
unload_rc=$?
sleep 0.6
kill -0 "$hypr_pid" 2>/dev/null
alive=$?
shot after-unload
ug0=$(grey_share "$run/after-unload.png" 0)
nestctl dispatch "hl.dsp.focus({ window = \"address:$addr_c3\" })" >>"$log" 2>&1
sleep 0.3
capb0=$(stat -c %s "$cap_b")
pointer abs "$ring_x" "$ring_y" sleep 150 click sleep 200
capb_new=$(tail -c +"$((capb0 + 1))" "$cap_b" | cat -v | head -c 60)
((unload_rc == 0 && alive == 0 && ug0 <= 2 && $(st_count '"reason":"unavailable"') > w0)) && [[ $capb_new == *"[<0;"*M* && $(clients_of "$all") == "$before_clients" ]]
check "unload during Stages: Hyprland alive, on:false/unavailable posted, no thumbnail, windows normal and unblocked" $? \
  "rc $unload_rc, tile0 $ug0 %, b3 got '$capb_new'"
nestctl plugin load "$plugin" >>"$log" 2>&1
load_rc=$?
sleep 0.5
has_feature stages-available && ! has_feature stages
feat_rc=$?
((load_rc == 0 && feat_rc == 0)) && plugin_unloaded=0
check "plugin loaded again: stages-available, flag back to off (no stages)" $((load_rc + feat_rc)) "$(features)"
stop_fixture

# 16. health.
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $?
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
((${dumps:-0} == 0))
check "no core dump of the nested Hyprland" $?
exc=$(grep -ac '\[grassfield\] .*exception' "$hyprlog" 2>/dev/null)
((${exc:-0} == 0))
check "no grassfield exception in the nested log" $? "${exc:-0}"
sleep 2 # Hyprland writes its log late
overflow=$(tail -n +"$((flood_log0 + 1))" "$hyprlog" | grep -ac "overflowed event queue")
((${overflow:-0} == 0))
check "no socket2 subscriber dropped since the flood (Hyprland: overflowed event queue)" $? "${overflow:-0} line(s)"
say "stages log lines in the nested log so far: $(grep -ac '\[grassfield\] stages' "$hyprlog" 2>/dev/null) (Hyprland buffers its log); events: $(st_events | wc -l)"

if ((fail == 0)); then say "stages: PASS ($passed/$total checks)"; else say "stages: FAIL ($passed/$total checks passed)"; fi
say "stages: log $log"
exit "$fail"
