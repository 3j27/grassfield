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
#   hold      a press under 550 ms is a click (launches), a press over it opens the Dock menu and launches nothing
#   holdtiles a 900 ms hold on the Apps tile, the Trash tile and a minimized-window tile (no Dock menu) still clicks on release
#   retitle   eight clicks while the focused window retitles every 20 ms all tap (title and focus events never cancel a click)
#   mapdrop   a window opening during a held press ends it early in Qt: neither a tap nor an activation (Trash, app tile)
#   interrupt a press that another surface interrupts clicks nothing (Trash held while Apps opens, app tile pressed while Apps opens)
#   rightclick a right press opens the Dock menu at once, however long it is held
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
(( ${#parts[@]} )) || parts=(launch double forward minimized reopen desktop badge hold holdtiles retitle mapdrop interrupt rightclick reduced)
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
# Closes every window of the classes and waits until none shows up for 4 s: an app started by an earlier part (the slow gfLA opens its
# window 1-3 s after its click) must not appear in the middle of the next one.
quiet() {
  local c n=0 any
  while (( n < 4 )); do
    any=0
    for c in "$@"; do
      if [[ $(count_class "$c") -gt 0 ]]; then any=1; kill_class "$c"; fi
    done
    if (( any )); then n=0; else n=$((n + 1)); fi
    sleep 1
  done
}
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
# Duration (ms) of the press in a file of Dock log lines ("pressed true|false EPOCH-MS").
press_ms() { awk '/pressed true/ {d = $NF} /pressed false/ {u = $NF} END {print u - d}' "$1"; }
# Hold of the launch click (ms): well under the Dock's menu hold (dock.menuHold, 550 ms: a host stall of 100 ms made the 450 ms hold
# a menu hold), long enough for a couple of frames of the dimmed icon. The shell logs the real duration, which is checked.
HOLD=250
passed=0
failed=0
# The status is taken into RC right after the condition ("cond; RC=$?"): `$?` as an argument would be read after the command
# substitutions of the description, which reset it (checks that always passed).
# Status 2 is a host stall (the shell measured a hold that is not the one asked for): reported as such, still a failure.
check() { # DESCRIPTION CONDITION-EXIT-STATUS
  if [[ $2 -eq 0 ]]; then echo "PASS $1"; passed=$((passed + 1))
  elif [[ $2 -eq 2 ]]; then echo "FAIL (host stall, not a behaviour failure: rerun) $1"; fail=1; failed=$((failed + 1))
  else echo "FAIL $1"; fail=1; failed=$((failed + 1)); fi
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

# Centre "x y" of the tile of an app key, from the Dock itself (no screenshot; the magnification is off).
# The tile of the app is in the Dock (running or recent), or it is made a recent app: a part run alone, or after a stall, still has it.
ensure_recent() { # CLASS
  vs_ipc dock tiles | jq -e --arg k "$1" 'index($k)' >/dev/null && return 0
  make_recent "$1" magenta
}
tile_xy() { vs_ipc dock centre "$(vs_ipc dock tiles | jq --arg k "$1" 'index($k)')" "$VS_OUTPUT"; }

# Closes any open Dock menu, popup or overlay and asserts that none is open: a menu left by an earlier part would take the next click.
clean_state() { # PART
  local i
  for i in 1 2 3; do
    vs_ipc apps close >/dev/null 2>&1
    vs_ipc search close >/dev/null 2>&1
    vs_ipc overview close >/dev/null 2>&1
    [[ -z $(vs_ipc dock popup) ]] && break
    vs_ipc menubar close >/dev/null 2>&1
    sleep 0.5
    [[ -z $(vs_ipc dock popup) ]] || { vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" click >/dev/null; sleep 0.5; }
  done
  [[ -z $(vs_ipc dock popup) ]]; RC=$?
  check "$1: clean state, no menu or overlay open before the part (popup: '$(vs_ipc dock popup)')" $RC
}

if want launch || want reduced; then
  make_recent gfLA magenta
fi

# One launch from the recents tile of gfLA, frames until 4 s after the click. $1 = part name.
launch_gfLA() {
  local name=$1 x y
  read -r x y <<<"$(tile_xy gfLA)"
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
  # Press and release times come from the shell (same epoch clock, logged by the Dock on its tap handler): see dock-launch.py.
  echo "down $t0" > "$out/$name.events"
  echo "up $(( t0 + HOLD + 15 ))" >> "$out/$name.events"
  # The time the window shows up in the compositor (polled), for the dot check.
  rm -f "$out/$name.map"
  (
    for _ in $(seq 1 200); do
      if [[ $(count_class gfLA) -ge 1 ]]; then date +%s%3N > "$out/$name.map"; break; fi
      sleep 0.03
    done
  ) &
  vs_pointer down sleep "$HOLD" up >/dev/null
  wait "$rec_pid"; rec_pid=""
  wait
  tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch:" > "$out/$name.curve"
}

# dock_click X Y: a plain click on the tile at X Y. A host stall that holds the press for 500 ms or more (the shell logs it) turns a click
# into the Dock menu: that is closed and the click repeated (up to four times). The log lines of the delivered click stay in lastclick.txt.
dock_click() {
  local a m
  for a in 1 2 3 4; do
    vs_pointer abs "$1" "$2" >/dev/null
    sleep 0.7
    m=$(wc -l < "$VS_DEV/shell.log")
    vs_pointer click >/dev/null
    sleep 0.6
    tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/lastclick.txt"
    if grep -q "menu-by-hold" "$out/lastclick.txt"; then
      if [[ $(press_ms "$out/lastclick.txt") -lt 500 ]]; then
        echo "dock_click: the click opened a menu with a press of $(press_ms "$out/lastclick.txt") ms: not a host stall"
        return 1
      fi
      echo "dock_click: attempt $a: a host stall held the press for $(press_ms "$out/lastclick.txt") ms and opened the menu: closing it, again"
      vs_ipc menubar close >/dev/null
      sleep 0.5
      [[ -z $(vs_ipc dock popup) ]] || { vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" click >/dev/null; sleep 0.5; }
      continue
    fi
    return 0
  done
  return 1
}

# launch_gfLA + analysis, up to three attempts: a host stall (status 2: the shell measured a hold or frame gaps that are not the ones
# asked for) starts again from the recents state; three stalls in a row are reported as a stall. Leaves the status in $st.
launch_retry() { # NAME [nobounce]
  local name=$1
  for attempt in 1 2 3; do
    launch_gfLA "$name"
    python3 -I "$VS_HERE/dock-launch.py" launch "$out" "$name" magenta "${2:-}" > "$out/$name-analysis.txt"
    st=$?
    cat "$out/$name-analysis.txt"
    [[ $st -ne 2 ]] && break
    echo "$name: attempt $attempt stalled, again"
    quiet gfLA
    clean_state "$name retry $attempt"
    sleep 3
  done
}

if want launch; then
  clean_state launch
  launch_retry launch
  check "launch: bounce, press, dot (attempt $attempt)" "$st"
  sleep 1
  [[ $(active_class) == gfLA ]]; RC=$?
  check "launch: the new window has the focus (active: $(active_class))" $RC
  [[ $(count_class gfLA) -eq 1 ]]; RC=$?
  check "launch: one window" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want double; then
  clean_state double
  kill_class gfLA
  wait_count gfLA 0 5
  sleep 2.5
  read -r x y <<<"$(tile_xy gfLA)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  vs_pointer click sleep 120 click >/dev/null
  sleep 5
  [[ $(count_class gfLA) -eq 1 ]]; RC=$?
  check "double: two clicks 120 ms apart start one window (found $(count_class gfLA))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want forward || want minimized; then
  clean_state forward
  kill_class gfLA
  vs_sleep 1
  vs_spawn foot --app-id gfLB
  wait_count gfLB 1 10
  vs_spawn foot --app-id gfLB
  wait_count gfLB 2 10
  vs_spawn foot --app-id gfLA
  wait_count gfLA 1 10
  sleep 2
  [[ $(active_class) == gfLA ]]; RC=$?
  check "forward: setup, gfLA in front (active: $(active_class))" $RC
  read -r x y <<<"$(tile_xy gfLB)"
  dock_click "$x" "$y"
  sleep 1
  nest clients -j | jq -c '[.[] | {class, focusHistoryID}]' > "$out/forward.txt"
  cat "$out/forward.txt"
  [[ $(active_class) == gfLB ]]; RC=$?
  check "forward: gfLB has the focus (active: $(active_class))" $RC
  top2=$(nest clients -j | jq '[.[] | select(.focusHistoryID <= 1 and .class == "gfLB")] | length')
  [[ $top2 -eq 2 ]]; RC=$?
  check "forward: both gfLB windows are the two most recent (found $top2)" $RC
  first=$(nest activewindow -j | jq -r .address)
  dock_click "$x" "$y"
  sleep 1
  grep -q "dock-launch: tap [0-9]" "$out/lastclick.txt"; RC=$?
  check "forward: the second click was delivered to the tile (tap logged: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/lastclick.txt" | tr '\n' ' '))" $RC
  [[ $(nest activewindow -j | jq -r .address) == "$first" ]]; RC=$?
  check "forward: a second click does not cycle the windows" $RC
fi

if want minimized; then
  clean_state minimized
  # Minimize every gfLB window, one at a time, waiting for each to reach special:minimized (the Dock tile and the focus settle after).
  minimized_count() { nest clients -j | jq '[.[] | select(.class == "gfLB" and .workspace.name == "special:minimized")] | length'; }
  for i in 1 2 3 4 5 6; do
    nmin=$(minimized_count)
    [[ $nmin -ge 2 ]] && break
    addr=$(nest clients -j | jq -r '[.[] | select(.class == "gfLB" and .workspace.name != "special:minimized")] | .[0].address // empty')
    [[ -n $addr ]] || break
    nest dispatch "hl.dsp.focus({window = 'address:$addr'})" >/dev/null 2>&1
    for _ in $(seq 1 20); do [[ $(nest activewindow -j | jq -r .address) == "$addr" ]] && break; sleep 0.15; done
    vs_ipc windows minimize >/dev/null
    for _ in $(seq 1 25); do [[ $(minimized_count) -gt $nmin ]] && break; sleep 0.2; done
  done
  sleep 1.5
  min=$(nest clients -j | jq '[.[] | select(.class == "gfLB" and .workspace.name == "special:minimized")] | length')
  [[ $min -eq 2 ]]; RC=$?
  check "minimized: setup, both gfLB windows minimized (found $min)" $RC
  read -r x y <<<"$(tile_xy gfLB)"
  dock_click "$x" "$y"
  sleep 2
  min=$(nest clients -j | jq '[.[] | select(.class == "gfLB" and .workspace.name == "special:minimized")] | length')
  [[ $min -eq 1 && $(active_class) == gfLB ]]; RC=$?
  check "minimized: one gfLB window restored and focused, one still minimized (minimized: $min, active: $(active_class))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want reopen; then
  clean_state reopen
  quiet gfLB gfLA
  wait_count gfLB 0 5
  sleep 3
  read -r x y <<<"$(tile_xy gfLB)"
  dock_click "$x" "$y"
  wait_count gfLB 1 10; RC=$?
  check "reopen: a click on the tile of an app with no window starts it again (windows: $(count_class gfLB))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want desktop; then
  clean_state desktop
  nest dispatch 'hl.dsp.focus({ workspace = "3" })' >/dev/null
  sleep 1
  vs_spawn foot --app-id gfLA
  wait_count gfLA 1 10
  sleep 1
  ws_a=$(nest clients -j | jq -r '.[] | select(.class == "gfLA") | .workspace.id')
  nest dispatch 'hl.dsp.focus({ workspace = "2" })' >/dev/null
  sleep 1.5
  [[ $(nest activeworkspace -j | jq -r .id) != "$ws_a" ]]; RC=$?
  check "desktop: setup, gfLA on Desktop $ws_a, another Desktop shown" $RC
  read -r x y <<<"$(tile_xy gfLA)"
  dock_click "$x" "$y"
  sleep 1.5
  [[ $(nest activeworkspace -j | jq -r .id) == "$ws_a" && $(active_class) == gfLA ]]; RC=$?
  check "desktop: the click switched to Desktop $ws_a and focused gfLA (now $(nest activeworkspace -j | jq -r .id), active $(active_class))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want badge; then
  clean_state badge
  # The press-dim layer must not clip a badge that overhangs the icon: a tile with a badge, button down, a frame taken while held. The
  # press is 250 ms (a click, clearly under dock.menuHold). A timed sequence of small frames runs around it; the held frame is one whose
  # whole capture lies inside the press by the shell's own press and release times (dock-launch.py badgeseq). Without such a frame
  # nothing is proved and the attempt is repeated (up to six times); a missing press or release line is a FAIL.
  RC=2
  for attempt in 1 2 3 4 5 6; do
    quiet gfLA gfLB
    DBUS_SESSION_BUS_ADDRESS=$(<"$VS_DEV/bus.address") notify-send -a "GF Launch A" -t 0 "Badge test" "One notification."
    sleep 2
    ensure_recent gfLA
    read -r x y <<<"$(tile_xy gfLA)"
    vs_pointer abs "$x" "$y" >/dev/null
    sleep 0.7
    REGION="$(( OX + x - 60 )),$(( OY + 960 )) 120x90"
    bmark=$(wc -l < "$VS_DEV/shell.log")
    record badgeseq 1700
    sleep 0.6
    vs_pointer down sleep 250 up >/dev/null
    wait "$rec_pid"; rec_pid=""
    tail -n +"$(( bmark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/badge-log.txt"
    python3 -I "$VS_HERE/dock-launch.py" badgeseq "$out" badgeseq "$out/badge-log.txt"; RC=$?
    [[ $RC -ne 2 ]] && break
    echo "badge: attempt $attempt proved nothing, again"
  done
  check "badge: the icon is darker in a frame inside the press and the whole badge shows (attempt $attempt)" $RC
  ! grep -q "menu-by-hold" "$out/badge-log.txt"; RC=$?
  check "badge: the 250 ms press opened no menu (log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/badge-log.txt" | tr '\n' ' '))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
fi

if want hold; then
  clean_state hold
  quiet gfLA gfLB
  wait_count gfLA 0 5
  sleep 5
  ensure_recent gfLA
  read -r x y <<<"$(tile_xy gfLA)"
  echo "hold: gfLA tile at $x,$y; tiles $(vs_ipc dock tiles)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  # A hold under the menu threshold is a click: it launches, no menu.
  mark=$(wc -l < "$VS_DEV/shell.log")
  vs_pointer down sleep 200 up >/dev/null
  wait_count gfLA 1 12; RC=$?
  check "hold: 200 ms is a click, the app starts (windows: $(count_class gfLA))" $RC
  tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/hold-short.txt"
  grep -q "dock-launch: tap" "$out/hold-short.txt" && ! grep -q menu-by-hold "$out/hold-short.txt"; RC=$?
  # A hold near the menu threshold is a host stall (the shell measures the real duration), not a Dock failure.
  [[ $RC -ne 0 && $(press_ms "$out/hold-short.txt") -ge 500 ]] && RC=2
  check "hold: 200 ms logged a tap and no menu ($(tr '\n' ' ' < "$out/hold-short.txt" | sed 's/[0-9]\{13\}//g'))" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
  kill_class gfLA
  wait_count gfLA 0 5
  sleep 5
  ensure_recent gfLA
  read -r x y <<<"$(tile_xy gfLA)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  # A hold over it opens the Dock menu on the pressed tile and the release launches nothing.
  "$VS_ROOT/scripts/dev/shot.sh" dock-launch-locate "$VS_OUTPUT" >/dev/null
  cp "$VS_DEV/shots/dock-launch-locate.png" "$out/hold-before.png"
  mark=$(wc -l < "$VS_DEV/shell.log")
  vs_pointer down sleep 900 up >/dev/null
  sleep 0.5
  "$VS_ROOT/scripts/dev/shot.sh" dock-launch-hold-menu "$VS_OUTPUT" >/dev/null
  cp "$VS_DEV/shots/dock-launch-hold-menu.png" "$out/hold-menu.png"
  tail -n +"$(( mark + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(tap\|menu-by-hold\)" > "$out/hold-long.txt"
  grep -q menu-by-hold "$out/hold-long.txt" && ! grep -q "dock-launch: tap" "$out/hold-long.txt"; RC=$?
  check "hold: 900 ms opened the menu and logged no tap ($(tr '\n' ' ' < "$out/hold-long.txt" | sed 's/[0-9]\{13\}//g'))" $RC
  sleep 3
  [[ $(count_class gfLA) -eq 0 ]]; RC=$?
  check "hold: 900 ms launched nothing (windows: $(count_class gfLA))" $RC
  # The menu is on screen over the tile: bright menu pixels above the Dock (the capture is kept in $out/hold-menu.png to look at).
  python3 -I "$VS_HERE/dock-launch.py" menu "$out/hold-menu.png" "$out/hold-before.png" "$x"; RC=$?
  check "hold: the Dock menu is drawn above the pressed tile" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" click >/dev/null
fi

if want retitle; then
  clean_state retitle
  # A focused window that changes its title every 20 ms (a terminal, a browser tab, a player) makes Hyprland send activewindowv2
  # all the time. Dock clicks must not notice: eight 100 ms clicks on the Trash tile must all tap, none refused.
  quiet gfLA gfLB gfLR
  vs_spawn foot --app-id gfLR sh -c 'i=0; while :; do i=$((i + 1)); printf "\033]2;t%s\007" "$i"; sleep 0.02; done'
  wait_count gfLR 1 10
  sleep 2
  [[ $(active_class) == gfLR ]]; RC=$?
  check "retitle: setup, the retitling window has the focus (active: $(active_class))" $RC
  title1=$(nest activewindow -j | jq -r .title)
  sleep 0.3
  title2=$(nest activewindow -j | jq -r .title)
  [[ -n $title1 && $title1 != "$title2" ]]; RC=$?
  check "retitle: the title changes ($title1 -> $title2)" $RC
  read -r cx cy <<<"$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("trash")')" "$VS_OUTPUT")"
  vs_pointer abs "$cx" "$cy" >/dev/null
  sleep 0.7
  m=$(wc -l < "$VS_DEV/shell.log")
  for k in 1 2 3 4 5 6 7 8; do
    vs_pointer down sleep 100 up >/dev/null
    sleep 0.4
  done
  sleep 0.5
  tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/retitle.txt"
  taps=$(grep -c "dock-launch: tap [0-9]" "$out/retitle.txt")
  refused=$(grep -c "tap-refused-interrupted" "$out/retitle.txt")
  [[ $taps -eq 8 && $refused -eq 0 ]]; RC=$?
  check "retitle: eight 100 ms clicks while the focused window retitles every 20 ms: $taps taps, $refused refused" $RC
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
  quiet gfLR
fi

if want mapdrop; then
  clean_state mapdrop
  # A window opening during a press makes Qt end the press with a release (and a tap) while the button is still down. A press the Dock
  # did not finish does nothing: neither a tap nor an activation nor a menu. The sequence the handler sees is kept in the logs.
  quiet gfLA gfLB gfLM
  ensure_recent gfLA
  logs() { sed 's/.*dock-launch: //' "$1" | tr '\n' '|'; }
  # (a) the Trash tile held for 1 s, a window opens 0.1 s into the hold.
  read -r cx cy <<<"$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("trash")')" "$VS_OUTPUT")"
  vs_pointer abs "$cx" "$cy" >/dev/null
  sleep 0.7
  m=$(wc -l < "$VS_DEV/shell.log")
  ( sleep 0.1; vs_spawn foot --app-id gfLM ) &
  vs_pointer down sleep 1000 up >/dev/null
  wait
  sleep 1.5
  tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch:" > "$out/mapdrop-trash.txt"
  echo "mapdrop trash: $(logs "$out/mapdrop-trash.txt")"
  ! grep -q "dock-launch: tap [0-9]" "$out/mapdrop-trash.txt" && grep -q "tap-refused" "$out/mapdrop-trash.txt"; RC=$?
  check "mapdrop: Trash held 1 s, a window opened 0.1 s in: the early release taps nothing (refused logged)" $RC
  quiet gfLM
  # (b) the app tile held for 1 s, a window opens 0.1 s in: the app is not activated and no menu opens.
  ensure_recent gfLA
  read -r x y <<<"$(tile_xy gfLA)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  m=$(wc -l < "$VS_DEV/shell.log")
  ( sleep 0.1; vs_spawn foot --app-id gfLM ) &
  vs_pointer down sleep 1000 up >/dev/null
  wait
  sleep 3
  tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch:" > "$out/mapdrop-app.txt"
  echo "mapdrop app: $(logs "$out/mapdrop-app.txt")"
  ! grep -q "dock-launch: tap [0-9]" "$out/mapdrop-app.txt"; RC=$?
  [[ $RC -eq 0 && $(count_class gfLA) -eq 0 ]]; RC=$?
  check "mapdrop: app tile held 1 s, a window opened 0.1 s in: the app is not activated (gfLA windows: $(count_class gfLA))" $RC
  vs_ipc menubar close >/dev/null
  quiet gfLM gfLA
