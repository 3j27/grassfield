#!/usr/bin/env bash
# Gate A2 driver: captures the contrast surfaces on 5 worst-case wallpapers x light/dark x transparency
# 0.25/0.6 in the nested session, each in four glyph modes (normal, hidden, white, black: the glyph mask method of
# docs/testing/visual.md), then runs contrast.py. Run as a BARE command (reference machine only).
#   tests/visual/contrast.sh [--measure-only] [--wallpapers white,black,...] [--transparency 0.25,0.6] [--surfaces desktop,search,...]
# Output: .dev/visual/contrast/<wallpaper>__<appearance>__<transparency>/<surface>[.hidden|.white|.black].png and
# contrast.csv. The nested session this script starts is torn down on exit (also on failure or interruption).
# The lock surface is captured last and locks the nested session (never typed into: only the owner's password could
# unlock it), so the session is torn down after it even when it was already running.
# Exit status: contrast.py's (1 when a cell is below its threshold).
source "$(dirname "$0")/lib.sh"

measure_only=0
wallpapers="white black gray noise checker"
transparencies="0.25 0.6"
surfaces=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --measure-only) measure_only=1 ;;
    --wallpapers) wallpapers=${2//,/ }; shift ;;
    --transparency) transparencies=${2//,/ }; shift ;;
    --surfaces) surfaces=${2//,/ }; shift ;;
    *) echo "contrast: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

out=$VS_STATE/contrast
wp=$out/wallpapers

