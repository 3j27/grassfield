#!/usr/bin/env bash
# Overview v2 scenario (docs/specs/overview.md "v2"): grassfield-compositor draws the real windows, live, scaled and
# moved into the overview layout, without resizing or configuring the clients.
#
# Usage: tests/compositor/overview.sh [check]              functional scenario (default)
#        tests/compositor/overview.sh perf [seconds]       CPU of the nested Hyprland, the shell and the fixture,
#                                                          9 foot windows, each phase `seconds` long (default 30)
# NESTED only: needs scripts/dev/nested-up.sh with grassfield-compositor loaded (feature "overview"). Every foot goes
# through scripts/dev/isolated.sh with the nested socket; pointer and keys through scripts/dev/pointer.sh and
# scripts/dev/keys.sh; the verb is called with scripts/nestctl (Lua `hl.plugin.grassfield.overview(...)` dispatch,
# what the shell sends through Hyprland.dispatch); plugin unload/load during the run also go through scripts/nestctl.
# The shell's v2 surfaces are stood in for by tests/compositor/overview-fixture (Bottom-layer backdrop, transparent
# Overlay chrome with labels that holds pointer and keyboard).
#
# check: 6 foot windows on OUTPUT (GF-REF), stacked where foot opens them: 4 idle, 1 ticker (prints the time every
# 200 ms), 1 that reports mouse buttons and keys into a capture file. The layout is a grid (what the shell's Layout.js
# would send). Checks:
#   events      opening/open/closing/closed with the window count, through the plugin's event throttle
#   sizes       `hyprctl clients` at/size of every window identical before, during and after the overview
#   layout      each window's pixels at its layout rect while open (dark terminal colour at the rect centre)
#   live        the ticker's layout rect changes between two frames while open; an idle one does not
#   input       clicks at a window's real place and on a window's image, and a key, reach the fixture only
#   restore     after on:false the output matches the frame before the overview (menu bar masked)
#   chrome      on:true is refused (no-chrome) without the fixture's chrome, and with a chrome that does not hold the
#               keyboard (R13 review of f12f610)
#   retarget    closing the active window while open: no closing, the state is posted with the new count
#   fullscreen  a window going full screen while open takes its workspace out (reason fullscreen); a workspace showing a
#               full-screen window is refused (no-windows)
#   resize      a surface resized twice while open: the box drawn while taller is damaged again (plugin damage log,
#               evaluated at the end: Hyprland writes its log late); the captured frame matches
#   failsafe    the chrome unmapping (process alive) ends the overview at once; the keyboard leaving the chrome ends
#               it; the chrome's process exiting ends it
#   invalid     malformed payloads change nothing and report reason "invalid"
#   flood       1000 overview calls in one Lua dispatch: a few coalesced events, socket2 kept, windows back
#   unload      `scripts/nestctl plugin unload` during an open overview: Hyprland alive, windows normal, event
#               closed/unavailable; the plugin is loaded again afterwards and advertises "overview"
#   health      Hyprland alive, no core dump of its PID, no grassfield exception in the nested log
# Screenshots (grim -o OUTPUT) before / during (mid animation) / open / after: .dev/overview/run-<timestamp>/.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
mode=${1:-check}
perf_secs=${2:-30}
case $mode in
  check) ;;
  perf) [[ $perf_secs =~ ^[1-9][0-9]*$ ]] || { echo "usage: overview.sh [check|perf [seconds]]" >&2; exit 2; } ;;
  *) echo "usage: overview.sh [check|perf [seconds]]" >&2; exit 2 ;;
esac

