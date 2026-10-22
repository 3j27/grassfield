#!/usr/bin/env bash
# Dock drag-out under interruption (owner model: any interruption during a tile drag cancels the removal, the tile glides back).
# Nested session only, run as a BARE command (reference machine). The nested session this script starts is torn down on exit.
#   tests/visual/dock-drag-interrupt.sh interrupt [REPS=1] ["trigger ..."]   every trigger x 4 tile positions (held above the Dock
#                                                                           window / inside it, still / moving) must KEEP the pin;
#                                                                           above-still also with the release at the held point
#   tests/visual/dock-drag-interrupt.sh holddrag [REPS=1]  (alias hd)       a press that opened the hold menu (forced: dock forcehold)
#                                                                           refuses its drag and changes no pin (drag out, and sideways
#                                                                           = reorder); the next press is a normal one
#   tests/visual/dock-drag-interrupt.sh deliberate [REPS=1]                 deliberate drag-outs must REMOVE the pin, 100 %
#   tests/visual/dock-drag-interrupt.sh lock POS                            LAST, alone: POS = above-still | above-moving |
#                                                                           inside-still | inside-moving. Locks the session while
#                                                                           the tile is held, releases, checks the pins from the
#                                                                           config file, stops the session. Nothing is ever typed
#                                                                           into the lock screen.
# Triggers: overview apps search switcher dockmenu ncenter ccenter menubarmenu windowopen windowclose appquit workspace banner.
# Prints one line per trial and a summary; exit status 1 when any trial failed. On GF-REF the Dock window's top edge is y=830.
source "$(dirname "$0")/lib.sh"
set +e

mode=${1:-interrupt}
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${ptr_pid:-} ]] && kill "$ptr_pid" 2>/dev/null
  vs_nested_running && vs_kill_clients
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

vs_session en || exit 1
vs_reset dark 0.25
# x of the pinned foot tile, from the Dock itself (a crash-report window or another extra tile moves it; the old fixed 927 did not follow).
# FX=NNN in the environment still overrides it.
FX_FORCED=${FX:-}
refresh_fx() {
  [[ -n $FX_FORCED ]] && { FX=$FX_FORCED; return 0; }
  local xy
  xy=$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("foot")')" "$VS_OUTPUT" 2>/dev/null)
  [[ $xy =~ ^[0-9]+\ [0-9]+$ ]] || return 1
  FX=${xy% *}
}
FX=927
DY=1032
ABOVE=600   # above the Dock window (top edge y=830)
INSIDE=900  # inside the window, above the shelf
cfg=$VS_DEV/config/grassfield.json
vs_spawn foot --app-id gfdockA
sleep 1.5
vs_spawn foot --app-id gfdockB
sleep 3
vs_park
pinned() { vs_ipc dock pinned 2>/dev/null | jq -c . 2>/dev/null; }
want='["foot"]'
dock_ready_start() {
  local i
  for i in $(seq 1 40); do vs_ipc dock tiles 2>/dev/null | jq -e 'index("foot") != null' >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}
