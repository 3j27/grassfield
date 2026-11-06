#!/usr/bin/env bash
# UI audit 2026-11-05 U1: frames of the banner stack through three exits, to measure whether any remaining card leaves its
# rest position (a jump after the exit finished). Nested session only, on the session's PRIVATE D-Bus; the nested session is
# started by the caller (scripts/dev/nested-up.sh [--ref-scale 1.25] [--no-plugin]) and left running.
# Usage (bare command):  tests/visual/flow-banner-exit.sh [--no-plugin] OUTDIR  (OUTDIR relative to the repository)
# Writes OUTDIR/<case>/EPOCH.ppm: one file per frame, named by the time it was taken (three staggered grim loops on the
# banners strip of GF-REF, from the card left - 24, 392x560 logical). Cases:
#   expire3   three banners, the newest (top) one expires by its own timeout
#   close     three banners, the top one dismissed by its close button (pointer click)
#   arrival   as close, and a new banner arrives 0.12 s after the click, while the exit still plays
# Reduce Motion is off for the run (the exits are animations). tests/visual/banner-top-y.py reads the top card per frame.
source "$(dirname "$0")/lib.sh"

rm_on=0
while [[ ${1:-} == --* ]]; do
  case $1 in
    --no-plugin) export GRASSFIELD_NO_PLUGIN=1 ;;  # the session was started with --no-plugin
    --reduce-motion) rm_on=1 ;;                    # Reduce Motion stays on: the exits fade in place, the gap closes at once
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
out=${1:?usage: flow-banner-exit.sh [--no-plugin] [--reduce-motion] OUTDIR}
bus=
cap_pid=
cleanup() {
  [[ -z $cap_pid ]] || kill "$cap_pid" 2>/dev/null || true
  vs_ipc notifications clearAll >/dev/null 2>&1 || true
}
trap cleanup EXIT

vs_session >/dev/null
vs_reset dark >/dev/null
set +e
(( rm_on )) || vs_ipc controlcenter reduceMotion false >/dev/null
vs_ipc notifications dnd false >/dev/null
bus=$(<"$VS_DEV/bus.address")
send() { DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "$1" -t "$2" "$3" "Body text of $3, long enough to take a second line in the card."; }

scale=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .scale')
width=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .width')
lw=$(awk -v w="$width" -v s="$scale" 'BEGIN { printf "%d", w / s }')
cardleft=$((lw - 16 - 344))
outx=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .x')
# Only the banners' strip is captured (device pixels): a small PPM is the fastest grim can do, and a jump of one or two
# frames needs the highest frame rate.
region="$((outx + cardleft - 24)),0 392x560"
echo "scale=$scale logical width=$lw card left=$cardleft"

# Three grim loops in parallel, staggered: each frame is named by the time it was taken (NNNNNNNNNN.NNNNNNNNN.ppm).
capture() { # DIR SECONDS
  mkdir -p "$1"
  local end=$(( $(date +%s%N) + $2 * 1000000000 )) k
  for k in 1 2 3; do
    (
      sleep "0.0$((k * 2))"
      while (( $(date +%s%N) < end )); do
        WAYLAND_DISPLAY=$(vs_nested_wayland) grim -g "$region" -t ppm -s "$scale" "$1/w$k.tmp" && mv "$1/w$k.tmp" "$1/$(date +%s.%N).ppm"
      done
    ) &
  done
  wait
}

# after NAME: the strip two seconds after an exit, as a PNG (a stale blur region would show as a faint empty band)
after() {
  vs_sleep 2
  WAYLAND_DISPLAY=$(vs_nested_wayland) grim -g "$region" -s "$scale" "$out/$1-after.png"
}

swipe_top() {
  vs_pointer abs $((cardleft + 170)) 70 >/dev/null; vs_sleep 0.4
  vs_pointer abs $((cardleft + 170)) 70 down >/dev/null
  vs_pointer drag $((cardleft + 330)) 70 >/dev/null
  vs_pointer up >/dev/null
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null
}

fresh() {
  vs_ipc notifications clearAll >/dev/null
  vs_sleep 2
  vs_park
}

three() {
  send Mail 0 "Banner A"; vs_sleep 0.4
  send Calendar 0 "Banner B"; vs_sleep 0.4
  send Messages 0 "Banner C"; vs_sleep 1.8
}

click_close() {
  vs_pointer abs $((cardleft + 170)) 70 >/dev/null; vs_sleep 0.5
  vs_pointer abs $((cardleft + 4)) 44 sleep 150 click >/dev/null
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null   # no hover on the next card: its close button would show in the frames
}

# expire3: the newest banner expires 3 s after it arrives.
fresh
send Mail 0 "Banner A"; vs_sleep 0.4
send Calendar 0 "Banner B"; vs_sleep 0.8
capture "$out/expire3" 8 &
cap_pid=$!
vs_sleep 0.8
send Messages 3000 "Banner C (expires)"
wait "$cap_pid"; cap_pid=
after expire3

# expire-bottom: the OLDEST (bottom) banner expires.
fresh
send Mail 3000 "Banner A (expires)"; vs_sleep 0.4
send Calendar 0 "Banner B"; vs_sleep 0.4
send Messages 0 "Banner C"
capture "$out/expire-bottom" 6 &
cap_pid=$!
wait "$cap_pid"; cap_pid=
after expire-bottom

# swipe: the top banner dragged away.
fresh
three
capture "$out/swipe" 4 &
cap_pid=$!
vs_sleep 0.6
swipe_top
wait "$cap_pid"; cap_pid=
after swipe

# close: dismissed by its close button.
fresh
three
capture "$out/close" 5 &
cap_pid=$!
vs_sleep 0.8
click_close
wait "$cap_pid"; cap_pid=
after close

# arrival: a new banner during the exit.
fresh
three
capture "$out/arrival" 5 &
cap_pid=$!
vs_sleep 0.8
click_close
vs_sleep 0.12
send Photos 0 "Banner D (arrives during the exit)"
wait "$cap_pid"; cap_pid=
after arrival
fresh
echo "done: $out"
