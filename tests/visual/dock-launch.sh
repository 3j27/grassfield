#!/usr/bin/env bash
# Dock launch and activation on the nested output (Reduce Motion OFF, magnification off), with the real pointer:
#   launch    click a Dock tile of an app that is not running (slow start, window after about 1.2 s): the icon darkens while the
#             button is held, bounces within a frame of the click (about a third of the icon, about 0.5 s per hop), the running dot
#             appears when the window maps, the window has the focus
#   double    two clicks 120 ms apart start the app once
#   forward   a running app with two windows behind another app's window: a click brings both forward, the most recent one has the
#             focus; a second click does not cycle
#   minimized every window of the app minimized: a click restores the most recent one only
#   reopen    every window closed (the tile stays as a recent app): a click starts the app again
#   desktop   a window on another Desktop: a click switches to that Desktop and focuses it
#   reduced   Reduce Motion on: no bounce, the dot still appears
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-launch.sh [part ...]     all parts by default
# Output: .dev/visual/dock-launch/<part>.txt and the frames (PPM). Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

out=$VS_STATE/dock-launch
was_running=0
vs_nested_running && was_running=1
nest() { "$VS_ROOT/scripts/nestctl" "$@"; }
cleanup() {
  [[ -n ${rec_pid:-} ]] && kill "$rec_pid" 2>/dev/null || true
  vs_nested_running && vs_kill_clients || true
  if vs_nested_running; then
    local pid
    for pid in $(nest clients -j 2>/dev/null | jq -r '.[] | select(.class | startswith("gfL")) | .pid' 2>/dev/null); do
      dev_may_signal "$pid" && kill "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

parts=("$@")
(( ${#parts[@]} )) || parts=(launch double forward minimized reopen desktop reduced)
want() { local p; for p in "${parts[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

mkdir -p "$out" "$VS_DEV/share/applications" "$VS_DEV/share/gflaunch"
rm -f "$out"/*
# Test apps: gfLA (magenta) starts slowly: its window appears about 1.2 s after the click; gfLB (cyan) starts at once.
magick -size 64x64 xc:'#ff00ff' "$VS_DEV/share/gflaunch/a.png"
magick -size 64x64 xc:'#00ffff' "$VS_DEV/share/gflaunch/b.png"
printf '[Desktop Entry]\nType=Application\nName=GF Launch A\nExec=sh -c "sleep 1.2; exec foot --app-id gfLA"\nIcon=%s\n' "$VS_DEV/share/gflaunch/a.png" > "$VS_DEV/share/applications/gfLA.desktop"
printf '[Desktop Entry]\nType=Application\nName=GF Launch B\nExec=foot --app-id gfLB\nIcon=%s\n' "$VS_DEV/share/gflaunch/b.png" > "$VS_DEV/share/applications/gfLB.desktop"

kill_class() { # a test window by class (its own process, started by this script)
  local pid
  for pid in $(nest clients -j | jq -r --arg c "$1" '.[] | select(.class == $c) | .pid'); do
    dev_may_signal "$pid" && kill "$pid" 2>/dev/null || true
  done
}
count_class() { nest clients -j | jq --arg c "$1" '[.[] | select(.class == $c)] | length'; }
active_class() { nest activewindow -j | jq -r '.class // ""'; }
wait_count() { # CLASS N SECONDS
  local i
  for i in $(seq 1 $(( $3 * 4 ))); do
    [[ $(count_class "$1") -eq $2 ]] && return 0
    sleep 0.25
  done
  return 1
}
fail=0
check() { # DESCRIPTION CONDITION-EXIT-STATUS
  if [[ $2 -eq 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi
}

vs_session en
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null
vs_ipc dock magnify 1 false >/dev/null
sock=$(vs_nested_wayland)
origin=$(nest monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.x) \(.y)"')
OX=${origin% *}
OY=${origin#* }
REGION="$(( OX + 860 )),$(( OY + 940 )) 220x130"

record() { # NAME MILLISECONDS: frames of REGION in the background until the time is up (rec_pid)
  local name=$1 ms=$2
  (
    i=0
    end=$(( $(date +%s%3N) + ms ))
    : > "$out/$name.log"
    while (( $(date +%s%3N) < end )); do
      t0=$(date +%s%3N)
      WAYLAND_DISPLAY=$sock grim -t ppm -g "$REGION" "$out/$name-$(printf %03d "$i").ppm"
      echo "$i $t0 $(date +%s%3N)" >> "$out/$name.log"
      i=$((i + 1))
    done
  ) &
  rec_pid=$!
}

# recent_tile COLOUR: the app ran once (its window is closed): its tile stays in the recents section. Prints the centre of the icon.
make_recent() { # CLASS COLOUR
  vs_spawn foot --app-id "$1"
  wait_count "$1" 1 10 || { echo "dock-launch: $1 did not start" >&2; return 1; }
  sleep 2
  kill_class "$1"
  wait_count "$1" 0 5
  sleep 2.5
}
locate() { # COLOUR -> "x y"
  "$VS_ROOT/scripts/dev/shot.sh" dock-launch-locate "$VS_OUTPUT" >/dev/null
  python3 -I "$VS_HERE/dock-launch.py" locate "$VS_DEV/shots/dock-launch-locate.png" "$1"
}

if want launch || want reduced; then
  make_recent gfLA magenta
fi

# One launch from the recents tile of gfLA, frames until 4 s after the click. $1 = part name.
launch_gfLA() {
  local name=$1 x y
  read -r x y <<<"$(locate magenta)"
  echo "$name: tile at $x,$y"
  REGION="$(( OX + x - 110 )),$(( OY + 940 )) 220x130"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  record "$name" 5200
  sleep 0.5
  # One pointer process holds the button (a second process would be a second virtual device: its release would be ignored).
  local mark t0
  mark=$(wc -l < "$VS_DEV/shell.log")
  t0=$(date +%s%3N)
  echo "down $t0" > "$out/$name.events"
  echo "up $(( t0 + 600 + 15 ))" >> "$out/$name.events"
  # The time the window shows up in the compositor (polled), for the dot check.
  rm -f "$out/$name.map"
  (
    for _ in $(seq 1 200); do
      if [[ $(count_class gfLA) -ge 1 ]]; then date +%s%3N > "$out/$name.map"; break; fi
      sleep 0.03
    done
  ) &
  vs_pointer down sleep 600 up >/dev/null
  wait "$rec_pid"; rec_pid=""
  wait
  tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch:" > "$out/$name.curve"
}

if want launch; then
  launch_gfLA launch
  python3 -I "$VS_HERE/dock-launch.py" launch "$out" launch magenta | tee "$out/launch.txt"
  check "launch: bounce, press, dot" "${PIPESTATUS[0]}"
  sleep 1
  [[ $(active_class) == gfLA ]]
  check "launch: the new window has the focus (active: $(active_class))" $?
  [[ $(count_class gfLA) -eq 1 ]]
  check "launch: one window" $?
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want double; then
  kill_class gfLA
  wait_count gfLA 0 5
  sleep 2.5
  read -r x y <<<"$(locate magenta)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click sleep 120 click >/dev/null
  sleep 5
  [[ $(count_class gfLA) -eq 1 ]]
  check "double: two clicks 120 ms apart start one window (found $(count_class gfLA))" $?
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want forward || want minimized; then
  kill_class gfLA
  vs_sleep 1
  vs_spawn foot --app-id gfLB
  wait_count gfLB 1 10
  vs_spawn foot --app-id gfLB
  wait_count gfLB 2 10
  vs_spawn foot --app-id gfLA
  wait_count gfLA 1 10
  sleep 2
  [[ $(active_class) == gfLA ]]
  check "forward: setup, gfLA in front (active: $(active_class))" $?
  read -r x y <<<"$(locate cyan)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click >/dev/null
  sleep 1
  nest clients -j | jq -c '[.[] | {class, focusHistoryID}]' > "$out/forward.txt"
  cat "$out/forward.txt"
  [[ $(active_class) == gfLB ]]
  check "forward: gfLB has the focus (active: $(active_class))" $?
  top2=$(nest clients -j | jq '[.[] | select(.focusHistoryID <= 1 and .class == "gfLB")] | length')
  [[ $top2 -eq 2 ]]
  check "forward: both gfLB windows are the two most recent (found $top2)" $?
  first=$(nest activewindow -j | jq -r .address)
  vs_pointer click >/dev/null
  sleep 1
  [[ $(nest activewindow -j | jq -r .address) == "$first" ]]
  check "forward: a second click does not cycle the windows" $?
fi

if want minimized; then
  # Minimize every gfLB window (the focused one, then the next).
  for i in 1 2 3; do
    [[ $(active_class) == gfLB ]] || break
    vs_ipc windows minimize >/dev/null
    sleep 1.2
  done
  min=$(nest clients -j | jq '[.[] | select(.class == "gfLB" and .workspace.name == "special:minimized")] | length')
  [[ $min -eq 2 ]]
  check "minimized: setup, both gfLB windows minimized (found $min)" $?
  read -r x y <<<"$(locate cyan)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click >/dev/null
  sleep 2
  min=$(nest clients -j | jq '[.[] | select(.class == "gfLB" and .workspace.name == "special:minimized")] | length')
  [[ $min -eq 1 && $(active_class) == gfLB ]]
  check "minimized: one gfLB window restored and focused, one still minimized (minimized: $min, active: $(active_class))" $?
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want reopen; then
  kill_class gfLB
  kill_class gfLA
  wait_count gfLB 0 5
  sleep 3
  read -r x y <<<"$(locate cyan)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click >/dev/null
  wait_count gfLB 1 10
  check "reopen: a click on the tile of an app with no window starts it again (windows: $(count_class gfLB))" $?
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want desktop; then
  nest dispatch 'hl.dsp.focus({ workspace = "3" })' >/dev/null
  sleep 1
  vs_spawn foot --app-id gfLA
  wait_count gfLA 1 10
  sleep 1
  ws_a=$(nest clients -j | jq -r '.[] | select(.class == "gfLA") | .workspace.id')
  nest dispatch 'hl.dsp.focus({ workspace = "2" })' >/dev/null
  sleep 1.5
  [[ $(nest activeworkspace -j | jq -r .id) != "$ws_a" ]]
  check "desktop: setup, gfLA on Desktop $ws_a, another Desktop shown" $?
  read -r x y <<<"$(locate magenta)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click >/dev/null
  sleep 1.5
  [[ $(nest activeworkspace -j | jq -r .id) == "$ws_a" && $(active_class) == gfLA ]]
  check "desktop: the click switched to Desktop $ws_a and focused gfLA (now $(nest activeworkspace -j | jq -r .id), active $(active_class))" $?
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want reduced; then
  kill_class gfLA
  kill_class gfLB
  sleep 5
  vs_ipc controlcenter reduceMotion true >/dev/null
  sleep 0.5
  launch_gfLA reduced
  # No bounce: no frame with the icon lifted; the dot still appears.
  python3 -I "$VS_HERE/dock-launch.py" launch "$out" reduced magenta > "$out/reduced-analysis.txt" || true
  grep -E "^(frames|dot|map)" "$out/reduced-analysis.txt"
  [[ ! -s "$out/reduced.curve" ]]
  check "reduced: no bounce with Reduce Motion (bounce samples logged: $(wc -l < "$out/reduced.curve"))" $?
  grep -q "^dot: .*first seen [0-9]" "$out/reduced-analysis.txt"
  check "reduced: the running dot appears" $?
  vs_ipc controlcenter reduceMotion false >/dev/null
fi

echo "dock-launch: $(( fail ? 1 : 0 )) (0 = all checks passed); frames and logs in $out"
exit "$fail"
