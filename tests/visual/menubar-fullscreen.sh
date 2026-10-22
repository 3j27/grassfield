#!/usr/bin/env bash
# The menu bar over a full-screen window (docs/specs/menubar.md 2b), on GF-REF with one foot window made full screen:
# the bar is away, the pointer at the top edge slides it down over the window (the window keeps its size), leaving it
# slides it away. Captures (crops of the top strip) in $VS_SHOTS/mbfs-*.png: dark and light appearance, each away, mid-slide
# and shown. Reduce Motion: shown without a slide.
#   away          nothing of the bar is drawn over the window
#   mid-slide     reported, not asserted: a capture taken right after the dwell shows the bar part-way when the timing caught
#   shown         the bar is drawn over the window; the window geometry is unchanged
#   reduce-motion with Reduce Motion on the bar is shown (visible 1) 0.5 s after the pointer reached the edge, never part-way
# Usage (bare command): tests/visual/menubar-fullscreen.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
nest() { "$VS_ROOT/scripts/nestctl" "$@"; }
state() { vs_ipc menubar autohide "$VS_OUTPUT"; }
field() { jq -r "$1" <<<"$2"; }
foot_geom() { nest clients -j | jq -r '.[] | select(.title == "mbfs-foot") | "\(.at[0]),\(.at[1]),\(.size[0]),\(.size[1])"'; }
px_diff() { # a b crop -> differing pixels (fuzz 6 %)
  { magick compare -fuzz 6% -metric AE <(magick "$1" -crop "$3" +repage png:-) <(magick "$2" -crop "$3" +repage png:-) null: 2>&1 || true; } | awk '{print int($1)}'
}
shot() { # name -> crop of the top strip in $VS_SHOTS
  "$VS_ROOT/scripts/dev/shot.sh" "visual-$1" "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/visual-$1.png" -crop 1920x60+0+0 +repage "$VS_SHOTS/mbfs-$1.png"
  cp "$VS_DEV/shots/visual-$1.png" "$VS_SHOTS/mbfs-$1-full.png"
}

vs_session >/dev/null
vs_reset >/dev/null
vs_foot mbfs-foot 80x20 >/dev/null
vs_wait_clients 1 >/dev/null || true
vs_sleep 1.5
addr=$(nest clients -j | jq -r '.[] | select(.title == "mbfs-foot") | .address' | head -n 1)
nest dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$addr' })" >/dev/null 2>&1
vs_sleep 1.5
geom=$(foot_geom)
echo "full-screen foot: $geom"

for look in dark light; do
  vs_ipc controlcenter appearance "$look" >/dev/null
  vs_ipc controlcenter reduceMotion false >/dev/null
  vs_sleep 1
  vs_pointer abs 960 540 >/dev/null
  vs_sleep 1.2
  shot "$look-away"
  away=$(state)
  check "away ($look): the bar is away over the full-screen window ($away)" test "$(field '[.fullscreen, .away, .overlay] | @csv' "$away")" = "true,true,true"
  # Reach the top edge and capture at once, again a little later, then once settled.
  vs_pointer abs 960 0 >/dev/null
  vs_sleep 0.2
  shot "$look-mid"
  mid=$(state)
  vs_sleep 1.2
  shot "$look-shown"
  shown=$(state)
  echo "mid-slide ($look): $(field '"\(.state) visible=\(.visible)"' "$mid")"
  d=$(px_diff "$VS_SHOTS/mbfs-$look-away.png" "$VS_SHOTS/mbfs-$look-shown.png" "1920x22+0+1")
  check "shown ($look): the bar is drawn over the window ($d px changed) and the window keeps its geometry" test "$d" -gt 400 -a "$(field .state "$shown")" = shown -a "$(foot_geom)" = "$geom"
  vs_pointer abs 960 540 >/dev/null
  vs_sleep 1.5
done

# Reduce Motion: no slide.
vs_ipc controlcenter reduceMotion true >/dev/null
vs_sleep 0.5
vs_pointer abs 960 0 >/dev/null
vs_sleep 0.5
rm_state=$(state)
check "reduce-motion: shown at once, no slide ($rm_state)" test "$(field '[.state, .visible] | @csv' "$rm_state")" = '"shown",1'
vs_pointer abs 960 540 >/dev/null
vs_sleep 1

nest dispatch "hl.dsp.window.fullscreen({ mode = 'fullscreen', window = 'address:$addr' })" >/dev/null 2>&1 || true
vs_ipc controlcenter appearance dark >/dev/null
vs_ipc controlcenter reduceMotion true >/dev/null
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