# Only tear down a session this run started, or one this run locked.
was_running=0
locked=0
vs_nested_running && was_running=1
cleanup() {
  if (( ! was_running || locked )); then
    "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
    if (( locked )); then rm -f "$VS_STATE/session.lang"; fi
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# snap NAME SETTLE [VS_NOPARK]: one capture -> $dir/NAME.en.png. The nested GF-REF output sometimes returns a fully
# transparent frame (an RGBA image with mean alpha ~ 0.0000005; a real capture has no alpha channel, mean.a reads 0) while
# the host is busy; such a frame is taken again (up to 8 times, 2 s apart) instead of being measured as a blank surface.
snap() {
  local name=$1 settle=$2 try
  for try in 1 2 3 4 5 6 7 8; do
    VS_SHOTS=$dir VS_SETTLE=$settle vs_capture "$name" >/dev/null
    [[ $(magick "$dir/$name.en.png" -format '%[fx:(mean.a>0&&mean.a<0.01)?1:0]' info: 2>/dev/null) == 0 ]] && return 0
    sleep 2
  done
  fail "$name: the nested output kept returning an empty frame"
}

# ae A B: number of pixels that differ between two captures (2 % fuzz); 0 when compare prints nothing usable.
ae() {
  local n
  n=$(compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 || true)
  awk -v n="${n%% *}" 'BEGIN { printf "%d", n + 0 }'
}

# snap_stable NAME SETTLE: like snap, then taken again until two consecutive frames agree within 150 px, so that a surface still
# fading in or moving (slow nested frames) is not measured half way. Bounded in time (SNAP_BUDGET seconds, 60 by default): when
# no two frames agree it says "unsettled" and returns 1; such a frame is never used. A frame costs 1 to 13 s on a busy host
# (park, settle, shot), so the time budget bounds the loop, not a count. The pointer is never parked here (cap does it once).
snap_stable() {
  local name=$1 settle=$2 t0=$SECONDS
  VS_NOPARK=1 snap "$name" "$settle"
  while (( SECONDS - t0 < ${SNAP_BUDGET:-60} )); do
    mv "$dir/$name.en.png" "$dir/$name.prev.png"
    VS_NOPARK=1 snap "$name" 0.4
    if (( $(ae "$dir/$name.prev.png" "$dir/$name.en.png") < 150 )); then rm -f "$dir/$name.prev.png"; return 0; fi
  done
  rm -f "$dir/$name.prev.png"
  echo "contrast: $name: unsettled (no two frames within 150 px in ${SNAP_BUDGET:-60} s)" >&2
  return 1
}

# cap_state_ok: the scenario state of the surface (CAP_CHECK, a function name set by the caller: banners still shown, Center
# still open, session still locked); true without a check. Called before EVERY capture of a set.
cap_state_ok() { [[ -z ${CAP_CHECK:-} ]] || "$CAP_CHECK"; }

# set_consistent BASE: the captures of one set (BASE.png normal, .hidden, .white, .black, .end = normal again) show the same
# surface state. The normal frame taken last must equal the first (the state did not end meanwhile); the glyph modes must have
# been applied (black vs white differ at glyph pixels only, hidden vs normal at the glyphs) and hidden vs white and hidden vs
# black may differ by no more than the glyph pixels (+150): a banner that expired between two captures shows as a large
# difference there.
set_consistent() {
  local b=$1 end hw hk wk nh n
  n=$(basename "$b")
  end=$(ae "$b.png" "$b.end.png")
  wk=$(ae "$b.white.png" "$b.black.png")
  hw=$(ae "$b.hidden.png" "$b.white.png")
  hk=$(ae "$b.hidden.png" "$b.black.png")
  nh=$(ae "$b.png" "$b.hidden.png")
  if (( end >= 150 )); then echo "contrast: $n: the state changed during the set (first and last normal frame differ by $end px)" >&2; return 1; fi
  if (( wk < 20 || nh < 20 )); then echo "contrast: $n: glyph modes not applied (white/black differ by $wk px, hidden/normal by $nh px)" >&2; return 1; fi
  if (( hw > wk + 150 || hk > wk + 150 )); then echo "contrast: $n: the glyph captures show different states (hidden/white $hw, hidden/black $hk, white/black $wk px)" >&2; return 1; fi
  return 0
}

# capture_set NAME SETTLE: one pass over the four glyph modes -> $dir/NAME{,.hidden,.white,.black,.end}.png; 1 when the state
# was lost, a frame did not settle or the frames disagree.
capture_set() {
  local name=$1 settle=$2 m
  cap_state_ok || { echo "contrast: $name: scenario state lost before the set" >&2; return 1; }
  snap_stable "$name" "$settle" || return 1
  mv "$dir/$name.en.png" "$dir/$name.png"
  for m in hidden white black; do
    cap_state_ok || { vs_ipc visual glyphs normal >/dev/null; echo "contrast: $name: scenario state lost before the $m capture" >&2; return 1; }
    vs_ipc visual glyphs "$m" >/dev/null
    VS_NOPARK=1 snap "$name" 0.8
    mv "$dir/$name.en.png" "$dir/$name.$m.png"
  done
  vs_ipc visual glyphs normal >/dev/null
  cap_state_ok || { echo "contrast: $name: scenario state lost before the last capture" >&2; return 1; }
  VS_NOPARK=1 snap "$name" 0.8
  mv "$dir/$name.en.png" "$dir/$name.end.png"
  set_consistent "$dir/$name"
}

# cap SURFACE [SETTLE]: the surface in the four glyph modes -> $dir/SURFACE{,.hidden,.white,.black}.png. The pointer is parked
# ONCE per set (not per capture; hover surfaces set VS_NOPARK and place it themselves). A set that is not usable (state lost,
# unsettled, frames that disagree) is redone up to CAP_TRIES times (3); then the run fails "not measured", or with CAP_SOFT=1
# cap returns 1 and the caller decides: a surface that could not be captured is never passed. A set costs 5 to 7 frames.
cap() {
  local name=$1 settle=${2:-1} try
  for try in $(seq 1 "${CAP_TRIES:-3}"); do
    if [[ -z ${VS_NOPARK:-} ]]; then vs_park; vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null; vs_sleep 0.2; fi
    if capture_set "$name" "$settle"; then rm -f "$dir/$name.end.png"; return 0; fi
    echo "contrast: $name: set $try of ${CAP_TRIES:-3} not usable" >&2
  done
  vs_ipc visual glyphs normal >/dev/null
  if [[ -n ${CAP_SOFT:-} ]]; then return 1; fi
  fail "$name: not measured (no consistent capture set in ${CAP_TRIES:-3} tries)"
}

# want SURFACE: true when the surface is selected (--surfaces; all by default).
want() { [[ -z $surfaces || " $surfaces " == *" $1 "* ]]; }

# want_unlocked: true when a surface other than the lock is selected.
want_unlocked() {
  local s
  [[ -z $surfaces ]] && return 0
  for s in $surfaces; do [[ $s == lock ]] || return 0; done
  return 1
}

# fail MSG: stop the run (the cleanup trap still tears the session down). A surface that is not open is never measured.
fail() { echo "contrast: $*" >&2; exit 1; }

# need_json TARGET FIELD WANT: poll `ipc TARGET status` (JSON) until FIELD equals WANT (5 s), else fail.
need_json() {
  local target=$1 field=$2 want=$3 i got=""
  for i in $(seq 1 25); do
    got=$(vs_ipc "$target" status 2>/dev/null | jq -r "$field" 2>/dev/null || true)
    [[ $got == "$want" ]] && return 0
    sleep 0.2
  done
  fail "$target is not $field=$want before the capture (got '$got')"
}

# notif_state KEY: value of KEY in `notifications status` (server= history= banners= dnd= center=).
notif_state() { vs_ipc notifications status 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# need_notif KEY WANT [SECONDS]: wait until the notification state KEY equals WANT, else fail.
need_notif() {
  local key=$1 want=$2 i got=""
  for i in $(seq 1 $(( ${3:-5} * 5 ))); do
    got=$(notif_state "$key")
    [[ $got == "$want" ]] && return 0
    sleep 0.2
  done
  fail "notifications $key is '$got', expected '$want'"
}

# State checks for CAP_CHECK (no waiting, no failing: true or false).
banners_up() { [[ $(notif_state banners) == 2 ]]; }
center_open() { [[ $(notif_state center) == true ]]; }
is_locked() { [[ $(vs_ipc lock status 2>/dev/null || true) == locked ]]; }

# center open|closed: the Notification Center is toggled by a click on the menu bar clock (the same path as a user) and
# its state is read back through IPC; up to three clicks, then fail.
center() {
  local want=false n
  [[ $1 == open ]] && want=true
  for n in 1 2 3; do
    [[ $(notif_state center) == "$want" ]] && return 0
    vs_pointer abs 1850 12 sleep 300 click >/dev/null
    sleep 0.8
  done
  [[ $(notif_state center) == "$want" ]] || fail "the Notification Center did not become $1"
}

# need_locked: poll `lock status` until the shell reports the session locked (10 s), else fail.
need_locked() {
  local i got=""
  for i in $(seq 1 50); do
    got=$(vs_ipc lock status 2>/dev/null || true)
    [[ $got == locked ]] && return 0
    sleep 0.2
  done
  fail "lock status is '$got', expected locked"
}

# differs REF IMG MIN: capture check that IMG shows something REF (the bare desktop of the same combination) does not.
differs_q() {
  local n
  n=$(compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 || true)
  # compare prints "4394.01 (0.0021)" with a fuzz: keep the integer part.
  # (large counts come as "1.77e+06 (0.85)": awk reads the number)
  awk -v n="${n%% *}" -v min="$3" 'BEGIN { exit !(n + 0 >= min + 0) }'
}
differs() { differs_q "$@" || fail "$(basename "$2") looks like $(basename "$1"): the surface did not open (fewer than $3 px differ)"; }

# overlay NAME OPEN_ARGS...: open a Search/Apps style overlay by IPC (target = NAME), check its state AND that it is on GF-REF,
# capture it, and verify by pixels that it is shown; up to three attempts (the first open can land on another output), then fail.
overlay() {
  local name=$1 n
  shift
  for n in 1 2 3; do
    vs_ipc "$name" open "$@" >/dev/null
    need_json "$name" .open true
    vs_sleep 1
    cap "$name"
    if differs_q "$dir/desktop.png" "$dir/$name.png" 2000; then
      vs_ipc "$name" close >/dev/null
      need_json "$name" .open false
      return 0
    fi
    vs_ipc "$name" close >/dev/null
    need_json "$name" .open false
    vs_park
  done
  fail "$name did not show on GF-REF after three attempts"
}

# Dock tile centres on GF-REF with the dock of this run (Files tile, Apps tile, pinned foot, then the two test apps, separator, Trash): the pinned
# tile and the two running ones (their dots, tooltip and badge). Magnification is off, so the layout is the unscaled one.
DOCK_X_FOOT=927 DOCK_X_A=979 DOCK_X_B=1031 DOCK_Y=1032

# dock_surface: two running test apps (foot windows with distinct app ids: running dots), a notification for one of them (the
# badge), the pointer on the first (its tooltip) -> "dock"; the pinned foot tile pressed and dragged up (its "Remove" label) ->
# "dockdrag"; the held pointer is stopped after the set and the tile is put back on its slot before the release, so nothing is
# removed from the Dock. The windows are closed and the notifications cleared again (they would be in the backdrop of the
# surfaces that follow).
dock_surface() {
  # One after the other: the tiles follow the order of the windows (A first, B second).
  vs_spawn foot --app-id gfdockA
  vs_sleep 1.5
  vs_spawn foot --app-id gfdockB
  vs_sleep 2
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a gfdockB -t 0 "Test" "Badge"
  vs_sleep 1
  # Hover: the tooltip of the first test tile.
  # (nudged: a hover that arrives while the new windows re-lay the Dock is only seen at the next motion; the tooltip is shown
  # with the pointer at rest, which snap_stable waits for)
  vs_pointer abs $DOCK_X_A $DOCK_Y sleep 300 abs $((DOCK_X_A + 2)) $DOCK_Y sleep 300 abs $DOCK_X_A $DOCK_Y >/dev/null
  vs_sleep 1.5
  VS_NOPARK=1 cap dock 0.8
  # Drag: the pinned foot tile pressed and dragged up and HELD (the holding pointer process has no timer: it is stopped after the
  # set, then the tile is put back on its slot and released, an unchanged order). A press that the busy shell never turned into
  # a drag shows no "Remove" label (checked by pixels in the label's place, which is empty in "dock"), a drag that ended shows
  # the same through the consistency check of the set: both redo the whole drag, up to three times, then the run fails.
  local pointer_pid try ok=""
  for try in 1 2 3; do
    "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs $DOCK_X_FOOT $DOCK_Y sleep 400 abs $((DOCK_X_FOOT + 2)) $DOCK_Y sleep 400 abs $DOCK_X_FOOT $DOCK_Y sleep 600 down sleep 300 drag $DOCK_X_FOOT 900 \
      sleep 600000 >/dev/null &
    pointer_pid=$!
    vs_sleep 4
    if VS_NOPARK=1 CAP_TRIES=1 CAP_SOFT=1 SNAP_BUDGET=45 cap dockdrag 0.3; then
      magick "$dir/dock.png" -crop 120x50+870+830 +repage "$dir/label-ref.png"
      magick "$dir/dockdrag.png" -crop 120x50+870+830 +repage "$dir/label-now.png"
      if differs_q "$dir/label-ref.png" "$dir/label-now.png" 150; then ok=1; fi
      rm -f "$dir/label-ref.png" "$dir/label-now.png"
    fi
    kill "$pointer_pid" 2>/dev/null || true
    wait "$pointer_pid" 2>/dev/null || true
    vs_pointer abs $DOCK_X_FOOT $DOCK_Y sleep 400 up sleep 300 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
    [[ -n $ok ]] && break
    echo "contrast: dockdrag: drag $try of 3 not usable" >&2
    vs_sleep 2
  done
  vs_ipc notifications clearAll >/dev/null
  vs_kill_clients
  vs_park
  [[ -n $ok ]] || fail "dockdrag: not measured (no usable drag in 3 tries)"
}

if (( ! measure_only )); then
  rm -rf "$out"; mkdir -p "$out"
  python3 -I "$VS_HERE/contrast.py" gen "$wp"
  export VISUAL_LANG=en
  vs_session en
  vs_reset dark 0.25
  bus=$(<"$VS_DEV/bus.address")
  want_unlocked && for w in $wallpapers; do
    for appearance in light dark; do
      for tr in $transparencies; do
        dir=$out/${w}__${appearance}__${tr}
        mkdir -p "$dir"
        vs_wallpaper "$wp/$w.png"
        vs_ipc controlcenter appearance "$appearance" >/dev/null
        vs_ipc controlcenter transparency "$tr" >/dev/null
        vs_sleep 1.5
        # Always captured: every other surface is checked against it (differs); it is only MEASURED with --surfaces desktop.
        cap desktop
        need_notif center false
        if want systemmenu; then
          vs_ipc menubar open system GF-REF >/dev/null; cap systemmenu; vs_ipc menubar close >/dev/null
          differs "$dir/desktop.png" "$dir/systemmenu.png" 2000
        fi
        if want controlcenter; then
          vs_ipc menubar open controlcenter GF-REF >/dev/null; cap controlcenter; vs_ipc menubar close >/dev/null
          differs "$dir/desktop.png" "$dir/controlcenter.png" 2000
        fi
        if want search; then
          overlay search files
        fi
        if want apps; then
          overlay apps
        fi
        if want banners || want notificationcenter; then
          # The banners never expire (expire_timeout 0: a capture set takes 30 s to 90 s on a busy host, longer than any lifetime) and
          # are dismissed by the test hook after the set; the set is only taken while both are shown (banners_up, checked before
          # every capture).
          vs_ipc notifications clearAll >/dev/null
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 0 "Anna Martin" "Are we still on for lunch tomorrow?"
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 0 "Design review" "Starts in 10 minutes in Room 4."
          need_notif banners 2
          if want banners; then
            vs_sleep 1.5
            CAP_CHECK=banners_up cap banners 0.5
            differs "$dir/desktop.png" "$dir/banners.png" 2000
          fi
          vs_ipc notifications dismissAll >/dev/null
          need_notif banners 0 10
          if want notificationcenter; then
            # A second Calendar card (a short banner, waited out) makes the top group a group of two: a single card has
            # no group controls (no "Clear All"), and the hover cells measure them.
            DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 1000 "Standup" "Starts in 5 minutes in Room 2."
            need_notif banners 0 45
            center open; vs_sleep 3; CAP_CHECK=center_open cap notificationcenter
            # The column is floating cards (no full-height sheet): a light card on the white wallpaper differs by its text only.
            differs "$dir/desktop.png" "$dir/notificationcenter.png" 600
            # Hover states (macOS model, no permanent Clear All): the pointer on the first card shows its x and the
            # group x; the pointer on the group x grows it into the "Clear All" pill. Frames are slow in the nested
            # session, so the pointer is nudged while the reveal animation runs.
            vs_pointer abs 1730 110 sleep 300 abs 1731 111 sleep 300 abs 1730 110 sleep 300 abs 1731 111 sleep 300 abs 1730 110 \
              sleep 300 abs 1731 111 sleep 300 abs 1730 110 >/dev/null
            vs_sleep 1.5
            VS_NOPARK=1 CAP_CHECK=center_open cap notificationcenterhover
            vs_pointer abs 1881 65 sleep 300 abs 1882 65 sleep 300 abs 1881 65 sleep 300 abs 1882 66 sleep 300 abs 1881 65 \
              sleep 300 abs 1882 65 sleep 300 abs 1881 65 sleep 300 abs 1882 66 sleep 300 abs 1881 65 sleep 600 \
              abs 1862 73 sleep 300 abs 1863 73 sleep 300 abs 1862 73 >/dev/null
            # (the pointer ends on the lower edge of the pill so the cursor image does not cover the label)
            vs_sleep 1.5
            VS_NOPARK=1 CAP_CHECK=center_open cap notificationcenterclear
            differs "$dir/notificationcenter.png" "$dir/notificationcenterclear.png" 200
            vs_park
            center closed
          fi
        fi
        if want dock || want dockdrag; then
          dock_surface
        fi
        vs_park
      done
    done
  done

  # The lock screen last: a locked nested session cannot be unlocked without the owner's password, which is never typed.
  # It is locked once, through the same IPC as tests/visual/scenarios/lock.sh; each combination is then set through IPC
  # (wallpaper, appearance and transparency reach the shell while it is locked) and captured. cleanup tears it down.
  if want lock; then
    locked=1
    r=$(vs_ipc lock lock)
    [[ $r == ok ]] || fail "lock lock answered '$r'"
    need_locked
    for w in $wallpapers; do
      for appearance in light dark; do
        for tr in $transparencies; do
          dir=$out/${w}__${appearance}__${tr}
          mkdir -p "$dir"
          vs_wallpaper "$wp/$w.png"
          vs_ipc controlcenter appearance "$appearance" >/dev/null
          vs_ipc controlcenter transparency "$tr" >/dev/null
          vs_sleep 1.5
          CAP_CHECK=is_locked cap lock
          need_locked
          if [[ -f $dir/desktop.png ]]; then
            differs "$dir/desktop.png" "$dir/lock.png" 2000
          fi
        done
      done
    done
  fi
fi

python3 -I "$VS_HERE/contrast.py" measure "$out" --surfaces "${surfaces// /,}"
