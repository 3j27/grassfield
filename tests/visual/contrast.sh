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

# cap SURFACE [SETTLE]: the surface in the four glyph modes -> $dir/SURFACE{,.hidden,.white,.black}.png
cap() {
  local name=$1 settle=${2:-1} m
  snap "$name" "$settle"
  mv "$dir/$name.en.png" "$dir/$name.png"
  for m in hidden white black; do
    vs_ipc visual glyphs "$m" >/dev/null
    VS_NOPARK=1 snap "$name" 0.5
    mv "$dir/$name.en.png" "$dir/$name.$m.png"
  done
  vs_ipc visual glyphs normal >/dev/null
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
# "dockdrag"; the drag comes back to its slot before the release, so nothing is removed from the Dock. The windows are
# closed again (they would be in the backdrop of the surfaces that follow).
dock_surface() {
  local m
  # One after the other: the tiles follow the order of the windows (A first, B second).
  vs_spawn foot --app-id gfdockA
  vs_sleep 1.5
  vs_spawn foot --app-id gfdockB
  vs_sleep 2
  DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a gfdockB -t 20000 "Test" "Badge"
  vs_sleep 1
  # Hover: the tooltip of the first test tile.
  vs_pointer abs $DOCK_X_A $DOCK_Y >/dev/null
  vs_sleep 1.5
  VS_SHOTS=$dir VS_NOPARK=1 VS_SETTLE=0.8 vs_capture dock >/dev/null
  mv "$dir/dock.en.png" "$dir/dock.png"
  for m in hidden white black; do
    vs_ipc visual glyphs "$m" >/dev/null
    VS_SHOTS=$dir VS_NOPARK=1 VS_SETTLE=0.8 vs_capture dock >/dev/null
    mv "$dir/dock.en.png" "$dir/dock.$m.png"
  done
  vs_ipc visual glyphs normal >/dev/null
  # Drag: held for the four captures, then back on its slot and released (an unchanged order).
  "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs $DOCK_X_FOOT $DOCK_Y sleep 300 down sleep 300 drag $DOCK_X_FOOT 900 \
    sleep 14000 drag $DOCK_X_FOOT $DOCK_Y sleep 400 up sleep 300 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
  local pointer_pid=$!
  vs_sleep 2
  VS_SHOTS=$dir VS_NOPARK=1 VS_SETTLE=0.3 vs_capture dockdrag >/dev/null
  mv "$dir/dockdrag.en.png" "$dir/dockdrag.png"
  for m in hidden white black; do
    vs_ipc visual glyphs "$m" >/dev/null
    VS_SHOTS=$dir VS_NOPARK=1 VS_SETTLE=0.3 vs_capture dockdrag >/dev/null
    mv "$dir/dockdrag.en.png" "$dir/dockdrag.$m.png"
  done
  vs_ipc visual glyphs normal >/dev/null
  wait "$pointer_pid" || true
  vs_kill_clients
  vs_park
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
          # Banners stay up for the four captures (6 s to 15 s on a busy host; 24 s lifetime), then expire before the Notification Center is opened.
          vs_ipc notifications clearAll >/dev/null
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 24000 "Anna Martin" "Are we still on for lunch tomorrow?"
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 24000 "Design review" "Starts in 10 minutes in Room 4."
          need_notif banners 2
          if want banners; then
            vs_sleep 1.5; cap banners 0.5
            differs "$dir/desktop.png" "$dir/banners.png" 2000
          fi
          # The banners expire (24 s) before the Notification Center is opened; both are checked, not assumed.
          need_notif banners 0 45
          if want notificationcenter; then
            # A second Calendar card (a short banner, waited out) makes the top group a group of two: a single card has
            # no group controls (no "Clear All"), and the hover cells measure them.
            DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 1000 "Standup" "Starts in 5 minutes in Room 2."
            need_notif banners 0 45
            center open; vs_sleep 3; cap notificationcenter
            # The column is floating cards (no full-height sheet): a light card on the white wallpaper differs by its text only.
            differs "$dir/desktop.png" "$dir/notificationcenter.png" 600
            # Hover states (macOS model, no permanent Clear All): the pointer on the first card shows its x and the
            # group x; the pointer on the group x grows it into the "Clear All" pill. Frames are slow in the nested
            # session, so the pointer is nudged while the reveal animation runs.
            vs_pointer abs 1730 110 sleep 300 abs 1731 111 sleep 300 abs 1730 110 sleep 300 abs 1731 111 sleep 300 abs 1730 110 \
              sleep 300 abs 1731 111 sleep 300 abs 1730 110 >/dev/null
            vs_sleep 1.5
            VS_NOPARK=1 cap notificationcenterhover
            vs_pointer abs 1881 65 sleep 300 abs 1882 65 sleep 300 abs 1881 65 sleep 300 abs 1882 66 sleep 300 abs 1881 65 \
              sleep 300 abs 1882 65 sleep 300 abs 1881 65 sleep 300 abs 1882 66 sleep 300 abs 1881 65 sleep 600 \
              abs 1862 73 sleep 300 abs 1863 73 sleep 300 abs 1862 73 >/dev/null
            # (the pointer ends on the lower edge of the pill so the cursor image does not cover the label)
            vs_sleep 1.5
            VS_NOPARK=1 cap notificationcenterclear
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
          cap lock
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