out=${OV_OUTPUT:-GF-REF}
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)
hypr_pid=$(cat "$dev/nested.pid" 2>/dev/null || true)
shell_pid=$(cat "$dev/shell.pid" 2>/dev/null || true)
plugin=$root/compositor/build/grassfield-compositor.so
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "overview: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
# Never the owner's session (R3).
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "overview: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat jq grim magick foot qs; do
  command -v "$tool" >/dev/null || { echo "overview: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
nestctl -j grassfield 2>/dev/null | jq -e '.features | index("overview")' >/dev/null \
  || { echo "overview: the loaded plugin does not advertise \"overview\"" >&2; exit 2; }

run=$dev/overview/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
log=$run/run.log
events=$run/events.log
start_human=$(date '+%Y-%m-%d %H:%M:%S')
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log

say() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$log" 2>&1; }
shot() { WAYLAND_DISPLAY=$sock grim -l 0 -o "$out" "$run/$1.png" 2>>"$log"; }

pids=()
socat_pid=""
fixture_pid=""
plugin_unloaded=0
cleanup() {
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  if ((plugin_unloaded)); then
    nestctl plugin load "$plugin" >/dev/null 2>&1 # never leave the nested session without the plugin
  fi
}
trap cleanup EXIT

stamp_events() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$log" </dev/null > >(stamp_events >"$events") &
socat_pid=$!

ov_events() { grep -a 'grassfield>>{"v":"gfc/1","type":"overview"' "$events" 2>/dev/null; }
ov_count() { ov_events | grep -c "$1"; }
# Waits until more than <before> overview events match <regex> (at most <ms>).
wait_ov() { # <regex> <before> <ms>
  local deadline=$(($(date +%s%3N) + $3))
  while (($(ov_count "$1") <= $2)); do
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.02
  done
}
overview() { # <json>: the Lua dispatch the shell sends (long-bracket string: no escaping needed)
  nestctl dispatch "hl.plugin.grassfield.overview([[$1]])" >>"$log" 2>&1
}

read -r mon_x mon_y mon_w mon_h < <(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "overview: output $out not found" >&2; exit 2; }
ws=$(nestctl -j monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | .activeWorkspace.id')

foot_bg() { # [foot args...] -> pid
  WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name overview foot "$@" >/dev/null 2>&1 </dev/null &
  echo $!
}
# A foot that reports mouse buttons (xterm 1000 + 1006 SGR) and every byte typed into <capture> (raw tty).
foot_capture() { # <capture> -> pid
  : >"$1"
  foot_bg -e sh -c 'stty raw -echo; printf "\033[?1000h\033[?1006h"; exec cat -v >"$0"' "$1"
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
  nestctl -j clients | jq -c --arg list "$1" '[.[] | select(.address as $a | ($list | split(" ") | index($a))) | {address, at, size, workspace: .workspace.id}] | sort_by(.address)'
}

# Grid layout of n windows of size ww x wh on the output (layout coordinates): Spaces bar 96 px at the top, Dock
# 110 px at the bottom, 48 px gaps, scale <= 0.8, the titlebar (28 px x scale) kept clear above each rect.
grid_json() { # <on> <durationMs> <addresses...>
  local on=$1 dur=$2
  shift 2
  jq -nc --argjson on "$on" --argjson d "$dur" --argjson mx "$mon_x" --argjson my "$mon_y" --argjson W "$mon_w" --argjson H "$mon_h" \
    --argjson ww 700 --argjson wh 500 '$ARGS.positional as $a | ($a | length) as $n |
    (if $n == 0 then 1 else ([range(1; $n + 1)] | map(select(. * . >= $n)) | first) end) as $cols |
    (if $n == 0 then 1 else (($n + $cols - 1) / $cols | floor) end) as $rows |
    48 as $gap | 96 as $top | 110 as $bottom |
    (($W - 2 * $gap - ($cols - 1) * $gap) / $cols) as $cw |
    (($H - $top - $bottom - $gap - ($rows - 1) * $gap) / $rows) as $ch |
    ([0.8, $cw / $ww, $ch / ($wh + 28)] | min) as $s |
    {on: $on, durationMs: $d, windows: [$a | to_entries[] | .key as $i |
      {address: .value,
       x: ($mx + $gap + ($i % $cols) * ($cw + $gap) + ($cw - $ww * $s) / 2 | floor),
       y: ($my + $top + $gap + (($i / $cols) | floor) * ($ch + $gap) + ($ch - ($wh + 28) * $s) / 2 + 28 * $s | floor),
       w: ($ww * $s | floor), h: ($wh * $s | floor)}]}' --args "$@"
}

start_fixture() { # <grid json> [keyboard: exclusive (default) | none]
  local targets
  targets=$(jq -c '[.windows | to_entries[] | {x: .value.x, y: .value.y, w: .value.w, h: .value.h, label: "foot \(.key + 1)"}]' <<<"$1")
  : >"$run/fixture.log"
  GF_OVERVIEW_OUTPUT=$out GF_OVERVIEW_TARGETS=$targets GF_OVERVIEW_DIM=0.35 GF_OVERVIEW_KEYBOARD=${2:-exclusive} WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig \
    setsid "$root/scripts/dev/isolated.sh" --name overview-fixture qs -p "$root/tests/compositor/overview-fixture" --no-color \
    >"$run/fixture.log" 2>&1 </dev/null &
  fixture_pid=$!
  local i
  for i in $(seq 1 50); do
    grep -q "\[overview-fixture\] output .* found" "$run/fixture.log" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.5 # surfaces mapped and the keyboard taken
  grep -q "\[overview-fixture\] output $out found" "$run/fixture.log"
}
stop_fixture() {
  [[ -n $fixture_pid ]] || return 0
  kill "$fixture_pid" 2>/dev/null
  wait "$fixture_pid" 2>/dev/null
  fixture_pid=""
}

# Mean colour of a w x h crop centred on (x, y) (output-local pixels) of <png>: "r g b" (0..255).
mean_rgb() { # <png> <x> <y> <w> <h>
  magick "$1" -crop "${4}x${5}+$(($2 - $4 / 2))+$(($3 - $5 / 2))" +repage -resize 1x1\! -depth 8 txt:- 2>/dev/null \
    | sed -n 's/.*(\([0-9.]*\),\([0-9.]*\),\([0-9.]*\).*/\1 \2 \3/p' | awk '{printf "%d %d %d\n", $1, $2, $3}'
}
# Terminal background (foot's default dark grey, scaled down: still a dark neutral grey).
is_terminal_grey() { # r g b
  awk -v r="$1" -v g="$2" -v b="$3" 'BEGIN { m = r; if (g > m) m = g; if (b > m) m = b; n = r; if (g < n) n = g; if (b < n) n = b; exit !(m < 70 && m - n < 10) }'
}
# Share of differing pixels between two crops of two shots (fuzz 3 %).
crop_diff() { # <a.png> <b.png> <geometry WxH+X+Y>
  magick compare -metric AE -fuzz 3% <(magick "$1" -crop "$3" +repage png:-) <(magick "$2" -crop "$3" +repage png:-) null: 2>&1 \
    | sed -n 's/^\([0-9.e+]*\).*/\1/p'
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
  fi
}
last_ov() { ov_events | tail -n 1 | sed 's/^[0-9]* //'; }
# Terminal grey at the centre of each listed layout rect in <png>: count.
grey_count() { # <png> <layout json> <first index> <count>
  local n=0 i x y w h r g b
  for ((i = $3; i < $3 + $4; i++)); do
    read -r x y w h < <(jq -r --argjson i "$i" '.windows[$i] | "\(.x) \(.y) \(.w) \(.h)"' <<<"$2")
    read -r r g b < <(mean_rgb "$1" $((x - mon_x + w / 2)) $((y - mon_y + h / 2 + h / 5)) 40 40)
    is_terminal_grey "$r" "$g" "$b" && n=$((n + 1))
  done
  echo "$n"
}

say "overview $mode: run $run, nested pid $hypr_pid ($(nestctl -j version | jq -r .tag)), output $out ${mon_w}x${mon_h} at $mon_x,$mon_y, workspace $ws"
say "plugin features: $(nestctl -j grassfield | jq -c .features)"

# New windows open on the output under the pointer, centered (700x500, foot's default size).
pointer abs $((mon_w / 2)) $((mon_h - 160)) sleep 50

if [[ $mode == perf ]]; then
  # ---- perf: 9 windows, one ticker that prints only while the flag file exists ----
  flag=$run/ticker.flag
  addrs=()
  for i in $(seq 1 8); do
    p=$(foot_bg)
    pids+=("$p")
    sleep 0.35
    addrs+=("$(address_of "$p")")
  done
  p=$(foot_bg -e sh -c 'while sleep 0.1; do [ -e "$0" ] && date +%T.%N; done' "$flag")
  pids+=("$p")
  addrs+=("$(address_of "$p")")
  [[ ${#addrs[@]} -eq 9 && -n ${addrs[8]} ]] || { say "perf: setup error: windows did not map (${addrs[*]})"; exit 2; }
  layout=$(grid_json true 350 "${addrs[@]}")
  closejson='{"on":false,"durationMs":350}'
  hz=$(getconf CLK_TCK)
  sleep 2
  measure() { # <label>: CPU % of one core over perf_secs for Hyprland, the shell, the fixture
    local h0 s0 f0 h1 s1 f1 t0 t1
    h0=$(cpu_ticks "$hypr_pid"); s0=$(cpu_ticks "${shell_pid:-0}"); f0=$(cpu_ticks "${fixture_pid:-0}"); t0=$(date +%s%N)
    sleep "$perf_secs"
    h1=$(cpu_ticks "$hypr_pid"); s1=$(cpu_ticks "${shell_pid:-0}"); f1=$(cpu_ticks "${fixture_pid:-0}"); t1=$(date +%s%N)
    awk -v l="$1" -v h=$((h1 - h0)) -v s=$((s1 - s0)) -v f=$((f1 - f0)) -v dt=$((t1 - t0)) -v hz="$hz" -v rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$hypr_pid/status")" \
      'BEGIN { sec = dt / 1e9; printf "| %s | %.1f %% | %.1f %% | %.1f %% | %.0f MB |\n", l, 100 * h / hz / sec, 100 * s / hz / sec, 100 * f / hz / sec, rss / 1024 }' | tee -a "$log"
  }
  say "perf: 9 foot windows (700x500) on $out, ${perf_secs} s per phase, CPU = % of one core from /proc/<pid>/stat"
  say "| Phase | nested Hyprland | grassfield-shell | fixture (v2 chrome stand-in) | Hyprland RSS |"
  measure "closed, idle"
  touch "$flag"; measure "closed, ticker 10 lines/s"; rm -f "$flag"
  start_fixture "$layout" || say "perf: fixture did not start (see $run/fixture.log)"
  overview "$layout"; sleep 1
  measure "open, idle"
  touch "$flag"; measure "open, ticker 10 lines/s"; rm -f "$flag"
  # Animation: open/close every second (350 ms animation each way).
  (
    end=$(($(date +%s) + perf_secs))
    while (($(date +%s) < end)); do overview "$closejson"; sleep 0.5; overview "$layout"; sleep 0.5; done
  ) &
  anim=$!
  measure "open/close every 0.5 s (350 ms animations)"
  wait "$anim"
  overview "$closejson"; sleep 0.6
  stop_fixture
  say "perf: overview events: $(ov_count '"state":"open"') open, $(ov_count '"state":"closed"') closed"
  kill -0 "$hypr_pid" 2>/dev/null || { say "perf: FAIL nested Hyprland is gone"; exit 1; }
  say "perf: done (log $log)"
  exit 0
fi

# ---- check ----
say "setup: 6 foot windows"
addrs=()
for i in 1 2 3 4; do
  p=$(foot_bg)
  pids+=("$p")
  sleep 0.35
  addrs+=("$(address_of "$p")")
done
p=$(foot_bg -e sh -c 'while sleep 0.2; do date +%T.%N; done')
pids+=("$p")
ticker=$(address_of "$p")
addrs+=("$ticker")
cap=$run/capture.cap
p=$(foot_capture "$cap")
pids+=("$p")
capture=$(address_of "$p")
addrs+=("$capture")
for a in "${addrs[@]}"; do [[ -n $a ]] || { say "setup error: a window did not map (${addrs[*]})"; exit 2; }; done
sleep 1
layout=$(grid_json true 350 "${addrs[@]}")
printf '%s\n' "$layout" >"$run/layout.json"
say "setup: windows ${addrs[*]} (ticker $ticker, capture $capture); layout $run/layout.json"

before_clients=$(clients_of "${addrs[*]}")
shot before

# 0. no transform without the shell's chrome covering the windows and holding the keyboard (R13 review of f12f610).
n0=$(ov_count '"reason":"no-chrome"'); o0=$(ov_count '"state":"opening"')
overview "$(jq -c '.durationMs = 0' <<<"$layout")"
sleep 0.4
(($(ov_count '"reason":"no-chrome"') > n0 && $(ov_count '"state":"opening"') == o0))
check "on:true without the shell's chrome mapped: refused (no-chrome), nothing transformed" $? "$(last_ov)"
start_fixture "$layout" none
n0=$(ov_count '"reason":"no-chrome"'); o0=$(ov_count '"state":"opening"')
overview "$(jq -c '.durationMs = 0' <<<"$layout")"
sleep 0.4
(($(ov_count '"reason":"no-chrome"') > n0 && $(ov_count '"state":"opening"') == o0))
check "on:true with the chrome mapped but keyboard None: refused (no-chrome)" $? "$(last_ov)"
stop_fixture
sleep 0.3

# 1. open, with the shell stand-in (backdrop + chrome) mapped first, as the shell would.
start_fixture "$layout"
check "fixture surfaces mapped on $out" $? "$run/fixture.log"
o0=$(ov_count '"state":"opening"'); p0=$(ov_count '"state":"open"')
open_json=$(jq -c '.durationMs = 900' <<<"$layout") # slower, so a frame mid-animation can be captured
overview "$open_json"
sleep 0.25
shot during-open
wait_ov '"state":"open"' "$p0" 3000
check "events: opening then open" $? "$(ov_events | tail -n 2 | sed 's/^[0-9]* //' | tr '\n' ' ')"
ov_events | grep -q '"state":"opening","windows":6' ; check "opening reports 6 windows" $?
sleep 0.3
shot open
during_clients=$(clients_of "${addrs[*]}")
[[ $during_clients == "$before_clients" ]]
check "client sizes and positions unchanged while open" $? "$during_clients"

# 2. layout: the dark terminal grey at each rect centre while open; at least half of them not grey before.
grey_open=0 grey_before=0
for i in "${!addrs[@]}"; do
  read -r x y w h < <(jq -r --argjson i "$i" '.windows[$i] | "\(.x) \(.y) \(.w) \(.h)"' <<<"$layout")
  cx=$((x - mon_x + w / 2)); cy=$((y - mon_y + h / 2 + h / 5)) # below the text lines
  read -r r g b < <(mean_rgb "$run/open.png" "$cx" "$cy" 40 40)
  is_terminal_grey "$r" "$g" "$b" && grey_open=$((grey_open + 1))
  read -r r g b < <(mean_rgb "$run/before.png" "$cx" "$cy" 40 40)
  is_terminal_grey "$r" "$g" "$b" && grey_before=$((grey_before + 1))
done
((grey_open == 6 && grey_before <= 3))
check "each window drawn at its layout rect" $? "terminal grey at $grey_open/6 rect centres open, $grey_before/6 before"
magick compare -metric AE -fuzz 3% "$run/during-open.png" "$run/before.png" null: 2>"$run/cmp1.txt"
magick compare -metric AE -fuzz 3% "$run/during-open.png" "$run/open.png" null: 2>"$run/cmp2.txt"
d1=$(sed -n 's/^\([0-9.e+]*\).*/\1/p' "$run/cmp1.txt"); d2=$(sed -n 's/^\([0-9.e+]*\).*/\1/p' "$run/cmp2.txt")
awk -v a="${d1:-0}" -v b="${d2:-0}" 'BEGIN { exit !(a > 20000 && b > 20000) }'
check "a frame mid-animation differs from before and from open" $? "$d1 / $d2 px"

# 3. live: the ticker's rect changes between two frames; an idle window's does not.
geom() { jq -r --arg a "$1" --argjson mx "$mon_x" --argjson my "$mon_y" '.windows[] | select(.address == $a) | "\(.w)x\(.h)+\(.x - $mx)+\(.y - $my)"' <<<"$layout"; }
sleep 0.6
shot open-later
tick_diff=$(crop_diff "$run/open.png" "$run/open-later.png" "$(geom "$ticker")")
idle_diff=$(crop_diff "$run/open.png" "$run/open-later.png" "$(geom "${addrs[0]}")")
awk -v t="${tick_diff:-0}" -v i="${idle_diff:-1}" 'BEGIN { exit !(t > 20 && i == 0) }'
check "live content: the ticker updates in the overview, an idle window does not change" $? "ticker $tick_diff px, idle $idle_diff px"

# 4. input: a click at the capture window's real place (outside every rect), one on its image, one key.
read -r cx cy cw ch < <(jq -r '.[] | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' <<<"$(clients_of "$capture")")
real_pt=$(jq -r --argjson x "$cx" --argjson y "$cy" --argjson w "$cw" --argjson h "$ch" --argjson mx "$mon_x" --argjson my "$mon_y" '
  [range(0; 20) as $i | range(0; 20) as $j | {px: ($x + 10 + $i * ($w - 20) / 19 | floor), py: ($y + 10 + $j * ($h - 20) / 19 | floor)}] as $pts |
  [.windows[] | {x: .x - 4, y: (.y - 4 - .h * 0.06), r: (.x + .w + 4), b: (.y + .h + 4)}] as $rects |
  [$pts[] | select(. as $p | $rects | all($p.px < .x or $p.px > .r or $p.py < .y or $p.py > .b))][0] |
  if . == null then "" else "\(.px - $mx) \(.py - $my)" end' <<<"$layout")
img_pt=$(jq -r --arg a "$capture" --argjson mx "$mon_x" --argjson my "$mon_y" '.windows[] | select(.address == $a) | "\(.x - $mx + (.w / 2 | floor)) \(.y - $my + (.h / 2 | floor))"' <<<"$layout")
presses0=$(grep -c "\[overview-fixture\] press" "$run/fixture.log")
keys0=$(grep -c "\[overview-fixture\] key" "$run/fixture.log")
cap0=$(stat -c %s "$cap")
if [[ -n $real_pt ]]; then
  read -r rx ry <<<"$real_pt"
  pointer abs "$rx" "$ry" sleep 120 click sleep 150
fi
read -r ix iy <<<"$img_pt"
pointer abs "$ix" "$iy" sleep 120 click sleep 150
keys q
sleep 0.4
presses=$(($(grep -c "\[overview-fixture\] press" "$run/fixture.log") - presses0))
keyn=$(($(grep -c "\[overview-fixture\] key" "$run/fixture.log") - keys0))
cap_new=$(tail -c +"$((cap0 + 1))" "$cap" | cat -v | head -c 200)
[[ -n $real_pt ]] && ((presses == 2 && keyn == 1)) && [[ -z $cap_new ]]
check "input goes to the overview surface, never to the real windows" $? \
  "real place ($real_pt) + image ($img_pt): $presses press(es) and $keyn key(s) at the fixture, capture window got '${cap_new}'"

# 5. close: closing then closed; the frame after matches the one before (menu bar masked).
c0=$(ov_count '"state":"closed"')
overview '{"on":false,"durationMs":900}'
sleep 0.3
shot during-close
wait_ov '"state":"closed"' "$c0" 3000
check "events: closing then closed" $? "$(ov_events | tail -n 2 | sed 's/^[0-9]* //' | tr '\n' ' ')"
stop_fixture
pointer abs $((mon_w / 2)) $((mon_h - 160)) sleep 50 # the nested output draws a software cursor: same place as before
sleep 0.8                                            # keyboard back on the capture window, frames settled
shot after
after_clients=$(clients_of "${addrs[*]}")
[[ $after_clients == "$before_clients" ]]
check "client sizes and positions unchanged after" $?
mask() { magick "$1" -fill black -draw "rectangle 0,0 $mon_w,30" "$2"; }
mask "$run/before.png" "$run/before-masked.png"
mask "$run/after.png" "$run/after-masked.png"
restore_diff=$(magick compare -metric AE -fuzz 3% "$run/before-masked.png" "$run/after-masked.png" null: 2>&1 | sed -n 's/^\([0-9.e+]*\).*/\1/p')
awk -v d="${restore_diff:-999999}" 'BEGIN { exit !(d < 200) }'
check "rendering back to normal: after == before (menu bar masked)" $? "$restore_diff px differ"

open_now() { # <layout json>: on:true without animation, waits for "open"
  local p0
  p0=$(ov_count '"state":"open"')
  overview "$(jq -c '.durationMs = 0' <<<"$1")"
  wait_ov '"state":"open"' "$p0" 2000
}
close_now() { overview '{"on":false,"durationMs":0}'; sleep 0.3; }

# 5b. closing the ACTIVE window while open retargets (spec): the overview stays, the other windows stay in the layout.
p=$(foot_bg); pids+=("$p"); victim_pid=$p
victim=$(address_of "$p")
sleep 0.6
layout7=$(grid_json true 0 "${addrs[@]}" "$victim")
start_fixture "$layout7" >/dev/null
active=$(nestctl -j activewindow | jq -r '.address // ""')
open_now "$layout7"
c0=$(ov_count '"state":"closing"'); cl0=$(ov_count '"state":"closed"'); s0=$(ov_count '"state":"open","windows":6')
kill "$victim_pid" 2>/dev/null
sleep 0.8
shot open-after-active-close
kept=$(grey_count "$run/open-after-active-close.png" "$layout7" 0 6)
[[ -n $victim && $active == "$victim" ]] && (($(ov_count '"state":"closing"') == c0 && $(ov_count '"state":"closed"') == cl0 && $(ov_count '"state":"open","windows":6') > s0 && kept == 6))
check "closing the active window while open retargets: no closing, open/6 posted, the 6 others stay in the layout" $? \
  "active $active (closed: $victim), last: $(last_ov), terminal grey at $kept/6 remaining rects"
close_now
stop_fixture

# 5c. a window going full screen while open: its workspace leaves the overview (event reason fullscreen); a workspace
# showing a full-screen window is not overviewed (no-windows).
fs() { nestctl dispatch "hl.dsp.window.fullscreen({ mode = \"fullscreen\", window = \"address:$1\" })" >>"$log" 2>&1; }
start_fixture "$layout" >/dev/null
open_now "$layout"
f0=$(ov_count '"reason":"fullscreen"')
fs "${addrs[0]}"
sleep 0.8
fs_event=$(ov_events | grep '"reason":"fullscreen"' | tail -n 1 | sed 's/^[0-9]* //')
(($(ov_count '"reason":"fullscreen"') > f0)) && [[ $fs_event == *'"windows":0'* ]]
check "a window going full screen while open: its workspace leaves the overview (reason fullscreen, 0 windows left)" $? "$fs_event; last: $(last_ov)"
close_now
n0=$(ov_count '"reason":"no-windows"')
overview "$(jq -c '.durationMs = 0' <<<"$layout")"
sleep 0.4
(($(ov_count '"reason":"no-windows"') > n0))
check "a workspace showing a full-screen window is not overviewed (no-windows)" $? "$(last_ov)"
fs "${addrs[0]}" # back to floating
sleep 0.8
close_now
stop_fixture
fs_after=$(nestctl -j clients | jq -r --arg a "${addrs[0]}" '.[] | select(.address == $a) | .fullscreen')
[[ $fs_after == 0 || $fs_after == false ]] || say "  note: ${addrs[0]} still full screen ($fs_after)"

# 5d. a surface resized while open leaves no stale pixels (R13 review: damage of the last drawn box). A dedicated foot
# (700x500) gets a square rect in the top-left part of the output, away from every window's real place (Hyprland damages
# the real place itself); it is resized to 300x500 (drawn taller, filling the rect's height) and back while open. The band
# at the top of the rect is drawn on by the tall state only: after the resize back it must match the frame before.
p=$(foot_bg); pids+=("$p"); rs_pid=$p
rs=$(address_of "$p")
sleep 0.6
sq=$(jq -nc --arg a "$rs" --argjson x $((mon_x + 60)) --argjson y $((mon_y + 140)) '{on: true, durationMs: 0, windows: [{address: $a, x: $x, y: $y, w: 400, h: 400}]}')
start_fixture "$sq" >/dev/null
open_now "$sq"
sleep 0.4
shot resize-open
resize() { nestctl dispatch "hl.dsp.window.resize({ x = $2, y = $3, exact = true, window = \"address:$1\" })" >>"$log" 2>&1; }
log0=$(grep -ac "" "$hyprlog")
resize "$rs" 300 500
sleep 1
shot resize-tall
resize "$rs" 700 500
sleep 1
shot resize-back
# Screen captures repaint the whole output (a capture with the fix reverted showed no stale pixels either), so the proof
# that the box drawn while taller is damaged again is the plugin's damage log: one line at the first frame of each burst,
# "damaged <previous box> and <current box>". Growing (first burst): the previous box is the open box (height h0).
# Shrinking back (second burst): the previous box must be the tall box (h1 > h0 + 50); without the fix the previous box
# stays the open box (h1 = h0). Hyprland writes its log late: polled up to 3 s.
damage_lines() { tail -n +"$((log0 + 1))" "$hyprlog" | grep -a "overview: window ${rs#0x} drawn box changed while open" | sed -n 's/.*damaged [-0-9.]*,[-0-9.]* [0-9.]*x\([0-9.]*\) and [-0-9.]*,[-0-9.]* [0-9.]*x\([0-9.]*\).*/\1 \2/p'; }
# Band: 200x24 px at the rect's horizontal centre, 8..32 px below its top (output-local); mean colours compared.
read -r r0 g0 b0 < <(mean_rgb "$run/resize-open.png" 260 160 200 24)
read -r r1 g1 b1 < <(mean_rgb "$run/resize-tall.png" 260 160 200 24)
read -r r2 g2 b2 < <(mean_rgb "$run/resize-back.png" 260 160 200 24)
dist() { awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" -v e="$5" -v f="$6" 'BEGIN { printf "%.1f", sqrt((a - d) ^ 2 + (b - e) ^ 2 + (c - f) ^ 2) }'; }
tall_dist=$(dist "$r0" "$g0" "$b0" "$r1" "$g1" "$b1")
back_dist=$(dist "$r0" "$g0" "$b0" "$r2" "$g2" "$b2")
awk -v t="$tall_dist" -v b="$back_dist" 'BEGIN { exit !(t > 20 && b < 4) }'
check "surface resized twice while open: the captured frame matches the frame before where the taller state was drawn" $? \
  "band mean colour: open $r0,$g0,$b0; tall $r1,$g1,$b1 (distance $tall_dist); after the resize back $r2,$g2,$b2 (distance $back_dist)"
close_now
stop_fixture
kill "$rs_pid" 2>/dev/null
sleep 0.5

# 6. failsafes: the chrome unmapping while open (the shell process alive) ends the overview at once, without a closing
# animation; the chrome dropping the keyboard ends it; the chrome's process exiting ends it.
start_fixture "$layout" >/dev/null
open_now "$layout"
c0=$(ov_count '"state":"closing"'); cl0=$(ov_count '"state":"closed"')
keys h # the fixture unmaps its chrome
wait_ov '"state":"closed"' "$cl0" 3000
(($(ov_count '"state":"closing"') == c0)) && [[ $(last_ov) == *'"state":"closed"'*'"reason":"interrupted"'* ]]
check "failsafe: the chrome unmapping while open ends the overview at once (closed/interrupted, no closing animation)" $? "$(last_ov)"
stop_fixture
start_fixture "$layout" >/dev/null
open_now "$layout"
cl0=$(ov_count '"state":"closed"')
keys n # the fixture's chrome drops its keyboard to None
wait_ov '"state":"closed"' "$cl0" 3000
ov_events | tail -n 2 | grep -q '"reason":"interrupted"'
check "failsafe: the keyboard leaving the chrome while open ends the overview (interrupted)" $? "$(ov_events | tail -n 2 | sed 's/^[0-9]* //' | tr '\n' ' ')"
stop_fixture
start_fixture "$layout" >/dev/null
open_now "$layout"
c0=$(ov_count '"state":"closed"')
stop_fixture
wait_ov '"state":"closed"' "$c0" 3000
ov_events | tail -n 1 | grep -q '"reason":"interrupted"'
check "failsafe: the chrome's process exiting closes the overview" $? "$(ov_events | tail -n 2 | sed 's/^[0-9]* //' | tr '\n' ' ')"
sleep 0.5

# 7. invalid payloads: nothing changes, reason "invalid".
i0=$(ov_count '"reason":"invalid"')
for bad in '{"on":true}' '{"on":true,"durationMs":350,"windows":[{"address":"0xzz","x":0,"y":0,"w":1,"h":1}]}' \
  '{"on":true,"durationMs":99999,"windows":[]}' 'not json' '{"on":true,"durationMs":0,"windows":[{"address":"0x1","x":1e999,"y":0,"w":10,"h":10}]}'; do
  overview "$bad"
done
nestctl dispatch 'hl.plugin.grassfield.overview(42)' >>"$log" 2>&1
sleep 0.5
inv=$(($(ov_count '"reason":"invalid"') - i0))
last=$(ov_events | tail -n 1 | sed 's/^[0-9]* //')
((inv >= 1)) && [[ $last == *'"state":"closed"'* ]]
check "invalid payloads refused, state unchanged" $? "$inv invalid event(s) after coalescing, last: $last"
# A rect outside the window's monitor and an unknown window: nothing transformable, refused (no-windows).
n0=$(ov_count '"reason":"no-windows"')
overview "{\"on\":true,\"durationMs\":0,\"windows\":[{\"address\":\"${addrs[0]}\",\"x\":-5000,\"y\":0,\"w\":100,\"h\":100},{\"address\":\"0x1\",\"x\":$mon_x,\"y\":0,\"w\":100,\"h\":100}]}"
sleep 0.3
(($(ov_count '"reason":"no-windows"') > n0))
check "out-of-monitor rect and unknown window ignored (no-windows)" $?

start_fixture "$layout" >/dev/null # the chrome covers the windows for the flood and the unload below
# 7b. flood (R11): one dispatch with 500 open/close pairs: events coalesced, socket2 subscriber connected, Hyprland
# alive, the final state closed and every window back at its place.
f0=$(ov_events | wc -l)
on0=$(jq -c '.durationMs = 0' <<<"$layout")
nestctl dispatch "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview then for i = 1, 500 do p.overview([[$on0]]); p.overview([[{\"on\":false,\"durationMs\":0}]]) end end end" >>"$log" 2>&1
sleep 0.8
flood_events=$(($(ov_events | wc -l) - f0))
last=$(ov_events | tail -n 1 | sed 's/^[0-9]* //')
kill -0 "$socat_pid" 2>/dev/null && kill -0 "$hypr_pid" 2>/dev/null && ((flood_events <= 10)) && [[ $last == *'"state":"closed"'* ]] \
  && [[ $(clients_of "${addrs[*]}") == "$before_clients" ]]
check "flood of 1000 overview calls in one dispatch" $? "$flood_events overview event(s) posted, last: $last"

# 8. unload during an open overview, then load again.
p0=$(ov_count '"state":"open"')
overview "$(jq -c '.durationMs = 0' <<<"$layout")"
wait_ov '"state":"open"' "$p0" 2000
shot open-before-unload
u0=$(ov_count '"reason":"unavailable"')
plugin_unloaded=1
nestctl plugin unload "$plugin" >>"$log" 2>&1
unload_rc=$?
sleep 0.6
kill -0 "$hypr_pid" 2>/dev/null
alive=$?
shot after-unload
(($(ov_count '"reason":"unavailable"') > u0))
ev_rc=$?
unload_clients=$(clients_of "${addrs[*]}")
grey_left=0
for i in "${!addrs[@]}"; do
  read -r x y w h < <(jq -r --argjson i "$i" '.windows[$i] | "\(.x) \(.y) \(.w) \(.h)"' <<<"$layout")
  read -r r g b < <(mean_rgb "$run/after-unload.png" $((x - mon_x + w / 2)) $((y - mon_y + h / 2 + h / 5)) 40 40)
  is_terminal_grey "$r" "$g" "$b" && grey_left=$((grey_left + 1))
done
((unload_rc == 0 && alive == 0 && ev_rc == 0)) && [[ $unload_clients == "$before_clients" ]] && ((grey_left == grey_before))
check "unload during the overview: Hyprland alive, windows back at their place, closed/unavailable posted" $? \
  "unload rc $unload_rc, terminal grey at $grey_left/6 rect centres (as before: $grey_before)"
nestctl plugin load "$plugin" >>"$log" 2>&1
load_rc=$?
sleep 0.5
nestctl -j grassfield 2>/dev/null | jq -e '.features | index("overview")' >/dev/null
feat_rc=$?
((load_rc == 0 && feat_rc == 0)) && plugin_unloaded=0
check "plugin loaded again and advertises overview" $((load_rc + feat_rc)) "$(nestctl -j grassfield 2>/dev/null | jq -c .features)"
stop_fixture

# 5d (end). damage log of the resize step (see 5d).
h0="" h1=""
for _ in $(seq 1 100); do # evaluated at the end of the run: Hyprland flushes its log late
  h0=$(damage_lines | sed -n 1p | cut -d' ' -f1)
  h1=$(damage_lines | sed -n 2p | cut -d' ' -f1)
  [[ -n $h0 && -n $h1 ]] && break
  sleep 0.1
done
awk -v a="${h0:-0}" -v b="${h1:-0}" 'BEGIN { exit !(a > 0 && b - a > 50) }'
check "surface resized while open: the box drawn while taller is damaged again when it shrinks back (plugin damage log)" $? \
  "open box height ${h0:-none}, box damaged at the start of the shrink ${h1:-none} ($(damage_lines | wc -l) burst line(s))"

# 9. health.
kill -0 "$hypr_pid" 2>/dev/null
check "nested Hyprland alive" $?
dumps=$(coredumpctl --no-pager --json=short list Hyprland --since "$start_human" 2>/dev/null | jq -r '.[].pid' 2>/dev/null | grep -cx "$hypr_pid")
((${dumps:-0} == 0))
check "no core dump of the nested Hyprland" $?
exc=$(grep -ac '\[grassfield\] .*exception' "$hyprlog" 2>/dev/null)
((${exc:-0} == 0))
check "no grassfield exception in the nested log" $? "${exc:-0}"
say "overview log lines in the nested log so far: $(grep -ac '\[grassfield\] overview' "$hyprlog" 2>/dev/null) (Hyprland buffers its log)"

if ((fail == 0)); then say "overview: PASS ($passed/$total checks)"; else say "overview: FAIL ($passed/$total checks passed)"; fi
say "overview: log $log"
exit "$fail"
