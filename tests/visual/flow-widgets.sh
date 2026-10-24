#!/usr/bin/env bash
# GF-009 functional flow: desktop Widgets, used the way a user does. Nested session only.
#
# Proves, with `widgets status` (dev hook: the placed desktop widgets and their rectangles in output pixels), the saved
# widgets.json (the dev state directory of this tree) and the Notification Center state:
#   1. add: two widgets (a medium Clock, a small Calendar) are placed on GF-REF by the call "Add to Desktop" makes
#      (`widgets addDesktop`), inside the output, not overlapping, and saved to widgets.json;
#   2. move: the Clock is dragged with the pointer (left button down, drag, up) to a free place on the right of the
#      desktop: it snaps to the grid near the drop point and the new place is saved;
#   3. edit mode: "Edit Widgets..." of the desktop's context menu opens the widget gallery (the Notification Center opens
#      on it, macOS model); it is reached with the keyboard from the menu (the row's position is found, not assumed);
#   4. remove: "Remove Widget" of a widget's context menu removes it, also from widgets.json;
#   5. the widgets' clocks follow GRASSFIELD_FIXED_TIME (09:41) in the captures (look at flow-widgets-added).
# The gallery's own buttons are not driven (the add call above is the one they make).
# Captures: $VS_SHOTS/flow-widgets-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up after itself):  tests/visual/flow-widgets.sh
# Expected: a PASS line per check and "widgets: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start widgets

state=$VS_DEV/state/widgets.json
ws() { fl_json widgets status "$VS_OUTPUT"; }
count_is() { [[ $(ws | jq 'length') == "$1" ]]; }
saved_count_is() { [[ $(jq '.desktop | length' "$state" 2>/dev/null) == "$1" ]]; }
rect_of() { ws | jq -r --arg id "$1" '.[] | select(.id == $id) | "\(.x) \(.y) \(.w) \(.h)"'; }
center_is() { [[ $(fl_notif center) == "$1" ]]; }
saved_pos() { jq -c --arg id "$1" '[.desktop[] | select(.id == $id) | [.col, .row]] | .[0]' "$state" 2>/dev/null; }

r=$(vs_ipc widgets clearDesktop | tr -d '"')
fl_check "the desktop widgets are cleared ($r)" test "$r" = cleared
fl_check_wait "nothing is placed" 5 count_is 0
vs_park
base=$(fl_shot base)

# 1. add
r=$(vs_ipc widgets addDesktop clock medium "$VS_OUTPUT" | tr -d '"')
fl_check "a medium Clock is added ($r)" test "$r" = added
r=$(vs_ipc widgets addDesktop calendar small "$VS_OUTPUT" | tr -d '"')
fl_check "a small Calendar is added ($r)" test "$r" = added
fl_check_wait "two widgets are placed" 5 count_is 2
fl_check_wait "both are saved to widgets.json" 5 saved_count_is 2
read -r cx cy cw ch <<<"$(rect_of clock)"
read -r kx ky kw kh <<<"$(rect_of calendar)"
echo "clock at $cx,$cy ${cw}x$ch; calendar at $kx,$ky ${kw}x$kh"
inside() { # x y w h inside the 1920x1080 output
  (( $1 >= 0 && $2 >= 0 && $1 + $3 <= 1920 && $2 + $4 <= 1080 ))
}
overlap() { # two rectangles intersect
  (( $1 < $5 + $7 && $5 < $1 + $3 && $2 < $6 + $8 && $6 < $2 + $4 ))
}
fl_check "both widgets are inside the output" bash -c "$(declare -f inside); inside $cx $cy $cw $ch && inside $kx $ky $kw $kh"
fl_check "the two widgets do not overlap" bash -c "$(declare -f overlap); ! overlap $cx $cy $cw $ch $kx $ky $kw $kh"
vs_sleep 2
added=$(fl_shot added)
n=$(vs_px_diff "$base" "$added")
fl_check "the widgets are on screen ($n px differ from the bare desktop, need >= 3000)" test "$n" -ge 3000

# 2. move: the Clock to the right of the desktop (a free place: widgets fill the grid from the top left)
tx=1500
ty=420
gx=$((cw / 2))
gy=$((ch / 2))
before=$(saved_pos clock)
vs_pointer abs $((cx + gx)) $((cy + gy)) sleep 400 down sleep 400 drag $((cx + gx + 40)) $((cy + gy + 20)) sleep 200 \
  drag $(((cx + gx + tx) / 2)) $(((cy + gy + ty) / 2)) sleep 200 drag "$tx" "$ty" sleep 500 up >/dev/null
vs_sleep 1.5
read -r mx my _ _ <<<"$(rect_of clock)"
echo "clock moved to $mx,$my (dropped at $tx,$ty grabbing at +$gx,+$gy)"
near() { (( ($1 - $2) * ($1 - $2) + ($3 - $4) * ($3 - $4) < 250 * 250 )); }
fl_check "the Clock moved (from $cx,$cy to $mx,$my)" test "$mx,$my" != "$cx,$cy"
fl_check "it snapped near the drop point (within 250 px of $((tx - gx)),$((ty - gy)))" near "$mx" $((tx - gx)) "$my" $((ty - gy))
pos_changed() { [[ $(saved_pos clock) != "$before" ]]; }
fl_check_wait "the new place is saved to widgets.json (was $before)" 5 pos_changed
fl_shot moved >/dev/null

# 3. edit mode: Edit Widgets... from the desktop's context menu
opened=""
for n in 4 3 5 2 6; do
  vs_pointer abs 1000 600 rclick >/dev/null
  vs_sleep 0.8
  for _ in $(seq 1 "$n"); do fl_tap Down; done
  fl_tap Return
  vs_sleep 1
  if [[ $(fl_notif center) == true ]]; then opened=$n; break; fi
  fl_tap Escape
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
fl_check "Edit Widgets... opens the gallery (the Center opens; the menu row was Down x${opened:-?})" test -n "$opened"
vs_sleep 1.5
gal=$(fl_shot gallery)
n=$(vs_px_diff "$added" "$gal")
fl_check "the gallery is on screen ($n px differ from the desktop with the widgets, need >= 3000)" test "$n" -ge 3000
fl_tap Escape
vs_sleep 0.5
if [[ $(fl_notif center) == true ]]; then vs_ipc notifications toggleCenter >/dev/null; fi
fl_check_wait "the gallery and the Center are closed" 5 center_is false

# 4. remove: Remove Widget from the Calendar's context menu
read -r kx ky kw kh <<<"$(rect_of calendar)"
removed=""
for n in 4 3 5 2 6; do
  vs_pointer abs $((kx + kw / 2)) $((ky + kh / 2)) sleep 300 rclick >/dev/null
  vs_sleep 0.8
  for _ in $(seq 1 "$n"); do fl_tap Down; done
  fl_tap Return
  vs_sleep 1
  if [[ $(ws | jq 'length') == 1 ]]; then removed=$n; break; fi
  fl_tap Escape
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
fl_check "Remove Widget removes it (the menu row was Down x${removed:-?})" test -n "$removed"
fl_check "the Clock is the one left" test "$(ws | jq -r '.[0].id')" = clock
fl_check_wait "the removal is saved to widgets.json" 5 saved_count_is 1
fl_shot removed >/dev/null

# Clean up
vs_ipc widgets clearDesktop >/dev/null
fl_check_wait "the desktop is empty again (widgets.json too)" 5 saved_count_is 0

fl_done
