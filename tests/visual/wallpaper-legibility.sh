#!/usr/bin/env bash
# Menu bar legibility over user wallpapers (ADR-0016 section 7, gate A2): generated worst-case pictures go through the real
# path (grassfield.json -> shell -> grassfield-wallpaper -> strip statistics -> BarTone). The bar must end with a tone that
# reaches 4.5:1 or, when no tone can, with the frosted band on that output. Pictures are generated under .dev, never committed.
# Usage (bare command): tests/visual/wallpaper-legibility.sh      Captures: $VS_SHOTS/legibility-*.en.png
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-a2
mkdir -p "$pics"
magick -size 1920x1080 xc:black "$pics/dark.png"
magick -size 1920x1080 xc:white "$pics/light.png"
magick -size 1920x1080 xc:black -fill white -draw "rectangle 0,0 959,1079" "$pics/split.png"
magick -size 1920x1080 xc:black -fill white -draw "rectangle 0,0 1919,11" "$pics/horizon.png"
# A threshold wallpaper: luminance 0.17, the crossover of the two tones (menubar.md).
magick -size 1920x1080 xc:'#767676' "$pics/threshold.png"
# The hysteresis case of the review: after a light wallpaper (tone dark), two greys that give black 4.42:1 and white 4.61:1.
magick -size 1920x1080 xc:'#737373' -fill '#757575' -draw "rectangle 960,0 1919,1079" "$pics/pair.png"
# Large-scale blocks of extreme luminance.
magick -size 30x17 xc: +noise Random -threshold 50% -scale 6400% -crop 1920x1080+0+0 +repage "$pics/blocks.png"
# Large-scale noise (a photo-like picture).
magick -size 24x14 xc: +noise Random -colorspace Gray -resize 1920x1080! -blur 0x20 "$pics/photolike.png"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

vs_session
vs_reset
cfg=$VS_DEV/config/grassfield.json

use() { # file
  jq --arg p "$pics/$1" '.wallpaper = {source: "file", path: $p, fit: "fill"}' "$cfg" > "$cfg.new" 2>/dev/null || printf '{"version":1,"wallpaper":{"source":"file","path":"%s","fit":"fill"}}\n' "$pics/$1" > "$cfg.new"
  mv "$cfg.new" "$cfg"
  vs_sleep 4
}

status() { vs_ipc bartone status; }
field() { # output field -> value
  status | jq -r --arg o "$VS_OUTPUT" --arg f "$1" '.[$o][$f]'
}

for case in dark:light:false light:dark:false split:any:true horizon:any:true; do
  IFS=: read -r name tone assist <<<"$case"
  use "$name.png"
  got_tone=$(field tone)
  got_assist=$(field assist)
  echo "$name: tone=$got_tone assist=$got_assist white=$(field white) black=$(field black)"
  check "$name: assist=$assist" test "$got_assist" = "$assist"
  [[ $tone == any ]] || check "$name: tone=$tone" test "$got_tone" = "$tone"
  vs_capture "legibility-$name" >/dev/null
  magick "$VS_SHOTS/legibility-$name.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/legibility-$name-bar.$VS_LANG.png"
done

# The rule for every picture: the tone reaches 4.5:1, or the band is on.
use light.png
for name in pair threshold blocks photolike; do
  use "$name.png"
  w=$(field white)
  b=$(field black)
  a=$(field assist)
  t=$(field tone)
  echo "$name: tone=$t assist=$a white=$w black=$b"
  # The CHOSEN tone must reach 4.5:1 (not the better of the two: hysteresis can keep the other), or the band is on.
  check "$name: the chosen tone ($t) is legible, or the band is on" awk -v t="$t" -v w="$w" -v b="$b" -v a="$a" 'BEGIN {c = (t == "light" ? w : b); exit !(c >= 4.5 || a == "true")}'
  vs_capture "legibility-$name" >/dev/null
  magick "$VS_SHOTS/legibility-$name.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/legibility-$name-bar.$VS_LANG.png"
done

# The dev override (contrast runs): while it covers the wallpaper the bar follows it; once it is cleared the bar follows what
# is on screen again (review finding: it kept the override's tone). The artwork's sky is dark, so its tone is light.
jq '.wallpaper = {source: "builtin"}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
vs_sleep 3
check "the artwork gives the light tone" test "$(field tone)" = light
vs_wallpaper "$pics/light.png"
vs_sleep 2
check "a white override gives the dark tone" test "$(field tone)" = dark
vs_wallpaper ""
vs_sleep 2
check "the override cleared: the bar follows the artwork again (light)" test "$(field tone)" = light

# The override cleared while the next picture still decodes (dev hook loadDelay, at most 5 s): the bar keeps the tone of what
# is on screen (the black picture, light), not the one of the white picture that is not shown yet (review finding: a flag
# left over from the previous fade made it report the pending picture). Needs a real fade first (vs_reset turns Reduce
# Motion on, which switches without one).
vs_ipc controlcenter reduceMotion false >/dev/null
use dark.png
check "after a real fade the black picture gives the light tone" test "$(field tone)" = light
vs_ipc wallpaper loadDelay 5000 >/dev/null
vs_wallpaper "$pics/light.png"
vs_sleep 1
jq --arg p "$pics/light.png" '.wallpaper = {source: "file", path: $p, fit: "fill"}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
vs_sleep 2
vs_wallpaper ""
vs_sleep 1
check "the override cleared during a decode: the bar keeps the shown picture's tone (light)" test "$(field tone)" = light
vs_ipc wallpaper loadDelay 0 >/dev/null
vs_sleep 7
check "the decoded white picture then gives the dark tone" test "$(field tone)" = dark
vs_ipc controlcenter reduceMotion true >/dev/null

check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