dock_ready_start && refresh_fx
echo "start pinned=$(pinned) mode=$mode foot tile x=$FX"
[[ $(pinned) == "$want" ]] || { echo "dock-drag-interrupt: start state is $(pinned), not $want" >&2; exit 1; }
# The shell is up (IPC answers) and the Dock shows the pinned tile: a trial that starts before that would test nothing.
dock_ready() {
  local i
  for i in $(seq 1 40); do
    vs_ipc lock status >/dev/null 2>&1 && vs_ipc dock tiles 2>/dev/null | jq -e 'index("foot") != null' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
# Brings the session back to the start state. Returns 1 when it could not: the trial is then a FAIL, never a pass without a test.
restore() {
  local attempt
  for attempt in 1 2 3; do
    if [[ $(pinned) != "$want" ]]; then
      # Quickshell sometimes crashes within 10 s of a restart (the log then says so: "crashed within 10 seconds of launching"): the
      # restart is repeated, up to three times, and a restore that never works is a FAIL of the trial.
      vs_session en > "$VS_DEV/restore.log" 2>&1
      sleep 1
      vs_spawn foot --app-id gfdockA
      sleep 1.5
      vs_spawn foot --app-id gfdockB
      sleep 3
      vs_park
    fi
    if dock_ready && [[ $(pinned) == "$want" ]]; then
      refresh_fx
      return 0
    fi
    echo "  (restore attempt $attempt failed: pinned=$(pinned 2>/dev/null) tiles=$(vs_ipc dock tiles 2>&1 | head -c 120))"
  done
  tail -n 4 "$VS_DEV/restore.log" 2>/dev/null | sed 's/^/    restore.log: /'
  return 1
}
pass=0
failn=0
res() {
  local ok=FAIL
  if [[ $2 == removed && $3 == "[]" ]] || [[ $2 == kept && $3 == "$want" ]]; then
    ok=ok
    pass=$((pass + 1))
  else
    failn=$((failn + 1))
    cp "$VS_DEV/shell.log" "$VS_DEV/shell.fail.$failn.log" 2>/dev/null
  fi
  echo "$(date +%T) $1 expect=$2 got=$3 $ok"
}
restore_failed() { # LABEL: a trial whose start state could not be restored is a failure, not a pass
  failn=$((failn + 1))
  echo "$(date +%T) $1 restore failed, not tested: FAIL"
}
P="abs $FX $DY sleep 200 down sleep 200"
park="abs $VS_PARK_X $VS_PARK_Y"

bus() { cat "$VS_DEV/bus.address"; }
kill_class() {
  local pid
  for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg c "$1" '.[] | select(.class == $c) | .pid'); do
    dev_may_signal "$pid" && kill "$pid"
  done
}
trig_none() { :; }
end_none() { :; }
trig_overview() { vs_ipc overview open; }
end_overview() { vs_ipc overview close; sleep 1.5; }
trig_apps() { vs_ipc apps open; }
end_apps() { vs_ipc apps close; sleep 1.5; }
trig_search() { vs_ipc search open files; }
end_search() { vs_ipc search close; sleep 1; }
trig_switcher() { vs_ipc switcher next ""; }
end_switcher() { vs_ipc switcher cancel; sleep 1; }
trig_dockmenu() { vs_ipc dock menu "$(vs_ipc dock tiles | jq 'index("foot")')" GF-REF; } # the pinned foot tile by its key: the index moves with the fixed tiles
end_dockmenu() { vs_ipc menubar close; sleep 1; }
trig_ncenter() { vs_ipc notifications toggleCenter; }
end_ncenter() { vs_ipc notifications toggleCenter; sleep 1; }
trig_ccenter() { vs_ipc menubar open controlcenter GF-REF; }
end_ccenter() { vs_ipc menubar close; sleep 1; }
trig_menubarmenu() { vs_ipc menubar open system GF-REF; }
end_menubarmenu() { vs_ipc menubar close; sleep 1; }
trig_windowopen() { vs_spawn foot --app-id gfwin; }
end_windowopen() { kill_class gfwin; sleep 1.5; }
# The window must be OPEN before the press: a window mapping during the press makes Qt end it (no drag), which the old fixed sleep let
# happen (those trials passed without ever dragging).
pre_windowclose() {
  local i
  vs_spawn foot --app-id gfwin
  for i in $(seq 1 60); do
    [[ $("$VS_ROOT/scripts/nestctl" clients -j | jq '[.[] | select(.class == "gfwin")] | length') -ge 1 ]] && break
    sleep 0.25
  done
  sleep 2
}
trig_windowclose() { kill_class gfwin; }
end_windowclose() { sleep 1; }
trig_appquit() { kill_class gfdockB; }
end_appquit() { vs_spawn foot --app-id gfdockB; sleep 3; }
# GF-REF sits on Space 2 (vs_canonical_workspaces): the switch goes to Space 3 and back.
trig_workspace() { "$VS_ROOT/scripts/nestctl" dispatch 'hl.dsp.focus({ workspace = "3" })'; }
end_workspace() { "$VS_ROOT/scripts/nestctl" dispatch 'hl.dsp.focus({ workspace = "2" })'; sleep 1; }
trig_banner() { DBUS_SESSION_BUS_ADDRESS=$(bus) notify-send -a gfdockB -t 3000 Interrupt "Banner during a drag"; }
end_banner() { sleep 3.5; }
trig_lock() { vs_ipc lock lock; }
end_lock() { :; }

