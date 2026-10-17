#!/usr/bin/env bash
# Gate A2 driver: captures the contrast surfaces on 5 worst-case wallpapers x light/dark x transparency
# 0.25/0.6 in the nested session, each in four glyph modes (normal, hidden, white, black: the glyph mask method of
# docs/testing/visual.md), then runs contrast.py. Run as a BARE command (reference machine only).
#   tests/visual/contrast.sh [--measure-only] [--wallpapers white,black,...] [--transparency 0.25,0.6] [--surfaces desktop,search,...]
# Output: .dev/visual/contrast/<wallpaper>__<appearance>__<transparency>/<surface>[.hidden|.white|.black].png and
# contrast.csv. The nested session this script starts is torn down on exit (also on failure or interruption).
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

# Only tear down a session this run started.
was_running=0
vs_nested_running && was_running=1
cleanup() {
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# cap SURFACE [SETTLE]: the surface in the four glyph modes -> $dir/SURFACE{,.hidden,.white,.black}.png
cap() {
  local name=$1 settle=${2:-1} m
  VS_SHOTS=$dir VS_SETTLE=$settle vs_capture "$name" >/dev/null
  mv "$dir/$name.en.png" "$dir/$name.png"
  for m in hidden white black; do
    vs_ipc visual glyphs "$m" >/dev/null
    VS_SHOTS=$dir VS_SETTLE=0.5 VS_NOPARK=1 vs_capture "$name" >/dev/null
    mv "$dir/$name.en.png" "$dir/$name.$m.png"
  done
  vs_ipc visual glyphs normal >/dev/null
}

# want SURFACE: true when the surface is selected (--surfaces; all by default).
want() { [[ -z $surfaces || " $surfaces " == *" $1 "* ]]; }

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

# differs REF IMG MIN: capture check that IMG shows something REF (the bare desktop of the same combination) does not.
differs() {
  local n
  n=$(compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 || true)
  # compare prints "4394.01 (0.0021)" with a fuzz: keep the integer part.
  [[ $n =~ ^[0-9]+ ]] && (( ${BASH_REMATCH[0]} >= $3 )) || fail "$(basename "$2") looks like $(basename "$1") (differs in '$n' px, need $3): the surface did not open"
}

if (( ! measure_only )); then
  rm -rf "$out"; mkdir -p "$out"
  python3 -I "$VS_HERE/contrast.py" gen "$wp"
  export VISUAL_LANG=en
  vs_session en
  vs_reset dark 0.25
  bus=$(<"$VS_DEV/bus.address")
  for w in $wallpapers; do
    for appearance in light dark; do
      for tr in $transparencies; do
        dir=$out/${w}__${appearance}__${tr}
        mkdir -p "$dir"
        vs_wallpaper "$wp/$w.png"
        vs_ipc controlcenter appearance "$appearance" >/dev/null
        vs_ipc controlcenter transparency "$tr" >/dev/null
        vs_sleep 1.5
        want desktop && cap desktop
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
          vs_ipc search open files >/dev/null; need_json search .open true; vs_sleep 1; cap search; vs_ipc search close >/dev/null
          need_json search .open false
        fi
        if want apps; then
          vs_ipc apps open >/dev/null; need_json apps .open true; vs_sleep 1; cap apps; vs_ipc apps close >/dev/null
          need_json apps .open false
        fi
        if want banners || want notificationcenter; then
          # Banners stay up for the four captures (about 6 s), then expire before the Notification Center is opened.
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 14000 "Anna Martin" "Are we still on for lunch tomorrow?"
          DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 14000 "Design review" "Starts in 10 minutes in Room 4."
          need_notif banners 2
          if want banners; then
            vs_sleep 1.5; cap banners 0.5
            differs "$dir/desktop.png" "$dir/banners.png" 2000
          fi
          # The banners expire (14 s) before the Notification Center is opened; both are checked, not assumed.
          need_notif banners 0 30
          if want notificationcenter; then
            center open; vs_sleep 1; cap notificationcenter
            differs "$dir/desktop.png" "$dir/notificationcenter.png" 2000
            center closed
          fi
        fi
        vs_park
      done
    done
  done
fi

python3 -I "$VS_HERE/contrast.py" measure "$out" --surfaces "${surfaces// /,}"
