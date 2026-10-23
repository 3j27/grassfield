#!/usr/bin/env bash
# Desktop widgets are real frosted glass (master-prompt 5.5, audit GF-027 / D-8): a high-frequency stripe wallpaper is set,
# one desktop widget is added, and a strip of the tile's own pixels (inside it, away from its content) is compared with a strip
# of the same size just outside it. The wallpaper stripes cross the first strongly; behind real blur they are gone from the
# tile (deviation inside < 25 % of the deviation outside). With Reduce Transparency on the tile is opaque (no stripes at all).
# Captures: $VS_SHOTS/widgets-blur-*.png. Usage (bare command): tests/visual/widgets-blur.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
sd() { # image crop -> luminance standard deviation x 100 (0-25500)
  magick "$1" -crop "$2" +repage -colorspace Gray -format '%[fx:int(standard_deviation*25500)]' info:
}

vs_session >/dev/null
vs_reset dark >/dev/null

stripes="$VS_STATE/widgets-blur-stripes.png"
# 4 px black, 4 px white vertical stripes at full contrast.
magick -size 8x8 xc:white -fill black -draw "rectangle 0,0 3,7" "$VS_STATE/widgets-blur-tile.png"
magick -size 1920x1080 "tile:$VS_STATE/widgets-blur-tile.png" "$stripes"
vs_wallpaper "$stripes"
r=$(vs_ipc widgets clearDesktop | tr -d '"')
check "dev hook clears the desktop widgets ($r)" test "$r" = cleared
r=$(vs_ipc widgets addDesktop clock medium "$VS_OUTPUT" | tr -d '"')
check "a desktop widget is added ($r)" test "$r" = added
vs_sleep 2
rect=$(vs_ipc widgets status "$VS_OUTPUT" | jq -r '.[0] | "\(.x) \(.y) \(.w) \(.h)"')
read -r wx wy ww wh <<<"$rect"
echo "widget at $rect"

vs_park
vs_capture widgets-blur-on >/dev/null
on="$VS_SHOTS/widgets-blur-on.$VS_LANG.png"
# A 40x12 strip inside the tile near its top-left corner (the clock text is centred) and the same strip just outside it.
inside=$(sd "$on" "40x12+$((wx + 14))+$((wy + 10))")
# Outside: right of the tile (a widget at the left edge has no room on its left), below it when the right is off the output.
if (( wx + ww + 70 < 1900 )); then ox=$((wx + ww + 20)); oy=$((wy + 10)); else ox=$((wx + 14)); oy=$((wy + wh + 20)); fi
outside=$(sd "$on" "40x12+${ox}+${oy}")
echo "stripe deviation x100: inside the tile $inside, outside $outside"
check "the stripes are visible outside the tile (deviation $outside > 2000)" test "$outside" -gt 2000
check "the tile blurs them away: inside $inside < 25 % of outside $outside" test "$((inside * 4))" -lt "$outside"

vs_ipc controlcenter reduceTransparency true >/dev/null
vs_sleep 1
vs_capture widgets-blur-opaque >/dev/null
opaque="$VS_SHOTS/widgets-blur-opaque.$VS_LANG.png"
inside_opaque=$(sd "$opaque" "40x12+$((wx + 14))+$((wy + 10))")
check "Reduce Transparency: the tile is opaque (deviation $inside_opaque < 300)" test "$inside_opaque" -lt 300
vs_ipc controlcenter reduceTransparency false >/dev/null

vs_ipc widgets clearDesktop >/dev/null
vs_wallpaper ""
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
