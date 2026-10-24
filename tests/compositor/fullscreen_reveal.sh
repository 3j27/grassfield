#!/usr/bin/env bash
# NESTED scenario (ADR-0015 P6, docs/specs/compositor.md work item P6 and FR13): the revealed titlebar of a full-screen
# window takes its presses from the event bus, a press and its release cancelled together. What a client and the session
# see of it:
#   1 control      a click in the window's content reaches the client (a mouse-reporting foot: ESC[<0;col;rowM / m)
#   2 drag area    top edge, then a click on the revealed bar's drag area: the client gets neither the press nor the release,
#                  the window stays in full screen
#   3 minimize     top edge, then a click on the minimize light: inert (still full screen, not minimized), nothing to the client
#   4 overlay      an Overlay layer of another client over the lights (tests/compositor/reveal-fixture): a control click on
#                  the layer below the bar reaches it (the layer takes input here); top edge, then a click on the zoom
#                  light's place: the layer logs that press (awaited 10 s), foot gets nothing, the window stays in full
#                  screen; the plugin's own line ("left to Hyprland", written before Hyprland delivers) alone gives
#                  NOT VERIFIED, never PASS
#   5 lock         the session locked (tests/security/foreign_locker, released over its IPC): top edge, then a click on the
#                  zoom light's place: still full screen after the unlock (the bar never takes a click while locked); then
#                  the session must be unlocked again: a click in the content reaches foot
#   6 way out      top edge, then a click on the zoom light: full screen left (fullscreen 0), nothing to the client
# After each step the plugin's own lines about the revealed bar (one INFO line per press over it: taken, or left to
# Hyprland and why, with the number of held buttons; one per release of an armed light) are copied from the nested
# hyprland.log into this log.
# Not covered here: a pointer the client confines (no constraining client in the fixtures; the plugin checks
# CInputManager::isConstrained).
# Usage: tests/compositor/fullscreen_reveal.sh   (bare; NESTED only: scripts/dev/nested-up.sh with grassfield-compositor)
# Exit: 0 PASS, 1 FAIL or NOT VERIFIED, 2 setup or environment error. Log: .dev/fullscreen-reveal/run-<timestamp>.log.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
out=${FR_OUTPUT:-GF-REF}
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
# shellcheck source=titlebar_geometry.sh
. "$root/tests/compositor/titlebar_geometry.sh" || exit 2
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ -z $sock || -z $sig || -z $hypr_pid ]] || ! kill -0 "$hypr_pid" 2>/dev/null; then
  echo "fullscreen_reveal: no nested instance (run scripts/dev/nested-up.sh)" >&2
  exit 2
fi
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "fullscreen_reveal: refusing: recorded nested instance is the main session" >&2
  exit 2
fi

