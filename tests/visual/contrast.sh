#!/usr/bin/env bash
# Gate A2 driver: captures the contrast surfaces on 5 worst-case wallpapers x light/dark x transparency
# 0.25/0.6 in the nested session, then runs contrast.py. Run as a BARE command (reference machine only).
#   tests/visual/contrast.sh [--measure-only] [--wallpapers white,black,...] [--transparency 0.25,0.6]
# Output: .dev/visual/contrast/<wallpaper>__<appearance>__<transparency>/<surface>.png and contrast.csv.
# Exit status: contrast.py's (1 when a cell is below its threshold).
source "$(dirname "$0")/lib.sh"

measure_only=0
wallpapers="white black gray noise checker"
transparencies="0.25 0.6"
while [[ $# -gt 0 ]]; do
  case $1 in
    --measure-only) measure_only=1 ;;
    --wallpapers) wallpapers=${2//,/ }; shift ;;
    --transparency) transparencies=${2//,/ }; shift ;;
    *) echo "contrast: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

out=$VS_STATE/contrast
wp=$out/wallpapers

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
        vs_ipc wallpaper set "$wp/$w.png" >/dev/null
        vs_ipc controlcenter appearance "$appearance" >/dev/null
        vs_ipc controlcenter transparency "$tr" >/dev/null
        vs_sleep 1.5
        cap() { VS_SHOTS=$dir VS_SETTLE=${2:-1} vs_capture "$1" >/dev/null; mv "$dir/$1.en.png" "$dir/$1.png"; }
        cap desktop
        vs_ipc menubar open system GF-REF >/dev/null; cap systemmenu; vs_ipc menubar close >/dev/null
        vs_ipc menubar open controlcenter GF-REF >/dev/null; cap controlcenter; vs_ipc menubar close >/dev/null
        vs_ipc search open files >/dev/null; vs_sleep 1; cap search; vs_ipc search close >/dev/null
        vs_ipc apps open >/dev/null; vs_sleep 1; cap apps; vs_ipc apps close >/dev/null
        DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 6000 "Anna Martin" "Are we still on for lunch tomorrow?"
        DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 6000 "Design review" "Starts in 10 minutes in Room 4."
        vs_sleep 1.5; cap banners 0.5
        vs_sleep 6.5
        vs_pointer abs 1850 12 sleep 300 click >/dev/null; vs_sleep 1; cap notificationcenter
        vs_pointer abs 1850 12 sleep 300 click >/dev/null
        vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
        vs_sleep 0.5
      done
    done
  done
  "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
fi

python3 -I "$VS_HERE/contrast.py" measure "$out"
