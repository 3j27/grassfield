#!/usr/bin/env bash
# GF-009 functional flow: Preview on images, used the way a user does. Nested session only.
#
# Proves, with the window the compositor reports (its title is the file name) and captures compared with the same window
# before the action:
#   1. Preview opens an image of a folder of three generated images (the title names the file);
#   2. zoom in (the "=" / "+" key) enlarges the image: the window content changes; Fit (Ctrl+9) brings back the first view;
#   3. rotate (Ctrl+R) turns the picture: the content changes; four turns bring back the first view;
#   4. Right moves to the next image of the folder (the title follows) and Left back.
# Keys: typed into the focused app window through scripts/dev/keys.sh (plain keys and Ctrl shortcuts, as preview-browse.sh does).
# Captures: $VS_SHOTS/flow-preview-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up its window):  tests/visual/flow-preview.sh
# Expected: a PASS line per check and "preview: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start preview

img=$VS_STATE/flow-preview-images
mkdir -p "$img"
for i in 1 2 3; do
  # An asymmetric picture (a gradient and a numeral off centre): a turn or a zoom always changes the pixels.
  magick -size 1200x800 gradient:'#d9453d'-'#2f5fd0' -gravity northwest -pointsize 220 -fill white -annotate +60+40 "$i" "$img/img$i.png"
done
class='org\.grassfield\.Preview'
title_is() { fl_title_has "$class" "$1"; }
count_is() { [[ $(fl_window_count "$class") == "$1" ]]; }

vs_spawn "$VS_DEV/build/grassfield-preview" "$img/img2.png"
fl_check_wait "Preview opens img2.png" 25 title_is 'img2\.png'
vs_sleep 2
fl_check "Preview has the keyboard focus" fl_focus_class "$class"
first=$(fl_shot open)

# 2. zoom
fl_key -k equal
fl_key -k equal
vs_sleep 1
zoomed=$(fl_shot zoomed)
n=$(vs_px_diff "$first" "$zoomed")
fl_check "zoom in changes the view ($n px differ, need >= 5000)" test "$n" -ge 5000
fl_appkey ctrl 9
vs_sleep 1
fit=$(fl_shot fit)
n=$(vs_px_diff "$first" "$fit")
fl_check "Fit (Ctrl+9) brings back the first view ($n px differ, need < 600)" test "$n" -lt 600

# 3. rotate
fl_appkey ctrl r
vs_sleep 1
rot=$(fl_shot rotated)
n=$(vs_px_diff "$fit" "$rot")
fl_check "Ctrl+R turns the picture ($n px differ, need >= 5000)" test "$n" -ge 5000
# Three more turns, each given time to land (the rotation is a plain binding, no animation, and `turns` is taken mod 4 in
# ImageView.rotate). A key lost under load would leave the picture turned, so after the fourth turn up to three more are
# tried: the flow then says how many presses it took, and fails when no multiple of four brings the first view back.
presses=1
n=999999
for _ in 1 2 3 4 5 6 7; do
  if (( presses >= 4 )); then
    vs_sleep 1
    full=$(fl_shot "turns-$presses")
    n=$(vs_px_diff "$fit" "$full")
    (( n < 600 )) && break
  fi
  fl_appkey ctrl r
  vs_sleep 0.5
  presses=$((presses + 1))
done
fl_check "the first view is back after $presses turns ($n px differ, need < 600)" test "$n" -lt 600
(( presses == 4 )) || fl_note "Ctrl+R needed $presses presses for four turns: a key press was lost or doubled under load"

# 4. next and previous image
fl_key -k Right
fl_check_wait "Right shows img3.png" 10 title_is 'img3\.png'
fl_shot next >/dev/null
fl_key -k Left
fl_check_wait "Left shows img2.png again" 10 title_is 'img2\.png'

fl_close_windows "$class"
fl_check_wait "the Preview window is closed" 10 count_is 0

fl_done