work=$dev/fullscreen-reveal
mkdir -p "$work"
rm -f "$work"/*.cap "$work"/fixture.log
log=$work/run-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
pointer() { timeout 20 "$root/scripts/dev/pointer.sh" output "$out" "$@" >>"$log" 2>&1; }
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
log_at() { grep -ac "" "$hyprlog" 2>/dev/null || echo 0; }
plugin_lines() { # <line count before the step>: the plugin's lines about the revealed bar since then, into this log
  tail -n +"$(($1 + 1))" "$hyprlog" 2>/dev/null | grep -a "revealed titlebar\|titlebar of a full-screen window" | sed 's/^/    plugin: /' | tee -a "$log" >/dev/null
}
query() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$1"; } # read-only: clients, monitors, layers

foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
foreign_ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }
pids=() locker_pid=""
cleanup() {
  if [[ -n $locker_pid ]] && kill -0 "$locker_pid" 2>/dev/null; then
    foreign_ipc unlock >/dev/null # never leave the nested session locked
    sleep 0.5
    kill "$locker_pid" 2>/dev/null
  fi
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

fail=0
check() { # <label> <0 ok / 1 fail> <details>
  if [[ $2 == 0 ]]; then say "  $1: OK   ($3)"; else say "  $1: FAIL ($3)"; fail=1; fi
}

read -r mon_x mon_y mon_w mon_h < <(query monitors | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.x) \(.y) \(.width) \(.height)"')
[[ -n ${mon_w:-} ]] || { echo "fullscreen_reveal: output $out not found" >&2; exit 2; }

# A foot window that reports button presses and releases (SGR) into <capture> (as tests/compositor/input_consistency.sh).
cap=$work/foot.cap
: >"$cap"
pointer abs $((mon_w / 2)) $((mon_h - 150)) sleep 50 # windows open on the output under the pointer
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot -e sh -c \
  'stty raw -echo; printf "\033[?1000h\033[?1006h"; exec cat -v >"$0"' "$cap" >/dev/null 2>&1 </dev/null &
pid=$!
pids+=("$pid")
sleep 1.5
geom() { # "<x> <y> <w> <h> <fullscreen> <workspace>" of foot, x/y relative to the output
  query clients | jq -r --argjson p "$pid" --argjson mx "$mon_x" --argjson my "$mon_y" \
    '.[] | select(.pid == $p) | "\(.at[0] - $mx) \(.at[1] - $my) \(.size[0]) \(.size[1]) \(.fullscreen) \(.workspace.name)"' | head -1
}
sgr_since() { tail -c +"$(($2 + 1))" "$1" 2>/dev/null | grep -aoE '\[<[0-9]+;[0-9]+;[0-9]+[Mm]' | tr '\n' ' '; }
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }

read -r x0 y0 w0 h0 fs0 _ < <(geom)
[[ -n ${w0:-} && $fs0 == 0 ]] || { say "setup error: foot not found or not floating"; exit 2; }
say "fullscreen_reveal: nested pid $hypr_pid, output $out ${mon_w}x${mon_h}; foot ${w0}x${h0} at ($x0,$y0)"

# Full screen through the zoom light with Alt held (zoom_restore.sh case 6).
"$root/scripts/dev/keys.sh" -M alt -s 1500 -m alt >>"$log" 2>&1 &
keys=$!
sleep 0.4
pointer abs $((x0 + GF_TB_ZOOM_X)) $((y0 - GF_TB_MID)) sleep 50 click sleep 700
wait "$keys" 2>/dev/null
read -r _ _ _ _ fs _ < <(geom)
[[ $fs == 2 ]] || { say "setup error: foot did not enter full screen (fullscreen ${fs:-?})"; exit 2; }

inset=$(query layers | jq -r --arg o "$out" '[.[$o].levels[][]? | select(.namespace == "grassfield-menubar") | .h] | max // 0')
[[ $inset =~ ^[0-9]+$ ]] || inset=0
bar_y=$((inset + GF_TB_MID))
reveal() { pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 100 abs $((mon_w / 2)) 0 sleep 250; } # from the content to the top edge
say "  menu bar ${inset} px: the revealed bar's middle at y $bar_y"

lrun0=$(log_at) # step 4's own plugin line is counted from here
say "1 control: a click in the content reaches foot"
l0=$(log_at)
off=$(size_of "$cap")
pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 150 click sleep 400
ev=$(sgr_since "$cap" "$off")
[[ $ev == *M* && $ev == *m* ]]
check "foot reports the press and the release" $? "events: ${ev:-none}"
plugin_lines "$l0"

say "2 drag area of the revealed bar"
l0=$(log_at)
off=$(size_of "$cap")
reveal
pointer abs $((mon_w / 2)) "$bar_y" sleep 200 click sleep 500
ev=$(sgr_since "$cap" "$off")
read -r _ _ _ _ fs _ < <(geom)
[[ -z $ev && $fs == 2 ]]
check "the client gets neither the press nor the release; still full screen" $? "events: ${ev:-none}, fullscreen ${fs:-?}"
plugin_lines "$l0"

say "3 minimize light (unavailable in full screen)"
l0=$(log_at)
off=$(size_of "$cap")
reveal
pointer abs "$GF_TB_MIN_X" "$bar_y" sleep 200 click sleep 800
ev=$(sgr_since "$cap" "$off")
read -r _ _ _ _ fs ws < <(geom)
[[ -z $ev && $fs == 2 && $ws != special:minimized ]]
check "inert: still full screen, not minimized, nothing to the client" $? "events: ${ev:-none}, fullscreen ${fs:-?}, workspace ${ws:-?}"
plugin_lines "$l0"

say "4 an Overlay layer over the lights"
l0=$(log_at)
fixlog=$work/fixture.log
WAYLAND_DISPLAY=$sock GF_RV_OUTPUT=$out setsid "$root/scripts/dev/isolated.sh" --name reveal-fixture \
  qs -p "$root/tests/compositor/reveal-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
fixture_pid=$!
pids+=("$fixture_pid")
for _ in $(seq 1 40); do grep -aq "\[rv-fixture\] mapped" "$fixlog" && break; sleep 0.2; done
# The fixture's presses so far, once it logged more than <count> or <seconds> passed (default 3; its log is written by
# another process, late under load).
presses_after() { # <count before> [seconds]
  local n i
  for i in $(seq 1 $((${2:-3} * 10))); do
    n=$(grep -ac "\[rv-fixture\] press" "$fixlog")
    ((n > $1)) && break
    sleep 0.1
  done
  echo "$n"
}
if grep -aq "\[rv-fixture\] mapped" "$fixlog"; then
  sleep 0.5
  # Control: a click on the layer below the bar's band (the layer is 120 px tall): the layer takes input here.
  c0=$(grep -ac "\[rv-fixture\] press" "$fixlog")
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 100 abs 200 100 sleep 200 click sleep 300
  c1=$(presses_after "$c0")
  [[ $((c1 - c0)) -ge 1 ]]
  check "control: a click on the layer outside the bar reaches it" $? "presses to the layer $((c1 - c0))"
  p0=$(grep -ac "\[rv-fixture\] press" "$fixlog")
  off=$(size_of "$cap")
  reveal
  pointer abs "$GF_TB_ZOOM_X" "$bar_y" sleep 200 click sleep 300
  p1=$(presses_after "$p0" 10) # the fixture stays mapped while its own line is awaited
  ev=$(sgr_since "$cap" "$off")
  read -r _ _ _ _ fs _ < <(geom)
  # PASS only on the layer's own press line, with nothing to foot and the window still in full screen. The plugin's line
  # ("left to Hyprland") is written before Hyprland delivers the press: it cannot prove the layer got it, so on its own it
  # gives NOT VERIFIED (counter-review of part B, 2026-10-24); it is looked for at the end (Hyprland writes its log late).
  step4_presses=$((p1 - p0))
  if [[ -n $ev || $fs != 2 ]]; then
    check "the layer gets the press; foot nothing; still full screen" 1 "presses to the layer $step4_presses, foot events: ${ev:-none}, fullscreen ${fs:-?}"
  elif ((step4_presses >= 1)); then
    check "the layer gets the press; foot nothing; still full screen" 0 "presses to the layer $step4_presses, foot events: none, fullscreen 2"
  else
    step4_pending=1
    say "  the layer logged no press in 10 s; foot nothing, still full screen: the plugin's line is looked for at the end"
  fi
else
  check "the Overlay fixture mapped" 1 "see $fixlog"
fi
kill "$fixture_pid" 2>/dev/null
sleep 0.8
plugin_lines "$l0"

say "5 the session locked"
l0=$(log_at)
WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig GRASSFIELD_FOREIGN_LOCKER=1 \
  setsid "$root/scripts/dev/isolated.sh" --name reveal-locker qs -p "$foreign" --no-color >>"$work/locker.log" 2>&1 </dev/null &
locker_pid=$!
locked=""
for _ in $(seq 1 60); do
  locked=$(foreign_ipc status)
  [[ $locked == "locked secure" ]] && break
  sleep 0.1
done
if [[ $locked == "locked secure" ]]; then
  sleep 0.4
  reveal
  pointer abs "$GF_TB_ZOOM_X" "$bar_y" sleep 200 click sleep 600
  foreign_ipc unlock >/dev/null
  # The locker exits once the lock is released; killed instead, it would leave Hyprland's dead-locker screen (still locked).
  exited=0
  for _ in $(seq 1 100); do kill -0 "$locker_pid" 2>/dev/null || { exited=1; break; }; sleep 0.1; done
  ((exited)) || kill "$locker_pid" 2>/dev/null
  locker_pid=""
  sleep 0.6
  read -r _ _ _ _ fs _ < <(geom)
  [[ $fs == 2 ]]
  check "a click on the zoom light's place while locked changes nothing" $? "fullscreen ${fs:-?} after the unlock (want 2)"
  off=$(size_of "$cap")
  pointer abs $((mon_w / 2)) $((mon_h / 2)) sleep 150 click sleep 400
  ev=$(sgr_since "$cap" "$off")
  [[ $exited == 1 && $ev == *M* && $ev == *m* ]]
  check "unlocked again: the locker exited and a click in the content reaches foot" $? "locker exited: $exited, events: ${ev:-none}"
else
  check "the foreign locker locked the session" 1 "status '${locked:-none}' (see $work/locker.log)"
fi

plugin_lines "$l0"

say "6 the way out: top edge, then the zoom light"
l0=$(log_at)
off=$(size_of "$cap")
reveal
pointer abs "$GF_TB_ZOOM_X" "$bar_y" sleep 200 click sleep 800
ev=$(sgr_since "$cap" "$off")
read -r _ _ _ _ fs _ < <(geom)
[[ $fs == 0 && -z $ev ]]
check "full screen left; nothing to the client" $? "fullscreen ${fs:-?} (want 0), events: ${ev:-none}"
plugin_lines "$l0"

notverified=0
if ((${step4_pending:-0})); then
  # Step 4's own line: the third press line over the revealed bar since the run began (2: the drag area taken, 3: minimize
  # taken, 4: left to Hyprland; nothing is logged while locked (5); 6 comes after it). Only that line counts.
  line4=""
  for _ in $(seq 1 100); do
    line4=$(tail -n +"$((lrun0 + 1))" "$hyprlog" 2>/dev/null | grep -a "revealed titlebar: a press" | sed -n 3p)
    [[ -n $line4 ]] && break
    sleep 0.3
  done
  if [[ $line4 == *"left to Hyprland: a layer popup or an Overlay layer"* ]]; then
    notverified=1
    say "  4 the layer gets the press: NOT VERIFIED (the plugin left it to Hyprland, the layer logged no press: ${line4##*\] })"
  else
    check "4 the layer gets the press (step 4's plugin line)" 1 "step 4's line: ${line4:-none}"
  fi
fi
if ! kill -0 "$hypr_pid" 2>/dev/null; then
  say "check: FAIL nested Hyprland pid $hypr_pid is gone"
  fail=1
fi
if ((fail)); then
  say "fullscreen_reveal: FAIL"
elif ((notverified)); then
  say "fullscreen_reveal: NOT VERIFIED (step 4)"
  fail=1
else
  say "fullscreen_reveal: PASS"
fi
say "fullscreen_reveal: log $log"
exit "$fail"