# trial TRIGGER HY STYLE RELEASE LABEL: press the tile, go out to (FX,HY), then keep moving (wiggle) or hold still, fire the
# trigger 1.5 s into the hold, then release on the slot (RELEASE slot) or right where the tile was held (RELEASE held). The pin
# must stay.
trial() {
  local trig=$1 hy=$2 style=$3 rel=$4 label=$5 path="" k tail
  # The pointer path is built per attempt, after the pre-step: a window opened by it adds a Dock tile and moves the foot tile
  # (the old fixed x then pressed between tiles and the "kept" results were vacuous).
  build_path() {
    path=""
    if [[ $style == wiggle ]]; then
      for k in 1 2 3 4 5 6 7 8 9 10; do path="$path drag $((FX + 25)) $hy sleep 100 drag $((FX - 25)) $hy sleep 100"; done
    else
      path="sleep 3000"
    fi
    if [[ $rel == held ]]; then
      tail="sleep 150 up sleep 150 $park"
    else
      tail="drag $FX $DY sleep 150 up sleep 150 $park"
    fi
    P="abs $FX $DY sleep 200 down sleep 200"
  }
  # A trial counts only when the shell logged the drag start (dock-launch: drag-start): a pointer that never dragged (released 1-3 ms
  # after the press) proves nothing and is repeated, up to three times, then reported as not tested (FAIL), never as a pass.
  local attempt mark started=0
  for attempt in 1 2 3; do
    restore || { restore_failed "$label"; return; }
    if declare -F "pre_$trig" >/dev/null; then "pre_$trig" >/dev/null 2>&1; fi
    refresh_fx
    build_path
    mark=$(wc -l < "$VS_DEV/shell.log")
    vs_pointer $P drag $FX $hy $path $tail >/dev/null &
    ptr_pid=$!
    sleep 1.5
    "trig_$trig" >/dev/null 2>&1
    wait "$ptr_pid"
    ptr_pid=""
    sleep 1.2
    if tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep -q "dock-launch: drag-start"; then
      started=1
      break
    fi
    echo "  ($label: no drag started on attempt $attempt, not tested: again; shell log lines of the attempt: $(tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep -c .), dock lines: $(tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch:" | sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' | tr '\n' '|' | cut -c1-200); clients: $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '[.[].class] | join(",")'))"
    "end_$trig" >/dev/null 2>&1
    # the pin may have been touched by nothing; bring the state back
  done
  if (( ! started )); then
    failn=$((failn + 1))
    echo "$(date +%T) $label no drag ever started, not tested: FAIL"
    "end_$trig" >/dev/null 2>&1
    return
  fi
  res "$label" kept "$(pinned)"
  "end_$trig" >/dev/null 2>&1
}
pos_run() { # TRIGGER REP: the four positions (+ released-at-held-point above the window)
  local t=$1 r=$2
  trial "$t" $ABOVE still slot "${t}_above_still_r$r"
  trial "$t" $ABOVE wiggle slot "${t}_above_moving_r$r"
  trial "$t" $INSIDE still slot "${t}_inside_still_r$r"
  trial "$t" $INSIDE wiggle slot "${t}_inside_moving_r$r"
  trial "$t" $ABOVE still held "${t}_above_still_releaseheld_r$r"
}

# hd LABEL KEY KIND: the press on the tile of KEY opened the hold menu, then the pointer drags it. KIND above: out above the Dock and release
# there (the removal case); side: along the shelf to just left of the pinned foot tile (the reorder case, KEY = a running unpinned app,
# which a drop before a pinned tile would pin). The press becomes the menu's: the drag must be REFUSED (the shell logs drag-refused, never
# drag-start), nothing moves, and the pins must not change (neither unpin nor reorder).
# The menu is forced deterministically: `dock forcehold true` marks every press on an app tile as having opened the hold menu the moment
# it goes down (no popup, no timing against the 550 ms timer). A trial counts only when the shell logged pressed true, the forced menu
# and then drag-refused; a press that never reached the Dock is repeated (four times), then reported as not tested (FAIL). A drag-start
# after the menu is a FAIL at once.
hd() {
  local label=$1 key=$2 kind=$3 attempt mark ok=0 lines idx cx cy fx steps before
  for attempt in 1 2 3 4; do
    restore || { restore_failed "$label"; return; }
    before=$(pinned)
    idx=$(vs_ipc dock tiles | jq --arg k "$key" 'index($k)')
    fx=$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("foot")')" "$VS_OUTPUT" | cut -d' ' -f1)
    read -r cx cy <<<"$(vs_ipc dock centre "$idx" "$VS_OUTPUT")"
    if ! [[ $cx =~ ^[0-9]+$ && $fx =~ ^[0-9]+$ ]]; then
      echo "  ($label: attempt $attempt: no tile '$key' in the Dock, not tested: again)"
      continue
    fi
    if [[ $kind == side ]]; then steps="drag $((fx - 30)) $cy sleep 150 drag $((fx - 34)) $cy"; else steps="drag $cx $ABOVE sleep 150 drag $((cx + 25)) $ABOVE"; fi
    vs_ipc dock forcehold true >/dev/null
    mark=$(wc -l < "$VS_DEV/shell.log")
    vs_pointer abs "$cx" "$cy" sleep 200 down sleep 200 $steps sleep 400 up sleep 300 $park >/dev/null
    sleep 1
    vs_ipc dock forcehold false >/dev/null
    lines=$(tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|menu-by-hold\|drag-start\|drag-refused\)")
    if grep -q "drag-start" <<<"$lines"; then
      failn=$((failn + 1))
      echo "$(date +%T) $label a drag STARTED after the hold menu ($(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' <<<"$lines" | tr '\n' '|')): FAIL"
      vs_ipc menubar close >/dev/null 2>&1
      return
    fi
    if grep -q "pressed true" <<<"$lines" && grep -q "menu-by-hold (forced)" <<<"$lines" && grep -q "drag-refused" <<<"$lines"; then
      ok=1
      break
    fi
    echo "  ($label: attempt $attempt: no press / forced menu / drag-refused in the log ($(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' <<<"$lines" | tr '\n' '|')), not tested: again)"
    vs_ipc menubar close >/dev/null 2>&1
  done
  if (( ! ok )); then
    failn=$((failn + 1))
    echo "$(date +%T) $label never gave press + forced menu + drag-refused, not tested: FAIL"
    return
  fi
  echo "  ($label: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' <<<"$lines" | tr '\n' '|'); pins before $before)"
  res "$label" kept "$(pinned)"
  vs_ipc menubar close >/dev/null 2>&1
  sleep 1
}