fi

if want interrupt; then
  clean_state interrupt
  # macOS: a press that something else interrupts does nothing. Qt ends such a press with a release while the button is still down and
  # fires the tap: the Dock refuses it (dock-launch: tap-refused-interrupted), like an interrupted drag.
  quiet gfLA gfLB
  ensure_recent gfLA
  # (a) the Trash tile held for 2 s, the Apps panel opened by IPC 0.6 s into the hold.
  read -r cx cy <<<"$(vs_ipc dock centre "$(vs_ipc dock tiles | jq 'index("trash")')" "$VS_OUTPUT")"
  vs_pointer abs "$cx" "$cy" >/dev/null
  sleep 0.7
  m=$(wc -l < "$VS_DEV/shell.log")
  ( sleep 0.6; vs_ipc apps open >/dev/null ) &
  vs_pointer down sleep 2000 up >/dev/null
  wait
  sleep 1
  tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/interrupt-trash.txt"
  grep -q "tap-refused-interrupted" "$out/interrupt-trash.txt" && ! grep -q "dock-launch: tap [0-9]" "$out/interrupt-trash.txt"; RC=$?
  check "interrupt: Trash held, Apps opened during the hold: the release clicks nothing (log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/interrupt-trash.txt" | tr '\n' ' '))" $RC
  vs_ipc apps close >/dev/null
  sleep 1.5
  clean_state interrupt
  # (b) the app tile pressed for 450 ms, the Apps panel opened at once: the release does not start the app. A hold the shell measures at
  # 500 ms or more opened the menu instead and proves a stall (retried by the part, then FAIL).
  RC=1
  for attempt in 1 2 3; do
    quiet gfLA gfLB
    ensure_recent gfLA
    read -r x y <<<"$(tile_xy gfLA)"
    vs_pointer abs "$x" "$y" >/dev/null
    sleep 0.7
    m=$(wc -l < "$VS_DEV/shell.log")
    ( vs_ipc apps open >/dev/null ) &
    vs_pointer down sleep 450 up >/dev/null
    wait
    sleep 3
    tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(pressed\|tap\|menu-by-hold\)" > "$out/interrupt-app.txt"
    vs_ipc apps close >/dev/null
    sleep 1.5
    if grep -q "menu-by-hold" "$out/interrupt-app.txt" && [[ $(press_ms "$out/interrupt-app.txt") -ge 500 ]]; then
      echo "interrupt: attempt $attempt: the shell measured a hold of $(press_ms "$out/interrupt-app.txt") ms (menu hold): host stall, again"
      RC=2
      clean_state interrupt
      continue
    fi
    grep -q "tap-refused-interrupted" "$out/interrupt-app.txt" && ! grep -q "dock-launch: tap [0-9]" "$out/interrupt-app.txt" && [[ $(count_class gfLA) -eq 0 ]]; RC=$?
    break
  done
  check "interrupt: app tile pressed, Apps opened during the press: nothing starts (windows: $(count_class gfLA); log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/interrupt-app.txt" | tr '\n' ' '))" $RC
  quiet gfLA gfLB
