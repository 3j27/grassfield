#!/usr/bin/env bash
# Stress test of the Dock drag: the pinned foot tile is never lost by a drag that comes back into the shelf before the release.
# Repeats the pattern of the contrast harness (press the pinned tile, drag far above the shelf so "Remove" shows, hold, drag back
# onto its slot, release) N times, in three variants: plain, a window opening during the drag (the rebuild waits for the release),
# and a very short hold. After every iteration the live pinned list (qs ipc: dock pinned) must still be ["foot"]. A last drag that
# is released far above the Dock must remove the tile: it proves the pointer really drives the drag.
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-drag-stress.sh [ITERATIONS=50]
# Exit status 1 when the pinned list changed (the iteration is named) or the control drag did not remove the tile.
source "$(dirname "$0")/lib.sh"

n=${1:-50}
was_running=0
vs_nested_running && was_running=1
cleanup() {
  [[ -n ${ptr_pid:-} ]] && kill "$ptr_pid" 2>/dev/null || true
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

vs_session en
vs_reset dark 0.25
FOOT_X=875 DOCK_Y=1032 UP_Y=900
cfg=$VS_DEV/config/grassfield.json

# Same tiles as the contrast harness: pinned foot, then the two running test apps.
vs_spawn foot --app-id gfdockA
vs_sleep 1.5
vs_spawn foot --app-id gfdockB
vs_sleep 3
vs_park

pinned() { vs_ipc dock pinned | tr -d ' '; }
want='["foot"]'
[[ $(pinned) == "$want" ]] || { echo "dock-drag-stress: start state is $(pinned), not $want" >&2; exit 1; }

fail=0
lost=0
for i in $(seq 1 "$n"); do
  case $(( i % 3 )) in
    0) hold=100 ;;
    1) hold=500 ;;
    *) hold=1500 ;;
  esac
  with_window=$(( i % 5 == 0 ))
  vs_pointer abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep "$hold" drag $FOOT_X $DOCK_Y sleep 100 up sleep 100 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
  ptr_pid=$!
  if (( with_window )); then
    # A window opens while the tile is held out: the rebuild must wait for the release and must not touch the pin.
    sleep 0.9
    vs_spawn foot --app-id gfstress
  fi
  wait "$ptr_pid" || true
  ptr_pid=""
  sleep 0.6
  got=$(pinned)
  if [[ $got != "$want" ]]; then
    echo "iteration $i (hold ${hold} ms, window during drag: $with_window): pinned is $got"
    fail=1
    lost=$(( lost + 1 ))
    break
  fi
  if (( with_window )); then
    for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.class == "gfstress") | .pid'); do
      dev_may_signal "$pid" && kill "$pid" || true
    done
    sleep 1.5
    [[ $(pinned) == "$want" ]] || { echo "iteration $i: pinned changed after the window closed: $(pinned)"; fail=1; break; }
  fi
done
echo "drags: $i, pinned changed: $lost (live list: $(pinned))"
[[ $(jq -c '.dock.pinned' "$cfg") == "$want" ]] || { echo "config file dock.pinned is $(jq -c '.dock.pinned' "$cfg")"; fail=1; }

# Control: released far above the Dock, the (not running) pinned tile is removed. Needs foot with no window: the test apps are
# not foot, so it has none.
sleep 3
vs_pointer abs $FOOT_X $DOCK_Y sleep 200 down sleep 200 drag $FOOT_X $UP_Y sleep 3000 up sleep 200 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
ptr_pid=$!
sleep 2
"$VS_ROOT/scripts/dev/shot.sh" dock-drag-stress-control "$VS_OUTPUT" >/dev/null
wait "$ptr_pid" || true
ptr_pid=""
sleep 1
if [[ $(pinned) == "[]" ]]; then
  echo "control: released above the Dock removes the tile: ok"
else
  echo "control: released above the Dock left pinned = $(pinned) (the drag did not engage; see $VS_DEV/shots/dock-drag-stress-control.png)"
  fail=1
fi
exit $fail