# hd_then_deliberate LABEL: a press right after a hold-menu press is a normal press: the drag of the first press is refused, a deliberate
# drag-out of the next press (no menu, no interruption) still removes the pin.
hd_then_deliberate() {
  local label=$1 attempt mark lines cx cy ok=0
  for attempt in 1 2 3 4; do
    restore || { restore_failed "$label"; return; }
    read -r cx cy <<<"$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("foot")')" "$VS_OUTPUT")"
    vs_ipc dock forcehold true >/dev/null
    mark=$(wc -l < "$VS_DEV/shell.log")
    vs_pointer abs "$cx" "$cy" sleep 200 down sleep 200 drag "$cx" $ABOVE sleep 300 up sleep 300 $park >/dev/null
    sleep 1
    vs_ipc dock forcehold false >/dev/null
    vs_ipc menubar close >/dev/null 2>&1
    lines=$(tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(drag-start\|drag-refused\)")
    grep -q "drag-refused" <<<"$lines" && ! grep -q "drag-start" <<<"$lines" && [[ $(pinned) == "$want" ]] && { ok=1; break; }
    echo "  ($label: attempt $attempt: the first press was not refused cleanly ($(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' <<<"$lines" | tr '\n' '|')) pins $(pinned), not tested: again)"
  done
  if (( ! ok )); then
    failn=$((failn + 1))
    echo "$(date +%T) $label the hold-menu press was never refused cleanly, not tested: FAIL"
    return
  fi
  refresh_fx
  mark=$(wc -l < "$VS_DEV/shell.log")
  vs_pointer abs "$cx" "$cy" sleep 200 down sleep 200 drag "$cx" $ABOVE sleep 600 up sleep 300 $park >/dev/null
  sleep 1.3
  if ! tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep -q "dock-launch: drag-start"; then
    failn=$((failn + 1))
    echo "$(date +%T) $label the deliberate drag after the menu press never started, not tested: FAIL"
    return
  fi
  res "$label" removed "$(pinned)"
}

# fn NAME DRAG-STEPS...: a deliberate drag that must remove the pin.
fn() {
  local name=$1
  shift
  restore || { restore_failed "$name"; return; }
  vs_pointer $P "$@" >/dev/null
  sleep 1.3
  res "$name" removed "$(pinned)"
}

hd_trials() { # REP
  hd "holdmenu_then_drag_out_r$1" foot above
  hd "holdmenu_then_drag_sideways_reorder_r$1" gfdockA side
  hd_then_deliberate "holdmenu_then_next_press_removes_r$1"
}

