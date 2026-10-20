#!/usr/bin/env bash
# Dock drag-out under interruption (owner model: any interruption during a tile drag cancels the removal, the tile glides back).
# Nested session only, run as a BARE command (reference machine). The nested session this script starts is torn down on exit.
#   tests/visual/dock-drag-interrupt.sh interrupt [REPS=1] ["trigger ..."]   every trigger x 4 tile positions (held above the Dock
#                                                                           window / inside it, still / moving) must KEEP the pin;
#                                                                           above-still also with the release at the held point
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
FX=875
DY=1032
ABOVE=600   # above the Dock window (top edge y=830)
INSIDE=900  # inside the window, above the shelf
cfg=$VS_DEV/config/grassfield.json
vs_spawn foot --app-id gfdockA
sleep 1.5
vs_spawn foot --app-id gfdockB
sleep 3
vs_park
pinned() { vs_ipc dock pinned | jq -c .; }
want='["foot"]'
echo "start pinned=$(pinned) mode=$mode"
[[ $(pinned) == "$want" ]] || { echo "dock-drag-interrupt: start state is $(pinned), not $want" >&2; exit 1; }
restore() {
  if [[ $(pinned) != "$want" ]]; then
    vs_session en >/dev/null 2>&1
    sleep 1
    vs_spawn foot --app-id gfdockA
    sleep 1.5
    vs_spawn foot --app-id gfdockB
    sleep 3
    vs_park
  fi
  [[ $(pinned) == "$want" ]] || echo "  (restore failed: $(pinned))"
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
P="abs $FX $DY sleep 200 down sleep 200"
park="abs $VS_PARK_X $VS_PARK_Y"

bus() { cat "$VS_DEV/bus.address"; }
kill_class() {
  local pid
  for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg c "$1" '.[] | select(.class == $c) | .pid'); do
    dev_may_signal "$pid" && kill "$pid"
  done
}
trig_overview() { vs_ipc overview open; }
end_overview() { vs_ipc overview close; sleep 1.5; }
trig_apps() { vs_ipc apps open; }
end_apps() { vs_ipc apps close; sleep 1.5; }
trig_search() { vs_ipc search open files; }
end_search() { vs_ipc search close; sleep 1; }
trig_switcher() { vs_ipc switcher next ""; }
end_switcher() { vs_ipc switcher cancel; sleep 1; }
trig_dockmenu() { vs_ipc dock menu 1 GF-REF; }
end_dockmenu() { vs_ipc menubar close; sleep 1; }
trig_ncenter() { vs_ipc notifications toggleCenter; }
end_ncenter() { vs_ipc notifications toggleCenter; sleep 1; }
trig_ccenter() { vs_ipc menubar open controlcenter GF-REF; }
end_ccenter() { vs_ipc menubar close; sleep 1; }
trig_menubarmenu() { vs_ipc menubar open system GF-REF; }
end_menubarmenu() { vs_ipc menubar close; sleep 1; }
trig_windowopen() { vs_spawn foot --app-id gfwin; }
end_windowopen() { kill_class gfwin; sleep 1.5; }
pre_windowclose() { vs_spawn foot --app-id gfwin; sleep 2; }
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
  if [[ $style == wiggle ]]; then
    for k in 1 2 3 4 5 6 7 8 9 10; do path="$path drag $((FX + 25)) $hy drag $((FX - 25)) $hy"; done
  else
    path="sleep 3000"
  fi
  if [[ $rel == held ]]; then
    tail="sleep 150 up sleep 150 $park"
  else
    tail="drag $FX $DY sleep 150 up sleep 150 $park"
  fi
  restore
  if declare -F "pre_$trig" >/dev/null; then "pre_$trig" >/dev/null 2>&1; fi
  vs_pointer $P drag $FX $hy $path $tail >/dev/null &
  ptr_pid=$!
  sleep 1.5
  "trig_$trig" >/dev/null 2>&1
  wait "$ptr_pid"
  ptr_pid=""
  sleep 1.2
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

# fn NAME DRAG-STEPS...: a deliberate drag that must remove the pin.
fn() {
  local name=$1
  shift
  restore
  vs_pointer $P "$@" >/dev/null
  sleep 1.3
  res "$name" removed "$(pinned)"
}

reps=${2:-1}
rc=0
case $mode in
  interrupt)
    for r in $(seq 1 "$reps"); do
      for t in ${3:-overview apps search switcher dockmenu ncenter ccenter menubarmenu windowopen windowclose appquit workspace banner}; do
        pos_run "$t" "$r"
      done
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
      restore
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
      for k in 1 2 3 4 5 6 7 8 9 10; do path="$path drag $((FX + 25)) $hy drag $((FX - 25)) $hy"; done
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
    echo "usage: dock-drag-interrupt.sh interrupt|deliberate|lock ..." >&2
    exit 2
    ;;
esac
echo "SUMMARY mode=$mode ok=$pass fail=$failn"
grep -iE "Dock.qml|TypeError|ReferenceError" "$VS_DEV/shell.log" 2>/dev/null | tail -5
[[ $failn -eq 0 ]]