fi

if want rightclick; then
  clean_state rightclick
  # macOS: a secondary click opens the Dock menu on the press, however long the button is held (Qt's 0.8 s long press used to decide).
  quiet gfLA gfLB
  ensure_recent gfLA
  read -r x y <<<"$(tile_xy gfLA)"
  vs_pointer abs "$x" "$y" >/dev/null
  sleep 0.7
  m=$(wc -l < "$VS_DEV/shell.log")
  rt0=$(date +%s%3N)
  vs_pointer rdown sleep 1200 rup >/dev/null
  tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: menu-by-right-press" > "$out/rightclick.txt"
  rts=$(awk '{print $NF; exit}' "$out/rightclick.txt")
  [[ -n $rts && $(( rts - rt0 )) -lt 700 ]]; RC=$?
  check "rightclick: the menu opened on the press, not after the 1.2 s hold (${rts:+$(( rts - rt0 ))} ms after the start of the process)" $RC
  [[ $(vs_ipc dock popup) == dock ]]; RC=$?
  check "rightclick: the Dock menu is open after the release (popup: '$(vs_ipc dock popup)')" $RC
  vs_ipc menubar close >/dev/null
  sleep 0.5
fi

if want holdtiles; then
  clean_state holdtiles
  # A hold of 900 ms on a tile WITHOUT a Dock menu still clicks on release (like a right click does nothing there): Apps, Trash, a
  # minimized window. (An app tile gives its menu, see `hold`.) The Dock logs `tap` for a click and `menu-by-hold` for a menu.
  quiet gfLA gfLB
  sleep 3
  tile_centre() { vs_ipc dock centre "$1" "$VS_OUTPUT"; } # INDEX -> "x y"
  hold_tile() { # NAME INDEX: hold 900 ms, then the Dock log lines of that hold in $out/holdtiles-NAME.txt
    local cx cy m
    read -r cx cy <<<"$(tile_centre "$2")"
    vs_pointer abs "$cx" "$cy" >/dev/null
    sleep 0.7
    m=$(wc -l < "$VS_DEV/shell.log")
    vs_pointer down sleep 900 up >/dev/null
    sleep 1
    tail -n +"$(( m + 1 ))" "$VS_DEV/shell.log" | grep "dock-launch: \(tap\|menu-by-hold\)" > "$out/holdtiles-$1.txt"
    vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
  }
  idx() { vs_ipc dock tiles | jq "$1"; }
  hold_tile apps "$(idx 'index("grid")')"
  grep -q "dock-launch: tap" "$out/holdtiles-apps.txt" && ! grep -q menu-by-hold "$out/holdtiles-apps.txt"; RC=$?
  check "holdtiles: 900 ms on the Apps tile clicks on release (log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/holdtiles-apps.txt" | tr '\n' ' '))" $RC
  vs_ipc apps close >/dev/null
  sleep 1
  hold_tile trash "$(idx 'index("trash")')"
  grep -q "dock-launch: tap" "$out/holdtiles-trash.txt" && ! grep -q menu-by-hold "$out/holdtiles-trash.txt"; RC=$?
  check "holdtiles: 900 ms on the Trash tile clicks on release (log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/holdtiles-trash.txt" | tr '\n' ' '))" $RC
  # A minimized window: its tile restores the window on a click, held or not.
  vs_spawn foot --app-id gfLB
  wait_count gfLB 1 10
  sleep 2
  vs_ipc windows minimize >/dev/null
  sleep 1.5
  nest clients -j | jq -r '.[] | select(.class == "gfLB") | .workspace.name' > "$out/holdtiles-ws-before.txt"
  mi=$(idx 'to_entries | map(select(.value | test("^min:"))) | .[0].key')
  echo "minimized tile index: $mi ($(vs_ipc dock tiles))"
  hold_tile minimized "$mi"
  sleep 1.5
  ws_after=$(nest clients -j | jq -r '.[] | select(.class == "gfLB") | .workspace.name')
  [[ $(<"$out/holdtiles-ws-before.txt") == "special:minimized" && $ws_after != "special:minimized" && -n $ws_after ]]; RC=$?
  check "holdtiles: 900 ms on a minimized-window tile restores the window (workspace $(<"$out/holdtiles-ws-before.txt") -> $ws_after; log: $(sed 's/.*dock-launch: //; s/ [0-9]\{13\}//' "$out/holdtiles-minimized.txt" | tr '\n' ' '))" $RC
  kill_class gfLB
fi

if want reduced; then
  clean_state reduced
  quiet gfLA gfLB
  sleep 5
  vs_ipc controlcenter reduceMotion true >/dev/null
  sleep 0.5
  launch_retry reduced nobounce
  ! grep -q "dock-launch: lift" "$out/reduced.curve"; RC=$?
  check "reduced: no bounce with Reduce Motion (bounce samples logged: $(grep -c "dock-launch: lift" "$out/reduced.curve"))" $RC
  grep -q "^dot: .*first seen [0-9]" "$out/reduced-analysis.txt"; RC=$?
  check "reduced: the running dot appears" $RC
  vs_ipc controlcenter reduceMotion false >/dev/null
fi

echo "dock-launch: $passed checks passed, $failed failed (of $(( passed + failed ))); exit $fail; frames and logs in $out"
exit "$fail"