reps=${2:-1}
rc=0
case $mode in
  interrupt)
    for r in $(seq 1 "$reps"); do
      for t in ${3:-overview apps search switcher dockmenu ncenter ccenter menubarmenu windowopen windowclose appquit workspace banner}; do
        pos_run "$t" "$r"
      done
      hd_trials "$r"
    done
    ;;
  holddrag|hd)
    # Only the hold-menu-press trials (also part of `interrupt`): drag out above, drag sideways (reorder), and the next press is normal.
    for r in $(seq 1 "$reps"); do
      hd_trials "$r"
    done
    ;;
  deliberate)
    for r in $(seq 1 "$reps"); do
      fn "fn_far_r$r" drag $FX 500 sleep 600 up sleep 300 $park
      fn "fn_top_edge_r$r" drag $FX 0 sleep 400 up sleep 300 $park
      fn "fn_corner00_r$r" drag 0 0 sleep 400 up sleep 300 $park
      fn "fn_slow_far_r$r" drag $FX 990 sleep 300 drag $FX 940 sleep 300 drag $FX 860 sleep 300 drag $FX 700 sleep 300 drag $FX 400 sleep 400 up sleep 300 $park
      fn "fn_hold2s_far_r$r" drag $FX 500 sleep 2000 up sleep 300 $park
      fn "fn_flick_far_r$r" drag $FX 500 up sleep 300 $park
      fn "fn_leave_reenter_r$r" drag $FX 500 sleep 300 drag $FX 880 up sleep 300 $park
      fn "fn_leave_reenter_fast_r$r" drag $FX 900 sleep 300 abs $FX 800 abs $FX 880 up sleep 300 $park
      fn "fn_inside_window_r$r" drag $FX 880 sleep 500 up sleep 300 $park
    done
    ;;
  race)
    # The release comes 0-50 ms around the opening of Search while the tile is held ABOVE the Dock window: a release that reaches
    # the drag handler before the interruption event must not remove. The trigger is started at a swept delay (the ipc call has
    # its own latency); the real offset (release minus first interruption, ms, from the DBG lines of the shell log when present) is
    # printed per trial.
    for k in $(seq 0 $((${2:-20} - 1))); do
      restore || { restore_failed "race_${3:-search}_k$k"; continue; }
      delay=$(awk -v k="$k" 'BEGIN { printf "%.3f", '"${4:-1.80}"' + k * 0.025 }')
      vs_pointer $P drag $FX $ABOVE sleep 1500 up sleep 300 $park >/dev/null &
      ptr_pid=$!
      sleep "$delay"
      "trig_${3:-search}" >/dev/null 2>&1
      wait "$ptr_pid"
      ptr_pid=""
      sleep 1.2
      off=$(awk '/DBG active/ && $NF == "true" { i = 0; r = 0 } /DBG interrupt/ && !i { i = $NF } /DBG grab/ && $(NF-3) == 2 && $(NF-2) == 8 { r = $(NF-4) } END { if (i && r) print r - i; else print "n/a" }' "$VS_DEV/shell.log")
      res "race_${3:-search}_k${k}_delay${delay}_release_minus_open=${off}ms" kept "$(pinned)"
      "end_${3:-search}" >/dev/null 2>&1
    done
    ;;
  lock)
    pos=${2:-above-still}
    case $pos in
      above-still) hy=$ABOVE style=still ;;
      above-moving) hy=$ABOVE style=wiggle ;;
      inside-still) hy=$INSIDE style=still ;;
      inside-moving) hy=$INSIDE style=wiggle ;;
      *) echo "unknown position $pos" >&2; exit 2 ;;
    esac
    path=""
    if [[ $style == wiggle ]]; then
      for k in 1 2 3 4 5 6 7 8 9 10; do path="$path drag $((FX + 25)) $hy sleep 100 drag $((FX - 25)) $hy sleep 100"; done
    else
      path="sleep 3000"
    fi
    vs_pointer $P drag $FX $hy $path drag $FX $DY sleep 150 up sleep 150 $park >/dev/null &
    ptr_pid=$!
    sleep 1.5
    vs_ipc lock lock >/dev/null 2>&1
    wait "$ptr_pid"
    ptr_pid=""
    sleep 1.5
    got=$(jq -c '.dock.pinned' "$cfg")
    res "lock_${pos}_config" kept "$got"
    echo "lock status: $(vs_ipc lock status 2>&1)"
    "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1
    was_running=1
    ;;
  *)
    echo "usage: dock-drag-interrupt.sh interrupt|holddrag|deliberate|race|lock ... (holddrag, alias hd: [REPS])" >&2
    exit 2
    ;;
esac
echo "SUMMARY mode=$mode ok=$pass fail=$failn"
grep -iE "Dock.qml|TypeError|ReferenceError" "$VS_DEV/shell.log" 2>/dev/null | tail -5
[[ $failn -eq 0 ]]
