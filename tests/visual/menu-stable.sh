#!/usr/bin/env bash
# A context menu never moves once open (macOS model; owner report 2026-10-23: the desktop menu moved when the pointer went
# over a row with a submenu) and opens with no row highlighted (macOS: until the pointer or a key selects one). The desktop
# menu is opened in the middle, near the right edge, near the bottom edge and in the corner; the pointer is walked up its
# rows (10 px steps from the bottom, "Clean Up By" is the last row) until a submenu opens (the menu's box grows); the parent's
# top border (a strip of its frosted panel) must be pixel-identical before and after.
# The empty-desktop reference is taken with the pointer parked in the left margin, where the software cursor shows in the
# capture: that margin (x < 200) is left out of every comparison (the first version of this walk measured the cursor as
# part of the menu, took a box 700 px wide for it and never reached a row).
# Captures: $VS_SHOTS/mstable-*.png. Usage (bare command): tests/visual/menu-stable.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

vs_session >/dev/null
vs_reset dark >/dev/null
vs_park
vs_capture mstable-none >/dev/null
none="$VS_SHOTS/mstable-none.$VS_LANG.png"
MARGIN=200

# Bounding box "WxH+X+Y" of the pixels that differ from the empty desktop right of the margin (the menu and, once open, its
# submenu).
diffbox() {
  local box w h x y
  box=$(magick "$none" "$1" -crop "+${MARGIN}+0" +repage -compose difference -composite -colorspace Gray -threshold 3% -trim -format '%wx%h%O' info:)
  IFS='x+' read -r w h x y <<<"$box"
  echo "${w}x${h}+$((x + MARGIN))+${y}"
}

# Pixels of strong colour (the highlighted row is the accent colour; the menu, its text and the frosted wallpaper are not).
saturated() { # image box
  local w h x y
  IFS='x+' read -r w h x y <<<"$2"
  magick "$1" -crop "${w}x${h}+${x}+${y}" +repage -colorspace HSL -channel G -separate +channel -threshold 55% -format '%[fx:int(mean*w*h)]' info:
}

first=1
for spot in "mid 700 500" "right 1900 500" "bottom 700 1070" "corner 1910 1070"; do
  read -r name x y <<<"$spot"
  vs_pointer abs "$x" "$y" rclick >/dev/null
  VS_NOPARK=1 vs_capture "mstable-$name-closed" >/dev/null
  a="$VS_SHOTS/mstable-$name-closed.$VS_LANG.png"
  box_a=$(diffbox "$a")
  echo "$name: menu box before the submenu: $box_a"
  IFS='x+' read -r bw bh bx by <<<"$box_a"
  sat_closed=$(saturated "$a" "$box_a")
  opened=""
  box_b=""
  for step in $(seq 1 16); do
    py=$((by + bh - 8 - (step - 1) * 10))
    px=$((bx + bw / 3))
    vs_pointer abs "$px" "$py" >/dev/null
    vs_sleep 0.5
    VS_NOPARK=1 vs_capture "mstable-$name-open" >/dev/null
    b="$VS_SHOTS/mstable-$name-open.$VS_LANG.png"
    box_b=$(diffbox "$b")
    IFS='x+' read -r cw ch cx cy <<<"$box_b"
    if [[ $cw -gt $bw ]]; then
      opened=1
      break
    fi
  done
  check "$name: hovering the last row opened its submenu (step $step)" test -n "$opened"
  echo "$name: box after: $box_b"
  top_a=$(magick "$a" -crop "$((bw / 2))x4+${bx}+${by}" +repage -format '%#' info:)
  top_b=$(magick "$b" -crop "$((bw / 2))x4+${bx}+${by}" +repage -format '%#' info:)
  check "$name: the parent's top border is pixel-identical before and after (same position)" test "$top_a" = "$top_b"
  if [[ -n $first ]]; then
    first=""
    sat_open=$(saturated "$b" "$box_b")
    echo "$name: saturated pixels: closed $sat_closed, with a row highlighted $sat_open"
    check "no row is highlighted when the menu opens (saturated pixels $sat_closed; $sat_open once the pointer is on a row)" test "$((sat_closed + 1000))" -lt "$sat_open"
  fi
  vs_pointer abs 300 700 click >/dev/null
  vs_sleep 0.5
done
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
